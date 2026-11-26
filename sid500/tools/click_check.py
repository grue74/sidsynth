"""click_check.py - SID500 stage C: the metronome's clicks on the beat, in VICE.

Builds TEST_PLAY programs with the metronome on at start (TEST_CLICK, src/
click.asm) and the timing log, plays the band from the start and checks
each click (LOG_CLICK, logged as voice 3's gate is written, in the timer
interrupt) against the player's ticks (LOG_TICK, stamped as each comes
due):

- a click on every beat's tick and on no other: a quarter (48 ticks) in
  n/4, an eighth (24) in n/8, from the song's start;
- the bar's first beat the brighter one (value 2), the others 1;
- each within CLICK_MAX cycles of its tick's stamp (the interrupt's work
  before it: the clock out, the tick counted).

Runs at 120 and 240 BPM, with swing (the beats don't move: swing moves
passes, not ticks), and in 7/8. And through stops and continues
(TEST_KEYS=2, the light scene: eight stops, each continued at its 16th):
each click's song tick (LOG_CLICK_AT) a beat's, the bar's first the
brighter, none while stopped (the phase found again from the 16th).

The MIDI note (TEST_CLICK 2 and 3, the note on channel 16: the band's
drums are on 10): from MIDI out as sent (LOG_TX), a note on of the Beat
note (37), or the Bar note (75) on a bar's first beat, on every beat's
tick and no other, within MIDI_CLICK_MAX cycles of its tick (before the
tick's own bytes: the user, 2026-11-22), its off (velocity 0) before the next beat; MIDI only:
no SID click. Through stops: every note on its off, none sounding at
the end, none while stopped.

And heard (2026-11-24: the SID's volume had been cleared after the click
set it, silent from stage C on, unseen by the checks above): the band at
120 BPM with the MIDI interface off, recorded through VICE's sound
(c64tools' vicewav.py, real time): a click every half second, every
fourth a higher one (the bar's first).

    python tools/click_check.py [--seconds S]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import timing_check as tc  # noqa: E402

LOG_CLICK, LOG_CLICK_AT = 19, 20    # src/timing.asm
CLICK_MAX = 1500                # cycles from a tick's stamp to its click (~400 seen)
MIDI_CLICK_MAX = 2000           # to its MIDI note's first byte sent (before the tick's bytes)
CLICK_STATUS = 0x9F             # a note on, channel 16 (TEST_CLICK_CHAN 15)
BEAT_NOTE, BAR_NOTE = 37, 75    # src/params.asm's defaults
SIG_EIGHTHS = 0x80              # src/player.asm

RUNS = [  # (name, BPM, swing, signature: beats - 1, + SIG_EIGHTHS for n/8, keys, mode:
          #  TEST_CLICK 1 SID, 2 MIDI, 3 both)
    ("band, 120 BPM, 4/4", 120, 0, 3, 0, 1),
    ("band, 240 BPM, swing 8, 4/4", 240, 8, 3, 0, 1),
    ("band, 120 BPM, 7/8", 120, 0, 6 | SIG_EIGHTHS, 0, 1),
    ("light, 120 BPM, 4/4, eight stops", 120, 0, 3, 2, 1),
    ("band, 120 BPM, 4/4, MIDI", 120, 0, 3, 0, 2),
    ("band, 240 BPM, 7/8, SID+MIDI", 240, 0, 6 | SIG_EIGHTHS, 0, 3),
    ("light, 120 BPM, 4/4, eight stops, MIDI", 120, 0, 3, 2, 2),
]


def build(out, bpm, swing, sig, keys, mode):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", f"TEST_PLAY={5 if keys else 1}", "-D", f"TEST_CLICK={mode}",
                    "-D", "TEST_CLICK_CHAN=15",
                    "-D", f"TEST_TEMPO={bpm}", "-D", f"TEST_KEYS={keys}",
                    "-D", f"TEST_SWING={swing}", "-D", f"TEST_SIG={sig}", "-o", out,
                    "sid500.asm"], cwd=ROOT, check=True)


def check_stops(name, log, sig):
    """Through stops: each click's song tick a beat's, the bar's first the
    brighter, none while stopped."""
    errors = []
    beat = 24 if sig & SIG_EIGHTHS else 48
    bar = beat * ((sig & 0x0F) + 1)
    at = [v for k, v, _ in log if k == LOG_CLICK_AT]
    clicks = [(v, t) for k, v, t in log if k == LOG_CLICK]
    marks = [(v, t) for k, v, t in log if k == tc.LOG_TX and v in (tc.START, 0xFB, 0xFC)]
    for i, (v, t) in enumerate(clicks):
        tick = at[2 * i] | at[2 * i + 1] << 8
        if tick % beat:
            errors.append(f"a click on song tick {tick}, not a beat's")
        elif v != (2 if tick % bar == 0 else 1):
            errors.append(f"song tick {tick}'s click is {v}")
        last = max((m for m in marks if m[1] < t), key=lambda m: m[1], default=None)
        if last is None or last[0] == 0xFC:
            errors.append(f"a click at song tick {tick} while stopped")
    stops = sum(1 for v, _ in marks if v == 0xFC)
    print(f"{name}: {stops} stops, {len(clicks)} clicks, each on a beat's song tick")
    for e in errors[:8]:
        print("   FAIL:", e)
    if stops < 4 or len(clicks) < 8:
        print("   FAIL: too few stops or clicks")
        return False
    return not errors


def midi_notes(log):
    """The click's notes as sent: [(time of the status byte, note,
    velocity)], channel 16's note ons (real-time bytes skipped, running
    status followed: the band's own messages use it)."""
    out, status, data, t_status = [], None, [], None
    for k, v, t in log:
        if k != tc.LOG_TX or v >= 0xF8:
            continue
        if v >= 0x80:
            status, data, t_status = v, [], t
            continue
        if status is None:
            continue
        if not data:
            t_first = t_status if t_status is not None else t
        data.append(v)
        kind = status & 0xF0
        if kind in (0x80, 0x90, 0xA0, 0xB0, 0xE0) and len(data) == 2:
            if status == CLICK_STATUS:
                out.append((t_first, data[0], data[1]))
            data, t_status = [], None
        elif kind in (0xC0, 0xD0) or status >= 0xF0:
            data, t_status = [], None
    return out


