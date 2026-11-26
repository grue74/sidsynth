"""locate_check.py - SID500 stage G: a slave's song position through the
song's scenes, in VICE.

The oracle is the program itself: a master build plays scene test 1 (the
band as scene 1, scenes 2 and 3 after it, Song on: tables.py SCENE_TESTS:
1/4 three times, 3/4, 5/8, round again: a round of 34 16ths) from its
start; a slave build of the same song is fed song positions and continues
(tables.py feed 15). From each located 16th the slave must send what the
master sent from that tick on (src/locate.asm: as the song played from its
start), less the note offs of notes the master began before it (the
located song starts with nothing sounding). Positions 20 (in scene 2), 30
(scene 3) and 46 (the song once round, scene 2), each with swing 0 and 15;
and the same with Song off (scene test 3: scene 1 looping, each track at
its own length).

The take armed as slave (src/locate.asm count_arm; design 5e): C= R
stopped at start-up on track 9 (an empty cell: a new pattern), then song
positions 20 and 37 and a continue (tables.py feed 16), a played part:
the notes before the master's first tick left out, every one after it
stamped at the tick heard when its last byte came (within one), the take's
start logged again at 16th 37's pass, merged at its loops' ends, ended by
the stop; and disarmed by SPACE or by Clock made the C64's before the
continue: nothing stamped, the take ended.

    python tools/locate_check.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402
import play_check as pc  # noqa: E402

LOG_TICK, LOG_RX = 1, 7
LOG_REC_STAMP, LOG_REC_START, LOG_REC_MERGE, LOG_REC_FINAL, LOG_REC_END = 26, 27, 28, 29, 30
ARM_FEED, ARM_TRACK = 16, 9
ARM_RUNS = [("armed, two song positions, continue", 0), ("armed, then SPACE", 1),
            ("armed, then Clock the C64's", 2)]
SPP, CONTINUE, STOP = 0xF2, 0xFB, 0xFC
STEP = 12
FEED = 15
COMPARED = 40                   # ticks compared after each continue
RUNS = [  # (name, tables.py SCENE_TESTS' test, swing)
    ("Song on, three scenes", 1, 0), ("Song on, three scenes, swing 15", 1, 15),
    ("Song off (the start scene looping)", 3, 0)]


def build(out, slave, swing, test):
    defs = ["-D", f"TEST_SLAVE={FEED}"] if slave else []
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF['datel']}", "-D", "TEST_PLAY=1",
                    "-D", f"TEST_SCENES={test}", "-D", f"TEST_SWING={swing}",
                    "-D", "TEST_TEMPO=120", *defs, "-o", out, "sid500.asm"],
                   cwd=ROOT, check=True)


def master_ticks(log):
    """The master's messages by tick: [[message, ...] per tick from 0], each
    message at the tick its first byte was sent in (a message's bytes may
    straddle a tick's start)."""
    ticks, status, cur = [], 0, []
    for k, v, _ in log:
        if k == LOG_TICK:
            ticks.append([])
        elif k == tc.LOG_TX and v < 0xF8 and ticks:
            if v >= 0x80:
                status, cur = v, [v]
                at = len(ticks) - 1
            else:
                if not cur:
                    cur, at = [status], len(ticks) - 1
                cur.append(v)
            if cur and len(cur) == (2 if cur[0] & 0xE0 == 0xC0 else 3):
                ticks[at].append(tuple(cur))
                cur = []
    return ticks[1:]                    # (the first: MIDI start's, before tick 0)


def expected(ticks, start, n):
    """The master's messages from tick start for n ticks, less the offs of
    notes begun before start."""
    sounding = set()
    for t in range(start):
        for m in ticks[t]:
            key = (m[0] & 0x0F, m[1]) if m[0] & 0xE0 == 0x80 else None
            if key and m[0] & 0xF0 == 0x90 and m[2]:
                sounding.add(key)
            elif key:
                sounding.discard(key)
    out = []
    for t in range(start, start + n):
        for m in ticks[t]:
            key = (m[0] & 0x0F, m[1]) if m[0] & 0xE0 == 0x80 else None
            is_off = key and (m[0] & 0xF0 == 0x80 or m[2] == 0)
            if is_off and key in sounding:
                sounding.discard(key)
                continue
            if key and not is_off:
                sounding.discard(key)
            out.append(m)
    return out


def slave_stretches(log):
    """[(the 16th located, the messages sent after its continue up to the
    next stop)]."""
    fed = [(v, t) for k, v, t in log if k == LOG_RX]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX and v < 0xF8]
    out = []
    for i, (v, t) in enumerate(fed):
        if v != CONTINUE:
            continue
        spp = next((fed[j + 1][0] | fed[j + 2][0] << 7 for j in range(i - 1, -1, -1)
                    if fed[j][0] == SPP), None)
        end = next((t2 for v2, t2 in fed[i + 1:] if v2 == STOP), None)
        data = [b for b, t2 in sent if t2 > t and (end is None or t2 < end)]
        out.append((spp, pc.messages(data)))
    return out


