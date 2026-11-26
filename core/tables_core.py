# core/tables_core.py - table helpers and the tables every core-based synth needs
# Part of the SID synth core shared by SID303 and SID808.
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Helpers for a synth's tables.py, which writes tables.inc (64tass syntax).

A synth's tables.py imports this (sys.path gets the core directory) and puts
core_parts() first in its output; the core's code needs TICK_LATCH and the
sq_lo/sq_hi multiply tables from it. Timing values assume the PAL clock and
the synth tick rate: 250 Hz unless the synth passes its own rate (hz=...),
which must match TICK_HZ in the assembly (core/options.inc; the core checks
TICK_LATCH against it).
"""
import math

PAL_CLOCK = 985248          # PAL C64 CPU clock, Hz
TICK_HZ = 250               # default synth tick rate (CIA1 timer A, core/options.inc)
TICK_LATCH = round(PAL_CLOCK / TICK_HZ) - 1   # CIA counts latch..0 => latch+1 cycles


def latch(hz=TICK_HZ):
    """CIA1 timer A latch for a tick rate of hz."""
    return round(PAL_CLOCK / hz) - 1


def k16(seconds, hz=TICK_HZ):
    """Per-tick exponential decay factor as a 16-bit fraction of 65536 (env_decay)."""
    return round(65536 * (1 - math.exp(-1.0 / (hz * seconds))))


def k8(seconds, hz=TICK_HZ):
    """Per-tick exponential approach factor as an 8-bit fraction of 256."""
    return max(1, min(255, round(256 * (1 - math.exp(-1.0 / (hz * seconds))))))


def geo(lo, hi, i, n):
    """i-th of n values spaced geometrically from lo to hi."""
    return lo * (hi / lo) ** (i / (n - 1))


def table(name, values, comment, per_line=16):
    """A labelled .byte table, per_line values per line, with a comment."""
    out = [f"; {comment}", f"{name}"]
    for i in range(0, len(values), per_line):
        out.append("        .byte " + ",".join(f"${v:02x}" for v in values[i:i + per_line]))
    return "\n".join(out) + "\n"


def tick_latch(hz=TICK_HZ):
    """The TICK_LATCH definition the core's start-up code programs the CIA with."""
    return f"TICK_LATCH = {latch(hz)}     ; CIA1 timer A latch for a {hz} Hz synth tick (PAL)\n"


def freq_tables():
    """SID oscillator frequency per semitone, freq_lo/freq_hi.

    Index 0 = MIDI note 12 (C0) ... index 95 = MIDI note 107 (B7); entry 96 is
    the clamp/interpolation end point (C8 would overflow 16 bits)."""
    freqs = []
    for i in range(97):
        hz = 440.0 * 2 ** ((i + 12 - 69) / 12)
        freqs.append(min(65535, round(hz * 16777216 / PAL_CLOCK)))
    return (table("freq_lo", [f & 255 for f in freqs],
                  "SID frequency, low bytes: index = MIDI note - 12 (97 entries)")
            + "\n" + table("freq_hi", [f >> 8 for f in freqs], "SID frequency, high bytes"))


