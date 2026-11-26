"""Check that a core change leaves the family's synths byte-identical.

The core's rule (CLAUDE.md): every change comes as an option that defaults
to off, so SID303, SID808 and SID101 must build exactly as before. This
builds every program each synth's build.sh makes (the 64tass lines only,
with BUILD and the version fixed at 0) twice, in two scratch copies of the
synth: once with the synth's own core and once with this project's core
(the working tree of ../sid500/core), and compares the PRGs byte for byte.

    python tools/core_identical.py [sid303 sid808 sid101]

Exit status 0 when every program is identical. Needs python and 64tass on
PATH, and sh (Git Bash) for the build lines.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECTS = os.path.normpath(os.path.join(HERE, '..', '..'))
NEW_CORE = os.path.normpath(os.path.join(HERE, '..', 'core'))
SYNTHS = ['sid303', 'sid808', 'sid101']

# what the build doesn't need: history, outputs, recordings, documents
SKIP = shutil.ignore_patterns('.git', 'demos', 'docs', 'snapshots', 'proto',
                              '__pycache__', '*.prg', '*.d64', '*.wav',
                              '*.mp4', '*.png', '*.pdf', '*.lst', '*.lbl')

# the variables build.sh's 64tass lines use, fixed so both builds agree
FIXED = {
    '$BUILD': '0',
    '$VER': '-D BUILD=0 -D V_MAJOR=0 -D V_MINOR=0 -D V_PATCH=0',
}


def build_lines(build_sh):
    """The 64tass command lines of a build.sh, continuations joined."""
    with open(build_sh, encoding='utf-8') as f:
        text = f.read().replace('\\\n', ' ')
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('64tass '):
            for name, value in FIXED.items():
                line = line.replace(name, value)
            lines.append(line)
    return lines


def output_of(line):
    """The file a 64tass line writes (its -o argument)."""
    words = line.split()
    return words[words.index('-o') + 1]


def build_copy(synth, core, where):
    """Copy the synth with the given core into where, build it; the PRGs."""
    src = os.path.join(PROJECTS, synth)
    dst = os.path.join(where, synth)
    def skip_top_core(path, names):
        # the synth's own core is left out; the one asked for goes in
        skipped = SKIP(path, names)
        if os.path.samefile(path, src):
            skipped.add('core')
        return skipped
    shutil.copytree(src, dst, ignore=skip_top_core)
    shutil.copytree(core, os.path.join(dst, 'core'), ignore=SKIP)
    subprocess.run([sys.executable, 'tables.py'], cwd=dst, check=True,
                   stdout=subprocess.DEVNULL)
    prgs = {}
    for line in build_lines(os.path.join(src, 'build.sh')):
        subprocess.run(['sh', '-c', line], cwd=dst, check=True)
        out = output_of(line)
        with open(os.path.join(dst, out), 'rb') as f:
            prgs[out] = f.read()
    return prgs


def main():
    synths = sys.argv[1:] or SYNTHS
    all_same = True
    with tempfile.TemporaryDirectory() as tmp:
        for synth in synths:
            old_core = os.path.join(PROJECTS, synth, 'core')
            old = build_copy(synth, old_core, os.path.join(tmp, 'old'))
            new = build_copy(synth, NEW_CORE, os.path.join(tmp, 'new'))
            for name in old:
                same = old[name] == new[name]
                all_same &= same
                print('%-8s %-26s %6d bytes  %s' % (
                    synth, name, len(old[name]),
                    'identical' if same else 'DIFFERENT (%d bytes new)'
                    % len(new[name])))
    print('all identical' if all_same else 'NOT identical')
    return 0 if all_same else 1


if __name__ == '__main__':
    sys.exit(main())
