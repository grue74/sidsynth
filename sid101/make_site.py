# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds SID101's web page into the SidSynth site: ../sidsynth/site/sid101/.

The SidSynth site (projects/sidsynth) is the one web site of the family:
its main page at the root, each synth's page in a folder of its own,
linking back with "../". sidsynth/make_site.py runs this and writes the
main page; upload sidsynth/site/ as it is.

    python make_site.py

Run build.sh, docs/icon.py and docs/manual.py first (the screenshots in
docs/ come from tools/screenshots.sh, the video from demos/video_demo.py).
The page shows the demo video, plays the five stage demos (demos/*.wav as
MP3s made with ffmpeg, a waveform each) and offers the disk image, the
program, the manual, the video, the WAV recordings and the source as
downloads. SID303's make_site.py is the model. The page can go on any
static web host as is; nothing is loaded from other servers.
"""
import array
import html
import json
import os
import shutil
import subprocess
import wave
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(os.path.dirname(ROOT), "sidsynth", "site", "sid101")  # see above

# the demos: file name (demos/<name>.wav), title, what it plays, the
# program that plays it
DEMOS = [
    ("a-voice", "The voice", "A bass with glides, a squelch with the cutoff "
     "opening step by step, a PWM lead with vibrato, and a filter sweep over "
     "the sub two octaves down.", "sid101-demo.prg"),
    ("b-sync", "Sync mode", "The synced saw: a riff swept by the envelope on "
     "every note, the sync pitch turned by hand, a sync bass and a sync lead "
     "with glide.", "sid101-sync.prg"),
    ("c-modulation", "Modulation", "Sample and hold on the cutoff, a square "
     "trill, the LFO fading in after each note, the mod wheel, accent off and "
     "on, and everything at once.", "sid101-mod.prg"),
    ("d-sequencer", "Step sequencer", "A song of the four patterns SID101 "
     "starts with: a bass line with slides, a lead with ties, a sync riff and "
     "a 12-step bounce.", "sid101-seq.prg"),
    ("e-arpeggiator", "Arpeggiator", "Up, up and down, a fast run down on the "
     "sync lead, random with glide, and the arpeggio turned off with a key "
     "held.", "sid101-arp.prg"),
    ("g-presets", "Presets", "The 31 factory presets one after another, each chosen by "
     "MIDI program change: basses, leads, arpeggios and the C64 mode's leads and "
     "chords.", "sid101-presets.prg"),
    ("h-c64-voice", "C64 lead", "The C64 mode: a pulse lead with its own slow PWM "
     "sweep and vibrato coming in late, then with its echo, a riff with noise, saw "
     "and square clicks, and all of it with the sub.", "sid101-c64.prg"),
    ("h2-c64-chords", "C64 chords", "Chords as fast arpeggios on one voice: shapes "
     "on single keys, chords held on the keys, octave arpeggios on a melody, and the "
     "arpeggiator with a chord on each note.", "sid101-chords.prg"),
]

# the video on the page (demos/<name>.mp4, demos/video_demo.py) and the
# second its poster is taken at
VIDEO = ("video-demo", 11.0)

DOWNLOADS = [
    ("sid101.d64", "Disk image",
     "The synth, with room on the disk for your songs and banks. Start with "
     "LOAD\"SID101\",8 and RUN."),
    ("sid101-demos.d64", "Demo disk", "The eight demo programs, each playing by itself."),
    ("sid101.prg", "Program", "The synth on its own, for SD2IEC, Ultimate or emulators."),
    ("SID101-manual.pdf", "Manual",
     "Controls, every parameter, MIDI, the arpeggiator, the step sequencer, starting points."),
    ("video-demo.mp4", "Video", "The demo video above, 1152x816 (H.264, AAC)."),
    ("sid101-demos-wav.zip", "Recordings", "The demos as WAV (48 kHz, 16-bit mono)."),
    ("sysex.py", "SysEx tool",
     "Fetch the song or the preset bank over MIDI and send them back (Python, mido)."),
    ("sid101-source.zip", "Source", "64tass assembly, table generator, checks and build scripts."),
]

# file types left out of the source zip (built programs, recordings, images;
# they are separate downloads)
NOT_SOURCE = (".prg", ".d64", ".wav", ".mp3", ".mp4", ".png", ".pdf", ".zip")


def source_files():
    """Every source file of the project, including submodules: what git
    tracks plus new files not ignored, minus binaries. Walking git instead of
    a hand list keeps the GPL source offer complete when files are added."""
    def git_ls(*args):
        return subprocess.run(["git", "ls-files", *args], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout.splitlines()
    # --recurse-submodules only works with --cached, so untracked files
    # (new, not yet committed) come from a second call
    files = set(git_ls("--cached", "--recurse-submodules"))
    files |= set(git_ls("--others", "--exclude-standard"))
    return sorted(f for f in files if not f.lower().endswith(NOT_SOURCE)
                  and not directions(f) and os.path.isfile(os.path.join(ROOT, f)))


# files of directions for the AI assistant the project is worked with (its
# instructions and working rules), not part of the program's source: left
# out of the zip
NOT_IN_ZIP = ("CLAUDE.md", "docs/shared-parts.md")


def directions(f):
    """True for a file of directions (NOT_IN_ZIP, any CLAUDE.md, .claude/)."""
    return (f in NOT_IN_ZIP or os.path.basename(f) == "CLAUDE.md"
            or f.startswith(".claude/") or "/.claude/" in f)


PEAKS = 240                       # waveform bars per track


def peaks(path):
    """Peak level 0..1 per bar, scaled so the loudest bar is 1."""
    with wave.open(path) as w:
        data = array.array("h", w.readframes(w.getnframes()))
    step = max(1, len(data) // PEAKS)
    p = [max(abs(s) for s in data[i:i + step]) for i in range(0, step * PEAKS, step)]
    top = max(p) or 1
    return [round(v / top, 3) for v in p]


def duration(path):
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def mp3(src, dst):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src,
                    "-codec:a", "libmp3lame", "-b:a", "192k", dst], check=True)


def size_text(path):
    n = os.path.getsize(path)
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:.1f} MB"


def main():
    # empty site/sid101/ file by file: the folders themselves may be held
    # open (a browser showing the page, OneDrive syncing), so they are kept
    for d, _, fs in os.walk(SITE):
        for f in fs:
            os.remove(os.path.join(d, f))
    for d in ("audio", "files"):
        os.makedirs(os.path.join(SITE, d), exist_ok=True)

    # audio: MP3 for playing, waveform peaks for drawing
    tracks = []
    for name, title, desc, prg in DEMOS:
        wav = os.path.join(ROOT, "demos", name + ".wav")
        out = f"audio/{name}.mp3"
        mp3(wav, os.path.join(SITE, out))
        tracks.append({"id": name, "title": title, "desc": desc, "prg": prg, "src": out,
                       "peaks": peaks(wav), "len": round(duration(wav), 2)})

    # downloads
    files = os.path.join(SITE, "files")
    for f in ("sid101.d64", "sid101-demos.d64", "sid101.prg"):
        shutil.copy(os.path.join(ROOT, f), files)
    shutil.copy(os.path.join(ROOT, "docs", "SID101-manual.pdf"), files)
    shutil.copy(os.path.join(os.path.dirname(ROOT), "core", "sysex.py"), files)  # the PC side of the dumps
    for f in ("screen.png", "screen-steps.png"):
        shutil.copy(os.path.join(ROOT, "docs", f), SITE)
    # the icon (docs/icon.py)
    for f in ("favicon.svg", "favicon-32.png", "apple-touch-icon.png"):
        shutil.copy(os.path.join(ROOT, "docs", f), SITE)
    # the video: in files/ (played and downloaded from there), a poster frame
    name, at = VIDEO
    shutil.copy(os.path.join(ROOT, "demos", name + ".mp4"), files)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(at), "-i",
                    os.path.join(ROOT, "demos", name + ".mp4"), "-frames:v", "1",
                    "-q:v", "3", os.path.join(SITE, name + ".jpg")], check=True)
    shutil.copy(os.path.join(ROOT, "LICENSE"), os.path.join(files, "LICENSE.txt"))
    with zipfile.ZipFile(os.path.join(files, "sid101-demos-wav.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for name, *_ in DEMOS:
            z.write(os.path.join(ROOT, "demos", name + ".wav"), f"sid101-demos/{name}.wav")
    with zipfile.ZipFile(os.path.join(files, "sid101-source.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for f in source_files():
            z.write(os.path.join(ROOT, f), "sid101/" + f)

    rows = []
    for f, label, desc in DOWNLOADS:
        rows.append(
            f'<a class="dl" href="files/{f}" download>'
            f'<span class="dl-label">{html.escape(label)}</span>'
            f'<span class="dl-name">{html.escape(f)}</span>'
            f'<span class="dl-desc">{html.escape(desc)}</span>'
            f'<span class="dl-size">{size_text(os.path.join(files, f))}</span></a>')

    # build number written by build.sh, the same one the program shows
    try:
        build = open(os.path.join(ROOT, "build-number.txt")).read().strip()
    except OSError:
        build = "?"

    page = TEMPLATE.replace("%DOWNLOADS%", "\n".join(rows)).replace(
        "%TRACKS%", json.dumps(tracks, separators=(",", ":"))).replace("%BUILD%", build).replace(
        "%VIDEO%", VIDEO[0])
    with open(os.path.join(SITE, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    total = sum(os.path.getsize(os.path.join(d, x)) for d, _, fs in os.walk(SITE) for x in fs)
    print(f"sidsynth/site/sid101/ written: {total / 1024 / 1024:.1f} MB")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SID101</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="description" content="An SH-101 style lead synth for the Commodore 64 with an 8580 SID: saw, pulse and sub, sync lead, arpeggiator and step sequencer. Listen to the demos and download the disk image.">
<style>
:root {
  --bg: #f3f6fb; --panel: #ffffff; --line: #d9e1ee; --text: #18202e;
  --muted: #5a6478; --accent: #2a5fc4; --accent-soft: #e2ebfa; --wave: #c4d2ea;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", Consolas, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e131c; --panel: #161d2a; --line: #273246; --text: #e5eaf3;
    --muted: #97a3b8; --accent: #7fa8ff; --accent-soft: #1f2d4d; --wave: #303d58;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main { max-width: 860px; margin: 0 auto; padding: 48px 16px 64px; }
h1, h2, .mono { font-family: var(--mono); }
h1 { font-size: clamp(30px, 6vw, 46px); letter-spacing: .02em; margin: 0 0 6px; }
h1 span { color: var(--accent); }
.home { display: inline-block; margin-bottom: 10px; font-family: var(--mono); font-size: 13px;
        color: var(--muted); text-decoration: none; }
.home:hover { color: var(--accent); }
h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .12em;
     color: var(--muted); margin: 56px 0 16px; font-weight: 600; }
p { margin: 0 0 12px; }
.lede { font-size: 19px; color: var(--muted); max-width: 640px; margin-bottom: 28px; }
.hero { display: grid; grid-template-columns: 1fr; gap: 24px; align-items: start; }
.hero + .hero { margin-top: 32px; }
@media (min-width: 760px) { .hero { grid-template-columns: 1.15fr 1fr; } }
figure { margin: 0; }
.video video { width: 100%; aspect-ratio: 384 / 272; display: block; background: #000;
               border-radius: 8px; border: 1px solid var(--line); }
figcaption { color: var(--muted); font-size: 14px; margin-top: 6px; }
.screen { width: 100%; image-rendering: pixelated; border-radius: 6px;
          border: 1px solid var(--line); display: block; }
.facts { list-style: none; padding: 0; margin: 0; }
.facts li { padding: 8px 0; border-bottom: 1px solid var(--line); }
.facts li:last-child { border-bottom: 0; }
.facts b { font-weight: 600; }
.cta { display: inline-block; margin-top: 18px; padding: 11px 18px; border-radius: 6px;
       background: var(--accent); color: var(--bg); text-decoration: none; font-weight: 600; }
.cta:hover { filter: brightness(1.08); }

/* player */
.track { display: grid; grid-template-columns: 44px 1fr; gap: 6px 14px;
         background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
         padding: 14px 16px; margin-bottom: 10px; }
.play { width: 44px; height: 44px; border-radius: 50%; border: 0; cursor: pointer;
        background: var(--accent-soft); color: var(--accent); display: grid; place-items: center; }
.play svg { width: 18px; height: 18px; fill: currentColor; }
.track.playing .play { background: var(--accent); color: var(--panel); }
.head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; min-width: 0; }
.head h3 { margin: 0; font-size: 17px; }
.time { font-family: var(--mono); font-size: 13px; color: var(--muted); margin-left: auto; }
.desc { grid-column: 2; color: var(--muted); font-size: 14.5px; margin: 0; }
.prg { grid-column: 2; font-family: var(--mono); font-size: 12.5px; color: var(--muted); }
canvas { grid-column: 1 / -1; width: 100%; height: 44px; cursor: pointer; display: block; margin-top: 6px; }

