# SID808 sequencer and drum track editor

Plan step 3 (README). Decided 2026-11-17: per-step velocity with three
levels, 64 patterns of up to 16 steps, internal clock and MIDI clock in
before MIDI out.

## Screen

An 808-style step grid, one row per sound, 16 steps across; F7 switches
between it and the parameter screen.

```
PAT 01   BPM 125  SW 00  LEN 16  PLAY 01
      1 . . . 2 . . . 3 . . . 4 . . .
 Kck  X . . . . . x . X . . . . . . .
 Snr  . . . . X . . . . . . . X . . .
 Clp  . . . . . . . . . . . . x . . .
 CHH  x . o . x . o x x . o . x . . .
 ...  (13 rows: all sounds)
SONG 03/02 >01x2 02x1 ----
1:OHH 2:Kck 3:---  Vel 100          MIDI
 (help rows)
```

The song row (phase D): `SONG` (reversed: song mode on), the song cursor
/ the song's length, then five entries from two before the cursor: `>` on
the one playing, pattern and repeats (`01x2` = pattern 1 twice); the
cursor's entry reversed; `----` after the last entry, where P adds one.

Cursor keys move; a key cycles a cell through off, soft, normal, accent
(`.` `o` `x` `X`). While playing, a marker runs along the step row. Hits
go through `note_on`, so choke groups and voice sharing work as they do for
MIDI.

## Keys (phase C, done)

| Key | Does |
|---|---|
| CRSR (SHIFT: other way) | move the cursor (auto-repeat) |
| SPACE | cell on (normal) / off |
| 1 2 3 | cell soft / normal / accent, cursor to the next step |
| DEL | cell off |
| M | mute / unmute the cursor's sound |
| + / - | pattern length 1..16 |
| F1 / F2 | next / previous pattern (plays from the next pattern start) |
| F3 / F4 | tempo +/- 1 BPM |
| F5 / F6 | swing +/- (0..15: off-beats late by swing/32 of a step) |
| C | copy the pattern to the next one and show it |
| HOME / CLR | cursor to the start / clear the pattern |
| RUN/STOP | play / stop (sounds ring out) |
| F7 / F8 | parameter screen (F7 there comes back) / all notes off |

## Keys (phase D: song mode, live record)

| Key | Does |
|---|---|
| S | song mode on / off |
| , / . | song cursor back / on; on an entry the grid shows its pattern |
| P | put the grid's pattern into the song at the cursor (after the last entry: add one, 1 repeat); cursor on |
| ; (SHIFT: back) | the cursor entry's repeats 1..9 |
| left arrow | delete the cursor's entry |

| W / L | save / load (disk, below): the name prompt on the song row |
| R | live record on / off (`REC` on the song row) |
| U (SHIFT: redo) | undo the last edit / redo (below) |
| RETURN (SHIFT: accent) | tap: play the cursor's sound, velocity 100 (127); recorded while recording |

Song mode plays the song (if it has entries) in a loop: each entry's
pattern as many times as its repeats, then the next; after the last, the
first. RUN/STOP starts it from the first entry. While it plays the grid
shows the pattern playing (it follows at each pattern start); F1/F2 still
show other patterns for editing until the next pattern start. Turned on
while playing, the song starts from its first entry at the next pattern
start; turned off, the pattern on the grid plays from the next pattern
start. Editing the song while it plays is safe: an entry deleted under the
one playing makes the song go on from the first entry.

Every key is taken on the grid (none plays a note but RETURN, below);
MIDI notes still play.
`TEST_KEYS=1` (src/test_scripts.asm) edits two patterns and checks the
result in memory; it matched in VICE.

## Undo (src/undo.asm)

U undoes the last edit, again and again up to 12 back; SHIFT+U redoes. An
edit is a cell (SPACE, 1 2 3, DEL), the length (+/-), a pattern clear (CLR),
a copy (C: the pattern it wrote over), or a song edit (P, ;, left arrow);
live record counts once per pass of a pattern. Before an edit changes
something, `undo_save` copies the pattern's page (or the song block) into a
ring of 12 pages under the patterns ($7400-$7FFF; 16 until the SysEx
dumps took the room, 2026-11-19); undo steps back a slot
and swaps it with the data, so redo swaps it back; a new edit drops the
redo steps. The grid shows the pattern that changed (and it plays next, as
with F1/F2). The song row says `UNDO, 5 MORE LEFT`, `REDO, ...`, or
`NOTHING TO UNDO` until a key. A load from disk clears it; mutes, tempo and
swing are settings, not undone. Keys that change nothing (DEL on an empty
cell) save no step.

