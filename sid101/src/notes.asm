; notes.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Notes in, gates and voice levels out. Monophonic with a held-note stack
; (the newest held note sounds; letting it go falls back to the one held
; before), legato (a note on while another is held doesn't retrigger), and
; the glide modes. The engine (engine.asm) runs the envelope and the pitch.

; zero-page variables (placed by .dsection zp in core/framework.asm)
        .section zp
pitch_cur       .word ?         ; sounding pitch, hi = semitone (MIDI-12), lo = fraction
pitch_tgt       .word ?         ; pitch glided towards
gate_bit        .byte ?         ; GATE while the SID gates are open, else 0
env_stage       .byte ?         ; the ADSR's stage, STAGE_*
note_glides     .byte ?         ; 1 if the sounding note moves by glide (status row)
note_count      .byte ?         ; notes in note_stack
last_vel        .byte ?         ; velocity of the last note on (status row)
v1_level        .byte ?         ; the voices' sustain levels as last written, 0..15:
v2_level        .byte ?         ;   during a note they only go down (a raised SID
v3_level        .byte ?         ;   sustain level is not followed)
.if TEST_LOG
log_ptr         .word ?         ; next free entry of the note log
log_tick        .word ?         ; +1 every synth tick
out_log_ptr     .word ?         ; next free entry of the MIDI out log
out_log_y       .byte ?         ; log_out: Y kept
.endif
        .send

; the ADSR's stages (env_stage)
STAGE_IDLE      = 0             ; silent: the gates are closed
STAGE_ATTACK    = 1
STAGE_DECAY     = 2
STAGE_SUSTAIN   = 3
STAGE_RELEASE   = 4

.if TEST_LOG
; TEST_LOG: every note_on / note_off, 4 bytes each: tick (low, high), note,
; velocity (0 = note off). It fills NOTE_LOG..NOTE_LOG_END (512 entries) and
; then stops. (It was $6000-$6FFF until the C64 lead mode's code needed the
; room below it: tools/seq_check.py and voice_check.py read it here.)
NOTE_LOG        = $6800
NOTE_LOG_END    = $7000
; every byte queued for MIDI out (log_out): tick (low, high), the byte, 0;
; room for 1024 (the tests use up to 773), in the RAM under the KERNAL
; (the ROMs are banked out): the program has outgrown $5100-$5EFF. That RAM
; is SysEx's staging area (core/sysex.asm SYSEX_RAM), so a TEST_MIDIOUT
; build can't test dumps. tools/seq_check.py reads OUT_LOG from the labels.
OUT_LOG         = $e000
OUT_LOG_END     = $f000         ; (the full check is on the high byte)
        .cerror TEST_MIDIOUT && TEST_SYSEX, "TEST_MIDIOUT's log is where TEST_SYSEX's dumps go"
LOG_FIRST       = NOTE_LOG - $100 ; log_init clears from here: PROFILE_MAX, the note log
LOG_LAG         = NOTE_LOG - 1  ; the most ticks ever left waiting when a tick ran (tick_count -
                                ; tick_done in synth_tick): ticks falling behind the timer show here
LOG_LAG_AT      = NOTE_LOG - 3  ; (word) log_tick when LOG_LAG was last raised
TICK_MAX        = NOTE_LOG - 4  ; the longest synth_tick, in 256-cycle units (CIA1 timer A high byte)
.endif

; held-note stack in the synth's RAM area ($C140-$C1FF, see core/framework.asm)
note_stack      = $c140         ; STACK_SIZE bytes: held notes, last = newest

; =============================================================================
; Notes
; =============================================================================

; -----------------------------------------------------------------------------
; notes_init - no notes held, silent.
; clobbers A, X
; -----------------------------------------------------------------------------
notes_init
        lda #0
        sta note_count
        sta gate_bit
        sta note_glides
        sta pitch_cur
        sta pitch_tgt
        lda #$ff                ; no pitch written yet (pitch_to_sid)
        sta pitch_last+1
        lda #STAGE_IDLE
        sta env_stage
        ldx #STACK_SIZE-1
-       sta note_stack,x
        dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; voice_note_on - a note starts in the voice (the core's note_on, or the
; arpeggiator's step: arp.asm). With another note held it is legato: no
; retrigger, the pitch glides there (glide On or Auto) or jumps (Off).
; Otherwise the envelope and the gates start again; with glide On the
; pitch glides from the last note's, else it starts at the note.
; A: MIDI note, X: velocity (1..127). clobbers A, X, Y
; -----------------------------------------------------------------------------
voice_note_on
.if TEST_LOG
        jsr log_note
.endif
        stx last_vel
        jsr fold_note
        sta tmp2                ; folded note

        ; legato if another note was held before this one
        ldx note_count
        stx tmp                 ; notes held before this one

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

        ; legato: no retrigger; glide (On, Auto) or jump (Off)
        lda tmp
        beq _fresh
        lda env_stage           ; (held, but already released? then fresh)
        cmp #STAGE_RELEASE
        bcs _fresh
        jsr chord_note          ; (C64 mode: the chord again)
        jmp glide_or_jump

        ; a fresh note: glide from the last pitch only with glide On
_fresh  lda #0
        sta note_glides
        lda params+P_GLIDEMODE
        cmp #GLIDE_ON
        bne _jump
        lda pitch_cur+1         ; (no note before: pitch 0, nothing to glide from)
        ora pitch_cur
        beq _jump
        lda #1
        sta note_glides
        bne _start              ; always
_jump   jsr pitch_jump

        ; the note's accent and the LFO's fade; the envelope from 0, the
        ; gates retriggered
_start  jsr note_accent
        lda #0
        sta env_lo+ENV_ADSR
        sta env_hi+ENV_ADSR
        lda #STAGE_ATTACK
        sta env_stage
        jsr chord_note          ; (C64 mode: the chord from its start)
        ; the note's frequencies before its gates open: else the voices
        ; start at the last note's until the engine's next tick (0.75-3.8
        ; ms, a blip; SID500 docs/latency.md, tools/synth_latency.py). Not
        ; in C64 mode: its chord steps and echo follow the tick (written
        ; here, a chord's note sounded a tick early: voice_check's chords)
        lda params+P_VOICEMODE
        cmp #VM_C64
        beq +
        jsr pitch_to_sid
+       jmp voices_retrigger

; -----------------------------------------------------------------------------
; note_accent - a fresh note's accent from its velocity (last_vel) and
; ACCENT: the level factor (acc_vel4, 15 = full) and the env mod boost
; (acc_boost), from accent_level / accent_env [ACCENT x 16 + velocity / 8].
; Legato notes keep the accent of the note they continue (their level
; couldn't rise anyway). The LFO's fade-in starts again (LFO delay 0: none).
; clobbers A, X
; -----------------------------------------------------------------------------
note_accent
        lda params+P_ACCENT
        asl
        asl
        asl
        asl
        sta tmp
        lda last_vel
        lsr
        lsr
        lsr
        ora tmp
        tax
        lda accent_level,x
        sta acc_vel4
        lda accent_env,x
        sta acc_boost
        ; the fade from 0, or full without a delay
        lda #$ff
        ldx params+P_LFODELAY
        beq +
        lda #0
+       sta lfo_fade
        sta lfo_fade+1
        rts

; -----------------------------------------------------------------------------
; glide_or_jump - a legato move to pitch_tgt: glide with glide On or Auto,
; jump with Off. clobbers A
; -----------------------------------------------------------------------------
glide_or_jump
        lda params+P_GLIDEMODE
        beq pitch_jump          ; GLIDE_OFF
        lda #1
        sta note_glides
        rts

; pitch_jump - the pitch straight to the target. clobbers A
pitch_jump
        lda #0
        sta note_glides
        lda pitch_tgt
        sta pitch_cur
        lda pitch_tgt+1
        sta pitch_cur+1
        rts

; -----------------------------------------------------------------------------
; voice_note_off - a note ends in the voice. If it was the sounding one and others are still
; held, legato back to the newest of them; if none are held, the release
; (Gate mode: the gates close now; C64 mode: the chord plays on in it).
; A: MIDI note. clobbers A, X, Y
; -----------------------------------------------------------------------------
voice_note_off
.if TEST_LOG
        ldx #0                  ; (voice_note_off clobbers X anyway)
        jsr log_note
.endif
        jsr fold_note
        jsr stack_remove
        bcc _done               ; not the sounding note: only a chord of keys changes
        ldx note_count
        beq note_release
        lda note_stack-1,x      ; legato back to the newest held note
        sec
        sbc #LOWEST_NOTE
        sta pitch_tgt+1
        lda #0
        sta pitch_tgt
        jsr chord_note          ; (C64 mode: the chord again)
        jmp glide_or_jump
_done   jmp chord_note

; note_release - no note held: the envelope's release; in Gate mode the
; gates close at once. clobbers A, X
note_release
        lda env_stage
        beq _done               ; already silent
        lda #STAGE_RELEASE
        sta env_stage
        lda params+P_AMPMODE
        cmp #AMP_GATE
        beq note_gate_off
_done   rts

; note_gate_off - close the SID gates (the voices' release, 6 ms)
note_gate_off
        lda #0
        sta gate_bit
        jmp gates_write

; -----------------------------------------------------------------------------
; voices_retrigger - restart the voices' SID envelopes: gates off, each
; voice's sustain level = its mix level x the note's accent (the envelope
; starts full; as levels_update's first tick), gates on. With every rate at
; 0 the SID starts again at once. C64 mode: the click starts (the lead's
; first frames in its waveform), the PWM sweep from its start, and the
; echo is told (lead_retrig).
; clobbers A, X
; -----------------------------------------------------------------------------
voices_retrigger
        lda #0
        sta gate_bit
        lda params+P_VOICEMODE
        cmp #VM_C64
        beq _c64
        jsr gates_write
        lda params+P_SAW        ; the levels at a note's start: the mix x accent
        jsr _accented
        sta v1_level
        lda params+P_PULSE
        jsr _accented
        sta v2_level
_sub    lda params+P_SUB
        jsr _accented
        sta v3_level
        jsr levels_write
        lda #GATE
        sta gate_bit
        jmp gates_write

        ; C64 mode: the PWM sweep from its start, the click (if any) starts,
        ; the echo retriggers; voice 1 is the pulse lead (voice 2's level is
        ; the echo's)
_c64    lda #0
        sta sweep_phase
        sta sweep_phase+1
        ldx params+P_CLICK
        lda click_ticks,x
        sta click_left
        lda #ECHO_RETRIG
        sta lead_retrig
        jsr gates_write
        lda params+P_PULSE
        jsr _accented
        sta v1_level
        jmp _sub

        ; A = level_tab[mix level A x 16 + acc_vel4]. clobbers X
_accented
        asl
        asl
        asl
        asl
        ora acc_vel4
        tax
        lda level_tab,x
        rts

; -----------------------------------------------------------------------------
; gates_write - the voices' control registers: saw on voice 1, pulse on 2
; (Sync mode: a saw hard-synced to voice 1; C64 mode: voice 1 the pulse
; lead or its click, voice 2 left to the echo) and 3, each gated with gate_bit
; if its mix level is above 0 (a voice at level 0 would still click: the SID
; attacks to full before its sustain). Voice 1 runs at level 0 too: its
; oscillator still drives the sync.
; clobbers A, X
; -----------------------------------------------------------------------------
gates_write
        lda params+P_VOICEMODE
        cmp #VM_C64
        beq _c64
        ldx #WAVE_SAW
        lda params+P_SAW
        jsr _gate
        sta SID_V1_CTRL
        sta lead_ctrl
        ldx #WAVE_PULSE
        lda params+P_VOICEMODE
        beq +
        ldx #WAVE_SAW | SYNC
+       lda params+P_PULSE
        jsr _gate
        sta SID_V2_CTRL
_sub    ldx #WAVE_PULSE
        lda params+P_SUB
        jsr _gate
        sta SID_V3_CTRL
        rts

        ; C64 mode: voice 1 the pulse lead (the click's waveform while it
        ; sounds), at the Pulse level; voice 2 is the echo's (c64_update)
_c64    ldx #WAVE_PULSE
        lda click_left
        beq +
        ldx params+P_CLICK
        lda click_waves,x
        tax
+       lda params+P_PULSE
        jsr _gate
        sta SID_V1_CTRL
        sta lead_ctrl
        jmp _sub

        ; A = waveform X, with the gate if level A is above 0
_gate   beq +
        txa
        ora gate_bit
        rts
+       txa
        rts

; -----------------------------------------------------------------------------
; levels_write - v1_level..v3_level into the voices' sustain levels
; (release 0). C64 mode: v2_level is the echo's (c64_update keeps it as
; it writes it), so voice 2 gets its own level again. clobbers A
; -----------------------------------------------------------------------------
levels_write
        lda v1_level
        asl
        asl
        asl
        asl
        sta SID_V1_SR
        lda v2_level
        asl
        asl
        asl
        asl
        sta SID_V2_SR
        lda v3_level
        asl
        asl
        asl
        asl
        sta SID_V3_SR
        rts

; -----------------------------------------------------------------------------
; all_notes_off - panic: forget held notes, close the gates, centre the bend.
; clobbers A, X
; -----------------------------------------------------------------------------
all_notes_off
        lda #0
        sta note_count
        sta bend
        sta bend+1
        lda #STAGE_IDLE
        sta env_stage
        jsr seq_forget          ; the sequencer's note is gone too (MIDI out: its off)
        jsr arp_forget          ; and the arpeggiator's keys
        jsr echo_clear          ; and C64 mode's echo
        jmp note_gate_off

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

.if TEST_LOG
; -----------------------------------------------------------------------------
; log_init - the out and note logs empty and cleared (LOG_FIRST-$6FFF and
; with TEST_MIDIOUT the out log: an entry of zeros marks each one's end;
; without TEST_MIDIOUT the out log starts full), LOG_LAG and TICK_MAX 0.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
log_init
        lda #<OUT_LOG
        sta out_log_ptr
.if TEST_MIDIOUT
        lda #>OUT_LOG
.else
        lda #>OUT_LOG_END       ; no MIDI out in this build: the out log stays full
.endif
        sta out_log_ptr+1
.if TEST_MIDIOUT
        lda #0                  ; the out log cleared
        tay
        ldx #>(OUT_LOG_END - OUT_LOG)
-       sta (out_log_ptr),y
        iny
        bne -
        inc out_log_ptr+1
        dex
        bne -
        lda #>OUT_LOG
        sta out_log_ptr+1
.endif
        lda #<LOG_FIRST
        sta log_ptr
        lda #>LOG_FIRST
        sta log_ptr+1           ; (clearing from LOG_FIRST on)
        lda #0
        tay
-       sta (log_ptr),y
        iny
        bne -
        inc log_ptr+1
        ldy log_ptr+1
        cpy #>NOTE_LOG_END
        ldy #0
        bcc -
        lda #>NOTE_LOG
        sta log_ptr+1
        lda #0
        sta LOG_LAG
        sta LOG_LAG_AT
        sta LOG_LAG_AT+1
        sta TICK_MAX
        rts

; -----------------------------------------------------------------------------
; log_out - TEST_LOG, core/sequencer.asm: append (log_tick, MIDI out byte
; A, 0) to the out log, until it is full. Preserves A and Y.
; -----------------------------------------------------------------------------
log_out
        pha
        sty out_log_y
        ldy out_log_ptr+1
        cpy #>OUT_LOG_END
        bcs _full
        ldy #2
        sta (out_log_ptr),y     ; the byte
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

; -----------------------------------------------------------------------------
; log_note - TEST_LOG: append (log_tick, note A, velocity X) to the note log,
; until it is full. Preserves A and X; clobbers Y.
; -----------------------------------------------------------------------------
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
