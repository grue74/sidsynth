; grid.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The step grid (docs/sequencer.md): one row per sound, 16 steps across.
; It owns the screen and keys through the core's SYNTH_SCREEN hooks:
; synth_draw_step draws one row per call, synth_key edits. F7 switches
; between the grid and the core's parameter screen.

; screen layout
GRID_TITLE_ROW  = 0             ; pattern, tempo, swing, length, play state
GRID_HEAD_ROW   = 1             ; step numbers, play position
GRID_ROW0       = 2             ; first sound row (sounds 0..12 on rows 2..14)
GRID_SONG_ROW   = GRID_ROW0 + NUM_SOUNDS ; song mode, song entries, record
GRID_STATUS_ROW = 16            ; voices, velocity, MIDI (synth_draw_status)
GRID_HELP_ROW0  = 18
GRID_ROWS_DRAWN = GRID_STATUS_ROW + 1 ; rows synth_draw_step cycles through (0..16)
        .cerror GRID_SONG_ROW >= GRID_STATUS_ROW, "sound rows run into the status row"
NAME_COL_G      = 1             ; sound name, 3 characters
MUTE_COL        = 4             ; 'M' when muted
CELL_COL0       = 6             ; step i at column CELL_COL0 + 2 * i
; title row fields
T_PAT_COL       = 4             ; (columns of the numbers in grid_title_text)
T_BPM_COL       = 13
T_SW_COL        = 21
T_LEN_COL       = 29
T_STATE_COL     = 33
; song row fields
S_POS_COL       = 5             ; "pp/ll": song cursor (1-based) / song length
SONG_COL0       = 11            ; first shown entry: mark, "ppxr" (pattern, repeats)
SONG_SHOWN      = 5             ; entries shown, from 2 before the cursor
SONG_ENTRY_W    = 5             ; columns per entry
S_REC_COL       = 37            ; "REC" (reversed) while recording

COL_GRID_A      = 15            ; light grey: steps 1-4 and 9-12
COL_GRID_B      = 3             ; cyan: steps 5-8 and 13-16
COL_NAMES       = 14            ; light blue
COL_SONG        = 7             ; yellow

; key codes (column*8 + row) the grid uses
KC_DEL          = 0
KC_RETURN       = 1
KC_CRSR_RIGHT   = 2
KC_F7           = 3
KC_F1           = 4
KC_F3           = 5
KC_F5           = 6
KC_CRSR_DOWN    = 7
KC_3            = 1*8+0
KC_C            = 2*8+4
KC_M            = 4*8+4
KC_PLUS         = 5*8+0
KC_MINUS        = 5*8+3
KC_HOME         = 6*8+3
KC_1            = 7*8+0
KC_2            = 7*8+3
KC_SPACE        = 7*8+4
KC_STOP         = 7*8+7
KC_S            = 1*8+5
KC_P            = 5*8+1
KC_PERIOD       = 5*8+4
KC_COMMA        = 5*8+7
KC_SEMICOLON    = 6*8+2
KC_ARROW_LEFT   = 7*8+1         ; the left-arrow key, top left
KC_R            = 2*8+1
KC_W            = 1*8+1
KC_L            = 5*8+2
KC_U            = 3*8+6
; (test scripts: file name letters)
KC_T            = 2*8+6
KC_I            = 4*8+1
KC_D            = 2*8+2
KC_8            = 3*8+3
KC_0            = 4*8+3
KC_N            = 4*8+7
KC_O            = 4*8+6
KC_E            = 1*8+6
KC_K            = 4*8+5

        .section zp
grid_full       .byte ?         ; nonzero: redraw everything (static parts first)
grid_row        .byte ?         ; synth_draw_step: next row
edit_pat        .byte ?         ; pattern shown and edited
cur_row         .byte ?         ; cursor: sound 0..12
cur_col         .byte ?         ; cursor: step 0..15
grid_ptr        .word ?         ; the cursor's pattern page / a pattern being drawn
draw_len        .byte ?         ; length of the pattern being drawn
draw_snd        .byte ?         ; sound row being drawn
song_cur        .byte ?         ; song cursor: entry 0..song_len (song_len = add one)
draw_ent        .byte ?         ; song entry being drawn
draw_left       .byte ?         ; song entries still to draw
        .send

; =============================================================================
; Taking and giving back the screen
; =============================================================================

