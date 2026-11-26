; core/params.asm - parameter system: MIDI controllers, learn, value scaling, changes
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; -----------------------------------------------------------------------------
; midi_cc - control change. Controllers 0..119 set the parameter cc_map
; assigns them (value 0..127 scaled onto the parameter's 0..max range);
; 120/123 stop all notes, other channel mode messages are ignored.
; In learn mode the first controller 0..119 that arrives is assigned to the
; selected parameter (taking it from any other controller), then sets it.
; With PATTERN_CC that controller picks the pattern instead (synth_pattern,
; A = the value), before learn and cc_map: only on the synth's own channel,
; not in omni (one message must not switch every synth on the cable).
; -----------------------------------------------------------------------------
midi_cc
.if PATTERN_CC
        lda midi_data
        cmp #PATTERN_CC
        bne +
        lda params+P_CHANNEL    ; 0 = omni
        beq _ignore
        lda midi_data+1
        jmp synth_pattern
+
.endif
        lda midi_data
        cmp #120
        bcs _mode
        ldx learn_mode
        beq _lookup
        ldy sel_param
        cpy #LEARN_LIMIT        ; MIDI channel/interface and paddles can't be learnt
        bcs _lookup
        jsr cc_unassign         ; the parameter gets this controller only
        ldx midi_data
        tya
        sta cc_map,x
        lda #0
        sta learn_mode

_lookup ldx midi_data
        ldy cc_map,x
        bpl _found
        rts

_mode   cmp #120                ; all sound off
        beq _panic
        cmp #123                ; all notes off
        bne _ignore
_panic  jmp all_notes_off
_ignore rts

        ; stretch the value 0..127 to v = value*2 + value/64 (0..255)
_found  lda midi_data+1
        asl
        sta tmp                 ; value*2
        asl                     ; bit 6 of value -> carry
        lda tmp
        adc #0                  ; + value/64
        jmp param_set_v

; -----------------------------------------------------------------------------
; param_set_v - set parameter Y from a knob or paddle position v (0..255),
; scaled onto the parameter's range: result = v*(max+1)/256.
; Side effects (waveform etc. retrigger a sounding note) only when the value
; really changed, so a knob at rest costs nothing.
; A: v, Y: parameter. clobbers A, X, Y, tmp2
; -----------------------------------------------------------------------------
param_set_v
        ldx param_max,y
        cpx #255
        beq _store              ; full range: v is the value
        inx
        sty tmp2                ; mul8 clobbers Y
        jsr mul8                ; A = high byte of v*(max+1)
        ldy tmp2
_store  cmp params,y
        beq +
        sta params,y
        jmp param_changed
+       rts

; -----------------------------------------------------------------------------
; cc_unassign - remove every controller assignment of parameter Y.
; Preserves Y. clobbers A, X
; -----------------------------------------------------------------------------
cc_unassign
        ldx #127
-       tya
        cmp cc_map,x
        bne +
        lda #KEY_NONE
        sta cc_map,x
+       dex
        bpl -
        rts


; what the core expects of a synth's parameter list: the parameters
; controllers and paddles can't be learnt come last, from LEARN_LIMIT on
        .cerror P_CHANNEL < LEARN_LIMIT || P_MIDIIF < LEARN_LIMIT || P_PADDLES < LEARN_LIMIT, "MIDI channel, MIDI i/face and Paddles must not be learnable"
        .cerror LEARN_LIMIT > NUM_PARAMS, "LEARN_LIMIT beyond the parameter list"

; -----------------------------------------------------------------------------
; param_changed - side effects after parameter Y changed (keys, MIDI knob,
; paddle): the core's own parameters here, everything else in the synth's
; synth_param_changed hook, entered with Y = the parameter.
; -----------------------------------------------------------------------------
param_changed
        cpy #P_MIDIIF
        bne +
        jmp midi_init
+       cpy #P_PADDLES
        bne +
        jmp paddles_reset
+       cpy #P_CHANNEL
        bne +
        jmp all_notes_off
+       jmp synth_param_changed
