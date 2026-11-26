# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""tune_dub.py - the dub demo tune: A minor, 75 BPM, a one-drop riddim.

SID808 the drums (track 1) and percussion (track 6) on channel 10, SID101
five times: the sub bass (track 2, channel 4, preset Sub bass), the skank
(tracks 3, 7, 8, channels 1, 5, 6: three SID101s a note each, Perc blip)
with echo throws (the chord again a dotted eighth apart, the
volume falling: CC 7), the melodica (track 4, channel 3, Echo lead: its
echo voice the dub delay); SID303 a resonant siren in the dub sections
(track 5, channel 2, its slides where notes overlap).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunes import Tune, note, cc, program, bars, STEP  # noqa: E402

# notes
G2, A2, B2, C3, D3, E3, F3, G3, A3 = 43, 45, 47, 48, 50, 52, 53, 55, 57
G4, A4, B4, C5, D5, E5, G5, A5 = 67, 69, 71, 72, 74, 76, 79, 81
KICK, RIM, CHH, OHH, LTM, MTM, HTM, MRC, CLV = 36, 37, 42, 46, 41, 45, 48, 70, 75
AM, GM, DM = (57, 60, 64), (55, 59, 62), (62, 65, 69)
VOL = 7                                 # SID101's Volume (CC 7)


def seq(*items, bar=0, shift=0):
    """notes from (step, pitch, steps[, velocity]) in a bar (0-based), each
    2 ticks short of its steps (a note never touches the next on the same
    key), shift semitones up."""
    out = []
    for it in items:
        step, pitch, length = it[:3]
        vel = it[3] if len(it) > 3 else 100
        n = note(step, pitch + shift, vel, length)
        out.append(n[:4] + (max(1, n[4] - 2),))
    return bars(out, bar)


def chord(step, notes_, vel=90, steps=1.5, bar=0):
    return bars([note(step, n, vel, steps) for n in notes_], bar)


# ---- set-up (scene 1, a bar before the music): each synth's sound
SET_KEYS = [program(1, 18), cc(2, 74, 80), cc(2, VOL, 110)]   # Perc blip, a little darker
SET_303 = [cc(1, 74, 40), cc(1, 71, 105), cc(1, 12, 70), cc(1, 75, 80), cc(1, 13, 0),
           cc(1, 5, 60), cc(1, 7, 105)]
# Echo lead, softened (the user: too sharp): the filter mostly closed
# (cutoff 80 of 255), a square (pulse width 50 %), little filter envelope
SET_MEL = [program(1, 24), cc(2, 74, 40), cc(2, 27, 0), cc(2, 20, 6), cc(2, 71, 10)]
# Bounce bass (the user: livelier): saw + sub, a filter pluck, velocity
# accents, a random wander on the cutoff; some sustain for the weight
SET_BASS = [program(1, 6), cc(2, 21, 50), cc(2, 75, 60), cc(2, 74, 70), cc(2, 25, 64)]  # (sub 8: room for the kick)
# SID808: its knobs act on the selected sound, the kick (the user: not
# heard; its body a 48 Hz triangle, below small speakers): level 15, a
# longer decay, 5 semitones up (~64 Hz), Tone 15 (its knock from ~1 kHz)
SET_DRUMS = [cc(1, 16, 127), cc(1, 18, 95), cc(1, 17, 88), cc(1, 19, 127), cc(1, 7, 127)]


# ---- drums (channel 10)
def one_drop_bar(bar, fill=False, open_hat=False, rockers=False):
    """The one drop: kick and rim on beat 3 (rockers: the kick on 1 too),
    hats on the eighths but the kick's (its voice kept: SID808 has three)."""
    ev = [note(9, KICK, 127), note(9, RIM, 96)]
    if rockers:
        ev.append(note(1, KICK, 118))
    for st in range(1, 17, 2):
        if (fill and st >= 13) or st == 9 or (rockers and st == 1):
            continue
        ev.append(note(st, CHH, 70 if st % 4 == 1 else 50))
    if open_hat:
        ev.append(note(15, OHH, 70))
    if fill:
        ev += [note(13, HTM, 100), note(14, MTM, 95), note(15, LTM, 105), note(16, LTM, 90)]
    return bars(ev, bar)


