; disk.asm - part of SID808, included by sid808.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Save and load (docs/sequencer.md, Disk): every pattern, the song, tempo,
; swing and mute in one PRG file, on the drive the Disk drive parameter
; picks (8..16), through the KERNAL. The
; program normally has the ROMs banked out and owns all of zero page and
; the interrupt vectors, so a disk operation (disk_run):
;   1. stops the sequencer, silences the voices, lets queued MIDI out go
;   2. turns every interrupt source off at the chip (CIA1, the ACIA): with
;      the KERNAL banked in, the vectors at $FFFA/$FFFE are the ROM's
;   3. swaps zero page for the KERNAL's own (core KERNAL_ZP_COPY: as BASIC's
;      SYS left it), banks the KERNAL in, turns its messages off
;   4. writes or reads the file (no zero page of ours may be used here: our
;      variables are in ZP_OURS meanwhile), reads the drive's status
;   5. puts it all back: our zero page, the ROMs out, the tick timer and
;      MIDI as at start-up
;
; File: load address $8000 (a PRG), then FILE_MAGIC (6 bytes) and
; FILE_VERSION, the 64 patterns (cells and length, PAT_BYTES each), the
; song block (song_pat, song_rep, song_len), then tempo, swing and the mute
; bits; from version 2 the sound knobs (knobs.asm: knob_level, knob_tune,
; knob_decay; from version 3 knob_tone too). A load checks the header
; before it writes anything, and takes older files too (the knobs they
; lack get their defaults).

