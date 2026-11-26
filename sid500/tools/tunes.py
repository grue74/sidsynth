# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""tunes.py - the demo tunes' library: a tune as SID500's song (patterns,
tracks, scenes, the family's synths on their channels), its song file
(.s5, as disk.asm saves one) and a model of what SID500 sends playing it
with Song on from scene 1.

    from tunes import Tune, note, cc, program, STEP, BAR

A tune is built in a tools/tune_<name>.py (TUNE = Tune(...)); its
patterns' events are tables.py encode()'s: (tick, "note", note, velocity,
length) and so on, ticks from the pattern's start (48 a quarter, STEP a
16th). The scenes play in order, each for bars x repeats, every track from
its pattern's start; the last scene is the end (one empty pattern, many
repeats): the song stops being modelled there (Song on would loop back).

The tools: demo_tunes.py (the disk, SID500's video, the synths' renders,
the mix, the video).
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import tables  # noqa: E402

STEP = tables.STEP                      # ticks a 16th
QUARTER = tables.TICKS_PER_QUARTER      # 48
BAR = 16 * STEP                         # a 4/4 bar
NO_PATTERN = 0xFF
POOL_BLOCKS_RELEASE = 680               # src/pool.asm: the release's pool ($6B00-$BFFF)
GRID_MAX = 256                          # src/grid.asm: events a pattern may have to open in the grid
SYNTH_CODE = {None: 0, "sid303": 1, "sid808": 2, "sid101": 3}   # src/names.asm SYNTH_*
SYNTH_CHANNEL = {"sid101": 0, "sid303": 1, "sid808": 9}         # each synth's own channel (feeds)
FILE_MAGIC = b"SID500" + bytes([1])     # disk.asm file_magic, FILE_VERSION
LOAD_ADDRESS = 0x6B00                   # (any: a load lays the blocks from POOL_START)


def note(step, pitch, vel=100, steps=1, at=0):
    """A note on 16th step (1-based) lasting steps 16ths (fractions allowed:
    whole ticks), at=ticks later than the step."""
    return ((step - 1) * STEP + at, "note", pitch, vel, max(1, round(steps * STEP)))


def cc(step, number, value, at=0):
    return ((step - 1) * STEP + at, "cc", number, value)


def program(step, number, at=0):
    return ((step - 1) * STEP + at, "program", number)


def bars(events, n_bars, at=0):
    """events moved n_bars 4/4 bars (and at ticks) later."""
    return [(e[0] + n_bars * BAR + at,) + tuple(e[1:]) for e in events]


