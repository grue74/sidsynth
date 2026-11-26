# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the SID303 user manual: docs/SID303-manual.pdf.

Run from anywhere: python docs/manual.py [out.pdf]   (needs reportlab, and
docs/screen.png and docs/screen-steps.png: VICE screenshots of the parameter
screen and the step screen, 384x272 with the borders).
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
from reportlab.graphics.shapes import Drawing, Rect, String
from reportlab.platypus import (Image, KeepTogether, PageBreak, Paragraph,
                                SimpleDocTemplate, Spacer, Table, TableStyle)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "SID303-manual.pdf")

# ---------------------------------------------------------------- styles
INK = colors.HexColor("#1d1d1f")
ACCENT = colors.HexColor("#5b4fc4")      # C64-ish violet for headings
LIGHT = colors.HexColor("#ecebf8")       # table header / note boxes
RULE = colors.HexColor("#c8c6e0")

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


LOADCMD = 'LOAD"SID303",8'
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
        canv.drawString(20 * mm, 12 * mm, "SID303 user manual")
        canv.drawRightString(190 * mm, 12 * mm, str(doc.page))
    canv.restoreState()


# ------------------------------------------------------------------ content
story = []

# --- cover
story += [
    Spacer(1, 30 * mm),
    P("SID303", ParagraphStyle("t", parent=h1, fontSize=34, leading=40)),
    P("TB-303 style acid bass for the Commodore 64 and the 8580 SID",
      ParagraphStyle("st", parent=body, fontSize=14, leading=18)),
    P("User manual", ParagraphStyle("st2", parent=body, fontSize=12,
                                    textColor=colors.HexColor("#666666"))),
    Spacer(1, 14 * mm),
    Image(os.path.join(HERE, "screen.png"), width=144 * mm, height=102 * mm),
    P("The SID303 screen at start, with the default sound.", caption),
    PageBreak(),
]

