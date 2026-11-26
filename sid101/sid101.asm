; =============================================================================
; SID101 - monophonic SH-101 style lead synth for the C64 with an 8580 SID
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
; This program is free software under the GNU General Public License,
; version 3 or (at your option) any later version; see LICENSE.
;
;   * MIDI in through a 6850 ACIA cartridge (Sequential, Passport, Datel,
;     Namesoft), any channel or omni, running status, pitch bend
;   * the C64 keyboard plays notes (tracker layout, two octaves)
;   * paddles: X = filter cutoff, Y = resonance at start, or any parameter
;     by learn (RETURN, then turn a paddle); soft takeover
;   * function keys select and change parameters (two pages: Sound, Play)
;   * a step sequencer (the core's, from SID303): 64 patterns of 16 steps
;     with accent, slide and tie, songs, MIDI clock in and out; its step
;     screen (F7), undo, and save and load on disk (from SID303)
;   * an arpeggiator: up, down, up and down, random over 1 to 3 octaves, at
;     1/8, 1/16 or 1/32 of the sequencer's tempo or of MIDI clock
;
; Sound model (docs/design.md; what an SH-101 does and how it is done on
; the SID):
;   oscillators  one note on all three voices: saw on voice 1, pulse on
;                voice 2 (width by hand and by the LFO: PWM), the sub on
;                voice 3 (square 1 or 2 octaves down, or a 25 % pulse 2 down)
;   mixer        each voice's level 0..15 through its SID sustain level
;   VCF          8580 12 dB low-pass, cutoff on a log scale, env mod, LFO
;   envelope     one software ADSR for the filter and (Env mode) the amp
;   VCA          SID ADSR with every rate at 0 (instant gate, no ADSR delay
;                bug); decay, sustain and release by lowering the sustain
;                levels (docs/plan.md, "Stage A: the amplitude envelope")
;   Sync mode    voice 2 a saw hard-synced to voice 1, its pitch above the
;                note by hand and swept by the envelope: the sync lead; the
;                sub stays on voice 3
;   LFO          triangle, square, random (sample and hold) or noise, with a
;                fade-in after each fresh note; to pitch (vibrato, plus the mod
;                wheel), pulse width and cutoff
;   accent       velocity lowers the level of soft notes and adds env mod to
;                hard ones, by the Accent amount
;   glide        RC-like portamento: Off, On (every note), Auto (legato only)
;
; Build: see build.sh (python tables.py; 64tass ...). PAL timing.
; Memory: BASIC and KERNAL ROMs are banked out ($01 = $35); we own the
; hardware IRQ/NMI vectors at $FFFE/$FFFA.
; =============================================================================

        .cpu "6502"

        .weak                   ; overridable with 64tass -D NAME=value
                                ; (the core's options are in core/options.inc)
TEST_TIMING = 0                 ; 1 = border colour marks synth_tick's CPU time
TEST_PROFILE = 0                ; 1 = the longest run of each part of synth_tick, in cycles,
                                ; at PROFILE_MAX (tools/voice_check.py --profile)
TEST_ARP = 0                    ; Arpeggio parameter at start (tools/arp_check.py)
VIDEO_MARK = 0                  ; 1 = call video_frame once per video frame (engine.asm),
                                ; a breakpoint address for c64tools/vicerec.py
                                ; (demos/video_demo.py)
        .endweak

SYNTH_SCREEN = 1                ; the step screen owns the screen and keys (core hooks)
STATUS_ROW = 22                 ; the status row near the bottom, two help rows below
RASTER_SAFE = 1                 ; rows drawn out of the raster beam's way: no text flashes
MIDI_POLL_SCAN = 0              ; (not here: MIDI read between the scan's pieces too made the
                                ; heaviest cases fall 2-3 ticks behind: arp_check's controller
                                ; stream, dump_check, preset_check, seq_check; SID500
                                ; docs/latency.md)
PARAM_PAGE2 = 20                ; the parameter screen in two pages: the sound (Cutoff to
                                ; Click), playing and setup (LFO rate to Paddles; = P_LFORATE,
                                ; checked below)
PARAM_NAMES_LONG = 1            ; more than 21 parameters (core/screen.asm reads their names in two parts)
OMNI_SKIP_DRUMS = 1             ; in omni, notes on channel 10 (SID808's MIDI out) are ignored
MIDI_REALTIME = 1               ; MIDI clock, start, stop come to synth_realtime (core/sequencer.asm)
MIDI_OUT = 1                    ; MIDI output (core midi_send): the sequencer's notes and clock
SEQ_REALTIME_OWN = 1            ; synth_realtime is the arpeggiator's (src/arp.asm), passing the bytes on
MIDI_PROGRAM = 1                ; program change recalls a preset (src/presets.asm synth_program)
PARAM_SYNTH_KEYS = 1            ; the parameter screen's keys go to synth_param_key first (presets)
PATTERN_CC = 85                 ; controller 85 picks the pattern (core/sequencer.asm seq_pattern)
MIDI_SYSTEM = 1                 ; song position (src/arp.asm synth_song_position) and song select
MIDI_SYSEX = 1                  ; the song file and the preset bank as SysEx dumps (src/dumps.asm)
SYSEX_SYNTH = 3                 ; SID101's ID in them (SidSynth: 1 SID303, 2 SID808, 3 SID101)
KERNAL_ZP_COPY = $c500          ; start keeps the KERNAL's zero page here (disk.asm)

        .include "core/options.inc"
        .include "core/c64.inc"

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
; TICK_LATCH and the lookup tables come from tables.inc (included at the end)

STACK_SIZE      = 8             ; held-note stack depth
LOWEST_NOTE     = 12            ; MIDI note at freq table index 0 (C0)
HIGHEST_NOTE    = 107           ; MIDI note at freq table index 95 (B7)
TUNE_CENTER     = 16            ; TUNE parameter value for "in tune"

; SID registers the core's c64.inc doesn't name
SID_V2_AD       = $d40c
SID_V3_PW_LO    = $d410
SID_V3_PW_HI    = $d411
SID_V3_AD       = $d413

; SID control register bits
GATE            = %00000001
SYNC            = %00000010     ; voice 2: hard sync to voice 1
WAVE_PULSE      = %01000000
WAVE_SAW        = %00100000
WAVE_NOISE      = %10000000     ; (never with another waveform: it locks the noise up)
FILTER_ROUTING  = %111          ; $D417: all three voices through the filter
MODE_LOWPASS    = %00010000     ; $D418: low-pass

; envelopes (env_lo/env_hi, stepped by the core's env_decay)
ENV_ADSR        = 0             ; the ADSR envelope, $FFFF = full
ENV_WORK        = 1             ; scratch: the decay works on ENV_ADSR - sustain here
ENV_COUNT       = 2

; parameter indices (order = order on screen)
P_CUTOFF        = 0
P_RESO          = 1
P_ENVMOD        = 2
P_ATTACK        = 3             ; the envelope (filter; the amp has no attack: docs/plan.md)
P_DECAY         = 4
P_SUSTAIN       = 5
P_RELEASE       = 6
P_AMPMODE       = 7             ; 0 = the amp follows the envelope, 1 = gate (on/off)
P_VOICEMODE     = 8             ; VM_101 (saw, pulse, sub), VM_SYNC (voice 2 synced to voice 1),
                                ; VM_C64 (a pulse lead, its echo, the sub)
P_SAW           = 9             ; mixer: voice levels 0..15
P_PULSE         = 10            ; (Sync mode: the synced voice; C64 mode: the lead, and Saw its echo)
P_SUB           = 11
P_SUBTYPE       = 12            ; 0 = square 1 octave down, 1 = 2 down, 2 = 25 % pulse 2 down
P_PW            = 13            ; pulse width by hand: 0 = 50 % .. 15 = ~9 %
P_PWM           = 14            ; LFO to pulse width (C64 mode: the speed of its own sweep)
P_SYNCPITCH     = 15            ; Sync mode: the synced voice's pitch above the note, 0..255 = 0..48 semitones
P_SYNCENV       = 16            ; Sync mode: the envelope's sweep of it, 0..255 = up to 48 semitones
P_CHORD         = 17            ; C64 mode: the chord a single key plays (0 = off; CHORD_*)
P_CHORDSPEED    = 18            ; C64 mode: the chord's fast notes, 0..7 = 1..8 frames each
P_CLICK         = 19            ; C64 mode: the attack click, 0 off, then noise / saw / square
                                ; for 1..3 frames each (CLICK_*)
P_LFORATE       = 20            ; (the second page, Play, from here)
P_LFOSHAPE      = 21            ; 0 triangle, 1 square, 2 random (sample and hold), 3 noise
P_LFODELAY      = 22            ; the LFO's fade-in after a fresh note, 0 = none
P_VIBRATO       = 23            ; LFO to pitch
P_LFOCUT        = 24            ; LFO to cutoff
P_MODWHEEL      = 25            ; the mod wheel (CC 1), 0..255: adds vibrato depth
P_ACCENT        = 26            ; velocity to level and env mod, 0 = none
P_GLIDE         = 27            ; glide time
P_GLIDEMODE     = 28            ; 0 off, 1 on (every note), 2 auto (legato notes only)
P_ARP           = 29            ; the arpeggiator: 0 off, 1 up, 2 down, 3 up and down, 4 random
P_ARPRANGE      = 30            ; its range: 0..2 = 1..3 octaves
P_ARPRATE       = 31            ; its step: 0 = 1/8, 1 = 1/16, 2 = 1/32 note (at the sequencer's tempo)
P_TUNE          = 32
P_VOLUME        = 33
P_CHANNEL       = 34
P_MIDIIF        = 35
P_PADDLES       = 36
P_CLOCK         = 37            ; sequencer and arpeggiator clock: 0 internal, 1 MIDI
P_MIDIOUT       = 38            ; MIDI out: 0 off, 1 on (the sequencer's notes and clock)
P_DRIVE         = 39            ; disk drive: 0..8 = drive 8..16 (the last: disk tests wrap to it)
NUM_PARAMS      = 40
        .cerror PARAM_PAGE2 != P_LFORATE, "the second page starts at LFO rate"
FIRST_DRIVE     = 8             ; the Disk drive parameter: 0 = drive 8 ...
LAST_DRIVE      = 16            ; ... 8 = drive 16
PAD_DEFAULT_X   = P_CUTOFF      ; paddle X at start
PAD_DEFAULT_Y   = P_RESO        ; paddle Y at start

VM_101          = 0             ; P_VOICEMODE values
VM_SYNC         = 1
VM_C64          = 2
AMP_ENV         = 0             ; P_AMPMODE values
AMP_GATE        = 1
GLIDE_OFF       = 0             ; P_GLIDEMODE values
GLIDE_ON        = 1
GLIDE_AUTO      = 2
LFO_TRIANGLE    = 0             ; P_LFOSHAPE values
LFO_SQUARE      = 1
LFO_RANDOM      = 2
LFO_NOISE       = 3
ARP_OFF         = 0             ; P_ARP values
ARP_UP          = 1
ARP_DOWN        = 2
ARP_UPDOWN      = 3
ARP_RANDOM      = 4
ARP_RATE_8      = 0             ; P_ARPRATE values
ARP_RATE_16     = 1
ARP_RATE_32     = 2

        .include "core/framework.asm"

; -----------------------------------------------------------------------------
; synth_init - hook called once at start, after core init_vars: the note
; state, the test log, then the SID (falls through into sid_init).
; -----------------------------------------------------------------------------
synth_init
        jsr presets_init        ; first: the factory presets may lie where the test logs go
        jsr notes_init
        jsr engine_init
.if TEST_LOG
        jsr log_init            ; (clears $5000-$6FFF: before prof_clear)
.endif
.if TEST_PROFILE
        jsr prof_clear
.endif
        jsr seq_init            ; patterns, tempo (TEST_SEQ: starts playing)
        jsr arp_init            ; no keys held
        jsr steps_init          ; the step screen's key masks
        jsr undo_clear          ; nothing to undo yet
        jsr disk_init           ; the drive the program came from, the default name

; -----------------------------------------------------------------------------
; sid_init - clear the SID: every ADSR rate 0 (attack 2 ms, decay and
; release 6 ms). With every rate at 0 the SID envelope counter can never be
; above the new rate's period, which is what causes the ADSR delay bug, so
; retriggers always start instantly. The levels come from the sustain
; levels (levels_update).
; -----------------------------------------------------------------------------
sid_init
        lda #0
        ldx #$18
-       sta $d400,x
        dex
        bpl -
        rts

        .include "core/midi.asm"
        .include "core/params.asm"
        .include "src/notes.asm"
        .include "src/engine.asm"
        .include "core/sequencer.asm"
synth_pattern = seq_pattern     ; core hooks: CC 85, song select (song position: src/arp.asm)
synth_song_select = seq_song_select
        .include "src/arp.asm"
        .include "core/math.asm"
        .include "core/paddles.asm"
        .include "core/keyboard.asm"
        .include "src/keymap.asm"
        .include "src/hooks.asm"
        .include "core/screen.asm"
        .include "src/steps.asm"
        .include "src/undo.asm"
        .include "src/disk.asm"
        .include "src/presets.asm"
        .include "src/dumps.asm"
        .include "src/params.asm"
        .include "core/test_feed.asm"

; =============================================================================
; Generated tables (tables.py): frequencies, cutoff curve, envelope rates,
; glide, LFO rates, pulse widths, TICK_LATCH and the TEST_MIDI pattern
; =============================================================================
        .include "tables.inc"

        .include "core/test_keys.asm"
        .include "src/test_scripts.asm"
code_end

; the factory presets (tables.py), last: presets_init copies them to
; PRESET_RAM before anything else runs, so the test logs may overwrite
; them afterwards
        .include "presets.inc"
.if TEST_SYSEX & TSX_FEED
test_sysex_data .binary "test_sysex.bin" ; (tools/dump_check.py: copied to $F000 at start)
.endif

program_end
        .cerror program_end > UNDO_RAM, "program runs into the undo pages"
.if TEST_LOG
        .cerror code_end > LOG_FIRST, "program runs into the test logs (src/notes.asm LOG_FIRST)"
.endif
