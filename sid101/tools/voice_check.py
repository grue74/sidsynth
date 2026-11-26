#!/usr/bin/env python3
# tools/voice_check.py - check SID101's voice in VICE
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Runs the demo patterns (TEST_MIDI=1, 2, 3, 17, 19) in VICE and checks, for each:

1. lag: a TEST_LOG build logs every note on/off and the most ticks ever
   left waiting (LOG_LAG); at most 1 (the engine keeps up with its tick).
   The note log must hold the demo's notes in order, at their ticks.
2. the SID writes (headless VICE's sound dump):
   - voice 3 (the sub) plays voice 1's frequency an octave or two down;
   - a voice's sustain level never rises while its gate stays open (the
     SID wouldn't follow: it decays a voice whose sustain is raised);
   - every voice's attack, decay and release rates stay 0 (no ADSR bug);
   - while voice 2 is synced to voice 1 (Sync mode), its frequency is
     never below voice 1's (the synced voice sounds at or above the note).
3. accent: voice 1's level at each fresh note (its gate opening) is the
   model's, the Saw level (C64 mode: Pulse) x the note's accent level
   (tables.accent_tables), with the parameters replayed from the demo's
   controllers.
4. C64 mode (demos 17, 19): voice 2 is voice 1 ECHO_LEN ticks later: every
   frequency voice 2 gets is voice 1's of then, every gate opening of
   voice 2 (with Saw above 0) follows one of voice 1's.
5. chords (demo 19): voice 1's note tick by tick follows chord_model, a
   replay of the demo through the chord code's rules (chord_build).

Usage: python tools/voice_check.py
"""

import bisect
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
HEADLESS = os.path.join(C64TOOLS, "vice-headless", "x64.exe")
sys.path.insert(0, ROOT)
import tables  # noqa: E402  (the demo's events)

NOTE_LOG, NOTE_LOG_END = 0x6800, 0x7000
LOG_LAG = NOTE_LOG - 1
LOG_LAG_AT = NOTE_LOG - 3                # (word) the tick of the worst lag
TICK_MAX = NOTE_LOG - 4                  # the longest synth_tick, x 256 cycles
CYCLES_PER_TICK = tables.TICK_LATCH + 1


def build(out, defines):
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg"]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-o", out, "sid101.asm"], cwd=ROOT, check=True)


def run_log(prg, seconds):
    """Run prg in VICE (warp) and return (LOG_LAG, its tick, [(tick, note, velocity)])."""
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg,
                          f"m {TICK_MAX:04x} {NOTE_LOG_END - 1:04x}", "--seconds", str(seconds)],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            data += bytes(int(b, 16) for b in m.group(2).split())
    print(f"  longest synth_tick: about {data[0] * 256} cycles (a tick is {CYCLES_PER_TICK})")
    lag_at, lag, data = data[1] | data[2] << 8, data[3], data[4:]
    log = []
    for i in range(0, len(data) - 3, 4):
        tick = data[i] | data[i + 1] << 8
        if tick == 0:                   # the cleared area: the log ends
            break
        log.append((tick, data[i + 2], data[i + 3]))
    return lag, lag_at, log


def run_dump(prg, cycles):
    """[(cycle, register, value)] of every SID write in a headless run. The
    headless VICE now and then leaves an empty dump: then it runs again."""
    for _ in range(3):
        writes = run_dump_once(prg, cycles)
        if writes:
            return writes
    return writes


def run_dump_once(prg, cycles):
    with tempfile.TemporaryDirectory() as tmp:
        with open(prg, "rb") as src, open(os.path.join(tmp, "t.prg"), "wb") as dst:
            dst.write(src.read())
        subprocess.run([HEADLESS, "-default", "-warp", "-soundwarpmode", "0", "-drive8type", "0",
                        "-sounddev", "dump", "-soundarg", "dump.txt", "-limitcycles", str(cycles),
                        "-autostartprgmode", "1", "-autostart", "t.prg"],
                       cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        writes, cycle = [], 0
        with open(os.path.join(tmp, "dump.txt")) as f:
            for line in f:
                delta, reg, value = (int(v) for v in line.split())
                cycle += delta
                writes.append((cycle, reg, value))
    return writes


def check_log(n, lag, lag_at, log):
    """The note log against the demo's note events, as times from the first."""
    events, end = tables.demo_events(n)
    want = sorted((t, o, m[1], m[2]) for t, o, m in events if m[0] == 0x90)
    want = [(t, n, v) for t, _, n, v in want]
    if n == 19:                         # up to its arpeggiator part (the log has its notes too)
        stop = tables.H2_LEAD_IN + tables.H2_PARTS["arp"] * tables.BAR
        want = [e for e in want if e[0] < stop]
    got = log[:len(want)]
    t0 = got[0][0] if got else 0
    got = [(t - t0, n, v) for t, n, v in got]
    w0 = want[0][0] if want else 0
    want = [(t - w0, n, v) for t, n, v in want]
    # the feed is ahead of the note by up to a tick: compare the order and
    # the times within one tick
    ok_notes = [(n, v) for _, n, v in got] == [(n, v) for _, n, v in want]
    ok_times = all(abs(g[0] - w[0]) <= 1 for g, w in zip(got, want))
    good = lag <= 1 and ok_notes and ok_times and len(got) == len(want)
    print(f"{'PASS' if good else 'FAIL'} log: {len(got)} of {len(want)} note events in order "
          f"({'same' if ok_notes else 'DIFFERENT'} notes, times {'within a tick' if ok_times else 'OFF'}), "
          f"lag at most {lag} tick(s) (worst first at tick {lag_at}, "
          f"{lag_at - log[0][0] if log else 0} after the first note)")
    return good


def expected_starts(n):
    """Voice 1's level at each fresh note of demo n, from a replay of its
    controllers (as the core's midi_cc scales them) and notes."""
    events, _ = tables.demo_events(n)
    events.sort(key=lambda e: (e[0], e[1]))
    by_cc = {cc: name for name, cc in tables.CC.items()}
    p = {"SAW": 15, "PULSE": 0, "ACCENT": 0, "VOICEMODE": 0}  # the defaults (src/params.asm)
    acc_level, _ = tables.accent_tables()
    level = tables.level_tab()
    held, out = set(), []
    for _, _, m in events:
        if m[0] == 0xB0:
            name, v = by_cc[m[1]], m[2] * 2 + (m[2] >> 6)
            top = tables.MAX[name]
            p[name] = v if top == 255 else v * (top + 1) >> 8
        elif m[2]:
            mix = p["PULSE"] if p["VOICEMODE"] == 2 else p["SAW"]  # (C64 mode: the pulse lead)
            if not held and mix:                # (level 0: voice 1 runs ungated)
                out.append(level[mix * 16 + acc_level[p["ACCENT"] * 16 + (m[2] >> 3)]])
            held.add(m[1])
        else:
            held.discard(m[1])
    return out


def gate_starts(writes):
    """Voice 1's sustain level at each retrigger: its gate opening straight
    after the three voices' levels were written (voices_retrigger; C64 mode:
    voices 1 and 3, voice 2 is the echo's), not when
    a mix level turned up from 0 opens it (gates_write alone)."""
    regs, gate, out, last = [0] * 32, 0, [], []
    for _, reg, value in writes:
        regs[reg] = value
        if reg == 4:
            if value & 1 and not gate and (last[-3:] == [6, 13, 20] or last[-2:] == [6, 20]):
                out.append(regs[6] >> 4)
            gate = value & 1
        last.append(reg)
    return out


def check_accent(n, writes):
    want = expected_starts(n)
    got = gate_starts(writes)[:len(want)]       # (the demo loops: the first time round)
    bad = sum(g != w for g, w in zip(got, want)) + len(want) - len(got)
    print(f"{'PASS' if bad == 0 else 'FAIL'} accent: voice 1's level at {len(got)} of {len(want)} "
          f"fresh notes, {bad} unlike the model (levels {sorted(set(want))})")
    return bad == 0


def check_dump(writes):
    regs = [0] * 32
    gate = [0, 0, 0]
    level = [0, 0, 0]
    sub_bad = rise_bad = rate_bad = 0
    sub_checks = rises = 0
    sync_checks = sync_bad = 0
    for cycle, reg, value in writes:
        regs[reg] = value
        voice, off = divmod(reg, 7) if reg < 21 else (None, None)
        if voice is None:
            continue
        if off == 4:                    # control: a gate opening starts a note
            g = value & 1
            if g and not gate[voice]:
                level[voice] = regs[voice * 7 + 6] >> 4
            gate[voice] = g
        elif off == 6:                  # sustain/release
            if value & 0x0f:
                rate_bad += 1
            new = value >> 4
            if gate[voice]:
                rises += 1
                if new > level[voice]:
                    rise_bad += 1
            level[voice] = new
        elif off == 5 and value:        # attack/decay must stay 0
            rate_bad += 1
        elif reg == 15:                 # voice 3 frequency high byte: compare with voice 1
            v1 = regs[0] | regs[1] << 8
            v3 = regs[14] | regs[15] << 8
            sub_checks += 1
            if v3 not in (v1 >> 1, v1 >> 2):
                sub_bad += 1
        # voice 2's frequency written (high byte, after the low; sync_update runs
        # after pitch_to_sid, so voice 1 is up to date too), voice 2 synced
        if reg == 8 and regs[11] & 2:
            sync_checks += 1
            if (regs[7] | regs[8] << 8) < (regs[0] | regs[1] << 8):
                sync_bad += 1
    good = sub_bad == 0 and rise_bad == 0 and rate_bad == 0 and sub_checks > 500 and sync_bad == 0
    print(f"{'PASS' if good else 'FAIL'} SID writes: sub frequency {sub_checks - sub_bad}/{sub_checks} right, "
          f"{rise_bad} sustain rises in {rises} level writes with the gate open, "
          f"{rate_bad} nonzero ADSR rates, synced voice below voice 1 {sync_bad} times in {sync_checks}")
    return good


ECHO_LEN = 32                            # src/engine.asm: the echo's delay, ticks


def value_at(series, cycle):
    """The last value of [(cycle, value)] written at or before cycle, or None."""
    i = bisect.bisect_right(series, (cycle, 1 << 20))
    return series[i - 1][1] if i else None


def check_echo(writes):
    """C64 mode: voice 2's frequencies and gate openings are voice 1's, ECHO_LEN
    ticks (within a tick) before."""
    tick = CYCLES_PER_TICK
    regs = [0] * 32
    v1_freq, v1_opens = [], []                  # (cycle, value)
    gate1 = gate2 = 0
    freq_n = freq_bad = open_n = open_bad = level_opens = last11 = 0
    for cycle, reg, value in writes:
        regs[reg] = value
        if reg == 1:
            v1_freq.append((cycle, regs[0] | regs[1] << 8))
        elif reg == 4:
            if value & 1 and not gate1:
                v1_opens.append(cycle)
            gate1 = value & 1
        elif reg == 8 and not regs[11] & 2:     # voice 2's frequency, not synced: the echo's
            # the ticks run up to one late (lag 1): voice 1's values from
            # ECHO_LEN - 1 to ECHO_LEN + 1 ticks before; none before the
            # ring was filled once (its slots start ungated, any frequency)
            f = regs[7] | regs[8] << 8
            lo, hi = cycle - (ECHO_LEN + 1.5) * tick, cycle - (ECHO_LEN - 1.5) * tick
            then = {value_at(v1_freq, lo)} | {v for c, v in v1_freq if lo <= c <= hi}
            if v1_freq and lo > v1_freq[0][0]:
                freq_n += 1
                freq_bad += f not in then
        elif reg == 11:
            # a retrigger (its gate off and on in the same tick) follows one
            # of voice 1's; an opening without one is Saw turned up from 0
            # with voice 1 held then (as gates_write opens a voice)
            if value & 1 and not gate2:
                if cycle - last11 < tick // 2:
                    open_n += 1
                    open_bad += not any(cycle - (ECHO_LEN + 1.5) * tick <= c <= cycle - (ECHO_LEN - 1.5) * tick
                                        for c in v1_opens)
                else:
                    level_opens += 1
            gate2 = value & 1
            last11 = cycle
    good = freq_n > 100 and freq_bad == 0 and open_n > 10 and open_bad == 0
    print(f"{'PASS' if good else 'FAIL'} echo: voice 2's frequency {freq_n - freq_bad}/{freq_n} voice 1's "
          f"{ECHO_LEN} ticks before, {open_n - open_bad}/{open_n} retriggers after one of voice 1's "
          f"({level_opens} openings by Saw turned up)")
    return good


def chord_model(n):
    """The sounding note at each tick of demo n (C64 mode's chords), from a
    replay of its events through src/engine.asm's chord_build and
    c64_update: [(tick, note)] from its first note on to its arpeggiator
    part (tables.H2_PARTS["arp"]: the arpeggiator's own timing isn't
    modelled). Glide off, no vibrato or bend in the parts compared."""
    events, _ = tables.demo_events(n)
    events.sort(key=lambda e: (e[0], e[1]))
    by_cc = {cc: name for name, cc in tables.CC.items()}
    p = {"CHORD": 0, "CHORDSPEED": 0, "VOICEMODE": 0}
    shapes = ((0, 4, 7), (0, 3, 7), (0, 4, 7, 10), (0, 3, 7, 10), (0, 4, 7, 11), (0, 5, 7),
              (0, 7), (0, 12), (0, 3, 6))
    held, chord = [], {"offs": [], "pos": 0, "now": 0, "wait": 0}
    base = None
    stop = tables.H2_LEAD_IN + tables.H2_PARTS["arp"] * tables.BAR

    def build():
        if p["VOICEMODE"] != 2 or p["CHORD"] == 0:
            chord["offs"] = []
        elif not held:
            return
        elif len(held) >= 2:
            srt = sorted(held)
            i = srt.index(held[-1])
            chord["offs"] = [srt[(i + k) % len(srt)] - held[-1] for k in range(len(srt))]
        elif p["CHORD"] >= 2:
            chord["offs"] = list(shapes[p["CHORD"] - 2])
        else:
            chord["offs"] = []
        chord.update(pos=0, now=0, wait=(p["CHORDSPEED"] + 1) * 5)

    out, i, t = [], 0, events[0][0]
    while t < stop:
        while i < len(events) and events[i][0] <= t:
            m = events[i][2]
            if m[0] == 0xB0:
                name, v = by_cc[m[1]], m[2] * 2 + (m[2] >> 6)
                top = tables.MAX[name]
                p[name] = v if top == 255 else v * (top + 1) >> 8
                if name in ("CHORD", "VOICEMODE"):
                    build()
            elif m[2]:
                if m[1] in held:
                    held.remove(m[1])
                held.append(m[1])
                base = m[1]
                build()
            elif m[1] in held:
                top = held[-1] == m[1]
                held.remove(m[1])
                if held:
                    if top:
                        base = held[-1]
                    build()
            i += 1
        t += 1
        if base is not None:
            out.append((t, base + chord["now"]))
        if chord["offs"]:
            chord["wait"] -= 1
            if chord["wait"] == 0:
                chord["pos"] = (chord["pos"] + 1) % len(chord["offs"])
                chord.update(now=chord["offs"][chord["pos"]], wait=(p["CHORDSPEED"] + 1) * 5)
    return out


def runs(seq):
    """[(value, count)] of a sequence's runs."""
    out = []
    for v in seq:
        if out and out[-1][0] == v:
            out[-1][1] += 1
        else:
            out.append([v, 1])
    return out


def check_chords(n, writes):
    """C64 mode's chords: voice 1's note, tick by tick, against chord_model
    (the notes in order exactly; each run's length within a tick: the
    ticks against the feed's events, as check_log)."""
    tick = CYCLES_PER_TICK
    freqs = [(f_lo | f_hi << 8) for f_lo, f_hi in zip(*tables_freq())]
    v1, regs, first_open, gate = [], [0] * 32, None, 0
    for cycle, reg, value in writes:
        regs[reg] = value
        if reg == 1:
            v1.append((cycle, regs[0] | regs[1] << 8))
        elif reg == 4:
            if value & 1 and not gate and first_open is None:
                first_open = cycle
            gate = value & 1
    want = chord_model(n)
    t0 = want[0][0]
    got = []
    for t, _ in want:
        f = value_at(v1, first_open + (t - t0 + 0.5) * tick)
        got.append(min(range(len(freqs)), key=lambda i: abs(freqs[i] - f)) + 12 if f else None)
    while got and got[0] is None:       # (the gate opens a moment before the pitch is written)
        got.pop(0)
    w, g = runs([nt for _, nt in want]), runs(got)
    same_notes = [v for v, _ in w] == [v for v, _ in g]
    worst = max((abs(a[1] - b[1]) for a, b in zip(w[1:-1], g[1:-1])), default=0) if same_notes else None
    good = same_notes and worst is not None and worst <= 1 and len(w) > 100
    print(f"{'PASS' if good else 'FAIL'} chords: {len(g)} runs of voice 1's note against the model's "
          f"{len(w)} ({'the same notes' if same_notes else 'DIFFERENT notes'}, run lengths within "
          f"{worst} tick(s))")
    if not same_notes:
        for k, (a, b) in enumerate(zip(w, g)):
            if a[0] != b[0]:
                print(f"     first difference at run {k}: model {w[k - 2:k + 3]}, voice 1 {g[k - 2:k + 3]}")
                break
    return good


def tables_freq():
    """freq_lo, freq_hi as lists (core/tables_core.py's formula)."""
    lo, hi = [], []
    for i in range(97):
        hz = 440.0 * 2 ** ((i + 12 - 69) / 12)
        f = min(65535, round(hz * 16777216 / 985248))
        lo.append(f & 255)
        hi.append(f >> 8)
    return lo, hi


def main():
    good = True
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)    # tables.inc from the demos checked here
    with tempfile.TemporaryDirectory() as tmp:
        for n in tables.DEMOS:
            _, end = tables.demo_events(n)
            seconds = end / tables.TICK_HZ + 3
            print(f"demo {n} ({tables.DEMOS[n].__doc__.split(',')[0]}):")
            prg = os.path.join(tmp, f"log{n}.prg")
            build(prg, [f"TEST_MIDI={n}", "TEST_LOG=1"])
            lag, lag_at, log = run_log(prg, seconds + 1)
            good &= check_log(n, lag, lag_at, log)
            prg = os.path.join(tmp, f"demo{n}.prg")
            build(prg, [f"TEST_MIDI={n}"])
            writes = run_dump(prg, int(seconds * 985248))
            good &= check_dump(writes)
            good &= check_accent(n, writes)
            if n in (17, 19):
                good &= check_echo(writes)
            if n == 19:
                good &= check_chords(n, writes)
    print("ALL PASS" if good else "FAILED")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