; -----------------------------------------------------------------------------
; grid_take - the grid owns the screen and keys; it draws itself in full on
; the next synth_draw_step (also at start-up: the core's screen_init runs
; after synth_init and would overwrite anything drawn earlier).
; clobbers A
; -----------------------------------------------------------------------------
grid_take
        lda #1
        sta screen_owner
        sta grid_full
        lda #KEY_NONE           ; no key repeat carried over from the other screen
        sta repeat_cmd
        rts

; -----------------------------------------------------------------------------
; grid_leave - back to the core's parameter screen.
; -----------------------------------------------------------------------------
grid_leave
        lda #0
        sta screen_owner
        lda #KEY_NONE
        sta repeat_cmd
        jmp screen_init

; =============================================================================
; Drawing
; =============================================================================

; -----------------------------------------------------------------------------
; synth_draw_step - core hook (SYNTH_SCREEN): draw one grid row per call,
; title, step header, the 13 sound rows, the song row, the status row; or
; everything
; static after grid_take.
; -----------------------------------------------------------------------------
synth_draw_step
        lda grid_full
        beq _row
        jmp grid_draw_static
_row    ldx grid_row
        inx
        cpx #GRID_ROWS_DRAWN
        bcc +
        ldx #0
+       stx grid_row
        cpx #GRID_TITLE_ROW
        bne +
        jmp grid_draw_title
+       cpx #GRID_HEAD_ROW
        bne +
        jmp grid_draw_head
+       cpx #GRID_STATUS_ROW
        beq _status
        cpx #GRID_SONG_ROW
        bne +
        jmp grid_draw_song
+       txa
        sec
        sbc #GRID_ROW0
        cmp #NUM_SOUNDS
        bcs +
        jmp grid_draw_sound
+       rts
_status jsr set_row_ptr         ; X = the row
        jmp synth_draw_status

; -----------------------------------------------------------------------------
; grid_draw_static - clear the screen, colours, help rows; then the rows
; are drawn one per step.
; -----------------------------------------------------------------------------
grid_draw_static
        lda #0
        sta grid_full
        sta grid_row
        ; clear the screen
        ldx #0
        lda #CHAR_SPACE
-       sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        inx
        bne -
        ; colours: title, header, cell columns by beat group, names, status, help
        ldx #GRID_TITLE_ROW
        jsr set_row_ptr
        lda #COL_TITLE
        jsr fill_row_colour
        ldx #GRID_HEAD_ROW
_colour_row
        jsr set_row_ptr
        ldy #39
-       lda grid_col_colour,y
        sta (cptr),y
        dey
        bpl -
        inx
        cpx #GRID_ROW0+NUM_SOUNDS
        bne _colour_row
        ldx #GRID_SONG_ROW
        jsr set_row_ptr
        lda #COL_SONG
        jsr fill_row_colour
        ldx #GRID_STATUS_ROW
        jsr set_row_ptr
        lda #COL_STATUS
        jsr fill_row_colour
        ldx #GRID_HELP_ROW0
-       jsr set_row_ptr
        lda #COL_HELP
        jsr fill_row_colour
        inx
        cpx #25
        bne -
        ; help text
        ldx #0                  ; in two halves (more than 255 bytes)
-       lda grid_help,x
        sta SCREEN+GRID_HELP_ROW0*40,x
        lda grid_help+GRID_HELP_ROWS*20,x
        sta SCREEN+GRID_HELP_ROW0*40+GRID_HELP_ROWS*20,x
        inx
        cpx #GRID_HELP_ROWS*20
        bne -
        rts

; -----------------------------------------------------------------------------
; grid_draw_title - "PAT 01   BPM 125  SW 05  LEN 16  PLAY 01"
; -----------------------------------------------------------------------------
grid_draw_title
        jsr set_row_ptr         ; X = GRID_TITLE_ROW
        ldy #39
-       lda grid_title_text,y
        sta (ptr),y
        dey
        bpl -
        lda edit_pat
        clc
        adc #1
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
        beq ++                  ; always
+       lda seq_bpm
        jsr print_dec3
+
        lda seq_swing
        ldy #T_SW_COL
        jsr print_dec2
        jsr edit_page
        ldy #PAT_LENGTH
        lda (grid_ptr),y
        ldy #T_LEN_COL
        jsr print_dec2
        ; play state: "PLAY nn" (the pattern playing) or "STOP"
        lda seq_play
        beq _stop
        ldx #0
        ldy #T_STATE_COL
-       lda play_text,x
        sta (ptr),y
        iny
        inx
        cpx #5
        bne -
        lda seq_pat
        clc
        adc #1
        jmp print_dec2          ; Y = T_STATE_COL + 5
