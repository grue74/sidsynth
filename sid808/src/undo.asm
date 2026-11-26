; undo.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Undo and redo for the step grid (U, SHIFT+U): the last UNDO_STEPS edits.
; Before an edit changes a pattern (a cell, the length, clear, the pattern
; copy writes over) or the song (put, repeats, delete), undo_save copies
; what it changes into the next slot of a ring of pages. Undo steps back
; one slot and swaps it with the data, so the slot then holds the state
; after the edit: redo swaps it back. A new edit drops the steps that could
; be redone. Live record saves once per pass of a pattern (rec_write), so
; undo takes back a whole recorded pass. A load from disk clears it all
; (undo_clear). Mutes, tempo and swing are settings, not edits: not undone.

        .weak
UNDO_STEPS      = 12            ; undo steps (12: SysEx dumps took the room of 4 more);
                                ; a build whose program reaches the pages takes fewer
        .endweak
UNDO_RAM        = PATTERN_RAM - UNDO_STEPS * 256 ; a page per step, under the patterns
UNDO_SONG       = $80           ; undo_what: the song block (else a pattern number)
        .cerror SONG_END - song_pat > 256, "the song block must fit an undo page"

; RAM (zero page is full)
undo_what       = $c6c0         ; UNDO_STEPS: what each slot holds (pattern 0..63, UNDO_SONG)
undo_pos        = undo_what + UNDO_STEPS ; the slot the next edit saves to
undo_count      = undo_pos + 1  ; steps that can be undone (0..UNDO_STEPS)
undo_redo       = undo_count + 1 ; steps that can be redone
rec_undo_pat    = undo_redo + 1 ; live record: the pattern saved in this pass ($FF = none)
rec_undo_pass   = rec_undo_pat + 1 ;           and the pass (seq_pass) it was saved in
seq_pass        = rec_undo_pass + 1 ; +1 at every pattern start and play (sequencer.asm)
cell_new        = seq_pass + 1  ; cell_set: the new cell value
UNDO_VARS_END   = cell_new + 1
        .cerror undo_what < KNOB_RAM_END || UNDO_VARS_END > load_warn, "undo variables overlap the knob RAM or load_warn"

; -----------------------------------------------------------------------------
; undo_clear - nothing to undo or redo (start-up, after a load).
; clobbers A
; -----------------------------------------------------------------------------
undo_clear
        lda #0
        sta undo_pos
        sta undo_count
        sta undo_redo
        lda #$ff
        sta rec_undo_pat        ; live record saves again on its next hit
        rts

; -----------------------------------------------------------------------------
; undo_save - before an edit changes pattern A (0..63) or the song
; (A = UNDO_SONG): save it into the next slot. The oldest step goes when
; all UNDO_STEPS are in use; nothing can be redone after a new edit.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
undo_save
        ldx undo_pos
        sta undo_what,x
        jsr undo_setup          ; Y = the length
-       dey
us_data lda $ffff,y             ; (undo_setup: the data)
us_slot sta $ff00,y             ;            and the slot's page
        tya
        bne -
        lda undo_pos            ; the next slot (round the ring)
        clc
        adc #1
        cmp #UNDO_STEPS
        bcc +
        lda #0
+       sta undo_pos
        lda undo_count
        cmp #UNDO_STEPS
        bcs +
        inc undo_count
+       lda #0
        sta undo_redo
        rts

; -----------------------------------------------------------------------------
; undo_swap - swap slot X with the data it was saved from, then show what
; changed: a pattern on the grid (and next to play, as F1/F2 do), or the
; song with its cursor kept on it. Live record saves afresh after it.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
undo_swap
        jsr undo_setup
-       dey
uw_data1 lda $ffff,y
        pha
uw_slot1 lda $ff00,y
uw_data2 sta $ffff,y
        pla
uw_slot2 sta $ff00,y
        tya
        bne -
        lda #$ff
        sta rec_undo_pat
        lda undo_what,x
        bmi _song
        sta edit_pat            ; the pattern that changed, on the grid
        sta seq_next
        rts
_song   lda song_cur            ; the cursor at most just past the last entry
        cmp song_len
        bcc _done
        beq _done
        lda song_len
        cmp #SONG_MAX
        bcc +
        lda #SONG_MAX-1         ; (a full song: the last entry)
+       sta song_cur
_done   rts

