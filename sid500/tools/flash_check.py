"""flash_check.py - SID500 stage B: no flashing on the song screen, and
the screen as a model of the song data says.

The editor's rule 1 (docs/plan.md): no flashing, ever. Builds TEST_FRAMES
programs (src/test_frames.asm: a raster interrupt below the text every
frame, at frame_mark) with a key script on the song screen while the
sequencer plays, runs them in VICE (Datel MIDI) and stops at frame_mark
every frame through the binary monitor (c64tools' vicerec.py), taking the
picture as the beam drew it. Each frame is decoded into the screen's
characters and colours (the ROM's mixed set, black background). The VIC
fetches a text row's characters once a frame, so a row shows the screen
memory as it was at that moment: a half-drawn row, a row cleared before it
is drawn, a cell's character and colour apart, all show as a row state
of their own. Fails on:

- a row state that lasts at most FLASH_FRAMES frames and then goes back
  to the one before it (A, B, A): a flash (but the cursor passing through
  a row on quick keys);
- a scene row blank, or a character not in the set;
- a frame with no cursor or with two (the cursor's old and new rows drawn
  in different frames).

From the first frame the song screen is whole: the switch to it (F7) is
drawn a row at a time over the parameter screen (no row cleared first),
reported.

Reported, not failed: frames where the scene rows' numbers don't run on
(a scroll or a half's flip drawn over several frames, a row at a time).

The model: at every frame's stop the song data is read too (the scenes,
the tracks' channels, mutes and solos, the cursor, the first scene shown,
the play state and the tempo) and each row rendered as src/song.asm
should show it: the title, the header (track numbers in their colours, M
or S), the scene rows (numbers, the playing scene's mark, each cell's
number in its track's colour, the cursor reversed). Each row must show
its model within SETTLE_LIGHT frames of the model's last change
(SETTLE_BUSY at half the wire) (a key's own
row much sooner: screen_check.py measures that); the time it took is
reported.

    python tools/flash_check.py [--frames N]
"""
import argparse
import os
import subprocess
import sys
import tempfile
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C64TOOLS = os.path.join(os.path.dirname(ROOT), "c64tools")
sys.path.insert(0, C64TOOLS)
import vicerec  # noqa: E402  (BinMon: the binary monitor)
import vicetime  # noqa: E402  (find_vice)
sys.path.insert(0, ROOT)
import tables  # noqa: E402  (the test scenes: the step grid's patterns)
import vice_env  # noqa: E402,F401  (the patched VICE: 10 bits a MIDI byte)

MIDI_ARGS = ["-midi", "-miditype", "2", "-midiout", "-1", "-midiin", "-1"]   # Datel
SETTLE_LIGHT = 15               # frames a row may take to show its model (the user,
SETTLE_BUSY = 40                # 2026-11-21: optimised now): the band ~10 at most (a
                                # scroll), half the wire ~30 (a scroll; mute, solo and a
                                # half's flip much sooner)
WHOLE_ROWS = 8                  # step grid rows whose model changes in one frame: the
                                # whole grid drawn again (CLR, its undo, a transpose): held
                                # as a switch, reported
SETTLE_SWITCH = 60              # after the step grid opened or left (a whole screen drawn
                                # again, as F7's): reported, held to this
FLASH_FRAMES = 2                # a state this short between two equal ones: a flash
TITLE_ROW, HEAD_ROW, GRID_ROW, GRID_ROWS = 0, 2, 3, 22      # src/song.asm
CHARGEN = os.path.join(os.path.dirname(vicetime.find_vice()), "..", "C64",
                       "chargen-901225-01.bin")

RUNS = [  # (name, TEST_PLAY scene, TEST_KEYS script, frames; settle: SETTLE_BUSY at half
          #  the wire, scene 4)
    ("half the wire, the cursor, stops and continues", 4, 3, 520),
    ("the band, scroll, + - DEL, mute, solo", 1, 4, 420),
    ("the band, whole-screen changes one at a time", 1, 6, 520),
    ("the band, the step grid opened on three patterns", 1, 8, 560),
    ("half the wire, whole-screen changes one at a time", 4, 6, 520),
    ("the band, editing on the step grid", 1, 9, 760),
    ("the band, copy and clear on the step grid", 1, 12, 840),
    ("the band, a count-in and a take from the song screen", 1, 14, 480),
    ("the band, scenes: row 1's keys, launches, Song", 1, 15, 760),
    ("the band, the event list: F3, pages, fields", 1, 16, 860),
    ("the band, editing in the event list", 1, 17, 560),
    ("the band, the family's names", 1, 18, 560),
]


