"""edit_check.py - SID500 stage C: editing on the step grid, in VICE.

Builds a TEST_KEYS=9 program (src/test_scripts.asm) playing the band
(TEST_PLAY=1), runs the script in VICE and checks the memory it leaves
against a model of the edits:

- the new pattern (scene 2's first cell, the first free number: no track
  plays it) published as encode() writes the model's events (notes, a
  rest, a chord of 4, DEL, a note replaced, one added from another column,
  the octave up and down; its length down to 4 and up to 7: the chord
  past the shortened end kept), 7 steps, its number in the cell;
- opened again after (decoded from the chain) and closed unedited: still
  that chain, not published again; the bass opened and closed unedited:
  its chain where test_play_load put it;
- the drums, which a track plays, edited while playing: published at once
  (edit_state clean, design 5 "Editing a playing pattern"), the drums'
  stream as encode() writes the edited table; the track switched to the
  new chain and the old one freed (no track or snapshot entry stale, the
  list of replaced chains empty); then the new pattern's cell opens (the
  table no longer waits) and is closed;
- step entry from MIDI in (TEST_KEYS=11, TEST_MIDI: src/test_scripts.asm's
  test_pattern): a new pattern holds a chord of three on step 1, a single
  note on step 2, a chord whose keys overlapped on step 3 (the entry
  velocity and length, not the keys'), the cursor on step 4;
- copy and clear (TEST_KEYS=12): the bass, playing, copied (C= C) to the
  first free number, the copy in its cell and played by its track, the
  original unchanged; the copy's first note replaced, then CLR, undone,
  redone and undone (the copy as edited), step 3's note DEL'd (the steps'
  index found again); the many notes (96 events, more
  than a CLR keeps for undo): CLR asks, HOME cancels it; the copy, cut to
  94 (DEL), asks too; at 93 cleared at once and undone (the copy: the many
  notes but step 1's first three); the original (the cell put back to
  it) cleared by two CLRs, C= U then changing nothing; HOME leaves the
  cursor on step 1; the cell back to the copy, played;
- editing in the event list (TEST_KEYS=17): the pad, playing, edited by
  fields, DEL, INST, undone and redone: its stream as encode()'s of the
  model's events;
- the pool whole: every block a pattern's or free, none in two chains,
  free_count the free list's length and what the patterns' streams leave
  (a leak or a block freed twice would show).

    python tools/edit_check.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, ROOT)
import tables  # noqa: E402
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

POOL_END = 0xC000               # src/pool.asm (no TEST_LOG; POOL_START from the labels:
                                # a test build's program can run past $6000)
BLOCK, DATA = 32, 30
PAT_FIRST_LO, PAT_FIRST_HI, PAT_STEPS, PATTERNS = 0xC800, 0xC880, 0xC900, 128
SCENES = 0xCB00
GRID_TABLE = 0xE000
MIDI_ARGS = "-midi -miditype 2 -midiout -1 -midiin -1"   # Datel (as flash_check.py: the
                                                         # player waits for the interface)
NEW = 8                         # the first number scene 1 (patterns 0-7) leaves free
DRUMS, BASS = 0, 1
Z_KEY = 36                      # the Z key's note at the start (C2)
NEW_STEPS = 6                   # 16, then - to 4 (the chord on step 6 kept), + to 7,
                                # the last + undone
PLAY_PATTERN, PLAY_STALE = 0xCA50, 0xCA60   # src/player.asm
SNAPSHOT, SNAP_SIZE, SNAP_PLAY, SNAP_STALE = 0xFD10, 288, 256, 272
SNAP_END = SNAPSHOT + 2 * SNAP_SIZE


def drums_edited(drums):
    """The drums after the script's edit: step 1's first note (the kick)
    replaced in place by Z (C2, the entry velocity and length: as last set,
    103 and 2 steps)."""
    return [(0, "note", Z_KEY, ENTRY_VEL, ENTRY_LEN)] + drums[1:]


ENTRY_VEL, ENTRY_LEN = 103, 24  # the entry settings after the script's C= + and C= L
MANY = 7                        # the band's 96 long notes, step 1 quantized


def model_events():
    """The new pattern after the script's edits: (tick, "note", note, 100,
    12); step 4's note's velocity 102 and length 2 steps (C= + three times,
    one undone; C= L); all two semitones down (C= T, C= -, one undone and
    redone); step 5's F2 back (its DEL undone); Q's and W's edits undone
    and redone."""
    step = 12
    notes = [(0, Z_KEY),                    # step 1: Z
             (1, Z_KEY + 12),               # step 2: X (D2), replaced by Q (C3)
             (2, Z_KEY + 4), (2, Z_KEY + 14),   # step 3: C (E2), then W (D3) added
             (3, Z_KEY + 12),               # step 4: a rest, then Z an octave up
             (4, Z_KEY + 5),                # step 5: V (F2): DEL, undone
             (5, Z_KEY), (5, Z_KEY + 4), (5, Z_KEY + 7), (5, Z_KEY + 9)]  # step 6: SHIFT
    out = []
    for s, n in notes:
        vel, length = (ENTRY_VEL - 1, ENTRY_LEN) if (s, n) == (3, Z_KEY + 12) else (100, 12)
        out.append((s * step, "note", n - 2, vel, length))
    return out


def many_quantized(events):
    """The many notes' pattern after C= Q on step 1: its notes onto tick 0."""
    return [(0,) + e[1:] if e[1] == "note" and e[0] < 12 else e for e in events]


