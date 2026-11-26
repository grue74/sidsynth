; dumps.asm - part of SID303, included by sid303.asm (from SID101's)
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; SysEx dumps (core/sysex.asm, MIDI_SYSEX): the song file and the preset
; bank over MIDI, each byte for byte as its disk file (src/disk.asm), so a
; PC keeps them as .prg files and can put them on a disk. Two kinds:
;   DUMP_SONG  the song file: load address, "sid303" and FILE_VERSION, the
;              64 patterns, the song block, tempo, swing, the sound
;   DUMP_BANK  the preset bank: load address, "s303bank" and BANK_VERSION,
;              PRESET_RAM..PRESET_END
; A request (from a PC) or C= + M (the step screen: the song; the
; parameter screen: the bank) sends one; with MIDI out on, a playing
; sequencer stops first (its notes would cut the dump). A dump that comes
; in silences the synth as it begins (the sequencer stops), is checked
; (length, header) and then loads as from disk (song_loaded; bank_check).
; The song row and the parameter screen's status row tell what happened.

DUMP_SONG       = 0             ; the kinds (the messages' kind byte)
DUMP_BANK       = 1

LOAD_ADDR_LEN   = 2             ; a file's load address, before its header
SONG_FILE_LEN   = LOAD_ADDR_LEN + FILE_HEADER_LEN + NUM_PATTERNS * PAT_BYTES + (SONG_END - song_pat) + 2 + SOUND_PARAMS
                                ; (the 2: tempo and swing)
BANK_FILE_LEN   = LOAD_ADDR_LEN + BANK_HEADER_LEN + PRESET_END - PRESET_RAM
        .cerror SONG_FILE_LEN >= SYSEX_MAX || BANK_FILE_LEN >= SYSEX_MAX, "a file is too long for SYSEX_MAX"

; the file as a region list (core/sysex.asm): what disk_save writes, in its
; order; tools/dump_check.py compares a dump with a saved file
song_regions
        #sysex_region song_load_address, LOAD_ADDR_LEN
        #sysex_region file_magic, FILE_HEADER_LEN
song_data                               ; (after the header: what a dump loads)
        #sysex_region PATTERN_RAM, PAT_BYTES, NUM_PATTERNS, 1
        #sysex_region song_pat, SONG_END - song_pat
        #sysex_region seq_bpm, 1
        #sysex_region seq_swing, 1
        #sysex_region params, SOUND_PARAMS
        #sysex_regions_end

PRESET_BYTES_ALL = PRESET_END - PRESET_RAM
bank_regions
        #sysex_region bank_load_address, LOAD_ADDR_LEN
        #sysex_region bank_magic, BANK_HEADER_LEN
bank_data
        #sysex_region PRESET_RAM, 256, PRESET_BYTES_ALL / 256, 1
.if PRESET_BYTES_ALL % 256
        #sysex_region PRESET_RAM + PRESET_BYTES_ALL - PRESET_BYTES_ALL % 256, PRESET_BYTES_ALL % 256
.endif
        #sysex_regions_end

song_load_address .word PATTERN_RAM
bank_load_address .word PRESET_RAM

; -----------------------------------------------------------------------------
; synth_sysex_request - core hook: a request for kind A (or C= + M). Sends
; the file unless a dump is still going out or the kind isn't ours.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_request
        cmp #DUMP_BANK+1
        bcs _done               ; not a kind of ours
        tax
        jsr sysex_busy
        bne _done               ; one at a time
        txa
        pha                     ; (the kind)
        lda seq_play            ; with MIDI out on, a playing sequencer stops first
        beq +
        lda params+P_MIDIOUT
        beq +
        jsr seq_toggle          ; (its note off and stop go out before the dump)
+       pla
        ldx #<song_regions
        ldy #>song_regions
        cmp #DUMP_SONG
        beq +
        ldx #<bank_regions
        ldy #>bank_regions
+       jsr sysex_send
        ldx #MSG_SENDING
        jmp dump_message
_done   rts

; -----------------------------------------------------------------------------
; k_dump - (the step screen's C= key table) C= + M: the song as a SysEx
; dump, as a request would.
; -----------------------------------------------------------------------------
k_dump  lda #DUMP_SONG
        jsr synth_sysex_request
        jmp key_done

; -----------------------------------------------------------------------------
; synth_sysex_sent - core hook: the dump's last byte is queued.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_sent
        ldx #MSG_SENT
        jmp dump_message

; -----------------------------------------------------------------------------
; synth_sysex_begin - core hook: a dump for SID303 begins (kind A). The
; sequencer stops and every note ends now: the core skips the ticks while
; the data comes (~12 bytes a tick don't fit beside a busy tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_begin = dump_quiet

; -----------------------------------------------------------------------------
; synth_sysex_dump - core hook: a dump came in, kind A, carry clear = whole
; (sysex_len bytes at SYSEX_RAM), set = bad. A whole one of the right
; length and header loads, as from disk.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_dump
        bcs _bad
        cmp #DUMP_SONG
        beq _song
        cmp #DUMP_BANK
        beq _bank
_bad    ldx #MSG_BAD
        jmp dump_message

        ; the song file: its length and header (the version: only 1 yet)
_song   lda sysex_len
        cmp #<SONG_FILE_LEN
        bne _not_song
        lda sysex_len+1
        cmp #>SONG_FILE_LEN
        bne _not_song
        ldx #FILE_HEADER_LEN-1
-       lda SYSEX_RAM+LOAD_ADDR_LEN,x
        cmp file_magic,x
        bne _not_song
        dex
        bpl -

        ; whole and ours: in through the region list, then used as a load
        jsr dump_quiet          ; (again: a key may have started something)
        lda #<SYSEX_RAM + LOAD_ADDR_LEN + FILE_HEADER_LEN
        sta sysex_src
        lda #>SYSEX_RAM + LOAD_ADDR_LEN + FILE_HEADER_LEN
        sta sysex_src+1
        ldx #<song_data
        ldy #>song_data
        jsr sysex_unload
        jsr song_loaded         ; made safe and used, as a disk load
        jsr dump_caught_up
        ldx #MSG_SONG
        jmp dump_message
_not_song
        ldx #MSG_NOT_SONG
        jmp dump_message

        ; the preset bank: its length and header
_bank   lda sysex_len
        cmp #<BANK_FILE_LEN
        bne _not_bank
        lda sysex_len+1
        cmp #>BANK_FILE_LEN
        bne _not_bank
        ldx #BANK_HEADER_LEN-1
-       lda SYSEX_RAM+LOAD_ADDR_LEN,x
        cmp bank_magic,x
        bne _not_bank
        dex
        bpl -

        ; whole and ours: into PRESET_RAM, then as a bank load from disk
        jsr dump_quiet          ; (again: a key may have started something)
        lda #<SYSEX_RAM + LOAD_ADDR_LEN + BANK_HEADER_LEN
        sta sysex_src
        lda #>SYSEX_RAM + LOAD_ADDR_LEN + BANK_HEADER_LEN
        sta sysex_src+1
        ldx #<bank_data
        ldy #>bank_data
        jsr sysex_unload
        lda #1                  ; the sound is no slot's any more
        sta preset_edited
        jsr bank_check
        jsr dump_caught_up
        ldx #MSG_BANK
        jmp dump_message
_not_bank
        ldx #MSG_NOT_BANK
        jmp dump_message

; -----------------------------------------------------------------------------
; dump_quiet - before a dump loads: the sequencer stopped, every note off.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dump_quiet
        lda seq_play
        beq +
        jsr seq_toggle
+       jmp all_notes_off

; -----------------------------------------------------------------------------
; dump_caught_up - after a dump has loaded (it took tens of ticks, in
; silence): the ticks missed meanwhile are skipped, not caught up.
; clobbers A
; -----------------------------------------------------------------------------
dump_caught_up
        lda tick_count
        sta tick_done
        rts

; -----------------------------------------------------------------------------
; dump_message - message X (MSG_*) into steps_msg, shown on the song row
; and on the parameter screen's status row until a key.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dump_message
        ldy #0
-       lda dump_texts,x
        sta steps_msg,y
        inx
        iny
        cpy #DUMP_TEXT_LEN
        bne -
        lda #CHAR_SPACE         ; the rest blank
-       sta steps_msg,y
        iny
        cpy #40
        bne -
        lda #1
        sta msg_on
        sta preset_msg_on
        rts

        .enc "screen"
DUMP_TEXT_LEN   = 24
dump_texts
MSG_SENDING     = * - dump_texts
                .text format("%-24s", "SENDING SYSEX...")
MSG_SENT        = * - dump_texts
                .text format("%-24s", "SYSEX SENT")
MSG_SONG        = * - dump_texts
                .text format("%-24s", "SYSEX: SONG LOADED")
MSG_BANK        = * - dump_texts
                .text format("%-24s", "SYSEX: BANK LOADED")
MSG_BAD         = * - dump_texts
                .text format("%-24s", "SYSEX: BAD DATA")
MSG_NOT_SONG    = * - dump_texts
                .text format("%-24s", "SYSEX: NOT A SID303 FILE")
MSG_NOT_BANK    = * - dump_texts
                .text format("%-24s", "SYSEX: NOT A SID303 BANK")
        .cerror * - dump_texts > 256, "dump_texts: more than 256 bytes"
        .enc "none"
