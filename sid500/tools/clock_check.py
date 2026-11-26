"""clock_check.py - SID500: the time display (src/clock.asm, design 5f)
against a model, in VICE.

Each run builds a test program, lets it play for a while in VICE and looks
at the clock's variables: the tick it has counted to (ck_seen) must be the
tick heard (play_tick; a little ahead only when stopped, at the 16th a
continue plays from), and its text, beat and the time's remainder must be
what the song's place at that tick is:

- the bar and beat from the scenes' bars walked from tick 0 (tables.py
  SCENE_TESTS: 1/4 three times, 3/4, 5/8, then round again with Song on;
  scene 1 looping with Song off), the bar counted on through the rounds;
- the time: the tick x 5 / (4 x BPM) s, the remainder ck_frac.

Runs: a master with Song on at 120, 240 and 40 BPM; Song off; a slave fed
song positions 20, 30 and 46 (in scene 2, scene 3, and once round into
scene 2; tables.py feed 15), each continued for 30 clocks and stopped:
the located place worked out from locate.asm's walk, its rounds and the
16th's time. Each build is looked at after a few different run times.

    python tools/clock_check.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402

C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")

TICKS_PER_QUARTER = 48
TEXT_LEN = 11
LAG_MAX = 40                    # ticks the count may be behind the tick heard (the main
                                # loop held a while by a busy 16th)
RUNS = [  # (name, build options, Song on, BPM, seconds to look after)
    ("master, Song on, 120 BPM", ["TEST_LOG=1", "TEST_PLAY=1", "TEST_SCENES=1", "TEST_TEMPO=120",
     "MIDI_IF_DEFAULT=3"], 1, 120, [2, 4, 7]),
    ("master, Song on, 240 BPM", ["TEST_LOG=1", "TEST_PLAY=1", "TEST_SCENES=1", "TEST_TEMPO=240",
     "MIDI_IF_DEFAULT=3"], 1, 240, [3, 6]),
    ("master, Song on, 40 BPM", ["TEST_LOG=1", "TEST_PLAY=1", "TEST_SCENES=1", "TEST_TEMPO=40",
     "MIDI_IF_DEFAULT=3"], 1, 40, [3, 6]),
    ("master, Song off", ["TEST_LOG=1", "TEST_PLAY=1", "TEST_SCENES=3", "TEST_TEMPO=120",
     "MIDI_IF_DEFAULT=3"], 0, 120, [4]),
    ("slave, song positions 20, 30, 46", ["TEST_LOG=1", "TEST_PLAY=1", "TEST_SCENES=1",
     "TEST_TEMPO=120", "TEST_SLAVE=15", "MIDI_IF_DEFAULT=3"], 1, 120, [1.5, 2.2, 2.9, 3.6, 4.3, 6]),
]


def run(prg, ranges, seconds):
    """Run prg in VICE with a Datel cartridge (MIDI out sent: else its queue
    fills and the main loop waits), at real speed (no warp: the looks land
    where they're asked); memory as {address: byte} for [(start, end)]."""
    cmds = [f"m {a:04x} {b:04x}" for a, b in ranges]
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg, *cmds,
                          "--seconds", str(seconds),
                          "--vice-args", f"{tc.VICE_ARGS['datel']} +warp"],
                         capture_output=True, text=True, check=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            for i, b in enumerate(m.group(2).split()):
                mem[int(m.group(1), 16) + i] = int(b, 16)
    return mem


def labels(path):
    """The label file's names: addresses ($hex) and the variables' (decimal)."""
    out = {}
    for line in open(path):
        name, _, value = line.partition("=")
        value = value.strip()
        if value.startswith("$"):
            out[name.strip()] = int(value[1:], 16)
        elif value.isdigit():
            out[name.strip()] = int(value)
    return out


def bars_of(song_on):
    """The song's bars in order, (ticks, a beat's ticks), one round."""
    _, scenes, _ = tables.SCENE_TESTS[1 if song_on else 3]
    out = []
    for bars, sig, reps in (scenes if song_on else scenes[:1]):
        beats = (sig & 0x0F) + 1
        blen = TICKS_PER_QUARTER // 2 if sig & tables.SIG_EIGHTHS else TICKS_PER_QUARTER
        out += [(beats * blen, blen)] * (bars * reps)
    return out


def model(tick, song_on, bpm):
    """(text, beat, ticks into it, the time's remainder) at the tick."""
    bars = bars_of(song_on)
    n, t = 0, tick
    while t >= bars[n % len(bars)][0]:
        t -= bars[n % len(bars)][0]
        n += 1
    blen = bars[n % len(bars)][1]
    beat, bt = divmod(t, blen)
    secs, frac = divmod(tick * 5, 4 * bpm)
    text = f"{(n + 1) % 1000:03}.{beat + 1:<2}{secs // 60 % 100:>2}:{secs % 60:02}"
    return text, beat, bt, frac


def main():
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True)
    prg = os.path.join(ROOT, "clock-test.prg")
    errors, looks = [], 0
    for name, opts, song_on, bpm, times in RUNS:
        defs = [x for o in opts for x in ("-D", o)]
        subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *defs, "-l", prg + ".lbl",
                        "-o", prg, "sid500.asm"], cwd=ROOT, check=True)
        lab = labels(prg + ".lbl")
        lo, hi = lab["ck_seen"], lab["ck_text"] + TEXT_LEN
        pt = lab["play_tick"]
        print(name)
        for secs in times:
            mem = run(prg, [(lo, hi), (pt, pt + 1)], seconds=secs)
            looks += 1
            seen = mem[lab["ck_seen"]] | mem[lab["ck_seen"] + 1] << 8
            tick = mem[pt] | mem[pt + 1] << 8
            text = bytes(mem[lab["ck_text"] + i] for i in range(TEXT_LEN)).decode("latin-1")
            frac = mem[lab["ck_frac"]] | mem[lab["ck_frac"] + 1] << 8
            got = (text, mem[lab["ck_beat"]], mem[lab["ck_bt"]], frac)
            want = model(seen, song_on, bpm)
            if got != want and got == model(seen + 1, song_on, bpm):
                want = got      # (looked at mid-tick: counted, ck_seen not yet on)
            ahead = (seen - tick + 32768) % 65536 - 32768   # (stopped: at the 16th, a little on)
            ok = got == want and -LAG_MAX <= ahead <= 12
            print(f"   after {secs} s: tick {tick}, counted to {seen}: \"{text}\""
                  + ("" if ok else f"  FAIL, want \"{want[0]}\" (beat, ticks, rest: "
                     f"{got[1:]} / {want[1:]})"))
            if not ok:
                errors.append(f"{name}, {secs} s")
    for f in (prg, prg + ".lbl"):
        if os.path.exists(f):
            os.remove(f)
    print(f"{looks} looks, {len(errors)} wrong")
    print("all passed" if not errors else "FAILED: " + "; ".join(errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
