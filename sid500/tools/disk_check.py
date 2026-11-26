"""disk_check.py - SID500 stage G: saving and loading a song, in VICE.

Builds the program and its disk overlay (src/disk.asm) with a test scene
(TEST_PLAY) and a key script, puts both on a .d64 ("sid500", "sid500
disk"), runs it in VICE (true drive emulation) and checks:

- the round trip (TEST_KEYS=19): C= W loads the overlay and saves "song"
  (the file "song.s5"), DEL empties a cell, C= L loads the song back: the
  song data, the parameters and every pattern's stream as a run that never
  used the disk (TEST_KEYS=20) left them; the pool whole (every block a
  pattern's or free, free_count right); the title shows the drive's
  "00, OK,00,00";
- the saved file, read from the disk image VICE left: its header, the
  parameters, Song on and the start scene, the song data's runs and each
  pattern's blocks as the run without the disk had them in memory;
- the code copied at start (low RAM, under the KERNAL) as the program's
  images after the disk was used: the KERNAL (and JiffyDOS) left it alone;
- a load that can't be (TEST_KEYS=22): no such file (the drive's "62, FILE
  NOT FOUND"), a file not a song ("NOT A SID500 SONG"), no overlay file or
  another build's ("NO SID500 DISK FILE"): the song unchanged; a file
  ended early ("FILE ENDED EARLY"), more blocks than the pool ("SONG TOO
  BIG"): an empty song, the pool whole;
- the directory (C= D, TEST_KEYS=24): of a disk with two songs and a file
  that isn't one, the songs' names (no ".s5") one a row, the cursor on the
  first, the title "DIRECTORY 8: 2 SONGS"; then (25) the cursor down and
  RETURN load the second, as the round trip's;
- the code at HI3_CODE (TEST_KEYS=26: the event list's, under the KERNAL
  where the overlay loads; kept in the note map meanwhile): after a save,
  the step grid opened and F3, as the program's image, the note map's
  pages empty again, the list shown;
- the note map after a save (TEST_KEYS=27): a save, then SPACE and SPACE
  (played: hi3_in from transport_go_start; stopped): HI3_CODE as the image,
  the note map's channels 4-15 (HI3_KEEP's pages and after) as the same
  play and stop without the save (28) left them.

    python tools/disk_check.py [--jiffy]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, C64TOOLS)
import vicetime  # noqa: E402  (find_vice)
sys.path.insert(0, os.path.join(ROOT, "tools"))
from record_check import decode  # noqa: E402  (a stream's events up to its end)
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

POOL_END = 0xC000
BLOCK, DATA = 32, 30
PAT_FIRST_LO, PAT_FIRST_HI, PAT_STEPS, PATTERNS = 0xC800, 0xC880, 0xC900, 128
RUNS = [(0xC900, 208), (0xCA00, 64), (0xCA80, 0xCF00 - 0xCA80)]   # disk.asm song_runs
SCREEN = 0x0400
SCENE = 2                       # the heavy test scene: many blocks
PLAYED = 1                      # the band (TEST_KEYS=27, 28: played; the heavy one is
                                # overload, its keys not read)
MIDI_ARGS = "-midi -miditype 2 -midiout -1 -midiin -1"   # (as edit_check.py's)
SAVED_PARAMS = 14               # every parameter but Disk drive


def build(out, keys, defines=(), scene=SCENE):
    """The program and its overlay, the same defines."""
    d = sum((["-D", x] for x in (f"TEST_KEYS={keys}", f"TEST_PLAY={scene}") + tuple(defines)), [])
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *d, "-l", out + ".lbl",
                    "-o", out, "sid500.asm"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *d, "-D", "DISK_OV_OUT=1",
                    "--output-section=disk_ov", "-o", out + ".disk", "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = {}
    for line in open(out + ".lbl"):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return lab


def disk(prg, img, overlay=True, extra=()):
    """A .d64: the program, its overlay (or another file as it), extra
    files [(path, name)]."""
    files = [f"{prg}=SID500"]
    if overlay:
        files.append(f"{prg if overlay is True else overlay}.disk=SID500 DISK"
                     if overlay is True else f"{overlay}=SID500 DISK")
    files += [f"{path}={name}" for path, name in extra]
    subprocess.run([sys.executable, os.path.join(C64TOOLS, "d64.py"), "--name", "SID500",
                    "--id", "01", img, *files], check=True, capture_output=True)


def run(img, ranges, seconds, jiffy, save=None, midi=False):
    """With midi: VICE's MIDI cartridge (a song played: without it the
    bytes never go, the player waits for the wire, the keys aren't read)."""
    cmds = [f"m {a:04x} {b:04x}" for a, b in ranges] + (["detach 8"] if save else [])
    args = [sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), img, *cmds,
            "--seconds", str(seconds)] + (["--jiffy"] if jiffy else []) \
        + (["--save-image", save] if save else []) \
        + ([f"--vice-args={MIDI_ARGS}"] if midi else [])
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            for i, b in enumerate(m.group(2).split()):
                mem[int(m.group(1), 16) + i] = int(b, 16)
    return mem


