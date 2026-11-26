; dumps.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; SysEx dumps (core/sysex.asm, MIDI_SYSEX): the song file and the preset
; bank over MIDI, each byte for byte as its disk file (src/disk.asm), so a
; PC keeps them as .prg files and can put them on a disk. Two kinds:
;   DUMP_SONG  the song file: load address, "sid101" and FILE_VERSION, the
;              64 patterns, the song block, tempo, swing, the sound
;   DUMP_BANK  the preset bank: load address, "s101bank" and BANK_VERSION,
;              PRESET_RAM..PRESET_END
; A request (from a PC) or C= + M (the step screen: the song; the
; parameter screen: the bank) sends one; with MIDI out on, a playing
; sequencer stops first (its notes would cut the dump). A dump that comes
; in is checked (length, header) and then loads as from disk: the sequencer
; stops, the song is made safe (load_check), the bank too (bank_check).
; The song row and the parameter screen's status row tell what happened.

DUMP_SONG       = 0             ; the kinds (the messages' kind byte)
DUMP_BANK       = 1

LOAD_ADDR_LEN   = 2             ; a file's load address, before its header
SONG_FILE_LEN   = LOAD_ADDR_LEN + FILE_HEADER_LEN + NUM_PATTERNS * PAT_BYTES + (SONG_END - song_pat) + 2 + SOUND_PARAMS
                                ; (the 2: tempo and swing)
BANK_FILE_LEN   = LOAD_ADDR_LEN + BANK_HEADER_LEN + PRESET_END - PRESET_RAM
SONG_FILE_LEN_V1 = SONG_FILE_LEN - V2_PARAMS ; version 1 files (disk.asm): they still load
BANK_FILE_LEN_V1 = LOAD_ADDR_LEN + BANK_HEADER_LEN + BANK_V1_END - PRESET_RAM
        .cerror SONG_FILE_LEN >= SYSEX_MAX || BANK_FILE_LEN >= SYSEX_MAX, "a file is too long for SYSEX_MAX"

; the files as region lists (core/sysex.asm): what disk_save writes, in
; its order; tools/dump_check.py compares a dump with a saved file
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
song_data_v1                            ; a version 1 file's: no P_V2_FIRST..P_V2_LAST
        #sysex_region PATTERN_RAM, PAT_BYTES, NUM_PATTERNS, 1
        #sysex_region song_pat, SONG_END - song_pat
        #sysex_region seq_bpm, 1
        #sysex_region seq_swing, 1
        #sysex_region params, P_V2_FIRST
        #sysex_region params + P_V2_LAST + 1, SOUND_PARAMS - P_V2_LAST - 1
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
PRESET_BYTES_V1 = BANK_V1_END - PRESET_RAM
bank_data_v1                            ; a version 1 bank, made version 2 after (bank_loaded)
        #sysex_region PRESET_RAM, 256, PRESET_BYTES_V1 / 256, 1
.if PRESET_BYTES_V1 % 256
        #sysex_region PRESET_RAM + PRESET_BYTES_V1 - PRESET_BYTES_V1 % 256, PRESET_BYTES_V1 % 256
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
; dump, as a request would (the parameter screen's C= + M, the bank, is in
; presets.asm synth_param_key).
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
; synth_sysex_begin - core hook: a dump for SID101 begins (kind A). The
; sequencer stops and every note ends now: parsing ~12 bytes a tick doesn't
; fit beside the heaviest sound playing (the ring would overflow).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_begin = dump_quiet

; -----------------------------------------------------------------------------
; synth_sysex_dump - core hook: a dump came in, kind A, carry clear = whole
; (sysex_len bytes at SYSEX_RAM), set = bad. A whole one of the right
; length and header loads, as from disk (version 1 files too).
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

        ; the song file: its header, and the length its version has
        ; (version 1: Chord, Chord speed, Click left out: their defaults)
_song   ldx #FILE_HEADER_LEN-2  ; the magic
-       lda SYSEX_RAM+LOAD_ADDR_LEN,x
        cmp file_magic,x
        bne _not_song
        dex
        bpl -
        ldx #<song_data
        ldy #>song_data
        lda SYSEX_RAM+LOAD_ADDR_LEN+FILE_HEADER_LEN-1 ; the version
        cmp #FILE_VERSION
        bne _song_v1
        lda #<SONG_FILE_LEN
        cmp sysex_len
        bne _not_song
        lda #>SONG_FILE_LEN
        cmp sysex_len+1
        bne _not_song
        beq _song_in            ; always
_song_v1
        cmp #1
        bne _not_song
        lda #<SONG_FILE_LEN_V1
        cmp sysex_len
        bne _not_song
        lda #>SONG_FILE_LEN_V1
        cmp sysex_len+1
        bne _not_song
        ldx #V2_PARAMS-1        ; the new ones: their defaults
-       lda param_default+P_V2_FIRST,x
        sta params+P_V2_FIRST,x
        dex
        bpl -
        ldx #<song_data_v1
        ldy #>song_data_v1
_song_in
        txa                     ; (the region list, kept over dump_quiet)
        pha
        tya
        pha
        jsr dump_quiet          ; (again: a key may have started something)
        lda #<SYSEX_RAM + LOAD_ADDR_LEN + FILE_HEADER_LEN
        sta sysex_src
        lda #>SYSEX_RAM + LOAD_ADDR_LEN + FILE_HEADER_LEN
        sta sysex_src+1
        pla
        tay
        pla
        tax
        jsr sysex_unload
        jsr song_loaded         ; made safe and used, as a disk load
        jsr dump_caught_up
        ldx #MSG_SONG
        jmp dump_message
_not_song
        ldx #MSG_NOT_SONG
        jmp dump_message

        ; the preset bank: its header, the length its version has
_bank   ldx #BANK_HEADER_LEN-2  ; the magic
-       lda SYSEX_RAM+LOAD_ADDR_LEN,x
        cmp bank_magic,x
        bne _not_bank
        dex
        bpl -
        ldx #<bank_data
        ldy #>bank_data
        lda SYSEX_RAM+LOAD_ADDR_LEN+BANK_HEADER_LEN-1 ; the version
        sta disk_version        ; (bank_loaded reads it)
        cmp #BANK_VERSION
        bne _bank_v1
        lda #<BANK_FILE_LEN
        cmp sysex_len
        bne _not_bank
        lda #>BANK_FILE_LEN
        cmp sysex_len+1
        bne _not_bank
        beq _bank_in            ; always
_bank_v1
        cmp #1
        bne _not_bank
        lda #<BANK_FILE_LEN_V1
        cmp sysex_len
        bne _not_bank
        lda #>BANK_FILE_LEN_V1
        cmp sysex_len+1
        bne _not_bank
        ldx #<bank_data_v1
        ldy #>bank_data_v1
_bank_in
        txa                     ; (the region list, kept over dump_quiet)
        pha
        tya
        pha
        jsr dump_quiet          ; (again: a key may have started something)
        lda #<SYSEX_RAM + LOAD_ADDR_LEN + BANK_HEADER_LEN
        sta sysex_src
        lda #>SYSEX_RAM + LOAD_ADDR_LEN + BANK_HEADER_LEN
        sta sysex_src+1
        pla
        tay
        pla
        tax
        jsr sysex_unload
        lda #1                  ; as a bank load from disk: the sound is no slot's
        sta preset_edited
        jsr bank_loaded         ; (version 1: made version 2), made safe
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
                .text format("%-24s", "SYSEX: NOT A SID101 FILE")
MSG_NOT_BANK    = * - dump_texts
                .text format("%-24s", "SYSEX: NOT A SID101 BANK")
        .cerror * - dump_texts > 256, "dump_texts: more than 256 bytes"
        .enc "none"
