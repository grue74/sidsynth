; test_scripts.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; scripts for core/test_keys.asm (TEST_KEYS builds)
.if TEST_KEYS
.if TEST_KEYS == 1
; expected end state: sel_param 16, cutoff 80, MIDI i/face 1, octave 2,
; the parameter screen (F7 went to the step screen and back), no notes held
test_key_script
        .byte 10, $ff                           ; settle
        .for i := 0, i < 2, i += 1              ; F1 x2: select 2
        #tap TK_F1
        .endfor
        .for i := 0, i < 3, i += 1              ; F2 x3: 1, 0, wrap to 20
        #stap TK_F1
        .endfor
        #tap TK_F1                              ; wrap to 0 (cutoff)
        .byte 200, TK_F3, $ff, 2, $ff           ; hold F3: repeat up to 255
        .byte 200, TK_SHIFT, TK_F3, $ff, 2, $ff ; hold F4: down to 0
        .for i := 0, i < 20, i += 1             ; F3 x20: 80
        #tap TK_F3
        .endfor
        .for i := 0, i < 5, i += 1              ; F2 x5: 20, 19, 18, 17, 16 (MIDI i/face)
        #stap TK_F1
        .endfor
        .for i := 0, i < 4, i += 1              ; F3 x4: 2, 3, 4, 4
        #tap TK_F3
        .endfor
        .for i := 0, i < 4, i += 1              ; F4 x4: 3, 2, 1, 0 (Off)
        #stap TK_F3
        .endfor
        #tap TK_F3                              ; back to 1 (Sequential)
        .for i := 0, i < 6, i += 1              ; F5 x6: octave 6 (max)
        #tap TK_F5
        .endfor
        .for i := 0, i < 8, i += 1              ; F6 x8: octave 0 (min)
        #stap TK_F5
        .endfor
        .for i := 0, i < 2, i += 1              ; F5 x2: octave 2
        #tap TK_F5
        .endfor
        .byte 40, TK_Z, $ff                     ; C2
        .byte 40, TK_Z, TK_X, $ff               ; + D2 while C2 held: slide
        .byte 20, $ff
        .byte 30, TK_SHIFT, TK_C, $ff           ; accented E2
        .byte 20, $ff
        #tap TK_F7                              ; the step screen
        .byte 20, $ff
        #tap TK_F7                              ; back to the parameters
        #tap TK_STOP
        .byte 0
.elsif TEST_KEYS == 4
; TEST_KEYS=4: open the step screen and stay there (screenshots)
test_key_script
        .byte 10, $ff                           ; settle
        #tap TK_F7                              ; the step screen
        .byte 0
.elsif TEST_KEYS == 5
; TEST_KEYS=5: play and stop from the step screen (tools/seq_check.py, with
; TEST_LOG): F7, RUN/STOP, pattern 1 for ~1 s, then F7 to the parameter
; screen and F7 back while it plays, ~1 s more, RUN/STOP. Expected: notes
; played, none left sounding after the stop, and no ticks falling behind
; while the screens switch (LOG_LAG).
test_key_script
        .byte 10, $ff                           ; settle
        #tap TK_F7                              ; the step screen
        .byte 40, $ff                           ; (its frame drawn)
        #tap TK_STOP                            ; play
        .byte 60, $ff                           ; 1 s
        #tap TK_F7                              ; the parameter screen, playing
        .byte 30, $ff
        #tap TK_F7                              ; and back
        .byte 60, $ff                           ; 1 s
        #tap TK_STOP                            ; stop
        .byte 0
