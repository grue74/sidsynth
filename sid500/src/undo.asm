; undo.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Undo and redo on the step grid (C= U, C= SHIFT U; docs/design.md section
; 5, "Undo"). SID303 copies a whole pattern into a ring of pages before
; an edit; a SID500 pattern's edit table is up to 3 KB, so each edit is
; kept instead as what it changed (edit.asm and grid.asm call undo_save):
;
; - UNDO_INSERT: a record put in at its index (the record kept);
; - UNDO_DELETE: a record taken out (the record kept);
; - UNDO_RANGE: records changed in place (their other version kept:
;   undo and redo swap it with the table's, so it is the same both ways);
; - UNDO_TRANSPOSE: the pattern transposed (the semitones);
; - UNDO_LENGTH: the pattern's length changed (the other length: swapped);
; - UNDO_CUT: records taken out from its index to the table's end (CLR:
;   kept last first, so each goes back at the table's end; the steps'
;   index then found again).
;
; A key's edits are one group (its first entry flagged UNDO_FIRST): a note
; replacing one off its step is a delete and an insert, undone together.
; The entries are kept one after another in UNDO_RAM, each with its length
; at both ends (walked back by undo, on by redo); undo_now is where the
; next one goes, undo_top the end of those that can be redone. A new edit
; drops what could be redone; when one doesn't fit, the oldest groups go.
; The history is the open pattern's: opening another clears it. Settings
; (the entry velocity and length, the octave, what C= + / - change) are
; not edits: not undone (as SID303).

UNDO_RAM        = $c500         ; the entries (free in the core's map until stage G's disk
UNDO_SIZE       = $300          ; code: design 3), 768 bytes: ~50 note edits
        .cerror KERNAL_ZP_COPY >= UNDO_RAM - $ff && KERNAL_ZP_COPY < UNDO_RAM + UNDO_SIZE, "KERNAL_ZP_COPY over the undo entries"
        .cerror UNDO_RAM + UNDO_SIZE > PAT_FIRST_LO, "the undo entries run into the song data"
