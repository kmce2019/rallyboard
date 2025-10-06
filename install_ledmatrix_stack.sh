#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# LEDMatrix "Base OS + App Store" — One-shot Installer
# Tested on Raspberry Pi OS (Bookworm). Run with: sudo bash
# ============================================================

LED_USER="ledpi"
LED_GROUP="ledpi"
LED_HOME="/opt/ledmatrix"
PY="python3"
VENV="$LED_HOME/venv"
WEB_PORT="5001"
PANEL_W=128
PANEL_H=64
MATRIX_REPO="https://github.com/hzeller/rpi-rgb-led-matrix.git"

echo "[1/12] Updating apt and installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git build-essential pkg-config \
  libjpeg-dev libtiff5 libtiff5-dev zlib1g-dev libfreetype6-dev \
  python3 python3-venv python3-dev \
  libgraphicsmagick++-dev libwebp-dev \
  curl unzip ca-certificates \
  fonts-freefont-ttf

# Optional but handy
apt-get install -y vim htop jq

# Enable SSH if not already (optional)
if [ ! -e /etc/ssh/sshd_config ]; then
  apt-get install -y openssh-server
fi
systemctl enable ssh --now || true

# Create service user
if ! id -u "$LED_USER" >/dev/null 2>&1; then
  adduser --system --home "$LED_HOME" --no-create-home --group "$LED_USER"
fi

echo "[2/12] Building rpi-rgb-led-matrix (C library + Python binding)..."
if [ ! -d /opt/rpi-rgb-led-matrix ]; then
  git clone --depth=1 "$MATRIX_REPO" /opt/rpi-rgb-led-matrix
  make -C /opt/rpi-rgb-led-matrix -j"$(nproc)"
  # Build Python binding
  make -C /opt/rpi-rgb-led-matrix/bindings/python build-python -j"$(nproc)"
  # Install the python package into system site-packages (so venv can see it)
  $PY -m pip install --upgrade pip wheel setuptools
  $PY -m pip install /opt/rpi-rgb-led-matrix/bindings/python
fi

echo "[3/12] Creating filesystem layout..."
mkdir -p "$LED_HOME"/{core,web,appd,scheduler,shared,data/apps/{installed,staging,registry},run,logs}
mkdir -p "$LED_HOME/shared/fonts"
mkdir -p "$LED_HOME/data/backup"

# Seed default settings
cat > "$LED_HOME/data/settings.yaml" <<YAML
brightness: 0.8              # 0.0 - 1.0
brightness_schedule: []       # [{start:"22:00", end:"06:30", brightness:0.1}]
timezone: "America/Chicago"
power: "on"                   # "on"|"off"
gamma: 2.2
panel:
  width: $PANEL_W
  height: $PANEL_H
  # rpi-rgb-led-matrix options (tweak as needed)
  chain_length: 2
  parallel: 1
  pwm_bits: 11
  pwm_lsb_nanoseconds: 130
  gpio_slowdown: 4
  row_address_type: 0
  multiplexing: 0
  hardware_mapping: "adafruit-hat"   # adjust for your HAT
YAML

# Default playlist
cat > "$LED_HOME/data/playlist.yaml" <<'YAML'
slots:
  - app_id: "sys.clock"
    duration_sec: 10
YAML

# Local registry (clock app bundled)
cat > "$LED_HOME/data/apps/registry/registry.json" <<'JSON'
{
  "apps": [
    {
      "id": "sys.clock",
      "name": "System Clock",
      "version": "1.0.0",
      "description": "Simple digital clock.",
      "tags": ["system","clock"],
      "download": "local-bundled"
    }
  ]
}
JSON

echo "[4/12] Python virtual environment + packages..."
$PY -m venv "$VENV"
source "$VENV/bin/activate"
pip install --upgrade pip wheel
pip install pillow pyyaml flask waitress requests

# ---------- Core Renderer ----------
cat > "$LED_HOME/core/core.py" <<'PY'
#!/usr/bin/env python3
import os, socket, struct, threading, time, json, yaml, sys, signal
from io import BytesIO
from PIL import Image, ImageEnhance
from rgbmatrix import RGBMatrix, RGBMatrixOptions

