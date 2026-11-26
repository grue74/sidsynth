; sequencer.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Step sequencer (docs/sequencer.md): 64 patterns of 13 sounds x 16 steps,
; one byte per cell (bits 0-1: level 0 off, 1 soft, 2 normal, 3 accent).
; Tempo comes from a 16-bit step phase that grows every engine tick, so any
; BPM is exact; swing delays the off-beat 16ths. Steps fire from
; synth_tick (seq_tick), never from the keyboard handler. Song mode chains
; patterns: a list of up to SONG_MAX entries (pattern, repeats) that plays
; in a loop. Live record writes the hits played (MIDI, keys) into the
; pattern playing, quantised to the nearest step. With the Clock parameter
; on MIDI, MIDI clock (24 per quarter note: 6 per step), start, continue and
; stop drive the steps instead of the tempo. With MIDI out on, the steps'
; hits go out as notes, and with the internal clock start, clock and stop.

; pattern memory: one 256-byte page per pattern
PATTERN_RAM     = $8000         ; $8000-$BFFF: 64 patterns (RAM: BASIC ROM is banked out)
NUM_PATTERNS    = 64
PAT_LENGTH      = NUM_SOUNDS * SEQ_STEPS ; offset of the pattern's length byte (1..16)
        .cerror PAT_LENGTH >= 256, "a pattern must fit one page"
        .cerror PATTERN_RAM + NUM_PATTERNS * 256 > $c000, "patterns run into $C000"
CELL_LEVEL      = %00000011     ; cell bits: level

; song memory ($C140-$C1FF is free for the synth, core framework.asm): the
; entries and the length together, one block for the disk (phase F)
SONG_MAX        = 64            ; entries
SONG_REP_MAX    = 9             ; repeats of an entry, 1..9 (one digit on screen)
song_pat        = $c140         ; SONG_MAX bytes: pattern of each entry, 0..63
song_rep        = song_pat + SONG_MAX ; SONG_MAX bytes: its repeats, 1..SONG_REP_MAX
song_len        = song_rep + SONG_MAX ; entries in the song, 0..SONG_MAX
SONG_END        = song_len + 1  ; end of the song block
        .cerror SONG_END > $c200, "the song runs into cc_map at $C200"

        .weak
SEQ_BPM_DEFAULT = 125           ; tempo at start
SEQ_SWING_DEFAULT = 0           ; swing at start, 0..SWING_MAX
TEST_SEQ = 0                    ; 1 = start playing at once (tempo/swing tests)
TEST_SEQ_PAT = 0                ; pattern TEST_SEQ plays (0 = pattern 1)
TEST_SONG = 0                   ; 1 = the bass-and-drums demo's drum part (tables.py DEMO_*)
                                ; as patterns 14.. and the song, song mode on (with
                                ; TEST_SEQ: the sequencer plays it; demos/bass_and_drums.py)
TEST_STRESS = 0                 ; 1 = one more default pattern, number 14: the CPU stress
                                ; pattern (tables.py: the kick on the quarters, every
                                ; other sound on every step)
TEST_REC = 0                    ; 1 = record on from the start (live record test)
TEST_CLOCK = 0                  ; Clock parameter at start: 0 internal, 1 MIDI
TEST_MIDIOUT = 0                ; MIDI out parameter at start: 0 off, 1 on
TEST_DRIVE = 0                  ; Disk drive parameter at start: 0 = drive 8 ... 8 = drive 16
        .endweak
