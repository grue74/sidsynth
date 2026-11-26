# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""demo_band.py - SID500 stage C's listening test: SID500 enters the song
on its step grid and plays it to the family's synths (tools/demo_song.py).

    python tools/demo_band.py --check          # the entry against the model (VICE, warp)
    python tools/demo_band.py work/demo        # the live run, the renders, the mix

--check: the TEST_KEYS=13 build run headless past the script's end
(edit_check.py's way): each pattern's published stream as tables.py's
encode() writes the model's notes; the cells as the build-up leaves them
(lead A back, drums B), nothing muted, stopped.

The live run: the build in VICE at real speed (sidsynth/band's vice.py: in
the desktop session), its Datel MIDI out on the band's virtual port, every
message it sends captured with its time (vmidi). Then:
- the capture against the model: every note on is one of its track's
  patterns' notes (pitch, velocity, its step in the pattern), on a 16th
  (the clocks before it a multiple of 6), each with its off; no note
  from a muted track, both patterns of the lead and the drums heard;
- the capture as a MIDI file (out/demo.mid), each synth's part rendered
  exactly by sidsynth/band's feeds.py (its test feed, in emulated time:
  c64tools' vicerec.py, the sound of the video), lined up on the notes (sync.py) and mixed with the
  band's balance (levels.py): out/demo.wav and demo.mp3;
- out/listening.md, the guide: what changes at each time of the mix.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECTS = os.path.dirname(ROOT)
BAND = os.path.join(PROJECTS, "sidsynth", "band")
C64TOOLS = os.path.join(PROJECTS, "c64tools")
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import demo_song as ds  # noqa: E402
import tables  # noqa: E402
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

# (the capture's timing is the PC's: VICE's MIDI out reaches it in bursts, its
# clocks 1-58 ms apart for 20; so a note is placed by the clocks before it, and
# SID500's real timing is play_check.py's, in emulated time)
SECONDS_TO_END = 150.0          # --check: past the script's end (demo_song: ~136 s)
END_CELLS = {(1, 1): 0, (1, 2): 2, (1, 10): 4, (2, 1): 1, (2, 10): 4}   # (scene, track):
                                # the number after the build-up (lead A again, drums B)


def build(prg):
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "demo_song.py")], check=True)
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_KEYS=13",
                    "-D", "MIDI_IF_DEFAULT=3", "-D", f"TEST_TEMPO={ds.TEMPO}", "-l", prg + ".lbl", "-o", prg, "sid500.asm"],
                   cwd=ROOT, check=True)
    lab = {}
    for line in open(prg + ".lbl"):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return lab


def model_events(events):
    """A pattern's notes as the edit table holds them: (tick, "note", note,
    velocity, ticks), a step's notes in the order they were entered."""
    return [((st - 1) * 12, "note", n, v, ln * 12) for st, n, v, ln in events]


def check():
    import edit_check as ec
    prg = os.path.join(ROOT, "demo-check.prg")
    lab = build(prg)
    ec.POOL_START = lab["POOL_START"]
    mute = lab["TRACK_MUTE"]
    try:
        mem = ec.run(prg, [(ec.PAT_FIRST_LO, ec.PAT_STEPS + ec.PATTERNS - 1),
                           (ec.POOL_START, ec.POOL_END - 1), (ec.SCENES, ec.SCENES + 31),
                           (mute, mute + 15), (lab["play_state"], lab["play_state"])],
                     SECONDS_TO_END)
    finally:
        os.remove(prg)
        os.remove(prg + ".lbl")
    errors = []
    for (scene, track), want in END_CELLS.items():
        cell = mem[ec.SCENES + (scene - 1) * 16 + track - 1]
        if cell != want:
            errors.append(f"scene {scene}'s track {track} holds {cell}, not {want}")
    for number, (name, track, scene, steps, events) in enumerate(ds.PATTERNS):
        if mem[ec.PAT_STEPS + number] != steps:
            errors.append(f"{name}: {mem[ec.PAT_STEPS + number]} steps, not {steps}")
            continue
        _, data = ec.chain(mem, mem[ec.PAT_FIRST_LO + number] | mem[ec.PAT_FIRST_HI + number] << 8)
        stream = tables.encode(model_events(events))
        if data[:len(stream)] != stream:
            errors.append(f"{name}: the stream {data[:12]}... differs from encode()'s "
                          f"{stream[:12]}...")
        else:
            print(f"{name}: {len(events)} notes on {steps} steps, as the model's")
    muted = [t + 1 for t in range(16) if mem[mute + t]]
    if muted:
        errors.append(f"tracks {muted} still muted")
    if mem[lab["play_state"]] != 0:
        errors.append(f"still playing (play_state {mem[lab['play_state']]})")
    for e in errors:
        print("   FAIL:", e)
    print("all passed" if not errors else "FAILED")
    return 0 if not errors else 1


# ---- the live run
CAPTURE_SECONDS = 150           # the script's ~136 s and a margin
PORT = "pro16"                  # (sidsynth/band's virtual port for the conductor: its
                                # names are fixed there, SID500 takes Pro-16's)
