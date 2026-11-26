# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the SID101 user manual: docs/SID101-manual.pdf.

Run from anywhere: python docs/manual.py [out.pdf]   (needs reportlab, and
docs/screen.png and docs/screen-steps.png: VICE screenshots of the parameter
screen and the step screen, 384x272 with the borders; tools/screenshots.sh
takes them). SID303's docs/manual.py is the model.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tables  # noqa: E402  (the factory presets)

from reportlab import rl_config
from reportlab.lib import colors

# reproducible output: no creation date or random document ID in the PDF, so
# rebuilding an unchanged manual gives an identical file
rl_config.invariant = 1
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.graphics.shapes import Drawing, Rect, String
from reportlab.platypus import (Image, PageBreak, Paragraph,
                                SimpleDocTemplate, Spacer, Table, TableStyle)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "SID101-manual.pdf")

# ---------------------------------------------------------------- styles
INK = colors.HexColor("#1d1d1f")
ACCENT = colors.HexColor("#2a5fc4")      # the icon's blue for headings
LIGHT = colors.HexColor("#e7eefa")       # table header / note boxes
RULE = colors.HexColor("#c3d0e8")

ss = getSampleStyleSheet()
body = ParagraphStyle("body", parent=ss["Normal"], fontName="Helvetica",
                      fontSize=10, leading=14, textColor=INK, spaceAfter=6)
small = ParagraphStyle("small", parent=body, fontSize=8.5, leading=11,
                       spaceAfter=0)
cell = ParagraphStyle("cell", parent=body, fontSize=9, leading=12,
                      spaceAfter=0)
cellb = ParagraphStyle("cellb", parent=cell, fontName="Helvetica-Bold")
h1 = ParagraphStyle("h1", parent=body, fontName="Helvetica-Bold", fontSize=17,
                    leading=21, textColor=ACCENT, spaceBefore=4, spaceAfter=8)
h2 = ParagraphStyle("h2", parent=body, fontName="Helvetica-Bold", fontSize=12,
                    leading=16, textColor=INK, spaceBefore=8, spaceAfter=4)
bullet = ParagraphStyle("bullet", parent=body, leftIndent=12, bulletIndent=2,
                        spaceAfter=3)
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


# ------------------------------------------------- piano keyboard diagram
def piano(title, keys):
    """Draw a piano section labelled with C64 keys.

    keys: list of (C64 key, note name) in semitone order starting at C.
    """
    white_w, white_h, black_w, black_h = 22, 62, 14, 38
    whites = [k for k in keys if "#" not in k[1]]
    width = len(whites) * white_w + 2
    d = Drawing(width, white_h + 18)
    d.add(String(0, white_h + 6, title, fontName="Helvetica-Bold", fontSize=9,
                 fillColor=INK))
    x = 1
    white_x = {}
    for i, (k, n) in enumerate(keys):
        if "#" in n:
            continue
        d.add(Rect(x, 0, white_w, white_h, fillColor=colors.white,
                   strokeColor=INK, strokeWidth=0.7))
        d.add(String(x + white_w / 2, 16, k, fontName="Courier-Bold",
                     fontSize=10, textAnchor="middle", fillColor=ACCENT))
        d.add(String(x + white_w / 2, 4, n, fontName="Helvetica", fontSize=6.5,
                     textAnchor="middle", fillColor=INK))
        white_x[i] = x
        x += white_w
    for i, (k, n) in enumerate(keys):
        if "#" not in n:
            continue
        bx = white_x[i - 1] + white_w - black_w / 2
        d.add(Rect(bx, white_h - black_h, black_w, black_h, fillColor=INK,
                   strokeColor=INK, strokeWidth=0.7))
        d.add(String(bx + black_w / 2, white_h - black_h + 6, k,
                     fontName="Courier-Bold", fontSize=9, textAnchor="middle",
                     fillColor=colors.white))
    return d


LOADCMD = 'LOAD"SID101",8'
NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
LOWER = "Z S X D C V G B H N J M , L . ; /".split()
UPPER = "Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P @".split()


def labelled(row):
    return [(k, NOTES[i % 12]) for i, k in enumerate(row)]


# ---------------------------------------------------------- page furniture
def on_page(canv, doc):
    canv.saveState()
    canv.setFont("Helvetica", 8)
    canv.setFillColor(colors.HexColor("#777777"))
    if doc.page > 1:
        canv.drawString(20 * mm, 12 * mm, "SID101 user manual")
        canv.drawRightString(190 * mm, 12 * mm, str(doc.page))
    canv.restoreState()


# ------------------------------------------------------------------ content
story = []

# --- cover
story += [
    Spacer(1, 30 * mm),
    P("SID101", ParagraphStyle("t", parent=h1, fontSize=34, leading=40)),
    P("SH-101 style lead synth for the Commodore 64 and the 8580 SID",
      ParagraphStyle("st", parent=body, fontSize=14, leading=18)),
    P("User manual", ParagraphStyle("st2", parent=body, fontSize=12,
                                    textColor=colors.HexColor("#666666"))),
    Spacer(1, 14 * mm),
    Image(os.path.join(HERE, "screen.png"), width=144 * mm, height=102 * mm),
    P("The SID101 screen at start, with the default sound.", caption),
    PageBreak(),
]