Tested (`TEST_KEYS=12`, `13`, VICE): edits, undo, redo, a song entry, a
pattern clear undone, as expected; 17 edits and 17 undos: 16 undone, then
`NOTHING TO UNDO`. Since the ring has 12 steps (not a power of 2, so it
wraps by comparing, not by masking) the `TEST_KEYS=13` build needs
`UNDO_STEPS=11`: 12 edits and 12 undos, 11 undone, `NOTHING TO UNDO`
(2026-11-19). Live record (`TEST_MIDI=3`): six hits in a pass, one
step. The problem demo build (`TEST_MIDI=7`, a long test feed) reaches past
$7000, so it builds with `UNDO_STEPS=8`.

## Live record

While recording and playing, every hit played live - MIDI notes, the
parameter screen's note keys, the grid's RETURN tap - is written into the
pattern playing (`note_on` -> `sound_hit` -> `rec_hit`; the sequencer's
own hits don't go through it). The step is the nearest on the unswung
grid: past half a step, the next one (after the pattern's last step: step
0 of the pattern that plays next, the same answer `seq_step_due` will use,
`seq_next_pat`). The level is the nearest of soft 55, normal 100, accent
127 (velocity below 78: soft, below 114: normal). The cell is overwritten.

The hit plays at once, as played. If its step is still to fire in this
pass (the next step; or the current one while play was just pressed, a
swung step waits, or the step's hits - spread over ticks - haven't reached
this sound yet), that firing skips the sound once (`skip_now`,
`skip_next`: masks outside the pattern data, cleared at play and stop). So
a press sounds once, and from the next pass on the step plays it.

## MIDI clock in (phase E)

The parameter screen's `Clock` (Internal / MIDI) picks what drives the
steps. On MIDI, the core hands realtime bytes to `synth_realtime`
(`MIDI_REALTIME = 1`, core option), which only counts and sets flags; the
steps still fire from `synth_tick`, at most one engine tick (2 ms) after
the clock byte:

- Start ($FA): play from the start (in song mode the first entry); step 0
  comes with the first clock after it, as the MIDI spec has it.
- Clock ($F8): every 6th (24 per quarter note) makes the next step due.
- Continue ($FB): play on from where it stopped, the clock count included.
- Stop ($FC): stop; sounds ring out.

The title shows `EXT` for the tempo. Swing works as with the internal
clock: the off-beat delay comes from the step length measured between the
clock's steps. Live record quantises on the clock count (3 of the 6 clocks:
the next step); a note that comes with the clock starting a step (handled
before the step fires) goes to that step, and one between start and the
first clock to step 0. RUN/STOP still starts and stops locally; steps then move
only with clocks. Song position pointer is not used yet.

## MIDI control

Pattern select, song select and song position over MIDI (the core's
`PATTERN_CC` and `MIDI_SYSTEM`; `seq_pattern`, `seq_song_select` and
`seq_song_position` in src/sequencer.asm, as the core's sequencer module
has them, without transposes):

- Controller 85, value 0-63: that pattern plays from the next pattern
  start, as F1/F2 choose it (stopped: from play); the grid shows it; song
  mode goes off. 64-127: nothing. Only on SID808's channel, not in omni.
- Song select (any number): song mode on. SID808 holds one song.
- Song position, with Clock on MIDI and stopped (ignored otherwise): the
  next Continue plays from there. In steps; the song's length is the sum
  of each entry's pattern length times its repeats, and the position wraps
  at it. Without a song, the queued pattern's step. Start forgets it.