BASE="/opt/ledmatrix"
RUN=f"{BASE}/run"
LOG=f"{BASE}/logs/core.log"
SET=f"{BASE}/data/settings.yaml"
FRAMEBUS=f"{RUN}/framebus.sock"
CORECTL=f"{RUN}/corectl.sock"

def log(msg):
    ts=time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG,"a") as f: f.write(f"{ts} {msg}\n")

def load_settings():
    try:
        with open(SET) as f: return yaml.safe_load(f) or {}
    except Exception: return {}

def make_matrix():
    s=load_settings()
    p=s.get("panel",{})
    opt=RGBMatrixOptions()
    opt.rows = int(p.get("height",64))
    opt.cols = int(p.get("width",128))
    opt.chain_length = int(p.get("chain_length",1))
    opt.parallel = int(p.get("parallel",1))
    opt.pwm_bits = int(p.get("pwm_bits",11))
    opt.pwm_lsb_nanoseconds = int(p.get("pwm_lsb_nanoseconds",130))
    opt.gpio_slowdown = int(p.get("gpio_slowdown",4))
    opt.row_address_type = int(p.get("row_address_type",0))
    opt.multiplexing = int(p.get("multiplexing",0))
    opt.hardware_mapping = p.get("hardware_mapping","regular")
    return RGBMatrix(options=opt)

def apply_brightness(img, b):
    b = max(0.0,min(1.0,float(b or 1.0)))
    return ImageEnhance.Brightness(img).enhance(b)

class Core:
    def __init__(self):
        self.settings = load_settings()
        self.brightness = self.settings.get("brightness",1.0)
        self.power = self.settings.get("power","on")
        self.gamma = float(self.settings.get("gamma",2.2))
        self.matrix = make_matrix()
        self.stop = threading.Event()

    def run(self):
        # Start control and frame servers
        threading.Thread(target=self.corectl_server, daemon=True).start()
        threading.Thread(target=self.framebus_server, daemon=True).start()
        log("Core started.")
        try:
            while not self.stop.is_set():
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass

    def corectl_server(self):
        try: os.unlink(CORECTL)
        except FileNotFoundError: pass
        s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(CORECTL); s.listen(4)
        while not self.stop.is_set():
            conn,_=s.accept()
            try:
                data=conn.recv(4096)
                if not data: continue
                req=json.loads(data.decode("utf-8","ignore"))
                cmd=req.get("cmd")
                if cmd=="set_brightness":
                    self.brightness=float(req.get("value",1.0))
                    self.save_setting("brightness", self.brightness)
                elif cmd=="power":
                    self.power=req.get("state","on")
                    self.save_setting("power", self.power)
                elif cmd=="reload":
                    self.settings=load_settings()
                conn.sendall(b'{"ok":true}')
            except Exception as e:
                log(f"corectl error: {e}")
            finally:
                conn.close()

    def framebus_server(self):
        try: os.unlink(FRAMEBUS)
        except FileNotFoundError: pass
        s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(FRAMEBUS); s.listen(4)
        while not self.stop.is_set():
            conn,_=s.accept()
            threading.Thread(target=self.handle_stream, args=(conn,), daemon=True).start()

    def handle_stream(self, conn):
        try:
            while True:
                hdr=self._recv_exact(conn,4)
                if not hdr: break
                (size,) = struct.unpack("!I", hdr)
                blob=self._recv_exact(conn, size)
                if not blob: break
                if self.power!="on": continue
                try:
                    img=Image.open(BytesIO(blob)).convert("RGB")
                    img = apply_brightness(img, self.brightness)
                    self.matrix.SetImage(img, 0, 0)  # top-left
                except Exception as e:
                    log(f"frame decode error: {e}")
        except Exception as e:
            log(f"frame stream error: {e}")
        finally:
            conn.close()

    def _recv_exact(self, conn, n):
        buf=b""
        while len(buf)<n:
            chunk=conn.recv(n-len(buf))
            if not chunk: return None
            buf+=chunk
        return buf

    def save_setting(self, key, val):
        s=load_settings(); s[key]=val
        with open(SET,"w") as f: yaml.safe_dump(s,f)

