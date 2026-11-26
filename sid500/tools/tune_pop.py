# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""tune_pop.py - the pop demo tune: C major, 122 BPM; verse Am F C G,
pre-chorus Dm Em F G, chorus C G Am F.

SID808 the drums (track 1, channel 10: a backbeat in the verses, four on
the floor and open hats in the choruses, tom fills; its kick tuned up and
bright), SID303 the bass (track 2, channel 2: clean, sparse in the verses,
eighths in the choruses), SID101 five times: the chords as three, a note
each (tracks 3-5, channels 1, 5, 6, Hollow lead darker: stabs in the
verses, held in the choruses), the lead (track 6, channel 3, PWM lead
softened) and a plucked counter-arpeggio in the choruses (track 7,
channel 4, Arp pluck): the 101 voice only (the user: no C64-mode sounds
in the pop song; as many SID101s as needed, up to 9 screens).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunes import Tune, note, cc, program, bars  # noqa: E402

KICK, SNARE, CHH, OHH, LTM, MTM, HTM, CYM = 36, 38, 42, 46, 41, 45, 48, 49
# chords: (name, the bass's root, the chord's voicing around C4)
C_, G_, AM, F_ = ("C", 36, (60, 64, 67)), ("G", 43, (59, 62, 67)), ("Am", 45, (60, 64, 69)), \
    ("F", 41, (60, 65, 69))
DM, EM = ("Dm", 38, (62, 65, 69)), ("Em", 40, (59, 64, 67))
VERSE, PRE, CHORUS = (AM, F_, C_, G_), (DM, EM, F_, G_), (C_, G_, AM, F_)
G4, A4, B4, C5, D5, E5, F5, G5, A5, B5, C6 = 67, 69, 71, 72, 74, 76, 77, 79, 81, 83, 84


def seq(*items, bar=0, shift=0, gap=2):
    """notes from (step, pitch, steps[, velocity]) in a bar (0-based), each
    gap ticks short of its steps, shift semitones up."""
    out = []
    for it in items:
        step, pitch, length = it[:3]
        vel = it[3] if len(it) > 3 else 100
        n = note(step, pitch + shift, vel, length)
        out.append(n[:4] + (max(1, n[4] - gap),))
    return bars(out, bar)


def per_bar(chords, fn):
    out = []
    for b, ch in enumerate(chords):
        out += fn(ch, b)
    return out


# ---- set-up (scene 1, a bar before the music)
# (the user: no C64-mode sounds on SID101 in the pop song, its 101 voice
# only; a chord is three SID101s, a note each)
SET_CHORDS = [program(1, 10), cc(2, 74, 50), cc(2, 71, 6)]                   # Hollow lead, darker
SET_LEAD = [program(1, 9), cc(2, 74, 50), cc(2, 30, 0), cc(2, 71, 8)]         # PWM lead, soft, no glide
SET_PLUCK = [program(1, 19), cc(2, 80, 0), cc(2, 74, 70)]                    # Arp pluck, its arp off
SET_BASS = [cc(1, 74, 62), cc(1, 71, 30), cc(1, 12, 45), cc(1, 75, 70), cc(1, 13, 0),
            cc(1, 5, 0), cc(1, 72, 100), cc(1, 7, 112)]
SET_DRUMS = [cc(1, 16, 127), cc(1, 18, 75), cc(1, 17, 88), cc(1, 19, 127), cc(1, 7, 127)]

# ---- drums
def verse_bar(bar, fill=False):
    ev = [note(1, KICK, 127), note(9, KICK, 120), note(11, KICK, 100), note(5, SNARE, 110),
          note(13, SNARE, 114)]
    ev += [note(st, CHH, 66 if st % 4 == 1 else 50) for st in range(1, 17, 2)
           if st not in (5, 9, 13) and not (fill and st >= 13)]
    if fill:
        ev += [note(13, HTM, 104), note(14, MTM, 100), note(15, LTM, 110), note(16, LTM, 100)]
        ev = [e for e in ev if not (e[2] == SNARE and e[0] >= 12 * 12)]
    return bars(ev, bar)


def chorus_bar(bar, fill=False, crash=False):
    ev = [note(st, KICK, 127) for st in (1, 5, 9, 13) if not (fill and st == 13)]
    ev += [note(5, SNARE, 112)] + ([] if fill else [note(13, SNARE, 116)])
    ev += [note(st, OHH, 62) for st in (3, 7, 11)] + ([] if fill else [note(15, OHH, 62)])
    if crash:
        ev.append(note(1, CYM, 100))
    if fill:
        ev += [note(13, HTM, 104), note(14, MTM, 100), note(15, LTM, 110), note(16, LTM, 100)]
    return bars(ev, bar)


