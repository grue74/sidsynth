# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Glide Path: the band's own demo tune, written to show what the three
synths do, SID101's lead most of all. A MIDI file for Pro-16 (the same
road as the cover: record_cover.py, play_band.py, feeds.py).

    python glide_path.py work/glide-path.mid

125 BPM (SID101's own tempo at start, so its arpeggiator, on its internal
clock, keeps time with the song: every arpeggio chord is struck fresh),
A minor, 49 bars:

  bar  0      the synths' sounds set (controllers, one a clock); maracas count in
  bars 1-4    intro: SID303's acid line, its cutoff opening; hats, the kick
  bars 5-12   groove: SID101's soft filtered lead (saw, a little pulse
              with slow PWM, the filter's attack), the cutoff (CC 74)
              swelling on the long notes, the vibrato fading in (LFO
              delay), two slides (Glide mode Auto: only the notes written
              legato glide)
  bars 13-20  lead: an octave glide and two slides, the mod wheel's
              vibrato, a pitch bend scoop and a fall, a cutoff swell on a
              held note, accents (velocity); SID303's env mod rising
  bars 21-28  breakdown: SID101's arpeggiator (Up, Up & down, Random,
              Down at 1/32 over 3 octaves) with its cutoff opening; SID808's
              kick long and low (its Tune, Decay, Tone: CC 17-19 turn the
              selected sound, the kick at start), claves, cowbell, rim,
              toms; a snare roll
  bars 29-36  sync: the Sync voice, filtered, the sync pitch knob (CC 78)
              swept on every long note
  bars 37-44  finale: the soft lead an octave up and a little brighter,
              three slides, a trill (LFO shape Square); SID303's cutoff and
              resonance up
  bars 45-48  outro: one long note, the wheel's vibrato swelling, the
              cutoff closing; the release rings out