def run(prg, ranges, seconds):
    cmds = [f"m {a:04x} {b:04x}" for a, b in ranges]
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg, *cmds,
                          "--seconds", str(seconds), f"--vice-args={MIDI_ARGS}"],
                         capture_output=True, text=True, check=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            for i, b in enumerate(m.group(2).split()):
                mem[int(m.group(1), 16) + i] = int(b, 16)
    return mem


def word(mem, a):
    return mem[a] | mem[a + 1] << 8


def chain(mem, first):
    blocks, data, seen = [], [], set()
    b = first
    while b:
        assert POOL_START <= b < POOL_END and b % BLOCK == 0, f"bad link {b:04x}"
        assert b not in seen, f"a loop at {b:04x}"
        seen.add(b)
        blocks.append(b)
        data += [mem[b + i] for i in range(DATA)]
        b = word(mem, b + DATA)
    return blocks, data


MIDI_NOTES = [(0, 60), (0, 64), (0, 67), (12, 62), (24, 65), (24, 69), (24, 72)]


def labels(prg):
    lab = {}
    for line in open(prg + ".lbl"):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:                   # (hex, or decimal: a label from a computed address)
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return lab


def check_pool(mem, zp, used, errors, what=""):
    """Every block a pattern's or free, once; free_count the free list's
    length and the pool's blocks less the used ones."""
    owner = {}
    for p in range(PATTERNS):
        if not mem[PAT_STEPS + p]:
            continue
        blocks, _ = chain(mem, mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8)
        for blk in blocks:
            if blk in owner:
                errors.append(f"{what}block {blk:04x} in pattern {p} and {owner[blk]}")
            owner[blk] = f"pattern {p}"
    free_blocks, _ = chain(mem, word(mem, zp))
    for blk in free_blocks:
        if blk in owner:
            errors.append(f"{what}free block {blk:04x} is also {owner[blk]}'s")
        owner[blk] = "free"
    total = (POOL_END - POOL_START) // BLOCK
    free_count = word(mem, zp + 2)
    if len(owner) != total:
        errors.append(f"{what}{total - len(owner)} blocks lost (neither a pattern's nor free)")
    if len(free_blocks) != free_count or free_count != total - used:
        errors.append(f"{what}free_count {free_count}, the free list {len(free_blocks)}, "
                      f"expected {total - used}")
    return total, free_count


COPY_BASS, COPY_MANY = 8, 9     # the copies' numbers (the first free each time)


