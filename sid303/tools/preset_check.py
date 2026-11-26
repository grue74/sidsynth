# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the presets in VICE (src/presets.asm, docs/sequencer.md Presets).

    python tools/preset_check.py [--keep DIR]

Builds TEST_LOG test programs with TEST_PRESET_LOG (every recall logs the
slot, whether the sound was edited before, and the 15 values after it),
runs each in headless VICE (c64tools/vicepeek.py, through seq_check.py's
helpers) and reads memory. Then:

1. start: the 32 slots in PRESET_RAM are tables.py's presets() (values and
   names), slot 1 is the sound the synth starts with, slot 1 current, not
   edited.
2. program change (TEST_MIDI=7): Volume set, then a program change to
   every slot with a Cutoff controller between (to 2, a value no preset
   has), then to 40 and 127.
   Every slot is recalled once, in order, with exactly its values but Tune
   and Volume (kept); each recall after the first finds the sound edited;
   40 and 127 recall nothing.
3. keys (TEST_KEYS=16): C= + F3 / F4 step through the slots; the store
   prompt stores the sound into another slot under a typed name (SHIFT for
   a capital); a note key held when the prompt opens ends when let go in
   it; a key pressed in the prompt and let go after it closed plays
   nothing.
4. bank (TEST_KEYS=17..19, from a .d64): a bank saved, a slot changed, the
   bank loaded back; the song file's name kept apart; a bank file loaded as
   a song and the program loaded as a bank are refused, nothing changed.
5. load (TEST_MIDI=8): pattern 1 on the step screen while program
   changes alternate between Hard scream and Fuller bass every 40 ticks
   with a controller on every other tick: notes play, at most one tick
   waiting.

Exit status 0 when every check passes.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import tables  # noqa: E402
import seq_check  # noqa: E402  (build, labels, run_mems, run_log, note_ons, lags)
from seq_check import build, labels, run_mems, run_log, note_ons, lags  # noqa: E402

C64TOOLS = seq_check.C64TOOLS
NP, PB, NL = tables.NUM_PRESETS, len(tables.PRESET_ORDER), tables.PRESET_NAME_LEN
NOT_RECALLED = {tables.PRESET_ORDER.index(k) for k in ("TUNE", "VOLUME")}
PRESET_LOG = 0x7000                     # src/presets.asm (UNDO_RAM)
STEPS_MSG, DISK_NAME = 0xC800, 0xC600


def screen(text):
    """A name as the program keeps it: screen codes, small letters $01..$1A,
    capitals $41..$5A, the rest as ASCII; padded to NL."""
    out = []
    for c in text.ljust(NL):
        if "a" <= c <= "z":
            out.append(ord(c) - 0x60)
        else:
            out.append(ord(c))
    return out


def text_of(codes):
    return "".join(chr(c + 0x60) if 1 <= c <= 26 else chr(c) if 0x20 <= c < 0x60 else "?"
                   for c in codes)


def slots(mem, lab):
    """[(values, name codes)] of the 32 slots in PRESET_RAM."""
    ram, names = lab["PRESET_RAM"], lab["PRESET_NAMES"]
    return [([mem[ram + i * PB + j] for j in range(PB)],
             [mem[names + i * NL + j] for j in range(NL)]) for i in range(NP)]


def preset_log(mem, count=40):
    """The recall log: [(slot, edited before, values)] until an empty entry."""
    out = []
    for i in range(count):
        a = PRESET_LOG + i * (PB + 1)
        e = [mem[a + j] for j in range(PB + 1)]
        if not any(e):
            break
        out.append((e[0] & 0x7f, bool(e[0] & 0x80), e[1:]))
    return out


def msg_of(mem):
    return "".join(chr(b) if 0x20 <= b < 0x60 else "?" for b in
                   (mem[STEPS_MSG + i] for i in range(40))).rstrip()


