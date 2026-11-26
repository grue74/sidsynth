"""synth_latency.py - the family's synths: the latency from MIDI in to the
SID, measured in headless VICE.

Each synth (../sid303, ../sid808, ../sid101) is built as it is, in a copy
whose core is this project's (the same core, byte-identical builds: python
tools/core_identical.py), with the core's TEST_RX_FEED and TEST_RX_NOTES
test options: a note on and its note off fed through the real receive
interrupt (the raster interrupt standing in for the ACIA), each message's
bytes a wire's byte apart, at varying places in the frame and so anywhere
in the synth's tick; as each message's last byte comes in, a marker goes
to SID register $1F. Headless VICE's sound dump stamps every SID write in
cycles, so from each marker:

- gate: the first control-register write that opens a voice's gate (the
  note's envelope begins);
- pitch: the first write of a voice's frequency (the note's own pitch:
  before it the voice may sound at the last note's);
- sound: when the note is heard: the gate for SID303 and SID101; SID808
  holds the waveform until the envelope settles (MUTE_SETTLE), so its
  first write giving a gated voice a waveform after the gate;
- off: from a note off's marker to the gate closing.

The wire itself adds a message's bytes before the marker: a note on is 3
bytes, ~0.96 ms at 31,250 baud (0.64 ms with running status), not counted
here.

    python tools/synth_latency.py [--seconds S] [--raw SYNTH]
"""
import argparse
import os
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECTS = os.path.dirname(ROOT)
HEADLESS = os.path.join(PROJECTS, "c64tools", "vice-headless", "x64.exe")
CYCLES_MS = 985.248
MARK_REG = 0x1F
CTRL = {4: 0, 11: 1, 18: 2}                 # control registers: voice
FREQ = {0: 0, 1: 0, 7: 1, 8: 1, 14: 2, 15: 2}
SYNTHS = [  # (name, the note fed, every other one)
    ("sid303", 60, 67), ("sid808", 36, 36), ("sid101", 60, 67)]
ONLY = os.environ.get("LATENCY_ONLY")


def version_defs(src):
    """SID808's build passes its version (build.sh: VERSION)."""
    path = os.path.join(src, "VERSION")
    if not os.path.exists(path):
        return []
    major, minor, patch = open(path).read().strip().split(".")
    return ["-D", f"V_MAJOR={major}", "-D", f"V_MINOR={minor}", "-D", f"V_PATCH={patch}"]


def build(name, note, note2, work):
    """The synth's latency build in a copy at work/name, this project's core."""
    src = os.path.join(PROJECTS, name)
    dst = os.path.join(work, name)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(
        ".git", "core", "demos", "docs", "proto", "*.prg", "*.d64", "*.lst", "*.lbl"))
    shutil.copytree(os.environ.get("LATENCY_CORE", os.path.join(os.path.dirname(ROOT), "core")),
                    os.path.join(dst, "core"),
                    ignore=shutil.ignore_patterns(".git", "__pycache__"))
    subprocess.run([sys.executable, "tables.py"], cwd=dst, check=True,
                   stdout=subprocess.DEVNULL)
    prg = os.path.join(dst, "lat.prg")
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "BUILD=0",
                    *version_defs(src), "-D", "TEST_RX_FEED=1", "-D", "TEST_RX_NOTES=1",
                    "-D", f"TEST_RX_NOTE={note}", "-D", f"TEST_RX_NOTE2={note2}", "-o", prg, f"{name}.asm"],
                   cwd=dst, check=True)
    return prg


def dump(prg, seconds):
    """[(cycle, register, value)] of every SID write in a headless run."""
    for _ in range(3):
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copy(prg, os.path.join(tmp, "t.prg"))
            subprocess.run([HEADLESS, "-default", "-warp", "-soundwarpmode", "0",
                            "-drive8type", "0", "-sounddev", "dump", "-soundarg", "dump.txt",
                            "-limitcycles", str(int(seconds * 985248)),
                            "-autostartprgmode", "1", "-autostart", "t.prg"],
                           cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=300)
            writes, cycle = [], 0
            path = os.path.join(tmp, "dump.txt")
            if os.path.exists(path):
                for line in open(path):
                    delta, reg, value = (int(v) for v in line.split())
                    cycle += delta
                    writes.append((cycle, reg, value))
        if writes:
            return writes
    return writes


def measure(name, writes):
    """Per note on: gate (a voice's gate opening), pitch (a voice given a
    frequency other than its own before the note and not a parking value,
    0 or $FFFF), sound (both: the later), cycles from its marker; per note
    off: shut (a gate closing)."""
    ctrl, freq = [0, 0, 0], [0, 0, 0]
    notes, offs = [], []
    pending, before = None, None
    for c, r, v in writes:
        if r == MARK_REG:
            pending = {"kind": v, "at": c, "gate": None, "pitch": None, "shut": None}
            before = list(freq)
            (notes if v == 1 else offs).append(pending)
            continue
        if r in CTRL:
            k = CTRL[r]
            was, ctrl[k] = ctrl[k], v
            if pending and pending["kind"] == 1 and pending["gate"] is None                     and v & 1 and not was & 1:
                pending["gate"] = c - pending["at"]
            if pending and pending["kind"] == 2 and pending["shut"] is None                     and was & 1 and not v & 1:
                pending["shut"] = c - pending["at"]
        if r in FREQ:
            k = FREQ[r]
            freq[k] = (freq[k] & 0xFF00 | v) if r in (0, 7, 14) else (freq[k] & 0xFF | v << 8)
            if pending and pending["kind"] == 1 and pending["pitch"] is None:
                if name == "sid808":    # (parked until then: the first after the gate)
                    if pending["gate"] is not None and r not in (0, 7, 14):
                        pending["pitch"] = c - pending["at"]
                elif freq[k] not in (0, 0xFFFF, before[k]) and r not in (0, 7, 14):
                    pending["pitch"] = c - pending["at"]
    for n in notes:
        n["sound"] = max(n["gate"], n["pitch"]) if None not in (n["gate"], n["pitch"]) else None
    return notes, offs


def stats(values):
    v = [x / CYCLES_MS for x in values if x is not None]
    if not v:
        return "none"
    return f"{min(v):.2f}-{max(v):.2f} ms (median {statistics.median(v):.2f}, n {len(v)})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=30, help="emulated seconds a synth")
    ap.add_argument("--raw", help="print one synth's SID writes around its first notes")
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as work:
        for name, note, note2 in SYNTHS:
            if a.raw and a.raw != name or ONLY and ONLY != name:
                continue
            writes = dump(build(name, note, note2, work), a.seconds)
            if a.raw:
                marks = [c for c, r, _ in writes if r == MARK_REG][:4]
                for c, r, v in writes:
                    if any(m - 2000 <= c <= m + 30000 for m in marks):
                        print(f"{c:10d} {r:2d} {v:3d}" + ("   <- marker" if r == MARK_REG else ""))
                continue
            notes, offs = measure(name, writes)
            print(f"{name} (note {note}): {len(notes)} notes")
            print(f"   gate open:  {stats(n['gate'] for n in notes)}")
            print(f"   pitch:      {stats(n['pitch'] for n in notes)}")
            print(f"   sound (gate and pitch): {stats(n['sound'] for n in notes)}")
            print(f"   the last note's pitch heard (gate to pitch): "
                  f"{stats(max(0, n['pitch'] - n['gate']) for n in notes if n['sound'] is not None)}")
            print(f"   gate shut:  {stats(n['shut'] for n in offs)}")


if __name__ == "__main__":
    sys.exit(main())
