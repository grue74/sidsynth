# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate lookup tables for sid303.asm (writes tables.inc, 64tass syntax).

Run:  python tables.py            (build.sh does this before assembling)

All curves are computed here so the 6502 code only does table lookups and
a few 8x8 multiplies. The tick timer value, SID frequencies, the multiply
tables and the helpers (k8, k16, geo, table) come from core/tables_core.py;
timing values assume the PAL clock and the core's 250 Hz tick.
"""

import os
import sys

# shared helpers and the tables the core needs (core/tables_core.py)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
from tables_core import (PAL_CLOCK, TICK_HZ, TICK_LATCH, freq_tables,  # noqa: E402,F401
                         geo, k8, k16, sq_tables, table, tick_latch)
# the sequencer's (core/sequencer.asm); tools/seq_check.py reads them through tables
from tables_core import (BPM_MIN, BPM_MAX, SEQ_STEPS, GATE_LEN, REAL_TICK_HZ,  # noqa: E402,F401
                         TIME_REST, TIME_NOTE, TIME_TIE, FLAG_ACCENT, FLAG_SLIDE,
                         step_bytes, pattern_bytes, tempo_steps)
from tables_core import seq_tables as core_seq_tables  # noqa: E402


def test_pattern(sweep=False):
    """MIDI byte stream for the TEST_MIDI build: a 16-step acid line at 125 BPM.

    sweep=False (TEST_MIDI=1): four bars plus a bar of long notes, below.
    sweep=True  (TEST_MIDI=2): eight bars at high resonance with the cutoff
    (CC74) set on every step, swept from closed to fully open over two bars
    and back down over the next two, twice - the classic acid knob tweak.

    Deliberately exercises the parser: running status (note-offs are note-ons
    with velocity 0), MIDI clock ($F8) bytes between and inside messages,
    accents (velocity 127 vs 100), slides (next note-on before the previous
    note-off) and a CC74 cutoff change every bar.
    Entry format for test_feed: count, bytes..., ticks until the next entry;
    count 0 = end (restart).
    """
    step = round(TICK_HZ * 60 / 125 / 4)   # 16th note at 125 BPM, in ticks
    gate = step * 6 // 10
    line = ACID_LINE                    # (MIDI note, accent, slide into next)
    events = []                         # (tick, order, [bytes])
    bars = 8 if sweep else 4
    if sweep:
        events.append((0, 0, [0xB0, 71, 120]))          # resonance 15
    for bar in range(bars):
        t0 = bar * 16 * step
        if sweep:
            for i in range(16):                         # triangle 0 -> 127 -> 0, twice
                pos = ((bar * 16 + i) % 64) / 32        # 0..2 over four bars
                val = round(127 * (pos if pos <= 1 else 2 - pos))
                events.append((t0 + i * step, 0, [0xB0, 74, val]))
        else:
            events.append((t0, 0, [0xB0, 74, [30, 50, 70, 40][bar]]))
        for i, (note, acc, slide) in enumerate(line):
            t = t0 + i * step
            events.append((t, 2, [0x90, note, 127 if acc else 100]))
            off = t + (step + 1 if slide else gate)
            events.append((off, 1, [0x90, note, 0]))
    # one bar of long held notes (quarter notes, nearly full gate), so the
    # amplitude fade can be heard
    t0 = bars * 16 * step
    if not sweep:
        for i, (note, acc) in enumerate([(33, 1), (40, 0), (36, 0), (31, 1)]):
            t = t0 + i * 4 * step
            events.append((t, 2, [0x90, note, 127 if acc else 100]))
            events.append((t + 4 * step - 4, 1, [0x90, note, 0]))
    end = (bars + (0 if sweep else 1)) * 16 * step
    for t in range(0, end, 5):          # MIDI clock, 24 per quarter note
        events.append((t, 3, [0xF8]))
    events.sort(key=lambda e: (e[0], e[1]))

    # apply running status and push one clock byte inside a message per bar
    entries = []                        # (tick, bytes)
    status = None
    for n, (t, _, msg) in enumerate(events):
        out = list(msg)
        if msg[0] < 0xF8:
            if msg[0] == status:
                out = out[1:]
            status = msg[0]
            if msg[0] == 0x90 and t % (16 * step) == 4 * step and len(out) >= 2:
                out = out[:1] + [0xF8] + out[1:]
        if entries and entries[-1][0] == t:
            entries[-1][1].extend(out)
        else:
            entries.append((t, out))
    data = []
    for i, (t, b) in enumerate(entries):
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        wait = nxt - t - 1                # test_feed: emits, then waits this many ticks
        assert 0 <= wait < 256 and 0 < len(b) < 256
        data += [len(b)] + b + [wait]
    data.append(0)
    n = 2 if sweep else 1
    return (f".if TEST_MIDI == {n}\n"
            + table("test_pattern", data, f"TEST_MIDI={n} pattern for test_feed (see tables.py)")
            + ".endif\n")


def learn_pattern():
    """TEST_MIDI=3: controller messages for the MIDI learn test (TEST_KEYS=2).

    Times match the key script in sid303.asm. Gaps are filled with
    active-sensing bytes ($FE, ignored like all realtime bytes), and after the
    last controller they go on for about a minute, so the pattern doesn't
    restart during a test run.
    """
    ccs = [(1.0, 21, 10), (1.5, 74, 127), (2.5, 21, 127),
           (3.5, 12, 0), (4.5, 1, 127), (5.5, 22, 64)]
    entries = [(0, [0xFE])]                             # (tick, bytes)
    for sec, cc, val in ccs:
        entries.append((round(sec * TICK_HZ), [0xB0, cc, val]))
    end = entries[-1][0] + 60 * TICK_HZ
    filled = []
    for i, (t, b) in enumerate(entries):
        filled.append((t, b))
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        while nxt - filled[-1][0] > 256:                # test_feed waits up to 256 ticks
            filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    return (".if TEST_MIDI == 3\n"
            + table("test_pattern", data, "TEST_MIDI=3 pattern: MIDI learn test (see tables.py)")
            + ".endif\n")


def omni_pattern():
    """TEST_MIDI=4: OMNI_SKIP_DRUMS (channel 10 in omni). At 0.5 s A-2 on
    channel 1, velocity 64, held; at 1.0 s C-2 on channel 10, velocity 127,
    held; at 1.5 s CC74 = 0 on channel 10. Expected (status row and Cutoff,
    channel Omni): Note A-2, Vel 064 (the drum note ignored), Cutoff 000
    (controllers on channel 10 still count). Then active sensing ($FE) for
    about a minute, so the pattern doesn't restart during a test run.
    """
    entries = [(0, [0xFE]), (round(0.5 * TICK_HZ), [0x90, 45, 64]),
               (round(1.0 * TICK_HZ), [0x99, 36, 127]),
               (round(1.5 * TICK_HZ), [0xB9, 74, 0])]
    end = entries[-1][0] + 60 * TICK_HZ
    filled = []
    for i, (t, b) in enumerate(entries):
        filled.append((t, b))
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        while nxt - filled[-1][0] > 256:                # test_feed waits up to 256 ticks
            filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    return (".if TEST_MIDI == 4\n"
            + table("test_pattern", data, "TEST_MIDI=4 pattern: channel 10 in omni (see tables.py)")
            + ".endif\n")


# -----------------------------------------------------------------------------
# Step sequencer (core/sequencer.asm, docs/sequencer.md): the patterns
# -----------------------------------------------------------------------------
# A step: (note, accent, slide). note is a MIDI note, "-" a rest or "=" a tie.
# Pattern 1 is the TEST_MIDI=1 acid line (test_pattern's line), so a fresh
# start plays what the demos play.
ACID_LINE = [(33, 1, 0), (33, 0, 0), (45, 0, 1), (43, 0, 0),
             (33, 1, 0), (36, 0, 0), (33, 0, 0), (40, 1, 1),
             (38, 0, 0), (33, 0, 0), (45, 1, 0), (33, 0, 0),
             (31, 0, 1), (33, 0, 0), (36, 1, 0), (39, 0, 0)]
SEQ_PATTERNS = [ACID_LINE]

# TEST_EDGES: the playing rules' awkward cases (docs/sequencer.md, Playing),
# copied over pattern 1. tools/seq_check.py computes the notes they should give.
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

# TEST_SONG=1 (with TEST_EDGES=2's patterns): song entries (pattern index,
# repeats, transpose), song mode on
SONG_TEST = [(0, 2, 0), (1, 1, 5), (0, 1, -12)]


def seq_tables():
    """The sequencer's tables (core/tables_core.py) with these patterns."""
    return core_seq_tables(SEQ_PATTERNS, EDGES, (SHORT1, SHORT2), SONG_TEST)


