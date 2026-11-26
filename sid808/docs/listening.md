# Listening tests

Recordings in `demos/` (VICE, reSID 8580), made from the programs on
`sid808.d64`. Notes on what is heard go to `docs/design.md` 8.

## demo-4, track-6: the sounds as they are now

`demo-4` (SID808-DEMO): every sound soft, then hard, then an 808 beat.
`track-6` (SID808-TRACK): the drum track. Compare with `demo-3` and
`track-5` (the build before the sound page, Tone and the click fix): with the
knobs at their defaults they should sound the same.

## problems-1: the places where the engine might go wrong

SID808-PROBLEMS (`TEST_MIDI=7`, tables.py `PROBLEM_SECTIONS`). Times are in
the recording:

| Time | Section | Listen for |
|---|---|---|
| 0:00 | Long tails | kick, open hat, cymbal alone, then the kick at Decay 15 (4x longer): do the tails fade smoothly, or in audible steps (the level has 16 steps)? |
| 0:11 | Soft to hard | snare, then low tom, velocity 8 to 127 in 16 steps: an even rise, no thump or spike on the soft ones (the attack mute)? |
| 0:20 | Flams and chokes | closed then open hat 4 ms apart, open then closed 6 ms apart, kick on kick 4 ms apart: a hit stopped right after its start - clicks or thumps? |
| 0:26 | Fast repeats | high tom every 40 ms, snare every 30 ms, closed hat every 20 ms: each restart cuts a fading voice - clicks, uneven rolls? |
| 0:31 | Filter handover | clap then closed hat 20 ms later, cowbell then open hat 10 ms later, cymbal then clap: the filter changes under a ringing tail - snaps? |
| 0:37 | Crowd | five sounds at once every 8th, then a cymbal the crowd steals from: which sounds drop out, any clicks when a voice is taken? |
| 0:42 | Cowbell pair | cowbell alone (two voices, ring-modulated), then with kick and open hat sounding (one voice): how big is the difference? |
| 0:46 | Kick Tone and Tune | kick at Tone 0, 4, 8, 12, 15, then Tune -12, -6, 0, +6, +12: even steps, no glitches? |

## stress-1, stress-max-1: tempo under load

SID808-STRESS and SID808-STRESSMAX (`TEST_STRESS=1`, pattern 14): the
sequencer at 125 BPM, the kick on the quarters to judge the tempo by, every
other sound on every 16th (levels varied, so voices keep being taken).
`stress-max` also has every sound at Tone 15, Tune +12, Decay 0, and an NMI
every 317 cycles (`TEST_NMI`: a MIDI byte arriving without a break, ~14 % of
the CPU) - far more than real use.

Measured (each kick's launch logged with the timer interrupt's tick count,
127 kicks):

- `stress`: kicks 238-242 ticks apart (240 = a quarter; +-4 ms), the main
  loop at most 12 ticks behind and catching up: in time.
- `stress-max`: the main loop can't keep up: it falls behind steadily, the
  tempo about 4-5 % slow, and past 255 ticks behind the 8-bit tick count
  wraps and the lost ticks are never played (the sequencer keeps counting
  steps in ticks it ran, so it slows rather than dropping hits). Extreme
  knobs alone or the NMIs alone keep time (at most 12-15 ticks behind).
- The status row's `CPU` warning (`docs/sequencer.md`, CPU overload): off
  in `stress`, `CPU!` in `stress-max`.
