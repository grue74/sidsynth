; test_scripts.asm - part of SID500 (TEST_KEYS builds), included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Key scripts for core/test_keys.asm: an entry is the scans to hold (a scan
; every 16 ms), its key codes, $FF; hold 0 ends it.

TK_SPACE        = KEY_SPACE
TK_CRSR_RIGHT   = KEY_CRSR_RIGHT
TK_CRSR_DOWN    = KEY_CRSR_DOWN
TK_PLUS         = KEY_PLUS
TK_M            = KEY_M
TK_S            = KEY_S
TK_LEFT_ARROW   = KEY_LEFT_ARROW
TK_MINUS        = KEY_MINUS
TK_RET          = KEY_RETURN
TK_RUNSTOP      = KEY_RUNSTOP
TK_V            = 31            ; (the core has Z, X and C)
TK_B            = 28
TK_N            = 39
TK_Q            = 62
TK_W            = 9
TK_P            = 41
TK_L            = 42
TK_D            = 18
TK_T            = 22
TK_CBM          = 61            ; C= (held with a letter: a command)
TK_U            = 30
TK_R            = 17
TK_HOME         = KEY_HOME          ; (SHIFT: CLR)
ctap    .macro                  ; a key with C= held, 2 scans, released 2
        .byte 2, TK_CBM, \1, $ff, 2, $ff
        .endm
cstap   .macro                  ; the same with SHIFT too
        .byte 2, TK_SHIFT, TK_CBM, \1, $ff, 2, $ff
        .endm

.if TEST_KEYS == 1
; TEST_KEYS=1: the transport as master (tools/transport_check.py): play
; from the start, stop, continue, then SHIFT+SPACE while playing (a stop,
; then from the start again), stop
test_key_script
        .byte 30, $ff                           ; settle (~0.5 s)
        #stap TK_SPACE                          ; play from the start
        .byte 95, $ff                           ; ~1.5 s
        #tap TK_SPACE                           ; stop
        .byte 30, $ff
        #tap TK_SPACE                           ; continue
        .byte 75, $ff                           ; ~1.2 s
        #stap TK_SPACE                          ; from the start again, while playing
        .byte 60, $ff                           ; ~1 s
        #tap TK_SPACE                           ; stop
        .byte 0
.elsif TEST_KEYS == 2
; TEST_KEYS=2: eight stops, each held one scan (16 ms, ~1.5 ticks at 120
; BPM) longer than the one before, so they fall at every place in a 16th:
; short of the next 16th's start by more than the lead (rendered on to it)
; and within it (back with its snapshot); each continued
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .for _i := 0, _i < 8, _i += 1
        .byte 40 + _i, $ff                      ; play on
        #tap TK_SPACE                           ; stop
        .byte 12, $ff
        #tap TK_SPACE                           ; continue
        .endfor
        .byte 40, $ff
        #tap TK_SPACE                           ; stop
        .byte 0
.elsif TEST_KEYS == 3
; TEST_KEYS=3: the song screen's response while playing (tools/
; screen_check.py): play, F7 to the song screen, the cursor moved right a
; step at a time (each held 2 scans, released 5: ~110 ms, landing at every
; place of a 16th), stop, more steps, continue, more steps, stop
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 20, $ff
        #tap TK_F7                              ; the song screen
        .byte 10, $ff
        .for _i := 0, _i < 24, _i += 1
        .byte 2, TK_CRSR_RIGHT, $ff, 5, $ff
        .endfor
        #tap TK_SPACE                           ; stop
        .byte 10, $ff
        .for _i := 0, _i < 8, _i += 1
        .byte 2, TK_CRSR_RIGHT, $ff, 5, $ff
        .endfor
        #tap TK_SPACE                           ; continue
        .byte 10, $ff
        .for _i := 0, _i < 24, _i += 1
        .byte 2, TK_CRSR_RIGHT, $ff, 5, $ff
        .endfor
        #tap TK_SPACE                           ; stop
        .byte 20, $ff
        #stap TK_SPACE                          ; (from the start again: the log goes on
        .byte 20, $ff                           ; past the stop's title)
        .byte 0
