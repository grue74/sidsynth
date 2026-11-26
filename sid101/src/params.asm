; params.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; =============================================================================
; Parameter tables (index = P_* constant)
; =============================================================================
;                    Cut Res Env Att Dec Sus Rel Amp Mode Saw Pul Sub Typ PW PWM SPit SEnv
param_default .byte  90,  6, 120,  0,  6,  4,  3,  0,  0,  15,  0, 10,  0,  0,  0,  0,   0
              ;      Chord Speed Click
              .byte  0,    0,    0
              ;      Rate Shape         Dly Vib LCut Whl Acc Gli GMode
              .byte  8,   LFO_TRIANGLE, 0,  0,  0,   0,  0,  4,  GLIDE_AUTO
              ;      Arp      Range Rate         Tune Vol Chan MIDIIF Paddles
              .byte  TEST_ARP, 0,   ARP_RATE_16, 16,  15,  TEST_CHANNEL, MIDI_IF_DEFAULT, 0
              ;      Clock       MIDI out      Drive
              .byte  TEST_CLOCK, TEST_MIDIOUT, 0 ; internal, off, drive 8
        .cerror * - param_default != NUM_PARAMS, "param_default needs NUM_PARAMS entries"
param_max     .byte  255, 15, 255, 15, 15, 15, 15, 1, VM_C64, 15, 15, 15, 2, 15, 15, 255, 255
              .byte  CHORDS-1, CHORD_SPEEDS-1, CLICKS-1
              .byte  15, 3, 15, 15, 15, 255, 15, 15, 2, 4, 2, 2, 31, 15, 16, 4, 2
              .byte  1, 1, LAST_DRIVE - FIRST_DRIVE
        .cerror * - param_max != NUM_PARAMS, "param_max needs NUM_PARAMS entries"
param_step    .byte  4, 1, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 4, 4
              .byte  1, 1, 1
              .byte  1, 1, 1, 1, 1, 8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
              .byte  1, 1, 1
        .cerror * - param_step != NUM_PARAMS, "param_step needs NUM_PARAMS entries"
param_kind    .byte  K_BAR256, K_BAR16, K_BAR256, K_BAR16, K_BAR16, K_BAR16, K_BAR16, K_ENUM, K_ENUM
              .byte  K_BAR16, K_BAR16, K_BAR16, K_ENUM, K_BAR16, K_BAR16, K_BAR256, K_BAR256
              .byte  K_ENUM, K_ENUM, K_ENUM
              .byte  K_BAR16, K_ENUM, K_BAR16, K_BAR16, K_BAR16, K_BAR256, K_BAR16, K_BAR16, K_ENUM
              .byte  K_ENUM, K_ENUM, K_ENUM
              .byte  K_TUNE, K_BAR16, K_ENUM, K_ENUM, K_ENUM
              .byte  K_ENUM, K_ENUM, K_ENUM
        .cerror * - param_kind != NUM_PARAMS, "param_kind needs NUM_PARAMS entries"
enum_ptr_lo   .byte  0, 0, 0, 0, 0, 0, 0, <ampmode_names, <voicemode_names, 0, 0, 0, <subtype_names, 0, 0, 0, 0
              .byte  <chord_names, <chordspeed_names, <click_names
              .byte  0, <lfoshape_names, 0, 0, 0, 0, 0, 0, <glidemode_names
              .byte  <arp_names, <arprange_names, <arprate_names
              .byte  0, 0, <channel_names, <midiif_names, <paddle_names
              .byte  <clock_names, <onoff_names, <drive_names
        .cerror * - enum_ptr_lo != NUM_PARAMS, "enum_ptr_lo needs NUM_PARAMS entries"
enum_ptr_hi   .byte  0, 0, 0, 0, 0, 0, 0, >ampmode_names, >voicemode_names, 0, 0, 0, >subtype_names, 0, 0, 0, 0
              .byte  >chord_names, >chordspeed_names, >click_names
              .byte  0, >lfoshape_names, 0, 0, 0, 0, 0, 0, >glidemode_names
              .byte  >arp_names, >arprange_names, >arprate_names
              .byte  0, 0, >channel_names, >midiif_names, >paddle_names
              .byte  >clock_names, >onoff_names, >drive_names
        .cerror * - enum_ptr_hi != NUM_PARAMS, "enum_ptr_hi needs NUM_PARAMS entries"

        .enc "screen"           ; text below is in screen codes (mixed-case charset)

; parameter names, 12 characters each
param_names
        .text "Cutoff      "
        .text "Resonance   "
        .text "Env mod     "
        .text "Attack      "
        .text "Decay       "
        .text "Sustain     "
        .text "Release     "
        .text "Amp         "
        .text "Voice mode  "
        .text "Saw         "
        .text "Pulse / sync"
        .text "Sub         "
        .text "Sub type    "
        .text "Pulse width "
        .text "PWM         "
        .text "Sync pitch  "
        .text "Sync env    "
        .text "Chord       "
        .text "Chord speed "
        .text "Click       "
        .text "LFO rate    "
        .text "LFO shape   "
        .text "LFO delay   "
        .text "Vibrato     "
        .text "LFO cutoff  "
        .text "Mod wheel   "
        .text "Accent      "
        .text "Glide       "
        .text "Glide mode  "
        .text "Arpeggio    "
        .text "Arp range   "
        .text "Arp rate    "
        .text "Tune        "
        .text "Volume      "
        .text "MIDI channel"
        .text "MIDI i/face "
        .text "Paddles     "
        .text "Clock       "
        .text "MIDI out    "
        .text "Disk drive  "