UNDO_INSERT     = 1             ; an entry's kinds (its second byte, + UNDO_FIRST)
UNDO_DELETE     = 2
UNDO_RANGE      = 3
UNDO_TRANSPOSE  = 4
UNDO_LENGTH     = 5
UNDO_CUT        = 6
UNDO_FIRST      = $80           ;   the first entry of a key's edits
UNDO_HEAD       = 5             ; an entry: its length, kind, index (2), records n (or the
                                ; semitones, the other length in the index's low byte),
                                ; n records, its length again
UNDO_MAX_RECS   = (255 - UNDO_HEAD - 1) / REC_SIZE ; records an entry can keep (31): more
                                ; (a quantized step that full) clears the history
UNDO_CLEAR_MAX  = 93            ; a CLR kept for undo: at most these records (entries of
                                ; UNDO_MAX_RECS; more ask first, then clear the history)
        .cerror (UNDO_CLEAR_MAX + UNDO_MAX_RECS - 1) / UNDO_MAX_RECS * (UNDO_HEAD + 1) + UNDO_CLEAR_MAX * REC_SIZE > UNDO_SIZE, "UNDO_CLEAR_MAX: a CLR's entries don't fit"
        .cerror (UNDO_CLEAR_MAX + UNDO_MAX_RECS) / UNDO_MAX_RECS * (UNDO_HEAD + 1) + (UNDO_CLEAR_MAX + 1) * REC_SIZE <= UNDO_SIZE, "UNDO_CLEAR_MAX: one more would fit"

        .section edit_vars
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
undo_now        .word ?         ; where the next entry goes (the end of those to undo)
        .send
undo_top        .word ?         ; the end of those that can be redone
undo_first      .byte ?         ; UNDO_FIRST: the next entry begins a key's edits
undo_kind       .byte ?         ; undo_save's scratch: the entry's kind
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
undo_n          .byte ?         ;   its records
        .send
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
undo_len        .byte ?         ;   its length
        .send
undo_at         .word ?         ; the entry being undone or redone: its start
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
undo_cut        .word ?         ; undo_room: the oldest groups' length
        .send
undo_changed    .byte ?         ; nonzero: a record entry undone or redone (the cursor
                                ; to its step)
undo_saved      .byte ?         ; nonzero: undo_save kept the last edit (undo_unsave may
                                ; drop it)
undo_busy       .byte ?         ; nonzero: undoing or redoing (edit_transpose saves none)
undo_all        .byte ?         ; nonzero: a transpose or length undone or redone (every
                                ; row drawn again; else only the step's)
undo_reindex    .byte ?         ; nonzero: a CLR undone or redone (the steps' index found
                                ; again)
        .send

; -----------------------------------------------------------------------------
; undo_clear - nothing to undo or redo (start-up, another pattern opened).
; clobbers A
; -----------------------------------------------------------------------------
undo_clear
        lda #0
        sta undo_now
        sta undo_now+1
        sta undo_top
        sta undo_top+1
        lda #UNDO_FIRST
        sta undo_first
        rts

; -----------------------------------------------------------------------------
; undo_key - (grid_key, every key) the next entry begins a new group.
; clobbers nothing but the flags
; -----------------------------------------------------------------------------
undo_key
        pha
        lda #UNDO_FIRST
        sta undo_first
        pla
        rts

; -----------------------------------------------------------------------------
; undo_ptr - ptr = UNDO_RAM + A (low) and X (high). keeps A, X, Y
; -----------------------------------------------------------------------------
undo_ptr
        pha
        clc
        adc #<UNDO_RAM
        sta ptr
        txa
        adc #>UNDO_RAM
        sta ptr+1
        pla
        rts

; -----------------------------------------------------------------------------
; undo_save - (before an edit changes the table, or after a record is put
; in) an entry: kind A, X records from index edit_at (kept as they are
; now; X = 0: none, edit_at's low byte the entry's datum). Drops what
; could be redone, and the oldest groups if it doesn't fit; more records
; than an entry keeps clears the history (that edit can't be undone).
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
undo_save
        sta undo_kind
        stx undo_n
        lda #0
        sta undo_saved
        cpx #UNDO_MAX_RECS+1
        bcs undo_clear
+       inc undo_saved
        txa                     ; the length: UNDO_HEAD + n * 8 + 1
        asl
        asl
        asl
        clc
        adc #UNDO_HEAD+1
        sta undo_len
        lda undo_now            ; what could be redone: dropped
        sta undo_top
        lda undo_now+1
        sta undo_top+1
        jsr undo_room
        ; the head
        lda undo_now
        ldx undo_now+1
        jsr undo_ptr
        ldy #0
        lda undo_len
        sta (ptr),y
        iny
        lda undo_kind
        ora undo_first
        sta (ptr),y
        iny
        lda edit_at
        sta (ptr),y
        iny
        lda edit_at+1
        sta (ptr),y
        iny
        lda undo_n
        sta (ptr),y
        ; the records, as they are now
        beq _end
        jsr edit_record_ptr
        lda undo_n
        asl
        asl
        asl
        tax                     ; (bytes to copy)
        lda ptr                 ; ptr past the head
        clc
        adc #UNDO_HEAD
        sta ptr
        bcc +
        inc ptr+1
+       ldy #0
-       lda (grid_ptr),y
        sta (ptr),y
        iny
        dex
        bne -
        lda undo_now            ; (ptr back at the entry's start)
        ldx undo_now+1
        jsr undo_ptr
        ; its length again, at its end; then the next one's place
_end    ldy undo_len
        dey
        lda undo_len
        sta (ptr),y
        clc
        adc undo_now
        sta undo_now
        sta undo_top
        bcc +
        inc undo_now+1
+       lda undo_now+1
        sta undo_top+1
        lda #0
        sta undo_first
        rts

; undo_unsave - (an edit that changed nothing after all) its entry
; dropped, if undo_save kept it: the last one. clobbers A, X, Y, ptr
undo_unsave
        lda undo_saved
        bne +
        rts
+       lda undo_now
        ldx undo_now+1
        jsr undo_ptr
        ldy #0                  ; (ptr - 1: its length, read as ptr's page - 1 + $FF)
        lda ptr
        bne +
        dec ptr+1
+       dec ptr
        lda (ptr),y
        sta undo_len
        ldy #1                  ; was it a group's first? then the next one is again
        sec
        lda undo_now
        sbc undo_len
        sta undo_now
        sta undo_top
        lda undo_now+1
        sbc #0
        sta undo_now+1
        sta undo_top+1
        lda undo_now
        ldx undo_now+1
        jsr undo_ptr
        lda (ptr),y
        and #UNDO_FIRST
        sta undo_first
        rts

; undo_room - room for undo_len bytes at undo_now: the oldest groups
; dropped (the rest moved down, a byte at a time through absolute
; operands: ~30 cycles a byte, rare) until it fits.
; clobbers A, X, Y, ptr
undo_room
_check  lda undo_now            ; undo_now + undo_len <= UNDO_SIZE?
        clc
        adc undo_len
        tax
        lda undo_now+1
        adc #0
        cmp #>UNDO_SIZE
        bcc _fit
        bne _drop
        cpx #<UNDO_SIZE+1
        bcs _drop
_fit    rts
        ; the oldest group's length: entries from the start until the
        ; next one that begins a group (or the end)
_drop   lda #0
        sta undo_cut
        sta undo_cut+1
-       lda undo_cut
        ldx undo_cut+1
        jsr undo_ptr
        ldy #0
        lda (ptr),y             ; (this entry's length)
        clc
        adc undo_cut
        sta undo_cut
        bcc +
        inc undo_cut+1
+       lda undo_cut            ; at the end?
        cmp undo_now
        lda undo_cut+1
        sbc undo_now+1
        bcs _all
        lda undo_cut            ; the next one begins a group?
        ldx undo_cut+1
        jsr undo_ptr
        ldy #1
        lda (ptr),y
        bpl -
        ; the rest moved down by undo_cut
        lda #<UNDO_RAM
        sta _to+1
        lda #>UNDO_RAM
        sta _to+2
        lda undo_cut
        ldx undo_cut+1
        jsr undo_ptr
        lda ptr
        sta _from+1
        lda ptr+1
        sta _from+2
        sec                     ; bytes: undo_now - undo_cut
        lda undo_now
        sbc undo_cut
        sta undo_now
        lda undo_now+1
        sbc undo_cut+1
        sta undo_now+1
        tay                     ; (Y, X: the count's high, low; at least 1)
        ldx undo_now
_from   lda $ffff               ; (self-modified: the source)
_to     sta $ffff               ;   and the destination
        inc _from+1
        bne +
        inc _from+2
+       inc _to+1
        bne +
        inc _to+2
+       dex                     ; the count down
        cpx #$ff
        bne +
        dey
+       txa
        bne _from
        tya
        bne _from
        lda undo_now
        sta undo_top
        lda undo_now+1
        sta undo_top+1
        jmp _check
        ; nothing left to drop (can't be: an entry is at most 255)
_all    jsr undo_clear
_fits   rts

; -----------------------------------------------------------------------------
; undo_undo - (C= U) the last key's edits undone, its entries' last first.
; Carry set: nothing to undo (or the table not whole).
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
undo_undo
        lda edit_whole
        beq _no
        lda undo_now
        ora undo_now+1
        beq _no
        jsr grid_mark_old       ; (the cursor as shown: put back with the new one)
        lda #0
        sta undo_changed
        sta undo_all
        sta undo_reindex
_entry  lda undo_now            ; the entry ending at undo_now: its length at its end
        ldx undo_now+1
        jsr undo_ptr
        lda ptr
        bne +
        dec ptr+1
+       dec ptr
        ldy #0
        lda (ptr),y
        sta undo_len
        sec
        lda undo_now
        sbc undo_len
        sta undo_now
        sta undo_at
        lda undo_now+1
        sbc #0
        sta undo_now+1
        sta undo_at+1
        lda #$ff                ; (backwards)
        jsr undo_apply
        lda undo_at             ; its group's first? done
        ldx undo_at+1
        jsr undo_ptr
        ldy #1
        lda (ptr),y
        bmi _done
        lda undo_now
        ora undo_now+1
        bne _entry
_done   jmp undo_done
_no     sec
        rts

; -----------------------------------------------------------------------------
; undo_redo - (C= SHIFT U) the next key's edits made again, first first.
; Carry set: nothing to redo.
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
undo_redo
        lda edit_whole
        beq _no
        lda undo_now
        cmp undo_top
        bne +
        lda undo_now+1
        cmp undo_top+1
        beq _no
+       jsr grid_mark_old       ; (the cursor as shown: put back with the new one)
        lda #0
        sta undo_changed
        sta undo_all
        sta undo_reindex
_entry  lda undo_now
        sta undo_at
        ldx undo_now+1
        stx undo_at+1
        jsr undo_ptr
        ldy #0
        lda (ptr),y
        sta undo_len
        lda #1                  ; (forwards)
        jsr undo_apply
        lda undo_at             ; on past it
        clc
        adc undo_len
        sta undo_now
        lda undo_at+1
        adc #0
        sta undo_now+1
        cmp undo_top+1          ; the end, or a group's first next: done
        bne +
        lda undo_now
        cmp undo_top
        beq _done
+       lda undo_now
        ldx undo_now+1
        jsr undo_ptr
        ldy #1
        lda (ptr),y
        bpl _entry
_done   jmp undo_done
_no     sec
        rts

; undo_done - (undo, redo) the table to publish; the cursor on the step a
; record changed (its page shown), within the length; that step's row
; drawn now (a key's edits change one step), or every row again after a
; transpose or a length, or on another page. Carry clear.
; clobbers A, X, Y
undo_done
        jsr edit_touch
        lda undo_reindex        ; a CLR's: each step's first event found again
        beq +
        jsr undo_index_all
+
        lda undo_changed
        beq +
        lda div_lo              ; (undo_apply: the record's step)
        sta grid_cursor
+       lda grid_cursor         ; within the length
        cmp grid_steps
        bcc +
        ldx grid_steps
        dex
        stx grid_cursor
+       lda grid_cursor         ; its page: another one shown whole
        and #$ff-(GRID_STEPS-1)
        cmp grid_top
        beq +
        sta grid_top
        lda #$ff
        sta song_old_row
        sta undo_all
+       jsr grid_cursor_screen  ; (on the old cursor's row still: drawn whole)
        cpx song_old_row
        bne +
        lda #$ff
        sta song_old_row
+       lda undo_all
        beq +
        jsr song_dirty_grid     ; every row again, the cursor's first (the title
        ldx #SONG_TITLE_ROW     ; only dirty: two urgent rows took past a frame)
        jsr song_dirty_row
+       jsr song_urgent_cursor
        clc
        rts

; -----------------------------------------------------------------------------
; undo_apply - the entry at undo_at undone (A = $FF) or made again (A = 1).
; An insert undone and a delete made again take the record out; the other
; way round put it back; changed records and the length are swapped (the
; same both ways); a transpose goes the other way undone. A record's step
; in div_lo (undo_changed set).
; clobbers A, X, Y, ptr, grid_ptr
; -----------------------------------------------------------------------------
undo_apply
        sta edit_dir
        lda undo_at
        ldx undo_at+1
        jsr undo_ptr
        ldy #2                  ; the index
        lda (ptr),y
        sta edit_at
        iny
        lda (ptr),y
        sta edit_at+1
        iny
        lda (ptr),y
        sta undo_n
        dey
        dey
        dey
        lda (ptr),y             ; the kind
        and #$ff-UNDO_FIRST
        cmp #UNDO_TRANSPOSE
        bne +
        jmp _transpose
+       cmp #UNDO_LENGTH
        bne +
        jmp _length
+       cmp #UNDO_RANGE
        beq _range
+       cmp #UNDO_CUT
        beq _cut
+
        ; an insert or a delete: in (an insert again, a delete undone) or out
        cmp #UNDO_INSERT
        bne _delete
        lda edit_dir
        bpl _put_in
        bmi _take_out
_delete lda edit_dir
        bpl _take_out
        bmi _put_in
        ; the record taken out (the cursor on its step first: edit_delete
        ; counts the steps' index after the cursor's step)
_take_out
        jsr edit_record_ptr
        jsr undo_step_of_table
        jmp edit_delete
_put_in jsr undo_step_of_entry
        jsr edit_insert
        jsr edit_record_ptr
        ldy #REC_SIZE-1         ; the record's bytes from the entry
-       tya
        clc
        adc #UNDO_HEAD
        sty edit_hi_tmp
        tay
        lda (ptr),y
        ldy edit_hi_tmp
        sta (grid_ptr),y
        dey
        bpl -
        rts
        ; records swapped with the entry's
_range  jsr edit_record_ptr
        jsr undo_step_of_table
        lda undo_n
        asl
        asl
        asl
        tax
        lda ptr
        clc
        adc #UNDO_HEAD
        sta ptr
        bcc +
        inc ptr+1
+       ldy #0
-       lda (grid_ptr),y
        pha
        lda (ptr),y
        sta (grid_ptr),y
        pla
        sta (ptr),y
        iny
        dex
        bne -
        rts
        ; records cut from the table's end: put back there (undone) or
        ; cut again; the index found again once all are applied (undo_done)
_cut    inc undo_all
        inc undo_reindex
        lda edit_dir
        bmi +
        lda edit_at             ; again: the count back to the index
        sta grid_count
        lda edit_at+1
        sta grid_count+1
        rts
+       jsr edit_record_ptr     ; undone: the records from the entry at edit_at (the
        lda undo_n              ; table's end)
        asl
        asl
        asl
        tax                     ; (bytes: at most UNDO_MAX_RECS * 8)
        lda ptr
        clc
        adc #UNDO_HEAD
        sta ptr
        bcc +
        inc ptr+1
+       ldy #0
-       lda (ptr),y
        sta (grid_ptr),y
        iny
        dex
        bne -
        clc
        lda edit_at
        adc undo_n
        sta grid_count
        lda edit_at+1
        adc #0
        sta grid_count+1
        rts
        ; a transpose the other way (undone) or again
_transpose
        lda edit_at             ; (the semitones it went)
        ldx edit_dir
        bpl +
        eor #$ff
        clc
        adc #1
+       sta edit_dir
        inc undo_all
        inc undo_busy           ; (not an edit to keep)
        jsr edit_transpose
        dec undo_busy
        rts
        ; the length swapped with the entry's
_length inc undo_all
        lda grid_steps
        pha
        ldy #2
        sta (ptr),y             ; (the entry now holds this one)
        lda edit_at
        sta undo_n              ; (the length to go to)
        pla
        cmp undo_n
        bcs _shorter
-       jsr grid_index_next     ; longer: each step's first event found
        inc grid_steps
        lda grid_steps
        cmp undo_n
        bcc -
        rts
_shorter
        lda undo_n
        sta grid_steps
        rts

; undo_index_all - (a CLR undone or redone) each step's first event found
; again, steps 0 to the length's in one pass over the table (~50 cycles a
; record, ~35 a step). clobbers A, X, Y, grid_ptr, edit_at
undo_index_all
        lda #0
        sta edit_at
        sta edit_at+1
        lda #<GRID_TABLE
        sta grid_ptr
        lda #>GRID_TABLE
        sta grid_ptr+1
        ldx #0                  ; (the step)
_record lda edit_at             ; all looked at: the rest of the steps start there
        cmp grid_count
        lda edit_at+1
        sbc grid_count+1
        bcs _found
        jsr step_tick
        ldy #REC_TIME_LO        ; its tick the step's or later: the step's first
        lda (grid_ptr),y
        cmp step_lo
        iny
        lda (grid_ptr),y
        sbc step_hi
        bcs _found
        lda grid_ptr            ; on to the next record
        clc
        adc #REC_SIZE
        sta grid_ptr
        bcc +
        inc grid_ptr+1
+       inc edit_at
        bne _record
        inc edit_at+1
        jmp _record
_found  lda edit_at
        sta GRID_STEP_LO,x
        lda edit_at+1
        sta GRID_STEP_HI,x
        cpx grid_steps
        beq +
        inx
        jmp _record
+       rts

; undo_fit_clear - (edit_clear_all, A records to keep) the history cleared
; if it and a CLR's entries (A records in entries of UNDO_MAX_RECS) won't
; both fit. keeps A; clobbers X, Y
undo_fit_clear
        pha
        sta undo_n              ; the entries' bytes: records * 8 + entries * 6
        lda #0
        sta undo_cut+1
        lda undo_n
        asl
        rol undo_cut+1
        asl
        rol undo_cut+1
        asl
        rol undo_cut+1
        sta undo_cut
        ldx undo_n
-       lda undo_cut            ; (an entry's head and end for each UNDO_MAX_RECS)
        clc
        adc #UNDO_HEAD+1
        sta undo_cut
        bcc +
        inc undo_cut+1
+       txa
        sec
        sbc #UNDO_MAX_RECS
        tax
        beq +
        bcs -
+       clc                     ; with the history: over UNDO_SIZE?
        lda undo_cut
        adc undo_now
        tax
        lda undo_cut+1
        adc undo_now+1
        cmp #>UNDO_SIZE
        bcc _fits
        bne _clear
        cpx #<UNDO_SIZE+1
        bcc _fits
_clear  jsr undo_clear
_fits   pla
        rts

; undo_step_of_table / undo_step_of_entry - the cursor on the step of the
; record at grid_ptr / kept in the entry at ptr (its tick / 12; div_lo,
; undo_changed set). clobbers A, X, Y
undo_step_of_table
        ldy #REC_TIME_LO
        lda (grid_ptr),y
        sta div_lo
        iny
        lda (grid_ptr),y
        jmp +
undo_step_of_entry
        ldy #UNDO_HEAD+REC_TIME_LO
        lda (ptr),y
        sta div_lo
        iny
        lda (ptr),y
+       sta div_hi
        jsr div12
        lda div_lo
        sta grid_cursor
        lda #1
        sta undo_changed
        rts
