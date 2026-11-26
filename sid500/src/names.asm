; names.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The family's names (docs/design.md section 5d; the user, 2026-11-24): a
; setting per MIDI channel, which of the family's synths plays it (none,
; SID303, SID808, SID101), cycled by C= Y on the song screen for the
; cursor's track's channel and shown as a digit (3, 8, 1) before each
; track's number in the header. A pattern opened from a track on such a
; channel shows the names: SID808's drums by note (its 3-letter sound
; names, on the step grid's note columns and in the event list) and each
; synth's controllers (in the list, 8 letters). The names are read from
; the synths' own sources at build time (tables.py family_names). Program
; changes stay numbers (the presets are the user's own banks).
;
; All of it after the tables (late_code): song.asm's calls of
; song_prepare and click_key and grid.asm's pitch code come here through
; same-size changes, so nothing before them moves.

CHANNEL_SYNTH   = $c9c0         ; each MIDI channel's family synth, SYNTH_* (song data:
                                ; the free bytes after SCENE_REPEATS, saved with the song)
        .cerror CHANNEL_SYNTH < SCENE_REPEATS + NUM_SCENES || CHANNEL_SYNTH + 16 > TRACK_CHANNEL, "CHANNEL_SYNTH's place"
SYNTH_NONE      = 0             ; the setting's values (tables.py FAMILY)
SYNTH_303       = 1
SYNTH_808       = 2
SYNTH_101       = 3
SYNTHS          = 4
KEY_Y           = 3*8+1         ; Y's key code (column 3, row 1)
NAME_LEN        = 8             ; a controller's name

; the variables: after list.asm's (main RAM, whatever $01 is)
        .virtual list_vars_end
names_row       .byte ?         ; names_prepare: the row
names_y         .byte ?         ; name_note: the place
names_note      .byte ?         ;   the note (name_cc: the controller)
names_k         .byte ?         ;   scratch
names_vars_end
        .endv
        .cerror names_vars_end > $d000, "the names' variables run past $CFFF"

.if LIST_CODE                ; (sid500.asm LIST_CODE)
        .section late_code

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; names_init - (io_copy_all, at start) no channel has a family synth.
; clobbers A, X
; -----------------------------------------------------------------------------
names_init
        lda #SYNTH_NONE
        ldx #15
-       sta CHANNEL_SYNTH,x
        dex
        bpl -
        rts
        .send

; -----------------------------------------------------------------------------
; names_key - (song.asm synth_key, the song screen, in click_key's place)
; C= Y: the cursor's track's channel's family synth the next (none, SID303,
; SID808, SID101, round), the header drawn now; carry set (used). Else
; click_key (C= K).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
names_key
        cmp #KEY_Y
        bne _no
        pha
        lda key_now+KEY_CBM_COLUMN ; C= held?
        and #KEY_CBM_BIT
        beq _not
        pla
        lda want_press
        beq _used               ; (its release)
        ldx song_cursor
        ldy TRACK_CHANNEL,x
        ldx CHANNEL_SYNTH,y
        inx
        cpx #SYNTHS
        bcc +
        ldx #SYNTH_NONE
+       txa
        sta CHANNEL_SYNTH,y
        ldx #SONG_HEAD_ROW      ; (every track on the channel: the whole header)
        jsr song_urgent_row
        jsr song_urgent
_used   sec
        rts
_not    pla
_no     jmp click_key

; -----------------------------------------------------------------------------
; names_prepare - (song.asm song_draw_from, song_more_take: in song_prepare's
; place) row X prepared (song_prepare); the song screen's header: before
; each track's number (its first place, always blank: 1-16) its channel's
; family synth's digit, white. clobbers A, X, Y
; -----------------------------------------------------------------------------
names_prepare
        stx names_row
        jsr disk_prepare        ; (disk.asm: the overlay's rows, else song_prepare)
        lda song_mode
        bne _done
        lda names_row
        cmp #SONG_HEAD_ROW
        bne _done
        ldx #0                  ; the half's cells
_cell   txa
        ora song_half
        tay
        lda TRACK_CHANNEL,y
        tay
        lda CHANNEL_SYNTH,y
        beq _next
        tay
        lda names_digit-1,y
        pha
        txa
        asl a
        asl a
        adc #SONG_CELL_COL0     ; (carry clear)
        tay
        pla
        sta song_line,y
        lda #COL_SONG_TITLE
        sta song_line_col,y
_next   inx
        cpx #SONG_TRACKS
        bcc _cell
_done   rts
        .cerror SONG_CELL_WIDTH != 4, "names_prepare: a cell's place"

; -----------------------------------------------------------------------------
; names_synth - A = the open pattern's track's channel's family synth (Z
; set: none). clobbers X, Y
; -----------------------------------------------------------------------------
names_synth
        ldx grid_track
        ldy TRACK_CHANNEL,x
        lda CHANNEL_SYNTH,y
        rts

