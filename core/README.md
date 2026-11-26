# SID synth core

The shared base of SID303, SID808 and SID101: a C64 program frame for SID
instruments played from MIDI, the C64 keyboard and paddles, with a parameter
screen. It is written in 64tass, needs an 8580 SID and runs on PAL.

A synth supplies the sound (notes, its 250 Hz engine), its parameter list,
its key map and a few hooks. The core does everything else:

| File | What |
|---|---|
| `options.inc` | build options the core reads (weak defaults, set with `-D`): `TEST_MIDI`, `TEST_KEYS`, `TEST_PADDLES`, `MIDI_IF_DEFAULT` (3 = Datel), `BUILD`, `TICK_HZ` (synth tick, 250 Hz), `SYNTH_SCREEN` (the synth can own the screen and keys), `MIDI_REALTIME` (realtime bytes go to the synth), `MIDI_OUT` (MIDI output: `midi_send`), `KERNAL_ZP_COPY` (start keeps the KERNAL's zero page for KERNAL calls), `STATUS_ROW` (the parameter screen's status row, 19; the help rows follow it), `OMNI_SKIP_DRUMS` (in omni, notes on channel 10 are ignored, so a drum machine on the same MIDI line doesn't play the synth), `PARAM_PAGE2` (the parameter screen in two pages, the second from this parameter; the page holding the selected parameter is shown, named in the title row; 0 = one page), `PARAM_NAMES_LONG` (more than 21 parameters, up to 42: their names take more than 256 bytes, so `draw_param_row` reads them in two parts; without it more than 21 is a build error), `RASTER_SAFE` (a screen row is drawn only when the raster beam won't pass it meanwhile, so text drawn and then corrected can't flash; `row_safe`), `SEQ_REALTIME_OWN` (with `sequencer.asm`: the synth provides `synth_realtime` and passes the bytes on to the sequencer's `seq_realtime`), `MIDI_PROGRAM` (program change on the synth's channel goes to `synth_program`), `PARAM_SYNTH_KEYS` (on the parameter screen every key event goes to the synth's `synth_param_key` first), `PATTERN_CC` (a controller number, SidSynth's 85: on the synth's channel, not in omni, it goes to `synth_pattern` before learn and the controller map; 0 = none), `MIDI_SYSTEM` (song position and song select go to `synth_song_position` and `synth_song_select`), `MIDI_SYSEX` (SysEx dumps of the synth's files: `sysex.asm`; with `SYSEX_SYNTH`, the synth's ID, and `SYSEX_RAM`/`SYSEX_MAX`, the staging area), `TEST_SYSEX` (test builds: a dump fed into MIDI in, or what is sent kept at `SYSEX_RAM`), `TEST_CHANNEL` (test builds: the MIDI channel at start, for the synth's `param_default`), `TEST_LOG` (a test build that logs to RAM: the synth's logs, and with the sequencer its MIDI out through `log_out`), and for SID500's timing (see "Timing options" below): `SYNTH_TIMER`, `MIDI_URGENT`, `MIDI_RT_IRQ`, `IRQ_IO_IN`, `MIDI_TX_HOOK`, `TEST_RX_FEED`; `MATH_SHIFT_MUL` (`mul8` by shifts and adds, ~150 cycles, without the 1 KB of square tables); `MIDI_RX_IRQ` (every byte received, but realtime ones with `MIDI_RT_IRQ`, to `synth_rx_irq` in the receive interrupt, then into the ring); `MATH_ENV` (0 = no `env_decay` and none of its zero-page variables, for a synth without envelopes); and `START_COPY` (start-up's code run once from where the synth puts it: `start` calls the synth's `synth_start_copy` first, which copies the synth's section `init_code` into place, then jumps to `start_rest`; the rest of `start` and `init_vars` are in that section, `start_rest` ends with a jump to `main_loop`); `MIDI_POLL_SCAN` (`midi_process` also between the scan's pieces, after the paddles and after the keyboard: a note waits less behind them); `TEST_RX_NOTES` (test builds, with `TEST_RX_FEED`: a note on and off fed through the receive interrupt, a marker in SID register $1F as each message's last byte comes in: SID500's `tools/synth_latency.py`) |
| `c64.inc` | C64 hardware registers and the 6850 ACIA values |
| `framework.asm` | zero page block, RAM map, BASIC stub, start-up, main loop, IRQ/NMI handlers, `init_vars` |
| `midi.asm` | MIDI input through a 6850 ACIA cartridge (Sequential, Passport, Datel, Namesoft): ring buffer, parser with running status, channel filter, pitch bend into `bend`; with `MIDI_OUT`, output: `midi_send` (A = byte, main loop only) queues into a ring at $C300 that the IRQ/NMI handler sends with the ACIA's transmit interrupt |
| `params.asm` | parameter system: MIDI controllers and learn, `param_set_v` (0..255 scaled onto a parameter), `param_changed` |
| `math.asm` | `mul8` (8x8 multiply by quarter squares), `env_decay` (exponential envelope step) |
| `paddles.asm` | paddles with soft takeover and paddle learn |
| `keyboard.asm` | matrix scan, key events, auto-repeat, the F-key commands |
| `screen.asm` | parameter list with bars, choice names, P and CC columns, learn prompt |
| `sequencer.asm` | optional: a monophonic step sequencer (64 patterns of 16 steps with rest, note, tie, accent and slide; tempo and swing, songs with repeats and transpose, MIDI clock in and out, the steps as MIDI notes out), from SID303. See "The sequencer" below |
| `sysex.asm` | with `MIDI_SYSEX` (included by `midi.asm`): the synth's files as SysEx dumps, sent and received. See "SysEx dumps" below |
| `sysex.py` | the PC side of the dumps: fetch a synth's file, send one back (mido) |
| `test_feed.asm`, `test_keys.asm` | test builds: a MIDI byte pattern fed to the parser, scripted keys and paddles |
| `tables_core.py` | helpers for the synth's `tables.py`, plus the tick timer value (`tick_latch(hz)`), SID frequencies and multiply tables; `seq_tables` and the step helpers for `sequencer.asm` |

## Including it

The synth's main file includes, in this order:

```
        .include "core/options.inc"
        .include "core/c64.inc"
        ; the synth's constants (parameter indices and the like)
        .include "core/framework.asm"
        ; synth_init (and anything else that should come early)
        .include "core/midi.asm"
        .include "core/params.asm"
        ; the synth's notes and engine
        .include "core/sequencer.asm"   ; optional, right after the engine
        .include "core/math.asm"
        .include "core/paddles.asm"
        .include "core/keyboard.asm"
        ; the synth's key map and hooks
        .include "core/screen.asm"
        ; the synth's parameter tables and texts
        .include "core/test_feed.asm"
        .include "tables.inc"
        .include "core/test_keys.asm"
        ; the synth's test scripts
program_end
        .cerror program_end > rx_buffer, "program runs into the buffers at $C000"
```

Each module declares its own zero-page variables in a `.section zp` block;
`framework.asm` places them all with `.dsection zp`. A synth declares its own
variables the same way.

## What a synth provides

`python tools/module_deps.py --contract` (in SID303) lists these from the source.

**Hooks (routines)**

| Name | Called | Does |
|---|---|---|
| `synth_init` | once at start, after `init_vars` | the synth's own state, SID setup |
| `synth_start_copy` | (`START_COPY` only) once, first in `start`, interrupts off, `$01` = `RAM_IO` | the section `init_code` (with `start_rest` and `init_vars`) copied to where it runs |
| `synth_tick` | 250 times a second (CIA1 timer) | the sound engine |
| `note_on` | MIDI note on, note key pressed | A = MIDI note, X = velocity 1..127 |
| `note_off` | MIDI note off, note key released | A = MIDI note |
| `all_notes_off` | F8, RUN/STOP, CC 120/123, MIDI channel changed | silence |
| `synth_param_changed` | after the core's own `param_changed` checks | side effects; Y = the parameter |
| `synth_command` | F7 (SHIFT+F7 = F8 is all notes off) | the synth's own key command |
| `synth_draw_status` | for the status row, unless in learn mode | draw the row; `ptr` points at it |
| `synth_draw_step` | only with `SYNTH_SCREEN = 1`: instead of the core's screen drawing while `screen_owner` is nonzero | draw a little of the synth's own screen |
| `synth_realtime` | only with `MIDI_REALTIME = 1`: each MIDI realtime byte, from the main loop's `midi_process` | A = the byte ($F8 clock, $FA start, $FB continue, $FC stop, ...); clobbers what it likes but the ring buffer's `rx_tail` |
| `synth_program` | only with `MIDI_PROGRAM = 1`: a program change on the synth's channel (or any, in omni), from `midi_process` | A = the program, 0..127 |
| `synth_pattern` | only with `PATTERN_CC`: that controller on the synth's channel (never in omni), from `midi_process` | A = the value, 0..127 |
| `synth_song_position` | only with `MIDI_SYSTEM = 1`: a song position pointer ($F2), from `midi_process` | A = LSB, X = MSB (7 bits each): MIDI beats (16ths) from the start |
| `synth_song_select` | only with `MIDI_SYSTEM = 1`: a song select ($F3) | A = the song, 0..127 |
| `synth_sysex_request` | only with `MIDI_SYSEX`: a whole request for the synth, from `midi_process` | A = the kind; the synth sends it with `sysex_send` (unless `sysex_busy`) |
| `synth_sysex_begin` | only with `MIDI_SYSEX`: a dump for the synth begins (its header is in) | A = the kind; the synth goes quiet: no note may sound on, its ticks are skipped while the data comes |
| `synth_sysex_dump` | only with `MIDI_SYSEX`: a dump for the synth has ended (F7) | A = the kind; carry clear = whole (`sysex_len` bytes at `SYSEX_RAM`: the synth checks and loads them, `sysex_unload` helps), set = bad (a byte lost, too long) |
| `synth_sysex_sent` | only with `MIDI_SYSEX`: a dump's last byte is queued | |
| `synth_param_key` | only with `PARAM_SYNTH_KEYS = 1`: every key event while the core's parameter screen is shown, before the core acts on it | A = key code (column*8 + row), `want_press` 1 = pressed, 0 = released; return carry set if used (the core then skips the key), clear to let the core have it |
| `synth_timer` | only with `SYNTH_TIMER = 1`: CIA1 timer A ran out (the tick is timer B then), from the IRQ handler | interrupts off, the CIA acknowledged; saves every register it uses but A; may `cli` (then it must cope with being called again before it returns) |
| `synth_rt_irq` | only with `MIDI_RT_IRQ = 1`: each realtime byte ($F8-$FF) as it arrives, from the receive interrupt (IRQ or NMI), instead of the ring | A = the byte; may clobber A and X only; keep it short (another byte comes in 320 us) |
| `synth_tx_byte` | only with `MIDI_TX_HOOK = 1` (test builds): each MIDI byte just before the transmit handler writes it to the ACIA | A = the byte, kept; may clobber X only |
| `test_rx_feed` | only with `TEST_RX_FEED = 1` (test builds): the raster interrupt, from the IRQ handler | out: carry set = A is a byte received; may clobber A and X only |
| `synth_rx_irq` | only with `MIDI_RX_IRQ = 1`: each byte received (but realtime ones with `MIDI_RT_IRQ`), from the receive interrupt (IRQ or NMI: `midi_nmi_mode`), after it went into the ring | A = the byte, kept; may clobber X only; in the IRQ it may `cli` if it `sei`s again before returning; keep it short (another byte comes in 320 us) |
| `synth_key` | only with `SYNTH_SCREEN = 1`: from `key_event` while `screen_owner` is nonzero, presses and releases | A = key code (column*8+row), `want_press`, `shift_held`; out: carry set = used, then A nonzero = auto-repeat the key while held. Must keep the keyboard scan's variables |

A synth with its own screen sets `screen_owner` nonzero to take the screen
and keys; to give them back it clears it and calls `screen_init`. With
`RASTER_SAFE`, its `synth_draw_step` should ask `row_safe` (X = the screen
row; carry clear = not now) before drawing a row, and leave it for the next
call if the beam is about to pass it: drawing a template and then the
values over it, or blanking a row and then filling it, otherwise flashes.

**Parameters**

- `NUM_PARAMS` and the tables `param_default`, `param_max`, `param_step`,
  `param_kind` (`K_BAR256`, `K_BAR16`, `K_ENUM`, `K_TUNE`), `enum_ptr_lo`,
  `enum_ptr_hi` (choice names, 10 characters each) and `param_names`
  (12 characters each), all `NUM_PARAMS` long.
- The parameters `P_CHANNEL` (Omni, 1-16), `P_MIDIIF` (Off, Sequential,
  Passport, Datel, Namesoft) and `P_PADDLES` (Port 1, Port 2, Off), last in
  the list. From `LEARN_LIMIT` on, parameters can't be given a MIDI
  controller or a paddle; `.cerror` checks that these three are among them.
- `TUNE_CENTER` if the synth has a `K_TUNE` parameter (the value shown as 0).
- Default controllers `cc_numbers` / `cc_params` (`CC_COUNT` of them, may be 0) and
  default paddles `PAD_DEFAULT_X` / `PAD_DEFAULT_Y`.

**Screen and keys**

- `title_text` (40 characters), `help_text` (`HELP_ROWS` rows of 40), in
  screen codes.
- With `PARAM_PAGE2`: `page_names`, the two pages' names, `PAGE_NAME_WIDTH`
  (6) screen codes each, drawn at column 29 of the title row (keep the
  title's own text left of it); and `page_hints`, two rows of 40 screen
  codes, drawn in the help colour under each page's last parameter (to say
  where the other page is).
- `key_map`: 64 entries, one per matrix key (column*8 + row): a note
  (semitones above the keyboard's base C), `KEY_CMD | command` (with
  `KEY_SHIFTABLE`: SHIFT gives command+1) or `KEY_NONE`.

**Arrays and tables**

- `env_lo` / `env_hi`: the synth's 16-bit envelopes, which `env_decay` steps.
- In `tables.inc`: `TICK_LATCH`, `sq_lo`/`sq_hi` (from `tables_core.py`), and
  `test_pattern` for `TEST_MIDI` builds.
- `test_key_script` for `TEST_KEYS` builds.

**Memory**

- Zero page: core and synth variables together must end below $100
  (checked).
- $C000-$C0FF MIDI receive ring, $C100-$C13F key notes and $C200-$C27F
  controller map belong to the core. $C140-$C1FF is free for the synth.
  With `MIDI_OUT` $C300-$C3FF is the transmit ring; with `MIDI_SYSEX`
  $C280-$C2FF holds `sysex.asm`'s variables (`SYSEX_VARS`) and
  `SYSEX_RAM` ($E000-$EFFF, under the KERNAL) a received dump.
- The program must end below $C000 (checked by the `.cerror` above).

## Timing options

For a sequencer that plays in sync with no lag added (SID500, its
`docs/design.md` section 4). All off by default.

- `SYNTH_TIMER`: the 250 Hz tick moves to CIA1 timer B, and timer A's
  interrupt goes to `synth_timer` (the synth programs timer A and enables
  its interrupt in `synth_init`). Timer A, because old 6526 CIAs lose
  timer B's interrupt when the ICR is read on the cycle before it runs out
  (VICE emulates it), and the handler reads the ICR on every interrupt: a
  lost 250 Hz tick only delays the keys or a screen row by 4 ms, a lost
  sequencer tick would be a note late.
- `MIDI_URGENT` (needs `MIDI_OUT`): `midi_send_urgent` (A = the byte;
  clobbers A, X) queues a realtime byte that the transmit handlers send
  before the ring, so clock waits at most for the two bytes in the 6850
  (0.64 ms) however full the ring is. A 4-byte queue in zero page, one
  writer at a time (main loop or one interrupt). It writes the control
  register only when the transmit interrupt is off (`tx_irq_on`): VICE
  restarts its byte timer at every control write.
- `MIDI_RT_IRQ`: realtime bytes go to `synth_rt_irq` from the receive
  interrupt, as they arrive, and not into the ring (so the main loop's
  `synth_realtime` never sees them). After it the handler goes on to the
  transmit side, so a byte the hook queued with `midi_send_urgent` leaves
  in the same interrupt if the 6850 is free.
- `MIDI_RX_IRQ`: every other byte received goes into the ring as before,
  then to `synth_rx_irq` from the receive interrupt, so the synth sees
  MIDI in at once however long the main loop is held (SID500 parses there:
  its thru and its recording's timestamps). In the IRQ, interrupts are off
  (the hook may let them in, if it turns them off again before it
  returns: the byte is in the ring already, so a nested one can't overtake
  it); in the NMI (`midi_nmi_mode`), anything may have been interrupted.
- `IRQ_IO_IN`: both handlers save `$01`, set `RAM_IO` and put it back on
  exit (about 14 cycles), so the program may read the RAM under I/O with
  interrupts on and an interrupt still reaches the chips.
- `MIDI_TX_HOOK` (test builds, needs `MIDI_OUT`): `synth_tx_byte` sees
  every byte as it is written to the ACIA, to stamp it with a timer.
- `TEST_RX_FEED` (test builds): the VIC's raster interrupt stands in for
  a byte received. `irq_handler` calls the synth's `test_rx_feed` (carry
  set = A is a byte; it may clobber A and X), and the byte then takes the
  ACIA byte's path (`synth_rt_irq` or the ring). VICE takes MIDI in only
  from the host's devices, so this feeds a master's clock with exact
  timing (SID500's slave tests).

Stock VICE's 6850 sends a byte every 283 cycles (9 bit times, on purpose);
the wire and a real 6850 take 315 (10 bit times: measured on a Kerberos;
SID500's checks run a VICE patched to 10, SID500 docs/latency.md). It has
the transmit data register and the shift register as on the chip; a control-register write with the transmit interrupt on restarts that
timer (the next byte goes out a cycle later).

## The sequencer

`sequencer.asm` is optional: a synth that wants it includes it right after
its notes and engine. A synth that doesn't include it builds as before, so
it needs no option of its own. It plays one note at a time through the
synth's `note_on` / `note_off`, so the engine hears the steps as it hears
MIDI: an accented step comes with velocity `VEL_ACCENT` (127, else
`VEL_NORMAL`, 100), and a slide is the next note on while the gate is still
open. SID303 uses it; SID303's `docs/sequencer.md` has the design and the
playing rules, and its `tools/seq_check.py` tests it in VICE.

It needs `MIDI_REALTIME = 1` (it provides `synth_realtime`) and
`MIDI_OUT = 1` (checked). With `SEQ_REALTIME_OWN = 1` (off by default)
its handler is named `seq_realtime` instead, and the synth provides
`synth_realtime` and passes every byte on to it (with A = the byte): so
the synth sees the realtime bytes too, also MIDI clock while the
sequencer is stopped (SID101's arpeggiator). The synth provides:

- Calls: `seq_init` from `synth_init`; `seq_tick` from `synth_tick`
  every tick, before the sound engine; and from its screen, keys and
  hooks `seq_toggle` (play/stop), `seq_set_tempo` (after `seq_bpm` or
  `seq_swing` changed), `song_toggle`, `clock_reset` (Clock parameter
  changed), `seq_forget` (all notes off) and `out_note_off_now` (MIDI out
  turned off with a note sounding).
- The parameters `P_CLOCK` (0 internal, 1 MIDI clock) and `P_MIDIOUT`
  (0 off, 1 on); MIDI out goes on `P_CHANNEL` (Omni: channel 1).
- `LOWEST_NOTE`, `HIGHEST_NOTE`: transposed notes fold into this range.
- `edit_pat`: a zero-page byte, the pattern the synth's screen shows; a
  song entry sets it, so the screen follows the song.
- With `TEST_LOG`: `log_out`, called with each MIDI out byte in A (keeps
  A, Y).
- With `PATTERN_CC` and `MIDI_SYSTEM`: the hooks pointed at the
  sequencer's routines (`synth_pattern = seq_pattern`,
  `synth_song_position = seq_song_position`, `synth_song_select =
  seq_song_select`), or hooks of its own that call them (SID101's
  arpeggiator follows a song position).
- In `tables.inc`: `seq_tables(patterns, ...)` from `tables_core.py`, the
  constants (`SEQ_STEPS`, `BPM_MIN`, `BPM_MAX`, `GATE_LEN`, the step flags),
  the tempo tables and `default_patterns`; for the tests also the
  `TEST_EDGES` patterns and the `TEST_SONG` song.

MIDI control (SidSynth's: each synth holds one song):

- `seq_pattern` (CC 85, value 0..63 = pattern 1..64; 64..127 nothing):
  the pattern plays from the next pattern start, as F1/F2 choose it
  (stopped: from play); the step screen shows it; song mode goes off.
- `seq_song_select` (any song number): song mode on.
- `seq_song_position` (MIDI clock and stopped only; else ignored): the
  sequencer moves there, in steps (a MIDI beat is a 16th, 6 clocks). In
  song mode the song's length is the sum of each entry's pattern length
  times its repeats and the position wraps at it; the entry it falls in
  plays with its transpose, the repeats before it counted off. Else the
  queued pattern, the position modulo its length. The next continue plays
  from there, its first clock firing the step (an off-beat step fires
  then, not swung); a start forgets it. SID303's
  `tools/pattern_check.py` checks all of it in VICE against
  `tools/seq_check.py`'s model.

Memory, weak defaults the synth can change: `PATTERN_RAM` ($8000: 64 pages,
one per pattern: notes at 0, flags at 16, length at 32), `SONG_RAM` ($C700:
the song, under a page), and with `MIDI_SYSTEM` `SEQ_SPP_RAM` (`SONG_RAM` +
$F0: `seq_song_position`'s 7 working bytes, after the song block and the
synth's undo variables; checked). Test options in the file: `TEST_SEQ`,
`TEST_SEQ_PAT`, `TEST_SEQ_NEXT`, `TEST_SONG`, `TEST_CLOCK`,
`TEST_MIDIOUT`, `TEST_EDGES`; and `SEQ_BPM_DEFAULT`, `SEQ_SWING_DEFAULT`.

## SysEx dumps

With `MIDI_SYSEX` (needs `MIDI_SYSTEM` and `MIDI_OUT`) a synth sends and
takes its files over MIDI, each byte for byte as its disk file (load
address, header, data), so a PC can keep one as a .prg and put it on a
disk. Manufacturer ID $7D (non-commercial):

    request  F0 7D <synth> <device> 01 <kind> F7
    dump     F0 7D <synth> <device> 02 <kind> <len lo> <len hi> <data> <sum> F7

- synth: `SYSEX_SYNTH`, SidSynth's 1 SID303, 2 SID808, 3 SID101. device:
  the synth's MIDI channel - 1; $7F = any (a synth in omni hears every
  device and sends $7F). kind: the synth's (0 the song file; SID101: 1
  the preset bank).
- len: the file's length, 7 bits in each byte. data: groups of up to 7
  bytes, each a byte of their top bits (bit 0 = the group's first byte's),
  then their low 7 bits. sum: the sum of every byte from kind to sum is a
  multiple of 128.

Receiving: the header must match (ID, synth, device); then
`synth_sysex_begin` lets the synth go quiet, the data is unpacked into
`SYSEX_RAM` as it comes (`midi_process` hands data bytes straight to
`sxr_data`: ~12 come every tick), and the main loop skips the synth's
ticks meanwhile. At F7 the synth gets `synth_sysex_dump`; nothing else
changes before. Any status byte but realtime ends a message unfinished,
and so do 50 ticks (0.2 s) without a data byte (the synth hears a bad
dump). The main loop's two SysEx calls are opcodes switched between BIT
(4 cycles) and JSR/JMP only while a dump goes out or comes in, and
`midi_process`'s call is pointed at `sx_fast` only then: SID101's
heaviest case has hardly more time to spare.

Sending: the synth describes a file as a region list (the `sysex_region`
macro: address, bytes 1..256, times, pages apart; `sysex_regions_end`)
and calls `sysex_send` (A = kind, X/Y = the list). The main loop's
`sysex_pump` packs and queues it, at most 8 bytes a pass, only when no
tick is due (packing at the wire's speed doesn't fit beside a busy tick:
a busy synth sends slower) and while the transmit ring has room. The same list, past the header, can take a
received dump in (`sysex_unload`, from `sysex_src`).

Tests: `TEST_SYSEX` 1 feeds the synth's `test_sysex_data` (a length
word, then MIDI bytes: copied to $F000 at start) into MIDI in from tick
`TEST_SYSEX_TICK`, `TEST_SYSEX_RATE` (13) bytes a tick; 2 keeps every
SysEx byte sent at `SYSEX_RAM` (and doesn't wait for room: VICE has no
MIDI there); 3 both. SID101's `tools/dump_check.py` is the model.

The PC tool, `sysex.py` (mido, python-rtmidi): `python sysex.py get
sid101 [--bank] [-o FILE]`, `python sysex.py send FILE` (the synth and
kind from the file's header), `--port NAME`, `--channel N`.

## License

Copyright (C) 2026 Jarkko Lehti. Free software under the GNU General Public
License, version 3 or (at your option) any later version; see
[LICENSE](LICENSE).
