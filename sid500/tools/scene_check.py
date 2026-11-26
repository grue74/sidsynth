"""scene_check.py - SID500 stage E: scenes, the song and launches, in VICE.

Builds TEST_PLAY=1 programs (the band as scene 1) with TEST_SCENES n
(tables.py SCENE_TESTS: scenes 2 and 3, each scene's bars, signature and
repeats, Song on or off, and actions at play ticks as the keys would:
launches, a cell changed, a stop, a continue; src/scene.asm scene_test)
and the metronome on, plays from the start and checks, from the log
(every tick, every byte sent, each launch armed and made, each click):

- each launch made at the bar line it was armed for, and that pass the
  right one: Song on (or after song select), the playing scene's end (its
  bars times its repeats of its bar) and the next row's scene (scene 1
  after the last or an empty row); a launch of the user's (keys or MIDI),
  the playing scene's next bar line past the renderer's pass when armed;
- every byte the player sends, to the first stop, as play_check.py's model
  plays the song with the launches made where logged (a scene's tracks
  each from its pattern's start, a cell's track alone until the next
  scene) and the live switches (each track's place counted from its own
  start); after each continue, every note as the model's from the 16th it
  plays on from (its song position);
- each click on a beat of the scene playing then (its signature, its bars
  from its start), the bar's first the brighter, and no beat without one
  (but where a stop skipped);
- with swing (the bar lines still a tick's start), by MIDI (feed 13: CC 85
  and a program change on SID500's channel launch, the others pass through,
  song select turns Song on), and a take begun after a launch: its loop
  from its track's start, cut at the next launch (the user, 2026-11-23).

    python tools/scene_check.py [--seconds S] [--run N]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import timing_check as tc  # noqa: E402
import play_check as pc  # noqa: E402
import record_check as rc  # noqa: E402  (a run with the memory at the end)
import count_check as cc  # noqa: E402  (the labels)

LOG_RX, LOG_TX_THRU = 7, 22
LOG_CLICK, LOG_CLICK_AT = 19, 20
LOG_REC_START, LOG_REC_END = 27, 30
LOG_LAUNCH, LOG_LAUNCH_ASK = 32, 33
STOP, CONTINUE, SONG_POS = 0xFC, 0xFB, 0xF2
SIG_EIGHTHS = 0x80
FEED = 13

RUNS = [  # (name, scene test, BPM, options: midi = feed 13 into MIDI in on channel 1,
          #  swing, take = (track, from play tick): a take begun after a launch)
    ("Song on: three scenes, looping", 1, 120, {}),
    ("Song on: three scenes, looping", 1, 240, {}),
    ("Song on: three scenes, looping, swing 15", 1, 120, {"swing": 15}),
    ("Song off: scenes and a cell launched", 2, 120, {}),
    ("Song off: scenes and a cell launched", 2, 240, {}),
    ("Song off: scenes and a cell launched, swing 15", 2, 120, {"swing": 15}),
    ("by MIDI: CC 85, program change, song select", 3, 120, {"midi": True}),
    ("stops just after a launch and in a 3/4 scene, a cell changed after a launch", 4, 120,
     {}),
    ("a take on track 2 after a launch, cut by the next", 5, 120, {"take": (2, 150)}),
]


def build(out, test, bpm, opts):
    more = ["-D", f"TEST_SLAVE={FEED}", "-D", "TEST_FEED_MASTER=1",
            "-D", "TEST_CHANNEL=1"] if opts.get("midi") else []
    more += ["-D", f"TEST_SWING={opts.get('swing', 0)}"]
    if "take" in opts:
        more += ["-D", f"TEST_RECORD={opts['take'][0]}",
                 "-D", f"TEST_REC_FROM={opts['take'][1]}"]
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF['datel']}", "-D", "TEST_PLAY=1",
                    "-D", f"TEST_SCENES={test}", "-D", "TEST_CLICK=1", *more,
                    "-D", f"TEST_TEMPO={bpm}", "-o", out, "-l", out + ".lbl", "sid500.asm"],
                   cwd=ROOT, check=True)


def scene_rows():
    """Scene index -> its row (a pattern or None a track): scene 1 the
    band's, 2.. tables.py's."""
    _, tracks, _ = tables.SCENES[1]()
    rows = {0: [p for p, _, _ in tracks]}
    for k, row in tables.SCENE_ROWS_EXTRA.items():
        rows[k] = row
    return rows


def bar_of(sig):
    """(a bar's ticks, a beat's ticks, beats) for a signature byte."""
    beat = 24 if sig & SIG_EIGHTHS else 48
    beats = (sig & 0x0F) + 1
    return beat * beats, beat, beats


class ScenePlayer(pc.Player):
    """play_check's player with launches: at a launch's pass (a tick's
    start: a bar line), a scene's tracks each from its pattern's start, or
    one track's cell; each track's place counted from its own start (live
    switches: src/scene.asm live_rel)."""

    def __init__(self, patterns, tracks, order, rows, launches, swing=0, switches=()):
        super().__init__(patterns, tracks, order, swing=swing, switches=switches)
        self.rows, self.launches = rows, list(launches)
        self.origin = [0] * 16

    def switch(self, track, pattern):
        music = self.music
        self.music -= self.origin[track]
        super().switch(track, pattern)
        self.music = music

    def start(self, t, pattern):
        self.origin[t] = self.music
        _, channel, muted = self.spec[t]
        if pattern is None or pattern not in self.patterns or self.patterns[pattern][0] == 0:
            self.tracks[t] = None
            return
        steps, events = self.patterns[pattern]
        plen = steps * tables.STEP
        self.tracks[t] = {"events": events, "plen": plen, "pos": plen, "i": 0,
                          "channel": channel, "muted": muted, "pattern": pattern}

    def play(self):
        while self.launches and self.launches[0][0] <= self.music:
            _, kind, what = self.launches.pop(0)
            if kind == "scene":
                for t in range(16):
                    self.start(t, self.rows[what][t])
            else:
                self.start(kind, self.rows[what][kind])
        return super().play()


def pairs16(vals, n):
    """Entries of n values each: the first two a 16-bit number."""
    return [(vals[i] | vals[i + 1] << 8, *vals[i + 2:i + n])
            for i in range(0, len(vals) - n + 1, n)]


def note_ons(msgs):
    return [x for x in msgs if x[0] & 0xF0 == 0x90 and len(x) > 2 and x[2]]


def check(name, test, bpm, log, opts, mem=None, lab=None):
    errors = []
    song_on, scenes, actions = tables.SCENE_TESTS[test]
    rows = scene_rows()
    ticks = [t for k, _, t in log if k == tc.LOG_TICK]
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    song = ticks[next(i for i, t in enumerate(ticks) if t > start):]
    made = pairs16([v for k, v, _ in log if k == LOG_LAUNCH], 3)    # (pass, what)
    ask_v = [(v, t) for k, v, t in log if k == LOG_LAUNCH_ASK]
    asked = [(ask_v[i][0] | ask_v[i + 1][0] << 8, ask_v[i + 2][0] | ask_v[i + 3][0] << 8,
              ask_v[i + 4][0], ask_v[i + 4][1]) for i in range(0, len(ask_v) - 4, 5)]
    # (the renderer's pass, the launch's, what, when armed)
    rx = [(v, t) for k, v, t in log if k == LOG_RX]
    select_t = next((rx[i + 1][1] for i in range(len(rx) - 1) if rx[i][0] == 0xF3), None)
    # the stretches played: (the first song tick, from when, to the stop)
    stretches, first_tick, t0 = [], 0, start
    for i, (v, t) in enumerate(sent):
        if v == STOP:
            stretches.append((first_tick, t0, t))
        elif v == SONG_POS and i + 2 < len(sent):
            first_tick = (sent[i + 1][0] | sent[i + 2][0] << 7) * 12
        elif v == CONTINUE:
            t0 = t
    if not stretches or stretches[-1][1] != t0:
        stretches.append((first_tick, t0, 1 << 40))

    # the launches made: each at its armed pass, and that pass right
    playing, origin = 0, 0
    launches = []
    cell_scene = {a: b for _, kind, a, b in actions if kind == 1}
    for k, (at, code) in enumerate(made):
        kind, what = (("scene", code) if code < 0x80 else (code & 0x7F, None))
        arms = [a for a in asked if a[1] == at and a[2] == code]
        if not arms:
            errors.append(f"launch {k} at pass {at}: armed for no such pass")
            continue
        r, when = arms[-1][0], arms[-1][3]
        bar, _, _ = bar_of(scenes[playing][1])
        by_song = song_on or (select_t is not None and when > select_t)
        if by_song and kind == "scene":
            bars, _, reps = scenes[playing]
            want_at = origin + bar * bars * reps
            nxt = playing + 1
            if nxt >= len(scenes) or all(p is None for p in rows.get(nxt, [None])):
                nxt = 0
            if (at, what) != (want_at, nxt):
                errors.append(f"the song's launch {k}: scene {what + 1} at pass {at}, not "
                              f"scene {nxt + 1} at {want_at}")
        else:
            x = r + 1                           # the next bar line past the renderer
            want_at = x + (-(x - origin)) % bar
            if at != want_at:
                errors.append(f"launch {k} at pass {at}, not the next bar line {want_at} "
                              f"(the renderer at {r}, the scene from {origin}, bars of {bar})")
        if kind == "scene":
            launches.append((at, "scene", what))
            playing, origin = what, at
        else:
            launches.append((at, kind, cell_scene.get(kind, playing)))
    if song_on:
        if len(made) < len(scenes):
            errors.append(f"{len(made)} launches made")
    else:
        due = [a for a in actions if a[1] in (0, 1) and a[0] < len(song) - 60]
        if len(made) < len(due) and not opts.get("midi"):
            errors.append(f"{len(made)} launches made of the {len(due)} asked")
    if opts.get("midi"):
        # CC 85 = 1 and program change 2 on channel 1: scenes 2 and 3, then
        # (song select) the song from there; thru: only the other two
        whats = [w for _, k, w in launches if k == "scene"]
        if whats[:2] != [1, 2]:
            errors.append(f"the scenes launched by MIDI {[w + 1 for w in whats[:2]]}, not 2 3")
        if select_t is None or not any(a[3] > select_t for a in asked):
            errors.append("song select: no song launch armed after it")
        thru = [v for k, v, _ in log if k == LOG_TX_THRU]
        kinds = [(b & 0xF0) for b in thru if b >= 0x80]
        if kinds != [0xC0, 0xB0] or 85 not in thru or 100 not in thru or 1 in thru[:2]:
            errors.append(f"thru sent {[hex(b) for b in thru]}: not only the program change "
                          f"on channel 2 and CC 85 = 100")

    # every byte as the model's to the first stop; after each continue its
    # notes from the 16th it plays on from (the notes the stop ended aren't
    # ended again: notes on only)
    patterns, tracks, order = tables.SCENES[1]()
    player = ScenePlayer(patterns, tracks, order, rows, launches, opts.get("swing", 0),
                         pc.switches(log))
    expect, per_tick = [], []
    for _ in range(len(song) + 64):
        b = player.play()
        expect += b
        per_tick.append(b)
    got = [v for v, t in sent if v not in (tc.START, tc.CLOCK) and t < stretches[0][2]]
    got_m, exp_m = pc.messages(got), pc.messages(expect)
    m = min(len(got_m), len(exp_m))
    if got_m[:m] != exp_m[:m]:
        i = next(i for i in range(m) if got_m[i] != exp_m[i])
        errors.append(f"message {i} is {got_m[i]}, the model's {exp_m[i]}: "
                      f"{got_m[max(0, i - 3):i + 3]} / {exp_m[max(0, i - 3):i + 3]}")
    after = 0
    for k, (ft, ts, te) in enumerate(stretches[1:], 1):
        mine = note_ons(pc.messages([v for v, t in sent if ts < t < te and v < 0xF0]))
        model = note_ons(pc.messages([b for bb in per_tick[ft:] for b in bb]))
        n = min(len(mine), len(model))
        after += n
        if n == 0:
            errors.append(f"after continue {k} (from song tick {ft}): no notes")
        elif mine[:n] != model[:n]:
            i = next(i for i in range(n) if mine[i] != model[i])
            errors.append(f"after continue {k} (from song tick {ft}): note {i} is {mine[i]}, "
                          f"the model's {model[i]}")

    # the clicks: each on a beat of the scene playing, none missing
    segs = [(0, 0)] + [(at, w) for at, kind, w in launches if kind == "scene"]
    want = {}
    horizon = len(song) + 64
    for i, (s0, sc) in enumerate(segs):
        s1 = segs[i + 1][0] if i + 1 < len(segs) else horizon
        _, beat, beats = bar_of(scenes[sc][1])
        for j, t in enumerate(range(s0, s1, beat)):
            want[t] = 2 if j % beats == 0 else 1
    clicks = [v for k, v, _ in log if k == LOG_CLICK]
    at = [v for k, v, _ in log if k == LOG_CLICK_AT]
    got_c = {}
    for i, v in enumerate(clicks):
        if 2 * i + 1 < len(at):
            got_c[at[2 * i] | at[2 * i + 1] << 8] = v
    top = max(got_c, default=0)
    want = {t: v for t, v in want.items() if t <= top}
    for k in range(len(stretches) - 1):         # (not where a stop skipped)
        ft, ts, te = stretches[k]
        played = sum(1 for t in ticks if ts < t <= te) - 1
        nxt = stretches[k + 1][0]
        want = {t: v for t, v in want.items() if not ft + played - 1 <= t < nxt}
        got_c = {t: v for t, v in got_c.items() if not ft + played - 1 <= t < nxt}
    if got_c != want:
        extra = sorted(set(got_c) - set(want))[:6]
        missing = sorted(set(want) - set(got_c))[:6]
        wrong = sorted(t for t in set(got_c) & set(want) if got_c[t] != want[t])[:6]
        errors.append(f"clicks: on no beat {extra}, missing {missing}, wrong kind {wrong}")

    # a take begun after a launch: its loop from its track's start, cut at
    # the next launch
    take_note = ""
    if "take" in opts:
        track, begun = opts["take"][0] - 1, opts["take"][1]
        org = max((a for a, k, w in launches if a <= begun and k in ("scene", track)),
                  default=0)
        scene = tables.SCENE_TEST_ROW.get(test, 0)     # (the cursor's: the take's)
        plen = patterns[rows[scene][track]][0] * tables.STEP
        rec_origin = mem[lab["rec_origin"]] | mem[lab["rec_origin"] + 1] << 8
        starts = pairs16([v for k, v, _ in log if k == LOG_REC_START], 2)
        ends = pairs16([v for k, v, _ in log if k == LOG_REC_END], 2)
        cut = next((a for a, k, w in launches if a > begun), None)
        if (rec_origin - org) % plen:
            errors.append(f"the take's loop from pass {rec_origin}, not from its track's "
                          f"start {org} (a {plen}-pass pattern)")
        if not ends or cut is None or not cut <= ends[0][0] < cut + 96:
            errors.append(f"the take ended at {ends}, not at the launch at {cut} (heard)")
        if mem[lab["rec_state"]]:
            errors.append(f"the take still on at the end (rec_state {mem[lab['rec_state']]})")
        take_note = (f"; the take from pass {starts[0][0] if starts else None}, its loop from "
                     f"{rec_origin}, ended at {ends[0][0] if ends else None}")

    names = [f"{w + 1}" if k == "scene" else f"t{k + 1}" for _, k, w in launches]
    print(f"{name}, {bpm} BPM: {len(song)} ticks, launches {' '.join(names)} at "
          f"{[a for a, _, _ in launches]}; {m} messages as the model's"
          + (f", {after} notes after {len(stretches) - 1} continues"
             if len(stretches) > 1 else "")
          + f"; {len(got_c)} clicks on their beats{take_note}")
    for e in errors[:8]:
        print("   FAIL:", e)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--run", type=int, default=None)
    args = ap.parse_args()
    ok = True
    for n, (name, test, bpm, opts) in enumerate(RUNS):
        if args.run is not None and n != args.run:
            continue
        prg = os.path.join(ROOT, "work", f"scene{n}.prg")
        os.makedirs(os.path.dirname(prg), exist_ok=True)
        build(prg, test, bpm, opts)
        if "take" in opts:
            lab = cc.labels(prg + ".lbl")
            log, mem = rc.run(prg, args.seconds, [(lab["rec_origin"], lab["rec_origin"] + 2),
                                                  (lab["rec_state"], lab["rec_state"] + 1)],
                              whole=True, cut=False)
            ok &= check(name, test, bpm, log, opts, mem, lab)
        else:
            ok &= check(name, test, bpm, tc.run_log(prg, args.seconds, 1), opts)
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
