; scene.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Scenes, the song and live play (stage E; docs/design.md section 5c,
; settled with the user 2026-11-23):
;
; - The song is the scene rows in order, each for its bars times its
;   repeats (SCENE_BARS, SCENE_SIG, SCENE_REPEATS), to the first empty
;   scene. Song on (C= S, or MIDI song select), the song plays down the
;   rows and loops back to scene 1; Song off, the playing scene loops.
; - A launch (SHIFT+RETURN a scene, C= RETURN one cell, CC 85 or a
;   program change on SID500's channel) takes over at the playing scene's
;   next bar line. The player makes it as that tick begins (play_begin):
;   at a bar line the passes and the ticks are in step (swing moves passes
;   only inside a pair of 16ths), so the bar's first pass is a tick's
;   first. A scene launched: every track from its pattern's start, the
;   tracks' places counted from there (TRK_ORG: the live switch's place,
;   live_rel); a cell launched: that track only, overriding its scene's
;   cell (TRACK_OVERRIDE) until the next scene. The song's next scene is a
;   launch armed at the playing scene's end (scene_poll).
; - A launch never has to be undone by a stop: the render lead is at most
;   8 ticks (240 BPM) and bar lines are 16ths, so a stop always locates to
;   a 16th the renderer had reached or one after the launch (a slave's
;   first lead, 14 ticks before its master's tempo is known, is the one
;   exception). The 16th's snapshot is taken again after a launch.
;
; All of it after the tables (late_code) or under I/O; the routines it
; changes are renamed and wrapped (play_begin, player_reset, live_wanted,
; song_prepare, song_scene_line, rx_message, synth_rx_irq, rec_key,
; click_phase), and the few in-place changes keep their sizes, so nothing
; before the tables moves (the hot code's place, design 4b).

SCENE_REPEATS   = $c980         ; each scene's repeats, 1-9 (song data, after PAT_STEPS)
        .cerror SCENE_REPEATS < PAT_STEPS + NUM_PATTERNS, "SCENE_REPEATS over PAT_STEPS"
TRACK_OVERRIDE  = $ca70         ; each track's cell launched (C= RETURN): its pattern, or
                                ; OVR_NONE (its scene's cell), OVR_SILENT (an empty cell)
        .cerror TRACK_OVERRIDE + NUM_TRACKS > SCENE_BARS, "TRACK_OVERRIDE runs into SCENE_BARS"
OVR_NONE        = $ff
OVR_SILENT      = $fe
LAUNCH_SCENE    = $ff           ; launch_kind: a scene (else a track: a cell launched)
REPEATS_MAX     = 9
BARS_MAX        = 8
SIG_BEATS_MAX   = 16
LOG_LAUNCH      = 32            ; (tests, log a) a launch made: its pass (low, middle), then
                                ; the scene (a scene launched) or $80 + the track
LOG_LAUNCH_ASK  = 33            ; (tests, log a) a launch armed: the renderer's pass then
                                ; (low, middle), its pass (low, middle), what (as above)
KEY_B           = 28            ; key codes (column * 8 + row)
KEY_N           = 39
KEY_T           = 22
KEY_X           = 23

        .section zp
play_scene1     .byte ?         ; the scene playing's number (1-64: the title's, song.asm's
                                ; playing mark; the zero page has room for one byte)
        .send

        .section late_code

; the variables: after the song's data, at $CF00 (main RAM, read by the
; interrupts too; not the song's: scene_init and player_reset set them)
        .virtual SONG_DATA_END
play_scene      .byte ?         ; the scene playing (0-63)
launch_pending  .byte ?         ; nonzero: a launch armed (the player makes it at launch_at)
launch_kind     .byte ?         ; LAUNCH_SCENE, or the track whose cell is launched
launch_what     .byte ?         ; the scene launched, or the cell's scene
launch_by_song  .byte ?         ; nonzero: armed by the song (scene_poll may move it)
launch_at       .fill 3         ; the pass it is made at (a bar line)
scene_origin    .fill 3         ; the pass the playing scene began at
scene_tick      .word ?         ; and its song tick (the metronome's bars from there)
start_scene     .byte ?         ; the scene the song starts from (player_reset)
song_on         .byte ?         ; Song mode (C= S)
take_cut        .byte ?         ; nonzero: a launch made changes the take's track (the user,
                                ; 2026-11-23: the take ends there)
take_cut_at     .fill 3         ;   its pass: messages heard from it on aren't the take's
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
scene_ver       .byte ?         ; counted on at every launch armed, made or dropped
        .send
ovr_scene       .fill NUM_TRACKS ; each override's scene (the cell's row: its '>' mark)
TRK_ORG_0       .fill NUM_TRACKS ; each track's origin: the pass its place counts from
TRK_ORG_1       .fill NUM_TRACKS
TRK_ORG_2       .fill NUM_TRACKS
midi_ask        .byte ?         ; (the receive interrupt) a scene + 1 to launch, 0 = none
song_ask        .byte ?         ;   nonzero: song select came (Song on)
rx_select       .byte ?         ; synth_rx_irq: song select's data byte comes next
; the main loop's scratch
sc_num          .fill 3         ; a 24-bit number
sc_len          .word ?         ; a bar's passes
sc_rem          .word ?         ; sc_mod's remainder
sc_x            .fill 3         ; the pass a launch is looked for from
sc_mul          .byte ?         ; sc_mul24's multiplier
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
sc_tmp          .byte ?
        .send
