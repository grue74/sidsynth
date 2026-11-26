"""transport_check.py - SID500 stage A: start, stop and continue, in VICE.

As master, scripted keys (src/test_scripts.asm): TEST_KEYS=1 plays from the
start, stops, continues, plays from the start again while playing (a stop,
then a start) and stops;
TEST_KEYS=2 stops and continues eight times, each stop a scan later in the
16th than the one before. As slave, a master's start, stop and continue
fed in (tables.py's feeds 7 and 8, the same, its clock running
throughout; feed 9 short stretches, for the heavy scene). Checks every byte sent against the model (play_check.Player,
docs/design.md section 4):

- each stretch played: the model's bytes for its ticks; at a stop, a note
  off for each note sounding then (channel 1 first, each channel's notes
  upwards), nothing else; the song then at the 16th at or after the stop
  point (the ticks sent), nothing sounding; as master its song position
  sent (16ths), and again before MIDI continue; continue plays on from
  that 16th, start from the song's start;
- the ways a stop moved on to its 16th (transport.asm's LOG_LOCATE): never
  the fallback (no snapshot); in the TEST_KEYS=2 and feed 8 runs, a
  continue played and matched after both ways, rendering on to the 16th
  and back with its snapshot; with TEST_ABORT (render's loop going on
  while held, so the stage fills), a step abandoned (render_abort) and
  the stop still exact (no note left sounding, no hang);
- TEST_KEYS=5, five stops on the song screen (the band), each just
  after a + on the playing scene's first cell (the live switch, src/live.asm): the
  switches as logged made by the model; a stop that goes back to a snapshot from
  before a switch's pass undoes it (the program makes it again after the
  continue, logged again), so the model drops, at each stop, the switches
  logged before it whose pass is past its 16th's;
- TEST_KEYS=10 with TEST_LIVE 3 (an edit to a playing pattern, design 5),
  the band: the band's patterns replaced (tables.py band_republish, a
  publish at each of the script's P: src/live.asm) while playing, during a
  stop, while stopped (then a continue and a stop at once: back with the
  16th's snapshot, its entries moved to the new chains), and more than the
  list of replaced chains holds while stopped. The model plays each publish
  from where it was made (its pass and place in the pass, logged) as
  play_check.py --edits does, and from the 16th where the song went back
  to it (a stop's locate after it, or the song prepared again while
  stopped: stop_reprepare, logged); the snapshots' entries moved are
  logged as switches at the snapshot's pass. Required: publishes in each
  state, the song prepared again, and every replaced chain freed by the
  log's end (the run ends stopped);
- no note left sounding: every note started is ended by the log's end
  (all the runs end stopped). The heavy scene (more than the C64 can
  compute: ticks go out partly, then a stop counts a tick partly sent)
  is checked for this only, the model not knowing which ticks went out
  partly; that a stop came in such a tick is required there. It runs as
  slave: in that overload the main loop gets no time, so the keys aren't
  read (a master can't be stopped by its keys then);
- master: MIDI start and continue a tick before the first clock, a clock
  every two ticks while playing and none while stopped;
- slave: every realtime byte fed passed on; after start and continue the
  first clock's tick within EVEN_MAX (slave_check.py's), except a start
  away from the song's start: the song is reset first, the clocks counted
  meanwhile played at once (that delay reported, at most RESET_MAX).

    python tools/transport_check.py [--seconds S]
"""
import argparse
import copy
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402
import play_check as pc  # noqa: E402
import slave_check as sc  # noqa: E402

START, CONTINUE, STOP, CLOCK, SPP = 0xFA, 0xFB, 0xFC, 0xF8, 0xF2
STEP = 12                       # ticks a 16th
LOG_LOCATE = 10                 # src/timing.asm; its values: transport.asm LOCATE_*
LOCATE_THERE, LOCATE_FORWARD, LOCATE_BACK, LOCATE_NONE, LOCATE_PARTIAL = 0, 1, 2, 3, 4
LOCATE_BROKEN = 8               # an abandoned step (render_abort): from a snapshot
LOG_REPREPARE = 18              # src/timing.asm: stop_reprepare, prepared again while stopped
LOCATE_NAMES = {LOCATE_THERE: "there", LOCATE_FORWARD: "forward", LOCATE_BACK: "back",
                LOCATE_NONE: "no snapshot"}
LOCATE_MAX = 80000              # a slave's continue after a song position: located first
                                # (reported; the locate's pieces before the first tick)
