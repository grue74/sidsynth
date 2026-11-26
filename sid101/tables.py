#!/usr/bin/env python3
# tables.py - writes tables.inc for SID101
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates tables.inc (64tass): the core's tables (tick latch, SID
frequencies, multiply tables), SID101's curves (cutoff, envelope rates,
glide, LFO rates, pulse widths) and the TEST_MIDI demo pattern.

All timing values assume the PAL clock and the core's 250 Hz tick.
"""

import os
import sys

# shared helpers and the tables the core needs (core/tables_core.py)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
from tables_core import (TICK_HZ, TICK_LATCH, freq_tables, geo, k8, k16,  # noqa: E402
                         sq_tables, table, tick_latch)
# the sequencer's (core/sequencer.asm); tools/seq_check.py reads them through tables
from tables_core import (BPM_MIN, BPM_MAX, SEQ_STEPS, GATE_LEN, REAL_TICK_HZ,  # noqa: E402,F401
                         TIME_REST, TIME_NOTE, TIME_TIE, FLAG_ACCENT, FLAG_SLIDE,
                         step_bytes, pattern_bytes, tempo_steps)
from tables_core import seq_tables as core_seq_tables  # noqa: E402

# -----------------------------------------------------------------------------
# Controllers: the default MIDI CC of each sound parameter (the demos use
# them too). Names match the P_* constants in sid101.asm; src/params.asm's
# cc_numbers / cc_params must match.
# -----------------------------------------------------------------------------
CC = {"CUTOFF": 74, "RESO": 71, "ENVMOD": 20, "ATTACK": 73, "DECAY": 75, "SUSTAIN": 21,
      "RELEASE": 72, "AMPMODE": 22, "VOICEMODE": 31, "SAW": 23, "PULSE": 24, "SUB": 25,
      "SUBTYPE": 26, "PW": 27, "PWM": 28, "SYNCPITCH": 78, "SYNCENV": 79,
      "CHORD": 17, "CHORDSPEED": 18, "CLICK": 19, "LFORATE": 76,
      "LFOSHAPE": 14, "LFODELAY": 15, "VIBRATO": 77, "LFOCUT": 29, "MODWHEEL": 1, "ACCENT": 16,
      "GLIDE": 5, "GLIDEMODE": 30, "ARP": 80, "ARPRANGE": 81, "ARPRATE": 82,
      "VOLUME": 7}

# parameter ranges (max value), for the demos' CC values
MAX = {"CUTOFF": 255, "RESO": 15, "ENVMOD": 255, "ATTACK": 15, "DECAY": 15, "SUSTAIN": 15,
       "RELEASE": 15, "AMPMODE": 1, "VOICEMODE": 2, "SAW": 15, "PULSE": 15, "SUB": 15,
       "SUBTYPE": 2, "PW": 15, "PWM": 15, "SYNCPITCH": 255, "SYNCENV": 255,
       "CHORD": 10, "CHORDSPEED": 7, "CLICK": 9, "LFORATE": 15,
       "LFOSHAPE": 3, "LFODELAY": 15, "VIBRATO": 15, "LFOCUT": 15, "MODWHEEL": 255, "ACCENT": 15,
       "GLIDE": 15, "GLIDEMODE": 2, "ARP": 4, "ARPRANGE": 2, "ARPRATE": 2,
       "VOLUME": 15}


def cc_value(name, value):
    """The CC value (0..127) that sets parameter name to value: the core's
    param_set_v scales CC*2 (0..254) by (max+1)/256, so aim at the middle of
    the value's range. A full-range parameter (max 255) gets CC*2 itself, so
    an odd value comes out one lower."""
    m = MAX[name]
    if m == 255:
        return min(127, value // 2)
    cc = round((value + 0.5) * 256 / (m + 1) / 2)
    cc = max(0, min(127, cc))
    assert (cc * 2 * (m + 1)) >> 8 == value, (name, value, cc)
    return cc


# -----------------------------------------------------------------------------
# The demos (TEST_MIDI=n), at 125 BPM
# -----------------------------------------------------------------------------
STEP = round(TICK_HZ * 60 / 125 / 4)    # a 16th at 125 BPM: 30 ticks
BAR = 16 * STEP
LEAD_IN = 24                            # ticks before the first section: room for its controllers

# bass line: (step, MIDI note, length in steps); a note longer than the gap
# to the next one overlaps it: legato, so it glides (glide mode Auto)
BASS = [(0, 36, 1), (2, 36, 1), (3, 48, 2), (6, 36, 1), (8, 39, 1), (9, 36, 1),
        (10, 46, 1), (11, 36, 2), (12, 43, 1), (14, 36, 1), (15, 34, 1)]
# lead melody over four bars: (step from the section start, note, length)
LEAD = [(0, 67, 6), (6, 70, 2), (8, 72, 8), (16, 75, 4), (20, 74, 2), (22, 72, 2),
        (24, 70, 8), (32, 67, 3), (34, 70, 3), (36, 72, 3), (38, 75, 3), (40, 77, 8),
        (48, 79, 4), (52, 77, 2), (54, 75, 2), (56, 72, 8)]
# sync riff over two bars: 8ths and a few longer notes, legato where they touch
SYNC_RIFF = [(0, 60, 2), (2, 60, 2), (4, 63, 2), (6, 65, 4), (10, 67, 2), (12, 65, 2),
             (14, 63, 2), (16, 60, 2), (18, 60, 2), (20, 58, 2), (22, 60, 4), (26, 67, 3),
             (29, 70, 3)]
# sync lead over two bars: long notes
SYNC_LEAD = [(0, 67, 8), (8, 70, 4), (12, 72, 4), (16, 75, 8), (24, 72, 6), (30, 70, 2)]


class Demo:
    """Collects a demo's MIDI events: [(tick, order, bytes)]; order puts
    controllers before notes on the same tick."""

    def __init__(self):
        self.ev = []

    def cc(self, t, name, value):
        self.ev.append((t, 0, [0xB0, CC[name], cc_value(name, value)]))

    def note(self, t, n, length_ticks, vel=100):
        self.ev.append((t, 2, [0x90, n, vel]))
        self.ev.append((t + length_ticks, 1, [0x90, n, 0]))

    def sound(self, t, **values):
        # one controller a tick, ending just before t, as real MIDI would
        # bring them (31250 baud: a 3-byte message takes ~1 ms; a burst fed
        # in one tick would hold the engine up, which MIDI never can)
        for i, (name, value) in enumerate(values.items()):
            self.cc(t - len(values) + i, name.upper(), value)

    def line(self, t0, notes, bars=1, bar_len=16):
        """notes (step, note, length in steps), repeated for bars; a note that
        reaches the next one overlaps it by a tick (legato), else it sounds
        half its length. The line's very last note never overlaps: whatever
        comes after the line starts fresh (a legato note there would keep
        this line's levels: the SID can't raise them)."""
        for bar in range(bars):
            for i, (step, n, length) in enumerate(notes):
                nxt = next((s for s, _, _ in notes if s > step), bar_len)
                last = bar == bars - 1 and i == len(notes) - 1
                if step + length >= nxt and not last:
                    ticks = length * STEP + 1
                elif step + length >= nxt:
                    ticks = length * STEP - 4
                else:
                    ticks = length * STEP // 2
                self.note(t0 + bar * bar_len * STEP + step * STEP, n, ticks)


def demo_a():
    """TEST_MIDI=1, demos/a-voice.wav: the SH-101 voice. Returns (events, end)."""
    d = Demo()
    # 1. bass (bars 0-1): saw + sub, short filter envelope, the amp on Gate
    # (as an SH-101 bass: the envelope works on the filter only), glide on legato notes
    t0 = LEAD_IN
    d.sound(t0, cutoff=60, reso=7, envmod=150, attack=0, decay=5, sustain=0, release=2,
            ampmode=1, voicemode=0, saw=15, pulse=0, sub=11, subtype=0, pw=0, pwm=0,
            lforate=8, vibrato=0, lfocut=0, glide=4, glidemode=2, volume=15)
    d.line(t0, BASS, bars=2)

    # 2. squelch (bars 2-3): the same line, resonance up, env mod up, the
    # cutoff opening step by step
    t0 = LEAD_IN + 2 * BAR
    d.sound(t0, reso=13, envmod=220, decay=6)
    d.line(t0, BASS, bars=2)
    for i in range(32):
        d.cc(t0 + i * STEP, "CUTOFF", 30 + i * 3)

    # 3. lead (bars 4-7): saw + pulse with PWM, glide always, vibrato from bar 6
    t0 = LEAD_IN + 4 * BAR
    d.sound(t0, cutoff=130, reso=4, envmod=70, attack=3, decay=9, sustain=10, release=7, ampmode=0,
            saw=10, pulse=15, sub=0, pw=3, pwm=11, lforate=5, vibrato=0, glide=6, glidemode=1)
    d.sound(t0 + 2 * BAR, vibrato=4, lforate=9)
    for step, n, length in LEAD:
        d.note(t0 + step * STEP, n, length * STEP - 4)

    # 4. filter sweep (bars 8-9): one held note, all three voices, the LFO
    # on the cutoff, the cutoff turned from closed to open
    t0 = LEAD_IN + 8 * BAR
    d.sound(t0, cutoff=20, reso=12, envmod=0, attack=0, decay=8, sustain=15, release=6,
            saw=15, pulse=12, sub=10, subtype=1, pw=0, pwm=6, lforate=7, vibrato=0,
            lfocut=8, glidemode=0)
    d.note(t0, 36, 2 * BAR - 10)
    for i in range(32):
        d.cc(t0 + i * STEP, "CUTOFF", 20 + i * 7)
    return d.ev, LEAD_IN + 10 * BAR + BAR // 2      # half a bar of silence, then it loops


def demo_b():
    """TEST_MIDI=2, demos/b-sync.wav: Sync mode. Returns (events, end)."""
    d = Demo()
    # 1. sync lead (bars 0-1): the synced saw alone over the sub, its pitch
    # swept down by the envelope at every note: the tearing attack
    t0 = LEAD_IN
    d.sound(t0, voicemode=1, cutoff=200, reso=2, envmod=30, attack=0, decay=7, sustain=11,
            release=5, ampmode=0, saw=0, pulse=15, sub=8, subtype=0, syncpitch=20, syncenv=200,
            lforate=8, vibrato=0, lfocut=0, pwm=0, glide=3, glidemode=2, volume=15)
    d.line(t0, SYNC_RIFF, bars=1, bar_len=32)

    # 2. the sync pitch by hand (bars 2-3): one held note, no envelope sweep,
    # Sync pitch turned up over a bar and back down over the next
    t0 = LEAD_IN + 2 * BAR
    d.sound(t0, syncenv=0, syncpitch=0, decay=10, sustain=15, release=6, sub=10)
    d.note(t0, 48, 2 * BAR - 10)
    knob = 2 * BAR // 10                    # a controller every 10 ticks, as a turned knob sends
    for i in range(knob):
        pos = i / (knob / 2)
        d.cc(t0 + i * 10, "SYNCPITCH", round(254 * (pos if pos <= 1 else 2 - pos)))

    # 3. sync bass (bars 4-5): demo A's bass line, saw and synced saw with
    # the sub, a short sweep, the amp on Gate
    t0 = LEAD_IN + 4 * BAR
    d.sound(t0, cutoff=110, reso=6, envmod=110, decay=5, sustain=0, release=2, ampmode=1,
            saw=8, pulse=13, sub=12, syncpitch=0, syncenv=120, glide=4, glidemode=2)
    d.line(t0, BASS, bars=2)

    # 4. sync lead with vibrato and glide (bars 6-7): long notes, the synced
    # voice higher, a slower sweep
    t0 = LEAD_IN + 6 * BAR
    d.sound(t0, cutoff=170, reso=3, envmod=40, decay=10, sustain=8, release=8, ampmode=0,
            saw=6, pulse=15, sub=6, syncpitch=60, syncenv=90, lforate=9, vibrato=4,
            glide=6, glidemode=1)
    for step, n, length in SYNC_LEAD:
        d.note(t0 + step * STEP, n, length * STEP - 4)
    return d.ev, LEAD_IN + 8 * BAR + BAR // 2


# LFO shapes and accent (demo C)
LFO = {"triangle": 0, "square": 1, "random": 2, "noise": 3}
# an accented bass line over a bar: (step, note, length, velocity)
ACC_BASS = [(0, 36, 1, 127), (2, 36, 1, 70), (3, 48, 1, 70), (4, 36, 1, 127), (6, 43, 1, 70),
            (7, 36, 1, 70), (8, 39, 1, 127), (10, 36, 1, 70), (11, 46, 1, 127), (12, 36, 1, 70),
            (14, 34, 1, 127), (15, 36, 1, 70)]
# a lead for the LFO delay: long notes, each fresh (gaps between them)
DELAY_LEAD = [(0, 72, 7), (8, 75, 7), (16, 79, 7), (24, 77, 7)]
C_LEAD_IN = 40                          # demo C's first sound() sends 26 controllers


def demo_c():
    """TEST_MIDI=3, demos/c-modulation.wav: LFO shapes, delay, mod wheel, accent. Returns (events, end)."""
    d = Demo()
    # 1. random (bars 0-1): one held note, sample and hold on the cutoff, the
    # classic burble, resonance up
    t0 = C_LEAD_IN
    d.sound(t0, voicemode=0, cutoff=90, reso=12, envmod=0, attack=0, decay=8, sustain=15,
            release=5, ampmode=0, saw=15, pulse=0, sub=9, subtype=0, pw=0, pwm=0,
            lforate=11, lfoshape=LFO["random"], lfodelay=0, vibrato=0, lfocut=15, modwheel=0,
            accent=0, glide=0, glidemode=0, volume=15)
    d.note(t0, 36, 2 * BAR - 10)

    # 2. square (bars 2-3): a trill, the square on the pitch; then on the
    # pulse width (bar 3) with the cutoff following
    t0 = C_LEAD_IN + 2 * BAR
    d.sound(t0, lfoshape=LFO["square"], lforate=8, vibrato=7, lfocut=0, cutoff=150, reso=4,
            saw=8, pulse=15, sub=0, pw=2, decay=10, sustain=11)
    d.note(t0, 67, BAR - 6)
    d.sound(t0 + BAR, vibrato=0, pwm=12, lforate=7, lfocut=5)
    d.note(t0 + BAR, 60, BAR - 6)

    # 3. LFO delay (bars 4-5): long fresh notes, the vibrato fading in on each
    t0 = C_LEAD_IN + 4 * BAR
    d.sound(t0, lfoshape=LFO["triangle"], lforate=9, lfodelay=11, vibrato=6, lfocut=0, pwm=6,
            cutoff=140, reso=3, envmod=60, attack=2, decay=10, sustain=10, release=7,
            saw=12, pulse=12, sub=0)
    for step, n, length in DELAY_LEAD:
        d.note(t0 + step * STEP, n, length * STEP)

    # 4. mod wheel (bars 6-7): one held note, no vibrato set; the wheel up
    # over a bar and back down over the next
    t0 = C_LEAD_IN + 6 * BAR
    d.sound(t0, lfodelay=0, vibrato=0, lforate=9, pwm=4)
    d.note(t0, 70, 2 * BAR - 10)
    knob = 2 * BAR // 10                    # a controller every 10 ticks, as a moved wheel sends
    for i in range(knob):
        pos = i / (knob / 2)
        d.cc(t0 + 6 + i * 10, "MODWHEEL", round(254 * (pos if pos <= 1 else 2 - pos)))

    # 5. accent (bars 8-11): a bass line, velocities 127 and 70; first
    # without accent (bars 8-9), then at accent 15 (bars 10-11)
    t0 = C_LEAD_IN + 8 * BAR
    d.sound(t0, modwheel=0, cutoff=50, reso=10, envmod=110, attack=0, decay=5, sustain=0,
            release=2, ampmode=0, saw=15, pulse=0, sub=10, lfocut=0, pwm=0, glidemode=0)
    for bar in range(4):
        if bar == 2:
            d.sound(t0 + bar * BAR, accent=15)
        for step, n, length, vel in ACC_BASS:
            d.note(t0 + bar * BAR + step * STEP, n, STEP // 2, vel)

    # 6. noise and everything at once (bars 12-13): Sync mode, noise on
    # the cutoff, delayed vibrato, accent, the wheel: the engine's worst case
    t0 = C_LEAD_IN + 12 * BAR
    d.sound(t0, voicemode=1, lfoshape=LFO["noise"], lfocut=6, lfodelay=9, vibrato=5,
            modwheel=60, cutoff=150, reso=5, envmod=40, decay=9, sustain=10, release=6,
            saw=6, pulse=15, sub=8, syncpitch=40, syncenv=110, glide=4, glidemode=2)
    for step, n, length in SYNC_LEAD:
        d.note(t0 + step * STEP, n, length * STEP - 4, 127 if step % 16 == 0 else 80)
    return d.ev, C_LEAD_IN + 14 * BAR + BAR // 2


# the C64 lead (demo H): a melody of fresh notes over two bars (32 steps),
# and a staccato riff over one bar for the clicks
H_LEAD = [(0, 72, 4), (4, 75, 2), (6, 77, 2), (8, 79, 6), (14, 77, 2), (16, 75, 4), (20, 74, 2),
          (22, 72, 2), (24, 70, 7)]
H_RIFF = [(0, 72), (2, 72), (4, 79), (6, 77), (8, 75), (10, 72), (12, 70), (14, 72)]
H_LEAD_IN = 40                          # demo H's first sound() sends 25 controllers


def demo_h():
    """TEST_MIDI=17, demos/h-c64-voice.wav: the C64 lead mode (echo, click, PWM sweep). Returns (events, end)."""
    d = Demo()

    def lead(t0):
        for step, n, length in H_LEAD:
            d.note(t0 + step * STEP, n, length * STEP - 6)

    # 1. the lead alone (bars 0-1): pulse with its own slow PWM sweep, the
    # vibrato coming in after a delay, no echo, no sub
    t0 = H_LEAD_IN
    d.sound(t0, voicemode=2, cutoff=210, reso=2, envmod=20, attack=0, decay=11, sustain=12,
            release=6, ampmode=0, saw=0, pulse=15, sub=0, subtype=0, pw=3, pwm=6, lforate=11,
            lfoshape=0, lfodelay=6, vibrato=5, lfocut=0, glidemode=0, click=0, accent=0)
    lead(t0)

    # 2. the same with the echo (bars 2-3): voice 2 plays voice 1 128 ms later
    t0 = H_LEAD_IN + 2 * BAR
    d.sound(t0, saw=10)
    lead(t0)

    # 3. the clicks (bars 4-6): the riff with a noise click (1 frame), a
    # saw click (2 frames), a square click (3 frames), no echo
    for i, click in enumerate((1, 5, 9)):
        t0 = H_LEAD_IN + (4 + i) * BAR
        d.sound(t0, click=click, saw=0, lfodelay=0, vibrato=0, decay=6, sustain=6)
        for step, n in H_RIFF:
            d.note(t0 + step * STEP, n, STEP - 6)

    # 4. all of it (bars 7-8): echo, sub two octaves down, a noise click,
    # vibrato after a delay, the faster sweep
    t0 = H_LEAD_IN + 7 * BAR
    d.sound(t0, saw=9, sub=8, subtype=1, click=2, decay=11, sustain=12, lfodelay=5, vibrato=5,
            pwm=9)
    lead(t0)
    return d.ev, H_LEAD_IN + 9 * BAR + BAR // 2

# C64 mode's chords (demo H2): the Chord values (P_CHORD, chord_names)
CHORD = {"off": 0, "keys": 1, "major": 2, "minor": 3, "7th": 4, "minor7": 5, "major7": 6,
         "sus4": 7, "5th": 8, "octave": 9, "dim": 10}
# its sections' starts, in bars from H2_LEAD_IN (demo_h2_times, voice_check.py)
H2_PARTS = {"shapes": 0, "keys": 4, "octave": 6, "arp": 8, "end": 10}
H2_LEAD_IN = 40                         # demo H2's first sound() sends 25 controllers


def demo_h2():
    """TEST_MIDI=19, demos/h2-c64-chords.wav: C64 mode's chords. Returns (events, end)."""
    d = Demo()
    bar = lambda b: H2_LEAD_IN + b * BAR    # noqa: E731

    # 1. shapes (bars 0-3): one key a bar, its chord a fast arpeggio of a
    # note a frame: C minor, A flat major, B flat major, G 7th; the echo on
    t0 = bar(H2_PARTS["shapes"])
    d.sound(t0, voicemode=2, cutoff=200, reso=3, envmod=30, attack=0, decay=11, sustain=12,
            release=7, ampmode=0, saw=7, pulse=15, sub=0, subtype=0, pw=4, pwm=5, lforate=11,
            lfoshape=0, lfodelay=0, vibrato=0, lfocut=0, glidemode=0, click=0, accent=0,
            chord=CHORD["minor"], chordspeed=0)
    for i, (note, shape) in enumerate(((60, "minor"), (56, "major"), (58, "major"), (55, "7th"))):
        if i:
            d.cc(t0 + i * BAR - 2, "CHORD", CHORD[shape])
        d.note(t0 + i * BAR, note, BAR - 12)

    # 2. keys (bars 4-5): the chord held on the keys, two frames a note:
    # C minor 7th, then F minor
    t0 = bar(H2_PARTS["keys"])
    d.sound(t0, chord=CHORD["keys"], chordspeed=1)
    for i, keys in enumerate(((60, 63, 67, 70), (65, 68, 72))):
        for n in keys:
            d.note(t0 + i * BAR, n, BAR - 12)

    # 3. octaves (bars 6-7): demo H's lead melody, each note an octave
    # arpeggio, a note a frame, the click on
    t0 = bar(H2_PARTS["octave"])
    d.sound(t0, chord=CHORD["octave"], chordspeed=0, click=1)
    for step, n, length in H_LEAD:
        d.note(t0 + step * STEP, n, length * STEP - 6)

    # 4. with the arpeggiator (bars 8-9): C minor held, Up over 2 octaves at
    # 1/8; each of its notes a fifth arpeggio
    t0 = bar(H2_PARTS["arp"])
    d.sound(t0, chord=CHORD["5th"], click=0, arp=1, arprange=1, arprate=0)
    for n in (48, 51, 55):
        d.note(t0, n, 2 * BAR - 12)
    d.cc(t0 + 2 * BAR, "ARP", 0)
    return d.ev, bar(H2_PARTS["end"]) + BAR // 2