.elsif TEST_KEYS == 6
; TEST_KEYS=6: editing on the step screen (tools/seq_check.py reads the
; result from memory). Expected, stopped throughout:
;   pattern 2 ($8100): notes 36 38 0 0 42 41 48, flags 0 5 2 0 13 1 1,
;     length 7 (step 1 entered, then made a rest by DEL: its note stays)
;   pattern 3 ($8200): the copy of pattern 2 before the DEL: flags 1 5 2 0 13 1 1
;   pattern 4 ($8300): cleared (a note entered, then CLR): all 0, length 16
;   edit_pat 1, cur_step 0, kb_octave 3, tempo 128, swing 2, seq_next 1,
;   no note held (the auditions' releases reached the core)
KS_V      = 3*8+7
KS_A      = 1*8+2
KS_F      = 2*8+5
KS_EQUALS = 6*8+5
KS_SPACE  = 7*8+4
KS_HOME   = 6*8+3
KS_PLUS   = 5*8+0
KS_MINUS  = 5*8+3
KS_DOWN   = 7
KS_RIGHT  = 2
KS_CBM    = 7*8+5
test_key_script
        .byte 10, $ff                           ; settle
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
        #tap TK_F1                              ; pattern 2 (empty)
        #tap TK_Z                               ; step 1: C-2 (36)
        #stap TK_X                              ; step 2: D-2 accented
        #tap KS_EQUALS                          ; step 3: tie
        #tap KS_SPACE                           ; step 4: rest
        #tap TK_C                               ; step 5: E-2 (40)
        #stap KS_DOWN                           ; back up to step 5
        #tap KS_F                               ; slide on
        #tap KS_A                               ; accent on
        #tap KS_RIGHT                           ; E-2 -> F-2
        #tap KS_RIGHT                           ; -> F#2 (42)
        #tap KS_DOWN                            ; step 6
        #tap KS_V                               ; step 6: F-2 (41)
        .for i := 0, i < 10, i += 1             ; length 16 -> 6
        #tap KS_MINUS
        .endfor
        #tap KS_PLUS                            ; -> 7
        #tap TK_F5                              ; entry octave 3
        #tap TK_Z                               ; step 7: C-3 (48)
        .byte 2, KS_CBM, TK_C, $ff, 2, $ff      ; C=+C: copy to pattern 3, show it
        #tap TK_F1                              ; pattern 4
        #tap TK_Z                               ; a note ...
        #stap KS_HOME                           ; ... CLR: cleared
        #stap TK_F1                             ; pattern 3
        #stap TK_F1                             ; pattern 2
        #tap KS_HOME                            ; cursor to step 1
        #tap TK_DEL                             ; step 1: rest
        .for i := 0, i < 3, i += 1              ; tempo 128
        #tap TK_F3
        .endfor
        .for i := 0, i < 2, i += 1              ; swing 2
        .byte 2, KS_CBM, TK_F3, $ff, 2, $ff
        .endfor
        .byte 0
.elsif TEST_KEYS == 7
; TEST_KEYS=7: no stuck notes from the step screen's auditions
; (tools/seq_check.py). X (D-2) held on the parameter screen through F7 and
; let go on the step screen; then Z held on the step screen (it enters C-2
; at step 1 and plays it) while RUN/STOP starts the pattern, let go while it
; plays, RUN/STOP. Expected: D-2 and the auditioned C-2 each get their note
; off; at the end no note held and the gate closed.
test_key_script
        .byte 10, $ff                           ; settle
        .byte 10, TK_X, $ff                     ; hold X: D-2 plays
        .byte 2, TK_X, TK_F7, $ff               ; F7 while held
        .byte 40, TK_X, $ff                     ; the step screen draws
        .byte 4, $ff                            ; let go: D-2 off (through the core)
        .byte 4, TK_Z, $ff                      ; hold Z: C-2 at step 1, plays
        .byte 2, TK_Z, TK_STOP, $ff             ; play while held
        .byte 60, TK_Z, $ff
        .byte 4, $ff                            ; let go while playing: C-2 off
        .byte 60, $ff
        #tap TK_STOP                            ; stop
        .byte 0
.elsif TEST_KEYS == 8
; TEST_KEYS=8: undo, redo and the song keys (tools/seq_check.py reads the
; result from memory). Expected:
;   pattern 2 ($8100): notes 36 38, flags 1 1, length 15
;   the song: 2 entries, patterns 1 0, repeats 3 1, transposes +2 0;
;   song mode on, song cursor 1
;   undo_count 13, undo_redo 1, no message (C=+S cleared it)
KU_A      = 1*8+2
KU_HOME   = 6*8+3
KU_MINUS  = 5*8+3
KU_PLUS   = 5*8+0
KU_CBM    = 7*8+5
KU_U      = 3*8+6
KU_P      = 5*8+1
KU_COMMA  = 5*8+7
KU_PERIOD = 5*8+4
KU_SEMI   = 6*8+2
KU_S      = 1*8+5
KU_LEFT   = 7*8+1
ctap    .macro                  ; C= and a key for 2 scans, release for 2
        .byte 2, KU_CBM, \1, $ff, 2, $ff
        .endm
cstap   .macro                  ; C=, SHIFT and a key
        .byte 2, KU_CBM, TK_SHIFT, \1, $ff, 2, $ff
        .endm
test_key_script
        .byte 10, $ff                           ; settle
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
        #tap TK_F1                              ; pattern 2
        #tap TK_Z                               ; 1: step 1 C-2
        #tap TK_X                               ; 2: step 2 D-2
        #tap KU_HOME
        #tap KU_A                               ; 3: step 1 accent on
        #tap KU_A                               ; 4: off
        #tap TK_DEL                             ; 5: step 1 rest
        #ctap KU_U                              ; undo 5: C-2 again
        #ctap KU_U                              ; undo 4: accented (flags 5)
        #cstap KU_U                             ; redo 4: not accented (flags 1)
        #tap KU_PLUS                            ; length 16 already: no undo step
        #tap KU_MINUS                           ; 5: length 15 (redo gone)
        #cstap KU_U                             ; nothing to redo
        #ctap KU_P                              ; 6: song entry 1 = pattern 2, cursor 2
        #ctap KU_COMMA                          ; song cursor 1
        #ctap KU_SEMI                           ; 7: repeats 2
        #ctap KU_SEMI                           ; 8: repeats 3
        #ctap KU_PLUS                           ; 9: transpose +1
        #ctap KU_PLUS                           ; 10: +2
        #ctap KU_PLUS                           ; 11: +3
        #ctap KU_MINUS                          ; 12: +2
        #ctap KU_PERIOD                         ; song cursor 2 (the end)
        #stap TK_F1                             ; pattern 1
        #ctap KU_P                              ; 13: song entry 2 = pattern 1, cursor 3
        #tap KU_LEFT                            ; at the end: nothing to delete
        #ctap KU_COMMA                          ; song cursor 2
        #tap KU_LEFT                            ; 14: entry 2 deleted
        #ctap KU_U                              ; undo 14: back
        #ctap KU_S                              ; song mode on (clears the message)
        .byte 0
.elsif TEST_KEYS == 13
; TEST_KEYS=13: save while pattern 1 plays (from a .d64, tools/seq_check.py).
; Expected: the save stops the sequencer first; afterwards stopped, no
; note held, the gate closed, the drive's "00, OK,00,00".
test_key_script
        .byte 20, $ff                           ; settle
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
        #tap TK_STOP                            ; play
        .byte 50, $ff
        .byte 2, 7*8+5, 1*8+1, $ff, 2, $ff      ; C=+W: save "song"
        #tap TK_RETURN
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 21 || TEST_KEYS == 22
; TEST_KEYS=21, 22: SysEx dumps from the keys (tools/dump_check.py, from a
; .d64 with the program as "SID303", drive emulation on, TEST_SYSEX
; capture). Expected: the dump sent equals the file saved, byte for byte
;  21: the step screen: save the song as "t1", then C= + M (the song)
;  22: the parameter screen: save the bank as "b1", then C= + M (the bank)
KX_CBM    = 7*8+5
KX_W      = 1*8+1
KX_M      = 4*8+4
KX_T      = 2*8+6
KX_B      = 3*8+4
KX_1      = 7*8+0
xtap    .macro                  ; C= and a key
        .byte 2, KX_CBM, \1, $ff, 2, $ff
        .endm
test_key_script
        .byte 20, $ff                           ; settle
.if TEST_KEYS == 21
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
.endif
        #xtap KX_W                              ; save: the prompt ("song" / "bank")
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
.if TEST_KEYS == 21
        #tap KX_T                               ; "t1"
.else
        #tap KX_B                               ; "b1"
.endif
        #tap KX_1
        #tap TK_RETURN
        .byte 30, $ff
        #xtap KX_M                              ; the dump
        .byte 0
.elsif TEST_KEYS >= 16 && TEST_KEYS <= 19
; TEST_KEYS=16..19: the presets on the parameter screen (tools/preset_check.py;
; 17..19 from a .d64 with the program as "SID303", drive emulation on)
;  16: C= + F3 three times (slot 4), C= + SHIFT + F3 (slot 3); store: C= +
;      RETURN, F3 (slot 4), the name deleted, "Abc" typed (SHIFT on the A),
;      RETURN. Then Z held while C= + RETURN opens the prompt, let go in it
;      (its note ends), RUN/STOP; C= + RETURN, X pressed in the prompt and
;      held while RUN/STOP cancels, let go after (no note); X played once.
;      Expected: slot 4 = slot 3's values, named "Abc", the current one,
;      not edited; the notes: Z on and off, X on and off once.
;  17: save the bank ("bank"); store the sound into slot 1 named "z"; load
;      the bank. Expected: slot 1 "Classic acid" again, the drive's "00,
;      OK,00,00", the sound edited, the song's name still "song"
;  18: save the bank as "b"; on the step screen load "b" as a song: NOT A
;      SID101 FILE, nothing changed
;  19: load "sid303" (the program) as a bank: NOT A SID303 BANK, the
;      presets unchanged
KP_CBM    = 7*8+5
KP_W      = 1*8+1
KP_L      = 5*8+2
KP_A      = 1*8+2
KP_B      = 3*8+4
KP_C      = 2*8+4
KP_S      = 1*8+5
KP_I      = 4*8+1
KP_D      = 2*8+2
KP_1      = 7*8+0
KP_0      = 4*8+3
KP_3      = 1*8+0
ptap    .macro                  ; C= and a key
        .byte 2, KP_CBM, \1, $ff, 2, $ff
        .endm
pstap   .macro                  ; C=, SHIFT and a key
        .byte 2, KP_CBM, TK_SHIFT, \1, $ff, 2, $ff
        .endm
test_key_script
        .byte 20, $ff                           ; settle
.if TEST_KEYS == 16
        #ptap TK_F3                             ; slot 2
        #ptap TK_F3                             ; 3
        #ptap TK_F3                             ; 4
        #pstap TK_F3                            ; back to 3
        #ptap TK_RETURN                         ; store: slot 3, its name
        #tap TK_F3                              ; slot 4
        .for i := 0, i < 12, i += 1
        #tap TK_DEL
        .endfor
        #stap KP_A                              ; "A"
        #tap KP_B                               ; "b"
        #tap KP_C                               ; "c"
        #tap TK_RETURN                          ; stored
        .byte 10, $ff
        .byte 10, TK_Z, $ff                     ; Z held: its note
        .byte 2, TK_Z, KP_CBM, TK_RETURN, $ff   ; ... and C= + RETURN: the prompt
        .byte 4, TK_Z, $ff
        .byte 10, $ff                           ; Z let go in the prompt: its note ends
        #tap TK_STOP                            ; cancel
        #ptap TK_RETURN                         ; the prompt again
        .byte 4, TK_X, $ff                      ; X pressed in it
        .byte 2, TK_X, TK_STOP, $ff             ; RUN/STOP cancels, X still held
        .byte 4, TK_X, $ff
        .byte 10, $ff                           ; X let go: no note
        .byte 6, TK_X, $ff                      ; X played once
        .byte 10, $ff
.elsif TEST_KEYS == 17
        #ptap KP_W                              ; save the bank: the prompt ("bank")
        #tap TK_RETURN
        .byte 30, $ff
        #ptap TK_RETURN                         ; store into slot 1 ...
        .for i := 0, i < 12, i += 1
        #tap TK_DEL
        .endfor
        #tap TK_Z                               ; ... named "z"
        #tap TK_RETURN
        .byte 10, $ff
        #ptap KP_L                              ; load the bank
        #tap TK_RETURN
        .byte 30, $ff
.elsif TEST_KEYS == 18
        #ptap KP_W                              ; save the bank as "b"
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
        #tap KP_B
        #tap TK_RETURN
        .byte 30, $ff
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
        #ptap KP_L                              ; load "b" as a song
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
        #tap KP_B
        #tap TK_RETURN
        .byte 30, $ff
.else
        #ptap KP_L                              ; load the program as a bank
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
        #tap KP_S                               ; "sid303"
        #tap KP_I
        #tap KP_D
        #tap KP_3
        #tap KP_0
        #tap KP_3
        #tap TK_RETURN
        .byte 30, $ff
.endif
        .byte 0
.elsif TEST_KEYS >= 9 && TEST_KEYS <= 12
; TEST_KEYS=9..12: disk (tools/seq_check.py runs them from a .d64 with the
; program as "SID303", drive emulation on). Start on the parameter screen.
;   9: Cutoff 100; the step screen; song entry 1 = pattern 1; save "T1";
;      then clear pattern 1, tempo 126, delete the song entry, Cutoff 108;
;      load "T1". Expected: pattern 1 the acid line again, tempo 125, the
;      song entry back, Cutoff 100, the drive's "00, OK,00,00", nothing
;      to undo
;  10: load "SID303" (the program): NOT A SID303 FILE, nothing changed
;  11: load "XX": the drive's "62, FILE NOT FOUND,00,00"
;  12: Disk drive 9 (no such drive): load: NO DRIVE 9
KD_W      = 1*8+1
KD_L      = 5*8+2
KD_T      = 2*8+6
KD_1      = 7*8+0
KD_S      = 1*8+5
KD_I      = 4*8+1
KD_D      = 2*8+2
KD_3      = 1*8+0
KD_0      = 4*8+3
KD_X      = 2*8+7
KD_P      = 5*8+1
KD_COMMA  = 5*8+7
KD_HOME   = 6*8+3
KD_LEFT   = 7*8+1
KD_CBM    = 7*8+5
dtap    .macro                  ; C= and a key
        .byte 2, KD_CBM, \1, $ff, 2, $ff
        .endm
test_key_script
        .byte 20, $ff                           ; settle
.if TEST_KEYS == 9
        .for i := 0, i < 5, i += 1              ; Cutoff 80 -> 100
        #tap TK_F3
        .endfor
.elsif TEST_KEYS == 12
        #stap TK_F1                             ; from Cutoff back to Disk drive
        #tap TK_F3                              ; drive 9
.endif
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
.if TEST_KEYS == 9
        #dtap KD_P                              ; song entry 1 = pattern 1
        #dtap KD_W                              ; save: the prompt ("song")
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
        #tap KD_T
        #tap KD_1                               ; "t1"
        #tap TK_RETURN                          ; save
        .byte 30, $ff
        #stap KD_HOME                           ; CLR pattern 1
        #tap TK_F3                              ; tempo 126
        #dtap KD_COMMA                          ; song cursor to entry 1
        #tap KD_LEFT                            ; delete it
        #tap TK_F7                              ; the parameter screen
        .byte 40, $ff
        #tap TK_F3                              ; Cutoff 104
        #tap TK_F3                              ; 108
        #tap TK_F7                              ; the step screen
        .byte 40, $ff
        #dtap KD_L                              ; load: the prompt ("t1")
        #tap TK_RETURN
        .byte 30, $ff
.else
        #dtap KD_L                              ; load: the prompt ("song")
        .for i := 0, i < 4, i += 1
        #tap TK_DEL
        .endfor
.if TEST_KEYS == 10
        #tap KD_S                               ; "sid303"
        #tap KD_I
        #tap KD_D
        #tap KD_3
        #tap KD_0
        #tap KD_3
.else
        #tap KD_X                               ; "xx"
        #tap KD_X
.endif
        #tap TK_RETURN
        .byte 30, $ff
.endif
        .byte 0
.elsif TEST_KEYS == 14
; TEST_KEYS=14: the step sequencer demo (demos/step_demo.py records it).
; The parameter screen; F7 to the step screen; pattern 2, empty; a 16-step
; acid loop typed in at about four keys a second (each note plays as it is
; entered); play; on the parameter screen, while it plays, the sound made
; harsher a control at a time (Resonance 15, Env mod 255, Decay 3, Accent
; 15, Saw+square, Low+band), then the cutoff closed, opened wide and
; brought half way back; it ends there, playing. Scans: 62.5 a second.
KV_N      = 4*8+7               ; A (9 semitones above the Z key)
KV_Y      = 3*8+1               ; A an octave up
KV_T      = 2*8+6               ; G an octave up
KV_Q      = 7*8+6               ; C an octave up
KV_E      = 1*8+6               ; E an octave up
KV_W      = 1*8+1               ; D an octave up
KV_B      = 3*8+4               ; G
KV_F      = 2*8+5               ; slide
KV_SPACE  = 7*8+4               ; rest
KV_EQUALS = 6*8+5               ; tie
kt      .macro                  ; a key at typing speed: held 4 scans, 10 between
        .byte 4, \1, $ff, 10, $ff
        .endm
kst     .macro                  ; the same with SHIFT (an accented note)
        .byte 4, TK_SHIFT, \1, $ff, 10, $ff
        .endm
kn      .macro                  ; a quick key (moving the cursor)
        .byte 3, \1, $ff, 5, $ff
        .endm
kns     .macro                  ; the same with SHIFT
        .byte 3, TK_SHIFT, \1, $ff, 5, $ff
        .endm
test_key_script
        .byte 90, $ff                           ; the parameter screen, 1.4 s
        #kt TK_F7                               ; the step screen (pattern 1: the demo line)
        .byte 60, $ff
        #kt TK_F1                               ; pattern 2: empty
        .byte 40, $ff
        .byte 4, TK_SHIFT, TK_F5, $ff, 30, $ff  ; F6: the note keys an octave down (Z = C-1)
        #kst KV_N                               ;  1 A-1 accent
        #kt KV_N                                ;  2 A-1
        #kt KV_F                                ;  3 slide ...
        #kt KV_Y                                ;    ... A-2
        #kt KV_T                                ;  4 G-2
        #kt KV_SPACE                            ;  5 rest
        #kt KV_N                                ;  6 A-1
        #kst KV_Q                               ;  7 C-2 accent
        #kt KV_N                                ;  8 A-1
        #kt KV_EQUALS                           ;  9 tie
        #kt KV_F                                ; 10 slide ...
        #kt KV_E                                ;    ... E-2
        #kt KV_W                                ; 11 D-2
        #kt KV_N                                ; 12 A-1
        #kt KV_SPACE                            ; 13 rest
        #kst KV_Y                               ; 14 A-2 accent
        #kt KV_F                                ; 15 slide ...
        #kt KV_B                                ;    ... G-1
        #kt KV_N                                ; 16 A-1
        .byte 40, $ff
        #kt TK_STOP                             ; play
        .byte 240, $ff                          ; two bars
        #kt TK_F7                               ; the parameter screen (on Cutoff),
        .byte 40, $ff                           ; playing on
        ; harsher, a control at a time (a bar or so to hear each)
        #kn TK_F1                               ; Resonance 12 ...
        .for i := 0, i < 3, i += 1
        #kt TK_F3                               ; ... 15
        .endfor
        .byte 90, $ff
        #kn TK_F1                               ; Env mod 160 ...
        .byte 100, TK_F3, $ff, 2, $ff           ; ... held up to 255
        .byte 90, $ff
        #kn TK_F1                               ; (Env mod type)
        #kn TK_F1                               ; Decay 6 ...
        .for i := 0, i < 3, i += 1
        #kst TK_F3                              ; ... 3: shorter
        .endfor
        .byte 90, $ff
        #kn TK_F1                               ; Accent 10 ...
        .for i := 0, i < 5, i += 1
        #kt TK_F3                               ; ... 15
        .endfor
        .byte 90, $ff
        .for i := 0, i < 3, i += 1              ; (Slide time, Amp decay)
        #kn TK_F1                               ; Waveform Saw ...
        .endfor
        #kt TK_F3                               ; ... Square
        #kt TK_F3                               ; ... Saw+square: buzzier
        .byte 120, $ff
        .for i := 0, i < 5, i += 1              ; (Pulse width, Square tilt, Body, Tune)
        #kn TK_F1                               ; Filter Low-pass ...
        .endfor
        #kt TK_F3                               ; ... Low+band: a stronger peak
        .byte 120, $ff
        ; and the cutoff again
        .for i := 0, i < 13, i += 1             ; back up to Cutoff
        #kns TK_F1
        .endfor
        .byte 30, $ff
        .byte 80, TK_SHIFT, TK_F3, $ff, 2, $ff  ; hold F4: closed down
        .byte 60, $ff
        .byte 220, TK_F3, $ff, 2, $ff           ; hold F3: wide open
        .byte 60, $ff
        .byte 110, TK_SHIFT, TK_F3, $ff, 2, $ff ; hold F4: half way back
        .byte 250, $ff                          ; playing to the end
        .byte 0
.elsif TEST_KEYS == 3
; TEST_KEYS=3: paddle learn, together with TEST_PADDLES=1 (paddle X turns by
; one step per scan from $FF down to 0, then stops; Y stays unplugged).
; Expected end state: paddle X on Decay ("X" on its row) and Decay 15 (X
; fully clockwise); Cutoff frozen around 50 where X left it, still CC 74,
; no "X"; Resonance 12 with no paddle and no controller (DEL); sel_param 1.
test_key_script
        .byte 31, $ff                           ; 0.0 X turns: cutoff follows
        .for i := 0, i < 4, i += 1              ; 0.5 select Decay (4)
        #tap TK_F1
        .endfor
        #tap TK_RETURN                          ;     learn: X moves next -> Decay
        .byte 40, $ff                           ;     Decay follows X, cutoff stays
        .for i := 0, i < 3, i += 1              ; 1.6 back to Resonance (1)
        #stap TK_F1
        .endfor
        #tap TK_DEL                             ;     remove paddle Y and CC 71
        .byte 0
.else
; TEST_KEYS=2: MIDI learn, together with the TEST_MIDI=3 controller pattern
; (times in seconds from start; 62.5 scans per second). Expected end state:
; cc_map[1] = 8 (waveform), [21] = 1 (resonance), [71], [74], [12], [22] =
; $FF; cutoff 20, resonance 15, env mod 160, waveform 3 (303 square);
; sel_param 0 with learn mode on ("???" on the cutoff row).
test_key_script
        .byte 31, $ff                           ; 0.0 settle
        #tap TK_RETURN                          ; 0.5 learn cutoff
        .byte 90, $ff                           ;     1.0 CC21 -> cutoff 20, 1.5 CC74 (now unassigned)
        #tap TK_F1                              ; 2.0 select resonance
        #tap TK_RETURN                          ;     learn
        .byte 55, $ff                           ;     2.5 CC21 -> moves to resonance = 15
        #tap TK_F1                              ; 3.0 select env mod
        #tap TK_DEL                             ;     remove its controller (CC12)
        .byte 54, $ff                           ;     3.5 CC12 = 0: no effect
        .for i := 0, i < 6, i += 1              ; 4.0 select waveform (8)
        #tap TK_F1
        .endfor
        #tap TK_RETURN                          ;     learn
        .byte 35, $ff                           ;     4.5 CC1 = 127 -> 303 square
        .for i := 0, i < 7, i += 1              ; 5.0 select MIDI channel (15)
        #tap TK_F1
        .endfor
        #tap TK_RETURN                          ;     refused: not learnable
        .byte 30, $ff                           ;     5.5 CC22: no effect
        .for i := 0, i < 15, i += 1             ; 6.0 back to cutoff (0)
        #stap TK_F1
        .endfor
        #tap TK_RETURN                          ;     learn, left on
        .byte 0
.endif
.endif
