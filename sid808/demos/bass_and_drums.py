# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The bass-and-drums demo: SID808's drums and SID303's bass, composed
together, on two C64s recorded in VICE and put side by side.

    python demos/bass_and_drums.py [--vice PATH] [--name bass-and-drums-3]

The drum part is tables.py's DEMO_* patterns: SID808 built with TEST_SONG=1
TEST_SEQ=1 plays them as a song on its own sequencer. The bass part is
BASS below: a copy of SID303 (../sid303) built with it as its
TEST_MIDI=1 feed. Both are 16 bars at 125 BPM, then two silent bars, and
loop. vicerec.py (c64tools) records each for 72 s; it starts grabbing a few
seconds into the program, so each part's second pass is found by the
silence before it, and the bass's first note is put on the drums' first
hit (this also takes out SID808's attack latency). Writes demos/<name>.wav
(the mix, mono in both channels) and demos/<name>.mp4 (1920x1080, both
screens). Needs python, 64tass, ffmpeg, numpy and VICE (x64, 8580 reSID).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SID303 = os.path.join(os.path.dirname(ROOT), "sid303")
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
VICE_DEFAULT = "E:/github/svn-mirror/vice/out/build/headless/x64.exe"

sys.path.insert(0, ROOT)
import tables  # noqa: E402  (DEMO_BARS, the drum part)

BPM = 125
BAR_S = 4 * 60 / BPM
PASS_BARS = tables.DEMO_BARS + 2        # the song, then two silent bars
SR = 48000

# -----------------------------------------------------------------------------
# The bass part. A bar is 16 steps: a note name (A1 = MIDI 33), "." a rest,
# "-" holding the note before; ">" after a note accents it, "~" slides it
# into the next one. CUTOFF: SID303's cutoff (CC 74) per bar, or a pair
# (from, to) swept over the bar's steps.
# -----------------------------------------------------------------------------
RIFF = "A1> . A1 . A2~ G2 . A1 . A1 C2> . A1 . G1~ A1"
TURN = "A1> . A1 . A2~ G2 . A1 . A1 D2> . C2 . E2~ D2"
DRIVE = "A1> A1 A2 A1 G2~ A2 A1 C2> A1 A1 D2~ E2 A1 G1> A1 C2"
END = "A1> - - - - - - - - - - - - - . ."
BASS = ([RIFF, RIFF, RIFF, TURN] * 3        # bars 1-12, under hats, kick, groove, bell
        + [DRIVE, DRIVE, TURN, END])        # 13-15 the peak, 16 the ending
CUTOFF = ([24, 28, 32, 36, 44, 48, 52, 56, (52, 70), (70, 86), (86, 100), (100, 110),
           112, 112, 104, 60])
assert len(BASS) == len(CUTOFF) == tables.DEMO_BARS

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def midi_note(name):
    """'A1' -> 33, 'C#2' -> 37."""
    m = re.fullmatch(r"([A-G])(#?)(\d)", name)
    return 12 * (int(m.group(3)) + 1) + NOTE[m.group(1)] + (1 if m.group(2) else 0)


def bass_feed(tick_hz=250):
    """SID303's test_feed bytes for BASS: (count, bytes..., wait) entries,
    count 0 = start again. Velocity 127 accented, 100 not; a note ends at 60 %
    of its last step, or a tick into the next step when it slides."""
    step = round(tick_hz * 60 / BPM / 4)            # 30 ticks at 250 Hz
    gate = step * 6 // 10
    events = []                                     # (tick, order, bytes)
    for b, bar in enumerate(BASS):
        t0 = b * 16 * step
        c = CUTOFF[b]
        for i in range(16):
            if isinstance(c, tuple):
                v = round(c[0] + (c[1] - c[0]) * i / 15)
            elif i:
                continue
            else:
                v = c
            events.append((t0 + i * step, 0, [0xB0, 74, v]))
        toks = bar.split()
        assert len(toks) == 16, (b, bar)
        for i, tok in enumerate(toks):
            if tok in (".", "-"):
                continue
            accent, slide = ">" in tok, "~" in tok
            note = midi_note(tok.rstrip(">~"))
            t = t0 + i * step
            n = 1
            while i + n < 16 and toks[i + n] == "-":
                n += 1
            off = t + step + 1 if slide else t + (n - 1) * step + gate
            events.append((t, 2, [0x90, note, 127 if accent else 100]))
            events.append((off, 1, [0x90, note, 0]))
    end = PASS_BARS * 16 * step
    events.sort(key=lambda e: (e[0], e[1]))
    entries = []
    for t, _, msg in events:
        if entries and entries[-1][0] == t:
            entries[-1][1].extend(msg)
        else:
            entries.append((t, list(msg)))
    if entries[0][0] != 0:
        entries.insert(0, (0, [0xF8]))
    data = []
    for i, (t, b) in enumerate(entries):
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        wait = nxt - t - 1
        while wait > 255:                           # long rests: clock bytes (ignored)
            data += [len(b)] + b + [255]
            b = [0xF8]
            wait -= 256
        data += [len(b)] + b + [wait]
    data.append(0)
    return data


# -----------------------------------------------------------------------------
# Building
# -----------------------------------------------------------------------------
VIDEO_HOOK = """        ; nothing urgent: redraw one screen row
_idle   jsr video_check         ; (demo build: a call per video frame for vicerec)
        jsr screen_draw_step
        jmp main_loop

; video_check - demo build: video_frame once per frame, when the raster
; line is lower than at the last look (a new frame began)
video_check
        lda $d011               ; raster bit 8 into carry
        asl
        lda $d012
        ror                     ; A = line / 2 (bit 8, then $D012 bits 7-1)
        cmp $cff0
        sta $cff0
        bcs +
        jmp video_frame
+       rts
video_frame
        rts
"""


def run(cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True)


def build_bass(work):
    """SID303 with BASS as its TEST_MIDI=1 feed and the frame hook."""
    src = os.path.join(work, "sid303")
    os.makedirs(src)
    archive = subprocess.run(["git", "archive", "HEAD"], cwd=SID303, check=True,
                             capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", src], input=archive, check=True)
    shutil.copytree(os.path.join(SID303, "core"), os.path.join(src, "core"), dirs_exist_ok=True)
    fw = os.path.join(src, "core", "framework.asm")
    s = open(fw, "rb").read().decode()
    old = "        ; nothing urgent: redraw one screen row\n_idle   jsr screen_draw_step\n        jmp main_loop\n"
    assert s.count(old) == 1
    open(fw, "wb").write(s.replace(old, VIDEO_HOOK).encode())
    run([sys.executable, "tables.py"], cwd=src)
    inc = os.path.join(src, "tables.inc")
    s = open(inc, "rb").read().decode()
    data = bass_feed()
    rows = "\n".join("        .byte " + ",".join(f"${v:02x}" for v in data[i:i + 16])
                     for i in range(0, len(data), 16))
    new = (".if TEST_MIDI == 1\n; the bass-and-drums demo's bass (SID808 demos/bass_and_drums.py)\n"
           f"test_pattern\n{rows}\n.endif\n")
    s, n = re.subn(r"\.if TEST_MIDI == 1\n.*?\.endif\n", lambda m: new, s, count=1, flags=re.S)
    assert n == 1
    open(inc, "wb").write(s.encode())
    build = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=SID303, check=True,
                           capture_output=True, text=True).stdout.strip()
    run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", f"BUILD={build}", "-D", "TEST_MIDI=1",
         "-l", "bass.lbl", "-o", "bass.prg", "sid303.asm"], cwd=src)
    return os.path.join(src, "bass.prg"), label(os.path.join(src, "bass.lbl"), "video_frame")


