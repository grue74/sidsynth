; engine.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The drum engine: every tick (500 Hz) each sounding voice runs one tick of
; its sound's step program (tables.py writes the programs). A step sets the
; waveform, pitch and pitch glide, pulse width, level and decay, and filter.
; Starting and stopping voices: voices.asm.

; zero-page variables (placed by .dsection zp in core/framework.asm)
        .section zp
; per voice, index 0..2 = SID voice 1..3
v_sound         .fill NUM_VOICES ; sound playing, VOICE_IDLE = none
v_vel           .fill NUM_VOICES ; velocity x 2 (2..254): scales step levels
v_mute          .fill NUM_VOICES ; attack mute ticks left (gate on, oscillator parked)
v_fade          .fill NUM_VOICES ; fade-out ticks left (voice_end); a new sound waits for them
                                ; (also: ticks until a hit's delayed launch, voice_start)
launched        .byte ?         ; nonzero: no more launches in this synth_tick (one was
                                ; made, or the sequencer's hits are being started)
v_left          .fill NUM_VOICES ; ticks left in the current step (FOREVER: until silent)
v_ptr_lo        .fill NUM_VOICES ; next step of the program
v_ptr_hi        .fill NUM_VOICES
v_freq_lo       .fill NUM_VOICES ; SID frequency now
v_freq_hi       .fill NUM_VOICES
v_target_lo     .fill NUM_VOICES ; glide target frequency
v_target_hi     .fill NUM_VOICES
v_glide         .fill NUM_VOICES ; glide shift: 1/2^shift of the way per tick, 0 = none
v_pw            .fill NUM_VOICES ; pulse width, 8 bits (register = value x 16)
v_pk            .fill NUM_VOICES ; pitch raise of this hit, x/256 (velocity + random; voice_start)
ps_x            .byte ?         ; pitch_scale: its X
ps_hi           .byte ?         ;              product high byte
v_ctrl          .fill NUM_VOICES ; SID control byte of the current step (gate included)
v_decay         .fill NUM_VOICES ; level decay rate: page of decay_dlo/dhi (level_decay)
env_lo          .fill ENV_COUNT ; level per voice, 16 bit (level_decay steps it);
env_hi          .fill ENV_COUNT ; its top 4 bits are the voice's SID sustain level
vx              .byte ?         ; voice being worked on
prog            .word ?         ; step_load / voice_start: program pointer
diff            .word ?         ; glide_step: distance to the target, shifted
dlo_ptr         .word ?         ; level_decay: the rate's page of decay_dlo (low byte 0)
dhi_ptr         .word ?         ;              and of decay_dhi
.if VIDEO_MARK
raster_hi       .byte ?         ; video mark: raster bit 8 at the previous tick
.endif
.if TEST_CPU
cpu_start       .word ?         ; TEST_CPU: CIA2 timer B at the start of this tick
cpu_max         .word ?         ;           longest synth_tick so far, cycles
cpu_lag         .byte ?         ;           most ticks the main loop was behind after one
cpu_over        .word ?         ;           ticks longer than a tick period (TICK_LATCH+1)
cpu_ticks       .word ?         ;           ticks measured (stops at $FFFF)
.endif
        .send

; step layout, STEP_SIZE bytes (tables.py, step())
S_TICKS         = 0             ; ticks the step lasts; 0 = end of program, FOREVER
S_WAVE          = 1             ; SID control byte, gate included
S_FREQ          = 2             ; 2 bytes: start frequency, 0 = keep
S_TARGET        = 4             ; 2 bytes: glide target
S_GLIDE         = 6             ; glide shift, 0 = no glide
S_PULSE         = 7             ; pulse width (8 bits)
S_LEVEL         = 8             ; 0 = keep, else restart the level at this x velocity
S_DECAY         = 9             ; decay rate index
S_FILTER        = 10            ; filter setting index, 0 = unfiltered

LEVEL_SILENT    = $10           ; env_hi below this = sustain level 0: the sound has ended

; SID register offset of each voice from voice 1's
voice_reg       .byte 0, 7, 14

; =============================================================================
; synth_tick - hook called 500 times a second: one tick of every voice,
; then the sequencer. At most one voice is launched (its oscillator
; parked) per tick, by its voice_tick: launches are the costliest part of
; a hit, and hits launched together would also load their first steps
; together when their mute phases end. The sequencer's hits only set up
; their voices; each launches on a following tick (voice_start).
; =============================================================================
synth_tick
.if TEST_LOG
        inc log_tick            ; (sequencer.asm's hit log)
        bne +
        inc log_tick+1
+
.endif
        jsr overload_check      ; CPU overload warning
        lda #0
        sta launched            ; a note_on between ticks doesn't count
.if TEST_CPU
        jsr cpu_begin
.endif
.if TEST_TIMING
        inc VIC_BORDER          ; border shows the time a tick takes
.endif
.if VIDEO_MARK
        ; a new frame began since the last tick when raster bit 8 went from
        ; 1 (lines 256-311, 56 lines: at least one tick sees it) to 0
        lda VIC_CTRL1
        and #RASTER_BIT8
        tay
        eor raster_hi
        and raster_hi           ; nonzero: was 1, now 0
        sty raster_hi
        beq +
        jsr video_frame
+
.endif
        ldx #0
        jsr voice_tick
        ldx #1
        jsr voice_tick
        ldx #2
        jsr voice_tick
        jsr seq_tick            ; then the sequencer, in the time left (seq_hits)
        lda #0
        sta launched            ; MIDI notes in the main loop launch at once
.if TEST_TIMING
        dec VIC_BORDER
.endif
.if TEST_CPU
        jmp cpu_end
.else
        rts
.endif

; -----------------------------------------------------------------------------
; overload_check - the CPU overload warning (status row, synth_draw_status).
; The timer interrupt counts ticks (tick_count) and the main loop runs them
; (tick_done); ticks still waiting behind this one mean the engine is late:
; LOAD_LATE or more (hits 16 ms or more late: audible jitter) lights "CPU",
; LOAD_SLIP or more lights "CPU!": at 256 behind the 8-bit count wraps and
; the waiting ticks are lost, so the tempo slips (and MIDI clock out with
; it). Each stays lit LOAD_HOLD x 4 ticks (~2 s) after the last time.
; clobbers A, Y
; -----------------------------------------------------------------------------
LOAD_LATE       = 8             ; ticks behind: late
LOAD_SLIP       = 128           ; ticks behind: losing ticks is near
LOAD_HOLD       = 250           ; x 4 ticks the warning stays lit
load_warn       = $c6f0         ; ticks / 4 left to show "CPU" (RAM: zero page is full)
load_slip       = $c6f1         ;                    and "CPU!"
        .cerror KNOB_RAM_END > load_warn, "load_warn overlaps the knob RAM"

overload_check
        lda tick_count
        sec
        sbc tick_done           ; ticks waiting
        cmp #LOAD_LATE
        bcc _count
        ldy #LOAD_HOLD
        sty load_warn
        cmp #LOAD_SLIP
        bcc _count
        sty load_slip
_count  lda tick_done           ; count down every 4th tick
        and #3
        bne _done
        lda load_warn
        beq +
        dec load_warn
+       lda load_slip
        beq _done
        dec load_slip
_done   rts

.if TEST_CPU
; -----------------------------------------------------------------------------
; cpu_begin / cpu_end - TEST_CPU: time synth_tick with CIA2 timer B, which
; counts down every cycle from $FFFF (free-running; its interrupt stays off).
; cpu_max = the longest tick in cycles (interrupts during it included),
; cpu_lag = the most ticks still waiting when one ended (0 = kept up),
; cpu_over = ticks longer than a tick period, cpu_ticks = ticks measured;
; all only while the sequencer plays (TEST_SEQ builds start playing before
; the screen is set up, so their cpu_lag counts start-up: use TEST_KEYS).
; clobbers A, Y
; -----------------------------------------------------------------------------
CIA2_TB_LO      = $dd06
CIA2_TB_HI      = $dd07
CIA2_CRB        = $dd0f
cpu_begin
        lda CIA2_CRB
        lsr                     ; bit 0: running
        bcs _running            ; started already
        lda #$ff
        sta CIA2_TB_LO
        sta CIA2_TB_HI
        lda #%00010001          ; force latch load, start, continuous, count cycles
        sta CIA2_CRB
_running
        ; read low then high; if the high byte moved meanwhile read again
-       lda CIA2_TB_HI
        sta cpu_start+1
        lda CIA2_TB_LO
        sta cpu_start
        lda CIA2_TB_HI
        cmp cpu_start+1
        bne -
        rts

cpu_end
        lda seq_play            ; only while the sequencer plays (not start-up)
        bne +
        rts
+
        ; elapsed = start - now (the timer counts down; 16-bit wrap is fine
        ; while a tick is under 65536 cycles)
-       lda CIA2_TB_HI
        sta tmp2
        lda CIA2_TB_LO
        sta tmp
        lda CIA2_TB_HI
        cmp tmp2
        bne -
        sec
        lda cpu_start
        sbc tmp
        sta tmp
        lda cpu_start+1
        sbc tmp2
        sta tmp2                ; tmp2:tmp = elapsed
        inc cpu_ticks
        bne +
        inc cpu_ticks+1
        bne +
        dec cpu_ticks           ; stop at $FFFF
        dec cpu_ticks+1
+
        ; over a tick period?
        lda tmp
        cmp #<(TICK_LATCH+1)
        lda tmp2
        sbc #>(TICK_LATCH+1)
        bcc +
        inc cpu_over
        bne +
        inc cpu_over+1
+       lda tmp2
        cmp cpu_max+1
        bcc _lag
        bne +
        ldy tmp
        cpy cpu_max
        bcc _lag
+       sta cpu_max+1
        lda tmp
        sta cpu_max
_lag    ; ticks behind
        lda tick_count
        sec
        sbc tick_done
        cmp cpu_lag
        bcc +
        sta cpu_lag
+       rts
.endif

.if VIDEO_MARK
; video_frame - does nothing: vicerec.py stops here once per frame to grab it
video_frame
        rts
.endif

; -----------------------------------------------------------------------------
; voice_tick - one tick of voice X: the attack mute phase, or the program
; (next step when due, glide, level decay), then the SID registers.
; X: voice. clobbers A, X, Y
; -----------------------------------------------------------------------------
voice_tick
        ; fading out (voice_end): count down; a sound waiting for the voice
        ; launches when the fade is over, unless another voice launched in
        ; this tick: then it waits one more
        lda v_fade,x
        beq _sounding
        dec v_fade,x
        bne _fading
        lda v_sound,x
        cmp #VOICE_IDLE
        beq _fading
        lda launched
        bne _later
        jmp voice_launch
_later  inc v_fade,x            ; v_fade 1: try again next tick
_fading rts

_sounding
        lda v_sound,x
        cmp #VOICE_IDLE
        beq _done
        stx vx
        lda v_mute,x
        beq _run

        ; mute phase: gate on with the oscillator parked at its silent
        ; midpoint (osc_park), so the envelope rises and settles at the
        ; hit's level unheard (design.md 5)
        ldy voice_reg,x
        lda #TRIANGLE | GATE
        sta SID_V1_CTRL,y
        dec v_mute,x
        bne _done               ; the last mute tick goes on to the first step

        ; next step when the current one is over
_run    lda v_left,x
        bne _count
        jsr step_load
        bcs _done               ; the program ended
        ldx vx
_count  lda v_left,x
        cmp #FOREVER
        beq +
        dec v_left,x
+
        ; pitch glide and level decay (the Decay knob: level_decay passes
        ; per tick in DECAY_UNITs, the remainder carried; one at the default)
        jsr glide_step
        lda v_dspeed,x
        cmp #DECAY_UNIT
        bne _passes
        jsr level_decay
        jmp _decayed
_passes clc
        adc v_dacc,x
-       cmp #DECAY_UNIT
        bcc +
        sbc #DECAY_UNIT         ; (carry set)
        pha
        jsr level_decay         ; preserves X
        pla
        jmp -
+       sta v_dacc,x
_decayed
        lda env_hi,x
        cmp #LEVEL_SILENT
        bcs _write
        jmp voice_end           ; faded out

        ; SID registers: frequency, pulse width, sustain level, control
_write  ldy voice_reg,x
        lda v_freq_lo,x
        sta SID_V1_FREQ_LO,y
        lda v_freq_hi,x
        sta SID_V1_FREQ_HI,y
        lda v_pw,x              ; 8-bit width -> 12-bit register: value x 16
        asl
        asl
        asl
        asl
        sta SID_V1_PW_LO,y
        lda v_pw,x
        lsr
        lsr
        lsr
        lsr
        sta SID_V1_PW_HI,y
        lda env_hi,x
        and #$f0                ; sustain level = top 4 bits, release rate 0
        sta SID_V1_SR,y
        lda v_ctrl,x
        sta SID_V1_CTRL,y
_done   rts

; -----------------------------------------------------------------------------
; step_load - start the next step of voice X's program and move past it.
; Fields that say "keep" leave the voice's current value.
; X: voice (= vx). Out: carry set = the program ended (voice now idle).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
step_load
        lda v_ptr_lo,x
        sta prog
        lda v_ptr_hi,x
        sta prog+1
        ldy #S_TICKS
        lda (prog),y
        bne +
        jsr voice_end           ; ticks 0: end of the program
        sec
        rts
+       sta v_left,x
        ldy #S_WAVE
        lda (prog),y
        sta v_ctrl,x

        ; start frequency, unless 0 (keep)
        ldy #S_FREQ
        lda (prog),y
        iny
        ora (prog),y
        beq _glide
        lda (prog),y
        sta v_freq_hi,x
        dey
        lda (prog),y
        sta v_freq_lo,x
        lda v_tune,x            ; the Tune knob, unless at 0 semitones
        cmp #TUNE_CENTER
        beq +
        jsr tune_scale
+       lda v_pk,x              ; the hit's pitch raise
        beq +
        jsr pitch_scale
+       lda v_tfirst,x          ; the Tone knob on an unfiltered sound's first step
        beq +
        lda v_tone,x
        jsr tune_by
+
        ; a target the same as the start (a step without a glide): the start
        ; as tuned and raised, without doing it all again
        ldy #S_TARGET
        lda (prog),y
        ldy #S_FREQ
        cmp (prog),y
        bne _glide
        ldy #S_TARGET+1
        lda (prog),y
        ldy #S_FREQ+1
        cmp (prog),y
        bne _glide
        lda v_freq_lo,x
        sta v_target_lo,x
        lda v_freq_hi,x
        sta v_target_hi,x
        jmp _speed

        ; glide target (raised as the start), speed, pulse width, decay rate
_glide  ldy #S_TARGET
        lda (prog),y
        sta v_target_lo,x
        iny
        lda (prog),y
        sta v_target_hi,x
        lda v_tune,x            ; tuned as the start
        cmp #TUNE_CENTER
        beq +
        txa
        clc
        adc #v_target_lo-v_freq_lo ; tune_scale on the target arrays
        tax
        jsr tune_scale
+       lda v_pk,x
        beq +
        txa
        clc
        adc #v_target_lo-v_freq_lo ; pitch_scale on the target arrays
        tax
        jsr pitch_scale
+
_speed  ldy #S_GLIDE
        lda (prog),y
        sta v_glide,x
        ldy #S_PULSE
        lda (prog),y
        sta v_pw,x
        ldy #S_DECAY
        lda (prog),y
        sta v_decay,x

        ; filter: only while this voice owns it (voice_start claims it)
        cpx filter_owner
        bne _level
        ldy #S_FILTER
        lda (prog),y
        jsr filter_apply

        ; level: restart at step level x velocity, unless 0 (keep)
_level  ldy #S_LEVEL
        lda (prog),y
        beq _next
        ldy v_vel,x
        tax
        tya
        jsr mul8                ; A = level x velocity x 2 / 256; clobbers X, Y
        ldx vx
        sta env_hi,x
        lda #0
        sta env_lo,x

        ; move the program pointer to the next step (the Tone's first step is over)
_next   lda #0
        sta v_tfirst,x
        clc
        lda v_ptr_lo,x
        adc #STEP_SIZE
        sta v_ptr_lo,x
        bcc +
        inc v_ptr_hi,x
+       clc
        rts

; -----------------------------------------------------------------------------
; level_decay - one tick of voice X's exponential level decay:
; env -= the decay table's amount for env_hi (tables.py decay_tables: the
; same result as the core's env_decay with the rate's factor, which takes
; two multiplies; this is a table lookup). Below 1/256 it snaps to 0, and it
; never goes below 0.
; X: voice (preserved). clobbers A, Y
; -----------------------------------------------------------------------------
        .cerror (decay_dlo & $ff) != 0, "decay_dlo must be page-aligned"
level_decay
        lda env_hi,x
        beq _zero
        tay                     ; Y = env_hi: index into the rate's pages
        lda v_decay,x
        clc
        adc #>decay_dlo
        sta dlo_ptr+1
        adc #NUM_DECAYS         ; carry clear: the high-byte pages follow
        sta dhi_ptr+1
        sec
        lda env_lo,x
        sbc (dlo_ptr),y
        sta env_lo,x
        lda env_hi,x
        sbc (dhi_ptr),y
        bcs +
        lda #0                  ; below 0: stop at 0
        sta env_lo,x
+       sta env_hi,x
        rts
_zero   sta env_lo,x            ; env_hi 0: below 1/256, snap to 0
        rts

; -----------------------------------------------------------------------------
; pitch_scale - raise a 16-bit frequency by v_pk/256 of itself:
; f += f_hi x v_pk (= f x v_pk / 256, the low byte's share left out).
; X: voice (v_freq_lo/hi), or voice + v_target_lo - v_freq_lo (the target
; arrays, which follow the frequency arrays). vx: the voice.
; Out: X = vx. clobbers A, Y
; -----------------------------------------------------------------------------
        .cerror v_freq_hi - v_freq_lo != NUM_VOICES || v_target_hi - v_target_lo != NUM_VOICES, "pitch_scale: array layout"
pitch_scale
        stx ps_x
        ldy vx
        lda v_freq_hi,x
        ldx v_pk,y
        jsr mul8                ; A:mul_lo = f_hi x v_pk; clobbers X, Y
        sta ps_hi
        ldx ps_x
        clc
        lda v_freq_lo,x
        adc mul_lo
        sta v_freq_lo,x
        lda v_freq_hi,x
        adc ps_hi
        sta v_freq_hi,x
        bcc +
        lda #$ff                ; past the top: the highest frequency
        sta v_freq_lo,x
        sta v_freq_hi,x
+       ldx vx
        rts

; -----------------------------------------------------------------------------
; glide_step - move voice X's frequency 1/2^v_glide of the way to its target
; (an exponential approach, like the 808's pitch drop). Rounds towards
; -infinity, so it settles on the target or one step below.
; X: voice (preserved). clobbers A, Y
; -----------------------------------------------------------------------------
glide_step
        ldy v_glide,x
        beq _done
        ; diff = target - freq, signed 16 bit
        sec
        lda v_target_lo,x
        sbc v_freq_lo,x
        sta diff
        lda v_target_hi,x
        sbc v_freq_hi,x
        sta diff+1
        ; arithmetic shift right v_glide times
-       lda diff+1
        cmp #$80                ; carry = sign bit, shifted back in
        ror diff+1
        ror diff
        dey
        bne -
        ; freq += diff
        clc
        lda v_freq_lo,x
        adc diff
        sta v_freq_lo,x
        lda v_freq_hi,x
        adc diff+1
        sta v_freq_hi,x
_done   rts
