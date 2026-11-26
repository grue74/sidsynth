; disk.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Save and load (docs/design.md 5e "Disk"), from SID101's disk.asm. The
; disk code is an overlay: a file of its own ("sid500 disk"), loaded into
; the step grid's edit table under the KERNAL (DISK_OV: rebuilt whenever
; RETURN opens a pattern) when C= W, C= L or C= D asks for it on the song
; screen while stopped, and kept while that RAM is left alone. Its first
; bytes (OV_ID: an edit table record can't look like them) say it is there
; and of this build. Resident (late_code): the keys' hook, the overlay's
; loader, the disk mode's way in and out, a message when the overlay can't
; be loaded. The rest runs from the overlay with the ROMs out, like the
; main loop; the KERNAL is reached through kcall (copied into main RAM:
; code under the KERNAL can't call it directly).
;
; The disk mode (disk_in .. disk_out): every interrupt source off at the
; chips, the ACIA reset; our zero page in ZP_OURS (a page of the note-off
; map: nothing sounds while stopped, so it is filled again afterwards) and
; a zero page for the KERNAL in its place: all zeros but its output device
; (the screen) and its last drive (the Disk drive parameter's). With it in,
; none of our zero-page variables may be used (the overlay's code there
; keeps to $FB-$FE, which the KERNAL leaves alone, and absolute RAM).
; Afterwards: the core's tick (timer B), the player's timer A (player_go)
; and the time base (CIA2's, time_init) as at start, MIDI as at start-up.
;
; A song file (DISK_SAVE): load address, FILE_MAGIC and FILE_VERSION; the
; parameters saved (all but Disk drive: SAVED_PARAMS, its count first);
; Song on and the start scene; the song data's three runs (song_runs:
; pattern lengths, scene repeats, the channels' synths; the tracks'
; channels, order, mute, solo; the scenes' bars, signatures and cells);
; then each pattern there is: its number, its blocks (2 bytes), each
; block's BLOCK_DATA stream bytes (the link left out: a load lays the
; blocks one after another from POOL_START); $FF after the last.

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
DISK_OV         = GRID_TABLE    ; the overlay's place (under the KERNAL)
DISK_OV_END     = GRID_STEP_LO  ; up to the grid's step index (the take's ring)
ZP_OURS         = NOTE_ENTRY    ; our zero page during the disk mode (a page of the
                                ; note map: NO_ENTRY again afterwards, wheel_clear_page 0)
        .cerror ZP_OURS != NOTE_ENTRY, "disk_out refills NOTE_ENTRY's page 0"
        .cerror KERNAL_ZP_COPY != NOTE_ENTRY + $100, "the KERNAL's zero page at start: NOTE_ENTRY's page 1"
KERNAL_IO       = $36           ; $01: KERNAL ROM and I/O in, BASIC out
KERNAL_DFLTO    = $9a           ; KERNAL zero page: the output device (3 = the screen)
KERNAL_LAST_DEVICE = $ba        ;   the last device number used (FA)
FIRST_DRIVE     = 8             ; the Disk drive parameter: 0 = drive 8
LAST_DRIVE      = 16
KEY_W           = 1*8+1         ; key codes (column * 8 + row)
KEY_L           = 5*8+2
KEY_D           = 2*8+2

; KERNAL entry points (jump table: all at $FFxx, kcall's high byte)
SETMSG          = $ff90
READST          = $ffb7
SETLFS          = $ffba
SETNAM          = $ffbd
OPEN            = $ffc0
CLOSE           = $ffc3
CHKIN           = $ffc6
CHKOUT          = $ffc9
CLRCHN          = $ffcc
CHRIN           = $ffcf
CHROUT          = $ffd2
LOAD            = $ffd5
ST_EOF          = %01000000     ; READST: end of file

; disk_ui: what the overlay shows and takes the keys for (0: nothing)
DISK_SAVE       = 1             ; the name asked for a save
DISK_LOAD       = 2             ;   for a load
DISK_DIR        = 3             ; the directory (C= D)
DISK_MESSAGE    = 4             ; a message on the title row until a key

NAME_MAX        = 13            ; characters typed: + SUFFIX (".s5") = 16
OV_LFN          = 1             ; the overlay's LOAD: logical file, secondary address 1
OV_SA           = 1             ;   (to the address in the file)

        .weak
TEST_DRIVE      = 0             ; test builds: the Disk drive parameter at start (0 = $BA's)
        .endweak


.if DISK_CODE
; the resident variables: after the locate's (main RAM at $CFAF, seen with
; the KERNAL in too)
        .virtual locate_vars_end
disk_ui         .byte ?         ; DISK_*: the overlay's screen and keys, 0 = none
disk_res_msg    .byte ?         ; nonzero: the title shows "no overlay" until a key
disk_vic_mask   .byte ?         ; the VIC's interrupts before the disk mode (test builds)
disk_name_len   .byte ?         ; the name typed (kept while the overlay is reloaded)
hi3_out         .byte ?         ; nonzero: HI3_CODE kept in HI3_KEEP, the overlay over it
disk_name       .fill NAME_MAX
KCALL_RAM       .fill KCALL_LEN ; kcall, copied here from the overlay (ov_disk_in)
disk_cmd        .fill CMD_MAX   ; the file's name for OPEN: "s0:" name, or name ",p,w" / ",p,r"
                                ; (here: the KERNAL reads it with its ROM in)
disk_vars_end
        .endv
        .cerror disk_vars_end > $d000, "the disk's variables run past $CFFF"

; =============================================================================
; Resident: main RAM (after the tables: nothing before them moves), and
; under the KERNAL in the wheel's gap (HI2_CODE: the disk mode's way in and
; out, run with the ROMs out; copied there at start)
; =============================================================================
        .section late_code

        .section init_code      ; (start-up only: run once from INIT_CODE)
; -----------------------------------------------------------------------------
; disk_copy_all - (synth_init, in io_copy_all's place) io_copy_all, the
; code under the KERNAL in the wheel's gap, then disk_init (before anything
; uses the note map, where start-up put the KERNAL's zero page).
; -----------------------------------------------------------------------------
disk_copy_all
        jsr io_copy_all
        ldx #hi2_image_end - hi2_image
-       lda hi2_image-1,x
        sta HI2_CODE-1,x
        dex
        bne -
        .cerror hi2_image_end - hi2_image > 255 || hi2_image_end == hi2_image, "disk_copy_all: 1-255 bytes"
        ; (disk_init follows)

; -----------------------------------------------------------------------------
; disk_init - the Disk drive parameter: the drive SID500 was loaded from
; (the KERNAL's last device, in its zero page as start-up found it; one
; outside 8..16: drive 8); nothing shown, no name yet.
; clobbers A
; -----------------------------------------------------------------------------
disk_init
.if TEST_DRIVE == 0
        lda KERNAL_ZP_COPY + KERNAL_LAST_DEVICE
        sec
        sbc #FIRST_DRIVE
        cmp #LAST_DRIVE - FIRST_DRIVE + 1
        bcc +                   ; 8..16 (below 8 wrapped round: too big)
        lda #0
+
.else
        lda #TEST_DRIVE - FIRST_DRIVE
.endif
        sta params+P_DRIVE
        lda #0
        sta disk_ui
        sta disk_res_msg
        sta disk_name_len
        sta hi3_out
        rts
        .send

; -----------------------------------------------------------------------------
; disk_key - (song.asm synth_key, in names_key's place) a key on the song
; screen: the overlay's while it shows something; C= W / L / D open it
; (stopped: disk_may), loading it first when it isn't there; else
; names_key. Carry set = used.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
disk_key
        ldx disk_ui
        beq +
        jmp OV_KEY              ; (the overlay's: its own carry)
+       ldx disk_res_msg        ; the "no overlay" message: gone at a key's press
        beq +
        cmp #KEY_CBM_CODE       ; (but C='s own: with the letter that asked, it comes
        beq +                   ; after it in the same scan)
        jsr res_msg_off
        ; C= W / L / D: DISK_SAVE, DISK_LOAD, DISK_DIR
+       ldx #DISK_DIR
-       cmp disk_keys-1,x
        beq _cbm
        dex
        bne -
_not    jmp names_key
_cbm    tay
        lda key_now+KEY_CBM_COLUMN
        and #KEY_CBM_BIT
        bne +
        tya
        bcs _not                ; (always: cmp found it)
+       lda want_press
        beq _used               ; (its release)
        jsr disk_may
        bcs _used               ; playing, or busy: not now
        stx disk_ui
        jsr ov_valid
        bcc _open
        jsr ov_load
        jsr ov_valid
        bcc _open
        ldx #0                  ; not there (or another build's): say so
        stx disk_ui
        inx
        stx disk_res_msg
        dex
        jsr song_dirty_row      ; (the title)
        jmp _used
_open   jsr OV_OPEN             ; (disk_ui: what to open)
_used   lda #0                  ; (used, no repeat)
        sec
        rts
        .cerror SONG_TITLE_ROW != 0, "disk_key: the title is row 0"

; -----------------------------------------------------------------------------
; hi3_in - (the step grid opened; the song about to play or be located:
; transport_go_start, _continue, transport_poll, locate_begin, count_begin;
; a slave's start held for it, slave.asm) the code at HI3_CODE back from
; HI3_KEEP if the overlay was loaded over it, the note map's pages there
; NO_ENTRY again; the overlay then not there (its id spoiled), a disk screen
; open closed (the user: a slave's start closes it). keeps X, Y
; -----------------------------------------------------------------------------
hi3_in
        lda hi3_out
        bne +
        rts
+       txa
        pha
        tya
        pha
        ldy #0
-       .for _p := 0, _p < 4, _p += 1
        lda HI3_KEEP + _p * $100,y
        sta HI3_CODE + _p * $100,y
        .endfor
        lda #NO_ENTRY
        .for _p := 0, _p < 4, _p += 1
        sta HI3_KEEP + _p * $100,y
        .endfor
        iny
        bne -
        sty hi3_out
        sty DISK_OV             ; (ov_valid: not there)
        lda disk_ui
        beq +
        sty disk_ui             ; the disk screen closed: the song's rows again
        jsr song_half_changed
        ldx #SONG_INFO_ROW
        jsr song_dirty_row
+       pla
        tay
        pla
        tax
        rts

; -----------------------------------------------------------------------------
; ov_load - load the overlay file from the Disk drive parameter's drive into
; DISK_OV (the KERNAL's LOAD writes the RAM under its ROM), in the disk mode.
; First the code at HI3_CODE, which the overlay goes over, kept in the note
; map (HI3_KEEP: stopped, nothing sounds; hi3_in puts it back), once.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
HI3_KEEP        = NOTE_ENTRY + $200 ; (its pages 0 and 1: ZP_OURS, KERNAL_ZP_COPY)
        .cerror HI3_CODE + $400 > GRID_STEP_LO || HI3_KEEP + $400 > NOTE_ENTRY + $800, "HI3_KEEP: four pages"
ov_load
        lda hi3_out
        bne _kept
        ldy #0
-       .for _p := 0, _p < 4, _p += 1
        lda HI3_CODE + _p * $100,y
        sta HI3_KEEP + _p * $100,y
        .endfor
        iny
        bne -
        inc hi3_out
_kept   ldy params+P_DRIVE      ; (disk_in keeps Y)
        jsr disk_in
        lda #KERNAL_IO          ; (main RAM: the KERNAL in throughout)
        sta CPU_PORT
        tya
        clc
        adc #FIRST_DRIVE
        tax
        lda #OV_LFN
        ldy #OV_SA
        jsr SETLFS
        lda #OV_NAME_LEN
        ldx #<ov_name
        ldy #>ov_name
        jsr SETNAM
        lda #0                  ; load, not verify
        jsr LOAD
        lda #RAM_IO
        sta CPU_PORT
        jmp disk_out

; -----------------------------------------------------------------------------
; disk_prepare - (names.asm names_prepare, in song_prepare's place) row X
; prepared: the overlay's rows while it shows something, the "no overlay"
; message on the title row, else song_prepare.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
disk_prepare
        lda disk_ui
        beq +
        jmp OV_PREPARE
+       lda disk_res_msg
        beq _song
        cpx #SONG_TITLE_ROW
        bne _song
        jmp res_msg_line        ; (under the KERNAL)
_song   jmp song_prepare

        .send late_code

        .section lo3_code       ; (main RAM, copied at start)
; -----------------------------------------------------------------------------
; ov_valid - is the overlay of this build in its place? Carry set = no.
; clobbers A, Y
; -----------------------------------------------------------------------------
ov_valid
        ldy #OV_ID_LEN-1
-       lda DISK_OV,y
        cmp ov_id,y
        bne _no
        dey
        bpl -
        clc
        rts
_no     sec
        rts



; res_msg_off - (disk_key) the "no overlay" message gone at a key's press
; (not at a release: C= and the letter that asked are released after).
; keeps A; clobbers X
res_msg_off
        ldx want_press
        beq +
        ldx #0
        stx disk_res_msg
        pha
        jsr song_dirty_row      ; (the title)
        pla
+       rts
        .cerror SONG_TITLE_ROW != 0, "res_msg_off: the title is row 0"
        .send lo3_code

        .section lo2_code       ; (main RAM, copied at start)
disk_keys .byte KEY_W, KEY_L, KEY_D ; (DISK_SAVE, DISK_LOAD, DISK_DIR: disk_key)
        .cerror DISK_SAVE != 1 || DISK_LOAD != 2 || DISK_DIR != 3, "disk_keys' order"
; the overlay's first bytes (an edit table record's third byte is its type,
; 0-3: never $A5), then the build
ov_id   .byte $53, $35, $a5, $44, <BUILD, >BUILD
OV_ID_LEN = * - ov_id
        .send lo2_code

        .section hi_code        ; (under the KERNAL, the ROMs out: the main loop's)
; res_msg_line - the "no overlay" message prepared (disk_prepare). clobbers
; A, X, Y
res_msg_line
        jsr song_blank_line     ; (a line of no scene: its kind)
        lda #COL_SONG_TITLE
        ldx #<res_msg
        ldy #>res_msg
        jmp line_text           ; (its text under I/O)
        .send hi_code

        .section io_data
        .enc "screen"
res_msg .text format("%-40s", "NO SID500 DISK FILE")
        .enc "none"
        .send io_data

        .section hi2_code
; -----------------------------------------------------------------------------
; disk_may - may the disk be used now: stopped, and nothing using the edit
; table (an edit being encoded, a take, a count-in or an armed take) or
; about to (a live switch). Carry set = not now.
; clobbers A
; -----------------------------------------------------------------------------
disk_may
        lda play_state
        ora edit_state
        ora rec_state
        ora count_state
        ora lv_phase
        cmp #1                  ; (anything but all 0: carry set)
        rts
        .cerror PLAY_STOPPED != 0 || EDIT_CLEAN != 0 || REC_OFF != 0 || COUNT_NONE != 0 || LIVE_IDLE != 0, "disk_may: the idle states are 0"

; -----------------------------------------------------------------------------
; disk_in - into the disk mode (see the top): interrupts off at the chips,
; the ACIA reset, our zero page in ZP_OURS and zeros in its place (the
; KERNAL's: no file open, no messages). Returns with the ROMs still out.
; clobbers A, X (keeps Y)
; -----------------------------------------------------------------------------
disk_in
        sei
        lda #$7f                ; every CIA1 interrupt source off (CIA2's are, always)
        sta CIA1_ICR
        lda CIA1_ICR            ; (any pending acknowledged)
.if TEST_RX_FEED
        jsr disk_vic_off        ; (test builds: the VIC's raster off, kept)
.endif
        ldx midi_if_active      ; the ACIA reset: no interrupt from it
        beq +
        lda if_ctrl,x
        sta disk_acia
        lda #ACIA_RESET
disk_acia = * + 1               ; (low byte: the interface's control register; the
        sta $de00               ; only byte copied at start that changes: disk_check.py)
+       ldx #2                  ; zero page: ours away, zeros in
-       lda $00,x
        sta ZP_OURS,x
        lda #0
        sta $00,x
        inx
        bne -
        rts

; -----------------------------------------------------------------------------
; disk_out - (the ROMs out) out of the disk mode: our zero page back (its
; page of the note map empty again), the core's tick, the player's timer
; and the time base as at start, no ticks to catch up, MIDI as at start-up
; (interrupts on).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
disk_out
        ldx #2
-       lda ZP_OURS,x
        sta $00,x
        inx
        bne -
        ldx #0
        jsr wheel_clear_page    ; (ZP_OURS's page: no note sounding)
        ; the core's tick on timer B (as core framework.asm start)
        lda #<TICK_LATCH
        sta CIA1_TB_LO
        lda #>TICK_LATCH
        sta CIA1_TB_HI
        lda #%00010001          ; force latch load, start, continuous, counting cycles
        sta CIA1_CRB
        lda #%10000010          ; timer B's interrupt on
        sta CIA1_ICR
        jsr time_init           ; CIA2's timers: the time base
        jsr player_go           ; timer A: master at the tempo, slave still (interrupts kept off)
.if TEST_RX_FEED
        jsr disk_vic_on         ; (test builds: the VIC's raster as before)
.endif
        lda tick_count
        sta tick_done           ; no ticks to catch up
        jmp midi_init           ; the interface and both rings afresh (ends with cli)
        .send hi2_code

.if TEST_RX_FEED
        .section late_tests
; disk_vic_off, disk_vic_on - (test builds with the raster interrupt) the
; VIC's interrupts off for the disk mode, kept; back. clobbers A
disk_vic_off
        lda VIC_IRQ_MASK
        sta disk_vic_mask
        lda #0
        sta VIC_IRQ_MASK
        rts
disk_vic_on
        lda disk_vic_mask
        sta VIC_IRQ_MASK
        rts
        .send late_tests
.endif

; =============================================================================
; The overlay (at DISK_OV, under the KERNAL; run with the ROMs out). Its
; own build: 64tass -D DISK_OV_OUT=1 --output-section=disk_ov (build.sh);
; in the program's build it is only addresses (sid500.asm).
; =============================================================================
        .section disk_ov
ov_start
        .cerror ov_start != DISK_OV, "the overlay's id first (ov_valid)"
        .byte $53, $35, $a5, $44, <BUILD, >BUILD ; (ov_id)
        .cerror * - ov_start != OV_ID_LEN, "the overlay's id"
OV_OPEN         jmp ov_open
OV_KEY          jmp ov_key
OV_PREPARE      jmp ov_prepare

; kc - (macro; \1 = a KERNAL routine) kcall to call \1: kcall the next
; jsr (A, X, Y and the flags through both ways)
kc      .macro
        lda #<\1
        sta KCALL_RAM + kcall_to - kcall_image
        .endm

; -----------------------------------------------------------------------------
; ov_open - (disk_key) disk_ui: what to open. The name prompt for a save or
; a load (the name typed last, at first "song"); the directory (dir_open).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
ov_open
        lda disk_name_len
        bne +
        ldx #DEFAULT_NAME_LEN-1 ; no name yet: "song"
-       lda default_name,x
        sta disk_name,x
        dex
        bpl -
        lda #DEFAULT_NAME_LEN
        sta disk_name_len
+       lda disk_ui
        cmp #DISK_DIR
        bne ov_title
        jmp dir_open

; ov_title - the title row to draw at once. clobbers A, X, Y
ov_title
        ldx #SONG_TITLE_ROW
        jmp song_urgent_row

; -----------------------------------------------------------------------------
; ov_key - (disk_key) a key while the overlay shows something. A message:
; any key ends it. The prompt: RETURN saves or loads, RUN/STOP cancels, DEL
; deletes a character, letters, digits, space and + - . type. The
; directory's: dir_key. Carry set (every key used), A = 0 (no repeat) but
; the directory's cursor (1).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
ov_key
        ldx want_press
        beq _used               ; (releases)
        ldx disk_ui
        cpx #DISK_MESSAGE
        beq _close
        cpx #DISK_DIR
        bne +
        jmp dir_key
+       cmp #KEY_RETURN
        beq _go
        cmp #KEY_RUNSTOP
        beq _close
        cmp #KEY_DEL
        beq _delete
        tax
        lda name_chars,x
        beq _used               ; not a name's character
        ldx disk_name_len
        cpx #NAME_MAX
        bcs _used               ; full
        sta disk_name,x
        inc disk_name_len
        bne _shown              ; (always)
_delete ldx disk_name_len
        beq _used
        dec disk_name_len
_shown  jsr ov_title
_used   lda #0                  ; (no repeat)
        sec
        rts
_close  lda #0
        sta disk_ui
        beq _shown              ; (always)
_go     lda disk_name_len
        beq _used               ; no name
        jsr ov_run
        jmp _used

; -----------------------------------------------------------------------------
; ov_prepare - (disk_prepare) row X prepared while the overlay shows
; something: the title row its prompt or message, else song_prepare.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
ov_prepare
        lda disk_ui
        cmp #DISK_DIR
        bne +
        jsr song_blank_line     ; (keeps X)
        jmp dir_prepare
+       cpx #SONG_TITLE_ROW
        beq +
        jmp song_prepare
+       jsr song_blank_line
        lda disk_ui
        cmp #DISK_MESSAGE
        bne _prompt
        ; the message
        ldy #39
-       lda ov_msg,y
        sta song_line,y
        lda #COL_SONG_TITLE
        sta song_line_col,y
        dey
        bpl -
        rts
        ; "SAVE 8: name" / "LOAD 8: name", the cursor (reversed) after it
        ; (one reversed place: song_put_line puts at most PUT_AT_ONCE of
        ; them, as a cursor's cell)
_prompt ldx #0
        cmp #DISK_SAVE
        beq +
        ldx #prompt_load - prompt_texts
+       ldy #0
-       lda prompt_texts,x
        jsr _put
        inx
        cpy #PROMPT_LEN
        bne -
        jsr drive_digits        ; the drive, ':'
        ldx #0
-       lda drive_text,x
        jsr _put
        inx
        cpx drive_text_len
        bne -
        lda #CHAR_COLON
        jsr _put
        iny                     ; a space, then the name (PETSCII = these screen codes)
        ldx #0
-       cpx disk_name_len
        beq +
        lda disk_name,x
        jsr _put
        inx
        bne -                   ; (always)
+       lda #CHAR_SPACE         ; the cursor
_rev    ora #REVERSE
_put    sta song_line,y
        lda #COL_SONG_TITLE
        sta song_line_col,y
        iny
        rts

; -----------------------------------------------------------------------------
; drive_digits - the drive (Disk drive parameter) as screen codes in
; drive_text, drive_text_len = 1 or 2. clobbers A
; -----------------------------------------------------------------------------
drive_digits
        lda params+P_DRIVE
        clc
        adc #FIRST_DRIVE
        cmp #10
        bcs _two
        adc #CHAR_ZERO          ; (carry clear)
        sta drive_text
        lda #1
        sta drive_text_len
        rts
_two    sbc #10                 ; (carry set: 10..16 -> 0..6)
        clc
        adc #CHAR_ZERO
        sta drive_text+1
        lda #CHAR_ZERO+1
        sta drive_text
        lda #2
        sta drive_text_len
        rts

; =============================================================================
; Saving and loading (from ov_key)
; =============================================================================

; -----------------------------------------------------------------------------
; ov_run - save or load (disk_ui) the file named: stopped (else a message),
; "SAVING..." / "LOADING..." shown first; the disk mode; afterwards a load
; put to use (ov_loaded), or an empty song when a load failed half way;
; the message (ours, or the drive's status line) until a key.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
ov_run
        lda disk_ui
        sta ov_kind
        lda #DISK_MESSAGE
        sta disk_ui
        jsr disk_may            ; (as slave, a start may have come meanwhile)
        bcc +
        lda #ERR_PLAYING
        sta disk_error
        jmp ov_message
+       ldx #BUSY_SAVE
        lda ov_kind
        cmp #DISK_SAVE
        beq +
        ldx #BUSY_LOAD
+       txa
        jsr ov_show             ; (before the disk mode: nothing is drawn in it)
        ; the disk mode: the file, then the drive's status
        jsr ov_disk_in
        lda #ERR_NONE
        sta disk_error
        sta ov_changed
        lda ov_kind
        cmp #DISK_SAVE
        bne +
        jsr disk_save
        jmp ++
+       jsr disk_load
+       jsr disk_status
        jsr disk_out
        ; a load: used, or the song emptied when it failed after changing it
        lda ov_kind
        cmp #DISK_LOAD
        bne _msg
        lda ov_changed          ; (unchanged: the file not opened, or not a song)
        beq _msg
        lda disk_error
        bne +
        jsr ov_loaded
        jmp _msg
+       jsr ov_emptied
_msg    jmp ov_message

; ov_message - the message on the title until a key: ours (disk_error), else
; the drive's status line (disk_status put it in ov_msg). clobbers A, X, Y
ov_message
        lda #DISK_MESSAGE
        sta disk_ui
        lda disk_error
        beq _status             ; the drive's own words
        tax
        lda err_text_ofs-1,x
        jsr ov_text
        lda disk_error
        cmp #ERR_DEVICE
        bne _shown
        jsr drive_digits        ; "NO DRIVE" + its number
        ldx #0
        ldy #NO_DRIVE_LEN+1
-       lda drive_text,x
        sta ov_msg,y
        iny
        inx
        cpx drive_text_len
        bne -
_status
_shown  jmp ov_title

; ov_show - ov_text, then the title drawn now (the disk mode draws
; nothing). clobbers A, X, Y
ov_show
        jsr ov_text
        jsr ov_title
-       jsr song_urgent
        lda song_urgent_rows
        ora song_urgent_rows+1
        ora song_urgent_rows+2
        ora song_urgent_rows+3
        bne -
        rts

; ov_all_rows - every row of the song screen to draw (the directory shown,
; or gone). ov_all_rows_used: then used, the key repeating (dir_key).
; clobbers A, X, Y
ov_all_rows
        jsr song_half_changed   ; (the title, the header and the scenes' rows)
        ldx #SONG_INFO_ROW
        jmp song_dirty_row
ov_all_rows_used
        jsr ov_all_rows
        lda #1
        sec
        rts

; ov_text - ov_msg: the text at offset A in ov_texts (OV_TEXT_LEN), the
; rest blank. clobbers A, X, Y
ov_text
        tax
        ldy #0
-       lda ov_texts,x
        sta ov_msg,y
        inx
        iny
        cpy #OV_TEXT_LEN
        bne -
        lda #CHAR_SPACE
-       sta ov_msg,y
        iny
        cpy #40
        bne -
        rts

; -----------------------------------------------------------------------------
; ov_disk_in - disk_in, and kcall copied into main RAM (KCALL_RAM).
; clobbers A, X
; -----------------------------------------------------------------------------
ov_disk_in
        jsr disk_in
        ldx #KCALL_LEN-1
-       lda kcall_image,x
        sta KCALL_RAM,x
        dex
        bpl -
        rts

; kcall's image: the KERNAL in, the routine (kc set its low byte), back
; out; A, X, Y and the flags through both ways
kcall_image
        pha
        lda #KERNAL_IO
        sta CPU_PORT
        pla
kcall_to = * + 1
        jsr $ff00               ; (low byte: kc)
        php
        pha
        lda #RAM_IO
        sta CPU_PORT
        pla
        plp
        rts
KCALL_LEN = * - kcall_image
KCALL = KCALL_RAM

; =============================================================================
; In the disk mode (the KERNAL's zero page: none of ours; ZP_OURS has it)
; =============================================================================
blk             = $fb           ; KERNAL zero page left free: a block's address
pat             = $fd           ;   the pattern (disk_save, disk_load)

; -----------------------------------------------------------------------------
; disk_save - scratch an old file of the name (S0:), then write the song
; (see the top). Sets disk_error on failure.
; -----------------------------------------------------------------------------
disk_save
        ; the command channel with "S0:name.s5": an old file of the name
        ; goes (not "@0:", which the 1541 can get wrong)
        ldx #0
-       lda scratch_text,x
        sta disk_cmd,x
        inx
        cpx #SCRATCH_LEN
        bne -
        jsr cmd_add_name
        lda #LFN_CMD
        ldy #LFN_CMD
        jsr open_cmd_len
        bcc _far1       ; (bcs no_device: too far)
        jmp no_device
_far1
        #kc READST
        jsr KCALL
        bpl _far2       ; (bmi no_device: too far)
        jmp no_device
_far2
        ; the file: name.s5,P,W
        ldx #0
        jsr cmd_add_name
        ldy #0
-       lda write_suffix,y
        sta disk_cmd,x
        inx
        iny
        cpy #SUFFIX_RW_LEN
        bne -
        stx disk_len
        lda #LFN_FILE
        ldy #LFN_FILE
        jsr open_cmd_len
        bcc _far3       ; (bcs no_device: too far)
        jmp no_device
_far3
        #kc CHKOUT
        ldx #LFN_FILE
        jsr KCALL
        bcc _far4       ; (bcs no_device: too far)
        jmp no_device
_far4
        #kc CHROUT
        ; the load address, the header
        lda #<POOL_START
        jsr KCALL
        lda #>POOL_START
        jsr KCALL
        ldx #0
-       lda file_magic,x
        jsr KCALL
        inx
        cpx #FILE_HEADER_LEN
        bne -
        ; the parameters (our zero page's copy), Song on, the start scene
        lda #SAVED_PARAMS
        jsr KCALL
        ldx #0
-       lda @w ZP_OURS + params,x
        jsr KCALL
        inx
        cpx #SAVED_PARAMS
        bne -
        lda song_on
        jsr KCALL
        lda start_scene
        jsr KCALL
        ; the song data's runs
        ldx #0
_run    lda song_runs,x
        sta blk
        lda song_runs+1,x
        sta blk+1
        lda song_runs+2,x
        sta pat
        lda song_runs+3,x
        sta pat+1
        stx disk_len            ; (as a counter here)
        ldy #0
-       lda (blk),y
        jsr KCALL
        iny
        bne +
        inc blk+1
+       lda pat
        bne +
        dec pat+1
+       dec pat
        lda pat
        ora pat+1
        bne -
        lda disk_len
        clc
        adc #4
        tax
        cpx #SONG_RUNS_LEN
        bne _run
        ; each pattern there is: its number, its blocks, their bytes
        ldx #0
_pat    lda PAT_FIRST_HI,x
        beq _next
        stx disk_page
        jsr pat_blocks          ; (pat = the blocks)
        lda disk_page
        jsr KCALL
        lda pat
        jsr KCALL
        lda pat+1
        jsr KCALL
        ldx disk_page
        jsr pat_first
_block  ldy #0
-       lda (blk),y
        jsr KCALL
        iny
        cpy #BLOCK_DATA
        bne -
        jsr blk_next
        bne _block
        ldx disk_page
_next   inx
        bpl _pat                ; (up to NUM_PATTERNS - 1 = 127)
        .cerror NUM_PATTERNS != 128, "disk_save's loop: 128 patterns"
        lda #PATS_END
        jsr KCALL
        jmp close_file          ; the drive's status says if all went well

no_device
        lda #ERR_DEVICE
        sta disk_error
        jmp close_file

; pat_first - blk = pattern X's first block. clobbers A
pat_first
        lda PAT_FIRST_LO,x
        sta blk
        lda PAT_FIRST_HI,x
        sta blk+1
        rts

; blk_next - blk = the block's link; Z set = it was the last. clobbers A, Y
blk_next
        ldy #BLOCK_DATA
        lda (blk),y
        pha
        iny
        lda (blk),y
        sta blk+1
        pla
        sta blk
        lda blk+1
        rts

; pat_blocks - pat = pattern X's blocks. clobbers A, Y, blk
pat_blocks
        jsr pat_first
        lda #0
        sta pat
        sta pat+1
-       inc pat
        bne +
        inc pat+1
+       jsr blk_next
        bne -
        rts

; -----------------------------------------------------------------------------
; disk_load - read the file: the header first (nothing changes if it isn't
; a song of a version we know), then the rest into place: the parameters
; into our zero page's copy, the song data, the patterns' blocks laid one
; after another from POOL_START. ov_changed set once anything changed.
; Sets disk_error on failure.
; -----------------------------------------------------------------------------
disk_load
        ; the command channel, for the status afterwards
        lda #0
        sta disk_len
        lda #LFN_CMD
        ldy #LFN_CMD
        jsr open_cmd_len
        bcs no_device
        #kc READST
        jsr KCALL
        bmi no_device
        ; the file: name.s5,P,R
        ldx #0
        jsr cmd_add_name
        ldy #0
-       lda read_suffix,y
        sta disk_cmd,x
        inx
        iny
        cpy #SUFFIX_RW_LEN
        bne -
        stx disk_len
        lda #LFN_FILE
        ldy #LFN_FILE
        jsr open_cmd_len
        bcs no_device
        #kc CHKIN
        ldx #LFN_FILE
        jsr KCALL
        bcs no_device
        ; the load address (any), the header (ours, a version we know)
        jsr get_byte
        jsr get_byte
        ldx #0
-       stx disk_len            ; (as a counter here)
        jsr get_byte
        ldx disk_len
        cmp file_magic,x
        beq _far5       ; (bne _header: too far)
        jmp _header
_far5
        inx
        cpx #FILE_HEADER_LEN-1  ; the magic; then the version
        bne -
        jsr get_byte
        bne _far6       ; (beq _header: too far) 0: not ours
        jmp _header
_far6
        cmp #FILE_VERSION+1
        bcc _far7       ; (bcs _header: too far) a later version: not for this program
        jmp _header
_far7
        jsr get_status
        beq _far8       ; (bne _header: too far)
        jmp _header
_far8
        ; the parameters (as many as the file has, up to ours), Song on,
        ; the start scene
        lda #1
        sta ov_changed
        jsr tracks_init         ; (no zero page: the tracks as at start, nothing playing)
        jsr get_byte
        sta disk_page           ; (the count, as a counter here)
        ldx #0
_param  cpx disk_page
        beq +
        stx disk_len
        jsr get_byte
        ldx disk_len
        cpx #SAVED_PARAMS
        bcs _skip               ; (one we don't have: skipped)
        sta @w ZP_OURS + params,x
_skip   inx
        bne _param              ; (always)
+       jsr get_byte
        sta ov_song_on
        jsr get_byte
        sta ov_start_scene
        ; the song data's runs
        ldx #0
_run    lda song_runs,x
        sta _dst
        lda song_runs+1,x
        sta _dst+1
        lda song_runs+2,x
        sta pat
        lda song_runs+3,x
        sta pat+1
        stx disk_len
-       jsr get_byte
_dst = * + 1
        sta $ffff               ; (self-modified: where)
        inc _dst
        bne +
        inc _dst+1
+       lda pat
        bne +
        dec pat+1
+       dec pat
        lda pat
        ora pat+1
        bne -
        lda disk_len
        clc
        adc #4
        tax
        cpx #SONG_RUNS_LEN
        bne _run
        jsr get_status
        beq _far9       ; (bne _short: too far)
        jmp _short
_far9
        ; the patterns: none, then each in the file, its blocks laid from
        ; POOL_START on
        lda #0
        ldx #NUM_PATTERNS-1
-       sta PAT_FIRST_HI,x
        dex
        bpl -
        lda #<POOL_START
        sta blk
        lda #>POOL_START
        sta blk+1
_pat    jsr get_byte
        cmp #PATS_END
        beq _done
        tax
        bpl _far10      ; (bmi _bad: too far) (not a pattern: 0..127)
        jmp _bad
_far10
        lda blk                 ; its first block: the next free one
        sta PAT_FIRST_LO,x
        lda blk+1
        sta PAT_FIRST_HI,x
        jsr get_byte            ; its blocks: 1 or more
        sta pat
        jsr get_byte
        sta pat+1
        ora pat
        beq _bad
_block  lda blk+1               ; room for one more?
        cmp #>POOL_END
        bcs _big
        ldy #0
-       sty disk_len
        jsr get_byte
        ldy disk_len
        sta (blk),y
        iny
        cpy #BLOCK_DATA
        bne -
        ; the link: the next block, or none after the pattern's last
        lda blk
        clc
        adc #BLOCK_SIZE
        tax
        lda blk+1
        adc #0
        pha
        lda pat
        bne +
        dec pat+1
+       dec pat
        lda pat
        ora pat+1
        bne +
        pla                     ; (the last: $0000)
        lda #0
        tax
        pha
+       txa
        ldy #BLOCK_DATA
        sta (blk),y
        pla
        iny
        sta (blk),y
        lda blk                 ; on to the next block in the pool
        clc
        adc #BLOCK_SIZE
        sta blk
        bcc +
        inc blk+1
+       lda pat
        ora pat+1
        bne _block
        jsr get_status
        bne _short
        beq _pat                ; (always)
        ; the end: the next free block for ov_loaded
_done   lda blk
        sta ov_free
        lda blk+1
        sta ov_free+1
        jsr get_status
        and #~ST_EOF            ; the file's end is expected here
        bne _short
        jmp close_file

_header jsr get_status          ; the header differs: the file isn't there
        bne close_file          ; (a read error: the drive's status tells why)
        lda #ERR_NOT_OURS
        .byte $2c               ; bit abs: skips the next lda
_bad
_short  lda #ERR_SHORT
        .byte $2c
_big    lda #ERR_TOO_BIG
        sta disk_error
        jmp close_file

; get_byte - the file's next byte in A (Z from it). clobbers X (CHRIN's)
get_byte
        #kc CHRIN
        jsr KCALL
        cmp #0
        rts

; get_status - the KERNAL's status in A (Z: all well). clobbers A
get_status
        #kc READST
        jmp KCALL

; close_file - the file closed, the channels back. clobbers A, X, Y
close_file
        #kc CLRCHN
        jsr KCALL
        #kc CLOSE
        lda #LFN_FILE
        jmp KCALL

; -----------------------------------------------------------------------------
; disk_status - the drive's status line ("00, OK,00,00") from the command
; channel into ov_msg as screen codes, then the channel closed. With no
; drive, nothing is read.
; -----------------------------------------------------------------------------
disk_status
        ldx #39
        lda #CHAR_SPACE
-       sta ov_msg,x
        dex
        bpl -
        lda disk_error
        cmp #ERR_DEVICE
        beq _close
        #kc CHKIN
        ldx #LFN_CMD
        jsr KCALL
        bcs _close
        ldx #0
-       stx disk_len
        jsr get_status
        bne _done
        jsr get_byte
        ldx disk_len
        cmp #$0d                ; the line ends with a carriage return
        beq _done
        sta ov_msg,x            ; (PETSCII digits, capitals, ", ": these screen codes)
        inx
        cpx #40
        bne -
_done   #kc CLRCHN
        jsr KCALL
_close  #kc CLOSE
        lda #LFN_CMD
        jmp KCALL

; -----------------------------------------------------------------------------
; cmd_add_name - disk_name and the suffix ".s5" after disk_cmd's first X
; characters; X = the length after, also in disk_len. clobbers A, Y
; -----------------------------------------------------------------------------
cmd_add_name
        ldy #0
-       cpy disk_name_len
        beq +
        lda disk_name,y
        sta disk_cmd,x
        inx
        iny
        bne -                   ; (always)
+       ldy #0
-       lda name_suffix,y
        sta disk_cmd,x
        inx
        iny
        cpy #SUFFIX_LEN
        bne -
        stx disk_len
        rts

; -----------------------------------------------------------------------------
; open_cmd_len - OPEN logical file A on the drive, secondary address Y,
; with the name disk_cmd (disk_len characters). Carry set = failed.
; -----------------------------------------------------------------------------
open_cmd_len
        pha
        lda @w ZP_OURS + params + P_DRIVE ; (the parameter in our zero page's copy)
        clc
        adc #FIRST_DRIVE
        tax
        #kc SETLFS
        pla
        jsr KCALL
        #kc SETNAM
        lda disk_len
        ldx #<disk_cmd
        ldy #>disk_cmd
        jsr KCALL
        #kc OPEN
        jmp KCALL

; =============================================================================
; After a load (our zero page back, interrupts on)
; =============================================================================

; -----------------------------------------------------------------------------
; ov_loaded - put a loaded song to use: the free blocks after the loaded
; ones chained (the gauge), patterns without blocks and every value out of
; range made safe, the scenes' state, nothing to undo, the player prepared
; from the song's start with the parameters' effects, every row drawn.
; clobbers A, X, Y, ptr
; -----------------------------------------------------------------------------
ov_loaded
        ; the free list: every block from ov_free on, in address order
        lda #0
        sta free_head+1
        sta free_count
        sta free_count+1
        lda ov_free
        sta ptr
        lda ov_free+1
        sta ptr+1
        cmp #>POOL_END
        bcs _patterns           ; (the pool full: none free)
        lda ptr
        sta free_head
        lda ptr+1
        sta free_head+1
_block  inc free_count
        bne +
        inc free_count+1
+       lda ptr                 ; the next block, or none after the pool's end
        clc
        adc #BLOCK_SIZE
        tax
        lda ptr+1
        adc #0
        cmp #>POOL_END
        bcc +
        lda #0
        tax
+       ldy #BLOCK_DATA+1
        sta (ptr),y
        dey
        pha
        txa
        sta (ptr),y
        sta ptr
        pla
        sta ptr+1
        bne _block
        ; patterns: a length 1..MAX_STEPS with blocks, 0 without
_patterns
        ldx #NUM_PATTERNS-1
-       lda PAT_FIRST_HI,x
        beq _none
        lda PAT_STEPS,x
        beq _fix
        cmp #MAX_STEPS+1
        bcc _ok
_fix    lda #16
        bne _set                ; (always)
_none   lda #0
_set    sta PAT_STEPS,x
_ok     dex
        bpl -
        ; the song data's values in range
        ldx #0                  ; a cell: a pattern, or none
-       .for _page := 0, _page < NUM_SCENES * NUM_TRACKS / 256, _page += 1
        lda SCENES + _page * $100,x
        bpl +
        lda #NO_PATTERN
        sta SCENES + _page * $100,x
+
        .endfor
        inx
        bne -
        ldx #NUM_SCENES-1
-       lda SCENE_REPEATS,x
        beq +
        cmp #9+1
        bcc ++
+       lda #1
        sta SCENE_REPEATS,x
+       lda SCENE_BARS,x
        bne +
        lda #SCENE_BARS_DEFAULT
        sta SCENE_BARS,x
+       lda SCENE_SIG,x         ; the beats - 1, 0..15, + SIG_EIGHTHS
        and #SIG_EIGHTHS + 15
        sta SCENE_SIG,x
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda TRACK_CHANNEL,x
        and #15
        sta TRACK_CHANNEL,x
        lda CHANNEL_SYNTH,x
        cmp #SYNTH_COUNT
        bcc +
        lda #0
        sta CHANNEL_SYNTH,x
+       dex
        bpl -
        ; the tracks' order: each track once, else 1-16
        lda #0
        ldx #NUM_TRACKS-1
-       sta disk_cmd,x          ; (as each track's count here)
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda TRACK_ORDER,x
        cmp #NUM_TRACKS
        bcs _order
        tay
        lda disk_cmd,y
        bne _order              ; (twice)
        lda #1
        sta disk_cmd,y
        dex
        bpl -
        bmi _params             ; (always)
_order  ldx #NUM_TRACKS-1
-       txa
        sta TRACK_ORDER,x
        dex
        bpl -
        ; the parameters at most their maximum (else the default)
_params ldx #SAVED_PARAMS-1
-       lda params,x
        cmp param_max,x
        beq +
        bcc +
        lda param_default,x
        sta params,x
+       dex
        bpl -
        ; the scenes' state as at start, with the file's Song and start
        jsr scene_init_vars
        lda ov_song_on
        and #1
        sta song_on
        lda ov_start_scene
        cmp #NUM_SCENES
        bcc +
        lda #0
+       sta start_scene
        ; nothing to undo, no take, nothing under way; the screen afresh
        jsr ov_reset
        ; the parameters' effects, then the player from the song's start
        ldy #P_SWING
        jsr synth_param_changed
        ldy #P_THRU
        jsr synth_param_changed
        sei
        jsr player_init         ; (the tempo, the clock: as at start)
        cli
        rts

; -----------------------------------------------------------------------------
; ov_emptied - a load that failed half way: an empty song, as at start
; (the parameters as loaded so far, kept in range).
; clobbers A, X, Y, ptr
; -----------------------------------------------------------------------------
ov_emptied
        jsr pool_init
        jsr tracks_init
        jsr scene_init
        lda #0
        ldx #NUM_CHANNELS-1
-       sta CHANNEL_SYNTH,x
        dex
        bpl -
        ldx #SAVED_PARAMS-1
-       lda params,x
        cmp param_max,x
        beq +
        bcc +
        lda param_default,x
        sta params,x
+       dex
        bpl -
        jsr ov_reset
        sei
        jsr player_init
        cli
        rts

; ov_reset - after a load: nothing to undo (the grid's, the take's), the
; transport and the live switch idle, the song screen from its top, every
; row to draw. clobbers A, X, Y
ov_reset
        jsr undo_clear
        jsr rec_init
        jsr transport_init
        jsr live_init
        jsr tracks_quiet
        jsr song_init
        jmp song_half_changed

; =============================================================================
; The directory (C= D): the disk's songs (".s5"), one a row, a cursor
; =============================================================================

; -----------------------------------------------------------------------------
; dir_open - (ov_open, DISK_DIR) "READING..." shown, the directory read in
; the disk mode (each name ending in ".s5", the suffix left out, into
; DIR_NAMES: up to DIR_MAX), then shown: the songs' rows, the cursor on
; the first. With none (or a drive's error): the message instead.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dir_open
        lda #DISK_MESSAGE
        sta disk_ui
        lda #BUSY_DIR
        jsr ov_text
        jsr ov_show
        jsr ov_disk_in
        lda #ERR_NONE
        sta disk_error
        sta dir_count
        jsr dir_read
        jsr disk_status
        jsr disk_out
        lda disk_error
        bne _message
        lda dir_count
        bne +
        lda ov_msg              ; none: the drive's words unless "00, OK"
        cmp #CHAR_ZERO
        bne _message
        lda ov_msg+1
        cmp #CHAR_ZERO
        bne _message
        lda #ERR_NO_SONGS
        sta disk_error
_message
        jmp ov_message          ; (ov_run's: the error, or the drive's status)
        ; the list: its title, the cursor on the first, every row
+       lda #0
        sta dir_top
        sta dir_cur
        lda #DISK_DIR
        sta disk_ui
        jmp ov_all_rows

; -----------------------------------------------------------------------------
; dir_read - (the disk mode) the directory ("$", read as a program: a
; line a file, its name between quotes) into DIR_NAMES: the names ending
; ".s5", without it, space-padded to NAME_MAX. Sets disk_error on failure.
; -----------------------------------------------------------------------------
dir_read
        lda #DIR_NAME_LEN
        sta disk_len
        ldx #0
-       lda dir_name,x
        sta disk_cmd,x
        inx
        cpx #DIR_NAME_LEN
        bne -
        lda #LFN_FILE
        ldy #DIR_SA
        jsr open_cmd_len
        bcc +
        jmp no_device
+       #kc CHKIN
        ldx #LFN_FILE
        jsr KCALL
        bcc +
        jmp no_device
+       jsr get_byte            ; the load address
        jsr get_byte
        ; a line: its link (0: the end), its number (the blocks), its text
_line   jsr get_byte
        sta disk_page
        jsr get_byte
        ora disk_page
        beq _end
        jsr get_byte
        jsr get_byte
        jsr get_status
        bne _end
        lda #$ff                ; not in a name yet
        sta disk_len
_char   jsr get_byte
        beq _done_line          ; (the line's end)
        cmp #CHAR_QUOTE
        bne _in
        lda disk_len            ; a quote: the name begins, or ends
        bpl _name_end
        lda #0
        sta disk_len
        beq _char               ; (always)
_in     ldx disk_len
        bmi _char               ; (outside the quotes)
        cpx #NAME_MAX + SUFFIX_LEN
        bcs _char               ; (too long: never ours)
        sta dir_line,x
        inc disk_len
        bne _char               ; (always)
_name_end
        jsr dir_keep
        lda #0                  ; the rest of the line: no more names
        sta disk_len
        dec disk_len
        bmi _char               ; (always)
_done_line
        jsr get_status
        beq _line
_end    jmp close_file

; dir_keep - the name in dir_line (disk_len characters) kept in DIR_NAMES
; if it ends ".s5" and there is room. clobbers A, X, Y
dir_keep
        lda disk_len
        sec
        sbc #SUFFIX_LEN
        bcc _no                 ; (shorter than the suffix)
        beq _no                 ; (the suffix alone)
        tax                     ; X = the name's length without it
        ldy #0
-       lda dir_line,x
        cmp name_suffix,y
        bne _no
        inx
        iny
        cpy #SUFFIX_LEN
        bne -
        lda dir_count
        cmp #DIR_MAX
        bcs _no                 ; (no room: the first DIR_MAX)
        jsr dir_at              ; (blk = its place)
        ldy #0
-       lda #CHAR_SPACE
        cpy disk_len
        bcs +
        lda dir_line,y
+       sta (blk),y
        iny
        cpy #NAME_MAX
        bne -
        lda disk_len            ; (the suffix's place: blanked)
        sec
        sbc #SUFFIX_LEN
        tay
        lda #CHAR_SPACE
-       cpy #NAME_MAX
        bcs +
        sta (blk),y
        iny
        bne -
+       inc dir_count
_no     rts

; dir_at - blk = entry dir_count's (or A's: dir_at_a) place in DIR_NAMES.
; clobbers A, X
dir_at
        lda dir_count
dir_at_a
        tax
        lda #<DIR_NAMES
        sta blk
        lda #>DIR_NAMES
        sta blk+1
-       dex
        bmi +
        lda blk
        clc
        adc #NAME_MAX
        sta blk
        bcc -
        inc blk+1
        bne -                   ; (always)
+       rts

; -----------------------------------------------------------------------------
; dir_key - (ov_key, DISK_DIR) CRSR down / up (SHIFT) the cursor (the list
; scrolled at its ends), RETURN loads the cursor's song, RUN/STOP leaves.
; Carry set.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dir_key
        cmp #KEY_CRSR_DOWN
        beq _move
        cmp #KEY_RUNSTOP
        beq _leave
        cmp #KEY_RETURN
        bne _done
        ; RETURN: the cursor's name, then as the load's prompt
        lda dir_cur
        jsr dir_at_a
        ldy #NAME_MAX           ; its length: without the padding
-       dey
        bmi _done               ; (blank: none)
        lda (blk),y
        cmp #CHAR_SPACE
        beq -
        iny
        sty disk_name_len
-       dey
        lda (blk),y
        sta disk_name,y
        tya
        bne -
        lda #DISK_LOAD
        sta disk_ui
        jsr ov_all_rows         ; (the song's rows again)
        jsr ov_run
        sec
        rts
_leave  lda #0
        sta disk_ui
        jsr ov_all_rows
_done   sec
        rts
        ; the cursor down (SHIFT: up), the list scrolled to keep it shown
_move   ldx dir_cur
        lda shift_held
        bne _up
        inx
        cpx dir_count
        bcs _done
        stx dir_cur
        txa
        sec
        sbc dir_top
        cmp #DIR_ROWS
        bcc _rows
        inc dir_top
        jmp ov_all_rows_used
_up     dex
        bmi _done
        stx dir_cur
        cpx dir_top
        bcs _rows
        stx dir_top
        jmp ov_all_rows_used
        ; only the two rows: the old cursor's and the new
_rows   txa                     ; (the new: X)
        jsr _row
        ldx dir_cur
        lda shift_held
        bne +
        dex
        dex
+       inx                     ; (the old: one before or after)
        txa
        jsr _row
        sec
        rts
_row    sec
        sbc dir_top
        clc
        adc #SONG_GRID_ROW
        tax
        jmp song_urgent_row

; -----------------------------------------------------------------------------
; dir_prepare - (ov_prepare, DISK_DIR; song_blank_line done) row X: the
; title "DIRECTORY 8: 12 SONGS", rows 1-2 blank, then the songs, the
; cursor's reversed.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dir_prepare
        cpx #SONG_TITLE_ROW
        beq _title
        cpx #SONG_GRID_ROW
        bcc _blank
        txa
        sec
        sbc #SONG_GRID_ROW
        clc
        adc dir_top
        cmp dir_count
        bcs _blank
        sta disk_page           ; (the entry)
        jsr dir_at_a
        ; the cursor's: ">" before it, the name white (not reversed:
        ; song_put_line puts at most PUT_AT_ONCE reversed places)
        ldx #COL_LABEL
        lda disk_page
        cmp dir_cur
        bne +
        lda #CHAR_MARK
        sta song_line+DIR_COL-2
        ldx #COL_SONG_TITLE
+       stx disk_len            ; (the name's colour, here)
        ldy #NAME_MAX-1
-       lda (blk),y
        sta song_line+DIR_COL,y
        lda disk_len
        sta song_line_col+DIR_COL,y
        dey
        bpl -
        lda disk_len
        sta song_line_col+DIR_COL-2
_blank  rts
_title  ldy #0
-       lda dir_title,y
        jsr _put
        cpy #DIR_TITLE_LEN
        bne -
        jsr drive_digits
        ldx #0
-       lda drive_text,x
        jsr _put
        inx
        cpx drive_text_len
        bne -
        lda #CHAR_COLON
        jsr _put
        iny
        lda dir_count           ; the songs: 1-2 digits
        ldx #CHAR_ZERO-1
        sec
-       inx
        sbc #10
        bcs -
        adc #10 + CHAR_ZERO
        pha
        txa
        cmp #CHAR_ZERO
        beq +
        jsr _put
+       pla
        jsr _put
        ldx #0
-       lda dir_songs,x
        jsr _put
        inx
        cpx #DIR_SONGS_LEN
        bne -
        rts
_put    sta song_line,y
        lda #COL_SONG_TITLE
        sta song_line_col,y
        iny
        rts

; =============================================================================
; Tables, texts and the overlay's variables
; =============================================================================
LFN_FILE        = 2             ; the data file's logical file and secondary address
LFN_CMD         = 15            ; the drive's command / error channel
FILE_VERSION    = 1
PATS_END        = $ff           ; after the last pattern
SAVED_PARAMS    = P_DRIVE       ; every parameter but Disk drive (the last)
        .cerror P_DRIVE != NUM_PARAMS - 1, "Disk drive must be the last parameter"
SYNTH_COUNT     = 4             ; CHANNEL_SYNTH: none, SID303, SID808, SID101
NUM_CHANNELS    = 16

ERR_NONE        = 0
ERR_DEVICE      = 1             ; no drive of that number (or it would not take the file)
ERR_NOT_OURS    = 2             ; the file isn't a SID500 song
ERR_SHORT       = 3             ; the file ended early (or made no sense)
ERR_TOO_BIG     = 4             ; more blocks than the pool has
ERR_PLAYING     = 5             ; started meanwhile (a master's Start): not now
ERR_NO_SONGS    = 6             ; the directory: no ".s5" file
ERR_LAST        = 6

        .enc "none"             ; (plain PETSCII: 64tass -a, lowercase = what DOS wants)
file_magic      .text "sid500"
                .byte FILE_VERSION
FILE_HEADER_LEN = * - file_magic
scratch_text    .text "s0:"
SCRATCH_LEN     = * - scratch_text
name_suffix     .text ".s5"
SUFFIX_LEN      = * - name_suffix
write_suffix    .text ",p,w"
SUFFIX_RW_LEN   = * - write_suffix
read_suffix     .text ",p,r"
default_name    .text "song"
DEFAULT_NAME_LEN = * - default_name
dir_name        .text "$"           ; the directory, read as a program
DIR_NAME_LEN    = * - dir_name
DIR_SA          = 0
CHAR_QUOTE      = $22
DIR_NAMES       = GRID_STEP_LO      ; the names (NAME_MAX each, space-padded): the
DIR_MAX         = (GRID_STEP_HI + MAX_STEPS + 1 - GRID_STEP_LO) / NAME_MAX ; grid's step
                                    ; index, free while stopped (the take's after it)
DIR_ROWS        = SONG_ROWS         ; names shown at once
DIR_COL         = 2                 ; their first place

; the song data saved: runs of (address, length)
song_runs       .word PAT_STEPS, CHANNEL_SYNTH + NUM_CHANNELS - PAT_STEPS
                .word TRACK_CHANNEL, TRACK_QUIET - TRACK_CHANNEL
                .word SCENE_BARS, SONG_DATA_END - SCENE_BARS
SONG_RUNS_LEN   = * - song_runs
        .cerror CHANNEL_SYNTH != SCENE_REPEATS + NUM_SCENES || SCENE_REPEATS != PAT_STEPS + NUM_PATTERNS, "song_runs: the first run"
        .cerror TRACK_ORDER != TRACK_CHANNEL + 16 || TRACK_MUTE != TRACK_ORDER + 16 || TRACK_SOLO != TRACK_MUTE + 16 || TRACK_QUIET != TRACK_SOLO + 16, "song_runs: the second run"
        .cerror SCENE_SIG != SCENE_BARS + NUM_SCENES || SCENES != SCENE_SIG + NUM_SCENES, "song_runs: the third run"

; PETSCII of each key that may go into a file name, index = key code
; (column * 8 + row), 0 = not one (SID101's)
name_chars
        .byte 0, 0, 0, 0, 0, 0, 0, 0                    ; DEL RETURN CRSR F7 F1 F3 F5 CRSR
        .text "3wa4zse"                                 ; 3 W A 4 Z S E
        .byte 0                                         ; LSHIFT
        .text "5rd6cftx"
        .text "7yg8bhuv"
        .text "9ij0mkon"
        .text "+pl-."                                   ; + P L - .
        .byte 0, 0, 0                                   ; : @ ,
        .byte 0, 0, 0, 0, 0, 0, 0, 0                    ; pound * ; HOME RSHIFT = up /
        .text "1"
        .byte 0, 0                                      ; <- CTRL
        .text "2 "                                      ; 2 SPACE
        .byte 0                                         ; C=
        .text "q"
        .byte 0                                         ; RUN/STOP
        .cerror * - name_chars != 64, "name_chars: 64 keys"

        .enc "screen"
CHAR_COLON      = $3a
prompt_texts    .text "SAVE "
PROMPT_LEN      = * - prompt_texts
prompt_load     .text "LOAD "
dir_title       .text "DIRECTORY "
DIR_TITLE_LEN   = * - dir_title
dir_songs       .text " SONGS"
DIR_SONGS_LEN   = * - dir_songs
OV_TEXT_LEN     = 24
ov_texts
BUSY_SAVE       = * - ov_texts
                .text format("%-24s", "SAVING...")
BUSY_LOAD       = * - ov_texts
                .text format("%-24s", "LOADING...")
BUSY_DIR        = * - ov_texts
                .text format("%-24s", "READING...")
err_texts       .text format("%-24s", "NO DRIVE")       ; + the number (ov_run)
NO_DRIVE_LEN    = len("NO DRIVE")
                .text format("%-24s", "NOT A SID500 SONG")
                .text format("%-24s", "FILE ENDED EARLY")
                .text format("%-24s", "SONG TOO BIG")
                .text format("%-24s", "STOP FIRST")
                .text format("%-24s", "NO SONGS ON THE DISK")
err_text_ofs    .for _e := 0, _e < ERR_LAST, _e += 1   ; per ERR_* - 1
                .byte err_texts - ov_texts + _e * OV_TEXT_LEN
                .endfor
        .enc "none"

; the routines run at start and after a load (sid500.asm twice: their
; start-up copies in init_code; these here, after the id the overlay is
; known by at DISK_OV). clobber A, X
pool_init       #pool_init_body
song_init       #song_init_body

; the overlay's variables (its RAM: not in the file)
ov_vars
ov_kind         = ov_vars       ; DISK_SAVE or DISK_LOAD being done
disk_error      = ov_kind + 1   ; ERR_*
ov_changed      = disk_error + 1 ; nonzero: a load changed the song already
disk_len        = ov_changed + 1 ; the command's length; a counter
disk_page       = disk_len + 1  ; a counter
ov_free         = disk_page + 1 ; (2) a load: the first block not loaded
ov_song_on      = ov_free + 2   ; a load: Song on, the start scene
ov_start_scene  = ov_song_on + 1
drive_text      = ov_start_scene + 1 ; (2) the drive's digits
drive_text_len  = drive_text + 2
CMD_MAX         = SCRATCH_LEN + NAME_MAX + SUFFIX_LEN + SUFFIX_RW_LEN
ov_msg          = drive_text_len + 1 ; (40) the message on the title row
dir_count       = ov_msg + 40   ; the directory: its songs
dir_top         = dir_count + 1 ;   the first shown
dir_cur         = dir_top + 1   ;   the cursor's
dir_line        = dir_cur + 1   ; (NAME_MAX + SUFFIX_LEN) a name as read
ov_vars_end     = dir_line + NAME_MAX + SUFFIX_LEN
        .cerror ov_vars_end > DISK_OV_END, "the overlay runs into the grid's step index"
        .send disk_ov
.else
        .section late_code
hi3_in  rts                     ; (no disk: HI3_CODE never out)
        .send
disk_copy_all   = io_copy_all   ; (no disk: the hooks to their own)
disk_key        = names_key
disk_prepare    = song_prepare
.endif
