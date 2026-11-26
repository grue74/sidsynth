; knobs.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The sound page (docs/design.md 10): every sound has four knobs - Level,
; Tune, Decay, Tone - kept in knob_level / knob_tune / knob_decay /
; knob_tone. The parameter
; screen shows one sound's knobs at a time: the Sound parameter picks it
; (the step grid's cursor row: the two follow each other), and the Level,
; Tune, Decay and Tone parameters are a window on its entries: knob_window copies
; them in when the sound changes, knob_store writes an edit back (from
; synth_param_changed, so keys, MIDI controllers and paddles all go there).
; A MIDI controller or paddle learnt to a knob therefore turns that knob of
; the sound selected at the moment.
;
; The engine reads the table when a hit starts (voice_start: level, tune,
; decay speed, tone), so a knob change applies from the next hit. At the
; defaults (LEVEL_MAX, TUNE_CENTER, DECAY_CENTER, TONE_CENTER) the engine skips the knob: the
; sound is exactly its program.

; RAM after the song block, saved with it (disk.asm: file version 2 the
; first three, 3 all four)
knob_level      = SONG_END      ; NUM_SOUNDS bytes: Level 0..LEVEL_MAX
knob_tune       = knob_level + NUM_SOUNDS ; Tune 0..2*TUNE_CENTER (TUNE_CENTER = 0 semitones)
knob_decay      = knob_tune + NUM_SOUNDS ; Decay 0..15 (DECAY_CENTER = the program's)
knob_tone       = knob_decay + NUM_SOUNDS ; Tone 0..15 (TONE_CENTER = the program's)
KNOBS_END       = knob_tone + NUM_SOUNDS
KNOBS_V2_END    = knob_tone     ; the knobs a version 2 file holds
        .cerror KNOBS_END > $c200, "the knob table runs into cc_map at $C200"

        .weak
TEST_LEVEL = LEVEL_MAX          ; every sound's knobs at start (tests: e.g. the CPU at the extremes)
TEST_TUNE = TUNE_CENTER
TEST_DECAY = DECAY_CENTER
TEST_TONE = TONE_CENTER
        .endweak

; -----------------------------------------------------------------------------
; knob_init - every sound's knobs at their defaults (power-on RAM is junk),
; the page on sound 0. From synth_init.
; clobbers A, X
; -----------------------------------------------------------------------------
knob_init
        ldx #NUM_SOUNDS-1
-       lda #TEST_LEVEL
        sta knob_level,x
        lda #TEST_TUNE
        sta knob_tune,x
        lda #TEST_DECAY
        sta knob_decay,x
        lda #TEST_TONE
        sta knob_tone,x
        dex
        bpl -
        lda #0
        jmp sound_select

; -----------------------------------------------------------------------------
; knob_defaults - sound X's knobs at the defaults (a file without knobs).
; clobbers A
; -----------------------------------------------------------------------------
knob_defaults
        lda #LEVEL_MAX
        sta knob_level,x
        lda #TUNE_CENTER
        sta knob_tune,x
        lda #DECAY_CENTER
        sta knob_decay,x
        ; (on to tone_default)

; tone_default - sound X's Tone at the default (a version 2 file). clobbers A
tone_default
        lda #TONE_CENTER
        sta knob_tone,x
        rts

; -----------------------------------------------------------------------------
; sound_select - the sound page shows sound A: the Sound parameter and the
; grid cursor row follow, and the knob parameters show its values.
; clobbers A, X
; -----------------------------------------------------------------------------
sound_select
        sta params+P_SOUND
        sta cur_row
        ; (on to knob_window)

; -----------------------------------------------------------------------------
; knob_window - the Level, Tune, Decay and Tone parameters = the selected sound's
; knobs. Written straight into params (not through param_changed: nothing
; to write back). clobbers A, X
; -----------------------------------------------------------------------------
knob_window
        ldx params+P_SOUND
        lda knob_level,x
        sta params+P_LEVEL
        lda knob_tune,x
        sta params+P_TUNE
        lda knob_decay,x
        sta params+P_DECAY
        lda knob_tone,x
        sta params+P_TONE
        rts

; -----------------------------------------------------------------------------
; knob_store - parameter Y (P_LEVEL, P_TUNE, P_DECAY or P_TONE) changed: into the
; selected sound's knob. From synth_param_changed.
; preserves Y; clobbers A, X
; -----------------------------------------------------------------------------
knob_store
        ldx params+P_SOUND
        lda params+P_LEVEL
        sta knob_level,x
        lda params+P_TUNE
        sta knob_tune,x
        lda params+P_DECAY
        sta knob_decay,x
        lda params+P_TONE
        sta knob_tone,x
        rts

; -----------------------------------------------------------------------------
; knob_check - after a load: knobs in range (a damaged file); the page
; again. clobbers A, X
; -----------------------------------------------------------------------------
knob_check
        ldx #NUM_SOUNDS-1
-       lda knob_level,x
        cmp #LEVEL_MAX+1
        bcs _bad
        lda knob_tune,x
        cmp #2*TUNE_CENTER+1
        bcs _bad
        lda knob_decay,x
        cmp #16
        bcs _bad
        lda knob_tone,x
        cmp #16
        bcc _ok
_bad    jsr knob_defaults
_ok     dex
        bpl -
        jmp knob_window

; -----------------------------------------------------------------------------
; tune_word - scale the 16-bit frequency in tune_f by Tune knob value Y:
; f x 2^(s/12) as f +- f_hi x delta (tune_delta, tune_up: one multiply; the
; low byte's share is left out, as pitch_scale does); +12 doubles; at most
; $FFFF. Y: knob value (not TUNE_CENTER: callers skip that).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
tune_word
        lda tune_up,y
        sta tune_dir
        lda tune_delta,y
        bne _mul
        asl tune_f              ; delta 0 (+12 semitones): x 2
        rol tune_f+1
        bcs _top
        rts
_mul    tax
        lda tune_f+1
        jsr mul8                ; A:mul_lo = f_hi x delta; clobbers X, Y
        sta tune_acc+1
        lda mul_lo
        sta tune_acc
        lda tune_dir
        beq _down
        clc                     ; higher: f + f_hi x delta
        lda tune_f
        adc tune_acc
        sta tune_f
        lda tune_f+1
        adc tune_acc+1
        sta tune_f+1
        bcs _top
        rts
_down   sec                     ; lower: f - f_hi x delta (delta <= 128: no borrow)
        lda tune_f
        sbc tune_acc
        sta tune_f
        lda tune_f+1
        sbc tune_acc+1
        sta tune_f+1
        rts
_top    lda #$ff                ; past the top: the highest frequency
        sta tune_f
        sta tune_f+1
        rts

; -----------------------------------------------------------------------------
; tune_scale - voice vx's Tune on the frequency array entry X (v_freq_lo/hi
; at X: the voice, or voice + v_target_lo - v_freq_lo for the target, as
; pitch_scale). tune_by: Tune knob value A instead (step_load: the Tone).
; Out: X = vx. clobbers A, Y
; -----------------------------------------------------------------------------
tune_scale
        ldy vx
        lda v_tune,y
tune_by stx tune_x
        tay
        lda v_freq_lo,x
        sta tune_f
        lda v_freq_hi,x
        sta tune_f+1
        jsr tune_word
        ldx tune_x
        lda tune_f
        sta v_freq_lo,x
        lda tune_f+1
        sta v_freq_hi,x
        ldx vx
        rts

; -----------------------------------------------------------------------------
; tone_cutoff - the Tone on a filter cutoff (filter_apply): A x the factor of
; Tune knob value Y (tone_tune; not TUNE_CENTER), at most 255 - tune_word
; on A as a frequency's high byte.
; Out: A. clobbers X, Y
; -----------------------------------------------------------------------------
tone_cutoff
        sta tune_f+1
        lda #0
        sta tune_f
        jsr tune_word
        lda tune_f+1
        rts

; working RAM (not zero page, which is full; only absolute addressing here)
KNOB_RAM        = $c660         ; after disk.asm's variables
tune_f          = KNOB_RAM      ; 2 bytes: tune_word: the frequency
tune_acc        = tune_f + 2    ; 2 bytes:            the product
tune_dir        = tune_acc + 2  ;                     1 = up, 0 = down
tune_x          = tune_dir + 1  ; tune_scale: its X
v_tune          = tune_x + 1    ; NUM_VOICES: Tune knob of each voice's hit (TUNE_CENTER = none)
v_dspeed        = v_tune + NUM_VOICES ; NUM_VOICES: level_decay passes per tick x DECAY_UNIT
v_dacc          = v_dspeed + NUM_VOICES ; NUM_VOICES: the passes' remainder
v_tone          = v_dacc + NUM_VOICES ; NUM_VOICES: Tone of each voice's hit as a Tune
                                ; knob value (tone_tune; TUNE_CENTER = none)
v_tfirst        = v_tone + NUM_VOICES ; NUM_VOICES: nonzero = Tone on the next step's start
                                ; pitch (an unfiltered sound's first step; step_load)
KNOB_RAM_END    = v_tfirst + NUM_VOICES
        .cerror KNOB_RAM < DISK_RAM_END || KNOB_RAM_END > $c6ff, "knob RAM overlaps disk.asm's or the test log index at $C6FF"