CLOCKS_PER_STEP = 6             ; MIDI clock: 24 per quarter note, a step is a 16th
SWING_MAX       = 15            ; swing delays odd steps by swing/32 of a step (0..47 %)

        .section zp
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
seq_ptr         .word ?         ; seq_fire: the pattern's page
seq_i           .byte ?         ; seq_hits: next position in fire_order
seq_hits_on     .byte ?         ; nonzero: seq_step's hits are still being fired (seq_hits)
seq_fired       .byte ?         ; seq_hits: hits fired in this tick
seq_waited      .byte ?         ; seq_hits: nonzero = the next hit waited a tick for time
step_voices     .byte ?         ; voices (voice_bit) the step's hits have taken so far
sound_now       .byte ?         ; seq_hits: the sound being fired (hits_after)
mute            .word ?         ; muted sounds, bit = sound (0..12)
song_on         .byte ?         ; nonzero: song mode (plays the song if it has entries)
song_pos        .byte ?         ; song entry playing
song_left       .byte ?         ; repeats of it left, counting this one
rec_on          .byte ?         ; nonzero: live record
skip_now        .word ?         ; sounds (mute_bit) the current step must not fire once:
                                ; recorded live and played already (rec_hit)
skip_next       .word ?         ; the same for the next step (moves to skip_now)
hit_level       .byte ?         ; seq_hits: the cell's level / rec_hit: the level to record
rec_ptr         .word ?         ; rec_hit: the target pattern's page
clock_count     .byte ?         ; MIDI clock: clocks since the step began, 0..5
clock_due       .byte ?         ; MIDI clock: steps due, for seq_tick
clock_wait      .byte ?         ; MIDI clock: nonzero = started, step 0 waits for a clock
clock_ticks     .byte ?         ; MIDI clock: engine ticks since the last step (swing)
out_phase       .word ?         ; MIDI out: clock phase, 6 x the step phase (wraps 6 times a step)
out_inc         .word ?         ; MIDI out: its increment per tick, 6 x seq_inc
seq_located     .byte ?         ; nonzero: a song position moved the sequencer (stopped);
                                ; the next continue plays from there
.if TEST_LOG
log_ptr         .word ?         ; TEST_LOG: the next entry of the hit log
.endif
        .send

; seq_song_position's working bytes, and TEST_LOG's tick: not in zero page
; (full in some builds), in the free page at $C700
        .virtual $c700
spp_pos         .word ?         ; seq_song_position: the position, steps from the start
spp_total       .word ?         ;   the song's length in steps (and mod16's divisor)
spp_rem         .word ?         ;   mod16's remainder
spp_plen        .byte ?         ;   an entry's pattern length
.if TEST_LOG
log_tick        .word ?         ; TEST_LOG: +1 every synth tick (engine.asm)
.endif
        .endvirtual

.if TEST_LOG
; TEST_LOG: every hit the sequencer fires, 4 bytes: tick (low, high), sound,
; level (tools/pattern_check.py reads it in VICE)
HIT_LOG         = $c800
HIT_LOG_END     = $d000
.endif

; live record: velocity -> level, the nearest of level_vel (55, 100, 127)
REC_NORMAL_MIN  = 78            ; from here normal
REC_ACCENT_MIN  = 114           ; from here accent

; =============================================================================
; Start-up
; =============================================================================

; -----------------------------------------------------------------------------
; seq_init - empty patterns of length 16, the default patterns in the first
; ones, tempo and swing from the defaults. Power-on RAM is junk, so all 64
; pages are cleared. (TEST_LOG: the hit log empty too.)
; -----------------------------------------------------------------------------
seq_init
.if TEST_LOG
        jsr log_init
.endif
        ; clear every pattern page
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

        ; default patterns into pages 0.. (208 cells each, contiguous in the table)
        lda #<default_patterns
        sta prog
        lda #>default_patterns
        sta prog+1
        lda #>PATTERN_RAM
        sta seq_ptr+1
        ldx #DEFAULT_PATTERNS
_copy   ldy #PAT_LENGTH-1
-       lda (prog),y
        sta (seq_ptr),y
        dey
        cpy #$ff
        bne -
        clc
        lda prog
        adc #PAT_LENGTH
        sta prog
        bcc +
        inc prog+1