`tools/pattern_check.py` checks it in VICE. `TEST_LOG` builds log every
hit the sequencer fires (tick, sound, level) at $C800-$CFFF; the check puts
the hits on steps by their time and compares them with tables.py's
patterns and song. The working bytes of `seq_song_position` (and
`TEST_LOG`'s tick) are at $C700, out of the full zero page. The demo builds
(`sid808-test`, `-track`, `-timing`) now have 8 undo steps: with the new
code their long MIDI feeds no longer fit beside 16.

## MIDI out (phase E)

The parameter screen's `MIDI out` (Off / On) sends, through the core's
interrupt-driven output (`MIDI_OUT = 1`: `midi_send` queues, the ACIA's
transmit interrupt sends at the wire's speed):

- every hit the sequencer fires: note on with the cell's velocity (55,
  100, 127), at once note off; on the MIDI channel (Omni: channel 10, the
  GM drum channel), with the sound's GM note (`sound_gm`: 36 kick, 38
  snare, 39 clap, 42/46 hats, 41/45/48 toms, 37 rim, 75 claves, 49 cymbal,
  56 cowbell, 70 maracas). Muted sounds are not sent; hits the voices then
  drop are (the receiver may have voices to spare). Hits played live are
  not echoed.
- with the internal clock: start ($FA) at play, clock ($F8) 6 per step -
  a phase at 6 x the step phase, so the 6th falls on the step's tick - and
  stop ($FC). With MIDI clock in, the master sends those.

## Disk (phase F)

