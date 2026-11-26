; midilat.asm - MIDI interface latency test for a real C64 (SidSynth family)
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Measures a MIDI cartridge's 6850 ACIA (or an emulation of one, such as the
; Kerberos cartridge's) the way the SidSynth programs use it, to compare the
; real hardware with VICE (docs/latency.md: VICE's 6850 sends a byte every
; 283 cycles, the wire takes 315 at 31,250 baud):
;
;   1. transmit pacing (no cable needed): bytes written back to back as the
;      ACIA takes them (its "transmit data register empty" flag); the time
;      between them, and how many it takes at once (a real 6850 has the data
;      register and the shift register: two);
;   2. loopback, one byte (MIDI OUT cabled to MIDI IN): from the write to the
;      byte's arrival back ("receive data register full");
;   3. loopback, a 3-byte message (a note on's size), written as fast as the
;      ACIA takes it: from the first write to the last byte back;
;   4. loopback, a 64-byte burst: the whole and a byte's share.
;
; Every byte received is compared with what was sent; framing and overrun
; errors are counted. Only data bytes ($00-$7F) are sent, never a status
; byte, so a device left connected ignores them. Interrupts are off while a
; test runs (the ACIA's are never enabled, so Namesoft's NMI stays quiet);
; times come from CIA2's timer A counting cycles, shown in cycles and in
; microseconds at the machine's clock (PAL or NTSC, from the KERNAL's flag).
;
; Build: 64tass -C --cbm-prg -o midilat.prg midilat.asm (hwtest/build.sh; no -a: the
; texts are upper case ASCII, the same bytes as PETSCII's upper case)

; -----------------------------------------------------------------------------
; Hardware and KERNAL
; -----------------------------------------------------------------------------
CHROUT          = $ffd2         ; KERNAL: print the character in A
GETIN           = $ffe4         ; KERNAL: a key from the buffer, 0 = none
PAL_FLAG        = $02a6         ; KERNAL: 1 = PAL, 0 = NTSC (set at power on)
CIA2_TA_LO      = $dd04         ; CIA2 timer A, counting down a cycle at a time
CIA2_TA_HI      = $dd05
CIA2_ICR        = $dd0d         ; its interrupt control (NMI): all kept off
CIA2_CRA        = $dd0e         ; timer A's control
CRA_START_LOAD  = %00010001     ; start, continuous, latch loaded now
IO_PAGE         = $de           ; every MIDI cartridge's registers are in page $DE

ACIA_RESET      = %00000011     ; control: master reset
ACIA_8N1        = %00010100     ; control: 8 data bits, no parity, 1 stop, no interrupts
ACIA_DIV16      = %01           ;   500 kHz clock / 16 = 31,250 baud (Sequential, Passport, Namesoft)
ACIA_DIV64      = %10           ;   2 MHz clock / 64 (Datel)
ACIA_RDRF       = %00000001     ; status: a received byte waiting
ACIA_TDRE       = %00000010     ; status: the transmit data register empty
ACIA_ERRORS     = %00110000     ; status: framing error (4), receiver overrun (5)

        .weak
AUTO_IF         = 0              ; VICE runs (-D AUTO_IF=3): the interface given, no menu
        .endweak
PACE_BYTES      = 64            ; test 1: bytes timed (after the ones taken at once)
QUICK_CYCLES    = 150           ; test 1: a byte taken within this of the last: "at once"
LOOP_BYTES      = 64            ; test 2: single bytes sent and timed
MSG_LEN         = 3             ; test 3: a note on's bytes
MSG_RUNS        = 32            ;   messages timed
BURST_LEN       = 64            ; test 4: bytes in the burst
BURST_RUNS      = 8             ;   bursts timed
TIMEOUT_HI      = 40            ; polls x 256 before a byte counts as never coming back (~80 ms)

; -----------------------------------------------------------------------------
; Zero page (the KERNAL's free bytes and the RS-232 ones, unused here)
; -----------------------------------------------------------------------------
ctrl_ptr        = $f7           ; the ACIA's control register (write)
status_ptr      = $f9           ;   its status register (read)
tx_ptr          = $fb           ;   its transmit data register (write)
rx_ptr          = $fd           ;   its receive data register (read)
text_ptr        = $22           ; print_text: the text (BASIC's temporary pointer)
t0              = $26           ; a time stamp (word: the timer's count)
delta           = $28           ; an interval in cycles (word)
num             = $2a           ; print_dec: the number (word)
digit_seen      = $2c
log_ptr         = $33           ; log_rx: RX_LOG's next place (word)           ; print_dec: nonzero once a digit is printed
poll_lo         = $2d           ; a wait's poll count (word)
poll_hi         = $2e
sent            = $2f           ; bytes written in a message or burst
received        = $30           ;   and come back
value           = $31           ; the next byte value to send
expect          = $32           ; the next byte value to receive

        * = $0801
; BASIC stub: 10 SYS 2061
        .word +, 10
        .byte $9e
        .text "2061", 0
+       .word 0

; -----------------------------------------------------------------------------
; start - the interface asked for, then the tests; again on a key
; -----------------------------------------------------------------------------
start
        lda #$7f                ; CIA2: no NMIs, its timer A running free
        sta CIA2_ICR
        lda CIA2_ICR
        lda #$ff
        sta CIA2_TA_LO
        sta CIA2_TA_HI
        lda #CRA_START_LOAD
        sta CIA2_CRA
.if AUTO_IF
        lda #AUTO_IF            ; (VICE runs: the interface given, no menu)
        jmp _chosen
.endif
_menu   ldx #<text_menu
        ldy #>text_menu
        jsr print_text
-       jsr GETIN               ; 1-4: the interface
        cmp #"1"
        bcc -
        cmp #"6"
        bcs -
        and #$0f
_chosen jsr if_select
        jsr if_present          ; a 6850 there? else the tests mean nothing
        bcc +
        ldx #<text_absent
        ldy #>text_absent
        jsr print_text
        jmp _again
+       jsr test_pace
        ldx #<text_cable
        ldy #>text_cable
        jsr print_text
        jsr wait_key
        jsr test_loop_byte
        bcs _again              ; (nothing came back: the rest can't run)
        jsr test_message
        jsr test_burst
_again  ldx #<text_again
        ldy #>text_again
        jsr print_text
        jsr wait_key
        jmp _menu

; -----------------------------------------------------------------------------
; if_select - interface A (1 Sequential, 2 Passport, 3 Datel, 4 Namesoft,
; 5 a Kerberos cartridge, its MIDI switched on as Datel): its registers'
; pointers, its name printed, the ACIA reset and set to 31,250 baud 8N1
; with no interrupts. clobbers A, X, Y
; -----------------------------------------------------------------------------
if_select
        tax
        cpx #IF_KERBEROS
        bne +
        lda #KERBEROS_AS_DATEL  ; the Kerberos: its 6850 where Datel's is, MIDI on
        sta KERBEROS_MIDI_ADDRESS
        lda #KERBEROS_MIDI_ON
        sta KERBEROS_MIDI_CONFIG
+       lda #IO_PAGE            ; the pointers' high bytes
        sta ctrl_ptr+1
        sta status_ptr+1
        sta tx_ptr+1
        sta rx_ptr+1
        lda if_ctrl,x           ; and their low bytes
        sta ctrl_ptr
        lda if_status,x
        sta status_ptr
        lda if_tx,x
        sta tx_ptr
        lda if_rx,x
        sta rx_ptr
        lda if_control,x
        pha
        lda if_name_lo,x        ; its name
        ldy if_name_hi,x
        tax
        jsr print_text
        ldy #0                  ; the ACIA reset, then set up
        lda #ACIA_RESET
        sta (ctrl_ptr),y
        pla
        sta (ctrl_ptr),y
        lda (rx_ptr),y          ; (a stale byte dropped)
        ldx #<text_clock        ; the clock the microseconds are at
        ldy #>text_clock
        lda PAL_FLAG
        bne +
        ldx #<text_clock_ntsc
        ldy #>text_clock_ntsc
+       jmp print_text

; -----------------------------------------------------------------------------
; if_present - does a 6850 answer at the chosen registers? After its reset,
; with nothing sent or received, its status must read PRESENT_READS times
; running with "transmit register empty" set and "byte received" clear (no
; cartridge, or another mode than the one chosen, reads the bus's leftovers
; there: bits that flicker; the error bits may be stale, so not looked at).
; Carry clear: yes. clobbers A, X, Y
; -----------------------------------------------------------------------------
PRESENT_READS   = 0             ; 256 reads (X wraps)
if_present
        jsr idle_wire           ; (Y = 0)
        ldx #PRESENT_READS
-       lda (status_ptr),y
        sta present_status      ; (the last read: for a look over the network)
        and #ACIA_TDRE | ACIA_RDRF
        cmp #ACIA_TDRE
        bne _no
        dex
        bne -
        clc
        rts
_no     sec
        rts

; The Kerberos cartridge (Frank Buss; its source, c64/src/regs.h): its 6850
; at two places (control/status, then data) for writes from $DE00 + the
; high half of MIDI_ADDRESS, for reads from $DE00 + its low half (measured
; on the user's Ultimate 64, 2026-11-26: $46 = Datel's layout, writes at
; $DE04/05, reads at $DE06/07; $02 Sequential's and Namesoft's, $88
; Passport's). MIDI_CONFIG: on ($20), 2 MHz ($04: Datel's /64; 500 kHz
; $00), no IRQ ($01) or NMI ($02) here. Its menu switches MIDI off; a
; program started from a slot gets the slot's settings.
IF_KERBEROS     = 5
KERBEROS_MIDI_ADDRESS = $de39
KERBEROS_MIDI_CONFIG  = $de3a
KERBEROS_AS_DATEL     = $46
KERBEROS_MIDI_ON      = $24

; interface tables, index 1-5 (0 unused); register low bytes in page $DE,
; as core/midi.asm's (from VICE's c64-midi.c)
if_ctrl         .byte 0, $00, $08, $04, $00, $04 ; control (write)
if_status       .byte 0, $02, $08, $06, $02, $06 ; status (read)
if_tx           .byte 0, $01, $09, $05, $01, $05 ; transmit data (write)
if_rx           .byte 0, $03, $09, $07, $03, $07 ; receive data (read)
if_control      .byte 0, ACIA_8N1|ACIA_DIV16, ACIA_8N1|ACIA_DIV16, ACIA_8N1|ACIA_DIV64, ACIA_8N1|ACIA_DIV16, ACIA_8N1|ACIA_DIV64
if_name_lo      .byte 0, <text_seq, <text_pass, <text_datel, <text_name, <text_kerberos
if_name_hi      .byte 0, >text_seq, >text_pass, >text_datel, >text_name, >text_kerberos

; -----------------------------------------------------------------------------
; read_time - (macro, interrupts off) A = CIA2 timer A's low byte, X = its
; high byte, read so the two belong together (the high byte read again: if
; it moved meanwhile, again). The timer counts down: an interval is the
; earlier reading minus the later one. Same cost every time (~14 cycles).
; -----------------------------------------------------------------------------
read_time .macro
-       ldx CIA2_TA_HI
        lda CIA2_TA_LO
        cpx CIA2_TA_HI
        bne -
        .endm

; stamp_t0 - (macro) the time now into t0
stamp_t0 .macro
        #read_time
        sta t0
        stx t0+1
        .endm

; -----------------------------------------------------------------------------
; test_pace - test 1: PACE_BYTES + the first ones written as the ACIA takes
; them (status TDRE polled), the time between takes; the first ones taken
; within QUICK_CYCLES of the last counted as taken at once (the ACIA's
; buffer), the rest give the byte period. clobbers A, X, Y
; -----------------------------------------------------------------------------
test_pace
        jsr stats_clear
        jsr idle_wire           ; (the wire quiet: the buffer empty)
        lda #0
        sta value
        sta sent                ; (counts the bytes taken at once)
        sta received            ; (nonzero once a byte waited: the period from then)
        ldy #0
        sei
        #stamp_t0
        ldx #PACE_BYTES+8       ; (up to 8 taken at once, then PACE_BYTES timed)
        stx poll_hi
_byte   lda (status_ptr),y      ; wait until it takes a byte
        and #ACIA_TDRE
        beq _byte
        jsr take_delta          ; delta: since the last take
        lda value               ; the byte (a data byte: ignored by any device)
        sta (tx_ptr),y
        inc value
        lda value
        and #$7f
        sta value
        lda received            ; still taking at once?
        bne _timed
        lda delta+1
        bne _waited
        lda delta
        cmp #QUICK_CYCLES
        bcs _waited
        inc sent                ; taken at once
        jmp _next
_waited inc received            ; the first that waited: the period from here
        jmp _next
_timed  jsr stats_add
_next   dec poll_hi
        bne _byte
        cli
        ldx #<text_pace
        ldy #>text_pace
        jsr print_text
        lda sent                ; the results: how many at once, then the period
        ldx #0
        jsr print_dec
        ldx #<text_period
        ldy #>text_period
        jsr print_text
        jmp stats_print

; -----------------------------------------------------------------------------
; test_loop_byte - test 2: LOOP_BYTES bytes one at a time, each timed from
; its write to its arrival back. Carry set: a byte never came back (the
; cable missing). clobbers A, X, Y
; -----------------------------------------------------------------------------
test_loop_byte
        jsr log_clear
        ldx #<text_loop
        ldy #>text_loop
        jsr print_text
        jsr stats_clear
        jsr idle_wire
        lda #0
        sta value
        sta expect
        sta errors
        sta errors+1
        lda #LOOP_BYTES
        sta sent
        ldy #0
_byte   sei
-       lda (status_ptr),y      ; the transmitter free (the last byte gone)
        and #ACIA_TDRE
        beq -
        #stamp_t0
        lda value
        sta (tx_ptr),y
        jsr wait_rx             ; its arrival (carry set: never)
        bcs _none
        jsr take_delta
        jsr check_byte
        jsr stats_add
        cli
        inc value
        dec sent
        bne _byte
        jsr stats_print
        jsr errors_print
        clc
        rts
_none   cli
        ldx #<text_none
        ldy #>text_none
        jsr print_text
        sec
        rts

; -----------------------------------------------------------------------------
; test_message - test 3: MSG_RUNS messages of MSG_LEN bytes, each written as
; fast as the ACIA takes them, timed from the first write to the last byte
; back. clobbers A, X, Y
; -----------------------------------------------------------------------------
test_message
        ldx #<text_message
        ldy #>text_message
        jsr print_text
        lda #MSG_LEN
        ldx #MSG_RUNS
        jmp test_runs

; -----------------------------------------------------------------------------
; test_burst - test 4: BURST_RUNS bursts of BURST_LEN bytes, as test 3; the
; whole printed, then a byte's share (the whole / BURST_LEN). clobbers A, X, Y
; -----------------------------------------------------------------------------
test_burst
        ldx #<text_burst
        ldy #>text_burst
        jsr print_text
        lda #BURST_LEN
        ldx #BURST_RUNS
        jsr test_runs
        ldx #<text_per_byte
        ldy #>text_per_byte
        jsr print_text
        lda stats_sum           ; the average of the wholes / 64 (= sum / runs / 64)
        sta num
        lda stats_sum+1
        sta num+1
        lda stats_sum+2
        ldx #BURST_SHIFT        ; (runs x 64 = 512: 9 shifts)
-       lsr a
        ror num+1
        ror num
        dex
        bne -
        jsr print_cycles_us
        lda #13
        jmp CHROUT
BURST_SHIFT = 9
        .cerror BURST_RUNS * BURST_LEN != 1 << BURST_SHIFT, "BURST_SHIFT: runs x bytes"

; -----------------------------------------------------------------------------
; test_runs - X runs of A bytes each, written as fast as the ACIA takes them
; while the ones coming back are read, each run timed from its first write
; to its last byte back; the stats of the runs, the errors. clobbers A, X, Y
; -----------------------------------------------------------------------------
test_runs
        sta run_len
        stx run_count
        jsr stats_clear
        jsr idle_wire
        lda #0
        sta value
        sta expect
        sta errors
        sta errors+1
        ldy #0
_run    sei
        lda #0
        sta sent
        sta received
        lda #0                  ; (a timeout's count from 0)
        sta poll_lo
        sta poll_hi
        #stamp_t0
_poll   lda (status_ptr),y      ; a byte back?
        lsr a                   ; RDRF -> carry
        bcc _send
        jsr check_byte          ; (reads it)
        inc received
        lda received
        cmp run_len
        beq _done
_send   lda sent                ; one to write, and room for it?
        cmp run_len
        bcs _wait
        lda (status_ptr),y
        and #ACIA_TDRE
        beq _wait
        lda value
        sta (tx_ptr),y
        inc value
        lda value
        and #$7f
        sta value
        inc sent
_wait   inc poll_lo             ; a timeout (nothing back for long)
        bne _poll
        inc poll_hi
        lda poll_hi
        cmp #TIMEOUT_HI
        bcc _poll
        cli
        ldx #<text_none
        ldy #>text_none
        jmp print_text
_done   jsr take_delta
        jsr stats_add
        cli
        jsr idle_wire           ; (the next run from a quiet wire)
        dec run_count
        bne _run
        jsr stats_print
        jmp errors_print

; -----------------------------------------------------------------------------
; take_delta - delta = t0 - the time now (the cycles since t0, the timer
; counting down); t0 = now. The same cost wherever it is called, so it
; cancels out of every interval. clobbers A, X
; -----------------------------------------------------------------------------
take_delta
        #read_time
        pha                     ; (the low byte kept for t0)
        stx now_hi
        sec
        sbc t0                  ; (now - t0: negative of the interval)
        eor #$ff                ; -(now - t0) - 1 ...
        sta delta
        txa
        sbc t0+1
        eor #$ff
        sta delta+1
        inc delta               ; ... + 1: t0 - now
        bne +
        inc delta+1
+       pla
        sta t0
        lda now_hi
        sta t0+1
        rts

; -----------------------------------------------------------------------------
; wait_rx - (interrupts off) until a byte has come in (status RDRF), at most
; TIMEOUT_HI x 256 polls. Carry set: none came. clobbers A; keeps X, Y (0)
; -----------------------------------------------------------------------------
wait_rx
        lda #0
        sta poll_lo
        sta poll_hi
-       lda (status_ptr),y
        lsr a                   ; RDRF -> carry
        bcs _in
        inc poll_lo
        bne -
        inc poll_hi
        lda poll_hi
        cmp #TIMEOUT_HI
        bcc -
        sec                     ; never
        rts
_in     clc
        rts

; -----------------------------------------------------------------------------
; check_byte - the byte waiting read and compared with expect (then the next
; expected); a wrong one, or a framing error or overrun in the status,
; counted in errors. clobbers A; keeps X, Y (0)
; -----------------------------------------------------------------------------
check_byte
        lda (status_ptr),y      ; (its errors, before the read clears them)
        sta rx_status
        lda (rx_ptr),y
        jsr log_rx              ; (kept at RX_LOG: read over the network on an Ultimate)
        lda rx_status
        and #ACIA_ERRORS
        bne _wrong
        lda rx_byte
        cmp expect
        beq _ok
_wrong  inc errors
        bne _ok
        inc errors+1
_ok     lda expect
        clc
        adc #1
        and #$7f
        sta expect
        rts

; -----------------------------------------------------------------------------
; log_rx - byte A (rx_byte too) and its status (rx_status) at RX_LOG's next
; place, while there is room: what came back, to read afterwards (an
; Ultimate's REST API: machine:readmem). keeps X, Y
; RX_LOG: pairs of (status, byte), from test 2 on; RX_LOG_COUNT (word):
; the pairs written. Cleared at each start of test 2.
; -----------------------------------------------------------------------------
RX_LOG          = $c000
RX_LOG_END      = $cff0
RX_LOG_COUNT    = $cffe
log_rx
        sta rx_byte
        lda log_ptr+1
        cmp #>RX_LOG_END
        bcs _rts                ; (full)
        tya
        pha
        ldy #0
        lda rx_status
        sta (log_ptr),y
        iny
        lda rx_byte
        sta (log_ptr),y
        pla
        tay
        lda log_ptr             ; on two
        clc
        adc #2
        sta log_ptr
        bcc +
        inc log_ptr+1
+       inc RX_LOG_COUNT        ; counted
        bne _rts
        inc RX_LOG_COUNT+1
_rts    rts

; log_clear - RX_LOG empty. clobbers A
log_clear
        lda #<RX_LOG
        sta log_ptr
        lda #>RX_LOG
        sta log_ptr+1
        lda #0
        sta RX_LOG_COUNT
        sta RX_LOG_COUNT+1
        rts

; -----------------------------------------------------------------------------
; idle_wire - a byte's time and more with nothing sent (the transmitter's
; buffer and the wire empty), any byte waiting read. clobbers A, X; Y = 0
; -----------------------------------------------------------------------------
idle_wire
        ldx #0
-       dex                     ; ~1,300 cycles: four byte times
        bne -
        ldy #0
        lda (status_ptr),y
        lsr a
        bcc +
        lda (rx_ptr),y
+       rts

; -----------------------------------------------------------------------------
; stats_clear, stats_add, stats_print - the smallest, largest and average of
; the intervals given (delta): min, max, sum (24 bits), count
; -----------------------------------------------------------------------------
stats_clear
        lda #$ff
        sta stats_min
        sta stats_min+1
        lda #0
        sta stats_max
        sta stats_max+1
        sta stats_sum
        sta stats_sum+1
        sta stats_sum+2
        sta stats_n
        sta stats_n+1
        rts

; stats_add - delta counted in. clobbers A
stats_add
        lda delta               ; smaller than min?
        cmp stats_min
        lda delta+1
        sbc stats_min+1
        bcs +
        lda delta
        sta stats_min
        lda delta+1
        sta stats_min+1
+       lda stats_max           ; larger than max?
        cmp delta
        lda stats_max+1
        sbc delta+1
        bcs +
        lda delta
        sta stats_max
        lda delta+1
        sta stats_max+1
+       clc                     ; the sum
        lda stats_sum
        adc delta
        sta stats_sum
        lda stats_sum+1
        adc delta+1
        sta stats_sum+1
        bcc +
        inc stats_sum+2
+       inc stats_n
        bne +
        inc stats_n+1
+       rts

; stats_print - "MIN a MAX b AVG c (u US)" on one line: cycles, the
; average in microseconds too (a whole screen holds every test's results);
; the average the sum / the count. clobbers A, X, Y
stats_print
        ldx #<text_min
        ldy #>text_min
        jsr print_text
        lda stats_min
        ldx stats_min+1
        jsr print_dec
        ldx #<text_max
        ldy #>text_max
        jsr print_text
        lda stats_max
        ldx stats_max+1
        jsr print_dec
        ldx #<text_avg
        ldy #>text_avg
        jsr print_text
        jsr stats_average
        jsr print_cycles_us
        lda #13
        jmp CHROUT

; stats_average - num = stats_sum / stats_n (by repeated subtraction of a
; shifted count: a 24 / 16-bit division). clobbers A, X
stats_average
        lda #0
        sta num
        sta num+1
        sta div_rem
        sta div_rem+1
        lda stats_sum
        sta div_num
        lda stats_sum+1
        sta div_num+1
        lda stats_sum+2
        sta div_num+2
        ldx #24
-       asl div_num             ; the next bit of the sum into the remainder
        rol div_num+1
        rol div_num+2
        rol div_rem
        rol div_rem+1
        asl num                 ; the quotient on a bit
        rol num+1
        lda div_rem             ; the count fits? subtract it, a 1 bit
        cmp stats_n
        lda div_rem+1
        sbc stats_n+1
        bcc +
        sta div_rem+1
        lda div_rem
        sbc stats_n
        sta div_rem
        inc num
+       dex
        bne -
        rts

; errors_print - "ERRORS n" (wrong bytes, framing errors, overruns), only
; when there were any. clobbers A, X, Y
errors_print
        lda errors
        ora errors+1
        beq +
        ldx #<text_errors
        ldy #>text_errors
        jsr print_text
        lda errors
        ldx errors+1
        jsr print_dec
        lda #13
        jmp CHROUT
+       rts

; -----------------------------------------------------------------------------
; print_cycles_us - num as "c (u US)": the cycles and the microseconds at the
; machine's clock (PAL 985,248 Hz: x 1.015, NTSC 1,022,727 Hz: x 0.978, both
; as num + num x k / 256). clobbers A, X, Y, num
; -----------------------------------------------------------------------------
print_cycles_us
        lda num                 ; the cycles
        ldx num+1
        pha
        txa
        pha
        lda num
        jsr print_dec
        ldx #<text_open
        ldy #>text_open
        jsr print_text
        pla                     ; the microseconds: num x k / 256 (k: PAL 4, NTSC -6)
        sta num+1
        pla
        sta num
        lda num+1               ; num / 64 (PAL: x 4 / 256)
        sta us_add+1
        lda num
        sta us_add
        ldx #6
-       lsr us_add+1
        ror us_add
        dex
        bne -
        lda PAL_FLAG
        beq _ntsc
        clc                     ; PAL: + num / 64
        lda num
        adc us_add
        sta num
        lda num+1
        adc us_add+1
        sta num+1
        jmp _print
_ntsc   lda us_add+1            ; NTSC: - num x 6 / 256 = - (num / 64 + num / 128)
        lsr a                   ; (delta: free while printing) = us_add / 2
        sta delta+1
        lda us_add
        ror a
        sta delta
        clc
        lda us_add
        adc delta
        sta us_add
        lda us_add+1
        adc delta+1
        sta us_add+1
        sec
        lda num
        sbc us_add
        sta num
        lda num+1
        sbc us_add+1
        sta num+1
_print  lda num
        ldx num+1
        jsr print_dec
        ldx #<text_us
        ldy #>text_us
        jmp print_text

; -----------------------------------------------------------------------------
; print_dec - A (low), X (high) as a decimal number, no leading zeros.
; clobbers A, X, Y, num
; -----------------------------------------------------------------------------
print_dec
        sta num
        stx num+1
        lda #0
        sta digit_seen
        ldy #4                  ; 10000, 1000, 100, 10, then the ones
_place  ldx #"0"
_count  lda num                 ; num >= the power? subtract it
        cmp pow_lo,y
        lda num+1
        sbc pow_hi,y
        bcc _digit
        sta num+1
        lda num
        sbc pow_lo,y
        sta num
        inx
        bne _count
_digit  txa
        cmp #"0"
        bne +
        ldx digit_seen          ; (a leading zero: not printed)
        beq _skip
+       jsr CHROUT
        inc digit_seen
_skip   dey
        bpl _place
        lda digit_seen          ; (0 itself)
        bne +
        lda #"0"
        jsr CHROUT
+       rts
pow_lo          .byte <1, <10, <100, <1000, <10000
pow_hi          .byte >1, >10, >100, >1000, >10000

; -----------------------------------------------------------------------------
; print_text - the text at X (low), Y (high), ending at a 0. clobbers A, Y
; -----------------------------------------------------------------------------
print_text
        stx text_ptr
        sty text_ptr+1
        ldy #0
-       lda (text_ptr),y
        beq +
        jsr CHROUT
        iny
        bne -
+       rts

; wait_key - until a key is pressed. clobbers A, X, Y
wait_key
-       jsr GETIN
        beq -
        rts

; -----------------------------------------------------------------------------
; Texts (PETSCII: upper case; 13 = RETURN, 147 = clear screen)
; -----------------------------------------------------------------------------
text_menu       .text 147, "MIDI LATENCY TEST (SIDSYNTH)", 13, 13
                .text "1 SEQUENTIAL  2 PASSPORT", 13
                .text "3 DATEL       4 NAMESOFT", 13
                .text "5 KERBEROS (AS DATEL)", 13, 13
                .text "INTERFACE? ", 0
text_seq        .text 13, "SEQUENTIAL", 0
text_pass       .text 13, "PASSPORT", 0
text_datel      .text 13, "DATEL", 0
text_name       .text 13, "NAMESOFT", 0
text_kerberos   .text 13, "KERBEROS AS DATEL", 0
text_clock      .text ", PAL. TIMES IN CYCLES", 13, 0
text_clock_ntsc .text ", NTSC. TIMES IN CYCLES", 13, 0
text_pace       .text 13, "1 SEND PACING, TAKEN AT ONCE: ", 0
text_period     .text 13, 0
text_cable      .text "CABLE OUT TO IN, THEN A KEY", 13, 0
text_loop       .text "2 LOOPBACK, ONE BYTE", 13, 0
text_message    .text "3 LOOPBACK, 3 BYTES", 13, 0
text_burst      .text "4 LOOPBACK, 64 BYTES", 13, 0
text_per_byte   .text "  A BYTE'S SHARE ", 0
text_none       .text "  NOTHING CAME BACK: CABLE?", 13, 0
text_errors     .text "  ERRORS ", 0
text_min        .text "  MIN ", 0
text_max        .text " MAX ", 0
text_avg        .text " AVG ", 0
text_open       .text " (", 0
text_us         .text "US)", 0
text_again      .text "A KEY: AGAIN", 13, 0
text_absent     .text "NO 6850 ANSWERS HERE: IS THE", 13
                .text "CARTRIDGE IN THIS MODE, ITS MIDI ON?", 13, 0

; -----------------------------------------------------------------------------
; Variables
; -----------------------------------------------------------------------------
stats_min       .word 0         ; the smallest interval
stats_max       .word 0         ;   the largest
stats_sum       .fill 3         ;   their sum (24 bits)
stats_n         .word 0         ;   their count
div_num         .fill 3         ; stats_average: the sum, shifted out
div_rem         .word 0         ;   the remainder
errors          .word 0         ; wrong bytes, framing errors, overruns
run_len         .byte 0         ; test_runs: bytes a run
run_count       .byte 0         ;   runs left
now_hi          .byte 0         ; take_delta: the time's high byte
us_add          .word 0         ; print_cycles_us: num x k / 256
present_status  .byte 0         ; if_present: the status last read
rx_status       .byte 0         ; check_byte: a received byte's status
rx_byte         .byte 0         ;   and the byte
