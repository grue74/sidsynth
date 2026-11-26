; core/paddles.asm - paddles with soft takeover and learn
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

PADDLE_DEADBAND = 3             ; paddle must move this much to take over
PAD_NONE        = $ff           ; pad_param: paddle controls nothing
PADDLES_OFF     = 2             ; P_PADDLES value: paddles ignored

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
pad_raw         .fill 2         ; last raw reading [X, Y]
pad_used        .fill 2         ; reading last applied to the parameter
pad_avg         .byte ?
pad_param       .fill 2         ; parameter paddle [X, Y] controls, PAD_NONE = none
pad_index       .byte ?         ; paddles_read: paddle being handled (0 = X, 1 = Y)
        .send

; =============================================================================
; Paddles
; =============================================================================

; -----------------------------------------------------------------------------
; paddles_read - read paddle X/Y of the selected port and apply each to the
; parameter in pad_param, with soft takeover: a parameter only follows a
; paddle once that paddle moves, so keys, MIDI CCs and an unplugged port
; (constant $FF) can't fight it. In learn mode the first paddle that moves
; becomes the selected parameter's paddle.
; The mux on CIA1 PA6/PA7 was set at the end of the previous keyboard scan,
; long enough ago (> 512 cycles) for the SID to have measured it.
; -----------------------------------------------------------------------------
paddles_read
        lda params+P_PADDLES
        cmp #PADDLES_OFF
        beq _done
.if TEST_PADDLES
        jsr test_paddles_turn
.endif
        ldx #1
_axis   stx pad_index
        lda pot_source,x
        tay
        clc
        adc pad_raw,x           ; average with the previous reading (jitter)
        ror                     ; 9-bit sum / 2
        sta pad_avg
        tya
        sta pad_raw,x

        ; |avg - used| >= deadband ?
        lda pad_avg
        sec
        sbc pad_used,x
        bcs +
        eor #$ff                ; negative: negate (carry clear -> +1)
        adc #1
+       cmp #PADDLE_DEADBAND
        bcc _next

        ; the paddle moved: it takes over
        lda pad_avg
        sta pad_used,x

        ; learn mode: this paddle now controls the selected parameter (only
        ; this paddle: the other one lets go of it), and learn mode ends
        lda learn_mode
        beq _apply
        ldy sel_param
        cpy #LEARN_LIMIT        ; MIDI channel/interface and paddles can't be learnt
        bcs _apply
        jsr pad_unassign
        tya
        sta pad_param,x
        lda #0
        sta learn_mode

        ; set the parameter; turning clockwise lowers the reading, so invert
_apply  ldy pad_param,x
        cpy #PAD_NONE
        beq _next
        lda pad_used,x
        eor #$ff
        jsr param_set_v         ; clobbers X: pad_index restores it
_next   ldx pad_index
        dex
        bpl _axis
_done   rts

; -----------------------------------------------------------------------------
; pad_unassign - neither paddle controls parameter Y any more.
; Preserves X, Y. clobbers A
; -----------------------------------------------------------------------------
pad_unassign
        tya
        cmp pad_param
        bne +
        lda #PAD_NONE
        sta pad_param
        tya
+       cmp pad_param+1
        bne +
        lda #PAD_NONE
        sta pad_param+1
+       rts

; -----------------------------------------------------------------------------
; paddles_reset - forget paddle history (start, or port changed). $FF is what
; an empty port reads, so an unplugged port never takes over.
; -----------------------------------------------------------------------------
paddles_reset
        lda #$ff
        sta pad_raw
        sta pad_raw+1
        sta pad_used
        sta pad_used+1
        rts

; where paddles_read reads the pots: the SID, or a stand-in in TEST_PADDLES
.if TEST_PADDLES
pot_source      = test_pot
.else
pot_source      = SID_POTX      ; SID_POTX, SID_POTX+1 = paddle X, Y
.endif

; CIA1 port A value that selects the paddle port, index = params[P_PADDLES]
; (PA6 = 1 selects port 1, PA7 = 1 selects port 2)
paddle_select   .byte %01111111, %10111111, %11111111
