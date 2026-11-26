; core/sequencer.asm - step sequencer, optional core module
; Part of the SID synth core shared by SID303 and SID808 (from SID303, 2026-11-18).
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A monophonic step sequencer for a synth that plays one note at a time
; (SID303, SID101). Optional: a synth that wants it includes this file
; right after its notes and engine (README, "The sequencer"); a synth that
; doesn't include it builds as before.
;
; 64 patterns of up to 16 steps, a page each. A step is a MIDI note and a
; flags byte: the time (rest, note, tie), accent and slide. The steps play
; through the synth's note_on / note_off, so the sound engine treats them
; as it treats MIDI: a note on while the gate is open is a slide, an
; accented step comes with velocity VEL_ACCENT.
; Tempo comes from a 16-bit step phase that grows every engine tick, so a
; step falls on the tick nearest its time and the tempo is right to within
; 0.05 % at any BPM (the increment is a whole number); swing delays the
; off-beat 16ths (from SID808's sequencer). Song mode chains patterns: a
; list of up to SONG_MAX entries (pattern, repeats, transpose) that plays
; in a loop. With the Clock parameter on MIDI, MIDI clock (24 per quarter
; note: 6 per step), start, continue and stop drive the steps instead of
; the tempo. With MIDI out on, the steps go out as notes (a slide as the
; next note on before the note off), and with the internal clock start,
; clock and stop.
; Steps fire from synth_tick (seq_tick), never from the keyboard handler.
;
; The synth provides (README, "The sequencer"):
;   note_on, note_off           the core's note hooks, which play the steps
;   P_CLOCK, P_MIDIOUT          parameters: clock 0 internal / 1 MIDI, MIDI out 0 off / 1 on
;   LOWEST_NOTE, HIGHEST_NOTE   the note range transposed notes are folded into
;   edit_pat                    a zero-page byte: the pattern its screen shows
;                               (song_enter sets it, so the screen follows the song)
;   TEST_LOG, log_out           with TEST_LOG (core/options.inc) on: log_out logs MIDI out byte A
;   tables (tables_core.py seq_tables): SEQ_STEPS, BPM_MIN, BPM_MAX, GATE_LEN,
;     TIME_REST, TIME_NOTE, TIME_TIE, FLAG_ACCENT, FLAG_SLIDE, bpm_inc_lo,
;     bpm_inc_hi, bpm_steplen, bpm_gate, DEFAULT_PATTERNS, default_patterns,
;     and for the tests edges_pattern, TEST_SONG_LEN, test_song_pat/rep/tr
; It needs MIDI_REALTIME (it is the synth_realtime hook) and MIDI_OUT, and
; calls synth_tick's seq_tick (each tick, before the sound engine).
        .cerror !MIDI_REALTIME, "the sequencer needs MIDI_REALTIME = 1 (it is synth_realtime)"
                                ; (or, with SEQ_REALTIME_OWN, seq_realtime: called by the synth's)
        .cerror !MIDI_OUT, "the sequencer needs MIDI_OUT = 1"

        .weak                   ; memory and velocities, overridable by the synth
PATTERN_RAM     = $8000         ; patterns: NUM_PATTERNS pages (RAM: BASIC ROM is banked out)
SONG_RAM        = $c700         ; the song block (song_pat ... SONG_END), at most a page
VEL_NORMAL      = 100           ; note velocity of a step (SID303: below its ACCENT_VELOCITY)
VEL_ACCENT      = 127           ; ... of an accented step
        .endweak

; pattern memory: one 256-byte page per pattern
NUM_PATTERNS    = 64
PAT_NOTES       = 0             ; offset of the 16 notes (MIDI note numbers)
PAT_FLAGS       = PAT_NOTES + SEQ_STEPS ; offset of the 16 flags bytes
PAT_LENGTH      = PAT_FLAGS + SEQ_STEPS ; offset of the length byte (1..16)
PAT_BYTES       = PAT_LENGTH + 1 ; bytes of a pattern that mean something (copy, disk)
        .cerror PATTERN_RAM + NUM_PATTERNS * 256 > $c000, "patterns run into $C000"
; step flags (tables_core.py: TIME_REST, TIME_NOTE, TIME_TIE, FLAG_ACCENT, FLAG_SLIDE)
TIME_MASK       = %00000011     ; flags bits 0-1: the time
NO_NOTE         = $ff           ; seq_note: the sequencer has no note sounding

        .weak
SEQ_BPM_DEFAULT = 125           ; tempo at start
SEQ_SWING_DEFAULT = 0           ; swing at start, 0..SWING_MAX
TEST_SEQ = 0                    ; 1 = start playing at once (tempo and playing tests)
TEST_SEQ_PAT = 0                ; pattern TEST_SEQ plays (0 = pattern 1)
TEST_SEQ_NEXT = -1              ; >= 0: the pattern TEST_SEQ queues after its first pass
TEST_SONG = 0                   ; 1 = tables.py's SONG_TEST as the song, song mode on
TEST_CLOCK = 0                  ; Clock parameter at start: 0 internal, 1 MIDI
TEST_MIDIOUT = 0                ; MIDI out parameter at start: 0 off, 1 on
TEST_EDGES = 0                  ; 1 = pattern 1 is tables.py's EDGES (the playing rules' cases);
                                ; 2 = patterns 1 and 2 are SHORT1, SHORT2 (lengths 6, 5)
        .endweak
SWING_MAX       = 15            ; swing delays odd steps by swing/32 of a step (0..47 %)
CLOCKS_PER_STEP = 6             ; MIDI clock: 24 per quarter note, a step is a 16th

; the song: its entries and length together, one block for undo and disk
SONG_MAX        = 64            ; entries
SONG_REP_MAX    = 9             ; repeats of an entry, 1..9 (one digit on screen)
TRANSPOSE_MAX   = 12            ; an entry's transpose, -12..+12 semitones (signed byte)
song_pat        = SONG_RAM      ; SONG_MAX bytes: pattern of each entry, 0..63
song_rep        = song_pat + SONG_MAX ; SONG_MAX bytes: its repeats, 1..SONG_REP_MAX
song_tr         = song_rep + SONG_MAX ; SONG_MAX bytes: its transpose
song_len        = song_tr + SONG_MAX ; entries in the song, 0..SONG_MAX
SONG_END        = song_len + 1  ; end of the song block
        .cerror SONG_END - song_pat > 256, "the song block must fit an undo page"

        .section zp
out_tmp         .byte ?         ; out_message: the channel
seq_play        .byte ?         ; nonzero: playing
seq_start       .byte ?         ; nonzero: fire step 0 on the next tick (play pressed)
seq_step        .byte ?         ; step playing, 0..length-1
seq_pat         .byte ?         ; pattern playing, 0..NUM_PATTERNS-1
seq_next        .byte ?         ; pattern to play from the next pattern start
seq_phase       .word ?         ; step phase: a step is due when it passes 65536
seq_inc         .word ?         ; phase increment per tick (tempo)
seq_bpm         .byte ?         ; tempo, BPM_MIN..BPM_MAX
seq_swing       .byte ?         ; swing 0..SWING_MAX
swing_ticks     .byte ?         ; delay of an off-beat step, ticks
swing_wait      .byte ?         ; ticks until the delayed off-beat step fires, 0 = none
gate_ticks      .byte ?         ; how long a note's gate stays open at this tempo, ticks
seq_ptr         .word ?         ; the playing pattern's page (low byte 0)
look_ptr        .word ?         ; step_after: the next pattern's flags
seq_note        .byte ?         ; the note the sequencer has sounding (transposed), NO_NOTE = none
seq_held        .byte ?         ; seq_note goes on past its step: FLAG_SLIDE = slid into
                                ; the next note, 0 = tied (or a timed gate, seq_gate)
seq_gate        .byte ?         ; ticks until seq_note's gate closes, 0 = no timed close
seq_transpose   .byte ?         ; semitones added to every note (the song entry's, else 0)
song_on         .byte ?         ; nonzero: song mode (plays the song if it has entries)
song_pos        .byte ?         ; song entry playing
song_left       .byte ?         ; repeats of it left, counting this one
step_flags      .byte ?         ; seq_fire: the step's flags
step_note       .byte ?         ; seq_fire: the step's note, transposed
step_vel        .byte ?         ; step_note_on: its velocity
clock_count     .byte ?         ; MIDI clock: clocks since the step began, 0..5
clock_due       .byte ?         ; MIDI clock: steps due, for seq_tick
clock_wait      .byte ?         ; MIDI clock: nonzero = started, step 0 waits for a clock
clock_ticks     .byte ?         ; MIDI clock: engine ticks since the last step (swing)
gate_clocks     .byte ?         ; MIDI clock: clocks until seq_note's gate closes, 0 = none
out_phase       .word ?         ; MIDI out: clock phase, 6 x the step phase (wraps 6 times a step)
out_inc         .word ?         ; MIDI out: its increment per tick, 6 x seq_inc
.if MIDI_SYSTEM
seq_located     .byte ?         ; nonzero: a song position moved the sequencer (stopped);
                                ; the next continue plays from there
.endif
        .send

.if MIDI_SYSTEM
; seq_song_position's working bytes: not in zero page (full in some test
; builds), at the end of the song block's page (the synth's undo
; variables come after the song block: its undo.asm checks they end before)
        .weak
