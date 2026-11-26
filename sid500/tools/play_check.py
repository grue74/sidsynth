"""play_check.py - SID500 stage A: the player in VICE against a model.

Builds TEST_PLAY programs (tables.py's test scenes, src/test_play.asm) with
the timing log (src/timing.asm), runs them in VICE with a Datel MIDI
cartridge, and checks:

- every byte sent but clock and start is exactly the model's, in order
  (running status, note offs as note on with velocity 0): each tick's note
  offs first, then the tracks in their priority order, each track's events
  in their recorded order; muted tracks silent; a note already sounding
  ended before it starts again; with more than 128 notes sounding the
  next off ended early to make room. The model keeps the offs' timing
  wheel as the program does, so even their order within a tick is checked;
- the lag the player adds: each byte against a wire model (a tick's bytes
  ready at its stamp, then a byte every 283 cycles behind the ones before
  it, clocks included);
- MIDI clock as timing_check.py does: a clock per two ticks, soon after
  its tick, its gaps even;
- with TEST_LIVE (the live switch, src/live.asm): the playing scene's
  cells changed while playing; the switches the program made (logged:
  the track, the pattern, the pass T) made by the model at the same
  passes, each track then at T modulo its new pattern's length; each
  switch within LIVE_MAX passes of its change;
- with TEST_LIVE 2 (an edit to a playing pattern): the band's patterns
  replaced while they play (tables.py band_republish; each publish logged
  with its pass and its place in the pass); the model plays the new
  version from there (a track coming to its pattern's end starts again
  in it, at the old length until its switch), each publish followed by
  its track's switch to the new chain within LIVE_MAX_MS, and the
  replaced chains freed (each free all of them).

    python tools/play_check.py [--seconds S] [--sparse] [--live] [--edits]
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402  (the test scenes)
import timing_check as tc  # noqa: E402  (VICE runs and the log)

OFF_ENTRIES = 128               # src/player.asm
LOG_SWITCH = 13                 # src/timing.asm: a live switch made (five entries)
LOG_LIVE_MISS = 14              #   the renderer got to T first (a try more)
LOG_LIVE_CHANGE = 15            #   TEST_LIVE: a cell changed (pl_music's two bytes)
LOG_PUBLISH = 16                #   live_publish: the pattern, pl_music's two bytes, pl_order,
                                #   play_state * 16 + stop_phase
LOG_FREED = 17                  #   live_free: replaced chains freed (how many)
NO_PATTERN = 0xFF
LIVE_CHANGES = [(100, 3, 1), (180, 0, NO_PATTERN), (260, 9, 0), (340, 3, 3), (420, 0, 2),
                (460, 1, 50)]   # src/live.asm test_live: (from pass n, track, pattern)
LIVE_MAX_MS = 150               # from a change to its switch, ms (the user, 2026-11-21:
LIVE_BUSY_MS = 400              # accepted as measured): light loads (~115 seen, swing
                                # 15); the busy 16ths of half the wire and of 295 BPM (before the 240 cap),
                                # where the main loop is kept out (~250 and ~350 seen)
EDIT_BUSY_MS = 250              # an edit at 240 BPM (TEST_LIVE 2: the many notes' dense
                                # pattern read under that load): 21-141 ms seen since the
                                # 240 cap (2026-11-23); at 295 the user had accepted up to
                                # 600 (242-627 seen)
LAG_MAX = 3150 * tc.BYTE_CYCLES // 283  # with one byte in 8 stamped (--sparse): cycles a
                                # byte may go out later than the wire model allows, in the
                                # scenes that must be on time (the user: half the wire; 3 ms,
                                # 2026-11-22 3.2 ms for now: 2.9-3.1 ms seen across runs;
                                # 2026-11-26 scaled by the wire's pace: 3,505 on the real
                                # wire, 315 cycles a byte, ~3.56 ms)


class Player:
    """The player as src/player.asm plays: per tick the offs due, then the
    tracks in order. The offs wait in a timing wheel as the program keeps
    it: 256 slots (the off time's low byte), each a list with its newest
    entry first; a tick's offs go out a channel at a time (channel 1
    first), each channel's oldest first; a retriggered note's entry is
    freed at once; with all OFF_ENTRIES in
    use, the next slot from the next tick on gives up its first entry."""

    def __init__(self, patterns, tracks, order, swing=0, switches=(), publishes=()):
        self.counts = tables.swing_counts(swing)
        self.patterns, self.spec = dict(patterns), tracks
        self.publishes = list(publishes)        # [(pass, place in it, pattern, (steps, events))]
        self.music = 0                          # passes so far (src/player.asm pl_music)
        self.switches = list(switches)          # [(T, track, pattern)], in the order made
        self.tracks = []
        for pattern, channel, muted in tracks:
            if pattern is None or patterns[pattern][0] == 0:
                self.tracks.append(None)
                continue
            steps, events = patterns[pattern]
            plen = steps * tables.STEP
            self.tracks.append({"events": events, "plen": plen, "pos": plen, "i": 0,
                                "channel": channel, "muted": muted, "pattern": pattern})
        self.order = order
        self.tick = 0
        self.wheel = [[] for _ in range(256)]   # entries: [time high, channel, note, dead]
        self.used = 0
        self.sounding = {}                      # (channel, note) -> its entry
        self.status = 0
        self.out = []

    def send(self, *msg):
        if msg[0] != self.status:
            self.status = msg[0]
            self.out.append(msg[0])
        self.out += msg[1:]

    def play(self):
        """One tick: the bytes it sends (running status afresh each tick)."""
        self.out = []
        self.status = 0
        slot = self.wheel[self.tick & 0xFF]
        if slot:
            due, stay = [], []
            for e in slot:
                if e[3]:
                    self.used -= 1              # dead: freed
                elif e[0] == self.tick >> 8:
                    due.append(e)
                else:
                    stay.append(e)
            self.wheel[self.tick & 0xFF] = stay
            for ch in range(16):
                for e in reversed([e for e in due if e[1] == ch]):
                    self.send(0x90 | ch, e[2], 0)
                    del self.sounding[(ch, e[2])]
                    self.used -= 1
        for _ in range(self.counts[self.tick % 24]):    # (swing: 0-2 passes)
            for t, track, pattern in self.switches:     # live switches before this pass
                if t == self.music:
                    self.switch(track, pattern)
            k, place = self.music, 0
            self.music += 1
            for t in self.order:
                tr = self.tracks[t]
                if tr is None:
                    continue
                self.publish(k, place)                  # (published before this track)
                place += 1
                if tr["pos"] == tr["plen"]:             # from the start: the pattern as now
                    tr["pos"], tr["i"] = 0, 0
                    tr["events"] = self.patterns[tr["pattern"]][1]
                ev = tr["events"]
                while tr["i"] < len(ev) and ev[tr["i"]][0] == tr["pos"]:
                    if not tr["muted"]:
                        self.event(tr["channel"], ev[tr["i"]])
                    tr["i"] += 1
                tr["pos"] += 1
            self.publish(k, 255)                        # (after the pass's tracks)
        self.tick = (self.tick + 1) & 0xFFFF
        return self.out

    def publish(self, k, place):
        """The publishes made at pass k before the track at this place in
        the pass (the tracks already played in it play the old version)."""
        while self.publishes and (self.publishes[0][0], self.publishes[0][1]) <= (k, place):
            p = self.publishes.pop(0)
            self.patterns[p[2]] = p[3]

    def switch(self, track, pattern):
        """Track plays pattern from this pass on, at the pass's place in it."""
        _, channel, muted = self.spec[track]
        if pattern not in self.patterns or self.patterns[pattern][0] == 0:
            self.tracks[track] = None           # (NO_PATTERN, or a number with none)
            return
        steps, events = self.patterns[pattern]
        plen = steps * tables.STEP
        pos = self.music % plen
        i = next((k for k, e in enumerate(events) if e[0] >= pos), len(events))
        self.tracks[track] = {"events": events, "plen": plen, "pos": pos, "i": i,
                              "channel": channel, "muted": muted, "pattern": pattern}

    def event(self, ch, ev):
        kind = ev[1]
        if kind == "cc":
            self.send(0xB0 | ch, ev[2], ev[3])
        elif kind == "bend":
            self.send(0xE0 | ch, ev[2], ev[3])
        elif kind == "program":
            self.send(0xC0 | ch, ev[2])
        else:
            _, _, note, vel, length = ev
            old = self.sounding.get((ch, note))
            if old:                             # sounding: its off first, its entry freed
                self.send(0x90 | ch, note, 0)
                self.wheel[old[4]].remove(old)
                self.used -= 1
            self.send(0x90 | ch, note, vel)
            if self.used == OFF_ENTRIES:        # none free: the next slot's first gives way
                for d in range(1, 257):
                    s = self.wheel[(self.tick + d) & 0xFF]
                    if s:
                        h = s.pop(0)
                        self.used -= 1
                        if not h[3]:
                            self.send(0x90 | h[1], h[2], 0)
                            del self.sounding[(h[1], h[2])]
                        break
            time = (self.tick + length) & 0xFFFF
            e = [time >> 8, ch, note, False, time & 0xFF]
            self.wheel[time & 0xFF].insert(0, e)
            self.used += 1
            self.sounding[(ch, note)] = e


