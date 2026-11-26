"""Check SID101's SysEx dumps in VICE (src/dumps.asm, core/sysex.asm).

    python tools/dump_check.py [--keep DIR]

Builds TEST_SYSEX programs, runs each in headless VICE (c64tools/vicepeek.py)
and reads what they sent (TEST_SYSEX capture: every SysEx byte sent, at
SYSEX_RAM) or what a dump fed in (TEST_SYSEX feed: test_sysex.bin, at
wire speed) left in memory. The messages are made and read with the PC
tool's own code (core/sysex.py).

1. song by key (TEST_KEYS=21): the song saved to disk as "t1", then C= + M.
   The dump equals the file on the disk, byte for byte. (A song file's
   unused song entries hold whatever RAM held: the checks below leave them
   out, or make them safe as load_check does.)
2. bank by key (TEST_KEYS=22): the same with the preset bank ("b1").
3. request: three requests fed in, on channel 2: for another synth, for
   device 5, for device 1 (channel 2). Only the last is answered, from
   device 1, with the same song file as 1. Then a request while the
   sequencer plays the heaviest sound with the step screen open and MIDI
   out off: it plays on, the dump (paced as the wire would take it) is the
   song file, no tick fell behind by more than one.
4. a song dump in: the patterns, song, tempo, swing and sound are the
   dump's, the song row says "SYSEX: SONG LOADED", no tick fell behind by
   more than one. Again while the sequencer plays the heaviest sound with
   the step screen open (TEST_MIDI=7, TEST_KEYS=4): it stops, the same
   (but the sound: TEST_MIDI=7's controllers come again after the load).
5. a bank dump in: the presets are the dump's, "SYSEX: BANK LOADED".
6. a song dump with a wrong sum: "SYSEX: BAD DATA", nothing changed. The
   same when the dump stops halfway (after 0.2 s without data), and the
   synth's ticks run again.
7. a SID303 file sent as SID101's: "SYSEX: NOT A SID101 FILE", nothing
   changed.

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
sys.path.insert(0, os.path.join(ROOT, "tools"))
import sysex  # noqa: E402  (core/sysex.py: the PC tool)
from seq_check import labels  # noqa: E402

SID101 = sysex.SYNTHS["sid101"]
SYSEX_RAM, SYSEX_MAX = 0xE000, 0x1000   # core/options.inc
STEPS_MSG = 0xC800                      # src/undo.asm
PATTERN_RAM, NUM_PATTERNS = 0x8000, 64
LOG_LAG = 0x67FF                        # src/notes.asm (NOTE_LOG - 1)


def build(out, defines, feed=None):
    """Assemble sid101.asm with -D options into out (labels into out.lbl);
    feed: MIDI bytes for TEST_SYSEX's feed (test_sysex.bin beside out)."""
    work = os.path.dirname(out)
    if feed is not None:
        with open(os.path.join(work, "test_sysex.bin"), "wb") as f:
            f.write(len(feed).to_bytes(2, "little") + bytes(feed))
    args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1", "-I", work]
    for d in defines:
        args += ["-D", d]
    subprocess.run(args + ["-l", out + ".lbl", "-o", out, "sid101.asm"], cwd=ROOT, check=True)


def run(img, seconds, ranges, save_image=None):
    """Run img (a .prg or .d64) in VICE; return {address: byte} for the
    ranges [(start, end inclusive)]; save_image: keep the disk image."""
    cmds = [f"m {lo:04x} {hi:04x}" for lo, hi in ranges]
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


def captured(mem):
    """The SysEx messages the capture holds: [bytes F0..F7]."""
    data = bytes(mem.get(SYSEX_RAM + i, 0) for i in range(SYSEX_MAX))
    msgs, i = [], 0
    while True:
        a = data.find(b"\xf0", i)
        if a < 0:
            return msgs
        b = data.find(b"\xf7", a)
        if b < 0:                       # unfinished: up to the capture's end
            msgs.append(data[a:].rstrip(b"\0"))
            return msgs
        msgs.append(data[a:b + 1])
        i = b + 1


def message(mem):
    """The song row's message (steps_msg, screen codes) as text."""
    return "".join(chr(b) if 0x20 <= b < 0x60 else chr(b + 0x40) if 1 <= b <= 26 else "?"
                   for b in (mem[STEPS_MSG + i] for i in range(40))).rstrip()


