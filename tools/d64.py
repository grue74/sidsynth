#!/usr/bin/env python3
"""d64.py - write a 1541 disk image (.d64) from PRG files, with directory art.

    python d64.py [options] out.d64 game.prg [other.prg=NAME ...]

    -n, --name NAME     disk name (16 chars max), default: the first file's name
    --id ID             disk ID (2 chars), default "01"
    -i, --interleave N  sectors between a file's blocks, default 6 (fastest with
                        JiffyDOS, no loss with the stock loader - see README)
    --art FILE          directory art: one zero-block DEL entry per line, after the files
    --art-first         put the art entries before the files (LOAD"*" then loads the
                        first file - so keep the game first unless you mean it)
    --list              print the directory afterwards (PETSCII codes as {xx})

A file's directory name defaults to its file name without .prg, upper-cased;
give one explicitly with file.prg=NAME.  Files are PRG; file=NAME,SEQ (or
,USR) writes another type.

Art file: one line per directory entry (16 characters max). Plain text is
converted to PETSCII (letters upper case), {xx} inserts a PETSCII code in hex,
e.g. {d5}{c0}{c0}{c9} draws a rounded box top. Every line is padded with
spaces to 16 so the closing quotes line up. Lines starting with # are comments.
Useful codes (upper-case/graphics set): {d5} {c9} {ca} {cb} round corners
(top-left, top-right, bottom-left, bottom-right), {c0} horizontal line, {dd}
vertical line, {ab} {b3} {b1} {b2} T-joints (left, right, bottom, top), {db}
cross, {d1} filled circle, {d7} circle, {cd} {ce} diagonals, {a0} is not
allowed (it ends a name).

Files are laid out like the 1541 DOS does it: tracks 17 down to 1, then 19 up
to 35, each next block INTERLEAVE sectors on, also across track changes.
"""
import argparse
import os
import re
import sys

SECTORS = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5          # tracks 1..35
OFFSET = [0]
for _n in SECTORS:
    OFFSET.append(OFFSET[-1] + _n)
DIR_SECTORS = [1, 4, 7, 10, 13, 16, 2, 5, 8, 11, 14, 17, 3, 6, 9, 12, 15, 18]   # interleave 3
FILE_TYPES = {'': 0x82, 'PRG': 0x82, 'P': 0x82, 'SEQ': 0x81, 'S': 0x81, 'USR': 0x83, 'U': 0x83}
TYPE_NAMES = {0x80: 'DEL', 0x81: 'SEQ', 0x82: 'PRG', 0x83: 'USR'}


def ts(track, sector):
    return (OFFSET[track - 1] + sector) * 256


def petscii(text):
    """ASCII text with {xx} hex escapes -> PETSCII bytes."""
    out = []
    for part in re.split(r'(\{[0-9a-fA-F]{2}\})', text):
        if not part:
            continue
        if part[0] == '{':
            out.append(int(part[1:3], 16))
            continue
        for ch in part:
            c = ord(ch)
            if 0x61 <= c <= 0x7a:
                c -= 0x20                       # lower-case ASCII -> PETSCII upper case
            if c > 0x7f:
                raise SystemExit('non-ASCII character %r: use a {xx} code' % ch)
            out.append(c)
    return bytes(out)


def entry_name(raw, pad):
    if len(raw) > 16:
        raise SystemExit('directory name longer than 16: %r' % raw)
    if 0xa0 in raw:
        raise SystemExit('{a0} ends a directory name: %r' % raw)
    return raw + bytes([0x20 if pad else 0xa0] * (16 - len(raw)))


