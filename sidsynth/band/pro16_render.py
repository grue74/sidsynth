# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pro-16 playing the cover, rendered frame by frame (emulated time) into a
video: the screen of every PAL frame from the start of playback.

    python pro16_render.py work/trip2jupiter.d64 work/video/pro16.mp4 [--seconds 166]

Pro-16 (pro16.py, its MIDI on the virtual ports) loads the song from the disk; RETURN
starts it. Pro-16 has no frame mark of its own, so its playback loop's
RUN/STOP read (STOPCHECK, called all the time while it plays and only
then) carries two checkpoints, used in turn: "the beam below the text"
(raster line > 250: the frame is whole) takes the screenshot, "the beam at
the top" re-arms for the next frame. The cycle counter (the monitor's
stopwatch) numbers each grab's frame; a frame without one repeats the
last picture. Frame 0 is the first grab: the start of playback.
"""
import argparse
import sys
import os
import re
import shutil
import subprocess
import time

import vice_band
import vmidi
from pro16 import Pro16, STOPCHECK
from play_band import load_song
from songs import pick

FRAME_CYCLES = 19656
REGS = re.compile(r"\.;([0-9a-f]{4}) .* (\d+)\s+(\d+)\s+(\d+)\s*$", re.I | re.M)


def regs(m):
    """(raster line, stopwatch cycles) from the register line."""
    r = m.cmd("r")
    line = [l for l in r.splitlines() if l.startswith(".;")][-1].split()
    return int(line[-3], 16) if False else int(line[-3]), int(line[-1])


def run_to_break(m):
    """Continue until a checkpoint stops the CPU (read up to the prompt)."""
    m.s.sendall(b"x\n")
    data = b""
    m.s.settimeout(30)
    while not m.PROMPT.search(data):
        data += m.s.recv(65536)
    m.s.settimeout(0.05)
    return data.decode("latin-1")


def checkpoint(m, cond):
    r = m.cmd(f"break {STOPCHECK:04x} if {cond}")
    return int(re.search(r"BREAK:\s*(\d+)", r).group(1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("disk")
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=166)
    ap.add_argument("--scale", type=int, default=3)
    song = pick(sys.argv)
    a = ap.parse_args()

    # Pro-16 needs its MIDI interface (without one it hangs, polling it):
    # the virtual ports, nobody listening
    ports = {n: vmidi.Port(n) for n in vice_band.PORTS}
    time.sleep(0.5)
    p = Pro16(vice_band.device_numbers(), title="pro16r", disk=a.disk)

    class S:                                    # load_song wants an object with .p
        pass
    s = S()
    s.p = p
    load_song(s, song["name"])
    v, m = p.v, p.v.mon
    m.stop()
    low = checkpoint(m, "rl > $fa")             # below the text: a whole frame
    top = checkpoint(m, "rl < $20")             # the next frame's top
    m.cmd(f"disable {top}")
    m.cmd("> 03f0 0d 03")                       # RETURN: play
    frames_dir = os.path.join(v.dir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    total = int(a.seconds * 50)
    first, last_frame, grabbed = None, -1, 0
    t0 = time.time()
    while last_frame < total - 1:
        run_to_break(m)
        rl, sw = regs(m)
        if first is None:
            first = sw - rl * 63                # the start of its frame
        frame = (sw - first) // FRAME_CYCLES
        if frame > last_frame:
            m.cmd(f'screenshot "frames/f{frame:05d}.png" 2')
            # a frame without a grab repeats the one before
            for k in range(last_frame + 1, frame):
                if last_frame >= 0:
                    shutil.copy(os.path.join(frames_dir, f"f{last_frame:05d}.png"),
                                os.path.join(frames_dir, f"f{k:05d}.png"))
            last_frame = frame
            grabbed += 1
        m.cmd(f"disable {low}")
        m.cmd(f"enable {top}")
        run_to_break(m)
        m.cmd(f"disable {top}")
        m.cmd(f"enable {low}")
        if grabbed % 500 == 0:
            print(f"frame {last_frame} of {total} ({time.time() - t0:.0f} s)", flush=True)
    m.cmd(f"delete {low}")
    m.cmd(f"delete {top}")
    v.go()
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "50", "-start_number", "0",
                    "-i", os.path.join(frames_dir, "f%05d.png"), "-frames:v", str(total),
                    "-vf", f"scale=iw*{a.scale}:ih*{a.scale}:flags=neighbor", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-crf", "18", a.out], check=True)
    p.quit()
    for q in ports.values():
        q.close()
    print(f"{a.out}: {total} frames, {grabbed} grabbed, {total - grabbed} repeated")
    os._exit(0)


if __name__ == "__main__":
    main()