SEQ_SPP_RAM     = SONG_RAM + $f0
        .endweak
        .virtual SEQ_SPP_RAM
spp_pos         .word ?         ; the position, steps from the start
spp_total       .word ?         ; the song's length in steps (and mod16's divisor)
spp_rem         .word ?         ; mod16's remainder
spp_plen        .byte ?         ; an entry's pattern length
SEQ_SPP_END
        .endvirtual
        .cerror SONG_END > SEQ_SPP_RAM, "the song block runs into seq_song_position's bytes"
.endif

; =============================================================================
; Start-up
; =============================================================================

; -----------------------------------------------------------------------------
; seq_init - empty patterns (rests, length 16), the default patterns in the
; first pages, tempo and swing from the defaults. Power-on RAM is junk, so
; all 64 pages are cleared.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_init
        ; clear every pattern page: notes 0, flags 0 (rest), length 16
        lda #<PATTERN_RAM
        sta seq_ptr
        lda #>PATTERN_RAM
        sta seq_ptr+1
        ldx #NUM_PATTERNS
_page   lda #0
        tay
-       sta (seq_ptr),y
        iny
        bne -
        ldy #PAT_LENGTH
        lda #SEQ_STEPS
        sta (seq_ptr),y
        inc seq_ptr+1
        dex
        bne _page

        ; default patterns into pages 0.. (PAT_BYTES each, contiguous in the table)
        lda #<default_patterns
        sta look_ptr
        lda #>default_patterns
        sta look_ptr+1
        lda #>PATTERN_RAM
        sta seq_ptr+1
        ldx #DEFAULT_PATTERNS
