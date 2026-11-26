; hooks.asm - SID101's hooks called by the core
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The core calls: synth_init (sid101.asm), synth_tick (engine.asm),
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
; Arpeggio: on or off (arp_param_changed). Clock: the other clock from
; here on. MIDI out turned off with a step's note sounding: its note off
; goes out first (the receiver must not keep it).
; Voice mode: voice 2's waveform and frequency change, the echo is cleared,
; the chord built again (C64 mode). Chord: the chord built again.
; A mix level turned to 0 or up from 0 changes which voices are gated; the
; levels themselves follow in levels_update (lowered at once; raised from
; the next note, as the SID can't raise a held voice's level).
; -----------------------------------------------------------------------------
synth_param_changed
        jsr preset_touched      ; a sound parameter: the preset is edited
        cpy #P_ARP
        bne +
        jmp arp_param_changed
+       cpy #P_CLOCK
        bne +
        jmp clock_reset
+       cpy #P_MIDIOUT
        bne +
        lda params+P_MIDIOUT
        bne _done
        lda seq_note
        cmp #NO_NOTE
        beq _done
        jmp out_note_off_now
+       cpy #P_VOICEMODE
        bne +
        lda #$ff                ; voice 2's frequency again (pitch_to_sid), its
        sta pitch_last+1        ; waveform and sync bit (gates_write), C64
        jsr echo_clear          ; mode's echo silent, its chord for the keys held
        jsr chord_build
        jmp gates_write
+       cpy #P_CHORD
        bne +
        jmp chord_build         ; the chord for the keys held
+       cpy #P_SAW
        bcc _done
        cpy #P_SUB+1
        bcs _done
        jmp gates_write         ; saw, pulse, sub: the gates as the levels say
_done   rts

; -----------------------------------------------------------------------------
; synth_draw_status - the status row (ptr set to it by core draw_status):
; octave, sounding note, velocity, glide, MIDI activity.
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
        ; gliding?
        lda note_glides
        beq _no_note
        ldx #0
        ldy #STATUS_GLIDE_COL
-       lda glide_text,x
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
