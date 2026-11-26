# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""One VICE (x64sc) of the band, running in real time, driven through its
remote monitor (c64tools/vicetime.Monitor).

    v = Vice("pro16", midi=vice_band.vice_args("pro16", nums), prg="pro16/pro16-2-4.prg")
    v.keys("\\x5f"); v.shot("p.png"); v.quit()

GTK VICE needs the real display: started from the services session this
tool runs in, it gets none and runs at ~15 % speed. So each VICE starts
through a scheduled task (schtasks /it) in the user's desktop session: at
full speed, with its window on the user's screen.

keys() types into the KERNAL keyboard buffer (monitor keybuf), so it
reaches programs that read keys through the KERNAL. PETSCII: F1 $85, F3
$86, F5 $87, F7 $88, RETURN $0d, RUN/STOP $03, CRSR right $1d, down $11,
left-arrow $5f.
"""
import os
import shutil
import subprocess
import sys
import tempfile

C64TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                        "c64tools")
sys.path.insert(0, C64TOOLS)
import vicetime  # noqa: E402

CRLF = chr(13) + chr(10)


class Vice:
    def __init__(self, title, midi=(), wav=None, sid8580=True, extra=(), prg=None, disk=None):
        self.port = vicetime.free_port()
        args = [vicetime.find_vice(), "-default", "-remotemonitor",
                "-remotemonitoraddress", f"ip4://127.0.0.1:{self.port}"]
        if sid8580:
            args += ["-sidenginemodel", "257"]
        if wav:
            args += ["-sounddev", "wav", "-soundarg", wav]
        else:
            args += ["-sounddev", "dummy"]
        args += list(midi) + list(extra)
        # VICE mishandles some long paths (c64tools/vicecap.py): it runs in a
        # folder of its own, with short names
        self.dir = tempfile.mkdtemp(prefix=f"vice-{title}-")
        if disk:                        # drive 8 (true drive emulation: -default)
            shutil.copy(disk, os.path.join(self.dir, "d.d64"))
            args += ["-8", "d.d64"]
        if prg:                         # straight into memory, then RUN
            shutil.copy(prg, os.path.join(self.dir, "p.prg"))
            args += ["-autostartprgmode", "1", "-autostart", "p.prg"]
        self.title = title
        bat = os.path.join(self.dir, "run.bat")
        quoted = " ".join(f'"{a}"' if (" " in a or os.sep in a) else a for a in args)
        with open(bat, "w", newline="") as f:
            f.write("@echo off" + CRLF)
            f.write('cd /d "%~dp0"' + CRLF)
            f.write(f'start "" {quoted}' + CRLF)
        self.task = f"sidband-{title}"
        subprocess.run(["schtasks", "/create", "/tn", self.task, "/tr", f'"{bat}"', "/sc", "once",
                        "/st", "23:59", "/it", "/f"], check=True, capture_output=True)
        subprocess.run(["schtasks", "/run", "/tn", self.task], check=True, capture_output=True)
        self.mon = vicetime.Monitor(self.port)

    def cmd(self, c):
        """A monitor command (stop() first; go() runs the emulation on)."""
        return self.mon.cmd(c)

    def go(self):
        self.mon.cmd("x")

    def keys(self, text):
        """Type text (with \\xNN escapes for PETSCII codes) into the keyboard buffer."""
        self.mon.stop()
        r = self.mon.cmd(f'keybuf "{text}"')
        self.go()
        return r

    def shot(self, path):
        """A screenshot (PNG) into path (made in VICE's folder, then copied)."""
        self.mon.stop()
        self.mon.cmd('screenshot "s.png" 2')
        self.go()
        shutil.copy(os.path.join(self.dir, "s.png"), path)

    def peek(self, lo, hi):
        self.mon.stop()
        r = self.mon.cmd(f"m {lo:04x} {hi:04x}")
        self.go()
        return r

    def quit(self):
        try:
            self.mon.stop()
            self.mon.cmd("quit")
        except OSError:
            pass
        subprocess.run(["schtasks", "/delete", "/tn", self.task, "/f"], capture_output=True)
