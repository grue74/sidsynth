; timing.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The player's clock (docs/design.md section 4): CIA1 timer A interrupts
; once a sequencer tick (48 a quarter), its period the exact length of a
; tick at the tempo, 1,231,560 / BPM cycles, the fraction carried over by
; switching the latch between P and P+1 (dithering), so it never drifts.
; Every second tick sends MIDI clock through the core's urgent queue, ahead
; of any notes waiting. As slave the master's clock plays the ticks
; instead (src/slave.asm).
;
; Also here: the MIDI out merger's first piece (out_byte, out_go: main
; loop only so far), and for the tests the log of every tick and every
; byte sent, each stamped with the time, and the bursts of notes that load
; the wire.

CIA2_TA_LO      = $dd04         ; CIA2 timers A and B: the time (time_init)
CIA2_TA_HI      = $dd05
CIA2_TB_LO      = $dd06
CIA2_TB_HI      = $dd07
CIA2_CRA        = $dd0e
CIA2_CRB        = $dd0f

PLAY_STOPPED    = 0             ; play_state values
PLAY_STARTING   = 1             ; master: start_byte (start or continue) goes at the next
                                ; tick, the first clock a tick later (>= 3.4 ms); slave:
                                ; start or continue came, the next clock plays a tick
PLAY_RUNNING    = 2
PLAY_HELD       = 3             ; the main loop stopping, locating or resetting the player:
                                ; no tick plays (transport.asm)

        .section zp
