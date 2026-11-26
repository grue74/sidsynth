# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""tune_moonlight.py - Beethoven's Moonlight Sonata, first movement (Op. 27
No. 2, Adagio sostenuto, 1801), at Jet Set Willy's pace: the C64 game's
music (HVSC GAMES/G-L/Jet_Set_Willy.sid, subtune 1; measured from its SID
writes: a beat of three triplet eighths every 32 frames, 94 BPM, in C
minor, a semitone below Beethoven's C# minor). Only its tempo and key are
taken; the notes are Beethoven's, read from the Mutopia Project's edition
(score 276, Berners 1908 ed. Winterberger; MIDI by LilyPond, CC BY-SA
2.5: https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=276),
downloaded into work/moonlight/ (not kept in git).

The orchestra (the user: as many synths as a "large" sound needs): SID101
the triplets (track 1, channel 1, Arp PWM), the melody (track 2, channel
3, Fat lead) and the melody an octave up (track 3, channel 4, Hollow lead);
SID303 the bass's lowest note (track 4, channel 2), SID101 the bass's next
(track 5, channel 7, Sub bass); a pad of three SID101s holding each beat's
chord, the notes of its triplets (tracks 6-8, channels 5, 6, 8, Delay
vibe). 69 bars of 2/2 as SID500's 4/4 bars, 8 a scene.
"""
import os
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunes import Tune, cc, program, QUARTER  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCORE_DIR = os.path.join(ROOT, "work", "moonlight")
SCORE_ZIP = "https://www.mutopiaproject.org/ftp/BeethovenLv/O27/moonlight/moonlight-mids.zip"
TRANSPOSE = -1                  # to C minor, as Jet Set Willy
TEMPO = 94                      # Jet Set Willy's: 32 frames a beat (measured)
BAR_TICKS = 4 * QUARTER         # a 2/2 bar: 192 of SID500's ticks
SCENE_BARS = 8                  # a pattern's longest: 128 16ths


def score_file():
    """The first movement's MIDI (Mutopia), downloaded once."""
    path = os.path.join(SCORE_DIR, "moonlight1.mid")
    if not os.path.exists(path):
        os.makedirs(SCORE_DIR, exist_ok=True)
        z = os.path.join(SCORE_DIR, "moonlight-mids.zip")
        subprocess.run(["curl", "-sSL", "-o", z, SCORE_ZIP], check=True)
        zipfile.ZipFile(z).extract("moonlight1.mid", SCORE_DIR)
    return path


def read_score():
    """(right hand, left hand): [(SID500 tick, note, length)] each."""
    import mido
    mid = mido.MidiFile(score_file())
    scale = QUARTER / mid.ticks_per_beat           # (384 -> 48: exact, 8)

    def notes(track):
        t, on, out = 0, {}, []
        for m in track:
            t += m.time
            if m.type == "note_on" and m.velocity:
                on.setdefault(m.note, []).append(t)
            elif m.type in ("note_off", "note_on") and on.get(m.note):
                s = on[m.note].pop(0)
                out.append((round(s * scale), m.note + TRANSPOSE, round((t - s + 1) * scale)))
        return sorted(out)
    return notes(mid.tracks[1]), notes(mid.tracks[2])


TRIPLET = QUARTER // 3          # 16 ticks


def parts():
    """{part: [(tick, note, length, velocity)]} from the score."""
    up, down = read_score()
    is_trip = lambda n: n[2] == TRIPLET and n[0] % TRIPLET == 0   # noqa: E731
    trip = sorted(n for n in up + down if is_trip(n))
    mel_all = [n for n in up if not is_trip(n)]
    bass_all = [n for n in down if not is_trip(n)]
    out = {}
    # the triplets: a beat's first a little stronger; 1 tick short (struck again)
    out["triplets"] = [(t, p, TRIPLET - 1, 92 if t % QUARTER == 0 else 78) for t, p, _ in trip]
    # the melody: its top note at each start (the last bars' chords: the pad has them)
    top = {}
    for t, p, ln in mel_all:
        if t not in top or p > top[t][0]:
            top[t] = (p, ln)
    mel = [(t, p, ln - 2, 108) for t, (p, ln) in sorted(top.items())]
    out["melody"] = mel
    out["melody octave"] = [(t, p + 12, ln, 96) for t, p, ln, _ in mel]
    # the bass: the lowest note at each start, and the next
    by_t = {}
    for t, p, ln in bass_all:
        by_t.setdefault(t, []).append((p, ln))
    low, nxt = [], []
    for t in sorted(by_t):
        ns = sorted(by_t[t])
        low.append((t, ns[0][0], ns[0][1] - 3, 104))
        if len(ns) > 1:
            nxt.append((t, ns[1][0], ns[1][1] - 3, 96))
    out["bass"], out["bass octave"] = low, nxt
    # the pad: each beat's triplets as a chord, three voices, a voice held
    # on while its note stays
    beats = {}
    for t, p, _ in trip:
        beats.setdefault(t // QUARTER, []).append(p)
    end = max(t + ln for t, _, ln in up + down)
    for v, name in enumerate(("pad low", "pad mid", "pad high")):
        held = []
        for b in sorted(beats):
            ns = sorted(set(beats[b]))
            if len(ns) < 3:
                continue
            p = ns[v]
            if held and held[-1][1] == p and held[-1][0] + held[-1][2] == b * QUARTER:
                t0, _, ln = held[-1]
                held[-1] = (t0, p, ln + QUARTER)
            else:
                held.append((b * QUARTER, p, QUARTER))
        out[name] = [(t, p, min(ln, end - t) - 3, 72) for t, p, ln in held]
    return out


# ---- set-up: each synth's sound
SETUP = {
    "triplets": [program(1, 20), cc(2, 80, 0), cc(2, 74, 72)],              # Arp PWM, its arp off
    "melody": [program(1, 11), cc(2, 74, 64), cc(2, 30, 0)],                # Fat lead, no glide
    "melody octave": [program(1, 10), cc(2, 74, 52), cc(2, 30, 0)],         # Hollow lead
    "bass": [cc(1, 74, 38), cc(1, 71, 20), cc(1, 12, 30), cc(1, 75, 100), cc(1, 13, 0),
             cc(1, 5, 0), cc(1, 72, 120), cc(1, 7, 112)],                    # SID303, dark and long
    "bass octave": [program(1, 4), cc(2, 74, 60)],                          # Sub bass
    "pad low": [program(1, 13), cc(2, 74, 72)], "pad mid": [program(1, 13), cc(2, 74, 72)],
    "pad high": [program(1, 13), cc(2, 74, 72)],    # Delay vibe, its cutoff half open (the
                                                    # user, 2026-11-26: 46 hid the pad)
}
LAYOUT = [  # track, channel, synth, part, preset (the video's label)
    (1, 1, "sid101", "triplets", "Arp PWM"), (2, 3, "sid101", "melody", "Fat lead"),
    (3, 4, "sid101", "melody octave", "Hollow lead"), (4, 2, "sid303", "bass", None),
    (5, 7, "sid101", "bass octave", "Sub bass"), (6, 5, "sid101", "pad low", "Delay vibe"),
    (7, 6, "sid101", "pad mid", "Delay vibe"), (8, 8, "sid101", "pad high", "Delay vibe")]


def build():
    ps = parts()
    end = max(t + ln for evs in ps.values() for t, _, ln, _ in evs)
    n_bars = -(-end // BAR_TICKS)
    scenes_n = -(-n_bars // SCENE_BARS)
    patterns, scenes = {}, []
    setup_row = {}
    for k, (track, _ch, _s, part, _p) in enumerate(LAYOUT):
        patterns[1 + k] = (16, SETUP[part])
        setup_row[track] = 1 + k
    patterns[10] = (16, [])                                              # the end's silence
    scenes.append(("Setup", 1, setup_row, 1))
    for sc in range(scenes_n):
        first = sc * SCENE_BARS
        bars_here = min(SCENE_BARS, n_bars - first)
        row = {}
        for k, (track, _ch, _s, part, _p) in enumerate(LAYOUT):
            lo, hi = first * BAR_TICKS, (first + bars_here) * BAR_TICKS
            evs = [(t - lo, "note", p, v, ln) for t, p, ln, v in ps[part] if lo <= t < hi]
            if not evs:
                continue
            num = 20 + sc * len(LAYOUT) + k
            patterns[num] = (bars_here * 16, evs)
            row[track] = num
        scenes.append((f"Bars {first + 1}-{first + bars_here}", bars_here, row, 1))
    scenes.append(("End", 8, {1: 10}, 9))
    synths = {ch: (s, part, preset) for _t, ch, s, part, preset in LAYOUT}
    tracks = {t: ch for t, ch, *_ in LAYOUT}
    return Tune("moonlight", "Moonlight Sonata", "moonlight", TEMPO, synths, patterns, tracks,
                scenes)


TUNE = build()
TUNE.levels = {"pad": -25.0, "bass": -23.5, "bass octave": -26.0}  # (the user, 2026-11-26:
                                # the bass and the pads 3 dB up; the pad was -28: a large sound)

if __name__ == "__main__":
    blocks = TUNE.check()
    counts = {}
    for t, ch, m in TUNE.messages():
        if m[0] & 0xF0 == 0x90:
            counts[ch + 1] = counts.get(ch + 1, 0) + 1
    print(f"{TUNE.title}: {len(TUNE.patterns)} patterns, {len(TUNE.scenes)} scenes, {blocks} "
          f"blocks of 680, {TUNE.seconds(TUNE.length_ticks()):.1f} s; notes per channel {counts}")
