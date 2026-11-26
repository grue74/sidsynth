# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""demo_tunes.py - the demo tunes played by SID500 to the family's synths,
as videos: SID500's screen and each synth's, the synths' sound mixed.

    python tools/demo_tunes.py <tune> <step>|all [work/tunes]

tune: dub (tools/tune_dub.py) ...; steps, each after the ones before:
  disk     the tune's song file (.s5) and a disk with SID500 (the video's
           build: TEST_KEYS=29 loads it from the directory and plays it with
           Song on, TEST_FRAMES its frame mark for vicerec) and its overlay;
           checked: SID500 loads it (VICE, warp) as the model's song data
           and patterns, the pool whole
  sid500   SID500's video (c64tools vicerec.py, emulated time, VICE's Datel
           cartridge: without it the player would wait for the wire)
  check    SID500 at real speed, its MIDI out captured (sidsynth/band's
           virtual port, as demo_band.py) against the model's
  synths   each synth's part from the model (sidsynth/band feeds.py's test
           feed, the part's channel moved to the synth's own), rendered
  render   sid500 and synths at once (every VICE side by side: emulated time)
  all      disk, render, check, video
  fx       (video does it too) the enhanced mix, echo and reverb (pedalboard), and its
           video: <tune>-sid500-fx.mp4, <tune>-fx.mp3
  video    the parts lined up on their notes (sync.py), balanced, mixed;
           the 3x2 video
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECTS = os.path.dirname(ROOT)
BAND = os.path.join(PROJECTS, "sidsynth", "band")
C64TOOLS = os.path.join(PROJECTS, "c64tools")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import tunes  # noqa: E402
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

ORDER = ["dub", "synth", "pop", "moonlight"]         # the songs on the disk, the directory's order
MIDI_ARGS = "-midi -miditype 2 -midiout -1 -midiin -1"     # VICE's Datel cartridge


def load_tune(key):
    mod = __import__(f"tune_{key}")
    return mod.TUNE


def labels(path):
    lab = {}
    for line in open(path):
        m = re.match(r"(\w+)\s*=\s*(\$[0-9a-fA-F]+|\d+)\s*$", line)
        if m:
            v = m.group(2)
            lab[m.group(1)] = int(v[1:], 16) if v[0] == "$" else int(v)
    return lab


def build(out, place):
    """SID500's video build (TEST_KEYS=29, the song at place in the
    directory) and its overlay: (prg, labels)."""
    prg = os.path.join(out, "sid500-video.prg")
    d = ["-D", "TEST_KEYS=29", "-D", f"TEST_TUNE={place}", "-D", "TEST_FRAMES=1",
         "-D", "MIDI_IF_DEFAULT=3"]
    subprocess.run([sys.executable, "tables.py"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *d, "-l", prg + ".lbl", "-o", prg,
                    "sid500.asm"], cwd=ROOT, check=True)
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *d, "-D", "DISK_OV_OUT=1",
                    "--output-section=disk_ov", "-o", prg + ".disk", "sid500.asm"],
                   cwd=ROOT, check=True)
    return prg, labels(prg + ".lbl")


def step_disk(key, out):
    tune = load_tune(key)
    blocks = tune.check()
    print(f"{tune.title}: {len(tune.patterns)} patterns, {blocks} blocks of "
          f"{tunes.POOL_BLOCKS_RELEASE}, {tune.seconds(tune.length_ticks()):.1f} s")
    files = []
    for k in ORDER:
        try:
            t = tune if k == key else load_tune(k)
        except ImportError:
            continue
        path = os.path.join(out, f"{k}.s5")
        with open(path, "wb") as f:
            f.write(t.s5())
        files.append((path, f"{k}.s5"))
    place = [os.path.basename(p)[:-3] for p, _ in files].index(key) + 1
    prg, lab = build(out, place)
    img = os.path.join(out, "tunes.d64")
    subprocess.run([sys.executable, os.path.join(C64TOOLS, "d64.py"), "--name", "SID500 TUNES",
                    "--id", "01", img, f"{prg}=SID500", f"{prg}.disk=SID500 DISK",
                    *[f"{p}={n}" for p, n in files]], check=True, capture_output=True)
    # SID500 loads it: as the model
    import disk_check as dc
    want = dc.parse_file(tune.s5())
    assert not isinstance(want, str), want
    mem = dc.run(img, [(0x0002, 0x00FF), (0xC800, 0xCFFF), (lab["POOL_START"], dc.POOL_END - 1),
                       (dc.SCREEN, dc.SCREEN + 999)], 40, False, midi=True)
    got = dc.song(mem, lab)
    errors = []
    for name, w, g in zip(("parameters", "Song on and start", "song data", "patterns"), want, got):
        if w != g:
            errors.append(f"{name} differ")
    used, free = dc.check_pool(mem, lab, errors)
    rows = [dc.screen_row(mem, r) for r in range(3)]
    print("\n".join(rows))
    if errors:
        sys.exit("FAIL the load: " + "; ".join(errors))
    print(f"PASS SID500 loaded {key}.s5 as the model ({used} blocks used, {free} free); "
          f"the disk: {img}")


