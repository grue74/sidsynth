# Latency in the SidSynth family

The user (2026-11-26): "it is paramount that the sequencer is stable with
latency and as fast as possible for stable results with many synths." These
are the measured figures, how they were measured, and what could still be
gained. The **tech specs** section at the end holds the numbers for the
release web page; keep it current when anything here changes.

All figures are from VICE (PAL, 985,248 Hz), stamped in CPU cycles, not
estimated. MIDI's wire is 31,250 baud: a byte is 320 us (VICE's 6850 sends
one every 283 cycles, the wire takes 315), so a 3-byte note on takes 0.96 ms
on the wire (0.64 ms with running status) before any device can know it.
That wire time is not in the figures below, which start when the last byte
has arrived.

## SID500: the sequencer's own output

What SID500 plays goes out exactly on its ticks (design section 4: the
player runs in CIA1 timer A's interrupt, rendered ahead by ~42 ms at any
tempo, the clock jumps the queue). `python tools/timing_check.py`, both CIA
models, 2026-11-26:

| Measured | Figure |
|---|---|
| Ticks on their grid (Datel, IRQ) | within 97-302 cycles (0.1-0.3 ms), 40-240 BPM, with 16-note bursts |
| Tempo | the average tick within 0.02 cycles of exact |
| MIDI clock after its tick | 358-501 cycles (0.36-0.51 ms) |
| Clock gaps vary by | 0.31-0.56 ms |
| A burst's last byte behind the wire's pace | at most 0.36 ms (120 BPM), 0.41 ms (240 BPM) |
| Namesoft (NMI) | ticks within 0.2-0.4 ms, clock gaps vary by ~0.9 ms (the NMI's nature) |

Under load (`python tools/play_check.py --sparse`, every byte against a
wire model): the player adds at most **3.1 ms** to any byte with half the
wire busy (the user's limit 3.2 ms), 2.4 ms on the band.

As slave (`python tools/slave_check.py`): the master's clock passed on
within 519-562 cycles (~0.55 ms); a tick within ~1,040 cycles (~1.05 ms)
of its clock.

Recording (`python tools/record_check.py`): a played note is stamped at the
tick heard when its last byte came, within one tick; the player's lag while
recording 3.7-4.5 ms (the user: 5 ms, reported).

## SID500: MIDI thru

A keyboard played through SID500 to a synth (`python tools/thru_check.py`;
in to out, the last byte in to the last byte out):

| Case | Before 2026-11-26 | Sending from the receive interrupt (being settled) |
|---|---|---|
| Stopped | 1.6-5.3 ms (median 3.2-3.4) | 1.7-6.7 ms (median 3.2-3.3) |
| The band, 120 BPM | 2.5-16.4 ms (median ~8) | 1.7-20.5 ms (median 3.6-4.6) |
| The band, 240 BPM | 3.0-32.5 ms (median 15.5-17.9) | 2.2-32.4 ms (median 6.1-7.1) |
| Half the wire, 120 BPM | 2.8-24.9 ms (median 9.4) | 2.7-55.0 ms (median 11-16) |
| Namesoft (NMI), the band | 1.5-12.6 ms (median 5.5) | 1.3-11.8 ms (median 5.3-6.0) |

**Where the time went** (`thru_why.py`, the wait split into the wire busy
with bytes ahead and the wire idle): at 240 BPM the worst message waited
34.6 ms of which 22 ms the wire was idle; at 120 BPM 15 ms of which 11 ms
idle. A message received while playing was only queued and waited for a
send point (a tick's start, the main loop's 250 Hz poll, after a release),
which the clock guard (no thru that would still be on the wire when a
clock is due) and ticks released in parts (the renderer behind on a busy
16th) often skipped; a burst's messages went one or two per send point.

**Thru from the receive interrupt: tried, not taken** (the user, 2026-11-26:
"keep the queue"). The receive interrupt sent a message as it arrived when
that was safe (not inside a release, the clock guard), and a message could
go between a tick's parts with no render step running and nothing staged
(`docs/experiments/thru-from-irq.patch`, against 99ab6e6; it also moved the
clock's song-position arithmetic under I/O for room). On the real wire's
pace, against the queue:

| | Queue (kept) | From the receive interrupt |
|---|---|---|
| The band, 120 BPM | median 8.5-9.3 ms, worst 16.8-19.9 | median 4.7-4.9, worst 11.2-11.5 |
| The band, 240 BPM | median 14-19 ms, worst 30.9-34.5 | median 5.2-7.2, worst 23.8-24.9 |
| Half the wire, 120 BPM | median 9.8-12.7 ms, worst 19.9-21.2 | median 12.1-12.9, worst 43.6-49.1 |
| Ticks off their grid (jitter runs) | - | ~500 cycles more |
| A clock after its tick | - | up to ~600 cycles later |
| The receive interrupt's longest | +~200 cycles | +694 (limit 360) |

The sequencer's own timing comes first (the user): the queue stays.

## The synths: MIDI in to the SID

`python tools/synth_latency.py` (2026-11-26): each synth built as it is
(its own code untouched, this project's core, byte-identical), a note on and
its note off fed through the real receive interrupt (the core's test option
`TEST_RX_NOTES`: the raster interrupt standing in for the ACIA, a wire's
byte apart, at varying places in the synth's tick, two notes a fifth apart
in turn), every SID write stamped by headless VICE's sound dump. From the
note on's last byte:

| Synth | Gate open | The note's own pitch | Heard (both) | The last note's pitch before it |
|---|---|---|---|---|
| SID303 (note 60/67) | 0.9-6.9 ms, median 2.3-2.6 | 1.4-7.4 ms, median 2.7-3.2 | **1.4-7.4 ms, median 2.7-3.2** | 0.4-3.4 ms, median 0.46 |
| SID101 (note 60/67) | 0.8-5.2 ms, median 1.5-1.6 | 1.7-6.1 ms, median 2.9-3.1 | **1.7-6.1 ms, median 2.9-3.1** | 0.75-3.8 ms, median 0.84 |
| SID808 (kick, 36) | 1.2-4.2 ms, median 1.8-2.1 | 5.3-9.4 ms, median 7.0-7.1 | **5.3-9.4 ms, median 7.0-7.1** | (parked: silent) |

Note off to the gate closing: SID303 0.3-6.1 ms (median 1.9-2.1); SID101
releases in software (its gate closes ~72-81 ms later, after its release);
SID808's hits end by themselves.

How each works, and what that costs:

- **SID303 and SID101:** the note on is parsed in the main loop
  (`midi_process`, first in each pass) and the gate opens at once; the
  note's frequency is written by the engine's next 250 Hz tick. So the
  wait is the main loop's pass in progress when the byte came (up to ~5 ms
  when a long piece of work, a tick of the engine or a screen row, is
  under way), and the voice opens at the previous note's pitch for 0.4-3.8
  ms (median 0.5-0.8 ms) until the tick writes the new one.
- **SID808:** a hit's voice is parked (frequency $FFFF, silent) while its
  envelope settles (`MUTE_SETTLE = 1`, design 5: soft hits otherwise start
  with a full-level spike), ~5 ms, then its waveform and pitch start. Its
  design measured 11-12 ms from MIDI to sound in audio (the wire and the
  attack included).

## What could still be gained (for the user to choose)

- **SID303, SID101: the pitch with the gate: done** (2026-11-26, sid303
  f4f5b25, sid101 fd50425): a fresh note's frequency written before its
  gate opens (SID101: not in C64 mode, whose chord and echo follow the
  tick: written early, a chord's note sounded a tick early). No note heard
  at the last one's pitch any more; over ~200 notes each, heard: SID303
  median 3.13 -> 2.75 ms (worst 7.75 -> 7.61), SID101 3.24 -> 2.27 ms
  (worst 6.53 -> 5.68). SID101's voice_check (chords: 672 runs against the
  model's 671) and dump_check fail the same without the change: older.
- **The main loop's wait: done where it fits** (2026-11-26, core 1a567c2
  `MIDI_POLL_SCAN`, off by default): `midi_process` also between the
  scan's pieces (after the paddles, after the keyboard). On in SID303
  (237d33b) and SID808 (030848a); **off in SID101** (a474c93): with it,
  SID101's heaviest cases fell 2-3 ticks behind (arp_check's controller
  stream with the arpeggiator, a SysEx request with the heaviest sound,
  preset_check's 256 notes with program changes, seq_check), against the
  family's limit of 1. Final, over ~200 notes each (synth_latency.py, 120
  s): SID303 heard median 2.39 ms, worst 4.65 (this morning 3.13 / 7.75);
  SID101 median 2.27, worst 5.68 (3.24 / 6.53: the pitch fix alone);
  SID808 median 7.26, worst 9.52 (its settle).
- **SID808: MUTE_SETTLE.** 0 would take ~4-5 ms off every hit, at the
  cost its design names (soft hits spike); a shorter settle is a middle
  way to measure.
- **SID500 thru:** as above.

## The hardware test (a real C64 against VICE)

`hwtest/midilat.prg` (on `hwtest/midilat.d64`; `hwtest/build.sh`) measures
the MIDI cartridge's 6850 the way the programs use it, on a real C64 (the
user's: a Kerberos cartridge, which emulates the 6850 of the interface it is
set to) or in VICE. Choose the interface (1 Sequential, 2 Passport, 3
Datel, 4 Namesoft, as the cartridge is set), then:

1. **Transmit pacing** (no cable needed): bytes written back to back as the
   ACIA takes them; how many it takes at once, then the byte period (min,
   max, average).
2. **Loopback, one byte** (MIDI OUT cabled to MIDI IN, the program asks):
   from the write to the byte's arrival back.
3. **Loopback, 3 bytes** (a note on's size), written as fast as taken.
4. **Loopback, 64 bytes**: the whole, and a byte's share.

Only data bytes are sent (a device left connected ignores them); every byte
back is compared, errors counted. Times in cycles and microseconds (PAL or
NTSC from the KERNAL's flag); each includes ~30 cycles of the measuring
itself.

What to expect from a real 6850 at 31,250 baud (its baud clock is the
cartridge's own, not the C64's): 2 bytes taken at once (its data and shift
registers), then a byte every **320 us** (315 PAL cycles) with almost no
spread; a byte back ~320-330 us after its write; 3 bytes ~0.96-1.0 ms; a
burst's byte share 320 us.

**Measured** (2026-11-26; the user's Ultimate 64 Elite II with a Kerberos,
its 6850 switched on as Datel, MIDI OUT cabled to its own MIDI IN, run and
read over the Ultimate's REST API; VICE x64sc with its Datel model):

| | Kerberos (a real MC68B50) | VICE |
|---|---|---|
| Bytes taken at once | 2 | 2 |
| Byte period | **315 cycles (319 us)**, 265-370 | 285 (289 us), 251-326 |
| One byte, write to its arrival back | **409 cycles (415 us)**, 384-435 | (no loopback device) |
| 3 bytes, first write to the last back | **1,225 cycles (1.24 ms)**, 1,196-1,285 | |
| 64-byte burst, a byte's share | **319 cycles (323 us)** | |

No errors. The hardware sends at the wire's own pace; VICE's 6850 is ~10 %
faster (283 cycles a byte by its model). So:

- SID500's figures measured in VICE that depend on the wire's pace (half
  the wire's lag, a burst's last byte, thru behind the player's bytes) are
  ~10 % longer on hardware; the timing of ticks and clocks (the CPU's) is
  not affected.
- The clock guard (record.asm `thru_one`) counted VICE's 283 cycles (n +
  n/8 pages, ~288): on hardware a byte is 315, so the guard could let a thru
  message in that was still on the wire when a clock was due (up to ~0.3 ms
  late). Now n + n/4 pages (320 cycles a byte).

**VICE patched** (the user, 2026-11-26): VICE's `src/midi.c` times a byte as
9 bit times on purpose ("9 is better if the frequency of external devices is
a bit off, that avoids buffer overflows for very large and fast transfers"),
for every interface, not Datel's alone. Our build sends 10, the wire's:
`C:\app\gtkvice-midi10` (GTK3 x64sc with MIDI, MSYS2;
`vice-custom\source\midi-ten-bits.patch`, vice-custom README), which
SID500's checks use through `tools/vice_env.py` (`VICE_X64SC`, read by
c64tools' `vicetime.find_vice`). In it hwtest/midilat's byte period is 313
cycles on average (the Kerberos: 315). The figures above this section were
measured with stock VICE (9 bits) until they are rerun.

**SID500 on the real wire's pace** (the patched VICE, the checks' wire model
at 315 cycles a byte, 2026-11-26): every check passes. timing_check: ticks
within 81-331 cycles of their grid, clocks 358-538 cycles after their tick;
play_check --sparse: the player adds at most 1.6-1.9 ms on the band, 2.45 ms
with half the wire busy; thru median 3.2 ms stopped, 8.5-9.3 ms on the band
at 120 BPM, 14-19 ms at 240 (worst 34.5 ms). The limits that depend on the
wire's pace scaled by it (the user: 315/283): play_check's LAG_MAX 3.2 ->
3.56 ms (a slave's sudden 240 -> 60 BPM jump: 3.25-3.50 ms on the real wire,
2.75-2.98 on stock VICE), thru_check's 30 -> 33.4 ms.

**The Kerberos's MIDI** (its source, c64/src/regs.h, and measured):
`$DE39` (MIDI_ADDRESS) places its 6850: writes (control, transmit) at
$DE00 + its high half, reads (status, receive) at $DE00 + its low half;
`$DE3A` (MIDI_CONFIG): $20 on, $04 2 MHz (else 500 kHz), $01 IRQ, $02 NMI,
$08/$10 MIDI in/out mirrored to thru. For the family's interfaces: Datel
$46 with 2 MHz, Sequential and Namesoft $02 (500 kHz), Passport $88. Its
menu switches MIDI off (and "Reset to BASIC" leaves it off); a program
started from a slot gets the slot's settings (the Kerberos PC tool), so a
SidSynth program needs its slot set to the interface it is set to.
`hwtest/midilat`'s 5 sets $46 / $24 itself.

## Tech specs (for the release web page)

Keep these in step with the sections above.

- **How measured:** in VICE, with the author's fork vice-gsync
  (https://github.com/grue74/vice-gsync, commit b101196985): stock VICE's
  MIDI interface sends a byte every 9 bit times, ~11 % faster than the real
  wire, flattering MIDI timing; the fork sends 10, as a real 6850 does
  (checked on a Kerberos on a real C64).

- **SID500 timing:** notes and clock on a fixed grid from CIA1's timer,
  rendered ~42 ms ahead: ticks within 0.3 ms of exact, MIDI clock 0.4-0.5
  ms after its tick, clock gaps steady within ~0.5 ms; at most ~3 ms added
  to any byte with half the MIDI wire busy; nothing ever dropped.
- **SID500 as slave:** the master's clock passed on within ~0.6 ms.
- **SID500 MIDI thru:** ~3 ms stopped; playing, median ~9 ms at 120 BPM,
  ~14-19 ms at 240 (the sequencer's own timing kept first).
- **SID303:** MIDI note on to sound median ~2.4 ms (1.3-4.7 ms), every
  note at its own pitch from its first sample.
- **SID101:** median ~2.3 ms (1.3-5.7 ms), the same.
- **SID808:** median ~7 ms (5.3-9.5 ms), including a ~5 ms envelope settle
  that keeps soft hits clean.
- (Add MIDI's own 1 ms for a note on's three bytes on the wire.)
