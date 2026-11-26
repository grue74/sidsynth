; params.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; =============================================================================
; Parameter tables (index = P_* constant)
; =============================================================================
param_default .byte  15, LEVEL_MAX, TUNE_CENTER, DECAY_CENTER, TONE_CENTER, 0, TEST_CHANNEL, MIDI_IF_DEFAULT, 2, TEST_CLOCK, TEST_MIDIOUT, TEST_DRIVE
        .cerror * - param_default != NUM_PARAMS, "param_default needs NUM_PARAMS entries"
param_max     .byte  15, LEVEL_MAX, 2*TUNE_CENTER, 15, 15, NUM_SOUNDS-1, 16, 4, 2, 1, 1, LAST_DRIVE - FIRST_DRIVE
        .cerror * - param_max != NUM_PARAMS, "param_max needs NUM_PARAMS entries"
param_step    .byte  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
        .cerror * - param_step != NUM_PARAMS, "param_step needs NUM_PARAMS entries"
param_kind    .byte  K_BAR16, K_BAR16, K_TUNE, K_BAR16, K_BAR16, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM
        .cerror * - param_kind != NUM_PARAMS, "param_kind needs NUM_PARAMS entries"
enum_ptr_lo   .byte  0, 0, 0, 0, 0, <sound_long_names, <channel_names, <midiif_names, <paddle_names, <clock_names, <onoff_names, <drive_names
        .cerror * - enum_ptr_lo != NUM_PARAMS, "enum_ptr_lo needs NUM_PARAMS entries"
enum_ptr_hi   .byte  0, 0, 0, 0, 0, >sound_long_names, >channel_names, >midiif_names, >paddle_names, >clock_names, >onoff_names, >drive_names
        .cerror * - enum_ptr_hi != NUM_PARAMS, "enum_ptr_hi needs NUM_PARAMS entries"

        .enc "screen"           ; text below is in screen codes (mixed-case charset)

; parameter names, 12 characters each
param_names
        .text "Volume      "
        .text " Level      "                ; (indented: the selected sound's)
        .text " Tune       "
        .text " Decay      "
        .text " Tone       "
        .text "Sound       "
        .text "MIDI channel"
        .text "MIDI i/face "
        .text "Paddles     "
        .text "Clock       "
        .text "MIDI out    "
        .text "Disk drive  "

; enum names, ENUM_WIDTH (10) characters each
channel_names   .text "Omni      "
                .for ch := 1, ch <= 16, ch += 1
                .text format("%-10d", ch)
                .endfor
midiif_names    .text "Off       ", "Sequential", "Passport  ", "Datel     ", "Namesoft  "
paddle_names    .text "Port 1    ", "Port 2    ", "Off       "
sound_long_names .text "Kick      ", "Snare     ", "Clap      ", "Closed hat", "Open hat  "
                .text "Cowbell   ", "Low tom   ", "Mid tom   ", "High tom  ", "Rim shot  "
                .text "Claves    ", "Cymbal    ", "Maracas   "
        .cerror (* - sound_long_names) != NUM_SOUNDS * 10, "sound_long_names: one per sound"
clock_names     .text "Internal  ", "MIDI      "
onoff_names     .text "Off       ", "On        "
drive_names     .for _d := FIRST_DRIVE, _d <= LAST_DRIVE, _d += 1
                .text format("%-10d", _d)
                .endfor

; status row template and where its fields go
STATUS_VEL_COL   = 25
STATUS_CPU_COL   = 30           ; CPU overload warning (engine.asm overload_check)
STATUS_MIDI_COL  = 36
status_text     .text format("%-30s", "1:---  2:---  3:---  Vel 000"), "CPU   ", "MIDI"
status_voice_col .byte 2, 9, 16 ; column of each voice's sound name

; title row, 40 characters
title_text      .text format("%-35s", format("SID808  v%d.%d.%d  build %d", V_MAJOR, V_MINOR, V_PATCH, BUILD)), " P CC"
                                ; version and build number for bug reports; P, CC head the paddle and controller columns
        .cerror * - title_text != 40, "title must be 40 characters"

; help rows, HELP_ROWS x 40 characters
help_text
        .text format("%-40s", "F1/F2 select  F3/F4 +/- value  F5/F6 oct")
        .text format("%-40s", "F7 grid F8 off RETURN learn SHIFT accent")
        .text format("%-40s", "Z kick  X snare  D clap  G closed hat")
        .text format("%-40s", "J open hat  V B N M , toms  S rim  L cym")
HELP_ROWS = (* - help_text) / 40

        .enc "none"


; controllers assigned at start, and the parameter each one sets
cc_numbers      .byte 7, 16, 17, 18, 19 ; volume; general purpose 1-4: the selected
cc_params       .byte P_VOLUME, P_LEVEL, P_TUNE, P_DECAY, P_TONE ; sound's knobs
CC_COUNT = cc_params - cc_numbers
LEARN_LIMIT = P_SOUND           ; parameters below this can be given a controller
