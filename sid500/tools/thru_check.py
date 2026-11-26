"""thru_check.py - SID500 stage D: MIDI thru, in VICE.

Builds TEST_SLAVE=10 programs with TEST_FEED_MASTER: as master, a test
scene playing from the start (or stopped), and a keyboard's phrases
(tables.py's KEYS_PHRASE, feed 10) fed into MIDI in through the real
receive interrupt (src/test_slave.asm, as slave_check.py; the core's
MIDI_RX_IRQ hands each byte to record.asm there). Thru is on and the
cursor on track 1, so every message goes out again on track 1's channel.
The log has each byte fed (LOG_RX), the ticks, and the bytes sent, thru's
apart (LOG_TX_THRU: the test build marks their places in the ring).

Three kinds of run:

- "content" (every byte stamped): the thru messages are the ones fed, in
  order, on track 1's channel (an off as it came: $8x, or a note on of
  velocity 0; aftertouch not passed on); the player's messages are the
  model's (play_check.Player), in order; no message mixes thru's bytes and
  the player's (thru came between whole messages and broke no running
  status); the lag from a message's last byte in to its last byte out, at
  most LAG_MAX (reported: median and most);
- "jitter" (the ticks and realtime bytes stamped, and thru's): the ticks
  on their grid and the clock's gaps within timing_check.py's limits with
  a keyboard playing;
- "sparse" (one byte in 8 stamped, and thru's): the lag the player adds
  against a wire model in which thru's bytes and the clocks take their
  slots, against the same build with Thru off. Half the wire with a
  keyboard played through is overload (the user, 2026-11-22): its busy
  16ths' render takes nearly all the time there is, so thru's ~500 cycles
  a message make them late (~25 ms more than Thru off), and in about one
  run in nine the renderer falls further behind as long as the playing
  lasts (~280 ms). Reported, not checked, as play_check's heavy scene.

    python tools/thru_check.py [--seconds S]
"""
import argparse
import bisect
import os
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402  (the feed, the scenes)
import timing_check as tc  # noqa: E402  (VICE runs and the log)
import play_check as pc  # noqa: E402  (the player's model)

LOG_RX, LOG_THRU_LOST, LOG_TX_THRU, LOG_MARKS_FULL, LOG_RX_DONE = 7, 21, 22, 23, 24  # src/
                                # timing.asm, src/record.asm
FEED = 10                       # tables.py feed_keys
CYCLES_MS = 985.248
LAG_MAX = 30 * CYCLES_MS * tc.BYTE_CYCLES / 283  # in to out: the IRQ's flush, the busy
                                # tick's bytes already in the ring ahead (half the wire: ~21
                                # ms seen); 30 ms at VICE's old pace, scaled by the wire's
                                # (the user, 2026-11-26): 33.4 ms on the real wire
THRU_TICK_ADDED_MAX = tc.TICK_JITTER_MAX   # cycles thru may add to the ticks' spread, and
THRU_CLOCK_ADDED_MAX = tc.TICK_JITTER_MAX  # to a clock's time after its tick: its work in
                                # the receive interrupt before them (~330 seen on a clock)
JITTER_RUNS = 2                 # runs on each CIA model, the worst compared
THRU_IRQ_ADDED_MAX = tc.TICK_JITTER_MAX  # cycles thru may add to the receive interrupt's
                                # longest: a tick or a clock may wait for it
THRU_PLAYER_ADDED_MAX = 30 * CYCLES_MS # cycles thru may add to the player's lag (the user,
                                # 2026-11-22: half the wire's busy 16ths, a keyboard playing
                                # through: their render takes all the time there is, so thru's
                                # ~500 cycles a message delay them, and the next 16th)

RUNS = [  # (name, scene, BPM, interface, mode, more build options)
    ("the band, 120 BPM", 1, 120, "datel", "content", {}),
    ("the band, 240 BPM", 1, 240, "datel", "content", {}),
    ("half the wire, 120 BPM", 4, 120, "datel", "content", {}),
    ("stopped", 1, 120, "datel", "content", {"TEST_AUTOSTART": 0}),
    # (the NMI: only queued there, sent after the next release)
    ("Namesoft (NMI), the band, 120 BPM", 1, 120, "namesoft", "content", {}),
    ("the band, 120 BPM", 1, 120, "datel", "jitter", {"TEST_STAMP_FEW": 3}),
    ("half the wire, 120 BPM", 4, 120, "datel", "jitter", {"TEST_STAMP_FEW": 3}),
    ("the band, 120 BPM", 1, 120, "datel", "irq", {"TEST_RX_TIME": 1}),
    ("half the wire, 120 BPM", 4, 120, "datel", "sparse", {"TEST_STAMP_FEW": 2}),  # (overload)
]