class Tune:
    """name: the file's name (no .s5); title, style for the video;
    tempo (40-240), swing (0: the model has no swing);
    synths {channel 1-16: (synth, label, preset or None, [(cc, value)...])};
    patterns {number 1-128: (steps, events)};
    tracks {track 1-16: channel 1-16};
    scenes [(name, bars, {track: pattern number}, repeats)], 4/4, the last
    the end (silent)."""

    def __init__(self, name, title, style, tempo, synths, patterns, tracks, scenes, swing=0):
        self.name, self.title, self.style = name, title, style
        self.tempo, self.swing = tempo, swing
        self.synths, self.patterns, self.tracks, self.scenes = synths, patterns, tracks, scenes

    # ---- the limits
    def check(self):
        """SID500's limits, the release's pool; returns the blocks used."""
        assert 40 <= self.tempo <= 240 and self.swing == 0
        assert len(self.scenes) <= 64 and all(1 <= t <= 16 for t in self.tracks)
        blocks = 0
        for num, (steps, events) in self.patterns.items():
            assert 1 <= num <= 128 and 1 <= steps <= 128, num
            assert len(events) <= GRID_MAX, (num, len(events))
            ev = sorted(events, key=lambda e: e[0])
            assert all(0 <= e[0] < steps * STEP for e in ev), f"pattern {num}: an event past its end"
            blocks += tables.blocks_for(tables.encode(ev))
        for name, n_bars, cells, rep in self.scenes:
            assert 1 <= n_bars <= 255 and 1 <= rep <= 9 and cells, name
            for t, p in cells.items():
                assert t in self.tracks and p in self.patterns, (name, t, p)
        assert blocks <= POOL_BLOCKS_RELEASE, f"{blocks} blocks: over the release's pool"
        self.notes_apart()
        return blocks

    # ---- the song file
    def s5(self):
        """The song file's bytes (disk.asm: load address, header, the 14
        saved parameters, Song on, the start scene, the runs, the patterns)."""
        params = [self.tempo - 40, self.swing, 0, 0, 9, 37, 75, 0, 0, 0, 0, 0, 3, 2]
        out = bytearray([LOAD_ADDRESS & 0xFF, LOAD_ADDRESS >> 8]) + FILE_MAGIC
        out += bytes([len(params)] + params + [1, 0])          # Song on, from scene 1
        steps = [0] * 128
        for num, (s, _) in self.patterns.items():
            steps[num - 1] = s
        repeats = [1] * 64
        chsynth = [0] * 16
        for ch, (synth, *_rest) in self.synths.items():
            chsynth[ch - 1] = SYNTH_CODE[synth]
        for k, sc in enumerate(self.scenes):
            repeats[k] = sc[3]
        out += bytes(steps + repeats + chsynth)                 # $C900: 128 + 64 + 16
        channel = list(range(16))
        for t, ch in self.tracks.items():
            channel[t - 1] = ch - 1
        out += bytes(channel + list(range(16)) + [0] * 32)      # order, mute, solo
        bars_ = [4] * 64
        sig = [3] * 64
        cells = [NO_PATTERN] * (64 * 16)
        for k, (_, n_bars, row, _) in enumerate(self.scenes):
            bars_[k] = n_bars
            for t, p in row.items():
                cells[k * 16 + t - 1] = p - 1
        out += bytes(bars_ + sig + cells)
        for num in sorted(self.patterns):
            stream = tables.encode(sorted(self.patterns[num][1], key=lambda e: e[0]))
            n = tables.blocks_for(stream)
            out += bytes([num - 1, n & 0xFF, n >> 8]) + bytes(stream + [0] * (n * 30 - len(stream)))
        out.append(0xFF)
        return bytes(out)

    # ---- what SID500 sends
    def scene_ticks(self):
        """[(scene index, its first tick, its ticks)] up to the end scene."""
        out, t = [], 0
        for k, (_, n_bars, _, rep) in enumerate(self.scenes[:-1]):
            out.append((k, t, n_bars * BAR * rep))
            t += n_bars * BAR * rep
        return out

    def length_ticks(self):
        k, t, n = self.scene_ticks()[-1]
        return t + n

    def messages(self):
        """[(tick, channel 0-15, bytes)]: every message SID500 sends from
        the song's start (tick 0) but clock, start and stop; a note off as
        $8n note 0 at its on + length."""
        out = []
        for k, start, n in self.scene_ticks():
            for t, p in self.scenes[k][2].items():
                ch = self.tracks[t] - 1
                steps, events = self.patterns[p]
                period = steps * STEP
                for loop in range(-(-n // period)):
                    for e in events:
                        at = start + loop * period + e[0]
                        if at >= start + n:
                            continue
                        kind = e[1]
                        if kind == "note":
                            out.append((at, ch, [0x90 | ch, e[2], e[3]]))
                            out.append((at + e[4], ch, [0x80 | ch, e[2], 0]))
                        elif kind == "cc":
                            out.append((at, ch, [0xB0 | ch, e[2], e[3]]))
                        elif kind == "program":
                            out.append((at, ch, [0xC0 | ch, e[2]]))
                        elif kind == "bend":
                            out.append((at, ch, [0xE0 | ch, e[2], e[3]]))
        # (offs before ons at the same tick: a note ended and struck again)
        out.sort(key=lambda m: (m[0], 0 if m[2][0] & 0xF0 == 0x80 else 1))
        return out

    def notes_apart(self):
        """No note struck again on its channel while it sounds (SID500
        would end the first early: the model doesn't)."""
        sounding = {}
        for t, ch, m in self.messages():
            key = (ch, m[1]) if m[0] & 0xE0 == 0x80 else None
            if key is None or self.synths[ch + 1][0] == "sid808":
                continue
            if m[0] & 0xF0 == 0x90:
                assert key not in sounding, f"channel {ch + 1} note {m[1]} at tick {t}: still sounding"
                sounding[key] = t
            else:
                sounding.pop(key, None)

    def write_midi(self, path, channels=None):
        """The model as a type 0 MIDI file (480 a quarter), all channels or
        those given (0-15)."""
        import mido
        tpb = 480
        mid = mido.MidiFile(type=0, ticks_per_beat=tpb)
        tr = mido.MidiTrack()
        mid.tracks.append(tr)
        tr.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(self.tempo), time=0))
        now = 0
        for t, ch, m in self.messages():
            if channels is not None and ch not in channels:
                continue
            tick = t * tpb // QUARTER
            tr.append(mido.Message.from_bytes(m).copy(time=tick - now))
            now = tick
        mid.save(path)

    def seconds(self, ticks):
        return ticks * 60 / self.tempo / QUARTER
