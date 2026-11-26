# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds SID808's web page into the SidSynth site: ../sidsynth/site/sid808/.

The SidSynth site (projects/sidsynth) is the one web site of the family:
its main page at the root, each synth's page in a folder of its own,
linking back with "../". sidsynth/make_site.py runs this and writes the
main page; upload sidsynth/site/ as it is.

    python make_site.py

Run build.sh and docs/manual.py first. The page plays the demo recordings
(MP3s made from the WAVs in demos/ with ffmpeg) and offers the disk image,
programs, manual, WAV recordings and source as downloads. The page can go on any
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
SITE = os.path.join(os.path.dirname(ROOT), "sidsynth", "site", "sid808")  # see above

# the recordings on the page: demos/<name>.wav, title, what it is
DEMOS = [
    ("track-6", "Drum track",
     "A short track from the sequencer's own patterns: intro, grooves, a tom fill, "
     "a clave break, a cymbal crash and the ending, with a light shuffle."),
    ("demo-4", "Every sound, then a beat",
     "All thirteen sounds one by one, soft and then accented, followed by an "
     "808 beat with the ring-modulated cowbell."),
    ("bass-and-drums-3", "With SID303",
     "A piece written for two C64s: SID808's drums on its own sequencer and an acid "
     "line from SID303, the filter opening as it builds - two machines, one tempo."),
]

# the video on the page (demos/<name>.mp4) and the second its poster is taken at
VIDEO = ("bass-and-drums-3", 17.0)

DOWNLOADS = [
    ("sid808.d64", "Disk image",
     "The drum machine, the demo and the track, plus test programs. "
     "Start with LOAD\"SID808\",8 and RUN."),
    ("sid808.prg", "Program", "The drum machine on its own, for SD2IEC, Ultimate or emulators."),
    ("sid808-test.prg", "Demo program", "Plays every sound, then a beat, with no MIDI needed."),
    ("sid808-track.prg", "Track program", "Plays the drum track above."),
    ("SID808-manual.pdf", "Manual", "The step grid, songs, the sounds, MIDI, disk."),
    ("bass-and-drums-3.mp4", "Video", "The two-C64 piece above, 1920x1080 (H.264, AAC)."),
    ("sid808-demos-wav.zip", "Recordings", "The demos as WAV (48 kHz, 16-bit mono)."),
    ("sysex.py", "SysEx tool",
     "Fetch the song over MIDI and send it back (Python, mido)."),
    ("sid808-source.zip", "Source", "64tass assembly, the sound and table generator, build scripts."),
]

# file types left out of the source zip (built programs, recordings, images;
# they are separate downloads)
NOT_SOURCE = (".prg", ".d64", ".wav", ".mp3", ".mp4", ".png", ".pdf", ".zip")


def source_files():
    """Every source file of the project, including the core submodule: what git
    tracks plus new files not ignored, minus binaries. Walking git instead of
    a hand list keeps the GPL source offer complete when files are added."""
    def git_ls(*args):
        return subprocess.run(["git", "ls-files", *args], cwd=ROOT, check=True,
                              capture_output=True, text=True).stdout.splitlines()
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


