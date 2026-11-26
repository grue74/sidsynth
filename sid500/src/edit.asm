; edit.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Editing a pattern (docs/design.md section 5, "The step grid"): the step
; grid's edits change the edit table (grid.asm: a record of 8 bytes an
; event, in time order), and the table is then encoded into a new chain of
; blocks (pool.asm wr_begin, wr_byte) and published (wr_publish): a
; published chain is never changed.
;
; The edits (as SID303's step keys where it has the same thing): a note
; key puts its note in the cursor's column (the step's n-th note, in the
; table's order) on the step's start with the entry velocity and length,
; or adds it after the step's notes on its start (a note off the step,
; edited: taken out and put back on the start); SPACE and DEL take the
; column's note out. A record put in or taken out moves the table's
; records after it (edit_move_up, edit_move_down: ~11 cycles a byte) and
; the steps' index after the cursor's step.
;
; The publish (live.asm live_publish) is heard at once, a playing pattern
; too: the tracks playing it are switched to the new chain at their place,
; the old chain freed once nothing reads it. It waits only while the list
; of chains waiting to be freed is full (live_room) or the pool is full;
; until then (the title's "*") no other pattern can be opened (its table
; would replace this one's). The "*" shows only a publish that waits: one
; done at once (a frame or two) would make it flash.
;
; The encoder writes exactly what tables.py's encode() writes for the same
; events (tools/event_check.py: every test pattern decoded and encoded
; again gives its stream byte for byte): each event's time since the one
; before ($F0 + high byte, then the low byte, when 240 or more), a length
; prefix where the length changes (len_table's, else 1 or 2 bytes), a
; velocity prefix where it changes, the event; a controller of the current
; number as EV_CC_SAME; then TIME_END. It goes a record at a time
; (en_record), so the step grid can encode a piece at a time while the 250
; Hz tick has time.

; the editor's variables, in the RAM after the edit table (under the
; KERNAL: the main loop runs with the ROMs out)
        .virtual GRID_STEP_HI + $100
        .dsection edit_vars
edit_vars_end
        .endv
        .cerror edit_vars_end > $f000, "the editor's variables run into the wheel"

EDIT_CLEAN      = 0             ; edit_state: the table is the pattern as published
EDIT_CHANGED    = 1             ;   edited since: to be encoded and published
EDIT_ENCODING   = 2             ;   being encoded (en_*), a piece at a time
EDIT_TO_VELOCITY = 0            ; edit_target: the cursor's note's velocity (C= V)
EDIT_TO_LENGTH  = 1             ;   its length (C= L)
EDIT_TO_TRANSPOSE = 2           ;   the whole pattern's pitch (C= T)
EDIT_DREW_ENTRY = 0             ; edit_change: the entry row to draw again
EDIT_DREW_NOTE  = 1             ;   and the cursor's row
EDIT_DREW_ALL   = 2             ;   every step row
ENTRY_VELOCITY  = 100           ; the entry settings at start
ENTRY_LENGTH    = TICKS_PER_STEP
NEW_STEPS       = 16            ; a new pattern's length
EDIT_SPARE_HI   = SLICE_SPARE_HI ; encoding goes on while more than this many pages of the
                                ; 250 Hz tick's cycles are left (at least one record)
RECS_A_PAGE     = 256 / REC_SIZE

        .section edit_vars
edit_state      .byte ?         ; EDIT_*
edit_full       .byte ?         ; nonzero: the pool was full at the last try (tried again
                                ;   after the next edit)
edit_wait       .byte ?         ; nonzero: the publish waits (the replaced chains' list or
                                ;   the pool full): the title's "*"
edit_whole      .byte ?         ; nonzero: the table holds the whole pattern (decoding
                                ;   didn't stop short): it may be edited
edit_vel        .byte ?         ; the entry velocity
edit_len        .word ?         ;   and length, in ticks
edit_note       .byte ?         ; the note being entered
edit_col        .byte ?         ; edit_find: the column looked for ($FF: none)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
edit_at         .word ?         ;   the record found, or where one goes
        .send
edit_on         .byte ?         ;   nonzero: the note found is on its step's start
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
edit_on_now     .byte ?         ;   scratch: the record looked at is
        .send
edit_seen       .byte ?         ;   the step's notes before it
edit_ins        .word ?         ;   the first record after the step's start (high $FF: none)
edit_end        .word ?         ;   the step's records' end (the next step's first)
edit_left       .word ?         ; edit_move_*: records to move
edit_last       .word ?         ;   a record's index (the first or last to move)
edit_hi_tmp     .byte ?         ;   edit_page_of's scratch
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
edit_page       .byte ?         ;   the page being moved
        .send
edit_end_page   .byte ?         ;   the page where the move ends
edit_end_x      .byte ?         ;   and the place in it
edit_stop_x     .byte ?         ;   in the page being moved: the place it stops at
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
edit_dir        .byte ?         ; grid_move_by: the steps to move (1 or -1); edit_change's
        .send
edit_target     .byte ?         ; EDIT_TO_*: what C= + and C= - change (C= V, L, T)
edit_ticks      .word ?         ; edit_len_on: a length in ticks
edit_used       .fill NUM_PATTERNS ; edit_free_number: nonzero = a cell holds the number
grid_confirm    .byte ?         ; grid.asm: nonzero = a CLR waits for its second
edit_copy_cell  .byte ?         ; nonzero: a copy (C= C) to put in its cell once published
edit_copy_from  .byte ?         ;   the pattern copied (the cell is changed only if it
edit_copy_scene .byte ?         ;   still holds it), the cell's scene
edit_copy_track .byte ?         ;   and track
song_more_n     .byte ?         ; song.asm song_more_take: cells listed (0: none)
song_more_row   .byte ?         ;   their row
song_more_go    .byte ?         ;   song_draw_from: nonzero = this put has the pair
song_more_pair  .byte ?         ;   nonzero: the list goes with the pair
song_more_pos   .fill 40        ;   each cell's column, character, colour
song_more_chr   .fill 40
song_more_col   .fill 40
en_rec          .word ?         ; the next record to encode
en_left         .word ?         ; records still to encode
en_last         .word ?         ; the time of the event before (the pattern's start: 0)
en_vel          .byte ?         ; the stream's current velocity, length, controller
en_len          .word ?
en_cc           .byte ?
en_r            .fill REC_SIZE  ; the record being encoded (a copy: wr_byte clobbers Y)
en_gap          .word ?         ; its time since the event before
        .send

; -----------------------------------------------------------------------------
; en_begin - start encoding en_left records from en_rec into a new chain
; (the caller sets them): the stream's starting values, a block taken.
; Carry set = the pool is full (nothing taken).
; clobbers A, Y, ptr
; -----------------------------------------------------------------------------
en_begin
        jsr wr_begin
        bcs _full
        lda #0
        sta en_last
        sta en_last+1
        lda #START_VELOCITY
        sta en_vel
        lda #<START_LENGTH
        sta en_len
        lda #>START_LENGTH
        sta en_len+1
        lda #START_CC
        sta en_cc
        clc
_full   rts

; -----------------------------------------------------------------------------
; en_record - the next record (en_left > 0) encoded onto the stream, then
; on to the one after. Carry set = the pool is full: the stream abandoned
; (wr_abandon), nothing changed.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
en_record
        ; the record copied, and on to the next
        lda en_rec
        sta grid_ptr
        lda en_rec+1
        sta grid_ptr+1
        ldy #REC_SIZE-1
-       lda (grid_ptr),y
        sta en_r,y
        dey
        bpl -
        clc
        lda en_rec
        adc #REC_SIZE
        sta en_rec
        bcc +
        inc en_rec+1
+       lda en_left
        bne +
        dec en_left+1
+       dec en_left
        ; its time: the ticks since the event before, one byte under
        ; TIME_LONG, else TIME_LONG + the high byte, then the low byte
        sec
        lda en_r+REC_TIME_LO
        sbc en_last
        sta en_gap
        lda en_r+REC_TIME_HI
        sbc en_last+1
        sta en_gap+1
        lda en_r+REC_TIME_LO
        sta en_last
        lda en_r+REC_TIME_HI
        sta en_last+1
        lda en_gap+1
        bne _long
        lda en_gap
        cmp #TIME_LONG
        bcc _short
_long   lda en_gap+1
        ora #TIME_LONG
        jsr en_put
        lda en_gap
_short  jsr en_put
        ; the event, by its type
        lda en_r+REC_TYPE
        beq en_note             ; (TYPE_NOTE)
        cmp #TYPE_CC
        beq en_cc_event
        cmp #TYPE_BEND
        beq en_bend
        ; a program change (TYPE_PROGRAM)
        lda #EV_PROGRAM
        jsr en_put
        lda en_r+REC_D1
        jmp en_last_byte

; en_bend - pitch bend: its two 7-bit halves
en_bend lda #EV_BEND
        jsr en_put
        lda en_r+REC_D1
        jsr en_put
        lda en_r+REC_D2
        jmp en_last_byte

; en_cc_event - a controller: EV_CC_SAME and the value when it is the
; current number, else EV_CC, the number (now the current one), the value
en_cc_event
        lda en_r+REC_D1
        cmp en_cc
        bne +
        lda #EV_CC_SAME
        jsr en_put
        jmp ++
+       sta en_cc
        lda #EV_CC
        jsr en_put
        lda en_cc
        jsr en_put
+       lda en_r+REC_D2
        jmp en_last_byte

; en_note - a note: a length prefix if its length isn't the current one
; (len_table's prefix if it is one of them, else EV_LEN_BYTE under 256,
; else EV_LEN_WORD), a velocity prefix if its velocity isn't, the note
en_note lda en_r+REC_LEN_LO
        cmp en_len
        bne _length
        lda en_r+REC_LEN_HI
        cmp en_len+1
        beq _velocity
_length lda en_r+REC_LEN_LO     ; (now the current length)
        sta en_len
        lda en_r+REC_LEN_HI
        sta en_len+1
        bne _word
        ldx #EV_LEN_BYTE-EV_LEN_TABLE-1 ; one of the table's?
        lda en_len
-       cmp len_table,x
        beq _table
        dex
        bpl -
        lda #EV_LEN_BYTE        ; a byte
        jsr en_put
        lda en_len
        jsr en_put
        jmp _velocity
_table  txa
        ora #EV_LEN_TABLE
        jsr en_put
        jmp _velocity
_word   lda #EV_LEN_WORD        ; two bytes
        jsr en_put
        lda en_len
        jsr en_put
        lda en_len+1
        jsr en_put
_velocity
        lda en_r+REC_VEL
        cmp en_vel
        beq +
        sta en_vel
        lda #EV_VELOCITY
        jsr en_put
        lda en_vel
        jsr en_put
+       lda en_r+REC_D1
        ; (on into en_last_byte)

; en_last_byte - the event's last byte A written: carry clear, or set and
; the stream abandoned (the pool is full)
en_last_byte
        jsr en_put
        clc
        rts

; en_put - byte A onto the stream (wr_byte). The pool full: back to the
; caller of en_record (or en_finish) instead, the stream abandoned, carry
; set (en_put's own return address dropped: it is called only at their
; level, never from a routine of theirs).
; preserves A (written); clobbers Y, ptr (and X, pool_next when full)
en_put  jsr wr_byte
        bcc +
        pla
        pla
        jsr wr_abandon
        sec
+       rts

; -----------------------------------------------------------------------------
; en_finish - (every record encoded) the stream's end. Carry set = the
; pool is full: the stream abandoned. Then wr_publish switches it in.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
en_finish
        lda #TIME_END
        jmp en_last_byte

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; edit_init - (synth_init) nothing edited, the entry settings at start.
; clobbers A
; -----------------------------------------------------------------------------
edit_init
        lda #EDIT_CLEAN
        sta edit_state
        sta edit_full
        sta edit_whole
        sta edit_wait
        sta song_more_n
        sta grid_confirm
        sta edit_copy_cell
        sta edit_target         ; (EDIT_TO_VELOCITY)
        lda #ENTRY_VELOCITY
        sta edit_vel
        lda #<ENTRY_LENGTH
        sta edit_len
        lda #>ENTRY_LENGTH
        sta edit_len+1
        lda #0
        sta undo_busy
        jmp undo_clear
        .send

; -----------------------------------------------------------------------------
; edit_touch - (an edit made) the table to publish: an encoding under way
; dropped (it would encode a table that changed under it), a full pool
; tried again.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
edit_touch
        lda edit_state
        cmp #EDIT_ENCODING
        bne +
        jsr wr_abandon
+       lda #EDIT_CHANGED
        sta edit_state
        lda #0
        sta edit_full
        rts

; -----------------------------------------------------------------------------
; edit_slice - (grid_slice, no grid job) an edited table encoded into a
; new chain a record at a time while the 250 Hz tick has time, then
; published (live.asm live_publish: heard at once). Not while the list of
; replaced chains is full (live_room: looked at before beginning and again
; just before publishing); a full pool: tried again after the next edit.
; clobbers A, X, Y, ptr, pool_next, grid_ptr
; -----------------------------------------------------------------------------
edit_slice
        lda edit_state
        bne +
        rts
+       cmp #EDIT_ENCODING
        beq _encode
        ; edited: begun, if it may be published (and the pool had room)
        lda edit_full
        bne _rts
        jsr live_room
        bcs edit_waits          ; (the replaced chains' list full)
+       lda #<GRID_TABLE
        sta en_rec
        lda #>GRID_TABLE
        sta en_rec+1
        lda grid_count
        sta en_left
        lda grid_count+1
        sta en_left+1
        jsr en_begin
        bcs _full
        lda #EDIT_ENCODING
        sta edit_state
        ; a record at a time while there is time
_encode lda en_left
        ora en_left+1
        beq _finish
        jsr en_record
        bcs _full               ; (abandoned)
        lda tick_count
        cmp tick_done
        bne _rts
        lda CIA1_TB_HI
        cmp #EDIT_SPARE_HI
        bcs _encode
_rts    rts
        ; the end, and published
_finish jsr en_finish
        bcs _full               ; (abandoned)
        jsr live_room
        bcs _unsafe
        ldx grid_pattern
        lda grid_steps
        jsr live_publish
        lda #EDIT_CLEAN
        sta edit_state
        jsr edit_copy_put       ; (a copy: into its cell now)
        lda edit_wait           ; (it waited: the title's "*" gone)
        beq +
        lda #0
        sta edit_wait
        ldx #SONG_TITLE_ROW
        jmp song_dirty_row
+       rts
_unsafe jsr wr_abandon          ; (can't be: nothing else publishes; later)
        lda #EDIT_CHANGED
        sta edit_state
        jmp edit_waits
_full   lda #1
        sta edit_full
        lda #EDIT_CHANGED
        sta edit_state
        ; (on into edit_waits)

; edit_waits - the publish waits: the title's "*" (drawn when it appears)
edit_waits
        lda edit_wait
        bne +
        inc edit_wait
        ldx #SONG_TITLE_ROW
        jmp song_dirty_row
+       rts

; -----------------------------------------------------------------------------
; edit_free_number - A = the first pattern number no scene's cell holds
; and with no pattern (~14,000 cycles: every cell looked at). Carry set:
; none.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
edit_free_number
        lda #0
        ldx #NUM_PATTERNS-1
-       sta edit_used,x
        dex
        bpl -
        ; every cell's number marked (NO_PATTERN, $FF: none)
        lda #1
        ldx #0
_cell
        .for _page := 0, _page < NUM_SCENES * NUM_TRACKS / 256, _page += 1
        ldy SCENES + _page * $100,x
        bmi +
        sta edit_used,y
+
        .endfor
        inx
        bne _cell
        ; the first unmarked with no pattern
        ldx #0
-       lda edit_used,x
        ora PAT_STEPS,x
        beq _found
        inx
        cpx #NUM_PATTERNS
        bne -
        sec
        rts
_found  txa
        clc
        rts
        .cerror NUM_PATTERNS > 128, "edit_free_number: NO_PATTERN told apart by its high bit"

; -----------------------------------------------------------------------------
; edit_new - (grid_open) pattern X made new in the table: no events,
; NEW_STEPS long, to publish (so its number is taken).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
edit_new
        stx grid_pattern
        lda #NEW_STEPS
        sta grid_steps
        lda #0
        sta grid_count
        sta grid_count+1
        ldx #MAX_STEPS
-       sta GRID_STEP_LO,x
        sta GRID_STEP_HI,x
        dex
        bpl -
        lda #1
        sta edit_whole
        jmp edit_touch

; -----------------------------------------------------------------------------
; edit_copy - (C= C) the open pattern copied to the first free number (the
; user, 2026-11-22): the table becomes the new number's (published as an
; edit), its history cleared (another pattern). The cell the grid was
; opened from gets the copy once it is published (edit_copy_put: before
; that the number has no pattern, and the playing scene's track would
; fall silent until then); the original stays as it is, in its other
; cells. Carry set: nothing done (the table not whole, an edit waiting to
; be published: the original's own, or no number free).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
edit_copy
        lda edit_whole
        beq _no
        lda edit_state
        bne _no
        jsr edit_free_number
        bcs _no
        tax
        lda grid_pattern
        sta edit_copy_from
        stx grid_pattern
        lda song_row            ; (the grid's cell: the song screen's cursor)
        sta edit_copy_scene
        lda grid_track
        sta edit_copy_track
        lda #1
        sta edit_copy_cell
        jsr undo_clear
        jsr edit_touch
        clc
        rts
_no     sec
        rts

; edit_copy_put - (a publish) a copy's cell given the copy, if it still
; holds the original (the playing scene's: switched by the live rule, the
; same notes); the song screen's rows drawn again if it is shown.
; clobbers A, X, Y
edit_copy_put
        lda edit_copy_cell
        beq _done
        lda #0
        sta edit_copy_cell
        ldx edit_copy_scene
        jsr song_scene_at
        ldy edit_copy_track
        lda (song_scene_ptr),y
        cmp edit_copy_from
        bne _done               ; (changed since on the song screen: left so)
        lda grid_pattern
        sta (song_scene_ptr),y
        cpx play_scene1         ; (scene.asm; edit, grid: a hint only, song.asm's mark: set by scene.asm)
        bne +
        sty lv_scan             ; (the live switch looks there first)
+       lda song_mode
        bne _done
        jmp song_dirty_grid
_done   rts

; -----------------------------------------------------------------------------
; edit_clear_all - (CLR) every record out of the table, the length kept,
; to publish. Kept for undo when it fits (UNDO_CLEAR_MAX records: entries
; of UNDO_MAX_RECS, the table's last first, so undo puts each back at the
; table's end); else (grid.asm asked first) the history cleared. When
; the history and its entries won't both fit, the history goes first, at
; once (undo_room dropping its groups one at a time, each moving the rest
; down a byte at a time, took a 93-event CLR to ~145,000 cycles).
; clobbers A, X, Y, ptr, grid_ptr, pool_next
; -----------------------------------------------------------------------------
edit_clear_all
        lda grid_count+1
        bne _no_undo
        lda grid_count
        cmp #UNDO_CLEAR_MAX+1
        bcs _no_undo
        sta edit_left           ; (records still to keep)
        jsr undo_fit_clear      ; (the history first, if it and these won't both fit)
_keep   lda edit_left
        beq _cleared
        ldx #UNDO_MAX_RECS      ; this entry's: at most UNDO_MAX_RECS
        cmp #UNDO_MAX_RECS
        bcs +
        tax
+       stx edit_seen
        sec
        sbc edit_seen
        sta edit_left
        sta edit_at             ; (from there to the end)
        lda #0
        sta edit_at+1
        lda #UNDO_CUT
        ldx edit_seen
        jsr undo_save
        jmp _keep
_no_undo
        jsr undo_clear
_cleared
        lda #0
        sta grid_count
        sta grid_count+1
        ldx #MAX_STEPS          ; (every step's first: none)
-       sta GRID_STEP_LO,x
        sta GRID_STEP_HI,x
        dex
        bpl -
        jmp edit_touch

; -----------------------------------------------------------------------------
; edit_record_ptr - grid_ptr = record edit_at's address (GRID_TABLE +
; edit_at * 8). clobbers A
; -----------------------------------------------------------------------------
edit_record_ptr
        lda edit_at
        sta grid_ptr
        lda edit_at+1
        asl grid_ptr
        rol a
        asl grid_ptr
        rol a
        asl grid_ptr
        rol a
        clc
        adc #>GRID_TABLE
        sta grid_ptr+1
        rts
        .cerror (GRID_TABLE & $ff) != 0, "edit_record_ptr: the edit table on a page"

; -----------------------------------------------------------------------------
; edit_find - the cursor's step's note in column edit_col (its n-th note
; in the table's order): carry clear, edit_at = its record, edit_on
; nonzero if it is on the step's start. Else (none there; edit_col $FF:
; none looked for) carry set, edit_at = where a note on the step's start
; goes: after the step's records on its start, before those after it.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
edit_find
        ldx grid_cursor
        lda GRID_STEP_LO+1,x
        sta edit_end
        lda GRID_STEP_HI+1,x
        sta edit_end+1
        lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
        lda #$ff
        sta edit_ins+1
        lda #0
        sta edit_seen
_record lda edit_at             ; the step's end?
        cmp edit_end
        bne +
        lda edit_at+1
        cmp edit_end+1
        beq _end
+       jsr edit_record_ptr
        ; on the step's start? (the first record after it: where a note goes)
        lda #0
        sta edit_on_now
        ldx grid_cursor
        jsr step_tick
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        cmp step_lo
        bne _off
        iny
        lda (grid_ptr),y
        cmp step_hi
        bne _off
        inc edit_on_now
        jmp _kind
_off    lda edit_ins+1
        bpl _kind               ; (the first found already)
        lda edit_at
        sta edit_ins
        lda edit_at+1
        sta edit_ins+1
        ; a note: the one looked for?
_kind   ldy #REC_TYPE
        lda (grid_ptr),y
        bne _next               ; (not a note: TYPE_NOTE is 0)
        lda edit_seen
        cmp edit_col
        beq _found
        inc edit_seen
_next   inc edit_at
        bne +
        inc edit_at+1
+       jmp _record
_found  lda edit_on_now
        sta edit_on
        clc
        rts
        ; none: where a note on the step's start goes
_end    lda edit_ins+1
        bmi +                   ; (no record after the start: the step's end)
        sta edit_at+1
        lda edit_ins
        sta edit_at
+       sec
        rts
        .cerror TYPE_NOTE != 0, "edit_find: TYPE_NOTE tested as 0"

; -----------------------------------------------------------------------------
; edit_enter_note - (a note key) note A into the cursor's step, column
; edit_col ($FF: added): the column's note replaced (on the step's start:
; in place; off it: taken out, then put on the start), else a note added
; on the step's start. The table full: nothing. Carry set: nothing done.
; clobbers A, X, Y, grid_ptr, ptr, pool_next
; -----------------------------------------------------------------------------
edit_enter_note
        sta edit_note
        lda edit_whole
        beq _no
        jsr edit_find
        bcs _add
        lda edit_on
        bne _inplace            ; (on the start: in place)
        lda #UNDO_DELETE        ; off it: out, then in on the start (both kept for
        ldx #1                  ; undo)
        jsr undo_save
        jsr edit_delete
        lda #$ff
        sta edit_col
        jsr edit_find
_add    lda grid_count+1        ; room?
        cmp #>GRID_MAX
        bne +
        lda grid_count
        cmp #<GRID_MAX
        bcs _no
+       jsr edit_insert
        jsr edit_put_note
        lda #UNDO_INSERT        ; (kept as put in)
        ldx #1
        jsr undo_save
        jmp _done
_inplace
        lda #UNDO_RANGE         ; (kept as it was)
        ldx #1
        jsr undo_save
        jsr edit_put_note
_done   jsr edit_touch
        clc
        rts
_no     sec
        rts

; -----------------------------------------------------------------------------
; edit_clear - (SPACE, DEL) the cursor's column's note taken out. Carry
; set: none there (or the table not whole).
; clobbers A, X, Y, grid_ptr, ptr, pool_next
; -----------------------------------------------------------------------------
edit_clear
        lda edit_whole
        beq _no
        lda grid_col
        sta edit_col
        jsr edit_find
        bcs _no
        lda #UNDO_DELETE        ; (kept for undo)
        ldx #1
        jsr undo_save
        jsr edit_delete
        jsr edit_touch
        clc
        rts
_no     sec
        rts

; -----------------------------------------------------------------------------
; edit_change - (C= + / C= -: A = 1 or $FF) what C= V, L or T picked
; (edit_target; the user, 2026-11-21) one on: the cursor's column's note's
; velocity (1-127) or length (in whole steps, 1-128: a length not whole
; goes to the whole step above or below), the entry setting then the
; same; with no note there the entry setting alone. Transpose: every note
; of the pattern a semitone (none if one would leave 0-127). Returns A:
; EDIT_DREW_ENTRY (the entry row changed), EDIT_DREW_NOTE (the cursor's
; row too), EDIT_DREW_ALL (every step row); carry set: nothing changed.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
edit_change
        sta edit_dir
        lda edit_target
        cmp #EDIT_TO_TRANSPOSE
        bne +
        jmp edit_transpose
+       lda edit_whole          ; the cursor's note (none: the entry setting)
        beq _entry
        lda grid_col
        sta edit_col
        jsr edit_find
        bcs _entry
        jsr edit_record_ptr
        lda edit_target
        cmp #EDIT_TO_LENGTH
        beq _note_len
        ; a note's velocity
        ldy #REC_VEL
        lda (grid_ptr),y
        jsr edit_vel_on
        bcs _no
        pha
        jsr _keep
        pla
        ldy #REC_VEL
        sta (grid_ptr),y
        sta edit_vel
        jmp _note
        ; a note's length
_note_len
        ldy #REC_LEN_LO
        lda (grid_ptr),y
        sta edit_ticks
        iny
        lda (grid_ptr),y
        sta edit_ticks+1
        jsr edit_len_on
        bcs _no
        jsr _keep
        ldy #REC_LEN_LO
        lda edit_ticks
        sta (grid_ptr),y
        sta edit_len
        iny
        lda edit_ticks+1
        sta (grid_ptr),y
        sta edit_len+1
_note   jsr edit_touch
        lda #EDIT_DREW_NOTE
        clc
        rts
        ; the entry setting alone
_entry  lda edit_target
        cmp #EDIT_TO_LENGTH
        beq _entry_len
        lda edit_vel
        jsr edit_vel_on
        bcs _no
        sta edit_vel
        jmp _entry_done
_entry_len
        lda edit_len
        sta edit_ticks
        lda edit_len+1
        sta edit_ticks+1
        jsr edit_len_on
        bcs _no
        lda edit_ticks
        sta edit_len
        lda edit_ticks+1
        sta edit_len+1
_entry_done
        lda #EDIT_DREW_ENTRY
        clc
        rts
_no     sec
        rts
; _keep - the note as it is kept for undo (grid_ptr found again)
_keep   lda #UNDO_RANGE
        ldx #1
        jsr undo_save
        jmp edit_record_ptr

; edit_vel_on - velocity A one on (edit_dir), 1-127. Carry set: past the
; end (A unchanged). keeps Y
edit_vel_on
        clc
        adc edit_dir
        beq _past               ; (below 1)
        bmi _past               ; (above 127)
        clc
        rts
_past   sec
        rts

; edit_len_on - length edit_ticks to the next whole step (edit_dir): up
; from a whole one a step, from one not whole the step above; down the
; same below; 1-128 steps (MAX_STEPS). Carry set: past the end.
; clobbers A, X
edit_len_on
        lda edit_ticks
        sta div_lo
        lda edit_ticks+1
        sta div_hi
        jsr div12               ; (Z clear: some ticks over)
        beq _whole
        ldx edit_dir
        bmi _set                ; down from not whole: the step below (the quotient)
        bpl _up                 ; up: the step above
_whole  lda div_lo
        clc
        adc edit_dir
        sta div_lo
        jmp _check
_up     inc div_lo
_set
_check  lda div_hi              ; 1-128 steps
        bne _past
        lda div_lo
        beq _past
        cmp #MAX_STEPS+1
        bcs _past
        ; edit_ticks = steps * 12 (* 8 + * 4)
        lda #0
        sta edit_ticks+1
        lda div_lo
        asl
        rol edit_ticks+1
        asl
        rol edit_ticks+1
        sta edit_ticks          ; (* 4)
        ldx edit_ticks+1
        asl
        rol edit_ticks+1
        clc
        adc edit_ticks
        sta edit_ticks
        txa
        adc edit_ticks+1
        sta edit_ticks+1
        clc
        rts
_past   sec
        rts

; edit_transpose - (edit_change, EDIT_TO_TRANSPOSE) every note a semitone
; (edit_dir): first looked at (one past 0-127: nothing), then changed.
; ~45 cycles a record each time (a full table: ~35,000, 1.8 frames).
; clobbers A, X, Y, grid_ptr
edit_transpose
        lda edit_whole
        beq _no
        lda #0                  ; the first pass looks, the second changes
        sta edit_on_now
_pass   lda #<GRID_TABLE
        sta grid_ptr
        lda #>GRID_TABLE
        sta grid_ptr+1
        lda grid_count
        sta edit_left
        lda grid_count+1
        sta edit_left+1
_record lda edit_left
        ora edit_left+1
        beq _passed
        ldy #REC_TYPE
        lda (grid_ptr),y
        bne _next               ; (not a note: TYPE_NOTE is 0)
        iny                     ; (REC_D1: the note)
        lda (grid_ptr),y
        clc
        adc edit_dir
        bmi _no                 ; (past 0 or 127)
        ldx edit_on_now
        beq _next
        sta (grid_ptr),y
_next   lda grid_ptr
        clc
        adc #REC_SIZE
        sta grid_ptr
        bcc +
        inc grid_ptr+1
+       lda edit_left
        bne +
        dec edit_left+1
+       dec edit_left
        jmp _record
_passed lda edit_on_now
        bne _done
        inc edit_on_now
        jmp _pass
_done   lda undo_busy           ; kept for undo (not when undoing one)
        bne +
        lda edit_dir
        sta edit_at
        lda #0
        sta edit_at+1
        lda #UNDO_TRANSPOSE
        ldx #0
        jsr undo_save
+       jsr edit_touch
        lda #EDIT_DREW_ALL
        clc
        rts
_no     sec
        rts
        .cerror REC_D1 != REC_TYPE + 1, "edit_transpose: REC_D1 after REC_TYPE"

; -----------------------------------------------------------------------------
; edit_quantize - (C= Q) the cursor's step's notes not on its start put on
; it (design 5: their lengths kept; exact ticks are the event list's). The
; table stays in time order: a note is moved ahead of the step's other
; events off its start (controllers, bend and program changes stay where
; they are). Carry set: nothing to move.
; clobbers A, X, Y, grid_ptr, ptr
; -----------------------------------------------------------------------------
edit_quantize
        lda edit_whole
        bne +
        sec                     ; (not whole: not edited)
        rts
+       ldx grid_cursor         ; the step's records kept for undo (dropped again if
        sec                     ; none moves)
        lda GRID_STEP_LO+1,x
        sbc GRID_STEP_LO,x
        tay
        lda GRID_STEP_HI+1,x
        sbc GRID_STEP_HI,x
        beq +
        ldy #$ff                ; (more than an entry keeps)
+       lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
        tya
        tax
        lda #UNDO_RANGE
        jsr undo_save
        lda #0
        sta edit_seen           ; (notes moved)
        ; the notes ahead of the other events off the start, a swap at a
        ; time (a step holds few events)
_sweep  ldx grid_cursor
        lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
        lda #0
        sta edit_on_now         ; (an event off the start, not a note, seen)
_look   jsr _end_q              ; the step's last record?
        beq _times
        jsr edit_record_ptr
        jsr edit_on_start
        beq _on                 ; (on the start: not moved)
        ldy #REC_TYPE
        lda (grid_ptr),y
        beq _note
        lda #1                  ; another event off the start
        sta edit_on_now
        bne _on
_note   lda edit_on_now         ; a note after one: swapped with the record before it
        beq _on
        jsr edit_swap_back
        jmp _sweep
_on     inc edit_at
        bne _look
        inc edit_at+1
        jmp _look
        ; then the notes off the start onto it
_times  ldx grid_cursor
        lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
-       jsr _end_q
        beq _moved
        jsr edit_record_ptr
        jsr edit_on_start
        beq +
        ldy #REC_TYPE
        lda (grid_ptr),y
        bne +
        ldx grid_cursor         ; (REC_TIME: the step's tick)
        jsr step_tick
        ldy #REC_TIME_LO
        lda step_lo
        sta (grid_ptr),y
        iny
        lda step_hi
        sta (grid_ptr),y
        inc edit_seen
+       inc edit_at
        bne -
        inc edit_at+1
        jmp -
_moved  lda edit_seen
        beq _none
        jsr edit_touch
        clc
        rts
_none   jsr undo_unsave
_no     sec
        rts
; _end_q - Z set: edit_at is the next step's first record
_end_q  ldx grid_cursor
        lda edit_at
        cmp GRID_STEP_LO+1,x
        bne +
        lda edit_at+1
        cmp GRID_STEP_HI+1,x
+       rts

; edit_on_start - Z set: record grid_ptr is on the cursor's step's start.
; clobbers A, X, Y
edit_on_start
        ldx grid_cursor
        jsr step_tick
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        cmp step_lo
        bne +
        iny
        lda (grid_ptr),y
        cmp step_hi
+       rts

; edit_swap_back - record grid_ptr and the one before it swapped (ptr:
; the one before). clobbers A, X, Y, ptr
edit_swap_back
        lda grid_ptr
        sec
        sbc #REC_SIZE
        sta ptr
        lda grid_ptr+1
        sbc #0
        sta ptr+1
        ldy #REC_SIZE-1
-       lda (grid_ptr),y
        tax
        lda (ptr),y
        sta (grid_ptr),y
        txa
        sta (ptr),y
        dey
        bpl -
        rts

; -----------------------------------------------------------------------------
; edit_put_note - record edit_at becomes a note: edit_note on the cursor's
; step's start, the entry velocity and length.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
edit_put_note
        jsr edit_record_ptr
        ldx grid_cursor
        jsr step_tick
        ldy #REC_TIME_LO
        lda step_lo
        sta (grid_ptr),y
        iny
        lda step_hi
        sta (grid_ptr),y
        iny
        lda #TYPE_NOTE          ; (REC_TYPE)
        sta (grid_ptr),y
        iny
        lda edit_note           ; (REC_D1)
        sta (grid_ptr),y
        iny
        lda #0                  ; (REC_D2)
        sta (grid_ptr),y
        iny
        lda edit_vel            ; (REC_VEL)
        sta (grid_ptr),y
        iny
        lda edit_len            ; (REC_LEN_LO, HI)
        sta (grid_ptr),y
        iny
        lda edit_len+1
        sta (grid_ptr),y
        rts
        .cerror REC_TIME_HI != 1 || REC_TYPE != 2 || REC_D1 != 3 || REC_D2 != 4 || REC_VEL != 5 || REC_LEN_LO != 6 || REC_LEN_HI != 7, "edit_put_note: the record's order"

; -----------------------------------------------------------------------------
; edit_insert / edit_delete - a record put in at edit_at (the ones from
; there on moved up one) / taken out (the ones after it moved down one);
; the count, and the steps' index after the cursor's step (to the
; length's entry, the end), one more / less (the record is the cursor's
; step's).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
edit_insert
        jsr edit_move_up
        inc grid_count
        bne +
        inc grid_count+1
+       ldx grid_cursor
-       inx
        inc GRID_STEP_LO,x
        bne +
        inc GRID_STEP_HI,x
+       cpx grid_steps
        bne -
        rts

edit_delete
        jsr edit_move_down
        lda grid_count
        bne +
        dec grid_count+1
+       dec grid_count
        ldx grid_cursor
-       inx
        lda GRID_STEP_LO,x
        bne +
        dec GRID_STEP_HI,x
+       dec GRID_STEP_LO,x
        cpx grid_steps
        bne -
        rts

; -----------------------------------------------------------------------------
; edit_page_of - record edit_last's page in the table (Y: index / 32) and
; place in it (A: (index & 31) * 8). clobbers A, Y
; -----------------------------------------------------------------------------
edit_page_of
        lda edit_last+1
        sta edit_hi_tmp
        lda edit_last
        lsr edit_hi_tmp         ; (the index has 9 bits)
        ror a
        lsr a
        lsr a
        lsr a
        lsr a
        tay
        lda edit_last
        and #RECS_A_PAGE-1
        asl a
        asl a
        asl a
        rts

; -----------------------------------------------------------------------------
; edit_move_up - (a record to put in at edit_at; the table not full) the
; records from edit_at to the last moved up one, the last first, a page of
; 32 at a time: 8 bytes a pass through absolute,X operands whose high
; bytes are the page's (~11 cycles a byte: a full table's 3 KB ~33,000
; cycles).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
edit_move_up
        lda edit_at             ; none to move (at the end)?
        cmp grid_count
        bne +
        lda edit_at+1
        cmp grid_count+1
        bne +
        rts
+       ; where it ends: edit_at's page and place
        lda edit_at
        sta edit_last
        lda edit_at+1
        sta edit_last+1
        jsr edit_page_of
        sty edit_end_page
        sta edit_end_x
        ; where it starts: the last record's
        sec
        lda grid_count
        sbc #1
        sta edit_last
        lda grid_count+1
        sbc #0
        sta edit_last+1
        jsr edit_page_of
        sty edit_page
        tax
        ; a page: its operands, then its records down to where it stops
_page   lda edit_page
        clc
        adc #>GRID_TABLE
        .for _i := 0, _i < 16, _i += 1
        sta _up + 3 * _i + 2
        .endfor
        ldy #0
        lda edit_page
        cmp edit_end_page
        bne +
        ldy edit_end_x          ; (its last page: down to edit_at)
+       sty edit_stop_x
_up
        .for _k := 7, _k >= 0, _k -= 1
        lda GRID_TABLE + _k,x
        sta GRID_TABLE + REC_SIZE + _k,x
        .endfor
        cpx edit_stop_x
        beq +
        txa
        sec
        sbc #REC_SIZE
        tax
        jmp _up
+       lda edit_page           ; edit_at's page done: all moved
        cmp edit_end_page
        beq _done
        dec edit_page
        ldx #256 - REC_SIZE
        jmp _page
_done   rts

; -----------------------------------------------------------------------------
; edit_move_down - (record edit_at taken out) the records after it moved
; down one, the first first, a page at a time as edit_move_up.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
edit_move_down
        clc                     ; the first to move: edit_at + 1; none if it is the count
        lda edit_at
        adc #1
        sta edit_last
        lda edit_at+1
        adc #0
        sta edit_last+1
        cmp grid_count+1
        bne +
        lda edit_last
        cmp grid_count
        bne +
        rts
+       jsr edit_page_of
        sty edit_page
        pha                     ; (its place: where X starts)
        ; where it ends: the last record's page and place
        sec
        lda grid_count
        sbc #1
        sta edit_last
        lda grid_count+1
        sbc #0
        sta edit_last+1
        jsr edit_page_of
        sty edit_end_page
        sta edit_end_x
        pla
        tax
        ; a page: its operands (the stores' a page lower: a record below the
        ; page's first is the page before's last), then its records up to
        ; where it stops
_page   lda edit_page
        clc
        adc #>GRID_TABLE
        .for _i := 0, _i < 8, _i += 1
        sta _down + 6 * _i + 2
        .endfor
        sec
        sbc #1
        .for _i := 0, _i < 8, _i += 1
        sta _down + 6 * _i + 5
        .endfor
        ldy #256 - REC_SIZE
        lda edit_page
        cmp edit_end_page
        bne +
        ldy edit_end_x          ; (its last page: up to the last record)
+       sty edit_stop_x
_down
        .for _k := 0, _k < 8, _k += 1
        lda GRID_TABLE + _k,x
        sta GRID_TABLE - REC_SIZE + _k,x
        .endfor
        cpx edit_stop_x
        beq +
        txa
        clc
        adc #REC_SIZE
        tax
        jmp _down
+       lda edit_page           ; the last record's page done: all moved
        cmp edit_end_page
        beq _done
        inc edit_page
        ldx #0
        jmp _page
_done   rts