RESET_MAX = 40000               # a slave's start away from the song's start: the reset
                                # (player_prepare_quick: tick 0 rendered) before the first
                                # tick, cycles (~26,000 seen; an open question)

RUNS = [  # (name, master, scene, TEST_KEYS or feed, cartridge, content checked,
          #  what must be seen: "both" ways with continues after, a stop in a tick
          #  "partly" sent, a step "abandoned"; more build options)
    ("master, the keys, band", True, 1, 1, "datel", True, (), {}),
    ("master, eight stops, light", True, 5, 2, "datel", True, ("both",), {}),
    ("master, eight stops, light, Namesoft (NMI)", True, 5, 2, "namesoft", True, (), {}),
    ("master, five stops, band, a + before each (live switches)", True, 1, 5, "datel", True,
     ("live",), {}),
    ("master, edits playing, stopping and stopped, band", True, 1, 10, "datel", True,
     ("edits",), {"TEST_LIVE": 3}),
    ("slave, feed 7, band", False, 1, 7, "datel", True, (), {}),
    ("slave, feed 8 (eight stops), light", False, 5, 8, "datel", True, ("both",), {}),
    # (song positions: src/locate.asm, design 5e)
    ("slave, feed 14 (song positions), band", False, 1, 14, "datel", True, ("located",), {}),
    ("slave, feed 14 (song positions), band, swing 15", False, 1, 14, "datel", True,
     ("located",), {"TEST_SWING": 15}),
    # (the heavy scene: more than the C64 can compute, so its ticks go out
    # partly; as slave, as the keys aren't read in that overload)
    ("slave, feed 9, heavy (a tick partly sent)", False, 2, 9, "datel", False, ("partly",), {}),
    # (render's loop going on while held, as it did before: the stage fills
    # and the step must be abandoned, render_abort)
    ("slave, feed 9, heavy, the step abandoned (TEST_ABORT)", False, 2, 9, "datel", False,
     ("abandoned",), {"TEST_ABORT": 1}),
]


class Song:
    """The model of the song through stops: play_check.Player, located."""

    def __init__(self, scene, switches=(), publishes=(), locates=(), repreps=(), swing=0):
        self.scene = scene
        self.swing = swing
        self.switches = list(switches)          # [(T, track, pattern, time logged)]
        self.publishes = list(publishes)        # [(pass, place, pattern, content, time)]
        self.locates = list(locates)            # each stop's locate: its time
        self.repreps = list(repreps)            # stop_reprepare's: their times
        self.undone = 0
        self.start()

    def start(self, at=0):
        """From the song's start (the switches and publishes logged after
        time at; the patterns as published before it)."""
        patterns, tracks, order = tables.SCENES[self.scene]()
        patterns = dict(patterns)
        for _, _, pattern, content, t, *_ in self.publishes:
            if t < at:
                patterns[pattern] = content
        self.player = pc.Player(patterns, tracks, order, swing=self.swing,
                                switches=[w[:3] for w in self.switches if w[3] > at],
                                publishes=[p for p in self.publishes if p[4] > at])
        self.pos = 0

    def published(self, before):
        """The publishes logged before a time and not yet played made now:
        the song went back to where it is (a locate, prepared again), so
        every track that starts its pattern again reads the new one."""
        keep = []
        for p in self.player.publishes:
            if p[4] < before:
                self.player.patterns[p[2]] = p[3]
            else:
                keep.append(p)
        self.player.publishes = keep

    def resume(self, at):
        """Before a continue at time at: the song prepared again meanwhile."""
        for t in self.repreps:
            if t < at:
                self.published(t)

    def play(self, n):
        out = []
        for _ in range(n):
            out += pc.messages(self.player.play())
            self.pos += 1
        return out

    def stop(self, at=None):
        """The offs at a stop (at: its time); then on to the next 16th,
        nothing sounding; the live switches logged before it whose pass is
        past the 16th's undone (back with a snapshot from before them).
        Returns (offs, the 16th's number)."""
        offs = [(0x90 | ch, note, 0) for ch, note in sorted(self.player.sounding)]
        b = -(-self.pos // STEP) * STEP
        while self.pos < b:                     # rendered on silently
            self.player.play()
            self.pos += 1
        if at is not None:
            undone = [w for w in self.switches if w[3] < at and w[0] > self.player.music]
            self.undone += len(undone)
            self.switches = [w for w in self.switches if w not in undone]
            self.player.switches = [w[:3] for w in self.switches]
            located = next((t for t in self.locates if t > at), None)
            if located is not None:
                self.published(located)
        self.player.wheel = [[] for _ in range(256)]
        self.player.used = 0
        self.player.sounding = {}
        return offs, b // STEP

    def locate(self, n16):
        """A song position as slave (src/locate.asm): the song as played from
        its start to that 16th, nothing sounding."""
        self.start()
        while self.pos < n16 * STEP:
            self.player.play()
            self.pos += 1
        self.player.wheel = [[] for _ in range(256)]
        self.player.used = 0
        self.player.sounding = {}

    def copy(self):
        other = Song.__new__(Song)
        other.scene, other.pos, other.swing = self.scene, self.pos, self.swing
        other.switches, other.undone = list(self.switches), self.undone
        other.publishes, other.locates, other.repreps = self.publishes, self.locates, self.repreps
        other.player = copy.deepcopy(self.player)
        return other


def spp(n):
    return (SPP, n & 0x7F, n >> 7 & 0x7F)


def build(out, master, scene, which, iface, more):
    defs = ["-D", f"TEST_KEYS={which}"] if master else ["-D", f"TEST_SLAVE={which}"]
    for k, v in more.items():
        defs += ["-D", f"{k}={v}"]
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF[iface]}",
                    "-D", f"TEST_PLAY={scene}", *defs, "-o", out, "sid500.asm"],
                   cwd=ROOT, check=True)


