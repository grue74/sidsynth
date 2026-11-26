; dumps.asm - part of SID808, included by sid808.asm (from SID101's)
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; SysEx dumps (core/sysex.asm, MIDI_SYSEX): the song file over MIDI, byte
; for byte as its disk file (src/disk.asm), so a PC keeps it as a .prg and
; can put it on a disk. One kind:
;   DUMP_SONG  the song file: load address, "sid808" and FILE_VERSION, the
;              64 patterns, the song block, tempo, swing, the mute bits,
;              the sound knobs
; A request (from a PC) or D on the grid sends it (always FILE_VERSION);
; with MIDI out on, a playing sequencer stops first (its notes would cut
; the dump). A dump that comes in silences the synth as it begins (the
; sequencer stops), is checked (header, and the length its version has:
; versions 1 and 2, from older disks, load too, as disk_load takes them)
; and then loads as from disk (song_loaded). The song row tells what
; happened.

DUMP_SONG       = 0             ; the kind (the messages' kind byte)

LOAD_ADDR_LEN   = 2             ; a file's load address, before its header
MAGIC_LEN       = FILE_HEADER_LEN - 1 ; "sid808", then the version byte
FILE_DATA       = LOAD_ADDR_LEN + FILE_HEADER_LEN ; where the data starts in a file
COMMON_LEN      = NUM_PATTERNS * PAT_BYTES + (SONG_END - song_pat) + 4
                                ; every version's data (the 4: tempo, swing, the mute bits)
KNOBS_V2_LEN    = KNOBS_V2_END - knob_level ; the knobs a version 2 file holds
KNOBS_V3_LEN    = KNOBS_END - knob_level    ; ... version 3 (+ Tone)
SONG_FILE_V1    = FILE_DATA + COMMON_LEN    ; a file's length by its version
SONG_FILE_V2    = SONG_FILE_V1 + KNOBS_V2_LEN
SONG_FILE_V3    = SONG_FILE_V1 + KNOBS_V3_LEN
        .cerror FILE_VERSION != 3, "dumps.asm: a new file version needs its length here"
        .cerror SONG_FILE_V3 >= SYSEX_MAX, "the song file is too long for SYSEX_MAX"

; the file as a region list (core/sysex.asm): what disk_save writes, in its
; order; tools/dump_check.py compares a dump with a saved file
song_regions
        #sysex_region song_load_address, LOAD_ADDR_LEN
        #sysex_region file_magic, FILE_HEADER_LEN
        #sysex_region PATTERN_RAM, PAT_BYTES, NUM_PATTERNS, 1
        #sysex_region song_pat, SONG_END - song_pat
        #sysex_region seq_bpm, 1
        #sysex_region seq_swing, 1
        #sysex_region mute, 2
song_knobs_v3                           ; (the sound knobs: version 3)
        #sysex_region knob_level, KNOBS_V3_LEN
        #sysex_regions_end
song_knobs_v2                           ; (version 2: all but Tone)
        #sysex_region knob_level, KNOBS_V2_LEN
        #sysex_regions_end

; what every version holds, after the header (a list of its own:
; sysex_unload writes until its list ends, and the knobs differ)
song_common_only
        #sysex_region PATTERN_RAM, PAT_BYTES, NUM_PATTERNS, 1
        #sysex_region song_pat, SONG_END - song_pat
        #sysex_region seq_bpm, 1
        #sysex_region seq_swing, 1
        #sysex_region mute, 2
        #sysex_regions_end

song_load_address .word PATTERN_RAM

.if TEST_DUMP_VERSION
; tests: a dump of another file version (sid808.asm TEST_DUMP_VERSION):
; the header says it, and it holds what that version holds (4: as 3)
test_dump_regions
        #sysex_region song_load_address, LOAD_ADDR_LEN
        #sysex_region file_magic, MAGIC_LEN
        #sysex_region test_dump_version, 1
        #sysex_region PATTERN_RAM, PAT_BYTES, NUM_PATTERNS, 1
        #sysex_region song_pat, SONG_END - song_pat
        #sysex_region seq_bpm, 1
        #sysex_region seq_swing, 1
        #sysex_region mute, 2
.if TEST_DUMP_VERSION == 2
        #sysex_region knob_level, KNOBS_V2_LEN
.elsif TEST_DUMP_VERSION >= 3
        #sysex_region knob_level, KNOBS_V3_LEN
.endif
        #sysex_regions_end
test_dump_version .byte TEST_DUMP_VERSION
.endif

; a file's length by its version (1..3), low and high bytes
file_len_lo     .byte <SONG_FILE_V1, <SONG_FILE_V2, <SONG_FILE_V3
file_len_hi     .byte >SONG_FILE_V1, >SONG_FILE_V2, >SONG_FILE_V3

; -----------------------------------------------------------------------------
; synth_sysex_request - core hook: a request for kind A (or D on the grid).
; Sends the song file unless a dump is still going out or the kind isn't
; ours.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_request
        cmp #DUMP_SONG
        bne _done               ; not a kind of ours
        jsr sysex_busy
        bne _done               ; one at a time
        lda seq_play            ; with MIDI out on, a playing sequencer stops first
        beq +
        lda params+P_MIDIOUT
        beq +
        jsr seq_toggle          ; (its notes off and stop go out before the dump)
+       lda #DUMP_SONG
.if TEST_DUMP_VERSION
        ldx #<test_dump_regions
        ldy #>test_dump_regions
.else
        ldx #<song_regions
        ldy #>song_regions
.endif
        jsr sysex_send
        ldx #MSG_SENDING
        jmp dump_message
_done   rts

; -----------------------------------------------------------------------------
; k_dump - (the grid's key table) D: the song as a SysEx dump, as a request
; would.
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
; synth_sysex_begin - core hook: a dump for SID808 begins (kind A). The
; sequencer stops and every sound ends now: the core skips the ticks while
; the data comes (~12 bytes a tick don't fit beside a busy tick).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_begin = dump_quiet

; -----------------------------------------------------------------------------
; synth_sysex_dump - core hook: a dump came in, kind A, carry clear = whole
; (sysex_len bytes at SYSEX_RAM), set = bad. A whole one with SID808's
; header, a version this program knows and that version's length loads, as
; from disk: the knobs an older version lacks get their defaults.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_sysex_dump
        bcs _bad
        cmp #DUMP_SONG
        beq _song
_bad    ldx #MSG_BAD
        jmp dump_message

        ; the header: the magic, then a version 1..FILE_VERSION
_song   ldx #MAGIC_LEN-1
-       lda SYSEX_RAM+LOAD_ADDR_LEN,x
        cmp file_magic,x
        bne _not_song
        dex
        bpl -
        ldx SYSEX_RAM+LOAD_ADDR_LEN+MAGIC_LEN
        dex                     ; (0..2: the tables' index)
        cpx #FILE_VERSION
        bcs _not_song           ; 0 (dex: $FF) or later than ours
        ; the length that version has
        lda sysex_len
        cmp file_len_lo,x
        bne _not_song
        lda sysex_len+1
        cmp file_len_hi,x
        bne _not_song
        txa                     ; (version - 1, on the stack: no RAM to spare)
        pha

        ; whole and ours: every version's part, then the knobs it has
        jsr dump_quiet          ; (again: a key may have started something)
        lda #<SYSEX_RAM + FILE_DATA
        sta sysex_src
        lda #>SYSEX_RAM + FILE_DATA
        sta sysex_src+1
        ldx #<song_common_only
        ldy #>song_common_only
        jsr sysex_unload
        pla                     ; (version - 1)
        beq _v1
        pha
        ldx #NUM_SOUNDS-1       ; versions 2, 3: Tone at its default (version 3
-       jsr tone_default        ; reads it over)
        dex
        bpl -
        lda #<SYSEX_RAM + FILE_DATA + COMMON_LEN
        sta sysex_src
        lda #>SYSEX_RAM + FILE_DATA + COMMON_LEN
        sta sysex_src+1
        ldx #<song_knobs_v3
        ldy #>song_knobs_v3
        pla                     ; (version - 1)
        cmp #3-1
        beq +
        ldx #<song_knobs_v2
        ldy #>song_knobs_v2
+       jsr sysex_unload
        jmp _loaded
_v1     ldx #NUM_SOUNDS-1       ; version 1: no knobs, all at their defaults
-       jsr knob_defaults
        dex
        bpl -
_loaded jsr song_loaded         ; made safe and used, as a disk load
        jsr dump_caught_up
        ldx #MSG_SONG
        jmp dump_message
_not_song
        ldx #MSG_NOT_SONG
        jmp dump_message

; -----------------------------------------------------------------------------
; dump_quiet - before a dump loads: the sequencer stopped, every sound off.
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
; dump_message - message X (MSG_*) into disk_msg, shown on the song row
; until a key.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
dump_message
        ldy #0
-       lda dump_texts,x
        sta disk_msg,y
        inx
        iny
        cpy #DUMP_TEXT_LEN
        bne -
        lda #CHAR_SPACE         ; the rest blank
-       sta disk_msg,y
        iny
        cpy #40
        bne -
        lda #1
        sta msg_on
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
MSG_BAD         = * - dump_texts
                .text format("%-24s", "SYSEX: BAD DATA")
MSG_NOT_SONG    = * - dump_texts
                .text format("%-24s", "SYSEX: NOT A SID808 FILE")
        .cerror * - dump_texts > 256, "dump_texts: more than 256 bytes"
        .enc "none"
