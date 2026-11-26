#!/usr/bin/env python3
"""
c64pack - self-extracting packer for Commodore 64 PRG files, built for fast
decompression.

Usage:
    python c64pack.py input.prg output.prg [start]
    python c64pack.py input.prg output.prg -s 0x0810
    python c64pack.py -slow input.prg output.prg 0x0810
    python c64pack.py -verify input.prg output.prg 0x0810

-verify additionally runs the real 6502 depacker in py65 (needs test_pack.py
and pip install py65) and only writes the output if the unpacked RAM matches.

-slow selects a bit-stream format (see the -slow section below) that packs
about as well as exomizer and still unpacks faster; the default format is
built purely for unpacking speed.

start may be given as 0xc000, decimal 49152 or '$c000' (quote the $ form:
PowerShell and bash would otherwise expand it as a variable and drop it).  If no start address is
given, a payload loading at $0801 is started with BASIC RUN, anything else is
started with JMP <load address>.

Format
------
Byte-aligned LZ77, no bit streams, decoded *backwards* (from the end of the
payload towards its start).  Backward decoding lets most of the packed stream
be decompressed in place straight from where LOAD put it, so the C64 does not
have to move the whole packed file out of the way first.  Only a small tail of
the stream (the part that is overwritten by the lowest payload bytes) is copied
to a safe buffer before decoding.

While decoding, the screen is blanked (no badlines), $d030 is set to 1 (2 MHz
on a C128 in C64 mode, ignored by a C64) and $01 is $34, so the payload may
cover $d000-$dfff.  Afterwards $01=$37, $d030=0 and the screen is switched on.

Tokens, in reading order (the stream is read from high to low addresses):
    $00              end of segment
    $01-$7f n        n literal bytes follow
    $80-$bf o        match, length (t&$3f)+3, offset o+1        (1..256)
    $c0-$ff hi lo    match, length (t&$3f)+3, offset hi*256+lo+1 (1..65536)
Offsets point upwards in memory (towards data that was already decoded).
"""

import argparse
import re
import sys
from collections import deque

# ---------------------------------------------------------------------------
# Tiny two-pass 6502 assembler, just enough for the depacker stub.
# ---------------------------------------------------------------------------

OPCODES = {
    'lda': {'imm': 0xa9, 'zp': 0xa5, 'abs': 0xad, 'absx': 0xbd, 'absy': 0xb9, 'indy': 0xb1},
    'sta': {'zp': 0x85, 'abs': 0x8d, 'absx': 0x9d, 'absy': 0x99, 'indy': 0x91},
    'ldx': {'imm': 0xa2, 'zp': 0xa6, 'abs': 0xae},
    'ldy': {'imm': 0xa0, 'zp': 0xa4, 'abs': 0xac},
    'stx': {'zp': 0x86, 'abs': 0x8e},
    'sty': {'zp': 0x84, 'abs': 0x8c},
    'adc': {'imm': 0x69, 'zp': 0x65, 'abs': 0x6d},
    'sbc': {'imm': 0xe9, 'zp': 0xe5, 'abs': 0xed},
    'and': {'imm': 0x29}, 'ora': {'imm': 0x09, 'zp': 0x05, 'abs': 0x0d}, 'eor': {'imm': 0x49},
    'asl': {'acc': 0x0a, 'zp': 0x06, 'abs': 0x0e}, 'rol': {'acc': 0x2a, 'zp': 0x26, 'abs': 0x2e},
    'cmp': {'imm': 0xc9}, 'cpx': {'imm': 0xe0}, 'cpy': {'imm': 0xc0},
    'inc': {'zp': 0xe6, 'abs': 0xee},
    'dec': {'zp': 0xc6, 'abs': 0xce},
    'jmp': {'abs': 0x4c}, 'jsr': {'abs': 0x20},
}
BRANCHES = {'bpl': 0x10, 'bmi': 0x30, 'bcc': 0x90, 'bcs': 0xb0, 'bne': 0xd0, 'beq': 0xf0}
IMPLIED = {'tax': 0xaa, 'txa': 0x8a, 'tay': 0xa8, 'tya': 0x98, 'dex': 0xca, 'dey': 0x88,
           'inx': 0xe8, 'iny': 0xc8, 'sei': 0x78, 'cli': 0x58, 'clc': 0x18, 'sec': 0x38,
           'rts': 0x60, 'nop': 0xea, 'txs': 0x9a}