def check_midi(name, log, sig, mode, stops):
    """The click as a MIDI note: on every beat's tick (the right note),
    its off before the next; MIDI only: no SID click; through stops none
    left sounding, none while stopped."""
    errors = []
    beat = 24 if sig & SIG_EIGHTHS else 48
    bar = beat * ((sig & 0x0F) + 1)
    notes = midi_notes(log)
    ons = [(t, n) for t, n, v in notes if v]
    offs = [(t, n) for t, n, v in notes if not v]
    clicks = [t for k, _, t in log if k == LOG_CLICK]
    if mode == 2 and clicks:
        errors.append(f"{len(clicks)} SID clicks with the metronome on MIDI only")
    if mode == 3 and abs(len(clicks) - len(ons)) > 1:
        errors.append(f"{len(clicks)} SID clicks, {len(ons)} notes")
    sounding = None
    for t, n, v in notes:
        if v:
            if sounding is not None:
                errors.append(f"a note on at {t} with note {sounding} still sounding")
            sounding = n
        else:
            if sounding != n:
                errors.append(f"a note off of {n} at {t}, sounding {sounding}")
            sounding = None
    if stops and sounding is not None:
        errors.append(f"note {sounding} left sounding at the end")
    delays = []
    if not stops:
        sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
        start = next(t for v, t in sent if v == tc.START)
        ticks = [t for k, _, t in log if k == tc.LOG_TICK and t > start]
        seen = set()
        for t, n in ons:
            k = max((i for i, x in enumerate(ticks) if x <= t), default=None)
            if k is None:
                errors.append("a note before the song's first tick")
                continue
            seen.add(k)
            delays.append(t - ticks[k])
            if k % beat:
                errors.append(f"a note on tick {k}, not a beat's")
            elif n != (BAR_NOTE if k % bar == 0 else BEAT_NOTE):
                errors.append(f"tick {k}'s note is {n}")
            if t - ticks[k] > MIDI_CLICK_MAX:
                errors.append(f"tick {k}'s note {t - ticks[k]} cycles after it")
        for (t, n), nxt in zip(ons, ons[1:]):
            off = next((o for o in offs if o[0] > t), None)
            if off is None or off[0] > nxt[0]:
                errors.append(f"the note at {t} not off before the next beat's")
        missing = [k for k in range(0, len(ticks) - 1, beat) if k not in seen]
        if missing:
            errors.append(f"no note on the beats' ticks {missing[:6]}")
    else:
        marks = [(v, t) for k, v, t in log if k == tc.LOG_TX and v in (tc.START, 0xFB, 0xFC)]
        for t, n in ons:
            last = max((m for m in marks if m[1] < t), key=lambda m: m[1], default=None)
            if last is None or last[0] == 0xFC:
                errors.append(f"a note on at {t} while stopped")
    if len(ons) < 8:
        errors.append(f"only {len(ons)} notes")
    print(f"{name}: {len(ons)} notes on, {len(offs)} offs, {len(clicks)} SID clicks"
          + (f", each {min(delays)}..{max(delays)} cycles after its tick" if delays else ""))
    for e in errors[:8]:
        print("   FAIL:", e)
    return not errors


