; notes.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; zero-page variables (placed by .dsection zp in sid303.asm)
        .section zp
pitch_cur       .word ?         ; sounding pitch, hi = semitone (MIDI-12), lo = fraction
pitch_tgt       .word ?         ; pitch slid towards
gate_bit        .byte ?         ; GATE while a note sounds, else 0
note_accent     .byte ?         ; $80 if the sounding note is accented
note_level      .byte ?         ; base loudness of the sounding note 0..15 (15 - ACCENT/2)
note_gap        .byte ?         ; accented note: extra level on top, faded by ENV_ACCENT; else 0
acc_extra       .byte ?         ; levels_update: note_gap*17 * accent envelope, 0..255
amp8            .byte ?         ; levels_update: note loudness faded by ENV_AMP, 0..254
amp_level       .byte ?         ; levels_update: amp8 as a SID level 0..15
v3_level        .byte ?         ; voice 3 level last written; $FF = new note (no limit)
note_slid       .byte ?         ; 1 if the sounding note was reached by a slide
note_count      .byte ?         ; notes in note_stack
last_vel        .byte ?         ; velocity of the last note on (display)
.if TEST_LOG
log_ptr         .word ?         ; next free entry of the note log
log_tick        .word ?         ; +1 every synth tick
out_log_ptr     .word ?         ; next free entry of the MIDI out log
out_log_y       .byte ?         ; log_out: Y kept
.endif
        .send

.if TEST_LOG
; TEST_LOG: every note_on / note_off, 4 bytes each: tick (low, high), note,
; velocity (0 = note off). It fills NOTE_LOG..NOTE_LOG_END and then stops.
NOTE_LOG        = $6000
NOTE_LOG_END    = $7000
OUT_LOG         = $5000         ; every byte queued for MIDI out (out_byte): tick (low,
OUT_LOG_END     = $5ffc         ; high), the byte, 0; up to here
LOG_LAG         = NOTE_LOG - 1  ; the most ticks ever left waiting when a tick ran (tick_count -
                                ; tick_done in synth_tick): the logged ticks are ticks run,
                                ; so this shows when they fell behind the timer
.endif

; held-note stack in the synth's RAM area ($C140-$C1FF, see core/framework.asm)
note_stack      = $c140         ; STACK_SIZE bytes: held notes, last = newest

; =============================================================================
; Notes
; =============================================================================

; -----------------------------------------------------------------------------
; note_on - start a note, or slide to it if another note is still held.
; A: MIDI note, X: velocity (1..127). Velocity >= ACCENT_VELOCITY = accent.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
note_on
.if TEST_LOG
        jsr log_note
.endif
        stx last_vel
        jsr fold_note
        sta tmp2                ; folded note

        ; put the note on top of the held-note stack (once only)
        jsr stack_remove
        ldx note_count
        cpx #STACK_SIZE
        bcc _push
        dex                     ; full: newest replaces the top
_push   lda tmp2
        sta note_stack,x
        inx
        stx note_count

        ; target pitch = semitone index (note - 12), no fraction
        lda tmp2
        sec
        sbc #LOWEST_NOTE
        sta pitch_tgt+1
        lda #0
        sta pitch_tgt

        ; another note still held = legato = slide: no retrigger
        lda gate_bit
        beq _new_note
        lda #1
        sta note_slid
        rts

        ; fresh note: jump straight to the pitch
