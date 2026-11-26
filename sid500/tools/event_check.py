"""event_check.py - SID500 stage A: the note pool and the event format in VICE.

Builds a TEST_EVENTS program (src/test_events.asm), runs it in VICE and
checks against tables.py's model (encode, test_patterns):

- every pattern's stream in the pool is exactly encode()'s bytes, in a
  chain of 32-byte blocks (30 bytes, then the link) from the pattern table,
  with its steps;
- the free list: free_count blocks, no block in two chains, every block
  either a pattern's or free; the replaced pattern's first blocks freed;
- filling the pool: the bytes written are exactly the free blocks * 30,
  and abandoning that stream frees them all again;
- reading every pattern back (ev_read_time, ev_read_event) gives each
  event at its tick with its data, a note with its velocity and length;
- encoding each pattern again from those records (src/edit.asm, the step
  grid's encoder) and publishing it: every pattern then in the pool as
  encode() writes it (the checks above are made after this), the free
  blocks as before.

    python tools/event_check.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, ROOT)
import tables  # noqa: E402  (the event model and the test patterns)
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

POOL_START, POOL_END = 0x6800, 0xA000   # src/pool.asm, TEST_EVENTS builds (POOL_START
                                        # from the labels: the program can run past it)
BLOCK, DATA = 32, 30
PAT_FIRST_LO, PAT_FIRST_HI, PAT_STEPS, PATTERNS = 0xC800, 0xC880, 0xC900, 128
EVENTS_OUT, RESULTS, DONE = 0xA000, 0xBF00, 0xA5   # src/test_events.asm
REC_END = 0xFE
TYPES = {0: "note", 1: "cc", 2: "bend", 3: "program"}


def labels(path):
    out = {}
    for line in open(path):
        m = re.match(r"(\w+)\s*=\s*\$([0-9a-fA-F]+)\s*$", line)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def run(prg, ranges, seconds=3):
    """Run prg in VICE; memory as {address: byte} for [(start, end)]."""
    cmds = [f"m {a:04x} {b:04x}" for a, b in ranges]
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), prg, *cmds,
                          "--seconds", str(seconds)],
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
    """A chain's blocks and its bytes (30 a block), as the program links them."""
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


def main():
    prg = os.path.join(ROOT, "event-test.prg")
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_EVENTS=1",
                    "-l", prg + ".lbl", "-o", prg, "sid500.asm"], cwd=ROOT, check=True)
    lab = labels(prg + ".lbl")
    global POOL_START
    POOL_START = lab["POOL_START"]
    zp = lab["free_head"]
    try:
        mem = run(prg, [(zp, zp + 3), (PAT_FIRST_LO, PAT_STEPS + PATTERNS - 1),
                        (POOL_START, POOL_END - 1), (EVENTS_OUT, RESULTS + 15)])
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    errors = []

    # the patterns as tables.py wrote them (the last of each number counts)
    expect = {}
    for pattern, steps, events in tables.test_patterns():
        expect[pattern] = (steps, events)
    if mem[RESULTS + 8] != DONE:
        print("FAIL: the test didn't finish")
        return 1
    if mem[RESULTS + 9] != len(expect):
        errors.append(f"{mem[RESULTS + 9]} patterns encoded again, not {len(expect)}")

    # 1. the pool: each pattern's chain holds exactly its stream
    owner = {}
    for p in range(PATTERNS):
        first = mem[PAT_FIRST_LO + p] | mem[PAT_FIRST_HI + p] << 8
        steps = mem[PAT_STEPS + p]
        if p not in expect:
            if steps or mem[PAT_FIRST_HI + p]:
                errors.append(f"pattern {p}: not written, yet steps {steps}, first {first:04x}")
            continue
        want_steps, events = expect[p]
        stream = tables.encode(events)
        blocks, data = chain(mem, first)
        if steps != want_steps:
            errors.append(f"pattern {p}: {steps} steps, not {want_steps}")
        if len(blocks) != tables.blocks_for(stream) or data[:len(stream)] != stream:
            errors.append(f"pattern {p}: the pool's stream differs from encode()")
        for b in blocks:
            if b in owner:
                errors.append(f"block {b:04x} in pattern {p} and {owner[b]}")
            owner[b] = f"pattern {p}"

    # 2. the free list: its length, nothing shared, every block somewhere
    free_blocks, _ = chain(mem, word(mem, zp))
    free_count = word(mem, zp + 2)
    for b in free_blocks:
        if b in owner:
            errors.append(f"free block {b:04x} is also {owner[b]}'s")
        owner[b] = "free"
    total = (POOL_END - POOL_START) // BLOCK
    if len(free_blocks) != free_count:
        errors.append(f"the free list has {len(free_blocks)} blocks, free_count {free_count}")
    if len(owner) != total:
        errors.append(f"{total - len(owner)} blocks lost (neither a pattern's nor free)")
    used = sum(tables.blocks_for(tables.encode(ev)) for _, (_, ev) in expect.items())
    start, loaded, filled, after = (word(mem, RESULTS + i) for i in (0, 2, 4, 6))
    if start != total or loaded != total - used:
        errors.append(f"free blocks: {start} at start, {loaded} after the patterns "
                      f"(expected {total}, {total - used})")

    # 3. the fill: every free block's 30 bytes, then all free again
    if filled != loaded * DATA or after != loaded:
        errors.append(f"the fill wrote {filled} bytes (expected {loaded * DATA}), "
                      f"left {after} blocks free (expected {loaded})")

    # 4. reading back: each pattern's events, in order, at their ticks
    records = []
    a = EVENTS_OUT
    while a < RESULTS and len(records) < 4000:
        records.append([mem[a + i] for i in range(8)])
        a += 8
    i, events_read = 0, 0
    for p in sorted(expect):
        steps, events = expect[p]
        got = []
        while i < len(records) and records[i][2] != REC_END:
            r = records[i]
            tick, kind = r[0] | r[1] << 8, TYPES.get(r[2], "bad")
            if kind == "note":
                got.append((tick, kind, r[3], r[5], r[6] | r[7] << 8))
            elif kind == "program":
                got.append((tick, kind, r[3]))
            else:
                got.append((tick, kind, r[3], r[4]))
            i += 1
        if i >= len(records) or records[i][3] != p:
            errors.append(f"pattern {p}: its end record missing")
            break
        i += 1
        events_read += len(got)
        if got != [tuple(e) for e in events]:
            first = next((k for k, (x, y) in enumerate(zip(got, events)) if x != tuple(y)),
                         min(len(got), len(events)))
            errors.append(f"pattern {p}: event {first} read as "
                          f"{got[first] if first < len(got) else None}, "
                          f"written {events[first] if first < len(events) else None}")

    print(f"{len(expect)} patterns, {events_read} events read back and encoded again; "
          f"pool {total} blocks: {used} the patterns', {free_count} free; "
          f"the fill wrote {filled} bytes")
    for e in errors:
        print("   FAIL:", e)
    print("all passed" if not errors else "FAILED")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
