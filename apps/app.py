#!/usr/bin/env python3
import sys, json, time, struct
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont

W, H = 128, 64

def send(img):
    b=BytesIO(); img.save(b, "PNG")
    blob=b.getvalue()
    sys.stdout.buffer.write(struct.pack("!I", len(blob)))
    sys.stdout.buffer.write(blob)
    sys.stdout.flush()

def main():
    params=json.loads(sys.stdin.read() or "{}")
    end=time.time()+params.get("duration_sec",10)
    try:
        font=ImageFont.truetype("/usr/share/fonts/truetype/freefont/FreeSans.ttf", 28)
    except:
        font=ImageFont.load_default()
    while time.time() < end:
        img=Image.new("RGB",(W,H))
        d=ImageDraw.Draw(img)
        s=time.strftime("%H:%M:%S")
        tw,th=d.textsize(s,font=font)
        d.text(((W-tw)//2,(H-th)//2), s, fill=(255,255,255), font=font)
        send(img)
        time.sleep(0.25)

if __name__=="__main__":
    main()