DR_V = verse_bar(0) + verse_bar(1) + verse_bar(2) + verse_bar(3, fill=True)              # 4 bars
DR_C = (chorus_bar(0, crash=True) + chorus_bar(1) + chorus_bar(2) + chorus_bar(3)
        + chorus_bar(4) + chorus_bar(5) + chorus_bar(6) + chorus_bar(7, fill=True))     # 8 bars
DR_B = (bars([note(1, KICK, 120), note(13, SNARE, 100)], 0) + bars([note(1, KICK, 120)], 1)
        + bars([note(1, KICK, 120), note(13, SNARE, 100)], 2)
        + bars([note(1, KICK, 120), note(9, KICK, 110)] + [note(st, SNARE, 60 + 4 * st)
                                                          for st in range(9, 17)], 3))  # 4 bars
DR_O = [note(1, KICK, 120), note(1, CYM, 90)]                                             # 1 bar

# ---- bass
def bass_verse(ch, b):
    r = ch[1]
    return seq((1, r, 2, 104), (4, r, 1, 92), (7, r, 2, 100), (9, r, 2, 104), (11, r + 7, 1, 92),
               (13, r, 2, 100), (15, r + 12, 1, 96), bar=b)


def bass_chorus(ch, b):
    r = ch[1]
    return seq(*[(st, r + (12 if st in (7, 15) else 0), 1.5, 104 if st % 4 == 1 else 94)
                 for st in range(1, 17, 2)], bar=b)


def bass_long(ch, b):
    r = ch[1]
    return seq((1, r, 6, 104), (7, r + 7, 2, 94), (9, r, 8, 100), bar=b)


BS_V, BS_P = per_bar(VERSE, bass_verse), per_bar(PRE, bass_verse)
BS_C, BS_B = per_bar(CHORUS, bass_chorus), per_bar(CHORUS, bass_long)

# ---- chords: three SID101s, the chord's notes from the lowest (voice 0)
def stabs(voice):
    """the verse's rhythm: stabs on 1, the 4th and 7th 16ths, 11 and 13"""
    def bar_(ch, b):
        p = sorted(ch[2])[voice]
        return seq(*[(st, p, ln, 92) for st, ln in ((1, 3), (4, 2), (7, 2), (11, 2), (13, 3))],
                   bar=b)
    return bar_


def held(voice):
    """the chorus's: the chord held through the bar"""
    def bar_(ch, b):
        return seq((1, sorted(ch[2])[voice], 16, 88), bar=b, gap=3)
    return bar_


CH = {v: (per_bar(VERSE, stabs(v)), per_bar(PRE, stabs(v)), per_bar(CHORUS, held(v)))
      for v in range(3)}

# ---- the pluck: eighths over the chord, an octave up
def pluck(ch, b):
    r, t3, t5 = sorted(ch[2])
    tones = [r + 12, t5 + 12, t3 + 12, t5 + 12, r + 24, t5 + 12, t3 + 12, t5 + 12]
    return seq(*[(1 + 2 * k, p, 2, 96 if k % 2 == 0 else 80) for k, p in enumerate(tones)],
               bar=b, gap=0)


PL_C = per_bar(CHORUS, pluck)

# ---- the lead
LEAD_V = [((1, A4, 2), (3, A4, 2), (5, C5, 2), (7, A4, 2), (9, E5, 4), (13, D5, 2), (15, C5, 2)),
          ((1, C5, 4), (5, A4, 4), (9, A4, 6), (15, G4, 2)),
          ((1, G4, 2), (3, G4, 2), (5, C5, 2), (7, G4, 2), (9, E5, 4), (13, D5, 2), (15, C5, 2)),
          ((1, D5, 6), (7, B4, 2), (9, G4, 8))]
LEAD_V += LEAD_V[:3] + [((1, D5, 4), (5, E5, 4), (9, D5, 4), (13, B4, 4))]
LEAD_P = [((1, A4, 2), (3, D5, 2), (5, F5, 4), (9, E5, 2), (11, D5, 2), (13, F5, 4)),
          ((1, E5, 2), (3, G5, 2), (5, B4, 4), (9, E5, 2), (11, G5, 2), (13, E5, 4)),
          ((1, F5, 2), (3, A5, 2), (5, C6, 4), (9, A5, 4), (13, F5, 4)),
          ((1, G5, 8), (9, B4, 2), (11, D5, 2), (13, G5, 4))]
