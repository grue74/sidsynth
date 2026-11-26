; params.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; =============================================================================
; Parameter tables (index = P_* constant). Stage A has only the player's
; tempo, swing and clock; the setup parameters the core needs come last.
; =============================================================================
;                    Tempo                  Swing       Clock                                Click       Click chan       Beat note, bar
param_default .byte  TEST_TEMPO-BPM_LOWEST, TEST_SWING, TEST_SLAVE != 0 && TEST_SWITCH == 0 && !TEST_FEED_MASTER, TEST_CLICK, TEST_CLICK_CHAN, 37, 75
;                    Thru       Record         Rec quantize    Count-in
              .byte  TEST_THRU, TEST_REC_MODE, TEST_REC_QUANT, TEST_COUNT_BARS
;                    Chan          MIDIIF           Paddles
              .byte  TEST_CHANNEL, MIDI_IF_DEFAULT, 2
.if DISK_CODE
;                    Disk drive (disk.asm disk_init: the drive loaded from)
              .byte  0
.endif
        .cerror * - param_default != NUM_PARAMS, "param_default needs NUM_PARAMS entries"
        .cerror TEST_TEMPO < BPM_LOWEST || TEST_TEMPO > BPM_HIGHEST, "TEST_TEMPO: 40-240 BPM"
param_max     .byte  BPM_HIGHEST-BPM_LOWEST, 15, 1, 3, 15, 127, 127, 1, 1, 3, 2, 16, 4, 2
.if DISK_CODE
              .byte  16-8
.endif
        .cerror * - param_max != NUM_PARAMS, "param_max needs NUM_PARAMS entries"
param_step    .byte  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
.if DISK_CODE
              .byte  1
.endif
        .cerror * - param_step != NUM_PARAMS, "param_step needs NUM_PARAMS entries"
param_kind    .byte  K_BAR256, K_BAR16, K_ENUM, K_ENUM, K_ENUM, K_BAR256, K_BAR256, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM, K_ENUM
.if DISK_CODE
              .byte  K_ENUM
.endif
        .cerror * - param_kind != NUM_PARAMS, "param_kind needs NUM_PARAMS entries"
enum_ptr_lo   .byte  0, 0, <clock_names, <click_names, <channel_names+10, 0, 0, <onoff_names, <record_names, <quant_names, <count_names, <channel_names, <midiif_names, <paddle_names
.if DISK_CODE
              .byte  <(channel_names+80)
.endif
        .cerror * - enum_ptr_lo != NUM_PARAMS, "enum_ptr_lo needs NUM_PARAMS entries"
enum_ptr_hi   .byte  0, 0, >clock_names, >click_names, >(channel_names+10), 0, 0, >onoff_names, >record_names, >quant_names, >count_names, >channel_names, >midiif_names, >paddle_names
.if DISK_CODE
              .byte  >(channel_names+80)
.endif
        .cerror * - enum_ptr_hi != NUM_PARAMS, "enum_ptr_hi needs NUM_PARAMS entries"

        .enc "screen"           ; text below is in screen codes (mixed-case charset)

; parameter names, 12 characters each
param_names
        .text "Tempo -40   "
        .text "Swing       "
        .text "Clock       "
        .text "Metronome   "
        .text "Click chan  "
        .text "Beat note   "
        .text "Bar note    "
        .text "Thru        "
        .text "Record      "
        .text "Rec quantize"
        .text "Count-in    "
        .text "MIDI channel"
        .text "MIDI i/face "
        .text "Paddles     "
.if DISK_CODE
        .text "Disk drive  "
.endif

; enum names, ENUM_WIDTH (10) characters each
clock_names     .text "Internal  ", "MIDI      "
click_names     .text "Off       ", "SID       ", "MIDI      ", "SID+MIDI  "
onoff_names     .text "Off       ", "On        "
record_names    .text "Overdub   ", "Replace   "
quant_names     .text "Off       ", "16th      ", "8th       ", "16th trip "
count_names     .text "Off       ", "1 bar     ", "2 bars    "
channel_names   .text "Omni      "
                .for ch := 1, ch <= 16, ch += 1
                .text format("%-10d", ch)
                .endfor
midiif_names    .text "Off       ", "Sequential", "Passport  ", "Datel     ", "Namesoft  "
paddle_names    .text "Port 1    ", "Port 2    ", "Off       "

; status line template
status_text     .text format("%-40s", "F7: song screen. Tempo shows BPM - 40")

; title row, 40 characters
title_text      .text format("%-35s", format("SID500 b%d", BUILD)), " P CC"
                                ; build number for bug reports; P, CC head the paddle and
                                ; controller columns
        .cerror * - title_text != 40, "title must be 40 characters"

; help rows, HELP_ROWS x 40 characters
help_text
        .text format("%-40s", "F1/2 select F3/4 value")
HELP_ROWS = (* - help_text) / 40

        .enc "none"

; controllers assigned at start: none yet
cc_numbers
cc_params
CC_COUNT = 0
LEARN_LIMIT = P_CHANNEL         ; parameters below this can be given a controller