CLOCK_TICKS = 5                 # TEST_MIDI=5: a MIDI clock every 5 ticks (125 BPM: 6 a step of 30)


def clock_events():
    """TEST_MIDI=5: MIDI clock in. Start at tick 25, a clock every
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


def clock_pattern():
    """The TEST_MIDI=5 feed: clock_events(), then active sensing ($FE,
    ignored) for about a minute, so the pattern doesn't restart in a test."""
    entries = [(0, [0xFE])] + clock_events()
    end = entries[-1][0] + 60 * TICK_HZ
    filled = []
    for i, (t, b) in enumerate(entries):
        filled.append((t, b))
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        while nxt - filled[-1][0] > 256:                # test_feed waits up to 256 ticks
            filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    return (".if TEST_MIDI == 5\n"
            + table("test_pattern", data, "TEST_MIDI=5 pattern: MIDI clock in (see tables.py)")
            + ".endif\n")


# -----------------------------------------------------------------------------
# Presets (src/presets.asm): 32 slots of the 15 sound parameters (Cutoff to
# Volume, the P_* order) and a 12-character name. Slot 1 is the start sound
# (src/params.asm param_default); the manual's starting points follow, then
# more acid sounds; the slots after them hold the start sound, named
# "Init". presets.inc holds them after the program's code (factory_presets:
# copied to PRESET_RAM at start).
# -----------------------------------------------------------------------------
PRESET_ORDER = ["CUTOFF", "RESO", "ENVMOD", "ENVTYPE", "DECAY", "ACCENT", "SLIDE", "AMPDECAY",
                "WAVE", "PW", "BLEND", "BODY", "TUNE", "FILTER", "VOLUME"]
