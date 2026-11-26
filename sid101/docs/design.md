# SID101 design

A monophonic lead synth for the C64 and its 8580 SID, in the spirit of the
Roland SH-101 (1982), the third SidSynth synth after SID303 and SID808. The
start-up questions were settled with the user on 2026-11-18 (section 6);
the details of the voice and controls are still a starting point to try
out and change.

Background: the SID has three voices, one shared filter, and hard sync and
ring modulation built in. That suits one big mono lead better than chords.
The SH-101 was a mono lead/bass synth with a sequencer and an arpeggiator,
which fits the family: 303 bass, 808 drums, 101 lead.

## 1. The voice: three SID voices on one note

The SH-101 mixed a saw, a pulse with pulse-width modulation (PWM) and a
sub-oscillator through one resonant low-pass filter. On the SID, one note
plays on all three voices:

| SID voice | Role | Notes |
|---|---|---|
| 1 | saw | level by its envelope; the SID can't mix two waveforms freely on one voice (combined waveforms are a fixed AND-like mix), so the saw gets its own voice |
| 2 | pulse | width swept by software at the 250 Hz tick: by the LFO (PWM), the envelope or by hand |
| 3 | sub | square one octave down, or two octaves down, or a 25% pulse two down (the 101's three sub choices) |

All three go through the filter, with the mix set by each voice's level.
The SID has no per-voice volume, only the envelope's sustain level (16
steps), so the mix is set through the voices' ADSR sustain levels: three
parameters, saw, pulse and sub level, 0-15 each, like the SH-101's mixer
(decided 2026-11-18). The SID doesn't raise a held note's envelope when
its sustain level goes up, so a raised level is heard from the next note;
a lowered one at once. The tick test's voice used saw 15, pulse 12, sub
10.

## 2. Modes beyond the SH-101

**Sync lead (Sequential Pro-One, Moog Prodigy).** One voice hard-synced to
another, with the synced voice's pitch swept by an envelope: the tearing
lead sound (the Cars, "Let's Go"). On the SID, voice 1's sync bit locks it
to voice 3, voice 2's to voice 1, voice 3's to voice 2. A sweep of the
synced voice's frequency at the 250 Hz tick gives the effect almost for
free. Ring modulation (the same voice pairs, needs triangle on the
modulated voice) gives metallic and bell-like leads.

**C64 lead (Rob Hubbard, Martin Galway).** The C64's own 80s lead: a pulse
lead with a slow PWM sweep, vibrato that comes in after a delay, a short
noise or waveform click at the attack, and chords played as fast
arpeggios on one voice.

Decided 2026-11-18: the first version has a "Voice mode" parameter with
the SH-101 voice and Sync. The C64 lead (its fast chord arpeggios and
delayed vibrato) comes later, as a third mode or a synth of its own.

**The C64 lead mode, settled with the user 2026-11-19/20:**

- **A third Voice mode** (Voice mode 2, "C64"): presets, banks, the
  sequencer and the arpeggiator work with it as with the others.
- **The voices: lead + echo + sub.** Voice 1 the pulse lead; voice 2 the
  same as voice 1 a fixed time later (Hubbard's echo: a delay line of voice
  1's frequency and control byte, so vibrato, chords and the click are
  echoed too), its level the Saw level; voice 3 the sub as in 101 mode.
- **Chords: held keys + a chord shape.** Several keys held play as a fast
  chord arpeggio on one voice; with one key, the Chord parameter (off,
  major, minor, 7th, m7, sus4, octave...) makes the chord. Chord speed: 1-8
  frames a note (a frame = 5 ticks, 50 Hz as the old players).
- **Click:** a parameter, off or noise / saw / square for 1-3 frames at
  the note's start.
- **PWM** in C64 mode sets the speed of its own slow pulse-width sweep, so
  vibrato (the LFO, with its delay) and the sweep play together; in 101
  and Sync modes PWM stays the LFO's depth to pulse width.
- **Old files still load:** the bank and song files get a new version (3
  more sound parameters); version 1 files load with the new ones off.

Set by Claude (defaults, stated here): with the arpeggiator on, it takes
the held keys and the chord shape plays on each arp step; sequencer notes
get the chord shape; no glide between a chord's fast notes; chords don't
go to MIDI out. Only 3 parameters fit (page 2 is full, page 1 has 3 free
rows), so the echo's delay is fixed; after this the screen is full (40
parameters).

## 3. Modulation and playing

- **LFO:** triangle, square, random (sample and hold) and noise, rate and
  delay (fade-in), to pitch (vibrato), pulse width and cutoff.