# ---- SID500's video
SID500_SECONDS = 30             # its video beyond the song: the start-up, the directory, the load


REC_PORT = 6600                 # vicerec's binary monitor: this and up, one a recording, 20 a
                                # tune (ORDER): tunes recorded at the same time


def rec_port(key):
    return REC_PORT + 20 * ORDER.index(key)


def sid500_job(key, out):
    """SID500's video's vicerec command."""
    tune = load_tune(key)
    prg = os.path.join(out, "sid500-video.prg")
    frame = "%04x" % labels(prg + ".lbl")["frame_mark"]
    seconds = SID500_SECONDS + tune.seconds(tune.length_ticks()) + 8
    return ("sid500", [sys.executable, os.path.join(C64TOOLS, "vicerec.py"),
                       os.path.join(out, "tunes.d64"), os.path.join(out, "sid500.mp4"),
                       "--frame-addr", frame, "--seconds", f"{seconds:.0f}", "--skip", "1",
                       "--crop", "screen", "--scale", "1", f"--vice-args={MIDI_ARGS}",
                       "--port", str(rec_port(key))])


def record(jobs):
    """vicerec commands [(name, args)] all at once (emulated time: running
    side by side changes nothing), each on its own monitor port."""
    procs = [(name, subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                     text=True)) for name, args in jobs]
    failed = []
    for name, p in procs:
        _, err = p.communicate()
        if p.returncode:
            failed.append(f"{name}: {err.strip()[-300:]}")
    if failed:
        sys.exit("FAIL recording: " + "; ".join(failed))
    print(f"recorded: {', '.join(name for name, _ in jobs)}")


def step_sid500(key, out):
    record([sid500_job(key, out)])


# ---- SID500's MIDI out against the model (real speed: demo_band.py's way)
PORT = "pro16"                  # (sidsynth/band's virtual port for the conductor)


def step_check(key, out):
    import json
    import time
    sys.path.insert(0, BAND)
    import vice_band
    import vmidi
    from vice import Vice
    tune = load_tune(key)
    log, t0 = [], time.perf_counter()
    port = vmidi.Port(PORT, lambda m: log.append((time.perf_counter() - t0, list(m))))
    nums = vice_band.device_numbers()
    for _ in range(50):                 # (the port's numbers: once Windows lists it)
        if None not in nums[PORT]:
            break
        time.sleep(0.2)
        nums = vice_band.device_numbers()
    assert None not in nums[PORT], nums
    v = Vice("sid500", midi=vice_band.vice_args(PORT, nums),
             prg=os.path.join(out, "sid500-video.prg"), disk=os.path.join(out, "tunes.d64"))
    song_s = tune.seconds(tune.length_ticks())
    limit = time.perf_counter() + 90 + song_s
    while time.perf_counter() < limit:
        time.sleep(2)
        starts = [t for t, m in log if m[0] == 0xFA]
        if starts and time.perf_counter() - t0 > starts[0] + song_s + 4:
            break
    v.quit()
    port.close()
    with open(os.path.join(out, "capture.json"), "w") as f:
        json.dump(log, f)
    errors = compare(tune, log)
    for e in errors[:12]:
        print("   ", e)
    if errors:
        sys.exit(f"FAIL SID500's MIDI out: {len(errors)} differences")
    print("PASS SID500's MIDI out as the model's: every message on its clock (24 a quarter), every channel")