def check_copy_clear(errors):
    """Copy (C= C) and clear (CLR) on the step grid (TEST_KEYS=12)."""
    global POOL_START
    prg = os.path.join(ROOT, "edit-copy.prg")
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_KEYS=12",
                    "-D", "TEST_PLAY=1", "-l", prg + ".lbl", "-o", prg, "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = labels(prg)
    POOL_START = lab["POOL_START"]
    zp, gv, ev, rc = lab["free_head"], lab["song_mode"], lab["edit_state"], lab["retire_count"]
    cf = lab["grid_confirm"]
    try:
        mem = run(prg, [(zp, zp + 3), (PAT_FIRST_LO, PAT_STEPS + PATTERNS - 1),
                        (POOL_START, POOL_END - 1), (SCENES, SCENES + 31), (gv, gv + 31),
                        (ev, ev), (cf, cf + 1), (PLAY_PATTERN, PLAY_STALE + 15), (rc, rc),
                        (SNAPSHOT, SNAP_END - 1)], 20)   # (the script: ~16.3 s)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    w = "copy and clear: "
    patterns = tables.SCENES[1]()[0]
    bass = patterns[BASS][1]
    want = {p: (steps, events) for p, (steps, events) in patterns.items()}
    want[COPY_BASS] = (patterns[BASS][0], [(0, "note", Z_KEY, 100, 12)] + bass[2:])
    want[COPY_MANY] = (patterns[MANY][0], patterns[MANY][1][3:])   # (step 1's first 3)
    want[MANY] = (patterns[MANY][0], [])
    for p, (steps, events) in sorted(want.items()):
        if mem[PAT_STEPS + p] != steps:
            errors.append(f"{w}pattern {p} has {mem[PAT_STEPS + p]} steps, not {steps}")
            continue
        _, data = chain(mem, mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8)
        stream = tables.encode(events)
        if data[:len(stream)] != stream:
            errors.append(f"{w}pattern {p}'s stream {data[:len(stream)]} differs from "
                          f"encode()'s {stream}")
    for track, p in ((BASS, COPY_BASS), (MANY, COPY_MANY)):
        if mem[SCENES + track] != p:
            errors.append(f"{w}scene 1's track {track + 1} holds {mem[SCENES + track]}, "
                          f"not the copy {p}")
        if mem[PLAY_PATTERN + track] != p:
            errors.append(f"{w}track {track + 1} plays {mem[PLAY_PATTERN + track]}, "
                          f"not the copy {p}")
    g = {k: mem[gv + lab[k] - lab["song_mode"]] for k in
         ("song_mode", "grid_pattern", "grid_cursor")}
    if g["song_mode"] != 0:
        errors.append(f"{w}the step grid still shown")
    if g["grid_pattern"] != MANY:
        errors.append(f"{w}the edit table is pattern {g['grid_pattern']}'s, not the many "
                      f"notes' (the original opened last)")
    if g["grid_cursor"] != 0:
        errors.append(f"{w}HOME left the cursor on step {g['grid_cursor'] + 1}")
    if mem[cf]:
        errors.append(f"{w}a CLR still waits for its second")
    if mem[ev]:
        errors.append(f"{w}an edit not published (edit_state {mem[ev]})")
    if mem[cf + 1]:
        errors.append(f"{w}a copy still waits for its cell")
    stale = [t for t in range(16) if mem[PLAY_STALE + t]]
    if stale or mem[rc]:
        errors.append(f"{w}tracks still stale {stale}, {mem[rc]} replaced chains not freed")
    used = sum(tables.blocks_for(tables.encode(e)) for _, e in want.values())
    total, free = check_pool(mem, zp, used, errors, w)
    print(f"copy and clear: the bass and the many notes copied into their cells and played; "
          f"CLRs of 5 and 93 events undone, of 94 and 96 asked (cancelled, made); pool "
          f"{total} blocks, {free} free")


PAD = 2                         # the band's pad: a program change, controllers, a chord, bends
LIST_EVENTS = [(0, "program", 12), (0, "cc", 74, 20), (0, "note", 64, 80, 80),
               (0, "note", 67, 80, 80), (2, "note", 73, 67, 93), (17, "cc", 74, 62),
               (70, "bend", 0, 64), (70, "bend", 0, 65)]
                                # (the pad after TEST_KEYS=17's edits in the event list:
                                # src/test_scripts.asm)


