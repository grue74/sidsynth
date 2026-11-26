# SID101 first version: plan

Written 2026-11-18, from `design.md` (all its start-up questions settled).
SID303 is the model for the code. Every stage that changes the sound ends
with a **sound demo**: a `TEST_MIDI` build recorded in VICE on an 8580
(real time, `-sidenginemodel 257`) into `demos/`, with a listening guide
(timestamps, what to listen for). The user listens before the next stage.

| Stage | What | Demo |
|---|---|---|
| A | The SH-101 voice on the core: notes (held-note stack, legato, glide Off/On/Auto), saw + pulse + sub (three sub types) with three mix levels, PW and PWM, one ADSR for filter and amp (amp: Env or Gate), the log cutoff with env mod, one triangle LFO to pitch, PW and cutoff; the parameter screen (two pages), keys, paddles | `demos/a-voice.wav`: bass, squelch, lead, filter sweep |
| B | Sync mode: the Voice mode parameter, voice 1 synced to voice 3, the sweep's envelope amount; ring modulation if it fits | `demos/b-sync.wav` |
| C | More playing: LFO shapes (square, random, noise) and delay, mod wheel to LFO depth, accent (velocity) | `demos/c-modulation.wav` |
| D | The sequencer: the core's `sequencer.asm`, a step screen, undo and disk from SID303 | `demos/d-sequencer.wav` |
| E | The arpeggiator: up, down, up and down, random, 1-3 octaves, internal or MIDI clock | `demos/e-arpeggiator.wav` |
| F | Manual, the web page in the SidSynth site, the disk image, real hardware checks by the user | the demos on the page |

## Stage A: status (2026-11-18)

Built: `sid101.asm` and `src/` on the core, 24 parameters on two pages
(Sound, Setup), every sound parameter on a MIDI controller (`src/params.asm`,
`tables.py` `CC`). `tools/voice_check.py` passes in VICE: the demo's 122
note events in order and on time, the engine at most 1 tick behind (the
longest tick ~2300 of 3941 cycles: `TEST_PROFILE=1` builds time each part),
no sustain level raised under an open gate, every ADSR rate 0, the sub 1 or
2 octaves under voice 1.

The demo, `demos/a-voice.wav` (`sid101-demo.prg`, 20.3 s, 125 BPM):

| Time | Section | Listen for |
|---|---|---|
| 0:00 | bass: saw + sub, amp on Gate, short filter envelope | the glides between legato notes (glide Auto) |
| 0:04 | squelch: resonance 13, more env mod, the cutoff opening step by step | the resonant pluck; zipper or clicks |
| 0:08 | lead: saw + pulse with PWM, filter attack, glide On; vibrato from 0:11.6 | the PWM's chorus-like movement, the glides, the vibrato |
| 0:15.5 | sweep: saw + pulse + sub two octaves down, LFO on the cutoff, cutoff opening | the sub's weight, the LFO wobble, the release at the end |

The user's verdict (2026-11-18): "its sounds awesome, last sound had
_bass_" (the sweep with the sub two octaves down). So Sync mode keeps the
sub: voice 2 syncs to voice 1 (the SID's sync pairs), voice 3 stays the sub.

## Stage B: status (2026-11-18)

Built: the Voice mode parameter (101, Sync). In Sync mode voice 2 is a saw
hard-synced to voice 1 (the master, at the note; its level is Saw, and at
level 0 it still drives the sync), at the note + Sync pitch (0..255 = up to
48 semitones) + the envelope x Sync env (up to 48 more); the sub stays on
voice 3. The parameters now fill page 1 (Sound, 17); the LFO and glide moved
to page 2 (Play). `tools/voice_check.py` checks both demos: notes, lag at
most 1 tick (the longest tick ~2560 cycles in Sync mode), SID writes, and
the synced voice never below the note.

Found on the way: a line's last note overlapped the next section's first
note, which then played legato and kept the old levels (the SID can't raise
them): the hand sweep was 10 dB quiet and demo A's first lead note had no
pulse. `tables.py`'s `Demo.line` now ends a line's last note before the next
section; both demos re-recorded.

The demo, `demos/b-sync.wav` (`sid101-sync.prg`, 16.4 s, 125 BPM):

| Time | Section | Listen for |
|---|---|---|
| 0:00 | sync riff: the synced saw over the sub, its pitch swept down by the envelope at every note | the tearing attack of each note |
| 0:04 | Sync pitch by hand: one held note, the sync pitch turned up (to 0:06) and back down | the classic sync sweep, smooth or stepped |
| 0:08 | sync bass: demo A's bass line, saw + synced saw + sub, a short sweep, amp on Gate | the bite on each note, the bass under it |
| 0:11.5 | sync lead: long notes, the synced voice higher, slower sweep, vibrato, glide | the sweep's tail, the glides |

The user's verdict (2026-11-18): "demos sounded ok".

## Stage C: status (2026-11-18)

Built: four new parameters on page 2 (Play), 31 in all:

- **LFO shape:** triangle, square (the phase's top bit), random (a new
  value at the start of each cycle: sample and hold) and noise (a new value
  every tick; the rate does nothing). The random values come from a 16-bit
  LFSR, 8 steps a value.
- **LFO delay:** 0 = none, 1..15 = a linear fade-in of 0.1..4 s after each
  fresh note (legato notes keep the fade going). It scales the LFO itself,
  so vibrato, PWM and LFO cutoff fade in together (and the mod wheel's
  vibrato too, during the fade).
- **Mod wheel** (CC 1, 0..255): adds to the vibrato depth, on top of
  Vibrato, as the SH-101's modulator grip; full wheel = full depth. As a
  parameter it can also be given to a paddle.
- **Accent** 0..15: velocity, latched at each fresh note. A soft note's
  level falls (at accent 15 velocity 1 sounds at about half the level), a
  hard one's env mod rises (from velocity 64 up, up to +255 at 127). Velocity
  can only lower the level: the mix level is the top, and the SID can't
  raise a held voice's level. Accent 0 = every note the same, as before.

With everything at its default (triangle, no delay, wheel 0, accent 0),
demos A and B give exactly the same SID writes as before Stage C (checked
against dumps of the Stage B build).

Found on the way: the core's parameter screen read the names with an
8-bit offset (index x 12), so from the 22nd parameter on it showed other
names (Stage B's 27 already did). The core now has `PARAM_NAMES_LONG` (off
by default; SID303 and SID808 build byte-identical), on in SID101; without
it more than 21 parameters is a build error.

`tools/voice_check.py` checks all three demos: notes, lag at most 1 tick
(the longest tick ~2820 of 3941 cycles, in demo C's last section: Sync
mode, noise, fade, vibrato, wheel and accent at once), the SID writes, and
a new check: voice 1's level at each fresh note against a model (the demo's
controllers replayed, Saw level x the accent table).

