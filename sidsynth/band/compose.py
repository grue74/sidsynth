# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The presentation video: the four screens in a 2x2 grid, the three
synths' sound mixed.

    python compose.py work/video work/trip2jupiter-band.mp4 [--song glide]

Inputs in the folder: sid101.mp4, sid303.mp4, sid808.mp4 (feeds.py's
builds rendered by c64tools/vicerec.py: each song starts LEAD seconds
after its synth does) and pro16.mp4 (pro16_render.py: from the start of
playback, so it is delayed by LEAD, its first picture held). Each screen
at twice the C64's 384x272, labelled; the sound mixed and levelled
(loudnorm); a fade at the end. The mix also goes to the same name .mp3.

Each synth's sound is first moved onto its notes (sync.py): vicerec.py
lines a render's sound up with its pictures to within a few tens of ms,
differently for each synth, and the parts' notes are where the song's
times say (LEAD + the file's time), as the pictures are. Each part's level
is set by its measured loudness (levels.py).
"""
import os
import subprocess
import sys

import numpy as np

import levels
import sync
from feeds import LEAD, SYNTHS
from songs import pick

FONT = "work/consolab.ttf"      # a copy of Windows' Consolas Bold: no drive colon in the filter
W, H = 768, 544                 # each screen: 384x272 x 2
LABELS = {"pro16": "Steinberg Pro-16  sequencer 1986", "sid101": "SID101  arpeggio (ch 1)",
          "sid303": "SID303  acid bass (ch 2)", "sid808": "SID808  drums (ch 10)"}
ORDER = ["pro16", "sid101", "sid303", "sid808"]     # top left, top right, bottom left, right


def sound_lag(path, song, ch, rate=16000):
    """The render's sound against its notes: seconds late (negative: early)."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(rate),
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.int16).astype(float)
    return sync.lag(x, rate, sync.note_times(song["midi"], ch, song["tempo"]) + LEAD)


def main():
    song = pick(sys.argv)
    folder, out = sys.argv[1:3]
    seconds = LEAD + song["bars"] * 4 * 60 / song["tempo"] + 2.5
    labels = dict(LABELS, **song["labels"])
    args = ["ffmpeg", "-y", "-loglevel", "error"]
    for name in ORDER:
        args += ["-i", f"{folder}/{name}.mp4"]
    parts = []
    for k, name in enumerate(ORDER):
        f = f"[{k}:v]"
        if name == "pro16":
            f += f"tpad=start_duration={LEAD}:start_mode=clone,"
        f += (f"scale={W}:{H}:flags=neighbor,trim=0:{seconds:.2f},setpts=PTS-STARTPTS,"
              f"drawtext=fontfile='{FONT}':text='{labels[name]}':x=12:y=h-30:fontsize=18:"
              f"fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=6[v{k}]")
        parts.append(f)
    parts.append("[v0][v1][v2][v3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0,"
                 f"fade=t=out:st={seconds - 2:.2f}:d=2[v]")
    gain = levels.gains({n: levels.loudness_file(f"{folder}/{n}.mp4") for n in ORDER[1:]})
    print("gains: " + ", ".join(f"{k} {20 * np.log10(g):+.1f} dB" for k, g in gain.items()))
    for k, name in enumerate(ORDER):
        if name == "pro16":
            continue
        lag = sound_lag(f"{folder}/{name}.mp4", song, SYNTHS[name][1])
        print(f"{name}: sound {lag * 1000:+.0f} ms against its notes, moved", flush=True)
        if lag > 0:
            parts.append(f"[{k}:a]atrim=start={lag:.4f},asetpts=PTS-STARTPTS[a{k}]")
        else:
            parts.append(f"[{k}:a]adelay={-lag * 1000:.1f}:all=1[a{k}]")
    weights = " ".join(f"{gain[n]:.4f}" for n in ORDER[1:])
    parts.append(f"[a1][a2][a3]amix=inputs=3:normalize=0:weights={weights},"
                 f"atrim=0:{seconds:.2f},loudnorm=I=-16:TP=-1.5,afade=t=out:st={seconds - 2:.2f}:d=2[a]")
    args += ["-filter_complex", ";".join(parts), "-map", "[v]", "-map", "[a]",
             "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
             "-r", "50", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", out]
    subprocess.run(args, check=True)
    mp3 = os.path.splitext(out)[0] + ".mp3"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", out, "-vn", "-b:a", "192k", mp3],
                   check=True)
    print(f"{out}: {seconds:.1f} s, {2 * W}x{2 * H}; the sound in {mp3}")


if __name__ == "__main__":
    main()