SYNTH_CH = {"sid101": 0, "sid303": 1, "sid808": 9}
RENDER_SECONDS = 70             # each part's render (the video, from its first frame): feeds'
                                # LEAD, the song (~61 s), a tail


def capture(out):
    """SID500 in VICE at real speed; [(seconds, bytes)] it sent."""
    sys.path.insert(0, BAND)
    import vice_band
    import vmidi
    from vice import Vice
    prg = os.path.join(out, "sid500-demo.prg")
    build(prg)
    log, t0 = [], time.perf_counter()
    port = vmidi.Port(PORT, lambda m: log.append((time.perf_counter() - t0, list(m))))
    time.sleep(0.5)
    nums = vice_band.device_numbers()
    v = Vice("sid500", midi=vice_band.vice_args(PORT, nums), prg=prg)
    limit = time.perf_counter() + CAPTURE_SECONDS
    shots = 0
    while time.perf_counter() < limit:
        time.sleep(5)
        if any(m[0] == 0xFC for _, m in log):
            break
        if shots < 8 and time.perf_counter() - t0 > 20 + 15 * shots:
            v.shot(os.path.join(out, f"screen-{shots}.png"))
            shots += 1
    time.sleep(1)
    v.quit()
    port.close()
    with open(os.path.join(out, "capture.json"), "w") as f:
        json.dump(log, f)
    return log


def song_times(log):
    """The capture from MIDI start to stop, each message on the song's time:
    (clocks before it (the start's first clock is 0), seconds after the
    last clock as the PC saw it, seconds on the song's time, bytes). The
    song's time is the clocks' count: the capture's own timing is the PC's
    (bursts of tens of ms; VICE's and the PC's clocks ~0.2 % apart)."""
    start = next(i for i, (_, m) in enumerate(log) if m[0] == 0xFA)
    clock_s = 60 / ds.TEMPO / 24
    out, clocks, last, stopped = [], -1, log[start][0], False
    for t, m in log[start + 1:]:
        if m[0] == 0xF8:
            clocks += 1
            last = t
            continue
        if m[0] == 0xFC:
            stopped = True              # (the stop's note offs follow it)
            continue
        if stopped and not (m[0] & 0xF0 == 0x80 or (m[0] & 0xF0 == 0x90 and m[2] == 0)):
            break
        out.append((clocks, t - last, max(clocks, 0) * clock_s, m))
    return out


def check_capture(msgs):
    """The capture against the model (module doc). Returns the errors."""
    errors = []
    known = {}                          # channel -> {(step 0-31, note, velocity): its patterns}
    for name, track, _, _, events in ds.PATTERNS:
        for st, n, v, _ in events:
            known.setdefault(ds.CHANNEL[track], {}).setdefault((st - 1, n, v), set()).add(name)
    heard = {}                          # channel -> [(16th from the start, pattern)]
    sounding = {}
    for clocks, after, _, m in msgs:
        kind, ch = m[0] & 0xF0, m[0] & 0x0F
        if kind == 0x90 and m[2]:
            if clocks % 6:
                errors.append(f"channel {ch + 1} note {m[1]}: after {clocks} clocks, not on a "
                              f"16th")
            step = max(clocks, 0) // 6
            names = known.get(ch, {}).get((step % 32, m[1], m[2]))
            name = next(iter(names)) if names and len(names) == 1 else None
            if names is None:
                errors.append(f"channel {ch + 1} note {m[1]} velocity {m[2]} on 16th {step}: "
                              f"in none of its patterns")
            heard.setdefault(ch, []).append((step, name))
            if (ch, m[1]) in sounding and ch != 9:
                errors.append(f"channel {ch + 1} note {m[1]} again before its off")
            sounding[(ch, m[1])] = step
        elif kind == 0x80 or kind == 0x90:
            sounding.pop((ch, m[1]), None)
    if sounding:
        errors.append(f"notes left sounding: {sorted(sounding)}")
    bar = 16

    def first(ch, name=None):
        """The first 16th of a note on ch (only name's patterns have it)."""
        return min((s for s, n in heard.get(ch, []) if name is None or n == name), default=None)
    for ch, name, at in ((1, None, 4), (0, None, 8), (0, "lead B", 16), (9, "drums B", 20)):
        f = first(ch, name)
        if f is None or not (at - 0.5) * bar <= f <= (at + 0.5) * bar:
            errors.append(f"channel {ch + 1}'s {name or 'first note'} on 16th {f}, not near "
                          f"bar {at}")
    gap = [s for s, _ in heard.get(9, []) if 24 * bar + 4 <= s < 26 * bar - 4]
    if gap:
        errors.append(f"drums during their break: 16ths {gap[:4]}")
    return errors, heard


