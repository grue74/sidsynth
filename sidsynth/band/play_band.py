# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The band: Pro-16 plays the cover from its disk to SID101, SID303 and
SID808, four VICEs in real time, each synth's sound recorded and mixed.

    python play_band.py work/trip2jupiter.d64 work/band work/cover.mid

1. Pro-16 (VICE 1) with the disk: the song TRIP2JUPITER loaded (DSK LOD).
2. SID101, SID303, SID808 (VICEs 2-4), each its MIDI in on its port, its
   sound to a WAV; their sounds set over MIDI (the song's setup, songs.py).
3. RETURN on Pro-16: the session routes its notes by channel (1 SID101,
   2 SID303, 10 SID808) and logs when each went out.
4. Stopped after the song; every VICE quits; the three parts (as they
   are: out/<synth>.wav) mixed into out/band.wav and band.mp3 (mix_band.py:
   lined up on their notes, balanced).
Screenshots of the four screens while it plays: out/screens-*.png.
"""
import json
import os
import shutil
import sys
import time

import mix_band
from session import Session
from record_cover import compare
from songs import pick
from vice import Vice
import vice_band

PROJECTS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SYNTHS = {"sid101": os.path.join(PROJECTS, "sid101", "sid101.prg"),
          "sid303": os.path.join(PROJECTS, "sid303", "sid303.prg"),
          "sid808": os.path.join(PROJECTS, "sid808", "sid808.prg")}


def load_song(s, name):
    p = s.p
    p.keys("T", "DOWN", "DOWN", "DOWN", "DOWN", "DOWN", after=0.3)
    for _ in range(5):
        p.press("RIGHT", after=0.3)             # the DSK box: LOD
    p.press("D", after=0.8)
    for ch in name:
        p.press(ch, after=0.3)
    p.press("RETURN", after=25)
    p.press("SPACE", after=1)
    p.press("T", after=0.3)



def main():
    song = pick(sys.argv)
    disk, out, src = sys.argv[1:4]
    clocks = song["bars"] * 4 * 24
    seconds = song["bars"] * 4 * 60 / song["tempo"] + 8     # the song and Pro-16's start
    os.makedirs(out, exist_ok=True)
    s = Session(bars=4, disk=disk, title="pro16")   # setup is overwritten by the load
    load_song(s, song["name"])
    s.shot(os.path.join(out, "pro16-loaded.png"))
    synths = {}
    for name, prg in SYNTHS.items():
        synths[name] = Vice(name, midi=vice_band.vice_args(name, s.nums, midi_out=False),
                            wav="w.wav", prg=prg)
    time.sleep(8)                                   # the synths start up
    for name, msgs in song["setup"].items():
        for m in msgs:
            s.ports[name].send(bytes(m))
    time.sleep(1)

    # play, with screenshots now and then
    with s.lock:
        s.log = []
        s.route = True
        s.route_until = clocks          # not the song's start again
    s.p.press("RETURN", after=0)
    shots = 0
    t_end = time.time() + seconds
    while time.time() < t_end:
        time.sleep(15)
        if shots < 6:
            for name, v in [("pro16", s.p.v)] + list(synths.items()):
                v.shot(os.path.join(out, f"screens-{shots}-{name}.png"))
            shots += 1
    s.p.press("STOP", after=1)
    with s.lock:
        s.route = False
        log = list(s.log)
    # Pro-16's playing against the file, clock by clock
    print("Pro-16's playing: " + json.dumps(compare(log, src, clocks)), flush=True)
    time.sleep(2)
    for name, v in synths.items():
        v.quit()
    time.sleep(2)
    for name, v in synths.items():
        shutil.copy(os.path.join(v.dir, "w.wav"), os.path.join(out, f"{name}.wav"))
    s.close()

    mix_band.mix(out, src, song)
    os._exit(0)


if __name__ == "__main__":
    main()
