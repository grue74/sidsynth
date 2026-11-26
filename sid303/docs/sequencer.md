# SID303 step sequencer

Design, 2026-11-18. Modelled on SID808's sequencer (`../sid808/docs/sequencer.md`,
`src/sequencer.asm`, `grid.asm`, `undo.asm`, `disk.asm`).

**Status:** all phases (A-F) done on 2026-11-18 and checked in VICE
(`python tools/seq_check.py`, results under "Measured" below). The user
manual and the site describe it. Not yet tried on real hardware: disk on a
1541 / SD2IEC, and following SID808's MIDI clock through the Kerberos.

**Where the code is:** the playing part (patterns, transport, tempo and
swing, songs, MIDI clock in and out) moved into the core on 2026-11-18, as
`core/sequencer.asm`, with its tables in `core/tables_core.py`
(`seq_tables`), so SID101 can use it too. SID303's binaries stayed byte
for byte the same. The step screen, undo and disk are still SID303's own
(`src/steps.asm`, `src/undo.asm`, `src/disk.asm`).

Decided with the user 2026-11-18:

- a vertical step list, one row per step (tracker style)
- on the step screen the note keys enter the pitch at the cursor
- the generic parts are copied from SID808 and adapted; whatever turns out
  the same in both goes into synthcore later, with SID808 rebuilding
  byte-identical
- the first version has MIDI clock in, MIDI out, song mode with undo, and
  disk save/load
- in Omni, notes on channel 10 (the GM drum channel) are ignored, so
  SID808's MIDI out doesn't play into the bass line
- SID303 starts on the parameter screen, as today

## What a 303 step is

A TB-303 pattern has up to 16 steps. Each step has a pitch and a time
value: a **note** (the gate opens, then closes partway through the step),
a **tie** (the note before goes on through this step) or a **rest**. It
also has two flags. **Accent** plays the note louder, with a short filter
decay and the accent sweep. **Slide** keeps the gate open into the next
step, so the next note glides in with no retrigger.

SID303's engine already does all of this from MIDI. A velocity of 110 or
more is an accent (`ACCENT_VELOCITY`). A note on while the gate is open is
a slide (`note_on`: `gate_bit` set). So the sequencer plays through
`note_on` / `note_off`, just as SID808's grid plays through `note_on`. The
sound engine doesn't change.

## Screen

F7 switches between the step screen and the parameter screen, as in
SID808. The waveform cycle moves off F7 (below). SID303 starts on the
parameter screen, so it still comes up as a synth to play from MIDI. F7
goes to the steps.

```
PAT 01  BPM 125  SW 00  LEN 16  PLAY 01
 ST NOTE A S  C   C   C   C   C   C
>01 A-1  A .  *
 02 ---
 03 A-1  . .  *
 04 ---
 05 A-2  . S              *
 06 G-2  . .            *
 07 ===
 08 A-1  . .  *
 ...       (16 step rows, rows 2-17)
SONG 01/02 >01x2+0 02x1+5 ----
OCT 2  A-1  VEL 127              MIDI
 (help rows 20-24)
```

- **Title row:** pattern, tempo (`EXT` on MIDI clock), swing, length, and
  `PLAY nn` / `STOP`. Same fields as SID808.
- **Step rows:** the play marker (`>`), the step number, then the note:
  a name (`C#2`), `---` for a rest or `===` for a tie. After it come the
  accent and slide flags (`A`, `S`, or `.`), then a piano-roll lane. The
  lane puts one mark per step at its pitch, over 28 semitones from the C of
  the entry octave, and the `C` marks in the header show the octaves. You
  see the line's shape at a glance. Steps past the pattern's length are
  shown dim, and the cursor's row is reversed.
- **Song row:** as in SID808, with each entry's transpose added
  (`01x2+05`). Three entries fit, from the one before the cursor.
- **Status row:** the core's `synth_draw_status`, unchanged.

The screen is drawn through the core's `SYNTH_SCREEN` hooks
(`synth_draw_step`, one row per call; `synth_key`), as in `grid.asm`.