def write_midi(msgs, path):
    import mido
    tpb = 480
    mid = mido.MidiFile(type=0, ticks_per_beat=tpb)
    tr = mido.MidiTrack()
    mid.tracks.append(tr)
    tr.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(ds.TEMPO), time=0))
    now = 0
    for _, _, s, m in msgs:
        if m[0] >= 0xF0:
            continue
        tick = round(s * ds.TEMPO / 60 * tpb)
        tr.append(mido.Message.from_bytes(m).copy(time=tick - now))
        now = tick
    mid.save(path)


def render(mid, out):
    """Each synth's part from the MIDI file, rendered exactly (feeds.py,
    vicewav.py): out/<synth>.wav."""
    sys.path.insert(0, BAND)
    import feeds
    song = dict(key="sid500", name="SID500 demo", tempo=ds.TEMPO, setup={})
    feeds.pick = lambda argv=None: song
    argv, sys.argv = sys.argv, ["feeds.py", mid, out]
    try:
        feeds.main()
    finally:
        sys.argv = argv
    for name in SYNTH_CH:
        prg = os.path.join(out, f"{name}-sid500.prg")
        frame = next(l.split("=")[1].strip() for l in open(prg + ".lbl")
                     if l.split("=")[0].strip() == "video_frame")
        subprocess.run([sys.executable, os.path.join(C64TOOLS, "vicerec.py"), prg,
                        os.path.join(out, f"{name}.mp4"), "--frame-addr", frame.lstrip("$"),
                        "--seconds", str(RENDER_SECONDS), "--sid", "8580", "--skip", "1",
                        "--crop", "screen", "--scale", "1"], check=True)


def mix(mid, out):
    """The renders lined up on the notes and balanced: out/demo.wav, .mp3.
    Returns the mix's seconds at the song's start (its time 0)."""
    sys.path.insert(0, BAND)
    import wave
    import numpy as np
    import levels
    import mix_band
    import sync
    tracks = {}
    pre = 0.5                           # seconds before the song's start
    rate = 48000
    for name, ch in SYNTH_CH.items():
        x = mix_band.read_render(os.path.join(out, f"{name}.mp4"), rate)
        times = sync.note_times(mid, ch, ds.TEMPO)
        lag = sync.lag(x, rate, times)
        tracks[name] = mix_band.shifted(x, int(round((lag - pre) * rate)))
        print(f"{name}: {len(times)} notes, its render {lag:.3f} s late")
    gain = levels.gains({k: levels.loudness(x, rate) for k, x in tracks.items()})
    print("gains: " + ", ".join(f"{k} {20 * np.log10(g):+.1f} dB" for k, g in gain.items()))
    n = min(min(len(t) for t in tracks.values()), int((ds.BARS * 16 * ds.STEP_S + pre + 3) * rate))
    m = sum(gain[k] * tracks[k][:n] for k in tracks)
    m *= 0.89 * 32767 / max(1.0, np.abs(m).max())
    wav = os.path.join(out, "demo.wav")
    with wave.open(wav, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(m.astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-codec:a", "libmp3lame",
                    "-b:a", "192k", os.path.join(out, "demo.mp3")], check=True)
    print(f"{n / rate:.1f} s mixed: {wav} and demo.mp3")
    return pre


def guide(out, pre):
    bar_s = 16 * ds.STEP_S
    rows = [(0, "drums A alone (SID808: kick, clap, closed and open hats)")]
    rows += [(bar, what) for bar, _, _, what in ds.TIMELINE]
    with open(os.path.join(out, "listening.md"), "w", newline="\n") as f:
        f.write("# SID500 stage C: listening test\n\n"
                "`demo.mp3`: SID500 entered five patterns on its step grid (tools/demo_song.py),"
                f" then played them at {ds.TEMPO} BPM to SID808 (drums, ch 10), SID303 (bass, "
                "ch 2) and SID101 (lead, ch 1), built up live. Each synth's part is rendered "
                "exactly from what SID500 sent (captured, then sidsynth/band's feeds.py).\n\n"
                "| Time | Bar | What | Listen for |\n|---|---|---|---|\n")
        for bar, what in rows:
            t = pre + bar * bar_s
            f.write(f"| {int(t // 60)}:{t % 60:04.1f} | {bar + 1} | {what} | "
                    f"{ds.LISTEN.get(bar, '')} |\n")
    print(f"the guide: {os.path.join(out, 'listening.md')}")


def main():
    if "--check" in sys.argv:
        return check()
    out = os.path.abspath(sys.argv[1])
    os.makedirs(out, exist_ok=True)
    cap = os.path.join(out, "capture.json")
    if "--again" in sys.argv and os.path.exists(cap):
        log = json.load(open(cap))      # (the capture kept: renders and mix again)
    else:
        log = capture(out)
    msgs = song_times(log)
    errors, heard = check_capture(msgs)
    notes = {ch: len(v) for ch, v in heard.items()}
    print(f"captured {len(log)} messages, note ons by channel {notes}")
    for e in errors[:12]:
        print("   FAIL:", e)
    mid = os.path.join(out, "demo.mid")
    write_midi(msgs, mid)
    render(mid, out)
    guide(out, mix(mid, out))
    print("all passed" if not errors else "FAILED (the capture)")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
