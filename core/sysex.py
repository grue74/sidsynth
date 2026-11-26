"""sysex.py - SidSynth SysEx dumps from a PC: fetch a synth's files, send them back.

Part of the SID synth core shared by SID303, SID808 and SID101.
Copyright (C) 2026 Jarkko Lehti
SPDX-License-Identifier: GPL-3.0-or-later

The synths (core/sysex.asm, MIDI_SYSEX) send and take their files over MIDI
as SysEx, each byte for byte as its disk file (a .prg: load address, header,
data), so a fetched file can go on a disk and a file from a disk can be
sent. The messages (manufacturer ID $7D):

    request  F0 7D <synth> <device> 01 <kind> F7
    dump     F0 7D <synth> <device> 02 <kind> <len lo> <len hi> <data> <sum> F7

synth: 1 SID303, 2 SID808, 3 SID101. device: the synth's MIDI channel - 1,
or $7F for any. kind: 0 the song file, 1 the preset bank (SID101, SID303). data: groups
of up to 7 bytes, each a byte of their top bits (bit 0 = the first byte's)
and then their low 7 bits. sum: the sum of every byte from kind to sum is
a multiple of 128.

Usage (needs mido and python-rtmidi):

    python sysex.py ports
    python sysex.py get sid101 [--bank] [-o FILE] [--port NAME] [--channel N]
    python sysex.py send FILE [--port NAME] [--channel N]

--port picks the MIDI port (in and out) by part of its name; without it,
the only port that isn't Windows' own synth. --channel is the synth's MIDI
channel (1-16; default: any synth of the kind). A sent file's synth and
kind come from its header.
"""
import argparse
import os
import sys
import time

SYSEX_ID = 0x7D
REQUEST, DUMP = 0x01, 0x02
DEVICE_ANY = 0x7F
SYNTHS = {"sid303": 1, "sid808": 2, "sid101": 3}
KIND_SONG, KIND_BANK = 0, 1
# a file's header after its load address (plain PETSCII = ASCII capitals):
# (synth, kind) by its magic, the version byte after it
MAGICS = {b"SID303": ("sid303", KIND_SONG), b"SID808": ("sid808", KIND_SONG),
          b"SID101": ("sid101", KIND_SONG), b"S101BANK": ("sid101", KIND_BANK),
          b"S303BANK": ("sid303", KIND_BANK)}


def pack(data):
    """The 8-bit bytes in 7-bit groups: per up to 7 bytes, their top bits
    (bit i = byte i's), then their low 7 bits."""
    out = []
    for i in range(0, len(data), 7):
        group = data[i:i + 7]
        out.append(sum(((b >> 7) & 1) << j for j, b in enumerate(group)))
        out += [b & 0x7F for b in group]
    return out


def unpack(packed, length):
    """pack's inverse: the first `length` bytes."""
    out = []
    i = 0
    while len(out) < length:
        top = packed[i]
        group = packed[i + 1:i + 8]
        for j, b in enumerate(group):
            if len(out) == length:
                break
            out.append(b | ((top >> j) & 1) << 7)
        i += 1 + len(group)
    return bytes(out)


def checksum(body):
    """The sum byte for the bytes from kind on."""
    return -sum(body) & 0x7F


def request(synth, kind, device=DEVICE_ANY):
    """A request message, F0 to F7."""
    return bytes([0xF0, SYSEX_ID, synth, device, REQUEST, kind, 0xF7])


def dump(synth, kind, data, device=DEVICE_ANY):
    """A dump message of data (the file), F0 to F7."""
    body = [kind, len(data) & 0x7F, len(data) >> 7] + pack(data)
    return bytes([0xF0, SYSEX_ID, synth, device, DUMP] + body + [checksum(body), 0xF7])


def parse(msg):
    """A dump message (F0 to F7, or mido's data without them) ->
    (synth, device, kind, data); ValueError if it isn't a whole dump."""
    m = list(msg)
    if m and m[0] == 0xF0:
        m = m[1:]
    if m and m[-1] == 0xF7:
        m = m[:-1]
    if len(m) < 8 or m[0] != SYSEX_ID or m[3] != DUMP:
        raise ValueError("not a SidSynth dump")
    synth, device, body = m[1], m[2], m[4:]
    if sum(body) & 0x7F:
        raise ValueError("bad checksum")
    kind, length = body[0], body[1] | body[2] << 7
    packed = body[3:-1]
    if len(packed) != length + (length + 6) // 7:
        raise ValueError(f"{len(packed)} packed bytes for {length}")
    return synth, device, kind, unpack(packed, length)


