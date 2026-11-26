; test_slave.asm - part of SID500 (TEST_SLAVE builds), included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A master's realtime bytes fed into MIDI in through the real receive
; interrupt (tools/slave_check.py): the VIC's raster interrupt stands in
; for the ACIA's (core option TEST_RX_FEED), and each byte takes the
; received byte's path in the core's irq_handler, synth_rt_irq included.
; The bytes and their spacing are tables.py's feed n (feed_bytes), timed
; in raster lines; each byte is logged (LOG_RX) with its real time.

RASTER_LINES    = 312           ; PAL: lines a frame, 63 cycles each
VIC_RASTER      = $d012         ; the raster compare line, low 8 bits (its 9th: VIC_CTRL1 bit 7)
FEED_ENTRY      = 3             ; feed_bytes: the byte, then the lines to the next (word)

        .section zp
feed_ptr        .word ?         ; the next entry of feed_bytes
        .send
        .section edit_vars      ; (under the KERNAL: the zero page is full in these builds)
feed_line       .word ?         ; the line its interrupt is set for
feed_skip       .byte ?         ; that line's interrupts to let pass first (whole frames)
feed_byte       .byte ?         ; (scratch)
feed_lines      .word ?         ; (scratch: the lines to the next byte)
.if TEST_SWITCH
switch_countdown .word ?        ; main-loop ticks until the Clock switches
.endif
        .send

; the feed's code goes with the feed (feed_data: copied into the step
; grid's table at start, unless recording: sid500.asm), out of the
; program's room, which the heavy scene's pool needs
        .section feed_data

; -----------------------------------------------------------------------------
; test_slave_init - from synth_init (interrupts off): the first byte's
; interrupt set (feed_first lines from line 0), the raster interrupt on.
; -----------------------------------------------------------------------------
test_slave_init
        lda #<feed_bytes
        sta feed_ptr
        lda #>feed_bytes
        sta feed_ptr+1
        lda #0
        sta feed_line
        sta feed_line+1
        lda #<feed_first
        sta feed_lines
        lda #>feed_first
        sta feed_lines+1
        jsr feed_schedule
.if TEST_SWITCH
        lda #<TEST_SWITCH
        sta switch_countdown
        lda #>TEST_SWITCH
        sta switch_countdown+1
.endif
        lda #1                  ; the raster interrupt on
        sta VIC_IRQ_MASK
        rts

; -----------------------------------------------------------------------------
; test_rx_feed - (core irq_handler, TEST_RX_FEED) the raster interrupt: if
; the feed's next byte is due, carry set and A = it, the next one's
; interrupt set and then the byte logged (its stamp as it goes in); else
; carry clear. May clobber A and X only.
; -----------------------------------------------------------------------------
test_rx_feed
        lda feed_skip
        beq _due
        dec feed_skip           ; a frame to let pass
        clc
        rts
_due    lda feed_ptr+1      ; (0: the feed has ended; the raster flag still
        bne +                   ; latches every frame, and another interrupt finds it)
        clc
        rts
+       tya
        pha
        ldy #0
        lda (feed_ptr),y
        sta feed_byte
        ldy #1
        lda (feed_ptr),y
        sta feed_lines
        iny
        lda (feed_ptr),y
        sta feed_lines+1
        ora feed_lines
        bne _next
        lda #0                  ; the last: the raster interrupt off, the feed ended
        sta VIC_IRQ_MASK
        sta feed_ptr+1
        beq _out
_next   clc
        lda feed_ptr
        adc #FEED_ENTRY
        sta feed_ptr
        bcc +
        inc feed_ptr+1
+       jsr feed_schedule
_out
.if !(TEST_FEED_MASTER && TEST_STAMP_FEW == 3) ; (not when timing the ticks: its cost)
        lda feed_byte           ; logged with its time, last: as it goes in
        sta log_a_value
        lda #LOG_RX
        jsr log_a
.endif
        pla
        tay
        lda feed_byte
        sec
        rts

; -----------------------------------------------------------------------------
; feed_schedule - the raster interrupt feed_lines after feed_line: its line
; (feed_line moves on, less whole frames) and how many of that line's
; interrupts pass first: one a frame, the first in this frame if the new
; line is still ahead in it.
; clobbers A, X
; -----------------------------------------------------------------------------
feed_schedule
        lda feed_line           ; (the old line, kept to compare)
        pha
        lda feed_line+1
        pha
        clc
        lda feed_line
        adc feed_lines
        sta feed_line
        lda feed_line+1
        adc feed_lines+1
        sta feed_line+1
        lda #0
        sta feed_skip
        ; whole frames off, each one more interrupt to let pass
-       lda feed_line+1
        cmp #>RASTER_LINES
        bcc _in_frame
        bne +
        lda feed_line
        cmp #<RASTER_LINES
        bcc _in_frame
+       sec
        lda feed_line
        sbc #<RASTER_LINES
        sta feed_line
        lda feed_line+1
        sbc #>RASTER_LINES
        sta feed_line+1
        inc feed_skip
        jmp -
_in_frame
        ; at or before the old line: the next frame's is the first (one less)
        pla
        cmp feed_line+1
        bcc _ahead              ; old high < new high
        bne _behind
        pla
        cmp feed_line
        bcc _set                ; old < new: ahead in this frame
        bcs _less
_ahead  pla
        jmp _set
_behind pla
_less   dec feed_skip
        ; the line: its 9th bit first, so the compare line between the
        ; two writes is ~256 lines from the raster (equal to the raster's
        ; line, it would interrupt at once)
_set    lda VIC_CTRL1
        and #$7f
        ldx feed_line+1         ; (the line's 9th bit into bit 7)
        beq +
        ora #$80
+       sta VIC_CTRL1
        lda feed_line
        sta VIC_RASTER
        rts

.if TEST_SWITCH
; -----------------------------------------------------------------------------
; test_switch - (TEST_SWITCH, from synth_tick) after TEST_SWITCH main-loop
; ticks, Clock to MIDI as the parameter screen would change it
; (synth_param_changed: player_restart).
; -----------------------------------------------------------------------------
test_switch
        lda switch_countdown
        ora switch_countdown+1
        beq _done               ; (switched already)
        lda switch_countdown
        bne +
        dec switch_countdown+1
+       dec switch_countdown
        lda switch_countdown
        ora switch_countdown+1
        bne _done
        lda #1
        sta params+P_CLOCK
        ldy #P_CLOCK
        jmp synth_param_changed
_done   rts
.endif

        .send                   ; (feed_data)

.if !(TEST_TAKE)
; -----------------------------------------------------------------------------
; feed_copy - (synth_init, after io_copy) the feed from its image after the
; program into FEED_RAM, whole pages (a little past its end: the table is
; free in these builds).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
FEED_PAGES      = (feed_ram_end - FEED_RAM + $ff) >> 8
feed_copy
        ldx #FEED_PAGES
        ldy #0
_page
_from = * + 1
-       lda feed_image,y
_to = * + 1
        sta FEED_RAM,y
        iny
        bne -
        inc _from+1
        inc _to+1
        dex
        bne _page
        rts
.endif
