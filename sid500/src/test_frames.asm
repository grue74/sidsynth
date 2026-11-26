; test_frames.asm - part of SID500 (TEST_FRAMES builds), included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A mark once a frame for tools/flash_check.py: the VIC's raster interrupt
; on line FRAME_LINE, just below the text (core TEST_RX_FEED's path, no
; byte fed), runs frame_mark, where VICE's binary monitor stops each frame
; to take the picture: the whole frame as the beam drew it.

FRAME_LINE      = 251           ; below the 25th text row (lines 51-250)
VIC_RASTER_LINE = $d012

; -----------------------------------------------------------------------------
; test_frames_init - from synth_init (interrupts off): the raster interrupt
; on, at FRAME_LINE every frame.
; -----------------------------------------------------------------------------
test_frames_init
        lda #FRAME_LINE
        sta VIC_RASTER_LINE
        lda VIC_CTRL1           ; (the compare line's 9th bit: 0, line 251 < 256)
        and #$7f
        sta VIC_CTRL1
        lda #1                  ; the raster interrupt on
        sta VIC_IRQ_MASK
        rts

; -----------------------------------------------------------------------------
; test_rx_feed - (core irq_handler, TEST_RX_FEED) the raster interrupt: the
; frame's mark; no byte (carry clear). frame_mark is the monitor's stop.
; -----------------------------------------------------------------------------
test_rx_feed
frame_mark
        clc
        rts
