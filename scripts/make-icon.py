#!/usr/bin/env python3
"""Draws the C64 app icon (rainbow background, pixel "c64") and writes Resources/AppIcon.icns.
Usage: python3 scripts/make-icon.py   (needs Pillow and macOS iconutil)"""
import os, shutil, subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources")
S = 1024

GLYPHS = {
    "c": ["........", "........", "..####..", ".##.....", ".##.....", ".##.....", "..####..", "........"],
    "6": ["...###..", "..##....", ".##.....", ".#####..", ".##..##.", ".##..##.", "..####..", "........"],
    "4": ["....##..", "...###..", "..####..", ".##.##..", ".######.", "....##..", "....##..", "........"],
}
RAINBOW = [(150, 20, 35), (160, 80, 15), (160, 130, 20), (30, 115, 50), (20, 85, 150), (65, 40, 135), (125, 30, 115)]


def icon():
    # Rainbow: diagonal bands across the whole canvas.
    bg = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(bg)
    band = S * 2 // len(RAINBOW) + 1
    for i, c in enumerate(RAINBOW):
        x = -S + i * band
        d.polygon([(x, S), (x + band, S), (x + band + S, 0), (x + S, 0)], fill=c)
    bg = bg.filter(ImageFilter.GaussianBlur(18))

    # macOS icon grid: 824x824 rounded square centred on a 1024 canvas.
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([100, 100, 923, 923], radius=185, fill=255)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(bg, (0, 0), mask)

    # Pixel "c64": each glyph trimmed to its ink columns, 1 pixel apart, 38 px per pixel, with a dark drop shadow.
    px = 38
    cols = {ch: [c for c in range(8) if any(row[c] == "#" for row in GLYPHS[ch])] for ch in "c64"}
    starts, x0 = [], 0
    for ch in "c64":
        starts.append(x0)
        x0 += len(cols[ch]) + 1
    w, h = (x0 - 1) * px, 8 * px
    ox, oy = (S - w) // 2, (S - h) // 2 + px // 2
    text = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(text)
    for off, col in (((12, 14), (0, 0, 0, 190)), ((0, 0), (255, 255, 255, 255))):
        for ci, ch in enumerate("c64"):
            for r, row in enumerate(GLYPHS[ch]):
                for k, c in enumerate(cols[ch]):
                    if row[c] == "#":
                        x = ox + (starts[ci] + k) * px + off[0]
                        y = oy + r * px + off[1]
                        td.rectangle([x, y, x + px - 1, y + px - 1], fill=col)
    img.alpha_composite(text)
    return img


def main():
    img = icon()
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, "AppIcon.png"))
    iconset = "/tmp/AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        img.resize((size, size), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}.png")
        img.resize((size * 2, size * 2), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
    print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
