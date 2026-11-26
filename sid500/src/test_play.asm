; test_play.asm - part of SID500 (TEST_PLAY builds), included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A test scene from tables.py (play_streams, play_tracks, play_order) into
; the pool and the track settings at start, for the player to play from
; the start (tools/play_check.py).

        .section zp
tp_src          .word ?         ; the next byte of play_streams
tp_left         .word ?         ; the stream's bytes still to write
tp_pattern      .byte ?
tp_steps        .byte ?
        .send

; -----------------------------------------------------------------------------
; test_play_load - from synth_init (interrupts off, after tracks_init):
; each pattern written and published, then the tracks' patterns, channels,
; mutes and order.
; -----------------------------------------------------------------------------
        .section play_data      ; (with the scene: run once at start, before the log
                                ; is cleared; out of the program's room, which the
                                ; heavy scene's pool needs)
        .cerror PLAY_BLOCKS > POOL_BLOCKS, "the test scene's patterns don't fit in the pool (wr_byte would fail unseen): ", PLAY_BLOCKS, " blocks, the pool ", POOL_BLOCKS
test_play_load
        lda #<play_streams
        sta tp_src
        lda #>play_streams
        sta tp_src+1
        ; the patterns
_pattern
        jsr tp_next
        cmp #$ff
        beq _tracks
        sta tp_pattern
        jsr tp_next
        sta tp_steps
        jsr tp_next
        sta tp_left
        jsr tp_next
        sta tp_left+1
        jsr wr_begin
_byte   jsr tp_next
        jsr wr_byte
        lda tp_left
        bne +
        dec tp_left+1
+       dec tp_left
        lda tp_left
        ora tp_left+1
        bne _byte
        ldx tp_pattern
        lda tp_steps
        jsr wr_publish
        jmp _pattern
        ; the tracks
_tracks ldx #NUM_TRACKS-1
-       lda play_tracks,x
        sta SCENE_PATTERN,x
        lda play_tracks+NUM_TRACKS,x
        sta TRACK_CHANNEL,x
        lda play_tracks+2*NUM_TRACKS,x
        sta TRACK_MUTE,x
        lda play_order,x
        sta TRACK_ORDER,x
        dex
        bpl -
        jmp tracks_quiet        ; (what the player reads: the mutes)

        .send

; tp_next - play_streams' next byte in A (TEST_LIVE: live.asm reads the
; streams while playing, after the log's RAM is cleared: in the program;
; else with the loader)
tp_next_code .macro
        ldy #0
        lda (tp_src),y
        inc tp_src
        bne +
        inc tp_src+1
+       rts
        .endm
.if TEST_LIVE
tp_next #tp_next_code
.else
        .section play_data
tp_next #tp_next_code
        .send
.endif
