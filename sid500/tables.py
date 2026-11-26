#!/usr/bin/env python3
# tables.py - writes tables.inc for SID500
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates tables.inc (64tass): the core's tables (tick latch, multiply
tables), SID500's tempo tables (for each Tempo parameter value, BPM
BPM_LOWEST + value: the player's timer latch and the period's fraction),
and for TEST_EVENTS builds the test patterns' event streams.

Also the model of the event format (docs/design.md section 3): encode()
writes a pattern's events as the program reads them (src/events.asm), and
tools/event_check.py checks the program against it.

All timing values assume the PAL clock.
"""

import os
import random
import sys

# shared helpers and the tables the core needs (core/tables_core.py)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
from tables_core import PAL_CLOCK, sq_tables, table, tick_latch  # noqa: E402

TICKS_PER_QUARTER = 48          # sid500.asm
BPM_LOWEST = 40                 # sid500.asm: Tempo parameter 0
BPM_HIGHEST = 240               # sid500.asm: the Tempo parameter's top (the family's, the user)
TEMPOS = BPM_HIGHEST - BPM_LOWEST + 1   # the Tempo parameter's values


def tick_cycles(bpm):
    """A sequencer tick at bpm, in CPU cycles (1,231,560 / BPM on PAL)."""
    return PAL_CLOCK * 60 / (TICKS_PER_QUARTER * bpm)


def tempo_period(bpm):
    """(latch, fraction) for a tempo: the timer runs latch+1 cycles, and
    the fraction (x/256 of a cycle) is carried over by the dither, so the
    ticks average exactly tick_cycles(bpm) (to 1/512 of a cycle)."""
    p256 = round(tick_cycles(bpm) * 256)
    whole, frac = divmod(p256, 256)
    assert whole - 1 < 65536, bpm
    return whole - 1, frac


LEAD_MS = 42                    # the render lead (the user): about 42 ms at any tempo
LEAD_MAX = 14                   # src/render.asm: TICK_END holds 16 ticks


def tempo_lead(bpm):
    """The render lead at a tempo, in ticks: about LEAD_MS, at least 1."""
    ticks = round(LEAD_MS / 1000 * bpm * TICKS_PER_QUARTER / 60)
    return max(1, min(LEAD_MAX, ticks))


def slave_lead():
    """As slave, the render lead by the master's tick period (half its
    clock gap, measured): about LEAD_MS of ticks; index = the period's high
    byte (a tick of hi * 256 + 128 cycles)."""
    cycles = LEAD_MS / 1000 * PAL_CLOCK
    return [max(1, min(LEAD_MAX, round(cycles / (hi * 256 + 128)))) for hi in range(256)]


SWINGS = 16                     # the Swing parameter's values (the family's, 0-15)


def swing_ticks(swing):
    """The odd 16th's delay in ticks: swing/32 of a 16th (12 ticks), rounded."""
    return round(swing * 12 / 32)


def swing_counts(swing):
    """For each tick of a pair of 16ths (24 ticks from the scene's start),
    how many ticks of the music it plays (0, 1 or 2): the music's tick m
    plays at tick round(W(m)), W stretching the first 16th to 12 + s ticks
    and squeezing the second into 12 - s (s = swing_ticks), so the odd 16th
    starts s ticks late and what lies between moves in proportion."""
    s = swing_ticks(swing)
    counts = [0] * 24
    for m in range(24):
        w = m * (12 + s) / 12 if m < 12 else 12 + s + (m - 12) * (12 - s) / 12
        counts[int(w + 0.499)] += 1         # (halves down: 23.5 is tick 23)
    assert sum(counts) == 24 and counts[0] == 1 and max(counts) <= 2, (swing, counts)
    return counts