def song_file(mem, lab, header):
    """The song file as memory holds it (the disk layout, src/disk.asm)."""
    out = bytearray(header)
    for p in range(NUM_PATTERNS):
        a = PATTERN_RAM + p * 256
        out += bytes(mem[a + i] for i in range(lab["PAT_BYTES"]))
    out += bytes(mem[a] for a in range(lab["song_pat"], lab["SONG_END"]))
    out += bytes([mem[lab["seq_bpm"]], mem[lab["seq_swing"]]])
    out += bytes(mem[lab["params"] + i] for i in range(lab["SOUND_PARAMS"]))
    return bytes(out)


HDR = 2 + 7                             # a song file's load address, "sid101" and version
PAT_BYTES, SONG_MAX, SEQ_STEPS = 33, 64, 16
SONG_REP_MAX, TRANSPOSE_MAX = 9, 12     # (src/disk.asm load_check's limits)
SONG_AT = HDR + NUM_PATTERNS * PAT_BYTES
SONG_BLOCK = 3 * SONG_MAX + 1           # song_pat, song_rep, song_tr, song_len


def checked(f):
    """A song file as load_check leaves it in memory: pattern lengths
    1..16, every song entry's pattern, repeats and transpose in range (the
    unused entries hold whatever RAM held when the file was saved)."""
    f = bytearray(f)
    for p in range(NUM_PATTERNS):
        ln = HDR + p * PAT_BYTES + 32
        if not 1 <= f[ln] <= SEQ_STEPS:
            f[ln] = SEQ_STEPS
    if f[SONG_AT + 3 * SONG_MAX] > SONG_MAX:
        f[SONG_AT + 3 * SONG_MAX] = 0
    for e in range(SONG_MAX):
        f[SONG_AT + e] &= NUM_PATTERNS - 1
        if not 1 <= f[SONG_AT + SONG_MAX + e] <= SONG_REP_MAX:
            f[SONG_AT + SONG_MAX + e] = 1
        if (f[SONG_AT + 2 * SONG_MAX + e] + TRANSPOSE_MAX) & 0xFF > 2 * TRANSPOSE_MAX:
            f[SONG_AT + 2 * SONG_MAX + e] = 0
    return bytes(f)


