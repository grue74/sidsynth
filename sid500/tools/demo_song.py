# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""demo_song.py - SID500 stage C's listening test: the music, and the key
script that enters it on the step grid and plays it (TEST_KEYS=13).

An 8-bar build-up loop at 125 BPM (the user, 2026-11-22): SID808's drums
(track 10, channel 10), SID303's bass (track 2, channel 2: accents at
velocity 110 or more, slides where a note overlaps the next) and SID101's
lead (track 1, channel 1; SID101 plays one voice, so a lead and a second
lead switched in live, no chords). Notes only: the step grid has no
controllers yet.

The patterns are entered from the song screen as a player would: RETURN
on an empty cell (a new pattern, the first free number), its length with
+, the entry velocity and length (C= V, C= L, C= + / -) set on an empty
column before a step's notes, each note with SHIFT (added, the cursor
stays), CRSR down to the next step, RETURN back. Numbers in order: lead A
1, lead B 2 (scene 2), bass 3, drums A 4, drums B 5 (scene 2), so + on a
playing cell switches lead A to B and drums A to B.

Then it plays from the start, the lead and bass muted, and builds up (TIMELINE,
in bars from the start).

    python tools/demo_song.py          # writes src/demo_keys.inc (sid500.asm's TEST_KEYS=13)

Also a library: PATTERNS, TIMELINE, TEMPO for tools/demo_band.py.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPO = 125
STEP_S = 60 / TEMPO / 4                 # a 16th, seconds
SCAN_S = 0.016                          # the key script's scan (core/test_keys.asm)
TAP = 4                                 # scans a tap takes (2 held, 2 released)

KICK, SNARE, CLAP, CHH, OHH = 36, 38, 39, 42, 46     # SID808's GM notes
A1, B1, C2, D2, E2, F1, F2, G1, G2, A2 = 33, 35, 36, 38, 40, 29, 41, 31, 43, 45
ACC, NORM = 110, 104                    # SID303: accent at 110 or more (close: C= + steps by 1)


def notes(*items):
    """[(step 1-based, note, velocity, length in steps)] from tuples, sorted."""
    return sorted(items, key=lambda e: (e[0], e[1]))


LEAD_A = notes((1, 69, 100, 3), (4, 72, 100, 1), (5, 76, 100, 2), (7, 74, 100, 1),
               (8, 72, 100, 2), (11, 69, 100, 2), (13, 67, 100, 2), (15, 69, 100, 2),
               (17, 69, 100, 3), (20, 72, 100, 1), (21, 76, 100, 2), (23, 79, 100, 1),
               (24, 76, 100, 2), (27, 74, 100, 2), (29, 72, 100, 2), (31, 74, 100, 2))
LEAD_B = notes((1, 76, 110, 2), (3, 79, 100, 1), (4, 81, 110, 2), (6, 79, 100, 1),
               (7, 76, 100, 1), (8, 74, 100, 2), (10, 72, 100, 1), (11, 74, 100, 2),
               (13, 76, 110, 4), (17, 76, 110, 2), (19, 79, 100, 1), (20, 81, 110, 2),
               (22, 84, 110, 1), (23, 83, 100, 1), (24, 81, 100, 2), (26, 79, 100, 1),
               (27, 76, 100, 2), (29, 74, 100, 2), (31, 76, 100, 2))
BASS = notes((1, A1, ACC, 1), (2, A1, NORM, 1), (3, A2, NORM, 2), (4, G2, NORM, 1),
             (5, A1, NORM, 1), (7, A1, ACC, 1), (8, C2, NORM, 1), (9, A1, NORM, 1),
             (10, A2, ACC, 2), (11, E2, NORM, 1), (12, A1, NORM, 1), (14, G1, NORM, 1),
             (15, A1, NORM, 1), (16, C2, NORM, 2),
             (17, F1, ACC, 1), (18, F1, NORM, 1), (19, F2, NORM, 2), (20, E2, NORM, 1),
             (21, F1, NORM, 1), (23, F1, ACC, 1), (24, A1, NORM, 1), (25, G1, NORM, 1),
             (26, G2, ACC, 2), (27, D2, NORM, 1), (28, G1, NORM, 1), (30, G1, NORM, 1),
             (31, A1, NORM, 2), (32, B1, NORM, 1))