def switches(log):
    """The live switches the program made: [(T, track, pattern)]."""
    v = [v for k, v, _ in log if k == LOG_SWITCH]
    return [(v[i + 2] | v[i + 3] << 8 | v[i + 4] << 16, v[i], v[i + 1])
            for i in range(0, len(v) - 4, 5)]


def publishes(log):
    """The publishes logged (TEST_LIVE 2 and 3): [(pass, place, pattern,
    (steps, events), play_state * 16 + stop_phase)], the k-th
    band_republish entry (round again after its end) the k-th publish."""
    v = [v for k, v, _ in log if k == LOG_PUBLISH]
    rep = tables.band_republish()
    out = []
    for i in range(0, len(v) - 4, 5):
        _, _, steps, events = rep[i // 5 % len(rep)]
        out.append((v[i + 1] | v[i + 2] << 8, v[i + 3], v[i], (steps, events), v[i + 4]))
    return out


def edit_errors(made, pubs, passes, bpm, log):
    """TEST_LIVE 2: each publish (its pattern as band_republish's, at its
    pass or later) followed by its track's switch to it (the band's track
    n plays pattern n) within LIVE_MAX_MS; the replaced chains freed: all
    those published before the last free, freed by then. Returns (errors,
    delays in ms, a note)."""
    errors, delays = [], []
    rep = tables.band_republish()
    pass_ms = 60000 / (bpm * tables.TICKS_PER_QUARTER)
    most = (EDIT_BUSY_MS if bpm > 200 else LIVE_MAX_MS) / pass_ms
    for k, (m, place, pattern, *_) in enumerate(pubs):
        n, number = rep[k][0], rep[k][1]
        if pattern != number or m < n:
            errors.append(f"publish {k}: pattern {pattern} at pass {m}, the list's {number} "
                          f"from {n}")
        # its track's first switch after it (a second publish of the same
        # pattern before that switch shares it)
        t = next((t for t, tr, pa in made if tr == pattern and t > m), None)
        if t is None:
            if m + most < passes - 8:
                errors.append(f"the publish at pass {m} (pattern {pattern}) never switched")
            continue
        delays.append((t - m) * pass_ms)
        if t - m > most:
            errors.append(f"the publish at pass {m} switched at pass {t} "
                          f"({(t - m) * pass_ms:.0f} ms)")
    for t, tr, pa in made:                      # each switch to its own pattern, published
        if tr != pa or not any(p[2] == pa and p[0] < t for p in pubs):
            errors.append(f"switch {(t, tr, pa)} for no publish")
    for i, n in enumerate(rep):                 # every publish the log reaches made
        if i >= len(pubs) and n[0] + most < passes - 8:
            errors.append(f"the publish from pass {n[0]} never made")
    # the frees: each frees every chain replaced before it
    freed, before, total = 0, 0, 0
    for k, v, _ in log:
        if k == LOG_PUBLISH:
            total += 1
        elif k == LOG_FREED:
            freed += v
            before = total
    total //= 5
    before //= 5
    if freed != before:
        errors.append(f"{freed} chains freed, {before} replaced before the last free")
    misses = sum(1 for k, _, _ in log if k == LOG_LIVE_MISS)
    return errors, delays, (f"; {total} publishes, {freed} chains freed, {misses} tries "
                            f"again")


def live_errors(made, passes, bpm, patterns, log):
    """Each change switched once, in order (a number with no pattern as
    none), within LIVE_MAX_MS of the pass it came at (logged; the changes
    the log reaches). Returns (errors, the delays in ms)."""
    errors, delays = [], []
    v = [v for k, v, _ in log if k == LOG_LIVE_CHANGE]
    came = [v[i] | v[i + 1] << 8 for i in range(0, len(v) - 1, 2)]
    pass_ms = 60000 / (bpm * tables.TICKS_PER_QUARTER)
    busy = bpm > 200 or len([p for p in patterns.values() if p[1]]) == 16
    most = (LIVE_BUSY_MS if busy else LIVE_MAX_MS) / pass_ms
    for k, (n, track, pattern) in enumerate(LIVE_CHANGES):
        if k >= len(made):
            if n + most < passes - 8:
                errors.append(f"the change at pass {n} (track {track}) never switched")
            continue
        t, tr, pa = made[k]
        if k < len(came):
            n = came[k]
        want = pattern if pattern in patterns and patterns[pattern][0] else NO_PATTERN
        if (tr, pa) != (track, want):
            errors.append(f"switch {made[k]} for the change at pass {n} ({track}, {pattern})")
        delays.append((t - n) * pass_ms)
        if not 0 < t - n <= most:
            errors.append(f"the change at pass {n} switched at pass {t} "
                          f"({(t - n) * pass_ms:.0f} ms)")
    if len(made) > len(LIVE_CHANGES):
        errors.append(f"more switches than changes: {made}")
    return errors, delays


def messages(data):
    """MIDI bytes as whole channel messages (running status written out)."""
    out, status, cur = [], 0, []
    for b in data:
        if b >= 0x80:
            status, cur = b, [b]
        else:
            if not cur:
                cur = [status]
            cur.append(b)
        if cur and len(cur) == (2 if cur[0] & 0xE0 == 0xC0 else 3):
            out.append(tuple(cur))
            cur = []
    return out


def build(out, scene, bpm, sparse=False, iface="datel", swing=0, live=False):
    import subprocess
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"TEST_LIVE={int(live)}",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF[iface]}",
                    "-D", f"TEST_PLAY={scene}", "-D", f"TEST_TEMPO={bpm}",
                    "-D", f"TEST_SWING={swing}",
                    "-D", f"TEST_STAMP_FEW={2 if sparse else 0}", "-o", out,
                    "sid500.asm"], cwd=ROOT, check=True)


