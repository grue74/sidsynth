; size.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The size pass (the user, 2026-11-24: the room for stage F from a smaller
; program first, then the note pool): tables computed instead of stored.
; All after the tables (late_code), so nothing before them moves: the two
; reads of slave_lead became same-size jsr's, and player_set_swing is a
; wrapper in player_set_swing_table's place (its table gone).

        .section late_code

; -----------------------------------------------------------------------------
; player_set_swing - (in player.asm player_set_swing_table's place) the row
; of passes for the Swing parameter, made (it was a table of 16 rows, 384
; bytes): the music's tick m plays at tick (m (12 + s) + 5) div 12 in a
; pair of 16ths' first half and at 12 + s + ((m - 12)(12 - s) + 5) div 12
; in its second (s: the delay in ticks, swing_ticks_tab; tables.py checks
; it gives swing_counts exactly). Made in the row not in use, then
; pl_swing_row pointed at it with interrupts off (the timer interrupt
; reads it every tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_set_swing
        ldx params+P_SWING
        lda swing_ticks_tab,x
        sta sws_s
        ldx #<swing_row_a       ; the row not in use: its address in the incs
        ldy #>swing_row_a
        lda pl_swing_row
        cmp #<swing_row_a
        bne +
        lda pl_swing_row+1
        cmp #>swing_row_a
        bne +
        ldx #<swing_row_b
        ldy #>swing_row_b
+       stx _inc+1
        sty _inc+2
        stx _clr+1
        sty _clr+2
        stx sws_at
        sty sws_at+1
        ldx #23                 ; cleared
        lda #0
_clr    sta swing_row_a,x       ; (patched)
        dex
        bpl _clr
        ; the first 16th: acc = m (12 + s) + 5, tick acc div 12
        lda #12
        clc
        adc sws_s
        sta sws_step
        lda #0
        sta sws_base
        jsr _half
        ; the second: acc = (m - 12)(12 - s) + 5, tick 12 + s + acc div 12
        lda #12
        sec
        sbc sws_s
        sta sws_step
        lda #12
        clc
        adc sws_s
        sta sws_base
        jsr _half
        php                     ; in use from now
        sei
        lda sws_at
        sta pl_swing_row
        lda sws_at+1
        sta pl_swing_row+1
        plp
        rts
; _half - twelve ticks of the music into the row from sws_base
_half   lda #5
        sta sws_acc
        ldy #12
-       lda sws_acc              ; the tick: acc div 12 (+ sws_base)
        ldx sws_base
        dex
        sec
_div    inx
        sbc #12
        bcs _div
_inc    inc swing_row_a,x       ; (patched)
        lda sws_acc
        clc
        adc sws_step
        sta sws_acc
        dey
        bne -
        rts

; the two rows (the one in use and the one made), the scratch
swing_row_a     .fill 24
swing_row_b     .fill 24
sws_s            .byte 0
sws_step         .byte 0
sws_base         .byte 0
sws_acc          .byte 0
sws_at           .word 0
swing_counts    = swing_row_a   ; (player_set_swing_table's, unused)

; -----------------------------------------------------------------------------
; slave_lead_x, slave_lead_y - (click.asm, slave.asm: in "lda slave_lead,x"
; and ",y"'s place) A = the render lead as slave for the master's tick
; period's high byte in X or Y: its table up to SLAVE_LEAD_TAB (tables.py:
; the lead is 1 past it), 1 past it. ~20 cycles (the clock's interrupt asks
; at every clock: a lead computed there made the clock's tick ~300 cycles
; later, slave_check.py). Keeps X and Y.
; -----------------------------------------------------------------------------
slave_lead_x
        cpx #SLAVE_LEAD_TAB
        bcs sl_one
        lda slave_lead_tab,x
        rts
slave_lead_y
        cpy #SLAVE_LEAD_TAB
        bcs sl_one
        lda slave_lead_tab,y
        rts
sl_one  lda #1
        rts

        .send

; -----------------------------------------------------------------------------
; The tempo computed (2026-11-24, the user: room for stage F from the code
; first): the timer's period and the render lead, which were four tables
; of 201 under I/O (804 bytes). tables.py checks the formula gives the
; tables exactly at every Tempo; TEST_TEMPO_ALL builds dump what this code
; computes for every Tempo (tools/tempo_check.py).
; -----------------------------------------------------------------------------

; the variables: after the scene's (main RAM, whatever $01 is)
        .virtual scene_vars_end
tempo_q         .fill 4         ; the period in 1/256 cycles: its fraction, the latch's low
                                ; and high bytes (the cycles - 1), 0
tempo_lead_new  .byte ?         ; the render lead in ticks
tempo_bpm       .byte ?         ; the divisor
size_vars_end
        .endv
        .cerror size_vars_end > $d000, "size.asm's variables run past $CFFF"

        .section hi_code        ; (under the KERNAL at $FF80: sid500.asm; RAM with
                                ; $01 = $35 too, so no switching)
; tempo_period - (player_init, player_set_tempo) tempo_q and tempo_lead_new
; for the Tempo parameter. The period: (TEMPO_DIVIDEND + BPM div 2) div
; BPM in 1/256 cycles (rounded: tables.py tempo_period_int), shift and
; subtract 32 times (~1,500 cycles, with interrupts on); less 256 (the
; latch is the cycles - 1). The lead: 1, and 1 more for each of
; tempo_lead_steps the Tempo has reached. clobbers A, X
tempo_period
        lda params+P_TEMPO      ; the dividend: TEMPO_DIVIDEND + BPM div 2
        clc
        adc #BPM_LOWEST
        sta tempo_bpm
        lsr a
        clc
        adc #<TEMPO_DIVIDEND
        sta tempo_q
        lda #>TEMPO_DIVIDEND
        adc #0
        sta tempo_q+1
        lda #(TEMPO_DIVIDEND >> 16) & $ff
        adc #0
        sta tempo_q+2
        lda #TEMPO_DIVIDEND >> 24
        adc #0
        sta tempo_q+3
        ldx #32                 ; divided by BPM: the quotient in tempo_q, the remainder
        lda #0                  ; in A (a 9th bit in carry after the rol)
-       asl tempo_q
        rol tempo_q+1
        rol tempo_q+2
        rol tempo_q+3
        rol a
        bcs _sub
        cmp tempo_bpm
        bcc +
_sub    sbc tempo_bpm           ; (carry set)
        inc tempo_q             ; (bit 0 was 0)
+       dex
        bne -
        lda tempo_q+1           ; the latch: the whole cycles - 1
        bne +
        dec tempo_q+2
+       dec tempo_q+1
        lda #1                  ; the lead
        sta tempo_lead_new
        lda params+P_TEMPO
        ldx #TEMPO_LEAD_STEPS-1
-       cmp tempo_lead_steps,x
        bcc +
        inc tempo_lead_new
+       dex
        bpl -
        rts
        .send
        .cerror TEMPO_DIVIDEND >= 1 << 29, "tempo_period_io: 32 shifts"

.if TEST_TEMPO_ALL
; tempo_dump - (tests: synth_init) tempo_period for every Tempo, 4 bytes
; each (tempo_q's fraction, latch low, latch high; tempo_lead_new) at
; TEMPO_DUMP, then TEMPO_DUMP_DONE; the Tempo as it was.
TEMPO_DUMP      = GRID_TABLE
TEMPO_COUNT     = BPM_HIGHEST - BPM_LOWEST + 1
TEMPO_DUMP_DONE = $a5
        .section late_code
tempo_dump
        lda params+P_TEMPO
        pha
        lda #<TEMPO_DUMP
        sta ptr
        lda #>TEMPO_DUMP
        sta ptr+1
        lda #0
        sta params+P_TEMPO
-       jsr tempo_period
        ldy #0
        lda tempo_q
        sta (ptr),y
        iny
        lda tempo_q+1
        sta (ptr),y
        iny
        lda tempo_q+2
        sta (ptr),y
        iny
        lda tempo_lead_new
        sta (ptr),y
        lda ptr
        clc
        adc #4
        sta ptr
        bcc +
        inc ptr+1
+       inc params+P_TEMPO
        lda params+P_TEMPO
        cmp #TEMPO_COUNT
        bne -
        pla
        sta params+P_TEMPO
        lda #TEMPO_DUMP_DONE
        ldy #0
        sta (ptr),y
        rts
        .send
.endif