def compare(tune, log):
    """The capture from MIDI start on, each message placed by the clocks
    before it (24 a quarter: SID500's 48 ticks / 2), against the model's
    messages to the song's end: per channel, the same messages in the same
    order, each after the same clocks (a model tick T: T // 2 clocks)."""
    start = next(i for i, (_, m) in enumerate(log) if m[0] == 0xFA)
    end = tune.length_ticks() // 2
    got, clocks = {}, -1
    for _, m in log[start + 1:]:
        if m[0] == 0xF8:
            clocks += 1
            continue
        if m[0] >= 0xF0:
            continue
        if clocks >= end:
            break
        if m[0] & 0xF0 == 0x90 and m[2] == 0:
            m = [0x80 | (m[0] & 0x0F), m[1], 0]
        got.setdefault(m[0] & 0x0F, []).append((max(clocks, 0), m))
    want = {}
    for t, ch, m in tune.messages():
        if t // 2 >= end:
            continue
        want.setdefault(ch, []).append((t // 2, m))
    errors = []
    for ch in sorted(set(want) | set(got)):
        w, g = want.get(ch, []), got.get(ch, [])
        # (the same clock: SID500's order within a tick is its own; compare as sets per clock)
        bw, bg = {}, {}
        for c, m in w:
            bw.setdefault(c, []).append(m)
        for c, m in g:
            bg.setdefault(c, []).append(m)
        for c in sorted(set(bw) | set(bg)):
            a, b = sorted(bw.get(c, [])), sorted(bg.get(c, []))
            if a != b:
                errors.append(f"channel {ch + 1} clock {c}: model {a[:4]}, SID500 {b[:4]}")
        print(f"channel {ch + 1}: {len(w)} messages in the model, {len(g)} captured")
    return errors


# ---- the synths' renders
FEED_LEAD = 2.0                 # feeds.py LEAD: seconds from a synth's start to the first beat
TAIL = 6.0                      # seconds rendered after the song's end


def part_mid(tune, out, ch):
    path = os.path.join(out, f"part-ch{ch + 1}.mid")
    tune.write_midi(path, channels={ch})
    return path


def step_synths(key, out):
    record(synth_jobs(key, out))


def synth_jobs(key, out):
    """Each synth's part built as a feed; their vicerec commands."""
    jobs = []
    sys.path.insert(0, BAND)
    import feeds
    tune = load_tune(key)
    seconds = FEED_LEAD + tune.seconds(tune.length_ticks()) + TAIL
    for ch1, (synth, label, _preset) in sorted(tune.synths.items()):
        ch = ch1 - 1
        own = tunes.SYNTH_CHANNEL[synth]
        events = []
        for t, c, m in tune.messages():
            if c != ch:
                continue
            m = [(m[0] & 0xF0) | own] + m[1:]
            if synth == "sid808" and m[0] & 0xF0 == 0x80:
                continue                        # (its note offs do nothing: not fed)
            events.append((tune.seconds(t), m))
        folder, _own, latch = feeds.SYNTHS[synth]
        proj = os.path.join(PROJECTS, folder)
        data = feeds.feed_bytes(events, feeds.PAL_CLOCK / (latch + 1), [])
        name = f"{synth}-ch{ch1}"
        asm = os.path.join(out, name + ".asm")
        with open(asm, "w", newline="\n") as f:
            f.write(f"; generated by demo_tunes.py: {synth} playing {tune.title}'s channel {ch1} "
                    f"({label})\n")
            f.write(f'        .include "{os.path.join(proj, folder + ".asm").replace(os.sep, "/")}"\n')
            f.write("test_pattern                    ; (core/test_feed.asm, TEST_MIDI=99)\n")
            for i in range(0, len(data), 16):
                f.write("        .byte " + ", ".join(f"${b:02x}" for b in data[i:i + 16]) + "\n")
            f.write("feed_end\n")
            f.write(f'        .cerror feed_end > ${feeds.PATTERN_RAM:04x}, "the feed runs into the patterns"\n')
        prg = os.path.join(out, name + ".prg")
        r = subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", *feeds.version_defines(proj),
                            "-D", "TEST_MIDI=99", "-D", "VIDEO_MARK=1", "-I", proj,
                            "-l", prg + ".lbl", "-o", prg, asm], cwd=proj, capture_output=True,
                           text=True)
        if r.returncode:
            sys.exit(f"{name}: build failed\n{r.stdout}{r.stderr}")
        frame = "%04x" % labels(prg + ".lbl")["video_frame"]
        print(f"{name} ({label}): {len(events)} messages, {len(data)} feed bytes; rendering "
              f"{seconds:.0f} s")
        jobs.append((name, [sys.executable, os.path.join(C64TOOLS, "vicerec.py"), prg,
                            os.path.join(out, name + ".mp4"), "--frame-addr", frame,
                            "--seconds", f"{seconds:.0f}", "--sid", "8580", "--skip", "1",
                            "--crop", "screen", "--scale", "1",
                            "--port", str(rec_port(key) + 1 + len(jobs))]))
    return jobs


