; hooks.asm - SID808's hooks called by the core
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The core calls: synth_init (sid808.asm), synth_tick (engine.asm),
; note_on, note_off, all_notes_off (voices.asm), and these three.

; -----------------------------------------------------------------------------
; synth_command - F7 on the parameter screen: back to the step grid
; (SHIFT+F7 = F8 is the core's all notes off).
; -----------------------------------------------------------------------------
synth_command
        jmp grid_take

; -----------------------------------------------------------------------------
; synth_param_changed - side effects of the synth's own parameters, from
; core param_changed. Y: the parameter that changed.
; -----------------------------------------------------------------------------
synth_param_changed
        cpy #P_VOLUME
        bne +
        jmp mode_vol_write
+       cpy #P_SOUND
        bne +
        lda params+P_SOUND      ; another sound: the page (and the grid cursor) follow
        jmp sound_select
+       cpy #P_TONE+1
        bcs +
        jmp knob_store          ; Level, Tune, Decay, Tone: the selected sound's knob
+       cpy #P_CLOCK
        bne +
        jmp clock_reset         ; the other clock from here on
+       rts

; -----------------------------------------------------------------------------
; synth_draw_status - the status row (ptr set to it by core draw_status):
; the sound on each voice, the last velocity, MIDI activity.
; -----------------------------------------------------------------------------
synth_draw_status
        ; fixed labels
        ldy #39
-       lda status_text,y
        sta (ptr),y
        dey
        bpl -

        ; each voice's sound name, 3 characters (the template shows --- when idle)
        ldx #NUM_VOICES-1
_voice  lda v_sound,x
        cmp #VOICE_IDLE
        beq _next
        sta tmp                 ; name offset = sound x 3
        asl
        adc tmp                 ; carry clear: sound < 128
        sta tmp
        lda status_voice_col,x
        tay
        stx tmp2
        ldx tmp
        lda sound_names,x
        sta (ptr),y
        iny
        lda sound_names+1,x
        sta (ptr),y
        iny
        lda sound_names+2,x
        sta (ptr),y
        ldx tmp2
_next   dex
        bpl _voice

        ; velocity of the last hit
        lda last_vel
        ldy #STATUS_VEL_COL
        jsr print_dec3

        ; CPU overload (overload_check): "CPU" reversed while late, "CPU!" when
        ; ticks are about to be lost
        lda load_warn
        beq _midi
        lda load_slip
        beq +
        ldy #STATUS_CPU_COL+3
        lda #'!'                ; (screen code = ASCII here)
        sta (ptr),y
+       ldy #STATUS_CPU_COL+3
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        dey
        cpy #STATUS_CPU_COL
        bcs -

        ; MIDI activity: reverse the label while bytes arrive
_midi   lda midi_led
        beq _done
        ldy #STATUS_MIDI_COL+3
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        dey
        cpy #STATUS_MIDI_COL
        bcs -
_done   rts
