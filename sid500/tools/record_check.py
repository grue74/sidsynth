"""record_check.py - SID500 stage D: recording in real time, in VICE.

Builds TEST_SLAVE=11 programs with TEST_FEED_MASTER and TEST_RECORD: as
master, a test scene playing from the start, a take begun on one track as
the song plays (take.asm, as C= R would), and a played part (tables.py's
take_part, feed 11) fed into MIDI in through the real receive interrupt
(src/test_slave.asm). The log has each byte fed (LOG_RX), each message's
stamp (LOG_REC_STAMP: the music's pass the receive interrupt gave it), the
take's start, each merge's begin with the messages taken by then, the
publishes and live switches, the ticks and the bytes sent. Checked:

- every message stamped (aftertouch left out), each stamp the tick heard
  when its last byte came (the nearest: within one tick, most exact);
- the take as a model of take.asm makes it from the stamps (notes and
  their offs, controllers and bend thinned to a pass), each merge's
  records (those taken by its begin: finished and before the loop's end)
  put in the pattern as the model merges them (Overdub; Replace's first
  pass; Rec Quantize), its publish where the model has one;
- the player's bytes, the merges heard from their publishes on (the
  publishes and switches as logged), as the model's (play_check.Player);
- when each merge was published after the loop's end it took (heard on
  the next pass when its notes come after that), reported;
- the memory at the end: the pattern as the model's last merge encodes it
  (tables.encode), byte for byte, and the pool whole;
- with C= U after the take (TEST_REC_UNDO) and SHIFT+C= U (TEST_REC_REDO):
  each published, the pattern from before the take heard from the undo's
  publish, the take's again from the redo's; at the end the pattern and
  the kept chain (rec_before) the other way round when undone.

    python tools/record_check.py [--seconds S] [--run N] [--repeat K] [--keep]

--keep saves a failing run's log, memory and labels to work/ (pickle), and
--load checks such a file again (for finding what went wrong).
"""
import argparse
import os
import pickle
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402
import play_check as pc  # noqa: E402
import edit_check as ec  # noqa: E402  (the pool's chains)
import thru_check as th  # noqa: E402  (messages from stamped bytes)

LOG_RX, LOG_TX_THRU = 7, 22
LOG_REC_LOST, LOG_REC_STAMP, LOG_REC_START, LOG_REC_MERGE, LOG_REC_FINAL = 25, 26, 27, 28, 29
LOG_REC_END, LOG_REC_THIN = 30, 31
FEED = 11
STEP = tables.STEP
PLAYED_LAG_MAX = 5 * 985        # the player's added lag while a part is played into MIDI in
                                # (the user, 2026-11-23: 5 ms, reported; play_check's 3.2 ms
                                # is for playback alone): each byte's receive interrupt
                                # can't wait for a tick (no FIFO), and the test logs each
                                # byte and stamp there too. Measured: 2.8-4.0 ms with no
                                # take, 3.7-4.5 ms recording (the band, 120 BPM)
NEW_PATTERN = 8                 # the band leaves 8 the first free number

