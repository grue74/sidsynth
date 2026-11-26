; transport.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Start, stop and continue (docs/design.md section 4; the user,
; 2026-11-20). As master, from the keys: SPACE stops if playing, else
; continues from where it stopped (song position, then MIDI continue; at
; the song's start, MIDI start); SHIFT+SPACE plays from the start. As
; slave, from MIDI in (slave.asm synth_rt_irq): the receive interrupt
; only changes play_state and asks; the main loop does the rest here
; (transport_poll), the player held meanwhile.
;
; A stop ends what sounds with exact note offs: a note off for each note
; that has gone out and not ended, nothing else (stop_ends_notes). Then
; the song moves on to the next 16th (MIDI's song position counts 16ths:
; continue resumes there, skipping what lies between; stop_locate), with
; nothing sounding, its first ticks rendered again, so continue is
; immediate.

KEY_SPACE       = 60            ; SPACE's key code (column 7, row 4)
STOP_NONE       = 0             ; stop_phase: the pieces of a stop, in order
STOP_OFFS       = 1             ;   a note off for each note sounding (stop_offs_part)
STOP_FORWARD    = 2             ;   rendered on to the 16th, silently (stop_forward_part)
STOP_CLEAR      = 3             ;   the wheel cleared, a page a call (stop_clear_part)
STOP_FIRST      = 4             ;   the lead rendered again (stop_first_part)
STOP_POSITION   = 5             ;   master: the song position sent (stop_position_part)
STOP_DRAIN      = 6             ;   before a continue: the ring sent out (stop_drain_part)
STOP_DONE       = 7
STOP_RESET      = 8             ; (a start away from the song's start: player_reset first)
REQ_START       = 1             ; transport_req: SHIFT+SPACE (from the start)
REQ_CONTINUE    = 2             ;   SPACE (continue)
CONT_NONE       = 0             ; stop_continuing: no continue under way
CONT_SENDING    = 1             ;   its song position, then the ring drained (stop_run)
CONT_READY      = 2             ;   both done: MIDI continue may go
SEEN_ON         = $80           ; stop_walk_stage's marks in NOTE_ENTRY (entries are 0-127,
SEEN_OFF        = $81           ;   NO_ENTRY $FF): a note's first event unsent was its on, off

        .section zp
pos_zero        .byte ?         ; nonzero: the song is ready at its start (tick 0)
walk_ptr        .word ?         ; a row of NOTE_ENTRY
        .send

; the main loop's own, in the RAM the core leaves to the synth ($C140-$C1FF;
; the zero page is full)
        .virtual $c150
stop_point      .word ?         ; the tick a stop came at: the ticks sent (one partly too)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
locate_tick     .word ?         ; the tick the song is ready at after a stop (a 16th's)
        .send
locate_16th     .word ?         ;   and its 16th's number (the song position)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
div_lo          .byte ?         ; div12's number
        .send
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
div_hi          .byte ?
        .send
walk_status     .byte ?         ; stop_walk_stage: the message's status
walk_need       .byte ?         ;   its data bytes, 1 or 2
walk_got        .byte ?         ;   the data bytes so far
walk_data       .fill 2         ;   and them
walk_channel    .byte ?         ; stop_offs_part: the row's first channel
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
stop_phase      .byte ?         ; STOP_*: the stop's (or continue's) next piece, 0 = none
        .send
stop_off_y      .byte ?         ; stop_offs_part: where in its page of NOTE_ENTRY
stop_page       .byte ?         ; stop_clear_part: the next page of the wheel to clear
stop_unlimited  .byte ?         ; nonzero: the pieces run to the end (player_restart)
stop_then       .byte ?         ; after the lead is rendered: STOP_POSITION or STOP_DONE
stop_continuing .byte ?         ; CONT_*: a continue's song position, then the ring drained
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
transport_req   .byte ?         ; master: REQ_* asked while held (a key during a stop)
        .send
transport_vars_end
        .endv
        .cerror transport_vars_end > $c200, "the transport's variables run past $C1FF"

