; pool.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The note pool (docs/design.md section 3): every pattern's event stream
; (events.asm has the format) in linked blocks of 32 bytes, 30 bytes of the
; stream and then the next block's address (low, high; $0000 = the last
; block). Free blocks are chained the same way from free_head. A pattern
; is written aside (wr_begin, wr_byte) and switched in by wr_publish with
; one write the player can't see half done; a replaced pattern's blocks go
; back to the free list (pool_free_chain).
;
; The pattern table, in the song data: each pattern's first block and its
; length in steps (0 = no pattern). Main loop only, all of it: the player
; only reads published patterns.

BLOCK_SIZE      = 32            ; a block, aligned to its size
BLOCK_DATA      = 30            ; stream bytes in a block; then the link (2 bytes)
.if TEST_EVENTS
POOL_BASE       = $7400         ; (its test streams make the program longer)
.elsif TEST_PLAY || TEST_LOG || TEST_KEYS || TEST_MIDI
POOL_BASE       = $6000         ; (test builds: the pool from the program's end, up to the
                                ; log at $7000: the test scenes need that room)
.else
POOL_BASE       = $6d00         ; the program's room to $6CFF (the user: the pool's first
                                ; 2 KB for stage E's code, 2026-11-23; 2 KB more for stage
                                ; F's, 2026-11-24; 1 KB for stage G's song position, the
                                ; same day; from $7400 to the program's end after the size
                                ; pass, 2026-11-25: "all I can get"; two pages for the time
                                ; display, 2026-11-26)
.endif
.if TEST_EVENTS || TEST_PLAY || TEST_LOG || TEST_KEYS || TEST_MIDI
POOL_START      = program_end > POOL_BASE ? (program_end + $ff) & $ff00 : POOL_BASE
                                ; (test builds: their scenes, feeds, scripts and test
                                ; code can make the program longer)
.else
POOL_START      = POOL_BASE
.endif
.if TEST_LOG
POOL_END        = LOG_START     ; the timing test logs above it
.elsif TEST_EVENTS
POOL_END        = $a000         ; the decoded events above it
.else
POOL_END        = $c000
.endif
POOL_BLOCKS     = (POOL_END - POOL_START) / BLOCK_SIZE  ; 680 in the real program
        .cerror POOL_START % $100 != 0 || POOL_END % $100 != 0, "the pool must be whole pages"

NUM_PATTERNS    = 128
PAT_FIRST_LO    = $c800         ; each pattern's first block, low bytes
PAT_FIRST_HI    = $c880         ;   high bytes (0 = no pattern)
PAT_STEPS       = $c900         ; each pattern's length in steps, 1..128 (0 = no pattern)
        .cerror PAT_STEPS + NUM_PATTERNS > $d000, "pattern table outside the song data"

        .section zp
free_head       .word ?         ; the first free block (high byte 0 = none)
free_count      .word ?         ; free blocks (the memory gauge)
wr_ptr          .word ?         ; where wr_byte writes next
wr_first        .word ?         ; the first block of the pattern being written
pool_next       .word ?         ; scratch: a block's link
        .send

; -----------------------------------------------------------------------------
; pool_init - every block free (chained in address order), every pattern
; empty.
; clobbers A, Y, ptr
; -----------------------------------------------------------------------------
pool_init_body .macro               ; (run at start and from the disk overlay: sid500.asm twice)
        lda #<POOL_START
        sta ptr
        sta free_head
        lda #>POOL_START
        sta ptr+1
        sta free_head+1
        ; each block's link is the next block, the last one's $0000
_block  clc
        lda ptr
        adc #BLOCK_SIZE
        sta pool_next
        lda ptr+1
        adc #0
        sta pool_next+1
        cmp #>POOL_END          ; (the pool ends on a page: low byte 0 there)
        bne +
        lda #0
        sta pool_next
        sta pool_next+1
+       jsr _link
        lda pool_next+1
        beq _patterns
        sta ptr+1
        lda pool_next
        sta ptr
        jmp _block

        ; the gauge, and no patterns
_patterns
        lda #<POOL_BLOCKS
        sta free_count
        lda #>POOL_BLOCKS
        sta free_count+1
        lda #0
        ldy #NUM_PATTERNS-1
-       sta PAT_FIRST_HI,y
        sta PAT_STEPS,y
        dey
        bpl -
        rts

; _link - the block at ptr links to pool_next
_link   ldy #BLOCK_DATA
        lda pool_next
        sta (ptr),y
        iny
        lda pool_next+1
        sta (ptr),y
        rts
        .endm
        #twice pool_init

