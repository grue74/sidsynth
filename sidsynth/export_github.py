# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""export_github.py - the SidSynth family as one public repository.

    python export_github.py [--out DIR] [--commit MESSAGE]

Assembles the public tree in DIR (default E:\\GitHub\\sidsynth, a git
repository of its own; its remote is GitHub's) from the projects as they
are committed (git ls-files of each, the core from sid500's submodule):

    core/       the shared core (synthcore)
    sid303/ sid808/ sid101/ sid500/   the programs
    sidsynth/   the family web site's scripts (each program's make_site.py
                writes into sidsynth/site/)
    tools/      c64pack.py and test_pack.py (the packer), d64.py (disk images)

Left out: media (WAV, MP3, MP4: the web site has the recordings), the
assistant's directions (CLAUDE.md, docs/shared-parts.md), old work (work/,
proto/, docs/reference/, docs/experiments/), build output (listings,
labels), and the web site's upload script (a private server).

Changed in the copies only, so a clone builds: each program finds the core at
../core (64tass -I .. on every call), and the packer and d64.py in ../tools.
The projects themselves stay as they are (each with its core/ submodule and
../packer, ../c64tools beside it).

With --commit, the tree is committed in DIR (author: the user's GitHub
no-reply address); pushing is left to the caller.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))          # projects/sidsynth
PROJECTS = os.path.dirname(ROOT)
PROGRAMS = ["sid303", "sid808", "sid101", "sid500"]
AUTHOR = "Jarkko Lehti <43750721+grue74@users.noreply.github.com>"

SKIP_EXT = (".wav", ".mp3", ".mp4", ".lst", ".lbl")
SKIP_NAMES = ("CLAUDE.md", ".gitmodules", "build-number.txt")
SKIP_PATHS = ("docs/shared-parts.md", "upload.sh", "stats.py")   # (stats.py: the private server's logs)
SKIP_DIRS = ("work/", "proto/", "docs/reference/", "docs/experiments/", ".claude/")
TOOLS = [("packer", "c64pack.py"), ("packer", "test_pack.py"), ("c64tools", "d64.py")]

# the packer's own licence (the user, 2026-11-26: "release the packer with
# greetings licence"); the rest of the repository is GPL v3 or later
PACKER_LICENSE = """c64pack - a fast-unpacking packer for Commodore 64 programs
(tools/c64pack.py and its self-check tools/test_pack.py)

Copyright (C) 2026 Jarkko Lehti (grue)

The Greetings Licence

You may use, copy, change and pass on this packer, and anything packed with
it, for any purpose, free of charge, with or without changes, in source or
in any other form.

In return: when something you release was packed with it, send greetings to
grue in the release (its greetings, credits or notes). That's all.

The packer comes as it is, without any warranty: whoever uses it does so at
their own risk.
"""


def tracked(project):
    """The project's tracked files (not the core submodule's)."""
    out = subprocess.run(["git", "ls-files"], cwd=project, check=True,
                         capture_output=True, text=True).stdout.splitlines()
    return [f for f in out if os.path.isfile(os.path.join(project, f))]


def wanted(f):
    name = os.path.basename(f)
    return not (f.lower().endswith(SKIP_EXT) or name in SKIP_NAMES or f in SKIP_PATHS
                or any(f.startswith(d) or ("/" + d) in f for d in SKIP_DIRS))


def portable(text, path):
    """A copied script made to work in the public tree: the core at ../core
    (64tass -I ..), the tools in ../tools."""
    if path.endswith(".sh"):
        text = "".join(line if line.lstrip().startswith("#") else
                       re.sub(r"(^|[\s;(])64tass ", r"\g<1>64tass -I .. ", line)
                       for line in text.splitlines(keepends=True))   # (commands, not comments)
        text = text.replace('"$HOME/OneDrive/Commodore/projects/packer/c64pack.py"',
                            '"../tools/c64pack.py"')
        text = text.replace('"$HOME/OneDrive/Commodore/projects/c64tools/d64.py"',
                            '"../tools/d64.py"')
    elif path.endswith(".py"):
        text = text.replace('"64tass", "-I", "..",', '"64tass", "-I", "..", "-I", "..",')
        # the core's Python (tables_core.py, sysex.py) and files: ../core
        text = text.replace('os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core")',
                            'os.path.join(os.path.dirname(os.path.dirname('
                            'os.path.abspath(__file__))), "core")')
        text = text.replace('os.path.join(os.path.dirname(ROOT), "core"', 'os.path.join(os.path.dirname(ROOT), "core"')
    if path == "README.md" and "upload.sh" in text:    # (the site's: its upload and stats
        text = "".join(line for line in text.splitlines(keepends=True)   # are private)
                       if "upload.sh" not in line and "stats.py" not in line)
    return text


def copy_project(src, dst, files):
    n = 0
    for f in files:
        if not wanted(f):
            continue
        s, d = os.path.join(src, f), os.path.join(dst, f)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        if f.endswith((".sh", ".py")) or f == "README.md":
            text = open(s, encoding="utf-8", newline="").read()
            open(d, "w", encoding="utf-8", newline="").write(portable(text, f))
        else:
            shutil.copyfile(s, d)
        n += 1
    return n