def compare(got, song, stretches, master, errors):
    """got: the messages sent (realtime left out, song position in);
    stretches: [(START or CONTINUE, its ticks' estimate, exact, stopped,
    its start's time, its stop's)] in order, each ended by a stop (the last
    maybe by the log's end). Each
    stretch's tick count is found where it isn't exact: the one near the
    estimate whose bytes match. Returns how many stretches matched."""
    at = 0
    pos16 = 0
    for i, (how, est, exact, stopped, *times) in enumerate(stretches):
        began, ended, located = (list(times) + [None])[:3] if times else (0, None, None)
        if how == START:
            song.start(began)
        elif located is not None:               # a song position before it (slave)
            song.locate(located)
        else:
            song.resume(began)
        if how != START and master:             # continue: its song position again
            want = [spp(pos16)]
            if got[at:at + 1] != want:
                errors.append(f"stretch {i}: {got[at:at + 1]} before continue, not {want}")
                return i
            at += 1
        best = None
        for n in ([est] if exact else sorted(range(max(0, est - 3), est + 4),
                                             key=lambda n: abs(n - est))):
            trial = song.copy()
            want = trial.play(n)
            if stopped:
                offs, n16 = trial.stop(ended)
                want += offs + ([spp(n16)] if master else [])
            if got[at:at + len(want)] == want or (not stopped and got[at:] == want[:len(got) - at]):
                best = (n, trial, want)
                break
        if best is None:
            want = song.play(est)
            k = next((k for k in range(min(len(want), len(got) - at))
                      if got[at + k] != want[k]), None)
            errors.append(f"stretch {i} ({'start' if how == START else 'continue'}, ~{est} "
                          f"ticks): message {k} is {got[at + k] if k is not None else None}, "
                          f"the model's {want[k] if k is not None else None}")
            return i
        n, trial, want = best
        song.player, song.pos = trial.player, trial.pos
        song.switches, song.undone = trial.switches, trial.undone
        pos16 = song.pos // STEP
        at += len(want)
        print(f"   stretch {i}: {'start' if how == START else 'continue'}, {n} ticks"
              + (f", stopped: {sum(1 for m in want if m[0] & 0xF0 == 0x90 and m[2] == 0)} "
                 f"note offs at the stop, on at 16th {pos16}" if stopped else ""))
    if at < len(got):
        errors.append(f"{len(got) - at} messages more than the model's: {got[at:at + 4]}")
    return len(stretches)


def no_stuck_notes(got, errors):
    """Every note started is ended by the log's end (note on with velocity
    0, or note off)."""
    sounding = set()
    for m in got:
        if m[0] & 0xE0 == 0x80:                 # $8n, $9n
            key = (m[0] & 0x0F, m[1])
            if m[0] & 0xF0 == 0x90 and m[2]:
                sounding.add(key)
            else:
                sounding.discard(key)
    if sounding:
        errors.append(f"{len(sounding)} notes left sounding: {sorted(sounding)[:6]}")