sc_next         .byte ?         ; scene_poll: the song's next scene
sc_kind         .byte ?         ; launch_arm: the launch's kind and scene, until committed
sc_what         .byte ?
sc_ver          .byte ?         ;   scene_ver when its computing began (a launch made
                                ;   meanwhile: computed again)
lm_tmp          .byte ?         ; the player's side's own scratch (launch_make)
; the song screen's: what row 1 and the scenes' marks show
shown_ver       .byte ?         ; scene_ver as drawn
shown_row1      .fill 5         ; row 1's: the cursor's scene, song_on, bars, sig, repeats
scene_vars_end
        .endv
        .cerror scene_vars_end > $d000, "scene.asm's variables run past $CFFF"

; -----------------------------------------------------------------------------
; scene_init - (synth_init: count_init) every scene played once, Song
; off, the song from scene 1. clobbers A, X
; -----------------------------------------------------------------------------
scene_init
        ldx #NUM_SCENES-1
        lda #1
-       sta SCENE_REPEATS,x
        dex
        bpl -
scene_init_vars                 ; (disk.asm: a song loaded keeps its repeats)
        lda #0
        sta song_on
        sta start_scene
        sta launch_pending
        sta midi_ask
        sta song_ask
        sta rx_select
        sta scene_ver
        lda #$ff                ; (drawn at the first look)
        sta shown_ver
        sta shown_row1
        ; click_phase_song reads the tick from the playing scene's start in
        ; song_scene_ptr (click_phase puts it there for the call)
        lda #<song_scene_ptr
        sta CPS_TICK_LO
        lda #<song_scene_ptr+1
        sta CPS_TICK_HI
.if TEST_SCENES
        jsr st_init             ; (tests: the scenes and Song)
.endif
        lda #0
        jmp scene_set

; =============================================================================
; The player's part (the renderer: the timer interrupt or render_slice)
; =============================================================================

; -----------------------------------------------------------------------------
; play_begin - (render.asm, a tick's rendering begins; player.asm's
; play_begin_tick after) a launch armed and its pass come (or passed: made
; late rather than never): made first (launch_make). Carry as
; play_begin_tick leaves it.
; -----------------------------------------------------------------------------
play_begin
        lda launch_pending
        beq +
        jsr launch_due
+       jmp play_begin_tick

; launch_due - the launch made if pl_music >= launch_at. clobbers A, X, Y
launch_due
        lda pl_music
        cmp launch_at
        lda pl_music+1
        sbc launch_at+1
        lda pl_music+2
        sbc launch_at+2
        bcs launch_make
        rts

; -----------------------------------------------------------------------------
; launch_make - the launch made, as a tick begins (no walk of ACTIVE under
; way): a live switch half made dropped (pl_jumps: it was for the scene
; before), then a scene: every track from its pattern's start, the scene's
; place and the metronome's bar from here; a cell: its track. The 16th's
; snapshot taken again (it was taken as the tick before ended).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
launch_make
        lda rec_state           ; a take on the track it changes: it ends at this bar
        cmp #REC_ON             ; (the user, 2026-11-23; scene_poll, rec_put_count)
        bne +
        ldx launch_kind
        bmi _cut                ; (a scene: every track)
        cpx rec_track
        bne +
_cut    ldx #2
-       lda launch_at,x
        sta take_cut_at,x
        dex
        bpl -
        lda #1
        sta take_cut
+       inc scene_ver           ; (the song screen: the marks)
        inc pl_jumps            ; (live.asm: a switch for the scene before dropped)
        lda #0
        sta sw_pending
        sta launch_pending
        ldx launch_kind
        bpl _cell
        ; a scene: the playing one now, its origin this pass
        lda launch_what
        jsr scene_set
        ldx #2                  ; (the bar line armed: a launch made late keeps the
-       lda launch_at,x         ; scene's bars on their grid)
        sta scene_origin,x
        dex
        bpl -
        lda song_tick
        sta scene_tick
        lda song_tick+1
        sta scene_tick+1
        ldx #NUM_TRACKS-1
-       lda #OVR_NONE
        sta TRACK_OVERRIDE,x
        sta ovr_scene,x
        jsr scene_cell
        jsr launch_track
        dex
        bpl -
        jsr launch_click
        jmp _made
        ; a cell: its pattern over the scene's, on its track
_cell   lda launch_what
        sta ovr_scene,x
        jsr scene_at_x          ; (A: the cell's number, X kept)
        cmp #NO_PATTERN
        bne +
        lda #OVR_SILENT
+       sta TRACK_OVERRIDE,x
        cmp #OVR_SILENT
        bne +
        lda #NO_PATTERN
+       jsr launch_track
_made   jsr active_build
        lda pl_step_tick        ; a 16th's first tick (a bar line's): its snapshot anew
        bne +
        jsr snapshot_save
+
.if TEST_LOG
        php
        sei
        lda pl_music
        sta log_a_value
        lda #LOG_LAUNCH
        jsr log_a
        lda pl_music+1
        sta log_a_value
        lda #LOG_LAUNCH
        jsr log_a
        lda launch_kind
        bmi +
        ora #$80
        bne ++
+       lda launch_what
+       sta log_a_value
        lda #LOG_LAUNCH
        jsr log_a
        plp
.endif
        rts

; launch_track - track X from pattern A's start at this pass (NO_PATTERN, or
; a number with no pattern: none), its origin this pass. keeps X
launch_track
        sta PLAY_PATTERN,x
        cmp #NO_PATTERN
        beq _none
        tay
        lda PAT_STEPS,y
        beq _none               ; (a number with no pattern yet: as none)
        stx lm_tmp
        jsr steps_to_ticks      ; (A low, Y high)
        ldx lm_tmp
        sta TRK_PLEN_LO,x
        sta TRK_POS_LO,x        ; (at its end: this pass starts the pattern)
        tya
        sta TRK_PLEN_HI,x
        sta TRK_POS_HI,x
        jmp +