DEMOS = {1: demo_a, 2: demo_b, 3: demo_c, 17: demo_h, 19: demo_h2}  # the voice demos (tools/voice_check.py)


# -----------------------------------------------------------------------------
# Step sequencer (core/sequencer.asm; SID303's docs/sequencer.md): the
# patterns at start, the test patterns and songs
# -----------------------------------------------------------------------------
# A step: (note, accent, slide). note is a MIDI note, "-" a rest or "=" a tie.
# Pattern 1: a bass line with slides (glide Auto glides them) and accents
BASS_LINE = [(36, 1, 0), (36, 0, 0), (48, 0, 1), (46, 0, 0),
             (36, 1, 0), ("-", 0, 0), (43, 0, 0), (36, 0, 1),
             (39, 0, 0), (36, 0, 0), (51, 1, 0), (36, 0, 0),
             (34, 0, 1), (36, 0, 0), (41, 1, 0), (43, 0, 0)]
# pattern 2: a lead melody with ties
LEAD_LINE = [(60, 1, 0), ("=", 0, 0), (63, 0, 0), (65, 0, 1),
             (67, 0, 0), ("=", 0, 0), (70, 1, 0), (67, 0, 0),
             (65, 0, 1), (63, 0, 0), ("=", 0, 0), (60, 0, 0),
             (58, 1, 1), (60, 0, 0), ("=", 0, 0), ("-", 0, 0)]