.elsif TEST_KEYS == 4
; TEST_KEYS=4: the song screen's keys, for a screenshot (the band playing,
; TEST_PLAY=1): F7, pattern 3 put on scene 2's track 2 (+ three times),
; R and U there without C= (nothing: tools/flash_check.py checks the cell),
; down to scene 30 (a scroll) and back up to scene 3, track 4 muted, track 5
; soloed and unsoloed, track 6 soloed, DEL on scene 3's track 6
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 10, $ff
        #tap TK_CRSR_DOWN                       ; scene 2
        #tap TK_CRSR_RIGHT                      ; track 2
        #tap TK_PLUS
        #tap TK_PLUS
        #tap TK_PLUS
        #tap TK_R                               ; (without C=: nothing)
        #tap TK_U
        .for _i := 0, _i < 28, _i += 1
        #tap TK_CRSR_DOWN                       ; to scene 30: scrolled
        .endfor
        .byte 10, $ff
        .for _i := 0, _i < 27, _i += 1
        #stap TK_CRSR_DOWN                      ; back up to scene 3
        .endfor
        #tap TK_CRSR_RIGHT                      ; track 3
        #tap TK_CRSR_RIGHT                      ; track 4
        #tap TK_M                               ; muted
        #tap TK_CRSR_RIGHT                      ; track 5
        #tap TK_S                               ; soloed
        .byte 30, $ff                           ; (every row's colours drawn)
        #tap TK_S                               ; and not
        .byte 30, $ff
        #tap TK_CRSR_RIGHT                      ; track 6
        #tap TK_S                               ; soloed
        #tap TK_PLUS                            ; a pattern there, then cleared
        .byte 5, $ff                            ; (shown a while: two taps' gap let it
                                                ; show 2-3 frames, a flash to flash_check
                                                ; when the drawing's timing moved)
        #tap TK_DEL
        .byte 20, $ff
        .byte 0
.elsif TEST_KEYS == 5
; TEST_KEYS=5: five stops as TEST_KEYS=2's, on the song screen, each two
; scans after a + on the playing scene's first cell (tools/transport_check.py,
; the band scene: its 8 patterns): the live switch made just before the
; stop, sometimes undone by it (back with a snapshot from before it) and
; made again after the continue; every second stop another + while stopped
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 10, $ff
        #stap TK_SPACE                          ; play from the start
        .for _i := 0, _i < 5, _i += 1
        .byte 30 + _i, $ff                      ; play on
        .byte 1, TK_PLUS, $ff, 1, $ff           ; the next pattern, then soon
        #tap TK_SPACE                           ; stop
        .byte 12, $ff
        .if _i % 2 == 1
        .byte 1, TK_PLUS, $ff, 1, $ff           ; (and a + while stopped: the switch
        .byte 8, $ff                            ; made at once, in the lead rendered)
        .endif
        #tap TK_SPACE                           ; continue
        .endfor
        .byte 30, $ff
        #tap TK_SPACE                           ; stop
        .byte 0
.elsif TEST_KEYS == 10
; TEST_KEYS=10: (tools/transport_check.py, TEST_LIVE 3, the band) edits
; to playing patterns: P publishes the next of tables.py band_republish
; (src/live.asm test_live_key): while playing; during a stop (just after
; SPACE); while stopped, then a continue and a stop at once (back with
; the 16th's snapshot, its entries moved to the new chains); ten while
; stopped (more than the list of replaced chains holds); once more while
; playing and while stopped
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 10, $ff
        #stap TK_SPACE                          ; play from the start
        .byte 40, $ff
        #tap TK_P                               ; playing
        .byte 30, $ff
        .byte 2, TK_SPACE, $ff                  ; stop
        .byte 1, TK_P, $ff, 2, $ff              ; during the stop
        .byte 20, $ff
        #tap TK_P                               ; stopped
        .byte 20, $ff
        #tap TK_SPACE                           ; continue
        #tap TK_SPACE                           ; and stop at once
        .byte 20, $ff
        .for _i := 0, _i < 10, _i += 1
        #tap TK_P                               ; stopped: more than RETIRE_MAX
        .endfor
        .byte 30, $ff
        #tap TK_SPACE                           ; continue
        .byte 40, $ff
        #tap TK_P                               ; playing
        .byte 30, $ff
        #tap TK_SPACE                           ; stop
        .byte 20, $ff
        #tap TK_P                               ; stopped
        .byte 20, $ff
        #tap TK_SPACE                           ; continue
        .byte 40, $ff
        #tap TK_SPACE                           ; stop
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 11
; TEST_KEYS=11: (tools/edit_check.py, with TEST_MIDI) step entry from MIDI
; in: a new pattern in scene 2's first cell (stopped), then test_pattern's
; notes: a chord of three, a single note, and a chord whose keys overlap
; (one released before the last is pressed: still one chord)
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 10, $ff
        #tap TK_CRSR_DOWN                       ; scene 2, track 1: empty
        #tap TK_RET                             ; a new pattern (the first free)
        .byte 250, $ff                          ; the notes come (~6 s: 62.5 scans a
        .byte 125, $ff                          ; second)
        #tap TK_RET                             ; back: the feed starting again (VICE
        .byte 0                                 ; runs warp) plays the song screen
; test_pattern - (core TEST_MIDI: a count, the bytes, then the 250 Hz ticks
; to the next entry) ~4 s to settle (fillers: a note off for note 0, which
; no key holds), the notes, then fillers past the run's end (the pattern
; would start again)
MIDI_GAP        = 50            ; ticks between the chords (200 ms)
test_pattern
        .for _i := 0, _i < 4, _i += 1
        .byte 3, $80, 0, 0, 250
        .endfor
        .byte 3, $90, 60, 100, 2                ; C3 E3 G3 together
        .byte 3, $90, 64, 100, 2
        .byte 3, $90, 67, 100, MIDI_GAP
        .byte 3, $80, 60, 0, 2
        .byte 3, $80, 64, 0, 2
        .byte 3, $80, 67, 0, MIDI_GAP           ; all released: the cursor down
        .byte 3, $90, 62, 90, MIDI_GAP          ; D3 alone
        .byte 3, $80, 62, 0, MIDI_GAP
        .byte 3, $90, 65, 100, 5                ; F3, A3, F3 up, C4, then the rest up
        .byte 3, $90, 69, 100, 5
        .byte 3, $80, 65, 0, 5
        .byte 3, $90, 72, 100, 5
        .byte 3, $80, 69, 0, 5
        .byte 3, $80, 72, 0, MIDI_GAP
        .for _i := 0, _i < 100, _i += 1
        .byte 3, $80, 0, 0, 250
        .endfor
        .byte 0
