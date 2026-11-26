; engine.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; zero-page variables (placed by .dsection zp in sid303.asm)
        .section zp
pitch_sum       .word ?         ; pitch_cur + bend + tune, clamped
diff            .word ?         ; slide: |target - current|
step            .word ?         ; slide: amount moved this tick
freq_base       .word ?         ; pitch_to_sid: table frequency
freq_span       .word ?         ; pitch_to_sid: distance to the next semitone
env_lo          .fill ENV_COUNT ; envelopes, 16 bit, $FFFF = full: [ENV_FILTER, ENV_ACCENT, ENV_AMP]
env_hi          .fill ENV_COUNT
sweep           .byte ?         ; accent sweep level 0..255
cut_sum         .word ?         ; filter_update: log-cutoff index before clamping
.if VIDEO_MARK
raster_hi       .byte ?         ; video mark: the raster line at the previous tick, bit 8
raster_lo       .byte ?         ;             and bits 0-7
.endif
        .send

; =============================================================================
; Synth engine (250 Hz)
; =============================================================================

; -----------------------------------------------------------------------------
; synth_tick - one step of slide, pitch, envelopes and filter.
; -----------------------------------------------------------------------------
synth_tick
.if TEST_TIMING
        inc VIC_BORDER          ; border shows the time a tick takes
.endif
.if TEST_LOG
        inc log_tick            ; the note log's clock
        bne +
        inc log_tick+1
+       lda tick_count          ; ticks still waiting behind this one
        sec
        sbc tick_done
        cmp LOG_LAG
        bcc +
        sta LOG_LAG
+
.endif
.if VIDEO_MARK
        ; once a frame, below the text (vicerec.py grabs VICE's picture
        ; here, so the frame must be drawn whole: a mark at the top of the
        ; frame grabbed half of the last one): the first tick at or past
        ; raster line MARK_LINE, or, when a tick skipped from above it past
        ; the frame's end, the first one after. A tick is ~62 lines, a frame
        ; 312, so every frame is seen once. (SID808, at 500 Hz, uses raster
        ; bit 8: set for only 56 lines, less than a tick here.)
        lda VIC_CTRL1
        and #RASTER_BIT8
        tay                     ; Y = bit 8 now
        ldx VIC_RASTER          ; X = bits 0-7 now
        lda raster_hi           ; the last tick was above MARK_LINE?
        bne _no
        lda raster_lo
        cmp #MARK_LINE
        bcs _no
        tya                     ; ... and this one at or past it,
        bne _mark
        cpx #MARK_LINE
        bcs _mark
        cpx raster_lo           ; ... or past the frame's end (lower again)
        bcs _no
_mark   jsr video_frame
_no     sty raster_hi
        stx raster_lo
.endif
        jsr seq_tick            ; the sequencer first: a step's note sounds in this tick
        jsr slide_step
        jsr pitch_to_sid
        jsr envelopes_step
        jsr filter_update
.if TEST_TIMING
        jsr voice_regs_update
        dec VIC_BORDER
        rts
.else
        jmp voice_regs_update
.endif

.if VIDEO_MARK
RASTER_BIT8     = %10000000     ; VIC_CTRL1 ($D011) bit 7: raster line bit 8
MARK_LINE       = 250           ; the video mark: below the text (lines 51-250)
VIC_RASTER      = $d012         ; raster line bits 0-7
; video_frame - does nothing: vicerec.py stops here once per frame to grab it
video_frame
        rts
.endif

; -----------------------------------------------------------------------------
; slide_step - move pitch_cur towards pitch_tgt by slide_k[SLIDE]/256 of the
; remaining distance (an exponential, RC-like glide in pitch, as on a 303).
; Non-slid notes already have pitch_cur = pitch_tgt, so they stay put.
; -----------------------------------------------------------------------------
slide_step
        ; diff = target - current
        sec
        lda pitch_tgt
        sbc pitch_cur
        sta diff
        lda pitch_tgt+1
        sbc pitch_cur+1
        sta diff+1
        ora diff
        beq _done
        lda diff+1
        bpl _up

        ; going down: make diff positive, subtract the step
        lda #0
        sec
        sbc diff
        sta diff
        lda #0
        sbc diff+1
        sta diff+1
        jsr _step_size
        sec
        lda pitch_cur
        sbc step
        sta pitch_cur
        lda pitch_cur+1
        sbc step+1
        sta pitch_cur+1
