; engine.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The 250 Hz sound engine: the ADSR, glide, the LFO (four shapes, a fade-in),
; the pitch of the three voices (the sub an octave or two down), the filter,
; the pulse widths and the voice levels (mix x envelope x accent); in C64
; mode the lead's echo, its attack click and its own PWM sweep.

; zero-page variables (placed by .dsection zp in core/framework.asm)
        .section zp
env_lo          .fill ENV_COUNT ; envelopes, 16 bit, $FFFF = full: [ENV_ADSR, ENV_WORK]
env_hi          .fill ENV_COUNT
sustain_lvl     .word ?         ; the sustain level as an envelope value (SUSTAIN x $1111)
diff            .word ?         ; glide: |target - current|
glide_step      .word ?         ; glide: amount moved this tick
pitch_sum       .word ?         ; pitch_cur + bend + tune + vibrato, clamped
freq_base       .word ?         ; pitch_to_sid: table frequency
freq_span       .word ?         ; pitch_to_sid: distance to the next semitone
freq_out        .word ?         ; freq_of_pitch: the SID frequency
freq_pitch      .word ?         ; freq_of_pitch: the pitch it converts
lfo_phase       .word ?         ; LFO phase, 16 bit
lfo_tri         .byte ?         ; the LFO 0..254 in its shape (128 = the middle), faded
lfo_dev         .byte ?         ; |lfo_tri - 128| x 2, 0..255: how far from the middle, faded
lfo_neg         .byte ?         ; $80 if lfo_tri is below the middle, else 0
lfo_held        .byte ?         ; the random shape's value, held for a cycle
lfo_last        .byte ?         ; the random shape: the phase's high byte last tick
lfo_fade        .word ?         ; the LFO's fade-in, $FFFF = full (note_accent restarts it)
rng             .word ?         ; random_byte: 16-bit Galois LFSR, never 0
acc_vel4        .byte ?         ; accent: the note's level factor 0..15 (15 = full; note_accent)
acc_boost       .byte ?         ; accent: env mod added for the note, 0..255
.if TEST_LOG
tick_start_hi   .byte ?         ; TEST_LOG: CIA1 timer A's high byte when synth_tick began
.endif
.if TEST_PROFILE
prof_t0         .word ?         ; TEST_PROFILE: the timer at prof_start
.endif
.if VIDEO_MARK
raster_hi       .byte ?         ; video mark: the raster line at the previous tick, bit 8
raster_lo       .byte ?         ;             and bits 0-7
.endif
cut_sum         .word ?         ; filter_update: log-cutoff index before clamping, signed
pw_out          .word ?         ; pw_update: the lead's pulse width (voice 2's; C64 mode: voice 1's)
amp4            .byte ?         ; levels_update: the amp envelope's top 4 bits, 0..15
pitch_last      .word ?         ; pitch_to_sid: pitch_sum last written ($FFxx: none yet)
subtype_last    .byte ?         ; pitch_to_sid: the sub type last written
        .send

; C64 mode's echo (c64_update): voice 1 as it was ECHO_LEN ticks ago, a slot a
; tick in a ring of ECHO_LEN, one table per value
ECHO_LEN        = 32            ; ticks: 128 ms
ECHO_RAM        = $cf00         ; after the presets (PRESET_END), below I/O
echo_freq_lo    = ECHO_RAM
echo_freq_hi    = ECHO_RAM + ECHO_LEN
echo_ctrl       = ECHO_RAM + 2 * ECHO_LEN ; control byte, ECHO_RETRIG if it retriggered
echo_level      = ECHO_RAM + 3 * ECHO_LEN ; voice 1's level, 0..15
echo_pw_lo      = ECHO_RAM + 4 * ECHO_LEN
echo_pw_hi      = ECHO_RAM + 5 * ECHO_LEN
        .cerror ECHO_LEN & (ECHO_LEN - 1), "ECHO_LEN must be a power of 2 (the slot is masked)"

; C64 mode's variables (zero page is full in the test builds), after the ring
        .virtual ECHO_RAM + 6 * ECHO_LEN
lead_freq       .word ?         ; pitch_to_sid: voice 1's frequency as written (the echo)
lead_ctrl       .byte ?         ; gates_write: voice 1's control byte as written (the echo)
lead_retrig     .byte ?         ; ECHO_RETRIG once voices_retrigger ran, until the echo took it
click_left      .byte ?         ; ticks of the attack click left, 0 = none
sweep_phase     .word ?         ; the PWM sweep's phase (from 0 at a fresh note)
echo_pos        .byte ?         ; the echo ring's slot this tick, 0..ECHO_LEN-1
chord_len       .byte ?         ; the chord's notes (chord_build), 0 = no chord
chord_pos       .byte ?         ; the one sounding, 0..chord_len-1
chord_wait      .byte ?         ; ticks until the next one
chord_now       .byte ?         ; semitones it adds to the note (signed; pitch_to_sid)
chord_offs      .fill STACK_SIZE ; each note's semitones from the sounding note, in
                                ; playing order (the first 0: the note itself)
chord_sorted    .fill STACK_SIZE ; chord_build: the held keys, sorted upwards
c64_vars_end
        .endv
        .cerror c64_vars_end > $d000, "C64 mode's variables run into I/O"
ECHO_RETRIG     = %00001000     ; the SID's TEST bit, never written: marks a retrigger
FRAME_TICKS     = 5             ; a frame of the old 50 Hz players, in ticks (the click)

; the attack click by P_CLICK (click_names): off, then noise, saw and square
; for 1, 2, 3 frames each (voices_retrigger, gates_write; square = the
; pulse at 50 %: pw_update)
click_waves     .byte 0
                .fill 3, WAVE_NOISE
                .fill 3, WAVE_SAW
                .fill 3, WAVE_PULSE