RUNS = [  # (name, scene, BPM, track (1-16), Record (0 overdub, 1 replace), Rec Quantize
          #  (0 off, 1 16th, 2 8th, 3 16th triplet), mode: "content" every byte logged,
          #  the log ~4 s; "whole" one byte in 8 (TEST_STAMP_FEW 2), the log the whole
          #  take: the memory at the end checked; the take ended from play tick n on
          #  (as C= R does: TEST_REC_END), 0 = not)
    ("the band, 120 BPM, a new pattern on track 9", 1, 120, 9, 0, 0, "content", 0),
    ("the band, 120 BPM, a new pattern on track 9", 1, 120, 9, 0, 0, "whole", 0),
    ("the band, 120 BPM, overdub on the lead (5 steps)", 1, 120, 4, 0, 0, "content", 0),
    ("the band, 120 BPM, overdub on the lead (5 steps)", 1, 120, 4, 0, 0, "whole", 0),
    ("the band, 200 BPM, overdub on the lead (5 steps)", 1, 200, 4, 0, 0, "whole", 800),
    ("the band, 120 BPM, replace on the bass (12 steps)", 1, 120, 2, 1, 0, "whole", 0),
    ("the band, 120 BPM, replace on the lead, 16th triplets", 1, 120, 4, 1, 3, "content", 0),
    ("the band, 120 BPM, a new pattern quantized to 16ths", 1, 120, 9, 0, 1, "whole", 0),
    ("the band, 120 BPM, replace on the bass, ended mid-part", 1, 120, 2, 1, 2, "whole", 380),
    # (C= U from play tick n, SHIFT+C= U from tick m: TEST_REC_UNDO, TEST_REC_REDO)
    ("the band, 120 BPM, overdub on the lead, undone and redone", 1, 120, 4, 0, 0,
     "content", 200, 260, 330),
    ("the band, 120 BPM, overdub on the lead, undone", 1, 120, 4, 0, 0, "whole", 380,
     500, 0),
    ("the band, 120 BPM, replace on the bass, undone and redone", 1, 120, 2, 1, 0, "whole",
     380, 500, 650),
    ("the band, 120 BPM, a new pattern on track 9, undone and redone", 1, 120, 9, 0, 0,
     "whole", 380, 500, 650),
    # (options: thru 0 = Thru off, the player's added lag measured; stop n = the song
    # stopped at play tick n, as SPACE: the take ends with it; iface "namesoft": NMI)
    ("the band, 120 BPM, overdub on the lead, Thru off: the player's lag", 1, 120, 4, 0, 0,
     "whole", 0, {"thru": 0}),
    ("the band, 200 BPM, replace on the bass, Thru off: the player's lag", 1, 200, 2, 1, 0,
     "whole", 800, {"thru": 0}),
    ("the band, 120 BPM, overdub on the lead, ended by a stop", 1, 120, 4, 0, 0,
     "whole", 0, {"stop": 380}),
    ("the band, 120 BPM, replace on the bass, ended by a stop mid-part", 1, 120, 2, 1, 0,
     "content", 0, {"stop": 300}),
    ("Namesoft (NMI), the band, 120 BPM, overdub on the lead", 1, 120, 4, 0, 0,
     "whole", 0, {"iface": "namesoft"}),
    ("Namesoft (NMI), the band, 120 BPM, a new pattern on track 9", 1, 120, 9, 0, 0,
     "content", 0, {"iface": "namesoft"}),
]


def build(out, scene, bpm, track, mode, quant, more=(), iface="datel"):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF[iface]}",
                    "-D", f"TEST_PLAY={scene}", "-D", f"TEST_SLAVE={FEED}",
                    "-D", "TEST_FEED_MASTER=1", "-D", f"TEST_TEMPO={bpm}",
                    "-D", f"TEST_RECORD={track}", "-D", f"TEST_REC_MODE={mode}",
                    "-D", f"TEST_REC_QUANT={quant}", *more,
                    "-o", out, "-l", out + ".lbl", "sid500.asm"],
                   cwd=ROOT, check=True)


