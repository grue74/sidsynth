; events.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Reading a pattern's event stream (docs/design.md section 3 has the
; format; tables.py's encode() writes it, tools/event_check.py checks this
; against it). Each event is its time, any prefixes (length, velocity),
; then the event: a note, a controller, pitch bend or a program change.
; The reader's state (where it is, the current velocity, length and
; controller) is in zero page: the player keeps one per track and swaps it
; in. Two readers, the same code (the reader segment): ev_* the player's
; (in the timer interrupt), ed_* the main loop's (live.asm: a live
; switch's new pattern found at its place), so neither disturbs the other.

; the time byte
TIME_LONG       = $f0           ; $F0-$FE: (byte - $F0) * 256 + the next byte
TIME_END        = $ff           ; the pattern's end
; prefixes and events (a note is $00-$7F)
EV_LEN_TABLE    = $80           ; $80-$8D: a length from len_table
EV_LEN_BYTE     = $8e           ; a length of 1-255 ticks in the next byte
EV_LEN_WORD     = $8f           ; a length in the next two bytes (low, high)
EV_VELOCITY     = $90           ; a velocity in the next byte
EV_CC           = $91           ; a controller: number, value
EV_CC_SAME      = $92           ; the current controller: value
EV_BEND         = $93           ; pitch bend: low 7 bits, high 7 bits
EV_PROGRAM      = $94           ; program change: the program
; what ev_read_event gives (ev_type)
TYPE_NOTE       = 0             ; ev_d1 = the note; ev_vel, ev_len
TYPE_CC         = 1             ; ev_d1 = the controller, ev_d2 = the value
TYPE_BEND       = 2             ; ev_d1 = low 7 bits, ev_d2 = high 7 bits
TYPE_PROGRAM    = 3             ; ev_d1 = the program
TYPE_BAD        = $ff           ; a byte no event starts with: the stream ends there
; a pattern's starting values
START_VELOCITY  = 100
START_LENGTH    = 12            ; a 16th
START_CC        = 1

; -----------------------------------------------------------------------------
; rd_get - (macro; \1 = the reader's prefix) \1_byte inline (ed_: called): the stream's
; next byte in A, the link followed out of line (\1_link). The flags are
; not A's. clobbers Y (and X when it follows a link)
; -----------------------------------------------------------------------------
rd_get  .macro
.if \1_left == ed_left
        jsr ed_byte             ; (the main loop's reader: a call, 11 bytes less a read;
.else                           ; the player's inline, for its interrupt's time)
        ldy #0
        lda (\1_ptr),y
        inc \1_ptr             ; (never past the block: the link comes first)
        dec \1_left
        bne +
        jsr \1_link
+
.endif
        .endm

; -----------------------------------------------------------------------------
; reader - (segment; \1 = its prefix, \2 = the section for its state but
; the pointer, which is in zero page) a reader: its state and its routines,
; \1_start, \1_read_time, \1_read_event (and \1_byte, \1_link,
; \1_point_end).
; -----------------------------------------------------------------------------
reader  .segment
        .section zp
\1_ptr         .word ?         ; the next byte of the stream
        .send
        .section \2            ; (the rest: zero page, or absolute)
\1_left       .byte ?         ; the stream's bytes left in this block
\1_vel         .byte ?         ; the current velocity, length, controller
\1_len         .word ?
\1_cc          .byte ?
\1_delta       .word ?         ; \1_read_time: the ticks since the previous event
\1_type        .byte ?         ; \1_read_event: TYPE_*
\1_d1          .byte ?         ;   and its data
\1_d2          .byte ?
        .send

; \1_start - the reader at pattern A's start (an empty pattern reads as
; ended), with the starting velocity, length and controller.
; clobbers A, X
\1_start
        tax
        lda PAT_FIRST_HI,x
        beq _empty
        sta \1_ptr+1
        lda PAT_FIRST_LO,x
        sta \1_ptr
        lda #BLOCK_DATA         ; (a pattern starts at a block's start)
        sta \1_left
        jmp +
_empty  jsr \1_point_end
+       lda #START_VELOCITY
        sta \1_vel
        lda #<START_LENGTH
        sta \1_len
        lda #>START_LENGTH
        sta \1_len+1
        lda #START_CC
        sta \1_cc
        rts