def build_drums(work):
    """SID808 playing the drum part on its sequencer."""
    build = open(os.path.join(ROOT, "build-number.txt")).read().strip()
    major, minor, patch = open(os.path.join(ROOT, "VERSION")).read().strip().split(".")
    out = os.path.join(work, "drums.prg")
    lbl = os.path.join(work, "drums.lbl")
    run([sys.executable, "tables.py"], cwd=ROOT)
    run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", f"BUILD={build}", "-D", f"V_MAJOR={major}",
         "-D", f"V_MINOR={minor}", "-D", f"V_PATCH={patch}", "-D", "TEST_SONG=1", "-D", "TEST_SEQ=1",
         "-D", "VIDEO_MARK=1", "-D", "UNDO_STEPS=8", "-l", lbl, "-o", out, "sid808.asm"], cwd=ROOT)
    return out, label(lbl, "video_frame")


def label(path, name):
    for line in open(path):
        if line.split("=")[0].strip() == name:
            return line.split("$")[1].strip()
    raise KeyError(name)


def record(prg, frame, out, vice):
    run([sys.executable, os.path.join(C64TOOLS, "vicerec.py"), prg, out, "--frame-addr", frame,
         "--seconds", "72", "--sid", "8580", "--vice", vice])
    wav = out[:-4] + "-a.wav"
    run(["ffmpeg", "-v", "error", "-y", "-i", out, "-vn", "-ac", "1", "-ar", str(SR),
         "-c:a", "pcm_s16le", wav])
    with wave.open(wav) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)