+       inc seq_ptr+1
        dex
        bne _copy

        .cerror TEST_SONG && TEST_STRESS, "TEST_SONG and TEST_STRESS both add patterns 14.."
.if TEST_SONG
        .cerror demo_patterns != default_patterns + (DEFAULT_PATTERNS - DEMO_PATTERN_COUNT) * PAT_LENGTH, "demo_patterns must follow default_patterns"
.endif
        ; an empty song (power-on RAM is junk)
        lda #0
        sta song_len
.if TEST_SONG
        ldx #TEST_SONG_LEN-1    ; TEST_SONG: the demo's song, song mode on
-       lda test_song_pat,x
        sta song_pat,x
        lda test_song_rep,x
        sta song_rep,x
        dex
        bpl -
        lda #TEST_SONG_LEN
        sta song_len
        lda #1
        sta song_on
.endif

        lda #SEQ_BPM_DEFAULT
        sta seq_bpm
        lda #SEQ_SWING_DEFAULT
        sta seq_swing
        jsr seq_set_tempo
.if TEST_REC
        lda #1
        sta rec_on
.endif
.if TEST_SEQ
        lda #TEST_SEQ_PAT
        sta seq_next
        sta edit_pat            ; and show it
        jmp seq_toggle          ; play from the start
.else
        rts
.endif

; -----------------------------------------------------------------------------
; seq_set_tempo - seq_inc and swing_ticks from seq_bpm and seq_swing.
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
        rol out_inc+1           ; 6 x inc (at most 6 x 2097: no overflow)
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
        jsr mul8
        sta swing_ticks
        rts

; =============================================================================
; Transport
; =============================================================================

; -----------------------------------------------------------------------------
; seq_toggle - play from step 0 of seq_next (in song mode: of the song's
; first entry), or stop (sounds ring out, as on the 808). Only sets state:
; step 0 fires on the next tick (seq_tick). MIDI out (internal clock):
; start / stop.
; clobbers A, X
; -----------------------------------------------------------------------------
seq_toggle
        lda seq_play
        beq _play
        lda #0
        sta seq_play
        sta seq_start
        sta swing_wait
        sta seq_hits_on
        jsr skip_clear
        lda #MIDI_STOP
        jmp out_realtime
_play   jsr song_active
        bcc _pattern
        ; song mode: from the first entry; the grid shows what plays
        ldx #0
        jsr song_enter
        jmp _go
_pattern
        lda seq_next
        sta seq_pat
_go     jsr skip_clear
        lda #MIDI_START
        jsr out_realtime
        lda #0
        sta out_phase
        sta out_phase+1
        sta seq_step
        sta seq_phase
        sta seq_phase+1
        sta swing_wait
        lda #1
        sta seq_start
        sta seq_play
        rts

; =============================================================================
; Timing (every engine tick)
; =============================================================================

