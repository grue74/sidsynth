# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""SID101's icon: docs/favicon.svg, docs/favicon-32.png, docs/apple-touch-icon.png.

    python docs/icon.py

A white sawtooth, the lead's wave, on the SH-101's blue. The SVG and the
PNGs come from the same shape: the PNGs are drawn with Pillow (no SVG
renderer needed) at 16 times the size and scaled down.
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

BLUE = "#2a5fc4"                 # the background (the SH-101's blue)
WHITE = "#ffffff"
RADIUS = 7                       # the rounded corners, in the 32x32 view
STROKE = 2.6                     # the wave's line width
# the sawtooth: three teeth, each a slow rise and a drop
WAVE = [(4, 22), (12, 10), (12, 22), (20, 10), (20, 22), (28, 10), (28, 22)]

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <!-- SID101's icon: a sawtooth, the lead's wave, on the SH-101's blue (docs/icon.py) -->
  <rect width="32" height="32" rx="{RADIUS}" fill="{BLUE}"/>
  <path d="M{' L'.join(f'{x} {y}' for x, y in WAVE)}" fill="none" stroke="{WHITE}"
        stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""


def png(size, path):
    """The icon at size x size pixels: drawn at 16x, scaled down."""
    big = size * 16
    s = big / 32                 # pixels per view unit
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, big - 1, big - 1), radius=RADIUS * s, fill=BLUE)
    w = STROKE * s
    pts = [(x * s, y * s) for x, y in WAVE]
    d.line(pts, fill=WHITE, width=round(w))
    for x, y in pts:             # round caps and joins
        d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=WHITE)
    im.resize((size, size), Image.LANCZOS).save(path)


def main():
    with open(os.path.join(HERE, "favicon.svg"), "w", encoding="utf-8", newline="") as f:
        f.write(SVG)
    png(32, os.path.join(HERE, "favicon-32.png"))
    png(180, os.path.join(HERE, "apple-touch-icon.png"))
    print("docs/favicon.svg, favicon-32.png, apple-touch-icon.png written")


if __name__ == "__main__":
    main()