_copy   ldy #PAT_BYTES-1
-       lda (look_ptr),y
        sta (seq_ptr),y
        dey
        bpl -
        clc
        lda look_ptr
        adc #PAT_BYTES
        sta look_ptr
        bcc +
        inc look_ptr+1
+       inc seq_ptr+1
        dex
        bne _copy
.if TEST_EDGES
        ; TEST_EDGES: the awkward cases over pattern 1 (and 2)
        ldy #PAT_BYTES-1
-       lda edges_pattern,y
        sta PATTERN_RAM,y
.if TEST_EDGES == 2
        lda edges_pattern+PAT_BYTES,y
        sta PATTERN_RAM+$100,y
.endif
        dey
        bpl -
.endif

        lda #0                  ; an empty song (power-on RAM is junk), song mode off
        sta song_len
        sta song_on
.if TEST_SONG
        ldx #TEST_SONG_LEN-1    ; TEST_SONG: the test song, song mode on
-       lda test_song_pat,x
        sta song_pat,x
        lda test_song_rep,x
        sta song_rep,x
        lda test_song_tr,x
        sta song_tr,x
        dex
        bpl -
        lda #TEST_SONG_LEN
        sta song_len
        lda #1
        sta song_on
.endif
        lda #NO_NOTE
        sta seq_note
        lda #SEQ_BPM_DEFAULT
        sta seq_bpm
        lda #SEQ_SWING_DEFAULT
        sta seq_swing
        jsr seq_set_tempo
.if TEST_SEQ
        lda #TEST_SEQ_PAT
        sta seq_next
.if TEST_SEQ_NEXT >= 0
        jsr seq_toggle          ; play from the start ...
        lda #TEST_SEQ_NEXT      ; ... and then the next pattern
        sta seq_next
        rts
.else
        jmp seq_toggle          ; play from the start
.endif
.else
        rts
.endif

; -----------------------------------------------------------------------------
; seq_set_tempo - seq_inc, gate_ticks and swing_ticks from seq_bpm and
; seq_swing.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_set_tempo
        lda seq_bpm
        sec
        sbc #BPM_MIN
        tay
        lda bpm_inc_lo,y
        sta seq_inc
        lda bpm_inc_hi,y
        sta seq_inc+1
        lda bpm_gate,y
        sta gate_ticks
        ; MIDI out clock: 6 x the step phase's increment (2 x (2 x inc + inc))
        lda seq_inc
        asl
        sta out_inc
        lda seq_inc+1
        rol
        sta out_inc+1           ; 2 x inc
        clc
        lda out_inc
        adc seq_inc
        sta out_inc
        lda out_inc+1
        adc seq_inc+1
        sta out_inc+1           ; 3 x inc
        asl out_inc
        rol out_inc+1           ; 6 x inc (at most 6 x 4194: no overflow)
        lda bpm_steplen,y
        ; (on to swing_set)

; -----------------------------------------------------------------------------
; swing_set - swing_ticks for a step of A ticks: the delay of an off-beat
; step = step length x swing / 32 = high byte of steplen x swing x 8.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
swing_set
        pha
        lda seq_swing
        asl
        asl
        asl
        tax
        pla
        jsr mul8                ; A = product high byte
        sta swing_ticks
        rts