def run(prg, seconds, ranges, whole=False, iface="datel", cut=True):
    """The log (as timing_check.run_log) and the memory ranges at the end.
    cut=False: both logs whole (not cut where the first ends: count_check.py,
    whose log B, the bytes sent, can end before anything is sent)."""
    start, size = tc.log_layout(prg)
    cmds = [f"m {start:04x} {start + 10 * size - 1:04x}"]
    cmds += [f"m {a:04x} {b - 1:04x}" for a, b in ranges] + ["r"]
    out = subprocess.run([sys.executable, os.path.join(tc.C64TOOLS, "vicepeek.py"), prg, *cmds,
                          "--seconds", str(seconds),
                          "--vice-args", f"{tc.VICE_ARGS[iface]} -ciamodel 1"],
                         capture_output=True, text=True, check=True).stdout
    mem = {"regs": [l for l in out.splitlines() if "PC" in l or l.startswith(".;")]}
    for line in out.splitlines():
        m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+){1,16})", line)
        if m:
            for i, b in enumerate(m.group(2).split()):
                mem[int(m.group(1), 16) + i] = int(b, 16)
    data = bytes(mem[start + i] for i in range(10 * size))
    log_a, log_b = tc.read_log(data, 0, size), tc.read_log(data, 5 * size, size)
    ends = [lg[-1][2] for lg in (log_a, log_b) if lg]
    end = (min(ends) if cut else max(ends)) if ends else 0
    # "whole" runs (the log the whole take): the main loop's entries in log
    # A kept past log B's end (log B, every byte fed and stamped, can fill
    # first: a late publish was lost with it)
    keep = {pc.LOG_PUBLISH, pc.LOG_SWITCH, pc.LOG_FREED, LOG_REC_START, LOG_REC_MERGE,
            LOG_REC_FINAL, LOG_REC_END} if whole else set()
    log = sorted((e for e in log_a + log_b if e[2] <= end or e[0] in keep),
                 key=lambda e: e[2])
    t0 = log[0][2] if log else 0
    return [(k, v, t - t0) for k, v, t in log], mem


LEN_TABLE = [3, 6, 8, 9, 12, 16, 18, 24, 32, 36, 48, 72, 96, 192]   # design 3


def decode(data):
    """A stream's events (tables' form) up to its end ($FF), as the
    player reads it; a byte no event starts with ends it too."""
    out, i, t, vel, length, cc = [], 0, 0, 100, 12, 1
    while i < len(data):
        b = data[i]
        i += 1
        if b == 0xFF:
            break
        if b >= 0xF0:
            b = (b - 0xF0) << 8 | data[i]
            i += 1
        t += b
        while True:
            e = data[i]
            i += 1
            if 0x80 <= e <= 0x8D:
                length = LEN_TABLE[e - 0x80]
            elif e == 0x8E:
                length, i = data[i], i + 1
            elif e == 0x8F:
                length, i = data[i] | data[i + 1] << 8, i + 2
            elif e == 0x90:
                vel, i = data[i], i + 1
            else:
                break
        if e < 0x80:
            out.append((t, "note", e, vel, length))
        elif e == 0x91:
            cc = data[i]
            out.append((t, "cc", cc, data[i + 1]))
            i += 2
        elif e == 0x92:
            out.append((t, "cc", cc, data[i]))
            i += 1
        elif e == 0x93:
            out.append((t, "bend", data[i], data[i + 1]))
            i += 2
        elif e == 0x94:
            out.append((t, "program", data[i]))
            i += 1
        else:
            out.append((t, "bad", e))
            break
    return out


def pairs(log, kind):
    v = [v for k, v, _ in log if k == kind]
    return [v[i] | v[i + 1] << 8 for i in range(0, len(v) - 1, 2)]


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