; -----------------------------------------------------------------------------
; pool_alloc - take a block from the free list: its address in ptr, its
; link cleared (the last block of a chain). Carry set = none left (ptr
; unchanged).
; clobbers A, Y
; -----------------------------------------------------------------------------
pool_alloc
        lda free_head+1
        bne +
        sec                     ; the pool is full
        rts
+       sta ptr+1
        lda free_head
        sta ptr
        ; the free list starts at its link now
        ldy #BLOCK_DATA
        lda (ptr),y
        sta free_head
        iny
        lda (ptr),y
        sta free_head+1
        ; it is a chain's last block until it gets a successor
        lda #0
        sta (ptr),y
        dey
        sta (ptr),y
        ; the gauge
        lda free_count
        bne +
        dec free_count+1
+       dec free_count
        clc
        rts

; -----------------------------------------------------------------------------
; pool_free_chain - a chain of blocks (its first in ptr; high byte 0 = no
; chain) back to the free list: the chain's last block links to the old
; free list, which then starts at the chain's first.
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
pool_free_chain
        lda ptr+1
        beq _done
        lda ptr                 ; the chain's first: the free list's new start
        sta pool_next
        lda ptr+1
        sta pool_next+1
        ; walk to the last block, counting each one free
_walk   inc free_count
        bne +
        inc free_count+1
+       ldy #BLOCK_DATA+1
        lda (ptr),y
        beq _last
        tax
        dey
        lda (ptr),y
        sta ptr
        stx ptr+1
        jmp _walk
        ; the last block links to the old free list
_last   ldy #BLOCK_DATA
        lda free_head
        sta (ptr),y
        iny
        lda free_head+1
        sta (ptr),y
        lda pool_next
        sta free_head
        lda pool_next+1
        sta free_head+1
_done   rts

; -----------------------------------------------------------------------------
; wr_begin - start writing a pattern's stream aside, in a block of its own.
; Carry set = the pool is full (nothing taken).
; clobbers A, Y, ptr
; -----------------------------------------------------------------------------
wr_begin
        jsr pool_alloc
        bcs _done
        lda ptr
        sta wr_first
        sta wr_ptr
        lda ptr+1
        sta wr_first+1
        sta wr_ptr+1
_done   rts

; -----------------------------------------------------------------------------
; wr_byte - append byte A to the stream being written, taking a new block
; when this one's 30 bytes are used. Carry set = the pool is full (the
; byte is lost: the caller frees the chain, wr_abandon).
; preserves A; clobbers Y, ptr
; -----------------------------------------------------------------------------
wr_byte
        pha
        ; at the block's link: on to a new block, linked from this one
        lda wr_ptr
        and #BLOCK_SIZE-1
        cmp #BLOCK_DATA
        bne _store
        jsr pool_alloc
        bcs _full
        ldy #0                  ; the link (wr_ptr points at it)
        lda ptr
        sta (wr_ptr),y
        iny
        lda ptr+1
        sta (wr_ptr),y
        sta wr_ptr+1            ; then on to the new block
        lda ptr
        sta wr_ptr
        ; the byte, and on
_store  pla
        ldy #0
        sta (wr_ptr),y
        inc wr_ptr              ; (never past the block: the link comes first)
        clc
        rts
_full   pla
        rts

; -----------------------------------------------------------------------------
; wr_abandon - the stream being written back to the free list (a full
; pool, a cancelled recording).
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
wr_abandon
        lda wr_first
        sta ptr
        lda wr_first+1
        sta ptr+1
        jmp pool_free_chain

; -----------------------------------------------------------------------------
; wr_publish - the stream written becomes pattern X, A steps long: its
; first block and length switched in together, out of the player's way;
; the pattern's old blocks then go back to the free list. (So far only
; for a pattern no track is playing: the player's step must keep a playing
; pattern's old blocks until no track reads them.)
; clobbers A, X, Y, ptr, pool_next
; -----------------------------------------------------------------------------
wr_publish
        ; the old chain, to free after the switch
        ldy PAT_FIRST_LO,x
        sty ptr
        ldy PAT_FIRST_HI,x
        sty ptr+1
        ; the new one in, as one change
        php
        sei
        sta PAT_STEPS,x
        lda wr_first
        sta PAT_FIRST_LO,x
        lda wr_first+1
        sta PAT_FIRST_HI,x
        plp
        jmp pool_free_chain