/* downloads */
.dls { display: grid; gap: 8px; }
.dl { display: grid; grid-template-columns: 1fr auto; gap: 2px 16px; text-decoration: none;
      color: var(--text); background: var(--panel); border: 1px solid var(--line);
      border-radius: 8px; padding: 12px 16px; }
.dl:hover { border-color: var(--accent); }
.dl-label { font-weight: 600; }
.dl-name { font-family: var(--mono); font-size: 13px; color: var(--accent); grid-column: 1;
           overflow-wrap: anywhere; }
.dl-desc { color: var(--muted); font-size: 14px; grid-column: 1; }
.dl-size { grid-column: 2; grid-row: 1 / span 3; align-self: center;
           font-family: var(--mono); font-size: 13px; color: var(--muted); }
.note { background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--accent);
        border-radius: 6px; padding: 12px 16px; font-size: 15px; color: var(--muted); }
code, kbd { font-family: var(--mono); font-size: .92em; }
kbd { border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 5px; }
footer a { color: var(--accent); }
footer { margin-top: 64px; color: var(--muted); font-size: 14px; border-top: 1px solid var(--line); padding-top: 16px; }
</style>
</head>
<body>
<main>
  <a class="home" href="../">&larr; SidSynth</a>
  <h1>SID<span>101</span></h1>
  <p class="lede">A monophonic lead and bass synth for the Commodore 64 and its 8580 SID chip, in the spirit of the Roland SH-101. Saw, pulse and sub on the SID's three voices through one resonant filter, a sync lead, the C64's own 80s lead with its chords, an arpeggiator and a step sequencer. Play it from a MIDI keyboard or the C64's own keys.</p>

  <div class="hero">
    <img class="screen" src="screen.png" alt="The SID101 screen: the Sound page's parameters with bars, values and MIDI controller numbers">
    <ul class="facts">
      <li><b>SH-101 voice:</b> saw, pulse with PWM and a sub-oscillator (one or two octaves down, or a narrow pulse), each with its own level, one note on all three SID voices.</li>
      <li><b>Filter and envelope:</b> the 8580's resonant low-pass with an ADSR, the amp on the envelope or a plain gate.</li>
      <li><b>Sync mode:</b> the pulse voice hard-synced to the saw, its pitch swept by hand or by the envelope.</li>
      <li><b>C64 mode:</b> the lead of Rob Hubbard's and Martin Galway's tunes: a pulse lead with its own PWM sweep, an echo, a click at each note, and chords as fast arpeggios on one voice, from a chord shape or the keys held.</li>
      <li><b>LFO</b> in four shapes (triangle, square, sample and hold, noise) with a fade-in, to pitch, pulse width and cutoff; glide Off, On or Auto.</li>
    </ul>
  </div>
  <div class="hero">
    <img class="screen" src="screen-steps.png" alt="The SID101 step screen: 16 steps with notes, accent and slide marks, and a lane showing each note's pitch">
    <ul class="facts">
      <li><b>Arpeggiator:</b> up, down, up and down or random over one to three octaves, at 1/8, 1/16 or 1/32, on its own tempo or MIDI clock.</li>
      <li><b>Step sequencer:</b> 64 patterns of up to 16 steps with accent, slide and tie, songs with transpose, 16 steps of undo.</li>
      <li><b>MIDI</b> in and out through Datel, Sequential, Passport or Namesoft cartridges, with learn for any knob; paddles on cutoff and resonance.</li>
      <li><b>32 presets</b> with names: 31 factory sounds, recalled with C= + F3/F4 or MIDI program change; store your own, save and load them as a bank.</li>
      <li><b>Saved to disk:</b> patterns, song, tempo and the whole sound in one file.</li>
    </ul>
  </div>
  <a class="cta" href="files/sid101.d64" download>Download the disk image</a>

  <h2 id="watch">Watch</h2>
  <figure class="video">
    <video id="video" controls preload="none" playsinline poster="%VIDEO%.jpg" src="files/%VIDEO%.mp4"></video>
    <figcaption>A lead typed into an empty pattern note by note, with slides, and played; then, while it plays, the sound shaped a control at a time (resonance, env mod, sustain, the pulse, less sub, PWM), and the cutoff closed and swept open. Recorded in VICE with the 8580 SID.</figcaption>
  </figure>

  <h2 id="listen">Listen</h2>
  <p>One demo for each stage SID101 was built in, and one of the factory presets. Each is a program on the disk that plays by itself.</p>
  <div id="tracks"></div>
  <p class="note">Recorded in the VICE emulator (x64sc, reSID 8580 model) in real time, not on real hardware. A real 8580 will sound a little different.</p>

  <h2 id="download">Download</h2>
  <div class="dls">