def pass_start(x, gap=1.0):
    """The first sound after `gap` seconds of near silence (a pass begins)."""
    h = SR // 1000
    e = np.abs(x[:len(x) // h * h]).reshape(-1, h).max(1)      # 1 ms
    quiet = 0
    for i in range(len(e)):
        if e[i] < 100:
            quiet += 1
            continue
        if quiet >= gap * 1000:         # sound after the silence: its attack (above 300)
            j = (i - 1) * h
            k = np.nonzero(np.abs(x[j:j + 30 * h]) > 300)[0]
            if len(k):
                return (j + int(k[0])) / SR
        quiet = 0
    raise ValueError("no pass start found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vice", default=VICE_DEFAULT)
    ap.add_argument("--name", default="bass-and-drums-3")
    ap.add_argument("--keep", help="keep the work files in this folder")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="bassdrums-")
    os.makedirs(work, exist_ok=True)

    bass_prg, bass_frame = build_bass(work)
    drums_prg, drums_frame = build_drums(work)
    drums = record(drums_prg, drums_frame, os.path.join(work, "drums.mp4"), a.vice)
    bass = record(bass_prg, bass_frame, os.path.join(work, "bass.mp4"), a.vice)

    # each part's second pass; the bass's first note on the drums' first hit
    pre = 0.30
    d1 = pass_start(drums)
    b1 = pass_start(bass)
    d0, b0 = d1 - pre, b1 - pre
    dur = pre + tables.DEMO_BARS * BAR_S + 2.2         # the ending's crash rings out
    n = int(dur * SR)
    dd = drums[int(d0 * SR):int(d0 * SR) + n]
    bb = bass[int(b0 * SR):int(b0 * SR) + n]
    assert len(dd) == len(bb) == n, "record longer"
    both = slice(int(pre * SR), int((pre + 15 * BAR_S) * SR))
    gain = dd[both].std() / bb[both].std() * 0.85      # the bass a little under the drums
    mix = dd + gain * bb
    fade = int(0.4 * SR)
    mix[-fade:] *= np.linspace(1, 0, fade)
    mix *= 0.92 * 32767 / np.abs(mix).max()
    wav = os.path.join(HERE, a.name + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(np.repeat(mix.astype("<i2"), 2).tobytes())

    font = "C\\:/Windows/Fonts/consola.ttf"
    graph = (f"color=c=0x13131d:s=1920x1080:r=50:d={dur:.3f}[bg];"
             "[1:v]setpts=PTS-STARTPTS,scale=920:652:flags=neighbor[bass];"
             "[0:v]setpts=PTS-STARTPTS,scale=920:652:flags=neighbor[drums];"
             "[bg][bass]overlay=26:214[a];[a][drums]overlay=974:214[b];"
             f"[b]drawtext=fontfile='{font}':text='SID303  bass':fontsize=34:"
             "fontcolor=0x9d93ff:x=26+(920-tw)/2:y=135,"
             f"drawtext=fontfile='{font}':text='SID808  drums':fontsize=34:"
             "fontcolor=0xf08a24:x=974+(920-tw)/2:y=135,"
             f"drawtext=fontfile='{font}':text='two C64s with 8580 SIDs  -  {BPM} BPM  -  "
             "recorded in VICE':fontsize=26:fontcolor=0x8a8aa0:x=(w-tw)/2:y=930[v]")
    run(["ffmpeg", "-v", "error", "-y",
         "-ss", f"{d0:.4f}", "-t", f"{dur:.3f}", "-i", os.path.join(work, "drums.mp4"),
         "-ss", f"{b0:.4f}", "-t", f"{dur:.3f}", "-i", os.path.join(work, "bass.mp4"),
         "-i", wav, "-filter_complex", graph, "-map", "[v]", "-map", "2:a",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "slow",
         "-c:a", "aac", "-b:a", "192k", "-shortest", os.path.join(HERE, a.name + ".mp4")])
    print(f"drums pass at {d1:.3f} s, bass pass at {b1:.3f} s; {dur:.2f} s, bass gain {gain:.2f}")
    print(f"wrote demos/{a.name}.wav and .mp4" + ("" if a.keep else f" (work files: {work})"))


if __name__ == "__main__":
    main()
