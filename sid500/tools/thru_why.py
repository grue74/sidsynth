"""thru_why.py - SID500: where thru's lag goes (docs/latency.md). For each
thru message its wait split into the wire busy with bytes sent before it
(the player's, the clock) and the wire idle (the program holding it back),
and the worst message's timeline. Runs thru_check's content build.

    python tools/thru_why.py SCENE BPM [CIA]   (e.g. 1 240: the band)
"""
import os
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import thru_check as th  # noqa: E402
import timing_check as tc  # noqa: E402
import tables  # noqa: E402

scene, bpm = int(sys.argv[1]), int(sys.argv[2])
cia = int(sys.argv[3]) if len(sys.argv) > 3 else 0
prg = os.path.join(ROOT, "thru-why.prg")
th.build(prg, scene, bpm, "datel", {})
try:
    log = tc.run_log(prg, 6, cia, "datel")
finally:
    os.remove(prg)
MS = th.CYCLES_MS
B = tc.BYTE_CYCLES
fed = th.stamped_messages([(v, t, 0) for k, v, t in log if k == th.LOG_RX])
ch = tables.SCENES[scene]()[1][0][1]
want = [(th.thru_of(m, ch), t) for m, t, _ in fed]
want = [(m, t) for m, t in want if m is not None]
got = th.stamped_messages([(v, t, 0) for k, v, t in log if k == th.LOG_TX_THRU])
sent = sorted((t, k, v) for k, v, t in log if k in (tc.LOG_TX, th.LOG_TX_THRU))
ticks = [t for k, _, t in log if k == tc.LOG_TICK]
rows = []
for (m, tout, _), (_, tin) in zip(got, want):
    # the bytes whose stamps fall in (tin, tout - 3 bytes]: before thru's own
    first_own = tout - 2 * B
    busy = sum(1 for t, k, v in sent if tin < t < first_own - B / 2) * B
    wait = tout - tin
    nt = sum(1 for t in ticks if tin < t < tout)
    rows.append((wait, busy, nt, m))
rows.sort(reverse=True)
print(f"scene {scene}, {bpm} BPM, {len(rows)} thru messages; lag median "
      f"{statistics.median(r[0] for r in rows) / MS:.2f} ms")
print("worst: lag ms, wire busy before it ms, idle ms (incl. its own 3 bytes ~1 ms), ticks between")
for wait, busy, nt, m in rows[:12]:
    print(f"  {wait / MS:6.2f}  {busy / MS:6.2f}  {(wait - busy) / MS:6.2f}  {nt}  {m}")
idle = [(w - b) / MS for w, b, _, _ in rows]
print(f"idle part: median {statistics.median(idle):.2f} ms, most {max(idle):.2f}")

# the worst message's timeline: the ticks and the bytes sent from its arrival
wait, busy, nt, m = rows[0]
for (mm, tout, _), (_, tin) in zip(got, want):
    if tout - tin == wait:
        break
print(f"\nthe worst {m}: in at {tin:.0f}, out at {tout:.0f}")
ev = sorted([(t, 'TICK', v) for k, v, t in log if k == tc.LOG_TICK] +
            [(t, 'thru' if k == th.LOG_TX_THRU else 'tx', v) for k, v, t in log
             if k in (tc.LOG_TX, th.LOG_TX_THRU)])
for t, k, v in ev:
    if tin - 2000 <= t <= tout + 500:
        print(f"  {(t - tin) / MS:7.2f} ms  {k:4} {v:02x}")
