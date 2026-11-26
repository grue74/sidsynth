; voices.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Voice allocation (docs/design.md 4) and filter ownership (6): a hit takes
; the voice already playing its choke group, else an idle voice, else the
; voice with the lowest level x priority. A sound with a ring version
; (cowbell) first looks for a voice pair: a voice and its ring partner, which
; is lent to it (lent) while it sounds. The core calls note_on, note_off
; and all_notes_off; they run in the main loop, never during synth_tick.

        .section zp
filter_owner    .byte ?         ; voice whose steps set the filter, VOICE_IDLE = none
sid_mode        .byte ?         ; filter mode bits for $D418 (combined with the volume)
new_sound       .byte ?         ; note_on: the sound to start
new_vel         .byte ?         ; note_on: its velocity 1..127
new_group       .byte ?         ; voice_pick: its choke group
best_score      .byte ?         ; voice_pick: lowest score so far
best_voice      .byte ?         ;             and its voice
new_score       .byte ?         ; voice_pick: the new hit's score
score_ptr       .word ?         ; voice_pick: a sound's page of score_tab (low byte 0)
new_partner     .byte ?         ; voice_pick: the ring partner found for new_sound, NO_PARTNER = none
v_partner       .fill NUM_VOICES ; the voice lent to each voice as ring partner, NO_PARTNER = none
lent            .byte ?         ; voices (voice_bit) lent as ring partners: idle, but not free
pair_room       .byte ?         ; voice_pick: voices a ring pair must leave free: 0 (MIDI
                                ; notes), or PAIR_ASK: the sequencer's hits still to come
                                ; in the step (hits_after)
pick_keep       .byte ?         ; voice_pick: voices (voice_bit) 4. must not steal; 0 but
                                ; while the sequencer fires a step (seq_hits)
last_vel        .byte ?         ; status row: velocity of the last hit
v_rand          .fill NUM_VOICES ; random value of each voice's hit (filter variation)
rng             .byte ?         ; random generator state, never 0 (synth_init seeds it)
filt_set        .byte ?         ; filter_apply: the filter setting
filt_voice      .byte ?         ;               the voice
filt_sum        .byte ?         ;               velocity part of the cutoff
filt_routes     .byte ?         ; voices routed through the filter ($D417 bits 0-2)
filt_res        .byte ?         ; resonance bits ($D417 bits 4-7) of the setting in use
        .send

RNG_SEED        = $5a           ; any nonzero value
NO_PARTNER      = $ff
PAIR_ASK        = $ff           ; pair_room: count the step's later hits (hits_after)
RNG_TAPS        = $1d           ; Galois LFSR feedback: x^8 + x^4 + x^3 + x^2 + 1, period 255

; -----------------------------------------------------------------------------
; note_on - hook: MIDI note on or a note key. A: MIDI note, X: velocity
; 1..127. Notes without a sound (note_sound = $FF) are ignored.
; -----------------------------------------------------------------------------
note_on
        stx new_vel
        stx last_vel
        sec
        sbc #GM_FIRST
        bcc _none
        cmp #GM_LAST-GM_FIRST+1
        bcs _none
        tax
        lda note_sound,x
        bmi _none               ; $FF: no sound on this note
        sta new_sound
        jmp sound_hit
_none   rts

