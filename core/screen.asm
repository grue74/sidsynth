; core/screen.asm - parameter screen
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; value shown as 0 by K_TUNE parameters; a synth with such a parameter
; defines its own (a normal definition overrides this weak default)
        .weak
TUNE_CENTER     = 0
        .endweak

; parameter display kinds
K_BAR256        = 0             ; 0..255 as a 16-cell bar + number
K_BAR16         = 1             ; 0..15  as a 16-cell bar + number
K_ENUM          = 2             ; value picks a 10-character name
K_TUNE          = 3             ; signed value - TUNE_CENTER

; screen layout
TITLE_ROW       = 0
PARAM_ROW0      = 1             ; first parameter row
.if PARAM_PAGE2
        .cerror PARAM_PAGE2 >= NUM_PARAMS, "PARAM_PAGE2 beyond the parameter list"
PAGE_ROWS       = (PARAM_PAGE2 >? NUM_PARAMS - PARAM_PAGE2) + 1 ; rows of the longer page and
                                ; its hint row (>? = the larger)
PAGE_NAME_COL   = 29            ; the page's name in the title row (left of the P and CC heads)
PAGE_NAME_WIDTH = 6
.else
PAGE_ROWS       = NUM_PARAMS
.endif
        .cerror PARAM_ROW0 + PAGE_ROWS > STATUS_ROW, "parameter rows run into the status line"
HELP_ROW0       = STATUS_ROW + 1 ; (STATUS_ROW: options.inc)
        .cerror HELP_ROW0 + HELP_ROWS > 25, "help rows run off the screen"
NAME_COL        = 2
VALUE_COL       = 15
NUMBER_COL      = 32
PAD_COL         = 36            ; assigned paddle, X or Y
CC_COL          = 37            ; assigned MIDI controller, 3 characters
ENUM_WIDTH      = 10
.if PARAM_NAMES_LONG
NAMES_SPLIT     = 21            ; draw_param_row: names of parameters from here on are read
                                ; from param_names + NAMES_SPLIT*12 (an index byte holds 21)
        .cerror NUM_PARAMS > 2 * NAMES_SPLIT, "PARAM_NAMES_LONG: at most 42 parameters"
.else
        .cerror NUM_PARAMS > 21, "more than 21 parameter names (12 bytes each): set PARAM_NAMES_LONG = 1"
.endif
BAR_WIDTH       = 16

COL_TITLE       = 7             ; yellow
COL_PARAM       = 15            ; light grey
COL_SELECTED    = 1             ; white
COL_STATUS      = 13            ; light green
COL_HELP        = 12            ; grey

CHAR_SPACE      = $20
CHAR_FULL       = $a0           ; reverse space = filled bar cell
CHAR_EMPTY      = $2e           ; '.' = empty bar cell
CHAR_MARKER     = $3e           ; '>' marks the selected parameter
CHAR_ZERO       = $30
REVERSE         = $80

