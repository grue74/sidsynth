; record.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; MIDI in while playing or stopped (docs/design.md section 5b, settled
; with the user 2026-11-22). The main loop is often held for tens of ms
; (busy ticks rendered by the timer interrupt), so MIDI in is parsed in
; the receive interrupt (core option MIDI_RX_IRQ, the user's choice),
; every byte as it comes, any channel:
;
; - Thru (the Thru parameter, On at start): notes, controllers, bend and
;   program changes out again on the record track's channel (the cursor's
;   track on the song screen, the open pattern's on the step grid). A
;   note's off goes to the channel its on went to, so moving the cursor
;   while a key is held leaves nothing sounding. Aftertouch isn't passed
;   on. A message waits in thru's queue for its turn in the merger:
;   between whole ticks only (not during a release, release_busy, nor
;   while a tick goes out in parts, rel_partial: their running status),
;   with room for it in the transmit ring. It goes at once from the IRQ;
;   from the NMI (Namesoft) only queued, as anything may be interrupted
;   there. What waits goes after the next tick's release (synth_timer:
;   click_midi_send, MIDI_SEND_THRU) or from the main loop (thru_poll).
;
; The core's parser goes on with the bytes from its ring as before (step
; entry on the grid, a controller learnt for a parameter).

THRU_HELD       = $df80         ; (RAM under I/O, the last 128 bytes) each note: the channel + 1 its on went
                                ; out on through thru, 0 = none sounding
        .cerror io_tables_end > THRU_HELD, "the tables under I/O run into THRU_HELD"
