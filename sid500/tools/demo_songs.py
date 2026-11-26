"""demo_songs.py - the demo tunes as SID500 song files for the release disk:
songs/<title>.s5 from tools/tune_<key>.py (the same songs the demo videos
play, tools/demo_tunes.py). build.sh puts them on sid500.d64 under their
titles, so SID500's directory (C= D on the song screen) lists them.

The Moonlight Sonata's needs its score downloaded into work/moonlight/
(tools/tune_moonlight.py), so the files are made here once and kept in git.

    python tools/demo_songs.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

SONGS = [  # (tune module key, the file's name on the disk: 16 characters at most)
    ("dub", "echo chamber.s5"), ("synth", "glass horizon.s5"),
    ("pop", "summer signal.s5"), ("moonlight", "moonlight.s5")]


def main():
    out = os.path.join(ROOT, "songs")
    os.makedirs(out, exist_ok=True)
    for key, name in SONGS:
        assert len(name) <= 16, name
        tune = __import__(f"tune_{key}").TUNE
        blocks = tune.check()
        with open(os.path.join(out, name), "wb") as f:
            f.write(tune.s5())
        print(f"songs/{name}: {tune.title}, {blocks} blocks of the pool")


if __name__ == "__main__":
    main()
