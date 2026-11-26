#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# The manual's and the web page's screenshots, from VICE (../c64tools/vicecap.py):
# docs/screen.png, the parameter screen at start (sid101.prg), and
# docs/screen-steps.png, the step screen with pattern 1 playing (a TEST_KEYS=14
# build). Run build.sh first: the screens show its build number.
set -e
cd "$(dirname "$0")/.."
BUILD=$(cat build-number.txt)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD -D TEST_KEYS=14 -o "$TMP/steps.prg" sid101.asm
python ../c64tools/vicecap.py --seconds 5 sid101.prg docs/screen.png
python ../c64tools/vicecap.py --seconds 6.3 "$TMP/steps.prg" docs/screen-steps.png
