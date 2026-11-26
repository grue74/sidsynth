"""Check SID808's SysEx dump in VICE (src/dumps.asm, core/sysex.asm).

    python tools/dump_check.py [--keep DIR]

SID808's song file is 13.5 KB: a test feed of it wouldn't fit in memory
beside the program, the patterns and the staging area. So these tests use
TEST_SYSEX=4: what the synth sends comes back into its own MIDI in, and it
takes its own dump (the core's sender, receiver and the staging under the
I/O chips, SYSEX_UNDER_IO, all at once). The staged file ($C800 on) and
memory are read with the monitor on RAM. The message format itself is
checked byte for byte by SID101's and SID303's tools/dump_check.py.

1. by key (TEST_KEYS=21): the song saved to disk as "t1", then D. The
   dump comes back and loads ("SYSEX: SONG LOADED"), and the staged file
   equals "t1" on the disk, byte for byte.
2. file versions (TEST_KEYS=22, D; TEST_DUMP_VERSION makes the dump say
   another version and hold what it holds), the knobs set away from their
   defaults first (TEST_TONE, TEST_TUNE, TEST_DECAY):
   - version 3: every knob as it was
   - version 2: Tone back at its defaults, the other knobs as they were
   - version 1: every knob at its defaults
   - version 4 (later than this program): "SYSEX: NOT A SID808 FILE",
     every knob as it was
3. while the sequencer plays (TEST_SEQ): it stops, the dump loads.

Exit status 0 when every check passes.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "core"))
import sysex  # noqa: E402  (core/sysex.py: the PC tool)

SYSEX_RAM = 0xC800                      # sid808.asm
FILE_LEN = 13570                        # src/dumps.asm SONG_FILE_V3


def build(out, defines):
    """Assemble sid808.asm with -D options into out (labels into out.lbl)."""
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg"]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", out + ".lbl", "-o", out, "sid808.asm"], cwd=ROOT, check=True)


def labels(prg):
    """The program's labels: name -> address (64tass -l)."""
    out = {}
    with open(prg + ".lbl") as f:
        for line in f:
            m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
            if m:
                v = m.group(2)
                out[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return out


def run(img, seconds, ranges, save_image=None):
    """Run img (a .prg or .d64) in VICE; return {address: byte} for the
    ranges [(start, end inclusive)], read from RAM (under the I/O chips and
    the ROMs too); save_image: keep the disk image."""
    cmds = ["bank ram"] + [f"m {lo:04x} {hi:04x}" for lo, hi in ranges]
    extra = []
    if save_image:
        cmds.append("detach 8")
        extra = ["--save-image", save_image]
    out = subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicepeek.py"), img, *cmds,
                          "--seconds", str(seconds)] + extra,
                         capture_output=True, text=True, check=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            addr = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                mem[addr + i] = int(b, 16)
    return mem


def d64_file(path, name):
    """The bytes of file `name` (PETSCII capitals = ASCII) on a .d64."""
    with open(path, "rb") as f:
        img = f.read()

    def sector(t, s):
        spt = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
        return img[(sum(spt[:t - 1]) + s) * 256:][:256]
    t, s = 18, 1
    while t:
        d = sector(t, s)
        for e in range(8):
            ent = d[e * 32:e * 32 + 32]
            if ent[2] & 7 == 2 and ent[5:21].rstrip(b"\xa0") == name.encode():
                out, ft, fs = b"", ent[3], ent[4]
                while ft:
                    blk = sector(ft, fs)
                    ft, fs = blk[0], blk[1]
                    out += blk[2:] if ft else blk[2:fs + 1]
                return out
        t, s = d[0], d[1]
    raise FileNotFoundError(name)


def message(mem, lab):
    """The song row's message (disk_msg, screen codes) as text."""
    return "".join(chr(b) if 0x20 <= b < 0x60 else chr(b + 0x40) if 1 <= b <= 26 else "?"
                   for b in (mem[lab["disk_msg"] + i] for i in range(40))).rstrip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder (default: a temporary one)")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="dumpcheck")
    os.makedirs(work, exist_ok=True)
    ok = True

    def report(good, text):
        nonlocal ok
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} {text}")

    def knobs(mem, lab):
        """{name: [the 13 sounds' values]}"""
        n = lab["NUM_SOUNDS"]
        return {k: [mem[lab["knob_" + k] + i] for i in range(n)] for k in ("level", "tune", "decay", "tone")}

    # 1: by key, against the disk file
    prg = os.path.join(work, "keys21.prg")
    build(prg, ["TEST_KEYS=21", "TEST_SYSEX=4"])
    lab = labels(prg)
    img = os.path.join(work, "keys21.d64")
    subprocess.run([sys.executable, os.path.join(C64TOOLS, "d64.py"), "--name", "SID808", "--id", "08",
                    img, f"{prg}=SID808"], check=True, capture_output=True)
    after = os.path.join(work, "keys21-after.d64")
    msg_range = (lab["disk_msg"], lab["disk_msg"] + 39)
    knob_range = (lab["knob_level"], lab["KNOBS_END"] - 1)
    mem = run(img, 60, [(SYSEX_RAM, SYSEX_RAM + FILE_LEN - 1), msg_range, knob_range], save_image=after)
    disk = d64_file(after, "T1")
    staged = bytes(mem[SYSEX_RAM + i] for i in range(FILE_LEN))
    sysex.identify(disk)                                # (a SID808 file)
    defaults = knobs(mem, lab)
    report(staged == disk and message(mem, lab) == "SYSEX: SONG LOADED",
           f"by D (TEST_KEYS=21), its own dump back in: the staged file equals \"T1\" on the disk "
           f"({len(disk)} bytes): {staged == disk}, \"{message(mem, lab)}\"")

    # 2: file versions, the knobs away from their defaults first
    away = ["TEST_TONE=15", "TEST_TUNE=24", "TEST_DECAY=0"]
    prg = os.path.join(work, "away.prg")
    build(prg, away)
    lab = labels(prg)
    start = knobs(run(prg, 6, [knob_range]), lab)       # (no dump: the knobs as set)
    for version, want_msg in ((3, "SYSEX: SONG LOADED"), (2, "SYSEX: SONG LOADED"),
                              (1, "SYSEX: SONG LOADED"), (4, "SYSEX: NOT A SID808 FILE")):
        prg = os.path.join(work, f"v{version}.prg")
        build(prg, ["TEST_KEYS=22", "TEST_SYSEX=4"] + away
              + ([] if version == 3 else [f"TEST_DUMP_VERSION={version}"]))
        lab = labels(prg)
        mem = run(prg, 20, [msg_range, knob_range])
        now = knobs(mem, lab)
        if version == 2:
            want = dict(start, tone=defaults["tone"])
        elif version == 1:
            want = defaults
        else:
            want = start
        report(now == want and message(mem, lab) == want_msg,
               f"version {version}: \"{message(mem, lab)}\", the knobs "
               f"{'as they were' if want is start else 'Tone at its defaults' if version == 2 else 'at their defaults'}: "
               f"{now == want}")

    # 3: while the sequencer plays
    prg = os.path.join(work, "playing.prg")
    build(prg, ["TEST_KEYS=22", "TEST_SYSEX=4", "TEST_SEQ=1"])
    lab = labels(prg)
    mem = run(prg, 20, [(0x0000, 0x00ff), msg_range])
    playing = mem[lab["seq_play"]]
    report(playing == 0 and message(mem, lab) == "SYSEX: SONG LOADED",
           f"while the sequencer plays: stopped: {playing == 0}, \"{message(mem, lab)}\"")

    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