def main():
    c=Core()
    def sigterm(*_):
        c.stop.set()
        sys.exit(0)
    signal.signal(signal.SIGTERM, sigterm)
    c.run()

if __name__=="__main__":
    main()
PY
chmod +x "$LED_HOME/core/core.py"

# ---------- App Manager (install/remove/list) ----------
cat > "$LED_HOME/appd/appd.py" <<'PY'
#!/usr/bin/env python3
import os, json, shutil, subprocess, tempfile, time
from pathlib import Path
from flask import Flask, request, jsonify

BASE=Path("/opt/ledmatrix")
REG=BASE/"data/apps/registry/registry.json"
INST=BASE/"data/apps/installed"
STAGE=BASE/"data/apps/staging"

app=Flask(__name__)

def load_registry():
    try:
        return json.loads((REG).read_text())
    except Exception:
        return {"apps":[]}

@app.get("/api/apps/registry")
def api_registry():
    return jsonify(load_registry())

@app.get("/api/apps/installed")
def api_installed():
    out=[]
    for d in INST.glob("*"):
        if (d/"manifest.json").exists():
            try:
                out.append(json.loads((d/"manifest.json").read_text()))
            except: pass
    return jsonify(out)

@app.post("/api/apps/install")
def api_install():
    data=request.get_json(force=True)
    app_id=data.get("app_id")
    version=data.get("version")
    # For "local-bundled", expect folder in staging/<app_id>
    if not app_id:
        return jsonify({"ok":False,"error":"missing app_id"}),400
    dest=INST/app_id
    src=STAGE/app_id
    if not src.exists():
        return jsonify({"ok":False,"error":"bundle not found (local-bundled)"}),404
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)
    return jsonify({"ok":True})

@app.post("/api/apps/remove")
def api_remove():
    data=request.get_json(force=True)
    app_id=data.get("app_id")
    d=INST/app_id
    if d.exists():
        shutil.rmtree(d)
    return jsonify({"ok":True})

if __name__=="__main__":
    app.run(host="127.0.0.1", port=5061)
PY
chmod +x "$LED_HOME/appd/appd.py"

# ---------- Scheduler (runs apps in rotation) ----------
cat > "$LED_HOME/scheduler/scheduler.py" <<'PY'
#!/usr/bin/env python3
import os, sys, time, json, yaml, socket, struct, subprocess
from pathlib import Path

BASE=Path("/opt/ledmatrix")
PLAY=BASE/"data/playlist.yaml"
RUN=BASE/"run"
FRAMEBUS=str(RUN/"framebus.sock")
INST=BASE/"data/apps/installed"

def send_frame_to_core(png_bytes):
    # prefix length + payload over UNIX socket
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(FRAMEBUS)
    s.sendall(struct.pack("!I", len(png_bytes)) + png_bytes)
    s.close()

