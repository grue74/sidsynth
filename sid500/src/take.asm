; take.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Recording (docs/design.md section 5b, "Recording as built"): C= R on the
; song screen records the cursor's track into its cell's pattern while the
; song plays (an empty cell gets a new pattern first, as RETURN makes one).
;
; - The receive interrupt stamps each message (rec_put, from record.asm
;   rx_message): the music's pass heard now (rec_now: the tick being
;   played, rounded to the nearest by timer A's count, looked up in
;   TICK_MUSIC, which the renderer fills as each tick begins: the renderer
;   is ~42 ms ahead), into a ring of 64.
; - The main loop (rec_poll) turns the ring into the take: a record for
;   each note (its length 0 while held, set at its off), controller, bend
;   and program change; a controller or bend at the same pass as the
;   take's last record of its kind replaces that one's value (thinned to
;   a pass).
; - At each pass of the pattern's loop end (heard), and when the take
;   ends, the take's finished records up to there are merged into the
;   pattern: put in a list at their places (Rec Quantize applied to the
;   notes), sorted, then the pattern's chain and the list encoded into a
;   new chain together (the old events first on a tie; Replace drops the
;   old ones the take has passed over in its first pass) and published
;   (live.asm live_publish: heard from the next pass). A piece at a time
;   while the 250 Hz tick has time (grid_job JOB_MERGE: the step grid's
;   table, the main loop's reader and the encoder are the merge's
;   meanwhile; the grid isn't opened during a take).
; - The chain from before the take is kept (rec_before) for undo: C= U on
;   the song screen puts it back, SHIFT+C= U the take's again (rec_undo,
;   the user: as the step grid's), until the pattern is edited otherwise
;   or the next take.

REC_OFF         = 0             ; rec_state: no take
REC_ON          = 1             ;   a take: MIDI in stamped into the ring
REC_ENDING      = 2             ;   the take ended: what is left merged, then off
REC_STOPPING    = 3             ;   C= R: to end at the next look (not during a merge)
RP_COLLECT      = 0             ; rec_phase: the take's records due into the merge list
RP_SORT         = 1             ;   the list sorted by place
RP_ENCODE       = 2             ;   the pattern and the list encoded into a new chain
TAKE            = GRID_TABLE    ; the take's records (grid.asm's layout: REC_TIME the pass
TAKE_MAX        = 128           ; heard, 16 bits; a note still held has length 0; 192 until
                                ; the size pass: HI3_CODE after the lists)
MERGE_LIST      = TAKE + TAKE_MAX * REC_SIZE ; a merge's records (REC_TIME: the place)
        .cerror MERGE_LIST + TAKE_MAX * REC_SIZE > HI3_CODE, "the take runs into HI3_CODE"
        .cerror TAKE % $100 != 0 || MERGE_LIST % $100 != 0, "rec_ptr: the lists start on a page"
RING_SLOTS      = 64            ; the receive interrupt's ring: messages stamped (a power of 2)
RING_LO         = GRID_STEP_LO  ; (in the grid's index: the grid isn't open during a take)
RING_HI         = RING_LO + RING_SLOTS  ;   each one's pass (low, high)
RING_ST         = RING_HI + RING_SLOTS  ;   its status, data
RING_D1         = RING_ST + RING_SLOTS
RING_D2         = RING_D1 + RING_SLOTS
        .cerror RING_D2 + RING_SLOTS > GRID_STEP_HI + $100, "the ring runs into the editor's variables"
TICK_MUSIC_LO   = $ff60         ; (under the KERNAL) each tick's pl_music as it began (low,
TICK_MUSIC_HI   = $ff70         ; high), by ren_tick & 15: player.asm play_begin
        .cerror SNAP_MUSIC_2 + 2 > TICK_MUSIC_LO, "the snapshots run into TICK_MUSIC"
        .cerror TICK_MUSIC_HI + 16 > $fffa, "TICK_MUSIC runs into the vectors"
REC_KEY         = 2*8+1         ; R (with C=)
REC_UNDO_KEY    = 3*8+6         ; U (with C=: the take undone; SHIFT: redone)
REC_SPARE_HI    = SLICE_SPARE_HI ; a merge goes on while more than this many pages of the
                                ; 250 Hz tick's cycles are left, after REC_BURST pieces
REC_BURST       = 8             ; pieces a merge does each turn, whatever the time (as
                                ; live.asm's LIVE_BURST: on a busy song one a turn took
                                ; up to ~460 ms to merge a pattern of ~60 events)
LOG_REC_LOST    = 25            ; (tests, log a) the ring or the take full, or the pool: lost
LOST_RING       = 1             ;   (its value)
LOST_TAKE       = 2
LOST_POOL       = 3
LOG_REC_STAMP   = 26            ; (tests, log a) a message stamped: its pass, low then high
                                ; (log a: on Namesoft the NMI stamps every byte sent into
                                ; log b, and could come in the middle of a stamp's entry)
LOG_REC_START   = 27            ; (tests, log a) a take begun: its pass, low then high
LOG_REC_MERGE   = 28            ; (tests, log a) a merge begun: the messages taken so far (low
LOG_REC_FINAL   = 29            ;   byte); the take's last merge
LOG_REC_END     = 30            ; (tests, log a) the take ended: the last pass heard (two)
LOG_REC_THIN    = 31            ; (tests, log a) a message replaced the newest waiting: its pass

; the take's variables: after the grid's index's high bytes (free while the
; grid is open too; under the KERNAL, read by the interrupts with $01 = $35)
        .virtual GRID_STEP_HI + MAX_STEPS + 1
        .dsection rec_vars
rec_vars_end
        .align BLOCK_SIZE       ; events.asm's end_stream (an empty stream's reader: end
end_stream      .fill BLOCK_SIZE ; markers linked to itself), within a page; init_run
                                ; fills it (the size pass: no alignment in the program)
        .endv
        .cerror end_stream + BLOCK_SIZE > GRID_STEP_HI + $100, "the take's variables run into the editor's"
        .cerror RING_D2 >= GRID_STEP_HI + MAX_STEPS + 1 && RING_D2 < rec_vars_end, "the ring over the take's variables"

        .section rec_vars
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
rec_state       .byte ?         ; REC_*
        .send
