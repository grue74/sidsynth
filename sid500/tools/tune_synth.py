# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""tune_synth.py - the synth demo tune: D minor, 112 BPM, Dm - Bb - F - C.

SID808 the drums (track 1, channel 10: four on the floor, claps, offbeat
hats; its kick tuned up and bright, as the dub tune's), SID303 an acid line
(track 2, channel 2: accents, slides where notes overlap, its filter swept
in the break), SID101 five times: a 16th arpeggio (track 3, channel 1,
Perc blip, its filter opening through the intro), a chord pad (tracks 4,
6, 7, channels 3, 5, 6: three SID101s a note each, Delay vibe darker) and the
lead (track 5, channel 4, Hollow lead with its filter kept low: legato
notes glide).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunes import Tune, note, cc, program, bars  # noqa: E402

KICK, CLAP, CHH, OHH, LTM, MTM, HTM = 36, 39, 42, 46, 41, 45, 48
D2, F2, A2, BB1, C2 = 38, 41, 45, 34, 36
CHORDS = [("Dm", 50, (62, 65, 69)), ("Bb", 46, (58, 62, 65)), ("F", 41, (60, 65, 69)),
          ("C", 48, (60, 64, 67))]                      # name, the acid's root, the pad
MINOR = {"Dm": True, "Bb": False, "F": False, "C": False}


def seq(*items, bar=0, shift=0, gap=2):
    """notes from (step, pitch, steps[, velocity]) in a bar (0-based), each
    gap ticks short of its steps (negative: overlapping the next: a slide
    or a glide), shift semitones up."""
    out = []
    for it in items:
        step, pitch, length = it[:3]
        vel = it[3] if len(it) > 3 else 100
        n = note(step, pitch + shift, vel, length)
        out.append(n[:4] + (max(1, n[4] - gap),))
    return bars(out, bar)


# ---- set-up (scene 1, a bar before the music)
SET_ARP = [program(1, 18), cc(2, 80, 0), cc(2, 74, 60)]        # Perc blip, its arpeggiator off
SET_PAD = [program(1, 13), cc(2, 74, 60), cc(2, 7, 100)]       # Delay vibe, darker
SET_LEAD = [program(1, 10), cc(2, 74, 55), cc(2, 71, 12)]      # Hollow lead, its filter low
SET_ACID = [cc(1, 74, 45), cc(1, 71, 100), cc(1, 12, 85), cc(1, 75, 45), cc(1, 13, 95),
            cc(1, 5, 40), cc(1, 7, 110)]
SET_DRUMS = [cc(1, 16, 127), cc(1, 18, 70), cc(1, 17, 88), cc(1, 19, 127), cc(1, 7, 127)]

# ---- the arpeggio: chord tones in 16ths, the first of each beat accented
ARP_SHAPE = (0, 2, 3, 1, 2, 3, 4, 5, 3, 2, 4, 3, 2, 1, 0, 2)  # (indexes into the chord's tones)


def arp_bar(tones, bar):
    r, t3, t5 = tones
    pitches = [r, t3, t5, r + 12, t3 + 12, t5 + 12]
    # (a whole 16th each: its off with the next on, one feed entry (SID101's
    # feed holds ~8 KB); Perc blip decays by itself)
    return seq(*[(st + 1, pitches[i], 1, 112 if st % 4 == 0 else 86)
                 for st, i in enumerate(ARP_SHAPE)], bar=bar, gap=0)


ARP = []
for b, (_, _, tones) in enumerate(CHORDS):
    ARP += arp_bar(tones, b)                                    # 4 bars
ARP_IN = []
for b in range(8):
    ARP_IN += arp_bar(CHORDS[b % 4][2], b)
ARP_IN += [cc(1 + 2 * k, 74, 30 + k) for k in range(64)]        # the filter opening: 8 bars
ARP_OUT = []
for b in range(8):
    ARP_OUT += arp_bar(CHORDS[b % 4][2], b)
ARP_OUT += [cc(1 + 2 * k, 74, 94 - k) for k in range(64)]       # and closing

# ---- the pad: each bar's chord held, three SID101s a note each (the
# user: chords from several 101s, not C64 mode)
PAD = [[] for _ in range(3)]
for b, (_, _, tones) in enumerate(CHORDS):
    for v in range(3):
        PAD[v] += seq((1, sorted(tones)[v], 16, 84), bar=b, gap=3)

# ---- the acid line: per bar on the chord's root
ACID_STEPS = [(1, 0, 1, 124), (2, 0, 1, 90), (3, 12, 1.5, 96), (4, 10, 1, 120), (5, 0, 1, 90),
              (7, 7, 1, 96), (8, 12, 1, 124), (9, 0, 1, 90), (10, "3", 1, 96), (11, 0, 1.5, 92),
              (12, 5, 1, 118), (13, 12, 1, 124), (14, 0, 1, 90), (15, 7, 1, 96), (16, 10, 1, 110)]


def acid_bar(name, root, bar):
    items = []
    for st, iv, ln, v in ACID_STEPS:
        if iv == "3":
            iv = 3 if MINOR[name] else 4
        items.append((st, root - 12 + iv, ln, v))
    # (1.5 steps: overlapping the next, a slide; the rest 2 ticks short)
    out = []
    for it in items:
        out += seq(it, bar=bar, gap=-4 if it[2] > 1 else 2)
    return out


ACID = []
for b, (name, root, _) in enumerate(CHORDS):
    ACID += acid_bar(name, root, b)
ACID_BRK = []
for b in range(8):
    name, root, _ = CHORDS[b % 4]
    ACID_BRK += acid_bar(name, root, b)
ACID_BRK += ([cc(1 + 2 * k, 74, 25 + int(70 * (k / 31) ** 2)) for k in range(32)]
             + [cc(65 + 2 * k, 74, 95 - k * 2) for k in range(32)]
             + [cc(1, 71, 115), cc(127, 71, 100)])              # the break: up, then down

# ---- the lead
LEAD_A = [((1, 69, 6), (7, 74, 2), (9, 77, 7.5)), ((1, 77, 4), (5, 74, 4), (9, 70, 7.5)),
          ((1, 72, 6), (7, 77, 2), (9, 81, 7.5)), ((1, 79, 6), (7, 76, 2), (9, 72, 7.5)),
          ((1, 74, 4), (5, 77, 4), (9, 81, 6), (15, 79, 2)), ((1, 77, 8), (9, 74, 4), (13, 77, 4)),
          ((1, 81, 4), (5, 79, 4), (9, 77, 4), (13, 72, 4)), ((1, 76, 12), (13, 79, 3.5))]
LEAD_B = [((1, 81, 4), (5, 79, 2), (7, 77, 2), (9, 76, 2), (11, 77, 2), (13, 81, 4)),
          ((1, 77, 6), (7, 74, 2), (9, 70, 7.5)),
          ((1, 72, 2), (3, 77, 2), (5, 81, 4), (9, 84, 7.5)),
          ((1, 79, 4), (5, 76, 4), (9, 72, 4), (13, 76, 3.5))] + LEAD_A[4:]


def lead(phrases):
    out = []
    for b, ph in enumerate(phrases):
        # (legato: each note into the next, Hollow lead's auto glide; a
        # phrase's last note 3 ticks short)
        for k, it in enumerate(ph):
            out += seq(it, bar=b, gap=-3 if k < len(ph) - 1 else 3)
    return out


LEAD1, LEAD2 = lead(LEAD_A), lead(LEAD_B)

# ---- drums
DK = [note(st, KICK, 124) for st in (1, 5, 9, 13)] + [note(st, CHH, 60) for st in (3, 7, 11, 15)]


def main_bar(bar, fill=False):
    ev = [note(st, KICK, 127) for st in (1, 5, 9, 13) if not (fill and st == 13)]
    ev += [note(5, CLAP, 100), note(13, CLAP, 108)]
    ev += [note(st, OHH, 64) for st in (3, 7, 11)] + ([] if fill else [note(15, OHH, 64)])
    if fill:
        ev += [note(13, HTM, 100), note(14, MTM, 96), note(15, LTM, 108), note(16, LTM, 96)]
    return bars(ev, bar)


DM = main_bar(0) + main_bar(1) + main_bar(2) + main_bar(3, fill=True)       # 4 bars
EMPTY = []

PATTERNS = {
    1: (16, SET_ARP), 2: (16, SET_ACID), 3: (16, SET_PAD), 4: (16, SET_LEAD), 5: (16, SET_DRUMS),
    6: (16, EMPTY),
    10: (16, DK), 11: (64, DM),
    20: (64, ACID), 21: (128, ACID_BRK),
    30: (64, ARP), 31: (128, ARP_IN), 32: (128, ARP_OUT),
    40: (64, PAD[0]), 41: (64, PAD[1]), 42: (64, PAD[2]),
    50: (128, LEAD1), 51: (128, LEAD2),
}
SYNTHS = {10: ("sid808", "drums", None), 2: ("sid303", "acid", None),
          1: ("sid101", "arp", "Perc blip"), 3: ("sid101", "pad low", "Delay vibe"),
          5: ("sid101", "pad mid", "Delay vibe"), 6: ("sid101", "pad high", "Delay vibe"),
          4: ("sid101", "lead", "Hollow lead")}
TRACKS = {1: 10, 2: 2, 3: 1, 4: 3, 5: 4, 6: 5, 7: 6}
SCENES = [
    ("Setup", 1, {1: 5, 2: 2, 3: 1, 4: 3, 5: 4, 6: 3, 7: 3}, 1),
    ("Intro", 8, {3: 31, 4: 40}, 1),
    ("Build", 8, {1: 10, 2: 20, 3: 30, 4: 40}, 1),
    ("Main A", 16, {1: 11, 2: 20, 3: 30, 4: 40, 5: 50}, 1),
    ("Break", 8, {2: 21, 3: 30, 4: 40}, 1),
    ("Main B", 16, {1: 11, 2: 20, 3: 30, 4: 40, 5: 51}, 1),
    ("Outro", 8, {1: 10, 3: 32, 4: 40}, 1),
    ("End", 8, {1: 6}, 9),
]

for _name, _bars, _row, _rep in SCENES[1:]:
    if 4 in _row:                       # (the pad's low voice: the others along)
        _row[6], _row[7] = 41, 42

TUNE = Tune("synth", "Glass Horizon", "synth", 112, SYNTHS, PATTERNS, TRACKS, SCENES)

if __name__ == "__main__":
    blocks = TUNE.check()
    print(f"{TUNE.title}: {len(PATTERNS)} patterns, {blocks} blocks of 680, "
          f"{TUNE.seconds(TUNE.length_ticks()):.1f} s, {len(TUNE.messages())} messages")
