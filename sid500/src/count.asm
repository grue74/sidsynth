; count.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The count-in (docs/design.md section 5b, "The count-in as built"): C= R on
; the song screen while stopped (master) records from the song's start
; after the Count-in parameter's bars (0, 1 or 2) of clicks. Only the click
; plays meanwhile: the SID's always (even with the Metronome off: a count-in
; you can't hear is no use), and the MIDI note too if the Metronome has it;
; no Start or clock goes out until the song starts after it.
;
; - Away from the song's start the song is reset first (the transport's
;   STOP_RESET, a piece at a time: COUNT_RESET), then the count begins.
; - The take is begun at C= R (rec_start_now: its pattern, track, the
;   loop's place 0), before the count, so a note played on the downbeat
;   a little early isn't lost: until the song's first tick is due, a
;   message is stamped at pass 0 when it comes within COUNT_EARLY ticks
;   of it, and left out before that (rec_put_count, rec_now_count).
; - The count runs in the timer interrupt while stopped (count_idle, from
;   synth_timer's idle path: master timer A keeps ticking at the tempo):
;   a beat every count_len ticks from scene 1's signature (count_begin
;   finds them), the bar's first brighter; two ticks before the song's tick 0 it starts
;   the song as SPACE would (transport_go_start: MIDI start at the next
;   tick, tick 0 a tick after it), so tick 0 comes exactly a beat after
;   the last click.
; - C= R again or SPACE during the count ends it (nothing sent, the take
;   ended with nothing in it); once MIDI start has gone, SPACE stops as
;   ever. A Clock change to MIDI ends it too.
; - As slave there is no count-in (the master starts the song): C= R
;   stopped arms the take (count_arm, design 5e: REC shown, the take from
;   the master's first tick, messages before it left out; C= R or SPACE
;   disarms it).
;
; All of it after the tables (late_code), so nothing before them moves (the
; hot code's place, design 4b): the callers' jsr's point here instead
; (synth_timer's idle path, rx_message, synth_tick, rec_key_io, the song
; screen's SPACE and title, synth_init), the same number of bytes.

COUNT_NONE      = 0             ; count_state: no count-in
COUNT_RESET     = 1             ;   the song being reset to its start first (or the take
                                ;   being begun: the interrupt leaves it alone)
COUNT_TICKING   = 2             ;   counting (the interrupt's idle ticks)
COUNT_STARTED   = 3             ;   MIDI start asked: waiting for the song's first tick
COUNT_ARMED     = 4             ;   as slave: the take armed, waiting for the master's
                                ;   first tick (design 5e; count_arm)
COUNT_EARLY     = 6             ; a message within this many ticks before the song's tick 0
                                ; is stamped at pass 0 (Claude's default: half a 16th);
                                ; earlier ones are left out (thru still plays them)

; the count's variables: after the song screen's (main RAM at $C1ED, read by the
; interrupts whatever $01 is)
        .virtual song_vars_end
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
count_state     .byte ?         ; COUNT_*
        .send
count_left      .word ?         ; idle ticks until the song's tick 0 ($FFFF: not counting)
count_wait      .byte ?         ; ticks until the next count beat (1: the next tick)
count_beat_no   .byte ?         ;   that beat in its bar, 0 = the first
count_len       .byte ?         ; ticks a beat (48: a quarter, 24: an eighth)
count_beats     .byte ?         ; beats a bar
count_vars_end
        .endv
        .cerror count_vars_end > $c200, "the count-in's variables run past $C1FF"

        .section late_code

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; count_init - (synth_init, in rec_init's place) no count-in; then rec_init.
; clobbers A
; -----------------------------------------------------------------------------
count_init
        jsr scene_init          ; (stage E: scene.asm)
        lda #COUNT_NONE
        sta count_state
        jmp rec_init
        .send

; =============================================================================
; The interrupts' part
; =============================================================================

; -----------------------------------------------------------------------------
; count_idle - (synth_timer's idle path, in click_idle's place: stopped or
; held, interrupts on) click_idle (a click sounding released, its note's
; off sent); then the count-in's tick. COUNT_TICKING, stopped: a tick
; less to the song's tick 0;
; on a beat the click; two ticks before tick 0 the song started
; (transport_go_start: MIDI start at the next tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
count_idle
        jsr click_idle
        lda count_state
        cmp #COUNT_TICKING
        bne _rts
        lda play_state
        bne _rts                ; (held: count_poll's to look at)
        ; a tick less: two left, the song started
        lda count_left
        bne +
        dec count_left+1
+       dec count_left
        bne _beat
        lda count_left+1
        bne _beat
_rts    rts                     ; (never 0 here: started at 2)
_beat   lda count_left+1
        bne +
        lda count_left
        cmp #2
        bne +
        jsr transport_go_start  ; MIDI start at the next tick, tick 0 a tick after it
        lda #COUNT_STARTED
        sta count_state
        rts
+       dec count_wait
        bne _rts
        lda count_len           ; a beat: the next one a beat on
        sta count_wait
        ; the click as click_beat makes it, the SID's always; the song's
        ; own count put back after it (at the song's start, as click_phase
        ; finds it: its first beat at the next tick due)
        lda params+P_METRONOME
        pha
        ora #CLICK_SID
        sta params+P_METRONOME
        lda count_beat_no
        sta click_beat_no
        ldx count_left          ; (tests: LOG_CLICK_AT = 0 - this, the song tick's low byte)
.if TEST_LOG
        php                     ; (tests: click_beat logs to log A, which the receive
        sei                     ; interrupt writes too: one writer at a time)
.endif
        jsr click_beat
.if TEST_LOG
        plp
.endif
        pla
        sta params+P_METRONOME
        lda #1
        sta click_wait
        lda #0
        sta click_beat_no
        ldy count_beat_no       ; the next beat
        iny
        cpy count_beats
        bcc +
        ldy #0
+       sty count_beat_no
        lda click_midi          ; the note on (Metronome MIDI or SID+MIDI): now
        bpl _rts
        jmp click_midi_send

; -----------------------------------------------------------------------------
; rec_put_count - (rx_message, a take on: in rec_put's place) the message
; stamped (rec_put), but during a count-in before the song's first tick
; only within COUNT_EARLY ticks of it (count_left; stamped at pass 0 by
; rec_now_count); earlier ones left out. (Armed as slave: locate.asm
; rec_put_armed first.)
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rec_put_count
        lda take_cut            ; a launch cut the take (scene.asm): from its pass on,
        beq +                   ; not the take's
        jsr rec_now_count
        cmp take_cut_at
        tya
        sbc take_cut_at+1
        bcs _out
+       lda count_state
        beq _put
        lda play_tick
        ora play_tick+1
        bne _put                ; (the song's ticks due: as ever)
        lda count_left+1
        bne _out
        lda count_left
        cmp #COUNT_EARLY+1
        bcs _out
_put    jmp rec_put
_out    rts

; -----------------------------------------------------------------------------
; rec_now_count - (rec_put, rec_now_out: in rec_now's place) rec_now; but
; during a count-in before the song's first tick is due, pass 0 (A, Y).
; clobbers X
; -----------------------------------------------------------------------------
rec_now_count
        lda count_state
        beq _now
        lda play_tick
        ora play_tick+1
        bne _now
        tay
        rts
_now    jmp rec_now

; count_poll - (synth_tick, in rec_poll's place) the count-in's turn
; (count_poll_io, under I/O), then the take's (rec_poll) unless the count
; goes on: rec_poll_io would end a take while the song isn't playing.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
count_poll
        jsr scene_poll          ; (stage E: the song, MIDI launches; scene.asm)
.if TEST_REC_STOP
        jsr rec_stop_test       ; (tests: SPACE at a play tick, the take ending with it)
.endif
.if !TEST_COUNT
        lda count_state         ; (none: no switching, as rec_poll)
        beq _take
.endif
        lda #RAM_ALL
        sta $01
        jsr count_poll_io
        lda #RAM_IO
        sta $01
        bcs _take
        rts
_take   jmp rec_poll

.if TEST_REC_STOP
; rec_stop_test - (tests, count_poll: $01 = RAM_IO) once, from play tick
; TEST_REC_STOP on while playing: the song stopped as SPACE does
; (transport_stop), so the take ends with it (rec_poll_io).
; clobbers A, X, Y
rec_stop_test
        lda rec_test_stop
        bne _rts
        lda play_state
        cmp #PLAY_RUNNING
        bne _rts
        lda play_tick
        cmp #<TEST_REC_STOP
        lda play_tick+1
        sbc #>TEST_REC_STOP
        bcc _rts
        inc rec_test_stop
        jmp transport_stop
_rts    rts
.endif

; -----------------------------------------------------------------------------
; count_key - (the song screen's SPACE, in synth_param_key's place; A = its
; key code) during a count-in before MIDI start has gone: ends it
; (count_key_io); else the transport's SPACE.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
count_key
        ldx count_state
        beq _space
        ldx #RAM_ALL
        stx $01
        jsr count_key_io        ; (carry set: MIDI start sent, a stop as ever)
        ldx #RAM_IO
        stx $01
        bcs _space
        rts
_space  ldx shift_held          ; SHIFT+SPACE with Song on: from scene 1 (design 5c)
        beq +
        ldx want_press
        beq +
        ldx song_on
        beq +
        ldx #0
        stx start_scene
        cpx play_scene
        beq +
        stx pos_zero            ; (another scene's start: reset first)
+       jmp synth_param_key

; -----------------------------------------------------------------------------
; count_state_check - (the song screen, in song_state_check's place) during
; a count-in while not yet playing the title shows REC at once; else as
; song_state_check.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
count_state_check
        jsr clock_check         ; (the time display: clock.asm)
        jsr scene_shown_check   ; (stage E: what scene.asm's marks show)
        lda count_state
        beq +
        lda play_state
        beq _rec                ; (PLAY_STOPPED)
        cmp #PLAY_HELD
        beq _rec
+       jmp song_state_check
_rec    lda #2                  ; (REC)
        .cerror PLAY_STOPPED != 0, "count_state_check: PLAY_STOPPED is 0"
        jmp song_state_set

; =============================================================================
; The main loop's part under I/O (run with $01 = RAM_ALL: from rec_key_io
; and count_poll)
; =============================================================================

; -----------------------------------------------------------------------------
; rec_start_any - (rec_key_io, $01 = RAM_ALL: C= R with no take on) playing:
; a take at once (rec_start). Stopped as slave: armed (count_arm). Stopped,
; master, no count-in under way: the
; count-in, at the song's start (count_begin), or the song reset to it
; first (STOP_RESET, held: count_poll begins it after). During that reset,
; C= R ends it (the song stays stopped).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
        .send
        .section late_code
        .send
        .section io_data        ; (under I/O: run with $01 = RAM_ALL)

rec_start_any
        lda count_state
        beq +
        cmp #COUNT_RESET
        bne _rts
        lda #COUNT_NONE         ; (C= R again while resetting: no count-in)
        sta count_state
        rts
+       lda play_state
        cmp #PLAY_RUNNING
        bne +
        jmp rec_start
+       cmp #PLAY_STOPPED
        bne _rts                ; (held: a stop or start under way)
        lda params+P_CLOCK
        beq +
        jmp count_arm           ; (slave: the master starts the song; armed)
+       lda pos_zero
        bne count_begin
        lda #COUNT_RESET        ; away from the song's start: reset first
        sta count_state
        lda #STOP_RESET
        sta stop_phase
        lda #PLAY_HELD
        sta play_state
_rts    rts

; -----------------------------------------------------------------------------
; count_begin - ($01 = RAM_ALL; stopped at the song's start, master) the
; take begun (rec_start_now: the loop's place 0, stamps left out until the
; count is near its end); then the count-in (the beat and bar from scene
; 1's signature, the ticks to tick 0; COUNT_TICKING: the timer
; interrupt's from its next idle tick), or with Count-in Off the song started at once. Nothing if
; the take can't begin (an edit waiting, the list of replaced chains full).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
count_begin
        jsr hi3_in              ; (disk.asm: the note map free; the code at HI3_CODE back)
        lda #$ff                ; (no stamps until the count is near its end)
        sta count_left
        sta count_left+1
        lda #COUNT_RESET        ; (the interrupt leaves it alone meanwhile)
        sta count_state
        jsr rec_start_now
        lda rec_state
        cmp #REC_ON
        beq +
        lda #COUNT_NONE         ; (not begun)
        sta count_state
        clc
        rts
+       lda params+P_COUNT_IN
        beq _now
        ; the beat and the bar from the starting scene's signature
        ldx play_scene
        jsr sig_beats           ; (scene.asm: A beats, X a beat's ticks)
        sta count_beats
        stx count_len
        ; the idle ticks to the song's tick 0: the bars, and one (the first
        ; beat at the next tick)
        ldx #1
        stx count_left
        stx count_wait
        dex
        stx count_left+1
        stx count_beat_no
        ldx params+P_COUNT_IN
-       ldy count_beats
-       clc
        lda count_left
        adc count_len
        sta count_left
        bcc +
        inc count_left+1
+       dey
        bne -
        dex
        bne --
        lda #COUNT_TICKING      ; (last: the interrupt counts from now)
        sta count_state
        clc                     ; (count_poll_io's: no take's turn yet)
        rts
_now    lda #0                  ; Count-in Off: started at once, near from now
        sta count_left
        sta count_left+1
        lda #COUNT_STARTED
        sta count_state
        jsr transport_go_start
        clc
        rts

; -----------------------------------------------------------------------------
; count_poll_io - (count_poll, $01 = RAM_ALL) the count-in's turn; carry
; set: the take's turn too (rec_poll).
; - COUNT_RESET: once the song is stopped at its start, the count begun;
;   the reset left another way (a start meanwhile), no count-in.
; - Counting: the song's first tick due: the count-in done, the take's as
;   ever. MIDI start sent and tick 0 not yet due: waiting (a C= R then ends
;   the take at pass 0). Else C= R (REC_STOPPING), a Clock change to MIDI,
;   the song started or held by something else, or stopped after the count
;   started it: the count-in ended (a start not yet sent undone: the song
;   stays at its start), then rec_poll ends the take (nothing in it).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
count_poll_io
.if TEST_COUNT
        jsr count_test          ; (tests: C= R as the song screen would)
.endif
        lda count_state
        bne +
        sec                     ; (no count-in: the take's)
        rts
+       cmp #COUNT_ARMED
        bcc +
        jmp count_armed         ; (armed as slave: main RAM)
+       cmp #COUNT_RESET
        bne _counting
        lda play_state
        cmp #PLAY_HELD
        beq _rts                ; (resetting)
        cmp #PLAY_STOPPED
        bne _none
        lda pos_zero
        beq _none
        jmp count_begin         ; at the song's start: the count (carry clear)
_none   lda #COUNT_NONE
        sta count_state
_rts    clc
        rts
_counting
        lda play_tick
        ora play_tick+1
        beq +
        lda #COUNT_NONE         ; the song's first tick due: the take's as ever
        sta count_state
        sec
        rts
+       lda play_state
        cmp #PLAY_RUNNING
        beq _rts                ; (MIDI start sent: tick 0 is a tick away)
        ldx params+P_CLOCK
        bne _end                ; (now slave)
        ldx rec_state
        cpx #REC_STOPPING
        beq _end                ; (C= R again)
        ldx count_state
        cpx #COUNT_STARTED
        beq _started
        cmp #PLAY_STOPPED
        beq _rts                ; (counting)
        bne _end                ; (started or held by something else)
_started
        cmp #PLAY_STARTING
        beq _rts
        ; the count-in ended: a start not yet sent undone, the take ended
_end    php
        sei
        lda play_state
        cmp #PLAY_STARTING
        bne +
        lda #PLAY_STOPPED       ; (MIDI start not sent: the song still at its start)
        sta play_state
        lda #1
        sta pos_zero
+       lda #COUNT_NONE
        sta count_state
        plp
        sec                     ; (rec_poll: not playing, the take ends)
        rts


; count_key_io - (count_key: SPACE during a count-in) MIDI start sent:
; carry set (the transport's SPACE: a stop). Else, pressed: the count-in
; ended (as C= R: count_poll), the song stays stopped; while resetting, no
; count-in after it. A kept (the key code); clobbers X
count_key_io
        ldx play_state
        cpx #PLAY_RUNNING
        beq _rts                ; (carry set)
        ldx want_press
        beq _done               ; (its release)
        ldx count_state
        cpx #COUNT_RESET
        bne +
        ldx #COUNT_NONE         ; (resetting: no count-in after it)
        stx count_state
        clc
        rts
+       ldx rec_state
        cpx #REC_ON
        bne _done
        ldx #REC_STOPPING       ; (count_poll ends the count, rec_poll the take)
        stx rec_state
_done   clc
_rts    rts

        .send
.if TEST_COUNT
        .section late_code      ; (tests: in main RAM, run with $01 = RAM_ALL; under
                                ; I/O there is no room in the test builds)
; -----------------------------------------------------------------------------
; count_test - (tests, count_poll_io) once, at the first look: C= R on the song
; screen while stopped, on track TEST_COUNT (TEST_COUNT_RESET: the song taken
; as away from its start, so it is reset first); then with TEST_COUNT_CANCEL
; C= R again once the count has fewer than that many ticks left.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
count_test
        lda rec_test_done
        bne _cancel
        inc rec_test_done
        lda #TEST_COUNT-1
        sta song_cursor
.if TEST_COUNT_RESET
        lda #0
        sta pos_zero
.endif
        jmp rec_start_any
_cancel
.if TEST_COUNT_CANCEL
        cmp #1
        bne _rts
        lda count_state
        cmp #COUNT_TICKING
        bne _rts
        lda count_left+1
        bne _rts
        lda count_left
        cmp #TEST_COUNT_CANCEL
        bcs _rts
        inc rec_test_done
        lda #REC_STOPPING       ; (as C= R)
        sta rec_state
.endif
_rts    rts
        .send
.endif