; -----------------------------------------------------------------------------
; transport_init - from synth_init: no stop, start or continue under way
; (the RAM is junk at power-on).
; clobbers A
; -----------------------------------------------------------------------------
transport_init
        lda #STOP_NONE
        sta stop_phase
        lda #0
        sta stop_unlimited
        sta stop_continuing     ; (CONT_NONE)
        sta transport_req
        rts

; =============================================================================
; The keys (master)
; =============================================================================

; -----------------------------------------------------------------------------
; synth_param_key - core hook (PARAM_SYNTH_KEYS): a key on the parameter
; screen, before the core. A = key code, want_press (1 = pressed). SPACE:
; as master SHIFT+SPACE plays from the start, SPACE stops if playing and
; else continues; as slave nothing (its master starts and stops it).
; While a stop (or a start, a continue) is being done, what is pressed
; is done after it (transport_req). Carry set = used.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_param_key
        cmp #KEY_SPACE
        bne _not
        lda want_press
        beq _used               ; (its release)
        lda params+P_CLOCK
        bne _used               ; slave
        lda shift_held
        bne _from_start
        lda play_state
        cmp #PLAY_STOPPED
        beq _continue
        cmp #PLAY_HELD
        beq _ask_continue
        jsr transport_stop
        sec
        rts
_continue
        jsr transport_continue
        sec
        rts
_ask_continue
        lda #REQ_CONTINUE
        sta transport_req
        sec
        rts
_from_start
        lda play_state
        cmp #PLAY_STOPPED
        beq +
        jsr transport_stop      ; (playing: stopped first; the start after it)
        lda #REQ_START
        sta transport_req
        sec
        rts
+       jsr transport_start
_used   sec
        rts
_not    clc
        rts

; -----------------------------------------------------------------------------
; transport_start - (master, main loop) stopped: play from the song's
; start. At it: the next tick sends MIDI start, the first clock and tick 0
; come a tick after it. Else the song reset first, a piece at a time
; (held: transport_poll), then started.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
transport_start
        lda play_state
        bne _done               ; (playing or held)
        lda pos_zero
        bne transport_go_start
        lda #REQ_START          ; away from it: reset first
        sta transport_req
        lda #STOP_RESET
        sta stop_phase
        lda #PLAY_HELD
        sta play_state
_done   rts

; transport_go_start - (at the song's start) MIDI start at the next tick.
; clobbers A
transport_go_start
        jsr hi3_in              ; (disk.asm: the code at HI3_CODE back, the note map free)
        lda #MIDI_START
        sta start_byte
        lda #0
        sta pos_zero
        sta transport_req
        lda #PLAY_STARTING
        sta play_state
        rts

; -----------------------------------------------------------------------------
; transport_continue - (master, main loop) stopped: play on from where it
; stopped (the 16th stop_locate readied). The song position goes first,
; and out on the wire before MIDI continue, which the next tick sends
; (through the urgent queue, which would jump ahead of it): both a piece
; at a time (held: transport_poll). At the song's start: MIDI start.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
transport_continue
        lda play_state
        bne _done               ; (playing or held)
        lda pos_zero
        bne transport_go_start
        lda #REQ_CONTINUE
        sta transport_req
        lda #CONT_SENDING
        sta stop_continuing
        lda #STOP_POSITION
        sta stop_phase
        lda #PLAY_HELD
        sta play_state
_done   rts

; transport_go_continue - (transport_poll) the song position out: MIDI
; continue at the next tick. clobbers A
transport_go_continue
        jsr hi3_in              ; (disk.asm)
        lda #MIDI_CONTINUE
        sta start_byte
        lda #CONT_NONE
        sta stop_continuing
        lda #0
        sta pos_zero
        sta transport_req
        lda #PLAY_STARTING
        sta play_state
        rts

; -----------------------------------------------------------------------------
; transport_stop - (master, main loop) playing: MIDI stop at once (the
; urgent queue), the player held; the rest a piece at a time
; (transport_poll: what sounds ends, the song moves to the next 16th, its
; song position goes out), so the keys and the screen go on meanwhile.
; Starting (MIDI start or continue not sent yet): just stopped.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
transport_stop
        sei
        lda play_state
        cmp #PLAY_STARTING
        bne +
        lda #PLAY_STOPPED       ; nothing sent yet
        sta play_state
        cli
        rts
+       cmp #PLAY_RUNNING
        beq +
        cli                     ; (stopped or held already)
        rts
+       lda #PLAY_HELD          ; no tick from here on
        sta play_state
        lda #MIDI_STOP          ; (the timer's interrupt writes the urgent queue too:
        jsr midi_send_urgent    ; not meanwhile, interrupts off)
        cli
        jmp stop_begin