%DOWNLOADS%
  </div>

  <h2>Getting started</h2>
  <p>You need a PAL Commodore 64 with an <b>8580 SID</b> (a C64C, or any C64 with an 8580 fitted). A 6581 runs it, but its filter sounds quite different. A MIDI cartridge and paddles are optional.</p>
  <p>Load it with <kbd>LOAD"SID101",8</kbd> and <kbd>RUN</kbd>. The keyboard plays like a piano: <kbd>Z</kbd> <kbd>X</kbd> <kbd>C</kbd>… are white keys and <kbd>S</kbd> <kbd>D</kbd>… black keys, with a second octave on <kbd>Q</kbd> <kbd>W</kbd> <kbd>E</kbd>… and the number row. Hold one note and play another to glide. <kbd>F1</kbd>/<kbd>F2</kbd> choose a parameter and <kbd>F3</kbd>/<kbd>F4</kbd> change it; the parameters are on two pages, the sound and the playing. The manual has them all.</p>
  <p>Hold <kbd>C=</kbd> and press <kbd>F3</kbd> to step through the 32 presets (with <kbd>SHIFT</kbd>, back); their number and name show in the title row. <kbd>C=</kbd> + <kbd>RETURN</kbd> stores the sound under a name of your own, and <kbd>C=</kbd> + <kbd>W</kbd> / <kbd>L</kbd> save and load all the presets as a bank on disk.</p>
  <p>For the arpeggiator, set <b>Arpeggio</b> to Up and hold a chord, or pick one of the Arp presets. <kbd>F7</kbd> opens the step sequencer, which starts with four patterns: press <kbd>RUN/STOP</kbd> to hear the first. To hear velocity and the sequencer's accents, turn <b>Accent</b> up (the SH-101 has none, so it starts at 0).</p>
  <p>In VICE, use <code>x64sc</code> with the SID model set to 8580. For MIDI, enable a MIDI cartridge of type Datel/Siel under the cartridge/IO settings. With a <b>Kerberos</b> cartridge, start SID101 from the Kerberos menu or App with the MIDI emulation set to Datel.</p>

  <footer>SID101 build %BUILD% · © 2026 Jarkko Lehti · Free software under the <a href="files/LICENSE.txt">GNU GPL v3 or later</a>; the source is in the downloads above. Part of <a href="../">SidSynth</a>, with SID303 and SID808.</footer>