STAMP_EVERY = 8                 # src/timing.asm, TEST_STAMP_FEW 2


def lag_sparse(name, scene, log, lag_checked, swing=0, live=False):
    """The lag the player adds, from a build stamping one byte in 8 (and
    the clocks): the stamped bytes against the model's at their places,
    each against a wire model (a tick's bytes ready at its stamp, a byte
    every 283 cycles; the clocks take their slots at their own times).
    Returns the worst lag in cycles."""
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    song = ticks[next(i for i, t in enumerate(ticks) if t > start):]
    made = switches(log)
    pubs = publishes(log)
    player = Player(*tables.SCENES[scene](), swing=swing, switches=made, publishes=pubs)
    expect = []
    for k in range(len(song)):
        expect += [(b, k) for b in player.play()]
    clocks = [t for v, t in sent if v == tc.CLOCK]
    stamped = [(v, t) for v, t in sent if v not in (tc.START, tc.CLOCK)]
    errors = []
    stray = sorted({v for v, _ in stamped if v >= 0xF8})
    if stray:
        errors.append(f"realtime bytes the player never sends: {stray}")
    # the wire model over every byte the model sends, clocks slotted in
    ready, wire, c = [], 0, 0
    for b, k in expect:
        r = max(song[k], wire)
        while c < len(clocks) and clocks[c] <= r:
            wire = max(wire, clocks[c]) + tc.BYTE_CYCLES
            r = max(song[k], wire)
            c += 1
        ready.append(r)
        wire = r + tc.BYTE_CYCLES
    worst, where = 0, None
    for j, (v, t) in enumerate(stamped):
        i = (j + 1) * STAMP_EVERY - 1
        if i >= len(expect):
            break
        if v != expect[i][0]:
            errors.append(f"stamped byte {i} is {v:02x}, the model's {expect[i][0]:02x}")
            break
        if t - ready[i] > worst:
            worst, where = t - ready[i], expect[i][1]
    behind = 0
    if stamped:
        last_t = stamped[-1][1]
        behind = sum(1 for (b, k), r in zip(expect, ready) if r <= last_t) - len(stamped) * STAMP_EVERY
    live_note = ""
    bpm = int(name.split(" BPM")[0].split()[-1])
    if live == 2:
        errs, delays, note = edit_errors(made, pubs, len(song), bpm, log)
        errors += errs
        live_note = (f"; {len(made)} switches to edited patterns, {min(delays, default=0):.0f}.."
                     f"{max(delays, default=0):.0f} ms after their publishes{note}")
    elif live:
        errs, delays = live_errors(made, len(song), bpm, tables.SCENES[scene]()[0], log)
        errors += errs
        misses = sum(1 for k, _, _ in log if k == LOG_LIVE_MISS)
        live_note = (f"; {len(made)} live switches, {min(delays, default=0):.0f}.."
                     f"{max(delays, default=0):.0f} ms after their changes ({misses} tries "
                     f"again)")
    print(f"{name}, one byte in {STAMP_EVERY} stamped, {len(song)} ticks: the player's added lag at most "
          f"{worst} cycles ({worst / 985.248:.2f} ms), at song tick {where}; "
          f"{max(0, behind)} bytes behind the wire model at the log's end{live_note}")
    if lag_checked and worst > LAG_MAX:
        errors.append(f"a byte went out {worst} cycles later than the wire allows")
    for e in errors:
        print("   FAIL:", e)
    return worst, not errors


