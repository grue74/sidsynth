; core/sysex.asm - (MIDI_SYSEX) SysEx dumps: a synth's files over MIDI
; Part of the SID synth core shared by SID303, SID808 and SID101.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Included by core/midi.asm when MIDI_SYSEX is on. A dump carries one of
; the synth's files (its kind: the song file, SID101's preset bank) byte for
; byte as on disk, load address and header included, so a PC can keep it
; as a .prg and the synth can check it as its disk load does.
;
; The messages (manufacturer ID $7D, for non-commercial use):
;   request  F0 7D <synth> <device> 01 <kind> F7
;   dump     F0 7D <synth> <device> 02 <kind> <len lo> <len hi> <data> <sum> F7
; synth: SYSEX_SYNTH (SidSynth: 1 SID303, 2 SID808, 3 SID101). device: the
; synth's MIDI channel - 1, or $7F (any synth of the kind; a synth in omni
; sends $7F). len: the file's length in bytes, 7 bits in each. data: the
; file in groups of up to 7 bytes, each group a byte of their top bits
; (bit 0 = the group's first byte's) and then the bytes' low 7 bits. sum:
; makes the sum of every byte from kind to sum a multiple of 128.
;
; Receiving: midi_system and midi_sysdata (midi.asm) hand the bytes over.
; A dump is unpacked into SYSEX_RAM as it comes; nothing else changes until
; F7, when the synth's synth_sysex_dump gets it (carry clear) or hears that
; a dump meant for it was bad (carry set: a byte lost, too long, ...). Any
; status byte but realtime ends a message unfinished. synth_sysex_begin
; hears when a dump for the synth begins (A = its kind): ~12 bytes come
; every tick, more than a busy tick leaves time for, so the synth goes
; quiet then (no note may be left sounding), and while the data comes in
; the main loop skips its ticks (synth_tick isn't called; the test feeds
; still run).
;
; Sending: sysex_send starts a dump of a region list (below); the main
; loop's sysex_pump queues it for MIDI out a few bytes a pass, only when no
; tick is due and while the transmit ring has room (midi_send would drop
; bytes), so the synth's ticks keep their time: a quiet synth sends at the
; wire's speed, a busy one slower (with the time its ticks leave). synth_sysex_sent hears when the last byte is queued.
;
; A region list says where a file's bytes are: entries of 5 bytes, from
; the sysex_region macro: the address, the bytes (1..256: 0 = 256), how
; many times (1..255), and the pages to step on between times; a count of 0
; ends the list (sysex_regions_end). sysex_unload writes received bytes
; through the same kind of list.

SYSEX_ID        = $7d           ; manufacturer ID: non-commercial
SX_REQUEST      = $01           ; commands
SX_DUMP         = $02
SX_DEVICE_ALL   = $7f           ; device: any
SX_HEADER_LEN   = 8             ; F0 7D synth device 02 kind len-lo len-hi
SX_BURST        = 8             ; bytes queued per main-loop pass at most
SX_LEN_MAX      = $3fff         ; 14 bits of length
SX_TIMEOUT      = 250           ; ticks (1 s) without a data byte: the dump has stopped
                                ; coming (USB MIDI may send in bursts: the synth is quiet anyway)
MIDI_SYSEX_START = $f0          ; status bytes: SysEx start and end
MIDI_SYSEX_END  = $f7
SX_REALTIME     = $f8           ; realtime bytes from here: allowed inside a message
SX_GROUP        = 7             ; data bytes per group (after its top-bits byte)
SX_GROUP_DUE    = 2             ; sx_rx_msb below this: the marker alone, a group's top bits next
SX_TOP_MARKER   = $80           ; the marker above a group's 7 top bits
SXH_DEVICE      = 3             ; offsets in sx_hdr (F0 7D synth device 02 kind len-lo len-hi)
SXH_COMMAND     = 4
SXH_KIND        = 5
SXH_LEN_LO      = 6
SXH_LEN_HI      = 7
RG_ENTRY_LEN    = 5             ; a region list entry: address (word), bytes, times, step
OP_BIT          = $2c           ; opcodes the main loop's sx_pump_op and sx_tick_op switch
OP_JSR          = $20           ;   between (BIT abs: does nothing, in 4 cycles)
OP_JMP          = $4c

        .cerror !MIDI_SYSTEM, "MIDI_SYSEX needs MIDI_SYSTEM (midi_system hands the bytes over)"
        .cerror !MIDI_OUT, "MIDI_SYSEX needs MIDI_OUT"
        .cerror SYSEX_SYNTH < 1 || SYSEX_SYNTH > $7f, "MIDI_SYSEX: set SYSEX_SYNTH, 1..127"
        .cerror SYSEX_MAX > SX_LEN_MAX, "SYSEX_MAX: at most 14 bits"
        .cerror SYSEX_RAM + SYSEX_MAX > $fffa, "SYSEX_RAM: the area runs into the vectors at $FFFA"
        .cerror !SYSEX_UNDER_IO && SYSEX_RAM < $e000 && SYSEX_RAM + SYSEX_MAX > $d000, "SYSEX_RAM: under the I/O chips only with SYSEX_UNDER_IO"