def check_list(errors):
    """Editing in the event list (TEST_KEYS=17): the pad, playing, edited
    by fields (a note's pitch, velocity, length and position; a
    controller's position and value; a bend's value), DEL, INST, two undos
    and a redo; then published as the model's, heard, the pool whole."""
    global POOL_START
    prg = os.path.join(ROOT, "edit-list.prg")
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_KEYS=17",
                    "-D", "TEST_PLAY=1", "-l", prg + ".lbl", "-o", prg, "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = labels(prg)
    POOL_START = lab["POOL_START"]
    zp, gv, ev, rc = lab["free_head"], lab["song_mode"], lab["edit_state"], lab["retire_count"]
    try:
        mem = run(prg, [(zp, zp + 3), (PAT_FIRST_LO, PAT_STEPS + PATTERNS - 1),
                        (POOL_START, POOL_END - 1), (gv, gv + 31), (ev, ev),
                        (PLAY_PATTERN, PLAY_STALE + 15), (rc, rc)], 12)  # (the script ~7.5 s)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    w = "the event list: "
    patterns = tables.SCENES[1]()[0]
    want = {p: (steps, events) for p, (steps, events) in patterns.items()}
    want[PAD] = (patterns[PAD][0], LIST_EVENTS)
    for p, (steps, events) in sorted(want.items()):
        if mem[PAT_STEPS + p] != steps:
            errors.append(f"{w}pattern {p} has {mem[PAT_STEPS + p]} steps, not {steps}")
            continue
        _, data = chain(mem, mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8)
        stream = tables.encode(events)
        if data[:len(stream)] != stream:
            errors.append(f"{w}pattern {p}'s stream {data[:len(stream)]} differs from "
                          f"encode()'s {stream}")
    if mem[gv]:
        errors.append(f"{w}the step grid still shown")
    if mem[ev]:
        errors.append(f"{w}an edit not published (edit_state {mem[ev]})")
    stale = [t for t in range(16) if mem[PLAY_STALE + t]]
    if stale or mem[rc]:
        errors.append(f"{w}tracks still stale {stale}, {mem[rc]} replaced chains not freed")
    if mem[PLAY_PATTERN + 2] != PAD:
        errors.append(f"{w}track 3 plays {mem[PLAY_PATTERN + 2]}, not the pad")
    used = sum(tables.blocks_for(tables.encode(e)) for _, e in want.values())
    total, free = check_pool(mem, zp, used, errors, w)
    print(f"the event list: the pad's {len(LIST_EVENTS)} events as the model's after its "
          f"edits by field, DEL, INST, undo and redo, published while playing; pool {total} "
          f"blocks, {free} free")


def check_midi(errors):
    """Step entry from MIDI in (TEST_KEYS=11, TEST_MIDI)."""
    prg = os.path.join(ROOT, "edit-midi.prg")
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_KEYS=11",
                    "-D", "TEST_MIDI=1", "-l", prg + ".lbl", "-o", prg, "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = {}
    for line in open(prg + ".lbl"):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    gv, pool = lab["song_mode"], lab["POOL_START"]
    try:
        mem = run(prg, [(PAT_FIRST_LO, PAT_STEPS + PATTERNS - 1), (pool, POOL_END - 1),
                        (SCENES, SCENES + 31), (gv, gv + 31)], 9)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    first = mem[SCENES + 16]
    want = [(t, "note", n, 100, 12) for t, n in MIDI_NOTES]
    if first != 0:
        errors.append(f"step entry: scene 2's first cell holds {first}, not pattern 0")
        return
    if not mem[PAT_FIRST_HI]:
        errors.append("step entry: the new pattern wasn't published")
        return
    global POOL_START
    POOL_START = pool
    _, data = chain(mem, mem[PAT_FIRST_LO] | mem[PAT_FIRST_HI] << 8)
    stream = tables.encode(want)
    if data[:len(stream)] != stream:
        errors.append(f"step entry: the pattern's stream {data[:len(stream)]} differs from "
                      f"encode()'s {stream}")
    cursor = mem[gv + lab["grid_cursor"] - lab["song_mode"]]
    if cursor != 3:
        errors.append(f"step entry: the cursor on step {cursor + 1}, not 4")
    print(f"step entry from MIDI in: {len(want)} notes on 3 steps as the model's, the cursor "
          f"on step {cursor + 1}")