# --- 1. intro
story += [
    P("1. What it is", h1),
    P("SID101 turns a C64 into a monophonic lead and bass synth in the "
      "spirit of the Roland SH-101. One note plays on all three of the SID's "
      "voices at once: a <b>saw</b>, a <b>pulse</b> with pulse width "
      "modulation and a <b>sub-oscillator</b> one or two octaves down, each "
      "with its own level, through one resonant filter with an <b>ADSR "
      "envelope</b>. An <b>LFO</b> with four shapes moves the pitch, the "
      "pulse width and the cutoff, <b>glide</b> slides between notes, and a "
      "<b>Sync mode</b> turns the pulse voice into a hard-synced saw for the "
      "tearing sync lead. The <b>C64 mode</b> plays the C64's own 80s lead, "
      "in the style of Rob Hubbard and Martin Galway: a pulse lead with its "
      "own slow pulse-width sweep, vibrato that comes in after a delay, an "
      "echo, a click at each note's start, and chords played as fast "
      "arpeggios on one voice (section 11)."),
    P("<b>32 presets</b> hold whole sounds with their names: 31 factory sounds "
      "to start from, recalled with two keys or MIDI program change, stored "
      "over with your own, and saved to disk as a bank (section 7)."),
    P("It also has an <b>arpeggiator</b> (up, down, up and down, random over "
      "one to three octaves) and the SidSynth <b>step sequencer</b>: 64 "
      "patterns of up to 16 steps with accent, slide and tie, songs, undo, "
      "MIDI clock in and out and saving to disk (section 10). Play it from a "
      "MIDI keyboard, the C64 keyboard, or both, and turn the filter with "
      "paddles."),
    P("SID101 is the third synth of <b>SidSynth</b>, after SID303 (acid bass) "
      "and SID808 (drum machine), built on the same shared core: whoever "
      "knows one of them will find the screen, the keys, MIDI learn and the "
      "step sequencer familiar."),
    P("What you need", h2),
    *bullets([
        "A PAL Commodore 64 with an <b>8580 SID</b> (C64C, or a 6581 machine "
        "fitted with an 8580). The filter settings are made for the 8580; a "
        "6581 filter sounds quite different.",
        "Optional: a MIDI interface cartridge: Sequential, Passport, Datel/Siel "
        "or Namesoft compatible (a Kerberos cartridge works in Datel mode). "
        "The Maplin interface is not supported.",
        "Optional: a pair of paddles for hands-on cutoff and resonance, or "
        "any parameter you assign them to.",
        "Or the VICE emulator with the 8580 SID model selected.",
    ]),
    P("Files", h2),
    table([
        ["File", "What"],
        ["sid101.prg / sid101.d64", "The synth. Use this one to play. The disk "
         "holds only the synth, with room for 59 songs or 98 preset banks."],
        ["sid101-demos.d64", "The demo programs below on a disk of their own."],
        ["sid101-demo.prg", "Demo A, the voice: a bass, a squelch, a lead "
         "with PWM and vibrato, a filter sweep over the sub."],
        ["sid101-sync.prg", "Demo B, Sync mode: a sync riff, a hand sweep, a "
         "sync bass and a sync lead."],
        ["sid101-mod.prg", "Demo C, modulation: the LFO shapes, LFO delay, "
         "the mod wheel and accent."],
        ["sid101-seq.prg", "Demo D, the step sequencer playing a song of the "
         "four patterns SID101 starts with."],
        ["sid101-arp.prg", "Demo E, the arpeggiator in every mode."],
        ["sid101-presets.prg", "Demo G, the 31 factory presets one after another, "
         "chosen by MIDI program change."],
        ["sid101-c64.prg", "Demo H, the C64 mode: the lead, its echo, the "
         "clicks, the PWM sweep."],
        ["sid101-chords.prg", "Demo H2, the C64 mode's chords: shapes, chords "
         "held on the keys, octaves, and with the arpeggiator."],
        ["demos/*.wav", "VICE recordings of the demos (section 11)."],
    ], [48 * mm, 122 * mm]),
    P("The demo programs play by themselves, with no MIDI needed: they feed "
      "the synth recorded MIDI and loop. The keys work while they play.",
      small),
    Spacer(1, 4 * mm),
    P("License", h2),
    P("Copyright (C) 2026 Jarkko Lehti. SID101 is free software: you "
      "can redistribute it and/or modify it under the terms of the GNU General "
      "Public License as published by the Free Software Foundation, either "
      "version 3 of the License, or (at your option) any later version. It is "
      "distributed WITHOUT ANY WARRANTY; see the LICENSE file that comes with "
      "the source for the full text."),
    PageBreak(),

    P("2. Getting started", h1),
    P("On a real C64", h2),
    P(f"Insert the disk (or copy the PRG to your SD/cartridge device) and "
      f"type {key(LOADCMD)} then {key('RUN')}. The synth "
      f"screen appears at once and the synth is ready to play."),
    P("In VICE", h2),
    P(f"Autostart <i>sid101.prg</i> or <i>sid101.d64</i>. Choose the 8580 "
      f"SID first: <i>Settings &gt; Audio &gt; SID</i>, or start VICE with "
      f"{key('-sidenginemodel 257')}. For MIDI in VICE, enable a MIDI "
      f"cartridge of type Datel/Siel in the cartridge/IO settings (or set "
      f"MIDI i/face to match the type you pick) and connect your MIDI input "
      f"device."),
    P("With a Kerberos cartridge", h2),
    P("Start SID101 through the Kerberos, not from BASIC: the menu items "
      "<b>R</b> and <b>H</b> switch the cartridge off, and then no MIDI "
      "arrives. Use <i>Send PRG and start</i> in the Kerberos App, or flash "
      "<i>sid101.prg</i> to a slot and start it with <b>S</b> in the menu. "
      "Set the slot's MIDI emulation to Datel, which is also SID101's "
      "default. The Kerberos menu item <b>M</b> tests the MIDI input."),
    P("First sounds", h2),
    *bullets([
        f"Press {key('Z')}, {key('X')}, {key('C')}... on the C64 keyboard: "
        "you hear the saw and the sub through the filter.",
        "Hold one note and press another: the new note glides in without "
        "starting again (legato). Let it go and the first note comes back.",
        f"Press {key('F1')} / {key('F2')} to move the cursor to Cutoff, then "
        f"{key('F3')} / {key('F4')} to open or close the filter while you play.",
        f"Hold {key('C=')} and press {key('F3')}: the next preset. Its number "
        "and name show at the top of the screen.",
        f"Press {key('F7')} and then {key('RUN/STOP')}: the step sequencer "
        "plays its first pattern, a bass line. RUN/STOP again stops it.",
    ]),
    note_box("<b>Leaving the program:</b> the synth takes over the whole machine "
             "(BASIC and KERNAL are switched off), so RUN/STOP-RESTORE does not "
             "exit. Reset the C64 to leave. Save your patterns, song and sound "
             "first (section 10) and the presets as a bank (section 7); MIDI and "
             "paddle assignments are not saved."),
    PageBreak(),
]

