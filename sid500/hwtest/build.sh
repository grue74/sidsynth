#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the MIDI latency test (midilat.prg) and a disk with it (midilat.d64),
# for a real C64 with a MIDI cartridge (docs/latency.md "The hardware test").
# Needs 64tass and python on PATH, ../../c64tools.
set -e
cd "$(dirname "$0")"
64tass -I .. -C -q --cbm-prg -o midilat.prg midilat.asm
python ../../c64tools/d64.py --name "MIDI LATENCY" --id ML midilat.d64 "midilat.prg=MIDILAT"
ls -l midilat.prg midilat.d64
