"""screen_check.py - SID500 stage B: how soon a key's effect is on the screen.

The editor's rule 2 (docs/plan.md): a key's effect on the screen in the
next frame at the latest (one frame, 19,656 cycles), also while the
sequencer plays. Builds TEST_KEYS=3 (src/test_scripts.asm: the song
screen, the cursor moved a step at a time while playing, stopped and
playing again) with the half-the-wire scene (TEST_PLAY 4, the load the
user set) and reads the log: each key as the song screen read it
(LOG_KEY) and each row as it was drawn (LOG_DRAWN). For each cursor key
pressed, the time to the cursor's row drawn with the cursor where it
moved; for each SPACE, the time to the title drawn with the new state.
Then TEST_KEYS=7, the other keys: down and up (scrolls too), the half's
flip, + and -, DEL (each to the cursor's row drawn), M and S (to the
header drawn). Then TEST_KEYS=9, editing on the step grid: each note key,
SPACE, DEL and F5 to every row it made urgent drawn (the edited step's and
the cursor's: LOGGED_URGENT_DONE). Then TEST_KEYS=12, copy (C= C), CLR
(at once, undone and redone; a big one asked, then made) and HOME, the
same way. Then TEST_KEYS=16, the event list: F3 both ways, CRSR down,
up, right and left on the list (to its urgent rows drawn), and the
step grid's own CRSR keys in that script; and TEST_KEYS=17, editing in
the list (+ / -, DEL, INST, C= U: to its urgent rows drawn). Held as the
step grid's edits
(the user, 2026-11-24: F3 and page turns redraw the whole screen and wait
for the beam to be clear of the rows between the old and the new cursor;
a move or a field lands on a busy 16th now and then as an edit does, up
to ~24,000 cycles on the band), those over a frame reported. Every scene
the same way (--scene).
Every key within a frame, except on the half-the-wire scene (4), whose
busy 16ths (all 16 tracks at once) the timer interrupt renders for ~30
ms while the main loop waits: there up to BUSY_MAX (the user, 2026-11-20:
the music first, the editor slow for a moment).

    python tools/screen_check.py [--seconds S] [--scene N] [--keys K]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import timing_check as tc  # noqa: E402

LOG_KEY, LOG_DRAWN = 11, 12     # src/timing.asm
LOG_SHIFT = 34                  # src/scene.asm (tests): the next key read with SHIFT held
LOGGED_ROW1 = 0xA1              # src/scene.asm song_log_drawn: row 1 drawn
SCENE_KEYS = {13: "C= S", 28: "C= B N", 39: "C= B N", 22: "C= T", 23: "C= X"}
                                # (stage E: src/scene.asm scene_key, to row 1 drawn)
KEY_CRSR_RIGHT, KEY_SPACE = 2, 60
KEY_M, KEY_S, KEY_LEFT_ARROW = 36, 13, 57           # src/song.asm: the header drawn (LOGGED_HEAD)
OTHER_KEYS = {7: "down/up", 57: "half", 40: "+", 43: "-", 0: "DEL"}   # the cursor's row
LOGGED_HEAD = 0xA0              # src/song.asm song_log_drawn: the header
LOGGED_URGENT_DONE = 0x40       #   the step grid's urgent rows all drawn
KEY_RETURN, KEY_DEL, KEY_F5, KEY_PLUS, KEY_MINUS = 1, 0, 6, 40, 43
KEY_HOME = 6 * 8 + 3            # (SHIFT: CLR; the log doesn't tell them apart)
KEY_F3, KEY_CRSR_DOWN = 5, 7    # src/list.asm: F3 the list and back; the cursor keys
LIST_KEYS = {KEY_F3: "F3", KEY_CRSR_DOWN: "list down/up", KEY_CRSR_RIGHT: "list field"}
                                # (TEST_KEYS=16: to LOGGED_URGENT_DONE)

GRID_NOTE_CODES = {8, 9, 12, 13, 14, 16, 17, 18, 19, 20, 22, 23, 24, 25, 26, 28, 29, 30,
                   31, 32, 33, 34, 35, 36, 38, 39, 41, 42, 44, 46, 47, 50, 55, 59, 62}
#                  (the key codes src/grid.asm's grid_note_keys gives a note)
FRAME = 19656                   # PAL: a frame, cycles (63 x 312)
LOG_END_SPAN = 200 * 985        # a key read this near the log's end: its drawing maybe
                                # not logged (the log full)
NUM_TRACKS = 16
SCENE_HALF = 4                  # tables.py's half-the-wire scene
BUSY_MAX = 80 * 985             # its busy 16ths: a key's effect within 80 ms (cycles)
SCENE_BAND = 1
EDIT_BUSY_MAX = 100 * 985       # the step grid's edits (TEST_KEYS=9; the user, 2026-11-21:
EDIT_BAND_MAX = 2 * 19656       # accepted): at half the wire 100 ms; on the band a frame
                                # but when a key lands on a busy 16th (~13,000 cycles of
                                # rendering meanwhile: up to ~29,000 seen; those over a
                                # frame are reported)


def build(out, scene, keys=3):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"MIDI_IF_DEFAULT={tc.MIDI_IF['datel']}", "-D", f"TEST_KEYS={keys}",
                    "-D", f"TEST_PLAY={scene}", "-D", "TEST_STAMP_FEW=3",
                    "-o", out, "sid500.asm"], cwd=ROOT, check=True)


CBM_KEYS = {KEY_PLUS: "C= + -", KEY_MINUS: "C= + -", 3 * 8 + 7: "C= V L T",
            5 * 8 + 2: "C= V L T", 2 * 8 + 6: "C= V L T", 7 * 8 + 6: "C= Q",
            3 * 8 + 6: "C= U", 2 * 8 + 4: "C= C"}
                                # (src/grid.asm grid_cbm_key; LOG_KEY + $40: C= held)


def latencies(log, list_keys=False):
    """[(what, cycles from the key read to its effect drawn)]; list_keys:
    the step grid's and the list's F3 and CRSR keys too (TEST_KEYS=16)."""
    out = []
    cursor = 0
    pending = []                # (what, time, the drawn value it waits for)
    grid = False                # (the step grid's keys: each RETURN opens or closes it)
    shift = False               # (LOG_SHIFT: the next key read with SHIFT held)
    for k, v, t in log:
        if k == LOG_SHIFT:
            shift = True
            continue
        if k == LOG_KEY:
            shifted, shift = shift, False
        if k == LOG_KEY and v & 0x80 and not grid and (v & 0x3F) == KEY_RETURN \
                and (shifted or v & 0x40):      # (stage E: a launch, its '+')
            pending.append(("launch", t, cursor))
            continue
        if k == LOG_KEY and v & 0x80 and not grid and v & 0x40 and (v & 0x3F) in SCENE_KEYS:
            pending.append((SCENE_KEYS[v & 0x3F], t, None))
            continue
        if k == LOG_KEY and v & 0x80 and (v & 0x3F) == KEY_RETURN and not v & 0x40:
            grid = not grid
            continue
        if k == LOG_KEY and v & 0x80 and grid and v & 0x40:   # C= held: a command
            what = CBM_KEYS.get(v & 0x3F)
            if what:
                pending.append((what, t, None))
        elif k == LOG_KEY and v & 0x80 and grid:
            code = v & 0x3F
            if list_keys and code in LIST_KEYS:
                pending.append((LIST_KEYS[code], t, None))
            elif code in GRID_NOTE_CODES or code in (KEY_SPACE, KEY_DEL, KEY_F5, KEY_PLUS,
                                                   KEY_MINUS, KEY_HOME):
                pending.append(({KEY_SPACE: "rest", KEY_DEL: "DEL", KEY_F5: "octave",
                                 KEY_PLUS: "length", KEY_MINUS: "length",
                                 KEY_HOME: "HOME/CLR"}
                                .get(code, "note"), t, None))
        elif k == LOG_KEY and v & 0x80:
            code = v & 0x3F
            if code == KEY_CRSR_RIGHT:
                cursor = (cursor + 1) % NUM_TRACKS
                pending.append(("cursor", t, cursor))
            elif code == KEY_SPACE:
                pending.append(("space", t, None))
            elif code in (KEY_M, KEY_S):
                pending.append(({KEY_M: "mute", KEY_S: "solo"}[code], t, None))
            elif code in OTHER_KEYS:
                if code == KEY_LEFT_ARROW:
                    cursor ^= 8
                pending.append((OTHER_KEYS[code], t, None))
        elif k == LOG_DRAWN:
            keep = []
            for what, t0, want in pending:
                if (what in ("cursor", "launch") and v == want) \
                        or (what in SCENE_KEYS.values() and v == LOGGED_ROW1) \
                        or (what == "space" and v & 0x80
                                                        and v != LOGGED_HEAD)                         or (what in ("mute", "solo") and v == LOGGED_HEAD)                         or (what in OTHER_KEYS.values() and v < LOGGED_URGENT_DONE)                         or (what in ("note", "rest", "DEL", "octave", "length", "HOME/CLR")
                            + tuple(CBM_KEYS.values()) + tuple(LIST_KEYS.values())
                            and v == LOGGED_URGENT_DONE):
                    out.append((what, t - t0))
                else:
                    keep.append((what, t0, want))
            pending = keep
    last = log[-1][2] if log else 0     # (keys read just before the log filled: not
    out += [(what, None) for what, t0, _ in pending if t0 < last - LOG_END_SPAN]   # judged)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--scene", type=int, default=4, help="tables.py's test scene playing")
    ap.add_argument("--keys", type=int, default=None, help="only this key script")
    a = ap.parse_args()
    ok = True
    for keys in (3, 7, 9, 12, 15, 16, 17):
        if a.keys is not None and keys != a.keys:
            continue
        prg = os.path.join(ROOT, "screen-t.prg")
        build(prg, a.scene, keys)
        try:
            ok &= run(prg, a, keys)
        finally:
            os.remove(prg)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


def run(prg, a, keys):
    ok = True
    if True:
        for model, cia in tc.CIA_MODELS:
            seconds = max(a.seconds, 18) if keys in (12, 15, 16, 17) else a.seconds  # (their
                                                                # scripts ~10-16 s)
            lat = latencies(tc.run_log(prg, seconds, cia), list_keys=keys in (16, 17))
            never = [w for w, d in lat if d is None]
            ds = sorted(d for _, d in lat if d is not None)
            limit = BUSY_MAX if a.scene == SCENE_HALF else FRAME
            if keys in (9, 12):
                limit = {SCENE_HALF: EDIT_BUSY_MAX, SCENE_BAND: EDIT_BAND_MAX}.get(a.scene, FRAME)
            if keys in (16, 17):            # (the list's: as edits, the light scene too)
                limit = EDIT_BUSY_MAX if a.scene == SCENE_HALF else EDIT_BAND_MAX
            slow = [d for d in ds if d > FRAME]
            late = [d for d in ds if d > limit]
            kinds = {}
            for w, d in lat:
                if d is not None:
                    kinds[w] = max(kinds.get(w, 0), d)
            print(f"{model}, scene {a.scene}, keys {keys}: {len(ds)} keys; key to screen "
                  f"{ds[0] if ds else '-'}..{ds[-1] if ds else '-'} cycles "
                  f"(median {ds[len(ds) // 2] if ds else '-'}), {len(slow)} later than a frame"
                  + (f": {slow[:8]}" if slow else "")
                  + "; slowest " + ", ".join(f"{w} {d}" for w, d in sorted(kinds.items())))
            if never or late or not ds:
                ok = False
                if never:
                    print(f"   FAIL: {len(never)} keys never drawn: {never[:5]}")
                if late:
                    print(f"   FAIL: {len(late)} later than {limit} cycles: {late[:8]}")
    return ok


if __name__ == "__main__":
    sys.exit(main())