</main>

<script>
const TRACKS = %TRACKS%;
const ICON_PLAY = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5v15l13-7.5z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4h4.5v16H6zM13.5 4H18v16h-4.5z"/></svg>';
const audio = new Audio();
audio.preload = "none";
const video = document.getElementById("video");
video.addEventListener("play", () => { if (!audio.paused) audio.pause(); });
audio.addEventListener("play", () => { if (!video.paused) video.pause(); });
let current = null;
const rows = {};

const fmt = s => Math.floor(s / 60) + ":" + String(Math.floor(s % 60)).padStart(2, "0");
const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

function draw(id) {
  const r = rows[id], c = r.canvas, dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth, h = c.clientHeight;
  if (!w) return;
  c.width = w * dpr; c.height = h * dpr;
  const g = c.getContext("2d");
  g.scale(dpr, dpr);
  const p = TRACKS[r.index].peaks, n = p.length;
  const played = current === id && audio.duration ? audio.currentTime / audio.duration : 0;
  const bw = w / n, on = css("--accent"), off = css("--wave");
  for (let i = 0; i < n; i++) {
    const bh = Math.max(1.5, p[i] * (h - 4));
    g.fillStyle = (i + 0.5) / n <= played ? on : off;
    g.fillRect(i * bw, (h - bh) / 2, Math.max(1, bw - 1), bh);
  }
}