.elsif TEST_KEYS == 6
; TEST_KEYS=6: whole-screen changes one at a time, each given time to be
; drawn (tools/flash_check.py measures each): playing, F7, down to the
; last row shown, a scroll down, a scroll up (up to the top and one more),
; the half flipped and back, a mute and a solo
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 60, $ff
        .for _i := 0, _i < 21, _i += 1
        #tap TK_CRSR_DOWN                       ; to the last row shown
        .endfor
        .byte 30, $ff
        #tap TK_CRSR_DOWN                       ; a scroll down
        .byte 30, $ff
        .for _i := 0, _i < 21, _i += 1
        #stap TK_CRSR_DOWN                      ; up to the top row
        .endfor
        .byte 30, $ff
        #stap TK_CRSR_DOWN                      ; a scroll up
        .byte 30, $ff
        #tap TK_LEFT_ARROW                      ; the other half
        .byte 30, $ff
        #tap TK_LEFT_ARROW                      ; and back
        .byte 30, $ff
        #tap TK_M                               ; a mute
        .byte 30, $ff
        #tap TK_S                               ; a solo
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 7
; TEST_KEYS=7: the song screen's other keys while playing (tools/
; screen_check.py), each held 2 scans and released 5 (~110 ms: at every
; place of a 16th): down 24 times (scrolls at the end), up 24 times, the
; half flipped 6 times, + 8 times, - 8 times, DEL twice, M and S on and
; off twice each
key7    .macro
        .byte 2, \1, $ff, 5, $ff
        .endm
skey7   .macro
        .byte 2, TK_SHIFT, \1, $ff, 5, $ff
        .endm
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 20, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        .for _i := 0, _i < 24, _i += 1
        #key7 TK_CRSR_DOWN
        .endfor
        .for _i := 0, _i < 24, _i += 1
        #skey7 TK_CRSR_DOWN
        .endfor
        .for _i := 0, _i < 6, _i += 1
        #key7 TK_LEFT_ARROW
        .endfor
        .for _i := 0, _i < 8, _i += 1
        #key7 TK_PLUS
        .endfor
        .for _i := 0, _i < 8, _i += 1
        #key7 TK_MINUS
        .endfor
        #key7 TK_DEL
        #key7 TK_DEL
        .for _i := 0, _i < 4, _i += 1
        #key7 TK_M
        .endfor
        .for _i := 0, _i < 4, _i += 1
        #key7 TK_S
        .endfor
        .byte 20, $ff
        .byte 0
