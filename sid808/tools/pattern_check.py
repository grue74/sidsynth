# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check SID808's MIDI pattern select (CC 85), song select and song
position in VICE (docs/sequencer.md, MIDI control).

    python tools/pattern_check.py [--keep DIR]

Each test is a TEST_LOG build of sid808.asm with TEST_MIDI=99 and a MIDI
feed of its own (a wrapper source including sid808.asm, the feed after it
as test_pattern). The hit log (src/sequencer.asm: every hit the sequencer
fires, with its tick, sound and level) is read from VICE's memory; each hit
is put on its step by its time (a step is 60 ticks at 125 BPM on the
500 Hz engine tick, or 6 MIDI clocks 10 ticks apart), and the steps are
compared with what tables.py's patterns and song say, empty steps
included. Step 0 is lined up by the first step with hits.

1. CC 85 = 4 on the synth's channel (2) while pattern 1 (MAIN) plays:
   MAIN's pass ends, pattern 5 (BREAK) loops. In omni, ignored.
2. Song position, pattern mode (MIDI clock): continue plays MAIN from step 6.
3. Song position, song mode (TEST_SONG: the demo's song, 9 entries of
   repeats, then two empty bars): positions 40, 100 and 300 (past the
   end: 300 mod 288 = 12).
4. CC 85 (song mode off), song select (on again), start: the song plays.

Exit status 0 when every check passes.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "core"))
import tables  # noqa: E402

HIT_LOG, HIT_LOG_END = 0xC800, 0xD000          # src/sequencer.asm (TEST_LOG)
CHANNEL = 2
CLOCK = 10                                     # ticks between MIDI clocks (500 Hz: 60 a step)
STEPLEN = tables.PAL_CLOCK / (tables.TICK_LATCH_500 + 1) * 60 / (125 * 4)
LEVEL = {".": 0, "o": 1, "x": 2, "X": 3}
NAMES = [s[0] for s in tables.SOUNDS]


def cells(name):
    """Pattern `name` (tables.py) as 16 steps: each a set of (sound, level)."""
    steps = [set() for _ in range(tables.SEQ_STEPS)]
    for inst, grid in getattr(tables, name).items():
        snd = NAMES.index(tables.GM[tables.TRACK_NOTES[inst]])
        for i, c in enumerate(grid):
            if LEVEL[c]:
                steps[i].add((snd, LEVEL[c]))
    return steps


def song_steps():
    """TEST_SONG's song, flattened: every step of every repeat, in order."""
    out = []
    for name, rep in tables.DEMO_SONG:
        out += cells(name) * rep
    out += [set() for _ in range(2 * tables.SEQ_STEPS)]     # pattern 64 (empty), twice
    return out


def feed_source(events, end):
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


def build(work, name, defines, events, end=60 * 500):
    asm = os.path.join(work, name + ".asm")
    with open(asm, "w", newline="\n") as f:
        f.write(f'        .include "{os.path.join(ROOT, "sid808.asm").replace(os.sep, "/")}"\n')
        f.write(feed_source(events, end))
    prg = os.path.join(work, name + ".prg")
    # (4 undo steps: these runs never undo, and with SysEx and TEST_SONG the
    # program needs the room)
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "-Wno-portable", "--cbm-prg", "-D", "TEST_LOG=1", "-D", "UNDO_STEPS=4",
            "-D", "TEST_MIDI=99", "-I", ROOT]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-o", prg, asm], cwd=ROOT, check=True)
    return prg


def run_hits(prg, seconds):
    """Run prg in VICE and return the hit log: [(tick, sound, level)]."""
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg,
                          f"m {HIT_LOG:04x} {HIT_LOG_END - 1:04x}", "--seconds", str(seconds)],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            data += bytes(int(b, 16) for b in m.group(2).split())
    hits = []
    for i in range(0, len(data) - 3, 4):
        tick = data[i] | data[i + 1] << 8
        if tick == 0:
            break
        hits.append((tick, data[i + 2], data[i + 3]))
    return hits


def check(label, hits, want):
    """The hits put on steps, against want (a list of sets), step by step."""
    first_want = next(i for i, s in enumerate(want) if s)
    if not hits:
        print(f"FAIL {label}: no hits")
        return False
    t_ref = hits[0][0] - first_want * STEPLEN
    got = [set() for _ in want]
    for t, snd, lvl in hits:
        i = round((t - t_ref) / STEPLEN)
        if 0 <= i < len(want):
            got[i].add((snd, lvl))
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            print(f"FAIL {label}: step {i}: got {sorted(g)}, want {sorted(w)}")
            return False
    n = sum(len(s) for s in want)
    print(f"PASS {label}: {len(want)} steps, {n} hits as the patterns say")
    return True


def clocks(start, count):
    return [(start + i * CLOCK, [0xF8]) for i in range(count)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp()
    os.makedirs(work, exist_ok=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    ok = True
    main_, brk = cells("MAIN"), cells("BREAK")
    cc = 0xB0 | (CHANNEL - 1)

    # 1. CC 85 while MAIN plays (internal clock)
    for name, ch, switched in (("cc", CHANNEL, True), ("cc-omni", 0, False)):
        prg = build(work, name, ["TEST_SEQ=1", f"TEST_CHANNEL={ch}"], [(300, [cc, 85, 4])])
        want = main_ + (brk * 2 if switched else main_ * 2)
        what = "MAIN's pass ends, BREAK loops" if switched else "omni: ignored"
        ok &= check(f"{name}: CC 85 = 4 at tick 300 ({what})", run_hits(prg, 6), want)

    # 2-3. song position (MIDI clock)
    def spp_test(name, defines, pos, want_from, label):
        n = 2 * tables.SEQ_STEPS
        ev = [(20, [0xF2, pos & 0x7F, pos >> 7]), (25, [0xFB])] + clocks(30, n * 6)
        ev.append((30 + n * 6 * CLOCK, [0xFC]))
        prg = build(work, name, ["TEST_CLOCK=1"] + defines, ev)
        want = [want_from[(pos + i) % len(want_from)] for i in range(n)]
        return check(f"{name}: {label}", run_hits(prg, 6), want)

    ok &= spp_test("spp-pat", [], 6, main_, "pattern mode, position 6: MAIN from step 7")
    song = song_steps()
    for pos, where in ((40, "entry 2, first pass, step 9"), (100, "entry 3, third pass, step 5"),
                       (300, f"past the end: 300 mod {len(song)} = {300 % len(song)}")):
        ok &= spp_test(f"spp-song{pos}", ["TEST_SONG=1"], pos, song, f"song, position {pos}: {where}")

    # 4. CC 85 (song off), song select (song on), start: the song from its start
    n = 2 * tables.SEQ_STEPS
    ev = [(15, [cc, 85, 1]), (20, [0xF3, 0]), (25, [0xFA])] + clocks(30, n * 6)
    ev.append((30 + n * 6 * CLOCK, [0xFC]))
    prg = build(work, "select", ["TEST_CLOCK=1", "TEST_SONG=1", f"TEST_CHANNEL={CHANNEL}"], ev)
    ok &= check("select: CC 85 (song off), song select (song on), start: the song from its start",
                run_hits(prg, 6), song[:n])

    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