def sq_tables():
    """Quarter squares floor(n*n/4), n = 0..511, for mul8 (core/math.asm)."""
    sq = [n * n // 4 for n in range(512)]
    return (table("sq_lo", [v & 255 for v in sq], "floor(n^2/4) low bytes, n = 0..511 (mul8)")
            + "\n" + table("sq_hi", [v >> 8 for v in sq], "floor(n^2/4) high bytes"))


# -----------------------------------------------------------------------------
# Step sequencer (core/sequencer.asm): its constants and tables
# -----------------------------------------------------------------------------
BPM_MIN, BPM_MAX = 60, 240
SEQ_STEPS = 16
GATE_LEN = 3                    # a note's gate: GATE_LEN sixths of a step (3 = half, as on a 303)
REAL_TICK_HZ = PAL_CLOCK / (TICK_LATCH + 1)     # 985248 / 3941 = 249.999 Hz

# step flags: bits 0-1 time, bit 2 accent, bit 3 slide
TIME_REST, TIME_NOTE, TIME_TIE = 0, 1, 2
FLAG_ACCENT, FLAG_SLIDE = 4, 8


def step_bytes(step):
    """(note byte, flags byte) of a step: (note, accent, slide), where note
    is a MIDI note, "-" a rest or "=" a tie."""
    note, acc, slide = step
    if note == "-":
        n, t = 0, TIME_REST
    elif note == "=":
        n, t = 0, TIME_TIE
    else:
        n, t = note, TIME_NOTE
    return n, t | (FLAG_ACCENT if acc else 0) | (FLAG_SLIDE if slide else 0)


def pattern_bytes(steps):
    """The 33 bytes of a pattern: 16 notes, 16 flags, the length (the
    steps given; rests after them)."""
    assert 1 <= len(steps) <= SEQ_STEPS
    pairs = [step_bytes(s) for s in steps] + [(0, TIME_REST)] * (SEQ_STEPS - len(steps))
    return [n for n, _ in pairs] + [f for _, f in pairs] + [len(steps)]


def tempo_steps(bpm):
    """Phase increment per tick and ticks per 16th at a tempo."""
    steps_per_s = bpm * 4 / 60
    return round(65536 * steps_per_s / REAL_TICK_HZ), REAL_TICK_HZ / steps_per_s


def seq_tables(patterns, edges=None, shorts=None, song_test=None, gate_len=GATE_LEN):
    """The tables core/sequencer.asm needs: the constants, the tempo tables
    (bpm_inc_lo/hi, bpm_steplen, bpm_gate), the patterns at start
    (default_patterns: a list of step lists), and for the test builds:
    edges (TEST_EDGES=1, a step list over pattern 1), shorts (TEST_EDGES=2,
    two step lists over patterns 1 and 2) and song_test (TEST_SONG:
    (pattern index, repeats, transpose) entries). gate_len: a note's gate
    in sixths of a step."""
    consts = [("BPM_MIN", BPM_MIN), ("BPM_MAX", BPM_MAX), ("SEQ_STEPS", SEQ_STEPS),
              ("GATE_LEN", gate_len), ("TIME_REST", TIME_REST), ("TIME_NOTE", TIME_NOTE),
              ("TIME_TIE", TIME_TIE), ("FLAG_ACCENT", FLAG_ACCENT), ("FLAG_SLIDE", FLAG_SLIDE)]
    out = ["".join(f"{name} = {value}\n" for name, value in consts)]
    inc, steplen, gate = [], [], []
    for bpm in range(BPM_MIN, BPM_MAX + 1):
        i, ticks = tempo_steps(bpm)
        inc.append(i)
        steplen.append(round(ticks))
        gate.append(max(1, round(ticks * gate_len / 6)))
    assert max(inc) < 65536 and max(steplen) < 256
    out.append(table("bpm_inc_lo", [v & 255 for v in inc],
                     "step phase increment per tick (x/65536 of a 16th), low bytes; index BPM - BPM_MIN"))
    out.append(table("bpm_inc_hi", [v >> 8 for v in inc], "... high bytes"))
    out.append(table("bpm_steplen", steplen, "ticks per 16th (the swing delay); index BPM - BPM_MIN"))
    out.append(table("bpm_gate", gate, "ticks a note's gate stays open (GATE_LEN sixths of a step)"))
    data = []
    for p in patterns:
        data += pattern_bytes(p)
    out.append(f"DEFAULT_PATTERNS = {len(patterns)}\n")
    out.append(table("default_patterns", data, "the patterns at start: 16 notes, 16 flags, length each"))
    if edges or shorts:
        text = ""
        if edges:
            text += ".if TEST_EDGES == 1\n" + table("edges_pattern", pattern_bytes(edges),
                                                    "TEST_EDGES=1: the playing rules' awkward cases")
        if shorts:
            text += (".elsif" if edges else ".if") + " TEST_EDGES == 2\n"
            text += table("edges_pattern", pattern_bytes(shorts[0]) + pattern_bytes(shorts[1]),
                          f"TEST_EDGES=2: patterns 1 and 2, lengths {len(shorts[0])} and {len(shorts[1])}")
        out.append(text + ".endif\n")
    if song_test:
        out.append(".if TEST_SONG\n" + f"TEST_SONG_LEN = {len(song_test)}\n"
                   + table("test_song_pat", [p for p, _, _ in song_test], "TEST_SONG: the song's patterns")
                   + table("test_song_rep", [r for _, r, _ in song_test], "... repeats")
                   + table("test_song_tr", [t & 255 for _, _, t in song_test], "... transposes")
                   + ".endif\n")
    return "".join(out)
