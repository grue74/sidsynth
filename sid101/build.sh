#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Build sid101.prg, the demos (sid101-demo.prg: the voice, demos/a-voice.wav;
# sid101-sync.prg: Sync mode, demos/b-sync.wav; sid101-mod.prg: modulation,
# demos/c-modulation.wav; sid101-seq.prg: the sequencer playing a song,
# demos/d-sequencer.wav; sid101-arp.prg: the arpeggiator,
# demos/e-arpeggiator.wav; sid101-presets.prg: the factory presets,
# demos/g-presets.wav; sid101-c64.prg: the C64 lead mode,
# demos/h-c64-voice.wav; sid101-chords.prg: its chords, demos/h2-c64-chords.wav)
# and two .d64s, every program packed: sid101.d64 the synth alone,
# sid101-demos.d64 the demos. Needs python and
# 64tass on PATH.
set -e
cd "$(dirname "$0")"

# Build number, shown in the title row for bug reports: the number of git
# commits, plus one if there are uncommitted changes (not counting the build
# outputs themselves). So a build made just before a commit carries that
# commit's number, and rebuilding a clean checkout gives the same number.
# No date or time goes in, so rebuilding unchanged source gives identical files.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ -n "$(git status --porcelain -- . ':!*.prg' ':!*.d64' ':!docs/*.pdf' ':!docs/screen*.png' ':!demos/*' 2>/dev/null)" ]; then
    BUILD=$((BUILD + 1))
fi
echo "$BUILD" > build-number.txt        # read by make_site.py

python tables.py
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -L sid101.lst --vice-labels -l sid101.lbl -o sid101.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=1 -o sid101-demo.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=2 -o sid101-sync.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=3 -o sid101-mod.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=6 -D TEST_SEQ=1 -D TEST_SONG=2 -o sid101-seq.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=13 -o sid101-arp.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=14 -o sid101-presets.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=17 -o sid101-c64.prg sid101.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=19 -o sid101-chords.prg sid101.asm
# the disks get every program packed (c64pack, the fast format: about 80 %
# of the size, unpacked in half a second; its depacker uses zero page
# $F9-$FE and $2D/$2E only, so the KERNAL zero page the program keeps for
# disk access, core KERNAL_ZP_COPY, is as BASIC left it). The plain PRGs
# stay as built, for the tests and VICE.
PACKER="../tools/c64pack.py"
START=0x$(grep -i '\.start$' sid101.lbl | cut -d' ' -f2)   # the program's entry (after the SYS line)
PACKED=$(mktemp -d)
trap 'rm -rf "$PACKED"' EXIT
for f in sid101 sid101-demo sid101-sync sid101-mod sid101-seq sid101-arp sid101-presets sid101-c64 sid101-chords; do
    python "$PACKER" -verify $f.prg "$PACKED/$f.prg" $START > /dev/null
done
# two disks: the synth alone (sid101.d64: room for songs and banks) and
# the demos (sid101-demos.d64)
D64="../tools/d64.py"
python "$D64" --name "SID101" --id 01 sid101.d64 "$PACKED/sid101.prg=SID101"
python "$D64" --name "SID101 DEMOS" --id 02 sid101-demos.d64 \
    "$PACKED/sid101-demo.prg=SID101-DEMO" "$PACKED/sid101-sync.prg=SID101-SYNC" \
    "$PACKED/sid101-mod.prg=SID101-MOD" "$PACKED/sid101-seq.prg=SID101-SEQ" \
    "$PACKED/sid101-arp.prg=SID101-ARP" "$PACKED/sid101-presets.prg=SID101-PRESETS" \
    "$PACKED/sid101-c64.prg=SID101-C64" "$PACKED/sid101-chords.prg=SID101-CHORDS"
ls -l sid101.prg sid101-demo.prg sid101-sync.prg sid101-mod.prg sid101-seq.prg sid101-arp.prg sid101-presets.prg sid101-c64.prg sid101-chords.prg sid101.d64 sid101-demos.d64
echo "build $BUILD"
