# SID500 first version: plan

Written 2026-11-20, from `design.md` (all its questions settled). SID101 is
the model for the project's layout, build, tests, manual and site; the
core's step sequencer and SID303's / SID101's step screens for the editing
keys. Every stage is checked in VICE before the next one starts, and the
user tries each stage that changes how it plays or edits.

SID500 makes no sound of its own until stage H, so a stage's "demo" is what
it sends: a `TEST_LOG` build logs every MIDI byte out with its time, a
Python model says what should have gone out, and from stage C on the
family's synths can play it (the band setup in `../sidsynth/band`, as Glide
Path is recorded) for the user to hear.

## Timing: in sync, no added MIDI lag

The user's requirement (2026-11-20): everything runs in sync, and SID500
adds no MIDI lag. `design.md` section 4 has the design, from a review of
this plan against the core's code (Fable 5.2, 2026-11-20). In short, and
checked in every stage that plays:

1. **The player runs in CIA1 timer A's interrupt** (the core's tick moved to timer B: `design.md` 4), timed to the exact
   sequencer tick at the tempo (dithered, no drift), not in the 250 Hz
   main-loop tick (which would add 0-4 ms of grid error and 0.3-4 ms of
   main-loop delay). The 250 Hz tick stays for keys, screen and the synth.
2. **Clock jumps the queue** (an urgent slot before the transmit ring):
   jitter at most about 0.7 ms however busy the wire is.
3. **Nothing is ever dropped:** the player waits for room; order clock,
   thru, note offs, notes, controllers (a waiting controller replaced by
   its newer value). One merger writes MIDI out.
4. **Slave:** incoming clock acted on in the receive interrupt, the odd
   tick interpolated by timer A; **clock passed on** to MIDI out about 0.3
   ms later (the user: yes), so the synths downstream stay in sync.
5. **Thru** goes right after clock, ahead of sequenced notes.
6. **The wire is the only lag left** (3125 bytes a second): tracks go out
   in a fixed priority order, the same every time.

**Tests:** the MIDI out log is stamped in the transmit handler with a CIA
timer reading, not the 4 ms tick, and checked in microseconds: each byte
against the model's exact time, clock intervals even within 0.7 ms under
the heaviest load (16 tracks of chords and controllers, the editor busy),
no byte ever dropped, no stuck note. First, in stage A: find out whether
VICE sends ACIA bytes at the wire's speed; if not, the burst tests use a
throttled model and the user's real hardware.

## The editor: requirements for every stage

The user's requirements (2026-11-20), checked in every stage that draws:

1. **No flashing.** No cell may ever be seen half drawn: not a template
   then its value, not a row cleared then filled, not a colour changed a
   frame before or after its text. Every row is drawn with the core's
   `RASTER_SAFE` rule (`row_safe`: only when the beam won't pass it while
   it is drawn), and a cell is written once, with its final character and
   colour. **Test:** each editing stage's key scripts are recorded with
   `../c64tools/vicerec.py`, and a check finds any cell that changes and
   changes back within two frames, as well as
   any frame where a cell's text and its colour disagree with the model.
   (Built in stage B as `tools/flash_check.py`, the family's first: a
   frame mark, `TEST_FRAMES`, where VICE's binary monitor takes every
   frame, decoded into characters and colours; no family synth had one,
   despite what this said before.)