def version():
    """The version build.sh wrote (version.txt), else the build number."""
    for name in ("version.txt", "build-number.txt"):
        try:
            return open(os.path.join(ROOT, name)).read().strip()
        except OSError:
            pass
    return "?"


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
    for name, title, desc in DEMOS:
        wav = os.path.join(ROOT, "demos", name + ".wav")
        out = f"audio/{name}.mp3"
        mp3(wav, os.path.join(SITE, out))
        tracks.append({"id": name, "title": title, "desc": desc, "src": out,
                       "peaks": peaks(wav), "len": round(duration(wav), 2)})

    # downloads
    files = os.path.join(SITE, "files")
    for f in ("sid808.d64", "sid808.prg", "sid808-test.prg", "sid808-track.prg"):
        shutil.copy(os.path.join(ROOT, f), files)
    shutil.copy(os.path.join(ROOT, "docs", "SID808-manual.pdf"), files)
    shutil.copy(os.path.join(os.path.dirname(ROOT), "core", "sysex.py"), files)  # the PC side of the dumps
    # the video: in files/ (played and downloaded from there), a poster frame
    name, at = VIDEO
    shutil.copy(os.path.join(ROOT, "demos", name + ".mp4"), files)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(at), "-i",
                    os.path.join(ROOT, "demos", name + ".mp4"), "-frames:v", "1",
                    "-q:v", "3", os.path.join(SITE, name + ".jpg")], check=True)
    # the icon (docs/favicon.svg; the PNGs are rendered from it) and the screenshots
    for f in ("screen-grid.png", "screen-params.png",
              "favicon.svg", "favicon-32.png", "apple-touch-icon.png"):
        shutil.copy(os.path.join(ROOT, "docs", f), SITE)
    shutil.copy(os.path.join(ROOT, "LICENSE"), os.path.join(files, "LICENSE.txt"))
    with zipfile.ZipFile(os.path.join(files, "sid808-demos-wav.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for name, *_ in DEMOS:
            z.write(os.path.join(ROOT, "demos", name + ".wav"), f"sid808-demos/{name}.wav")
    with zipfile.ZipFile(os.path.join(files, "sid808-source.zip"), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for f in source_files():
            z.write(os.path.join(ROOT, f), "sid808/" + f)

    rows = []
    for f, label, desc in DOWNLOADS:
        rows.append(
            f'<a class="dl" href="files/{f}" download>'
            f'<span class="dl-label">{html.escape(label)}</span>'
            f'<span class="dl-name">{html.escape(f)}</span>'
            f'<span class="dl-desc">{html.escape(desc)}</span>'
            f'<span class="dl-size">{size_text(os.path.join(files, f))}</span></a>')

    page = TEMPLATE.replace("%DOWNLOADS%", "\n".join(rows)).replace(
        "%TRACKS%", json.dumps(tracks, separators=(",", ":"))).replace(
        "%VERSION%", html.escape(version())).replace("%VIDEO%", VIDEO[0])
    with open(os.path.join(SITE, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    total = sum(os.path.getsize(os.path.join(d, x)) for d, _, fs in os.walk(SITE) for x in fs)
    print(f"sidsynth/site/sid808/ written: {total / 1024 / 1024:.1f} MB")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SID808</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="description" content="An 808-style drum machine for the Commodore 64 with an 8580 SID: thirteen synthesized drums, a step sequencer, songs and MIDI. Listen to the demos and download the disk image.">
<style>
/* TR-808: the charcoal case, the step keys' red - orange - yellow - cream
   run (light mode: the silver-grey panel, the key colours darkened enough
   to read on it) */
:root {
  --bg: #dcd9d2; --panel: #eeece7; --line: #c2beb5; --text: #1c1b19;
  --muted: #5a564f; --accent: #c8321f; --accent-soft: #f4d9d2; --wave: #bdb8ae;
  --red: #c8321f; --orange: #c9620e; --yellow: #9a7400; --cream: #6f6656;
  --key-red: #e2412d; --key-orange: #f08a24; --key-yellow: #f3c432; --key-cream: #efe7d2;
  --case: #232323;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", Consolas, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161616; --panel: #222222; --line: #353535; --text: #eee8db;
    --muted: #a39d92; --accent: #ef4a35; --accent-soft: #3b1f1b; --wave: #3e3c39;
    --red: #ef4a35; --orange: #f39237; --yellow: #f3c432; --cream: #efe7d2;
    --case: #0e0e0e;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main { max-width: 860px; margin: 0 auto; padding: 48px 16px 64px; }
h1, h2, .mono { font-family: var(--mono); }
h1 { font-size: clamp(34px, 7vw, 52px); letter-spacing: .02em; margin: 0 0 6px; }
h1 span { color: var(--red); }
.home { display: inline-block; margin-bottom: 10px; font-family: var(--mono); font-size: 13px;
        color: var(--muted); text-decoration: none; }
.home:hover { color: var(--accent); }
.keys { display: grid; grid-template-columns: repeat(16, 1fr); gap: 5px; max-width: 520px;
        background: var(--case); padding: 7px; border-radius: 6px; margin: 4px 0 22px; }
.keys i { display: block; height: 16px; border-radius: 2px; box-shadow: inset 0 -3px 0 rgba(0,0,0,.25); }
.keys i:nth-child(-n+4) { background: var(--key-red); }
.keys i:nth-child(n+5):nth-child(-n+8) { background: var(--key-orange); }
.keys i:nth-child(n+9):nth-child(-n+12) { background: var(--key-yellow); }
.keys i:nth-child(n+13) { background: var(--key-cream); }
.keys i.lit { box-shadow: inset 0 -3px 0 rgba(0,0,0,.25), 0 0 0 2px var(--text); }
h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .12em;
     color: var(--muted); margin: 56px 0 16px; font-weight: 600;
     border-left: 4px solid var(--orange); padding-left: 10px; }
h2#watch { border-color: var(--red); } h2#listen { border-color: var(--orange); } h2#download { border-color: var(--yellow); }
h2#tech { border-color: var(--cream); }
h3 { font-size: 17px; margin: 22px 0 6px; }
p { margin: 0 0 12px; }
.lede { font-size: 19px; color: var(--muted); max-width: 660px; margin-bottom: 28px; }
.hero { display: grid; grid-template-columns: 1fr; gap: 24px; align-items: start; }
@media (min-width: 760px) { .hero { grid-template-columns: 1.15fr 1fr; } }
.screen { width: 100%; image-rendering: pixelated; border-radius: 6px;
          border: 1px solid var(--line); display: block; }
.shots { display: grid; grid-template-columns: 1fr; gap: 16px; }
@media (min-width: 760px) { .shots { grid-template-columns: 1fr 1fr; } }
figure { margin: 0; }
.video video { width: 100%; aspect-ratio: 16 / 9; display: block; background: #000;
               border-radius: 8px; border: 1px solid var(--line); }
figcaption { color: var(--muted); font-size: 14px; margin-top: 6px; }
.facts { list-style: none; padding: 0; margin: 0; }
.facts li { padding: 8px 0; border-bottom: 1px solid var(--line); }
.facts li:last-child { border-bottom: 0; }
.facts b { font-weight: 600; }
.facts li:nth-child(1) b { color: var(--red); } .facts li:nth-child(2) b { color: var(--orange); }
.facts li:nth-child(3) b { color: var(--yellow); } .facts li:nth-child(4) b { color: var(--cream); }
.cta { display: inline-block; margin-top: 18px; padding: 11px 18px; border-radius: 6px;
       background: var(--key-red); color: #1a1a1a; text-decoration: none; font-weight: 700;
       box-shadow: inset 0 -3px 0 rgba(0,0,0,.25); }
.cta:hover { filter: brightness(1.08); }
.badge { display: inline-block; font-family: var(--mono); font-size: 13px; color: var(--orange);
         border: 1px solid var(--orange); border-radius: 999px; padding: 2px 10px; margin-left: 10px;
         vertical-align: middle; }

/* player */
.track { --c: var(--red); --k: var(--key-red); display: grid; grid-template-columns: 44px 1fr; gap: 6px 14px;
         background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
         padding: 14px 16px; margin-bottom: 10px; }
.track:nth-child(3n+2) { --c: var(--orange); --k: var(--key-orange); }
.track:nth-child(3n+3) { --c: var(--yellow); --k: var(--key-yellow); }
.play { width: 44px; height: 44px; border-radius: 6px; border: 0; cursor: pointer;
        background: var(--case); color: var(--k); display: grid; place-items: center;
        box-shadow: inset 0 -3px 0 rgba(255,255,255,.08); }
.play svg { width: 18px; height: 18px; fill: currentColor; }
.track.playing .play { background: var(--k); color: #1a1a1a; }
.head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; min-width: 0; }
.head h3 { margin: 0; font-size: 17px; }
.time { font-family: var(--mono); font-size: 13px; color: var(--muted); margin-left: auto; }
.desc { grid-column: 2; color: var(--muted); font-size: 14.5px; margin: 0; }
canvas { grid-column: 1 / -1; width: 100%; height: 44px; cursor: pointer; display: block; margin-top: 6px; }

/* technical */
table { border-collapse: collapse; width: 100%; font-size: 14.5px; margin: 8px 0 16px; }
th, td { text-align: left; padding: 7px 10px 7px 0; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: 13px; text-transform: uppercase; letter-spacing: .06em; }
td:first-child { font-family: var(--mono); white-space: nowrap; }
.wide { overflow-x: auto; }
.ear { background: var(--case); color: #eee8db; border-radius: 8px; padding: 14px 18px; margin: 18px 0;
       border-top: 4px solid var(--key-red); }
.ear b { color: var(--key-yellow); }

/* downloads */
.dls { display: grid; gap: 8px; }
.dl { display: grid; grid-template-columns: 1fr auto; gap: 2px 16px; text-decoration: none;
      color: var(--text); background: var(--panel); border: 1px solid var(--line);
      border-radius: 8px; padding: 12px 16px; }
.dl:hover { border-color: var(--orange); }
.dl-label { font-weight: 600; }
.dl-name { font-family: var(--mono); font-size: 13px; color: var(--orange); grid-column: 1;
           overflow-wrap: anywhere; }
.dl-desc { color: var(--muted); font-size: 14px; grid-column: 1; }
.dl-size { grid-column: 2; grid-row: 1 / span 3; align-self: center;
           font-family: var(--mono); font-size: 13px; color: var(--muted); }
.note { background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--yellow);
        border-radius: 6px; padding: 12px 16px; font-size: 15px; color: var(--muted); }
code, kbd { font-family: var(--mono); font-size: .92em; }
kbd { border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 5px; }
footer a { color: var(--orange); }
footer { margin-top: 64px; color: var(--muted); font-size: 14px; border-top: 1px solid var(--line); padding-top: 16px; }
</style>
</head>
<body>
<main>
  <a class="home" href="../">&larr; SidSynth</a>
  <h1>SID<span>808</span><span class="badge">%VERSION% · test release</span></h1>
  <div class="keys" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
  <p class="lede">An 808-style drum machine for the Commodore 64 and its 8580 SID chip. Thirteen drum sounds synthesized live on three voices, a 16-step sequencer with songs, and MIDI in and out.</p>

  <div class="hero">
    <img class="screen" src="screen-grid.png" alt="The SID808 step grid: thirteen sound rows of sixteen steps, with the song and status rows below">
    <ul class="facts">
      <li><b>Thirteen sounds:</b> kick, snare, clap, closed and open hat, three toms, rim shot, claves, cymbal, maracas and a ring-modulated cowbell.</li>
      <li><b>Step sequencer:</b> 64 patterns of up to 16 steps, three levels per step, swing, mute, songs of up to 64 entries, and 16 steps of undo.</li>
      <li><b>Sound page:</b> Level, Tune, Decay and Tone for every sound, on keys, MIDI knobs or paddles.</li>
      <li><b>MIDI</b> drum notes in, clock in, notes and clock out; songs saved to disk.</li>
    </ul>
  </div>
  <a class="cta" href="files/sid808.d64" download>Download the disk image</a>

  <h2 id="watch">Watch</h2>
  <figure class="video">
    <video id="video" controls preload="none" playsinline poster="%VIDEO%.jpg" src="files/%VIDEO%.mp4"></video>
    <figcaption>Two C64s, one tempo: SID303 plays the acid bass on the left, SID808's sequencer the drums on the right, in a piece written for both. Recorded in VICE with 8580 SIDs.</figcaption>
  </figure>

  <h2 id="listen">Listen</h2>
  <div id="tracks"></div>
  <p class="note">Recorded in the VICE emulator (reSID, 8580 model), not on real hardware. A real 8580 will sound a little different - every chip does.</p>

  <h2 id="download">Download</h2>
  <div class="dls">
%DOWNLOADS%
  </div>

  <h2>Getting started</h2>
  <p>You need a PAL Commodore 64 with an <b>8580 SID</b> (a C64C, or any C64 with an 8580 fitted). A MIDI cartridge (Sequential, Passport, Datel/Siel or Namesoft compatible), paddles and a disk drive are optional.</p>
  <p>Load it with <kbd>LOAD"SID808",8</kbd> and <kbd>RUN</kbd>. It starts on the step grid with thirteen patterns ready: press <kbd>RUN/STOP</kbd> to play and <kbd>F1</kbd>/<kbd>F2</kbd> to change pattern. The cursor keys move, <kbd>SPACE</kbd> sets a step and <kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> set it soft, normal or accented. <kbd>F7</kbd> goes to the parameter screen with the sound page. <kbd>U</kbd> undoes (16 steps, <kbd>SHIFT</kbd>+<kbd>U</kbd> redoes), <kbd>W</kbd> and <kbd>L</kbd> save and load. The manual has the rest.</p>
  <p>In VICE, use <code>x64sc</code> with the SID model set to 8580. For MIDI, enable a MIDI cartridge (Datel/Siel is the default) under the cartridge/IO settings.</p>

  <h2 id="tech">Technical details</h2>
  <div class="shots">
    <figure><img class="screen" src="screen-params.png" alt="The SID808 parameter screen with the sound page"><figcaption>The parameter screen: the sound page on top, MIDI and disk settings below.</figcaption></figure>
    <div>
      <h3>One SID, three voices, thirteen drums</h3>
      <p>The 808 has a separate circuit for every sound; the SID has three voices and one filter. SID808 shares them: a new hit takes the voice of its choke group (a closed hat stops an open hat), else a free voice, else the quietest sound, weighted by how much it matters - the kick and snare are hardest to take. A voice is never cut: it fades out in a few milliseconds, so stealing doesn't click.</p>
    </div>
  </div>
  <h3>Sounds as programs</h3>
  <p>Every sound is a short program of steps - waveform, pitch and exponential pitch drop, level and decay, filter - generated by a Python script and run by one interpreter for all three voices, <b>500 times a second</b>. The snare is a falling tone for 12 ms and then noise; the clap is three retriggered bursts of band-passed noise and a tail; the kick is a triangle falling from 500 Hz to 48 Hz, which is where its knock comes from.</p>
  <div class="wide"><table>
    <tr><th>Sound</th><th>On the SID</th></tr>
    <tr><td>Kick, toms</td><td>triangle with an exponential pitch drop, the 808's bridged-T "boom"</td></tr>
    <tr><td>Snare</td><td>a 330 → 185 Hz tone, then noise for the snappy</td></tr>
    <tr><td>Clap</td><td>three noise bursts and a tail through a resonant band-pass</td></tr>
    <tr><td>Hats, cymbal</td><td>high-passed noise; velocity darkens soft hits, every hit varies a little</td></tr>
    <tr><td>Cowbell</td><td>ring modulation: a 670 Hz triangle times a borrowed voice at 130 Hz gives the 808's 540 + 800 Hz pair, band-passed (one pulse tone when no second voice is free)</td></tr>
    <tr><td>Rim, claves</td><td>short triangle bursts: the rim's 1667 Hz tick into its 455 Hz ring, the claves' 2.3 kHz tone with a tiny drop</td></tr>
  </table></div>
  <h3>Soft hits on a chip that only attacks at full level</h3>
  <p>The SID's envelope always rises to full before settling, which would make every soft hit start with a full-level click. SID808 sets the level through the sustain register and starts each hit with a <b>silent attack</b>: the oscillator is parked, cycle-exactly, at the triangle's midpoint - the 8580 DAC's zero - while the envelope rises and settles unheard; then the waveform starts, at a zero crossing like the 808's. The park is timed with a CIA timer and redone if a MIDI interrupt lands in it.</p>
  <h3>Timing</h3>
  <p>The engine runs at 500 Hz (1970 cycles a tick). Expensive work is spread out: at most one voice starts per tick, a step's hits fire while the tick has time and the rest a tick later, decays are table lookups. If a moment is still too busy, SID808 catches up without losing time, and a <b>CPU</b> light on the status row says when hits came late. MIDI input and output are interrupt-driven through the cartridge's 6850 ACIA.</p>

  <div class="ear"><b>Tuned by ear.</b> Every sound was tuned to perfection by a human ear - one pair of them, on one 8580, in one room, on one day. What "perfection" means for a drum machine that has to share three voices among thirteen drums is left as an exercise for the listener; reports from other ears are welcome.</div>

  <footer>SID808 %VERSION% · © 2026 Jarkko Lehti · Free software under the <a href="files/LICENSE.txt">GNU GPL v3 or later</a>; the source is in the downloads above. Part of <a href="../">SidSynth</a>, with SID303.</footer>
</main>

<script>
const TRACKS = %TRACKS%;
const ICON_PLAY = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5v15l13-7.5z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4h4.5v16H6zM13.5 4H18v16h-4.5z"/></svg>';
const audio = new Audio();
audio.preload = "none";
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
  const t = TRACKS[r.index], p = t.peaks, n = p.length;
  const played = current === id && audio.duration ? audio.currentTime / audio.duration : 0;
  const bw = w / n, on = getComputedStyle(r.el).getPropertyValue("--c").trim() || css("--accent"), off = css("--wave");
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

const keys = document.querySelectorAll(".keys i");
let lit = -1;
function runKeys() {            // the step light, a 16th at 125 BPM, while a demo plays
  const on = current && !audio.paused;
  const k = on ? Math.floor(audio.currentTime * 125 / 15) % 16 : -1;
  if (k !== lit) {
    if (lit >= 0) keys[lit].classList.remove("lit");
    if (k >= 0) keys[k].classList.add("lit");
    lit = k;
  }
  if (on) requestAnimationFrame(runKeys);
}
const video = document.getElementById("video");
video.addEventListener("play", () => { if (!audio.paused) audio.pause(); });
audio.addEventListener("play", () => { if (!video.paused) video.pause(); });
audio.addEventListener("timeupdate", () => current && update(current));
audio.addEventListener("playing", runKeys);
audio.addEventListener("pause", runKeys);
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