_none   lda #NO_PATTERN
        sta PLAY_PATTERN,x
+       lda #0
        sta TRK_SKIP_LO,x
        sta TRK_SKIP_HI,x
        sta PLAY_STALE,x
        lda pl_music
        sta TRK_ORG_0,x
        lda pl_music+1
        sta TRK_ORG_1,x
        lda pl_music+2
        sta TRK_ORG_2,x
        rts

; launch_click - (a scene launched) the metronome's beat from this tick in
; the new scene's signature: its first beat when this tick is heard (the
; next beat of the scene before is here too: a bar line, and the lead is
; shorter than any beat). Not if the tick is heard already (the renderer
; behind). clobbers A, X
launch_click
        ldx play_scene
        php
        sei
        lda song_tick           ; ticks due until this one: song_tick + 1 - play_tick
        sec
        sbc play_tick
        tax
        lda song_tick+1
        sbc play_tick+1
        bne _no                 ; (behind, or far ahead: left)
        inx
        beq _no
        stx click_wait
        lda #0
        sta click_beat_no
        ldx play_scene
        jsr sig_beats           ; (A: the beats, X: the beat's ticks)
        sta click_beats
        stx click_len
_no     plp
        rts

; sig_beats - scene X's signature: A = its beats, X = a beat's ticks (48 in
; n/4, 24 in n/8). clobbers nothing else
sig_beats
        lda SCENE_SIG,x
        bmi _eighths
        and #$0f
        ldx #TICKS_PER_QUARTER
        bne +
_eighths
        and #$0f
        ldx #TICKS_PER_QUARTER/2
+       clc
        adc #1
        rts

; scene_set - scene A the playing one: play_scene, the title's number and
; scene_cell's row. clobbers A
scene_set
        sta play_scene
        clc
        adc #1
        sta play_scene1
        lda play_scene          ; the row's address: SCENES + scene * 16
        asl
        asl
        asl
        asl
        sta scene_cell+1         ; (its lda's operand)
        lda play_scene
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>SCENES
        sta scene_cell+2
        rts
; scene_cell - A = track X's cell in the playing scene. keeps X, Y
scene_cell
        lda SCENES,x            ; (the row's address patched by scene_set)
        rts

; scene_at_x - A = track X's cell in scene launch_what. keeps X, Y
scene_at_x
        sty lm_tmp
        lda launch_what
        asl
        asl
        asl
        asl
        sta _at+1
        lda launch_what
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>SCENES
        sta _at+2
_at     lda SCENES,x
        ldy lm_tmp
        rts

; -----------------------------------------------------------------------------
; player_reset - (in player.asm player_reset_tracks' place: the song from
; its start) the song starts from start_scene, no cell launched, no launch
; armed, every place from pass 0; then player_reset_tracks.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_reset
        inc scene_ver
        lda #CK_RESET           ; (clock.asm: the time display from the start)
        sta ck_jump
        lda #0
        sta launch_pending
        sta take_cut
        ldx #2
-       sta scene_origin,x
        dex
        bpl -
        sta scene_tick
        sta scene_tick+1
        ldx #NUM_TRACKS-1
-       lda #0
        sta TRK_ORG_0,x
        sta TRK_ORG_1,x
        sta TRK_ORG_2,x
        lda #OVR_NONE
        sta TRACK_OVERRIDE,x
        sta ovr_scene,x
        dex
        bpl -
        lda start_scene
        jsr scene_set
        jmp player_reset_tracks

; -----------------------------------------------------------------------------
; live_wanted - (live.asm live_rule, in live_wanted_row's place) the pattern
; track X wants in A: its cell launched (TRACK_OVERRIDE), else its cell in
; the playing scene; NO_PATTERN for none or a number with no pattern yet.
; keeps X, Y
; -----------------------------------------------------------------------------
live_wanted
        lda TRACK_OVERRIDE,x
        cmp #OVR_NONE
        bne +
        jsr scene_cell
+       cmp #OVR_SILENT
        bne +
        lda #NO_PATTERN
+       cmp #NO_PATTERN
        beq _rts
        sty sc_tmp
        tay
        lda PAT_STEPS,y
        beq _none
        tya
        ldy sc_tmp
        rts
_none   lda #NO_PATTERN
        ldy sc_tmp
_rts    rts

; live_rel - (live.asm live_target) lv_num = T (lv_at) less the switched
; track's origin (TRK_ORG): T's place counts from where its scene (or its
; cell) was launched. clobbers A, X
live_rel
        ldx lv_track
        lda lv_at
        sec
        sbc TRK_ORG_0,x
        sta lv_num
        lda lv_at+1
        sbc TRK_ORG_1,x
        sta lv_num+1
        lda lv_at+2
        sbc TRK_ORG_2,x
        sta lv_num+2
        rts

; -----------------------------------------------------------------------------
; click_phase - (click.asm click_idle, X = 0) click_phase_song for the
; playing scene: its signature (the two reads of SCENE_SIG pointed at its
; byte) and the tick from its start (read from song_scene_ptr in
; play_tick's place: a tick before the scene's start as its start).
; song_scene_ptr is the main loop's alone (song.asm), so the timer
; interrupt (or the main loop, player_go) may borrow it: kept. X kept.
; clobbers A, Y
; -----------------------------------------------------------------------------
CPS_SIG1        = cps_sig1      ; (click.asm click_phase_song: lda SCENE_SIG's operand, low)
CPS_SIG2        = cps_sig2      ;   (bit SCENE_SIG's)
CPS_TICK_LO     = cps_tick_lo   ;   (lda play_tick's)
CPS_TICK_HI     = cps_tick_hi   ;   (lda play_tick+1's)
        .cerror play_tick >= $100 || song_scene_ptr >= $100, "click_phase: play_tick and song_scene_ptr in the zero page (only the operand low byte patched)"
        .cerror (>(SCENE_SIG + NUM_SCENES - 1)) != (>SCENE_SIG), "SCENE_SIG's scenes in one page"
click_phase
        lda play_scene
        clc
        adc #<SCENE_SIG
        sta CPS_SIG1
        sta CPS_SIG2
        lda song_scene_ptr      ; (borrowed: kept)
        pha
        lda song_scene_ptr+1
        pha
        lda play_tick
        sec
        sbc scene_tick
        sta song_scene_ptr
        lda play_tick+1
        sbc scene_tick+1
        sta song_scene_ptr+1
        bcs +
        lda #0
        sta song_scene_ptr
        sta song_scene_ptr+1
+       jsr click_phase_song
        pla
        sta song_scene_ptr+1
        pla
        sta song_scene_ptr
        rts

; sc_mod - sc_rem = sc_num (24 bits) mod sc_len, a bit at a time; sc_num
; the quotient. clobbers A, X, Y
sc_mod
        lda #0
        sta sc_rem
        sta sc_rem+1
        ldx #24
-       asl sc_num
        rol sc_num+1
        rol sc_num+2
        rol sc_rem
        rol sc_rem+1
        lda sc_rem
        sec
        sbc sc_len
        tay
        lda sc_rem+1
        sbc sc_len+1
        bcc +
        sta sc_rem+1
        sty sc_rem
        inc sc_num              ; (the quotient's bit)
+       dex
        bne -
        rts

; =============================================================================
; MIDI in (the receive interrupt)
; =============================================================================

; -----------------------------------------------------------------------------
; synth_rx_irq - (core MIDI_RX_IRQ, every byte but realtime; in
; synth_rx_irq_base's place) song select (status $F3, then the song) asks
; for Song on (scene_poll); every byte on to synth_rx_irq_base.
; -----------------------------------------------------------------------------
synth_rx_irq_scene              ; (locate.asm synth_rx_irq first: song position)
        cmp #$80
        bcs _status
        bit rx_select
        bpl _on
        inc song_ask            ; (song select's data: SID500 has one song)
        lsr rx_select
        jmp synth_rx_irq_base
_status pha
        cmp #MIDI_SONG_SELECT
        beq +
        lda #0
        beq ++
+       lda #$80
+       sta rx_select
        pla
_on     jmp synth_rx_irq_base

; -----------------------------------------------------------------------------
; rx_message - (record.asm synth_rx_irq_base, a whole message; in
; rx_message_base's place) on SID500's MIDI channel (not Omni: the
; family's rule), CC 85 or a program change, values 0-63: a scene to
; launch (scene_poll), neither passed through nor recorded. Else on.
; keeps A; clobbers X
; -----------------------------------------------------------------------------
rx_message
        ldx params+P_CHANNEL
        beq _on                 ; (Omni)
        pha
        dex
        txa
        eor rx_status
        and #$0f
        bne _other              ; (another channel)
        lda rx_status
        and #$f0
        cmp #MSG_PROGRAM
        bne +
        lda rx_d1
        jmp _scene
+       cmp #MSG_CC
        bne _other
        lda rx_d1
        cmp #PATTERN_CC_NUMBER
        bne _other
        lda rx_d2
_scene  cmp #NUM_SCENES
        bcs _other              ; (64-127: as any other message)
        clc
        adc #1
        sta midi_ask
        pla
        rts
_other  pla
_on     jmp rx_message_base

PATTERN_CC_NUMBER = 85          ; the family's pattern controller (SID808's)

; =============================================================================
; The main loop's part
; =============================================================================

; -----------------------------------------------------------------------------
; scene_poll - (count_poll, every 250 Hz tick) a scene asked by MIDI
; launched (Song off), song select's Song on; playing with Song on, the
; next scene armed at the playing one's end (its bars times its repeats),
; and kept there while nothing else is armed.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
scene_poll
.if TEST_SCENES
        jsr scene_test
.endif
        lda take_cut            ; a launch cut the take: ended once heard there
        beq _no_cut
        lda rec_state
        cmp #REC_ON
        bne _uncut
        php
        sei
        jsr rec_now_count       ; (the pass heard now: A, Y)
        plp
        cmp take_cut_at
        tya
        sbc take_cut_at+1
        bcc _no_cut
        lda #REC_STOPPING       ; (as C= R: what was played merged)
        sta rec_state
_uncut  lda #0
        sta take_cut
_no_cut
        lda midi_ask
        beq +
        ldx #0
        stx midi_ask
        stx song_on             ; (as SID808's: a pattern asked, song mode off)
        sec
        sbc #1
        jsr launch_scene_key
+       lda song_ask
        beq +
        lda #0
        sta song_ask
        lda #1
        sta song_on
+       lda song_on
        beq _rts
        lda play_state
        cmp #PLAY_RUNNING
        bne _rts
        lda launch_pending
        beq _arm
        lda launch_by_song
        beq _rts                ; (a launch of the user's armed: the song goes on from it)
        ; the song's next: the row after the playing one, or scene 1
_arm    lda scene_ver           ; (a launch made while this is computed: not armed)
        sta sc_ver
        ldx play_scene
        inx
        cpx #NUM_SCENES
        bcs _first
        jsr scene_empty
        bne +
_first  ldx #0
+       stx sc_next
        ; its pass: the playing scene's start + bars * the bar * repeats
        ldx play_scene
        jsr bar_passes          ; sc_len
        lda sc_len
        sta sc_num
        lda sc_len+1
        sta sc_num+1
        lda #0
        sta sc_num+2
        ldx play_scene
        lda SCENE_BARS,x
        jsr sc_mul24
        ldx play_scene
        lda SCENE_REPEATS,x
        jsr sc_mul24
        ldx #0
        clc
-       lda scene_origin,x
        adc sc_num,x
        sta sc_num,x
        inx
        txa
        eor #3
        bne -
        ; the same as armed already: nothing to do
        lda launch_pending
        beq _new
        lda launch_what
        cmp sc_next
        bne _new
        ldx #2
-       lda launch_at,x
        cmp sc_num,x
        bne _new
        dex
        bpl -
_rts    rts
_new    lda #1
        sta launch_by_song
        lda #LAUNCH_SCENE
        ldx sc_next
        jmp launch_arm_at

; scene_empty - scene X has no cell: Z set. keeps X
scene_empty
        stx sc_tmp
        txa
        asl
        asl
        asl
        asl
        sta _ptr+1
        txa
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>SCENES
        sta _ptr+2
        ldy #NUM_TRACKS-1
_ptr    lda SCENES,y
        cmp #NO_PATTERN
        bne +
        dey
        bpl _ptr
        ldx sc_tmp
        lda #0                  ; (Z set: empty)
        rts
+       ldx sc_tmp
        lda #1                  ; (Z clear)
        rts

; bar_passes - sc_len = scene X's bar in passes (its beats * a beat's
; ticks: a pass a tick, swing aside). clobbers A, X, Y
bar_passes
        jsr sig_beats           ; A beats, X a beat
        tay
        stx sc_tmp
        lda #0
        sta sc_len
        sta sc_len+1
-       lda sc_len
        clc
        adc sc_tmp
        sta sc_len
        bcc +
        inc sc_len+1
+       dey
        bne -
        rts

; sc_mul24 - sc_num (24 bits) times A (1-255; 0 as 1). clobbers A, X, Y
sc_mul24
        cmp #0
        bne +
        rts
+       sta sc_mul
        ldx #2
-       lda sc_num,x
        sta sc_x,x
        lda #0
        sta sc_num,x
        dex
        bpl -
        ldy #8
-       asl sc_num              ; product * 2
        rol sc_num+1
        rol sc_num+2
        asl sc_mul
        bcc +
        clc                     ; + the number
        lda sc_num
        adc sc_x
        sta sc_num
        lda sc_num+1
        adc sc_x+1
        sta sc_num+1
        lda sc_num+2
        adc sc_x+2
        sta sc_num+2
+       dey
        bne -
        rts

; -----------------------------------------------------------------------------
; launch_scene_key - (SHIFT+RETURN on the song screen, or MIDI) scene A
; launched: playing, at the playing scene's next bar line (launch_arm);
; stopped, the scene the song starts from (start_scene; the song reset to
; it unless it is there: SPACE then plays it).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
launch_scene_key
        tax
        lda play_state
        cmp #PLAY_RUNNING
        beq _playing
        cmp #PLAY_STOPPED
        bne _rts                ; (held: a stop or start under way)
        lda stop_phase
        bne _rts
        stx start_scene
        cpx play_scene
        bne +
        lda pos_zero
        bne _rts                ; (there already)
+       lda #STOP_RESET         ; the song reset to it (transport.asm, a piece at a time)
        sta stop_phase
        lda #PLAY_HELD
        sta play_state
_rts    rts
_playing
        lda #0
        sta launch_by_song
        lda #LAUNCH_SCENE
        jmp launch_arm

; -----------------------------------------------------------------------------
; launch_arm - (main loop, playing) a launch (A: LAUNCH_SCENE or the track,
; X: the scene) armed at the playing scene's next bar line past the
; renderer; launch_arm_at - at the pass in sc_num if still ahead of the
; renderer, else at the next bar line (the song's end came too soon).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
launch_arm
        sta sc_kind
        stx sc_what
        jmp launch_bar
launch_arm_at
        sta sc_kind
        stx sc_what
        php
        sei
        lda scene_ver           ; a launch made since scene_poll began: computed again
        cmp sc_ver              ; at its next look
        beq +
        plp
        rts
+       lda pl_music            ; ahead of the renderer?
        cmp sc_num
        lda pl_music+1
        sbc sc_num+1
        lda pl_music+2
        sbc sc_num+2
        bcs +
        jmp launch_commit       ; (yes: armed there)
+       plp
        ; the next bar line past the renderer: x = pl_music + 1 less its
        ; place in its bar, a bar on while not past the renderer
launch_bar
        lda scene_ver           ; (a launch made while this is computed: again)
        sta sc_ver
        php
        sei
        lda pl_music
        clc
        adc #1
        sta sc_x
        lda pl_music+1
        adc #0
        sta sc_x+1
        lda pl_music+2
        adc #0
        sta sc_x+2
        plp
        ldx play_scene
        jsr bar_passes
        lda sc_x
        sec
        sbc scene_origin
        sta sc_num
        lda sc_x+1
        sbc scene_origin+1
        sta sc_num+1
        lda sc_x+2
        sbc scene_origin+2
        sta sc_num+2
        jsr sc_mod              ; sc_rem: x's place in its bar
        lda sc_x                ; x's bar line: x - its place (then a bar on, below,
        sec                     ; unless x is on it: past the renderer already)
        sbc sc_rem
        sta sc_num
        lda sc_x+1
        sbc sc_rem+1
        sta sc_num+1
        lda sc_x+2
        sbc #0
        sta sc_num+2
        ; armed, unless the renderer got there meanwhile: then a bar on
-       php
        sei
        lda pl_music
        cmp sc_num
        lda pl_music+1
        sbc sc_num+1
        lda pl_music+2
        sbc sc_num+2
        bcc +
        plp
        lda sc_num
        clc
        adc sc_len
        sta sc_num
        lda sc_num+1
        adc sc_len+1
        sta sc_num+1
        bcc -
        inc sc_num+2
        bne -
+       lda scene_ver
        cmp sc_ver
        beq launch_commit
        plp                     ; (the playing scene changed meanwhile)
        jmp launch_bar
; launch_commit - (interrupts off, the flags pushed) the launch armed at
; sc_num: its kind, scene and pass, then pending
launch_commit
        lda sc_kind
        sta launch_kind
        lda sc_what
        sta launch_what
        lda sc_num
        sta launch_at
        lda sc_num+1
        sta launch_at+1
        lda sc_num+2
        sta launch_at+2
        lda #1
        sta launch_pending
        inc scene_ver
        plp
        ; (on into launch_log)

; launch_log - (tests) LOG_LAUNCH_ASK: the renderer's pass now (as close to
; the arming as the log gets), the launch's pass, what. clobbers A, X
launch_log
.if TEST_LOG
        php
        sei
        lda $01                 ; (I/O in: the keys come here with it out)
        pha
        lda #RAM_IO
        sta $01
        lda pl_music
        sta log_a_value
        lda #LOG_LAUNCH_ASK
        jsr log_a
        lda pl_music+1
        sta log_a_value
        lda #LOG_LAUNCH_ASK
        jsr log_a
        lda launch_at
        sta log_a_value
        lda #LOG_LAUNCH_ASK
        jsr log_a
        lda launch_at+1
        sta log_a_value
        lda #LOG_LAUNCH_ASK
        jsr log_a
        lda launch_kind
        bmi +
        ora #$80
        bne ++
+       lda launch_what
+       sta log_a_value
        lda #LOG_LAUNCH_ASK
        jsr log_a
        pla
        sta $01
        plp
.endif
        rts

; -----------------------------------------------------------------------------
; rec_key - (song.asm, a key on the song screen; in rec_key_base's place)
; stage E's keys (scene_key), else on to rec_key_base (C= R,
; C= U). Carry set = the key was used.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_key
        jsr scene_key
        bcc +
        rts
+       jmp rec_key_base

; -----------------------------------------------------------------------------
; scene_launch_cell - (C= RETURN) the cursor's cell launched on its track:
; playing, at the next bar line; stopped, nothing (the song starts from
; whole scenes). clobbers A, X, Y
; -----------------------------------------------------------------------------
scene_launch_cell
        lda play_state
        cmp #PLAY_RUNNING
        bne +
        lda #0
        sta launch_by_song
        lda song_cursor
        ldx song_row
        jmp launch_arm
+       rts

; =============================================================================
; The song screen: row 1, the title's scene, the marks
; =============================================================================

; -----------------------------------------------------------------------------
; song_prepare - (in song_prepare_base's place) row 1 on the song screen:
; the cursor's scene (scene_row1); else as song_prepare_base.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_prepare
        lda song_mode
        bne +
        cpx #SONG_INFO_ROW
        beq scene_row1
+       jmp song_prepare_base

SONG_INFO_ROW   = 1
COL_INFO        = 12            ; grey (as the labels)

; scene_row1 - row 1 prepared: "SONG  SC 05  2 BARS  4/4  X3", SONG
; reversed while Song is on (the user, 2026-11-23). clobbers A, X, Y
scene_row1
        lda #LINE_OTHER
        sta song_line_kind
        ldy #39
-       lda row1_text,y
        sta song_line,y
        lda #COL_INFO
        sta song_line_col,y
        dey
        bpl -
        lda song_on
        beq +
        ldy #3
-       lda song_line,y
        ora #CHAR_REVERSE
        sta song_line,y
        lda #COL_SONG_TITLE
        sta song_line_col,y
        dey
        bpl -
+       ldx song_row
        txa
        clc
        adc #1
        ldy #ROW1_SCENE
        jsr song_num2
        ldx song_row
        lda SCENE_BARS,x
        cmp #10
        bcs +
        ora #CHAR_DIGIT0        ; (1-9: a digit)
        sta song_line+ROW1_BARS+1
        bne ++
+       ldy #ROW1_BARS
        jsr song_num2
+       ldx song_row            ; "BAR " for one
        lda SCENE_BARS,x
        cmp #1
        bne +
        lda #CHAR_SPACE
        sta song_line+ROW1_BARS+6
+       ldx song_row
        lda SCENE_SIG,x         ; n/4 or n/8
        and #$0f
        clc
        adc #1
        cmp #10
        bcs +
        ora #CHAR_DIGIT0
        sta song_line+ROW1_SIG+1
        bne ++
+       ldy #ROW1_SIG
        jsr song_num2
+       ldx song_row
        lda SCENE_SIG,x
        bmi +
        lda #CHAR_DIGIT0+4
        bne ++
+       lda #CHAR_DIGIT0+8
+       sta song_line+ROW1_SIG+3
        ldx song_row
        lda SCENE_REPEATS,x
        ora #CHAR_DIGIT0
        sta song_line+ROW1_REP
        rts

        .enc "screen"
row1_text       .text "SONG  SC 01   1 BARS   4/4  X1          "
        .enc "none"
        .cerror * - row1_text != 40, "row 1's text: 40 characters"
ROW1_SCENE      = 9             ; its places in row1_text
ROW1_BARS       = 13            ;   (2 places, then " BARS")
ROW1_SIG        = 22            ;   (2 places, "/", 4 or 8)
ROW1_REP        = 29

; -----------------------------------------------------------------------------
; song_scene_line - (in song_scene_line_base's place) a scene's row, then
; its marks: '+' after the number of a scene launch waiting, '>' in the gap
; before a cell playing on its track by launch (C= RETURN) and '+' before
; one waiting.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_scene_line
        jsr song_scene_line_base
        lda #CHAR_SPACE         ; the mark: '>' the scene playing (shown so), '+' one
        ldx #COL_LABEL          ; launched (song.asm's own test is of play_scene1)
        ldy song_line_scene
        cpy play_scene
        bne +
        ldy song_shown_state
        beq +
        lda #CHAR_MARK
        ldx #COL_SONG_TITLE
+       sta song_line+SONG_MARK_COL
        stx song_line_col+SONG_MARK_COL
        lda launch_pending
        beq _cells
        lda launch_kind
        bpl _cells
        lda launch_what
        cmp song_line_scene
        bne _cells
        lda #CHAR_PLUS
        sta song_line+SONG_MARK_COL
        lda #COL_SONG_TITLE
        sta song_line_col+SONG_MARK_COL
_cells  ldy #SONG_TRACKS-1      ; the half's tracks: a mark before their cells
-       tya
        ora song_half
        tax
        lda ovr_scene,x
        cmp song_line_scene
        bne +
        lda #CHAR_MARK
        jsr _mark
+       lda launch_pending
        beq +
        cpx launch_kind
        bne +
        lda launch_what
        cmp song_line_scene
        bne +
        lda #CHAR_PLUS
        jsr _mark
+       dey
        bpl -
        rts
_mark   pha                     ; (at the cell's column - 1: Y the cell)
        tya
        asl
        asl
        adc #SONG_CELL_COL0-1   ; (carry clear)
        tax
        pla
        sta song_line,x
        tya                     ; (X: the track again)
        ora song_half
        tax
        rts


; -----------------------------------------------------------------------------
; scene_shown_check - (count_state_check, every draw step) a launch armed,
; made or dropped since drawn (scene_ver): the title (its scene) and every
; scene row (their marks); row 1's values (the cursor's scene, Song).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
scene_shown_check
        lda song_mode
        bne _done               ; (the step grid shown)
        lda scene_ver
        cmp shown_ver
        beq _row1
        sta shown_ver
        jsr song_dirty_grid
        ldx #SONG_TITLE_ROW
        jsr song_urgent_row
_row1   ldx song_row
        lda song_row
        cmp shown_row1
        bne +
        lda song_on
        cmp shown_row1+1
        bne +
        lda SCENE_BARS,x
        cmp shown_row1+2
        bne +
        lda SCENE_SIG,x
        cmp shown_row1+3
        bne +
        lda SCENE_REPEATS,x
        cmp shown_row1+4
        beq _done
+       lda song_row
        sta shown_row1
        lda song_on
        sta shown_row1+1
        lda SCENE_BARS,x
        sta shown_row1+2
        lda SCENE_SIG,x
        sta shown_row1+3
        lda SCENE_REPEATS,x
        sta shown_row1+4
        ldx #SONG_INFO_ROW
        jmp song_urgent_row
_done   rts

; =============================================================================
; Tests
; =============================================================================

.if TEST_LOG
; song_log_drawn - (tests, song.asm: a row drawn; in song_log_drawn_base's
; place) row 1 logs LOGGED_ROW1 (screen_check.py: row 1's keys); else as
; before. log_key - (in log_key_base's place) a key read with SHIFT held
; logs LOG_SHIFT first (screen_check.py: SHIFT+RETURN isn't RETURN).
LOGGED_ROW1     = $a1
LOG_SHIFT       = 34
song_log_drawn
        lda song_mode
        bne +
        ldx song_draw_row
        cpx #SONG_INFO_ROW
        bne +
        lda #LOGGED_ROW1
        jmp log_drawn
+       jmp song_log_drawn_base
log_key
        ldx shift_held
        beq +
        pha
        php
        sei
        stx log_a_value
        lda #LOG_SHIFT
        jsr log_a
        plp
        pla
+       jmp log_key_base
.endif

.if TEST_SCENES
; -----------------------------------------------------------------------------
; scene_test - (tests, scene_poll) once: the test's scenes (tables.py
; scene_tests: rows 2.., each scene's bars, signature, repeats) and Song;
; then its actions at their play ticks (a scene or a cell launched, Song
; on or off), as the keys would.
; -----------------------------------------------------------------------------
scene_test
        jmp scene_test_act
; st_init - (scene_init, at start: before the metronome's phase is found) the
; test's scenes and Song
st_init
        ldx #0
-       lda st_rows,x           ; scenes 2.. (scene 1 is the test scene's row)
        sta SCENES+NUM_TRACKS,x
        inx
        cpx #st_rows_end-st_rows
        bne -
        ldx #ST_SCENES-1
-       lda st_bars,x
        sta SCENE_BARS,x
        lda st_sigs,x
        sta SCENE_SIG,x
        lda st_reps,x
        sta SCENE_REPEATS,x
        dex
        bpl -
        lda #ST_SONG
        sta song_on
        lda #ST_ROW             ; (the cursor's scene: a take's, TEST_RECORD)
        sta song_row
        rts
scene_test_act
_act    ldx st_next             ; the next action due?
        lda st_actions+2,x
        cmp #$ff
        bne +
_out    rts
+       cmp #ST_CONTINUE        ; (a continue: once stopped, whatever the tick)
        bne +
        lda play_state
        cmp #PLAY_STOPPED
        bne _out
        lda stop_phase
        bne _out
        jsr transport_continue
        jmp _next
+       lda play_state
        cmp #PLAY_RUNNING
        bne _out
        lda play_tick
        cmp st_actions,x
        lda play_tick+1
        sbc st_actions+1,x
        bcc _out
        lda st_actions+2,x      ; 0 a scene, 1 a cell (track, scene), 2 Song (on/off),
        beq _scene              ; 3 a pattern into the playing scene's cell (track,
        cmp #1                  ; pattern: as + does), 4 a stop
        beq _cell
        cmp #ST_PUT
        beq _put
        cmp #ST_STOP
        bne +
        jsr transport_stop
        jmp _next
+       lda st_actions+3,x
        sta song_on
        jmp _next
_scene  lda st_actions+3,x
        jsr launch_scene_key
        jmp _next
_cell   lda #0
        sta launch_by_song
        lda st_actions+3,x
        pha
        lda st_actions+4,x
        tax
        pla
        jsr launch_arm
        jmp _next
_put    lda play_scene          ; the playing scene's row: the cell (self-modified)
        asl
        asl
        asl
        asl
        clc
        adc st_actions+3,x      ; (+ the track)
        sta _cell_at+1
        lda play_scene
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>SCENES
        sta _cell_at+2
        lda st_actions+4,x
_cell_at
        sta SCENES
        lda st_actions+3,x
        sta lv_scan             ; (the live switch looks there first, as song.asm)
_next   lda st_next
        clc
        adc #5
        sta st_next
_rts    rts
st_next         .byte 0
ST_PUT          = 3
ST_STOP         = 4
ST_CONTINUE     = 5
.endif

        .send

; the keys (in main RAM: under I/O there was no room)
        .section late_code

; -----------------------------------------------------------------------------
; scene_key - (rec_key) stage E's keys on the song screen
; (the user, 2026-11-23): C= S Song on/off, C= B / C= N the cursor's
; scene's bars down / up, C= T its beats (SHIFT: n/4 or n/8), C= X its
; repeats (SHIFT: down), SHIFT+RETURN the cursor's scene launched, C=
; RETURN its cell. Carry set = used (the key's release too). A, the key
; code, kept when not.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
scene_key
        cmp #KEY_RETURN
        bne _cbm
        ldx shift_held          ; SHIFT+RETURN or C= RETURN
        bne _ret
        tax
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq _not
        lda want_press
        beq _used
        jsr scene_launch_cell
        jsr song_urgent_cursor  ; (its '+' at once)
        jmp _used
_ret    ldx want_press
        beq _used
        lda song_row
        jsr launch_scene_key
        jsr song_urgent_cursor  ; (its '+' at once)
        jmp _used
        ; C= with S, B, N, T, X
_cbm    tax
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq _not
        txa
        ldy #KEYS_E-1
-       cmp scene_keys,y
        beq +
        dey
        bpl -
        bmi _not
+       lda want_press
        beq _used
        ldx song_row
        tya
        asl
        tay
        lda scene_key_jumps+1,y
        pha
        lda scene_key_jumps,y
        pha
        rts                     ; (to the key's routine - 1)
_used   sec
        rts
_not    txa
        clc
        rts

scene_keys      .byte KEY_S, KEY_B, KEY_N, KEY_T, KEY_X
KEYS_E          = * - scene_keys
scene_key_jumps .word sk_song-1, sk_bars_down-1, sk_bars_up-1, sk_sig-1, sk_repeats-1

; the keys' routines: X = the cursor's scene; carry set on return (used)
sk_song lda song_on
        eor #1
        sta song_on
        bne _on
        php                     ; off: a launch the song armed dropped
        sei
        lda launch_by_song
        beq +
        lda #0
        sta launch_pending
        sta launch_by_song
        inc scene_ver
+       plp
_on     sec
        rts
sk_bars_down
        lda SCENE_BARS,x
        cmp #2
        bcc +
        dec SCENE_BARS,x
+       sec
        rts
sk_bars_up
        lda SCENE_BARS,x
        cmp #BARS_MAX
        bcs +
        inc SCENE_BARS,x
+       sec
        rts
sk_sig  lda shift_held          ; SHIFT: n/4 or n/8
        beq +
        lda SCENE_SIG,x
        eor #SIG_EIGHTHS
        sta SCENE_SIG,x
        sec
        rts
+       lda SCENE_SIG,x         ; the beats, 1-16 round
        and #$0f
        cmp #SIG_BEATS_MAX-1
        bcc +
        lda SCENE_SIG,x
        and #SIG_EIGHTHS
        sta SCENE_SIG,x
        sec
        rts
+       inc SCENE_SIG,x
        sec
        rts
sk_repeats
        lda shift_held
        bne _down
        lda SCENE_REPEATS,x
        cmp #REPEATS_MAX
        bcs +
        inc SCENE_REPEATS,x
+       sec
        rts
_down   lda SCENE_REPEATS,x
        cmp #2
        bcc +
        dec SCENE_REPEATS,x
+       sec
        rts

        .send
