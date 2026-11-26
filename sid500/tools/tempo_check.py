"""tempo_check.py - SID500: the tempo computed (src/size.asm tempo_period)
against tables.py's tempo_period and tempo_lead at every Tempo.

Builds a TEST_TEMPO_ALL program, which at start computes the period and
the render lead for each of the 201 Tempo values into the step grid's
table (src/size.asm tempo_dump), runs it in VICE and compares every byte.

    python tools/tempo_check.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import tables  # noqa: E402
from event_check import labels, run  # noqa: E402

TEMPO_DUMP, DONE = 0xE000, 0xA5         # src/size.asm


def main():
    prg = os.path.join(ROOT, "tempo-test.prg")
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_TEMPO_ALL=1",
                    "-l", prg + ".lbl", "-o", prg, "sid500.asm"], cwd=ROOT, check=True)
    try:
        assert labels(prg + ".lbl")["TEMPO_DUMP"] == TEMPO_DUMP
        n = tables.TEMPOS
        mem = run(prg, [(TEMPO_DUMP, TEMPO_DUMP + 4 * n)], seconds=2)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    if mem[TEMPO_DUMP + 4 * n] != DONE:
        print("FAIL: the dump didn't finish")
        return 1
    errors = []
    for v in range(n):
        bpm = tables.BPM_LOWEST + v
        latch, frac = tables.tempo_period(bpm)
        lead = tables.tempo_lead(bpm)
        got = [mem[TEMPO_DUMP + 4 * v + i] for i in range(4)]
        want = [frac, latch & 255, latch >> 8, lead]
        if got != want:
            errors.append(f"{bpm} BPM: {got}, not {want} (fraction, latch, lead)")
    print(f"{n} tempos, {len(errors)} wrong")
    for e in errors[:10]:
        print("   FAIL:", e)
    print("all passed" if not errors else "FAILED")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