def build(out, scene, bpm, iface, more):
    defs = []
    for k, v in more.items():
        defs += ["-D", f"{k}={v}"]
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF[iface]}",
                    "-D", f"TEST_PLAY={scene}", "-D", f"TEST_SLAVE={FEED}",
                    "-D", "TEST_FEED_MASTER=1", "-D", f"TEST_TEMPO={bpm}", *defs,
                    "-o", out, "sid500.asm"], cwd=ROOT, check=True)


def stamped_messages(stamped):
    """[(message, time of its last byte, origins)] from [(byte, time,
    origin)]: channel messages, running status written out, with the set
    of origins of their bytes; realtime bytes left out."""
    out, status, cur, origins = [], 0, [], set()
    for b, t, o in stamped:
        if b >= 0xF8:
            continue
        if b >= 0x80:
            status, cur, origins = b, [b], {o}
        else:
            if not cur:
                cur, origins = [status], set()
            cur.append(b)
            origins.add(o)
        if cur and len(cur) == (2 if cur[0] & 0xE0 == 0xC0 else 3):
            out.append((tuple(cur), t, origins))
            cur = []
    return out


def thru_of(message, channel):
    """What thru sends for a message fed: on the channel, or None."""
    kind = message[0] & 0xF0
    if kind in (0xA0, 0xD0):
        return None
    return (kind | channel,) + message[1:]


def thru_lags(log, channel, errors):
    """The thru messages sent against the ones fed: the same, in order;
    returns their lags (cycles)."""
    fed = stamped_messages([(v, t, 0) for k, v, t in log if k == LOG_RX])
    want = [(thru_of(m, channel), t) for m, t, _ in fed]
    want = [(m, t) for m, t in want if m is not None]
    got = stamped_messages([(v, t, 0) for k, v, t in log if k == LOG_TX_THRU])
    lags = []
    for j, (m, t, _) in enumerate(got):
        if j >= len(want) or m != want[j][0]:
            errors.append(f"thru message {j} is {m}, fed {want[j][0] if j < len(want) else None}")
            break
        lags.append(t - want[j][1])
    end = max(t for _, _, t in log)
    missing = [t for _, t in want[len(got):] if t < end - LAG_MAX]
    if missing:
        errors.append(f"{len(missing)} thru messages never sent ({len(got)} of {len(want)} were)")
    if lags and max(lags) > LAG_MAX:
        errors.append(f"a thru message {max(lags) / CYCLES_MS:.1f} ms after it came in")
    if len(got) < 3 * len(tables.KEYS_PHRASE):
        errors.append(f"only {len(got)} thru messages in the log")
    if any(k == LOG_THRU_LOST for k, _, _ in log):
        errors.append("thru's queue was full: messages lost")
    if any(k == LOG_MARKS_FULL for k, _, _ in log):
        errors.append("the test's marks of thru's bytes overflowed (record.asm THRU_MARKS)")
    return lags


def lag_text(lags):
    if not lags:
        return "no thru message"
    return (f"thru {len(lags)} messages, lag {min(lags) / CYCLES_MS:.2f}.."
            f"{max(lags) / CYCLES_MS:.2f} ms (median {statistics.median(lags) / CYCLES_MS:.2f})")


def check_content(name, scene, log, stopped):
    errors = []
    patterns, tracks, order = tables.SCENES[scene]()
    channel = tracks[0][1]
    lags = thru_lags(log, channel, errors)
    both = stamped_messages([(v, t, k) for k, v, t in log if k in (tc.LOG_TX, LOG_TX_THRU)])
    mixed = [m for m, _, o in both if len(o) > 1]
    if mixed:
        errors.append(f"{len(mixed)} messages mix thru's bytes and the player's: {mixed[0]}")
    player_m = [m for m, _, o in both if o == {tc.LOG_TX}]
    if stopped:
        if player_m:
            errors.append(f"stopped, the player sent {player_m[0]}")
    else:
        player = pc.Player(patterns, tracks, order)
        data = []
        while len(data) < 3 * len(player_m) + 300:
            data += player.play()
        model = pc.messages(data)
        if player_m != model[:len(player_m)]:
            i = next(i for i, (a, b) in enumerate(zip(player_m, model)) if a != b)
            errors.append(f"the player's message {i} is {player_m[i]}, the model's {model[i]}")
    print(f"{name}: {lag_text(lags)} on channel {channel + 1}; {len(player_m)} of the "
          f"player's as the model's")
    return errors