def step_render(key, out):
    """SID500's video and every synth's render at once."""
    record([sid500_job(key, out)] + synth_jobs(key, out))


# ---- the mix and the video
RATE = 48000
PRE = 3.0                       # seconds of the video before the song's first beat
LOUDNESS = {"drums": -25.0, "percussion": -30.0, "bass": -26.5, "sub bass": -26.5,
            "skank": -30.0, "melodica": -21.5, "siren": -31.0, "lead": -26.0, "chords": -30.0,
            "pad": -31.0, "arp": -30.5, "acid": -29.0, "pluck": -30.5,
            "triplets": -27.0, "melody": -24.5, "melody octave": -29.5, "bass octave": -29.0}
PAN = {"skank": 0.35, "melodica": -0.3, "siren": -0.45, "arp": 0.4, "pad": -0.25,
       "chords": 0.0, "lead": -0.15, "pluck": -0.35}            # -1 left .. 1 right (else the middle)
LABEL_NAME = {"sid101": "SID101", "sid303": "SID303", "sid808": "SID808"}


DUCKED = ("bass", "acid")      # parts dipped under the kick (the kick heard over them)
DUCK_DB, DUCK_S = -8.0, 0.15    # by how much, for how long (then back over as long again)
KICK_NOTES = (35, 36)


LOW_BOOST = {"drums": (9.0, 120.0)}   # dB below Hz: SID808's kick (a low triangle) up
                                # against the bass (its loudness is the hats')


def low_shelf(y, db, hz):
    """y with the frequencies below hz raised by db (a smooth 4th-order
    shelf, by FFT: offline, no phase change)."""
    import numpy as np
    F = np.fft.rfft(y)
    f = np.fft.rfftfreq(len(y), 1 / RATE)
    F *= 1 + (10 ** (db / 20) - 1) / (1 + (f / hz) ** 4)
    return np.fft.irfft(F, len(y))


def duck_envelope(tune, n):
    """A gain for the mix's samples (its time: PRE before the song): down
    DUCK_DB at each kick on channel 10, back over DUCK_S."""
    import numpy as np
    g = np.ones(n)
    low = 10 ** (DUCK_DB / 20)
    hold, rel = int(DUCK_S * RATE), int(DUCK_S * RATE)
    shape = np.concatenate([np.full(hold, low), np.linspace(low, 1, rel)])
    for t, ch, m in tune.messages():
        if ch == 9 and m[0] & 0xF0 == 0x90 and m[2] and m[1] in KICK_NOTES:
            i = int((PRE + tune.seconds(t)) * RATE) - int(0.005 * RATE)
            j = min(n, i + len(shape))
            if 0 <= i < n:
                g[i:j] = np.minimum(g[i:j], shape[:j - i])
    return g


VOICE_PART = {"chord": "chords"}    # a chord voice's part's name, if not its own
VOICE_SPREAD = {"low": -0.3, "mid": 0.0, "high": 0.3}


def voice_of(label):
    """("part", spread) for a chord voice's label ("skank low", "pad high",
    "chord mid": one note of a chord, a SID101 each), else (label, None)."""
    part, _, voice = label.rpartition(" ")
    if voice in VOICE_SPREAD and part:
        return VOICE_PART.get(part, part), VOICE_SPREAD[voice]
    return label, None