# pattern 3: octave riff (Sync mode in the demo)
OCTAVE_RIFF = [(48, 1, 0), (60, 0, 0), (55, 0, 0), (60, 0, 0),
               (51, 1, 0), (63, 0, 0), (58, 0, 0), (63, 0, 1),
               (53, 1, 0), (65, 0, 0), (60, 0, 0), (65, 0, 0),
               (50, 1, 0), (62, 0, 1), (58, 0, 0), (62, 0, 0)]
# pattern 4: 12 steps, an octave-bouncing bass (against 16-step patterns: 3 over 4)
BOUNCE = [(36, 1, 0), (48, 0, 0), (36, 0, 0), (48, 0, 1),
          (46, 0, 0), (36, 1, 0), (48, 0, 0), (43, 0, 1),
          (41, 0, 0), (36, 1, 0), (39, 0, 0), (41, 0, 1)]
SEQ_PATTERNS = [BASS_LINE, LEAD_LINE, OCTAVE_RIFF, BOUNCE]

# TEST_EDGES (SID303's): the playing rules' awkward cases, copied over
# pattern 1. tools/seq_check.py computes the notes they should give.
EDGES = [(33, 0, 1),            # 1  A-1 slides into ...
         (33, 0, 0),            # 2  ... the same pitch: plays as a tie
         ("=", 0, 0),           # 3  a tie after it: the gate closes half way
         ("-", 0, 0),           # 4  rest
         ("=", 0, 0),           # 5  a tie after a rest: a rest
         (36, 1, 1),            # 6  accented C-2 slides into ...
         ("-", 0, 0),           # 7  ... a rest: released at its start
         (38, 0, 0),            # 8  D-2, then ...
         ("=", 0, 1),           # 9  ... a tie that slides into ...
         (40, 0, 0),            # 10 ... E-2
         (43, 1, 0),            # 11 G-2 accented
         ("-", 0, 0),           # 12
         ("-", 0, 0),           # 13
         ("-", 0, 0),           # 14
         ("-", 0, 0),           # 15
         (45, 0, 1)]            # 16 A-2 slides across the pattern's end into step 1

# TEST_EDGES=2: lengths and the next pattern. Pattern 1 (6 steps) plays
# once, then pattern 2 (5 steps) loops (TEST_SEQ_NEXT=1). Pattern 1's last
# step slides into pattern 2's first, a tie: A-2 holds into it. Pattern 2's
# last step goes on into its own first step's tie each pass.
SHORT1 = [(33, 0, 0), (36, 0, 0), ("-", 0, 0), (38, 1, 0), (40, 0, 0), (45, 0, 1)]
SHORT2 = [("=", 0, 0), (43, 0, 0), ("-", 0, 0), (40, 0, 1), (38, 1, 0)]

# songs: entries (pattern index, repeats, transpose), song mode on.
# TEST_SONG=1 (with TEST_EDGES=2's patterns): tools/seq_check.py's song test.
SONG_TEST = [(0, 2, 0), (1, 1, 5), (0, 1, -12)]
# TEST_SONG=2: demo D (demos/d-sequencer.wav) over the default patterns
EMPTY = 4                                               # pattern 5: empty at start (rests)
SONG_DEMO = [(EMPTY, 1, 0),                             # a bar of silence: the sound is set
             (0, 2, 0), (0, 1, 5), (0, 1, -2),          # bass (4 bars)
             (1, 2, 0),                                 # lead (2 bars)
             (2, 2, 0), (2, 1, 5), (2, 1, 0),           # sync riff (4 bars)
             (3, 4, 0), (3, 4, -5)]                     # bounce, 12 steps (6 bars)


def song_steps(song):
    """Steps each song entry starts at, and the song's total: [(start step,
    (pattern, repeats, transpose))], total steps."""
    out, t = [], 0
    for entry in song:
        out.append((t, entry))
        length = len(SEQ_PATTERNS[entry[0]]) if entry[0] < len(SEQ_PATTERNS) else SEQ_STEPS
        t += entry[1] * length          # (a pattern past the defaults: empty, 16 steps)
    return out, t


