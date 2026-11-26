# SidSynth

Synthesizers and a sequencer for the Commodore 64 and its SID chip, built on
one shared core. Each program turns a C64 into one dedicated instrument,
played from MIDI, its own keyboard and paddles.

**Web site: [voidhole.com/~grue/sidsynth](https://voidhole.com/~grue/sidsynth/)**,
with each program's page, its demos to watch and hear, the manuals and the
disk images.

| Folder | What it is |
|---|---|
| `sid303/` | **SID303**, an acid bass synth in the spirit of the TB-303, with its own step sequencer |
| `sid808/` | **SID808**, an 808-style drum machine: thirteen drum sounds synthesized live |
| `sid101/` | **SID101**, an SH-101 style lead synth with a sync lead, the C64's own 80s lead and an arpeggiator |
| `sid500/` | **SID500**, a 16-channel MIDI sequencer named after the Roland MC-500, playing the others |
| `core/` | the shared core: start-up, MIDI in and out, parameters, keyboard, paddles, screen |
| `sidsynth/` | the family's web site: each program's `make_site.py` writes its page into `sidsynth/site/` |
| `tools/` | `c64pack.py` (the packer the disk images use; its own Greetings Licence: `tools/LICENSE-c64pack.txt`), `d64.py` (writes the disk images) |

Each program has its own README or manual (`docs/*-manual.pdf`, built by
`docs/manual.py`) and its design notes in `docs/`.

## Building

You need [64tass](https://sourceforge.net/projects/tass64/) and Python 3 on
the path (and `pip install py65` for the packer's self-check). In a program's
folder, `sh build.sh` assembles it and writes its disk image. The core
options are off by default, so every program builds byte-identical whatever
the others turned on.

The checks in each program's `tools/` run the programs in the VICE emulator
and need VICE and further helper scripts (`c64tools`) that are not part of
this repository.

## Hardware

A PAL Commodore 64 (the synths sound as meant with an 8580 SID), a MIDI
cartridge (Datel/Siel/JMS, Sequential, Passport or Namesoft, or a Kerberos
set to one of them) and, for SID500, MIDI instruments on its MIDI OUT.

## License

Copyright (C) 2026 Jarkko Lehti. Free software under the GNU General Public
License version 3 or later: see `LICENSE`. The packer (`tools/c64pack.py`,
`tools/test_pack.py`) is under its own Greetings Licence
(`tools/LICENSE-c64pack.txt`): use it freely, greet its author in what you
release with it. SID500's Moonlight Sonata demo song
(`sid500/songs/moonlight.s5`) holds notes from the Mutopia Project's edition
(Berners 1908, ed. Winterberger; CC BY-SA 2.5).