GRID_VARS = 32                  # src/grid.asm's variables read from song_mode on
GRID_AT = {}                    # each one's place among them
LIST_AT = {}                    # src/list.asm's variables' places (from grid_view on)
SCENE_OF_RUN = [1]              # the test scene the run plays (its patterns: the grid's)
KEYS_OF_RUN = [0]               # and its key script
GRID_TABLE, TABLE_READ = 0xE000, 1024   # src/grid.asm's edit table: the first 128 records
TABLE_ERRORS = []               # the edit table unlike the test scene's pattern (decoding)


def build(out, scene, keys):
    subprocess.run(["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg", "-D", "TEST_FRAMES=1",
                    "-D", f"TEST_KEYS={keys}", "-D", f"TEST_PLAY={scene}",
                    "-l", out + ".lbl", "-o", out, "sid500.asm"], cwd=ROOT, check=True)
    labels = {}
    for line in open(out + ".lbl"):
        if "=" in line:
            name, value = line.split("=", 1)
            value = value.strip()
            if value.startswith("$"):
                labels[name.strip()] = int(value[1:], 16)
            elif value.isdigit():       # (a label from a computed address: decimal)
                labels[name.strip()] = int(value)
    READS[:] = [("scenes", labels["SCENES"], 64 * 16),
                ("tracks", labels["TRACK_CHANNEL"], 0x50),
                ("colours", labels["channel_colour"], 16),
                ("song", labels["song_cursor"], 3),
                ("state", labels["play_state"], 1),
                ("transport_req", labels["transport_req"], 1),
                ("slave_req", labels["slave_req"], 1),
                ("tempo", labels["params"] + labels.get("P_TEMPO", 0), 1),
                ("grid", labels["song_mode"], GRID_VARS),
                ("table", GRID_TABLE, TABLE_READ),
                ("edit", labels["edit_wait"], 1),
                ("octave", labels["kb_octave"], 1),
                ("entry", labels["edit_vel"], 3),       # edit_vel, edit_len (2)
                ("target", labels["edit_target"], 1),
                ("confirm", labels["grid_confirm"], 1),
                ("rec", labels["rec_state"], 1),
                ("count", labels["count_state"], 1),
                ("clock", labels["ck_text"], 11),      # the time display (clock.asm)
                ("bars", labels["SCENE_BARS"], NUM_SCENES),       # stage E (scene.asm)
                ("sigs", labels["SCENE_SIG"], NUM_SCENES),
                ("reps", labels["SCENE_REPEATS"], NUM_SCENES),
                ("sv", labels["play_scene"], labels["scene_vars_end"] - labels["play_scene"]),
                ("list", labels["grid_view"], labels["list_vars_end"] - labels["grid_view"]),
                ("synths", labels["CHANNEL_SYNTH"], 16)]
    LIST_AT.clear()
    LIST_AT.update({k: labels[k] - labels["grid_view"] for k in
                    ("grid_view", "list_top", "list_cursor", "list_field")})
    SV_AT.clear()
    SV_AT.update({k: labels[k] - labels["play_scene"] for k in
                  ("play_scene", "launch_pending", "launch_kind", "launch_what", "song_on",
                   "ovr_scene")})
    GRID_AT.clear()
    GRID_AT.update({k: labels[k] - labels["song_mode"] for k in
                    ("song_mode", "grid_pattern", "grid_track", "grid_steps", "grid_top",
                     "grid_cursor", "grid_col", "grid_colour", "grid_count")})
    SCENE_OF_RUN[0] = scene
    KEYS_OF_RUN[0] = keys
    PLAY_STATES.update(stopped=labels.get("PLAY_STOPPED", 0),
                       starting=labels.get("PLAY_STARTING", 1),     # (src/timing.asm)
                       running=labels.get("PLAY_RUNNING", 2), held=labels.get("PLAY_HELD", 3))
    assert labels["song_row"] == labels["song_cursor"] + 1 \
        and labels["song_top"] == labels["song_cursor"] + 2, "song.asm's variables' order"
    return labels["frame_mark"]


def glyphs():
    """The mixed set's 256 characters (reversed among them): 8 bytes -> code."""
    rom = open(CHARGEN, "rb").read()[0x800:0x1000]
    table = {}
    for code in range(256):
        g = rom[code * 8:code * 8 + 8]
        table.setdefault(g, code)
    return table


READS = []                      # (name, address, length): set by build()
SV_AT = {}                      # scene.asm's variables: each one's place in the "sv" read
COL_INFO = 12                   # src/scene.asm: row 1's colour


def memory(mon, start, length):
    """length bytes from start (the CPU's view)."""
    import struct
    data = mon.call(0x01, struct.pack('<BHHBH', 0, start, start + length - 1, 0, 0))
    return data[2:2 + length]