2. **Very responsive.** A key's effect is on the screen in the next frame
   (20 ms) at the latest, also while the sequencer plays 16 busy tracks:
   - the cursor and the cell being edited are drawn first, before any
     other row (a "dirty" list with the cursor's rows at its head), never
     waiting behind a full redraw;
   - the rest of a screen change (a page turned, a pattern changed) follows
     a row per main-loop pass, at most a frame or two for the whole screen;
   - keys repeat smoothly (the core's repeat), and no key press is lost
     while a screen is being drawn or the disk is idle.
   **Test:** `TEST_KEYS` builds log, for every key, the tick it was read
   and the tick its cell was written; a Python check requires at most one
   frame (5 ticks) between them in every script, under the heaviest
   playing load (16 tracks, a chord on each, controllers).
3. **The engine never waits.** Drawing never holds up the 250 Hz tick: the
   engine stays at most 1 tick behind (the family's rule), measured with
   the editor busy. Screen work is cut into pieces that fit between ticks.
   The player itself runs in timer A's interrupt (the timing section above),
   so drawing can't delay a note at all; but the interrupts stretch a row's
   drawing, so the core's `SAFE_LINES` margin is measured with the player
   and the transmit interrupt at their busiest, and each cell's character
   and colour are written back to back.

## Colour: the channels

Each track's notes and events are shown in its **MIDI channel's colour**,
on every screen (the song grid, the step grid, the event list, the track
page), so a channel is recognised at a glance wherever it appears.

- The C64 has 16 colours and MIDI 16 channels, but not every colour reads
  on the background (black and dark grey on a dark screen, blue on blue).
  So the background is black, and the palette is chosen for legibility:
  the readable colours first, the few dim ones reused with reverse video or
  a marker, so that no two channels a song is likely to use side by side
  look alike. The palette is decided with the user from a test screen
  (stage B) before it is used everywhere.
- The cursor and the playing step are shown by reverse video, not by a
  colour, so they never hide a channel's colour.
- **The palette** (chosen with the user, 2026-11-20, from `tools/palette.py`'s
  test screen; no dim colours: blue and brown left out, too dim on black):

  | Channels | Colours |
  |---|---|
  | 1-6 | red, orange, yellow, light green, cyan, light blue |
  | 7-12 | purple, light red, green, white (10: drums by General MIDI), light grey, grey |
  | 13-16 | cyan, purple, red, light green (the same as 5, 7, 1 and 4) |

- Muted tracks are drawn in dark grey; solo shows the soloed tracks in
  their colours and the rest grey.
- Colour RAM is written in the same pass as the screen cell (rule 1): a
  cell's text and colour change together.

## Stages

| Stage | What | Checked by |
|---|---|---|
| A | **The player, in sync.** The core options first (done 2026-11-20: the player's timer, urgent realtime queue, realtime bytes to a hook, interrupt handlers that switch I/O in, a transmit hook for the tests; off by default, SID303/SID808/SID101 byte-identical, `tools/core_identical.py`). The project on the core (`sid500.asm`, `src/`, `build.sh`, `tables.py`). The compact event format in the pool of linked blocks; patterns of 1-128 steps, scenes with a length and time signature, 16 tracks on their channels with a priority. The player in timer A's interrupt at 48 ticks a quarter (tempo, swing, dithered period); per-track next-event pointers, one note-off queue; the merger: running status, never dropping, clock urgent. Master clock, start, stop, continue, song position; **slave clock designed in here** (it shapes the interrupts): clock in caught in the receive interrupt, the odd tick interpolated, clock passed on. Test patterns built in by `tables.py`. | `tools/play_check.py`: the MIDI out log, stamped in microseconds in the transmit handler, against a Python model of the player: every byte at its exact time (within the interrupt's latency plus the wire), clock even within 0.7 ms under the heaviest load, nothing dropped, no stuck note; as slave, the ticks and the passed-on clock against a fed clock; VICE's ACIA: 283 cycles a byte (found from its source) |
| B | **The song screen and colours** (its texts and tables under I/O, copied there at start). The 16 tracks across, scenes down, the pattern each plays; mute, solo, the playing scene; the channel colours (the palette tried on a test screen with the user first). The editor's drawing rules in place: the dirty-row list, cursor first, `row_safe`. | the flash check and the key-to-screen check (above), the screen against a model of what it should show |
| C | **The step grid and the metronome.** One track's pattern, 16 steps a page: notes, velocity, length, step entry from the C64 keys and MIDI, copy, clear, length, transpose; undo (SID303's). The metronome (design 4b): a soft SID click on voice 3 (always its own) started from the player's interrupt, brighter on the bar's first beat, off by default and toggled by a key, optionally also a MIDI note. | flash and response checks; edits against a model; the click's SID writes on the beat (microseconds, as the MIDI checks); a WAV of the click for the user to judge its softness; first listening: a song entered by steps played by the family's synths |
| D | **Recording in real time.** Record a track from MIDI in while it plays (a count-in of 0-2 bars that clicks even with the metronome off; overdub or replace) into the take buffer, merged a piece at a time between ticks; MIDI thru to the record track's channel through the merger, right after clock; quantize (kept separately, changeable); controllers and bend thinned; timestamps rounded to the nearest tick. | `TEST_MIDI` feeds a played part; the recorded events against a model, the thru bytes and their lag (microseconds), the player's timing unchanged while recording and merging |
| E | **Scenes, the song and live play.** The song of scenes with repeats; launching a scene or one track's pattern while it plays, at the end of the bar or pattern; the same by MIDI (CC 85 as the family, program change). | the out log against the model through song and live changes |
| F | **The event list and the family's names.** The list view of a pattern (position, value, velocity, length; edit, insert, delete); tracks marked as SID303, SID808 or SID101 show their drum, preset and controller names. | flash and response checks; edits against the model |
| G | **Song position as slave, disk, SysEx.** Locate by song position as slave (the clock itself is stage A's); save and load the whole song, packed (the pool and the song all below $D000: SAVE writes straight from memory), disk only while stopped; SysEx dumps streamed or limited in size (a full song is bigger than the core's 4 KB staging area at $E000). | song position tests as SID101's seq_check, disk round trips with a full pool, dump_check |
| H | **Left out (the user, 2026-11-25: it won't fit; the pool is the songs').** ~~**The drone synth**~~ (if there was time; design section 6): one ambient, slowly changing sound on one channel made of SID voices 1 and 2 (voice 1 modulating voice 2: ring modulation, sync, detune), the SID's own slow envelope, slow LFOs and random wander, noise and the filter; updated at 50 Hz, spread over the 250 Hz ticks; its parameters and presets. Voice 3 stays the metronome's. | sound demos for the user; its SID writes against a model; play_check's timing unchanged with the drone playing |
| I | Manual, the web page in the SidSynth site, the disks, real hardware checks by the user. | the user |

Stage A is invisible (no editor), so B is the first one the user tries; the
editor's requirements are designed in from B on, not added afterwards.