; -----------------------------------------------------------------------------
; seq_tick - from synth_tick, after the voices: start, the delayed off-beat
; step, the phase (or the steps MIDI clock made due); then fire what the
; tick's time allows of the step's hits (seq_hits).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_tick
        lda seq_play
        beq _done

        ; play pressed: step 0 now
        lda seq_start
        beq +
        inc seq_pass            ; (live record's undo: a pass begins)
        lda #0
        sta seq_start
        sta clock_ticks
        lda #MIDI_CLOCK         ; MIDI out: the first clock, with step 0
        jsr out_realtime
        jsr seq_fire
        jmp seq_hits
+
        ; a swung off-beat step waiting for its moment
        lda swing_wait
        beq +
        dec swing_wait
        bne +
        jsr seq_fire
+
        ; MIDI clock: the steps its clocks made due
        lda params+P_CLOCK
        beq _internal
        inc clock_ticks
        bne +
        dec clock_ticks         ; at most 255
+       lda clock_due
        beq _hits
        dec clock_due
        ; the swing from the step length the clock gives
        lda clock_ticks
        jsr swing_set
        lda #0
        sta clock_ticks
        jsr seq_step_due
_hits   jmp seq_hits

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
        ; the step phase, a step is due when it passes 65536
        clc
        lda seq_phase
        adc seq_inc
        sta seq_phase
        lda seq_phase+1
        adc seq_inc+1
        sta seq_phase+1
        bcc +
        jsr seq_step_due
+       jmp seq_hits
_done   rts

; -----------------------------------------------------------------------------
; seq_step_due - the next 16th is due (internal tempo; MIDI clock in will
; call this too): advance; at the pattern's end go to the next pattern
; (seq_next_pat: the queued one, or the song's); fire now, or after the
; swing delay on off-beats.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_step_due
        ; the next step's skips become the current step's
        lda skip_next
        sta skip_now
        lda skip_next+1
        sta skip_now+1
        lda #0
        sta skip_next
        sta skip_next+1

        ldx seq_step
        inx
        ; wrap at the length: ">=", so a pattern shortened while it plays,
        ; or a shorter queued one, never runs past its end
        lda seq_pat
        clc
        adc #>PATTERN_RAM
        sta seq_ptr+1
        lda #PAT_LENGTH
        sta seq_ptr
        txa
        ldy #0
        cmp (seq_ptr),y
        bcc _in
        inc seq_pass            ; (live record's undo: a pass begins)
        ; pattern start: the next pattern (seq_next, or the song's)
        jsr seq_next_pat
        bcs _entry
        sta seq_pat
        lda song_left           ; a repeat of the song entry (0 outside songs)
        beq +
        dec song_left
+       ldx #0
        beq _in                 ; always
_entry  jsr song_enter          ; the song's next entry
        ldx #0
_in     stx seq_step

        ; off-beats (odd steps) wait for the swing
        txa
        lsr
        bcc seq_fire
        lda swing_ticks
        beq seq_fire
        sta swing_wait
        rts

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
; changing anything (seq_step_due starts it; live record asks too, so both
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
; repeats, and the grid shows it (edit_pat follows the song while it plays).
; clobbers A
; -----------------------------------------------------------------------------
song_enter
        stx song_pos
        lda song_rep,x
        sta song_left
        lda song_pat,x
        sta seq_pat
        sta edit_pat
        rts

; -----------------------------------------------------------------------------
; song_toggle - song mode on / off. Turned on while playing, the song starts
; from its first entry at the next pattern start; turned off, the pattern
; on the grid plays from the next pattern start (seq_next = edit_pat; while
; the song played, that is the pattern playing, unless F1/F2 changed it).
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

; -----------------------------------------------------------------------------
; seq_fire - seq_step of seq_pat is due: seq_hits fires its cells from now
; on, sounds in fire_order (highest priority first). Hits of a step not
; finished yet are given up (cannot happen at any tempo: a step is 30+ ticks).
; clobbers A
; -----------------------------------------------------------------------------
seq_fire
        lda #0
        sta seq_i
        sta step_voices
        sta seq_waited
        lda #1
        sta seq_hits_on

        rts

; -----------------------------------------------------------------------------
; seq_hits - fire the step's hits, from fire_order position seq_i on, while
; the tick has time: a hit costs up to ~HIT_CYCLES (voice choice and setup;
; the voice launches on a following tick, synth_tick). A hit fires if the
; next timer interrupt is at least HIT_CYCLES away and no tick is waiting;
; else it and the rest wait for the next tick, in the same order. A hit
; waits at most one tick: the tick after, the first hit fires anyway.
; Muted sounds and empty cells are skipped, and so are sounds live record
; played already for this step (skip_now).
; Hits of a busy step so come a tick apart instead of stalling every
; voice's tick (docs/sequencer.md, CPU). A hit never steals a voice an
; earlier hit of the same step took (pick_keep): with all hits in one tick,
; as before, the levels they compare stood still; now they move between
; the hits, and a weaker hit could take over a stronger one's voice.
; clobbers A, X, Y, prog, vx (voice_start)
; -----------------------------------------------------------------------------
HIT_CYCLES      = 768           ; time a hit may take, cycles; a multiple of 256: only
                                ; timer A's high byte (cycles to the next tick / 256) is read

seq_hits
        lda seq_hits_on
        bne +
        jmp _done
+
        lda seq_pat
        clc
        adc #>PATTERN_RAM
        sta seq_ptr+1
        lda seq_step
        sta seq_ptr             ; (seq_ptr),y with y = sound x 16
        ldy #0
        sty seq_fired           ; no hit fired in this tick yet
        iny
        sty launched            ; hits set up their voices only; launches next tick
        lda step_voices
        sta pick_keep           ; a later hit never steals an earlier one's voice

_sound  ldx seq_i
        cpx #NUM_SOUNDS
        bne +
        jmp _end
+
        lda fire_order,x
        tax                     ; X = sound
        ; muted?
        lda mute_bit,x
        cpx #8
        bcs +
        and mute
        bne _next
        beq _cell
+       and mute+1
        bne _next
_cell   lda sound_cell_ofs,x
        tay
        lda (seq_ptr),y
        and #CELL_LEVEL
        beq _next
        sta hit_level

        ; recorded live in this pass and played then (rec_hit): not again
        lda mute_bit,x
        cpx #8
        bcs +
        and skip_now
        beq _hit
        eor skip_now            ; that bit off: once only
        sta skip_now
        jmp _next
+       and skip_now+1
        beq _hit
        eor skip_now+1
        sta skip_now+1
        jmp _next

        ; a hit: time for it in this tick? If not, it waits for the next
        ; tick, but only once: then it fires whatever the time
_hit    ldy tick_count
        cpy tick_done
        bne _no_time            ; already behind
        ldy CIA1_TA_HI
        cpy #>HIT_CYCLES
        bcs _fire               ; time enough
_no_time
        ldy seq_fired
        bne _done               ; one fired in this tick: the rest next tick
        ldy seq_waited
        bne _fire               ; it waited a tick already: now
        inc seq_waited
        bne _done               ; always
_fire   inc seq_fired
.if TEST_LOG
        jsr log_hit
.endif
        ldy #0
        sty seq_waited
        ldy hit_level
        lda level_vel,y
        jsr out_note            ; MIDI out (also when the voices then drop it)
        ldy hit_level
        lda level_vel,y
        sta new_vel
        sta last_vel
        stx new_sound
        lda #PAIR_ASK           ; a ring sound's pair must leave voices for the
        sta pair_room           ; step's hits still to come: voice_pick asks
        jsr voice_pick          ; hits_after if a pair could be had at all
        bcs _next               ; dropped (everything sounding matters more)
        lda voice_bit,x
        ora step_voices
        sta step_voices
        sta pick_keep
        jsr voice_start
_next   inc seq_i
        jmp _sound

_end    lda #0
        sta seq_hits_on         ; the step is done
_done   lda #0
        sta pick_keep           ; MIDI notes may take any voice
        sta pair_room           ; and a free pair
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
;   $F8 clock: every 6th makes a step due
;   $FB continue: play on from where it stopped
;   $FC stop: stop (sounds ring out)
; A: the byte. clobbers A, X, Y
; -----------------------------------------------------------------------------
MIDI_CLOCK      = $f8
MIDI_START      = $fa
MIDI_CONTINUE   = $fb
MIDI_STOP       = $fc

synth_realtime
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
        lda clock_wait
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

_start  lda #0
        sta seq_located         ; from the start: a song position is forgotten
        lda seq_play
        beq +
        jsr seq_toggle          ; playing: stop first, then from the start
+       jsr seq_toggle          ; play (song or pattern start, seq_start set)
        lda #0
        sta seq_start           ; ... but step 0 waits for the first clock
        sta clock_due
        sta clock_count         ; (live record before it: step 0)
        lda #1
        sta clock_wait
        rts

_continue
        lda seq_play
        bne _done
        lda seq_located
        beq +
        ; after a song position: as a start, but from the located step
        ; (seq_pat, seq_step, the song entry): its first clock fires it
        jsr skip_clear
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
+       lda #0
        sta clock_due
        lda #1
        sta seq_play            ; the clocks go on counting from where they were
        rts

_stop   lda seq_play
        beq _done
        jmp seq_toggle

; =============================================================================
; MIDI pattern select, song select, song position (core PATTERN_CC,
; MIDI_SYSTEM; the core's sequencer module has the same, with transposes)
; =============================================================================

; -----------------------------------------------------------------------------
; seq_pattern - the pattern controller (value A, 0..63 = pattern 1..64), as
; F1/F2 on the grid: the pattern plays from the next pattern start
; (stopped: from play), and the grid shows it; song mode goes off. Values
; 64..127 do nothing.
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

; -----------------------------------------------------------------------------
; seq_song_select - MIDI song select (any song: SID808 holds one): song mode
; on, as song_toggle turning it on; already on, nothing changes.
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
; start. Only with the Clock on MIDI and the sequencer stopped; else
; ignored. It moves the sequencer there, and the next continue plays from
; it (synth_realtime):
;   song mode (the song has entries): the song's length is the sum of each
;   entry's pattern length x repeats; the position wraps at it. The entry it
;   falls in plays, the repeats before it counted off, from its step.
;   else: the queued pattern (seq_next), from the position modulo its length.
; The grid shows the pattern (edit_pat). Start forgets it.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
seq_song_position
        ldy params+P_CLOCK
        beq _ignore             ; internal clock: no song positions
        ldy seq_play
        beq +
_ignore rts                     ; playing: ignored
+       ; the position: X * 128 + A
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

        ; pattern mode: the queued pattern
        lda #0
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
_found  jsr song_enter          ; its pattern and repeats; edit_pat
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
        rts

; -----------------------------------------------------------------------------
; pat_len - A = the length of pattern X (1..SEQ_STEPS). clobbers A, Y, rec_ptr
; entry_steps - A = song entry X's steps: its pattern's length (also in
; spp_plen) x its repeats (at most 16 x 9 = 144). keeps X; clobbers A, Y, rec_ptr
; (rec_ptr: live record's, free outside rec_hit)
; -----------------------------------------------------------------------------
pat_len
        lda #PAT_LENGTH
        sta rec_ptr
        txa
        clc
        adc #>PATTERN_RAM
        sta rec_ptr+1
        ldy #0
        lda (rec_ptr),y
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

.if TEST_LOG
; -----------------------------------------------------------------------------
; log_init - TEST_LOG: the hit log empty (zeros) and log_tick 1, so an entry
; never has tick 0 (tools/pattern_check.py reads up to the first zero tick).
; log_hit - append (log_tick, sound X, hit_level) to the hit log, until it
; is full. keeps A, X; clobbers Y
; -----------------------------------------------------------------------------
log_init
        lda #<HIT_LOG
        sta log_ptr
        lda #>HIT_LOG
        sta log_ptr+1
        ldx #>(HIT_LOG_END - HIT_LOG)
        lda #0
        tay
-       sta (log_ptr),y
        iny
        bne -
        inc log_ptr+1
        dex
        bne -
        lda #>HIT_LOG
        sta log_ptr+1
        lda #1
        sta log_tick
        lda #0
        sta log_tick+1
        rts

log_hit
        ldy log_ptr+1
        cpy #>HIT_LOG_END
        bcs _full
        pha
        ldy #0
        lda log_tick
        sta (log_ptr),y
        iny
        lda log_tick+1
        sta (log_ptr),y
        iny
        txa
        sta (log_ptr),y
        iny
        lda hit_level
        sta (log_ptr),y
        clc
        lda log_ptr
        adc #4
        sta log_ptr
        bcc +
        inc log_ptr+1
+       pla
_full   rts
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
        jmp midi_send
_done   rts

; -----------------------------------------------------------------------------
; out_note - send sound X's hit, velocity A, if MIDI out is on: note on and
; at once note off (a drum hit has no length), on the MIDI channel (Omni:
; channel 10, the GM drum channel), with the sound's GM note (sound_gm).
; X: sound (preserved). clobbers A, Y
; -----------------------------------------------------------------------------
NOTE_ON_STATUS  = $90
NOTE_OFF_STATUS = $80
GM_DRUM_CHANNEL = 10

out_note
        ldy params+P_MIDIOUT
        beq _done
        stx new_sound           ; (seq_hits sets it too; X is needed back)
        pha
        ldy params+P_CHANNEL    ; 0 = omni, 1..16
        bne +
        ldy #GM_DRUM_CHANNEL
+       dey
        tya
        ora #NOTE_ON_STATUS
        jsr midi_send           ; note on: status, note, velocity
        ldy new_sound
        lda sound_gm,y
        jsr midi_send
        pla
        jsr midi_send
        ldy params+P_CHANNEL
        bne +
        ldy #GM_DRUM_CHANNEL
+       dey
        tya
        ora #NOTE_OFF_STATUS
        jsr midi_send           ; note off: status, note, velocity 0
        ldy new_sound
        lda sound_gm,y
        jsr midi_send
        lda #0
        jsr midi_send
        ldx new_sound
_done   rts

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

; -----------------------------------------------------------------------------
; hits_after - how many of the step's hits come after fire_order position
; seq_i (unmuted cells that aren't off), so a ring sound's voice pair
; leaves them voices (voice_pick, pair_room). Only for ring sounds: it
; costs ~30 cycles per sound. Called by voice_pick (pair_room = PAIR_ASK).
; seq_ptr, seq_i: the step being fired. X preserved. Out: A. clobbers Y
; -----------------------------------------------------------------------------
hits_after
        stx sound_now
        lda #0
        sta pair_room           ; (the count)
        ldy seq_i
_next   iny
        cpy #NUM_SOUNDS
        beq _done
        ldx fire_order,y
        lda mute_bit,x
        cpx #8
        bcs +
        and mute
        bne _next
        beq _cell
+       and mute+1
        bne _next
_cell   tya
        pha
        ldy sound_cell_ofs,x
        lda (seq_ptr),y
        and #CELL_LEVEL
        beq +
        inc pair_room
+       pla
        tay
        jmp _next
_done   ldx sound_now
        lda pair_room
        rts

; =============================================================================
; Live record
; =============================================================================

; -----------------------------------------------------------------------------
; rec_hit - a hit played live (note_on: MIDI or a note key; the grid's tap
; key): while recording and playing, write it into the pattern at the
; nearest step (rec_quantise) with the nearest level. The hit itself plays
; now (the caller), so if its step is still to fire in this pass, that one
; firing skips the sound (skip_now / skip_next): one sound per press.
; new_sound, new_vel: the hit (kept). clobbers A, X, Y
; -----------------------------------------------------------------------------
rec_hit
        lda rec_on
        beq _done
        lda seq_play
        beq _done

        ; the level: nearest of soft 55, normal 100, accent 127
        ldx #1
        lda new_vel
        cmp #REC_NORMAL_MIN
        bcc +
        inx
        cmp #REC_ACCENT_MIN
        bcc +
        inx
+       stx hit_level

        jsr rec_quantise
        bcs _next_step

        ; the current step: still to fire if play was just pressed (or MIDI
        ; start waits for its first clock), a swung step waits, or the
        ; step's hits haven't reached this sound yet
        jsr rec_write           ; A = pattern, X = step
        lda seq_start
        ora swing_wait
        ora clock_wait
        bne _skip_now
        lda seq_hits_on
        beq _done               ; fired already: it plays from the next pass
        ldx new_sound
        lda fire_pos,x
        cmp seq_i
        bcc _done               ; passed already
_skip_now
        ldx #skip_now
        jmp skip_set
_next_step
        jsr rec_write           ; the next step: it always fires
        ldx #skip_next
        jmp skip_set
_done   rts

; -----------------------------------------------------------------------------
; rec_quantise - the step a live hit belongs to: the nearest on the unswung
; grid (the step phase past half, or 3 of the step's 6 MIDI clocks: the
; next step; so is a step MIDI clock made due that seq_tick hasn't begun).
; Out: A = pattern, X = step; carry clear = the current step, set = the
; next one (after the pattern's end: step 0 of seq_next_pat's pattern).
; clobbers Y
; -----------------------------------------------------------------------------
rec_quantise
        lda params+P_CLOCK
        beq _internal
        lda clock_due           ; MIDI clock: a step due but not fired yet (its
        bne _next               ; clock came with this note): that one
        lda clock_count         ; half a step = 3 of its 6 clocks
        cmp #CLOCKS_PER_STEP/2
        bcs _next
        bcc _current            ; always
_internal
        lda seq_phase+1
        bmi _next               ; past half a step
_current
        lda seq_pat
        ldx seq_step
        clc
        rts
_next   lda seq_pat
        clc
        adc #>PATTERN_RAM
        sta rec_ptr+1
        lda #PAT_LENGTH
        sta rec_ptr
        ldx seq_step
        inx
        txa
        ldy #0
        cmp (rec_ptr),y
        bcs _wrap               ; the pattern ends here (">=" as seq_step_due)
        lda seq_pat
        sec
        rts
_wrap   jsr seq_next_pat        ; the pattern after this one
        ldx #0
        sec
        rts

; -----------------------------------------------------------------------------
; rec_write - set new_sound's cell in pattern A, step X to hit_level.
; clobbers A, Y
; -----------------------------------------------------------------------------
rec_write
        ; undo: the pattern saved once per pass (the first hit recorded in it)
        cmp rec_undo_pat
        bne +
        ldy seq_pass
        cpy rec_undo_pass
        beq _write
+       sta rec_undo_pat
        pha
        txa
        pha
        lda seq_pass
        sta rec_undo_pass
        lda rec_undo_pat
        jsr undo_save
        pla
        tax
        pla
_write  clc
        adc #>PATTERN_RAM
        sta rec_ptr+1
        ldy new_sound
        txa
        clc
        adc sound_cell_ofs,y
        sta rec_ptr
        ldy #0
        lda (rec_ptr),y
        and #~CELL_LEVEL
        ora hit_level
        sta (rec_ptr),y
        rts

; -----------------------------------------------------------------------------
; skip_set - set new_sound's bit in the skip mask at zero page X (skip_now
; or skip_next). clobbers A, Y
; -----------------------------------------------------------------------------
skip_set
        ldy new_sound
        lda mute_bit,y
        cpy #8
        bcc +
        inx                     ; sounds 8..: the high byte
+       ora 0,x
        sta 0,x
        rts

; -----------------------------------------------------------------------------
; skip_clear - no skips (play, stop). clobbers A
; -----------------------------------------------------------------------------
skip_clear
        lda #0
        sta skip_now
        sta skip_now+1
        sta skip_next
        sta skip_next+1
        rts

; bit of each sound in mute / mute+1
mute_bit        .byte 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16
        .cerror * - mute_bit != NUM_SOUNDS, "mute_bit: one per sound"
; offset of each sound's first cell in a pattern page
sound_cell_ofs  .for _s := 0, _s < NUM_SOUNDS, _s += 1
                .byte _s * SEQ_STEPS
                .endfor