def grab(prg, mark, frames):
    """Run prg, stop at mark each frame: the frames' 25 x 40 (code, colour)
    cells (code None: a glyph not in the set; colour None: nothing drawn),
    and the song data then ({name: bytes})."""
    vice = vicetime.find_vice()
    tmp = tempfile.mkdtemp()
    src = os.path.join(tmp, "prog.prg")
    shutil.copy(prg, src)
    args = [vice, "-default", "-console", "-sounddev", "dummy", "-warp", *MIDI_ARGS,
            "-binarymonitor", "-binarymonitoraddress", f"ip4://127.0.0.1:{vicerec.PORT}",
            "-autostartprgmode", "1", "-autostart", "prog.prg"]
    proc = subprocess.Popen(args, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    table = glyphs()
    out = []
    try:
        mon = vicerec.BinMon(30)
        mon.checkpoint(mark)
        mon.resume()
        mon.wait_stop()
        w, h, ox, oy, iw, ih, pix = mon.display()
        if (w, h, ox, oy, iw, ih) == (384, 272, 0, 0, 384, 272):
            ox, oy = 32, 35                     # (a headless build: see vicerec.py)
        else:
            ox, oy = ox + vicerec.DX, oy + vicerec.DY
        for n in range(frames):
            if n:
                mon.resume()
                mon.wait_stop()
                pix = mon.display()[6]
            rows = []
            for r in range(25):
                row = []
                for c in range(40):
                    bits, colour = bytearray(8), None
                    for y in range(8):
                        base = (oy + r * 8 + y) * w + ox + c * 8
                        line = pix[base:base + 8]
                        b = 0
                        for x, p in enumerate(line):
                            if p:
                                b |= 0x80 >> x
                                if colour is None:
                                    colour = p
                                elif p != colour:
                                    colour = -1         # two colours in a cell: can't be
                        bits[y] = b
                    row.append((table.get(bytes(bits)), colour))
                rows.append(tuple(row))
            out.append((rows, {name: memory(mon, a, n) for name, a, n in READS}))
        mon.send(0xbb)                          # quit
    finally:
        try:
            proc.wait(3)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)
    return out


def text(row):
    """A row as text (screen codes of the mixed set; reversed as is)."""
    s = ""
    for code, _ in row:
        if code is None:
            s += "?"
            continue
        c = code & 0x7F
        s += ("@" if c == 0 else chr(c + 96) if c < 27 else chr(c) if c < 64
              else chr(c) if c < 91 else "#")
    return s


def plain(row):
    """A row without the cursor (reverse video off): the cursor passing
    through a row for a frame or two on fast keys is no flash (the cursor
    count is checked on its own)."""
    out = []
    for code, colour in row:
        if code is not None:
            code &= 0x7F
            if code == 0x20:
                colour = None                   # (a space shows no colour; reversed, it did)
        out.append((code, colour))
    return tuple(out)


def cursor_places(rows):
    """Where the runs of reversed characters start in the scene rows:
    [(row, column)]."""
    out = []
    for r in range(GRID_ROW, GRID_ROW + GRID_ROWS):
        prev = False
        for c, (code, colour) in enumerate(rows[r]):
            rev = code is not None and code >= 0x80 and colour is not None
            if rev and not prev:
                out.append((r, c))
            prev = rev
    return out


def cursors(rows):
    """How many runs of reversed characters the scene rows have."""
    return len(cursor_places(rows))


PLAY_STATES = {}
BPM_LOWEST = 40                 # sid500.asm
COL_TITLE, COL_LABEL, COL_MUTED, COL_UNSOLOED = 1, 12, 11, 12      # src/song.asm
NUM_SCENES, NO_PATTERN = 64, 0xFF


SYNTH_808 = 2                   # src/names.asm SYNTH_*
CC_NAMES = {sid: {cc: n for cc, n in tables.synth_controllers(name)}
            for name, sid in tables.FAMILY}
GM_NAMES = tables.drum_map()[0]


def scr(s):
    """Text as the mixed set's screen codes (lowercase $01-$1A)."""
    return [c - 96 if 97 <= c <= 122 else c for c in s.encode()]


def grid_synth(d):
    """The open pattern's track's channel's family synth (src/names.asm)."""
    return d["synths"][d["tracks"][grid_var(d, "grid_track")]]


def name_of(d, note):
    """src/names.asm name_note: a drum's name on an SID808 channel, else
    the pitch."""
    if grid_synth(d) == SYNTH_808 and note in GM_NAMES:
        return scr(GM_NAMES[note])
    return list(note_name(note).encode())


def grid_var(d, name):
    return d["grid"][GRID_AT[name]]