# --- 1. intro
story += [
    P("1. What it is", h1),
    P("SID303 turns a C64 into a monophonic acid bass synth in the style "
      "of the Roland TB-303. Play it from a MIDI keyboard or sequencer, or from "
      "the C64 keyboard. It reproduces the parts that make a 303 sound like a "
      "303: the resonant low-pass filter with its decaying envelope, "
      "<b>accent</b>, <b>slide</b>, and an amplifier that opens instantly and "
      "fades while a note is held."),
    P("It also has its own <b>step sequencer</b>: 64 patterns of up to 16 "
      "steps with accent, slide and tie, songs that chain them with repeats "
      "and transposes, undo, MIDI clock in and out to play along with other "
      "machines, and saving to disk (section 8)."),
    P("What you need", h2),
    *bullets([
        "A PAL Commodore 64 with an <b>8580 SID</b> (C64C, or a 6581 machine "
        "fitted with an 8580). The filter settings are made "
        "for the 8580; a 6581 filter sounds quite different.",
        "Optional: a MIDI interface cartridge: Sequential, Passport, Datel/Siel "
        "or Namesoft compatible (a Kerberos cartridge works; tested on real "
        "hardware). The Maplin interface is not supported.",
        "Optional: a pair of paddles for hands-on cutoff and resonance, or "
        "any parameter you assign them to.",
        "Or the VICE emulator with the 8580 SID model selected.",
    ]),
    P("Files", h2),
    table([
        ["File", "What"],
        ["sid303.prg / sid303.d64", "The synth. Use this one to play."],
        ["sid303-test.prg", "Plays a built-in acid line by itself (no MIDI "
         "needed). Good for checking the sound and trying parameters."],
        ["sid303-sweep.prg", "The acid line at high resonance with the "
         "cutoff swept open and closed twice over eight bars."],
        ["demos/presets/*.wav", "One recording for each of the starting-point "
         "sounds (see section 9)."],
    ], [55 * mm, 115 * mm]),
    Spacer(1, 4 * mm),
    P("License", h2),
    P("Copyright (C) 2026 Jarkko Lehti. SID303 is free software: you "
      "can redistribute it and/or modify it under the terms of the GNU General "
      "Public License as published by the Free Software Foundation, either "
      "version 3 of the License, or (at your option) any later version. It is "
      "distributed WITHOUT ANY WARRANTY; see the LICENSE file that comes with "
      "the source for the full text."),

    P("2. Getting started", h1),
    P("On a real C64", h2),
    P(f"Insert the disk (or copy the PRG to your SD/cartridge device) and "
      f"type {key(LOADCMD)} then {key('RUN')}. The synth "
      f"screen appears at once and the synth is ready to play."),
    P("In VICE", h2),
    P(f"Autostart <i>sid303.prg</i> or <i>sid303.d64</i>. Choose the 8580 "
      f"SID first: <i>Settings &gt; Audio &gt; SID</i>, or start VICE with "
      f"{key('-sidenginemodel 257')}. For MIDI in VICE, enable a MIDI "
      f"cartridge of type Datel/Siel in the cartridge/IO settings (or set "
      f"MIDI i/face to match the type you pick) and connect your MIDI input "
      f"device."),
    P("With a Kerberos cartridge", h2),
    P("Start SID303 through the Kerberos, not from BASIC: the menu items "
      "<b>R</b> and <b>H</b> switch the cartridge off, and then no MIDI "
      "arrives. Use <i>Send PRG and start</i> in the Kerberos App, or flash "
      "<i>sid303.prg</i> to a slot and start it with <b>S</b> in the menu. "
      "Set the slot's MIDI emulation to Datel, which is also SID303's "
      "default. The App can send through a USB keyboard's MIDI Out: on an "
      "M-Audio Axiom, turn <i>MIDI Out from USB</i> on to send, and off again "
      "to play. The Kerberos menu item <b>M</b> tests the MIDI input."),
    P("First sounds", h2),
    *bullets([
        f"Press {key('Z')}, {key('X')}, {key('C')}... on the C64 keyboard: "
        "you hear the bass.",
        f"Hold {key('SHIFT')} while pressing a note to accent it.",
        "Hold one note and press another: the pitch slides to the new note "
        "without retriggering. This is the 303 slide.",
        f"Press {key('F1')} / {key('F2')} to move the cursor to Cutoff, then "
        f"{key('F3')} / {key('F4')} to open or close the filter while you play.",
    ]),
    note_box("<b>Leaving the program:</b> the synth takes over the whole machine "
             "(BASIC and KERNAL are switched off), so RUN/STOP-RESTORE does not "
             "exit. Reset the C64 to leave. Save your patterns, song and sound "
             "first (section 8); MIDI and paddle assignments are not saved."),
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
        "shown as a bar and a number; the others as a name (Saw, Low-pass...).",
        "<b>Two pages.</b> <b>Sound</b> has the sound, Cutoff to Volume; "
        "<b>Setup</b> has MIDI channel, MIDI i/face, Paddles, Clock, MIDI out "
        "and Disk drive. The page shown is the one the selected parameter is "
        f"on: {key('F1')} past Volume goes on to Setup, {key('F2')} from Cutoff "
        "goes straight to Disk drive. A grey line under each page's last "
        "parameter says where the other page is.",
        "<b>Title row.</b> The program name and build number (<b>SID303 "
        "b43</b>), the preset (<b>01 Classic acid</b>, with <b>*</b> once you "
        "change the sound) and the page's name. Please mention the build "
        "number when you report a problem.",
        "<b>P and CC columns</b> (right). P shows X or Y for the paddle that "
        "sets a parameter, CC the MIDI controller number. During learn the CC "
        f"column shows {key('???')}.",
        f"<b>Status line.</b> {key('Oct')}: the keyboard octave. {key('Note')} "
        f"and {key('Vel')}: the last note played and its velocity. "
        f"{key('Acc')} appears on an accented note, {key('Slide')} during a "
        f"slide. {key('MIDI')} turns reverse while MIDI data comes in. In learn mode "
        "this line shows the learn prompt instead.",
        "<b>Help lines</b> at the bottom: a short summary of the keys. "
        "<b>C=+</b> goes with the keys after it: C= + F3/F4 preset, C= + "
        "RETURN store, C= + W/L/M the bank (save, load, send over MIDI).",
        f"{key('F7')} switches to the <b>step screen</b>, the step "
        "sequencer's (section 8), and back. SID303 starts on the parameter "
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
        [f"{key('SHIFT')} + note", "Accented note. SHIFT LOCK accents every note."],
        ["Hold a note, play another", "Slide (portamento). Release the new note "
         "while still holding the first, and it slides back."],
        [f"{key('F8')} or {key('RUN/STOP')}", "All notes off"],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    P("Notes are last-note priority: the newest held note sounds. Up to eight "
      "held notes are remembered. Changing octave while a key is held never "
      "leaves a stuck note. Keyboard notes have velocity 80, accented 127.",
      body),
    note_box("<b>Tip:</b> the C64 keyboard matrix can ghost when three or more "
             "keys are held, so a key may seem pressed when it isn't. Play "
             "slides with two keys at a time."),
    P("5. Paddles", h1),
    P("Plug paddles into the port selected in <b>Paddles</b> (Port 1 by "
      "default). At start paddle X sets <b>Cutoff</b> and paddle Y sets "
      "<b>Resonance</b>. Either paddle can be given another parameter: select "
      f"it, press {key('RETURN')} and turn the paddle (see learn in section 7). "
      "The P column shows which paddle controls what."),
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

# --- 5. editing
story += [
    P("6. Editing the sound", h1),
    table([
        ["Key", "Action"],
        [f"{key('F1')} / {key('F2')} or CRSR down / up", "Next / previous parameter. "
         "Past Volume, or back from Cutoff, to the Setup page."],
        [f"{key('F3')} / {key('F4')}, {key('+')} / {key('-')}, CRSR right / left",
         "Increase / decrease the value. Hold to repeat (after 0.3 s, then 20 "
         "steps a second)."],
        [f"{key('F7')}", "The step screen (section 8)"],
        [f"{key('RETURN')}", "Learn a MIDI knob or paddle for the selected parameter (section 7)"],
        [f"{key('DEL')}", "Remove the selected parameter's MIDI controller"],
    ], [62 * mm, 108 * mm]),
    Spacer(1, 2 * mm),
    P("SHIFT turns F1, F3, F5 and F7 into F2, F4, F6 and F8. With SHIFT LOCK on, "
      "F1 therefore acts as F2."),

    P("Parameter reference", h2),
    table([
        ["Parameter", "Range", "CC", "What it does"],
        ["Cutoff", "0-255", "74", "Filter cutoff on a log scale, about 40 Hz to "
         "12 kHz, so each step is the same musical distance. Paddle X."],
        ["Resonance", "0-15", "71", "Filter resonance: the squelch. Paddle Y."],
        ["Env mod", "0-255", "12", "How far the filter envelope sweeps the "
         "filter on each note, up to about 4 octaves."],
        ["Env mod type", "Centred, Up only", "", "Centred (the default) works "
         "like the 303: more Env mod opens the filter higher at the start of a "
         "note and closes it lower at the end, around Cutoff. Up only opens the "
         "filter upward from Cutoff."],
        ["Decay", "0-15", "75", "How fast the filter envelope falls back, "
         "0.12 s to 2.5 s."],
        ["Accent", "0-15", "13", "Accent strength: the extra cutoff kick and "
         "the loudness difference of accented notes."],
        ["Slide time", "0-15", "5", "Glide time, 10 ms to 300 ms. The default "
         "8 (about 60 ms) is the 303's."],
        ["Amp decay", "0-15", "72", "How fast a held note fades, 0.15 s to 4 s. "
         "15 = no fade."],
        ["Waveform", "4 types", "", "Saw; Square; Saw+square (buzzier, "
         "brighter); 303 square (a square slanted by the saw, closer to the "
         "303's square)."],
        ["Pulse width", "0-15", "", "3% to 50%, for Square and 303 square."],
        ["Square tilt", "0-15", "", "303 square only: how much the saw slants "
         "the pulse. More tilt = more even harmonics."],
        ["Body", "0-15", "", "Adds an unfiltered triangle on the fundamental "
         "for a rounder bottom. 0 = off. It gets quieter as resonance goes up."],
        ["Tune", "-16..+15", "", "Fine tune, up to half a semitone either way."],
        ["Filter", "4 types", "", "Low-pass (the 303 sound); Low+band "
         "(stronger resonant peak, gentler slope); Band-pass; High-pass."],
        ["Volume", "0-15", "7", "Master volume."],
        ["MIDI channel", "Omni, 1-16", "", "Which channel the synth listens to."],
        ["MIDI i/face", "5 choices", "", "Off, Sequential, Passport, "
         "Datel (default), Namesoft."],
        ["Paddles", "Port 1/2, Off", "", "Which control port the paddles are in."],
        ["Clock", "Internal, MIDI", "", "The step sequencer's clock: its own "
         "tempo, or MIDI clock from another machine (section 8)."],
        ["MIDI out", "Off, On", "", "Send the step sequencer's notes, and with "
         "the internal clock its start, clock and stop."],
        ["Disk drive", "8-16", "", "Where patterns and songs are saved and "
         "loaded. At start: the drive SID303 was loaded from."],
    ], [26 * mm, 22 * mm, 10 * mm, 112 * mm]),
    Spacer(1, 2 * mm),
    P("The CC column lists the MIDI controllers assigned when the program "
      "starts. They and the paddles can be changed with learn.", small),
    Spacer(1, 2 * mm),
    note_box("Changing <b>Waveform</b>, <b>Square tilt</b> or <b>Body</b> while "
             "a note sounds restarts that note's envelopes, so you hear a new "
             "attack. The SID can't raise a voice's level mid-note."),

    P("Presets", h2),
    P("SID303 keeps <b>32 presets</b>, each a whole sound (Cutoff to Volume) "
      "with a name of up to 12 characters. At start, preset 1 is the sound "
      "SID303 starts with (<i>Classic acid</i>), 2 to 22 are factory sounds "
      "(section 9, Starting points) and 23 to 32 are copies of the start "
      "sound named <i>Init</i>, to store your own in. The title row shows "
      "the preset: <b>01 Classic acid</b>, and <b>01*Classic acid</b> once "
      "you change the sound."),
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
        "A recall sets every sound parameter <b>except Tune and Volume</b>: "
        "the tuning and level stay as they are for the rest of your setup. "
        "(They are stored with the preset, but not recalled.)",
        "Recalled while a note sounds: a new Waveform, Square tilt or Body "
        "restarts the note's envelopes, as when you change them by hand.",
        "The keys work on the parameter screen. On the step screen, use MIDI "
        "program change, or F7 back.",
    ]),
    P("Storing a sound", h2),
    P(f"{key('C=')} + {key('RETURN')} opens the store prompt on the status "
      f"line: <b>STORE TO 04: Square bass</b> and, at the right, "
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
      f"replace your song by mistake. The drive is the Setup page's "
      f"<b>Disk drive</b>. {key('C=')} + {key('M')} sends the bank over "
      f"MIDI instead (section 7, Backing up over MIDI)."),
    *bullets([
        "A bank file holds the 32 presets, values and names (4 blocks). "
        "Loading one replaces all 32; the sound playing stays as it is (the "
        "title shows <b>*</b>) until you recall a preset.",
        "The song file (section 8) holds the patterns, the song and the "
        "sound playing, not the presets; the bank holds only the presets. "
        "Each refuses the other: <b>NOT A SID303 BANK</b>, <b>NOT A SID303 "
        "FILE</b>, and nothing changes.",
        "While the disk works the sequencer stops and nothing plays. The "
        "drive's message (<b>00, OK,00,00</b>, <b>62, FILE NOT FOUND,00,00</b>, "
        "<b>NO DRIVE 9</b> ...) stays on the status line until the next key.",
    ]),
    PageBreak(),
]