def main():
    prg = os.path.join(ROOT, "edit-test.prg")
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_KEYS=9",
                    "-D", "TEST_PLAY=1", "-l", prg + ".lbl", "-o", prg, "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = {}
    for line in open(prg + ".lbl"):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:                   # (hex, or decimal: a label from a computed address)
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    global POOL_START
    POOL_START = lab["POOL_START"]
    zp, gv, ev = lab["free_head"], lab["song_mode"], lab["edit_state"]
    rc = lab["retire_count"]
    try:
        mem = run(prg, [(zp, zp + 3), (PAT_FIRST_LO, PAT_STEPS + PATTERNS - 1),
                        (POOL_START, POOL_END - 1), (SCENES, SCENES + 31),
                        (gv, gv + 31), (ev, ev + 3), (GRID_TABLE, GRID_TABLE + 0x3ff),
                        (PLAY_PATTERN, PLAY_STALE + 15), (rc, rc), (SNAPSHOT, SNAP_END - 1)],
                  14)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    errors = []
    patterns = tables.SCENES[1]()[0]

    # where test_play_load put the scene's patterns: one after another
    first_at, b = {}, POOL_START
    for p, (steps, events) in sorted(patterns.items()):
        first_at[p] = b
        b += tables.blocks_for(tables.encode(events)) * BLOCK

    # the new pattern
    want = model_events()
    if mem[SCENES + 16] != NEW:
        errors.append(f"scene 2's first cell holds {mem[SCENES + 16]}, not {NEW}")
    if mem[PAT_STEPS + NEW] != NEW_STEPS:
        errors.append(f"the new pattern has {mem[PAT_STEPS + NEW]} steps, not {NEW_STEPS}")
    new_first = mem[PAT_FIRST_LO + NEW] | mem[PAT_FIRST_HI + NEW] << 8
    if os.environ.get("EDIT_DEBUG"):
        print("scenes 1-2:", [mem[SCENES + i] for i in range(32)])
        print("steps:", [mem[PAT_STEPS + i] for i in range(12)])
        print("grid:", [mem[gv + i] for i in range(32)], "edit:", [mem[ev + i] for i in range(4)])
    if not mem[PAT_FIRST_HI + NEW]:
        errors.append("the new pattern wasn't published")
    else:
        _, data = chain(mem, new_first)
        stream = tables.encode(want)
        if data[:len(stream)] != stream:
            errors.append(f"the new pattern's stream {data[:len(stream)]} differs from "
                          f"encode()'s {stream}")

    # the scene's patterns: where they were put, as written (the drums
    # edited: published again, elsewhere)
    drums = drums_edited(patterns[DRUMS][1])
    edited = {DRUMS: drums, MANY: many_quantized(patterns[MANY][1])}
    for p, (steps, events) in sorted(patterns.items()):
        first = mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8
        _, data = chain(mem, first)
        if p in edited:
            stream = tables.encode(edited[p])
            if data[:len(stream)] != stream:
                errors.append(f"pattern {p}'s stream {data[:len(stream)]} differs from "
                              f"encode()'s of the edited table {stream}")
            continue
        stream = tables.encode(events)
        if first != first_at[p] or data[:len(stream)] != stream:
            errors.append(f"pattern {p}: published again (at {first:04x}, "
                          f"loaded at {first_at[p]:04x}) or changed")

    # the drums' edit published and heard: nothing stale, nothing waiting
    g = {k: mem[gv + lab[k] - lab["song_mode"]] for k in
         ("song_mode", "grid_pattern", "grid_count", "grid_steps")}
    state = mem[ev]
    if state != 0:
        errors.append(f"the drums' edit not published (edit_state {state})")
    if g["song_mode"] != 0:
        errors.append("the step grid still shown (scene 2's pattern not closed)")
    if g["grid_pattern"] != NEW:
        errors.append(f"the edit table is pattern {g['grid_pattern']}'s, not the new one's "
                      f"(scene 2's cell not opened)")
    stale = [t for t in range(16) if mem[PLAY_STALE + t]]
    stale += [f"snapshot {s}: {t}" for s in (0, 1) for t in range(16)
              if mem[SNAPSHOT + s * SNAP_SIZE + SNAP_STALE + t]]
    if stale:
        errors.append(f"tracks still reading the drums' old chain: {stale}")
    if mem[PLAY_PATTERN + 0] != DRUMS:
        errors.append(f"track 1 plays pattern {mem[PLAY_PATTERN]}, not the drums")
    if mem[rc]:
        errors.append(f"{mem[rc]} replaced chains not freed")

    # the pool: every block somewhere, once
    used = sum(tables.blocks_for(tables.encode(edited.get(p, e)))
               for p, (_, e) in patterns.items()) + tables.blocks_for(tables.encode(want))
    total, free_count = check_pool(mem, zp, used, errors)

    check_midi(errors)
    check_copy_clear(errors)
    check_list(errors)
    print(f"the new pattern: {len(want)} notes as the model's; the scene's "
          f"{len(patterns) - 2} other patterns where loaded; the drums' edit and the many "
          f"notes' quantize published while playing, heard, the old chains freed; pool "
          f"{total} blocks, {free_count} free")
    for e in errors:
        print("   FAIL:", e)
    print("all passed" if not errors else "FAILED")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