- **Envelopes:** ADSR for the filter (the SH-101 had one envelope for both
  filter and amp; a second, simpler one could go to the amp or to the sync
  sweep).
- **Portamento:** glide time, on always or only on legato notes (as the
  SH-101's Auto); SID303's slide code is the model.
- **Pitch bend and modulation:** the core takes pitch bend (`bend`); the mod
  wheel (CC 1) to LFO depth, like the 101's modulator grip.
- **Accent:** velocity to filter envelope amount and level.

## 4. Sequencer and arpeggiator

- **Sequencer:** SID303's, now in the core (`core/sequencer.asm`:
  patterns, accent, slide, tie, songs, MIDI clock in and out). The step
  screen, disk and undo are still SID303's to copy.
- **Arpeggiator (new, in the first version):** up, down, up and down, random; one to three
  octaves; notes from held keys or MIDI; synced to the internal or the MIDI
  clock. Would also serve the C64 lead mode's fast chord arpeggios
  (much faster, per tick rather than per step).

## 5. What it reuses

- From the core: everything in `shared-parts.md` section 1. Probably
  `PARAM_PAGE2` (SID101 will have more than 15 parameters), `SYNTH_SCREEN`
  for the step screen, `MIDI_REALTIME` and `MIDI_OUT` for clock and notes,
  `KERNAL_ZP_COPY` for disk.
- From SID303: the filter and its envelope (log cutoff, centred env mod),
  slide, accent, the step sequencer, its tests (`tools/seq_check.py`) and
  the manual and site scripts as templates.
- From SID808: the use of all three voices and the SID pitfalls
  (`reference/sid808-design.md` sections 4 and 7).

## 6. Start-up questions (all settled with the user, 2026-11-18)

1. Voice modes in the first version: **the SH-101 voice and Sync**; the
   C64 lead later (section 2).
2. The mix: **three levels, saw, pulse and sub, 0-15 each**, through the
   voices' sustain levels (section 1).
3. Sequencer: **moved into the core** (`core/sequencer.asm`); SID303 uses
   it, SID808 keeps its drum sequencer.
4. Arpeggiator: **in the first version**, with the sequencer.
5. Name on screen, disk and site: **SID101**.
6. Paddles at start: **cutoff and resonance**, as in SID303 (paddle learn
   maps them to anything else).
7. The 250 Hz tick: **enough**, by listening to the prototype (below);
   SID101 uses the core's 250 Hz tick.

### The 250 Hz tick: what to test

Everything in software (filter envelope, LFO, PWM, slide, sync sweep)
moves in 4 ms steps. The amp envelope is the SID's own ADSR, so the tick
doesn't limit it.

Should be fine: PWM (about 0.5-5 Hz, 50-500 steps a cycle), vibrato (5-7
Hz, 35-50 steps), portamento (SID303's slide runs at this rate), and the
C64 lead mode (the players it imitates ran at 50 Hz).

May show steps; try these in the prototype:

- **Short filter pluck with high resonance:** a 20 ms decay is only about 5
  cutoff steps; listen for zipper noise. Compare with SID303's acid
  plucks, which already run at this rate.
- **Fast LFO to cutoff or pitch:** at 30 Hz a triangle has only about 8
  points a cycle and turns into a staircase (PWM barely cares).
- **Short, deep sync sweep:** a 50 ms sweep is about 12 steps; it may sound
  stepped instead of tearing smoothly. The most likely place to need more.

If something sounds stepped, try in this order: curves that hide the steps
(exponential decay, log cutoff as in SID303); a limit on the fastest
settings; and last, a core option (off by default) for a faster sub-tick
that writes only one or two registers (cutoff, the synced voice's
frequency), checked against the engine's CPU budget.

**Prototype (2026-11-18):** `proto/ticktest.prg` (`proto/build.sh`) plays
the first three tests and the SH-101 voice (saw + PWM pulse + sub, a ~64 ms
filter decay), each with the SID written at 250 Hz and then at 1000 Hz. A
1 kHz engine computes every curve in both; the 250 Hz parts write the
registers only every 4th tick, so only the update rate differs.
`proto/check_ticktest.py` checks the update rates in VICE. The recording,
on an 8580 in VICE, is `demos/ticktest-250-vs-1000.wav`: a part every
3.84 s, pluck at 0:00 / 0:04, LFO at 0:08 / 0:12, sync at 0:15 / 0:19,
voice at 0:23 / 0:27 (250 Hz first). Verdict (the user, 2026-11-18):
"250 Hz it is".

Probably matters more for the 101 feel than the tick: the ADSR's attack
delay on retrigger (fast notes and legato) and the 8580 filter's range and
resonance.
