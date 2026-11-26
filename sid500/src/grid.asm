; grid.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The step grid (docs/design.md section 5, "The step grid"; the user,
; 2026-11-21): one pattern, a row per step, 16 steps a page, 3 note
; columns (pitch, the off-step mark, velocity, length), "+" for more notes
; on a step. RETURN on a song screen cell with a pattern opens it (heard
; on that track's channel); RETURN goes back.
;
; The pattern is decoded into an edit table under the KERNAL (GRID_TABLE:
; a record of 8 bytes an event, in the stream's order) and an index of
; each step's first event, a piece at a time (grid_slice, from synth_tick,
; while the 250 Hz tick has time); then the screen is the grid's. The rows
; are drawn by song.asm's machinery (urgent and dirty rows, prepared
; aside, put when the beam allows; the cursor's move put in one moment):
; song_prepare and song_cursor_screen ask grid.asm in MODE_GRID.
;
; The decoder is the main loop's reader (events.asm ed_*), which the live
; switch keeps between ticks while it reads: the two take turns
; (grid_job's decoding keeps live_begin from starting; the decoding waits
; while the live switch reads).
;
; The edits are edit.asm's (the table changed, then encoded into a new
; chain and published); grid.asm has the keys and the screen.

MODE_SONG       = 0             ; song_mode: the song screen's rows
MODE_GRID       = 1             ;   the step grid's
GRID_TABLE      = $e000         ; the edit table: GRID_MAX records of 8 bytes, under the
GRID_MAX        = 256           ; KERNAL (design 3: parts used only while editing; 384
                                ; until the size pass: the 1 KB after it is HI3_CODE)
HI3_CODE        = GRID_TABLE + GRID_MAX * 8 ; code (sid500.asm), up to the step index
GRID_STEP_LO    = GRID_TABLE + $c00 ; each step's first event (index), 0-128
GRID_STEP_HI    = GRID_STEP_LO + $100
MAX_STEPS       = 128           ; a pattern's longest (the index: 0 to MAX_STEPS)
        .cerror GRID_STEP_HI + 129 > $f000, "the edit table runs into the wheel"
        .cerror TEST_PROBE, "TEST_PROBE uses $E000 (the edit table)"
; a record's bytes
REC_TIME_LO     = 0             ; its tick in the pattern
REC_TIME_HI     = 1
REC_TYPE        = 2             ; TYPE_* (events.asm)
REC_D1          = 3             ; the note, controller, ...
REC_D2          = 4
REC_VEL         = 5             ; a note's velocity
REC_LEN_LO      = 6             ;   and length in ticks
REC_LEN_HI      = 7
REC_SIZE        = 8
; the screen
GRID_STEP_ROW   = 3             ; the first step's row
GRID_STEPS      = 16            ; steps a page
GRID_COL0       = 3             ; the first note column
GRID_COL_WIDTH  = 12            ;   a space, pitch 3, mark 1, velocity 3, a space, length 3
GRID_COLS       = 3
GRID_MORE_COL   = 39            ; "+": more notes on the step
GRID_HELP_ROW   = 21
CHAR_OFF_STEP   = $27           ; "'" after a note not on its step's start
CHAR_LESS       = $3c           ; "<": a length under a step ("<1")
CHAR_PLUS       = $2b
; grid_job
JOB_NONE        = 0
JOB_INDEX       = 1             ; each step's first event being found
JOB_DECODE      = 2             ; the pattern being decoded into the edit table (live_slice
JOB_MERGE       = 3             ; waits from here on); a take's merge (take.asm: the
                                ; table, the reader and the encoder its own meanwhile)
GRID_SPARE_HI   = SLICE_SPARE_HI ; a piece goes on while more than this many pages of the
                                ; 250 Hz tick's cycles are left (at least one event)
GRID_KEYS_ROW   = 22            ; the note keys' help
GRID_ENTRY_ROW  = 23            ; the entry settings
GRID_ENTRY_OCT  = 11            ;   their places
GRID_ENTRY_VEL  = 18
GRID_ENTRY_LEN  = 27
GRID_TITLE_MARK = 34            ; "*": edits waiting to be published (not heard)
CHAR_STAR       = $2a
KEY_RETURN      = 1
KEY_F5          = 6             ; (SHIFT: F6)
KEY_RUNSTOP     = 63
KEY_HOME        = 6*8+3         ; (SHIFT: CLR)
KEY_CBM_COLUMN  = 7             ; C=: key_now's column and row bit (held: a command, not
KEY_CBM_BIT     = 1 << 5        ; a note)
KEY_CBM_CODE    = KEY_CBM_COLUMN*8+5 ; C='s own key code
GRID_KEY_V      = 3*8+7         ; the C= commands' letters (key matrix: column * 8 + row)
GRID_KEY_L      = 5*8+2
GRID_KEY_T      = 2*8+6
GRID_KEY_Q      = 7*8+6
GRID_KEY_U      = 3*8+6
GRID_KEY_C      = 2*8+4
GRID_ENTRY_TARGET = 36          ; the entry row: what C= + and C= - change

        .section zp
grid_ptr        .word ?         ; a record in the edit table
        .send

        .section live_vars      ; (the RAM at $C280: see live.asm)
song_mode       .byte ?         ; MODE_SONG or MODE_GRID
grid_job        .byte ?         ; JOB_*
grid_pattern    .byte ?         ; the pattern shown
grid_track      .byte ?         ;   the track it was opened from (its colour, channel)
grid_steps      .byte ?         ;   its length in steps
grid_count      .word ?         ; events in the edit table
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
grid_time       .word ?         ; decoding: the next event's tick; indexing: the step's
        .send
grid_step       .byte ?         ; indexing: the step whose first event is looked for
grid_index      .word ?         ;   the event looked at
grid_top        .byte ?         ; the first step shown (a page's)
grid_cursor     .byte ?         ; the cursor's step
grid_col        .byte ?         ;   and note column, 0-2
grid_colour     .byte ?         ; the notes' colour (the track's)
grid_line_step  .byte ?         ; grid_step_line's scratch: its step
grid_note_col   .byte ?         ;   the column being filled
grid_more       .byte ?         ;   nonzero: more notes than columns
grid_end        .word ?         ;   the step's events end (the next step's first)
grid_line_tmp   .byte ?         ; grid_note_cell: the column's pitch's place
grid_held       .byte ?         ; step entry from MIDI: the keys held (0: none)
        .send

        .section edit_vars      ; (under the KERNAL: main loop only)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
