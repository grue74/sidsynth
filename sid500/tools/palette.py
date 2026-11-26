"""palette.py - SID500 stage B: the channel colours' test screen.

Writes palette.prg: a C64 program that shows the proposed colour of each
MIDI channel on SID500's black screen (docs/plan.md "Colour: the
channels"): each channel's number and a sample cell, normally, in reverse
video (the cursor and the playing step) and muted (dark grey); a few rows
of a song grid in those colours; and all the C64's colours as swatches,
for choosing others. Captured with ../c64tools/vicecap.py for the user to
judge (the palette is chosen with the user before it is used anywhere).

    python tools/palette.py [--shot palette.png]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")

NAMES = ["black", "white", "red", "cyan", "purple", "green", "blue", "yellow", "orange",
         "brown", "light red", "dark grey", "grey", "light green", "light blue", "light grey"]
MUTED = 11                      # dark grey: muted tracks (docs/plan.md)

# The palette (the user, 2026-11-20: no dim colours): channel 1-16 -> C64
# colour. The 12 clearly readable colours first, neighbours unlike each
# other, channel 10 (drums by General MIDI) white; channels 13-16 repeat
# colours of channels at least four away (a song rarely uses all 16): blue
# and brown left out, too dim on black.
PROPOSAL = [2, 8, 7, 13, 3, 14, 4, 10, 5, 1, 15, 12, 3, 4, 2, 13]


def screen_code(ch):
    """An ASCII character's screen code in the C64's upper case set."""
    o = ord(ch.upper())
    if 64 <= o <= 95:
        return o - 64
    return o


def build(palette):
    scr = [32] * 1000
    col = [1] * 1000

    def put(row, x, text, colour, reverse=False):
        for i, ch in enumerate(text):
            scr[row * 40 + x + i] = screen_code(ch) | (0x80 if reverse else 0)
            col[row * 40 + x + i] = colour

    put(0, 0, "SID500 CHANNEL COLOURS", 1)
    put(1, 0, "CH COLOUR       NORMAL  CURSOR  MUTED", 12)
    for ch in range(16):
        c = palette[ch]
        row = 2 + ch
        put(row, 0, f"{ch + 1:2d}", c)
        put(row, 3, NAMES[c].upper()[:11], c)
        put(row, 16, "C-4 100", c)
        put(row, 24, "C-4 100", c, reverse=True)
        put(row, 32, "C-4 100", MUTED)
    # a song grid: 8 tracks across, three scenes down, one track muted,
    # the cursor on one cell
    put(19, 0, "SONG", 12)
    for t in range(8):
        put(19, 5 + t * 4, f"T{t + 1}", palette[t])
    for scene in range(3):
        row = 20 + scene
        put(row, 0, f"S{scene + 1}", 12)
        for t in range(8):
            text = f"{(scene * 8 + t) % 32 + 1:02d}"
            muted = t == 5
            put(row, 5 + t * 4, text, MUTED if muted else palette[t],
                reverse=(scene == 1 and t == 2))
    # every colour, numbered, as a swatch
    put(24, 0, "ALL", 12)
    for c in range(1, 16):
        put(24, 4 + (c - 1) * 2, f"{c:X}", c, reverse=True)
    return scr, col


def write_prg(path, scr, col):
    # BASIC stub: 10 SYS 2061
    stub = [0x0B, 0x08, 0x0A, 0x00, 0x9E] + [ord(c) for c in "2061"] + [0, 0, 0]
    data_at = 0x0801 + len(stub) + 96           # (after the code, below)
    code = []

    def op(*b):
        code.extend(b)

    # sei; black border and background; copy 4 pages of screen and colour
    op(0x78)
    op(0xA9, 0x00, 0x8D, 0x20, 0xD0, 0x8D, 0x21, 0xD0)
    op(0xA9, 0x15, 0x8D, 0x18, 0xD0)            # the upper case set
    op(0xA2, 0x00)                              # ldx #0
    loop = 0x0801 + len(stub) + len(code)
    for page in range(4):
        s = data_at + page * 256
        c = data_at + 1024 + page * 256         # (the screen padded to 1024)
        op(0xBD, s & 255, s >> 8, 0x9D, 0x00, 0x04 + page)       # lda scr,x; sta $0400+,x
        op(0xBD, c & 255, c >> 8, 0x9D, 0x00, 0xD8 + page)       # lda col,x; sta $d800+,x
    op(0xE8, 0xD0, (loop - (0x0801 + len(stub) + len(code) + 3)) & 255)   # inx; bne loop
    here = 0x0801 + len(stub) + len(code)
    op(0x4C, here & 255, here >> 8)             # jmp *
    assert len(code) <= 96
    code += [0] * (96 - len(code))
    # pad to 1024 each so the last page's copy stays in the data
    body = stub + code + scr + [32] * 24 + col + [1] * 24
    with open(path, "wb") as f:
        f.write(bytes([0x01, 0x08] + body))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot", default=None, help="also capture it in VICE to this PNG")
    a = ap.parse_args()
    prg = os.path.join(ROOT, "palette.prg")
    write_prg(prg, *build(PROPOSAL))
    print(f"wrote {prg}")
    for ch, c in enumerate(PROPOSAL):
        print(f"  channel {ch + 1:2d}: {NAMES[c]}")
    if a.shot:
        subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicecap.py"), prg, a.shot,
                        "--seconds", "8"], check=True)
        print(f"captured {a.shot}")


if __name__ == "__main__":
    main()