; RAM ($C400-$C6FF; $C300 is the MIDI transmit ring)
ZP_OURS         = $c400         ; 256 bytes: our zero page during a disk operation
                                ; ($C500: the KERNAL's, sid808.asm KERNAL_ZP_COPY)
disk_name       = $c600         ; NAME_MAX bytes: the file name (PETSCII), kept as the default
disk_name_len   = disk_name + NAME_MAX
disk_kind       = disk_name_len + 1 ; DISK_SAVE or DISK_LOAD
disk_error      = disk_kind + 1 ; 0 = done; else an error of ours (ERR_*), or the drive's
disk_page       = disk_error + 1 ; save/load: pattern page high byte
disk_len        = disk_page + 1 ; length of the command / name string in disk_cmd
disk_cmd        = disk_len + 1  ; CMD_MAX bytes: "S0:" name, or name ",P,W" / ",P,R"
disk_msg        = disk_cmd + CMD_MAX ; 40 screen codes: the message the song row shows
drive_text      = disk_msg + 40 ; 2 characters: the drive's number (drive_digits)
drive_text_len  = drive_text + 2 ; 1 or 2
disk_version    = drive_text_len + 1 ; load: the file's version
DISK_RAM_END    = disk_version + 1
        .cerror DISK_RAM_END > $c700, "disk variables run past $C6FF"
        .cerror KERNAL_ZP_COPY != ZP_OURS + $100, "disk: zero page copies at $C400 and $C500"

NAME_MAX        = 16            ; file name characters
CMD_MAX         = NAME_MAX + 4  ; + "S0:" or ",P,W"
DISK_SAVE       = 1
DISK_LOAD       = 2
FIRST_DRIVE     = 8             ; the Disk drive parameter: 0 = drive 8 ...
LAST_DRIVE      = 16            ; ... 8 = drive 16
LFN_FILE        = 2             ; logical file and secondary address of the data file
LFN_CMD         = 15            ; the drive's command / error channel

ERR_NONE        = 0
ERR_DEVICE      = 1             ; no drive of that number (or it would not take the file)
ERR_NOT_OURS    = 2             ; the file isn't a SID808 file
ERR_SHORT       = 3             ; the file ended early (or a read error)

FILE_VERSION    = 3             ; 3: + Tone, 2: + the other sound knobs (older ones still load)
PAT_BYTES       = PAT_LENGTH + 1 ; cells and the length byte
KERNAL_IO       = $36           ; $01 value: KERNAL ROM and I/O in, BASIC out ($A000 stays RAM)

; KERNAL entry points (jump table)
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
ST_EOF          = %01000000     ; READST: end of file
ST_NO_DEVICE    = %10000000     ; READST: device not present

        .section zp
disk_mode       .byte ?         ; the name prompt on the song row: 0 none, DISK_SAVE, DISK_LOAD
msg_on          .byte ?         ; nonzero: the song row shows disk_msg (until a key)
        .send

; -----------------------------------------------------------------------------
; disk_init - from synth_init (after the core's init_vars set the parameter
; defaults): the Disk drive parameter = the drive the program was loaded
; from (the KERNAL's last device, $BA, in the zero page kept at start);
; 0 (none yet) or a device outside 8..16 (1 = tape): drive 8. And the
; default file name.
; clobbers A, X
; -----------------------------------------------------------------------------
KERNAL_LAST_DEVICE = $ba        ; KERNAL zero page: the last device number used (FA)

disk_init
.if TEST_DRIVE == 0             ; (test builds set the drive themselves)
        lda KERNAL_ZP_COPY + KERNAL_LAST_DEVICE
        sec
        sbc #FIRST_DRIVE
        cmp #LAST_DRIVE - FIRST_DRIVE + 1
        bcc +                   ; 8..16 (below 8 wrapped round: too big)
        lda #0                  ; else drive 8
+       sta params+P_DRIVE
.endif
        ldx #DEFAULT_NAME_LEN-1
-       lda default_name,x
        sta disk_name,x
        dex
        bpl -
        lda #DEFAULT_NAME_LEN
        sta disk_name_len
        rts

; =============================================================================
; The disk operation
; =============================================================================

; -----------------------------------------------------------------------------
; disk_run - save or load (disk_kind) the file disk_name; the result goes
; into disk_msg (the song row shows it, msg_on). Takes seconds; nothing else
; runs meanwhile (no sound, no MIDI).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
disk_run
        ; 1. stop, silence, let MIDI out send what it has (the stop byte)
        lda seq_play
        beq +
        jsr seq_toggle
+       jsr all_notes_off
        jsr tx_drain

        ; 2. interrupt sources off at the chips; the ACIA reset, so the
        ; handlers have nothing to do (midi_init sets it all up again)
        sei
        lda #$7f
        sta CIA1_ICR
        lda CIA1_ICR            ; acknowledge one pending
        ldx midi_if_active
        beq +
        lda if_ctrl,x
        sta _acia_ctrl
        lda #ACIA_RESET
_acia_ctrl = *+1                ; low byte: the interface's control register
        sta $de00
+       lda #0
        sta midi_irq_mode
        sta midi_nmi_mode

        ; 3. zero page: ours away, the KERNAL's back; KERNAL in, no messages
        ldx #2
-       lda $00,x
        sta ZP_OURS,x
        lda KERNAL_ZP_COPY,x
        sta $00,x
        inx
        bne -
        lda #KERNAL_IO
        sta CPU_PORT
        lda #0
        sta disk_error
        jsr SETMSG              ; A = 0: no "SAVING" etc. (they would print to the screen)

        ; 4. the file, then the drive's status
        lda disk_kind
        cmp #DISK_SAVE
        bne +
        jsr disk_save
        jmp ++
+       jsr disk_load
+       jsr disk_status

        ; 5. back: ROMs out, zero page ours again (the KERNAL's kept for the
        ; next time: its open files etc.), the tick timer as at start
        lda #RAM_IO
        sta CPU_PORT
        ldx #2
-       lda $00,x
        sta KERNAL_ZP_COPY,x
        lda ZP_OURS,x
        sta $00,x
        inx
        bne -
        lda #<TICK_LATCH
        sta CIA1_TA_LO
        lda #>TICK_LATCH
        sta CIA1_TA_HI
        lda #%00010001          ; force latch load, start, continuous mode
        sta CIA1_CRA
        lda #%10000001          ; timer A interrupt on
        sta CIA1_ICR
        lda CIA1_ICR            ; nothing pending from before
        lda tick_count
        sta tick_done           ; no ticks to catch up
        jsr midi_init           ; the interface and both rings afresh
        cli

        ; a load: make what came in safe, then use it
        lda disk_kind
        cmp #DISK_LOAD
        bne +
        jsr song_loaded
+       jsr disk_message
        lda #1
        sta grid_full           ; redraw everything (after any disk operation)
        rts

; -----------------------------------------------------------------------------
; song_loaded - after a song file came in (a disk load, a SysEx dump): make
; it safe (load_check, knob_check: the sound page shows the loaded knobs),
; forget the undo steps, use its tempo, start from pattern 1 and the
; song's start, and redraw the whole grid.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
song_loaded
        jsr load_check
        jsr undo_clear          ; nothing before the load can be undone
        jsr knob_check
        jsr seq_set_tempo
        lda #0
        sta edit_pat
        sta seq_next
        sta song_cur
        lda #1
        sta grid_full           ; redraw everything
        rts

; -----------------------------------------------------------------------------
; tx_drain - wait (at most ~0.6 s) until MIDI out has sent its queue and the
; last byte has left the ACIA (another ~1 ms). Interrupts on.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
tx_drain
        ldy #0
        ldx #0
-       lda tx_tail
        cmp tx_head
        beq _sent
        dex
        bne -
        dey
        bne -
        rts                     ; gave up (an interface that doesn't send)
_sent   ldx #200                ; ~1 ms: the byte in the shift register
-       dex
        bne -
        rts

; =============================================================================
; With the KERNAL (inside disk_run step 4: no zero page of ours)
; =============================================================================

; -----------------------------------------------------------------------------
; disk_save - scratch an old file of the name (S0:), then write the file.
; Sets disk_error on failure.
; -----------------------------------------------------------------------------
disk_save
        ; command channel with "S0:name": an old file of the name goes
        ; (not "@0:" save-with-replace, which the 1541 can get wrong)
        ldx #0
-       lda scratch_text,x
        sta disk_cmd,x
        inx
        cpx #3
        bne -
        jsr cmd_add_name
        lda #LFN_CMD
        ldy #LFN_CMD
        jsr open_cmd_len
        bcc +
        jmp _no_device
+
        jsr READST
        bpl +
        jmp _no_device
+

        ; the file: name,P,W
        ldx #0
        jsr cmd_add_name
        ldy #0
-       lda write_suffix,y
        sta disk_cmd,x
        inx
        iny
        cpy #4
        bne -
        stx disk_len
        lda #LFN_FILE
        ldy #LFN_FILE
        jsr open_cmd_len
        bcc +
        jmp _no_device
+
        ldx #LFN_FILE
        jsr CHKOUT
        bcc +
        jmp _no_device
+

        ; load address, header
        lda #<PATTERN_RAM
        jsr CHROUT
        lda #>PATTERN_RAM
        jsr CHROUT
        ldx #0
-       lda file_magic,x
        jsr CHROUT
        inx
        cpx #FILE_HEADER_LEN
        bne -

        ; the patterns: PAT_BYTES of each page
        lda #>PATTERN_RAM
        sta disk_page
_page   lda disk_page
        sta _src+2
        ldx #0
_src    lda PATTERN_RAM,x       ; high byte: the page (self-modified)
        jsr CHROUT
        inx
        cpx #PAT_BYTES
        bne _src
        inc disk_page
        lda disk_page
        cmp #(>PATTERN_RAM) + NUM_PATTERNS ; (">" binds the whole sum)
        bne _page

        ; the song block, then tempo, swing, mute (from our zero page copy)
        ldx #0
-       lda song_pat,x
        jsr CHROUT
        inx
        cpx #SONG_END - song_pat
        bne -
        lda ZP_OURS + seq_bpm
        jsr CHROUT
        lda ZP_OURS + seq_swing
        jsr CHROUT
        lda ZP_OURS + mute
        jsr CHROUT
        lda ZP_OURS + mute + 1
        jsr CHROUT
        ; (version 3) the sound knobs
        ldx #0
-       lda knob_level,x
        jsr CHROUT
        inx
        cpx #KNOBS_END - knob_level
        bne -
        jsr CLRCHN
        lda #LFN_FILE
        jmp CLOSE               ; the drive's status says if all went well

_no_device
        lda #ERR_DEVICE
        sta disk_error
        jsr CLRCHN
        lda #LFN_FILE
        jmp CLOSE

; -----------------------------------------------------------------------------
; disk_load - read the file: the header first (nothing changes if it isn't
; ours), then the patterns, the song and the settings (settings into our
; zero page copy). Sets disk_error on failure.
; -----------------------------------------------------------------------------
disk_load
        ; the command channel, for the status afterwards
        lda #0
        sta disk_len
        lda #LFN_CMD
        ldy #LFN_CMD
        jsr open_cmd_len
        bcc +
        jmp _no_device
+
        jsr READST
        bpl +
        jmp _no_device
+

        ; the file: name,P,R
        ldx #0
        jsr cmd_add_name
        ldy #0
-       lda read_suffix,y
        sta disk_cmd,x
        inx
        iny
        cpy #4
        bne -
        stx disk_len
        lda #LFN_FILE
        ldy #LFN_FILE
        jsr open_cmd_len
        bcc +
        jmp _no_device
+
        ldx #LFN_FILE
        jsr CHKIN
        bcc +
        jmp _no_device
+

        ; load address (any), header (must match)
        jsr CHRIN
        jsr CHRIN
        ldx #0
-       stx disk_page           ; (as a counter here)
        jsr CHRIN
        ldx disk_page
        cmp file_magic,x
        bne _bad_header
        inx
        cpx #FILE_HEADER_LEN-1  ; the magic; then the version
        bne -
        jsr CHRIN
        sta disk_version
        beq _bad_header         ; 0: not ours
        cmp #FILE_VERSION+1
        bcc _version_ok         ; a later version: not for this program
_bad_header
        jmp _header
_version_ok
        jsr READST
        beq +
        jmp _not_ours           ; (missing file: the read failed)
+

        ; the patterns
        lda #>PATTERN_RAM
        sta disk_page
_page   lda disk_page
        sta _dst+2
        ldx #0
-       stx disk_len            ; (CHRIN may not keep X)
        jsr CHRIN
        ldx disk_len
_dst    sta PATTERN_RAM,x       ; high byte: the page (self-modified)
        inx
        cpx #PAT_BYTES
        bne -
        jsr READST
        beq +
        jmp _short              ; ended (or failed) before the song
+       inc disk_page
        lda disk_page
        cmp #(>PATTERN_RAM) + NUM_PATTERNS ; (">" binds the whole sum)
        bne _page

        ; the song block, then tempo, swing, mute (into our zero page copy)
        ldx #0
-       stx disk_len
        jsr CHRIN
        ldx disk_len
        sta song_pat,x
        inx
        cpx #SONG_END - song_pat
        bne -
        jsr CHRIN
        sta ZP_OURS + seq_bpm
        jsr CHRIN
        sta ZP_OURS + seq_swing
        jsr CHRIN
        sta ZP_OURS + mute
        jsr CHRIN
        sta ZP_OURS + mute + 1
        ; the sound knobs: version 3 all, version 2 all but Tone, else the
        ; defaults
        lda disk_version
        cmp #2
        bcc _no_knobs
        ldx #NUM_SOUNDS-1       ; Tone at the default (version 3 reads it over)
-       jsr tone_default
        dex
        bpl -
        ldx #KNOBS_END - knob_level
        lda disk_version
        cmp #3
        bcs +
        ldx #KNOBS_V2_END - knob_level
+       stx disk_page           ; (free here: the knob bytes to read)
        ldx #0
-       stx disk_len
        jsr CHRIN
        ldx disk_len
        sta knob_level,x
        inx
        cpx disk_page
        bne -
        jmp _end
_no_knobs
        ldx #NUM_SOUNDS-1
-       jsr knob_defaults
        dex
        bpl -
_end    jsr READST
        and #~ST_EOF            ; the end of the file is expected here
        bne _short
        jmp _close

_header jsr READST              ; the header differs: the file isn't there
        bne _close              ; (a read error: the drive's status tells why)
_not_ours
        lda #ERR_NOT_OURS
        .byte $2c               ; bit abs: skips the next lda
_short  lda #ERR_SHORT
        sta disk_error
_close  jsr CLRCHN
        lda #LFN_FILE
        jmp CLOSE

_no_device
        lda #ERR_DEVICE
        sta disk_error
        jsr CLRCHN
        lda #LFN_FILE
        jmp CLOSE

; -----------------------------------------------------------------------------
; disk_status - the drive's status line ("00, OK,00,00") from the command
; channel into disk_msg as screen codes, then close it. With no drive,
; nothing is read. (KERNAL)
; -----------------------------------------------------------------------------
disk_status
        ldx #39
        lda #CHAR_SPACE
-       sta disk_msg,x
        dex
        bpl -
        lda disk_error
        cmp #ERR_DEVICE
        beq _close
        ldx #LFN_CMD
        jsr CHKIN
        bcs _close
        ldx #0
-       stx disk_len
        jsr READST
        bne _done
        jsr CHRIN
        ldx disk_len
        cmp #$0d                ; the line ends with a carriage return
        beq _done
        sta disk_msg,x          ; PETSCII digits, capitals, ", " = these screen codes
        inx
        cpx #40
        bne -
_done   jsr CLRCHN
_close  lda #LFN_CMD
        jmp CLOSE

; -----------------------------------------------------------------------------
; cmd_add_name - append disk_name to disk_cmd at X; out: X = new length.
; clobbers A, Y
; -----------------------------------------------------------------------------
cmd_add_name
        ldy #0
-       cpy disk_name_len
        beq +
        lda disk_name,y
        sta disk_cmd,x
        inx
        iny
        bne -                   ; always
+       stx disk_len
        rts

; -----------------------------------------------------------------------------
; open_cmd_len - OPEN logical file A, the Disk drive parameter's drive,
; secondary address Y, with the name disk_cmd (disk_len characters).
; Out: carry set = failed. (KERNAL: the parameter is read from our zero
; page's copy)
; -----------------------------------------------------------------------------
open_cmd_len
        pha
        lda ZP_OURS + params + P_DRIVE
        clc
        adc #FIRST_DRIVE
        tax
        pla
        jsr SETLFS
        lda disk_len
        ldx #<disk_cmd
        ldy #>disk_cmd
        jsr SETNAM
        jmp OPEN

; =============================================================================
; After a load, back with our zero page
; =============================================================================

; -----------------------------------------------------------------------------
; load_check - make a loaded (maybe damaged) file safe: pattern lengths
; 1..16, the song's length, patterns and repeats in range, tempo and swing
; in range. clobbers A, X, Y
; -----------------------------------------------------------------------------
load_check
        ldx #0
_pat    txa
        clc
        adc #>PATTERN_RAM
        sta _len+2
        sta _set+2
_len    lda PATTERN_RAM + PAT_LENGTH ; (high byte self-modified)
        beq _fix
        cmp #SEQ_STEPS+1
        bcc _ok
_fix    lda #SEQ_STEPS
_set    sta PATTERN_RAM + PAT_LENGTH
_ok     inx
        cpx #NUM_PATTERNS
        bne _pat

        lda song_len
        cmp #SONG_MAX+1
        bcc +
        lda #0                  ; nonsense: no song
        sta song_len
+       ldx #SONG_MAX-1
-       lda song_pat,x
        and #NUM_PATTERNS-1
        sta song_pat,x
        lda song_rep,x
        beq _rep
        cmp #SONG_REP_MAX+1
        bcc +
_rep    lda #1
        sta song_rep,x
+       dex
        bpl -

        lda seq_bpm
        cmp #BPM_MIN
        bcc _bpm
        cmp #BPM_MAX+1
        bcc +
_bpm    lda #SEQ_BPM_DEFAULT
        sta seq_bpm
+       lda seq_swing
        cmp #SWING_MAX+1
        bcc +
        lda #0
        sta seq_swing
+       lda mute+1
        and #%00011111          ; sounds 8..12
        sta mute+1
        rts

; -----------------------------------------------------------------------------
; disk_message - disk_msg for the song row: our own error text, or the
; drive's status line (disk_status put it there); shown until a key.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
disk_message
        ldx disk_error
        beq _shown              ; the drive's own words
        lda err_text_ofs-1,x
        tax
        ldy #0
-       lda err_texts,x
        sta disk_msg,y
        inx
        iny
        cpy #ERR_TEXT_LEN
        bne -
        ldx #ERR_TEXT_LEN       ; the rest blank
        lda #CHAR_SPACE
-       sta disk_msg,x
        inx
        cpx #40
        bne -
        lda disk_error
        cmp #ERR_DEVICE
        bne _shown
        jsr drive_digits        ; "NO DRIVE" + the number
        ldx #0
        ldy #NO_DRIVE_LEN+1
-       lda drive_text,x
        sta disk_msg,y
        iny
        inx
        cpx drive_text_len
        bne -
_shown  lda #1
        sta msg_on
        rts

; =============================================================================
; The name prompt (song row), from synth_key
; =============================================================================

; -----------------------------------------------------------------------------
; prompt_key - a key while the prompt is up. A: key code (presses only).
; RETURN: save / load; RUN/STOP: cancel; DEL: delete a character; letters,
; digits, space, + - .: type.
; -----------------------------------------------------------------------------
prompt_key
        cmp #KC_RETURN
        beq _go
        cmp #KC_STOP
        beq _cancel
        cmp #KC_DEL
        beq _delete
        tax
        lda name_chars,x
        beq _done               ; not a name character
        ldx disk_name_len
        cpx #NAME_MAX
        bcs _done               ; full
        sta disk_name,x
        inc disk_name_len
_done   jmp key_done
_delete ldx disk_name_len
        beq _done
        dec disk_name_len
        jmp key_repeat
_cancel lda #0
        sta disk_mode
        jmp key_done
_go     lda disk_name_len
        beq _done               ; no name
        lda disk_mode
        sta disk_kind
        lda #0
        sta disk_mode
        ; "SAVING ..." / "LOADING ..." on the song row while it runs
        ldx #39
        lda #CHAR_SPACE
-       sta disk_msg,x
        dex
        bpl -
        ldx #0
        lda disk_kind
        cmp #DISK_SAVE
        beq +
        ldx #busy_load - busy_texts
+       ldy #0
-       lda busy_texts,x
        sta disk_msg,y
        inx
        iny
        cpy #BUSY_LEN
        bne -
        lda #1
        sta msg_on
        ldx #GRID_SONG_ROW
        jsr grid_draw_song
        jsr disk_run
        jmp key_done

; -----------------------------------------------------------------------------
; draw_prompt - "SAVE 8: xxxx_" / "LOAD 8: xxxx_" (the drive, then the
; name) on the song row ((ptr) = the row, cleared). clobbers A, X, Y
; -----------------------------------------------------------------------------
draw_prompt
        lda disk_mode
        cmp #DISK_SAVE
        beq +
        ldx #prompt_load - prompt_texts
        .byte $2c               ; bit abs: skips the next ldx
+       ldx #0
        ldy #0
-       lda prompt_texts,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        cpy #PROMPT_LEN
        bne -
        jsr drive_digits        ; the drive and ':'
        ldx #0
-       lda drive_text,x
        ora #REVERSE
        sta (ptr),y
        iny
        inx
        cpx drive_text_len
        bne -
        lda #CHAR_COLON | REVERSE
        sta (ptr),y
        iny
        iny                     ; a space, then the name (screen code = PETSCII here)
        ldx #0
-       cpx disk_name_len
        beq +
        lda disk_name,x
        sta (ptr),y
        inx
        iny
        bne -                   ; always
+       lda #CHAR_SPACE | REVERSE ; the cursor
        sta (ptr),y
        rts

; -----------------------------------------------------------------------------
; drive_digits - the drive's number (Disk drive parameter) as screen codes
; in drive_text, drive_text_len = 1 or 2. clobbers A
; -----------------------------------------------------------------------------
drive_digits
        lda params+P_DRIVE
        clc
        adc #FIRST_DRIVE
        cmp #10
        bcs _two
        adc #CHAR_ZERO          ; carry clear
        sta drive_text
        lda #1
        sta drive_text_len
        rts
_two    sbc #10                 ; carry set: 10..16 -> 0..6, no borrow
        clc
        adc #CHAR_ZERO
        sta drive_text+1
        lda #CHAR_ZERO+1
        sta drive_text
        lda #2
        sta drive_text_len
        rts

; -----------------------------------------------------------------------------
; draw_message - disk_msg on the song row ((ptr) = the row).
; clobbers A, Y
; -----------------------------------------------------------------------------
draw_message
        ldy #39
-       lda disk_msg,y
        sta (ptr),y
        dey
        bpl -
        rts

; =============================================================================
; Tables and texts
; =============================================================================

file_magic      .text "sid808"  ; (64tass -a: lowercase source = plain PETSCII, as DOS wants)
                .byte FILE_VERSION
FILE_HEADER_LEN = * - file_magic
scratch_text    .text "s0:"
write_suffix    .text ",p,w"
read_suffix     .text ",p,r"
default_name    .text "song"
DEFAULT_NAME_LEN = * - default_name

; PETSCII of each key that may go into a file name, index = key code
; (column*8 + row, keyboard matrix as src/keymap.asm), 0 = not one
name_chars
        .byte 0, 0, 0, 0, 0, 0, 0, 0                    ; DEL RETURN CRSR F7 F1 F3 F5 CRSR
        .text "3wa4zse"                                 ; 3 W A 4 Z S E (lowercase:
        .byte 0                                         ; LSHIFT     plain PETSCII, 64tass -a)
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
prompt_texts    .text "SAVE "
PROMPT_LEN      = * - prompt_texts
prompt_load     .text "LOAD "
CHAR_COLON      = $3a
busy_texts      .text "SAVING... "
BUSY_LEN        = * - busy_texts
busy_load       .text "LOADING..."
ERR_TEXT_LEN    = 24
err_texts       .text format("%-24s", "NO DRIVE")          ; + the number (disk_message)
NO_DRIVE_LEN    = len("NO DRIVE")
                .text format("%-24s", "NOT A SID808 FILE")
                .text format("%-24s", "FILE ENDED EARLY")
err_text_ofs    .byte 0, ERR_TEXT_LEN, 2 * ERR_TEXT_LEN ; per ERR_* - 1
        .enc "none"
