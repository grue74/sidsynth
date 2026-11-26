# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the step sequencer's playing in VICE (docs/sequencer.md, Checks).

    python tools/seq_check.py [--keep DIR]

Builds TEST_LOG test programs with 64tass, runs each in headless VICE
(c64tools/vicepeek.py) and reads the note log (every note_on / note_off with
its tick, sid101.asm TEST_LOG) from memory. Then:

1. bass: the sequencer plays pattern 1 (tables.py BASS_LINE). Its log must
   equal model() note for note and tick for tick.
2. edges: the same with tables.py EDGES, the playing rules' awkward cases
   (same-pitch slide, ties, a slide into a rest, a slide across the
   pattern's end). The expected notes are also printed with what they show.
   Then lengths and the next pattern (TEST_EDGES=2): a 6-step pattern
   once, sliding into a 5-step one that loops, starting with a tie.
   Then swing 8: pattern 1 with the off-beats late by a quarter step. And
   RUN/STOP on the step screen (TEST_KEYS=5): notes play, none stays on.
3. feed: pattern 1 against the same line fed through the MIDI parser
   (TEST_MIDI=4): over the first four bars the note-ons must come at the
   same ticks (within one: the tempo phase vs the feed's whole ticks), with
   the same notes and velocities, and the same notes slid into (on while
   another is still on). The note-offs differ by design (the feed's gate is
   6/10 of a step, the sequencer's GATE_LEN/6).
4. tempo: at 60, 120 and 240 BPM the note-ons come at the model's ticks
   for 16 bars (the phase arithmetic, no jitter or slips; 30 bars until
   the note log shrank to 512 entries for the C64 lead mode's code). The real tempo is
   printed: the phase increment per tick is a whole number, so a tempo is
   off by up to 0.5 / increment (0.05 % at 60 BPM, a few ms over a minute).

5. load: pattern 3 on the step screen with the heaviest sound (TEST_MIDI=7)
   plays its notes.
6. lag: no run that plays had more than one tick waiting when a tick ran
   (LOG_LAG); the editing runs (which never play) at most two: an undo of
   a song edit swaps 193 bytes, ~1.6 ticks. The logged ticks are ticks
   run, so ticks falling behind the timer would not show in the logs.

Exit status 0 when every check passes.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, ROOT)
import tables  # noqa: E402  (pattern data, tempo tables)

NOTE_LOG, NOTE_LOG_END = 0x6800, 0x7000
LOG_LAG = NOTE_LOG - 1                  # the most ticks ever left waiting (src/notes.asm)
lags = {}                               # program name -> its LOG_LAG


def build(out, defines):
    """Assemble sid101.asm with -D options into out (labels into out.lbl)."""
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1"]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", out + ".lbl", "-o", out, "sid101.asm"], cwd=ROOT, check=True)


def labels(prg):
    """The program's labels: name -> address (64tass -l)."""
    out = {}
    with open(prg + ".lbl") as f:
        for line in f:
            m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
            if m:                       # ($hex for addresses, decimal for computed ones)
                v = m.group(2)
                out[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return out


def run_mems(img, seconds, ranges, jiffy=False):
    """Run img in VICE once (with JiffyDOS: jiffy) and return {address:
    byte} for the ranges [(start, end inclusive)]."""
    cmds = [f"m {lo:04x} {hi:04x}" for lo, hi in ranges]
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), img, *cmds,
                          "--seconds", str(seconds)] + (["--jiffy"] if jiffy else []),
                         capture_output=True, text=True, check=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            addr = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                mem[addr + i] = int(b, 16)
    return mem


def run_mem(prg, seconds, start, end):
    """Run prg in VICE and return memory start..end (inclusive) as bytes."""
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg,
                          f"m {start:04x} {end:04x}", "--seconds", str(seconds)],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            data += bytes(int(b, 16) for b in m.group(2).split())
    return bytes(data[:end - start + 1])


