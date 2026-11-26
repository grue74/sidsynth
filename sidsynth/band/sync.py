# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""A synth's recorded sound against the song: where its notes fall.

    lag(x, rate, times)                 # a render's sound against its notes (s)
    track(x, ref, rate)                 # [(time, lag)]: a recording against a render
    warp(x, rate, points)               # the recording moved by a line through them

x and ref are mono float numpy arrays at the same rate; times the note ons
in seconds on x's timeline (note_times() + where the song starts in it).

Two places need it.

The video (compose.py): vicerec.py puts each render's sound against its
pictures by the lengths of the two, and VICE's sound buffer at quitting
makes that tens of ms off, differently for each synth and each run (Glide
Path: SID101 +122, SID303 +61, SID808 -109 ms against the notes; SID808
-125 in the run before). lag() measures it: the
first sound against the first note (the part is silent before it), then a
fit of the sound's rises to all the note ons within NEAR of that (a
repeating pattern also fits a 16th or a beat off, so the fit stays near).

The live recordings (mix_band.py): each synth's VICE records its WAV in
its own emulated time and each ran at its own real speed, so the parts
drift (about 0.2 %, 0.2 s over the song). A note-by-note fit can't follow
that through dense patterns, but the same part's render is the same sound
in exact time: track() matches the recording's loudness curve to the
render's, window by window, and warp() moves the recording by a straight
line through the good matches.
"""
import mido
import numpy as np

HOP = 0.001                     # seconds: the onset curve's step
NEAR = 0.03                     # seconds: the fit's range around the rough lag
ENV_HOP = 0.002                 # seconds: the loudness curve's step (track)


def note_times(path, ch, tempo):
    """The file's note ons on channel ch (0-based), seconds from its start."""
    mid = mido.MidiFile(path)
    out = []
    for tr in mid.tracks:
        t = 0
        for m in tr:
            t += m.time
            if not m.is_meta and m.type == "note_on" and m.velocity and m.channel == ch:
                out.append(t / mid.ticks_per_beat * 60 / tempo)
    return np.array(sorted(out))


# ---- a render against its notes
def onset_curve(x, rate):
    """How fast the loudness rises, every HOP seconds (log energy's rise)."""
    hop = max(1, int(rate * HOP))
    n = len(x) // hop
    e = (x[:n * hop].reshape(n, hop) ** 2).mean(axis=1)
    d = np.diff(np.log(e + 1.0), prepend=0.0)
    d[d < 0] = 0
    return d


def _fit(curve, times, lo, hi):
    """The lag (s) in lo..hi that puts the most rise just after the notes:
    a 5 ms window from each note's time plus the lag."""
    best = (None, 0.0)
    for k in range(int(round(lo / HOP)), int(round(hi / HOP)) + 1):
        idx = np.round(times / HOP).astype(int) + k
        idx = idx[(idx >= 0) & (idx + 5 < len(curve))]
        if len(idx) == 0:
            continue
        score = sum(curve[idx + j].sum() for j in range(5))
        if best[0] is None or score > best[0]:
            best = (score, k * HOP)
    return best[1]


def rough_lag(x, rate, times, before=1.0, level=0.05):
    """The first sound's time less the first note's: the first sample above
    level x the peak, from `before` seconds ahead of the first note (past
    VICE's start-up click). The part is silent before its first note."""
    a = np.abs(x)
    start = max(0, int((times[0] - before) * rate))
    i = start + int(np.argmax(a[start:] > level * a.max()))
    return i / rate - times[0]


def lag(x, rate, times):
    """A render's sound against its notes, seconds late (negative: early)."""
    r = rough_lag(x, rate, times)
    return _fit(onset_curve(x, rate), times, r - NEAR, r + NEAR)


# ---- a live recording against the render
def envelope(x, rate):
    """The loudness curve: log energy every ENV_HOP seconds."""
    hop = max(1, int(rate * ENV_HOP))
    n = len(x) // hop
    return np.log((x[:n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1.0)


def track(x, ref, rate, window=8.0, every=5.0, first=0.08, step=0.03, good=0.6):
    """[(time, lag)]: where each window of ref (the render, on x's timeline)
    is found in x, seconds late; the first window searched within `first`,
    the rest within `step` of the last good one; only windows whose match
    correlates `good` or better. The first sound has already put x within
    tens of ms (a wider first search let a soft lead, little to match, lock
    250 ms off), and the drift moves a window ~10 ms at most."""
    ex, er = envelope(x, rate), envelope(ref, rate)
    w = int(window / ENV_HOP)
    out, prev = [], 0.0
    t = 0.0
    while (t + window) / ENV_HOP < min(len(ex), len(er)):
        i = int(t / ENV_HOP)
        seg = er[i:i + w] - er[i:i + w].mean()
        if seg.std() > 0.5:                     # not silence
            reach = first if not out else step
            best = None
            for k in range(int((prev - reach) / ENV_HOP), int((prev + reach) / ENV_HOP) + 1):
                j = i + k
                if j < 0 or j + w > len(ex):
                    continue
                s2 = ex[j:j + w] - ex[j:j + w].mean()
                c = float(np.dot(seg, s2) / (np.linalg.norm(seg) * np.linalg.norm(s2) + 1e-9))
                if best is None or c > best[0]:
                    best = (c, k * ENV_HOP)
            if best and best[0] >= good:
                prev = best[1]
                out.append((t + window / 2, prev))
        t += every
    return out


def line(points, keep=0.02):
    """A straight line (lag at 0, slope) through the points, fitted again
    without those more than `keep` seconds off the first fit."""
    t = np.array([p[0] for p in points])
    v = np.array([p[1] for p in points])
    if len(t) < 2:
        return (float(v[0]) if len(v) else 0.0), 0.0
    slope, at0 = np.polyfit(t, v, 1)
    ok = np.abs(v - (at0 + slope * t)) <= keep
    if ok.sum() >= 2:
        slope, at0 = np.polyfit(t[ok], v[ok], 1)
    return float(at0), float(slope)


def warp(x, rate, at0, slope):
    """x moved so that what it has at t + at0 + slope * t comes at t."""
    t = np.arange(len(x)) / rate
    return np.interp((t + at0 + slope * t) * rate, np.arange(len(x)), x, left=0.0, right=0.0)