def assemble(source, org, symbols):
    """Assemble `source` at `org`.  Returns (bytes, labels)."""
    lines = []
    for raw in source.splitlines():
        line = raw.split(';', 1)[0].strip()
        if not line:
            continue
        label = None
        if ':' in line:
            label, line = line.split(':', 1)
            label, line = label.strip(), line.strip()
        lines.append((label, line))

    labels = {}
    modes = {}

    def ev(expr, final):
        expr = expr.strip()
        part = None
        if expr[:1] in '<>':
            part, expr = expr[0], expr[1:]
        expr = re.sub(r'\$([0-9a-fA-F]+)', lambda mo: '0x' + mo.group(1), expr)
        env = dict(symbols)
        env.update(labels)
        try:
            v = eval(expr, {'__builtins__': {}}, env)
        except NameError:
            if final:
                raise
            return None
        if part == '<':
            v &= 0xff
        elif part == '>':
            v = (v >> 8) & 0xff
        return v

    for final in (False, True):
        pc = org
        out = bytearray()
        for idx, (label, line) in enumerate(lines):
            if label:
                if not final:
                    labels[label] = pc
                elif labels[label] != pc:
                    raise RuntimeError('phase error at ' + label)
            if not line:
                continue
            mn, _, opnd = line.partition(' ')
            mn, opnd = mn.lower(), opnd.strip()
            if mn == '.byte':
                for e in opnd.split(','):
                    v = ev(e, final)
                    out.append((v or 0) & 0xff)
                pc += len(opnd.split(','))
                continue
            if mn in IMPLIED:
                out.append(IMPLIED[mn])
                pc += 1
                continue
            if mn in BRANCHES:
                tgt = ev(opnd, final)
                if final:
                    rel = tgt - (pc + 2)
                    if not -128 <= rel <= 127:
                        raise RuntimeError('branch out of range: ' + line)
                    out += bytes([BRANCHES[mn], rel & 0xff])
                pc += 2
                continue
            table = OPCODES[mn]
            o = opnd.lower()
            if o == 'a':
                out.append(table['acc'])
                pc += 1
                continue
            if o.startswith('#'):
                mode, expr = 'imm', opnd[1:]
            elif o.startswith('(') and o.endswith('),y'):
                mode, expr = 'indy', opnd[1:-3]
            elif o.endswith(',x'):
                mode, expr = 'absx', opnd[:-2]
            elif o.endswith(',y'):
                mode, expr = 'absy', opnd[:-2]
            else:
                mode, expr = 'abs', opnd
            v = ev(expr, final)
            if mode == 'abs':
                if not final:
                    modes[idx] = 'zp' if (v is not None and v < 256 and 'zp' in table) else 'abs'
                mode = modes[idx]
            if mode not in table:
                raise RuntimeError('bad addressing mode: ' + line)
            size = 3 if mode in ('abs', 'absx', 'absy') else 2
            if final:
                out.append(table[mode])
                if size == 2:
                    if not 0 <= v <= 255:
                        raise RuntimeError('operand too large: ' + line)
                    out.append(v)
                else:
                    out += bytes([v & 0xff, (v >> 8) & 0xff])
            pc += size
    return bytes(out), labels


# ---------------------------------------------------------------------------
# C64 side
# ---------------------------------------------------------------------------

ZP_SRC = 0xfb      # stream pointer, points at the next token
ZP_DST = 0xfd      # output pointer, points at the byte below the decoded data
ZP_MP = 0xf9       # match source pointer
DEPACK_ORG = 0x0100  # bottom of the stack page
BOOT_ORG = 0x080d    # right after "10 SYS2061"

# Runs at $080d.  Moves the depacker to the stack page, copies the low part of
# the stream (segment 2) to a safe buffer and starts decoding segment 1 in place.
BOOT_SRC = """
        sei
        lda #$7f
        sta $dd0d           ; no CIA2 NMIs
        lda $d011
        and #$6f            ; screen off: no badlines
        sta $d011
        lda #1
        sta $d030           ; C128 in C64 mode: 2 MHz
        lda #$34            ; all RAM, decode under I/O too
        sta $01
        ldx #DLEN
mv:     lda DFILE-1,x
        sta DEPACK_ORG-1,x
        dex
        bne mv
        lda #<P
        sta src
        lda #>P
        sta src+1
        lda #<B
        sta dst
        lda #>B
        sta dst+1
        ldy #0
        ldx #CPAGES
        beq rest
pg:     lda (src),y
        sta (dst),y
        iny
        bne pg
        inc src+1
        inc dst+1
        dex
        bne pg
rest:   cpy #CREST
        beq init
rl:     lda (src),y
        sta (dst),y
        iny
        cpy #CREST
        bne rl
init:   lda #<S1TOP
        sta src
        lda #>S1TOP
        sta src+1
        lda #<DTOP
        sta dst
        lda #>DTOP
        sta dst+1
        jmp next
"""

ENDSEG_SRC = """
endseg: lda flag
        bne done
        inc flag
        lda #<S2TOP
        sta src
        lda #>S2TOP
        sta src+1
        jmp next
done:   lda #$37
        sta $01
        lda #0
        sta $d030           ; back to 1 MHz
        lda $d011
        and #$7f
        ora #$10            ; screen on
        sta $d011
        cli
"""

DEPACK_SRC = """
next:   ldy #0
        lda (src),y
        bmi match
        beq endseg
        tax                 ; literal run of X bytes
        eor #$ff
        clc
        adc src             ; src -= X+1
        sta src
        bcs l1
        dec src+1
l1:     txa
        eor #$ff
        sec
        adc dst             ; dst -= X
        sta dst
        bcs l2
        dec dst+1
l2:     txa
        tay
lcp:    lda (src),y
        sta (dst),y
        dey
        bne lcp
        beq next+2
match:  cmp #$c0
        bcs long
        and #$3f            ; near match, C=0
        adc #3
        tax
        lda src
        sbc #1              ; C=0: src -= 2
        sta src
        bcs s1
        dec src+1
s1:     txa
        eor #$ff
        sec
        adc dst             ; dst -= len
        sta dst
        bcs s2
        dec dst+1
s2:     ldy #1
        lda (src),y
        sec
        adc dst             ; mp = dst + offset
        sta mp
        lda dst+1
        adc #0
        sta mp+1
        txa
        tay
scp:    lda (mp),y
        sta (dst),y
        dey
        bne scp
        beq next+2
long:   and #$3f            ; far match, C=1
        adc #2
        tax
        lda src
        sbc #2              ; C=0: src -= 3
        sta src
        bcs g1
        dec src+1
g1:     txa
        eor #$ff
        sec
        adc dst
        sta dst
        bcs g2
        dec dst+1
g2:     ldy #1
        lda (src),y
        sec
        adc dst
        sta mp
        iny
        lda (src),y
        adc dst+1
        sta mp+1
        txa
        tay
lmcp:   lda (mp),y
        sta (dst),y
        dey
        bne lmcp
        jmp next
"""

