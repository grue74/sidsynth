# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The SidSynth web site: site/, ready to upload as it is.

    python make_site.py [--no-synths]

This is the family's one web site: all web page work happens here. The
main page (index.html) is at the root, and each synth's page in a folder
of its own: site/sid303/, site/sid808/, site/sid101/. A synth's make_site.py (in its
project, projects/<synth>) writes its folder here; this runs each of them
first, unless --no-synths, which keeps the synth folders as they are and
only rewrites the main page. Each synth's page links back with "../".

To add a synth: an entry in SYNTHS (its folder next to this one, the
screenshot for its card, the facts), its make_site.py writing to
../sidsynth/site/<synth>/, and a link back to "../" on its page.
"""
import argparse
import html
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECTS = os.path.dirname(ROOT)
SITE = os.path.join(ROOT, "site")

# the synths, in the order of their cards: the folder (projects/<dir>, also
# the site's folder), the name split for the title colour, a one-line
# description, the screenshot (in its site), the facts, and the version text
# (a function of the synth folder: its build or version)
def build_303(d):
    return "build " + open(os.path.join(d, "build-number.txt")).read().strip()


def version_808(d):
    return open(os.path.join(d, "version.txt")).read().strip()


SYNTHS = [
    {"dir": "sid101", "name": ("SID", "101"), "kind": "Lead synth",
     "line": "An SH-101 style lead and bass synth: saw, pulse and sub on the SID's three voices "
             "through one resonant filter, with a sync lead, the C64's own 80s lead and an "
             "arpeggiator.",
     "shot": "screen.png",
     "alt": "The SID101 parameter screen: the Sound page with bars and MIDI controller numbers",
     "facts": ["Saw, pulse with PWM and a sub, an ADSR, glide and a four-shape LFO",
               "Sync mode, and a C64 mode with echo, clicks and fast-arpeggio chords",
               "An arpeggiator and the SidSynth step sequencer",
               "32 named presets, saved to disk as a bank"],
     "version": build_303},
    {"dir": "sid303", "name": ("SID", "303"), "kind": "Acid bass synth",
     "line": "A TB-303 style acid bass voice: resonant filter with envelope, accent and slide, "
             "and a step sequencer of its own.",
     "shot": "screen-steps.png",
     "alt": "The SID303 step screen: 16 steps with notes, accent and slide marks",
     "facts": ["Saw, square or the 303's slanted square through the SID's filter",
               "64 patterns, songs with transpose, MIDI clock in and out",
               "Played from MIDI, the C64 keyboard or paddles"],
     "version": build_303},
    {"dir": "sid808", "name": ("SID", "808"), "kind": "Drum machine",
     "line": "An 808-style drum machine: thirteen drum sounds synthesized live on the SID's "
             "three voices, sequenced on the C64.",
     "shot": "screen-grid.png",
     "alt": "The SID808 pattern grid: thirteen drum rows across 16 steps",
     "facts": ["Kick, snare, clap, hats, toms, cowbell and more",
               "64 patterns, three levels per step, swing and songs",
               "MIDI drum notes and clock in, notes and clock out"],
     "version": version_808},
    {"dir": "sid500", "name": ("SID", "500"), "kind": "MIDI sequencer",
     "line": "A 16-channel MIDI sequencer named after the Roland MC-500: songs of scenes and "
             "patterns, played to the SidSynth synths and any MIDI instrument in tight time.",
     "shot": "screen.png",
     "alt": "The SID500 song screen while playing: scenes, each track's pattern numbers in its "
            "MIDI channel's colour, the bar, beat and time in the title",
     "facts": ["16 tracks on 16 MIDI channels, 64 scenes, 128 patterns",
               "Step grid, event list, recording with count-in, MIDI thru",
               "Notes and clock from the C64's timer: within 0.3 ms"],
     "version": build_303},
]

# what the shared core does, for the diagram: (module, what it covers)
CORE = [
    ("Start-up", "takes over the machine, interrupts, the 250 Hz synth tick"),
    ("MIDI", "in and out through Datel, Sequential, Passport and Namesoft cartridges"),
    ("Parameters", "values, MIDI controllers and learn"),
    ("Paddles", "with soft takeover and paddle learn"),
    ("Keyboard", "a piano on the letter keys, the function-key commands"),
    ("Screen", "the parameter list with bars, names and learn"),
    ("Test feeds", "scripted MIDI, keys and paddles for repeatable runs in VICE"),
]

TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SidSynth</title>
<meta name="description" content="SidSynth: a family of synthesizers for the Commodore 64 and its SID chip, built on one shared core. SID101 lead synth, SID303 acid bass, SID808 drum machine and the SID500 MIDI sequencer.">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="icon" href="favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<style>
:root {
  --bg: #fff8f1; --panel: #ffffff; --line: #f0dcc8; --text: #2a1d12;
  --muted: #7a6352; --accent: #e8620c; --link: #b84a00; --accent-soft: #ffe8d4;
  --on-accent: #1f1006;
  --bar1: #ffb070; --bar2: #ff8a3d; --bar3: #e8620c; --bar4: #b84a00;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", Consolas, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #17110c; --panel: #211811; --line: #3a2a1d; --text: #f6ece3;
    --muted: #b59d89; --accent: #ff8a3d; --link: #ffa665; --accent-soft: #3b2312;
    --bar1: #6e3208; --bar2: #a8480a; --bar3: #e8620c; --bar4: #ff8a3d;
  }
}
:root[data-theme="dark"] {
  --bg: #17110c; --panel: #211811; --line: #3a2a1d; --text: #f6ece3;
  --muted: #b59d89; --accent: #ff8a3d; --link: #ffa665; --accent-soft: #3b2312;
  --bar1: #6e3208; --bar2: #a8480a; --bar3: #e8620c; --bar4: #ff8a3d;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main { max-width: 960px; margin: 0 auto; padding: 40px 16px 48px; }
a { color: var(--link); }
h1, h2, h3, .mono { font-family: var(--mono); }
h1 { font-size: clamp(36px, 8vw, 60px); letter-spacing: .01em; margin: 0; line-height: 1.1; }
h1 span, h3 span { color: var(--accent); }
h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .12em;
     color: var(--muted); margin: 64px 0 18px; font-weight: 600; }
h3 { font-size: 26px; margin: 0; }

/* raster bars under the title: a nod to the C64's colour bars */
.bars { display: grid; gap: 3px; margin: 18px 0 22px; max-width: 420px; }
.bars i { display: block; height: 5px; border-radius: 3px; }
.bars i:nth-child(1) { background: var(--bar1); width: 55%; }
.bars i:nth-child(2) { background: var(--bar2); width: 75%; }
.bars i:nth-child(3) { background: var(--bar3); width: 100%; }
.bars i:nth-child(4) { background: var(--bar4); width: 85%; }
.lede { font-size: clamp(18px, 2.4vw, 21px); max-width: 720px; margin: 0; }
.sub { color: var(--muted); max-width: 720px; margin: 14px 0 0; }

/* synth cards */
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px;
        overflow: hidden; display: flex; flex-direction: column; }
.card img { width: 100%; display: block; image-rendering: pixelated; background: #000;
            aspect-ratio: 384 / 272; }
.card .body { padding: 18px 18px 20px; display: flex; flex-direction: column; gap: 10px; flex: 1; }
.kind { font-family: var(--mono); font-size: 12px; text-transform: uppercase; letter-spacing: .1em;
        color: var(--accent); font-weight: 600; }
.card p { margin: 0; }
.card ul { margin: 0; padding-left: 18px; color: var(--muted); font-size: 15px; }
.card .ver { font-family: var(--mono); font-size: 12px; color: var(--muted); }
.actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: auto; padding-top: 6px; }
.btn { display: inline-block; padding: 9px 16px; border-radius: 8px; font-weight: 600;
       text-decoration: none; font-size: 15px; }
.btn.primary { background: var(--accent); color: var(--on-accent); }
.btn.primary:hover { filter: brightness(1.08); }
.btn.ghost { border: 1px solid var(--line); color: var(--text); }
.btn.ghost:hover { border-color: var(--accent); }
.card.next { border-style: dashed; background: transparent; justify-content: center; }
.card.next .body { justify-content: center; text-align: center; align-items: center; padding: 32px 22px; }
.plus { width: 54px; height: 54px; border-radius: 50%; display: grid; place-items: center;
        background: var(--accent-soft); color: var(--accent); font: 600 30px/1 var(--mono); }

/* the core diagram: synths on top of the core's modules */
.stack { display: grid; gap: 10px; }
.layer { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
.box { border-radius: 10px; padding: 12px 14px; font-size: 14px; }
.box b { font-family: var(--mono); font-size: 15px; display: block; margin-bottom: 2px; }
.synth { background: var(--panel); border: 1px solid var(--line); }
.synth.dashed { border-style: dashed; background: transparent; color: var(--muted); }
.joins { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; height: 14px; }
.joins i { border-left: 2px solid var(--accent); margin-left: 50%; }
.core { background: var(--accent-soft); border: 1px solid var(--accent); border-radius: 12px; padding: 14px; }
.core > b { font-family: var(--mono); color: var(--accent); display: block; margin-bottom: 10px; }
.mods { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 8px; }
.mod { background: var(--panel); border-radius: 8px; padding: 8px 10px; font-size: 13px; color: var(--muted); }
.mod b { font-family: var(--mono); color: var(--text); font-size: 13px; display: block; }
.hw { margin-top: 10px; text-align: center; font-family: var(--mono); font-size: 13px;
      color: var(--muted); border: 1px solid var(--line); border-radius: 10px; padding: 9px; }
@media (max-width: 620px) {
  .layer, .joins { grid-template-columns: 1fr; }
  .joins { display: none; }
}

.points { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 18px; margin-top: 22px; }
.point { border-top: 3px solid var(--accent); padding-top: 10px; }
.point b { display: block; margin-bottom: 4px; }
.point p { margin: 0; color: var(--muted); font-size: 15px; }

.band { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 0;
        background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
.band > a { display: block; background: #000; }
.band img { width: 100%; height: 100%; object-fit: cover; display: block; image-rendering: pixelated; }
.band .body { padding: 20px 22px; display: flex; flex-direction: column; gap: 10px; }
.band p { margin: 0; }
@media (max-width: 720px) { .band { grid-template-columns: 1fr; } }

.needs { list-style: none; padding: 0; margin: 0; display: grid; gap: 0; }
.needs li { padding: 10px 0; border-bottom: 1px solid var(--line); }
footer { margin-top: 64px; color: var(--muted); font-size: 14px; border-top: 1px solid var(--line); padding-top: 16px; }
</style>
</head>
<body>
<main>
  <h1>Sid<span>Synth</span></h1>
  <div class="bars" aria-hidden="true"><i></i><i></i><i></i><i></i></div>
  <p class="lede">Synthesizers for the Commodore 64 and its SID chip. Each one turns the C64 into a single dedicated instrument, played from MIDI, its own keyboard and paddles.</p>
  <p class="sub">They are all built on one shared core, so every new synth starts from proven parts and only has to bring its own sound.</p>

  <h2 id="synths">The synths</h2>
  <div class="cards">
%CARDS%
    <div class="card next">
      <div class="body">
        <div class="plus" aria-hidden="true">+</div>
        <h3>Next synth</h3>
        <p class="sub" style="margin:0">More instruments are coming, built on the same core as these.</p>
      </div>
    </div>
  </div>
%BAND%
  <h2 id="core">One core, many synths</h2>
  <p class="lede" style="font-size:18px">SID101, SID303, SID808 and SID500 share a core. The core does everything a C64 instrument needs apart from its sound. A synth adds its sound engine, its parameters, its keys and any screens of its own.</p>
  <div class="stack" style="margin-top:22px" role="img" aria-label="Diagram: SID101, SID303, SID808, SID500 and a next synth on top of the shared core, which sits on the C64 and its SID">
    <div class="layer">
%SYNTH_BOXES%
      <div class="box synth dashed"><b>next synth</b>its sound, its screens</div>
    </div>
    <div class="joins" aria-hidden="true"><i></i><i></i><i></i><i></i></div>
    <div class="core">
      <b>shared core</b>
      <div class="mods">
%MODULES%
      </div>
    </div>
    <div class="hw">Commodore 64 &middot; 8580 SID &middot; PAL</div>
  </div>

  <div class="points">
    <div class="point"><b>Fix it once</b><p>An improvement to MIDI, the screen or the keys is made in the core, and every synth gets it.</p></div>
    <div class="point"><b>Nothing breaks</b><p>New core features are switched off by default. When the core changes, each synth is checked to build byte for byte the same as before.</p></div>
    <div class="point"><b>They play together</b><p>SID101 and SID303 follow SID808's MIDI clock, and ignore its drum notes on channel 10, so they run as one rig.</p></div>
  </div>

  <h2 id="need">What you need</h2>
  <ul class="needs">
    <li><b>A Commodore 64 with an 8580 SID</b>, PAL. Or the VICE emulator, set to the 8580.</li>
    <li><b>A MIDI cartridge</b> if you want MIDI: Datel, Sequential, Passport or Namesoft. The synths also play from the C64 keyboard without one.</li>
    <li><b>Paddles</b> (optional) to turn knobs by hand, and a <b>disk drive</b> to save your patterns.</li>
  </ul>

  <footer>SidSynth &middot; &copy; 2026 Jarkko Lehti &middot; Free software under the GNU GPL v3 or later; each synth's source is in its downloads.</footer>
</main>
</body>
</html>
"""