def run_log(prg, seconds):
    """Run prg in VICE for about `seconds` of real time (warp) and return
    the note log: [(tick, note, velocity)], velocity 0 = note off. The
    program's LOG_LAG goes into lags."""
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg,
                          f"m {LOG_LAG:04x} {NOTE_LOG_END - 1:04x}", "--seconds", str(seconds)],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            data += bytes(int(b, 16) for b in m.group(2).split())
    lags[os.path.basename(prg)] = data[0]
    data = data[1:]
    log = []
    for i in range(0, len(data) - 3, 4):
        tick = data[i] | data[i + 1] << 8
        if tick == 0:                   # the cleared area: the log ends
            break
        log.append((tick, data[i + 2], data[i + 3]))
    return log


OUT_LOG_END = 0xf000  # (src/notes.asm; OUT_LOG from the label file)


def run_out(prg, seconds):
    """Run prg in VICE and return its MIDI out log (src/notes.asm OUT_LOG):
    [(tick, byte)], every byte the sequencer queued with its tick."""
    data = run_mem(prg, seconds, labels(prg)["OUT_LOG"], OUT_LOG_END - 1)
    out = []
    for i in range(0, len(data) - 3, 4):
        tick, b = data[i] | data[i + 1] << 8, data[i + 2]
        if tick == 0 and b == 0:        # the cleared area: the log ends
            break
        out.append((tick, b))
    return out