def meaningful(f):
    """A song file without its unused song entries (left-over RAM)."""
    used = f[SONG_AT + 3 * SONG_MAX]
    entries = [f[SONG_AT + k * SONG_MAX:SONG_AT + k * SONG_MAX + used] for k in range(3)]
    return f[:SONG_AT] + b"".join(entries) + f[SONG_AT + 3 * SONG_MAX:]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="build the test programs into this folder (default: a temporary one)")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="dumpcheck")
    os.makedirs(work, exist_ok=True)
    d64tool = os.path.join(C64TOOLS, "d64.py")
    ok = True

    def report(good, text):
        nonlocal ok
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} {text}")

    def disk_run(n, ranges):
        prg = os.path.join(work, f"keys{n}.prg")
        build(prg, [f"TEST_KEYS={n}", "TEST_SYSEX=2"])
        img = os.path.join(work, f"keys{n}.d64")
        subprocess.run([sys.executable, d64tool, "--name", "SID101", "--id", "01", img,
                        f"{prg}=SID101"], check=True, capture_output=True)
        after = os.path.join(work, f"keys{n}-after.d64")
        mem = run(img, 40, ranges, save_image=after)
        return labels(prg), mem, after

    cap = [(SYSEX_RAM, SYSEX_RAM + SYSEX_MAX - 1), (STEPS_MSG, STEPS_MSG + 39)]

    # 1, 2: by key, against the disk file
    files = {}
    for n, name, kind in ((21, "T1", sysex.KIND_SONG), (22, "B1", sysex.KIND_BANK)):
        lab, mem, after = disk_run(n, cap)
        disk = d64_file(after, name)
        msgs = captured(mem)
        try:
            synth, device, k, data = sysex.parse(msgs[0])
            got = (len(msgs), synth, device, k, data == disk)
        except (ValueError, IndexError) as e:
            got, data = (len(msgs), str(e)), b""
        files[kind] = disk
        want = (1, SID101, sysex.DEVICE_ANY, kind, True)
        report(got == want and message(mem) == "SYSEX SENT",
               f"{'song' if kind == 0 else 'bank'} by C= + M (TEST_KEYS={n}): {len(data)} bytes, "
               f"equal to \"{name}\" on the disk ({len(disk)} bytes): {got == want}, \"{message(mem)}\"")

    # 3: requests on channel 2: only the one for device 1 (or any) is answered
    feed = (sysex.request(1, 0, 1) + sysex.request(SID101, 0, 5) + sysex.request(SID101, 0, 1))
    prg = os.path.join(work, "request.prg")
    build(prg, ["TEST_SYSEX=3", "TEST_CHANNEL=2"], feed)
    mem = run(prg, 12, cap)
    msgs = captured(mem)
    try:
        got = [sysex.parse(m)[:3] + (meaningful(sysex.parse(m)[3]) == meaningful(files[0]),) for m in msgs]
    except ValueError as e:
        got = [str(e)]
    report(got == [(SID101, 1, 0, True)],
           f"requests (another synth, device 5, device 1) on channel 2: {len(msgs)} dump(s) back, "
           f"from device 1, the song file as by key: {got}")

    # 3b: a request while the heaviest sound plays on the step screen, MIDI
    # out off: the sequencer plays on while the dump goes out at the wire's
    # pace (the capture's model of the ring), and keeps its ticks
    prg = os.path.join(work, "sendheavy.prg")
    build(prg, ["TEST_SYSEX=3", "TEST_SEQ=1", "TEST_SEQ_PAT=2", "TEST_MIDI=7", "TEST_KEYS=4"],
          sysex.request(SID101, 0))
    lab = labels(prg)
    mem = run(prg, 15, cap + [(0x0000, 0x00ff), (LOG_LAG, LOG_LAG)])
    msgs = captured(mem)
    sound = len(files[0]) - lab["SOUND_PARAMS"]         # (TEST_MIDI=7 has set the sound)
    try:
        data = sysex.parse(msgs[0])[3]
        same = len(msgs) == 1 and meaningful(data[:sound]) == meaningful(files[0][:sound])
    except (ValueError, IndexError) as e:
        same = str(e)
    report(same is True and mem[lab["seq_play"]] == 1 and mem[LOG_LAG] <= 1
           and message(mem) == "SYSEX SENT",
           f"request while the heaviest sound plays (MIDI out off): the song file but the sound: "
           f"{same}, still playing: {mem[lab['seq_play']] == 1}, \"{message(mem)}\", lag {mem[LOG_LAG]}")

    # 4: a song dump in, while the heaviest sound plays on the step screen
    song = bytearray(files[sysex.KIND_SONG])
    hdr = 2 + 7                                         # load address, "sid101" and version
    lab = labels(os.path.join(work, "keys21.prg"))
    pb = lab["PAT_BYTES"]
    for p in (0, 5, 63):                                # patterns 1, 6, 64: notes, flags, length
        base = hdr + p * pb
        for i in range(16):
            song[base + i] = 36 + (p + i * 5) % 40
            song[base + 16 + i] = (i * 7 + p) % 16
        song[base + 32] = 12
    song_at = hdr + NUM_PATTERNS * pb
    n_song = lab["SONG_END"] - lab["song_pat"]
    song[song_at:song_at + 3] = bytes([5, 0, 63])       # song entries: patterns 6, 1, 64
    song[song_at + 64:song_at + 67] = bytes([2, 1, 3])  # repeats
    song[song_at + n_song - 1] = 3                      # song_len
    song[song_at + n_song] = 140                        # tempo
    song[song_at + n_song + 1] = 5                      # swing
    song[song_at + n_song + 2] = 77                     # Cutoff
    song = bytes(song)
    ranges = [(0x0000, 0x00ff), (PATTERN_RAM, PATTERN_RAM + NUM_PATTERNS * 256 - 1),
              (lab["song_pat"], lab["SONG_END"] - 1), (STEPS_MSG, STEPS_MSG + 39), (LOG_LAG, LOG_LAG)]
    want = checked(song)                                # (its unused entries made safe)
    sound = len(song) - lab["SOUND_PARAMS"]
    # a version 1 file of the same song (build 21 and before): no Chord,
    # Chord speed, Click (at their defaults, 0, in the song: it loads the same)
    v2_first, v2_n = lab["P_V2_FIRST"], lab["V2_PARAMS"]
    at = len(song) - lab["SOUND_PARAMS"] + v2_first
    assert song[at:at + v2_n] == bytes(v2_n)
    song_v1 = bytearray(song[:at] + song[at + v2_n:])
    song_v1[hdr - 1] = 1
    for name, defs, feed in (("songin", ["TEST_SYSEX=1"], song),
                             ("songv1", ["TEST_SYSEX=1"], bytes(song_v1)),
                             ("songheavy", ["TEST_SYSEX=1", "TEST_SEQ=1", "TEST_SEQ_PAT=2", "TEST_MIDI=7",
                                            "TEST_KEYS=4"], song)):
        prg = os.path.join(work, f"{name}.prg")
        build(prg, defs, sysex.dump(SID101, 0, feed))
        lab = labels(prg)
        mem = run(prg, 15, ranges)
        now = song_file(mem, lab, song[:hdr])
        if name == "songheavy":                         # (TEST_MIDI=7's controllers come again
            now, want_now = now[:sound], want[:sound]   # after the load: not its sound)
        else:
            want_now = want
        report(now == want_now and mem[lab["seq_play"]] == 0 and message(mem) == "SYSEX: SONG LOADED"
               and mem[LOG_LAG] <= 1,
               f"song dump in ({'while playing the heaviest sound on the step screen' if 'heavy' in name else 'version 1, stopped' if 'v1' in name else 'stopped'}): "
               f"memory = the dump{' but the sound' if 'heavy' in name else ''}: {now == want_now}, "
               f"stopped: {mem[lab['seq_play']] == 0}, \"{message(mem)}\", lag {mem[LOG_LAG]}")

    # 5: a bank dump in
    bank = bytearray(files[sysex.KIND_BANK])
    bhdr = 2 + 9                                        # load address, "s101bank" and version
    pv = lab["PRESET_BYTES"]
    bank[bhdr + pv * 7:bhdr + pv * 8] = bank[bhdr + pv:bhdr + pv * 2]  # slot 8 = slot 2's values
    names = bhdr + 32 * pv
    bank[names:names + 12] = b"\x13\x19\x13\x05\x18" + b" " * 7  # slot 1 "SYSEX" (screen codes)
    bank = bytes(bank)
    prg = os.path.join(work, "bankin.prg")
    build(prg, ["TEST_SYSEX=1"], sysex.dump(SID101, 1, bank))
    lab = labels(prg)
    pr = lab["PRESET_RAM"]
    mem = run(prg, 12, [(pr, pr + len(bank) - bhdr - 1), (STEPS_MSG, STEPS_MSG + 39)])
    now = bytes(mem[pr + i] for i in range(len(bank) - bhdr))
    report(now == bank[bhdr:] and message(mem) == "SYSEX: BANK LOADED",
           f"bank dump in: the presets = the dump: {now == bank[bhdr:]}, \"{message(mem)}\"")

    # 5b: the same bank as a version 1 file: it loads as the same version 2
    # bank (its presets' Chord, Chord speed, Click are 0: their defaults)
    v1 = bytearray(bank[:bhdr])
    v1[bhdr - 1] = 1
    for slot in range(32):
        vals = bank[bhdr + slot * pv:bhdr + (slot + 1) * pv]
        assert vals[v2_first:v2_first + v2_n] == bytes(v2_n)
        v1 += vals[:v2_first] + vals[v2_first + v2_n:]
    v1 += bank[names:]
    prg = os.path.join(work, "bankv1.prg")
    build(prg, ["TEST_SYSEX=1"], sysex.dump(SID101, 1, bytes(v1)))
    mem = run(prg, 12, [(pr, pr + len(bank) - bhdr - 1), (STEPS_MSG, STEPS_MSG + 39)])
    now = bytes(mem[pr + i] for i in range(len(bank) - bhdr))
    report(now == bank[bhdr:] and message(mem) == "SYSEX: BANK LOADED",
           f"version 1 bank dump in: the presets = the version 2 bank: {now == bank[bhdr:]}, \"{message(mem)}\"")

    # 6, 7: a bad sum, a SID303 file: nothing changes
    bad = bytearray(sysex.dump(SID101, 0, song))
    bad[-2] ^= 1
    sid303 = bytearray(song)
    sid303[2:8] = b"SID303"
    cut = sysex.dump(SID101, 0, song)[:1000]            # the PC stops halfway
    for name, feed, want in (("badsum", bytes(bad), "SYSEX: BAD DATA"),
                             ("cut", cut, "SYSEX: BAD DATA"),
                             ("sid303", sysex.dump(SID101, 0, bytes(sid303)), "SYSEX: NOT A SID101 FILE")):
        prg = os.path.join(work, f"{name}.prg")
        build(prg, ["TEST_SYSEX=1"], feed)
        lab = labels(prg)
        mem = run(prg, 12, ranges)
        same = meaningful(song_file(mem, lab, song[:hdr])) == meaningful(files[sysex.KIND_SONG])
        report(same and message(mem) == want and mem[LOG_LAG] <= 1,
               f"{name}: \"{message(mem)}\", the song as at start: {same}, lag {mem[LOG_LAG]}")

    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
