"""build_matrix.py - SID500: assemble every configuration the check tools
build (no VICE), and optionally compare their labels with another commit.

Each check tool builds sid500.asm with its own TEST_* options; a change
that fits the release build can still break a test build (its pool, the
RAM under I/O or under the KERNAL, the zero page). This assembles them all
(the same option sets as the tools, ~100) and reports any that fail and
the largest ends (program, under I/O, the editor's variables, zero page).

With --ref REV it also assembles REV (in a temporary git worktree, its own
tables.py run there) and compares each configuration's labels from
synth_timer up to FROZEN_END: the code the timing was measured with (the
player, the renderer, the live reader, the core's keyboard code, the
interrupts' code after the tables up to the scene code; design 4b "The
hot code's place", design 7). Any label there at another address is
reported (hot_pad itself may move: it is what absorbs a change before it).

    python tools/build_matrix.py [--ref HEAD]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FROZEN_START, FROZEN_END = "synth_timer", "player_set_swing"   # (size.asm's first)
MOVABLE = {"hot_pad", "synth_rx_irq", "io_copy"}   # (hot_pad: what absorbs a change before it;
                                        # synth_rx_irq: the name moved to locate.asm's
                                        # wrapper, scene.asm's as synth_rx_irq_scene;
                                        # io_copy: in late_code with the disk, stage G)
MOVABLE_FROM, MOVABLE_TO = "param_max", "io_copy"   # (the parameter screen's tables and
                                        # texts, read by the main loop: the disk's Disk drive
                                        # made them longer; the core's test feed after them
                                        # too, test builds only; the tables stay: IO_COPY_PAD)
UNTIMED = {"TEST_TEMPO_ALL=1"}  # (builds that time nothing: their own code before the tables)


def configurations():
    """The -D option sets the check tools build (one of each kind)."""
    b = [[]]                                                    # the release
    for k, s in [(3, 4), (4, 1), (6, 1), (8, 1), (6, 4), (9, 1), (12, 1), (14, 1), (15, 1),
                 (16, 1)]:
        b.append(["TEST_FRAMES=1", f"TEST_KEYS={k}", f"TEST_PLAY={s}"])       # flash
    for k in (3, 7, 9, 12, 16):
        for s in (1, 4, 5):
            b.append(["TEST_LOG=1", "MIDI_IF_DEFAULT=3", f"TEST_KEYS={k}", f"TEST_PLAY={s}",
                      "TEST_STAMP_FEW=3"])                                  # screen
    b += [["TEST_KEYS=9", "TEST_PLAY=1"], ["TEST_KEYS=12", "TEST_PLAY=1"],
          ["TEST_KEYS=11", "TEST_MIDI=1"], ["TEST_EVENTS=1"], ["TEST_TEMPO_ALL=1"],
          ["TEST_KEYS=13", "MIDI_IF_DEFAULT=3", "TEST_TEMPO=125"]]          # edit, event, demo
    for s in (1, 2, 3, 4, 5):
        for live in ((0, 1, 2, 3) if s == 1 else (0, 1)):
            b.append(["TEST_LOG=1", f"TEST_LIVE={live}", f"TEST_PLAY={s}", "TEST_TEMPO=240",
                      "TEST_SWING=15", "TEST_STAMP_FEW=2"])                  # play
    for k in (1, 2, 5, 10):
        b.append(["TEST_LOG=1", "TEST_PLAY=1", f"TEST_KEYS={k}", "TEST_LIVE=3",
                  "TEST_ABORT=1"])                                          # transport
    for f in range(1, 10):
        b.append(["TEST_LOG=1", "TEST_PLAY=1", f"TEST_SLAVE={f}", "TEST_STAMP_FEW=2"])
        b.append(["TEST_LOG=1", "TEST_PLAY=1", f"TEST_SLAVE={f}", "TEST_SWITCH=200"])
        b.append(["TEST_LOG=1", "TEST_PLAY=2", f"TEST_SLAVE={f}"])          # slave
    for s in (1, 4):
        b.append(["TEST_LOG=1", f"TEST_PLAY={s}", "TEST_SLAVE=10", "TEST_FEED_MASTER=1",
                  "TEST_RX_TIME=1"])                                        # thru
    for s in (1,):
        b.append(["TEST_LOG=1", f"TEST_PLAY={s}", "TEST_SLAVE=11", "TEST_FEED_MASTER=1",
                  "TEST_RECORD=3", "TEST_REC_MODE=1", "TEST_REC_QUANT=3", "TEST_REC_END=900",
                  "TEST_REC_UNDO=1000", "TEST_REC_REDO=1100", "TEST_REC_STOP=1200",
                  "TEST_STAMP_FEW=2"])                                      # record
    b.append(["TEST_LOG=1", "TEST_PLAY=1", "TEST_SLAVE=12", "TEST_FEED_MASTER=1", "TEST_THRU=0",
              "TEST_COUNT=3", "TEST_COUNT_BARS=2", "TEST_CLICK=3", "TEST_COUNT_RESET=1",
              "TEST_COUNT_CANCEL=20"])                                      # count
    for t in range(1, 6):
        b.append(["TEST_LOG=1", "TEST_PLAY=1", f"TEST_SCENES={t}", "TEST_CLICK=1"])
        b.append(["TEST_LOG=1", "TEST_PLAY=1", f"TEST_SCENES={t}", "TEST_CLICK=1",
                  "TEST_SLAVE=12", "TEST_FEED_MASTER=1", "TEST_CHANNEL=1", "TEST_RECORD=2",
                  "TEST_REC_FROM=300"])                                     # scene
    for few in (0, 1, 2, 3):
        for burst in (0, 9, 16):
            b.append(["TEST_LOG=1", f"TEST_STAMP_FEW={few}", "TEST_TEMPO=240",
                      f"TEST_BURST={burst}"])                               # timing
    for keys in (0, 2):
        b.append(["TEST_LOG=1", f"TEST_PLAY={5 if keys else 1}", "TEST_CLICK=3",
                  "TEST_CLICK_CHAN=15", f"TEST_KEYS={keys}"])               # click
    return b


def labels(path):
    out = {}
    for line in open(path):
        if "=" in line:
            name, value = line.split("=", 1)
            value = value.strip()
            if value.startswith("$"):
                out[name.strip()] = int(value[1:], 16)
            elif value.isdigit():       # (a label from a computed address: decimal)
                out[name.strip()] = int(value)
    return out


def assemble(root, configs, out):
    """Each configuration of the tree at root: its labels, or its error."""
    env = dict(os.environ, SIDSYNTH_PROJECTS=os.path.dirname(ROOT))  # (the family's sources)
    subprocess.run([sys.executable, "tables.py"], cwd=root, check=True,
                   stdout=subprocess.DEVNULL, env=env)
    results = []
    for i, d in enumerate(configs):
        lbl = os.path.join(out, f"{i}.lbl")
        args = ["64tass", "-I", "..", "-C", "-a", "-q", "--cbm-prg"] + sum((["-D", x] for x in d), []) \
            + ["-l", lbl, "-o", os.path.join(out, "m.prg"), "sid500.asm"]
        r = subprocess.run(args, cwd=root, capture_output=True, text=True)
        if r.returncode:
            lines = [x for x in r.stderr.splitlines() if "error" in x]
            results.append((None, lines[0] if lines else r.stderr.strip()[:200]))
        else:
            results.append((labels(lbl), None))
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", help="a commit to compare the frozen code's labels with")
    a = ap.parse_args()
    configs = configurations()
    tmp = tempfile.mkdtemp()
    ok = True
    try:
        os.makedirs(os.path.join(tmp, "now"))
        now = assemble(ROOT, configs, os.path.join(tmp, "now"))
        failed = [(i, e) for i, (_, e) in enumerate(now) if e]
        for i, e in failed:
            print(f"FAIL {i} {' '.join(configs[i])}\n    {e}")
        built = [lab for lab, _ in now if lab]
        print(f"{len(configs)} configurations, {len(failed)} failed")
        if built:
            print("largest ends: program $%04x, under I/O $%04x, editor's variables $%04x, "
                  "zero page $%02x" % tuple(max(lab.get(k, 0) for lab in built) for k in
                                            ("program_end", "io_tables_end", "edit_vars_end",
                                             "zp_end")))
        if now[0][0]:
            r = now[0][0]
            print("the release: program $%04x (pool $%04x), under I/O $%04x" %
                  (r["program_end"], r["POOL_START"], r["io_tables_end"]))
        ok = not failed
        if a.ref:
            wt = os.path.join(tmp, "ref")
            subprocess.run(["git", "worktree", "add", "--detach", wt, a.ref], cwd=ROOT,
                           check=True, capture_output=True)
            try:
                core = os.path.join(os.path.dirname(ROOT), "core")          # (the submodule: the same files)
                shutil.rmtree(os.path.join(wt, "core"), ignore_errors=True)
                shutil.copytree(core, os.path.join(wt, "core"),
                                ignore=shutil.ignore_patterns(".git"))
                os.makedirs(os.path.join(tmp, "ref-out"))
                ref = assemble(wt, configs, os.path.join(tmp, "ref-out"))
            finally:
                subprocess.run(["git", "worktree", "remove", "--force", wt], cwd=ROOT,
                               capture_output=True)
            moved_any = 0
            for i, ((b, _), (r, _)) in enumerate(zip(now, ref)):
                if not b or not r or FROZEN_START not in r or FROZEN_END not in r                         or UNTIMED & set(configs[i]):
                    continue
                lo, hi = r[FROZEN_START], r[FROZEN_END]
                moved = sorted((n for n, v in r.items() if lo <= v <= hi and n in b
                                and b[n] != v and n not in MOVABLE and not n.isupper()
                                and not r.get(MOVABLE_FROM, -1) <= v <= r.get(MOVABLE_TO, -2)),
                               key=lambda n: r[n])     # (code: lowercase; not constants)
                if moved:
                    moved_any += 1
                    print(f"MOVED {i} {' '.join(configs[i])}: {len(moved)} labels, first "
                          + ", ".join(f"{n} ${r[n]:04x}->${b[n]:04x}" for n in moved[:3]))
            print(f"against {a.ref}: {moved_any} configurations with the frozen code moved "
                  f"({FROZEN_START} to {FROZEN_END})")
            # (information only since 2026-11-25: the code may move, the timing
            # checks run after each change; design "Memory for the music")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("all passed" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