THRU_SLOTS      = 32            ; thru's queue: messages waiting for the merger
THRU_QUEUE_SIZE = THRU_SLOTS * 3 ; (3 bytes each: a one-data message's third is $FF)
THRU_MARK       = TEST_FEED_MASTER && TEST_STAMP_FEW != 3 ; (tests: thru's bytes stamped
                                ; apart; not when timing the ticks, the marks' cost)
THRU_WIRE_EXTRA = 3 + 1         ; bytes on the wire before a clock besides those waiting in
                                ; the ring: the message's and the one in the 6850
MIDI_SEND_THRU  = $20           ; click_midi: thru's queue to send after the release

MSG_NOTE_OFF    = $80
MSG_POLY_PRESSURE = $a0         ; (aftertouch: not passed on)
MSG_PRESSURE    = $d0
LOG_THRU_LOST   = 21            ; (tests, log b) thru's queue full: a message lost
LOG_RX_DONE     = 24            ; (tests, log a: TEST_RX_TIME) synth_rx_irq done
LOG_MARKS_FULL  = 23            ; (tests, log b) THRU_MARKS places in the ring at once: a mark lost
THRU_MARKS      = 64            ; (tests) thru_marks' size, a power of 2 (the room under the KERNAL)

        .section edit_vars      ; (under the KERNAL: the interrupts read it with $01 = $35)
rx_status       .byte ?         ; MIDI in's running status (0 = none: data dropped)
rx_have         .byte ?         ;   its data bytes so far (0 or 1)
rx_d1           .byte ?         ;   the message's data
rx_d2           .byte ?         ;   ($FF: a one-data message)
thru_channel    .byte ?         ; the channel a thru message goes out on, 0-15
thru_swap       .byte ?         ; thru_held_swap's scratch
thru_head       .byte ?         ; thru's queue: where the next message goes (rx interrupt)
thru_tail       .byte ?         ;   the first not yet sent (sei: the flush)
thru_queue      .fill THRU_QUEUE_SIZE
.if THRU_MARK
thru_marks      .fill THRU_MARKS ; (tests) the transmit ring's places holding thru's bytes, in
                                ; the order they go (the transmit interrupt looks at the first)
thru_mark_in    .byte ?         ;   where the next goes
thru_mark_out   .byte ?         ;   the first not yet sent
thru_mark_x     .byte ?         ;   (thru_byte's scratch)
thru_marked_x   .byte ?         ;   (thru_marked's: on Namesoft it runs in the NMI, which may
                                ;   come inside thru_byte)
.endif
        .send

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; record_init - (synth_init, interrupts off) nothing sounding through
; thru, nothing queued, no running status.
; clobbers A, X
; -----------------------------------------------------------------------------
record_init
        lda #RAM_ALL
        sta $01
        lda #0
        ldx #127
-       sta THRU_HELD,x
        dex
        bpl -
        ldx #RAM_IO
        stx $01
        sta rx_status
        sta rx_have
        sta thru_head
        sta thru_tail
.if THRU_MARK
        sta thru_mark_in
        sta thru_mark_out
.endif
        rts
        .send

; -----------------------------------------------------------------------------
; synth_rx_irq - core hook (MIDI_RX_IRQ): byte A received, from the
; receive interrupt (IRQ, or the NMI: midi_nmi_mode), realtime bytes not
; among them (MIDI_RT_IRQ). Parsed: a channel message whole goes to
; rx_message; a system byte ends running status.
; keeps A; clobbers X
; -----------------------------------------------------------------------------
synth_rx_irq_base               ; (scene.asm synth_rx_irq first: song select)
.if TEST_RX_TIME
        jsr rx_parse            ; (tests: its end logged, its time from the byte's
        sta log_a_value         ; LOG_RX: thru_check.py)
        lda #LOG_RX_DONE
        jsr log_a
        lda log_a_value
        rts
rx_parse
.endif
        cmp #$80
        bcs _status
        ldx rx_status
        beq _done               ; data without a status: dropped
        ldx rx_have
        bne _second
        sta rx_d1
        tax
        lda rx_status           ; $Cx and $Dx carry one data byte, the rest two
        and #$e0
        cmp #$c0
        beq _one
        inc rx_have
        txa
        rts
_one    lda #$ff
        sta rx_d2
        txa
        jmp rx_message
_second sta rx_d2
        ldx #0
        stx rx_have
        jmp rx_message
_status cmp #$f0
        bcs _system
        sta rx_status
        ldx #0
        stx rx_have
_done   rts
_system cmp #$f8
        bcs _done               ; (realtime: no effect on parsing)
        ldx #0                  ; system common, SysEx: running status ends
        stx rx_status
        stx rx_have
        rts

; -----------------------------------------------------------------------------
; rx_message - (synth_rx_irq) a whole message: rx_status, rx_d1, rx_d2.
; With Thru on (aftertouch left out): into thru's queue on the record
; track's channel, an off on the channel its on went to (none if its on
; didn't go out: Thru turned on while the key was held); then sent, from
; the IRQ. keeps A; clobbers X
; -----------------------------------------------------------------------------
rx_message_base                 ; (scene.asm rx_message first: MIDI launches)
        pha
        tya
        pha
        lda rec_state           ; a take: stamped into its ring (take.asm)
        cmp #REC_ON
        bne +
        jsr rec_put_armed       ; (locate.asm, then count.asm: a count-in's early ones)
+       lda params+P_THRU
        bne _thru
_none   pla
        tay
        pla
        rts
_thru   lda rx_status
        and #$f0
        cmp #MSG_POLY_PRESSURE
        beq _none
        cmp #MSG_PRESSURE
        beq _none
        tay                     ; Y = the kind
        ; the record track's channel
        ldx song_cursor
        lda song_mode
        cmp #MODE_GRID
        bne +
        ldx grid_track
+       lda TRACK_CHANNEL,x
        sta thru_channel
        ; a note: its on's channel kept for its off
        cpy #MSG_NOTE_OFF
        beq _off
        cpy #MSG_NOTE_ON
        bne _put
        lda rx_d2
        beq _off                ; (velocity 0: an off)
        ldx thru_channel
        inx
        txa
        ldx rx_d1
        jsr thru_held_swap
        jmp _put
_off    lda #0
        ldx rx_d1
        jsr thru_held_swap
        tax
        beq _done               ; its on never went out: nor does its off
        dex
        stx thru_channel
        ; into the queue: the status on that channel, the data as it came
_put    tya
        ora thru_channel
        ldx thru_head
        sta thru_queue,x
        lda rx_d1
        sta thru_queue+1,x
        lda rx_d2
        sta thru_queue+2,x
        txa
        clc
        adc #3
        cmp #THRU_QUEUE_SIZE
        bcc +
        lda #0
+       cmp thru_tail
        beq _lost               ; full (the slot not published)
        sta thru_head
        lda click_midi          ; (what waits goes after the next release, at the latest)
        ora #MIDI_SEND_THRU
        sta click_midi
        lda midi_nmi_mode
        bne _done               ; the NMI: anything may have been interrupted
        lda play_state          ; playing: it goes at the tick's start, after its clock
        cmp #PLAY_STARTING      ; (release_thru): sent here, the tick's interrupt
        beq _done               ; would wait for it
        cmp #PLAY_RUNNING
        beq _done
        jsr thru_flush_irq
_done   jmp _none
_lost
.if TEST_LOG
        lda #LOG_THRU_LOST      ; (tests: never seen, thru_check.py)
        jsr log_b
.endif
        jmp _done

; thru_held_swap - THRU_HELD for note X set to A, A = what it was (Z set
; for 0). keeps X, Y
thru_held_swap
        sta thru_swap
        lda #RAM_ALL
        sta $01
        lda THRU_HELD,x
        pha
        lda thru_swap
        sta THRU_HELD,x
        lda #RAM_IO
        sta $01
        pla
        rts

; -----------------------------------------------------------------------------
; thru_drain - (interrupts as they are: click_midi_send after the release,
; thru_poll) the queue's messages into the transmit ring and sent, between
; whole ticks only, as many as there is room for, each inside sei on its
; own (a tick's interrupt, its clock, wait no longer than for one); with
; all sent, MIDI_SEND_THRU off.
; clobbers A, X
; -----------------------------------------------------------------------------
thru_drain
        php
        sei
        lda release_busy
        ora rel_partial
        bne _done
        jsr thru_one
        bcs _done
        jsr out_go
        plp
        jmp thru_drain
_done   plp
        rts

; thru_flush_irq - (rx_message, the receive IRQ: interrupts off) the same
; for one message (the IRQ short: more go after the next release, or from
; the main loop; no interrupt let in here, so none nests in this one).
; clobbers A, X
thru_flush_irq
        lda release_busy
        ora rel_partial
        bne _done
        jsr thru_one
        bcs _done
        jmp out_go
_done   rts

; thru_one - (interrupts off) the message at thru_tail into the transmit
; ring, if there is room for it: carry clear = queued (not yet published),
; set = none waiting (MIDI_SEND_THRU then off) or no room.
; clobbers A, X
thru_one
        ldx thru_tail
        cpx thru_head
        beq _empty
        ; not if it would still be on the wire at a clock's tick (as
        ; master, playing: the next tick has one): the bytes waiting in
        ; the ring, the message's 3 and the one in the 6850, 315 cycles
        ; each (the wire's 10 bits; ~1/4 more than a page: 320), against
        ; timer A's pages to the tick; it goes after the tick, the clock
        ; first (release_thru). (Counted 283, VICE's 9 bits, until a real
        ; 6850 was measured: docs/latency.md "The hardware test".)
        lda clock_countdown
        cmp #1
        bne _go
        lda params+P_CLOCK
        bne _go
        lda play_state
        cmp #PLAY_RUNNING
        bne _go
        lda out_next            ; the bytes waiting
        sec
        sbc tx_tail
        clc
        adc #THRU_WIRE_EXTRA
        bcs _full
        sta thru_swap
        lsr
        lsr
        adc thru_swap           ; (pages: n + n/4)
        bcs _full
        cmp CIA1_TA_HI
        bcs _full               ; too few pages left
_go     lda tx_tail             ; room for 3? (tail - next - 1)
        clc
        sbc out_next
        cmp #3
        bcc _full
        lda thru_queue,x
        jsr thru_byte
        lda thru_queue+1,x
        jsr thru_byte
        lda thru_queue+2,x
        bmi +                   ; (a one-data message)
        jsr thru_byte
+       txa
        clc
        adc #3
        cmp #THRU_QUEUE_SIZE
        bcc +
        lda #0
+       sta thru_tail
        cmp thru_head
        bne +
        lda click_midi          ; (the last: nothing waits after the release)
        and #$ff-MIDI_SEND_THRU
        sta click_midi
+       clc
        rts
_empty  lda click_midi
        and #$ff-MIDI_SEND_THRU
        sta click_midi
_full   sec
        rts

; thru_byte - out_byte, and in tests (TEST_FEED_MASTER) the ring's place
; marked as thru's (thru_marks: timing.asm synth_tx_byte stamps it apart).
; (interrupts off) preserves A, X, Y
thru_byte
.if THRU_MARK
        pha
        stx thru_mark_x
        ldx thru_mark_in
        lda out_next            ; its place, last in the marks
        sta thru_marks,x
        inx
        txa
        and #THRU_MARKS-1
        cmp thru_mark_out
        bne +
        lda #LOG_MARKS_FULL     ; (full: thru_check.py fails on it)
        jsr log_b
        jmp ++
+       sta thru_mark_in
+       ldx thru_mark_x
        pla
.endif
        jmp out_byte

.if THRU_MARK
; thru_marked - (tests: synth_tx_byte) the ring's byte X thru's (the first
; mark's place)? Carry set: yes, the mark gone. keeps A, X
thru_marked
        pha
        stx thru_marked_x
        ldx thru_mark_out
        cpx thru_mark_in
        beq _no                 ; (no marks)
        lda thru_marks,x
        cmp thru_marked_x
        bne _no
        inx
        txa
        and #THRU_MARKS-1
        sta thru_mark_out
        ldx thru_marked_x
        pla
        sec
        rts
_no     ldx thru_marked_x
        pla
        clc
        rts
.endif

; release_thru - (render.asm release, a tick due; interrupts as they are)
; before a tick's first bytes (rel_partial 0), thru's queue first: right
; after the clock, what the clock guard held. A message at a time inside
; sei (the release is this one: release_busy not looked at).
; clobbers A, X
release_thru
        lda rel_partial
        bne _done
_next   lda thru_head
        cmp thru_tail
        beq _done
        php
        sei
        jsr thru_one
        bcs +
        jsr out_go
        plp
        jmp _next
+       plp
_done   rts

; -----------------------------------------------------------------------------
; commit_release - (render.asm stage_commit, the renderer behind) the
; tick's whole messages so far released; then, with them all out and the
; tick partly sent (rel_partial: its rest still to be rendered), what
; waits in thru's queue goes between its parts, and the renderer's next
; message carries its status again (last_status), as thru's had its own.
; So thru doesn't wait out a busy tick rendered while it goes (tens of ms
; at half the wire). clobbers A, X, Y
; -----------------------------------------------------------------------------
commit_release
        jsr release
        lda rel_partial
        beq _done
        lda thru_head
        cmp thru_tail
        beq _done
_next   php                     ; a message at a time inside sei
        sei
        lda release_busy        ; (inside a release this interrupted: not now)
        bne +
        lda stage_tail          ; nothing staged after the part sent
        cmp stage_head
        bne +
        jsr thru_one
        bcs +
        jsr out_go
        lda #0
        sta last_status
        plp
        jmp _next
+       plp
_done   rts

; -----------------------------------------------------------------------------
; thru_poll - (synth_tick, main loop) what waits in thru's queue sent
; (from the NMI, while playing, a full ring: not sent yet).
; clobbers A, X
; -----------------------------------------------------------------------------
thru_poll
        lda thru_head
        cmp thru_tail
        beq +
        jmp thru_drain
+       rts

; -----------------------------------------------------------------------------
; thru_all_off - (Thru set Off: no message is queued any more) what is
; queued sent, then an off for every note sounding through thru, on the
; channel its on went to.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
thru_all_off
-       jsr thru_poll           ; (the queue first: its ons before their offs)
        lda thru_head
        cmp thru_tail
        bne -
        ldx #127
_note   lda #0
        jsr thru_held_swap
        beq _next
        tay
        dey
        tya
        ora #MSG_NOTE_ON        ; (velocity 0)
        sta out_msg
        stx out_msg+1
        lda #0
        sta out_msg+2
        lda #3
        sta out_msg_len
        txa
        pha
        jsr thru_out
        pla
        tax
_next   dex
        bpl _note
        rts

; -----------------------------------------------------------------------------
; thru_out - (main loop) out_msg queued and sent as out_message_main does,
; but only between whole ticks: while a tick goes out in parts
; (rel_partial: the renderer behind) its running status mustn't be broken,
; so it waits for the tick's rest with interrupts on. Not while the player
; is held: a stop counts that tick as sent (transport.asm).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
thru_out
-       sei
        lda rel_partial
        beq _whole
        lda play_state
        cmp #PLAY_HELD
        bne _wait               ; playing: the tick's rest comes soon
_whole  lda tx_tail
        clc
        sbc out_next            ; free bytes = tail - next - 1
        cmp out_msg_len
        bcc _wait
        jmp out_message_room
_wait   cli
        jsr out_go              ; (what is queued goes: room comes)
        jmp -