rec_track       .byte ?         ; the take's track and pattern
rec_pattern     .byte ?
rec_plen        .word ?         ;   its length in ticks
rec_origin      .word ?         ; the pass its loop began at (the pattern's place 0): the
                                ; next merge takes what came before rec_origin + rec_plen
rec_m0          .word ?         ; the pass the take began at
rec_last        .word ?         ; the pass heard at the last look (the take's end)
rec_head        .byte ?         ; the ring: where the receive interrupt puts the next
rec_tail        .byte ?         ;   the first the main loop hasn't taken
rec_count       .byte ?         ; records in the take
rec_mcount      .byte ?         ;   and in the merge list
rec_phase       .byte ?         ; RP_*
rec_i           .byte ?         ; collecting: the take's record looked at / sorting: the next
rec_w           .byte ?         ;   collecting: where the next one kept goes (scratch after)
rec_mi          .byte ?         ; encoding: the list's next record
rec_old_state   .byte ?         ;   the old chain's event: 0 to read, 1 in rec_old, 2 ended
rec_old         .fill REC_SIZE  ;   it (and the sort's record in hand)
rec_otime       .word ?         ;   the old chain's time so far
rec_hold        .byte ?         ; nonzero: the next publish keeps the old chain (live.asm)
rec_before      .word ?         ; the pattern's chain from before the take (0: none);
                                ; undone, the take's (rec_undo swaps them)
rec_after       .word ?         ; the pattern's chain as the take (or its undo) left it:
                                ; another there, the pattern edited since (no undo)
rec_undone      .byte ?         ; 1: the take undone (SHIFT+C= U redoes it)
rec_drop_lo     .word ?         ; Replace: the old events at places from rec_drop_lo to
rec_drop_hi     .word ?         ;   rec_drop_hi (not including it) dropped, and those
rec_drop_wrap   .word ?         ;   before rec_drop_wrap (the take's first pass past the end)
rec_d           .word ?         ; scratch: a place
rec_num         .fill 3         ; scratch: a 24-bit pass (rec_mod24), the quantize remainder
rec_tmp         .byte ?
rec_page        .byte ?         ; rec_ptr's scratch
rec_burst       .byte ?         ; the pieces this turn still to do whatever the time
rec_slot        .byte ?         ; rec_put's scratch (the receive interrupt's own)
.if TEST_TAKE
rec_test_done   .byte ?         ; (tests: the take begun)
.endif
.if TEST_REC_STOP
rec_test_stop   .byte ?         ; (tests: the song stopped)
.endif
.if TEST_LOG
rec_taken       .byte ?         ; (tests: the ring's messages taken into the take)
.endif

        .send

; -----------------------------------------------------------------------------
; rec_init - (synth_init) no take, nothing kept for undo.
; clobbers A
; -----------------------------------------------------------------------------
rec_init
        lda #0
        sta rec_state
.if TEST_REC_STOP
        sta rec_test_stop
.endif
        sta rec_hold
        sta rec_before+1
.if TEST_TAKE
        sta rec_test_done
.endif
.if TEST_LOG
        sta rec_taken
.endif
        rts

; -----------------------------------------------------------------------------
; rec_now - (interrupts off: the receive interrupt, or the main loop with
; sei) the music's pass heard now, in A (low), Y (high): the tick last
; due, the next one when timer A is past half its period (rounded to
; the nearest), its pass as it began (TICK_MUSIC); the renderer at that
; tick or behind it (the test's feed at a byte a millisecond can hold it
; back): the pass the renderer's tick began at + the ticks between.
; Writes nothing (an NMI may call it in the
; middle of the main loop's call). clobbers X
; -----------------------------------------------------------------------------
rec_now
        ldx play_tick           ; (the ticks due so far: the last of them is heard)
        dex
        lda period_hi
        lsr
        cmp CIA1_TA_HI          ; less than half the period to the next tick: that one
        bcc +
        beq +
        inx
+       txa                     ; ren_tick - the tick: 1-15 is in TICK_MUSIC
        eor #$ff
        sec
        adc ren_tick
        beq _here
        cmp #16
        bcs _behind
        txa
        and #15
        tax
        lda TICK_MUSIC_LO,x
        ldy TICK_MUSIC_HI,x
        rts
_behind eor #$ff                ; the renderer behind: the ticks past ren_tick
        clc
        adc #1
        bne +                   ; (always)
_here   lda #0
+       pha
        ; ren_tick's pass as it began: pl_music, not begun yet; else its
        ; TICK_MUSIC (pl_music may be a pass on, or being counted on)
        lda render_phase
        bne _begun              ; (PHASE_BEGIN 0: not begun)
        lda pl_music
        ldy pl_music+1
        jmp _add
_begun  lda ren_tick
        and #15
        tax
        lda TICK_MUSIC_LO,x
        ldy TICK_MUSIC_HI,x
_add    tsx                     ; + the ticks past it (a pass a tick: swing aside)
        clc
        adc $0101,x
        bcc +
        iny
+       inx                     ; (off the stack)
        txs
        rts
        .cerror PHASE_BEGIN != 0, "rec_now: PHASE_BEGIN is 0"

; -----------------------------------------------------------------------------
; rec_put - (rx_message, a take on) the message (rx_status, rx_d1, rx_d2)
; stamped into the ring, aftertouch left out; the ring full: lost (tests:
; logged, record_check.py fails on it). With the ring half full (the main
; loop behind), a controller or bend replaces the newest message waiting
; (its value and stamp) when that one is the same (kind and number): a
; knob's sweep loses points then, no note is lost.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rec_put
        lda rx_status
        and #$f0
        cmp #MSG_POLY_PRESSURE
        beq +
        cmp #MSG_PRESSURE
        bne ++
+       rts
+       pha
        ; the newest waiting the same controller or bend: replaced
        cmp #MSG_CC
        beq +
        cmp #MSG_BEND
        bne _new
+       lda rec_head            ; the ring half full? (the main loop behind; and the
        sec                     ; newest isn't the one it may be taking)
        sbc rec_tail
        and #RING_SLOTS-1
        cmp #RING_SLOTS/2
        bcc _new
        ldx rec_head
        dex
        txa
        and #RING_SLOTS-1
        tax
        pla
        pha
        cmp RING_ST,x
        bne _new
        cmp #MSG_BEND
        beq _thin
        lda rx_d1
        cmp RING_D1,x
        bne _new
_thin   stx rec_slot
        jsr rec_now_count       ; (count.asm: pass 0 before the song's first tick)
        ldx rec_slot
        sta RING_LO,x
        tya
        sta RING_HI,x
        lda rx_d1
        sta RING_D1,x
        lda rx_d2
        sta RING_D2,x
        pla
.if TEST_LOG
        lda #LOG_REC_THIN       ; (tests: its pass, record_check.py)
        bne _log
.else
        rts
.endif
_new    jsr rec_now_count
        ldx rec_head
        sta RING_LO,x
        tya
        sta RING_HI,x
        pla
        sta RING_ST,x
        lda rx_d1
        sta RING_D1,x
        lda rx_d2
        sta RING_D2,x
        inx
        txa
        and #RING_SLOTS-1
        cmp rec_tail
        beq _full               ; (full: the slot not published)
        sta rec_head
.if TEST_LOG
        dex                     ; (tests: its pass logged, record_check.py)
        txa
        and #RING_SLOTS-1
        tax
        lda #LOG_REC_STAMP
_log    stx rec_slot
        pha
        lda RING_LO,x
        sta log_a_value
        pla
        pha
        jsr log_a
        ldx rec_slot
        lda RING_HI,x
        sta log_a_value
        pla
        jmp log_a
.endif
_no     rts
_full   ldx #LOST_RING

; rec_lost - (interrupts off; tests: logged, the value X: LOST_*) a message
; lost: the ring or the take full, or a merge's list (the pool full).
; clobbers A, X
rec_lost
.if TEST_LOG
        stx log_a_value
        lda #LOG_REC_LOST
        jmp log_a
.else
        rts
.endif

.if TEST_LOG
; rec_log - (tests, main loop) an entry X, value A, in log A with
; interrupts off and I/O in (from the code under I/O too). The value
; stored with interrupts off: the test feed's and the tick's interrupts
; log to log A too (their value over ours made record_check fail now and
; then: a merge's count or the take's end logged wrong). clobbers A, X
rec_log
        php
        sei
        sta log_a_value
        lda $01
        pha
        lda #RAM_IO
        sta $01
        txa
        jsr log_a
        pla
        sta $01
        plp
        rts
.endif

; =============================================================================
; The main loop's part (the key, the take's start and end on) is in the RAM under I/O (the user,
; 2026-11-22: room), copied there at start with the tables (sid500.asm
; io_copy), run with $01 = RAM_ALL: rec_poll and rec_merge_slice switch
; it; the interrupts put I/O in themselves (IRQ_IO_IN). What it calls that
; touches I/O (the timer, the test log) it calls with I/O in (*_out).
; =============================================================================

; rec_poll, rec_merge_slice - (synth_tick, grid_slice) rec_poll_io and
; rec_merge_slice_io run with I/O out. clobbers A, X, Y, ptr, pool_next,
; grid_ptr
rec_poll
.if !TEST_RECORD
        lda rec_state           ; (no take: nothing to do, no switching; the main loop's
        bne +                   ; time is the live switch's too)
        rts
+
.endif
        lda #RAM_ALL
        sta $01
        jsr rec_poll_io
        lda #RAM_IO
        sta $01
        rts
rec_merge_slice
        lda #RAM_ALL
        sta $01
        jsr rec_merge_slice_io
        lda #RAM_IO
        sta $01
        rts

; rec_key - (synth_key, the song screen) rec_key_io with I/O out (its
; carry kept: the key used). clobbers A, X, Y, ptr, pool_next, grid_ptr
rec_key_base                    ; (scene.asm rec_key first: stage E's keys)
        ldx #RAM_ALL
        stx $01
        jsr rec_key_io
        ldx #RAM_IO
        stx $01
        rts

; rec_now_out, rec_lost_out, live_publish_out, song_urgent_cursor_out - (the code
; under I/O) the routine with I/O in, back with it out; their own inputs
; and outputs (rec_now's A and Y kept)
rec_now_out
        ldx #RAM_IO
        stx $01
        jsr rec_now_count       ; (count.asm: pass 0 before the song's first tick)
        ldx #RAM_ALL
        stx $01
        rts
rec_lost_out
        lda #RAM_IO
        sta $01
        jsr rec_lost
        lda #RAM_ALL
        sta $01
        rts
live_publish_out
        ldy #RAM_IO
        sty $01
        jsr live_publish
        lda #RAM_ALL
        sta $01
        rts
song_urgent_cursor_out
        lda #RAM_IO
        sta $01
        jsr song_urgent_cursor
        lda #RAM_ALL
        sta $01
        rts

        .section io_data        ; (under I/O: run with $01 = RAM_ALL)

; -----------------------------------------------------------------------------
; rec_key - (synth_key, the song screen) C= R: a take started on the
; cursor's track while playing, ended if one is on. Carry set = the key
; was it (used).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_key_io
        cmp #REC_KEY
        beq +
        cmp #REC_UNDO_KEY
        bne _no
+       tax                     ; (the key code: back in A if C= isn't held)
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq _not
        lda want_press
        beq _used               ; (its release)
        cpx #REC_UNDO_KEY
        bne +
        lda shift_held          ; C= U: undone (SHIFT: redone)
        beq _undo
        lda #1
_undo   jsr rec_undo
        jmp _used
+       lda rec_state
        beq +
        cmp #REC_ON
        bne _used
        lda #REC_STOPPING       ; on: ended at rec_poll's next look
        sta rec_state
        jmp _used
+       jsr rec_start_any       ; (count.asm: stopped, the count-in)
_used   sec
        rts
_not    txa
_no     clc
        rts

; -----------------------------------------------------------------------------
; rec_undo - (C= U on the song screen, A = 0; SHIFT+C= U, A = 1) the last
; take undone: its pattern's chain from before the take published again
; (heard at once, playing or stopped), the take's kept instead (rec_hold:
; live_publish keeps the chain it replaces in rec_before), so A = 1 swaps
; them back. Only with a take to undo (or redo), none on, nothing waiting
; to be published or merged. The pattern edited since (its chain isn't
; the one the take left): the kept chain given up (freed once nothing
; reads it), nothing undone.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
rec_undo
        cmp rec_undone          ; (undo while not undone, redo while undone)
        bne _rts
        lda rec_before+1
        beq _rts                ; (nothing kept)
        lda rec_state
        ora edit_state
        ora grid_job
        bne _rts                ; (a take, an edit or a merge under way)
        jsr live_room
        bcs _rts                ; (the replaced chains' list full)
        ldx rec_pattern
        lda PAT_FIRST_LO,x      ; edited since?
        cmp rec_after
        bne _gone
        lda PAT_FIRST_HI,x
        cmp rec_after+1
        bne _gone
        ; the kept chain in, the one there kept instead
        lda rec_before
        sta wr_first
        lda rec_before+1
        sta wr_first+1
        lda #1
        sta rec_hold
        lda PAT_STEPS,x
        jsr live_publish_out
        ldx rec_pattern
        lda PAT_FIRST_LO,x
        sta rec_after
        lda PAT_FIRST_HI,x
        sta rec_after+1
        lda rec_undone
        eor #1
        sta rec_undone
_rts    rts
        ; edited since: no undo, the kept chain to the replaced ones
_gone   ldx retire_count
        lda rec_before
        sta retire_lo,x
        lda rec_before+1
        sta retire_hi,x
        inc retire_count
        lda #0
        sta rec_before+1
        rts

; -----------------------------------------------------------------------------
; rec_start - a take on the cursor's track, at once (the song playing; not
; while an edit waits to be published or the step grid's table is busy):
; its cell's pattern, or a new one (the first free number, NEW_STEPS: as
; RETURN makes one), its loop's place from the pass heard now. The chain
; kept from the take before goes to the replaced chains (freed once
; nothing reads it).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
rec_start
        lda play_state
        cmp #PLAY_RUNNING
        bne rec_start_not
rec_start_now                   ; (count.asm count_begin: stopped at the song's start)
        lda edit_state
        ora grid_job
        bne rec_start_not
        jsr live_room
        bcc +
rec_start_not
        rts                     ; (the replaced chains' list full)
+
        ; the take before's chain given up
        lda rec_before+1
        beq +
        ldx retire_count
        sta retire_hi,x
        lda rec_before
        sta retire_lo,x
        inc retire_count
        lda #0
        sta rec_before+1
        ; the cell's pattern, or a new one there
+       jsr song_cell_read
        cmp #NO_PATTERN
        bne +
        jsr edit_free_number
        bcs rec_start_not       ; (none free)
        pha
        jsr song_cell_write
        jsr song_urgent_cursor_out
        pla
+       sta rec_pattern
        tax
        lda PAT_STEPS,x
        bne +
        jsr undo_clear          ; (the step grid's table: the new pattern's, published
        ldx rec_pattern         ; empty by edit_slice)
        jsr edit_new
        lda #NEW_STEPS
+       tax
        jsr step_tick
        lda step_lo
        sta rec_plen
        lda step_hi
        sta rec_plen+1
        lda song_cursor
        sta rec_track
        ; the pass heard now, and its loop's start: now - (now mod length)
        php
        sei
        jsr rec_now_out
        sta rec_m0
        sty rec_m0+1
        sec                     ; the 24-bit pass: pl_music - (pl_music - now, 16 bits)
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
        bcs +
        lda #0                  ; (before the song's first tick: from pass 0)
        sta rec_num
        sta rec_num+1
        sta rec_num+2
        sta rec_m0
        sta rec_m0+1
+       lda #0
        sta rec_head
        sta rec_tail
        plp
        ldx rec_track           ; (the track's place counts from its launch: scene.asm)
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
        jsr rec_mod24
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
        lda #0
        sta rec_count
        lda #0
        sta rec_undone
        lda #1
        sta rec_hold            ; (the first merge's publish keeps the chain before it)
        lda #REC_ON             ; (last: the receive interrupt stamps from now)
        sta rec_state
.if TEST_LOG
        jmp rec_log_start       ; (tests: the pass it began at; in main RAM)
.endif
        rts

; rec_mod24 - rec_d = rec_num (24 bits) mod rec_plen, a bit at a time.
; clobbers A, X, Y, rec_num
rec_mod24
        lda #0
        sta rec_d
        sta rec_d+1
        ldx #24
-       asl rec_num
        rol rec_num+1
        rol rec_num+2
        rol rec_d               ; (below 2 * 1,536: no carry out)
        rol rec_d+1
        lda rec_d
        sec
        sbc rec_plen
        tay
        lda rec_d+1
        sbc rec_plen+1
        bcc +
        sta rec_d+1
        sty rec_d
+       dex
        bne -
        rts

; -----------------------------------------------------------------------------
; rec_end - (rec_poll, no merge under way: C= R, or the song stopped) the
; take ends: nothing more stamped, what the ring holds taken, each note
; still held given its length to the last pass heard (at least a tick);
; the last merge follows.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
rec_end
        lda #REC_ENDING
        sta rec_state
        jsr rec_drain
.if TEST_LOG
        jsr rec_log_end         ; (tests: the last pass, record_check.py; in main RAM)
.endif
        lda rec_last
        sta rec_num
        lda rec_last+1
        sta rec_num+1
        ldx #0
_record cpx rec_count
        bcs _done
        txa
        ldy #>TAKE
        jsr rec_ptr
        ldy #REC_TYPE
        lda (grid_ptr),y
        bne _next               ; (TYPE_NOTE 0)
        ldy #REC_LEN_LO
        lda (grid_ptr),y
        iny
        ora (grid_ptr),y
        bne _next
        jsr rec_close
_next   inx
        bne _record
_done   rts

; rec_close - the held note at grid_ptr ends at pass rec_num (2 bytes):
; its length the passes since it began, at least 1. keeps X
rec_close
        sec
        ldy #REC_TIME_LO
        lda rec_num
        sbc (grid_ptr),y
        sta rec_d
        iny
        lda rec_num+1
        sbc (grid_ptr),y
        bmi _one                ; (before its start: can't be)
        tay
        ora rec_d
        bne +
_one    lda #1
        sta rec_d
        ldy #0
+       tya
        ldy #REC_LEN_HI
        sta (grid_ptr),y
        dey
        lda rec_d
        sta (grid_ptr),y
        rts

; rec_ptr - grid_ptr at record A of the list whose first page is Y (TAKE
; or MERGE_LIST). keeps X
rec_ptr
        sty rec_page
        ldy #0
        sty grid_ptr+1
        asl
        rol grid_ptr+1
        asl
        rol grid_ptr+1
        asl
        rol grid_ptr+1
        sta grid_ptr
        lda grid_ptr+1
        clc
        adc rec_page
        sta grid_ptr+1
        rts

; -----------------------------------------------------------------------------
; rec_drain - (main loop) the ring's messages into the take: a note on a
; record held (length 0), its off the latest held record of that note
; given its length (none: its on came before the take, dropped); a
; controller or bend at the same pass as the take's last record, of the
; same kind (and number), replaces its value; the take full: lost.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
rec_drain
_next   ldx rec_tail
        cpx rec_head
        bne +
        rts
+       lda RING_ST,x
        cmp #MSG_NOTE_ON
        bne +
        lda RING_D2,x
        beq _off                ; (velocity 0: an off)
        ldy #TYPE_NOTE
        bpl _new
+       cmp #MSG_NOTE_OFF
        beq _off
        ; a controller, bend or program change: its type
        ldy #TYPE_PROGRAM
        cmp #MSG_PROGRAM
        beq _new
        ldy #TYPE_CC
        cmp #MSG_CC
        beq +
        ldy #TYPE_BEND
        ; the take's last record the same kind at the same pass: its value
+       sty rec_tmp
        lda rec_count
        beq _new_t
        sbc #1                  ; (carry set: the cmp equal, or bend's past $B0)
        ldy #>TAKE
        jsr rec_ptr
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        cmp RING_LO,x
        bne _new_t
        iny
        lda (grid_ptr),y
        cmp RING_HI,x
        bne _new_t
        iny                     ; (REC_TYPE)
        lda (grid_ptr),y
        cmp rec_tmp
        bne _new_t
        iny                     ; (REC_D1)
        cmp #TYPE_BEND
        beq _value              ; (a bend: both halves replaced)
        lda (grid_ptr),y
        cmp RING_D1,x
        bne _new_t
_value  lda RING_D1,x
        sta (grid_ptr),y
        iny
        lda RING_D2,x
        sta (grid_ptr),y
        jmp _done
_new_t  ldy rec_tmp
        ; a new record: its pass, type Y, the data, a note's velocity, length 0
_new    jsr rec_append
        bcc _done
        bcs _lost
        ; an off: the latest held record of its note
_off    ldy rec_count
_find   dey
        cpy #$ff
        beq _done               ; (none held: dropped)
        sty rec_w               ; (the record's number)
        tya
        ldy #>TAKE
        jsr rec_ptr
        ldy #REC_TYPE
        lda (grid_ptr),y
        bne _not                ; (TYPE_NOTE 0)
        iny                     ; (REC_D1)
        lda (grid_ptr),y
        cmp RING_D1,x
        bne _not
        ldy #REC_LEN_LO
        lda (grid_ptr),y
        iny
        ora (grid_ptr),y
        bne _not
        lda RING_LO,x           ; the off's pass: its length
        sta rec_num
        lda RING_HI,x
        sta rec_num+1
        jsr rec_close
        jmp _done
_not    ldy rec_w
        jmp _find
_lost   php
        sei
        ldx #LOST_TAKE
        jsr rec_lost_out
        plp
_done
.if TEST_LOG
        inc rec_taken
.endif
        ldx rec_tail
        inx
        txa
        and #RING_SLOTS-1
        sta rec_tail
        jmp _next

; rec_append - a record at the take's end from ring slot X: its pass, type
; Y, the data, the velocity (a note's second byte), length 0. Carry set =
; the take full. keeps X
rec_append
        lda rec_count
        cmp #TAKE_MAX
        bcs _full
        sty rec_w
        ldy #>TAKE
        jsr rec_ptr
        inc rec_count
        ldy #REC_TIME_LO
        lda RING_LO,x
        sta (grid_ptr),y
        iny
        lda RING_HI,x
        sta (grid_ptr),y
        iny
        lda rec_w
        sta (grid_ptr),y
        iny
        lda RING_D1,x
        sta (grid_ptr),y
        iny
        lda RING_D2,x
        sta (grid_ptr),y
        iny
        sta (grid_ptr),y        ; (REC_VEL: a note's)
        iny
        lda #0
        sta (grid_ptr),y
        iny
        sta (grid_ptr),y
        clc
_full   rts

; -----------------------------------------------------------------------------
; rec_poll - (synth_tick, main loop) a take's turn: a merge under way goes
; on in grid_slice (JOB_MERGE), the ring taken meanwhile (at 295 BPM a
; short loop's merges come one after the other); else the ring into the take, the take
; ended when the song stops, a merge begun when the loop's end has been
; heard (or the take has ended).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_poll_io
.if TEST_RECORD || TEST_REC_END || TEST_REC_UNDO
        jsr rec_test            ; (tests: C= R, C= U as the keys would: in main RAM)
.endif
        lda rec_state
        beq _rts
        lda grid_job
        cmp #JOB_MERGE
        bne +
        lda rec_phase           ; a merge: grid_slice does its pieces; the ring taken
        cmp #RP_COLLECT         ; meanwhile, but while collecting (the take being
        beq _rts                ; compacted; ring 64 messages)
        jmp rec_drain
+
        lda rec_state
        cmp #REC_ENDING
        beq _merge
        cmp #REC_STOPPING
        beq _stop               ; (C= R)
        jsr rec_drain
        lda play_state
        cmp #PLAY_RUNNING
        beq +
_end    jsr rec_end             ; (or stopped: the take ends)
        jmp _merge
_stop   lda play_state          ; C= R: the pass heard now (rec_last wasn't looked at
        cmp #PLAY_RUNNING       ; while a merge ran)
        bne _end
        php
        sei
        jsr rec_now_out
        plp
        sta rec_last
        sty rec_last+1
        jmp _end
+       php
        sei
        jsr rec_now_out
        plp
        sta rec_last
        sty rec_last+1
        ; the loop's end heard? (now - origin >= the length)
        sec
        sbc rec_origin
        tax
        lda rec_last+1
        sbc rec_origin+1
        bmi _rts
        cmp rec_plen+1
        bcc _rts
        bne _merge
        cpx rec_plen
        bcc _rts
_merge  jmp rec_merge_begin
_rts    rts

; -----------------------------------------------------------------------------
; rec_merge_begin - a merge begun (not while an edit waits to be published,
; the list of replaced chains is full or the live switch reads: the
; reader and the encoder are shared; playing, only once the last merge is
; switched in; tried again at the next look): Replace's places for it (the take's first pass
; that it covers, up to the loop's end or, ended, to the last pass heard),
; then the records collected.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rec_merge_begin
        lda edit_state
        bne _not
        jsr live_room           ; (room for the chain it replaces: waiting for it with the
        bcs _not                ; job taken, the live switch couldn't free any)
        lda rec_state
        cmp #REC_ENDING
        beq _ended
        ldx rec_track           ; playing: the last merge switched in first (the live
        lda PLAY_STALE,x        ; switch has its turn between merges: at 295 BPM they
        ora lv_phase            ; come one after the other)
        bne _not
        beq _go
_ended  lda lv_phase            ; (ended: the reader not the live switch's)
        cmp #LIVE_READ
        bne _go
_not    rts
_go
.if TEST_LOG
        jsr rec_log_merge       ; (tests: what it merges, record_check.py; in main RAM)
.endif
        lda #JOB_MERGE
        sta grid_job
        lda #RP_COLLECT
        sta rec_phase
        lda #0
        sta rec_i
        sta rec_w
        sta rec_mcount
        sta rec_drop_lo
        sta rec_drop_lo+1
        sta rec_drop_hi
        sta rec_drop_hi+1
        sta rec_drop_wrap
        sta rec_drop_wrap+1
        lda params+P_RECORD
        beq _not                ; (overdub: nothing dropped)
        ; from: the take's start, or the loop's (rec_m0 - rec_origin, at least 0)
        sec
        lda rec_m0
        sbc rec_origin
        tax
        lda rec_m0+1
        sbc rec_origin+1
        bmi +
        stx rec_drop_lo
        sta rec_drop_lo+1
        ; to: the loop's end, or ended the last pass heard; at most the
        ; take's start + the length
+       lda rec_plen
        sta rec_d
        lda rec_plen+1
        sta rec_d+1
        lda rec_state
        cmp #REC_ENDING
        bne +
        sec
        lda rec_last
        sbc rec_origin
        sta rec_d
        lda rec_last+1
        sbc rec_origin+1
        sta rec_d+1
+       sec                     ; the take's start + the length - origin
        lda rec_m0
        sbc rec_origin
        tax
        lda rec_m0+1
        sbc rec_origin+1
        tay
        clc
        txa
        adc rec_plen
        tax
        tya
        adc rec_plen+1
        bmi _none               ; (the first pass done: nothing more dropped)
        cmp rec_d+1             ; less than to: to it
        bcc _lower
        bne +
        cpx rec_d
        bcs +
_lower  stx rec_d
        sta rec_d+1
+       lda rec_d+1
        bmi _none
        ; past the loop's end: the rest from the pattern's start (wrap)
        sec
        lda rec_d
        sbc rec_plen
        tax
        lda rec_d+1
        sbc rec_plen+1
        bcc +
        stx rec_drop_wrap
        sta rec_drop_wrap+1
        lda rec_plen            ; (the main part to the loop's end)
        sta rec_d
        lda rec_plen+1
        sta rec_d+1
+       lda rec_d
        sta rec_drop_hi
        lda rec_d+1
        sta rec_drop_hi+1
_rts    rts
_none   lda #0                  ; (nothing: from 0 to 0)
        sta rec_drop_lo
        sta rec_drop_lo+1
        rts

; -----------------------------------------------------------------------------
; rec_merge_slice - (grid_slice, JOB_MERGE) the merge's next pieces while
; the 250 Hz tick has time: collecting, sorting, encoding (rec_phase).
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_merge_slice_io
        lda #REC_BURST
        sta rec_burst
        lda rec_phase
        beq rec_collect
        cmp #RP_SORT
        bne +
        jmp rec_sort
+       jmp rec_encode

; rec_time_left - carry set: another piece this turn (the burst's, or the
; 250 Hz tick has time)
rec_time_left
        dec rec_burst
        bmi +
        sec
        rts
+       inc rec_burst           ; (kept at 0)
        lda tick_count
        cmp tick_done
        bne +
        jmp rec_spare_out       ; (the timer read from main RAM: this code is under I/O)
+       clc
        rts

; -----------------------------------------------------------------------------
; rec_collect - (RP_COLLECT) the take's records looked at in turn: one
; finished and before the loop's end (ended: all) into the merge list at
; its place (the pass - origin, into the pattern: a note held across the
; loop's end at its start's place), a note quantized (Rec Quantize); the
; others kept in the take, in order. Then the list sorted.
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
rec_collect
_record ldx rec_i
        cpx rec_count
        bcc +
        lda rec_w               ; all looked at: the kept ones are the take
        sta rec_count
        lda #RP_SORT
        sta rec_phase
        lda #1
        sta rec_i
        rts
+       txa
        ldy #>TAKE
        jsr rec_ptr
        ; its place: the pass - origin
        sec
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        sbc rec_origin
        sta rec_d
        iny
        lda (grid_ptr),y
        sbc rec_origin+1
        sta rec_d+1
        ; due? ended: all; else before the loop's end, and a note finished
        lda rec_state
        cmp #REC_ENDING
        beq _due
        lda rec_d+1
        bmi +                   ; (before the origin: due)
        cmp rec_plen+1
        bcc +
        bne _keep
        lda rec_d
        cmp rec_plen
        bcs _keep
+       ldy #REC_TYPE
        lda (grid_ptr),y
        bne _due                ; (not a note)
        ldy #REC_LEN_LO
        lda (grid_ptr),y
        iny
        ora (grid_ptr),y
        beq _keep               ; (still held)
_due    jsr rec_place           ; (rec_d into the pattern, quantized)
        lda rec_mcount
        inc rec_mcount
        ldy #>MERGE_LIST
        bne _copy
_keep   lda rec_w
        inc rec_w
        ldy #>TAKE
_copy   ldx grid_ptr            ; (the record's own address kept)
        stx ptr
        ldx grid_ptr+1
        stx ptr+1
        jsr rec_ptr             ; grid_ptr: where it goes
        ldy #REC_SIZE-1
-       lda (ptr),y
        sta (grid_ptr),y
        dey
        bpl -
        lda grid_ptr+1          ; into the merge list: REC_TIME its place
        cmp #>MERGE_LIST
        bcc +
        ldy #REC_TIME_LO
        lda rec_d
        sta (grid_ptr),y
        iny
        lda rec_d+1
        sta (grid_ptr),y
+       inc rec_i
        jsr rec_time_left
        bcc +
        jmp _record
+       rts

; rec_place - rec_d (a place, signed) into the pattern (0 to the length
; - 1), and the record at grid_ptr a note: quantized to Rec Quantize's
; grid, the nearest (one rounded to the loop's end: the pattern's start).
; keeps grid_ptr; clobbers A, X, Y
rec_quant_ticks .byte 0, TICKS_PER_STEP, 2 * TICKS_PER_STEP, TICKS_PER_STEP * 2 / 3
rec_place
        jsr rec_wrap
        ldy #REC_TYPE
        lda (grid_ptr),y
        bne _done               ; (not a note)
        ldx params+P_REC_QUANT
        lda rec_quant_ticks,x
        beq _done
        sta rec_tmp
        ; the remainder: the place mod the grid, a bit at a time
        lda rec_d
        sta rec_num
        lda rec_d+1
        sta rec_num+1
        lda #0
        ldx #16
-       asl rec_num
        rol rec_num+1
        rol a
        cmp rec_tmp
        bcc +
        sbc rec_tmp
+       dex
        bne -
        sta rec_num+2
        ; down to the grid, up a step if the remainder is half or more
        sec
        lda rec_d
        sbc rec_num+2
        sta rec_d
        bcs +
        dec rec_d+1
+       lda rec_num+2
        asl
        cmp rec_tmp
        bcc _wrap
        clc
        lda rec_d
        adc rec_tmp
        sta rec_d
        bcc _wrap
        inc rec_d+1
_wrap   jmp rec_wrap
_done   rts

; rec_wrap - rec_d (signed) into the pattern: the length added or taken
; away until 0 to the length - 1. clobbers A
rec_wrap
-       lda rec_d+1
        bpl +
        clc
        lda rec_d
        adc rec_plen
        sta rec_d
        lda rec_d+1
        adc rec_plen+1
        sta rec_d+1
        jmp -
+       lda rec_d
        cmp rec_plen
        lda rec_d+1
        sbc rec_plen+1
        bcc +
        sta rec_d+1
        lda rec_d
        sbc rec_plen            ; (carry set)
        sta rec_d
        jmp -
+       rts

; -----------------------------------------------------------------------------
; rec_sort - (RP_SORT) the merge list in order of place, as an insertion
; sort (nearly sorted already: a few moves), a record at a time; equal
; places keep their order. Then the encoding begins.
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
rec_sort
_record ldx rec_i
        cpx rec_mcount
        bcs rec_encode_begin
+       ; the record in hand
        txa
        ldy #>MERGE_LIST
        jsr rec_ptr
        ldy #REC_SIZE-1
-       lda (grid_ptr),y
        sta rec_old,y
        dey
        bpl -
        ; the ones before it with a later place moved up one
_move   lda grid_ptr            ; ptr: the one before
        sec
        sbc #REC_SIZE
        sta ptr
        lda grid_ptr+1
        sbc #0
        sta ptr+1
        cmp #>MERGE_LIST
        bcc _put                ; (the list's start)
        ldy #REC_TIME_LO        ; its place later than the record's?
        lda rec_old+REC_TIME_LO
        cmp (ptr),y
        iny
        lda rec_old+REC_TIME_HI
        sbc (ptr),y
        bcs _put
        ldy #REC_SIZE-1
-       lda (ptr),y
        sta (grid_ptr),y
        dey
        bpl -
        lda ptr
        sta grid_ptr
        lda ptr+1
        sta grid_ptr+1
        jmp _move
_put    ldy #REC_SIZE-1
-       lda rec_old,y
        sta (grid_ptr),y
        dey
        bpl -
        inc rec_i
        jsr rec_time_left
        bcs _record
        rts

; -----------------------------------------------------------------------------
; rec_encode_begin - the encoding begun: a new chain, the pattern's reader
; at its start (nothing to put in or drop: the merge done at once). The
; pool full: the list dropped (lost). (The list of replaced chains has
; room, or is waited for: nothing else publishes during a take.)
; clobbers A, X, Y, ptr
; -----------------------------------------------------------------------------
rec_encode_begin
        lda rec_mcount
        ora rec_drop_hi
        ora rec_drop_hi+1
        ora rec_drop_wrap
        ora rec_drop_wrap+1
        bne +
        jmp rec_merged          ; (nothing to do)
+       jsr live_room
        bcs _wait
        jsr en_begin
        bcs _full
        lda rec_pattern
        jsr ed_start
        lda #0
        sta rec_mi
        sta rec_old_state
        sta rec_otime
        sta rec_otime+1
        lda #RP_ENCODE
        sta rec_phase
_wait   rts
_full   php
        sei
        ldx #LOST_POOL
        jsr rec_lost_out
        plp
        jmp rec_merged

; -----------------------------------------------------------------------------
; rec_encode - (RP_ENCODE) the next events onto the new chain while the
; 250 Hz tick has time: the old chain's next (read as needed; Replace's
; places dropped) or the list's, whichever comes first (the old one on a
; tie); both done: the end written and published.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_encode
_step   lda rec_old_state
        bne _have
        ; the old chain's next event
        jsr ed_read_time
        bcs _ended
        clc
        lda rec_otime
        adc ed_delta
        sta rec_otime
        sta rec_old+REC_TIME_LO
        lda rec_otime+1
        adc ed_delta+1
        sta rec_otime+1
        sta rec_old+REC_TIME_HI
        jsr ed_read_event
        lda ed_type
        cmp #TYPE_BAD
        beq _ended              ; (a broken stream: ended there)
        sta rec_old+REC_TYPE
        lda ed_d1
        sta rec_old+REC_D1
        lda ed_d2
        sta rec_old+REC_D2
        lda ed_vel
        sta rec_old+REC_VEL
        lda ed_len
        sta rec_old+REC_LEN_LO
        lda ed_len+1
        sta rec_old+REC_LEN_HI
        jsr rec_dropped
        bcs _step               ; (Replace: dropped)
        lda #1
        bne +
_ended  lda #2
+       sta rec_old_state
        ; which first?
_have   ldx rec_mi
        cpx rec_mcount
        bcs _old                ; (the list done)
        txa
        ldy #>MERGE_LIST
        jsr rec_ptr
        lda rec_old_state
        cmp #1
        bne _list
        ldy #REC_TIME_LO        ; the old one's place not later: it first
        lda (grid_ptr),y
        cmp rec_old+REC_TIME_LO
        iny
        lda (grid_ptr),y
        sbc rec_old+REC_TIME_HI
        bcs _old
_list   inc rec_mi
        lda grid_ptr
        sta en_rec
        lda grid_ptr+1
        sta en_rec+1
        jmp _encode
_old    lda rec_old_state
        cmp #1
        bne _finish             ; (both done)
        lda #0
        sta rec_old_state
        lda #<rec_old
        sta en_rec
        lda #>rec_old
        sta en_rec+1
_encode jsr en_record
        bcs _full               ; (abandoned)
        jsr rec_time_left
        bcc +
        jmp _step
+       rts
_finish jsr en_finish
        bcs _full
        ldx rec_pattern
        lda PAT_STEPS,x
        jsr live_publish_out
        jmp rec_merged
_full   php
        sei
        ldx #LOST_POOL
        jsr rec_lost_out
        plp
        ; (on into rec_merged)

; rec_merged - the merge done: the next loop's (or the take off, ended)
rec_merged
        lda #JOB_NONE
        sta grid_job
        ldx rec_pattern         ; (the chain the take leaves: C= U undoes it while it
        lda PAT_FIRST_LO,x      ; is still there, rec_undo)
        sta rec_after
        lda PAT_FIRST_HI,x
        sta rec_after+1
        lda rec_state
        cmp #REC_ENDING
        beq _off
        clc
        lda rec_origin
        adc rec_plen
        sta rec_origin
        lda rec_origin+1
        adc rec_plen+1
        sta rec_origin+1
        rts
_off    lda #REC_OFF
        sta rec_state
        sta rec_hold            ; (nothing published: nothing to undo)
        rts

; rec_dropped - (Replace) the old event at rec_old's place dropped? Carry
; set: yes (from rec_drop_lo to rec_drop_hi, or before rec_drop_wrap).
; clobbers A
rec_dropped
        lda rec_old+REC_TIME_LO ; before the wrap's end: dropped
        cmp rec_drop_wrap
        lda rec_old+REC_TIME_HI
        sbc rec_drop_wrap+1
        bcc _yes
        lda rec_old+REC_TIME_LO ; before the range: kept
        cmp rec_drop_lo
        lda rec_old+REC_TIME_HI
        sbc rec_drop_lo+1
        bcc _no
        lda rec_old+REC_TIME_LO ; before its end: dropped
        cmp rec_drop_hi
        lda rec_old+REC_TIME_HI
        sbc rec_drop_hi+1
        bcc _yes
_no     clc
        rts
_yes    sec
        rts
        .send

; -----------------------------------------------------------------------------
; rec_spare_out - (rec_time_left, under I/O) carry set: more than
; REC_SPARE_HI pages of the 250 Hz tick's cycles left (CIA1 timer B, read
; with I/O in). In main RAM: switching I/O in from the code under I/O
; took that code away under the CPU (a crash now and then in a merge:
; record_check, Fable's finding). Placed after the tables (late_code) so
; nothing before it moves. clobbers A, X
; -----------------------------------------------------------------------------
        .section late_code
rec_spare_out
        ldx #RAM_IO
        stx $01
        lda CIA1_TB_HI
        ldx #RAM_ALL
        stx $01
        cmp #REC_SPARE_HI
        rts
        .send

.if TEST_LOG
        .section late_tests     ; (tests: in main RAM, called from the code under I/O,
                                ; whose room the event list took: 2026-11-24; after
                                ; late_code, so it doesn't move)
; rec_log_start, rec_log_end, rec_log_merge - (tests) the pass the take
; began at (rec_poll_io), its last pass (rec_end), what a merge takes
; (rec_merge_begin): rec_log's entries. clobbers A, X
rec_log_start
        lda rec_m0
        ldx #LOG_REC_START
        jsr rec_log
        lda rec_m0+1
        ldx #LOG_REC_START
        jmp rec_log
rec_log_end
        lda rec_last
        ldx #LOG_REC_END
        jsr rec_log
        lda rec_last+1
        ldx #LOG_REC_END
        jmp rec_log
rec_log_merge
        lda rec_state
        ldx #LOG_REC_MERGE
        cmp #REC_ENDING
        bne +
        ldx #LOG_REC_FINAL
+       lda rec_taken
        jmp rec_log
        .send
.endif

.if TEST_RECORD || TEST_REC_END || TEST_REC_UNDO
        .section late_code      ; (tests: in main RAM, run with $01 = RAM_ALL; under
                                ; I/O there is no room in the test builds)
; -----------------------------------------------------------------------------
; rec_test - (tests, rec_poll_io) TEST_RECORD: a take on track TEST_RECORD
; the first time the song plays; TEST_REC_END: the take ended from play
; tick TEST_REC_END on (as C= R); TEST_REC_UNDO, TEST_REC_REDO: C= U and
; SHIFT+C= U from those play ticks.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
rec_test
.if TEST_RECORD
        lda rec_test_done       ; (tests: a take on track TEST_RECORD from the first
        bne +                   ; time the song plays)
        lda play_state
        cmp #PLAY_RUNNING
        bne +
.if TEST_REC_FROM
        lda play_tick           ; (tests: not before play tick TEST_REC_FROM)
        cmp #<TEST_REC_FROM
        lda play_tick+1
        sbc #>TEST_REC_FROM
        bcc +
.endif
        inc rec_test_done
        lda #TEST_RECORD-1
        sta song_cursor
        jsr rec_start
+
.endif
.if TEST_REC_END
        lda rec_state           ; (tests: the take ended from play tick TEST_REC_END on,
        cmp #REC_ON             ; as C= R does)
        bne _test_no
        lda play_tick
        cmp #<TEST_REC_END
        lda play_tick+1
        sbc #>TEST_REC_END
        bcc _test_no
        lda #REC_STOPPING
        sta rec_state
_test_no
.endif
.if TEST_REC_UNDO
        lda rec_test_done       ; (tests: C= U from play tick TEST_REC_UNDO, SHIFT+C= U
        cmp #1                  ; from TEST_REC_REDO; rec_test_done 1 the take begun,
        bne _test_redo          ; 2 undone, 3 redone)
        lda play_tick
        cmp #<TEST_REC_UNDO
        lda play_tick+1
        sbc #>TEST_REC_UNDO
        bcc _test_done
        lda #0
        jsr rec_undo
        lda rec_undone
        beq _test_done          ; (not yet: tried again)
        inc rec_test_done
        bne _test_done
_test_redo
.if TEST_REC_REDO
        cmp #2
        bne _test_done
        lda play_tick
        cmp #<TEST_REC_REDO
        lda play_tick+1
        sbc #>TEST_REC_REDO
        bcc _test_done
        lda #1
        jsr rec_undo
        lda rec_undone
        bne _test_done          ; (not yet: tried again)
        inc rec_test_done
.endif
_test_done
.endif
        rts
        .send
.endif