; zero-page variables (placed by .dsection zp in the synth's main file, e.g. sid303.asm)
        .section zp
draw_row        .byte ?         ; screen_draw_step: next row to draw
.if SYNTH_SCREEN
screen_owner    .byte ?         ; nonzero: the synth draws the screen and sees keys first
.endif
cur_param       .byte ?         ; draw_param_row: parameter being drawn
.if PARAM_PAGE2
page_first      .byte ?         ; screen_draw_step: the page's first parameter (0 or PARAM_PAGE2) ...
page_end        .byte ?         ; ... and the one after its last
.endif
        .send

; =============================================================================
; Screen
; =============================================================================

; -----------------------------------------------------------------------------
; screen_init - colours, charset, clear, static text.
; -----------------------------------------------------------------------------
screen_init
        lda #0
        sta VIC_BORDER
        sta VIC_BACKGROUND
        lda #CHARSET_MIXED
        sta VIC_MEMSETUP
        lda #%00011011          ; screen on, text mode, 25 rows
        sta VIC_CTRL1

        ; clear screen, help colour everywhere
        ldx #0
-       lda #CHAR_SPACE
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        lda #COL_HELP
        sta COLOR_RAM,x
        sta COLOR_RAM+$100,x
        sta COLOR_RAM+$200,x
        sta COLOR_RAM+$2e8,x
        inx
        bne -

        ; title row
        ldx #39
-       lda title_text,x
        sta SCREEN+TITLE_ROW*40,x
        lda #COL_TITLE
        sta COLOR_RAM+TITLE_ROW*40,x
        dex
        bpl -

        ; help rows (already help-coloured)
        ldx #0
-       lda help_text,x
        sta SCREEN+HELP_ROW0*40,x
        inx
        cpx #HELP_ROWS*40
        bne -
        ; status line colour
        ldx #STATUS_ROW
        jsr set_row_ptr
        lda #COL_STATUS
        jsr fill_row_colour
        rts

; -----------------------------------------------------------------------------
; set_row_ptr - ptr/cptr = start of screen/colour row X. clobbers A
; -----------------------------------------------------------------------------
set_row_ptr
        lda row_lo,x
        sta ptr
        sta cptr
        lda row_hi,x
        sta ptr+1
        clc
        adc #>(COLOR_RAM-SCREEN)
        sta cptr+1
        rts

; -----------------------------------------------------------------------------
; fill_row_colour - colour the 40 cells at cptr with A. clobbers Y
; -----------------------------------------------------------------------------
fill_row_colour
        ldy #39
-       sta (cptr),y
        dey
        bpl -
        rts

.if RASTER_SAFE
; =============================================================================
; Drawing out of the raster's way (RASTER_SAFE)
;
; Drawing a row often writes a cell twice: a template, then the value over
; it ("000", then "074", then the zero blanked), or the whole row blanked and
; then filled. If the raster beam passes the cell in between, the first value
; is what that frame shows: the text flashes. So a row is drawn only when the
; beam won't reach it while it is drawn: not in the SAFE_LINES raster lines
; before the row, nor on the row itself. Otherwise the draw step does nothing
; and the row is tried again on the next pass (some 2 ms later at most, when
; the main loop is idle). Never waits, and costs ~30 cycles.
; =============================================================================

BEAM_LINE       = $d012         ; VIC: raster line bits 0-7 (bit 8: VIC_CTRL1 bit 7)
RASTER_ROW0     = 51            ; raster line of text row 0's top (PAL, 25 rows, YSCROLL 3)
SAFE_LINES      = 72            ; the longest draw step in raster lines (63 cycles each:
                                ; ~4500 cycles, more than a tick period of drawing)
HALF_LINES      = 312 / 2       ; PAL lines per frame, counted in pairs (8-bit sums)

row_beam        .byte 0         ; row_safe: the beam's line / 2

; -----------------------------------------------------------------------------
; row_safe - may screen row X be drawn now? Carry set: yes, the beam is
; neither on the row nor less than SAFE_LINES above it. In lines / 2,
; the beam's distance past the start of the row's unsafe window,
; (beam - window) mod 156, must be at least the window's length.
; clobbers A; keeps X, Y
; -----------------------------------------------------------------------------
row_safe
        ; the beam's line / 2, 0..155: bit 8 from VIC_CTRL1 and bits 1-7 of
        ; BEAM_LINE; read again if bit 8 changed meanwhile (line 255->256)
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
        bmi -                   ; bit 8 differs from the one used: again

        ; distance past the window's start, mod HALF_LINES
        lda row_beam
        sec
        sbc row_window,x
        bcs +
        adc #HALF_LINES         ; below the start: wrap (carry clear, adds HALF_LINES)
+       cmp #WINDOW_HALVES      ; carry set: past the window, safe
        rts

WINDOW_HALVES   = (SAFE_LINES + 8) / 2 + 1 ; the unsafe window: SAFE_LINES and the row's
                                ; 8 lines, in pairs, one more for rounding
; per screen row, the start of its unsafe window in lines / 2
row_window
        .for row := 0, row < 25, row += 1
        .byte ((RASTER_ROW0 + row*8) / 2 - SAFE_LINES / 2 + HALF_LINES) % HALF_LINES
        .endfor
.endif

; -----------------------------------------------------------------------------
; screen_draw_step - redraw one screen row per call (parameters, then the
; status line), so the main loop is never busy for long. With RASTER_SAFE,
; nothing if the beam is about to pass the row (row_safe). With PARAM_PAGE2,
; the rows show the page holding the selected parameter, then the page's
; hint (page_hints: where the other page is), blank rows below it; the
; status step also draws the page's name.
; -----------------------------------------------------------------------------
screen_draw_step
.if SYNTH_SCREEN
        lda screen_owner
        beq +
        jmp synth_draw_step     ; the synth's own screen
+
.endif
.if RASTER_SAFE
        ; the row this step draws: a parameter's (or a page's blank or hint
        ; row), or the status row (PAGE_ROWS = NUM_PARAMS with one page)
        ldx #STATUS_ROW
        lda draw_row
        cmp #PAGE_ROWS
        bcs +
        adc #PARAM_ROW0         ; carry clear here
        tax
+       jsr row_safe
        bcs +
        rts                     ; the beam is about to pass it: next time
+
.endif
.if PARAM_PAGE2
        ; the page: the one the selected parameter is on
        ldx #0
        ldy #PARAM_PAGE2
        lda sel_param
        cmp #PARAM_PAGE2
        bcc +
        ldx #PARAM_PAGE2
        ldy #NUM_PARAMS
