# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The band's songs: what the scripts need to know of each. A script takes
--song <key> anywhere on its command line (default: the cover).

    from songs import pick
    song = pick(sys.argv)       # removes --song <key> from argv

midi      the MIDI file (the source: transcribe.py, glide_path.py)
name      the song's name on Pro-16's disk
bars      the sequence's length in bars, tempo its BPM
setup     MIDI to each synth before the song (play_band.py, feeds.py)
labels    the video's labels (compose.py)
renders   the folder of the parts' exact renders (vicerec.py: <synth>.mp4), the
          live mix's reference (mix_band.py)
"""
import sys

SONGS = {
    "cover": dict(midi="work/cover.mid", name="TRIP2JUPITER", bars=64, tempo=94,
                  setup={"sid101": [[0xC0, 18]]},           # factory preset 19, Perc blip
                  labels={"sid101": "SID101  arpeggio (ch 1)"}, renders="work/video"),
    "glide": dict(midi="work/glide-path.mid", name="GLIDEPATH", bars=49, tempo=125,
                  setup={},                                 # the file sets every sound
                  labels={"sid101": "SID101  lead (ch 1)"}, renders="work/glide-video"),
}


def pick(argv=sys.argv):
    """The song named by --song <key> (removed from argv), else the cover;
    its key is in song["key"]."""
    key = "cover"
    if "--song" in argv:
        i = argv.index("--song")
        key = argv[i + 1]
        del argv[i:i + 2]
    if key not in SONGS:
        sys.exit(f"--song: one of {', '.join(SONGS)}")
    return dict(SONGS[key], key=key)