; =============================================================================
; The pieces, in the main loop
; =============================================================================

; -----------------------------------------------------------------------------
; transport_poll - (synth_tick, every 250 Hz tick) the player held: the
; stop's (or start's, continue's) pieces while this tick has time
; (stop_run); a slave's stop asked by synth_rt_irq begun. Then, all done:
; what was asked meanwhile. A slave: a start asked resets the song first
; (player_prepare_quick), then plays, the clocks counted meanwhile at
; once (a kick); else stopped. synth_rt_irq may come in between anywhere
; (an NMI on some interfaces): it only asks while held, so what it asked
; is looked at again after the player is let go. A master: a start or a
; continue asked meanwhile, else stopped.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
transport_poll
        lda play_state
        cmp #PLAY_HELD
        beq _again
        rts
_again  jsr hi3_in              ; (disk.asm: before a reset, a locate or a start)
        lda stop_phase
        bne _run
        lda slave_stop_req      ; (a slave's stop asked: begun)
        beq _ready
        lda #0
        sta slave_stop_req
        jsr stop_begin
_run    jsr stop_run
        bcs _ready
        rts                     ; (more at the next tick)
_ready  lda params+P_CLOCK
        bne _slave
        ; master: what was asked, else stopped
        lda transport_req
        beq _stopped
        cmp #REQ_START
        beq _start
        lda pos_zero            ; continue: at the song's start, a start
        bne _go_start
        lda stop_continuing     ; its song position out and the ring drained: go
        cmp #CONT_READY
        beq _go_continue
        lda #CONT_SENDING       ; (asked during a stop: the song position again,
        sta stop_continuing     ; then the ring drained)
        lda #STOP_POSITION
        sta stop_phase
        jmp _again
_start  lda pos_zero
        bne _go_start
        lda #STOP_RESET
        sta stop_phase
        jmp _again
_go_start
        jmp transport_go_start
_go_continue
        jmp transport_go_continue
_stopped
        lda #PLAY_STOPPED
        sta play_state
        rts
        ; slave
_slave  lda slave_req
        cmp #MIDI_START
        bne +
        lda pos_zero
        bne +
        jsr player_prepare_quick ; start asked: from the song's start
        ; let go: what was asked plays, else stopped
+       sei
        lda slave_req
        beq _stop
        cmp #MIDI_START
        bne _go
        lda pos_zero
        bne _go
        cli                     ; (start asked just now: to the start first)
        jmp _again
_go     lda #0
        sta slave_req
        sta pos_zero
        lda #PLAY_STARTING
        sta play_state
        lda slave_clocks        ; clocks came meanwhile: they play at once
        cmp slave_done
        beq +
        jsr slave_kick
+       cli
        rts
_stop   lda #PLAY_STOPPED
        sta play_state
        lda slave_req           ; (asked between the two: once more)
        beq +
        lda #PLAY_HELD
        sta play_state
        cli
        jmp _again
+       cli
        rts

; -----------------------------------------------------------------------------
; stop_time - may a piece go on? Carry set: yes (stop_unlimited, or no 250
; Hz tick waiting and SLICE_SPARE_HI of this one's time left, as
; render_slice). clobbers A
; -----------------------------------------------------------------------------
stop_time
        lda stop_unlimited
        bne _yes
        lda tick_count
        cmp tick_done
        bne _no                 ; the next tick first
        lda CIA1_TB_HI
        cmp #SLICE_SPARE_HI     ; (carry set: time left)
        rts