+       stx page_first
        sty page_end

        ; this row's parameter, the hint, a blank row, or the status
        lda draw_row
        cmp #PAGE_ROWS
        bcs _status
        adc page_first          ; carry clear here
        tay
        cpy page_end
        bcc _param
        php                     ; Z set: the row right after the page's last parameter
        lda draw_row
        adc #PARAM_ROW0-1       ; carry set here
        tax
        jsr set_row_ptr
        plp
        bne _blank

        ; the hint, in the help colour: the first or the second of page_hints
        lda #COL_HELP
        jsr fill_row_colour
        ldx #0
        lda page_first
        beq +
        ldx #40
+       ldy #0
-       lda page_hints,x
        sta (ptr),y
        inx
        iny
        cpy #40
        bne -
        inc draw_row
        rts

        ; further down: blank
_blank  lda #CHAR_SPACE
        ldy #39
-       sta (ptr),y
        dey
        bpl -
        inc draw_row
        rts
_status jsr draw_page_name
        jsr draw_status
        lda #0
        sta draw_row
        rts
.else
        ldy draw_row
        cpy #NUM_PARAMS
        bcc _param
        jsr draw_status
        lda #0
        sta draw_row
        rts
.endif
_param  jsr draw_param_row
        jsr draw_param_cc
        inc draw_row
        rts

.if PARAM_PAGE2
; -----------------------------------------------------------------------------
; draw_page_name - the shown page's name (page_names) in the title row.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
draw_page_name
        ldx #0
        lda page_first
        beq +
        ldx #PAGE_NAME_WIDTH    ; the second name
+       ldy #0
-       lda page_names,x
        sta SCREEN+TITLE_ROW*40+PAGE_NAME_COL,y
        inx
        iny
        cpy #PAGE_NAME_WIDTH
        bne -
        rts
.endif

; -----------------------------------------------------------------------------
; draw_param_row - draw parameter Y: marker, name, value, number.
; -----------------------------------------------------------------------------
draw_param_row
        sty cur_param
        tya
.if PARAM_PAGE2
        sec
        sbc page_first          ; the row on its page
.endif
        clc
        adc #PARAM_ROW0
        tax
        jsr set_row_ptr

        ; colour and marker: the selected parameter stands out
        lda #COL_PARAM
        ldx #CHAR_SPACE
        ldy cur_param
        cpy sel_param
        bne +
        lda #COL_SELECTED
        ldx #CHAR_MARKER
+       jsr fill_row_colour
        txa
        ldy #0
        sta (ptr),y

        ; name: 12 characters at param_names + index*12
        lda cur_param
.if PARAM_NAMES_LONG
        cmp #NAMES_SPLIT        ; past the first 256 bytes of names:
        bcs _late_name          ; from param_names + NAMES_SPLIT*12
.endif
        asl
        asl
        sta tmp
        asl
        adc tmp                 ; *8 + *4, carry clear (small values)
        tax
        ldy #NAME_COL
-       lda param_names,x
        sta (ptr),y
        inx
        iny
        cpy #NAME_COL+12
        bne -
.if PARAM_NAMES_LONG
        beq _named              ; always
        ; parameters NAMES_SPLIT.. : (index - NAMES_SPLIT)*12 from the split
_late_name
        sbc #NAMES_SPLIT        ; carry set here
        asl
        asl
        sta tmp
        asl
        adc tmp                 ; *8 + *4, carry clear (small values)
        tax
        ldy #NAME_COL
-       lda param_names+NAMES_SPLIT*12,x
        sta (ptr),y
        inx
        iny
        cpy #NAME_COL+12
        bne -