DR0 = [note(9, RIM, 90)] + [note(st, CHH, 58) for st in (3, 7, 11, 15)]          # intro: 1 bar
DR1 = (one_drop_bar(0) + one_drop_bar(1, open_hat=True) + one_drop_bar(2)
       + one_drop_bar(3, fill=True))                                             # 4 bars
DR4 = (one_drop_bar(0, rockers=True) + one_drop_bar(1, open_hat=True, rockers=True)
       + one_drop_bar(2, rockers=True) + one_drop_bar(3, fill=True, rockers=True))  # rockers
DR2 = []                                                                          # the dub: 4 bars
for b in range(4):
    DR2 += bars([note(9, KICK, 127)] + ([note(9, RIM, 95)] if b % 2 else [])
                + ([note(15, CHH, 50)] if b != 3 else [note(15, OHH, 70)]), b)
DR3 = (bars([note(1, KICK, 120), note(9, RIM, 100)], 0) + bars([note(9, KICK, 110)], 1)
       + bars([note(9, RIM, 100), note(13, HTM, 80), note(15, MTM, 85)], 2)
       + bars([note(9, KICK, 127), note(11, HTM, 90), note(12, HTM, 80),
               note(13, MTM, 95), note(14, MTM, 85), note(15, LTM, 105), note(16, LTM, 95)], 3))
P1 = ([note(st, MRC, 52 if st % 4 == 0 else 40) for st in range(2, 17, 2) if st != 10]
      + [note(4, CLV, 70), note(11, CLV, 64)])                                    # 1 bar

# ---- the bass (Bounce bass): pushes on the 16ths, octave pops, ghost notes
B_AM1 = ((1, A2, 2, 120), (3, A2, 1, 72), (5, E3, 1.5, 96), (7, A2, 1, 84), (8, C3, 1.5, 108),
         (10, A2, 1, 76), (11, E3, 2, 112), (13, G3, 1, 90), (14, E3, 1, 74), (15, D3, 1.5, 104))
B_AM2 = ((1, C3, 2, 116), (3, A2, 1, 74), (5, A2, 2, 100), (7, A3, 1, 98), (9, G2, 2, 112),
         (11, A2, 1, 82), (13, C3, 1.5, 102), (15, E3, 1.5, 108))
B_G1 = ((1, G2, 2, 120), (3, G2, 1, 72), (5, D3, 1.5, 96), (7, G2, 1, 84), (8, B2, 1.5, 108),
        (10, G2, 1, 76), (11, D3, 2, 112), (13, F3, 1, 90), (14, D3, 1, 74), (15, C3, 1.5, 104))
B_G2 = ((1, B2, 2, 116), (3, G2, 1, 74), (5, G2, 2, 100), (7, G3, 1, 98), (9, D3, 2, 112),
        (11, B2, 1, 82), (13, G2, 1.5, 102), (15, B2, 1.5, 108))
BS1 = seq(*B_AM1, bar=0) + seq(*B_AM2, bar=1) + seq(*B_G1, bar=2) + seq(*B_G2, bar=3)
BS2 = (seq(*B_AM1, bar=0, shift=5) + seq(*B_AM2, bar=1, shift=5)       # D minor, then back
       + seq(*B_AM1, bar=2) + seq(*B_G2, bar=3))
BS3 = (seq((1, A2, 3, 120), (7, A3, 1, 96), (11, E3, 2, 108), bar=0)
       + seq((1, A2, 6, 118), (13, C3, 1, 90), (15, E3, 1, 96), bar=1)
       + seq((1, G2, 3, 120), (7, G3, 1, 96), (11, D3, 2, 108), bar=2)
       + seq((1, G2, 6, 118), (13, B2, 1, 90), (15, A2, 2, 100), bar=3))
BS4 = (seq((1, A2, 4, 120), (7, A3, 1, 96), (9, E3, 4, 104), bar=0)
       + seq((1, G2, 4, 118), (7, G3, 1, 96), (9, D3, 4, 104), bar=1)
       + seq((1, A2, 12, 124), bar=2))