def build_arm(out, cancel):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF['datel']}", "-D", "TEST_PLAY=1",
                    "-D", f"TEST_SLAVE={ARM_FEED}", "-D", f"TEST_ARM={ARM_TRACK}",
                    "-D", f"TEST_ARM_CANCEL={cancel}", "-D", "TEST_TEMPO=120",
                    "-o", out, "sid500.asm"], cwd=ROOT, check=True)


def pairs(log, kind):
    """The (low, high) pairs logged as kind, as 16-bit numbers."""
    vals = [v for k, v, _ in log if k == kind]
    return [vals[i] | vals[i + 1] << 8 for i in range(0, len(vals) - 1, 2)]


def check_arm(name, cancel, log):
    errors, notes = [], []
    fed = [(v, t) for k, v, t in log if k == LOG_RX]
    stamps = pairs(log, LOG_REC_STAMP)
    starts = pairs(log, LOG_REC_START)
    ends = [v for k, v, _ in log if k == LOG_REC_END]
    merges = [v for k, v, _ in log if k in (LOG_REC_MERGE, LOG_REC_FINAL)]
    if not ends:
        errors.append("the take didn't end")
    if cancel:
        if stamps:
            errors.append(f"{len(stamps)} messages stamped, disarmed")
        notes.append(f"nothing stamped, the take ended: {bool(ends)}")
        return errors, notes
    cont = next(t for v, t in fed if v == 0xFB)
    c0 = next(t for v, t in fed if v == 0xF8 and t > cont)
    half = tables.clock_gap(120) / 2
    first = tables.ARM_POSITIONS[-1] * STEP
    msgs, status, cur = [], 0, []          # each fed message, when its last byte came
    for v, t in fed:
        if v >= 0xF8 or v in (0xF2, 0xFB, 0xFC):
            if v == 0xF2:
                status, cur = v, []
            continue
        if v >= 0x80:
            status, cur = v, [v]
            continue
        if status == 0xF2:
            continue
        cur.append(v)
        if len(cur) == 3:
            msgs.append((tuple(cur), t))
            cur = [status]
    after = [(m, t) for m, t in msgs if t > c0]
    before = [(m, t) for m, t in msgs if t <= c0]
    if len(stamps) != len(after):
        errors.append(f"{len(stamps)} stamps, {len(after)} messages after the first tick "
                      f"({len(before)} before it)")
    worst = 0
    for (m, t), got in zip(after, stamps):
        want = first + (t - c0) / half
        worst = max(worst, abs(got - want))
        if abs(got - want) > 1.01:
            errors.append(f"{m} at tick {want:.2f}: stamped {got}")
    if not starts or starts[-1] != first:
        errors.append(f"the take's start {starts}, not {first} last")
    if len(merges) < 2:
        errors.append(f"{len(merges)} merges")
    notes.append(f"{len(before)} messages left out before the first tick, {len(stamps)} "
                 f"stamped (worst {worst:.2f} ticks off), start {starts[-1] if starts else None}"
                 f", {len(merges)} merges")
    return errors, notes


def main():
    ok = True
    for name, cancel in ARM_RUNS:
        prg = os.path.join(ROOT, "locate-t.prg")
        try:
            build_arm(prg, cancel)
            log = tc.run_log(prg, 8)
        finally:
            if os.path.exists(prg):
                os.remove(prg)
        errors, notes = check_arm(name, cancel, log)
        print(f"{name}: " + "; ".join(notes))
        for e in errors:
            print("   FAIL:", e)
        ok &= not errors
    for name, test, swing in RUNS:
        prg = os.path.join(ROOT, "locate-t.prg")
        try:
            build(prg, False, swing, test)
            ticks = master_ticks(tc.run_log(prg, 12))
            build(prg, True, swing, test)
            stretches = slave_stretches(tc.run_log(prg, 12))
        finally:
            if os.path.exists(prg):
                os.remove(prg)
        errors = []
        want_spps = [spp for spp in tables.FEED_POSITIONS_SONG]
        if [s for s, _ in stretches] != want_spps:
            errors.append(f"continues after song positions {[s for s, _ in stretches]}, "
                          f"not {want_spps}")
        notes, compared = [], 0
        for spp, got in stretches:
            start = spp * STEP
            if start + COMPARED > len(ticks):     # (the log full: the denser song's)
                notes.append(f"16th {spp}: past the master's log")
                continue
            want = expected(ticks, start, COMPARED)
            if got[:len(want)] != want:
                k = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]),
                         min(len(got), len(want)))
                errors.append(f"16th {spp}: message {k} is "
                              f"{got[k] if k < len(got) else None}, the master's "
                              f"{want[k] if k < len(want) else None}")
            notes.append(f"16th {spp}: {len(want)} messages as the master's")
            compared += 1
        if compared < 2:
            errors.append(f"only {compared} song positions within the master's log")
        print(f"{name}: the master's log {len(ticks)} ticks; " + "; ".join(notes))
        for e in errors:
            print("   FAIL:", e)
        ok &= not errors
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