click_ticks     .byte 0
                .for _w := 0, _w < 3, _w += 1
                .byte FRAME_TICKS, 2 * FRAME_TICKS, 3 * FRAME_TICKS
                .endfor

; =============================================================================
; Synth engine (250 Hz)
; =============================================================================

; -----------------------------------------------------------------------------
; engine_init - the LFO at full depth (no fade running), no accent, the
; random generator seeded, C64 mode's echo ring cleared. clobbers A, X
; -----------------------------------------------------------------------------
RNG_SEED        = $ace1         ; any nonzero start
RNG_TAPS        = $b4           ; Galois LFSR feedback into the high byte: x^16 + x^14 +
                                ; x^13 + x^11 + 1, period 65535
ACC_NONE        = 15            ; acc_vel4 without accent: level x 15/15

engine_init
        lda #$ff
        sta lfo_fade
        sta lfo_fade+1
        lda #ACC_NONE
        sta acc_vel4
        lda #0
        sta acc_boost
        lda #128
        sta lfo_held
        lda #<RNG_SEED
        sta rng
        lda #>RNG_SEED
        sta rng+1
        lda #0
        sta click_left
        sta echo_pos
        sta lead_retrig
        ldx #6 * ECHO_LEN       ; the whole echo ring 0 (then echo_clear)
-       sta ECHO_RAM-1,x
        dex
        bne -
        jmp echo_clear

.if VIDEO_MARK
RASTER_BIT8     = %10000000     ; VIC_CTRL1 ($D011) bit 7: raster line bit 8
MARK_LINE       = 250           ; the video mark: below the text (lines 51-250)
VIC_RASTER      = $d012         ; raster line bits 0-7
; video_frame - does nothing: vicerec.py stops here once per frame to grab it
video_frame
        rts
.endif