def song_tables():
    """The two songs, as core/sequencer.asm's TEST_SONG tables wants them."""
    text = ""
    for n, song in ((1, SONG_TEST), (2, SONG_DEMO)):
        text += (".if" if n == 1 else ".elsif") + f" TEST_SONG == {n}\n"
        text += (f"TEST_SONG_LEN = {len(song)}\n"
                 + table("test_song_pat", [p for p, _, _ in song], f"TEST_SONG={n}: the song's patterns")
                 + table("test_song_rep", [r for _, r, _ in song], "... repeats")
                 + table("test_song_tr", [t & 255 for _, _, t in song], "... transposes"))
    return text + ".endif\n"


def seq_tables():
    """The sequencer's tables (core/tables_core.py) with these patterns, and
    the songs (not through the core's song_test: two of them here)."""
    return core_seq_tables(SEQ_PATTERNS, EDGES, (SHORT1, SHORT2)) + song_tables()


def feed_entries(events, end):
    """[(tick, [bytes])] sorted, same-tick messages together; long gaps
    filled with active sensing ($FE, ignored): test_feed waits up to 256."""
    entries = []
    for t, msg in sorted(events, key=lambda e: e[0]):
        if entries and entries[-1][0] == t:
            entries[-1][1].extend(msg)
        else:
            entries.append((t, list(msg)))
    filled = []
    for i, (t, b) in enumerate(entries):
        filled.append((t, b))
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        while nxt - filled[-1][0] > 256:
            filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        assert 0 < len(b) < 256 and 0 <= nxt - t - 1 < 256
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    return data


def feed_events():
    """TEST_MIDI=4: pattern 1 (BASS_LINE) fed through the MIDI parser for
    four bars at 125 BPM, as SID303's TEST_MIDI=1: accents at velocity 127
    (else 100), slides as the next note on before the note off, the gate
    6/10 of a step, running status and MIDI clock bytes mixed in (one inside
    a message each bar). tools/seq_check.py compares it with the sequencer.
    Returns (entries [(tick, bytes)], end)."""
    step = round(TICK_HZ * 60 / 125 / 4)
    gate = step * 6 // 10
    events = []                         # (tick, order, [bytes])
    for bar in range(4):
        t0 = bar * 16 * step
        for i, (note, acc, slide) in enumerate(BASS_LINE):
            if note in ("-", "="):
                continue
            t = t0 + i * step
            events.append((t, 2, [0x90, note, 127 if acc else 100]))
            events.append((t + (step + 1 if slide else gate), 1, [0x90, note, 0]))
    end = 4 * 16 * step + 16 * step     # a bar of silence after
    for t in range(0, end, 5):
        events.append((t, 3, [0xF8]))
    events.sort(key=lambda e: (e[0], e[1]))
    entries, status = [], None
    for t, _, msg in events:
        out = list(msg)
        if msg[0] < 0xF8:
            if msg[0] == status:
                out = out[1:]
            status = msg[0]
            if msg[0] == 0x90 and t % (16 * step) == 4 * step and len(out) >= 2:
                out = out[:1] + [0xF8] + out[1:]
        entries.append((t, out))
    return entries, end


CLOCK_TICKS = 5                 # TEST_MIDI=5: a MIDI clock every 5 ticks (125 BPM: 6 a step of 30)


def clock_events():
    """TEST_MIDI=5 (SID303's): MIDI clock in. Start at tick 25, a clock every
    CLOCK_TICKS ticks for two bars (192 clocks: the first is step 1's),
    stop, 100 ticks of silence, continue, one more bar of clocks, stop.
    Returns [(tick, [bytes])]; tools/seq_check.py plays the same list
    through its model."""
    ev = [(25, [0xFA])]
    t = 30
    for _ in range(2 * 16 * 6):
        ev.append((t, [0xF8]))
        t += CLOCK_TICKS
    ev.append((t, [0xFC]))
    t += 100
    ev.append((t, [0xFB]))
    t += CLOCK_TICKS
    for _ in range(16 * 6):
        ev.append((t, [0xF8]))
        t += CLOCK_TICKS
    ev.append((t, [0xFC]))
    return ev


def demo_d():
    """TEST_MIDI=6 with TEST_SEQ=1 TEST_SONG=2, demos/d-sequencer.wav: the
    sequencer plays SONG_DEMO; this feed sets the sound for each part, its
    controllers in the ticks just before the part starts. Returns (events,
    end): end = the song's length, so the feed restarts with the song."""
    d = Demo()
    starts, total = song_steps(SONG_DEMO)
    at = {i: t * STEP for i, (t, _) in enumerate(starts)}
    # 1. bass (entries 1-3, after the silent bar): saw + sub, resonant,
    # accent; glide Auto glides the slides
    d.sound(at[1], cutoff=55, reso=10, envmod=120, attack=0, decay=6, sustain=0, release=3,
            ampmode=0, voicemode=0, saw=15, pulse=0, sub=11, subtype=0, pw=0, pwm=0,
            lforate=8, lfoshape=0, lfodelay=0, vibrato=0, lfocut=0, modwheel=0, accent=10,
            glide=4, glidemode=2, volume=15)
    # 2. lead (entry 4): saw + pulse, PWM, delayed vibrato, glide on slides
    d.sound(at[4], cutoff=140, reso=4, envmod=60, attack=2, decay=9, sustain=10, release=6,
            saw=11, pulse=14, sub=0, pw=2, pwm=8, lforate=9, lfodelay=8, vibrato=5, accent=8,
            glide=5)
    # 3. sync riff (entries 5-7): Sync mode, the envelope's sweep, sub under it
    d.sound(at[5], voicemode=1, cutoff=180, reso=3, envmod=40, attack=0, decay=7, sustain=6,
            release=4, saw=6, pulse=15, sub=9, syncpitch=30, syncenv=150, lfodelay=0,
            vibrato=0, pwm=0, accent=12, glide=3)
    # 4. bounce (entries 8-9): 101 mode again, random LFO on the cutoff
    d.sound(at[8], voicemode=0, cutoff=70, reso=11, envmod=90, decay=5, sustain=0,
            release=2, saw=15, pulse=0, sub=12, lforate=12, lfoshape=2, lfocut=6, accent=10)
    return d.ev, total * STEP


def heavy_events(c64=False):
    """TEST_MIDI=7: the heaviest sound for the engine (demo C's last part:
    Sync mode, noise on the cutoff, delayed vibrato, the wheel, accent),
    set once at the start; tools/seq_check.py plays pattern 3 over it with
    the step screen open. c64: the heaviest C64 mode sound instead (the
    echo, a click, the PWM sweep, a chord, the same modulation). Returns (events, end)."""
    d = Demo()
    if c64:
        d.sound(30, voicemode=2, lfoshape=LFO["noise"], lfocut=6, lfodelay=9, vibrato=5,
                modwheel=60, cutoff=150, reso=5, envmod=40, decay=9, sustain=10, release=6,
                saw=8, pulse=15, sub=8, pw=3, pwm=12, click=8, glide=4, glidemode=2, accent=12,
                chord=2, chordspeed=0)          # (a major chord, a note a frame)
        return d.ev, 60 * TICK_HZ
    d.sound(30, voicemode=1, lfoshape=LFO["noise"], lfocut=6, lfodelay=9, vibrato=5,
            modwheel=60, cutoff=150, reso=5, envmod=40, decay=9, sustain=10, release=6,
            saw=6, pulse=15, sub=8, syncpitch=40, syncenv=110, glide=4, glidemode=2, accent=12)
    return d.ev, 60 * TICK_HZ


ARP = {"off": 0, "up": 1, "down": 2, "updown": 3, "random": 4}   # P_ARP values
ARP_RATE = {8: 0, 16: 1, 32: 2}                                     # P_ARPRATE values


class Feed:
    """A test feed's MIDI events, in order: [(tick, [bytes])], channel 1."""

    def __init__(self):
        self.ev = []

    def cc(self, t, name, value):
        self.ev.append((t, [0xB0, CC[name], cc_value(name, value)]))

    def arp(self, t, mode=None, octaves=None, rate=None):
        # one controller a tick, from t on
        for name, v in (("ARP", None if mode is None else ARP[mode]),
                        ("ARPRANGE", None if octaves is None else octaves - 1),
                        ("ARPRATE", None if rate is None else ARP_RATE[rate])):
            if v is not None:
                self.cc(t, name, v)
                t += 1

    # several notes one a tick from t on (MIDI brings a message a
    # millisecond; a burst fed in one tick would hold the engine up)
    def on(self, t, *notes, vel=100):
        for i, n in enumerate(notes):
            self.ev.append((t + i, [0x90, n, vel]))

    def off(self, t, *notes):
        for i, n in enumerate(notes):
            self.ev.append((t + i, [0x90, n, 0]))


