; test_events.asm - part of SID500 (TEST_EVENTS builds), included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The pool and the event reader against tables.py's model
; (tools/event_check.py reads the results):
;   1. tables.py's test patterns written into the pool with wr_begin,
;      wr_byte, wr_publish (one pattern twice: its first blocks freed);
;   2. the pool filled to the last byte with one more stream, which is
;      then abandoned (all its blocks free again);
;   3. every pattern read back with ev_read_time / ev_read_event, each
;      event written to EVENTS_OUT as a record of 8 bytes;
;   4. each pattern encoded again from those records (edit.asm, the step
;      grid's encoder: the records are the edit table's) into a new chain
;      and published, its old chain freed: the pool then holds what
;      encode() writes, the free blocks as before.

EVENTS_OUT      = $a000         ; the records: tick (2), type, d1, d2, velocity, length (2);
                                ; a pattern's end: tick (2), REC_END, the pattern
EVENTS_OUT_END  = $bf00
REC_END         = $fe
RESULTS         = $bf00         ; free blocks at start (2), after the patterns (2), the
                                ; bytes the fill wrote (2), free blocks after it (2),
                                ; then RESULTS_DONE, the patterns encoded again (1)
RESULTS_DONE    = $a5           ; (RESULTS+8: everything ran)
        .cerror POOL_END > EVENTS_OUT, "the pool runs into the test results"

        .section zp
te_src          .word ?         ; the next byte of test_streams
te_left         .word ?         ; the stream's bytes still to write
te_out          .word ?         ; the next record
te_tick         .word ?         ; the event's tick from the pattern's start
te_pattern      .byte ?
te_steps        .byte ?
te_end          .word ?         ; test 4: where test 3's records end
        .send

; -----------------------------------------------------------------------------
; test_events - the three tests, from synth_init (interrupts off).
; -----------------------------------------------------------------------------
test_events
        lda free_count
        sta RESULTS
        lda free_count+1
        sta RESULTS+1
        jsr te_write_patterns
        lda free_count
        sta RESULTS+2
        lda free_count+1
        sta RESULTS+3
        jsr te_fill
        lda free_count
        sta RESULTS+6
        lda free_count+1
        sta RESULTS+7
        jsr te_read_patterns
        jsr te_encode_patterns
        lda #RESULTS_DONE
        sta RESULTS+8
        rts

; te_next - test_streams' next byte in A
te_next
        ldy #0
        lda (te_src),y
        inc te_src
        bne +
        inc te_src+1
+       rts

; -----------------------------------------------------------------------------
; te_write_patterns - test 1: each stream of test_streams written aside and
; published as its pattern.
; -----------------------------------------------------------------------------
te_write_patterns
        lda #<test_streams
        sta te_src
        lda #>test_streams
        sta te_src+1
_pattern
        jsr te_next
        cmp #$ff
        beq _done
        sta te_pattern
        jsr te_next
        sta te_steps
        jsr te_next
        sta te_left
        jsr te_next
        sta te_left+1
        jsr wr_begin
        ; the stream's bytes
_byte   jsr te_next
        jsr wr_byte
        lda te_left
        bne +
        dec te_left+1
+       dec te_left
        lda te_left
        ora te_left+1
        bne _byte
        ldx te_pattern
        lda te_steps
        jsr wr_publish
        jmp _pattern
_done   rts

; -----------------------------------------------------------------------------
; te_fill - test 2: one more stream until the pool is full (counting the
; bytes written), then abandoned.
; -----------------------------------------------------------------------------
te_fill
        lda #0
        sta RESULTS+4
        sta RESULTS+5
        jsr wr_begin
        bcs _done
-       lda #$55
        jsr wr_byte
        bcs _full
        inc RESULTS+4
        bne -
        inc RESULTS+5
        jmp -
_full   jsr wr_abandon
_done   rts

; -----------------------------------------------------------------------------
; te_read_patterns - test 3: every pattern (with steps) read back, its
; events as records at EVENTS_OUT, a record of REC_END after each.
; -----------------------------------------------------------------------------
te_read_patterns
        lda #<EVENTS_OUT
        sta te_out
        lda #>EVENTS_OUT
        sta te_out+1
        lda #0
        sta te_pattern
_pattern
        ldx te_pattern
        lda PAT_STEPS,x
        beq _next
        txa
        jsr ev_start
        lda #0
        sta te_tick
        sta te_tick+1
        ; each event: its time, then the event
_event  jsr ev_read_time
        bcs _end
        clc
        lda te_tick
        adc ev_delta
        sta te_tick
        lda te_tick+1
        adc ev_delta+1
        sta te_tick+1
        jsr ev_read_event
        ldy #2
        lda ev_type
        sta (te_out),y
        iny
        lda ev_d1
        sta (te_out),y
        iny
        lda ev_d2
        sta (te_out),y
        iny
        lda ev_vel
        sta (te_out),y
        iny
        lda ev_len
        sta (te_out),y
        iny
        lda ev_len+1
        sta (te_out),y
        jsr te_record
        lda ev_type
        cmp #TYPE_BAD
        bne _event
        ; the pattern's end
_end    ldy #2
        lda #REC_END
        sta (te_out),y
        iny
        lda te_pattern
        sta (te_out),y
        jsr te_record
_next   inc te_pattern
        lda te_pattern
        cmp #NUM_PATTERNS
        bne _pattern
        rts

; te_record - the record's tick, and on to the next record (it stops at
; EVENTS_OUT_END: the check sees the records missing)
te_record
        ldy #0
        lda te_tick
        sta (te_out),y
        iny
        lda te_tick+1
        sta (te_out),y
        lda te_out+1
        cmp #>EVENTS_OUT_END
        beq +
        clc
        lda te_out
        adc #8
        sta te_out
        bcc +
        inc te_out+1
+       rts

; -----------------------------------------------------------------------------
; te_encode_patterns - test 4: each pattern's records (test 3's, up to its
; REC_END record, which names the pattern) encoded into a new chain and
; published with the pattern's steps (RESULTS+9: how many).
; -----------------------------------------------------------------------------
te_encode_patterns
        lda te_out
        sta te_end
        lda te_out+1
        sta te_end+1
        lda #<EVENTS_OUT
        sta te_out
        lda #>EVENTS_OUT
        sta te_out+1
        lda #0
        sta RESULTS+9
_pattern
        lda te_out              ; all done?
        cmp te_end
        lda te_out+1
        sbc te_end+1
        bcs _done
        ; its records: counted up to its REC_END
        lda te_out
        sta en_rec
        lda te_out+1
        sta en_rec+1
        lda #0
        sta en_left
        sta en_left+1
_count  ldy #2
        lda (te_out),y
        cmp #REC_END
        beq _named
        inc en_left
        bne +
        inc en_left+1
+       jsr te_next_record
        jmp _count
_named  iny
        lda (te_out),y
        sta te_pattern
        jsr te_next_record
        ; encoded and published
_encode jsr en_begin
        bcs _done
-       lda en_left
        ora en_left+1
        beq +
        jsr en_record
        bcs _done
        jmp -
+       jsr en_finish
        bcs _done
        ldx te_pattern
        lda PAT_STEPS,x
        jsr wr_publish
        inc RESULTS+9
        jmp _pattern
_done   rts

; te_next_record - te_out on to the next record
te_next_record
        clc
        lda te_out
        adc #8
        sta te_out
        bcc +
        inc te_out+1
+       rts
