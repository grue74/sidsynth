; keymap.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; key_map: what each matrix key does, index = column*8 + row
;   0..$3F        note: semitones above the keyboard's base C
;   $40+cmd       command, $60+cmd: SHIFT gives cmd+1
;   $FF           nothing
; Stage A: the core's parameter keys only (the editor's keys come with its
; screens, stage B on).
KN = KEY_NONE
KC = KEY_CMD
KS = KEY_CMD | KEY_SHIFTABLE
key_map
        ;     DEL             RETURN        CRSR-RT          F7            F1                 F3               F5  CRSR-DN
        .byte KC|CMD_UNLEARN, KC|CMD_LEARN, KS|CMD_VALUE_UP, KS|CMD_SYNTH, KS|CMD_PARAM_NEXT, KS|CMD_VALUE_UP, KN, KS|CMD_PARAM_NEXT
        ;     3   W   A   4   Z   S   E   LSHIFT
        .byte KN, KN, KN, KN, KN, KN, KN, KN
        ;     5   R   D   6   C   F   T   X
        .byte KN, KN, KN, KN, KN, KN, KN, KN
        ;     7   Y   G   8   B   H   U   V
        .byte KN, KN, KN, KN, KN, KN, KN, KN
        ;     9   I   J   0   M   K   O   N
        .byte KN, KN, KN, KN, KN, KN, KN, KN
        ;     +                P   L   -                  .   :   @   ,
        .byte KC|CMD_VALUE_UP, KN, KN, KC|CMD_VALUE_DOWN, KN, KN, KN, KN
        ;     pound *  ;   HOME RSHIFT =  UP  /
        .byte KN,   KN, KN, KN,  KN,    KN, KN, KN
        ;     1   <-  CTRL 2   SPACE C=  Q   RUN/STOP
        .byte KN, KN, KN,  KN, KN,   KN, KN, KC|CMD_PANIC