.elsif TEST_KEYS == 8
; TEST_KEYS=8: the step grid (tools/flash_check.py), the band playing:
; the drums opened (chords), the cursor down and across, back; the many
; notes' pattern (more than 3 a step, off the steps' starts), down; back;
; the bass (lengths not whole steps), down to its end; back
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #tap TK_RET                             ; scene 1, track 1: the drums
        .byte 40, $ff
        .for _i := 0, _i < 6, _i += 1
        #tap TK_CRSR_DOWN
        .endfor
        #tap TK_CRSR_RIGHT
        #tap TK_CRSR_RIGHT
        #tap TK_CRSR_RIGHT                      ; (round to the first column)
        .for _i := 0, _i < 3, _i += 1
        #stap TK_CRSR_DOWN                      ; up
        .endfor
        .byte 20, $ff
        #tap TK_RET                             ; back to the song
        .byte 30, $ff
        .for _i := 0, _i < 7, _i += 1
        #tap TK_CRSR_RIGHT                      ; to track 8: many notes
        .endfor
        #tap TK_RET
        .byte 40, $ff
        .for _i := 0, _i < 4, _i += 1
        #tap TK_CRSR_DOWN
        .endfor
        .byte 20, $ff
        #tap TK_RET
        .byte 30, $ff
        .for _i := 0, _i < 6, _i += 1
        #stap TK_CRSR_RIGHT                     ; back to track 2: the bass
        .endfor
        #tap TK_RET
        .byte 40, $ff
        .for _i := 0, _i < 14, _i += 1
        #tap TK_CRSR_DOWN                       ; (to its last step: 12)
        .endfor
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 9
; TEST_KEYS=9: editing on the step grid (tools/edit_check.py,
; tools/flash_check.py), the band playing: a new pattern in scene 2's
; first cell (no track plays it): notes, a rest, a chord of 4 (SHIFT: the
; cursor stays), DEL, a note replaced, one added from another column, the
; octave up and down, a note's velocity (C= +) and length (C= L), the
; pattern transposed (C= T, C= -), the length down to 4 and up to 7;
; undo and redo between them (C= U, C= SHIFT U: the DEL, a velocity step
; and the last + undone for good, the rest undone and redone);
; back, then opened again (decoded from what was
; published); the bass opened and closed unedited (not published again);
; the many notes' step 1 quantized (C= Q; playing: heard at once);
; the drums (playing) edited: published at once, heard (live.asm); back;
; scene 2's cell opened (the table no longer waits) and closed
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #tap TK_CRSR_DOWN                       ; scene 2, track 1: empty
        #tap TK_RET                             ; a new pattern (9: the first free)
        .byte 40, $ff
        #tap TK_Z                               ; step 1: C2
        #tap TK_X                               ; step 2: D2
        #tap TK_C                               ; step 3: E2
        #tap TK_SPACE                           ; step 4: a rest
        #tap TK_V                               ; step 5: F2
        #stap TK_Z                              ; step 6: C2 E2 G2 A2
        #stap TK_C
        #stap TK_B
        #stap TK_N
        #stap TK_CRSR_DOWN                      ; up to step 5
        #tap TK_DEL                             ; its F2 out
        #ctap TK_U                              ; undone: F2 back (kept so)
        #stap TK_CRSR_DOWN
        #stap TK_CRSR_DOWN
        #stap TK_CRSR_DOWN                      ; step 2
        #tap TK_Q                               ; its D2 replaced: C3
        #tap TK_CRSR_RIGHT
        #tap TK_CRSR_RIGHT                      ; step 3, the third column
        #tap TK_W                               ; D3 added (the step's second note)
        #ctap TK_U                              ; undone: W's D3, then Q's C3 (D2
        #ctap TK_U                              ; back)
        .byte 10, $ff                           ; (shown a while: undone and redone
                                                ; within 2 frames reads as a flash)
        #cstap TK_U                             ; both redone (the cursor on step 3,
        #cstap TK_U                             ; the last's)
        #tap TK_CRSR_DOWN                       ; step 4 again
        #tap TK_F5                              ; the octave up
        #tap TK_Z                               ; step 4: C3
        #stap TK_F5                             ; and down
        #tap TK_CRSR_RIGHT                      ; the first column (round)
        #stap TK_CRSR_DOWN                      ; step 4: its C3
        .for _i := 0, _i < 3, _i += 1
        #ctap TK_PLUS                           ; C= + three times: velocity 103
        .endfor
        .byte 10, $ff                           ; (103 shown a while: undone within 2
                                                ; frames reads as a flash)
        #ctap TK_U                              ; one undone: 102 (the entry setting
                                                ; stays 103: settings aren't undone)
        #ctap TK_L                              ; C= L: the length
        #ctap TK_PLUS                           ; a step longer: 2
        #ctap TK_T                              ; C= T: the transpose
        #ctap TK_MINUS
        #ctap TK_MINUS                          ; the pattern 2 semitones down
        .byte 10, $ff                           ; (shown a while, as above)
        #ctap TK_U                              ; one undone, then redone
        .byte 10, $ff
        #cstap TK_U
        #ctap TK_V                              ; C= V: the velocity again
        .for _i := 0, _i < 12, _i += 1
        #tap TK_MINUS                           ; 4 steps (the cursor up to step 4;
        .endfor                                 ; the chord kept, silent)
        .byte 10, $ff                           ; (4 steps shown a while: a state
                                                ; undone within 2 frames reads as a flash)
        .for _i := 0, _i < 3, _i += 1
        #tap TK_PLUS                            ; 7: the chord back
        .endfor
        #ctap TK_U                              ; the last undone: 6 steps
        .byte 30, $ff
        #tap TK_RET                             ; back
        .byte 40, $ff
        #tap TK_RET                             ; opened again
        .byte 40, $ff
        .for _i := 0, _i < 6, _i += 1
        #tap TK_CRSR_DOWN
        .endfor
        #tap TK_RET                             ; back
        .byte 30, $ff
        #stap TK_CRSR_DOWN                      ; scene 1
        #tap TK_CRSR_RIGHT                      ; track 2: the bass
        #tap TK_RET
        .byte 40, $ff
        #tap TK_CRSR_DOWN
        #tap TK_CRSR_DOWN
        #tap TK_RET                             ; back, unedited
        .byte 30, $ff
        .for _i := 0, _i < 6, _i += 1
        #tap TK_CRSR_RIGHT                      ; track 8: the many notes (playing)
        .endfor
        #tap TK_RET
        .byte 100, $ff                          ; (decoded: at half the wire slowly)
        #ctap TK_Q                              ; step 1's six notes onto its start
        #ctap TK_U                              ; undone and redone
        .byte 10, $ff
        #cstap TK_U
        .byte 20, $ff
        #tap TK_RET                             ; back
        .byte 30, $ff
        .for _i := 0, _i < 7, _i += 1
        #stap TK_CRSR_RIGHT                     ; track 1: the drums
        .endfor
        #tap TK_RET
        .byte 40, $ff
        #tap TK_Z                               ; step 1's first note: C2 (playing:
        .byte 20, $ff                           ; published, heard)
        #tap TK_RET                             ; back
        .byte 30, $ff
        #tap TK_CRSR_DOWN                       ; scene 2
        #tap TK_RET                             ; opened
        .byte 40, $ff
        #tap TK_RET                             ; back
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 12
; TEST_KEYS=12: (tools/edit_check.py, tools/screen_check.py,
; tools/flash_check.py) copy and clear on the step grid, the band playing:
; the bass (track 2, playing) copied (C= C: the first free number into its
; cell, the track switched to the copy), the copy's first note replaced;
; CLR (5 events: at once), undone, redone, undone; step 3's note out (DEL:
; the steps' index found again after the undo); back. The many notes
; (track 8, playing, 96 events: more than a CLR keeps for undo): CLR asks,
; HOME cancels it (the cursor to step 1); copied (all 96 in the copy);
; step 1's first note out twice (94): CLR asks, HOME cancels; once more
; (93, the most a CLR keeps): CLR clears at once, C= U brings all 93
; back; back. The cell back to the original (- twice), opened: CLR asks,
; CLR again clears it, C= U changes nothing (the history cleared); HOME
; from step 4; back, the cell to the copy again (+ twice)
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #tap TK_CRSR_RIGHT                      ; scene 1, track 2: the bass
        #tap TK_RET
        .byte 40, $ff
        #ctap TK_C                              ; copied: pattern 9 in the cell
        .byte 40, $ff
        #tap TK_Z                               ; step 1's note: C2, 100, a step
        .byte 20, $ff
        #stap TK_HOME                           ; CLR: cleared at once
        .byte 10, $ff
        #ctap TK_U                              ; undone
        .byte 10, $ff
        #cstap TK_U                             ; redone: cleared again
        .byte 10, $ff
        #ctap TK_U                              ; undone: the copy as edited
        .byte 20, $ff
        #tap TK_HOME                            ; step 1
        #tap TK_CRSR_DOWN
        #tap TK_CRSR_DOWN                       ; step 3 (the steps' index found
        #tap TK_DEL                             ; again): its note out
        .byte 20, $ff
        #tap TK_RET                             ; back
        .byte 30, $ff
        .for _i := 0, _i < 6, _i += 1
        #tap TK_CRSR_RIGHT                      ; track 8: the many notes
        .endfor
        #tap TK_RET
        .byte 100, $ff                          ; (decoded: at half the wire slowly)
        .for _i := 0, _i < 3, _i += 1
        #tap TK_CRSR_DOWN
        .endfor
        #stap TK_HOME                           ; CLR: asks (96 events)
        .byte 10, $ff
        #tap TK_HOME                            ; cancelled; the cursor to step 1
        .byte 10, $ff
        #ctap TK_C                              ; copied: pattern 10, all 96 notes
        .byte 40, $ff
        #tap TK_DEL                             ; step 1's first note out: 95
        .byte 10, $ff
        #tap TK_DEL                             ; and the next: 94
        .byte 10, $ff
        #stap TK_HOME                           ; CLR: asks (94)
        .byte 10, $ff
        #tap TK_HOME                            ; cancelled
        .byte 10, $ff
        #tap TK_DEL                             ; 93
        .byte 10, $ff
        #stap TK_HOME                           ; CLR: cleared at once (93)
        .byte 20, $ff
        #ctap TK_U                              ; undone: all 93 back
        .byte 20, $ff
        #tap TK_RET                             ; back
        .byte 30, $ff
        #tap TK_MINUS                           ; the cell: 9, the bass's copy
        .byte 10, $ff
        #tap TK_MINUS                           ; 8: the many notes
        .byte 20, $ff
        #tap TK_RET                             ; opened
        .byte 100, $ff
        #stap TK_HOME                           ; CLR: asks (96)
        .byte 10, $ff
        #stap TK_HOME                           ; CLR again: cleared
        .byte 20, $ff
        #ctap TK_U                              ; nothing to undo
        .byte 10, $ff
        .for _i := 0, _i < 3, _i += 1
        #tap TK_CRSR_DOWN
        .endfor
        #tap TK_HOME                            ; the cursor to step 1
        .byte 10, $ff
        #tap TK_RET                             ; back
        .byte 30, $ff
        #tap TK_PLUS                            ; the cell: 9
        .byte 10, $ff
        #tap TK_PLUS                            ; 10: the copy again
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 13
; TEST_KEYS=13: stage C's listening test (tools/demo_song.py, which writes
; demo_keys.inc; tools/demo_band.py runs it): five patterns entered on the
; step grid, then played from the start and built up live
test_key_script
        .include "demo_keys.inc"
