# SID500 design (draft)

A 16-channel MIDI sequencer for the Commodore 64, the fourth program of
**SidSynth**, after SID303 (acid bass), SID808 (drum machine) and SID101
(lead synth). Named after the Roland MC-500, a MIDI sequencer of the same
era. Later, if there is time, a simple synth of its own on the SID. Begun
2026-11-20; all of section 7's questions were settled with the user the
same day, and section 4's timing design follows a review of the plan
against the core's code (in sync, no added MIDI lag).

## 1. Decided (the user, 2026-11-20)

- **Patterns and a song.** 16 tracks, each on its own MIDI channel, each
  playing short patterns; a song chains them. Like the family's step
  sequencer grown to 16 tracks.
- **Real time and step entry.** Recorded from a MIDI keyboard while it
  plays, with quantize; entered and corrected step by step on the screen.
- **The built-in synth** (a later stage, if there is time): first a 3-voice
  polyphonic synth; changed by the user (2026-11-20) to an ambient drone
  made of SID voices 1 and 2 together, ring modulation and sync between
  them, updated at 50 Hz (section 6), with voice 3 always the metronome's.
- **The name: SID500.**

## 2. What it reuses

From the core (`core/`, synthcore): the MIDI interfaces (in, out, clock,
song position), the parameter screen, keys, paddles and learn, the 250 Hz
tick, disk (KERNAL access with its zero page kept), SysEx dumps and the
VICE test framework (`TEST_MIDI`, `TEST_KEYS`, logs and Python models).
The core's own `sequencer.asm` is a one-track step sequencer for a mono
synth: SID500's engine is new, but its song chaining, tempo, swing, clock
and song position work the same way and should stay compatible (a song
position from a master means the same to all four programs).

From SID303 and SID101: the step screen's look and keys, undo, the disk
and SysEx code, the manual and site scripts. Packed disks (c64pack).

## 3. The music data

- **Time:** 48 ticks a quarter note (Q2), steps of 1/16 = 12 ticks; MIDI
  clock in and out is 24 a quarter, every second tick. Recording keeps the
  ticks (quantize is applied to what is kept, so it can be changed); step
  entry writes on the steps.
- **What an event is:** a note (note, velocity, length), a controller,
  pitch bend or a program change (Q3). Aftertouch isn't recorded; a
  controller or bend moved live is thinned as it is recorded (a change
  kept only every few ms), and rounded to the nearest tick, not floored.