DONE_JMP = """
        jmp START
flag:   .byte 0
"""

DONE_BASIC = """
        lda #<PEND
        sta $2d
        lda #>PEND
        sta $2e
        jsr $a533           ; relink lines
        jsr $a659           ; reset TXTPTR + CLR
        jmp $a7ae           ; RUN
flag:   .byte 0
"""


def basic_line():
    nxt = 0x080b
    return bytes([nxt & 0xff, nxt >> 8, 10, 0, 0x9e]) + b'2061' + bytes([0, 0, 0])


# ---------------------------------------------------------------------------
# Compressor (works on the reversed payload, see module docstring)
# ---------------------------------------------------------------------------

MINLEN = 3
MAXLEN = 66
MAXLIT = 127
NEAR = 256
FAR = 65536
CHAIN_DEPTH = 512


def find_matches(r):
    n = len(r)
    near_len = [0] * n
    near_off = [0] * n
    far_len = [0] * n
    far_off = [0] * n
    head = {}
    prev = [-1] * n
    for i in range(n - MINLEN + 1):
        key = r[i:i + MINLEN]
        p = head.get(key, -1)
        prev[i] = p
        head[key] = i
        maxl = min(MAXLEN, n - i)
        nl = no = fl = fo = 0
        depth = 0
        while p >= 0 and depth < CHAIN_DEPTH:
            off = i - p
            if off > FAR:
                break
            need = nl if off <= NEAR else fl
            if need < maxl and r[p + need] == r[i + need]:
                ln = MINLEN
                while ln < maxl and r[p + ln] == r[i + ln]:
                    ln += 1
                if off <= NEAR and ln > nl:
                    nl, no = ln, off
                if ln > fl:
                    fl, fo = ln, off
            if fl == maxl and (nl == maxl or off >= NEAR):
                break
            p = prev[p]
            depth += 1
        near_len[i], near_off[i], far_len[i], far_off[i] = nl, no, fl, fo
    return near_len, near_off, far_len, far_off


def parse(r):
    """Optimal parse for size, ties broken by fewer tokens (faster decode)."""
    n = len(r)
    near_len, near_off, far_len, far_off = find_matches(r)
    SC = 1 << 20
    cost = [0] * (n + 1)
    choice = [None] * (n + 1)
    win = deque()        # candidate literal-run ends j, increasing cost[j] + j*SC
    for i in range(n - 1, -1, -1):
        j = i + 1
        fj = cost[j] + j * SC
        while win and cost[win[-1]] + win[-1] * SC >= fj:
            win.pop()
        win.append(j)
        while win[0] > i + MAXLIT:
            win.popleft()
        j = win[0]
        best = cost[j] + (j - i + 1) * SC + 1
        ch = ('L', j - i)
        nl = near_len[i]
        for ln in range(MINLEN, nl + 1):
            c = cost[i + ln] + 2 * SC + 1
            if c < best:
                best, ch = c, ('N', ln, near_off[i])
        for ln in range(max(MINLEN, nl + 1), far_len[i] + 1):
            c = cost[i + ln] + 3 * SC + 1
            if c < best:
                best, ch = c, ('F', ln, far_off[i])
        cost[i] = best
        choice[i] = ch
    tokens = []
    i = 0
    while i < n:
        ch = choice[i]
        if ch[0] == 'L':
            tokens.append(('L', r[i:i + ch[1]]))
            i += ch[1]
        else:
            tokens.append(ch)
            i += ch[1]
    return tokens


def encode(tok):
    """Token bytes in reading order, and the number of output bytes."""
    if tok[0] == 'L':
        return bytes([len(tok[1])]) + tok[1], len(tok[1])
    kind, ln, off = tok
    if kind == 'N':
        return bytes([0x80 | (ln - MINLEN), off - 1]), ln
    return bytes([0xc0 | (ln - MINLEN), (off - 1) >> 8, (off - 1) & 0xff]), ln


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

class PackError(Exception):
    pass


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


LOW_BUF = 0x0334     # $0334-$03ff: unused + tape buffer, below are the vectors


def find_buffer(load, pend, fend, c):
    """Address for the c byte segment 2 buffer, outside the payload and the
    loaded file ($0801..fend).  $0400 and up is tried first; if nothing fits
    there, the buffer may also start in $0334-$03ff."""
    def ok(b, floor):
        return (b >= floor and b + c <= 0x10000 and
                not overlaps(b, b + c, load, pend) and
                not overlaps(b, b + c, 0x0801, fend))
    cands = [max(pend, fend), pend, load - c, fend, 0x0400]
    B = next((b for b in cands if ok(b, 0x0400)), None)
    if B is None:
        B = next((b for b in (load - c, 0x0801 - c, LOW_BUF) if ok(b, LOW_BUF)), None)
    return B