# --- 3. the screen
story += [
    P("3. The screen", h1),
    Image(os.path.join(HERE, "screen.png"), width=120 * mm, height=85 * mm),
    P("The parameter screen: the Sound page", caption),
    Spacer(1, 3 * mm),
    *bullets([
        "<b>Parameter list.</b> One row per parameter. The <b>&gt;</b> marks "
        "the selected parameter, the one F3/F4 change. Numeric values are "
        "shown as a bar and a number; the others as a name (Envelope, Sync...).",
        "<b>Two pages.</b> <b>Sound</b> has the voice, Cutoff to Click. "
        "<b>Play</b> has the LFO, accent, glide, the arpeggiator, Tune and "
        "Volume, and the setup: MIDI channel, MIDI i/face, Paddles, Clock, "
        f"MIDI out and Disk drive. The page shown is the one the selected "
        f"parameter is on: {key('F1')} past Click goes on to the Play page, "
        f"{key('F2')} from Cutoff goes straight to Disk drive. A grey line under "
        "each page's last parameter says what is on the other page.",
        "<b>Title row.</b> The program name and its build number (<b>b15</b>: "
        "build 15; please mention it when you report a problem), then the "
        "preset: its number, a <b>*</b> once the sound has been changed since "
        "it was recalled or stored, and its name (section 7). Then the page's "
        "name.",
        "<b>P and CC columns</b> (right). P shows X or Y for the paddle that "
        "sets a parameter, CC the MIDI controller number. During learn the CC "
        f"column shows {key('???')}.",
        f"<b>Status line.</b> {key('Oct')}: the keyboard octave. {key('Note')} "
        f"and {key('Vel')}: the last note played and its velocity. "
        f"{key('Glide')} appears while the pitch glides. {key('MIDI')} turns "
        "reverse while MIDI data comes in. In learn mode this line shows the "
        "learn prompt instead.",
        "<b>Help lines</b> at the bottom: a short summary of the keys. "
        "<b>C=+</b> goes with the keys after it: C= + F3/F4 preset, C= + "
        "RETURN store, C= + W/L/M the bank (save, load, send over MIDI).",
        f"{key('F7')} switches to the <b>step screen</b>, the step "
        "sequencer's (section 10), and back. SID101 starts on the parameter "
        "screen.",
    ]),

    PageBreak(),
    P("4. Playing from the C64 keyboard", h1),
    P("The two rows of letter keys work like a piano keyboard (the tracker "
      "layout): the bottom letter row plays the lower octave, the top row the "
      "octave above, with sharps on the row above each."),
    piano("Lower row", labelled(LOWER)),
    Spacer(1, 3 * mm),
    piano("Upper row", labelled(UPPER)),
    Spacer(1, 3 * mm),
    table([
        ["Key", "Action"],
        [f"{key('F5')} / {key('F6')}", "Keyboard octave up / down (shown as Oct)"],
        [f"{key('SHIFT')} + note", "The note at full velocity (127) instead of 80: "
         "louder and brighter when Accent is above 0. SHIFT LOCK plays every "
         "note so."],
        ["Hold a note, play another", "Legato: the new note doesn't start the "
         "envelope again, and glides there with Glide mode On or Auto. Let it "
         "go and the voice goes back to the note still held."],
        [f"{key('F8')} or {key('RUN/STOP')}", "All notes off"],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    P("Notes are last-note priority: the newest held note sounds. Up to eight "
      "held notes are remembered. Changing octave while a key is held never "
      "leaves a stuck note. With the arpeggiator on, the held keys are its "
      "chord (section 9)."),
    note_box("<b>Tip:</b> the C64 keyboard matrix can ghost when three or more "
             "keys are held, so a key may seem pressed when it isn't. For "
             "chords on the arpeggiator a MIDI keyboard is the better choice."),
    P("5. Paddles", h1),
    P("Plug paddles into the port selected in <b>Paddles</b> (Port 1 by "
      "default). At start paddle X sets <b>Cutoff</b> and paddle Y sets "
      "<b>Resonance</b>. Either paddle can be given another parameter: select "
      f"it, press {key('RETURN')} and turn the paddle (see learn in section 8). "
      "The P column shows which paddle controls what. <b>Mod wheel</b> is a "
      "parameter too, so a paddle can be the SH-101's modulation lever."),
    *bullets([
        "<b>Soft takeover:</b> a paddle takes control only once you move it. "
        "Until then, keys and MIDI knobs set the value freely, and an empty "
        "port is ignored.",
        "Turning clockwise raises the value.",
        "<b>Don't press the paddle fire buttons:</b> they share lines with the "
        "keyboard and act as key presses.",
    ]),
    PageBreak(),
]

# --- 6. editing and the parameters
story += [
    P("6. The parameters", h1),
    table([
        ["Key", "Action"],
        [f"{key('F1')} / {key('F2')} or CRSR down / up", "Next / previous "
         "parameter, across both pages."],
        [f"{key('F3')} / {key('F4')}, {key('+')} / {key('-')}, CRSR right / left",
         "Increase / decrease the value. Hold to repeat."],
        [f"{key('F7')}", "The step screen (section 10)"],
        [f"{key('RETURN')}", "Learn a MIDI knob or paddle for the selected parameter (section 8)"],
        [f"{key('DEL')}", "Remove the selected parameter's MIDI controller and paddle"],
    ], [62 * mm, 108 * mm]),
    Spacer(1, 2 * mm),
    P("SHIFT turns F1, F3, F5 and F7 into F2, F4, F6 and F8. With SHIFT LOCK on, "
      "F1 therefore acts as F2."),

    P("The Sound page", h2),
    table([
        ["Parameter", "Range", "CC", "What it does"],
        ["Cutoff", "0-255", "74", "Filter cutoff on a log scale, about 40 Hz to "
         "12 kHz, so each step is the same musical distance. Paddle X."],
        ["Resonance", "0-15", "71", "Filter resonance. Paddle Y."],
        ["Env mod", "0-255", "20", "How far the envelope opens the filter above "
         "Cutoff, up to about 4 octaves."],
        ["Attack", "0-15", "73", "The envelope's rise: 0 at once, 1-15 from "
         "5 ms to 3 s. It shapes the <b>filter</b> only: the loudness always "
         "starts at once (see the note below)."],
        ["Decay", "0-15", "75", "The envelope's fall to Sustain, 4 ms to 4 s."],
        ["Sustain", "0-15", "21", "The level held while the key is down."],
        ["Release", "0-15", "72", "The fall after the key is let go, 4 ms to 4 s."],
        ["Amp", "Envelope, Gate", "22", "Envelope: the loudness follows the "
         "envelope's decay, sustain and release. Gate: full while the key is "
         "down, off when it is let go, as the SH-101's Gate setting."],
        ["Voice mode", "101, Sync, C64", "31", "101: saw, pulse and sub, as the "
         "SH-101. Sync: the pulse voice becomes a saw hard-synced to the saw "
         "voice, for the sync lead. C64: a pulse lead, its echo and the sub "
         "(section 11)."],
        ["Saw", "0-15", "23", "The saw's level. In Sync mode it is the sync "
         "master's level; at 0 it still drives the sync. <b>In C64 mode: the "
         "echo's level</b> (0: no echo)."],
        ["Pulse / sync", "0-15", "24", "The pulse's level; in Sync mode the "
         "synced saw's. <b>In C64 mode: the lead's level.</b>"],
        ["Sub", "0-15", "25", "The sub-oscillator's level."],
        ["Sub type", "3 types", "26", "1 oct down: a square an octave down. "
         "2 oct down: two octaves down. 25% 2 down: a narrow pulse two octaves "
         "down, as the SH-101's third sub setting."],
        ["Pulse width", "0-15", "27", "50% (a square) at 0, to about 9%."],
        ["PWM", "0-15", "28", "How far the LFO moves the pulse width. In C64 "
         "mode: the speed of the lead's own pulse-width sweep instead, 0.1 to "
         "4 Hz (0: none), so vibrato and the sweep can play together."],
        ["Sync pitch", "0-255", "78", "Sync mode: the synced saw's pitch above "
         "the note, up to 4 octaves. This is the sync sweep's knob."],
        ["Sync env", "0-255", "79", "Sync mode: how far the envelope sweeps "
         "the synced pitch up on each note, up to 4 more octaves."],
        ["Chord", "11 settings", "17", "C64 mode: Off (a mono lead); Keys (the "
         "keys held play as a fast arpeggio); or a shape: Major, Minor, 7th, "
         "Minor 7th, Major 7th, Sus 4, 5th, Octave, Diminished, which one key "
         "plays (section 11)."],
        ["Chord speed", "1-8 frames", "18", "C64 mode: how long each of the "
         "chord's notes sounds, in frames of 1/50 s."],
        ["Click", "Off, 9 kinds", "19", "C64 mode: a click at each fresh "
         "note's start: Noise, Saw or Square for 1, 2 or 3 frames."],
    ], [24 * mm, 24 * mm, 10 * mm, 112 * mm]),
    Spacer(1, 2 * mm),
    note_box("<b>Levels and the attack.</b> The SID can lower a voice's level "
             "during a note but not raise it. So the loudness always starts at "
             "once (Attack shapes the filter only), and a level raised while a "
             "note sounds (Saw, Pulse / sync, Sub) is heard from the next "
             "fresh note on; lowering one is heard at once."),
    PageBreak(),
    P("The Play page", h2),
    table([
        ["Parameter", "Range", "CC", "What it does"],
        ["LFO rate", "0-15", "76", "0.1 Hz to 30 Hz."],
        ["LFO shape", "4 shapes", "14", "Triangle; Square (a trill on the "
         "pitch); Random (a new value each cycle: sample and hold); Noise (a "
         "new value every tick, the rate does nothing)."],
        ["LFO delay", "0-15", "15", "0: none. 1-15: the LFO fades in over "
         "0.1 to 4 s after each fresh note (legato notes keep the fade going)."],
        ["Vibrato", "0-15", "77", "LFO to pitch, up to about a semitone each way."],
        ["LFO cutoff", "0-15", "29", "LFO to cutoff, up to about 2 octaves "
         "each way."],
        ["Mod wheel", "0-255", "1", "More vibrato on top of Vibrato, up to the "
         "full depth: the MIDI mod wheel (CC 1), or a paddle."],
        ["Accent", "0-15", "16", "What velocity does. 0: nothing, every note "
         "alike (the SH-101 has no velocity). Higher: soft notes quieter, hard "
         "ones (velocity 64 and up) with more env mod. At 0 the sequencer's "
         "accents sound like its other steps."],
        ["Glide", "0-15", "5", "Glide time: 0 at once, 1-15 from 10 ms to 1.5 s."],
        ["Glide mode", "Off, On, Auto", "30", "Off: no glide. On: every note "
         "glides from the last. Auto: only legato notes glide (and the "
         "sequencer's slides), as the SH-101's Auto."],
        ["Arpeggio", "5 modes", "80", "Off, Up, Down, Up &amp; down, Random "
         "(section 9)."],
        ["Arp range", "1-3 octaves", "81", "How many octaves the arpeggio "
         "covers."],
        ["Arp rate", "1/8, 1/16, 1/32", "82", "The arpeggio's step at the "
         "sequencer's tempo or MIDI clock."],
        ["Tune", "-16..+15", "", "Fine tune, up to half a semitone either way."],
        ["Volume", "0-15", "7", "Master volume."],
        ["MIDI channel", "Omni, 1-16", "", "Which channel the synth listens to."],
        ["MIDI i/face", "5 choices", "", "Off, Sequential, Passport, "
         "Datel (default), Namesoft."],
        ["Paddles", "Port 1/2, Off", "", "Which control port the paddles are in."],
        ["Clock", "Internal, MIDI", "", "The step sequencer's and the "
         "arpeggiator's clock: their own tempo, or MIDI clock (sections 9, 10)."],
        ["MIDI out", "Off, On", "", "Send the step sequencer's notes, and with "
         "the internal clock its start, clock and stop."],
        ["Disk drive", "8-16", "", "Where patterns, songs and sounds are saved "
         "and loaded. At start: the drive SID101 was loaded from."],
    ], [24 * mm, 24 * mm, 10 * mm, 112 * mm]),
    Spacer(1, 2 * mm),
    P("The CC column lists the MIDI controllers assigned when the program "
      "starts. They and the paddles can be changed with learn.", small),
    PageBreak(),
]

# --- 7. presets
FACTORY_KIND = {"bass": "Bass", "lead": "Lead", "arp": "Arpeggio"}
story += [
    P("7. Presets", h1),
    P("SID101 keeps <b>32 presets</b>, each a whole sound with a name of up "
      "to 12 characters. At start, preset 1 is the sound SID101 starts with, "
      "2 to 31 are the factory sounds (the list is in section 11) and 32 "
      "is a copy of the start sound named <i>Init</i>; store your own over "
      "any of them. The title row shows the preset: <b>01 Saw + sub</b>, and "
      "<b>01*Saw + sub</b> once you change the sound."),
    P("Recalling a preset", h2),
    table([
        ["Key or message", "Action"],
        [f"{key('C=')} + {key('F3')}", "The next preset (after 32: 1)"],
        [f"{key('C=')} + {key('F4')}", "The previous preset (SHIFT + F3 is F4)"],
        ["MIDI program change", "Programs 0-31 recall presets 1-32 (keyboards "
         "that number programs from 1 show them as 1-32); higher ones do "
         "nothing. On the synth's MIDI channel, or any in Omni."],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        "A recall sets every sound parameter <b>except Mod wheel, Tune and "
        "Volume</b>: the wheel stays where your hand put it, and the tuning "
        "and level stay as they are for the rest of your setup. (They are "
        "stored with the preset, but not recalled.)",
        "The arpeggiator's three parameters are part of a preset: an "
        "arpeggio preset turns it on, the others turn it off.",
        "Recalled while a note sounds: a level the new sound raises is heard "
        "from the next note (the SID can't raise a held voice's level).",
        "The keys work on the parameter screen. On the step screen, use MIDI "
        "program change, or F7 back.",
    ]),
    P("Storing a sound", h2),
    P(f"{key('C=')} + {key('RETURN')} opens the store prompt on the status "
      f"line: <b>STORE TO 04: Acid 101</b> and, at the right, "
      f"<b>F3/F4 slot</b>. It starts on the current preset and its name."),
    table([
        ["Key", "Action"],
        [f"{key('F3')} / {key('F4')}", "The slot to store into, 1-32"],
        ["Letters, digits, SPACE, + - .", "Type the name (up to 12); with "
         "SHIFT, capitals"],
        [f"{key('DEL')}", "Delete the last character"],
        [f"{key('RETURN')}", "Store: the sound and the name go into the slot, "
         "replacing what was there; it becomes the current preset"],
        [f"{key('RUN/STOP')}", "Cancel"],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    P("While the prompt is up the keys type into it; a note still held from "
      "before ends normally when you let it go."),
    P("Saving and loading the bank", h2),
    P(f"The presets live in memory: a reset brings back the factory set. "
      f"{key('C=')} + {key('W')} saves all 32 as one file, a <b>bank</b>, and "
      f"{key('C=')} + {key('L')} loads one. The status line asks for the "
      f"file name (<b>SAVE BANK 8: bank</b>): it is typed as on the step "
      f"screen (letters, digits, space and + - ., DEL deletes, RETURN goes, "
      f"RUN/STOP cancels). A bank has a name of its own, at first "
      f"<i>bank</i>, apart from the song file's, so saving one can't "
      f"replace your song by mistake. The drive is the Play page's "
      f"<b>Disk drive</b>."),
    *bullets([
        "A bank file holds the 32 presets, values and names (6 blocks). "
        "Loading one replaces all 32; the sound playing stays as it is (the "
        "title shows <b>*</b>) until you recall a preset.",
        "The song file (section 10) holds the patterns, the song and the "
        "sound playing, not the presets; the bank holds only the presets. "
        "Each refuses the other: <b>NOT A SID101 BANK</b>, <b>NOT A SID101 "
        "FILE</b>, and nothing changes.",
        "While the disk works the sequencer stops and nothing plays. The "
        "drive's message (<b>00, OK,00,00</b>, <b>62, FILE NOT FOUND,00,00</b>, "
        "<b>NO DRIVE 9</b> ...) stays on the status line until the next key.",
    ]),
    PageBreak(),
]

# --- 8. MIDI
story += [
    P("8. MIDI", h1),
    P("Setting up", h2),
    *bullets([
        "Plug the MIDI interface into the expansion port with the C64 off.",
        "Select your interface type in <b>MIDI i/face</b> (Datel is the "
        "default). A Kerberos cartridge works in Datel mode; see section 2 for "
        "how to start SID101 with it.",
        "Set <b>MIDI channel</b> to your keyboard's channel, or leave it on "
        "Omni to hear every channel but 10: in Omni, notes on channel 10 (the "
        "General MIDI drum channel, and SID808's) are ignored, so a drum "
        "machine on the same MIDI line doesn't play the lead. Controllers on "
        "channel 10 still count.",
        "The <b>MIDI</b> label on the status line turns reverse while data arrives.",
    ]),
    P("What the synth responds to", h2),
    table([
        ["Message", "Effect"],
        ["Note on / off", "Plays notes; velocity as Accent sets (section 6)."],
        ["Overlapping notes (legato)", "The new note doesn't start the envelope "
         "again; it glides there with Glide mode On or Auto."],
        ["Pitch bend", "Plus or minus 2 semitones"],
        ["Mod wheel (CC 1)", "More vibrato (the Mod wheel parameter)"],
        ["Program change", "Programs 0-31 recall presets 1-32 (section 7)"],
        ["Control change", "Sets the parameter assigned to that controller "
         "(CC column on screen)"],
        ["CC 120, CC 123", "All notes off"],
        ["Controller 85", "Picks the pattern: values 0-63 are patterns 1-64. It plays "
         "from the next pattern start, as F1/F2 choose it (stopped: from play), and "
         "song mode goes off. Only on the synth's own channel, not in Omni."],
        ["Song select", "Song mode on (the synth holds one song; the number doesn't "
         "matter)."],
        ["Song position", "With Clock on MIDI and the sequencer stopped: where the "
         "next Continue plays from: the song entry, its repeat and step, or the "
         "pattern's step. Start still plays from the beginning."],
        ["SysEx dumps", "A request sends the song file or the preset bank; a "
         "dump loads one (see Backing up over MIDI, below)."],
        ["Clock, start, continue, stop", "Drive the step sequencer and the "
         "arpeggiator when Clock is MIDI; otherwise ignored, even in the middle "
         "of other messages"],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    P("Running status is supported. Controller values 0-127 are scaled to each "
      "parameter's range."),
    P("Backing up over MIDI", h2),
    P("The song file (patterns, song, tempo, swing, sound) and the preset bank "
      "go to a PC and back as SysEx, each byte for byte as its disk file, so "
      "a file fetched over MIDI can also go on a disk, and a file from a disk "
      "can be sent. The PC tool is <b>sysex.py</b>, a download on SID101's web "
      "page (and in the source, core/sysex.py; Python with mido and python-rtmidi):"),
    table([
        ["Command", "Does"],
        ["python sysex.py get sid101", "Fetches the song file into sid101-song.prg "
         "(-o picks the name)"],
        ["python sysex.py get sid101 --bank", "Fetches the preset bank"],
        ["python sysex.py send FILE", "Sends a song file or a bank back: which "
         "one, and for which synth, comes from the file"],
        ["--port NAME, --channel N", "The MIDI port (part of its name), and "
         "SID101's channel when several synths share the line"],
    ], [60 * mm, 110 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        f"{key('C=')} + {key('M')} sends a dump without a request: the song "
        "from the step screen, the bank from the parameter screen (any SysEx "
        "recorder takes it).",
        "Sending takes about a second, longer while a heavy sound plays (it "
        "only uses the time the sound leaves). With MIDI out on, a playing "
        "sequencer stops first: its notes would cut the dump.",
        "A dump that comes in stops the sequencer and silences the synth at "
        "once, loads like a disk file when it is whole, and shows <b>SYSEX: "
        "SONG LOADED</b> or <b>SYSEX: BANK LOADED</b>. Nothing changes if it "
        "isn't (section 12).",
        "SID101 answers on its MIDI channel, or to any channel in Omni.",
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
    P("MIDI and paddle learn", h2),
    P("Any knob or slider on your MIDI controller, and either paddle, can be "
      "assigned to any parameter from Cutoff to Volume:"),
    table([
        ["1", "Select the parameter with F1/F2."],
        ["2", f"Press {key('RETURN')}. The status line shows "
              f"{key('Learn: knob/paddle')} and the CC column shows {key('???')}."],
        ["3", "Move a MIDI knob or turn a paddle. It now controls that "
              "parameter, and learn mode ends."],
    ], [10 * mm, 160 * mm], header=False),
    Spacer(1, 2 * mm),
    *bullets([
        "Press RETURN again to cancel learn mode.",
        "Each parameter has one knob. Learning a new knob frees the old one, "
        "and a knob already used by another parameter moves to the new one.",
        "Each parameter has at most one paddle; a learnt paddle leaves its "
        "old parameter. A parameter can have both a knob and a paddle.",
        f"{key('DEL')} removes the selected parameter's controller and paddle.",
        "Controllers 0-119 can be learnt (120-127 are channel mode messages).",
        "MIDI channel, MIDI i/face, Paddles, Clock, MIDI out and Disk drive "
        "can't be learnt, so a knob or paddle can never switch the MIDI "
        "interface off.",
        "Assignments are not saved: a reset restores the default CCs and "
        "paddles.",
    ]),
    PageBreak(),
]

# --- 8. the arpeggiator
story += [
    P("9. The arpeggiator", h1),
    P("Set <b>Arpeggio</b> to a mode and hold a chord: the arpeggiator plays "
      "the held notes one at a time, each a fresh note with its own envelope, "
      "its gate open for half a step. Let go of the last key and it stops at "
      "once."),
    table([
        ["Mode", "How it plays"],
        ["Up", "The held notes from the lowest up, then the same an octave up "
         "for each octave of <b>Arp range</b>, then from the bottom again."],
        ["Down", "The same, from the top down."],
        ["Up &amp; down", "Up and then down again; the top and the bottom notes "
         "play once each at the turn."],
        ["Random", "Any of the same notes, at random."],
    ], [30 * mm, 140 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        "<b>Chords:</b> up to eight held notes, from MIDI and the C64 keyboard "
        "together, sorted by pitch. Adding or letting go of a key changes the "
        "chord without losing the place in the pattern, so chord changes keep "
        "time.",
        "<b>Rate:</b> <b>Arp rate</b> 1/16 is a step of the sequencer at its "
        "tempo (F3/F4 on the step screen); 1/8 is half as fast, 1/32 twice. "
        "The first note plays at once.",
        "<b>On MIDI clock</b> (Clock: MIDI), a step is 12, 6 or 3 clocks, "
        "counted from MIDI start, and the first key waits for the next step. "
        "It follows the clock also with the sequencer stopped.",
        "<b>Velocity:</b> the arpeggio's notes take the newest key's velocity "
        "(as Accent sets).",
        "<b>Turning it off</b> with keys held: the newest key goes on sounding, "
        "held. Turning it on with keys held takes them as the chord.",
        "<b>With the sequencer:</b> the sequencer's notes go past the "
        "arpeggiator to the voice, so a pattern and an arpeggio can play "
        "together, on one voice.",
    ]),
    P("Not in this version: Hold (the SH-101's latch); the arpeggio's notes "
      "are not sent to MIDI out; with the sequencer playing, the arpeggio "
      "starts from the first key rather than on the sequencer's step.",
      small),
    PageBreak(),
]

# --- 9. the step sequencer
story += [
    P("10. The step sequencer", h1),
    P(f"SID101 has the SidSynth step sequencer, the one SID303 has: patterns "
      f"of up to 16 steps, each a note with accent and slide, or a tie or a "
      f"rest. Press {key('F7')} on the parameter screen to open the step "
      f"screen, and {key('F7')} again to go back. The parameters, MIDI and "
      f"the paddles work as before while a pattern plays."),
    Image(os.path.join(HERE, "screen-steps.png"), width=120 * mm, height=85 * mm),
    P("The step screen, playing pattern 1", caption),
    P("The step screen", h2),
    *bullets([
        "<b>Title row:</b> the pattern shown (1-64), the tempo in BPM "
        "(<b>EXT</b> on MIDI clock), swing, the pattern's length, and "
        "<b>PLAY nn</b> with the pattern playing, or <b>STOP</b>.",
        "<b>Step rows:</b> one per step: the step number, the note "
        "(<b>---</b> a rest, <b>===</b> a tie), <b>A</b> for accent and "
        "<b>S</b> for slide. On the right, a lane marks each note at its pitch, "
        "so you can see the line's shape; the <b>C1 C2 C3</b> above it mark "
        "the octaves. <b>&gt;</b> marks the step playing, the reversed row is "
        "the cursor, and steps past the length are dim.",
        "<b>Song row:</b> the song (below), or a message after undo or a disk "
        "operation, until the next key.",
        "<b>Status line and help</b> as on the parameter screen.",
    ]),
    P("How a pattern plays", h2),
    *bullets([
        "<b>Note:</b> the note starts and its gate closes after half a step; "
        "the envelope's release follows.",
        "<b>Accent:</b> the note plays at velocity 127, the others at 100. "
        "What that does is up to <b>Accent</b> on the Play page: at 0, "
        "nothing; turn it up to hear the accents louder and brighter.",
        "<b>Slide:</b> the note holds on into the next step's note, which "
        "plays legato: it glides in (Glide mode Auto or On) without starting "
        "the envelope again.",
        "<b>Tie:</b> the note before goes on through this step. A tie after a "
        "rest stays silent.",
        "<b>Rest:</b> silence.",
    ]),
    P("Patterns 1 to 4 hold four lines when SID101 starts: a bass line with "
      "slides and accents, a lead with ties, an octave riff and a 12-step "
      "bounce. The other 60 are empty."),
    P("Entering a pattern", h2),
    P(f"The note keys enter notes, as in a tracker: put the cursor on a step "
      f"and press a note key. The step gets that note and the cursor moves "
      f"down. {key('SHIFT')} with the note accents it. While stopped you also "
      f"hear the note. {key('F5')} / {key('F6')} change the octave of the note "
      f"keys. The other commands are on the keys the notes leave free, and on "
      f"letter keys with {key('C=')} held."),
    table([
        ["Key", "Action"],
        ["Note keys", "The cursor's step becomes that note, cursor down "
         "(SHIFT: accented). Its slide stays as it was."],
        [f"{key('A')} / {key('F')}", "Accent / slide on or off"],
        [f"{key('=')}", "Tie, cursor down"],
        [f"{key('SPACE')} / {key('DEL')}", "Rest, cursor down / rest, cursor stays"],
        ["CRSR down / up", "Cursor (hold to repeat)"],
        ["CRSR right / left", "The cursor's note a semitone up / down"],
        [f"{key('+')} / {key('-')}", "Pattern length 1-16"],
        [f"{key('HOME')} / {key('CLR')}", "Cursor to step 1 / clear the pattern"],
        [f"{key('F1')} / {key('F2')}", "Next / previous pattern. While playing, "
         "it plays from the next pattern start."],
        [f"{key('F3')} / {key('F4')}", "Tempo +/- 1 BPM (60-240)"],
        [f"{key('C=')} + {key('F3')} / {key('F4')}", "Swing: the off-beat steps "
         "later, 0-15"],
        [f"{key('F5')} / {key('F6')}", "Octave of the note keys"],
        [f"{key('C=')} + {key('C')}", "Copy the pattern to the next one"],
        [f"{key('C=')} + {key('U')} (SHIFT: redo)", "Undo the last edit / redo "
         "(16 steps)"],
        [f"{key('RUN/STOP')}", "Play / stop"],
        [f"{key('F7')} / {key('F8')}", "Parameter screen / all notes off"],
    ], [52 * mm, 118 * mm]),
    Spacer(1, 2 * mm),
    P("Undo covers steps, lengths, clears, copies and the song; tempo, swing "
      "and the octave are settings and are not undone."),
    P("Songs", h2),
    P(f"A song chains patterns: up to 64 entries, each a pattern played 1-9 "
      f"times and transposed up or down by up to 12 semitones. The song row "
      f"shows <b>SONG</b>, the song cursor and the song's length "
      f"(<b>02/03</b>), then entries such as <b>01x2+05</b>: pattern 1, "
      f"twice, 5 semitones up. In song mode ({key('C=')} + {key('S')}, "
      f"<b>SONG</b> reversed) RUN/STOP plays the song from its first entry, "
      f"in a loop, and the step screen follows the pattern playing."),
    table([
        ["Key", "Action"],
        [f"{key('C=')} + {key('S')}", "Song mode on / off"],
        [f"{key('C=')} + {key(',')} / {key('.')}", "Song cursor back / on; on an "
         "entry the step screen shows its pattern"],
        [f"{key('C=')} + {key('P')}", "Put the pattern shown into the song at the "
         "cursor (after the last entry: a new one)"],
        [f"{key('C=')} + {key(';')} (SHIFT: back)", "The entry's repeats, 1-9"],
        [f"{key('C=')} + {key('+')} / {key('-')}", "The entry's transpose, -12..+12"],
        [f"{key('&lt;-')} (left arrow)", "Delete the entry at the cursor"],
    ], [52 * mm, 118 * mm]),
    P("Saving and loading", h2),
    P(f"{key('C=')} + {key('W')} saves and {key('C=')} + {key('L')} loads. The "
      f"song row asks for a file name (the last one used, at first "
      f"<i>song</i>): letters, digits, space and + - . type, DEL deletes, "
      f"RETURN goes and RUN/STOP cancels. A file holds the 64 patterns, the "
      f"song, tempo, swing and the sound: every parameter from Cutoff to "
      f"Volume, the arpeggiator's too (it counts as a change: the title "
      f"shows <b>*</b>); not the presets, which go in a bank (section 7). "
      f"The setup (MIDI, paddles, clock, "
      f"drive) is not in it. The drive is the Play page's <b>Disk drive</b>, "
      f"at start the drive SID101 was loaded from. Saving replaces a file of "
      f"the same name."),
    P("While a file is saved or loaded, the pattern stops and nothing plays. "
      "Afterwards the song row shows the drive's message, such as "
      "<b>00, OK,00,00</b> or <b>62, FILE NOT FOUND,00,00</b>, or "
      "<b>NO DRIVE 9</b>, <b>NOT A SID101 FILE</b> or <b>FILE ENDED EARLY</b>."),
    P("Playing with other machines", h2),
    *bullets([
        "<b>Following a MIDI clock:</b> set <b>Clock</b> to MIDI. The "
        "sequencer then waits for the master: Start plays from the first step "
        "(the song's first entry in song mode), each 6 clocks (a 16th) is a "
        "step, Stop stops and Continue goes on where it stopped. The title "
        "shows <b>BPM EXT</b>. The arpeggiator follows the same clock.",
        "<b>MIDI out:</b> set <b>MIDI out</b> to On to send the pattern's notes "
        "on the MIDI channel (Omni: channel 1): accent as velocity 127, a "
        "slide as the next note starting before the last one ends. With the "
        "internal clock it also sends start, clock and stop, so another "
        "machine can follow SID101.",
        "<b>With SID808:</b> connect SID808's MIDI out to SID101's MIDI in, "
        "set SID808's MIDI out On and SID101's Clock to MIDI, and press "
        "RUN/STOP on SID808. SID808 sends its drums on channel 10, which "
        "SID101 ignores in Omni, so they don't play the lead.",
    ]),
    PageBreak(),
]

# --- 10. sound guide
story += [
    P("11. Making sounds", h1),
    P("How the voice works", h2),
    P("Every note plays on all three SID voices: the saw on voice 1, the "
      "pulse on voice 2 and the sub on voice 3. <b>Saw</b>, <b>Pulse</b> and "
      "<b>Sub</b> are the SH-101's mixer. All three go through the 8580's "
      "low-pass filter. The <b>envelope</b> (Attack, Decay, Sustain, Release) "
      "opens the filter by <b>Env mod</b> above <b>Cutoff</b> and, with Amp "
      "on Envelope, shapes the loudness too. Short Decay with low Sustain and "
      "some Resonance is the plucked bass; Sustain high with Amp on Gate is "
      "the organ-like lead."),
    P("<b>Sync mode</b> makes voice 2 a saw hard-synced to voice 1: it starts "
      "its wave again at every cycle of voice 1, so its own pitch (<b>Sync "
      "pitch</b>, above the note) changes its tone rather than its note. "
      "Sweeping Sync pitch, by hand or with <b>Sync env</b> on every note, is "
      "the tearing sync lead. The sub stays under it."),
    P("<b>C64 mode</b> is the C64's own lead, as Rob Hubbard and Martin "
      "Galway made it in the 80s. Voice 1 is a <b>pulse lead</b> at the "
      "<b>Pulse</b> level; <b>PWM</b> sweeps its width slowly up and down on "
      "its own, starting again at each fresh note, while the LFO is free for "
      "vibrato: set <b>LFO delay</b> and <b>Vibrato</b> for the vibrato that "
      "comes in after a moment. Voice 2 is its <b>echo</b>: the lead again "
      "128 ms later, at the <b>Saw</b> level. Voice 3 is the sub. "
      "<b>Click</b> starts each fresh note with a frame or three of noise, "
      "saw or square: the attack of the old game tunes."),
    P("<b>Chords</b> are played as fast arpeggios on the one voice, the C64 "
      "way. With <b>Chord</b> on a shape (Major, Minor...), one key plays "
      "that chord; with <b>Keys</b> or a shape, holding several keys plays "
      "the keys held. <b>Chord speed</b> sets how long each note sounds: 1 "
      "frame (50 notes a second) is the classic buzzing chord. The chord "
      "starts on the note just played, goes on into the release, and changes "
      "no envelope: it moves only the pitch. The sequencer's and the "
      "arpeggiator's notes play the shape too; MIDI out sends the notes "
      "themselves, not the chord. Chord Off is a plain mono lead, where "
      "overlapping notes are legato and glide."),
    P("The <b>LFO</b> moves the pitch (Vibrato and the mod wheel), the pulse "
      "width (PWM) and the cutoff (LFO cutoff) together, at one rate and "
      "shape. <b>LFO delay</b> lets each fresh note start straight and the "
      "modulation fade in."),
    P("The factory presets", h2),
    P("The factory sounds are good places to start: recall one, change it, "
      "store it in a slot of its own. They come from the sounds of the demos."),
    table([["No.", "Name", "Kind", "No.", "Name", "Kind"]] + [
        [str(i + 1), tables.FACTORY[i][0].replace("&", "&amp;"),
         FACTORY_KIND[tables.FACTORY[i][2]]] +
        ([str(j + 1), tables.FACTORY[j][0].replace("&", "&amp;"),
          FACTORY_KIND[tables.FACTORY[j][2]]] if j < len(tables.FACTORY) else ["", "", ""])
        for i, j in ((i, i + 16) for i in range(16))],
        [12 * mm, 38 * mm, 25 * mm, 12 * mm, 38 * mm, 25 * mm]),
    Spacer(1, 2 * mm),
    P("Demo recordings", h2),
    P("The <i>demos</i> folder holds VICE (reSID 8580) recordings of the "
      "demo programs:"),
    table([
        ["File", "What it plays"],
        ["a-voice.wav", "A bass with glides, a squelch with the cutoff opening, "
         "a PWM lead with vibrato, a filter sweep over the sub two octaves down."],
        ["b-sync.wav", "A sync riff, Sync pitch swept by hand, a sync bass and "
         "a sync lead."],
        ["c-modulation.wav", "Sample and hold, a square-wave trill, LFO delay, "
         "the mod wheel, accent off and on, and everything at once."],
        ["d-sequencer.wav", "A song of the four start patterns, each with its "
         "own sound."],
        ["e-arpeggiator.wav", "Up, Up &amp; down, Down at 1/32 on the sync "
         "lead, Random with glide, and the arpeggio turned off with a key "
         "held."],
        ["g-presets.wav", "The 31 factory presets in order, chosen by program "
         "change: a bar of a bass or lead line each, two bars of a chord for "
         "the arpeggios."],
        ["h-c64-voice.wav", "C64 mode: the lead alone, with its echo, three "
         "clicks on a staccato riff, and all of it with the sub."],
        ["h2-c64-chords.wav", "C64 mode's chords: shapes on single keys, chords "
         "held on the keys, octave arpeggios on a melody, and with the "
         "arpeggiator."],
    ], [34 * mm, 136 * mm]),
    PageBreak(),

    P("12. Troubleshooting and limits", h1),
    table([
        ["Problem", "What to check"],
        ["No sound from MIDI", "MIDI i/face matches your cartridge; MIDI "
         "channel is Omni or your channel (not 10 in Omni); the MIDI label "
         "lights up (reverse) when you play. Kerberos: start SID101 through "
         "the Kerberos menu or App, not from BASIC (section 2)."],
        ["No sound at all", "Saw, Pulse and Sub all at 0, Volume 0, or Cutoff "
         "closed with Env mod 0. In C64 mode the lead is Pulse / sync: at 0 "
         "only the sub sounds."],
        ["C64 mode: overlapping notes make a chord", "Chord is on Keys or a "
         "shape: holding several keys plays them as a chord. Set Chord to Off "
         "for legato and glide."],
        ["Sound is thin or the filter behaves oddly", "The machine has a 6581 "
         "SID. The synth is made for the 8580. In VICE, select the 8580 model."],
        ["A level change is not heard", "A raised level is heard from the next "
         "note (section 6)."],
        ["Velocity does nothing", "Accent is 0: turn it up."],
        ["A preset doesn't change the volume or tuning", "By design: a recall "
         "keeps Volume, Tune and Mod wheel (section 7)."],
        ["My presets are gone", "They live in memory: save a bank (C= + W) "
         "before you reset, and load it (C= + L) after."],
        ["Pitch slightly sharp, envelopes fast", "NTSC machine. The timing is "
         "for PAL: on NTSC pitch is about 2/3 of a semitone sharp and envelopes "
         "about 4% fast."],
        ["Wrong or extra notes from the keyboard", "Keyboard ghosting with three "
         "or more keys held, or a paddle fire button pressed."],
        ["Paddle seems to do nothing", "Move it: soft takeover waits for movement. "
         "Check the Paddles setting matches the port, and the P column for "
         "what it controls."],
        ["The pattern or arpeggio doesn't play", "Clock is on MIDI: they wait "
         "for the master's clock. Set Clock to Internal to play on their own."],
        ["Disk: NO DRIVE 8", "No drive answers at the Disk drive number. Turn "
         "it on, or set Disk drive to your drive's number."],
        ["Disk: NOT A SID101 FILE", "The file isn't a SID101 song file (a bank "
         "loaded on the step screen?). Nothing was changed."],
        ["Disk: NOT A SID101 BANK", "The file isn't a preset bank (a song file "
         "loaded with C= + L on the parameter screen?). Nothing was changed."],
        ["SYSEX: BAD DATA", "A dump came in damaged (a byte lost or changed on "
         "the way). Nothing was changed: send it again, slower if the PC "
         "software can."],
        ["SYSEX: NOT A SID101 FILE / BANK", "The dump was meant for SID101 but "
         "isn't one of its files. Nothing was changed."],
        ["Songs and banks from older builds", "They load: songs and banks saved "
         "before the C64 mode (build 21 and earlier) get Chord, Chord speed "
         "and Click off. Files saved now don't load in those older builds."],
        ["Can't leave the program", "RESTORE does nothing. Reset the C64."],
        ["Reporting a bug", "Include the build number from the title row "
         "and what you did."],
    ], [55 * mm, 115 * mm]),
    PageBreak(),
]

# --- quick reference
story += [
    P("Quick reference", h1),
    table([
        ["Key", "Action"],
        ["F1 / F2, CRSR down / up", "Select parameter"],
        ["F3 / F4, + / -, CRSR right / left", "Change value (hold to repeat)"],
        ["F5 / F6", "Octave up / down"],
        ["F7", "Step screen"],
        ["F8, RUN/STOP", "All notes off"],
        ["RETURN", "Learn knob or paddle on / off"],
        ["C= + F3 / F4", "Next / previous preset"],
        ["C= + RETURN", "Store the sound into a preset"],
        ["C= + W / L", "Save / load the preset bank"],
        ["C= + M", "Send the preset bank over MIDI (SysEx)"],
        ["DEL", "Remove MIDI controller and paddle"],
        ["Z S X D C V G B H N J M , L . ; /", "Notes, lower octave (C to E)"],
        ["Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P @", "Notes, upper octave (C to F)"],
        ["SHIFT + note", "Velocity 127 (SHIFT LOCK: every note)"],
        ["Hold note + play another", "Legato (glide with Glide mode On or Auto)"],
        ["Paddle X / Y", "Cutoff / Resonance (or as learnt)"],
    ], [75 * mm, 95 * mm]),
    Spacer(1, 6 * mm),
    table([
        ["CC", "Parameter", "CC", "Parameter", "CC", "Parameter"],
        ["74", "Cutoff", "25", "Sub", "15", "LFO delay"],
        ["71", "Resonance", "26", "Sub type", "77", "Vibrato"],
        ["20", "Env mod", "27", "Pulse width", "29", "LFO cutoff"],
        ["73", "Attack", "28", "PWM", "1", "Mod wheel"],
        ["75", "Decay", "78", "Sync pitch", "16", "Accent"],
        ["21", "Sustain", "79", "Sync env", "5", "Glide"],
        ["72", "Release", "76", "LFO rate", "30", "Glide mode"],
        ["22", "Amp", "14", "LFO shape", "80", "Arpeggio"],
        ["31", "Voice mode", "17", "Chord", "81", "Arp range"],
        ["23", "Saw", "18", "Chord speed", "82", "Arp rate"],
        ["24", "Pulse / sync", "19", "Click", "7", "Volume"],
    ], [14 * mm, 32 * mm, 14 * mm, 32 * mm, 14 * mm, 32 * mm]),
    Spacer(1, 4 * mm),
    P("CC 120, 123: all notes off. Pitch bend: plus or minus 2 semitones. "
      "Overlapping notes: legato. Program change 0-31: presets 1-32."),
    PageBreak(),
    P("Quick reference: the step screen", h1),
    table([
        ["Key", "Action"],
        ["Note keys (SHIFT: accent)", "Enter a note at the cursor, cursor down"],
        ["A / F", "Accent / slide on or off"],
        ["=", "Tie"],
        ["SPACE / DEL", "Rest (cursor down / stays)"],
        ["CRSR down / up", "Cursor"],
        ["CRSR right / left", "Note a semitone up / down"],
        ["+ / -", "Pattern length"],
        ["HOME / CLR", "Cursor to step 1 / clear the pattern"],
        ["F1 / F2", "Next / previous pattern"],
        ["F3 / F4", "Tempo"],
        ["C= + F3 / F4", "Swing"],
        ["F5 / F6", "Octave of the note keys"],
        ["RUN/STOP", "Play / stop"],
        ["F7 / F8", "Parameter screen / all notes off"],
        ["C= + C", "Copy the pattern to the next one"],
        ["C= + U (SHIFT: redo)", "Undo / redo"],
        ["C= + S", "Song mode on / off"],
        ["C= + , / .", "Song cursor"],
        ["C= + P", "Put the pattern into the song"],
        ["C= + ; (SHIFT: back)", "The entry's repeats"],
        ["C= + + / -", "The entry's transpose"],
        ["left arrow", "Delete the song entry"],
        ["C= + W / L", "Save / load"],
        ["C= + M", "Send the song over MIDI (SysEx)"],
    ], [75 * mm, 95 * mm]),
]

doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=20 * mm,
                        rightMargin=20 * mm, topMargin=18 * mm,
                        bottomMargin=20 * mm, title="SID101 user manual",
                        author="Jarkko Lehti", subject="How to use SID101")
doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
print("wrote", OUT)