def loudness_of(label, levels=None):
    """A part's target loudness (LUFS), or the tune's own (Tune.levels);
    a chord voice's: three together about as loud as the part."""
    part, spread = voice_of(label)
    base = (levels or {}).get(part, LOUDNESS[part])
    return base - (4.5 if spread is not None else 0.0)


def pan_of(label):
    """-1 left .. 1 right; a chord's voices spread around the part's place."""
    part, spread = voice_of(label)
    return max(-1.0, min(1.0, PAN.get(part, 0.0) + (spread or 0.0)))


def song_start_in_sid500(path, rate=50):
    """SID500's video: the time its title row first shows the song playing
    (the frame whose title's right end ("PLAY") is as it is late in the
    video), seconds."""
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf",
                          "crop=40:8:280:0,format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, 8 * 40).astype(int)
    ref = frames[int(len(frames) * 0.6)]
    # (near enough: the video's compression changes a few pixels at its key frames)
    same = np.nonzero(np.abs(frames - ref).sum(axis=1) <= 8 * 40 * 4)[0]
    return int(same[0]) / rate


def step_video(key, out):
    import numpy as np
    import wave
    sys.path.insert(0, BAND)
    import levels
    import mix_band
    import sync
    tune = load_tune(key)
    song_s = tune.seconds(tune.length_ticks())
    total = PRE + song_s + 4.0
    tracks, starts = {}, {}
    for ch1, (synth, label, _p) in sorted(tune.synths.items()):
        name = f"{synth}-ch{ch1}"
        x = mix_band.read_render(os.path.join(out, name + ".mp4"), RATE)
        times = sync.note_times(part_mid(tune, out, ch1 - 1), ch1 - 1, tune.tempo)
        lag = sync.lag(x, RATE, times)          # the render's song start (its time 0)
        starts[name] = lag
        y = mix_band.shifted(x, int(round((lag - PRE) * RATE)))[:int(total * RATE)]
        y = np.pad(y, (0, max(0, int(total * RATE) - len(y))))
        loud = levels.loudness(y, RATE)         # (the level from the part as rendered)
        g = 10 ** ((loudness_of(label, getattr(tune, 'levels', None)) - loud) / 20)
        if label in DUCKED:
            y = y * duck_envelope(tune, len(y))
        if label in LOW_BOOST:
            y = low_shelf(y, *LOW_BOOST[label])
        tracks[name] = (y * g, pan_of(label), label)
        print(f"{name} ({label}): {len(times)} notes, its song start at {lag:.3f} s, "
              f"{loud:.1f} LUFS, {20 * np.log10(g):+.1f} dB")
    n = int(total * RATE)
    mix = np.zeros((n, 2))
    for y, pan, _label in tracks.values():
        mix += panned(y, pan)
    wav = write_mix(out, key, mix)
    np.savez_compressed(os.path.join(out, "parts.npz"), total=total,
                        **{f"{name}|{label}|{pan}": y.astype(np.float32)
                           for name, (y, pan, label) in tracks.items()})
    starts["sid500"] = song_start_in_sid500(os.path.join(out, "sid500.mp4"))
    print(f"sid500: the song starts at {starts['sid500']:.2f} s of its video")
    compose(tune, out, starts, total, wav)
    step_fx(key, out)


def panned(y, pan):
    """A mono part placed in stereo (constant power)."""
    import numpy as np
    return np.stack([y * np.sqrt(1 - pan), y * np.sqrt(1 + pan)], axis=1)


def write_mix(out, key, mix, suffix="", fade_s=3.0):
    """The mix faded out at its end, peak-normalised: <key><suffix>.wav, .mp3."""
    import numpy as np
    import wave
    fade = int(fade_s * RATE)
    mix = mix.copy()
    mix[-fade:] *= np.linspace(1, 0, fade)[:, None]
    mix *= 0.89 * 32767 / max(1.0, np.abs(mix).max())
    wav = os.path.join(out, f"{key}{suffix}.wav")
    with wave.open(wav, "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(mix.astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-codec:a", "libmp3lame",
                    "-b:a", "224k", os.path.join(out, f"{key}{suffix}.mp3")], check=True)
    return wav


