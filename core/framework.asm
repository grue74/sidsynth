; core/framework.asm - zero page, RAM map, start-up, main loop, interrupts
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; ticks between keyboard/paddle scans: 62.5 Hz at any tick rate, so key
; repeat and paddle timing (counted in scans) stay the same
SCAN_EVERY      = TICK_HZ * 2 / 125     ; 4 at 250 Hz, 8 at 500 Hz
        .cerror TICK_HZ * 2 != SCAN_EVERY * 125, "TICK_HZ must be a multiple of 62.5"
        .cerror SCAN_EVERY > 255, "TICK_HZ too high for the scan countdown"

; -----------------------------------------------------------------------------
; Zero page variables ($02-$FF are free: KERNAL and BASIC are not used)
; -----------------------------------------------------------------------------
        .virtual $02
; framework: interrupt counter, main loop, scratch, parameter state
tick_count      .byte ?         ; +1 per CIA timer IRQ (250 Hz)
tick_done       .byte ?         ; ticks already processed
scan_countdown  .byte ?         ; ticks until the next keyboard/paddle scan
ptr             .word ?         ; screen pointer
cptr            .word ?         ; colour RAM pointer
tmp             .byte ?
tmp2            .byte ?
sel_param       .byte ?         ; parameter the F-keys edit
learn_mode      .byte ?         ; nonzero: the next controller or paddle moved gets sel_param
params          .fill NUM_PARAMS ; parameter values, see param_* tables
; every module's own variables ('.section zp' blocks), in include order
        .dsection zp
zp_end
        .endv
        .cerror zp_end > $100, "zero page overflow"

; RAM areas outside zero page
rx_buffer       = $c000         ; 256-byte MIDI receive ring (IRQ/NMI write, main loop reads)
key_note        = $c100         ; 64 bytes: MIDI note each key started (so release matches)
; $C140-$C1FF: free for the synth
cc_map          = $c200         ; 128 bytes: parameter each MIDI controller sets, $FF = none
.if MIDI_OUT
tx_buffer       = $c300         ; 256-byte MIDI transmit ring (midi_send writes, IRQ/NMI send)
.endif

; =============================================================================
; BASIC stub: 2026 SYS 2061
; =============================================================================
        * = $0801
        .word basic_end, 2026
        .byte $9e
        .text format("%d", start)
        .byte 0
basic_end
        .word 0

; start_body - (segment) start-up after the machine's setup: the interrupt
; handlers, the timers, the variables, the synth, the screen, MIDI
start_body .segment

        ; our own interrupt handlers on the hardware vectors
        lda #<irq_handler
        sta VEC_IRQ
        lda #>irq_handler
        sta VEC_IRQ+1
        lda #<nmi_handler
        sta VEC_NMI
        lda #>nmi_handler
        sta VEC_NMI+1

        ; silence every interrupt source, then acknowledge anything pending
        lda #$7f
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR
        lda #0
        sta VIC_IRQ_MASK
        lda #$ff
        sta VIC_IRQ_FLAG

        ; CIA1: port A drives keyboard columns / paddle mux, port B reads rows
        lda #$ff
        sta CIA1_DDRA
        lda #$00
        sta CIA1_DDRB