def pack(data, load, start=None, verbose=True, slow=False):
    n = len(data)
    pend = load + n
    if n == 0:
        raise PackError('empty payload')
    if load < 0x0200:
        raise PackError('payload overlaps zero page / stack page (depacker lives at $0100)')
    if pend > 0x10000:
        raise PackError('payload runs past $ffff')

    if start is None:
        if load == 0x0801:
            mode = 'basic'
        else:
            mode = 'jmp'
            start = load
            print('warning: no start address given and payload is not at $0801, '
                  'will JMP $%04x' % load, file=sys.stderr)
    else:
        mode = 'jmp'
    if slow:
        return pack_slow(data, load, start, mode, verbose)

    tokens = parse(data[::-1])
    enc = [encode(t) for t in tokens]
    qs = [0]   # stream bytes consumed before token j
    os_ = [0]  # output bytes produced before token j
    for b, o in enc:
        qs.append(qs[-1] + len(b))
        os_.append(os_[-1] + o)
    ntok = len(tokens)
    m = qs[-1] + 2   # two end-of-segment markers

    # Fixed code sizes (all patched values are immediates / absolutes).
    dummy = dict(src=ZP_SRC, dst=ZP_DST, mp=ZP_MP, DEPACK_ORG=DEPACK_ORG,
                 DLEN=1, DFILE=0x1000, P=0x1000, B=0x1000, CPAGES=0, CREST=0,
                 S1TOP=0x1000, DTOP=0x1000, S2TOP=0x1000, START=0x1000,
                 PEND=0x1000, next=0x1000)
    tail = DONE_BASIC if mode == 'basic' else DONE_JMP
    depack, dlabels = assemble(ENDSEG_SRC + tail + DEPACK_SRC, DEPACK_ORG, dummy)
    boot, _ = assemble(BOOT_SRC, BOOT_ORG, dummy)
    dlen = len(depack)
    if DEPACK_ORG + dlen > 0x01e0:   # keep clear of the live stack (SP is ~$f6 after SYS)
        raise PackError('internal: depacker too large')
    P = BOOT_ORG + len(boot)
    file_end = P + m + dlen
    if file_end > 0xd000:
        raise PackError('packed file would load past $cfff (%04x)' % file_end)
    if overlaps(load, pend, DEPACK_ORG, DEPACK_ORG + dlen):
        raise PackError('payload overlaps depacker at $%04x' % DEPACK_ORG)

    dtop = pend - 1          # dst pointer before decoding (byte below decoded data)
    s1top = P + m - 1        # first token

    def seg2_size(k):
        return m - (qs[k] + 1)

    def valid(k):
        # Segment 1 = tokens[:k] + end marker, decoded in place from the file.
        lo = P + seg2_size(k)    # lowest byte of segment 1
        for j in range(k):
            dprev = dtop - os_[j]
            dnext = dtop - os_[j + 1]
            snext = s1top - qs[j + 1]
            # writes stay above everything unread, or below segment 1 entirely
            if not (dnext >= snext or dprev < lo):
                return False
        return True

    lo_k, hi_k = 0, ntok
    while lo_k < hi_k:
        mid = (lo_k + hi_k + 1) // 2
        if valid(mid):
            lo_k = mid
        else:
            hi_k = mid - 1
    k = lo_k
    c = seg2_size(k)

    # Buffer for segment 2: outside payload, outside the loaded file
    # ($0801..stream end), above $03ff and below $10000.
    B = find_buffer(load, pend, P + m, c)
    if B is None:
        raise PackError('no room for the %d byte tail buffer' % c)

    seg1 = bytes(b for e, _ in enc[:k] for b in e) + b'\x00'
    seg2 = bytes(b for e, _ in enc[k:] for b in e) + b'\x00'
    stream = seg2[::-1] + seg1[::-1]
    assert len(stream) == m and len(seg2) == c

    syms = dict(src=ZP_SRC, dst=ZP_DST, mp=ZP_MP, DEPACK_ORG=DEPACK_ORG,
                DLEN=dlen, DFILE=P + m, P=P, B=B, CPAGES=c >> 8, CREST=c & 0xff,
                S1TOP=s1top, DTOP=dtop, S2TOP=B + c - 1, START=start or 0,
                PEND=pend)
    depack, dlabels = assemble(ENDSEG_SRC + tail + DEPACK_SRC, DEPACK_ORG, syms)
    syms['next'] = dlabels['next']
    boot, _ = assemble(BOOT_SRC, BOOT_ORG, syms)
    assert len(depack) == dlen and BOOT_ORG + len(boot) == P

    prg = bytes([0x01, 0x08]) + basic_line() + boot + stream + depack

    info = dict(load=load, end=pend, packed=len(prg), tokens=ntok, seg2=c,
                buffer=B, mode=mode, start=start, P=P, m=m, dlen=dlen)
    if verbose:
        print('payload  $%04x-$%04x (%d bytes)' % (load, pend - 1, n))
        print('packed   %d bytes (%.1f%%), %d tokens' % (len(prg), 100.0 * len(prg) / (n + 2), ntok))
        print('in place %d bytes, %d byte tail -> buffer $%04x-$%04x' % (m - c, c, B, B + c - 1))
        print('start    %s' % ('BASIC RUN' if mode == 'basic' else 'JMP $%04x' % start))
    verify(prg, data, load, syms)
    if verbose and len(prg) > n + 2:
        print('warning: output is larger than input (already packed?)', file=sys.stderr)
    return prg, info