_stop   ldy #T_STATE_COL
        ldx #0
-       lda stop_text,x
        sta (ptr),y
        iny
        inx
        cpx #4
        bne -
        rts

; -----------------------------------------------------------------------------
; grid_draw_head - step numbers 1 . . . 2 . . . ; the play position reversed
; when the pattern shown is playing; nothing past the length.
; -----------------------------------------------------------------------------
grid_draw_head
        jsr set_row_ptr
        jsr edit_page
        ldy #PAT_LENGTH
        lda (grid_ptr),y
        sta draw_len
        ldx #0
_step   ldy step_col,x
        lda #CHAR_SPACE
        cpx draw_len
        bcs _put                ; past the length
        lda head_chars,x
        ; the play position
        pha
        lda seq_play
        beq _plain
        lda seq_pat
        cmp edit_pat
        bne _plain
        cpx seq_step
        bne _plain
        pla
        ora #REVERSE
        bne _put
_plain  pla
_put    sta (ptr),y
        inx
        cpx #SEQ_STEPS
        bne _step
        rts

; -----------------------------------------------------------------------------
; grid_draw_sound - sound row A (0..12): name, mute mark, 16 cells as
; . o x X (off, soft, normal, accent); the cursor cell reversed; nothing
; past the length.
; -----------------------------------------------------------------------------
grid_draw_sound
        sta draw_snd
        jsr set_row_ptr         ; X = screen row
        ; name
        lda draw_snd
        sta tmp
        asl
        adc tmp                 ; x 3 (carry clear: sound < 86)
        tax
        ldy #NAME_COL_G
        lda sound_names,x
        sta (ptr),y
        iny
        lda sound_names+1,x
        sta (ptr),y
        iny
        lda sound_names+2,x
        sta (ptr),y
        ; mute mark
        ldx draw_snd
        lda mute_bit,x
        cpx #8
        bcs +
        and mute
        jmp ++
+       and mute+1
+       beq +
        lda #CHAR_MUTED
        bne ++
+       lda #CHAR_SPACE
+       ldy #MUTE_COL
        sta (ptr),y
        ; cells
        jsr edit_page
        ldy #PAT_LENGTH
        lda (grid_ptr),y
        sta draw_len
        ldx draw_snd
        lda sound_cell_ofs,x
        sta grid_ptr            ; (grid_ptr),y = this sound's cells, y = step
        ldx #0
_cell   txa
        tay
        lda (grid_ptr),y
        and #CELL_LEVEL
        tay
        lda cell_chars,y
        cpx draw_len
        bcc +
        lda #CHAR_SPACE         ; past the length
+       ldy draw_snd            ; the cursor?
        cpy cur_row
        bne +
        cpx cur_col
        bne +
        ora #REVERSE
+       ldy step_col,x
        sta (ptr),y
        inx
        cpx #SEQ_STEPS
        bne _cell
        rts

; -----------------------------------------------------------------------------
; grid_draw_song - the song row: "SONG" (reversed: song mode on), the song
; cursor / length, then SONG_SHOWN entries from two before the cursor, each
; a mark (> = playing) and "ppxr" (pattern, repeats); the cursor's entry
; reversed; "----" after the last entry (where P adds one).
; X: screen row.
; -----------------------------------------------------------------------------
grid_draw_song
        jsr set_row_ptr
        ldy #39
        lda #CHAR_SPACE
-       sta (ptr),y
        dey
        bpl -
        ; the disk name prompt or message instead, while up
        lda disk_mode
        beq +
        jmp draw_prompt
+       lda msg_on
        beq +
        jmp draw_message
+        ; "SONG"
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

        ; the entries shown: from the cursor - 2 (not below 0)
        lda song_cur
        sec
        sbc #2
        bcs +
        lda #0
+       sta draw_ent
        lda #SONG_SHOWN
        sta draw_left
        ldy #SONG_COL0
_entry  ldx draw_ent
        cpx song_len
        beq _add
        bcs _blank              ; past the end
        ; the mark: > on the entry playing
        lda seq_play
        beq _mark
        cpx song_pos
        bne _mark
        jsr song_active         ; carry set: the song plays; clobbers A only
        bcc _mark
        lda #CHAR_PLAYING
        bne +
_mark   lda #CHAR_SPACE
+       sta (ptr),y
        iny
        ; pattern, x, repeats
        lda song_pat,x
        clc
        adc #1
        jsr print_dec2          ; clobbers X
        lda #CHAR_X
        sta (ptr),y
        iny
        ldx draw_ent
        lda song_rep,x
        clc
        adc #CHAR_ZERO
        sta (ptr),y
        iny
        jmp _cursor
