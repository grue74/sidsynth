# SID303

A monophonic TB-303 style acid bass synth for the C64 with an **8580 SID**.
Play it from MIDI or the C64 keyboard. Paddles control cutoff and resonance
(or any parameter you learn them to),
and the function keys edit parameters.

It has its own **step sequencer** (F7): 64 patterns of up to 16 steps
with accent, slide and tie, songs that chain them with repeats and
transposes, undo, MIDI clock in and out (so it can follow SID808 or any
other master), and saving to disk. Design and test results:
`docs/sequencer.md`.

## Files

| File | What |
|---|---|
| `sid303.asm` | the program (64tass): sound build options, synth constants and parameter list, `synth_init`; includes the core and `src/` |
| `core/` | git submodule (repo `synthcore`): the SID synth core shared with SID808: start-up, interrupts, MIDI input, parameter system with learn, paddles, keyboard, parameter screen, test feeders. `core/README.md` lists what a synth must provide |
| `src/*.asm` | SID303's own parts: `notes`, `engine` (250 Hz sound engine), `hooks` (F7 to the step screen, parameter side effects, status line), `sequencer` (the step sequencer's engine, song mode), `steps` (its screen and keys), `undo` and `disk` (save and load): `docs/sequencer.md`; `keymap`, `params` (parameter tables, texts, default controllers), `test_scripts` |
| `tools/compare_builds.sh` | refactoring check: builds every variant from a git revision and from the working tree and compares them byte for byte (`ZP_REMAP=1`: zero-page moves allowed, `ROUTINES=1`: routine by routine, moves allowed) |
| `tools/compare_screens.sh` | runtime refactoring check: the test builds' end screens in VICE, old and new, pixel for pixel |
| `tools/seq_check.py` | the step sequencer's playing checks in VICE: note logs against a model of the rules, against the MIDI-fed test line, swing, tempo, play/stop |
| `tools/module_deps.py` | what each module needs from the others (`--contract`: what the core needs from the synth). The comparers behind the checks, `routine_compare.py` and `zp_remap_check.py`, are in the shared `c64tools` folder |
| `tables.py` | generates `tables.inc`: note frequencies, log cutoff curve, envelope/slide factors, test pattern |
| `build.sh` | builds `sid303.prg`, `sid303-test.prg` and `sid303.d64` |
| `sid303-test.prg` | same program, but it plays a built-in acid line through the MIDI parser (no MIDI hardware needed) |
| `sid303-sweep.prg` | same, but the acid line plays at high resonance while the cutoff sweeps fully open and back down twice over eight bars |
| `demos/*.wav` | that test line recorded in VICE (reSID 8580), one file per sound setting (see below) |
| `demos/presets/*.wav`, `demos/record.py` | one demo per starting-point sound in the manual, and the script that records them |
| `demos/uponly/*.wav` | the same presets with Env mod type "Up only", for A/B listening |
| `demos/step-demo.mp4`, `demos/step_demo.py` | the step sequencer demo video (an empty pattern, a 16-step loop typed in and played; then on the parameter screen resonance, env mod, decay, accent, waveform and filter made harsher, and the cutoff swept), and the script that builds and records it (`TEST_KEYS=14`, `VIDEO_MARK=1`, c64tools `vicerec.py`) |
| `make_site.py` | builds SID303's web page (demos, video, downloads) into the SidSynth site, `../sidsynth/site/sid303/`; the site as a whole is built and uploaded from `projects/sidsynth` |
| `LICENSE` | GNU GPL version 3 |
| `docs/SID303-manual.pdf`, `docs/manual.py` | the user manual, and the script that builds it (reportlab) |
| `docs/screen.png`, `docs/screen-steps.png` | VICE screenshots of the parameter screen and the step screen (manual, site) |
| `docs/sequencer.md` | the step sequencer's design, and what was measured in each phase |