W (save) or L (load) puts a name prompt on the song row (`SAVE 8:` with
the drive's number, then the last name used, first `SONG`): letters,
digits, space and + - . type, DEL deletes, RETURN goes, RUN/STOP cancels.
The drive is the parameter screen's `Disk drive`, 8 to 16; at start the
drive the program was loaded from (the KERNAL's last device, $BA), or 8 if
that is 0 or not 8..16. While it runs the
song row says `SAVING...` / `LOADING...`; then it shows the drive's
status line (`00, OK,00,00`, `62, FILE NOT FOUND,00,00`, ...) or one of
ours (`NO DRIVE 9` etc., `NOT A SID808 FILE`, `FILE ENDED EARLY`) until a
key.

The file (one PRG, 54 blocks) holds everything: the 64 patterns (cells and
length), the song, tempo, swing and mute. Saving scratches an old file of
the name first (`S0:`; not the 1541's unreliable `@0:` replace). Loading
reads the header first and changes nothing if it isn't a SID808 file;
then it checks what came in (lengths, song entries, tempo, swing in
range), shows pattern 1 and puts the song cursor at the start.

A disk operation stops the sequencer (MIDI out's stop byte goes out
first), silences the voices, turns every interrupt source off at the chip,
puts back the KERNAL's zero page (kept at start, core `KERNAL_ZP_COPY`)
and banks the KERNAL in; afterwards our zero page, the tick timer and MIDI
are set up as at start. No sound or MIDI meanwhile; RUN/STOP plays again.
Details: src/disk.asm.

## Data

One byte per cell: bits 0-1 the level (0 off, 1 soft, 2 normal, 3 accent),
the rest free for later per-step extras. A pattern is 13 sounds x 16 steps
= 208 bytes plus its length; 64 patterns are about 13 KB of the ~40 KB free.

The song: up to 64 entries at $C140 (patterns), $C180 (repeats) and its
length at $C1C0, saved with the patterns (Disk). Cleared at start. The
sound knobs follow at $C1C1 (4 x 13 bytes, `docs/design.md` 10); the file
holds them from version 2 (Tone from version 3). Test logs: $C700-$C7FE,
their index at $C6FF.
Other RAM: $C300 MIDI out ring, $C400 and $C500 zero page copies (disk),
$C600 disk variables.

## Phases

| Phase | What |
|---|---|
| A | Core: the synth can own the screen and get keys first (`SYNTH_SCREEN` build option; off = the core assembles as before, SID303 byte-identical) |
| B | Sequencer engine: pattern data, play/stop, tempo 60-240 BPM from a fractional step counter (exact at any BPM), swing, triggers from `synth_tick` |
| C | Grid editor: cursor, cell levels, pattern select, length 1-16, clear/copy, mute per sound |
| D | Song mode (pattern chain with repeats), live record (keys or MIDI while running, quantised) |
| E | MIDI clock in (start/stop/continue, 24 ppqn); then MIDI out (clock, notes; the core needs ACIA transmit) |
| F | Disk save/load (ROMs are banked out: pause sound and MIDI, bank the KERNAL in) |

## Core hooks (phase A)

With `SYNTH_SCREEN = 1` the synth provides:

| Hook | Called | Does |
|---|---|---|
| `synth_draw_step` | instead of the core's `screen_draw_step` while `screen_owner` is nonzero | draw a little of the synth's screen |
| `synth_key` | from `key_event` while `screen_owner` is nonzero, for presses and releases | A = key code (column*8+row), `want_press`, `shift_held`. Out: carry set = used (the core does nothing more), then A nonzero = auto-repeat this key while held. Must keep the scan's variables. |

To give the screen back, the synth clears `screen_owner` and calls
`screen_init` (the parameter rows then redraw one per step).

## Measured (phase B, VICE)

- Tempo: bar lengths 1916-1921 ms at 125 BPM (1920 expected) and 1998-2002
  ms at 120 BPM (2000; a 16th is 62.5 ticks there), no drift over six bars.
  The tempo table uses the real tick, 985248 / 1970 = 500.126 Hz.
- Swing 8 delays the off-beat 16ths by 29-32 ms (a quarter of a step, 30 ms).
- CPU: see "CPU per tick" below (the first figures here were wrong: one
  read only the timer, which wraps at every reload).

## CPU per tick (VICE, `TEST_CPU=1`)

The tick is 1970 cycles. `TEST_CPU=1` times every `synth_tick` while the
sequencer plays with CIA2 timer B: the longest (`cpu_max`), the most ticks
the main loop was behind (`cpu_lag`), how many ticks ran over a tick period
(`cpu_over`) and how many were measured (`cpu_ticks`). Read them in VICE's
monitor; use `TEST_KEYS` builds for `cpu_lag` (`TEST_SEQ` starts playing
before the screen is set up).

Before: a step's hits were all chosen, set up and launched in one tick.
A hit cost 600-1000 cycles: `voice_pick` up to ~800 (four multiplies when
every voice sounds, even for a hit then dropped), `voice_start` with its
launch (two multiplies, the filter, the oscillator park) up to ~900. On
top of that the voice ticks took 1100-1500 cycles with three voices
sounding, two multiplies each for the level decay; and hits launched
together ended their mute phases together, so three first steps loaded in
one tick (2800 cycles). FULL pattern: longest tick 4470 cycles; all 13
sounds on one step (`TEST_KEYS=3`): 10591, 6 ticks behind.

Now:

- The level decay is a table lookup (`level_decay`, `decay_dlo/dhi`: the
  core `env_decay` result for each rate and level, 6.5 KB): quiet ticks with
  three voices take ~700 cycles (median), at most ~1400 (long glides).
- `voice_pick`'s scores come from `score_tab` (a page per sound, the same
  products, 3.3 KB): a pick costs at most ~400 cycles, a drop ~150.
- At most one voice is launched (oscillator parked) per tick, by its
  `voice_tick`; the sequencer's hits only set up their voices, which launch
  on the following ticks.
- The sequencer runs after the voice ticks and fires a step's hits while
  the tick has `HIT_CYCLES` (768) left (CIA1 timer A); the rest wait for the
  next tick, in the same order. A hit waits at most one tick. A step's
  later hits never steal a voice an earlier one took (`pick_keep`; with all
  hits in one tick the levels they compare stood still, and the 13-sound
  step otherwise played a weak hit over a stronger one's voice).

Result, over 65535 ticks each: FULL longest tick ~2500 cycles, FULL_CYM
~2700, 13 sounds ~2300 and 2 ticks behind; 0.1-0.5 % of ticks still run
over (a launch, first steps and a hit meeting), by at most ~700 cycles,
and the main loop catches up. A busy step's hits now come about a tick
(2 ms) apart, kick first (`fire_order`); the mute phase before each hit's
sound already varies by a few ticks with the level.

Checked against the previous build by logging every voice start: FULL,
the 13-sound step and the MIDI demo track start the same sounds on the
same voices; FULL_CYM and ROLL the same sounds, some on other voice
numbers. `TEST_KEYS=1` and `2` give the same results as before.

## Measured (sound page, VICE)

- Defaults change nothing: voice-start logs of FULL, ROLL, the 13-sound step
  and the demo track equal the build before (FULL_CYM: the same sounds, two
  voice numbers swapped); the demo recording's envelope correlates 0.996
  with the build before (headless x64; runs differ slightly from run to run).
- Knobs on the cowbell alone (headless x64): Tune +12 -> 1080/1600 Hz, +7 ->
  810/1190, -12 -> 270/410 (from 540/800); Decay 0 -> 170 ms to 10 % (315 at
  8); Level 7 -> 0.45 of the RMS.
- `TEST_KEYS=9`: grid cursor to Snare, Level -3, Tune +2, Decay -1, Sound
  +1: Snare's knobs 12, 14, 7, the page on Clap's defaults, cursor row 2.
  `TEST_MIDI=6`: CC 16 = 64, 17 = 127, 18 = 0 -> Kick's Level 8, Tune +12,
  Decay 0.
- Disk: `TEST_KEYS=10` saves Kick's Level 10, sets 15, loads: 10. A version
  1 file (saved by the build before) loads with every knob back at its
  default (`TEST_KEYS=11`, `TEST_LEVEL=3`).
- CPU (`TEST_CPU`, 65535 ticks), defaults: FULL longest 3258, 467 over;
  MAIN_CB 2832, 574; 13 sounds 2390, 336, 2 behind. Every sound at Tune +12
  and Decay 0: FULL 2939, 970 over (1.5 %); MAIN_CB 2767, 627; 13 sounds
  3032, 1407, 6 behind (first version, two multiplies and up to 3 passes:
  2384 over in FULL, 9 behind).

## CPU overload

The timer interrupt counts ticks (`tick_count`, 8 bits) and the main loop
runs them (`tick_done`), so a tick that takes too long only delays the next
ones: the main loop then runs the waiting ticks back to back until it has
caught up. Timing under load, then:

- **Internal clock:** the step phase advances per tick run, so steps and
  their hits come late by the ticks waiting (jitter), but none is lost and
  the tempo holds on average. MIDI clock out is made in the same ticks, so it
  jitters with the hits and a slave stays with them. Only at 256 ticks
  behind (~0.5 s) does the 8-bit count wrap: those 256 ticks are lost, the
  tempo slips for good, and clock out with it (a slave follows the slower
  clock, so it stays in step with SID808, but not with anything else).
- **MIDI clock in:** the main loop reads MIDI before it runs a tick, so clocks
  are counted as they come (`clock_due`); each tick run takes at most one
  due step. Under load steps come late but are never dropped, and SID808
  catches up with the master afterwards. The swing, measured in ticks run
  between steps, is off while it is late. A main loop stalled long enough
  to let the 256-byte receive ring overflow would lose MIDI bytes (clocks
  among them); a busy tick is far shorter than that.

**Warning** (`overload_check`, every tick; the status row on both screens):
`CPU` reversed when 8 or more ticks are waiting (hits 16 ms or more late,
audible jitter), `CPU!` from 128 (losing ticks is near); each stays lit ~2 s
after the last time. Measured in VICE: the stress pattern (`sid808-stress`)
never lights it (sampled at 4-25 s); `sid808-stress-max` shows `CPU!`
throughout; the demo, the track and the idle program never.

## Measured (Tone knob, VICE)

- `TEST_KEYS=9` (with a Tone +1 step): Snare's knobs 12, 14, 7, 9; the page
  on Clap's defaults 15, 12, 8, 8. `TEST_MIDI=6`: CC 19 = 127 -> Kick's Tone
  15.
- Logged in the audition (`TEST_MIDI=1`, every sound at `TEST_TONE` 0 / 8 /
  15): start pitch Kick 4290 / 8514 / 17028, Snare 2931 / 5619 / 11238, low
  tom 1300 / 2452 / 4904, Rim 14484 / 28948 / 57896, Claves 19709 / 39165 /
  65535 (the top); cutoff Clap 11 / 23 / 46, Cowbell 8 / 16 / 32, Cymbal
  53 / 106 / 212, hats ~92 / 184 / 255; the filtered sounds' noise
  frequencies unchanged.
- CPU (`TEST_CPU=1 TEST_SEQ=1 TEST_SEQ_PAT=8`, FULL, 65535 ticks, headless
  x64; this way counts more ticks over than the figures above): the build
  before the click fix longest 3130, 979 over; with it 3217, 1015; with
  Tone at the defaults 3311, 1099 (1.7 %); every sound at Tone 15: 3291,
  1417; Tone 15, Tune +12, Decay 0: 2959, 2765 (4.2 %).
- Bug in the first version (de43837): with Tone at its default,
  `filter_apply` went on with Y = the Tone value instead of the filter
  setting, so the resonance and mode came from past the end of their
  tables; the stray mode bits ("voice 3 off" among them) silenced most
  kicks' body after the first filtered sound. Found with a probe (a kick,
  another sound, a kick, for eight sounds): the kick's body (80-200 ms
  peak) ~30 after every sound but the cymbal, ~2500 in 3bcf6cd, 96ab673
  and the fix.

## Measured (phase F, VICE)

On a .d64 with the program (true drive emulation):

- `TEST_KEYS=5`: song entry 1 = pattern 1, save `T1`; clear pattern 1,
  tempo 126, delete the song entry (checked: pattern 1 empty, 126, no
  song); load `T1`: pattern 1 = MAIN again (14 cells, length 16), tempo
  125, song entry back; drive status `00, OK,00,00`. The same with
  JiffyDOS (`vicepeek --jiffy`).
- `TEST_KEYS=6`: loading the program itself: `NOT A SID808 FILE`, memory
  unchanged. `TEST_KEYS=7`: a missing file: `62, FILE NOT FOUND,00,00`; with
  drive 8 off (`-drive8type 0`, the program injected): `NO DRIVE 8`. The
  program plays on in every case.
- Disk drive (`TEST_DRIVE` = the parameter at start): `TEST_DRIVE=1`, the
  program on drive 8 and a blank disk on drive 9 (`-drive9type 1541 -9
  ...`): the `TEST_KEYS=5` round trip passes and `t1` (54 blocks) is on
  the drive 9 disk. With no drive 10 or 16: `NO DRIVE 10`, `NO DRIVE 16`
  (the first try said 17: a carry left set).
- Drive at start: autostarted from drive 8 -> 8; `LOAD"SID808",9` and RUN
  -> 9; the program injected into RAM ($BA = 0) -> 8.
- `TEST_KEYS=8` with `TEST_MIDIOUT=1` on Namesoft (`-midi -miditype 3`):
  start and clocks every 10 ticks, the stop byte before the save, then
  start and clocks again after it.
- Found on the way: `#>PATTERN_RAM + NUM_PATTERNS` is `>(PATTERN_RAM + 64)`
  in 64tass (the save ran through all of memory); and with `64tass -a`,
  DOS strings must be lowercase in the source to be plain PETSCII.

## Measured (phase E, VICE)

- `TEST_MIDI=4 TEST_CLOCK=1 SEQ_SWING_DEFAULT=8`: start, clocks every 10
  ticks (125 BPM) for two bars, stop, a pause, continue, a bar. Logged
  steps: 0..15 twice, then on from step 0 after the continue; on-beats 60
  ticks apart with swing 8 putting the off-beats 15 ticks late (gaps 75,
  45), from the measured step length.

- MIDI out, `TEST_SEQ=1 TEST_MIDIOUT=1`, VICE with Datel (`-midi
  -miditype 2`) and Namesoft (`-miditype 3`, the NMI path): the bytes the
  handler wrote to the ACIA, logged with their tick, are the same on both:
  a clock every 10 ticks (125 BPM), and on each step its notes (MAIN step
  0: `99 24 7f 89 24 00 99 2a 64 89 2a 00`) within 1-2 ticks after the
  step's clock. (The start byte is missing there only because TEST_SEQ
  starts playing before the interface is set up.)

