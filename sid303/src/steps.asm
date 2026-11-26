; steps.asm - part of SID303, included by sid303.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The step screen (docs/sequencer.md, Screen and Keys): a pattern as a
; list, one row per step, and the keys that edit it. It owns the screen
; and keys through the core's SYNTH_SCREEN hooks: synth_draw_step draws one
; row per call, synth_key edits. F7 switches between it and the core's
; parameter screen, which is where SID303 starts.
;
; The note keys enter notes at the cursor; the other commands are on the
; keys the notes leave free, and with C= held.

; screen layout
STEPS_TITLE_ROW = 0             ; pattern, tempo, swing, length, play state
STEPS_HEAD_ROW  = 1             ; column heads
STEPS_ROW0      = 2             ; first step row (steps 1..16 on rows 2..17)
STEPS_SONG_ROW  = STEPS_ROW0 + 16 ; song mode, song entries (phase D)
STEPS_STATUS_ROW = 19           ; the synth's status row (synth_draw_status)
STEPS_HELP_ROW0 = 20
STEPS_ROWS_DRAWN = STEPS_STATUS_ROW + 1 ; rows synth_draw_step cycles through
        .cerror STEPS_SONG_ROW >= STEPS_STATUS_ROW, "step rows run into the status row"
; step row columns
PLAY_COL        = 0             ; '>' on the step playing
STEPNO_COL      = 1             ; step number, 2 digits
NOTE_COL        = 4             ; note name, "---" rest, "===" tie
ACC_COL         = 9             ; 'A' or '.'
SLIDE_COL       = 11            ; 'S' or '.'
REVERSE_COLS    = 13            ; columns reversed on the cursor's row
LANE_COL        = 14            ; piano-roll lane: a mark per step at its pitch
LANE_WIDTH      = 40 - LANE_COL ; semitones in the lane (from the C below the entry octave)
; title row fields (columns of the values in steps_title)
T_PAT_COL       = 4
T_BPM_COL       = 12
T_SW_COL        = 20
T_LEN_COL       = 28
T_STATE_COL     = 32            ; "PLAY nn" or "STOP   "
; song row fields
S_POS_COL       = 5             ; "pp/ll": song cursor (1-based) / song length
SONG_COL0       = 11            ; the first entry shown: mark, "ppxr+tt"
SONG_SHOWN      = 3             ; entries shown, from the one before the cursor
SONG_ENTRY_W    = 9             ; columns per entry (mark, 7 characters, a space)
        .cerror SONG_COL0 + SONG_SHOWN * SONG_ENTRY_W > 40 + 1, "song entries run off the row"

COL_STEPS       = 15            ; light grey: steps within the pattern's length
COL_PAST        = 11            ; dark grey: steps past it
COL_BEAT        = 1             ; white: the numbers of steps 1, 5, 9, 13
COL_SONG        = 7             ; yellow
CHAR_DOT        = $2e           ; '.'
CHAR_DASH       = $2d           ; '-'
CHAR_EQUALS     = $3d           ; '='
CHAR_LANE_NOTE  = $2a           ; '*': a note in the lane
CHAR_LANE_LOW   = $3c           ; '<': a note below the lane
CHAR_LANE_HIGH  = $3e           ; '>': a note above the lane
CHAR_A          = $41           ; screen codes of 'A', 'S', 'C' (mixed-case charset: the
CHAR_S          = $53           ; capitals are at $41-$5A)
CHAR_C          = $43
CHAR_X          = $18           ; 'x' (lower case: "01x2")
CHAR_SLASH      = $2f
CHAR_PLUS       = $2b
NO_MARKER       = $ff           ; marker_row: no play marker shown

LOWEST_STEP_NOTE = LOWEST_NOTE  ; notes a step can hold: the frequency table's range
HIGHEST_STEP_NOTE = HIGHEST_NOTE

; key codes (column*8 + row) the step screen uses
KC_DEL          = 0
KC_CRSR_RIGHT   = 2
KC_F7           = 3
KC_F1           = 4
KC_F3           = 5
KC_F5           = 6
KC_CRSR_DOWN    = 7
KC_A            = 1*8+2
KC_C            = 2*8+4
KC_F            = 2*8+5
KC_PLUS         = 5*8+0
KC_MINUS        = 5*8+3
KC_HOME         = 6*8+3
KC_EQUALS       = 6*8+5
KC_SPACE        = 7*8+4
KC_CBM          = 7*8+5         ; the C= key
KC_STOP         = 7*8+7
KC_S            = 1*8+5
KC_U            = 3*8+6
KC_P            = 5*8+1
KC_PERIOD       = 5*8+4
KC_COMMA        = 5*8+7
KC_SEMICOLON    = 6*8+2
KC_ARROW_LEFT   = 7*8+1         ; the left-arrow key, top left
KC_RETURN       = 1
KC_W            = 1*8+1
KC_L            = 5*8+2
KC_M            = 4*8+4