SX_RAM_ONLY     = $34           ; $01 value: RAM everywhere, no I/O (SYSEX_UNDER_IO's stores)

; receive states (sx_rx_state); 0 = no message of ours
SXR_ID          = 1             ; after F0: the manufacturer ID next
SXR_SYNTH       = 2
SXR_DEVICE      = 3
SXR_COMMAND     = 4
SXR_REQ_KIND    = 5             ; a request: its kind next
SXR_REQ_END     = 6             ; ... complete: F7 next
SXR_KIND        = 7             ; a dump: its kind next
SXR_LEN_LO      = 8
SXR_LEN_HI      = 9
SXR_DATA        = 10            ; the packed data
SXR_SUM         = 11            ; the data all in: the sum (and nothing more)
SXR_BAD         = 12            ; a dump for us that can't be used: wait for F7
SXR_STATES      = 13

; send states (sx_tx_state); 0 = nothing to send
SXT_HEADER      = 1
SXT_DATA        = 2
SXT_SUM         = 3
SXT_END         = 4

TSX_FEED        = 1             ; TEST_SYSEX bits: feed test_sysex_data into MIDI in
TSX_CAPTURE     = 2             ;   keep every SysEx byte sent at SYSEX_RAM
TSX_LOOP        = 4             ;   what is sent goes into MIDI in (the synth takes its own dump)

        .weak
SYSEX_VARS      = $c280         ; the variables: after the controller map ($C200-$C27F)
TEST_SYSEX_TICK = 250           ; TEST_SYSEX feed: the tick it starts at
TEST_SYSEX_RATE = 13            ;   bytes a tick
TEST_SYSEX_RAM  = $f000         ;   where sysex_init copies it ($F000-$FEFF)
TEST_SYSEX_END  = $ff00
        .endweak

        .virtual SYSEX_VARS
sx_rx_state     .byte ?         ; SXR_*
sx_rx_kind      .byte ?         ; the message's kind
sx_rx_sum       .byte ?         ; the sum from kind on
sx_rx_end       .word ?         ; where the data's staging ends (SYSEX_RAM + its length)
sx_rx_msb       .byte ?         ; the group's top bits, bit 0 next, with a marker bit above
                                ; them; 0 or 1 (the marker alone): a group's top bits next
sx_rx_extra     .byte ?         ; bytes after the data (the sum: 1)
sx_rx_vector    .word ?         ; sysex_byte's jump
sysex_len       .word ?         ; a received dump's length (the synth reads it)
sysex_src       .word ?         ; sysex_unload: the first byte to write
rg_base         .word ?         ; the region walker: the region's address this time
rg_len          .byte ?         ;   its bytes (0 = 256)
rg_count        .byte ?         ;   times left (0 = the list has ended)
rg_step         .byte ?         ;   pages between times
rg_addr         .word ?         ;   the next byte's address
rg_left         .byte ?         ;   bytes left this time (0 = 256)
rg_y            .byte ?         ;   the entry's offset in the list
sx_tx_state     .byte ?         ; SXT_*
sx_tx_list      .word ?         ; the region list sent
sx_tx_sum       .byte ?
sx_tx_idx       .byte ?         ; the header: the next byte; the data: the group's
sx_burst        .byte ?         ; sysex_pump: bytes still allowed this pass
sx_hdr          .fill SX_HEADER_LEN ; the dump's header, as sent
sx_grp          .fill 1 + SX_GROUP ; a group as sent: the top bits, then up to 7 bytes
sx_grp_len      .byte ?         ; bytes in sx_grp
sx_temp         .byte ?
sx_quiet        .byte ?         ; ticks skipped since the last data byte
.if TEST_SYSEX
sx_test_tick    .word ?         ; ticks since start (the feed starts at TEST_SYSEX_TICK)
sx_feed_left    .word ?         ; feed bytes still to come
sx_feed_addr    .word ?         ; the next one
sx_cap_addr     .word ?         ; the capture's next byte
sx_cap_queue    .byte ?         ; the capture's model of the transmit ring: bytes in it
.endif
SYSEX_VARS_END
        .endvirtual
        .cerror SYSEX_VARS_END > SYSEX_VARS + $80, "the SysEx variables take more than $80 bytes"
        .cerror (sx_rx_vector & $ff) == $ff, "jmp (sx_rx_vector) across a page: the 6502 reads it wrong"

; sysex_region - a region list entry: COUNT times LEN bytes (1..256) from
; ADDR, STEP pages apart
sysex_region    .macro addr, len, count=1, step=0
        .cerror \len < 1 || \len > 256 || \count < 1 || \count > 255, "sysex_region: 1..256 bytes, 1..255 times"
        .word \addr
        .byte \len & $ff, \count, \step     ; (RG_ENTRY_LEN bytes: rg_entry reads them so)
        .endm
; sysex_regions_end - the end of a region list
sysex_regions_end .macro
        .word 0
        .byte 0, 0, 0
        .endm

; -----------------------------------------------------------------------------
; sysex_init - at start (before init_vars): nothing being received or sent;
; test builds set up the feed and the capture.
; clobbers A, X
; -----------------------------------------------------------------------------
sysex_init
        lda #0
        ldx #SYSEX_VARS_END - SYSEX_VARS - 1
-       sta SYSEX_VARS,x
        dex
        bpl -
.if TEST_SYSEX & TSX_FEED
        ; the feed's bytes (test_sysex_data: a length word, then the bytes)
        ; to TEST_SYSEX_RAM, out of the test logs' way
        lda test_sysex_data
        sta sx_feed_left
        lda test_sysex_data+1
        sta sx_feed_left+1
        lda #<test_sysex_data+2
        sta _src+1
        lda #>test_sysex_data+2
        sta _src+2
        lda #<TEST_SYSEX_RAM
        sta _dst+1
        sta sx_feed_addr
        lda #>TEST_SYSEX_RAM
        sta _dst+2
        sta sx_feed_addr+1
        ldx #>(TEST_SYSEX_END - TEST_SYSEX_RAM) ; (whole pages: past the data does no harm)
        ldy #0
_src    lda $ffff,y
_dst    sta $ffff,y
        iny
        bne _src
        inc _src+2
        inc _dst+2
        dex
        bne _src
.endif
.if TEST_SYSEX & TSX_CAPTURE
        ; the capture: SYSEX_RAM cleared (no dump comes in in these tests)
        lda #<SYSEX_RAM
        sta sx_cap_addr
        sta _clr+1
        lda #>SYSEX_RAM
        sta sx_cap_addr+1
        sta _clr+2
        ldx #>SYSEX_MAX
        lda #0
        tay
_clr    sta $ffff,y
        iny
        bne _clr
        inc _clr+2
        dex
        bne _clr
.endif
        rts

; =============================================================================
; Receiving
; =============================================================================

; -----------------------------------------------------------------------------
; sysex_start - (from midi_system) F0: a message begins.
; clobbers A
; -----------------------------------------------------------------------------
sysex_start
        lda #SXR_ID
        sta sx_rx_state
        rts

; -----------------------------------------------------------------------------
; sysex_end - (from midi_system) F7: the message ends. A complete request
; goes to synth_sysex_request (A = the kind); a dump for us to
; synth_sysex_dump, A = the kind, carry clear = good (sysex_len bytes at
; SYSEX_RAM), set = bad. Anything else is forgotten.
; clobbers A, X, Y (and what the synth's hook does)
; -----------------------------------------------------------------------------
sysex_end
        ldx sx_rx_state
        lda #0
        sta sx_rx_state
        lda sx_rx_kind
        cpx #SXR_REQ_END
        beq _request
        cpx #SXR_SUM
        beq _check
        cpx #SXR_KIND+1         ; a dump's kind came: it was ours, so it is told
        bcs _bad
        rts                     ; not ours, or not ours to answer
_request
        jmp synth_sysex_request
_check  ldx sx_rx_extra         ; exactly the sum after the data
        dex
        bne _bad
        lda sx_rx_sum
        and #$7f
        bne _bad
        lda sx_rx_kind
        clc
        jmp synth_sysex_dump
_bad    lda sx_rx_kind
        sec
        jmp synth_sysex_dump

; -----------------------------------------------------------------------------
; sysex_byte - (from midi_sysdata) a data byte while a message of ours may
; be coming (sx_rx_state nonzero): one step of the state machine.
; A: the byte. clobbers A, X, Y
; -----------------------------------------------------------------------------
sysex_byte
        ldx sx_rx_state
        ldy sx_rx_jump_lo,x
        sty sx_rx_vector
        ldy sx_rx_jump_hi,x
        sty sx_rx_vector+1
        jmp (sx_rx_vector)

sxr_handlers = [sxr_none, sxr_id, sxr_synth, sxr_device, sxr_command, sxr_req_kind, sxr_none, sxr_kind, sxr_len_lo, sxr_len_hi, sxr_data, sxr_sum, sxr_bad]
        .cerror len(sxr_handlers) != SXR_STATES, "sysex_byte: a handler per state"
sx_rx_jump_lo   .byte <(sxr_handlers)
sx_rx_jump_hi   .byte >(sxr_handlers)

; -----------------------------------------------------------------------------
; The state handlers (sysex_byte jumps to the state's, A = the byte).
; The header first: the manufacturer ID, the synth, the device, the
; command; anything not ours ends the message for us (state 0: its other
; bytes are ignored until the next F0).
; -----------------------------------------------------------------------------
sxr_id  cmp #SYSEX_ID
        beq sxr_next
sxr_not lda #0
        sta sx_rx_state
sxr_none
sxr_bad rts
sxr_synth
        cmp #SYSEX_SYNTH
        beq sxr_next
        bne sxr_not
        ; the device: $7F, or ours (omni: any)
sxr_device
        cmp #SX_DEVICE_ALL
        beq sxr_next
        ldx params+P_CHANNEL    ; omni (0) hears every device, else channel - 1
        beq sxr_next
        dex
        stx sx_temp
        cmp sx_temp
        bne sxr_not
sxr_next
        inc sx_rx_state
        rts
        ; the command: a request or a dump, else not ours
sxr_command
        ldx #SXR_REQ_KIND
        cmp #SX_REQUEST
        beq +
        ldx #SXR_KIND
        cmp #SX_DUMP
        bne sxr_not
+       stx sx_rx_state
        rts
        ; a request's kind: then F7 (sysex_end answers it)
sxr_req_kind
        sta sx_rx_kind
        bpl sxr_next            ; (always: a data byte)

; -----------------------------------------------------------------------------
; A dump: its kind (synth_sysex_begin: the synth goes quiet), the length
; (7 bits in each byte; below SYSEX_MAX), then the data (sxr_data, through
; sx_fast) and the sum (sxr_sum). Every byte from the kind on adds to
; sx_rx_sum.
; -----------------------------------------------------------------------------
sxr_kind
        sta sx_rx_kind
        sta sx_rx_sum
        lda #0
        sta sx_rx_extra
        sta sx_rx_msb
        inc sx_rx_state
        lda sx_rx_kind          ; the synth makes room: a dump at the wire's
        jmp synth_sysex_begin   ; speed takes more time than a busy tick has spare
        ; the length's low 7 bits
sxr_len_lo
        sta sysex_len
        clc
        adc sx_rx_sum
        sta sx_rx_sum
        jmp sxr_next
        ; the length's high 7 bits: the staging set up; while the data comes,
        ; midi_process calls sx_fast and the synth's ticks are skipped
sxr_len_hi
        tax
        clc
        adc sx_rx_sum
        sta sx_rx_sum
        txa
        lsr                     ; len = hi << 7 | lo
        sta sysex_len+1
        lda #0
        ror
        ora sysex_len
        sta sysex_len
        sta sx_rx_end           ; (SYSEX_RAM: whole pages)
        lda sysex_len+1
        cmp #>SYSEX_MAX         ; below SYSEX_MAX (whole pages)
        bcs _too_long
        .cerror (SYSEX_MAX & $ff) != 0 || (SYSEX_RAM & $ff) != 0, "SYSEX_RAM, SYSEX_MAX: whole pages"
        adc #>SYSEX_RAM         ; (carry clear)
        sta sx_rx_end+1
        lda #<SYSEX_RAM         ; staged from SYSEX_RAM on
        sta sxr_store+1
        lda #>SYSEX_RAM
        sta sxr_store+2
        lda #SXR_SUM            ; (no data at all)
        ldx sysex_len
        bne +
        ldx sysex_len+1
        beq ++
+       lda #<sx_fast           ; midi_process hands the data bytes straight over,
        sta midi_process_call
        lda #>sx_fast
        sta midi_process_call+1
        lda #OP_JMP             ; the synth's ticks are skipped
        sta sx_tick_op
        lda #0
        sta sx_quiet
        lda #SXR_DATA
+       sta sx_rx_state
        rts
_too_long
        lda #SXR_BAD
        sta sx_rx_state
        rts

; -----------------------------------------------------------------------------
; sx_fast - midi_process's call while a dump's data comes in (sxr_len_hi
; points it here; the rest of the time it costs nothing): its data bytes
; straight to sxr_data, realtime bytes to midi_byte; anything else (the sum,
; a status byte) puts midi_byte back and goes there.
; A: the byte. clobbers A, X, Y
; -----------------------------------------------------------------------------
sx_fast
        ldx sx_rx_state
        cpx #SXR_DATA
        bne _back
        cmp #$80
        bcs _status             ; (a data byte is below $80)
        ldx #MIDI_LED_TIME      ; (the activity indicator, as midi_byte)
        stx midi_led
        ldx #0
        stx sx_quiet
        jmp sxr_data
_status cmp #SX_REALTIME
        bcs _byte               ; realtime: the data goes on after it
_back   jsr sx_normal
_byte   jmp midi_byte

; -----------------------------------------------------------------------------
; sx_normal - midi_process calls midi_byte again, the synth's ticks run.
; preserves A, Y; clobbers X
; -----------------------------------------------------------------------------
sx_normal
        ldx #<midi_byte
        stx midi_process_call
        ldx #>midi_byte
        stx midi_process_call+1
        ldx #OP_BIT
        stx sx_tick_op
        rts

; -----------------------------------------------------------------------------
; sx_skip_tick - (the main loop jumps here instead of synth_tick while a
; dump's data comes in) the tick is skipped. If no data byte came for
; SX_TIMEOUT ticks, the dump has stopped (a cable pulled, the PC stopped):
; it ends, and the synth hears it was bad.
; -----------------------------------------------------------------------------
sx_skip_tick
        inc sx_quiet
        lda sx_quiet
        cmp #SX_TIMEOUT
        bcs +
        jmp main_loop
+       jsr sx_normal
        lda #0
        sta sx_rx_state
        lda sx_rx_kind
        sec
        jsr synth_sysex_dump
        jmp main_loop

; -----------------------------------------------------------------------------
; sxr_data - a byte of the packed data (the hot path: ~12 come every tick).
; A group's top-bits byte is kept with a marker bit above its 7 bits; each
; data byte shifts its own top bit out, so after 7 bytes only the marker
; is left (1) and the next byte is a group's top bits again. The bytes go
; to the staging area through a self-modified store; at sx_rx_end the sum
; is due.
; A: the byte. clobbers A, X (SYSEX_UNDER_IO: and Y)
; -----------------------------------------------------------------------------
sxr_data
        tax
        clc
        adc sx_rx_sum
        sta sx_rx_sum
        lda sx_rx_msb
        cmp #SX_GROUP_DUE
        bcs _byte
        txa                     ; a group's top bits, the marker above them
        ora #SX_TOP_MARKER
        sta sx_rx_msb
        rts
_byte   lsr sx_rx_msb           ; this byte's top bit
        txa
        bcc +
        ora #$80
+
.if SYSEX_UNDER_IO
        ldy #SX_RAM_ONLY        ; the staging may run under the I/O chips: out with them
        sei                     ; meanwhile (the interrupt handlers need them)
        sty CPU_PORT
.endif
sxr_store
        sta $ffff               ; (the address self-modified: the staging area)
.if SYSEX_UNDER_IO
        ldy #RAM_IO             ; I/O back
        sty CPU_PORT
        cli
.endif
        inc sxr_store+1
        beq _page
        lda sxr_store+1         ; the end? (the low byte first: rarely equal)
        cmp sx_rx_end
        beq _end_hi
        rts
_page   inc sxr_store+2
        lda sxr_store+1
        cmp sx_rx_end
        bne _more
_end_hi lda sxr_store+2
        cmp sx_rx_end+1
        bne _more
        lda #SXR_SUM
        sta sx_rx_state
_more   rts

; sxr_sum - the bytes after the data: the sum (exactly one: sysex_end
; checks). A: the byte. clobbers A
sxr_sum clc
        adc sx_rx_sum
        sta sx_rx_sum
        inc sx_rx_extra         ; (more than one: bad at F7)
        bne +
        dec sx_rx_extra         ; (stays above 1)
+       rts

; =============================================================================
; Region lists
; =============================================================================

; -----------------------------------------------------------------------------
; rg_start - walk the region list at X (low), Y (high) from its start.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rg_start
        stx rg_list_op
        sty rg_list_op+1
        lda #0
        sta rg_y
        ; fall through

; -----------------------------------------------------------------------------
; rg_entry - the walker to the entry at rg_y (rg_count 0: the list's end):
; the entry's bytes into rg_base, rg_len, rg_count, rg_step (in that order
; in memory), then the first time's address and bytes left.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rg_entry
        ldy rg_y
        ldx #0
-
rg_list_op = *+1
        lda $ffff,y             ; (the list's address self-modified)
        sta rg_base,x           ; rg_base, rg_len, rg_count, rg_step
        iny
        inx
        cpx #RG_ENTRY_LEN
        bne -
        lda rg_base             ; the first time: from the region's address
        sta rg_addr
        lda rg_base+1
        sta rg_addr+1
        lda rg_len
        sta rg_left
        rts

; -----------------------------------------------------------------------------
; rg_advance - the walker past a byte: on in the region, its next time
; (rg_step pages on), or the next entry.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rg_advance
        inc rg_addr
        bne +
        inc rg_addr+1
+       dec rg_left
        bne _done
        dec rg_count
        beq _next
        lda rg_base+1           ; the next time
        clc
        adc rg_step
        sta rg_base+1
        sta rg_addr+1
        lda rg_base
        sta rg_addr
        lda rg_len
        sta rg_left
_done   rts
_next   lda rg_y
        clc
        adc #RG_ENTRY_LEN
        sta rg_y
        jmp rg_entry

; -----------------------------------------------------------------------------
; rg_read - the walker's next byte. Out: carry clear, A = the byte; carry
; set: the list has ended.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
rg_read
        lda rg_count
        beq _end
        lda rg_addr
        sta _read+1
        lda rg_addr+1
        sta _read+2
_read   lda $ffff               ; (self-modified)
        pha
        jsr rg_advance
        pla
        clc
        rts
_end    sec
        rts

; -----------------------------------------------------------------------------
; sysex_unload - write the bytes from sysex_src on through the region list
; at X (low), Y (high), until it ends. The synth has checked the length.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sysex_unload
        jsr rg_start
        lda sysex_src
        sta _src+1
        lda sysex_src+1
        sta _src+2
_byte   lda rg_count
        beq _done
        lda rg_addr
        sta _dst+1
        lda rg_addr+1
        sta _dst+2
.if SYSEX_UNDER_IO
        ldy #SX_RAM_ONLY        ; the staging may run under the I/O chips (as sxr_data)
        sei
        sty CPU_PORT
.endif
_src    lda $ffff               ; (self-modified: the staged byte)
.if SYSEX_UNDER_IO
        ldy #RAM_IO
        sty CPU_PORT
        cli
.endif
_dst    sta $ffff               ; (self-modified: where it belongs)
        inc _src+1
        bne +
        inc _src+2
+       jsr rg_advance
        jmp _byte
_done   rts

; -----------------------------------------------------------------------------
; sysex_measure - the region list at X (low), Y (high): its bytes into
; sysex_len.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sysex_measure
        jsr rg_start
        lda #0
        sta sysex_len
        sta sysex_len+1
_entry  lda rg_count
        beq _done
-       ldx #0                  ; + rg_len (0 = 256), rg_count times
        lda rg_len
        bne +
        inx
+       clc
        adc sysex_len
        sta sysex_len
        txa
        adc sysex_len+1
        sta sysex_len+1
        dec rg_count
        bne -
        lda rg_y
        clc
        adc #RG_ENTRY_LEN
        sta rg_y
        jsr rg_entry
        jmp _entry
_done   rts

; =============================================================================
; Sending
; =============================================================================

; -----------------------------------------------------------------------------
; sysex_send - start sending a dump: A = its kind, X (low), Y (high) = the
; region list of its file. sysex_pump sends it. A dump still going is
; replaced (the synth asks sysex_busy first).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sysex_send
        sta sx_hdr+SXH_KIND     ; F0 7D synth device 02 kind len-lo len-hi
        stx sx_tx_list
        sty sx_tx_list+1
        jsr sysex_measure
        ldx #MIDI_SYSEX_START
        stx sx_hdr
        ldx #SYSEX_ID
        stx sx_hdr+1
        ldx #SYSEX_SYNTH
        stx sx_hdr+2
        ldx params+P_CHANNEL    ; device: channel - 1, omni: any
        dex
        bpl +
        ldx #SX_DEVICE_ALL
+       stx sx_hdr+SXH_DEVICE
        ldx #SX_DUMP
        stx sx_hdr+SXH_COMMAND
        lda sysex_len           ; the length, 7 bits in each
        and #$7f
        sta sx_hdr+SXH_LEN_LO
        lda sysex_len
        asl                     ; bit 7 -> carry
        lda sysex_len+1
        rol
        sta sx_hdr+SXH_LEN_HI
        lda sx_hdr+SXH_KIND     ; the sum so far: kind and length
        clc
        adc sx_hdr+SXH_LEN_LO
        clc
        adc sx_hdr+SXH_LEN_HI
        sta sx_tx_sum
        ldx sx_tx_list          ; the walker at the file's start
        ldy sx_tx_list+1
        jsr rg_start
        lda #0
        sta sx_tx_idx
        lda #SXT_HEADER
        sta sx_tx_state
        lda #OP_JSR             ; the main loop calls sysex_pump
        sta sx_pump_op
        rts

; -----------------------------------------------------------------------------
; sysex_busy - out: A nonzero (Z clear) while a dump is being sent.
; -----------------------------------------------------------------------------
sysex_busy
        lda sx_tx_state
        rts

; -----------------------------------------------------------------------------
; sysex_pump - (main loop) queue the dump's next bytes for MIDI out: at most
; SX_BURST a pass, and only while the transmit ring has room.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sysex_pump
        lda sx_tx_state
        beq _done
        lda #SX_BURST
        sta sx_burst
_byte
.if TEST_SYSEX & TSX_LOOP
        ldx rx_head             ; (the loop: room in the receive ring)
        inx
        cpx rx_tail
        beq _done
.elsif TEST_SYSEX & TSX_CAPTURE
        lda sx_cap_queue        ; (the capture's VICE has no MIDI: nothing drains the real
        cmp #255                ; ring, so a model of it paces the dump as the wire would:
        beq _done               ; test_sysex_tick drains it 12.5 bytes a tick)
.else
        ldx tx_head             ; room in the ring?
        inx
        cpx tx_tail
        beq _done
.endif
        jsr sx_next
        bcs _done               ; all sent
        jsr sx_out
        dec sx_burst
        bne _byte
_done   rts

; -----------------------------------------------------------------------------
; sx_next - the dump's next byte. Out: carry clear, A = the byte; carry set:
; nothing more (the dump is done; synth_sysex_sent has been told).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sx_next
        ldx sx_tx_state
        cpx #SXT_HEADER
        bne _data
        ldx sx_tx_idx           ; the header, as sysex_send made it
        lda sx_hdr,x
        inx
        stx sx_tx_idx
        cpx #SX_HEADER_LEN
        bne _out
        ldx #0
        stx sx_tx_idx
        stx sx_grp_len
        ldx #SXT_DATA
        stx sx_tx_state
_out    clc
        rts

_data   cpx #SXT_DATA
        bne _sum
        ldx sx_tx_idx           ; the group's bytes left?
        cpx sx_grp_len
        bcc _group_byte
        jsr sx_group            ; the next group (sx_tx_idx = 0)
        ldx #0
        lda sx_grp_len
        bne _group_byte
        lda #SXT_SUM            ; no more data: the sum next
        sta sx_tx_state
        bne _sum_now            ; always
_group_byte
        lda sx_grp,x
        inx
        stx sx_tx_idx
        tax
        clc
        adc sx_tx_sum
        sta sx_tx_sum
        txa
        clc
        rts

_sum    cpx #SXT_SUM
        bne _end
_sum_now
        lda #SXT_END
        sta sx_tx_state
        lda #0                  ; the sum: the total a multiple of 128
        sec
        sbc sx_tx_sum
        and #$7f
        clc
        rts

_end    lda #0                  ; F7, and done
        sta sx_tx_state
        lda #OP_BIT             ; the main loop stops calling sysex_pump
        sta sx_pump_op
        jsr synth_sysex_sent
        lda #MIDI_SYSEX_END
        jsr sx_out
        sec
        rts

; -----------------------------------------------------------------------------
; sx_out - a byte of the dump out: midi_send (test builds: kept by the
; capture, or into MIDI in for the loop).
; A: the byte. clobbers X
; -----------------------------------------------------------------------------
sx_out
.if TEST_SYSEX & TSX_CAPTURE
        jsr sx_capture
.endif
.if TEST_SYSEX & TSX_LOOP
        sei                     ; (the IRQ handler writes the ring too)
        ldx rx_head
        sta rx_buffer,x
        inc rx_head
        cli
        rts
.else
        jmp midi_send
.endif

; -----------------------------------------------------------------------------
; sx_group - the next group from the walker into sx_grp: the top bits, then
; up to 7 bytes' low 7 bits; sx_grp_len = its bytes (0: the file has
; ended), sx_tx_idx = 0.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
sx_group
        lda #1
        sta sx_grp_len
-       jsr rg_read
        bcs _ended
        ldx sx_grp_len
        sta sx_grp,x
        inc sx_grp_len
        cpx #SX_GROUP
        bne -
_ended  ldx sx_grp_len
        dex
        bne +
        stx sx_grp_len          ; nothing read: the file has ended
        rts
+       lda #0                  ; the top bits, the last byte's first: bit 0 = the first's
        sta sx_grp
-       lda sx_grp,x
        asl                     ; bit 7 -> carry
        rol sx_grp
        lsr                     ; the low 7 bits back
        sta sx_grp,x
        dex
        bne -
        stx sx_tx_idx
        rts

; =============================================================================
; Test builds
; =============================================================================

.if TEST_SYSEX & TSX_CAPTURE
; sx_capture - TEST_SYSEX capture: byte A, as sent, at sx_cap_addr (from
; SYSEX_RAM on). preserves A
sx_capture
        pha
        ldx sx_cap_addr+1
        cpx #>(SYSEX_RAM + SYSEX_MAX)
        bcs +                   ; full
        ldx sx_cap_addr
        stx _st+1
        ldx sx_cap_addr+1
        stx _st+2
_st     sta $ffff
        inc sx_cap_addr
        bne +
        inc sx_cap_addr+1
+       inc sx_cap_queue        ; one more in the ring's model
        pla
        rts
.endif

.if TEST_SYSEX
; -----------------------------------------------------------------------------
; test_sysex_tick - TEST_SYSEX, once per tick (skipped ones too). The
; capture: its model of the transmit ring drains as the wire would send,
; 12 and 13 bytes a tick in turn. The feed: from tick TEST_SYSEX_TICK on,
; TEST_SYSEX_RATE of the feed's bytes into the MIDI ring as if they had
; been received (13 a tick is a little faster than the wire's 12.5).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
WIRE_PER_TICK   = 12            ; bytes the wire sends a tick (+1 every other tick)
test_sysex_tick
.if TEST_SYSEX & TSX_CAPTURE
        lda sx_test_tick        ; 12, then 13: 12.5 a tick
        and #1
        sec
        adc #WIRE_PER_TICK - 1  ; (carry set: + 1)
        sta sx_temp
        lda sx_cap_queue
        sec
        sbc sx_temp
        bcs +
        lda #0                  ; the ring has run empty
+       sta sx_cap_queue
.endif
.if !(TEST_SYSEX & TSX_FEED)
        inc sx_test_tick
        rts
.else
        inc sx_test_tick
        bne +
        inc sx_test_tick+1
+       lda sx_test_tick+1
        cmp #>TEST_SYSEX_TICK
        bcc _done
        bne +
        lda sx_test_tick
        cmp #<TEST_SYSEX_TICK
        bcc _done
+       ldy #TEST_SYSEX_RATE
_byte   lda sx_feed_left
        ora sx_feed_left+1
        beq _done
        lda sx_feed_addr
        sta _ld+1
        lda sx_feed_addr+1
        sta _ld+2
_ld     lda $ffff
        sei                     ; the IRQ handler may write the ring too
        ldx rx_head
        sta rx_buffer,x
        inc rx_head
        cli
        inc sx_feed_addr
        bne +
        inc sx_feed_addr+1
+       lda sx_feed_left
        bne +
        dec sx_feed_left+1
+       dec sx_feed_left
        dey
        bne _byte
_done   rts
.endif
.endif
