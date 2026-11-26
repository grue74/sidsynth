; undo.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Undo and redo for the step screen (C=+U, C=+SHIFT+U): the last UNDO_STEPS
; edits. From SID808's undo.asm. Before an edit changes a pattern (a step,
; the length, clear, the pattern a copy writes over) or the song (put,
; repeats, transpose, delete), undo_save copies what it changes into the
; next slot of a ring of pages. Undo steps back one slot and swaps it with
; the data, so the slot then holds the state after the edit: redo swaps it
; back. A new edit drops the steps that could be redone. Tempo, swing,
; song mode and the octave are settings, not edits: not undone.

        .weak
UNDO_STEPS      = 16            ; undo steps (a power of 2: the ring index is masked)
        .endweak
UNDO_RAM        = PATTERN_RAM - UNDO_STEPS * 256 ; a page per step, under the patterns
        .cerror UNDO_STEPS & (UNDO_STEPS - 1) != 0, "UNDO_STEPS must be a power of 2"
.if TEST_LOG
        .cerror UNDO_RAM < NOTE_LOG_END, "the undo pages run into the test note log"
.endif
UNDO_SONG       = $80           ; undo_what: the song block (else a pattern number)

; RAM (after the song block)
undo_what       = SONG_END      ; UNDO_STEPS: what each slot holds (pattern 0..63, UNDO_SONG)
undo_pos        = undo_what + UNDO_STEPS ; the slot the next edit saves to
undo_count      = undo_pos + 1  ; steps that can be undone (0..UNDO_STEPS)
undo_redo       = undo_count + 1 ; steps that can be redone
UNDO_VARS_END   = undo_redo + 1
        .cerror UNDO_VARS_END > $c800, "undo variables run past $C7FF"
.if MIDI_SYSTEM
        .cerror UNDO_VARS_END > SEQ_SPP_RAM, "undo variables run into the sequencer's song position bytes"
.endif
steps_msg       = $c800         ; 40 screen codes: a message the song row shows (msg_on)

; -----------------------------------------------------------------------------
; undo_clear - nothing to undo or redo (start-up, after a load).
; clobbers A
; -----------------------------------------------------------------------------
undo_clear
        lda #0
        sta undo_pos
        sta undo_count
        sta undo_redo
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
us_data lda $ffff,y             ; (undo_setup sets the address: the data)
us_slot sta $ff00,y             ;                           and the slot's page
        tya
        bne -
        lda undo_pos
        clc
        adc #1
        and #UNDO_STEPS-1
        sta undo_pos
        lda undo_count
        cmp #UNDO_STEPS
        bcs +
        inc undo_count
+       lda #0
        sta undo_redo
        rts

; -----------------------------------------------------------------------------
; undo_swap - swap slot X with the data it was saved from, then show what
; changed: a pattern on the step screen (and next to play, as F1/F2 do),
; or the song with its cursor kept on it.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
undo_swap
        jsr undo_setup
-       dey
uw_data1 lda $ffff,y            ; (undo_setup sets these four addresses)
        pha
uw_slot1 lda $ff00,y
uw_data2 sta $ffff,y
        pla
uw_slot2 sta $ff00,y
        tya
        bne -
        lda undo_what,x
        bmi _song
        sta edit_pat            ; the pattern that changed, on the screen
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
; page and the data undo_what,x names (self-modified operands).
; Out: Y = the data's length. preserves X; clobbers A
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
        adc #>PATTERN_RAM       ; a pattern: its page, notes, flags and length
        ldy #0
        sty us_data+1
        sty uw_data1+1
        sty uw_data2+1
        ldy #PAT_BYTES
        bne _hi                 ; always
_song   lda #<song_pat          ; the song: entries, repeats, transposes, length
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
; k_undo - C=+U: undo the last edit; C=+SHIFT+U: redo. The song row says
; what happened (until a key).
; -----------------------------------------------------------------------------
k_undo  lda shift_held
        bne _redo
        lda undo_count
        beq _no_undo
        dec undo_count
        inc undo_redo
        lda undo_pos            ; back one slot: the last edit's
        sec
        sbc #1
        and #UNDO_STEPS-1
        sta undo_pos
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
        lda undo_pos
        clc
        adc #1
        and #UNDO_STEPS-1
        sta undo_pos
        ldx #MSG_REDO
        lda undo_redo
        jmp undo_message
_no_redo
        ldx #MSG_NO_REDO
        ; (on to undo_message_only)

; -----------------------------------------------------------------------------
; undo_message - the song row shows undo_texts entry X (MSG_*), and for
; MSG_UNDO / MSG_REDO the steps left, A (0..16): "UNDO, 5 MORE LEFT".
; In steps_msg, shown while msg_on (cleared by the next key).
; -----------------------------------------------------------------------------
undo_message_only
        lda #$ff                ; no count
undo_message
        pha
        ldy #39
        lda #CHAR_SPACE
-       sta steps_msg,y
        dey
        bpl -
        ldy #0
-       lda undo_texts,x
        beq +                   ; 0 ends the text
        sta steps_msg,y
        inx
        iny
        bne -                   ; always
+       pla
        bmi _shown
        ; ", n MORE LEFT"
        pha
        lda #CHAR_COMMA
        sta steps_msg,y
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
        sta steps_msg,y
        iny
        pla
+       sta steps_msg,y
        iny
        ldx #0
-       lda left_text,x
        sta steps_msg,y
        iny
        inx
        cpx #LEFT_TEXT_LEN
        bne -
_shown  lda #1
        sta msg_on
        jmp key_done

CHAR_COMMA      = $2c
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
