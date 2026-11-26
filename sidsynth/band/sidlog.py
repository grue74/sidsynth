# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read a VICE SID dump (vsid -sounddev dump: lines "cycles-since-last
register value") into the SID's state once a frame.

    frames = sid_frames("t2j.dump")   # [ [25 register values] per frame ]

Each frame is the state at the frame's end (PAL: 19656 cycles a frame,
50.125 a second); a gate that went off and on again inside the frame
shows as a retrigger in voice_frames().
"""
import math

PAL_CLOCK = 985248
FRAME_CYCLES = 19656            # PAL: 312 lines x 63 cycles
WAVES = {0x10: "tri", 0x20: "saw", 0x40: "pul", 0x80: "noi"}


def sid_frames(path):
    """[(registers after the frame, set of (voice) retriggered in it)]."""
    regs = [0] * 25
    frames = []
    t, frame_end = 0, FRAME_CYCLES
    retrig = set()
    for line in open(path):
        dt, r, v = map(int, line.split())
        t += dt
        while t >= frame_end:
            frames.append((list(regs), retrig))
            retrig = set()
            frame_end += FRAME_CYCLES
        if r in (4, 11, 18):
            voice = r // 7
            if (regs[r] & 1) == 0 and (v & 1) == 1:
                retrig.add(voice)
        regs[r] = v
    frames.append((list(regs), retrig))
    return frames


def note_of(freq):
    """The nearest MIDI note of a SID frequency register (PAL), and the
    cents off it; None for 0."""
    if freq == 0:
        return None, 0
    hz = freq * PAL_CLOCK / 16777216
    n = 69 + 12 * math.log2(hz / 440)
    return round(n), round((n - round(n)) * 100)


def voice_frames(frames, voice):
    """Per frame: dict(note, cents, freq, wave, gate, trig, pw, ad, sr)."""
    out = []
    b = voice * 7
    for regs, retrig in frames:
        freq = regs[b] | regs[b + 1] << 8
        ctrl = regs[b + 4]
        n, c = note_of(freq)
        out.append(dict(note=n, cents=c, freq=freq,
                        wave="+".join(w for bit, w in WAVES.items() if ctrl & bit) or "-",
                        gate=ctrl & 1, test=bool(ctrl & 8), sync=bool(ctrl & 2),
                        ring=bool(ctrl & 4), trig=voice in retrig,
                        pw=(regs[b + 2] | (regs[b + 3] & 15) << 8), ad=regs[b + 5], sr=regs[b + 6]))
    return out


NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def name(n):
    return "---" if n is None else f"{NAMES[n % 12]}{n // 12 - 1}"