# --- 6. MIDI
story += [
    P("7. MIDI", h1),
    P("Setting up", h2),
    *bullets([
        "Plug the MIDI interface into the expansion port with the C64 off.",
        "Select your interface type in <b>MIDI i/face</b> (Datel is the "
        "default). A Kerberos cartridge works in Datel mode; see section 2 for "
        "how to start SID303 with it.",
        "Set <b>MIDI channel</b> to your keyboard's channel, or leave it on "
        "Omni to hear every channel but 10: in Omni, notes on channel 10 (the "
        "General MIDI drum channel) are ignored, so a drum machine on the same "
        "MIDI line doesn't play the bass. Controllers on channel 10 still "
        "count.",
        "The <b>MIDI</b> label on the status line turns reverse while data arrives.",
    ]),
    P("What the synth responds to", h2),
    table([
        ["Message", "Effect"],
        ["Note on / off", "Plays notes. Velocity 110 or more plays an accented "
         "note."],
        ["Overlapping notes (legato)", "Slide. Most MIDI-to-303 setups send "
         "slides this way: start the next note before releasing the previous one."],
        ["Pitch bend", "Plus or minus 2 semitones"],
        ["Control change", "Sets the parameter assigned to that controller "
         "(CC column on screen)"],
        ["CC 120, CC 123", "All notes off"],
        ["Program change", "Programs 0-31 recall presets 1-32 (section 6)"],
        ["Controller 85", "Picks the pattern: values 0-63 are patterns 1-64. It plays "
         "from the next pattern start, as F1/F2 choose it (stopped: from play), and "
         "song mode goes off. Only on the synth's own channel, not in Omni."],
        ["Song select", "Song mode on (the synth holds one song; the number doesn't "
         "matter)."],
        ["Song position", "With Clock on MIDI and the sequencer stopped: where the "
         "next Continue plays from: the song entry, its repeat and step, or the "
         "pattern's step. Start still plays from the beginning."],
        ["SysEx dumps", "A request sends the song file or the preset bank; a "
         "dump loads one (Backing up over MIDI, below)."],
        ["Clock, start, continue, stop", "Drive the step sequencer when Clock "
         "is MIDI (section 8); otherwise ignored, even in the middle of other "
         "messages"],
    ], [50 * mm, 120 * mm]),
    Spacer(1, 2 * mm),
    P("Running status is supported. Controller values 0-127 are scaled to each "
      "parameter's range."),
    P("Backing up over MIDI", h2),
    P("The song file (everything a disk save holds) and the preset bank go "
      "to a PC and back as SysEx, each byte for byte as its file on disk: a "
      "file fetched over MIDI can go on a disk, and one from a disk can be "
      "sent. The PC tool is <b>sysex.py</b>, a download on SID303's web page "
      "(Python with mido and python-rtmidi):"),
    table([
        ["Command", "Does"],
        ["python sysex.py get sid303", "Fetches the song file into "
         "sid303-song.prg (-o picks the name)"],
        ["python sysex.py get sid303 --bank", "Fetches the preset bank"],
        ["python sysex.py send FILE", "Sends a song file or a bank back (a .prg "
         "fetched before, or copied from a disk): which one, and for which "
         "synth, comes from the file"],
        ["--port NAME, --channel N", "The MIDI port (part of its name), and the "
         "synth's channel when several synths share the line"],
    ], [60 * mm, 110 * mm]),
    Spacer(1, 2 * mm),
    *bullets([
        f"{key('C=')} + {key('M')} sends a dump without a request: the song "
        "from the step screen, the bank from the parameter screen (any SysEx "
        "recorder takes it).",
        "With MIDI out on, a playing sequencer stops before a dump goes out: "
        "its notes would cut the dump. With MIDI out off it plays on, and the "
        "dump only uses the time the sound leaves.",
        "A dump that comes in stops the sequencer and silences the synth at "
        "once; when it is whole and SID303's it loads like a disk file and "
        "the song row shows <b>SYSEX: SONG LOADED</b> or <b>SYSEX: BANK "
        "LOADED</b>. Otherwise nothing changes and it says why: <b>SYSEX: "
        "BAD DATA</b> (a byte lost on the way: send it again) or <b>SYSEX: "
        "NOT A SID303 FILE</b> / <b>BANK</b>.",
        "Sending takes about a second.",
        "SID303 answers on its MIDI channel, or to any channel in Omni.",
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
    P("Programming acid lines from a sequencer", h2),
    *bullets([
        "<b>Accent:</b> give the note a velocity of 110-127. Use lower "
        "velocities for normal notes.",
        "<b>Slide:</b> make the note overlap the next one (tie it or lengthen "
        "its gate past the next note's start).",
        "<b>Normal notes:</b> leave a gap between notes so each one retriggers "
        "the envelopes.",
    ]),
    P("MIDI and paddle learn", h2),
    P("Any knob or slider on your MIDI controller, and either paddle, can be "
      "assigned to any sound parameter (Cutoff to Volume):"),
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

# --- 8. the step sequencer
story += [
    P("8. The step sequencer", h1),
    P(f"SID303 has its own step sequencer in the style of the 303's: patterns "
      f"of up to 16 steps, each a note with accent and slide, or a tie or a "
      f"rest. Press {key('F7')} on the parameter screen to open the step "
      f"screen, and {key('F7')} again to go back. The sound parameters, MIDI "
      f"and the paddles work as before while a pattern plays."),
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
        "so you can see the line's shape. It starts at the C below the pattern's "
        "lowest note; the <b>C1 C2 C3</b> above it mark the octaves. <b>&gt;</b> marks the step playing, the "
        "reversed row is the cursor, and steps past the length are dim.",
        "<b>Song row:</b> the song (below), or a message after undo or a disk "
        "operation, until the next key.",
        "<b>Status line and help</b> as on the parameter screen.",
    ]),
    P("How a pattern plays", h2),
    *bullets([
        "<b>Note:</b> the note starts and its gate closes after half a step, "
        "as on a 303.",
        "<b>Accent:</b> the note plays accented (velocity 127): louder, a "
        "shorter filter decay and the accent sweep.",
        "<b>Slide:</b> the note holds on into the next step's note, which "
        "glides in without restarting the envelopes. A slide into the same "
        "note simply holds it; a slide into a rest ends at the rest.",
        "<b>Tie:</b> the note before goes on through this step. A tie after a "
        "rest stays silent.",
        "<b>Rest:</b> silence.",
    ]),
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
    P("Pattern 1 holds the acid line of the demos when SID303 starts, so "
      "RUN/STOP plays something at once. The other 63 patterns are empty. "
      "Undo covers steps, lengths, clears, copies and the song; tempo, swing "
      "and the octave are settings and are not undone."),
    P("Songs", h2),
    P(f"A song chains patterns: up to 64 entries, each a pattern played 1-9 "
      f"times and transposed up or down by up to 12 semitones, like a 303's "
      f"track mode. The song row shows <b>SONG</b>, the song cursor and the "
      f"song's length (<b>02/03</b>), then entries such as <b>01x2+05</b>: "
      f"pattern 1, twice, 5 semitones up. In song mode ({key('C=')} + "
      f"{key('S')}, <b>SONG</b> reversed) RUN/STOP plays the song from its "
      f"first entry, in a loop, and the step screen follows the pattern "
      f"playing."),
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
      f"RETURN goes and RUN/STOP cancels. A file (about 10 blocks) holds the 64 "
      f"patterns, the song, tempo, swing and the sound (Cutoff to Volume); the "
      f"setup (MIDI, paddles, clock, drive) is not in it. The drive is the "
      f"parameter screen's <b>Disk drive</b>, at start the drive SID303 was "
      f"loaded from. Saving replaces a file of the same name."),
    P("While a file is saved or loaded, the pattern stops and nothing plays. "
      "Afterwards the song row shows the drive's message, such as "
      "<b>00, OK,00,00</b> or <b>62, FILE NOT FOUND,00,00</b>, or "
      "<b>NO DRIVE 9</b>, <b>NOT A SID303 FILE</b> or <b>FILE ENDED EARLY</b>."),
    P("Playing with other machines", h2),
    *bullets([
        "<b>Following a MIDI clock:</b> set <b>Clock</b> to MIDI. The "
        "sequencer then waits for the master: Start plays from the first step "
        "(the song's first entry in song mode), each 6 clocks (a 16th) is a "
        "step, Stop stops and Continue goes on where it stopped. The title "
        "shows <b>BPM EXT</b>.",
        "<b>MIDI out:</b> set <b>MIDI out</b> to On to send the pattern's notes "
        "on the MIDI channel (Omni: channel 1): accent as velocity 127, a "
        "slide as the next note starting before the last one ends. With the "
        "internal clock it also sends start, clock and stop, so another "
        "machine can follow SID303.",
        "<b>With SID808:</b> connect SID808's MIDI out to SID303's MIDI in, "
        "set SID808's MIDI out On and SID303's Clock to MIDI, and press "
        "RUN/STOP on SID808. SID808 sends its drums on channel 10, which "
        "SID303 ignores in Omni, so they don't play the bass.",
    ]),
    PageBreak(),
]