_done   rts

        ; going up: add the step
_up     jsr _step_size
        clc
        lda pitch_cur
        adc step
        sta pitch_cur
        lda pitch_cur+1
        adc step+1
        sta pitch_cur+1
        rts

        ; step = diff * k / 256 = diff_hi*k + (diff_lo*k)/256; at least 1
        ; (when it rounds to 0 the remaining distance is taken in one go)
_step_size
        ldy params+P_SLIDE
        ldx slide_k,y
        lda diff
        jsr mul8
        sta tmp                 ; (diff_lo*k)/256
        ldy params+P_SLIDE
        ldx slide_k,y
        lda diff+1
        jsr mul8
        sta step+1              ; diff_hi*k, 16 bit
        lda mul_lo
        clc
        adc tmp
        sta step
        bcc +
        inc step+1
+       lda step
        ora step+1
        bne +
        lda diff
        sta step
        lda diff+1
        sta step+1
+       rts

; -----------------------------------------------------------------------------
; pitch_to_sid - pitch_cur + bend + tune -> SID voice 1 frequency, with linear
; interpolation between the semitones of freq_lo/freq_hi.
; -----------------------------------------------------------------------------
pitch_to_sid
        ; sum = current + bend
        clc
        lda pitch_cur
        adc bend
        sta pitch_sum
        lda pitch_cur+1
        adc bend+1
        sta pitch_sum+1

        ; + tune: (TUNE - 16) * 8 = -128..+120 = about +-half a semitone
        lda params+P_TUNE
        sec
        sbc #TUNE_CENTER
        asl
        asl
        asl
        ldx #0
        cmp #$80
        bcc +
        dex                     ; negative: sign-extend with $FF
+       clc
        adc pitch_sum
        sta pitch_sum
        txa
        adc pitch_sum+1
        sta pitch_sum+1

        ; clamp to the table: below 0 -> 0, above 95.255 -> 95.255
        bpl _not_low
        lda #0
        sta pitch_sum
        sta pitch_sum+1
_not_low
        cmp #HIGHEST_NOTE-LOWEST_NOTE+1
        bcc _in_range
        lda #HIGHEST_NOTE-LOWEST_NOTE
        sta pitch_sum+1
        lda #$ff
        sta pitch_sum
_in_range

        ; base = table[semi], span = table[semi+1] - table[semi]
        ldx pitch_sum+1
        lda freq_lo,x
        sta freq_base
        lda freq_hi,x
        sta freq_base+1
        sec
        lda freq_lo+1,x
        sbc freq_lo,x
        sta freq_span
        lda freq_hi+1,x
        sbc freq_hi,x
        sta freq_span+1

        ; freq = base + span*fraction/256 = base + span_hi*f + (span_lo*f)/256
        lda freq_span
        ldx pitch_sum
        jsr mul8
        sta tmp
        lda freq_span+1
        ldx pitch_sum
        jsr mul8                ; A:mul_lo = span_hi * f
        tay
        lda mul_lo
        clc
        adc tmp
        bcc +
        iny
+       clc
        adc freq_base
        sta SID_V1_FREQ_LO      ; all three voices play the same pitch
        sta SID_V2_FREQ_LO
        sta SID_V3_FREQ_LO
        tya
        adc freq_base+1
        sta SID_V1_FREQ_HI
        sta SID_V2_FREQ_HI
        sta SID_V3_FREQ_HI
        rts

; -----------------------------------------------------------------------------
; envelopes_step - decay the filter and accent envelopes, update the sweep.
; Accented notes decay the filter envelope at the short accent rate (the 303
; does the same: accent overrides the DECAY knob).
; -----------------------------------------------------------------------------
envelopes_step
        ldx params+P_DECAY
        lda decay_k_lo,x
        ldy decay_k_hi,x
        bit note_accent
        bpl +
        lda #<ACCENT_DECAY_K
        ldy #>ACCENT_DECAY_K
+       ldx #ENV_FILTER
        jsr env_decay

        lda #<ACCENT_DECAY_K
        ldy #>ACCENT_DECAY_K
        ldx #ENV_ACCENT
        jsr env_decay

        ; amplitude envelope (held notes fade), unless AMP DECAY = hold
        ldx params+P_AMPDECAY
        cpx #AMP_HOLD
        beq +
        lda amp_decay_k_lo,x
        ldy amp_decay_k_hi,x
        ldx #ENV_AMP
        jsr env_decay
