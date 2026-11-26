; test_scripts.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; scripts for core/test_keys.asm (TEST_KEYS builds); entry: scans to hold,
; key codes..., $FF; hold 0 = end. #tap / #stap: a key / with SHIFT.
.if TEST_KEYS
.if TEST_KEYS == 1
; Step grid editing. Expected end state (check with c64tools/vicepeek.py):
;   pattern 2 ($8100): Kck step 1 = 3 (accent), Kck step 5 = 1 (soft),
;                      Snr step 5 = 2 (normal), every other cell 0, length 12
;   pattern 3 ($8200): the same, but Snr step 5 = 0
;   mute = $0002 (Snr), seq_bpm = 130, seq_swing = 3, edit_pat = 2,
;   seq_play = 1, screen_owner = 0 (the parameter screen)
test_key_script
        .byte 20, $ff                           ; settle on the grid
        #tap KC_F1                              ; pattern 2
        #stap KC_HOME                           ; CLR: clear it
        #tap KC_3                               ; Kck step 1 accent, cursor to step 2
        .for _i := 0, _i < 3, _i += 1           ; to step 5
        #tap KC_CRSR_RIGHT
        .endfor
        #tap KC_1                               ; Kck step 5 soft, cursor to step 6
        #tap KC_CRSR_DOWN                       ; Snr
        #stap KC_CRSR_RIGHT                     ; back to step 5
        #tap KC_SPACE                           ; on (normal)
        #tap KC_SPACE                           ; off
        #tap KC_SPACE                           ; on
        .for _i := 0, _i < 4, _i += 1           ; length 16 -> 12
        #tap KC_MINUS
        .endfor
        #tap KC_M                               ; mute Snr
        .for _i := 0, _i < 5, _i += 1           ; 125 -> 130 BPM
        #tap KC_F3
        .endfor
        .for _i := 0, _i < 3, _i += 1           ; swing 3
        #tap KC_F5
        .endfor
        #tap KC_C                               ; copy to pattern 3, show it
        #tap KC_DEL                             ; Snr step 5 off there
        #tap KC_STOP                            ; play
        #tap KC_F7                              ; parameter screen
        .byte 0                                 ; end
.endif
.if TEST_KEYS == 2
; Editing while playing: pattern 1 plays; F1 about four steps in queues
; pattern 2, which must start at the next bar start (step 0); then its
; length goes 16 -> 4 quicker than it plays: the step must wrap below the
; new length at once. Check: log seq_pat/seq_step at each step.
test_key_script
        .byte 20, $ff                           ; settle
        #tap KC_STOP                            ; play pattern 1
        .byte 26, $ff                           ; ~4 steps (a step is 7.5 scans at 125 BPM)
        #tap KC_F1                              ; queue pattern 2
        .byte 150, $ff                          ; into pattern 2's first bar
        .for _i := 0, _i < 12, _i += 1          ; length 16 -> 4, a tap per ~half step
        #tap KC_MINUS
        .endfor
        .byte 200, $ff                          ; play on
        .byte 0
.endif
.if TEST_KEYS == 3
; Worst case for the CPU: every sound accented on step 1 of the empty
; pattern 64, played (measure the longest tick in a scratch build).
test_key_script
        .byte 20, $ff                           ; settle
        #stap KC_F1                             ; F2: pattern 64 (empty)
        .for _i := 0, _i < NUM_SOUNDS, _i += 1
        #tap KC_3                               ; accent, cursor right
        #stap KC_CRSR_RIGHT                     ; back to step 1
        #tap KC_CRSR_DOWN                       ; next sound
        .endfor
        #tap KC_STOP                            ; play
        .byte 250, $ff
        .byte 0
.endif
.if TEST_KEYS == 4
; Song mode: build the song [pattern 1 x2, pattern 2 x1] (a third entry
; added, then deleted), song mode on, play. Expected: song_len = 2,
; song_pat = 0, 1, song_rep = 2, 1; pattern starts 1, 1, 2, 1, 1, 2, ...
test_key_script
        .byte 20, $ff                           ; settle
        #tap KC_P                               ; entry 1 = pattern 1, cursor on
        #tap KC_COMMA                           ; back to entry 1
        #tap KC_SEMICOLON                       ; 2 repeats
        #tap KC_PERIOD                          ; to the end
        #tap KC_F1                              ; pattern 2
        #tap KC_P                               ; entry 2 = pattern 2
        #tap KC_F1                              ; pattern 3
        #tap KC_P                               ; entry 3 = pattern 3
        #tap KC_COMMA                           ; back to entry 3
        #tap KC_ARROW_LEFT                      ; delete it
        #tap KC_S                               ; song mode on
        #tap KC_STOP                            ; play
        .for _i := 0, _i < 6, _i += 1
        .byte 250, $ff                          ; ~2 bars each
        .endfor
        .byte 0
