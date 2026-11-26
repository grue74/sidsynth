; core/test_feed.asm - TEST_MIDI pattern feeder
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
.if TEST_MIDI
test_ptr        .word ?         ; test_feed: next pattern entry
test_wait       .byte ?         ; test_feed: ticks until it is due
test_count      .byte ?
.endif
        .send

; =============================================================================
; Test pattern feeder (assembled only with TEST_MIDI=1)
; =============================================================================
.if TEST_MIDI
; -----------------------------------------------------------------------------
; test_feed - once per tick: when the current pattern entry is due, push its
; bytes into the MIDI ring buffer as if they had been received.
; Entry format: byte count (0 = end, restart), bytes..., ticks to the next.
; -----------------------------------------------------------------------------
test_feed
        lda test_wait
        beq _due
        dec test_wait
        rts
_due    ldy #0
        lda (test_ptr),y
        bne _bytes
        jmp test_restart
_bytes  sta test_count
-       iny
        lda (test_ptr),y
        sei                     ; the IRQ handler may write the ring too
        ldx rx_head
        sta rx_buffer,x
        inc rx_head
        cli
        dec test_count
        bne -
        iny
        lda (test_ptr),y
        sta test_wait
        iny
        tya
        clc
        adc test_ptr
        sta test_ptr
        bcc +
        inc test_ptr+1
+       rts

; test_restart - point test_feed at the start of the pattern
test_restart
        lda #<test_pattern
        sta test_ptr
        lda #>test_pattern
        sta test_ptr+1
        rts
.endif

; =============================================================================
; Notes through the receive interrupt (assembled only with TEST_RX_NOTES=1,
; with TEST_RX_FEED=1): the latency from MIDI in to the SID, measured from
; headless VICE's dump of every SID write (each synth as it is: nothing of
; its own needed).
; =============================================================================
.if TEST_RX_NOTES
TRX_BYTE_LINES  = 5             ; a byte every 5 raster lines (315 cycles: the wire's)
TRX_MARK        = $d41f         ; an unused SID register: the dump stamps the write
TRX_SETTLE      = 100           ; frames before the first note (start-up done)
TRX_LINE_MIN    = 16            ; a message's first byte between these raster lines
TRX_LINE_MAX    = 240           ;   (its last 10 lines on: within the line's low byte)
VIC_RASTER_LINE = $d012

; -----------------------------------------------------------------------------
; test_rx_init - (init_vars) the raster interrupt on, its line's 9th bit 0,
; the first message after TRX_SETTLE frames. clobbers A
; -----------------------------------------------------------------------------
test_rx_init
        lda VIC_CTRL1
        and #$7f
        sta VIC_CTRL1
        lda #TRX_LINE_MIN
        sta VIC_RASTER_LINE
        lda #TRX_SETTLE
        sta trx_wait
        lda #0
        sta trx_i
        lda #1
        sta VIC_IRQ_MASK        ; the raster interrupt on
        rts

; -----------------------------------------------------------------------------
; test_rx_feed - (core irq_handler, the raster interrupt) the next byte of
; the next message when due: carry set, A = the byte. After a message's
; last byte, TRX_MARK written (1: a note on, 2: its off; after an off the
; note changes between TEST_RX_NOTE and TEST_RX_NOTE2) and the next
; message TEST_RX_FRAMES frames on, at a raster line from an LFSR (so it
; falls anywhere in the synth's tick). clobbers A, X
; -----------------------------------------------------------------------------
test_rx_feed
        lda trx_wait
        beq _due
        dec trx_wait            ; (the same line next frame)
        clc
        rts
_due    ldx trx_i
        lda trx_msgs,x
        pha
        inx
        cpx #3
        beq _last
        cpx #6
        beq _last
        stx trx_i
        lda VIC_RASTER_LINE     ; the next byte a wire's byte on
        clc
        adc #TRX_BYTE_LINES
        sta VIC_RASTER_LINE
        pla
        sec
        rts
_last   cpx #6
        bne +
        lda trx_msgs+1          ; (after an off: the other note next)
        eor #TEST_RX_NOTE ^ TEST_RX_NOTE2
        sta trx_msgs+1
        sta trx_msgs+4
        ldx #0
+       stx trx_i
        txa                     ; the marker: 1 after the on (X 3), 2 after the off (X 0)
        beq +
        lda #1
        bne ++
+       lda #2
+       sta TRX_MARK
        lda #TEST_RX_FRAMES-1
        sta trx_wait
        lda trx_rand            ; the next message's line: an 8-bit LFSR
        asl
        bcc +
        eor #$1d
+       sta trx_rand
        cmp #TRX_LINE_MAX
        bcc +
        sbc #128
+       cmp #TRX_LINE_MIN
        bcs +
        adc #64
+       sta VIC_RASTER_LINE
        pla
        sec
        rts

trx_msgs        .byte $90 | TEST_RX_CHAN, TEST_RX_NOTE, TEST_RX_VEL
                .byte $80 | TEST_RX_CHAN, TEST_RX_NOTE, 0
trx_wait        .byte 0         ; frames until the next byte is due
trx_i           .byte 0         ; the next byte in trx_msgs
trx_rand        .byte $a7       ; the LFSR
.endif
