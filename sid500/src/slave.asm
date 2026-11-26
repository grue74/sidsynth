; slave.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; As slave (Clock = MIDI) the master's clock plays the ticks instead
; (design 4): a clock byte is caught in the receive interrupt
; (synth_rt_irq), passed on at once, and kicks timer A to run out a few
; cycles later, so the even tick plays in synth_timer as a master's tick
; does; the odd tick between two clocks comes from timer A as a one-shot
; at half the last clock gap, measured on the free-running time (CIA2).
;
; Here too: the free-running time (time_init, time_read) the gaps are
; measured on, which the test logs' stamps read as well. (After the
; player's code: its hot loops keep their places, and their branches
; their page crossings, when this changes.)

CRA_ONE_SHOT    = %00011001     ; timer A: force latch load, one-shot, start
TIMER_KICK      = 2             ; slave: timer A runs out this many cycles after a clock came
                                ; (before anything can read the ICR: one interrupt, not two)
SLAVE_HALF_MIN  = $0800         ; half a clock gap below this (above ~600 BPM): not taken
SLAVE_ODD_EARLY = 64            ; an odd tick's interrupt this early is its (more: a stray)
SLAVE_FIRST_LEAD = LEAD_MAX     ; ticks a slave renders before start (render.asm): the lead
                                ; at the fastest tempo and more

        .section zp
; the time, as time_read reads it (CIA2: 24 bits, counting down a cycle a
; count), one copy for each context that reads it: low, middle, high
time_irq        .fill 3         ;   synth_timer's
time_rx         .fill 3         ;   synth_rt_irq's (on an NMI interface: in an NMI)
; slave: synth_rt_irq writes these (clock in), synth_timer reads them
slave_clocks    .byte ?         ; clocks in while playing, counted (wraps)
slave_period_lo .fill 2         ; a tick's cycles at each clock, by the count's lowest
slave_period_hi .fill 2         ;   bit (one being written while the other is read)
slave_last      .fill 3         ; synth_rt_irq's own: the last clock's time
slave_last_ok   .byte ?         ;   nonzero = there was one (a gap can be measured)
slave_period    .word ?         ;   a tick's cycles: half the last clock gap taken
slave_gap       .fill 3         ;   (scratch)
; slave: synth_rt_irq writes these, the main loop (transport_poll) reads
; and clears them while the player is held
slave_req       .byte ?         ; MIDI_START or MIDI_CONTINUE: asked while held, 0 = none
slave_stop_req  .byte ?         ; nonzero: stop came while playing (the notes to end)
rt_byte         .byte ?         ;   (scratch: the byte in)
; slave: synth_timer's own
slave_done      .byte ?         ; the clocks it has played (as slave_clocks)
slave_seen      .byte ?         ; slave_clocks as read this time
slave_odd       .byte ?         ; 1 = the last clock's odd tick is still to play
slave_odd_time  .fill 3         ;   its time: the clock's tick's + a tick
slave_ticks     .byte ?         ; (scratch: the ticks due now)
        .send

; -----------------------------------------------------------------------------
; time_init - CIA2's timers free running, no interrupt: timer A a cycle a
; count from $FFFF, timer B counting timer A's wraps: 24 bits, counting
; down (time_read), wrapping every 17 s. The slave's clock gaps and the
; test logs' stamps.
; -----------------------------------------------------------------------------
time_init
        lda #$ff
        sta CIA2_TA_LO
        sta CIA2_TA_HI
        sta CIA2_TB_LO
        sta CIA2_TB_HI
        lda #%01010001          ; timer B: force latch load, count timer A's wraps, start
        sta CIA2_CRB
        lda #%00010001          ; timer A: force latch load, start, continuous
        sta CIA2_CRA
        rts

; -----------------------------------------------------------------------------
; time_read - (macro; \1 = 3 bytes) the time now into \1 (low, middle,
; high): timer B, timer A's high byte, its low byte, then both read again
; until neither moved (a wrap between). ~35 cycles. clobbers A
; -----------------------------------------------------------------------------
time_read .segment
-       lda CIA2_TB_LO
        sta \1+2
        lda CIA2_TA_HI
        sta \1+1
        lda CIA2_TA_LO
        sta \1
        lda CIA2_TA_HI
        cmp \1+1
        bne -
        lda CIA2_TB_LO
        cmp \1+2
        bne -
        .endsegment

