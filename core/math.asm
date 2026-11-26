; core/math.asm - 8x8 multiply, exponential envelope decay
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
mul_lo          .byte ?         ; mul8: product low byte
mul_a           .byte ?         ; mul8: first factor
mul_b           .byte ?         ; mul8: second factor
.if MATH_ENV
env_index       .byte ?         ; env_decay: which envelope
k_lo            .byte ?         ; env_decay: decay factor
k_hi            .byte ?
delta           .word ?         ; env_decay: amount removed this tick
.endif
        .send

.if MATH_SHIFT_MUL
; -----------------------------------------------------------------------------
; mul8 - (MATH_SHIFT_MUL) unsigned 8x8 -> 16 bit multiply by shifts and
; adds (~150 cycles, no tables): the multiplier (X) shifted out of mul_lo
; a bit at a time, the product shifted in from the top.
; A: factor, X: factor. Out: A = product high byte, mul_lo = low byte.
; clobbers X (mul_a, mul_b: the factors)
; -----------------------------------------------------------------------------
mul8
        sta mul_a
        stx mul_b
        stx mul_lo
        lda #0
        ldx #8
        lsr mul_lo              ; the multiplier's lowest bit into carry
-       bcc +
        clc
        adc mul_a               ; (a 1 bit: the multiplicand added)
+       ror a                   ; the product a bit down, its low bit into mul_lo
        ror mul_lo              ;   and the multiplier's next bit into carry
        dex
        bne -
        rts
.else
; -----------------------------------------------------------------------------
; mul8 - unsigned 8x8 -> 16 bit multiply by quarter squares (~45 cycles):
;   a*b = (a+b)^2/4 - (a-b)^2/4   (exact: a+b and a-b have the same parity)
; with sq_lo/sq_hi = floor(n^2/4) for n = 0..511 (tables.inc).
; A: factor, X: factor. Out: A = product high byte, mul_lo = low byte.
; clobbers X, Y
; -----------------------------------------------------------------------------
mul8
        sta mul_a
        stx mul_b
        ; Y = |a - b|
        sec
        sbc mul_b
        bcs +
        eor #$ff                ; negative: negate (carry clear -> +1)
        adc #1
+       tay
        ; X = low byte of a + b; carry = bit 8 picks the table half
        lda mul_a
        clc
        adc mul_b
        tax
        bcs _high
        sec
        lda sq_lo,x
        sbc sq_lo,y
        sta mul_lo
        lda sq_hi,x
        sbc sq_hi,y
        rts
_high   sec
        lda sq_lo+256,x
        sbc sq_lo,y
        sta mul_lo
        lda sq_hi+256,x
        sbc sq_hi,y
        rts
.endif


.if MATH_ENV
; -----------------------------------------------------------------------------
; env_decay - one exponential decay step: env -= env * k / 65536.
; X: envelope index, A/Y: factor k low/high. Uses only env_hi in the
; product, which is plenty precise. Reaches exactly 0.
; -----------------------------------------------------------------------------
env_decay
        sta k_lo
        sty k_hi
        stx env_index
        lda env_hi,x
        bne _decay
        sta env_lo,x            ; below 1/256: snap to 0
        rts

        ; delta = env_hi*k_hi + (env_hi*k_lo)/256
_decay  ldx k_lo
        jsr mul8
        sta tmp
        ldx env_index
        lda env_hi,x
        ldx k_hi
        jsr mul8
        sta delta+1
        lda mul_lo
        clc
        adc tmp
        sta delta
        bcc +
        inc delta+1
+       ora delta+1
        bne +
        inc delta               ; at least 1
+
        ; env -= delta, not below 0
        ldx env_index
        sec
        lda env_lo,x
        sbc delta
        sta env_lo,x
        lda env_hi,x
        sbc delta+1
        sta env_hi,x
        bcs +
        lda #0
        sta env_lo,x
        sta env_hi,x
+       rts
.endif
