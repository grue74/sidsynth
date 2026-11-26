; core/midi.asm - MIDI input (and with MIDI_OUT, output) through a 6850 ACIA cartridge
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; scans the MIDI indicator stays lit after a byte
MIDI_LED_TIME   = 8             ; scans the MIDI indicator stays lit

.if MIDI_URGENT
URGENT_SIZE     = 4             ; urgent queue: 3 realtime bytes can wait (a power of two)
        .cerror !MIDI_OUT, "MIDI_URGENT needs MIDI_OUT"
.endif
.if MIDI_TX_HOOK
        .cerror !MIDI_OUT, "MIDI_TX_HOOK needs MIDI_OUT"
.endif

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
rx_head         .byte ?         ; MIDI ring buffer write index (IRQ/NMI)
midi_irq_mode   .byte ?         ; 1 = ACIA interrupts on IRQ
midi_nmi_mode   .byte ?         ; 1 = ACIA interrupts on NMI
rx_tail         .byte ?         ; MIDI ring buffer read index
running_status  .byte ?         ; current channel status byte, 0 = none
midi_count      .byte ?         ; data bytes collected
midi_need       .byte ?         ; data bytes this message needs
midi_data       .fill 2
midi_if_active  .byte ?         ; interface midi_init programmed last (0 = none)
midi_led        .byte ?         ; scans left to show MIDI activity
bend            .word ?         ; pitch bend, signed, 256 = 1 semitone
.if MIDI_OUT
tx_head         .byte ?         ; MIDI transmit ring write index (midi_send)
tx_tail         .byte ?         ; MIDI transmit ring read index (IRQ/NMI handler)
tx_ctrl_on      .byte ?         ; ACIA control value: transmit interrupt on
tx_ctrl_off     .byte ?         ;                     and off (the value midi_init sets)
.endif
.if MIDI_URGENT
urgent_head     .byte ?         ; urgent queue write index (midi_send_urgent), 0..URGENT_SIZE-1
urgent_tail     .byte ?         ; urgent queue read index (the transmit handlers)
urgent_queue    .fill URGENT_SIZE ; realtime bytes waiting to go out before the ring
tx_irq_on       .byte ?         ; nonzero = the transmit interrupt is on (midi_send_urgent
                                ; sets it, the handlers clear it when nothing is left to send)
.endif
.if MIDI_SYSTEM
sys_status      .byte ?         ; the system message collecting data ($F2, $F3), 0 = none
.endif
        .send

MIDI_SONG_POSITION = $f2        ; system common: song position pointer (2 data bytes)
MIDI_SONG_SELECT   = $f3        ;                song select (1 data byte)

; =============================================================================
; MIDI input
; =============================================================================

; -----------------------------------------------------------------------------
; midi_init - (re)program the interface chosen in params[P_MIDIIF].
; Resets the previously active ACIA first so it can't keep interrupting while
; the handlers look at another address. Patches the handlers' ACIA addresses.
; Safe to call with interrupts on; restores the caller's interrupt flag.
; clobbers A, X, Y, ptr
; -----------------------------------------------------------------------------
midi_init
        php
        sei
        lda #0
        sta midi_irq_mode
        sta midi_nmi_mode
        lda #>$de00             ; every interface lives in page $DE
        sta ptr+1
        ldy #0

        ; step 1: master-reset the interface we used before (stops its IRQs)
        ldx midi_if_active
        beq _program
        lda if_ctrl,x
        sta ptr
        lda #ACIA_RESET
        sta (ptr),y

        ; step 2: patch the handlers and program the new interface
_program
        ldx params+P_MIDIIF
        stx midi_if_active
        beq _flush              ; "Off": nothing to program
        lda if_status,x
        sta irq_acia_status
        sta nmi_acia_status
        lda if_data,x
        sta irq_acia_data
        sta nmi_acia_data
.if MIDI_OUT
        ; the transmit side: status, data, control registers, control values
        lda if_status,x
        sta irq_acia_status2
        sta nmi_acia_status2
        lda if_tx,x
        sta irq_acia_tx
        sta nmi_acia_tx
        lda if_ctrl,x
        sta irq_acia_ctrl
        sta nmi_acia_ctrl
        sta send_acia_ctrl