; -----------------------------------------------------------------------------
; slave_tick - (synth_timer, slave, interrupts off: but on an NMI
; interface synth_rt_irq can come in between) the ticks due now, in A.
; Clocks in since the last time (normally one; the clock's kick ran timer
; A out): the even tick, and before it an odd tick still owed (the master
; sped up: its clock came before the odd tick's one-shot ran out), 2n - 1
; for n clocks; then timer A one-shot to the odd tick, a tick period from
; now (so the two ticks are as far apart as the master's clocks: each
; clock's tick is late by the same receive interrupt, the kick, and the
; clock passed on), and the render lead for the period. No clock
; in: the odd tick, if one is owed and it is its time (a kick that came in
; an NMI during the even tick leaves a stray interrupt, before its time).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
slave_tick
        lda play_state
        cmp #PLAY_STARTING
        beq +
        cmp #PLAY_RUNNING
        beq +
        lda #0                  ; stopped or held: nothing plays
        rts
+       lda slave_clocks
        sta slave_seen
        sec
        sbc slave_done
        beq _odd
        ; n clocks in: 2n - 1 ticks, and the odd tick owed
        asl                     ; (n < 128: carry clear)
        adc slave_odd
        sec
        sbc #1
        sta slave_ticks
        lda #1
        sta slave_odd
        lda slave_seen
        sta slave_done
        lda #PLAY_RUNNING       ; (the first clock after start: song tick 0)
        sta play_state
        ; the odd tick: timer A one-shot a tick period from now (the
        ; latest clock's slot), and its time kept (now - the period: the
        ; time counts down)
        lda slave_seen
        and #1
        tax
        #time_read time_irq
        lda slave_period_lo,x
        sta CIA1_TA_LO          ; (the latch, loaded by the force bit)
        lda slave_period_hi,x
        sta CIA1_TA_HI
        lda #CRA_ONE_SHOT
        sta CIA1_CRA
        sec
        lda time_irq
        sbc slave_period_lo,x
        sta slave_odd_time
        lda time_irq+1
        sbc slave_period_hi,x
        sta slave_odd_time+1
        lda time_irq+2
        sbc #0
        sta slave_odd_time+2
        ; the render lead at the master's tempo (about 42 ms of ticks)
        ldy slave_period_hi,x
        jsr slave_lead_y        ; (size.asm: computed, a table no more)
        jsr set_lead
        ; a clock in meanwhile (an NMI) may have had its kick overwritten
        ; here: kicked again, so it plays at once
        lda slave_clocks
        cmp slave_seen
        beq +
        jsr slave_kick
+       lda slave_ticks
        rts
        ; no clock in: the odd tick, if owed and its time
_odd    lda slave_odd
        beq _none
        #time_read time_irq
        sec                     ; now - its time: how early this is
        lda time_irq
        sbc slave_odd_time
        tay
        lda time_irq+1
        sbc slave_odd_time+1
        sta time_irq+1
        lda time_irq+2
        sbc slave_odd_time+2
        bmi _odd_now            ; past its time
        bne _none               ; (far early: a stray)
        lda time_irq+1
        bne _none
        cpy #SLAVE_ODD_EARLY+1
        bcs _none
_odd_now
        lda #0
        sta slave_odd
        lda #1
        rts
_none   lda #0
        rts

; -----------------------------------------------------------------------------
; slave_kick - timer A one-shot, running out TIMER_KICK cycles from now:
; synth_timer plays a clock's tick at once (in its own interrupt, as every
; tick: never in the receive interrupt, an NMI on some interfaces). A
; one-shot still running (an odd tick's) is replaced: the kick's tick
; plays it too.
; clobbers A
; -----------------------------------------------------------------------------
slave_kick
        lda #TIMER_KICK
        sta CIA1_TA_LO
        lda #0
        sta CIA1_TA_HI
        lda #CRA_ONE_SHOT
        sta CIA1_CRA
        rts

; -----------------------------------------------------------------------------
; synth_rt_irq - core hook (MIDI_RT_IRQ): a realtime byte as it arrives,
; from the receive interrupt (an NMI on some interfaces). A = the byte;
; may clobber A and X only. Master: ignored. Slave: passed on to MIDI out
; at once (design 4: the synths downstream stay in sync), then clock
; (slave_clock_in), start, continue and stop (design 4: the slave as
; built). What takes long (the notes ended at a stop, the song located or
; reset) is left to the main loop (transport_poll), the player held
; meanwhile; this only changes play_state and asks.
; -----------------------------------------------------------------------------
synth_rt_irq
        ldx params+P_CLOCK
        bne +
        rts                     ; master: the bytes in are ignored
+       sta rt_byte
        jsr midi_send_urgent    ; passed on first
        lda rt_byte
        cmp #MIDI_CLOCK
        beq slave_clock_in
        ldx play_state
        cmp #MIDI_STOP
        beq _stop
        cmp #MIDI_START
        beq _start
        cmp #MIDI_CONTINUE
        bne _done
        ; continue: stopped, the song is ready where it stopped: the next
        ; clock plays
        cpx #PLAY_STOPPED
        beq _go
        bne _ask                ; (held: when the main loop is done)
        ; start: from the song's start; ready there only if it is at it
_start  cpx #PLAY_STOPPED
        bne _ask
        ldx pos_zero
        bne _go
_hold   ldx #PLAY_HELD          ; the main loop resets it first (or puts HI3_CODE back)
        stx play_state
_ask    cpx #PLAY_HELD          ; (playing, or starting: ignored)
        bne _done
        sta slave_req           ; held: asked (clocks counted from here on)
        jmp _from_now
.if DISK_CODE
_go     ldx hi3_out             ; the code at HI3_CODE kept in the note map (disk.asm):
        bne _hold               ; held, the main loop puts it back first (transport_poll)
        ldx #PLAY_STARTING
.else
_go     ldx #PLAY_STARTING
.endif
        stx play_state
        ldx #0                  ; (the song moves on from here)
        stx pos_zero
_from_now
        lda slave_clocks        ; clocks counted from now, none owed
        sta slave_done
        lda #0
        sta slave_odd
_done   rts
        ; stop: starting, nothing played yet: stopped; playing: held, the
        ; main loop ends the notes; held: what was asked is off
_stop   lda #0
        sta slave_req
        cpx #PLAY_STARTING
        bne +
        lda #PLAY_STOPPED
        sta play_state
        rts
+       cpx #PLAY_RUNNING
        bne _done
        lda #PLAY_HELD
        sta play_state
        sta slave_stop_req
        rts

; -----------------------------------------------------------------------------
; slave_clock_in - (synth_rt_irq) a clock in, slave. Always: the gap since
; the last clock measured, and half of it taken as a tick's length if it
; is one (SLAVE_HALF_MIN to $FFFF cycles: a longer gap is a pause). While
; playing: the tick's length into the clock's slot, the clock counted, and
; timer A kicked (synth_timer plays the even tick).
; clobbers A, X
; -----------------------------------------------------------------------------
slave_clock_in
        #time_read time_rx
        lda slave_last_ok
        beq _gap_done
        ; the gap: last - now (the time counts down); half of it a tick
        sec
        lda slave_last
        sbc time_rx
        sta slave_gap
        lda slave_last+1
        sbc time_rx+1
        sta slave_gap+1
        lda slave_last+2
        sbc time_rx+2
        lsr
        ror slave_gap+1
        ror slave_gap
        tax
        bne _gap_done           ; a tick over $FFFF cycles: a pause, not a tempo
        lda slave_gap+1
        cmp #>SLAVE_HALF_MIN
        bcc _gap_done           ; too short to be a tempo
        sta slave_period+1
        lda slave_gap
        sta slave_period
_gap_done
        ; this clock's time is the next gap's start
        lda time_rx
        sta slave_last
        lda time_rx+1
        sta slave_last+1
        lda time_rx+2
        sta slave_last+2
        lda #1
        sta slave_last_ok
        ; playing: the tick's length into the slot the count will point
        ; at, then the count (synth_timer reads the slot after it), and
        ; the kick. Held with a start or continue asked: counted, not
        ; kicked (the main loop kicks when the song is ready)
        lda play_state
        cmp #PLAY_STARTING
        beq +
        cmp #PLAY_RUNNING
        beq +
        cmp #PLAY_HELD
        bne _done
        lda slave_req
        bne _count              ; (counted only)
        rts
+       jsr _count
        jmp slave_kick
_done   rts
_count  lda slave_clocks
        clc
        adc #1
        and #1
        tax
        lda slave_period
        sta slave_period_lo,x
        lda slave_period+1
        sta slave_period_hi,x
        inc slave_clocks
        rts