class Take:
    """take.asm's take: records [pass, kind, d1, d2, vel, length] (a note
    held: length 0), merged into the pattern's events (tables' form)."""

    def __init__(self, plen, m0, mode, quant, events):
        self.plen, self.m0, self.mode = plen, m0, mode
        self.grid = [0, STEP, 2 * STEP, STEP * 2 // 3][quant]
        self.records = []
        self.events = list(events)

    def take(self, msg, stamp):
        st, kind = msg[0], msg[0] & 0xF0
        if kind == 0x90 and msg[2]:
            self.records.append([stamp, "note", msg[1], msg[2], msg[2], 0])
        elif kind in (0x80, 0x90):
            for r in reversed(self.records):
                if r[1] == "note" and r[2] == msg[1] and r[5] == 0:
                    r[5] = max(1, s16(stamp - r[0]))
                    break
        elif kind == 0xC0:
            self.records.append([stamp, "program", msg[1], 0xFF, 0xFF, 0])
        else:
            k = "cc" if kind == 0xB0 else "bend"
            last = self.records[-1] if self.records else None
            if (last and last[0] == stamp and last[1] == k
                    and (k == "bend" or last[2] == msg[1])):
                last[2], last[3] = msg[1], msg[2]
            else:
                self.records.append([stamp, k, msg[1], msg[2], msg[2], 0])

    def close(self, last):
        """The take ended (take.asm rec_end): each note held given its
        length to the last pass heard."""
        for r in self.records:
            if r[1] == "note" and r[5] == 0:
                r[5] = max(1, s16(last - r[0]))

    def place(self, r, d):
        d %= self.plen
        if r[1] == "note" and self.grid:
            rem = d % self.grid
            d -= rem
            if 2 * rem >= self.grid:
                d += self.grid
            d %= self.plen
        return d

    def merge(self, origin, ending=False, last=0):
        """One merge (take.asm rec_collect, rec_sort, rec_encode): the
        pattern's new events, or None when nothing is published."""
        plen = self.plen
        due, keep = [], []
        for r in self.records:
            d = s16(r[0] - origin)
            if ending or (d < plen and (r[1] != "note" or r[5])):
                due.append((self.place(r, d), r))
            else:
                keep.append(r)
        self.records = keep
        due.sort(key=lambda e: e[0])            # (stable: equal places in order)
        lo = hi = wrap = 0
        if self.mode:
            a = s16(self.m0 - origin)
            lo = max(a, 0)
            to = s16(last - origin) if ending else plen
            lim = a + plen
            if lim >= 0:
                to = min(to, lim)
                if to >= 0:
                    if to - plen >= 0:
                        wrap, to = to - plen, plen
                    hi = to
                else:
                    lo = 0
            else:
                lo = 0
        if not due and not hi and not wrap:
            return None
        old = [e for e in self.events
               if not (e[0] < wrap or lo <= e[0] < hi)]
        new = [self.event(p, r) for p, r in due]
        out, i, j = [], 0, 0
        while i < len(old) or j < len(new):
            if j == len(new) or (i < len(old) and old[i][0] <= new[j][0]):
                out.append(old[i])
                i += 1
            else:
                out.append(new[j])
                j += 1
        self.events = out
        return out

    @staticmethod
    def event(p, r):
        if r[1] == "note":
            return (p, "note", r[2], r[4], r[5])
        if r[1] == "program":
            return (p, "program", r[2])
        return (p, r[1], r[2], r[3])


def check(name, scene, bpm, track, mode, quant, kind, log, mem, undo=0, redo=0):
    errors = []
    patterns, tracks, order = tables.SCENES[scene]()
    pattern = tracks[track - 1][0]
    if pattern is None:
        pattern = NEW_PATTERN
        patterns = {**patterns, pattern: (16, [])}
    steps, events = patterns[pattern]
    plen = steps * STEP

    # the messages fed and their stamps
    fed = th.stamped_messages([(v, t, 0) for k, v, t in log if k == LOG_RX])
    fed = [(m, t) for m, t, _ in fed if m[0] & 0xF0 not in (0xA0, 0xD0)]
    # each message's stamp in order; a thinned one (LOG_REC_THIN) replaced
    # the newest message waiting in the ring (take.asm rec_put)
    marks = [(k, v) for k, v, _ in log if k in (LOG_REC_STAMP, LOG_REC_THIN)]
    seq = [(marks[i][0], marks[i][1] | marks[i + 1][1] << 8)
           for i in range(0, len(marks) - 1, 2)]
    stamps = [x for _, x in seq]
    lost = [v for k, v, _ in log if k == LOG_REC_LOST]
    if lost:
        errors.append(f"messages lost: {[(w, lost.count(i)) for i, w in ((1, 'the ring full'), (2, 'the take full'), (3, 'the pool full')) if i in lost]}")
    starts = pairs(log, LOG_REC_START)
    if len(starts) != 1:
        return errors + [f"{len(starts)} takes begun"]
    m0 = starts[0]
    ends = pairs(log, LOG_REC_END)
    if not ends and len(stamps) != len(fed):    # (the take begins before the part)
        errors.append(f"{len(fed) - len(stamps)} of {len(fed)} messages not stamped")
    fed = fed[:len(stamps)]
    ring = []                                   # the ring's messages as taken
    for (m, _), (k, x) in zip(fed, seq):
        if k == LOG_REC_THIN:
            ring[-1] = (m, x)
        else:
            ring.append((m, x))
    thinned = len(fed) - len(ring)

    # each stamp the tick heard: the nearest to its last byte's time
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    first = next(i for i, t in enumerate(ticks) if t > start)
    song = ticks[first:]
    period = tables.tick_cycles(bpm)
    # stopped (TEST_REC_STOP): the player's bytes up to MIDI stop (its note
    # offs after it are the transport's: transport_check.py)
    stopped = next((t for v, t in sent if v == tc.STOP), None)
    if stopped is not None:
        song = [t for t in song if t < stopped]
        sent = [(v, t) for v, t in sent if t < stopped]
        if not ends:
            errors.append("stopped, and the take not ended")
    exact, off = 0, []
    for (m, t), s in zip(fed, stamps):
        k = max(0, next((i for i, x in enumerate(song) if x > t), len(song)) - 1)
        if t - song[k] > period / 2:
            k += 1
        off.append(s16(s - k))
        exact += s == k
    if off and max(abs(o) for o in off) > 1:
        bad = [(i, fed[i][0], o) for i, o in enumerate(off) if abs(o) > 1]
        errors.append(f"stamps off the tick heard by {min(off)}..{max(off)}: "
                      f"{ {o: off.count(o) for o in sorted(set(off))} }, {bad[:6]}")

    # the take and its merges, as the model makes them
    tk = Take(plen, m0, mode, quant, events)
    origin = (m0 - m0 % plen) & 0xFFFF
    merges = [(k, v) for k, v, _ in log if k in (LOG_REC_MERGE, LOG_REC_FINAL)]
    taken, n_prev, published = 0, 0, []
    for mk, v in merges:
        n = n_prev + ((v - n_prev) & 0xFF)
        n_prev = n
        while taken < n and taken < len(ring):
            tk.take(*ring[taken])
            taken += 1
        if mk == LOG_REC_FINAL:
            tk.close(ends[0] if ends else 0)
        out = tk.merge(origin, ending=mk == LOG_REC_FINAL, last=ends[0] if ends else 0)
        origin = (origin + plen) & 0xFFFF
        if out is not None:
            published.append(list(out))

    # the publishes logged: the record pattern's, one for each the model has
    v = [v for k, v, _ in log if k == pc.LOG_PUBLISH]
    pubs_log = [(v[i + 1] | v[i + 2] << 8, v[i + 3], v[i]) for i in range(0, len(v) - 4, 5)]
    if any(p[2] != pattern for p in pubs_log):
        others = [p for p in pubs_log if p[2] != pattern]
        if not (pattern == NEW_PATTERN and len(others) == 0):
            errors.append(f"publishes of other patterns: {others}")
    rec_pubs = [p for p in pubs_log if p[2] == pattern]
    if pattern == NEW_PATTERN and not rec_pubs:
        return errors + ["the new pattern never published"]
    # what each publish holds: (the new pattern's, empty, first), each merge's,
    # then C= U's (the pattern before the take) and SHIFT+C= U's (the take's)
    before = (16, []) if pattern == NEW_PATTERN else (steps, events)
    contents = ([before] if pattern == NEW_PATTERN else []) + [(steps, e) for e in published]
    taken_out = (steps, published[-1]) if published else before
    contents += [before] * bool(undo) + [taken_out] * bool(redo)
    rec_pubs = [(*p, c) for p, c in zip(rec_pubs, contents)]
    n_model = len(contents)
    n_log = len([p for p in pubs_log if p[2] == pattern])
    if merges and merges[-1][0] != LOG_REC_FINAL and n_log == n_model - 1 and not undo:
        n_model -= 1                            # (the last merge begun as the log ended)
    if n_log != n_model:
        errors.append(f"{n_log} publishes logged, the model's merges {n_model}")

    # the player's bytes: the merges heard as published
    made = pc.switches(log)
    player = pc.Player({k: p for k, p in patterns.items() if k != NEW_PATTERN or
                        tracks[track - 1][0] is not None}, tracks, order, switches=made,
                       publishes=[(m, place, pat, pe, 0) for m, place, pat, pe in rec_pubs])
    expect, at_tick = [], []
    for k in range(len(song)):
        b = player.play()
        expect += b
        at_tick += [k] * len(b)
    got = [v for v, _ in sent if v not in (tc.START, tc.CLOCK)]
    if kind == "content":
        got_m, exp_m = pc.messages(got), pc.messages(expect)
        m = min(len(got_m), len(exp_m))
        sent_note = f"{len(got_m)} messages sent as the model's"
        if got_m[:m] != exp_m[:m]:
            i = next(i for i in range(m) if got_m[i] != exp_m[i])
            errors.append(f"message {i} is {got_m[i]}, the model's {exp_m[i]}: "
                          f"{got_m[max(0, i - 3):i + 3]} / {exp_m[max(0, i - 3):i + 3]}")
    else:                                       # (one byte in 8 stamped)
        # a thru message sent between a tick's parts (the renderer behind:
        # record.asm commit_release) makes the player's next message carry
        # its status again, a byte the model (no thru) hasn't: the samples
        # then match one byte on. Allowed only with a thru byte sent since
        # the last sample that matched, and the next ones matching too.
        got_t = [t for v, t in sent if v not in (tc.START, tc.CLOCK)]
        thru_t = [t for k, _, t in log if k == LOG_TX_THRU]
        extra, last_ok = 0, 0
        for j, v in enumerate(got):
            i = (j + 1) * pc.STAMP_EVERY - 1 - extra
            if i >= len(expect):
                break
            if v == expect[i]:
                last_ok = got_t[j]
                continue
            ahead = [(jj, (jj + 1) * pc.STAMP_EVERY - 2 - extra) for jj in range(j, j + 4)]
            if (any(last_ok <= t <= got_t[j] for t in thru_t)
                    and all(jj >= len(got) or ii >= len(expect) or got[jj] == expect[ii]
                            for jj, ii in ahead)):
                extra += 1
                last_ok = got_t[j]
                continue
            errors.append(f"stamped byte {i + extra} is {v:02x}, the model's {expect[i]:02x}")
            break
        sent_note = (f"{len(got)} bytes stamped (one in {pc.STAMP_EVERY}) as the model's"
                     + (f" ({extra} running status bytes again after thru between a "
                        f"tick's parts)" if extra else ""))
        if not thru_t:
            # Thru off: the lag the player adds while recording and merging,
            # as play_check.py --sparse measures it (a tick's bytes ready at
            # its stamp, a byte every 283 cycles, the clocks in their slots)
            clocks = [t for v, t in sent if v == tc.CLOCK]
            ready, wire, c = [], 0, 0
            for k in at_tick:
                r = max(song[k], wire)
                while c < len(clocks) and clocks[c] <= r:
                    wire = max(wire, clocks[c]) + tc.BYTE_CYCLES
                    r = max(song[k], wire)
                    c += 1
                ready.append(r)
                wire = r + tc.BYTE_CYCLES
            lags = sorted(((t - ready[(j + 1) * pc.STAMP_EVERY - 1], t)
                           for j, t in enumerate(got_t)
                           if (j + 1) * pc.STAMP_EVERY - 1 < len(ready)), reverse=True)
            worst = lags[0][0] if lags else 0
            if os.environ.get("REC_LAG_DEBUG"):
                for lag, t in lags[:6]:
                    near = [(k, v, round((tt - t) / 985.2, 1)) for k, v, tt in log
                            if -12000 < tt - t < 1000 and k not in (tc.LOG_TX, tc.LOG_TICK)]
                    print(f"   lag {lag} at {t / 985248:.2f} s: {near[:14]}")
            sent_note += f"; the player's added lag at most {worst} cycles ({worst / 985.248:.2f} ms)"
            if worst > PLAYED_LAG_MAX:
                errors.append(f"a byte went out {worst} cycles later than the wire allows "
                              f"(with a part played in: {PLAYED_LAG_MAX})")

    # when each merge was published: passes after the loop's end before it
    o0 = m0 - m0 % plen
    passes = [m for m, *_ in [p for p in pubs_log if p[2] == pattern][
        1 if pattern == NEW_PATTERN else 0:]]
    passes = passes[:len(published)]           # (not C= U's and SHIFT+C= U's)
    if any(mk == LOG_REC_FINAL for mk, _ in merges) and published and passes:
        passes = passes[:-1]                    # (the last merge's: at the take's end)
    late = [((m - o0) % plen) * 60000 / (bpm * tables.TICKS_PER_QUARTER) for m in passes]
    note = (f"{len(stamps)} messages stamped ({exact} on the nearest tick, {thinned} "
            f"thinned in the ring), "
            f"{len(merges)} merges, {len(published)} published"
            + (f" {min(late):.0f}..{max(late):.0f} ms after their loop's end" if late else "")
            + f", {len(made)} switches, {sent_note}")
    print(f"{name}, {kind}: {note}")
    if kind == "content":
        return errors

    # the memory at the end: the pattern as the model's last merge (the log
    # saw the take through: every record merged, a loop more), the pool whole
    if tk.records:
        errors.append(f"the log ends with {len(tk.records)} records not merged")
    if ends and not any(k == LOG_REC_FINAL for k, _ in merges):
        errors.append("the take ended without its last merge")
    last_rx = max(t for k, _, t in log if k == LOG_RX)
    if not ends and song[-1] - last_rx < 2 * plen * period:
        errors.append("the log ends too soon after the part")   # (ended: its last merge)
    first_blk = mem[ec.PAT_FIRST_LO + pattern] | mem[ec.PAT_FIRST_HI + pattern] << 8
    kept_blk = mem[LAB["rec_before"]] | mem[LAB["rec_before"] + 1] << 8
    merged, old = tables.encode(tk.events), tables.encode(before[1])
    undone = bool(undo) and not redo
    for what, blk, want in (("the pattern at the end", first_blk, old if undone else merged),
                            ("the chain kept", kept_blk, merged if undone else old)):
        if not blk:
            continue                            # (none kept: below)
        _, data = ec.chain(mem, blk)
        if data[:len(want)] != want:
            i = next(i for i in range(len(want)) if i >= len(data) or data[i] != want[i])
            errors.append(f"{what} isn't the model's "
                          f"{'pattern before the take' if (want is old) else 'last merge'} "
                          f"({len(want)} bytes), from byte {i}: {bytes(data[i:i + 24]).hex()} / "
                          f"{bytes(want[i:i + 24]).hex()}")
    # every block a pattern's, the chain kept from before the take, a
    # replaced chain not yet freed, or free; once each
    chains = [(f"pattern {p}", mem[ec.PAT_FIRST_LO + p] | mem[ec.PAT_FIRST_HI + p] << 8)
              for p in range(ec.PATTERNS) if mem[ec.PAT_STEPS + p]]
    if not kept_blk:
        errors.append("no chain kept from before the take (or the take's, undone)")
    chains.append(("the chain kept", kept_blk))
    chains += [("a replaced chain", mem[LAB["retire_lo"] + i] | mem[LAB["retire_hi"] + i] << 8)
               for i in range(mem[LAB["retire_count"]])]
    owner, used = {}, 0
    for what, first_b in chains:
        for blk in ec.chain(mem, first_b)[0] if first_b else []:
            if blk in owner:
                errors.append(f"block {blk:04x} {what}'s and {owner[blk]}'s")
            owner[blk] = what
            used += 1
    free_blocks = ec.chain(mem, ec.word(mem, LAB["free_head"]))[0]
    for blk in free_blocks:
        if blk in owner:
            errors.append(f"free block {blk:04x} is also {owner[blk]}'s")
        owner[blk] = "free"
    total = (ec.POOL_END - ec.POOL_START) // ec.BLOCK
    free_count = ec.word(mem, LAB["free_head"] + 2)
    if len(owner) != total:
        errors.append(f"the pool: {total - len(owner)} blocks lost")
    if len(free_blocks) != free_count or free_count != total - used:
        errors.append(f"the pool: free_count {free_count}, the free list {len(free_blocks)}, "
                      f"expected {total - used}")
    return errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=8, help="real seconds a run (warp)")
    ap.add_argument("--run", type=int, default=None, help="only this run (its index)")
    ap.add_argument("--repeat", type=int, default=1, help="each run this many times")
    ap.add_argument("--keep", action="store_true", help="a failing run's data to work/")
    ap.add_argument("--load", default=None, help="check a kept run's data again")
    a = ap.parse_args()
    ok = True
    global LAB
    if a.load:
        with open(a.load, "rb") as f:
            k = pickle.load(f)
        LAB = k["lab"]
        ec.POOL_START, ec.POOL_END = LAB["POOL_START"], LAB["POOL_END"]
        errors = check(*k["args"], k["log"], k["mem"], *k["more"])
        for e in errors:
            print("   FAIL:", e)
        return 1 if errors else 0
    for n, (name, scene, bpm, track, mode, quant, kind, end, *more) in             [r for r in enumerate(RUNS) for _ in range(a.repeat)]:
        if a.run is not None and n != a.run:
            continue
        opts = more.pop() if more and isinstance(more[-1], dict) else {}
        undo, redo = more if more else (0, 0)
        iface = opts.get("iface", "datel")
        prg = os.path.join(ROOT, f"record-{n}.prg")
        build(prg, scene, bpm, track, mode, quant,
              (["-D", "TEST_STAMP_FEW=2"] if kind == "whole" else [])
              + ["-D", f"TEST_REC_END={end}", "-D", f"TEST_REC_UNDO={undo}",
                 "-D", f"TEST_REC_REDO={redo}", "-D", f"TEST_THRU={opts.get('thru', 1)}",
                 "-D", f"TEST_REC_STOP={opts.get('stop', 0)}"], iface)
        try:
            LAB = lab = ec.labels(prg)
            ec.POOL_START = lab["POOL_START"]
            ec.POOL_END = lab["POOL_END"]
            ranges = [(ec.PAT_FIRST_LO, ec.PAT_STEPS + ec.PATTERNS),
                      (ec.POOL_START, ec.POOL_END), (0, 0x200),
                      (lab["rec_before"], lab["rec_before"] + 2),
                      (lab["retire_count"], lab["retire_hi"] + 8)]
            log, mem = run(prg, a.seconds if kind == "content" else 3 * a.seconds, ranges,
                           whole=kind == "whole", iface=iface)
            try:
                errors = check(name, scene, bpm, track, mode, quant, kind, log, mem, undo,
                               redo)
            except (AssertionError, KeyError, IndexError, StopIteration) as e:
                errors = [f"the check stopped: {type(e).__name__} {e}"]
            if errors and a.keep:
                os.makedirs(os.path.join(ROOT, "work"), exist_ok=True)
                kept = os.path.join(ROOT, "work", f"record-fail-{n}-{len(os.listdir(os.path.join(ROOT, 'work')))}.pkl")
                with open(kept, "wb") as f:
                    pickle.dump({"args": (name, scene, bpm, track, mode, quant, kind),
                                 "log": log, "mem": mem, "lab": lab,
                                 "more": (undo, redo)}, f)
                print("   kept:", kept)
        finally:
            for f in (prg, prg + ".lbl"):
                if os.path.exists(f):
                    os.remove(f)
        for e in errors:
            print("   FAIL:", e)
        ok &= not errors
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