Channel 1 SID101, 2 SID303, 10 SID808, as the cover. Times are in MIDI
clocks (24 a beat), Pro-16's grid; the file has 96 ticks a beat. No
program changes: every sound is set with controllers, so the file is the
whole performance. Writes the cue sheet (what plays when) next to the file.
"""
import os
import sys

import mido

BPM = 125
PPQ = 96
TICKS_PER_CLOCK = PPQ // 24
BEAT = 24                       # clocks
BAR = 4 * BEAT
S16 = BEAT // 4                 # a 16th
BARS = 49
TITLE = "Glide Path - SidSynth demo"

# ---- the synths' controllers: (CC, the parameter's max value)
SID101 = dict(CUTOFF=(74, 255), RESO=(71, 15), ENVMOD=(20, 255), ATTACK=(73, 15),
              DECAY=(75, 15), SUSTAIN=(21, 15), RELEASE=(72, 15), AMPMODE=(22, 1),
              VOICEMODE=(31, 1), SAW=(23, 15), PULSE=(24, 15), SUB=(25, 15), SUBTYPE=(26, 2),
              PW=(27, 15), PWM=(28, 15), SYNCPITCH=(78, 255), SYNCENV=(79, 255),
              LFORATE=(76, 15), LFOSHAPE=(14, 3), LFODELAY=(15, 15), VIBRATO=(77, 15),
              LFOCUT=(29, 15), MODWHEEL=(1, 255), ACCENT=(16, 15), GLIDE=(5, 15),
              GLIDEMODE=(30, 2), ARP=(80, 4), ARPRANGE=(81, 2), ARPRATE=(82, 2),
              VOLUME=(7, 15))
SID303 = dict(CUTOFF=(74, 255), RESO=(71, 15), ENVMOD=(12, 255), DECAY=(75, 15),
              ACCENT=(13, 15), SLIDE=(5, 15), AMPDECAY=(72, 15), VOLUME=(7, 15))
SID808 = dict(VOLUME=(7, 15), LEVEL=(16, 15), TUNE=(17, 24), DECAY=(18, 15), TONE=(19, 15))
TUNE_CENTER = 12                # SID808's Tune: 0..24, 12 = as made
GM = dict(kick=36, rim=37, snare=38, clap=39, hat=42, ohat=46, tom_lo=41, tom_mid=45,
          tom_hi=48, cymbal=49, cowbell=56, claves=75, maracas=70)
ARP = dict(off=0, up=1, down=2, updown=3, random=4)
ARP_RATE = {8: 0, 16: 1, 32: 2}


def cc_value(m, value):
    """The CC value (0..127) that sets a parameter of max m to value: the
    core's param_set_v scales CC*2 (0..254) by (m+1)/256, so aim at the
    middle of the value's range; a full-range parameter (m 255) gets CC*2."""
    if m == 255:
        return min(127, value // 2)
    cc = max(0, min(127, round((value + 0.5) * 256 / (m + 1) / 2)))
    assert (cc * 2 * (m + 1)) >> 8 == value, (m, value, cc)
    return cc


# ---- SID101's sounds (the changes go out in the rests before a section)
# the lead: soft and filtered - saw with a little pulse (slow PWM for
# warmth) and a small sub, the cutoff low (about 500 Hz, the envelope
# opening it to about 1 kHz), the filter's attack
# letting each note bloom, a light accent; Glide mode Auto with a short
# glide, so only the notes written legato slide
LEAD = dict(VOICEMODE=0, CUTOFF=95, RESO=3, ENVMOD=50, ATTACK=3, DECAY=9, SUSTAIN=8,
            RELEASE=7, AMPMODE=0, SAW=12, PULSE=3, SUB=4, SUBTYPE=0, PW=4, PWM=3,
            SYNCPITCH=0, SYNCENV=0, LFORATE=6, LFOSHAPE=0, LFODELAY=8, VIBRATO=3,
            LFOCUT=0, MODWHEEL=0, ACCENT=4, GLIDE=4, GLIDEMODE=2, ARP=0, ARPRANGE=0,
            ARPRATE=1, VOLUME=15)
ARP_SOUND = dict(LEAD, VOICEMODE=0, SYNCPITCH=0, SYNCENV=0, CUTOFF=60, RESO=11, ENVMOD=130,
                 DECAY=5, SUSTAIN=0, RELEASE=2, SAW=15, PULSE=0, SUB=6, LFODELAY=0,
                 VIBRATO=0, ACCENT=6, GLIDEMODE=0, ARP=ARP["up"], ARPRANGE=1,
                 ARPRATE=ARP_RATE[16])
# the sync section: the Sync voice, but filtered down and its own sweep
# small, so the knob's sweeps are the show without the bite
SYNC = dict(LEAD, VOICEMODE=1, CUTOFF=115, RESO=4, ENVMOD=40, ATTACK=0, SAW=6, PULSE=15,
            SUB=6, PW=0, PWM=0, SYNCPITCH=20, SYNCENV=40, ACCENT=6)
FINALE = dict(LEAD, CUTOFF=105, SUB=5, VIBRATO=4)
BASS = dict(CUTOFF=20, RESO=12, ENVMOD=150, DECAY=6, ACCENT=10, SLIDE=8, AMPDECAY=15,
            VOLUME=15)


class Part:
    """One channel's messages: [(clock, order, bytes)]; order puts note offs
    first, then controllers and bends, then note ons."""

    def __init__(self, ch, ccs):
        self.ch, self.ccs, self.ev = ch, ccs, []
        self.sound = {}             # the parameters as last sent

    def raw(self, c, order, msg):
        self.ev.append((c, order, msg))

    def cc(self, c, name, value):
        num, m = self.ccs[name]
        self.raw(c, 1, [0xB0 | self.ch, num, cc_value(m, value)])
        self.sound[name] = value

    def set(self, c, sound):
        """The parameters of sound that differ from those sent, one a clock
        from clock c; returns the clock after the last."""
        for name, v in sound.items():
            if self.sound.get(name) != v:
                self.cc(c, name, v)
                c += 1
        return c

    def sweep(self, name, c0, c1, v0, v1, every=2):
        """Parameter name from v0 at clock c0 to v1 at clock c1, a value
        every `every` clocks while it changes."""
        num, m = self.ccs[name]
        last = None
        for c in range(c0, c1 + 1, every):
            v = round(v0 + (v1 - v0) * (c - c0) / max(1, c1 - c0))
            cv = cc_value(m, v)
            if cv != last:
                self.raw(c, 1, [0xB0 | self.ch, num, cv])
                last = cv
        if last != cc_value(m, v1):
            self.raw(c1, 1, [0xB0 | self.ch, num, cc_value(m, v1)])
        self.sound[name] = v1

    def bend(self, c, semis):
        """Pitch bend to semis (SID101: -2..+2 semitones)."""
        v = max(0, min(16383, round(8192 + semis * 8192 / 2)))
        self.raw(c, 1, [0xE0 | self.ch, v & 0x7F, v >> 7])

    def bend_sweep(self, c0, c1, s0, s1, every=2):
        for c in range(c0, c1 + 1, every):
            self.bend(c, s0 + (s1 - s0) * (c - c0) / max(1, c1 - c0))

    def note(self, c, n, length, vel=100):
        self.raw(c, 2, [0x90 | self.ch, n, vel])
        self.raw(c + length, 0, [0x80 | self.ch, n, 0])

    def phrase(self, c0, notes, gap=S16):
        """notes: [(beat, note, beats, velocity, legato)] from clock c0. A
        legato note holds a clock into the next (SID101 glides into it in
        Glide mode Auto); else it ends `gap` before the next begins."""
        for i, (beat, n, beats, vel, legato) in enumerate(notes):
            on = c0 + round(beat * BEAT)
            off = c0 + round((beat + beats) * BEAT)
            off = off + 1 if legato else off - gap
            self.raw(on, 2, [0x90 | self.ch, n, vel])
            self.raw(off, 0, [0x80 | self.ch, n, 0])


def bar(b):
    return b * BAR


# ---- SID303: a bar of the acid line on a root, 16 steps
# (step, interval, accent, slide into the next): an interval is semitones
# from the root, or "3" / "7" the chord's third / seventh in A minor (a
# slide never goes into the same pitch: its note off would end the next)
ACID = [(0, 0, 1, 0), (1, 0, 0, 0), (2, 12, 0, 1), (3, 7, 0, 0), (5, 0, 0, 0),
        (6, "7", 1, 0), (7, 0, 0, 0), (8, 12, 0, 1), (9, 7, 0, 0), (10, 0, 0, 0),
        (12, 0, 1, 0), (13, "3", 0, 0), (14, 12, 0, 1), (15, "7", 0, 0)]
THIRD = dict(A=3, F=4, C=4, G=4, D=3, E=4)        # the chords' thirds and sevenths, in key
SEVENTH = dict(A=10, F=11, C=11, G=10, D=10, E=10)
# the half-time line of the breakdown: (step, semitones, accent, steps, slide)
PULSE_LINE = [(0, 0, 1, 3, 0), (4, 0, 0, 2, 1), (6, 12, 0, 2, 0), (10, 7, 1, 2, 1),
              (12, 5, 0, 4, 0)]
ROOTS = dict(A=33, F=29, C=36, G=31, D=26, E=28)
GROOVE_CHORDS = "A A F F C C G G".split()


def acid_bar(p, b, root, line=ACID):
    for i, (step, semis, acc, slide) in enumerate(line):
        c = bar(b) + step * S16
        nxt = line[i + 1][0] if i + 1 < len(line) else 16
        length = (nxt - step) * S16 + 1 if slide else S16 // 2
        semis = THIRD[root] if semis == "3" else SEVENTH[root] if semis == "7" else semis
        p.note(c, ROOTS[root] + semis, length, 120 if acc else 90)


def pulse_bar(p, b, root):
    for step, semis, acc, steps, slide in PULSE_LINE:
        p.note(bar(b) + step * S16, ROOTS[root] + semis, steps * S16 + (1 if slide else -2),
               120 if acc else 85)


# ---- SID808: a bar of drums by style: [(16th, sound, velocity)]
def drum_bar(style, i):
    h = []
    if style == "count":
        h += [(s, "maracas", 70 if s % 4 else 95) for s in range(4, 16, 2)]   # (not clock 0)
    elif style == "intro":
        h += [(s, "hat", 55 if s % 4 else 80) for s in range(0, 16, 2)]
        if i >= 2:
            h += [(s, "kick", 115) for s in (0, 4, 8, 12)]
            h += [(s, "maracas", 50) for s in range(1, 16, 2)]
        if i == 3:
            h += [(12, "snare", 90), (13, "snare", 100), (14, "snare", 110), (15, "snare", 120)]
    elif style == "groove":
        h += [(s, "kick", 120 if s == 0 else 110) for s in (0, 4, 8, 12)]
        h += [(4, "clap", 105), (12, "clap", 105)]
        h += [(s, "hat", 85 if s % 4 == 2 else 55) for s in range(16) if s % 4 != 2]
        h += [(s, "ohat", 80) for s in (2, 6, 10, 14)]
        if i % 8 == 0:
            h.append((0, "cymbal", 115))
        if i % 4 == 3:
            h += [(14, "rim", 90), (15, "rim", 100)]
    elif style == "break":
        h += [(0, "kick", 127), (10, "kick", 100)]
        h += [(s, "claves", 90) for s in (3, 6, 11, 14)]
        h += [(7, "cowbell", 85), (15, "cowbell", 70)]
        h.append((12, "rim", 95))
        if i >= 4:
            h += [(s, "hat", 50 if s % 2 else 70) for s in range(16)]
            h += [(4, "clap", 95), (12, "clap", 95)]
        if i == 3:
            h += [(12, "tom_hi", 100), (13, "tom_mid", 100), (14, "tom_lo", 110)]
        if i == 7:
            h = [(0, "kick", 127), (4, "kick", 110), (8, "kick", 110)]
            h += [(s, "snare", 60 + 4 * s) for s in range(8, 16)]
    elif style == "drive":
        h += [(s, "kick", 120 if s == 0 else 110) for s in (0, 4, 8, 12)]
        h += [(4, "snare", 110), (12, "snare", 110)]
        h += [(s, "hat", 80 if s % 2 == 0 else 55) for s in range(16)]
        h += [(14, "ohat", 85)]
        if i % 8 == 0:
            h.append((0, "cymbal", 120))
        if i % 4 == 3:
            h += [(12, "tom_hi", 105), (13, "tom_hi", 95), (14, "tom_mid", 105),
                  (15, "tom_lo", 115)]
    elif style == "outro":
        h += [(s, "kick", 115) for s in (0, 4, 8, 12)]
        h += [(s, "hat", 60) for s in range(2, 16, 4)]
        if i < 2:
            h += [(4, "clap", 95), (12, "clap", 95)]
    elif style == "end":
        h += [(0, "kick", 127), (0, "cymbal", 120)]
    return h


def drums(p, b, style, i):
    for step, sound, vel in drum_bar(style, i):
        p.note(bar(b) + step * S16, GM[sound], 2, vel)


# ---- SID101's lines: (beat, note, beats, velocity, legato)
# (legato = 1: a slide into the next note; the rest are played apart)
GROOVE = [(0, 76, 5.5, 100, 1), (5.5, 74, 0.5, 80, 0), (6, 72, 2, 90, 0),
          (8, 69, 3, 100, 0), (11, 72, 1, 80, 0), (12, 77, 4, 110, 0),
          (16, 79, 6, 105, 0), (22, 76, 2, 85, 0),
          (24, 74, 3, 100, 0), (27, 71, 1, 80, 1), (28, 74, 2, 90, 0), (30, 76, 2, 100, 0)]
LEAD_B = [(0, 69, 1, 90, 1), (1, 81, 5, 120, 0), (6, 79, 1, 85, 0), (7, 76, 1, 85, 0),
          (8, 84, 4, 127, 0), (12, 81, 2, 90, 1), (14, 84, 2, 100, 0),
          (16, 88, 6, 120, 0), (22, 86, 1, 85, 1), (23, 84, 1, 85, 0),
          (24, 83, 3, 110, 0), (27, 86, 1, 90, 0), (28, 88, 3.5, 127, 0)]
SYNC_LINE = [(0, 69, 4, 110, 0), (4, 72, 2, 90, 0), (6, 76, 2, 100, 0),     # 8 bars
             (8, 77, 6, 120, 0), (14, 76, 2, 90, 0),
             (16, 76, 4, 110, 1), (20, 81, 4, 120, 0),
             (24, 79, 2, 100, 0), (26, 81, 2, 90, 1), (28, 83, 3.5, 127, 0)]
# the finale: the groove's first half an octave up, then the lead's second
# half, three slides
FINALE_LINE = ([(b, n + 12, l, v, g) for b, n, l, v, g in GROOVE[:6]] +
               [(b, n, l, v, 1 if b == 24 else g) for b, n, l, v, g in LEAD_B if b >= 16])
ARP_CHORDS = [(50, 53, 57), (45, 48, 52), (41, 45, 48), (40, 44, 47)]     # Dm Am F E
ARP_MODES = [("up", 1, 16), ("up", 1, 16), ("updown", 1, 16), ("updown", 1, 16),
             ("random", 1, 16), ("random", 1, 16), ("down", 2, 32), ("up", 2, 16)]


def swells(p, c0, line, name, base, top, beats_min=4, upto=None):
    """Parameter name (the cutoff, the sync pitch) over each long note of a
    line (before beat upto): from base up to top (a number, or a function
    of the note) and back by the note's end."""
    for beat, n, beats, vel, legato in line:
        if beats >= beats_min and (upto is None or beat < upto):
            a = c0 + round(beat * BEAT)
            z = a + round(beats * BEAT) - S16
            mid = (a + z) // 2
            t = top(n) if callable(top) else top
            p.sweep(name, a, mid, base, t, every=3)
            p.sweep(name, mid, z, t, base, every=3)


def check_lead(ev, chords=range(21, 29)):
    """SID101 plays one note at a time: outside the arpeggio bars, a note may
    start while another sounds only as a slide (the old one ends a clock
    after the new one starts). Fails on any other overlap."""
    held = {}                                   # note -> its note off's clock
    offs = {}
    for c, o, m in ev:
        if m[0] & 0xF0 == 0x80:
            offs.setdefault((m[1], c), 0)
    for c, o, m in sorted(ev, key=lambda e: (e[0], e[1])):
        if m[0] & 0xF0 == 0x80:
            held.pop(m[1], None)
        elif m[0] & 0xF0 == 0x90:
            if c // BAR not in chords:
                for n in held:
                    assert (n, c + 1) in offs, f"bar {c // BAR} beat {c % BAR / BEAT}: {m[1]} over {n}"
            held[m[1]] = c


def main():
    out = sys.argv[1]
    lead, bass, drum = Part(0, SID101), Part(1, SID303), Part(9, SID808)
    cues = []

    def cue(b, text):
        cues.append((b, text))

    # bar 0: the sounds (SID808's kick as made), a count in
    cue(0, "sounds set by controllers; SID808 maracas count in")
    c = lead.set(6, LEAD)
    bass.set(6, BASS)
    drum.set(6, dict(VOLUME=15, LEVEL=15, TUNE=TUNE_CENTER, DECAY=8, TONE=8))
    drum.sound.clear()                         # (sent again at the breakdown's end)
    drums(drum, 0, "count", 0)
    lead.bend(c + 1, 0)

    # bars 1-4: intro
    cue(1, "intro: SID303 acid line, its cutoff opening (CC 74); SID808 hats, kick, snare fill")
    for i in range(4):
        acid_bar(bass, 1 + i, "A")
        drums(drum, 1 + i, "intro", i)
    bass.sweep("CUTOFF", bar(1), bar(5) - S16, 20, 110, every=3)

    # bars 5-12: groove, the lead comes in
    cue(5, "groove: SID101 soft filtered lead, the cutoff (CC 74) swelling on the long notes, "
           "delayed vibrato, two slides; SID808 kick, clap, hats, open hats")
    for i in range(8):
        acid_bar(bass, 5 + i, GROOVE_CHORDS[i])
        drums(drum, 5 + i, "groove", i)
    lead.phrase(bar(5), GROOVE)
    swells(lead, bar(5), GROOVE, "CUTOFF", LEAD["CUTOFF"], LEAD["CUTOFF"] + 30)

    # bars 13-20: the lead
    cue(13, "lead: octave glide, two slides, mod wheel vibrato, pitch bend scoop, "
            "cutoff swell, a fall; SID303 env mod rising")
    for i in range(8):
        acid_bar(bass, 13 + i, GROOVE_CHORDS[i])
        drums(drum, 13 + i, "groove", i)
    c0 = bar(13)
    lead.phrase(c0, LEAD_B)
    lead.sweep("MODWHEEL", c0 + 2 * BEAT, c0 + 6 * BEAT - 4, 0, 200, every=3)   # the octave's swell
    lead.cc(c0 + 6 * BEAT, "MODWHEEL", 0)
    lead.bend(c0 + 8 * BEAT - 1, -2)                                     # the scoop up to C6
    lead.bend_sweep(c0 + 8 * BEAT, c0 + 8 * BEAT + 9, -2, 0, every=1)
    cut = LEAD["CUTOFF"]
    lead.sweep("CUTOFF", c0 + 16 * BEAT, c0 + 19 * BEAT, cut, cut + 45, every=3)  # E6's swell
    lead.sweep("CUTOFF", c0 + 19 * BEAT, c0 + 22 * BEAT - S16, cut + 45, cut, every=3)
    lead.sweep("MODWHEEL", c0 + 24 * BEAT, c0 + 27 * BEAT - 2, 0, 140, every=3)
    lead.cc(c0 + 27 * BEAT, "MODWHEEL", 0)
    lead.bend_sweep(c0 + 30 * BEAT, c0 + 31 * BEAT + 12, 0, -2, every=2)  # the fall
    lead.bend(c0 + 32 * BEAT - 4, 0)
    bass.sweep("ENVMOD", c0, bar(21) - S16, 150, 230, every=6)
    bass.sweep("RESO", c0 + 4 * BAR, bar(21) - S16, 12, 14, every=24)

    # bars 21-28: breakdown
    cue(21, "breakdown: SID101 arpeggiator (Up, Up & down, Random, Down 1/32 over "
            "3 octaves), cutoff opening; SID808 long low kick (CC 17-19), claves, "
            "cowbell, rim; SID303 back at bar 25")
    c = bar(20) + 3 * BEAT + 12                # after the fall: the arp sound
    c = lead.set(c, ARP_SOUND)
    drum.set(bar(21) - 6, dict(TUNE=TUNE_CENTER - 4, DECAY=15, TONE=4))
    for i in range(8):
        b = 21 + i
        mode, rng, rate = ARP_MODES[i]
        lead.set(bar(b) - 2, dict(ARP=ARP[mode], ARPRANGE=rng, ARPRATE=ARP_RATE[rate]))
        length = BAR - 3 if i < 7 else 2 * BEAT
        for n in ARP_CHORDS[i % 4]:
            lead.note(bar(b), n, length, 110 if i % 2 == 0 else 90)
        drums(drum, b, "break", i)
        if i >= 4:
            pulse_bar(bass, b, "DAFE"[i - 4])
    lead.sweep("CUTOFF", bar(21), bar(28) + 2 * BEAT - 2, 60, 170, every=6)
    bass.set(bar(25) - 8, dict(CUTOFF=60, ENVMOD=180, DECAY=10, RESO=13))
    drum.set(bar(28) + 3 * BEAT, dict(TUNE=TUNE_CENTER, DECAY=8, TONE=8))

    # bars 29-36: sync
    cue(29, "sync: SID101's Sync voice, filtered, the sync pitch knob (CC 78) swept on "
            "every long note, two slides; SID808 snare, toms; SID303 back to the acid line")
    lead.set(bar(28) + 2 * BEAT + 4, SYNC)
    bass.set(bar(29) - 6, dict(CUTOFF=130, ENVMOD=160, DECAY=6, RESO=10))
    for i in range(8):
        acid_bar(bass, 29 + i, GROOVE_CHORDS[i])
        drums(drum, 29 + i, "drive", i)
    lead.phrase(bar(29), SYNC_LINE)
    swells(lead, bar(29), SYNC_LINE, "SYNCPITCH", 20, lambda n: 90 + 20 * (n - 69) // 6)

    # bars 37-44: finale
    cue(37, "finale: the soft lead an octave up and a little brighter, three slides, a "
            "trill (LFO shape Square), the wheel; SID303 cutoff and resonance up")
    c = bar(36) + 3 * BEAT + 12                # the sync line's last note has ended
    lead.set(c, FINALE)
    for i in range(8):
        acid_bar(bass, 37 + i, GROOVE_CHORDS[i])
        drums(drum, 37 + i, "drive" if i < 7 else "groove", i)
    c0 = bar(37)
    lead.phrase(c0, FINALE_LINE)
    swells(lead, c0, FINALE_LINE, "CUTOFF", FINALE["CUTOFF"], FINALE["CUTOFF"] + 30, upto=16)
    lead.set(c0 + 12 * BEAT - 3, dict(LFOSHAPE=1, VIBRATO=7, LFODELAY=0, LFORATE=9))   # the trill
    lead.set(c0 + 16 * BEAT - 3, dict(LFOSHAPE=0, VIBRATO=4, LFODELAY=8, LFORATE=6))
    lead.sweep("MODWHEEL", c0 + 16 * BEAT, c0 + 21 * BEAT, 0, 255, every=3)
    lead.cc(c0 + 22 * BEAT, "MODWHEEL", 0)
    lead.bend_sweep(c0 + 30 * BEAT, c0 + 31 * BEAT + 12, 0, -2, every=2)
    lead.bend(c0 + 32 * BEAT - 4, 0)
    bass.sweep("CUTOFF", c0 + 4 * BAR, bar(45) - S16, 130, 210, every=6)
    bass.set(c0 + 4 * BAR, dict(RESO=13))

    # bars 45-48: outro
    cue(45, "outro: one long note, the mod wheel's vibrato swelling, SID101's cutoff "
            "closing; the release rings out")
    c0 = bar(45)
    lead.set(c0 - 6, dict(VIBRATO=2, LFODELAY=0))
    lead.phrase(c0, [(0, 76, 2, 100, 1), (2, 81, 13, 120, 0)], gap=0)
    lead.sweep("MODWHEEL", c0 + 4 * BEAT, c0 + 10 * BEAT, 0, 255, every=3)
    lead.sweep("MODWHEEL", c0 + 10 * BEAT, c0 + 14 * BEAT, 255, 60, every=3)
    lead.sweep("CUTOFF", c0 + 8 * BEAT, c0 + 15 * BEAT, FINALE["CUTOFF"], 25, every=3)
    for i in range(3):
        acid_bar(bass, 45 + i, "A")
        drums(drum, 45 + i, "outro", i)
    bass.sweep("CUTOFF", c0, bar(48), 210, 40, every=6)
    bass.note(bar(48), ROOTS["A"], BEAT, 120)
    drums(drum, 48, "end", 0)
    lead.cc(bar(48) + 3 * BEAT, "MODWHEEL", 0)
    cue(49, "end")

    check_lead(lead.ev)

    # ---- the file
    mid = mido.MidiFile(ticks_per_beat=PPQ)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name=TITLE, time=0))
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(BPM), time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    meta.append(mido.MetaMessage("end_of_track", time=BARS * BAR * TICKS_PER_CLOCK))
    mid.tracks.append(meta)
    counts = {}
    for part, name in ((lead, "SID101 lead"), (bass, "SID303 bass"), (drum, "SID808 drums")):
        evs = sorted(part.ev, key=lambda e: (e[0], e[1]))
        # one message per controller a clock (the last), and none after the song
        seen, kept = {}, []
        for c, o, m in evs:
            assert 0 <= c < BARS * BAR, (name, c, m)
            if m[0] & 0xF0 in (0xB0, 0xE0):
                key = (c, m[0], m[1] if m[0] & 0xF0 == 0xB0 else None)
                if key in seen:
                    kept[seen[key]] = None
                seen[key] = len(kept)
            kept.append((c, o, m))
        evs = [e for e in kept if e]
        tr = mido.MidiTrack()
        tr.append(mido.MetaMessage("track_name", name=name, time=0))
        last = 0
        for c, _, m in evs:
            t = c * TICKS_PER_CLOCK
            tr.append(mido.Message.from_bytes(m, time=t - last))
            last = t
        tr.append(mido.MetaMessage("end_of_track", time=0))
        mid.tracks.append(tr)
        counts[name] = (sum(1 for _, _, m in evs if m[0] & 0xF0 == 0x90),
                        sum(1 for _, _, m in evs if m[0] & 0xF0 in (0xB0, 0xE0)), len(evs))
    mid.save(out)

    sec = lambda b: b * 4 * 60 / BPM
    cue_path = os.path.splitext(out)[0] + "-cues.txt"
    with open(cue_path, "w", newline="") as f:
        f.write(f"{TITLE}: {BARS} bars at {BPM} BPM, {sec(BARS):.0f} s\n")
        for b, text in cues:
            f.write(f"{int(sec(b)) // 60}:{sec(b) % 60:04.1f}  bar {b:2d}  {text}\n")
    total = sum(n for _, _, n in counts.values())
    print(f"{out}: {BARS} bars at {BPM} BPM ({sec(BARS):.0f} s); " +
          "; ".join(f"{k} {n} notes, {c} controllers/bends" for k, (n, c, _) in counts.items()) +
          f"; {total} messages; cues in {cue_path}")


if __name__ == "__main__":
    main()
