# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The demo videos: demos/video-demo.mp4 and demos/presets-video.mp4.

    python demos/video_demo.py [--seconds 47]
    python demos/video_demo.py --presets [--seconds 48]

--presets: pattern 2 (a short lead melody) plays from the start (TEST_SEQ=1
TEST_SEQ_PAT=1) on the parameter screen, and TEST_KEYS=20 steps through
every factory preset with C= + F3, one a bar.

Builds SID101 with TEST_KEYS=15 (src/test_scripts.asm: the keys a player
would press: the step screen, an empty pattern, a 16-step lead with slides
typed in, play; on the parameter screen a lead sound made a control at a
time, then the cutoff swept; it ends there, playing) and VIDEO_MARK=1 (a
call per video frame for the recorder), and records it in VICE with
c64tools/vicerec.py: every frame and the sound, 8580 SID. Needs 64tass,
x64sc and ffmpeg. SID303's demos/step_demo.py is the model.
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
    """The build number build.sh would give (git commits, + 1 if changed,
    with build.sh's list of what doesn't count)."""
    count = int(subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout)
    dirty = subprocess.run(["git", "status", "--porcelain", "--", ".", ":!*.prg", ":!*.d64",
                            ":!docs/*.pdf", ":!docs/screen*.png", ":!demos/*"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return count + (1 if dirty else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--presets", action="store_true", help="the presets video")
    ap.add_argument("--seconds", type=float, help="length of the video")
    ap.add_argument("--out")
    a = ap.parse_args()
    if a.presets:
        defines = ["TEST_KEYS=20", "TEST_SEQ=1", "TEST_SEQ_PAT=1"]
        seconds, out = 48, os.path.join(HERE, "presets-video.mp4")
    else:
        defines = ["TEST_KEYS=15"]
        seconds, out = 47, os.path.join(HERE, "video-demo.mp4")
    a.seconds = a.seconds or seconds
    a.out = a.out or out

    tmp = tempfile.mkdtemp(prefix="videodemo")
    prg = os.path.join(tmp, "sid101-video.prg")
    lbl = os.path.join(tmp, "sid101-video.lbl")
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", f"BUILD={build_number()}",
            "-D", "VIDEO_MARK=1"]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", lbl, "-o", prg, "sid101.asm"], cwd=ROOT, check=True)
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
