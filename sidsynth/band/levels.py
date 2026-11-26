# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The band's balance: each synth's part measured (integrated loudness,
EBU R128, ffmpeg's ebur128) and given the gain that puts it at its target.

    gains = levels.gains({"sid101": lufs, ...})      # name -> linear gain
    lufs = levels.loudness_file(path)                # a file's sound
    lufs = levels.loudness(x, rate)                  # a numpy array's

The synths come out of their renders far apart (Glide Path: SID101 -24,
SID303 -30, SID808 -33 LUFS), so a fixed mix buries some. The targets: the
lead 2 LU over the bass and the drums, those two level; the mix is then
brought to its final loudness as a whole (compose.py: loudnorm).
"""
import re
import subprocess

import numpy as np

TARGET = {"sid101": -27.0, "sid303": -29.0, "sid808": -29.0}     # LUFS, before the whole is levelled


def _ebur128(args, data=None):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", *args, "-vn",
                        "-af", "ebur128", "-f", "null", "-"],
                       input=data, capture_output=True, check=True)
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", r.stderr.decode(errors="replace"))
    return float(found[-1])                      # the summary's


def loudness_file(path):
    return _ebur128(["-i", path])


def loudness(x, rate):
    pcm = np.clip(x, -32768, 32767).astype(np.int16).tobytes()
    return _ebur128(["-f", "s16le", "-ar", str(rate), "-ac", "1", "-i", "-"], pcm)


def gains(louds):
    """name -> the linear gain that brings its loudness to its TARGET."""
    return {k: 10 ** ((TARGET[k] - v) / 20) for k, v in louds.items()}