LEAD_C = [((1, E5, 2), (3, G5, 2), (5, G5, 3), (9, A5, 2), (11, G5, 2), (13, E5, 4)),
          ((1, D5, 2), (3, E5, 2), (5, D5, 2), (7, B4, 2), (9, D5, 8)),
          ((1, C5, 2), (3, E5, 2), (5, A5, 3), (9, G5, 2), (11, E5, 2), (13, C5, 4)),
          ((1, D5, 2), (3, C5, 2), (5, A4, 4), (9, C5, 8))]
LEAD_C += [LEAD_C[0], ((1, D5, 2), (3, E5, 2), (5, G5, 4), (9, A5, 2), (11, G5, 6)),
           ((1, E5, 2), (3, G5, 2), (5, A5, 2), (7, C6, 2), (9, B5, 2), (11, A5, 2), (13, G5, 4)),
           ((1, A5, 4), (5, G5, 4), (9, C5, 8))]


def lead(phrases):
    out = []
    for b, ph in enumerate(phrases):
        out += seq(*ph, bar=b, gap=3)
    return out


LD_V, LD_P, LD_C = lead(LEAD_V), lead(LEAD_P), lead(LEAD_C)
EMPTY = []

PATTERNS = {
    1: (16, SET_CHORDS), 2: (16, SET_BASS), 3: (16, SET_LEAD), 4: (16, SET_PLUCK),
    5: (16, SET_DRUMS), 6: (16, EMPTY),
    10: (64, DR_V), 11: (128, DR_C), 12: (64, DR_B), 13: (16, DR_O),
    20: (64, BS_V), 21: (64, BS_P), 22: (64, BS_C), 23: (64, BS_B),
    30: (64, CH[0][0]), 31: (64, CH[0][1]), 32: (64, CH[0][2]),
    33: (64, CH[1][0]), 34: (64, CH[1][1]), 35: (64, CH[1][2]),
    36: (64, CH[2][0]), 37: (64, CH[2][1]), 38: (64, CH[2][2]),
    40: (128, LD_V), 41: (64, LD_P), 42: (128, LD_C),
    50: (64, PL_C),
}
SYNTHS = {10: ("sid808", "drums", None), 2: ("sid303", "bass", None),
          1: ("sid101", "chord low", "Hollow lead"), 5: ("sid101", "chord mid", "Hollow lead"),
          6: ("sid101", "chord high", "Hollow lead"),
          3: ("sid101", "lead", "PWM lead"), 4: ("sid101", "pluck", "Arp pluck")}
TRACKS = {1: 10, 2: 2, 3: 1, 4: 5, 5: 6, 6: 3, 7: 4}
CHORDS_V, CHORDS_P, CHORDS_C = {3: 30, 4: 33, 5: 36}, {3: 31, 4: 34, 5: 37}, {3: 32, 4: 35, 5: 38}
VERSE_ROW = {1: 10, 2: 20, **CHORDS_V, 6: 40}
PRE_ROW = {1: 10, 2: 21, **CHORDS_P, 6: 41}
CHORUS_ROW = {1: 11, 2: 22, **CHORDS_C, 6: 42, 7: 50}
SCENES = [
    ("Setup", 1, {1: 5, 2: 2, 3: 1, 4: 1, 5: 1, 6: 3, 7: 4}, 1),
    ("Intro", 4, {**CHORDS_C, 7: 50}, 1),
    ("Verse 1", 8, VERSE_ROW, 1),
    ("Pre 1", 4, PRE_ROW, 1),
    ("Chorus 1", 8, CHORUS_ROW, 1),
    ("Verse 2", 8, VERSE_ROW, 1),
    ("Pre 2", 4, PRE_ROW, 1),
    ("Chorus 2", 8, CHORUS_ROW, 1),
    ("Bridge", 8, {1: 12, 2: 23, **CHORDS_C, 7: 50}, 1),
    ("Chorus 3", 8, CHORUS_ROW, 2),
    ("Outro", 4, {1: 13, **CHORDS_C, 7: 50}, 1),
    ("End", 8, {1: 6}, 9),
]

TUNE = Tune("pop", "Summer Signal", "pop", 122, SYNTHS, PATTERNS, TRACKS, SCENES)

if __name__ == "__main__":
    blocks = TUNE.check()
    print(f"{TUNE.title}: {len(PATTERNS)} patterns, {blocks} blocks of 680, "
          f"{TUNE.seconds(TUNE.length_ticks()):.1f} s, {len(TUNE.messages())} messages")
