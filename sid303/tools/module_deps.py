# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""List, per source module, the symbols it uses but does not define itself,
and which file defines them: the interface a module needs from the rest.

    python tools/module_deps.py [core/midi.asm ...]  (default: every module)
    python tools/module_deps.py --contract           (what core/ needs from the synth)

A rough 64tass parse: definitions are labels and constants at column 0
(locals starting with _ are ignored), uses are identifiers in the code
outside comments and strings. Good enough to plan a split, not a linker.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = (["sid303.asm", "tables.inc"]
         + sorted(glob.glob(os.path.join(os.path.dirname(ROOT), "core", "*.inc")))
         + sorted(glob.glob(os.path.join(os.path.dirname(ROOT), "core", "*.asm")))
         + sorted(glob.glob(os.path.join(ROOT, "src", "*.asm"))))
FILES = [os.path.relpath(os.path.join(ROOT, f), ROOT).replace("\\", "/") for f in FILES]

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DEF = re.compile(r"^([A-Za-z][A-Za-z0-9_]*)\b")
MNEMONICS = set("""adc and asl bcc bcs beq bit bmi bne bpl brk bvc bvs clc cld cli clv cmp
cpx cpy dec dex dey eor inc inx iny jmp jsr lda ldx ldy lsr nop ora pha php pla plp rol
ror rti rts sbc sec sed sei sta stx sty tax tay tsx txa txs tya a x y""".split())


def strip(line):
    """Code part of a line: no comment, no string or character literals."""
    line = re.sub(r'"[^"]*"', "", line)
    line = re.sub(r"'[^']*'", "", line)
    return line.split(";", 1)[0]


defs, uses = {}, {}
for f in FILES:
    path = os.path.join(ROOT, f)
    if not os.path.exists(path):
        continue
    used = set()
    for line in open(path, encoding="utf-8", errors="replace"):
        code = strip(line)
        m = DEF.match(code)
        if m:
            defs.setdefault(m.group(1), f)
            code = code[m.end():]
        for word in IDENT.findall(code):
            if word.lower() in MNEMONICS or word.startswith("_") or word.isdigit():
                continue
            used.add(word)
    uses[f] = used

if sys.argv[1:] == ["--contract"]:
    need = {}
    for f in FILES:
        if f.startswith("core/"):
            for word in uses.get(f, ()):
                where = defs.get(word)
                if where and not where.startswith("core/"):
                    need.setdefault(where, set()).add(word)
    for where in sorted(need):
        print(f"from {where}: {', '.join(sorted(need[where]))}")
    sys.exit(0)
targets = sys.argv[1:] or [f for f in FILES if f.startswith(("core/", "src/"))]
for f in targets:
    f = f.replace("\\", "/")
    need = {}
    for word in sorted(uses.get(f, ())):
        where = defs.get(word)
        if where and where != f:
            need.setdefault(where, []).append(word)
    print(f"{f} needs:")
    for where in sorted(need):
        print(f"  from {where}: {', '.join(need[where])}")
    print()
