#!/usr/bin/env python3
"""Draws the C64 app icon (MacMiga's wavy rainbow background, pixel "C64") and writes Resources/AppIcon.icns.
Usage: python3 scripts/make-icon.py   (needs Pillow and macOS iconutil)"""
import math, os, shutil, subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources")
S = 1024

GLYPHS = {
    "C": ["..####..", ".##..##.", ".##.....", ".##.....", ".##.....", ".##..##.", "..####..", "........"],
    "6": ["...###..", "..##....", ".##.....", ".#####..", ".##..##.", ".##..##.", "..####..", "........"],
    "4": ["....##..", "...###..", "..####..", ".##.##..", ".######.", "....##..", "....##..", "........"],
}
# The 12 bands of MacMiga's icon (MacMiga/Bundle/MakeIcon.swift), top to bottom, as sRGB:
# hue i/12*0.8, saturation 0.9, at brightness 0.55 (band edges) and 1.0 (band middle).
BANDS = [
    ((0.626, 0.112, 0.059), (1.000, 0.206, 0.124)), ((0.624, 0.326, 0.058), (1.000, 0.541, 0.122)),
    ((0.621, 0.520, 0.056), (1.000, 0.845, 0.118)), ((0.523, 0.608, 0.056), (0.849, 0.983, 0.119)),
    ((0.308, 0.606, 0.059), (0.514, 0.979, 0.123)), ((0.000, 0.604, 0.060), (0.000, 0.977, 0.125)),
    ((0.000, 0.606, 0.321), (0.000, 0.981, 0.534)), ((0.000, 0.611, 0.526), (0.000, 0.987, 0.855)),
    ((0.000, 0.524, 0.619), (0.000, 0.852, 1.000)), ((0.048, 0.334, 0.620), (0.106, 0.554, 1.000)),
    ((0.069, 0.135, 0.620), (0.139, 0.242, 1.000)), ((0.326, 0.142, 0.620), (0.541, 0.254, 1.000)),
]


def rainbow(k=2):
    """MacMiga's background, drawn at k times the size: wavy bands, each dark at its edges and bright in the
    middle, under a gloss (white at 18% at the top to black at 18% at the bottom). Works in MacMiga's
    coordinates (y up, body 100...924); a pixel below the last band stays black, as there."""
    n, bh = len(BANDS), (824 + 120) / len(BANDS)
    # Colour of band i at each row: depends only on the row.
    table = []
    for i, (dark, bright) in enumerate(BANDS):
        top = 984 - bh * i + 30
        rows = []
        for Y in range(S * k):
            y = (S * k - Y - 0.5) / k
            t = min(max((top - y) / (bh + 60), 0), 1)
            f = t * 2 if t < 0.5 else (1 - t) * 2
            g = min(max((924 - y) / 824, 0), 1)
            rows.append(bytes(round(255 * ((d + (b - d) * f) * 0.82 + (1 - g) * 0.18)) for d, b in zip(dark, bright)))
        table.append(rows)
    black = bytes(3)
    data = bytearray(S * k * S * k * 3)
    for X in range(100 * k, 924 * k):
        x = (X + 0.5) / k
        t = (x - 100) / 824
        edges = [984 - bh * i + 26 * math.sin(t * 2 * math.pi * 1.2 + i * 0.35) for i in range(n + 1)]
        i = 0
        for Y in range(100 * k, 924 * k):
            y = (S * k - Y - 0.5) / k
            while i < n and y <= edges[i + 1]:
                i += 1
            p = (Y * S * k + X) * 3
            data[p:p + 3] = table[i][Y] if i < n else black
    return Image.frombytes("RGB", (S * k, S * k), bytes(data)).resize((S, S), Image.LANCZOS)


def icon():
    bg = rainbow()

    # macOS icon grid: 824x824 rounded square centred on a 1024 canvas, with MacMiga's drop shadow
    # (black at 45%, 12 px down, blur 28).
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([100, 100, 923, 923], radius=185, fill=255)
    shadow = Image.new("L", (S, S), 0)
    shadow.paste(mask, (0, 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: v * 45 // 100)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.putalpha(shadow)
    img.paste(bg, (0, 0), mask)

    # Pixel "C64": each glyph trimmed to its ink columns, 1 pixel apart, 38 px per pixel, with a dark drop shadow.
    px = 38
    cols = {ch: [c for c in range(8) if any(row[c] == "#" for row in GLYPHS[ch])] for ch in "C64"}
    starts, x0 = [], 0
    for ch in "C64":
        starts.append(x0)
        x0 += len(cols[ch]) + 1
    w, h = (x0 - 1) * px, 8 * px
    ox, oy = (S - w) // 2, (S - h) // 2 + px // 2
    text = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(text)
    for off, col in (((12, 14), (0, 0, 0, 190)), ((0, 0), (255, 255, 255, 255))):
        for ci, ch in enumerate("C64"):
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