def locates(log, stretches, matched, need, errors):
    """The ways each stop moved on (LOG_LOCATE, one a stop, in order; an
    abandoned step's entry comes first, then its way's, if any): never the
    fallback; need "both": a continue matched after each of forward and
    back; "partly": a stop in a tick partly sent; "abandoned": a step
    abandoned. Returns a summary."""
    entries = [v for k, v, _ in log if k == LOG_LOCATE]
    broken = [v for v in entries if v & LOCATE_BROKEN]
    if any((v & 3) == LOCATE_NONE and not v & LOCATE_BROKEN for v in entries):
        errors.append("a stop found no snapshot for its 16th (the fallback ran)")
    ways = [v for v in entries if not v & LOCATE_BROKEN]
    after = {}
    for i, v in enumerate(ways):
        way = v & 3
        nxt = i + 1                             # the stretch after stop i
        if nxt < matched and stretches[nxt][0] == CONTINUE:
            after[way] = after.get(way, 0) + 1
    if "both" in need:
        for way in (LOCATE_FORWARD, LOCATE_BACK):
            if not after.get(way):
                errors.append(f"no continue played after a stop that went "
                              f"{LOCATE_NAMES[way]}")
    if "partly" in need and not any(v & LOCATE_PARTIAL for v in entries):
        errors.append("no stop came in a tick partly sent")
    if "abandoned" in need and not broken:
        errors.append("no step abandoned")
    return (", ".join(f"{LOCATE_NAMES[v & 3]}" + (" (partly sent)" if v & LOCATE_PARTIAL else "")
                      for v in ways)
            + (f"; {len(broken)} step(s) abandoned" if broken else "")
            + "; continues after: " + ", ".join(f"{LOCATE_NAMES[w]} {n}"
                                               for w, n in sorted(after.items())))