.if MIDI_URGENT
        sta urgent_acia_ctrl
.endif
        lda if_control_value,x
        sta tx_ctrl_off
        ora #ACIA_TXIRQ
        sta tx_ctrl_on
.endif
        lda if_ctrl,x
        sta ptr
        lda #ACIA_RESET
        sta (ptr),y
        lda if_control_value,x
        sta (ptr),y
        lda if_data,x           ; discard a stale received byte
        sta ptr
        lda (ptr),y

        ; step 3: let the right handler service it
        lda if_irq_type,x
        cmp #IF_NMI
        beq _nmi
        lda #1
        sta midi_irq_mode
        bne _flush
_nmi    lda #1
        sta midi_nmi_mode

        ; step 4: forget half-received data (and unsent output)
_flush  lda rx_head
        sta rx_tail
.if MIDI_OUT
        lda tx_head
        sta tx_tail
.endif
        lda #0
        sta running_status
        sta midi_count
.if MIDI_URGENT
        sta urgent_head         ; the urgent queue empty, its interrupt counted off
        sta urgent_tail         ; (the reset above turned it off)
        sta tx_irq_on
.endif
        plp
        rts

; MIDI interface table, index = params[P_MIDIIF]; register addresses are the
; low bytes in page $DE (from VICE's c64-midi.c interface list)
IF_IRQ = 1
IF_NMI = 2
if_ctrl          .byte 0, $00, $08, $04, $00     ; Off, Sequential, Passport, Datel, Namesoft
if_status        .byte 0, $02, $08, $06, $02
if_data          .byte 0, $03, $09, $07, $03     ; receive data register
.if MIDI_OUT
if_tx            .byte 0, $01, $09, $05, $01     ; transmit data register
.endif
if_control_value .byte 0, ACIA_8N1_RXIRQ|ACIA_DIV16, ACIA_8N1_RXIRQ|ACIA_DIV16, ACIA_8N1_RXIRQ|ACIA_DIV64, ACIA_8N1_RXIRQ|ACIA_DIV16
if_irq_type      .byte 0, IF_IRQ, IF_IRQ, IF_IRQ, IF_NMI

.if MIDI_OUT
; -----------------------------------------------------------------------------
; midi_send - queue byte A for MIDI output and turn the ACIA's transmit
; interrupt on: the IRQ/NMI handler sends the queue at the wire's speed
; (320 us a byte) and turns it off when the queue is empty. Call from the
; main loop only (synth_tick included), never from an interrupt: the ring
; has one writer (here) and one reader (the handler); an interrupt between
; the queueing and the control write at worst finds the queue empty and
; turns the interrupt off before it is turned on again here. A full ring
; (256 bytes, ~80 ms of MIDI) drops the byte; with the interface Off
; nothing is queued.
; preserves A, Y; clobbers X
; -----------------------------------------------------------------------------
midi_send
        ldx midi_if_active
        beq _drop
        ldx tx_head
        inx
        cpx tx_tail
        beq _drop               ; full
        dex
        sta tx_buffer,x
        inc tx_head
        pha
        lda tx_ctrl_on
send_acia_ctrl = *+1            ; operand low byte patched by midi_init
        sta $de00               ; transmit interrupt on
        pla
_drop   rts
.endif

.if MIDI_URGENT
; -----------------------------------------------------------------------------
; midi_send_urgent - (MIDI_URGENT) queue realtime byte A (clock, start,
; stop, continue) to go out before everything in the transmit ring: the
; handlers send it at the next "transmit register empty", so it waits at
; most for the byte being shifted out and the one in the data register
; (MIDI lets a realtime byte go between any two bytes of a message).
; Callable from the main loop and from interrupts (the synth's timer, the
; receive hook passing clock on), but from one of them at a time: the
; queue has one writer. A full queue (3 bytes waiting, which the 3 byte
; times a byte waits can't fill at MIDI's own input rate) drops the byte.
; The control register is written only when the transmit interrupt is off:
; VICE restarts its byte timer at every control write, so writing it per
; byte would send faster than the wire.
; With the interface Off nothing is queued.
; clobbers A, X
; -----------------------------------------------------------------------------
midi_send_urgent
        ldx midi_if_active
        beq _done
        ; step 1: the byte into the queue, unless it is full
        ldx urgent_head
        sta urgent_queue,x
        inx
        txa
        and #URGENT_SIZE-1
        cmp urgent_tail
        beq _done               ; full: the byte is dropped
        sta urgent_head         ; (the handler sees the byte from here on)
        ; step 2: the transmit interrupt on, if the handlers turned it off.
        ; An interrupt between the test and the write finds the byte queued
        ; and sends it (and may turn the interrupt off before it is turned
        ; on here: then it comes once more, finds nothing and turns it off)
        lda tx_irq_on
        bne _done
        inc tx_irq_on
        lda tx_ctrl_on
urgent_acia_ctrl = *+1          ; operand low byte patched by midi_init
        sta $de00
_done   rts
.endif

; -----------------------------------------------------------------------------
; midi_process - feed every byte waiting in the ring buffer to the parser.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
midi_process
        ldx rx_tail
        cpx rx_head
        beq _done
        lda rx_buffer,x
        inc rx_tail
.if MIDI_SYSEX
midi_process_call = *+1         ; (sysex.asm points it at sx_fast while a dump's data comes)
.endif
        jsr midi_byte
        jmp midi_process
_done   rts

; -----------------------------------------------------------------------------
; midi_byte - MIDI parser, one byte at a time.
; A: received byte. Handles running status; realtime bytes ($F8-$FF, e.g.
; clock) never affect parsing, wherever they appear, even mid-message: they
; are dropped, or with MIDI_REALTIME = 1 handed to the synth's
; synth_realtime (A = the byte); system common and SysEx cancel running
; status so their data is ignored (with MIDI_SYSTEM, song position and song
; select collect theirs and go to the synth: midi_system).
; -----------------------------------------------------------------------------
midi_byte
        cmp #$f8
.if MIDI_REALTIME
        bcc +
        jmp synth_realtime      ; realtime: the synth's (no effect on parsing nor the LED)
+
.else
        bcs _ignore             ; realtime: no effect on parsing (nor the LED)
.endif
        ldx #MIDI_LED_TIME      ; light the activity indicator
        stx midi_led
        cmp #$80
        bcc _data
        cmp #$f0
        bcc _status
.if MIDI_SYSTEM
        jmp midi_system         ; system common / SysEx: messages of their own
.else
        lda #0                  ; system common / SysEx
        sta running_status
        rts
.endif

        ; channel status byte: start a new message
_status
.if MIDI_SYSTEM
        ldx #0
        stx sys_status          ; (it ends a system message still collecting)
.endif
.if MIDI_SYSEX
        stx sx_rx_state         ; (and a SysEx message)
.endif
        sta running_status
        ldx #0
        stx midi_count
        and #$e0                ; $Cx program change and $Dx channel pressure
        cmp #$c0                ; carry 1 data byte, the rest 2
        beq _one
        ldx #2
        .byte $2c               ; bit abs: skips the next 2-byte instruction
_one    ldx #1
        stx midi_need
        rts

        ; data byte: collect, dispatch when the message is complete
_data   ldx running_status
.if MIDI_SYSTEM
        bne +
        jmp midi_sysdata        ; no channel status: a system message's, or dropped
+
.else
        beq _ignore             ; data without status: drop
.endif
        ldx midi_count
        sta midi_data,x
        inx
        stx midi_count
        cpx midi_need
        bne _ignore
        lda #0                  ; running status: next data byte starts a new message
        sta midi_count
        jmp midi_dispatch
_ignore rts

.if MIDI_SYSTEM
; -----------------------------------------------------------------------------
; midi_system - (MIDI_SYSTEM) a system common or SysEx status byte, $F0-$F7:
; running status ends (the MIDI rule); song position and song select start
; collecting their data bytes (midi_sysdata), every other one is ignored
; with its data. With MIDI_SYSEX, F0 and F7 go to core/sysex.asm, and any
; other ends a SysEx message unfinished.
; A: the byte. clobbers A, X
; -----------------------------------------------------------------------------
midi_system
.if MIDI_SYSEX
        cmp #$f7                ; end of SysEx: a message of ours may be complete
        bne +
        ldx #0
        stx running_status
        stx midi_count
        stx sys_status
        jmp sysex_end
+       ldx #0
        stx sx_rx_state         ; any other: a SysEx message ends unfinished
.else
        ldx #0
.endif
        stx running_status
        stx midi_count
        stx sys_status
.if MIDI_SYSEX
        cmp #$f0                ; SysEx: maybe ours
        bne +
        jmp sysex_start
+
.endif
        ldx #2                  ; song position: 2 data bytes
        cmp #MIDI_SONG_POSITION
        beq _collect
        ldx #1                  ; song select: 1
        cmp #MIDI_SONG_SELECT
        bne _done
_collect
        sta sys_status
        stx midi_need
_done   rts

; -----------------------------------------------------------------------------
; midi_sysdata - (MIDI_SYSTEM) a data byte with no channel status: the next
; byte of the system message collecting (sys_status), else dropped. A
; complete message goes to the synth once (system messages have no running
; status): song position to synth_song_position (A = LSB, X = MSB), song
; select to synth_song_select (A = the song).
; A: the byte. clobbers A, X, Y (and what the synth's hook does)
; -----------------------------------------------------------------------------
midi_sysdata
.if MIDI_SYSEX
        ldx sx_rx_state         ; a SysEx message of ours may be coming
        beq +
        jmp sysex_byte
+
.endif
        ldx sys_status
        beq _drop
        ldx midi_count
        sta midi_data,x
        inx
        stx midi_count
        cpx midi_need
        bne _drop
        ldx sys_status
        lda #0
        sta sys_status
        sta midi_count
        lda midi_data
        cpx #MIDI_SONG_SELECT
        beq _select
        ldx midi_data+1
        jmp synth_song_position
_select jmp synth_song_select
_drop   rts
.endif

; -----------------------------------------------------------------------------
; midi_dispatch - act on a complete channel message in running_status and
; midi_data. Messages for other channels are ignored unless omni
; (OMNI_SKIP_DRUMS: in omni, notes on channel 10 are ignored too).
; -----------------------------------------------------------------------------
midi_dispatch
        ; channel filter: params[P_CHANNEL] 0 = omni, 1..16 = channel
        ldx params+P_CHANNEL
.if OMNI_SKIP_DRUMS
        bne _channel
        ; omni: note on/off on channel 10 ($99/$89) belongs to a drum machine
        lda running_status
        and #%11101111          ; $99 and $89 -> $89, no other status gives $89
        cmp #$89
        beq _done
        bne _omni               ; always
_channel
.else
        beq _omni
.endif
        dex
        txa
        eor running_status
        and #$0f
        bne _done

_omni   lda running_status
        and #$f0
        cmp #$90
        beq _note_on
        cmp #$80
        beq _note_off
        cmp #$b0
        beq _cc
        cmp #$e0
        beq _bend
.if MIDI_PROGRAM
        cmp #$c0
        beq _program
.endif
_done   rts
.if MIDI_PROGRAM
_program
        lda midi_data           ; the program, 0..127
        jmp synth_program
.endif

_note_on
        ldx midi_data+1         ; velocity 0 means note off
        beq _note_off
        lda midi_data
        jmp note_on
_note_off
        lda midi_data
        jmp note_off
_cc     jmp midi_cc

        ; pitch bend: 14-bit value -> signed +-2 semitones (+-512 pitch units)
_bend   lda midi_data+1         ; MSB, 7 bits
        lsr                     ; MSB bit 0 -> carry
        sta bend+1              ; value bits 8-13
        lda #0
        ror                     ; MSB bit 0 -> bit 7
        ora midi_data           ; LSB 7 bits
        sta bend
        lda bend+1              ; centre: subtract $2000
        sec
        sbc #$20
        sta bend+1
        ldx #4                  ; arithmetic shift right 4: +-8192 -> +-512
-       lda bend+1
        cmp #$80                ; carry = sign bit
        ror bend+1
        ror bend
        dex
        bne -
        rts

.if MIDI_SYSEX
        .include "sysex.asm"
.endif
