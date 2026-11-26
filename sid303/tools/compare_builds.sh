#!/bin/sh
# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
# Refactoring check: assemble every build variant from a git revision
# (default HEAD) and from the working tree, with the same fixed build number
# and the same tables.inc, and compare the PRGs byte for byte.
#
#   sh tools/compare_builds.sh [REV]
#   ZP_REMAP=1 sh tools/compare_builds.sh [REV]
#   ROUTINES=1 sh tools/compare_builds.sh [REV]
#
# Exit status 0 = every variant identical. With ZP_REMAP=1 a variant may
# also differ by moved zero-page variables only (zp_remap_check.py).
# With ROUTINES=1 a variant may differ by moved code and data only: every
# routine and table, compared by name with addresses as label+offset
# (routine_compare.py), lists what really changed. Both comparers are in the
# shared c64tools folder next to this project.
# The temporary tree is a git archive, so files not yet committed (in either
# tree) count as part of the working tree only.
set -e
cd "$(dirname "$0")/.."
REV=${1:-HEAD}
BUILD=99                        # fixed: the real build number would differ
C64TOOLS="$(cd .. && pwd)/c64tools"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# the revision's sources in a temporary tree, with this tree's tables.inc
git archive "$REV" | tar -x -C "$OUT" --one-top-level=old
# submodules (core/) aren't in git archive: add each at the commit REV records
git ls-tree "$REV" | awk '$2 == "commit" {print $3, $4}' | while read -r sha path; do
    mkdir -p "$OUT/old/$path"
    git -C "$path" archive "$sha" | tar -x -C "$OUT/old/$path"
done
python tables.py >/dev/null
cp tables.inc "$OUT/old/"

VARIANTS="main|
test-midi|-D TEST_MIDI=1
sweep|-D TEST_MIDI=2
keys|-D TEST_KEYS=1
learn|-D TEST_KEYS=2 -D TEST_MIDI=3
padlearn|-D TEST_KEYS=3 -D TEST_PADDLES=1
timing|-D TEST_TIMING=1
raw|-D FILTER_ROUTING=0
uponly|-D ENVTYPE_DEFAULT=0
sequential|-D MIDI_IF_DEFAULT=1"

fail=0
echo "$VARIANTS" | while IFS='|' read -r name defs; do
    # shellcheck disable=SC2086
    (cd "$OUT/old" && 64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD $defs -l "$OUT/$name-old.lbl" -o "$OUT/$name-old.prg" sid303.asm)
    # shellcheck disable=SC2086
    64tass -I .. -C -a -q --cbm-prg -D BUILD=$BUILD $defs -l "$OUT/$name-new.lbl" -o "$OUT/$name-new.prg" sid303.asm
    if cmp -s "$OUT/$name-old.prg" "$OUT/$name-new.prg"; then
        echo "same     $name"
    elif [ -n "$ZP_REMAP" ] && result=$(python "$C64TOOLS/zp_remap_check.py" "$OUT/$name-old.prg" "$OUT/$name-old.lbl" "$OUT/$name-new.prg" "$OUT/$name-new.lbl"); then
        echo "remap    $name: $result"
    elif [ -n "$ROUTINES" ]; then
        rc=0
        result=$(python "$C64TOOLS/routine_compare.py" "$OUT/$name-old.prg" "$OUT/$name-old.lbl" "$OUT/$name-new.prg" "$OUT/$name-new.lbl") || rc=$?
        case $rc in
            0) echo "moved    $name: $result" ;;
            2) echo "REVIEW   $name: $result" ;;
            *) echo "CHANGED  $name: $result"; echo 1 > "$OUT/failed" ;;
        esac
    else
        echo "DIFFERS  $name"
        echo 1 > "$OUT/failed"
    fi
done
[ ! -f "$OUT/failed" ]