def verify(prg, data, load, syms):
    """Simulate the boot code and depacker on a full 64K memory image.

    Everything is done in memory exactly as on the C64, so a stream byte that
    gets overwritten before it is read shows up as a mismatch.
    """
    mem = bytearray(0x10000)
    body = prg[2:]
    mem[0x0801:0x0801 + len(body)] = body
    dlen = syms['DLEN']
    mem[DEPACK_ORG:DEPACK_ORG + dlen] = mem[syms['DFILE']:syms['DFILE'] + dlen]
    cnt = syms['CPAGES'] * 256 + syms['CREST']
    p, b = syms['P'], syms['B']
    mem[b:b + cnt] = mem[p:p + cnt]
    s, d = syms['S1TOP'], syms['DTOP']
    seg = 0
    while True:
        t = mem[s]
        if t == 0:
            if seg:
                break
            seg = 1
            s = syms['S2TOP']
            continue
        if t < 0x80:
            s -= t + 1
            d -= t
            for y in range(t, 0, -1):
                mem[d + y] = mem[s + y]
            continue
        ln = (t & 0x3f) + 3
        if t < 0xc0:
            s -= 2
            off = mem[s + 1] + 1
        else:
            s -= 3
            off = (mem[s + 1] | (mem[s + 2] << 8)) + 1
        d -= ln
        mp = d + off
        for y in range(ln, 0, -1):
            mem[d + y] = mem[mp + y]
    if d != load - 1:
        raise PackError('internal: verify ended at $%04x' % d)
    if bytes(mem[load:load + len(data)]) != data:
        raise PackError('internal: verify mismatch')


# ---------------------------------------------------------------------------
# -slow: bit-stream format, smaller output, slower decode
# ---------------------------------------------------------------------------
#
# Read in the same backward direction as the fast format and laid out in the
# same two segments, but tokens are made of bits (fetched MSB first, 8 per
# byte, a bit byte is fetched when the previous one runs out) mixed with plain
# bytes.  Elias gamma: v=1; while bit: v = v*2 + bit.
#
#   after a literal run:  0 = repeat-offset match: gamma(len)
#                         1 = new-offset match
#   otherwise:            0 = literal run: gamma(len), len bytes
#                         1 = new-offset match
#   new-offset match:     gamma(hi+1), byte lo, gamma(len-1)
#                         offset = hi*256+lo+1; gamma(hi+1) == 255 ends a segment
# Decoding starts in the "otherwise" state, also after a segment switch.

SLOW_ZP = dict(src=ZP_SRC, dst=ZP_DST, frm=0xf9, len=0xf7, off=0x22, tmp=0x24, bitbuf=0x02)
SLOW_MAXOFF = 254 * 256
SLOW_MAXLEN = 65535
SLOW_DEPTH = 192
SLOW_ENUM = 80       # match lengths tried exhaustively, longer ones only at their maximum
SLOW_GOOD = 1024     # stop searching once a match this long is found

SLOW_ORG = 0x0120    # stack lives at $0100-$011f while unpacking, code may run
SLOW_END = 0x0259    # into the BASIC input buffer ($0200-$0258)

SLOW_BOOT_SRC = BOOT_SRC.replace("        sei\n", "        sei\n        ldx #$1f\n        txs\n", 1).replace("""
        ldx #DLEN
mv:     lda DFILE-1,x
        sta DEPACK_ORG-1,x
        dex
        bne mv
""", """
        ldx #0
mv:     lda DFILE,x
        sta DEPACK_ORG,x
        inx
        bne mv
        ldx #DLEN-256
mv2:    lda DFILE+255,x
        sta DEPACK_ORG+255,x
        dex
        bne mv2
""")
assert 'mv2' in SLOW_BOOT_SRC

SLOW_HEAD_SRC = """
next:   lda #$80
        sta bitbuf
        lda #1
        sta off
        lda #0
        sta off+1
        jmp disp
endseg: lda flag
        bne done
        inc flag
        lda #<S2TOP
        sta src
        lda #>S2TOP
        sta src+1
        lda #$80
        sta bitbuf
        jmp disp
done:   lda #$37
        sta $01
        lda #0
        sta $d030           ; back to 1 MHz
        lda $d011
        and #$7f
        ora #$10            ; screen on
        sta $d011
        ldx #$f6            ; stack pointer as after SYS
        txs
        cli
"""

SLOW_DEPACK_SRC = """
lit:    jsr gamma           ; literal run
        lda src
        sta frm
        lda src+1
        sta frm+1
        jsr copyn
        lda frm
        sta src
        lda frm+1
        sta src+1
        asl bitbuf
        bne l3
        jsr refill
l3:     bcs newoff
        jsr gamma           ; repeat-offset match
        jsr mcopy
disp:   asl bitbuf
        bne d1
        jsr refill
d1:     bcc lit
newoff: jsr gamma
        cpx #255
        bne noend
        jmp endseg          ; gamma 255 = end of segment
noend:  dex
        stx off+1
        ldy #0
        lda (src),y
        sta off
        lda src
        bne n0
        dec src+1
n0:     dec src
        inc off             ; offset = hi*256 + lo + 1
        bne n1
        inc off+1
n1:     jsr gamma
        inx                 ; length = gamma + 1
        bne n2
        inc len+1
n2:     jsr mcopy
        jmp disp
mcopy:  clc                 ; frm = dst + off
        lda dst
        adc off
        sta frm
        lda dst+1
        adc off+1
        sta frm+1
copyn:  lda len+1           ; copy X + 256*len+1 bytes down from frm to dst
        beq copyx
        stx len
cbl:    ldx #$ff
        lda len+1
        bne cb1
        ldx len
cb1:    txa
        eor #$ff
        sec
        adc len             ; len -= X
        sta len
        bcs cb2
        dec len+1
cb2:    jsr copyx
        lda len
        ora len+1
        bne cbl
        rts
copyx:  stx tmp             ; copy X (1-255) bytes
        sec
        lda frm
        sbc tmp
        sta frm
        bcs c1
        dec frm+1
c1:     sec
        lda dst
        sbc tmp
        sta dst
        bcs c2
        dec dst+1
c2:     ldy tmp
cl:     lda (frm),y
        sta (dst),y
        dey
        bne cl
        rts
gamma:  ldx #1              ; value: low byte in X, high byte in len+1
        lda #0
        sta len+1
g1:     asl bitbuf
        bne g2
        jsr refill
g2:     bcc gd
        asl bitbuf
        bne g3
        jsr refill
g3:     txa
        rol a
        tax
        rol len+1
        jmp g1
gd:     rts
refill: ldy #0              ; C=1 (sentinel) on entry
        lda (src),y
        rol a
        sta bitbuf
        lda src
        bne rf
        dec src+1
rf:     dec src
        rts
"""