def model(steps, bpm, ticks, gate_len=tables.GATE_LEN, swing=0, then=None, song=None,
          feed=None, out=None, switch=None, locate=None):
    """What core/sequencer.asm should log playing steps (tables.py tuples,
    one per step of the pattern's length) from tick 0, for `ticks` ticks:
    [(tick, note, vel)]. The pattern loops; with `then`, it plays once and
    then `then` loops (seq_next). With `song`, a list of (steps, repeats,
    transpose) entries, the song plays instead, in a loop; its notes are
    transposed and folded by octaves into MIDI 12..107 (transpose_note).
    Written from the rules in docs/sequencer.md, tick by tick as seq_tick
    runs: the gate countdown, then play's step 0, a swung step waiting,
    the phase. Swing delays odd steps by steplen * swing * 8 / 256 ticks
    (swing_set), steplen rounded from the tempo.

    feed: MIDI clock in instead of the tempo (the Clock parameter on MIDI):
    [(tick, [bytes])], realtime bytes handled before tick+1's seq_tick, as
    the main loop parses them after the tick they were fed in; play starts
    with the Start byte. The gate closes GATE_LEN clocks after the step
    fired; swing comes from the ticks between the steps.
    out: a list that gets the MIDI out bytes, [(tick, byte)]: notes (note
    on $90, note off $80 0, channel 1) and, with the internal clock, start,
    6 clocks a step (the first with step 1), stop.

    switch: [(tick, steps)]: the pattern controller (core seq_pattern) at
    that tick: song mode goes off; the pattern playing ends its pass (no
    more song repeats) and `steps` loops untransposed; stopped, play starts
    with it. locate: [(tick, position)]: a song position (MIDI clock,
    stopped; core seq_song_position): the step `position` steps into the
    song's passes (wrapping at their total) or into the pattern (modulo its
    length); the next continue ($FB) plays from it, its first clock firing
    the step; start forgets it."""
    inc, steplen = tables.tempo_steps(bpm)
    gate_ticks = max(1, round(steplen * gate_len / 6))
    swing_ticks = round(steplen) * swing * 8 >> 8
    # the passes in playing order: (pattern bytes, transpose), and where the loop starts
    if song:
        passes = [([tables.step_bytes(s) for s in st], tr) for st, rep, tr in song for _ in range(rep)]
        loop_from = 0
    else:
        passes = [([tables.step_bytes(s) for s in steps], 0)]
        loop_from = 0
        if then:
            passes.append(([tables.step_bytes(s) for s in then], 0))
            loop_from = 1
    st = dict(pi=0, step=0, phase=0, out_phase=0, note=None, held=False, gate=0,
              gate_clocks=0, swing_wait=0, swing_ticks=swing_ticks, play=feed is None,
              start=feed is None, clock_wait=0, clock_count=0, clock_due=0, clock_ticks=0)
    log = []
    sent = out if out is not None else []
    bytes_at = {}
    for t, b in (feed or []):
        bytes_at.setdefault(t + 1, []).extend(b)

    if out is not None and feed is None:
        sent.append((-1, 0xFA))         # play (TEST_SEQ at start): before the first tick

    def send(t, *bs):
        if out is not None and (feed is None or bs[0] < 0xF8):  # MIDI clock in: no clock out
            sent.extend((t, b) for b in bs)

    override = {}                       # "to": the pass the pattern controller queued
    cycle = len(passes)                 # the song's (or pattern's) passes, before any switch
    switch_at = {}
    for t, s in (switch or []):
        switch_at.setdefault(t, []).append(s)
    locate_at = dict(locate or [])

    def next_pass(i):
        if "to" in override:
            return override["to"]
        return i + 1 if i + 1 < len(passes) else loop_from

    def do_switch(s):
        passes.append(([tables.step_bytes(x) for x in s], 0))
        override["to"] = len(passes) - 1

    def do_locate(pos):
        if not feed or st["play"]:
            return                      # internal clock, or playing: ignored
        if song:
            lens = [len(passes[i][0]) for i in range(cycle)]
            p = pos % sum(lens)
            for i, n in enumerate(lens):
                if p < n:
                    st["located"] = (i, p)
                    return
                p -= n
        else:
            i = override.get("to", 0)
            st["located"] = (i, pos % len(passes[i][0]))

    def fold(n):
        while n < 12:
            n += 12
        while n > 107:
            n -= 12
        return n

    def release(t):
        if st["note"] is not None:
            log.append((t, st["note"], 0))
            send(t, 0x80, st["note"], 0)
        st.update(note=None, held=False, gate=0, gate_clocks=0)

    def fire(t):
        if st["gate"] or st["gate_clocks"]:
            release(t)
        pat, tr = passes[st["pi"]]
        step = st["step"]
        n, flags = pat[step]
        n = fold(n + tr)
        time = flags & 3
        if time == tables.TIME_REST:
            release(t)
            return
        note = st["note"]
        if time == tables.TIME_TIE:
            if note is None:
                return
        else:
            vel = 127 if flags & tables.FLAG_ACCENT else 100
            if note is not None and st["held"] and n != note:
                log.append((t, n, vel))         # slide: new on, old off
                send(t, 0x90, n, vel)
                log.append((t, note, 0))
                send(t, 0x80, note, 0)
                st["note"] = n
            elif note is not None and st["held"]:
                pass                            # same pitch: a tie
            else:
                release(t)                      # (a tied note ends first)
                log.append((t, n, vel))
                send(t, 0x90, n, vel)
                st["note"] = n
        # gate plan
        st["held"] = bool(flags & tables.FLAG_SLIDE)
        after = (pat[step + 1] if step + 1 < len(pat) else passes[next_pass(st["pi"])][0][0])[1] & 3
        goes_on = st["held"] or after == tables.TIME_TIE
        st["gate"] = 0 if goes_on or feed else gate_ticks
        st["gate_clocks"] = 0 if goes_on or not feed else gate_len

    def step_due(t):
        st["step"] += 1
        if st["step"] >= len(passes[st["pi"]][0]):
            st["pi"], st["step"] = next_pass(st["pi"]), 0
        if st["step"] % 2 and st["swing_ticks"]:
            st["swing_wait"] = st["swing_ticks"]
        else:
            fire(t)

    def toggle(t):
        if st["play"]:
            st.update(play=False, start=False, swing_wait=0)
            release(t)
            send(t, 0xFC)
        else:
            send(t, 0xFA)
            st.update(pi=override.get("to", 0), step=0, phase=0, out_phase=0, swing_wait=0,
                      start=True, play=True)

    def realtime(t, b):
        # t is the tick whose seq_tick comes next; the main loop parsed the
        # byte after the tick before (t - 1), and a note it releases (stop)
        # is logged with that tick
        if b == 0xF8:
            if not st["play"]:
                return
            if st["gate_clocks"]:
                st["gate_clocks"] -= 1
                if st["gate_clocks"] == 0:
                    st["gate"] = 1
            if st["clock_wait"]:
                st.update(clock_wait=0, clock_count=0, start=True)
                return
            st["clock_count"] += 1
            if st["clock_count"] >= 6:
                st["clock_count"] = 0
                st["clock_due"] += 1
        elif b == 0xFA:
            st["located"] = None
            if st["play"]:
                toggle(t - 1)
            toggle(t - 1)
            st.update(start=False, clock_due=0, clock_count=0, clock_wait=1)
        elif b == 0xFB:
            if not st["play"] and st["located"]:
                pi, step = st["located"]
                st.update(located=None, pi=pi, step=step, play=True, clock_wait=1, clock_due=0,
                          clock_count=0, swing_wait=0, start=False)
            elif not st["play"]:
                st.update(clock_due=0, play=True)
        elif b == 0xFC:
            if st["play"]:
                toggle(t - 1)

    st["located"] = None
    for t in range(ticks):
        for s in switch_at.get(t, []):
            do_switch(s)
        if t in locate_at:
            do_locate(locate_at[t])
        for b in bytes_at.get(t, []):
            realtime(t, b)
        if not st["play"]:
            continue
        if st["gate"]:
            st["gate"] -= 1
            if st["gate"] == 0:
                release(t)
        if st["start"]:
            st.update(start=False, clock_ticks=0)
            send(t, 0xF8)
            fire(t)
            continue
        if st["swing_wait"]:
            st["swing_wait"] -= 1
            if st["swing_wait"] == 0:
                fire(t)
        if feed:
            st["clock_ticks"] = min(255, st["clock_ticks"] + 1)
            if st["clock_due"]:
                st["clock_due"] -= 1
                st["swing_ticks"] = st["clock_ticks"] * swing * 8 >> 8
                st["clock_ticks"] = 0
                step_due(t)
            continue
        st["out_phase"] += 6 * inc
        if st["out_phase"] >= 65536:
            st["out_phase"] -= 65536
            send(t, 0xF8)
        st["phase"] += inc
        if st["phase"] >= 65536:
            st["phase"] -= 65536
            step_due(t)
    return log


