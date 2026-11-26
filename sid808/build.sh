#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Build sid808.prg (and sid808-test.prg, which plays a built-in MIDI test
# pattern: every sound soft and hard, then an 808 beat; sid808-track.prg
# plays a drum track) plus a .d64.
# Needs python and 64tass on PATH.
set -e
cd "$(dirname "$0")"

# Build number, shown in the title row for bug reports: the number of git
# commits, plus one if there are uncommitted changes (not counting the build
# outputs themselves). No date or time goes in, so rebuilding unchanged
# source gives identical files.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ -n "$(git status --porcelain -- . ':!*.prg' ':!*.d64' 2>/dev/null)" ]; then
    BUILD=$((BUILD + 1))
fi
echo "$BUILD" > build-number.txt

# Version (VERSION, edited by hand at a release: major.minor.patch, tagged
# v<version> in git), shown with the build number: "v0.9.0 build 30" names
# the exact build in a report. version.txt is for the manual and web page.
VERSION=$(tr -d ' \r\n' < VERSION)
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "VERSION must be major.minor.patch, not '$VERSION'"; exit 1 ;;
esac
set -- $(echo "$VERSION" | tr . ' ')
VER="-D BUILD=$BUILD -D V_MAJOR=$1 -D V_MINOR=$2 -D V_PATCH=$3"
echo "v$VERSION build $BUILD" > version.txt

python tables.py
64tass -I .. -C -a -q --cbm-prg $VER -L sid808.lst --vice-labels -l sid808.lbl -o sid808.prg sid808.asm
# the demos: their MIDI feeds are long, so fewer undo steps (undo.asm) for room
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_MIDI=1 -D UNDO_STEPS=8 -D DUMPS=0 -o sid808-test.prg sid808.asm
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_MIDI=2 -D UNDO_STEPS=8 -D DUMPS=0 -o sid808-track.prg sid808.asm
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_MIDI=1 -D TEST_TIMING=1 -D UNDO_STEPS=8 -D DUMPS=0 -o sid808-timing.prg sid808.asm
# listening tests: the problem spots (docs/design.md 8), and the CPU stress
# pattern on the sequencer (every sound on every step, kick on the quarters),
# as it is and with every sound at Tone 15, Tune +12, Decay 0 and an NMI
# every 317 cycles (MIDI-rate interrupts)
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_MIDI=7 -D UNDO_STEPS=6 -D DUMPS=0 -o sid808-problems.prg sid808.asm
# (these too with fewer undo steps: SysEx dumps took the room; and the
# self-playing builds without the dumps, DUMPS=0, so six fit on the disk)
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_STRESS=1 -D TEST_SEQ=1 -D TEST_SEQ_PAT=13 -D UNDO_STEPS=8 -D DUMPS=0 -o sid808-stress.prg sid808.asm
64tass -I .. -C -a -q --cbm-prg $VER -D TEST_STRESS=1 -D TEST_SEQ=1 -D TEST_SEQ_PAT=13 -D UNDO_STEPS=8 \
    -D TEST_TONE=15 -D TEST_TUNE=24 -D TEST_DECAY=0 -D TEST_NMI=317 -D DUMPS=0 -o sid808-stress-max.prg sid808.asm
python "../tools/d64.py" --name "SID808" --id 08 \
    sid808.d64 "sid808.prg=SID808" "sid808-test.prg=SID808-DEMO" "sid808-track.prg=SID808-TRACK" \
    "sid808-problems.prg=SID808-PROBLEMS" "sid808-stress.prg=SID808-STRESS" \
    "sid808-stress-max.prg=SID808-STRESSMAX"
ls -l sid808.prg sid808-test.prg sid808-track.prg sid808-problems.prg sid808-stress.prg sid808-stress-max.prg sid808.d64
echo "v$VERSION build $BUILD"