# ---- the enhanced mix: the same parts, with echo and reverb (the user: a
# second version of each video beside the C64's own sound)
FX = {  # per style: the reverb, the echo (in quarters), each part's sends and its chorus
    "dub": dict(room=0.78, damping=0.55, width=1.0, echo=0.75, feedback=0.55,
                echo_band=(250, 2400),
                sends={"melodica": (0.30, 0.50), "skank": (0.25, 0.40), "siren": (0.35, 0.65),
                       "drums": (0.12, 0.06), "bass": (0.0, 0.0)}),
    "synth": dict(room=0.86, damping=0.45, width=1.0, echo=0.75, feedback=0.42,
                  echo_band=(300, 5000),
                  sends={"arp": (0.22, 0.38), "pad": (0.50, 0.05), "lead": (0.32, 0.30),
                         "acid": (0.08, 0.18), "drums": (0.10, 0.0)},
                  chorus=("pad",)),
    "pop": dict(room=0.58, damping=0.35, width=1.0, echo=0.5, feedback=0.25,
                echo_band=(400, 6000),
                sends={"lead": (0.28, 0.20), "chords": (0.30, 0.0), "pluck": (0.20, 0.28),
                       "drums": (0.12, 0.0), "bass": (0.0, 0.0)},
                chorus=("chords",)),
    "moonlight": dict(room=0.93, damping=0.40, width=1.0, echo=1.0, feedback=0.25,
                      echo_band=(400, 4000),
                      sends={"triplets": (0.38, 0.0), "melody": (0.42, 0.14),
                             "melody octave": (0.55, 0.10), "pad": (0.62, 0.0),
                             "bass": (0.18, 0.0), "bass octave": (0.15, 0.0)},
                      chorus=("pad",)),
}


def fx_mix(tune, parts):
    """parts [(mono, pan, label)] -> the enhanced stereo mix: each part dry
    (its chorus first, if its style has one), its sends to one reverb and
    one tempo echo (the right side's echo half a beat later than the
    left's: it moves across), filtered; then a gentle compressor and a
    limiter."""
    import numpy as np
    from pedalboard import (Pedalboard, Reverb, Delay, Chorus, Compressor, Limiter,
                            HighpassFilter, LowpassFilter)
    fx = FX[tune.style]
    n = len(parts[0][0])
    dry = np.zeros((n, 2), np.float32)
    rev_in = np.zeros((n, 2), np.float32)
    echo_in = np.zeros((n, 2), np.float32)
    chorus = Pedalboard([Chorus(rate_hz=0.4, depth=0.25, centre_delay_ms=9, feedback=0.0, mix=0.45)])
    for y, pan, label in parts:
        part = voice_of(label)[0]
        st = panned(y, pan).astype(np.float32)
        if part in fx.get("chorus", ()):
            st = chorus(st.T.copy(), RATE).T
        r, e = fx["sends"].get(part, (0.15, 0.0))
        dry += st
        rev_in += r * st
        echo_in += e * st
    scale = 1.0 / max(1.0, np.abs(dry).max())   # (pedalboard works on -1..1)
    dry, rev_in, echo_in = dry * scale, rev_in * scale, echo_in * scale
    beat = 60.0 / tune.tempo
    lo, hi = fx["echo_band"]
    echo = np.zeros_like(echo_in)
    for side, extra in ((0, 0.0), (1, 0.5)):    # (left: the echo; right: half a beat later)
        board = Pedalboard([HighpassFilter(lo), LowpassFilter(hi),
                            Delay(delay_seconds=beat * (fx["echo"] + extra),
                                  feedback=fx["feedback"], mix=1.0)])
        echo[:, side] = board(echo_in[:, side].copy()[None, :], RATE)[0]
    rev = Pedalboard([HighpassFilter(150), Reverb(room_size=fx["room"], damping=fx["damping"],
                                                  wet_level=1.0, dry_level=0.0,
                                                  width=fx["width"])])
    wet = rev((rev_in + 0.35 * echo).T.copy(), RATE).T
    out = dry + wet + echo
    master = Pedalboard([Compressor(threshold_db=-16, ratio=2.0, attack_ms=15, release_ms=180),
                         Limiter(threshold_db=-1.0, release_ms=120)])
    return master(out.T.copy(), RATE).T


