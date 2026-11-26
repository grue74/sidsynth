#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Build sid500.prg, its disk overlay sid500-disk.prg, and sid500.d64: SID500
# packed, the overlay and the four demo songs (songs/, tools/demo_songs.py).
# Needs python and 64tass on PATH, ../packer and ../c64tools.
set -e
cd "$(dirname "$0")"

# Build number, shown in the title row for bug reports: the number of git
# commits, plus one if there are uncommitted changes (not counting the build
# outputs themselves). So a build made just before a commit carries that
# commit's number, and rebuilding a clean checkout gives the same number.
# No date or time goes in, so rebuilding unchanged source gives identical files.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ -n "$(git status --porcelain -- . ':!*.prg' ':!*.d64' ':!docs/*.pdf' ':!docs/screen*.png' 2>/dev/null)" ]; then
    BUILD=$((BUILD + 1))
fi
echo "$BUILD" > build-number.txt

python tables.py
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -L sid500.lst --vice-labels -l sid500.lbl -o sid500.prg sid500.asm
# the disk overlay (src/disk.asm): the same source, its section only; on a
# disk as "sid500 disk"
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D DISK_OV_OUT=1 --output-section=disk_ov -o sid500-disk.prg sid500.asm
# the disk: SID500 packed (c64pack, the fast format; its depacker uses zero
# page $F9-$FE and $2D/$2E only, so the KERNAL zero page SID500 keeps for disk
# access, core KERNAL_ZP_COPY, is as BASIC left it), the overlay as built (SID500
# loads it with the KERNAL, at its own place), and the demo songs under their
# titles. The plain PRGs stay as built, for the tests and VICE.
PACKER="../tools/c64pack.py"
D64="../tools/d64.py"
START=0x$(grep -i ' \.start$' sid500.lbl | cut -d' ' -f2)   # the program's entry (after the SYS line)
PACKED=$(mktemp -d)
trap 'rm -rf "$PACKED"' EXIT
python "$PACKER" -verify sid500.prg "$PACKED/sid500.prg" $START > /dev/null
python "$D64" --name "SID500" --id 05 sid500.d64 "$PACKED/sid500.prg=SID500"     "sid500-disk.prg=SID500 DISK" "songs/echo chamber.s5=echo chamber.s5"     "songs/glass horizon.s5=glass horizon.s5" "songs/summer signal.s5=summer signal.s5"     "songs/moonlight.s5=moonlight.s5" > /dev/null
ls -l sid500.prg sid500-disk.prg sid500.d64
echo "build $BUILD"
