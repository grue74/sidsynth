# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""Starting the band's VICEs with their MIDI on the router's virtual ports.

    from vice_band import device_numbers, vice_args
    nums = device_numbers()               # port name -> (midi in #, midi out #)
    args = vice_args("pro16", nums)       # x64sc options: Datel MIDI on that port

The ports (vmidi.Port) must exist first. VICE numbers the MIDI devices as
Windows (WinMM) does: read here with midiIn/OutGetDevCaps. (mido's output
list is in another order: by it, -midiout went to the GS Wavetable Synth.)
"""
import ctypes
from ctypes import wintypes

DATEL = 2                       # x64sc -miditype: 0 Sequential, 1 Passport, 2 Datel, 3 Namesoft
PORTS = ("pro16", "sid101", "sid303", "sid808")

_winmm = ctypes.WinDLL("winmm")


class _InCaps(ctypes.Structure):
    _fields_ = [("wMid", wintypes.WORD), ("wPid", wintypes.WORD), ("vDriverVersion", wintypes.UINT),
                ("szPname", wintypes.WCHAR * 32), ("dwSupport", wintypes.DWORD)]


class _OutCaps(ctypes.Structure):
    _fields_ = [("wMid", wintypes.WORD), ("wPid", wintypes.WORD), ("vDriverVersion", wintypes.UINT),
                ("szPname", wintypes.WCHAR * 32), ("wTechnology", wintypes.WORD),
                ("wVoices", wintypes.WORD), ("wNotes", wintypes.WORD),
                ("wChannelMask", wintypes.WORD), ("dwSupport", wintypes.DWORD)]


def winmm_names():
    """(input names, output names) in Windows' (and VICE's) numbering."""
    ins, outs = [], []
    for i in range(_winmm.midiInGetNumDevs()):
        c = _InCaps()
        _winmm.midiInGetDevCapsW(i, ctypes.byref(c), ctypes.sizeof(c))
        ins.append(c.szPname)
    for i in range(_winmm.midiOutGetNumDevs()):
        c = _OutCaps()
        _winmm.midiOutGetDevCapsW(i, ctypes.byref(c), ctypes.sizeof(c))
        outs.append(c.szPname)
    return ins, outs


def device_numbers():
    """{port name: (input number, output number)} for the virtual ports."""
    ins, outs = winmm_names()
    return {name: (ins.index(name) if name in ins else None,
                   outs.index(name) if name in outs else None) for name in PORTS}


def vice_args(name, nums, midi_out=True):
    """x64sc options: the Datel MIDI cartridge with its in (and out) on
    the router's port name."""
    i, o = nums[name]
    args = ["-midi", "-miditype", str(DATEL), "-midiin", str(i)]
    if midi_out:
        args += ["-midiout", str(o)]
    return args
