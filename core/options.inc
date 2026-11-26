; core/options.inc - build options the core reads, with their defaults
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Each is a weak default: set it with 64tass -D NAME=value, or with a plain
; (not .weak) definition in the synth's main file, which overrides it. A synth
; must not define these as .weak itself (64tass allows only one weak
; definition per name).

        .weak
TEST_MIDI = 0                   ; 1 = feed a built-in MIDI test pattern, 2 = the cutoff-sweep pattern
TEST_KEYS = 0                   ; 1 = play a scripted key sequence instead of reading the keyboard
TEST_PADDLES = 0                ; 1 = paddle X turns by itself (with TEST_KEYS=3: paddle learn test)
MIDI_IF_DEFAULT = 3             ; MIDI interface at start: 0 off, 1 Sequential, 2 Passport, 3 Datel, 4 Namesoft
BUILD = 0                       ; build number in the title row (build.sh: git commit count)
TICK_HZ = 250                   ; synth tick rate, Hz; a multiple of 62.5 (tables.py's tick_latch must match)
SYNTH_SCREEN = 0                ; 1 = the synth can own the screen and keys (synth_draw_step, synth_key)
MIDI_REALTIME = 0               ; 1 = realtime bytes ($F8-$FF: clock, start, stop) go to synth_realtime
MIDI_OUT = 0                    ; 1 = MIDI output: midi_send queues bytes, the ACIA's interrupt sends them
KERNAL_ZP_COPY = 0              ; address of a 256-byte area: start copies the KERNAL's zero page
                                ; ($02-$FF, at the same offsets) there first, for KERNAL calls later
STATUS_ROW = 19                 ; parameter screen: the status row; the parameters are on rows
                                ; 1..STATUS_ROW-1, the help rows from STATUS_ROW+1
OMNI_SKIP_DRUMS = 0             ; 1 = in omni, notes on channel 10 (the GM drum channel) are ignored
PARAM_PAGE2 = 0                 ; parameter screen in two pages: the first parameter of the second
                                ; page (0 = one page). The page shown is the one holding the
                                ; selected parameter; the synth supplies page_names (2 x PAGE_NAME_WIDTH)
                                ; and page_hints (2 x 40: the row under each page's last parameter)
PARAM_NAMES_LONG = 0            ; 1 = more than 21 parameters (up to 42): their 12-character names
                                ; take more than 256 bytes (draw_param_row reads them in two parts)
RASTER_SAFE = 0                 ; 1 = a screen row is drawn only when the raster beam won't pass it
                                ; meanwhile (row_safe), so nothing drawn and then corrected flashes
SEQ_REALTIME_OWN = 0            ; 1 = with core/sequencer.asm: its realtime handler is named
                                ; seq_realtime, and the synth provides synth_realtime (seeing every
                                ; realtime byte, e.g. clocks with the sequencer stopped), which
                                ; passes the bytes on to seq_realtime
MIDI_PROGRAM = 0                ; 1 = program change ($Cx) on the synth's channel goes to
                                ; synth_program (A = the program, 0..127)
PATTERN_CC = 0                  ; a controller number (SidSynth: 85): that controller on the
                                ; synth's channel (not in omni) goes to synth_pattern (A = the
                                ; value) before learn and cc_map, so learn can't take it; 0 = none
MIDI_SYSTEM = 0                 ; 1 = song position ($F2) goes to synth_song_position (A = LSB,
                                ; X = MSB, 7 bits each) and song select ($F3) to
                                ; synth_song_select (A = the song); without it they are dropped
TEST_CHANNEL = 0                ; test builds: the MIDI channel at start (0 = omni), for the
                                ; synth's param_default
PARAM_SYNTH_KEYS = 0            ; 1 = on the core's parameter screen every key event goes to the
                                ; synth's synth_param_key first (A = key code, want_press 1 =
                                ; pressed, 0 = released); carry set = used, the core skips it
MIDI_SYSEX = 0                  ; 1 = SysEx dumps (core/sysex.asm; needs MIDI_SYSTEM and MIDI_OUT):
                                ; the synth's files sent and received over MIDI, synth_sysex_request,
                                ; synth_sysex_dump, synth_sysex_sent
SYSEX_SYNTH = 0                 ; with MIDI_SYSEX: the synth's ID in the messages (SidSynth: 1
                                ; SID303, 2 SID808, 3 SID101)
