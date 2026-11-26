# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check SID101's MIDI pattern select (CC 85) and song position in VICE.

    python tools/pattern_check.py [--keep DIR]

The sequencer is the core's (core/sequencer.asm), checked in full by
SID303's tools/pattern_check.py; this checks SID101's own wiring. Each
test is a TEST_LOG build of sid101.asm with TEST_MIDI=99 and a MIDI feed
of its own (a wrapper source including sid101.asm, the feed after it as
test_pattern):

1. CC 85 on the synth's channel (2) while pattern 1 plays: pattern 1 ends
   its pass, pattern 2 loops (tools/seq_check.py's model). In omni: ignored.
2. The arpeggiator after a song position (MIDI clock, the sequencer
   stopped, a chord held, Up): continue, and its steps keep to the
   position (src/arp.asm synth_song_position) - at 1/8 an odd position is
   half a step in. Positions 5 and 6 at 1/8, 5 at 1/16. The sequencer's
   own notes (pattern 1, from the position) are left out, as in
   tools/arp_check.py; the arpeggio is compared with its model.

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
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "core"))
import tables  # noqa: E402
import seq_check as sc  # noqa: E402
from arp_check import Model, BASS_NOTES, counts, compare as arp_compare  # noqa: E402

CHANNEL = 2
CLOCK = 5                           # ticks between MIDI clocks (125 BPM)
CHORD = (72, 76, 79)                # C5 E5 G5: none of them in pattern 1 (BASS_LINE)


def feed_source(events, end):
    """test_pattern for [(tick, [bytes])] (core/test_feed.asm), active
    sensing bridging waits over 256 ticks, up to tick `end`."""
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
    asm = os.path.join(work, name + ".asm")
    with open(asm, "w", newline="\n") as f:
        f.write(f'        .include "{os.path.join(ROOT, "sid101.asm").replace(os.sep, "/")}"\n')
        f.write(feed_source(events, end))
    prg = os.path.join(work, name + ".prg")
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "-Wno-portable", "--cbm-prg", "-D", "TEST_LOG=1",
            "-D", "TEST_MIDI=99", "-I", ROOT]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", prg + ".lbl", "-o", prg, asm], cwd=ROOT, check=True)
    return prg


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp()
    os.makedirs(work, exist_ok=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    ok = True

    # 1. CC 85 while pattern 1 plays
    for name, ch, switched in (("cc", CHANNEL, True), ("cc-omni", 0, False)):
        status = 0xB0 | (CHANNEL - 1)
        prg = build(work, name, ["TEST_SEQ=1", f"TEST_CHANNEL={ch}"], [(60, [status, 85, 1])])
        want = sc.model(tables.BASS_LINE, 125, 16 * 31 * 3,
                        then=tables.LEAD_LINE if switched else None)
        what = "pattern 1's pass ends, pattern 2 loops" if switched else "omni: ignored"
        ok &= sc.compare(f"{name}: CC 85 = 1 on channel 2 ({what})", sc.run_log(prg, 6), want)

    # 2. the arpeggiator after a song position
    cc = lambda name, v: [0xB0, tables.CC[name], tables.cc_value(name, v)]
    for pos, rate in ((5, 0), (6, 0), (5, 1)):
        events = [(10, cc("ARP", 1)), (12, cc("ARPRATE", rate)), (14, cc("ARPRANGE", 0))]
        events += [(16 + i, [0x90, n, 100]) for i, n in enumerate(CHORD)]
        events += [(25, [0xF2, pos & 0x7F, pos >> 7]), (30, [0xFB])]
        t = 35
        for _ in range(2 * 16 * 6):
            events.append((t, [0xF8]))
            t += CLOCK
        events.append((t, [0xFC]))
        events += [(t + 5 + i, [0x80, n, 0]) for i, n in enumerate(CHORD)]
        end = t + 40
        name = f"arp-spp{pos}-{'8' if rate == 0 else '16'}"
        prg = build(work, name, ["TEST_CLOCK=1"], events, end=end + 60 * 250)
        want = Model(midi_clock=True).run(events, end)
        got = sc.run_log(prg, end // 250 + 4)
        arp = [e for e in got if e[1] not in BASS_NOTES]
        seq = [e for e in got if e[1] in BASS_NOTES]
        good = arp_compare(f"{name}: arpeggio after song position {pos} at 1/"
                           f"{'8' if rate == 0 else '16'} ({counts(want)} notes)", arp, want)
        print(f"  the sequencer played {counts(seq)} notes of pattern 1 from the position")
        ok &= good and counts(seq) > 5

    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