# ---- the skank on beats 2 and 4: three SID101s, the chord's notes from
# the lowest (voice 0) up (the user: chords from several 101s, not C64 mode)
def skank(v):
    """voice v's K1 (Am Am G G), K2 (the dub's throws), K3 (the outro's long
    throws), K4 (Dm Dm Am G)."""
    def ch1(step, chord_, **kw):
        return chord(step, (sorted(chord_)[v],), **kw)

    def throw(step, chord_, bar, vols=(110, 80, 58, 42, 30)):
        """the chord and its echoes a dotted eighth (3 16ths) apart, each
        quieter (CC 7 before it, on every voice's channel)"""
        out = []
        for k, vol in enumerate(vols):
            at = step + 3 * k           # (past 16: into the next bars)
            out += bars([cc(at, VOL, vol)], bar)    # (before the note at its tick: a stable sort)
            out += ch1(at, chord_, vel=90, steps=1.25, bar=bar)
        return out
    k1, k4 = [], []
    for b, c in enumerate((AM, AM, GM, GM)):
        k1 += ch1(5, c, bar=b) + ch1(13, c, bar=b)
    for b, c in enumerate((DM, DM, AM, GM)):
        k4 += ch1(5, c, bar=b) + ch1(13, c, bar=b)
    k2 = throw(13, AM, 0) + throw(13, GM, 2)                                    # 4 bars
    k3 = throw(5, AM, 0, vols=(110, 85, 64, 48, 36, 26, 18)) + throw(5, GM, 2, vols=(100, 75, 55, 40, 28))
    for pat in (k2, k3):
        pat.append(cc(64, VOL, 110))                                            # (back for the next)
    return k1, k2, k3, k4


SKANK = [skank(v) for v in range(3)]

# ---- the melodica (Echo lead)
M0 = (seq((1, E5, 4), (7, D5, 2), (9, C5, 6), bar=0) + seq((1, A4, 12), bar=1)
      + seq((1, G4, 4), (5, A4, 4), (9, C5, 4), (13, D5, 3), bar=2) + seq((1, E5, 14), bar=3))
M_B1 = ((5, A4, 2), (7, C5, 2), (9, E5, 6), (15, D5, 2))
M_B2 = ((1, C5, 4), (5, A4, 8))
M_B3 = ((5, G4, 2), (7, A4, 2), (9, C5, 4), (13, D5, 2), (15, C5, 2))
M_B4 = ((1, B4, 4), (5, G4, 10))
M_B5 = ((5, E5, 2), (7, G5, 2), (9, A5, 6), (15, G5, 2))
M_B6 = ((1, E5, 4), (5, D5, 4), (9, C5, 6))
M_B7 = ((5, D5, 2), (7, E5, 2), (9, D5, 4), (13, B4, 3))
M_B8 = ((1, A4, 12),)
M1 = []
for b, ph in enumerate((M_B1, M_B2, M_B3, M_B4, M_B5, M_B6, M_B7, M_B8)):
    M1 += seq(*ph, bar=b)
M2 = []
for b, ph in enumerate((((1, A5, 6), (9, G5, 2), (11, E5, 4)), ((1, D5, 4), (5, E5, 10)),
                        ((1, G5, 6), (9, E5, 2), (11, D5, 4)), ((1, B4, 4), (5, D5, 10)),
                        M_B5, M_B6, M_B7, M_B8)):
    M2 += seq(*ph, bar=b)
M3 = seq((1, E5, 4), (5, D5, 4), (9, C5, 8), bar=0) + seq((1, A4, 16), bar=1)

# ---- the siren (SID303): overlapping notes slide
S1 = (seq((1, A2, 2.5), (3, E3, 2.5), (5, A3, 2.5), (7, C3 + 12, 1.5), bar=0)
      + [cc(1, 74, 30)] + [cc(st, 74, 30 + st * 10) for st in range(2, 10)] + [cc(12, 74, 40)]
      + seq((1, E3, 2.5), (3, A3, 2.5), (5, E3 + 12, 1.5), bar=2)
      + bars([cc(1, 74, 50)] + [cc(st, 74, 50 + st * 8) for st in range(2, 8)] + [cc(12, 74, 40)], 2))