def run_app(app_dir, duration_sec):
    exe=app_dir/"app.py"
    if not exe.exists():
        return
    env=os.environ.copy()
    env["LEDMATRIX_WIDTH"]="128"
    env["LEDMATRIX_HEIGHT"]="64"
    env["PYTHONUNBUFFERED"]="1"
    # The app writes length-prefixed PNG frames to stdout
    p=subprocess.Popen(
        [sys.executable, str(exe)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env
    )
    # Pass params on stdin
    params=json.dumps({"duration_sec":duration_sec}).encode()
    p.stdin.write(params); p.stdin.close()
    start=time.time()
    try:
        while time.time()-start < duration_sec:
            hdr=p.stdout.read(4)
            if not hdr: break
            (size,) = struct.unpack("!I", hdr)
            buf=p.stdout.read(size)
            if not buf: break
            send_frame_to_core(buf)
    except Exception:
        pass
    finally:
        try: p.terminate()
        except: pass

def main():
    while True:
        try:
            pl=yaml.safe_load(PLAY.read_text())
            slots=pl.get("slots",[])
            if not slots:
                time.sleep(1); continue
            for slot in slots:
                app_id=slot.get("app_id")
                dur=int(slot.get("duration_sec",10))
                app_dir=INST/app_id
                if app_dir.exists():
                    run_app(app_dir, dur)
                else:
                    time.sleep(dur)
        except Exception as e:
            # minimal resilience
            time.sleep(1)

if __name__=="__main__":
    main()
PY
chmod +x "$LED_HOME/scheduler/scheduler.py"

# ---------- Web Configurator (very minimal) ----------
cat > "$LED_HOME/web/web.py" <<'PY'
#!/usr/bin/env python3
import os, yaml, json, socket
from pathlib import Path
from flask import Flask, jsonify, request, render_template_string

BASE=Path("/opt/ledmatrix")
SET=BASE/"data/settings.yaml"
PLAY=BASE/"data/playlist.yaml"

app=Flask(__name__)

HTML = """
<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
<title>LEDMatrix Config</title>
<style>
  body{font-family:system-ui;max-width:900px;margin:32px auto;padding:0 16px;color:#eee;background:#111}
  h1{margin:0 0 16px}
  .card{background:#1b1b1b;border:1px solid #333;border-radius:12px;padding:16px;margin:12px 0}
  input,button,select{padding:8px;border-radius:8px;border:1px solid #444;background:#222;color:#eee}
  label{display:block;margin:8px 0 4px}
  .row{display:flex;gap:12px;align-items:center}
  table{width:100%;border-collapse:collapse}
  td,th{border-bottom:1px solid #333;padding:8px}
</style>
<h1>LEDMatrix Config</h1>

<div class="card">
  <h2>Display</h2>
  <div class="row">
    <label>Brightness (0-1)</label>
    <input id="brightness" type="number" step="0.05" min="0" max="1">
    <button onclick="setBrightness()">Save</button>
  </div>
</div>

<div class="card">
  <h2>Apps</h2>
  <div id="apps"></div>
</div>

<div class="card">
  <h2>Playlist</h2>
  <table id="playlist"></table>
  <div class="row">
    <input id="new_app" placeholder="app_id (e.g., sys.clock)">
    <input id="new_dur" type="number" value="10">
    <button onclick="addSlot()">Add</button>
    <button onclick="savePlaylist()">Save Playlist</button>
  </div>
</div>

<script>
async function load(){
  let s=await fetch('/api/display/settings').then(r=>r.json());
  document.getElementById('brightness').value=s.brightness ?? 0.8;
  let r=await fetch('/api/apps/registry').then(r=>r.json());
  let i=await fetch('/api/apps/installed').then(r=>r.json());
  let div=document.getElementById('apps'); div.innerHTML='';
  r.apps.forEach(a=>{
    let installed = i.find(x=>x.id===a.id);
    let btn = installed ? `<button onclick="removeApp('${a.id}')">Remove</button>` :
                          `<button onclick="installApp('${a.id}','${a.version}')">Install</button>`;
    div.innerHTML += `<div class="row"><div style="flex:1">
      <b>${a.name}</b> <small>(${a.id} v${a.version})</small><br>${a.description}
      </div>${btn}</div>`;
  });
  let pl=await fetch('/api/playlist').then(r=>r.json());
  let t=document.getElementById('playlist');
  t.innerHTML='<tr><th>#</th><th>App</th><th>Duration</th><th></th></tr>';
  pl.slots.forEach((s,idx)=>{
    t.innerHTML += `<tr><td>${idx+1}</td><td>${s.app_id}</td><td>${s.duration_sec}s</td>
    <td><button onclick="delSlot(${idx})">Delete</button></td></tr>`;
  });
}
async function setBrightness(){
  let v=parseFloat(document.getElementById('brightness').value);
  await fetch('/api/display/brightness',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({value:v})});
  alert('Saved');
}
async function installApp(id,ver){
  await fetch('/api/apps/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({app_id:id,version:ver})});
  load();
}
async function removeApp(id){
  await fetch('/api/apps/remove',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({app_id:id})});
  load();
}
async function savePlaylist(){
  let rows=[...document.querySelectorAll('#playlist tr')].slice(1);
  let slots=rows.map(r=>{
    let t=r.children;
    return {app_id:t[1].innerText, duration_sec:parseInt(t[2].innerText)};
  });
  await fetch('/api/playlist',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({slots})});
  alert('Playlist saved');
}
async function addSlot(){
  let id=document.getElementById('new_app').value.trim();
  let d=parseInt(document.getElementById('new_dur').value);
  let t=document.getElementById('playlist');
  t.innerHTML += `<tr><td>*</td><td>${id}</td><td>${d}</td><td><button onclick="this.closest('tr').remove()">Delete</button></td></tr>`;
}
async function delSlot(idx){
  let t=document.getElementById('playlist');
  t.deleteRow(idx+1);
}
load();
</script>
"""

def load_yaml(p):
    try: return yaml.safe_load(Path(p).read_text()) or {}
    except: return {}

def save_yaml(p, data):
    Path(p).write_text(yaml.safe_dump(data))

@app.get("/")
def home():
    return render_template_string(HTML)

@app.get("/api/display/settings")
def api_get_settings():
    return load_yaml(SET)

@app.post("/api/display/brightness")
def api_set_brightness():
    v=request.json.get("value",1.0)
    s=load_yaml(SET); s["brightness"]=float(v)
    save_yaml(SET,s)
    # ping core
    try:
        import json, socket
        CORECTL="/opt/ledmatrix/run/corectl.sock"
        c=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(CORECTL)
        c.sendall(json.dumps({"cmd":"set_brightness","value":float(v)}).encode()); c.close()
    except Exception:
        pass
    return {"ok":True}

@app.get("/api/playlist")
def api_get_playlist():
    return load_yaml(PLAY)

@app.post("/api/playlist")
def api_set_playlist():
    slots=request.json.get("slots",[])
    save_yaml(PLAY, {"slots":slots})
    return {"ok":True}

# proxy minimal appd endpoints (both run on same host)
import requests
@app.get("/api/apps/registry")
def proxy_reg():
    return requests.get("http://127.0.0.1:5061/api/apps/registry").json()

@app.get("/api/apps/installed")
def proxy_inst():
    return requests.get("http://127.0.0.1:5061/api/apps/installed").json()

@app.post("/api/apps/install")
def proxy_install():
    r=requests.post("http://127.0.0.1:5061/api/apps/install", json=request.json)
    return (r.text, r.status_code, r.headers.items())

@app.post("/api/apps/remove")
def proxy_remove():
    r=requests.post("http://127.0.0.1:5061/api/apps/remove", json=request.json)
    return (r.text, r.status_code, r.headers.items())

if __name__=="__main__":
    from waitress import serve
    serve(app, host="0.0.0.0", port=5001)
PY
chmod +x "$LED_HOME/web/web.py"

# ---------- Sample App: sys.clock ----------
mkdir -p "$LED_HOME/data/apps/staging/sys.clock"
cat > "$LED_HOME/data/apps/staging/sys.clock/manifest.json" <<'JSON'
{
  "id": "sys.clock",
  "name": "System Clock",
  "version": "1.0.0",
  "entrypoint": "app.py",
  "display_mode": "frames",
  "frame_size": "128x64"
}
JSON

cat > "$LED_HOME/data/apps/staging/sys.clock/app.py" <<'PY'
#!/usr/bin/env python3
import sys, json, time, struct
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont

def write_png(img):
    # output as length-prefixed PNG to stdout
    b=BytesIO(); img.save(b, format="PNG"); blob=b.getvalue()
    sys.stdout.buffer.write(struct.pack("!I", len(blob)))
    sys.stdout.buffer.write(blob)
    sys.stdout.flush()

def render(w,h,tick):
    img=Image.new("RGB",(w,h))
    d=ImageDraw.Draw(img)
    # Basic font: PIL default or FreeSans if present
    try:
        f=ImageFont.truetype("/usr/share/fonts/truetype/freefont/FreeSans.ttf", 28)
    except:
        f=ImageFont.load_default()
    s=time.strftime("%H:%M:%S")
    tw,th=d.textsize(s,font=f)
    d.text(((w-tw)//2,(h-th)//2), s, fill=(255,255,255), font=f)
    return img

if __name__=="__main__":
    params=json.loads(sys.stdin.read() or "{}")
    duration=params.get("duration_sec",10)
    w=int(sys.argv[1]) if len(sys.argv)>1 else 128
    h=int(sys.argv[2]) if len(sys.argv)>2 else 64
    end=time.time()+duration
    tick=0
    while time.time() < end:
        img=render(w,h,tick)
        write_png(img)
        time.sleep(0.25)
        tick+=1
PY
chmod +x "$LED_HOME/data/apps/staging/sys.clock/app.py"

# ---------- systemd services ----------
cat > /etc/systemd/system/ledmatrix-core.service <<'UNIT'
[Unit]
Description=LEDMatrix Core Renderer
After=network-online.target
Wants=network-online.target

[Service]
User=ledpi
Group=ledpi
WorkingDirectory=/opt/ledmatrix/core
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/ledmatrix/venv/bin/python /opt/ledmatrix/core/core.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/ledmatrix-appd.service <<'UNIT'
[Unit]
Description=LEDMatrix App Manager API
After=network-online.target
Wants=network-online.target

[Service]
User=ledpi
Group=ledpi
WorkingDirectory=/opt/ledmatrix/appd
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/ledmatrix/venv/bin/python /opt/ledmatrix/appd/appd.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/ledmatrix-scheduler.service <<'UNIT'
[Unit]
Description=LEDMatrix Scheduler
After=ledmatrix-core.service ledmatrix-appd.service
Requires=ledmatrix-core.service ledmatrix-appd.service

[Service]
User=ledpi
Group=ledpi
WorkingDirectory=/opt/ledmatrix/scheduler
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/ledmatrix/venv/bin/python /opt/ledmatrix/scheduler/scheduler.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/ledmatrix-web.service <<'UNIT'
[Unit]
Description=LEDMatrix Web Configurator
After=network-online.target
Wants=network-online.target

[Service]
User=ledpi
Group=ledpi
WorkingDirectory=/opt/ledmatrix/web
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/ledmatrix/venv/bin/python /opt/ledmatrix/web/web.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

echo "[5/12] Permissions..."
chown -R "$LED_USER:$LED_GROUP" "$LED_HOME"
chmod -R 755 "$LED_HOME"
chmod 770 "$LED_HOME/run" || true

echo "[6/12] Enable services..."
systemctl daemon-reload
systemctl enable ledmatrix-core.service ledmatrix-appd.service ledmatrix-scheduler.service ledmatrix-web.service
systemctl restart ledmatrix-core.service ledmatrix-appd.service ledmatrix-scheduler.service ledmatrix-web.service

echo "[7/12] Installing bundled app (sys.clock)..."
# Use appd to install the bundled app into 'installed'
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"app_id":"sys.clock","version":"1.0.0"}' \
  http://127.0.0.1:5061/api/apps/install >/dev/null || true

echo "[8/12] Final touches..."
# Make sure locale/timezone defaults won't block
timedatectl set-timezone America/Chicago || true

echo "[9/12] Quick status:"
systemctl --no-pager --full status ledmatrix-core.service | sed -n '1,12p' || true
systemctl --no-pager --full status ledmatrix-web.service  | sed -n '1,12p' || true

echo "[10/12] Where things live:"
echo "  Web UI:          http://<PI-IP>:$WEB_PORT"
echo "  Core logs:       $LED_HOME/logs/core.log"
echo "  Apps registry:   $LED_HOME/data/apps/registry/registry.json"
echo "  Installed apps:  $LED_HOME/data/apps/installed/"
echo "  Playlist:        $LED_HOME/data/playlist.yaml"
echo "  Settings:        $LED_HOME/data/settings.yaml"

echo "[11/12] If you see the clock:"
echo "  You're done. Use the Web UI to change brightness, install/remove apps, and edit playlist."

echo "[12/12] Done."