The demo, `demos/c-modulation.wav` (`sid101-mod.prg`, 27.6 s, 125 BPM):

| Time | Section | Listen for |
|---|---|---|
| 0:00 | random: one held note, sample and hold on the cutoff, resonance 12 | the classic random burble, a new step every cycle (~6.5 a second) |
| 0:03.8 | square: a trill (the square on the pitch, a semitone each way); from 0:05.8 the square on the pulse width and a little on the cutoff | the trill's evenness; the PWM jumping between two widths |
| 0:07.7 | LFO delay: four long fresh notes, the vibrato (and PWM) fading in over ~1.4 s on each | each note starting straight |
| 0:11.5 | mod wheel: one held note with no vibrato set, the wheel up over a bar, then down | the vibrato growing and fading with the wheel, no steps |
| 0:15.4 | accent: a bass line, velocities 127 and 70, first at accent 0 (all alike), from 0:19.2 at accent 15 | the accented notes louder and squelchier, the others quieter and duller |
| 0:23.0 | noise and everything: Sync mode, noise on the cutoff, delayed vibrato, accent, the wheel | the grainy sync lead; the engine's worst case |

The user's reply (2026-11-18): "go on". The question of the accent range
(at accent 15 a velocity-70 note is only ~3 dB quieter than a 127 one) is
still open.

## Stage D: status (2026-11-18)

Built: the core's sequencer (`core/sequencer.asm`) and, copied from SID303,
the step screen (`src/steps.asm`, F7), undo (`src/undo.asm`) and disk save
and load (`src/disk.asm`: patterns, song, tempo, swing and the sound
parameters Cutoff to Volume, 28 of them; the file magic "sid101"). Three
setup parameters at the end of page 2: Clock (internal or MIDI), MIDI out,
Disk drive (34 parameters). The sequencer's notes go through SID101's
note_on / note_off like MIDI: a slide is a legato note (glide Auto glides
it), an accented step comes at velocity 127, the others at 100, so the
Accent parameter decides what an accent does (at 0, nothing).

Four patterns at start (`tables.py`): 1 a bass line with slides and
accents, 2 a lead with ties, 3 an octave riff, 4 a 12-step bounce.

Checks:
- with the sequencer stopped, demos A, B and C write exactly the same SID
  values as in Stage C; `tools/voice_check.py` ALL PASS;