README = """# SidSynth

Synthesizers and a sequencer for the Commodore 64 and its SID chip, built on
one shared core. Each program turns a C64 into one dedicated instrument,
played from MIDI, its own keyboard and paddles.

**Web site: [voidhole.com/~grue/sidsynth](https://voidhole.com/~grue/sidsynth/)**,
with each program's page, its demos to watch and hear, the manuals and the
disk images.

| Folder | What it is |
|---|---|
| `sid303/` | **SID303**, an acid bass synth in the spirit of the TB-303, with its own step sequencer |
| `sid808/` | **SID808**, an 808-style drum machine: thirteen drum sounds synthesized live |
| `sid101/` | **SID101**, an SH-101 style lead synth with a sync lead, the C64's own 80s lead and an arpeggiator |
| `sid500/` | **SID500**, a 16-channel MIDI sequencer named after the Roland MC-500, playing the others |
| `core/` | the shared core: start-up, MIDI in and out, parameters, keyboard, paddles, screen |
| `sidsynth/` | the family's web site: each program's `make_site.py` writes its page into `sidsynth/site/` |
| `tools/` | `c64pack.py` (the packer the disk images use; its own Greetings Licence: `tools/LICENSE-c64pack.txt`), `d64.py` (writes the disk images) |

Each program has its own README or manual (`docs/*-manual.pdf`, built by
`docs/manual.py`) and its design notes in `docs/`.

## Building

You need [64tass](https://sourceforge.net/projects/tass64/) and Python 3 on
the path (and `pip install py65` for the packer's self-check). In a program's
folder, `sh build.sh` assembles it and writes its disk image. The core
options are off by default, so every program builds byte-identical whatever
the others turned on.

The checks in each program's `tools/` run the programs in the VICE emulator
and need VICE and further helper scripts (`c64tools`) that are not part of
this repository.

## Hardware

A PAL Commodore 64 (the synths sound as meant with an 8580 SID), a MIDI
cartridge (Datel/Siel/JMS, Sequential, Passport or Namesoft, or a Kerberos
set to one of them) and, for SID500, MIDI instruments on its MIDI OUT.

## License

Copyright (C) 2026 Jarkko Lehti. Free software under the GNU General Public
License version 3 or later: see `LICENSE`. The packer (`tools/c64pack.py`,
`tools/test_pack.py`) is under its own Greetings Licence
(`tools/LICENSE-c64pack.txt`): use it freely, greet its author in what you
release with it. SID500's Moonlight Sonata demo song
(`sid500/songs/moonlight.s5`) holds notes from the Mutopia Project's edition
(Berners 1908, ed. Winterberger; CC BY-SA 2.5).
"""

GITATTRIBUTES = """# LF line endings (the build scripts run under sh)
* text=auto eol=lf
*.prg binary
*.d64 binary
*.png binary
*.pdf binary
*.s5 binary
"""

GITIGNORE = """# build output and test builds
tables.inc
build-number.txt
*.lst
*.lbl
__pycache__/
# renders, captures and the web site as built
work/
sidsynth/site/
sid500/src/demo_keys.inc
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=r"E:\GitHub\sidsynth")    # (the user: under E:\GitHub)
    ap.add_argument("--commit", help="commit the tree with this message")
    a = ap.parse_args()
    out = a.out
    os.makedirs(out, exist_ok=True)
    # the tree afresh (its .git kept)
    for name in os.listdir(out):
        if name == ".git":
            continue
        p = os.path.join(out, name)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)

    counts = {}
    for prog in PROGRAMS:
        src = os.path.join(PROJECTS, prog)
        counts[prog] = copy_project(src, os.path.join(out, prog), tracked(src))
    core = os.path.join(PROJECTS, "sid500", "core")
    counts["core"] = copy_project(core, os.path.join(out, "core"), tracked(core))
    counts["sidsynth"] = copy_project(ROOT, os.path.join(out, "sidsynth"), tracked(ROOT))
    os.makedirs(os.path.join(out, "tools"), exist_ok=True)
    for d, f in TOOLS:
        shutil.copyfile(os.path.join(PROJECTS, d, f), os.path.join(out, "tools", f))
    counts["tools"] = len(TOOLS)
    shutil.copyfile(os.path.join(PROJECTS, "sid500", "LICENSE"), os.path.join(out, "LICENSE"))
    open(os.path.join(out, "tools", "LICENSE-c64pack.txt"), "w", encoding="utf-8",
         newline="\n").write(PACKER_LICENSE)
    for name, text in (("README.md", README), (".gitattributes", GITATTRIBUTES),
                       (".gitignore", GITIGNORE)):
        open(os.path.join(out, name), "w", encoding="utf-8", newline="\n").write(text)

    total = sum(os.path.getsize(os.path.join(d, f)) for d, ds, fs in os.walk(out)
                if ".git" not in d.split(os.sep) for f in fs)
    print(f"{out}: " + ", ".join(f"{k} {v}" for k, v in counts.items())
          + f" files; {total / 1024 / 1024:.1f} MB")

    if a.commit:
        if not os.path.isdir(os.path.join(out, ".git")):
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=out, check=True)
        subprocess.run(["git", "add", "-A"], cwd=out, check=True)
        subprocess.run(["git", "-c", "user.name=Jarkko Lehti", "-c",
                        "user.email=43750721+grue74@users.noreply.github.com", "commit", "-q",
                        "--author", AUTHOR, "-m", a.commit], cwd=out, check=True)
        print(subprocess.run(["git", "log", "--oneline", "-1"], cwd=out, check=True,
                             capture_output=True, text=True).stdout.strip())


if __name__ == "__main__":
    sys.exit(main())
