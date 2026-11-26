# Copyright (C) 2026 Jarkko Lehti
# SPDX-License-Identifier: GPL-3.0-or-later
"""The band's ports and Pro-16 together: recording a part into Pro-16 on
its own clock, and logging what Pro-16 plays.

    s = Session()                       # ports, Pro-16 started and set up
    s.record(track=1, events=evs)       # evs: [(clock, bytes)], clock 0 = the first beat
    log = s.play(seconds)               # Pro-16 plays; [(time, bytes)] it sent
    s.close()

Pro-16 records on its own clock (it can't follow MIDI clock while it
records, its manual 5-28) with MIDI clock out on (page two, MID): after
the count-in it sends start ($FA), then 24 clocks a beat; an event goes
to its MIDI in when its clock reaches the event's.
"""
import threading
import time

import vice_band
import vmidi
from pro16 import Pro16

SYNTH_PORT = {0: "sid101", 1: "sid303", 9: "sid808"}    # MIDI channel (0-based) -> port


class Session:
    def __init__(self, bars=64, tempo=94, channels=(1, 2, 10), title="pro16", disk=None):
        self.lock = threading.Lock()
        self.feed = None                # record: [(clock, bytes)] still to send
        self.clock = None               # Pro-16's clocks since its start
        self.route = False              # play: Pro-16's notes on to the synths
        self.route_until = None         # ... while its clock is below this (the song's
                                        # end: in SEQ mode it goes round again)
        self.log = []
        self.t0 = time.perf_counter()
        self.ports = {"pro16": vmidi.Port("pro16", self._from_pro16)}
        for n in ("sid101", "sid303", "sid808"):
            self.ports[n] = vmidi.Port(n)
        time.sleep(0.5)
        self.nums = vice_band.device_numbers()
        self.p = Pro16(self.nums, title, disk=disk)
        self.setup(bars, tempo, channels)

    # ---- MIDI from Pro-16 (the driver's thread)
    def _from_pro16(self, msg):
        now = time.perf_counter() - self.t0
        with self.lock:
            self.log.append((now, msg))
            if msg[0] == 0xFA:
                self.clock = 0
            elif msg[0] == 0xF8 and self.clock is not None:
                self.clock += 1
            elif msg[0] == 0xFC:
                self.clock = None
            if self.feed is not None and self.clock is not None and msg[0] in (0xFA, 0xF8):
                while self.feed and self.feed[0][0] <= self.clock:
                    _, m = self.feed.pop(0)
                    self.ports["pro16"].send(m)
                    port = SYNTH_PORT.get(m[0] & 0x0F)
                    if port:                    # heard while it records
                        self.ports[port].send(m)
            if self.route and msg[0] < 0xF0 and (self.route_until is None or (
                    self.clock is not None and self.clock < self.route_until)):
                port = SYNTH_PORT.get(msg[0] & 0x0F)
                if port:
                    self.ports[port].send(msg)

    # ---- Pro-16's screens
    def setup(self, bars, tempo, channels, quantize_off_presses=8):
        """Track channels, tempo, bars, quantize off (main screen), MIDI
        clock out on (page two). From the start screen (cursor on track 1)."""
        p, A = self.p, 0.15
        p.press("DOWN", after=A)                        # track 1's channel box
        for k, ch in enumerate(channels):
            if k:
                p.press("RIGHT", after=A)
            for _ in range(ch - 1):
                p.press("F1", after=A)
        for _ in range(len(channels) - 1):
            p.press("LEFT", after=A)
        p.keys("DOWN", "DOWN", "DOWN", after=A)         # TMP
        for _ in range(abs(120 - tempo)):              # it starts at 120
            p.press("F3" if tempo < 120 else "F1", after=A)
        p.press("RIGHT", after=A)                       # BAR
        for _ in range(abs(bars - 4)):
            p.press("F1" if bars > 4 else "F3", after=A)
        p.keys("RIGHT", "RIGHT", "RIGHT", after=A)      # QNT
        for _ in range(quantize_off_presses):           # 16, 24 ... 96, then 0: real time
            p.press("F1", after=0.3)
        p.press("ARROW", after=0.8)                     # page two: MID on
        p.keys("DOWN", "DOWN", "DOWN", "RIGHT", "RIGHT", "F1", after=A)
        p.press("ARROW", after=0.8)

    def record(self, track, events, length_clocks, margin=1.0, timeout=240):
        """Record track (1..16): events [(clock, bytes)] go in on Pro-16's
        clock; RUN/STOP once the sequence has gone round."""
        p = self.p
        p.press("T", after=0.3)                         # the cursor to track 1
        for _ in range(track - 1):
            p.press("RIGHT", after=0.15)
        with self.lock:
            self.feed = sorted(events, key=lambda e: e[0])
            self.clock = None
        p.press("R", after=0.5)
        limit = time.perf_counter() + timeout
        while time.perf_counter() < limit:              # wait until the sequence's end
            time.sleep(0.1)
            with self.lock:
                if self.clock is not None and self.clock >= length_clocks:
                    break
        else:
            print("record: Pro-16's clock never reached the end")
        time.sleep(margin)
        p.press("STOP", after=0.5)
        with self.lock:
            left = len(self.feed)
            self.feed = None
        return left

    def play(self, seconds, route=True, until_clock=None):
        """Play the sequence from its start (RETURN) for seconds, or with
        until_clock until Pro-16's clock reaches it (seconds then a time
        limit: after a disk save Pro-16 can start many seconds late);
        Pro-16's notes go on to the synths. Returns the log of that time."""
        with self.lock:
            self.log = []
            self.clock = None
            self.route = route
        self.p.press("RETURN", after=0)
        if until_clock is None:
            time.sleep(seconds)
        else:
            limit = time.perf_counter() + seconds
            while time.perf_counter() < limit:
                time.sleep(0.1)
                with self.lock:
                    if self.clock is not None and self.clock >= until_clock:
                        break
            else:
                print(f"play: Pro-16's clock never reached {until_clock}")
            time.sleep(0.5)
        self.p.press("STOP", after=0.5)
        with self.lock:
            self.route = False
            return list(self.log)

    def shot(self, path):
        self.p.shot(path)

    def close(self):
        self.p.quit()
        for q in self.ports.values():
            q.close()
