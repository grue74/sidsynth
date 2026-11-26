# SID101

A monophonic lead synth for the Commodore 64 and its 8580 SID, in the spirit
of the Roland SH-101: saw, pulse with PWM and a sub-oscillator on the SID's
three voices through one resonant filter, with a sync lead mode, an
arpeggiator, a step sequencer and 32 named presets. The third synth of
**SidSynth**, after SID303 (acid bass) and SID808 (drum machine), built on
the same shared core.

**Status:** first version (stages A to F of `docs/plan.md`), presets (stage
G). The user manual is `docs/SID101-manual.pdf`; the web page is in the
SidSynth site (`../sidsynth/site/sid101/`).

## Building

Needs python (with reportlab and Pillow for the docs), 64tass and, for the
page, ffmpeg.

| Command | What |
|---|---|
| `sh build.sh` | `sid101.prg`, the six demo programs and `sid101.d64` |
| `sh tools/screenshots.sh` | `docs/screen.png`, `docs/screen-steps.png` (VICE) |
| `python docs/icon.py` | the icon: `docs/favicon.svg` and its PNGs |
| `python docs/manual.py` | `docs/SID101-manual.pdf` |
| `python make_site.py` | the web page into `../sidsynth/site/sid101/` (or run `../sidsynth/make_site.py`, which runs this) |

Checks in VICE (one at a time: two VICE runs at once disturb each other):
`tools/voice_check.py`, `tools/seq_check.py`, `tools/arp_check.py`,
`tools/preset_check.py`.

## Files

| File | What |
|---|---|
| `sid101.asm`, `src/` | the synth, on the core |
| `tables.py` | the lookup tables, the start patterns and the demos' MIDI feeds (`tables.inc`), the factory presets (`presets.inc`) |
| `demos/` | the stage demos (VICE, 8580, real time), the demo video |
| `docs/plan.md` | the stages, how each was built and checked, the listening verdicts |
| `docs/design.md` | the design and the start-up decisions |
| `docs/shared-parts.md` | what SID101 gets from the family: the core, the copied parts, the working rules |
| `docs/reference/` | copies of SID303's and SID808's docs as they were when this project was set up |
| `core/` | git submodule (repo `synthcore`): the SID synth core shared with SID303 and SID808 |
| `CLAUDE.md` | how this project is worked on |

After cloning: `git submodule update --init`.

## License

Copyright (C) 2026 Jarkko Lehti. Free software under the GNU General Public
License, version 3 or (at your option) any later version; see
[LICENSE](LICENSE).