_GAMMA_BITS = [0] + [2 * v.bit_length() - 1 for v in range(1, SLOW_MAXLEN + 2)]


def parse_slow(r):
    """Forward DP over two states per position (after literal / after match),
    each remembering its last offset.  Costs are in bits."""
    n = len(r)
    G = _GAMMA_BITS
    INF = float('inf')
    mc = [INF] * (n + 1)
    mo = [1] * (n + 1)
    mb = [None] * (n + 1)      # (from pos, from state, token)
    lc = [INF] * (n + 1)
    lo = [1] * (n + 1)
    lrun = [0] * (n + 1)
    lstart = [0] * (n + 1)
    mc[0] = 0
    head = {}
    prev = [-1] * n
    prevf = {}

    def mlen(p, i, cap):
        ln = 0
        while ln + 32 <= cap and r[p + ln:p + ln + 32] == r[i + ln:i + ln + 32]:
            ln += 32
        while ln < cap and r[p + ln] == r[i + ln]:
            ln += 1
        return ln

    for i in range(n):
        cap = min(SLOW_MAXLEN, n - i)
        # literal state at i+1
        c = mc[i] + 1 + G[1] + 8
        lc[i + 1], lo[i + 1], lrun[i + 1], lstart[i + 1] = c, mo[i], 1, i
        if lc[i] < INF:
            k = lrun[i]
            c = lc[i] + G[k + 1] - G[k] + 8
            if c < lc[i + 1]:
                lc[i + 1], lo[i + 1], lrun[i + 1], lstart[i + 1] = c, lo[i], k + 1, lstart[i]

        # match candidates: nearest offsets first, keep only longer ones
        entries = []
        curf = {}
        if i + 1 < n:
            key = r[i:i + 2]
            p = head.get(key, -1)
            prev[i] = p
            head[key] = i
            best = 1
            depth = 0
            while p >= 0 and depth < SLOW_DEPTH and best < cap and best < SLOW_GOOD:
                off = i - p
                if off > SLOW_MAXOFF:
                    break
                pl = prevf.get(off)
                if pl is not None:
                    ln = pl - 1
                elif r[p + best] == r[i + best]:
                    ln = mlen(p, i, cap)
                else:
                    ln = 0
                if ln >= 2:
                    if ln < SLOW_MAXLEN:
                        curf[off] = ln
                    if ln > best:
                        entries.append((off, ln))
                        best = ln
                p = prev[p]
                depth += 1
        prevf = curf

        if lc[i] <= mc[i]:
            base, bstate = lc[i], 'L'
        else:
            base, bstate = mc[i], 'M'
        if base < INF:
            last = 1
            for off, ln in entries:
                hc = base + 1 + G[((off - 1) >> 8) + 1] + 8
                ls = list(range(last + 1, min(ln, SLOW_ENUM) + 1))
                if ln > SLOW_ENUM:
                    ls.append(ln)
                for l in ls:
                    c = hc + G[l - 1]
                    if c < mc[i + l]:
                        mc[i + l], mo[i + l], mb[i + l] = c, off, (i, bstate, ('N', l, off))
                last = ln

        # repeat-offset match, only directly after a literal run
        if lc[i] < INF and i - lo[i] >= 0:
            off = lo[i]
            ln = curf.get(off)
            if ln is None:
                ln = mlen(i - off, i, cap)
            ls = list(range(1, min(ln, SLOW_ENUM) + 1))
            if ln > SLOW_ENUM:
                ls.append(ln)
            for l in ls:
                c = lc[i] + 1 + G[l]
                if c < mc[i + l]:
                    mc[i + l], mo[i + l], mb[i + l] = c, off, (i, 'L', ('R', l, off))

    tokens = []
    pos, state = n, ('L' if lc[n] < mc[n] else 'M')
    while pos > 0:
        if state == 'L':
            s = lstart[pos]
            tokens.append(('L', r[s:pos]))
            pos, state = s, 'M'
        else:
            frm, fstate, tok = mb[pos]
            tokens.append(tok)
            pos, state = frm, fstate
    tokens.reverse()
    return tokens


class BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.mask = 0
        self.idx = 0

    def bit(self, b):
        if not self.mask:
            self.mask = 0x80
            self.idx = len(self.out)
            self.out.append(0)
        if b:
            self.out[self.idx] |= self.mask
        self.mask >>= 1

    def gamma(self, v):
        for ch in bin(v)[3:]:
            self.bit(1)
            self.bit(ch == '1')
        self.bit(0)


def encode_slow(tokens, off=1, marks=None):
    """One segment in reading order, end marker included.  marks, if given,
    receives the byte count consumed after each token."""
    bw = BitWriter()
    state = 'M'
    for tok in tokens:
        kind = tok[0]
        if kind == 'R' and state != 'L':
            kind = 'N'               # only possible at a segment start
        if kind == 'L':
            assert state == 'M'
            bw.bit(0)
            bw.gamma(len(tok[1]))
            bw.out += tok[1]
            state = 'L'
        elif kind == 'R':
            assert tok[2] == off
            bw.bit(0)
            bw.gamma(tok[1])
            state = 'M'
        else:
            ln, off = tok[1], tok[2]
            bw.bit(1)
            bw.gamma(((off - 1) >> 8) + 1)
            bw.out.append((off - 1) & 0xff)
            bw.gamma(ln - 1)
            state = 'M'
        if marks is not None:
            marks.append(len(bw.out))
    bw.bit(1)
    bw.gamma(255)
    return bytes(bw.out), off


def tok_len(tok):
    return len(tok[1]) if tok[0] == 'L' else tok[1]


def pack_slow(data, load, start, mode, verbose):
    n = len(data)
    pend = load + n
    tokens = parse_slow(data[::-1])
    ntok = len(tokens)
    qs = [0]                     # stream bytes consumed after token j-1
    encode_slow(tokens, 1, qs)
    os_ = [0]
    for t in tokens:
        os_.append(os_[-1] + tok_len(t))

    syms = dict(SLOW_ZP, DEPACK_ORG=SLOW_ORG, DLEN=257, DFILE=0x1000, P=0x1000, B=0x1000,
                CPAGES=0, CREST=0, S1TOP=0x1000, DTOP=0x1000, S2TOP=0x1000, START=0x1000,
                PEND=0x1000, next=0x1000)
    tail = DONE_BASIC if mode == 'basic' else DONE_JMP
    code = SLOW_HEAD_SRC + tail + SLOW_DEPACK_SRC
    depack, _ = assemble(code, SLOW_ORG, syms)
    if len(depack) < 257:            # the boot always copies more than one page
        code += '        .byte ' + ','.join(['0'] * (257 - len(depack))) + '\n'
        depack, _ = assemble(code, SLOW_ORG, syms)
    boot, _ = assemble(SLOW_BOOT_SRC, BOOT_ORG, syms)
    dlen = len(depack)
    if SLOW_ORG + dlen > SLOW_END:
        raise PackError('internal: slow depacker too large (%d bytes)' % dlen)
    if overlaps(load, pend, 0x0100, SLOW_ORG + dlen):
        raise PackError('payload overlaps depacker at $0100-$%04x' % (SLOW_ORG + dlen - 1))
    P = BOOT_ORG + len(boot)
    dtop = pend - 1

    def layout(k):
        seg1, off = encode_slow(tokens[:k])
        seg2, _ = encode_slow(tokens[k:], off)
        return seg1, seg2

    def valid(k):
        # same rule as the fast format: each token's writes stay above
        # everything still unread, or below segment 1 entirely
        seg1, seg2 = layout(k)
        lo_ = P + len(seg2)
        s1top = P + len(seg1) + len(seg2) - 1
        for j in range(k):
            dprev = dtop - os_[j]
            dnext = dtop - os_[j + 1]
            snext = s1top - qs[j + 1]
            if not (dnext >= snext or dprev < lo_):
                return False
        return True

    lo_k, hi_k = 0, ntok
    while lo_k < hi_k:
        mid = (lo_k + hi_k + 1) // 2
        if valid(mid):
            lo_k = mid
        else:
            hi_k = mid - 1
    k = lo_k
    seg1, seg2 = layout(k)
    m = len(seg1) + len(seg2)
    c = len(seg2)
    file_end = P + m + dlen
    if file_end > 0xd000:
        raise PackError('packed file would load past $cfff (%04x)' % file_end)

    B = find_buffer(load, pend, P + m, c)
    if B is None:
        raise PackError('no room for the %d byte tail buffer' % c)

    stream = seg2[::-1] + seg1[::-1]
    syms.update(DLEN=dlen, DFILE=P + m, P=P, B=B, CPAGES=c >> 8, CREST=c & 0xff,
                S1TOP=P + m - 1, DTOP=dtop, S2TOP=B + c - 1, START=start or 0, PEND=pend)
    depack, dlabels = assemble(code, SLOW_ORG, syms)
    syms['next'] = dlabels['next']
    boot, _ = assemble(SLOW_BOOT_SRC, BOOT_ORG, syms)
    assert len(depack) == dlen and BOOT_ORG + len(boot) == P
    prg = bytes([0x01, 0x08]) + basic_line() + boot + stream + depack

    info = dict(load=load, end=pend, packed=len(prg), tokens=ntok, seg2=c,
                buffer=B, mode=mode, start=start, P=P, m=m, dlen=dlen)
    if verbose:
        print('payload  $%04x-$%04x (%d bytes)' % (load, pend - 1, n))
        print('packed   %d bytes (%.1f%%), %d tokens, slow format'
              % (len(prg), 100.0 * len(prg) / (n + 2), ntok))
        print('in place %d bytes, %d byte tail -> buffer $%04x-$%04x' % (m - c, c, B, B + c - 1))
        print('start    %s' % ('BASIC RUN' if mode == 'basic' else 'JMP $%04x' % start))
    verify_slow(prg, data, load, syms)
    if verbose and len(prg) > n + 2:
        print('warning: output is larger than input (already packed?)', file=sys.stderr)
    return prg, info


