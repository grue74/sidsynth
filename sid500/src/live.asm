; live.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The live switch (docs/design.md section 5; the user, 2026-11-21: a
; change to the playing scene is heard at once, in place). The player
; plays its own copy of the playing scene's row (PLAY_PATTERN); the main
; loop compares the row with it, a few tracks a 250 Hz tick (live_rule),
; and where a track's cell wants another pattern it switches the track:
;
; - a time to switch at, T: a pass over the tracks (player.asm pl_music,
;   the music's ticks, which swing makes differ from the ticks) a margin
;   past the renderer's;
; - the new pattern's reader (events.asm's ed_*, the main loop's own) read
;   to T modulo the pattern's length, every event read in full (its
;   prefixes change the velocity, length and controller), a few at a time
;   while the 250 Hz tick has time left (live_read), so neither the keys
;   nor the engine wait;
; - a record handed to the player (sw_*, sw_pending written last), which
;   it takes as the pass before T ends (live_due): the track's state from
;   it, ACTIVE built again when the track gains or loses a pattern. If the
;   renderer got to T first, T moves on (its place now, the margin grown by
;   how far past T it got) and the
;   reading goes on from where it is (from the start if T's place in the
;   pattern came round past it). In a busy 16th the main loop can be kept
;   out for longer than the margin (design 5): a few tries then.
;
; Stopped, the switch is made at once at the renderer's place (nothing
; renders meanwhile). A jump (player_reset, a snapshot restored by a
; stop: pl_jumps) drops a record not yet taken and any switch half read;
; a snapshot holds the patterns playing then (player.asm), so after a
; stop the rule finds the cells that differ again and switches them.
; Notes the old pattern started end at their own offs.
;
; An edit to a playing pattern (design 5, "Editing a playing pattern"):
; its new chain is published at once (live_publish) and every reader in
; the old one marked stale: a track playing it (PLAY_STALE) and its entry
; in either snapshot (SNAP_STALE); a switch being read from it, or handed
; over and not yet taken, is dropped. The rule switches a stale track to
; its pattern as it switches a changed cell (the new chain, read to T),
; and while stopped it moves a stale snapshot entry to the new chain the
; same way (T the snapshot's own pass: live_snap_rule). The old chain
; waits in the list of replaced chains until nothing anywhere is stale,
; then goes back to the pool (live_free). A track that comes to its
; pattern's end before its switch starts again in the new chain (ev_start
; reads the pattern table), at the old length until the switch.

LIVE_IDLE       = 0             ; lv_phase: looking for a track to switch (live_rule)
LIVE_READ       = 1             ;   reading its new pattern to its place (live_read)
LIVE_WAIT       = 2             ;   the record handed over, waiting for the player
LIVE_MARGIN_MIN = 2             ; passes past the renderer a switch is set for: half the
                                ; lead (render_ahead: ~21 ms at any tempo), at least 2
LIVE_SPARE_HI   = SLICE_SPARE_HI ; timer B's high byte: read on while more than that many
                                ; pages of cycles of the 250 Hz tick are left (as
                                ; render_slice; at least one event each time)
LIVE_RULE_TRACKS = 4            ; tracks the rule looks at a 250 Hz tick
LIVE_BURST      = 7             ; live_read: events read each time + 1, whatever the time
LIVE_TO_PLAYER  = 0             ; lv_dest: the switch is the player's track
LIVE_TO_SNAP_0  = 1             ;   or a stale entry of snapshot slot 0 (stopped only)
LIVE_TO_SNAP_1  = 2             ;   or of slot 1
RETIRE_MAX      = 8             ; replaced chains that can wait to be freed (a full list:
                                ; an edit waits, edit.asm)

