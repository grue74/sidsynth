"""count_check.py - SID500 stage D: the count-in, in VICE.

Builds TEST_SLAVE=12 programs with TEST_FEED_MASTER and TEST_COUNT: as
master, the band (scene 1) stopped at start-up, C= R on track 9 (a new
pattern) at the first look (src/count.asm count_test, as the song screen
would), the Count-in parameter's bars of clicks, then the song from its
start, recording; notes fed into MIDI in through the real receive
interrupt across the count-in's end (tables.py feed_count). Checked from
the log (each timer interrupt, each byte sent and fed, the clicks, the
stamps):

- the count's clicks (LOG_CLICK): bars x beats of them, one on each
  beat's interrupt (a quarter in n/4, an eighth in n/8), the bar's first
  the brighter (2), the last one a beat before the song's tick 0: MIDI
  start goes at the interrupt before tick 0's (its first clock), so the
  count's beat runs straight on into the song's;
- nothing sent before MIDI start but the click's MIDI notes (the
  Metronome MIDI or SID+MIDI: the Beat or Bar note on channel 16, on each
  click's interrupt, its off before the next), no clock;
- each message fed before tick 0 stamped at pass 0 when it came within
  COUNT_EARLY ticks of it, else left out; those after it the tick heard
  (the nearest, within one); none lost;
- with Count-in Off: MIDI start at once (no clicks, nothing before it);
- away from the song's start (TEST_COUNT_RESET): the song reset first,
  then the same;
- C= R again during the count (TEST_COUNT_CANCEL): the clicks stop, no
  MIDI start or clock ever, every click note ended, the take ended; at the
  end nothing on (count_state, rec_state, play_state 0) and the song at
  its start (pos_zero).

    python tools/count_check.py [--seconds S] [--run N]
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402
import thru_check as th  # noqa: E402  (messages from stamped bytes)
import record_check as rc  # noqa: E402  (the run: log and memory)

LOG_CLICK, LOG_CLICK_AT = 19, 20
FEED = 12
TRACK = 9                       # a new pattern (the band leaves track 9 empty)
COUNT_EARLY = 6                 # src/count.asm
CLICK_STATUS = 0x9F             # the click's note on, channel 16 (TEST_CLICK_CHAN 15)
BEAT_NOTE, BAR_NOTE = 37, 75
MIDI_CLICK_MAX = 3000           # cycles from a click's interrupt to its note's first byte
                                # (click_check's 2,000, and the feed's receive interrupts,
                                # ~650 cycles each with their logging, between)
EDGE = 400                      # cycles: a message this near an interrupt may fall either side
SIG_EIGHTHS = 0x80
PAL_CLOCK = 985248

RUNS = [  # (name, BPM, Count-in bars, Metronome (TEST_CLICK: 0 off, 1 SID, 2 MIDI, 3
          #  both), signature (beats - 1, + SIG_EIGHTHS for n/8), reset first, C= R again
          #  with fewer than n ticks of the count left)
    ("120 BPM, 1 bar of 4/4, Metronome Off", 120, 1, 0, 3, 0, 0),
    ("240 BPM, 2 bars of 4/4, SID+MIDI", 240, 2, 3, 3, 0, 0),
    ("240 BPM, 2 bars of 7/8, MIDI", 240, 2, 2, 6 | SIG_EIGHTHS, 0, 0),
    ("120 BPM, Count-in Off", 120, 0, 0, 3, 0, 0),
    ("120 BPM, 1 bar, away from the song's start (reset first)", 120, 1, 1, 3, 1, 0),
    ("120 BPM, 1 bar, SID+MIDI, ended by C= R", 120, 1, 3, 3, 0, 100),
]



def build(out, bpm, bars, click, sig, reset, cancel):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF['datel']}",
                    "-D", "TEST_PLAY=1", "-D", f"TEST_SLAVE={FEED}",
                    "-D", "TEST_FEED_MASTER=1", "-D", f"TEST_TEMPO={bpm}",
                    "-D", "TEST_THRU=0", "-D", f"TEST_COUNT={TRACK}",
                    "-D", f"TEST_COUNT_BARS={bars}", "-D", f"TEST_CLICK={click}",
                    "-D", "TEST_CLICK_CHAN=15", "-D", f"TEST_SIG={sig}",
                    "-D", f"TEST_COUNT_RESET={reset}", "-D", f"TEST_COUNT_CANCEL={cancel}",
                    "-o", out, "-l", out + ".lbl", "sid500.asm"],
                   cwd=ROOT, check=True)


def labels(path):
    out = {}
    for line in open(path):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:
            v = m.group(2)
            out[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return out


def click_notes(log):
    """The click's MIDI messages as sent: [(time of the status byte, note,
    velocity)] (channel 16's note ons; running status followed)."""
    out, status, data, t_status = [], None, [], None
    for k, v, t in log:
        if k != tc.LOG_TX or v >= 0xF8:
            continue
        if v >= 0x80:
            status, data, t_status = v, [], t
            continue
        data.append(v)
        if len(data) == 2:
            if status == CLICK_STATUS:
                out.append((t_status, data[0], data[1]))
            data, t_status = [], t
    return out


def at_interrupt(ticks, t):
    """The index of the last timer interrupt at or before time t."""
    lo, hi = 0, len(ticks)
    while lo < hi:
        mid = (lo + hi) // 2
        if ticks[mid] <= t:
            lo = mid + 1
        else:
            hi = mid
    return lo - 1


def check(name, bpm, bars, click, sig, reset, cancel, log, mem, lb):
    errors = []
    beat = 24 if sig & SIG_EIGHTHS else 48
    beats = (sig & 0x0F) + 1
    period = tables.tick_cycles(bpm)
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    clicks = [(v, t) for k, v, t in log if k == LOG_CLICK]
    lost = [v for k, v, _ in log if k == rc.LOG_REC_LOST]
    if lost:
        errors.append(f"messages lost: {lost[:8]}")
    starts = [t for v, t in sent if v == tc.START]
    clocks = [t for v, t in sent if v == tc.CLOCK]

    if cancel:
        # ended by C= R: no start, no clock, every click note ended, all off
        if starts or clocks:
            errors.append(f"{len(starts)} MIDI starts and {len(clocks)} clocks sent")
        notes = click_notes(log)
        ons = sum(1 for _, _, vel in notes if vel)
        offs = len(notes) - ons
        if ons != offs:
            errors.append(f"{ons} click notes on and {offs} offs")
        if click & 2 and not ons:
            errors.append("no click note sent")
        if not clicks:
            errors.append("no clicks before C= R")
        n0 = bars * beats
        if len(clicks) >= n0:
            errors.append(f"{len(clicks)} clicks: the count went on")
        idx = [at_interrupt(ticks, t) for _, t in clicks]
        for a, b in zip(idx, idx[1:]):
            if b - a != beat:
                errors.append(f"clicks {b - a} interrupts apart, not {beat}")
        if len(rc.pairs(log, rc.LOG_REC_END)) != 1:
            errors.append("the take not ended")
        for var, want in (("count_state", 0), ("rec_state", 0), ("play_state", 0),
                          ("pos_zero", 1)):
            got = mem.get(lb[var])
            if got != want:
                errors.append(f"{var} {got} at the end, not {want}")
        print(f"{name}: {len(clicks)} clicks, {ons} click notes, then ended: nothing sent")
        for e in errors[:10]:
            print("   FAIL:", e)
        return not errors

    if len(starts) != 1:
        print(f"{name}:\n   FAIL: {len(starts)} MIDI starts")
        return False
    t_start = starts[0]
    i_start = at_interrupt(ticks, t_start)
    i0 = i_start + 1                            # the song's tick 0's interrupt
    if i0 >= len(ticks):
        print(f"{name}:\n   FAIL: the log ends before tick 0")
        return False
    t0 = ticks[i0]
    first_clock = min((t for t in clocks if t > t_start), default=None)
    if first_clock is None or at_interrupt(ticks, first_clock) != i0:
        errors.append("the first clock not at tick 0's interrupt")
    if any(t < t_start for t in clocks):
        errors.append("a clock before MIDI start")

    # the count's clicks: on beats, the last a beat before tick 0
    pre = [(v, at_interrupt(ticks, t)) for v, t in clicks if t < t0]
    n = bars * beats
    want = [(2 if j % beats == 0 else 1, i0 - (n - j) * beat) for j in range(n)]
    if pre != want:
        errors.append(f"the count's clicks (value, interrupt from tick 0) "
                      f"{[(v, i - i0) for v, i in pre][:10]}, not "
                      f"{[(v, i - i0) for v, i in want][:10]}")
    at = [v for k, v, _ in log if k == LOG_CLICK_AT][:2 * len(pre)]
    for j, (_, i) in enumerate(pre):
        low = at[2 * j] if 2 * j < len(at) else None
        if low != (i - i0) & 0xFF:
            errors.append(f"click {j}'s song tick (low byte) {low}, not {(i - i0) & 0xFF}")
            break

    # nothing sent before MIDI start but the click's notes
    notes = click_notes(log)
    before = [(v, t) for v, t in sent if t < t_start]
    pre_notes = [x for x in notes if x[0] < t_start]
    if click & 2:
        ons = [x for x in pre_notes if x[2]]
        if len(ons) != n:
            errors.append(f"{len(ons)} click notes on before the start, not {n}")
        for (t, note, _), (v, i) in zip(ons, want):
            want_note = BAR_NOTE if v == 2 else BEAT_NOTE
            if note != want_note:
                errors.append(f"a click note {note}, not {want_note}")
            if not 0 <= t - ticks[i] <= MIDI_CLICK_MAX:
                errors.append(f"a click note {t - ticks[i]} cycles from its interrupt")
        offs = [x for x in pre_notes if not x[2]]
        if len(offs) != len(ons):
            errors.append(f"{len(ons)} click notes on before the start, {len(offs)} offs")
        if len(before) != 3 * len(pre_notes):    # (each message whole: a send
            errors.append(f"{len(before)} bytes before MIDI start, "  # starts afresh)
                          f"{3 * len(pre_notes)} the click notes'")
    elif before:
        errors.append(f"{len(before)} bytes sent before MIDI start: {[v for v, _ in before][:8]}")

    # the stamps: before tick 0 within COUNT_EARLY ticks at 0, else left
    # out; after it the tick heard (the nearest, within one)
    fed = th.stamped_messages([(v, t, 0) for k, v, t in log if k == rc.LOG_RX])
    marks = [v for k, v, _ in log if k == rc.LOG_REC_STAMP]
    stamps = [marks[i] | marks[i + 1] << 8 for i in range(0, len(marks) - 1, 2)]
    expect = []                                 # each message: a set of what may come
    for m, t, _ in fed:
        if m[0] & 0xF0 in (0xA0, 0xD0):
            continue
        i = at_interrupt(ticks, t)
        near = min(abs(t - ticks[i]) if i >= 0 else 1 << 30,
                   abs(ticks[i + 1] - t) if i + 1 < len(ticks) else 1 << 30)
        if t < t0 - EDGE:
            left = i0 - i                       # count_left then
            ok = {0} if left <= COUNT_EARLY else {None}
            if near < EDGE and left in (COUNT_EARLY, COUNT_EARLY + 1):
                ok = {0, None}
        elif t < t0 + EDGE:
            ok = {0}
        else:
            # the tick heard, as record_check.py takes it: the last due, the
            # next past half the period; within one
            k = i - i0 + (1 if t - ticks[i] > period / 2 else 0)
            ok = {k - 1, k, k + 1}
        expect.append((t - t0, ok))
    # matched in order; a message at the edge may or may not be stamped:
    # each way tried (the log ends where the stamps or the messages do)
    bad = []

    def match(m, j):
        while m < len(expect) and j < len(stamps):
            d, ok = expect[m]
            if None in ok and len(ok) > 1:      # (either way)
                return (stamps[j] in ok and match(m + 1, j + 1)) or match(m + 1, j)
            if None in ok:
                m += 1
            elif stamps[j] in ok:
                m, j = m + 1, j + 1
            else:
                bad.append((d, stamps[j], ok))
                return False
        return j == len(stamps) or m == len(expect)
    if not match(0, 0):
        d, st, ok = bad[-1] if bad else (0, None, set())
        errors.append(f"the stamps unlike the messages': a message {d / period:+.1f} ticks "
                      f"from tick 0 stamped {st}, not {sorted(x for x in ok if x is not None)}")
    stamped_early = sum(1 for k, _, t in log if k == rc.LOG_REC_STAMP and t < t0) // 2
    left_out = sum(1 for d, _ in expect if d < 0) - stamped_early
    j = len(stamps)
    starts_rec = rc.pairs(log, rc.LOG_REC_START)
    if starts_rec != [0]:
        errors.append(f"the take begun at {starts_rec}, not pass 0")
    lead = (t0 - ticks[0]) / PAL_CLOCK
    print(f"{name}: {len(pre)} count clicks, MIDI start a tick before tick 0 "
          f"({lead:.2f} s from the first interrupt); {stamped_early} messages before "
          f"tick 0 stamped 0, {left_out} left out, {j} stamps in all")
    if not stamped_early and bars:
        errors.append("no message in the count's last ticks: the feed missed them")
    for e in errors[:10]:
        print("   FAIL:", e)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--run", type=int, default=None)
    args = ap.parse_args()
    os.makedirs(os.path.join(ROOT, "work"), exist_ok=True)
    ok = True
    for n, (name, bpm, bars, click, sig, reset, cancel) in enumerate(RUNS):
        if args.run is not None and n != args.run:
            continue
        prg = os.path.join(ROOT, "work", f"count{n}.prg")
        build(prg, bpm, bars, click, sig, reset, cancel)
        lb = labels(prg + ".lbl")
        ranges = [(lb["count_state"], lb["count_state"] + 1), (lb["pos_zero"], lb["pos_zero"] + 1),
                  (lb["play_state"], lb["play_state"] + 1), (lb["rec_state"], lb["rec_state"] + 1)]
        log, mem = rc.run(prg, args.seconds, ranges, whole=True, cut=False)
        ok &= check(name, bpm, bars, click, sig, reset, cancel, log, mem, lb)
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
