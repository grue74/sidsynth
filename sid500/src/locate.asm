; locate.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Song position as slave (docs/design.md section 5e; the user,
; 2026-11-24): with Clock on MIDI and stopped, a master's song position
; locates the song at once at that 16th, and the Continue after it plays
; from there (~55 ms late with the band, then caught up: the locate);
; positions count through the song (Song on: the scene rows with their bars
; and repeats, round to scene 1; Song off: the start scene, each track
; playing on at its own length), as the song played from its start would
; be there. After a stop the song stays ready at the stop's 16th (the
; user, 2026-11-24: a bare Continue on time; a Start away from the start
; ~29 ms late, as in stage A).
;
; A locate is a reset (as scene.asm player_reset: the start scene, no
; launch, every place from pass 0), then the song's scene at the 16th and
; its origin set as a launch there would, the music's pass at the 16th
; (pl_music: swing's passes in an odd 16th's first half), and each track's
; reader read up to its place, a track a piece while the 250 Hz tick has
; time; then the stop's own last pieces (transport.asm stop_there: the
; 16th's snapshot, the lead rendered). The song position's bytes are taken
; in the receive interrupt, which holds the player at once (a Continue
; right after it is then asked, not played from the old place).
;
; All of it after the tables (late_code): hooks.asm's call of
; transport_poll and the core's of synth_rx_irq (scene.asm's renamed
; synth_rx_irq_scene) come here first, so nothing before them moves.

LOC_NONE        = 0             ; loc_phase: no locate under way
LOC_TRACKS      = 1             ;   the tracks' readers, a track a piece
LOG_LOCATED     = 35            ; (tests, log a) a locate begun: its 16th (low, high)
LOG_LOCATED_SET = 36            ; (tests, log a) its readers set (the lead next)
LOG_LOCATED_PLACE = 37          ; (tests, log a) a track's place (low byte), the origin's
SPP_DATA1       = $80           ; spp_state: song position's first data byte next
SPP_DATA2       = $40           ;   its second

; the variables: after names.asm's (main RAM, whatever $01 is; the receive
; interrupt's first)
        .virtual names_vars_end
spp_state       .byte ?         ; SPP_*: where in a song position message (0: not in one)
spp_lo          .byte ?         ; its 16th, low 7 bits
spp_hi          .byte ?         ;   high 7 bits
spp_ask         .byte ?         ; nonzero: a song position came (slave, stopped: held)
loc_phase       .byte ?         ; LOC_*
loc_16th        .word ?         ; the 16th being located
loc_track       .byte ?         ; the next track's reader to set
loc_t           .fill 3         ; the 16th's tick; then the song's: where the walk is
loc_m           .fill 3         ; the music's pass at the 16th
loc_org         .fill 3         ; the scene's origin (its tick and pass: a bar line)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
loc_k           .byte ?         ; the walk's scene
        .send
loc_turned      .byte ?         ;   nonzero: the song came round to scene 1 once
loc_req         .byte ?         ;   _hold: slave_req hidden from it
loc_unlimited   .byte ?         ; nonzero: locate_done set stop_unlimited (cleared after)
loc_pieces      .byte ?         ; nonzero: the stop's pieces under way are a locate's own
                                ; (no Continue came: STOP_CLEAR on), dropped by a new one
locate_vars_end
        .endv
        .cerror locate_vars_end > $d000, "the locate's variables run past $CFFF"

        .section late_code

