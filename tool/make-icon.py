#!/usr/bin/env python3
"""Draws the Group Play icon (ink rings on paper) and writes every iOS and Android size.

    python3 tool/make-icon.py
"""
import math
import pathlib
import re

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "group_play"
PAPER = (241, 243, 243, 255)
INK = (13, 26, 30, 255)
FAINT = (190, 199, 202, 255)


def master(size=1024, ss=4):
    s = size * ss
    img = Image.new("RGBA", (s, s), PAPER)
    d = ImageDraw.Draw(img)
    c = s / 2

    def ring(r, w, col):
        d.ellipse([c - r, c - r, c + r, c + r], outline=col, width=int(w))

    ring(s * 0.42, s * 0.012, FAINT)
    ring(s * 0.315, s * 0.012, FAINT)
    ring(s * 0.205, s * 0.03, INK)
    r = s * 0.06
    d.ellipse([c - r, c - r, c + r, c + r], fill=INK)
    # three "phones" on the ink ring
    for a in (-90, 30, 150):
        rad = math.radians(a)
        x, y = c + math.cos(rad) * s * 0.205, c + math.sin(rad) * s * 0.205
        w, h = s * 0.055, s * 0.095
        d.rounded_rectangle([x - w / 2, y - h / 2, x + w / 2, y + h / 2], radius=s * 0.016, fill=INK)
    return img.resize((size, size), Image.LANCZOS)


def main():
    m = master()
    # iOS: every file in the app icon set, sized from its name (e.g. Icon-App-20x20@3x.png)
    ios = APP / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for f in ios.glob("*.png"):
        mt = re.search(r"(\d+(?:\.\d+)?)x\1@(\d)x", f.name)
        if not mt:
            continue
        px = round(float(mt.group(1)) * int(mt.group(2)))
        m.resize((px, px), Image.LANCZOS).convert("RGB").save(f)
    # Android legacy launcher icons
    for folder, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        out = APP / "android" / "app" / "src" / "main" / "res" / f"mipmap-{folder}" / "ic_launcher.png"
        m.resize((px, px), Image.LANCZOS).save(out)
    m.convert("RGB").save(ROOT / "docs" / "icon-1024.png") if (ROOT / "docs").exists() else None
    print("icons written")


if __name__ == "__main__":
    main()
