; core/keyboard.asm - keyboard matrix scan, key events, auto-repeat, commands
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

KB_VELOCITY     = 80            ; C64 keyboard note velocity (not accented)
KB_ACCENT_VEL   = 127           ; ... with SHIFT held (accented)
OCTAVE_MAX      = 6             ; keyboard octave 0..6, Z key = C of (octave+1)*12
OCTAVE_DEFAULT  = 2             ; Z = C2 (MIDI 36, 65 Hz)
REPEAT_DELAY    = 20            ; scans before a held value key repeats (~0.32 s)
REPEAT_RATE     = 3             ; scans between repeats (~20 per second)
REPEAT_SYNTH    = $1e           ; repeat_cmd: auto-repeat repeat_key through synth_key (SYNTH_SCREEN)

; keyboard commands (key_map values $40+): bit 5 = SHIFT selects cmd+1
CMD_PARAM_NEXT  = 0
CMD_PARAM_PREV  = 1
CMD_VALUE_UP    = 2
CMD_VALUE_DOWN  = 3
CMD_OCT_UP      = 4
CMD_OCT_DOWN    = 5
CMD_SYNTH       = 6             ; F7: the synth's own command (synth_command hook)
CMD_PANIC       = 7
CMD_LEARN       = 8             ; RETURN: MIDI learn on/off for the selected parameter
CMD_UNLEARN     = 9             ; DEL: remove the selected parameter's controller
CMD_MASK        = %00011111     ; key_map bits holding the command
KEY_NONE        = $ff
KEY_CMD         = $40           ; key_map: command
KEY_SHIFTABLE   = $20           ; key_map: SHIFT turns cmd into cmd+1
KEY_CODE_LSHIFT = 1*8+7         ; matrix position column*8 + row
KEY_CODE_RSHIFT = 6*8+4

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
key_now         .fill 8         ; matrix this scan, 1 = pressed, [column] bits = rows
key_prev        .fill 8         ; matrix last scan
col_mask        .byte ?         ; keyboard_scan: column being driven low
scan_col        .byte ?         ; keyboard_scan: column being compared
changed_bits    .byte ?         ; keyboard_scan: keys that changed in this column
now_bits        .byte ?         ; keyboard_scan: current state of this column
key_code        .byte ?         ; keyboard_scan: column*8+row of the key examined
bits_left       .byte ?
want_press      .byte ?         ; keyboard_scan pass: 0 = releases, 1 = presses
shift_held      .byte ?         ; nonzero while a SHIFT key is down
repeat_cmd      .byte ?         ; command auto-repeating, $FF = none
repeat_key      .byte ?         ; key code that started it
repeat_timer    .byte ?
kb_octave       .byte ?         ; keyboard octave 0..OCTAVE_MAX
kb_base         .byte ?         ; MIDI note of the Z key for kb_octave
        .send

; =============================================================================
; Keyboard
; =============================================================================