def arp_events():
    """TEST_MIDI=8 (tools/arp_check.py): the arpeggiator on the internal
    clock at 125 BPM, every mode, range and rate, keys added and let go
    while it plays, a ninth key (not played), turned off with keys held
    (the newest sounds on), turned on with keys held (it takes them), the
    mode and range changed while it plays. Returns (events, end)."""
    f = Feed()
    f.arp(20, "up", 1, 16)
    f.on(30, 48, vel=100)
    f.on(30, 52, vel=90)
    f.on(30, 55, vel=80)
    f.off(230, 48, 52, 55)
    f.arp(260, "down", 2)
    f.on(270, 50, 57, vel=110)
    f.on(300, 53, vel=70)                   # a key added: in its place
    f.off(420, 50)                          # one let go
    f.off(520, 57, 53)
    f.arp(560, "updown", 3)
    f.on(570, 45, 52, vel=95)
    f.on(780, 60, vel=105)
    f.off(900, 45)
    f.off(910, 52)
    f.off(920, 60)
    f.arp(960, "random", 2, 32)
    f.on(970, 40, 43, 47, 50, 55, 59, 62, 64, vel=120)
    f.on(980, 67, vel=60)                   # the ninth: not held
    f.off(1200, 40, 43, 47, 50, 55, 59, 62, 64, 67)
    f.arp(1240, "up", 1, 8)
    f.on(1250, 60, vel=64)                  # one key, 1/8
    f.off(1400, 60)
    f.arp(1430, octaves=2, rate=16)
    f.on(1440, 48, vel=100)
    f.on(1442, 55, vel=77)
    f.arp(1560, "off")                      # keys held: the newest (55) sounds on
    f.off(1600, 48)
    f.off(1620, 55)
    f.on(1660, 48, vel=90)                  # arpeggiator off: the voice, legato
    f.on(1680, 52, vel=85)
    f.arp(1700, "up", 1)                    # on with the keys held: it takes them
    f.off(1850, 48, 52)
    f.arp(1880, "updown")
    f.on(1890, 48, 52, 55, vel=100)
    f.arp(1990, "down")                     # the mode while it plays
    f.arp(2090, octaves=3)                  # the range while it plays
    f.off(2200, 48, 52, 55)
    f.arp(2230, "off", 1)
    return f.ev, 2300


ARP_CLOCK_TICKS = 5                         # TEST_MIDI=9: a MIDI clock every 5 ticks (125 BPM)


def arp_clock_events():
    """TEST_MIDI=9 with TEST_CLOCK=1 (tools/arp_check.py): the arpeggiator
    on MIDI clock: clocks from tick 30 with the sequencer stopped (no start
    yet: the steps count from power on), keys held at 1/16 then 1/8 and
    1/32; MIDI start (the next clock a step, the pattern from its start;
    the sequencer plays pattern 1 too: its notes go to the voice, not to
    the arpeggiator), stop, continue. Keys and clocks never share a tick.
    Returns (events, end)."""
    f = Feed()
    f.arp(20, "up", 2, 16)
    t, clocks = 30, []
    while t < 1500:
        clocks.append(t)
        t += ARP_CLOCK_TICKS
    for c in clocks:
        f.ev.append((c, [0xF8]))
    f.on(52, 60, 64, 67, vel=100)
    f.arp(301, rate=8)
    f.arp(451, rate=32)
    f.arp(601, rate=16)
    f.ev.append((702, [0xFA]))              # start
    f.ev.append((1002, [0xFC]))             # stop (the clocks go on: a master that keeps clocking)
    f.ev.append((1102, [0xFB]))             # continue
    f.off(1302, 60, 64, 67)
    f.ev.append((1352, [0xFC]))
    f.ev.sort(key=lambda e: e[0])           # (stable: same-tick order kept)
    return f.ev, 1600


STREAM_START = 500                          # TEST_MIDI=11: the controller stream, ticks
STREAM_TICKS = 350


def arp_heavy_events(stream=False, arp=True, c64=False):
    """TEST_MIDI=10: the load test's sound (heavy_events) with the
    arpeggiator at its busiest: Random, 3 octaves, 1/32, eight keys held
    for the whole run; tools/arp_check.py plays pattern 3 over it with the
    step screen open. The feed is set once: it is 200 s long, so it doesn't
    start again (and send the sound again) while the test runs.
    stream (TEST_MIDI=11): also a cutoff sweep, a controller every tick for
    STREAM_TICKS ticks from STREAM_START, in running status (a knob
    turned fast: MIDI's limit is about a controller a millisecond). arp=False (TEST_MIDI=12):
    the same without the arpeggiator, for comparison. c64 (TEST_MIDI=18):
    TEST_MIDI=11 over the heaviest C64 mode sound."""
    ev, _end = heavy_events(c64)
    f = Feed()
    if arp:
        f.arp(40, "random", 3, 32)
        f.on(50, 40, 43, 47, 50, 55, 59, 62, 64, vel=127)
    if stream:
        for i in range(STREAM_TICKS):
            pos = i % 200 / 100
            v = cc_value("CUTOFF", 2 * round(50 + 50 * (pos if pos <= 1 else 2 - pos)))
            msg = [0xB0, CC["CUTOFF"], v] if i == 0 else [CC["CUTOFF"], v]   # running status
            f.ev.append((STREAM_START + i, msg))
    return sorted([(t, m) for t, _, m in ev] + f.ev, key=lambda e: e[0]), 200 * TICK_HZ


E_LEAD_IN = 40                          # demo E's first sound() sends 30 controllers


def demo_e():
    """TEST_MIDI=13, demos/e-arpeggiator.wav: the arpeggiator on the
    internal clock at 125 BPM, a part per mode. Each part starts it afresh
    (its keys down, its first step a tick after the first key); the chords
    change between two steps, the new keys down before the old ones up, so
    it never stops and keeps its time. Returns (events, end)."""
    d = Demo()

    def keys_on(t, notes, vel):
        for i, n in enumerate(notes):           # one a tick, as MIDI brings them
            d.ev.append((t + i, 2, [0x90, n, vel]))

    def keys_off(t, notes):
        for i, n in enumerate(notes):
            d.ev.append((t + i, 1, [0x90, n, 0]))

    def part(t0, chords, bars_each, vel=100):
        """chords in turn for bars_each bars each, the first keys at t0 - 1
        (its first step at t0); the last ones up 20 ticks before the end,
        before the next part's controllers."""
        grid = t0
        keys_on(t0 - 1, chords[0], vel)
        held = chords[0]
        for k, chord in enumerate(chords[1:], 1):
            at = grid + round(k * bars_each * BAR)
            new = [n for n in chord if n not in held]
            keys_on(at - 12, new, vel)          # between the steps at at - 30 and at
            keys_off(at - 6, [n for n in held if n not in chord])
            held = chord
        end = grid + round(len(chords) * bars_each * BAR) - 20
        keys_off(end, held)
        return held

    # 1. Up, 1 octave, 1/16 (bars 0-2): a bass pluck, Cm, Ab, Bb
    t0 = E_LEAD_IN
    d.sound(t0 - 2, voicemode=0, cutoff=60, reso=10, envmod=120, attack=0, decay=5, sustain=0,
            release=2, ampmode=0, saw=15, pulse=0, sub=10, subtype=0, pw=0, pwm=0,
            lforate=8, lfoshape=LFO["triangle"], lfodelay=0, vibrato=0, lfocut=0, modwheel=0,
            accent=0, glide=0, glidemode=0, volume=15, arp=ARP["up"], arprange=0, arprate=1)
    part(t0, [(36, 39, 43), (32, 36, 39), (34, 38, 41)], 1)

    # 2. Up & down, 2 octaves, 1/16 (bars 3-5): saw and PWM pulse, Cm7, Fm7
    t0 = E_LEAD_IN + 3 * BAR
    d.sound(t0 - 2, cutoff=140, reso=4, envmod=60, decay=8, sustain=8, release=4, saw=12,
            pulse=12, sub=0, pwm=6, lforate=7, arp=ARP["updown"], arprange=1)
    part(t0, [(48, 51, 55, 58), (53, 56, 60, 63)], 1.5)

    # 3. Down, 3 octaves, 1/32 (bars 6-8): the sync lead, Eb then Db
    t0 = E_LEAD_IN + 6 * BAR
    d.sound(t0 - 2, voicemode=1, syncpitch=30, syncenv=90, cutoff=170, reso=3, envmod=40,
            decay=6, sustain=6, release=3, saw=6, pulse=15, sub=6, pwm=0,
            arp=ARP["down"], arprange=2, arprate=2)
    part(t0, [(51, 55, 58), (49, 53, 56)], 1.5)

    # 4. Random, 2 octaves, 1/16, glide on (bars 9-11): resonant, the notes
    # gliding into each other, Cm9
    t0 = E_LEAD_IN + 9 * BAR
    d.sound(t0 - 2, voicemode=0, syncpitch=0, syncenv=0, cutoff=80, reso=12, envmod=110,
            decay=7, sustain=3, release=3, saw=15, pulse=0, sub=8, glide=3, glidemode=1,
            arp=ARP["random"], arprange=1, arprate=1)
    part(t0, [(48, 51, 55, 58, 62)], 3)

    # 5. Up, 1 octave, 1/8 (bars 12-13), then the arpeggiator off with the
    # keys held: the newest key sounds on, held, until let go
    t0 = E_LEAD_IN + 12 * BAR
    d.sound(t0 - 2, cutoff=120, reso=6, envmod=70, decay=9, sustain=9, release=8, saw=13,
            pulse=10, sub=8, pwm=8, glide=0, glidemode=0, arp=ARP["up"], arprange=0, arprate=0)
    keys_on(t0 - 1, (48, 52, 55, 60), 100)
    off_at = t0 + BAR + 3 * BAR // 4
    d.cc(off_at, "ARP", ARP["off"])             # C5, the newest, sounds on
    keys_off(off_at + BAR, (48, 52, 55, 60))
    return d.ev, off_at + 2 * BAR