; -----------------------------------------------------------------------------
; synth_rx_irq - (core MIDI_RX_IRQ, every byte but realtime; in
; scene.asm synth_rx_irq_scene's place) a song position (status $F2, then
; two data bytes): as slave and stopped, the player held and the position
; asked (locate_poll); every byte on to synth_rx_irq_scene. Any other
; status ends a song position not yet whole. A few compares on other
; bytes (thru's lag). keeps A
; -----------------------------------------------------------------------------
synth_rx_irq
        bit spp_state
        bmi _data1
        bvs _data2
        cmp #MIDI_SONG_POSITION
        beq _begin
        jmp synth_rx_irq_scene
_begin  pha
        lda #SPP_DATA1
        sta spp_state
        pla
        jmp synth_rx_irq_scene
_data1  cmp #$80
        bcs _end                ; (a status: not a song position)
        sta spp_lo
        pha
        lda #SPP_DATA2
        sta spp_state
        pla
        jmp synth_rx_irq_scene
_data2  cmp #$80
        bcs _end
        sta spp_hi
        pha
        lda #0
        sta spp_state
        lda params+P_CLOCK      ; slave and stopped: held, asked
        beq _done
        lda play_state
        cmp #PLAY_STOPPED
        beq +
        cmp #PLAY_HELD          ; (a stop being done: asked for after it)
        bne _done               ; (playing: ignored, as the family's)
+       lda #PLAY_HELD
        sta play_state
        lda #1
        sta spp_ask
_done   pla
        jmp synth_rx_irq_scene
_end    pha
        lda #0
        sta spp_state
        pla
        cmp #MIDI_SONG_POSITION
        beq _begin
        jmp synth_rx_irq_scene

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; locate_init - (synth_init: io_copy_all) no locate under way, no song
; position coming or asked, nothing located since a stop (the RAM is junk
; at power-on). clobbers A
; -----------------------------------------------------------------------------
locate_init
        lda #0
        sta loc_phase
        sta spp_state
        sta spp_ask
        sta loc_unlimited
        sta loc_pieces
        rts
        .send

; -----------------------------------------------------------------------------
; locate_poll - (hooks.asm synth_tick, in transport_poll's place) a locate
; under way: its next pieces (transport_poll after it). A song position
; asked (as slave, stopped: held): located (or nothing to do: already
; there). Then transport_poll.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
locate_poll
.if TEST_ARM
        jsr arm_test            ; (tests: C= R stopped as slave)
.endif
        lda loc_phase
        beq _asks
        jsr locate_tracks       ; (more pieces; done: the stop's own after it, and
        lda loc_phase           ; what was asked meanwhile looked at)
        beq _asks
        rts
_asks   lda params+P_CLOCK
        beq _transport          ; (master)
        lda spp_ask
        beq _transport
        lda play_state
        cmp #PLAY_HELD
        bne _transport
        lda stop_phase
        beq +
        lda loc_pieces          ; a locate's own pieces (no Continue came): dropped,
        bne _drop               ; the new locate makes them again (a stop's: done
        jmp _hold               ; first, its offs sent; _hold)
_drop   lda #0
        sta stop_phase
        sta loc_pieces
+
        php                     ; the 16th asked
        sei
        lda #0
        sta spp_ask
        lda spp_hi              ; (14 bits: hi * 128 + lo)
        lsr a
        sta loc_16th+1
        lda #0
        ror a
        ora spp_lo
        sta loc_16th
        plp
        jsr locate_there        ; (there already: nothing to do)
        bcs _transport
        jmp locate_begin
_transport
        jsr transport_poll
        lda stop_phase          ; (the pieces done: a locate's no more; at once no more)
        bne +
        sta loc_pieces
        lda loc_unlimited
        beq +
        lda #0
        sta loc_unlimited
        sta stop_unlimited
+
_rts    rts

; _hold - a locate due after the pieces being done (a song position asked
; during a stop): the pieces
; (transport_poll) with what was asked hidden (the Continue would go as they
; end, from the wrong place); ended, the player held again for the
; locate, what was asked given back. (A locate's own pieces are dropped
; instead: _asks.)
_hold   php
        sei
        lda slave_req
        sta loc_req
        lda #0
        sta slave_req
        plp
        jsr transport_poll
        php
        sei
        lda slave_req           ; (a Start since: kept)
        bne +
        lda loc_req
        sta slave_req
+       lda play_state
        cmp #PLAY_STOPPED
        bne +
        lda #PLAY_HELD
        sta play_state
+       plp
        rts

; locate_there - the song ready at loc_16th already (stopped or held, no
; stop being done): carry set. clobbers A
locate_there
        lda loc_16th
        ora loc_16th+1
        bne +
        lda pos_zero            ; (the start: ready there)
        cmp #1
        rts
+       lda pos_zero
        bne _no
        lda locate_16th
        cmp loc_16th
        bne _no
        lda locate_16th+1
        cmp loc_16th+1
        bne _no
        sec
        rts
_no     clc
        rts

; -----------------------------------------------------------------------------
; locate_begin - (the player held, stopped: nothing sounds) the song to
; 16th loc_16th: as scene.asm player_reset, the wheel cleared later
; (locate_done): no launch armed, no cell launched, a live switch not yet
; made dropped; swing's row; the scene there (locate_scene), the music's
; pass (locate_music), the tracks' readers next (LOC_TRACKS, each as a
; launch: launch_track). Then the stop's last pieces (locate_done).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
locate_begin
        jsr hi3_in              ; (disk.asm: the note map free; the code at HI3_CODE back)
.if TEST_LOG
        php                     ; (tests: the 16th located)
        sei
        lda loc_16th
        sta log_a_value
        lda #LOG_LOCATED
        jsr log_a
        lda loc_16th+1
        sta log_a_value
        lda #LOG_LOCATED
        jsr log_a
        plp
.endif
        inc scene_ver           ; (the song screen's marks)
        inc pl_jumps            ; (live.asm: a switch not yet made dropped)
        lda #0
        sta sw_pending
        sta launch_pending
        sta take_cut
        sta last_status
        ldx #NUM_TRACKS-1
-       lda #OVR_NONE
        sta TRACK_OVERRIDE,x
        sta ovr_scene,x
        dex
        bpl -
        jsr player_set_swing
        lda loc_16th            ; the tick: 16th * 12 (24 bits)
        sta sc_num
        lda loc_16th+1
        sta sc_num+1
        lda #0
        sta sc_num+2
        lda #12
        jsr sc_mul24
        ldx #2
-       lda sc_num,x
        sta loc_t,x
        lda #0                  ; (the start's pass: 0)
        sta loc_m,x
        dex
        bpl -
        jsr locate_scene        ; (the start: the start scene, every place 0)
        lda loc_16th
        ora loc_16th+1
        beq +
        jsr locate_music
+       lda #0
        sta loc_track
        lda #LOC_TRACKS
        sta loc_phase
        rts

; locate_done - the readers set: the wheel cleared (a locate's lead before
; may have left offs in it), the 16th's tick the song's (the player's ticks,
; its snapshot, its lead: transport.asm stop_there, stop_first_part), as a
; stop's last pieces (STOP_CLEAR on), done after them; with a Start or
; Continue waiting, the clearing at once and only the first tick rendered.
; clobbers A, X, Y
locate_done
.if TEST_LOG
        php                     ; (tests: the readers set)
        sei
        lda #0
        sta log_a_value
        lda #LOG_LOCATED_SET
        jsr log_a
        plp
.endif
        lda #CK_LOCATED         ; (clock.asm: the time display from here)
        sta ck_jump
        lda #LOC_NONE
        sta loc_phase
        lda loc_16th
        sta locate_16th
        lda loc_16th+1
        sta locate_16th+1
        lda loc_t
        sta locate_tick
        lda loc_t+1
        sta locate_tick+1
        ldx #2                  ; the music's pass
-       lda loc_m,x
        sta pl_music,x
        dex
        bpl -
        jsr active_build
        lda #STOP_DONE
        sta stop_then
        lda slave_req           ; no Start or Continue waiting: the wheel cleared (the
        bne +                   ; lead of a locate before may have left offs), its 16th,
        sta stop_page           ; as a stop's last pieces, a piece at a time (a song
        lda #STOP_CLEAR         ; position meanwhile drops them: locate_poll)
        sta stop_phase
        sta loc_pieces
        rts
+       jsr wheel_clear         ; one waiting: at once
        jsr stop_there
        lda slave_req           ; only the first tick
        beq +                   ; rendered before it goes, the timer interrupt renders
        ldx ren_tick            ; the rest of the lead as it plays (as
        inx                     ; click.asm player_prepare_quick), and the pieces at
        stx render_first_end    ; once (stop_unlimited, until locate_poll sees it gone)
        sta stop_unlimited
        sta loc_unlimited
+       rts

; -----------------------------------------------------------------------------
; locate_scene - the song's scene at tick loc_t and its origin: Song off,
; the start scene from 0 (it plays on, never launched again); Song on, the
; rows from the start scene, each its bars * its bar * its repeats, then
; the next row (or scene 1 after the last), as scene_poll arms them;
; once round at scene 1, the tick taken modulo the song's round from there.
; The scene set as a launch makes it (scene_set, scene_origin, scene_tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
locate_scene
        lda #0
        sta loc_org
        sta loc_org+1
        sta loc_org+2
        sta loc_turned
        sta ck_bars             ; (clock.asm: the bars passed, the rounds left out)
        sta ck_bars+1
        sta ck_q
        sta ck_q+1
        lda start_scene
        sta loc_k
        lda song_on
        beq _found
_scene  ldx loc_k               ; its length: sc_num
        jsr locate_len
        ldx #0                  ; ends after the tick? (org + len > t)
        clc
-       lda loc_org,x
        adc sc_num,x
        sta sc_x,x
        inx
        txa
        eor #3
        bne -
        lda loc_t
        cmp sc_x
        lda loc_t+1
        sbc sc_x+1
        lda loc_t+2
        sbc sc_x+2
        bcc _found
        ldx #2                  ; on past it
-       lda sc_x,x
        sta loc_org,x
        dex
        bpl -
        ldx loc_k               ; (clock.asm: its bars counted)
        jsr ck_add_bars
        inx                     ; the next row, or scene 1
        cpx #NUM_SCENES
        bcs _first
        jsr scene_empty
        bne +
_first  ldx #0
+       stx loc_k
        txa
        bne _scene
        lda loc_turned          ; at scene 1 the first time: the tick within the
        bne _scene              ; song's round from here
        inc loc_turned
        jsr locate_round
        jmp _scene
_found  lda loc_k
        jsr scene_set
        ldx #2
-       lda loc_org,x
        sta scene_origin,x
        dex
        bpl -
        lda loc_org
        sta scene_tick
        lda loc_org+1
        sta scene_tick+1
        rts

; locate_len - sc_num = scene X (= loc_k) length in ticks (24 bits): its
; bar * its bars * its repeats. clobbers A, X, Y
locate_len
        jsr bar_passes          ; sc_len: the bar (bar_passes uses sc_tmp itself)
        lda sc_len
        sta sc_num
        lda sc_len+1
        sta sc_num+1
        lda #0
        sta sc_num+2
        ldx loc_k
        lda SCENE_BARS,x
        jsr sc_mul24
        ldx loc_k
        lda SCENE_REPEATS,x
        jmp sc_mul24

; locate_round - (the walk at scene 1, origin loc_org) the song's round from
; scene 1 summed (sc_x, every row to the first empty), and loc_t brought
; within one round of loc_org (loc_t - loc_org modulo it, a bit at a
; time). clobbers A, X, Y
locate_round
        lda #0
        sta sc_x
        sta sc_x+1
        sta sc_x+2
        ldx #0
_row    stx loc_k
        jsr locate_len
        ldx #0
        clc
-       lda sc_x,x
        adc sc_num,x
        sta sc_x,x
        inx
        txa
        eor #3
        bne -
        ldx loc_k
        inx
        cpx #NUM_SCENES
        bcs +
        jsr scene_empty
        bne _row
+       lda #0
        sta loc_k
        ldx #2                  ; sc_num = loc_t - loc_org
        sec
        ldy #0
-       lda loc_t,y
        sbc loc_org,y
        sta sc_num,y
        iny
        dex
        bpl -
        lda #0                  ; its remainder by the round (sc_rem, 24 bits)
        sta sc_rem
        sta sc_rem+1
        sta sc_tmp
        ldx #24
_bit    asl sc_num
        rol sc_num+1
        rol sc_num+2
        rol sc_rem
        rol sc_rem+1
        rol sc_tmp
        lda sc_rem
        sec
        sbc sc_x
        pha
        lda sc_rem+1
        sbc sc_x+1
        tay
        lda sc_tmp
        sbc sc_x+2
        bcc +
        sta sc_tmp
        sty sc_rem+1
        pla
        sta sc_rem
        inc sc_num              ; (the quotient's bit: the rounds, for clock.asm)
        jmp ++
+       pla
+       dex
        bne _bit
        lda sc_num              ; (clock.asm: the rounds left out)
        sta ck_q
        lda sc_num+1
        sta ck_q+1
        clc                     ; loc_t = loc_org + the remainder
        lda loc_org
        adc sc_rem
        sta loc_t
        lda loc_org+1
        adc sc_rem+1
        sta loc_t+1
        lda loc_org+2
        adc sc_tmp
        sta loc_t+2
        rts

; locate_music - loc_m = the music's pass at the 16th: its pairs of 16ths
; whole (24 passes each: swing moves passes only inside a pair), and in an
; odd 16th the first's passes (swing's row's first 12 ticks). clobbers A, Y
locate_music
        lda loc_16th+1          ; (16th / 2) * 24 = * 16 + * 8
        lsr a
        sta sc_num+1
        lda loc_16th
        ror a
        sta sc_num
        lda #0
        sta sc_num+2
        lda #24
        jsr sc_mul24
        ldx #2
-       lda sc_num,x
        sta loc_m,x
        dex
        bpl -
        lda loc_16th
        lsr a
        bcc _even
        lda #0                  ; the first 16th's passes
        clc
        ldy #TICKS_PER_STEP-1
-       adc (pl_swing_row),y
        dey
        bpl -
        clc
        adc loc_m
        sta loc_m
        bcc _even
        inc loc_m+1
        bne _even
        inc loc_m+2
_even   rts

; -----------------------------------------------------------------------------
; locate_tracks - (LOC_TRACKS) the tracks' readers, a track a piece while
; the 250 Hz tick has time (transport.asm stop_time; with a Start or a
; Continue waiting, all at once): each its scene cell's
; pattern from the scene's origin (as launch_track), its place the music's
; pass less the origin, modulo its length; its reader read to the first
; event at or after it (the events before read, not played: their
; prefixes set the velocity, length and controller); its place there,
; nothing to skip. All done: locate_done. clobbers A, X, Y
; -----------------------------------------------------------------------------
locate_tracks
_track  ldx loc_track
        cpx #NUM_TRACKS
        bcc +
        jmp locate_done
+       lda slave_req           ; (a Start or Continue waiting: the rest at once, the
        bne +                   ; main loop has nothing else to answer meanwhile)
        jsr stop_time
        bcs +
        rts                     ; (the next tick)
+       ldx loc_track
        jsr scene_cell          ; its pattern from the origin
        jsr launch_track
        lda loc_org
        sta TRK_ORG_0,x
        lda loc_org+1
        sta TRK_ORG_1,x
        lda loc_org+2
        sta TRK_ORG_2,x
        lda PLAY_PATTERN,x
        cmp #NO_PATTERN
        beq _next
        lda loc_m               ; its place: (pass - origin) mod its length
        sec
        sbc loc_org
        sta sc_num
        lda loc_m+1
        sbc loc_org+1
        sta sc_num+1
        lda loc_m+2
        sbc loc_org+2
        sta sc_num+2
        lda TRK_PLEN_LO,x
        sta sc_len
        lda TRK_PLEN_HI,x
        sta sc_len+1
        jsr sc_mod              ; (sc_rem)
.if TEST_LOG
        php                     ; (tests: the track's place, its origin's low byte)
        sei
        lda sc_rem
        sta log_a_value
        lda #LOG_LOCATED_PLACE
        jsr log_a
        lda loc_org
        sta log_a_value
        lda #LOG_LOCATED_PLACE
        jsr log_a
        plp
.endif
        ldx loc_track
        stx pl_track
        jsr track_restart       ; the reader at the start, the first event's time
_read   ldx loc_track           ; read to the first event at or after the place
        lda TRK_DUE_LO,x
        cmp sc_rem
        lda TRK_DUE_HI,x
        sbc sc_rem+1
        bcs _there
        jsr ev_read_event
        jsr track_next_time
        bcc _read
_there  jsr track_save
        ldx loc_track
        lda sc_rem
        sta TRK_POS_LO,x
        lda sc_rem+1
        sta TRK_POS_HI,x
        lda #0
        sta TRK_SKIP_LO,x
        sta TRK_SKIP_HI,x
_next   inc loc_track
        jmp _track

; -----------------------------------------------------------------------------
; count_arm - (rec_start_any, $01 = RAM_ALL: C= R stopped as slave) the
; take begun now (rec_start_now: its pattern, a new one in an empty cell;
; its place set again at the master's first tick, count_armed), armed
; (COUNT_ARMED: REC shown, nothing stamped till then). Nothing if the take
; can't begin. clobbers A, X, Y, ptr, pool_next, grid_ptr
count_arm
        lda #COUNT_ARMED        ; (rec_put_count: nothing stamped yet)
        sta count_state
        jsr rec_start_now
        lda rec_state
        cmp #REC_ON
        beq +
        lda #COUNT_NONE         ; (not begun)
        sta count_state
+       rts

; -----------------------------------------------------------------------------
; count_armed - (count_poll_io, $01 = RAM_ALL) the armed take's turn: C= R
; or SPACE (REC_STOPPING), or Clock now the C64's: disarmed, the take ended
; with nothing in it (carry set: rec_poll). Waiting for the master (carry
; clear: no take's turn). The master's first tick heard: the take's place
; from it (count_place), as ever from now on (carry set).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
count_armed
        lda params+P_CLOCK
        beq _end                ; (the C64's clock now)
        lda rec_state
        cmp #REC_ON
        bne _end                ; (C= R, SPACE: REC_STOPPING)
        lda play_state
        cmp #PLAY_RUNNING
        bne _wait
        lda play_tick           ; the first tick heard?
        cmp locate_tick
        bne +
        lda play_tick+1
        cmp locate_tick+1
        beq _wait
+       jsr count_place
_end    lda #COUNT_NONE
        sta count_state
        sec
        rts
_wait   clc
        rts

; -----------------------------------------------------------------------------
; count_place - (count_armed) the armed take's place from the master's
; first tick (it plays from locate_tick: the stop's 16th, a song
; position's, or the start): its pass as it began (TICK_MUSIC, while fewer
; than 16 ticks are rendered past it; else the pass heard now, the stamps
; before it dropped: the main loop held that long), then as take.asm
; rec_start: the loop's start (rec_origin: the track's place modulo the
; pattern's length, from its launch), rec_m0, rec_last. The stamps since
; the first tick stay in the ring. clobbers A, X, Y
; -----------------------------------------------------------------------------
count_place
        php
        sei
        sec                     ; the first tick's pass still in TICK_MUSIC?
        lda ren_tick
        sbc locate_tick
        tax
        lda ren_tick+1
        sbc locate_tick+1
        bne _late
        cpx #16
        bcs _late
        lda locate_tick
        and #15
        tax
        lda TICK_MUSIC_LO,x
        ldy TICK_MUSIC_HI,x
        jmp _pass
_late   lda #0                  ; (the stamps so far dropped: their passes may be
        sta rec_head            ; before the loop's start found from now)
        sta rec_tail
        jsr rec_now_out
_pass   sta rec_m0
        sty rec_m0+1
        sec                     ; the 24-bit pass: pl_music - (pl_music - it, 16 bits)
        lda pl_music
        sbc rec_m0
        sta rec_d
        lda pl_music+1
        sbc rec_m0+1
        sta rec_d+1
        sec
        lda pl_music
        sbc rec_d
        sta rec_num
        lda pl_music+1
        sbc rec_d+1
        sta rec_num+1
        lda pl_music+2
        sbc #0
        sta rec_num+2
        plp
        ldx rec_track           ; (the track's place counts from its launch)
        sec
        lda rec_num
        sbc TRK_ORG_0,x
        sta rec_num
        lda rec_num+1
        sbc TRK_ORG_1,x
        sta rec_num+1
        lda rec_num+2
        sbc TRK_ORG_2,x
        sta rec_num+2
        jsr rec_mod24           ; (rec_d: the place in the loop)
        sec
        lda rec_m0
        sbc rec_d
        sta rec_origin
        lda rec_m0+1
        sbc rec_d+1
        sta rec_origin+1
        lda rec_m0
        sta rec_last
        lda rec_m0+1
        sta rec_last+1
.if TEST_LOG
        jmp rec_log_start       ; (tests: the pass it began at, logged again)
.endif
        rts


; -----------------------------------------------------------------------------
; rec_put_armed - (rx_message, a take on: in rec_put_count's place) armed
; as slave (COUNT_ARMED): a message only from the master's first tick heard
; (play_tick past locate_tick, the tick it plays from; none before it: the
; user), then rec_put_count. clobbers A, X, Y
; -----------------------------------------------------------------------------
rec_put_armed
        lda count_state
        cmp #COUNT_ARMED
        bne _put
        lda play_state
        cmp #PLAY_RUNNING
        bne _out
        lda play_tick
        cmp locate_tick
        bne _put
        lda play_tick+1
        cmp locate_tick+1
        beq _out
_put    jmp rec_put_count
_out    rts


.if TEST_ARM
; -----------------------------------------------------------------------------
; arm_test - (tests, locate_poll: $01 = RAM_IO) once, at the first look
; stopped with nothing under way: C= R as the song screen would (count_arm)
; on track TEST_ARM; then with TEST_ARM_CANCEL at the next look while armed
; SPACE (1: REC_STOPPING, as count_key_io) or Clock the C64's (2).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
arm_test
        lda rec_test_done
        bne _cancel
        lda play_state
        cmp #PLAY_STOPPED
        bne _rts
        lda stop_phase
        ora loc_phase
        bne _rts
        inc rec_test_done
        lda #TEST_ARM-1
        sta song_cursor
        lda #RAM_ALL
        sta $01
        jsr count_arm
        lda #RAM_IO
        sta $01
_rts    rts
_cancel
.if TEST_ARM_CANCEL
        cmp #1
        bne _rts
        inc rec_test_done
        lda count_state
        cmp #COUNT_ARMED
        bne _rts
.if TEST_ARM_CANCEL == 1
        lda #REC_STOPPING
        sta rec_state
.else
        lda #0
        sta params+P_CLOCK
.endif
.endif
        rts
.endif

        .send