def check_master(name, log, scene, content, need):
    errors = []
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    got = pc.messages([v for v, _ in sent if v < 0xF8])
    marks = [(v, t) for v, t in sent if v in (START, CONTINUE, STOP)]
    if not marks or marks[-1][0] != STOP:
        errors.append("the run didn't end stopped (the log too short?)")
    stretches = []
    for j, (v, t) in enumerate(marks):
        if v == STOP:
            continue
        end = next((t2 for v2, t2 in marks[j + 1:] if v2 == STOP), None)
        # the tick the start byte went with, then the ticks played: the
        # timer's ticks after it, before the stop
        played = [x for x in ticks if x > t and (end is None or x < end)]
        stretches.append((v, len(played), False, end is not None, t, end))
        # clocks: the first a tick after the start byte, one every two ticks
        clocks = [t2 for v2, t2 in sent if v2 == CLOCK and t2 > t and (end is None or t2 < end)]
        if clocks and played and not (played[0] < clocks[0] < played[0] + tc.CLOCK_MAX):
            errors.append(f"the first clock after {v:02x} not with the first tick")
        if abs(len(clocks) - (len(played) + 1) // 2) > 1:
            errors.append(f"{len(clocks)} clocks in a stretch of {len(played)} ticks")
    # none while stopped
    for j, (v, t) in enumerate(marks):
        if v == STOP:
            nxt = next((t2 for v2, t2 in marks[j + 1:]), None)
            late = [t2 for v2, t2 in sent if v2 == CLOCK and t2 > t + tc.CLOCK_MAX
                    and (nxt is None or t2 < nxt)]
            if late:
                errors.append(f"{len(late)} clocks sent while stopped")
    made = [w + (t,) for w, t in zip(pc.switches(log),
                                     [t for k, _, t in log if k == pc.LOG_SWITCH][::5])]
    pubs = [p[:4] + (t, p[4]) for p, t in zip(pc.publishes(log),
                                              [t for k, _, t in log if k == pc.LOG_PUBLISH][::5])]
    locate_times = [t for k, v, t in log if k == LOG_LOCATE and not v & LOCATE_BROKEN]
    repreps = [t for k, _, t in log if k == LOG_REPREPARE]
    song = Song(scene, made, pubs, locate_times, repreps)
    matched = compare(got, song, stretches, True, errors) if content else 0
    no_stuck_notes(got, errors)
    ways = locates(log, stretches, matched, need, errors)
    live = ""
    if "live" in need:
        live = f"; {len(made)} live switches made, {song.undone} of them undone by a stop"
        if not made:
            errors.append("no live switch made")
        if not song.undone:
            errors.append("no live switch undone by a stop (and made again)")
    elif "edits" in need:
        def state(v):                           # (play_state * 16 + stop_phase, logged)
            return {0: "stopped", 1: "playing", 2: "playing"}.get(v >> 4, "stopping")
        seen = {state(p[5]) for p in pubs}
        freed = sum(v for k, v, _ in log if k == pc.LOG_FREED)
        live = (f"; {len(pubs)} publishes ({', '.join(sorted(seen))}), {len(made)} switches "
                f"(the snapshots' among them), prepared again {len(repreps)} times, "
                f"{freed} replaced chains freed")
        for st in ("playing", "stopping", "stopped"):
            if st not in seen:
                errors.append(f"no publish while {st}")
        if not repreps:
            errors.append("never prepared again while stopped")
        if freed != len(pubs):
            errors.append(f"{freed} replaced chains freed of {len(pubs)}")
    elif made:
        errors.append(f"live switches without TEST_LIVE: {made}")
    print(f"{name}: {len(marks)} start, stop and continue bytes; {len(got)} messages; "
          f"stops went {ways}{live}")
    for e in errors:
        print("   FAIL:", e)
    return not errors


def check_slave(name, log, scene, content, need, swing=0):
    errors = []
    fed = [(v, t) for k, v, t in log if k == sc.LOG_RX]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    sc.passed_on(fed, sent, errors)
    got = pc.messages([v for v, _ in sent if v < 0xF8])
    marks = [(v, t) for v, t in fed if v in (START, CONTINUE, STOP)]
    if not marks or marks[-1][0] != STOP:
        errors.append("the run didn't end stopped (the log too short?)")
    positions = [(fed[i + 1][0] | fed[i + 2][0] << 7, fed[i + 2][1])   # (whole ones: when
                 for i, (v, _) in enumerate(fed[:-2]) if v == SPP]      # the last byte came)
    slave = [(v, t) for k, v, t in log if k == sc.LOG_SLAVE and v]
    stretches, firsts = [], []
    for j, (v, t) in enumerate(marks):
        if v == STOP:
            continue
        end = next((t2 for v2, t2 in marks[j + 1:] if v2 == STOP), None)
        before = max((t2 for v2, t2 in marks[:j] if v2 == STOP), default=0)
        located = None
        if v == CONTINUE:                       # the last song position since the stop
            located = next((n for n, t2 in reversed(positions) if before < t2 < t), None)
        due = [(n, t2) for n, t2 in slave if t2 > t and (end is None or t2 < end)]
        stretches.append((v, sum(n for n, _ in due), True, end is not None, t, end, located))
        first_clock = next((t2 for v2, t2 in fed if v2 == CLOCK and t2 > t), None)
        if due and first_clock:
            lag = due[0][1] - first_clock
            restart = v == START and j > 0
            firsts.append(f"{'start' if v == START else 'continue'} {lag}"
                          + (" (reset first)" if restart else "")
                          + (f" (located at 16th {located})" if located is not None else ""))
            limit = RESET_MAX if restart else LOCATE_MAX if located is not None \
                else sc.EVEN_MAX
            if lag > limit or lag < 0:
                errors.append(f"after {v:02x} the first tick {lag} cycles after the clock")
    if "located" in need and not any(s[6] is not None for s in stretches):
        errors.append("no continue after a song position")
    matched = compare(got, Song(scene, swing=swing), stretches, False, errors) if content else 0
    no_stuck_notes(got, errors)
    ways = locates(log, stretches, matched, need, errors)
    print(f"{name}: {len(marks)} start, stop and continue fed; {len(got)} messages; "
          f"stops went {ways}; first ticks after the first clock (cycles): "
          + ", ".join(firsts))
    for e in errors:
        print("   FAIL:", e)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=12, help="real seconds a run (warp)")
    ap.add_argument("--only", default=None, help="only the runs whose name has this")
    a = ap.parse_args()
    ok = True
    for name, master, scene, which, iface, content, need, more in RUNS:
        if a.only and a.only not in name:
            continue
        prg = os.path.join(ROOT, "transport-t.prg")
        build(prg, master, scene, which, iface, more)
        try:
            for model, cia in tc.CIA_MODELS:
                log = tc.run_log(prg, a.seconds, cia, iface)
                if master:
                    ok &= check_master(f"{model}, {name}", log, scene, content, need)
                else:
                    ok &= check_slave(f"{model}, {name}", log, scene, content, need,
                                      swing=more.get("TEST_SWING", 0))
        finally:
            os.remove(prg)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