_yes    sec
        rts
_no     clc
        rts

; -----------------------------------------------------------------------------
; stop_run - the pieces in turn while there is time: each part returns
; carry set when its piece is done (the next one follows), clear when
; out of time (here again at the next tick). Carry set: all done
; (stop_phase STOP_NONE).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_run
        lda stop_phase
        cmp #STOP_OFFS
        bne +
        jsr stop_offs_part
        bcc _later
        jsr stop_locate         ; (decides: STOP_FORWARD or STOP_CLEAR)
        jmp stop_run
+       cmp #STOP_FORWARD
        bne +
        jsr stop_forward_part
        bcc _later
        lda #STOP_CLEAR
        sta stop_phase
        lda #0
        sta stop_page
        jmp stop_run
+       cmp #STOP_CLEAR
        bne +
        jsr stop_clear_part
        bcc _later
        jsr stop_there          ; (STOP_FIRST)
        jmp stop_run
+       cmp #STOP_RESET
        bne +
        jsr stop_reset
        jmp stop_run
+       cmp #STOP_FIRST
        bne +
        jsr stop_first_part
        bcc _later
        lda stop_then
        sta stop_phase
        jmp stop_run
+       cmp #STOP_POSITION
        bne +
        jsr stop_position_part
        bcc _later
        lda #STOP_DONE
        ldx stop_continuing     ; (a continue's: the ring drained next)
        cpx #CONT_SENDING
        bne _next_phase
        lda #STOP_DRAIN
_next_phase
        sta stop_phase
        jmp stop_run
+       cmp #STOP_DRAIN
        bne +
        lda tx_tail             ; out on the wire (the last byte in the ACIA at most)
        cmp tx_head
        bne _later
        lda #CONT_READY
        sta stop_continuing
        lda #STOP_DONE
        sta stop_phase
        jmp stop_run
+       lda #STOP_NONE          ; (STOP_DONE)
        sta stop_phase
        sec
        rts
_later  clc
        rts

; stop_reset - (STOP_RESET: a start away from the song's start) the song
; reset (player_reset, the tempo, the lead), then its first ticks a piece
; at a time (STOP_FIRST), then done. clobbers A, X, Y
stop_reset
        jsr player_reset
        jsr player_set_swing
        jsr player_set_tempo
        jsr slave_first_lead
        lda #1
        sta pos_zero
        lda #STOP_DONE
        sta stop_then
        jmp stop_first_begin

; =============================================================================
; A stop: the notes ended, the song moved on to the next 16th
; =============================================================================

; -----------------------------------------------------------------------------
; stop_ends_notes - (player_restart: the Clock changed) a stop's notes
; ended, at once (stop_begin, then stop_offs_part to its end).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_ends_notes
        lda #1
        sta stop_unlimited
        jsr stop_begin
        jsr stop_offs_part
        lda #0
        sta stop_unlimited
        sta stop_phase
        rts

; -----------------------------------------------------------------------------
; stop_begin - (the player held) a note off for each note that has gone
; out and not ended, nothing else (the user, 2026-11-20), begun: the stop
; point: the ticks released (rel_tick; a tick partly sent counts as sent).
; Nothing more is due (play_tick = rel_tick): the staged ticks stay
; unsent, and what sounds is NOTE_ENTRY's notes (the wheel's, as rendered)
; with the unsent bytes undone (stop_walk_stage: at most a page, done at
; once); then the offs a piece at a time (STOP_OFFS). A master's song
; position after the lead (stop_then).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_begin
        clc
        lda rel_tick
        adc rel_partial
        sta stop_point
        lda rel_tick+1
        adc #0
        sta stop_point+1
        lda rel_tick
        sta play_tick
        lda rel_tick+1
        sta play_tick+1
        jsr stop_walk_stage
        lda #<NOTE_ENTRY        ; the offs from the map's start
        sta walk_ptr
        lda #>NOTE_ENTRY
        sta walk_ptr+1
        lda #0
        sta walk_channel
        sta stop_off_y
        sta stop_continuing     ; (CONT_NONE)
        lda #STOP_POSITION      ; master: the song position after the lead
        ldx params+P_CLOCK
        beq +
        lda #STOP_DONE          ; (a slave's master sends it)
+       sta stop_then
        lda #STOP_OFFS
        sta stop_phase
        rts

; -----------------------------------------------------------------------------
; stop_walk_stage - the stage's unsent bytes (stage_tail to stage_head)
; read as messages; each note's first event there marks its NOTE_ENTRY:
; an off first (SEEN_OFF) = it was sounding at the stop point (the off
; unsent), an on first (SEEN_ON) = it wasn't (a note sounding is always
; ended before it starts again). Notes with no event there keep their
; entry: sounding if they have one. A tick partly sent goes on with its
; running status: then the status is the last one before stage_tail.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_walk_stage
        lda #0
        sta walk_got
        ldx stage_tail
        cpx stage_head
        beq _done               ; nothing unsent
        lda STAGE,x
        bmi _walk               ; (a status first)
        txa                     ; running status: the last status before it
        tay