_four = [(s, KICK, 110, 1) for s in range(1, 33, 4)]
_claps = [(s, CLAP, 110, 1) for s in (5, 13, 21, 29)]
_hats = [(s, CHH, 105, 1) for s in range(3, 33, 4) if s != 31] + [(31, OHH, 110, 1)]
DRUMS_A = notes(*_four, *_claps, *_hats)
DRUMS_B = notes(*_four, (16, KICK, 110, 1), (32, KICK, 110, 1), *_claps,
                *[(s, CHH, 100, 1) for s in range(2, 31, 2) if s not in (16, 30)],
                *_hats, (30, SNARE, 100, 1), (31, SNARE, 105, 1), (32, SNARE, 110, 1))

# (name, track 1-16, scene 1-64, steps, notes): entered in this order, so
# their numbers are 1-5 (the first free each time)
PATTERNS = [("lead A", 1, 1, 32, LEAD_A), ("lead B", 1, 2, 32, LEAD_B),
            ("bass", 2, 1, 32, BASS), ("drums A", 10, 1, 32, DRUMS_A),
            ("drums B", 10, 2, 32, DRUMS_B)]
CHANNEL = {1: 0, 2: 1, 10: 9}           # track -> MIDI channel (0-based: track n plays n)

# the build-up: (bar from the start, track, key, what it does); the lead and
# the bass are muted before the start
TIMELINE = [(4, 2, "M", "the bass in"), (8, 1, "M", "the lead in"),
            (16, 1, "+", "lead B (switched on the playing scene)"),
            (20, 10, "+", "drums B"), (24, 10, "M", "the drums out (a break)"),
            (26, 10, "M", "the drums back"), (28, 1, "-", "lead A again"),
            (32, None, "SPACE", "stop")]
LISTEN = {0: "a steady four on the floor; the hats even, the open hat on the last 8th",
          4: "the bass comes in on the bar; its accents (louder, brighter) and slides "
             "(gliding into the next note) where the pattern has them",
          8: "the lead in time with the drums and the bass, from the bar",
          16: "the switch lands where the loop is, no gap, no note doubled or cut short",
          20: "ghost hats on the 16ths, the snare roll at the end of each second bar",
          24: "the drums stop cleanly (a mute is heard within ~42 ms); bass and lead "
              "keep time alone",
          26: "the drums back on the beat",
          28: "the first lead again, as at 0:15",
          32: "everything stops; no note left hanging"}
BARS = 32

# key codes (column * 8 + row: core/test_keys.asm, src/grid.asm)
K = dict(RETURN=1, RIGHT=2, F7=3, F5=6, DOWN=7, SHIFT=15, PLUS=40, MINUS=43, M=36, SPACE=60,
         **{"+": 40, "-": 43},
         CBM=61, V=31, L=42)


def note_keys():
    """semitones above the Z key -> key code, from src/grid.asm's
    grid_note_keys (the first key found for each)."""
    src = open(os.path.join(ROOT, "src", "grid.asm")).read()
    body = src[src.index("grid_note_keys\n"):src.index(".cerror * - grid_note_keys")]
    codes = []
    for line in body.splitlines():
        m = re.match(r"\s*\.byte\s+([^;]+)", line)
        if m:
            codes += [c.strip() for c in m.group(1).split(",")]
    out = {}
    for code, v in enumerate(codes):
        if v != "N_" and int(v) not in out:
            out[int(v)] = code
    return out


class Script:
    """The key script's entries: (scans to hold, key codes)."""

    def __init__(self):
        self.entries = []
        self.scans = 0

    def wait(self, scans):
        while scans > 0:
            n = min(255, scans)
            self.entries.append((n, []))
            self.scans += n
            scans -= n

    def tap(self, *keys):
        self.entries.append((2, list(keys)))
        self.entries.append((2, []))
        self.scans += TAP

    def asm(self):
        out = []
        for n, keys in self.entries:
            out.append("        .byte " + ", ".join(str(b) for b in [n] + keys + [0xFF]))
        out.append("        .byte 0")
        return "\n".join(out)