; -----------------------------------------------------------------------------
; name_note - note A's name in 3 places at song_line + Y: on an SID808
; channel its drum sound's name (if the note has one), else its pitch
; (MIDI note 12 = C0, below it "-" for the octave). (grid.asm
; grid_note_cell, list.asm list_row_io.) clobbers A, X, Y
; -----------------------------------------------------------------------------
name_note
        sty names_y
        sta names_note
        jsr names_synth
        cmp #SYNTH_808
        bne _pitch
        lda names_note          ; a drum's note?
        sec
        sbc #DRUM_FIRST
        cmp #DRUM_NOTES
        bcs _pitch
        tax
        lda drum_note_sound,x
        bmi _pitch
        sta names_k             ; its name: 3 places
        asl a
        adc names_k             ; (carry clear: under 128)
        tax
        ldy names_y
        lda drum_names,x
        sta song_line,y
        lda drum_names+1,x
        sta song_line+1,y
        lda drum_names+2,x
        sta song_line+2,y
        rts
_pitch  lda names_note          ; the pitch: its name and octave
        ldx #CHAR_DIGIT0-1      ; (X = "0" - 1 + the octave)
-       cmp #12
        bcc +
        sbc #12
        inx
        bne -
+       tay
        lda note_letters,y
        pha
        lda note_signs,y
        ldy names_y
        sta song_line+1,y
        pla
        sta song_line,y
        cpx #CHAR_DIGIT0-1      ; (below C0: "-")
        bne +
        ldx #CHAR_DASH
+       txa
        sta song_line+2,y
        rts

; -----------------------------------------------------------------------------
; name_cc - controller A's name for the open pattern's channel's family
; synth, in its 8 places at song_line + LIST_EVENT: carry clear; none (no
; synth, or not one of its controllers): carry set, nothing written.
; clobbers A, X, Y, ptr
; -----------------------------------------------------------------------------
name_cc
        sta names_note
        jsr names_synth
        beq _no
        sta names_k
        ldx #NAMES_CC-1
-       lda names_cc_synth,x
        cmp names_k
        bne _next
        lda names_cc_num,x
        cmp names_note
        beq _found
_next   dex
        bpl -
_no     sec
        rts
_found  lda #0                  ; its name: names_cc_text + X * 8
        sta ptr+1
        txa
        asl a
        rol ptr+1
        asl a
        rol ptr+1
        asl a
        rol ptr+1
        adc #<names_cc_text     ; (carry clear)
        sta ptr
        lda ptr+1
        adc #>names_cc_text
        sta ptr+1
        ldy #NAME_LEN-1
-       lda (ptr),y
        sta song_line+LIST_EVENT,y
        dey
        bpl -
        clc
        rts
        .cerror NAMES_CC > 128, "name_cc: X * 8 in 10 bits"

        .enc "screen"
names_digit     .text "381"     ; SYNTH_303, _808, _101's digits
        .enc "none"
        .send
.else
names_key       = click_key     ; (no LIST_CODE: the hooks to the song screen's own)
names_prepare   = disk_prepare
        .section late_code
; name_note - (no LIST_CODE) note A's pitch in 3 places at song_line + Y
name_note
        sty names_y
        ldx #CHAR_DIGIT0-1
-       cmp #12
        bcc +
        sbc #12
        inx
        bne -
+       tay
        lda note_letters,y
        pha
        lda note_signs,y
        ldy names_y
        sta song_line+1,y
        pla
        sta song_line,y
        cpx #CHAR_DIGIT0-1
        bne +
        ldx #CHAR_DASH
+       txa
        sta song_line+2,y
        rts
        .send
.endif
