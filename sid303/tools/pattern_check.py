# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check MIDI pattern select (CC 85), song select and song position in
VICE (docs/sequencer.md, MIDI control; the core's PATTERN_CC, MIDI_SYSTEM).

    python tools/pattern_check.py [--keep DIR]

Each test is a TEST_LOG build of sid303.asm with TEST_MIDI=99 and a MIDI
feed of its own: a wrapper source (in the work folder) that includes
sid303.asm and puts the feed after it as test_pattern. The patterns are
TEST_EDGES=2's SHORT1 (pattern 1, 6 steps) and SHORT2 (pattern 2, 5
steps), the song TEST_SONG=1's (3 entries: repeats, transposes +5 and
-12; 23 steps). The note log is compared with tools/seq_check.py's model
(its switch and locate arguments):

1. CC 85 on the synth's channel (2) while pattern 1 plays (internal
   clock): pattern 1 ends its pass, then pattern 2 loops.
2. The same CC in omni, on another channel, and with value 64: ignored.
3. CC 85 while the song plays: song mode off, the entry's pass ends (no
   more repeats), pattern 2 loops untransposed.
4. MIDI clock: CC 85 while stopped, then start: pattern 2 from its start.
5. Song position, pattern mode: continue plays from the step (modulo the
   length).
6. Song position, song mode: positions in each entry, a repeat, a
   transposed entry, and past the end (wrapping).
7. Song position then start: from the start. While playing: ignored.
8. CC 85 (song mode off), song select (on again), start: the song plays.

Exit status 0 when every check passes.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import tables  # noqa: E402
from seq_check import model, run_log, compare, relative  # noqa: E402

CHANNEL = 2                         # TEST_CHANNEL: the synth's MIDI channel
CC = 0xB0 | (CHANNEL - 1)
CLOCK = 5                           # ticks between MIDI clocks (125 BPM: 6 a step of 30)
PATS = [tables.SHORT1, tables.SHORT2]
SONG = [(PATS[p], rep, tr) for p, rep, tr in tables.SONG_TEST]


def feed_source(events, end):
    """The test_pattern bytes for [(tick, [bytes])] (core/test_feed.asm:
    count, bytes, ticks to the next - 1), active sensing ($FE, ignored)
    bridging waits over 256 ticks, up to tick `end` (then it restarts)."""
    entries = [(0, [0xFE])] + sorted(events, key=lambda e: e[0])
    filled = []
    for i, (t, b) in enumerate(entries):
        filled.append((t, b))
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        while nxt - filled[-1][0] > 256:
            filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    lines = ["test_pattern"]
    for i in range(0, len(data), 16):
        lines.append("        .byte " + ", ".join(f"${b:02x}" for b in data[i:i + 16]))
    return "\n".join(lines) + "\n"


def build(work, name, defines, events, end=60 * 250):
    """A wrapper source with the feed, assembled with TEST_LOG, TEST_MIDI=99."""
    asm = os.path.join(work, name + ".asm")
    with open(asm, "w", newline="\n") as f:
        f.write(f'        .include "{os.path.join(ROOT, "sid303.asm").replace(os.sep, "/")}"\n')
        f.write(feed_source(events, end))
    prg = os.path.join(work, name + ".prg")
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "-Wno-portable", "--cbm-prg", "-D", "TEST_LOG=1", "-D", "TEST_MIDI=99",
            "-D", "TEST_EDGES=2", "-I", ROOT]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", prg + ".lbl", "-o", prg, asm], cwd=ROOT, check=True)
    return prg


def clocks(start, count):
    """MIDI clocks every CLOCK ticks from tick start: [(tick, [$F8])]."""
    return [(start + i * CLOCK, [0xF8]) for i in range(count)]