_add    iny                     ; "----": where P adds an entry
        ldx #3
        lda #CHAR_DASH
-       sta (ptr),y
        iny
        dex
        bpl -
        ; the cursor's entry reversed (the 4 characters before Y)
_cursor lda draw_ent
        cmp song_cur
        bne _after
        tya
        sec
        sbc #4
        tay
        ldx #3
-       lda (ptr),y
        ora #REVERSE
        sta (ptr),y
        iny
        dex
        bpl -
        jmp _after
_blank  tya
        clc
        adc #SONG_ENTRY_W
        tay
_after  inc draw_ent
        dec draw_left
        bne _entry
        ; REC while recording
        lda rec_on
        beq +
        ldy #S_REC_COL
        ldx #0
-       lda rec_text,x
        ora #REVERSE
        sta (ptr),y
        iny
        inx
        cpx #3
        bne -
+       rts

; -----------------------------------------------------------------------------
; edit_page - grid_ptr = start of the edited pattern's page. clobbers A
; -----------------------------------------------------------------------------
edit_page
        lda #0
        sta grid_ptr
        lda edit_pat
        clc
        adc #>PATTERN_RAM
        sta grid_ptr+1
        rts

; -----------------------------------------------------------------------------
; print_dec2 - A (0..99) as two digits at (ptr)+Y. Y advances by 2.
; clobbers A, X
; -----------------------------------------------------------------------------
print_dec2
        ldx #CHAR_ZERO-1
        sec
-       inx
        sbc #10
        bcs -
        adc #10+CHAR_ZERO
        pha
        txa
        sta (ptr),y
        iny
        pla
        sta (ptr),y
        iny
        rts

; =============================================================================
; Keys
; =============================================================================

