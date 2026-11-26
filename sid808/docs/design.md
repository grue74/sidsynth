# SID808 design

How the TR-808's sounds are made on one 8580 SID: three voices, one filter,
one master volume. Decided 2026-11-17: **dynamic voice allocation with
borrowed second voices**, and an engine tick of **500 Hz** (at least 250 Hz).

## 1. The 808's sounds and their SID versions

| 808 sound | 808 circuit | SID version (one voice) | With a borrowed voice |
|---|---|---|---|
| Kick | decaying ~50 Hz sine, small pitch drop, click | triangle, exponential pitch drop to the base pitch, 1-2 ticks of noise or pulse for the click | - |
| Low/mid/high tom, congas | the same, higher, a little noise | triangle with a pitch drop | - |
| Snare | two tones (~180, ~330 Hz) + high-passed noise ("snappy") | tone for the first ticks, then noise (waveform switched per tick) | tone and noise at the same time |
| Rimshot | two short tones (~455, ~1667 Hz), high-passed | a 6 ms triangle tick at 1667 Hz, then 455 Hz (tried: a ring-modulated pair sounding both at once buzzed, demos/rim-compare.mp4) | - |
| Claves | short ~2.5 kHz tone | short triangle burst | - |
| Clap | band-passed noise, 3-4 quick retriggers, reverb tail | noise, level retriggered every few ticks, band-pass | - |
| Maracas | short high-passed noise | short noise | - |
| Cowbell | 540 Hz and 800 Hz squares, band-passed, two-stage decay | pulse, band-pass 1.6 kHz, two-stage decay (one tone) | ring modulation: triangle 670 Hz x the partner's 130 Hz = 540 + 800 Hz (done, below) |
| Closed / open hat | six squares (metallic), high-passed | high noise, high-pass | ring-modulated pulse pair under the noise |
| Cymbal | the six squares, longer, high-passed | noise, long decay | as the hats |
| Accent | global level boost on a step | velocity scales each hit's level (section 4) | - |

## 2. Engine tick

The engine runs at **500 Hz** (2 ms). Pitch drops and the clap's retriggers
need finer steps than 4 ms, and at 2 ms a whole snare can be shaped tick by
tick. The tick rate is a core build option, `TICK_HZ` (default 250, which
SID303 keeps). SID808 sets it to 500. The core derives the keyboard
and paddle scan interval from it, so they still run at 62.5 Hz.

A tick has 985248 / 500 = 1970 cycles. Three voices with an envelope multiply
each, the allocator and the register writes should take well under half of
that; `TEST_TIMING=1` shows the time in the border colour, to check. 1 kHz
(985 cycles) is possible later if the listening tests ask for it.

## 3. Sounds as data

Each sound is a **program**: a list of steps that `tables.py` generates from
a readable description, so sounds are tuned in Python, not in assembly. A
voice runs one program; one interpreter serves all three voices.

A step holds:

| Field | Meaning |
|---|---|
| ticks | how long the step lasts (0 = end of the sound) |
| wave | SID control byte without the gate (waveform, test, ring mod, sync) |
| freq | start frequency (0 = keep the current one) |
| target, glide | frequency moves towards target by 1/2^glide of the distance each tick (exponential, like the 808's pitch drop); glide 0 = no glide |
| pulse | pulse width (high byte) |
| level | 0 = keep the level, else restart it at this value x velocity (clap retriggers) |
| decay | the level's decay rate from here on (a page of the `decay_dlo/dhi` tables: the core `env_decay` result, precomputed) |
| filter | 0 = unfiltered, else wants the filter with this mode and cutoff |

Level is a 16-bit software envelope per voice. Its top four bits go to the
voice's sustain level each tick (section 5).

## 4. Voice allocation

**Choke groups first.** Every sound belongs to a choke group (its own, or a
shared one: closed, pedal and open hat). A new hit chokes the voice playing
its group, if any: that voice fades out (below).

**Then a silent voice, then a fading one, then steal the quietest.** The new
hit takes an idle, silent voice if there is one, so it starts at once while
the choked sound fades on its own voice. Next best is an idle voice still
fading out. If every voice sounds, it steals the one with the lowest score:
the current level weighted by the sound's priority (the kick and snare are
hardest to steal) - but only if the new hit scores higher (its velocity
weighted by its priority). Otherwise the new hit is dropped: in a crowd the
least important sound is lost, whether it is sounding or new. Measured on
the demo track's busiest bars (four bars asking for 4-6 sounds at once):
before, 17 of 86 hits cut off a ringing sound, including the kick and
clap; now 7 do (cowbell tails and a crash cymbal), and 10 soft hits
(maracas, a closed hat) are dropped instead.