def demo_e_feed():
    """demo_e() as the TEST_MIDI=13 test_feed pattern."""
    events, end = demo_e()
    return feed_entries([(t, m) for t, _, m in sorted(events, key=lambda e: (e[0], e[1]))], end)


def demo_d_feed():
    """demo_d() as the TEST_MIDI=6 test_feed pattern."""
    events, end = demo_d()
    return feed_entries([(t, m) for t, _, m in events], end)


def demo_events(n=1):
    """The events and end tick of demo TEST_MIDI=n (tools/voice_check.py)."""
    return DEMOS[n]()


def test_pattern(n):
    """Demo n as a test_feed pattern (core/test_feed.asm): entries of
    count, bytes..., ticks to the next entry; count 0 = end (restart)."""
    events, end = demo_events(n)
    events.sort(key=lambda e: (e[0], e[1]))
    entries = []
    for t, _, msg in events:
        if entries and entries[-1][0] == t:
            entries[-1][1].extend(msg)
        else:
            entries.append((t, list(msg)))
    data = []
    for i, (t, b) in enumerate(entries):
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        wait = nxt - t - 1                # test_feed: emits, then waits this many ticks
        while wait > 255:                 # long gaps: active sensing ($FE, ignored) between
            data += [len(b)] + b + [255]
            b = [0xFE]
            wait -= 256
        assert 0 < len(b) < 256
        data += [len(b)] + b + [wait]
    data.append(0)
    return (f".if TEST_MIDI == {n}\n"
            + table("test_pattern", data, f"TEST_MIDI={n}: {DEMOS[n].__doc__.split(':')[0]}")
            + ".endif\n")


# -----------------------------------------------------------------------------
# Presets (src/presets.asm): 32 slots of the 34 sound parameters (Cutoff to
# Volume, the P_* order) and a 12-character name. The factory set is built
# from the sounds of demos A-E; the slots after it hold the start sound,
# named "Init". presets.inc holds them at the program's very end
# (factory_presets: copied to PRESET_RAM at start).
# -----------------------------------------------------------------------------
PRESET_ORDER = ["CUTOFF", "RESO", "ENVMOD", "ATTACK", "DECAY", "SUSTAIN", "RELEASE", "AMPMODE",
                "VOICEMODE", "SAW", "PULSE", "SUB", "SUBTYPE", "PW", "PWM", "SYNCPITCH",
                "SYNCENV", "CHORD", "CHORDSPEED", "CLICK", "LFORATE", "LFOSHAPE", "LFODELAY", "VIBRATO", "LFOCUT", "MODWHEEL",
                "ACCENT", "GLIDE", "GLIDEMODE", "ARP", "ARPRANGE", "ARPRATE", "TUNE", "VOLUME"]
NUM_PRESETS = 32
PRESET_NAME_LEN = 12
# the start sound: src/params.asm's param_default, Cutoff to Volume (slot 1
# must be exactly this: tools/preset_check.py checks it in VICE)
START_SOUND = dict(CUTOFF=90, RESO=6, ENVMOD=120, ATTACK=0, DECAY=6, SUSTAIN=4, RELEASE=3,
                   AMPMODE=0, VOICEMODE=0, SAW=15, PULSE=0, SUB=10, SUBTYPE=0, PW=0, PWM=0,
                   SYNCPITCH=0, SYNCENV=0, CHORD=0, CHORDSPEED=0, CLICK=0, LFORATE=8, LFOSHAPE=0, LFODELAY=0, VIBRATO=0,
                   LFOCUT=0, MODWHEEL=0, ACCENT=0, GLIDE=4, GLIDEMODE=2, ARP=0, ARPRANGE=0,
                   ARPRATE=1, TUNE=16, VOLUME=15)
PRESET_MAX = dict(MAX, TUNE=31)
# (name, the changes from the start sound, what plays it in demo G: "bass",
# "lead" or "arp")
# C64 mode's base sounds for the presets: demo H's lead, demo H2's chords
C64_LEAD = dict(VOICEMODE=2, CUTOFF=210, RESO=2, ENVMOD=20, DECAY=11, SUSTAIN=12, RELEASE=6,
                SAW=0, PULSE=15, SUB=0, PW=3, PWM=6, LFORATE=11, LFODELAY=6, VIBRATO=5,
                GLIDEMODE=0)
C64_CHORD = dict(VOICEMODE=2, CUTOFF=200, RESO=3, ENVMOD=30, DECAY=11, SUSTAIN=12, RELEASE=7,
                 SAW=7, PULSE=15, SUB=0, PW=4, PWM=5, LFORATE=11, GLIDEMODE=0, CHORDSPEED=0)
FACTORY = [
    ("Saw + sub", {}, "bass"),
    ("Plucked bass", dict(CUTOFF=60, RESO=7, ENVMOD=150, DECAY=5, SUSTAIN=0, RELEASE=2,
                          AMPMODE=1, SUB=11), "bass"),
    ("Squelch bass", dict(CUTOFF=45, RESO=13, ENVMOD=220, DECAY=6, SUSTAIN=0, RELEASE=2,
                          AMPMODE=1, SUB=11, ACCENT=8), "bass"),
    ("Acid 101", dict(CUTOFF=55, RESO=10, ENVMOD=120, DECAY=6, SUSTAIN=0, RELEASE=3, SUB=11,
                      ACCENT=10), "bass"),
    ("Sub bass", dict(CUTOFF=70, RESO=3, ENVMOD=40, DECAY=8, SUSTAIN=12, RELEASE=4, AMPMODE=1,
                      SAW=8, SUB=15, SUBTYPE=1), "bass"),
    ("Square bass", dict(CUTOFF=70, RESO=5, ENVMOD=100, DECAY=5, SUSTAIN=2, RELEASE=2,
                         AMPMODE=1, SAW=0, PULSE=15, SUB=10), "bass"),
    ("Bounce bass", dict(CUTOFF=70, RESO=11, ENVMOD=90, DECAY=5, SUSTAIN=0, RELEASE=2, SUB=12,
                         LFORATE=12, LFOSHAPE=2, LFOCUT=6, ACCENT=10), "bass"),
    ("Wobble bass", dict(CUTOFF=60, RESO=11, ENVMOD=40, DECAY=8, SUSTAIN=15, AMPMODE=1, SUB=12,
                         LFORATE=10, LFOCUT=12), "bass"),
    ("Sync bass", dict(VOICEMODE=1, CUTOFF=110, RESO=6, ENVMOD=110, DECAY=5, SUSTAIN=0,
                       RELEASE=2, AMPMODE=1, SAW=8, PULSE=13, SUB=12, SYNCENV=120), "bass"),
    ("PWM lead", dict(CUTOFF=130, RESO=4, ENVMOD=70, ATTACK=3, DECAY=9, SUSTAIN=10, RELEASE=7,
                      SAW=10, PULSE=15, SUB=0, PW=3, PWM=11, LFORATE=8, LFODELAY=8, VIBRATO=4,
                      GLIDE=6, GLIDEMODE=1), "lead"),
    ("Hollow lead", dict(CUTOFF=140, RESO=4, ENVMOD=60, ATTACK=2, DECAY=9, SUSTAIN=10,
                         RELEASE=6, SAW=11, PULSE=14, SUB=0, PW=2, PWM=8, LFORATE=9,
                         LFODELAY=8, VIBRATO=5, ACCENT=8, GLIDE=5), "lead"),
    ("Fat lead", dict(CUTOFF=150, RESO=5, ENVMOD=50, DECAY=8, SUSTAIN=12, RELEASE=6, SAW=15,
                      PULSE=12, SUB=6, PW=4, PWM=5, LFORATE=9, LFODELAY=8, VIBRATO=3, GLIDE=5,
                      GLIDEMODE=1), "lead"),
    ("Trill lead", dict(CUTOFF=150, RESO=4, ENVMOD=40, DECAY=10, SUSTAIN=11, RELEASE=5, SAW=8,
                        PULSE=15, SUB=0, PW=2, LFORATE=8, LFOSHAPE=1, VIBRATO=7), "lead"),
    ("Delay vibe", dict(CUTOFF=140, RESO=3, ENVMOD=60, ATTACK=2, DECAY=10, SUSTAIN=10,
                        RELEASE=7, SAW=12, PULSE=12, SUB=0, PWM=6, LFORATE=9, LFODELAY=11,
                        VIBRATO=6), "lead"),
    ("Sync riff", dict(VOICEMODE=1, CUTOFF=200, RESO=2, ENVMOD=30, DECAY=7, SUSTAIN=11,
                       RELEASE=5, SAW=0, PULSE=15, SUB=8, SYNCPITCH=20, SYNCENV=200,
                       GLIDE=3), "lead"),
    ("Sync lead", dict(VOICEMODE=1, CUTOFF=170, RESO=3, ENVMOD=40, DECAY=10, SUSTAIN=8,
                       RELEASE=8, SAW=6, PULSE=15, SUB=6, SYNCPITCH=60, SYNCENV=90, LFORATE=9,
                       LFODELAY=8, VIBRATO=4, GLIDE=6, GLIDEMODE=1), "lead"),
    ("Sync scream", dict(VOICEMODE=1, CUTOFF=150, RESO=5, ENVMOD=40, DECAY=9, SUSTAIN=10,
                         RELEASE=6, SAW=6, PULSE=15, SUB=8, SYNCPITCH=40, SYNCENV=110,
                         LFOSHAPE=3, LFODELAY=9, VIBRATO=5, LFOCUT=6, ACCENT=12), "lead"),
    ("S&H burble", dict(CUTOFF=90, RESO=12, ENVMOD=0, DECAY=8, SUSTAIN=15, RELEASE=5, SUB=9,
                        LFORATE=11, LFOSHAPE=2, LFOCUT=15), "lead"),
    ("Perc blip", dict(CUTOFF=100, RESO=10, ENVMOD=200, DECAY=3, SUSTAIN=0, RELEASE=3, SAW=0,
                       PULSE=15, SUB=0, PW=10), "lead"),
    ("Arp pluck", dict(CUTOFF=60, RESO=10, ENVMOD=120, DECAY=5, SUSTAIN=0, RELEASE=2,
                       GLIDE=0, GLIDEMODE=0, ARP=1), "arp"),
    ("Arp PWM", dict(CUTOFF=140, RESO=4, ENVMOD=60, DECAY=8, SUSTAIN=8, RELEASE=4, SAW=12,
                     PULSE=12, SUB=0, PWM=6, LFORATE=7, GLIDEMODE=0, ARP=3, ARPRANGE=1), "arp"),
    ("Arp sync", dict(VOICEMODE=1, CUTOFF=170, RESO=3, ENVMOD=40, DECAY=6, SUSTAIN=6,
                      RELEASE=3, SAW=6, PULSE=15, SUB=6, SYNCPITCH=30, SYNCENV=90, GLIDEMODE=0,
                      ARP=2, ARPRANGE=2, ARPRATE=2), "arp"),
    ("Arp glide", dict(CUTOFF=80, RESO=12, ENVMOD=110, DECAY=7, SUSTAIN=3, RELEASE=3, SUB=8,
                       GLIDE=3, GLIDEMODE=1, ARP=4, ARPRANGE=1), "arp"),
    # C64 mode (Stage H, from demos H and H2): the pulse lead (Pulse) with its
    # echo (Saw), its own PWM sweep, vibrato after a delay, a click, chords
    ("C64 lead", dict(C64_LEAD), "lead"),
    ("Echo lead", dict(C64_LEAD, SAW=10), "lead"),
    ("Hubbard lead", dict(C64_LEAD, SAW=9, SUB=8, SUBTYPE=1, CLICK=2, LFODELAY=5, PWM=9), "lead"),
    ("Click pluck", dict(C64_LEAD, DECAY=6, SUSTAIN=6, RELEASE=4, CLICK=1, LFODELAY=0,
                         VIBRATO=0), "lead"),
    ("Octave lead", dict(C64_LEAD, SAW=7, CLICK=1, CHORD=9), "lead"),
    ("Major chord", dict(C64_CHORD, CHORD=2), "lead"),
    ("Minor chord", dict(C64_CHORD, CHORD=3), "lead"),
    ("Keys chord", dict(C64_CHORD, CHORD=1, CHORDSPEED=1), "arp"),
]


