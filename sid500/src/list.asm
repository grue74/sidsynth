; list.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The event list (docs/design.md section 5d; the user, 2026-11-24): the
; step grid's other view of the same pattern, F3 flipping between them,
; the cursor on the same event. Every event of the edit table up to the
; pattern's length, in order, a row each, 16 a page: its position
; (bar.beat.tick, from the playing scene's signature), the note or the
; controller, bend or program, its value, a note's velocity and length
; (bar.beat.tick from 0); then an END row at the pattern's length (the
; cursor's place in an empty pattern). The cursor is a field of a row
; (position, the note or value, velocity, length), 3 characters reversed,
; so a move across a row changes at most 6 cells (song.asm song_put_line
; puts that many at once) and a move up or down is put by the step grid's
; pair (song_pair_cell: 3 cells).
;
; The list is the step grid with grid_view set (song_mode stays
; MODE_GRID): song.asm's jumps to grid_key, grid_prepare and
; grid_cursor_screen and hooks.asm's to grid_midi_on and grid_midi_off
; come here first (same-size jumps), and the step grid's own routines run
; as before when grid_view is 0. All of it after the tables, so nothing
; before them moves (design 7: the hot code's place): the keys, the cursor
; and the rows' dispatch in main RAM (late_code); the rows' builder and the
; cursor's mapping between the views under I/O (io_data, run with I/O out
; through list_io: the room was in the RAM under I/O, the size pass's
; tempo computed).

KEY_F3          = 5             ; F3's key code (column 0, row 5)
LIST_ROWS       = 16            ; events a page (the step grid's rows)
LIST_POS        = 0             ; a row's places: the position (8, right-aligned)
LIST_EVENT      = 9             ;   the note or the event's kind
LIST_CC_NUM     = 12            ;   a controller's number (3)
LIST_VALUE_END  = 22            ;   the value's last place (bend: 5 with its sign)
LIST_VEL        = 24            ;   a note's velocity (3)
LIST_LEN        = 28            ;   its length (8, right-aligned)
LIST_VIEW_COL   = 16            ; the help row's "LIST" / "GRID"
CHAR_DOT        = $2e           ; screen codes
CHAR_MINUS      = $2d

; the variables: after size.asm's (main RAM at $CF74, whatever $01 is)
        .virtual size_vars_end
grid_view       .byte ?         ; nonzero: the step grid shows the event list
list_top        .word ?         ; the first event shown (a page's)
list_cursor     .word ?         ; the cursor's event (list_n: the END row)
list_field      .byte ?         ;   and field: 0 position, 1 note or value, 2 velocity,
                                ;   3 length
list_idx        .word ?         ; the event being looked at
list_n          .word ?         ; list_count: the events up to the pattern's length
list_k          .byte ?         ; scratch: a count, a direction
list_d          .byte ?         ; list_div's divisor
list_beats      .byte ?         ; the playing scene's signature: beats a bar
list_beat_ticks .byte ?         ;   and a beat's ticks
list_base       .byte ?         ; list_pos: 1 a position (bar 1, beat 1), 0 a length
list_y          .byte ?         ;   its place
list_ticks      .byte ?         ;   the ticks over the beat
list_beat       .byte ?         ;   the beat
list_sign       .byte ?         ; list_bend's sign
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
list_delta      .byte ?         ; list_change: what + / - add (signed)
        .send
list_lo         .byte ?         ;   a 7-bit value's lowest
list_old        .word ?         ;   the position or length before
list_rec        .fill REC_SIZE  ; list_move_record, list_insert_copy: the record
list_pair_lo    .byte ?         ; list_pair_safe: the two rows, the lower
list_pair_hi    .byte ?         ;   and the higher (then its end's line / 2)
list_vars_end
        .endv
        .cerror list_vars_end > $d000, "the list's variables run past $CFFF"

.if LIST_CODE                ; (sid500.asm LIST_CODE: else the hooks to the grid's own)
        .section lo_code        ; (in low RAM at $0334: sid500.asm LO_CODE, copied at
                                ; start; the program's room)
; -----------------------------------------------------------------------------
; list_key - (song.asm synth_key, in grid_key's place: the step grid's
; keys, a press) A = the key. The step grid: F3 the list, else grid_key.
; The list: CRSR up and down (the events; a page turned when the cursor
; leaves it), right and left (the fields), F3 the step grid, RETURN the
; song screen, RUN/STOP play and stop, C= K the metronome; the rest
; nothing. Carry set: used (A: nonzero = repeat).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
list_key
        ldx grid_view
        bne _list
        cmp #KEY_F3
        beq list_show
        jmp grid_key
_list   tax
        lda key_now+KEY_CBM_COLUMN ; C= held: a command
        and #KEY_CBM_BIT
        beq _plain
        txa
        jsr click_key           ; (C= K: the metronome)
        jmp list_cbm_more       ; (C= U: undo)
_plain  txa
        cmp #KEY_CRSR_DOWN
        beq list_key_down
        cmp #KEY_CRSR_RIGHT
        beq list_key_right
        cmp #KEY_F3
        beq list_hide
        cmp #KEY_RETURN
        bne +
        lda #0                  ; (the step grid's view the next time)
        sta grid_view
        jsr grid_close
        jmp song_key_done
+       cmp #KEY_RUNSTOP
        beq +
        jmp list_key_more       ; (the edits: + -, DEL, INST)
+       lda #KEY_SPACE          ; (play and stop: the transport's SPACE)
        jsr synth_param_key
        jmp song_key_done

; list_show - F3 on the step grid: the list, the cursor on the grid
; cursor's note (else the step's first event, or the next), every row
; drawn again. A CLR waiting for its second is cancelled; keys held for
; step entry count no more.
list_show
        jsr list_from_grid
        lda #1
        bne +
; list_hide - F3 on the list: the step grid, the cursor on the event's
; step (and its column, if a note)
list_hide
        jsr list_to_grid
        lda #0
+       sta grid_view
        lda #0
        sta grid_confirm
        sta grid_held
        lda #$ff
        sta song_old_row        ; (every row drawn again)
        jsr grid_all_rows
        lda #KEY_NONE
        sta repeat_cmd
        jmp song_key_done

; list_key_down - the next event (SHIFT: the one before)
list_key_down
        ldx #1
        lda shift_held
        beq +
        ldx #$ff
+       jsr list_move_by
        jmp song_key_repeat

; list_key_right - the next field (SHIFT: the one before), round the row's
list_key_right
        jsr list_mark_old
        jsr list_max
        sta list_k
        ldx list_field
        lda shift_held
        bne _left
        inx
        cpx list_k
        beq +
        bcc +
        ldx #0
        beq +
_left   dex
        bpl +
        ldx list_k
+       stx list_field
        lda #$ff                ; (the same row: drawn whole)
        sta song_old_row
        jmp song_cursor_repeat

; list_mark_old - the cursor as shown kept (song_old_row, song_old_col: its
; 3 characters put back plain in the moment the new row is drawn), its row
; drawn again later. clobbers A, X, Y, grid_ptr
list_mark_old
        lda song_old_row
        bpl +                   ; (a move not yet drawn: that place still shown)
        jsr list_cursor_screen
        stx song_old_row
        jsr list_place
        sta song_old_col
        ldx song_old_row
        jsr song_dirty_row
+       rts

        .enc "screen"
list_title_text .text "LIST   "     ; (the title's steps' place)
list_grid_text  .text "GRID"        ; (the help row: F3's other view)
        .enc "none"
        .send

        .section lo3_code       ; (in low RAM at $0200: sid500.asm LO3_CODE, copied at
                                ; start; the program's room)
; list_div - div_lo/hi / A: the quotient in div_lo/hi, the remainder in A
; (A 1-127). Under 256 (the beats a bar, most positions and lengths): 8
; steps (~150 cycles), else 16 (~430). clobbers X
list_div
        sta list_d
        lda #0
        ldx div_hi
        bne _16
        ldx #8
-       asl div_lo
        rol a
        cmp list_d
        bcc +
        sbc list_d              ; (carry set)
        inc div_lo              ; (bit 0 was 0)
+       dex
        bne -
        rts
_16     ldx #16
-       asl div_lo
        rol div_hi
        rol a
        cmp list_d
        bcc +
        sbc list_d              ; (carry set)
        inc div_lo              ; (bit 0 was 0)
+       dex
        bne -
        rts

        .send

        .section lo2_code       ; (in low RAM at $02A7: sid500.asm LO2_CODE, copied at
                                ; start; the program's room)
; -----------------------------------------------------------------------------
; list_pair_safe - (song.asm song_put_safe_now, in song_row_safe's place
; for the pair's row) may the old cursor's row X be put back with row
; song_put_x now? As song_row_safe; and when the two rows are far apart (a
; page turned, an undo's move), the beam not between them either: the
; picture is what the beam drew, and with the beam between them the frame
; showed one row before the moment and the other after it (no cursor, or
; two: flash_check.py). Carry set: yes. clobbers A
; -----------------------------------------------------------------------------
list_pair_safe
        jsr song_row_safe       ; (row_beam: the beam's line / 2)
        bcc _no
        cpx song_put_x          ; the lower and the higher row
        bcc +
        stx list_pair_hi
        lda song_put_x
        sta list_pair_lo
        bcs ++
+       stx list_pair_lo
        lda song_put_x
        sta list_pair_hi
+       lda list_pair_hi
        sec
        sbc list_pair_lo
        cmp #2
        bcc _yes                ; (next to each other: nothing between)
        lda list_pair_lo        ; the beam above the lower row's top: yes
        asl a
        asl a
        adc #RASTER_ROW0/2      ; (row r's top line / 2: 4r + 25)
        cmp row_beam
        beq +
        bcs _yes
+       lda list_pair_hi        ; past the higher row's end: yes
        asl a
        asl a
        adc #RASTER_ROW0/2 + 4
        sta list_pair_hi
        lda row_beam
        cmp list_pair_hi
        bcs _yes
        clc                     ; (between them)
        rts
_yes    sec
_no     rts
        .cerror RASTER_ROW0 + SCREEN_ROWS * 8 > 2 * 255, "list_pair_safe: lines / 2 in a byte"

        .send

        .section hi3_code       ; (under the KERNAL at $E800: sid500.asm HI3_CODE, put back by
                                ; hi3_in after the disk overlay was loaded over it)

; -----------------------------------------------------------------------------
; list_key_more - (list_key: the list's keys) + / - the cursor's field by
; one (a tick, a semitone, 1), SHIFT by more (a 16th, an octave, 10); DEL
; the cursor's event out; INST (SHIFT+DEL) a copy of it put in after it,
; the cursor on the copy (design 5d; the user, 2026-11-24). Each heard at
; once (published as the grid's edits: edit_touch) and undoable, a key's
; edits one group. Not on the END row, nor while the table isn't whole:
; then the cursor's row is drawn all the same, so every key is answered.
; Carry set: used (A: nonzero = repeat).
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
list_key_more
        jsr undo_key            ; (a key: its edits a group of their own)
        ldx #1
        cmp #KEY_PLUS
        beq _change
        ldx #$ff
        cmp #KEY_MINUS
        beq _change
        cmp #KEY_DEL
        beq _del
        jmp song_key_done       ; (the rest, SHIFT's own press among them: nothing; a
                                ; cursor marked for one left its row undrawn)
_change stx list_delta
        jsr list_mark_old       ; (the cursor as shown: put back with the new one)
        jsr list_editable
        bcs _same
        jsr list_change
        bcs _same
        jmp song_key_repeat
_same   jsr list_urgent_cursor
        jmp song_urgent_done
_del    jsr list_mark_old
        jsr list_editable
        bcs _same
        lda shift_held
        bne _inst
        jsr list_delete         ; DEL: out, the cursor on the next (or END)
        jmp list_edited_all
_inst   lda grid_count+1        ; INST: room for one more?
        cmp #>GRID_MAX
        bne +
        lda grid_count
        cmp #<GRID_MAX
        bcs _same
+       jsr list_insert_copy
        inc list_cursor         ; (on the copy: after it)
        bne list_edited_all
        inc list_cursor+1
        ; (on into list_edited_all)

; list_edited_all - (an event in or out, or moved, or an undo; the old
; cursor marked: list_mark_old) the edit to publish; the field one the
; cursor's event has; the rows from the old cursor's or the new one's, the
; higher, down to the page's end drawn again (the events below moved), the
; cursor's now (the old one put back in the same moment); on another page,
; every row (drawing every row after each edit, and each key starting the
; rows again, kept rows near the top old for ~25 frames on the band: a
; second cursor meanwhile, flash_check.py). Carry set, A = 0 (no repeat).
; clobbers A, X, Y, grid_ptr
list_edited_all
        jsr edit_touch
        jsr list_max
        cmp list_field
        bcs +
        sta list_field
+       lda list_cursor         ; on the page shown?
        and #$100-LIST_ROWS
        cmp list_top
        bne _page
        lda list_cursor+1
        cmp list_top+1
        bne _page
        jsr list_cursor_screen  ; from the higher row of the two down (no old one:
        cpx song_old_row        ; $FF, the new one's)
        bcc +
        ldx song_old_row
+
-       jsr song_dirty_row
        inx
        cpx #GRID_STEP_ROW+LIST_ROWS
        bcc -
        bcs _cursor
_page   jsr list_page           ; another page: every row
        jsr grid_all_rows
_cursor jsr list_urgent_cursor
        jmp song_urgent_done

; list_editable - the cursor on an event of a whole table: carry clear,
; edit_at = its index, grid_ptr = its record, grid_cursor its step (the
; steps' index is counted after it: edit_insert, edit_delete).
; clobbers A, X, Y
list_editable
        lda edit_whole
        beq _no
        jsr list_at_end
        beq _no
        jsr list_ptr
        lda list_cursor
        sta edit_at
        lda list_cursor+1
        sta edit_at+1
        jsr list_step_of
        clc
        rts
_no     sec
        rts

; list_step_of - grid_cursor = the step of the record at grid_ptr (its tick
; / 12). clobbers A, X, Y
list_step_of
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        sta div_lo
        iny
        lda (grid_ptr),y
        sta div_hi
        jsr div12
        lda div_lo
        sta grid_cursor
        rts

        .send
        .section late_code      ; (resident: HI3_CODE is full)
; -----------------------------------------------------------------------------
; list_change - (list_editable done) the cursor's field by list_delta (1 or
; $FF; with SHIFT 12 or 10 times it): kept for undo first (a range of one
; record), then changed within its bounds (a pitch, a value 0-127, a
; velocity 1-127, a length 1-65535 ticks); its row drawn now. Nothing
; changed (at an end): carry set, the entry dropped. The position, within
; the pattern's length: the event taken out and put in at its new place
; (list_move_record), every row drawn again.
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
list_change
        lda list_field
        beq _position
+       cmp #3
        beq _length
+       lda #UNDO_RANGE         ; kept as it is
        ldx #1
        jsr undo_save
        jsr list_ptr
        lda list_field
        cmp #2
        beq _velocity
        ldy #REC_TYPE           ; the note's pitch (an octave with SHIFT), else a
        lda (grid_ptr),y        ; program's number, a controller's value, a bend's
        ldx #REC_D1             ; high 7 bits
        cmp #TYPE_NOTE
        bne +
        jsr list_shift_12
        jmp _seven
+       cmp #TYPE_PROGRAM
        beq +
        ldx #REC_D2
+       jsr list_shift_10
_seven  lda #0                  ; (0-127)
        beq _add
_velocity
        ldx #REC_VEL
        jsr list_shift_10
        lda #1                  ; (1-127)
_add    sta list_lo
        txa
        tay
        lda (grid_ptr),y
        pha
        jsr list_add7
        sta (grid_ptr),y
        pla
        cmp (grid_ptr),y
        beq _none
_drawn  jsr edit_touch
        jsr list_urgent_cursor
        jsr song_urgent
        clc
        rts
_none   jsr undo_unsave         ; (at an end: nothing changed)
        sec
        rts
        ; a note's length (its last field: notes only)
_length jsr list_shift_12       ; (a 16th with SHIFT)
        lda #UNDO_RANGE
        ldx #1
        jsr undo_save
        jsr list_ptr
        ldy #REC_LEN_LO
        jsr list_add16
        lda div_lo              ; at least 1
        ora div_hi
        bne +
        inc div_lo
+       jsr list_store16
        bcs _none
        bcc _drawn
        ; the position: within the pattern's length
_position
        jsr list_shift_12       ; (a 16th with SHIFT)
        ldy #REC_TIME_LO
        jsr list_add16
        ldx grid_steps          ; past the end: its last tick
        jsr step_tick
        lda div_lo
        cmp step_lo
        lda div_hi
        sbc step_hi
        bcc +
        lda step_lo
        sbc #1                  ; (carry set)
        sta div_lo
        lda step_hi
        sbc #0
        sta div_hi
+       lda div_lo
        cmp list_old
        bne +
        lda div_hi
        cmp list_old+1
        beq _stays
+       jsr list_move_record
        jsr list_edited_all
        clc
        rts
_stays  sec
        rts

        .send
        .section hi3_code       ; (under the KERNAL at $E800: sid500.asm HI3_CODE, put back by
                                ; hi3_in after the disk overlay was loaded over it)

; list_shift_12, list_shift_10 - with SHIFT held, list_delta 12 / 10 times
; itself (a 16th, an octave; 10). keeps X
list_shift_12
        lda #12
        bne +
list_shift_10
        lda #10
+       ldy shift_held
        beq ++
        bit list_delta
        bpl +
        eor #$ff
        clc
        adc #1
+       sta list_delta
+       rts

; list_add7 - A + list_delta within list_lo-127. keeps X, Y
list_add7
        bit list_delta
        bmi _down
        clc
        adc list_delta
        bpl +
        lda #127
+       rts
_down   clc
        adc list_delta          ; (no carry: under 0)
        bcc _lo
        cmp list_lo
        bcs +
_lo     lda list_lo
+       rts

; list_add16 - div_lo/hi = the record's word at Y (grid_ptr) + list_delta,
; within 0-65535; list_old the word as it was. keeps Y; clobbers A, X
list_add16
        lda (grid_ptr),y
        sta list_old
        clc
        adc list_delta
        sta div_lo
        iny
        lda (grid_ptr),y
        sta list_old+1
        ldx #0                  ; (the delta's high byte; the carry kept)
        bit list_delta
        bpl +
        dex
+       stx div_hi
        adc div_hi
        sta div_hi
        dey
        bit list_delta
        bpl _up
        bcs +                   ; (down: no carry is under 0)
        lda #0
        sta div_lo
        sta div_hi
+       rts
_up     bcc +                   ; (up: a carry is over 65535)
        lda #$ff
        sta div_lo
        sta div_hi
+       rts

; list_store16 - div_lo/hi into the record's word at Y (grid_ptr); carry
; set: it was that already. clobbers A, Y
list_store16
        lda div_lo
        cmp list_old
        bne +
        lda div_hi
        cmp list_old+1
        sec
        beq ++
+       lda div_lo
        sta (grid_ptr),y
        iny
        lda div_hi
        sta (grid_ptr),y
        clc
+       rts

; -----------------------------------------------------------------------------
; list_move_record - (list_editable done) the cursor's event to tick
; div_lo/hi: taken out (kept for undo), its new place found (gone later:
; after the events on that tick; earlier: before them), put in there (kept),
; the cursor on it. clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
list_move_record
        ldy #REC_SIZE-1         ; the record, its new tick
-       lda (grid_ptr),y
        sta list_rec,y
        dey
        bpl -
        lda div_lo
        sta list_rec+REC_TIME_LO
        lda div_hi
        sta list_rec+REC_TIME_HI
        jsr list_delete         ; out
        lda #0                  ; its place: past those before its tick (and those on
        sta edit_at             ; it, gone later)
        sta edit_at+1
_look   lda edit_at
        cmp grid_count
        lda edit_at+1
        sbc grid_count+1
        bcs _found
        jsr edit_record_ptr
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        cmp list_rec+REC_TIME_LO
        iny
        lda (grid_ptr),y
        sbc list_rec+REC_TIME_HI
        bcc _on                 ; (before its tick)
        bne _found              ; (after it)
        dey
        lda (grid_ptr),y
        cmp list_rec+REC_TIME_LO
        bne _found
        bit list_delta          ; (on it: past them when it went later)
        bmi _found
_on     inc edit_at
        bne _look
        inc edit_at+1
        bne _look
_found  lda edit_at             ; the cursor on it
        sta list_cursor
        lda edit_at+1
        sta list_cursor+1
        ; (on into list_put_rec)

; list_put_rec - list_rec put in at edit_at (grid_cursor its step), kept
; for undo. clobbers A, X, Y, ptr, grid_ptr
list_put_rec
        lda list_rec+REC_TIME_LO
        sta div_lo
        lda list_rec+REC_TIME_HI
        sta div_hi
        jsr div12
        lda div_lo
        sta grid_cursor
        jsr edit_insert
        jsr edit_record_ptr
        ldy #REC_SIZE-1
-       lda list_rec,y
        sta (grid_ptr),y
        dey
        bpl -
        lda #UNDO_INSERT        ; (kept once in)
        ldx #1
        jmp undo_save

; list_insert_copy - (INST; list_editable done) the cursor's event copied,
; put in after it. clobbers A, X, Y, ptr, grid_ptr
list_insert_copy
        ldy #REC_SIZE-1
-       lda (grid_ptr),y
        sta list_rec,y
        dey
        bpl -
        inc edit_at
        bne list_put_rec
        inc edit_at+1
        bne list_put_rec

; list_delete - (list_editable done) the event at edit_at out (grid_cursor
; its step), kept for undo first. clobbers A, X, Y, ptr, grid_ptr
list_delete
        lda #UNDO_DELETE
        ldx #1
        jsr undo_save
        jmp edit_delete

; -----------------------------------------------------------------------------
; list_cbm_more - (list_key: C= held, after click_key; carry set: it was C=
; K) C= U the last key's edits undone (SHIFT: redone), the cursor on the
; event changed (within the list), every row drawn again; nothing to undo:
; the cursor's row, so every key is answered. The rest nothing.
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
list_cbm_more
        bcs _done
        cmp #GRID_KEY_U
        bne _done
        jsr list_mark_old       ; (the list's cursor as shown, kept: undo_undo's
        lda song_old_row        ; grid_mark_old leaves it, undo_done may drop it)
        pha
        lda song_old_col
        pha
        lda shift_held
        bne +
        jsr undo_undo
        jmp ++
+       jsr undo_redo
+       pla
        sta song_old_col
        pla
        sta song_old_row
        bcs _same
        lda edit_at             ; the cursor on the event changed, within the list
        sta list_cursor
        lda edit_at+1
        sta list_cursor+1
        jsr list_count
        lda list_n
        cmp list_cursor
        lda list_n+1
        sbc list_cursor+1
        bcs +
        lda list_n
        sta list_cursor
        lda list_n+1
        sta list_cursor+1
+       jmp list_edited_all
_same   jsr list_urgent_cursor
        jsr song_urgent
_done   jmp song_key_done

; list_urgent_cursor - the cursor's row to draw first; on the old cursor's
; row still (an edit in place, an undo there): drawn whole, no put-back
; (else song_draw_from leaves that row for the put-back: it waited on
; itself). clobbers A, X, Y
list_urgent_cursor
        jsr list_cursor_screen
        cpx song_old_row
        bne +
        lda #$ff
        sta song_old_row
+       jmp song_urgent_cursor

; list_move_by - the cursor an event on (X = 1) or back (X = $FF), not past
; the first or the END row; the field kept if the row has it; off the page:
; the page it is on, every row drawn again.
; clobbers A, X, Y, grid_ptr
list_move_by
        stx list_k
        jsr list_mark_old
        jsr list_count
        lda list_k
        bmi _up
        lda list_cursor         ; down: not past the END row
        cmp list_n
        lda list_cursor+1
        sbc list_n+1
        bcs _done
        inc list_cursor
        bne _moved
        inc list_cursor+1
        bne _moved
_up     lda list_cursor         ; up: not before the first
        ora list_cursor+1
        beq _done
        lda list_cursor
        bne +
        dec list_cursor+1
+       dec list_cursor
_moved  jsr list_max            ; (a field the row hasn't: its last)
        cmp list_field
        bcs +
        sta list_field
+       lda list_cursor         ; off the page?
        and #$100-LIST_ROWS
        cmp list_top
        bne _page
        lda list_cursor+1
        cmp list_top+1
        beq _done
_page   jsr list_page        ; (every row drawn again; the old cursor still put back
        jsr grid_all_rows       ; with the new one: two cursors for ~6 frames until its
                                ; row came, flash_check.py)
_done   jsr list_cursor_screen  ; on the old cursor's row still: drawn whole
        cpx song_old_row
        bne +
        lda #$ff
        sta song_old_row
+       jmp song_urgent_cursor

; list_at_end - list_count, list_idx = the cursor: Z set if it is on the
; END row. keeps X
list_at_end
        lda list_cursor
        sta list_idx
        lda list_cursor+1
        sta list_idx+1
        jsr list_count
        lda list_cursor
        cmp list_n
        bne +
        lda list_cursor+1
        cmp list_n+1
+       rts

; list_ptr - grid_ptr = the record list_idx (GRID_TABLE + list_idx * 8).
; clobbers A; keeps X, Y
list_ptr
        lda list_idx
        sta grid_ptr
        lda list_idx+1
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

; list_count - list_n = the events up to the pattern's length (the steps'
; index at its end: those past a shortened end aren't shown). keeps X
list_count
        ldy grid_steps
        lda GRID_STEP_LO,y
        sta list_n
        lda GRID_STEP_HI,y
        sta list_n+1
        rts

; list_page - the cursor's page shown. clobbers A
list_page
        lda list_cursor
        and #$100-LIST_ROWS
        sta list_top
        lda list_cursor+1
        sta list_top+1
        rts

; -----------------------------------------------------------------------------
; list_cursor_screen - (song.asm song_cursor_screen, in grid_cursor_screen's
; place) X = the cursor's row; carry clear (always shown: the page follows
; the cursor). The step grid: grid_cursor_screen. clobbers A
; -----------------------------------------------------------------------------
list_cursor_screen
        lda grid_view
        bne +
        jmp grid_cursor_screen
+       lda list_cursor
        sec
        sbc list_top
        clc
        adc #GRID_STEP_ROW
        tax
        clc
        rts

        .send
        .section late_code      ; (resident: the hooks, in every mode)
; -----------------------------------------------------------------------------
; list_midi_on, list_midi_off - (hooks.asm note_on, note_off, in
; grid_midi_on's and grid_midi_off's place) step entry on the step grid
; only: nothing on the list.
; -----------------------------------------------------------------------------
list_midi_on
        ldy grid_view
        bne +
        jmp grid_midi_on
+       rts
list_midi_off
        ldy grid_view
        bne +
        jmp grid_midi_off
+       rts

        .send
        .section hi3_code       ; (under the KERNAL at $E800: sid500.asm HI3_CODE, put back by
                                ; hi3_in after the disk overlay was loaded over it)

; -----------------------------------------------------------------------------
; list_prepare - (song.asm song_prepare_base, MODE_GRID, in grid_prepare's
; place) row X prepared aside: the list's title, header, events, help;
; else blank. The step grid: grid_prepare.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
list_prepare
        lda grid_view
        bne +
        jmp grid_prepare
+       lda #LINE_OTHER
        sta song_line_kind
        cpx #SONG_TITLE_ROW
        bne +
        jsr grid_title_line     ; (its steps' place: "LIST")
        ldx #6
-       lda list_title_text,x
        sta song_line+GRID_TITLE_FIRST,x
        dex
        bpl -
        rts
+       cpx #SONG_HEAD_ROW
        bne +
        lda #COL_LABEL
        ldx #<list_head_text
        ldy #>list_head_text
        jmp line_text
+       cpx #GRID_HELP_ROW
        bne +
        jsr grid_help_line      ; (F3's other view: "GRID")
        ldx #3
-       lda list_grid_text,x
        sta song_line+LIST_VIEW_COL,x
        dex
        bpl -
        rts
+       cpx #GRID_KEYS_ROW
        bne +
        lda #COL_LABEL
        ldx #<list_keys_text
        ldy #>list_keys_text
        jmp line_text
+       cpx #GRID_STEP_ROW
        bcc _blank
        cpx #GRID_STEP_ROW+LIST_ROWS
        bcc +
_blank  jmp song_blank_line
+       stx list_k              ; (an event's row, or past the END row: blank)
        jmp list_row

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; io_copy_all - (synth_init, first, in io_copy's place) the tables under I/O
; (io_copy), then the code under the KERNAL and in low RAM (sid500.asm
; HI_CODE, LO_CODE, LO2_CODE, LO3_CODE) from their images. clobbers A, X, Y
; -----------------------------------------------------------------------------
io_copy_all
        jsr io_copy
        ldx #hi_image_end - hi_image
-       lda hi_image-1,x
        sta HI_CODE-1,x
        dex
        bne -
        ldx #lo_image_end - lo_image
-       lda lo_image-1,x
        sta LO_CODE-1,x
        dex
        bne -
        ldx #lo2_image_end - lo2_image
-       lda lo2_image-1,x
        sta LO2_CODE-1,x
        dex
        bne -
        ldx #lo3_image_end - lo3_image
-       lda lo3_image-1,x
        sta LO3_CODE-1,x
        dex
        bne -
        jsr names_init          ; (names.asm: no channel a family synth's)
        jmp locate_init         ; (locate.asm: no locate, no song position)
        .send
        .cerror hi_image_end - hi_image > 255 || hi_image_end == hi_image, "io_copy_all: 1-255 bytes"
        .cerror lo_image_end - lo_image > 255 || lo_image_end == lo_image, "io_copy_all: 1-255 bytes"
        .cerror lo2_image_end == lo2_image || lo3_image_end == lo3_image, "io_copy_all: 1-255 bytes"

; -----------------------------------------------------------------------------
; list_row, list_from_grid, list_to_grid, list_max, list_place - the
; routines under I/O (list_row_io ...) run with I/O out; A as they leave
; it. clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
list_row
        ldx #<list_row_io
        ldy #>list_row_io
        bne list_io
list_from_grid
        ldx #<list_from_grid_io
        ldy #>list_from_grid_io
        bne list_io
list_max
        ldx #<list_max_io
        ldy #>list_max_io
        bne list_io
list_place
        ldx #<list_place_io
        ldy #>list_place_io
        bne list_io
list_to_grid
        ldx #<list_to_grid_io
        ldy #>list_to_grid_io
list_io stx _call+1
        sty _call+2
        lda #RAM_ALL
        sta $01
_call   jsr $ffff               ; (self-modified: the routine)
        ldx #RAM_IO             ; (A kept: list_max's, list_place's)
        stx $01
        rts

        .send

; =============================================================================
; Under I/O (io_data: run with $01 = RAM_ALL, through list_io). Nothing here
; reaches I/O: no line_text (it puts I/O back), no drawing, no timer; only
; RAM and main-RAM routines that touch nothing else (song_num2, song_num3,
; sig_beats, step_tick, div12, edit_find, list_count, list_at_end,
; list_ptr, list_div, list_page, song_blank_line; names.asm name_note,
; name_cc).
; =============================================================================
        .section io_data

; list_max_io - (list_max) A = the cursor's row's last field: a note 3, another event 1,
; the END row 0. clobbers A, Y, grid_ptr; keeps X
list_max_io
        jsr list_at_end
        beq _end
        jsr list_ptr
        ldy #REC_TYPE
        lda (grid_ptr),y
        beq _note
        lda #1
        rts
_note   lda #3
        rts
_end    lda #0
        rts

; list_place_io - (list_place) A = where the cursor's field's 3 reversed characters start
; (the value's: a note's name, else the value's last 3; the END row: its
; position's). clobbers A, Y, grid_ptr; keeps X
list_place_io
        jsr list_at_end
        beq _pos                ; (the END row: its position only)
        ldy list_field
        cpy #1
        bne _fixed
        jsr list_ptr
        ldy #REC_TYPE
        lda (grid_ptr),y
        ldy #1
        cmp #TYPE_NOTE
        beq _fixed
        lda #LIST_VALUE_END-2
        rts
_pos    ldy #0
_fixed  lda list_places,y
        rts
list_places     .byte LIST_POS+5, LIST_EVENT, LIST_VEL, LIST_LEN+5

; -----------------------------------------------------------------------------
; list_from_grid_io - (list_from_grid) the list's cursor from the step
; grid's: the cursor's column's note (edit.asm edit_find: the step's n-th
; note), its note field; else the step's first event (the first at or
; after its start: the END row if none is), its position; its page.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
list_from_grid_io
        lda grid_col
        sta edit_col
        jsr edit_find
        ldx #1                  ; (the note's field)
        bcc +
        ldx grid_cursor         ; none: the step's first event
        lda GRID_STEP_LO,x
        sta edit_at
        lda GRID_STEP_HI,x
        sta edit_at+1
        ldx #0
+       stx list_field
        lda edit_at
        sta list_cursor
        lda edit_at+1
        sta list_cursor+1
        jmp list_page

; -----------------------------------------------------------------------------
; list_to_grid_io - (list_to_grid) the step grid's cursor from the list's:
; the event's step (the END row: the last step), the column whose note it
; is (edit_find; not a note, or past the columns: the first); its page.
; clobbers A, X, Y, grid_ptr
; -----------------------------------------------------------------------------
list_to_grid_io
        lda #0
        sta grid_col
        ldx grid_steps
        dex
        stx grid_cursor         ; (the END row: the last step)
        jsr list_at_end
        beq _page
        jsr list_ptr            ; the event's step: its tick / 12
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        sta div_lo
        iny
        lda (grid_ptr),y
        sta div_hi
        jsr div12
        lda div_lo
        cmp grid_steps          ; (within the length: always; kept so)
        bcs _page
        sta grid_cursor
-       lda grid_col            ; the column whose note it is
        sta edit_col
        jsr edit_find
        bcs _first              ; (no more notes)
        lda edit_at
        cmp list_cursor
        bne +
        lda edit_at+1
        cmp list_cursor+1
        beq _page
+       inc grid_col
        lda grid_col
        cmp #GRID_COLS
        bcc -
_first  lda #0
        sta grid_col
_page   lda grid_cursor
        and #$100-GRID_STEPS
        sta grid_top
        rts

; list_row_io - (list_row: with I/O out) screen row list_k's event's row
; prepared (the END row's after the last; past it blank).
; clobbers A, X, Y, grid_ptr
list_row_io
        lda list_k              ; the row's event
        sec
        sbc #GRID_STEP_ROW
        clc
        adc list_top
        sta list_idx
        lda list_top+1
        adc #0
        sta list_idx+1
        jsr list_count          ; past the END row: blank
        lda list_n
        cmp list_idx
        lda list_n+1
        sbc list_idx+1
        bcs +
        jmp song_blank_line
+
        ldy #9                  ; blank, the track's colour (4 places a pass: ~500
-       lda #CHAR_SPACE         ; cycles; a place a pass took ~1,100)
        sta song_line,y
        sta song_line+10,y
        sta song_line+20,y
        sta song_line+30,y
        lda grid_colour
        sta song_line_col,y
        sta song_line_col+10,y
        sta song_line_col+20,y
        sta song_line_col+30,y
        dey
        bpl -
        lda #COL_LABEL          ; the position grey
        ldy #LIST_EVENT-1
-       sta song_line_col,y
        dey
        bpl -
        ldx play_scene          ; the playing scene's signature
        jsr sig_beats
        sta list_beats
        stx list_beat_ticks
        lda #1                  ; (a position: from bar 1, beat 1)
        sta list_base
        lda list_idx            ; the END row?
        cmp list_n
        bne _event
        lda list_idx+1
        cmp list_n+1
        bne _event
        ldx grid_steps          ; the END row: the pattern's length as its position,
        jsr step_tick           ; "END", grey
        lda step_lo
        sta div_lo
        lda step_hi
        sta div_hi
        ldy #LIST_POS
        jsr list_pos
        ldx #2
-       lda list_end_text,x
        sta song_line+LIST_EVENT,x
        lda #COL_LABEL
        sta song_line_col+LIST_EVENT,x
        dex
        bpl -
        jmp _cursor
_event  jsr list_ptr            ; the position
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        sta div_lo
        iny
        lda (grid_ptr),y
        sta div_hi
        ldy #LIST_POS
        jsr list_pos
        ldy #REC_TYPE           ; the event
        lda (grid_ptr),y
        bne _other
        ; a note: its name, velocity, length (from 0)
        ldy #REC_D1
        lda (grid_ptr),y
        ldy #LIST_EVENT
        jsr name_note           ; (names.asm: a drum's name, or the pitch)
        ldy #REC_VEL
        lda (grid_ptr),y
        ldy #LIST_VEL
        jsr song_num3
        ldy #REC_LEN_LO
        lda (grid_ptr),y
        sta div_lo
        iny
        lda (grid_ptr),y
        sta div_hi
        lda #0
        sta list_base
        ldy #LIST_LEN
        jsr list_pos
        jmp _cursor
_other  asl                     ; its kind's name: (type - 1) * 4
        asl
        tax
        ldy #0
-       lda list_kind_text-4,x
        sta song_line+LIST_EVENT,y
        inx
        iny
        cpy #4
        bne -
        ldy #REC_TYPE
        lda (grid_ptr),y
        cmp #TYPE_BEND
        bne +
        jsr list_bend           ; bend: signed, -8192 to 8191
        jmp _cursor
+       ldy #REC_D1
        cmp #TYPE_CC
        bne +
        lda (grid_ptr),y        ; a controller: its family name (names.asm), else its
        jsr name_cc             ; number; its value
        bcc _named
        ldy #REC_D1
        lda (grid_ptr),y
        ldy #LIST_CC_NUM
        jsr song_num3
_named  ldy #REC_D2
        lda (grid_ptr),y
        jmp ++
+       lda (grid_ptr),y        ; a program: 1-128
        clc
        adc #1
+       ldy #LIST_VALUE_END-2
        jsr song_num3
_cursor lda list_idx            ; the cursor's row: its field reversed
        cmp list_cursor
        bne +
        lda list_idx+1
        cmp list_cursor+1
        bne +
        jsr list_place_io       ; (here under I/O: not the stub)
        tay
        ldx #3
-       lda song_line,y
        ora #CHAR_REVERSE
        sta song_line,y
        iny
        dex
        bne -
+       rts


; -----------------------------------------------------------------------------
; list_pos - div_lo/hi ticks as bar.beat.tick in the 8 places from
; song_line + Y, right-aligned: from bar 1 and beat 1 with list_base 1 (a
; position), from 0 with 0 (a length); bars over 99 shown as 99. The
; signature in list_beats, list_beat_ticks.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
list_pos
        sty list_y
        lda list_beat_ticks
        jsr list_div            ; the beats, the ticks over
        sta list_ticks
        lda list_beats
        jsr list_div            ; the bars, the beat in the bar
        clc
        adc list_base
        sta list_beat
        lda div_hi
        bne _99
        lda div_lo
        clc
        adc list_base
        cmp #100
        bcc +
_99     lda #99
+       ldy list_y              ; a beat of one digit: the bar a place on
        ldx list_beat
        cpx #10
        bcs +
        iny
+       jsr song_num2           ; the bar, a leading zero a space
        lda song_line,y
        cmp #CHAR_DIGIT0
        bne +
        lda #CHAR_SPACE
        sta song_line,y
+       iny
        iny
        lda #CHAR_DOT
        sta song_line,y
        iny
        lda list_beat           ; the beat
        cmp #10
        bcc +
        jsr song_num2
        iny
        bne ++
+       ora #CHAR_DIGIT0
        sta song_line,y
+       iny
        lda #CHAR_DOT
        sta song_line,y
        iny
        lda list_ticks          ; the ticks, 2 digits
        jmp song_num2

; -----------------------------------------------------------------------------
; list_bend - the bend at grid_ptr as its value less 8192 (-8192 to 8191),
; right-aligned to LIST_VALUE_END, the sign before its first digit (the
; digits from the last: list_div by 10).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
list_bend
        ldy #REC_D2             ; the value: high 7 bits, low 7 bits
        lda (grid_ptr),y
        lsr
        sta div_hi
        lda #0
        ror
        ldy #REC_D1
        ora (grid_ptr),y
        sta div_lo
        ldx #CHAR_SPACE
        lda div_hi              ; less 8192 ($2000): negative, made positive
        sec
        sbc #$20
        sta div_hi
        bcs +
        lda #0
        sec
        sbc div_lo
        sta div_lo
        lda #0
        sbc div_hi
        sta div_hi
        ldx #CHAR_MINUS
+       stx list_sign
        ldy #LIST_VALUE_END
-       lda #10                 ; a digit, from the last
        jsr list_div
        ora #CHAR_DIGIT0
        sta song_line,y
        dey
        lda div_lo
        ora div_hi
        bne -
        lda list_sign
        sta song_line,y
        rts

        .enc "screen"
list_end_text   .text "END"
list_kind_text  .text "CC  BENDPROG"    ; TYPE_CC, TYPE_BEND, TYPE_PROGRAM
        .cerror TYPE_CC != 1 || TYPE_BEND != 2 || TYPE_PROGRAM != 3, "list_kind_text"
list_head_text  .text "POSITION EVENT    VALUE VEL   LENGTH    "
        .cerror * - list_head_text != 40, "the list's header is a row"
list_keys_text  .text "CRSR MOVE  +- CHANGE  INST COPY  DEL CUT"
        .cerror * - list_keys_text != 40, "the list's keys' help is a row"
        .enc "none"
        .send
.else
list_key        = grid_key      ; (no LIST_CODE: the hooks to the step grid's own routines)
list_cursor_screen = grid_cursor_screen
list_prepare    = grid_prepare
list_midi_on    = grid_midi_on
list_midi_off   = grid_midi_off
list_pair_safe  = song_row_safe
        .section late_code
        .section init_code      ; (start-up only: run once from INIT_CODE)
; io_copy_all - (no LIST_CODE) the tables under I/O, the code under the KERNAL
io_copy_all
        jsr io_copy
        ldx #hi_image_end - hi_image
-       lda hi_image-1,x
        sta HI_CODE-1,x
        dex
        bne -
        jmp locate_init         ; (locate.asm: no locate, no song position)
        .send
        .send
.endif