step_lo         .byte ?         ; step_tick: a step's tick
        .send
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
step_hi         .byte ?
        .send
        .send

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; grid_init - (synth_init) the song screen's rows, no job.
; clobbers A
; -----------------------------------------------------------------------------
grid_init
        lda #0
        sta grid_held
        lda #MODE_SONG
        sta song_mode
        lda #JOB_NONE
        sta grid_job
        jmp edit_init
        .send

; -----------------------------------------------------------------------------
; grid_open - (RETURN on the song screen) the cursor's cell's pattern to
; the step grid: decoded first (grid_slice), then shown. An empty cell: a
; new pattern, the first free number, put in the cell; a number with no
; pattern yet: a new pattern of that number (edit.asm edit_new: published
; empty at once). The table's edits not yet published: only their own
; pattern opens (the table shown as it is), no other.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
grid_open
        jsr hi3_in              ; (disk.asm: the event list's code at HI3_CODE back)
        lda grid_job
        bne _no                 ; (one being opened)
        jsr song_cell_read
        cmp #NO_PATTERN
        beq _empty
        tax
        lda edit_state          ; edits not yet published: theirs only
        beq +
        cpx grid_pattern
        bne _no
        jsr grid_from_cell
        jmp grid_show           ; (the table as it is)
+       lda PAT_STEPS,x
        beq _new
        sta grid_steps
        stx grid_pattern
        jsr grid_from_cell
        jsr undo_clear          ; (another pattern: its own history)
        lda #JOB_DECODE
        sta grid_job
        lda #0
        sta grid_count
        sta grid_count+1
        sta grid_time
        sta grid_time+1
        lda #1                  ; (until the decoding stops short)
        sta edit_whole
        lda #<GRID_TABLE
        sta grid_ptr
        lda #>GRID_TABLE
        sta grid_ptr+1
        ; (the reader starts in grid_slice: the live switch may be reading)
_no     rts
        ; an empty cell: the first free number into it
_empty  lda edit_state
        bne _no
        jsr edit_free_number
        bcs _no                 ; (none free)
        pha
        jsr song_cell_write
        pla
        tax
        ; a new pattern
_new    jsr undo_clear
        jsr edit_new
        jsr grid_from_cell
        jmp grid_show

; song_cell_write - (song.asm's, here out of the live reader's way: design
; 5b "Recording as built") A into the cursor's cell (scene song_row, track
; song_cursor); the playing scene's: the live switch looks there first.
; clobbers X, Y
song_cell_write
        pha
        ldx song_row
        jsr song_scene_at
        ldy song_cursor
        pla
        sta (song_scene_ptr),y
        cpx play_scene1         ; (scene.asm; edit, grid: a hint only, song.asm's mark: set by scene.asm)
        bne +
        sty lv_scan             ; (the playing scene: the live switch looks there first)
+       rts

; grid_from_cell - the track the grid is opened from (its colour), the
; cursor at the first step. clobbers A, X
grid_from_cell
        lda song_cursor
        sta grid_track
        tax
        jsr song_track_colour
        sta grid_colour
        lda #0
        sta grid_top
        sta grid_cursor
        sta grid_col
        sta grid_confirm
        rts

; -----------------------------------------------------------------------------
; grid_slice - (synth_tick) the job's next piece while the 250 Hz tick has
; time: decoding an event at a time (not while the live switch is reading:
; the reader is shared), then indexing a step at a time; done: the grid
; shown.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
grid_slice
        lda grid_job
        bne +
        jmp edit_slice          ; (no job: an edit's encoding, if any)
+       cmp #JOB_INDEX
        bne +
        jmp grid_index_steps
+       cmp #JOB_MERGE
        bne +
        jmp rec_merge_slice
+       ; decoding
        lda lv_phase
        cmp #LIVE_READ
        bne _go
_rts    rts                     ; (the reader is the live switch's now)
_go
        lda grid_count          ; begun? (the first piece starts the reader)
        ora grid_count+1
        ora grid_time
        ora grid_time+1
        bne _event
        lda grid_pattern
        jsr ed_start
_event  jsr ed_read_time
        bcc +
        jmp _decoded            ; (the end)
+       clc
        lda grid_time
        adc ed_delta
        sta grid_time
        lda grid_time+1
        adc ed_delta+1
        sta grid_time+1
        jsr ed_read_event
        lda ed_type             ; a broken stream: read as ended there (the table
        cmp #TYPE_BAD           ; not the whole pattern: not edited)
        beq _short
        lda grid_count+1        ; room? (more: the rest not shown, the end taken as
        cmp #>GRID_MAX          ; here, the table not edited)
        bne +
        lda grid_count
        cmp #<GRID_MAX
        bcs _short
+       ldy #REC_TIME_LO
        lda grid_time
        sta (grid_ptr),y
        iny
        lda grid_time+1
        sta (grid_ptr),y
        iny
        lda ed_type
        sta (grid_ptr),y
        iny
        lda ed_d1
        sta (grid_ptr),y
        iny
        lda ed_d2
        sta (grid_ptr),y
        iny
        lda ed_vel
        sta (grid_ptr),y
        iny
        lda ed_len
        sta (grid_ptr),y
        iny
        lda ed_len+1
        sta (grid_ptr),y
        clc
        lda grid_ptr
        adc #REC_SIZE
        sta grid_ptr
        bcc +
        inc grid_ptr+1
+       inc grid_count
        bne +
        inc grid_count+1
+       ; time left?
        lda tick_count
        cmp tick_done
        bne _done
        lda CIA1_TB_HI
        cmp #GRID_SPARE_HI
        bcc _done
        jmp _event
_done   rts
_short  lda #0
        sta edit_whole
        ; decoded: on to the index
_decoded
        lda #JOB_INDEX
        sta grid_job
        lda #0
        sta grid_step
        sta grid_index
        sta grid_index+1
        sta grid_time           ; (the step's tick)
        sta grid_time+1
        lda #<GRID_TABLE
        sta grid_ptr
        lda #>GRID_TABLE
        sta grid_ptr+1
        rts

; grid_index_steps - (JOB_INDEX) each step's first event: the first whose
; tick is the step's or later (steps 0 to grid_steps: the last is the
; end, the records after it notes kept past a shortened end), a step at a
; time while the tick has time; then the grid shown.
grid_index_steps
_step   ; on past the events before the step's tick
-       lda grid_index          ; (all looked at: the rest of the steps start there)
        cmp grid_count
        lda grid_index+1
        sbc grid_count+1
        bcs _found
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        cmp grid_time
        iny
        lda (grid_ptr),y
        sbc grid_time+1
        bcs _found              ; (this one's tick is the step's or later)
        clc
        lda grid_ptr
        adc #REC_SIZE
        sta grid_ptr
        bcc +
        inc grid_ptr+1
+       inc grid_index
        bne -
        inc grid_index+1
        jmp -
_found  ldx grid_step
        lda grid_index
        sta GRID_STEP_LO,x
        lda grid_index+1
        sta GRID_STEP_HI,x
        cpx grid_steps
        beq _shown              ; (the last: the end; past it, + finds each)
        inc grid_step
        clc
        lda grid_time
        adc #TICKS_PER_STEP
        sta grid_time
        bcc +
        inc grid_time+1
+       lda tick_count          ; time left?
        cmp tick_done
        bne +
        lda CIA1_TB_HI
        cmp #GRID_SPARE_HI
        bcs _step
+       rts
        ; done: the grid shown
_shown  lda #JOB_NONE
        sta grid_job
        ; (on into grid_show)

; grid_show - the step grid shown, every row drawn again.
; clobbers A, X, Y
grid_show
        lda #MODE_GRID
        sta song_mode
        lda #$ff
        sta song_old_row        ; (no move pending)
        lda #0
        sta song_shift
        sta song_recolour
        lda #LINE_OTHER
        sta song_line_kind
        jsr grid_all_rows
        lda #KEY_NONE           ; no key repeat carried over
        sta repeat_cmd
        rts

; grid_all_rows - every row to draw again (the title and the cursor's
; first). clobbers A, X, Y
grid_all_rows
        jsr song_dirty_grid
        ldx #SONG_TITLE_ROW
        jsr song_urgent_row
        ldx #1
        jsr song_dirty_row
        jmp song_urgent_cursor

; -----------------------------------------------------------------------------
; grid_close - (RETURN on the grid) back to the song screen, every row
; drawn again. clobbers A, X, Y
; -----------------------------------------------------------------------------
grid_close
        lda #0                  ; (step entry: keys held count no more)
        sta grid_held
        lda #MODE_SONG
        sta song_mode
        lda #$ff
        sta song_old_row
        jsr song_colours_reset
        jsr grid_all_rows
        lda #KEY_NONE
        sta repeat_cmd
        rts

; -----------------------------------------------------------------------------
; grid_cursor_screen - X = the cursor's step's row; carry clear (always
; shown: the page follows the cursor). clobbers A
; -----------------------------------------------------------------------------
grid_cursor_screen
        lda grid_cursor
        sec
        sbc grid_top
        clc
        adc #GRID_STEP_ROW
        tax
        clc
        rts

; -----------------------------------------------------------------------------
; grid_key - (synth_key, MODE_GRID, a press) A = the key: CRSR up and
; down (the steps; a page turned when the cursor leaves it), right and
; left (the note columns), a note key (Z S X ..., Q 2 W ...: the note in
; the cursor's column, the cursor down a step; SHIFT: added to the step,
; the cursor stays), SPACE a rest (the column's note out, the cursor
; down), DEL (the column's note out), F5 / F6 the entry octave, + / -
; the pattern's length, HOME the cursor to step 1, CLR (SHIFT+HOME) the
; pattern cleared (a big one only at a second CLR: grid_key_clr), RETURN
; back to the song screen, RUN/STOP play and stop (as SPACE elsewhere:
; SPACE is the rest key here, as on SID303). A CLR waiting for its second:
; any other key cancels it (and does what it does). Carry set: used (A:
; nonzero = repeat).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
grid_key
        jsr undo_key            ; (a key: its edits a group of their own)
        tax
        lda grid_confirm        ; a CLR waiting: cancelled by any key but CLR (and SHIFT
        beq _keys               ; and C= themselves: the core passes their presses too,
        cpx #KEY_CODE_LSHIFT    ; SHIFT's before HOME's)
        beq _keys
        cpx #KEY_CODE_RSHIFT
        beq _keys
        cpx #KEY_CBM_CODE
        beq _keys
        cpx #KEY_HOME
        bne _cancel
        lda shift_held
        beq _cancel
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq _keys
_cancel lda #0
        sta grid_confirm
        txa
        pha
        ldx #GRID_ENTRY_ROW     ; (the entry row back)
        jsr song_urgent_row
        pla
        tax
_keys   lda key_now+KEY_CBM_COLUMN ; C= held: a command
        and #KEY_CBM_BIT
        beq +
        txa
        jmp grid_cbm_key
+       txa
        cmp #KEY_CRSR_DOWN
        beq grid_key_down
        cmp #KEY_CRSR_RIGHT
        beq grid_key_right
        cmp #KEY_RETURN
        bne +
        jsr grid_close
        jmp song_key_done
+       cmp #KEY_RUNSTOP
        bne +
        lda #KEY_SPACE          ; (play and stop: the transport's SPACE)
        jsr synth_param_key
        jmp song_key_done
+       cmp #KEY_SPACE
        bne +
        jmp grid_key_rest
+       cmp #KEY_DEL
        bne +
        jmp grid_key_del
+       cmp #KEY_F5
        bne +
        jmp grid_key_octave
+       cmp #KEY_PLUS
        bne +
        jmp grid_key_longer
+       cmp #KEY_MINUS
        bne +
        jmp grid_key_shorter
+       cmp #KEY_HOME
        bne +
        jmp grid_key_home
+       tax                     ; a note key?
        lda grid_note_keys,x
        bpl grid_key_note
+       jmp song_key_done       ; (the rest: nothing here, nor the core's: its + and -
                                ; would change a parameter not shown)

; grid_key_right - the next note column (SHIFT: the one before), round
grid_key_right
        jsr grid_mark_old
        ldx grid_col
        lda shift_held
        bne _left
        inx
        cpx #GRID_COLS
        bcc +
        ldx #0
        beq +
_left   dex
        bpl +
        ldx #GRID_COLS-1
+       stx grid_col
        lda #$ff                ; (the same row: drawn whole)
        sta song_old_row
        jmp song_cursor_repeat

; grid_key_down - the next step (SHIFT: the one before)
grid_key_down
        ldx #1
        lda shift_held
        beq +
        ldx #$ff
+       jsr grid_move_by
        jmp song_key_repeat

; grid_move_by - the cursor X steps on (1, or $FF: back one; not past the
; first or the last); off the page: the next (or previous) page shown.
; clobbers A, X, Y
grid_move_by
        stx edit_dir
        jsr grid_mark_old
        clc
        lda grid_cursor
        adc edit_dir
        cmp grid_steps          ; (back from the first: $FF, past too)
        bcs _done
        tax
        stx grid_cursor
        ; off the page: the page it is on, every row drawn again
        txa
        and #$ff-(GRID_STEPS-1)
        cmp grid_top
        beq _done
        sta grid_top
        lda song_old_row        ; (every row drawn again, the old cursor put back with
        jsr grid_all_rows       ; the new one: list.asm list_pair_safe)
_done   jsr grid_cursor_screen  ; on the old cursor's row still: drawn whole
        cpx song_old_row
        bne +
        lda #$ff
        sta song_old_row
+       jmp song_urgent_cursor

; grid_key_note - note key X: its note (kb_base: the Z key's, F5 / F6;
; above 127 an octave lower) in the cursor's column, the cursor down
; (SHIFT: added to the step, the cursor stays). C= held: none (C= keys
; are commands).
grid_key_note
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        bne _used
        lda grid_note_keys,x
        clc
        adc kb_base
-       bpl +
        sec
        sbc #12
        jmp -
+       ldx grid_col
        ldy shift_held
        beq +
        ldx #$ff                ; (SHIFT: added)
+       stx edit_col
        jsr edit_enter_note
        bcs _used               ; (nothing done: the table full or not whole)
        lda shift_held
        bne _stay
        jmp grid_edited_down
_stay   jsr song_urgent_cursor
        jsr song_urgent         ; (drawn now)
_used   jmp song_key_done

; grid_key_rest - SPACE: the column's note out (if any), the cursor down
grid_key_rest
        jsr edit_clear
        bcc grid_edited_down
+       ldx #1
        jsr grid_move_by
        jmp song_key_repeat

; grid_key_del - DEL: the column's note out, the cursor stays; the
; cursor's row drawn now (none there too: every key answered)
grid_key_del
        jsr edit_clear
        jsr song_urgent_cursor
        jmp song_urgent_done    ; (drawn now)

; grid_edited_down - (the cursor's step edited) the cursor down a step,
; both rows drawn now, not at the next 250 Hz tick: the edited row (the
; old cursor's) prepared first and its changed cells listed (song.asm
; song_more_take), put right after the cursor's row and its pair, in the
; same moment's window (drawn one after the other, waiting for the
; tick and the beam twice made notes ~1.3 frames late on the band). No
; move (the last step): the cursor's row, the edited one, drawn whole.
grid_edited_down
        ldx #1
        jsr grid_move_by
        ldx song_old_row
        bmi +                   ; (no move)
        lda #1                  ; (with the move's pair)
        jsr song_more_take
+       jmp song_urgent_repeat

; grid_key_longer / grid_key_shorter - + / -: the pattern a step longer
; (up to MAX_STEPS) / shorter (down to 1; the cursor off the end: up a
; step). Notes past the end are kept, silent and not shown (the user,
; 2026-11-21): lengthening brings them back. The step's row and the title
; drawn now.
grid_key_longer
        lda edit_whole
        beq _done
        ldx grid_steps
        cpx #MAX_STEPS
        bcs _done
        jsr grid_keep_length
        jsr grid_index_next
        ldx grid_steps
        inc grid_steps
        jmp grid_length_changed  ; (X: the step gained)
_done   jmp song_key_done
grid_key_shorter
        lda edit_whole
        beq _done
        ldx grid_steps
        cpx #2
        bcc _done
        jsr grid_keep_length
        ldx grid_steps
        dex
        cpx grid_cursor
        bne +
        txa                     ; (the cursor on the last step: up first)
        pha
        ldx #$ff
        jsr grid_move_by
        pla
        tax
+       stx grid_steps          ; (X: the step lost)
        jmp grid_length_changed
_done   jmp song_key_done

; grid_keep_length - (+, -) the length as it is kept for undo (undo.asm).
; clobbers A, X, Y, ptr, grid_ptr
grid_keep_length
        lda grid_steps
        sta edit_at
        lda #0
        sta edit_at+1
        lda #UNDO_LENGTH
        ldx #0
        jmp undo_save

; grid_index_next - (+) the index's entry after the last (grid_steps + 1):
; the first record from the last entry on whose tick is that step's or
; later (the index is kept to the length only: an edit adjusting all 128
; entries cost ~1,500 cycles). clobbers A, X, Y, grid_ptr
grid_index_next
        ldx grid_steps
        lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
_record lda edit_at             ; all looked at?
        cmp grid_count
        lda edit_at+1
        sbc grid_count+1
        bcs _found
        jsr edit_record_ptr
        ldx grid_steps
        inx
        jsr step_tick
        ldy #REC_TIME_LO        ; its tick < the next step's: on
        lda (grid_ptr),y
        cmp step_lo
        iny
        lda (grid_ptr),y
        sbc step_hi
        bcs _found
        inc edit_at
        bne _record
        inc edit_at+1
        jmp _record
_found  ldx grid_steps
        lda edit_at
        sta GRID_STEP_LO+1,x
        lda edit_at+1
        sta GRID_STEP_HI+1,x
        rts

; grid_length_changed - (+, -) step X gained or lost: its row (if on the
; page) and the title urgent, drawn now; the edit to publish
grid_length_changed
        txa
        sec
        sbc grid_top
        cmp #GRID_STEPS
        bcs _title              ; (not on the page)
        adc #GRID_STEP_ROW
        tax
        jsr song_urgent_row
        ldx #SONG_TITLE_ROW     ; the title listed, put right after the step's row
        lda #0                  ; (one wait for the beam, not two: + and - took up to
        jsr song_more_take      ; 24,700 cycles)
        jmp +
_title  ldx #SONG_TITLE_ROW
        jsr song_urgent_row
+       jsr edit_touch
        jmp song_urgent_repeat

; grid_key_home - HOME: the cursor to step 1 (its page shown); SHIFT, CLR:
; grid_key_clr
grid_key_home
        lda shift_held
        bne grid_key_clr
        lda grid_cursor         ; (back by the cursor's step)
        eor #$ff
        clc
        adc #1
        tax
        jsr grid_move_by
        jmp song_key_done

; grid_key_clr - CLR: every event of the pattern out, its length kept (the
; user, 2026-11-22: edit.asm edit_clear_all). One that fits in the undo
; history (UNDO_CLEAR_MAX events) at once, undoable; a bigger one first
; asks (the entry row: "CLR AGAIN ..."), cleared at a second CLR, not
; undoable; any other key cancels (grid_key). Every row drawn again; none
; to clear (or the table not whole): the cursor's row, so every key is
; answered.
grid_key_clr
        lda edit_whole
        beq _same
        lda grid_count
        ora grid_count+1
        beq _same               ; (nothing to clear)
        lda grid_confirm
        bne _clear              ; (the second CLR)
        lda grid_count+1        ; fits in the history?
        bne _ask
        lda grid_count
        cmp #UNDO_CLEAR_MAX+1
        bcc _clear
_ask    lda #1
        sta grid_confirm
        ldx #GRID_ENTRY_ROW
        jsr song_urgent_row
        jmp song_urgent_done
_clear  jsr edit_clear_all      ; (grid_confirm set: the history cleared instead)
        lda #0
        sta grid_confirm
        jsr song_dirty_grid     ; every row (the entry row among them), the cursor's first
        jsr song_urgent_cursor
        jmp song_urgent_done
_same   jsr song_urgent_cursor
        jmp song_urgent_done

; grid_key_copy - C= C: the pattern copied to the first free number, the
; copy put in the cell it was opened from and shown (the user, 2026-11-22:
; edit.asm edit_copy); the title drawn now (its number). Not while an
; edit waits to be published, nor with no number free: the cursor's row,
; so every key is answered.
grid_key_copy
        jsr edit_copy
        bcs +
        ldx #SONG_TITLE_ROW
        jsr song_urgent_row
        jmp song_urgent_done
+       jsr song_urgent_cursor
        jmp song_urgent_done

; grid_key_octave - F5: the entry octave up (SHIFT, F6: down), the
; core's keyboard octave (kb_base)
grid_key_octave
        lda #CMD_OCT_UP
        ldx shift_held
        beq +
        lda #CMD_OCT_DOWN
+       jsr run_command
        ldx #GRID_ENTRY_ROW
        jsr song_urgent_row
        jmp song_key_done

; grid_cbm_key - a key with C= held (the user, 2026-11-21; C= K the
; metronome: click.asm): V, L, T pick
; what C= + and C= - change (the cursor's note's velocity, its length,
; the pattern's transpose: shown on the entry row), + and - change it, Q
; quantizes the cursor's step; the rest nothing.
grid_cbm_key
        jsr click_key           ; (C= K: the metronome)
        bcc +
        jmp song_key_done
+       cmp #KEY_PLUS
        bne +
        lda #1
        jmp grid_key_change
+       cmp #KEY_MINUS
        bne +
        lda #$ff
        jmp grid_key_change
+       ldx #EDIT_TO_VELOCITY
        cmp #GRID_KEY_V
        beq grid_key_target
        ldx #EDIT_TO_LENGTH
        cmp #GRID_KEY_L
        beq grid_key_target
        ldx #EDIT_TO_TRANSPOSE
        cmp #GRID_KEY_T
        beq grid_key_target
        cmp #GRID_KEY_Q
        beq grid_key_quantize
+       cmp #GRID_KEY_U
        beq grid_key_undo
+       cmp #GRID_KEY_C
        beq grid_key_copy
+       jmp song_key_done

; grid_key_undo - C= U: the last key's edits undone (SHIFT: redone), the
; cursor on the step changed, every row drawn again (nothing to undo: the
; cursor's row all the same, every key answered)
grid_key_undo
        lda shift_held
        bne +
        jsr undo_undo
        jmp _drawn
+       jsr undo_redo
_drawn  bcc +
        jsr song_urgent_cursor
+       jmp song_urgent_done

; grid_key_target - C= V, L, T: X = what C= + and C= - change, shown now
grid_key_target
        stx edit_target
        ldx #GRID_ENTRY_ROW
        jsr song_urgent_row
        jmp song_urgent_done

; grid_key_change - C= + / C= - (A = 1 / $FF): edit.asm edit_change; the
; rows it changed drawn now (a transpose: every step row, the cursor's
; first; nothing changed, at an end: the cursor's row all the same, so
; every key is answered on the screen). Repeats while held.
grid_key_change
        jsr edit_change
        bcs _same
        cmp #EDIT_DREW_ALL
        beq _all
        cmp #EDIT_DREW_NOTE
        bne +
        jsr song_urgent_cursor
+       ldx #GRID_ENTRY_ROW
        jsr song_urgent_row
        jsr song_urgent
_done   jmp song_key_repeat
_same   jsr song_urgent_cursor
        jmp song_urgent_repeat
_all    jsr song_dirty_grid
        jsr song_urgent_cursor
        jmp song_urgent_repeat

; grid_key_quantize - C= Q: the cursor's step's notes onto its start, its
; row drawn now (also with none to move: every key answered)
grid_key_quantize
        jsr edit_quantize
        jsr song_urgent_cursor
        jmp song_urgent_done

; -----------------------------------------------------------------------------
; grid_midi_on - (hooks.asm note_on: a note from MIDI in, A the note) step
; entry on the step grid (design 5, "The step grid"): the first key of a
; chord puts its note in the cursor's column, those held with it are added
; to the step, the cursor stays; with the entry velocity and length (the
; key's velocity isn't used). A chord's notes are one edit for undo. Not
; while the pattern is being decoded (or isn't whole: edit.asm).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
grid_midi_on
        ldy song_mode
        beq _no                 ; (the song screen: nothing yet)
        ldy grid_job
        bne _no
        ldx grid_held
        inx
        beq _no                 ; (255 held: can't be)
        stx grid_held
        dex
        bne _more
        jsr undo_key            ; the chord's first: a new group, the cursor's column
        ldx grid_col
        jmp +
_more   ldx #$ff                ; held with it: added
+       stx edit_col
        jsr edit_enter_note
        bcs _no
        jsr song_urgent_cursor
        jmp song_urgent
_no     rts

; grid_midi_off - (note_off) a key of the chord released: all of them, the
; cursor down a step. clobbers A, X, Y
grid_midi_off
        lda grid_held
        beq +                   ; (none held since the grid was shown)
        dec grid_held
        bne +
        lda song_mode
        beq +
        ldx #1
        jsr grid_move_by
        jmp song_urgent
+       rts

; grid_mark_old - the cursor as shown kept (song_old_row, song_old_col:
; its pitch put back plain in the moment the new row is drawn), its row
; drawn again later. clobbers A, X, Y
grid_mark_old
        lda song_old_row
        bpl +                   ; (a move not yet drawn: that place still shown)
        jsr grid_cursor_screen
        stx song_old_row
        jsr grid_col_place
        sta song_old_col
        jsr song_dirty_row
+       rts

; grid_col_place - A = the cursor's column's pitch's place. clobbers A
grid_col_place
        lda grid_col
        asl                     ; * 12 = * 8 + * 4
        asl
        sta grid_note_col
        asl
        clc
        adc grid_note_col
        adc #GRID_COL0+1
        rts

; -----------------------------------------------------------------------------
; grid_prepare - (song_prepare, MODE_GRID) row X prepared aside: the
; title, the header, a step's row, the help, else blank.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
grid_prepare
        lda #LINE_OTHER
        sta song_line_kind
        cpx #SONG_TITLE_ROW
        beq grid_title_line
+       cpx #SONG_HEAD_ROW
        bne +
        jmp grid_head_line
+       cpx #GRID_HELP_ROW
        bne +
        jmp grid_help_line
+       cpx #GRID_KEYS_ROW
        bne +
        jmp grid_keys_line
+       cpx #GRID_ENTRY_ROW
        bne +
        jmp grid_entry_line
+       cpx #GRID_STEP_ROW
        bcc _blank
        cpx #GRID_STEP_ROW+GRID_STEPS
        bcs _blank
        txa
        sec
        sbc #GRID_STEP_ROW
        clc
        adc grid_top
        cmp grid_steps
        bcs _blank
        jmp grid_step_line
_blank  jmp song_blank_line

; grid_title_line - "PAT 001  TRK 02  LEN 016  STEPS 001-016  STOP"
grid_title_line
        lda #COL_SONG_TITLE
        ldx #<grid_title_text
        ldy #>grid_title_text
        jsr line_text
        ldx grid_pattern
        inx
        txa
        ldy #GRID_TITLE_PAT
        jsr grid_num3
        lda grid_track
        clc
        adc #1
        ldy #GRID_TITLE_TRK
        jsr song_num2
        lda grid_steps
        ldy #GRID_TITLE_LEN
        jsr grid_num3
        lda grid_top
        clc
        adc #1
        ldy #GRID_TITLE_FIRST
        jsr grid_num3
        lda grid_top            ; the last shown: the page's, or the pattern's
        clc
        adc #GRID_STEPS
        cmp grid_steps
        bcc +
        lda grid_steps
+       ldy #GRID_TITLE_LAST
        jsr grid_num3
        lda song_shown_state
        asl
        asl
        tax
        ldy #0
-       lda song_state_text,x
        sta song_line+GRID_TITLE_STATE,y
        inx
        iny
        cpy #4
        bne -
        lda edit_wait           ; edits waiting to be published (not heard): "*"
        beq +
        lda #CHAR_STAR
        sta song_line+GRID_TITLE_MARK
+       rts

; grid_num3 - A (0-255) as 3 digits, leading zeros kept, at song_line + Y.
; clobbers A, X; keeps Y
grid_num3
        ldx #CHAR_DIGIT0-1      ; the hundreds
-       inx
        sec
        sbc #100
        bcs -
        adc #100
        pha
        txa
        sta song_line,y
        pla
        iny
        jsr song_num2
        dey
        rts

; grid_head_line - the columns' heads, grey
grid_head_line
        lda #COL_LABEL
        ldx #<grid_head_text
        ldy #>grid_head_text
        jmp line_text

; grid_help_line / grid_keys_line - the keys, grey
grid_help_line
        lda #COL_LABEL
        ldx #<grid_help_text
        ldy #>grid_help_text
        jmp line_text
grid_keys_line
        lda #COL_LABEL
        ldx #<grid_keys_text
        ldy #>grid_keys_text
        jmp line_text

; grid_entry_line - the entry settings: the octave (the Z key's), the
; velocity, the length in steps
grid_entry_line
        lda grid_confirm        ; a CLR waiting for its second: that asked instead
        beq +
        lda #COL_SONG_TITLE
        ldx #<grid_confirm_text
        ldy #>grid_confirm_text
        jmp line_text
+       lda #COL_LABEL
        ldx #<grid_entry_text
        ldy #>grid_entry_text
        jsr line_text
        lda kb_octave           ; (kb_base = 12 * (octave + 1): MIDI note 12 = C0)
        ora #CHAR_DIGIT0
        sta song_line+GRID_ENTRY_OCT
        lda edit_vel
        ldy #GRID_ENTRY_VEL
        jsr song_num3
        lda edit_len
        sta div_lo
        lda edit_len+1
        sta div_hi
        jsr div12
        sta grid_time           ; (the ticks over)
        lda div_lo
        ldy #GRID_ENTRY_LEN-8   ; (grid_len_text: at the pitch's place + 8)
        jsr grid_len_text
        ; what C= + and C= - change
        lda edit_target
        asl
        adc edit_target         ; (* 3)
        tax
        ldy #0
-       lda grid_target_text,x
        sta song_line+GRID_ENTRY_TARGET,y
        inx
        iny
        cpy #3
        bne -
        rts

; -----------------------------------------------------------------------------
; grid_step_line - step A's row prepared: its number (1-128), then the
; notes starting in it, up to 3 (pitch, "'" if not on the step's start,
; velocity, length in steps: "<1", or "+" after it if not whole), "+"
; if more; "---"
; if none. Other events (controllers, bend, program) aren't shown here
; (the event list's, stage F). The cursor's pitch reversed.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
grid_step_line
        sta grid_line_step
        ; blank; the notes' columns in the track's colour, the step's number
        ; grey (8 stores a pass: ~370 cycles, a byte a pass took ~720; a row
        ; is prepared on every edit; fully unrolled ~320 cost 480 bytes)
        ldx #40-8
-       lda #CHAR_SPACE
        .for _i := 0, _i < 8, _i += 1
        sta song_line + _i,x
        .endfor
        lda grid_colour
        .for _i := 0, _i < 8, _i += 1
        sta song_line_col + _i,x
        .endfor
        txa
        sec
        sbc #8
        tax
        bpl -
        lda #COL_LABEL
        sta song_line_col
        sta song_line_col+1
        sta song_line_col+2
        ; the step's number
        ldx grid_line_step
        inx
        txa
        ldy #0
        jsr grid_num3
        ; its events: from its first to the next step's first
        ldx grid_line_step
        lda GRID_STEP_LO+1,x
        sta grid_end
        lda GRID_STEP_HI+1,x
        sta grid_end+1
        lda GRID_STEP_LO,x      ; the record's address: GRID_TABLE + index * 8
        sta grid_ptr
        lda GRID_STEP_HI,x
        sta grid_ptr+1
        lda GRID_STEP_LO,x
        sta grid_index
        lda GRID_STEP_HI,x
        sta grid_index+1
        asl grid_ptr
        rol grid_ptr+1
        asl grid_ptr
        rol grid_ptr+1
        asl grid_ptr
        rol grid_ptr+1
        clc
        lda grid_ptr+1
        adc #>GRID_TABLE
        sta grid_ptr+1
        lda #0
        sta grid_note_col
        sta grid_more
_event  lda grid_index          ; the step's end?
        cmp grid_end
        bne +
        lda grid_index+1
        cmp grid_end+1
        beq _events_done
+       ldy #REC_TYPE
        lda (grid_ptr),y
        cmp #TYPE_NOTE
        bne _next               ; (not a note: not shown here)
        lda grid_note_col
        cmp #GRID_COLS
        bcc +
        sta grid_more           ; (more than the columns)
        bcs _next
+       jsr grid_note_cell
        inc grid_note_col
_next   clc
        lda grid_ptr
        adc #REC_SIZE
        sta grid_ptr
        bcc +
        inc grid_ptr+1
+       inc grid_index
        bne _event
        inc grid_index+1
        jmp _event
_events_done
        ; none: a rest
        lda grid_note_col
        bne +
        lda #CHAR_DASH
        sta song_line+GRID_COL0+1
        sta song_line+GRID_COL0+2
        sta song_line+GRID_COL0+3
        lda #COL_LABEL
        sta song_line_col+GRID_COL0+1
        sta song_line_col+GRID_COL0+2
        sta song_line_col+GRID_COL0+3
+       lda grid_more
        beq +
        lda #CHAR_PLUS
        sta song_line+GRID_MORE_COL
+       ; the cursor's pitch reversed
        lda grid_line_step
        cmp grid_cursor
        bne +
        jsr grid_col_place
        tay
        lda song_line,y
        ora #CHAR_REVERSE
        sta song_line,y
        lda song_line+1,y
        ora #CHAR_REVERSE
        sta song_line+1,y
        lda song_line+2,y
        ora #CHAR_REVERSE
        sta song_line+2,y
+       rts

; grid_note_cell - the note at grid_ptr into column grid_note_col: its
; pitch, "'" if it isn't on the step's start, velocity, length in steps
; (grid_len_text). clobbers A, X, Y
grid_note_cell
        lda grid_note_col       ; Y = the column's place
        asl
        asl
        sta grid_line_tmp
        asl
        clc
        adc grid_line_tmp
        adc #GRID_COL0+1
        sta grid_line_tmp       ; (the pitch's place)
        ; the pitch's name, or a drum's (names.asm name_note)
        ldy #REC_D1
        lda (grid_ptr),y
        ldy grid_line_tmp
        jsr name_note
        ; on the step's start? else "'"
        ldx grid_line_step      ; the step's tick: step * 12, compared with the
        jsr step_tick           ; record's
        lda step_lo
        ldy #REC_TIME_LO
        cmp (grid_ptr),y
        bne _off
        lda step_hi
        iny
        cmp (grid_ptr),y
        beq _on
_off    lda #CHAR_OFF_STEP
        ldy grid_line_tmp
        sta song_line+3,y
_on     ; the velocity, right-aligned (pitch + 4)
        lda grid_line_tmp
        clc
        adc #4
        pha
        ldy #REC_VEL
        lda (grid_ptr),y
        tax
        pla
        tay
        txa
        jsr song_num3
        ; the length in steps: ticks / 12, the ticks over in grid_time (under
        ; 256 ticks by subtraction, ~190 cycles at most; else transport.asm's
        ; div12, ~400)
        ldy #REC_LEN_HI
        lda (grid_ptr),y
        bne _long
        dey
        lda (grid_ptr),y
        ldx #0
-       cmp #TICKS_PER_STEP
        bcc +
        sbc #TICKS_PER_STEP     ; (carry set)
        inx
        bne -
+       sta grid_time
        jmp _steps
_long   sta div_hi
        dey
        lda (grid_ptr),y
        sta div_lo
        jsr div12
        sta grid_time
        lda div_hi              ; (at most 255 shown)
        beq +
        lda #$ff
        sta div_lo
+       ldx div_lo
_steps  txa
        ldy grid_line_tmp
        ; (on into grid_len_text)

; grid_len_text - length A whole steps (grid_time: the ticks over) at the
; column whose pitch is at Y, left-aligned in 3 places: under a step
; "<1"; else the steps, "+" after them if not whole (3+: between 3 and 4;
; the mixed set has no "~"); 100 or more: 3 digits, no "+".
; clobbers A, X, Y
grid_len_text
        pha
        tya
        clc
        adc #8                  ; (the length's place: pitch + 8)
        tay
        pla
        bne +
        lda #CHAR_LESS          ; under a step
        sta song_line,y
        lda #CHAR_DIGIT0+1
        sta song_line+1,y
        rts
+       cmp #100
        bcs _three
        cmp #10
        bcs _two
        ora #CHAR_DIGIT0        ; one digit
        sta song_line,y
        iny
        bne _mark
_two    ldx #CHAR_DIGIT0-1      ; two digits
-       inx
        sec
        sbc #10
        bcs -
        adc #10+CHAR_DIGIT0
        pha
        txa
        sta song_line,y
        pla
        iny
        sta song_line,y
        iny
_mark   lda grid_time           ; ticks over: not whole
        beq +
        lda #CHAR_PLUS
        sta song_line,y
+       rts
_three  jmp grid_num3

; the note keys: each key code's semitones above the Z key ($FF: none),
; as SID303's (Z S X D C V G B H N J M , L . ; / and Q 2 W 3 E R 5 T 6 Y
; 7 U I 9 O 0 P @)
N_ = $ff
grid_note_keys
        .byte N_, N_, N_, N_, N_, N_, N_, N_    ; DEL RETURN CRSR-RT F7 F1 F3 F5 CRSR-DN
        .byte 15, 14, N_, N_, 0, 1, 16, N_      ; 3 W A 4 Z S E LSHIFT
        .byte 18, 17, 3, 20, 4, N_, 19, 2       ; 5 R D 6 C F T X
        .byte 22, 21, 6, N_, 7, 8, 23, 5        ; 7 Y G 8 B H U V
        .byte 25, 24, 10, 27, 11, N_, 26, 9     ; 9 I J 0 M K O N
        .byte N_, 28, 13, N_, 14, N_, 29, 12    ; + P L - . : @ ,
        .byte N_, N_, 15, N_, N_, N_, N_, 16    ; pound * ; HOME RSHIFT = UP /
        .byte N_, N_, N_, 13, N_, N_, 12, N_    ; 1 <- CTRL 2 SPACE C= Q RUN/STOP
        .cerror * - grid_note_keys != 64, "grid_note_keys: a byte a key code"

; the pitch names (the mixed set's capitals: screen codes)
        .enc "screen"
note_letters    .text "CCDDEFFGGAAB"
note_signs      .text "-#-#--#-#-#-"
        .enc "none"

; -----------------------------------------------------------------------------
; step_tick - step X's tick, X * 12 (X 0-129), in step_lo, step_hi (it was
; two tables of 129 bytes: room for recording, 2026-11-22).
; keeps X, Y
; -----------------------------------------------------------------------------
step_tick
        lda #0                  ; X * 3 (9 bits) ...
        sta step_hi
        stx step_lo
        txa
        asl
        rol step_hi             ; (carry out 0: step_hi was 0)
        adc step_lo
        sta step_lo
        lda step_hi
        adc #0
        asl step_lo             ; ... * 4
        rol a
        asl step_lo
        rol a
        sta step_hi
        rts
        .cerror TICKS_PER_STEP != 12, "step_tick multiplies by 12"

GRID_TITLE_PAT  = 4             ; the title's places
GRID_TITLE_TRK  = 13
GRID_TITLE_LEN  = 21
GRID_TITLE_FIRST = 26
GRID_TITLE_LAST = 30
GRID_TITLE_STATE = 36
        .enc "screen"           ; (the texts in screen codes, as song.asm's)
        .section io_data        ; (the rows' texts under I/O: line_text reads them)
grid_title_text .text "PAT 001  TRK 01  LEN 016  001-016   STOP"
        .cerror * - grid_title_text != 40, "the grid's title is a row"
grid_head_text  .text "ST  ", "KEY VEL LEN ", "KEY VEL LEN ", "KEY VEL LEN "
        .cerror * - grid_head_text != 40, "the grid's header is a row"
grid_help_text  .text "RETURN SONG  F3 LIST  RUN/STOP PLAY     "
        .cerror * - grid_help_text != 40, "the grid's help is a row"
grid_keys_text  .text "Z-/ Q-P NOTE SPACE REST DEL CLEAR F5 OCT"
        .cerror * - grid_keys_text != 40, "the grid's keys' help is a row"
grid_entry_text .text "ENTRY  OCT 2  VEL 100  LEN 1   C=+- VEL "
        .cerror * - grid_entry_text != 40, "the grid's entry row is a row"
        .cerror grid_entry_text + GRID_ENTRY_TARGET != * - 4, "GRID_ENTRY_TARGET"
grid_confirm_text .text "CLR AGAIN: CLEAR ALL, NO UNDO  ELSE KEEP"
        .cerror * - grid_confirm_text != 40, "the CLR question is a row"
        .send
grid_target_text .text "VELLENTRN"     ; (EDIT_TO_*: 3 characters each)
        .enc "none"