_new_note
        lda #0
        sta note_slid
        sta pitch_cur
        lda pitch_tgt+1
        sta pitch_cur+1

        ; accent decision. Every note has the base level 15 - ACCENT/2.
        ; An accented note adds note_gap = ACCENT/2 on top, scaled by the
        ; accent envelope: it starts at level 15 and falls back to the base
        ; level as the accent decays (the 303's accent also drives the VCA).
        lda params+P_ACCENT
        lsr
        tay                     ; Y = ACCENT/2
        eor #$0f
        sta note_level          ; 15 - ACCENT/2
        lda last_vel
        cmp #ACCENT_VELOCITY
        bcs _accent
        ldy #0                  ; normal note: no accent gap
        tya
        beq _set_accent
_accent lda #$ff                ; restart the accent envelope
        sta env_lo+ENV_ACCENT
        sta env_hi+ENV_ACCENT
        lda #$80
_set_accent
        sta note_accent
        sty note_gap

        ; restart the filter and amplitude envelopes
        lda #$ff
        sta env_lo+ENV_FILTER
        sta env_hi+ENV_FILTER
        sta env_lo+ENV_AMP
        sta env_hi+ENV_AMP
        ; the note's frequency before its gate opens: else the voices start
        ; at the last note's until the engine's next tick (0.4-3.4 ms, a
        ; blip; SID500 docs/latency.md, tools/synth_latency.py)
        jsr pitch_to_sid
        jmp voices_retrigger

; -----------------------------------------------------------------------------
; note_off - release a note. If other notes are still held and the released
; one was the newest, slide back to the newest remaining note; if none are
; held, close the gate.
; A: MIDI note. clobbers A, X, Y
; -----------------------------------------------------------------------------
note_off
.if TEST_LOG
        ldx #0                  ; (note_off clobbers X anyway)
        jsr log_note
.endif
        jsr fold_note
        jsr stack_remove
        bcc _done               ; not the sounding note: nothing audible changes
        ldx note_count
        beq note_gate_off
        lda note_stack-1,x      ; legato back to the newest held note
        sec
        sbc #LOWEST_NOTE
        sta pitch_tgt+1
        lda #0
        sta pitch_tgt
        lda #1
        sta note_slid
_done   rts

; note_gate_off - close the SID gates (all notes released)
note_gate_off
        lda #0
        sta gate_bit
        jmp gates_write

; -----------------------------------------------------------------------------
; voices_retrigger - restart the voices' SID envelopes: gates off, sustain
; levels for the current note, gates on (attack 0: no ADSR delay bug).
; Also used when a waveform/level parameter changes mid-note, because the
; SID can lower a sustain level during a note but never raise it.
; -----------------------------------------------------------------------------
voices_retrigger
        lda #0
        sta gate_bit
        jsr gates_write
        lda #$ff                ; new note: voice 3 level may start anywhere
        sta v3_level
        jsr levels_update
        lda #GATE
        sta gate_bit
        jmp gates_write

; -----------------------------------------------------------------------------
; gates_write - control registers of all voices from gate_bit, WAVE and BODY.
; Voice 2 sounds only in 303-square mode, voice 3 only with BODY > 0; their
; waveform bits stay set so voice 2 keeps syncing.
; clobbers A, X
; -----------------------------------------------------------------------------
gates_write
        ldx params+P_WAVE
        lda wave_bits,x
        ora gate_bit
        sta SID_V1_CTRL
        lda #V2_PULSE_SYNC
        cpx #WAVE_303SQ
        bne +
        ora gate_bit
+       sta SID_V2_CTRL
        lda #V3_TRIANGLE
        ldx params+P_BODY
        beq +
        ora gate_bit
+       sta SID_V3_CTRL
        rts

; -----------------------------------------------------------------------------
; levels_update - sustain level (= loudness) of each voice:
;   note    = note_level + note_gap * accent envelope  (the accent "pluck")
;   amp     = note * amplitude envelope            (the VCA fade)
;   voice 1 = amp, or amp * BLEND/15 in 303-square mode (the slanting saw)
;   voice 2 = amp                                   (the pulse)
;   voice 3 = amp * BODY/15 * body_res_scale[RESO] (the body triangle,
;             thinner at high resonance, as the 303 loses bass there)
; Worked on 8-bit levels (level*17) and cut to 4 bits only at the end.
; During a note these only fall (the envelopes only decay), which the SID
; follows by decaying to the lower level.
; clobbers A, X, Y, tmp
; -----------------------------------------------------------------------------
levels_update
        ; accent part: note_gap*17 * accent envelope / 256 (0 if not accented)
        lda note_gap
        beq +
        jsr times17
        ldx env_hi+ENV_ACCENT
        jsr mul8
+       sta acc_extra

        ; note loudness (8 bit) faded by the amplitude envelope
        lda note_level
        jsr times17             ; 0..255; plus acc_extra stays <= 255
        clc                     ; (note_level + note_gap = 15 at most)
        adc acc_extra
        ldx env_hi+ENV_AMP
        jsr mul8                ; A = loudness*env/256 = 0..254
        sta amp8
        lsr
        lsr
        lsr
        lsr
        sta amp_level

        ; voice 1
        ldx params+P_WAVE
        cpx #WAVE_303SQ
        bne +
        ldx params+P_BLEND
        jsr scale_level
+       jsr level_to_sr
        sta SID_V1_SR

        ; voice 2
        lda amp_level
        jsr level_to_sr
        sta SID_V2_SR

        ; voice 3: amp8 * body_res_scale[RESO]/256 * BODY*17/256, then 4 bits
        lda amp8
        ldy params+P_RESO
        beq +                   ; resonance 0: full level (the table's 255 would round down)
        ldx body_res_scale,y
        jsr mul8                ; A = amp8 thinned by resonance
+       pha
        lda params+P_BODY
        jsr times17
        tax
        pla
        jsr mul8                ; A = ... * BODY/15
        clc                     ; round to the nearest of 16 levels
        adc #8
        bcc +
        lda #$ff
+       lsr
        lsr
        lsr
        lsr
        ; never rise during a note: lowering RESO mid-note would raise the
        ; level, and a SID voice whose sustain is raised decays to silence
        cmp v3_level
        bcc +
        lda v3_level
+       sta v3_level
        jsr level_to_sr
        sta SID_V3_SR
        rts

; level_to_sr - A = sustain level 0..15 -> SR register (sustain in bits 4-7,
; release 0)
level_to_sr
        asl
        asl
        asl
        asl
        rts

; times17 - A = A * 17 for A = 0..15 (0..255: a 4-bit level spread to 8 bits)
times17
        sta tmp
        asl
        asl
        asl
        asl
        ora tmp
        rts

; scale_level - A = A * X / 15 for levels A, X = 0..15. clobbers X, tmp
scale_level
        jsr times17
        pha
        txa
        jsr times17
        tax
        pla
        jsr mul8                ; A = A*X*289/256 = 0..254
        lsr
        lsr
        lsr
        lsr
        rts

; -----------------------------------------------------------------------------
; all_notes_off - panic: forget held notes, close the gate, centre the bend.
; -----------------------------------------------------------------------------
all_notes_off
        lda #0
        sta note_count
        sta bend
        sta bend+1
        jsr seq_forget          ; the sequencer's note is gone too (MIDI out: its off)
        jmp note_gate_off

.if TEST_LOG
; -----------------------------------------------------------------------------
; log_note - TEST_LOG: append (log_tick, note A, velocity X) to the note log,
; until it is full. Preserves A and X; clobbers Y.
; -----------------------------------------------------------------------------
log_out
        pha                     ; MIDI out byte A: (tick, A, 0) into the out log
        sty out_log_y
        ldy out_log_ptr+1
        cpy #>OUT_LOG_END
        bcs _full
        ldy #2
        sta (out_log_ptr),y
        iny
        lda #0
        sta (out_log_ptr),y
        lda log_tick
        ldy #0
        sta (out_log_ptr),y
        lda log_tick+1
        iny
        sta (out_log_ptr),y
        clc
        lda out_log_ptr
        adc #4
        sta out_log_ptr
        bcc _full
        inc out_log_ptr+1
_full   ldy out_log_y
        pla
        rts

log_note
        ldy log_ptr+1
        cpy #>NOTE_LOG_END
        bcs _full
        pha
        ldy #2
        sta (log_ptr),y         ; note
        txa
        iny
        sta (log_ptr),y         ; velocity
        lda log_tick
        ldy #0
        sta (log_ptr),y
        lda log_tick+1
        iny
        sta (log_ptr),y
        clc
        lda log_ptr
        adc #4
        sta log_ptr
        bcc +
        inc log_ptr+1
+       pla
_full   rts
.endif

; -----------------------------------------------------------------------------
; stack_remove - remove a note from note_stack if present.
; A: folded note. Out: carry set if the note was found at the top of the
; stack (it was the sounding note). Preserves A; clobbers X, Y.
; -----------------------------------------------------------------------------
stack_remove
        ldx note_count
        beq _absent
        ; search from the top down
_find   dex
        cmp note_stack,x
        beq _found
        cpx #0
        bne _find
_absent clc
        rts

        ; found at X: carry = (X was the top), then close the gap
_found  ldy note_count
        dey
        sty note_count
        sty tmp
        cpx tmp                 ; X >= new count  <=>  X was the top
        php
        pha
-       cpx note_count
        bcs _closed
        lda note_stack+1,x
        sta note_stack,x
        inx
        bne -
_closed pla
        plp
        rts

; -----------------------------------------------------------------------------
; fold_note - move a MIDI note into the playable range by octaves.
; A: MIDI note in, LOWEST_NOTE..HIGHEST_NOTE out.
; -----------------------------------------------------------------------------
fold_note
-       cmp #LOWEST_NOTE
        bcs +
        adc #12                 ; carry clear here
        bcc -
+
-       cmp #HIGHEST_NOTE+1
        bcc +
        sbc #12                 ; carry set here
        bcs -
+       rts