def spp(pos):
    """A song position message: $F2, LSB, MSB."""
    return [0xF2, pos & 0x7F, pos >> 7]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp()
    os.makedirs(work, exist_ok=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    ok = True
    ticks = 16 * 30 * 3                 # three bars

    # 1-2. CC 85 while pattern 1 plays (internal clock)
    for name, ch, msg, switched in (("cc", CHANNEL, [CC, 85, 1], True),
                                    ("cc-omni", 0, [0xB0, 85, 1], False),
                                    ("cc-otherch", CHANNEL, [0xB2, 85, 1], False),
                                    ("cc-64", CHANNEL, [CC, 85, 64], False)):
        prg = build(work, name, ["TEST_SEQ=1", f"TEST_CHANNEL={ch}"], [(60, msg)])
        want = model(PATS[0], 125, ticks, then=PATS[1] if switched else None)
        what = "pattern 1's pass ends, pattern 2 loops" if switched else "ignored"
        ok &= compare(f"{name}: {' '.join(f'{b:02X}' for b in msg)} at tick 60 ({what})",
                      run_log(prg, 6), want)

    # 3. CC 85 in song mode
    prg = build(work, "cc-song", ["TEST_SEQ=1", "TEST_SONG=1", f"TEST_CHANNEL={CHANNEL}"],
                [(60, [CC, 85, 1])])
    # the model's tick 0 is the song's first step; the feed's tick 60 lands in
    # entry 1's first pass (6 steps x 30 ticks), so that pass ends at 180
    want = model(None, 125, ticks, song=SONG, switch=[(61, PATS[1])])
    ok &= compare("cc-song: song mode off, the entry's repeat dropped, pattern 2 loops "
                  "untransposed", run_log(prg, 6), want)

    # 4. MIDI clock: CC 85 while stopped, then start
    ev = [(20, [CC, 85, 1]), (25, [0xFA])] + clocks(30, 2 * 16 * 6) + [(30 + 2 * 16 * 6 * CLOCK, [0xFC])]
    prg = build(work, "cc-stopped", ["TEST_CLOCK=1", f"TEST_CHANNEL={CHANNEL}"], ev)
    want = model(PATS[0], 125, ev[-1][0] + 100, feed=ev, switch=[(21, PATS[1])])
    ok &= compare("cc-stopped: CC 85 while stopped, then start: pattern 2 from its start",
                  run_log(prg, 6), relative(want))

    # 5-7. song position (MIDI clock)
    def spp_test(name, defines, pos, song, extra=None, label=""):
        ev = [(20, spp(pos))] + (extra or [(25, [0xFB])]) + clocks(30, 16 * 6)
        ev.append((30 + 16 * 6 * CLOCK, [0xFC]))
        prg = build(work, name, ["TEST_CLOCK=1"] + defines, ev)
        want = model(PATS[0] if not song else None, 125, ev[-1][0] + 100, feed=ev,
                     song=SONG if song else None, locate=[(21, pos)])
        return compare(f"{name}: {label}", run_log(prg, 6), relative(want))

    ok &= spp_test("spp-pat4", [], 4, False, label="pattern mode, position 4: from step 5")
    ok &= spp_test("spp-pat9", [], 9, False, label="pattern mode, position 9: 9 mod 6 = step 4")
    for pos, where in ((0, "entry 1, first pass"), (7, "entry 1, second pass, step 2"),
                       (13, "entry 2 (+5), step 2"), (20, "entry 3 (-12), step 3"),
                       (30, "past the end: 30 mod 23 = 7")):
        ok &= spp_test(f"spp-song{pos}", ["TEST_SONG=1"], pos, True,
                       label=f"song, position {pos}: {where}")
    ok &= spp_test("spp-start", ["TEST_SONG=1"], 13, True, extra=[(25, [0xFA])],
                   label="position 13, then start: from the start")
    # while playing: start, a bar, the position (ignored), the clocks go on
    ev = [(25, [0xFA])] + clocks(30, 2 * 16 * 6)
    ev.append((30 + 16 * 6 * CLOCK + 2, spp(13)))
    ev.append((30 + 2 * 16 * 6 * CLOCK, [0xFC]))
    prg = build(work, "spp-playing", ["TEST_CLOCK=1", "TEST_SONG=1"], ev)
    want = model(None, 125, ev[-1][0] + 100, feed=ev, song=SONG,
                 locate=[(30 + 16 * 6 * CLOCK + 3, 13)])
    ok &= compare("spp-playing: a position while playing is ignored", run_log(prg, 6),
                  relative(want))

    # 8. song mode off by CC 85, song select, then start: the song plays
    ev = [(15, [CC, 85, 1]), (20, [0xF3, 0]), (25, [0xFA])] + clocks(30, 16 * 6)
    ev.append((30 + 16 * 6 * CLOCK, [0xFC]))
    prg = build(work, "select", ["TEST_CLOCK=1", "TEST_SONG=1", f"TEST_CHANNEL={CHANNEL}"], ev)
    want = model(None, 125, ev[-1][0] + 100, feed=ev, song=SONG)
    ok &= compare("select: CC 85 (song off), song select (song on), start: the song plays",
                  run_log(prg, 6), relative(want))

    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