def step_fx(key, out):
    """The enhanced mix from the parts the C64 mix used (parts.npz), and its
    video: the C64 video's picture with this sound."""
    import numpy as np
    tune = load_tune(key)
    data = np.load(os.path.join(out, "parts.npz"))
    parts = []
    for k in data.files:
        if k == "total":
            continue
        name, label, pan = k.split("|")
        parts.append((data[k].astype(np.float32), float(pan), label))
    mix = fx_mix(tune, parts)
    wav = write_mix(out, key, mix, suffix="-fx")
    video = os.path.join(out, f"{tune.name}-sid500.mp4")
    fx_video = os.path.join(out, f"{tune.name}-sid500-fx.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video, "-i", wav,
                    "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "224k",
                    "-ar", "48000", "-shortest", fx_video], check=True)
    print(f"the enhanced video: {fx_video}")


def compose(tune, out, starts, total, wav):
    import shutil
    font = os.path.join(out, "consolab.ttf")
    if not os.path.exists(font):
        shutil.copy(r"C:\Windows\Fonts\consolab.ttf", font)
    W, H, STRIP = 640, 400, 44
    tiles = [("sid500", f"SID500  sequencer   {tune.title}  {tune.tempo} BPM")]
    for ch1, (synth, label, preset) in sorted(tune.synths.items(),
                                             key=lambda kv: (kv[1][0] != "sid808", kv[0])):
        extra = f"  {preset}" if preset else ""
        tiles.append((f"{synth}-ch{ch1}", f"{LABEL_NAME[synth]}  {label} (ch {ch1}){extra}"))
    assert len(tiles) <= 9
    cells = 6 if len(tiles) <= 6 else 9      # (3x2, or 3x3)
    args = ["ffmpeg", "-y", "-loglevel", "error"]
    for name, _ in tiles:
        args += ["-i", f"{name}.mp4"]
    args += ["-i", os.path.basename(wav)]
    parts = []
    for k, (name, text) in enumerate(tiles):
        s = starts[name] - PRE
        f = f"[{k}:v]"
        if s < 0:
            f += f"tpad=start_duration={-s:.3f}:start_mode=clone,"
            s = 0
        text = text.replace(":", "\\:").replace("'", "")
        f += (f"trim=start={s:.3f}:duration={total:.2f},setpts=PTS-STARTPTS,"
              f"tpad=stop_mode=clone:stop_duration={total:.2f},trim=duration={total:.2f},"
              f"scale={W}:{H}:flags=neighbor,pad={W}:{H + STRIP}:0:0:color=0x181818,"
              f"drawtext=fontfile=consolab.ttf:text='{text}':x=12:y={H + 11}:fontsize=22:"
              f"fontcolor=white[v{k}]")
        parts.append(f)
    while len(parts) < cells:                   # (an empty tile)
        k = len(parts)
        parts.append(f"color=c=0x181818:s={W}x{H + STRIP}:d={total:.2f}:r=50[v{k}]")
    layout = "|".join(f"{(k % 3) * W}_{(k // 3) * (H + STRIP)}" for k in range(cells))
    parts.append("".join(f"[v{k}]" for k in range(cells)) + f"xstack=inputs={cells}:layout={layout},"
                 f"fade=t=in:st=0:d=0.6,fade=t=out:st={total - 2.5:.2f}:d=2.5[v]")
    parts.append(f"[{len(tiles)}:a]atrim=0:{total:.2f}[a]")
    args += ["-filter_complex", ";".join(parts), "-map", "[v]", "-map", "[a]", "-c:v", "libx264",
             "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", "50", "-c:a", "aac",
             "-b:a", "224k", "-ar", "48000", f"{tune.name}-sid500.mp4"]
    subprocess.run(args, check=True, cwd=out)
    print(f"the video: {os.path.join(out, tune.name + '-sid500.mp4')}")


def main():
    key, step = sys.argv[1], sys.argv[2]
    out = os.path.abspath(sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, "work", "tunes",
                                                                              key))
    os.makedirs(out, exist_ok=True)
    steps = {"disk": step_disk, "sid500": step_sid500, "check": step_check,
             "synths": step_synths, "render": step_render, "video": step_video, "fx": step_fx}
    for st in (["disk", "render", "check", "video"] if step == "all" else [step]):
        print(f"== {st}")
        sys.stdout.flush()
        steps[st](key, out)


if __name__ == "__main__":
    main()