_named
.endif

        ; value by kind (each kind writes every cell of the value and number
        ; area, never blanking first, so a redraw can't flicker)
        ldx cur_param
        lda param_kind,x
        cmp #K_ENUM
        beq _enum
        cmp #K_TUNE
        beq _tune

        ; bars: scale to 0..255 (x17 for 0..15), cells = v*17/256 = 0..16
        lda params,x
        ldy param_kind,x
        beq +                   ; K_BAR256 already 0..255
        ldx #17
        jsr mul8
        lda mul_lo
+       ldx #17
        jsr mul8
        sta tmp                 ; filled cells
        ldy #VALUE_COL
        ldx #0
-       lda #CHAR_FULL
        cpx tmp
        bcc +
        lda #CHAR_EMPTY
+       sta (ptr),y
        iny
        inx
        cpx #BAR_WIDTH
        bne -
        ldx cur_param
        lda params,x
        ldy #NUMBER_COL
        jmp print_dec3

        ; enum: name at table + value*10
_enum   lda enum_ptr_lo,x
        sta _src
        lda enum_ptr_hi,x
        sta _src+1
        lda params,x
        asl
        sta tmp
        asl
        asl
        adc tmp                 ; *10, carry clear
        tax
        ldy #VALUE_COL
_src = *+1                      ; operand = enum table, patched above
-       lda $ffff,x
        sta (ptr),y
        inx
        iny
        cpy #VALUE_COL+ENUM_WIDTH
        bne -
        jmp blank_to_end

        ; tune: sign and two digits of TUNE - 16
_tune   lda #'+'
        sta tmp2
        lda params,x
        sec
        sbc #TUNE_CENTER
        bcs +
        eor #$ff                ; negative: negate (carry clear -> +1)
        adc #1
        ldx #'-'
        stx tmp2
+       ldy #VALUE_COL
        jsr print_dec3          ; "016" ...
        lda tmp2
        ldy #VALUE_COL
        sta (ptr),y             ; ... sign over the hundreds digit: "+16"
        ldy #VALUE_COL+3

; blank_to_end - spaces from (ptr)+Y to the end of the number column
blank_to_end
        lda #CHAR_SPACE
-       sta (ptr),y
        iny
        cpy #NUMBER_COL+3
        bne -
        rts

; -----------------------------------------------------------------------------
; draw_param_cc - the paddle and controller assigned to parameter cur_param,
; at the right of its row (ptr already set): X or Y in the P column, then the
; lowest controller number with leading blanks; blank if none, "???" while
; it is being learnt.
; -----------------------------------------------------------------------------
draw_param_cc
        ; paddle letter (X wins if both paddles had it, which can't happen)
        lda #CHAR_SPACE
        ldx cur_param
        cpx pad_param+1
        bne +
        lda pad_letters+1
+       cpx pad_param
        bne +
        lda pad_letters
+       ldy #PAD_COL
        sta (ptr),y

        ; controller number
        lda learn_mode
        beq _find
        lda cur_param
        cmp sel_param
        bne _find
        lda #'?'
        ldy #CC_COL
-       sta (ptr),y
        iny
        cpy #CC_COL+3
        bne -
        rts

_find   ldx #0
        lda cur_param
-       cmp cc_map,x
        beq _found
        inx
        bpl -                   ; 0..127
        lda #CHAR_SPACE         ; none
        ldy #CC_COL
-       sta (ptr),y
        iny
        cpy #CC_COL+3
        bne -
        rts

_found  txa
        ldy #CC_COL
        jsr print_dec3
        ; leading zeros to blanks: "074" -> " 74", "005" -> "  5"
        ldy #CC_COL
-       lda (ptr),y
        cmp #CHAR_ZERO
        bne +
        lda #CHAR_SPACE
        sta (ptr),y
        iny
        cpy #CC_COL+2
        bne -
+       rts

; -----------------------------------------------------------------------------
; draw_status - the status row: in learn mode a reversed prompt, otherwise
; whatever the synth's synth_draw_status hook shows (ptr set to the row).
; -----------------------------------------------------------------------------
draw_status
        ldx #STATUS_ROW
        jsr set_row_ptr
        lda learn_mode
        beq +
        ldy #39
-       lda learn_text,y
        ora #REVERSE
        sta (ptr),y
        dey
        bpl -
        rts
+       jmp synth_draw_status

; -----------------------------------------------------------------------------
; print_dec3 - A as three decimal digits at (ptr)+Y. Y advances by 3.
; clobbers A, X
; -----------------------------------------------------------------------------
print_dec3
        ldx #CHAR_ZERO-1
        sec
-       inx                     ; hundreds
        sbc #100
        bcs -
        adc #100
        pha
        txa
        sta (ptr),y
        iny
        pla
        ldx #CHAR_ZERO-1
        sec
-       inx                     ; tens
        sbc #10
        bcs -
        adc #10
        pha
        txa
        sta (ptr),y
        iny
        pla
        ora #CHAR_ZERO          ; ones
        sta (ptr),y
        iny
        rts

; screen row start addresses
row_lo  .for row := 0, row < 25, row += 1
        .byte <(SCREEN + row*40)
        .endfor
row_hi  .for row := 0, row < 25, row += 1
        .byte >(SCREEN + row*40)
        .endfor

; texts of the core's own screen parts, in screen codes (mixed-case charset)
        .enc "screen"
pad_letters     .text "XY"          ; P column: paddle X, paddle Y
learn_text      .text "Learn: knob/paddle  DEL=none  RETURN=off"
        .cerror * - learn_text != 40, "learn prompt must be 40 characters"
        .enc "none"
