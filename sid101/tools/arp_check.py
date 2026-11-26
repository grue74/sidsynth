#!/usr/bin/env python3
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check SID101's arpeggiator (src/arp.asm) in VICE against a model.

Builds TEST_LOG programs, runs them in VICE (../c64tools/vicepeek.py) and
compares the note log (every note the voice was given: voice_note_on and
voice_note_off, src/notes.asm) with this script's model of the
arpeggiator, fed the same MIDI (tables.py):

  internal  TEST_MIDI=8: every mode, range and rate at 125 BPM, keys added
            and let go while it plays, a ninth key, turned off and on with
            keys held, the mode and range changed while it plays
  clock     TEST_MIDI=9, TEST_CLOCK=1: on MIDI clock with the sequencer
            stopped, the rate changed, MIDI start (the sequencer plays
            pattern 1 too: its notes go to the voice and are left out of
            the comparison), stop, continue
  demo E    TEST_MIDI=13 (demos/e-arpeggiator.wav): as written
  bypass    TEST_SEQ=1, TEST_ARP=1: the sequencer's pattern 1 with the
            arpeggiator on and no keys: exactly seq_check.py's model
  load      TEST_MIDI=10, TEST_SEQ=1 (pattern 3), TEST_KEYS=4 (the step
            screen): the heaviest sound, eight keys, Random, 3 octaves, 1/32
  stream    TEST_MIDI=11 and 12: the load test with a controller every tick
            (a knob turned fast), with and without the arpeggiator

and that no run left the engine more than 1 tick behind (LOG_LAG; the
stream runs 2).
Usage: python tools/arp_check.py [--keep DIR]
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
import tables                                       # noqa: E402
import seq_check as sc                              # noqa: E402  (build, run_log, the sequencer's model)
from tables_core import tempo_steps                 # noqa: E402

ARP_MAX = 8                                         # src/arp.asm
ARP_RNG_SEED = 0x5D
CLOCKS_PER = (12, 6, 3)                             # arp_clocks_per: 1/8, 1/16, 1/32
GATE_HALF = (6, 3, 2)                               # arp_gate_half
UP, DOWN, UPDOWN, RANDOM = 1, 2, 3, 4
VOICE_STACK = 8                                     # STACK_SIZE
BASS_NOTES = {n for n, _a, _s in tables.BASS_LINE if isinstance(n, int)}
CC_PARAM = {tables.CC[k]: k for k in ("ARP", "ARPRANGE", "ARPRATE")}


def cc_to_value(name, cc):
    """The core's param_set_v: CC x 2 scaled by (max + 1) / 256."""
    return (cc * 2 * (tables.MAX[name] + 1)) >> 8


