# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Steinberg Pro-16 2.4 in VICE, played from a script.

    p = Pro16(nums)          # starts VICE with pro16/pro16-2-4.prg, Datel MIDI on "pro16"
    p.press(KEY["F1"]); p.press(KEY["RETURN"]); p.shot("x.png"); p.quit()

Pro-16 scans the keyboard matrix itself (its routine at $CC4E: X = the
key's PETSCII from the KERNAL's key table, $FF = none), so the KERNAL's
keyboard buffer (monitor keybuf) never reaches it. press() puts the key
in a mailbox instead: a patch in the free tape buffer ($03C0) makes the
scan return the mailbox's key ($03F0) for a few calls (the count in
$03F1), as a key held and let go; with the mailbox empty ($FF) the real
scan runs as before. RUN/STOP during playback is read apart from the
scan (at $BDF7: LDA $DC01, BPL = stop): that read calls STOPCHECK, which
answers "pressed" while the mailbox holds RUN/STOP ($03).
"""
import time

import vice_band
from vice import Vice

PRG = "pro16/pro16-2-4.prg"
SCAN = 0xCC4E                   # Pro-16's keyboard scan
SCAN_CONTINUE = 0xCC53          # ... after its first two instructions
PATCH = 0x03C0
STOPCHECK = 0x03A0              # playback's RUN/STOP read (STOP_READ) comes here
STOP_READ = 0xBDF7
MAILBOX = 0x03F0                # the key's PETSCII, $FF = none
HOLD = 0x03F1                   # scans it stays pressed
STARTUP_SECONDS = 18            # unpacking, the title, the main screen

KEY = {"F1": 0x85, "F3": 0x86, "F5": 0x87, "F7": 0x88, "F2": 0x89, "F4": 0x8A, "F6": 0x8B,
       "F8": 0x8C, "RETURN": 0x0D, "STOP": 0x03, "RIGHT": 0x1D, "LEFT": 0x9D, "DOWN": 0x11,
       "UP": 0x91, "ARROW": 0x5F, "HOME": 0x13, "SPACE": 0x20, "DEL": 0x14}


def patch_bytes():
    """The scan's mailbox, at PATCH (see the module's notes)."""
    lo, hi = MAILBOX & 0xFF, MAILBOX >> 8
    hlo, hhi = HOLD & 0xFF, HOLD >> 8
    code = [0xAE, lo, hi,               # LDX MAILBOX
            0xE0, 0xFF,                 # CPX #$FF
            0xF0, 0x10,                 # BEQ orig
            0xCE, hlo, hhi,             # DEC HOLD
            0xD0, 0x05,                 # BNE ret
            0xA0, 0xFF,                 # LDY #$FF
            0x8C, lo, hi,               # STY MAILBOX: let go
            0xA9, 0x7F,                 # ret: LDA #$7F (as the scan ends)
            0x8D, 0x00, 0xDC,           # STA $DC00
            0x60,                       # RTS
            0xA9, 0x00,                 # orig: LDA #$00 (the scan's first two)
            0x8D, 0x00, 0xDC,           # STA $DC00
            0x4C, SCAN_CONTINUE & 0xFF, SCAN_CONTINUE >> 8]
    return code


def stopcheck_bytes():
    """STOPCHECK: A = $DC01 as read, or with bit 7 clear (RUN/STOP down)
    while the mailbox holds RUN/STOP; the N flag as LDA leaves it."""
    lo, hi = MAILBOX & 0xFF, MAILBOX >> 8
    return [0xAD, lo, hi,               # LDA MAILBOX
            0xC9, 0x03,                 # CMP #$03 (RUN/STOP)
            0xD0, 0x08,                 # BNE real
            0xA9, 0xFF,                 # LDA #$FF
            0x8D, lo, hi,               # STA MAILBOX: let go
            0xA9, 0x7F,                 # LDA #$7F: bit 7 clear (N = 0)
            0x60,                       # RTS
            0xAD, 0x01, 0xDC,           # real: LDA $DC01
            0x60]                       # RTS


class Pro16:
    def __init__(self, nums, title="pro16", disk=None):
        """nums: the MIDI device numbers (vice_band), or None for no MIDI."""
        midi = vice_band.vice_args("pro16", nums) if nums else []
        self.v = Vice(title, midi=midi, prg=PRG, sid8580=False, disk=disk)
        time.sleep(STARTUP_SECONDS)
        m = self.v.mon
        m.stop()
        m.cmd(f"> {PATCH:04x} " + " ".join(f"{b:02x}" for b in patch_bytes()))
        m.cmd(f"> {MAILBOX:04x} ff 00")
        m.cmd(f"> {SCAN:04x} 4c {PATCH & 0xFF:02x} {PATCH >> 8:02x}")
        m.cmd(f"> {STOPCHECK:04x} " + " ".join(f"{b:02x}" for b in stopcheck_bytes()))
        m.cmd(f"> {STOP_READ:04x} 20 {STOPCHECK & 0xFF:02x} {STOPCHECK >> 8:02x}")
        self.v.go()

    def press(self, key, hold=3, after=0.25):
        """Press a key (PETSCII code, or a KEY name) for hold scans."""
        if isinstance(key, str):
            key = KEY[key] if key in KEY else ord(key.upper())
        m = self.v.mon
        m.stop()
        m.cmd(f"> {MAILBOX:04x} {key:02x} {hold:02x}")
        self.v.go()
        time.sleep(after)

    def keys(self, *names, after=0.25):
        for k in names:
            self.press(k, after=after)

    def shot(self, path):
        self.v.shot(path)

    def quit(self):
        self.v.quit()
