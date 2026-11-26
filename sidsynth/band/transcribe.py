# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The cover of Trip 2 Jupiter (Metal, 1994) as a MIDI file for the band:
SID101, SID303 and SID808, from the tune's own SID writes.

    python transcribe.py work/t2j.dump cover.mid

The tune (HVSC /MUSICIANS/M/Metal/Trip_2_Jupiter.sid, read with vsid
-sounddev dump) plays a row every 8 frames from frame 3, 16 rows a
pattern (128 frames): a row is a 16th at 93.75 BPM, a pattern a bar.
Voice 1 is a sliding bass, voices 2 and 3 arpeggios (a note every 4
frames, a 32nd) and stabs. No drums.

The cover, 64 bars (one Pro-16 sequence; the tune's 73 patterns less four
of the bass section's repeats and the outro):
- channel 1, SID101: the arpeggios, voice 2's or 3's (whichever arpeggiates
  in the bar, voice 2 first), as 32nd notes, each gated 2/3 of its length;
- channel 2, SID303: voice 1, its slides as overlapping notes (SID303
  slides those);
- channel 10, SID808: the tune's own drums (voices 2 and 3 play them as
  falling triangle hits when they don't arpeggiate: original_hits) where
  it has them; elsewhere (intro, the bass section, the bridge's start)
  drums written for it, on the sections.
Times are in MIDI clocks (24 a beat), the grid Pro-16's clock gives the
router; the file has 96 ticks a beat.
"""
import sys

import mido

import sidlog

FIRST_FRAME = 3                 # the first row's frame
ROW = 8                         # frames a row (a 16th)
BAR_FRAMES = 16 * ROW
PPQ = 96
TICKS_PER_CLOCK = PPQ // 24
BPM = 94                        # Pro-16's whole tempo nearest 93.75
VELOCITY = 100
# the tune's patterns, in the cover's order: (first pattern, bars, section)
SECTIONS = [(0, 4, "intro"), (4, 12, "bass"), (20, 16, "stabs"), (36, 8, "bridge"),
            (44, 8, "pedal"), (52, 16, "finale")]
GM = dict(kick=36, rim=37, snare=38, clap=39, hat=42, ohat=46, tom_lo=41, tom_mid=45,
          tom_hi=48, cymbal=49, cowbell=56)


def clocks(frame):
    """A frame of the tune, as MIDI clocks from its first row, on the
    tune's 4-frame (32nd) grid: a note's first frame is often a hard
    restart, a frame late (4 frames = 3 clocks)."""
    return round((frame - FIRST_FRAME) / 4) * 3


def settled(f):
    """The voice's note in frame f if it sounds a steady pitch, else None
    (rest, a hard-restart frame, between notes of a slide)."""
    if not f["gate"] or f["wave"] == "-" or f["note"] is None or abs(f["cents"]) > 20:
        return None
    return f["note"]


def steady(vf, i):
    """settled(), and the same pitch in the frame before or after: a
    slide passes a semitone for a single frame."""
    n = settled(vf[i])
    if n is None:
        return None
    if (i > 0 and settled(vf[i - 1]) == n) or (i + 1 < len(vf) and settled(vf[i + 1]) == n):
        return n
    return None


def segments(vf, start, end):
    """The voice's notes in frames start..end: [(on frame, off frame, note,
    legato)]: a note begins where a gate starts or the steady pitch changes
    (a slide's frames belong to the note it slides to: it begins where the
    slide does); legato = it began while the gate was held (a slide, an
    arpeggio step)."""
    out = []
    cur = None                  # [on, note, legato]
    moving = None               # the frame a pitch change began, gate held
    for i in range(start, end):
        f = vf[i]
        n = steady(vf, i)
        if f["trig"] or not f["gate"]:
            if cur:
                out.append((cur[0], i, cur[1], cur[2]))
                cur = None
            moving = None
        if not f["gate"]:
            continue
        if n is None:
            if cur and moving is None and f["wave"] != "-":
                moving = i      # a slide away from cur begins
            continue
        if cur is None:
            cur = [i if f["trig"] or moving is None else moving, n, not f["trig"] and moving is not None]
            if f["trig"] is False and i > start and vf[i - 1]["gate"] and out and out[-1][1] == i:
                cur[2] = True
            moving = None
        elif n != cur[1]:
            on = moving if moving is not None else i
            out.append((cur[0], on, cur[1], cur[2]))
            cur = [on, n, True]
            moving = None
        else:
            moving = None
    if cur:
        out.append((cur[0], end, cur[1], cur[2]))
    return out


def arpeggiates(segs):
    """Does the voice arpeggiate in these notes (mostly 4-frame notes)?"""
    short = sum(1 for on, off, _, _ in segs if off - on <= 4)
    return short >= 8


def stab_rows(vf, start):
    """Rows (0..15) of the bar from frame start where the voice starts a note."""
    return [r for r in range(16) if vf[start + r * ROW]["trig"] or
            (start + r * ROW + 1 < len(vf) and vf[start + r * ROW + 1]["trig"])]


def original_hits(V, start):
    """The tune's own drums in the bar from frame start: voices 2 and 3
    sound them as short triangle hits falling in pitch (the gate open 2 or
    3 frames). [(row, GM note, velocity)]: a fall from octave 3 a kick
    (they follow the chord's root), from octave 4 a high tom, the F4 click
    (F4, then C#3) a closed hat, or a snare on beats 2 and 4."""
    hits = []
    for v in (1, 2):
        vf = V[v]
        for r in range(16):
            i = start + r * ROW
            if not vf[i]["trig"] or i + 3 >= len(vf) or vf[i + 1]["wave"] != "tri" or vf[i + 3]["gate"]:
                continue
            first, second = vf[i + 1]["note"], vf[i + 2]["note"]
            if first == 65 and second == 49:                    # F4, C#3: the click
                hits.append((r, GM["snare"], 105) if r in (4, 12) else (r, GM["hat"], 75))
            elif first >= 60 + 5 or (first >= 60 and second >= 55):  # a fall from octave 4
                hits.append((r, GM["tom_hi"], 100))
            else:                                              # from octave 3: a kick
                hits.append((r, GM["kick"], 115 if r == 0 else 105))
    return hits


def drums(section, bar, rows):
    """The drum hits of one bar: [(step 0..15, GM note, velocity)]."""
    hits = []
    hat_steps = range(2, 16, 4)
    if section == "intro":
        if bar >= 2:
            hits += [(s, GM["hat"], 60) for s in hat_steps]
    elif section == "bass":
        hits += [(0, GM["kick"], 110), (8, GM["kick"], 100)]
        hits += [(s, GM["hat"], 70) for s in range(2, 16, 4)]
        if bar >= 4:
            hits += [(4, GM["clap"], 90), (12, GM["clap"], 90)]
    elif section == "stabs":
        hits += [(r, GM["kick"], 110) for r in rows]
        hits += [(4, GM["snare"], 100), (12, GM["snare"], 100)]
        hits += [(s, GM["hat"], 60 if s % 4 else 80) for s in range(0, 16, 2)]
        if bar % 8 == 7:
            hits += [(14, GM["tom_hi"], 100), (15, GM["tom_mid"], 100)]
    elif section == "bridge":
        hits += [(0, GM["kick"], 110), (8, GM["kick"], 100)]
        hits += [(r, GM["rim"], 90) for r in rows]
        hits += [(s, GM["ohat"], 70) for s in (6, 14)]
        if bar == 0:
            hits.append((0, GM["cymbal"], 110))
    elif section == "pedal":
        hits += [(r, GM["kick"], 110) for r in rows]
        hits += [(4, GM["clap"], 100), (12, GM["clap"], 100)]
        hits += [(s, GM["hat"], 55 if s % 2 else 75) for s in range(16)]
    elif section == "finale":
        hits += [(r, GM["kick"], 115) for r in rows]
        hits += [(4, GM["snare"], 110), (12, GM["snare"], 110)]
        hits += [(s, GM["ohat"], 75) for s in (2, 6, 10, 14)]
        hits += [(s, GM["hat"], 60) for s in (0, 4, 8, 12)]
        if bar % 8 == 0:
            hits.append((0, GM["cymbal"], 120))
        if bar % 4 == 3:
            hits += [(13, GM["tom_hi"], 100), (14, GM["tom_mid"], 100), (15, GM["tom_lo"], 100)]
    return hits


def main():
    dump, out = sys.argv[1], sys.argv[2]
    frames = sidlog.sid_frames(dump)
    V = [sidlog.voice_frames(frames, v) for v in range(3)]
    ev = {1: [], 2: [], 10: []}     # channel -> [(clock, order, bytes)]; order: off before on
    bar = 0
    for first, bars, section in SECTIONS:
        for b in range(bars):
            start = FIRST_FRAME + (first + b) * BAR_FRAMES
            end = start + BAR_FRAMES
            shift = (bar - first - b) * BAR_FRAMES       # the tune's frame -> the cover's
            base = lambda frame: clocks(frame + shift)
            # SID303: voice 1, slides as overlaps (the old note ends a clock
            # after the new one begins)
            for on, off, n, legato in segments(V[0], start, end):
                ev[2].append((base(on), 1, [0x91, n, VELOCITY]))
                held = off < len(V[0]) and V[0][off]["gate"] and not V[0][off]["trig"]
                ev[2].append((base(off) + (1 if held else 0), 0, [0x81, n, 0]))
            # SID101: the arpeggio, voice 2 if it arpeggiates, else voice 3
            segs = {v: segments(V[v], start, end) for v in (1, 2)}
            arp_v = 1 if arpeggiates(segs[1]) else 2 if arpeggiates(segs[2]) else None
            if arp_v is not None:
                for on, off, n, _ in segs[arp_v]:
                    c_on, c_off = base(on), base(off)
                    c_off = max(c_on + 1, c_on + (c_off - c_on) * 2 // 3)
                    ev[1].append((c_on, 1, [0x90, n, VELOCITY]))
                    ev[1].append((c_off, 0, [0x80, n, 0]))
            # SID808: the tune's own drums where it has them, else the
            # written part (on the stab voice's rhythm)
            hits = original_hits(V, start)
            if not hits:
                stab_v = {1: 2, 2: 1, None: 1}[arp_v]
                rows = stab_rows(V[stab_v], start) if not arpeggiates(segs[stab_v]) else []
                hits = drums(section, b, rows)
            for step, note, vel in hits:
                c = clocks(FIRST_FRAME + bar * BAR_FRAMES + step * ROW)
                ev[10].append((c, 1, [0x99, note, vel]))
                ev[10].append((c + 2, 0, [0x89, note, 0]))
            bar += 1

    mid = mido.MidiFile(ticks_per_beat=PPQ)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name="Trip 2 Jupiter (Metal) - SidSynth cover", time=0))
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(BPM), time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    meta.append(mido.MetaMessage("end_of_track", time=bar * 4 * PPQ))
    mid.tracks.append(meta)
    for ch, name in ((1, "SID101 arpeggio"), (2, "SID303 bass"), (10, "SID808 drums")):
        tr = mido.MidiTrack()
        tr.append(mido.MetaMessage("track_name", name=name, time=0))
        last = 0
        for c, _, m in sorted(ev[ch], key=lambda e: (e[0], e[1])):
            t = c * TICKS_PER_CLOCK
            tr.append(mido.Message.from_bytes(m, time=t - last))
            last = t
        tr.append(mido.MetaMessage("end_of_track", time=0))
        mid.tracks.append(tr)
    mid.save(out)
    notes = {ch: sum(1 for e in ev[ch] if e[2][0] & 0xF0 == 0x90) for ch in ev}
    print(f"{out}: {bar} bars at {BPM} BPM ({bar * 4 * 60 / BPM:.0f} s); notes: SID101 "
          f"{notes[1]}, SID303 {notes[2]}, SID808 {notes[10]}")


if __name__ == "__main__":
    main()