; =============================================================================
; Transport
; =============================================================================

; -----------------------------------------------------------------------------
; seq_toggle - play from step 0 of seq_next (in song mode: of the song's
; first entry), or stop: the note sounding is released, as if its key were
; let go. Only sets state: step 0 fires on the next tick (seq_tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_toggle
        lda seq_play
        beq _play
        lda #0
        sta seq_play
        sta seq_start
        sta swing_wait
        jsr seq_release         ; (MIDI out: the note off before the stop)
        lda #MIDI_STOP
        jmp out_realtime
_play   lda #0
        sta seq_transpose
        jsr song_active
        bcc _pattern
        ldx #0                  ; song mode: from the first entry
        jsr song_enter
        jmp _go
_pattern
        lda seq_next
        sta seq_pat
_go     lda #MIDI_START
        jsr out_realtime
        lda #0
        sta seq_step
        sta seq_phase
        sta seq_phase+1
        sta out_phase
        sta out_phase+1
        sta swing_wait
        lda #1
        sta seq_start
        sta seq_play
        rts

; -----------------------------------------------------------------------------
; seq_release - the sequencer's note off, if it has one sounding.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_release
        lda #0
        sta seq_gate
        sta gate_clocks
        sta seq_held
        lda seq_note
        cmp #NO_NOTE
        beq +
        ldx #NO_NOTE
        stx seq_note
        jsr out_note_off        ; (keeps A)
        jmp note_off
+       rts

; =============================================================================
; Timing (every engine tick)
; =============================================================================

; -----------------------------------------------------------------------------
; seq_tick - from synth_tick, before the sound engine (so a step's note is
; heard in the same tick): the gate closing, play pressed, the delayed
; off-beat step, the step phase.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_tick
        lda seq_play
        beq _done

        ; a timed gate closes
        lda seq_gate
        beq +
        dec seq_gate
        bne +
        jsr seq_release
+
        ; play pressed: step 0 now (the phase starts from 0 at this tick)
        lda seq_start
        beq +
        lda #0
        sta seq_start
        sta clock_ticks
        lda #MIDI_CLOCK         ; MIDI out: the first clock, with step 0
        jsr out_realtime
        jmp seq_fire
+
        ; a swung off-beat step waiting for its moment
        lda swing_wait
        beq +
        dec swing_wait
        bne +
        jsr seq_fire
+
        ; MIDI clock: the steps its clocks made due (synth_realtime)
        lda params+P_CLOCK
        beq _internal
        inc clock_ticks
        bne +
        dec clock_ticks         ; at most 255
+       lda clock_due
        beq _done
        dec clock_due
        lda clock_ticks         ; the swing from the step length the clock gives
        jsr swing_set
        lda #0
        sta clock_ticks
        jmp seq_step_due

        ; internal: MIDI out's clock (6 a step: the 6th with the step)
_internal
        clc
        lda out_phase
        adc out_inc
        sta out_phase
        lda out_phase+1
        adc out_inc+1
        sta out_phase+1
        bcc +
        lda #MIDI_CLOCK
        jsr out_realtime
+
        ; the step phase: a step is due when it passes 65536
        clc
        lda seq_phase
        adc seq_inc
        sta seq_phase
        lda seq_phase+1
        adc seq_inc+1
        sta seq_phase+1
        bcc _done
        jmp seq_step_due
_done   rts

; -----------------------------------------------------------------------------
; seq_step_due - the next 16th is due: advance; at the pattern's end go on
; from step 0 of the next pattern (seq_next_pat: the queued one, or the
; song's); fire now, or after the swing delay on off-beats.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_step_due
        jsr pat_page
        ldx seq_step
        inx
        ; wrap at the length: ">=", so a pattern shortened while it plays,
        ; or a shorter queued one, never runs past its end
        txa
        ldy #PAT_LENGTH
        cmp (seq_ptr),y
        bcc _in
        jsr seq_next_pat        ; pattern start: the next pattern
        bcs _entry
        sta seq_pat
        lda song_left           ; a repeat of the song entry (0 outside songs)
        beq _no_song
        dec song_left
        jmp _start
_no_song
        lda #0                  ; outside a song: no transpose
        sta seq_transpose
        beq _start              ; always
_entry  jsr song_enter          ; the song's next entry
_start  ldx #0
_in     stx seq_step

        ; off-beats (odd steps) wait for the swing
        txa
        lsr
        bcc seq_fire
        lda swing_ticks
        beq seq_fire
        sta swing_wait
        rts

; -----------------------------------------------------------------------------
; pat_page - seq_ptr = the playing pattern's page.
; clobbers A
; -----------------------------------------------------------------------------
pat_page
        lda #0
        sta seq_ptr
        lda seq_pat
        clc
        adc #>PATTERN_RAM
        sta seq_ptr+1
        rts

; =============================================================================
; Playing a step
; =============================================================================

; -----------------------------------------------------------------------------
; seq_fire - step seq_step of seq_pat is due: play it (SID303's
; docs/sequencer.md, Playing).
;   1. a timed gate still open (only if ticks came late) closes first
;   2. rest: the note held from before ends
;      tie: the held note goes on (nothing held: a rest)
;      note: held by a slide and a new pitch: the new note on, then the old
;            off (the engine slides); held by a slide at the same pitch: as
;            a tie; else the held note (tied) ends and the note starts fresh
;   3. how the note sounding ends (gate_plan)
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_fire
        jsr pat_page
        ; 1. a gate the ticks (or clocks) should have closed already
        lda seq_gate
        ora gate_clocks
        beq +
        jsr seq_release
+
        ; 2. by the step's time
        lda seq_step
        clc
        adc #PAT_FLAGS
        tay
        lda (seq_ptr),y
        sta step_flags
        and #TIME_MASK
        cmp #TIME_NOTE
        beq _note
        cmp #TIME_TIE
        beq _tie
        jmp seq_release         ; rest

_tie    lda seq_note
        cmp #NO_NOTE
        beq _done               ; nothing to tie: a rest
        jmp gate_plan

_note   ldy seq_step            ; (PAT_NOTES = 0)
        lda (seq_ptr),y
        jsr transpose_note
        sta step_note
        lda seq_note
        cmp #NO_NOTE
        beq _fresh
        lda seq_held
        beq _retrigger          ; held by a tie: this note starts anew
        lda step_note
        cmp seq_note
        beq gate_plan           ; slid into the same pitch: a tie
        ; slide: the new note on while the old one still holds the gate
        lda seq_note
        pha
        jsr step_note_on
        pla
        jsr out_note_off        ; (MIDI out too: on, then off; keeps A)
        jsr note_off
        jmp gate_plan
_retrigger
        jsr seq_release
_fresh  jsr step_note_on
        jmp gate_plan
_done   rts

; -----------------------------------------------------------------------------
; step_note_on - note_on for step_note with the step's velocity (accented:
; VEL_ACCENT); it becomes seq_note.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
step_note_on
        ldx #VEL_NORMAL
        lda step_flags
        and #FLAG_ACCENT
        beq +
        ldx #VEL_ACCENT
+       stx step_vel
        lda step_note
        sta seq_note
        jsr note_on
        lda step_note
        ldx step_vel
        jmp out_note_on

; -----------------------------------------------------------------------------
; gate_plan - seq_note sounds from this step: does it go on into the next
; step (this step slides, or the next is a tie), or does its gate close
; after gate_ticks?
; clobbers A, X, Y
; -----------------------------------------------------------------------------
gate_plan
        lda step_flags
        and #FLAG_SLIDE
        sta seq_held            ; FLAG_SLIDE: the next note slides from this one
        bne _goes_on
        jsr step_after
        and #TIME_MASK
        cmp #TIME_TIE
        beq _goes_on            ; (seq_held 0: tied)
        lda params+P_CLOCK
        bne _clocks
        lda gate_ticks          ; internal: after gate_ticks ticks
        sta seq_gate
        rts
_clocks lda #GATE_LEN           ; MIDI clock: after GATE_LEN clocks from now (the
        sta gate_clocks         ; sixths of a step; no step length needed)
        rts