Build: `sh build.sh` (needs python and 64tass). The core is a git submodule:
clone with `git clone --recurse-submodules`, or run
`git submodule update --init` in an existing clone. (On this Windows setup
Git Bash's ssh is broken; use `git -c core.sshCommand=C:/Windows/System32/OpenSSH/ssh.exe ...`.)

The build number shows in the title row ("build 5"). Please include it in
bug reports. `build.sh` takes it from git: the number of commits, plus one
when there are uncommitted changes. A build made just before a commit
therefore carries that commit's number (the n-th commit, `git log --reverse`),
and rebuilding a clean checkout gives the same number and identical files.
Assembled by hand without `-D BUILD=n`, the program shows build 0.

Test builds (64tass `-D` options):
- `TEST_MIDI=1` feeds the acid line through the MIDI parser. `TEST_MIDI=2`
  plays the cutoff sweep instead (CC71 resonance, then a CC74 on every step).
- `TEST_KEYS=1` plays a scripted key sequence instead of reading the
  keyboard: F-keys, auto-repeat, octave, interface switching, slide and
  accent, and F7 to the step screen and back.
- `TEST_KEYS=4` opens the step screen and stays there (screenshots).
  `TEST_KEYS=5` plays and stops pattern 1 from the step screen, switching
  screens while it plays. `TEST_KEYS=6` edits patterns 2-4, `TEST_KEYS=7`
  holds note keys across F7 and RUN/STOP, `TEST_KEYS=8` uses undo, redo
  and the song keys (all checked by `tools/seq_check.py`).
  `TEST_SONG=1` (with `TEST_EDGES=2`) plays tables.py's `SONG_TEST`.
- `TEST_MIDI=5` feeds MIDI clock (start, two bars, stop, continue, a bar,
  stop); with `TEST_CLOCK=1` (Clock on MIDI at start) the sequencer follows
  it. `TEST_MIDIOUT=1` starts with MIDI out on; `TEST_LOG` builds log every
  byte it sends at $5000.
- `TEST_KEYS=9`..`13` save and load on a disk with the program (a round
  trip, a file that isn't SID303's, a missing file, drive 9 absent, a save
  while playing; `tools/seq_check.py` makes the .d64 and checks them).
  `TEST_DRIVE=n` sets the Disk drive parameter at start (0..8 = drive 8..16).
- `TEST_SEQ=1` starts the sequencer at once (pattern `TEST_SEQ_PAT`+1, tempo
  `SEQ_BPM_DEFAULT`, swing `SEQ_SWING_DEFAULT`); `TEST_EDGES=1` puts the
  playing rules' awkward cases (tables.py `EDGES`) in pattern 1.
  `TEST_EDGES=2` puts patterns of length 6 and 5 in patterns 1 and 2, and
  `TEST_SEQ_NEXT=1` queues pattern 2 after the first pass.
  `TEST_LOG=1` logs every note on and off with its tick at $6000, and the
  most ticks ever left waiting at $5FFF, for `tools/seq_check.py`.
- `TEST_MIDI=4` tests channel 10 in Omni: a note on channel 1, then a drum
  note on channel 10 (ignored: the status row keeps A-2, velocity 64), then
  CC 74 = 0 on channel 10 (still taken: Cutoff 0).
- `TEST_KEYS=3 TEST_PADDLES=1` together test paddle learn: paddle X turns by
  itself while a script learns it onto Decay and removes paddle Y with DEL.
- `TEST_KEYS=2 TEST_MIDI=3` together test MIDI learn: scripted RETURN/DEL/F1
  presses with matching controller messages.
- `MIDI_IF_DEFAULT=n` sets the interface at start (default 3, Datel).
- `WAVE_DEFAULT`, `AMPDECAY_DEFAULT`, `BLEND_DEFAULT`, `BODY_DEFAULT`,
  `RESO_DEFAULT`, `FILTER_DEFAULT`, `ENVMOD_DEFAULT`, `DECAY_DEFAULT` and
  `ACCENT_DEFAULT` set the sound at start (used for the demos and tests).
- `ENVTYPE_DEFAULT=0` starts with Env mod type "Up only" instead of
  "Centred". `ENV_PIVOT` (default 140) is where the centred sweep pivots.
- `TEST_TIMING=1` shows each synth tick's CPU time in the border colour.
- `FILTER_ROUTING=0` sends no voice through the filter, for raw-waveform tests.

Run: `LOAD"SID303",8` then `RUN`, or autostart the PRG.
In VICE, choose the 8580 SID: `-sidenginemodel 257`, or Settings > Audio > SID.

## Controls

| Key | Action |
|---|---|
| F1 / F2 (or CRSR down / up) | next / previous parameter; on past Volume, or back from Cutoff, to the setup page |
| F3 / F4, `+` / `-`, CRSR right / left | change value (hold to repeat) |
| F5 / F6 | keyboard octave up / down |
| F7 | the step sequencer's screen (its keys are below) |
| F8 or RUN/STOP | all notes off |
| RETURN | learn for the selected parameter: move a MIDI knob or turn a paddle to assign it (RETURN again cancels) |
| DEL | remove the selected parameter's MIDI controller and paddle |
| `Z S X D C V G B H N J M , L . ; /` | notes, lower octave (C to E) |
| `Q 2 W 3 E R 5 T 6 Y 7 U I 9 O 0 P @` | notes, upper octave (C to F) |
| SHIFT + note | accented note (SHIFT LOCK = accent everything) |
| hold a note and play another | slide (portamento, no retrigger) |
| Paddle X / Y | cutoff / resonance, or what they are learnt to |

### Step screen (F7)

A pattern is a list of 16 steps, one per row: the note (`---` a rest, `===`
a tie), accent `A`, slide `S`, and a lane that marks each note at its pitch
(`C1`, `C2`, ... above it). A note slides into the next step's note; a tie
holds the note before it on. The gate is half a step.

The song row chains patterns: `SONG 01/03`, the song cursor and the
song's length, then entries like `01x2+05`: pattern 1, twice, transposed
up 5 semitones. In song mode (C= + S, `SONG` reversed) RUN/STOP plays the
song from its first entry, in a loop, and the step screen follows the
pattern playing. Undo takes back the last 16 edits of steps, lengths,
clears, copies and the song.

| Key | Action |
|---|---|
| note keys (as above) | the cursor's step becomes that note, cursor down; when stopped the note also plays |
| SHIFT + note | the same, accented |
| `A` / `F` | accent / slide on or off |
| `=` | tie, cursor down |
| SPACE / DEL | rest, cursor down / rest |
| CRSR down / up | cursor |
| CRSR right / left | the cursor's note a semitone up / down |
| `+` / `-` | pattern length 1-16 |
| F1 / F2 | next / previous pattern (it plays from the next pattern start) |
| F3 / F4 | tempo +/- 1 BPM (60-240) |
| C= + F3 / F4 | swing +/- (0-15) |
| F5 / F6 | octave of the note keys |
| HOME / CLR | cursor to step 1 / clear the pattern |
| C= + `C` | copy the pattern to the next one |
| C= + `S` | song mode on / off |
| C= + `,` / `.` | song cursor back / on (an entry shows its pattern) |
| C= + `P` | put the pattern into the song at the cursor (at the end: a new entry) |
| C= + `;` (SHIFT: back) | the entry's repeats 1-9 |
| C= + `+` / `-` | the entry's transpose -12..+12 |
| `←` | delete the song entry at the cursor |
| C= + `U` (SHIFT: redo) | undo / redo |
| C= + `W` / `L` | save / load: a name prompt on the song row (letters, digits, space, + - . type; DEL deletes; RETURN goes; RUN/STOP cancels) |

A file holds everything a song needs: the 64 patterns, the song, tempo,
swing and the sound (Cutoff to Volume), about 10 blocks. The setup
(channel, interface, paddles, clock, MIDI out, drive) isn't in it. The
drive is the parameter screen's **Disk drive**, 8-16, at start the drive
SID303 was loaded from. Saving replaces a file of the same name. While a
file is saved or loaded nothing plays; afterwards the song row shows the
drive's status (`00, OK,00,00`, `62, FILE NOT FOUND,00,00`, ...) or
`NO DRIVE 9`, `NOT A SID303 FILE`, `FILE ENDED EARLY`, until a key.
| RUN/STOP | play / stop |
| F7 / F8 | parameter screen / all notes off |

SHIFT also turns F1, F3, F5 and F7 into F2, F4, F6 and F8. With SHIFT LOCK
on, F1 therefore acts as F2.

## Parameters

The parameter screen has two pages, named at the top right: **Sound**
(Cutoff to Volume) and **Setup** (MIDI channel to Disk drive). The page
shown is the one the selected parameter is on, so F1 past Volume goes on
to the setup page, and F2 from Cutoff goes straight to its last row, Disk
drive. A grey line under each page's last parameter says where the other
page is.

| Parameter | Range | MIDI CC (at start) | Notes |
|---|---|---|---|
| Cutoff | 0-255 | 74 | log scale, ~40 Hz to 12 kHz; paddle X at start |
| Resonance | 0-15 | 71 | paddle Y at start |
| Env mod | 0-255 | 12 | filter envelope depth, up to ~4 octaves |
| Env mod type | Centred / Up only | | Centred (default) works like the 303: more Env mod opens the filter higher *and* closes it lower, around a fixed middle. Up only adds the envelope on top of Cutoff |
| Decay | 0-15 | 75 | filter envelope decay, 0.12 s to 2.5 s |
| Accent | 0-15 | 13 | accent strength: cutoff kick and the loudness gap between accented and normal notes |
| Slide time | 0-15 | 5 | glide time constant, 10 ms to 300 ms (default 8 is about 60 ms, like a 303) |
| Amp decay | 0-15 | 72 | how fast a held note fades: 0.15 s to 4 s time constant; 15 = no fade |
| Waveform | Saw / Square / Saw+square / 303 square | | |
| Pulse width | 0-15 | | 3% to 50% (square and 303 square) |
| Square tilt | 0-15 | | 303 square only: how much saw slants the pulse |
| Body | 0-15 | | level of an unfiltered triangle on the fundamental, 0 = off |
| Tune | -16..+15 | | ±½ semitone |
| Filter | Low-pass / Low+band / Band-pass / High-pass | | the 303 is low-pass; Low+band gives a stronger resonant peak but a gentler slope |
| Volume | 0-15 | 7 | |
| MIDI channel | Omni, 1-16 | | |
| MIDI i/face | Off, Sequential, Passport, Datel, Namesoft | | default Datel (the mode tested on a Kerberos cartridge) |
| Paddles | Port 1, Port 2, Off | | |
| Clock | Internal, MIDI | | the step sequencer's clock: its own tempo, or MIDI clock in |
| MIDI out | Off, On | | the step sequencer's notes, and with the internal clock its start, clock and stop |
| Disk drive | 8-16 | | where the step screen saves and loads (at start: the drive SID303 came from) |

### MIDI and paddle learn

Any knob or slider on a MIDI keyboard, and either paddle, can control any
sound parameter (Cutoff to Volume):

1. Select the parameter with F1/F2.
2. Press RETURN. The status line shows `Learn: knob/paddle`, and `???`
   appears in the parameter's CC column.
3. Move a MIDI knob or turn a paddle. It now sets that parameter, and learn
   mode ends.

- **One knob per parameter:** learning a knob removes the parameter's previous
  controller, so learning a new knob for Cutoff frees CC 74. A knob that was
  already assigned to another parameter moves to the new one.
- **One paddle per parameter:** a learnt paddle leaves its old parameter,
  and the other paddle lets go of the new one. Paddles and MIDI knobs are
  separate: a parameter can have one of each.
- **Remove a controller:** select the parameter and press DEL. This removes
  both its MIDI controller and its paddle.
- **Where to see it:** at the right of the screen, the P column shows X or Y
  for a parameter's paddle and the CC column its MIDI controller.
- **Defaults:** paddle X on Cutoff, Y on Resonance, and the controllers in
  the table above. Learnt assignments aren't saved, so a reset restores the
  defaults.
- **Not learnable:** MIDI channel, MIDI i/face, Paddles, Clock, MIDI out and
  Disk drive. RETURN does nothing
  on them, so a knob or paddle can't switch the MIDI interface off.
- **Controllers:** 0-119 can be learnt. 120-127 are MIDI channel mode messages.
- **Mid-note changes:** a knob or paddle on Waveform, Square tilt or Body
  restarts a sounding note each time its value changes, as the F-keys do.

MIDI also handles:
- **note on/off**: velocity ≥ 110 plays an accented note. On Omni, notes on
  channel 10 (the General MIDI drum channel) are ignored, so a drum machine
  on the same MIDI line, such as SID808 with its MIDI out on, doesn't play
  the bass. Controllers on channel 10 still count.
- **Running status**.
- **Pitch bend**: ±2 semitones.
- **CC 120/123**: all notes off.

With **Clock** on MIDI, the step sequencer follows MIDI clock: start,
clock (6 per step, 24 per quarter note), continue and stop; the title shows
`BPM EXT`. Other realtime bytes are ignored, even in the middle of a
message. With **MIDI out** on, the sequencer's steps go out as notes on the
MIDI channel (Omni: channel 1; accent is velocity 127, others 100, a slide
is the next note on before the note off), and with the internal clock also
start, clock and stop, so another machine can follow SID303.

## How the 303 parts are done on the SID

- **Voices:** voice 1 is the main oscillator. Voice 2 is used only for the
  303 square. Voice 3 is used only for Body.
- **303 square:** a pulse on voice 2, hard-synced to voice 1 so the two stay
  phase-locked, with voice 1's saw mixed under it. The saw slants the pulse's
  flat parts, as on the 303 square, which adds even harmonics: the 2nd harmonic
  is about -18 dB at Square tilt 6, against -43 dB for a plain square. This
  approximates the 303's waveshaped square, not a copy of it.
- **Body:** an unfiltered triangle on voice 3 for a rounder bottom. This isn't
  a 303 feature. It is turned down as resonance goes up (to -6 dB at 15),
  because the 303 loses bass at high resonance and the 8580 doesn't.
- **Filter:** the 8580's 12 dB low-pass, against the 303's 18/24 dB. The
  cutoff goes through a log table, so the knob, paddle and envelope sweep evenly
  in octaves.
- **Filter envelope:** a software exponential decay at 250 Hz (CIA timer). This
  is fast enough that short decays don't step audibly. It retriggers on every
  note except slides.
- **Env mod:** with Env mod type Centred (the default), the envelope swings
  around a fixed middle, as on the 303, so more Env mod opens the filter
  higher and closes it lower. Up only adds the envelope on top of Cutoff.
- **Accent:** a louder attack that falls back to the normal level over about
  0.2 s (a "pluck", because the 303's accent also drives its VCA), a shorter
  decay, and an extra cutoff kick. The kick builds up over back-to-back accents,
  and builds more at high resonance, like the 303's "accent sweep". High
  resonance also slows the kick's rise (up to ~60 ms), giving the 303's
  "waaaoow" on accented notes.
- **Slide:** an RC-style exponential glide in pitch with interpolated
  frequencies. Legato input slides, as with most MIDI-to-303 setups.
- **VCA:** the SID ADSR with every rate set to 0, which acts as an instant gate.
  This also avoids the SID's ADSR delay bug, so fast retriggers never drop. A
  software amplitude envelope then lowers each voice's sustain level during the
  note, and the SID follows it down, so held notes fade like a 303's. The fade
  moves in 16 level steps.
- **Changing Waveform, Square tilt or Body while a note sounds** restarts that
  note's envelopes. The SID can lower a sustain level mid-note but can't raise
  one.

## Demos

The demos are in `demos/`. Each plays four bars of the test line, then one bar
of long held notes so the fade (and the accent pluck on notes 1 and 4) is
audible (demos 6-8 are the cutoff sweep instead). Demos 2-5 have the accent pluck and resonance-thinned body; demo 1
predates both:

| File | Setting |
|---|---|
| `1-before-saw-nofade.wav` | saw, no fade (the original sound) |
| `2-saw-fade.wav` | saw with Amp decay 9 (the new default) |
| `3-square-fade.wav` | plain square |
| `4-303square-fade.wav` | 303 square, tilt 6 |
| `5-303square-body.wav` | 303 square plus Body 4 |
| `6-cutoff-sweep.wav` | saw, resonance 15: eight bars with the cutoff swept fully open and back down twice (`sid303-sweep.prg`) |
| `7-sweep-hard-saw.wav` | the sweep, harder: saw, Low+band filter, Env mod 200, Decay 1, Accent 15 |
| `8-sweep-hard-sawsquare.wav` | as 7 but with the Saw+square waveform: buzzier and brighter |

### Preset demos

`demos/presets/` has one recording per sound in the manual's "Starting
points" table. `python demos/record.py` builds each preset with its
`*_DEFAULT` options, records it in VICE (real time, about 20 s for all six)
and cuts one pass of the pattern from the first note.

| File | Setting |
|---|---|
| `1-default.wav` | the default sound |
| `2-hard.wav` | sweep: saw, Low+band, resonance 15, Env mod 200, Decay 1, Accent 15 |
| `3-buzzy.wav` | as 2 with Saw+square |
| `4-square-bass.wav` | 303 square, tilt 6 |
| `5-fuller-bottom.wav` | 303 square, tilt 6, Body 4 |
| `6-held-no-fade.wav` | the default with Amp decay 15 (no fade) |

`demos/uponly/` has the same six presets with Env mod type "Up only"
(`python demos/record.py -D ENVTYPE_DEFAULT=0 --out demos/uponly`), for A/B
listening. With the same knobs they are brighter than the default "Centred"
takes: the middle of the sweep sits above Cutoff instead of at it.

## Notes and limits

- **Tested on real hardware:** MIDI input works on a real C64 with a Kerberos
  cartridge in Datel mode, and the paddles turn the right way.
- **PAL timing.** On NTSC, pitch runs about ⅔ semitone sharp and envelopes run
  about 4% fast.
- **Paddles use soft takeover.** A paddle only takes control after it moves,
  so MIDI CCs and keys don't fight it, and an empty port is ignored. Turning
  clockwise raises the value (checked on real paddles). Don't press the
  paddle fire buttons: they share lines with the keyboard.
- **Kerberos:** start SID303 from the Kerberos menu or the Kerberos App
  ("Send PRG and start", or flash it to a slot), with the slot's MIDI
  emulation set to Datel. The menu's R and H items switch the cartridge off,
  so loading SID303 from BASIC leaves MIDI dead. The Kerberos menu's M item
  tests the MIDI input.
- **Keyboard chords.** The C64 keyboard matrix can ghost with three or more
  keys held.
- **Maplin MIDI interface:** not supported, because it has no interrupt.
- **MIDI handling:** the IRQ/NMI handler only stores bytes in a 256-byte ring
  buffer. Everything else runs in the main loop, so the ACIA does not overrun.
  The main loop reads the ring between its scan's pieces too (core
  `MIDI_POLL_SCAN`).
- **Latency** (measured 2026-11-26, SID500's `tools/synth_latency.py`: a note
  on fed through the real receive interrupt at random moments, every SID write
  stamped in VICE): from a note on's last byte to the note heard at its own
  pitch, median 2.4 ms, at most 4.7 ms (MIDI's own ~1 ms for the three bytes
  comes before). A fresh note's frequency is written before its gate opens:
  until then a note started at the last note's pitch for 0.4-3.8 ms. Figures
  and method: `../sid500/docs/latency.md`.
- **ROMs:** BASIC and KERNAL are banked out. RESTORE does nothing. Leave the
  program with a reset.

## License

Copyright (C) 2026 Jarkko Lehti.

SID303 is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE) for
the full text. This covers the program, the scripts, the manual and the demo
recordings.