-       dey
        lda STAGE,y
        bpl -
        jsr _status
_walk   lda STAGE,x
        bpl _data
        jsr _status
        jmp _next
_data   ldy walk_got
        sta walk_data,y
        iny
        sty walk_got
        cpy walk_need
        bne _next
        lda #0                  ; a whole message: a note's?
        sta walk_got
        lda walk_status
        and #$f0
        cmp #MSG_NOTE_ON
        bne _next
        jsr _mark
_next   inx
        cpx stage_head
        bne _walk
_done   rts

        ; _status - A = a status byte: its data bytes (program change and
        ; channel pressure one, the others two). keeps X
_status sta walk_status
        lda #0
        sta walk_got
        lda walk_status
        and #$e0
        cmp #$c0
        bne +
        lda #1                  ; ($C0, $D0: one)
        bne _need
+       lda #2
_need   sta walk_need
        rts

        ; _mark - the note message walk_status, walk_data: its NOTE_ENTRY
        ; marked, unless it was already (an earlier event). keeps X
_mark   lda walk_status         ; the channel's row: channel * 128
        and #$0f
        lsr
        ora #>NOTE_ENTRY
        sta walk_ptr+1
        lda #0
        ror
        sta walk_ptr
        ldy walk_data
        lda (walk_ptr),y
        and #$fe
        cmp #SEEN_ON
        beq +                   ; marked already
        lda #SEEN_ON
        ldy walk_data+1
        bne _set                ; velocity: an on
        lda #SEEN_OFF
_set    ldy walk_data
        sta (walk_ptr),y
+       rts

; -----------------------------------------------------------------------------
; stop_offs_part - (STOP_OFFS) for each note sounding at the stop point
; (stop_walk_stage left: an entry, 0-127, or SEEN_OFF) a note off (note on,
; velocity 0), channel 1 first, each channel's notes upwards, each with
; its status; from where it left off (walk_ptr, stop_off_y), while there
; is time and the ring has room for an off (it is never waited for, but
; with stop_unlimited). Carry set: all sent. NOTE_ENTRY is left marked
; (stop_clear_part clears it).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_offs_part
        ldy stop_off_y
_scan   lda (walk_ptr),y
        bpl _off                ; an entry: sounding, its off not sent
        cmp #SEEN_OFF
        bne _next
_off    sty stop_off_y          ; (here again if not now)
        jsr stop_time
        bcc _later
-       lda tx_tail             ; room for an off (3 bytes)? tail - next - 1
        clc
        sbc out_next
        cmp #3
        bcs +
        lda stop_unlimited
        beq _later              ; not now
        jsr out_go              ; (at once: what is queued goes, room comes)
        jmp -
+       ldy stop_off_y
        tya                     ; the channel: the row's first, +1 in its second half
        asl                     ; (bit 7 into carry)
        lda walk_channel
        adc #0
        ora #MSG_NOTE_ON
        sta out_msg
        tya
        and #$7f
        sta out_msg+1
        lda #0
        sta out_msg+2
        lda #3
        sta out_msg_len
        tya
        pha
        jsr out_message_main
        pla
        tay
