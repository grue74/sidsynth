# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the SID808 user manual: docs/SID808-manual.pdf.

Run from anywhere: python docs/manual.py [out.pdf]   (needs reportlab and
docs/screen-grid.png, docs/screen-params.png: 3x nearest-neighbour VICE
screenshots of the running program).
"""
import os
import sys

from reportlab import rl_config
from reportlab.lib import colors

# reproducible output: no creation date or random document ID in the PDF, so
# rebuilding an unchanged manual gives an identical file
rl_config.invariant = 1
from reportlab.lib.enums import TA_CENTER  # noqa: E402
from reportlab.lib.pagesizes import A4  # noqa: E402
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet  # noqa: E402
from reportlab.lib.units import mm  # noqa: E402
from reportlab.platypus import (Image, KeepTogether, PageBreak, Paragraph,  # noqa: E402
                                SimpleDocTemplate, Spacer, Table, TableStyle)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "SID808-manual.pdf")


def version():
    """The version build.sh wrote (version.txt), else the build number."""
    for name in ("version.txt", "build-number.txt"):
        try:
            return open(os.path.join(ROOT, name)).read().strip()
        except OSError:
            pass
    return "?"


VERSION = version()

# ---------------------------------------------------------------- styles
INK = colors.HexColor("#1d1d1f")
ACCENT = colors.HexColor("#c2410c")      # 808 orange for headings
LIGHT = colors.HexColor("#fdf0e6")       # table header / note boxes
RULE = colors.HexColor("#ecd3c0")

ss = getSampleStyleSheet()
body = ParagraphStyle("body", parent=ss["Normal"], fontName="Helvetica",
                      fontSize=10, leading=14, textColor=INK, spaceAfter=6)
small = ParagraphStyle("small", parent=body, fontSize=8.5, leading=11, spaceAfter=0)
cell = ParagraphStyle("cell", parent=body, fontSize=9, leading=12, spaceAfter=0)
cellb = ParagraphStyle("cellb", parent=cell, fontName="Helvetica-Bold")
h1 = ParagraphStyle("h1", parent=body, fontName="Helvetica-Bold", fontSize=17,
                    leading=21, textColor=ACCENT, spaceBefore=4, spaceAfter=8)
h2 = ParagraphStyle("h2", parent=body, fontName="Helvetica-Bold", fontSize=12,
                    leading=16, textColor=INK, spaceBefore=8, spaceAfter=4)
bullet = ParagraphStyle("bullet", parent=body, leftIndent=12, bulletIndent=2, spaceAfter=3)
caption = ParagraphStyle("caption", parent=small, alignment=TA_CENTER,
                         textColor=colors.HexColor("#555555"), spaceBefore=3)


def P(text, style=body):
    return Paragraph(text, style)


def bullets(items):
    return [Paragraph(t, bullet, bulletText="•") for t in items]


def key(k):
    """Inline key cap look-alike."""
    return f'<font name="Courier-Bold">{k}</font>'


def table(rows, widths, header=True, bold_first_col=True):
    """Table of Paragraph cells; the first row is the header when header=True."""
    data = []
    for r, row in enumerate(rows):
        out = []
        for c, txt in enumerate(row):
            st = cellb if (header and r == 0) or (bold_first_col and c == 0) else cell
            out.append(Paragraph(txt, st))
        data.append(out)
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    style = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, RULE),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]
    if header:
        style.append(("BACKGROUND", (0, 0), (-1, 0), LIGHT))
    t.setStyle(TableStyle(style))
    return t


def note_box(text):
    """Shaded single-cell box for tips and warnings."""
    t = Table([[Paragraph(text, cell)]], colWidths=[170 * mm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), LIGHT),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def on_page(canv, doc):
    canv.saveState()
    canv.setFont("Helvetica", 8)
    canv.setFillColor(colors.HexColor("#777777"))
    if doc.page > 1:
        canv.drawString(20 * mm, 12 * mm, f"SID808 user manual · {VERSION}")
        canv.drawRightString(190 * mm, 12 * mm, str(doc.page))
    canv.restoreState()


SHOT_W, SHOT_H = 144 * mm, 102 * mm        # 384 x 272 screenshots
story = []

# --- cover
story += [
    Spacer(1, 28 * mm),
    P("SID808", ParagraphStyle("t", parent=h1, fontSize=40, leading=46)),
    P("An 808-style drum machine for the Commodore 64 and the 8580 SID",
      ParagraphStyle("st", parent=body, fontSize=14, leading=18)),
    P(f"User manual · {VERSION}", ParagraphStyle("st2", parent=body, fontSize=12,
                                                 textColor=colors.HexColor("#666666"))),
    Spacer(1, 12 * mm),
    Image(os.path.join(HERE, "screen-grid.png"), width=SHOT_W, height=SHOT_H),
    P("The step grid playing pattern 9 (FULL), one of the patterns it starts with.", caption),
    PageBreak(),
]

# --- 1. what it is
story += [
    P("1. What it is", h1),
    P("SID808 turns a C64 into a drum machine in the style of the Roland TR-808. "
      "Thirteen drum sounds are synthesized live on the SID chip: kick, snare, "
      "clap, closed and open hat, three toms, rim shot, claves, cymbal, maracas "
      "and a ring-modulated cowbell. A 16-step pattern sequencer with 64 patterns "
      "and a song mode plays them, and they can also be played from MIDI or the "
      "C64 keyboard."),
    *bullets([
        "<b>Step grid:</b> one row per sound, 16 steps, three levels per step "
        "(soft, normal, accent). Tempo 60-240 BPM, swing, pattern length 1-16, mute.",
        "<b>Songs:</b> chain up to 64 pattern entries, each repeated 1-9 times.",
        "<b>Live record:</b> play hits in while the pattern runs; they land on the nearest step.",
        "<b>Sound page:</b> Level, Tune, Decay and Tone for every sound.",
        "<b>MIDI:</b> General MIDI drum notes in (velocity = accent), MIDI clock "
        "in, MIDI notes and clock out.",
        "<b>Disk:</b> save and load everything (patterns, song, tempo, knobs) to "
        "drives 8 to 16.",
    ]),
    P("What you need", h2),
    *bullets([
        "A <b>PAL</b> Commodore 64 with an <b>8580 SID</b> (a C64C, or a C64 "
        "fitted with an 8580). The sounds are made for the 8580; on a 6581 the "
        "filtered sounds come out quite different and soft hits may thump. On "
        "an NTSC machine the tempo and pitches are off.",
        "Optional: a MIDI interface cartridge, Sequential, Passport, Datel/Siel "
        "or Namesoft compatible.",
        "Optional: a pair of paddles, to turn any parameter by hand.",
        "Optional: a disk drive (or SD2IEC, Ultimate, ...) to save your songs.",
        "Or the VICE emulator with the 8580 SID model selected.",
    ]),
    P("Files", h2),
    table([
        ["File", "What"],
        ["sid808.d64", "Disk image with all the programs below. Start with "
         + key('LOAD"SID808",8') + " and " + key("RUN") + "."],
        ["sid808.prg", "The drum machine. Use this one to play."],
        ["sid808-test.prg (SID808-DEMO)", "Plays every sound soft and hard, then "
         "an 808 beat, through the MIDI input (no MIDI hardware needed)."],
        ["sid808-track.prg (SID808-TRACK)", "Plays a short drum track the same way."],
        ["sid808-stress.prg, -stress-max", "Test programs: the sequencer under heavy "
         "load (section 9)."],
    ], [62 * mm, 108 * mm]),
    PageBreak(),
]

# --- 2. getting started
story += [
    P("2. Getting started", h1),
    P("Load and run it: " + key('LOAD"SID808",8') + ", " + key("RUN") + ". It starts "
      "on the <b>step grid</b> with pattern 1 on screen. Thirteen patterns are "
      "already there (1 to 13: grooves, fills, a break, an intro and an ending), so "
      "press " + key("RUN/STOP") + " and it plays. " + key("F1") + " and " + key("F2")
      + " step through the patterns; the next one starts when the current one ends."),
    P("Move the cursor with the cursor keys and press " + key("SPACE") + " to set or "
      "clear a step, or " + key("1") + " " + key("2") + " " + key("3") + " for a soft, "
      "normal or accented hit. " + key("RETURN") + " plays the sound under the cursor. "
      + key("F7") + " goes to the <b>parameter screen</b> and back."),
    note_box("Everything you change lives in memory until you save it: " + key("W")
             + " saves, " + key("L") + " loads (section 7). Without a save, a reset "
             "brings back the patterns it starts with."),
    Spacer(1, 4 * mm),
    P("In VICE", h2),
    P("Use x64sc (or x64) with the SID model set to <b>8580</b>, PAL. For MIDI, "
      "enable a MIDI cartridge (Datel/Siel is the default here) under the "
      "cartridge / I/O settings and pick the same type on the parameter screen."),
    PageBreak(),
]

# --- 3. the step grid
story += [
    P("3. The step grid", h1),
    Image(os.path.join(HERE, "screen-grid.png"), width=120 * mm, height=85 * mm),
    P("The step grid while playing.", caption),
    Spacer(1, 3 * mm),
    P("From the top: the <b>title row</b> (pattern number, tempo, swing, length, and "
      "PLAY with the pattern playing, or STOP); the step numbers with a marker running "
      "along while it plays; one row per sound, each cell "
      + key(".") + " off, " + key("o") + " soft, " + key("x") + " normal, "
      + key("X") + " accent; the <b>song row</b>; the <b>status row</b> (the sound on "
      "each of the three SID voices, the last velocity, CPU and MIDI lights); and "
      "the help rows."),
    P("Keys on the grid", h2),
    table([
        ["Key", "Does"],
        ["CRSR (SHIFT: the other way)", "move the cursor (held: repeats)"],
        ["SPACE", "cell on (normal) / off"],
        ["1 2 3", "cell soft / normal / accent, cursor to the next step"],
        ["DEL", "cell off"],
        ["RETURN (SHIFT: accent)", "play the cursor's sound (velocity 100, accent 127); recorded while recording"],
        ["M", "mute / unmute the cursor's sound"],
        ["+ / -", "pattern length 1-16 steps"],
        ["F1 / F2", "next / previous pattern (it plays from the next pattern start)"],
        ["F3 / F4", "tempo +1 / -1 BPM (60-240)"],
        ["F5 / F6", "swing up / down (0-15: off-beat steps late by swing/32 of a step)"],
        ["C", "copy the pattern to the next one and show it"],
        ["HOME / CLR", "cursor to the start / clear the pattern"],
        ["RUN/STOP", "play / stop (sounds ring out)"],
        ["F7 / F8", "parameter screen / all sounds off"],
        ["S, comma, period, P, ;, left arrow", "song mode (section 4)"],
        ["R", "live record on / off (section 4)"],
        ["U (SHIFT: redo)", "undo the last edit, up to 12 back; SHIFT+U redoes"],
        ["W / L", "save / load (section 7)"],
        ["D", "send the song over MIDI as SysEx (section 8)"],
    ], [52 * mm, 118 * mm]),
    Spacer(1, 3 * mm),
    P("<b>Undo:</b> " + key("U") + " takes back the last edit - a cell, the length, a "
      "cleared or copied-over pattern, a song change - and pressing it again goes "
      "further back, up to 16 edits. " + key("SHIFT") + "+" + key("U") + " redoes. A whole "
      "pass of live recording undoes in one go. The grid jumps to the pattern that "
      "changed, and the song row says what happened. Loading from disk starts the "
      "undo history afresh; mutes, tempo and swing are not undone."),
    P("A pattern has 13 rows of 16 steps. A shorter length (" + key("+") + "/" + key("-")
      + ") plays only its first steps: 12 for a triplet feel, 15 for an odd bar. "
      "The grid's hits go through the same voice allocation as MIDI notes, so choke "
      "groups and voice sharing (section 5) work the same."),
    PageBreak(),
]

# --- 4. songs and live record
story += [
    P("4. Songs and live record", h1),
    P("Song mode", h2),
    P("A song is a list of up to 64 entries, each a pattern and how many times it "
      "plays (1-9). The <b>song row</b> shows " + key("SONG") + " (reversed while song "
      "mode is on), the song cursor and the song's length, then five entries around "
      "the cursor: " + key("01x2") + " is pattern 1 twice, " + key(">") + " marks the "
      "entry playing, " + key("----") + " the free place after the last one."),
    table([
        ["Key", "Does"],
        ["S", "song mode on / off"],
        [", / .", "song cursor back / forward; on an entry the grid shows its pattern"],
        ["P", "put the grid's pattern into the song at the cursor (after the last entry: add one)"],
        ["; (SHIFT: back)", "the cursor entry's repeats, 1-9"],
        ["left arrow", "delete the cursor's entry"],
    ], [40 * mm, 130 * mm]),
    Spacer(1, 3 * mm),
    P("In song mode " + key("RUN/STOP") + " plays the song from its first entry and loops "
      "it: each entry's pattern as many times as its repeats, then the next. The grid "
      "follows the pattern playing; " + key("F1") + "/" + key("F2") + " still show other "
      "patterns for editing. Turned on while playing, the song starts at the next "
      "pattern start. You can edit the song while it plays."),
    P("Live record", h2),
    P(key("R") + " turns recording on (" + key("REC") + " on the song row). While the "
      "sequencer plays, every hit you play live - MIDI notes, the parameter screen's "
      "note keys, " + key("RETURN") + " on the grid - is written into the pattern "
      "playing, on the nearest step (past half a step: the next one). The level is the "
      "nearest of soft (velocity below 78), normal (below 114) and accent. The hit "
      "sounds once as you played it, and from the next time round the step plays it."),
    PageBreak(),
]

# --- 5. the sounds
SOUNDS = [
    ("Kck", "Kick", "36, 35", "Z", "a triangle dropping fast from 500 Hz to 48 Hz"),
    ("Snr", "Snare", "38, 40", "X, C", "a tone dropping 330 to 185 Hz, then noise (the snappy)"),
    ("Clp", "Clap", "39", "D", "three bursts of band-passed noise and a tail"),
    ("CHH", "Closed hat", "42, 44", "G, H", "high-passed noise; chokes the open hat"),
    ("OHH", "Open hat", "46", "J", "longer high-passed noise; choked by the closed hat"),
    ("Cbl", "Cowbell", "56", "6", "ring modulation on two voices (540 + 800 Hz), else one pulse tone"),
    ("LTm", "Low tom", "41, 43", "V, B", "a triangle dropping to 90 Hz"),
    ("MTm", "Mid tom", "45, 47", "N, M", "the same at 130 Hz"),
    ("HTm", "High tom", "48, 50", ", . Q W", "the same at 185 Hz"),
    ("Rim", "Rim shot", "37", "S", "a 1667 Hz tick, then a short 455 Hz ring"),
    ("Clv", "Claves", "75", "F5, then 0", "a short 2.3 kHz tone with a small drop"),
    ("Cym", "Cymbal", "49, 51, 52, 55, 57, 59", "L ; / 2 3 E", "high-passed noise, long decay"),
    ("Mrc", "Maracas", "70", "F5, then 7", "a short burst of very high noise"),
]
story += [
    P("5. The sounds", h1),
    P("Each sound is synthesized as it plays, from a short program of steps "
      "(waveform, pitch and pitch drop, level and decay, filter) run 500 times a "
      "second. Velocity scales the level: soft hits are quieter, accents loudest."),
    table([["Row", "Sound", "MIDI notes", "Keys (param. screen)", "How it is made"]]
          + [[a, b, c, d, e] for a, b, c, d, e in SOUNDS],
          [14 * mm, 22 * mm, 30 * mm, 30 * mm, 74 * mm]),
    Spacer(1, 3 * mm),
    P("Three voices for thirteen sounds", h2),
    P("The SID has three voices, so the sounds share them. A new hit takes the voice "
      "already playing its <b>choke group</b> (a closed hat stops an open hat, a new "
      "kick ends the old kick's tail), else a free voice, else the quietest sound, "
      "weighted by importance: kick and snare are hardest to take, maracas and closed "
      "hats easiest. If everything sounding matters more than the new hit, the new "
      "hit is the one dropped. Stopped sounds fade out in a few milliseconds rather "
      "than being cut, so voice changes don't click."),
    P("The status row shows what each voice plays. In busy patterns, sounds with long "
      "tails (cymbal, open hat, cowbell) are the first to be shortened; the cowbell "
      "gets its two-voice ring-modulated version only when two voices are free."),
    P("One filter", h2),
    P("The SID has one filter. The clap and cowbell use it as a band-pass, the hats, "
      "cymbal and maracas as a high-pass. The newest filtered hit takes it, except "
      "that a sound wanting another filter type doesn't take it from a ringing cowbell "
      "or a louder sound: it then plays unfiltered (a closed hat right over a cowbell "
      "sounds a little fuller)."),
    PageBreak(),
]

# --- 6. the parameter screen
story += [
    P("6. The parameter screen", h1),
    Image(os.path.join(HERE, "screen-params.png"), width=120 * mm, height=85 * mm),
    P("The parameter screen with the Clap's sound page.", caption),
    Spacer(1, 3 * mm),
    table([
        ["Parameter", "Range", "CC", "Does"],
        ["Volume", "0-15", "7", "master volume"],
        ["Level", "0-15", "16", "the selected sound's loudness (15 = as made)"],
        ["Tune", "-12..+12", "17", "its pitch in semitones; noise sounds get brighter or darker"],
        ["Decay", "0-15", "18", "how long it rings: 8 = as made, 0 = twice as fast, 15 = four times as long"],
        ["Tone", "0-15", "19", "how bright its attack is: 8 = as made, 0 = half, 15 = double "
         "(filtered sounds: the filter cutoff; the others: the attack's pitch, e.g. the kick's knock)"],
        ["Sound", "13 sounds", "", "which sound Level, Tune, Decay and Tone show; follows the grid's cursor row"],
        ["MIDI channel", "Omni, 1-16", "", "the channel notes are read from (and sent on: Omni sends on 10)"],
        ["MIDI i/face", "Off, Sequential, Passport, Datel, Namesoft", "", "the cartridge type (Datel at start)"],
        ["Paddles", "Port 1, Port 2, Off", "", "where the paddles are (Off at start)"],
        ["Clock", "Internal, MIDI", "", "what drives the sequencer (section 8)"],
        ["MIDI out", "Off, On", "", "send the sequencer's notes and clock"],
        ["Disk drive", "8-16", "", "for save and load; at start the drive it was loaded from"],
    ], [26 * mm, 34 * mm, 10 * mm, 100 * mm]),
    Spacer(1, 3 * mm),
    P("The <b>sound page</b> (Level, Tune, Decay, Tone) always shows the sound picked by "
      "Sound; moving the grid's cursor to another row picks that sound too. A change "
      "applies from the sound's next hit. The knobs are saved with the song."),
    PageBreak(),
    P("Keys on the parameter screen", h2),
    table([
        ["Key", "Does"],
        ["F1 / F2 (or CRSR down / up)", "next / previous parameter"],
        ["F3 / F4, + / -, CRSR right / left", "change the value (held: repeats)"],
        ["F5 / F6", "keyboard octave up / down"],
        ["F7", "back to the step grid"],
        ["F8 or RUN/STOP", "all sounds off"],
        ["RETURN", "learn: move a MIDI knob or turn a paddle to give it to the selected parameter (RETURN again cancels)"],
        ["DEL", "remove the selected parameter's MIDI controller and paddle"],
        ["Z S X D C V G B H N J M , L . ; /  and  Q 2 W 3 E ...", "play sounds as MIDI notes "
         "(Z = note 36, kick, at the start octave; table in section 5); SHIFT = accent"],
    ], [62 * mm, 108 * mm]),
    Spacer(1, 3 * mm),
    P("MIDI and paddle learn", h2),
    *bullets([
        "Select a parameter (Volume to Tone), press " + key("RETURN") + ", then move a "
        "MIDI knob or turn a paddle: it now sets that parameter. The P column shows "
        "a paddle (X or Y), the CC column the MIDI controller.",
        "One knob and one paddle per parameter; learning a new one replaces the old. "
        + key("DEL") + " removes both.",
        "At start CC 7 is Volume and CC 16-19 are Level, Tune, Decay and Tone of the "
        "selected sound. Learnt assignments are not saved.",
        "Knobs on the sound page always turn the sound selected at the moment.",
    ]),
    PageBreak(),
]

# --- 7. disk
story += [
    P("7. Saving and loading", h1),
    P(key("W") + " (save) or " + key("L") + " (load) on the grid puts a name prompt on "
      "the song row, with the drive's number and the last name used (first "
      + key("SONG") + "). Type a name (letters, digits, space, + - .), "
      + key("DEL") + " deletes, " + key("RETURN") + " goes, " + key("RUN/STOP") + " cancels."),
    P("The file holds everything: the 64 patterns, the song, tempo, swing, mutes and "
      "every sound's Level, Tune, Decay and Tone. Saving replaces a file of the same "
      "name. Loading checks the file first and changes nothing if it isn't a SID808 "
      "file; files saved by earlier versions load, with the newer knobs at their "
      "defaults."),
    P("While the disk works the sequencer stops and there is no sound or MIDI. Then "
      "the song row shows the drive's message (" + key("00, OK,00,00") + ", "
      + key("62, FILE NOT FOUND,00,00") + ", ...) or " + key("NO DRIVE 9") + ", "
      + key("NOT A SID808 FILE") + ", " + key("FILE ENDED EARLY") + " until a key. "
      "Set the drive with Disk drive on the parameter screen."),
    Spacer(1, 6 * mm),

    # --- 8. MIDI
    P("8. MIDI", h1),
    P("Notes in", h2),
    P("Notes on the selected MIDI channel (Omni: any) play the sounds of the General "
      "MIDI drum map (section 5). Velocity sets the level; note offs are ignored, "
      "drums ring out on their own. CC 120 and 123 stop all sounds."),
    P("Clock in", h2),
    P("With Clock set to MIDI, the sequencer follows MIDI clock: Start plays from the "
      "beginning (the song's first entry in song mode), each 6 clocks (24 per quarter "
      "note) move one step, Continue goes on from where it stopped, Stop stops. The "
      "title row shows " + key("EXT") + " for the tempo. Swing still works."),
    P("Patterns and songs over MIDI", h2),
    P("Controller 85 picks the pattern: values 0-63 are patterns 1-64. It plays from the "
      "next pattern start, as F1/F2 choose it (stopped: from play), the grid shows it, and "
      "song mode goes off. It works only on SID808's own channel, not in Omni, so one "
      "message can't switch every synth on the cable. Song select turns song mode on "
      "(SID808 holds one song; the number doesn't matter). Song position, with Clock on "
      "MIDI and the sequencer stopped, sets where the next Continue plays from: the song "
      "entry, its repeat and step, or the pattern's step. Start still plays from the "
      "beginning."),
    P("Backing up over MIDI", h2),
    P("The song file (everything a disk save holds) goes to a PC and back as "
      "SysEx, byte for byte as the file on disk: a file fetched over MIDI can "
      "go on a disk, and one from a disk can be sent. The PC tool is "
      "<b>sysex.py</b>, a download on SID808's web page (Python with mido "
      "and python-rtmidi):"),
    table([
        ["Command", "Does"],
        ["python sysex.py get sid808", "Fetches the song file into "
         "sid808-song.prg (-o picks the name)"],
        ["python sysex.py send FILE", "Sends a song file back (a .prg fetched "
         "before, or copied from a disk): which synth it is for comes from "
         "the file"],
        ["--port NAME, --channel N", "The MIDI port (part of its name), and the "
         "synth's channel when several synths share the line"],
    ], [60 * mm, 110 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        key('D') + " on the grid" + " sends the song without a request (any SysEx recorder "
        "takes it).",
        "With MIDI out on, a playing sequencer stops before a dump goes out: "
        "its notes would cut the dump. With MIDI out off it plays on, and the "
        "dump only uses the time the sound leaves.",
        "A dump that comes in stops the sequencer and silences the synth at "
        "once; when it is whole and SID808's it loads like a disk file and "
        "the song row shows <b>SYSEX: SONG LOADED</b>. Otherwise nothing "
        "changes and the song row says why: <b>SYSEX: BAD DATA</b> (a byte "
        "lost on the way: send it again) or <b>SYSEX: NOT A SID808 FILE</b>.",
        "A SID808 song is large (13.5 KB): sending or taking one takes "
        "about 5 seconds. Song files from earlier versions load too, "
        "with the newer knobs at their defaults, as from disk.",
        "SID808 answers on its MIDI channel, or to any channel in Omni.",
    ]),
    P("SysEx reference", h2),
    P("For writing your own tools. The manufacturer ID is 7D (for non-commercial "
      "use); the numbers are hexadecimal."),
    table([
        ["Message", "Bytes"],
        ["Request", "F0 7D <i>synth device</i> 01 <i>kind</i> F7"],
        ["Dump", "F0 7D <i>synth device</i> 02 <i>kind len-lo len-hi data sum</i> F7"],
    ], [30 * mm, 140 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        "<i>synth</i>: 1 SID303, 2 SID808, 3 SID101 (the SidSynth family). "
        "<i>device</i>: the synth's MIDI channel minus 1, or 7F for any; a "
        "synth in Omni answers every device and sends 7F.",
        "<i>kind</i>: 0 the song file (SID101: 1 the preset bank).",
        "<i>len</i>: the file's length in bytes, 7 bits in each byte "
        "(len-lo + 128 x len-hi).",
        "<i>data</i>: the file exactly as on disk (load address, header, "
        "contents) in groups of up to 7 bytes: first a byte with the group's "
        "top bits (bit 0 = the group's first byte's), then each byte's low 7 "
        "bits.",
        "<i>sum</i>: makes every byte from <i>kind</i> to <i>sum</i> add up "
        "to a multiple of 128.",
        "A dump is checked whole before anything changes; a status byte "
        "(other than realtime) in the middle, or a second without data, ends "
        "it unused.",
    ]),
    P("MIDI out", h2),
    P("With MIDI out On, every hit the sequencer plays goes out as a note (velocity 55, "
      "100 or 127) on the MIDI channel (Omni: channel 10), with the sound's GM note. "
      "With the internal clock it also sends Start, Clock and Stop, so other gear can "
      "follow SID808. Muted sounds are not sent; hits played live are not echoed."),
    PageBreak(),
]

# --- 9. CPU and limits
story += [
    P("9. The CPU warning", h1),
    P("Every sound is computed 500 times a second while the sequencer runs, so a very "
      "busy moment can take longer than its 2 ms. SID808 then catches up: hits come a "
      "little late but none is lost, and the tempo stays right on average. The status "
      "row's " + key("CPU") + " light tells you when that happens:"),
    *bullets([
        "<b>" + key("CPU") + " reversed:</b> hits are 16 ms or more late (audible jitter). "
        "The pattern is too busy at that point: fewer simultaneous hits, or less "
        "extreme knob settings, help.",
        "<b>" + key("CPU!") + " reversed:</b> it has fallen so far behind that time is lost: "
        "the tempo slips (and MIDI clock out with it).",
    ]),
    P("Each light stays on for about 2 seconds after the last time. The normal "
      "patterns never light it; the test program SID808-STRESSMAX (every sound on "
      "every step, extreme knobs, a continuous stream of MIDI interrupts) shows "
      + key("CPU!") + " on purpose."),
    Spacer(1, 4 * mm),
    P("10. Notes and limits", h1),
    *bullets([
        "Three voices for thirteen sounds: in busy patterns some tails are cut short "
        "and the weakest hits are dropped (section 5).",
        "Made and tuned for the 8580 SID and PAL timing (see What you need).",
        "Learnt MIDI controllers and paddles are not saved.",
        "This is a test release: it has been made and tested in the VICE emulator. "
        "Reports from real hardware (C64 model, SID, MIDI interface, drive) are "
        "very welcome.",
    ]),
    Spacer(1, 6 * mm),
    P("SID808 is free software under the GNU General Public License, version 3 or "
      "(at your option) any later version. © 2026 Jarkko Lehti.", small),
]


def build(path):
    doc = SimpleDocTemplate(path, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm,
                            topMargin=18 * mm, bottomMargin=20 * mm,
                            title="SID808 user manual", author="Jarkko Lehti",
                            subject="An 808-style drum machine for the Commodore 64")
    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)


if __name__ == "__main__":
    build(OUT)
    print(OUT)
