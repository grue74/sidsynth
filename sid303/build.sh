#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Build sid303.prg (and sid303-test.prg, which plays a built-in MIDI test
# pattern) plus a .d64. Needs python and 64tass on PATH.
set -e
cd "$(dirname "$0")"

# Build number, shown in the title row for bug reports: the number of git
# commits, plus one if there are uncommitted changes (not counting the build
# outputs themselves). So a build made just before a commit carries that
# commit's number, and rebuilding a clean checkout gives the same number.
# No date or time goes in, so rebuilding unchanged source gives identical files.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ -n "$(git status --porcelain -- . ':!*.prg' ':!*.d64' ':!docs/*.pdf' 2>/dev/null)" ]; then
    BUILD=$((BUILD + 1))
fi
echo "$BUILD" > build-number.txt        # read by make_site.py

python tables.py
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -L sid303.lst --vice-labels -l sid303.lbl -o sid303.prg sid303.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=1 -o sid303-test.prg sid303.asm
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_MIDI=2 -o sid303-sweep.prg sid303.asm
python "../tools/d64.py" --name "SID303" --id 03 \
    sid303.d64 "sid303.prg=SID303" "sid303-test.prg=SID303-DEMO" "sid303-sweep.prg=SID303-SWEEP"
ls -l sid303.prg sid303-test.prg sid303-sweep.prg sid303.d64
echo "build $BUILD"