SYSEX_RAM = $e000               ; with MIDI_SYSEX: a received dump is staged here (RAM under the
SYSEX_MAX = $1000               ; KERNAL), at most SYSEX_MAX bytes (whole pages)
SYSEX_UNDER_IO = 0              ; with MIDI_SYSEX: 1 = the staging may run under the I/O chips
                                ; ($D000-$DFFF): each byte is stored and read with I/O banked out
TEST_SYSEX = 0                  ; with MIDI_SYSEX, test builds, bits: 1 = feed the synth's
                                ; test_sysex_data (a length word, then MIDI bytes) into MIDI in,
                                ; 2 = keep the SysEx bytes sent at SYSEX_RAM, 4 = what is sent
                                ; goes into MIDI in (the synth takes its own dump)
TEST_LOG = 0                    ; 1 = test build that logs to RAM (the synth's own logs; with
                                ; core/sequencer.asm, MIDI out bytes go to the synth's log_out)
SYNTH_TIMER = 0                 ; 1 = the synth tick runs on CIA1 timer B, and timer A's
                                ; interrupt goes to the synth's synth_timer (which sets timer
                                ; A up itself). Timer A, as old 6526 CIAs can lose timer B's
                                ; interrupt when the ICR is read a cycle before it (SID500)
MIDI_URGENT = 0                 ; with MIDI_OUT: 1 = a small queue of realtime bytes (clock,
                                ; start, stop) that the transmit handlers send before the ring:
                                ; midi_send_urgent, callable from interrupts (SID500)
MIDI_RT_IRQ = 0                 ; 1 = realtime bytes ($F8-$FF) go to synth_rt_irq from the
                                ; receive interrupt as they arrive, instead of into the ring
IRQ_IO_IN = 0                   ; 1 = the IRQ and NMI handlers switch I/O in on entry ($01 =
                                ; RAM_IO) and put $01 back on exit: the program may read the
                                ; RAM under I/O with interrupts on
MIDI_TX_HOOK = 0                ; with MIDI_OUT, test builds: 1 = the transmit handlers call
                                ; synth_tx_byte with each byte just before it is written to
                                ; the ACIA (A = the byte), to stamp it with its real time
TEST_RX_FEED = 0                ; test builds, IRQ: 1 = the VIC's raster interrupt stands in for
                                ; a MIDI byte received: irq_handler calls the synth's
                                ; test_rx_feed (carry set = A is a byte) and the byte takes the
                                ; ACIA byte's path (synth_rt_irq or the ring) (SID500)
MIDI_POLL_SCAN = 0               ; 1 = midi_process also between the scan's pieces (after
                                ; the paddles, after the keyboard): a note waits less behind
                                ; them (SID303's worst 7.4 -> 4.7 ms, SID101's 5.8 -> 4.1 ms:
                                ; SID500 docs/latency.md, tools/synth_latency.py)
TEST_RX_NOTES = 0               ; test builds, with TEST_RX_FEED: 1 = the core's own
                                ; test_rx_feed (test_feed.asm): a note on and its note off
                                ; through the receive interrupt, the bytes a wire's byte apart,
                                ; at varying places in the frame, a marker written to SID
                                ; register $1F as each message's last byte comes in (latency
                                ; measured from headless VICE's dump of the SID's writes)
TEST_RX_CHAN = 0                ;   its channel, 0-15
TEST_RX_NOTE = 60               ;   its note
TEST_RX_NOTE2 = TEST_RX_NOTE + 7 ;  every other note on (a pitch to write each time)
TEST_RX_VEL = 100               ;   its velocity
TEST_RX_FRAMES = 15             ;   frames from a message to the next (on, off, on ...)
MATH_ENV = 1                    ; 0 = no env_decay (core/math.asm) and none of its zero-page
                                ; variables: a synth with no envelopes of its own
START_COPY = 0                  ; 1 = start-up's code run once from where the synth puts it:
                                ; start calls synth_start_copy first (the synth copies its
                                ; section init_code there), then jumps to the rest of start
                                ; (start_rest) and init_vars, both in section init_code;
                                ; start_rest ends with a jump to main_loop
MATH_SHIFT_MUL = 0              ; 1 = mul8 by shifts and adds (~150 cycles, no tables) instead
                                ; of quarter squares (~45 cycles, sq_lo/sq_hi: 1 KB the synth
                                ; then needn't have) (SID500: its program's room)
MIDI_RX_IRQ = 0                 ; 1 = every byte received (but the realtime ones with
                                ; MIDI_RT_IRQ) goes into the ring as before, then to
                                ; synth_rx_irq in the receive interrupt (IRQ or NMI) (SID500:
                                ; thru and recording's stamps, however busy the main loop)
        .endweak