## Keys (step screen)

The note keys (`Z S X D ...`, `Q 2 W 3 ...`) are taken, so the letter
commands from SID808 are the same letters **with C= held**. The grid reads
C= from the core's `key_now`, the way the core reads SHIFT.

| Key | Does |
|---|---|
| note key | the cursor step becomes that note (octave from F5/F6), cursor down; when stopped it also plays the note while held |
| SHIFT + note | the same, accented |
| `A` | accent on / off |
| `F` | slide on / off (A and F sit on either side of the notes' S and D) |
| `=` | tie, cursor down |
| SPACE / DEL | rest, cursor down / rest, cursor stays |
| CRSR down / up | cursor (auto-repeat) |
| CRSR right / left | the cursor's note +/- 1 semitone (as values on the parameter screen) |
| `+` / `-` | pattern length 1..16 |
| F1 / F2 | next / previous pattern (it plays from the next pattern start) |
| F3 / F4 | tempo +/- 1 BPM |
| C= + F3 / F4 | swing +/- (0..15) |
| F5 / F6 | entry octave up / down (as on the parameter screen) |
| HOME / CLR | cursor to step 1 / clear the pattern |
| RUN/STOP | play / stop |
| F7 / F8 | parameter screen / all notes off |
| C= + `C` | copy the pattern to the next one |
| C= + `S` | song mode on / off |
| C= + `,` / `.` | song cursor back / on |
| C= + `P` | put the pattern into the song at the cursor |
| C= + `;` (SHIFT: back) | the entry's repeats 1..9 |
| C= + `+` / `-` | the entry's transpose -12..+12 |
| `←` | delete the song entry |
| C= + `U` (SHIFT: redo) | undo / redo |
| C= + `W` / `L` | save / load |

**Parameter screen:** F7 now switches to the step screen. The waveform
stays in the parameter list and can be set by MIDI CC or a paddle, but
loses its one-key cycle. (SHIFT+F7 = F8 stays all notes off.) The manual
and help text change to match.

## Data

A page per pattern, as in SID808: 64 patterns at $8000-$BFFF. The undo
ring copies pages, and copy/clear work on pages, so the code ports with
small changes. RAM is not short: the program ends at about $1F60.

| Offset | What |
|---|---|
| $00-$0F | each step's MIDI note (24..71 in use: C1..B3, plus room for transposing) |
| $10-$1F | each step's flags: bits 0-1 time (0 rest, 1 note, 2 tie), bit 2 accent, bit 3 slide |
| $20 | length, 1..16 |

`PAT_BYTES` = 33 go to disk. The default patterns come from `tables.py`.
Pattern 1 is the test acid line (`TEST_MIDI=1`), so a fresh start plays
what the demos play. A few more come from the presets' demo lines.

## Playing

Each engine tick, after the sound engine, `seq_tick` runs (`synth_tick`
calls it last). Tempo, swing and the song chain work as in SID808: a 16-bit
step phase, `bpm_inc` tables from `tables.py` for the real 250 Hz tick
(985248 / 3941), and off-beats delayed by swing / 32 of a step.

When a step fires, the sequencer keeps `seq_note` (the note it has
sounding, $FF = none) and `seq_gate` (time to gate off, 0 = none). The
gate-off is decided when a note *starts*, by looking at the step after it.
That is the next step of the pattern, or step 1 of whatever plays next
after the last step, the same answer `seq_next_pat` gives (as SID808's
`rec_quantise` does):

- **The note continues:** the next step is a tie, or this step has the
  slide flag. Then no gate-off is scheduled; the next step decides again.
- **Otherwise** the gate closes after `GATE_LEN` sixths of the step (tables.py,
  default 3: half, as on a 303). With the internal clock this is counted
  in ticks from when the step really fired, so a swung step gets its full
  gate (a `bpm_gate` table per tempo). With MIDI clock it is counted in
  clocks (3 of the step's 6), which needs no measured step length and so
  works from the first step after Start.

Each step, in this order:

1. **Release what doesn't continue.** If a note is still held (by a slide
   or a tie) and this step neither ties it nor is a note that slides from
   it, `note_off(seq_note)`. This covers a slide into a rest, and a tie
   edited to a rest while it plays.
2. **note:** if `seq_note` is held, the new note goes on *first* and then
   `note_off(seq_note)` follows. The engine sees an overlap, so it slides.
   Otherwise `note_on` starts it fresh. Velocity is 127 if accented, else
   100.
3. **slide to the same pitch:** `note_on` would take the note off the
   stack and push it again, and the `note_off` after it would then close
   the gate. So when the new note equals the held `seq_note`, the
   sequencer sends nothing: it plays as a tie.
4. **tie:** nothing is sent. A tie after a rest, or with nothing held (on
   step 1 at play), plays as a rest.

Accent on a note that is slid into is lost: `note_on`'s legato path
returns before the accent is set. That holds for any pitch, not only the
same one. It's how the engine treats MIDI legato today; change it later if
it sounds wrong.

**Transpose:** song entries add their transpose to the note at fire time,
clamped to the frequency table's range (MIDI 12..107).

**Stop** sends `note_off(seq_note)`. The note ends as it would after a
release; nothing else is cut off.

**Live notes:** MIDI in and the parameter screen's keys still play through
the same `note_on`. Played over a running pattern, they mix like two held
notes on a mono synth: legato and slides between them. That is fine for
jamming. The step screen plays its note keys only when stopped, so editing
during playback never sounds a stray note. (Live transpose by MIDI note, as
in a 303's track mode, is a candidate for later.)

**No hit budget.** There is one note event per step, not up to 13 hits,
so SID808's `seq_hits`, `HIT_CYCLES` and `fire_order` don't come across. A
tick is 3940 cycles. The engine's tick and the sequencer fit with room to
spare; `TEST_TIMING` will show it.

**The 250 Hz tick** stays: going to 500 Hz would change every envelope and
slide table. Its cost is 4 ms resolution: 30 ticks per 16th at 125 BPM, so
swing moves in steps of about 1/30 of a step (SID808: 1/60). The gate
length and MIDI clock latency (at most one tick) are also in 4 ms steps.
None of that is audible on a bass line.

## MIDI clock in and out

The same as SID808 phase E, with the same `Clock` and `MIDI out` parameters.

- **In** (`MIDI_REALTIME = 1`): start, clock (6 per step), continue, stop.
  This way SID303 follows SID808 (or any master): two C64s live, instead
  of two recordings lined up afterwards.
- **Out** (`MIDI_OUT = 1`): the steps as notes on the MIDI channel (Omni:
  channel 1). Accent is velocity 127, others 100. Note off comes at
  gate-off, and a slide is an overlap: the next note on goes before the
  note off, which is how 303 clones and most monosynths take legato. With
  the internal clock, also start, clock and stop.

The README's "realtime bytes ignored" changes to say this.

**Channel 10 in Omni.** SID808's MIDI out sends its hits on channel 10.
With SID303 on Omni (the default), following SID808's clock would also
play the drums into the bass line. So in Omni, notes on channel 10 are
ignored. This is a new weak core option, `OMNI_SKIP_DRUMS`, default 0 so
SID808 builds byte-identical; SID303 sets 1. Controllers on channel 10
still count, and choosing channel 10 by hand still plays it.

## MIDI control

Pattern select, song select and song position over MIDI (the core's
`PATTERN_CC` and `MIDI_SYSTEM`, the sequencer module's `seq_pattern`,
`seq_song_select`, `seq_song_position`; core/README.md has the rules):

- Controller 85, value 0-63: that pattern plays from the next pattern
  start, as F1/F2 choose it (stopped: from play); the step screen shows it;
  song mode goes off. 64-127: nothing. Only on SID303's channel: in omni
  it is ignored, so one message can't switch every synth on the cable.
  Learn can't take controller 85.
- Song select (any number): song mode on. SID303 holds one song.
- Song position, with Clock on MIDI and stopped (ignored otherwise): the
  next Continue plays from there. In steps (a MIDI beat is a 16th); the
  song's length is the sum of each entry's pattern length times its
  repeats, and the position wraps at it; the entry plays with its
  transpose, the repeats before it counted off. Without a song, the queued
  pattern's step, the position modulo its length. Start forgets it.

`tools/pattern_check.py` checks it in VICE: wrapper builds with a MIDI feed
of their own (`TEST_MIDI=99`, `TEST_CHANNEL`), their note logs against
`tools/seq_check.py`'s model (its `switch` and `locate`).

## Song mode and undo

As in SID808: up to 64 entries, each a pattern with 1..9 repeats, plus a
transpose of -12..+12 (one more byte, a 303's track mode does the same).
They play in a loop. Undo has 16 steps, a page ring at $7000-$7FFF, and
covers step edits, length, clear, copy and song edits. A step's note, time
and flags count as one edit.

Live record isn't in the first version: notes are entered step by step.

## Disk

As in SID808 phase F (`disk_run`: stop, interrupts off, zero page swap,
KERNAL in, then everything back). This needs `KERNAL_ZP_COPY`. One PRG
file holds, in order:

1. the magic `SID303` and a version byte
2. the 64 patterns (33 bytes each)
3. the song block
4. tempo and swing
5. the sound parameters (Cutoff to Volume), so a song comes back with its
   sound

Channel, interface, paddles and the clock settings are left out: they
belong to the setup, not the song. About 2.4 KB, 10 blocks. The `Disk
drive` parameter is the same as in SID808. After a load, `param_changed`
runs for each sound parameter, so the SID and the screen follow.

## Parameters

Three new ones after `P_PADDLES`, as in SID808: `Clock` (Internal / MIDI),
`MIDI out` (Off / On) and `Disk drive` (8..16). That makes 21. The
parameter screen has rows 1-18 and is full, so the core gets a weak
`STATUS_ROW` option. It defaults to 19, so SID808 builds byte-identical.
`HELP_ROW0` becomes `STATUS_ROW + 1`, with a check that the help rows end
by row 24. SID303 sets 22, and its parameter-screen help shrinks to two
rows (the step screen has its own help).

Later (build 34) the parameter screen was split into two pages, with the
core's `PARAM_PAGE2` option (default 0, SID808 byte-identical): **Sound**
(Cutoff to Volume) and **Setup** (MIDI channel to Disk drive). The page
holding the selected parameter is shown and named in the title row, and
a grey hint under each page's last parameter says where the other one is.

## RAM

| Where | What |
|---|---|
| $1F60-$6FFF | free (program ends ~$1F60 today; the sequencer adds a few KB) |
| $7000-$7FFF | undo ring, 16 pages |
| $8000-$BFFF | patterns, a page each |
| $C000 | MIDI receive ring (core) |
| $C100 | `key_note` (core) |
| $C140 | `note_stack` (8 bytes); $C148 `audition_bits`, $C150 `note_key_mask` (step screen) |
| $C200 | `cc_map` (core) |
| $C300 | MIDI transmit ring (core, `MIDI_OUT`) |
| $C400 / $C500 | our zero page / the KERNAL's, during a disk operation |
| $C600 | disk variables |
| $C700 | song block: 64 patterns, 64 repeats, 64 transposes, length (193 bytes); undo variables after it |
| $C800 | the song row's message (undo's), 40 bytes |

Zero page now ends at $7D, which leaves room for the sequencer's 30 or so
variables.

## Phases

| Phase | What |
|---|---|
| A | Core: the `STATUS_ROW` and `OMNI_SKIP_DRUMS` options (SID808 byte-identical). SID303: `SYNTH_SCREEN`, 21 parameters, F7 switches screens (the `TEST_KEYS=1` script taps F7 for the waveform: it changes, and the `compare_screens.sh` baselines with it) |
| B | Engine: pattern data, the default patterns, tempo and swing tables for 250 Hz, play/stop, note/tie/rest/accent/slide through `note_on`/`note_off`, gate timing |
| C | Step screen: the list, cursor, note entry, flags, length, pattern select, copy/clear |
| D | Song mode with transpose, undo |
| E | MIDI clock in, then MIDI out |
| F | Disk save/load |

## Checks

- **B:** `tools/seq_check.py`: note logs (`TEST_LOG`) of pattern 1, the
  edge cases and swing against a model of the rules; pattern 1 against the
  same line fed through the MIDI parser (`TEST_MIDI=1`); tempo at 60, 120
  and 240 BPM; play/stop from the keys. Results under Measured (phase B).
  The sound is the same `note_on`/`note_off` path MIDI uses, so recordings
  weren't compared.
- **C, D:** `TEST_KEYS` scripts that edit, check memory, undo and redo, as in
  SID808's `TEST_KEYS=1`, `4`, `12`, `13`.
- **E:** `TEST_MIDI` feeds with clock, start, stop and continue (SID808's
  `TEST_MIDI=4`), and MIDI out bytes logged on Datel and Namesoft in VICE.
  Then on the real C64 with the Kerberos: SID808 as master, SID303 following.
- **F:** a save, clear and load round trip on a .d64 (SID808's
  `TEST_KEYS=5`, `6`, `7`), with and without JiffyDOS.

## Measured (phase B, VICE)

`python tools/seq_check.py` builds `TEST_LOG` programs (every note on and
off logged with its tick at $6000), runs them headless and checks:

- **Pattern 1** (the acid line, 125 BPM): 133 note events over four bars
  equal the model (`model()`: the rules above, written in Python, tick by
  tick) note for note and tick for tick.
- **Edge cases** (tables.py `EDGES`, `TEST_EDGES=1`): equal the model, 49
  events. In the first bar:
  - the same-pitch slide plays on as a tie, and with the tie after it, A-1
    holds until half way through step 3 (75 ticks)
  - the tie after a rest stays silent
  - the accented C-2 sliding into a rest ends at the rest's start
  - D-2, tied with a slide, glides into E-2
  - at the end, A-2 on step 16 slides into the next bar's A-1
- **Lengths and the next pattern** (`TEST_EDGES=2`, `TEST_SEQ_NEXT=1`): a
  6-step pattern once, then a 5-step one looping, equal the model (81
  events). The last step of the first slides into the second's first
  step, a tie, so A-2 holds into it; the second pattern's last note goes
  on into its own tie on every pass.
- **Swing 8:** the same with the off-beats 7 ticks late (steps 37 and 23
  ticks apart).
- **Against the MIDI feed** (`TEST_MIDI=1`, the same line through the
  parser): the first 64 note-ons on the same ticks, with the same notes,
  velocities and slides. The note-offs differ as designed (gate 6/10
  against 3/6).
- **Tempo** 60, 120, 240 BPM: 30 bars at the model's ticks. The whole-number
  phase increment puts the real tempo at 60.024, 119.991 and 239.982 BPM
  (+0.04 %, -0.007 %, -0.007 %).
- **RUN/STOP** on the step screen (`TEST_KEYS=5`): 22 notes in 2.6 s, then
  stop with no note left sounding. It goes to the parameter screen and
  back while playing.
- **Lag:** in every run no tick waited behind another (`LOG_LAG`, the most
  ticks left waiting when a tick ran, is 1: the one running). The logged
  ticks are ticks run, so without this a backlog wouldn't show. It found
  the screen switches: drawing a whole screen at once (the step screen's
  frame, the core's `screen_init` going back) took 4-5 ticks. Both frames
  are now drawn a row per draw step. The way back draws what `screen_init`
  would, and the keys go to the parameter screen at once. SID808 has the
  same hiccup, so this belongs in the core one day.

Sequencer notes fire at the start of a tick, before the sound engine, so
they sound in the tick they are logged. MIDI notes come between ticks and
sound from the next one.

## Measured (phase C, VICE)

`tools/seq_check.py`, added to the phase B checks (all still pass):

- **Editing** (`TEST_KEYS=6`). The script:
  - enters notes, an accented note (SHIFT), a tie, a rest, slide and
    accent on a note, two semitones up, a note in another octave
  - cuts the length to 6 and back to 7
  - copies the pattern (C=+C), clears another (CLR), rests step 1 (DEL)
  - sets tempo 128 and swing 2 (C=+F3)

  Patterns 2-4 and the editor's variables then hold exactly what the
  script means. The first run found two bugs: the flags were stored at
  `shift_held`'s value as the offset, and C=+C entered a note (C is a note
  key). C= is now checked before the note keys.
- **Auditions** (`TEST_KEYS=7`): a note key held on the parameter screen
  through F7, and one held on the step screen while RUN/STOP starts the
  pattern. Every note got its note off, and at the end no note is held and
  the gate is closed. A note key's release goes to the core exactly when
  its press did (`audition_bits`), whatever happened in between. When the
  step screen opens, the keys already held count as auditioned.
- **Lag:** still at most one tick in every run. `steps_take` once looped
  over all 64 keys while playing (2 ticks): it now ANDs the held keys with
  a note-key mask built at start.

Screen: each row is drawn with its step's note, flags and lane mark. A tie
shows `===` with its mark at the pitch of the note above. Steps past the
length are dim, and the numbers of steps 1, 5, 9 and 13 are white. The
cursor's row is reversed, and `>` follows the step playing.

## Measured (phase D, VICE)

`tools/seq_check.py`, added to the earlier checks (all still pass):

- **Song** (`TEST_SONG=1`): three entries over the two short test patterns:
  pattern 1 twice, pattern 2 once transposed +5, pattern 1 once transposed
  -12, in a loop. 99 events equal the model. The model now plays a list of
  passes, each a pattern and a transpose, with the lookahead into the next
  pass, and folds transposed notes into MIDI 12..107 as `transpose_note`
  does.
- **Undo and the song keys** (`TEST_KEYS=8`):
  - five step edits; two undone, one redone
  - `+` at length 16, which saves no step
  - a length edit, which drops the redo
  - a redo with nothing to redo
  - two song entries put, repeats and transposes changed, an entry deleted
    and the delete undone

  Pattern 2, the song (2 entries, patterns 2 and 1, repeats 3 and 1,
  transposes +2 and 0), the undo counts (13 to undo, 1 to redo) and the
  message state are as scripted.
- **Lag:** the runs that play still never fall behind. An undo of a song
  edit swaps the 193-byte song block with its page (~6000 cycles, 1.6
  ticks). In the editing run that left one tick waiting; while a pattern
  plays it would make one tick 4 ms late, once per such undo. Accepted.
- **Play marker:** while playing, the rows are redrawn about one per scan,
  so a row's own `>` lagged several steps (two markers on screen at once).
  `marker_update` now moves the marker's two cells as soon as the step
  changes.

## Measured (phase E, VICE)

`tools/seq_check.py`, added to the earlier checks (all still pass):

- **MIDI clock in** (`TEST_MIDI=5`, `TEST_CLOCK=1`): Start, a clock every 5
  ticks (125 BPM) for two bars, Stop, 100 ticks of silence, Continue, one
  more bar, Stop. 96 note events equal the model. The model plays the same
  feed, handling each realtime byte before the next tick as the main loop
  does. After Continue the pattern goes on from where it stopped. The gate
  closes 3 clocks after the step fired.
- **Clock in with swing 8:** the same, with the off-beats late by a quarter
  of the step length measured between the clocks; equal to the model.
- **MIDI out, internal clock** (`TEST_MIDIOUT=1`): the 797 bytes queued over
  four bars equal the model:
  - start before the first tick
  - the first clock with step 1, then 6 a step
  - note on (`$90`, velocity 100 or 127) and note off (`$80`, 0) on
    channel 1
  - a slide as the new note's on before the old note's off
- **MIDI out with clock in:** the notes only (288 bytes), no realtime bytes:
  with MIDI clock in, the master sends those.

This checks what the sequencer queues (`out_byte`, logged at $5000 in
`TEST_LOG` builds). Sending the queue through the ACIA is the core's
(`MIDI_OUT`), checked in SID808 phase E on Datel and Namesoft in VICE. Not
yet tried: SID303 on real hardware following SID808's clock.

## Measured (phase F, VICE)

`tools/seq_check.py` builds each disk test, puts it on a .d64 as "SID303"
(`c64tools/d64.py`) and runs it with drive emulation:

- **Round trip** (`TEST_KEYS=9`):
  - Cutoff 100 and a song entry, then save "t1"
  - clear pattern 1, tempo 126, delete the entry, Cutoff 108
  - load "t1"

  Pattern 1 is the acid line again, tempo 125, the song entry is back,
  Cutoff 100, nothing to undo, and the drive says `00, OK,00,00`. The same
  with JiffyDOS.
- **Not ours** (`TEST_KEYS=10`, loading the program itself): `NOT A SID303
  FILE`, nothing changed.
- **Missing file** (`TEST_KEYS=11`): the drive's `62, FILE NOT FOUND,00,00`,
  nothing changed.
- **No drive** (`TEST_KEYS=12`, Disk drive 9 with none there): `NO DRIVE 9`,
  nothing changed.
- **Save while playing** (`TEST_KEYS=13`): saved (`00, OK,00,00`), and
  afterwards stopped, no note held, the gate closed.

All earlier checks still pass. The tempo runs now get 20 s of warp: at 10
s the 60 BPM run sometimes logged only 25 of its 30 bars, depending on
how fast the PC ran VICE.

Not done yet: on real hardware (a 1541 and SD2IEC with the Kerberos).

## SysEx dumps (2026-11-19)

The song file goes to a PC and back over MIDI as SysEx (the core's
`MIDI_SYSEX`, `src/dumps.asm`, the PC tool `core/sysex.py`), byte for byte
as its disk file (2331 bytes). SID303 is synth 1; C= + M on the step
screen sends it (as a request does); with MIDI out on a playing sequencer
stops first. A dump coming in silences SID303 at once, is staged under the
KERNAL ($E000), and loads like a disk file when whole (`song_loaded`, now
shared with `disk_run`); else nothing changes and the song row says why.
`tools/dump_check.py` (from SID101's) checks it in VICE: the dump by key
equals the file saved to disk byte for byte; requests for another synth or
device are ignored; a request while the sequencer plays (MIDI out off)
lets it play on; a dump loads, also while the sequencer plays; a bad sum,
a cut dump and a SID101 file change nothing. Test builds check that the
code stays below the logs at $5000.

## Presets (2026-11-19)

32 presets of the 15 sound parameters and a 12-character name, ported
from SID101 (`src/presets.asm`): C= + F3/F4 recall, C= + RETURN stores
(the status row's prompt: slot with F3/F4, the name typed), C= + W/L a
bank file of its own ("s303bank", 4 blocks; `disk.asm` is SID101's now),
C= + M the bank as a SysEx dump (kind 1), MIDI program change 0-31
recalls (core `MIDI_PROGRAM`). A recall sets all but Tune and Volume;
when Waveform, Square tilt or Body change under a sounding note it is
retriggered once. The title row shows `01*Classic acid` (`*`: edited).

The factory set (`tables.py` FACTORY): 1 the start sound (Classic acid,
as before), 2-6 the manual's starting points, 7-22 more acid sounds, 23-32
`Init`. They sit after the code (`presets.inc`, copied to $C900 at start,
so the test logs may overwrite them). `TEST_MIDI=6` with `TEST_SEQ=1`
plays each factory preset for two bars of pattern 1
(`demos/presets/factory.wav`).

`tools/preset_check.py` (from SID101's) checks it in VICE: the slots at
start, every slot by program change (TEST_MIDI=7: exactly its values but
Tune and Volume, edited before each but the first, programs 40 and 127
ignored), the keys (TEST_KEYS=16: step, store under a typed name, a note
held across the prompt), the bank file (17-19: round trip, and refusals),
and a load test (TEST_MIDI=8: program changes every 40 ticks and a
controller every other tick while pattern 1 plays on the step screen).
`tools/dump_check.py` adds the bank by C= + M and a bank dump in.