; -----------------------------------------------------------------------------
; undo_setup - point undo_save's and undo_swap's copy loops at slot X's
; page and the data undo_what,x names. Out: Y = the data's length.
; preserves X; clobbers A
; -----------------------------------------------------------------------------
undo_setup
        txa
        clc
        adc #>UNDO_RAM
        sta us_slot+2
        sta uw_slot1+2
        sta uw_slot2+2
        lda undo_what,x
        bmi _song
        clc
        adc #>PATTERN_RAM       ; a pattern: its page, cells and length
        ldy #0
        sty us_data+1
        sty uw_data1+1
        sty uw_data2+1
        ldy #PAT_LENGTH+1
        bne _hi                 ; always
_song   lda #<song_pat          ; the song: entries, repeats, length
        sta us_data+1
        sta uw_data1+1
        sta uw_data2+1
        lda #>song_pat
        ldy #SONG_END-song_pat
_hi     sta us_data+2
        sta uw_data1+2
        sta uw_data2+2
        rts

; -----------------------------------------------------------------------------
; k_undo - U: undo the last edit; SHIFT+U: redo. The song row says what
; happened (until a key).
; -----------------------------------------------------------------------------
k_undo  lda shift_held
        bne _redo
        lda undo_count
        beq _no_undo
        dec undo_count
        inc undo_redo
        lda undo_pos            ; back one slot: the last edit's (round the ring)
        sec
        sbc #1
        bcs +
        lda #UNDO_STEPS-1
+       sta undo_pos
        tax
        jsr undo_swap
        ldx #MSG_UNDO
        lda undo_count
        jmp undo_message
_no_undo
        ldx #MSG_NO_UNDO
        bne undo_message_only   ; always
_redo   lda undo_redo
        beq _no_redo
        dec undo_redo
        inc undo_count
        ldx undo_pos            ; the slot undo left: swap it back
        jsr undo_swap
        lda undo_pos            ; on one slot (round the ring)
        clc
        adc #1
        cmp #UNDO_STEPS
        bcc +
        lda #0
+       sta undo_pos
        ldx #MSG_REDO
        lda undo_redo
        jmp undo_message
_no_redo
        ldx #MSG_NO_REDO
        ; (on to undo_message_only)

; -----------------------------------------------------------------------------
; undo_message - the song row shows undo_texts entry X (MSG_*), and for
; MSG_UNDO / MSG_REDO the steps left, A (0..16): "UNDO, 5 MORE LEFT".
; Uses the disk message (disk_msg, msg_on: cleared by the next key).
; -----------------------------------------------------------------------------
undo_message_only
        lda #$ff                ; no count
undo_message
        pha
        ldy #39
        lda #CHAR_SPACE
-       sta disk_msg,y
        dey
        bpl -
        ldy #0
-       lda undo_texts,x
        beq +                   ; 0 ends the text
        sta disk_msg,y
        inx
        iny
        bne -                   ; always
+       pla
        bmi _shown
        ; ", n MORE LEFT"
        pha
        lda #','
        sta disk_msg,y
        iny
        iny                     ; (a space after the comma)
        pla
        ldx #CHAR_ZERO-1
        sec
-       inx
        sbc #10
        bcs -
        adc #10+CHAR_ZERO       ; A = the ones, X = the tens
        cpx #CHAR_ZERO
        beq +                   ; one digit
        pha
        txa
        sta disk_msg,y
        iny
        pla
+       sta disk_msg,y
        iny
        ldx #0
-       lda left_text,x
        sta disk_msg,y
        iny
        inx
        cpx #LEFT_TEXT_LEN
        bne -
_shown  lda #1
        sta msg_on
        jmp key_done

; -----------------------------------------------------------------------------
; cell_set - a grid key sets the cursor's cell to A: saved for undo first,
; if that changes it. clobbers A, X, Y
; -----------------------------------------------------------------------------
cell_set
        sta cell_new
        jsr cursor_cell
        lda (grid_ptr),y
        cmp cell_new
        beq _same
        lda edit_pat
        jsr undo_save
        jsr cursor_cell
        lda cell_new
        sta (grid_ptr),y
_same   rts

        .enc "screen"
MSG_UNDO        = 0
MSG_REDO        = undo_redo_text - undo_texts
MSG_NO_UNDO     = undo_none_text - undo_texts
MSG_NO_REDO     = redo_none_text - undo_texts
undo_texts      .text "UNDO", 0
undo_redo_text  .text "REDO", 0
undo_none_text  .text "NOTHING TO UNDO", 0
redo_none_text  .text "NOTHING TO REDO", 0
left_text       .text " MORE LEFT"
LEFT_TEXT_LEN   = * - left_text
        .enc "none"
