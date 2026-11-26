; core/test_keys.asm - scripted keyboard and paddles for the test builds
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
.if TEST_KEYS
tk_ptr          .word ?         ; test_keys_fill: current script entry
tk_hold         .byte ?         ; test_keys_fill: scans left for this entry
.endif
.if TEST_PADDLES
test_pot        .fill 2         ; stand-in pot readings [X, Y] (test_paddles_turn)
.endif
        .send

.if TEST_KEYS
; =============================================================================
; Scripted keyboard (assembled only with TEST_KEYS=1)
; =============================================================================

; -----------------------------------------------------------------------------
; test_keys_fill - stand-in for the matrix read: key_now = keys of the current
; script entry. Entry: scans to hold, key codes..., $FF. Hold 0 = end.
; -----------------------------------------------------------------------------
test_keys_fill
        lda #0
        ldx #7
-       sta key_now,x
        dex
        bpl -
        ldy #0
        lda (tk_ptr),y
        beq _done               ; script ended: no keys from now on
        lda tk_hold
        bne _apply

        ; entry used up: step past its key list to the next entry
-       iny
        lda (tk_ptr),y
        cmp #$ff
        bne -
        iny
        tya
        clc
        adc tk_ptr
        sta tk_ptr
        bcc +
        inc tk_ptr+1
+       ldy #0
        lda (tk_ptr),y
        beq _done
        sta tk_hold

        ; press this entry's keys
_apply  dec tk_hold
        ldy #1
-       lda (tk_ptr),y
        cmp #$ff
        beq _done
        pha
        lsr
        lsr
        lsr
        tax                     ; column
        pla
        and #7
        sty tmp
        tay
        lda _bit_mask,y
        ora key_now,x
        sta key_now,x
        ldy tmp
        iny
        bne -
_done   rts
_bit_mask .byte 1, 2, 4, 8, 16, 32, 64, 128

; key codes (column*8 + row) used by the script
TK_F1 = 4
TK_F3 = 5
TK_F5 = 6
TK_F7 = 3
TK_SHIFT = KEY_CODE_LSHIFT
TK_Z = 12
TK_X = 23
TK_C = 20
TK_STOP = 63
TK_RETURN = 1
TK_DEL = 0

tap     .macro                  ; press a key for 2 scans, release for 2
        .byte 2, \1, $ff, 2, $ff
        .endm
stap    .macro                  ; same with SHIFT
        .byte 2, TK_SHIFT, \1, $ff, 2, $ff
        .endm

.endif

.if TEST_PADDLES
; -----------------------------------------------------------------------------
; test_paddles_turn - stand-in paddles for TEST_PADDLES: paddle X turns
; clockwise by one step per scan, from the unplugged reading $FF down to 0,
; then stops; paddle Y stays unplugged. clobbers A
; -----------------------------------------------------------------------------
test_paddles_turn
        lda test_pot
        beq +
        dec test_pot
+       rts
.endif