.endif
.if TEST_KEYS == 5
; Disk round trip (on a disk with the program): song entry 1 = pattern 1,
; save "T1"; then clear pattern 1, tempo 126, delete the song entry; load
; "T1". Expected: pattern 1 = MAIN again, seq_bpm = 125, song_len = 1,
; song_pat = 0; disk_msg the drive's "00, OK,00,00".
test_key_script
        .byte 20, $ff                           ; settle
        #tap KC_P                               ; song entry 1 = pattern 1
        #tap KC_W                               ; save: the name prompt ("SONG")
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_T
        #tap KC_1                               ; "T1"
        #tap KC_RETURN                          ; save
        .byte 30, $ff
        #stap KC_HOME                           ; CLR pattern 1
        #tap KC_F3                              ; tempo 126
        #tap KC_COMMA                           ; song cursor to entry 1
        #tap KC_ARROW_LEFT                      ; delete it
        #tap KC_L                               ; load: the prompt ("T1")
        #tap KC_RETURN
        .byte 30, $ff
        .byte 0
.endif
.if TEST_KEYS == 6
; Load a file that isn't SID808's (the program itself): an error shown,
; memory unchanged (pattern 1 = MAIN, tempo 125).
test_key_script
        .byte 20, $ff
        #tap KC_L
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_S
        #tap KC_I
        #tap KC_D
        #tap KC_8
        #tap KC_0
        #tap KC_8                               ; "SID808"
        #tap KC_RETURN
        .byte 30, $ff
        .byte 0
.endif
.if TEST_KEYS == 7
; Load a file that isn't there: the drive's "62, FILE NOT FOUND".
test_key_script
        .byte 20, $ff
        #tap KC_L
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_N
        #tap KC_O
        #tap KC_N
        #tap KC_E                               ; "NONE"
        #tap KC_RETURN
        .byte 30, $ff
        .byte 0
.endif
.if TEST_KEYS == 8
; MIDI out across a disk operation (with TEST_MIDIOUT=1, on a disk): play,
; save "SONG" while playing (the sequencer stops: MIDI stop must go out
; first), play again: start and clocks must come out again (the interrupt
; handlers set up afresh).
test_key_script
        .byte 20, $ff
        #tap KC_STOP                            ; play
        .byte 40, $ff
        #tap KC_W
        #tap KC_RETURN                          ; save "SONG"
        .byte 20, $ff
        #tap KC_STOP                            ; play again
        .byte 60, $ff
        .byte 0
.endif
.if TEST_KEYS == 9
; The sound page: grid cursor to Snare, the parameter screen; Level -3
; (12), Tune +2 (14), Decay -1 (7), Tone +1 (9); then the Sound parameter
; +1 (Clap). Expected: knob_level/tune/decay/tone of Snare (1) = 12, 14, 7,
; 9; params: Sound 2, Level/Tune/Decay/Tone = Clap's defaults 15, 12, 8, 8;
; cur_row 2.
test_key_script
        .byte 20, $ff
        #tap KC_CRSR_DOWN                       ; Snare
        #tap KC_F7                              ; parameter screen
        .byte 10, $ff
        #tap KC_F1                              ; Level
        .for _i := 0, _i < 3, _i += 1
        #stap KC_F3                             ; F4: down
        .endfor
        #tap KC_F1                              ; Tune
        #tap KC_F3
        #tap KC_F3
        #tap KC_F1                              ; Decay
        #stap KC_F3
        #tap KC_F1                              ; Tone
        #tap KC_F3
        #tap KC_F1                              ; Sound
        #tap KC_F3                              ; Clap
        .byte 20, $ff
        .byte 0
