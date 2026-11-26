; =============================================================================
; SID500 - a 16-channel MIDI sequencer for the C64, named after the Roland MC-500
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
; This program is free software under the GNU General Public License,
; version 3 or (at your option) any later version; see LICENSE.
;
; The fourth program of SidSynth (after SID303, SID808 and SID101), on the
; family's shared core (core/). docs/design.md has the design, docs/plan.md
; the stages. Stage A so far: the player's timer and MIDI out in sync
; (design section 4): the player runs in CIA1 timer A's interrupt, timed to
; the exact sequencer tick at the tempo; MIDI clock jumps the queue.
;
; Build: see build.sh (python tables.py; 64tass ...). PAL timing.
; Memory: BASIC and KERNAL ROMs are banked out ($01 = $35); we own the
; hardware IRQ/NMI vectors at $FFFE/$FFFA.
; =============================================================================

        .cpu "6502"

        .weak                   ; overridable with 64tass -D NAME=value
                                ; (the core's options are in core/options.inc)
TEST_BURST = 0                  ; test builds: n > 0 = the main loop queues a burst of
                                ; n-byte note messages every BURST_EVERY ticks (src/timing.asm)
TEST_TEMPO = 120                ; the tempo at start, BPM
TEST_SWING = 0                  ; the swing at start, 0-15
TEST_EVENTS = 0                 ; 1 = at start write tables.py's test patterns into the pool,
                                ; fill it, then read every pattern back into $A000
                                ; (src/test_events.asm, tools/event_check.py)
TEST_PLAY = 0                   ; n > 0 = play tables.py's test scene n from the start
                                ; (src/test_play.asm, tools/play_check.py)
TEST_LOG_RELEASE = 0            ; with TEST_LOG: 1 = log each tick's release too (LOG_RELEASE)
TEST_TRAP_TICK = 0              ; with TEST_PLAY: n > 0 = track_handle calls trap_start and
TEST_TRAP_TRACK = 0             ; trap_end around track TEST_TRAP_TRACK's tick n (profiling);
                                ; TEST_TRAP_TRACK 255: around the whole tick's rendering
TEST_RENDER_TIMED = 0           ; with TEST_PLAY: 1 = time every render step (render_max ...:
                                ; timing.asm render_timed; it costs ~100 cycles a step)
TEST_PROBE = 0                  ; n > 0 = store the release state at play ticks n..n+15
                                ; (timing.asm probe_tick, at $E000)
TEST_LOG_FROM = 0               ; with TEST_LOG: n > 0 = log nothing before play tick n
TEST_STAMP_FEW = 0              ; with TEST_LOG: 1 = stamp only each burst's first and last
                                ; status bytes ($90, $9F) and the clocks, no ticks: the
                                ; bursts' pace without the stamps' cost (timing_check.py);
                                ; 2 = the ticks, the realtime bytes and one other byte in 8
                                ; (play_check.py: the lag without the stamps' cost);
                                ; 3 = the ticks and the realtime bytes only (clock jitter)
TEST_SLAVE = 0                  ; n > 0 = slave (Clock = MIDI), tables.py's feed n of a
                                ; master's realtime bytes coming into MIDI in through the
                                ; receive interrupt (src/test_slave.asm, tools/slave_check.py)
TEST_SWITCH = 0                 ; with TEST_SLAVE: n > 0 = start as master, and switch Clock
                                ; to MIDI after n main-loop ticks (player_restart)
TEST_FEED_MASTER = 0            ; with TEST_SLAVE: 1 = play as master, the feed a keyboard's
                                ; messages into MIDI in (thru, recording: tools/thru_check.py)
TEST_THRU = 1                   ; Thru at start (tests: 0 = off, thru_check.py's baseline)
TEST_RECORD = 0                 ; n > 0 = a take on track n from the first time the song
                                ; plays (take.asm; tools/record_check.py)
TEST_REC_MODE = 0               ; the Record parameter at start (tests: 1 = Replace)
TEST_REC_QUANT = 0              ; Rec Quantize at start (tests: 1-3)
TEST_REC_END = 0                ; with TEST_RECORD: n > 0 = the take ended from play tick n
                                ; on, as C= R does
TEST_REC_UNDO = 0               ; with TEST_RECORD: n > 0 = C= U (the take undone) from
                                ; play tick n on (tools/record_check.py)
TEST_REC_FROM = 0               ; with TEST_RECORD: n > 0 = the take begun from play tick n on
                                ; (scene_check.py: after a launch)
TEST_REC_STOP = 0               ; with TEST_RECORD: n > 0 = the song stopped at play tick n
                                ; (as SPACE: the take ends with it)
TEST_SCENES = 0                 ; n > 0 = tables.py's scene test n: scenes 2.., their bars,
                                ; signatures, repeats, Song, and launches at play ticks
                                ; (scene.asm scene_test; tools/scene_check.py)
TEST_COUNT = 0                  ; n > 0 = C= R while stopped on track n at the first look:
                                ; the count-in, then the take (count.asm; tools/count_check.py)
TEST_COUNT_BARS = 1             ; the Count-in parameter at start (tests: 0-2)
TEST_COUNT_RESET = 0            ; with TEST_COUNT: 1 = the song taken as away from its start
                                ; (reset first)
TEST_COUNT_CANCEL = 0           ; with TEST_COUNT: n > 0 = C= R again with fewer than n
                                ; ticks of the count left (n < 256)
TEST_REC_REDO = 0               ; with TEST_REC_UNDO: n > 0 = SHIFT+C= U from play tick n on
TEST_ARM = 0                    ; with TEST_SLAVE: n > 0 = C= R stopped as slave on track n at
                                ; the first look (the take armed: locate.asm arm_test)
TEST_ARM_CANCEL = 0             ; with TEST_ARM: 1 = then SPACE (disarmed), 2 = then Clock
                                ; the C64's
TEST_RX_TIME = 0                ; with TEST_FEED_MASTER: 1 = synth_rx_irq's end logged
                                ; (LOG_RX_DONE: its time from the byte's LOG_RX)
TEST_ABORT = 0                  ; tests: 1 = render's loop goes on while the player is held
                                ; (a stop being done), so the stage fills and render_abort
                                ; must abandon the step (tools/transport_check.py)
TEST_CLICK = 0                  ; the metronome at start: 1 SID, 2 MIDI, 3 both (tools/
TEST_CLICK_CHAN = 9             ;   click_check.py; its note's channel - 1: 15 there, the
                                ;   band's drums on 10)
TEST_SIG = 4 - 1                ; every scene's signature at start (tests: another; 4/4)
TEST_LIVE = 0                   ; with TEST_PLAY: 1 = the playing scene's cells changed while
                                ; playing (live.asm test_live: the live switch, play_check.py)
TEST_TEMPO_ALL = 0              ; 1 = at start, what size.asm computes for every Tempo into
                                ; the step grid's table (tools/tempo_check.py)
TEST_FRAMES = 0                 ; 1 = a raster interrupt every frame below the text, at
                                ; frame_mark (src/test_frames.asm, tools/flash_check.py)
TEST_AUTOSTART = TEST_LOG && TEST_KEYS == 0 && TEST_COUNT == 0 ; test builds with a log and
                                ; no key script (core TEST_KEYS): the master plays from start-up
        .endweak
TEST_TAKE       = TEST_RECORD || TEST_COUNT || TEST_ARM ; (tests: a take, the feed
                                ; in the program's RAM)
LIST_CODE       = !TEST_LOG || (TEST_KEYS >= 16 && TEST_KEYS <= 18) ; the event list's and the
                                ; names' code (list.asm, names.asm): in every build but the
                                ; logging test builds whose script doesn't open the list
                                ; (the user, 2026-11-24: their pool, from the program's end to
                                ; the log, needs the room; the hooks then the grid's own)

DISK_CODE       = !TEST_LOG && !TEST_TEMPO_ALL ; the disk (disk.asm): in every build but
                                ; the logging test builds (their pool, from the program's
                                ; end to the log, needs the room) and tempo_check's (its
                                ; test code and the pool at POOL_BASE)
        .weak
DISK_OV_OUT = 0                 ; 1 = the build of the disk overlay (build.sh:
        .endweak                ; --output-section=disk_ov)

MIDI_OUT = 1                    ; MIDI output: the player's notes and clock
KERNAL_ZP_COPY = $f100          ; the KERNAL's zero page at start (for the Disk drive: its
                                ; last device), in the note map's page 1 until it is cleared
SYNTH_TIMER = 1                 ; the player on CIA1 timer A (synth_timer), the core's tick on B
MIDI_URGENT = 1                 ; clock goes out before the notes (midi_send_urgent)
MIDI_RT_IRQ = 1                 ; clock in caught in the receive interrupt (synth_rt_irq)
IRQ_IO_IN = 1                   ; the handlers switch I/O in: tables under I/O (design 3)
MIDI_TX_HOOK = TEST_LOG         ; test builds stamp every byte sent (synth_tx_byte)
PARAM_SYNTH_KEYS = 1            ; the parameter screen's keys to synth_param_key first (SPACE)
SYNTH_SCREEN = 1                ; the song screen owns the screen and keys (src/song.asm)
RASTER_SAFE = 1                 ; rows drawn only when the beam won't pass them (no flashing)
MIDI_RX_IRQ = 1                 ; every byte from MIDI in to synth_rx_irq in the receive
                                ; interrupt (record.asm: thru, recording's stamps)
MATH_ENV = 0                    ; no envelopes: no env_decay (the size pass)
START_COPY = 1                  ; start-up's code run once under the KERNAL (synth_start_copy,
                                ; INIT_CODE; the size pass)
MATH_SHIFT_MUL = 1              ; mul8 without the square tables (1 KB of the program's room;
                                ; only parameter scaling and the parameter screen multiply)
TEST_RX_FEED = TEST_SLAVE != 0 || TEST_FRAMES ; test builds: the raster interrupt feeds
                                ; MIDI in (or marks each frame)
        .cerror TEST_SLAVE && TEST_FRAMES, "TEST_FRAMES and TEST_SLAVE both use the raster interrupt"
        .cerror TEST_SLAVE && !TEST_LOG, "TEST_SLAVE logs what it feeds: needs TEST_LOG"

        .include "core/options.inc"
        .include "core/c64.inc"

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
; TICK_LATCH and the tempo tables come from tables.inc (included at the end)

TICKS_PER_QUARTER = 48          ; the sequencer's resolution (design 3)
TICKS_PER_CLOCK = 2             ; MIDI clock is 24 a quarter: every second tick
BPM_LOWEST      = 40            ; Tempo parameter 0 = 40 BPM ...
BPM_HIGHEST     = 240           ;   ... 200 = 240 BPM (the family's top, the user; tables.py)

; MIDI realtime bytes
MIDI_CLOCK      = $f8
MIDI_START      = $fa
MIDI_CONTINUE   = $fb
MIDI_STOP       = $fc

; parameter indices (order = order on screen)
P_TEMPO         = 0             ; BPM - BPM_LOWEST
P_SWING         = 1             ; 0-15: an odd 16th delayed by swing/32 of a 16th
P_CLOCK         = 2             ; 0 internal (master), 1 MIDI (slave)
P_METRONOME     = 3             ; 0 off, 1 SID, 2 MIDI, 3 both (click.asm; C= K too)
P_CLICK_CHAN    = 4             ;   the note's channel, 0-15 (1-16)
P_CLICK_BEAT    = 5             ;   its note on a beat
P_CLICK_BAR     = 6             ;   and on a bar's first
P_THRU          = 7             ; MIDI in passed on to the record track's channel (record.asm)
P_RECORD        = 8             ; 0 overdub, 1 replace (stage D: the take)
P_REC_QUANT     = 9             ; 0 off, 1 16th, 2 8th, 3 16th triplet: at the take's merge
P_COUNT_IN      = 10            ; 0-2 bars before a take started from stop
P_CHANNEL       = 11
P_MIDIIF        = 12
P_PADDLES       = 13
P_DRIVE         = 14            ; the disk's drive, 0..8 = 8..16 (not saved: the last;
NUM_PARAMS      = DISK_CODE ? 15 : 14 ; only with the disk: the logging test builds'
                                ; zero page is full)
PAD_DEFAULT_X   = P_TEMPO       ; paddle X at start
PAD_DEFAULT_Y   = P_TEMPO       ; paddle Y at start

; RAM the core leaves to the synth ($C140-$C1FF)
env_lo          = $c140         ; (core/math.asm's envelopes: SID500 has none yet)
env_hi          = $c141
                                ; ($C150-: src/transport.asm's variables)

        .include "core/framework.asm"

; the main loop's most used variables (the size pass, 2026-11-25: a byte
; less at each use) in the zero page after the core's own (zp_end, $E0 in
; the release); the modules put them in section zp_hot. Not cleared at
; start, as the RAM they were in. Test builds whose own zero-page variables
; leave no room: in the program, before program_end, as before.
ZP_HOT_BYTES    = 36            ; (checked below)
ZP_HOT          = zp_end <= $100 - ZP_HOT_BYTES
.if ZP_HOT
        .virtual zp_end
zp_hot_start
        .dsection zp_hot
zp_hot_end
        .endv
.endif

; -----------------------------------------------------------------------------
; twice - (segment; \1 = a routine's name) a routine run only at start and
; after a song is loaded: its body (macro \1_body) in the start-up code as
; \1_at_start and, with the disk, in the disk overlay as \1 (its bytes
; not the program's: the size pass; disk.asm puts that copy after the
; overlay's id, which must come first)
; -----------------------------------------------------------------------------
twice   .segment
.if DISK_CODE
        .section init_code
\1_at_start #\1_body
        .send
.else
        .section init_code
\1      #\1_body
        .send
\1_at_start = \1
.endif
        .endsegment

; -----------------------------------------------------------------------------
; synth_start_copy - (core start, START_COPY: first, interrupts off) the
; start-up code (section init_code: the core's start_rest and init_vars,
; synth_init and the routines run only at start) from its image after the
; program to INIT_CODE, under the KERNAL in the step grid's table, which
; nothing uses yet: its bytes are not the program's (the size pass,
; 2026-11-25). Whole pages: a little past its end, harmless. clobbers A, Y
; -----------------------------------------------------------------------------
synth_start_copy
        ldy #0
-       .for _p := 0, _p < INIT_PAGES, _p += 1
        lda init_image + _p * $100,y
        sta INIT_CODE + _p * $100,y
        .endfor
        iny
        bne -
        rts

; -----------------------------------------------------------------------------
; synth_init - hook called once at start (from INIT_CODE), after core
; init_vars, interrupts off: end_stream, the images copied, the test log,
; the SID silent, the player's timer.
; -----------------------------------------------------------------------------
        .section init_code
synth_init
        ldx #BLOCK_DATA-1       ; events.asm's end_stream: end markers linked to itself
        lda #TIME_END
-       sta end_stream,x
        dex
        bpl -
        lda #<end_stream
        sta end_stream+BLOCK_DATA
        lda #>end_stream
        sta end_stream+BLOCK_DATA+1
.if HI3_USED
        ldy #0                  ; HI3_CODE from its image (whole pages: harmless)
-       .for _p := 0, _p < 4, _p += 1
        lda hi3_image + _p * $100,y
        sta HI3_CODE + _p * $100,y
        .endfor
        iny
        bne -
.endif
        jsr disk_copy_all       ; the tables under I/O, the code under the KERNAL (first:
                                ; nothing has used the RAM their images are in yet); the
                                ; Disk drive (disk.asm)
.if TEST_SLAVE && !(TEST_TAKE)
        jsr feed_copy           ; (tests: the feed into the step grid's table)
.endif
.if TEST_LOG && !TEST_PLAY
        jsr log_init
.endif
        jsr pool_init_at_start  ; no patterns
        jsr tracks_init         ; the tracks' channels and order, nothing playing
        jsr song_init_at_start  ; the song screen's cursor
        jsr transport_init      ; no stop under way
        jsr live_init           ; no live switch under way
        jsr click_init          ; the metronome's voice, silent
        jsr record_init         ; nothing sounding through thru
        jsr count_init          ; no take, no count-in (count.asm, then take.asm rec_init)
        jsr grid_init           ; the song screen's rows
        jsr clock_init          ; the title's bar.beat and m:ss (clock.asm)
.if TEST_EVENTS
        jsr test_events
.endif
.if TEST_PLAY
        jsr test_play_load      ; a test scene's patterns into the pool
.if TEST_LOG
        jsr log_init            ; (after: the patterns' streams were in the log's RAM)
.endif
.endif
.if TEST_SLAVE
        jsr test_slave_init     ; a master's bytes fed into MIDI in
.endif
.if TEST_FRAMES
        jsr test_frames_init    ; a mark every frame
.endif
.if TEST_TEMPO_ALL
        jsr tempo_dump          ; (size.asm: the tempo at every Tempo)
.endif
        lda #0                  ; voices 1 and 2 silent (not voice 3, the filter and the
        ldx #SID_V2_SR-$d400    ; volume: click_init set them; clearing them to $D418
-       sta $d400,x             ; left the metronome silent from stage C on)
        dex
        bpl -
        jmp player_init
        .send

        .include "core/midi.asm"
        .include "core/params.asm"
        .include "src/timing.asm"
        .include "src/pool.asm"
        .include "src/events.asm"
        .include "src/player.asm"
        .include "src/render.asm"
        .include "src/slave.asm"
        .include "src/transport.asm"
        .include "src/song.asm"
        .include "src/live.asm"
        .include "src/grid.asm"
        .include "src/edit.asm"
        .include "src/undo.asm"
        .include "src/click.asm"
        .include "src/record.asm"
        .include "src/take.asm"
        .include "src/count.asm"
        .include "src/scene.asm"
        .include "src/size.asm"
        .include "src/list.asm"
        .include "src/names.asm"
        .include "src/locate.asm"
        .include "src/disk.asm"
        .include "src/clock.asm"
.if TEST_PLAY
        .include "src/test_play.asm"
.endif
.if TEST_EVENTS
        .include "src/test_events.asm"
.endif
.if TEST_SLAVE
        .include "src/test_slave.asm"
.endif
.if TEST_FRAMES
        .include "src/test_frames.asm"
.endif
        .include "core/math.asm"
        .include "core/paddles.asm"
        .include "core/keyboard.asm"
        .include "src/keymap.asm"
        .include "src/hooks.asm"
        .include "core/screen.asm"
        .include "src/params.asm"
        .include "core/test_feed.asm"

IO_TABLES       = $d000
RAM_ALL         = $34           ; $01: RAM everywhere (I/O out too)
IO_PAGES        = (io_tables_end - IO_TABLES + $ff) >> 8
; -----------------------------------------------------------------------------
; io_copy - (synth_init, first; interrupts off) the tables' image from
; after the program to IO_TABLES, under I/O ($01 = RAM_ALL while copying:
; a write there with I/O in would go to the chips).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
io_copy_body .macro             ; (the routine: in late_code with the disk, see below)
        lda #RAM_ALL
        sta $01
        ldx #IO_PAGES           ; (whole pages: a little past the image's end, harmless)
        ldy #0
_page
_from = * + 1
-       lda io_image,y
_to = * + 1
        sta IO_TABLES,y
        iny
        bne -
        inc _from+1
        inc _to+1
        dex
        bne _page
        lda #RAM_IO
        sta $01
        rts

        .endm
.if DISK_CODE
        .enc "none"
ov_name .text "sid500 disk"     ; (disk.asm ov_load: 64tass -a, plain PETSCII, as DOS wants)
OV_NAME_LEN = * - ov_name
.endif
        .section init_code
io_copy #io_copy_body
        .send

; =============================================================================
; Generated tables (tables.py): TICK_LATCH, the multiply tables, the tempo
; =============================================================================
        .include "tables.inc"
        .dsection late_code     ; (code added late, after the tables: nothing before moves)
        .dsection late_tests    ; (tests' code added later still: late_code doesn't move)

        .include "core/test_keys.asm"
.if TEST_KEYS
        .include "src/test_scripts.asm"
.endif
.if !TEST_LOG
        .dsection play_data     ; (TEST_PLAY: the test scene's streams)
.endif
.if TEST_TAKE
        .dsection feed_data     ; (TEST_SLAVE with TEST_RECORD: the feed; the step grid's
.endif                          ; table is the take's)
.if !ZP_HOT
zp_hot_start                    ; (the hot variables: no room in the zero page)
        .dsection zp_hot
zp_hot_end
.endif
        .cerror zp_hot_end - zp_hot_start != ZP_HOT_BYTES, "ZP_HOT_BYTES: the hot variables' size"
program_end
        .cerror program_end > POOL_START, "program runs into the note pool: ", program_end

; the start-up code (synth_init, init_run): assembled at INIT_CODE, under
; the KERNAL at the step grid's table's end (unused until a pattern is
; opened), stored here, copied there first at start and run once
INIT_PAGES      = 3
HI3_USED        = hi3_image_end != hi3_image ; (the builds without the event list: none)
INIT_CODE       = (HI3_USED ? HI3_CODE : GRID_STEP_LO) - INIT_PAGES * $100 ; (the step grid's
                                ; table's end, or HI3_CODE's room when it holds nothing)
init_image
        .logical INIT_CODE
        .dsection init_code
init_code_end
        .endlogical
        .cerror init_code_end > INIT_CODE + INIT_PAGES * $100, "the start-up code is over INIT_PAGES pages"
        .cerror TEST_TEMPO_ALL && TEMPO_DUMP + 4 * TEMPO_COUNT + 1 > INIT_CODE, "tempo_dump runs into the start-up code"

; code under the KERNAL at HI3_CODE ($E800, the size pass: the 1 KB the
; step grid's table gave up): the event list's (list.asm), used only on
; the step grid; run with the ROMs out as main RAM; stored here, copied at
; start by synth_init. The disk overlay loads over it: disk.asm hi3_save
; keeps it in the note map meanwhile, hi3_in puts it back before the grid
; opens or the song plays.
hi3_image
        .logical HI3_CODE
        .dsection hi3_code
hi3_code_end
        .endlogical
hi3_image_end
        .cerror hi3_code_end > GRID_STEP_LO, "the code at HI3_CODE runs into the step index"
        .cerror hi3_image_end > $c000, "the image of HI3_CODE runs into the song data"

; the tables under I/O (design 3): assembled at IO_TABLES, stored here
; after the program (in the pool's space, or the log's), copied under I/O
; at start by io_copy before anything else uses that RAM
io_image
        .logical IO_TABLES
        .dsection io_data
io_tables_end
        .endlogical
io_image_end
        .cerror io_tables_end > $e000, "the tables under I/O run past it"
        .cerror io_image_end > $c000, "the tables' image runs into the song data"

; code under the KERNAL at HI_CODE (2026-11-24, the size pass: the RAM
; free after the snapshots and TICK_MUSIC, up to the vectors), run with
; $01 = $35 as main RAM; stored here, copied at start before the pool is
; cleared (list.asm io_copy_all)
HI_CODE         = $ff80
hi_image
        .logical HI_CODE
        .dsection hi_code
hi_code_end
        .endlogical
hi_image_end
        .cerror hi_code_end > $fffa, "the code under the KERNAL runs into the vectors"
        .cerror HI_CODE < SNAP_MUSIC_2 + 2 || HI_CODE < TICK_MUSIC_HI + 16, "HI_CODE over the snapshots"
        .cerror hi_image_end > $c000, "the image of the code under the KERNAL runs into the song data"

; code under the KERNAL at HI2_CODE (stage G's disk: disk.asm disk_in,
; disk_out): the gap in the wheel's arrays after CHANNEL_FIRST, run with
; $01 = $35; stored here, copied at start (disk.asm disk_copy_all)
.if DISK_CODE
HI2_CODE        = CHANNEL_FIRST + NUM_CHANNELS
hi2_image
        .logical HI2_CODE
        .dsection hi2_code
hi2_code_end
        .endlogical
hi2_image_end
        .cerror hi2_code_end > OFF_SLOT, "the code in the wheel's gap runs into OFF_SLOT"
        .cerror hi2_image_end > $c000, "the image of the code in the wheel's gap runs into the song data"
.endif

; code in low RAM at LO_CODE (2026-11-24, the size pass: the tape buffer
; and the bytes after it, which the KERNAL's disk routines leave alone: its
; file tables are at $0259-$02A6, its vectors at $0300-$0333), run as main
; RAM; stored here, copied at start (list.asm io_copy_all)
LO_CODE         = $0334
lo_image
        .logical LO_CODE
        .dsection lo_code
lo_code_end
        .endlogical
lo_image_end
        .cerror lo_code_end > SCREEN, "the code in low RAM runs into the screen"
        .cerror lo_image_end > $c000, "the image of the code in low RAM runs into the song data"
LO2_CODE        = $02a7         ; and after the KERNAL's variables, up to its vectors at $0300
lo2_image
        .logical LO2_CODE
        .dsection lo2_code
lo2_code_end
        .endlogical
lo2_image_end
        .cerror lo2_code_end > $0300, "the code at $02A7 runs into the KERNAL's vectors"
        .cerror lo2_image_end > $c000, "the image of the code at $02A7 runs into the song data"
LO3_CODE        = $0200         ; and BASIC's input buffer (BASIC is out), up to the
lo3_image                       ; KERNAL's file tables at $0259
        .logical LO3_CODE
        .dsection lo3_code
lo3_code_end
        .endlogical
lo3_image_end
        .cerror lo3_code_end > $0259, "the code at $0200 runs into the KERNAL's file tables"
        .cerror lo3_image_end > $c000, "the image of the code at $0200 runs into the song data"
.if TEST_SLAVE && !(TEST_TAKE)
; the slave tests' feed (not recording): in the step grid's table under the
; KERNAL, unused there (under I/O is the take's code now), stored after the
; tables' image and copied at start (test_slave.asm feed_copy)
FEED_RAM        = GRID_TABLE
feed_image
        .logical FEED_RAM
        .dsection feed_data
feed_ram_end
        .endlogical
feed_image_end
        .cerror (feed_ram_end + $ff & $ff00) > INIT_CODE, "the feed (whole pages) runs into the start-up code"
        .cerror feed_image_end > $c000, "the feed's image runs into the song data"
.endif
.if DISK_CODE
; the disk overlay (disk.asm): its own file, built with DISK_OV_OUT (build.sh);
; in the program's build only its addresses
.if DISK_OV_OUT
        * = DISK_OV
        .dsection disk_ov
.else
        .virtual DISK_OV
        .dsection disk_ov
        .endv
.endif
.endif
.if TEST_LOG
; TEST_LOG builds: the test scene's streams (scene 2's 3.4 KB) at the top of
; the log's RAM, copied into the pool at start-up before the log is cleared
; (the program would run into the pool)
PLAY_DATA       = $a800
        * = PLAY_DATA
        .dsection play_data
play_data_end
        .cerror play_data_end > LOG_END, "the test scene's streams run past the log"
.endif
