; keymap.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; key_map: what each matrix key does, index = column*8 + row
;   0..$3F        note: semitones above the keyboard's base C
;   $40+cmd       command, $60+cmd: SHIFT gives cmd+1
;   $FF           nothing
KN = KEY_NONE
KC = KEY_CMD
KS = KEY_CMD | KEY_SHIFTABLE
key_map
        ;     DEL RETURN  CRSR-RT          F7             F1                F3              F5            CRSR-DN
        .byte KC|CMD_UNLEARN, KC|CMD_LEARN, KS|CMD_VALUE_UP,  KS|CMD_SYNTH,    KS|CMD_PARAM_NEXT, KS|CMD_VALUE_UP, KS|CMD_OCT_UP, KS|CMD_PARAM_NEXT
        ;     3   W   A  4  Z  S  E   LSHIFT
        .byte 15, 14, KN, KN, 0, 1, 16, KN
        ;     5   R   D  6   C  F  T   X
        .byte 18, 17, 3, 20, 4, KN, 19, 2
        ;     7   Y   G  8  B  H  U   V
        .byte 22, 21, 6, KN, 7, 8, 23, 5
        ;     9   I   J   0   M   K  O   N
        .byte 25, 24, 10, 27, 11, KN, 26, 9
        ;     +               P   L   -                 .   :  @   ,
        .byte KC|CMD_VALUE_UP, 28, 13, KC|CMD_VALUE_DOWN, 14, KN, 29, 12
        ;     pound *  ;   HOME RSHIFT =  UP /
        .byte KN,    KN, 15, KN,   KN,     KN, KN, 16
        ;     1  <-  CTRL 2   SPACE C=  Q   RUN/STOP
        .byte KN, KN,  KN,   13, KN,    KN,  12, KC|CMD_PANIC