def jitter_of(bpm, log):
    """(how far the ticks vary from their grid, the most a clock went out
    after its tick's interrupt), cycles."""
    ticks = [t for k, _, t in log if k == tc.LOG_TICK][1:]
    exact = tables.tick_cycles(bpm)
    late = [t - i * exact for i, t in enumerate(ticks)]
    clocks = [t for k, v, t in log if k == tc.LOG_TX and v == tc.CLOCK]
    after = [c - ticks[i - 1] for c in clocks
             if (i := bisect.bisect_right(ticks, c)) > 0]
    return max(late) - min(late), max(after)


def check_jitter(name, bpm, logs, base_logs):
    """The ticks and clocks with the keyboard played through, against the
    same build with Thru off (base_logs), the worst of JITTER_RUNS runs
    each (single runs' worst varied by ~500 cycles, Thru off too): the
    feed's own raster interrupt (the test's stand-in for the ACIA) already
    costs the ticks ~400 cycles, and a clock behind it ~400 more, so tc's
    limits are for what thru adds. A clock is measured from its own tick
    (the ticks' lateness apart). (Thru's bytes and the feed's aren't
    logged here: the marks' cost.)"""
    errors = []
    spread, after = (max(x) for x in zip(*(jitter_of(bpm, lg) for lg in logs)))
    base_spread, base_after = (max(x) for x in zip(*(jitter_of(bpm, lg) for lg in base_logs)))
    if spread - base_spread > THRU_TICK_ADDED_MAX:
        errors.append(f"thru adds {spread - base_spread:.0f} cycles to the ticks' spread "
                      f"(at most {THRU_TICK_ADDED_MAX})")
    if after - base_after > THRU_CLOCK_ADDED_MAX:
        errors.append(f"thru adds {after - base_after:.0f} cycles to a clock's time after its "
                      f"tick (at most {THRU_CLOCK_ADDED_MAX})")
    print(f"{name}: ticks off their grid within {spread:.0f} cycles (Thru off "
          f"{base_spread:.0f}), a clock at most {after:.0f} after its tick (Thru off "
          f"{base_after:.0f})")
    return errors


def rx_times(log):
    """Each byte received: the cycles from its LOG_RX to synth_rx_irq's end
    (LOG_RX_DONE; TEST_RX_TIME builds), the receive interrupt not
    interrupted (a Datel's IRQ)."""
    out, start = [], None
    for k, _, t in log:
        if k == LOG_RX:
            start = t
        elif k == LOG_RX_DONE and start is not None:
            out.append(t - start)
            start = None
    return out


def check_irq(name, logs, base_logs):
    """What thru adds to the receive interrupt's longest time (exact: no
    interrupt comes between): what a tick or a clock may wait for it.
    (The ticks' and clocks' own lateness, compared in the jitter runs,
    varies from run to run by more than this.)"""
    errors = []
    most = max(max(rx_times(lg)) for lg in logs)
    base = max(max(rx_times(lg)) for lg in base_logs)
    if most - base > THRU_IRQ_ADDED_MAX:
        errors.append(f"thru adds {most - base} cycles to the receive interrupt "
                      f"(at most {THRU_IRQ_ADDED_MAX})")
    print(f"{name}: a byte received, from its log entry to the hook's end at most {most} "
          f"cycles (Thru off {base}): thru adds {most - base}")
    return errors


