# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The band's MIDI router: virtual MIDI ports for four VICEs (vmidi.py,
teVirtualMIDI) and what goes between them.

    python router.py record cover.mid --channel 1 [--log out.txt]
    python router.py play [--log out.txt] [--seconds 200]
    python router.py direct cover.mid [--log out.txt]
    python router.py ports

Ports it makes: "pro16" (Pro-16's MIDI in and out), "sid101", "sid303",
"sid808" (each synth's MIDI in). Each VICE opens its port by number
(-midiin / -midiout): "ports" lists the numbers Windows gives them.

record: Pro-16 records on its own clock (it can't record while following
MIDI clock, its manual 5-28), with MIDI clock out on (screen page two,
MID ON). The router waits for its start ($FA, sent after the count-in)
and plays one channel of the MIDI file into Pro-16's MIDI in, an event
when Pro-16's clock (24 a beat) reaches it, so the part lands on Pro-16's
grid whatever the timing of either side. The notes also go to that
channel's synth, to hear them.

play: Pro-16's MIDI out, split by channel: 1 to SID101, 2 to SID303, 10
to SID808. Realtime bytes (clock, start, stop) are not passed on: the
synths' own sequencers stay out of it.

direct: the router plays the MIDI file to the synths itself (no Pro-16):
the reference, and the fallback.
"""
import argparse
import threading
import time

import mido

import vmidi

CHANNEL_PORT = {0: "sid101", 1: "sid303", 9: "sid808"}   # MIDI channel (0-based) -> port
SYNTHS = ("sid101", "sid303", "sid808")
CLOCKS_PER_BEAT = 24


class Log:
    """What went where, with the time from the start: for checking."""

    def __init__(self, path):
        self.f = open(path, "w") if path else None
        self.t0 = time.perf_counter()

    def __call__(self, where, msg):
        if self.f:
            self.f.write(f"{time.perf_counter() - self.t0:9.4f} {where} {bytes(msg).hex()}\n")
            self.f.flush()


def open_ports(on_pro16=None):
    ports = {"pro16": vmidi.Port("pro16", on_pro16)}
    for name in SYNTHS:
        ports[name] = vmidi.Port(name)
    return ports


def events(path, channel=None):
    """The MIDI file's channel messages as [(beat position, bytes)],
    in order; only channel (0-based) if given."""
    mid = mido.MidiFile(path)
    out, ticks = [], 0
    for msg in mido.merge_tracks(mid.tracks):
        ticks += msg.time
        if msg.is_meta or msg.type == "sysex":
            continue
        if channel is not None and getattr(msg, "channel", None) != channel:
            continue
        out.append((ticks / mid.ticks_per_beat, bytes(msg.bytes())))
    return out, mid


def cmd_ports(a):
    ports = open_ports()
    time.sleep(0.5)
    print("MIDI inputs (VICE -midiin):")
    for i, n in enumerate(mido.get_input_names()):
        print(f"  {i}: {n}")
    print("MIDI outputs (VICE -midiout):")
    for i, n in enumerate(mido.get_output_names()):
        print(f"  {i}: {n}")
    for p in ports.values():
        p.close()


def cmd_record(a):
    log = Log(a.log)
    ch = a.channel - 1
    evs, _ = events(a.file, ch)
    state = {"clock": None, "i": 0}
    lock = threading.Lock()
    done = threading.Event()
    ports = {}

    def on_pro16(msg):
        log("from-pro16", msg)
        with lock:
            if msg[0] == 0xFA:                  # start: clock 0 is beat 0
                state["clock"], state["i"] = 0, 0
                due = 0.0
            elif msg[0] == 0xF8 and state["clock"] is not None:
                state["clock"] += 1
                due = state["clock"] / CLOCKS_PER_BEAT
            elif msg[0] == 0xFC:                # stop
                state["clock"] = None
                return
            else:
                return
            # everything due by this clock (+ half a clock: the nearest)
            while state["i"] < len(evs) and evs[state["i"]][0] < due + 0.5 / CLOCKS_PER_BEAT:
                _, m = evs[state["i"]]
                ports["pro16"].send(m)
                log("to-pro16", m)
                if ch in CHANNEL_PORT:
                    ports[CHANNEL_PORT[ch]].send(m)
                state["i"] += 1
            if state["i"] >= len(evs):
                done.set()

    ports.update(open_ports(on_pro16))
    print(f"recording channel {a.channel}: {len(evs)} events, last at beat "
          f"{evs[-1][0]:.2f}; waiting for Pro-16's start (R, then the count-in)")
    try:
        done.wait()
        print("all sent; press RUN/STOP in Pro-16 when the sequence has gone round")
        time.sleep(a.tail)
    except KeyboardInterrupt:
        pass
    for p in ports.values():
        p.close()


def cmd_play(a):
    log = Log(a.log)
    ports = {}

    def on_pro16(msg):
        log("from-pro16", msg)
        if msg[0] >= 0xF0:
            return                              # realtime and system: not to the synths
        port = CHANNEL_PORT.get(msg[0] & 0x0F)
        if port:
            ports[port].send(msg)
            log(port, msg)

    ports.update(open_ports(on_pro16))
    print("routing Pro-16's MIDI out: channel 1 -> sid101, 2 -> sid303, 10 -> sid808")
    try:
        time.sleep(a.seconds)
    except KeyboardInterrupt:
        pass
    for p in ports.values():
        p.close()


def cmd_direct(a):
    log = Log(a.log)
    evs, mid = events(a.file)
    tempo = next((m.tempo for m in mid.tracks[0] if m.type == "set_tempo"), 500000)
    ports = open_ports()
    time.sleep(a.wait)
    t0 = time.perf_counter()
    for beat, m in evs:
        when = t0 + beat * tempo / 1e6
        while time.perf_counter() < when:
            time.sleep(0.0005)
        port = CHANNEL_PORT.get(m[0] & 0x0F)
        if port:
            ports[port].send(m)
            log(port, m)
    time.sleep(2)
    for p in ports.values():
        p.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("ports")
    s.set_defaults(fn=cmd_ports)
    s = sub.add_parser("record")
    s.add_argument("file")
    s.add_argument("--channel", type=int, required=True, help="1-16")
    s.add_argument("--tail", type=float, default=5)
    s.add_argument("--log")
    s.set_defaults(fn=cmd_record)
    s = sub.add_parser("play")
    s.add_argument("--seconds", type=float, default=600)
    s.add_argument("--log")
    s.set_defaults(fn=cmd_play)
    s = sub.add_parser("direct")
    s.add_argument("file")
    s.add_argument("--wait", type=float, default=0, help="seconds before the first note")
    s.add_argument("--log")
    s.set_defaults(fn=cmd_direct)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
