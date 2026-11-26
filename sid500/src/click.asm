; click.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The metronome (docs/design.md section 4b; the user, 2026-11-20): a soft
; click on SID voice 3 (its own for good), a brighter one on each bar's
; first beat, started from the player's timer interrupt as a beat's tick
; comes due, so it is exactly on the beat. Off by default; the Metronome
; parameter, or C= K on the song screen and the step grid, turns it on and
; off. The beat is a quarter in n/4, an eighth in n/8, from the playing
; scene's signature (scene 1 until stage E); the bars count from the
; song's start, so after a stop the phase is found again from the tick
; (click_phase). The sound (a high triangle, a short level and release)
; is to be tuned by ear with the user.
;
; It can also be a MIDI note (the user, 2026-11-22): the Metronome
; parameter is Off, SID, MIDI or SID+MIDI (bit 0 the SID's click, bit 1
; the note); the note on the Click chan, the Beat note (side stick, 37)
; or a bar's first beat's Bar note (claves, 75) by default on channel 10.
; It goes through the merger just before the beat's tick's bytes, on the
; beat (the user, 2026-11-22: the beat's notes ~1 ms later while it is
; on), and its note off a tick later after that tick's bytes, from the
; timer interrupt; only between whole ticks (running status starts afresh at
; each tick), so with a tick released in parts or a release under way it
; waits for the next interrupt (click_midi_send).

