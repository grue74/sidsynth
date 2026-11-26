# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the SID500 user manual: docs/SID500-manual.pdf.

Run from anywhere: python docs/manual.py [out.pdf]   (needs reportlab, and
docs/screen.png, screen-grid.png, screen-list.png, screen-params.png: VICE
screenshots, 384x272 with the borders). SID101's docs/manual.py is the
model; the keys and figures here follow docs/design.md (the screens as
built) and docs/latency.md (the timing).
"""
import os
import sys

from reportlab import rl_config
from reportlab.lib import colors

# reproducible output: no creation date or random document ID in the PDF, so
# rebuilding an unchanged manual gives an identical file
rl_config.invariant = 1
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (Image, PageBreak, Paragraph,
                                SimpleDocTemplate, Spacer, Table, TableStyle)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "SID500-manual.pdf")

# ---------------------------------------------------------------- styles
INK = colors.HexColor("#1d1d1f")
ACCENT = colors.HexColor("#2a5fc4")      # the icon's blue for headings
LIGHT = colors.HexColor("#e7eefa")       # table header / note boxes
RULE = colors.HexColor("#c3d0e8")

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
    """Table of Paragraph cells; first row is the header when header=True."""
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


def shot(name, text, width=120):
    """A screenshot (384x272) and its caption."""
    return [Image(os.path.join(HERE, name), width=width * mm, height=width * 272 / 384 * mm),
            P(text, caption), Spacer(1, 4 * mm)]


def on_page(canv, doc):
    canv.saveState()
    canv.setFont("Helvetica", 8)
    canv.setFillColor(colors.HexColor("#777777"))
    if doc.page > 1:
        canv.drawString(20 * mm, 12 * mm, "SID500 user manual")
        canv.drawRightString(190 * mm, 12 * mm, str(doc.page))
    canv.restoreState()


K = key
CBM = "C=" + "&nbsp;"
W2 = [42 * mm, 128 * mm]                 # a key table: the key, what it does
W3 = [34 * mm, 40 * mm, 96 * mm]         # the parameters: name, values, what

# ------------------------------------------------------------------ content
story = []

# --- cover
story += [
    Spacer(1, 30 * mm),
    P("SID500", ParagraphStyle("t", parent=h1, fontSize=34, leading=40)),
    P("16-channel MIDI sequencer for the Commodore 64",
      ParagraphStyle("st", parent=body, fontSize=14, leading=18)),
    P("User manual", ParagraphStyle("st2", parent=body, fontSize=12,
                                    textColor=colors.HexColor("#666666"))),
    Spacer(1, 14 * mm),
    Image(os.path.join(HERE, "screen.png"), width=144 * mm, height=102 * mm),
    P("The song screen while a song plays: scene 7, bar 35, beat 3, 1:08 into the song.",
      caption),
    PageBreak(),
]

# --- 1. what it is
story += [
    P("1. What it is", h1),
    P("SID500 turns a C64 into a <b>16-channel MIDI sequencer</b>, named after the Roland "
      "MC-500. It makes no sound of its own (the SID only plays the metronome's click): "
      "it plays MIDI instruments, the <b>SidSynth</b> synths (SID303, SID808, SID101, "
      "each a C64 of its own) or any other, from songs of <b>scenes</b> and "
      "<b>patterns</b>."),
    P("Its <b>16 tracks</b> each play one MIDI channel, track 1 on channel 1 and so on, "
      "each shown in its channel's colour. A <b>pattern</b> is a loop of notes and "
      "controllers; a <b>scene</b> is a row of patterns, one for each track; the "
      "<b>song</b> is the scene rows played in order. Patterns are entered on a "
      "<b>step grid</b>, edited event by event in an <b>event list</b>, or "
      "<b>recorded</b> from a MIDI keyboard; scenes and single patterns can be "
      "<b>launched live</b> at the next bar."),
    P("<b>Timing comes first.</b> The notes and the MIDI clock come from the C64's own "
      "timer and are worked out ahead of time, so they go out on time however busy the "
      "editor is: each tick within 0.3 ms of exact, the clock steady (section 12). "
      "SID500 is the master clock for its synths, or follows another sequencer's MIDI "
      "clock and song position."),
    P("What you need", h2),
] + bullets([
    "A <b>PAL Commodore 64</b> (any model) and a <b>disk drive</b> (or an SD2IEC, "
    "Ultimate or similar) for the program and your songs.",
    "A <b>MIDI cartridge</b>: Datel/Siel/JMS (the default), Sequential, Passport or "
    "Namesoft, or a Kerberos set to one of them (section 9).",
    "<b>MIDI instruments</b> on its MIDI OUT: the SidSynth synths or any others. A MIDI "
    "keyboard on MIDI IN to record and play through, if you like.",
]) + [
    P("What is on the disk", h2),
    table([
        ["File", "What it is"],
        ["SID500", "The sequencer. Load it with " + K('LOAD"SID500",8') + " and " + K("RUN") + "."],
        ["SID500 DISK", "Its disk code, loaded when you save, load or list songs: keep it "
         "on every disk you keep songs on (copy it with any file copier)."],
        ["echo chamber, glass horizon, summer signal, moonlight",
         "Four demo songs (dub, a synth piece, pop, and Beethoven's Moonlight Sonata), "
         "the ones in the demo videos on the web page."],
    ], [48 * mm, 122 * mm]),
    PageBreak(),
]

# --- 2. first steps
story += [
    P("2. First steps", h1),
    P("Load SID500 with " + K('LOAD"SID500",8') + " and " + K("RUN") + ". It starts on the "
      "<b>parameter screen</b> (section 11): the tempo, the clock, the metronome, recording "
      "and the MIDI setup. Check <b>MIDI i/face</b> is your cartridge, then press "
      + K("F7") + " for the <b>song screen</b>, where everything else happens. "
      + K("F7") + " switches between the two."),
    P("To hear a demo song", h2),
] + bullets([
    "On the song screen, stopped, press " + K(CBM + "D") + ": the disk's songs are listed. "
    "Move to one with " + K("CRSR") + " and press " + K("RETURN") + " to load it.",
    "Press " + K("SHIFT+SPACE") + " to play it from the start, " + K("SPACE") + " to stop.",
    "The demos play on MIDI channels 1-8 and 10: SID808 on channel 10, SID303 on "
    "channel 2 and SID101s on the others (the video of each shows which). With fewer "
    "synths you hear the parts on the channels you have; mute the others with " + K("M") + ".",
]) + [
    P("To make a pattern", h2),
] + bullets([
    "On the song screen, move the cursor to an empty cell (" + K("--") + ") of track 1 "
    "and press " + K("RETURN") + ": a new 16-step pattern opens on the step grid.",
    "Play notes on the letter keys (" + K("Z S X D C") + "... like a piano, section 6): "
    "each goes on the cursor's step, and the cursor moves on. " + K("SPACE") + " leaves a "
    "rest.",
    "Press " + K("RUN/STOP") + " to hear it loop (again to stop), " + K("RETURN") + " to go "
    "back to the song screen. The cell now holds the pattern's number.",
    "Or record it: on the song screen press " + K(CBM + "R") + " on the cell and play your "
    "MIDI keyboard after the count-in (section 8).",
]) + [PageBreak()]

# --- 3. how a song is made
story += [
    P("3. Tracks, patterns, scenes and the song", h1),
    P("Tracks", h2),
    P("16 tracks, each on its own MIDI channel: track 1 plays channel 1, track 10 channel 10 "
      "(General MIDI drums: SID808's). Each track and everything it plays is shown in its "
      "channel's colour. A track can be <b>muted</b> or <b>soloed</b>."),
    P("Patterns", h2),
    P("A pattern is a loop of up to 128 sixteenth-note steps (16 when made), holding notes "
      "(with velocity and length), controllers, pitch bend and program changes. Patterns "
      "are numbered <b>1-128 for the whole song</b>: any track can play any pattern, and "
      "the same number on two tracks plays the same notes on both channels. Notes can sit "
      "exactly on a step or anywhere between (recorded ones keep their exact time): "
      "positions are bar.beat.tick, 48 ticks a quarter note."),
    P("Scenes", h2),
    P("64 scenes, the rows of the song screen. A scene holds a pattern number (or none) for "
      "each track, its length in bars (1-8), its time signature (1/4 to 16/4, or 1/8 to "
      "16/8) and its repeats (1-9). A pattern shorter than the scene loops; each track "
      "keeps its own place in its pattern."),
    P("The song", h2),
    P("With <b>Song on</b>, SID500 plays the scene rows in order, each for its bars times its "
      "repeats, to the first empty row, then from scene 1 again. With Song off, the "
      "playing scene loops until you launch another (section 5). A section heard twice is "
      "a copied row: patterns are shared by number, so editing one changes every row that "
      "plays it."),
    note_box("<b>Everything is heard at once.</b> A change to a pattern or a cell while the "
             "song plays is heard within a few tens of milliseconds, in place, without "
             "stopping: edit while you listen."),
    PageBreak(),
]

# --- 4. the song screen
story += [
    P("4. The song screen", h1),
] + shot("screen.png", "The song screen. Title: the playing scene, the tempo, the bar.beat "
         "and time, PLAY. Row 1: the cursor's scene (bars, signature, repeats). Row 2: the "
         "track numbers. Then a row per scene, a column per track.") + [
    P("The <b>title row</b> shows the scene playing, the tempo, the song's place as "
      "<b>bar.beat</b> and its time as <b>m:ss</b>, and STOP, PLAY or REC. <b>Row 1</b> shows "
      "the cursor's scene: its number, bars, signature and repeats (SONG reversed while "
      "Song is on). <b>Row 2</b> heads the tracks (M muted, S soloed, and 3, 8 or 1 for a "
      "channel set to a SidSynth synth). Below, 22 scene rows: each track's pattern "
      "number, " + K("--") + " for none. The playing scene is marked " + K(">") + ", a "
      "launch waiting " + K("+") + ". Eight tracks show at a time; the other eight are a "
      "key away."),
    table([
        ["Key", "On the song screen"],
        [K("CRSR"), "Move (right past track 8 goes to tracks 9-16; the scenes scroll)."],
        [K("&larr;"), "Show the other eight tracks."],
        [K("+") + " / " + K("-"), "The cell's pattern number up / down (1-128, and none)."],
        [K("DEL"), "Clear the cell."],
        [K("RETURN"), "Open the cell's pattern on the step grid; on an empty cell, make a "
         "new pattern (the first free number, 16 steps) and open it."],
        [K("M") + " / " + K("S"), "Mute / solo the cursor's track (several can be soloed)."],
        [K("SPACE"), "Stop, or continue from where it stopped (at the next 16th)."],
        [K("SHIFT+SPACE"), "Play from the start (with Song on from scene 1)."],
        [K("SHIFT+RETURN"), "Launch the cursor's scene at the next bar (stopped: the scene "
         "SPACE plays from)."],
        [K(CBM + "RETURN"), "Launch only the cursor's cell at the next bar: its track plays "
         "it until the next scene."],
        [K(CBM + "S"), "Song on / off."],
        [K(CBM + "B") + " / " + K(CBM + "N"), "The cursor's scene's bars down / up (1-8)."],
        [K(CBM + "T"), "The cursor's scene's time signature (n/4, n/8)."],
        [K(CBM + "X"), "The cursor's scene's repeats (1-9)."],
        [K(CBM + "R"), "Record on the cursor's track (section 8)."],
        [K(CBM + "U"), "Undo the last take; " + K("SHIFT") + ": redo."],
        [K(CBM + "K"), "Metronome on / off (on every screen)."],
        [K(CBM + "Y"), "Which SidSynth synth the cursor's track's channel is (none, SID303, "
         "SID808, SID101): names its drums and controllers on the grid and list."],
        [K(CBM + "W") + " / " + K(CBM + "L") + " / " + K(CBM + "D"),
         "Save / load a song / list the disk's songs (stopped; section 10)."],
        [K("F7"), "The parameter screen."],
    ], W2),
    PageBreak(),
]

# --- 5. playing live
story += [
    P("5. Playing: transport, launches and the metronome", h1),
    P("Start and stop", h2),
    P(K("SPACE") + " stops: every note sounding gets its note off at once, and the song waits "
      "at the next 16th. " + K("SPACE") + " again continues from there; " + K("SHIFT+SPACE")
      + " plays from the start. On the step grid " + K("RUN/STOP") + " does the same "
      "(" + K("SPACE") + " is the rest key there). As MIDI clock master SID500 sends Start, "
      "Stop, Continue and the song position to its synths (section 9)."),
    P("Launching scenes and patterns", h2),
    P(K("SHIFT+RETURN") + " launches the cursor's scene: it takes over at the <b>next bar</b> "
      "of the playing scene, each track from its pattern's beginning; a second launch before "
      "then replaces the first. " + K(CBM + "RETURN") + " launches one cell: its track plays "
      "that pattern from its start, looping, until the next scene. With Song on, a launch "
      "moves the song there. A launch waiting shows " + K("+") + " after its scene's "
      "number. Scenes can also be launched by MIDI (section 9)."),
    P("Mute, solo and live edits", h2),
    P(K("M") + " mutes the cursor's track, " + K("S") + " solos it; while any track is "
      "soloed, only soloed tracks sound. A cell changed with " + K("+") + " / " + K("-")
      + " on the playing scene, or a pattern edited on the grid, is heard at once, in place."),
    P("The metronome", h2),
    P(K(CBM + "K") + " turns it on and off; the <b>Metronome</b> parameter picks where it "
      "sounds: the SID's click, a MIDI note (on <b>Click chan</b>, notes <b>Beat note</b> "
      "and <b>Bar note</b>: channel 10, notes 37 and 75 at start), or both. The bar's first "
      "beat is brighter; it follows the playing scene's time signature."),
    P("The tempo and swing", h2),
    P("<b>Tempo</b> on the parameter screen is 40-240 BPM (the bar shows BPM minus 40; the "
      "song screen's title shows the BPM). <b>Swing</b> (0-15) delays every second 16th, for "
      "the whole song."),
    PageBreak(),
]

# --- 6. the step grid
story += [
    P("6. The step grid", h1),
] + shot("screen-grid.png", "The step grid: a row per step, three note columns (pitch, "
         "velocity, length); the help and the entry settings at the bottom.") + [
    P(K("RETURN") + " on a song cell opens its pattern here (" + K("RETURN") + " goes back). "
      "Each row is a step; each step shows up to three notes, each its pitch, velocity and "
      "length in steps (" + K("2+") + ": more than two steps, " + K("<1") + ": under one), "
      "and " + K("+") + " at the row's end for a fourth or more (all are in the event "
      "list). A note off its step's start is marked " + K("'") + ": its exact time is "
      "kept. The <b>entry settings</b> (octave, velocity, length) are on the bottom row."),
    P("The note keys play like a piano, two octaves on the letter keys:"),
    table([
        ["Keys", "Notes"],
        [K("Z S X D C V G B H N J M"), "C C# D D# E F F# G G# A A# B (the lower octave)"],
        [K("Q 2 W 3 E R 5 T 6 Y 7 U"), "C C# D D# E F F# G G# A A# B (an octave up)"],
        [K("F5") + " / " + K("F6"), "Octave up / down (shown on the bottom row)"],
    ], [60 * mm, 110 * mm]),
    Spacer(1, 3 * mm),
    table([
        ["Key", "On the step grid"],
        ["a note key", "Put the note in the cursor's column and move down a step. "
         + K("SHIFT") + " + note: add it to the step as a chord, the cursor stays."],
        [K("CRSR"), "Move (left / right across the three note columns)."],
        [K("SPACE"), "Take the column's note out and move down (a rest)."],
        [K("DEL"), "Take the column's note out."],
        [K("+") + " / " + K("-"), "The pattern's length up / down (1-128 steps; notes past "
         "a shortened end are kept, silent, and come back when it is lengthened)."],
        [K(CBM + "V") + ", " + K(CBM + "L"), "Pick velocity or length: then " + K(CBM + "+")
         + " / " + K(CBM + "-") + " change the cursor's note's (and the entry setting)."],
        [K(CBM + "T"), "Pick transpose: " + K(CBM + "+") + " / " + K(CBM + "-") + " move the "
         "whole pattern a semitone."],
        [K(CBM + "Q"), "Quantize the cursor's step: its notes off the step put on it."],
        [K(CBM + "C"), "Copy the pattern to a new number and open the copy (the cell gets it)."],
        [K("HOME") + " / " + K("CLR"), "Go to step 1 / clear the pattern (a big one asks "
         "for a second " + K("CLR") + ": that clear can't be undone)."],
        [K(CBM + "U"), "Undo the last edit; " + K("SHIFT") + ": redo (the open pattern's edits)."],
        [K("RUN/STOP"), "Play / stop (" + K("SHIFT") + ": from the start)."],
        [K("F3"), "The same pattern as an event list (section 7)."],
        [K("RETURN"), "Back to the song screen."],
    ], W2),
    Spacer(1, 3 * mm),
    P("<b>From MIDI:</b> notes played on a MIDI keyboard (on SID500's MIDI channel, Omni at "
      "start) are entered as the note keys are; keys held together go in as a chord, and the "
      "cursor moves on when all are released. The entry velocity and length are used."),
    PageBreak(),
]

# --- 7. the event list
story += [
    P("7. The event list", h1),
] + shot("screen-list.png", "The event list: every event of the pattern in order, its "
         "position (bar.beat.tick), the note or controller, its value, velocity and length.") + [
    P(K("F3") + " on the step grid shows the same pattern as a list of <b>every event</b>: "
      "notes, controllers, pitch bend and program changes, in order, 16 a page, with the "
      "cursor on the same event. Positions and lengths are bar.beat.tick (48 ticks a quarter, "
      "24 an eighth in an n/8 scene). With a channel set to a SidSynth synth " + K(CBM + "Y")
      + ", SID808's notes show as its drums and each synth's controllers by name."),
    table([
        ["Key", "In the event list"],
        [K("CRSR") + " up / down", "Move between events (the pages follow)."],
        [K("CRSR") + " left / right", "Move between the fields: position, note or value, "
         "velocity, length."],
        [K("+") + " / " + K("-"), "Change the field by one: a tick, a semitone, 1. With "
         + K("SHIFT") + " by more: a 16th, an octave, 10. A position moved takes the event "
         "with it."],
        [K("DEL"), "Delete the event."],
        [K("INST") + " (" + K("SHIFT+DEL") + ")", "Put in a copy of the event after it."],
        [K(CBM + "U"), "Undo; " + K("SHIFT") + ": redo (as on the grid)."],
        [K("F3"), "Back to the step grid."],
        [K("RETURN"), "Back to the song screen."],
    ], W2),
    PageBreak(),
]

# --- 8. recording
story += [
    P("8. Recording", h1),
    P("Play a MIDI keyboard into SID500's MIDI IN. With <b>Thru</b> on (at start), what you "
      "play goes straight out on the channel of the cursor's track on the song screen (or "
      "the open pattern's track on the grid), so you hear it on that track's synth. Turn "
      "Thru off for a keyboard with its own sound."),
    P("To record", h2),
] + bullets([
    "On the song screen, put the cursor on the track's cell and press " + K(CBM + "R") + ". "
    "An empty cell gets a new 16-step pattern first.",
    "<b>Stopped:</b> the <b>count-in</b> clicks (1 bar at start; the Count-in parameter: "
    "off, 1 or 2 bars), then the song plays from the start, recording. " + K(CBM + "R")
    + " or " + K("SPACE") + " during the count-in ends it.",
    "<b>Playing:</b> the take starts at once.",
    "What you play is merged into the pattern at each pass of its loop, so you hear it "
    "on the next pass. " + K(CBM + "R") + " again, or a stop, ends the take.",
    K(CBM + "U") + " on the song screen undoes the whole take (" + K("SHIFT") + ": redo), "
    "until the pattern is edited again.",
]) + [
    P("The recording parameters", h2),
] + bullets([
    "<b>Record:</b> <b>Overdub</b> adds to what is there; <b>Replace</b> drops the old notes "
    "and controllers as the take passes over them, then overdubs, so one take can build a "
    "loop.",
    "<b>Rec quantize:</b> Off (the exact time kept), 16th, 8th or 16th triplet, applied as the "
    "take is merged; the lengths are kept. " + K(CBM + "Q") + " on the grid fixes a step "
    "later.",
    "Velocities are the keys'; controllers and bend are recorded too, aftertouch is not.",
]) + [
    note_box("<b>As MIDI clock slave</b> (Clock: MIDI), " + K(CBM + "R") + " while stopped "
             "arms the take (REC in the title): it starts with the master's first clock. "
             "There is no count-in: the master starts the song."),
    PageBreak(),
]

# --- 9. MIDI
story += [
    P("9. MIDI", h1),
    P("Channels", h2),
    P("Track n plays MIDI channel n. <b>MIDI channel</b> (the parameter) is SID500's own "
      "channel for what it receives: step entry and scene launches (Omni: every channel, "
      "but scene launches need a channel of their own)."),
    P("Clock, start and stop", h2),
] + bullets([
    "<b>Clock: Internal</b> (at start): SID500 is the master. While playing it sends MIDI "
    "clock (24 a quarter note), and Start, Stop and Continue with the song position, so its "
    "synths follow it and their arpeggios and sequencers stay in step (no clock while "
    "stopped).",
    "<b>Clock: MIDI</b>: SID500 follows another sequencer's clock, Start, Stop, Continue "
    "and song position, and passes the clock on through its MIDI OUT. " + K("SPACE")
    + " does nothing then: the master starts and stops.",
]) + [
    P("Launching scenes by MIDI", h2),
    P("On SID500's MIDI channel (not in Omni), <b>controller 85</b> values 0-63 and "
      "<b>program changes</b> 0-63 launch scenes 1-64 at the next bar, as " + K("SHIFT+RETURN")
      + " does; they are neither passed through nor recorded. <b>Song select</b> turns Song "
      "on. (Controller 85 is the SidSynth family's pattern-select controller.)"),
    P("The cartridge", h2),
    P("<b>MIDI i/face</b> picks the cartridge: Datel/Siel/JMS (at start), Sequential, "
      "Passport or Namesoft (its interrupts come as NMIs: a little more clock jitter, about "
      "1 ms). The setting is saved with the song."),
    note_box("<b>Kerberos:</b> its MIDI is switched on by the program started from its menu "
             "or slot, with the emulation set in the Kerberos PC tool: set SID500's slot to "
             "the same interface as SID500's MIDI i/face (Datel at start). Started from BASIC "
             "after the Kerberos menu, its MIDI stays off."),
    P("Thru", h2),
    P("With <b>Thru</b> on, notes, controllers, bend and program changes from MIDI IN (any "
      "channel) go out on the cursor's track's channel, playing or stopped, in about 3 ms "
      "stopped and about 9 ms on average while a song plays at 120 BPM."),
    PageBreak(),
]

# --- 10. disk
story += [
    P("10. Saving and loading songs", h1),
    P("On the song screen, stopped:"),
    table([
        ["Key", "What it does"],
        [K(CBM + "W"), "Save the song: type a name (up to 13 letters, digits, space, + - .; "
         + K("DEL") + " deletes, " + K("RETURN") + " saves, " + K("RUN/STOP") + " cancels). "
         "A song of the same name is replaced."],
        [K(CBM + "L"), "Load a song by its name."],
        [K(CBM + "D"), "List the disk's songs: " + K("CRSR") + " down / up to pick one, "
         + K("RETURN") + " loads it, " + K("RUN/STOP") + " leaves."],
    ], W2),
    Spacer(1, 3 * mm),
    P("The title row then shows the drive's message (" + K("00, OK") + ", "
      + K("62, FILE NOT FOUND") + " and so on). A song file holds every pattern, every scene "
      "and every parameter but <b>Disk drive</b> (8-16: the drive SID500 was loaded from, at "
      "start), so a load brings back the whole setup. Song files end in " + K(".s5")
      + " on the disk (added for you, not shown)."),
    note_box("The disk code is the file <b>SID500 DISK</b>, loaded when you press "
             + K(CBM + "W") + ", " + K(CBM + "L") + " or " + K(CBM + "D") + ": it must be "
             "on the disk in the drive. Copy it onto every disk you keep songs on."),
    PageBreak(),
]

# --- 11. parameters
story += [
    P("11. The parameter screen", h1),
] + shot("screen-params.png", "The parameter screen, SID500's settings at start.", 110) + [
    P(K("F1") + " / " + K("F2") + " pick a parameter, " + K("F3") + " / " + K("F4")
      + " change it; " + K("F7") + " goes to the song screen. As on every SidSynth "
      "program, a parameter can be given a MIDI controller (learn) or a paddle. All are "
      "saved with the song but Disk drive."),
    table([
        ["Parameter", "Values (at start)", "What it does"],
        ["Tempo", "40-240 BPM (120)", "The song's tempo; the bar shows BPM minus 40."],
        ["Swing", "0-15 (0)", "Delays every second 16th."],
        ["Clock", "Internal, MIDI", "Master, or follow MIDI clock (section 9)."],
        ["Metronome", "Off, SID, MIDI, SID+MIDI", "Where the click sounds (" + K(CBM + "K")
         + " on / off)."],
        ["Click chan", "1-16 (10)", "The click's MIDI channel."],
        ["Beat note", "0-127 (37)", "The click's note on a beat."],
        ["Bar note", "0-127 (75)", "The click's note on a bar's first beat."],
        ["Thru", "Off, On (On)", "MIDI IN to the cursor's track's channel."],
        ["Record", "Overdub, Replace", "How a take goes into the pattern."],
        ["Rec quantize", "Off, 16th, 8th, 16th trip", "Applied as a take is merged."],
        ["Count-in", "Off, 1 bar, 2 bars", "Before recording from a stop."],
        ["MIDI channel", "Omni, 1-16 (Omni)", "SID500's own channel for what it receives."],
        ["MIDI i/face", "Off, Sequential, Passport, Datel, Namesoft (Datel)", "The cartridge."],
        ["Paddles", "Port 1, Port 2, Off (Off)", "Paddles on parameters, as learned."],
        ["Disk drive", "8-16", "The drive for songs (the one SID500 came from)."],
    ], W3),
    PageBreak(),
]

# --- 12. timing and limits
story += [
    P("12. Timing and limits", h1),
    P("Timing", h2),
    P("Measured in the VICE emulator with its MIDI interface at the real wire's pace (as a real "
      "6850 sends, checked on a Kerberos cartridge), not counting MIDI's own 1 ms for a note "
      "on's three bytes:"),
    table([
        ["What", "Measured"],
        ["Notes and clock", "From the C64's timer, worked out about 42 ms ahead: ticks within "
         "0.3 ms of exact, the clock 0.4-0.5 ms after its tick, its gaps steady within 0.5 ms."],
        ["Under load", "At most about 2.5 ms added to any byte with half the MIDI wire busy; "
         "nothing is ever dropped."],
        ["As clock slave", "The master's clock passed on within about 0.6 ms."],
        ["MIDI thru", "About 3 ms stopped; playing, about 9 ms on average at 120 BPM."],
        ["The SidSynth synths", "From a note on to its sound: SID303 about 2.4 ms on average, "
         "SID101 2.3 ms, SID808 7 ms (its drums settle 5 ms so soft hits start clean)."],
    ], [40 * mm, 130 * mm]),
    P("Limits", h2),
] + bullets([
    "16 tracks, 64 scenes, 128 patterns of up to 128 steps; a scene 1-8 bars, repeated 1-9 "
    "times; time signatures n/4 and n/8 (n 1-16); 40-240 BPM.",
    "The patterns share a pool of 664 blocks: about 5,000 notes in all. The step grid and the "
    "event list edit a pattern of up to 256 events.",
    "A disk holds about 30 songs of the demos' size (16-33 blocks each), with SID500 DISK "
    "on it.",
]) + [
    P("13. About", h1),
    P("SID500 is part of <b>SidSynth</b>, a family of Commodore 64 instruments built on one "
      "shared core, with SID303 (acid bass), SID808 (drum machine) and SID101 (lead synth). "
      "© 2026 Jarkko Lehti. Free software under the GNU GPL version 3 or later; the source "
      "is on the web page. The Moonlight Sonata demo's notes come from the Mutopia Project's "
      "edition (Berners 1908, ed. Winterberger; CC BY-SA 2.5)."),
]


def main():
    doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm,
                            topMargin=18 * mm, bottomMargin=20 * mm,
                            title="SID500 user manual", author="Jarkko Lehti")
    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
    print(OUT, "written")


if __name__ == "__main__":
    main()