; -----------------------------------------------------------------------------
; sound_hit - a hit played live (note_on, the grid's tap key): recorded
; when live record is on (rec_hit), and played now. new_sound, new_vel: the
; hit. clobbers A, X, Y
; -----------------------------------------------------------------------------
sound_hit
        jsr rec_hit
        jsr voice_pick
        bcs +                   ; dropped: everything sounding matters more
        jmp voice_start
+       rts

; -----------------------------------------------------------------------------
; note_off - hook: drums are one-shot, a note off does nothing.
; -----------------------------------------------------------------------------
note_off
        rts

; -----------------------------------------------------------------------------
; all_notes_off - hook (F8, RUN/STOP, CC 120/123, channel change): stop
; every voice.
; -----------------------------------------------------------------------------
all_notes_off
        ldx #NUM_VOICES-1
-       lda v_sound,x
        cmp #VOICE_IDLE
        beq +
        stx vx
        jsr voice_end
        ldx vx
+       dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; voice_pick - the voice for new_sound.
;   1. a voice playing the same choke group is choked: it fades out (a closed
;      hat chokes an open one, a new kick ends the old kick's tail)
;   2. an idle voice that is silent: the new hit starts at once
;   3. an idle voice still fading out: the one nearest to silent
;   4. the voice with the lowest score = level x sound priority / 256, but
;      only if the new hit scores higher (velocity x 2 x its priority / 256);
;      voices in pick_keep (a sequencer step's earlier hits) and lent ring
;      partners are not taken (a partner goes free with its sound);
;      else the new hit is dropped: in a crowd the least important sound is
;      the one lost, whether it is sounding or new (a soft maraca no longer
;      cuts off a clap; measured in the demo track's full section)
; With 3. and 4. the new hit waits for the fade (voice_start). A hat roll on
; an otherwise empty machine alternates voices, so no hit waits.
; The scores come from score_tab (tables.py), so a busy step's dropped hits
; are cheap.
; Before 2., a sound with a ring version (sound_ring) tries for a voice
; pair (pair_free) if the free voices leave pair_room for the step's later
; hits: found, new_partner = the partner; else NO_PARTNER and the sound
; plays its one-voice program.
; Out: X = voice, carry clear; carry set = dropped. clobbers A, Y
; -----------------------------------------------------------------------------
voice_pick
        ; 1. same choke group: fade it out
        ldy new_sound
        lda sound_group,y
        sta new_group
        ldx #NUM_VOICES-1
_choke  ldy v_sound,x
        cpy #VOICE_IDLE
        beq +
        lda sound_group,y
        cmp new_group
        bne +
        stx vx
        jsr voice_end
        ldx vx
+       dex
        bpl _choke

        ; a sound with a ring version: a voice pair if one is free - a
        ; voice idle (silent first, else fading) whose partner is idle,
        ; silent and not lent; else the one-voice program, as any sound
        lda #NO_PARTNER
        sta new_partner
        ldy new_sound
        lda sound_ring_hi,y
        beq _two
        ; enough free voices: the pair, and one for each hit still to come
        ; in the step (else the pair would starve them)
        ldy #0
        ldx #NUM_VOICES-1
-       lda v_sound,x
        cmp #VOICE_IDLE
        bne +
        lda voice_bit,x
        and lent
        bne +
        iny                     ; idle and not lent
+       dex
        bpl -
        tya
        sec
        sbc #2
        bcc _two                ; under 2 free
        ldy pair_room
        cpy #PAIR_ASK
        bne +
        pha
        jsr hits_after          ; (only now: it takes a while)
        sta pair_room
        pla
+       cmp pair_room
        bcc _two                ; the rest of the step would go short
        ldy #0                  ; pass 1: the voice silent too
_pair   ldx #0
-       jsr pair_free
        bcc _paired
        inx
        cpx #NUM_VOICES
        bne -
        iny
        cpy #2                  ; pass 2: the voice may still be fading
        bne _pair
        beq _two                ; no pair
_paired lda partner_of,x
        sta new_partner
        clc
        rts

        ; 2. idle and silent (lent partners are not free)
_two    ldx #0
-       lda v_sound,x
        cmp #VOICE_IDLE
        bne +
        lda voice_bit,x
        and lent
        bne +
        lda v_fade,x
        beq _found
+       inx
        cpx #NUM_VOICES
        bne -

        ; 3. idle but fading: the fewest fade ticks left
        lda #$ff
        sta best_score
        ldx #NUM_VOICES-1
-       lda v_sound,x
        cmp #VOICE_IDLE
        bne +
        lda voice_bit,x
        and lent
        bne +
        lda v_fade,x
        cmp best_score
        bcs +
        sta best_score
        stx best_voice
+       dex
        bpl -
        lda best_score
        cmp #$ff
        bne _best

        ; 4. every voice sounds: the lowest score, if below the new hit's
        ; (score_tab: the sound's page, indexed by velocity x 2 or level)
        lda new_sound
        clc
        adc #>score_tab
        sta score_ptr+1
        lda new_vel
        asl
        tay
        lda (score_ptr),y       ; velocity x 2 x priority / 256
        sta new_score
        lda #0
        sta best_voice
        ldx #0
_score  lda pick_keep
        ora lent
        and voice_bit,x
        bne +                   ; taken by an earlier hit of this step, or lent: keep it
        lda v_sound,x
        clc
        adc #>score_tab
        sta score_ptr+1
        ldy env_hi,x
        lda (score_ptr),y       ; level x priority / 256
        cmp best_score
        bcs +                   ; not lower: the earlier voice wins a tie
        sta best_score
        stx best_voice
+       inx
        cpx #NUM_VOICES
        bne _score
        lda best_score
        cmp new_score
        bcc _best               ; the quietest matters less than the new hit
        rts                     ; carry set: drop the new hit
_best   ldx best_voice
_found  clc
        rts

; -----------------------------------------------------------------------------
; pair_free - can voice X take a ring sound? X idle and not lent (Y = 0:
; silent too, Y = 1: may be fading); its partner idle, silent, not lent.
; Out: carry clear = yes. preserves X, Y; clobbers A
; -----------------------------------------------------------------------------
pair_free
        lda v_sound,x
        cmp #VOICE_IDLE
        bne _no
        lda voice_bit,x
        and lent
        bne _no
        cpy #0
        bne +
        lda v_fade,x
        bne _no                 ; pass 1: still fading
+       stx best_voice          ; (scratch: X back below)
        lda partner_of,x
        tax
        lda v_sound,x
        cmp #VOICE_IDLE
        bne _no_x
        lda v_fade,x
        bne _no_x
        lda voice_bit,x
        and lent
        bne _no_x
        ldx best_voice
        clc
        rts
_no_x   ldx best_voice
_no     sec
        rts

; the voice whose oscillator ring-modulates each voice (SID: 1 <- 3, 2 <- 1, 3 <- 2)
partner_of      .byte 2, 0, 1

; -----------------------------------------------------------------------------
; voice_start - start new_sound (velocity new_vel) on voice X. A sound still
; playing there fades out first (voice_end; cutting it off at once would
; click). The new sound's program, velocity and level are set now; it is
; launched (voice_launch) at once if the voice is silent, else by voice_tick
; when the fade is over. While launched is set (inside synth_tick: a launch
; was made, or the sequencer starts hits) a silent voice gets v_fade = 1
; instead: the next tick's voice_tick launches it (one launch per tick).
; X: voice. clobbers A, X, Y
; -----------------------------------------------------------------------------
voice_start
        stx vx
        lda v_sound,x
        cmp #VOICE_IDLE
        beq +
        jsr voice_end           ; still sounding (stolen): fade it out
+
        ; the program (with a partner: the ring version, the partner lent)
        ; and velocity
        ldy new_sound
        tya
        sta v_sound,x
        lda new_partner
        sta v_partner,x
        cmp #NO_PARTNER
        beq _one
        tay
        lda voice_bit,y
        ora lent
        sta lent
        ldy new_sound
        lda sound_ring_lo,y
        sta v_ptr_lo,x
        sta prog
        lda sound_ring_hi,y
        jmp _prog
_one    lda sound_prog_lo,y
        sta v_ptr_lo,x
        sta prog
        lda sound_prog_hi,y
_prog   sta v_ptr_hi,x
        sta prog+1
        lda new_vel
        asl                     ; 1..127 -> 2..254
        sta v_vel,x

        ; the sound's knobs (knobs.asm): Level scales the velocity (not
        ; new_vel: steal scores, record and MIDI out keep the hit's own),
        ; Tune and Decay are kept for step_load and voice_tick
        ldy new_sound
        lda knob_tune,y
        sta v_tune,x
        lda knob_decay,y
        tay
        lda decay_speed,y
        sta v_dspeed,x
        lda #0
        sta v_dacc,x
        sta v_tfirst,x
        ldy new_sound
        lda knob_tone,y         ; Tone: as a Tune knob value
        tay
        lda tone_tune,y
        sta v_tone,x
        cmp #TUNE_CENTER
        beq +                   ; at the default: nothing to do
        ldy #S_FILTER
        lda (prog),y
        bne +                   ; filtered: on the cutoff (filter_apply)
        inc v_tfirst,x          ; else on the first step's start pitch (step_load)
+       ldy new_sound
        lda knob_level,y
        cmp #LEVEL_MAX
        beq +                   ; full: the velocity as it is
        tay
        lda level_factor,y
        tax
        lda new_vel
        asl
        jsr mul8                ; A = velocity x 2 x level / 15; clobbers X, Y
        ldx vx
        sta v_vel,x
+

        ; a new random value for this hit (8-bit Galois LFSR step)
        lda rng
        asl
        bcc +
        eor #RNG_TAPS
+       sta rng
        sta v_rand,x

        ; this hit's pitch raise: velocity x sound_velpitch + random part
        ldy new_sound
        lda sound_velpitch,y
        beq +
        ldy v_vel,x
        tax
        tya
        jsr mul8                ; A = velocity x 2 x velpitch / 256; clobbers X, Y
        ldx vx
        ldy new_sound
+       sta ps_hi
        lda v_rand,x
        eor #$a5                ; other bits than the filter variation's
        and sound_detune,y
        clc
        adc ps_hi
        sta v_pk,x
        lda #0
        sta v_left,x            ; first tick after the mute loads step 0

        ; the starting level = first step's level x velocity
        ldy #S_LEVEL
        lda (prog),y
        ldy v_vel,x
        tax
        tya
        jsr mul8                ; clobbers X, Y
        ldx vx
        sta env_hi,x
        lda #0
        sta env_lo,x

        ; launch now if the voice is silent, else when its fade is over;
        ; if no launch may be made now, on the next tick
        lda v_fade,x
        bne _wait
        lda launched
        bne _next_tick
        jmp voice_launch
_next_tick
        lda #1                  ; the next tick's voice_tick counts it to 0: launch
        sta v_fade,x
_wait   rts

; -----------------------------------------------------------------------------
; voice_launch - begin voice X's new sound (voice_start set it up): the
; attack mute phase begins with the gate off and the oscillator parked at
; its silent midpoint (osc_park); the next ticks raise the gate (voice_tick).
; Called by voice_start, or by voice_tick after a fade or a delayed launch.
; Sets launched (one launch per synth_tick).
; X: voice. clobbers A, X, Y, prog
; -----------------------------------------------------------------------------
voice_launch
        lda #1
        sta launched            ; one launch per tick (synth_tick)
        stx vx
        lda v_ptr_lo,x          ; the program's first step (not started yet)
        sta prog
        lda v_ptr_hi,x
        sta prog+1

        ; SID: every rate 0, sustain at the level, gate off, oscillator
        ; parked at its silent midpoint
        ldy voice_reg,x
        lda #0
        sta SID_V1_AD,y
        lda env_hi,x
        and #$f0
        sta SID_V1_SR,y
        jsr osc_park
        ldx vx

        ; a ring version: the partner's oscillator at the sound's partner
        ; frequency, its gate off (the partner is silent: idle, its level 0)
        ldy v_partner,x
        cpy #NO_PARTNER
        beq +
        lda voice_reg,y
        tay
        lda v_sound,x
        tax
        lda ring_freq_lo,x
        sta tune_f
        lda ring_freq_hi,x
        sta tune_f+1
        sty tune_x              ; (the partner's register offset)
        ldx vx
        ldy v_tune,x            ; tuned with the sound, so the pair keeps its ratio
        cpy #TUNE_CENTER
        beq +
        jsr tune_word
+       ldy tune_x
        lda tune_f
        sta SID_V1_FREQ_LO,y
        lda tune_f+1
        sta SID_V1_FREQ_HI,y
        lda #TRIANGLE           ; running, no gate, no test bit
        sta SID_V1_CTRL,y
        ldx vx
+

        ; filter, set while the voice is parked and silent: a routing or mode
        ; change while a voice sounds makes a DC jump (a snap; measured on the
        ; hats). A sound that starts filtered takes the filter now, with its
        ; first step's setting (step 0 then rewrites the same values); the
        ; old owner stays routed, its tail goes on through the new setting -
        ; unless that is another filter mode and the old owner still sounds
        ; more important (filter_keep): then the new sound plays unfiltered.
        ; A sound that starts unfiltered takes this voice out of the routing.
        ldy #S_FILTER
        lda (prog),y
        beq _unfiltered
        jsr filter_keep
        bcs _unfiltered         ; the owner keeps the filter
        ldy #S_FILTER
        lda (prog),y            ; (filter_keep took A)
        stx filter_owner
        jsr filter_apply
        jmp _mute
_unfiltered
        lda voice_bit,x
        eor #$ff
        and filt_routes
        sta filt_routes
        ora filt_res
        sta SID_RES_FILT
_mute

        ; mute ticks: until the envelope has settled at the level
.if MUTE_SETTLE
        lda env_hi,x
        lsr
        lsr
        lsr
        lsr
        tay
        lda mute_ticks,y
.else
        lda #2                  ; one tick of gate on (the attack), then the waveform
.endif
        sta v_mute,x
        rts

; -----------------------------------------------------------------------------
; filter_keep - may voice X's new sound take the filter (setting A)? Not if
; the setting's mode differs from the one in use and the owner still sounds
; and either holds the filter (sound_fhold: the cowbell, whose pulse and
; ring-modulated edges came out as snaps through the hats' high-pass) or
; has a higher score (score_tab: level x priority) than the new sound's
; starting level gives (a soft hat doesn't turn a loud clap's band-pass
; into a high-pass). The same mode is taken over as before (hats over a
; cymbal: a cutoff change). A new sound refused plays unfiltered.
; X: voice (preserved). Out: carry set = the owner keeps it. clobbers A, Y
; -----------------------------------------------------------------------------
filter_keep
        tay
        lda filt_mode,y
        cmp sid_mode
        beq _take               ; the same mode
        ldy filter_owner
        cpy #VOICE_IDLE
        beq _take               ; nobody's
        lda v_sound,y           ; (the owner sounds: voice_end frees the filter)
        tay
        lda sound_fhold,y
        bne _keep               ; held while it sounds
        tya
        clc
        adc #>score_tab
        sta score_ptr+1
        ldy filter_owner
        lda env_hi,y
        tay
        lda (score_ptr),y       ; the owner's score
        sta best_score          ; (voice_pick's scratch: free here)
        lda v_sound,x
        clc
        adc #>score_tab
        sta score_ptr+1
        ldy env_hi,x
        lda (score_ptr),y       ; the new sound's
        cmp best_score          ; carry clear: lower, the owner keeps it
        bcs _take
_keep   sec
        rts
_take   clc
        rts

; -----------------------------------------------------------------------------
; osc_park - stop voice Y's oscillator a quarter cycle in, triangle selected,
; gate off. The triangle is then at its midpoint ($800), which is the 8580
; waveform DAC's zero: the voice is silent whatever its envelope does, so
; the attack mute phase makes no sound (the test bit alone would hold the
; output at 0 = full negative, and the rising envelope would thump), and
; the first step starts at a zero crossing.
;
; How: the test bit resets the accumulator to 0; then it runs at frequency
; $FFFF for 64 cycles and the frequency is set to 0: 64 x $FFFF = $3FFFC0,
; a quarter of the 24-bit cycle, triangle $7FF. The accumulator starts 3
; cycles after the control write, so the writes are 67 cycles apart
; (measured in VICE, 8580, by reading voice 3 back through OSC3: 8 trials
; each of 53..73 cycles all read 3 cycles short). The wait is cycle-exact, so
; the window runs with interrupts off and it starts on a raster line with no
; badline in the next two (badlines: raster & 7 = YSCROLL = 3, core
; screen_init). An NMI can't be masked: a MIDI byte in or out on an NMI
; interface (Namesoft) landing in the window adds its ~45 cycles at $FFFF,
; the triangle is parked near its peak and the hit starts with a DC jump (a
; click, about one in 30 s with MIDI traffic). So CIA1 timer A (the tick
; timer) times the window, and a window that took longer is done again.
; Y: voice register offset (preserved). clobbers A, X
; -----------------------------------------------------------------------------
PARK_DELAYS     = 5             ; jsr/rts pairs: 5 x 12 + 7 = 67 cycles (see below)
PARK_TIMED      = 87            ; cycles from the timer read before the window to the one after
CIA1_TA_LO_READ = $dc04         ; CIA1 timer A low byte (counts down, period TICK_LATCH+1)
TRIANGLE        = %00010000
YSCROLL_BADLINE = 3             ; raster & 7 of a badline (VIC_CTRL1 = %00011011)

osc_park
        php                     ; the caller's interrupt state, restored at the end
_again  lda #$ff
        sta SID_V1_FREQ_LO,y
        sta SID_V1_FREQ_HI,y
        lda #TEST_BIT           ; accumulator held at 0, gate off
        sta SID_V1_CTRL,y

        ; wait for a line from which the next two lines have no badline:
        ; raster & 7 in 4..7 (YSCROLL 3 is a badline, 0..2 lead into one).
        ; The wait runs with interrupts as the caller had them (a MIDI byte
        ; arrives every ~315 cycles; the wait can be 4 lines), then the
        ; line is checked again with interrupts off: an interrupt between
        ; the two checks may have moved it on. Masked: ~95 cycles.
_retry  plp
        php
-       lda VIC_RASTER
        and #7
        cmp #YSCROLL_BADLINE+1
        bcc -
        sei
        lda VIC_RASTER
        and #7
        cmp #YSCROLL_BADLINE+1
        bcc _retry

        ; release the test bit and count the cycles between the two writes
        ; (a store writes on its last cycle): jsr 6 + rts 6 per delay, then
        ; lda 2 + sta 5 = 12 x n + 7. No branches, so the timing doesn't
        ; depend on where the code lands (a branch loop takes a cycle more
        ; when it crosses a page; that happened once the code grew).
        ldx CIA1_TA_LO_READ     ; the timer before (read on the last cycle)
        lda #TRIANGLE
        sta SID_V1_CTRL,y       ; accumulator runs from here
        .rept PARK_DELAYS
        jsr _rts
        .endrept
        lda #0
        sta SID_V1_FREQ_HI,y    ; frequency $00FF for 5 cycles: +$4FB, nothing
        sta SID_V1_FREQ_LO,y    ; stopped

        ; the timer counted PARK_TIMED cycles, or that less one timer period
        ; if it reloaded in between: anything else is an NMI, park again
        txa
        sec
        sbc CIA1_TA_LO_READ     ; elapsed cycles, low byte
        cmp #PARK_TIMED
        beq _parked
        cmp #(PARK_TIMED - (TICK_LATCH + 1)) & $ff
        bne _again
_parked plp
_rts    rts

; -----------------------------------------------------------------------------
; voice_end - stop voice X: gate off with the waveform still running, so it
; fades out with the SID's fastest release (rate 0); voice idle; filter given
; up if it had it (its routing stays: the tail fades through the filter); a
; lent ring partner free again.
; v_fade = ticks until the fade is quiet enough (fade_ticks: down to ~1/10)
; for the voice to be restarted without a click. Faded-out sounds (level
; below LEVEL_SILENT) need none.
; X: voice. clobbers A, Y; preserves X
; -----------------------------------------------------------------------------
voice_end
        ; a lent ring partner goes free
        ldy v_partner,x
        cpy #NO_PARTNER
        beq +
        lda voice_bit,y
        eor #$ff
        and lent
        sta lent
        lda #NO_PARTNER
        sta v_partner,x
+       lda v_fade,x
        bne +                   ; already fading: keep it
        lda env_hi,x
        lsr
        lsr
        lsr
        lsr
        tay
        lda fade_ticks,y
        sta v_fade,x
+       ldy voice_reg,x
        lda v_mute,x
        beq +
        ; still in the attack mute (choked or stolen right after its launch):
        ; v_ctrl is the old sound's waveform, which on the parked oscillator
        ; would be a DC level (pulse, noise) fading out: keep the silent
        ; triangle midpoint
        lda #0
        sta v_mute,x
        lda #TRIANGLE
        bne ++
+       lda v_ctrl,x
        and #~GATE
+       sta SID_V1_CTRL,y
        lda #VOICE_IDLE
        sta v_sound,x
        lda #0
        sta env_hi,x
        sta env_lo,x
        cpx filter_owner
        bne +
        jmp filter_free
+       rts

; -----------------------------------------------------------------------------
; filter_apply - the filter setting A (filt_* index) for voice X, the owner:
; cutoff, resonance, mode, and only this voice routed through it.
; cutoff = filt_cutoff + velocity x 2 x filt_vel / 256 (soft hits darker)
;        + (the hit's random value AND filt_rand), at most 255; then x the
;        Tone knob's factor (tone_cutoff), at most 255.
; The voice joins the routing; voices routed before stay routed.
; Setting 0 frees the filter.
; X: voice (preserved). clobbers A, Y
; -----------------------------------------------------------------------------
filter_apply
        tay
        beq filter_free
        sty filt_set
        stx filt_voice

        ; velocity part, 0 if the setting has none
        lda #0
        ldx filt_vel,y
        beq _rand
        ldy filt_voice
        lda v_vel,y             ; 2..254
        jsr mul8                ; A = velocity x 2 x filt_vel / 256; clobbers X, Y
        ldy filt_set

        ; + random part, + cutoff at velocity 0, clamped to 255
_rand   ldx filt_voice
        sta filt_sum
        lda v_rand,x
        and filt_rand,y
        clc
        adc filt_sum
        bcs _top
        adc filt_cutoff,y
        bcc +
_top    lda #$ff
+       ldy v_tone,x            ; the Tone knob: the cutoff x its factor
        cpy #TUNE_CENTER
        beq +
        jsr tone_cutoff         ; clobbers X, Y
        ldx filt_voice
+       ldy filt_set            ; (both ways: Y is the setting from here on)
        sta SID_CUTOFF_HI

        ; resonance, routing (this voice only), mode
        lda #0
        sta SID_CUTOFF_LO
        lda filt_reso,y
        sta filt_res
        lda voice_bit,x
        ora filt_routes
        sta filt_routes
        ora filt_res
        sta SID_RES_FILT
        lda filt_mode,y
        cmp sid_mode
        beq +                   ; unchanged: no $D418 write
        sta sid_mode
        jmp mode_vol_write
+       rts

; -----------------------------------------------------------------------------
; filter_free - nobody owns the filter. The registers stay as they are:
; switching the routing or mode off under a sounding voice would snap, and
; a silent routed voice costs nothing (voice_start takes a voice out of the
; routing when it parks it for an unfiltered sound).
; preserves X, Y; clobbers A
; -----------------------------------------------------------------------------
filter_free
        lda #VOICE_IDLE
        sta filter_owner
        rts

; -----------------------------------------------------------------------------
; mode_vol_write - $D418: filter mode bits and the master volume parameter.
; preserves X, Y; clobbers A
; -----------------------------------------------------------------------------
mode_vol_write
        lda params+P_VOLUME
        ora sid_mode
        sta SID_MODE_VOL
        rts

; filter routing bit ($D417) of each voice
voice_bit       .byte %001, %010, %100