def word(mem, a):
    return mem[a] | mem[a + 1] << 8


def chain(mem, first, pool_start):
    blocks, data, seen = [], [], set()
    b = first
    while b:
        assert pool_start <= b < POOL_END and b % BLOCK == 0, f"bad link {b:04x}"
        assert b not in seen, f"a loop at {b:04x}"
        seen.add(b)
        blocks.append(b)
        data += [mem[b + i] for i in range(DATA)]
        b = word(mem, b + DATA)
    return blocks, data


def song(mem, lab):
    """What a song file holds, from memory: the parameters, Song on, the
    start scene, the runs, each pattern's blocks and events (the bytes after
    a stream's end are whatever the block held before)."""
    params = [mem[lab["params"] + i] for i in range(SAVED_PARAMS)]
    state = [mem[lab["song_on"]], mem[lab["start_scene"]]]
    runs = [[mem[a + i] for i in range(n)] for a, n in RUNS]
    pats = {}
    for p in range(PATTERNS):
        if mem[PAT_FIRST_HI + p]:
            data = chain(mem, mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8,
                         lab["POOL_START"])[1]
            pats[p] = (len(data) // DATA, decode(data))
    return params, state, runs, pats


def parse_file(data):
    """A song file's parts (disk.asm's format), or a reason it isn't one."""
    i = 2                                       # (the load address)
    if data[i:i + 6] != b"SID500" or data[i + 6] != 1:
        return f"header {data[2:9]!r}"
    i += 7
    n = data[i]
    params = list(data[i + 1:i + 1 + n])
    i += 1 + n
    state = list(data[i:i + 2])
    i += 2
    runs = []
    for _a, length in RUNS:
        runs.append(list(data[i:i + length]))
        i += length
    pats = {}
    while data[i] != 0xFF:
        p, blocks = data[i], data[i + 1] | data[i + 2] << 8
        i += 3
        pats[p] = (blocks, decode(list(data[i:i + blocks * DATA])))
        i += blocks * DATA
    if i + 1 != len(data):
        return f"{len(data) - i - 1} bytes after the end"
    return params, state, runs, pats


def check_pool(mem, lab, errors):
    owner = {}
    used = 0
    for p in range(PATTERNS):
        if not mem[PAT_FIRST_HI + p]:
            if mem[PAT_STEPS + p]:
                errors.append(f"pattern {p}: steps {mem[PAT_STEPS + p]} without blocks")
            continue
        if not 1 <= mem[PAT_STEPS + p] <= 128:
            errors.append(f"pattern {p}: steps {mem[PAT_STEPS + p]}")
        blocks, _ = chain(mem, mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8,
                          lab["POOL_START"])
        used += len(blocks)
        for b in blocks:
            if b in owner:
                errors.append(f"block {b:04x} in pattern {p} and {owner[b]}")
            owner[b] = f"pattern {p}"
    free, _ = chain(mem, word(mem, lab["free_head"]), lab["POOL_START"])
    for b in free:
        if b in owner:
            errors.append(f"free block {b:04x} is also {owner[b]}'s")
        owner[b] = "free"
    total = (POOL_END - lab["POOL_START"]) // BLOCK
    count = word(mem, lab["free_count"])
    if len(owner) != total:
        errors.append(f"{total - len(owner)} blocks lost")
    if count != len(free) or count != total - used:
        errors.append(f"free_count {count}, the free list {len(free)}, expected {total - used}")
    return used, count


def screen_row(mem, row):
    out = ""
    for i in range(40):
        c = mem[SCREEN + row * 40 + i] & 0x7F
        out += chr(c + 0x40) if 1 <= c <= 26 else chr(c) if 32 <= c < 64 else \
            chr(c) if 0x41 <= c <= 0x5A else "?"
    return out.rstrip()


IMAGES = [("lo_image", "lo_image_end", "LO_CODE"), ("lo2_image", "lo2_image_end", "LO2_CODE"),
          ("lo3_image", "lo3_image_end", "LO3_CODE"), ("hi_image", "hi_image_end", "HI_CODE"),
          ("hi2_image", "hi2_image_end", "HI2_CODE")]


def image_ranges(lab):
    return [(lab[dest], lab[dest] + lab[end] - lab[start] - 1) for start, end, dest in IMAGES]


def check_images(prg, lab, mem):
    """The code copied at start as the program file has it: [(name, the
    first byte that differs)]."""
    data = open(prg, "rb").read()
    load = data[0] | data[1] << 8
    bad = []
    for start, end, dest in IMAGES:
        for i in range(lab[end] - lab[start]):
            if lab[dest] + i == lab.get("disk_acia"):
                continue                        # (disk_in's: the interface's register)
            if mem[lab[dest] + i] != data[2 + lab[start] - load + i]:
                bad.append(f"{dest} +{i}")
                break
    return bad


def hi3_differs(mem, at, image):
    """HI3_CODE in memory not as its image, but the operands the code
    changes itself (jsr $ffff in the image: list.asm list_io's _call)."""
    changed = {i + k for i in range(len(image) - 2)
               if image[i:i + 3] == bytes((0x20, 0xFF, 0xFF)) for k in (1, 2)}
    return any(mem[at + i] != b for i, b in enumerate(image) if i not in changed)


def empty_song(mem, lab, errors):
    """No pattern, every block free."""
    if any(mem[PAT_FIRST_HI + p] or mem[PAT_STEPS + p] for p in range(PATTERNS)):
        errors.append("patterns left")
    used, free = check_pool(mem, lab, errors)
    if used:
        errors.append(f"{used} blocks used")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jiffy", action="store_true", help="the drive and the C64 with JiffyDOS")
    a = ap.parse_args()
    work = os.path.join(ROOT, "work", "disk")
    os.makedirs(work, exist_ok=True)
    tmp = tempfile.mkdtemp()
    ok = True
    try:
        # the song as the test scene made it (no disk)
        prg = os.path.join(work, "keys20.prg")
        lab = build(prg, 20)
        img = os.path.join(tmp, "keys20.d64")
        disk(prg, img)
        ranges = [(0x0002, 0x00FF), (0xC800, 0xCFFF), (lab["POOL_START"], POOL_END - 1),
                  (SCREEN, SCREEN + 39)]
        base = run(img, ranges, 15, a.jiffy)
        want = song(base, lab)

        # the round trip
        prg = os.path.join(work, "keys19.prg")
        lab19 = build(prg, 19)
        img = os.path.join(tmp, "keys19.d64")
        disk(prg, img)
        saved = os.path.join(work, "keys19-after.d64")
        mem = run(img, ranges + image_ranges(lab19), 60, a.jiffy, save=saved)
        errors = []
        got = song(mem, lab19)
        for name, w, g in zip(("parameters", "Song on and start", "song data", "patterns"),
                              want, got):
            if w != g:
                errors.append(f"{name} differ after the load")
        used, free = check_pool(mem, lab19, errors)
        title = screen_row(mem, 0)
        if title != "00, OK,00,00":
            errors.append(f"the title: {title!r}")
        good = not errors
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} round trip{' (JiffyDOS)' if a.jiffy else ''}: "
              f"{len(want[3])} patterns ({used} blocks, {free} free), the song data and "
              f"parameters as before the save; title {title!r}")
        for e in errors[:10]:
            print("   ", e)

        # the file on the disk
        vice = os.path.dirname(vicetime.find_vice())
        c1541 = os.path.join(vice, "c1541.exe" if os.name == "nt" else "c1541")
        out = os.path.join(tmp, "song.prg")
        subprocess.run([c1541, saved, "-read", "song.s5", out], check=True, capture_output=True)
        data = open(out, "rb").read()
        f = parse_file(data)
        good = not isinstance(f, str) and f == tuple(want)
        ok &= good
        detail = f if isinstance(f, str) else \
            ", ".join(n for n, w, g in zip(("parameters", "state", "runs", "patterns"), want, f)
                      if w != g) or "all as in memory"
        print(f"{'PASS' if good else 'FAIL'} the file song.s5: {len(data)} bytes, {detail}")
        bad = check_images(prg, lab19, mem)
        ok &= not bad
        print(f"{'PASS' if not bad else 'FAIL'} the code copied at start (low RAM, under the "
              f"KERNAL) unchanged after the disk was used{': ' + ', '.join(bad) if bad else ''}")

        # loads that can't be (TEST_KEYS=22)
        prg22 = os.path.join(work, "keys22.prg")
        lab22 = build(prg22, 22)
        prg23 = os.path.join(work, "keys23.prg")      # (C= L only: no overlay to load)
        lab23 = build(prg23, 23)
        other = os.path.join(work, "other.prg")
        build(other, 23, ["BUILD=1"])               # (another build's overlay)
        notsong = os.path.join(tmp, "notsong.prg")
        open(notsong, "wb").write(open(prg22 + ".disk", "rb").read())
        short = os.path.join(tmp, "short.prg")
        open(short, "wb").write(data[:len(data) // 2])
        big = os.path.join(tmp, "big.prg")
        head = data[:2 + 7 + 1 + SAVED_PARAMS + 2 + sum(n for _a, n in RUNS)]
        blocks = (POOL_END - lab22["POOL_START"]) // BLOCK + 1
        open(big, "wb").write(head + bytes([0, blocks & 255, blocks >> 8])
                              + bytes([0xFF]) * (blocks * DATA) + bytes([0xFF]))
        cases = [("no such file", 22, {}, "62, FILE NOT FOUND,00,00", "same"),
                 ("not a song", 22, {"extra": [(notsong, "SONG.S5")]}, "NOT A SID500 SONG",
                  "same"),
                 ("no overlay file", 23, {"overlay": False, "extra": [(short, "SONG.S5")]},
                  "NO SID500 DISK FILE", "same"),
                 ("another build's overlay", 23, {"overlay": other + ".disk",
                                                  "extra": [(short, "SONG.S5")]},
                  "NO SID500 DISK FILE", "same"),
                 ("ended early", 22, {"extra": [(short, "SONG.S5")]}, "FILE ENDED EARLY",
                  "empty"),
                 ("too big", 22, {"extra": [(big, "SONG.S5")]}, "SONG TOO BIG", "empty")]
        for name, keys, kw, msg, after in cases:
            prgk, labk = (prg22, lab22) if keys == 22 else (prg23, lab23)
            img = os.path.join(tmp, "case.d64")
            disk(prgk, img, **kw)
            mem = run(img, ranges, 60, a.jiffy)
            errors = []
            title = screen_row(mem, 0)
            if title != msg:
                errors.append(f"the title {title!r}")
            if after == "same":
                if song(mem, labk) != want:
                    errors.append("the song changed")
                check_pool(mem, labk, errors)
            else:
                empty_song(mem, labk, errors)
            good = not errors
            ok &= good
            print(f"{'PASS' if good else 'FAIL'} load, {name}: {msg!r}, the song "
                  f"{'unchanged' if after == 'same' else 'empty, the pool whole'}"
                  f"{': ' + '; '.join(errors) if errors else ''}")

        # the directory
        rows = {}
        for keys in (24, 25):
            prgk = os.path.join(work, f"keys{keys}.prg")
            labk = build(prgk, keys)
            img = os.path.join(tmp, "dir.d64")
            disk(prgk, img, extra=[(short, "FIRST.S5"), (notsong, "OTHER"),
                                   (out, "SONG.S5")])
            rows[keys] = (labk, run(img, ranges + [(SCREEN, SCREEN + 999), (0xD800, 0xD800 + 999)], 60, a.jiffy))
        labk, mem = rows[24]
        shown = [screen_row(mem, r) for r in range(5)]
        want_rows = ["DIRECTORY 8: 2 SONGS", "", "", "> FIRST", "  SONG"]
        white = [mem[0xD800 + r * 40 + 2] & 15 for r in (3, 4)] == [1, 12]   # (the cursor's)
        good = shown == want_rows and white and screen_row(mem, 5) == ""
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} the directory: {shown}, the cursor's name white, "
              f"the other grey: {white}")
        labk, mem = rows[25]
        errors = []
        if song(mem, labk) != want:
            errors.append("not the song loaded")
        check_pool(mem, labk, errors)
        title = screen_row(mem, 0)
        if title != "00, OK,00,00":
            errors.append(f"the title {title!r}")
        good = not errors
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} the directory's second song loaded by the cursor and "
              f"RETURN{': ' + '; '.join(errors) if errors else ''}")

        # the code at HI3_CODE put back (TEST_KEYS=26)
        prgk = os.path.join(work, "keys26.prg")
        labk = build(prgk, 26)
        img = os.path.join(tmp, "keys26.d64")
        disk(prgk, img)
        hi3 = labk["HI3_CODE"]
        keep = labk["HI3_KEEP"]
        mem = run(img, [(hi3, hi3 + 0x3FF), (keep, keep + 0x3FF), (SCREEN, SCREEN + 999)],
                  60, a.jiffy)
        data = open(prgk, "rb").read()
        load = data[0] | data[1] << 8
        n = labk["hi3_image_end"] - labk["hi3_image"]
        errors = []
        if hi3_differs(mem, hi3, data[2 + labk["hi3_image"] - load:][:n]):
            errors.append("HI3_CODE not as the program's image")
        if any(mem[keep + i] != 0xFF for i in range(0x400)):
            errors.append("the note map's pages not empty (NO_ENTRY)")
        rows = [screen_row(mem, r) for r in range(25)]
        if not any(r.startswith("POSITION EVENT") for r in rows):
            errors.append("the event list not shown")
        good = not errors
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} the code at HI3_CODE ({n} bytes) put back after a "
              f"save, the step grid and the event list opened{': ' + '; '.join(errors) if errors else ''}")

        # played after a save (TEST_KEYS=27), against played without one (28)
        got = {}
        for keys in (27, 28):
            prgk = os.path.join(work, f"keys{keys}.prg")
            labk = build(prgk, keys, scene=PLAYED)
            img = os.path.join(tmp, f"keys{keys}.d64")
            disk(prgk, img)
            note = labk["NOTE_ENTRY"]
            got[keys] = (labk, prgk, run(img, [(note, note + 0x7FF), (hi3, hi3 + 0x3FF),
                                               (labk["play_state"], labk["play_state"]),
                                               (labk["ren_tick"], labk["ren_tick"] + 2),
                                               (labk["hi3_out"], labk["hi3_out"])], 60, a.jiffy,
                                     midi=True))
        errors = []
        labk, prgk, mem = got[27]
        note = labk["NOTE_ENTRY"]
        data = open(prgk, "rb").read()
        load = data[0] | data[1] << 8
        if hi3_differs(mem, hi3, data[2 + labk["hi3_image"] - load:][:n]):
            errors.append("HI3_CODE not as the program's image")
        if mem[labk["hi3_out"]]:
            errors.append("hi3_out still set")
        for keys, (lk, _, m) in got.items():
            if m[lk["play_state"]]:
                errors.append(f"run {keys}: not stopped (play_state {m[lk['play_state']]})")
            if not any(m[lk["ren_tick"] + i] for i in range(3)):
                errors.append(f"run {keys}: nothing played")
        diff = [i for i in range(0x200, 0x800) if mem[note + i] != got[28][2][note + i]]
        if diff:
            errors.append(f"the note map's channels 4-15 not as without the save: {len(diff)} "
                          f"bytes, first at {note + diff[0]:04x}")
        good = not errors
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} played and stopped after a save: HI3_CODE as the "
              f"image, the note map as without the save{': ' + '; '.join(errors) if errors else ''}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
