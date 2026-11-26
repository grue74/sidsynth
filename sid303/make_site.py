# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds SID303's web page into the SidSynth site: ../sidsynth/site/sid303/.

The SidSynth site (projects/sidsynth) is the one web site of the family:
its main page at the root, each synth's page in a folder of its own,
linking back with "../". sidsynth/make_site.py runs this and writes the
main page; upload sidsynth/site/ as it is.

    python make_site.py

Run build.sh, demos/record.py (both takes), demos/step_demo.py and
docs/manual.py first. The page shows the step sequencer video, plays the
preset demos (MP3s made from the WAVs with ffmpeg, with an A/B
switch to the Env mod type "Up only" takes) and offers the disk image, programs,
manual, WAV recordings and source as downloads. The page can go on any
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
SITE = os.path.join(os.path.dirname(ROOT), "sidsynth", "site", "sid303")  # see above

# the manual's "Starting points": file name, title, what it is, settings
PRESETS = [
    ("1-default", "Default", "The sound the synth starts with: saw wave, "
     "squelchy filter, accents and slides on the acid line.",
     "Saw · Reso 12 · Env mod 160 · Decay 6 · Accent 10"),
    ("2-hard", "Hard", "The cutoff swept fully open and back down twice, at "
     "full resonance with short, hard accents.",
     "Saw · Low+band · Reso 15 · Env mod 200 · Decay 1 · Accent 15"),
    ("3-buzzy", "Buzzy", "As Hard, with the combined saw+square waveform: "
     "buzzier and brighter.",
     "Saw+square · Low+band · Reso 15 · Env mod 200 · Decay 1 · Accent 15"),
    ("4-square-bass", "Square bass", "The 303-style square: a pulse slanted "
     "by the saw, which adds the even harmonics of the 303 square.",
     "303 square · Tilt 6"),
    ("5-fuller-bottom", "Fuller bottom", "The square bass with an unfiltered "
     "triangle under it for more low end.",
     "303 square · Tilt 6 · Body 4"),
    ("6-held-no-fade", "Held, no fade", "The default sound with the amplitude "
     "fade turned off, so long notes keep their level.",
     "Saw · Amp decay 15 (no fade)"),
]

# the video on the page (demos/<name>.mp4) and the second its poster is taken at
VIDEO = ("step-demo", 11.0)

