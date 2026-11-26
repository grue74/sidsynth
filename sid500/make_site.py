# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds SID500's web page into the SidSynth site: ../sidsynth/site/sid500/.

The SidSynth site (projects/sidsynth) is the one web site of the family:
its main page at the root, each program's page in a folder of its own,
linking back with "../". sidsynth/make_site.py runs this and writes the
main page; upload sidsynth/site/ as it is.

    python make_site.py

Run build.sh, docs/icon.py and docs/manual.py first (the screenshots in
docs/), and tools/demo_tunes.py <tune> all for each tune in TUNES (the
videos and mixes in work/tunes/<tune>/). The page shows SID500 (its
screens), the four demo tunes as videos (SID500 and each synth's screen,
the synths' sound mixed) and as MP3s with a waveform each, the timing
figures of docs/latency.md ("Tech specs"), and the downloads: the disk
image, the program and its disk code, the manual, the source. SID101's
make_site.py is the model; the page can go on any static web host as is,
nothing is loaded from other servers.
"""
import array
import html
import json
import os
import shutil
import subprocess
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(os.path.dirname(ROOT), "sidsynth", "site", "sid500")  # see above
TUNES_DIR = os.path.join(ROOT, "work", "tunes")

# the demo tunes: folder and file name (work/tunes/<name>/<name>-sid500.mp4,
# <name>.mp3), title, tempo and key, who plays what, the second the video's
# poster is taken at
TUNES = [
    ("dub", "Echo Chamber", "Dub, 75 BPM, A minor",
     "A one-drop riddim: SID808 on drums and percussion, a SID101 sub bass, the "
     "skank as three SID101s a note each with echo throws, a SID101 melodica with its "
     "echo voice as the dub delay, and SID303 as a resonant siren.", 40.0),
    ("synth", "Glass Horizon", "Synth piece, 112 BPM, D minor",
     "Dm, Bb, F, C: SID808 four on the floor, a SID303 acid line with its filter "
     "swept in the break, a SID101 16th arpeggio, a chord pad of three SID101s and a "
     "gliding SID101 lead.", 40.0),
    ("pop", "Summer Signal", "Pop, 122 BPM, C major",
     "Verse, pre-chorus and chorus: SID808 drums with tom fills, a SID303 bass, the "
     "chords as three SID101s a note each, a SID101 PWM lead and a plucked "
     "counter-arpeggio in the choruses.", 60.0),
    ("moonlight", "Moonlight Sonata", "Beethoven, 94 BPM, C minor",
     "The first movement at the pace of Jet Set Willy's C64 version (its tempo and "
     "key only; the notes are Beethoven's): the triplets, the melody and its octave "
     "on SID101s, the bass on SID303 and a SID101 sub bass, and a pad of three "
     "SID101s.", 40.0),
]

DOWNLOADS = [
    ("sid500.d64", "Disk image",
     "SID500, its disk code and the four demo songs, with room for your own. Start with "
     "LOAD\"SID500\",8 and RUN."),
    ("sid500.prg", "Program", "SID500 on its own, for SD2IEC, Ultimate or emulators: put "
     "sid500-disk.prg beside it as SID500 DISK."),
    ("sid500-disk.prg", "Disk code", "SID500 DISK, loaded when you save, load or list songs: "
     "keep it on every disk or folder with your songs."),
    ("SID500-manual.pdf", "Manual",
     "The screens and keys, recording, scenes and the song, MIDI and timing."),
    ("sid500-source.zip", "Source", "64tass assembly, table generator, checks and build scripts."),
]

# file types left out of the source zip (built programs, recordings, images;
# they are separate downloads), and the work folder (renders, downloads)
NOT_SOURCE = (".prg", ".d64", ".wav", ".mp3", ".mp4", ".png", ".pdf", ".zip")
# files of directions for the AI assistant the project is worked with (its
# instructions and working rules), not part of the program's source
NOT_IN_ZIP = ("CLAUDE.md",)


def directions(f):
    """True for a file of directions (NOT_IN_ZIP, any CLAUDE.md, .claude/)."""
    return (f in NOT_IN_ZIP or os.path.basename(f) == "CLAUDE.md"
            or f.startswith(".claude/") or "/.claude/" in f)


def source_files():
    """Every source file of the project, including the core submodule: what
    git tracks plus new files not ignored, minus binaries and directions."""
    def git_ls(*args):
        return subprocess.run(["git", "ls-files", *args], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout.splitlines()
    files = set(git_ls("--cached", "--recurse-submodules"))
    files |= set(git_ls("--others", "--exclude-standard"))
    return sorted(f for f in files if not f.lower().endswith(NOT_SOURCE)
                  and not f.startswith("work/") and not directions(f)
                  and os.path.isfile(os.path.join(ROOT, f)))


def size_text(path):
    n = os.path.getsize(path)
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:.1f} MB"


PEAKS = 240                       # waveform bars per track


def peaks(path):
    """Peak level 0..1 per bar of an audio file (decoded by ffmpeg to 8 kHz
    mono), scaled so the loudest bar is 1; and its length in seconds."""
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", "8000",
                          "-f", "s16le", "-"], check=True, capture_output=True).stdout
    data = array.array("h", raw)
    step = max(1, len(data) // PEAKS)
    p = [max((abs(s) for s in data[i:i + step]), default=0) for i in range(0, step * PEAKS, step)]
    top = max(p) or 1
    return [round(v / top, 3) for v in p], round(len(data) / 8000, 2)


def main():
    # empty site/sid500/ file by file: the folders themselves may be held
    # open (a browser showing the page, OneDrive syncing), so they are kept
    for d, _, fs in os.walk(SITE):
        for f in fs:
            os.remove(os.path.join(d, f))
    for d in ("audio", "files"):
        os.makedirs(os.path.join(SITE, d), exist_ok=True)

    # the screenshots (docs/: VICE, 384x272) and the icon (docs/icon.py)
    for f in ("screen.png", "screen-grid.png", "screen-list.png", "favicon.svg",
              "favicon-32.png", "apple-touch-icon.png"):
        shutil.copy(os.path.join(ROOT, "docs", f), SITE)
    # the downloads
    files = os.path.join(SITE, "files")
    for f in ("sid500.d64", "sid500.prg", "sid500-disk.prg"):
        shutil.copy(os.path.join(ROOT, f), files)
    shutil.copy(os.path.join(ROOT, "docs", "SID500-manual.pdf"), files)
    with zipfile.ZipFile(os.path.join(files, "sid500-source.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for f in source_files():
            z.write(os.path.join(ROOT, f), "sid500/" + f)

    # each tune: its video and a poster frame, its mix as MP3 with a waveform
    videos, tracks = [], []
    for name, title, kind, desc, at in TUNES:
        src = os.path.join(TUNES_DIR, name)
        shutil.copy(os.path.join(src, f"{name}-sid500.mp4"), os.path.join(SITE, "files"))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(at), "-i",
                        os.path.join(src, f"{name}-sid500.mp4"), "-frames:v", "1", "-vf",
                        "scale=960:-1", "-q:v", "3", os.path.join(SITE, f"{name}.jpg")],
                       check=True)
        shutil.copy(os.path.join(src, f"{name}.mp3"), os.path.join(SITE, "audio"))
        p, length = peaks(os.path.join(src, f"{name}.mp3"))
        tracks.append({"id": name, "title": title, "desc": kind, "src": f"audio/{name}.mp3",
                       "peaks": p, "len": length})
        videos.append(
            f'  <figure class="video">\n'
            f'    <h3>{html.escape(title)} <span class="kind">{html.escape(kind)}</span></h3>\n'
            f'    <video controls preload="none" playsinline poster="{name}.jpg" '
            f'src="files/{name}-sid500.mp4"></video>\n'
            f'    <figcaption>{html.escape(desc)}</figcaption>\n'
            f'  </figure>')
    shutil.copy(os.path.join(ROOT, "LICENSE"), os.path.join(SITE, "files", "LICENSE.txt"))

    # build number written by build.sh, the same one the program shows
    try:
        build = open(os.path.join(ROOT, "build-number.txt")).read().strip()
    except OSError:
        build = "?"

    rows = []
    for f, label, desc in DOWNLOADS:
        rows.append(
            f'<a class="dl" href="files/{f}" download>'
            f'<span class="dl-label">{html.escape(label)}</span>'
            f'<span class="dl-name">{html.escape(f)}</span>'
            f'<span class="dl-desc">{html.escape(desc)}</span>'
            f'<span class="dl-size">{size_text(os.path.join(files, f))}</span></a>')
    page = TEMPLATE.replace("%DOWNLOADS%", "\n".join(rows)).replace("%VIDEOS%", "\n".join(videos)).replace(
        "%TRACKS%", json.dumps(tracks, separators=(",", ":"))).replace("%BUILD%", build)
    with open(os.path.join(SITE, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    total = sum(os.path.getsize(os.path.join(d, x)) for d, _, fs in os.walk(SITE) for x in fs)
    print(f"sidsynth/site/sid500/ written: {total / 1024 / 1024:.1f} MB")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SID500</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="description" content="SID500: a 16-channel MIDI sequencer for the Commodore 64, named after the Roland MC-500, playing the SidSynth family. Watch and listen to the demo tunes.">
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
@media (min-width: 760px) { .hero { grid-template-columns: 1.15fr 1fr; } }
figure { margin: 0; }
.video { margin-bottom: 36px; }
.video h3 { font-size: 18px; margin: 0 0 8px; }
.video .kind { font-family: var(--mono); font-size: 13px; color: var(--muted); font-weight: 400;
               margin-left: 8px; }
.video video { width: 100%; aspect-ratio: 1920 / 1332; display: block; background: #000;
               border-radius: 8px; border: 1px solid var(--line); }
figcaption { color: var(--muted); font-size: 14.5px; margin-top: 8px; }
.screen { width: 100%; image-rendering: pixelated; border-radius: 6px;
          border: 1px solid var(--line); display: block; }
.facts { list-style: none; padding: 0; margin: 0; }
.facts li { padding: 8px 0; border-bottom: 1px solid var(--line); }
.facts li:last-child { border-bottom: 0; }
.facts b { font-weight: 600; }
.specs { width: 100%; border-collapse: collapse; background: var(--panel);
         border: 1px solid var(--line); border-radius: 8px; overflow: hidden; font-size: 15px; }
.specs th, .specs td { text-align: left; padding: 9px 14px; border-bottom: 1px solid var(--line);
                       vertical-align: top; }
.specs tr:last-child th, .specs tr:last-child td { border-bottom: 0; }
.specs th { font-weight: 600; width: 38%; }

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
canvas { grid-column: 1 / -1; width: 100%; height: 44px; cursor: pointer; display: block; margin-top: 6px; }
.cta { display: inline-block; margin-top: 18px; padding: 11px 18px; border-radius: 6px;
       background: var(--accent); color: var(--bg); text-decoration: none; font-weight: 600; }
.cta:hover { filter: brightness(1.08); }
.hero + .hero { margin-top: 24px; }
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
code, kbd { font-family: var(--mono); font-size: .92em; }
kbd { border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 5px; }
.note { background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--accent);
        border-radius: 6px; padding: 12px 16px; font-size: 15px; color: var(--muted); }
footer a, .note a { color: var(--accent); }
footer { margin-top: 64px; color: var(--muted); font-size: 14px; border-top: 1px solid var(--line); padding-top: 16px; }
</style>
</head>
<body>
<main>
  <a class="home" href="../">&larr; SidSynth</a>
  <h1>SID<span>500</span></h1>
  <p class="lede">A 16-channel MIDI sequencer for the Commodore 64, named after the Roland MC-500. It makes no sound of its own: it plays the SidSynth synths, and any MIDI instrument, from songs of scenes and patterns, in tight time.</p>

  <div class="hero">
    <img class="screen" src="screen.png" alt="The SID500 song screen while playing: scene 7 at 122 BPM, bar 35 beat 3 at 1:08, a column of pattern numbers for each of the eight tracks shown, in each MIDI channel's colour">
    <ul class="facts">
      <li><b>16 tracks, 16 MIDI channels:</b> each track on its own channel, shown in that channel's colour.</li>
      <li><b>Scenes and patterns:</b> 64 scenes of up to 16 patterns, 128 patterns of up to 128 steps; the song is the scene rows in order, with repeats; launch a scene or a single pattern live, at the next bar.</li>
      <li><b>Step grid and event list:</b> notes, chords, velocity and length on a grid; every event, controllers included, in a list.</li>
      <li><b>Recording</b> from a MIDI keyboard, overdub or replace, quantized, with a count-in; MIDI thru to the track's synth.</li>
      <li><b>Timing first:</b> notes and clock from the C64's timer, rendered ahead; MIDI clock in and out, song position, swing, 40-240 BPM. Songs saved to disk.</li>
    </ul>
  </div>
  <div class="hero">
    <img class="screen" src="screen-grid.png" alt="The SID500 step grid: a row per step, three note columns with pitch, velocity and length, chords on every step">
    <img class="screen" src="screen-list.png" alt="The SID500 event list: every event with its position, note, velocity and length">
  </div>
  <a class="cta" href="files/sid500.d64" download>Download the disk image</a>

  <h2 id="watch">Watch</h2>
  <p>Four demo tunes, each a song SID500 loads from disk and plays with Song on. On the left SID500's song screen; around it the screen of each synth it plays, every one a C64 of its own, their sound mixed.</p>
%VIDEOS%
  <p class="note">Recorded in the VICE emulator (x64sc, reSID 8580 model), each C64 on its own, not on real hardware. SID500's MIDI out was captured and checked against the song's model, and each synth's part was played from it. The Moonlight Sonata's notes come from the <a href="https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=276">Mutopia Project's edition</a> (Berners 1908, ed. Winterberger; CC BY-SA 2.5).</p>

  <h2 id="listen">Listen</h2>
  <div id="tracks"></div>

  <h2 id="download">Download</h2>
  <div class="dls">
%DOWNLOADS%
  </div>

  <h2>Getting started</h2>
  <p>You need a PAL Commodore 64 with a MIDI cartridge (Datel/Siel/JMS, Sequential, Passport or Namesoft) and MIDI instruments on its MIDI OUT: the SidSynth synths, each on a C64 of its own, or any others. Track 1 plays MIDI channel 1, track 10 channel 10, and so on.</p>
  <p>Load it with <kbd>LOAD"SID500",8</kbd> and <kbd>RUN</kbd>. It starts on the parameter screen: check <b>MIDI i/face</b>, then press <kbd>F7</kbd> for the song screen. To hear a demo, press <kbd>C=</kbd> + <kbd>D</kbd>, pick a song and press <kbd>RETURN</kbd>, then <kbd>SHIFT</kbd> + <kbd>SPACE</kbd> to play it from the start and <kbd>SPACE</kbd> to stop. The demos play SID808 on channel 10, SID303 on channel 2 and SID101s on the others.</p>
  <p>To make a pattern, move to an empty cell and press <kbd>RETURN</kbd>: play notes on the letter keys (<kbd>Z</kbd> <kbd>S</kbd> <kbd>X</kbd>... like a piano), <kbd>RUN/STOP</kbd> to hear it loop, <kbd>RETURN</kbd> to go back. Or put the cursor on a cell and press <kbd>C=</kbd> + <kbd>R</kbd> to record from a MIDI keyboard after a bar's count-in. The manual has every key.</p>
  <p>In VICE, use <code>x64sc</code> and enable a MIDI cartridge of type Datel/Siel under the cartridge/IO settings. With a <b>Kerberos</b> cartridge, start SID500 from its slot with the MIDI emulation set to Datel: started from BASIC after the Kerberos menu, its MIDI stays off.</p>

  <h2 id="timing">Timing</h2>
  <table class="specs">
    <tr><th>Notes and clock</th><td>From the C64's CIA timer, rendered about 42 ms ahead: ticks within 0.3 ms of exact, the MIDI clock 0.4-0.5 ms after its tick, its gaps steady within about 0.5 ms.</td></tr>
    <tr><th>Under load</th><td>At most about 2.5 ms added to any byte with half the MIDI wire busy; nothing is ever dropped.</td></tr>
    <tr><th>As MIDI clock slave</th><td>The master's clock passed on within about 0.6 ms.</td></tr>
    <tr><th>MIDI thru</th><td>About 3 ms stopped; playing, median about 9 ms at 120 BPM.</td></tr>
    <tr><th>The synths, note on to sound</th><td>SID303 median 2.4 ms (1.3-4.7), SID101 2.3 ms (1.3-5.7), SID808 7 ms (5.3-9.5, a 5 ms envelope settle that keeps soft hits clean).</td></tr>
  </table>
  <p class="note">Measured in VICE with its MIDI interface sending at the real wire's pace (10 bits a byte, as a real 6850 does: checked on a Kerberos cartridge), not counting MIDI's own 1 ms for a note on's three bytes.</p>

  <footer>SID500 build %BUILD% · © 2026 Jarkko Lehti · Free software under the <a href="files/LICENSE.txt">GNU GPL v3 or later</a>; the source is in the downloads above. Part of <a href="../">SidSynth</a>, with SID101, SID303 and SID808.</footer>
</main>

<script>
const TRACKS = %TRACKS%;
const ICON_PLAY = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5v15l13-7.5z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4h4.5v16H6zM13.5 4H18v16h-4.5z"/></svg>';
const audio = new Audio();
audio.preload = "none";
const videos = Array.from(document.querySelectorAll("video"));
videos.forEach(v => v.addEventListener("play", () => {
  if (!audio.paused) audio.pause();
  videos.forEach(o => { if (o !== v && !o.paused) o.pause(); });
}));
audio.addEventListener("play", () => videos.forEach(v => { if (!v.paused) v.pause(); }));
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
    '<p class="desc"></p><canvas aria-hidden="true"></canvas>';
  el.querySelector("h3").textContent = t.title;
  el.querySelector(".desc").textContent = t.desc;
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
