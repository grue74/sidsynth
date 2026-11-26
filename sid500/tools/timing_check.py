"""timing_check.py - SID500 stage A: the player's timer and MIDI out in VICE.

Builds TEST_LOG programs (src/timing.asm), runs each in VICE with a Datel
MIDI cartridge (no MIDI device behind it: VICE still paces the 6850, a
byte every BYTE_CYCLES: 315 cycles in the patched VICE), reads the log of player ticks and bytes written to
the ACIA (each stamped with CIA2 timer A, a cycle a count) and checks:

- the ticks: their average period is the tempo's exact tick, 1,231,560 /
  BPM cycles (the dither: no drift), each within the interrupt's latency;
- MIDI out: start, then a clock every second tick; each clock written
  within CLOCK_MAX cycles of its tick (the urgent queue: at most the bytes
  in the 6850 ahead of it), also behind the bursts of notes;
- nothing dropped: the bytes other than clock are exactly the bursts
  queued, in order;
- on both CIA models VICE emulates (old 6526, new 8521): no player tick
  lost (timer A), and how many of the core's 250 Hz ticks (timer B) the
  old CIA's timer B bug loses (an ICR read on the cycle before timer B
  runs out cancels its interrupt: the reason the player is on timer A);
- the bursts go out at the wire's pace: measured in builds that stamp only
  each burst's ends and the clocks (TEST_STAMP_FEW), since stamping every
  byte makes the transmit interrupt late itself.

    python tools/timing_check.py [--keep]
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, ROOT)
import tables  # noqa: E402  (the tempo tables)
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

LOG_START, LOG_PAGES = 0x7a00, 7     # src/timing.asm: two logs of five arrays of
LOG_SIZE = LOG_PAGES * 256              # LOG_PAGES pages
LOG_TICK, LOG_TX = 1, 2
LOG_STACK = 9                   # src/timing.asm: the stack more than half used
VICE_ARGS = {                   # the MIDI cartridge, no device behind it: VICE numbers
    "datel": "-midi -miditype 2 -midiout -1 -midiin -1",        # them one lower than
    "namesoft": "-midi -miditype 3 -midiout -1 -midiin -1",     # the core (P_MIDIIF)
}
MIDI_IF = {"datel": 3, "namesoft": 4}   # core/options.inc MIDI_IF_DEFAULT
CIA_MODELS = [("old CIA", 0), ("new CIA", 1)]            # VICE -ciamodel: 6526, 8521
TICK250_CYCLES = 3941           # the core's 250 Hz tick (TICK_LATCH + 1)
BYTE_CYCLES = vice_env.BYTE_CYCLES  # VICE's 6850: a byte every 10 bit times (the
                                # patched VICE, as hardware: 315), stock 9 (283)
CLOCK_MAX = 2 * BYTE_CYCLES + 300   # a clock written after its tick: the two bytes in
                                # the 6850 ahead of it, plus the interrupts' own time
BURST_NOTE, BURST_VELOCITY = 60, 100    # src/timing.asm
START, CLOCK, STOP = 0xFA, 0xF8, 0xFC
TICK_JITTER_MAX = 360           # a tick's interrupt late by at most this, cycles: it waits
                                # for the handlers already running or pending before it: the
                                # transmit handler with this log's 24-bit stamp (up to ~290
                                # cycles, a retried timer read included), the 250 Hz tick
                                # (~40), the interrupt's entry (7) and an instruction (7)
CLOCK_JITTER_MAX = 700          # clock gaps vary by at most this, cycles (design 4: 0.7 ms)
# with an NMI interface (Namesoft) every byte sent interrupts the timer's
# interrupt too, before it queues the clock (on an IRQ interface they
# take turns): measured with only the ticks and clocks stamped, ticks
# within ~480 cycles of the grid, clock gaps even within ~1 ms
NMI_TICK_JITTER_MAX = 600
NMI_CLOCK_JITTER_MAX = 1300        # (1,224 and 1,226 seen once each, before and after the
                                    # transport went in: VICE runs vary)
NMI_CLOCK_MAX = 2 * BYTE_CYCLES + 700
BYTE_MAX = BYTE_CYCLES + 67     # with every byte stamped, a burst's bytes on average at most
                                # this far apart: VICE sends one every BYTE_CYCLES if the
                                # transmit interrupt writes the next in time, and the stamp
                                # makes it ~130 cycles late, so behind another handler (the
                                # player's or the 250 Hz tick) a slot is lost: 290-334 seen
SLOTS_MAX = 2                   # without the stamps' cost (TEST_STAMP_FEW): a burst's last
                                # byte at most this many byte times later than the wire's pace
                                # would have it (0.57 ms in VICE): a byte written late behind
                                # another handler costs only its lateness, as VICE restarts
                                # its byte timer, and the clocks' stamps cost a little

# the runs: (name, defines, BPM, burst messages)
RUNS = [  # (name, BPM, burst messages, the MIDI cartridge: Datel IRQ, Namesoft NMI)
    ("120 BPM, quiet", 120, 0, "datel"),
    ("120 BPM, 16-note bursts", 120, 16, "datel"),
    ("240 BPM, 16-note bursts", 240, 16, "datel"),
    ("40 BPM, 16-note bursts", 40, 16, "datel"),
    ("Namesoft (NMI), 120 BPM, 16-note bursts", 120, 16, "namesoft"),
    ("Namesoft (NMI), 240 BPM, 16-note bursts", 240, 16, "namesoft"),
]


def build(out, bpm, burst, few=0, iface="datel"):
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1", "-D", f"TEST_STAMP_FEW={few}",
            "-D", f"MIDI_IF_DEFAULT={MIDI_IF[iface]}",
            "-D", f"TEST_TEMPO={bpm}", "-D", f"TEST_BURST={burst}", "-o", out, "sid500.asm"]
    subprocess.run(args, cwd=ROOT, check=True)


LOG_MARK = b"SID500LOG"         # src/timing.asm log_layout: the log's page, its pages


def log_layout(prg):
    """(start, size of an array) of prg's log, from its log_layout mark (the
    heavy scene's builds have a smaller log than the others)."""
    data = open(prg, "rb").read()
    i = data.find(LOG_MARK)
    assert i >= 0, f"{prg}: no log_layout mark"
    return data[i + len(LOG_MARK)] << 8, data[i + len(LOG_MARK) + 1] * 256