.if SYNTH_TIMER
        ; CIA1 timer B = synth tick, continuous, interrupting (timer A is
        ; the synth's own: synth_init sets it up)
        lda #<TICK_LATCH
        sta CIA1_TB_LO
        lda #>TICK_LATCH
        sta CIA1_TB_HI
        lda #%00010001          ; force latch load, start, continuous, counting cycles
        sta CIA1_CRB
        lda #%10000010          ; enable timer B interrupt
        sta CIA1_ICR
.else
        ; CIA1 timer A = synth tick, continuous, interrupting
        lda #<TICK_LATCH
        sta CIA1_TA_LO
        lda #>TICK_LATCH
        sta CIA1_TA_HI
        lda #%00010001          ; force latch load, start, continuous mode
        sta CIA1_CRA
        lda #%10000001          ; enable timer A interrupt
        sta CIA1_ICR
.endif

        .cerror TICK_LATCH != round(985248.0 / TICK_HZ) - 1, "TICK_LATCH (tables.py) doesn't match TICK_HZ"
.if MIDI_SYSEX
        jsr sysex_init          ; (first: a test feed lies where the test logs go)
.endif
        jsr init_vars
        jsr synth_init          ; the synth's own state and SID setup
        jsr screen_init
        jsr midi_init           ; programs the default interface, ends with cli
        cli
        .endsegment

; =============================================================================
; start - one-time setup, then the main loop. Never returns.
; =============================================================================
start
        ; machine: no ROMs, no interrupts until everything is in place
        sei
        cld
.if KERNAL_ZP_COPY
        ; the KERNAL's zero page as BASIC's SYS left it, before ours goes
        ; over it: a synth that calls the KERNAL later (disk) puts it back
        ldx #2
-       lda $00,x
        sta KERNAL_ZP_COPY,x
        inx
        bne -
.endif
        ldx #$ff
        txs
        lda #RAM_IO
        sta CPU_PORT
.if START_COPY
        jsr synth_start_copy    ; (the synth's section init_code where it runs)
        jmp start_rest
        .section init_code
start_rest
        #start_body
        jmp main_loop
        .send
.else
        #start_body
.endif

; -----------------------------------------------------------------------------
; main_loop - everything except receiving MIDI bytes runs here.
; Order of priority: incoming MIDI, synth ticks, keyboard/paddles, screen.
; The interrupt handlers stay tiny so the ACIA never overruns (a MIDI byte
; arrives every ~315 cycles at full speed).
; -----------------------------------------------------------------------------
main_loop
        jsr midi_process        ; drain the receive ring buffer

        ; one synth tick per timer interrupt; catch up if we fell behind
        lda tick_count
        cmp tick_done
        beq _idle
        inc tick_done
.if TEST_MIDI
        jsr test_feed
.endif
.if TEST_SYSEX
        jsr test_sysex_tick     ; (the feed, the capture's pacing)
.endif
.if MIDI_SYSEX
sx_tick_op      = *             ; (not a label: _idle stays main_loop's)
        bit sx_skip_tick        ; a dump's data coming in (~12 bytes a tick): sysex.asm
                                ; makes this "jmp": the synth went quiet at
                                ; synth_sysex_begin, its ticks are skipped
.endif
        jsr synth_tick

        ; every SCAN_EVERY ticks read paddles and keyboard
        dec scan_countdown
        bne main_loop
        lda #SCAN_EVERY
        sta scan_countdown
        jsr paddles_read        ; must come first: the scan moves the paddle mux
.if MIDI_POLL_SCAN
        jsr midi_process        ; (MIDI between the scan's pieces: a note waits less)
.endif
        jsr keyboard_scan
.if MIDI_POLL_SCAN
        jsr midi_process
.endif
        jsr screen_draw_step    ; at least one row per scan, even when busy
        jmp main_loop

        ; nothing urgent: redraw one screen row
_idle
.if MIDI_SYSEX
sx_pump_op      = *
        bit sysex_pump          ; a dump going out: sysex_send makes this "jsr". Only
                                ; here, with no tick due: packing ~12 bytes a tick
                                ; doesn't fit beside a busy tick, so then it goes slower
.endif
        jsr screen_draw_step
        jmp main_loop

; =============================================================================
; Interrupt handlers
; =============================================================================

; -----------------------------------------------------------------------------
; irq_handler - CIA1 timer tick, or a MIDI byte on IRQ-type interfaces
; (with MIDI_OUT also: the ACIA can take the next byte to send).
; The CIA is checked first: only when the CIA did NOT interrupt do we touch
; the ACIA, so open bus at $DE00 with no cartridge can never inject junk.
; If both interrupted, the IRQ line is still low after rti and we come
; straight back for the ACIA. Preserves all registers (and with IRQ_IO_IN
; $01: I/O is in while it runs).
; With SYNTH_TIMER the tick is timer B, and timer A calls synth_timer (with
; interrupts off and the CIA acknowledged; it saves the registers it uses
; but A, and may allow interrupts again).
; -----------------------------------------------------------------------------
irq_handler
        pha
.if IRQ_IO_IN
        ; I/O in, whatever the interrupted code had banked: it may be
        ; reading the RAM under I/O ($01 kept on the stack, put back on exit)
        lda CPU_PORT
        pha
        lda #RAM_IO
        sta CPU_PORT
.endif
        lda CIA1_ICR            ; reading acknowledges the CIA
        lsr                     ; timer A flag -> carry
.if SYNTH_TIMER
        bcs _synth_timer
        lsr                     ; timer B flag (the tick) -> carry
.endif
        bcc _not_timer
        inc tick_count
.if IRQ_IO_IN
        pla
        sta CPU_PORT
.endif
        pla
        rti

.if SYNTH_TIMER
        ; timer A: the synth's (the tick first, if timer B ran out too:
        ; the one read acknowledged both)
_synth_timer
        lsr                     ; timer B flag -> carry
        bcc +
        inc tick_count
+       jsr synth_timer
        jmp _exit
.endif

_not_timer
.if TEST_RX_FEED
        ; tests: the VIC's raster interrupt stands in for a byte received,
        ; which then takes the ACIA byte's path (the synth's test_rx_feed
        ; schedules the next one: carry set = A is a byte in; it may
        ; clobber A and X)
        lda VIC_IRQ_FLAG
        lsr                     ; raster flag -> carry
        bcc _no_feed
        lda #1
        sta VIC_IRQ_FLAG        ; acknowledged
        txa
        pha
        jsr test_rx_feed
        bcs _rx_byte
        jmp _restore
_no_feed
.endif
        lda midi_irq_mode
        beq _exit
        txa
        pha
irq_acia_status = *+1           ; operand low byte patched by midi_init
        lda $de02
        bpl _restore            ; bit 7 clear: the ACIA isn't interrupting
        lsr                     ; RDRF -> carry
irq_acia_data = *+1             ; operand low byte patched by midi_init
        lda $de03               ; reading data clears the ACIA interrupt (lda keeps carry)
.if MIDI_OUT
        bcc _tx                 ; no byte (overrun/DCD, or transmit): just cleared it
.else
        bcc _restore            ; no byte (overrun/DCD): just cleared it
.endif
_rx_byte                        ; (TEST_RX_FEED: a test byte joins here, A = the byte)
.if MIDI_RT_IRQ
        ; realtime ($F8-$FF: clock, start, stop): the synth's at once, not
        ; the ring's (synth_rt_irq: A = the byte; may clobber A and X only)
        cmp #$f8
        bcc _rx_store
        jsr synth_rt_irq
  .if MIDI_OUT
        jmp _tx                 ; (it may have queued a byte to pass on)
  .else
        jmp _restore
  .endif
_rx_store
.endif
        ldx rx_head
        sta rx_buffer,x
        inc rx_head             ; 256-byte ring wraps by itself
.if MIDI_RX_IRQ
        jsr synth_rx_irq        ; (then the synth's: A = the byte, kept; may clobber X; it
.endif                          ; may let interrupts in, the byte in the ring already)
.if MIDI_OUT
        ; MIDI out: the transmit register empty and a byte queued: send it;
        ; nothing queued: transmit interrupt off (midi_send turns it on)
_tx
irq_acia_status2 = *+1          ; patched by midi_init
        lda $de02
        and #ACIA_TDRE
        beq _restore
.if MIDI_URGENT
        ; the urgent queue (realtime bytes) goes before the ring
        ldx urgent_tail
        cpx urgent_head
        beq _tx_ring
        lda urgent_queue,x
        inx
        cpx #URGENT_SIZE
        bne +
        ldx #0                  ; (the queue wraps)
+       stx urgent_tail
        jmp _tx_send
_tx_ring
.endif
        ldx tx_tail
        cpx tx_head
        beq _tx_off
        lda tx_buffer,x
        inc tx_tail             ; 256-byte ring wraps by itself
_tx_send
.if MIDI_TX_HOOK
        jsr synth_tx_byte       ; (test builds: A = the byte, kept; may clobber X)
.endif
        ; the data write last: the 6850 moves an idle transmitter's byte
        ; on at once and is empty again, which on an NMI interface means a
        ; new NMI right here - it must find everything up to date
irq_acia_tx = *+1               ; patched by midi_init
        sta $de01
        jmp _restore
_tx_off
.if MIDI_URGENT
        ldx #0                  ; (midi_send_urgent turns it on again)
        stx tx_irq_on
.endif
        lda tx_ctrl_off
irq_acia_ctrl = *+1             ; patched by midi_init
        sta $de00
.endif
_restore
        pla
        tax
_exit
.if IRQ_IO_IN
        pla                     ; $01 as the interrupted code had it
        sta CPU_PORT
.endif
        pla
        rti

; -----------------------------------------------------------------------------
; nmi_handler - MIDI byte on NMI-type interfaces (Namesoft; with MIDI_OUT
; also the next byte to send). RESTORE also lands here; with no byte
; waiting it does nothing. Preserves all registers (and with IRQ_IO_IN
; $01). Only one of irq/nmi modes is ever on, so the ring buffers have one
; writer and one reader.
; -----------------------------------------------------------------------------
nmi_handler
        pha
.if IRQ_IO_IN
        ; I/O in, whatever the interrupted code had banked: it may be
        ; reading the RAM under I/O ($01 kept on the stack, put back on exit)
        lda CPU_PORT
        pha
        lda #RAM_IO
        sta CPU_PORT
.endif
        lda midi_nmi_mode
        beq _exit
        txa
        pha
nmi_acia_status = *+1           ; patched by midi_init
        lda $de02
        lsr                     ; RDRF -> carry
nmi_acia_data = *+1             ; patched by midi_init
        lda $de03
.if MIDI_OUT
        bcc _tx
.else
        bcc _restore
.endif
.if MIDI_RT_IRQ
        ; realtime ($F8-$FF: clock, start, stop): the synth's at once, not
        ; the ring's (synth_rt_irq: A = the byte; may clobber A and X only)
        cmp #$f8
        bcc _rx_store
        jsr synth_rt_irq
  .if MIDI_OUT
        jmp _tx                 ; (it may have queued a byte to pass on)
  .else
        jmp _restore
  .endif
_rx_store
.endif
        ldx rx_head
        sta rx_buffer,x
        inc rx_head             ; 256-byte ring wraps by itself
.if MIDI_RX_IRQ
        jsr synth_rx_irq        ; (then the synth's: A = the byte, kept; may clobber X; it
.endif                          ; may let interrupts in, the byte in the ring already)
.if MIDI_OUT
        ; MIDI out: the transmit register empty and a byte queued: send it;
        ; nothing queued: transmit interrupt off (midi_send turns it on)
_tx
nmi_acia_status2 = *+1          ; patched by midi_init
        lda $de02
        and #ACIA_TDRE
        beq _restore
.if MIDI_URGENT
        ; the urgent queue (realtime bytes) goes before the ring
        ldx urgent_tail
        cpx urgent_head
        beq _tx_ring
        lda urgent_queue,x
        inx
        cpx #URGENT_SIZE
        bne +
        ldx #0                  ; (the queue wraps)
+       stx urgent_tail
        jmp _tx_send
_tx_ring
.endif
        ldx tx_tail
        cpx tx_head
        beq _tx_off
        lda tx_buffer,x
        inc tx_tail             ; 256-byte ring wraps by itself
_tx_send
.if MIDI_TX_HOOK
        jsr synth_tx_byte       ; (test builds: A = the byte, kept; may clobber X)
.endif
        ; the data write last: the 6850 moves an idle transmitter's byte
        ; on at once and is empty again, which on an NMI interface means a
        ; new NMI right here - it must find everything up to date
nmi_acia_tx = *+1               ; patched by midi_init
        sta $de01
        jmp _restore
_tx_off
.if MIDI_URGENT
        ldx #0                  ; (midi_send_urgent turns it on again)
        stx tx_irq_on
.endif
        lda tx_ctrl_off
nmi_acia_ctrl = *+1             ; patched by midi_init
        sta $de00
.endif
_restore
        pla
        tax
_exit
.if IRQ_IO_IN
        pla                     ; $01 as the interrupted code had it
        sta CPU_PORT
.endif
        pla
        rti

; =============================================================================
; Setup
; =============================================================================

init_vars_routine .segment
; -----------------------------------------------------------------------------
; init_vars - clear all variables and load parameter defaults.
; -----------------------------------------------------------------------------
init_vars
        ; zero page variables and the RAM tables
        lda #0
.if zp_end - tick_count <= $80
        ldx #zp_end-tick_count-1 ; up to 128 bytes: count down while X >= 0
-       sta tick_count,x
        dex
        bpl -
.else
        ldx #0                  ; more than 128: bpl would stop after the first byte
-       sta tick_count,x
        inx
        cpx #zp_end-tick_count
        bne -
.endif
        ldx #63
-       sta key_note,x
        dex
        bpl -

        ; parameters
        ldx #NUM_PARAMS-1
-       lda param_default,x
        sta params,x
        dex
        bpl -

        ; controller map: none, then the default controllers
        lda #KEY_NONE
        ldx #127
-       sta cc_map,x
        dex
        bpl -
.if CC_COUNT > 0                ; a synth may have no default controllers
        ldy #CC_COUNT-1
-       ldx cc_numbers,y
        lda cc_params,y
        sta cc_map,x
        dey
        bpl -
.endif

        ; paddles: the synth's defaults until learnt otherwise
        lda #PAD_DEFAULT_X
        sta pad_param
        lda #PAD_DEFAULT_Y
        sta pad_param+1

        ; everything that isn't zero at start
        lda #SCAN_EVERY
        sta scan_countdown
        lda #KEY_NONE
        sta repeat_cmd
        ldx #OCTAVE_DEFAULT
        stx kb_octave
        lda kb_base_of_octave,x
        sta kb_base
        jsr paddles_reset
.if TEST_PADDLES
        lda #$ff                ; both stand-in paddles start as unplugged
        sta test_pot
        sta test_pot+1
.endif
.if TEST_MIDI
        jsr test_restart
.endif
.if TEST_RX_NOTES
        jsr test_rx_init        ; (test_feed.asm: notes through the receive interrupt)
.endif
.if TEST_KEYS
        lda #<test_key_script
        sta tk_ptr
        lda #>test_key_script
        sta tk_ptr+1
        lda test_key_script
        sta tk_hold
.endif
        rts
        .endsegment
.if START_COPY
        .section init_code
        #init_vars_routine
        .send
.else
        #init_vars_routine
.endif