class Model:
    """src/arp.asm and the parts of src/notes.asm it touches, tick by
    tick. Events of feed tick t are handled (main loop) after tick t's
    arp_tick; what they log carries t, arp_tick's logs the tick's."""

    def __init__(self, midi_clock=False, bpm=125):
        self.midi_clock = midi_clock
        self.seq_inc = tempo_steps(bpm)[0]
        self.mode, self.range, self.rate = 0, 0, 1
        self.held = []                              # arp_held, sorted
        self.on = 0
        self.first = 0
        self.inc = 0
        self.pos = 0
        self.note = None
        self.vel = self.last = 0
        self.phase = 0
        self.clocks = self.due = self.gate_due = 0
        self.rng = ARP_RNG_SEED
        self.voice = []                             # note_stack
        self.last_vel = 0
        self.log = []
        self.t = 0

    # the voice (log_note in voice_note_on / voice_note_off)
    def voice_on(self, n, v):
        self.log.append((self.t, n, v))
        self.last_vel = v
        if n in self.voice:
            self.voice.remove(n)
        if len(self.voice) >= VOICE_STACK:
            self.voice[-1] = n
        else:
            self.voice.append(n)

    def voice_off(self, n):
        self.log.append((self.t, n, 0))
        if n in self.voice:
            self.voice.remove(n)

    # keys
    def key_on(self, n, v):
        self.vel, self.last = v, n
        if n in self.held:
            self.held.remove(n)
        if len(self.held) < ARP_MAX:
            self.held.append(n)
            self.held.sort()
        if len(self.held) == 1:
            self.first = 1
            self.due = self.gate_due = 0
            self.set_inc()
            self.phase = (0x10000 - self.inc) & 0xFFFF

    def key_off(self, n):
        if n not in self.held:
            self.voice_off(n)
            return
        self.held.remove(n)
        if not self.held:
            self.note_off()

    def note_off(self):
        if self.note is not None:
            n, self.note = self.note, None
            self.voice_off(n)

    def param_arp(self):
        x = 1 if self.mode else 0
        if x == self.on:
            return
        self.on = x
        if x:                                       # on: take the voice's notes
            for n in list(self.voice):
                self.key_on(n, self.last_vel)
            self.voice = []
            return
        self.note_off()                             # off: the newest key to the voice
        if self.held:
            n = self.last if self.last in self.held else self.held[-1]
            self.held = []
            self.voice_on(n, self.vel)

    # MIDI in (the main loop)
    def midi(self, msg):
        s = msg[0]
        if s >= 0xF8:
            self.realtime(s)
        elif s & 0xF0 == 0x90:
            n, v = msg[1], msg[2]
            if v:
                (self.key_on if self.mode else self.voice_on)(n, v)
            else:
                (self.key_off if self.mode else self.voice_off)(n)
        elif s == 0xF2:
            self.song_position(msg[1] | msg[2] << 7)
        elif s & 0xF0 == 0xB0 and msg[1] in CC_PARAM:
            name = CC_PARAM[msg[1]]
            v = cc_to_value(name, msg[2])
            if name == "ARP":
                self.mode = v
                self.param_arp()
            elif name == "ARPRANGE":
                self.range = v
            else:
                self.rate = v

    def song_position(self, pos):
        """synth_song_position (src/arp.asm), the sequencer stopped on MIDI
        clock: at 1/8 an odd position is half a step in, else the first
        clock is a step; the pattern from its first note."""
        if not self.midi_clock:
            return
        self.clocks = CLOCKS_PER[1] - 1 if pos & 1 and self.rate == 0 else 0xFF
        self.first = 1

    def realtime(self, b):
        if not self.midi_clock:
            return
        if b == 0xFA:
            self.clocks, self.first = 0xFF, 1
        elif b == 0xF8:
            self.clocks = (self.clocks + 1) & 0xFF
            if self.clocks == 0:
                self.due = 1
                return
            if self.clocks == GATE_HALF[self.rate]:
                self.gate_due = 1
            if self.clocks >= CLOCKS_PER[self.rate]:
                self.clocks, self.due = 0, 1

    # arp_tick, arp_step
    def set_inc(self):
        inc = self.seq_inc
        if self.rate == 0:
            inc >>= 1
        elif self.rate == 2:
            inc = (inc << 1) & 0xFFFF
        self.inc = inc

    def tick(self):
        if not self.held:
            return
        if self.midi_clock:
            if self.gate_due:
                self.gate_due = 0
                self.note_off()
            if self.due:
                self.due = 0
                self.step()
            return
        self.phase += self.inc
        if self.phase >= 0x10000:
            self.phase -= 0x10000
            self.step()
        elif self.phase & 0x8000:
            self.note_off()

    def random(self):
        self.rng = (5 * self.rng + 1) & 0xFF
        return self.rng

    def step(self):
        self.note_off()
        if not self.held:
            return
        self.set_inc()
        count = len(self.held)
        span = count * (self.range + 1)
        period = span
        if self.mode == UPDOWN:
            period = (2 * span - 2) or 1
        if self.first:
            self.pos = 0
        else:
            self.pos += 1
            if self.pos >= period:
                self.pos = 0
        self.first = 0
        if self.mode == DOWN:
            i = span - 1 - self.pos
        elif self.mode == UPDOWN:
            i = self.pos if self.pos < span else period - self.pos
        elif self.mode == RANDOM:
            i = self.random() * span >> 8
        else:
            i = self.pos
        self.note = self.held[i % count] + 12 * (i // count)
        self.voice_on(self.note, self.vel)

    def run(self, events, end):
        by_tick = {}
        for t, msg in events:
            by_tick.setdefault(t, []).append(msg)
        for t in range(end):
            self.t = t
            self.tick()
            for msg in by_tick.get(t, []):
                self.midi(msg)
        return self.log


def compare(label, got, want):
    """Pass if got equals want, both from their first entry's tick on."""
    got = sc.relative(got)[:len(want)]
    want = sc.relative(want)
    if got == want:
        print(f"PASS {label}: {len(want)} events equal the model")
        return True
    print(f"FAIL {label}")
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            print(f"  first difference at event {i}: got {g}, want {w}")
            print("  got:", got[max(0, i - 3):i + 4])
            print("  want:", want[max(0, i - 3):i + 4])
            break
    else:
        print(f"  got {len(got)} events, want {len(want)}")
    return False


def counts(log):
    """(note-ons, the modes' share): a short summary of a log."""
    return sum(1 for _t, _n, v in log if v)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder (default: a temporary one)")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="arpcheck")
    os.makedirs(work, exist_ok=True)
    inc = os.path.join(ROOT, "tables.inc")
    if not os.path.exists(inc) or os.path.getmtime(inc) < os.path.getmtime(os.path.join(ROOT, "tables.py")):
        subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    ok = True

    # 1. internal clock: every mode, range and rate
    events, end = tables.arp_events()
    prg = os.path.join(work, "arp.prg")
    sc.build(prg, ["TEST_MIDI=8"])
    want = Model().run(events, end)
    ok &= compare(f"internal clock (TEST_MIDI=8, {counts(want)} notes)", sc.run_log(prg, end // 250 + 2), want)

    # 2. MIDI clock, the sequencer's notes left out
    events, end = tables.arp_clock_events()
    prg = os.path.join(work, "arpclock.prg")
    sc.build(prg, ["TEST_MIDI=9", "TEST_CLOCK=1"])
    want = Model(midi_clock=True).run(events, end)
    got = sc.run_log(prg, end // 250 + 2)
    seq = [e for e in got if e[1] in BASS_NOTES]
    arp = [e for e in got if e[1] not in BASS_NOTES]
    good = compare(f"MIDI clock (TEST_MIDI=9, {counts(want)} notes)", arp, want)
    start = next(t for t, m in events if m == [0xFA]) - events[0][0]
    seq_ons = counts(seq)
    seq_ok = seq_ons > 5 and all(t >= got[0][0] + start - 40 for t, _n, _v in seq)
    print(f"{'PASS' if seq_ok else 'FAIL'} MIDI clock: the sequencer's notes ({seq_ons} from MIDI start) "
          f"went to the voice past the arpeggiator")
    ok &= good and seq_ok

    # 2a. demo E (demos/e-arpeggiator.wav) plays as written
    events, end = tables.demo_e()
    events = [(t, m) for t, _, m in sorted(events, key=lambda e: (e[0], e[1]))]
    prg = os.path.join(work, "demoe.prg")
    sc.build(prg, ["TEST_MIDI=13"])
    want = Model().run(events, end)
    ok &= compare(f"demo E (TEST_MIDI=13, {counts(want)} notes)", sc.run_log(prg, end // 250 + 2), want)

    # 3. the sequencer with the arpeggiator on: its notes as without it
    prg = os.path.join(work, "bypass.prg")
    sc.build(prg, ["TEST_SEQ=1", "TEST_ARP=1"])
    ok &= sc.compare("bypass (pattern 1, Arpeggio Up, no keys)", sc.run_log(prg, 6),
                     sc.model(tables.BASS_LINE, 125, 4 * 16 * 31))

    # 4. load
    prg = os.path.join(work, "arpheavy.prg")
    sc.build(prg, ["TEST_MIDI=10", "TEST_SEQ=1", "TEST_SEQ_PAT=2", "TEST_KEYS=4"])
    heavy = sc.run_log(prg, 12)
    n = counts(heavy)
    good = n > 200                      # (the note log holds 256 notes: 512 events)
    print(f"{'PASS' if good else 'FAIL'} load: {n} notes (sequencer and arpeggiator at 1/32) with the "
          f"heaviest sound and the step screen open")
    ok &= good

    worst = max(sc.lags.values())
    good = worst <= 1
    print(f"{'PASS' if good else 'FAIL'} lag: at most {worst} tick(s) waiting "
          f"({', '.join(f'{k} {v}' for k, v in sc.lags.items())})")
    ok &= good

    # 5. the same heaviest case with a controller every tick for 4 s, with
    # and without the arpeggiator: the engine 1 tick (4 ms) late while the
    # stream lasts is allowed, as in seq_check.py's editing runs
    stream = {}
    for name, midi in (("arpstream", 11), ("stream", 12), ("c64stream", 18)):
        prg = os.path.join(work, name + ".prg")
        sc.build(prg, [f"TEST_MIDI={midi}", "TEST_SEQ=1", "TEST_SEQ_PAT=2", "TEST_KEYS=4"])
        sc.run_log(prg, 12)
        stream[name] = sc.lags[name + ".prg"]
    good = stream["arpstream"] <= 2 and stream["c64stream"] <= 2
    print(f"{'PASS' if good else 'FAIL'} controller stream (a controller every tick, "
          f"{tables.STREAM_TICKS} ticks, the heaviest case): lag {stream['arpstream']} with the "
          f"arpeggiator, {stream['stream']} without; C64 mode's heaviest sound with the "
          f"arpeggiator: lag {stream['c64stream']}")
    ok &= good
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
