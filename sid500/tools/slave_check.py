"""slave_check.py - SID500 stage A: the player as slave, in VICE.

Builds TEST_SLAVE programs: Clock = MIDI, a master's realtime bytes
(tables.py's feeds) fed into MIDI in through the real receive interrupt
(src/test_slave.asm: the raster interrupt stands in for the ACIA's, core
option TEST_RX_FEED), the band scene (TEST_PLAY 1) playing. The log has
each byte fed (LOG_RX), each of the slave's timer interrupts with the
ticks it made due (LOG_SLAVE), and the bytes sent. Checks:

- passed on: the realtime bytes sent are the ones fed, in order, each
  within PASS_MAX of coming in;
- the ticks: two a clock from the first clock after start, never more,
  none lost: each clock's tick (the even one) within EVEN_MAX of it; the
  tick between (the odd one) half the last gap after the clock's tick,
  within ODD_MAX, or, when the next clock comes first (the master sped
  up), with that clock's tick;
- the bytes: every one the model's (play_check.Player), in order; with one
  byte in 8 stamped (--sparse) the lag the player adds against a wire
  model from the ticks' times (play_check's), at most LAG_MAX;
- the Clock switched from master to MIDI while playing (TEST_SWITCH): the
  master's bytes the model's up to there, then it stops as a stop does
  (MIDI stop, a note off for each note sounding), then no clock of its
  own: the bytes fed passed on, none lost, and from the start fed the
  slave's ticks and bytes as above.

    python tools/slave_check.py [--seconds S]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402  (the feeds, the scenes)
import timing_check as tc  # noqa: E402  (VICE runs and the log)
import play_check as pc  # noqa: E402  (the player's model)

LOG_RX, LOG_SLAVE = 7, 8        # src/timing.asm
SCENE = 1                       # the band
PASS_MAX = tc.CLOCK_MAX         # a byte passed on: the bytes in the 6850 ahead of it, plus
                                # the handlers (as the master's clock, timing_check.py)
EVEN_MAX = 1100                 # a clock's tick due after it came, cycles: synth_rt_irq
                                # (~200), the kick and the interrupts between (the transmit
                                # handler sending the clock on), slave_tick (~150), and the
                                # tests' stamps (~60 each: three in the way): ~970 seen, 1002
                                # once
NMI_EVEN_MAX = 1300             # with an NMI interface the transmit handler (stamping) also
                                # comes in the middle of it: ~1220 seen
ODD_MAX = 500                   # an odd tick due after its time (half a gap after the clock's
                                # tick): its interrupt behind the handlers already running
                                # (at 290 BPM, before the 240 cap, every byte stamped: 402 and 422)
ODD_EARLY = 64                  # src/timing.asm SLAVE_ODD_EARLY
HALF_MIN = 0x0800               # src/timing.asm SLAVE_HALF_MIN

SWITCH_TICKS = 250              # TEST_SWITCH: the Clock switched after 1 s (feed 6)

RUNS = [  # (name, feed, cartridge, lag checked, more build options)
    ("steady 120 BPM", 1, "datel", True, {}),
    ("120 BPM, each clock up to 1 ms off", 2, "datel", True, {}),
    ("120 BPM, 150, 120 again", 5, "datel", True, {}),
    # (a jump to 2.4x the tempo: the ticks rendered ahead at the old
    # tempo are 0.4 of the lead in time, and a busy one comes too
    # soon: ~3.4 ms seen just after the jump; the ticks themselves checked)
    ("100 BPM, then 240 at once", 3, "datel", False, {}),
    ("240 BPM, then 60 at once", 4, "datel", True, {}),
    # (the slave's own Tempo the slowest: its lead before start can't
    # come from it)
    ("240 BPM, then 60 at once, Tempo 40", 4, "datel", True, {"TEST_TEMPO": 40}),
    ("Namesoft (NMI out), steady 120 BPM", 1, "namesoft", True, {}),
    ("master, Clock to MIDI after 1 s, start fed at 2 s", 6, "datel", True,
     {"TEST_SWITCH": SWITCH_TICKS}),
]


def build(out, feed, sparse, iface, more):
    defs = []
    for k, v in more.items():
        defs += ["-D", f"{k}={v}"]
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF[iface]}",
                    "-D", f"TEST_PLAY={SCENE}", "-D", f"TEST_SLAVE={feed}",
                    "-D", f"TEST_STAMP_FEW={2 if sparse else 0}", *defs, "-o", out,
                    "sid500.asm"], cwd=ROOT, check=True)


def message_ends(data):
    """For each whole message in data (as play_check.messages parses
    them), the index of its last byte."""
    ends, status, n = [], 0, 0
    for i, b in enumerate(data):
        if b >= 0x80:
            status, n = b, 1
        else:
            n = n or 1                  # (running status: the status implied)
            n += 1
        if n and n == (2 if status & 0xE0 == 0xC0 else 3):
            ends.append(i)
            n = 0
    return ends


def split_switch(log, errors):
    """A TEST_SWITCH run's log cut at the switch: the master stopped as a
    stop does (MIDI stop, then a note off for each note sounding, nothing
    else), its messages before it the model's (the ticks it played found
    near twice its clocks); then no clock of its own: only the bytes fed,
    passed on. Returns the log from the first byte after the offs (the
    slave's part, for check)."""
    sent = [(i, v, t) for i, (k, v, t) in enumerate(log) if k == tc.LOG_TX]
    stop = next((t for _, v, t in sent if v == tc.STOP), None)
    if stop is None:
        errors.append("no MIDI stop at the switch")
        return log
    clocks = sum(1 for _, v, t in sent if v == tc.CLOCK and t < stop)
    notes = [(i, v, t) for i, v, t in sent if v < 0xF8]
    msgs = pc.messages([v for _, v, _ in notes])
    found = None
    for n in sorted(range(max(0, 2 * clocks - 4), 2 * clocks + 5), key=lambda n: abs(n - 2 * clocks)):
        player = pc.Player(*tables.SCENES[SCENE]())
        want = []
        for _ in range(n):
            want += pc.messages(player.play())
        want += [(0x90 | ch, note, 0) for ch, note in sorted(player.sounding)]
        if msgs[:len(want)] == want:
            found = (n, len(want), len(player.sounding))
            break
    if found is None:
        errors.append(f"the master's messages and its stop's offs aren't the model's "
                      f"for any tick count near {2 * clocks}")
        return log
    n, upto, offs = found
    # where the offs end in the log: the raw bytes walked as messages()
    # does (running status leaves statuses out)
    ends = message_ends([v for _, v, _ in notes])
    end_i = notes[ends[upto - 1]][0]
    # after it, only the bytes fed, passed on: the last ones fed, and none
    # fed after the stop missing (one fed just before the switch is a
    # master's: ignored)
    own = [v for i, v, t in sent if t > stop and v >= 0xF8]
    fed = [(v, t) for k, v, t in log if k == LOG_RX]
    tail = fed[len(fed) - len(own):] if own else []
    missed = [t for v, t in fed[:len(fed) - len(own)] if t > stop]
    if [v for v, _ in tail] != own or missed:
        errors.append("after the switch, the realtime bytes sent aren't the ones fed")
    print(f"   switched after {n} master ticks as the model's, then MIDI stop and {offs} "
          f"note offs; {len(own)} realtime bytes sent after, all the last ones fed")
    return log[end_i + 1:]


def ticks_of(log, errors):
    """The song ticks' times (each tick due at its LOG_SLAVE entry), and
    the ticks checked against the clocks fed."""
    fed = [(v, t) for k, v, t in log if k == LOG_RX]
    start = next(t for v, t in fed if v == tc.START)
    song, clocks_in, played = [], 0, 0
    gap = None
    last_rx = max((t for v, t in fed if v == tc.CLOCK and t < start), default=None)
    even_lags, odd_lags = [], []
    odd_due = None              # the odd tick owed: its time
    clock_t, pending_even = None, False
    for k, v, t in log:
        if k == LOG_RX and v == tc.CLOCK:
            if last_rx is not None and HALF_MIN <= (t - last_rx) / 2 <= 0xFFFF:
                gap = t - last_rx       # (as the program: other gaps aren't tempos)
            if t > start:
                if odd_due is not None and odd_due + ODD_MAX < t:
                    errors.append(f"the odd tick due at {odd_due:.0f} not played by the next "
                                  f"clock at {t}")
                clocks_in += 1
                clock_t = t
                pending_even = True
            last_rx = t
        elif k == LOG_SLAVE and t > start and v:
            if played + v > 2 * clocks_in:
                errors.append(f"{played + v} ticks due at {t} after {clocks_in} clocks")
                break
            if played + v == 2 * clocks_in - 1:     # a clock's tick (and an owed odd one)
                if not pending_even:
                    errors.append(f"a clock's tick at {t} with no clock")
                even_lags.append(t - clock_t)
                pending_even = False
                odd_due = t + gap / 2 if gap is not None else None
            elif played + v == 2 * clocks_in and v == 1 and not pending_even:
                if odd_due is not None:
                    odd_lags.append(t - odd_due)
                odd_due = None
            else:
                errors.append(f"{v} ticks due at {t}: {played} played, {clocks_in} clocks")
                break
            song += [t] * v
            played += v
    if not song:
        errors.append("no tick played")
    return song, even_lags, odd_lags, fed


def passed_on(fed, sent, errors):
    """The realtime bytes sent against the ones fed: the same, each soon."""
    rt_in = [(v, t) for v, t in fed if v >= 0xF8]   # (a song position fed: not passed on)
    rt_out = [(v, t) for v, t in sent if v >= 0xF8]
    n = min(len(rt_in), len(rt_out))
    if [v for v, _ in rt_in[:n]] != [v for v, _ in rt_out[:n]]:
        errors.append("the realtime bytes sent aren't the ones fed")
        return 0
    if len(rt_in) - n > 2:
        errors.append(f"{len(rt_in) - n} realtime bytes fed not passed on")
    lags = [o - i for (_, i), (_, o) in zip(rt_in, rt_out)]
    if lags and (min(lags) < 0 or max(lags) > PASS_MAX):
        errors.append(f"a byte passed on {min(lags)}..{max(lags)} cycles after it came")
    return max(lags) if lags else 0


def check(name, log, sparse, lag_checked=True, nmi=False, switch=False):
    errors = []
    if switch:
        log = split_switch(log, errors)
    song, even_lags, odd_lags, fed = ticks_of(log, errors)
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    pass_max = passed_on(fed, sent, errors)
    if even_lags and max(even_lags) > (NMI_EVEN_MAX if nmi else EVEN_MAX):
        errors.append(f"a clock's tick {max(even_lags)} cycles after it")
    if odd_lags and (max(odd_lags) > ODD_MAX or min(odd_lags) < -ODD_EARLY):
        errors.append(f"an odd tick {min(odd_lags):.0f}..{max(odd_lags):.0f} cycles off its time")

    # the bytes: the model's, from the ticks' times
    player = pc.Player(*tables.SCENES[SCENE]())
    expect = []
    for k in range(len(song)):
        expect += [(b, k) for b in player.play()]
    got = [(v, t) for v, t in sent if v < 0xF8]
    if sparse:
        lag_errors = []
        worst, where = lag_sparse(song, expect, got, [t for v, t in sent if v >= 0xF8],
                                  lag_errors)
        errors += [e for e in lag_errors if lag_checked or "later than" not in e]
        what = (f"one byte in {pc.STAMP_EVERY} stamped: the player's added lag at most "
                f"{worst} cycles ({worst / 985.248:.2f} ms), at song tick {where}")
    else:
        got_m, exp_m = pc.messages([v for v, _ in got]), pc.messages([b for b, _ in expect])
        m = min(len(got_m), len(exp_m))
        if got_m[:m] != exp_m[:m]:
            i = next(i for i in range(m) if got_m[i] != exp_m[i])
            errors.append(f"message {i} is {got_m[i]}, the model's {exp_m[i]}")
        if len(exp_m) - len(got_m) > 40:
            errors.append(f"{len(got_m)} messages sent, the model {len(exp_m)} by the log's end")
        what = f"{len(got_m)} messages as the model's"
    odd = (f"odd ticks {min(odd_lags):.0f}..{max(odd_lags):.0f}" if odd_lags else "no odd tick")
    print(f"{name}: {len(song)} ticks; passed on within {pass_max}; clock's tick within "
          f"{max(even_lags, default=0)}, {odd} cycles of their times; {what}")
    for e in errors:
        print("   FAIL:", e)
    return not errors


def lag_sparse(song, expect, got, realtime, errors):
    """As play_check.lag_sparse: the stamped bytes (one in STAMP_EVERY)
    against the model's at their places, each against the wire model (a
    tick's bytes ready at its time, a byte every 283 cycles, the realtime
    bytes in their own slots)."""
    ready, wire, c = [], 0, 0
    for b, k in expect:
        r = max(song[k], wire)
        while c < len(realtime) and realtime[c] <= r:
            wire = max(wire, realtime[c]) + tc.BYTE_CYCLES
            r = max(song[k], wire)
            c += 1
        ready.append(r)
        wire = r + tc.BYTE_CYCLES
    worst, where = 0, None
    for j, (v, t) in enumerate(got):
        i = (j + 1) * pc.STAMP_EVERY - 1
        if i >= len(expect):
            break
        if v != expect[i][0]:
            errors.append(f"stamped byte {i} is {v:02x}, the model's {expect[i][0]:02x}")
            break
        if t - ready[i] > worst:
            worst, where = t - ready[i], expect[i][1]
    if worst > pc.LAG_MAX:
        errors.append(f"a byte went out {worst} cycles later than the wire allows")
    return worst, where


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=6, help="real seconds a run (warp)")
    a = ap.parse_args()
    ok = True
    for i, (name, feed, iface, lag_checked, more) in enumerate(RUNS):
        switch = "TEST_SWITCH" in more
        for sparse in (False, True):
            if iface == "namesoft" and not sparse:
                continue        # (every byte stamped in the NMI: the timing distorted)
            if switch and sparse:
                continue        # (the switch is checked by its bytes, all stamped)
            prg = os.path.join(ROOT, f"slave-{i}.prg")
            build(prg, feed, sparse, iface, more)
            try:
                for model, cia in tc.CIA_MODELS:
                    label = f"{model}, {name}" + (", sparse" if sparse else "")
                    ok &= check(label, tc.run_log(prg, a.seconds, cia, iface), sparse,
                                lag_checked, iface == "namesoft", switch)
            finally:
                os.remove(prg)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