- **A compact event format** (2026-11-20, the user asked whether events
  can be compressed lightly): variable length, so an event takes only what
  it needs. Decided before stage A, as saved songs depend on it; settled
  in stage A (2026-11-20) as below. A pattern's events are a byte stream,
  each event its time, then any prefixes, then the event:
  - **time** (1 byte): $00-$EF = the ticks since the previous event (the
    first: since the pattern's start), $F0-$FE = (byte - $F0) * 256 plus
    the next byte (up to 3839 ticks), **$FF = the pattern's end**;
  - **prefixes**, which set the pattern's current values for this and the
    following notes: $80-$8D a length from a table of 14 (3, 6, 8, 9, 12,
    16, 18, 24, 32, 36, 48, 72, 96, 192 ticks: 64th to whole note, dotted
    and triplet ones), $8E a length of 1-255 ticks in the next byte, $8F
    of 1-65535 in the next two (low, high), $90 a velocity (1-127) in the
    next byte;
  - **the event:** $00-$7F a note of that number, with the current
    velocity and length; $91 a controller (number, value; the number
    becomes the current one), $92 the current controller (value), $93
    pitch bend (low 7 bits, high 7 bits), $94 a program change (program).
    $95-$FF are unused (a reader stops at them as at a broken pattern).
  - At a pattern's start the current values are velocity 100, length 12
    (a 16th) and controller 1.
  So a step-entered note takes 2 bytes (3-4 when its length or velocity
  changes), a live one 5 (time, a length, a velocity, the note: 4 with a
  table length), a knob move 3: the pool's 768 blocks of 30 bytes hold
  about 11,000 step notes, 4,600 live notes or 7,700 knob moves (a fixed
  4-5 byte record: about 5,000). Playing it costs almost nothing: each
  track reads its events in order anyway.
- **A pattern** belongs to one track: any length from 1 to 128 steps (8
  bars, Q1), its events in order; each track's pattern loops at its own
  length, so tracks of different lengths make polyrhythms. Patterns live in
  one shared pool, so a busy drum track can use more of the memory than a
  sparse pad.
- **The pool is made of small linked blocks** (32 bytes, 2026-11-20: 30
  bytes of a pattern's stream, then the next block's address, low and
  high, $0000 at the last; free blocks chained the same way), so an edit, an insert or a recording
  moves at most one pattern's bytes, never the pool: moving 30 KB takes
  about 0.45 s, which would break the editor's one-frame rule and hold the
  player up. A change the player could see half done is made aside and
  switched in by one pointer (or length) write, atomically.
- **Recording** writes to a small unsorted take buffer; it is merged into
  the pattern a piece at a time between ticks (at the loop's end or at
  stop), never in one go.
- **A scene** (row): which pattern each of the 16 tracks plays (or none),
  and **its length in bars** and **its time signature** (the bar for "at the
  end of the bar", the song's length and song position; 4/4 by default).
  The time signatures (the user, 2026-11-20): any 1-16 beats over 4 or 8
  (3/4, 5/4, 6/8, 7/8, 12/8...): a bar is that many quarters (48 ticks)
  or eighths (24 ticks).
- **Swing** (the user, 2026-11-20): as the family, one Swing parameter
  (0-15) for the whole song: what falls on an odd 16th is delayed by
  swing/32 of a 16th, rounded to ticks (0-6), counted from the scene's
  start, so all tracks swing together. As built (stage A): each tick
  makes 0, 1 or 2 passes over the tracks (`tables.py` `swing_counts`, 24
  entries a Swing value), so the music runs slower than the ticks in a
  pair of 16ths' first half and faster in its second: on the grid the odd
  16th comes s ticks late, as the family's; what was recorded off the grid
  moves in proportion. Clock, song position and stops stay in ticks.
  Checked by `play_check.py` (the band at swing 8 and 15, half the wire at
  15: every byte the model's, the lag as without swing).
- **The scene's length and time signature** are used from stage E on
  (the song of scenes, launching at the end of the bar); until then the
  song is one scene, playing on, its start the song's start.
  Each track's place in a scene is the time from the scene's start modulo
  its pattern's length. **The song:** a list of scenes, each with repeats,
  as the family's songs.
- **A track:** its MIDI channel (1-16, so two tracks can share one),
  program change and volume sent at start, transpose, mute and solo, and
  its **priority** (the order its notes go out when many fall on one tick:
  drums and bass first by default).
- **Memory** (checked against the core's map; the notes below $D000 at the
  user's request, 2026-11-20, so loading and saving stay simple):

  | Area | Use |
  |---|---|
  | $0801-$6FFF | the program (code, tables, texts; to $5FFF until stage E, $67FF until stage F); copied at start: code at $0200-$0258, $02A7-$02FF, $0334-$03FF and $FF80-$FFF9 (design "The size pass, second part") |
  | $7000-$BFFF | **the note pool, 20 KB** (24 KB from $6000 until stage E; the user: its first 2 KB for stage E's code, 2026-11-23, 2 KB more for stage F's, 2026-11-24): about 6,700-8,400 events in the compact format |
  | $C000-$C7FF | the core's (MIDI rings, key notes, controller map, SysEx variables, disk zero-page copies, song block) |
  | $C800-$CFFF | SID500's song, scenes and track settings (2 KB) |
  | $D000-$DFFF | the RAM under I/O, 4 KB: **tables and texts** (the user, 2026-11-20), read with `$01` = $34 |
  | $E000-$FFFF | under the KERNAL: left free; the core's SysEx staging area (`SYSEX_RAM`) |

- **How long a song fits** (estimates, 2026-11-20; to be measured in stage
  A and shown by a memory gauge): the pool holds about 8,000-10,000
  compact events, some 7,000-9,000 after the linked blocks' links and part
  filled last blocks. At 125 BPM (a bar 1.92 s), with nothing repeated:
  5 busy tracks (~64 events a bar) about 110-140 bars, 3.5-4.5 minutes;
  4 lighter tracks (~30) about 230-300 bars, 7.5-9.5 minutes; one played
  part (~8) 30-35 minutes. A song built from repeating patterns is limited
  by its different bars only: a 5-minute song at 125 BPM (156 bars) with a
  third of it different material uses about 40 % even with 5 busy tracks.
  Live knob moves cost most: a 2 s filter sweep is about as much as two
  drum patterns.
- **Tables and texts under I/O** (the user's suggestion, 2026-11-20): help
  texts, parameter and setting names, the family's drum, preset and
  controller names, screen templates, the event format's length table, the
  drone's tables. Not what the player reads in its interrupt (it never
  switches banks). The rules that make it safe:
  - **The interrupt handlers switch I/O in themselves** (save `$01`, set
    $35, put it back on exit: about 14 cycles each), so an interrupt that
    comes while a table is read reaches the CIA, the ACIA and the SID, not
    the RAM under them. An NMI interface can't be held off with `sei`, and
    long `sei` stretches would add the jitter section 4 removes: so no
    `sei` around table reads. This is a core option (the handlers are the
    core's), off by default like the others.
  - **Colour RAM is I/O:** a routine reads its table entry with I/O out,
    switches I/O back, then draws the cell (character and colour, back to
    back).
  - **Loading:** the KERNAL's LOAD writes with I/O in, so nothing can be
    loaded under it directly (c64pack's unpacker could, a plain PRG
    couldn't). The tables are assembled into the note pool's space and
    copied under I/O at start, before the pool is cleared, as SID101
    copies its factory presets: it works however the program is loaded.
  If the room still runs short, parts used only while editing can also go
  under the KERNAL ($E000 and up, with the ROMs out; not during disk
  access), never the notes.
  **As built (2026-11-22):**
  - **First the tempo tables:** `tempo_latch_lo` / `_hi`, `tempo_frac`
    and `tempo_lead`, 1 KB at $D000-$D3FF. They were the most bytes for
    the fewest readers (`player_set_tempo`, `player_init`, each switching
    `$01` to $34 around its reads). `slave_lead` and `swing_counts` stay:
    the interrupt reads them.
  - **The image:** `io_data` is assembled at $D000 and stored after
    `program_end`. `io_copy`, the first thing in `synth_init`, copies it
    there before the pool, the log or a test scene uses that RAM.
  - **Room:** the program ends at $5C0C (~1,000 bytes below the pool;
    it was $5FBA). The heavy test scene fits its test build's pool again.
  - **Then the rows' texts and the cells' numbers** (stage D's start,
    2026-11-22): the grid's and the song title's 40-character rows, read
    by `line_text` (song.asm), and `song_num_c0`-`_c2`, read with `$01`
    switched around the song row's cells and `song_cell_text`. The program
    ends at $596E (~1,680 bytes left); the hot code's addresses unchanged.
  - **Thru** (stage D's first step) took it to $5C9A (~870 bytes left).
  - **The grid's step ticks computed** (2026-11-22, room for recording):
    `step_tick` (step * 12, ~40 cycles) instead of two tables of 129
    bytes; the program ends at $5BD2 (~1,070 bytes left). The checks of
    the grid (edit, flash, screen) pass as before.
  - **Test builds:** the slave tests' feed (`feed_bytes`, up to ~580
    bytes) goes under I/O too. Its raster interrupt switches `$01` around
    its three reads, so the heavy scene fits every slave test build's
    pool. Before the guard, transport_check's heavy slave runs had played
    truncated patterns, which they don't check.
  - **Next:** the texts and other tables when room runs short again.
  - **The hot code's place is held:** the routines before `synth_timer`
    became 32 bytes shorter (`player_restart` moved out of the way, the
    two readers 8 bytes longer each). A fill of that size (`HOT_PAD`)
    keeps the player's and renderer's loops and the live reader where
    they were measured, in every build: a fixed address doesn't work,
    because the test builds have their own code before it. (A first try
    pinned `synth_timer`'s address: it moved the test builds' hot code by
    16 bytes, and the 295 BPM edit switches went to ~589 ms again.) A
    routine before it that grows takes its bytes from `HOT_PAD`.
- **Disk:** everything saved is below $D000, so the KERNAL's SAVE writes it
  straight from memory (it couldn't from the RAM under its own ROM). During
  disk access the KERNAL's vectors are in and MIDI is deaf: disk works only
  while stopped. A file is packed (c64pack) to shrink it.

## 4. Timing: in sync, no added MIDI lag

The user's requirement (2026-11-20): everything must run in sync, with no
MIDI lag added by SID500. A review of the plan against the core's code
(Fable 5.2, 2026-11-20; its findings checked in the code) showed the
synths' way of running, everything in the 250 Hz tick, can't do it:

- a 48 ppqn tick snapped to the 4 ms grid lands 0-4 ms off (at 300 BPM
  there are 240 ticks a second on 250 slots), and MIDI clock out comes out
  as alternating 20 and 24 ms gaps at 120 BPM: tempo wobble downstream;
- the tick is run by the main loop (`tick_count` vs `tick_done`), so a row
  being drawn or the keyboard scan starts it another 0.3-4 ms late;
- clock goes through the same transmit ring as notes (the core's
  `out_realtime`): behind a 48-byte burst it is 15 ms late;
- the core's `midi_send` drops bytes silently when its 255-byte ring is
  full: 16 four-note chords with their offs (272 bytes) overflow it, and a
  lost note off is a stuck note;
- as slave, an incoming clock byte waits for the main loop and the next
  250 Hz tick: 0-4 ms more.

So SID500 is built this way instead:

- **The player runs in its own timer interrupt: CIA1 timer A** (first
  planned on timer B; see the core list below for why A), loaded with
  the exact length of a sequencer tick at the tempo (1,231,560 / BPM
  cycles: 10,263 at 120 BPM, 4,105 at 300; it fits 16 bits down to 19
  BPM), the fraction carried over by dithering the latch between P and
  P+1, so it never drifts. Its jitter is the interrupt's latency: a
  handler already running (measured up to 0.29 ms in VICE with the
  tests' stamps). The handler sets the next latch, queues the tick's
  clock (urgent queue, interrupts still off: see "Measured in VICE"),
  counts the tick, marks itself busy and allows interrupts again (`cli`:
  the 6850 has no FIFO and a MIDI byte comes every 315 cycles, so a
  1000-cycle player with interrupts off would lose input), then plays the
  tick's notes. It has its own zero-page scratch, never the main loop's
  `ptr`/`tmp`.
  The 250 Hz tick (moved to timer B) stays for the keys, the screen and
  the stage H synth.
- **Clock jumps the queue:** an urgent one-byte slot the transmit handler
  sends before the ring (MIDI lets a realtime byte go between any two
  bytes). Clock jitter is then at most one or two byte times (0.32-0.64
  ms: the 6850's data and shift registers). The clock is queued before the
  same tick's notes.
- **One merger writes MIDI out** (the player in the interrupt, thru in the
  main loop): it keeps the running status, sends whole messages, and the
  main loop's side queues inside `sei`/`cli` (about 30 cycles).
- **Nothing is ever dropped:** when the ring is nearly full the player
  waits for room. Order (the user, 2026-11-20, as built): clock, then
  thru, then the tick's note offs, then the tracks in their priority
  order, each track's events in their recorded order (so a program change
  goes before the notes it is for). Nothing is replaced or thinned: in
  overload a controller goes out late, never dropped. (Planned at first:
  notes before controllers, and a controller still waiting replaced by
  its newer value.)
- **The wire is the only lag left, and it is physics:** 31,250 baud is
  3125 bytes a second. 16 tracks with a note each on one tick is 48 bytes,
  the last 15 ms after the first (31 ms with the previous notes' offs); 16
  four-note chords, 144 bytes, 46 ms. Tracks go out in their priority
  order, the same every time, so a beat always sounds the same. No
  per-track "send early" offset for now (the user, 2026-11-20): the
  priority order does that job (drums and bass first); it can come later
  if busy songs need it.
- **Slave:** a clock byte is caught in the receive interrupt (`cmp #$f8`)
  and plays the even sequencer tick at once; the odd tick between two
  clocks comes from timer A as a one-shot at half the last measured clock
  gap (its error touches only that tick and never accumulates; a tempo
  change is followed within one clock). Start, stop and continue are
  caught the same way.
- **A slaved SID500 passes the clock on** (the user, 2026-11-20): clock,
  start, stop and continue go to MIDI out through the urgent slot about
  0.3 ms after they came in, so the family's synths downstream stay in
  sync.
- **Stop ends what sounds with exact note offs** (the user, 2026-11-20):
  at once, a note off for each note SID500 started and hasn't ended,
  nothing else (no All Notes Off: other parts or a keyboard on the same
  channels go on). As master and as slave; continue doesn't restart them.
- **The transport keys** (the user, 2026-11-20): SPACE stops if playing,
  else continues from where it stopped (song position, then continue);
  SHIFT+SPACE plays from the start (start). RUN/STOP stays the core's
  panic key. As slave the master starts and stops it.
- **Continue resumes at the next 16th** (the user, 2026-11-20): MIDI's
  song position counts 16ths, so a master stopped between two resumes at
  the next one and sends that position; the notes off the grid and the
  controller changes between the stop and that 16th are skipped. Stop
  itself acts at once.
- **Song position:** as master it is sent at stop and at a locate, not just
  before continue (the family's `seq_song_position` divides), and start is
  sent at least 1 ms before the first clock.
- **Thru:** a whole message, re-channelled to the record track, through the
  merger, right after clock and before sequenced notes (else it would wait
  out a 46 ms burst). Its lag: about 0.3 ms after the message's last byte,
  plus the main-loop pass (1-4 ms) that parses it. Incoming notes are
  timestamped when parsed (under 4 ms, below the 10.4 ms sequencer tick at
  120 BPM) and rounded to the nearest tick.
- **MIDI in:** SID500 listens in omni and needs each message's channel: the
  core's `midi_dispatch` filters by `P_CHANNEL` and drops the channel, so
  SID500 reads `running_status` (or a core option passes the channel).
- **The CPU:** a byte out costs about 130 cycles (queueing about 45, the
  transmit interrupt 80-90): a saturated wire takes about 40 % of the CPU.
  That is fine for the sequencer, so the stage H synth must be light
  (hardware ADSR, about 1000 cycles a tick or less) and is the part that
  gives way under load, never MIDI.
- **The cheap per-tick scan:** each track keeps a pointer to its next event
  and that event's due tick in zero page, so an idle track costs about
  15-20 cycles (about 300 for 16); note offs wait in one queue of absolute
  off times with the earliest cached (about 10 cycles when nothing is due),
  not a countdown for every sounding note (64 notes x 10 cycles = 640 a
  tick). The dangers: a pattern's loop wrap, a launch at the bar, and mute
  with notes sounding: their offs are flushed from the queue.
- **The editor against the interrupts:** a row drawn while the player and
  the transmit interrupt preempt it stretches from about 19 raster lines
  to 50 or more; the core's `RASTER_SAFE` margin (`SAFE_LINES`, 72) must
  cover the row and the worst preemption, measured, or a cell's character
  and its colour land in different frames. Each cell's character and
  colour are written back to back.

### Core changes this needs (options, all off by default)

The core is shared: each comes as an option in `core/options.inc` that
defaults to off, and SID303, SID808 and SID101 must build byte-identical
(`tools/core_identical.py` builds every program of theirs with the old and
the new core). Done in stage A (2026-11-20, core 14b0773):

1. **`SYNTH_TIMER`:** the player's timer is **CIA1 timer A**, not B (the
   user, 2026-11-20): old 6526 CIAs lose timer B's interrupt when the ICR
   is read on the cycle before it runs out (VICE emulates it), and the
   core's handler reads the ICR on every interrupt, so a player on timer B
   would lose ticks on a breadbin C64. Measured (VICE `-ciamodel 0`, the
   user's suggestion): the core's 250 Hz tick, now on timer B, loses 1-4
   ticks in 40 s of emulated time (about one every 10-40 s; the new CIA
   none), and the player on timer A none on either model.
   The 250 Hz tick moves to timer B instead: a lost tick there only delays
   a key scan or a screen row by 4 ms. Timer A's interrupt goes to the
   synth's `synth_timer`.
2. **`MIDI_URGENT`:** a 4-byte realtime queue the transmit handlers (IRQ
   and NMI) send before the ring (`midi_send_urgent`).
3. **`MIDI_RT_IRQ`:** realtime bytes go to `synth_rt_irq` from the
   receive interrupt as they arrive, not into the ring.
4. ~~A `midi_send` that reports "full"~~: dropped. A byte-at-a-time "full"
   would leave half a message sent; the merger checks room for a whole
   message itself. SID500 writes the ring with its own merger (the core's
   `midi_send` has one writer, the main loop). The core's only sender
   SID500 will use is the SysEx pump (stage G): then a core option lets the
   synth provide `midi_send`, so the merger also sees F0...F7 go out.
5. **`IRQ_IO_IN`:** the interrupt handlers switch I/O in on entry and
   restore `$01` on exit.
6. **`MIDI_TX_HOOK`** (test builds): every byte as it is written to the
   ACIA goes to `synth_tx_byte`, to stamp it in microseconds.

**VICE's ACIA** (from its source, `src/midi.c`): a byte every 283 cycles
(9 bit times, about 10 % faster than the wire's 315), with the data and
shift registers as on the 6850, so the burst tests can run in VICE with
283 in the model. But a control-register write with the transmit
interrupt on restarts that timer and sends a waiting byte a cycle later:
senders write the control register only when the interrupt is off.

### Measured in VICE (stage A's first step, 2026-11-20)

`tools/timing_check.py` runs the player's timer with clock out, alone and
under bursts of 16 note-ons on one tick (48 bytes, every 200 ms), at 40,
120 and 295 BPM, every byte and tick stamped with CIA2 timer A:

- **Both CIA models** VICE emulates (old 6526, new 8521) run every test.
- **No drift:** the ticks average the exact period to 0.2 cycles (the
  dither); each is on the exact grid within 0.1 ms quiet and 0.29 ms under
  bursts (it waits for a handler already running).
- **Clock:** written 0.26-0.40 ms after its tick, its gaps even within
  0.25 ms quiet and 0.6 ms under bursts.
- **Nothing dropped**, and the bursts go out at the wire's pace: a
  burst's last byte at most 1.4 byte times (0.4 ms) behind it in VICE (a
  byte written late behind another handler costs only its lateness).
- **The NMI path (Namesoft), run 2026-11-20:** correct (nothing dropped,
  every message as the model's). Its timing is worse than an IRQ
  interface's, by its nature: every byte sent interrupts the timer's
  interrupt too, before it queues the clock (on an IRQ interface the two
  take turns). Measured with only the ticks and clocks stamped: ticks
  within ~300-480 cycles of the grid, clock gaps even within 0.9-1.0 ms
  (Datel 0.3-0.5 ms). The clock is now queued first in the timer
  interrupt, before the latch. The tests' log is two logs, one per writer
  (the timer interrupt's, the transmit hook's), with 24-bit stamps.

What it taught:

- **The clock is queued from the timer interrupt before interrupts go back
  on.** With the player's `cli` first, a busy wire keeps a transmit
  interrupt pending nearly all the time and the clock waited behind three
  ring bytes (1.6 ms). So: latch, clock, count the tick, then `cli` and
  the notes (a busy flag and a count of ticks due: a tick is never lost,
  the player never re-entered).
- **A tick's messages are queued unpublished and then published at once**
  (one write of the ring's head) and the transmit interrupt turned on
  once. Bytes the interrupt can see one by one go out as they come: the
  ring runs dry, the interrupt turns itself off, and the rest waited for
  the end (a 46-byte burst 8 byte times late, about once in 200); turned
  on per byte, each byte cost two interrupts and a control write, slower
  than the wire.
- **The tests' stamps load the transmit interrupt:** a stamp on every
  byte makes it late enough to lose byte slots in VICE (283 cycles a
  byte), so the pace is measured in builds that stamp only a burst's ends
  and the clocks.

### The player as built (stage A, 2026-11-20)

`src/player.asm`; `tools/play_check.py` checks every byte sent against a
model of these rules, byte for byte, in VICE:

- **Each tick:** the note offs due, then the playing tracks in priority
  order, each track's events in their recorded order (a controller or
  program change recorded before a note at the same tick goes first, so
  controllers are not moved after notes, as first planned).
- **Note offs:** a timing wheel of 256 slots (the off time's low byte),
  128 entries, in the RAM under the KERNAL ($F000-$FBFF, with a map of
  each channel's notes to their entries): a tick looks only at its own
  slot. A tick's offs go out a channel at a time, channel 1 first, each
  channel's oldest first, so running status saves the status bytes (64
  offs: 144 bytes, not 192). A note started again while sounding gets its
  off first. With all 128 entries in use, the next off in the wheel is
  sent early to make room.
- **The merger:** running status (note offs as note on, velocity 0); a
  track's bytes published as soon as they are queued (a tick's at once
  would keep the wire waiting for every track; a byte at a time costs two
  interrupts a byte).
- **Idle tracks** count down to their next event or pattern end: a few
  cycles each a tick.
- **Measured, the open problem** (`play_check.py --sparse`: one byte in 8
  stamped, so the stamps don't load the transmit interrupt): the transmit
  interrupt costs ~110 cycles a byte (the plan said 80-90), the player
  ~400 an event plus ~500 a track with something to do; a 2-3 byte event
  takes ~700 cycles of wire time in VICE (790 on the wire). The band scene
  adds up to 8.4 ms at its start (seven tracks at once) and ~10 ms at busy
  ticks at 295 BPM, with no backlog. 16 tracks of 4-note chords and a
  controller every 16th at 120 BPM (2,700 bytes a second, 87 % of the
  wire) needs more than the C64 has: the interrupts take 95 % of the CPU
  (the transmit interrupt ~40 %, the player ~53 %), the main loop is left
  ~5 % (keys and screen frozen), and the player falls ~8 % behind. Every
  byte is right and nothing is dropped.
- **The load to carry (the user, 2026-11-20): half the wire,** about 1,500
  bytes a second (16 tracks with a 2-note chord every 16th at 120 BPM, or
  8 tracks of 4-note chords) on time, with the editor responsive. Denser
  songs still play every byte, later. (`tables.py` scene 4: 1,260 bytes a
  second.)
- **Rendering ahead, and optimising too (the user, 2026-11-20):** the
  player renders each tick's bytes into a staging page (`STAGE`, under the
  KERNAL) up to 4 ticks before it is due, in the timer interrupt's spare
  time; at the tick the timer interrupt only copies them into the
  transmit ring (`src/render.asm`). Mute and other live changes act up to
  4 ticks later (42 ms at 120 BPM). The first 4 ticks are rendered before
  MIDI start. Running status starts afresh each tick (thru may come
  between ticks). When the renderer is behind, a due tick goes out as it
  is rendered, a track at a time.
- **As built and measured** (`play_check.py --sparse`, 2026-11-20): every
  scene that must be on time adds at most 2 ms to the wire's own pace
  (band 1.3-1.5 ms at 120 and 295 BPM, half the wire 2.0 ms, more notes
  than the wheel holds 1.4 ms), every message as the model's, nothing
  dropped; overload (more than the wire carries) plays everything, late.
  What it took, beyond rendering ahead:
  - the release copies the staged bytes 16 at a time, each chunk
    published at once (one call per byte, and publishing at the end, kept
    the wire waiting ~11 ms on a busy tick);
  - the stage writes, the reader's fast path and the note offs inline;
    note offs and tracks rendered a step at a time (`render_step`: a
    tick's beginning, a channel's offs, a track);
  - three bugs: start-up's first ticks half rendered (a scratch byte
    shared with the player), interrupts switched on during start-up (an
    unconditional `cli`), and a deadlock in overload (the timer
    interrupt rendered in the middle of a release it had interrupted: it
    now doesn't); and 16-bit tick counters, so overload can fall behind
    by more than 127 ticks.
- **Correction (2026-11-20, later):** the 2 ms above was measured with
  logs that ended after ~200 ticks at 295 BPM. With longer logs the band
  scene at 295 BPM shows one place where it doesn't hold: at song tick
  1344 four patterns restart together (the least common multiple of 192
  and 84), and rendering that tick took about seven ticks, so it and the
  next ticks went out late, 6-8 ms. Found and fixed on the way: a note
  started again while sounding left its old entry dead in the wheel until
  its slot came round, and a long note in a short loop (the band's 96
  notes of 1000 ticks) filled the 128 entries with them, so every new note
  stole one (ending a live note early, and walking the wheel each time);
  the entry is now freed at once (each entry keeps its slot). And
  `release` and `ticks_lead` shared a scratch byte. And the cause: all
  eight tracks restart on that tick, so rendering it takes ~28,000
  cycles (interrupts in it too), while a 4-tick lead is ~41,000 cycles at
  120 BPM but only ~17,000 at 295.
- **The lead in time, not ticks (the user, 2026-11-20): about 42 ms at
  any tempo** (`tables.py` `tempo_lead`: 1 tick at 40 BPM, 4 at 120, 10
  at 295; `TICK_END` holds 16), so a busy tick has as long at any tempo,
  and live changes act at most ~42 ms later at any tempo. Measured with
  logs covering ~2,000 ticks (`play_check.py --sparse`, 8 s runs): every
  on-time scene within 2.4 ms on both CIA models and both interfaces
  (band 1.4-1.7 ms at 120 and 295 BPM, half the wire 2.3 ms, Namesoft
  1.4-1.7 ms). (Stage B, 2026-11-21: half the wire now 2.8-2.95 ms,
  the same on the commit before the live switch and after it; within
  `LAG_MAX`, 3,000 cycles.)
- **Open: the main loop's share** (for stage B). The main loop can render
  in slices (`render_slice`, from `synth_tick`), but behind the core's
  parameter screen's long rows it couldn't keep the lead, and busy ticks
  went out late; so for now the timer interrupt keeps the whole lead
  (`RENDER_MIN = RENDER_AHEAD`), and a busy tick's rendering holds the
  main loop off (half the wire: render steps up to ~13,000 cycles,
  ~30,000 for a busy 16th in all). With the editor's own screen (short
  rows, stage B) the main loop should take its share; to measure then
  against the one-frame rule.
- **Paddles are off by default:** the core's `paddles_read` assumes the
  paddle mux was set over 512 cycles before (by the last keyboard scan).
  When the main loop falls several ticks behind and catches up, the scan
  and the next read come back to back, an unplugged paddle reads as moved
  and takes over its parameter (here Tempo). SID303, SID808 and SID101
  never fall that far behind; a core fix (wait for the mux) is a question
  for the user.

### The slave as built (stage A, 2026-11-20)

`src/slave.asm`; checked by `python tools/slave_check.py`.

- **A clock in** is caught in the receive interrupt (`synth_rt_irq`, an
  NMI on Namesoft). It is passed on first (the urgent queue). Then the gap
  since the last clock is measured on a free-running 24-bit time: CIA2's
  timers, `time_init`; the test logs' stamps read the same time. Half the
  gap is a tick's length, taken if it is 2048 to 65535 cycles: a longer
  gap is a pause, a shorter one a glitch. Clocks are measured while
  stopped too, so the first odd tick after start has a tick length; until
  a gap is measured, the Tempo parameter's is used.
- **Every tick plays in the timer interrupt, never in the receive one.**
  While playing, the clock is counted and timer A is kicked: a one-shot
  of 2 cycles, which runs out before anything reads the ICR, so it gives
  one interrupt, not two. `synth_timer` then plays the clock's tick (the
  even one) as a master's tick.
- **The odd tick** comes from timer A as a one-shot, one tick length after
  the even tick (not after the clock's arrival). That way the two ticks
  are as far apart as the master's clocks: the even tick's own delay
  (receiving, passing on, the kick) is the same at every clock.
- **If the master speeds up**, a clock can come before the odd tick's
  one-shot runs out. Its kick replaces the one-shot, and the owed odd
  tick plays together with the even one: 2n - 1 ticks for n clocks, then
  the odd tick owed. Two ticks a clock, never more, none lost.
- **On an NMI interface**, a clock can come in the middle of
  `slave_tick`:
  - the clock count and the tick lengths are kept in two slots by the
    count's lowest bit, one written while the other is read;
  - after setting the one-shot, `slave_tick` looks at the count again, and
    kicks again if a clock came meanwhile;
  - an odd-tick interrupt more than 64 cycles before its time is a stray
    (a kick that came during the even tick) and plays nothing.

  **Untested so far:** the test feed is an IRQ on both interfaces, so
  none of these has run yet. On Namesoft it is the first thing to watch
  on real hardware.
- **The render lead** follows the master's tempo: `slave_lead`, about 42
  ms of ticks, indexed by the tick length's high byte.
- **Before start** a slave renders `LEAD_MAX` ticks, 14. Its master's tempo
  is unknown until it plays, and the lead from its own Tempo parameter
  could be too short (one tick at 40 BPM: 3.0 ms late on tick 2 under a
  290 BPM master).
- **`render_first` goes a step at a time** and stops while the stage still
  has 128 bytes free. With nothing due, a full stage waits for a release
  that never comes. That was possible before too, with one tick over 256
  bytes, and the heavy scene now stops early. The rest is rendered once
  playing. A track with over 128 bytes of events on one tick (42 notes)
  could still hang it before start.
- **Start, stop and continue** as slave: see "Start, stop and continue
  as built" below.
- **Changing the Clock parameter** while playing stops the player as a
  stop does (a master sends MIDI stop; the exact note offs), then it
  waits at the song's start in its new role (`player_restart`). Tested
  from master to slave while playing: the master's bytes match the model,
  then MIDI stop and the note offs, then every byte fed is passed on,
  then the slave plays from start.
- **The test feed** (`src/test_slave.asm`; core option `TEST_RX_FEED`).
  VICE takes MIDI in only from the host's devices, so a master's bytes
  are fed inside the C64:
  - the VIC's raster interrupt stands in for the ACIA's, and each byte
    then takes a received byte's path through the core's `irq_handler`;
  - the bytes and their spacing are `tables.py`'s feeds, timed in raster
    lines, and each byte is logged with its real time;
  - the raster line's 9th bit is written first, so the compare line
    between the two writes can't equal the beam's and interrupt at once.
- **Measured** (band scene, both CIA models; steady 120 BPM, clocks up to
  1 ms off, 120-150-120 BPM, 290 then 60 BPM, Namesoft):

  | What | Measured |
  |---|---|
  | Each byte passed on | 0.5 ms after it came, at most (Namesoft 0.35 ms) |
  | A clock's tick due | within ~970 cycles of the clock (Namesoft ~1,220), the tests' three stamps in that included |
  | Odd ticks | 0-400 cycles after their time |
  | Every byte | the model's |
  | Added lag | 1.1-1.3 ms at 120 BPM (Namesoft 1.0 ms); 2.6 ms on tick 0 under a 290 BPM master, whatever the Tempo setting |

- **A near-3x tempo jump is late for a moment (accepted by the user,
  2026-11-20).** From 100 straight to 290 BPM, the ticks rendered at the
  old tempo are a third of the lead in time, and a busy tick right after
  the jump went out up to 3.4 ms late, over the 3 ms bound. The ticks
  themselves are right, and it settles within the lead (~42 ms). Such a
  jump is rare; rendering 14 ticks ahead always would make live changes
  act up to 14 ticks late. The check reports this run's lag and doesn't
  fail on it.
- **Re-measured after the slave code went in:** the band at 295 BPM as
  master shows 1.8-2.1 ms. With the commit before, it was 1.6-1.8 ms on
  the same runs.
  - Not CPU time: the player's code is byte for byte the same, the
    longest render step the same (~7,200-7,700 cycles), and the renderer
    was never behind.
  - Not the code's page layout: padding the old build by 64 bytes left it
    at 1.6 ms.
  - Cause not found.
- **The checks vary from run to run**, as VICE's runs do:
  - the commit before failed `timing_check.py` once in three runs (the
    Namesoft clock gaps, 1,226 cycles against 1,200);
  - its burst pace at 295 BPM was 366-524 cycles against 566;
  - the bursts a run catches depend on the host's speed (65-98 in 3 s).

  `timing_check.py` crashed when a log ended inside a burst; fixed.

### Start, stop and continue as built (stage A, 2026-11-20)

`src/transport.asm`; checked by `python tools/transport_check.py`.

- **The keys (master):** SPACE stops if playing, else continues; SHIFT+SPACE
  plays from the start (the core's `PARAM_SYNTH_KEYS` hands SPACE to
  `synth_param_key`). The player no longer starts by itself: it waits
  stopped at the song's start (test builds with a log and no key script
  still start at once, `TEST_AUTOSTART`).
- **Start:** the song reset to its start unless it is there, then MIDI
  start at the next tick and the first clock and tick 0 a tick later.
  **Continue:** the song position goes first, and is on the wire before
  MIDI continue (the urgent queue would jump ahead of it); at the song's
  start, MIDI start instead.
- **Stop:** MIDI stop at once; then a note off for each note that has gone
  out and not ended, nothing else. Which notes those are: the note map
  (each note's wheel entry, as rendered), undone by the staged bytes not
  sent yet. Each note's first event among them says whether it was sounding
  at the stop: an off first means it was; an on first means it wasn't (a
  sounding note always ends before it starts again). A tick partly sent
  counts as sent. The offs go channel 1 first, each channel's notes
  upwards, each with its status.
- **Then on to the next 16th** (the 16th at or after the stop point), with
  nothing sounding and its first ticks rendered again, so continue is
  immediate:
  - the unsent bytes are dropped;
  - if the renderer is short of that 16th, it renders on to it silently,
    from an empty wheel;
  - if it has passed the 16th's start, the tracks' state comes back from a
    snapshot. `play_begin` keeps the last two 16ths' state at $FD10 (240
    bytes each, ~2,000 cycles a 16th);
  - the wheel is cleared;
  - the lead is rendered again: the tempo's, or as slave, its master's
    once a clock gap is measured (else 14 ticks).

  The master sends that 16th's song position, and again before continue.
- **As slave** the receive interrupt only changes the state and asks:
  - stop: the player is held, and the main loop (`transport_poll`, every
    250 Hz tick) ends the notes and moves on to the next 16th;
  - continue: if stopped, the next clock plays the 16th it is at;
  - start at the song's start: the same;
  - start anywhere else: the main loop resets the song first, and the
    clocks that come meanwhile are counted and played at once when it is
    ready.

  On an NMI interface the interrupt can come in between anywhere: it only
  asks while the player is held, and the main loop looks again after
  letting it go.
- **Measured** (the band at 120 BPM, both CIA models):

  | What | Measured |
  |---|---|
  | Every stretch played | the model's |
  | Every stop's note offs | the model's (69-108 notes ended a stop) |
  | Song positions | the model's |
  | No clock while stopped | yes |
  | A slave's continue | its first tick ~850 cycles after the first clock |
  | A slave's start at the song's start | the same |
  | A slave's start anywhere else | ~26 ms late: the song's reset (it was 44 ms before only tick 0 was rendered first). Accepted for now by the user (2026-11-20), to revisit in stage G with locating by song position |
  | A slave's continue that comes during the stop's own work | late by what is left of that work (heavy scene: 31-68 ms, before the lead after a stop followed the master's tempo; now on time in the tests) |
  | A master's stop | holds the main loop ~160 ms: mostly the offs on the wire (108 notes, 324 bytes) |
- **Found on the way: a stop could hang the program.** A slave's stop
  holds the player in the receive interrupt. A render step running in a
  timer interrupt below it then found the stage full, and `st_full`
  waited for a tick to come due, which a held player never makes: the
  interrupt never returned, so the main loop never did the stop (the
  heavy scene, stopped while its renderer was ahead). Two fixes:
  - the interrupt's render loop stops once the player is stopped or held;
  - a step that still finds the stage full then is abandoned
    (`render_abort`: back to the loop's stack pointer, `render_broken`
    set). Nothing the stop needs is lost: each message is staged before
    the note map changes for it (an off before its entry is freed, a note
    before it gets one). The tracks' state may be half-way through the
    step, so `stop_locate` then always goes back to a snapshot: the
    16th's own if the renderer is past it, else the one of the 16th it is
    in, then forward.

  `TEST_ABORT` keeps the loop going while held, so the stage fills and the
  abandon runs (`transport_check.py`).
- **The tests cover** (`transport_check.py`, 7 builds on both CIA models):
  - master, the keys, the band: stop, continue, and SHIFT+SPACE while
    playing (a stop, then a start);
  - master, eight stops in every place of a 16th (the light scene, the
    band without its long notes), on Datel and on Namesoft;
  - slave, the same sequence and eight stops;
  - slave, the heavy scene: a stop in a tick partly sent, and with
    `TEST_ABORT` a step abandoned.

  In every run: no note left sounding, never the no-snapshot fallback, and
  a continue played and matched after both ways a stop moves on
  (rendering forward, back with a snapshot). Not tested yet: the receive
  path through an NMI, and song positions over 127 16ths (the 14-bit
  split; the tests stay under 40).
- **In overload a master can't be stopped by its keys.** The heavy scene
  (more than the C64 can compute) leaves the main loop no time, so the
  keys aren't read. That is the main loop's share again (stage B); a
  slave's stop comes through MIDI in and works.
- **Found on the way: the interrupt's render loop nested without limit.**
  The render lock is held only during a step. A tick's interrupt between
  two steps found it free and started a loop of its own, one level deeper
  each tick while the lead was being caught up. After a jump from 100 to
  290 BPM as slave, the stack overflowed and the machine reset: one run in
  three, a crash only, as each check reads its log after the run. Now the
  loop itself has a flag (`render_running`), and a nested interrupt only
  releases.
- **A tripwire for that:** test builds log the stack pointer if it is ever
  below $80 (more than half the stack used). `timing_check.py`'s
  `run_log`, which every check uses, then fails. Normal depth reaches
  about $D3.
- **The zero page is full** (it overflowed by a byte during this work).
  The transport's main-loop variables are at $C150 (the RAM the core
  leaves to the synth).

## 4b. The metronome (the user, 2026-11-20)

A soft click for playing in and step entry, the first sound SID500 makes
itself. Settled with the user, one question at a time:

- **From the SID, a MIDI note optional:** a soft, short click (a few ms of a
  high triangle tone with a fast decay, quiet), a brighter one on each
  bar's first beat; a setting also sends it as a MIDI note on a chosen
  channel and note (a drum machine's rim or claves), through the merger
  like any note. The click is started from the player's timer interrupt,
  so it is exactly on the beat (a SID write: a few cycles there).
- **Off by default, a key toggles it** at any time (and a setting). A
  count-in (0, 1 or 2 bars) before recording clicks even when the
  metronome is off: a count-in you can't hear is no use (Claude's default,
  the user may change it).
- **It owns SID voice 3** (the user first chose: only while on, the synth
  then playing two voices; then the synth became a drone on voices 1 and
  2, section 6, so voice 3 is the click's for good). The click has its own
  level (the voice's sustain level) and bypasses the filter, so the synth's
  filter and volume don't change it. Without the synth (stages C-G) the
  click is the only thing on the SID.
- The click's sound and level are tuned by ear with the user (a WAV demo
  in the stage that builds it).

### The metronome as built (stage C, 2026-11-21, `src/click.asm`)

- **On the beat:** the click is started in the timer interrupt as a
  beat's tick comes due, before the tick's bytes are released; voice 3's
  gate is a tick long. The count is a `dec` where the tick is counted, and
  the routine is called only on a beat (`click_beat`) or to release
  (`click_release`). A routine called every tick, first with interrupts
  off, put the half-the-wire scene's added lag over its 3 ms (3.0-3.2
  ms). **Open, for the user:** with the count inline it is 2.87-3.06 ms
  across runs (the limit crossed in some), where the commit before
  measured 2.78-2.83. Taking the click's code out again gave 2.82-2.92, so
  ~80 cycles are the click's and the rest the code's new addresses (branches
  and page crossings in the renderer). The parameter screen draws a row a tick
  whatever their number. **The user (2026-11-22): 3.2 ms allowed for now**
  (`play_check.py` LAG_MAX 3,150 cycles, slave_check's too), as 2.9-3.1 ms
  is seen across runs, before and after that day's changes alike.
  The same margin shows in screen_check at half the
  wire (a cursor key ~81 ms of 80 allowed, once). Measured (`python tools/click_check.py`):
  every beat's tick clicks and no other, ~430-510 cycles after the tick's
  stamp (the interrupt's work before it), at 120 and 295 BPM, with swing
  (swing moves passes, not ticks) and in 7/8.
- **The beat:** a quarter in n/4, an eighth in n/8, from the playing
  scene's signature (scene 1 until stage E); bars from the song's start.
  The beats are counted when it is off too, so turned on mid-song it
  clicks in time. After a stop the phase is found again from the next
  tick due (`click_phase`, ~1,100 cycles) while stopped, with interrupts
  on, so neither the first beat nor a slave's passed-on clock waits.
  click_check plays the light scene through eight stops: every click is
  on a beat's song tick, none while stopped.
- **The sound (the user, 2026-11-24, from the demo: "click is perfect"):** a triangle, ~1.5 kHz,
  ~3 kHz on a bar's first beat; attack 2 ms, decay 6 ms, sustain 9 of 15,
  release 6 ms; the SID's volume full, no filter.
- **On and off:** the Metronome parameter (Off / On, off at start), and
  C= K on the song screen and the step grid (Claude's default, the user
  may change it). On the parameter screen use F3 / F4 (C= K there not
  yet). Nothing on the song or grid screens shows it yet.
- **Not yet:** the click as a MIDI note (the setting in 4b), the count-in
  (stage D). (Both built since: below, and 5b "The count-in as built".)
- **The MIDI note (the user, 2026-11-22):** channel 10, side stick (note
  37) on the beats, claves (75) on a bar's first beat by default. The
  channel and the two notes are three parameters. The Metronome parameter
  becomes Off / SID / MIDI / SID+MIDI, and C= K toggles between Off and
  the last other choice (fewest bytes: ~350 were left).
- **The MIDI note as built (2026-11-22, `src/click.asm`):**
  - **When:** the beat marks the note on to send. The timer interrupt
    sends it just before the beat tick's bytes, on the beat (the user,
    asked with the measurement: after them it was 4-10 ms late on the
    band's busy beats). The beat's notes then go ~1 ms later (3 bytes),
    only while the MIDI click is on. Its off (velocity 0) goes a tick
    later, after that tick's bytes. Velocity 100.
  - **Safe in the stream:** sent only between whole ticks. Running status
    starts afresh at each tick, but not while a tick goes out in parts
    (`rel_partial`), nor while a release this interrupt interrupted is
    under way (`release_busy`). It is sent inside `sei`, because a
    nested timer interrupt's release could come between its bytes (seen:
    stacked notes at 295 BPM). It needs room for all 6 bytes, since the
    ring can't empty inside `sei`; else it waits for the next interrupt,
    and then goes after the tick's bytes. A sounding note's off goes
    before a new on, and a stop sends a sounding note's off and drops an
    on not yet sent (`click_idle`).
  - **Parameters:** Metronome Off / SID / MIDI / SID+MIDI (bit 0 the SID,
    bit 1 the note), Click chan (1-16, default 10), Beat note (37) and Bar
    note (75), as bars 0-127. C= K keeps the last value but Off.
  - **Measured** (`click_check.py`, the note on channel 16 there: the
    band's drums are on 10): MIDI only, at 120 BPM in 4/4, the note on
    every beat's tick and no other, the right note, its first byte
    ~1,150-1,320 cycles after the tick's stamp (the clock byte first), no
    SID click. SID+MIDI at 295 BPM in 7/8: ~1,490-1,750 cycles, a SID
    click with each. Through eight stops (the light scene): every note on
    has its off, none while stopped, none left sounding.
  - **The hot code's place:** the hooks' 16 bytes in `synth_timer` moved
    everything after it. Past `events.asm`'s `.align` that came to 32
    bytes, for the player's and renderer's loops and the live reader.
    The live switch at 295 BPM then came in up to ~585 ms after an edit's
    publish (`play_check.py --edits`: over 500 in 4 of 7 runs, against at
    most 449 in 8 runs of the commit before), with no added work in the
    main loop. `click_init` and `player_prepare` (run at start, and at a
    stop or a start) traded places, -16 bytes before `synth_timer`, so
    the code from `player_clock` to the click's is where it was: at most
    449 ms again in 6 runs. Later builds (the tables under I/O, design
    3) gave 242-593 ms with the hot code where it was, and with the
    tables after it put back where they were too (an experiment: up to
    496). So the delay at 295 BPM varies more with small layout changes
    than any one fix can hold. **The user (2026-11-22): 600 ms allowed**
    (`play_check.py` EDIT_BUSY_MS) until stage D's per-bar index, the real
    fix.
  - **Room:** the program ends at $5FCA, 54 bytes below the pool. The
    next thing to grow needs the texts moved under I/O first.
- **Silent until 2026-11-24:** `synth_init` cleared the SID's registers
  up to $D418 after `click_init` had set voice 3's envelope and the
  volume, so the click wrote its gate on the beat (what click_check
  logged) and made no sound. Now only voices 1 and 2 are cleared ($D400-
  $D40D: an operand, nothing moved). Found when the user asked for the
  metronome's demo: a WAV through vicewav.py had shown one sound before
  (put down to MIDI out not draining in real time; with the MIDI
  interface Off there is no wait, and it was silent all the same).
  click_check now also listens: the band at 120 BPM recorded through
  VICE's sound, a click every half second, every fourth higher (it fails
  on the old code: one sound in 10 s).
- **The demo** (for tuning the sound with the user): `work/click/
  click-6581.mp3` and `click-8580.mp3` (and the WAVs), 16 s at 120 BPM in
  4/4, the light scene playing (its MIDI not heard: the interface Off),
  made by `python ../c64tools/vicewav.py` on a TEST_LOG TEST_PLAY=5
  TEST_CLICK=1 MIDI_IF_DEFAULT=0 build.

## 5. Screens (proposal)

- **Song / scene screen:** 16 tracks across, scenes down: the pattern each
  track plays, mute and solo, the scene playing marked. Launch a scene,
  chain the song.
  Layout (the user, 2026-11-20): 8 tracks at a time, 4 columns each (the
  pattern number, a gap), tracks 1-8 or 9-16, a key flipping the halves;
  scenes down, their numbers on the left; a title row with the tempo,
  the scene playing and the half shown. Each cell in its track's channel
  colour (`docs/plan.md` "Colour"), the cursor in reverse video.
  Keys (the user, 2026-11-20): F7 switches between the parameter screen
  and the song screen; the cursor keys move (past the 8th track to the
  other half); left-arrow flips the halves at once; + and - change the
  cell's pattern, DEL clears it; M mutes the cursor's track, S solos it;
  SPACE and SHIFT+SPACE as everywhere (stop or continue, from the start).
  The song's data (the user, 2026-11-21):
  - **64 scenes**, each a pattern for each of the 16 tracks (or none),
    its length in bars and its time signature; the screen shows about 20
    at a time and scrolls.
  - **Pattern numbers song-wide, 1-128:** + and - step through all of
    them (and "--", none), so any track can play any pattern (the same
    line doubled on two channels, say); each track keeps its own place in
    it. A number with no pattern yet plays nothing; the cell keeps it.
  - **A change to the playing scene is heard at once, in place**: within
    the lead (~42 ms), the track at the time from the scene's start
    modulo the new pattern's length, as mute acts; the notes sounding end
    on time.
  - **Solo** (a default, the user may change it): S toggles the cursor's
    track's solo, several at once; while any track is soloed only the
    soloed ones sound; mute always silences.
  - The player keeps **its own copy of each track's pattern** (taken from
    the playing scene at a start and at a switch), so an edit never
    changes what a track is reading under it.
  **As built (2026-11-21, `src/song.asm`):** the title (scene playing,
  tempo, the half, play or stop), the track numbers (M muted, S soloed)
  in row 2, 22 scene rows. Song data: `TRACK_SOLO`, `TRACK_QUIET` (what
  the player reads: `tracks_quiet` from mute and solo), `PLAY_PATTERN`
  (the player's copy), `SCENE_BARS`, `SCENE_SIG`, `SCENES` (64 x 16 at
  $CB00). Drawing:
  - two bitmaps of rows: urgent (a key's effect, also tried every 250 Hz
    tick) and dirty (the rest, a row a main-loop pass);
  - a row prepared aside (~1,000 cycles: the numbers from a table, each
    column written once), kept until the screen's content changes, then
    put when the beam allows; an urgent row waits for the beam to pass
    (at most ~2,600 cycles): under load the main loop runs only in short
    gaps between the timer's renders, and a row left for later missed
    them (keys 44-93 ms at half the wire, now at most ~70);
  - the song screen's own beam margin, 32 lines (`song_row_safe`): the
    core's 72 kept a row out of bounds for a quarter of the frame, and
    keys waited;
  - each cell's character and colour written with interrupts off between
    them, so a busy tick's rendering can't hold them apart.
  - **The flash check (2026-11-21, `tools/flash_check.py`):** every frame
    taken through VICE's binary monitor at a raster interrupt below the
    text (`TEST_FRAMES`, `src/test_frames.asm`), decoded into characters
    and colours; fails on a row state of at most two frames between two
    equal ones, a blank scene row, a glyph not in the set, a frame without
    exactly one cursor. It found two flashes, both fixed:
    - a move up or down drew the new cursor row and the old one in
      different frames: two cursors (or none) for a frame. Now the old
      cell is put back plain with the new row, in the same beam-safe
      moment (`song_old_row`, `song_pair_safe`, `song_pair_put`);
    - at half the wire a busy tick's rendering in the middle of a put let
      the beam show the row half old, half new: two cursors. Now only the
      cells that differ are written: up to 6 of them (a key's usual
      change) all with interrupts off at once; more (a half's flip, a
      scroll) a cell at a time, the cursor's cells (their reverse bit
      changing) last, all at once;
    - the old cursor's cell is put back inside that same moment, and the
      beam is looked at again just before it with interrupts off (the
      search for the differing cells, ~1,000 cycles, and an interrupt in
      it let the beam reach the rows first: two cursors, or none).
    Six runs in a row pass. screen_check after it: the band's slowest key
    19,272 cycles (a frame is 19,656; it was ~15,600), half the wire within
    its 80 ms.
    Reported: the switch to the song screen (F7) is drawn a row at a time
    over the parameter screen, nothing cleared first: 14-19 frames on the
    band, 33-38 at half the wire.
  - **The screen against a model (2026-11-21, in `flash_check.py`):** at
    every frame's stop the song data is read too (scenes, tracks, cursor,
    play state, tempo) and each row rendered as `song.asm` should show it;
    a row must show its model within 15 frames of its last change (40 at
    half the wire). Every row ends up exactly so. It showed the plan's
    "the rest of a screen change in a frame or two" far off: a mute or a
    scroll took 15-17 frames even with nothing playing, 25-50 at half the
    wire. **The user (2026-11-21): optimise now.** Found and done:
    - a mute or solo writes only the changed columns' colours (88 colour
      cells, ~1,100 cycles a column), not every row prepared and compared;
    - scene rows' colours are the same on every row: built once a change
      (`song_line_kind`), a row prepares only its characters (~700
      cycles, inlined);
    - the compare stops at 7 differences; a big change writes a cell's
      character or colour alone when only one changed; a dirty row that
      isn't the cursor's never waits for the beam;
    - a dirty row is first tried only with room to prepare it before the
      beam comes near (`song_row_far`): the scan rode along with the beam,
      preparing rows that were then too near;
    - `song_take` marked bits past row 24, never drawn, never cleared: the
      quick "nothing to draw" never held, and every main-loop pass scanned;
    - a dirty row on 250 Hz ticks with time left, as well as when idle.
    Now (frames until every row shows its model): the band, a mute 1, a
    solo 2, a half's flip 3-4, a scroll 9-10; half the wire, a mute or solo
    1-5, a half's flip 7-13, a scroll 25-30. The scroll is still off the
    plan's target: a scroll row costs ~4,000 cycles (most of it comparing
    40 cells to change 2).
  - **A scroll by copying rows (2026-11-21):** with every scene row as it
    should be before the key (`song_grid_clean`), a scroll copies the
    rows up or down a row a step (`song_shift_step`, ~900 cycles: each
    cell's colour, then its character) instead of drawing each again; the
    row leaving under the cursor is saved first, its cursor cell plain,
    and goes to the row next to it last, so the cursor's row is drawn at
    once (urgent). Meanwhile no other scene row is drawn (a row drawn now
    would be copied over, or copied from, wrongly) and no column
    recoloured; a key meanwhile finishes the copying first. Otherwise
    (rows still to draw) every row is drawn again, as before. A scroll
    now: the band 4 frames, half the wire 6-7; every row as the model's
    within 3-7 frames in every run.
  - **Every key timed (2026-11-21, `screen_check.py` with TEST_KEYS=7):**
    down and up (scrolls too), the half's flip, + and -, DEL to the
    cursor's row drawn, M and S to the header drawn. The band and the
    light scene: every key within a frame (the slowest, up/down on the
    band, 19,021 cycles: a key during a scroll's copying finishes it
    first). Half the wire within its 80 ms (the half's flip up to ~77
    ms, up/down ~68 ms).
  `screen_check.py`: the band and the light scene every key within a
  frame (median ~7 ms), half the wire within its 80 ms (median 8 ms; the
  slow ones are keys read just before 60-70 ms of back-to-back rendering).
  **The live switch as built (2026-11-21, `src/live.asm`):**
  - **The music's own time:** `pl_music`, the passes over the tracks
    since the start (24 bits; swing makes 0-2 a tick, so it differs from
    the ticks), is "the time from the scene's start" a track's place is
    taken modulo.
  - **A rule, not the keys:** every 250 Hz tick the main loop compares a
    few tracks' cells in the playing scene with `PLAY_PATTERN` (a number
    with no pattern yet counts as none; a changed cell's track first). So
    a quick + + + switches once to the last value, and anything that
    makes them differ again is put right the same way.
  - **Read aside, handed over:** a time T half the lead (~21 ms) past the
    renderer; the new pattern read to T modulo its length by the main
    loop's own reader (`events.asm`'s reader made twice, `ev_*` the
    player's, `ed_*` the main loop's), every event read (its prefixes set
    the velocity, length and controller), a few while the 250 Hz tick
    has time. Then a record (the reader, the next event's time, the
    place, the length; its flag written last) that the player takes as
    the pass before T ends: the track's state from it, `ACTIVE` built
    again when the track gains or loses a pattern. If the renderer got
    to T first, T moves on by the margin and how far past T it got, and
    the reading goes on from where it is. Stopped, the switch is made at
    once.
  - **Stops:** each snapshot holds `PLAY_PATTERN`, `ACTIVE` and
    `pl_music` too (two of 272 bytes), so going back to one is a whole
    earlier state. A switch it undoes is made again by the rule after the
    continue; a jump (`player_reset`, a snapshot restored) drops a switch
    not yet taken.
  - **Measured** (`play_check.py --live`: the playing scene's cells
    changed while playing, `TEST_LIVE`; the switches as logged made by
    the model at the same passes, every byte checked): from the change to
    the switch, the band at 120 BPM 21-42 ms (up to ~100 with swing 15),
    at 295 BPM 21-~330 ms, half the wire at 120 BPM 21-~250 ms (runs
    differ); then the lead. `transport_check.py` (TEST_KEYS=5, six
    stops each just after a +): switches undone by the stop and made
    again, every byte as the model's. A slave's start away from the
    song's start now ~29 ms (was ~26: the larger snapshot). The slow ones are the busy 16ths: the main loop kept out by
    the timer interrupt's rendering for tens of ms (the change itself
    came up to ~85 ms late at 295 BPM), so the record misses T and is
    tried again.
  - **The user (2026-11-21): accepted as measured, go on;** revisit in
    stage D (an index of the reader's state every bar would make the
    locate a few events). `play_check.py --live` allows 150 ms on light
    loads (~115 seen), 400 ms on half the wire and at 295 BPM.
- **Measured first (stage B, 2026-11-20): how soon a key reaches the
  screen while playing.** `tools/screen_check.py` (a stub song screen,
  `src/song.asm`: the title and one row with the cursor; key script 3; the
  half-the-wire scene, the load the user set):
  - **Most keys are on time:** the cursor drawn a median ~6 ms after the
    key was read.
  - **A few cursor keys are 55-82 ms late, on the busy 16ths.** All 16
    tracks play there: ~32 notes on and their offs, ~30,000 cycles to
    render, while the transmit interrupts take a large share of the CPU.
    That tick wasn't rendered in time, so the timer interrupt rendered it
    when it came due, a track at a time, each part sent as rendered (~80
    ms), and the main loop didn't run meanwhile. (Seen in a trace with
    `TEST_LOG_RELEASE`.)
  - **A master's stop is ~140 ms:** its notes ended and the song moved on
    in the main loop at once.
  - **Tried and dropped:** giving the main loop half the lead to render
    made it worse (57-97 ms): it didn't keep ahead, and the interrupt still
    rendered the busy tick late. Releasing ticks only whole, and rendering
    only with room in the stage, didn't help either: the time is the
    rendering, not the waits.
  - **Also found:** the core draws a row only when the main loop is idle
    or at a key scan (every 4 ticks), and under load it is never idle. So
    `song_urgent` (every 250 Hz tick) tries the cursor's and title's rows
    as well.

  - **Optimised (2026-11-20):** profiled (VICE's profiler, a whole busy
    tick trapped with `TEST_TRAP_TRACK=255`), the busy 16th took ~52,500
    cycles. Now ~31,500: the test builds no longer time every render step
    (`TEST_RENDER_TIMED`, so they measure the program as it is), the check
    for a renderer behind is inline, and the 16th's snapshot is taken as
    the tick before ends (not on the busy tick itself).
  - **Main-loop rendering tried again** (the interrupt rendering only once
    the lead is gone): the keys mostly fine, but the main loop couldn't
    keep ahead of a busy 16th inside the 42 ms lead, and the music went out
    up to 35 ms late at half the wire, 15-19 ms on the band at 295 BPM.
    Reverted: the music's timing comes first.
  - **The user (2026-11-20): keep 16 tracks and go on; trim later if
    needed.** The cost of a busy tick is ~500 cycles a track playing on it
    and ~350 a note: 8 tracks on one 16th would be about half. So at half
    the wire with all 16 tracks on one 16th, the editor can be slow for a
    moment (keys 20-60 ms); the music stays on time.
  - **The stop in pieces (2026-11-20).** SPACE (or MIDI stop) only holds
    the player and sends MIDI stop, so the title shows STOP at once. The
    rest runs in `transport_poll`, every 250 Hz tick while that tick has
    time (`stop_run`):
    - the walk;
    - the offs: an off only when the ring has room for it, never waited
      for;
    - rendering on to the 16th;
    - clearing the wheel and the note map, a page a call;
    - the lead rendered again;
    - the song position;
    - before a continue, the ring sent out.

    A start away from the song's start and a master's continue go the same
    way. A key pressed meanwhile is done after it (`transport_req`).
    Measured with `screen_check.py`:
    - the band: keys a median ~5 ms, one at 63-69 ms (its heaviest tick);
    - half the wire: a median ~11 ms, a few at 20-38 ms on the busy 16ths;
    - the stops' 140-170 ms are gone.
    - (the wheel cleared at once, for a slave's start away from the song's
      start, stays one pass over its nine pages: a page at a time cost
      ~10,000 cycles more, and that start went from ~26 ms to ~40 ms.)
  - **The title shows what was asked (2026-11-20).** A continue is held
    while its song position goes out and the ring drains, and the title
    showed PLAY only once that was done: SPACE to the title 68-148 ms.
    Now, held with a start or continue asked (`transport_req`, a slave's
    `slave_req`), the title shows PLAY at once: SPACE at most ~39 ms (a
    busy 16th). What is left late is the cursor on the busy 16ths, 22-67
    ms: the timer interrupt renders the busy tick (~30 ms) and the main
    loop, which draws, doesn't run meanwhile. `screen_check.py` measures
    from the key read, and keys aren't read meanwhile either.
  - **The user (2026-11-20): accepted, go on.** `screen_check.py` passes
    when every key is within a frame, except on the half-the-wire scene,
    whose busy 16ths may take up to 80 ms (`BUSY_MAX`; 22-67 ms seen,
    once 79). The band and the light scene: every key within a frame.
- **Pattern screen** (Q5), two views of the same pattern, a key between
  them: a **step grid** (16 steps a page, notes, velocity, length; as the
  family's step screen) for quick entry and beats, and an **event list**
  (a line per note, controller, bend or program change: position, value,
  velocity, length; as Pro-16) for exact fixes to live recordings, whose
  notes often fall between the steps.
  **The step grid (the user, 2026-11-21, one question at a time):**
  - **Rows, 3 note columns** (first answered "4", but 4 columns of
    pitch, velocity and length need ~51 characters; the user then chose 3,
    all shown): as the family's list, a row per step, 16 steps a page; 3
    note columns, each its pitch, the off-step mark, velocity and length;
    a 4th note or more on a step shows "+" (all of them in the event list,
    stage F). Columns: 0 the cursor's mark, 1-2 the step, 3-14, 15-26,
    27-38 the notes (a space, pitch 3, mark 1, velocity 3 right-aligned, a
    space, length 3), 39 "+". (As built: the mixed set has no "~", so a
    length not whole shows "+" after its whole steps, 3+ between 3 and 4,
    and one under a step "<1".)

    ```
     ST NOTE VEL LEN  NOTE VEL LEN  NOTE VEL LEN
    >01 C-3'100 4~    E-3 100 4     G-3 100 4   +
     02 ---
     03 C-3  80 2
    ```
  - **RETURN on a song cell** opens its pattern (heard on that track's
    channel); RETURN goes back. On an empty cell ("--") RETURN makes a new
    pattern (the first free number, 16 steps) and puts it in the cell.
    While the song plays, edits are heard at once (as the live switch).
  - **Note entry:** a note key (Z S X D ..., Q 2 W 3 ..., F5/F6 the octave)
    puts its note in the cursor's column and moves down a step; for a
    chord, CRSR right to the next column first, or SHIFT + note: the next
    free column, the cursor stays. From MIDI: the keys held together fill
    the columns, the cursor moves down when all are released. Velocity and
    length from the entry settings (shown at the bottom), each note
    editable after.
  - **Notes off the steps** (recorded): a step shows every note from its
    start up to the next step's; one not exactly on it is marked (C-3'),
    its exact time and length kept until edited. LN in steps, "~" when not
    whole (3~); setting LN makes it whole steps. Quantize (C= Q) moves the
    cursor's step's notes onto it; exact ticks are the event list's.
  - **Keys** as SID303's where it has the same thing: CRSR moves (right /
    left across the columns), SPACE a rest, DEL clears the note, + / -
    the pattern's length (1-128 steps), F5/F6 octave, HOME step 1 / CLR
    the pattern, C= U
    undo (SHIFT: redo), C= C copy the pattern to a new number; RUN/STOP
    play / stop (SHIFT: from the start; SPACE is the rest key here, as on
    SID303). New: C= V velocity and C= L length of the cursor's note (then
    + / -; the entry settings follow the last set), C= T transpose the
    pattern (+ / -), C= Q quantize the cursor's step, RETURN back.
    (Claude's default, the user may change it: C= K toggles the
    metronome on every screen.)
    (Checked in the core: while the synth owns the screen, `synth_key`
    sees every key first, RUN/STOP among them; C= is read from `key_now`
    as SID303's `steps.asm` does. No core change.)
  **The step grid as built so far (stage C's first step, 2026-11-21,
  `src/grid.asm`): shown, not yet edited.**
  - RETURN on a song cell with a pattern decodes it into an edit table
    under the KERNAL (`GRID_TABLE` $E000: 8 bytes an event, up to 384; 256 since the size
    pass, 2026-11-25) and
    an index of each step's first event, a piece at a time while the 250
    Hz tick has time (`grid_slice`); then the screen is the grid's. The
    decoder is the main loop's reader (`ed_*`), which the live switch also
    keeps between ticks: they take turns.
  - The rows are drawn by `song.asm`'s machinery (`song_mode`: its prepare
    and cursor row ask `grid.asm`); the cursor is the note's pitch
    reversed, its moves up and down put in one moment as the song
    screen's. Pages of 16 steps follow the cursor.
  - Pitches as the family's (MIDI note 12 = C0); the texts in screen
    codes (`.enc "screen"`: under "none" 64tass makes capitals $C1-$DA,
    reverse video).
  - `flash_check.py` checks it against a model too (TEST_KEYS=8: the
    drums, the many notes' pattern, the bass): every row as the model's;
    opening or leaving the grid draws a whole screen, ~22 frames on the
    band (reported, held to 60, as F7's switch).
  - **+ / -, the pattern's length (the user, 2026-11-21):** notes past a
    shortened end are kept, silent (the player never plays past a
    pattern's length) and not shown; lengthening again brings them back.
    As built: the steps' index is kept to the length (an edit adjusting
    all 128 entries cost ~1,500 cycles); + finds the new step's entry.
  **Editing a pattern no track plays (stage C's second step, 2026-11-21,
  `src/edit.asm`):**
  - Keys: a note key (SID303's layout, `grid_note_keys`; the Z key's
    note is the core's `kb_base`, F5 / F6) puts its note in the cursor's
    column: the step's n-th note in the table's order, replaced in place if
    it is on the step's start; one off the step is taken out and put on the
    start. With no note there, it is added after the step's notes on its
    start, before any after it, so it can land in an earlier column than
    the cursor's. Then the cursor moves down. SHIFT + note adds one and
    the cursor stays. SPACE takes the column's note out and moves down;
    DEL takes it out. The entry settings (velocity 100, a step's length,
    the octave) are shown on row 23. All other keys do nothing on the
    grid: the core's + and - would change a parameter not shown.
  - RETURN on an empty cell makes a new pattern. It takes the first number
    no cell holds and with no pattern, puts it in the cell, and gives it 16
    steps; it is published empty at once. A number with no pattern yet is
    made with that number.
  - The table: a record put in or taken out moves the records after it
    (unrolled, ~88 cycles a record: a 100-record pattern edited at its
    first step costs ~9,000 cycles, a full one of 384 ~34,000, 1.7 frames:
    **open**, rare in step entry, could be done in pieces if needed) and
    the steps' index after the cursor's step. A table that stopped short in
    decoding (over 384 events, 256 since the size pass, or a broken
    stream) is not edited.
  - Publishing: after an edit the table is encoded into a new chain, a
    record at a time while the 250 Hz tick has time (`edit_slice`; an
    edit meanwhile starts it again), then `wr_publish`, the old chain
    freed. The encoder writes what `tables.py`'s `encode()` writes
    (`event_check.py` round-trips every test pattern, byte for byte). A
    full pool drops the new chain and changes nothing; it is tried again
    after the next edit.
  - (As first built; since replaced by "Editing a playing pattern" below.)
    Not while anything can read the pattern's chain (`edit_safe`): a
    track playing it (stopped too: the readers stay in it), either
    snapshot, a live switch reading it or handed over. Since start-up
    copies scene 1's row, scene 1's patterns always count as played until
    the next step. Their edits stay in the table and on the screen,
    waiting (the title's "*"), and no other pattern can be opened
    meanwhile. The "*" shows only a publish that waits: shown for every
    edit, it flashed for the frame or two a publish takes.
  - Drawing an edit within a frame: a note moves the cursor, so two rows
    change. Drawn one after the other at the next ticks, they took up to
    ~1.3 frames on the band. Now both are drawn from the key handler. The
    edited row (the old cursor's) is prepared first and only its changed
    cells are listed (`song_more_take`). Then the cursor's row is put
    with the pair, and the listed cells right after it, in the same beam
    window (`song_more_put`); + and - list the title the same way. An
    urgent row waits for the beam once, after its changed cells are found
    (waiting before too let the beam come near again during the ~1,000
    cycles of finding them: ~4,000 cycles of a note's ~10,000). A step
    row costs ~2,000 cycles to prepare.
    Measured (the user chose "optimise now"):
    - Band: notes at most ~16,000 cycles, median ~11,500. A few keys
      land on a busy 16th, where the timer interrupt renders for ~13,000
      cycles while the main loop waits: then up to 22,600.
    - Half the wire: up to 94 ms.
    - The song screen's keys are unchanged.
    - **The user (2026-11-21): accepted, go on.** The busy-16th cases are
      the same as half the wire's. `screen_check.py` holds the edits to a
      frame on the light scene, two frames on the band (those over one
      are reported; up to ~29,000 cycles seen, a - that also moves the
      cursor: three rows) and 100 ms at half the wire. The real fix stays with
      the open item "the main loop's share of the rendering".
  - Tests:
    - `tools/edit_check.py` (TEST_KEYS=9): the new pattern's published
      stream as the model's; the scene's patterns not published again
      when opened unedited; the drums' edit waiting; the pool whole, with
      no leak.
    - `flash_check.py`: a run with the edits, the grid modelled from the
      edit table read from RAM (and checked, when only opened, against
      the test scene).
    - `screen_check.py`: the edits timed.
  **Editing a playing pattern (stage C's third step, 2026-11-21,
  `src/live.asm`, design 5 "heard at once"):** the publish no longer waits.
  - **Published at once** (`live_publish`): the pattern table points at
    the new chain. A switch being read from the old one, or handed over and
    not yet taken, is dropped. Then each track playing the pattern and its
    entry in either snapshot is marked stale (`PLAY_STALE`, `SNAP_STALE`:
    the snapshots grew to 288 bytes). This is done a track at a time with
    interrupts off: done all at once it held the clock up to ~1.9 ms.
  - **Playing:** the live rule switches a stale track to its own pattern
    as it switches a changed cell. The new chain is read to T (half the
    lead past the renderer), and the notes sounding end at their own offs.
    A track that comes to its pattern's end before then starts again in
    the new chain (`ev_start` reads the table), at its old length until the
    switch. The snapshots are taken from the tracks every 16th, so they
    stop being stale on their own.
  - **Stopped:** a stale snapshot entry is moved to the new chain the same
    way, T being the snapshot's pass (`live_snap_rule`). Then the song is
    prepared again from its 16th (`transport.asm stop_reprepare`): the
    snapshot restored, the wheel cleared, the lead rendered again, no song
    position sent. So a continue plays the new version from the 16th, not
    the old one for the lead rendered before. A start or continue asked
    meanwhile waits for it, as for a stop.
  - **The old chains** wait in a list of 8 (`retire_*`). They go back to
    the pool once nothing anywhere is stale (`live_free`). A full list
    makes an edit wait (the title's "*"), as a full pool does.
  - **Reading under load:** each turn of the main loop reads at least 8
    events of the new pattern (`LIVE_BURST`). At 295 BPM the main loop gets
    a turn only every few ticks, and a dense pattern read an event a turn
    took ~1 s to catch up with the music.
  - **Room:** test builds had run past $6000 (their scenes, feeds and
    scripts). Their pool now starts after the program; the release program
    is unchanged in this respect. The snapshot copies were made smaller
    (a page in four strips: ~300 bytes less, ~0.5k cycles more a 16th);
    the release program ends at $56B1.
  - **Measured:** `play_check.py --edits` (TEST_LIVE 2, the band: 8 patterns
    replaced while they play, lengths changed, the many notes' pattern
    with its readers deep in it, the lead twice in quick succession; every
    byte as the model's). Each edit is heard 21-146 ms after its publish
    at 120 BPM (swing 15 the slowest), 21-~470 ms at 295 BPM (runs differ;
    the user, 2026-11-21: accepted up to 500 ms until stage D's per-bar
    index, `play_check.py`'s limit for edits at 295 BPM), with the
    publishes ~70 passes (~300 ms at 295 BPM) apart. Switches are made one
    at a time, so several patterns published at once would wait for each
    other; the editor publishes one table, so that can't come from it.
    The clock gaps vary by at most ~470 cycles. `transport_check.py`
    (TEST_KEYS=10, TEST_LIVE 3: a publish at each P of the script) covers
    publishes while playing, during a stop and while stopped, a continue and a
    stop at once after one, and ten while stopped (more than the list
    holds), all against the model, every replaced chain freed. With the
    re-prepare switched off it fails, as it should. `edit_check.py`: the
    drums' edit published while playing, the old chain freed, the pool
    whole.
  - **Open:** a + on the playing scene while stopped still plays the old
    pattern for the lead (~42 ms) after a continue; the same re-prepare
    could fix it. Not measured: a run of quick edits to one pattern at
    295 BPM (each publish restarts its switch), and how much a re-prepare
    delays a slave's continue.
  **Velocity, length, transpose, quantize (stage C's fourth step,
  2026-11-21, `src/edit.asm` edit_change, edit_quantize; the user: plain +
  / - stay the pattern's length, C= + / C= - change what C= V, L or T
  picked, shown on the entry row as "C=+- VEL", LEN or TRN, until another
  is picked):**
  - C= V: the cursor's column's note's velocity +/- 1 (1-127). C= L: its
    length to the next whole step up or down (a length not whole goes to
    the step above or below; 1-128 steps). The entry setting follows the
    last set; with no note in the column, the entry setting alone.
  - C= T: every note of the pattern a semitone up or down, none if one
    would leave 0-127; every step row drawn again (the cursor's first).
  - C= Q: the cursor's step's notes not on its start put on it, their
    lengths kept. The table stays in time order: a note is moved ahead of
    the step's other events off its start, which stay where they are.
  - A C= key that changes nothing (an end reached, nothing to quantize)
    still draws the cursor's row, so every key is answered on the screen.
    The F5 octave help moved to row 22.
  - Tests: `edit_check.py` (a note's velocity +3 and length +1 step, the
    pattern transposed -2, the next notes entered with the settings as
    last set; the band's many notes' step 1 quantized while it plays, every
    stream as encode() writes the model's). `flash_check.py` models the
    entry row. `screen_check.py` times the C= keys as their own kinds (the
    key log marks C= held: + $40). On the band they are within a frame, and on
    the light scene too; at half the wire the log fills before the script's
    C= Q (its other keys within the 100 ms allowed).
  - Not tested: quantize with a controller between the notes off a step
    (none in the test scenes).
  **Undo (stage C's fifth step, 2026-11-21, `src/undo.asm`; C= U, SHIFT:
  redo).** The user was away; these are Claude's defaults, and the user may
  change them:
  - **What:** the step grid's edits to the open pattern (notes, rests,
    DEL, velocity, length, transpose, quantize, the pattern's length). The
    history is cleared when another pattern is opened. Settings (the entry
    velocity and length, the octave, what C= + / - change) aren't undone,
    as in SID303.
  - **How:** SID303 copies a pattern into a ring of pages before each
    edit, but a SID500 edit table is up to 3 KB. So each edit is kept as
    what it changed: a record put in or taken out (the record), records
    changed (their other version, swapped both ways), a transpose (its
    semitones), the length (the other length, swapped). A key's edits are
    one group (a note replacing one off its step is a delete and an
    insert). The entries are kept in 768 bytes at $C500-$C7FF (free in the
    core's map until stage G's disk code: to be reviewed then), about 50
    note edits. The oldest groups go when one doesn't fit; a quantized
    step of more than 31 events clears the history. A new edit drops what
    could be redone.
  - **The screen:** the cursor goes to the step the undo changed, and only
    that row is drawn again (an undo that redrew every row made the next
    keys late while the rows were drawn). A transpose, a length or
    another page draws every row. The old cursor is put back in the same
    moment as the new one (`grid_mark_old`), and C= U with nothing to undo
    still answers by drawing the cursor's row.
  - **Tests:** `edit_check.py`. A DEL, one velocity step and the last + are
    undone for good (F2 back, velocity 102, 6 steps); an insert and a
    replace, a transpose and the many notes' quantize are undone and redone
    (byte for byte back). `flash_check.py` passes with time between each
    undo and its redo; done within 2 frames, a redo makes the undone state
    read as a flash. `screen_check.py` times C= U ("C= U").
  - **Open:** on the light scene a plain + or - sometimes takes ~23,000
    cycles, a little over a frame, with or without undo (the urgent row's
    wait for the beam and what the tick is doing then); seen at ~19,500
    with undo's saving switched off.
  **Step entry from MIDI in (stage C's sixth step, 2026-11-21,
  `src/grid.asm` grid_midi_on, grid_midi_off; as settled, design 5 "The
  step grid"):** on the step grid a note from MIDI in (on the synth's
  channel, omni by default) is entered as a note key would. The first key
  of a chord goes to the cursor's column, the keys held with it are added
  to the step, and the cursor moves down when all are released. The
  entry velocity and length are used, not the key's velocity (as
  settled). A chord is one edit for undo. Not while the pattern is being
  decoded; on the song screen nothing yet (stage D records). Test:
  `edit_check.py` (TEST_KEYS=11 with TEST_MIDI: a chord of three, a single
  note, and a chord whose keys overlapped, as the model's; the cursor on
  step 4). VICE runs warp, so the core's MIDI feed starts again after its
  ~100 s of fillers within a run; the script closes the grid first.
- **Room (2026-11-21):** the program had grown to $5DC4 (the pool starts at
  $6000), and the test builds past it. The core's `mul8` now works by shifts
  and adds (core option `MATH_SHIFT_MUL`, ~150 cycles: parameter scaling
  and the parameter screen only), so the 1 KB of square tables is gone:
  the program ends at ~$5A00. A grid row's blanking is 8 stores a pass,
  not 80 unrolled (~400 bytes). Test builds start their pool after the
  program. Next, when needed: the song and grid screens' texts and the
  grid's tick tables under I/O (design 3's plan for that RAM).
- **Copy, clear and HOME (stage C, 2026-11-22; the user: the copy into
  the cell, a big CLR confirmed):**
  - **C= C** copies the open pattern to the first free number (as RETURN on
    an empty cell) and opens the copy. The cell the grid was opened from
    gets the copy; other cells that hold the original keep it. The copy
    is published as an edit of the new number, and only then put in the
    cell (`edit_copy_put`): before that the number has no pattern, and the
    playing scene's track would fall silent until the publish. It is put
    there only if the cell still holds the original (it could have been
    changed on the song screen while a full pool held the publish). The
    playing scene's track then switches by the live rule, to the same
    notes. The history is cleared (another pattern); the copy itself isn't
    undone (the original is still there: - on the song screen puts it
    back). Nothing happens while an edit waits to be published, or with no
    number free.
  - **CLR** (SHIFT+HOME) takes every event out (notes, controllers, bends,
    those past a shortened end), and the length stays. Up to 93 events
    (`UNDO_CLEAR_MAX`) it clears at once and is undoable: kept as entries
    of 31 records (`UNDO_CUT`), the table's last first, so undo puts each
    back at the table's end; then the steps' index is found again
    (`undo_index_all`). A bigger pattern asks first ("CLR AGAIN: CLEAR
    ALL, NO UNDO  ELSE KEEP" on the entry row). A second CLR clears it and
    the history; any other key cancels (and does what it does). SHIFT and
    C= themselves don't cancel: the core passes their presses to
    `synth_key` too, SHIFT's before HOME's.
  - **HOME** moves the cursor to step 1 (its page shown).
  - **Tests:** `edit_check.py` (TEST_KEYS=12, the band playing). The bass
    is copied: the copy is in its cell and played by track 2. Its first
    note is replaced, then CLR, undone, redone and undone, then step 3's
    note deleted (which needs the index found again: with
    `undo_index_all` switched off, it fails). The many notes (96
    events): CLR asks, HOME cancels it, the copy has all 96, and two CLRs
    clear the copy (C= U then changes nothing). The originals are
    unchanged, HOME leaves the cursor on step 1, the pool is whole.
    The copy's steps are cut to 94 events (DEL), so CLR asks, and then to
    93, so it clears at once and is undone: both sides of `UNDO_CLEAR_MAX`.
    The original is opened again (- on the song screen) and cleared by two
    CLRs, C= U then changing nothing.
    `screen_check.py` (TEST_KEYS=12) times the keys. On the band most are
    within a frame. C= C takes ~20,000 cycles (finding a free number reads
    every cell, ~14,000). The DELs on the 96-event copy take ~31,000. The
    heaviest, the CLR of 93 events kept for undo and its undo, are measured
    at ~38,600 and ~35,700, within the two frames (39,312) accepted for
    edits. The CLR first took ~145,000 cycles: `undo_room` dropped the
    older groups one at a time, each by moving the rest down a byte at a
    time. Now `undo_fit_clear` clears the history at once when the CLR's
    entries won't fit beside it (they take ~762 of its 768 bytes, so no
    older group could stay anyway). The index is found again in one pass
    over the table. At half the wire the keys take up to ~90,000 cycles,
    within the 100 ms accepted; on the light scene all within a frame (C=
    C ~17,900). DEL with nothing to take out now draws the
    cursor's row as well, so every key is answered.
    `flash_check.py` has a run of its own (TEST_KEYS=12). Its model shows
    the CLR question on the entry row while `grid_confirm` is set. No
    flashes. Every row is drawn again after a CLR or its undo (the cursor's
    first, at once), which takes as long as opening the grid on a dense
    pattern: the 93 events shown whole after up to 21 frames (opening the
    grid: 25). The check now holds such a whole-grid change (8 or more
    step rows changed at once) to the switch's 60 frames, and reports it.
    **Open:** drawing those rows faster, as for opening the grid.
  - **Room:** the program ended at $5EA4 then (~350 bytes left below the
    pool); see section 3 "As built" for the tables and texts moved under I/O since.
- **Track screen:** channel, program, volume, transpose, quantize, and
  which family synth is on its channel, if any (Q7): a track marked as
  SID303, SID808 or SID101 shows its names (SID808's drums by note, the
  presets' names for program changes, the controllers' names). Otherwise
  plain MIDI throughout.
- The core's parameter screen for the setup (MIDI interface, clock, drive).

## 5b. Recording (stage D; settled with the user, 2026-11-22)

- **C= R on the song screen** records the cursor's track. Playing: the
  take starts at once. Stopped: the count-in, then the song from its
  start, recording. C= R again or a stop ends the take. The take is
  merged at each pass of the pattern's loop end (and at its end), so what
  was played is heard on the next pass.
- **Overdub or replace:** a Record parameter, Overdub at start. Replace
  drops the pattern's old notes and controllers as the take passes over
  them in its first pass, then overdubs, so one take can build a loop. C= U
  on the song screen undoes the whole take (the chain from before it kept
  until the next take).
- **An empty cell** gets a new pattern as RETURN makes one: the first free
  number, 16 steps, looping (lengthened on the grid first for a longer
  loop).
- **Quantize:** a Rec Quantize parameter (Off / 16th / 8th / 16th
  triplet, Off at start) applied as the take is merged, the lengths kept;
  Off keeps the exact ticks (rounded to the nearest tick), and C= Q on the
  grid still fixes a step. The player is unchanged. (The plan's "kept
  separately, changeable" becomes: undo the take, play it again.)
- **Thru:** a Thru parameter, On at start: notes, controllers, bend and
  program changes from MIDI in (omni) go out on the channel of the
  cursor's track on the song screen, or of the open pattern's track on the
  grid, playing or stopped, recording or not (section 4 "Thru": through
  the merger, right after clock). Off for keyboards with local sound on.
- **Count-in:** a Count-in parameter, 0 / 1 / 2 bars, 1 at start. Only the
  click plays (SID, and the MIDI note if the Metronome has MIDI), even with
  the Metronome off; no Start or clock goes out until the song starts after
  it. As slave there is no count-in: the master starts the song.
- **The per-bar index** (section 5, the live switch): after recording,
  once merges are measured at 120 and 240 BPM; built only if they miss
  the next pass.
- Recorded velocities are the keys'; controllers and bend thinned as
  section 3 says; aftertouch dropped.

### Thru as built (stage D's first step, 2026-11-22, `src/record.asm`)

- **First in the main loop, measured:** thru through a core hook on each
  parsed message was 16-38 ms late on the band at 120 BPM, up to ~640 ms
  at 295 BPM, and at half the wire nothing got through in the log: the
  main loop is held (busy ticks rendered by the timer interrupt, rows
  waiting for the beam). Recording's stamps would be as late. **The user
  (2026-11-22): parse in the receive interrupt.** Core option
  `MIDI_RX_IRQ` (off by default; the synths byte-identical): every byte
  received but the realtime ones goes into the ring as before, then to
  `synth_rx_irq` (the core's parser still has them: step entry, learn).
- **The parser** (`synth_rx_irq`, `rx_message`): running status, system
  bytes ending it; a whole message, with Thru on, into thru's queue (32
  messages) on the record track's channel (the cursor's track, the open
  pattern's on the grid); an off on the channel its on went to
  (`THRU_HELD`, under I/O), none if its on never went out; aftertouch
  left out. Thru Off sends an off for each note still sounding.
- **Into the merger between whole ticks only** (`thru_one`): never during
  a release (`release_busy`) nor between a tick's parts (`rel_partial`:
  their running status), with room for the whole message in the ring
  (`out_byte` would wait for room with interrupts off: a hang). Sent
  from the IRQ (one message) only when not playing; playing, and from the
  NMI (Namesoft), only queued: sent from the receive interrupt, it was
  right in front of ticks (they were up to ~950 cycles later with it,
  ~450 without), and it bought no lag (the NMI's, queued, was the
  lowest). What waits goes at a tick's start, before its bytes (`release_thru`), after
  the release (`click_midi_send`, `MIDI_SEND_THRU` in `click_midi`), from
  the main loop (`thru_poll`), and between a busy tick's parts when the
  renderer is behind (`commit_release`: all staged bytes out, then the
  renderer's next message given its status again, `last_status`): that
  last one took half the wire from ~190 ms to ~20 ms. Each message inside
  sei on its own.
- **The clock guard:** as master, playing, before a tick with a clock
  (`clock_countdown` 1), thru waits if its message would still be on the
  wire then: the bytes waiting in the ring, its own 3 and the one in the
  6850 (`THRU_WIRE_EXTRA`), 283 cycles each, against timer A's pages to
  the tick. (A fixed ~0.8 ms let a message in behind the player's bytes:
  a clock ~1,600 cycles after its tick.) It goes at the tick's start,
  right after the clock.
- **Measured** (`python tools/thru_check.py`, a keyboard's phrase every
  0.25 s fed through the real receive interrupt: notes, a controller,
  bend, a program change, aftertouch; the feed itself, the raster
  interrupt standing in for the ACIA, costs the ticks ~450 cycles and the
  busy 16ths at half the wire ~20 ms, so what thru adds is measured
  against the same build with Thru off):
  - every message through, in order, on the track's channel, the player's
    messages as the model's and none broken: in to out 1.2-30 ms on the
    band at 120 and 295 BPM and at half the wire, ~3-5 ms stopped;
  - the receive interrupt ~200 cycles longer with Thru on (476 against
    ~280: exact, `TEST_RX_TIME`), all a tick or a clock may wait for it.
    The ticks' and clocks' own lateness (reported): over four runs thru
    adds ~60 cycles to the ticks' 99th percentile and up to ~330 to a
    clock after its tick; single runs' worst vary by ~500 with Thru off;
  - **half the wire with a keyboard played through is overload (the
    user, 2026-11-22)**: its busy 16ths' render takes nearly all the
    time, so thru's ~500 cycles a message make them ~25 ms later than
    Thru off, and in about one run in nine the renderer falls further
    behind as long as the playing lasts (~280 ms, back after it).
    Reported, not checked, as the heavy scene is. Thru there up to ~65
    ms. The renderer's speed (stage D's per-bar index, the busy 16th) is
    what would help.
  - Found on the way: the test's marks of thru's bytes (a bit map) made
    every byte sent slower than the wire; now a list of thru's places in
    the ring, the transmit interrupt looking at the first.

### Recording as built (stage D's second step, 2026-11-22, `src/take.asm`)

- **C= R on the song screen** starts a take on the cursor's cell while the
  song plays (stopped: nothing yet, the count-in is still to come). An
  empty cell gets a new pattern as RETURN makes one (the first free
  number, 16 steps, published empty). The title shows REC instead of
  PLAY. C= R again or a stop ends the take. During a take RETURN does
  nothing, because the step grid's table is the take's. The track and
  pattern are fixed at C= R; thru still follows the cursor.
  (Claude's defaults where 5b says nothing; the user may change them.)
- **The stamp** (`rec_now`, in the receive interrupt, `rec_put`): the
  tick last due (`play_tick` - 1), or the next one when timer A is past
  half its period (rounded to the nearest), and the music's pass as that
  tick began (`TICK_MUSIC`, a ring of 16 that `play_begin` fills: the
  renderer is ~42 ms ahead). With the renderer behind, it is the pass the
  renderer's tick began at plus the ticks between. A place in the
  pattern is the pass modulo the pattern's length, as the live switch
  places a pattern. A take begun before the song's first tick counts
  from pass 0.
- **The ring** (64 messages, under the KERNAL in the grid's step index,
  free during a take): when it is half full (the main loop behind), a
  controller or bend replaces the newest message waiting if that one is
  the same kind and number. A sweep loses points then, but no note is
  lost. Aftertouch is left out.
- **The take** (up to 192 records in the grid's table, its layout; 128
  since the size pass, 2026-11-25): a
  note held has length 0 until its off; an off with no held note is
  dropped (its on came before the take). A controller or bend at the same
  pass as the take's last record of its kind replaces that record's value
  (thinned to a pass).
- **A merge** at each loop's end heard, and at the take's end: the
  finished records up to there go into a list at their places. A note
  held across the loop's end goes in at its start's place once its off
  comes. Notes are quantized to Rec Quantize's grid, to the nearest point;
  one rounded to the loop's end goes to the pattern's start, its length
  kept. The list is sorted (an insertion sort: it is nearly sorted), then
  encoded with the pattern's chain into a new chain, the old event first
  on a tie, and published (`live_publish`: heard from the next pass, by
  the live switch). Replace drops the old events at the places the take's
  first pass has covered: from its start to the loop's end in the first
  merge, the rest in the next.
  - A merge begins only when no edit waits, the list of replaced chains
    has room, and (playing) the last merge has been switched in. Waiting
    for room with the job taken was a deadlock at 240-295 BPM: the job
    keeps the live switch from making the switches that free chains.
  - Each turn does at least 8 pieces (`REC_BURST`, as the live switch's
    `LIVE_BURST`). One a turn took up to ~460 ms on the busy band.
  - The ring is taken during a merge too, except while the take is being
    compacted. At 200+ BPM a short loop's merges come one after another.
  - The pool full: the merge's list is lost (logged in tests).
- **The take's end:** each note still held is closed at the last pass
  heard (at least a tick). The last merge takes everything, at its place
  modulo the length.
- **Undo's chain:** the first merge's publish keeps the pattern's chain
  from before the take (`rec_before`) instead of freeing it. It is given
  to the replaced chains (freed once nothing reads it) at the next take.
  C= U on the song screen puts it back (below).
- **Room (the user, 2026-11-22: code under I/O).** The take's main-loop
  code (its key, start, end, ring taken, merges: ~1.9 KB) is in the RAM
  under I/O. It is copied there with the tables and run with `$01` =
  RAM_ALL: `rec_poll`, `rec_merge_slice` and `rec_key` switch it. The
  interrupts put I/O in themselves. What it calls that touches I/O (the
  timer, the test log, `live_publish`'s log, `song_urgent_cursor`) it
  calls through `*_out` wrappers with I/O in. The stamp, the ring and the
  wrappers stay in ordinary RAM. The release program ends at $5D7D (~640
  bytes left), and under I/O at $DE00 (256 bytes left).
  - The slave tests' feeds moved out from under I/O. Unless the build
    records, the feed and its raster interrupt's code are copied at start
    into the grid's table (unused in those tests); recording builds keep
    them in the program's RAM. The heavy scene fits its slave builds'
    pool again.
- **The hot code's place:** every hot routine is back at the address it
  was measured at (labels compared with the last commit):
  - `rec_init` took 3 bytes of `HOT_PAD`. An `.align` after the readers
    had turned those 3 bytes into 32.
  - The stamp's 17 bytes in `play_begin`: `wheel_free_all` (cold) moved
    to `click.asm`, with a `jmp` and a 1-byte `PLAYER_PAD` in its place.
  - The song screen's 21 bytes (C= R, the title's REC, RETURN during a
    take): `song_cell_write` (21 bytes) moved to `grid.asm`, after the
    live reader.
  - Timed with the stamp jumped over (same addresses): the 295 BPM edit
    switches came out 453-627 ms, against 581-623 with it. So the stamp
    isn't what decides them; the run and the layout after the hot code
    are.
- **The other checks, as run (2026-11-22):** event, timing, play
  (default, sparse, live), slave, transport, click, edit, screen and
  record pass. Three fail at their edges now and then, on the last
  commit's code too (run on a copy of it):
  - `play_check.py --edits`/`--live`: the band at 295 BPM, a switch
    606-627 ms after its publish against the 600 allowed. The last commit
    gave 614 in one of two runs.
  - `thru_check.py`: the band at 295 BPM (its main loop starved by the
    feed, above), a thru message 30-32 ms after it came against 30. The
    last commit gave 33.7.
  - `flash_check.py`: two spots in key script 9 tapped an undo less than
    2 frames after the edit it undoes. That reads as a flash, as design 5
    says (the last commit failed there 1 run in 4). Both now wait a moment
    first. Once, in one of five runs, a step row was 15 frames behind its
    model; it didn't come back in four more runs.
  - `slave_check.py` once gave "639 messages sent, the model 681" on the
    100-to-290 BPM jump, then passed twice.
- **Tests:** `python tools/record_check.py`. TEST_RECORD starts the take
  as the song begins; TEST_REC_END ends it at a play tick, as C= R does.
  A played part (tables.py `take_part`, feed 11) goes through the real
  receive interrupt: notes, a chord whose keys come and go apart, a
  controller swept every 4 ms, bend, a program change, aftertouch, a note
  held over a loop's end, offs as $8x and as velocity 0. Nine runs: a new
  pattern, Overdub on the 5-step lead, Replace on the bass, 16th and
  16th-triplet quantize, 200 BPM, a take ended mid-part. The log has
  every stamp, the take's start, each merge's begin with the messages
  taken by then, and the take's end.
  - Every stamp is within a tick of the tick heard when its last byte
    came (~90 % the nearest).
  - Every merge is as a model of the take merges it, and published where
    the model has one.
  - The player's bytes are the model's (`play_check.Player`), with the
    publishes and switches as logged.
  - The pattern at the end is the model's last merge, byte for byte
    (`tables.encode`), and the pool is whole: every block a pattern's, the
    kept chain's, a replaced chain's or free.
  - Merges are published 52-450 ms after their loop's end on the band at
    120 BPM, and 62-330 ms at 200 BPM: the main loop gets a turn only
    every ~25 ms on the busy 16ths, as the live switch finds. So what is
    played after that much of a pass is heard on the next one.
- **The test feed starves the main loop at fast tempos** (found while
  testing). With the band playing and the feed's raster interrupt (the
  test's stand-in for the ACIA) on, the main loop gets ~200 turns a second
  at 200 BPM, ~120 at 240, ~57 at 270 and none at 295. It is the same at
  the commit before recording, so `thru_check.py`'s 295 BPM run passes
  with the main loop starved: its content is all sent from the
  interrupts. Without the feed the main loop gets ~100 a second at 295
  BPM. Recording is tested up to 200 BPM for that reason.
- **Not yet:** see "Stage D's checks" below (a take ended by a stop and
  a take on Namesoft tested since). (The count-in: "The count-in as built"
  below.)

### The take undone as built (stage D's third step, 2026-11-23, `src/take.asm`)

- **The keys (the user, 2026-11-23: as the step grid's):** C= U on the
  song screen undoes the last take, SHIFT+C= U redoes it. Only the last
  take, on whatever track it was, wherever the cursor is; heard at once,
  playing or stopped. Nothing on screen changes (the cell's number stays).
- **How:** `rec_undo` publishes the kept chain (`rec_before`) again
  through `live_publish` with `rec_hold` set, so the chain it replaces
  (the take's) is kept in `rec_before` in its place: undo and redo are
  the same swap, `rec_undone` saying which way the next may go. Readers of
  either chain are switched by the live rule as for any edit.
- **When not:** during a take, while an edit waits to be published or a
  merge or other grid job is under way, or with the list of replaced
  chains full (the key does nothing; pressed again later it works).
- **Edited since:** `rec_merged` notes the chain the take left
  (`rec_after`), and an undo or redo notes the one it publishes. A C= U
  that finds another chain there (the pattern edited on the grid since)
  undoes nothing and gives the kept chain to the replaced ones. Until
  then, or the next take, the kept chain holds its blocks.
- **A take that made a new pattern:** undone, the pattern stays in its
  cell, empty (16 steps), as the take found it after RETURN's making.
- **Room:** all of it under I/O (156 bytes: the tables there end at
  $DDC0); nothing below the pool moved.
- **Fixed on the way:** R on the song screen without C= went on as key
  code 0, DEL, and emptied the cursor's cell: `rec_key_io` left A as the
  C= test's result (in since recording's core). It keeps the code in X
  now. `flash_check.py`'s key script 4 taps R and U there and checks the
  cell (it fails on the commit before).
- **Tests:** `record_check.py`'s runs 9-12 (TEST_REC_UNDO, TEST_REC_REDO:
  C= U and SHIFT+C= U at play ticks after the take ended): the lead
  overdubbed, undone and redone (every message), undone (the memory at
  the end: the pattern from before the take, the take's chain kept); the
  bass replaced and a new pattern, each undone and redone. The player's
  bytes as the model's with the pattern before the take heard from the
  undo's publish, the take's from the redo's; the pool whole. Not tested:
  the kept chain given up after a grid edit.
- **record_check's rare failures (2026-11-23), what they were:**
  - **The test log (fixed):** `rec_log` stored its value before `sei`;
    the test feed's interrupt (LOG_RX) and the tick's log A over it, so a
    merge's count or the take's end was logged wrong and the model merged
    other messages (4 of 8 runs of the 200 BPM lead failed so; the old
    order failed 5 of 12 again). Same bytes reordered: nothing moved.
  - **The check (fixed):** a thru message between a tick's parts (the
    renderer behind: `commit_release`) makes the player's next message
    carry its status again, a byte the model hasn't; the one-in-8 samples
    then match a byte on. Allowed only with a thru byte sent since the
    last sample that matched (counted in the report).
  - `record_check.py --keep` saves a failing run (log, memory, the stack
    page, registers) to work/, `--load` checks it again, `--repeat`.
- **Found with Fable's analysis (2026-11-23), fixed:**
  - **A crash in a merge:** `rec_time_left`, in the code under I/O,
    switched I/O in to read the 250 Hz tick's timer, so the CPU's next
    instructions came from the chips (single bytes shifted or rotated in
    the free list, CIA2's timers written, the log broken). Only when a
    merge's first 8 pieces of a turn left the tick unpassed: rare under
    the tests' load, likely often in real use on a quiet song. The read is
    in main RAM now (`rec_spare_out`), in `late_code` after the tables so
    nothing before it moves. Any code under I/O must reach I/O only
    through an `*_out` routine in main RAM.
  - **A stamp a tick late:** `render_step`'s `_tick_done` set the phase
    to PHASE_BEGIN before counting `ren_tick` on; `pl_music` is already
    the next tick's pass then, so a receive interrupt in between stamped
    a pass too many (`rec_now`'s "not begun: pl_music"). The two change
    together with interrupts off now (3 bytes; `SONG_PAD` gave them back,
    the code from the song title on where it was). The NMI interface
    (Namesoft) isn't held off by it: open with the take on Namesoft.
  - **A take ended by C= R during a merge** took `rec_last` from before
    the merge (not looked at meanwhile): held notes closed early. The pass
    heard now is taken first.
  - **A publish fewer than the model's** was record_check cutting the log
    where log B (every byte fed and stamped) ended: log A's main-loop
    entries are kept past it now. Behind it: in that run the main loop got
    no turn for ~2.9 s at 200 BPM (the band, a dense recorded lead and
    thru's second stretch: the known overload, the test feed's cost
    included); the last merge was published that late.

### The count-in as built (stage D's fourth step, 2026-11-23, `src/count.asm`)

- **C= R on the song screen while stopped** (master) begins the take on
  the cursor's track at once (as playing: the cell's pattern, or a new
  one) and then the count-in: the Count-in parameter's bars of clicks,
  then the song from its start, recording. Away from the song's start the
  song is reset first (the transport's STOP_RESET, a piece at a time),
  then counted in. Count-in Off: the song starts at once. The title shows
  REC from the key on, and scene 1 its playing mark (the scene to play).
- **In the timer interrupt:** master timer A ticks at the tempo while
  stopped, and its idle path (`count_idle`, after `click_idle`) counts
  the ticks: the beat and bar from scene 1's signature (`click_phase`, at
  the first idle tick, then a beat every `click_len` ticks, the bar's
  first brighter), the click made as `click_beat` makes it with the SID's
  bit forced on and the song's own count (`click_wait`, `click_beat_no`)
  kept; the MIDI note too when the Metronome has it. Two ticks before the
  song's tick 0 it starts the song as SPACE would (`transport_go_start`):
  MIDI start at the next tick, tick 0 (its first clock) a tick after, so
  the count's beat runs straight on into the song's. Nothing else goes
  out before MIDI start: no clock, no notes but the click's.
- **The downbeat played early (Claude's default):** the take is begun
  before the count, so a note played on the song's first beat is never
  lost to the main loop's lateness. Until the song's first tick is due, a
  message is stamped at pass 0 when it comes within `COUNT_EARLY` (6)
  ticks of it (half a 16th: 31 ms at 240 BPM, 62 at 120), and left out of
  the take before that (thru still plays it). From the first tick due on,
  stamps are as ever.
- **Ended (Claude's defaults):** C= R again or SPACE during the count
  ends it: the clicks stop (a click note's off sent), no MIDI start, the
  take ends with nothing in it (an empty cell's new pattern stays, empty),
  the song stays at its start. Once MIDI start has gone (the last tick
  before tick 0) SPACE stops as ever and C= R ends the take at pass 0. A
  Clock change to MIDI ends it too. C= R again during the reset: no
  count-in after it.
- **As slave: not yet.** C= R while stopped does nothing as slave (the
  master starts the song); a take armed for the master's start would need
  its song position: stage G with the slave's song position.
- **Room:** the interrupts' part and small stubs after the tables
  (`late_code`, 235 bytes), the main loop's under I/O (`count_poll_io`,
  `rec_start_any`, `count_begin`: the beat, the bar and the ticks to tick
  0 found there, `count_key_io`: 318 bytes). The callers' `jsr`s point
  there instead (synth_timer's idle path, rx_message's `rec_put`,
  `rec_put`'s and `rec_now_out`'s `rec_now`, synth_tick's `rec_poll`,
  rec_key_io's `rec_start`, the song screen's SPACE and title,
  synth_init's `rec_init`), the same bytes, so nothing before the tables
  moved (label addresses compared with the commit before; the tempo
  tables under I/O moved on, as with each addition there). The program
  ends at $5E60 (416 bytes left below the pool at $6000); under I/O
  $DF08. **THRU_HELD moved to $DF80** (the last 128 bytes under I/O; io_copy's
  whole pages pass over it at start, before record_init clears it): 120
  bytes left under I/O. Variables after the song screen's at $C1ED.
- **The test builds' room:** the heavy test scene's builds had exactly
  the 112 pool blocks it needs, and the count-in took them to 96; the
  record tests' code under I/O ran into THRU_HELD. So the scene's loader
  and track tables went with its streams (`play_data`, the log's RAM, run
  once before the log is cleared; `tp_next` stays in the program in
  TEST_LIVE builds, whose live.asm test reads the streams while playing),
  the record tests' inline code in
  `rec_poll_io` became `rec_test` in main RAM (test builds only), and
  `count_test` lives there too. The heavy scene's builds end at $61D0 to
  $61FD (the slave's, transport_check): 3 bytes from losing a pool page.
  The next main-RAM bytes in test builds need room found first.
- **Tests:** `python tools/count_check.py` (TEST_COUNT: C= R stopped on
  track 9 at the first look; feed 12, notes across the count's end): 1
  bar of 4/4 at 120 BPM (Metronome Off), 2 bars at 240 (SID+MIDI), 2 bars
  of 7/8 at 240 (MIDI), Count-in Off, away from the start (reset first),
  and ended by C= R. Checked: each click on
  its beat's interrupt and no other, the bar's first brighter, the last a
  beat before tick 0; MIDI start at the interrupt before tick 0, its first
  clock at tick 0's; nothing sent before MIDI start but the click notes
  (on at each click's interrupt, each ended); each message fed before tick
  0 stamped 0 within its last 6 ticks, else left out, those after it the
  tick heard; none lost; the take begun at pass 0; ended by C= R: no
  start or clock ever, the take ended, everything off and the song at its
  start. `flash_check.py`'s run 7 (TEST_KEYS=14: C= R on the song screen
  on an empty track, SPACE, C= R through the count into the song, C= R,
  SPACE): no flashes, the title REC during the count-in and the take,
  STOP after SPACE, PLAY after the take; the model has REC now.
- **Fixed on the way:** none needed outside the count-in; the variables
  had first been put over the song screen's ($C165: `song_vars` follow
  the transport's), found by the first run.

### Stage D's checks (2026-11-23)

- **A take ended by a stop** (`record_check.py` runs 15-16, TEST_REC_STOP:
  the song stopped at a play tick as SPACE does, `transport_stop`): the
  take ends with it, its last merge published while stopped, the pattern
  at the end the model's last merge, the pool whole; the player's bytes
  as the model's up to MIDI stop (its note offs are transport_check's).
- **A take on Namesoft** (runs 17-18): stamps, merges and the pattern as
  the model's (five runs of 17 in a row). The receive path there is still
  the test feed's IRQ: the NMI receive path (where a stamp could come in
  the middle of the timer interrupt's update) is untested, as the slave's.
  Found on the way, both in the tests only: the stamps' log entries went
  to log B, which the NMI writes too (each byte sent): now log A; and
  `thru_marked` (the test's marks of thru's bytes, called from the NMI on
  Namesoft) shared its scratch byte with `thru_byte`, so an NMI inside
  `thru_byte` gave it the wrong X and thru's filler $FF went out: its own
  byte now.
- **The player's timing while recording** (runs 13-14, Thru off, one
  byte in 8 stamped, play_check's wire model): the worst added lag with a
  part played in is 2.8-4.0 ms with no take and 3.7-4.5 ms recording (the
  band at 120 BPM, five runs each): each byte's receive interrupt can't
  wait for a tick (the 6850 has no FIFO), and the test logs each byte and
  stamp there too. **The user (2026-11-23): 5 ms, reported**
  (`PLAYED_LAG_MAX`); play_check's 3.2 ms stays for playback alone.
- **count_check's rare "no MIDI start"** (the tests): the run's log cut
  where log B (now only the bytes sent) ended, before anything was sent
  (`record_check.run(cut=False)` for count_check); and the count's click
  logging into log A from the timer interrupt with interrupts on, so a
  fed byte's LOG_RX re-entered the writer and its pages ran out early: in
  test builds the click is made with interrupts off (`click_beat` in the
  playing path logs the same way, after `cli`: the same race with a feed
  and the metronome on, untested so far).
- **The per-bar index:** merges are published 62-365 ms after their
  loop's end at 120 and 200 BPM (the main loop's turns on the busy 16ths,
  not the walk through the pattern); 240 BPM can't be measured with the
  test feed (it starves the main loop there). **The user (2026-11-23): not
  built** (it wouldn't shorten that, and it costs room). Stage D done.

## 5c. Scenes, the song and live play (stage E; settled with the user, from 2026-11-23)

- **The song is the scene rows in order** (the user, 2026-11-23): scene 1,
  2, 3... down the song screen, each for its bars times its repeats (a
  repeats setting on each row), to the first empty scene. A section heard
  again is a copied row: patterns are shared by number, so editing one
  changes every row that plays it.
- **Song mode, as SID808's** (the user, 2026-11-23): Song on, the song
  plays down the rows and loops back to scene 1 after the last; Song off
  (as until now), the playing scene loops until another is launched.
- **Row 1 shows the cursor's scene** (the user, 2026-11-23): its bars,
  signature and repeats, and SONG reversed while Song is on
  (`SONG  SC 05  2 BARS  4/4  X3`). Keys on the song screen: C= S Song
  on/off (S stays solo), C= B / C= N the bars down / up, C= T the
  signature, C= X the repeats (1-9).
- **A launch takes over at the next bar** of the playing scene (its
  signature's bar; the user, 2026-11-23); a second launch before then
  replaces the first. The new scene's tracks start from their patterns'
  beginning (the scene's start is the time they count from).
- **Launch keys** (the user, 2026-11-23): SHIFT+RETURN launches the
  cursor's scene, C= RETURN only the cursor's cell; a launch waiting shows
  '+' after its scene's number (the playing one keeps '>'). Stopped,
  SHIFT+RETURN picks the scene SPACE plays from.
- **A cell launched overrides its track until the next scene** (the user,
  2026-11-23): the scenes stay as they are; the track plays the launched
  pattern from its start, looping, until a scene launch (or the song
  moving on) gives it its scene's cell again. The launched cell shows '>'
  in its gap.
- **By MIDI** (the user, 2026-11-23): on SID500's MIDI channel only (not
  in Omni, as the family's), CC 85 values 0-63 and program changes 0-63
  launch scenes 1-64 at the next bar (as SHIFT+RETURN, Song off); those
  two are then neither passed through nor recorded. Song select turns Song
  on, as SID808's.
- **Claude's defaults where this says nothing** (the user may change
  them): Song turned on while playing goes on from the playing scene (its
  bars times repeats, then the next row); a scene launched with Song on
  jumps the song there; SHIFT+SPACE plays from scene 1 (Song on) or the
  scene picked (Song off); bars 1-8, the signature n/4 or n/8 (n 1-16) as
  until now; the metronome follows the playing scene's signature.
- **Room** (the user, 2026-11-23): the note pool starts at $6800 (its
  first 2 KB for stage E's code; test builds keep theirs from the
  program's end up to the log at $7000). The editor size pass (~1 KB)
  stays for a later stage.

### Stage E as built (2026-11-23, `src/scene.asm`)

- **A launch is made by the player as a tick begins** (`play_begin`,
  wrapped): at a bar line the passes and the ticks are in step (swing
  moves passes only within a pair of 16ths), so a bar's first pass is a
  tick's first. Armed by the main loop (`launch_arm`: the playing scene's
  next bar line past the renderer's pass, `pl_music + 1`), committed with
  interrupts off together with what it launches; a launch made while that
  was computed (`scene_ver`) makes it compute again. Made: a scene's tracks
  each from its pattern's start (`launch_track`, as `player_reset` starts
  them), a cell's track alone (`TRACK_OVERRIDE`, `OVR_SILENT` for an empty
  cell, until the next scene), a live switch half made dropped
  (`pl_jumps`), ACTIVE built again and the 16th's snapshot taken again.
- **Each track's place counts from its launch** (`TRK_ORG`: the live
  switch's place, `live_rel` in `live_target`), so an edit or a cell
  changed later is heard where the launched pattern is; a take begun on it
  counts its loop from there too (`rec_start`). The scene's bars count from
  the bar line armed (`scene_origin`: a launch made late keeps the grid).
- **A take and a launch** (the user, 2026-11-23): when a launch changes the
  take's track (a scene launched, or a cell on that track), the take ends
  at that bar line, as C= R: messages heard from it on are left out
  (`rec_put_count`), and once it is heard `scene_poll` ends the take
  (`take_cut`). A take records the cursor's cell, as in stage D: with the
  cursor on another scene than the playing one, its pattern may not be
  the one its track plays (**open**: a question for the user when it
  comes up).
- **SHIFT+SPACE with Song on plays from scene 1** (`count_key`); Song off,
  from the scene SHIFT+RETURN picked while stopped (`start_scene`).
- **A launch's '+' is drawn at once:** the key makes the cursor's row
  urgent; the other rows' marks follow a row at a time.
- **The song** (`scene_poll`, Song on): the next row's scene armed at the
  playing one's start + its bar x bars x repeats, scene 1 after the last or
  an empty row; kept there while nothing of the user's is armed (a launch
  by hand with Song on: the song goes on from it).
- **A launch never needs undoing at a stop:** the lead is at most 8 ticks
  (240 BPM), shorter than a 16th, so a stop locates to a 16th the renderer
  had reached, or one after the launch (a slave's first lead of 14 ticks,
  before its master's tempo is known, is the one exception).
- **The metronome** follows the playing scene: at a launch, its next beat
  is the launch's tick in the new signature (`launch_click`, the tick due
  then: the lead is shorter than a beat, so the old scene's next beat is
  there too); after a stop, `click_phase` (wrapped) points click.asm's own
  at the scene's signature and its tick from the scene's start (patched
  operands, guarded by the routine's size); the count-in counts in the
  starting scene's signature.
- **MIDI:** `rx_message` (wrapped) takes CC 85 and program changes 0-63 on
  SID500's channel as launches (`midi_ask`, made by `scene_poll`), not
  passed through or recorded; `synth_rx_irq` (wrapped) catches song select
  (Song on) without the core's MIDI_SYSTEM option, which would have moved
  the core's code before the hot code.
- **The screen:** row 1 (`scene_row1`); the title's scene; '>' and '+'
  after the scene's number, '>' or '+' in a cell's gap (`song_scene_line`,
  wrapped); every scene row drawn again at a launch armed, made or dropped
  (`scene_ver`), row 1 when its values change.
- **Nothing before the tables moved:** the routines it changes are renamed
  and wrapped (`play_begin`, `player_reset`, `live_wanted`, `song_prepare`,
  `song_scene_line`, `rx_message`, `synth_rx_irq`, `rec_key`,
  `click_phase`), the in-place changes keep their sizes (`player_reset`'s
  `jsr scene_cell`, `live_target`'s `jsr live_rel` and nops, the playing
  scene's number in zero page in song.asm, edit.asm, grid.asm). The zero
  page has room for one byte in the test builds (`play_scene1`).
- **Room:** ~2 KB of code after the tables (shrunk from ~2.4: the
  variables at $CF00 after the song's data, click_phase a wrapper, one
  change counter for the marks; then the fixes): the program ends at $671B (229 bytes
  below the pool at $6800); under I/O $DF1C. **The test log moved** from
  $7000 to $7A00 with 7 pages an array instead of 8 (logs 12.5% shorter),
  so the test builds' pools (from the program's end) still hold the heavy
  scene's 112 blocks.
- **Tests:** `python tools/scene_check.py` (TEST_SCENES: scenes 2 and 3
  from the band's patterns, 1/4 x3, 3/4, 5/8): Song on looping at 120 and
  240 BPM, launches by hand (scenes and a cell) at 120 and 240, and by
  MIDI (feed 13: CC 85, a program change, song select, and two messages
  that are passed through). Checked: each launch at its bar line (the
  song's end, or the next bar line past the renderer's pass when armed),
  every byte as play_check's model with the launches, every click on its
  scene's beats, thru only the others. `flash_check.py` run 8 (TEST_KEYS=15:
  row 1's keys, a scene and a cell launched, Song on): no flashes, every
  row as the model's (row 1, the title's scene, the marks), and each key's
  effect checked in memory. Since: swing 15 runs (the bar lines still a
  tick's start), stops just after a launch and inside a 3/4 scene each
  continued (every note after a continue as the model's from its song
  position, the clicks in the scene's signature), a cell changed after a
  launch (a live switch placed from the track's start: the model keeps each
  track's origin), and a take begun after a launch (its loop from the
  track's start, ended at the next launch). `screen_check.py`'s key script
  15 times stage E's keys: within a frame on the band (a launch's '+' up to
  17,600 cycles), within 66 ms at half the wire (its 80 ms rule).
  `transport_check.py`'s feed 7 events brought closer (its last stop's
  note offs had fallen past the shorter log's end). The real program boots
  with the pool at $6800, 704 blocks free.
- **Found on the way:** `bar_passes` used the scratch byte `scene_poll`
  kept the next scene in (scene 48 launched); `scene_empty` set its flag
  before restoring X with `ldx` (the empty scene 4 launched); the song's
  next launch computed from a scene just replaced (a wrong launch armed
  for a moment: `scene_ver`).

### The size pass (2026-11-24, `src/size.asm`; the user: the room for stage F from a smaller program first, then the note pool)

- **The swing rows made, not stored:** `swing_counts` (16 rows of 24, 384
  bytes) is made when Swing is set (`player_set_swing`, a wrapper): the
  music's tick m at tick (m (12 + s) + 5) div 12 in a pair of 16ths' first
  half, 12 + s + ((m - 12)(12 - s) + 5) div 12 in its second (s the delay,
  `swing_ticks_tab`); `tables.py` checks this gives the table exactly. Two
  rows of 24, the one not in use made, then `pl_swing_row` switched with
  interrupts off.
- **The slave's lead a shorter table:** `slave_lead` is 1 from period
  high byte 108 on, so 108 entries and a compare (`slave_lead_x`, `_y`: the
  two reads became same-size `jsr`s). Computing it instead (13 thresholds)
  made the clock's tick ~300 cycles later in slave_check: the clock's
  interrupt asks at every clock, with a period that alternates by a byte.
- **launch_bar shorter:** the bar line is x less its place, the loop that
  follows adding a bar while not past the renderer; one commit shared with
  `launch_arm_at`.
- **377 bytes in all, nothing before the tables moved:** the program ends
  at $65A2 (606 bytes below the pool at $6800). The editor's own code
  (song, grid, edit, undo: ~9 KB) lies before the core's keyboard code,
  whose place once moved the 240 BPM burst timing (design 7, `SONG_PAD`):
  shrinking it means measuring that again, so it is left for when the room
  is needed; the note pool is the next source (the user's order).

### The size pass, second part (2026-11-24; the user: "shrink code first", not the pool)

The event list's first step took ~1,550 bytes against 606 free. Found
without moving any code that is timed:
- **The tempo computed** (`src/size.asm` `tempo_period`): the four tables
  of 201 under I/O (`tempo_latch_lo` / `_hi`, `tempo_frac`, `tempo_lead`,
  804 bytes) became (TEMPO_DIVIDEND + BPM div 2) div BPM, 32 shifts
  (~1,500 cycles, with interrupts on; only the three stores under `sei`),
  and the lead 1 plus the 7 Tempo values where it grows
  (`tempo_lead_steps`). `tables.py` asserts the formula gives the old
  tables at all 201 Tempos (no ties to round); `tools/tempo_check.py`
  runs the 6502 code for every Tempo in VICE (TEST_TEMPO_ALL) and
  compares every byte. `player_init` and `player_set_tempo` became 15
  bytes shorter: `HOT_PAD` took them, so `synth_timer` and everything
  after it up to the tables stays where it was.
- **Two more places for code, copied at start** (`list.asm`
  `io_copy_all`, in `io_copy`'s place): `HI_CODE` $FF80-$FFF9 under the
  KERNAL (free after the snapshots and TICK_MUSIC; RAM with $01 = $35, so
  no switching: the tempo code, 108 bytes) and `LO_CODE` $0334-$03FF in
  low RAM (the tape buffer and the bytes after it, which the KERNAL's
  disk routines leave alone: its file tables are $0259-$02A6, its vectors
  $0300-$0333; the list's keys, 201 bytes), and `LO2_CODE` $02A7-$02FF
  (after the KERNAL's variables: `list_pair_safe`, 77 bytes), and
  `LO3_CODE` $0200-$0258 (BASIC's input buffer: `list_div`, `list_pitch`,
  89 bytes). **For stage G:**
  while the disk code has the KERNAL in, `HI_CODE` is ROM (nothing may
  call the tempo code then); and whether JiffyDOS or a fast loader the
  user's drives use touches $0334-$03FF is to be checked then.
- **The list's row builder under I/O** (in the tempo tables' room), behind
  a main-RAM stub (`list_io`); nothing there reaches I/O.
- **Test builds:** the take's test logging moved out of its code under
  I/O into main RAM (`late_tests`, a section after `late_code` so nothing
  there moves). The heavy test scene still fits its logging builds' pool
  (they end at up to $6BE5, $6C00 the limit).
- **Checked:** every label from `synth_timer` to the scene code's end is
  at the same address as before in all 99 test configurations the check
  tools build (a matrix assembled after every change).
- **Room after the list's first step:** the program ends at $6710,
  under I/O at $DF5D (the test builds ~$DF6C), `HI_CODE` 14 bytes left,
  `LO_CODE` 3, `LO2_CODE` 12, `LO3_CODE` ($0200-$0258: `list_div`,
  `list_pitch`) none. Then **the pool from $7000** (the user, 2026-11-24:
  2 KB more for the rest of stage F; 20 KB, 640 blocks): 2,288 bytes below
  it. The heavy test scene's logging builds end at up to ~$6BD0, their
  pool's limit $6C00 (their pool runs from the program's end to the log):
  stage F's next code will need another answer there (a smaller log, or
  that scene's patterns made in its own room).

## 5d. The event list and the family's names (stage F; settled with the user, 2026-11-24)

- **The event list is the step grid's other view** (the user): on the
  grid a key (F3: Claude's default) flips the same pattern between the
  grid and the list, the cursor on the same event; RETURN still goes back
  to the song screen. Every event in order: position, the note or the
  controller, bend or program, value, velocity, length.
  `PAT 001  TRK 01  LEN 016  LIST   PLAY`, then rows like
  `1.1.00     C-3          100  0.0.12`.
- **Editing by fields with + / -** (the user): cursor up / down moves
  between events, left / right between the fields (position, the note or
  value, velocity, length); + and - change the field by one (a tick, a
  semitone, 1), SHIFT by more (a 16th, an octave, 10). INST (SHIFT+DEL)
  inserts a copy of the event at its place, DEL deletes it. Each edit heard
  at once and undoable (C= U), as on the grid.
- **Family synths by MIDI channel** (the user): a setting per channel
  (none / SID303 / SID808 / SID101), cycled by a key on the song screen
  for the cursor's track's channel (C= Y: Claude's default); every track on
  that channel shows the names; a letter in the header (3, 8, 1).
- **The names** (the user): SID808's drums by note (its 3-letter sound
  names) and each synth's controllers by name (33 in all, 8 letters), taken
  from the synths' own sources at build time so they never drift; program
  changes as numbers (the presets are the user's editable banks).
- **Claude's defaults where this says nothing:** positions as
  bar.beat.tick (48 ticks a quarter, 24 an eighth in n/8, from the playing
  scene's signature), lengths the same; 16 events a screen, scrolling; the
  drum names on the step grid's note columns too for an SID808 channel; an
  event's kind not changed in the list (delete it and enter another).

### The event list as built: the view (stage F's first step, 2026-11-24, `src/list.asm`)

- **The step grid with `grid_view` set:** `song_mode` stays MODE_GRID;
  song.asm's jumps to `grid_key`, `grid_prepare`, `grid_cursor_screen`
  and hooks.asm's to the MIDI step entry go to `list.asm` first (same-size
  jumps), which hands them on when the grid shows. F3 on the grid shows
  the list, F3 on the list the grid; RETURN goes back to the song screen
  from either (the grid shows the next time); RUN/STOP plays and stops;
  C= K the metronome. MIDI step entry only on the grid.
- **Rows:** the title as the grid's with "LIST" for the steps; a header;
  16 events a page (pages as the grid's: Claude's default, the user may
  prefer scrolling), every event in the table's order up to the pattern's
  length (those past a shortened end aren't shown, as on the grid); then
  an END row at the pattern's length, where the cursor can be (an empty
  pattern's place). A row: the position (bar.beat.tick from 1.1.00,
  right-aligned), the note (C-4) or the kind (`CC  74`, `BEND`, `PROG`),
  the value (a controller's, a bend's less 8192: -8192 to 8191, a
  program's from 1), a note's velocity and length (bar.beat.tick from
  0.0.00; bars over 99 shown as 99). The position grey, the rest in the
  track's colour.
- **The cursor** is a field: the position, the note or value, the
  velocity, the length (a note's four, another event's two, the END
  row's one), its 3 characters reversed (the position's and length's last
  3, the value's last 3): so a move across a row changes at most 6 cells,
  which `song_put_line` puts at once, and a move up or down goes through
  the grid's pair (3 cells). CRSR down / up the events (a page turned when
  the cursor leaves it), right / left the fields, round. A field the next
  row hasn't: its last.
- **Between the views:** the grid's cursor note (its column's, as
  `edit_find` counts) is the list's cursor, on its note; a column without
  one: the step's first event (the first at or after the step's start,
  or END). Back: the event's step, the column whose note it is (not a
  note, or past the 3 columns: the first); the END row: the last step.
- **A page turned, the old cursor put back in the moment the new one is
  drawn** (as a move up or down). The put-back had been made for rows next
  to each other: with rows far apart, the beam between them showed one
  before the moment and the other after it, no cursor or two for a frame
  (the picture is what the beam drew). `list_pair_safe` (in
  `song_put_safe_now`'s `jsr song_row_safe` for the pair's row: an operand
  changed, nothing moved) also waits for the beam not to be between them.
  **Found on the way: the step grid's page turn** dropped the put-back
  and showed two cursors for ~10 frames (no check had turned a grid page);
  now it keeps it too (`grid_move_by`: the same number of bytes). An
  undo's far move goes through the same wait.
- **F3 is a switch of screens** for the checks (every row drawn again): the
  old view's cursor stays until its row comes, 3-6 frames, as when the
  grid opens.
- **Checked:** `flash_check.py`'s run 10 (TEST_KEYS=16: the pad's program
  change, controllers, chord and bends; the many notes' pattern across a
  page and back, F3 both ways; on the grid the pattern 4 steps longer and
  a page turned and back) against a model of the list (`list_model`): no
  flashes, one cursor, every row as the model's.
- **Timed** (`screen_check.py`, TEST_KEYS=16; a row's builder ~2,500-3,000
  cycles after making `list_div` 8 steps for a byte and the row's fill 4
  places a pass): a move or a field within a page a median ~11,000 cycles
  on the band, ~7,000 on the light scene. Over a frame: F3 (~21,000-27,000
  on the band) and page turns (~21,000-35,000; the wait for the beam clear
  of the 16 rows between the cursors is up to ~8,000), and now and then a
  move that lands on a busy 16th (up to ~24,000), as the grid's edits do.
  At half the wire up to ~90,000. **The user (2026-11-24): F3 and page
  turns held as edits** (2 frames, 100 ms at half the wire); the script's
  every key is held so (its moves too: they can't be told apart in the
  log), those over a frame reported.

### Editing in the list as built (stage F's second step, 2026-11-24, `src/list.asm`)

- **+ / -** change the cursor's field by one, SHIFT by more: the position
  a tick or a 16th (within the pattern's length), a note's pitch a
  semitone or an octave, a value (a controller's, a program's number, a
  bend's high 7 bits: Claude's default, a step of 1 in 16384 being too
  small to hear) 1 or 10, the velocity 1 or 10 (1-127), the length a tick
  or a 16th (1-65535). A field at its end changes nothing (its row drawn
  all the same). The position: the event taken out and put in at its new
  place (gone later: after the events on that tick; earlier: before them),
  the cursor with it, kept for undo as a delete and an insert.
- **DEL** takes the cursor's event out (the cursor on the next, or END);
  **INST** (SHIFT+DEL) puts a copy in after it, the cursor on the copy
  (not with the table full). Neither on the END row.
- **Undo** (C= U, SHIFT: redo) as the grid's (`undo.asm`'s entries: a
  range of one record, a delete, an insert), the list's cursor on the
  event changed.
- Each edit published as the grid's (`edit_touch`), heard at once while
  playing.
- **Drawing:** the old cursor marked before the edit and put back with the
  new one; the rows from the higher of the two down to the page's end
  drawn again (the events below them moved), every row only when the
  cursor goes to another page. (Every row after each edit, and each key
  starting the rows over, left rows near the top old for ~25 frames on
  the band, with a second cursor meanwhile.) An edit in place, its cursor
  on the same row: that row drawn whole (`list_urgent_cursor`: the draw
  left the old cursor's row for its put-back, so it waited on itself).
- **Checked:** `edit_check.py` (TEST_KEYS=17: the pad, playing, edited by
  every field, its note and a controller moved, a bend deleted, another
  copied, the program changed; two undos and a redo: its stream as
  encode()'s of the model's events, the pool whole); `flash_check.py`'s
  run 11 (the same script: no flashes, one cursor, every row as the
  model's); `screen_check.py` times the edits (TEST_KEYS=17, as edits).
- **Room for the test builds** (the user, 2026-11-24: the log 6 pages an
  array): the heavy test scene's logging builds (TEST_PLAY=2) have a log
  of 6 pages an array (1,536 entries a log, from $8400), so their pool
  from the program's end holds the scene again. In every build at first,
  it cut record_check's, transport_check's and screen_check's runs short
  (their logs ended before their scripts): the others keep 7 (from
  $7A00). The tools find each build's log in the program (`log_layout`:
  "SID500LOG", its page, its pages; `timing_check.log_layout`).
- **Found while timing it:** SHIFT's own press (the core passes it to the
  screen's keys) had marked the old cursor in `list_key_more`, and nothing
  drew after it: the cursor's row waited for a put-back that never came
  (keys up to ~960,000 cycles late). Only + / - and DEL mark it now.

### The family's names as built (stage F's third step, 2026-11-24, `src/names.asm`)

- **The setting:** a byte per MIDI channel, `CHANNEL_SYNTH` at $C9C0 (the
  song data's free bytes after the scenes' repeats: saved with the song in
  stage G), 0 none, 1 SID303, 2 SID808, 3 SID101; cleared at start. C= Y
  on the song screen steps the cursor's track's channel's round (none,
  SID303, SID808, SID101). The header shows the synth's digit (3, 8, 1),
  white, in each track's number's first place (always blank: tracks 1-16),
  on every track of that channel.
- **The names from the synths' sources** (`tables.py` `family_names`, run
  at every build): each synth's controllers from its `src/params.asm`
  `cc_numbers` and `cc_params` and its parameter names (`param_names`),
  SID808's drums from its `tables.py` `GM` map (notes 35-75, 13 sounds,
  their 3-letter names). Names over 8 letters have short forms in
  `tables.py` `SHORT` (Claude's: Reso, Slide, Amp dcy, Voice md,
  Pls/sync, Pulse w, Sync pch, Chord sp, LFO shp, LFO dly, LFO cut, Mod
  whl, Glide md, Arp rng); a new long name fails the build until it has
  one. 46 controller names in all (SID303 8, SID808 5, SID101 33), in
  the synths' own case.
- **Shown:** on the step grid and in the list, a note on an SID808
  channel by its drum's name (one without a sound: its pitch); in the
  list, a controller of the channel's synth by its name in the event's 8
  places (one it hasn't: "CC" and the number). Programs stay numbers.
- **Nothing moved:** song.asm's calls of `song_prepare` and `click_key`
  go to `names_prepare` and `names_key` (same-size changes); the grid's
  pitch code became a call of `name_note` and a jump, filled to its old
  46 bytes (`GRID_PITCH_SIZE`). The names' tables (~540 bytes) after
  `late_code`'s code. The program ends at $6DEC (532 bytes below the
  pool).
- **Test builds:** the half-the-wire scene's logging builds (TEST_PLAY=4)
  lost their pool's room to the tables too: they have the 6-page log as
  well (the user's answer for the heavy scene's). The take tests' builds
  (TEST_RECORD) need the 7-page log (their logs must reach two loops past
  the part) and their takes the pool: with the tables they had 16 blocks
  and record_check failed (the pool full; 88 blocks before stage F's
  list). Empty names' tables gave 32, still too few. **The user
  (2026-11-24): those builds without the list's and the names' code**
  (they never open the grid): `list.asm` and `names.asm` give only their
  hooks' targets there (the grid's and the song screen's own routines,
  `io_copy_all` copying the tempo code, `name_note` the pitch), so the
  timed code is where it is in every build; 80 blocks, record_check
  passes.
- **Checked:** `flash_check.py`'s run 12 (TEST_KEYS=18: channel 10 set to
  SID808, the pad's channel 3 to SID101 (the lead's too), the drums and
  the pad on the grid and in the list, the setting back to none) against
  the model, which takes its names from `tables.py` the same way.

## 5e. Song position, disk and SysEx (stage G; settled with the user from 2026-11-24)

- **The order** (Claude's suggestion, the user went on with it): the
  slave's song position first (no new room), then disk, then SysEx.
- **Song position as slave** (the user, 2026-11-24): as the family's:
  only with Clock on MIDI and stopped (ignored while playing); located at
  once (the song prepared from that 16th, the lead rendered), so the next
  Continue plays there on time. With Song on, positions count through the
  song's scenes and repeats, wrapping at its end; with Song off, within
  the playing scene's loop. Start plays from the song's start.
- **The song's start prepared while stopped as slave** (the user, first
  chosen; withdrawn the same day, below): after a stop as slave the
  song's start prepared, so a Start on time.
- **The stop's place kept instead** (the user, 2026-11-24, after it was
  measured): preparing the start made a bare Continue (no song position
  first: some hardware masters) 70-145 ms late with the band, where it
  was ~1 ms. So after a stop the song stays ready at the stop's 16th, as
  in stage A: a bare Continue on time, a Start away from the start ~29 ms
  late (accepted before), a song position and Continue ~55 ms (the
  locate).
- **C= R as slave while stopped arms the take** (the user): the title
  shows REC, the take begins with the first tick the master plays (Start,
  or Continue after its song position); no count-in clicks (the master's
  own, if any); C= R or SPACE again disarms it. Notes before the
  master's first tick are left out (thru plays them; the user,
  2026-11-24: a slave can't know when that tick comes).
- **Song off: from the start scene** (the user, 2026-11-24): a song
  position counts from the scene Start plays from (`start_scene`), each
  track at its own length, so position 0 plays what Start would (not the
  scene last playing after a live launch).

### Song position as built (2026-11-24, `src/locate.asm`)

- **Parsed in the receive interrupt** (`synth_rx_irq`, before scene.asm's
  own, now `synth_rx_irq_scene`): $F2 and its two data bytes; a whole one
  as slave while stopped (or held: a stop's pieces under way) holds the
  player (`PLAY_HELD`) and asks for a locate (`spp_ask`); playing, it is
  ignored. The Continue after it waits in `slave_req` as ever.
- **The locate** (`locate_poll`, in transport_poll's place in synth_tick):
  as scene.asm player_reset (no launch, no cell launched, a live switch
  not yet made dropped) without the wheel cleared again; the scene there
  (`locate_scene`: with Song on, the rows walked with each scene's bar *
  bars * repeats, the tick brought within one round of the song from
  scene 1 the first time it is reached (`locate_round`); Song off, the
  start scene); the music's pass (`locate_music`: whole pairs of 16ths
  24 passes, an odd 16th the swing row's first 12); then each track as a
  launch (`launch_track`) from the scene's origin, its place modulo its
  length, its reader read up to it, a track a call (`LOC_TRACKS`, at once
  with a Continue waiting). Then (`locate_done`) the wheel cleared and
  the 16th made the song's as a stop's (`stop_there`, its last pieces;
  with a Continue waiting all at once, `stop_unlimited`, and only the
  first tick rendered before it goes). A song position during a stop's
  pieces waits for them, the Continue hidden from transport_poll till
  the locate (`_hold`). At the place already: nothing done.
- **Measured** (the band, 120 BPM): song position + Continue as DAWs send
  them (3 byte times apart): the first tick ~50-58k cycles after the
  first clock (~55 ms), then caught up (transport_check's LOCATE_MAX 80k);
  without the cuts (the wheel cleared twice, the lead and the stop's
  pieces a piece a tick) it was ~110-140k.
- **Checked:** `python tools/transport_check.py` (feed 14: song positions
  37, 0 and 333, a bare Continue, a Start after stops; swing 0 and 15:
  every byte as the model's played from the song's start to the 16th);
  `python tools/locate_check.py` (feed 15, scene test 1, Song on: the
  slave located to 16ths 20, 30 and 46 (once round) sends what a master
  build sent from that tick, but for offs of notes begun before it).
- Fixed on the way: `locate_len` kept the scene number in `sc_tmp`,
  which `bar_passes` uses itself (every scene's length wrong).
- **Two song positions in a row** (as a DAW sends while its locator is
  moved, then one more with the Continue): the second came during the
  first locate's own last pieces (the wheel cleared, the lead rendered:
  no Continue waiting, a piece a tick), waited for them, and the slave's
  first tick was ~139 ms late. Now a song position drops a locate's own
  pieces (`loc_pieces`: they are superseded) and locates at once (~45 ms
  late); a stop's pieces (offs to send) are still done first (`_hold`).
  Running those pieces all at once instead had let the Continue go from
  the first position during the long call.

### The armed take as built (2026-11-24, `src/locate.asm` count_arm ...)

- **C= R stopped as slave** (`rec_start_any` -> `count_arm`): the take
  begun at once as the count-in's is (`rec_start_now`: the cursor's cell's
  pattern, a new one in an empty cell), `count_state` COUNT_ARMED (4): the
  title shows REC (`count_state_check`), nothing is stamped
  (`rec_put_armed`, in rec_put_count's place in rx_message: a message
  only once play_tick is past `locate_tick`, the tick the song plays
  from), no clicks (`count_idle` acts on COUNT_TICKING only).
- **The master's first tick heard** (`count_armed`, from count_poll_io in
  the main loop): the take's place from that tick (`count_place`: its pass
  as it began, TICK_MUSIC[locate_tick], valid while fewer than 16 ticks
  are rendered past it, else the pass heard now with the ring's stamps
  dropped; then as rec_start: the loop's start from the track's place
  modulo the pattern's length), so a song position or a reset after
  arming is followed; the stamps since the first tick kept; then a take
  as ever (merges at the loop's ends, ended by C= R or the stop).
- **Disarmed** by C= R or SPACE (REC_STOPPING, as during a count-in) or
  Clock made the C64's: the take ended with nothing in it.
- The code is after the frozen code (in locate.asm), the callers
  redirected the same size (record.asm's `jsr rec_put_armed`) or under I/O
  (`rec_start_any`, `count_poll_io`: 8 bytes).
- **Checked:** `python tools/locate_check.py`'s armed runs (feed 16: armed
  at start-up on track 9, song positions 20 and 37, Continue, a part: the
  4 messages before the first tick left out, the 66 after it stamped
  within 0.23 ticks of the tick heard, the start at 16th 37's pass, 3
  merges, the take ended by the stop; disarmed by SPACE or by Clock:
  nothing stamped). Not checked: the merged pattern byte for byte (the
  merges are record_check's, the take's place given).
- click_check's sound check had failed now and then since it was added
  (the same with the build before this work, 2 runs in 4): VICE's
  start-up sound lands a beat before the first click at times and was
  taken as one. It is dropped when the pattern holds without it.

### Disk (stage G's second part; settled with the user from 2026-11-25)

- **The disk code is an overlay** (the user, 2026-11-25: "loadable code
  blocks", loaded over what isn't needed meanwhile): a file of its own,
  loaded when the disk screen opens (on the song screen, stopped) into
  the grid's edit table under the KERNAL ($E000-$EBFF, rebuilt whenever
  RETURN opens a pattern; the step index after it holds the take's
  ring), so nothing has to be loaded
  back afterwards. It runs with the ROMs out; the KERNAL's routines are
  reached through a trampoline in main RAM (the KERNAL banked in around
  each call: code under the KERNAL can't call it directly). Resident: the
  trampoline and the overlay's loader (~150-250 bytes). The note-off map
  ($F000-$F7FF, refilled with NO_ENTRY afterwards) is room for more if
  needed. The SysEx dumps can be a second overlay in the same place. The
  overlay file must be on the disk in the drive when the disk screen
  opens (the program disk, or a copy on a data disk).
- **A song file holds the patterns' events** (the user, 2026-11-25):
  each pattern's chain walked and its events written in order, the free
  blocks left out; a load builds the chains again in a fresh pool. The
  file grows with the music (an 8-bar band song ~3-5 KB), doesn't depend
  on the pool's address, and has a version byte in its header so later
  formats still load the old ones. The song data ($C800-$CFFF) beside it.
- **Every parameter saved with the song** (the user, 2026-11-25): the
  setup too (Clock, the metronome, recording, MIDI channel, interface,
  paddles), so a load restores the whole state.
- **The keys: the family's, and a directory** (the user, 2026-11-25): on
  the song screen, stopped, C= W saves and C= L loads; the title row asks
  for the file name (the last one used, at first "song"; letters, digits,
  space, + - . ; DEL, RETURN goes, RUN/STOP cancels), then shows the
  drive's message (00, OK / 62, FILE NOT FOUND / NO DRIVE 9 / NOT A SID500
  FILE). A save replaces a file of the same name. C= D lists the disk's
  songs on the screen with a cursor to pick one to load. A new parameter
  **Disk drive** (8-16, at start the drive SID500 came from), the one
  parameter not saved with the song.
- **Songs by a suffix** (the user, 2026-11-25): a save adds ".s5" to the
  name (not typed, not shown: 13 characters typed of the 16), and C= D
  lists only the files ending in it; a load looks for the name with it.

### Save and load as built (2026-11-25, `src/disk.asm`)

- **The overlay** ("sid500 disk", built from the same source: `build.sh`'s
  second 64tass line, `-D DISK_OV_OUT=1 --output-section=disk_ov`; in the
  program's build only its addresses, `.virtual`, so the labels always
  agree) at $E000, up to the grid's step index ($EC00: the take's ring
  and variables after it, the editor's at $EE00-$EFB4, so not $EE80 as
  first written). Its first 6 bytes (`ov_id`: "S5", $A5, "D", the build)
  say it is there: an edit table record's third byte is its type (0-3),
  so a decoded pattern, a take or an edit always spoils them; a missing
  overlay, or another build's, is loaded again ("NO SID500 DISK FILE" on
  the title when it can't be). ~2.1 KB of its 3 KB used.
- **The disk mode** (`disk_in`, `disk_out`): CIA1's interrupt sources
  off, the ACIA reset; our zero page to `ZP_OURS` (the note map's page 0:
  nothing sounds while stopped, `wheel_clear_page` refills it) and
  **zeros in its place for the KERNAL** (no file open, no messages): no
  room for a lasting copy of its own. Start-up copies the KERNAL's zero
  page (core `KERNAL_ZP_COPY`, $F100: the note map's page 1, cleared
  later) only for its last drive, the Disk drive parameter's default
  (`disk_init`). Afterwards the core's tick (timer B), the player's timer
  (`player_go`), the time base (`time_init`: CIA2) and MIDI (`midi_init`)
  as at start, no ticks to catch up.
- **The KERNAL from the overlay:** through `kcall` (copied to main RAM at
  $CFxx by the overlay: the KERNAL in around the call, A, X, Y and the
  flags kept both ways). What the KERNAL reads itself must be in main RAM
  too: the file name for OPEN (`disk_cmd`, $CFxx; first put in the
  overlay, the KERNAL read its own ROM there: "NO DRIVE 8"). The overlay's
  code in the disk mode uses only $FB-$FE of zero page.
- **Where the resident parts went** (227 bytes were free): main RAM
  (`late_code`): the keys' hook, the overlay's loader, `disk_init`, the
  rows' hook; $0237 (LO3): `ov_valid`, `ov_id`, the keys; the wheel's gap
  $FB10-$FB7F (new `HI2_CODE`, copied at start: CHANNEL_FIRST is 16
  bytes, OFF_SLOT starts at $FB80): `disk_may`, `disk_in`, `disk_out`;
  `HI_CODE`: the message's row; under I/O: its text. The overlay's file
  name sits where `io_copy` was (now in `late_code`) with `IO_COPY_PAD`:
  the Disk drive parameter made the parameter tables 18 bytes longer, and
  the tables after them (`slave_lead_tab`, `swing_ticks_tab`) stay where
  they were. `build_matrix.py` lets the parameter screen's tables and
  texts move (and `io_copy`, the core's test feed after them).
- **The hooks:** same-size `jsr`s in place: song.asm's `names_key` to
  `disk_key`, names.asm's `song_prepare` to `disk_prepare`, synth_init's
  `io_copy_all` to `disk_copy_all`; the core's 10-byte zero-page copy at
  start taken from `HOT_PAD` (25 now): nothing from `synth_timer` on moved
  in any configuration.
- **When:** `disk_may`: stopped, no edit being encoded, no take, count-in
  or armed take, no live switch (each 0 when idle); asked again at RETURN
  (a master's Start as slave meanwhile: "STOP FIRST").
- **A load** is read into place in the disk mode: the parameters into
  `ZP_OURS`'s copy, the song data's runs, the patterns' blocks one after
  another from `POOL_START` (their links written as they come); then, with
  our zero page back, the free blocks chained after them, every value
  made safe (cells, repeats, bars, signatures, channels, the tracks' order
  a permutation, the synths, the parameters at most their maximum),
  the scenes' state (`scene_init_vars`, a label added in scene.asm), no
  undo, no take, the transport and live switch idle, the screen afresh,
  Swing and Thru applied, `player_init` (the tempo, the clock). A header
  that isn't ours, or a file not there, changes nothing; a file that ends
  early or holds more blocks than the pool leaves an empty song.
- **The Disk drive parameter** exists only in builds with the disk (the
  logging test builds have none: their zero page was full, $100).
- **Room after it:** the program ends at $73FD (3 bytes below the pool),
  LO2 3, LO3 2, `HI_CODE` 2, HI2 8 (2 in the raster test builds), under
  I/O 27, the variables at $CFxx 23; the overlay ~900.
- **The "no overlay" message** goes at a key's press, not a release, and
  not C='s own (pressed with the letter in one scan, its press comes
  after the letter's: it had cleared the message at once).
- **The old checks with it** (2026-11-25): all pass but the known edges,
  which the last commit fails the same way (thru at 240 BPM 30.6-32.4 ms
  of 30; screen_check's list keys at half the wire 100,532-100,673 cycles
  of 98,500); locate_check's armed run once stamped a note a tick early
  (1.22 ticks off), then passed three times: a rare race in the test.
- **64tass:** its `gcs`-style "long branches" are not conditional here (a
  `gcs` to an `rts` assembled as `rts`, else as `jmp`): far branches are
  written as the opposite branch over a `jmp`.
- **Checked** (`python tools/disk_check.py [--jiffy]`, true drive
  emulation, with and without JiffyDOS): a round trip of the heavy test
  scene (16 patterns, 112 blocks) as a run without the disk had it; the
  file's bytes against memory; the code copied at start unchanged
  afterwards (so JiffyDOS leaves $0334-$03FF alone); the loads that can't
  be (no file, not a song, no overlay, another build's overlay, ended
  early, too big).

### The directory as built (2026-11-25, `src/disk.asm` dir_*)

- **C= D** (song screen, stopped): "READING..." while the directory ("$",
  read as a program) comes in; the names ending ".s5", without it, kept
  in the grid's step index (free while stopped: 29 names of 13; the take's
  variables after it untouched). Shown one a row from row 3, the title
  "DIRECTORY 8: 2 SONGS", rows 1-2 blank; CRSR down / up (SHIFT) move the
  cursor (repeating; the list scrolled at its ends), RETURN loads the
  cursor's song as C= L would, RUN/STOP leaves (every row drawn again).
  None: "NO SONGS ON THE DISK", or the drive's own words when it said
  more than "00, OK" (Claude's defaults while the user was away).
- **The cursor isn't reversed:** a ">" before the name, the name white,
  the others grey. `song_put_line` puts at most `PUT_AT_ONCE` (6) places
  whose reverse bit changes, as a cursor's cell: a reversed name lost
  most of its letters. For the same reason the save and load prompt is
  plain now, only its cursor reversed (it had "SAVE 8:" reversed).
- **Keys don't repeat** but the directory's cursor: `disk_key` and the
  overlay's keys return A = 0 (they had left A as it was: a long C= W
  could have typed w's into the name).
- `disk_check.py`: the directory of a disk with two songs and a file that
  isn't one, the cursor's colours, the second song loaded by CRSR down and
  RETURN. Not yet in flash_check (the disk's screens).
- **Room:** the program ends at $7400 again (none left); the overlay at
  $EB60 (160 bytes left).

### Memory for the music (the user, 2026-11-25)

- **The concern** (the user): a sequencer is no use if the music doesn't
  fit. Measured: a busy 4/4 bar of 16 steps (16th hats with kick and snare,
  a 16th bass and lead, chords, a filter sweep at a controller a 32nd) is
  ~313 bytes, ~215 without the sweep: the pool's ~18,200 stream bytes hold
  ~58-85 different busy bars (repeats cost nothing; played parts with knob
  moves much more). The program is 26.8 KB in main RAM (the song screen
  2.8 KB, the grid 2.5, editing 2.4, scenes 2.1, the player 1.7,
  transport 1.5, the live switch 1.4, locate 1.3, undo 1.3, the list 1.3).
- **The code may move again** (the user, 2026-11-25): no more frozen
  addresses from `synth_timer` on (and no pads to keep them); after every
  size change the timing checks run again (timing_check, play_check
  --sparse / --live / --edits, thru_check, screen_check) and the figures
  are accepted while they stay within the current limits. So the big
  modules can be shrunk.
- **The order** (the user): save and load committed, the directory
  (overlay only), then a size pass with a target of +4 KB for the pool,
  before SysEx (which needs resident code).
- **The drone stays in SID500** (the user, 2026-11-25: to be used in
  the music being edited, a track the song plays), not a program of its
  own. The size pass aims at +4 KB for the pool first; the drone's room
  (~2-3 KB) is found when stage H comes (a second pass, the grid's edit
  table halved, loadable blocks).
- Other levers, not chosen yet: the grid's edit table halved (192
  events, 1.5 KB for the pool, which would then be in two pieces), more
  loadable blocks (stop-only code).

### The size pass (stage G, from 2026-11-25; target +4 KB of pool)

- **Done:** the pads gone (HOT_PAD, SONG_PAD and its jmp, PLAYER_PAD,
  IO_COPY_PAD): 16 bytes, the program ends at $73F0; the timing checks
  pass (thru_check's 240 BPM edge once). `build_matrix.py --ref` reports
  moved labels as information only.
- **The user (2026-11-25): tighten the code first**; the step grid's edit
  table (384 events, 3 KB) shrunk to 256 only if the target isn't
  reached that way.
- **What there is:** main RAM is 25.4 KB of code and 1.4 KB of data
  (tables.inc 543, params.asm 404); +4 KB is ~16 % of the code. The pool
  grows only by whole pages (POOL_BASE), so the savings count once they
  add up to a page.
- **Found so far:** `end_stream`'s `.align 32` (events.asm) wastes 25
  bytes now and swallows up to 31 of any saving before it: a 32-byte
  aligned home elsewhere (e.g. $CFE0 if the disk's variables there make
  room, or the pool's last block, set up by pool_init) frees them for
  good. The largest routines (bytes): undo_apply 312, grid_step_line 288,
  ed_read_event 260 (the reader segment, twice: ev_ and ed_), song_put_line
  247, stop_locate 227, song_draw_from 222, grid_slice 222, edit_quantize
  220, edit_move_down 217 and edit_move_up 210 (likely one routine with a
  direction), scene_poll 215, song_shift_step 211, list_change 208,
  slave_tick 201, player_set_swing 199, live_publish 196, undo_room 191,
  song_scene_line_base 191, scene_row1 189, click_phase_song 188, live_post
  183, edit_change 176, grid_note_cell 175, locate_round 173; the module
  totals in "Memory for the music". Wrappers left by the frozen-address
  rule (scene.asm's song_prepare, names.asm's names_prepare, rec_key_base,
  the `*_out` stubs, the hooks redirected through disk.asm) can be folded
  back now that code may move.
- **After each change:** timing_check, play_check (--sparse, --live,
  --edits), thru_check, screen_check, and the checks of what changed.
- **Start-up code run once under the KERNAL** (2026-11-25): the routines
  run only at start (synth_init's body as `init_run`, the images' copies,
  click_init, record_init, count_init, grid_init, edit_init, names_init,
  locate_init, disk_init) are in section `init_code`, assembled at
  `INIT_CODE` (GRID_STEP_LO - $200, the step grid's table's end, unused
  until a pattern is opened), stored after the program with the other
  images; synth_init copies its two pages there and jumps in. And
  `end_stream` (32 bytes within a page) is no longer aligned in the program:
  it is after the take's variables under the KERNAL ($EDC0), filled by
  init_run. 389 bytes: the program ends at $726B.
- **Then** (2026-11-25): the leftover NOP fills (grid_note_cell's pitch,
  live.asm, grid_move_by), the unused `player_set_swing_table` and
  `live_wanted_row`, `log_locate`'s calls only in logging builds
  (`#log_at`), the hooks `note_on`, `note_off`, `synth_command` as
  aliases: 155 bytes. scene.asm patched `click_phase_song` at fixed
  offsets (`CPS_*`): now labels in click.asm (`cps_sig1` ...).
- **The hot variables in the zero page** (section `zp_hot`, sid500.asm):
  the 31 bytes after the core's (`zp_end`, $E0 in the release) hold the
  main loop's most used variables (div12's, `edit_at`, `undo_now`, ...;
  chosen by counting absolute accesses in the listing, none read indexed
  or at a fixed offset from a neighbour by code or by the checks, which
  read the grid's, the list's and the song cursor's variables as blocks):
  560 bytes. Builds whose own zero page leaves no room (the logging test
  builds) keep them in the program before `program_end`, chosen by
  `ZP_HOT` from `zp_end`. The program ends at $6FA0. All checks pass but
  the known edges (screen_check's keys 17 at half the wire, 98,804-101,384
  cycles of 98,500: HEAD's two runs 97,994 and passing; thru at 240 BPM
  once 30.8 ms of 30) and click_check's sound once (13 clicks heard, the
  accent missed: passed again; HEAD passed).
- **Then, the second batch** (2026-11-25): far branches over a `jmp`
  turned where in range in every build (one in grid.asm reverted: a test
  build's code between), two `jsr`/`rts` pairs folded, the key handlers'
  shared tails (`song_urgent_done`, `song_urgent_repeat`,
  `song_cursor_repeat`), the main loop's reader `ed_` calling `ed_byte`
  (`rd_get`: the player's `ev_` inline as ever), core options `MATH_ENV`
  (no `env_decay`: 5 more zero-page bytes, 5 more hot variables) and
  `START_COPY` (the core's start-up and `init_vars` in `init_code` too;
  `synth_start_copy` copies it, 3 pages at INIT_CODE), `pool_init` and
  `song_init` expanded twice (`twice`: as `_at_start` in the start-up code
  and in the disk overlay, which alone calls them later). The program ends
  at $6D4F. disk_check found the overlay's copies put before its id (their
  modules come first in section disk_ov): C= W loaded it and found it not
  there, silently. Now disk.asm expands the two bodies after the id, and a
  `.cerror` keeps the id at DISK_OV. All checks pass but the known edges
  (see the reruns below).
- **The step grid's table to 256 events** (the user, 2026-11-25; design
  5 "The step grid": a pattern of more events can't be opened in it):
  $E000-$E7FF; the step index, the ring and the variables stay at $EC00.
  The 1 KB between is `HI3_CODE`: most of the event list's main-RAM code
  (list.asm; `list_change`, the MIDI hooks and `list_pair_safe` stay
  resident), copied at start. **The take** to 128 records and 128 in the
  merge list (the user: 128 a loop; was 192). The start-up code below
  HI3_CODE ($E500), or at $E900 in builds without the list (the slave
  tests' feeds reach $E82F).
- **The overlay goes over HI3_CODE** ($E000 to ~$EBA0): `ov_load` first
  keeps it in the note map's pages 2-5 (`HI3_KEEP`, $F200; stopped:
  nothing sounds; pages 0-1 are the disk mode's), once (`hi3_out`).
  `hi3_in` puts it back (the pages `NO_ENTRY` again, the overlay's id
  spoiled: loaded again next time) when the step grid opens (it spoils the
  overlay anyway: the overlay stays cached between disk actions as before)
  and before anything uses the note map: `transport_go_start`,
  `_continue`, `transport_poll`'s held path (resets, a slave's start),
  `locate_begin`, `count_begin`. A slave's Start or Continue that would
  play at once from the receive interrupt is held instead while
  `hi3_out` (the main loop puts the code back, then starts: that start
  ~a tick later); a disk screen open then is closed (the user). ~140 bytes
  for all that: the program ends at $6A2B. disk_check's run 26 (save, the
  step grid, F3: HI3_CODE as the image but list_io's self-modified call,
  the note map empty, the list shown) and runs 27-28 (a save, then
  SHIFT+SPACE and SPACE, against the same without the save: HI3_CODE as
  the image, the note map's channels 4-15 alike; with VICE's MIDI
  cartridge, without which the band's bytes never go and the keys aren't
  read). The slave's start held while `hi3_out` is untested. The suite:
  all pass but the edges: screen_check at half the wire (keys 7 80,356 of
  78,800 once), count_check once (a 7/8 stamp at 240 BPM; twice passed
  after), and thru at 240 BPM on the old CIA, 31.5-32.7 ms of 30 in three
  runs of three (the build before HI3 the same, 32.3-32.5 in two; before
  the size pass, e397160, 30.5-32.4 in one run, 27.5-28.8 in the other,
  medians 15-17 ms throughout: a noisy edge, not the size pass's): for
  the user.
- **The pool from $6B00** (the user, 2026-11-25: "all I can get at
  this point"): POOL_BASE from $7400 to the page after the program's end
  ($6A2B): 680 blocks, was 608 (+2,304 bytes, 72 blocks of 32). The
  release booted in VICE: the free list whole, 680 free. The test builds
  keep theirs ($6000, from the program's end); tempo_check's build is the
  one with the release's base.
- **SysEx left for last** (the user, 2026-11-25: "I don't think that
  sequencer needs sysex dumps, maybe just for the drone"): no song dumps
  now; perhaps the drone's sounds by SysEx, after everything else. Next:
  stage H, the drone.
- **The pool's room for a song** (estimated for the user, 2026-11-25):
  a note ~3.4 bytes encoded (the demo band's patterns: 2.7-3.7), ~3.7
  with the blocks' last bytes; 680 blocks hold ~5,000-5,500 notes. A busy
  8-part pop arrangement (~85 notes a bar) written out bar by bar: ~62
  bars, ~2 minutes at 130 BPM; built from patterns (25-40 bars of
  different material) a 3.5-minute song fills ~40-65%. The limits met
  first are often 128 patterns, 64 scenes, 128 steps, 256 events in the
  grid. **The drone left out** (the user: it won't fit; section 6).
- **Fable's survey** (2026-11-25): ~2.1-2.4 KB more from the code (hot
  variables into the free zero page $E0-$FF, dead code and leftover NOP
  fills, test-only calls in the release, the key handlers' shared tails,
  the start-and-load routines into the start-up code and the overlay,
  edit_move_up/down smaller and slower, the main loop's reader `ed_`
  calling its byte routine, peepholes, wrappers folded). Short of +4 KB
  by ~1.3-1.6 KB: **the user (2026-11-25): the step grid's edit table
  shrunk to 256 events** (a pattern of at most 256 events in the grid),
  the 1 KB freed under the KERNAL for main-loop code, after the code
  cuts.

## 5f. The time display (settled with the user, 2026-11-26)

The user: SID500 needs a time display while playing. Settled one question
at a time:

- **What:** the song's position as bar.beat and its time as m:ss.
- **Where:** the song screen's title row, in place of "TRK 1-8" (the
  half shown is in the header's colours): "SONG  SCENE 05  BPM 122
  012.3 2:15  PLAY". (Claude's first preview, on row 1, didn't fit: row
  1's text ends at column 29.) The bar three digits, zero-padded, counting
  on from 000 after 999; the beat 1-16 (n/8 signatures to 16); the time
  m:ss up to 99:59. At its widest (a bar of 100 or more, a beat of 10 or
  more and 10 minutes or more) the field reaches the play state's word
  (accepted).
- **The clock is song time:** it always matches bar.beat. A stop
  freezes it, a continue goes on from there, a start from the song's
  start (SHIFT+SPACE, a master's Start) is 001.1 0:00, a master's song
  position sets it at once. A tempo change counts the rest at the new
  tempo.
- **Song on's loop:** the count keeps going (as a master's song position).
- **Claude's plan:** in the main loop (no change to the timer interrupt,
  the renderer or the snapshots): the beat from the metronome's count
  (`click_beat_no`, which follows the heard ticks, the signatures and the
  launches, and is counted with the Metronome off too), a bar each time
  it comes round to 0; the seconds from `play_tick`'s differences (a tick
  5/(4 x BPM) s: a remainder, no division); a jump (a start: from 0; a
  song position: from `locate_16th`, the bar from the scene rows as
  locate walks them) worked out afresh. The title row marked to draw when
  the text changes.

### The time display as built (2026-11-26, `src/clock.asm`)

- **Room (the user: "go with 1"):** the first try took ~1,150 bytes; a
  rewrite ~650 (the zero page full, every variable's access 3 bytes),
  with 213 bytes free below the pool and 91 under I/O. **The pool from
  $6D00** (two pages: 664 blocks, was 680); the program ends at $6CCE.
- **The text is the count:** `ck_text` holds "001.1  0:00" in screen
  codes; a second or a bar counts its last digit up in place (`ck_up`,
  `ck_top`: each place's top digit, the colon passed over, the minutes'
  blank tens as 0; the bar's 999 on to 000 by itself). The title copies
  it (song.asm `song_title_line`).
- **Counting:** `clock_poll` (synth_tick, every screen) takes play_tick's
  difference from `ck_seen`: forward, each tick its 5 units (a second at 4
  x BPM, `ck_frac` the rest), its beat (`ck_bt`, `ck_beat`; at the beats'
  end a bar, the next bar's signature `play_scene`'s); behind (a stop:
  play_tick back to the ticks sent, then on to the 16th it continues
  from), nothing until it is past `ck_seen` again: exact without a path
  back. Stopped at tick 0 the start scene's signature is taken again (it
  may be edited there).
- **Jumps marked by their makers** (`ck_jump`): scene.asm `player_reset`
  (every start from the song's start: 001.1 0:00, the start scene's bar;
  play_tick's wrap after 65,536 ticks is no jump) and locate.asm
  `locate_done` (a song position): once the locate's and the stop's
  pieces are done, the bars from locate_scene's walk (it counts the
  scenes' bars x repeats as it passes them, `ck_bars`; locate_round's
  division keeps its quotient, the rounds left out, `ck_q`, times a
  round's bars), the bars and the place within the scene (`sc_mod`, which
  now leaves the quotient in sc_num), the time from the 16th (x 60
  units, / 4 x BPM); the text counted up from 001.1 0:00 to them.
- **Drawn by its digits:** `ck_ver` counts the text's changes (a beat's
  and a second's: ~3 a second at 120 BPM, up to 17 at 240 in n/8), and
  the song screen's draw step (`clock_check`, in count_state_check) puts
  the 11 characters straight on the screen (~200 cycles; the colours the
  title's already) when the title row shows the song screen's title (not
  marked to draw: then it is drawn whole from the text; no disk message or
  prompt there) and the beam is clear of it; a title prepared aside is
  forgotten. Drawn as a whole row the clock cost the keys at half the wire
  (urgent: screen_check up to 101.5 ms of 100, a song screen key 79.0 of
  80) or waited behind a scroll's copying (dirty: flash_check saw it a
  beat old for 15-23 frames). `clock_poll` runs after `thru_poll` in the
  tick (thru never waits for it).
- **Checked:** `python tools/clock_check.py` (in VICE at real speed: a
  master with Song on through the three signatures and the rounds at 40,
  120 and 240 BPM, Song off, a slave fed song positions 20, 30 and 46:
  the count at the tick heard, and its text, beat and remainder as the
  model's); flash_check's model shows the clock's text (its script 4 gives
  the + then DEL pattern 5 scans: shown 2 frames, it read as a flash).
- **The timing checks after it:** timing_check, play_check --sparse
  (worst 3.09 ms of 3.2), --live, --edits, thru (240 BPM: 28.4 ms of 30),
  flash, scene, transport and locate checks pass. screen_check: at half
  the wire the event list's keys 98.8-99.5 ms of 100 (98,500 cycles),
  as HEAD before the clock in the same session (99.0): its known edge.
- **Not yet:** as slave the seconds count at the Tempo parameter, not the
  master's tempo.

## 6. The built-in synth: a drone (left out)

**Left out** (the user, 2026-11-25, after an estimate of the room: "lets
leave the drone out, it wont fit"): its ~2-3 KB would come from the note
pool, ~12-15% of a song. SID500 makes no sound but the metronome's; this
section stays as the design that was.

Decided with the user (2026-11-20), replacing the 3-voice polyphonic synth
first planned: **one ambient drone sound, slowly changing, made of SID
voices 1 and 2 together**, so that ring modulation and sync between them
shape the sound. Voice 3 stays the metronome's for good (section 4b).

- **One sound on one MIDI channel** (a track's channel, or "internal"),
  one note at a time; a new note glides there slowly or starts afresh. The
  two voices are one instrument: voice 1 is the modulator, voice 2 the
  carrier (on the SID, voice 2's ring modulation and sync come from voice
  1, so voice 3 and the click never touch the drone).
- **The voices:** each its waveform (triangle, saw, pulse, noise) and level
  (voice 1 can be silent and still modulate: its oscillator always runs);
  voice 2's interval from voice 1 (semitones) and a fine detune, for slow
  beating; **ring modulation, sync, both or neither** on voice 2.
- **The SID's own envelope** for the amplitude: its attack runs up to 8 s
  and its release up to 24 s in hardware, which suits slow swells (the
  mono synths can't use it; here a slow sound has no fast retriggers).
- **Slow modulation:** a few LFOs, from seconds to minutes a cycle, with
  smooth random wandering as a shape so it never sounds like a loop,
  aimed at the cutoff, resonance, pulse width, voice 2's detune or
  interval (a slow sync or ring sweep) and the voices' balance. Noise
  through the resonant filter for wind and breath.
- **Updated at 50 Hz** (the user's suggestion): slow changes need no more;
  a cutoff swept over seconds moves in steps too small to hear. The work
  is spread over the 250 Hz ticks, a fifth each, so it costs very little
  and can never hold up the MIDI timing (section 4).
- **An instrument on a track** (the user, 2026-11-25: usable in the music
  being edited, in SID500 itself, not a program of its own): a track's
  channel setting gets **DRONE** after 1-16: its notes, controllers and
  bends go to the drone from the player (exact timing, nothing on the
  wire), its controllers automate the drone's parameters (as a synth's CC
  map), thru to the cursor's track plays it too (a drone part recorded
  from a keyboard). **And** a parameter, the drone's MIDI channel (or
  off), so an external keyboard or another sequencer plays it over MIDI
  in.
- **The filter is the drone's:** the click bypasses it (section 4b), so
  the drone's sweeps never colour the metronome.
- Its parameters on the parameter screen, its sounds as named presets (as
  SID101's), sound demos for the user to judge by ear.

## 7. The questions, settled (the user, 2026-11-20, one at a time)

1. **Pattern length:** any number of steps, 1-128 (8 bars), per pattern.
2. **Resolution:** 48 ticks a quarter note; MIDI clock 24.
3. **Recorded:** notes, controllers, pitch bend, program changes; no
   aftertouch; live moves thinned.
4. **Playing:** a song of scenes, and scenes or single patterns launched
   live (at the bar), by hand or MIDI.
5. **Editing:** a step grid and an event list of the same pattern.
6. **Clock:** master and slave in the first version.
7. **The family:** plain MIDI, plus the family's names on screen for
   tracks marked as SID303, SID808 or SID101. SysEx and remote control of
   them perhaps later.
8. **The setup aimed at:** one C64 with SID500 as the master of a MIDI
   rig: its MIDI out through thru or a splitter to the family's synths on
   their own C64s (each on its channel) and other gear, a keyboard into its
   MIDI in. Tested in VICE with MIDI fed in and what goes out logged, as
   the synths' tests do.

Settled after the review (2026-11-20): a slaved SID500 passes the clock on
(section 4); the compact event format and the linked blocks (section 3).
Settled in stage A (2026-11-20): no "send early" offset for now; the time
signatures n/4 and n/8; swing as the family's; events in recorded order,
none thinned. Settled in stage B (2026-11-21): 64 scenes, pattern
numbers song-wide, a change to the playing scene heard at once (section
5). Settled for stage C (2026-11-21): the step grid as rows with 3
note columns, opened by RETURN on a song cell, note entry column then
down, notes off the steps shown and kept exact, SID303's keys extended
(section 5). VICE does pace its ACIA (283 cycles a byte;
section 4's core list).
Settled in stage D (2026-11-23): **Tempo 40-240 BPM**, the family's top
(the parameter had run to 295 only because it was a byte from 40; music
is nearly always under 200). The tests' fast case is 240, the slave's
feeds too (a slave follows any master, but 240 is the range stated and
tested). The tempo tables under I/O 201 entries (220 bytes freed). As
measured at 240: live switches 21-73 ms, edits on the dense pattern
21-141 ms (play_check's limit now 250), the slave's 100-to-240 jump 1.5
ms of lag, thru 25-35 ms (still at its edge: the test feed). The song
title's 16 bytes saved are kept as `SONG_PAD`: without it the code after
moved and timing_check's 240 BPM bursts ran up to 2.21 byte times behind
the wire (3 runs of 9 over 2); with it 1.43-1.73. Memory
for stages D-G (the user asked, 2026-11-23): ~6-8 KB more code against
~0.9 KB free; an editor size pass (~1 KB), the stop-only parts of stage
G (disk and dump screens) loaded from disk as an overlay (~2 KB; the
disk works only while stopped, so nothing used while playing can be
one), the rest from the note pool's start ($6C00-$7000); the drone
(stage H) perhaps a second program with a smaller pool. Each to be
settled with the user when it comes.