def identify(data):
    """A file's (synth name, kind) from its header."""
    for magic, sk in MAGICS.items():
        if data[2:2 + len(magic)] == magic:
            return sk
    raise ValueError("not a SidSynth file (no SID303, SID808, SID101 or bank header)")


def _ports(name):
    import mido
    outs = mido.get_output_names()
    ins = mido.get_input_names()
    if name:
        o = [p for p in outs if name.lower() in p.lower()]
        i = [p for p in ins if name.lower() in p.lower()]
    else:
        o = [p for p in outs if "Microsoft" not in p]
        i = [p for p in ins if "Microsoft" not in p]
        if len(o) > 1 or len(i) > 1:
            sys.exit(f"several MIDI ports: pick one with --port\n  out: {o}\n  in: {i}")
    if not o or not i:
        sys.exit(f"no MIDI port {name or ''} (python sysex.py ports lists them)")
    return i[0], o[0]


def _device(channel):
    return DEVICE_ANY if channel is None else channel - 1


def cmd_get(a):
    import mido
    synth = SYNTHS[a.synth]
    kind = KIND_BANK if a.bank else KIND_SONG
    pin, pout = _ports(a.port)
    with mido.open_input(pin) as inp, mido.open_output(pout) as out:
        while inp.poll():                                  # nothing old
            pass
        out.send(mido.Message.from_bytes(list(request(synth, kind, _device(a.channel)))))
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            msg = inp.poll()
            if msg is None:
                time.sleep(0.01)
                continue
            if msg.type != "sysex" or msg.data[:2] != (SYSEX_ID, synth) or msg.data[3] != DUMP:
                continue
            s, _dev, k, data = parse(msg.data)
            if k != kind:
                continue
            name = a.output or f"{a.synth}-{'bank' if a.bank else 'song'}.prg"
            with open(name, "wb") as f:
                f.write(data)
            print(f"{name}: {len(data)} bytes from {a.synth}")
            return
    sys.exit(f"no dump from {a.synth} in {a.timeout:g} s (its MIDI interface, channel, cable?)")


def cmd_send(a):
    import mido
    with open(a.file, "rb") as f:
        data = f.read()
    name, kind = identify(data)
    _pin, pout = _ports(a.port)
    with mido.open_output(pout) as out:
        out.send(mido.Message.from_bytes(list(dump(SYNTHS[name], kind, data, _device(a.channel)))))
        time.sleep(len(data) * 1.15 / 3125 + 0.2)          # (let the port send it all)
    print(f"{a.file}: {len(data)} bytes to {name} ({'bank' if kind else 'song'})")


def cmd_ports(_a):
    import mido
    print("out:", ", ".join(mido.get_output_names()) or "-")
    print("in: ", ", ".join(mido.get_input_names()) or "-")


def self_test():
    """pack/unpack and the message format, without MIDI."""
    import random
    rnd = random.Random(1)
    for n in (0, 1, 6, 7, 8, 13, 14, 15, 2347):
        data = bytes(rnd.randrange(256) for _ in range(n))
        assert unpack(pack(data), n) == data
        msg = dump(3, 0, data, 4)
        assert all(b < 0x80 for b in msg[1:-1])
        assert parse(msg) == (3, 4, 0, data)
    print("sysex.py self test: ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("get", help="fetch a synth's song file (or bank)")
    p.add_argument("synth", choices=sorted(SYNTHS))
    p.add_argument("--bank", action="store_true", help="the preset bank (SID101, SID303)")
    p.add_argument("-o", "--output")
    p.add_argument("--timeout", type=float, default=30,
                   help="seconds to wait (a synth playing a heavy sound sends slowly)")
    p = sub.add_parser("send", help="send a file to its synth")
    p.add_argument("file")
    sub.add_parser("ports", help="list the MIDI ports")
    sub.add_parser("test", help="self test (no MIDI)")
    for name in ("get", "send"):
        sp = sub.choices[name]
        sp.add_argument("--port")
        sp.add_argument("--channel", type=int, choices=range(1, 17), metavar="1-16")
    a = ap.parse_args()
    {"get": cmd_get, "send": cmd_send, "ports": cmd_ports, "test": lambda _a: self_test()}[a.cmd](a)


if __name__ == "__main__":
    main()
