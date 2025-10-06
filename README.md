# rallyboard
Rallyboard

On a freshly imaged pi, ssh in and copy the script
Run the script with sudo bash install_ledmatrix_stack.sh

What you get out of the box

Core listens on a UNIX socket (framebus.sock) for length-prefixed PNG frames and draws them to the LED panels via rpi-rgb-led-matrix.

Scheduler reads playlist.yaml, launches each app for its duration_sec, and forwards frames to the Core.

App Manager (localhost API) lets the Web UI install/remove apps from a local registry (bundled sys.clock now; you can add more later).

Web Configurator (http://pi:5001
) lets you:

Set brightness

Install/Remove apps from the registry

Edit and save playlist (app order + durations)

Add more apps later

Create a folder under /opt/ledmatrix/data/apps/staging/<your.app.id>/ with:

manifest.json (id, name, version, entrypoint)

app.py that writes length-prefixed PNGs to stdout (template matches the clock app)

Any assets your app needs

Add an entry to /opt/ledmatrix/data/apps/registry/registry.json with "download": "local-bundled".

From the Web UI, Install the app, then add it to the Playlist.

Panel/HAT tweaks

Change /opt/ledmatrix/data/settings.yaml → panel.* values:

hardware_mapping (e.g., "regular", "adafruit-hat", "adafruit-hat-pwm")

chain_length, parallel, gpio_slowdown, etc.
Then either reboot or send a reload via:

printf '{"cmd":"reload"}' | socat - UNIX-CONNECT:/opt/ledmatrix/run/corectl.sock