_goes_on
        lda #0
        sta seq_gate
        rts

; -----------------------------------------------------------------------------
; step_after - the flags of the step that plays after seq_step: the next
; one of the pattern, or after its last step, step 0 of the pattern that
; plays next (as seq_step_due will choose). seq_ptr: the playing pattern.
; Out: A = the flags. clobbers A, X, Y
; -----------------------------------------------------------------------------
step_after
        ldx seq_step
        inx
        txa
        ldy #PAT_LENGTH
        cmp (seq_ptr),y
        bcs _wrap
        adc #PAT_FLAGS          ; carry clear here
        tay
        lda (seq_ptr),y
        rts
_wrap   lda #PAT_FLAGS          ; step 0 of the next pattern
        sta look_ptr
        jsr seq_next_pat
        clc
        adc #>PATTERN_RAM
        sta look_ptr+1
        ldy #0
        lda (look_ptr),y
        rts

; -----------------------------------------------------------------------------
; transpose_note - A = note A + seq_transpose, folded by octaves into the
; frequency table's range (LOWEST_NOTE..HIGHEST_NOTE).
; clobbers A
; -----------------------------------------------------------------------------
transpose_note
        clc
        adc seq_transpose       ; (signed: a note and -12..+12 stay in 0..119)
-       cmp #LOWEST_NOTE
        bcs +
        adc #12                 ; below the range: an octave up (carry clear here)
        bcc -                   ; always