.elsif TEST_KEYS == 14
; TEST_KEYS=14: (tools/flash_check.py) the count-in on the song screen, the
; band stopped: track 9 (empty: a new pattern), C= R: the count-in (the
; title REC at once); SPACE ends it (STOP); C= R again: a bar counted in,
; the song plays recording (REC); C= R ends the take (PLAY); SPACE stops
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        .for _i := 0, _i < 8, _i += 1
        #tap TK_CRSR_RIGHT                      ; to track 9 (the half flips)
        .endfor
        .byte 20, $ff
        #ctap TK_R                              ; the count-in: REC
        .byte 40, $ff
        #tap TK_SPACE                           ; ended: STOP
        .byte 40, $ff
        #ctap TK_R                              ; counted in again: a bar (2 s),
        .byte 200, $ff                          ; then playing, recording
        #ctap TK_R                              ; the take ended: PLAY
        .byte 60, $ff
        #tap TK_SPACE                           ; stopped
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 15
; TEST_KEYS=15: (tools/flash_check.py) stage E on the song screen, the band
; playing: row 1's keys on scene 1 (C= N, C= B the bars, C= T the beats,
; SHIFT+C= T n/8 and back, C= X and SHIFT+C= X the repeats), patterns put
; in scene 2, SHIFT+RETURN launches it ('+', then '>' at the bar), C=
; RETURN launches scene 1's cell on track 2 ('+' then '>' in its gap),
; C= S Song on, SHIFT+RETURN scene 1 again, SPACE stops
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #ctap TK_N                              ; 5 bars
        .byte 10, $ff
        #ctap TK_B                              ; 4 again
        .byte 10, $ff
        #ctap TK_T                              ; 5/4
        .byte 10, $ff
        #cstap TK_T                             ; 5/8
        .byte 10, $ff
        #cstap TK_T                             ; 5/4
        .byte 10, $ff
        #ctap TK_X                              ; twice
        .byte 10, $ff
        #cstap TK_X                             ; once
        .byte 10, $ff
        #tap TK_CRSR_DOWN                       ; scene 2: patterns 1 and 2
        #tap TK_PLUS
        #tap TK_CRSR_RIGHT
        #tap TK_PLUS
        #tap TK_PLUS
        .byte 10, $ff
        #stap TK_RET                            ; scene 2 launched
        .byte 150, $ff
        #stap TK_CRSR_DOWN                      ; (SHIFT: up) scene 1, track 2
        #ctap TK_RET                            ; its cell launched on track 2
        .byte 150, $ff
        #ctap TK_S                              ; Song on
        .byte 40, $ff
        #stap TK_RET                            ; scene 1 launched
        .byte 150, $ff
        #tap TK_SPACE                           ; stopped
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 16
; TEST_KEYS=16: (tools/flash_check.py, tools/screen_check.py) the event
; list, the band playing: the pad (a program change, controllers, a chord,
; bends) on the grid, its second column, F3: the list on that note; down
; to a bend, the fields round, down to the END row, up, F3: the grid on the
; bend's step (6). The many notes' pattern (96 events, 6 pages): step 4's
; second note (event 20), F3; down past a page (to event 34), the fields,
; up past it again (event 30: step 5's 6th note), F3 (the grid on step 5,
; the first column: past the columns); on the grid the pattern 4 steps
; longer (+), its page turned and back; back to the song, stopped
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #tap TK_CRSR_RIGHT                      ; track 3: the pad
        #tap TK_CRSR_RIGHT
        #tap TK_RET
        .byte 40, $ff
        #tap TK_CRSR_RIGHT                      ; its second column (E-4)
        #tap TK_F3                              ; the list: on E-4's note
        .byte 20, $ff
        .for _i := 0, _i < 3, _i += 1
        #tap TK_CRSR_DOWN                       ; to the first bend
        .endfor
        #tap TK_CRSR_RIGHT                      ; (a bend: 2 fields, round to 0)
        #stap TK_CRSR_RIGHT                     ; (back to its value)
        .for _i := 0, _i < 3, _i += 1
        #tap TK_CRSR_DOWN                       ; to the END row (and past: stays)
        .endfor
        #stap TK_CRSR_DOWN                      ; up: the second bend
        .byte 10, $ff
        #tap TK_F3                              ; the grid: step 6
        .byte 30, $ff
        #tap TK_RET                             ; the song screen
        .byte 30, $ff
        .for _i := 0, _i < 5, _i += 1
        #tap TK_CRSR_RIGHT                      ; track 8: the many notes
        .endfor
        #tap TK_RET
        .byte 60, $ff
        .for _i := 0, _i < 3, _i += 1
        #tap TK_CRSR_DOWN                       ; step 4
        .endfor
        #tap TK_CRSR_RIGHT                      ; its second note
        #tap TK_F3
        .byte 20, $ff
        .for _i := 0, _i < 14, _i += 1
        #tap TK_CRSR_DOWN                       ; to the next page
        .endfor
        #tap TK_CRSR_RIGHT                      ; the velocity
        #tap TK_CRSR_RIGHT                      ; the length
        .for _i := 0, _i < 4, _i += 1
        #stap TK_CRSR_DOWN                      ; up: the page before
        .endfor
        .byte 10, $ff
        #tap TK_F3                              ; the grid: step 5, column 1
        .byte 90, $ff                           ; (past flash_check's switch's frames)
        .for _i := 0, _i < 4, _i += 1
        #tap TK_PLUS                            ; 20 steps (a page more)
        .endfor
        .for _i := 0, _i < 13, _i += 1
        #tap TK_CRSR_DOWN                       ; the grid's next page (step 18)
        .endfor
        .byte 20, $ff
        #stap TK_CRSR_DOWN                      ; (back: step 17)
        #stap TK_CRSR_DOWN                      ; (back: step 16, the page before)
        .byte 20, $ff
        #tap TK_RET
        .byte 30, $ff
        #tap TK_SPACE                           ; stopped
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 17
; TEST_KEYS=17: (tools/edit_check.py) editing in the event list, the band
; playing: the pad (track 3) on the grid, F3 (the list on its C-4): the
; note's pitch + and SHIFT+ (73), velocity -3 and SHIFT- (67), length +
; and SHIFT+ (93), position + twice (tick 2: after the chord's others);
; the controller at 30 - and SHIFT- (17: before the bends), its value +2
; (62); the bend at 50 -, then DEL; INST on the bend at 70, its copy +
; (65); up to the program change, + (13); C= U twice (the program back to
; 12, the copy to 64), SHIFT+C= U (the copy 65 again); back to the song
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #tap TK_CRSR_RIGHT                      ; track 3: the pad
        #tap TK_CRSR_RIGHT
        #tap TK_RET
        .byte 40, $ff
        #tap TK_F3                              ; the list: on C-4, its note
        .byte 20, $ff
        #tap TK_PLUS                            ; C#4
        #stap TK_PLUS                           ; C#5
        #tap TK_CRSR_RIGHT                      ; the velocity
        #tap TK_MINUS
        #tap TK_MINUS
        #tap TK_MINUS                           ; 77
        #stap TK_MINUS                          ; 67
        #tap TK_CRSR_RIGHT                      ; the length
        #tap TK_PLUS                            ; 81
        #stap TK_PLUS                           ; 93
        #tap TK_CRSR_RIGHT                      ; the position (round)
        #tap TK_PLUS
        #tap TK_PLUS                            ; tick 2
        #tap TK_CRSR_DOWN                       ; the controller at 30
        #tap TK_MINUS                           ; 29
        #stap TK_MINUS                          ; 17
        #tap TK_CRSR_RIGHT                      ; its value
        #tap TK_PLUS
        #tap TK_PLUS                            ; 62
        #tap TK_CRSR_DOWN                       ; the bend at 50, its value
        #tap TK_MINUS                           ; 71
        #tap TK_DEL                             ; out: on the bend at 70
        #stap TK_DEL                            ; INST: its copy, the cursor on it
        #tap TK_PLUS                            ; 65
        .for _i := 0, _i < 7, _i += 1
        #stap TK_CRSR_DOWN                      ; up to the program change
        .endfor
        #tap TK_PLUS                            ; 13
        .byte 10, $ff
        #ctap TK_U                              ; the program back to 12
        #ctap TK_U                              ; the copy back to 64
        #cstap TK_U                             ; the copy 65 again
        .byte 20, $ff
        #tap TK_RET                             ; the song screen (published)
        .byte 60, $ff
        .byte 0
.elsif TEST_KEYS == 18
; TEST_KEYS=18: (tools/flash_check.py) the family's names, the band
; playing: C= Y twice on track 1 (the drums' channel 10: SID808), three
; times on track 3 (the pad's channel 3, the lead's too: SID101); the
; drums on the grid (drum names), F3 (in the list), back; the pad on the
; grid, F3 (its controllers named), back; C= Y once more on track 3 (none)
TK_Y    = KEY_Y
test_key_script
        .byte 30, $ff                           ; settle
        #stap TK_SPACE                          ; play from the start
        .byte 10, $ff
        #tap TK_F7                              ; the song screen
        .byte 40, $ff
        #ctap TK_Y                              ; channel 10: SID303
        #ctap TK_Y                              ;   SID808
        .byte 10, $ff
        #tap TK_CRSR_RIGHT
        #tap TK_CRSR_RIGHT                      ; track 3
        #ctap TK_Y
        #ctap TK_Y
        #ctap TK_Y                              ; channel 3: SID101
        .byte 10, $ff
        #stap TK_CRSR_RIGHT
        #stap TK_CRSR_RIGHT                     ; track 1: the drums
        #tap TK_RET
        .byte 40, $ff
        #tap TK_F3                              ; the list
        .byte 40, $ff
        #tap TK_RET
        .byte 30, $ff
        #tap TK_CRSR_RIGHT
        #tap TK_CRSR_RIGHT                      ; track 3: the pad
        #tap TK_RET
        .byte 40, $ff
        #tap TK_F3                              ; the list
        .byte 40, $ff
        #tap TK_RET
        .byte 30, $ff
        #ctap TK_Y                              ; channel 3: none again
        .byte 30, $ff
        #tap TK_SPACE                           ; stopped
        .byte 20, $ff
        .byte 0
.elsif TEST_KEYS == 19
; TEST_KEYS=19: the disk (tools/disk_check.py): the song screen, C= W (the
; overlay loaded from the disk), RETURN (the song saved as "song"), a key
; (the message gone), the cursor's cell emptied (DEL), C= L, RETURN (the
; song loaded back: the cell as saved); the message left on the title
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_W                              ; save: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; saved
        .byte 30, $ff
        #tap TK_RUNSTOP                         ; the message gone
        .byte 20, $ff
        #tap TK_DEL                             ; the cell emptied
        .byte 20, $ff
        #ctap TK_L                              ; load: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; loaded
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 20
; TEST_KEYS=20: (tools/disk_check.py) the song screen, nothing else: the
; song as TEST_PLAY made it, to compare a load with
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        .byte 0
.elsif TEST_KEYS == 21
; TEST_KEYS=21: (tools/disk_check.py) C= W, RETURN: saved, the message left
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_W                              ; save: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; saved
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 22
; TEST_KEYS=22: (tools/disk_check.py) C= L, RETURN: "song" loaded (or not:
; the error cases), the message left
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_L                              ; load: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; loaded
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 23
; TEST_KEYS=23: (tools/disk_check.py) C= L only: the overlay not loaded
; ("NO SID500 DISK FILE" left on the title)
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_L
        .byte 30, $ff
        .byte 0
.elsif TEST_KEYS == 24 || TEST_KEYS == 25
; TEST_KEYS=24: (tools/disk_check.py) C= D: the directory shown; 25: then
; the cursor down, RETURN: the second song loaded
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_D                              ; the directory
        .byte 40, $ff
.if TEST_KEYS == 25
        #tap TK_CRSR_DOWN                       ; the second song
        .byte 20, $ff
        #tap TK_RET                             ; loaded
        .byte 40, $ff
.endif
        .byte 0
.elsif TEST_KEYS == 26
; TEST_KEYS=26: (tools/disk_check.py) the code at HI3_CODE put back: C= W
; (the overlay loaded over it, kept in the note map), RETURN (saved), a key
; (the message gone), RETURN on the cursor's cell (the step grid opened:
; hi3_in), F3 (the event list: its code there)
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
        #ctap TK_W                              ; save: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; saved
        .byte 30, $ff
        #tap TK_RUNSTOP                         ; the message gone
        .byte 20, $ff
        #tap TK_RET                             ; the step grid
        .byte 40, $ff
        #tap KEY_F3                             ; the event list
        .byte 40, $ff
        .byte 0
