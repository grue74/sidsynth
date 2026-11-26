r"""vice_env.py - SID500's checks use the patched VICE (imported for its
effect): C:\app\gtkvice-midi10, a GTK x64sc built from the VICE tree with
MIDI on and its 6850 sending a byte in the wire's 10 bit times (stock VICE:
9, ~11 % faster than any real interface; docs/latency.md "The hardware
test"). The shared tools (../c64tools vicetime.find_vice) take it from
VICE_X64SC; without that build they fall back to the stock GTK VICE.
"""
import os

VICE_MIDI10 = r"C:\app\gtkvice-midi10\bin\x64sc.exe"
if os.path.exists(VICE_MIDI10):
    os.environ.setdefault("VICE_X64SC", VICE_MIDI10)

# a MIDI byte on the emulated wire, in cycles: 10 bit times in the patched
# VICE (315, as a real 6850), 9 in stock VICE (283); the checks' wire models
BYTE_CYCLES = 315 if os.environ.get("VICE_X64SC") == VICE_MIDI10 else 283
