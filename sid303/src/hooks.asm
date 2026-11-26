; hooks.asm - SID303's hooks called by the core
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The core calls: synth_init (sid303.asm), synth_tick (engine.asm),
; note_on, note_off, all_notes_off (notes.asm), and these three.

; -----------------------------------------------------------------------------
; synth_command - F7 on the parameter screen: to the step screen
; (SHIFT+F7 = F8 is the core's all notes off).
; -----------------------------------------------------------------------------
synth_command
        jmp steps_take

; -----------------------------------------------------------------------------
; synth_param_changed - side effects of the synth's own parameters, from
; core param_changed. Y: the parameter that changed.
; A sound parameter marks the preset edited (presets.asm). Voice mix
; changed: retrigger a sounding note so no level has to rise.
; -----------------------------------------------------------------------------
synth_param_changed
        jsr preset_touched      ; a sound parameter: the preset is edited
        cpy #P_CLOCK
        bne +
        jmp clock_reset         ; the other clock from here on
+       cpy #P_MIDIOUT
        bne +
        lda params+P_MIDIOUT    ; MIDI out turned off: the receiver must not
        bne _done               ; keep the sequencer's note
        lda seq_note
        cmp #NO_NOTE
        beq _done
        jmp out_note_off_now
+       cpy #P_WAVE
        beq _remix
        cpy #P_BLEND
        beq _remix
        cpy #P_BODY
        bne _done
_remix  lda gate_bit
        beq _done
        jmp voices_retrigger
_done   rts

; -----------------------------------------------------------------------------
; synth_draw_status - the status row (ptr set to it by core draw_status):
; octave, sounding note, velocity, accent/slide, MIDI activity. On the
; parameter screen the title row's preset field too; a preset prompt or
; message takes the status row's place (presets.asm).
; -----------------------------------------------------------------------------
synth_draw_status
        lda screen_owner        ; the parameter screen: the title's preset
        bne +
        jsr draw_preset_title
+       jsr draw_preset_prompt  ; a preset prompt or message instead?
        bcc +
        rts
+
        ; fixed labels
        ldy #39
-       lda status_text,y
        sta (ptr),y
        dey
        bpl -

        ; keyboard octave digit
        lda kb_octave
        ora #CHAR_ZERO
        ldy #STATUS_OCT_COL
        sta (ptr),y

        ; sounding note name, or --- when silent
        ldx note_count
        beq _no_note
        lda note_stack-1,x
        ldx #CHAR_ZERO-1        ; octave = note/12 - 1
        sec
-       inx
        sbc #12
        bcs -
        adc #12                 ; A = note within octave
        asl
        tay
        lda note_names,y
        sta tmp
        lda note_names+1,y
        ldy #STATUS_NOTE_COL+1
        sta (ptr),y
        dey
        lda tmp
        sta (ptr),y
        txa
        sec
        sbc #1                  ; MIDI octave numbering: note 12 = C0
        ldy #STATUS_NOTE_COL+2
        sta (ptr),y
        ; accent and slide flags of the sounding note
        bit note_accent
        bpl +
        ldx #0
        ldy #STATUS_ACC_COL
-       lda acc_text,x
        sta (ptr),y
        iny
        inx
        cpx #3
        bne -
+       lda note_slid
        beq _no_note
        ldx #0
        ldy #STATUS_SLIDE_COL
-       lda slide_text,x
        sta (ptr),y
        iny
        inx
        cpx #5
        bne -

_no_note
        ; velocity of the last note on
        lda last_vel
        ldy #STATUS_VEL_COL
        jsr print_dec3

        ; MIDI activity: reverse the label while bytes arrive
        lda midi_led
        beq _done
        ldy #STATUS_MIDI_COL+3
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        dey
        cpy #STATUS_MIDI_COL
        bcs -
_done   rts