+
-       cmp #HIGHEST_NOTE+1
        bcc +
        sbc #12                 ; above it: an octave down (carry set here)
        bcs -                   ; always
+       rts

; =============================================================================
; Song mode
; =============================================================================

; -----------------------------------------------------------------------------
; song_active - carry set if the song plays: song mode on and the song has
; entries. clobbers A
; -----------------------------------------------------------------------------
song_active
        clc
        lda song_on
        beq +
        lda song_len
        cmp #1                  ; carry set: at least one entry
+       rts

; -----------------------------------------------------------------------------
; seq_next_pat - the pattern that plays after the current one ends, without
; changing anything (seq_step_due starts it; step_after asks too, so both
; agree): in song mode the same pattern while the entry has repeats left,
; else the next entry's (after the last, the first: the song loops);
; outside song mode seq_next.
; Out: A = pattern; carry set = a new song entry, X = its index.
; clobbers A, X
; -----------------------------------------------------------------------------
seq_next_pat
        jsr song_active
        bcc _queued
        lda song_left
        cmp #2
        bcs _repeat             ; repeats left: the same pattern again
        ldx song_pos
        inx
        cpx song_len
        bcc +
        ldx #0                  ; past the end (or deleted under it): the first
+       lda song_pat,x
        sec
        rts
_repeat lda seq_pat
        clc
        rts
_queued lda seq_next
        clc
        rts

; -----------------------------------------------------------------------------
; song_enter - start song entry X: its pattern plays (seq_pat) with all its
; repeats and its transpose, and the step screen shows it (edit_pat follows
; the song while it plays).
; clobbers A
; -----------------------------------------------------------------------------
song_enter
        stx song_pos
        lda song_rep,x
        sta song_left
        lda song_tr,x
        sta seq_transpose
        lda song_pat,x
        sta seq_pat
        sta edit_pat
        rts

; -----------------------------------------------------------------------------
; song_toggle - song mode on / off. Turned on while playing, the song starts
; from its first entry at the next pattern start; turned off, the pattern
; on the step screen plays from the next pattern start, untransposed.
; clobbers A
; -----------------------------------------------------------------------------
song_toggle
        lda song_on
        eor #1
        sta song_on
        beq _off
        lda #$ff                ; "before the first entry", no repeats left:
        sta song_pos            ; seq_next_pat gives entry 0
        lda #0
        sta song_left
        rts
_off    lda #0
        sta song_left
        lda edit_pat
        sta seq_next
        rts

; =============================================================================
; MIDI clock in
; =============================================================================