.endif
.if TEST_KEYS == 10
; Knobs on disk (version 2): Kick's Level 10, save "K2"; Level back to 15;
; load "K2". Expected: knob_level of Kick = 10, the drive's 00, OK.
test_key_script
        .byte 20, $ff
        #tap KC_F7                              ; parameter screen
        .byte 10, $ff
        #tap KC_F1                              ; Level (of Kick)
        .for _i := 0, _i < 5, _i += 1
        #stap KC_F3                             ; 15 -> 10
        .endfor
        #tap KC_F7                              ; the grid
        .byte 10, $ff
        #tap KC_W
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_K
        #tap KC_2                               ; "K2"
        #tap KC_RETURN
        .byte 30, $ff
        #tap KC_F7
        .byte 10, $ff
        .for _i := 0, _i < 5, _i += 1
        #tap KC_F3                              ; 10 -> 15 (Level still selected)
        .endfor
        #tap KC_F7
        .byte 10, $ff
        #tap KC_L                               ; "K2"
        #tap KC_RETURN
        .byte 30, $ff
        .byte 0
.endif
.if TEST_KEYS == 11
; A version 1 file (saved by the build before the knobs as "T1"): loads,
; the knobs go to their defaults (build with TEST_LEVEL=3 to see it).
test_key_script
        .byte 20, $ff
        #tap KC_L
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_T
        #tap KC_1                               ; "T1"
        #tap KC_RETURN
        .byte 30, $ff
        .byte 0
.endif
.if TEST_KEYS == 12
; Undo and redo (src/undo.asm), on pattern 1 (MAIN: Kck step 1 accent, Snr
; step 5 accent). Expected: Kck step 1 ($8000) = 0, Snr step 5 ($8014) = 3
; (the clear undone), song_len = 1, undo_count = 2, undo_redo = 1; the song
; row "UNDO, 2 MORE LEFT".
test_key_script
        .byte 20, $ff
        #tap KC_SPACE                           ; Kck step 1: 3 -> 0      (1 step)
        #tap KC_2                               ; Kck step 1: 0 -> 2      (2 steps)
        #tap KC_U                               ; undo: 0
        #tap KC_U                               ; undo: 3
        #tap KC_U                               ; nothing to undo
        #stap KC_U                              ; redo: 0                 (1 step, 1 redo)
        #tap KC_P                               ; the song: 1 entry       (2 steps, redo gone)
        #tap KC_U                               ; undo: no entry
        #stap KC_U                              ; redo: 1 entry           (2 steps)
        #stap KC_HOME                           ; CLR: pattern cleared    (3 steps)
        #tap KC_U                               ; undo: back              (2 steps, 1 redo)
        .byte 20, $ff
        .byte 0
.endif
.if TEST_KEYS == 13
; Undo holds UNDO_STEPS edits: SPACE UNDO_STEPS + 1 times on Kck step 1
; (3, then 0 2 0 2 ...), then U as many times: UNDO_STEPS undone, back to
; the state after the first edit. Expected: $8000 = 0 (not 3), undo_count =
; 0, undo_redo = UNDO_STEPS, the song row "NOTHING TO UNDO". (Its build
; needs UNDO_STEPS=11: checked so 2026-11-19, the ring wrapping at 11.)
test_key_script
        .byte 20, $ff
        .for _i := 0, _i < UNDO_STEPS + 1, _i += 1
        #tap KC_SPACE
        .endfor
        .for _i := 0, _i < UNDO_STEPS + 1, _i += 1
        #tap KC_U
        .endfor
        .byte 20, $ff
        .byte 0
.endif
.if TEST_KEYS == 21
; SysEx (tools/dump_check.py, from a .d64 with the program as "SID808",
; TEST_SYSEX=4: what is sent comes back in): save the song as "t1", then
; D. Expected: the dump comes back and loads ("SYSEX: SONG LOADED"), its
; staged file ($C800 on) equals "t1" on the disk, byte for byte
test_key_script
        .byte 20, $ff
        #tap KC_W                               ; save: the prompt ("song")
        .for _i := 0, _i < 4, _i += 1
        #tap KC_DEL
        .endfor
        #tap KC_T                               ; "t1"
        #tap KC_1
        #tap KC_RETURN
        .byte 30, $ff
        #tap KC_D                               ; the dump
        .byte 0
.endif
.if TEST_KEYS == 22
; SysEx (tools/dump_check.py, TEST_SYSEX=4): D at once (with
; TEST_DUMP_VERSION, TEST_TONE etc.: the file versions; with TEST_SEQ: a
; dump while the sequencer plays)
test_key_script
        .byte 20, $ff
        #tap KC_D                               ; the dump
        .byte 0
.endif
.endif