S2 = (seq((9, A3, 2.5), (11, G3, 2.5), (13, E3, 2.5), (15, D3, 1.5), bar=0)
      + bars([cc(9, 74, 110)] + [cc(st, 74, 110 - (st - 9) * 10) for st in range(10, 17)], 0)
      + seq((9, G3, 2.5), (11, E3, 2.5), (13, D3, 2.5), (15, C3, 1.5), bar=2)
      + bars([cc(9, 74, 100)] + [cc(st, 74, 100 - (st - 9) * 9) for st in range(10, 17)], 2))

EMPTY = []

PATTERNS = {
    1: (16, SET_KEYS), 2: (16, SET_303), 3: (16, SET_MEL), 4: (16, SET_BASS), 5: (16, EMPTY),
    6: (16, SET_DRUMS), 14: (64, DR4),
    10: (16, DR0), 11: (64, DR1), 12: (64, DR2), 13: (64, DR3), 15: (16, P1),
    20: (64, BS1), 21: (64, BS2), 22: (64, BS3), 23: (64, BS4),
    30: (64, SKANK[0][0]), 31: (64, SKANK[0][1]), 32: (64, SKANK[0][2]), 33: (64, SKANK[0][3]),
    60: (64, SKANK[1][0]), 61: (64, SKANK[1][1]), 62: (64, SKANK[1][2]), 63: (64, SKANK[1][3]),
    64: (64, SKANK[2][0]), 65: (64, SKANK[2][1]), 66: (64, SKANK[2][2]), 67: (64, SKANK[2][3]),
    40: (64, M0), 41: (128, M1), 42: (128, M2), 43: (64, M3),
    50: (64, S1), 51: (64, S2),
}
SYNTHS = {10: ("sid808", "drums", None), 4: ("sid101", "bass", "Bounce bass"),
          1: ("sid101", "skank low", "Perc blip"), 5: ("sid101", "skank mid", "Perc blip"),
          6: ("sid101", "skank high", "Perc blip"), 3: ("sid101", "melodica", "Echo lead"),
          2: ("sid303", "siren", None)}
TRACKS = {1: 10, 2: 4, 3: 1, 4: 3, 5: 2, 6: 10, 7: 5, 8: 6}
SCENES = [
    ("Setup", 1, {1: 6, 2: 4, 3: 1, 4: 3, 5: 2, 7: 1, 8: 1}, 1),
    ("Intro", 4, {1: 10, 4: 40}, 1),
    ("Riddim", 8, {1: 11, 2: 20, 3: 30, 6: 15}, 1),
    ("Melodica", 8, {1: 11, 2: 20, 3: 30, 4: 41, 6: 15}, 1),
    ("Dub", 8, {1: 12, 2: 20, 3: 31, 5: 50}, 1),
    ("Riddim B", 8, {1: 14, 2: 21, 3: 33, 4: 42, 6: 15}, 1),
    ("Dub out", 4, {1: 13, 2: 22, 3: 31, 5: 51, 6: 15}, 1),
    ("Riddim", 8, {1: 14, 2: 20, 3: 30, 4: 41, 6: 15}, 1),
    ("Outro", 4, {1: 10, 2: 23, 3: 32, 4: 43}, 1),
    ("End", 8, {1: 5}, 9),
]

for _name, _bars, _row, _rep in SCENES[1:]:
    if 3 in _row:                       # (the skank's low voice: the others along)
        _row[7], _row[8] = _row[3] + 30, _row[3] + 34

TUNE = Tune("dub", "Echo Chamber", "dub", 75,
            {ch: (s, label, preset) for ch, (s, label, preset) in SYNTHS.items()},
            PATTERNS, TRACKS, SCENES)

if __name__ == "__main__":
    blocks = TUNE.check()
    end = TUNE.length_ticks()
    print(f"{TUNE.title}: {len(PATTERNS)} patterns, {blocks} blocks of {680}, "
          f"{TUNE.seconds(end):.1f} s, {len(TUNE.messages())} messages")