NUM_PRESETS = 32
PRESET_NAME_LEN = 12
# the start sound: src/params.asm's param_default, Cutoff to Volume (slot 1
# must be exactly this: tools/preset_check.py checks it in VICE)
START_SOUND = dict(CUTOFF=80, RESO=12, ENVMOD=160, ENVTYPE=1, DECAY=6, ACCENT=10, SLIDE=8,
                   AMPDECAY=9, WAVE=0, PW=15, BLEND=6, BODY=0, TUNE=16, FILTER=0, VOLUME=15)
PRESET_MAX = dict(CUTOFF=255, RESO=15, ENVMOD=255, ENVTYPE=1, DECAY=15, ACCENT=15, SLIDE=15,
                  AMPDECAY=15, WAVE=3, PW=15, BLEND=15, BODY=15, TUNE=31, FILTER=3, VOLUME=15)
# (name, the changes from the start sound). Waveform: 0 saw, 1 square, 2
# saw+square, 3 303 square; Filter: 0 low-pass, 1 low+band, 2 band-pass,
# 3 high-pass; Env mod type: 0 up only, 1 centred.
FACTORY = [
    ("Classic acid", {}),
    ("Hard scream", dict(FILTER=1, RESO=15, ENVMOD=200, DECAY=1, ACCENT=15)),
    ("Buzzy", dict(FILTER=1, RESO=15, ENVMOD=200, DECAY=1, ACCENT=15, WAVE=2)),
    ("Square bass", dict(WAVE=3, BLEND=6)),
    ("Fuller bass", dict(WAVE=3, BLEND=6, BODY=4)),
    ("Held organ", dict(AMPDECAY=15)),
    ("Squelch", dict(CUTOFF=50, RESO=14, ENVMOD=230, DECAY=4, ACCENT=12)),
    ("Deep sub", dict(CUTOFF=60, RESO=4, ENVMOD=60, DECAY=8, WAVE=3, BODY=10, AMPDECAY=11)),
    ("Rubber", dict(CUTOFF=70, RESO=13, ENVMOD=140, DECAY=9, SLIDE=12, AMPDECAY=12)),
    ("Pluck", dict(CUTOFF=90, RESO=8, ENVMOD=180, DECAY=2, AMPDECAY=4)),
    ("Dark rumble", dict(CUTOFF=35, RESO=10, ENVMOD=90, DECAY=10, BODY=6, ENVTYPE=0)),
    ("Open saw", dict(CUTOFF=180, RESO=6, ENVMOD=60, DECAY=8, AMPDECAY=12)),
    ("Band-pass", dict(FILTER=2, CUTOFF=110, RESO=12, ENVMOD=150, DECAY=5)),
    ("Thin hi-pass", dict(FILTER=3, CUTOFF=60, RESO=11, ENVMOD=170, DECAY=5)),
    ("Up only", dict(ENVTYPE=0, CUTOFF=60, RESO=13, ENVMOD=200, DECAY=6)),
    ("Long decay", dict(DECAY=12, ENVMOD=180, RESO=13, AMPDECAY=13)),
    ("Slow slide", dict(SLIDE=14)),
    ("Hollow sq", dict(WAVE=1, PW=8, CUTOFF=100, RESO=10)),
    ("Saw+sq lead", dict(WAVE=2, CUTOFF=140, RESO=9, ENVMOD=120, DECAY=8, AMPDECAY=13)),
    ("Wild accent", dict(ACCENT=15, RESO=14, ENVMOD=210, DECAY=3)),
    ("Soft acid", dict(CUTOFF=95, RESO=8, ENVMOD=100, ACCENT=6)),
    ("Tight bass", dict(DECAY=3, AMPDECAY=5, RESO=9, ENVMOD=130, WAVE=3, BLEND=4)),
]