CARD = """    <article class="card">
      <a href="{dir}/"><img src="{dir}/{shot}" alt="{alt}" loading="lazy"></a>
      <div class="body">
        <div class="kind">{kind}</div>
        <h3>{n1}<span>{n2}</span></h3>
        <p>{line}</p>
        <ul>
{facts}
        </ul>
        <div class="ver">{version}</div>
        <div class="actions">
          <a class="btn primary" href="{dir}/">Open {n1}{n2}</a>
{disk}        </div>
      </div>
    </article>"""


# the band's demo (band/, its README): site/band/, the files from band/work
# (not in git: made by the band scripts) under their published names
BAND = os.path.join(ROOT, "band", "work")
BAND_FILES = [  # (source in band/work, published name, what it is)
    ("glide-path-band.mp4", "glide-path.mp4",
     "Video: Pro-16 and the three synths' screens, the sound mixed"),
    ("glide-path-band.mp3", "glide-path.mp3",
     "Audio: each synth's part rendered in VICE (8580), mixed"),
    ("glide-band/band.mp3", "glide-path-live.mp3",
     "Audio: Pro-16 playing the three synths live, four VICEs in real time"),
    ("glide-path.d64", "glide-path.d64",
     "Pro-16 disk with the song (GLIDEPATH): channel 1 SID101, 2 SID303, 10 SID808"),
    ("glide-path.mid", "glide-path.mid", "The MIDI file Pro-16 recorded"),
    ("glide-path-cues.txt", "glide-path-cues.txt",
     "What plays when (times in the video and the rendered mix)"),
]
BAND_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Glide Path - SidSynth band demo</title>
<link rel="icon" href="../favicon.svg">
<style>
  :root { --bg: #fffaf4; --fg: #2b2118; --muted: #6d5c4d; --accent: #e8730c; --card: #ffffff;
          --line: #f0dcc6; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #1b1510; --fg: #f3e9df; --muted: #b9a693; --accent: #ff9a3c; --card: #261d16;
            --line: #3d2f22; } }
  body { margin: 0; background: var(--bg); color: var(--fg);
         font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 860px; margin: 0 auto; padding: 24px 16px 48px; }
  a { color: var(--accent); }
  h1 { margin: 8px 0 4px; } h1 span { color: var(--accent); }
  .lead { color: var(--muted); margin-top: 0; }
  video, audio { width: 100%; border-radius: 8px; }
  video { background: #000; margin: 12px 0; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
          padding: 12px 16px; margin: 16px 0; }
  .card h2 { font-size: 1.05rem; margin: 4px 0 8px; }
  ul { padding-left: 20px; } li { margin: 4px 0; }
  pre { white-space: pre-wrap; font-size: 0.85rem; color: var(--muted); margin: 0; }
  .how h3 { font-size: 0.98rem; margin: 18px 0 4px; }
  .how p { margin: 0 0 8px; }
  pre.flow { white-space: pre; overflow-x: auto; color: var(--fg); background: var(--bg);
             border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px;
             font: 0.8rem/1.45 ui-monospace, Consolas, Menlo, monospace; }
  footer { color: var(--muted); font-size: 0.85rem; margin-top: 32px; }
</style>
</head>
<body>
<main>
  <a href="../">&larr; SidSynth</a>
  <h1>Glide Path <span>&middot; the band</span></h1>
  <p class="lead">An original demo tune for SID101, SID303 and SID808, conducted by the 1986
  C64 sequencer Steinberg Pro-16: SID101's soft filtered lead with its slides, bends and
  filter swells, the mod wheel, the arpeggiator and the Sync voice; SID303's acid line;
  SID808's drums. Every sound
  change is a MIDI controller in the song, recorded and played by Pro-16 like the notes.</p>
  <video controls preload="metadata" poster="poster.jpg" src="glide-path.mp4"></video>
  <div class="card"><h2>Listen</h2>
%AUDIO%
  </div>
  <div class="card"><h2>Files</h2>
    <ul>
%FILES%
    </ul>
  </div>
  <div class="card"><h2>What plays when</h2>
    <pre>%CUES%</pre>
  </div>
  <div class="card how"><h2>How it's made</h2>
    <pre class="flow">                        ┌─ channel 1  ──▶ SID101  lead
Pro-16 ── MIDI ──▶ router ─┼─ channel 2  ──▶ SID303  acid bass
(VICE 1)  virtual          └─ channel 10 ──▶ SID808  drums
          cable                              (VICEs 2-4, each its own C64)</pre>
    <h3>Four C64s and virtual MIDI cables</h3>
    <p>Each machine is its own VICE emulator: Steinberg Pro-16 2.4 (1986) on one, the three
    synths on the others (each with an 8580 SID), all with an emulated MIDI cartridge. Instead
    of MIDI cables there are virtual MIDI ports (the teVirtualMIDI driver that comes with
    loopMIDI, opened from Python), one for each machine. A small Python router takes
    what Pro-16 sends and passes each channel on to its synth.</p>
    <h3>The song</h3>
    <p>Glide Path is written as a MIDI file by a Python script. Every sound change is in it
    as a MIDI controller: the cutoff swells, the mod wheel, the arpeggiator's modes, the
    switch to the Sync voice, SID808's long low kick. No presets are loaded. A check
    in the script makes sure the lead, a one-note synth, never has two notes at once unless
    it is a written slide.</p>
    <h3>Recorded into Pro-16</h3>
    <p>A script plays Pro-16 like a person would. Its keyboard reads are patched to take keys
    from a script through VICE's monitor. It sets the tempo (125 BPM), the length (49 bars)
    and the tracks' channels, then records each part on its own track in real time. Pro-16
    runs the clock, and each MIDI event is sent in when Pro-16's clock reaches it. Pro-16's
    input filters pass controllers and pitch bends, so it records them like the notes. The
    song is saved to a disk image with Pro-16's own disk menu, loaded again, and played back.
    Every note, controller and pitch bend Pro-16 sends is then checked against the file,
    clock by clock. All 1,612 notes, 927 controllers and 52 bends came out on their clocks.</p>
    <h3>Two recordings</h3>
    <p><b>Live</b> (glide-path-live.mp3): Pro-16 plays the disk to the three synths in real
    time and each synth's sound is recorded. Each emulator keeps its own time, about 0.2 %
    apart, so each part is matched to the exact render below and stretched back onto the song.</p>
    <p><b>Rendered</b> (the video and glide-path.mp3): each synth plays its part on its own,
    from the same MIDI fed straight to its MIDI input in its own engine ticks, while every
    video frame is grabbed. That is exact and the same every time. Pro-16's screen is grabbed
    frame by frame the same way. Each part's sound is placed on its notes by measuring it
    (all three within 1 ms) and its loudness balanced (EBU R128, the lead a little above the
    bass and drums).</p>
    <h3>Timing</h3>
    <p>The synths play each note when its MIDI arrives, so they stay together. The one
    exception is SID101's arpeggiator, which runs on its own clock. The song is set to
    125 BPM, SID101's own tempo, and every arpeggio chord is struck fresh, so the arpeggios
    keep time.</p>
  </div>
  <footer>SidSynth &middot; &copy; 2026 Jarkko Lehti</footer>
</main>
</body>
</html>
"""


VIDEO_LEAD = 2.0    # seconds before the song's first beat in the video and its mix (band/feeds.py LEAD)


def video_cues(path):
    """glide_path.py's cue sheet ("m:ss.s  bar ..." in the song's time) in
    the video's time."""
    out = []
    for line in open(path, encoding="utf-8").read().splitlines():
        m = re.match(r"(\d+):(\d+\.\d)  (.*)", line)
        if not m:
            out.append(line + f" (times in the video and its mix: +{VIDEO_LEAD:.0f} s lead-in)")
            continue
        t = int(m[1]) * 60 + float(m[2]) + VIDEO_LEAD
        out.append(f"{int(t) // 60}:{t % 60:04.1f}  {m[3]}")
    return "\n".join(out) + "\n"