def report(ok, label, detail):
    print(f"{'PASS' if ok else 'FAIL'} {label}: {detail}")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="keep the test programs in this folder")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="presetcheck")
    os.makedirs(work, exist_ok=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    factory = [(v, screen(n)) for n, v in tables.presets()]
    ok = True

    def regions(lab, extra=()):
        return [(0x0000, 0x00ff), (lab["params"], lab["params"] + 40),
                (lab["PRESET_RAM"], lab["PRESET_END"] - 1), (PRESET_LOG, PRESET_LOG + 0x500),
                (DISK_NAME, DISK_NAME + 0x20), (STEPS_MSG, STEPS_MSG + 0xc0), *extra]

    # 1. start
    prg = os.path.join(work, "start.prg")
    build(prg, ["TEST_PRESET_LOG=1"])
    lab = labels(prg)
    mem = run_mems(prg, 4, regions(lab))
    got = slots(mem, lab)
    params = [mem[lab["params"] + j] for j in range(PB)]
    start = [tables.START_SOUND[k] for k in tables.PRESET_ORDER]
    good = got == factory and params == start == factory[0][0] \
        and mem[lab["preset_cur"]] == 0 and mem[lab["preset_edited"]] == 0
    bad = [i + 1 for i in range(NP) if got[i] != factory[i]]
    ok &= report(good, "start", f"32 slots as tables.py (wrong: {bad or 'none'}), the start sound "
                 f"= slot 1 = START_SOUND: {params == start == factory[0][0]}, slot "
                 f"{mem[lab['preset_cur']] + 1} current, edited {mem[lab['preset_edited']]}")

    # 2. program change
    prg = os.path.join(work, "program.prg")
    build(prg, ["TEST_PRESET_LOG=1", "TEST_MIDI=7"])
    lab = labels(prg)
    mem = run_mems(prg, 30, regions(lab))
    log = preset_log(mem)
    vol_i = tables.PRESET_ORDER.index("VOLUME")
    errors = []
    for i, (slot, edited, values) in enumerate(log[:NP]):
        want = list(factory[i][0])
        want[vol_i] = tables.PRESET_TEST_VOLUME
        if slot != i or values != want or edited != (i > 0):
            errors.append((i, slot, edited, [(tables.PRESET_ORDER[j], values[j], want[j])
                                             for j in range(PB) if values[j] != want[j]]))
    # the feed starts again after its end: the next recall is slot 1's
    # (programs 40 and 127 recalled nothing in between)
    good = len(log) >= NP and not errors and (len(log) == NP or log[NP][0] == 0)
    ok &= report(good, "program change (TEST_MIDI=7)",
                 f"{min(len(log), NP)} recalls in order, then {'the feed again' if len(log) > NP else 'none'} "
                 f"(programs 40 and 127 ignored), each its slot's values with Volume "
                 f"{tables.PRESET_TEST_VOLUME} kept, edited before each but "
                 f"the first; errors: {errors[:3] or 'none'}")

    # 3. keys
    prg = os.path.join(work, "keys16.prg")
    build(prg, ["TEST_PRESET_LOG=1", "TEST_KEYS=16"])
    lab = labels(prg)
    mem = run_mems(prg, 10, regions(lab))
    notes = run_log(prg, 10)
    got = slots(mem, lab)
    recalls = [s for s, _, _ in preset_log(mem)]
    st = {"recalls": recalls, "current": mem[lab["preset_cur"]], "edited": mem[lab["preset_edited"]],
          "prompt": mem[lab["preset_mode"]], "slot 4 = slot 3's values": got[3][0] == factory[2][0],
          "slot 4's name": text_of(got[3][1]).rstrip(), "others unchanged":
          all(got[i] == factory[i] for i in range(NP) if i != 3),
          "notes": [(n, v) for _, n, v in notes]}
    want = {"recalls": [1, 2, 3, 2], "current": 3, "edited": 0, "prompt": 0,
            "slot 4 = slot 3's values": True, "slot 4's name": "Abc", "others unchanged": True,
            "notes": [(36, 80), (36, 0), (38, 80), (38, 0)]}
    good = st == want
    ok &= report(good, "keys (TEST_KEYS=16)", st if good else f"{st}\n     want {want}")

    # 4. bank, from a .d64 with the program as "SID303"
    d64tool = os.path.join(C64TOOLS, "d64.py")

    def disk_run(n):
        prg = os.path.join(work, f"keys{n}.prg")
        build(prg, ["TEST_PRESET_LOG=1", f"TEST_KEYS={n}"])
        img = os.path.join(work, f"keys{n}.d64")
        subprocess.run([sys.executable, d64tool, "--name", "SID303", "--id", "03", img,
                        f"{prg}=SID303"], check=True, capture_output=True)
        lab = labels(prg)
        return lab, run_mems(img, 40, regions(lab))

    lab, mem = disk_run(17)
    got = slots(mem, lab)
    name_len = mem[DISK_NAME + 16]
    st = {"slot 1": text_of(got[0][1]).rstrip(), "all as saved": got == factory,
          "edited": mem[lab["preset_edited"]], "message": msg_of(mem),
          "song name": "".join(chr(mem[DISK_NAME + i]) for i in range(name_len)).lower()}
    want = {"slot 1": "Classic acid", "all as saved": True, "edited": 1, "message": "00, OK,00,00",
            "song name": "song"}
    ok &= report(st == want, "bank round trip (TEST_KEYS=17)", st if st == want else f"{st}\n     want {want}")

    for n, want_msg, want_err in ((18, "NOT A SID303 FILE", 2), (19, "NOT A SID303 BANK", 4)):
        lab, mem = disk_run(n)
        same = slots(mem, lab) == factory and mem[lab["seq_bpm"]] == 125
        good = msg_of(mem) == want_msg and mem[lab["disk_error"]] == want_err and same
        ok &= report(good, f"refused (TEST_KEYS={n})", f"\"{msg_of(mem)}\", disk_error "
                     f"{mem[lab['disk_error']]}, presets and tempo unchanged: {same}")

    # 5. load
    prg = os.path.join(work, "heavy.prg")
    build(prg, ["TEST_PRESET_LOG=1", "TEST_SEQ=1", "TEST_MIDI=8", "TEST_KEYS=4"])
    heavy = run_log(prg, 12)
    good = len(note_ons(heavy)) > 100 and lags.get("heavy.prg", 99) <= 1
    ok &= report(good, "load (TEST_MIDI=8)", f"{len(note_ons(heavy))} notes played with a program "
                 f"change every 40 ticks and a controller every other tick, the step screen "
                 f"open: lag {lags.get('heavy.prg')} tick(s)")

    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