def read_log(data, first, size=None):
    """One log of the program's two (src/timing.asm): its entries as
    (kind, value, time), the 24-bit stamps (CIA2 timers B and A, counting
    down) as cycles since the timers started (unwrapped: entries come at
    most a few ticks apart)."""
    size = size or LOG_SIZE

    def array(n):
        return data[first + n * size:first + (n + 1) * size]
    kinds, values, los, mids, tops = (array(n) for n in range(5))
    out, last, now = [], None, 0
    for i in range(size):
        if kinds[i] == 0:
            break
        stamp = los[i] | mids[i] << 8 | tops[i] << 16
        if last is None:
            now = 0xFFFFFF - stamp          # (both logs start in the first 17 s)
        else:
            now += (last - stamp) & 0xFFFFFF
        last = stamp
        out.append((kinds[i], values[i], now))
    return out


def run_log(prg, seconds, cia=0, iface="datel"):
    """Run prg in VICE (a Datel or a Namesoft cartridge) and return the
    log: [(kind, value, time)], both of the program's logs merged in time
    order (time in cycles, from the first entry)."""
    start, size = log_layout(prg)
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg,
                          f"m {start:04x} {start + 10 * size - 1:04x}",
                          "--seconds", str(seconds),
                          "--vice-args", f"{VICE_ARGS[iface]} -ciamodel {cia}"],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            data += bytes(int(b, 16) for b in m.group(2).split())
    log_a, log_b = read_log(data, 0, size), read_log(data, 5 * size, size)
    # merged up to where the first one ends (the other went on unseen)
    ends = [lg[-1][2] for lg in (log_a, log_b) if lg]
    end = min(ends) if ends else 0
    log = sorted((e for e in log_a + log_b if e[2] <= end), key=lambda e: e[2])
    deep = [v for k, v, _ in log_a if k == LOG_STACK]
    if deep:            # (every check fails on it: interrupts nested too deep)
        raise AssertionError(f"{prg}: the stack more than half used (down to ${min(deep):02x})")
    t0 = log[0][2] if log else 0
    return [(k, v, t - t0) for k, v, t in log]