- `TEST_MIDI=5 TEST_CLOCK=1 TEST_REC=1`: MIDI clock and live record. A
  note between start and the first clock -> step 0; one in the same feed
  entry as the clock starting step 4 -> step 4 (it went to step 3 before
  the fix: the step was due but not yet fired); one right after step 8's
  clock -> step 8. Each sounds once, then from its step each pass, also
  after a second start (which first kept the old clock count: a cell on
  step 1 and a double hit).

## Measured (phase D, VICE)

- `TEST_KEYS=4`: builds the song [pattern 1 x2, pattern 2 x1] with P, ;,
  the song cursor and a deleted third entry, then plays it in song mode.
  Memory: length 2, patterns 0 1, repeats 2 1; logged pattern starts 1 1 2
  1 1 2 ... (over 80 bars).

- `TEST_MIDI=3` with `TEST_SEQ=1 TEST_SEQ_PAT=8 TEST_REC=1` (FULL
  recording at 125 BPM; tables.py `rec_test_pattern` times the notes
  against the sequencer's own phase): low tom soft just after step 1 ->
  step 1; mid tom 1 tick before step 5 -> step 5; high tom accent at 49 %
  of step 8 -> step 8; rim at 51 % of step 9 -> step 10; claves in the tick
  step 12 fires -> step 12; cymbal accent at 51 % of step 15 -> step 0.
  Memory: those six cells with levels 1 2 3 2 2 3. Voice-start log: each
  note sounds once when played, then each pass from its step (the claves
  on step 12 is dropped there by the voice rule: four sounds on three
  voices, the claves the weakest).

## Ring cowbell (VICE)

- Voice-start log, compared with the build before it: FULL, FULL_CYM,
  ROLL, the 13-sound step and the demo track start the same sounds on the
  same steps (once the pair had to leave room for the step's later hits:
  without that, FULL's soft closed hat on step 6 was lost every bar).
- CPU (`TEST_CPU`, 65535 ticks): FULL longest tick 2655 (before 2641),
  over budget 448 (323); MAIN_CB 3118 (2666), 472 (343); 13 sounds 2423,
  2 behind. The long ticks are ordinary hits on a busy engine; a ring
  cowbell's pair search adds a few hundred cycles in its tick.

## Measured (phase C, VICE)

- `TEST_KEYS=1`: a scripted edit of two patterns; memory matched the
  expected end state.
- `TEST_KEYS=2`, editing while playing: F1 pressed at step 4 of pattern 1;
  pattern 2 started at the next step 0. Its length cut from 16 to 4 while
  it played step 10: the next step was 0, then it looped 0-3.
- `TEST_KEYS=3`: all 13 sounds on one step, for the CPU measurement above.

## SysEx dumps (2026-11-19)

The song file goes to a PC and back over MIDI as SysEx (the core's
`MIDI_SYSEX`, `src/dumps.asm`, the PC tool `core/sysex.py`), byte for byte
as its disk file. SID808 is synth 2; D on the grid sends it (as a
request does); with MIDI out on a playing sequencer stops first. A dump
coming in silences SID808, is staged, and loads like a disk file when
whole: versions 1 and 2 too (the knobs they lack at their defaults).

SID808's file is 13.5 KB (the 64 patterns of 13 sounds), so:

- it is staged at $C800-$FEFF, under the I/O chips too (the core's
  `SYSEX_UNDER_IO`: each byte stored and read with I/O banked out);
- a dump takes ~5 s on the wire;
- the ~1.5 KB of code took the room of 4 undo steps (12 now), and the
  self-playing builds leave the dumps out (`DUMPS=0` in build.sh: with
  them the six programs don't fit on the disk); the stress builds have 8
  undo steps, the problem demo 6, `tools/pattern_check.py`'s builds 4.

`tools/dump_check.py` checks it in VICE with the core's test loop
(`TEST_SYSEX=4`: what is sent comes back in; a test feed of 13.5 KB
wouldn't fit beside the program): D's dump, staged, equals the file saved
to disk byte for byte and loads; versions 3, 2 and 1 load with the knobs
as disk_load leaves them, version 4 is refused (`SYSEX: NOT A SID808
FILE`); a dump while the sequencer plays stops it and loads. The message
format is checked byte for byte by SID101's and SID303's checks.