**Fade, never cut.** Cutting a sounding voice off at once is a click (it was
heard at every open hat choked by a closed hat: the open hat dropped to
silence within 0.25 ms). A choked or stolen voice gets its gate turned off
with the waveform still running, so the SID's fastest release (rate 0)
fades it; it can be restarted after 2-3 ticks (`fade_ticks`: down to about
a tenth), so a new hit that has to wait for it starts 4-6 ms later.

**One launch per tick.** Starting a voice (the oscillator park, the filter)
is the costliest part of a hit, so at most one voice launches per engine
tick; another waits a tick. The sequencer's hits always launch on a tick
after the one that chose their voices (docs/sequencer.md, CPU per tick).

**Borrowed voices.** A sound may have a second program (a layer). It runs
only if another voice scores below the layer's threshold (idle, or nearly
faded) and is dropped first when another hit needs a voice. So a lone snare
gets tone and noise together, and a busy pattern gets the one-voice snare,
never a cut-off kick.

Layers that use ring modulation or sync need a fixed partner: voice 1 takes
its modulator from voice 3, voice 2 from voice 1, voice 3 from voice 2. Such
a layer can run only on the partner voice. When only voice 3 is needed as a
modulator and must not sound, `3OFF` ($D418 bit 7) mutes it.

**Ring sounds (done: the cowbell).** A sound in `RING_SOUNDS` (tables.py) has
a second program that rings against its partner voice's oscillator. The
cowbell's: a triangle at 670 Hz ring-modulated by 130 Hz, which gives 540 and
800 Hz, the 808's two squares (with weaker 280/1060/1320 Hz), band-passed
at 800 Hz. `voice_pick` first looks for a voice pair: a voice idle (silent
first) whose partner is idle, silent and not lent, and only if the free
voices leave one for each of the step's later hits (the sequencer's
`hits_after`; live MIDI notes can't look ahead). The partner is *lent*: its
oscillator runs at the partner frequency with the gate off (silent), and no
other hit takes it until the sound ends, is choked or stolen (`voice_end`
frees it). With no pair the sound plays its one-voice program, so it never
cuts another sound; in busy parts most cowbells are the one-voice kind
(FULL: 14 ring of 27, FULL_CYM with its long cymbal: none, the demo track
3 of 9). Tried and not chosen (demos/cowbell-compare*.wav): two real pulse
voices at 540 and 800 Hz, and one voice switching between the two pitches
every tick (that is frequency modulation: a buzz at 670 Hz, not two tones).

**Defaults** (from the 808's usual parts, to change after listening):

- Kick + snare or clap + hat must always play together: the allocator
  guarantees this, since three groups never steal from each other while
  each has a voice.
- Snare + clap layered on one step works: they are separate groups.
- Priorities, high to low: kick, snare, clap, toms, cowbell, rimshot,
  claves, cymbal, open hat, closed hat, maracas.

## 5. Amplitude and velocity

As in SID303, every ADSR rate stays at 0 and the level is set through
the sustain level (4 bits) with the gate on. With all rates at 0 the ADSR
delay bug can't happen, so a stolen voice restarts at once, with no hard
restart gap.

The SID's attack always rises to full and then falls to the sustain level
(within ~8 ms at rate 0). For soft hits this would give a full-level click,
so a hit starts with a short **mute phase**: the gate rises while the
oscillator is **parked** at its silent midpoint, and the waveform starts
once the envelope has settled at the hit's level (`mute_ticks` in
`tables.py`: computed from the ADSR rates, plus one tick of margin that
VICE needed; the cause is not identified, and it may depend on load if
ticks run late and back to back). `MUTE_SETTLE=0` builds the other way: one tick, full-level spike.