def presets():
    """The 32 slots: [(name, [15 values in PRESET_ORDER])]."""
    out = []
    for name, changes in FACTORY:
        assert len(name) <= PRESET_NAME_LEN and all(k in START_SOUND for k in changes), name
        sound = dict(START_SOUND, **changes)
        for k, v in sound.items():
            assert 0 <= v <= PRESET_MAX[k], (name, k, v)
        out.append((name, [sound[k] for k in PRESET_ORDER]))
    while len(out) < NUM_PRESETS:
        out.append(("Init", [START_SOUND[k] for k in PRESET_ORDER]))
    return out


def presets_inc():
    """presets.inc: factory_presets (32 x 15 values, then 32 x 12 name
    characters in screen codes), included after the program's code."""
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


PRESET_DEMO_TICKS = 960                 # two bars of pattern 1 at 125 BPM, per preset


def feed(n, events, end, comment):
    """A TEST_MIDI=n feed (core/test_feed.asm) of events [(tick, [bytes])]
    (ticks from 1 on, rising) that starts again at tick end. Entries: byte
    count, bytes, ticks to the next (at most 255: active sensing fills
    longer gaps)."""
    filled = [(0, [0xFE])]              # (tick 0: a filler, so events may start at tick 1)
    for i, (t, b) in enumerate(events):
        while t - filled[-1][0] > 256:
            filled.append((filled[-1][0] + 256, [0xFE]))
        filled.append((t, b))
    while end - filled[-1][0] > 256:
        filled.append((filled[-1][0] + 256, [0xFE]))
    data = []
    for i, (t, b) in enumerate(filled):
        nxt = filled[i + 1][0] if i + 1 < len(filled) else end
        assert 0 < nxt - t <= 256, (t, nxt)
        data += [len(b)] + b + [nxt - t - 1]
    data.append(0)
    return (f".if TEST_MIDI == {n}\n" + table("test_pattern", data, f"TEST_MIDI={n}: {comment}")
            + ".endif\n")