class Song:
    """Where the song screen's cursor is, and the step grid's settings, as
    the program has them while the script is typed."""

    def __init__(self, s):
        self.s, self.track, self.scene = s, 1, 1
        self.octave_base = 36           # the Z key's note at the start (C2)
        self.vel, self.length, self.target = 100, 1, "V"
        self.keys = note_keys()

    def to(self, track, scene):
        """The cursor to the cell (CRSR right / SHIFT right, down / SHIFT down)."""
        while self.track != track:
            if track > self.track:
                self.s.tap(K["RIGHT"])
                self.track += 1
            else:
                self.s.tap(K["SHIFT"], K["RIGHT"])
                self.track -= 1
        while self.scene != scene:
            if scene > self.scene:
                self.s.tap(K["DOWN"])
                self.scene += 1
            else:
                self.s.tap(K["SHIFT"], K["DOWN"])
                self.scene -= 1

    def setting(self, which, want):
        """C= V or C= L, then C= + / C= - to the entry velocity or length
        (the cursor on an empty column: the entry setting alone)."""
        have = self.vel if which == "V" else self.length
        if have == want:
            return
        if self.target != which:
            self.s.tap(K["CBM"], K[which])
            self.target = which
        key = K["PLUS"] if want > have else K["MINUS"]
        for _ in range(abs(want - have)):
            self.s.tap(K["CBM"], key)
        if which == "V":
            self.vel = want
        else:
            self.length = want

    def note(self, n):
        """Note n added to the cursor's step (SHIFT: the cursor stays); the
        octave moved (F5 / F6) when it is out of the keys' reach."""
        while n - self.octave_base > max(self.keys):
            self.s.tap(K["F5"])
            self.octave_base += 12
        while n < self.octave_base:
            self.s.tap(K["SHIFT"], K["F5"])
            self.octave_base -= 12
        self.s.tap(K["SHIFT"], self.keys[n - self.octave_base])

    def pattern(self, track, scene, steps, events):
        """A new pattern in the cell, entered step by step, then back."""
        self.to(track, scene)
        self.s.tap(K["RETURN"])
        self.s.wait(50)                 # (the grid drawn: ~25 frames)
        for _ in range(steps - 16):     # (a new pattern has 16 steps)
            self.s.tap(K["PLUS"])
        by_step = {}
        for st, n, v, ln in events:
            by_step.setdefault(st, []).append((n, v, ln))
        for st in range(1, steps + 1):
            col = 0
            for n, v, ln in by_step.get(st, []):
                if (v, ln) != (self.vel, self.length):
                    assert col < 3, (st, "a setting changed with every column full")
                    for _ in range(col):        # (to the first empty column)
                        self.s.tap(K["RIGHT"])
                    self.setting("V", v)
                    self.setting("L", ln)
                    for _ in range((3 - col) % 3):  # (back to the first, round)
                        self.s.tap(K["RIGHT"])
                self.note(n)
                col += 1
            if st < steps:
                self.s.tap(K["DOWN"])
        self.s.tap(K["RETURN"])
        self.s.wait(90)                 # (published, the song screen drawn again)


def script():
    """The whole key script, and the scan at which it starts playing."""
    s = Script()
    s.wait(60)                          # settle
    s.tap(K["F7"])                      # the song screen
    s.wait(60)
    song = Song(s)
    for _, track, scene, steps, events in PATTERNS:
        song.pattern(track, scene, steps, events)
    song.to(1, 1)
    s.tap(K["M"])                       # the lead and the bass muted
    song.to(2, 1)
    s.tap(K["M"])
    s.wait(30)
    s.tap(K["SHIFT"], K["SPACE"])       # play from the start
    start = s.scans - TAP
    bar_scans = 4 * 4 * STEP_S / SCAN_S
    for bar, track, key, _ in TIMELINE:
        moves = 0 if track is None else abs(track - song.track)
        at = start + round(bar * bar_scans) - (moves + 1) * TAP
        s.wait(at - s.scans)
        if track is not None:
            song.to(track, 1)
        s.tap(K[key])
    s.wait(120)
    return s, start


def main():
    s, start = script()
    path = os.path.join(ROOT, "src", "demo_keys.inc")
    with open(path, "w", newline="\n") as f:
        f.write("; demo_keys.inc - generated by tools/demo_song.py, do not edit\n")
        f.write(f"; stage C's listening test: {len(s.entries)} entries, the playing from scan "
                f"{start} ({start * SCAN_S:.1f} s)\n")
        f.write(s.asm() + "\n")
    print(f"{path}: {len(s.entries)} entries, {s.scans * SCAN_S:.1f} s; plays from "
          f"{start * SCAN_S:.1f} s for {BARS} bars")


if __name__ == "__main__":
    main()