Parking (`osc_park`): the test bit alone would hold the waveform output at 0,
which is full negative on the SID, and the rising envelope would thump at
full level whatever the velocity (measured: soft toms came out louder than
hard ones). Instead the oscillator runs at frequency $FFFF for exactly 64
cycles from the test bit and is then stopped: a quarter cycle, where the
triangle is at $7FF, the 8580's zero. The wait is cycle-exact (interrupts
off, no badline). In VICE the accumulator starts 3 cycles after the control
write, measured through OSC3. A side effect: tonal sounds start at a zero
crossing, like the 808's.

An NMI can't be masked: a MIDI byte in or out on an NMI interface
(Namesoft) that lands in the window adds its ~45 cycles at $FFFF, the
triangle parks near its peak, and the hit starts with a DC jump: the
intermittent click (about one in 30 s at MIDI clock rates). So CIA1 timer A
times the window and a slow one is done again. Measured in VICE with
`TEST_NMI=317` (an NMI every 317 cycles, ~45 cycles each): voice 3 read back
through OSC3 right after each park, $86 when right; before the fix 18 of 82
parks read $DE, after it 39 of 39 read $86 (39 windows hit and redone). A
voice stopped during its mute phase keeps the parked triangle (its old
sound's waveform there would be a DC level fading out).

Measured in VICE (8580): the mute phase is silent (mean level within the
noise floor until the waveform starts); soft hits (velocity 70) peak at
55-65 % of hard ones (127); the latency from MIDI to sound is 11-12 ms.
Not yet the clap: each of its bursts is a gate retrigger, which attacks to
full level whatever the velocity.

Velocity (= accent from the sequencer) scales the starting level. The
master volume stays fixed (a parameter, default 15). Every write to $D418
combines the volume with the filter mode and `3OFF` bits.

## 6. Filter

One filter, one owner. A sound that wants the filter sets its mode, cutoff
and resonance and routes its voice through it. The newest filtered hit takes
the filter; the previous owner stays routed and its tail goes on through the
new setting. When the owner's sound ends, the filter is free, but its
registers stay as they are.

Except across filter modes (`filter_keep`): a hit that wants another mode
than the owner's doesn't take the filter while the owner sounds if the owner
holds it (`sound_fhold`: a filtered sound that isn't noise, the cowbell) or
scores higher (level x priority); it plays unfiltered. Heard as snaps in the
demo beat's cowbell bar: the closed hat on the cowbell's step took the
filter a few ticks after it, and the band-pass cowbell rang on through the
hats' high-pass, which let only its pulse and ring-modulated edges through,
as ticks over near silence (demo-4: 41 snaps between steps before, 1 with
the score rule alone, 0 with the hold; the track's cowbell bars ~20 -> 2).
Noise sounds through another mode only sound different, so a louder hit
still takes the filter from them.

Routing and mode change only while the voice concerned is parked and
silent (`voice_start`): switching them under a sounding voice makes a DC
jump, which was heard as a snap at every hi-hat (measured: a 1 ms DC shift
of ~760 at each hat; after the change ~30, and the hats' energy below 1 kHz
went from 15 % to 0.2 %).

A filter setting can vary per hit: velocity moves the cutoff (soft hits
darker), and each hit adds a random offset (an 8-bit LFSR value per hit,
the same for all of its steps), so repeated hits never sound identical.
The hats use both (2.5 kHz velocity range, up to ~0.7 kHz random), and
their filter starts higher for the first steps and settles lower.

## 7. SID pitfalls

- Noise plus any other waveform locks up the noise generator. Steps never
  combine them (`tables.py` refuses it).
- Parking resets the oscillator phase at every hit, so every kick has the
  same transient.

## 8. To find out in the prototype

Measured so far: the engine takes at most about a quarter of each 2 ms
tick (`TEST_TIMING=1`). Velocity works; latency 11-12 ms (in audio, the wire
and the attack included). Measured again 2026-11-26 (SID500's
`tools/synth_latency.py`: a kick's note on through the real receive
interrupt at random moments, every SID write stamped): from the note on's last
byte the gate opens at a median 1.9 ms, and the kick's own pitch starts at
7.3 ms (5.3-9.5), the settle taking ~5 ms of it. The main loop reads MIDI
between its scan's pieces too (core `MIDI_POLL_SCAN`, on). Figures:
`../sid500/docs/latency.md`.

By ear, still open:

1. Whether 16 sustain steps sound stepped on long tails (kick, open hat,
   cymbal).
2. Whether the 11-12 ms latency is felt when playing live; if so, try
   `MUTE_SETTLE=0` (4 ms, but soft hits get a full-level spike).
3. Whether 500 Hz is enough for the kick's pitch drop and the clap.
4. The sounds themselves: every program in `tables.py` is a first guess.

## 9. Order of work

1. Core: `TICK_HZ` as a build option (SID303 builds byte-identical).
2. SID808 skeleton on the core: hooks, parameters, key map, build script.
3. One-voice sounds on the allocator, with a `TEST_MIDI` beat to record in
   VICE: kick, snare, clap, hats, cowbell.
4. Borrowed second voices (the cowbell's ring pair is the first).
5. The other sounds, a parameter page per sound (plan step 2: the sound
   page, 10. below).

## 10. The sound page

Every sound has four knobs, like the 808's per-instrument controls:

| Knob | Range | Does | Default |
|---|---|---|---|
| Level | 0..15 | the hit's velocity x level/15 (the steal scores, live record and MIDI out keep the hit's own) | 15 |
| Tune | -12..+12 semitones | every frequency of the sound's program, the start and the glide target (and a ring sound's partner, so the cowbell's pair keeps its ratio); noise sounds too (their noise gets brighter or darker); the filter stays where the program puts it | 0 |
| Decay | 0..15 | how fast the level decays: 2x faster at 0, 4x slower at 15 (a decay time x 2^((k-8)/8) below 8, x 2^((k-8)/3.5) above) | 8 |
| Tone | 0..15 | how bright the attack is, x 2^(s/12) with s from -12 (0: half) to +12 (15: double): a filtered sound's cutoff (every step's; clap, hats, cowbell, cymbal, maracas), an unfiltered sound's first step's start pitch, the glide target kept (the kick's knock, the toms' drop, the snare's snap, the rim's click, the claves' snap) | 8 |

The parameter screen shows one sound's knobs at a time, under Volume:
`Level`, `Tune`, `Decay`, `Tone`, then `Sound`, which picks the sound. The step grid's
cursor row and `Sound` follow each other. The knobs are parameters like the
others, so F1-F4, MIDI controllers (learnt, or the defaults CC 16, 17, 18, 19)
and the paddles all work on them - always on the sound selected at the
moment. (Controllers fixed to one instrument each would need parameter pages
in the core and the parameters out of zero page: a later option.) A knob
change applies from the sound's next hit.

The table (`knob_level`, `knob_tune`, `knob_decay`, `knob_tone`, after the
song block) is saved with the song (file version 3; version 2 files load with
Tone at 8, version 1 files with every knob at its default).

How, at a cost only off the defaults (at the defaults the engine skips the
knob, so the sounds are exactly their programs):
- Level: one multiply when the hit starts (`voice_start`).
- Tune: f +- f_hi x delta per frequency (`tune_word`; one multiply; +12 is a
  doubling), when a step loads; a step's glide target equal to its start is a
  copy of the tuned start.
- Decay: `level_decay` 0..2 times a tick from a per-voice accumulator in
  units of 1/32 (`decay_speed`); the fastest setting is limited to 2x, since
  every pass costs time.
- Tone: `tune_word` with a Tune value from `tone_tune`, on the cutoff (as a
  frequency's high byte, `tone_cutoff`, in `filter_apply`) or on the first
  step's start frequency (`step_load`, after Tune and the hit's pitch raise;
  a first step without a glide keeps its target equal to the toned start).
  Which of the two: the first step has a filter or not (`voice_start`).

Not yet: the 808's snare Snappy (the noise part's level).
