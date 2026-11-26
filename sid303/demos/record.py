# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Records the manual's "Starting points" sounds as WAV demos (demos/presets/).

Each preset is the TEST_MIDI build (the acid test line, or the cutoff sweep
for the hard sounds) assembled with that preset's *_DEFAULT values, run in
VICE with the 8580 SID and recorded through VICE's wav sound device. The
recording is cut from the first note to exactly one pass of the pattern.

    python demos/record.py [name ...]      (default: every preset)
    python demos/record.py -D ENVTYPE_DEFAULT=0 --out demos/uponly [name ...]
                                           (A/B take: extra -D for every preset)

Needs 64tass, python and x64sc (C:\\app\\gtkvice\\bin\\x64sc.exe or on PATH).
Run `python tables.py` (or build.sh) first so tables.inc exists.
VICE runs in real time (warp mode records no sound), so each take lasts as long
as its pattern plus loading; all presets are recorded at the same time.
"""
import array
import os
import shutil
import subprocess
import sys
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "demos", "presets")
VICE = r"C:\app\gtkvice\bin\x64sc.exe"
if not os.path.exists(VICE):
    VICE = "x64sc"

RATE = 48000
PAL_HZ = 985248                 # PAL CPU cycles per second
LOAD_SECONDS = 4                # autostart and program start, before the line
STEP = 30 / 250                 # one 16th step: 30 synth ticks at 250 Hz
LINE_SECONDS = 5 * 16 * STEP    # TEST_MIDI=1: four bars + a bar of long notes
SWEEP_SECONDS = 8 * 16 * STEP   # TEST_MIDI=2: eight bars of cutoff sweep
TAIL_SECONDS = 0.5              # silence added after the last note

HARD = dict(FILTER_DEFAULT=1, RESO_DEFAULT=15, ENVMOD_DEFAULT=200,
            DECAY_DEFAULT=1, ACCENT_DEFAULT=15)

# name: (TEST_MIDI pattern, -D options) - one per row of the manual's table
PRESETS = {
    "1-default":       (1, {}),
    "2-hard":          (2, HARD),
    "3-buzzy":         (2, dict(HARD, WAVE_DEFAULT=2)),
    "4-square-bass":   (1, dict(WAVE_DEFAULT=3, BLEND_DEFAULT=6)),
    "5-fuller-bottom": (1, dict(WAVE_DEFAULT=3, BLEND_DEFAULT=6, BODY_DEFAULT=4)),
    "6-held-no-fade":  (1, dict(AMPDECAY_DEFAULT=15)),
}


def build(work, pattern, opts):
    """Assemble the preset's PRG into work/demo.prg."""
    defs = ["-D", f"TEST_MIDI={pattern}"]
    for k, v in opts.items():
        defs += ["-D", f"{k}={v}"]
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *defs,
                    "-o", os.path.join(work, "demo.prg"),
                    os.path.join(ROOT, "sid303.asm")], check=True, cwd=ROOT)


def start_vice(work, seconds):
    """Start VICE recording work/sound.wav for LOAD_SECONDS + seconds."""
    cycles = int((LOAD_SECONDS + seconds + 1) * PAL_HZ)
    args = [VICE, "-default", "+saveres", "-sidenginemodel", "257",
            "-sound", "-sounddev", "wav", "-soundarg", "sound.wav",
            "-soundrate", str(RATE), "-limitcycles", str(cycles),
            "-autostartprgmode", "1", "-autostart", "demo.prg"]
    return subprocess.Popen(args, cwd=work, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def cut(src, dst, seconds):
    """Copy one pattern pass from src to dst, starting at the first note."""
    with wave.open(src) as w:
        assert w.getsampwidth() == 2, "expected 16-bit samples"
        chans = w.getnchannels()
        data = array.array("h", w.readframes(w.getnframes()))
    if chans > 1:                       # keep the first channel
        data = data[::chans]
    # first note: the first sample well above the noise floor, less 5 ms
    onset = next(i for i, s in enumerate(data) if abs(s) > 1500)
    onset = max(0, onset - RATE // 200)
    n = int(seconds * RATE)
    take = data[onset:onset + n]
    if len(take) < n:
        raise RuntimeError(f"{src}: recording too short ({len(take) / RATE:.2f} s)")
    # 10 ms fade-out at the cut so the next pass's first note doesn't click in
    fade = RATE // 100
    for i in range(fade):
        take[n - fade + i] = int(take[n - fade + i] * (fade - i) / fade)
    take.extend([0] * int(TAIL_SECONDS * RATE))
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(take.tobytes())


def parse_args(argv):
    """Preset names, extra -D K=V options for every preset, and --out DIR."""
    names, extra, out_dir = [], {}, OUT_DIR
    it = iter(argv)
    for arg in it:
        if arg == "-D":
            key, _, value = next(it).partition("=")
            extra[key] = value
        elif arg == "--out":
            out_dir = os.path.join(ROOT, next(it))
        else:
            names.append(arg)
    return names or list(PRESETS), extra, out_dir


def main():
    names, extra, out_dir = parse_args(sys.argv[1:])
    os.makedirs(out_dir, exist_ok=True)
    runs = []
    for name in names:
        pattern, opts = PRESETS[name]
        work = tempfile.mkdtemp(prefix="sidrec-")
        build(work, pattern, dict(opts, **extra))
        seconds = SWEEP_SECONDS if pattern == 2 else LINE_SECONDS
        runs.append((name, work, seconds, start_vice(work, seconds)))
    for name, work, seconds, proc in runs:
        proc.wait()
        dst = os.path.join(out_dir, name + ".wav")
        cut(os.path.join(work, "sound.wav"), dst, seconds)
        print(f"{dst}  {seconds + TAIL_SECONDS:.2f} s")
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