; -----------------------------------------------------------------------------
; synth_key - core hook (SYNTH_SCREEN): a key on the grid. A: key code,
; want_press, shift_held. Every key is used (carry set), so no key plays a
; note here but RETURN (the cursor's sound); A nonzero on return =
; auto-repeat. Steps fire from synth_tick. Keeps the keyboard scan's
; variables.
; -----------------------------------------------------------------------------
synth_key
        ldx want_press
        beq _ignore             ; releases: nothing to do
        ldx disk_mode
        beq +
        jmp prompt_key          ; the disk name prompt takes every key
+       ldx msg_on
        beq +
        ldx #0                  ; a key clears the disk message
        stx msg_on
+        ldx #GRID_KEYS-1
-       cmp grid_key_codes,x
        beq _found
        dex
        bpl -
_ignore lda #0
        sec
        rts
_found  lda grid_key_jump_hi,x
        pha
        lda grid_key_jump_lo,x
        pha
        rts                     ; to the handler (address - 1 on the stack)

; handlers: each ends with A = repeat flag, carry set (key_done / key_repeat)
key_repeat
        lda #1
        sec
        rts
key_done
        lda #0
        sec
        rts

; cursor right (SHIFT: left), down (SHIFT: up); auto-repeat
k_right lda shift_held
        bne _left
        lda cur_col
        cmp #SEQ_STEPS-1
        bcs key_repeat
        inc cur_col
        bcc key_repeat
_left   lda cur_col
        beq key_repeat
        dec cur_col
        jmp key_repeat

k_down  lda shift_held
        bne _up
        lda cur_row
        cmp #NUM_SOUNDS-1
        bcs key_repeat
        adc #1                  ; (carry clear)
        bne _sel                ; always
_up     lda cur_row
        beq key_repeat
        sec
        sbc #1
_sel    jsr sound_select        ; the sound page follows the cursor row
        jmp key_repeat

; SPACE: cell on (normal) / off
k_space jsr cursor_cell
        lda (grid_ptr),y
        and #CELL_LEVEL
        beq +
        lda #0
        beq _set
+       lda #2
_set    jsr cell_set            ; (saved for undo)
        jmp key_done

; 1 2 3: the cell soft / normal / accent, cursor to the next step
k_1     lda #1
        bne set_and_next
k_2     lda #2
        bne set_and_next
k_3     lda #3
set_and_next
        jsr cell_set            ; (saved for undo)
        lda cur_col
        cmp #SEQ_STEPS-1
        bcs +
        inc cur_col
+       jmp key_done

; DEL: cell off
k_del   lda #0
        jsr cell_set            ; (saved for undo)
        jmp key_done

; M: mute / unmute the cursor's sound
k_mute  ldx cur_row
        lda mute_bit,x
        cpx #8
        bcs +
        eor mute
        sta mute
        jmp key_done
+       eor mute+1
        sta mute+1
        jmp key_done

; + / -: length 1..16
k_plus  jsr edit_page
        ldy #PAT_LENGTH
        lda (grid_ptr),y
        cmp #SEQ_STEPS
        bcs +
        adc #1
        jsr length_set
+       jmp key_repeat
k_minus jsr edit_page
        ldy #PAT_LENGTH
        lda (grid_ptr),y
        cmp #2
        bcc +
        sbc #1
        jsr length_set
+       jmp key_repeat

; length_set - the edited pattern's length = A, saved for undo first.
; clobbers A, X, Y
length_set
        pha
        lda edit_pat
        jsr undo_save
        jsr edit_page
        pla
        ldy #PAT_LENGTH
        sta (grid_ptr),y
        rts

; F1 / F2: next / previous pattern; it plays from the next pattern start
k_pat   ldx edit_pat
        lda shift_held
        bne _prev
        inx
        cpx #NUM_PATTERNS
        bcc _sel
        ldx #0
        beq _sel
_prev   dex
        bpl _sel
        ldx #NUM_PATTERNS-1
_sel    stx edit_pat
        stx seq_next
        jmp key_repeat

; F3 / F4: tempo up / down
k_tempo ldx seq_bpm
        lda shift_held
        bne _down
        cpx #BPM_MAX
        bcs +
        inx
        bne _bpm
_down   cpx #BPM_MIN+1
        bcc +
        dex
_bpm    stx seq_bpm
        jsr seq_set_tempo
+       jmp key_repeat

; F5 / F6: swing up / down
k_swing ldx seq_swing
        lda shift_held
        bne _down
        cpx #SWING_MAX
        bcs +
        inx
        bne _sw
_down   txa
        beq +
        dex
_sw     stx seq_swing
        jsr seq_set_tempo
+       jmp key_repeat

; F7: the parameter screen (SHIFT = F8: all notes off)
k_f7    lda shift_held
        beq +
        jsr all_notes_off
        jmp key_done
+       jsr grid_leave
        jmp key_done

; RUN/STOP: play / stop
k_stop  jsr seq_toggle
        jmp key_done

; HOME: cursor to the start; SHIFT (CLR): clear the pattern's cells
k_home  lda shift_held
        bne _clear
        lda #0
        sta cur_col
        jsr sound_select        ; cursor row 0: the page shows sound 0
        jmp key_done
_clear  lda edit_pat
        jsr undo_save
        jsr edit_page
        lda #0
        ldy #PAT_LENGTH-1
-       sta (grid_ptr),y
        dey
        cpy #$ff
        bne -
        jmp key_done

; C: copy this pattern (cells and length) to the next one and show it
k_copy  ldx edit_pat
        cpx #NUM_PATTERNS-1
        bcs +                   ; the last pattern has no next
        inx
        txa
        jsr undo_save           ; the pattern copied over
        jsr edit_page
        lda grid_ptr+1
        sta prog+1
        inc prog+1              ; the next page
        lda #0
        sta prog
        ldy #PAT_LENGTH
-       lda (grid_ptr),y
        sta (prog),y
        dey
        cpy #$ff
        bne -
        inc edit_pat
        lda edit_pat
        sta seq_next
+       jmp key_done

; R: live record on / off
k_rec   lda rec_on
        eor #1
        sta rec_on
        jmp key_done

; RETURN: play the cursor's sound (velocity 100, SHIFT: 127); while
; recording and playing it is recorded too (sound_hit)
k_tap   lda #100
        ldx shift_held
        beq +
        lda #127
+       sta new_vel
        sta last_vel
        lda cur_row
        sta new_sound
        jsr sound_hit
        jmp key_done

; W / L: save / load: the name prompt on the song row (src/disk.asm)
k_save  lda #DISK_SAVE
        .byte $2c               ; bit abs: skips the next lda
k_load  lda #DISK_LOAD
        sta disk_mode
        jmp key_done

; S: song mode on / off
k_song  jsr song_toggle
        jmp key_done

; , / .: song cursor back / on (0..song_len, at most SONG_MAX-1); on an
; entry, the grid shows its pattern
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

; P: put the grid's pattern into the song at the cursor (after the last
; entry: add one, 1 repeat); the cursor moves on
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
_set    lda edit_pat
        sta song_pat,x
        inx
        cpx #SONG_MAX
        bcs _done               ; the last entry: the cursor stays
        stx song_cur
