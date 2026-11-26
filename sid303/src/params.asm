; params.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; =============================================================================
; Parameter tables (index = P_* constant)
; =============================================================================
param_default .byte  80, RESO_DEFAULT, ENVMOD_DEFAULT, ENVTYPE_DEFAULT, DECAY_DEFAULT, ACCENT_DEFAULT, 8, AMPDECAY_DEFAULT, WAVE_DEFAULT, 15, BLEND_DEFAULT
              .byte  BODY_DEFAULT, 16, FILTER_DEFAULT, 15, TEST_CHANNEL, MIDI_IF_DEFAULT, 0
              .byte  TEST_CLOCK, TEST_MIDIOUT, 0 ; Clock internal, MIDI out off, drive 8
        .cerror * - param_default != NUM_PARAMS, "param_default needs NUM_PARAMS entries"
param_max     .byte  255, 15, 255, 1, 15, 15, 15, 15, WAVE_COUNT-1, 15, 15, 15, 31, 3, 15, 16, 4, 2
              .byte  1, 1, LAST_DRIVE - FIRST_DRIVE
        .cerror * - param_max != NUM_PARAMS, "param_max needs NUM_PARAMS entries"
param_step    .byte  4, 1, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        .cerror * - param_step != NUM_PARAMS, "param_step needs NUM_PARAMS entries"
param_kind    .byte  K_BAR256, K_BAR16, K_BAR256, K_ENUM, K_BAR16, K_BAR16, K_BAR16, K_BAR16, K_ENUM
              .byte  K_BAR16, K_BAR16, K_BAR16, K_TUNE, K_ENUM, K_BAR16, K_ENUM, K_ENUM, K_ENUM
              .byte  K_ENUM, K_ENUM, K_ENUM
        .cerror * - param_kind != NUM_PARAMS, "param_kind needs NUM_PARAMS entries"
enum_ptr_lo   .byte  0, 0, 0, <envtype_names, 0, 0, 0, 0, <wave_names, 0, 0, 0, 0, <filter_names, 0, <channel_names, <midiif_names, <paddle_names
              .byte  <clock_names, <onoff_names, <drive_names
        .cerror * - enum_ptr_lo != NUM_PARAMS, "enum_ptr_lo needs NUM_PARAMS entries"
enum_ptr_hi   .byte  0, 0, 0, >envtype_names, 0, 0, 0, 0, >wave_names, 0, 0, 0, 0, >filter_names, 0, >channel_names, >midiif_names, >paddle_names
              .byte  >clock_names, >onoff_names, >drive_names
        .cerror * - enum_ptr_hi != NUM_PARAMS, "enum_ptr_hi needs NUM_PARAMS entries"

        .enc "screen"           ; text below is in screen codes (mixed-case charset)

; parameter names, 12 characters each
param_names
        .text "Cutoff      "
        .text "Resonance   "
        .text "Env mod     "
        .text "Env mod type"
        .text "Decay       "
        .text "Accent      "
        .text "Slide time  "
        .text "Amp decay   "
        .text "Waveform    "
        .text "Pulse width "
        .text "Square tilt "
        .text "Body        "
        .text "Tune        "
        .text "Filter      "
        .text "Volume      "
        .text "MIDI channel"
        .text "MIDI i/face "
        .text "Paddles     "
        .text "Clock       "
        .text "MIDI out    "
        .text "Disk drive  "

; enum names, ENUM_WIDTH (10) characters each
envtype_names   .text "Up only   ", "Centred   "
wave_names      .text "Saw       ", "Square    ", "Saw+square", "303 square"
filter_names    .text "Low-pass  ", "Low+band  ", "Band-pass ", "High-pass "
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
page_names      .text "Sound ", "Setup "
        .cerror * - page_names != 2 * PAGE_NAME_WIDTH, "page_names: two names of PAGE_NAME_WIDTH"
; and the row under each page's last parameter, saying where the other one is
page_hints      .text format("%-40s", "  More below: MIDI, paddles, clock, disk")
                .text format("%-40s", "  Sound parameters above")
        .cerror * - page_hints != 2 * 40, "page_hints: two rows of 40"

; status line template and where its fields go
STATUS_OCT_COL   = 4
STATUS_NOTE_COL  = 12
STATUS_VEL_COL   = 21
STATUS_ACC_COL   = 26
STATUS_SLIDE_COL = 30
STATUS_MIDI_COL  = 36
status_text     .text format("%-36s", "Oct 2  Note ---  Vel 000"), "MIDI"
acc_text        .text "Acc"
slide_text      .text "Slide"

; title row, 40 characters
title_text      .text format("%-35s", format("SID303 b%d", BUILD)), " P CC"
                                ; build number for bug reports; the preset from column 12
                                ; (presets.asm draw_preset_title); P, CC head the paddle and
                                ; controller columns
        .cerror len(format("SID303 b%d", BUILD)) >= PRESET_COL, "the build number runs into the preset"
        .cerror * - title_text != 40, "title must be 40 characters"

; help rows, HELP_ROWS x 40 characters
help_text
        .text format("%-40s", "F1/2 select F3/4 value F5/6 oct F7 steps")
        .text format("%-40s", "RET learn C=+F3/4 preset RET store W/L/M")
HELP_ROWS = (* - help_text) / 40

        .enc "none"


; controllers assigned at start, and the parameter each one sets
cc_numbers      .byte 74, 71, 12, 75, 13, 5, 7, 72
cc_params       .byte P_CUTOFF, P_RESO, P_ENVMOD, P_DECAY, P_ACCENT, P_SLIDE, P_VOLUME, P_AMPDECAY
CC_COUNT = cc_params - cc_numbers
LEARN_LIMIT = P_CHANNEL         ; parameters below this can be given a controller