; RAM ($C148-$C1FF: the synth's, after note_stack)
audition_bits   = $c148         ; 8 bytes, a bit per key code: its press played a note
                                ; through the core, so its release must go to the core too
note_key_mask   = audition_bits + 8 ; 8 bytes: a bit per note key (steps_init, from key_map)
        .cerror note_stack + STACK_SIZE > audition_bits, "audition_bits overlaps note_stack"

        .section zp
steps_static    .byte ?         ; nonzero: the frame is being drawn, row steps_static-1 next
steps_leaving   .byte ?         ; nonzero: the parameter screen's frame is being drawn,
                                ; row steps_leaving-1 next (steps_leave)
steps_row       .byte ?         ; synth_draw_step: the row drawn last
text_ptr        .word ?         ; steps_static_row: the row's text
edit_pat        .byte ?         ; the pattern shown and edited
cur_step        .byte ?         ; the cursor: step 0..15
edit_ptr        .word ?         ; edit_page: the edited pattern's page (low byte 0)
draw_step       .byte ?         ; draw_step_row: the step being drawn
lane_pitch      .byte ?         ; draw_step_row: pitch of the last note drawn (ties show it)
lane_base       .byte ?         ; draw_step_row: the lane's lowest note
row_reverse     .byte ?         ; draw_step_row: $80 on the cursor's row, else 0
key_tmp         .byte ?         ; synth_key handlers, draw_step_row (the flags): scratch
name_octave     .byte ?         ; put_note_name: the octave + 1
key_x           .byte ?         ; synth_key: the key code
new_note        .byte ?         ; step_read / step_write: the cursor step's note ...
new_flags       .byte ?         ; ... and flags, as a handler wants them
song_cur        .byte ?         ; song cursor: entry 0..song_len (song_len = add one)
msg_on          .byte ?         ; nonzero: the song row shows steps_msg (until a key)
draw_ent        .byte ?         ; draw_song_row: the entry being drawn
draw_left       .byte ?         ; draw_song_row: entries still to draw
draw_col        .byte ?         ; draw_song_row: its column
marker_row      .byte ?         ; the step whose row shows the play marker, NO_MARKER = none
        .send

; =============================================================================
; Taking and giving back the screen
; =============================================================================

; -----------------------------------------------------------------------------
; steps_take - the step screen owns the screen and keys; from the next
; synth_draw_step it draws its frame, a row per call, then its rows.
; The note keys already held (pressed on the parameter screen) count as
; auditioned, so their releases still reach the core.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
steps_take
        lda #1
        sta screen_owner
        sta steps_static        ; the frame from row 0
        lda #0
        sta steps_leaving       ; (in case the way back was still drawing)
        lda #NO_MARKER          ; (the frame clears the old one)
        sta marker_row
        lda #KEY_NONE           ; no key repeat carried over from the other screen
        sta repeat_cmd

        ; audition bits: the note keys held now
        ldy #7
-       lda key_now,y
        and note_key_mask,y
        sta audition_bits,y
        dey
        bpl -
        rts

; -----------------------------------------------------------------------------
; steps_init - from synth_init: note_key_mask from key_map (a bit per note
; key), so steps_take needs no pass over all 64 keys.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
steps_init
        lda #0                  ; (power-on RAM is junk)
        ldx #7
-       sta note_key_mask,x
        sta audition_bits,x
        dex
        bpl -
        ldx #63
_key    lda key_map,x
        cmp #KEY_CMD
        bcs _next               ; not a note key
        txa
        and #7
        tay
        lda bit_of,y
        pha
        txa
        lsr
        lsr
        lsr
        tay                     ; Y = column = code / 8
        pla
        ora note_key_mask,y
        sta note_key_mask,y
_next   dex
        bpl _key
        rts

; -----------------------------------------------------------------------------
; steps_leave - back to the core's parameter screen. Its frame (what core
; screen_init draws: blank help-coloured rows, the title, the help, the
; status row's colour) is drawn a row per synth_draw_step first, then the
; core takes the screen and draws its rows. screen_init would clear it all
; at once, ~4 ticks, making the sequencer's notes late.
; clobbers A
; -----------------------------------------------------------------------------
steps_leave
        lda #1
        sta steps_leaving       ; the parameter screen's frame from row 0
        lda #0
        sta steps_static        ; (in case the step screen's frame was still drawing)
        lda #KEY_NONE
        sta repeat_cmd
        rts

; =============================================================================
; Drawing
; =============================================================================

; -----------------------------------------------------------------------------
; synth_draw_step - core hook (SYNTH_SCREEN): draw one row per call: the
; title, the column heads, the 16 step rows, the status row. Before that,
; after steps_take, the frame a row per call (drawing all 25 rows at once
; would take ~5 ticks and make the sequencer's notes late); after
; steps_leave, the parameter screen's frame, then the core takes over.
; -----------------------------------------------------------------------------
synth_draw_step
        ldx steps_leaving
        beq _here
        ; on the way back: the parameter screen's frame, then hand it over
        dex
        jsr param_frame_row
        inc steps_leaving
        lda steps_leaving
        cmp #25+1
        bcc +
        lda #0
        sta steps_leaving
        sta screen_owner        ; the core draws from here on,
        sta draw_row            ; its rows from the top
+       rts
_here   ldx steps_static
        beq _row
        dex
        jsr steps_static_row
        inc steps_static
        lda steps_static
        cmp #25+1
        bcc +
        lda #0                  ; frame done: the rows from the top
        sta steps_static
        lda #STEPS_ROWS_DRAWN-1
        sta steps_row
+       rts

        ; the rows in turn
_row    jsr marker_update   ; the play marker at once, then a row
        ldx steps_row
        inx
        cpx #STEPS_ROWS_DRAWN
        bcc +
        ldx #0
+       jsr row_safe            ; (core, RASTER_SAFE) the beam about to pass row X?
        bcs +
        rts                     ; yes: this row next time, so it can't flash
+       stx steps_row
        cpx #STEPS_TITLE_ROW
        bne +
        jmp draw_title
+       cpx #STEPS_HEAD_ROW
        bne +
        jmp draw_head
+       cpx #STEPS_STATUS_ROW
        beq _status
        txa
        sec
        sbc #STEPS_ROW0
        cmp #SEQ_STEPS
        bcs +
        jmp draw_step_row       ; A = the step
+       jmp draw_song_row
_status jsr set_row_ptr         ; X = the row
        jmp synth_draw_status

; -----------------------------------------------------------------------------
; draw_title - "PAT 01  BPM 125  SW 00  LEN 16  PLAY 01" (or "STOP   ";
; "BPM EXT" on MIDI clock).
; -----------------------------------------------------------------------------
draw_title
        ldx #STEPS_TITLE_ROW
        jsr set_row_ptr
        jsr edit_page
        ldy #39
-       lda steps_title,y
        sta (ptr),y
        dey
        bpl -
        ldx edit_pat
        inx
        txa
        ldy #T_PAT_COL
        jsr print_dec2
        ldy #T_BPM_COL
        lda params+P_CLOCK
        beq +
        ldx #0                  ; MIDI clock: "EXT" for the tempo
-       lda ext_text,x
        sta (ptr),y
        iny
        inx
        cpx #3
        bne -
        beq _swing              ; always
+       lda seq_bpm
        jsr print_dec3
_swing
        lda seq_swing
        ldy #T_SW_COL
        jsr print_dec2
        ldy #PAT_LENGTH
        lda (edit_ptr),y
        ldy #T_LEN_COL
        jsr print_dec2
        lda seq_play
        beq _stopped
        ldx seq_pat
        inx
        txa
        ldy #T_STATE_COL+5
        jmp print_dec2
_stopped
        ldx #6
        ldy #T_STATE_COL+6
-       lda stop_text,x
        sta (ptr),y
        dey
        dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; draw_head - the column heads and the lane's octaves: "C" and the octave
; number at each C of the lane.
; -----------------------------------------------------------------------------
draw_head
        ldx #STEPS_HEAD_ROW
        jsr set_row_ptr
        ldy #39
-       lda steps_head,y
        sta (ptr),y
        dey
        bpl -
        jsr lane_set
        lda lane_base
        ldy #LANE_COL
-       jsr put_note_octave     ; "C1" at the C
        tya
        clc
        adc #12-2
        tay
        cpy #40-1
        bcc -
        rts

; put_note_octave - "C" and the octave of the C at lane column Y into the
; head row; Y += 2. clobbers A, X
put_note_octave
        lda #CHAR_C
        sta (ptr),y
        iny
        tya
        sec
        sbc #LANE_COL+1         ; semitones from the lane's base
        clc
        adc lane_base           ; the C's MIDI note
        ldx #0
-       inx                     ; octave + 2: MIDI note 12 = C0
        sec
        sbc #12
        bcs -
        txa
        clc
        adc #CHAR_ZERO-2
        sta (ptr),y
        iny
        rts

; -----------------------------------------------------------------------------
; lane_set - lane_base = the C at or below the lowest note of the edited
; pattern (all 16 steps), so its line fits the lane (26 semitones: two
; octaves and a bit); with no notes, the C an octave below the note keys'
; (the Z key's) C. Sets edit_ptr.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
lane_set
        jsr edit_page
        lda #$ff                ; the lowest note so far: none
        sta lane_base
        ldx #SEQ_STEPS-1
_step   txa
        clc
        adc #PAT_FLAGS
        tay
        lda (edit_ptr),y
        and #TIME_MASK
        cmp #TIME_NOTE
        bne _next               ; rests and ties have no pitch of their own
        txa
        tay                     ; (PAT_NOTES = 0)
        lda (edit_ptr),y
        cmp lane_base
        bcs _next
        sta lane_base
_next   dex
        bpl _step
        lda lane_base
        cmp #$ff
        bne _round
        lda kb_base             ; no notes: an octave below the note keys
        sec
        sbc #12
        sta lane_base
        rts
_round  sec                     ; down to its C: lowest - (lowest mod 12)
-       sbc #12
        bcs -
        adc #12                 ; A = lowest mod 12 (carry clear here)
        eor #$ff
        sec
        adc lane_base           ; lowest - A
        sta lane_base
        rts

; -----------------------------------------------------------------------------
; draw_step_row - step A of the edited pattern: play marker, number, note,
; accent, slide, lane. Dim past the pattern's length; the cursor's row
; reversed. Rows are drawn in order, so a tie shows the pitch of the note
; drawn above it (lane_pitch).
; -----------------------------------------------------------------------------
draw_step_row
        sta draw_step
        clc
        adc #STEPS_ROW0
        tax
        jsr set_row_ptr
        jsr edit_page
        lda draw_step
        bne +
        lda #NO_NOTE            ; step 1: no note above it
        sta lane_pitch
        jsr lane_set
+
        ; colour: within the length, or past it; beat numbers white
        ldy #PAT_LENGTH
        lda draw_step
        cmp (edit_ptr),y
        lda #COL_STEPS
        bcc +
        lda #COL_PAST
+       jsr fill_row_colour
        lda draw_step
        and #3
        bne +
        lda #COL_BEAT
        ldy #STEPNO_COL
        sta (cptr),y
        iny
        sta (cptr),y
+
        ; reverse the cursor's row
        lda #0
        ldx draw_step
        cpx cur_step
        bne +
        lda #REVERSE
+       sta row_reverse

        ; blank the row
        lda #CHAR_SPACE
        ldy #39
-       sta (ptr),y
        dey
        bpl -

        ; play marker: where marker_update last put it
        lda draw_step
        cmp marker_row
        bne +
        lda #CHAR_MARKER
        ldy #PLAY_COL
        sta (ptr),y
+
        ; step number
        ldx draw_step
        inx
        txa
        ldy #STEPNO_COL
        jsr print_dec2

        ; note, rest or tie
        lda draw_step
        clc
        adc #PAT_FLAGS
        tay
        lda (edit_ptr),y
        sta key_tmp             ; the flags
        and #TIME_MASK
        cmp #TIME_NOTE
        beq _note
        ldx #CHAR_DASH          ; rest: "---"
        cmp #TIME_TIE
        bne _three
        ldx #CHAR_EQUALS        ; tie: "===", the lane at the note above
        lda lane_pitch
        cmp #NO_NOTE
        beq _three
        jsr lane_mark
        ldx #CHAR_EQUALS
_three  txa
        ldy #NOTE_COL
        sta (ptr),y
        iny
        sta (ptr),y
        iny
        sta (ptr),y
        jmp _flags
_note   ldy draw_step           ; (PAT_NOTES = 0)
        lda (edit_ptr),y
        sta lane_pitch
        ldy #NOTE_COL
        jsr put_note_name
        lda lane_pitch
        ldx #CHAR_LANE_NOTE
        jsr lane_mark

        ; accent and slide
_flags  ldx #CHAR_DOT
        lda key_tmp
        and #FLAG_ACCENT
        beq +
        ldx #CHAR_A
+       txa
        ldy #ACC_COL
        sta (ptr),y
        ldx #CHAR_DOT
        lda key_tmp
        and #FLAG_SLIDE
        beq +
        ldx #CHAR_S
+       txa
        ldy #SLIDE_COL
        sta (ptr),y

        ; the cursor's row reversed (the columns before the lane)
        lda row_reverse
        beq _done
        ldy #REVERSE_COLS-1
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        dey
        bpl -
_done   rts

; -----------------------------------------------------------------------------
; draw_song_row - the song row: "SONG" (reversed: song mode on), the song
; cursor / the song's length, then SONG_SHOWN entries from the one before
; the cursor: a mark (> on the entry playing), pattern, "x", repeats and
; transpose ("01x2+05"); "----" after the last entry (where C=+P adds
; one); the cursor's entry reversed. While msg_on, undo's message instead.
; -----------------------------------------------------------------------------
draw_song_row
        ldx #STEPS_SONG_ROW
        jsr set_row_ptr
        lda #COL_SONG
        jsr fill_row_colour
        lda disk_mode
        beq +
        jsr put_blank_row       ; the disk name prompt
        jmp draw_prompt
+       lda msg_on
        beq +
        lda #<steps_msg         ; the message
        sta text_ptr
        lda #>steps_msg
        sta text_ptr+1
        jmp put_text_row
+       jsr put_blank_row

        ; "SONG", reversed in song mode
        ldy #3
-       lda song_text,y
        ldx song_on
        beq +
        ora #REVERSE
+       sta (ptr),y
        dey
        bpl -
        ; cursor / length
        lda song_cur
        clc
        adc #1
        ldy #S_POS_COL
        jsr print_dec2
        lda #CHAR_SLASH
        sta (ptr),y
        iny
        lda song_len
        jsr print_dec2

        ; the entries shown: from the cursor - 1 (not below 0)
        lda song_cur
        sec
        sbc #1
        bcs +
        lda #0
+       sta draw_ent
        lda #SONG_SHOWN
        sta draw_left
        lda #SONG_COL0
        sta draw_col
_entry  ldy draw_col
        ldx draw_ent
        cpx song_len
        beq _add
        bcs _next               ; past the end: blank
        ; the mark: > on the entry playing
        lda #CHAR_SPACE
        ldx seq_play
        beq +
        ldx draw_ent
        cpx song_pos
        bne +
        jsr song_active         ; carry set: the song plays (clobbers A only)
        lda #CHAR_SPACE
        bcc +
        lda #CHAR_MARKER
+       sta (ptr),y
        iny
        ; pattern, x, repeats
        ldx draw_ent
        lda song_pat,x
        clc
        adc #1
        jsr print_dec2          ; clobbers X
        lda #CHAR_X
        sta (ptr),y
        iny
        ldx draw_ent
        lda song_rep,x
        ora #CHAR_ZERO
        sta (ptr),y
        iny
        ; transpose: sign and two digits
        lda song_tr,x
        bmi _minus
        pha
        lda #CHAR_PLUS
        bne _sign               ; always
_minus  eor #$ff                ; |transpose|
        clc
        adc #1
        pha
        lda #CHAR_DASH
_sign   sta (ptr),y
        iny
        pla
        jsr print_dec2
        jmp _cursor
_add    iny                     ; "----": where C=+P adds an entry
        lda #CHAR_DASH
        ldx #3
-       sta (ptr),y
        iny
        dex
        bpl -
        ; the cursor's entry reversed (from after its mark)
_cursor lda draw_ent
        cmp song_cur
        bne _next
        ldy draw_col
        iny
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        iny
        tya
        sec
        sbc draw_col
        cmp #SONG_ENTRY_W-1
        bcc -
_next   inc draw_ent
        lda draw_col
        clc
        adc #SONG_ENTRY_W
        sta draw_col
        dec draw_left
        beq +
        jmp _entry
+       rts

; -----------------------------------------------------------------------------
; marker_update - move the play marker ('>' before the step playing, when
; the step screen shows the pattern playing) as soon as the step changes:
; the rows are redrawn only one per call, so a row's own marker could lag
; several steps behind while playing. Only the two cells change.
; clobbers A, X, Y, ptr, cptr
; -----------------------------------------------------------------------------
marker_update
        ldx #NO_MARKER          ; where it should be
        lda seq_play
        beq +
        lda seq_pat
        cmp edit_pat
        bne +
        ldx seq_step
+       cpx marker_row
        bne +
        rts                     ; where it is already
+       txa
        pha
        ldx marker_row          ; the old one goes
        lda #CHAR_SPACE
        jsr marker_put
        pla
        sta marker_row          ; the new one
        tax
        lda #CHAR_MARKER
        ; (on to marker_put)

; marker_put - character A in the marker column of step X's row (reversed
; on the cursor's row); nothing for X = NO_MARKER. clobbers A, X, Y
marker_put
        cpx #NO_MARKER
        beq _done
        cpx cur_step
        bne +
        ora #REVERSE
+       pha
        txa
        clc
        adc #STEPS_ROW0
        tax
        jsr set_row_ptr
        pla
        ldy #PLAY_COL
        sta (ptr),y
_done   rts

; -----------------------------------------------------------------------------
; lane_mark - put character X in the lane at pitch A ('<' / '>' at the
; edge for a pitch outside it). clobbers A, Y
; -----------------------------------------------------------------------------
lane_mark
        sec
        sbc lane_base
        bcs +
        ldx #CHAR_LANE_LOW      ; below the lane
        lda #0
+       cmp #LANE_WIDTH
        bcc +
        ldx #CHAR_LANE_HIGH     ; above it
        lda #LANE_WIDTH-1
+       clc
        adc #LANE_COL
        tay
        txa
        sta (ptr),y
        rts

; -----------------------------------------------------------------------------
; put_note_name - the name of MIDI note A ("C#2", "A-1") at (ptr),Y; Y += 3.
; clobbers A, X
; -----------------------------------------------------------------------------
put_note_name
        ldx #0                  ; X = octave + 1 (MIDI note 12 = C0)
-       cmp #12
        bcc +
        sbc #12                 ; carry set here
        inx
        bne -                   ; always
+       asl                     ; the semitone's two characters
        stx name_octave
        tax
        lda note_names,x
        sta (ptr),y
        iny
        lda note_names+1,x
        sta (ptr),y
        iny
        lda name_octave
        clc
        adc #CHAR_ZERO-1
        sta (ptr),y
        iny
        rts

; -----------------------------------------------------------------------------
; print_dec2 - A (0..99) as two digits at (ptr),Y; Y += 2. clobbers A, X
; -----------------------------------------------------------------------------
print_dec2
        ldx #CHAR_ZERO-1
        sec
-       inx                     ; tens
        sbc #10
        bcs -
        adc #10+CHAR_ZERO       ; ones (carry clear here)
        pha
        txa
        sta (ptr),y
        iny
        pla
        sta (ptr),y
        iny
        rts

; -----------------------------------------------------------------------------
; edit_page - edit_ptr = the edited pattern's page. clobbers A
; -----------------------------------------------------------------------------
edit_page
        lda #0
        sta edit_ptr
        lda edit_pat
        clc
        adc #>PATTERN_RAM
        sta edit_ptr+1
        rts

; -----------------------------------------------------------------------------
; steps_static_row - the step screen's frame, row X: its colour, and its
; text (a help row) or blanks. The other rows draw their own text.
; clobbers A, Y, ptr, cptr, text_ptr
; -----------------------------------------------------------------------------
steps_static_row
        jsr set_row_ptr         ; ptr, cptr = row X
        lda steps_row_colour,x
        jsr fill_row_colour
        txa
        sec
        sbc #STEPS_HELP_ROW0
        bcc put_blank_row       ; above the help
        cmp #STEPS_HELP_ROWS
        bcs put_blank_row       ; below it
        tay                     ; help row Y
        lda #<steps_help
        sta text_ptr
        lda #>steps_help
        sta text_ptr+1
        jsr text_rows_on
        jmp put_text_row

; -----------------------------------------------------------------------------
; param_frame_row - row X of the parameter screen's frame, as core
; screen_init draws it: the title (title colour), a help row, or blanks;
; the status row in the status colour, every other row in the help colour
; (the core's rows recolour themselves as they are drawn).
; clobbers A, Y, ptr, cptr, text_ptr
; -----------------------------------------------------------------------------
param_frame_row
        jsr set_row_ptr         ; ptr, cptr = row X
        lda #COL_HELP
        cpx #TITLE_ROW
        bne +
        lda #COL_TITLE
+       cpx #STATUS_ROW
        bne +
        lda #COL_STATUS
+       jsr fill_row_colour

        ; the row's text: the title, a help row, or none
        cpx #TITLE_ROW
        bne +
        lda #<title_text
        sta text_ptr
        lda #>title_text
        sta text_ptr+1
        jmp put_text_row
+       txa
        sec
        sbc #HELP_ROW0
        bcc put_blank_row       ; above the help
        cmp #HELP_ROWS
        bcs put_blank_row       ; below it
        tay                     ; help row Y
        lda #<help_text
        sta text_ptr
        lda #>help_text
        sta text_ptr+1
        jsr text_rows_on
        jmp put_text_row

; -----------------------------------------------------------------------------
; text_rows_on - text_ptr += 40 * Y (to row Y of a block of 40-character
; rows). clobbers A, Y
; -----------------------------------------------------------------------------
text_rows_on
-       dey
        bmi _done
        clc
        lda text_ptr
        adc #40
        sta text_ptr
        bcc -
        inc text_ptr+1
        bne -                   ; always (the text is not in page $FF)
_done   rts

; -----------------------------------------------------------------------------
; put_text_row - the 40 characters at text_ptr into the screen row at ptr.
; put_blank_row - spaces into it. clobbers A, Y
; -----------------------------------------------------------------------------
put_text_row
        ldy #39
-       lda (text_ptr),y
        sta (ptr),y
        dey
        bpl -
        rts

put_blank_row
        lda #CHAR_SPACE
        ldy #39
-       sta (ptr),y
        dey
        bpl -
        rts

; =============================================================================
; Keys
; =============================================================================

; -----------------------------------------------------------------------------
; synth_key - core hook (SYNTH_SCREEN): a key on the step screen. A: key
; code, want_press, shift_held. Out: carry set = used (A nonzero =
; auto-repeat), carry clear = the core handles it as on the parameter
; screen. Keeps the keyboard scan's variables.
;   - once F7 has left (steps_leaving), every key goes to the core: the
;     parameter screen's frame is still drawing
;   - a press clears the song row's message (undo's, the disk's)
;   - while the disk name prompt is up, it takes every press (releases
;     still go on below, so an auditioned note's release reaches the core)
;   - a note key enters a note at the cursor; stopped, the core also plays
;     it (carry clear) and its release must go to the core too
;     (audition_bits), whatever happened in between
;   - with C= held, the C= commands (note keys too: C=+C, C=+S, ...); else
;     the step screen's commands
;   - every other key is used and does nothing (C= and SHIFT themselves)
; -----------------------------------------------------------------------------
synth_key
        ldx steps_leaving
        beq +
        clc                     ; on the way back: the parameter screen's keys already
        rts
+       tax                     ; X = key code
        stx key_x
        ldy want_press
        beq +
        ldy #0                  ; a press: the message goes
        sty msg_on
        ldy disk_mode
        beq +
        txa                     ; the disk name prompt takes every press
        jmp prompt_key
+       lda key_map,x
        cmp #KEY_CMD
        bcs _command
        ; a note key: a press with C= held is a C= command, not a note
        ldy want_press
        beq _release
        tay
        lda key_now+KC_CBM/8
        and #1 << (KC_CBM % 8)
        bne _command
        tya                     ; A = the note's semitones above the Z key
        jsr k_note
        ldx key_x
        lda seq_play
        bne _used               ; playing: no audition
        jsr audition_set        ; stopped: the core plays it (and its release)
        clc
        rts
_release
        jsr audition_test       ; release: to the core if the press went there
        beq _used
        jsr audition_clear
        clc
        rts

_command
        lda want_press
        beq _used               ; releases of command keys: nothing
        lda key_now+KC_CBM/8    ; C= held: its own table
        and #1 << (KC_CBM % 8)
        beq _plain
        txa
        ldx #CBM_KEYS-1
-       cmp cbm_key_codes,x
        beq _cbm_found
        dex
        bpl -
        bmi _used               ; always
_plain  txa
        ldx #STEP_KEYS-1
-       cmp step_key_codes,x
        beq _found
        dex
        bpl -
_used   lda #0
        sec
        rts
_found  lda step_key_jump_hi,x
        pha
        lda step_key_jump_lo,x
        pha
        rts                     ; to the handler (address - 1 on the stack)
_cbm_found
        lda cbm_key_jump_hi,x
        pha
        lda cbm_key_jump_lo,x
        pha
        rts

; handlers: each ends with A = repeat flag, carry set (key_done / key_repeat)
key_repeat
        lda #1
        sec
        rts
key_done
        lda #0
        sec
        rts

; -----------------------------------------------------------------------------
; audition_set / audition_clear / audition_test - key X's bit in
; audition_bits. audition_test: Z clear = set. clobbers A, Y; keeps X
; -----------------------------------------------------------------------------
audition_set
        jsr audition_at
        ora audition_bits,y
        sta audition_bits,y
        rts
audition_clear
        jsr audition_at
        eor #$ff
        and audition_bits,y
        sta audition_bits,y
        rts
audition_test
        jsr audition_at
        and audition_bits,y
        rts
; audition_at - Y = key X's byte, A = its bit
audition_at
        txa
        and #7
        tay
        lda bit_of,y
        pha
        txa
        lsr
        lsr
        lsr
        tay
        pla
        rts

; =============================================================================
; Editing a step
; =============================================================================

; -----------------------------------------------------------------------------
; step_read - new_note / new_flags = the cursor step's note and flags (a
; handler then changes them and calls step_write). clobbers A, Y
; -----------------------------------------------------------------------------
step_read
        jsr edit_page
        ldy cur_step            ; (PAT_NOTES = 0)
        lda (edit_ptr),y
        sta new_note
        tya
        clc
        adc #PAT_FLAGS
        tay
        lda (edit_ptr),y
        sta new_flags
        rts

; -----------------------------------------------------------------------------
; step_write - the cursor step becomes new_note / new_flags: if that
; changes it, saved for undo first; a key that changes nothing saves no
; undo step. clobbers A, X, Y
; -----------------------------------------------------------------------------
step_write
        jsr edit_page
        ldy cur_step
        lda (edit_ptr),y
        cmp new_note
        bne _changed
        tya
        clc
        adc #PAT_FLAGS
        tay
        lda (edit_ptr),y
        cmp new_flags
        beq _same
_changed
        lda edit_pat
        jsr undo_save
        jsr edit_page
        ldy cur_step
        lda new_note
        sta (edit_ptr),y
        tya
        clc
        adc #PAT_FLAGS
        tay
        lda new_flags
        sta (edit_ptr),y
_same   rts

; -----------------------------------------------------------------------------
; k_note - note key: the cursor's step becomes the note A semitones above
; the Z key (accented with SHIFT; its slide stays), cursor down. Notes
; above the table's range are an octave lower.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
k_note
        clc
        adc kb_base
-       cmp #HIGHEST_STEP_NOTE+1
        bcc +
        sbc #12                 ; carry set here
        bcs -                   ; always
+       pha
        jsr step_read
        pla
        sta new_note
        lda new_flags
        and #FLAG_SLIDE
        ora #TIME_NOTE
        ldx shift_held
        beq +
        ora #FLAG_ACCENT
+       sta new_flags
        jsr step_write
        jmp cursor_next

; -----------------------------------------------------------------------------
; cursor_next - the cursor one step down (after step 16: step 1).
; clobbers A
; -----------------------------------------------------------------------------
cursor_next
        lda cur_step
        clc
        adc #1
        and #SEQ_STEPS-1
        sta cur_step
        rts

; cursor down (SHIFT: up); auto-repeat
k_down  lda shift_held
        bne _up
        jsr cursor_next
        jmp key_repeat
_up     lda cur_step
        sec
        sbc #1
        and #SEQ_STEPS-1
        sta cur_step
        jmp key_repeat

; CRSR right (SHIFT: left): the cursor's note a semitone up (down); auto-repeat
k_pitch jsr step_read
        lda new_flags
        and #TIME_MASK
        cmp #TIME_NOTE
        bne _done               ; only notes have a pitch
        lda new_note
        ldx shift_held
        bne _lower
        cmp #HIGHEST_STEP_NOTE
        bcs _done
        adc #1                  ; carry clear here
        bcc _store              ; always
_lower  cmp #LOWEST_STEP_NOTE+1
        bcc _done
        sbc #1                  ; carry set here
_store  sta new_note
        jsr step_write
        jmp key_repeat
_done   jmp key_done

; A: accent on / off
k_accent
        lda #FLAG_ACCENT
        bne flag_flip           ; always
; F: slide on / off
k_slide lda #FLAG_SLIDE
flag_flip
        pha
        jsr step_read
        pla
        eor new_flags
        sta new_flags
        jsr step_write
        jmp key_done

; =: tie (its slide stays), cursor down
k_tie   jsr step_read
        lda new_flags
        and #FLAG_SLIDE
        ora #TIME_TIE
        sta new_flags
        jsr step_write
        jsr cursor_next
        jmp key_done

; SPACE: rest, cursor down. DEL: rest, cursor stays (no accent or slide
; either; the note byte stays as it was)
k_space jsr step_rest
        jsr cursor_next
        jmp key_done
k_del   jsr step_rest
        jmp key_done
step_rest
        jsr step_read
        lda #TIME_REST
        sta new_flags
        jmp step_write

; + / -: the pattern's length 1..16
k_plus  jsr edit_page
        ldy #PAT_LENGTH
        lda (edit_ptr),y
        cmp #SEQ_STEPS
        bcs +
        adc #1                  ; carry clear here
        jsr length_write
+       jmp key_done
k_minus jsr edit_page
        ldy #PAT_LENGTH
        lda (edit_ptr),y
        cmp #2
        bcc +
        sbc #1                  ; carry set here
        jsr length_write
+       jmp key_done
; length_write - the length becomes A, saved for undo first. clobbers A, X, Y
length_write
        pha
        lda edit_pat
        jsr undo_save
        jsr edit_page
        pla
        ldy #PAT_LENGTH
        sta (edit_ptr),y
        rts

; =============================================================================
; Patterns, tempo, transport
; =============================================================================

; F1 / F2: next / previous pattern; it plays from the next pattern start
; (stopped: from the start)
k_pat   ldx edit_pat
        lda shift_held
        bne _prev
        inx
        cpx #NUM_PATTERNS
        bcc _sel
        ldx #0
        beq _sel                ; always
_prev   dex
        bpl _sel
        ldx #NUM_PATTERNS-1
_sel    stx edit_pat
        stx seq_next
        jmp key_done

; F3 / F4: tempo +/- 1 BPM; auto-repeat
k_tempo ldx seq_bpm
        lda shift_held
        bne _slower
        cpx #BPM_MAX
        bcs _done
        inx
        bne _set                ; always
_slower cpx #BPM_MIN+1
        bcc _done
        dex
_set    stx seq_bpm
        jsr seq_set_tempo
        jmp key_repeat
_done   jmp key_done

; C= + F3 / F4: swing +/- 1 (0..SWING_MAX); auto-repeat
k_swing ldx seq_swing
        lda shift_held
        bne _less
        cpx #SWING_MAX
        bcs _done
        inx
        bne _set                ; always
_less   cpx #1
        bcc _done
        dex
_set    stx seq_swing
        jsr seq_set_tempo
        jmp key_repeat
_done   jmp key_done

; F5 / F6: the entry octave up / down (the core's keyboard octave)
k_octave
        lda #CMD_OCT_UP
        ldx shift_held
        beq +
        lda #CMD_OCT_DOWN
+       jsr run_command
        jmp key_done

; HOME: cursor to step 1. CLR (SHIFT+HOME): clear the pattern (all rests,
; length 16), saved for undo first
k_home  lda shift_held
        bne _clear
        lda #0
        sta cur_step
        jmp key_done
_clear  lda edit_pat
        jsr undo_save
        jsr edit_page
        lda #TIME_REST          ; (and note 0)
        ldy #PAT_LENGTH-1
-       sta (edit_ptr),y
        dey
        bpl -
        ldy #PAT_LENGTH
        lda #SEQ_STEPS
        sta (edit_ptr),y
        jmp key_done

; RUN/STOP: play / stop
k_stop  jsr seq_toggle
        jmp key_done

; F7: the parameter screen. F8 (SHIFT+F7): all notes off
k_f7    lda shift_held
        bne _off
        jsr steps_leave
        jmp key_done
_off    jsr all_notes_off
        jmp key_done

; C= + C: copy the pattern to the next one (saved for undo first) and show
; it (not past the last)
k_copy  ldx edit_pat
        inx
        cpx #NUM_PATTERNS
        bcs _done
        txa
        jsr undo_save           ; the pattern written over
        jsr edit_page
        lda edit_ptr+1
        sta text_ptr+1          ; (text_ptr: the copy's page)
        inc text_ptr+1
        lda #0
        sta text_ptr
        ldy #PAT_BYTES-1
-       lda (edit_ptr),y
        sta (text_ptr),y
        dey
        bpl -
        ldx edit_pat
        inx
        stx edit_pat
        stx seq_next
_done   jmp key_done

; =============================================================================
; The song
; =============================================================================

; C= + S: song mode on / off
k_song  jsr song_toggle
        jmp key_done

; C= + , / .: song cursor back / on (0..song_len, at most SONG_MAX-1); on an
; entry, the step screen shows its pattern; auto-repeat
k_scur_back
        lda song_cur
        beq song_show
        dec song_cur
        jmp song_show
k_scur_on
        lda song_cur
        cmp song_len
        bcs song_show           ; at the end already
        cmp #SONG_MAX-1
        bcs song_show
        inc song_cur
song_show
        ldx song_cur
        cpx song_len
        bcs +
        lda song_pat,x
        sta edit_pat
+       jmp key_repeat

; C= + P: put the step screen's pattern into the song at the cursor (after
; the last entry: add one, 1 repeat, no transpose); the cursor moves on
k_put   ldx song_cur
        cpx song_len
        bcc +
        cpx #SONG_MAX
        bcs _done               ; the song is full
+       lda #UNDO_SONG
        jsr undo_save
        ldx song_cur
        cpx song_len
        bcc _set
        inc song_len
        lda #1
        sta song_rep,x
        lda #0
        sta song_tr,x
_set    lda edit_pat
        sta song_pat,x
        inx
        cpx #SONG_MAX
        bcs _done               ; the last entry: the cursor stays
        stx song_cur
_done   jmp key_done

; C= + ;: the cursor entry's repeats + 1 (after SONG_REP_MAX: 1); SHIFT: - 1
k_rep   ldx song_cur
        cpx song_len
        bcs _done               ; not on an entry
        lda #UNDO_SONG
        jsr undo_save
        ldx song_cur
        ldy song_rep,x
        lda shift_held
        bne _down
        iny
        cpy #SONG_REP_MAX+1
        bcc _set
        ldy #1
        bne _set                ; always
_down   dey
        bne _set
        ldy #SONG_REP_MAX
_set    tya
        sta song_rep,x
_done   jmp key_done

; C= + + / -: the cursor entry's transpose +/- 1 semitone (-12..+12);
; auto-repeat
k_trans_up
        ldx song_cur
        cpx song_len
        bcs trans_done          ; not on an entry
        lda song_tr,x
        cmp #TRANSPOSE_MAX
        beq trans_done          ; (signed: +12 is the top)
        lda #1
        bne trans_add           ; always
k_trans_down
        ldx song_cur
        cpx song_len
        bcs trans_done
        lda song_tr,x
        cmp #256-TRANSPOSE_MAX  ; (-12 as a byte)
        beq trans_done          ; -12 is the bottom
        lda #$ff                ; -1
trans_add
        pha
        lda #UNDO_SONG
        jsr undo_save
        ldx song_cur
        pla
        clc
        adc song_tr,x
        sta song_tr,x
        jmp key_repeat
trans_done
        jmp key_done

; left arrow: delete the cursor's entry (the later ones move up)
k_sdel  ldx song_cur
        cpx song_len
        bcs _done               ; not on an entry
        lda #UNDO_SONG
        jsr undo_save
        ldx song_cur
-       inx
        cpx song_len
        bcs _last
        lda song_pat,x
        sta song_pat-1,x
        lda song_rep,x
        sta song_rep-1,x
        lda song_tr,x
        sta song_tr-1,x
        jmp -
_last   dec song_len
_done   jmp key_done

; =============================================================================
; Texts and tables
; =============================================================================

; key codes and handlers: without C=, and with it
step_key_codes  .byte KC_CRSR_DOWN, KC_CRSR_RIGHT, KC_A, KC_F, KC_EQUALS, KC_SPACE, KC_DEL
                .byte KC_PLUS, KC_MINUS, KC_F1, KC_F3, KC_F5, KC_HOME, KC_STOP, KC_F7
                .byte KC_ARROW_LEFT
STEP_KEYS = * - step_key_codes
step_key_handlers = [k_down, k_pitch, k_accent, k_slide, k_tie, k_space, k_del, k_plus, k_minus, k_pat, k_tempo, k_octave, k_home, k_stop, k_f7, k_sdel]
step_key_jump_lo .byte <(step_key_handlers - 1)
step_key_jump_hi .byte >(step_key_handlers - 1)
        .cerror len(step_key_handlers) != STEP_KEYS, "a handler per step key"
cbm_key_codes   .byte KC_F3, KC_C, KC_S, KC_COMMA, KC_PERIOD, KC_P, KC_SEMICOLON
                .byte KC_PLUS, KC_MINUS, KC_U, KC_W, KC_L, KC_M
CBM_KEYS = * - cbm_key_codes
cbm_key_handlers = [k_swing, k_copy, k_song, k_scur_back, k_scur_on, k_put, k_rep, k_trans_up, k_trans_down, k_undo, k_save, k_load, k_dump]
cbm_key_jump_lo .byte <(cbm_key_handlers - 1)
cbm_key_jump_hi .byte >(cbm_key_handlers - 1)
        .cerror len(cbm_key_handlers) != CBM_KEYS, "a handler per C= key"

bit_of          .byte 1, 2, 4, 8, 16, 32, 64, 128

; each row's colour in the frame (the step rows recolour themselves)
steps_row_colour
        .byte COL_TITLE, COL_HELP
        .fill 16, COL_STEPS
        .byte COL_SONG, COL_STATUS
        .fill 5, COL_HELP
        .cerror * - steps_row_colour != 25, "steps_row_colour: one per row"

        .enc "screen"
steps_title     .text format("%-40s", "PAT 01  BPM 125  SW 00  LEN 16  PLAY 01")
stop_text       .text "STOP   "
ext_text        .text "EXT"
steps_head      .text format("%-40s", " ST NOTE A S")
song_text       .text "SONG"
steps_help
        .text format("%-40s", "Z-P note SHIFT=acc = tie SPACE/DEL rest")
        .text format("%-40s", "A accent F slide CRSR step/pitch +- len")
        .text format("%-40s", "F1/2 pat F3/4 bpm C=F3/4 swing F5/6 oct")
        .text format("%-40s", "CLR STOP F7 F8 <-del C=: C copy U undo")
        .text format("%-40s", "C=: S song ,. P put ; rep +- tr W/L/M")
STEPS_HELP_ROWS = (* - steps_help) / 40
        .cerror (* - steps_help) != STEPS_HELP_ROWS * 40, "a help row is longer than 40"
        .cerror STEPS_HELP_ROW0 + STEPS_HELP_ROWS > 25, "help runs off the screen"
        .enc "none"