def presets():
    """The 32 slots: [(name, [34 values in PRESET_ORDER])]."""
    out = []
    for name, changes, _ in FACTORY:
        assert len(name) <= PRESET_NAME_LEN and all(k in START_SOUND for k in changes), name
        sound = dict(START_SOUND, **changes)
        for k, v in sound.items():
            assert 0 <= v <= PRESET_MAX[k], (name, k, v)
        out.append((name, [sound[k] for k in PRESET_ORDER]))
    while len(out) < NUM_PRESETS:
        out.append(("Init", [START_SOUND[k] for k in PRESET_ORDER]))
    return out


def presets_inc():
    """presets.inc: factory_presets (32 x 34 values, then 32 x 12 name
    characters in screen codes), included at the program's very end."""
    lines = ["; generated by tables.py: the factory presets (src/presets.asm)",
             f"NUM_PRESETS = {NUM_PRESETS}",
             f"PRESET_BYTES = {len(PRESET_ORDER)}",
             f"PRESET_NAME_LEN = {PRESET_NAME_LEN}",
             "factory_presets"]
    for name, values in presets():
        lines.append(f"        .byte {', '.join(str(v) for v in values)} ; {name}")
    lines.append('        .enc "screen"')
    for name, _ in presets():
        lines.append(f'        .text "{name:<{PRESET_NAME_LEN}}"')
    lines.append('        .enc "none"')
    lines.append("factory_end")
    lines.append(f"FACTORY_PRESETS = {len(FACTORY)}            ; the factory sounds (the rest: Init)")
    return "\n".join(lines) + "\n"


# phrases for demo G: (step, note, length in steps) over a bar
G_BASS = [(0, 36, 2), (2, 36, 1), (3, 48, 1), (4, 46, 2), (6, 43, 1), (7, 36, 2), (9, 39, 1),
          (10, 41, 2), (12, 43, 1), (13, 46, 1), (14, 48, 2)]
G_LEAD = [(0, 60, 3), (3, 63, 1), (4, 67, 4), (8, 70, 2), (10, 67, 2), (12, 65, 1), (13, 63, 3)]
G_ARP = (48, 51, 55, 58)


def demo_g():
    """TEST_MIDI=14, demos/g-presets.wav: each factory preset in turn, chosen
    by MIDI program change, playing a bar (two for the arpeggios): a bass
    line, a lead line or a held chord. Returns (events, end)."""
    d = Demo()
    t = 2 * STEP
    for slot, (_, _, kind) in enumerate(FACTORY):
        d.ev.append((t - 12, 0, [0xC0, slot]))        # program change, then a pause
        if kind == "arp":
            for i, n in enumerate(G_ARP):
                d.ev.append((t + i, 2, [0x90, n, 100]))
            for n in G_ARP:
                d.ev.append((t + 2 * BAR - 20, 1, [0x90, n, 0]))
            t += 2 * BAR
        else:
            d.line(t, G_BASS if kind == "bass" else G_LEAD)
            t += BAR
    return d.ev, t + BAR


def demo_g_times():
    """Demo G's listening guide: [(seconds, slot, name)] (the WAV starts at
    the first note: trimmed)."""
    out, t = [], 2 * STEP
    for slot, (name, _, kind) in enumerate(FACTORY):
        out.append(((t - 2 * STEP) / TICK_HZ, slot + 1, name))
        t += 2 * BAR if kind == "arp" else BAR
    return out


PRESET_TEST_GAP = 100                   # ticks between the program changes (TEST_MIDI=15)
PRESET_TEST_VOLUME = 10                 # ... set first: a recall must keep them
PRESET_TEST_WHEEL = 128


