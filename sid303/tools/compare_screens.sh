#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Runtime refactoring check: run the scripted test builds from a git revision
# (default HEAD) and from the working tree in VICE, and compare the final
# screens pixel for pixel. The scripts are timed in keyboard scans, so the
# same program behaviour gives the same end screen.
#
#   sh tools/compare_screens.sh [REV]
#   ONLY=keys sh tools/compare_screens.sh [REV]     (one run)
#
# Needs x64sc (VICE) and the c64tools vicecap.py next to this project.
# Exit status 0 = every screen identical.
set -e
cd "$(dirname "$0")/.."
REV=${1:-HEAD}
BUILD=99
VICECAP="$(cd .. && pwd)/c64tools/vicecap.py"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

git archive "$REV" | tar -x -C "$OUT" --one-top-level=old
# submodules (core/) aren't in git archive: add each at the commit REV records
git ls-tree "$REV" | awk '$2 == "commit" {print $3, $4}' | while read -r sha path; do
    mkdir -p "$OUT/old/$path"
    git -C "$path" archive "$sha" | tar -x -C "$OUT/old/$path"
done
python tables.py >/dev/null
cp tables.inc "$OUT/old/"

# name|64tass options|seconds to run before the screenshot. Only scripts that
# end in a still state belong here: the screen is redrawn one row per scan,
# so with a pattern that keeps playing (TEST_MIDI=1) a few cycles' shift in
# code layout changes which moment each row shows, and the screens differ
# even for pure code moves.
RUNS="main||4
keys|-D TEST_KEYS=1|20
learn|-D TEST_KEYS=2 -D TEST_MIDI=3|12
padlearn|-D TEST_KEYS=3 -D TEST_PADDLES=1|9"

# ONLY=name runs just that one
[ -n "$ONLY" ] && RUNS=$(echo "$RUNS" | grep "^$ONLY|")

echo "$RUNS" | while IFS='|' read -r name defs secs; do
    # shellcheck disable=SC2086
    (cd "$OUT/old" && 64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD $defs -o "$OUT/$name-old.prg" sid303.asm)
    # shellcheck disable=SC2086
    64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD $defs -o "$OUT/$name-new.prg" sid303.asm
    (cd "$OUT" && python "$VICECAP" "$name-old.prg" "$name-old.png" --seconds "$secs" >/dev/null \
               && python "$VICECAP" "$name-new.prg" "$name-new.png" --seconds "$secs" >/dev/null)
    if cmp -s "$OUT/$name-old.png" "$OUT/$name-new.png"; then
        echo "same     $name"
    else
        echo "DIFFERS  $name"
        mkdir -p screens-diff
        cp "$OUT/$name-old.png" "$OUT/$name-new.png" screens-diff/
        echo 1 > "$OUT/failed"
    fi
done
[ ! -f "$OUT/failed" ] || { echo "differing screens copied to screens-diff/"; exit 1; }