def check(name, bpm, burst, log, cia, mode="all"):
    """mode "all": everything; "content" (an NMI interface, every byte
    stamped: the stamps in the NMI make the timing worse than it is): what
    was sent only; "timing" (an NMI interface, only the ticks and the
    realtime bytes stamped): the ticks and the clock, NMI_* bounds."""
    errors = []
    timing, content = mode in ("all", "timing"), mode in ("all", "content")
    tick_max = NMI_TICK_JITTER_MAX if mode == "timing" else TICK_JITTER_MAX
    clock_max = NMI_CLOCK_JITTER_MAX if mode == "timing" else CLOCK_JITTER_MAX
    lag_max = NMI_CLOCK_MAX if mode == "timing" else CLOCK_MAX
    ticks = [t for k, _, t in log if k == LOG_TICK]
    counts = [v for k, v, _ in log if k == LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == LOG_TX]
    exact = tables.tick_cycles(bpm)

    # the ticks: average period exact, each on the exact grid within the
    # interrupt's latency. The first is left out: its interrupt waits for
    # the start-up to allow interrupts (screen_init, midi_init)
    grid = ticks[1:]
    mean = (grid[-1] - grid[0]) / (len(grid) - 1)
    # (a lost tick would show as a whole period late from then on)
    late = [t - i * exact for i, t in enumerate(grid)]
    spread = max(late) - min(late)
    # (the ends' own latency moves the average by up to spread / ticks)
    if abs(mean - exact) > max(0.5, spread / (len(grid) - 1)) + 1e-9:   # (equal: rounding)
        errors.append(f"average tick {mean:.3f} cycles, exact {exact:.3f}")
    if timing and spread > tick_max:
        errors.append(f"ticks vary by {spread:.0f} cycles from the grid (at most {tick_max})")

    # the core's 250 Hz ticks (timer B) between the first and last player
    # tick, against the time: the ones the old CIA's bug lost (to +-1: the
    # ends aren't in step with the 250 Hz phase)
    taken = sum((b - a) & 0xFF for a, b in zip(counts[1:], counts[2:]))
    lost250 = round((grid[-1] - grid[0]) / TICK250_CYCLES) - taken
    if cia == 1 and abs(lost250) > 1:
        errors.append(f"the new CIA lost {lost250} 250 Hz ticks")

    # MIDI out: start first, then a clock per two ticks, each soon after
    # its tick (the tick the start went out at is ticks[s])
    if not sent or sent[0][0] != START:
        errors.append("MIDI start isn't the first byte sent")
    clocks = [t for v, t in sent if v == CLOCK]
    start_tick = next(i for i, t in enumerate(ticks) if t > sent[0][1]) - 1
    clock_ticks = ticks[start_tick + 1::2]
    lags = [c - t for c, t in zip(clocks, clock_ticks)]
    if len(clocks) < len(clock_ticks) - 1:
        errors.append(f"{len(clocks)} clocks for {len(clock_ticks)} clock ticks")
    if timing and (min(lags) < 0 or max(lags) > lag_max):
        errors.append(f"clock lag {min(lags)}..{max(lags)} cycles (at most {lag_max})")
    gaps = [b - a for a, b in zip(clocks, clocks[1:])]
    jitter = max(gaps) - min(gaps)
    if timing and jitter > clock_max:
        errors.append(f"clock gaps vary by {jitter} cycles (at most {clock_max})")

    # nothing dropped: the other bytes are the bursts, in order
    notes = [v for v, _ in sent if v not in (START, CLOCK)]
    expect = []
    velocity = 0
    while len(expect) < len(notes):
        velocity ^= BURST_VELOCITY
        for ch in range(burst):
            expect += [0x90 | ch, BURST_NOTE, velocity]
    if content and notes != expect[:len(notes)]:
        first = next(i for i, (a, b) in enumerate(zip(notes, expect)) if a != b)
        errors.append(f"note bytes differ from the bursts at byte {first}")
    times = [t for _, t in sent]
    spacing = [b - a for a, b in zip(times, times[1:])]
    # the bursts' pace: each burst (bytes under 2000 cycles apart) from its
    # first byte to its last, per byte
    paces, first = [], 0
    for i in range(1, len(times) + 1):
        if i == len(times) or times[i] - times[i - 1] > 2000:
            if i - first > 10:
                paces.append((times[i - 1] - times[first]) / (i - 1 - first))
            first = i
    pace = max(paces) if paces else 0
    if mode == "all" and pace > BYTE_MAX:
        errors.append(f"a burst went out at {pace:.0f} cycles a byte (the wire: {BYTE_CYCLES})")

    print(f"{name}: {len(ticks)} ticks, average {mean:.3f} cycles (exact {exact:.3f}), "
          f"on the grid within {spread:.0f}; 250 Hz ticks lost {lost250} (+-1); {len(clocks)} clocks, lag {min(lags)}..{max(lags)} "
          f"cycles, gaps vary by {jitter} ({jitter / 985.248:.2f} ms); {len(notes)} note "
          f"bytes, bursts at {pace:.0f} cycles a byte at most")
    for e in errors:
        print("   FAIL:", e)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=3)
    a = ap.parse_args()
    ok = True
    for i, (name, bpm, burst, iface) in enumerate(RUNS):
        nmi = iface == "namesoft"
        # (an NMI interface: what is sent from a build stamping every byte,
        # the timing from one stamping only the ticks and the clocks)
        for mode, few in ((("content", 0), ("timing", 3)) if nmi else (("all", 0),)):
            prg = os.path.join(ROOT, f"timing-{i}.prg")
            build(prg, bpm, burst, few=few, iface=iface)
            try:
                for model, cia in CIA_MODELS:
                    ok &= check(f"{model}, {name}{', ' + mode if nmi else ''}", bpm, burst,
                                run_log(prg, a.seconds, cia, iface), cia, mode)
            finally:
                os.remove(prg)
    # the bursts' pace without the stamps' cost: only each burst's first
    # and last status bytes stamped, 3 * 15 bytes apart, and the clocks
    # that went out between them
    for bpm in (120, 240):
        prg = os.path.join(ROOT, "timing-few.prg")
        build(prg, bpm, 16, few=1)
        try:
            log = run_log(prg, a.seconds)
        finally:
            os.remove(prg)
        stamps = [(v, t) for k, v, t in log if k == LOG_TX]
        lags = []
        for i, (v, t) in enumerate(stamps):
            if v == 0x90:
                j = next((j for j in range(i + 1, len(stamps)) if stamps[j][0] != CLOCK), None)
                if j is None:
                    break               # (the log ended in the middle of this burst)
                if stamps[j][0] == 0x9F:
                    nbytes = 45 + j - i - 1     # the notes' bytes and the clocks between
                    lags.append(stamps[j][1] - t - nbytes * BYTE_CYCLES)
        worst = max(lags)
        print(f"{bpm} BPM bursts, unstamped: {len(lags)} bursts, the last byte at most "
              f"{worst} cycles ({worst / BYTE_CYCLES:.2f} byte times, {worst / 985.248:.2f} ms) "
              f"behind the wire's pace")
        if worst > SLOTS_MAX * BYTE_CYCLES:
            print(f"   FAIL: more than {SLOTS_MAX} byte times behind")
            ok = False
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