_next   iny
        bne _scan
        inc walk_channel        ; the next page: two channels on
        inc walk_channel
        inc walk_ptr+1
        lda walk_ptr+1
        cmp #>(NOTE_ENTRY + 16 * 128)
        bne _scan
        sec                     ; all sent
        rts
_later  clc
        rts

; -----------------------------------------------------------------------------
; stop_locate - (stop_run, the offs sent) the song moves on to the 16th at
; or after the stop point (locate_tick, its number locate_16th), with
; nothing sounding and its first ticks rendered again: the staged bytes
; dropped; the renderer gone past that 16th's start: back with its
; snapshot (player.asm), then STOP_CLEAR; else rendered on to it, its
; bytes dropped (STOP_FORWARD, a piece at a time), then STOP_CLEAR.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_locate
        ; the 16th: stop point / 12, up if a remainder
        lda stop_point
        sta div_lo
        lda stop_point+1
        sta div_hi
        jsr div12
        beq +
        inc div_lo
        bne +
        inc div_hi
+       lda div_lo
        sta locate_16th
        lda div_hi
        sta locate_16th+1
        jsr times12             ; its tick
        ; the unsent bytes dropped
        lda stage_head
        sta stage_tail
        ; a step abandoned (render_abort): the tracks' state can't be
        ; rendered on from; back to a snapshot
        lda render_broken
        bne _broken
        ; the renderer past the 16th's start (ren_tick > it, or = it in
        ; the middle of that tick): its snapshot
        lda ren_tick+1
        cmp locate_tick+1
        bne +
        lda ren_tick
        cmp locate_tick
+       bcs +
        jmp _forward            ; before it
+
        bne _back               ; past it
        lda render_phase
        bne _back
        #log_at LOCATE_THERE       ; (at its start: there)
        jmp _clear
_back   #log_at LOCATE_BACK
_snapshot_b
        lda locate_tick
        sta pl_time
        lda locate_tick+1
        sta pl_time+1
        jsr snapshot_restore
        bcc _clear
+       #log_at LOCATE_NONE        ; (no snapshot: can't be; from the start then)
        jsr player_reset
        jmp _forward
        ; after an abandoned step: back with the 16th's snapshot if the
        ; renderer is past its start, else with the snapshot of the 16th
        ; it is in, then rendered on
_broken lda #0
        sta render_broken
        #log_at LOCATE_BROKEN
        lda ren_tick+1          ; ren_tick > the 16th: its own snapshot
        cmp locate_tick+1
        bne +
        lda ren_tick
        cmp locate_tick
+       bcs _snapshot_b
        lda ren_tick            ; else the 16th ren_tick is in: ren_tick / 12 * 12
        sta div_lo
        lda ren_tick+1
        sta div_hi
        jsr div12
        lda locate_tick         ; (times12 writes locate_tick: kept meanwhile)
        pha
        lda locate_tick+1
        pha
        jsr times12
        lda locate_tick
        sta pl_time
        sta ren_tick
        lda locate_tick+1
        sta pl_time+1
        sta ren_tick+1
        pla
        sta locate_tick+1
        pla
        sta locate_tick
        jsr snapshot_restore
        bcc +
        #log_at LOCATE_NONE        ; (no snapshot: can't be; from the start then)
        jsr player_reset