POSTER_AT = 60          # seconds into the video: the band's still (the sync section)
BAND_SECTION = """
  <h2 id="band">The band</h2>
  <div class="band">
    <a href="band/"><img src="band/poster.jpg" alt="Steinberg Pro-16 and the three synths' screens playing Glide Path together"></a>
    <div class="body">
      <div class="kind">Demo</div>
      <h3>Glide <span>Path</span></h3>
      <p>SID101, SID303 and SID808 playing together, conducted by the 1986 C64 sequencer
      Steinberg Pro-16 over MIDI: SID101's lead with its slides, bends and filter swells, the
      arpeggiator and the Sync voice; SID303's acid line; SID808's drums. Every sound change is
      a MIDI controller in the song.</p>
      <div class="actions">
        <a class="btn primary" href="band/">Watch and listen</a>
        <a class="btn ghost" href="band/glide-path.mp3">MP3</a>
      </div>
    </div>
  </div>
"""


def band_section():
    """The main page's band section, if site/band has its page."""
    if not os.path.exists(os.path.join(SITE, "band", "index.html")):
        return ""
    return BAND_SECTION


def band_page():
    """site/band/: the band's demo, its files and a page; kept as it is if
    band/work doesn't have the files (they aren't in git)."""
    missing = [s for s, _, _ in BAND_FILES if not os.path.exists(os.path.join(BAND, s))]
    if missing:
        print(f"site/band kept as it is: band/work lacks {', '.join(missing)}")
        return
    out = os.path.join(SITE, "band")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):           # emptied, not removed (OneDrive may hold the folder)
        p = os.path.join(out, f)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    e = html.escape
    files, audio = [], []
    for src, name, what in BAND_FILES:
        if name.endswith("-cues.txt"):          # in the video's time: its lead-in added
            with open(os.path.join(out, name), "w", encoding="utf-8", newline="\n") as f:
                f.write(video_cues(os.path.join(BAND, src)))
        else:
            shutil.copy(os.path.join(BAND, src), os.path.join(out, name))
        mb = os.path.getsize(os.path.join(out, name)) / 1e6
        files.append(f'      <li><a href="{name}" download>{name}</a> ({mb:.1f} MB): {e(what)}</li>')
        if name.endswith(".mp3"):
            audio.append(f"    <p>{e(what)}</p>\n    <audio controls preload=\"none\" src=\"{name}\"></audio>")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(POSTER_AT), "-i",
                    os.path.join(out, "glide-path.mp4"), "-frames:v", "1", "-vf", "scale=768:-2",
                    "-q:v", "3", os.path.join(out, "poster.jpg")], check=True)
    cues = open(os.path.join(out, BAND_FILES[-1][1]), encoding="utf-8").read().strip()
    page = (BAND_PAGE.replace("%AUDIO%", "\n".join(audio)).replace("%FILES%", "\n".join(files))
            .replace("%CUES%", e(cues)))
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    print(f"site/band written: {len(BAND_FILES)} files")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-synths", action="store_true",
                    help="keep the synths' folders as they are; only the main page is rewritten")
    a = ap.parse_args()

    # each synth's page first: its make_site.py writes site/<synth>/ here
    for s in SYNTHS:
        if not a.no_synths:
            subprocess.run([sys.executable, "make_site.py"], cwd=os.path.join(PROJECTS, s["dir"]),
                           check=True)
        if not os.path.exists(os.path.join(SITE, s["dir"], "index.html")):
            sys.exit(f"site/{s['dir']} is empty: run projects/{s['dir']}/make_site.py "
                     "(or leave out --no-synths)")

    # the main page's own files (the synths' folders stay)
    for f in ("favicon.svg", "favicon-32.png", "apple-touch-icon.png"):
        shutil.copy(os.path.join(ROOT, "assets", f), SITE)

    e = html.escape
    cards, boxes = [], []
    for s in SYNTHS:
        d = os.path.join(PROJECTS, s["dir"])
        n1, n2 = s["name"]
        cards.append(CARD.format(
            dir=s["dir"], shot=s["shot"], alt=e(s["alt"]), kind=e(s["kind"]), n1=n1, n2=n2,
            line=e(s["line"]), version=e(s["version"](d)),
            disk="" if s.get("no_disk") else
                 f'          <a class="btn ghost" href="{s["dir"]}/files/{s["dir"]}.d64" download>Disk image</a>\n',
            facts="\n".join(f"          <li>{e(f)}</li>" for f in s["facts"])))
        boxes.append(f'      <div class="box synth"><b>{n1}{n2}</b>{e(s["kind"].lower())}</div>')
    mods = "\n".join(f'        <div class="mod"><b>{e(m)}</b>{e(t)}</div>' for m, t in CORE)
    band_page()
    page = (TEMPLATE.replace("%CARDS%", "\n".join(cards)).replace("%SYNTH_BOXES%", "\n".join(boxes))
            .replace("%MODULES%", mods).replace("%BAND%", band_section()))
    with open(os.path.join(SITE, "index.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)

    size = sum(os.path.getsize(os.path.join(p, n)) for p, _, ns in os.walk(SITE) for n in ns)
    print(f"site/ written: {size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