def check(name, scene, bpm, log, lag_checked, nmi=False, swing=0, live=False):
    errors = []
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    first = next(i for i, t in enumerate(ticks) if t > start)  # song tick 0's stamp
    song = ticks[first:]

    # the model's bytes, each with its song tick (the live switches as made)
    made = switches(log)
    pubs = publishes(log)
    live_note = ""
    if live == 2:
        errs, delays, note = edit_errors(made, pubs, len(song), bpm, log)
        errors += errs
        live_note = (f"; {len(made)} switches to edited patterns, {min(delays, default=0):.0f}.."
                     f"{max(delays, default=0):.0f} ms after their publishes{note}")
    elif live:
        errs, delays = live_errors(made, len(song), bpm, tables.SCENES[scene]()[0], log)
        errors += errs
        misses = sum(1 for k, _, _ in log if k == LOG_LIVE_MISS)
        live_note = (f"; {len(made)} live switches, {min(delays, default=0):.0f}.."
                     f"{max(delays, default=0):.0f} ms after their changes ({misses} tries "
                     f"again)")
    elif made:
        errors.append(f"live switches without changes: {made}")
    player = Player(*tables.SCENES[scene](), swing=swing, switches=made, publishes=pubs)
    expect = []
    for k in range(len(song)):
        expect += [(b, k) for b in player.play()]
    got = [(v, t) for v, t in sent if v not in (tc.START, tc.CLOCK)]
    n = min(len(got), len(expect))
    # whole messages compared (a tick released in parts restarts its
    # running status), up to the last whole one sent
    got_m, exp_m = messages([v for v, _ in got]), messages([b for b, _ in expect])
    m = min(len(got_m), len(exp_m))
    if got_m[:m] != exp_m[:m]:
        i = next(i for i in range(m) if got_m[i] != exp_m[i])
        errors.append(f"message {i} is {got_m[i]}, the model's {exp_m[i]}: "
                      f"{got_m[max(0, i - 3):i + 3]} / {exp_m[max(0, i - 3):i + 3]}")
    elif [v for v, _ in got[:n]] != [b for b, _ in expect[:n]]:
        print("   (the same messages; running status differs: a tick released in parts)")
    # all but the last ticks' bytes must be there (the log ends somewhere),
    # in the scenes that must be on time
    if lag_checked and (n < len(got) or (expect and n < len(expect)
                                         and expect[n][1] < len(song) - 4)):
        errors.append(f"{len(got)} bytes sent, the model {len(expect)} up to the log's end")

    # the lag the player adds: each byte against the wire model
    lags, wire, k_of = [], 0, iter(expect)
    for v, t in sent:
        if v in (tc.START, tc.CLOCK):
            wire = max(wire, t) + tc.BYTE_CYCLES
            continue
        try:
            _, k = next(k_of)
        except StopIteration:
            break
        ready = max(song[k], wire)
        lags.append(t - ready)
        wire = ready + tc.BYTE_CYCLES
    worst = max(lags) if lags else 0             # (reported only: the stamps load it)

    # clock: a clock with every second song tick, soon after it, gaps even
    clocks = [t for v, t in sent if v == tc.CLOCK]
    lag_c = [c - s for c, s in zip(clocks, song[::2])]
    gaps = [b - a for a, b in zip(clocks, clocks[1:])]
    # (an NMI interface: the stamps in the NMI make the timing worse than
    # it is: timing_check.py measures it with only the clocks stamped)
    if not nmi and (max(lag_c) > tc.CLOCK_MAX or min(lag_c) < 0):
        errors.append(f"clock lag {min(lag_c)}..{max(lag_c)} cycles")
    if not nmi and max(gaps) - min(gaps) > tc.CLOCK_JITTER_MAX:
        errors.append(f"clock gaps vary by {max(gaps) - min(gaps)} cycles")

    print(f"{name}: {len(song)} ticks, {len(got)} bytes as the model's; the player's added "
          f"lag at most {worst} cycles ({worst / 985.248:.2f} ms); clock lag {min(lag_c)}.."
          f"{max(lag_c)}, gaps vary by {max(gaps) - min(gaps)} cycles{live_note}")
    for e in errors:
        print("   FAIL:", e)
    return not errors