_done   jmp key_done

; ;: the cursor entry's repeats + 1 (after SONG_REP_MAX: 1); SHIFT: - 1
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
_done   jmp key_repeat

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
        jmp -
_last   dec song_len
_done   jmp key_done

; -----------------------------------------------------------------------------
; cursor_cell - (grid_ptr),y = the cursor's cell in the edited pattern.
; clobbers A, Y
; -----------------------------------------------------------------------------
cursor_cell
        jsr edit_page
        ldy cur_row
        lda sound_cell_ofs,y
        clc
        adc cur_col
        tay
        rts

; the keys and their handlers
grid_key_codes  .byte KC_CRSR_RIGHT, KC_CRSR_DOWN, KC_SPACE, KC_1, KC_2, KC_3, KC_DEL, KC_M
                .byte KC_PLUS, KC_MINUS, KC_F1, KC_F3, KC_F5, KC_F7, KC_STOP, KC_HOME, KC_C
                .byte KC_S, KC_COMMA, KC_PERIOD, KC_P, KC_SEMICOLON, KC_ARROW_LEFT
                .byte KC_R, KC_RETURN, KC_W, KC_L, KC_U, KC_D
GRID_KEYS = * - grid_key_codes
grid_key_handlers = [k_right, k_down, k_space, k_1, k_2, k_3, k_del, k_mute, k_plus, k_minus, k_pat, k_tempo, k_swing, k_f7, k_stop, k_home, k_copy, k_song, k_scur_back, k_scur_on, k_put, k_rep, k_sdel, k_rec, k_tap, k_save, k_load, k_undo, k_dump]
grid_key_jump_lo .byte <(grid_key_handlers - 1)
grid_key_jump_hi .byte >(grid_key_handlers - 1)
        .cerror len(grid_key_handlers) != GRID_KEYS, "a handler per grid key"

; =============================================================================
; Tables and texts
; =============================================================================

; screen column of each step
step_col        .for _i := 0, _i < SEQ_STEPS, _i += 1
                .byte CELL_COL0 + 2 * _i
                .endfor
; colour of each column on the grid rows: names, then cells by beat group
grid_col_colour .fill CELL_COL0, COL_NAMES
                .for _i := 0, _i < SEQ_STEPS, _i += 1
                .byte (COL_GRID_A, COL_GRID_B)[(_i / 4) % 2], (COL_GRID_A, COL_GRID_B)[(_i / 4) % 2]
                .endfor
                .fill 40 - CELL_COL0 - 2 * SEQ_STEPS, COL_NAMES
        .cerror * - grid_col_colour != 40, "grid_col_colour: 40 columns"

        .enc "screen"
cell_chars      .text ".oxX"    ; off, soft, normal, accent
head_chars      .text "1...2...3...4..."
CHAR_MUTED      = $4d           ; 'M' in the mixed-case charset
grid_title_text .text format("%-40s", "PAT 00   BPM 000  SW 00  LEN 00  ")
play_text       .text "PLAY "
stop_text       .text "STOP"
song_text       .text "SONG"
rec_text        .text "REC"
ext_text        .text "EXT"
CHAR_SLASH      = $2f
CHAR_DASH       = $2d
CHAR_X          = $18           ; 'x' (mixed-case charset)
CHAR_PLAYING    = $3e           ; '>'
CHAR_ARROW_LEFT = $1f           ; the left-arrow key's character
grid_help
        .text format("%-40s", "CRSR move  SPACE on/off  1 2 3 level")
        .text format("%-40s", "DEL clear  M mute  +/- length  C copy")
        .text format("%-40s", "F1/F2 pattern F3/F4 tempo F5/F6 swing")
        .text format("%-40s", "RUN/STOP play  F7 params  CLR clear pat")
        .text format("%-40s", "S song on/off  , . song position  D dump")
        .text "P put pattern  ; repeats  "
        .byte CHAR_ARROW_LEFT
        .text format("%-13s", " delete")
        .text format("%-40s", "R record RETURN tap W/L save/load U undo")
GRID_HELP_ROWS = (* - grid_help) / 40
        .cerror GRID_HELP_ROW0 + GRID_HELP_ROWS > 25, "help runs off the screen"
        .cerror GRID_HELP_ROWS * 20 > 255, "help: the copy loop takes half of it per pass"
        .enc "none"
