# SID500

A 16-channel MIDI sequencer for the Commodore 64, named after the Roland
MC-500: 16 tracks, each on its own MIDI channel, playing patterns that a
song chains, recorded in real time from a MIDI keyboard or entered step by
step. A soft SID metronome; later, if there is time, an ambient drone
synth of its own on two SID voices. The fourth program of **SidSynth**,
after SID303 (acid bass), SID808 (drum machine) and SID101 (lead synth),
built on the same shared core.

**Status:** design settled (`docs/design.md`) and the stages planned
(`docs/plan.md`), 2026-11-20; next, stage A.

| File | What |
|---|---|
| `docs/design.md` | the design, its questions settled |
| `docs/plan.md` | the stages, and the editor's requirements (no flashing, responsive, channel colours) |
| `core/` | the SidSynth core (the `synthcore` submodule) |

Copyright (C) 2026 Jarkko Lehti. Free software under the GNU GPL v3 or
later (`LICENSE`).