; enum names, ENUM_WIDTH (10) characters each
ampmode_names   .text "Envelope  ", "Gate      "
voicemode_names .text "101       ", "Sync      ", "C64       "
subtype_names   .text "1 oct down", "2 oct down", "25% 2 down"
chord_names     .text "Off       ", "Keys      ", "Major     ", "Minor     ", "7th       ", "Minor 7th "
                .text "Major 7th ", "Sus 4     ", "5th       ", "Octave    ", "Diminished"
CHORDS          = (* - chord_names) / ENUM_WIDTH
chordspeed_names .for _f := 1, _f <= 8, _f += 1
                .text format("%-10s", format("%d frame", _f) .. ("s" x (_f > 1)))
                .endfor
CHORD_SPEEDS    = (* - chordspeed_names) / ENUM_WIDTH
click_names     .text "Off       "
                .for _w in ("Noise", "Saw", "Square")
                .for _f := 1, _f <= 3, _f += 1
                .text format("%-10s", format("%s %d", _w, _f))
                .endfor
                .endfor
CLICKS          = (* - click_names) / ENUM_WIDTH
lfoshape_names  .text "Triangle  ", "Square    ", "Random    ", "Noise     "
glidemode_names .text "Off       ", "On        ", "Auto      "
arp_names       .text "Off       ", "Up        ", "Down      ", "Up & down ", "Random    "
arprange_names  .text "1 octave  ", "2 octaves ", "3 octaves "
arprate_names   .text "1/8       ", "1/16      ", "1/32      "
channel_names   .text "Omni      "
                .for ch := 1, ch <= 16, ch += 1
                .text format("%-10d", ch)
                .endfor
midiif_names    .text "Off       ", "Sequential", "Passport  ", "Datel     ", "Namesoft  "
paddle_names    .text "Port 1    ", "Port 2    ", "Off       "
clock_names     .text "Internal  ", "MIDI      "
onoff_names     .text "Off       ", "On        "
drive_names     .for _d := FIRST_DRIVE, _d <= LAST_DRIVE, _d += 1
                .text format("%-10d", _d)
                .endfor

note_names      .text "C-C#D-D#E-F-F#G-G#A-A#B-"

; the parameter screen's pages (PARAM_PAGE2), named in the title row
page_names      .text "Sound ", "Play  "
        .cerror * - page_names != 2 * PAGE_NAME_WIDTH, "page_names: two names of PAGE_NAME_WIDTH"
; and the row under each page's last parameter, saying where the other one is.
; Page 1's hint row is a parameter row on page 2 (Clock), and a parameter
; row never writes the gaps between its fields (core/screen.asm: columns 1,
; 14 and 35), so the hint must leave them blank
PAGE1_HINT      = format("%-40s", "  Page 2: LFO, glide, arp, MIDI")
        .cerror PAGE1_HINT[1] != " " || PAGE1_HINT[14] != " " || PAGE1_HINT[35] != " ", "page 1's hint over page 2's gaps"
page_hints      .text PAGE1_HINT
                .text format("%-40s", "  Sound parameters above")
        .cerror * - page_hints != 2 * 40, "page_hints: two rows of 40"

; status line template and where its fields go
STATUS_OCT_COL   = 4
STATUS_NOTE_COL  = 12
STATUS_VEL_COL   = 21
STATUS_GLIDE_COL = 27
STATUS_MIDI_COL  = 36
status_text     .text format("%-36s", "Oct 2  Note ---  Vel 000"), "MIDI"
glide_text      .text "Glide"

; title row, 40 characters
title_text      .text format("%-35s", format("SID101 b%d", BUILD)), " P CC"
                                ; build number for bug reports; the preset from column 12
                                ; (presets.asm draw_preset_title); P, CC head the paddle and
                                ; controller columns
        .cerror len(format("SID101 b%d", BUILD)) >= PRESET_COL, "the build number runs into the preset"
        .cerror * - title_text != 40, "title must be 40 characters"

; help rows, HELP_ROWS x 40 characters
help_text
        .text format("%-40s", "F1/2 select F3/4 value F5/6 oct F7 steps")
        .text format("%-40s", "RET learn C=+F3/4 preset RET store W/L/M")
HELP_ROWS = (* - help_text) / 40

        .enc "none"


; controllers assigned at start, and the parameter each one sets
; (tables.py's CC table must match: the demo pattern uses them)
cc_numbers      .byte 74, 71, 20, 73, 75, 21, 72, 22, 31, 23, 24, 25, 26, 27, 28, 78, 79, 17, 18, 19
                .byte 76, 14, 15, 77, 29, 1, 16, 5, 30, 80, 81, 82, 7
cc_params       .byte P_CUTOFF, P_RESO, P_ENVMOD, P_ATTACK, P_DECAY, P_SUSTAIN, P_RELEASE
                .byte P_AMPMODE, P_VOICEMODE, P_SAW, P_PULSE, P_SUB, P_SUBTYPE, P_PW, P_PWM
                .byte P_SYNCPITCH, P_SYNCENV, P_CHORD, P_CHORDSPEED, P_CLICK
                .byte P_LFORATE, P_LFOSHAPE, P_LFODELAY, P_VIBRATO, P_LFOCUT, P_MODWHEEL
                .byte P_ACCENT, P_GLIDE, P_GLIDEMODE, P_ARP, P_ARPRANGE, P_ARPRATE, P_VOLUME
CC_COUNT = cc_params - cc_numbers
        .cerror * - cc_params != CC_COUNT, "cc_params: one per cc_numbers entry"
LEARN_LIMIT = P_CHANNEL         ; parameters below this can be given a controller
