#!/usr/bin/env python3
"""Render Pine's app icon (the day glyph on pine green) into the asset catalog.

The mark is the home screen's day glyph: outer ring = activity, middle ring =
the two strength halves, centre dot = posture, here in warm gold. Drawn at 4x
and downsampled so every size stays crisp. Requires Pillow.

    python3 ios/scripts/make-icon.py [--preview out.png]
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
SS = 4
BIG = 1024 * SS

TOP, BOTTOM = (0x3B, 0x80, 0x5C), (0x1C, 0x48, 0x33)
CREAM = (0xF5, 0xF2, 0xE6)
GOLD = (0xE6, 0xBC, 0x5C)


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def arc(draw, center, diameter, width, start, end, color):
    """Clockwise arc from `start` to `end` degrees (0 = 12 o'clock), round caps."""
    cx, cy = center
    r = diameter / 2
    box = (cx - r, cy - r, cx + r, cy + r)
    draw.arc(box, start - 90, end - 90, fill=color, width=round(width))
    for angle in (start, end):
        a = math.radians(angle - 90)
        x, y = cx + (r - width / 2) * math.cos(a), cy + (r - width / 2) * math.sin(a)
        draw.ellipse((x - width / 2, y - width / 2, x + width / 2, y + width / 2), fill=color)


def render():
    image = Image.new("RGB", (BIG, BIG))
    pixels = image.load()
    # Diagonal gradient, lighter top-left.
    for y in range(0, BIG, SS):
        for x in range(0, BIG, SS):
            color = mix(TOP, BOTTOM, min(1, (0.35 * x + 0.65 * y) / BIG))
            for dy in range(SS):
                for dx in range(SS):
                    pixels[x + dx, y + dy] = color
    draw = ImageDraw.Draw(image)
    unit = 8.2 * SS
    center = (BIG / 2, BIG / 2)
    track = mix(TOP, BOTTOM, 0.5)
    track = mix(track, CREAM, 0.16)
    # Outer ring: track plus most of a lap.
    arc(draw, center, 72 * unit, 8 * unit, 0, 359.9, track)
    arc(draw, center, 72 * unit, 8 * unit, 0, 300, CREAM)
    # Middle ring: two halves meeting as one circle.
    r = 42 * unit / 2
    draw.ellipse((center[0] - r, center[1] - r, center[0] + r, center[1] + r), outline=CREAM, width=round(7 * unit))
    # Centre dot in gold.
    d = 18 * unit / 2
    draw.ellipse((center[0] - d, center[1] - d, center[0] + d, center[1] + d), fill=GOLD)
    return image


def main():
    big = render()
    if "--preview" in sys.argv:
        big.resize((1024, 1024), Image.LANCZOS).save(sys.argv[sys.argv.index("--preview") + 1])
        return
    images = []
    sizes = [(s, k, "iphone") for s in (20, 29, 40, 60) for k in (2, 3)] + [(1024, 1, "ios-marketing")]
    for size, scale, idiom in sizes:
        name = f"icon-{size}@{scale}x.png"
        big.resize((size * scale, size * scale), Image.LANCZOS).save(FOLDER / name, optimize=True)
        images.append({"filename": name, "idiom": idiom, "scale": f"{scale}x", "size": f"{size}x{size}"})
    path = FOLDER / "Contents.json"
    current = json.loads(path.read_text()) if path.exists() else {}
    if current.get("images") != images:
        contents = {"images": images, "info": {"author": "xcode", "version": 1}}
        path.write_text(json.dumps(contents, indent=2, sort_keys=True) + "\n")
    print("Generated opaque iPhone app icons.")


if __name__ == "__main__":
    main()