.elsif TEST_KEYS == 27 || TEST_KEYS == 28
; TEST_KEYS=27: (tools/disk_check.py) the note map after a save: C= W (the
; code at HI3_CODE kept in the note map's pages 2-5), RETURN (saved), a key
; (the message gone), SHIFT+SPACE (played: hi3_in first), SPACE (stopped); 28:
; the same without the save, to compare the note map with
test_key_script
        .byte 30, $ff                           ; settle
        #tap TK_F7                              ; the song screen
        .byte 20, $ff
.if TEST_KEYS == 27
        #ctap TK_W                              ; save: the name asked
        .byte 30, $ff
        #tap TK_RET                             ; saved
        .byte 30, $ff
        #tap TK_RUNSTOP                         ; the message gone
        .byte 20, $ff
.endif
        #stap TK_SPACE                          ; played from the start
        .byte 200, $ff
        #tap TK_SPACE                           ; stopped
        .byte 100, $ff
        .byte 0
.elsif TEST_KEYS == 29
; TEST_KEYS=29: (tools/demo_tunes.py) a demo tune loaded and played: the
; song screen, C= D (the directory), the cursor down to song TEST_TUNE,
; RETURN (loaded: Song on, its parameters), SHIFT+SPACE (from scene 1)
        .weak
TEST_TUNE = 1                           ; the song's place in the directory, 1..
        .endweak
test_key_script
        .byte 50, $ff                           ; settle (the title seen)
        #tap TK_F7                              ; the song screen
        .byte 50, $ff
        #ctap TK_D                              ; the directory
        .byte 60, $ff
        .for _i := 1, _i < TEST_TUNE, _i += 1
        #tap TK_CRSR_DOWN                       ; the next song
        .byte 25, $ff
        .endfor
        .byte 25, $ff
        #tap TK_RET                             ; loaded
        .byte 150, $ff                          ; (the song screen seen)
        #stap TK_SPACE                          ; played from scene 1
        .byte 0
.endif