RUNS = [  # (name, scene, BPM, lag checked: not when the wire can't keep up, cartridge,
          #  swing)
    ("band, 120 BPM", 1, 120, True, "datel", 0),
    ("band, 240 BPM", 1, 240, True, "datel", 0),
    ("band, 120 BPM, swing 8", 1, 120, True, "datel", 8),
    ("band, 240 BPM, swing 15", 1, 240, True, "datel", 15),
    ("half the wire, 120 BPM", 4, 120, True, "datel", 0),
    ("half the wire, 120 BPM, swing 15", 4, 120, True, "datel", 15),
    ("heavy, 120 BPM (more than the C64 can compute)", 2, 120, False, "datel", 0),
    ("heavy, 240 BPM (more than the wire can carry)", 2, 240, False, "datel", 0),
    ("overflow, 120 BPM (more notes than the wheel holds)", 3, 120, False, "datel", 0),
    ("Namesoft (NMI), band, 240 BPM", 1, 240, True, "namesoft", 0),
    ("Namesoft (NMI), half the wire, 120 BPM", 4, 120, True, "namesoft", 0),
    ("Namesoft (NMI), heavy, 240 BPM (overload)", 2, 240, False, "namesoft", 0),
    ("band, 120 BPM, live switches", 1, 120, True, "datel", 0, True),
    ("band, 120 BPM, swing 15, live switches", 1, 120, True, "datel", 15, True),
    ("band, 240 BPM, swing 8, live switches", 1, 240, True, "datel", 8, True),
    ("half the wire, 120 BPM, live switches", 4, 120, True, "datel", 0, True),
    ("band, 120 BPM, edits while playing", 1, 120, True, "datel", 0, 2),
    ("band, 120 BPM, swing 15, edits while playing", 1, 120, True, "datel", 15, 2),
    ("band, 240 BPM, swing 8, edits while playing", 1, 240, True, "datel", 8, 2),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=None,
                    help="real seconds a run (warp): default 3, with --sparse 8 (its logs "
                         "then cover ~2000 ticks: the band scene's tick 1344 included)")
    ap.add_argument("--sparse", action="store_true",
                    help="the lag from builds stamping one byte in 8 (no content check)")
    ap.add_argument("--live", action="store_true", help="only the live switch's runs")
    ap.add_argument("--edits", action="store_true",
                    help="only the runs editing playing patterns (TEST_LIVE 2)")
    a = ap.parse_args()
    if a.seconds is None:
        a.seconds = 8 if a.sparse else 3
    ok = True
    if a.sparse:
        for i, (name, scene, bpm, lag_checked, iface, swing, *live) in enumerate(RUNS):
            live = int(live[0]) if live else 0
            if (a.live and not live) or (a.edits and live != 2):
                continue
            prg = os.path.join(ROOT, f"play-{i}.prg")
            build(prg, scene, bpm, sparse=True, iface=iface, swing=swing, live=live)
            try:
                for model, cia in tc.CIA_MODELS:
                    ok &= lag_sparse(f"{model}, {name}", scene,
                                     tc.run_log(prg, a.seconds, cia, iface), lag_checked,
                                     swing, live)[1]
            finally:
                os.remove(prg)
        print("all passed" if ok else "FAILED")
        return 0 if ok else 1
    for i, (name, scene, bpm, lag_checked, iface, swing, *live) in enumerate(RUNS):
        live = int(live[0]) if live else 0
        if (a.live and not live) or (a.edits and live != 2):
            continue
        prg = os.path.join(ROOT, f"play-{i}.prg")
        build(prg, scene, bpm, iface=iface, swing=swing, live=live)
        try:
            for model, cia in tc.CIA_MODELS:
                ok &= check(f"{model}, {name}", scene, bpm,
                            tc.run_log(prg, a.seconds, cia, iface), lag_checked,
                            iface == "namesoft", swing, live)
        finally:
            os.remove(prg)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