function update(id) {
  const r = rows[id], t = TRACKS[r.index];
  const playing = current === id && !audio.paused;
  r.el.classList.toggle("playing", playing);
  r.btn.innerHTML = playing ? ICON_PAUSE : ICON_PLAY;
  r.btn.setAttribute("aria-label", (playing ? "Pause " : "Play ") + t.title);
  r.time.textContent = (current === id ? fmt(audio.currentTime) + " / " : "") + fmt(t.len);
  draw(id);
}

function load(id, at) {
  current = id;
  audio.src = TRACKS[rows[id].index].src;
  audio.currentTime = at || 0;
}

function toggle(id) {
  if (current !== id) {
    const old = current;
    load(id, 0);
    audio.play();
    if (old) update(old);
  } else if (audio.paused) audio.play(); else audio.pause();
  update(id);
}

function seek(id, frac) {
  const len = TRACKS[rows[id].index].len;
  if (current !== id) { const old = current; load(id, frac * len); if (old) update(old); }
  else audio.currentTime = frac * (audio.duration || len);
  audio.play();
  update(id);
}

const list = document.getElementById("tracks");
TRACKS.forEach((t, index) => {
  const el = document.createElement("div");
  el.className = "track";
  el.innerHTML =
    '<button class="play" type="button"></button>' +
    '<div class="head"><h3></h3><span class="time"></span></div>' +
    '<p class="desc"></p><div class="prg"></div><canvas aria-hidden="true"></canvas>';
  el.querySelector("h3").textContent = t.title;
  el.querySelector(".desc").textContent = t.desc;
  el.querySelector(".prg").textContent = t.prg;
  list.appendChild(el);
  const r = rows[t.id] = { index, el, btn: el.querySelector(".play"),
                           time: el.querySelector(".time"), canvas: el.querySelector("canvas") };
  r.btn.addEventListener("click", () => toggle(t.id));
  r.canvas.addEventListener("click", e => {
    const b = r.canvas.getBoundingClientRect();
    seek(t.id, Math.min(1, Math.max(0, (e.clientX - b.left) / b.width)));
  });
  update(t.id);
});

audio.addEventListener("timeupdate", () => current && update(current));
audio.addEventListener("play", () => current && update(current));
audio.addEventListener("pause", () => current && update(current));
audio.addEventListener("ended", () => { const id = current; audio.currentTime = 0; if (id) update(id); });
window.addEventListener("resize", () => Object.keys(rows).forEach(draw));
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => Object.keys(rows).forEach(draw));
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
