#!/usr/bin/env python3
"""Runs packed PRGs through the real 6502 depacker (py65) and checks the result.

    python test_pack.py [-slow] [file.prg ...]

Without arguments a set of synthetic payloads is tested.
"""
import os
import random
import sys
import time

from py65.devices.mpu6502 import MPU

import c64pack


class BankedMemory:
    """64K RAM with the I/O area banked in at $d000-$dfff according to $01.

    ROMs are not modelled (the test stops before any ROM call); writes always
    go to RAM except I/O writes while I/O is visible.
    """

    def __init__(self):
        self.ram = bytearray(0x10000)
        self.io = bytearray(0x1000)
        self.ram[1] = 0x37
        self.io[0x011] = 0x1b

    def _io(self, addr):
        return 0xd000 <= addr < 0xe000 and self.ram[1] & 3 and self.ram[1] & 4

    def __getitem__(self, addr):
        return self.io[addr - 0xd000] if self._io(addr) else self.ram[addr]

    def __setitem__(self, addr, value):
        if self._io(addr):
            self.io[addr - 0xd000] = value
        else:
            self.ram[addr] = value

    def __len__(self):
        return 0x10000


def run_6502(prg, stop_pcs, limit=200_000_000):
    mpu = MPU()
    mem = BankedMemory()
    body = prg[2:]
    mem.ram[0x0801:0x0801 + len(body)] = body
    mpu.memory = mem
    mpu.pc = 0x080d
    mpu.sp = 0xf6
    start = mpu.processorCycles
    entered = False   # the start address may lie inside the boot code
    while not (entered and mpu.pc in stop_pcs):
        mpu.step()
        entered = entered or 0x0100 <= mpu.pc < 0x0200
        if mpu.processorCycles - start > limit:
            raise RuntimeError('cycle limit hit, pc=$%04x' % mpu.pc)
    return mem, mpu.pc, mpu.processorCycles - start


def verify_6502(prg, data, load, info):
    """Run the packed PRG up to the start of the payload, return (ok, cycles)."""
    expect = 0xa533 if info['mode'] == 'basic' else info['start']
    mem, pc, cycles = run_6502(prg, {expect})
    ram = mem.ram
    ok = (bytes(ram[load:load + len(data)]) == data and ram[1] == 0x37 and
          mem.io[0x030] == 0 and mem.io[0x011] == 0x1b)
    if info['mode'] == 'basic':
        ok = ok and ram[0x2d] | (ram[0x2e] << 8) == (load + len(data)) & 0xffff
    return ok, cycles


def check(name, data, load, start=None, slow=False):
    t0 = time.time()
    try:
        prg, info = c64pack.pack(data, load, start, verbose=False, slow=slow)
    except c64pack.PackError as e:
        print('%-28s pack error: %s' % (name, e))
        return None
    t1 = time.time()
    ok, cycles = verify_6502(prg, data, load, info)
    print('%-28s $%04x-$%04x %6d -> %6d (%5.1f%%) tail %4d @$%04x  %8d cyc  %5.1f cyc/byte  pack %.1fs  %s'
          % (name, load, load + len(data) - 1, len(data), info['packed'],
             100.0 * info['packed'] / (len(data) + 2), info['seg2'], info['buffer'],
             cycles, cycles / len(data), t1 - t0, 'OK' if ok else 'FAIL'))
    return ok


def synthetic():
    rnd = random.Random(64)
    text = open(c64pack.__file__, 'rb').read()
    cases = [
        ('zeros 32k @0801', bytes(32768), 0x0801, None),
        ('random 8k @0801', bytes(rnd.randrange(256) for _ in range(8192)), 0x0801, None),
        ('random 300 @c000', bytes(rnd.randrange(256) for _ in range(300)), 0xc000, None),
        ('tiny 1 @0801', b'\x42', 0x0801, None),
        ('tiny 5 @1000', b'hello', 0x1000, 0x1000),
        ('text @0801', text, 0x0801, 0x0810),
        ('text to $ffff', text, 0x10000 - len(text), 0xe000),
        ('text over $d000', text[:0x2000], 0xc800, 0xc800),
        ('text $c000-$efff', (text * 2)[:0x3000], 0xc000, 0xc000),
        ('text @0400 (below file)', text[:900], 0x0400, 0x0400),
        ('zeros $0801-$ffff', bytes(0x10000 - 0x0801), 0x0801, 0x0801),
        ('mixed $0801-$ffff', (text * 4)[:0x10000 - 0x0801], 0x0801, 0x0801),
    ]
    return cases


def main():
    results = []
    args = sys.argv[1:]
    slow = '-slow' in args
    args = [a for a in args if a != '-slow']
    if args:
        for path in args:
            raw = open(path, 'rb').read()
            if len(raw) < 3:
                continue
            load = raw[0] | (raw[1] << 8)
            results.append(check(os.path.basename(path)[:28], raw[2:], load,
                                 None if load == 0x0801 else load, slow))
    else:
        for name, data, load, start in synthetic():
            results.append(check(name, data, load, start, slow))
    bad = [r for r in results if r is False]
    print('%d tested, %d failed, %d not packable' % (len(results), len(bad), results.count(None)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