; -----------------------------------------------------------------------------
; keyboard_scan - read the whole 8x8 matrix, turn changes into key events
; (releases first, so a quick finger change doesn't count as a slide), and
; run auto-repeat. Leaves CIA1 port A on the paddle select value.
; -----------------------------------------------------------------------------
keyboard_scan
        ; step 1: read every column, key_now[col] bit row = 1 when pressed
.if TEST_KEYS
        jsr test_keys_fill
.else
        ldx #0
        lda #%11111110
        sta col_mask
_read   lda col_mask
        sta CIA1_PRA
-       lda CIA1_PRB
        cmp CIA1_PRB            ; re-read until stable (key bounce)
        bne -
        eor #$ff
        sta key_now,x
        sec
        rol col_mask            ; next column low, others high
        inx
        cpx #8
        bne _read
.endif
        ldx params+P_PADDLES
        lda paddle_select,x
        sta CIA1_PRA

        ; SHIFT state (left/shift lock or right)
        lda key_now+KEY_CODE_LSHIFT/8
        and #1 << (KEY_CODE_LSHIFT % 8)
        sta shift_held
        lda key_now+KEY_CODE_RSHIFT/8
        and #1 << (KEY_CODE_RSHIFT % 8)
        ora shift_held
        sta shift_held

        ; step 2: two passes over the changes, releases then presses
        lda #0
        sta want_press
_pass   lda #0
        sta scan_col
_column ldx scan_col
        lda key_now,x
        eor key_prev,x
        beq _next_col
        sta changed_bits
        lda key_now,x
        sta now_bits
        txa
        asl
        asl
        asl
        sta key_code            ; column*8 + row 0
        lda #8
        sta bits_left
_bit    lsr now_bits            ; carry = pressed
        lda #0
        rol
        lsr changed_bits
        bcc _next_bit           ; this key didn't change
        cmp want_press
        bne _next_bit           ; other pass
        lda key_code
        jsr key_event
_next_bit
        inc key_code
        dec bits_left
        bne _bit
_next_col
        inc scan_col
        lda scan_col
        cmp #8
        bne _column
        lda want_press
        bne _passes_done
        inc want_press
        bne _pass
_passes_done
        ldx #7
-       lda key_now,x
        sta key_prev,x
        dex
        bpl -

        ; step 3: auto-repeat the held value/selection key
        lda repeat_cmd
        bmi _no_repeat
        dec repeat_timer
        bne _no_repeat
        lda #REPEAT_RATE
        sta repeat_timer
        lda repeat_cmd
.if SYNTH_SCREEN
        cmp #REPEAT_SYNTH
        bne +
        lda repeat_key          ; the synth's key again (want_press is 1 here)
        jsr synth_key
        jmp _no_repeat
+
.endif
        jsr run_command
_no_repeat

        ; step 4: MIDI indicator countdown
        lda midi_led
        beq +
        dec midi_led
+       rts

; -----------------------------------------------------------------------------
; key_event - one key changed. A: key code (column*8+row), want_press: 1 =
; pressed, 0 = released.
; -----------------------------------------------------------------------------
key_event
        tax
.if SYNTH_SCREEN
        ; while the synth owns the screen its key handler sees keys first:
        ; synth_key, A = key code; carry set = used, then A nonzero = repeat
        lda screen_owner
        beq _core
        lda want_press
        bne +
        cpx repeat_key          ; released: stop its auto-repeat
        bne +
        lda #KEY_NONE
        sta repeat_cmd
+       txa
        pha
        jsr synth_key
        bcc _not_used
        tay                     ; used: auto-repeat it if asked (presses only)
        pla
        tax
        tya
        beq _done
        lda want_press
        beq _done
        stx repeat_key
        lda #REPEAT_SYNTH
        sta repeat_cmd
        lda #REPEAT_DELAY
        sta repeat_timer
        rts
_not_used
        pla
        tax
_core
.endif
.if PARAM_SYNTH_KEYS
        ; the parameter screen: the synth's synth_param_key sees the key first
        ; (A = key code, want_press); carry set = used. (Not keys the synth's
        ; own screen passed on.)
.if SYNTH_SCREEN
        lda screen_owner
        bne _param_keys_done
.endif
        txa
        pha
        jsr synth_param_key
        pla
        tax
        bcc _param_keys_done
        rts
_param_keys_done
.endif
        lda want_press
        beq _release

        ; ---- press ----
        lda key_map,x
        cmp #KEY_NONE
        beq _done
        cmp #KEY_CMD
        bcs _command
        ; note: remember which MIDI note this key plays, accent with SHIFT
        clc
        adc kb_base
        sta key_note,x
        ldx #KB_VELOCITY
        ldy shift_held
        beq +
        ldx #KB_ACCENT_VEL
+       jmp note_on

_command
        stx repeat_key
        tay
        and #KEY_SHIFTABLE
        beq +
        lda shift_held
        beq +
        iny                     ; SHIFT: the odd partner command
+       tya
        and #CMD_MASK
        cmp #CMD_OCT_UP         ; commands below this auto-repeat
        bcs +
        sta repeat_cmd
        ldy #REPEAT_DELAY
        sty repeat_timer
+       jmp run_command

        ; ---- release ----
_release
        cpx repeat_key          ; stop auto-repeat of this key
        bne +
        lda #KEY_NONE
        sta repeat_cmd
+       lda key_map,x
        cmp #KEY_CMD
        bcs _done               ; commands and unused keys
        lda key_note,x
        jmp note_off
_done   rts

; kb_base = MIDI note of the Z key: C of octave kb_octave+1 (Z = C2 at default)
kb_base_of_octave .byte 12, 24, 36, 48, 60, 72, 84

; -----------------------------------------------------------------------------
; run_command - perform a keyboard command. A: CMD_* value.
; -----------------------------------------------------------------------------
run_command
        asl
        tax
        lda _jump+1,x
        pha
        lda _jump,x
        pha
        rts                     ; jumps to the entry + 1
_jump   .word _next-1, _prev-1, _up-1, _down-1, _oct_up-1, _oct_down-1, synth_command-1, all_notes_off-1
        .word _learn-1, _unlearn-1

        ; learn on/off: while on, the next MIDI controller or paddle moved is
        ; assigned to the selected parameter (see midi_cc, paddles_read)
_learn  lda sel_param
        cmp #LEARN_LIMIT
        bcs +                   ; MIDI channel/interface, paddles: not learnable
        lda learn_mode
        eor #1
        sta learn_mode
+       rts

        ; remove the selected parameter's controller and paddle, end learn mode
_unlearn
        lda #0
        sta learn_mode
        ldy sel_param
        jsr pad_unassign
        jmp cc_unassign

_next   ldx sel_param
        inx
        cpx #NUM_PARAMS
        bcc +
        ldx #0
+       stx sel_param
        rts

_prev   ldx sel_param
        dex
        bpl +
        ldx #NUM_PARAMS-1
+       stx sel_param
        rts

        ; value up by the parameter's step, clamped to its maximum
_up     ldy sel_param
        lda params,y
        clc
        adc param_step,y
        bcs _at_max
        cmp param_max,y
        bcc _set
        beq _set
_at_max lda param_max,y
        jmp _set

        ; value down by the step, clamped to 0
_down   ldy sel_param
        lda params,y
        sec
        sbc param_step,y
        bcs _set
        lda #0

        ; store and apply side effects of the changed parameter (Y)
_set    cmp params,y
        beq _same
        sta params,y
        jmp param_changed
_same   rts

_oct_up ldx kb_octave
        cpx #OCTAVE_MAX
        bcs +
        inx
        bne _set_octave
_oct_down
        ldx kb_octave
        beq +
        dex
_set_octave
        stx kb_octave
        lda kb_base_of_octave,x
        sta kb_base
+       rts