period_lo       .byte ?         ; the timer latch at this tempo: a tick's cycles - 1
period_hi       .byte ?
period_frac     .byte ?         ; and the cycles' fraction, in 1/256
period_acc      .byte ?         ; the fractions so far (the dither's carry)
play_state      .byte ?         ; PLAY_STOPPED, PLAY_STARTING, PLAY_RUNNING
clock_countdown .byte ?         ; ticks until the next MIDI clock
start_byte      .byte ?         ; master: what PLAY_STARTING sends, MIDI start or continue
.if TEST_PLAY
behind_max      .byte ?         ; tests: the most ticks ever due and not yet rendered
ring_fill_max   .byte ?         ;   the transmit ring's fullest, seen at a tick
behind_when     .byte ?         ;   the play tick (low byte) the renderer was furthest behind
render_max      .word ?         ;   the longest render step, cycles (interrupts in it too)
render_max_when .word ?         ;   and that tick (song_tick before it)
render_start    .byte ?         ; (render_timed's scratch: the timer at the start, 2 bytes)
        .byte ?
render_max_step .word ?         ;   the longest step's phase and place in ACTIVE
render_step_was .word ?         ; (render_timed's scratch: this step's)
.endif
out_next        .byte ?         ; where out_byte queues next in the transmit ring: bytes
                                ; from tx_head up to here are queued but not yet published
.if TEST_LOG
stamp_countdown .byte ?         ; TEST_STAMP_FEW 2: bytes until the next one stamped
.endif
.if TEST_BURST
burst_countdown .byte ?         ; main-loop ticks until the next burst
burst_velocity  .byte ?         ; the burst's velocity: 0 = the note offs
.endif
        .send

; =============================================================================
; The player's timer
; =============================================================================

; -----------------------------------------------------------------------------
; player_init - from synth_init, interrupts off: the time running, the
; player prepared and started (player_prepare, player_go).
; -----------------------------------------------------------------------------
player_init
        jsr time_init
        jsr tempo_period        ; (the slave's tick length: the Tempo's until measured;
        lda tempo_q+1           ; size.asm)
        sta slave_period
        lda tempo_q+2
        sta slave_period+1
        lda #0
        sta slave_last_ok
        sta slave_odd
        sta slave_req
        sta slave_stop_req
        lda slave_clocks
        sta slave_done
        jsr player_prepare
        jmp player_go

        .section init_code      ; (start-up only: run once from INIT_CODE)
; (click_init lives here and player_prepare in click.asm, so the hot code
; after synth_timer stays where it was: the player's and the renderer's
; loops, the live reader. Shifted by the click's MIDI hooks, their page
; crossings made the live switch at 295 BPM up to ~585 ms late, from ~450.)
; -----------------------------------------------------------------------------
; click_init - (synth_init) voice 3's click sound set, silent; the SID's
; volume up (nothing else plays it yet); the phase to find.
; clobbers A
; -----------------------------------------------------------------------------
click_init
        lda #CLICK_WAVE         ; (gate off)
        sta SID_V3_CTRL
        lda #CLICK_AD
        sta SID_V3_AD
        lda #CLICK_SR
        sta SID_V3_SR
        lda #0
        sta SID_RES_FILT        ; (no voice through the filter)
        sta click_gate
        sta click_midi
        sta click_sounding
        lda #CLICK_SID          ; (C= K's first: the SID's click)
        sta click_last
        lda #CLICK_VOLUME
        sta SID_MODE_VOL
        lda play_tick           ; (the phase from the next tick: click_idle)
        eor #$ff
        sta click_seen
        rts
        .send

; -----------------------------------------------------------------------------
; player_go - the prepared player waiting, timer A's interrupt on. Master:
; timer A running at the tempo's period, stopped until a key starts it
; (test builds with a log and no key script: starting at once). Slave:
; timer A still, waiting for start and clock from MIDI in. Keeps the
; caller's interrupt flag.
; clobbers A
; -----------------------------------------------------------------------------
player_go
        jsr click_idle          ; (the metronome's phase from the next tick: a test's
        php                     ; start comes before any idle interrupt)
        sei
        lda #%10000001          ; enable timer A's interrupt
        sta CIA1_ICR
        lda params+P_CLOCK
        bne _slave
        ; master: timer A running at the tempo's period
        lda period_lo
        sta CIA1_TA_LO
        lda period_hi
        sta CIA1_TA_HI
        lda #%00010001          ; force latch load, start, continuous, counting cycles
        sta CIA1_CRA
.if TEST_AUTOSTART
        lda #MIDI_START         ; (tests: playing from start-up)
        sta start_byte
        lda #PLAY_STARTING
.else
        lda #PLAY_STOPPED
.endif
        sta play_state
        plp
        rts
_slave  lda #0                  ; slave: timer A still (the KERNAL left it running;
        sta CIA1_CRA            ; clocks kick it), waiting for start
        lda #PLAY_STOPPED
        sta play_state
        plp
        rts

; -----------------------------------------------------------------------------
; player_set_tempo - the period at params[P_TEMPO] (size.asm
; tempo_period): from the next tick but one on (the latch written at a tick is
; loaded at the next); and the render lead for the tempo (render.asm). The three bytes change together, out of the timer
; interrupt's way.
; clobbers A, X
; -----------------------------------------------------------------------------
player_set_tempo
        jsr tempo_period        ; (size.asm: computed, with interrupts on)
        php
        sei
        lda tempo_q
        sta period_frac
        lda tempo_q+1
        sta period_lo
        lda tempo_q+2
        sta period_hi
        lda tempo_lead_new      ; the render lead: about 42 ms of ticks
        jsr set_lead
        plp
        rts

; (HOT_PAD, which kept the code after this where it was timed, is gone:
; the code may move again, the timing checks run after each change; the
; user, 2026-11-25, design "Memory for the music")

; -----------------------------------------------------------------------------
; synth_timer - core hook (SYNTH_TIMER): CIA1 timer A ran out, a sequencer
; tick. Interrupts off, the CIA acknowledged, A saved by the core.
; With interrupts still off: MIDI clock (player_clock: the urgent queue at
; once, so a saturated wire can't hold it up behind the transmit
; interrupts), the next period's latch (the dither), the tick counted as
; due.
; Then interrupts go back on (design 4: the 6850 has no FIFO, a MIDI byte
; comes every 315 cycles, and the transmit interrupt must not wait behind
; the player): the ticks due are released (their bytes, rendered ahead,
; into the transmit ring: render.asm), and unless it is busy already the
; renderer renders ahead again.
; As slave the ticks due come from the clocks in instead (slave_tick).
; preserves X, Y
; -----------------------------------------------------------------------------
synth_timer
        txa                     ; (X and Y: the player uses both, and the main loop's
        pha                     ; must survive the interrupt)
        tya
        pha
.if TEST_LOG && TEST_STAMP_FEW != 1 && (!TEST_SLAVE || TEST_FEED_MASTER)
        jsr log_tick            ; (not when measuring the bursts' pace alone)
.endif
.if TEST_LOG
        tsx                     ; (tests: the stack more than half used is logged:
        cpx #STACK_WARN         ; interrupts nested too deep; timing_check.py's
        bcs +                   ; run_log fails on it)
        stx log_a_value
        lda #LOG_STACK
        jsr log_a
+
.endif
        lda params+P_CLOCK
        bne _slave
        ; the clock first (with an NMI interface every byte sent interrupts
        ; this handler: the sooner it is queued, the fewer come between)
        jsr player_clock
        php                     ; (its carry: a tick to play)
        ; the latch for the period after this one: P, or P+1 when the
        ; fractions add up to a whole cycle (carry). The timer is running,
        ; so this only sets the latch, loaded at the next underflow
        clc
        lda period_acc
        adc period_frac
        sta period_acc
        lda period_lo
        adc #0
        sta CIA1_TA_LO
        lda period_hi
        adc #0
        sta CIA1_TA_HI
        plp
        bcc _released
        inc play_tick           ; a tick due: its bytes may go
        bne +
        inc play_tick+1
+       dec click_wait          ; (the metronome's count: click.asm)
        jmp _counted
_slave  jsr slave_tick          ; (A = the ticks due: 0, 1, 2 ...)
.if TEST_LOG && TEST_SLAVE
        pha
        sta log_a_value         ; (tests: how many, and when)
        lda #LOG_SLAVE
        jsr log_a
        pla
.endif
        tax
        beq _released
        clc                     ; the ticks due: their bytes may go
        adc play_tick
        sta play_tick
        bcc +
        inc play_tick+1
+       jsr click_count         ; (the metronome's count, each tick: click.asm)
_counted
.if TEST_PLAY
        jsr test_measure        ; (tests: how far behind the renderer ever was)
.endif
_released
        lda play_state
        cmp #PLAY_STARTING
        beq +
        cmp #PLAY_RUNNING
        bne _idle               ; stopped or held: nothing released or rendered
+       cli
        lda click_gate          ; the metronome (click.asm): a click a tick long
        beq +                   ; released, and on a beat's tick the click, before
        jsr click_release       ; the tick's bytes
+       lda click_wait
        bne +
        ldx #1
        jsr click_beat
+       bit click_midi          ; the metronome's note on before them, on the beat (the
        bpl +                   ; user, 2026-11-22: the beat's notes ~1 ms later)
        jsr click_midi_send
+       jsr release             ; the ticks due out
        lda click_midi          ; the note's off after them (and a note on that had to
        beq +                   ; wait: click.asm)
        jsr click_midi_send
+
.if TEST_PROBE
        jsr probe_tick          ; (tests: the state after the release, PROBE_RAM)
.endif
.if TEST_PROBE
        lda steps_irq           ; (tests: the steps this render does)
        sta probe_steps
        lda release_busy        ;   and why it may not
        sta probe_rel_busy
        lda render_busy
        sta probe_ren_busy
.endif
        jsr render              ; and ahead again (unless it is rendering already)
.if TEST_PROBE
        jsr probe_after
.endif
        jmp _return
_idle   cli                     ; (the metronome's phase found again when it plays:
        jsr count_idle          ; ~1,100 cycles, a slave's clock passed on meanwhile;
                                ; the count-in's tick: count.asm)
_return pla                     ; (the core's rti puts the interrupt flag back)
        tay
        pla
        tax
        rts

; -----------------------------------------------------------------------------
; player_clock - MIDI realtime out for this tick, from synth_timer with
; interrupts off: start (or continue) at the first tick, then clock every
; second tick (so start goes out at least a tick, >= 3.4 ms, before the
; first clock), the first clock with the first tick played. As master only: a slave passes the
; master's clock on instead (synth_rt_irq), and the urgent queue has one
; writer at a time.
; Carry set = the player plays this tick (from the first clock's on).
; clobbers A, X
; -----------------------------------------------------------------------------
player_clock
        lda params+P_CLOCK
        bne _no                 ; slave: no clock of its own
        lda play_state
        cmp #PLAY_RUNNING
        beq _running
        cmp #PLAY_STARTING
        bne _no                 ; stopped or held
        ; starting: MIDI start or continue now, the song's tick with the
        ; next tick's clock
        lda #PLAY_RUNNING
        sta play_state
        lda #1
        sta clock_countdown
        lda start_byte
        jsr midi_send_urgent
_no     clc
        rts
_running
        dec clock_countdown
        bne _play
        lda #TICKS_PER_CLOCK
        sta clock_countdown
        lda #MIDI_CLOCK
        jsr midi_send_urgent
_play   sec
        rts

; =============================================================================
; MIDI out: the merger (its first piece)
; =============================================================================

; -----------------------------------------------------------------------------
; out_byte - queue byte A in the core's transmit ring, unpublished: it is
; written after tx_head without moving it, so the transmit interrupt
; doesn't see it until out_go publishes everything queued at once. Queued
; bytes the interrupt could see one by one would go out as they come: the
; ring runs dry between them, the interrupt turns itself off, and the rest
; waits for out_go (or, turned on per byte, each byte costs two interrupts
; and a control write, slower than the wire). So a message, or a tick's
; messages, are queued and then published with one pointer write (design
; 3: a change made aside, switched in atomically).
; One writer at a time: the player (interrupt), or the main loop inside
; sei (out_message_main). Never drops: when the ring is full, what is
; queued is published and sent first, and it waits for room. (With the
; interface Off, out_go throws the bytes away instead.)
; preserves A, X, Y
; -----------------------------------------------------------------------------
out_byte
        stx out_saved_x
-       ldx out_next
        sta tx_buffer,x         ; (written; kept only if the ring has room)
        inx
        cpx tx_tail
        beq _full
        stx out_next
        ldx out_saved_x
        rts
_full   jsr out_go              ; (the interrupt sends what is queued: room comes)
        jmp -

        .section zp
out_saved_x     .byte ?         ; out_byte keeps X here
        .send

; -----------------------------------------------------------------------------
; out_go - publish what out_byte queued (tx_head, one write) and turn the
; transmit interrupt on, unless it is. Writes the ACIA's control register
; only when the interrupt is off (tx_irq_on, as core midi_send_urgent:
; VICE restarts its byte timer at every control write); no interrupt
; between the test and the write. With the interface Off, what was queued
; is thrown away (nothing would send it).
; preserves A, X, Y
; -----------------------------------------------------------------------------
out_go
        pha
        lda midi_if_active
        bne +
        lda tx_head             ; interface Off: the queued bytes dropped
        sta out_next
        pla
        rts
+       lda out_next
        sta tx_head             ; (the transmit interrupt sees the bytes from here on)
        php
        sei
        lda tx_irq_on
        bne +
        lda #1
        sta tx_irq_on
        lda urgent_acia_ctrl    ; the control register's address, as midi_init patched it
        sta _acia_ctrl
        lda tx_ctrl_on
_acia_ctrl = *+1                ; operand low byte copied from midi_send_urgent's
        sta $de00
+       plp
        pla
        rts

.if TEST_PROBE
; -----------------------------------------------------------------------------
; probe_tick - (TEST_PROBE) at play ticks TEST_PROBE .. TEST_PROBE+15,
; after the timer's release: 16 bytes of state each into PROBE_RAM (play,
; ren, rel ticks' low bytes, the locks, render phase, the stage's indices,
; the ring's, tx_irq_on, and CIA2 timer A then).
; -----------------------------------------------------------------------------
PROBE_RAM       = $e000         ; (under the KERNAL: the scenes are at $CB00)
PROBE_AFTER     = $e100         ; probe_after: 8 bytes a tick

        .section zp
probe_steps     .byte ?
probe_rel_busy  .byte ?
probe_ren_busy  .byte ?
        .send

; probe_after - (TEST_PROBE) after the timer's render: its steps, the
; locks it found, the lead now, ren_tick, render_phase, pl_order
probe_after
        sec
        lda play_tick
        sbc #<TEST_PROBE
        tax
        lda play_tick+1
        sbc #>TEST_PROBE
        bne _out
        cpx #16
        bcs _out
        txa
        asl
        asl
        asl
        tax
        sec
        lda steps_irq
        sbc probe_steps
        sta PROBE_AFTER,x
        lda probe_rel_busy
        sta PROBE_AFTER+1,x
        lda probe_ren_busy
        sta PROBE_AFTER+2,x
        jsr ticks_lead
        sta PROBE_AFTER+3,x
        lda ren_tick
        sta PROBE_AFTER+4,x
        lda render_phase
        sta PROBE_AFTER+5,x
        lda pl_order
        sta PROBE_AFTER+6,x
        lda play_tick
        sta PROBE_AFTER+7,x
_out    rts

probe_tick
        sec
        lda play_tick
        sbc #<TEST_PROBE
        tax
        lda play_tick+1
        sbc #>TEST_PROBE
        bne _out
        cpx #16
        bcs _out
        txa
        asl
        asl
        asl
        asl
        tax
        lda play_tick
        sta PROBE_RAM,x
        lda ren_tick
        sta PROBE_RAM+1,x
        lda rel_tick
        sta PROBE_RAM+2,x
        lda release_busy
        sta PROBE_RAM+3,x
        lda render_busy
        sta PROBE_RAM+4,x
        lda render_phase
        sta PROBE_RAM+5,x
        lda stage_head
        sta PROBE_RAM+6,x
        lda stage_tail
        sta PROBE_RAM+7,x
        lda tx_head
        sta PROBE_RAM+8,x
        lda tx_tail
        sta PROBE_RAM+9,x
        lda out_next
        sta PROBE_RAM+10,x
        lda tx_irq_on
        sta PROBE_RAM+11,x
        lda CIA1_TA_LO          ; (the timer: how long since the tick)
        sta PROBE_RAM+12,x
        lda CIA1_TA_HI
        sta PROBE_RAM+13,x
        lda pl_order
        sta PROBE_RAM+14,x
        lda release_again
        sta PROBE_RAM+15,x
_out    rts
.endif

.if TEST_PLAY
; -----------------------------------------------------------------------------
; render_timed - (TEST_PLAY) render_step timed with CIA2 timer A (started
; free running here if no log started it): the longest step kept (how long
; the main loop is held up), with its song tick.
; -----------------------------------------------------------------------------
render_timed
        lda #%00000001          ; (running, not reloaded: the log's stamps use it too)
        sta CIA2_CRA
        lda render_phase        ; (the step: its phase and place, kept with the longest)
        sta render_step_was
        lda pl_order
        sta render_step_was+1
        lda song_tick
        pha
        lda song_tick+1
        pha
-       lda CIA2_TA_HI          ; (high, low, high again: the low byte may wrap)
        sta render_start+1
        lda CIA2_TA_LO
        sta render_start
        lda CIA2_TA_HI
        cmp render_start+1
        bne -
        jsr render_step
render_timed_end                ; (a breakpoint: the step rendered)
        sec                     ; the timer counts down: start - now
        lda render_start
        sbc CIA2_TA_LO
        tax
        lda render_start+1
        sbc CIA2_TA_HI

        cmp render_max+1
        bcc _not
        bne _longer
        cpx render_max
        bcc _not
_longer sta render_max+1
        stx render_max
        lda render_step_was
        sta render_max_step
        lda render_step_was+1
        sta render_max_step+1
        pla
        sta render_max_when+1
        pla
        sta render_max_when
        rts
_not    pla
        pla
        rts

; -----------------------------------------------------------------------------
; test_measure - (TEST_PLAY) at a due tick: the most ticks ever due and not
; yet rendered (the renderer behind), and the transmit ring's fullest.
; -----------------------------------------------------------------------------
test_measure
        jsr ticks_lead
        bcs _ring               ; (not behind: fine)
        sec                     ; behind: play_tick - ren_tick, 255 at most
        lda play_tick
        sbc ren_tick
        tax
        lda play_tick+1
        sbc ren_tick+1
        beq +
        ldx #$ff
+       cpx behind_max
        bcc _ring
        stx behind_max
        lda play_tick
        sta behind_when
_ring   sec                     ; the ring's fill
        lda out_next
        sbc tx_tail
        cmp ring_fill_max
        bcc +
        sta ring_fill_max
+       rts
.endif

; =============================================================================
; Tests: the log, the bursts
; =============================================================================
.if TEST_LOG
; Two logs, so that each has one writer: log A the timer interrupt's (the
; ticks; the releases, written with interrupts off), log B the transmit
; hook's (every byte written to the ACIA): on an NMI interface (Namesoft)
; the transmit hook is an NMI, which could come in the middle of a log A
; entry. Each log is five arrays of LOG_PAGES pages, one byte of each entry
; in each (its kind, its value, and the time's three bytes), so an entry
; costs ~60 cycles. The time: CIA2 timer A (a cycle a count) and timer B
; (counting timer A's wraps), both free running down: 24 bits, so the two
; logs line up (tools/timing_check.py merges them).
LOG_PAGES       = TEST_PLAY == 2 || TEST_PLAY == 4 || (TEST_KEYS >= 16 && TEST_KEYS <= 18) ? 6 : 7
                                ; entries a log: LOG_PAGES * (the list's key scripts too: their
                                ; builds hold the list's code, sid500.asm LIST_CODE)
                                ; 256 (2048 until stage E; the heavy scene's and half the
                                ; wire's builds 6 since stage F, the user: their pool from
                                ; the program's end needs the room; the others' runs need
                                ; the 7)
LOG_START       = LOG_END_AT - 10 * LOG_PAGES * $100 ; above the test builds' smaller
LOG_END_AT      = $c000         ; pool (pool.asm), up to the core's RAM
LOG_ARRAY       = LOG_PAGES * $100
LOG_A           = LOG_START     ; log A's arrays: kinds, values, time low, middle, high
LOG_B           = LOG_START + 5 * LOG_ARRAY
LOG_END         = LOG_START + 10 * LOG_ARRAY
        .cerror LOG_END > $c000, "the test log runs into the core's RAM"
        .section late_tests     ; (the log's place for the tools: timing_check.py
log_layout                      ; log_layout finds it in the program)
        .byte $53, $49, $44, $35, $30, $30, $4c, $4f, $47 ; "SID500LOG" in ASCII
        .byte >LOG_START, LOG_PAGES
        .send
        .cerror POOL_END > LOG_START, "the pool runs into the test log"
STAMP_EVERY     = 8             ; TEST_STAMP_FEW 2: one byte in 8 stamped (not realtime ones)
LOG_TICK        = 1             ; entry kinds (0 = no entry): a player tick (value = the
                                ;   core's tick_count: the 250 Hz ticks so far, low byte)
LOG_TX          = 2             ;   a byte written to the ACIA (value = the byte)
LOG_RELEASE     = 3             ;   TEST_LOG_RELEASE: a tick released (value = its low byte)
LOG_PART        = 4             ;     a part of a tick in progress released
LOG_RENDERED    = 5             ;     a tick rendered (value = ren_tick after it)
LOG_STEP        = 6             ;     a render step begins (value = phase * 16 + pl_order)
LOG_RX          = 7             ;   TEST_SLAVE: a byte fed into MIDI in (value = the byte)
LOG_SLAVE       = 8             ;   TEST_SLAVE: a slave's timer interrupt (value = ticks due)
LOG_STACK       = 9             ;   the stack more than half used (value = the stack pointer)
LOG_LOCATE      = 10            ;   a stop's locate (value = transport.asm's LOCATE_*)
LOG_KEY         = 11            ;   a key read on the song screen (value = its code)
LOG_DRAWN       = 12            ;   a song screen row drawn (value: song.asm log_drawn)
LOG_SWITCH      = 13            ;   a live switch made: five entries (live.asm live_log:
                                ;   the track, the pattern, T's three bytes)
LOG_LIVE_MISS   = 14            ;   live.asm: the renderer got to T first (value = the track)
LOG_LIVE_CHANGE = 15            ;   TEST_LIVE: a cell changed, two entries (pl_music's low,
                                ;   middle byte)
LOG_PUBLISH     = 16            ;   live.asm live_publish: a pattern published, five entries
                                ;   (the pattern, pl_music's low and middle bytes, pl_order,
                                ;   play_state * 16 + stop_phase)
LOG_FREED       = 17            ;   live.asm live_free: replaced chains freed (value: how many)
LOG_REPREPARE   = 18            ;   transport.asm stop_reprepare: prepared again while stopped
LOG_CLICK       = 19            ;   click.asm: the metronome's click (1 a beat, 2 a bar's first)
LOG_CLICK_AT    = 20            ;     then its song tick, two entries (low, high)
                                ;   21: record.asm LOG_THRU_LOST
LOG_TX_THRU     = 22            ;   TEST_FEED_MASTER: a byte of thru's written to the ACIA
                                ;   23: record.asm LOG_MARKS_FULL
                                ;   24: record.asm LOG_RX_DONE
STACK_WARN      = $80           ; (the stack pointer below this: more than half used)
RTS_OPCODE      = $60           ; (a log writer's first byte when its log is full)

; -----------------------------------------------------------------------------
; log_init - (TEST_LOG) clear both logs (kind 0 = no entry), point their
; writers at their first pages, and start the time (time_init).
; -----------------------------------------------------------------------------
log_init
        ; clear the logs, a page at a time
        lda #>LOG_START
        sta _clear+2
        lda #0
        tay
_clear  sta LOG_START,y
        iny
        bne _clear
        inc _clear+2
        ldx _clear+2
        cpx #>LOG_END
        bne _clear
        jsr log_a_init
        jsr log_b_init
.if TEST_STAMP_FEW == 2
        lda #STAMP_EVERY
        sta stamp_countdown
.endif
        jmp time_init           ; the stamps' clock (player_init starts it again)

; -----------------------------------------------------------------------------
; log_writer - (macro;  = its name,  = its arrays) a log's writer:
; log_<name>_init points it at its first pages; log_<name> writes an entry: kind A, value log_<name>_value,
; the 24-bit time now (timer B's low byte, timer A's high and low bytes,
; read again until neither moved). The stores' high bytes are the arrays'
; current page (self-modified); a full log keeps its entries (the writer's
; first byte becomes RTS). One writer a log, never re-entered.
; clobbers A, X; preserves Y
; -----------------------------------------------------------------------------
log_writer .segment
        .section zp
log_\1_index .byte ?         ; the next entry within the page
log_\1_pages .byte ?         ; pages not yet started
log_\1_value .byte ?         ; the entry's value
log_\1_top   .byte ?         ; the time as first read: timer B
log_\1_mid   .byte ?         ;   and timer A's high byte
        .send

log_\1_init
        lda #>(\2)
        sta log_\1_kind+2
        lda #>(\2 + LOG_ARRAY)
        sta log_\1_val+2
        lda #>(\2 + 2 * LOG_ARRAY)
        sta log_\1_lo+2
        lda #>(\2 + 3 * LOG_ARRAY)
        sta log_\1_hi+2
        lda #>(\2 + 4 * LOG_ARRAY)
        sta log_\1_tp+2
        lda #LOG_PAGES-1
        sta log_\1_pages
        lda #0
        sta log_\1_index
        rts

log_\1
.if TEST_LOG_FROM
        ldx play_tick+1         ; (tests: nothing logged before tick TEST_LOG_FROM)
        cpx #>TEST_LOG_FROM
        bcc _skip
        bne +
        ldx play_tick
        cpx #<TEST_LOG_FROM
        bcs +
_skip   rts
+
.endif
        ldx log_\1_index
log_\1_kind
        sta \2,x             ; (page patched)
        lda log_\1_value
log_\1_val
        sta \2,x
        ; the time: timer B, timer A's high byte, its low byte, then both
        ; again (a wrap between: once more)
-       lda CIA2_TB_LO
        sta log_\1_top
        lda CIA2_TA_HI
        sta log_\1_mid
        lda CIA2_TA_LO
log_\1_lo
        sta \2,x
        lda CIA2_TA_HI
        cmp log_\1_mid
        bne -
log_\1_hi
        sta \2,x
        lda CIA2_TB_LO
        cmp log_\1_top
        bne -
log_\1_tp
        sta \2,x
        inc log_\1_index
        beq +
        rts
        ; a page of each array full: the next ones, or the end
+       dec log_\1_pages
        bmi _full
        inc log_\1_kind+2
        inc log_\1_val+2
        inc log_\1_lo+2
        inc log_\1_hi+2
        inc log_\1_tp+2
        rts
_full   lda #RTS_OPCODE         ; the log is full: the writer returns at once
        sta log_\1
        rts
        .endsegment

        #log_writer a, LOG_A
        #log_writer b, LOG_B

; log_tick - (synth_timer, interrupts off) a tick: its entry in log A, with
; the core's tick_count (old CIAs lose some of timer B's interrupts:
; tools/timing_check.py counts them). keeps Y
log_tick
        lda tick_count
        sta log_a_value
        lda #LOG_TICK
        jmp log_a

.if TEST_LOG_RELEASE
; log_release - (tests) a tick released: an entry LOG_RELEASE in log A,
; its number's low byte, with interrupts off (the timer interrupt writes
; log A too, and release runs in the main loop as well). keeps Y
log_release
        lda #LOG_RELEASE
log_release_kind                ; (A = the kind: LOG_PART, LOG_RENDERED log ren_tick)
        php
        sei
        pha
        lda rel_tick
        sta log_a_value
        pla
        cmp #LOG_RENDERED
        bne +
        ldx ren_tick
        stx log_a_value
+       cmp #LOG_STEP
        bne +
        pha
        lda render_phase        ; (a step: its phase * 16 + its place in ACTIVE)
        asl
        asl
        asl
        asl
        ora pl_order
        sta log_a_value
        pla
+       jsr log_a
        plp
        rts
.endif

; -----------------------------------------------------------------------------
; synth_tx_byte - core hook (MIDI_TX_HOOK): byte A is being written to the
; ACIA: logged with its time. Keeps A; clobbers X.
; -----------------------------------------------------------------------------
synth_tx_byte
.if THRU_MARK
        cmp #MIDI_CLOCK         ; (X: the byte's place in the ring, if not realtime)
        bcs +
        jsr thru_marked         ; thru's (record.asm): always stamped, apart
        bcc +
        sta log_b_value
        lda #LOG_TX_THRU
        jsr log_b
        lda log_b_value
        rts
+
.endif
.if TEST_STAMP_FEW == 3
        cmp #MIDI_CLOCK         ; only the realtime bytes stamped
        bcs +
        rts
+
.elsif TEST_STAMP_FEW == 2
        cmp #MIDI_CLOCK         ; realtime bytes all stamped,
        bcs +
        dec stamp_countdown     ; the others one in STAMP_EVERY
        beq _every
        rts
_every  pha
        lda #STAMP_EVERY
        sta stamp_countdown
        pla
+
.elsif TEST_STAMP_FEW
        cmp #$90                ; only a burst's first and last status bytes,
        beq +                   ; and the clocks between (they take wire time too)
        cmp #$90+15
        beq +
        cmp #MIDI_CLOCK
        beq +
        rts
+
.endif
        sta log_b_value
        lda #LOG_TX
        jsr log_b
        lda log_b_value
        rts
.endif

.if TEST_BURST
BURST_EVERY     = 50            ; main-loop ticks between bursts (200 ms)
BURST_NOTE      = 60            ; the bursts' note and velocity
BURST_VELOCITY  = 100
        .cerror TEST_BURST > 16, "TEST_BURST: up to 16 messages, one per channel"

; -----------------------------------------------------------------------------
; burst_tick - (TEST_BURST) from synth_tick: every BURST_EVERY ticks queue
; TEST_BURST note messages at once, on channels 1, 2, ..., each with its
; status byte (no running status): note ons, then at the next burst their
; note offs (note on, velocity 0). Loads the wire as many tracks with a
; note on one tick (design 4) do, with the player's clock going out meanwhile.
; Queued whole, then published and sent at once (out_go), as the player
; will a tick's messages.
; -----------------------------------------------------------------------------
burst_tick
        dec burst_countdown
        bpl _done
        lda #BURST_EVERY-1
        sta burst_countdown
        ; note ons after offs, offs after ons (the first: ons)
        lda burst_velocity
        eor #BURST_VELOCITY
        sta burst_velocity
        ; the burst, channel 1 first, queued whole, then published at once
        ; (as the player does a tick's). Without sei: in these builds no
        ; track plays, so the player never publishes the ring meanwhile
        ldy #0
-       tya
        ora #$90                ; note on, channel Y+1
        jsr out_byte
        lda #BURST_NOTE
        jsr out_byte
        lda burst_velocity
        jsr out_byte
        iny
        cpy #TEST_BURST
        bne -
        jmp out_go
_done   rts
.endif