+       lda #0
        sta render_phase
        jsr wheel_clear         ; (from an empty wheel: entries an abandoned step left
        jmp _forward_on         ; out of it mustn't be met by a note started again)
        ; before it: rendered on to it (STOP_FORWARD)
_forward
        #log_at LOCATE_FORWARD
_forward_on
        lda #STOP_FORWARD
        sta stop_phase
        rts
_clear  lda #STOP_CLEAR
        sta stop_phase
        lda #0
        sta stop_page
        rts

; -----------------------------------------------------------------------------
; stop_forward_part - (STOP_FORWARD) rendered on to the 16th, silently, a
; step at a time while there is time (the stage emptied after each step, so
; it never fills; nothing is due, nothing released; the map's marks are
; met by a note started again as no entry: harmless). Carry set: there.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_forward_part
-       lda ren_tick
        cmp locate_tick
        bne _step
        lda ren_tick+1
        cmp locate_tick+1
        bne _step
        lda render_phase
        bne _step
        sec                     ; there
        rts
_step   jsr stop_time
        bcc _later
        jsr render_step
        lda stage_head
        sta stage_tail
        jmp -
_later  clc
        rts

; -----------------------------------------------------------------------------
; stop_clear_part - (STOP_CLEAR) the wheel and the note map cleared, a page
; a call while there is time (wheel_clear_page). Carry set: done.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_clear_part
-       ldx stop_page
        cpx #WHEEL_PAGES
        bcs _done
        jsr stop_time
        bcc _later
        jsr wheel_clear_page
        inc stop_page
        jmp -
_done   sec
        rts
_later  clc
        rts

; -----------------------------------------------------------------------------
; stop_reprepare - (main loop, live.asm: stopped, no stop being done; an
; edit published since, its snapshot entries moved to the new chains) the
; song prepared again from where it is ready: the player held, the 16th's
; snapshot restored (at the song's start: tick 0's), the wheel cleared
; and the first ticks rendered again (STOP_CLEAR, STOP_FIRST), then done
; with no song position (it hasn't moved). So a continue plays the new
; chains from the 16th, not the old ones for the lead rendered before.
; What is asked meanwhile is done after it (transport_poll). Carry set:
; not now (the state changed meanwhile, or no snapshot: can't be).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_reprepare
        lda pos_zero            ; at the song's start: tick 0 (a reset leaves no
        beq +                   ; locate)
        lda #0
        sta locate_tick
        sta locate_tick+1
        sta locate_16th
        sta locate_16th+1
+       lda locate_tick
        sta pl_time
        lda locate_tick+1
        sta pl_time+1
        php
        sei
        lda play_state
        cmp #PLAY_STOPPED
        bne _not
        lda stop_phase
        bne _not
        lda #PLAY_HELD          ; (a slave's start or stop meanwhile only asks)
        sta play_state
        plp
        jsr snapshot_restore
        bcs _none
.if TEST_LOG
        php                     ; (tests: LOG_REPREPARE)
        sei
        lda #0
        sta log_a_value
        lda #LOG_REPREPARE
        jsr log_a
        plp
.endif
        lda #STOP_DONE
        sta stop_then
        lda #0
        sta stop_page
        lda #STOP_CLEAR
        sta stop_phase
        clc
        rts
_none   lda #PLAY_STOPPED
        sta play_state
        sec
        rts
_not    plp
        sec
        rts

; -----------------------------------------------------------------------------
; stop_there - (stop_run, the wheel clear) nothing sounds, everything
; counts from the 16th's tick; then its first ticks rendered again a piece
; at a time (STOP_FIRST: the lead the tempo's, a slave's its master's).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_there
        lda #0
        sta last_status
        sta render_phase
        sta rel_partial
        sta pl_step_tick
        lda locate_16th
        and #1
        sta pl_step_odd
        lda locate_tick
        sta ren_tick
        sta rel_tick
        sta play_tick
        sta song_tick
        lda locate_tick+1
        sta ren_tick+1
        sta rel_tick+1
        sta play_tick+1
        sta song_tick+1
        lda stage_head
        sta stage_tail
        sta stage_commit_at
        jsr snapshot_save       ; (this 16th's state: its start)
        ; whether it is the song's start; its first ticks rendered again
        ldx #0
        lda locate_tick
        ora locate_tick+1
        bne +
        inx
+       stx pos_zero
        jsr player_set_tempo
        jsr slave_first_lead
        ; (on into stop_first_begin)

; stop_first_begin - the lead's first ticks to render from ren_tick:
; STOP_FIRST. clobbers A
stop_first_begin
        lda ren_tick
        clc
        adc render_ahead
        sta render_first_end
        lda #STOP_FIRST
        sta stop_phase
        rts

; -----------------------------------------------------------------------------
; stop_first_part - (STOP_FIRST) the lead's first ticks rendered, a step at
; a time while there is time, as render_first (stopping early while the
; stage still has STAGE_RESERVE free: nothing is due to make room).
; Carry set: done.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_first_part
-       lda ren_tick
        cmp render_first_end
        beq _done               ; the lead rendered
        lda stage_tail          ; free = tail - head - 1 (carry clear: the 1)
        clc
        sbc stage_head
        cmp #STAGE_RESERVE
        bcc _done               ; nearly full: the rest when playing
        jsr stop_time
        bcc _later
        jsr render_step
        jmp -
_done   sec
        rts
_later  clc
        rts

; -----------------------------------------------------------------------------
; stop_position_part - (STOP_POSITION, master) the song position sent, once
; the ring has room for it (never waited for, but with stop_unlimited).
; Carry set: sent.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
stop_position_part
        lda tx_tail             ; room for 3 bytes? tail - next - 1
        clc
        sbc out_next
        cmp #3
        bcs +
        lda stop_unlimited
        bne +                   ; (out_message_main waits)
        clc
        rts
+       jsr send_song_position
        sec
        rts

; log_locate - (tests) which way stop_locate went, A = LOCATE_*: an entry
; LOG_LOCATE in log A (interrupts off: the timer interrupt writes it too),
; + LOCATE_PARTIAL when the stop came in the middle of a tick partly sent.
; Nothing in other builds (#log_at: not even the call). clobbers A, X
log_at  .macro                  ; log_locate with A = \1, in test builds with a log
.if TEST_LOG
        lda #\1
        jsr log_locate
.endif
        .endm
LOCATE_THERE    = 0             ; the renderer at the 16th's start already
LOCATE_FORWARD  = 1             ; rendered on to it
LOCATE_BACK     = 2             ; back with its snapshot
LOCATE_NONE     = 3             ; no snapshot (a bug): from the song's start
LOCATE_BROKEN   = 8             ; (added) after an abandoned step (render_abort): from a
                                ;   snapshot (then forward or back logged after it)
LOCATE_PARTIAL  = 4             ; (added) a tick was partly sent
.if TEST_LOG
log_locate
        php
        sei
        sta log_a_value
        lda rel_partial         ; (0 or 1: * LOCATE_PARTIAL)
        asl
        asl
        ora log_a_value
        sta log_a_value
        lda #LOG_LOCATE
        jsr log_a
        plp
        rts
.endif

; -----------------------------------------------------------------------------
; send_song_position - MIDI song position (16ths: 14 bits) of locate_16th,
; through the merger (main loop).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
send_song_position
        lda #MIDI_SONG_POSITION
        sta out_msg
        lda locate_16th
        and #$7f
        sta out_msg+1
        lda locate_16th         ; bits 7-13
        asl
        lda locate_16th+1
        rol
        and #$7f
        sta out_msg+2
        lda #3
        sta out_msg_len
        jmp out_message_main

; -----------------------------------------------------------------------------
; div12 - div_lo/hi / 12: the quotient in div_lo/hi, the remainder in A
; (Z set if none). Shift and subtract, 16 steps.
; clobbers A, X
; -----------------------------------------------------------------------------
div12
        lda #0
        ldx #16
-       asl div_lo
        rol div_hi
        rol a
        cmp #TICKS_PER_STEP
        bcc +
        sbc #TICKS_PER_STEP     ; (carry set)
        inc div_lo              ; (bit 0 was 0)
+       dex
        bne -
        cmp #0
        rts

; times12 - locate_tick = div_lo/hi * 12 (* 8 + * 4). clobbers A
times12
        lda div_lo              ; * 4
        asl
        sta locate_tick
        lda div_hi
        rol
        sta locate_tick+1
        asl locate_tick
        rol locate_tick+1
        lda locate_tick         ; * 8 in div (it isn't needed after)
        asl
        sta div_lo
        lda locate_tick+1
        rol
        sta div_hi
        clc
        lda locate_tick
        adc div_lo
        sta locate_tick
        lda locate_tick+1
        adc div_hi
        sta locate_tick+1
        rts
