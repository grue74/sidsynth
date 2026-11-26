# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record a song's MIDI file into Pro-16 in VICE, save it on a disk, and
check Pro-16's playback against the file.

    python record_cover.py work/cover.mid work/songs.d64 work/trip2jupiter.d64
    python record_cover.py work/glide-path.mid work/songs.d64 work/glide-path.d64 --song glide

Pro-16 (session.py) gets the song's bars and tempo (songs.py), quantize
off, tracks 1, 2, 3 on MIDI channels 1, 2, 10; each channel of the file is
recorded on its track on Pro-16's own clock; the song is saved under its
name; then one playback is logged and compared with the file, clock by
clock: note ons, controllers and pitch bends (Pro-16 plays a message at
clock 0 one clock late). The disk image with the song is copied to the
last argument. Screenshots go to work/rec-*.png, the report to
work/rec-report.json.
"""
import json
import os
import shutil
import sys
import time
from collections import Counter

import mido

from session import Session
from songs import pick

TRACKS = ((1, 0), (2, 1), (3, 9))          # Pro-16 track, MIDI channel (0-based)


def channel_events(path, ch):
    """The file's messages on channel ch as [(clock, bytes)]."""
    mid = mido.MidiFile(path)
    per_clock = mid.ticks_per_beat // 24
    out = []
    for tr in mid.tracks:
        t = 0
        for m in tr:
            t += m.time
            if not m.is_meta and m.channel == ch:
                out.append((t // per_clock, bytes(m.bytes())))
    return sorted(out, key=lambda e: e[0])


def notes_on(events):
    return [(c, m[0] & 0x0F, m[1]) for c, m in events if m[0] & 0xF0 == 0x90 and m[2]]


KINDS = {0x90: "note ons", 0xB0: "controllers", 0xE0: "pitch bends"}


def checked(m):
    """The kind of a message the check compares (note offs are not: Pro-16
    may send them either way), or None."""
    k = m[0] & 0xF0
    if k == 0x90 and m[2] == 0:
        return None
    return KINDS.get(k)


def compare(log, src, end):
    """Pro-16's playback (log: [(time, bytes)]) against the file, clock by
    clock: per kind, how many were wanted, played on time, a clock late,
    missing; and how many came that the file doesn't have, before clock
    end (the sequence goes round again after it)."""
    clock, got = None, Counter()
    for _, m in log:
        if m[0] == 0xFA:
            clock = 0
        elif m[0] == 0xF8 and clock is not None:
            clock += 1
        elif clock is not None and clock < end and m[0] < 0xF0 and checked(m):
            got[(clock, bytes(m))] += 1
    want = Counter((c, m) for _, ch in TRACKS for c, m in channel_events(src, ch) if checked(m))
    report = {k: Counter() for k in KINDS.values()}
    missing = []
    for (c, m), n in sorted(want.items()):
        kind = checked(m)
        for _ in range(n):
            report[kind]["wanted"] += 1
            if got[(c, m)]:
                got[(c, m)] -= 1
                report[kind]["on time"] += 1
            elif got[(c + 1, m)]:
                got[(c + 1, m)] -= 1
                report[kind]["a clock late"] += 1
            else:
                report[kind]["missing"] += 1
                missing.append((c, m.hex()))
    extra = []
    for (c, m), n in sorted(got.items()):
        if n > 0:
            report[checked(m)]["extra"] += n
            extra.append((c, m.hex(), n))
    out = {k: dict(v) for k, v in report.items() if v}
    out["first missing"] = missing[:10]
    out["first extra"] = extra[:10]
    out["clocks"] = clock
    return out


def save(s, name):
    """The DSK box, SAV, D, the name, RETURN (rehearsed: the song lands on drive 8)."""
    p = s.p
    p.keys("T", "DOWN", "DOWN", "DOWN", "DOWN", "DOWN", after=0.3)
    for _ in range(5):
        p.press("RIGHT", after=0.3)
    p.press("F3", after=0.5)                    # LOD -> SAV
    p.press("D", after=0.8)
    for ch in name:
        p.press(ch, after=0.3)
    p.press("RETURN", after=20)
    p.shot("work/rec-saved.png")
    p.press("SPACE", after=1)


def main():
    song = pick(sys.argv)
    src, blank, out = sys.argv[1:4]
    bars, tempo = song["bars"], song["tempo"]
    clocks = bars * 4 * 24
    seconds = bars * 4 * 60 / tempo
    s = Session(bars=bars, tempo=tempo, disk=blank)
    s.shot("work/rec-setup.png")
    report = {}
    for track, ch in TRACKS:
        evs = channel_events(src, ch)
        t0 = time.time()
        left = s.record(track, evs, length_clocks=clocks, timeout=seconds + 100)
        report[f"track {track}"] = {"events": len(evs), "unsent": left,
                                    "seconds": round(time.time() - t0)}
        s.shot(f"work/rec-track{track}.png")
        print(f"track {track} (channel {ch + 1}): {len(evs)} events, {left} unsent", flush=True)
    save(s, song["name"])
    log = s.play(seconds + 60, route=False, until_clock=clocks)
    disk = os.path.join(s.p.v.dir, "d.d64")
    s.close()
    shutil.copy(disk, out)
    report["playback"] = compare(log, src, clocks)
    json.dump(report, open("work/rec-report.json", "w"), indent=1)
    print(json.dumps(report, indent=1), flush=True)
    os._exit(0)


if __name__ == "__main__":
    main()