def sparse_lag(scene, log, errors):
    """As play_check.lag_sparse, thru's bytes taking their wire slots: the
    player's worst added lag (cycles) and its song tick."""
    patterns, tracks, order = tables.SCENES[scene]()
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    song = ticks[next(i for i, t in enumerate(ticks) if t > start):]
    player = pc.Player(patterns, tracks, order)
    expect = []
    for k in range(len(song)):
        expect += [(b, k) for b in player.play()]
    others = sorted([t for v, t in sent if v == tc.CLOCK]
                    + [t for k, _, t in log if k == LOG_TX_THRU])
    stamped = [(v, t) for v, t in sent if v not in (tc.START, tc.CLOCK)]
    ready, wire, c = [], 0, 0
    for b, k in expect:
        r = max(song[k], wire)
        while c < len(others) and others[c] <= r:
            wire = max(wire, others[c]) + tc.BYTE_CYCLES
            r = max(song[k], wire)
            c += 1
        ready.append(r)
        wire = r + tc.BYTE_CYCLES
    worst, where = 0, None
    for j, (v, t) in enumerate(stamped):
        i = (j + 1) * pc.STAMP_EVERY - 1
        if i >= len(expect):
            break
        if v != expect[i][0]:
            errors.append(f"stamped byte {i} is {v:02x}, the model's {expect[i][0]:02x}")
            break
        if t - ready[i] > worst:
            worst, where = t - ready[i], expect[i][1]
    return worst, where


def check_sparse(name, scene, log, base_log):
    """The player's lag with the keyboard played through, against the same
    build with Thru off (base_log: the feed's raster interrupt, the test's
    stand-in for the ACIA, costs the player's busy 16ths ~20 ms there)."""
    errors = []
    lags = thru_lags(log, tables.SCENES[scene]()[1][0][1], errors)
    worst, where = sparse_lag(scene, log, errors)
    base, _ = sparse_lag(scene, base_log, errors)
    if worst - base > THRU_PLAYER_ADDED_MAX:
        errors.append(f"thru adds {worst - base} cycles to the player's lag "
                      f"(at most {THRU_PLAYER_ADDED_MAX})")
    print(f"{name}: the player's added lag at most {worst / CYCLES_MS:.2f} ms at song tick "
          f"{where} (Thru off {base / CYCLES_MS:.2f}), thru's bytes on the wire too; "
          f"{lag_text(lags)}")
    return errors


def run_pair(n, name, scene, bpm, iface, more, runs):
    """The program with Thru on and with it off, run `runs` times on each
    CIA model: ([logs], [Thru off's logs])."""
    logs = ([], [])
    for i, opts in enumerate((more, {**more, "TEST_THRU": 0})):
        prg = os.path.join(ROOT, f"thru-{n}-{i}.prg")
        build(prg, scene, bpm, iface, opts)
        try:
            for _ in range(runs):
                for _, cia in tc.CIA_MODELS:
                    logs[i].append(tc.run_log(prg, ARGS.seconds, cia, iface))
        finally:
            os.remove(prg)
    return logs


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=6, help="real seconds a run (warp)")
    a = ARGS = ap.parse_args()
    ok = True
    for n, (name, scene, bpm, iface, mode, more) in enumerate(RUNS):
        if mode == "irq":
            logs, base_logs = run_pair(n, name, scene, bpm, iface, more, 1)
            errors = check_irq(f"both CIAs, {name}, irq", logs, base_logs)
            for e in errors:
                print("   FAIL:", e)
            ok &= not errors
            continue
        if mode == "jitter":            # (reported: the test's own noise is larger)
            logs, base_logs = run_pair(n, name, scene, bpm, iface, more, JITTER_RUNS)
            for e in check_jitter(f"both CIAs, {JITTER_RUNS} runs each, {name}, jitter", bpm,
                                  logs, base_logs):
                print("   (reported, not checked: the runs' own spread is larger):", e)
            continue
        if mode == "sparse":            # (overload: reported, not checked)
            logs, base_logs = run_pair(n, name, scene, bpm, iface, more, 1)
            for (model, _), log, base_log in zip(tc.CIA_MODELS, logs, base_logs):
                for e in check_sparse(f"{model}, {name}, sparse", scene, log, base_log):
                    print("   (overload, not checked):", e)
            continue
        prg = os.path.join(ROOT, f"thru-{n}.prg")
        build(prg, scene, bpm, iface, more)
        try:
            for model, cia in tc.CIA_MODELS:
                log = tc.run_log(prg, a.seconds, cia, iface)
                errors = check_content(f"{model}, {name}, {mode}", scene, log,
                                       "TEST_AUTOSTART" in more)
                for e in errors:
                    print("   FAIL:", e)
                ok &= not errors
        finally:
            os.remove(prg)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