; the main loop's and the record's variables, in the RAM the core leaves
; free without MIDI_SYSEX ($C280-$C2FF; events.asm's ed_* among them)
        .virtual $c280
        .dsection live_vars
live_vars_end
        .endv
        .cerror live_vars_end > $c300, "the live switch's variables run past $C2FF"
        .cerror MIDI_SYSEX, "MIDI_SYSEX uses $C280-$C2FF (live.asm's variables)"
        .cerror KERNAL_ZP_COPY >= $c200 && KERNAL_ZP_COPY < $c300, "KERNAL_ZP_COPY over live.asm's variables"

        .section live_vars
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
lv_phase        .byte ?         ; LIVE_*
        .send
lv_scan         .byte ?         ; the next track live_rule looks at
lv_dest         .byte ?         ; LIVE_TO_*: whose track is switched
lv_track        .byte ?         ; the track being switched
lv_pattern      .byte ?         ;   its new pattern (NO_PATTERN: none)
lv_jumps        .byte ?         ;   pl_jumps when it began (a jump: dropped)
lv_margin       .byte ?         ;   T's margin past the renderer, in passes
lv_base         .byte ?         ;   at first: half the lead
lv_at           .fill 3         ;   T: the pass it switches at (pl_music then)
lv_pos          .word ?         ;   T's place in the pattern: what the reader reads to
lv_plen         .word ?         ;   the pattern's length in ticks
lv_due          .word ?         ;   the reader's next event's time ($FFFF: the end)
lv_burst        .byte ?         ;   live_read: events still read whatever the time, - 1
lv_count        .byte ?         ; live_rule: tracks still to look at
lv_num          .fill 3         ; live_mod's scratch
lv_old_pos      .word ?         ; live_post's scratch
; the record (the main loop writes it while sw_pending is 0; the player
; reads it while it is 1)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
sw_pending      .byte ?         ; nonzero: the record ready (the player clears it)
        .send
sw_track        .byte ?         ; the track
sw_pattern      .byte ?         ; its new pattern (NO_PATTERN: none)
sw_at           .fill 3         ; T: switched as pl_music becomes T (a pass ends)
; (the track's state in the order of its arrays, TRK_PTR_LO..TRK_SKIP_HI:
; snap_apply copies it as one)
sw_ptr          .word ?         ; the reader at T (ed_*: as TRK_PTR ... TRK_CC)
sw_vel          .byte ?
sw_len          .word ?
sw_cc           .byte ?
sw_due          .word ?         ; its next event's time (TRK_DUE)
sw_pos          .word ?         ; T's place (TRK_POS)
sw_plen         .word ?         ; the pattern's length (TRK_PLEN)
sw_left         .byte ?         ;   (the reader's: TRK_LEFT)
sw_skip         .word ?         ; 0: its next pass plays at sw_pos (TRK_SKIP)
SW_STATE        = sw_skip + 2 - sw_ptr
        .cerror SW_STATE != (TRK_SKIP_HI - TRK_PTR_LO) / NUM_TRACKS + 1, "sw_* in the arrays' order"
        .cerror TRK_LEFT - TRK_PTR_LO != (sw_left - sw_ptr) * NUM_TRACKS, "sw_left's place"
sw_old          .byte ?         ; live_apply's scratch: the pattern before
pl_jumps        .byte ?         ; counted on by player_reset and snapshot_restore
; the replaced chains (live_publish), freed by live_free
retire_count    .byte ?
retire_lo       .fill RETIRE_MAX ; each one's first block
retire_hi       .fill RETIRE_MAX
lp_pattern      .byte ?         ; live_publish's scratch: the pattern
lp_steps        .byte ?         ;   its new length
lp_old          .word ?         ;   its old chain
lp_used         .byte ?         ;   nonzero: something reads the old chain
.if TEST_LOG
lp_log          .fill 4         ;   (tests) pl_music's low and middle bytes, pl_order,
                                ;   play_state * 16 + stop_phase then
.endif
.if TEST_LIVE
tl_next         .byte ?         ; test_live_tick: the next change in its table
tl_want         .byte ?         ;   TEST_LIVE 3: publishes asked by the key, not yet made
.endif
        .send

; -----------------------------------------------------------------------------
; live_init - (synth_init) no switch under way, none handed over.
; clobbers A
; -----------------------------------------------------------------------------
live_init
        lda #LIVE_IDLE
        sta lv_phase
        lda #0
        sta lv_scan
        sta sw_pending
        sta pl_jumps
        sta retire_count
.if TEST_LIVE
        sta tl_next
        sta tl_want
.endif
        rts

; -----------------------------------------------------------------------------
; live_slice - (main loop, synth_tick) the live switch's turn: playing (or
; stopped, no stop being done), the rule, the reading or the wait, as
; lv_phase says. Starting, held or in a stop: a switch half read is
; dropped (a record handed over is the player's to take or a jump's to
; drop).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_slice
        lda play_state
        cmp #PLAY_RUNNING
        beq _on
        cmp #PLAY_STOPPED
        bne _not_now
        lda stop_phase
        bne _not_now            ; (a stop or continue being done)
_on     lda lv_phase
        bne +
        lda grid_job            ; (the step grid decoding, or a take's merge: the reader
        cmp #JOB_DECODE         ; is theirs)
        bcs _wait
        jmp live_rule
+
        cmp #LIVE_READ
        bne +
        jmp live_read
+       jmp live_wait
_wait   jmp live_free
_not_now
        lda lv_phase
        cmp #LIVE_READ
        bne +
        lda #LIVE_IDLE
        sta lv_phase
+       jmp live_free

; -----------------------------------------------------------------------------
; live_rule - LIVE_RULE_TRACKS tracks from lv_scan on: the first whose cell
; in the playing scene wants another pattern than the one it plays, or
; playing, that reads a replaced chain (PLAY_STALE: its own pattern
; again), is switched (live_begin). song.asm points lv_scan at a track it
; changes. None: stopped, a stale snapshot entry (live_snap_rule); then
; the replaced chains (live_free).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_rule
        lda #LIVE_RULE_TRACKS
        sta lv_count
-       lda lv_scan
        and #NUM_TRACKS-1
        tax
        inc lv_scan
        jsr live_wanted
        cmp PLAY_PATTERN,x
        bne _switch
        ldy PLAY_STALE,x        ; stale: switched while playing (stopped: the song
        beq _next               ; prepared again from its 16th, live_snap_rule)
        ldy play_state
        cpy #PLAY_RUNNING
        beq _switch
_next   dec lv_count
        bne -
        jmp live_snap_rule
_switch ldy #LIVE_TO_PLAYER
        sty lv_dest
        jmp live_begin

; live_snap_rule - stopped (no stop being done: live_slice): the first
; stale entry of either snapshot moved to its pattern's new chain
; (live_begin; the pattern the snapshot's own). None, and a track still
; stale: the song prepared again from its 16th (transport.asm
; stop_reprepare: from the snapshot, now in the new chains, so a continue
; plays them from there). Else the replaced chains (live_free).
; clobbers A, X, Y
live_snap_rule
        lda play_state
        cmp #PLAY_STOPPED
        beq +
        jmp live_free
+       ldx #NUM_TRACKS-1
-       lda SNAPSHOT + SNAP_STALE,x
        bne _slot0
        lda SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        bne _slot1
        dex
        bpl -
        ldx #NUM_TRACKS-1       ; none: a track still stale?
-       lda PLAY_STALE,x
        bne _again
        dex
        bpl -
        jmp live_free
_again  jmp stop_reprepare
_slot0  ldy #LIVE_TO_SNAP_0
        lda SNAPSHOT + SNAP_PLAY,x
        jmp +
_slot1  ldy #LIVE_TO_SNAP_1
        lda SNAPSHOT + SNAP_SIZE + SNAP_PLAY,x
+       sty lv_dest
        jmp live_begin

; -----------------------------------------------------------------------------
; live_begin - track X to switch to pattern A: its length, T and T's place
; in it (live_target), the reader at the pattern's start; then reading.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_begin
        stx lv_track
        sta lv_pattern
        lda pl_jumps
        sta lv_jumps
        lda render_ahead        ; the margin: half the lead, at least LIVE_MARGIN_MIN
        lsr
        cmp #LIVE_MARGIN_MIN
        bcs +
        lda #LIVE_MARGIN_MIN
+       sta lv_margin
        sta lv_base
        lda #LIVE_READ
        sta lv_phase
        lda lv_pattern
        cmp #NO_PATTERN
        beq live_target         ; (none: nothing to read)
+
        ; the length in ticks: steps * 12 = steps * 8 + steps * 4
        tay
        lda PAT_STEPS,y
        sta lv_plen
        lda #0
        sta lv_plen+1
        asl lv_plen             ; * 4 (at most 512)
        rol lv_plen+1
        asl lv_plen
        rol lv_plen+1
        lda lv_plen+1
        sta lv_num+1
        lda lv_plen
        sta lv_num              ; (* 4 kept)
        asl                     ; * 8
        sta lv_plen
        rol lv_plen+1
        lda lv_plen
        clc
        adc lv_num
        sta lv_plen
        lda lv_plen+1
        adc lv_num+1
        sta lv_plen+1
        jsr live_target
        ; (on into live_read_start)

; live_read_start - the reader at lv_pattern's start, its first event's
; time in lv_due. clobbers A, X, Y
live_read_start
        lda lv_pattern
        jsr ed_start
        lda #0
        sta lv_due
        sta lv_due+1
        ; (on into live_next_time)

; live_next_time - the reader's next time: lv_due that much later ($FFFF
; at the pattern's end). clobbers A, X, Y
live_next_time
        jsr ed_read_time
        bcs _end
        lda lv_due
        adc ed_delta            ; (carry clear)
        sta lv_due
        lda lv_due+1
        adc ed_delta+1
        sta lv_due+1
        rts
_end    lda #$ff
        sta lv_due
        sta lv_due+1
        rts

; -----------------------------------------------------------------------------
; live_target - T (lv_at): the renderer's pass now, playing + lv_margin
; (a snapshot's entry: the snapshot's own pass); with a pattern, T's place
; in it (lv_pos = T mod lv_plen).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_target
        ldy lv_dest
        beq _player
        lda SNAP_MUSIC_0-1,y    ; (slot lv_dest - 1)
        sta lv_at
        lda SNAP_MUSIC_1-1,y
        sta lv_at+1
        lda SNAP_MUSIC_2-1,y
        sta lv_at+2
        jmp _place
_player php                     ; (pl_music's three bytes as one)
        sei
        lda pl_music
        sta lv_at
        lda pl_music+1
        sta lv_at+1
        lda pl_music+2
        sta lv_at+2
        plp
        lda play_state
        cmp #PLAY_RUNNING
        bne _place              ; (stopped: here)
        lda lv_at
        clc
        adc lv_margin
        sta lv_at
        bcc _place
        inc lv_at+1
        bne _place
        inc lv_at+2
_place  lda lv_pattern
        cmp #NO_PATTERN
        beq _done
        ; lv_pos = T mod lv_plen: a bit at a time into the remainder
        jsr live_rel            ; (scene.asm: T less the track's origin, its launch)
        lda #0
        sta lv_pos
        sta lv_pos+1
        ldx #24
-       asl lv_num
        rol lv_num+1
        rol lv_num+2
        rol lv_pos              ; (below 2 * 1,536: no carry out)
        rol lv_pos+1
        lda lv_pos
        sec
        sbc lv_plen
        tay
        lda lv_pos+1
        sbc lv_plen+1
        bcc +                   ; less than the length: kept
        sta lv_pos+1
        sty lv_pos
+       dex
        bne -
_done   rts

; -----------------------------------------------------------------------------
; live_read - (LIVE_READ) the reader on, an event at a time, until its next
; event is at T's place or later (then live_post), while the 250 Hz tick
; has time left, and at least LIVE_BURST events each time: with the main
; loop behind (a busy 16th, a fast tempo), one an event at a time fell
; behind the music in a dense pattern (an edit at 295 BPM heard ~1 s late).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_read
        lda lv_pattern
        cmp #NO_PATTERN
        beq live_post
        lda #LIVE_BURST
        sta lv_burst
-       lda lv_due              ; at T's place or past it: read
        cmp lv_pos
        lda lv_due+1
        sbc lv_pos+1
        bcs live_post
        jsr ed_read_event
        jsr live_next_time
        dec lv_burst
        bpl -                   ; (the first LIVE_BURST + 1 whatever the time)
        lda tick_count
        cmp tick_done
        bne +                   ; the next tick first
        lda CIA1_TB_HI
        cmp #LIVE_SPARE_HI
        bcs -
+       rts

; -----------------------------------------------------------------------------
; live_post - the pattern read to T's place: the record handed to the
; player (playing, the renderer short of T), or the switch made now
; (stopped, still where it was). Renderer at T already: T moved on (the
; margin grown by how far past T it got), reading on. A jump since it began: dropped.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_post
        lda lv_dest
        beq +
        jmp live_post_snap
+       jsr live_record         ; (the player reads it only once sw_pending is set)
        php
        sei
        lda pl_jumps
        cmp lv_jumps
        bne _drop
        lda play_state
        cmp #PLAY_RUNNING
        beq _running
        cmp #PLAY_STOPPED
        bne _drop
        lda pl_music            ; stopped: still at T?
        cmp lv_at
        bne _drop
        lda pl_music+1
        cmp lv_at+1
        bne _drop
        lda pl_music+2
        cmp lv_at+2
        bne _drop
        lda render_busy         ; the renderer's lock taken (a start meanwhile renders
        bne _drop               ; a tick later), the switch made with interrupts on
        inc render_busy         ; (~800 cycles: a MIDI byte must not wait that long)
        plp
        jsr live_apply
        lda #0
        sta render_busy
        lda #LIVE_IDLE
        sta lv_phase
        rts
_running
        lda pl_music            ; the renderer short of T?
        cmp lv_at
        lda pl_music+1
        sbc lv_at+1
        lda pl_music+2
        sbc lv_at+2
        bcs _missed
        lda #1                  ; handed over
        sta sw_pending
        plp
        lda #LIVE_WAIT
        sta lv_phase
        rts
_drop   plp
        lda #LIVE_IDLE
        sta lv_phase
        rts
        ; there first: T moved on, to the renderer's place now + the
        ; margin + how far past T it got (the main loop kept out that
        ; long once may be again); the reading goes on from where it is
_missed sec
        lda pl_music
        sbc lv_at
        tax
        lda pl_music+1
        sbc lv_at+1
        plp
        bne _far                ; (256 passes or more)
        txa
        clc
        adc lv_base
        bcc +
_far    lda #$ff
+       sta lv_margin
.if TEST_LOG
        php                     ; (tests: a miss, LOG_LIVE_MISS)
        sei
        lda lv_track
        sta log_a_value
        lda #LOG_LIVE_MISS
        jsr log_a
        plp
.endif
        lda lv_pos
        sta lv_old_pos
        lda lv_pos+1
        sta lv_old_pos+1
        jsr live_target
        lda lv_pattern
        cmp #NO_PATTERN
        beq _on
        lda lv_pos              ; the new place before the old: from the start
        cmp lv_old_pos
        lda lv_pos+1
        sbc lv_old_pos+1
        bcs _on
        jsr live_read_start
_on     rts                     ; (LIVE_READ still)

; live_post_snap - (live_post, a snapshot's entry) the entry moved to the
; new chain (snap_apply) with interrupts off, if still stopped with no
; stop being done, no jump since and the snapshot the one read for.
; clobbers A, X, Y
live_post_snap
        php
        sei
        lda pl_jumps
        cmp lv_jumps
        bne _drop
        lda play_state
        cmp #PLAY_STOPPED
        bne _drop
        lda stop_phase
        bne _drop
        ldy lv_dest
        lda SNAP_MUSIC_0-1,y
        cmp lv_at
        bne _drop
        lda SNAP_MUSIC_1-1,y
        cmp lv_at+1
        bne _drop
        lda SNAP_MUSIC_2-1,y
        cmp lv_at+2
        bne _drop
        jsr live_record
        jsr snap_apply
.if TEST_LOG
        jsr live_log            ; (tests: as a switch at the snapshot's pass)
.endif
_drop   plp
        lda #LIVE_IDLE
        sta lv_phase
        rts

; live_record - the record from the switch read (sw_pending 0 meanwhile:
; live_post sets it). clobbers A
live_record
        lda lv_track
        sta sw_track
        lda lv_pattern
        sta sw_pattern
        lda lv_at
        sta sw_at
        lda lv_at+1
        sta sw_at+1
        lda lv_at+2
        sta sw_at+2
        lda ed_ptr
        sta sw_ptr
        lda ed_ptr+1
        sta sw_ptr+1
        lda ed_left
        sta sw_left
        lda ed_vel
        sta sw_vel
        lda ed_len
        sta sw_len
        lda ed_len+1
        sta sw_len+1
        lda ed_cc
        sta sw_cc
        lda lv_due
        sta sw_due
        lda lv_due+1
        sta sw_due+1
        lda lv_pos
        sta sw_pos
        lda lv_pos+1
        sta sw_pos+1
        lda lv_plen
        sta sw_plen
        lda lv_plen+1
        sta sw_plen+1
        lda #0
        sta sw_skip
        sta sw_skip+1
        rts

; -----------------------------------------------------------------------------
; live_wait - (LIVE_WAIT) the record taken (or dropped by a jump): looking
; again. Still there with the renderer at T or past it (can't be): dropped.
; clobbers A
; -----------------------------------------------------------------------------
live_wait
        lda sw_pending
        beq _done
        php
        sei
        lda pl_music
        cmp sw_at
        lda pl_music+1
        sbc sw_at+1
        lda pl_music+2
        sbc sw_at+2
        bcc +                   ; (short of T: waiting)
        lda #0
        sta sw_pending
+       plp
        rts
_done   lda #LIVE_IDLE
        sta lv_phase
        rts

; -----------------------------------------------------------------------------
; live_due - (player.asm play_track, a pass done, sw_pending set) at T: the
; switch made (live_apply).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_due
        lda pl_music
        cmp sw_at
        bne +
        lda pl_music+1
        cmp sw_at+1
        bne +
        lda pl_music+2
        cmp sw_at+2
        beq live_apply
+       rts

; sw_state - (a macro) the record's reader, next time, place and length
; into track X's state: the player's arrays (offset 0) or a snapshot's
; (offset: the slot's address - TRK_PTR_LO); skip 0, so the next pass
; plays at sw_pos. Leaves A = 0.
sw_state .macro
        lda sw_ptr
        sta TRK_PTR_LO + \1,x
        lda sw_ptr+1
        sta TRK_PTR_HI + \1,x
        lda sw_left
        sta TRK_LEFT + \1,x
        lda sw_vel
        sta TRK_VEL + \1,x
        lda sw_len
        sta TRK_LEN_LO + \1,x
        lda sw_len+1
        sta TRK_LEN_HI + \1,x
        lda sw_cc
        sta TRK_CC + \1,x
        lda sw_due
        sta TRK_DUE_LO + \1,x
        lda sw_due+1
        sta TRK_DUE_HI + \1,x
        lda sw_pos
        sta TRK_POS_LO + \1,x
        lda sw_pos+1
        sta TRK_POS_HI + \1,x
        lda sw_plen
        sta TRK_PLEN_LO + \1,x
        lda sw_plen+1
        sta TRK_PLEN_HI + \1,x
        lda #0
        sta TRK_SKIP_LO + \1,x
        sta TRK_SKIP_HI + \1,x
        .endm

; -----------------------------------------------------------------------------
; snap_apply - (live_post_snap: stopped, interrupts off) the record into
; snapshot slot lv_dest - 1's entry for the track, no longer stale (the
; same pattern: the slot's ACTIVE and count unchanged).
; clobbers A, X
; -----------------------------------------------------------------------------
snap_apply
        lda #<SNAPSHOT          ; ptr: the slot's arrays
        ldx #>SNAPSHOT
        ldy lv_dest
        cpy #LIVE_TO_SNAP_1
        bne +
        lda #<(SNAPSHOT + SNAP_SIZE)
        ldx #>(SNAPSHOT + SNAP_SIZE)
+       sta ptr
        stx ptr+1
        ; the record, a field an array (Y: the field's array + the track)
        ldx #0
        ldy sw_track
-       lda sw_ptr,x
        sta (ptr),y
        tya
        clc
        adc #NUM_TRACKS
        tay
        inx
        cpx #SW_STATE
        bne -
        ; no longer stale (SNAP_STALE: past the page, from ptr's next)
        inc ptr+1               ; (the page after the arrays)
        lda sw_track
        clc
        adc #SNAP_STALE - $100
        tay
        lda #0
        sta (ptr),y
        rts
        .cerror SNAP_STALE < $100 || SNAP_STALE + NUM_TRACKS > $200, "SNAP_STALE's page" 

; -----------------------------------------------------------------------------
; live_apply - (the player between two passes, or the main loop while
; stopped, holding the renderer's lock) the record's switch: the track's pattern and
; its state at T (skip 0: its next pass plays at sw_pos), ACTIVE built
; again when it gains or loses a pattern; sw_pending cleared.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
live_apply
        ldx sw_track
        lda #0                  ; (in the new chain now, or in none)
        sta PLAY_STALE,x
        lda PLAY_PATTERN,x
        sta sw_old
        lda sw_pattern
        sta PLAY_PATTERN,x
        cmp #NO_PATTERN
        beq _active
        #sw_state 0             ; the track's state at T
        ; a pattern gained or lost: the tracks that play again
_active lda sw_old
        cmp #NO_PATTERN
        beq _had_none
        lda sw_pattern          ; had one: lost?
        cmp #NO_PATTERN
        bne _taken
        beq _build
_had_none
        lda sw_pattern          ; had none: gained?
        cmp #NO_PATTERN
        beq _taken
_build  jsr active_build
_taken  lda #0
        sta sw_pending
.if TEST_LOG
        jmp live_log
.else
        rts
.endif

; -----------------------------------------------------------------------------
; live_room - (main loop) may a pattern be published now? Carry set: no,
; the list of replaced chains is full (live_free empties it once nothing
; is stale).
; keeps X, Y
; -----------------------------------------------------------------------------
live_room
        lda retire_count
        cmp #RETIRE_MAX
        rts

; -----------------------------------------------------------------------------
; live_publish - (main loop, live_room said yes) pattern X's new chain
; (wr_first, written by wr_begin and wr_byte) published with A steps, as
; one change the player can't see half done. With interrupts off: every
; reader in the old chain marked stale (a track playing the pattern, its
; entry in either snapshot), a switch read from it or handed over and not
; yet taken dropped (made again by the rule). Then the old chain freed if
; nothing read it, else kept in the list of replaced chains (live_free).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
live_publish
        stx lp_pattern
        sta lp_steps
        lda PAT_FIRST_LO,x      ; the old chain
        sta lp_old
        lda PAT_FIRST_HI,x
        sta lp_old+1
        lda #0
        sta lp_used
        php
        sei
        ; the new one in (the place logged with it)
        lda lp_steps
        sta PAT_STEPS,x
        lda wr_first
        sta PAT_FIRST_LO,x
        lda wr_first+1
        sta PAT_FIRST_HI,x
        ; a switch read from the old one: dropped (a record not yet taken
        ; among them: then the player can't take one into it)
        lda lp_pattern
        ldx lv_phase
        cpx #LIVE_READ
        bne _handed
        cmp lv_pattern
        bne _logged
        beq _drop
_handed cpx #LIVE_WAIT
        bne _logged
        ldx sw_pending
        beq _logged             ; (taken: the track is marked below)
        cmp sw_pattern
        bne _logged
        ldx #0
        stx sw_pending
_drop   ldx #LIVE_IDLE
        stx lv_phase
_logged
.if TEST_LOG
        lda pl_music            ; (tests: the place and the state, logged below)
        sta lp_log
        lda pl_music+1
        sta lp_log+1
        lda pl_order
        sta lp_log+2
        lda play_state
        asl
        asl
        asl
        asl
        ora stop_phase
        sta lp_log+3
.endif
        plp
.if TEST_LOG
        jsr publish_log
.endif
        ; the tracks and snapshot entries reading the old one: stale, a
        ; track at a time with interrupts off (the clock must not wait).
        ; A snapshot saved or restored between two tracks copies all of
        ; them: the ones done are stale in both, the others looked at in
        ; both after it.
        ldy #1                  ; (stale)
        ldx #NUM_TRACKS-1
_track  php
        sei
        lda lp_pattern
        cmp PLAY_PATTERN,x
        bne +
        tya
        sta PLAY_STALE,x
        sta lp_used
        lda lp_pattern
+       cmp SNAPSHOT + SNAP_PLAY,x
        bne +
        tya
        sta SNAPSHOT + SNAP_STALE,x
        sta lp_used
        lda lp_pattern
+       cmp SNAPSHOT + SNAP_SIZE + SNAP_PLAY,x
        bne +
        tya
        sta SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        sta lp_used
+       plp
        dex
        bpl _track
        ; the old chain: freed now, or once nothing reads it
        lda lp_old+1
        beq _done               ; (there was none)
        sta ptr+1
        lda lp_old
        sta ptr
        lda rec_hold            ; (a take's first merge: the chain before it kept for
        bne _hold               ; undo, take.asm rec_before)
        lda lp_used
        bne _keep
.if TEST_LOG
        php                     ; (tests: freed at once, LOG_FREED 1)
        sei
        lda #1
        sta log_a_value
        lda #LOG_FREED
        jsr log_a
        plp
.endif
        jmp pool_free_chain
_hold   lda ptr
        sta rec_before
        lda ptr+1
        sta rec_before+1
        lda #0
        sta rec_hold
        rts
_keep   ldx retire_count
        lda ptr
        sta retire_lo,x
        lda ptr+1
        sta retire_hi,x
        inc retire_count
_done   rts

; -----------------------------------------------------------------------------
; live_free - (main loop, each live_slice) the replaced chains back to the
; pool once nothing is stale: no track, no snapshot entry (a switch being
; read or handed over reads only published chains: live_publish drops
; one in a chain it replaces).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
live_free
        lda retire_count
        beq _done
        lda #0
        ldx #NUM_TRACKS-1
-       ora PLAY_STALE,x
        ora SNAPSHOT + SNAP_STALE,x
        ora SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        dex
        bpl -
        tax
        bne _done               ; (something still reads one)
.if TEST_LOG
        php
        sei
        lda retire_count
        sta log_a_value
        lda #LOG_FREED
        jsr log_a
        plp
.endif
_chain  ldx retire_count
        lda retire_lo-1,x
        sta ptr
        lda retire_hi-1,x
        sta ptr+1
        jsr pool_free_chain
        dec retire_count
        bne _chain
_done   rts

.if TEST_LOG
; publish_log - (tests, live_publish) a publish: five entries LOG_PUBLISH
; (the pattern, pl_music's low and middle bytes, the place in the pass:
; pl_order, play_state * 16 + stop_phase, as they were when it was
; published), each with interrupts off (the timer interrupt writes log A
; too). clobbers A, X
publish_log
        lda lp_pattern
        jsr _entry
        lda lp_log
        jsr _entry
        lda lp_log+1
        jsr _entry
        lda lp_log+2
        jsr _entry
        lda lp_log+3
_entry  php
        sei
        sta log_a_value
        lda #LOG_PUBLISH
        jsr log_a
        plp
        rts

; live_log - (tests) a switch made: five entries LOG_SWITCH in log A (the
; track, the pattern, T's three bytes), each with interrupts off (the
; timer interrupt writes log A too; only one switch is made at a time).
; clobbers A, X
live_log
        lda sw_track
        jsr _entry
        lda sw_pattern
        jsr _entry
        lda sw_at
        jsr _entry
        lda sw_at+1
        jsr _entry
        lda sw_at+2
_entry  php
        sei
        sta log_a_value
        lda #LOG_SWITCH
        jsr log_a
        plp
        rts
.endif

.if TEST_LIVE >= 2
; -----------------------------------------------------------------------------
; test_live_tick - (TEST_LIVE 2 and 3, from synth_tick) the band's
; patterns replaced, as an edit publishes them: each entry of
; republish_streams (tables.py band_republish), with TEST_LIVE 2 once
; pl_music reaches its pass (while playing), with 3 once the key script's
; P asks (test_live_key: playing, stopping or stopped; the list from its
; start again after its end); its stream written into a new chain and
; published (live_publish: logged). The list of replaced chains full:
; tried again at the next tick.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
test_live_tick
        lda tl_next             ; (the first time: the list's start)
        bne +
        inc tl_next
        jsr _list
+       ldy #1
        lda (tp_src),y          ; its pass's high byte ($FF: the end)
        cmp #$ff
        bne +
.if TEST_LIVE == 3
        jsr _list               ; (from the start again)
        jmp test_live_tick
.endif
        rts
+
.if TEST_LIVE == 3
        lda tl_want             ; asked by the key
        beq _done
.else
        cmp pl_music+1          ; (the first 65,536 passes)
        beq +
        bcs _done
        bcc _due
+       dey
        lda (tp_src),y
        cmp pl_music
        beq _due
        bcs _done
.endif
_due    jsr live_room
        bcs _done
.if TEST_LIVE == 3
        dec tl_want
.endif
        jsr tp_next             ; (the pass, read)
        jsr tp_next
        jsr tp_next
        sta tp_pattern
        jsr tp_next
        sta tp_steps
        jsr tp_next
        sta tp_left
        jsr tp_next
        sta tp_left+1
        jsr wr_begin
_byte   jsr tp_next
        jsr wr_byte
        lda tp_left
        bne +
        dec tp_left+1
+       dec tp_left
        lda tp_left
        ora tp_left+1
        bne _byte
        ldx tp_pattern
        lda tp_steps
        jmp live_publish
_done   rts
_list   lda #<republish_streams
        sta tp_src
        lda #>republish_streams
        sta tp_src+1
        rts

.if TEST_LIVE == 3
; test_live_key - (TEST_LIVE 3, song.asm: P pressed) the next publish asked
; (test_live_tick makes it). clobbers nothing
test_live_key
        inc tl_want
        rts
.endif

.elsif TEST_LIVE
; -----------------------------------------------------------------------------
; test_live_tick - (TEST_LIVE, from synth_tick) the playing scene's cells
; changed as test_live's table says, each once pl_music reaches its time
; (as the editor would: the rule switches them); the pass each came at
; logged (LOG_LIVE_CHANGE: low, high).
; clobbers A, X
; -----------------------------------------------------------------------------
test_live_tick
        ldx tl_next
        lda test_live_hi,x
        cmp #$ff
        beq _done               ; (the table's end)
        lda pl_music+1          ; (the first 65,536 passes)
        cmp test_live_hi,x
        bcc _done
        bne +
        lda pl_music
        cmp test_live_lo,x
        bcc _done
+       lda test_live_pattern,x
        ldy test_live_track,x
        sta SCENE_PATTERN,y
        sty lv_scan             ; (as song.asm does)
        inc tl_next
        php                     ; the pass it came at: two entries LOG_LIVE_CHANGE
        sei
        lda pl_music
        sta log_a_value
        lda #LOG_LIVE_CHANGE
        jsr log_a
        lda pl_music+1
        sta log_a_value
        lda #LOG_LIVE_CHANGE
        jsr log_a
        plp
_done   rts

; the changes: from pass n, track t's cell = pattern p (NO_PATTERN: none;
; 50: a number with no pattern). Band scene (tables.py scene_band): the
; lead to the bass's pattern, the drums off, an empty track given the
; drums, the lead back, the drums' track given the pad (its program,
; controller and bend), the bass to a number with no pattern
TL_NONE         = NO_PATTERN
test_live_lo    .byte <100, <180, <260, <340, <420, <460, $ff
test_live_hi    .byte >100, >180, >260, >340, >420, >460, $ff
test_live_track .byte 3, 0, 9, 3, 0, 1
test_live_pattern .byte 1, TL_NONE, 0, 3, 2, 50
.endif