def check(name, log, sig):
    errors = []
    sent = [(v, t) for k, v, t in log if k == tc.LOG_TX]
    start = next(t for v, t in sent if v == tc.START)
    ticks = [t for k, _, t in log if k == tc.LOG_TICK and t > start]
    clicks = [(v, t) for k, v, t in log if k == LOG_CLICK]
    beat = 24 if sig & SIG_EIGHTHS else 48
    bar = beat * ((sig & 0x0F) + 1)
    delays, seen = [], set()
    for v, t in clicks:
        k = max((i for i, x in enumerate(ticks) if x <= t), default=None)
        if k is None:
            errors.append(f"a click before the song's first tick ({v})")
            continue
        seen.add(k)
        delays.append(t - ticks[k])
        if k % beat:
            errors.append(f"a click on tick {k}, not a beat's")
        elif v != (2 if k % bar == 0 else 1):
            errors.append(f"tick {k}'s click is {v}, not {2 if k % bar == 0 else 1}")
        if t - ticks[k] > CLICK_MAX:
            errors.append(f"tick {k}'s click {t - ticks[k]} cycles after it")
    last = ticks[-2] if len(ticks) > 1 else 0
    missing = [k for k in range(0, len(ticks) - 1, beat) if k not in seen]
    if missing:
        errors.append(f"no click on the beats' ticks {missing[:6]}")
    if not clicks:
        errors.append("no clicks")
    print(f"{name}: {len(ticks)} ticks, {len(clicks)} clicks "
          f"({sum(1 for v, _ in clicks if v == 2)} bars' first), each "
          f"{min(delays, default=0)}..{max(delays, default=0)} cycles after its tick")
    for e in errors[:8]:
        print("   FAIL:", e)
    del last
    return not errors


SOUND_SECONDS = 10              # the recording (start-up ~1 s of it)
SOUND_BEAT = 0.5                # 120 BPM


def check_sound():
    """The click heard: recorded from VICE's sound, a click every beat,
    the bar's first higher (its zero crossings in its first 5 ms)."""
    import struct
    import wave
    prg, wav = os.path.join(ROOT, "click-sound.prg"), os.path.join(ROOT, "click-sound.wav")
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_LOG=1",
                    "-D", "TEST_PLAY=5", "-D", "TEST_CLICK=1", "-D", "TEST_TEMPO=120",
                    "-D", "MIDI_IF_DEFAULT=0", "-o", prg, "sid500.asm"], cwd=ROOT, check=True)
    try:
        subprocess.run([sys.executable, os.path.join(tc.C64TOOLS, "vicewav.py"), prg, wav,
                        "--seconds", str(SOUND_SECONDS)], check=True, capture_output=True)
        w = wave.open(wav)
        n, rate = w.getnframes(), w.getframerate()
        s = struct.unpack(f"<{n * w.getnchannels()}h", w.readframes(n))[::w.getnchannels()]
        w.close()
    finally:
        for f in (prg, wav):
            if os.path.exists(f):
                os.remove(f)
    win = rate // 100
    env = [max(abs(x) for x in s[i:i + win]) for i in range(0, len(s) - win, win)]
    hits, last = [], -100
    for i, e in enumerate(env):
        if e > max(env) * 0.3 and i - last > 20:
            hits.append(i)
            last = i
    while len(hits) > 1 and abs((hits[1] - hits[0]) / 100 - SOUND_BEAT) > 0.02:
        hits.pop(0)                     # (the start-up's sounds: before the beats)
    gaps = [(b - a) / 100 for a, b in zip(hits, hits[1:])]
    pitch = []
    for h in hits:
        seg = s[h * win:h * win + rate // 200]
        m = sum(seg) / len(seg)
        pitch.append(sum(1 for x, y in zip(seg, seg[1:]) if x - m < 0 <= y - m))

    def fourth(pitch):
        """(every fourth higher, the highs)"""
        high = [p > 1.5 * min(pitch) for p in pitch] if pitch else []
        first = high.index(True) if True in high else None
        ok = first is not None and all(hh == ((k - first) % 4 == 0)
                                       for k, hh in enumerate(high) if k >= first)
        return ok, high
    ok, high = fourth(pitch)
    if not ok and len(hits) > 10 and fourth(pitch[1:])[0]:
        hits, pitch = hits[1:], pitch[1:]   # (VICE's start-up sound a beat before the
        ok, high = True, fourth(pitch)[1]   # first click, at times: not a click)
        gaps = gaps[1:]
    errors = []
    if len(hits) < 10:
        errors.append(f"{len(hits)} clicks heard in {SOUND_SECONDS} s")
    if any(abs(g - SOUND_BEAT) > 0.02 for g in gaps):
        errors.append(f"the clicks not a beat apart: {gaps}")
    if not ok:
        errors.append(f"not every fourth click the higher: {high}")
    print(f"heard: {len(hits)} clicks {SOUND_BEAT} s apart, every fourth higher"
          if not errors else "heard:")
    for e in errors:
        print("   FAIL:", e)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=3)
    a = ap.parse_args()
    ok = True
    for i, (name, bpm, swing, sig, keys, mode) in enumerate(RUNS):
        prg = os.path.join(ROOT, f"click-{i}.prg")
        build(prg, bpm, swing, sig, keys, mode)
        try:
            for model, cia in tc.CIA_MODELS:
                if mode != 1:
                    log = tc.run_log(prg, 12 if keys else a.seconds, cia)
                    ok &= check_midi(f"{model}, {name}", log, sig, mode, keys)
                    if mode == 3:
                        ok &= check(f"{model}, {name}", log, sig)
                elif keys:
                    ok &= check_stops(f"{model}, {name}", tc.run_log(prg, 12, cia), sig)
                else:
                    ok &= check(f"{model}, {name}", tc.run_log(prg, a.seconds, cia), sig)
        finally:
            os.remove(prg)
    ok &= check_sound()
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