DOWNLOADS = [
    ("sid303.d64", "Disk image",
     "All three programs on one disk. Start with LOAD\"SID303\",8 and RUN."),
    ("sid303.prg", "Program", "The synth on its own, for SD2IEC, Ultimate or emulators."),
    ("sid303-test.prg", "Demo program",
     "Plays a built-in acid line, so you can hear it without MIDI."),
    ("sid303-sweep.prg", "Sweep demo",
     "The acid line at high resonance with the cutoff swept open and closed."),
    ("SID303-manual.pdf", "Manual", "Controls, parameters, presets, MIDI, the step sequencer, starting points."),
    ("step-demo.mp4", "Video", "The step sequencer demo above, 1152x816 (H.264, AAC)."),
    ("sid303-demos-wav.zip", "Recordings", "All demo takes as WAV (48 kHz, 16-bit mono)."),
    ("sysex.py", "SysEx tool",
     "Fetch the song over MIDI and send it back (Python, mido)."),
    ("sid303-source.zip", "Source", "64tass assembly, table generator and build scripts."),
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
    # empty site/ file by file: the folders themselves may be held open (a
    # browser showing the page, OneDrive syncing), so they are kept
    for d, _, fs in os.walk(SITE):
        for f in fs:
            os.remove(os.path.join(d, f))
    for d in ("audio", "files"):
        os.makedirs(os.path.join(SITE, d), exist_ok=True)

    # audio: MP3 for playing, waveform peaks for drawing
    tracks = []
    for name, title, desc, settings in PRESETS:
        variants = {}
        for key, folder in (("centred", "presets"), ("uponly", "uponly")):
            wav = os.path.join(ROOT, "demos", folder, name + ".wav")
            out = f"audio/{name}-{key}.mp3"
            mp3(wav, os.path.join(SITE, out))
            variants[key] = {"src": out, "peaks": peaks(wav), "len": round(duration(wav), 2)}
        tracks.append({"id": name, "title": title, "desc": desc,
                       "settings": settings, "variants": variants})

    # downloads
    files = os.path.join(SITE, "files")
    for f in ("sid303.d64", "sid303.prg", "sid303-test.prg", "sid303-sweep.prg"):
        shutil.copy(os.path.join(ROOT, f), files)
    shutil.copy(os.path.join(ROOT, "docs", "SID303-manual.pdf"), files)
    shutil.copy(os.path.join(os.path.dirname(ROOT), "core", "sysex.py"), files)  # the PC side of the dumps
    shutil.copy(os.path.join(ROOT, "docs", "screen.png"), SITE)
    shutil.copy(os.path.join(ROOT, "docs", "screen-steps.png"), SITE)
    # the icon (docs/favicon.svg; the PNGs are rendered from it)
    for f in ("favicon.svg", "favicon-32.png", "apple-touch-icon.png"):
        shutil.copy(os.path.join(ROOT, "docs", f), SITE)
    # the video: in files/ (played and downloaded from there), a poster frame
    name, at = VIDEO
    shutil.copy(os.path.join(ROOT, "demos", name + ".mp4"), files)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(at), "-i",
                    os.path.join(ROOT, "demos", name + ".mp4"), "-frames:v", "1",
                    "-q:v", "3", os.path.join(SITE, name + ".jpg")], check=True)
    shutil.copy(os.path.join(ROOT, "LICENSE"), os.path.join(files, "LICENSE.txt"))
    with zipfile.ZipFile(os.path.join(files, "sid303-demos-wav.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for folder in ("presets", "uponly"):
            for name, *_ in PRESETS:
                z.write(os.path.join(ROOT, "demos", folder, name + ".wav"),
                        f"sid303-demos/{folder}/{name}.wav")
    with zipfile.ZipFile(os.path.join(files, "sid303-source.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for f in source_files():
            z.write(os.path.join(ROOT, f), "sid303/" + f)

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
    print(f"sidsynth/site/sid303/ written: {total / 1024 / 1024:.1f} MB")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SID303</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="description" content="A TB-303 style acid bass synth and step sequencer for the Commodore 64 with an 8580 SID. Listen to the demos and download the disk image.">
<style>
:root {
  --bg: #f5f4fa; --panel: #ffffff; --line: #dedcea; --text: #1c1b29;
  --muted: #5f5d75; --accent: #4a3fc0; --accent-soft: #e6e3fb;
  --amber: #a8640a; --amber-soft: #fbefd9; --wave: #c9c5e6;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", Consolas, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #10111c; --panel: #181a2a; --line: #2a2d44; --text: #e7e6f2;
    --muted: #9b9bb6; --accent: #9d93ff; --accent-soft: #272552;
    --amber: #f0b44c; --amber-soft: #3a2d14; --wave: #34375a;
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
.ab { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; margin-bottom: 16px; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
.seg button { font: inherit; font-size: 14px; border: 0; background: var(--panel);
              color: var(--muted); padding: 7px 14px; cursor: pointer; }
.seg button[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
.seg button.alt[aria-pressed="true"] { background: var(--amber-soft); color: var(--amber); }
.ab small { color: var(--muted); font-size: 14px; flex: 1 1 260px; }
.track { display: grid; grid-template-columns: 44px 1fr; gap: 6px 14px;
         background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
         padding: 14px 16px; margin-bottom: 10px; }
.play { width: 44px; height: 44px; border-radius: 50%; border: 0; cursor: pointer;
        background: var(--accent-soft); color: var(--accent); display: grid; place-items: center; }
.play svg { width: 18px; height: 18px; fill: currentColor; }
.track.playing .play { background: var(--accent); color: var(--panel); }
.alt-on .track.playing .play { background: var(--amber); }
.head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; min-width: 0; }
.head h3 { margin: 0; font-size: 17px; }
.time { font-family: var(--mono); font-size: 13px; color: var(--muted); margin-left: auto; }
.desc { grid-column: 2; color: var(--muted); font-size: 14.5px; margin: 0; }
.settings { grid-column: 2; font-family: var(--mono); font-size: 12.5px; color: var(--muted); }
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
  <h1>SID<span>303</span></h1>
  <p class="lede">A monophonic TB-303 style acid bass synth for the Commodore 64 and its 8580 SID chip, with its own step sequencer. Play it from a MIDI keyboard or the C64's own keys, program acid lines on the C64, and bend the filter with paddles.</p>

  <div class="hero">
    <img class="screen" src="screen.png" alt="The SID303 screen: a parameter list with values and MIDI controller numbers">
    <ul class="facts">
      <li><b>303-style voice:</b> saw, square or the 303's slanted square, a resonant filter with envelope, accent and slide.</li>
      <li><b>303 accents:</b> a louder pluck, a short filter decay and a cutoff kick that builds up over back-to-back accents.</li>
      <li><b>MIDI in</b> through Datel, Sequential, Passport or Namesoft cartridges, with MIDI learn for any knob.</li>
      <li><b>Paddles</b> on cutoff and resonance, or learnt onto any parameter; the function keys edit everything else.</li>
      <li><b>32 presets</b> with names, 22 factory acid sounds to start from; recalled with C= + F3/F4 or MIDI program change, saved as a bank.</li>
    </ul>
  </div>
  <div class="hero">
    <img class="screen" src="screen-steps.png" alt="The SID303 step screen: 16 steps with notes, accent and slide marks, and a lane showing each note's pitch">
    <ul class="facts">
      <li><b>Step sequencer:</b> 64 patterns of up to 16 steps with accent, slide and tie, entered note by note from the C64 keyboard.</li>
      <li><b>Songs</b> chain the patterns with repeats and a transpose per entry, like a 303's track mode; 16 steps of undo.</li>
      <li><b>MIDI clock in and out:</b> follow SID808 or any other master, or send the pattern's notes and clock to another synth.</li>
      <li><b>Saved to disk</b> or over MIDI as SysEx: patterns, song, tempo and the sound in one file, the presets in another.</li>
    </ul>
  </div>
  <a class="cta" href="files/sid303.d64" download>Download the disk image</a>

  <h2 id="watch">Watch</h2>
  <figure class="video">
    <video id="video" controls preload="none" playsinline poster="%VIDEO%.jpg" src="files/%VIDEO%.mp4"></video>
    <figcaption>The step sequencer: an empty pattern, an acid loop typed in note by note and played; then, while it plays, resonance, env mod, decay, accent, waveform and filter turned harsher one at a time, and the cutoff closed and swept open. Recorded in VICE with the 8580 SID.</figcaption>
  </figure>

  <h2 id="listen">Listen</h2>
  <div class="ab">
    <span class="seg" role="group" aria-label="Env mod type">
      <button type="button" data-variant="centred" aria-pressed="true">Centred</button>
      <button type="button" data-variant="uponly" class="alt" aria-pressed="false">Up only</button>
    </span>
    <small><b>Env mod type</b>, switchable on the C64. Centred (the default) works like a real 303: Env mod opens the filter higher <em>and</em> closes it lower. Up only opens it upward from Cutoff. Switch while a track plays to compare.</small>
  </div>
  <div id="tracks"></div>
  <p class="note">Recorded in the VICE emulator (x64sc, reSID 8580 model) from the built-in test line, not on real hardware. A real 8580 will sound a little different.</p>

  <h2 id="download">Download</h2>
  <div class="dls">
%DOWNLOADS%
  </div>

  <h2>Getting started</h2>
  <p>You need a PAL Commodore 64 with an <b>8580 SID</b> (a C64C, or any C64 with an 8580 fitted). A 6581 runs it, but its filter sounds quite different. A MIDI cartridge and paddles are optional; it has been tested on a real C64 with a Kerberos cartridge in Datel mode.</p>
  <p>Load it with <kbd>LOAD"SID303",8</kbd> and <kbd>RUN</kbd>. The keyboard plays like a piano: <kbd>Z</kbd> <kbd>X</kbd> <kbd>C</kbd>… are white keys and <kbd>S</kbd> <kbd>D</kbd>… black keys, with a second octave on <kbd>Q</kbd> <kbd>W</kbd> <kbd>E</kbd>… and the number row. Hold <kbd>SHIFT</kbd> for an accent, and overlap notes to slide. <kbd>F1</kbd>/<kbd>F2</kbd> choose a parameter and <kbd>F3</kbd>/<kbd>F4</kbd> change it. The manual has the full list.</p>
  <p><kbd>F7</kbd> opens the step sequencer, which starts with the demos' acid line in pattern 1: press <kbd>RUN/STOP</kbd> to hear it. The note keys enter notes at the cursor, <kbd>A</kbd> and <kbd>F</kbd> set accent and slide, <kbd>=</kbd> a tie, and <kbd>C=</kbd> with <kbd>W</kbd> or <kbd>L</kbd> saves or loads. To play along with SID808, set SID303's <b>Clock</b> to MIDI and SID808's <b>MIDI out</b> On, and start SID808.</p>
  <p>In VICE, use <code>x64sc</code> with the SID model set to 8580. For MIDI, enable a MIDI cartridge of type Datel/Siel under the cartridge/IO settings.</p>
  <p>With a <b>Kerberos</b> cartridge, start SID303 from the Kerberos menu or the Kerberos App with the MIDI emulation set to Datel. Loading it from BASIC switches the cartridge, and MIDI, off.</p>

  <footer>SID303 build %BUILD% · © 2026 Jarkko Lehti · Free software under the <a href="files/LICENSE.txt">GNU GPL v3 or later</a>; the source is in the downloads above. Part of <a href="../">SidSynth</a>, with SID808.</footer>
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
let variant = "centred", current = null;
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
  const v = TRACKS[r.index].variants[variant], p = v.peaks, n = p.length;
  const played = current === id && audio.duration ? audio.currentTime / audio.duration : 0;
  const bw = w / n, on = variant === "uponly" ? css("--amber") : css("--accent"), off = css("--wave");
  for (let i = 0; i < n; i++) {
    const bh = Math.max(1.5, p[i] * (h - 4));
    g.fillStyle = (i + 0.5) / n <= played ? on : off;
    g.fillRect(i * bw, (h - bh) / 2, Math.max(1, bw - 1), bh);
  }
}

function update(id) {
  const r = rows[id], v = TRACKS[r.index].variants[variant];
  const playing = current === id && !audio.paused;
  r.el.classList.toggle("playing", playing);
  r.btn.innerHTML = playing ? ICON_PAUSE : ICON_PLAY;
  r.btn.setAttribute("aria-label", (playing ? "Pause " : "Play ") + TRACKS[r.index].title);
  r.time.textContent = (current === id ? fmt(audio.currentTime) + " / " : "") + fmt(v.len);
  draw(id);
}

function load(id, at) {
  current = id;
  audio.src = TRACKS[rows[id].index].variants[variant].src;
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
  const len = TRACKS[rows[id].index].variants[variant].len;
  if (current !== id) { const old = current; load(id, frac * len); if (old) update(old); }
  else audio.currentTime = frac * (audio.duration || len);
  audio.play();
  update(id);
}

function setVariant(v) {
  if (v === variant) return;
  variant = v;
  document.body.classList.toggle("alt-on", v === "uponly");
  document.querySelectorAll(".seg button").forEach(b =>
    b.setAttribute("aria-pressed", String(b.dataset.variant === v)));
  if (current) {                       // keep the place: A/B while playing
    const at = audio.currentTime, wasPlaying = !audio.paused;
    load(current, at);
    if (wasPlaying) audio.play();
  }
  Object.keys(rows).forEach(update);
}

const list = document.getElementById("tracks");
TRACKS.forEach((t, index) => {
  const el = document.createElement("div");
  el.className = "track";
  el.innerHTML =
    '<button class="play" type="button"></button>' +
    '<div class="head"><h3></h3><span class="time"></span></div>' +
    '<p class="desc"></p><div class="settings"></div><canvas aria-hidden="true"></canvas>';
  el.querySelector("h3").textContent = t.title;
  el.querySelector(".desc").textContent = t.desc;
  el.querySelector(".settings").textContent = t.settings;
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

document.querySelectorAll(".seg button").forEach(b =>
  b.addEventListener("click", () => setVariant(b.dataset.variant)));
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