+

        ; accent sweep follows the accent envelope like an RC filter whose
        ; time constants grow with resonance: at high resonance it rises
        ; slowly (the 303's "waaaoow") and falls slowly, so back-to-back
        ; accents build up
        lda env_hi+ENV_ACCENT
        cmp sweep
        bcc _discharge
        beq _done               ; already there
        sbc sweep               ; carry set: A = gap
        ldy params+P_RESO
        ldx sweep_up_k,y
        jsr mul8                ; A = gap * k / 256
        bne +
        lda #1                  ; always move
+       clc
        adc sweep
        sta sweep
_done   rts
_discharge
        lda sweep
        sec
        sbc env_hi+ENV_ACCENT
        ldy params+P_RESO
        ldx sweep_down_k,y
        jsr mul8                ; A = gap * k / 256
        bne +
        lda #1                  ; always move
+       sta tmp
        lda sweep
        sec
        sbc tmp
        sta sweep
        rts

; -----------------------------------------------------------------------------
; filter_update - log-cutoff index = CUTOFF + env*ENVMOD/512
;                                   - ENV_PIVOT*ENVMOD/512 (Env mod type centred)
;                                   + sweep*(ACCENT*4)/256, clamped to 0..255,
; then the 8580 register value from cutoff_lo/cutoff_hi.
; The index has ~31 steps per octave, so env mod reaches up to ~4 octaves
; above the cutoff and the accent kick up to ~2 octaves, roughly a 303's range.
; Env mod type "Centred" copies the 303's env mod: its envelope swings around a
; fixed middle voltage, so more ENV MOD opens the filter further at the start
; of a note *and* closes it further at the end, while the middle of the sweep
; stays put.
; -----------------------------------------------------------------------------
filter_update
        lda env_hi+ENV_FILTER
        ldx params+P_ENVMOD
        jsr mul8
        lsr                     ; /512 in all
        clc
        adc params+P_CUTOFF
        sta cut_sum
        lda #0
        adc #0
        sta cut_sum+1           ; cut_sum is signed 16 bit from here on

        lda params+P_ENVTYPE
        beq _up_only
        ; centred env mod: subtract the pivot, ENV_PIVOT*ENVMOD/512
        lda params+P_ENVMOD
        ldx #ENV_PIVOT
        jsr mul8
        lsr
        sta tmp
        lda cut_sum
        sec
        sbc tmp
        sta cut_sum
        bcs +
        dec cut_sum+1           ; may go below 0: clamped below
+
_up_only

        lda params+P_ACCENT
        asl
        asl
        tax
        lda sweep
        jsr mul8
        clc
        adc cut_sum
        sta cut_sum
        bcc +
        inc cut_sum+1
+       lda cut_sum+1           ; clamp to 0..255
        beq _in_range
        bmi _too_low
        lda #255
        bne _clamped
_too_low
        lda #0
_clamped
        sta cut_sum
_in_range
        ldx cut_sum
        lda cutoff_lo,x
        sta SID_CUTOFF_LO
        lda cutoff_hi,x
        sta SID_CUTOFF_HI
        rts

; -----------------------------------------------------------------------------
; voice_regs_update - write the parameters that map straight to SID registers:
; resonance, filter mode, volume, pulse width, waveform (+ current gate).
; -----------------------------------------------------------------------------
voice_regs_update
        lda params+P_RESO
        asl
        asl
        asl
        asl
        ora #FILTER_ROUTING
        sta SID_RES_FILT

        ldx params+P_FILTER
        lda filter_mode_bits,x
        ora params+P_VOLUME
        sta SID_MODE_VOL

        ; pulse width = (PW+1) * $80: 3% .. 50%
        ldx params+P_PW
        inx
        txa
        lsr                     ; bit 0 -> carry, rest = bits 8-11
        sta SID_V1_PW_HI
        sta SID_V2_PW_HI
        lda #0
        ror                     ; old bit 0 -> bit 7 of the low byte
        sta SID_V1_PW_LO
        sta SID_V2_PW_LO

        ; voice levels (amp fade) and gates
        jsr levels_update
        jmp gates_write

; voice 1 waveform per WAVE: saw, pulse, saw+pulse (8580 combined), and the
; saw half of the 303 square
wave_bits        .byte $20, $40, $60, $20
filter_mode_bits .byte $10, $30, $20, $40       ; low-pass, low+band (stronger peak), band-, high-pass
