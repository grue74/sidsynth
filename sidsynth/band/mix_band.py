# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Mix the band's three live recordings (play_band.py's out/sid101.wav,
sid303.wav, sid808.wav) into out/band.wav and band.mp3. play_band.py calls
it; run it by itself to mix again.

    python mix_band.py work/band work/cover.mid
    python mix_band.py work/glide-band work/glide-path.mid --song glide

Each part is put on the song's time against its exact render (the song's
renders folder, songs.py: <synth>.mp4 from feeds.py and vicerec.py, the
same synth playing the same notes in emulated time):
1. roughly: its first sound (after SKIP: a VICE clicks as it starts) at
   its first note's time, the song's first note LEAD into the mix;
2. the render placed on the same time by its own lag against its notes
   (sync.lag: vicerec's sound is tens of ms off its pictures);
3. the recording matched to the render window by window (sync.track) and
   moved by a straight line through the matches (sync.line, sync.warp):
   each VICE's WAV is in its own emulated time, and each ran at its own
   real speed, so the parts drift apart over the song.
Then each part is brought to its loudness (levels.py) and they are mixed,
the peak at -1 dB, cut 2 s after the song.
"""
import os
import subprocess
import sys
import wave

import numpy as np

import levels
import sync
from feeds import LEAD as FEED_LEAD
from songs import pick

SKIP = 3.0                      # seconds: past the start-up click
THRESHOLD = 600
LEAD = 0.5                      # seconds before the song's first note
CHANNEL = {"sid101": 0, "sid303": 1, "sid808": 9}


def read(path):
    with wave.open(path) as w:
        rate, ch = w.getframerate(), w.getnchannels()
        data = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float)
    return rate, data[::ch]


def read_render(path, rate):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(rate),
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(float)


def first_sound(data, rate):
    i = int(SKIP * rate)
    loud = np.nonzero(np.abs(data[i:]) > THRESHOLD)[0]
    if not len(loud):
        raise ValueError("no sound")
    return i + int(loud[0])


def shifted(x, start):
    """x from sample start on (before its beginning: silence)."""
    return x[start:] if start >= 0 else np.concatenate([np.zeros(-start), x])


def mix(out, src, song):
    times = {k: sync.note_times(src, ch, song["tempo"]) for k, ch in CHANNEL.items()}
    first_note = min(t[0] for t in times.values())
    tracks, rate = {}, None
    for name in CHANNEL:
        rate, data = read(os.path.join(out, f"{name}.wav"))
        notes = times[name] - first_note + LEAD                  # on the mix's time
        x = shifted(data, first_sound(data, rate) - int(round(notes[0] * rate)))
        render = read_render(os.path.join(song["renders"], f"{name}.mp4"), rate)
        render_lag = sync.lag(render, rate, times[name] + FEED_LEAD)
        ref = shifted(render, int(round((FEED_LEAD + render_lag + first_note - LEAD) * rate)))
        points = sync.track(x, ref, rate)
        at0, slope = sync.line(points)
        tracks[name] = sync.warp(x, rate, at0, slope)
        off = [abs(v - (at0 + slope * t)) for t, v in points]
        print(f"{name}: {len(points)} windows matched its render; {at0 * 1000:+.0f} ms at the "
              f"start, drifting {slope * 100:+.3f} %, the matches within "
              f"{max(off) * 1000 if off else 0:.0f} ms of that (render {render_lag * 1000:+.0f} ms)",
              flush=True)
    gain = levels.gains({k: levels.loudness(x, rate) for k, x in tracks.items()})
    print("gains: " + ", ".join(f"{k} {20 * np.log10(g):+.1f} dB" for k, g in gain.items()))
    seconds = song["bars"] * 4 * 60 / song["tempo"] - first_note + LEAD + 2
    n = min(min(len(t) for t in tracks.values()), int(seconds * rate))
    m = sum(gain[k] * tracks[k][:n] for k in tracks)
    m *= 0.89 * 32767 / max(1.0, np.abs(m).max())
    wav = os.path.join(out, "band.wav")
    with wave.open(wav, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(m.astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-codec:a", "libmp3lame",
                    "-b:a", "192k", os.path.join(out, "band.mp3")], check=True)
    print(f"{n / rate:.1f} s mixed into {wav} and band.mp3", flush=True)


def main():
    song = pick(sys.argv)
    mix(sys.argv[1], sys.argv[2], song)


if __name__ == "__main__":
    main()