def preset_demo():
    """TEST_MIDI=6, demos/presets/factory.wav (with TEST_SEQ=1): the
    sequencer plays pattern 1 while program changes pick each factory
    preset in turn, two bars each."""
    events = [(1 + i * PRESET_DEMO_TICKS, [0xC0, i]) for i in range(len(FACTORY))]
    return feed(6, events, 1 + len(FACTORY) * PRESET_DEMO_TICKS,
                "each factory preset in turn (program change)")


def demo_times():
    """[(seconds into the demo, slot, name)]: when each preset starts."""
    return [(i * PRESET_DEMO_TICKS / TICK_HZ, i + 1, name) for i, (name, _) in enumerate(FACTORY)]


CC = dict(CUTOFF=74, RESO=71, VOLUME=7)  # src/params.asm cc_numbers (the ones the tests use)
PRESET_TEST_GAP = 100                   # ticks between the program changes (TEST_MIDI=7)
PRESET_TEST_VOLUME = 10                 # set first: a recall must keep it
PRESET_TEST_VOLUME_CC = 84              # the CC value for it (param_set_v: 84*2*16 >> 8 = 10)


def preset_test():
    """TEST_MIDI=7 (tools/preset_check.py): Volume set (a recall keeps it),
    then a program change to every slot, then to 40 and 127 (ignored),
    PRESET_TEST_GAP ticks apart, each followed half way by a Cutoff
    controller to 2, a value no preset has (the sound edited)."""
    assert (PRESET_TEST_VOLUME_CC * 2 * 16) >> 8 == PRESET_TEST_VOLUME
    ev = [(20, [0xB0, CC["VOLUME"], PRESET_TEST_VOLUME_CC])]
    t = 50
    for p in list(range(NUM_PRESETS)) + [40, 127]:
        ev.append((t, [0xC0, p]))
        ev.append((t + PRESET_TEST_GAP // 2, [0xB0, CC["CUTOFF"], 1]))
        t += PRESET_TEST_GAP
    return feed(7, ev, t + 200, "every preset by program change (tools/preset_check.py)")


def preset_load():
    """TEST_MIDI=8 (tools/preset_check.py): the load test for presets, an
    80-tick loop: program change to Hard scream, 40 ticks later to Fuller
    bass (a different waveform: the voices are retriggered), and a Cutoff
    controller on every other tick between; the check plays pattern 1 over
    it with the step screen open."""
    names = [n for n, _ in FACTORY]
    ev = [(1, [0xC0, names.index("Hard scream")]), (41, [0xC0, names.index("Fuller bass")])]
    ev += [(t, [0xB0, CC["CUTOFF"], 40 + t]) for t in range(2, 80, 2) if t != 40]
    ev.sort()
    return feed(8, ev, 81, "presets under load (tools/preset_check.py)")


def main():
    parts = ["; tables.inc - GENERATED by tables.py, do not edit by hand\n"]
    parts.append(tick_latch())
    parts.append(freq_tables())
    parts.append(sq_tables())

    # --- filter cutoff: exponential index -> 11-bit 8580 register -------------
    # The 8580 cutoff is roughly linear in its register (~30 Hz .. ~12 kHz), but
    # ears (and the 303 knob) are exponential, so index 0..255 spans 40 Hz..12 kHz
    # on a log scale. $D415 holds the low 3 bits, $D416 the high 8 bits.
    regs = []
    for i in range(256):
        hz = geo(40.0, 12000.0, i, 256)
        regs.append(max(0, min(2047, round((hz - 30.0) * 2047 / 12000.0))))
    parts.append(table("cutoff_lo", [r & 7 for r in regs],
                       "filter cutoff register bits 0-2 ($D415) per log-cutoff index 0..255"))
    parts.append(table("cutoff_hi", [r >> 3 for r in regs],
                       "filter cutoff register bits 3-10 ($D416)"))

    # --- filter envelope decay (DECAY parameter 0..15) ------------------------
    # 303 envelope decay knob runs from about 0.2 s to 2 s; we go a bit wider.
    dec = [k16(geo(0.12, 2.5, i, 16)) for i in range(16)]
    parts.append(table("decay_k_lo", [d & 255 for d in dec],
                       "filter env decay factor per tick (16-bit fraction), low bytes, DECAY 0..15"))
    parts.append(table("decay_k_hi", [d >> 8 for d in dec], "high bytes"))
    acc = k16(0.20)   # accented notes: 303 forces the shortest decay (~200 ms)
    parts.append(f"ACCENT_DECAY_K = ${acc:04x}    ; decay factor used for accented notes (~200 ms)\n")

    # --- amplitude (VCA) decay, AMP DECAY parameter 0..14 (15 = hold) -------
    # A held 303 note fades; time constant 0.15 s .. 4 s.
    amp = [k16(geo(0.15, 4.0, i, 15)) for i in range(15)]
    parts.append(table("amp_decay_k_lo", [d & 255 for d in amp],
                       "amp env decay factor per tick, low bytes, AMP DECAY 0..14"))
    parts.append(table("amp_decay_k_hi", [d >> 8 for d in amp], "high bytes"))

    # --- slide (portamento) speed, SLIDE parameter 0..15 ----------------------
    # The 303 slide is an RC glide in pitch with a ~60 ms time constant.
    parts.append(table("slide_k", [k8(geo(0.010, 0.300, i, 16)) for i in range(16)],
                       "slide approach factor per tick (/256), SLIDE 0..15 = 10 ms .. 300 ms"))

    # --- accent sweep discharge vs resonance ----------------------------------
    # On the 303 the accent capacitor charges up over consecutive accents, more
    # so at high resonance. High resonance => slow discharge => bigger sweep.
    parts.append(table("sweep_down_k", [k8(geo(0.02, 0.40, i, 16)) for i in range(16)],
                       "accent sweep discharge factor per tick (/256), by resonance 0..15"))
    # The 303's resonance pot is a dual pot: its second half puts the accent
    # pulse through an RC filter, so at high resonance the accent sweep also
    # *rises* slowly (the "waaaoow"). 6 ms at resonance 0 (as fast as before,
    # half the gap per tick) .. 60 ms at 15.
    parts.append(table("sweep_up_k", [k8(geo(0.006, 0.060, i, 16)) for i in range(16)],
                       "accent sweep charge factor per tick (/256), by resonance 0..15"))

    # --- body level vs resonance ---------------------------------------------
    # On the 303, turning resonance up thins out the bass; the 8580 doesn't.
    # The unfiltered body triangle (voice 3) carries the low end, so it is
    # turned down with resonance: 0 dB at resonance 0 .. -6 dB at 15.
    parts.append(table("body_res_scale",
                       [min(255, round(256 * 10 ** (-6.0 * r / 15 / 20))) for r in range(16)],
                       "body (voice 3) level factor (/256) by resonance 0..15: 0 .. -6 dB"))

    parts.append(test_pattern())
    parts.append(test_pattern(sweep=True))
    parts.append(learn_pattern())
    parts.append(omni_pattern())
    parts.append(clock_pattern())
    parts.append(seq_tables())
    parts.append(preset_demo())
    parts.append(preset_test())
    parts.append(preset_load())

    with open("tables.inc", "w", newline="\n") as f:
        f.write("\n".join(parts))
    with open("presets.inc", "w", newline="\n") as f:
        f.write(presets_inc())
    print(f"tables.inc, presets.inc written (tick latch {TICK_LATCH})")


if __name__ == "__main__":
    main()
