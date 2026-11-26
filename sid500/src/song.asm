; song.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The song screen (docs/design.md section 5; stage B): the 64 scenes down,
; 8 of the 16 tracks across (1-8 or 9-16), each cell the pattern its track
; plays in that scene, in the track's channel colour (muted: dark grey;
; another soloed: grey), the cursor's cell in reverse video. A title row
; (the scene playing, the tempo, the half shown, play or stop) and a
; header of the track numbers (M: muted, S: soloed). Keys: F7 back to the
; parameter screen, the cursor keys move (past the 8th track to the other
; half; the scenes scroll), left-arrow flips the halves, + and - change
; the cell's pattern (1-128 or none), DEL clears it, M mutes the cursor's
; track, S solos it, SPACE as everywhere.
;
; Drawing (docs/plan.md, the editor's rules): a row is prepared aside,
; then drawn only when the beam won't pass it meanwhile (song_row_safe;
; an urgent row waits for that, the others are tried again later),
; whole, each cell's character and colour written back to back with
; interrupts off between the two, so no cell is ever seen half drawn. The
; rows to draw are kept in two bitmaps: urgent (a key's effect: the
; cursor's rows, the title), drawn first and from every 250 Hz tick too
; (song_urgent), and dirty (every row to draw, the urgent ones among
; them), the rest a row a main-loop pass.

SONG_TITLE_ROW  = 0
SONG_HEAD_ROW   = 2             ; the track numbers
SONG_GRID_ROW   = 3             ; the first scene's row on the screen
SONG_ROWS       = 22            ; scene rows shown (3..24)
SCREEN_ROWS     = 25
SONG_SCENE_COL  = 0             ; the scene's number (2 digits)
SONG_MARK_COL   = 2             ; ">" at the scene playing
SONG_CELL_COL0  = 5             ; the first track's cell
SONG_CELL_WIDTH = 4             ; a cell: the pattern number (3 places) and a gap
SONG_FLAG_COL   = 3             ;   the gap's place in the header: M or S
SONG_TRACKS     = 8             ; tracks shown at once (the user: 1-8 or 9-16)
COL_SONG_TITLE  = 1             ; white: the title, the playing scene's mark
COL_LABEL       = 12            ; grey: the scenes' numbers
COL_MUTED       = 11            ; dark grey: a muted track (docs/plan.md)
COL_UNSOLOED    = 12            ; grey: a track not soloed while another is
CHAR_REVERSE    = $80           ; a character's reverse video bit (the cursor)
CHAR_DIGIT0     = $30           ; "0" in screen codes
SEL_URGENT      = 0             ; song_draw_from: the urgent rows' bitmap
SEL_DIRTY       = 4             ;   the dirty rows' (song_dirty_rows follows song_urgent_rows)
CHAR_DASH       = $2d           ; screen codes (a string constant would be encoded
CHAR_MARK       = $3e           ; where it is used, under .enc "none")
CHAR_M          = $4d           ; (the mixed set's capitals: $41-$5A)
CHAR_S          = $53
SHIFT_UP        = 1             ; song_shift: a scroll down, the rows' contents up
SHIFT_DOWN      = 2             ;   a scroll up, the rows' contents down
LINE_OTHER      = 0             ; song_line_kind
LINE_SCENE      = 1

; key codes (column * 8 + row; with SHIFT the other way)
KEY_DEL         = 0
KEY_CRSR_RIGHT  = 2             ; (SHIFT: left)
KEY_F7          = 3
KEY_CRSR_DOWN   = 7             ; (SHIFT: up)
KEY_S           = 13
KEY_M           = 36
KEY_PLUS        = 40
KEY_MINUS       = 43
KEY_LEFT_ARROW  = 57

        .section zp
song_scene_ptr  .word ?         ; a scene's row in SCENES (song_scene_at)
        .send

; the song screen's own, in the RAM the core leaves to the synth (after
; transport.asm's)
        .virtual transport_vars_end
song_cursor     .byte ?         ; the cursor's track, 0-15
song_row        .byte ?         ; the cursor's scene, 0-63
song_top        .byte ?         ; the first scene shown
song_shown_state .byte ?        ; play or stop as the title shows it (1 / 0)
song_shown_tempo .byte ?        ; the tempo as the title shows it (the parameter)
song_urgent_rows .fill 4        ; rows to draw first, a bit each (row / 8, song_bits)
song_dirty_rows .fill 4         ; every row to draw (the urgent ones too)
song_line       .fill 40        ; a row prepared aside: its characters
song_line_col   .fill 40        ;   and colours
song_sel        .byte ?         ; song_draw_from: SEL_URGENT or SEL_DIRTY
song_draw_row   .byte ?         ;   the row being drawn
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
song_ready_row  .byte ?         ; the row song_line holds, prepared ($FF: none; any
        .send
                                ; change to the screen's content forgets it)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
song_bit_byte   .byte ?         ; song_row_bit's scratch
        .send
song_line_scene .byte ?         ; the line being prepared: its scene
song_half       .byte ?         ;   the half's first track
song_cell       .byte ?         ;   the cell, 0-7
song_col        .byte ?         ;   its column
song_track      .byte ?         ;   its track
song_digits     .byte ?         ; song_num3's scratch
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
song_old_row    .byte ?         ; the cursor's row as the screen shows it, after a move
        .send
                                ; up or down not yet drawn ($FF: none): its cell put
song_old_col    .byte ?         ;   back with the new row (song_pair_prep); its column
song_put_x      .byte ?         ; song_put_line: X kept
song_put_list   .fill PUT_AT_ONCE ;   the cells that differ
song_put_cursor .fill PUT_AT_ONCE ;   those whose reverse bit changes (the cursor's)
song_put_rev    .byte ?         ;   how many
song_cur_col    .byte ?         ; song_scene_line: the cursor's cell's column ($FF: none)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
song_line_kind  .byte ?         ; LINE_SCENE: song_line_col holds the scene rows' colours
        .send
                                ; (the same on every scene row: built once a change)
song_col_colour .fill SONG_TRACKS ; each shown column's colour on the screen's scene rows
song_recolour   .byte ?         ; columns (a bit each) to recolour (song_recolour_step)
        .section zp_hot         ; (sid500.asm: in the zero page after the core's)
song_shift      .byte ?         ; a scroll by copying rows under way: SHIFT_UP or SHIFT_DOWN
        .send
                                ; (the rows' contents move), 0 = none
song_shift_row  .byte ?         ;   the next row to copy into
song_shift_ok   .byte ?         ; song_key_down: nonzero = every scene row was as it
                                ; should be before the key (a scroll may copy them)
song_put_pair   .byte ?         ; nonzero: the old cursor's cell to put back with them
song_pair_row   .byte ?         ;   its row
song_put_n      .byte ?         ; song_put_line: the cells listed
song_vars_end
        .endv
        .cerror song_vars_end > $c200, "the song screen's variables run past $C1FF"
        .cerror song_dirty_rows - song_urgent_rows != SEL_DIRTY, "the bitmaps' order"

; channel_colour - each MIDI channel's colour (the user, 2026-11-20:
; docs/plan.md "Colour"; tools/palette.py shows it)
channel_colour  .byte 2, 8, 7, 13, 3, 14, 4, 10, 5, 1, 15, 12, 3, 4, 2, 13

; song_bits - a row's bit in its byte of the row bitmaps
song_bits       .byte 1, 2, 4, 8, 16, 32, 64, 128

        .enc "screen"
SONG_TITLE_SCENE = 12           ; the title's places: the scene's number (2 digits)
SONG_TITLE_TEMPO = 20           ;   the tempo (3)
SONG_TITLE_STATE = 36           ;   play or stop (4)
        .section io_data        ; (under I/O: line_text reads it)
song_title_text .text "SONG  SCENE 01  BPM 120 001.1  0:00 STOP" ; (clock.asm: the bar.beat and
                                ; m:ss at SONG_TITLE_CLOCK, the user 2026-11-26)
        .cerror * - song_title_text != 40, "the title is a row"
        .send
song_state_text .text "STOP", "PLAY", "REC "
        .enc "none"

; -----------------------------------------------------------------------------
; song_init - from synth_init: the cursor on scene 1's track 1, nothing to
; draw (the RAM is junk at power-on).
; clobbers A, X
; -----------------------------------------------------------------------------
song_init_body .macro               ; (run at start and from the disk overlay: sid500.asm twice)
        lda #0
        sta song_shift
        lda #$ff
        sta song_old_row
        lda #0
        sta song_cursor
        sta song_row
        sta song_top
        sta song_shown_state
        sta song_shown_tempo
        lda #$ff
        sta song_ready_row
        lda #0
        ldx #3
-       sta song_urgent_rows,x
        sta song_dirty_rows,x
        dex
        bpl -
        rts
        .endm
        #twice song_init

; -----------------------------------------------------------------------------
; song_take - (F7 on the parameter screen: synth_command) the song screen
; owns the screen and keys: every row to draw, the cursor's first.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_take
        lda #MODE_SONG          ; (F7 from the step grid: the song screen)
        sta song_mode
        jsr song_colours_reset
        lda #1
        sta screen_owner
        lda #$ff                ; every row, 0-24 (bits past row 24, never drawn, never
        ldx #2                  ; cleared: song_draw_from's quick "none marked" never
-       sta song_dirty_rows,x   ; held, and every main-loop pass scanned)
        dex
        bpl -
        lda #%00000001
        sta song_dirty_rows+3
        .cerror SCREEN_ROWS != 25, "song_take: the rows' bits"
        jsr song_urgent_cursor
        lda #KEY_NONE           ; no key repeat carried over
        sta repeat_cmd
        rts

; -----------------------------------------------------------------------------
; song_leave - back to the parameter screen (redrawn at once by the core's
; screen_init; a later stage will hand it over a row at a time).
; -----------------------------------------------------------------------------
song_leave
        lda #0
        sta screen_owner
        sta draw_row
        lda #KEY_NONE
        sta repeat_cmd
        jmp screen_init

; =============================================================================
; The keys
; =============================================================================

; -----------------------------------------------------------------------------
; synth_key - core hook (SYNTH_SCREEN): a key on the song screen. A = key
; code, want_press. Carry set = used; A = 1: the key repeats while held
; (the cursor keys, + and -), 0: no repeat.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_key
        pha
.if TEST_LOG
        jsr log_key             ; (tests: when each key was read)
.endif
        pla
        ldx song_mode
        beq _song
        ldx want_press          ; the step grid's keys (its releases: used; SPACE is
        bne _grid               ; its rest key)
        sec
        lda #0
        rts
_grid   jmp list_key                ; (list.asm: F3, the event list; else grid_key)
_song   jsr disk_key        ; C= W / L / D: the disk (disk.asm), else names_key: C= K: the
                                ; metronome (carry set: it was); C= Y the family's
                                ; synth (names.asm)
        bcs +
        jsr rec_key             ; C= R: a take (take.asm)
        bcc ++
+       jmp song_key_done
+
.if TEST_LIVE == 3
TEST_PUBLISH_KEY = 5*8+1        ; (tests: P, the key matrix's column 5, row 1)
        cmp #TEST_PUBLISH_KEY   ; (tests: P publishes, live.asm test_live_key)
        bne +
        lda want_press
        beq song_key_done
        jsr test_live_key
        jmp song_key_done
+
.endif
        cmp #KEY_SPACE
        bne +
        jsr count_key           ; (the transport keys, a count-in ended: count.asm)
        lda #0
        rts
        ; ours? (its index in the tables in X)
+       ldx #SONG_KEY_COUNT-1
-       cmp song_key_codes,x
        beq _ours
        dex
        bpl -
        clc                     ; (not ours: the core's)
        rts
_ours   lda want_press
        beq song_key_done       ; (our keys' releases: used)
        lda song_shift          ; a scroll's copying under way: finished first (a
        beq +                   ; key during it, quick repeats: rows the key changes
        stx song_bit_byte       ; mustn't be copied over after)
-       jsr song_shift_step
        lda song_shift
        bne -
        ldx song_bit_byte
+
        lda song_key_hi,x       ; its routine (each ends at song_key_done or _repeat)
        pha
        lda song_key_lo,x
        pha
        rts

; song_key_done / song_key_repeat - where each key's routine ends: used, no
; repeat / used, repeating while held
song_urgent_done                ; (song_urgent, then the key done)
        jsr song_urgent
song_key_done
        lda #0
        sec
        rts
song_cursor_repeat              ; (song_urgent_cursor, then the key may repeat)
        jsr song_urgent_cursor
        jmp song_key_repeat
song_urgent_repeat              ; (song_urgent, then the key may repeat)
        jsr song_urgent
song_key_repeat
        lda #1
        sec
        rts

; the keys and their routines (as rts addresses: the routine - 1)
song_key_codes  .byte KEY_CRSR_RIGHT, KEY_CRSR_DOWN, KEY_LEFT_ARROW, KEY_PLUS
                .byte KEY_MINUS, KEY_DEL, KEY_M, KEY_S, KEY_F7, KEY_RETURN
SONG_KEY_COUNT  = * - song_key_codes
song_key_lo     .byte <song_key_right-1, <song_key_down-1, <song_key_flip-1, <song_key_plus-1
                .byte <song_key_minus-1, <song_key_del-1, <song_key_mute-1, <song_key_solo-1
                .byte <song_key_f7-1, <song_key_return-1
song_key_hi     .byte >song_key_right-1, >song_key_down-1, >song_key_flip-1, >song_key_plus-1
                .byte >song_key_minus-1, >song_key_del-1, >song_key_mute-1, >song_key_solo-1
                .byte >song_key_f7-1, >song_key_return-1
        .cerror song_key_hi - song_key_lo != SONG_KEY_COUNT, "a routine for each key"

; song_key_right - CRSR right (SHIFT: left): the next track, past the 8th
; to the other half, past the 16th to the first
song_key_right
        jsr song_urgent_cursor  ; (the old cursor's row: its cell plain again)
        ldx song_cursor
        lda shift_held
        bne _left
        inx
        cpx #NUM_TRACKS
        bcc _moved
        ldx #0
        beq _moved
_left   dex
        bpl _moved
        ldx #NUM_TRACKS-1
_moved  txa                     ; the other half now? (the half's bit changed)
        eor song_cursor
        stx song_cursor
        and #SONG_TRACKS
        beq +
        jsr song_half_changed
+       jmp song_cursor_repeat

; song_key_flip - left-arrow: the other half, the cursor on its track there
song_key_flip
        lda song_cursor
        eor #SONG_TRACKS
        sta song_cursor
        jsr song_half_changed
        jsr song_urgent_cursor
        jmp song_key_done

; song_key_down - CRSR down (SHIFT: up): the next scene (none past the
; first or the last), the scenes scrolled to keep it shown
song_key_down
        jsr song_grid_clean     ; (before this key marks anything)
        lda #0
        rol
        sta song_shift_ok
        ; the cursor as shown: its cell put back plain in the same moment as
        ; the new row is drawn (two rows drawn apart showed two cursors, or
        ; none, for a frame: tools/flash_check.py)
        lda song_old_row
        bpl +                   ; (a move not yet drawn: that place still shown)
        jsr song_cursor_screen
        stx song_old_row
        lda song_cursor
        and #SONG_TRACKS-1
        asl
        asl
        adc #SONG_CELL_COL0     ; (carry clear)
        sta song_old_col
        jsr song_dirty_row      ; (drawn again later: the same then)
+       ldx song_row
        lda shift_held
        bne _up
        inx
        cpx #NUM_SCENES
        bcs _done               ; (the last already)
        bcc _moved
_up     dex
        bmi _done               ; (the first already)
_moved  stx song_row
        ; shown? else scrolled, the cursor's scene at the top or the bottom
        cpx song_top
        bcs _below
        stx song_top            ; above the first shown: at the top
        lda #SHIFT_DOWN
        jsr song_shift_begin
        jmp _done
_below  txa
        sec
        sbc song_top
        cmp #SONG_ROWS
        bcc _done               ; (shown)
        txa                     ; below the last shown: at the bottom
        sbc #SONG_ROWS-1        ; (carry set)
        sta song_top
        lda #SHIFT_UP
        jsr song_shift_begin
_done   jsr song_cursor_screen  ; on the old cursor's row still (a scroll, or no move):
        cpx song_old_row        ; that row drawn whole, nothing to put back
        bne +
        lda #$ff
        sta song_old_row
+       jmp song_cursor_repeat

; song_key_plus / song_key_minus - + / -: the cell's next / previous
; pattern number, round through none (none, 1, 2 ... 128, none; stored as
; 0-127 and NO_PATTERN). song_key_del - DEL: none.
song_key_plus
        jsr song_cell_read
        clc
        adc #1                  ; (none, $FF, + 1: pattern 1's 0)
        cmp #NUM_PATTERNS
        bcc +
        lda #NO_PATTERN         ; (past 128)
+       jmp song_cell_changed
song_key_minus
        jsr song_cell_read
        cmp #NO_PATTERN
        bne +
        lda #NUM_PATTERNS       ; (none - 1: pattern 128's 127)
+       sec
        sbc #1                  ; (pattern 1's 0 - 1: none, $FF)
        jmp song_cell_changed
song_key_del
        lda #NO_PATTERN
        jsr song_cell_write
        jsr song_urgent_cursor
        jmp song_key_done

; song_cell_changed - (+, -) A into the cursor's cell, its row urgent, the
; key repeating
song_cell_changed
        jsr song_cell_write
        jmp song_cursor_repeat

; song_key_mute / song_key_solo - M / S: the cursor's track muted or soloed
; (or no longer), what the player reads updated (tracks_quiet: heard
; within the lead); the track's colour changes in every row
song_key_mute
        ldx song_cursor
        lda TRACK_MUTE,x
        eor #1
        sta TRACK_MUTE,x
        jmp song_quiet_changed
song_key_solo
        ldx song_cursor
        lda TRACK_SOLO,x
        eor #1
        sta TRACK_SOLO,x
song_quiet_changed
        jsr tracks_quiet
        jsr song_colours_changed ; (the scene rows' colours: a column at a time)
        ldx #SONG_HEAD_ROW      ; the header: its flags and colours
        jsr song_urgent_row
        jmp song_key_done

; song_key_return - RETURN: the cursor's cell's pattern on the step grid
; (grid.asm)
song_key_return
        lda rec_state           ; (not during a take: its table)
        bne +
        jsr grid_open
+       jmp song_key_done

; song_key_f7 - F7: back to the parameter screen
song_key_f7
        jsr song_leave
        jmp song_key_done

; -----------------------------------------------------------------------------
; song_cell_read / song_cell_write - the cursor's cell (scene song_row,
; track song_cursor) in SCENES: A = it / A into it.
; clobbers X, Y (and A, read)
; -----------------------------------------------------------------------------
song_cell_read
        ldx song_row
        jsr song_scene_at
        ldy song_cursor
        lda (song_scene_ptr),y
        rts
                                ; (song_cell_write: grid.asm, out of the live
                                ; reader's way)

; song_scene_at - song_scene_ptr = scene X's row in SCENES (SCENES + X *
; 16; read with Y = a track). clobbers A; keeps X, Y
song_scene_at
        txa                     ; the low byte: (X & 15) * 16
        asl
        asl
        asl
        asl
        sta song_scene_ptr
        txa                     ; the high byte: SCENES' + X / 16
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>SCENES
        sta song_scene_ptr+1
        rts
        .cerror (SCENES & $ff) != 0, "SCENES must start a page"

; =============================================================================
; Which rows to draw
; =============================================================================

; song_row_bit - row X's place in the bitmaps: Y = its byte, A = its bit.
; keeps X
song_row_bit
        txa
        lsr
        lsr
        lsr
        sta song_bit_byte
        txa
        and #7
        tay
        lda song_bits,y
        ldy song_bit_byte
        rts

; song_urgent_row - row X to draw first (urgent, and so dirty). song_dirty_row
; - row X to draw. clobbers A, Y; keeps X
song_urgent_row
        jsr song_row_bit
        ldy #$ff                ; (what is prepared may be old now)
        sty song_ready_row
        ldy song_bit_byte
        pha
        ora song_urgent_rows,y
        sta song_urgent_rows,y
        pla
        jmp +
song_dirty_row
        jsr song_row_bit
        ldy #$ff
        sty song_ready_row
        ldy song_bit_byte
+       ora song_dirty_rows,y
        sta song_dirty_rows,y
        rts

; song_cursor_screen - X = the cursor's scene's row on the screen; carry
; set: not shown (never, once song_key_down has scrolled). clobbers A
song_cursor_screen
        lda song_mode
        beq +
        jmp list_cursor_screen  ; (the step grid's: list.asm, else grid_cursor_screen)
+       lda song_row
        sec
        sbc song_top
        cmp #SONG_ROWS
        bcs +
        adc #SONG_GRID_ROW      ; (carry clear)
        tax
        clc
+       rts

; song_urgent_cursor - the cursor's row to draw first (a key's effect).
; clobbers A, X, Y
song_urgent_cursor
        jsr song_cursor_screen
        bcc song_urgent_row
+       rts

; song_dirty_grid - the header and every scene row to draw (a scroll, a
; mute or solo: every row's colours). clobbers A
song_dirty_grid
        lda #0                  ; (every row drawn afresh: no copying)
        sta song_shift
        lda #$ff                ; (what is prepared may be old now)
        sta song_ready_row
        lda song_dirty_rows     ; rows 2-7
        ora #%11111100
        sta song_dirty_rows
        lda #$ff                ; rows 8-23
        sta song_dirty_rows+1
        sta song_dirty_rows+2
        lda song_dirty_rows+3   ; row 24
        ora #%00000001
        sta song_dirty_rows+3
        rts
        .cerror SONG_HEAD_ROW != 2 || SONG_GRID_ROW + SONG_ROWS != SCREEN_ROWS, "song_dirty_grid's rows"

; song_half_changed - the other half shown: the title (its half), the
; header and every scene row to draw. clobbers A, X, Y
song_half_changed
        jsr song_colours_reset
        jsr song_dirty_grid
        ldx #SONG_TITLE_ROW
        jmp song_dirty_row

; -----------------------------------------------------------------------------
; song_state_check - the title's play or stop (as asked: a start or
; continue being done shows PLAY at once, not ~80 ms later when done) and
; tempo as they are now: if either changed, the title is urgent (and the
; playing scene's mark to draw).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_state_check
        lda play_state
        cmp #PLAY_STARTING
        beq _play
        cmp #PLAY_RUNNING
        beq _play
        cmp #PLAY_HELD
        bne _stop
        lda transport_req       ; (held: a start or continue asked, master
        ora slave_req           ; or slave)
        beq _stop
_play   lda #1
        ldx rec_state           ; (a take: REC)
        beq song_state_set
        lda #2
        bne song_state_set
_stop   lda #0
song_state_set                  ; (count.asm count_state_check: A = the state to show)
        cmp song_shown_state
        beq _tempo
        sta song_shown_state
        ldx #SONG_TITLE_ROW
        jsr song_urgent_row
        lda song_mode
        bne _tempo              ; (the step grid: no scenes shown)
        lda play_scene1         ; the playing scene's mark (scene.asm: its number,
        clc                     ; so less one more)
        sbc song_top
        cmp #SONG_ROWS
        bcs _tempo              ; (not shown)
        adc #SONG_GRID_ROW
        tax
        jsr song_dirty_row
_tempo  lda params+P_TEMPO
        cmp song_shown_tempo
        beq +
        sta song_shown_tempo
        ldx #SONG_TITLE_ROW
        jsr song_urgent_row
+       rts

; =============================================================================
; Drawing
; =============================================================================

; -----------------------------------------------------------------------------
; synth_draw_step - core hook (SYNTH_SCREEN; the main loop idle, or at a key
; scan): a row of the song screen, an urgent one first, else any to draw.
; song_urgent - (synth_tick: every 250 Hz tick) an urgent row, else a
; dirty one if the tick has time left: under load the main loop is never
; idle, and its scans every 4 ticks fall at nearly the same place of the
; frame, so a row the beam was near could wait several scans; consecutive
; ticks fall a fifth of a frame apart.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_draw_step
        jsr count_state_check   ; (count.asm: REC during a count-in)
        lda #SEL_URGENT
        jsr song_draw_from
        bcs +                   ; (one drawn)
        jsr song_shift_step
        bcs +                   ; (a row copied)
        jsr song_recolour_step
        bcs +                   ; (a column recoloured)
        lda #SEL_DIRTY
        jmp song_draw_from
+       rts

SONG_DIRTY_SPARE_HI = 10        ; timer B's high byte: a dirty row too with more than
                                ; 10 * 256 cycles of the tick left (prepare and put)
song_urgent
        lda screen_owner
        beq _done
        jsr count_state_check   ; (count.asm: REC during a count-in)
        lda #SEL_URGENT
        jsr song_draw_from
        bcc +                   ; (one drawn)
        lda song_mode           ; the step grid: a second in the same tick (an edit's
        beq _done               ; two rows, the moved cursor's and the edited step's:
        lda #SEL_URGENT         ; the second a tick later made notes ~1.3 frames late)
        jmp song_draw_from
+       jsr song_shift_step
        bcs _done               ; (a row copied)
        jsr song_recolour_step
        bcs _done               ; (a column recoloured)
        lda tick_count          ; time left in this tick: a dirty row (a half's
        cmp tick_done           ; flip or a scroll redrawn at half the wire took
        bne _done               ; ~1 s at a row a key scan: tools/flash_check.py)
        lda CIA1_TB_HI
        cmp #SONG_DIRTY_SPARE_HI
        bcc _done
        lda #SEL_DIRTY
        jmp song_draw_from
_done   rts

; -----------------------------------------------------------------------------
; song_draw_from - a row from bitmap A (SEL_URGENT or SEL_DIRTY), drawn if
; the beam allows: the cursor's row first, else the first marked one now
; safe. Each candidate looked at with row_safe, prepared aside, looked at
; again (preparing a scene row takes a while), then put. Its bits in both
; bitmaps cleared. Carry set: a row drawn.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_draw_from
        sta song_sel
        ; none marked: nothing to do (the usual case, every 250 Hz tick)
        tay
        lda song_urgent_rows,y
        ora song_urgent_rows+1,y
        ora song_urgent_rows+2,y
        ora song_urgent_rows+3,y
        beq _none
        ; the cursor's row first
        jsr song_cursor_screen
        bcs _scan
        jsr _try
        bcs _done
        ; then the others, from the top, a byte of the bitmap without any
        ; skipped whole
_scan   ldx #0
_row    txa
        and #7
        bne _bit                ; (within a byte: looked at already)
        txa
        lsr
        lsr
        lsr
        clc
        adc song_sel
        tay
        lda song_urgent_rows,y
        bne _bit
        txa                     ; (none in it: the next byte's first row)
        clc
        adc #8
        tax
        bne _more
_bit    jsr _try
        bcs _done
        inx
_more   cpx #SCREEN_ROWS
        bcc _row
_none   clc                     ; (none drawn)
_done   rts
; _try - row X if it is marked and the beam allows: drawn, carry set; else
; carry clear. keeps X when not drawn
_try    jsr song_row_bit
        pha
        tya
        clc
        adc song_sel
        tay
        pla
        and song_urgent_rows,y  ; (+ song_sel: the bitmap)
        bne +
        clc                     ; (not marked)
        rts
+       stx song_draw_row
        cpx song_old_row
        bne +
        clc                     ; (the old cursor's row: with the new one, song_pair_prep)
        rts
+
        lda song_shift
        beq +
        cpx #SONG_GRID_ROW      ; a scroll's copying under way: no scene row but the
        bcc +                   ; cursor's (the rows still to copy from must be as
        stx song_bit_byte       ; they were; one drawn now would be copied after)
        jsr song_cursor_screen
        txa
        ldx song_bit_byte
        cmp song_bit_byte
        bne _no
+
        lda song_sel
        bne _dirty
        ; urgent (a key's effect): prepared, then put as soon as the beam
        ; is past it. Under load the main loop runs only in short gaps
        ; between the timer's renders, and a row left for later missed
        ; them: keys took 44-93 ms at half the wire. The wait is at most
        ; the window, 42 lines (~2,600 cycles), and only song_put_line's,
        ; after it has found the cells that differ (waiting here too, the
        ; ~1,000 cycles of finding them let the beam come near again: a
        ; second wait, ~4,000 cycles of a note's ~10,000 on the step grid)
        cpx song_ready_row
        beq _put
        jsr names_prepare       ; (names.asm: song_prepare, the header's synths)
        ldx song_draw_row
        stx song_ready_row
        jmp _put
        ; the rest: only if the beam allows now, and still after preparing
_dirty  jsr song_row_far        ; (room to prepare and compare first: else the rows
        bcc _no                 ; just below the beam were prepared, then too near,
        jsr song_pair_safe      ; and the scan rode along with the beam: a scroll
        bcc _no                 ; took 13 frames)
        cpx song_ready_row
        beq _put                ; (prepared already, nothing changed since)
        jsr names_prepare       ; (names.asm: song_prepare, the header's synths)
        ldx song_draw_row
        stx song_ready_row      ; (kept, if the beam comes too near now)
        jsr song_pair_safe      ; (still?)
        bcc _no
_put    jsr song_pair_prep
        lda song_put_pair       ; (with the old cursor's row: its listed cells after)
        sta song_more_go
        jsr song_put_line
        bcc _no                 ; (a dirty row the beam came near: later, kept prepared)
        jsr song_more_put
        lda #$ff
        sta song_ready_row
        ; drawn: its bits cleared in both bitmaps
        ldx song_draw_row
        jsr song_row_bit
        eor #$ff
        pha
        and song_urgent_rows,y
        sta song_urgent_rows,y
        pla
        and song_dirty_rows,y
        sta song_dirty_rows,y
.if TEST_LOG
        jsr song_log_drawn      ; (tests: what was drawn)
.endif
        sec
        rts
_no     clc
        rts

; -----------------------------------------------------------------------------
; song_pair_safe - may row X be put now: song_row_safe, and for the
; cursor's row after a move up or down, the old cursor's row too (both
; rows then change in the same frame: the beam neither on nor near
; either, nor between them, the windows of rows less than 4 apart
; overlapping). Carry set: yes. clobbers A; keeps X, Y
; -----------------------------------------------------------------------------
song_pair_safe
        jsr song_row_safe
        bcc _no
        lda song_old_row
        bmi _yes                ; (no move pending)
        stx song_bit_byte
        jsr song_cursor_screen
        txa
        ldx song_bit_byte
        cmp song_bit_byte
        bne _yes                ; (not the cursor's row)
        ldx song_old_row
        jsr song_row_safe
        ldx song_bit_byte
        rts
_yes    sec
_no     rts

; song_pair_prep - (row X about to be put) the cursor's row, a move up or
; down pending on another row: the old cursor's cell's address made ready
; (song_pair_cell's operands), so song_put_line puts it back plain with
; the new cursor's cells, interrupts off throughout (put apart, an
; interrupt between them let the beam show two cursors). The move done.
; clobbers A; keeps X
song_pair_prep
        lda #0
        sta song_put_pair
        lda song_old_row
        bmi _done
        stx song_bit_byte
        jsr song_cursor_screen
        txa
        ldx song_bit_byte
        cmp song_bit_byte
        bne _done               ; (not the cursor's row)
        cpx song_old_row
        beq _same               ; (the same row: drawn whole, the new cursor in it)
        ldx song_old_row
        lda row_lo,x
        clc
        adc song_old_col
        sta _cell_lo
        sta song_pair_cell._b + 1
        lda row_hi,x
        adc #0
        sta _cell_hi
        sta song_pair_cell._b + 2
        lda song_old_row
        sta song_pair_row
        ldx song_bit_byte
        lda #1
        sta song_put_pair
_same   lda #$ff
        sta song_old_row
_done   rts
_cell_lo = song_pair_cell._a + 1
_cell_hi = song_pair_cell._a + 2

; song_pair_cell - (interrupts off) the old cursor's cell put back plain,
; if song_pair_prep made it ready. clobbers A, Y
song_pair_cell .proc
        lda song_put_pair
        beq _done
        ldy #2
_a      lda $ffff,y             ; (the cell's address: song_pair_prep)
        and #$ff-CHAR_REVERSE
_b      sta $ffff,y
        dey
        bpl _a
        lda #0
        sta song_put_pair
_done   rts
        .pend

; -----------------------------------------------------------------------------
; song_more_take - (the step grid) row X prepared now and the cells that
; differ from the screen listed, to be put right after the next urgent
; row (song_more_put): one wait for the beam for both. A nonzero: the old
; cursor's row after a move (prepared without the cursor), put only with
; the cursor's row and its pair; 0: after any urgent row, if the beam
; allows (else marked urgent then). A list already waiting (no draw
; since): row X urgent instead.
; clobbers A, X, Y, ptr, cptr
; -----------------------------------------------------------------------------
song_more_take
        ldy song_more_n
        beq +
        jmp song_urgent_row
+       sta song_more_pair
        stx song_more_row
        jsr names_prepare       ; (names.asm: song_prepare, the header's synths)
        lda #$ff                ; (song_line used)
        sta song_ready_row
        ldx song_more_row
        jsr set_row_ptr
        ldx #0
        ldy #39
_cell   lda song_line,y
        cmp (ptr),y
        bne _diff
        lda song_line_col,y
        eor (cptr),y
        and #$0f                ; (colour RAM: the low nibble only)
        beq _next
_diff   tya
        sta song_more_pos,x
        lda song_line,y
        sta song_more_chr,x
        lda song_line_col,y
        sta song_more_col,x
        inx
_next   dey
        bpl _cell
        stx song_more_n
        rts

; song_more_put - (a row just put) the list of song_more_take put onto its
; row: with the pair, if that row's pair was in this put (its old cursor
; put back plain in the same moment), else kept; without, if the beam
; allows, else the row marked urgent (drawn as any). Each cell's
; character and colour together, interrupts off between them; its row's
; bits cleared (drawn).
; clobbers A, Y, ptr, cptr; keeps X
song_more_put
        lda song_more_n
        beq _done
        stx song_put_x
        lda song_more_pair
        beq _free
        lda song_more_go
        beq _keep
        lda song_pair_row
        cmp song_more_row
        bne _keep
        beq _put
_free   ldx song_more_row       ; the beam near: drawn as an urgent row instead
        jsr song_row_safe
        bcs _put
        lda #0
        sta song_more_n
        jsr song_urgent_row
_keep   ldx song_put_x
        rts
_put
        ldx song_more_row
        jsr set_row_ptr
        ldx song_more_n
-       ldy song_more_pos-1,x
        sei
        lda song_more_chr-1,x
        sta (ptr),y
        lda song_more_col-1,x
        sta (cptr),y
        cli
        dex
        bne -
        stx song_more_n         ; (0)
        ldx song_more_row       ; drawn: no need to again
        jsr song_row_bit
        eor #$ff
        pha
        and song_urgent_rows,y
        sta song_urgent_rows,y
        pla
        and song_dirty_rows,y
        sta song_dirty_rows,y
        ldx song_put_x
_done   rts

; -----------------------------------------------------------------------------
; song_row_safe - may screen row X be put now? As the core's row_safe (the
; beam neither on the row nor less than a margin above it), with the song
; screen's own margin: its rows are prepared aside, so drawing one is only
; song_put_line (~1,200 cycles, 19 lines; SONG_SAFE_LINES leaves room for
; the transmit interrupts meanwhile). The core's 72 lines kept each row
; out of bounds for a quarter of the frame, so a key's cell often waited
; a tick or two. An interrupt that stretches a put past the beam (the
; timer's rendering a busy tick) shows the row half old, half new for a
; frame, every cell whole (song_put_line).
; Carry set: yes. clobbers A; keeps X, Y
; -----------------------------------------------------------------------------
SONG_SAFE_LINES = 32
SONG_WINDOW_HALVES = (SONG_SAFE_LINES + 8) / 2 + 1 ; (as the core's WINDOW_HALVES)
song_row_safe
        ; the beam's line / 2 (as row_safe: bit 8 read again if it changed)
-       lda VIC_CTRL1
        and #$80
        sta row_beam
        lda BEAM_LINE
        lsr
        ora row_beam
        sta row_beam
        lda VIC_CTRL1
        and #$80
        eor row_beam
        bmi -
        ; its distance past the row's window's start, mod HALF_LINES
        lda row_beam
        sec
        sbc song_row_window,x
        bcs +
        adc #HALF_LINES
+       cmp #SONG_WINDOW_HALVES ; carry set: past the window, safe
        rts

; song_row_far - as song_row_safe, with FAR_HALVES * 2 more lines before
; the window: room to prepare a row and compare it first (~2,200 cycles).
; Carry set: yes. clobbers A; keeps X, Y
FAR_HALVES      = 20
song_row_far
        jsr song_row_safe       ; (A: the beam's distance past the window's start)
        bcc _no                 ; (in the window)
        cmp #HALF_LINES - FAR_HALVES
        bcs _no                 ; (less than FAR_HALVES before it)
        sec
        rts
_no     clc
        rts

; each screen row's unsafe window's start, in lines / 2
song_row_window
        .for _row := 0, _row < SCREEN_ROWS, _row += 1
        .byte ((RASTER_ROW0 + _row * 8) / 2 - SONG_SAFE_LINES / 2 + HALF_LINES) % HALF_LINES
        .endfor

; -----------------------------------------------------------------------------
; song_prepare - row X prepared aside (song_line, song_line_col): the
; title, the header, a scene's row, else blank.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_prepare_base               ; (scene.asm song_prepare first: row 1)
        lda song_mode
        beq +
        jmp list_prepare        ; (the step grid's rows: list.asm, else grid_prepare)
+       cpx #SONG_TITLE_ROW
        beq song_title_line
        cpx #SONG_HEAD_ROW
        beq song_head_line
+
        cpx #SONG_GRID_ROW
        bcc song_blank_line
        txa                     ; the scene shown there
        clc
        adc song_top
        sec
        sbc #SONG_GRID_ROW
        cmp #NUM_SCENES
        bcs song_blank_line
        jmp song_scene_line

; song_blank_line - a blank row prepared. clobbers A, Y; keeps X
song_blank_line
        lda #LINE_OTHER
        sta song_line_kind
        ldy #39
-       lda #CHAR_SPACE
        sta song_line,y
        lda #COL_LABEL
        sta song_line_col,y
        dey
        bpl -
        rts

; -----------------------------------------------------------------------------
; song_title_line - the title prepared: "SONG  SCENE 01  BPM 120 001.1  0:00
; STOP", the scene playing, the tempo, the song's bar.beat and m:ss
; (clock.asm) and play or stop as shown.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_title_line
        lda #LINE_OTHER
        sta song_line_kind
        lda #COL_SONG_TITLE
        ldx #<song_title_text
        ldy #>song_title_text
        jsr line_text
        lda play_scene1         ; (the scene playing: scene.asm)
        ldy #SONG_TITLE_SCENE
        jsr song_num2
        ; the tempo, 40-240 BPM: the parameter + BPM_LOWEST
        lda song_shown_tempo
        clc
        adc #BPM_LOWEST
        ldy #SONG_TITLE_TEMPO
        jsr song_num3
        ldx #CK_TEXT_LEN-1      ; the song's bar.beat and m:ss (clock.asm)
-       lda ck_text,x
        sta song_line+SONG_TITLE_CLOCK,x
        dex
        bpl -
        lda ck_ver              ; (as prepared: clock_check)
        sta ck_drawn
        lda song_shown_state
        asl
        asl
        tax
        ldy #0
-       lda song_state_text,x
        sta song_line+SONG_TITLE_STATE,y
        inx
        iny
        cpy #4
        bne -
        rts

; -----------------------------------------------------------------------------
; song_head_line - the header prepared: the half's track numbers, each in
; its track's colour (song_track_colour), M after a muted one, S after a
; soloed one.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_head_line
        lda #LINE_OTHER
        sta song_line_kind
        jsr song_line_ends
        jsr song_cells_begin
_cell   jsr song_cell_begin     ; (Y = its column, X = its track)
        ; the flag after it
        lda #CHAR_SPACE
        ldy TRACK_SOLO,x
        beq +
        lda #CHAR_S
+       ldy TRACK_MUTE,x
        beq +
        lda #CHAR_M
+       ldy song_col
        sta song_line+SONG_FLAG_COL,y
        ; the track's number, 1-16
        inx
        txa
        jsr song_cell_text
        jsr song_cell_next
        bne _cell
        rts

; -----------------------------------------------------------------------------
; song_scene_line - scene A's row prepared: its number, ">" at the playing
; scene while playing, the half's 8 cells: each its pattern's number
; (right-aligned, 1-128) or "--", the cursor's reversed. The colours are
; every scene row's (song_scene_colours, built once a change: each cell
; in its track's colour), but the mark's. ~700 cycles.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_scene_line_base            ; (scene.asm song_scene_line after: the marks)
        sta song_line_scene
        lda song_line_kind
        cmp #LINE_SCENE
        beq +
        jsr song_scene_colours
+       ; the ends blank
        lda #CHAR_SPACE
        ldy #SONG_CELL_COL0-1
-       sta song_line,y
        dey
        bpl -
        ldy #39
-       sta song_line,y
        dey
        cpy #SONG_CELLS_END
        bcs -
        ; its number, 01-64
        lda song_line_scene
        clc
        adc #1
        ldy #SONG_SCENE_COL
        jsr song_num2
        ; the playing scene's mark (its colour too)
        lda #COL_LABEL
        ldx song_line_scene
        cpx play_scene1         ; (scene.asm; edit, grid: a hint only, song.asm's mark: set by scene.asm)
        bne +
        ldx song_shown_state
        beq +
        lda #CHAR_MARK
        sta song_line+SONG_MARK_COL
        lda #COL_SONG_TITLE
+       sta song_line_col+SONG_MARK_COL
        ldx song_line_scene
        jsr song_scene_at
        ; the cursor's cell's column in this row ($FF: not in it)
        lda song_cursor
        and #SONG_TRACKS
        sta song_half
        ldx #$ff
        lda song_line_scene
        cmp song_row
        bne +
        lda song_cursor
        and #SONG_TRACKS-1
        asl
        asl
        adc #SONG_CELL_COL0     ; (carry clear)
        tax
+       stx song_cur_col
        ; the cells: X its column, Y its track (the numbers' texts under I/O)
        lda #RAM_ALL
        sta $01
        ldx #SONG_CELL_COL0
        ldy song_half
_cell   lda (song_scene_ptr),y
        sty song_track
        tay
        iny                     ; (stored 0-127 or NO_PATTERN: text 1-128, 0 = none)
        lda song_num_c0,y
        sta song_line,x
        lda song_num_c1,y
        sta song_line+1,x
        lda song_num_c2,y
        sta song_line+2,x
        lda #CHAR_SPACE
        sta song_line+3,x
        ldy song_track
        iny
        txa
        clc
        adc #SONG_CELL_WIDTH
        tax
        cpx #SONG_CELLS_END
        bcc _cell
        lda #RAM_IO
        sta $01
        ; the cursor's cell reversed
        ldx song_cur_col
        bmi +
        lda song_line,x
        ora #CHAR_REVERSE
        sta song_line,x
        lda song_line+1,x
        ora #CHAR_REVERSE
        sta song_line+1,x
        lda song_line+2,x
        ora #CHAR_REVERSE
        sta song_line+2,x
+       rts

; song_scene_colours - song_line_col: every scene row's colours (the ends
; grey, each cell in its track's colour); LINE_SCENE. clobbers A, X, Y
song_scene_colours
        jsr song_line_ends      ; (and its characters: written over after)
        jsr song_cells_begin
-       jsr song_cell_begin
        jsr song_cell_next
        bne -
        lda #LINE_SCENE
        sta song_line_kind
        rts

; -----------------------------------------------------------------------------
; song_grid_clean - every scene row on the screen as it should be: none
; marked, no move's old cursor pending, no column to recolour, no copying
; under way. Carry set: yes. clobbers A
; -----------------------------------------------------------------------------
song_grid_clean
        lda song_dirty_rows     ; rows 3-7
        and #%11111000
        ora song_dirty_rows+1   ; rows 8-23
        ora song_dirty_rows+2
        ora song_recolour
        ora song_shift
        bne _no
        lda song_dirty_rows+3   ; row 24
        and #%00000001
        bne _no
        lda song_old_row
        bpl _no
        sec
        rts
_no     clc
        rts

; -----------------------------------------------------------------------------
; song_shift_begin - (a scroll by one: song_top moved) A = SHIFT_UP or
; SHIFT_DOWN: with every scene row as it should be before the key, the
; rows are copied a row up or down (song_shift_step, ~900 cycles a row)
; instead of each drawn again (~4,000: a scroll took 9-30 frames); the
; row leaving under the cursor (the last or the first) saved first, its
; cursor's cell plain, to go to the row next to it, so the cursor's row
; can be drawn at once (urgent). Otherwise every row drawn again.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_shift_begin
        ldx song_shift_ok
        bne +
        jmp song_dirty_grid
+       sta song_shift
        ldx #SCREEN_ROWS-1      ; up: the last row saved, rows 3-23 copied from below
        lda #SONG_GRID_ROW      ; (top down)
        ldy song_shift
        cpy #SHIFT_UP
        beq +
        ldx #SONG_GRID_ROW      ; down: the first row saved, rows 24-4 copied from
        lda #SCREEN_ROWS-1      ; above (bottom up)
+       sta song_shift_row
        ; the row saved, characters and colours
        jsr set_row_ptr
        ldy #39
-       lda (ptr),y
        sta song_shift_buf,y
        lda (cptr),y
        sta song_shift_buf+40,y
        dey
        bpl -
        ; its cursor's cell plain
        lda song_cursor
        and #SONG_TRACKS-1
        asl
        asl
        adc #SONG_CELL_COL0     ; (carry clear)
        tay
        ldx #3
-       lda song_shift_buf,y
        and #$ff-CHAR_REVERSE
        sta song_shift_buf,y
        iny
        dex
        bne -
        lda #$ff                ; (a row prepared aside may be old now)
        sta song_ready_row
        rts

; -----------------------------------------------------------------------------
; song_shift_step - a scroll's next row copied: from the row below (up) or
; above (down), the saved row for the last one. Carry set: one copied.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_shift_step
        lda song_shift
        bne +
        clc
        rts
+       ldx song_shift_row      ; the row copied into
        cmp #SHIFT_UP
        bne _down
        cpx #SCREEN_ROWS-2
        beq _saved              ; (the last: from the saved row)
        inx                     ; from the row below
        jsr _from_row
        dex
        inc song_shift_row
        jmp _copy
_down   cpx #SONG_GRID_ROW+1
        beq _saved              ; (the last: from the saved row)
        dex                     ; from the row above
        jsr _from_row
        inx
        dec song_shift_row
        jmp _copy
_saved  lda #<song_shift_buf
        sta _src+1
        lda #>song_shift_buf
        sta _src+2
        lda #<song_shift_buf+40
        sta _src_col+1
        lda #>song_shift_buf+40
        sta _src_col+2
        lda #0                  ; (the last: done)
        sta song_shift
        ; row X from the source: each cell's colour, then its character
_copy   lda row_lo,x
        sta _dst+1
        sta _dst_col+1
        lda row_hi,x
        sta _dst+2
        clc
        adc #>(COLOR_RAM-SCREEN)
        sta _dst_col+2
        ldy #39
_src_col lda $ffff,y
_dst_col sta $ffff,y
_src    lda $ffff,y
_dst    sta $ffff,y
        dey
        bpl _src_col
        sec
        rts
        ; the source: screen row X (keeps X)
_from_row
        lda row_lo,x
        sta _src+1
        sta _src_col+1
        lda row_hi,x
        sta _src+2
        clc
        adc #>(COLOR_RAM-SCREEN)
        sta _src_col+2
        rts

; song_shift_buf - the row a scroll moves out from under the cursor:
; characters, then colours
song_shift_buf  .fill 80

; -----------------------------------------------------------------------------
; song_colours_reset - (the half shown changed, the screen taken) the
; shown columns' colours as the tracks' now, nothing to recolour (every
; row drawn afresh); the scene rows' colours to build again.
; song_colours_changed - (a mute, a solo) the columns whose track's
; colour changed marked to recolour (song_recolour_step: a column's 88
; colour cells written straight, ~1,100 cycles, not 22 rows prepared and
; compared, ~5,000 cycles each); the scene rows' colours to build again.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_colours_reset
        lda #0
        sta song_recolour
song_colours_changed
        lda #LINE_OTHER         ; (the template, and a row prepared, are old now)
        sta song_line_kind
        lda #$ff
        sta song_ready_row
        lda song_cursor
        and #SONG_TRACKS
        sta song_half
        ldx #SONG_TRACKS-1
-       stx song_cell
        txa
        ora song_half
        tax
        jsr song_track_colour   ; (clobbers Y)
        ldx song_cell
        cmp song_col_colour,x
        beq +
        sta song_col_colour,x
        lda song_bits,x         ; this column to recolour
        ora song_recolour
        sta song_recolour
+       dex
        bpl -
        rts

; song_recolour_step - a column marked to recolour: its colour written to
; its 4 places in every scene row (the cursor's cell too). Carry set: one
; done. clobbers A, X, Y, cptr
song_recolour_step
        lda song_shift
        bne _none               ; (a scroll's copying first)
        lda song_recolour
        beq _none
        ldx #0                  ; the lowest marked
-       lsr
        bcs +
        inx
        bne -
+       lda song_bits,x
        eor #$ff
        and song_recolour
        sta song_recolour
        lda song_col_colour,x
        sta song_digits         ; (its colour)
        txa
        asl
        asl
        adc #SONG_CELL_COL0     ; (carry clear)
        sta song_col
        ldx #SONG_GRID_ROW
-       lda row_lo,x
        clc
        adc song_col
        sta cptr
        lda row_hi,x
        adc #>(COLOR_RAM-SCREEN)
        sta cptr+1
        lda song_digits
        ldy #3
        sta (cptr),y
        dey
        sta (cptr),y
        dey
        sta (cptr),y
        dey
        sta (cptr),y
        inx
        cpx #SCREEN_ROWS
        bne -
        sec
        rts
_none   clc
        rts

; song_line_ends - the columns around the cells blank (0-4, 37-39).
; clobbers A, Y
SONG_CELLS_END  = SONG_CELL_COL0 + SONG_TRACKS * SONG_CELL_WIDTH
song_line_ends
        ldy #SONG_CELL_COL0-1
-       lda #CHAR_SPACE
        sta song_line,y
        lda #COL_LABEL
        sta song_line_col,y
        dey
        bpl -
        ldy #39
-       lda #CHAR_SPACE
        sta song_line,y
        lda #COL_LABEL
        sta song_line_col,y
        dey
        cpy #SONG_CELLS_END
        bcs -
        rts

; song_cells_begin - the cells from the first of the cursor's half.
; clobbers A
song_cells_begin
        lda song_cursor
        and #SONG_TRACKS
        sta song_half
        lda #0
        sta song_cell
        rts

; song_cell_begin - cell song_cell: song_track, song_col; its 4 places'
; colour (song_track_colour), its gap blank. Y = its column, X = its
; track. clobbers A
song_cell_begin
        lda song_cell
        ora song_half
        sta song_track
        tax
        jsr song_track_colour
        pha
        lda song_cell
        asl
        asl
        adc #SONG_CELL_COL0     ; (carry clear: below 32)
        sta song_col
        tay
        pla
        sta song_line_col,y
        sta song_line_col+1,y
        sta song_line_col+2,y
        sta song_line_col+3,y
        lda #CHAR_SPACE
        sta song_line+3,y
        rts

; song_cell_text - number A's text (0: " --", 1-128 right-aligned) into
; the 3 places at song_line + Y (the tables under I/O). clobbers A, X; keeps Y
song_cell_text
        tax
        lda #RAM_ALL
        sta $01
        lda song_num_c0,x
        sta song_line,y
        lda song_num_c1,x
        sta song_line+1,y
        lda song_num_c2,x
        sta song_line+2,y
        lda #RAM_IO
        sta $01
        rts

; -----------------------------------------------------------------------------
; line_text - song_line from a row's text under I/O (40 screen codes at Y:X),
; every place in colour A.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
line_text
        sta _colour
        stx _text
        sty _text+1
        ldy #RAM_ALL
        sty $01
        ldy #39
_text = *+1
-       lda $ffff,y             ; (self-modified: the text)
        sta song_line,y
_colour = *+1
        lda #0                  ; (self-modified: the colour)
        sta song_line_col,y
        dey
        bpl -
        ldy #RAM_IO
        sty $01
        rts

; song_cell_next - on to the next cell: Z clear while there is one.
; clobbers A
song_cell_next
        inc song_cell
        lda song_cell
        cmp #SONG_TRACKS
        rts

; song_num_c0, _c1, _c2 - the numbers 0-128 as cells show them, a table
; for each place: 0 " --", then right-aligned, leading zeros as spaces
SONG_NUMBERS    = NUM_PATTERNS + 1
        .section io_data        ; (under I/O: read with $01 = RAM_ALL)
song_num_c0
        .for _n := 0, _n < SONG_NUMBERS, _n += 1
        .byte _n >= 100 ? CHAR_DIGIT0 + _n / 100 : CHAR_SPACE
        .endfor
song_num_c1
        .for _n := 0, _n < SONG_NUMBERS, _n += 1
        .byte _n == 0 ? CHAR_DASH : (_n >= 10 ? CHAR_DIGIT0 + _n / 10 % 10 : CHAR_SPACE)
        .endfor
song_num_c2
        .for _n := 0, _n < SONG_NUMBERS, _n += 1
        .byte _n == 0 ? CHAR_DASH : CHAR_DIGIT0 + _n % 10
        .endfor
        .send

; song_track_colour - A = track X's colour: dark grey muted, grey when
; another is soloed, else its channel's. clobbers Y; keeps X
song_track_colour
        lda TRACK_MUTE,x
        beq +
        lda #COL_MUTED
        rts
+       lda TRACK_QUIET,x
        beq +
        lda #COL_UNSOLOED
        rts
+       ldy TRACK_CHANNEL,x
        lda channel_colour,y
        rts

; -----------------------------------------------------------------------------
; song_num3 - A (0-255) right-aligned in 3 places at song_line + Y (leading
; zeros as spaces). song_num2 - A (0-99) in 2 places, a leading zero kept.
; clobbers A, X; keeps Y
; -----------------------------------------------------------------------------
song_num3
        ldx #$ff                ; the hundreds
-       inx
        sec
        sbc #100
        bcs -
        adc #100
        sta song_digits
        txa
        beq +
        ora #CHAR_DIGIT0
        bne ++
+       lda #CHAR_SPACE
+       sta song_line,y
        lda song_digits         ; the tens
        ldx #$ff
-       inx
        sec
        sbc #10
        bcs -
        adc #10 + CHAR_DIGIT0
        sta song_line+2,y       ; (the ones)
        txa
        bne _tens
        ldx song_line,y         ; no tens: a space after a space, else 0
        cpx #CHAR_SPACE
        bne _tens
        lda #CHAR_SPACE
        bne +
_tens   ora #CHAR_DIGIT0
+       sta song_line+1,y
        rts

song_num2
        ldx #$ff                ; the tens
-       inx
        sec
        sbc #10
        bcs -
        adc #10 + CHAR_DIGIT0
        sta song_line+1,y
        txa
        ora #CHAR_DIGIT0
        sta song_line,y
        rts

; -----------------------------------------------------------------------------
; song_put_line - the row prepared aside (song_line, song_line_col) onto
; screen row X: only the cells that differ from the screen. Up to
; PUT_AT_ONCE of them (a cursor's move, a number: the usual key) all with
; interrupts off at once, so the row changes in one moment: a timer
; interrupt rendering a busy tick in the middle of a put let the beam show
; the row half old, half new (two cursors for a frame at half the wire:
; tools/flash_check.py). More (a scroll, a mute's colours, a half's
; flip): a cell at a time, its character and colour with interrupts off
; between them, the cursor's cells (their reverse bit changing) last, all
; at once.
; Carry clear: not put (a dirty row with a few cells, the beam near: the
; caller tries it later). clobbers A, Y, ptr, cptr; keeps X
; -----------------------------------------------------------------------------
PUT_AT_ONCE     = 6             ; cells (~25 cycles each with interrupts off)
song_put_line
        jsr set_row_ptr
        stx song_put_x
        ; the cells that differ, listed; more than PUT_AT_ONCE: no need
        ; to look further
        ldx #0
        ldy #39
_find   lda song_line,y
        eor (ptr),y
        bne _diff
        lda song_line_col,y
        eor (cptr),y
        and #$0f                ; (colour RAM: the low nibble only)
        beq _next
_diff   cpx #PUT_AT_ONCE
        bcs _cells
        tya
        sta song_put_list,x
        inx
_next   dey
        bpl _find
        txa
        bne +
        jmp _done               ; (nothing differs)
+
        ; few: all at once (and the old cursor's cell, after a move), the
        ; beam looked at again just before (the search above takes ~1,000
        ; cycles, an interrupt more)
        stx song_put_n
        lda song_sel            ; a dirty row but the cursor's: no cursor cell
        beq _wait               ; changes in it, so no need to wait for the beam
        lda song_put_pair       ; (a scroll's rows waited, and the next row down
        bne _wait               ; too, a row a beam's pass)
        jsr song_cursor_screen
        cpx song_put_x
        beq _wait
        sei
        bne +                   ; (always)
_wait   jsr song_put_now        ; (interrupts off)
+       ldx song_put_n
-       ldy song_put_list-1,x
        lda song_line,y
        sta (ptr),y
        lda song_line_col,y
        sta (cptr),y
        dex
        bne -
        jsr song_pair_cell
        cli
        jmp _done
        ; many: a cell at a time, the cursor's cells last, all at once (a
        ; busy tick in the middle may show the row half old, half new for
        ; a frame, but never two cursors or none)
_cells  lda song_sel            ; urgent: the beam's leave first (song_draw_from no
        bne +                   ; longer waits for it before the cells are found)
-       jsr song_put_safe_now
        bcc -
        ldx song_put_x
+       lda #0
        sta song_put_rev
        ldy #39
_cell   lda song_line,y
        eor (ptr),y
        beq _colour             ; (the character as it is)
        and #CHAR_REVERSE
        bne _cursor
        lda song_line_col,y
        eor (cptr),y
        and #$0f
        bne _both
        lda song_line,y         ; the character only (a byte: whole)
        sta (ptr),y
        jmp _on
_both   sei                     ; both: together
        lda song_line,y
        sta (ptr),y
        lda song_line_col,y
        sta (cptr),y
        cli
        jmp _on
_colour lda song_line_col,y     ; the colour only, if it differs
        eor (cptr),y
        and #$0f
        beq _on
        lda song_line_col,y
        sta (cptr),y
        jmp _on
_cursor ldx song_put_rev        ; the cursor's: listed, put below
        cpx #PUT_AT_ONCE
        bcs _on
        tya
        sta song_put_cursor,x
        inc song_put_rev
_on     dey
        bpl _cell
        lda song_put_rev
        ora song_put_pair
        beq _done               ; (no cursor's cells: no need to wait)
        jsr song_put_now        ; (interrupts off)
        ldx song_put_rev
        beq +
-       ldy song_put_cursor-1,x
        lda song_line,y
        sta (ptr),y
        lda song_line_col,y
        sta (cptr),y
        dex
        bne -
+       jsr song_pair_cell
        cli
_done   lda song_put_pair       ; (not done above: nothing differed)
        beq +
        jsr song_put_now
        jsr song_pair_cell
        cli
+       ldx song_put_x
        sec
        rts

; song_put_now - wait until row song_put_x (and the old cursor's row, with
; a pair) may be put, and return with interrupts off, still so.
; clobbers A, X
song_put_now
-       jsr song_put_safe_now
        bcc -
        sei
        jsr song_put_safe_now
        bcs +
        cli                     ; (an interrupt in between: again)
        jmp -
+       rts

; song_put_safe_now - may row song_put_x (and the pair's) be put now?
; Carry set: yes. clobbers A, X
song_put_safe_now
        ldx song_put_x
        jsr song_row_safe
        bcc +
        lda song_put_pair
        beq +                   ; (carry set)
        ldx song_pair_row
        jsr list_pair_safe      ; (list.asm: song_row_safe, and rows far apart: the beam
+       rts                     ; not between them)

.if TEST_LOG
; -----------------------------------------------------------------------------
; song_log_drawn - (tests) row song_draw_row drawn: the cursor's row logs
; the cursor's track, the title $80 + play or stop shown, the header
; LOGGED_HEAD (screen_check.py); on the step grid, the last urgent row
; drawn logs LOGGED_URGENT_DONE.
LOGGED_HEAD     = $a0
LOGGED_URGENT_DONE = $40
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_log_drawn_base             ; (scene.asm song_log_drawn first: row 1)
        lda song_mode           ; the step grid: every urgent row drawn (a key's effect
        beq ++                  ; whole: the edited row and the cursor's)
        lda song_urgent_rows
        ora song_urgent_rows+1
        ora song_urgent_rows+2
        ora song_urgent_rows+3
        bne +
        lda #LOGGED_URGENT_DONE
        jmp log_drawn
+       rts
+       ldx song_draw_row
        bne +
        lda #$80                ; the title
        ora song_shown_state
        jmp log_drawn
+       cpx #SONG_HEAD_ROW
        bne +
        lda #LOGGED_HEAD        ; the header
        jmp log_drawn
+       stx song_bit_byte
        jsr song_cursor_screen
        bcs +
        cpx song_bit_byte
        bne +
        lda song_cursor         ; the cursor's row
        jmp log_drawn
+       rts

; log_key, log_drawn - (tests, main loop) a key read (A = its code, + $80
; when pressed) / a row drawn (A = the cursor's track, or $80 + the play
; state for the title): entries LOG_KEY / LOG_DRAWN in log A, interrupts
; off (the timer interrupt writes it too). clobbers A, X
log_key_base                    ; (scene.asm log_key first: SHIFT)
        ldx want_press
        beq +
        ora #$80
+       tax                     ; C= held: + $40 (key codes are 0-63)
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        beq +
        txa
        ora #$40
        tax
+       txa
        ldx #LOG_KEY
        bne +
log_drawn
        ldx #LOG_DRAWN
+       php
        sei
        sta log_a_value
        txa
        jsr log_a
        plp
        rts
.endif
