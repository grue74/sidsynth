# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate tables.inc for sid808.asm (64tass syntax): the drum sounds as
step programs, the GM note map, decay factors, filter settings, the attack
mute times and the TEST_MIDI beat.

Run:  python tables.py            (build.sh does this before assembling)

The sounds are tuned here, in milliseconds and Hz; the 6502 side only runs
the programs (src/engine.asm). See docs/design.md.
"""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
from tables_core import PAL_CLOCK, k16, sq_tables, table, tick_latch  # noqa: E402

TICK_HZ = 500                   # must match TICK_HZ in sid808.asm
TICK_LATCH_500 = round(PAL_CLOCK / TICK_HZ) - 1     # = TICK_LATCH in tables.inc (1969)
TICK_MS = 1000 / TICK_HZ
CYCLES_PER_TICK = PAL_CLOCK / TICK_HZ
MUTE_MARGIN = 1                 # extra attack mute ticks: VICE (8580) showed the envelope
                                # still at full one tick after the computed settle time
                                # (cause not identified)

# SID control register bits
GATE, SYNC, RING, TEST = 0x01, 0x02, 0x04, 0x08
TRI, SAW, PUL, NOI = 0x10, 0x20, 0x40, 0x80

FOREVER = 255                   # step ticks: until the level has decayed to 0
STEP_SIZE = 11                  # bytes per step (src/engine.asm reads them by offset)

# filter mode bits ($D418 bits 4-6)
LP, BP, HP = 0x10, 0x20, 0x40


def sid_freq(hz):
    """SID oscillator register value for hz (PAL)."""
    return max(1, min(65535, round(hz * 16777216 / PAL_CLOCK)))


def glide_shift(ms):
    """Glide: freq moves 1/2^shift of the way to the target each tick, so the
    time constant is about 2^shift ticks. Nearest shift for ms (1..8)."""
    return max(1, min(8, round(math.log2(ms / TICK_MS))))


# --- decay rates and filter settings: collected while the sounds are built ---
decays = []                     # time constants in seconds; index 0 = no decay
filters = [None]                # (mode, cutoff Hz, resonance 0..15); index 0 = unfiltered


def decay_index(seconds):
    if seconds is None:
        return 0
    if seconds not in decays:
        decays.append(seconds)
    return decays.index(seconds) + 1


def filter_index(setting):
    """Index of a filter setting: (mode, cutoff Hz, resonance) or
    (mode, cutoff Hz, resonance, velocity Hz, random Hz)."""
    if setting is None:
        return 0
    setting = tuple(setting) + (0, 0)[len(setting) - 3:]
    if setting not in filters:
        filters.append(setting)
    return filters.index(setting)


def step(ms, wave, hz=None, reg=None, to=None, glide_ms=None, pw=0.5,
         level=None, decay=None, filt=None):
    """One program step, STEP_SIZE bytes (layout: src/engine.asm, step_load).

    ms        how long it lasts (FOREVER: until the level is 0)
    wave      SID control byte, gate included (a step without GATE releases)
    hz / reg  start frequency in Hz, or a raw register value (noise); neither
              = keep the current frequency
    to        glide target in Hz, glide_ms its time constant
    pw        pulse width 0..1
    level     0..1: restart the level at this x velocity; None = keep
    decay     level time constant in seconds from here on; None = keep the
              previous step's (the first step must give one)
    filt      (mode, cutoff Hz, resonance[, velocity Hz, random Hz]) or None
              for unfiltered. The cutoff is for velocity 127; velocity Hz is
              how much lower it is at velocity 0 (soft hits darker), random
              Hz how far each hit moves it up at random (a new random value
              per hit, the same for all its steps). Only the first step
              claims the filter, later steps keep its setting unless they
              give their own
    """
    assert not (wave & NOI and wave & (TRI | SAW | PUL)), "noise + another waveform locks up the SID"
    ticks = FOREVER if ms == FOREVER else max(1, min(254, round(ms / TICK_MS)))
    f = sid_freq(hz) if hz else (reg or 0)
    t = sid_freq(to) if to else f
    g = glide_shift(glide_ms) if to else 0
    p = max(1, min(255, round(pw * 256)))
    lv = 0 if level is None else max(1, min(255, round(level * 255)))
    return [ticks, wave, f & 255, f >> 8, t & 255, t >> 8, g, p, lv,
            decay_index(decay) if decay is not None else 255, filter_index(filt)]


END = [0] * STEP_SIZE           # ticks 0 = end of the program

# -----------------------------------------------------------------------------
# The sounds. Rough first versions, to be tuned by ear (docs/design.md 8).
# (name for the status row, priority 1..255, choke group, steps)
# -----------------------------------------------------------------------------
# hats: velocity sets brightness (2.5 kHz darker at velocity 0), each hit up to
# ~0.7 kHz brighter at random, and the filter starts higher and settles
HAT_ATTACK = (HP, 9500, 5, 2500, 700)
HAT_BODY = (HP, 7500, 5, 2500, 700)


def tom(hz):
    """Triangle dropping from 1.6x to hz (the second step carries the glide on;
    until that fix the drop stopped after one tick and toms rang at ~1.5x).
    demos/toms-compare.wav: this is version 1; sag (A), a stick tick (B) and
    velocity/random pitch (C) were tried and not chosen."""
    return [step(2, TRI | GATE, hz=hz * 1.6, to=hz, glide_ms=20, level=1.0, decay=0.20),
            step(FOREVER, TRI | GATE)]


SOUNDS = [
    ("Kck", 255, 0, [                                   # kick: a triangle dropping fast from 500 Hz,
        step(FOREVER, TRI | GATE, hz=500, to=48, glide_ms=6, level=1.0, decay=0.30)]),
                                                        # the knock comes from the drop (like the 808).
                                                        # Brighter alternative (demos/kick-compare.wav B):
                                                        # step(2, TRI | GATE, hz=1200, level=1.0, decay=0.30),
                                                        # step(FOREVER, TRI | GATE, hz=200, to=48, glide_ms=12)
                                                        # The old 600 Hz pulse click (A) was too clicky.
    ("Snr", 230, 1, [                                   # snare: tone, then snappy noise
        step(12, TRI | GATE, hz=330, to=185, glide_ms=8, level=1.0, decay=0.08),
        step(FOREVER, NOI | GATE, reg=0xc000, decay=0.06)]),
    ("Clp", 210, 2, [                                   # clap: three bursts, then the tail
        step(8, NOI | GATE, reg=0x9000, level=1.0, decay=0.008, filt=(BP, 1100, 10)),
        step(2, NOI),
        step(8, NOI | GATE, level=1.0),
        step(2, NOI),
        step(8, NOI | GATE, level=1.0),
        step(2, NOI),
        step(FOREVER, NOI | GATE, level=0.8, decay=0.10)]),
    ("CHH", 70, 3, [                                    # closed hat
        step(4, NOI | GATE, reg=0xf000, level=0.9, decay=0.03, filt=HAT_ATTACK),
        step(FOREVER, NOI | GATE, filt=HAT_BODY)]),
    ("OHH", 90, 3, [                                    # open hat (same group: chokes/choked)
        step(10, NOI | GATE, reg=0xf000, level=0.9, decay=0.25, filt=HAT_ATTACK),
        step(FOREVER, NOI | GATE, filt=HAT_BODY)]),
    ("Cbl", 150, 4, [                                   # cowbell on one voice (when no voice pair is
        step(20, PUL | GATE, hz=800, pw=0.5, level=1.0, decay=0.03, filt=(BP, 1600, 6)),
        step(FOREVER, PUL | GATE, decay=0.25)]),        # free for RING_SOUNDS' version): one tone, brighter
                                                        # than the old 800 Hz band-pass (a beep)
    ("LTm", 190, 5, tom(90)),
    ("MTm", 190, 6, tom(130)),
    ("HTm", 190, 7, tom(185)),
    ("Rim", 130, 8, [                                   # rimshot: the 808's two tones (~1667 and 455 Hz),
        step(3, TRI | GATE, hz=1667, level=1.0, decay=0.010),   # a 6 ms tick of the upper,
        step(FOREVER, TRI | GATE, hz=455)]),            # then the lower ringing out (demos/rim-compare.mp4
                                                        # G; A the old 1700 Hz pulse click was harsh; B-D
                                                        # rang both together by ring modulation, which
                                                        # buzzed: the partner's square adds 757/2879 Hz)
    ("Clv", 120, 9, [                                   # claves: a quick small pitch drop makes it a hit,
        step(FOREVER, TRI | GATE, hz=2300, to=1900, glide_ms=4, level=1.0, decay=0.018)]),
                                                        # not a beep (demos/claves-compare.wav A; the old
                                                        # steady 2500 Hz tone was 0)
    ("Cym", 100, 10, [                                  # cymbal
        step(FOREVER, NOI | GATE, reg=0xe000, level=0.9, decay=0.60, filt=(HP, 5000, 2))]),
    ("Mrc", 50, 11, [                                   # maracas
        step(FOREVER, NOI | GATE, reg=0xff00, level=0.7, decay=0.015, filt=(HP, 9000, 0))]),
]

# Sounds with a ring-modulated version on a voice pair (docs/design.md 4): the
# program runs on a voice whose ring partner (the voice that modulates it: 1 <-
# 3, 2 <- 1, 3 <- 2) is free; the partner's oscillator runs at partner Hz,
# silent, while the sound lasts. Cowbell: a triangle at 670 Hz ring-modulated
# by 130 Hz = 540 + 800 Hz, the 808's two squares (demos/cowbell-compare.wav 3,
# cowbell-compare-2.wav 1: chosen over two real pulse voices and over one
# voice switching between the two pitches, which only buzzed at 670 Hz).
RING_SOUNDS = {
    "Cbl": (130, [step(20, TRI | RING | GATE, hz=670, level=1.0, decay=0.03, filt=(BP, 800, 8)),
                  step(FOREVER, TRI | RING | GATE, decay=0.25)]),
}

# Pitch variation per sound (voice_start, step_load): (raise at full velocity
# in %, random raise per hit up to %), e.g. "LTm": (8, 3). A harder hit
# stretches the skin: it starts higher; the random part is analog-like drift.
# Tried on the toms (demos/toms-compare.wav C): the plain drop (1) won.
SOUND_PITCH = {}

# General MIDI drum notes -> sound index
GM = {35: "Kck", 36: "Kck", 37: "Rim", 38: "Snr", 39: "Clp", 40: "Snr",
      41: "LTm", 42: "CHH", 43: "LTm", 44: "CHH", 45: "MTm", 46: "OHH",
      47: "MTm", 48: "HTm", 49: "Cym", 50: "HTm", 51: "Cym", 52: "Cym",
      55: "Cym", 56: "Cbl", 57: "Cym", 59: "Cym", 70: "Mrc", 75: "Clv"}
GM_FIRST, GM_LAST = 35, 75


def sounds_tables():
    """Programs, per-sound tables and the note map."""
    out = []
    names = [s[0] for s in SOUNDS]
    progs = []

    def program(name, steps):
        data = []
        last_decay = None
        prev = None
        for n, s in enumerate(steps):
            if s[9] == 255:                 # decay None: keep the previous one
                assert last_decay is not None, f"{name}: first step needs a decay"
                s = s[:9] + [last_decay] + s[10:]
            last_decay = s[9]
            if n and s[10] == 0:            # filter: later steps keep the first step's
                s = s[:10] + [steps[0][10]]
            if prev and s[2] == s[3] == 0 and s[6] == 0:
                s = s[:4] + prev[4:7] + s[7:]   # pitch kept, no glide given: the glide goes on
            prev = s
            data += s
        data += END
        assert steps[0][8] != 0, f"{name}: first step needs a level"
        return data

    for i, (name, prio, group, steps) in enumerate(SOUNDS):
        progs.append(f"prog_{i}")
        out.append(table(f"prog_{i}", program(name, steps),
                         f"sound {i} ({name}): {len(steps)} steps of {STEP_SIZE} bytes", per_line=STEP_SIZE))
    # ring-modulated versions (RING_SOUNDS): program and partner frequency
    ring_progs, ring_freq = [], []
    for i, (name, prio, group, steps) in enumerate(SOUNDS):
        if name in RING_SOUNDS:
            hz, rsteps = RING_SOUNDS[name]
            out.append(table(f"prog_ring_{i}", program(name, rsteps),
                             f"sound {i} ({name}), ring version: {len(rsteps)} steps", per_line=STEP_SIZE))
            ring_progs.append(f"prog_ring_{i}")
            ring_freq.append(sid_freq(hz))
        else:
            ring_progs.append("0")
            ring_freq.append(0)
    out.append(f"NUM_SOUNDS = {len(SOUNDS)}\n")
    out.append("sound_prog_lo   .byte " + ",".join(f"<{p}" for p in progs) + "\n")
    out.append("sound_prog_hi   .byte " + ",".join(f">{p}" for p in progs) + "\n")
    out.append("; ring version per sound (voice_pick, voice_start), 0 = none\n")
    out.append("sound_ring_lo   .byte " + ",".join(f"<{p}" for p in ring_progs) + "\n")
    out.append("sound_ring_hi   .byte " + ",".join(f">{p}" for p in ring_progs) + "\n")
    out.append(table("ring_freq_lo", [f & 255 for f in ring_freq], "ring partner's frequency per sound, low bytes"))
    out.append(table("ring_freq_hi", [f >> 8 for f in ring_freq], "... high bytes"))
    out.append(table("sound_prio", [s[1] for s in SOUNDS], "steal resistance per sound (1..255)"))
    out.append(table("sound_group", [s[2] for s in SOUNDS], "choke group per sound"))
    # filtered sounds that aren't noise (the cowbell, both versions): their
    # edges (pulse, ring modulation) through another mode, the hats' high-pass,
    # came out as snaps, so they keep the filter while they sound (filter_keep)
    def holds(name, steps):
        rs = RING_SOUNDS.get(name, (0, []))[1]
        return int(any(st[10] and not st[1] & NOI for st in steps + rs))
    out.append(table("sound_fhold", [holds(s[0], s[3]) for s in SOUNDS],
                     "1 = keeps the filter while it sounds against another mode (filter_keep)"))
    velp, det = [], []
    for name in names:
        vp, dp = SOUND_PITCH.get(name, (0, 0))
        k = round(vp / 100 * 256)
        r = round(dp / 100 * 256)
        m = (1 << ((r + 1).bit_length() - 1)) - 1      # AND mask: largest 2^n - 1 <= r
        assert k + m <= 255, name
        velp.append(k)
        det.append(m)
    out.append(table("sound_velpitch", velp,
                     "pitch raise at full velocity per sound, x/256 of the pitch (voice_start)"))
    out.append(table("sound_detune", det,
                     "random pitch raise per hit: AND mask, x/256 of the pitch (voice_start)"))
    out.append("        .enc \"screen\"\n; status row names, 3 characters per sound\nsound_names\n"
               + "".join(f"        .text \"{n}\"\n" for n in names) + "        .enc \"none\"\n")
    notes = [names.index(GM[n]) if n in GM else 255 for n in range(GM_FIRST, GM_LAST + 1)]
    out.append(f"GM_FIRST = {GM_FIRST}\nGM_LAST = {GM_LAST}\n")
    out.append(table("note_sound", notes, f"sound per MIDI note {GM_FIRST}..{GM_LAST}, $FF = none"))
    # MIDI out: each sound's GM note, the usual one (the demo track's notes)
    gm_out = [next(n for n in TRACK_NOTES.values() if GM[n] == name) for name in names]
    out.append(table("sound_gm", gm_out, "GM drum note each sound sends (MIDI out)"))
    return "\n".join(out)


def decay_tables():
    """The level decay of one tick, precomputed (src/engine.asm, level_decay):
    for each rate a page of the amount to subtract at each env_hi, exactly
    what the core's env_decay computes from env_hi and the 16-bit factor k
    (env_hi x k / 256 with the low product's low byte dropped, at least 1).
    Low bytes: one page per rate, then the high bytes; page-aligned."""
    ks = [0] + [k16(s, hz=TICK_HZ) for s in decays]
    lo, hi = [], []
    for k in ks:
        for e in range(256):
            d = max(1, e * (k >> 8) + ((e * (k & 255)) >> 8))
            assert d < 65536
            lo.append(d & 255)
            hi.append(d >> 8)
    return (f"NUM_DECAYS = {len(ks)}\n        .align 256\n"
            + table("decay_dlo", lo, "level decay per tick: NUM_DECAYS pages (rate 0 = none) "
                    "of the low byte to subtract, index env_hi (level_decay)", per_line=16)
            + "\n" + table("decay_dhi", hi, "... and the high bytes, NUM_DECAYS more pages", per_line=16))


def score_tables():
    """voice_pick's scores without multiplies (src/voices.asm): a page per
    sound, entry n = n x the sound's priority / 256, the high byte of the
    mul8 product it replaces. Index a voice's level (env_hi) or a new hit's
    velocity x 2."""
    data = []
    for s in SOUNDS:
        data += [(n * s[1]) >> 8 for n in range(256)]
    return ("        .align 256\n"
            + table("score_tab", data, "voice_pick score: a page per sound, n x priority / 256",
                    per_line=16))


CUTOFF_STEP_HZ = 5.86 * 8      # 8580: ~30 Hz + 5.86 Hz per step of the 11-bit cutoff; we set the high 8 bits


def filter_tables():
    """Per filter setting: cutoff at velocity 0, velocity range and random
    mask in cutoff register steps (src/voices.asm, filter_apply: cutoff =
    filt_cutoff + velocity x 2 x filt_vel / 256 + (random AND filt_rand))."""
    cut, vel, rnd = [0], [0], [0]
    for _, hz, _, vel_hz, rand_hz in filters[1:]:
        v = min(255, round(vel_hz / CUTOFF_STEP_HZ))
        top = round((hz - 30) / CUTOFF_STEP_HZ)
        cut.append(max(0, min(255, top - v)))
        vel.append(v)
        r = round(rand_hz / CUTOFF_STEP_HZ)
        rnd.append((1 << r.bit_length()) - 1 if r else 0)     # AND mask: 2^n - 1 >= r
    mode = [0] + [f[0] for f in filters[1:]]
    reso = [0] + [f[2] << 4 for f in filters[1:]]
    return (table("filt_cutoff", cut, "filter cutoff ($D416) at velocity 0 per filter setting; 0 = unfiltered")
            + "\n" + table("filt_vel", vel, "cutoff added at full velocity (x velocity x 2 / 256)")
            + "\n" + table("filt_rand", rnd, "random cutoff offset per hit: AND mask")
            + "\n" + table("filt_mode", mode, "filter mode bits ($D418 4-6)")
            + "\n" + table("filt_reso", reso, "resonance ($D417 bits 4-7)"))


def mute_table():
    """Ticks of the attack mute phase per sustain level 0..15 (docs/design.md 5).

    With every ADSR rate 0 the envelope rises 0->255 in 255 x 9 cycles, then
    falls to the sustain level 17*n one step per 9 cycles x the exponential
    counter period (1, 2, 4, 8, 16, 30 below 255, 93, 54, 26, 14, 6). The
    waveform starts once it has settled; plus one tick for the gate-off."""
    def period(level):
        for limit, p in ((93, 1), (54, 2), (26, 4), (14, 8), (6, 16)):
            if level > limit:
                return p
        return 30
    ticks = []
    for n in range(16):
        cyc = 255 * 9
        level = 255
        while level > 17 * n:
            cyc += 9 * period(level)
            level -= 1
        ticks.append(MUTE_MARGIN + 1 + math.ceil(cyc / CYCLES_PER_TICK))
    return table("mute_ticks", ticks, "attack mute phase in ticks, per sustain level 0..15")


def feed_bytes(events, end):
    """test_feed byte stream from (tick, [status, note, velocity]) events.

    Messages on the same tick go in one entry; running status drops repeated
    status bytes. Entry format: count, bytes..., ticks until the next entry;
    count 0 = end (restart). Waits over 255 ticks are padded with active
    sensing ($FE, ignored)."""
    entries = []
    for tick, b in sorted(events, key=lambda e: e[0]):
        if entries and entries[-1][0] == tick:
            entries[-1][1].extend(b)
        else:
            entries.append((tick, list(b)))
    data = []
    status = None
    for i, (tick, b) in enumerate(entries):
        out = []
        for j in range(0, len(b), 3):
            if b[j] != status:
                out.append(b[j])
                status = b[j]
            out += b[j + 1:j + 3]
        nxt = entries[i + 1][0] if i + 1 < len(entries) else end
        wait = nxt - tick - 1
        while wait > 255:
            data += [len(out)] + out + [255]
            out = [0xFE]
            wait -= 256
        data += [len(out)] + out + [wait]
    data.append(0)
    return data


STEP_T = round(TICK_HZ * 60 / 125 / 4)      # 16th note at 125 BPM: 60 ticks
NOTE_ON = 0x99                              # note on, channel 10 (GM drums)


FADE_TO = 24                    # envelope level a fading voice must reach before a restart (~1/10)


# -----------------------------------------------------------------------------
# Sound page knobs (src/knobs.asm): Level 0..15, Tune -12..+12 semitones,
# Decay 0..15. The defaults (LEVEL_MAX, TUNE_CENTER, DECAY_CENTER) leave a
# sound exactly as its program is: the engine skips the knob there.
# -----------------------------------------------------------------------------
LEVEL_MAX = 15
TUNE_CENTER = 12                # knob value of 0 semitones (0..24 = -12..+12)
DECAY_CENTER = 8                # knob value of the program's own decay
DECAY_UNIT = 32                 # decay speed unit: one level_decay per tick
TONE_CENTER = 8                 # knob value of the program's own brightness


def knob_tables():
    out = [f"LEVEL_MAX = {LEVEL_MAX}\nTUNE_CENTER = {TUNE_CENTER}\nDECAY_CENTER = {DECAY_CENTER}\n"
           f"DECAY_UNIT = {DECAY_UNIT}\n"]
    # Level k < 15: velocity x k / 15 (as factor/256); 15 is skipped (exact)
    out.append(table("level_factor", [round(k * 256 / LEVEL_MAX) for k in range(LEVEL_MAX)],
                     "Level knob 0..14: velocity factor x/256 (15: unchanged)"))
    # Tune: frequency x 2^(s/12), s = -12..+12, as f +- f_hi x delta (one multiply,
    # the low byte's share left out as pitch_scale does): delta = |factor - 256|
    # with factor = 256 x 2^(s/12); s = +12 (factor 512) is a doubling (delta 0, up)
    f = [round(256 * 2 ** ((k - TUNE_CENTER) / 12)) for k in range(2 * TUNE_CENTER + 1)]
    out.append(table("tune_delta", [abs(v - 256) & 255 for v in f],
                     "Tune knob: |factor - 256|, factor = 256 x 2^(s/12) (s = +12: 0, a doubling)"))
    out.append(table("tune_up", [1 if v > 256 else 0 for v in f], "... 1 = higher (add), 0 = lower (subtract)"))
    # Decay: level_decay passes per tick in DECAY_UNITs. Faster than the program
    # (knob below 8) at most 2x - each pass costs time - , slower down to 1/4:
    # decay time x 2^((k-8)/8) below 8, x 2^((k-8)/3.5) above (x 4 at 15)
    d = [round(DECAY_UNIT * 2 ** ((DECAY_CENTER - k) / (8 if k < DECAY_CENTER else 3.5))) for k in range(16)]
    assert d[DECAY_CENTER] == DECAY_UNIT and max(d) <= 2 * DECAY_UNIT
    out.append(table("decay_speed", d, "Decay knob: level_decay passes per tick x DECAY_UNIT"))
    # Tone: the attack's brightness x 2^(s/12), s from -12 (knob 0: half) to +12
    # (knob 15: double), as a Tune knob value for tune_word: a filtered sound's
    # cutoff, an unfiltered sound's first step's start pitch
    t = [TUNE_CENTER + round((k - TONE_CENTER) * 12 / (TONE_CENTER if k < TONE_CENTER else 15 - TONE_CENTER))
         for k in range(16)]
    assert t[TONE_CENTER] == TUNE_CENTER and t[0] == 0 and t[15] == 2 * TUNE_CENTER
    out.append(f"TONE_CENTER = {TONE_CENTER}\n")
    out.append(table("tone_tune", t, "Tone knob 0..15: the factor as a Tune knob value (tune_word)"))
    return "\n".join(out)


def fade_table():
    """Ticks a voice needs to fade from sustain level n (0..15) to FADE_TO with
    release rate 0 (voice_end), plus one: the fade starts anywhere in a tick.
    Same envelope timing as mute_table."""
    def period(level):
        for limit, p in ((93, 1), (54, 2), (26, 4), (14, 8), (6, 16)):
            if level > limit:
                return p
        return 30
    ticks = []
    for n in range(16):
        level = 17 * n
        cyc = 0
        while level > FADE_TO:
            cyc += 9 * period(level)
            level -= 1
        ticks.append(1 + math.ceil(cyc / CYCLES_PER_TICK) if cyc else 0)
    return table("fade_ticks", ticks, "fade-out ticks before a restart, per sustain level 0..15")


def test_pattern():
    """TEST_MIDI=1: LEAD_BARS of silence, each sound alone, soft then hard,
    then an 808 beat."""
    events = [(0, [0xFE])]              # (tick, bytes)
    t = LEAD_BARS * 16 * STEP_T
    # 1. audition: every sound at velocity 70 then 127, a quarter note apart
    for name, _, _, _ in SOUNDS:
        note = min(n for n, s in GM.items() if s == name)
        for vel in (70, 127):
            events.append((t, [NOTE_ON, note, vel]))
            t += 4 * STEP_T
    t += 8 * STEP_T
    # 2. a beat: kick, snare, hats, clap, toms and cowbell, four bars, twice
    K, S, C, CH, OH, CB, LT, MT, HT = 36, 38, 39, 42, 46, 56, 41, 45, 48
    bars = [
        {0: [K], 4: [S], 8: [K], 10: [K], 12: [S]},
        {0: [K], 4: [S, C], 7: [K], 8: [K], 12: [S, C]},
        {0: [K], 3: [CB], 4: [S], 6: [CB], 8: [K], 12: [S], 14: [CB]},
        {0: [K], 4: [S], 8: [LT], 10: [MT], 12: [HT], 13: [HT], 14: [S, C], 15: [S]},
    ]
    for _ in range(2):
        for bar in bars:
            for i in range(16):
                hits = list(bar.get(i, []))
                hits.append(OH if i in (2, 10) else CH)
                for n in hits:
                    vel = 127 if i % 4 == 0 else (60 if n == CH and i % 2 else 100)
                    events.append((t + i * STEP_T, [NOTE_ON, n, vel]))
            t += 16 * STEP_T
    data = feed_bytes(events, t + 8 * STEP_T)
    return ".if TEST_MIDI == 1\n" + table("test_pattern", data, "TEST_MIDI=1 pattern (see tables.py)") + ".endif\n"


# -----------------------------------------------------------------------------
# TEST_MIDI=2: a drum track, no audition. Bars are step grids, 16 steps a bar:
# X = accent (127), x = normal (100), o = soft (55), . = rest.
# -----------------------------------------------------------------------------
VEL = {"X": 127, "x": 100, "o": 55}
SWING = 6                       # ticks the off-beat 16ths come late (light shuffle)
TRACK_NOTES = {"kick": 36, "rim": 37, "snare": 38, "clap": 39, "chh": 42, "ohh": 46,
               "ltom": 41, "mtom": 45, "htom": 48, "cym": 49, "cowbell": 56,
               "maracas": 70, "claves": 75}

INTRO = {"kick":    "X.........X.....",
         "chh":     "x.o.x.o.x.o.x.oo"}
INTRO2 = {"kick":   "X.........X..x..",
          "chh":    "x.o.x.o.x.o.x.o.",
          "ohh":    "..............x."}
MAIN = {"kick":     "X.....x...X.....",
        "snare":    "....X.......X...",
        "chh":      "x.o.x.oxx.o.x...",
        "ohh":      "..............x."}
MAIN_CB = dict(MAIN, cowbell="...x..x.....x...", kick="X.....x...X..x..")
MAIN_CLAP = dict(MAIN, clap="............x...")
TOM_FILL = {"kick":  "X.......X.......",
            "snare": "....X...........",
            "chh":   "x.o.x.o.........",
            "htom":  "........x.x.....",
            "mtom":  "...........x.x..",
            "ltom":  "..............xX"}
BREAK = {"kick":    "X..x..x...X..x..",
         "clap":    "....X.......X...",
         "claves":  "x..x..x.....x...",
         "chh":     "..o...o...o...oo"}
BREAK2 = dict(BREAK, claves="x..x..x...x.x...", rim="...............x")
SNARE_FILL = {"kick": "X.......X.......",
              "snare": "....X...o.o.xoxX",
              "chh":   "x.o.x.o........."}
FULL = {"kick":     "X.....x...X..x..",
        "snare":    "....X.......X...",
        "clap":     "............X...",
        "chh":      "x.o.x.oxx.o.x...",
        "ohh":      "..............x.",
        "cowbell":  "...x..x.........",
        "maracas":  "..o...o...o...o."}
FULL_CYM = dict(FULL, cym="X...............", chh="..o.x.oxx.o.x...")
ROLL = {"kick":     "X.......X.......",
        "snare":    "oooooooxxxxxXXXX",
        "ltom":     "........x...x..."}
ENDING = {"kick": "X...............",
          "cym":  "X...............",
          "clap": "X..............."}

TRACK = ([INTRO, INTRO2]
         + [MAIN, MAIN_CLAP, MAIN_CB, TOM_FILL]
         + [BREAK, BREAK2, BREAK, SNARE_FILL]
         + [FULL_CYM, FULL, FULL, ROLL]
         + [ENDING])


# -----------------------------------------------------------------------------
# The drum part of the bass-and-drums demo (TEST_SONG=1; the bass part:
# demos/bass_and_drums.py, SID303). 125 BPM, straight 16ths, 16 bars:
# hats and rim under the bass alone, the kick in, the groove with the clap and
# a snare fill, cowbell and a tom fill, open hats and a crash, an ending hit.
# At most three sounds start on a step: SID808 has three voices.
# -----------------------------------------------------------------------------
DEMO_HATS = {"chh":     "x.o.x.o.x.o.x.o.",
             "rim":     "....o.......o..."}
DEMO_KICK = {"kick":    "X...x...X...x...",
             "chh":     "..x...x...x...x.",
             "rim":     "....o.......o..o"}
DEMO_GROOVE = {"kick":  "X...x...X...x...",
               "clap":  "....X.......X...",
               "chh":   "..x...x...x.....",
               "ohh":   "..............x."}
DEMO_FILL = dict(DEMO_GROOVE, snare=".............xxX", ohh="................")
DEMO_BELL = dict(DEMO_GROOVE, cowbell="...x..x.....x...")
DEMO_TOMS = {"kick":    "X.......X.......",
             "clap":    "....X...........",
             "htom":    "........x.x.....",
             "mtom":    "...........x.x..",
             "ltom":    "..............xX"}
DEMO_PEAK = {"kick":    "X...x...X...x...",
             "clap":    "....X.......X...",
             "ohh":     "..x...x...x...x."}
DEMO_CRASH = dict(DEMO_PEAK, cym="X...............")
DEMO_END = {"kick": "X...............", "cym": "X...............", "clap": "X..............."}
# (pattern, repeats); then two empty bars (pattern 64) so the ending rings out
DEMO_PATTERNS = ["DEMO_HATS", "DEMO_KICK", "DEMO_GROOVE", "DEMO_FILL", "DEMO_BELL",
                 "DEMO_TOMS", "DEMO_CRASH", "DEMO_PEAK", "DEMO_END"]
DEMO_SONG = [("DEMO_HATS", 2), ("DEMO_KICK", 2), ("DEMO_GROOVE", 3), ("DEMO_FILL", 1),
             ("DEMO_BELL", 3), ("DEMO_TOMS", 1), ("DEMO_CRASH", 1), ("DEMO_PEAK", 2),
             ("DEMO_END", 1)]
DEMO_BARS = sum(r for _, r in DEMO_SONG)
assert DEMO_BARS == 16


LEAD_BARS = 2                   # silent bars before the track: time for a recorder
                                # (vicerec.py attaches ~2 s after the program starts)


def track_pattern():
    """TEST_MIDI=2: LEAD_BARS of silence, TRACK above at 125 BPM, then a bar
    to ring out."""
    events = []
    for b, bar in enumerate(TRACK):
        for name, grid in bar.items():
            assert len(grid) == 16, f"bar {b + 1} {name}: {len(grid)} steps"
            for i, c in enumerate(grid):
                if c != ".":
                    t = ((LEAD_BARS + b) * 16 + i) * STEP_T + (SWING if i % 2 else 0)
                    events.append((t, [NOTE_ON, TRACK_NOTES[name], VEL[c]]))
    data = feed_bytes([(0, [0xFE])] + events, (LEAD_BARS + len(TRACK) + 1) * 16 * STEP_T)
    return ".if TEST_MIDI == 2\n" + table("test_pattern", data, "TEST_MIDI=2 drum track (see tables.py)") + ".endif\n"


def rec_test_pattern():
    """TEST_MIDI=3 (with TEST_SEQ=1 TEST_SEQ_PAT=8 TEST_REC=1: FULL plays at
    125 BPM, recording): notes timed against the sequencer's own step phase.
    Tick m = 1 fires step 0; from tick 2 the phase grows by inc per tick. A
    byte fed at feed time t is handled after synth tick m = t + 1, with the
    phase at (m - 1) x inc. Cases (docs/sequencer.md, phase D):
    low tom soft right after step 1 (fired, empty) -> step 1;
    mid tom 1 tick before step 5 -> step 5 (the next);
    high tom accent at 49 % of step 8 -> step 8;
    rim at 51 % of step 9 -> step 10;
    claves in the tick step 12 (3 hits) fires -> step 12, maybe still firing;
    cymbal accent at 51 % of step 15 -> step 0 of the next pass."""
    inc = round(65536 * (125 * 4 / 60) / REAL_TICK_HZ)

    def first_m(phase):         # first tick m whose phase reaches it
        m = 1
        while (m - 1) * inc < phase:
            m += 1
        return m
    full = 65536
    cases = [(first_m(1 * full), 41, 55),
             (first_m(5 * full) - 1, 45, 100),
             (first_m(8.5 * full) - 1, 48, 127),
             (first_m(9.5 * full), 37, 100),
             (first_m(12 * full), 75, 100),
             (first_m(15.5 * full), 49, 127)]
    events = [(0, [0xFE])] + [(m - 1, [NOTE_ON, n, v]) for m, n, v in cases]  # $FE: anchors tick 0
    data = feed_bytes(events, 64 * 16 * 60)
    return (".if TEST_MIDI == 3\n" + table("test_pattern", data, "TEST_MIDI=3 live record test (see tables.py)")
            + ".endif\n")


def feed_raw(events, end):
    """test_feed byte stream like feed_bytes, but the bytes go as given (no
    running status: realtime bytes repeat)."""
    data = []
    events = sorted(events, key=lambda e: e[0])
    for i, (tick, b) in enumerate(events):
        out = list(b)
        nxt = events[i + 1][0] if i + 1 < len(events) else end
        wait = nxt - tick - 1
        while wait > 255:
            data += [len(out)] + out + [255]
            out = [0xFE]
            wait -= 256
        data += [len(out)] + out + [wait]
    data.append(0)
    return data


def clock_test_pattern():
    """TEST_MIDI=4 (with TEST_CLOCK=1): MIDI start, clocks every 10 ticks
    (24 per quarter note at 125 BPM: a step every 60 ticks) for two bars,
    stop, a pause, continue and one more bar."""
    ev = [(0, [0xFE]), (100, [0xFA])]
    ev += [(110 + 10 * i, [0xF8]) for i in range(6 * 32)]
    ev += [(2100, [0xFC]), (2400, [0xFB])]
    ev += [(2410 + 10 * i, [0xF8]) for i in range(6 * 16)]
    return (".if TEST_MIDI == 4\n" + table("test_pattern", feed_raw(ev, 6000), "TEST_MIDI=4 MIDI clock test (see tables.py)")
            + ".endif\n")


def cc_test_pattern():
    """TEST_MIDI=6: the sound page's default controllers (src/params.asm) on
    the selected sound (Kick at start): CC 16 = 64 -> Level 8, CC 17 = 127 ->
    Tune 24 (+12), CC 18 = 0 -> Decay 0, CC 19 = 127 -> Tone 15."""
    ev = [(0, [0xFE]), (100, [0xB0, 16, 64]), (110, [0xB0, 17, 127]), (120, [0xB0, 18, 0]),
          (130, [0xB0, 19, 127])]
    return (".if TEST_MIDI == 6\n" + table("test_pattern", feed_raw(ev, 6000), "TEST_MIDI=6 controller test")
            + ".endif\n")


def cc_for(value, vmax):
    """The smallest controller value the core (param_set_v) turns into value:
    v = cc x 2 + cc / 64, parameter = v x (vmax + 1) / 256."""
    for cc in range(128):
        if (cc * 2 + cc // 64) * (vmax + 1) // 256 == value:
            return cc
    raise ValueError(value)


# TEST_MIDI=7: the places where the engine might go wrong, one section at a
# time, for listening tests (docs/design.md 8). (start in seconds, title,
# what to listen for); the events are made in problem_pattern.
PROBLEM_SECTIONS = [
    (0.0, "Long tails", "kick, open hat, cymbal alone, then the kick at Decay 15 (4x longer): "
          "do the tails fade smoothly or in audible steps (16 levels)?"),
    (11.0, "Soft to hard", "snare, then low tom, velocity 8 to 127 in 16 steps: "
           "an even rise, no thump or spike on the soft ones (the attack mute)?"),
    (19.5, "Flams and chokes", "closed then open hat 4 ms apart, open then closed 6 ms apart, "
           "kick on kick 4 ms apart: a hit stopped right after its start - clicks or thumps?"),
    (26.0, "Fast repeats", "high tom every 40 ms, snare every 30 ms, closed hat every 20 ms: "
           "each restart cuts a fading voice - clicks, uneven rolls?"),
    (30.5, "Filter handover", "clap then closed hat 20 ms later, cowbell then open hat 10 ms "
           "later, cymbal then clap: the filter changes under a ringing tail - snaps?"),
    (37.0, "Crowd", "five sounds at once every 8th, then a cymbal the crowd steals from: "
           "which sounds drop out, any clicks when a voice is taken?"),
    (41.5, "Cowbell pair", "cowbell alone (two voices, ring-modulated), then with kick and open "
           "hat sounding (one voice): how big is the difference?"),
    (46.0, "Kick Tone and Tune", "kick at Tone 0, 4, 8, 12, 15, then Tune -12, -6, 0, +6, +12: "
           "even steps, no glitches?"),
    (53.0, "End", "knobs back at the defaults; the demo starts again after 2 s"),
]


def problem_pattern():
    """TEST_MIDI=7: PROBLEM_SECTIONS, played once (the feed then loops)."""
    N = {"K": 36, "Rim": 37, "S": 38, "C": 39, "CH": 42, "OH": 46, "LT": 41, "MT": 45,
         "HT": 48, "Cym": 49, "CB": 56, "Mrc": 70, "Clv": 75}
    ev = [(0, [0xFE])]
    lead = LEAD_BARS * 16 * STEP_T

    def hit(s, name, vel=127, dt=0):        # at s seconds (+ dt ticks)
        ev.append((lead + round(s * TICK_HZ) + dt, [NOTE_ON, N[name], vel]))

    def cc(s, num, value, vmax):            # Kick's knobs: CC 16-19 (Kick is selected)
        ev.append((lead + round(s * TICK_HZ), [0xB9, num, cc_for(value, vmax)]))

    # 1. long tails
    hit(0.0, "K"); hit(2.5, "OH"); hit(5.0, "Cym")
    cc(7.3, 18, 15, 15); hit(7.5, "K"); cc(10.6, 18, 8, 15)
    # 2. soft to hard
    for i in range(16):
        hit(11.0 + 0.25 * i, "S", 8 * (i + 1) - 1 if i else 8)
        hit(15.0 + 0.25 * i, "LT", 8 * (i + 1) - 1 if i else 8)
    # 3. flams and chokes
    for i in range(4):
        hit(19.5 + 0.5 * i, "CH"); hit(19.5 + 0.5 * i, "OH", 127, 2)
        hit(21.5 + 0.5 * i, "OH"); hit(21.5 + 0.5 * i, "CH", 127, 3)
        hit(23.5 + 0.5 * i, "K"); hit(23.5 + 0.5 * i, "K", 127, 2)
    # 4. fast repeats
    for i in range(24):
        hit(26.0 + 0.04 * i, "HT", 100)
    for i in range(32):
        hit(27.2 + 0.03 * i, "S", 90)
    for i in range(50):
        hit(28.4 + 0.02 * i, "CH", 100)
    # 5. filter handover
    for i in range(4):
        hit(30.5 + 0.5 * i, "C"); hit(30.5 + 0.5 * i, "CH", 100, 10)
        hit(32.5 + 0.5 * i, "CB"); hit(32.5 + 0.5 * i, "OH", 100, 5)
        hit(34.5 + 0.5 * i, "Cym"); hit(34.5 + 0.5 * i, "C", 127, 40)
    # 6. crowd
    for i in range(16):
        for name in ("K", "S", "C", "OH", "CB"):
            hit(37.0 + 0.125 * i, name, 100)
    hit(39.2, "Cym")
    for i in range(6):
        for name in ("S", "CB", "OH"):
            hit(39.45 + 0.25 * i, name, 100)
    # 7. cowbell pair
    for i in range(4):
        hit(41.5 + 0.5 * i, "CB")
        hit(43.5 + 0.5 * i, "K"); hit(43.5 + 0.5 * i, "OH", 127, 4); hit(43.5 + 0.5 * i, "CB", 127, 30)
    # 8. kick Tone, then Tune
    for i, t in enumerate((0, 4, 8, 12, 15)):
        cc(46.0 + 0.7 * i - 0.1, 19, t, 15); hit(46.0 + 0.7 * i, "K")
    cc(49.4, 19, 8, 15)
    for i, t in enumerate((0, 6, 12, 18, 24)):
        cc(49.5 + 0.7 * i - 0.1, 17, t, 24); hit(49.5 + 0.7 * i, "K")
    cc(53.0, 17, 12, 24)
    end = lead + round(55.0 * TICK_HZ)
    data = feed_bytes(ev, end)
    notes = "".join(f"; {lead / TICK_HZ + s:5.1f} s  {title}: {what}\n" for s, title, what in PROBLEM_SECTIONS)
    return (".if TEST_MIDI == 7\n" + notes + table("test_pattern", data, "TEST_MIDI=7 problem spots (see tables.py)")
            + ".endif\n")


def clock_rec_test_pattern():
    """TEST_MIDI=5 (with TEST_CLOCK=1 TEST_REC=1 TEST_SEQ_PAT=63, the empty
    pattern 64): MIDI clock and live record together. A note between start
    and the first clock (-> step 0, still to fire); a note in the same
    entry as the clock that makes step 4 due (-> step 4, not step 3); a
    note right after step 8's clock (-> step 8, fired already). Clocks
    every 10 ticks."""
    ev = [(0, [0xFE]), (100, [0xFA]), (105, [0x99, 41, 100])]           # low tom
    clocks = [110 + 10 * i for i in range(6 * 32)]
    ev += [(t, [0xF8]) for t in clocks]
    step4 = clocks[6 * 4]                       # the clock that starts step 4
    ev = [e if e[0] != step4 else (step4, [0xF8, 0x99, 45, 100]) for e in ev]   # mid tom
    ev += [(clocks[6 * 8] + 1, [0x99, 48, 100])]                       # high tom
    return (".if TEST_MIDI == 5\n" + table("test_pattern", feed_raw(ev, 6000),
            "TEST_MIDI=5 MIDI clock + live record test (see tables.py)") + ".endif\n")


# -----------------------------------------------------------------------------
# Sequencer (docs/sequencer.md, src/sequencer.asm)
# -----------------------------------------------------------------------------
BPM_MIN, BPM_MAX = 60, 240
SEQ_STEPS = 16
LEVEL_VEL = [0, 55, 100, 127]           # cell level (off, soft, normal, accent) -> velocity
REAL_TICK_HZ = PAL_CLOCK / (TICK_LATCH_500 + 1)   # 985248 / 1970 = 500.126 Hz
# default patterns: the demo track's bars (pattern 1 = MAIN ...)
SEQ_PATTERNS = ["MAIN", "MAIN_CLAP", "MAIN_CB", "TOM_FILL", "BREAK", "BREAK2", "SNARE_FILL",
                "FULL_CYM", "FULL", "ROLL", "INTRO", "INTRO2", "ENDING"]


def seq_tables():
    names = [x[0] for x in SOUNDS]
    out = []
    # tempo: 16th-note steps; per tick the step phase (16 bit) grows by inc
    inc, steplen = [], []
    for bpm in range(BPM_MIN, BPM_MAX + 1):
        steps_per_s = bpm * 4 / 60
        inc.append(round(65536 * steps_per_s / REAL_TICK_HZ))
        steplen.append(round(REAL_TICK_HZ / steps_per_s))
    assert max(inc) < 65536 and max(steplen) < 256
    out.append(f"BPM_MIN = {BPM_MIN}\nBPM_MAX = {BPM_MAX}\nSEQ_STEPS = {SEQ_STEPS}\n")
    out.append(table("bpm_inc_lo", [v & 255 for v in inc],
                     "step phase increment per tick (x/65536 of a 16th), low bytes; index BPM - BPM_MIN"))
    out.append(table("bpm_inc_hi", [v >> 8 for v in inc], "... high bytes"))
    out.append(table("bpm_steplen", steplen, "ticks per 16th (for the swing delay); index BPM - BPM_MIN"))
    # sounds fire in priority order within a step, so a weak sound never takes
    # a voice that a stronger one of the same step then steals
    order = sorted(range(len(SOUNDS)), key=lambda i: -SOUNDS[i][1])
    out.append(table("fire_order", order, "sounds of a step in firing order (highest priority first)"))
    out.append(table("fire_pos", [order.index(i) for i in range(len(SOUNDS))],
                     "each sound's position in fire_order (live record)"))
    out.append(table("level_vel", LEVEL_VEL, "velocity of a cell level: off, soft, normal, accent"))
    # default patterns
    level = {".": 0, "o": 1, "x": 2, "X": 3}
    data = []
    for name in SEQ_PATTERNS:
        bar = globals()[name]
        cells = [0] * (len(SOUNDS) * SEQ_STEPS)
        for inst, grid in bar.items():
            snd = names.index(GM[TRACK_NOTES[inst]])
            for i, c in enumerate(grid):
                if level[c]:
                    cells[snd * SEQ_STEPS + i] = level[c]
        data += cells
    out.append(f".if TEST_STRESS\nDEFAULT_PATTERNS = {len(SEQ_PATTERNS) + 1}\n"
               f".elsif TEST_SONG\nDEFAULT_PATTERNS = {len(SEQ_PATTERNS) + len(DEMO_PATTERNS)}\n"
               f".else\nDEFAULT_PATTERNS = {len(SEQ_PATTERNS)}\n.endif\n")
    out.append(table("default_patterns", data,
                     f"{len(SEQ_PATTERNS)} patterns: {', '.join(SEQ_PATTERNS)} "
                     f"({len(SOUNDS)} sounds x {SEQ_STEPS} steps each, cell = level 0..3)", per_line=16))

    def cells_of(bar):
        cells = [0] * (len(SOUNDS) * SEQ_STEPS)
        for inst, grid in bar.items():
            assert len(grid) == SEQ_STEPS, (inst, grid)
            snd = names.index(GM[TRACK_NOTES[inst]])
            for i, c in enumerate(grid):
                if level[c]:
                    cells[snd * SEQ_STEPS + i] = level[c]
        return cells

    # TEST_SONG: the demo's drum part, its patterns right after the defaults
    # (numbers 14..), and the song: those patterns, then two empty bars
    for name in DEMO_PATTERNS:                  # at most three hits on a step
        c = cells_of(globals()[name])
        assert all(sum(1 for snd in range(len(SOUNDS)) if c[snd * SEQ_STEPS + i])
                   <= 3 for i in range(SEQ_STEPS)), name
    song = [(len(SEQ_PATTERNS) + DEMO_PATTERNS.index(n), r) for n, r in DEMO_SONG] + [(63, 2)]
    out.append(".if TEST_SONG\n"
               + table("demo_patterns", sum((cells_of(globals()[n]) for n in DEMO_PATTERNS), []),
                       f"TEST_SONG: {', '.join(DEMO_PATTERNS)}", per_line=16)
               + f"DEMO_PATTERN_COUNT = {len(DEMO_PATTERNS)}\nTEST_SONG_LEN = {len(song)}\n"
               + table("test_song_pat", [e[0] for e in song], "TEST_SONG: the demo's song, patterns")
               + table("test_song_rep", [e[1] for e in song], "... and repeats") + ".endif\n")

    # TEST_STRESS: one more pattern (number SEQ_PATTERNS + 1) right after them:
    # the kick on the quarters to judge the tempo by, every other sound on every
    # step (levels varied, so the voices keep being taken)
    cells = [0] * (len(SOUNDS) * SEQ_STEPS)
    for snd in range(len(SOUNDS)):
        for i in range(SEQ_STEPS):
            if snd == 0:
                cells[i] = 3 if i % 4 == 0 else 0
            else:
                cells[snd * SEQ_STEPS + i] = 1 + (i + snd) % 3
    out.append(".if TEST_STRESS\n" + table("stress_pattern", cells,
               "TEST_STRESS: kick on the quarters, every other sound on every step", per_line=16)
               + ".endif\n")
    return "\n".join(out)



def main():
    parts = ["; tables.inc - GENERATED by tables.py, do not edit by hand\n"]
    parts.append(tick_latch(TICK_HZ))
    parts.append(f"STEP_SIZE = {STEP_SIZE}\nFOREVER = {FOREVER}\n")
    parts.append(sq_tables())
    parts.append(sounds_tables())     # fills decays and filters
    parts.append(decay_tables())
    parts.append(score_tables())
    parts.append(filter_tables())
    parts.append(mute_table())
    parts.append(fade_table())
    parts.append(knob_tables())
    parts.append(test_pattern())
    parts.append(track_pattern())
    parts.append(rec_test_pattern())
    parts.append(clock_test_pattern())
    parts.append(clock_rec_test_pattern())
    parts.append(cc_test_pattern())
    parts.append(problem_pattern())
    parts.append(seq_tables())
    with open("tables.inc", "w", newline="\n") as f:
        f.write("\n".join(parts))


if __name__ == "__main__":
    main()