; -----------------------------------------------------------------------------
; synth_realtime - core hook (MIDI_REALTIME): a MIDI realtime byte, from the
; main loop. Only with the Clock parameter on MIDI; only sets state, the
; steps fire from synth_tick (seq_tick):
;   $FA start: play from the start (the song's first entry in song mode);
;       step 0 waits for the first clock
;   $F8 clock: every 6th makes a step due; a gate on clocks counts down
;   $FB continue: play on from where it stopped
;   $FC stop: stop (the note sounding is released)
; A: the byte. clobbers A, X, Y
; -----------------------------------------------------------------------------
MIDI_CLOCK      = $f8
MIDI_START      = $fa
MIDI_CONTINUE   = $fb
MIDI_STOP       = $fc

.if SEQ_REALTIME_OWN
seq_realtime                    ; (the synth's synth_realtime passes the bytes on)
.else
synth_realtime
.endif
        ldx params+P_CLOCK
        beq _done               ; internal clock: not ours
        cmp #MIDI_CLOCK
        beq _clock
        cmp #MIDI_START
        beq _start
        cmp #MIDI_CONTINUE
        beq _continue
        cmp #MIDI_STOP
        beq _stop
_done   rts

_clock  lda seq_play
        beq _done
        ; a gate on clocks: closed by seq_tick on its next tick
        lda gate_clocks
        beq +
        dec gate_clocks
        bne +
        lda #1
        sta seq_gate
+       lda clock_wait
        beq _count
        lda #0                  ; the first clock after start: step 0
        sta clock_wait
        sta clock_count
        lda #1
        sta seq_start
        rts
_count  inc clock_count
        lda clock_count
        cmp #CLOCKS_PER_STEP
        bcc _done
        lda #0
        sta clock_count
        inc clock_due
        rts

_start
.if MIDI_SYSTEM
        lda #0
        sta seq_located         ; from the start: a song position is forgotten
.endif
        lda seq_play
        beq +
        jsr seq_toggle          ; playing: stop first, then from the start
+       jsr seq_toggle          ; play (song or pattern start, seq_start set)
        lda #0
        sta seq_start           ; ... but step 0 waits for the first clock
        sta clock_due
        sta clock_count
        lda #1
        sta clock_wait
        rts

_continue
        lda seq_play
        bne _done
.if MIDI_SYSTEM
        lda seq_located
        beq +
        ; after a song position: as a start, but from the located step
        ; (seq_pat, seq_step, the song entry): its first clock fires it
        lda #0
        sta seq_located
        sta clock_due
        sta clock_count
        sta swing_wait
        sta seq_start
        lda #1
        sta clock_wait
        sta seq_play
        rts
+
.endif
        lda #0
        sta clock_due
        lda #1
        sta seq_play            ; the clocks go on counting from where they were
        rts

_stop   lda seq_play
        beq _done
        jmp seq_toggle

; -----------------------------------------------------------------------------
; clock_reset - the Clock parameter changed: no MIDI clock state left over.
; clobbers A
; -----------------------------------------------------------------------------
clock_reset
        lda #0
        sta clock_count
        sta clock_due
        sta clock_wait
        rts

; =============================================================================
; MIDI pattern select, song select, song position (core PATTERN_CC, MIDI_SYSTEM)
; =============================================================================
; The synth points its hooks here (synth_pattern = seq_pattern, ...), or
; calls these from hooks of its own.

.if PATTERN_CC
; -----------------------------------------------------------------------------
; seq_pattern - the pattern controller (value A, 0..63 = pattern 1..64), as
; F1/F2 on the step screen: the pattern plays from the next pattern start
; (stopped: from play), and the step screen shows it; song mode goes off.
; Values 64..127 do nothing.
; clobbers A
; -----------------------------------------------------------------------------
seq_pattern
        cmp #NUM_PATTERNS
        bcs _done
        sta seq_next
        sta edit_pat
        lda #0                  ; song mode off (as song_toggle turning it off)
        sta song_on
        sta song_left
_done   rts
.endif

.if MIDI_SYSTEM
; -----------------------------------------------------------------------------
; seq_song_select - MIDI song select (any song: the synth holds one): song
; mode on, as song_toggle turning it on; already on, nothing changes.
; clobbers A
; -----------------------------------------------------------------------------
seq_song_select
        lda song_on
        bne +
        jmp song_toggle
+       rts

; -----------------------------------------------------------------------------
; seq_song_position - MIDI song position pointer: A = LSB, X = MSB (7 bits
; each), the position in MIDI beats (16ths: 6 clocks, a step) from the
; start. Only with the Clock on MIDI and the sequencer stopped (the MIDI
; rule: a master sends it while stopped); else ignored. It moves the
; sequencer there, and the next continue plays from it (synth_realtime):
;   song mode (the song has entries): the song's length is the sum of each
;   entry's pattern length x repeats; the position wraps at it (the song
;   loops). The entry it falls in plays with its transpose, the repeats
;   before it counted off, from the step it falls on.
;   else: the queued pattern (seq_next), from the position modulo its length.
; The step screen shows the pattern (edit_pat). Start forgets it.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_song_position
        ldy params+P_CLOCK
        beq _ignore             ; internal clock: no song positions
        ldy seq_play
        beq +
_ignore rts                     ; playing: ignored
+
        ; the position: X * 128 + A
        sta spp_pos
        txa
        lsr                     ; MSB bit 0 -> carry
        sta spp_pos+1
        lda #0
        ror                     ; -> bit 7
        ora spp_pos
        sta spp_pos
        jsr song_active
        bcs _song

        ; pattern mode: the queued pattern, untransposed
        lda #0
        sta seq_transpose
        sta song_left
        lda seq_next
        sta seq_pat
        sta edit_pat
        tax
        jsr pat_len             ; A = its length
        jsr spp_mod             ; spp_pos mod A
        sta seq_step
        jmp _located

        ; song mode: the song's length in steps
_song   lda #0
        sta spp_total
        sta spp_total+1
        tax
-       jsr entry_steps         ; A = entry X's steps (pattern length x repeats)
        clc
        adc spp_total
        sta spp_total
        bcc +
        inc spp_total+1
+       inx
        cpx song_len
        bcc -
        jsr mod16               ; spp_pos = spp_pos mod the song's length

        ; the entry it falls in: take whole entries off
        ldx #0
-       jsr entry_steps
        sta spp_total           ; (the entry's steps, 1..144)
        lda spp_pos+1
        bne _past               ; >= 256: past this entry
        lda spp_pos
        cmp spp_total
        bcc _found
_past   sec
        lda spp_pos
        sbc spp_total
        sta spp_pos
        bcs +
        dec spp_pos+1
+       inx
        bne -                   ; always (it falls in one before song_len)

        ; entry X, spp_pos (< 144) steps in: the repeats before it, the step
_found  jsr song_enter          ; its pattern, repeats, transpose; edit_pat
        lda spp_pos
        ldx song_left
-       cmp spp_plen
        bcc +
        sbc spp_plen            ; (carry set here)
        dex                     ; a repeat played
        bne -                   ; always (the position is inside the entry)
+       stx song_left
        sta seq_step
_located
        lda #1
        sta seq_located
_done   rts

; -----------------------------------------------------------------------------
; pat_len - A = the length of pattern X (1..SEQ_STEPS). clobbers A, Y, look_ptr
; entry_steps - A = song entry X's steps: its pattern's length (also in
; spp_plen) x its repeats (at most 16 x 9 = 144). keeps X; clobbers A, Y, look_ptr
; -----------------------------------------------------------------------------
pat_len
        lda #PAT_LENGTH
        sta look_ptr
        txa
        clc
        adc #>PATTERN_RAM
        sta look_ptr+1
        ldy #0
        lda (look_ptr),y
        rts

entry_steps
        stx spp_rem             ; (a spare byte here)
        lda song_pat,x
        tax
        jsr pat_len
        sta spp_plen
        ldx spp_rem
        ldy song_rep,x
        lda #0
        clc
-       adc spp_plen            ; (no carry: at most 144)
        dey
        bne -
        rts

; -----------------------------------------------------------------------------
; spp_mod - A = spp_pos mod A (A = 1..255). mod16 - spp_pos = spp_pos mod
; spp_total (16 bits, spp_total > 0), by shifting and subtracting.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
spp_mod
        sta spp_total
        lda #0
        sta spp_total+1
        jsr mod16
        lda spp_pos
        rts

mod16
        lda #0
        sta spp_rem
        sta spp_rem+1
        ldx #16
-       asl spp_pos             ; the dividend's top bit into the remainder
        rol spp_pos+1
        rol spp_rem
        rol spp_rem+1
        sec
        lda spp_rem
        sbc spp_total
        tay
        lda spp_rem+1
        sbc spp_total+1
        bcc +                   ; the remainder is smaller: keep it
        sta spp_rem+1
        sty spp_rem
+       dex
        bne -
        lda spp_rem
        sta spp_pos
        lda spp_rem+1
        sta spp_pos+1
        rts
.endif

; =============================================================================
; MIDI out
; =============================================================================

; -----------------------------------------------------------------------------
; out_realtime - send realtime byte A (start, clock, stop) if MIDI out is on
; and the clock is internal (with MIDI clock in, the master sends them).
; clobbers A, X
; -----------------------------------------------------------------------------
out_realtime
        ldx params+P_MIDIOUT
        beq _done
        ldx params+P_CLOCK
        bne _done
        jmp out_byte
_done   rts

; -----------------------------------------------------------------------------
; out_note_on - note A on, velocity X, if MIDI out is on: on the MIDI
; channel (Omni: channel 1). out_note_off - note A off (note off, velocity
; 0); out_note_off_now does it even with MIDI out off (it was just turned
; off: the receiver must not keep a note). Keep A; clobber X, Y.
; -----------------------------------------------------------------------------
NOTE_ON_STATUS  = $90
NOTE_OFF_STATUS = $80

out_note_on
        ldy params+P_MIDIOUT
        beq _done
        pha
        stx step_vel
        ldy #NOTE_ON_STATUS
        jsr out_message
        pla
_done   rts

out_note_off
        ldy params+P_MIDIOUT
        bne out_note_off_now
        rts
out_note_off_now
        pha
        ldx #0
        stx step_vel
        ldy #NOTE_OFF_STATUS
        jsr out_message
        pla
_done   rts

; out_message - status Y on the MIDI channel, data A, data step_vel.
; clobbers A, X, Y
out_message
        pha
        tya
        ldy params+P_CHANNEL    ; 0 = omni (channel 1), 1..16
        beq +
        dey
+       sty out_tmp
        ora out_tmp
        jsr out_byte
        pla
        jsr out_byte
        lda step_vel
        ; (on to out_byte)

; -----------------------------------------------------------------------------
; out_byte - queue byte A for MIDI out (core midi_send); TEST_LOG builds
; also log it with its tick. clobbers X (keeps A, Y)
; -----------------------------------------------------------------------------
out_byte
.if TEST_LOG
        jsr log_out
.endif
        jmp midi_send

; -----------------------------------------------------------------------------
; seq_forget - all notes off: the sequencer's note is gone (MIDI out: its
; note off); its next note starts fresh (it plays on, if playing).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_forget
        lda seq_note
        cmp #NO_NOTE
        beq +
        jsr out_note_off
+       lda #0
        sta seq_gate
        sta gate_clocks
        sta seq_held
        lda #NO_NOTE
        sta seq_note
        rts