class Image:
    def __init__(self, interleave):
        self.img = bytearray(OFFSET[-1] * 256)
        self.used = {t: set() for t in range(1, 36)}
        self.used[18].add(0)
        self.interleave = interleave
        self.pos = 0                            # angular position carried across files
        self.tracks = list(range(17, 0, -1)) + list(range(19, 36))

    def write_file(self, data):
        need = max(1, (len(data) + 253) // 254)
        chain = []
        for t in self.tracks:
            n = SECTORS[t - 1]
            s = self.pos % n
            while len(self.used[t]) < n and len(chain) < need:
                while s in self.used[t]:
                    s = (s + 1) % n
                self.used[t].add(s)
                chain.append((t, s))
                s = (s + self.interleave) % n
            self.pos = s
            if len(chain) == need:
                break
        if len(chain) < need:
            raise SystemExit('disk full')
        for i, (t, s) in enumerate(chain):
            part = data[i * 254:(i + 1) * 254]
            o = ts(t, s)
            if i + 1 < len(chain):
                self.img[o], self.img[o + 1] = chain[i + 1]
            else:
                self.img[o], self.img[o + 1] = 0, len(part) + 1
            self.img[o + 2:o + 2 + len(part)] = part
        return chain[0], len(chain)

    def write_dir(self, entries, name, disk_id):
        nsec = (len(entries) + 7) // 8
        if nsec > len(DIR_SECTORS):
            raise SystemExit('too many directory entries (max %d)' % (8 * len(DIR_SECTORS)))
        dsecs = DIR_SECTORS[:max(1, nsec)]
        for k, s in enumerate(dsecs):
            o = ts(18, s)
            nxt = (18, dsecs[k + 1]) if k + 1 < len(dsecs) else (0, 0xff)
            self.img[o], self.img[o + 1] = nxt
            for j, (typ, (ft, fs), nm, blocks) in enumerate(entries[k * 8:(k + 1) * 8]):
                e = o + j * 32
                self.img[e + 2] = typ
                self.img[e + 3], self.img[e + 4] = ft, fs
                self.img[e + 5:e + 21] = nm
                self.img[e + 30], self.img[e + 31] = blocks & 255, blocks >> 8
            self.used[18].add(s)
        b = ts(18, 0)
        self.img[b:b + 4] = bytes([18, 1, 0x41, 0])
        for t in range(1, 36):
            n = SECTORS[t - 1]
            bits = sum(1 << s for s in range(n) if s not in self.used[t])
            self.img[b + 4 * t:b + 4 * t + 4] = bytes([n - len(self.used[t]), bits & 255, bits >> 8 & 255,
                                                       bits >> 16 & 255])
        self.img[b + 0x90:b + 0xa0] = entry_name(name, False)
        self.img[b + 0xa0:b + 0xab] = b'\xa0\xa0' + disk_id + b'\xa0' + b'2A' + b'\xa0' * 4


def show(raw):
    return ''.join(chr(c) if 0x20 <= c < 0x60 else '{%02x}' % c for c in raw.rstrip(b'\xa0'))


def main():
    ap = argparse.ArgumentParser(description='Write a .d64 from PRG files, with directory art.')
    ap.add_argument('out')
    ap.add_argument('files', nargs='+', help='file.prg or file.prg=NAME')
    ap.add_argument('-n', '--name')
    ap.add_argument('--id', default='01')
    ap.add_argument('-i', '--interleave', type=int, default=6)
    ap.add_argument('--art')
    ap.add_argument('--art-first', action='store_true')
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()

    img = Image(a.interleave)
    files = []
    for spec in a.files:
        path, _, nm = spec.partition('=')
        nm = nm or os.path.splitext(os.path.basename(path))[0]
        nm, _, ft = nm.partition(',')
        typ = FILE_TYPES.get(ft.upper())
        if typ is None:
            raise SystemExit('unknown file type %r in %r (PRG, SEQ or USR)' % (ft, spec))
        data = open(path, 'rb').read()
        first, blocks = img.write_file(data)
        files.append((typ, first, entry_name(petscii(nm), False), blocks))
    art = []
    if a.art:
        for line in open(a.art, encoding='utf-8').read().splitlines():
            if line.startswith('#'):
                continue
            art.append((0x80, (0, 0), entry_name(petscii(line), True), 0))
    entries = art + files if a.art_first else files + art
    name = petscii(a.name) if a.name else files[0][2].rstrip(b'\xa0')
    disk_id = petscii(a.id)[:2].ljust(2, b' ')
    img.write_dir(entries, name, disk_id)
    open(a.out, 'wb').write(img.img)
    print('%s: %d files, %d art lines, %d blocks used, interleave %d' % (
        a.out, len(files), len(art), sum(e[3] for e in files), a.interleave))
    if a.list:
        print('0 "%s" %s 2A' % (show(entry_name(name, False)), show(disk_id)))
        for typ, _, nm, blocks in entries:
            print('%-4d "%s" %s' % (blocks, show(nm), TYPE_NAMES[typ]))


if __name__ == '__main__':
    main()
