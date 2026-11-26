# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Virtual MIDI ports through the teVirtualMIDI driver (installed with
loopMIDI), with ctypes: no loopMIDI window needed.

A port made here shows up to every other program as a MIDI input and a
MIDI output of that name. What this program sends (Port.send) arrives at
the programs that opened the port as an input; what they send to it as an
output comes to this program's callback.
"""
import ctypes
import threading
from ctypes import wintypes

_dll = ctypes.WinDLL("teVirtualMIDI64.dll")
FLAGS_PARSE_RX = 1              # the callback gets whole MIDI messages
FLAGS_PARSE_TX = 2              # sends are checked to be whole messages
FLAGS_BOTH = 12                 # the port is both an input and an output

CALLBACK = ctypes.WINFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(ctypes.c_ubyte),
                              wintypes.DWORD, ctypes.c_void_p)
_dll.virtualMIDICreatePortEx2.restype = ctypes.c_void_p
_dll.virtualMIDICreatePortEx2.argtypes = [wintypes.LPCWSTR, CALLBACK, ctypes.c_void_p,
                                          wintypes.DWORD, wintypes.DWORD]
_dll.virtualMIDISendData.restype = wintypes.BOOL
_dll.virtualMIDISendData.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ubyte), wintypes.DWORD]
_dll.virtualMIDIClosePort.argtypes = [ctypes.c_void_p]


class Port:
    """A virtual MIDI port called name. on_message(bytes) is called (from
    the driver's thread) with each message other programs send to it."""

    def __init__(self, name, on_message=None):
        self.name = name
        self.on_message = on_message

        def cb(port, data, length, instance):
            if data and length and self.on_message:
                self.on_message(bytes(data[:length]))
        self._cb = CALLBACK(cb)                 # kept: the driver calls it
        self._port = _dll.virtualMIDICreatePortEx2(name, self._cb, None, 65535,
                                                   FLAGS_PARSE_RX | FLAGS_BOTH)
        if not self._port:
            raise OSError(f"virtual MIDI port {name!r}: error {ctypes.get_last_error()}")

    def send(self, msg):
        buf = (ctypes.c_ubyte * len(msg))(*msg)
        return bool(_dll.virtualMIDISendData(self._port, buf, len(msg)))

    def close(self, timeout=2.0):
        """Close the port. The driver's close can block once another program
        has used the port (seen after VICE's MIDI out had it open), so it
        runs aside with a time limit; a port left open goes with the process."""
        if self._port:
            port, self._port = self._port, None
            self.on_message = None
            t = threading.Thread(target=_dll.virtualMIDIClosePort, args=(port,), daemon=True)
            t.start()
            t.join(timeout)
