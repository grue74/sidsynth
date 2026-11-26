# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""SID500's icon: docs/favicon.svg, docs/favicon-32.png, docs/apple-touch-icon.png.

    python docs/icon.py

A piano roll, a sequencer's picture: four white note bars at different
pitches and times on the page's blue. The SVG and the PNGs come from the
same shapes: the PNGs are drawn with Pillow (no SVG renderer needed) at 16
times the size and scaled down. SID101's docs/icon.py is the model.
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

BLUE = "#2a5fc4"                 # the background (the page's blue)
WHITE = "#ffffff"
RADIUS = 7                       # the rounded corners, in the 32x32 view
BAR_H = 3.6                      # a note bar's height
# the notes: (start x, end x, middle y) in the 32x32 view, low to high in time
NOTES = [(5, 13, 22), (12, 20, 15), (19, 27, 9), (22, 27, 22)]

SVG_BARS = "\n".join(
    f'  <rect x="{x0}" y="{y - BAR_H / 2:g}" width="{x1 - x0}" height="{BAR_H}" '
    f'rx="{BAR_H / 2:g}" fill="{WHITE}"/>' for x0, x1, y in NOTES)
SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <!-- SID500's icon: a piano roll, a sequencer's notes, on the page's blue (docs/icon.py) -->
  <rect width="32" height="32" rx="{RADIUS}" fill="{BLUE}"/>
{SVG_BARS}
</svg>
"""


def png(size, path):
    """The icon at size x size pixels: drawn at 16x, scaled down."""
    big = size * 16
    s = big / 32                 # pixels per view unit
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, big - 1, big - 1), radius=RADIUS * s, fill=BLUE)
    for x0, x1, y in NOTES:
        d.rounded_rectangle((x0 * s, (y - BAR_H / 2) * s, x1 * s, (y + BAR_H / 2) * s),
                            radius=BAR_H / 2 * s, fill=WHITE)
    im.resize((size, size), Image.LANCZOS).save(path)


def main():
    with open(os.path.join(HERE, "favicon.svg"), "w", encoding="utf-8", newline="") as f:
        f.write(SVG)
    png(32, os.path.join(HERE, "favicon-32.png"))
    png(180, os.path.join(HERE, "apple-touch-icon.png"))
    print("docs/favicon.svg, favicon-32.png, apple-touch-icon.png written")


if __name__ == "__main__":
    main()