def swing_row_int(swing):
    """swing_counts in integers, as src/size.asm player_set_swing makes it:
    the music's tick m at tick (m (12 + s) + 5) div 12 in the first 16th,
    12 + s + ((m - 12)(12 - s) + 5) div 12 in the second."""
    s = swing_ticks(swing)
    counts = [0] * 24
    for m in range(24):
        counts[(m * (12 + s) + 5) // 12 if m < 12 else 12 + s + ((m - 12) * (12 - s) + 5) // 12] += 1
    assert counts == swing_counts(swing), swing
    return counts


def check_swing_rows():
    for sw in range(SWINGS):
        swing_row_int(sw)


TEMPO_DIVIDEND = PAL_CLOCK * 60 * 256 // TICKS_PER_QUARTER    # a tick's 1/256 cycles x BPM


def tempo_period_int(bpm):
    """tempo_period in integers, as src/size.asm tempo_period_io computes
    it: (TEMPO_DIVIDEND + bpm div 2) div bpm, 1/256 cycles a tick."""
    p256 = (TEMPO_DIVIDEND + bpm // 2) // bpm
    return (p256 >> 8) - 1, p256 & 255


def tempo_lead_steps():
    """The Tempo values (BPM - BPM_LOWEST) at which tempo_lead grows by one
    (from 1 at the lowest): src/size.asm counts those passed."""
    leads = [tempo_lead(BPM_LOWEST + v) for v in range(TEMPOS)]
    assert leads[0] == 1
    steps = [v for v in range(1, TEMPOS) if leads[v] != leads[v - 1]]
    assert all(leads[v] == leads[v - 1] + 1 for v in steps)
    return steps


def check_tempo():
    """The computed tempo equals the tables it replaced, at every Tempo."""
    assert PAL_CLOCK * 60 * 256 % TICKS_PER_QUARTER == 0
    assert TEMPO_DIVIDEND + BPM_HIGHEST < 1 << 29       # (32 shifts: no bit lost)
    steps = tempo_lead_steps()
    for v in range(TEMPOS):
        bpm = BPM_LOWEST + v
        assert tempo_period_int(bpm) == tempo_period(bpm), bpm
        assert 1 + sum(v >= s for s in steps) == tempo_lead(bpm), bpm


def tempo_tables():
    """The tempo's constants (the size pass, 2026-11-24: the period and the
    lead computed by src/size.asm tempo_period_io, no longer four tables
    of 201 under I/O); slave_lead and swing_counts stay in the program (the
    interrupt reads them, and it never switches banks)."""
    check_swing_rows()
    check_tempo()
    steps = tempo_lead_steps()
    return (f"TEMPO_DIVIDEND = {TEMPO_DIVIDEND}\n"
            + f"TEMPO_LEAD_STEPS = {len(steps)}\n"
            + "        .section hi_code        ; (under the KERNAL: src/size.asm)\n"
            + table("tempo_lead_steps", steps,
                    "the Tempo values from which the render lead is a tick longer (from 1)")
            + "        .send\n"
            + f"SLAVE_LEAD_TAB = {slave_lead_tab_len()}\n"
            + "\n" + table("slave_lead_tab", slave_lead()[:slave_lead_tab_len()],
                           "as slave: the render lead by the master's tick period's high byte "
                           "(from SLAVE_LEAD_TAB on 1: src/size.asm slave_lead_x)")
            + "\n" + table("swing_ticks_tab", [swing_ticks(sw) for sw in range(SWINGS)],
                           "each Swing value's delay in ticks (src/size.asm player_set_swing "
                           "makes the row of swing_counts from it)"))


def slave_lead_tab_len():
    """slave_lead's length up to its last value over 1 (the rest is 1)."""
    sl = slave_lead()
    n = max(hi for hi in range(256) if sl[hi] > 1) + 1
    assert all(v == 1 for v in sl[n:])
    return n


def slave_lead_max():
    """slave_lead as thresholds: for the leads 14, 13, ... 2, the highest
    period high byte with that lead or more (slave_lead falls as it rises)."""
    sl = slave_lead()
    assert all(sl[i] >= sl[i + 1] for i in range(255)) and sl[0] == 14 and sl[255] == 1
    out = [max(hi for hi in range(256) if sl[hi] >= lead) for lead in range(14, 1, -1)]
    # (src/size.asm: lead = 14 - the first index whose threshold is >= hi)
    for hi in range(256):
        y = next((i for i, t in enumerate(out) if t >= hi), len(out))
        assert 14 - y == sl[hi], hi
    return out


# -----------------------------------------------------------------------------
# The event format (docs/design.md section 3; src/events.asm reads it)
# -----------------------------------------------------------------------------
TIME_LONG, TIME_END = 0xF0, 0xFF
EV_LEN_TABLE, EV_LEN_BYTE, EV_LEN_WORD = 0x80, 0x8E, 0x8F
EV_VELOCITY, EV_CC, EV_CC_SAME, EV_BEND, EV_PROGRAM = 0x90, 0x91, 0x92, 0x93, 0x94
LENGTHS = [3, 6, 8, 9, 12, 16, 18, 24, 32, 36, 48, 72, 96, 192]    # events.asm len_table
START_VELOCITY, START_LENGTH, START_CC = 100, 12, 1
MAX_GAP = 0x0EFF                # the longest time byte pair: $FE then $FF


def encode(events):
    """A pattern's stream: events are (tick, kind, ...) in time order, kind
    'note' (note, velocity, length), 'cc' (number, value), 'bend' (low 7
    bits, high 7 bits) or 'program' (program); ticks from the pattern's
    start. Prefixes only where a value changes; then the end."""
    out, last = [], 0
    vel, length, cc = START_VELOCITY, START_LENGTH, START_CC
    for ev in events:
        tick, kind, data = ev[0], ev[1], ev[2:]
        gap = tick - last
        assert 0 <= gap <= MAX_GAP, ev
        last = tick
        out += [gap] if gap < TIME_LONG else [TIME_LONG + (gap >> 8), gap & 0xFF]
        if kind == "note":
            note, v, n = data
            assert 0 <= note < 128 and 1 <= v < 128 and 1 <= n < 65536, ev
            if n != length:
                if n in LENGTHS:
                    out.append(EV_LEN_TABLE + LENGTHS.index(n))
                elif n < 256:
                    out += [EV_LEN_BYTE, n]
                else:
                    out += [EV_LEN_WORD, n & 0xFF, n >> 8]
                length = n
            if v != vel:
                out += [EV_VELOCITY, v]
                vel = v
            out.append(note)
        elif kind == "cc":
            number, value = data
            out += [EV_CC_SAME, value] if number == cc else [EV_CC, number, value]
            cc = number
        elif kind == "bend":
            out += [EV_BEND, data[0], data[1]]
        elif kind == "program":
            out += [EV_PROGRAM, data[0]]
        else:
            raise ValueError(ev)
    return out + [TIME_END]


def blocks_for(stream, block_data=30):
    """The pool blocks a stream takes (30 bytes each, its end included)."""
    return -(-len(stream) // block_data)


# -----------------------------------------------------------------------------
# Test patterns (TEST_EVENTS): (pattern, steps, events); a pattern given
# twice is written twice, the second replacing the first (its blocks freed)
# -----------------------------------------------------------------------------
def fuzz_events(seed, count):
    """count events of every kind at random times, chords included."""
    rnd = random.Random(seed)
    events, tick = [], 0
    for _ in range(count):
        tick += rnd.choice([0, 0, 1, 5, 12, 12, 24, 200, 239, 240, 241, 700])
        kind = rnd.choice(["note"] * 6 + ["cc", "cc", "bend", "program"])
        if kind == "note":
            length = rnd.choice(LENGTHS + [1, 7, 255, 256, 1000, 65535])
            events.append((tick, "note", rnd.randrange(128), rnd.randrange(1, 128), length))
        elif kind == "cc":
            events.append((tick, "cc", rnd.choice([1, 1, 7, 74, 74, 127]), rnd.randrange(128)))
        elif kind == "bend":
            events.append((tick, "bend", rnd.randrange(128), rnd.randrange(128)))
        else:
            events.append((tick, "program", rnd.randrange(128)))
    return events


def test_patterns():
    steps16 = [(i * 12, "note", 36 + (i % 4) * 7, 100, 12) for i in range(16)]
    chords = [(0, "note", 60, 100, 12), (0, "note", 64, 100, 12), (0, "note", 67, 90, 48),
              (24, "note", 62, 90, 3), (36, "note", 65, 127, 192), (48, "note", 69, 1, 200),
              (60, "note", 71, 1, 300), (72, "note", 72, 64, 65535), (84, "note", 0, 64, 1),
              (96, "note", 127, 64, 255), (108, "note", 60, 64, 256)]
    others = [(0, "cc", 1, 0), (0, "cc", 1, 127), (10, "cc", 74, 64), (10, "cc", 74, 65),
              (20, "cc", 1, 3), (239, "bend", 0, 64), (479, "bend", 127, 127),
              (720, "program", 5), (720 + 3839, "program", 127), (720 + 3839, "note", 50, 100, 12)]
    return [
        (0, 16, steps16),
        (1, 16, chords),
        (2, 128, others),
        (3, 128, fuzz_events(500, 300)),
        (5, 1, []),                             # empty: only its end
        (10, 16, fuzz_events(7, 40)),           # written, then replaced:
        (10, 32, sorted(steps16 + chords[3:], key=lambda e: e[0])),  # its first blocks freed
        (127, 128, fuzz_events(9, 120)),
    ]


def test_streams():
    """The test patterns for the program to write into the pool: pattern,
    steps, stream length (2 bytes), the stream; $FF after the last."""
    out = []
    for pattern, steps, events in test_patterns():
        stream = encode(events)
        out += [pattern, steps, len(stream) & 0xFF, len(stream) >> 8] + stream
    out.append(0xFF)
    return (".if TEST_EVENTS\n" + table("test_streams", out, "the test patterns (TEST_EVENTS):"
                                         " pattern, steps, length (2), stream; $FF ends")
            + ".endif\n")


# -----------------------------------------------------------------------------
# Test scenes (TEST_PLAY=n): tracks playing patterns, for tools/play_check.py
# -----------------------------------------------------------------------------
NO_PATTERN = 0xFF
STEP = 12                       # ticks a 16th


def scene_band():
    """Scene 1: a small band. Returns (patterns, tracks, order): patterns
    {number: (steps, events)}, tracks [(pattern or None, channel, muted)]
    for the 16 tracks, order the tracks' priority."""
    drums = []
    for st in range(16):
        if st % 4 == 0:
            drums.append((st * STEP, "note", 36, 120, 6))           # kick
        if st % 8 == 4:
            drums.append((st * STEP, "note", 38, 110, 6))           # snare
        if st % 2 == 0:
            drums.append((st * STEP, "note", 42, 70 + 20 * (st % 4 == 0), 3))  # hat
    drums.sort(key=lambda e: e[0])
    bass = [(0, "note", 36, 100, 30), (24, "note", 36, 100, 30),    # retriggered: the
            (60, "note", 43, 90, 12), (84, "note", 48, 90, 60),     # first sounds over
            (120, "note", 36, 100, 6)]                              # the second's start
    pad = [(0, "program", 12), (0, "cc", 74, 20), (0, "note", 60, 80, 80),
           (0, "note", 64, 80, 80), (0, "note", 67, 80, 80), (30, "cc", 74, 60),
           (50, "bend", 0, 72), (70, "bend", 0, 64)]
    lead = [(0, "note", 72, 110, 24), (24, "note", 74, 100, 36)]   # 5 steps: loops at 60
    muted = [(0, "note", 50, 100, 12), (12, "cc", 7, 100)]
    long_note = [(0, "note", 30, 64, 400)]      # longer than its 16-step loop: retriggered
    many = [(t, "note", 20 + t // 2, 50, 1000) for t in range(0, 192, 2)]  # 96 long notes
    patterns = {0: (16, drums), 1: (12, bass), 2: (7, pad), 3: (5, lead), 4: (16, muted),
                5: (16, []), 6: (16, long_note), 7: (16, many)}
    tracks = ([(0, 9, False), (1, 1, False), (2, 2, False), (3, 2, False), (4, 4, True),
               (5, 5, False), (6, 6, False), (7, 7, False)]
              + [(None, i, False) for i in range(8, 16)])
    order = [0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    return patterns, tracks, order


def scene_heavy():
    """Scene 2: every track a 4-note chord and a controller on every 16th."""
    patterns, tracks = {}, []
    for t in range(16):
        events = []
        for st in range(16):
            root = 40 + t + (st % 4) * 3
            events += [(st * STEP, "note", root + i, 100 - st, STEP) for i in (0, 4, 7, 12)]
            events.append((st * STEP, "cc", 74, st * 8))
        patterns[t] = (16, events)
        tracks.append((t, t, False))
    return patterns, tracks, list(range(16))


def scene_overflow():
    """Scene 3: more notes sounding than the wheel's 128 entries (96 long
    notes on each of two channels): each new note ends the next off early."""
    many = [(t, "note", 20 + t // 2, 50, 1000) for t in range(0, 192, 2)]
    tracks = [(0, 7, False), (0, 8, False)] + [(None, i, False) for i in range(2, 16)]
    return {0: (16, many)}, tracks, list(range(16))


def scene_half():
    """Scene 4: the load SID500 must carry on time (the user: half the
    wire): every track a 2-note chord on every 16th."""
    patterns, tracks = {}, []
    for t in range(16):
        events = []
        for st in range(16):
            root = 40 + t + (st % 4) * 3
            events += [(st * STEP, "note", root + i, 100 - st, STEP) for i in (0, 7)]
        patterns[t] = (16, events)
        tracks.append((t, t, False))
    return patterns, tracks, list(range(16))


def scene_light():
    """Scene 5: the band's drums, bass, pad and lead only (tools/
    transport_check.py: many stops fit in a log; still a retriggered
    bass, long pad notes, controllers, bend and a program change)."""
    patterns, tracks, order = scene_band()
    tracks = tracks[:4] + [(None, i, False) for i in range(4, 16)]
    return {k: patterns[k] for k in (0, 1, 2, 3)}, tracks, order


SCENES = {1: scene_band, 2: scene_heavy, 3: scene_overflow, 4: scene_half, 5: scene_light}


def band_republish():
    """TEST_LIVE=2 (tools/play_check.py): the band's patterns replaced while
    they play, as an edit publishes them (src/live.asm live_publish): [(from
    pass n, pattern, steps, events)]. Lengths change (the lead 5 -> 7 -> 5
    steps, the pad 7 -> 4), the many notes' long stream is replaced with its
    readers deep in it, the lead twice in quick succession (a switch being
    read dropped), the empty pattern given notes and the drums put back.
    About as often as an editor publishes (70 passes: ~300 ms at 295 BPM):
    switches are made one at a time, so publishes of several patterns at
    once wait for each other."""
    patterns = scene_band()[0]
    drums2 = sorted([(st * STEP, "note", 36, 120, 6) for st in (0, 6, 10)]
                    + [(st * STEP, "note", 46, 60 + st, 2) for st in range(1, 16, 2)],
                    key=lambda e: e[0])
    lead7 = [(0, "note", 76, 100, 18), (30, "note", 79, 90, 12), (60, "note", 74, 80, 24)]
    lead5 = [(12, "note", 71, 120, 12), (36, "note", 69, 90, 6)]
    many2 = [(t, "note", 30 + t // 3, 60, 500) for t in range(1, 192, 3)]
    bass2 = [(0, "note", 31, 100, 18), (36, "note", 38, 100, 12), (72, "note", 43, 80, 30)]
    pad2 = [(0, "program", 20), (0, "note", 62, 70, 40), (6, "cc", 74, 90), (30, "bend", 0, 80)]
    empty2 = [(st * STEP, "note", 84 - st, 50, 4) for st in range(0, 16, 4)]
    return [(100, 0, 16, drums2), (160, 3, 7, lead7), (175, 3, 5, lead5), (240, 7, 16, many2),
            (310, 1, 12, bass2), (380, 2, 4, pad2), (440, 5, 16, empty2),
            (500, 0, 16, patterns[0][1])]


def play_tables():
    """For each test scene, under .if TEST_PLAY == n: play_streams (as
    test_streams), play_tracks (16 patterns, 16 channels, 16 mutes) and
    play_order."""
    out = []
    for n, scene in SCENES.items():
        patterns, tracks, order = scene()
        streams, blocks = [], 0
        for number, (steps, events) in sorted(patterns.items()):
            stream = encode(events)
            streams += [number, steps, len(stream) & 0xFF, len(stream) >> 8] + stream
            blocks += blocks_for(stream)
        streams.append(0xFF)
        tr = ([NO_PATTERN if p is None else p for p, _, _ in tracks] + [ch for _, ch, _ in tracks]
              + [int(m) for _, _, m in tracks])
        out.append(f".if TEST_PLAY == {n}\n"
                   + f"PLAY_BLOCKS = {blocks}             ; the pool blocks its patterns take\n"
                   + "        .section play_data      ; (sid500.asm: where it goes)\n"
                   + table("play_streams", streams, f"test scene {n}'s patterns (as test_streams)")
                   + table("play_tracks", tr, "its tracks: 16 patterns, 16 channels, 16 mutes")
                   + table("play_order", order, "the tracks' priority order")
                   + "        .send\n"
                   + ".endif\n")
    # TEST_LIVE=2: the band's patterns replaced while playing
    rep = []
    for n, number, steps, events in band_republish():
        stream = encode(events)
        rep += [n & 0xFF, n >> 8, number, steps, len(stream) & 0xFF, len(stream) >> 8] + stream
    rep += [0xFF, 0xFF]
    out.append(".if TEST_PLAY == 1 && TEST_LIVE >= 2\n"
               + table("republish_streams", rep, "TEST_LIVE 2 and 3: from pass (2), pattern, steps,"
                       " length (2), stream; $FFFF ends (in the program: the log's RAM is"
                       " cleared at start)")
               + ".endif\n")
    return "\n".join(out)


# -----------------------------------------------------------------------------
# Test feeds (TEST_SLAVE=n): a master's realtime bytes into MIDI in, for
# tools/slave_check.py (src/test_slave.asm feeds them on raster lines)
# -----------------------------------------------------------------------------
LINE_CYCLES = 63                # PAL: a raster line
FEED_START = 20000              # the first byte this many cycles after start-up


def clock_gap(bpm):
    """A MIDI clock's gap at bpm (24 a quarter), in cycles."""
    return PAL_CLOCK * 60 / (24 * bpm)


def clocks(t, bpm, seconds, jitter=0, seed=1):
    """(times, end): clocks from t at bpm for seconds, each moved by up to
    jitter cycles either way (a master's own jitter), and the time after."""
    rnd = random.Random(seed)
    out, gap = [], clock_gap(bpm)
    for i in range(round(seconds * PAL_CLOCK / gap)):
        out.append(t + i * gap + rnd.uniform(-jitter, jitter))
    return out, t + len(out) * gap


def feed_steady():
    """Feed 1: 120 BPM, clocks before start (a master's idle clock), start
    between two clocks, then 3 s of clocks."""
    pre, t = clocks(FEED_START, 120, 0.3)
    run, _ = clocks(t, 120, 3)
    return [(c, 0xF8) for c in pre] + [(t - 5000, 0xFA)] + [(c, 0xF8) for c in run]


def feed_jitter():
    """Feed 2: 120 BPM with each clock up to 1 ms off (a jittery master)."""
    pre, t = clocks(FEED_START, 120, 0.3)
    run, _ = clocks(t, 120, 3, jitter=1000)
    return [(c, 0xF8) for c in pre] + [(t - 5000, 0xFA)] + [(c, 0xF8) for c in run]


def feed_faster():
    """Feed 3: 100 BPM, then 240 at once: the first fast clock comes
    before the odd tick's one-shot (half the slow gap) runs out."""
    pre, t = clocks(FEED_START, 100, 0.3)
    slow, t2 = clocks(t, 100, 1)
    fast, _ = clocks(t2, 240, 2)
    return ([(c, 0xF8) for c in pre] + [(t - 5000, 0xFA)]
            + [(c, 0xF8) for c in slow + fast])


def feed_slower():
    """Feed 4: 240 BPM, then 60 at once."""
    pre, t = clocks(FEED_START, 240, 0.3)
    fast, t2 = clocks(t, 290, 1)
    slow, _ = clocks(t2, 60, 2)
    return ([(c, 0xF8) for c in pre] + [(t - 5000, 0xFA)]
            + [(c, 0xF8) for c in fast + slow])


def feed_change():
    """Feed 5: a song's tempo change: 120 BPM, 150 at once, then 120 again."""
    pre, t = clocks(FEED_START, 120, 0.3)
    a, t2 = clocks(t, 120, 1)
    b, t3 = clocks(t2, 150, 1)
    c, _ = clocks(t3, 120, 1)
    return ([(x, 0xF8) for x in pre] + [(t - 5000, 0xFA)]
            + [(x, 0xF8) for x in a + b + c])


def feed_switch():
    """Feed 6 (with TEST_SWITCH: master first, Clock to MIDI after ~1 s):
    clocks at 120 BPM from 0.5 s, across the switch, start at 2 s."""
    pre, t = clocks(FEED_START + PAL_CLOCK // 2, 120, 1.5)
    run, _ = clocks(t, 120, 2)
    return [(c, 0xF8) for c in pre] + [(t - 5000, 0xFA)] + [(c, 0xF8) for c in run]


def feed_transport():
    """Feed 7: 120 BPM clocks throughout (as many masters send them while
    stopped too): start, stop between two clocks, continue, stop, start
    from the start again (the song not there: the slave resets it while
    the clocks go on), stop."""
    gap = clock_gap(120)
    run, end = clocks(FEED_START, 120, 6)
    out = [(c, 0xF8) for c in run]
    first = FEED_START + 15 * gap               # after 15 clocks
    events = [(first - 5000, 0xFA), (first + 60.4 * gap, 0xFC),     # (closer since the
              (first + 80.5 * gap, 0xFB), (first + 128.3 * gap, 0xFC),  # test log became
              (first + 148.5 * gap, 0xFA), (first + 188.6 * gap, 0xFC)] # 7 pages: stage E)
    return sorted(out + events)


def feed_stops():
    """Feed 8: 120 BPM clocks throughout, start, then eight stops, each
    continued ten clocks later, each stretch played 0.6 clocks (1.2
    ticks) longer than the one before: as each continue starts on a 16th,
    the stops fall at every place in a 16th, both short of the next 16th's
    start by more than the lead and within it."""
    gap = clock_gap(120)
    run, _ = clocks(FEED_START, 120, 9)
    t = FEED_START + 10 * gap
    events = [(t - 5000, 0xFA)]
    for i in range(8):
        stop = t + (20.35 + 0.6 * i) * gap
        t = stop + 10.95 * gap
        events += [(stop, 0xFC), (t, 0xFB)]
    events.append((t + 20.3 * gap, 0xFC))
    return sorted([(c, 0xF8) for c in run] + events)


def feed_short():
    """Feed 9: 120 BPM clocks throughout; start, ~0.45 s played (the heavy
    scene's renderer behind by then, its ticks going out partly), stop: a
    log holds every byte of it."""
    gap = clock_gap(120)
    run, _ = clocks(FEED_START, 120, 4)
    t = FEED_START + 10 * gap
    events = [(t - 5000, 0xFA), (t + 22.35 * gap, 0xFC)]
    return sorted([(c, 0xF8) for c in run] + events)


def feed_positions():
    """Feed 14: 120 BPM clocks throughout; start, stop; song position 37 (an
    odd 16th) and continue right after it, as DAWs send them; stop; song
    position 0 and continue; stop; a bare continue (where it stopped: on
    time); stop; start (away from the song's start: reset first, as stage
    A's); stop; song position 333 (bar 21) and continue; stop
    (src/locate.asm, tools/transport_check.py)."""
    gap = clock_gap(120)
    run, _ = clocks(FEED_START, 120, 9)
    first = FEED_START + 15 * gap
    byte = 17 * LINE_CYCLES                     # (bytes of a message: the feed's least apart)

    def spp(t, n):
        return [(t, 0xF2), (t + byte, n & 0x7F), (t + 2 * byte, n >> 7), (t + 3 * byte, 0xFB)]
    events = [(first - 5000, 0xFA), (first + 25.4 * gap, 0xFC)]          # (30 clocks, ~0.6
    events += spp(first + 55.3 * gap, 37) + [(first + 80.4 * gap, 0xFC)]  # s, after a stop:
    events += spp(first + 110.3 * gap, 0) + [(first + 135.4 * gap, 0xFC)]  # its offs on the
    events += [(first + 165.5 * gap, 0xFB), (first + 190.4 * gap, 0xFC)]   # wire take ~0.2 s
    events += [(first + 220.5 * gap, 0xFA), (first + 245.4 * gap, 0xFC)]   # with the band)
    events += spp(first + 275.3 * gap, 333) + [(first + 300.4 * gap, 0xFC)]
    return sorted([(c, 0xF8) for c in run] + events)


FEED_POSITIONS_SONG = [20, 30, 46]      # (tools/locate_check.py: the 16ths fed: scene 2, 3, and round once into scene 2)


def feed_positions_song():
    """Feed 15 (tools/locate_check.py, with TEST_SCENES 1: Song on): 120 BPM
    clocks throughout; for each of FEED_POSITIONS_SONG, a song position and
    continue right after it, 30 clocks played, stop, 30 clocks stopped."""
    gap = clock_gap(120)
    run, _ = clocks(FEED_START, 120, 11)
    byte = 17 * LINE_CYCLES
    t = FEED_START + 20.3 * gap
    events = []
    for n in FEED_POSITIONS_SONG:
        events += [(t, 0xF2), (t + byte, n & 0x7F), (t + 2 * byte, n >> 7),
                   (t + 3 * byte, 0xFB), (t + 30.1 * gap, 0xFC)]
        t += 60 * gap
    return sorted([(c, 0xF8) for c in run] + events)


ARM_POSITIONS = [20, 37]        # (feed 16: the song positions fed, the last the take's)
ARM_STOP = 200                  # (feed 16: clocks played before the stop: two loops and a bit)


def feed_arm():
    """Feed 16 (tools/locate_check.py, with TEST_ARM: the take armed at
    start-up): 120 BPM clocks throughout; song position 20, then 37 and a
    continue right after it; a note on and off before the continue and one
    between it and the first clock (both left out of the take), then a note
    on every 6 clocks with its off 2 clocks later, ARM_STOP clocks
    played (two of the new pattern's loops and a bit), stop. Returns the
    feed; feed_arm_notes() the played notes."""
    gap = clock_gap(120)
    run, _ = clocks(FEED_START, 120, (17 + ARM_STOP + 4) * gap / PAL_CLOCK)
    byte = 18 * LINE_CYCLES
    first = FEED_START + 10 * gap
    events = []
    for k, n in enumerate(ARM_POSITIONS):
        t = first + 0.3 * gap + 3 * k * gap
        events += [(t, 0xF2), (t + byte, n & 0x7F), (t + 2 * byte, n >> 7)]
    cont = first + 6.3 * gap + 3 * byte
    events.append((cont, 0xFB))
    for t, msg in feed_arm_notes():
        for i, b in enumerate(msg):
            events.append((t + i * 18 * LINE_CYCLES, b))
    events.append((first + (7 + ARM_STOP) * gap + 0.4 * gap, 0xFC))
    return sorted([(c, 0xF8) for c in run] + events)


def feed_arm_notes():
    """feed_arm's notes: [(time of the first byte, bytes)]; the first two
    pairs before the master's first tick."""
    gap = clock_gap(120)
    first = FEED_START + 10 * gap
    out = [(first + 2.5 * gap, (0x90, 50, 90)), (first + 3.8 * gap, (0x90, 50, 0)),
           (first + 6.6 * gap, (0x90, 52, 90)), (first + 6.8 * gap, (0x90, 52, 0))]
    t, note = first + 9.5 * gap, 60
    while t < first + (7 + ARM_STOP - 4) * gap:
        out += [(t, (0x90, note, 100)), (t + 2 * gap, (0x90, note, 0))]
        t += 6 * gap
        note = 60 + (note - 59) % 12
    return out


# a keyboard's phrase (TEST_FEED_MASTER: tools/thru_check.py): notes with
# and without running status, an off as a note on of velocity 0 and as
# $8x, a controller twice (running status), bend, a program change, both
# aftertouches (not passed on), and a drum pad on channel 10
KEYS_PHRASE = [[0x90, 100, 90], [102, 80], [100, 0], [0x80, 102, 64],
               [0xB0, 20, 64], [20, 70], [0xE0, 0, 64], [0xC0, 5],
               [0xD0, 40], [0xA0, 101, 30], [0x99, 103, 100], [0x89, 103, 0]]
KEYS_REPEATS = 20               # (the feed under I/O: ~1,860 bytes of the room there)
KEYS_EVERY = 0.25               # seconds between the phrases' starts
KEYS_BYTE_LINES = 17            # between a phrase's bytes (the feed's least: 16 lines)


def feed_keys():
    """Feed 10 (with TEST_FEED_MASTER): KEYS_PHRASE every KEYS_EVERY s from
    0.2 s on, each phrase's bytes KEYS_BYTE_LINES apart (a message ~2 ms)."""
    out = []
    for r in range(KEYS_REPEATS):
        t = FEED_START + PAL_CLOCK * (0.2 + r * KEYS_EVERY) + r * 37 * LINE_CYCLES
        for b in [b for m in KEYS_PHRASE for b in m]:
            out.append((t, b))
            t += KEYS_BYTE_LINES * LINE_CYCLES
    return out


def take_part():
    """A played part for recording (feed 11): [(seconds from TAKE_FROM,
    [bytes])], a message each (running status where the bytes leave the
    status out). A phrase of TAKE_PHRASE seconds, TAKE_REPEATS times, a
    semitone up each time: single notes, a chord whose keys come and go
    apart, a controller swept every 4 ms (thinned to a pass), bend, a
    program change, aftertouch (left out), a note held across ~1 s (over
    a loop's end), offs as $8x and as velocity 0."""
    out = []
    for r in range(TAKE_REPEATS):
        t0, up = r * TAKE_PHRASE, r
        out += [(t0 + 0.00, [0x90, 60 + up, 100]), (t0 + 0.11, [0x80, 60 + up, 64]),
                (t0 + 0.26, [0x90, 62 + up, 90]), (t0 + 0.40, [62 + up, 0]),
                (t0 + 0.50, [0x90, 64 + up, 80]), (t0 + 0.505, [67 + up, 81]),
                (t0 + 0.512, [71 + up, 82]), (t0 + 0.90, [64 + up, 0]),
                (t0 + 0.93, [0x80, 67 + up, 0]), (t0 + 0.96, [71 + up, 0])]
        for i in range(25):
            out.append((t0 + 1.0 + i * 0.004, [0xB0, 1, 10 + 2 * i] if i == 0 else [1, 10 + 2 * i]))
        out += [(t0 + 1.20, [0xE0, 0, 70]), (t0 + 1.205, [0, 72]), (t0 + 1.30, [0, 64]),
                (t0 + 1.40, [0xC0, 5 + r]), (t0 + 1.45, [0xD0, 40]), (t0 + 1.47, [0xA0, 60, 30]),
                (t0 + 1.60, [0x90, 48 + up, 110]), (t0 + 2.60, [0x90, 48 + up, 0]),
                (t0 + 1.75, [0x90, 72 + up, 70]), (t0 + 1.78, [0x80, 72 + up, 0])]
    return sorted(out, key=lambda m: m[0])


TAKE_FROM = 0.6                 # seconds from start-up to the part (the song playing)
TAKE_PHRASE = 2.3               # seconds a phrase (not the loop's length: the take crosses it)
TAKE_REPEATS = 3


def feed_take():
    """Feed 11 (with TEST_FEED_MASTER, TEST_RECORD): take_part's bytes,
    KEYS_BYTE_LINES apart within a message."""
    out = []
    for s, msg in take_part():
        t = FEED_START + PAL_CLOCK * (TAKE_FROM + s)
        for b in msg:
            out.append((t, b))
            t += KEYS_BYTE_LINES * LINE_CYCLES
    out.sort(key=lambda e: e[0])
    return out


COUNT_FROM, COUNT_TO = 1.5, 2.6  # seconds from start-up: the notes fed across a count-in's
                                 # end (~2 s at the tests' tempos), into the song after it
COUNT_EVERY = 0.018             # seconds between the messages (a note on, then its off)


def feed_count():
    """Feed 12 (with TEST_FEED_MASTER, TEST_COUNT): a message every
    COUNT_EVERY s from COUNT_FROM to COUNT_TO, a note on (C4 up an octave
    in turn) and its off (velocity 0, running status) by turns: the ones
    before the count-in's last COUNT_EARLY ticks left out of the take, the
    ones in them at pass 0, those after the song's start as ever
    (tools/count_check.py)."""
    out, t, i = [], COUNT_FROM, 0
    while t < COUNT_TO:
        note = 60 + (i // 2) % 12
        msg = [0x90, note, 100] if i % 2 == 0 else [note, 0]
        b = FEED_START + PAL_CLOCK * t
        for x in msg:
            out.append((b, x))
            b += KEYS_BYTE_LINES * LINE_CYCLES
        t += COUNT_EVERY
        i += 1
    return out


SCENE_MIDI = [  # feed 13 (scene_check.py): (seconds from start-up, bytes)
    (0.40, [0xB0, 85, 1]),          # CC 85 on SID500's channel (1): scene 2
    (1.30, [0xC0, 2]),              # a program change there: scene 3
    (1.60, [0xC1, 5]),              # one on channel 2: passed through, not a launch
    (1.70, [0xB0, 85, 100]),        # CC 85 past 63: as any other message (thru)
    (2.20, [0xF3, 0]),              # song select: Song on
]


def feed_scene_midi():
    """Feed 13 (with TEST_FEED_MASTER, TEST_SCENES): SCENE_MIDI's messages,
    KEYS_BYTE_LINES apart within a message."""
    out = []
    for s_, msg in SCENE_MIDI:
        t = FEED_START + PAL_CLOCK * s_
        for b in msg:
            out.append((t, b))
            t += KEYS_BYTE_LINES * LINE_CYCLES
    return out


FEEDS = {1: feed_steady, 2: feed_jitter, 3: feed_faster, 4: feed_slower, 5: feed_change,
         6: feed_switch, 7: feed_transport, 8: feed_stops, 9: feed_short, 10: feed_keys,
         11: feed_take, 12: feed_count, 13: feed_scene_midi, 14: feed_positions,
         15: feed_positions_song, 16: feed_arm}


def feed_lines(feed):
    """A feed as src/test_slave.asm takes it: (first, entries): the lines
    to the first byte, then each byte with the lines to the next (0 = the
    last); times rounded to whole lines."""
    lines = [round(t / LINE_CYCLES) for t, _ in feed]
    entries = []
    for i, (_, b) in enumerate(feed):
        d = lines[i + 1] - lines[i] if i + 1 < len(feed) else 0
        assert i + 1 == len(feed) or 16 <= d < 65536, (i, d)   # (a raster interrupt
        entries += [b, d & 255, d >> 8]                         # late by < 16 lines)
    return lines[0], entries


def feed_tables():
    out = []
    for n, feed in FEEDS.items():
        first, entries = feed_lines(feed())
        out.append(f".if TEST_SLAVE == {n}\nfeed_first = {first}\n"
                   + "        .section feed_data      ; (sid500.asm: after the program)\n"
                   + table("feed_bytes", entries,
                           f"test feed {n}: each byte, then the raster lines to the next")
                   + "        .send\n"
                   + ".endif\n")
    return "\n".join(out)


SIG_EIGHTHS = 0x80              # src/player.asm SCENE_SIG: the beats - 1, + this for n/8
SCENE_ROWS_EXTRA = {             # scenes 2 and 3 for the scene tests (scene 1: the band's row)
    1: [3, 2, None, 0, None, 6, None, None, 1] + [None] * 7,
    2: [0, None, None, None, None, None, None, 7] + [None] * 8,
}
SCENE_TESTS = {  # tools/scene_check.py: (Song on, [(bars, signature, repeats)] scenes 1-3,
                 #  [(play tick, action, a, b)]: 0 = scene a launched, 1 = track a's cell in
                 #  scene b launched, 2 = Song a)
    1: (1, [(1, 0, 3), (1, 2, 1), (1, 4 | SIG_EIGHTHS, 1)], []),
    2: (0, [(1, 0, 3), (1, 2, 1), (1, 4 | SIG_EIGHTHS, 1)],
        [(60, 0, 1, 0), (130, 1, 7, 2), (250, 0, 2, 0), (400, 0, 0, 0)]),
    3: (0, [(1, 0, 3), (1, 2, 1), (1, 4 | SIG_EIGHTHS, 1)], []),    # (launched by MIDI)
    # 3 = track a's cell in the playing scene set to pattern b (a live switch),
    # 4 = a stop, 5 = continue once stopped (the tick unused)
    4: (0, [(1, 0, 3), (1, 2, 1), (1, 4 | SIG_EIGHTHS, 1)],
        [(60, 0, 1, 0), (94, 4, 0, 0), (0, 5, 0, 0), (170, 3, 1, 4), (250, 4, 0, 0),
         (0, 5, 0, 0), (330, 0, 2, 0)]),
    5: (0, [(1, 0, 3), (1, 2, 1), (1, 4 | SIG_EIGHTHS, 1)],      # (a take after a launch)
        [(60, 0, 1, 0), (250, 0, 2, 0)]),
}


SCENE_TEST_ROW = {5: 1}         # the cursor's scene at start (a take's: scene 2, playing)


def scene_tests():
    """Each scene test under .if TEST_SCENES == n (src/scene.asm scene_test)."""
    out = []
    for n, (song, scenes, actions) in SCENE_TESTS.items():
        rows = []
        for k in sorted(SCENE_ROWS_EXTRA):
            rows += [NO_PATTERN if p is None else p for p in SCENE_ROWS_EXTRA[k]]
        acts = []
        for tick, kind, a, b in actions:
            acts += [tick & 0xFF, tick >> 8, kind, a, b]
        acts += [0, 0, 0xFF, 0, 0]
        out.append(f".if TEST_SCENES == {n}\nST_SCENES = {len(scenes)}\nST_SONG = {song}\n"
                   + f"ST_ROW = {SCENE_TEST_ROW.get(n, 0)}\n"
                   + table("st_rows", rows, "scenes 2..: a pattern a track") + "st_rows_end\n"
                   + table("st_bars", [b for b, _, _ in scenes], "scenes 1..: bars")
                   + table("st_sigs", [g for _, g, _ in scenes], "signatures")
                   + table("st_reps", [r for _, _, r in scenes], "repeats")
                   + table("st_actions", acts, "play tick (2), action, a, b; $FF: the end")
                   + ".endif\n")
    return "\n".join(out)



# -----------------------------------------------------------------------------
# The family's names (stage F, design 5d): read from the synths' own
# sources at build time (../sid303, ../sid808, ../sid101), so they never
# drift: each synth's controllers (cc_numbers, cc_params) named by their
# parameters' names, SID808's drum sounds by GM note.
# -----------------------------------------------------------------------------
FAMILY = [("sid303", 1), ("sid808", 2), ("sid101", 3)]   # the setting's values (list.asm)
NAME_LEN = 8                    # a controller's name in the event list
SHORT = {"Resonance": "Reso", "Slide time": "Slide", "Amp decay": "Amp dcy",
         "Voice mode": "Voice md", "Pulse / sync": "Pls/sync", "Pulse width": "Pulse w",
         "Sync pitch": "Sync pch", "Chord speed": "Chord sp", "LFO shape": "LFO shp",
         "LFO delay": "LFO dly", "LFO cutoff": "LFO cut", "Mod wheel": "Mod whl",
         "Glide mode": "Glide md", "Arp range": "Arp rng"}
                                # (Claude's short forms of the names over 8 letters)
FAMILY_ROOT = os.environ.get("SIDSYNTH_PROJECTS",          # (where sid303, sid808 and
                             os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
                                # sid101 are: beside this project, unless a copy elsewhere
                                # says: tools/build_matrix.py's worktree)


def synth_controllers(name):
    """[(controller, its parameter's name)] for synth name, from its sources."""
    import re
    root = os.path.join(FAMILY_ROOT, name)
    assert os.path.isdir(root), f"the family's names need {root} (its sources)"
    params = {m.group(1): int(m.group(2)) for m in re.finditer(
        r"^(P_[A-Z0-9_]+)\s*=\s*(\d+)", open(os.path.join(root, name + ".asm")).read(), re.M)}
    lines = open(os.path.join(root, "src", "params.asm")).read().split("\n")

    def after(label):
        """The values of the .byte lines from label's on."""
        i = next(k for k, ln in enumerate(lines) if ln.startswith(label))
        out = []
        for k in range(i, len(lines)):
            ln = lines[k]
            if k > i and not ln.lstrip().startswith(".byte"):
                break
            body = ln.split(".byte", 1)[1].split(";", 1)[0]
            out += [v.strip() for v in body.split(",") if v.strip()]
        return out
    numbers = [int(v) for v in after("cc_numbers")]
    targets = [params[v] for v in after("cc_params")]
    i = next(k for k, ln in enumerate(lines) if ln.startswith("param_names"))
    names = []
    for ln in lines[i + 1:]:
        m = re.match(r'\s+\.text "(.*)"', ln)
        if not m:
            break
        names.append(m.group(1).strip())
    assert len(numbers) == len(targets), name
    out = []
    for cc, p in zip(numbers, targets):
        n = SHORT.get(names[p], names[p])
        assert len(n) <= NAME_LEN, f"{name}: {names[p]!r} needs a short form in SHORT"
        out.append((cc, n))
    return out


def drum_map():
    """SID808's GM note map: {note: sound name}, and its sounds in order."""
    import ast
    import re
    src = open(os.path.join(FAMILY_ROOT, "sid808", "tables.py")).read()
    gm = ast.literal_eval(re.search(r"^GM = (\{.*?\})", src, re.M | re.S).group(1))
    sounds = re.findall(r'^    \("(\w{3})", ', src[src.index("SOUNDS = ["):], re.M)
    return gm, sounds


def family_names():
    """The names' tables (after late_code's code: list.asm names_*)."""
    entries = [(sid, cc, n) for name, sid in FAMILY for cc, n in synth_controllers(name)]
    gm, sounds = drum_map()
    first, last = min(gm), max(gm)
    drums = sorted(set(gm.values()), key=sounds.index)
    note_sound = [drums.index(gm[n]) if n in gm else 255 for n in range(first, last + 1)]
    out = [".if LIST_CODE                   ; (sid500.asm: else none, src/names.asm)",
           "        .section late_code      ; (the family's names: design 5d)",
           f"NAMES_CC = {len(entries)}",
           f"DRUM_FIRST = {first}",
           f"DRUM_NOTES = {last - first + 1}",
           table("names_cc_synth", [e[0] for e in entries],
                 "each controller name's synth (1 SID303, 2 SID808, 3 SID101)"),
           table("names_cc_num", [e[1] for e in entries], "  and its controller"),
           table("drum_note_sound", note_sound,
                 "SID808's sound for each note from DRUM_FIRST ($FF: none; its GM map)"),
           '        .enc "screen"',
           "names_cc_text   ; the controllers' names, 8 places each"]
    out += [f'        .text "{n:<{NAME_LEN}}"' for _, _, n in entries]
    out += ["drum_names      ; SID808's sounds' names, 3 places each"]
    out += [f'        .text "{n}"' for n in drums]
    out += ['        .enc "none"', "        .send", ".endif", ""]
    return "\n".join(out)


def main():
    parts = [tick_latch(), ".if !MATH_SHIFT_MUL\n" + sq_tables() + ".endif\n", tempo_tables(),
             test_streams(), play_tables(),
             feed_tables(), scene_tests(), family_names()]
    with open("tables.inc", "w", newline="\n") as f:
        f.write("; tables.inc - generated by tables.py, do not edit\n\n")
        f.write("\n".join(parts))


if __name__ == "__main__":
    main()
