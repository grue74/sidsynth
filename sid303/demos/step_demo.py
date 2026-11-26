# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The step sequencer demo video: demos/step-demo.mp4.

    python demos/step_demo.py [--seconds 46]

Builds SID303 with TEST_KEYS=14 (src/test_scripts.asm: the keys a player
would press: the step screen, an empty pattern, a 16-step acid loop typed
in, play; on the parameter screen the sound made harsher a control at a
time, then the cutoff swept; it ends there, playing) and VIDEO_MARK=1
(a call per video frame for the recorder), and records it in VICE with
c64tools/vicerec.py: every frame and the sound, 8580 SID. Needs 64tass,
x64sc and ffmpeg.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")


def build_number():
    """The build number build.sh would give (git commits, + 1 if changed)."""
    count = int(subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout)
    dirty = subprocess.run(["git", "status", "--porcelain", "--", ".", ":!*.prg", ":!*.d64"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return count + (1 if dirty else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seconds", type=float, default=46, help="length of the video")
    ap.add_argument("--out", default=os.path.join(HERE, "step-demo.mp4"))
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="stepdemo")
    prg = os.path.join(tmp, "sid303-demo.prg")
    lbl = os.path.join(tmp, "sid303-demo.lbl")
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", f"BUILD={build_number()}",
                    "-D", "TEST_KEYS=14", "-D", "VIDEO_MARK=1", "-l", lbl, "-o", prg,
                    "sid303.asm"], cwd=ROOT, check=True)
    frame = None
    with open(lbl) as f:
        for line in f:
            m = re.match(r"video_frame\s*=\s*\$([0-9a-fA-F]+)", line)
            if m:
                frame = m.group(1)
    subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicerec.py"), prg, a.out,
                    "--frame-addr", frame, "--seconds", str(a.seconds), "--sid", "8580",
                    "--skip", "1"], check=True)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