; \1_point_end - the reader at a stream that only ends (an empty or broken
; pattern: it reads as ended from then on, however far it is read)
\1_point_end
        lda #<end_stream
        sta \1_ptr
        lda #>end_stream
        sta \1_ptr+1
        lda #BLOCK_DATA
        sta \1_left
        rts

; \1_byte - the stream's next byte in A, on to the next block after the
; 30th byte of one (\1_left counts them down; a link of $0000 where a block
; should follow: a broken stream, which then reads as ended).
; The flags are not A's. clobbers Y (and X when it follows a link)
\1_byte
        ldy #0
        lda (\1_ptr),y
        inc \1_ptr             ; (never past the block: the link comes first)
        dec \1_left
        beq \1_link
        rts

; \1_link - the block's last byte read (A, kept): on to the next block
; through its link (a link of $0000: the stream reads as ended)
\1_link pha
        lda (\1_ptr),y         ; (Y = 0)
        tax
        iny
        lda (\1_ptr),y
        beq _broken
        sta \1_ptr+1
        stx \1_ptr
        lda #BLOCK_DATA
        sta \1_left
        pla
        rts
_broken jsr \1_point_end
        pla
        rts

; \1_read_time - the next event's time: \1_delta = the ticks since the
; previous one. Carry set = the pattern's end instead.
; clobbers A, X, Y
\1_read_time
        #rd_get \1
        cmp #TIME_END
        beq _end
        cmp #TIME_LONG
        bcs _long
        sta \1_delta           ; 0..$EF ticks
        lda #0
        sta \1_delta+1
        clc
        rts
_long   and #$0f                ; (byte - $F0) * 256 + the next byte
        sta \1_delta+1
        #rd_get \1
        sta \1_delta
        clc
        rts
_end    sec
        rts

; \1_read_event - the event after its time: the prefixes change the
; current length and velocity, then \1_type and \1_d1, \1_d2 say what it
; is (a note's velocity and length in \1_vel, \1_len).
; clobbers A, X, Y
\1_read_event
        #rd_get \1
        cmp #$80               ; (the flags aren't A's)
        bcc _note               ; $00-$7F: a note
        cmp #EV_LEN_BYTE
        bcc _len_table
        beq _len_byte
        cmp #EV_VELOCITY
        bcc _len_word
        beq _velocity
        jmp _other              ; (the rarer ones: out of branch reach)

_note   sta \1_d1
        lda #TYPE_NOTE
        sta \1_type
        rts

        ; prefixes, then on to the event
_len_table
        tax
        lda len_table-EV_LEN_TABLE,x
        sta \1_len
        lda #0
        sta \1_len+1
        jmp \1_read_event
_len_byte
        #rd_get \1
        sta \1_len
        lda #0
        sta \1_len+1
        jmp \1_read_event
_len_word
        #rd_get \1
        sta \1_len
        #rd_get \1
        sta \1_len+1
        jmp \1_read_event
_velocity
        #rd_get \1
        sta \1_vel
        jmp \1_read_event

        ; the other events
_other  cmp #EV_CC_SAME
        bcc _cc
        beq _cc_same
        cmp #EV_PROGRAM
        bcc _bend
        beq _program
        ; no event starts with this: the stream ends here
        jsr \1_point_end
        lda #TYPE_BAD
        sta \1_type
        rts
_cc     jsr \1_byte            ; a controller: its number becomes the current one
        sta \1_cc
_cc_same
        lda \1_cc
        sta \1_d1
        jsr \1_byte
        sta \1_d2
        lda #TYPE_CC
        sta \1_type
        rts
_bend   jsr \1_byte
        sta \1_d1
        jsr \1_byte
        sta \1_d2
        lda #TYPE_BEND
        sta \1_type
        rts
_program
        jsr \1_byte
        sta \1_d1
        lda #TYPE_PROGRAM
        sta \1_type
        rts
        .endsegment

        #reader ev, zp          ; the player's
        #reader ed, live_vars   ; the main loop's (live.asm; the zero page is full)


; the length prefixes' table, in ticks (48 a quarter): 64th, 32nd, 16th
; triplet, dotted 32nd, 16th, 8th triplet, dotted 16th, 8th, quarter
; triplet, dotted 8th, quarter, dotted quarter, half, whole (tables.py's
; LENGTHS)
len_table       .byte 3, 6, 8, 9, 12, 16, 18, 24, 32, 36, 48, 72, 96, 192
        .cerror * - len_table != EV_LEN_BYTE - EV_LEN_TABLE, "len_table: one length per prefix"