SID_V3_AD       = $d413         ; voice 3: attack bits 4-7, decay bits 0-3
CLICK_WAVE      = $10           ; triangle (the gate bit 0 added to sound)
CLICK_FREQ_BEAT = 1500 * 16777216 / 985248 ; ~1.5 kHz (SID frequency: Hz * 2^24 / PAL clock)
CLICK_FREQ_BAR  = 3000 * 16777216 / 985248 ; ~3 kHz, brighter: a bar's first beat
CLICK_AD        = $00           ; attack 2 ms, decay 6 ms
CLICK_SR        = $90           ; sustain 9 of 15 (the click's level), release 6 ms: the
                                ; gate a tick long (10 ms at 120 BPM), then released
CLICK_VOLUME    = $0f           ; the SID's master volume, no filter (the click bypasses it)
CLICK_KEY       = 4*8+5         ; K (key matrix: column 4, row 5), with C=
CLICK_SID       = 1             ; P_METRONOME's bits: the SID's click
CLICK_MIDI      = 2             ;   the MIDI note
CLICK_VELOCITY  = 100           ; the note's velocity
MIDI_SEND_ON    = $80           ; click_midi: a note on to send
MIDI_SEND_OFF   = $40           ;   its note off to send

        .section live_vars
click_seen      .word ?         ; play_tick when last looked at
click_wait      .byte ?         ; the ticks due until the next beat's (1: the next one is)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
click_beat_no   .byte ?         ; that beat in its bar, 0 = the first
        .send
click_beats     .byte ?         ; beats a bar
click_len       .byte ?         ; ticks a beat (48: a quarter, 24: an eighth)
click_gate      .byte ?         ; nonzero: the voice gated (off at the next tick due)
click_t         .word ?         ; click_phase's scratch: the tick, then its place in the bar
click_bar       .word ?         ;   ticks a bar
        .send
        .section edit_vars      ; (under the KERNAL: $C280's are full in test builds)
click_last      .byte ?         ; C= K: the Metronome parameter's last value but Off
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
click_midi      .byte ?         ; MIDI_SEND_*: what waits to be sent
        .send
click_sounding  .byte ?         ; nonzero: a note on sent, its note off not yet
click_note      .byte ?         ;   the note to send
click_sent      .byte ?         ;   the one sounding (its off's)
        .send

; (player_prepare, player_prepare_quick, slave_first_lead and
; player_restart live here, out of the way: see timing.asm, at click_init
; and SYNTH_TIMER_AT)
; wheel_free_all - (player.asm wheel_clear) every entry of the timing
; wheel free, chained in order. clobbers A, X
wheel_free_all
        lda #0
        sta off_free
        ldx #0
-       inx
        txa
        sta OFF_NEXT-1,x
        cpx #OFF_ENTRIES
        bne -
        lda #NO_ENTRY
        sta OFF_NEXT+OFF_ENTRIES-1
        rts

; -----------------------------------------------------------------------------
; player_restart - the Clock parameter changed (main loop, interrupts on):
; playing, the player stops as it was (stop_ends_notes: a master sends
; MIDI stop, every note it started ends); then it waits at the song's
; start in its new role (player_prepare, player_go). Timer A stopped and
; the player held first, so no tick plays meanwhile.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_restart
        sei
        lda #0
        sta CIA1_CRA            ; timer A stopped: no tick from here on
        ldx play_state
        lda #PLAY_HELD
        sta play_state
        cpx #PLAY_RUNNING
        bne _ready              ; (not playing: nothing sounds)
        lda params+P_CLOCK
        beq +                   ; now master: it was a slave (its master sent stop)
        lda #MIDI_STOP          ; it was master: MIDI stop
        jsr midi_send_urgent
+       cli
        jsr stop_ends_notes
_ready  cli
        lda #0
        sta slave_req
        sta slave_stop_req
        sta transport_req       ; (a stop, start or continue under way: dropped)
        sta stop_continuing
        sta stop_phase
        jsr player_prepare
        jmp player_go

; -----------------------------------------------------------------------------
; player_prepare - (the player stopped or held: no tick plays meanwhile, so
; interrupts may be on) the song at its start with its first ticks
; rendered (pos_zero), the period at the tempo. A slave renders
; SLAVE_FIRST_LEAD ticks: its master's tempo is unknown until it plays
; (from then on the lead follows it), and the Tempo parameter's lead could
; be too short (at 40 BPM a tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_prepare
        jsr player_reset
        jsr player_set_swing
        jsr player_set_tempo    ; (first: the render lead too)
        jsr slave_first_lead
        jsr render_first        ; (the first ticks ready before MIDI start)
        lda #1
        sta pos_zero
        rts

; -----------------------------------------------------------------------------
; player_prepare_quick - (a slave asked to start away from the song's
; start: its master's clock is coming) as player_prepare, but only tick 0
; rendered before it goes; the timer interrupt renders the rest of the
; lead as it plays.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_prepare_quick
        jsr player_reset
        jsr player_set_swing
        jsr player_set_tempo
        lda #1
        sta render_ahead
        jsr render_first        ; (tick 0)
        jsr slave_first_lead    ; (the lead for the interrupt)
        lda #1
        sta pos_zero
        rts

; slave_first_lead - as slave, the render lead before start (transport.asm's
; locate too): the master's tempo's (slave_lead) once a clock gap has been
; measured, else SLAVE_FIRST_LEAD. clobbers A, X
slave_first_lead
        lda params+P_CLOCK
        beq _done
        lda #SLAVE_FIRST_LEAD
        ldx slave_last_ok
        beq +
        ldx slave_period+1      ; (a gap measured: its tempo's lead)
        jsr slave_lead_x        ; (size.asm: computed, a table no more)
+       jsr set_lead
_done   rts

; -----------------------------------------------------------------------------
; click_key - (song.asm, grid.asm: a key on the song screen or the step
; grid) C= K pressed: the metronome on or off (Claude's default, the user
; may change it). Carry set: it was (A = the key code otherwise kept).
; clobbers nothing else
; -----------------------------------------------------------------------------
click_key
        cmp #CLICK_KEY
        bne _no
        pha
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq _not
        lda want_press
        beq _used               ; (its release)
        lda params+P_METRONOME  ; on: off, the value kept; off: the value kept
        beq +
        sta click_last
        lda #0
        beq ++
+       lda click_last
+       sta params+P_METRONOME
_used   pla
        sec
        rts
_not    pla
_no     clc
        rts

; -----------------------------------------------------------------------------
; click_idle - (synth_timer, not playing, interrupts on) a click sounding
; released (a note's off sent, one not yet sent dropped); the next tick due moved (a stop's locate, a start, a reset):
; the phase found again from it (~1,100 cycles here, not at the first beat).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
click_idle
        lda click_midi          ; a note on not yet sent: not now
        and #$ff-MIDI_SEND_ON
        sta click_midi
        lda click_gate
        beq +
        jsr click_release       ; (a note sounding: its off to send)
+       lda click_midi
        beq +
        jsr click_midi_send     ; (its off)
+       lda play_tick
        cmp click_seen
        bne +
        lda play_tick+1
        cmp click_seen+1
        beq _same
+       lda play_tick
        sta click_seen
        lda play_tick+1
        sta click_seen+1
        ldx #0                  ; (from the next tick due: play_tick itself)
        jmp click_phase
_same   rts

; -----------------------------------------------------------------------------
; The count, in timing.asm's synth_timer as each tick comes due (a few
; cycles: the half-the-wire scene's lag is ~0.1 ms from its limit):
; click_wait one less (a slave's several ticks: click_count); then,
; playing, a click sounding released (click_gate: click_release) and on
; a beat (click_wait 0) click_beat. Counted when off too, so turned on
; mid-song it clicks in time.
; -----------------------------------------------------------------------------

; click_release - (synth_timer, playing, click_gate set) the click a tick
; long: released. clobbers A
click_release
        lda #CLICK_WAVE
        sta SID_V3_CTRL
        lda #0
        sta click_gate
        lda click_midi          ; a note sounding, or yet to: its off to send
        and #MIDI_SEND_ON+MIDI_SEND_OFF ; (not thru's bit: record.asm)
        ora click_sounding
        beq +
        lda click_midi
        ora #MIDI_SEND_OFF
        sta click_midi
+       rts

; -----------------------------------------------------------------------------
; click_midi_send - (synth_timer after the release, click_midi nonzero; a
; stop: click_idle) what waits of the note: a sounding note's off first
; (a beat's on can come while an off still waits), then the note on, then
; its off if that waits too. Through the merger inside sei (a nested timer
; interrupt's release could come between the bytes), between whole ticks
; only (not while a tick goes out in parts, rel_partial, nor while a
; release interrupted by this one is under way, release_busy), with room
; for all 6 bytes in the ring (inside sei it can't empty); else left for
; the next interrupt.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
click_midi_send
        php
        sei
        lda release_busy
        ora rel_partial
        bne _later
        lda tx_tail             ; room for 6? (tail - next - 1)
        clc
        sbc out_next
        cmp #6
        bcc _later
        lda params+P_CLICK_CHAN ; the status: a note on, the channel (0-15)
        ora #MSG_NOTE_ON
        tax
        bit click_midi          ; an off waiting for a sounding note: first
        bvc _on
        lda click_sounding
        beq _on
        jsr _off
_on     bit click_midi
        bpl +
        txa                     ; the note on
        jsr out_byte
        lda click_note
        sta click_sent
        jsr out_byte
        lda #CLICK_VELOCITY
        jsr out_byte
        sta click_sounding
        lda click_midi
        and #$ff-MIDI_SEND_ON
        sta click_midi
+       bit click_midi          ; its off waiting too
        bvc +
        jsr _off
+       jsr out_go
_later  plp
        jmp thru_drain          ; what waits in thru's queue (record.asm) after them
; _off - the sounding note's off (velocity 0), no longer waiting
_off    txa
        jsr out_byte
        lda click_sent
        jsr out_byte
        lda #0
        jsr out_byte
        sta click_sounding
        lda click_midi
        and #$ff-MIDI_SEND_OFF
        sta click_midi
        rts

; click_count - (synth_timer, a slave: X ticks due, 1 or more) each counted;
; a beat on the last left at 0 (synth_timer clicks it); one on an earlier
; one (a slave catching up) passed over, unheard. clobbers A, X, Y
click_count
-       dec click_wait
        bne _on
        cpx #1
        beq _done               ; (the last: synth_timer's)
        lda click_len
        sta click_wait
        ldy click_beat_no
        iny
        cpy click_beats
        bcc +
        ldy #0
+       sty click_beat_no
_on     dex
        bne -
_done   rts

; -----------------------------------------------------------------------------
; click_beat - (synth_timer, click_wait 0: a beat's tick due; X = play_tick
; - the beat's tick, 1 for the master) the next beat's count; on, the click
; (its gate a tick long, the bar's first brighter). TEST_LOG: LOG_CLICK (1
; a beat, 2 a bar's first) as it is written, then LOG_CLICK_AT (the beat's
; song tick: low, high).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
click_beat
        lda click_len
        sta click_wait
        lda params+P_METRONOME
        beq _next
        and #CLICK_MIDI         ; the note: to send after the tick's bytes
        beq _sid
        ldy params+P_CLICK_BEAT
        lda click_beat_no
        bne +
        ldy params+P_CLICK_BAR
+       sty click_note
        lda click_midi
        ora #MIDI_SEND_ON
        sta click_midi
        sta click_gate          ; (released a tick on: its off)
_sid    lda params+P_METRONOME
        and #CLICK_SID
        beq _next
        lda click_beat_no       ; its pitch (the bar's first brighter)
        bne +
        lda #<CLICK_FREQ_BAR
        sta SID_V3_FREQ_LO
        lda #>CLICK_FREQ_BAR
        jmp _gate
+       lda #<CLICK_FREQ_BEAT
        sta SID_V3_FREQ_LO
        lda #>CLICK_FREQ_BEAT
_gate   sta SID_V3_FREQ_HI
        lda #CLICK_WAVE | 1     ; gate on
        sta SID_V3_CTRL
        sta click_gate
.if TEST_LOG
        stx click_t             ; (tests: when, which, and the song tick)
        lda #1
        ldy click_beat_no
        bne +
        lda #2
+       sta log_a_value
        lda #LOG_CLICK
        jsr log_a
        lda play_tick
        sec
        sbc click_t
        sta log_a_value
        lda play_tick+1
        sbc #0
        pha
        lda #LOG_CLICK_AT
        jsr log_a
        pla
        sta log_a_value
        lda #LOG_CLICK_AT
        jsr log_a
.endif
_next   ldy click_beat_no       ; the next beat
        iny
        cpy click_beats
        bcc +
        ldy #0
+       sty click_beat_no
        rts

; -----------------------------------------------------------------------------
; click_phase - (click_idle, X = 0) the beat and the ticks to it from the
; tick play_tick - X (song ticks from the song's start), the signature
; from scene 1's. X kept. ~1,100 cycles.
; clobbers A, Y
; -----------------------------------------------------------------------------
click_phase_song                ; (unused: scene.asm click_phase, the playing scene's)
        ; the beat and the bar from the signature (scene.asm click_phase
        ; points the two reads, cps_sig1 and cps_sig2, at the scene's byte)
cps_sig1 = * + 1
        lda SCENE_SIG
        and #$0f
        clc
        adc #1
        sta click_beats
        lda #TICKS_PER_QUARTER
cps_sig2 = * + 1
        bit SCENE_SIG
        bpl +
        lda #TICKS_PER_QUARTER/2 ; (n/8: an eighth a beat)
+       sta click_len
        ; ticks a bar: beats * len (a loop: at most 16 * 48)
        lda #0
        sta click_bar
        sta click_bar+1
        ldy click_beats
-       lda click_bar
        clc
        adc click_len
        sta click_bar
        bcc +
        inc click_bar+1
+       dey
        bne -
        ; the first tick due: its place in the bar (the tick mod the bar,
        ; 16 bits a bit at a time)
        stx click_t             ; (X: the ticks due)
cps_tick_lo = * + 1
        lda play_tick           ; (click_phase: song_scene_ptr in its place)
        sec
        sbc click_t
        sta click_t
cps_tick_hi = * + 1
        lda play_tick+1
        sbc #0
        sta click_t+1
        txa                     ; (X kept)
        pha
        lda #0                  ; remainder in A (low), Y (high)
        tay
        ldx #16
-       asl click_t
        rol click_t+1
        rol a
        pha
        tya
        rol a
        tay
        pla
        cmp click_bar           ; remainder >= the bar: less it
        pha
        tya
        sbc click_bar+1
        bcc _keep
        tay
        pla
        sbc click_bar           ; (carry set)
        jmp +
_keep   pla
+       dex
        bne -
        sta click_t             ; the place in the bar (< 768)
        sty click_t+1
        pla
        tax
        ; its beat: place / len (a loop); the ticks to the next beat
        ldy #0
-       lda click_t
        sec
        sbc click_len
        pha
        lda click_t+1
        sbc #0
        bcc _beat
        sta click_t+1
        pla
        sta click_t
        iny
        jmp -
_beat   pla                     ; click_t: ticks past the beat Y
        lda click_t
        beq _on                 ; on the beat: it clicks now
        iny                     ; past it: the next one, len - place + 1 ticks on
        cpy click_beats
        bcc +
        ldy #0
+       lda click_len
        sec
        sbc click_t
        clc
        adc #1
        sta click_wait
        sty click_beat_no
        rts
_on     lda #1
        sta click_wait
        sty click_beat_no
        rts

click_phase_end                 ; (scene.asm patches click_phase_song: its size checked there)