def note_name(n):
    """src/grid.asm's pitch: letter, sign, octave (MIDI note 12 = C0)."""
    octave = n // 12
    return ("CCDDEFFGGAAB"[n % 12] + "-#-#--#-#-#-"[n % 12]
            + (chr(0x30 + octave - 1) if octave else "-"))


def length_text(ticks):
    """src/grid.asm grid_len_text: steps, "+" if not whole, "<1" under one."""
    n, rem = min(ticks // 12, 255), ticks % 12
    if n == 0:
        return "<1"
    if n >= 100:
        return f"{n:03}"
    return f"{n}" + ("+" if rem else "")


def table_events(d):
    """The edit table's events as read (src/grid.asm's records), or None
    when it has more than were read."""
    count = grid_var(d, "grid_count") | d["grid"][GRID_AT["grid_count"] + 1] << 8
    if count * 8 > TABLE_READ:
        return None
    t, out = d["table"], []
    for i in range(count):
        r = t[i * 8:i * 8 + 8]
        tick, kind = r[0] | r[1] << 8, r[2]
        if kind == 0:
            out.append((tick, "note", r[3], r[5], r[6] | r[7] << 8))
        elif kind == 3:
            out.append((tick, "program", r[3]))
        else:
            out.append((tick, ("cc", "bend")[kind - 1] if kind in (1, 2) else "bad", r[3], r[4]))
    return out


def grid_model(d):
    """The 25 rows src/grid.asm should show (the step grid) for the data d:
    the edit table's events (read from memory: edits change it; when only
    opened, it must be the test scene's pattern, TABLE_ERRORS)."""
    patterns = tables.SCENES[SCENE_OF_RUN[0]]()[0]
    pat, track = grid_var(d, "grid_pattern"), grid_var(d, "grid_track")
    steps, top = grid_var(d, "grid_steps"), grid_var(d, "grid_top")
    cursor, col, colour = grid_var(d, "grid_cursor"), grid_var(d, "grid_col"), \
        grid_var(d, "grid_colour")
    events = table_events(d)
    scene_events = [tuple(e) for e in patterns[pat][1]] if pat in patterns else []
    if events is None:
        events = scene_events
    elif KEYS_OF_RUN[0] == 8 and events != scene_events and len(TABLE_ERRORS) < 3:
        TABLE_ERRORS.append(f"pattern {pat}'s edit table {events[:4]}... differs from "
                            f"the test scene's {scene_events[:4]}...")
    st = d["state"][0]
    playing = st in (PLAY_STATES["starting"], PLAY_STATES["running"]) or \
        (st == PLAY_STATES["held"] and (d["transport_req"][0] or d["slave_req"][0]))

    def cells(chars, cols):
        return tuple((c, cols[i] if c == 0xA0 else (None if c == 0x20 else cols[i]))
                     for i, c in enumerate(chars))

    def line(text_, col_):
        return cells(list(text_.encode()), [col_] * 40)
    out = []
    last = min(top + 16, steps)
    out.append(line(f"PAT {pat + 1:03}  TRK {track + 1:02}  LEN {steps:03}  "
                    f"{top + 1:03}-{last:03} " + ("* " if d["edit"][0] else "  ")
                    + ("PLAY" if playing else "STOP"), COL_TITLE))
    out.append(line(" " * 40, COL_LABEL))
    out.append(line("ST  " + "KEY VEL LEN " * 3, COL_LABEL))
    for r in range(16):
        s_ = top + r
        if s_ >= steps:
            out.append(line(" " * 40, COL_LABEL))
            continue
        chars, cols = [0x20] * 40, [colour] * 40
        chars[0:3] = f"{s_ + 1:03}".encode()
        cols[0:3] = [COL_LABEL] * 3
        notes = [e for e in events if e[1] == "note" and s_ * 12 <= e[0] < s_ * 12 + 12]
        for k, (tick, _, note, vel, length) in enumerate(notes[:3]):
            p = 4 + 12 * k
            chars[p:p + 3] = name_of(d, note)
            if tick != s_ * 12:
                chars[p + 3] = ord("'")
            chars[p + 4:p + 7] = f"{vel:>3}".encode()
            t = length_text(length).encode()
            chars[p + 8:p + 8 + len(t)] = t
        if len(notes) > 3:
            chars[39] = ord("+")
        if not notes:
            chars[4:7] = b"---"
            cols[4:7] = [COL_LABEL] * 3
        if s_ == cursor:
            p = 4 + 12 * col
            chars[p:p + 3] = [c | 0x80 for c in chars[p:p + 3]]
        out.append(cells(chars, cols))
    vel, length = d["entry"][0], d["entry"][1] | d["entry"][2] << 8
    target = ["VEL", "LEN", "TRN"][d["target"][0]]     # (src/edit.asm EDIT_TO_*)
    rows = {21: "RETURN SONG  F3 LIST  RUN/STOP PLAY     ",
            22: "Z-/ Q-P NOTE SPACE REST DEL CLEAR F5 OCT",
            23: f"ENTRY  OCT {d['octave'][0]}  VEL {vel:>3}  LEN {length_text(length):<4}"
                f"C=+- {target} "}
    for r in range(19, 25):
        if r == 23 and d["confirm"][0]:             # a CLR waiting for its second
            out.append(line("CLR AGAIN: CLEAR ALL, NO UNDO  ELSE KEEP", COL_TITLE))
            continue
        out.append(line(rows.get(r, " " * 40), COL_LABEL))
    return out


def view(d):
    """0 the song screen, 1 the step grid, 3 the event list."""
    return grid_var(d, "song_mode") + 2 * (d["list"][LIST_AT["grid_view"]] != 0)


def list_word(d, name):
    return d["list"][LIST_AT[name]] | d["list"][LIST_AT[name] + 1] << 8


def list_pos(t, beats, beat_ticks, base):
    """src/list.asm list_pos: bar.beat.tick right-aligned in 8, from bar 1
    and beat 1 (a position) or 0 (a length); bars over 99 shown as 99."""
    beats_total, ticks = divmod(t, beat_ticks)
    bars, beat = divmod(beats_total, beats)
    return f"{min(bars + base, 99)}.{beat + base}.{ticks:02}".rjust(8)


def list_model(d):
    """The 25 rows src/list.asm should show (the event list) for the data d:
    the edit table's events up to the pattern's length, then END."""
    rows = grid_model(d)                        # (the title, the help: as the grid's)
    steps, colour = grid_var(d, "grid_steps"), grid_var(d, "grid_colour")
    top, cursor = list_word(d, "list_top"), list_word(d, "list_cursor")
    field = d["list"][LIST_AT["list_field"]]
    events = table_events(d)
    if events is None:                          # (more than were read: the test scene's)
        pat = grid_var(d, "grid_pattern")
        events = [tuple(e) for e in tables.SCENES[SCENE_OF_RUN[0]]()[0][pat][1]]
    events = [e for e in events if e[0] < steps * 12]
    sig = d["sigs"][d["sv"][SV_AT["play_scene"]]]
    beats, beat_ticks = (sig & 15) + 1, 24 if sig & 0x80 else 48

    def cells(chars, cols):
        return tuple((c, cols[i] if c == 0xA0 else (None if c == 0x20 else cols[i]))
                     for i, c in enumerate(chars))

    def line(text_, col_):
        return cells(list(text_.encode()), [col_] * 40)
    title = list(rows[0])
    title[26:33] = cells(list(b"LIST   "), [COL_TITLE] * 7)
    out = [tuple(title), line(" " * 40, COL_LABEL),
           line("POSITION EVENT    VALUE VEL   LENGTH    ", COL_LABEL)]
    for r in range(16):
        i = top + r
        if i > len(events):
            out.append(line(" " * 40, COL_LABEL))
            continue
        chars, cols = [0x20] * 40, [colour] * 40
        cols[0:9] = [COL_LABEL] * 9
        place = 5
        if i == len(events):                    # the END row
            chars[0:8] = list_pos(steps * 12, beats, beat_ticks, 1).encode()
            chars[9:12] = b"END"
            cols[9:12] = [COL_LABEL] * 3
        else:
            e = events[i]
            chars[0:8] = list_pos(e[0], beats, beat_ticks, 1).encode()
            if e[1] == "note":
                chars[9:12] = name_of(d, e[2])
                chars[24:27] = f"{e[3]:>3}".encode()
                chars[28:36] = list_pos(e[4], beats, beat_ticks, 0).encode()
                place = [5, 9, 24, 33][field]
            else:
                if e[1] == "cc":
                    named = CC_NAMES.get(grid_synth(d), {}).get(e[2])
                    chars[9:17] = scr(f"{named:<8}") if named else scr(f"CC {e[2]:>3}  ")
                    chars[20:23] = f"{e[3]:>3}".encode()
                elif e[1] == "bend":
                    chars[9:13] = b"BEND"
                    chars[18:23] = f"{e[2] + e[3] * 128 - 8192:>5}".encode()
                else:
                    chars[9:13] = b"PROG"
                    chars[20:23] = f"{e[2] + 1:>3}".encode()
                place = [5, 20][field] if field < 2 else None
        if i == cursor and place is not None:
            chars[place:place + 3] = [c | 0x80 for c in chars[place:place + 3]]
        out.append(cells(chars, cols))
    out += [line(" " * 40, COL_LABEL)] * 2
    help_ = list(rows[21])
    help_[16:20] = cells(list(b"GRID"), [COL_LABEL] * 4)
    out += [tuple(help_), line("CRSR MOVE  +- CHANGE  INST COPY  DEL CUT", COL_LABEL),
            line(" " * 40, COL_LABEL), line(" " * 40, COL_LABEL)]
    return out


def model(d):
    """The 25 rows src/song.asm should show for the song data d, as the
    decoded frames' cells (a space has no colour)."""
    if view(d) == 3:
        return list_model(d)
    if grid_var(d, "song_mode"):
        return grid_model(d)
    scenes, tracks, colours = d["scenes"], d["tracks"], d["colours"]
    cursor, row, top = d["song"]
    channel, order, mute, solo = (tracks[i * 16:i * 16 + 16] for i in range(4))
    st = d["state"][0]
    playing = st in (PLAY_STATES["starting"], PLAY_STATES["running"]) or \
        (st == PLAY_STATES["held"] and (d["transport_req"][0] or d["slave_req"][0]))
    any_solo = any(solo)
    half = cursor & 8
    # a count-in before the song plays: REC, and the scene to play marked
    # (src/count.asm)
    counting = d["count"][0] and st in (PLAY_STATES["stopped"], PLAY_STATES["held"])

    def colour_of(t):
        if mute[t]:
            return COL_MUTED
        if any_solo and not solo[t]:
            return COL_UNSOLOED
        return colours[channel[t]]

    def cells(chars, cols):
        return tuple((c, None if c == 0x20 else col) for c, col in zip(chars, cols))

    def blank():
        return [0x20] * 40, [COL_LABEL] * 40

    def num3(n):                                # 0: " --", else right-aligned
        if n == 0:
            return b" --"
        return f"{n:>3}".encode()

    out = []
    title, tcol = list(b"SONG  SCENE 01  BPM 120 001.1  0:00 STOP"), [COL_TITLE] * 40
    bpm = d["tempo"][0] + BPM_LOWEST
    title[20:23] = f"{bpm:>3}".encode()
    title[24:35] = d["clock"]                   # bar.beat and m:ss as the clock has them
    title[36:40] = b"REC " if counting or (playing and d["rec"][0]) else         b"PLAY" if playing else b"STOP"
    sv = d["sv"]
    play_scene = sv[SV_AT["play_scene"]]
    title[12:14] = f"{play_scene + 1:02}".encode()
    out.append(cells(title, tcol))
    # row 1: the cursor's scene (src/scene.asm scene_row1)
    r1 = list(b"SONG  SC 01   1 BARS   4/4  X1".ljust(40))
    r1col = [COL_INFO] * 40
    bars, sig, rep = d["bars"][row], d["sigs"][row], d["reps"][row]
    r1[9:11] = f"{row + 1:02}".encode()
    r1[13:15] = f"{bars:>2}".encode()
    if bars == 1:
        r1[19] = 0x20
    beats = (sig & 0x0F) + 1
    r1[22:24] = f"{beats:>2}".encode()
    r1[25] = ord("8") if sig & 0x80 else ord("4")
    r1[29] = ord(str(rep)) if rep < 10 else ord("?")
    if sv[SV_AT["song_on"]]:
        r1[0:4] = [c | 0x80 for c in r1[0:4]]
        r1col[0:4] = [COL_TITLE] * 4
    out.append(cells(r1, r1col))
    head, hcol = blank()
    for k in range(8):
        t, col = half + k, 5 + 4 * k
        head[col:col + 3] = num3(t + 1)
        head[col + 3] = ord("M") if mute[t] else ord("S") if solo[t] else 0x20
        hcol[col:col + 4] = [colour_of(t)] * 4
        synth = d["synths"][channel[t]]
        if synth:                               # (src/names.asm names_prepare)
            head[col], hcol[col] = ord("381"[synth - 1]), COL_TITLE
    out.append(cells(head, hcol))
    for r in range(22):
        scene = top + r
        chars, cols = blank()
        if scene < NUM_SCENES:
            chars[0:2] = f"{scene + 1:02}".encode()
            pending = sv[SV_AT["launch_pending"]]
            kind, what = sv[SV_AT["launch_kind"]], sv[SV_AT["launch_what"]]
            if scene == play_scene and (playing or counting):
                chars[2], cols[2] = ord(">"), COL_TITLE
            if pending and kind == 0xFF and what == scene:
                chars[2], cols[2] = ord("+"), COL_TITLE
            for k in range(8):
                t, col = half + k, 5 + 4 * k
                p = scenes[scene * 16 + t]
                chars[col:col + 3] = num3(0 if p == NO_PATTERN else p + 1)
                cols[col:col + 4] = [colour_of(t)] * 4
                if scene == row and t == cursor:
                    chars[col:col + 3] = [c | 0x80 for c in chars[col:col + 3]]
            for k in range(8):                  # a cell launched: '>' (or '+' waiting)
                t, col = half + k, 5 + 4 * k
                if sv[SV_AT["ovr_scene"] + t] == scene:
                    chars[col - 1] = ord(">")
                if pending and kind == t and what == scene:
                    chars[col - 1] = ord("+")
        row_cells = cells(chars, cols)
        # a reversed space shows its colour
        row_cells = tuple((c, cols[i] if c == 0xA0 else col)
                          for i, (c, col) in enumerate(row_cells))
        out.append(row_cells)
    return out


def model_errors(frames, errors, settle):
    """Each row its model within SETTLE frames of the model's last change.
    Returns the longest it took (frames), the title, header and scene rows'."""
    worst = {"title": 0, "header": 0, "scenes": 0}
    since = [0] * 25
    last = [None] * 25
    behind = [0] * 25
    mode, switched, switches = None, -SETTLE_SWITCH, []
    redraws = []                # (a whole grid drawn again: its frame, frames to show whole)
    for i, (rows, data) in enumerate(frames):
        m = model(data)
        if i and sum(m[r] != last[r] for r in range(25)) >= WHOLE_ROWS                 and view(data) == mode and mode:  # (the step grid's, the list's)
            switched = i
            redraws.append([i, None])
        if redraws and redraws[-1][1] is None and all(rows[r] == m[r] for r in range(25)):
            redraws[-1][1] = i - redraws[-1][0]
        if view(data) != mode:
            if mode is not None:
                switched = i
                switches.append([i, None])
            mode = view(data)
        if switches and switches[-1][1] is None and all(rows[r] == m[r] for r in range(25)):
            switches[-1][1] = i - switches[-1][0]
        limit = SETTLE_SWITCH if i - switched < SETTLE_SWITCH else settle
        for r in range(25):
            if m[r] != last[r]:
                last[r], since[r] = m[r], i
            if rows[r] == m[r]:
                kind = "title" if r == 0 else "header" if r == HEAD_ROW else "scenes"
                worst[kind] = max(worst[kind], behind[r])
                behind[r] = 0
            else:
                behind[r] = i - since[r] + 1
                if behind[r] == limit + 1:
                    errors.append(f"frame {i}, row {r}: {text(rows[r])!r}, not its model "
                                  f"{text(m[r])!r} (unchanged {limit} frames)"
                                  + ("; colours differ" if text(rows[r]) == text(m[r]) else ""))
    if switches:
        done = [t for _, t in switches if t is not None]
        if len(done) < len(switches) - 1:      # (the last may end with the log)
            errors.append(f"a switch of screens never showed whole: {switches}")
        if done:
            worst["grid switch"] = max(done)
    if redraws:
        done = [t for _, t in redraws if t is not None]
        if len(done) < len(redraws) - 1:
            errors.append(f"a whole grid drawn again never showed whole: {redraws}")
        if done:
            worst["whole grid"] = max(done)
    return worst


def check(name, frames, settle):
    errors, notes = [], []
    pairs = frames
    frames = [f for f, _ in pairs]
    begun = next((i for i, f in enumerate(frames) if text(f[TITLE_ROW]).startswith("SONG")), None)

    def whole(f):
        nums = [text(f[r])[:2] for r in range(GRID_ROW, GRID_ROW + GRID_ROWS)]
        return all(x.isdigit() for x in nums) and text(f[HEAD_ROW]).strip()
    first = next((i for i, f in enumerate(frames) if begun is not None and i >= begun
                  and whole(f)), None)
    if first is None:
        print(f"{name}: the song screen never appeared whole")
        return False
    notes.append(f"the screen's switch (F7) drawn in {first - begun + 1} frames, a row at a "
                 f"time over the old one")
    frames = frames[first:]
    worst = model_errors(pairs[first:], errors, settle)
    if KEYS_OF_RUN[0] == 4 and pairs[-1][1]["scenes"][1 * 16 + 1] == NO_PATTERN:
        errors.append("scene 2's track 2 empty at the end: R or U without C= "
                      "taken as another key")       # (rec_key_io once left A = 0: DEL)
    if KEYS_OF_RUN[0] == 15:                # (stage E: each key did what it should)
        ds = [dd for _, dd in pairs[first:]]
        end = ds[-1]
        sv = lambda dd, k, i=0: dd["sv"][SV_AT[k] + i]
        if (end["bars"][0], end["sigs"][0], end["reps"][0]) != (4, 4, 1):
            errors.append(f"scene 1 at the end: {end['bars'][0]} bars, signature "
                          f"{end['sigs'][0]:02x}, {end['reps'][0]} repeats, not 4 bars of "
                          f"5/4 once")
        if end["scenes"][16:18] != bytes([0, 1]) and list(end["scenes"][16:18]) != [0, 1]:
            errors.append(f"scene 2's cells {list(end['scenes'][16:18])}, not patterns 1, 2")
        if not any(sv(dd, "play_scene") == 1 for dd in ds):
            errors.append("scene 2 never played (SHIFT+RETURN)")
        if not any(sv(dd, "ovr_scene", 1) == 0 for dd in ds):
            errors.append("scene 1's cell never launched on track 2 (C= RETURN)")
        if not sv(end, "song_on"):
            errors.append("Song not on at the end (C= S)")
        if not any(sv(dd, "launch_pending") for dd in ds):
            errors.append("no launch ever seen waiting ('+')")
    notes.append("rows as the model's within " + ", ".join(f"{k} {v}" for k, v in worst.items())
                 + " frames")
    bad_cursor, spread = [], 0
    modes = [view(dd) for _, dd in pairs[first:]]
    switched = 0
    for i, f in enumerate(frames):
        if i and modes[i] != modes[i - 1]:
            switched = i
        if switched and i - switched < SETTLE_SWITCH:
            continue                            # (a switch of screens being drawn)
        if modes[i]:                            # the step grid: one cursor in its steps
            k = len([1 for r, c in cursor_places(f) if r < 19])
            if k != 1:
                bad_cursor.append((i, k))
            continue
        for r in range(25):
            if any(code is None or colour == -1 for code, colour in f[r]):
                errors.append(f"frame {i}, row {r}: a character not in the set: {text(f[r])!r}")
        for r in range(GRID_ROW, GRID_ROW + GRID_ROWS):
            if not text(f[r]).strip():
                errors.append(f"frame {i}: scene row {r} blank")
        k = cursors(f)
        if k != 1:
            bad_cursor.append((i, k))
        nums = [text(f[r])[:2] for r in range(GRID_ROW, GRID_ROW + GRID_ROWS)]
        try:
            v = [int(x) for x in nums]
            if any(b != a + 1 for a, b in zip(v, v[1:])):
                spread += 1
        except ValueError:
            errors.append(f"frame {i}: a scene row without its number: {nums}")
    for i, k in bad_cursor:
        around = "; ".join(f"{j}: {cursor_places(frames[j])}"
                           for j in range(max(0, i - 1), min(len(frames), i + 2)))
        errors.append(f"frame {i}: {k} cursors (row, column: {around})")
    # A, B, A with B short: a flash
    flashes = 0
    for r in range(25):
        runs = []
        for i, f in enumerate(frames):
            if runs and runs[-1][0] == f[r]:
                runs[-1][2] += 1
            else:
                runs.append([f[r], i, 1])
        for a, b, c in zip(runs, runs[1:], runs[2:]):
            if a[0] == c[0] and b[2] <= FLASH_FRAMES and plain(b[0]) != plain(a[0]):
                flashes += 1
                errors.append(f"row {r}, frames {b[1]}-{b[1] + b[2] - 1}: {text(b[0])!r} "
                              f"between {text(a[0])!r}")
    changes = sum(1 for r in range(25) for a, b in zip(frames, frames[1:]) if a[r] != b[r])
    notes.append(f"{spread} frames with the scene rows part redrawn")
    print(f"{name}: {len(frames)} frames of the song screen, {changes} row changes; "
          f"{flashes} flashes; " + "; ".join(notes))
    errors += TABLE_ERRORS
    TABLE_ERRORS.clear()
    for e in errors[:12]:
        print("   FAIL:", e)
    if len(errors) > 12:
        print(f"   ... {len(errors) - 12} more")
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=None, help="frames a run (default: the script's)")
    ap.add_argument("--run", type=int, default=None, help="only this run (its index)")
    a = ap.parse_args()
    ok = True
    for i, (name, scene, keys, frames) in enumerate(RUNS):
        if a.run is not None and i != a.run:
            continue
        prg = os.path.join(ROOT, "flash-t.prg")
        mark = build(prg, scene, keys)
        try:
            ok &= check(name, grab(prg, mark, a.frames or frames),
                        SETTLE_BUSY if scene == 4 else SETTLE_LIGHT)
        finally:
            for p in (prg, prg + ".lbl"):
                if os.path.exists(p):
                    os.remove(p)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