- `tools/seq_check.py` (SID303's, ported): ALL PASS: the playing against
  its model (pattern 1, the edge cases, lengths, swing, a song), the keys
  (play/stop, editing, auditions, undo and the song keys), MIDI clock in,
  MIDI out, disk (round trip also with JiffyDOS, save while playing, the
  errors), pattern 1 against the same line fed over MIDI, tempo at 60, 120
  and 240 BPM, and a new load test: pattern 3 on the step screen with the
  heaviest sound (Sync, noise, fade, vibrato, wheel, accent), 512 notes.
  Lag: at most 1 tick in every run that plays, 2 in the editing runs (as
  SID303).
- zero page ends at $E6, the program at $407D (test logs from $5000).

The demo, `demos/d-sequencer.wav` (`sid101-seq.prg`: TEST_SEQ=1,
TEST_SONG=2, the song `SONG_DEMO`, with the TEST_MIDI=6 feed setting the
sound for each part; 30.8 s, 125 BPM):

| Time | Part | Listen for |
|---|---|---|
| 0:00 | bass, pattern 1 twice, then +5 (0:03.8) and -2 (0:05.8); accent 10 | the slides gliding, the accented steps |
| 0:07.7 | lead, pattern 2 twice: saw + PWM pulse, delayed vibrato, accent 8 | the ties holding, the vibrato on the long notes |
| 0:11.5 | sync riff, pattern 3: Sync mode, the envelope's sweep; +5 at 0:15.4, back at 0:17.3 | the accented steps biting harder |
| 0:19.2 | bounce, pattern 4 (12 steps) four times, then -5 (0:24.9): random LFO on the cutoff | the 12-step loop against the bar |

Questions for the user: the accent range (above), and whether Accent
should start above 0, so that a fresh start plays the sequencer's
accents (at 0 they do nothing; above 0 the steps at velocity 100 are a
little quieter and brighter than played notes at full level).

The user's reply (2026-11-19): "go on". The two accent questions are
still open.

## Stage E: status (2026-11-19)

Built: the arpeggiator (`src/arp.asm`) and three parameters after Glide
mode on page 2: Arpeggio (Off, Up, Down, Up & down, Random), Arp range (1
to 3 octaves), Arp rate (1/8, 1/16, 1/32); CC 80, 81, 82; saved on disk
with the sound (37 parameters, page 2 now full). How it plays:

- With Arpeggio on, the notes played (MIDI, the C64 keyboard) go to a list
  sorted by pitch (8 keys at most); the arpeggiator plays them through the
  voice one at a time, each a fresh note (the envelope again, accent from
  the newest key's velocity), the gate open half a step (on MIDI clock
  at 1/32: 2 of its 3 clocks).
- Up: the keys upwards, then an octave up per range octave, from the bottom
  again. Down the same downwards. Up & down: the top and the bottom notes
  once each (period 2 x span - 2). Random: any of the same notes
  (r = 5r + 1 mod 256, its high bits x span / 256).
- Keys added or let go while it plays: the list changes and the place in
  the pattern goes on (from the start if it is past the end). The last key
  up silences it at once.
- Internal clock: the steps at the sequencer's tempo (a 1/16 is the
  sequencer's step), the first step a tick after the first key. Clock on
  MIDI: 12, 6 or 3 clocks a step counted from power on or MIDI start (the
  next clock after start is a step), also with the sequencer stopped (a
  new core option, `SEQ_REALTIME_OWN`: SID101's `synth_realtime` sees
  every realtime byte and passes it on to the sequencer's); the first key
  waits for the next step.
- Turned off with keys held: the newest key sounds on in the voice, held.
  Turned on with keys held: it takes them (not while the sequencer plays).
- The sequencer's notes go past it to the voice (synth_tick marks
  `seq_tick`'s calls), so a pattern and an arpeggio can play together.
  MIDI start with the clock on MIDI starts the sequencer too, as before.
- Not done: the arpeggio's notes don't go to MIDI out; with the sequencer
  playing, the arpeggio's steps start from the first key, not on the
  sequencer's grid; no Hold (the SH-101's latch). Random repeats after 256
  steps.
- Disk: the files now hold 31 sound parameters (the arpeggiator's three
  inserted before Tune), with the same "sid101" magic, so a file saved by
  build 9 loads shifted.

Checks:
- `tools/arp_check.py` (new): ALL PASS. A model of the arpeggiator in
  Python against the VICE note log, exact to the tick: every mode, range
  and rate with keys added and let go, a ninth key, off and on with keys
  held, mode and range changed while playing (142 events); on MIDI clock
  with the rate changed, start, stop, continue (88); demo E as written
  (511); the sequencer's pattern 1 with Arpeggio on, exactly as without it;
  the load test (the heaviest sound, pattern 3 on the step screen, eight
  keys at Random, 3 octaves, 1/32): lag 1; and with a controller every tick
  on top (a knob turned fast): lag 1.
- That last test first fell 14 ticks behind: Stage D's heaviest case had
  under 100 cycles a tick to spare while controllers stream in, and the
  arpeggiator takes about 140. Two savings fixed it: the noise LFO's
  `random_byte` does its 8 LFSR steps with a table (exactly the same
  bytes, about 100 cycles less every tick), and the arpeggiator's tick does
  only its phase between steps (the step's length is worked out once a
  step). Demos A, B and C still write exactly the same SID values.
- `tools/seq_check.py`, `tools/voice_check.py`: ALL PASS. SID303 and SID808
  build byte-identical with the new core (709d0f3).
- The screen: page 2 (20 parameters) is now longer than page 1, so page
  1's hint row is page 2's Clock row, and the core's parameter rows never
  write the gaps between their fields (columns 1, 14, 35): two letters of
  the hint stayed there. The hint is now worded to leave those columns
  blank ("Page 2: LFO, glide, arp, MIDI"), checked when assembling. A core
  fix (the rows writing their gaps) would change SID303's and SID808's
  binaries, so it waits for a reason of theirs or an option.

The demo, `demos/e-arpeggiator.wav` (`sid101-arp.prg`, TEST_MIDI=13; 30 s,
125 BPM; every part starts the arpeggiator afresh, the chords change
between two steps without stopping it):

| Time | Part | Listen for |
|---|---|---|
| 0:00 | Up, 1 octave, 1/16: a bass pluck, Cm, Ab (0:01.9), Bb (0:03.8) | the chord changes keeping time |
| 0:05.8 | Up & down, 2 octaves, 1/16: saw and PWM pulse, Cm7, Fm7 (0:08.6) | the turn at the top and bottom, each played once |
| 0:11.5 | Down, 3 octaves, 1/32: the sync lead, Eb, Db (0:14.4) | the fast run down; the sync sweep on every note |
| 0:17.3 | Random, 2 octaves, 1/16, glide On: resonant, Cm9 | the notes gliding into each other |
| 0:23.0 | Up, 1 octave, 1/8, C major; Arpeggio off at 0:26.4 | the newest key (C5) holding on after the arpeggio stops, let go at 0:28.3 |

The user's reply (2026-11-19): "sample sounded good". The accent questions
were left to Claude, and both stay as they are: the range as built (the
demos with accent sounded right), and Accent starts at 0 (the SH-101 has
no accent; at 0 the voice plays the same at any velocity). The manual
says to raise Accent to hear the sequencer's accents and velocity. Hold
and the arpeggio on MIDI out stay out of the first version.

## Stage F: status (2026-11-19)

Built, from SID303's as the model:

- **The manual**, `docs/SID101-manual.pdf` (`docs/manual.py`, reportlab,
  16 pages): getting started, the screen, the keyboard, paddles, every
  parameter on both pages with its range and CC, MIDI and learn, the
  arpeggiator, the step sequencer, making sounds (starting points taken
  from the demos' settings, the demo recordings), troubleshooting, quick
  reference. It says to turn Accent up for velocity and the sequencer's
  accents, and what the arpeggiator doesn't do yet.
- **Screenshots**, `docs/screen.png` and `docs/screen-steps.png`
  (`tools/screenshots.sh`, VICE through `../c64tools/vicecap.py`; the step
  screen from a new `TEST_KEYS=14` build: F7, RUN/STOP, left playing).
  `build.sh` leaves them out of the build number's "uncommitted changes".
- **The icon**, `docs/favicon.svg` and its PNGs (`docs/icon.py`: a white
  sawtooth on the SH-101's blue; the PNGs drawn with Pillow, no SVG
  renderer on this machine).
- **The web page**, `make_site.py` writing `../sidsynth/site/sid101/`: the
  two screens with the facts, the five stage demos as MP3s with a
  waveform each, downloads (disk image, program, manual, the WAVs in a
  zip, the source zip from git), getting started. SID101's card is in
  `../sidsynth/make_site.py`'s `SYNTHS`, and the main page's text names
  three synths.
- **The disk image**, `sid101.d64` (`build.sh`, as before): SID101 and the
  five demo programs.

- **The demo video**, `demos/video-demo.mp4` (47 s, at the user's request
  after Stage F: "a simple lead with some slides and a filtered sound with
  the cutoff modified"): `demos/video_demo.py` builds `TEST_KEYS=15` with
  `VIDEO_MARK=1` (SID303's frame mark, off by default: `sid101.prg`
  byte-identical) and records it with `../c64tools/vicerec.py`. A lead with
  four slides typed into the empty pattern 5 an octave up and played; on the
  parameter screen Resonance 12, Env mod ~200, Sustain 10, Pulse 13, Sub 4,
  PWM 8 a control at a time; the cutoff closed to 26, opened to ~220 and
  brought back to 126. On the page under "Watch", as SID303's.

The site was uploaded at the user's request (`../sidsynth/upload.sh`).
Real hardware checks are the user's: a C64 with an 8580, MIDI through a
cartridge (Kerberos in Datel mode), paddles, a real drive for save and
load.

## Stage G: presets (2026-11-19)

Asked for by the user after Stage F ("presets are needed for a lead synth
and various different sounds; also the presets need to be saved and
restored from disk"). Settled with the user: C= + F3/F4 and MIDI program
change select; 32 slots, all overwritable, with names; the bank saved and
loaded as a file of its own.

Built:

- **Core** (`core/`, both off by default; SID303 and SID808 build
  byte-identical, all 3 and all 7 programs, against core 709d0f3):
  `MIDI_PROGRAM` (program change on the synth's channel goes to
  `synth_program`) and `PARAM_SYNTH_KEYS` (while the core's parameter
  screen is shown, every key event goes to `synth_param_key` first).
  Core 5b03162, f6dfae3.
- **`src/presets.asm`**: 32 slots of the 31 sound parameters (Cutoff to
  Volume) and a 12-character name in PRESET_RAM ($C900-$CE5F). The
  factory set comes from `tables.py` (`FACTORY`, written to
  `presets.inc`), at the program's very end: `presets_init` copies it
  first in `synth_init`, so the test logs may overwrite it afterwards (only
  the code must end below the logs).
  - A recall (C= + F3 / C= + F4, program change 0..31) sets every sound
    parameter but Mod wheel (where the wheel is), Tune and Volume (setup):
    they are stored, never recalled. Its side effects run once each and
    only for values that changed (gates_write, voice 2's frequency,
    arp_param_changed): the 31 param_changed calls a disk load makes left
    2 ticks waiting under the heaviest load.
  - The title row (parameter screen) shows the build as `b15`, then the
    preset: number, `*` once the sound changes after a recall or store (a
    knob, a key, a song or bank load; not the wheel, Tune or Volume), name.
  - C= + RETURN: the store prompt on the status row ("STORE TO 05: name_",
    F3/F4 the slot, typing the name, SHIFT for capitals, DEL, RETURN,
    RUN/STOP). C= + W / L: the bank file's name prompt ("SAVE BANK 8:
    bank_"), its own name, at first "bank"; the song file's name is kept
    apart. The drive's message stays on the status row until a key.
  - Keys during a prompt are the prompt's, their releases too (a key
    pressed in the prompt and let go after it closed plays nothing); a
    note key held when a prompt opens still ends when let go.
- **The bank file** (`src/disk.asm`, DISK_BANK_SAVE / DISK_BANK_LOAD):
  load address $C900, "s101bank" + version 1, the 1376 bytes of
  PRESET_RAM. A bank load checks the header first (NOT A SID101 BANK:
  nothing changes), keeps the sound playing (marked edited), and clamps
  every value to its parameter's range. A bank loaded as a song is NOT A
  SID101 FILE.
- **The factory set**, 23 sounds from demos A-E (slots 24-32: the start
  sound, "Init"): 9 basses, 10 leads, 4 arpeggios. Slot 1 is the start
  sound itself. No slow-attack pads: the amp has no attack.
- The help rows: "F1/2 select F3/4 value F5/6 oct F7 steps" and "RET
  learn  C=+ F3/4 preset RET store W/L". F8 and the note keys are in the
  manual.
- Test builds: without `TEST_MIDIOUT` the out log ($5000) starts full and
  `log_init` clears only from $5F00, so the code may run into the out
  log's room (the voice demos' feeds and the preset code no longer fit
  below $5000).

Checks:
- `tools/preset_check.py` (new): ALL PASS. The start (the 32 slots as
  `tables.py`, slot 1 = the start sound); program change to every slot in
  order, each exactly its values with Volume and the wheel kept, edited
  before each but the first, programs 40 and 127 ignored (TEST_MIDI=15,
  with TEST_PRESET_LOG: every recall logged); the keys (TEST_KEYS=16:
  stepping, the store prompt with a typed name, a held note across the
  prompt, a key let go after the prompt closed); the bank round trip from
  a .d64 (TEST_KEYS=17), a bank as a song (18) and the program as a bank
  (19) refused; the load test (TEST_MIDI=16: a program change every 40
  ticks and a controller every other tick over pattern 3 on the step
  screen): 512 notes, lag 1.

The demo, `demos/g-presets.wav` (`sid101-presets.prg`, TEST_MIDI=14,
125 BPM): each factory preset in turn, chosen by program change, playing a
bar of a bass line or a lead line, or two bars of a held Cm7 chord for the
arpeggios.

| Time | Preset | Plays |
|---|---|---|
| 0:00.0 | 1 Saw + sub | bass |
| 0:01.9 | 2 Plucked bass | bass |
| 0:03.8 | 3 Squelch bass | bass |
| 0:05.8 | 4 Acid 101 | bass |
| 0:07.7 | 5 Sub bass | bass |
| 0:09.6 | 6 Square bass | bass |
| 0:11.5 | 7 Bounce bass | bass |
| 0:13.4 | 8 Wobble bass | bass |
| 0:15.4 | 9 Sync bass | bass |
| 0:17.3 | 10 PWM lead | lead |
| 0:19.2 | 11 Hollow lead | lead |
| 0:21.1 | 12 Fat lead | lead |
| 0:23.0 | 13 Trill lead | lead |
| 0:25.0 | 14 Delay vibe | lead |
| 0:26.9 | 15 Sync riff | lead |
| 0:28.8 | 16 Sync lead | lead |
| 0:30.7 | 17 Sync scream | lead |
| 0:32.6 | 18 S&H burble | lead |
| 0:34.6 | 19 Perc blip | lead |
| 0:36.5 | 20 Arp pluck | arp |
| 0:40.3 | 21 Arp PWM | arp |
| 0:44.2 | 22 Arp sync | arp |
| 0:48.0 | 23 Arp glide | arp |

## MIDI control: patterns, song position (2026-11-19)

For playing in a rig (a master sequencer, the band), with SID303 and
SID808 the same (the core's `PATTERN_CC = 85`, `MIDI_SYSTEM`; the
sequencer module's routines; core/README.md has the rules):

- Controller 85 (values 0-63) picks the step sequencer's pattern, from the
  next pattern start, as F1/F2; song mode off. On SID101's channel only.
- Song select turns song mode on; song position (Clock on MIDI, stopped)
  sets where the next Continue plays from.
- The arpeggiator follows a song position (src/arp.asm
  `synth_song_position`): at 1/8 an odd position is half a step in, so its
  next step comes 6 clocks after the first.

`tools/pattern_check.py` checks it in VICE: CC 85 against seq_check.py's
model (its `switch`), and the arpeggio after song positions 5 and 6 at 1/8
and 5 at 1/16 against arp_check.py's model (its `song_position`).
seq_check.py's model now logs a note released by a MIDI byte (stop) at the
tick it was parsed after.

Status (2026-11-19): every suite passes (voice, seq, arp, preset,
pattern). The new code pushed the clock-in MIDI-out test build
(seq_check.py's `outclock`) into its out log at $5100, so with
`TEST_CLOCK` the out log started at $5300 for a while; since the SysEx
work it is at $E000 for every build (below), and seq_check.py reads
`OUT_LOG` from the label file.

## SysEx dumps (2026-11-19)

The song file and the preset bank go to a PC and back over MIDI (the
core's `MIDI_SYSEX`, core/sysex.asm; src/dumps.asm; the PC tool
core/sysex.py), each byte for byte as its disk file. SID101 is synth 3;
kind 0 the song file (2347 bytes), 1 the bank (1387). The decisions:

- A request from the PC, or C= + M (the step screen: the song; the
  parameter screen: the bank), sends one. With MIDI out on, a playing
  sequencer stops first: its notes would cut the dump.
- A dump that comes in stops the sequencer and silences the synth as soon
  as its header is in (synth_sysex_begin), and the main loop skips the
  synth's ticks while its data comes. Parsing ~12 bytes a tick beside the
  heaviest sound and the sequencer took more time than a tick has spare:
  the ticks fell up to 139 behind. Data bytes now go straight from
  midi_process to the unpacker, too. A dump that stops coming (0.2 s
  without data) ends as a bad one, so the ticks can't stay skipped.
- Sending while a sound plays (MIDI out off: the sequencer plays on) took
  the ticks 155 behind with the heaviest sound: packing ~12 bytes a tick
  doesn't fit either. The main loop now calls sysex_pump only when no tick
  is due: a quiet synth sends at the wire's speed, a busy one slower (the
  PC tool waits 30 s). The capture tests model the transmit ring draining
  at the wire's 12.5 bytes a tick.
- What the main loop pays when no dump moves: 4 cycles a pass (two BIT
  opcodes that become JSR/JMP only meanwhile). The first version's checks
  (~26 cycles) put arp_check's controller stream, the heaviest case with
  ~100 cycles a tick to spare, at lag 3 now and then.
- It loads at F7 if whole (length, sum) and SID101's (length, header), as
  a disk load does (load_check / bank_check; disk.asm's `song_loaded` is
  shared). Else nothing changes, and the song row and the status row say
  why (SYSEX: BAD DATA, NOT A SID101 FILE / BANK).

The MIDI out test log moved to $E000 (the RAM under the KERNAL, SysEx's
staging area): the program outgrew $5100-$5EFF. `tools/dump_check.py`
checks it in VICE: both dumps by key equal the files saved to disk (read
back from the .d64: c64tools/vicepeek.py got `--save-image`), requests for
another synth or device are ignored, a song dump loads (also while the
heaviest sound plays on the step screen, lag 1), a bank dump loads, a bad
sum and a SID303 file change nothing. A song file's unused song entries
hold whatever RAM held when it was saved (as before); the checks leave
them out or make them safe as load_check does.

Not tested here: a real MIDI interface (VICE runs these tests without
one), the PC tool with real hardware.

## Stage H: the C64 lead mode (planned 2026-11-20)

The decisions are in design.md section 2. Two parts, each ending with a
WAV demo and the user's listening verdict:

- **H1, the voice:** Voice mode 2 (C64): voice 1 the pulse lead, voice 2
  its echo (a delay line of voice 1's frequency and control byte, fixed
  delay, level = Saw), voice 3 the sub; the Click parameter; PWM as its own
  slow sweep in this mode. The 3 new parameters (Chord, Chord speed,
  Click) go after Sync env on page 1 (PARAM_PAGE2 17 -> 20); bank and song
  files version 2, version 1 still loading. C64 mode replaces Sync's tick
  work, it doesn't add to it (arp_check's heaviest case had ~100 cycles a
  tick to spare). Voice mode's CC 31 values move (max 1 -> 2): check the
  scripts and the band's Glide Path for literal values.
- **H2, the chords:** held keys or the Chord shape as a fast arpeggio, a
  note every Chord speed frames (5 ticks); with the arpeggiator, the shape
  on each arp step; sequencer notes too; not to MIDI out.

Checks: voice_check.py gets a model of the echo and the chord timing;
every suite (voice, seq, arp, preset, pattern, dump) and the heavy-load
lag tests pass. C64 factory presets from slot 24. Manual and site last.

**H1 built (2026-11-20):**

- Parameters: Chord, Chord speed, Click after Sync env (page 1 now 20,
  PARAM_PAGE2 = 20, 40 in all: both pages full). CCs 17, 18, 19. Voice
  mode 0..2 (101, Sync, C64); the CC values for 101 and Sync still land on
  them (Glide Path's 32 and 64 too).
- `src/engine.asm`: `mode_update` (the old sync_update slot) runs Sync's
  sync_update or `c64_update`: the click's end, the PWM sweep's phase
  (`sweep_rate_*`, 0.1-4 Hz, a triangle at full depth, from 0 at each
  fresh note), and the echo: a ring of 32 ticks (128 ms) at $CF00 of voice
  1's frequency, control byte, level and pulse width; voice 2 plays the
  slot 32 ticks old at level Saw x that level, a retrigger then
  (ECHO_RETRIG, the TEST bit as a marker) as gate off, level, gate on.
  Voice 1 is the pulse lead at the Pulse level, its click (noise / saw /
  square at 50 %, 1-3 frames of 5 ticks) in gates_write. The new variables
  are after the ring ($CFC0): zero page is full in the test builds.
- Files version 2 (bank 1483 bytes, song 2350); version 1 loads from disk
  and over SysEx: the song's three new values at their defaults, a bank
  rebuilt in place (`bank_upgrade`, from the end down). preset_ptr x 34.
- The note log (TEST_LOG) moved from $6000 to $6800 (512 events): the test
  builds' code reached $5F00. seq_check's tempo test now checks 16 bars
  (it was 30) and arp_check's load test more than 200 notes (was 300):
  what the log holds.
- `sid101-c64.prg` (TEST_MIDI=17) didn't fit on the .d64 (each program is
  a whole synth, ~90 blocks: 724 of 664). Since 2026-11-20 build.sh puts
  every program on the disk packed with c64pack's fast format (about 80 %
  of the size, unpacked in 0.5 s; -slow would give 68 % but take 1.9 s):
  8 files, 568 blocks. The depacker touches only zero page $F9-$FE and
  $2D/$2E: a packed TEST_KEYS=17 build saved and loaded the bank from a
  .d64 in VICE ("00, OK,00,00"), so the KERNAL zero page kept for disk
  access is intact. The plain PRGs stay as built.

Checks: every suite passes. voice_check.py runs demo 17 too: its new echo
check finds voice 2's frequency equal to voice 1's 32 ticks (within one)
before in 4479 of 4479 writes, and each of its 18 retriggers after one of
voice 1's (2 more openings: Saw turned up from 0 while voice 1 was held).
preset_check.py loads a version 1 bank and song from a .d64
(TEST_KEYS=23), dump_check.py both over SysEx. The longest tick in demo
17: about 2560 cycles of 3941.

The CPU budget (2026-11-20): measured with TEST_PROFILE in the heaviest
case (TEST_MIDI=11, Sync), against the build before H1. The mode checks
first cost about 35 cycles a tick and ~30 a note in 101 and Sync mode;
after laying the paths out for them (Sync tested first in mode_update and
falling into sync_update, voice 3's pulse width first in pw_update so
Sync returns early, lead_freq stored only in C64 mode, one mode check in
voices_retrigger, the C64 level path after the others, and the echo
keeping v2_level so levels_write needs no check) the parts sum to the same
as before within the runs' spread (levels +10 cycles). arp_check.py's
stream test got a C64 case (TEST_MIDI=18: the stream over the heaviest
C64 sound, echo, click, sweep, noise LFO, vibrato, wheel): lag 1, as the
Sync cases. In the profile the C64 sound costs what Sync's does (6428 vs
6434 cycles over the parts' worst runs).

The demo, `demos/h-c64-voice.wav` (`sid101-c64.prg`, 125 BPM):

| Time | Plays |
|---|---|
| 0:00.0 | the lead alone: pulse, its slow PWM sweep, vibrato after a delay |
| 0:03.8 | the same with the echo (Saw 10) |
| 0:07.7 | a staccato riff with a noise click (1 frame) |
| 0:09.6 | ... a saw click (2 frames) |
| 0:11.5 | ... a square click (3 frames) |
| 0:13.4 | all of it: echo, the sub 2 octaves down, a noise click (2 frames), a faster sweep |

**H2 built (2026-11-20): the chords.**

- Chord got a Keys value (Claude's call, told to the user): Off, Keys,
  then the shapes Major, Minor, 7th, Minor 7th, Major 7th, Sus 4, 5th,
  Octave, Diminished. Off is a plain mono lead (legato, glide), so a
  legato line's overlaps never become chords. With Keys or a shape,
  several held keys play as the chord; with a shape, one key plays the
  shape over it.
- `chord_build` (src/engine.asm, on note events, a Chord or Voice mode
  change, a preset recall: never every tick): the notes as semitones from
  the sounding key (chord_offs), held keys sorted upwards and starting at
  the sounding one, so a one-tick legato overlap sounds no other note.
  `c64_update` steps it every Chord speed frames (5 ticks each);
  `pitch_to_sid` adds the note (chord_now). No retrigger, no glide
  between its notes; the chord plays on into the release; the
  arpeggiator's notes and the sequencer's get the shape; not to MIDI out.
- CPU: the heaviest C64 case now has a chord too (TEST_MIDI=18: a Major
  chord a note a frame; with the sequencer and the arpeggiator both
  playing, two keys are often held and it sorts them). It went to lag 6:
  C64 mode had no room left. Two savings: the PWM sweep's full depth
  without a multiply (x 255/256 changed it by at most 1 in 254), and Tune
  from a table (tune_lo/tune_hi) added with the chord's note in one
  addition, about 24 cycles a tick less in every mode. Every heavy case
  is back at lag 1, but C64 mode's heaviest case has little room left.
- Demo `demos/h2-c64-chords.wav` (`sid101-chords.prg`, TEST_MIDI=19, on
  the .d64 too: 9 files, 651 blocks).

Checks: voice_check.py's chord check replays demo 19 through a model of
chord_build and the stepping (chord_model) and compares voice 1's note
tick by tick: 671 runs, the same notes, each within a tick. Every suite
passes.

| Time | Plays |
|---|---|
| 0:00.0 | one key, Chord Minor: C minor, a note a frame (50 a second), the echo on |
| 0:01.9 | A flat major |
| 0:03.8 | B flat major |
| 0:05.8 | G 7th |
| 0:07.7 | Keys: C minor 7th held on four keys, two frames a note |
| 0:09.6 | F minor on three keys |
| 0:11.5 | Octave: demo H's melody, each note an octave arpeggio, a noise click |
| 0:15.4 | the arpeggiator (Up, 2 octaves, 1/8) over C minor, each of its notes a fifth arpeggio |

**C64 presets and two disks (2026-11-20).** The user on H2: "demo sounds
great!". Factory slots 24-31 got C64 mode sounds (tables.py C64_LEAD,
C64_CHORD), slot 32 stays Init:

| Slot | Name | In demos/g-presets.wav (now 71 s) |
|---|---|---|
| 24 | C64 lead | 0:51.8 |
| 25 | Echo lead | 0:53.8 |
| 26 | Hubbard lead | 0:55.7 |
| 27 | Click pluck | 0:57.6 |
| 28 | Octave lead | 0:59.5 |
| 29 | Major chord | 1:01.4 |
| 30 | Minor chord | 1:03.4 |
| 31 | Keys chord | 1:05.3 |

preset_check.py's version 1 bank test now expects Chord, Chord speed and
Click at their defaults: a version 1 file can't hold the new presets'
values. At the user's request the programs went on two disks:
sid101.d64 the synth alone (71 blocks: room for 59 songs or 98 banks),
sid101-demos.d64 the eight demos (583 blocks).

## Stage A: the amplitude envelope

The SID always attacks a voice to full level and then falls to the
sustain level, and a sustain level can be lowered during a note but never
raised. So, as in SID303 and SID808, every ADSR rate stays at 0 (no ADSR
delay bug, instant retriggers) and the level is set through the sustain
level:

- note start: the gates retrigger with each voice's mix level as sustain;
- decay, sustain and release: the levels are lowered every tick, mix x
  envelope (in Env mode; Gate mode holds the mix level and closes the
  gates at note off);
- the gates close when the release has faded out.

The cost: the amplitude can't have a slow attack (the Attack parameter
shapes the filter envelope only), and a mix level raised during a note is
heard from the next note. A slow attack through the SID's own attack rate
is a possible later addition: it brings the ADSR delay bug back for fast
retriggers and makes all voices equally loud until the decay.

## Latency (2026-11-26, from SID500's latency work)

Measured with SID500's `tools/synth_latency.py` (a note on fed through the
real receive interrupt at random moments, every SID write stamped in VICE;
`../sid500/docs/latency.md`):

- **A fresh note's frequency before its gate** (fd50425, `voice_note_on`
  calls `pitch_to_sid` before `voices_retrigger`; not in C64 mode, whose chord
  steps and echo follow the tick: written early, a chord's note sounded a tick
  early, voice_check's chords): a note no longer starts at the last note's
  pitch (0.75-3.8 ms before). Heard: median 3.24 -> 2.27 ms, worst 6.53 ->
  5.68 ms.
- **Core `MIDI_POLL_SCAN` left off** (a474c93): MIDI read between the main
  loop's scan pieces too took the worst to ~4.1 ms, but the heaviest cases
  fell 2-3 ticks behind (arp_check's controller stream with the arpeggiator,
  dump_check's request with the heaviest sound, preset_check's 256 notes,
  seq_check), against the limit of 1.
- **Older failures seen then, not from these changes** (the committed code
  before them fails the same): voice_check's chords (672 runs of voice 1's
  note against the model's 671) and dump_check's assertion (`vals[v2_first:...]
  == bytes(v2_n)`). Open.