; -----------------------------------------------------------------------------
; synth_tick - one step of the sequencer (a step's note on or off), the
; envelope, glide, LFO, pitch (and the sync voice's), filter, pulse width
; and voice levels.
; -----------------------------------------------------------------------------
synth_tick
.if TEST_TIMING
        inc VIC_BORDER          ; border shows the time a tick takes
.endif
.if TEST_LOG
        lda CIA1_TA_HI          ; the timer counts down from TICK_LATCH: the start
        sta tick_start_hi
        inc log_tick            ; the note log's clock
        bne +
        inc log_tick+1
+       lda tick_count          ; ticks still waiting behind this one
        sec
        sbc tick_done
        cmp LOG_LAG
        bcc +
        beq +
        sta LOG_LAG             ; a new worst: remember when
        lda log_tick
        sta LOG_LAG_AT
        lda log_tick+1
        sta LOG_LAG_AT+1
+
.endif
.if VIDEO_MARK
        ; once a frame, below the text (vicerec.py grabs VICE's picture
        ; here, so the frame must be drawn whole), as SID303's: the first
        ; tick at or past raster line MARK_LINE, or, when a tick skipped
        ; from above it past the frame's end, the first one after. A tick
        ; is ~62 lines, a frame 312, so every frame is seen once.
        lda VIC_CTRL1
        and #RASTER_BIT8
        tay                     ; Y = bit 8 now
        ldx VIC_RASTER          ; X = bits 0-7 now
        lda raster_hi           ; the last tick was above MARK_LINE?
        bne _no_mark
        lda raster_lo
        cmp #MARK_LINE
        bcs _no_mark
        tya                     ; ... and this one at or past it,
        bne _mark
        cpx #MARK_LINE
        bcs _mark
        cpx raster_lo           ; ... or past the frame's end (lower again)
        bcs _no_mark
_mark   jsr video_frame
_no_mark
        sty raster_hi
        stx raster_lo
.endif
        #timed arp_tick, 9      ; the arpeggiator and the sequencer first: their notes
        lda #1                  ; sound in this tick (the sequencer's straight to the voice)
        sta in_seq
        #timed seq_tick, 8
        lda #0
        sta in_seq
        #timed adsr_step, 0
        #timed glide_step_run, 1
        #timed lfo_step, 2
        #timed pitch_to_sid, 3
        #timed mode_update, 7
        #timed filter_update, 4
        #timed pw_update, 5
        #timed levels_update, 6
.if TEST_TIMING
        dec VIC_BORDER
.endif
.if TEST_LOG
        ; the time this tick took, in 256-cycle units (the timer may have wrapped)
        sec
        lda tick_start_hi
        sbc CIA1_TA_HI
        bcs +
        adc #>TICK_LATCH+1      ; wrapped: one timer period more
+       cmp TICK_MAX
        bcc +
        sta TICK_MAX
+
.endif
        rts

; -----------------------------------------------------------------------------
; timed - jsr routine; with TEST_PROFILE also time it (prof_start, prof_end)
; into PROFILE_MAX slot n.
; -----------------------------------------------------------------------------
timed   .macro routine, slot
.if TEST_PROFILE
        jsr prof_start
.endif
        jsr \routine
.if TEST_PROFILE
        ldx #\slot
        jsr prof_end
.endif
        .endm

.if TEST_PROFILE
PROFILE_MAX     = LOG_FIRST     ; PROFILE_SLOTS words: the longest run of each part, cycles
                                ; (the page below the note log)
PROFILE_SLOTS   = 10

; prof_start - remember CIA1 timer A (counts down). clobbers A, X
prof_start
        jsr timer_read
        sta prof_t0
        stx prof_t0+1
        rts

; prof_end - the cycles since prof_start (the timer may have wrapped once),
; kept in PROFILE_MAX slot X if the longest yet. clobbers A, X, Y
prof_end
        txa
        asl
        tay                     ; Y = slot x 2
        jsr timer_read
        sta tmp
        stx tmp2
        sec                     ; elapsed = t0 - now
        lda prof_t0
        sbc tmp
        sta tmp
        lda prof_t0+1
        sbc tmp2
        sta tmp2
        bcs +
        clc                     ; wrapped: + a timer period
        lda tmp
        adc #<(TICK_LATCH+1)
        sta tmp
        lda tmp2
        adc #>(TICK_LATCH+1)
        sta tmp2
+       lda tmp2                ; the longest yet?
        cmp PROFILE_MAX+1,y
        bcc _done
        bne _keep
        lda tmp
        cmp PROFILE_MAX,y
        bcc _done
_keep   lda tmp
        sta PROFILE_MAX,y
        lda tmp2
        sta PROFILE_MAX+1,y
_done   rts

; timer_read - CIA1 timer A into A (low), X (high), read so that a carry
; between the bytes can't mix two values. clobbers A, X
timer_read
-       ldx CIA1_TA_HI
        lda CIA1_TA_LO
        cpx CIA1_TA_HI
        bne -
        rts

; prof_clear - all slots 0. clobbers A, X
prof_clear
        lda #0
        ldx #PROFILE_SLOTS*2-1
-       sta PROFILE_MAX,x
        dex
        bpl -
        rts
.endif

; -----------------------------------------------------------------------------
; adsr_step - the envelope by stage: attack rises linearly to full, decay
; falls exponentially to the sustain level, sustain follows SUSTAIN,
; release falls exponentially to 0. When the release has faded (envelope
; below 1/256), the stage is idle and the gates close.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
adsr_step
        ; the sustain level as an envelope value: SUSTAIN x $1111 (15 = $FFFF)
        lda params+P_SUSTAIN
        sta tmp
        asl
        asl
        asl
        asl
        ora tmp                 ; SUSTAIN x $11
        sta sustain_lvl
        sta sustain_lvl+1

        ldx env_stage
        cpx #STAGE_ATTACK
        beq _attack
        cpx #STAGE_DECAY
        beq _decay
        cpx #STAGE_SUSTAIN
        beq _sustain
        cpx #STAGE_RELEASE
        beq _release
        rts                     ; idle

        ; attack: env += attack_inc[ATTACK]; past full: full, on to decay
_attack ldx params+P_ATTACK
        clc
        lda env_lo+ENV_ADSR
        adc attack_inc_lo,x
        sta env_lo+ENV_ADSR
        lda env_hi+ENV_ADSR
        adc attack_inc_hi,x
        sta env_hi+ENV_ADSR
        bcc _done
        lda #$ff
        sta env_lo+ENV_ADSR
        sta env_hi+ENV_ADSR
        lda #STAGE_DECAY
        sta env_stage
_done   rts

        ; decay: the part above the sustain level decays (in ENV_WORK)
_decay  sec
        lda env_lo+ENV_ADSR
        sbc sustain_lvl
        sta env_lo+ENV_WORK
        lda env_hi+ENV_ADSR
        sbc sustain_lvl+1
        sta env_hi+ENV_WORK
        bcc _to_sustain         ; already below it (SUSTAIN raised): sustain
        ldx params+P_DECAY
        lda decay_k_lo,x
        ldy decay_k_hi,x
        ldx #ENV_WORK
        jsr env_decay
        clc                     ; env = the rest + sustain level
        lda env_lo+ENV_WORK
        adc sustain_lvl
        sta env_lo+ENV_ADSR
        lda env_hi+ENV_WORK
        adc sustain_lvl+1
        sta env_hi+ENV_ADSR
        lda env_lo+ENV_WORK     ; the rest gone: sustain
        ora env_hi+ENV_WORK
        bne _done
_to_sustain
        lda #STAGE_SUSTAIN
        sta env_stage
        ; (on to sustain)

        ; sustain: the envelope at the sustain level (SUSTAIN may move)
_sustain
        lda sustain_lvl
        sta env_lo+ENV_ADSR
        lda sustain_lvl+1
        sta env_hi+ENV_ADSR
        rts

        ; release: decay to 0; faded out: idle, gates closed
_release
        ldx params+P_RELEASE
        lda decay_k_lo,x
        ldy decay_k_hi,x
        ldx #ENV_ADSR
        jsr env_decay
        lda env_hi+ENV_ADSR
        bne _done
        lda #STAGE_IDLE
        sta env_stage
        jmp note_gate_off

; -----------------------------------------------------------------------------
; glide_step_run - move pitch_cur towards pitch_tgt by glide_k[GLIDE]/256
; of the remaining distance (an exponential, RC-like glide, as SID303's
; slide). A note that doesn't glide already has pitch_cur = pitch_tgt.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
glide_step_run
        ; diff = target - current
        sec
        lda pitch_tgt
        sbc pitch_cur
        sta diff
        lda pitch_tgt+1
        sbc pitch_cur+1
        sta diff+1
        ora diff
        bne +
        sta note_glides         ; arrived (A = 0)
        rts
+       lda diff+1
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
        sbc glide_step
        sta pitch_cur
        lda pitch_cur+1
        sbc glide_step+1
        sta pitch_cur+1
        rts

        ; going up: add the step
_up     jsr _step_size
        clc
        lda pitch_cur
        adc glide_step
        sta pitch_cur
        lda pitch_cur+1
        adc glide_step+1
        sta pitch_cur+1
        rts

        ; step = diff * k / 256 = diff_hi*k + (diff_lo*k)/256; at least 1
        ; (when it rounds to 0 the remaining distance is taken in one go)
_step_size
        ldy params+P_GLIDE
        ldx glide_k,y
        lda diff
        jsr mul8
        sta tmp                 ; (diff_lo*k)/256
        ldy params+P_GLIDE
        ldx glide_k,y
        lda diff+1
        jsr mul8
        sta glide_step+1        ; diff_hi*k, 16 bit
        lda mul_lo
        clc
        adc tmp
        sta glide_step
        bcc +
        inc glide_step+1
+       lda glide_step
        ora glide_step+1
        bne +
        lda diff
        sta glide_step
        lda diff+1
        sta glide_step+1
+       rts

; -----------------------------------------------------------------------------
; lfo_step - the LFO's phase and its value 0..254 (lfo_tri) in the chosen
; shape: triangle; square (the phase's top bit); random, a new value at the
; start of each cycle (sample and hold); noise, a new value every tick (the
; rate does nothing). From it how far and which way it is from the middle
; (lfo_dev, lfo_neg) for the bipolar uses (vibrato, cutoff). While the fade
; after a fresh note runs, lfo_dev and lfo_tri are scaled by it (each from
; the unfaded shape, so a faded LFO sits at the middle and at PW's base).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
lfo_step
        ; phase += rate; a carry out of the high byte starts a new cycle
        ldx params+P_LFORATE
        clc
        lda lfo_phase
        adc lfo_inc_lo,x
        sta lfo_phase
        lda lfo_phase+1
        adc lfo_inc_hi,x
        sta lfo_phase+1         ; (A = the phase's high byte; ldx keeps the carry)
        ldx params+P_LFOSHAPE
        beq _triangle           ; LFO_TRIANGLE
        cpx #LFO_RANDOM         ; (cpx: the carry is lost here, so random reads
        bcc _square             ; the cycle's start from the phase instead)
        beq _random

        ; noise: a new value every tick
        jsr random_byte
        and #$fe                ; 0..254
        bcc _value              ; always (random_byte clears the carry)

        ; random: a new value when a cycle starts (the phase's high byte
        ; dropped below the last one), else the held one
_random lda lfo_phase+1
        cmp lfo_last
        sta lfo_last
        bcs _hold
        jsr random_byte
        and #$fe
        sta lfo_held
_hold   lda lfo_held
        jmp _value

        ; square: 254 in the first half of the cycle, 0 in the second
_square asl                     ; the phase's top bit to the carry
        lda #254
        bcc _value
        lda #0
        beq _value              ; always

        ; triangle: the phase's high byte, folded at the half way point
_triangle
        lda lfo_phase+1         ; (again: the flags are ldx's)
        bpl +
        eor #$ff                ; second half of the cycle: down again
+       asl
_value  sta lfo_tri
        ; distance from the middle (127), doubled: 0..254
        sec
        sbc #128
        bcs _above
        eor #$ff                ; below the middle: 127 - tri
        ldx #$80
        bne _dev                ; always
_above  ldx #0
_dev    stx lfo_neg
        asl
        sta lfo_dev

        ; the fade-in: full ($FFxx) = nothing to do
        lda lfo_fade+1
        cmp #$ff
        beq _done
        ldx params+P_LFODELAY
        clc
        lda lfo_fade
        adc lfo_fade_lo,x
        sta lfo_fade
        lda lfo_fade+1
        adc lfo_fade_hi,x
        sta lfo_fade+1
        bcc _scale
        lda #$ff                ; past full: full from here on
        sta lfo_fade
        sta lfo_fade+1
        rts
_scale  lda lfo_dev             ; scale both by the fade
        ldx lfo_fade+1
        jsr mul8
        sta lfo_dev
        lda lfo_tri
        ldx lfo_fade+1
        jsr mul8
        sta lfo_tri
_done   rts

; -----------------------------------------------------------------------------
; random_byte - the next random byte: 8 steps of the LFSR in rng at once,
; so that successive bytes share no bits by shifting. The 8 bits shifted
; out are the low byte's (the feedback, into bits 10 and up, can't reach
; bit 0 in 8 steps), so the steps come to rng >> 8 XOR a table entry for
; the low byte: lfsr8_lo/hi (tables.py), exactly the 8 shifts' result in
; a quarter of their time (the noise LFO runs it every tick).
; Out: A, carry clear. clobbers X
; -----------------------------------------------------------------------------
random_byte
        ldx rng                 ; the low byte: the bits shifted out
        lda rng+1               ; low = high XOR its feedback
        eor lfsr8_lo,x
        sta rng
        lda lfsr8_hi,x          ; high = its feedback (high >> 8 = 0)
        sta rng+1
        lda rng
        clc
        rts
        .cerror RNG_TAPS != LFSR8_TAPS, "tables.py's lfsr8 tables are for other taps"

; -----------------------------------------------------------------------------
; pitch_to_sid - pitch_cur + bend + tune + vibrato -> the SID frequencies,
; with linear interpolation between the semitones of freq_lo/freq_hi:
; voices 1 and 2 at the note, voice 3 (the sub) 1 or 2 octaves down.
; clobbers A, X, Y
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

        ; + tune ((TUNE - 16) x 8 = -128..+120: about +-half a semitone, from
        ; tune_lo/tune_hi) + the chord's note (C64 mode; 0 otherwise, whole
        ; semitones, signed: a negative one may take the sum below 0, clamped
        ; below) in one addition: every mode pays it, so it is kept short
        ldx params+P_TUNE
        clc
        lda pitch_sum
        adc tune_lo,x
        sta pitch_sum
        lda pitch_sum+1
        adc tune_hi,x
        clc
        adc chord_now
        sta pitch_sum+1

        ; + vibrato: lfo_dev x depth/256, depth = VIBRATO x 17 + the mod
        ; wheel (at most 255): up to about a semitone each way
        lda params+P_VIBRATO
        jsr times17
        clc
        adc params+P_MODWHEEL
        bcc +
        lda #255
+       cmp #0
        beq _clamp
        tax
        lda lfo_dev
        jsr mul8                ; A = 0..253 (256 = a semitone)
        cmp #0
        beq _clamp              ; (0: nothing to add, and -0 must not become -256)
        bit lfo_neg
        bpl +
        eor #$ff                ; below the middle: down
        clc
        adc #1
        ldx #$ff
        bne _vib                ; always
+       ldx #0
_vib    jsr _add_ax
_clamp
        ; clamp to the table: below 0 -> 0, above 95.255 -> 95.255
        lda pitch_sum+1
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

        ; the same pitch and sub type as last tick: the registers are right
        lda pitch_sum
        cmp pitch_last
        bne _new
        lda pitch_sum+1
        cmp pitch_last+1
        bne _new
        lda params+P_SUBTYPE
        cmp subtype_last
        bne _new
        rts
_new    lda pitch_sum
        sta pitch_last
        lda pitch_sum+1
        sta pitch_last+1
        lda params+P_SUBTYPE
        sta subtype_last

        ; the note's frequency: voice 1, and voice 2 in 101 mode (in Sync
        ; mode voice 2 has its own pitch: sync_update; in C64 mode it is the
        ; echo: c64_update)
        lda pitch_sum
        sta freq_pitch
        lda pitch_sum+1
        sta freq_pitch+1
        jsr freq_of_pitch
        lda freq_out
        sta SID_V1_FREQ_LO
        lda freq_out+1
        sta SID_V1_FREQ_HI
        lda params+P_VOICEMODE
        bne _not101
        lda freq_out            ; 101: voice 2 at the note too
        sta SID_V2_FREQ_LO
        lda freq_out+1
        sta SID_V2_FREQ_HI
        jmp _sub
_not101 cmp #VM_C64
        bne _sub
        lda freq_out            ; C64: kept for the echo
        sta lead_freq
        lda freq_out+1
        sta lead_freq+1
_sub
        ; voice 3: the sub, an octave (sub type 0) or two (1, 2) down
        lsr freq_out+1
        ror freq_out
        lda params+P_SUBTYPE
        beq +
        lsr freq_out+1
        ror freq_out
+       lda freq_out
        sta SID_V3_FREQ_LO
        lda freq_out+1
        sta SID_V3_FREQ_HI
        rts

        ; pitch_sum += A with high byte X
_add_ax clc
        adc pitch_sum
        sta pitch_sum
        txa
        adc pitch_sum+1
        sta pitch_sum+1
        rts

; -----------------------------------------------------------------------------
; freq_of_pitch - the SID frequency of pitch freq_pitch (hi = semitone index
; 0..95, lo = fraction), interpolated linearly between the semitones of
; freq_lo/freq_hi.
; Out: freq_out. clobbers A, X, Y
; -----------------------------------------------------------------------------
freq_of_pitch
        ; base = table[semi], span = table[semi+1] - table[semi]
        ldx freq_pitch+1
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
        ldx freq_pitch
        jsr mul8
        sta tmp
        lda freq_span+1
        ldx freq_pitch
        jsr mul8                ; A:mul_lo = span_hi * f
        tay
        lda mul_lo
        clc
        adc tmp
        bcc +
        iny
+       clc
        adc freq_base
        sta freq_out
        tya
        adc freq_base+1
        sta freq_out+1
        rts

; -----------------------------------------------------------------------------
; mode_update - the voice mode's own work: Sync mode's sync_update, C64
; mode's c64_update, nothing in 101 mode. clobbers A, X, Y
; -----------------------------------------------------------------------------
mode_update
        lda params+P_VOICEMODE
        cmp #VM_SYNC
        beq sync_update         ; (Sync, the heaviest mode, first: it follows)
        bcc +                   ; 101: nothing
        jmp c64_update
+       rts

; -----------------------------------------------------------------------------
; sync_update - Sync mode: voice 2's pitch = the note's (pitch_sum, with
; bend, tune and vibrato) + SYNC PITCH x 3/16 semitones + envelope x
; SYNC ENV x 3/16 semitones (each up to ~48 semitones: 4 octaves), at most
; the top of the table. Voice 2 is hard-synced to voice 1, so this is heard
; as the tearing timbre, not as a pitch. Nothing in 101 mode.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
SYNC_UNIT       = 48            ; pitch units (256 a semitone) per step of SYNC PITCH / SYNC ENV

sync_update
        ; offset = SYNC PITCH + envelope x SYNC ENV / 256, then x 48
        lda env_hi+ENV_ADSR
        ldx params+P_SYNCENV
        jsr mul8                ; 0..254
        clc
        adc params+P_SYNCPITCH
        sta freq_pitch          ; (low byte of the sum)
        lda #0
        rol
        sta freq_pitch+1        ; 0..509, 9 bits
        ; x 48 = x 32 + x 16: x 16 into tmp/tmp2, then x 3
        lda freq_pitch
        sta tmp
        lda freq_pitch+1
        sta tmp2
        ldx #4
-       asl tmp
        rol tmp2
        dex
        bne -                   ; tmp/tmp2 = x 16 (at most 8144)
        lda tmp                 ; x 3: + 2 x itself
        asl
        sta freq_pitch
        lda tmp2
        rol
        sta freq_pitch+1
        clc
        lda freq_pitch
        adc tmp
        sta freq_pitch
        lda freq_pitch+1
        adc tmp2
        sta freq_pitch+1        ; x 48: at most 24432 (95 semitones)
        ; + the note's pitch, at most the table's top
        clc
        lda freq_pitch
        adc pitch_sum
        sta freq_pitch
        lda freq_pitch+1
        adc pitch_sum+1
        sta freq_pitch+1
        bcs _top
        cmp #HIGHEST_NOTE-LOWEST_NOTE+1
        bcc _write
_top    lda #HIGHEST_NOTE-LOWEST_NOTE
        sta freq_pitch+1
        lda #$ff
        sta freq_pitch
_write  jsr freq_of_pitch
        lda freq_out
        sta SID_V2_FREQ_LO
        lda freq_out+1
        sta SID_V2_FREQ_HI
        rts

; -----------------------------------------------------------------------------
; c64_update - C64 mode, each tick: the attack click's end (the lead's
; pulse back: gates_write), the chord's next note when its time comes, the
; PWM sweep's phase (pw_update reads it), and
; the echo: voice 2 becomes voice 1 as it was ECHO_LEN ticks ago (its
; frequency, control byte, pulse width; its level that level x Saw / 15),
; and this tick's voice 1 goes into the ring in its place. A retrigger
; then (ECHO_RETRIG) retriggers voice 2 now: its gate off and on again.
; Saw 0: the echo stays ungated (a gated voice at level 0 still clicks).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
c64_update
        ; the click: its last tick puts the pulse back
        lda click_left
        beq +
        dec click_left
        bne +
        jsr gates_write
+
        ; the chord: its next note every Chord speed frames (heard from the
        ; next tick's pitch_to_sid)
        lda chord_len
        beq _no_chord
        dec chord_wait
        bne _no_chord
        ldx chord_pos
        inx
        cpx chord_len
        bcc +
        ldx #0
+       stx chord_pos
        lda chord_offs,x
        sta chord_now
        ldx params+P_CHORDSPEED
        lda chord_ticks,x
        sta chord_wait
_no_chord
        ; the sweep: phase += its rate (PWM 0: rate 0)
        ldx params+P_PWM
        clc
        lda sweep_phase
        adc sweep_rate_lo,x
        sta sweep_phase
        lda sweep_phase+1
        adc sweep_rate_hi,x
        sta sweep_phase+1

        ; the echo out: a retrigger's gate off, the level, the control byte
        ldx echo_pos
        lda params+P_SAW
        beq _quiet
        lda echo_ctrl,x
        and #ECHO_RETRIG
        beq +
        lda echo_ctrl,x         ; retriggered: the gate off first (a level raised
        and #~(ECHO_RETRIG | GATE) ; with the gate open would not be followed)
        sta SID_V2_CTRL
+       lda params+P_SAW        ; the level: Saw x voice 1's then
        asl
        asl
        asl
        asl
        ora echo_level,x
        tay
        lda level_tab,y
        sta v2_level            ; (levels_write writes it too)
        asl
        asl
        asl
        asl
        sta SID_V2_SR
        lda echo_ctrl,x
        and #~ECHO_RETRIG
        jmp _ctrl
_quiet  lda #0                  ; Saw 0: never gated (levels_write: level 0)
        sta v2_level
        lda echo_ctrl,x
        and #~(ECHO_RETRIG | GATE)
_ctrl   sta SID_V2_CTRL
        lda echo_freq_lo,x
        sta SID_V2_FREQ_LO
        lda echo_freq_hi,x
        sta SID_V2_FREQ_HI
        lda echo_pw_lo,x
        sta SID_V2_PW_LO
        lda echo_pw_hi,x
        sta SID_V2_PW_HI

        ; this tick's voice 1 in its place
        lda lead_freq
        sta echo_freq_lo,x
        lda lead_freq+1
        sta echo_freq_hi,x
        lda lead_ctrl
        ora lead_retrig
        sta echo_ctrl,x
        lda v1_level
        sta echo_level,x
        lda pw_out
        sta echo_pw_lo,x
        lda pw_out+1
        sta echo_pw_hi,x
        lda #0
        sta lead_retrig
        inx
        txa
        and #ECHO_LEN-1
        sta echo_pos
        rts

; -----------------------------------------------------------------------------
; echo_clear - the echo silent: every slot ungated, voice 2's gate off (at
; start, a voice mode change, all notes off); no click, no chord. clobbers A, X
; -----------------------------------------------------------------------------
; chord_note - C64 mode: the chord again after a note event (chord_build);
; other modes: nothing. clobbers A, X, Y
; -----------------------------------------------------------------------------
chord_note
        lda params+P_VOICEMODE
        cmp #VM_C64
        beq chord_build
        rts

; -----------------------------------------------------------------------------
; chord_build - C64 mode's chord, from its start, for the held keys and
; Chord (decided with the user, design.md section 2):
;   Off             no chord: a plain mono lead (legato, glide)
;   several keys    (Keys or a shape) the held keys, upwards from the
;                   sounding one (the newest) and round: the first step is
;                   that note, so a legato overlap of a tick sounds no other
;   one key, shape  the shape's intervals over it (chord_shapes)
;   no key held     the chord plays on into the release, unchanged
; Its notes are semitones from the sounding note (chord_offs); the first
; plays now, each for the Chord speed's frames (chord_ticks). Called on
; note events, a Chord or Voice mode change and a preset recall: never every
; tick. clobbers A, X, Y
; -----------------------------------------------------------------------------
CHORD_OFF       = 0             ; P_CHORD values (chord_names)
CHORD_KEYS      = 1
CHORD_SHAPE     = 2             ; the first shape

chord_build
        lda params+P_VOICEMODE
        cmp #VM_C64
        bne _none
        lda params+P_CHORD
        beq _none               ; Off
        ldx note_count
        bne _held
        rts                     ; nothing held: as it was (the release)
_none   lda #0                  ; no chord
        sta chord_len
        sta chord_now
        rts
_held   cpx #2
        bcs _keys
        cmp #CHORD_SHAPE        ; one key: a shape, or (Keys) no chord
        bcc _none

        ; one key: the shape's intervals
        sec
        sbc #CHORD_SHAPE
        tax
        ldy chord_shape_at,x    ; the shape in chord_shapes: its length, its notes
        lda chord_shapes,y
        sta chord_len
        ldx #0
-       lda chord_shapes+1,y
        sta chord_offs,x
        iny
        inx
        cpx chord_len
        bcc -
        bcs _start              ; always

        ; several keys: sorted upwards (insertion sort, at most STACK_SIZE)
_keys   stx chord_len
        dex
-       lda note_stack,x
        sta chord_sorted,x
        dex
        bpl -
        ldx #1
_outer  cpx chord_len
        bcs _sorted
        lda chord_sorted,x
        sta tmp                 ; the key to place
        txa
        tay                     ; Y: where it may go
_inner  lda chord_sorted-1,y    ; the one below it
        cmp tmp
        bcc _place              ; lower: it goes here
        sta chord_sorted,y      ; higher: that one moves up
        dey
        bne _inner
_place  lda tmp
        sta chord_sorted,y
        inx
        bne _outer              ; always

        ; from the sounding key (the newest held) upwards and round, each
        ; as semitones from it
_sorted ldx note_count
        lda note_stack-1,x
        sta tmp                 ; the sounding key
        ldy #0
-       cmp chord_sorted,y      ; (the keys differ: it is there)
        beq +
        iny
        bne -
+       ldx #0
-       lda chord_sorted,y
        sec
        sbc tmp
        sta chord_offs,x
        iny
        cpy chord_len
        bcc +
        ldy #0
+       inx
        cpx chord_len
        bcc -

        ; from its first note (0: the note itself), a step's wait
_start  lda #0
        sta chord_pos
        sta chord_now
        ldx params+P_CHORDSPEED
        lda chord_ticks,x
        sta chord_wait
        rts

; the shapes (P_CHORD from CHORD_SHAPE, chord_names): each its length and
; its intervals in semitones, the note itself first
SHAPES  = ((0, 4, 7), (0, 3, 7), (0, 4, 7, 10), (0, 3, 7, 10), (0, 4, 7, 11), (0, 5, 7), (0, 7), (0, 12), (0, 3, 6))
chord_shapes
                .for _s in SHAPES
                .byte len(_s), _s
                .endfor
chord_shape_at
_at             := 0
                .for _s in SHAPES
                .byte _at
_at             := _at + len(_s) + 1
                .endfor
        .cerror len(SHAPES) != CHORDS - CHORD_SHAPE, "a shape for each of chord_names' shapes"
; the Chord speed's step, in ticks: 1..8 frames
chord_ticks     .for _f := 1, _f <= 8, _f += 1
                .byte _f * FRAME_TICKS
                .endfor

; -----------------------------------------------------------------------------
echo_clear
        lda #0
        sta click_left
        sta chord_len           ; no chord either
        sta chord_now
        ldx #ECHO_LEN-1
-       sta echo_ctrl,x
        sta echo_level,x
        dex
        bpl -
        lda params+P_VOICEMODE
        cmp #VM_C64
        bne +
        lda #0
        sta SID_V2_CTRL         ; (other modes: gates_write owns voice 2)
+       rts

; -----------------------------------------------------------------------------
; filter_update - log-cutoff index = CUTOFF + env x ENVMOD/512 (ENVMOD
; plus the note's accent boost; up to ~4
; octaves) +- lfo_dev x LFOCUT/15 / 4 (up to ~2 octaves each way), clamped
; to 0..255; then the 8580 register value from cutoff_lo/cutoff_hi.
; Resonance, routing, mode and volume are written here too.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
filter_update
        ; cutoff + envelope x (ENVMOD + the note's accent boost, at most 255)
        lda params+P_ENVMOD
        clc
        adc acc_boost
        bcc +
        lda #255
+       tax
        lda env_hi+ENV_ADSR
        jsr mul8
        lsr                     ; /512 in all
        clc
        adc params+P_CUTOFF
        sta cut_sum
        lda #0
        adc #0
        sta cut_sum+1           ; cut_sum is signed 16 bit from here on

        ; +- the LFO
        lda params+P_LFOCUT
        beq _clamp
        jsr times17
        tax
        lda lfo_dev
        jsr mul8                ; 0..253
        lsr
        lsr                     ; 0..63: up to ~2 octaves (31 steps an octave)
        bit lfo_neg
        bmi _down
        clc
        adc cut_sum
        sta cut_sum
        bcc _clamp
        inc cut_sum+1
        bne _clamp              ; always
_down   sta tmp
        sec
        lda cut_sum
        sbc tmp
        sta cut_sum
        bcs _clamp
        dec cut_sum+1

        ; clamp to 0..255
_clamp  lda cut_sum+1
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

        ; resonance and routing, mode and volume
        lda params+P_RESO
        asl
        asl
        asl
        asl
        ora #FILTER_ROUTING
        sta SID_RES_FILT
        lda params+P_VOLUME
        ora #MODE_LOWPASS
        sta SID_MODE_VOL
        rts

; -----------------------------------------------------------------------------
; pw_update - the lead's pulse width (voice 2's; C64 mode: voice 1's): the
; PW setting, narrowed by a modulation x 6 (up to $5F0), never below PW_MIN.
; 101 mode: the LFO (lfo_tri x PWM/15); C64 mode: its own sweep, a triangle
; of sweep_phase at full depth (PWM 0: none), and 50 % while a square click
; sounds; Sync mode: none (voice 2 is a saw). Voice 3's from the sub type
; (50 %, or 25 % for type 2).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
PW_MIN          = $0080         ; narrowest pulse: ~3 %
PW_SQUARE       = $0800         ; 50 %
PW_QUARTER      = $0400         ; 25 %
SUBTYPE_PULSE   = 2             ; P_SUBTYPE: the 25 % pulse two octaves down
CLICK_SQUARE    = 7             ; P_CLICK from here: a square click (click_names)

pw_update
        ; voice 3: square, or the 25 % pulse
        lda #<PW_SQUARE
        sta SID_V3_PW_LO
        ldx #>PW_SQUARE
        lda params+P_SUBTYPE
        cmp #SUBTYPE_PULSE
        bne +
        ldx #>PW_QUARTER
+       stx SID_V3_PW_HI

        lda params+P_VOICEMODE  ; Sync mode: voice 2 is a saw, no pulse width
        cmp #VM_SYNC
        bne +
        rts
+       ldx params+P_PW
        lda pw_base_lo,x
        sta pw_out
        lda pw_base_hi,x
        sta pw_out+1

        ; the modulation: A = 0..254 (the LFO or the sweep), X = its depth
        lda params+P_PWM
        beq _write
        ldx params+P_VOICEMODE
        bne _sweep              ; (not Sync: C64)
        jsr times17             ; 101 mode: the LFO x PWM
        tax
        lda lfo_tri
        jmp _mod
_sweep  lda sweep_phase+1       ; C64 mode: the sweep's triangle at full depth: as
        asl                     ; is, no multiply (x 255/256 would change it by
        bcc _depth              ; at most 1 in 254; the tick has no room for it
        eor #$fe                ; with a chord playing). The falling half here
        bcs _depth              ; always (carry set from the asl)

        ; subtract A x X / 256 x 6
_mod    jsr mul8                ; A = 0..253
_depth  sta tmp
        lda #0
        sta tmp2
        asl tmp                 ; x 2
        rol tmp2
        lda tmp                 ; save x 2 ...
        pha
        lda tmp2
        pha
        asl tmp                 ; ... x 4
        rol tmp2
        pla                     ; x 6 = x 4 + x 2
        tay
        pla
        clc
        adc tmp
        sta tmp
        tya
        adc tmp2
        sta tmp2
        sec
        lda pw_out
        sbc tmp
        sta pw_out
        lda pw_out+1
        sbc tmp2
        sta pw_out+1
        bcc _min                ; below 0: the narrowest
        cmp #>PW_MIN
        bne _write
        lda pw_out
        cmp #<PW_MIN
        bcs _write
_min    lda #<PW_MIN
        sta pw_out
        lda #>PW_MIN
        sta pw_out+1
_write  lda params+P_VOICEMODE
        cmp #VM_C64
        beq _lead
        lda pw_out
        sta SID_V2_PW_LO
        lda pw_out+1
        sta SID_V2_PW_HI
        rts
_lead   lda click_left          ; C64 mode: voice 1, 50 % while a square click sounds
        beq +
        lda params+P_CLICK
        cmp #CLICK_SQUARE
        bcc +
        lda #<PW_SQUARE
        sta pw_out
        lda #>PW_SQUARE
        sta pw_out+1
+       lda pw_out
        sta SID_V1_PW_LO
        lda pw_out+1
        sta SID_V1_PW_HI
        rts
        .cerror (PW_SQUARE & $ff) != 0 || (PW_QUARTER & $ff) != 0, "pw_update writes only the high bytes"

; -----------------------------------------------------------------------------
; levels_update - each voice's sustain level = its mix level x the amp
; envelope (Env mode: full while the attack runs, then the ADSR; Gate
; mode: full) x the note's accent level (acc_vel4), from level_tab (mix x 16 + amp / 16: both 4 bits, as is the
; result). A level never goes up during a note: the SID wouldn't follow (it
; decays a voice whose sustain is raised). The registers are written only
; when a level changed.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
levels_update
        lda gate_bit
        beq _done               ; gates closed: nothing sounds
        ; the amp envelope's top 4 bits
        lda #$f0
        ldx params+P_AMPMODE
        cpx #AMP_GATE
        beq +
        ldx env_stage
        cpx #STAGE_ATTACK
        beq +
        lda env_hi+ENV_ADSR
+       and #$f0                ; x the note's accent: level_tab[amp x 16 + acc_vel4]
        ora acc_vel4            ; (15 without accent: amp itself)
        tax
        lda level_tab,x
        sta amp4

        ; each voice: mix x amp, never above its last level; Y counts
        ; changes. C64 mode: voice 1 is the pulse lead, voice 2 the echo
        ; (c64_update sets its level)
        ldy #0
        lda params+P_VOICEMODE
        cmp #VM_C64
        beq _c64
        lda params+P_SAW
        jsr _level
        cmp v1_level
        bcs +
        sta v1_level
        iny
+       lda params+P_PULSE
        jsr _level
        cmp v2_level
        bcs _sub
        sta v2_level
        iny
_sub    lda params+P_SUB
        jsr _level
        cmp v3_level
        bcs +
        sta v3_level
        iny
+       tya
        beq _done
        jmp levels_write
_done   rts

        ; C64 mode (after the rest: 101 and Sync run straight through)
_c64    lda params+P_PULSE
        jsr _level
        cmp v1_level
        bcs _sub
        sta v1_level
        iny
        bne _sub                ; always

        ; A = level_tab[mix level A x 16 + amp4]. clobbers X
_level  asl
        asl
        asl
        asl
        ora amp4
        tax
        lda level_tab,x
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