# --- 9. sound guide
story += [
    P("9. Making acid sounds", h1),
    P("How the controls work together", h2),
    P("Each note opens the filter and it then closes again over the "
      "<b>Decay</b> time. <b>Env mod</b> sets how wide the sweep is. With "
      "<b>Env mod type</b> Centred, as on a 303, the sweep swings around "
      "<b>Cutoff</b>: more Env mod opens it higher <i>and</i> closes it lower, "
      "so the middle of the sweep stays where Cutoff puts it. "
      "<b>Resonance</b> sharpens the peak at the cutoff frequency, which is "
      "what makes the sweep \"talk\". Low Cutoff with high Env mod and "
      "Resonance gives the classic squelch; turning Cutoff up while a line "
      "plays is the classic acid build-up."),
    P("<b>Accent</b> makes a note louder with a pluck that falls back over "
      "about 0.2 s, shortens its filter decay and kicks the cutoff higher. "
      "Accents in a row build up the kick, more so at high resonance, like the "
      "303's \"accent sweep\". At high resonance the kick also rises more slowly, the 303's \"waaaoow\". <b>Slide</b> glides the pitch without restarting "
      "the envelopes, so slid notes stay smooth while the filter keeps "
      "decaying."),
    P("Starting points", h2),
    P("These six are presets 1-6 (section 6). Each has a demo recording in "
      "<i>demos/presets</i>, and the same with Env mod type Up only in "
      "<i>demos/uponly</i>."),
    table([
        ["Sound", "Settings", "Demo"],
        ["Default (classic)", "Saw, Low-pass, Cutoff 80, Resonance 12, Env mod "
         "160, Decay 6, Accent 10, Slide 8, Amp decay 9", "1-default.wav"],
        ["Hard, screaming", "Saw, Low+band filter, Resonance 15, Env mod 200, "
         "Decay 1, Accent 15. Sweep Cutoff while it plays.", "2-hard.wav"],
        ["Buzzier and brighter", "As above with Saw+square", "3-buzzy.wav"],
        ["Square bass", "303 square, Square tilt 6", "4-square-bass.wav"],
        ["Fuller bottom", "303 square, Square tilt 6, Body 4",
         "5-fuller-bottom.wav"],
        ["Organ-like held notes", "Default with Amp decay 15 (no fade)",
         "6-held-no-fade.wav"],
    ], [38 * mm, 94 * mm, 38 * mm]),
    Spacer(1, 2 * mm),
    P("The other factory presets", h2),
    P("Presets 7-22 change the start sound (preset 1) as listed. Recall "
      "one and change it to taste: the title row shows <b>*</b> until you "
      "store the result (section 6). <i>demos/presets/factory.wav</i> plays "
      "each factory preset for two bars of pattern 1."),
    table([
        ["", "Preset", "Changes from Classic acid"],
        ["7", "Squelch", "Cutoff 50, Resonance 14, Env mod 230, Decay 4, Accent 12"],
        ["8", "Deep sub", "Cutoff 60, Resonance 4, Env mod 60, Decay 8, 303 square, Body 10, Amp decay 11"],
        ["9", "Rubber", "Cutoff 70, Resonance 13, Env mod 140, Decay 9, Slide 12, Amp decay 12"],
        ["10", "Pluck", "Cutoff 90, Resonance 8, Env mod 180, Decay 2, Amp decay 4"],
        ["11", "Dark rumble", "Cutoff 35, Resonance 10, Env mod 90, Decay 10, Body 6, Env mod up only"],
        ["12", "Open saw", "Cutoff 180, Resonance 6, Env mod 60, Decay 8, Amp decay 12"],
        ["13", "Band-pass", "Band-pass, Cutoff 110, Resonance 12, Env mod 150, Decay 5"],
        ["14", "Thin hi-pass", "High-pass, Cutoff 60, Resonance 11, Env mod 170, Decay 5"],
        ["15", "Up only", "Env mod up only, Cutoff 60, Resonance 13, Env mod 200, Decay 6"],
        ["16", "Long decay", "Decay 12, Env mod 180, Resonance 13, Amp decay 13"],
        ["17", "Slow slide", "Slide 14"],
        ["18", "Hollow sq", "Square, Pulse width 8, Cutoff 100, Resonance 10"],
        ["19", "Saw+sq lead", "Saw+square, Cutoff 140, Resonance 9, Env mod 120, Decay 8, Amp decay 13"],
        ["20", "Wild accent", "Accent 15, Resonance 14, Env mod 210, Decay 3"],
        ["21", "Soft acid", "Cutoff 95, Resonance 8, Env mod 100, Accent 6"],
        ["22", "Tight bass", "Decay 3, Amp decay 5, Resonance 9, Env mod 130, 303 square, Square tilt 4"],
    ], [10 * mm, 30 * mm, 130 * mm], bold_first_col=False),
    Spacer(1, 2 * mm),
    P("Demo recordings", h2),
    P("The demos are VICE (reSID 8580) recordings of the built-in test line, "
      "the one <i>sid303-test.prg</i> plays. Demos 1 and 4-6 play four bars "
      "of the line, then a bar of long notes so the fade and the accent pluck "
      "can be heard. The line sets Cutoff itself, a different value each bar. "
      "Demos 2 and 3 play the cutoff sweep of <i>sid303-sweep.prg</i>: eight "
      "bars with the cutoff turned fully open and back down twice, as you "
      "would with the knob."),
    P("The <i>demos</i> folder also keeps the recordings made while the synth "
      "was developed (<i>1-before-saw-nofade.wav</i> to "
      "<i>8-sweep-hard-sawsquare.wav</i>). <i>1-before-saw-nofade.wav</i> is "
      "an older version without the fade or the accent pluck."),
    Spacer(1, 4 * mm),

    PageBreak(),
    P("10. Troubleshooting and limits", h1),
    table([
        ["Problem", "What to check"],
        ["No sound from MIDI", "MIDI i/face matches your cartridge; MIDI "
         "channel is Omni or your channel; the MIDI label lights up (reverse) "
         "when you play. Kerberos: start SID303 through the Kerberos menu or "
         "App, not from BASIC (section 2). A USB keyboard must send its keys "
         "to its MIDI Out (Axiom: MIDI Out from USB off)."],
        ["Sound is thin or the filter behaves oddly", "The machine has a 6581 "
         "SID. The synth is made for the 8580. In VICE, select the 8580 model."],
        ["Pitch slightly sharp, envelopes fast", "NTSC machine. The timing is "
         "for PAL: on NTSC pitch is about 2/3 of a semitone sharp and envelopes "
         "about 4% fast."],
        ["Wrong or extra notes from the keyboard", "Keyboard ghosting with three "
         "or more keys held, or a paddle fire button pressed."],
        ["Paddle seems to do nothing", "Move it: soft takeover waits for movement. "
         "Check the Paddles setting matches the port, and the P column for "
         "what it controls."],
        ["The pattern doesn't play", "Clock is on MIDI: the sequencer waits for "
         "the master's Start and clocks. Set Clock to Internal to play on its own."],
        ["Pattern plays but sounds wrong", "Check the step screen shows the "
         "pattern you mean (F1/F2), its length, and whether song mode is on "
         "(SONG reversed): then the song decides what plays."],
        ["Disk: NO DRIVE 8", "No drive answers at the Disk drive number. Turn "
         "it on, or set Disk drive to your drive's number."],
        ["Disk: NOT A SID303 FILE", "The file isn't a SID303 song file (a bank "
         "loaded on the step screen, or a file from a newer version). Nothing "
         "was changed."],
        ["SYSEX: BAD DATA", "A dump came in damaged (a byte lost or changed "
         "on the way). Nothing was changed: send it again."],
        ["SYSEX: NOT A SID303 FILE / BANK", "The dump was meant for SID303 but "
         "isn't one of its files. Nothing was changed."],
        ["My presets are gone", "They live in memory: save a bank (C= + W on "
         "the parameter screen) before you reset, and load it (C= + L) after."],
        ["A preset doesn't change the volume or tuning", "By design: a recall "
         "keeps Volume and Tune (section 6)."],
        ["Disk: NOT A SID303 BANK", "The file isn't a preset bank (a song file "
         "loaded with C= + L on the parameter screen?). Nothing was changed."],
        ["Can't leave the program", "RESTORE does nothing. Reset the C64."],
        ["Reporting a bug", "Include the build number from the title row "
         "(\"build 5\") and what you did."],
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
        ["SHIFT + note", "Accent (SHIFT LOCK: accent all)"],
        ["Hold note + play another", "Slide"],
        ["Paddle X / Y", "Cutoff / Resonance (or as learnt)"],
    ], [75 * mm, 95 * mm]),
    Spacer(1, 6 * mm),
    table([
        ["Default MIDI CC", "Parameter"],
        ["74", "Cutoff"], ["71", "Resonance"], ["12", "Env mod"],
        ["75", "Decay"], ["13", "Accent"], ["5", "Slide time"],
        ["72", "Amp decay"], ["7", "Volume"], ["120, 123", "All notes off"],
    ], [40 * mm, 60 * mm]),
    Spacer(1, 4 * mm),
    P("Velocity 110-127 = accent. Overlapping notes = slide. "
      "Pitch bend = plus or minus 2 semitones."),
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
                        bottomMargin=20 * mm, title="SID303 user manual",
                        author="Jarkko Lehti", subject="How to use SID303")
doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
print("wrote", OUT)