def relative(log):
    t0 = log[0][0]
    return [(t - t0, n, v) for t, n, v in log]


def name(n):
    return "C-C#D-D#E-F-F#G-G#A-A#B-"[n % 12 * 2:n % 12 * 2 + 2] + str(n // 12 - 1)


def show(log, limit=40):
    for t, n, v in log[:limit]:
        print(f"    {t:5d}  {name(n)}  {'off' if v == 0 else f'on {v}'}")


def compare(label, got, want):
    """Pass if the logs are equal over the model's length."""
    got = relative(got)[:len(want)]
    if got == want:
        print(f"PASS {label}: {len(want)} events equal the model")
        return True
    print(f"FAIL {label}")
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            print(f"  first difference at event {i}: got {g}, want {w}")
            break
    else:
        print(f"  got {len(got)} events, want {len(want)}")
    return False


def note_ons(log):
    """[(tick, note, vel, slid)]: note-ons, slid = another note still on."""
    on, out = set(), []
    for t, n, v in log:
        if v:
            out.append((t, n, v, bool(on)))
            on.add(n)
        else:
            on.discard(n)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder (default: a temporary one)")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="seqcheck")
    os.makedirs(work, exist_ok=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    ok = True
    bar_ticks = 4 * 16 * 31                 # four bars and a bit at 125 BPM

    # 1. pattern 1 against the model
    prg = os.path.join(work, "acid.prg")
    build(prg, ["TEST_SEQ=1"])
    acid = run_log(prg, 6)
    ok &= compare("bass (pattern 1, 125 BPM)", acid, model(tables.BASS_LINE, 125, bar_ticks))

    # 2. the awkward cases
    prg = os.path.join(work, "edges.prg")
    build(prg, ["TEST_SEQ=1", "TEST_EDGES=1"])
    edges = run_log(prg, 6)
    want = model(tables.EDGES, 125, bar_ticks)
    ok &= compare("edges (tables.py EDGES, 125 BPM)", edges, want)
    print("  expected, first bar and the wrap (tick, note, on/off):")
    show([e for e in want if e[0] < 16 * 30 + 20])

    # 2a. lengths and the next pattern: SHORT1 once, then SHORT2 looping
    prg = os.path.join(work, "short.prg")
    build(prg, ["TEST_SEQ=1", "TEST_EDGES=2", "TEST_SEQ_NEXT=1"])
    want = model(tables.SHORT1, 125, bar_ticks, then=tables.SHORT2)
    ok &= compare("short (lengths 6 then 5, 125 BPM)", run_log(prg, 6), want)
    print("  expected, the first 14 steps (tick, note, on/off):")
    show([e for e in want if e[0] < 14 * 30])

    # 2b. swing: the off-beats late by swing / 32 of a step
    prg = os.path.join(work, "swing.prg")
    build(prg, ["TEST_SEQ=1", "SEQ_SWING_DEFAULT=8"])
    want = model(tables.BASS_LINE, 125, bar_ticks, swing=8)
    ok &= compare("swing 8 (pattern 1, 125 BPM)", run_log(prg, 6), want)
    ons = [t for t, *_rest in note_ons(want)]
    print(f"  step gaps in the model: {sorted(set(b - a for a, b in zip(ons, ons[1:])))} ticks")

    # 2c. RUN/STOP on the step screen plays and stops (TEST_KEYS=5)
    prg = os.path.join(work, "keys5.prg")
    build(prg, ["TEST_KEYS=5"])
    log = run_log(prg, 6)
    on = {}
    for _t, n, v in log:
        on[n] = on.get(n, 0) + (1 if v else -1)
    played = sum(1 for _t, _n, v in log if v)
    stuck = [name(n) for n, c in on.items() if c > 0]
    good = played >= 16 and not stuck
    ok &= good
    secs = (log[-1][0] - log[0][0]) / tables.REAL_TICK_HZ if log else 0
    print(f"{'PASS' if good else 'FAIL'} play/stop keys: {played} notes over {secs:.1f} s, "
          f"left sounding after stop: {stuck or 'none'}")

    # 2d. editing on the step screen (TEST_KEYS=6): the result in memory
    prg = os.path.join(work, "keys6.prg")
    build(prg, ["TEST_KEYS=6"])
    lab = labels(prg)
    mem = run_mem(prg, 12, 0x0000, 0x83ff)
    def page(n):
        base = 0x8000 + 0x100 * (n - 1)
        return list(mem[base:base + 16]), list(mem[base + 16:base + 32]), mem[base + 32]
    # pattern 2 starts as the default (tables.LEAD_LINE): the script enters
    # notes at steps 1, 2, 5, 6, 7 and sets the times of 1-7; a tie or rest
    # keeps the note byte that was there, and steps 8-16 stay the lead's
    lead = tables.pattern_bytes(tables.SEQ_PATTERNS[1])
    notes = [36, 38] + lead[2:4] + [42, 41, 48] + lead[7:16]
    flags = lead[16:32]
    want = {
        "pattern 2": (notes, [0, 5, 2, 0, 13, 1, 1] + flags[7:], 7),
        "pattern 3": (notes, [1, 5, 2, 0, 13, 1, 1] + flags[7:], 7),
        "pattern 4": ([0] * 16, [0] * 16, 16),
    }
    got = {"pattern 2": page(2), "pattern 3": page(3), "pattern 4": page(4)}
    want_vars = {"edit_pat": 1, "cur_step": 0, "kb_octave": 3, "seq_bpm": 128,
                 "seq_swing": 2, "seq_next": 1, "note_count": 0, "seq_play": 0}
    got_vars = {k: mem[lab[k]] for k in want_vars}
    good = got == want and got_vars == want_vars
    ok &= good
    lags["keys6.prg"] = mem[LOG_LAG]
    print(f"{'PASS' if good else 'FAIL'} editing keys (TEST_KEYS=6): patterns 2-4 and the "
          f"editor's state as scripted")
    if not good:
        for k in want:
            if got[k] != want[k]:
                print(f"  {k}: got {got[k]}, want {want[k]}")
        for k in want_vars:
            if got_vars[k] != want_vars[k]:
                print(f"  {k}: got {got_vars[k]}, want {want_vars[k]}")

    # 2e. no stuck notes from auditions (TEST_KEYS=7)
    prg = os.path.join(work, "keys7.prg")
    build(prg, ["TEST_KEYS=7"])
    lab = labels(prg)
    log = run_log(prg, 8)
    mem = run_mem(prg, 8, 0x0000, 0x00ff)
    def balance(note):
        ons = sum(1 for _t, n, v in log if n == note and v)
        offs = sum(1 for _t, n, v in log if n == note and not v)
        return ons, offs
    d2, c2 = balance(38), balance(36)
    end = {k: mem[lab[k]] for k in ("note_count", "gate_bit", "seq_play")}
    good = (d2[0] >= 1 and d2[0] == d2[1] and c2[0] >= 1 and c2[0] == c2[1]
            and end == {"note_count": 0, "gate_bit": 0, "seq_play": 0})
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} auditions (TEST_KEYS=7): D-2 on/off {d2}, C-2 on/off "
          f"{c2}, at the end {end}")

    # 2f. a song: entries with repeats and transposes (TEST_SONG=1)
    prg = os.path.join(work, "song.prg")
    build(prg, ["TEST_SEQ=1", "TEST_EDGES=2", "TEST_SONG=1"])
    pats = [tables.SHORT1, tables.SHORT2]
    song = [(pats[p], rep, tr) for p, rep, tr in tables.SONG_TEST]
    want = model(None, 125, bar_ticks, song=song)
    ok &= compare("song (3 entries, repeats, transposes +5 and -12)", run_log(prg, 6), want)

    # 2g. undo, redo and the song keys (TEST_KEYS=8): the result in memory
    prg = os.path.join(work, "keys8.prg")
    build(prg, ["TEST_KEYS=8"])
    lab = labels(prg)
    mem = run_mem(prg, 14, 0x0000, 0x81ff) + run_mem(prg, 14, 0xc700, 0xc7ff)
    def at(addr):
        return mem[addr] if addr < 0x8200 else mem[0x8200 + addr - 0xc700]
    sp, sr, st, sl = lab["song_pat"], lab["song_rep"], lab["song_tr"], lab["song_len"]
    got = {
        "pattern 2 notes": [at(0x8100), at(0x8101)],
        "pattern 2 flags": [at(0x8110), at(0x8111)],
        "pattern 2 length": at(0x8120),
        "song": (at(sl), [at(sp), at(sp + 1)], [at(sr), at(sr + 1)], [at(st), at(st + 1)]),
        "undo": (at(lab["undo_count"]), at(lab["undo_redo"])),
        "state": {k: at(lab[k]) for k in ("song_on", "song_cur", "msg_on")},
    }
    want = {
        "pattern 2 notes": [36, 38], "pattern 2 flags": [1, 1], "pattern 2 length": 15,
        "song": (2, [1, 0], [3, 1], [2, 0]),
        "undo": (13, 1),
        "state": {"song_on": 1, "song_cur": 1, "msg_on": 0},
    }
    lags["keys8.prg"] = mem[LOG_LAG]
    good = got == want
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} undo and song keys (TEST_KEYS=8): pattern, song and "
          f"undo state as scripted")
    if not good:
        for k in want:
            if got[k] != want[k]:
                print(f"  {k}: got {got[k]}, want {want[k]}")

    # 2h. MIDI clock in (TEST_MIDI=5): start, clocks, stop, continue, stop
    ev = tables.clock_events()
    end = ev[-1][0] + 200
    for swing in (0, 8):
        prg = os.path.join(work, f"clock{swing}.prg")
        build(prg, ["TEST_MIDI=5", "TEST_CLOCK=1", f"SEQ_SWING_DEFAULT={swing}"])
        want = model(tables.BASS_LINE, 125, end, swing=swing, feed=ev)
        ok &= compare(f"MIDI clock in, swing {swing} (start, 2 bars, stop, continue, 1 bar)",
                      run_log(prg, 8), relative(want))
    ons = note_ons(relative(want))
    print(f"  {len(ons)} notes; the step after continue: {name(ons[32][1])} "
          f"(step {32 % 16 + 1} of pattern 1, where it stopped)")

    # 2i. MIDI out, internal clock: notes, start, 6 clocks a step
    prg = os.path.join(work, "out.prg")
    build(prg, ["TEST_SEQ=1", "TEST_MIDIOUT=1"])
    got = run_out(prg, 6)
    want = []
    model(tables.BASS_LINE, 125, bar_ticks, out=want)
    t0g, t0w = got[0][0], want[0][0]
    got_rel = [(t - t0g, b) for t, b in got]
    want_rel = [(t - t0w, b) for t, b in want]
    n = len(want_rel)
    good = got_rel[:n] == want_rel
    ok &= good
    clocks = sum(1 for _t, b in want_rel if b == 0xF8)
    print(f"{'PASS' if good else 'FAIL'} MIDI out, internal clock: {n} bytes equal the model "
          f"(start, {clocks} clocks, note on/off with slides as overlaps)")
    if not good:
        for i, (g, w) in enumerate(zip(got_rel, want_rel)):
            if g != w:
                print(f"  first difference at byte {i}: got {g}, want {w}")
                break
        else:
            print(f"  got {len(got_rel)} bytes, want {n}")

    # 2j. MIDI out with MIDI clock in: the notes, no clock out
    prg = os.path.join(work, "outclock.prg")
    build(prg, ["TEST_MIDI=5", "TEST_CLOCK=1", "TEST_MIDIOUT=1"])
    got = run_out(prg, 8)
    want = []
    model(tables.BASS_LINE, 125, end, feed=ev, out=want)
    got_rel = [(t - got[0][0], b) for t, b in got]
    want_rel = [(t - want[0][0], b) for t, b in want]
    # (the feed restarts after about a minute: compare its first pass)
    good = got_rel[:len(want_rel)] == want_rel and not any(b >= 0xF8 for _t, b in got)
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} MIDI out with MIDI clock in: {len(want_rel)} bytes equal "
          f"the model (notes only), no realtime bytes sent")

    # 2k. disk (TEST_KEYS=9..12), from a .d64 with the program as "SID101"
    d64tool = os.path.join(C64TOOLS, "d64.py")
    acid_bytes = tables.pattern_bytes(tables.BASS_LINE)

    def disk_run(n, jiffy=False):
        prg = os.path.join(work, f"keys{n}.prg")
        build(prg, [f"TEST_KEYS={n}"])
        img = os.path.join(work, f"keys{n}.d64")
        subprocess.run([sys.executable, d64tool, "--name", "SID101", "--id", "01", img,
                        f"{prg}=SID101"], check=True, capture_output=True)
        lab = labels(prg)
        mem = run_mems(img, 40, [(0x0000, 0x00ff), (0x8000, 0x8020), (0xc600, 0xc827)], jiffy)
        msg = "".join(chr(b) if 0x20 <= b < 0x60 else "?" for b in
                      (mem[0xc800 + i] for i in range(40))).rstrip()
        return lab, mem, msg

    for jiffy in (False, True):
        lab, mem, msg = disk_run(9, jiffy)
        st = {"pattern 1": [mem[0x8000 + i] for i in range(len(acid_bytes))] == acid_bytes,
              "tempo": mem[lab["seq_bpm"]], "song_len": mem[lab["song_len"]],
              "song entry": mem[lab["song_pat"]], "cutoff": mem[lab["params"]],
              "undo_count": mem[lab["undo_count"]], "message": msg}
        want = {"pattern 1": True, "tempo": 125, "song_len": 1, "song entry": 0, "cutoff": 110,
                "undo_count": 0, "message": "00, OK,00,00"}
        good = st == want
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} disk round trip (TEST_KEYS=9{', JiffyDOS' if jiffy else ''}): "
              f"saved, changed, loaded back: {st}")

    lab, mem, msg = disk_run(13)
    end = {k: mem[lab[k]] for k in ("seq_play", "note_count", "gate_bit")}
    good = msg == "00, OK,00,00" and end == {"seq_play": 0, "note_count": 0, "gate_bit": 0}
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} disk save while playing (TEST_KEYS=13): \"{msg}\", after it {end}")

    for n, want_msg, want_err in ((10, "NOT A SID101 FILE", 2), (11, "62, FILE NOT FOUND,00,00", 0),
                                  (12, "NO DRIVE 9", 1)):
        lab, mem, msg = disk_run(n)
        same = [mem[0x8000 + i] for i in range(len(acid_bytes))] == acid_bytes and mem[lab["seq_bpm"]] == 125
        good = msg == want_msg and mem[lab["disk_error"]] == want_err and same
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} disk TEST_KEYS={n}: \"{msg}\", disk_error "
              f"{mem[lab['disk_error']]}, pattern 1 and tempo unchanged: {same}")

    # 3. against the MIDI feed of the same line
    prg = os.path.join(work, "feed.prg")
    build(prg, ["TEST_MIDI=4"])
    n_feed = 4 * sum(1 for n, _, _ in tables.BASS_LINE if n not in ("-", "="))   # four bars
    feed = note_ons(relative(run_log(prg, 6)))[:n_feed]
    seq = note_ons(relative(acid))[:n_feed]
    worst = max(abs(f[0] - s[0]) for f, s in zip(feed, seq))
    same = all(f[1:] == s[1:] for f, s in zip(feed, seq)) and len(feed) == len(seq) == n_feed
    if same and worst <= 1:
        print(f"PASS feed: {n_feed} note-ons with the same notes, velocities and slides, "
              f"ticks within {worst}")
    else:
        ok = False
        print(f"FAIL feed: same notes/slides {same}, worst tick difference {worst}")
        for f, s in zip(feed, seq):
            if f[1:] != s[1:] or abs(f[0] - s[0]) > 1:
                print(f"  feed {f}  sequencer {s}")
                break

    # 4. tempo: the note-ons at the model's ticks over TEMPO_BARS bars (the
    # note log holds 512 events: 17 bars of on and off)
    TEMPO_BARS = 16
    for bpm in (60, 120, 240):
        prg = os.path.join(work, f"tempo{bpm}.prg")
        build(prg, ["TEST_SEQ=1", f"SEQ_BPM_DEFAULT={bpm}"])
        inc, steplen = tables.tempo_steps(bpm)
        per_bar = sum(1 for n, _, _ in tables.BASS_LINE if n not in ("-", "="))
        ons = [t for t, *_rest in note_ons(relative(run_log(prg, 20)))][:TEMPO_BARS * per_bar]
        want = [t for t, *_rest in note_ons(model(tables.BASS_LINE, bpm, round(31 * 16 * steplen)))]
        real_bpm = inc * tables.REAL_TICK_HZ / 65536 * 15
        bar_ms = [(ons[i + per_bar] - ons[i]) * 1000 / tables.REAL_TICK_HZ
                  for i in range(0, len(ons) - per_bar, per_bar)]
        good = len(ons) == TEMPO_BARS * per_bar and ons == want[:len(ons)]
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} tempo {bpm} BPM: {len(ons) // per_bar} bars at the model's "
              f"ticks; real tempo {real_bpm:.3f} BPM ({(real_bpm / bpm - 1) * 100:+.3f} %), "
              f"bars {min(bar_ms):.0f}-{max(bar_ms):.0f} ms")

    # 5. load: pattern 3 (a fresh note every step) playing on the step screen
    # with the heaviest sound (TEST_MIDI=7: Sync mode, noise, fade, vibrato,
    # wheel, accent); its lag counts with the runs that play, below
    prg = os.path.join(work, "heavy.prg")
    build(prg, ["TEST_SEQ=1", "TEST_SEQ_PAT=2", "TEST_MIDI=7", "TEST_KEYS=4"])
    heavy = run_log(prg, 12)
    good = len(note_ons(heavy)) > 100
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} load: {len(note_ons(heavy))} notes played with the heaviest "
          f"sound and the step screen open, lag {lags.get('heavy.prg')} tick(s)")

    # ticks run late: the logged ticks are ticks run, so a backlog wouldn't show
    # Runs that play must never fall behind (a note would come late). The
    # editing runs never play: there an undo of a song edit (swapping the
    # 193-byte song block, ~1.6 ticks) may leave one tick waiting.
    edit_runs = {"keys6.prg", "keys8.prg"}
    worst_play = max(v for k, v in lags.items() if k not in edit_runs)
    worst_edit = max(v for k, v in lags.items() if k in edit_runs)
    good = worst_play <= 1 and worst_edit <= 2
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} lag: at most {worst_play} tick(s) waiting in the runs "
          f"that play, {worst_edit} in the editing runs "
          f"({', '.join(f'{k} {v}' for k, v in lags.items())})")

    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