def preset_test_events():
    """TEST_MIDI=15 (tools/preset_check.py): Volume and the mod wheel set
    (a recall keeps them), then a program change to every slot, then to 40
    and 127 (ignored), PRESET_TEST_GAP ticks apart, each followed half way
    by a Resonance controller (the sound edited). Returns (events, end)."""
    ev = [(20, 0, [0xB0, CC["VOLUME"], cc_value("VOLUME", PRESET_TEST_VOLUME)]),
          (21, 0, [0xB0, CC["MODWHEEL"], cc_value("MODWHEEL", PRESET_TEST_WHEEL)])]
    t = 50
    for p in list(range(NUM_PRESETS)) + [40, 127]:
        ev.append((t, 0, [0xC0, p]))
        ev.append((t + PRESET_TEST_GAP // 2, 0, [0xB0, CC["RESO"], 127]))
        t += PRESET_TEST_GAP
    return ev, t + 200


def preset_heavy_events():
    """TEST_MIDI=16 (tools/preset_check.py): the load test for presets, an
    80-tick loop (the feed starts again at its end): program change to Sync
    scream, 40 ticks later to Sync lead (the heaviest sounds: Sync mode,
    noise or delayed vibrato), and a Cutoff controller on every other tick
    between; tools/preset_check.py plays pattern 3 over it with the step
    screen open. Returns (events, end)."""
    names = [n for n, _, _ in FACTORY]
    ev = [(0, 0, [0xC0, names.index("Sync scream")]), (40, 0, [0xC0, names.index("Sync lead")])]
    for t in range(1, 80, 2):
        ev.append((t, 0, [0xB0, CC["CUTOFF"], 40 + t]))
    return ev, 80


def accent_tables():
    """accent_level, accent_env [ACCENT x 16 + velocity / 8] (note_accent): a
    soft note's level falls (at accent 15 velocity 1 is about half), a hard
    one's env mod rises (from velocity 64 up, up to +255 at 127). Accent 0:
    full level (15), no boost."""
    acc_level, acc_env = [], []
    for a in range(16):
        for b in range(16):
            v = min(127, b * 8 + 7)
            acc_level.append(15 - round(a / 15 * (127 - v) / 127 * 8))
            acc_env.append(min(255, round(a / 15 * 255 * max(0, v - 64) / 63)))
    return acc_level, acc_env


RNG_TAPS = 0xB4                 # src/engine.asm: the LFSR's feedback into the high byte


def lfsr8():
    """random_byte's table: what 8 steps of the right-shifting Galois LFSR
    (bit 0 out; when it is 1, RNG_TAPS into the high byte) XOR in, by the
    low byte shifted out: bit i out at step i + 1 puts the taps in, then 7 - i
    more steps move them down. Checked against the steps themselves."""
    out = []
    for b in range(256):
        v = 0
        for i in range(8):
            if b >> i & 1:
                v ^= (RNG_TAPS << 8) >> (7 - i)
        out.append(v)
    for s in range(1, 65536, 97):
        t = s
        for _ in range(8):
            c, t = t & 1, t >> 1
            if c:
                t ^= RNG_TAPS << 8
        assert t == (s >> 8) ^ out[s & 255]
    return out


def level_tab():
    """Voice level by [mix level x 16 + amp] (both 0..15)."""
    return [round(m * a / 15) for m in range(16) for a in range(16)]


def main():
    parts = [tick_latch(), freq_tables(), sq_tables()]

    # filter cutoff: SID303's curve, log index 0..255 = 40 Hz..12 kHz,
    # mapped onto the 8580's roughly linear 11-bit register
    regs = []
    for i in range(256):
        hz = geo(40.0, 12000.0, i, 256)
        regs.append(max(0, min(2047, round((hz - 30.0) * 2047 / 12000.0))))
    parts.append(table("cutoff_lo", [r & 7 for r in regs],
                       "filter cutoff register bits 0-2 ($D415) per log-cutoff index 0..255"))
    parts.append(table("cutoff_hi", [r >> 3 for r in regs], "filter cutoff register bits 3-10 ($D416)"))

    # envelope attack: linear rise, 0 = instant, 1..15 = 5 ms .. 3 s
    att = [65535] + [min(65535, max(1, round(65535 / (geo(0.005, 3.0, i, 15) * TICK_HZ))))
                     for i in range(15)]
    parts.append(table("attack_inc_lo", [a & 255 for a in att],
                       "ATTACK 0..15: envelope rise per tick (0 instant, 5 ms .. 3 s), low bytes"))
    parts.append(table("attack_inc_hi", [a >> 8 for a in att], "high bytes"))

    # decay and release: exponential, time constant 4 ms .. 4 s
    dec = [k16(geo(0.004, 4.0, i, 16)) for i in range(16)]
    parts.append(table("decay_k_lo", [d & 255 for d in dec],
                       "DECAY / RELEASE 0..15: env_decay factor (time constant 4 ms .. 4 s), low bytes"))
    parts.append(table("decay_k_hi", [d >> 8 for d in dec], "high bytes"))

    # glide: an RC-like approach in pitch, 0 = at once, 1..15 = 10 ms .. 1.5 s
    parts.append(table("glide_k", [255] + [k8(geo(0.010, 1.5, i, 15)) for i in range(15)],
                       "GLIDE 0..15: per-tick approach factor /256 (time constant 10 ms .. 1.5 s)"))

    # LFO rate: 0.1 .. 30 Hz, 16-bit phase increment per tick
    rates = [round(65536 * geo(0.1, 30.0, i, 16) / (985248 / (TICK_LATCH + 1))) for i in range(16)]
    parts.append(table("lfo_inc_lo", [r & 255 for r in rates], "LFO RATE 0..15: phase step per tick (0.1 .. 30 Hz), low bytes"))
    parts.append(table("lfo_inc_hi", [r >> 8 for r in rates], "high bytes"))

    # LFO delay: a linear fade-in, 0 = none, 1..15 = 0.1 .. 4 s
    fade = [65535] + [max(1, round(65536 / (geo(0.1, 4.0, i, 15) * TICK_HZ))) for i in range(15)]
    parts.append(table("lfo_fade_lo", [f & 255 for f in fade],
                       "LFO DELAY 0..15: fade-in step per tick (none, 0.1 .. 4 s), low bytes"))
    parts.append(table("lfo_fade_hi", [f >> 8 for f in fade], "high bytes"))

    # accent: [ACCENT x 16 + velocity / 8] (accent_tables)
    acc_level, acc_env = accent_tables()
    parts.append(table("accent_level", acc_level,
                       "ACCENT x 16 + velocity/8: the note's level factor 0..15 (note_accent)"))
    parts.append(table("accent_env", acc_env, "ACCENT x 16 + velocity/8: env mod boost 0..255"))

    # pulse width: PW 0..15 = 50 % .. ~9 % (12-bit register: $800 = 50 %)
    pw = [0x800 - i * 0x70 for i in range(16)]
    parts.append(table("pw_base_lo", [p & 255 for p in pw], "PULSE WIDTH 0..15: register value (50 % .. 9 %), low bytes"))
    parts.append(table("pw_base_hi", [p >> 8 for p in pw], "high bytes"))

    # Tune 0..31: (TUNE - 16) x 8 as a signed 16-bit pitch offset (pitch_to_sid)
    tune = [((t - 16) * 8) & 0xFFFF for t in range(32)]
    parts.append(table("tune_lo", [v & 255 for v in tune], "TUNE 0..31: pitch offset (TUNE - 16) x 8, low bytes"))
    parts.append(table("tune_hi", [v >> 8 for v in tune], "high bytes (signed)"))

    # C64 mode's PWM sweep (pw_update): PWM 1..15 = 0.1 .. 4 Hz, a triangle
    # of the 16-bit phase; PWM 0 = no sweep
    sweep = [0] + [round(65536 * geo(0.1, 4.0, i - 1, 15) / (985248 / (TICK_LATCH + 1))) for i in range(1, 16)]
    parts.append(table("sweep_rate_lo", [v & 255 for v in sweep],
                       "PWM 0..15 in C64 mode: the sweep's phase step a tick (0, 0.1 .. 4 Hz), low bytes"))
    parts.append(table("sweep_rate_hi", [v >> 8 for v in sweep], "high bytes"))

    # voice level = mix level x amp envelope, both 4 bits: [mix x 16 + amp]
    parts.append(table("level_tab", level_tab(),
                       "voice level 0..15 by mix level (x 16) and amp envelope 0..15 (levels_update)"))

    # random_byte: 8 steps of the 16-bit Galois LFSR at once (lfsr8)
    lfsr = lfsr8()
    parts.append(f"LFSR8_TAPS = ${RNG_TAPS:02x}\n")
    parts.append(table("lfsr8_lo", [v & 255 for v in lfsr],
                       "random_byte: the feedback of 8 LFSR steps by the low byte shifted out, low bytes"))
    parts.append(table("lfsr8_hi", [v >> 8 for v in lfsr], "high bytes"))

    for n in DEMOS:
        parts.append(test_pattern(n))
    entries, end = feed_events()
    parts.append(".if TEST_MIDI == 4\n" + table("test_pattern", feed_entries(entries, end),
                 "TEST_MIDI=4: pattern 1 fed through the MIDI parser (tools/seq_check.py)") + ".endif\n")
    parts.append(".if TEST_MIDI == 5\n" + table(
        "test_pattern", feed_entries([(0, [0xFE])] + clock_events(), clock_events()[-1][0] + 60 * TICK_HZ),
        "TEST_MIDI=5: MIDI clock in (tools/seq_check.py)") + ".endif\n")
    parts.append(".if TEST_MIDI == 6\n" + table("test_pattern", demo_d_feed(),
                 "TEST_MIDI=6: demo D's sound, with TEST_SEQ=1 TEST_SONG=2") + ".endif\n")
    events, end = heavy_events()
    parts.append(".if TEST_MIDI == 7\n" + table("test_pattern", feed_entries([(t, m) for t, _, m in events], end),
                 "TEST_MIDI=7: the heaviest sound (tools/seq_check.py)") + ".endif\n")
    events, end = arp_events()
    parts.append(".if TEST_MIDI == 8\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=8: the arpeggiator, internal clock (tools/arp_check.py)") + ".endif\n")
    events, end = arp_clock_events()
    parts.append(".if TEST_MIDI == 9\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=9: the arpeggiator on MIDI clock (tools/arp_check.py)") + ".endif\n")
    events, end = arp_heavy_events()
    parts.append(".if TEST_MIDI == 10\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=10: the arpeggiator's load test (tools/arp_check.py)") + ".endif\n")
    events, end = arp_heavy_events(stream=True)
    parts.append(".if TEST_MIDI == 11\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=11: the load test with a controller every tick (tools/arp_check.py)")
                 + ".endif\n")
    parts.append(".if TEST_MIDI == 13\n" + table("test_pattern", demo_e_feed(),
                 "TEST_MIDI=13: demo E, the arpeggiator (demos/e-arpeggiator.wav)") + ".endif\n")
    events, end = arp_heavy_events(stream=True, c64=True)
    parts.append(".if TEST_MIDI == 18\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=18: TEST_MIDI=11 over the heaviest C64 mode sound (tools/arp_check.py)")
                 + ".endif\n")
    events, end = arp_heavy_events(stream=True, arp=False)
    parts.append(".if TEST_MIDI == 12\n" + table("test_pattern", feed_entries(events, end),
                 "TEST_MIDI=12: TEST_MIDI=11 without the arpeggiator (tools/arp_check.py)")
                 + ".endif\n")
    for n, (events, end), what in (
            (14, demo_g(), "demo G, the presets (demos/g-presets.wav)"),
            (15, preset_test_events(), "every preset by program change (tools/preset_check.py)"),
            (16, preset_heavy_events(), "program changes under load (tools/preset_check.py)")):
        events = sorted(events, key=lambda e: (e[0], e[1]))
        parts.append(f".if TEST_MIDI == {n}\n" + table("test_pattern", feed_entries(
            [(t, m) for t, _, m in events], end), f"TEST_MIDI={n}: {what}") + ".endif\n")
    parts.append(seq_tables())

    with open("tables.inc", "w", newline="\n") as f:
        f.write("\n".join(parts))
    with open("presets.inc", "w", newline="\n") as f:
        f.write(presets_inc())
    print(f"tables.inc, presets.inc written (tick latch {TICK_LATCH})")


if __name__ == "__main__":
    main()