def verify_slow(prg, data, load, syms):
    """Memory-level simulation of the slow depacker, like verify()."""
    mem = bytearray(0x10000)
    body = prg[2:]
    mem[0x0801:0x0801 + len(body)] = body
    dlen = syms['DLEN']
    mem[SLOW_ORG:SLOW_ORG + dlen] = mem[syms['DFILE']:syms['DFILE'] + dlen]
    cnt = syms['CPAGES'] * 256 + syms['CREST']
    mem[syms['B']:syms['B'] + cnt] = mem[syms['P']:syms['P'] + cnt]
    st = {'s': syms['S1TOP'], 'd': syms['DTOP'], 'buf': 0x80}

    def rdbyte():
        v = mem[st['s']]
        st['s'] -= 1
        return v

    def getbit():
        b = st['buf']
        c = b >> 7
        b = (b << 1) & 0xff
        if b == 0:
            v = rdbyte()
            c, b = v >> 7, ((v << 1) | c) & 0xff
        st['buf'] = b
        return c

    def gamma():
        v = 1
        while getbit():
            v = (v << 1) | getbit()
        return v & 0xffff

    def copy(frm, ln):
        d = st['d']
        for k in range(ln):
            mem[d - k] = mem[frm - k]
        st['d'] = d - ln

    off, seg, state = 1, 0, 'M'
    while True:
        if getbit() == 0:
            if state == 'M':
                ln = gamma()
                copy(st['s'], ln)
                st['s'] -= ln
                state = 'L'
            else:
                copy(st['d'] + off, gamma())
                state = 'M'
            continue
        v = gamma()
        if v == 255:
            if seg:
                break
            seg = 1
            st['s'], st['buf'], state = syms['S2TOP'], 0x80, 'M'
            continue
        off = (v - 1) * 256 + rdbyte() + 1
        copy(st['d'] + off, gamma() + 1)
        state = 'M'
    if st['d'] != load - 1:
        raise PackError('internal: slow verify ended at $%04x' % st['d'])
    if bytes(mem[load:load + len(data)]) != data:
        raise PackError('internal: slow verify mismatch')


def parse_addr(s):
    s = s.strip().lower()
    if s.startswith('$'):
        return int(s[1:], 16)
    if s.startswith('0x'):
        return int(s[2:], 16)
    return int(s, 10)


def main():
    ap = argparse.ArgumentParser(description='Fast-decompressing self-extracting packer for C64 PRG files.')
    ap.add_argument('input')
    ap.add_argument('output')
    ap.add_argument('start', nargs='?', help="start address (0xc000, 49152 or '$c000')")
    ap.add_argument('-s', '--start', dest='start_opt', help='start address (same as positional)')
    ap.add_argument('-slow', '--slow', action='store_true',
                    help='smaller output, slower to unpack (bit-stream format)')
    ap.add_argument('-noirq', '--noirq', action='store_true',
                    help='start the program with interrupts still off (SEI) and the CIA1 IRQ off and '
                         'acknowledged, for programs that overwrite the KERNAL vectors ($0314)')
    ap.add_argument('-verify', '--verify', action='store_true',
                    help='also run the real 6502 depacker in py65 and check the result')
    a = ap.parse_args()
    if a.noirq:
        global ENDSEG_SRC, SLOW_HEAD_SRC
        noirq = ('        lda #$7f\n'
                 '        sta $dc0d           ; no CIA1 IRQs\n'
                 '        lda $dc0d           ; ack\n')
        cli = '        cli\n'
        assert ENDSEG_SRC.count(cli) == 1 and SLOW_HEAD_SRC.count(cli) == 1
        ENDSEG_SRC = ENDSEG_SRC.replace(cli, noirq)
        SLOW_HEAD_SRC = SLOW_HEAD_SRC.replace(cli, noirq)
    st = a.start_opt or a.start
    start = parse_addr(st) if st else None
    if start is not None and not 0 <= start <= 0xffff:
        ap.error('start address out of range')
    raw = open(a.input, 'rb').read()
    if len(raw) < 3:
        ap.error('input is not a PRG file')
    load = raw[0] | (raw[1] << 8)
    try:
        prg, info = pack(raw[2:], load, start, slow=a.slow)
    except PackError as e:
        print('error: %s' % e, file=sys.stderr)
        sys.exit(1)
    if a.verify:
        try:
            from test_pack import verify_6502
        except ImportError as e:
            print('error: -verify needs test_pack.py and py65 (pip install py65): %s' % e,
                  file=sys.stderr)
            sys.exit(1)
        try:
            ok, cycles = verify_6502(prg, raw[2:], load, info)
        except RuntimeError as e:
            ok, cycles = False, None
            print('6502 run: %s' % e, file=sys.stderr)
        if not ok:
            print('error: 6502 verify failed, output not written', file=sys.stderr)
            sys.exit(1)
        print('verify   OK, 6502 depacker, %d cycles (%.1f s at 985248 Hz)'
              % (cycles, cycles / 985248.0))
    open(a.output, 'wb').write(prg)


if __name__ == '__main__':
    main()
