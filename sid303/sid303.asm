; =============================================================================
; SID303 - monophonic TB-303 style acid bass for the C64 with an 8580 SID
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
; This program is free software under the GNU General Public License,
; version 3 or (at your option) any later version; see LICENSE.
;
;   * MIDI in through a 6850 ACIA cartridge (Sequential, Passport, Datel,
;     Namesoft), any channel or omni, running status; MIDI clock drives the
;     step sequencer (Clock on MIDI), and MIDI out sends its notes and clock
;   * the C64 keyboard plays notes (tracker layout, two octaves)
;   * paddles: X = filter cutoff, Y = resonance at start, or any parameter
;     by learn (RETURN, then turn a paddle); soft takeover
;   * function keys select and change parameters; F7 switches to the step
;     sequencer's screen (docs/sequencer.md; the sequencer is the core's)
;
; Sound model (what a 303 does and how it is faked on the SID):
;   oscillator  saw or square (pulse) on voice 1
;   VCF         8580 12 dB low-pass, cutoff on a log scale (tables.inc)
;   filter env  exponential decay, retriggered on every non-slid note,
;               software-run at 250 Hz so fast decays don't zipper
;   accent      louder attack that falls back to the normal level (SID sustain
;               level), short decay, extra cutoff kick that builds up over
;               consecutive accents ("accent sweep"), more so at high resonance
;   slide       overlapping (legato) notes glide with an RC-style curve and
;               do not retrigger the envelopes
;   VCA         SID ADSR with every rate at 0: instant gate, no ADSR delay bug;
;               a software amplitude envelope lowers the sustain level so held
;               notes fade like a 303's
;   303 square  voice 2 pulse hard-synced to voice 1, voice 1 saw under it:
;               the saw slants the pulse's flat parts, like the 303 square's
;               slanted top (adds even harmonics); BLEND = slant amount
;   body        voice 3 triangle on the fundamental, unfiltered (BODY level),
;               turned down at high resonance as the 303 loses bass there
;
; Build: see build.sh (python tables.py; 64tass ...). PAL timing.
; Memory: BASIC and KERNAL ROMs are banked out ($01 = $35); we own the
; hardware IRQ/NMI vectors at $FFFE/$FFFA.
; =============================================================================

        .cpu "6502"

        .weak                   ; sound defaults, overridable with 64tass -D NAME=value
                                ; (the core's options are in core/options.inc)
WAVE_DEFAULT = 0                ; waveform at start (0 saw, 1 square, 2 saw+square, 3 303 square)
AMPDECAY_DEFAULT = 9            ; amp decay at start (15 = no fade)
BLEND_DEFAULT = 6               ; 303 square slant at start
BODY_DEFAULT = 0                ; body level at start
RESO_DEFAULT = 12               ; resonance at start
FILTER_DEFAULT = 0              ; filter mode at start (0 low, 1 low+band, 2 band, 3 high)
ENVMOD_DEFAULT = 160            ; filter env depth at start (0..255)
DECAY_DEFAULT = 6               ; filter env decay at start (0..15)
ACCENT_DEFAULT = 10             ; accent strength at start (0..15)
ENVTYPE_DEFAULT = 1             ; env mod type at start: 0 up only, 1 centred (303)
ENV_PIVOT = 140                 ; centred env mod: the sweep pivots at filter env
                                ; level ENV_PIVOT/255 (303: (3-0.5)/(5-0.5) = 0.55)
TEST_TIMING = 0                 ; 1 = border colour marks synth_tick's CPU time
VIDEO_MARK = 0                  ; 1 = call video_frame once per video frame (engine.asm),
                                ; a breakpoint address for c64tools/vicerec.py
                                ; (tools/seq_check.py reads it in VICE)
FILTER_ROUTING = %011           ; $D417 voices through the filter: 1 and 2 (0 = test: raw waveforms)
        .endweak


SYNTH_SCREEN = 1                ; the step screen owns the screen and keys (core hooks)
STATUS_ROW = 22                 ; the status row near the bottom, two help rows below
RASTER_SAFE = 1                 ; rows drawn out of the raster beam's way: no text flashes
MIDI_POLL_SCAN = 1              ; MIDI read between the main loop's scan pieces too: a note waits
                                ; less (SID500 docs/latency.md, tools/synth_latency.py)
PARAM_PAGE2 = 15                ; the parameter screen in two pages: the sound (Cutoff to Volume),
                                ; the setup (MIDI channel to Disk drive; = P_CHANNEL, checked below)
OMNI_SKIP_DRUMS = 1             ; in omni, notes on channel 10 (SID808's MIDI out) are ignored
MIDI_REALTIME = 1               ; MIDI clock, start, stop come to synth_realtime (core/sequencer.asm)
MIDI_OUT = 1                    ; MIDI output (core midi_send): the sequencer's notes and clock
PATTERN_CC = 85                 ; controller 85 picks the pattern (core/sequencer.asm seq_pattern)
MIDI_SYSTEM = 1                 ; song position and song select (seq_song_position, seq_song_select)
MIDI_SYSEX = 1                  ; the song file and the preset bank as SysEx dumps (src/dumps.asm)
MIDI_PROGRAM = 1                ; program change recalls a preset (src/presets.asm synth_program)
PARAM_SYNTH_KEYS = 1            ; the parameter screen's keys go to synth_param_key first (presets)
SYSEX_SYNTH = 1                 ; SID303's ID in it (SidSynth: 1 SID303, 2 SID808, 3 SID101)
KERNAL_ZP_COPY = $c500          ; start keeps the KERNAL's zero page here (disk.asm)

        .include "core/options.inc"
        .include "core/c64.inc"

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
; TICK_LATCH and the lookup tables come from tables.inc (included at the end)

STACK_SIZE      = 8             ; held-note stack depth
ACCENT_VELOCITY = 110           ; MIDI velocity >= this plays an accented note
LOWEST_NOTE     = 12            ; MIDI note at freq table index 0 (C0)
HIGHEST_NOTE    = 107           ; MIDI note at freq table index 95 (B7)
TUNE_CENTER     = 16            ; TUNE parameter value for "in tune"

ENV_FILTER      = 0             ; index into env_lo/env_hi: filter envelope
ENV_ACCENT      = 1             ;                            accent envelope
ENV_AMP         = 2             ;                            amplitude (VCA) envelope
ENV_COUNT       = 3
AMP_HOLD        = 15            ; AMP DECAY value: no fade

WAVE_303SQ      = 3             ; WAVE value: synced pulse (voice 2) + saw (voice 1)
WAVE_COUNT      = 4
V2_PULSE_SYNC   = %01000010     ; voice 2 control: pulse, hard sync to voice 1
V3_TRIANGLE     = %00010000     ; voice 3 control: triangle

GATE            = %00000001     ; SID control register gate bit

; parameter indices (order = order on screen)
P_CUTOFF        = 0
P_RESO          = 1
P_ENVMOD        = 2
P_ENVTYPE       = 3             ; 0 = env mod opens the filter up only, 1 = centred (303)
P_DECAY         = 4
P_ACCENT        = 5
P_SLIDE         = 6
P_AMPDECAY      = 7
P_WAVE          = 8
P_PW            = 9
P_BLEND         = 10
P_BODY          = 11
P_TUNE          = 12
P_FILTER        = 13
P_VOLUME        = 14
P_CHANNEL       = 15
P_MIDIIF        = 16
P_PADDLES       = 17
P_CLOCK         = 18            ; sequencer clock: 0 internal, 1 MIDI
P_MIDIOUT       = 19            ; MIDI out: 0 off, 1 on (the sequencer's notes and clock)
P_DRIVE         = 20            ; disk drive: 0..8 = drive 8..16
NUM_PARAMS      = 21
        .cerror PARAM_PAGE2 != P_CHANNEL, "the setup page starts at MIDI channel"
FIRST_DRIVE     = 8             ; the Disk drive parameter: 0 = drive 8 ...
LAST_DRIVE      = 16            ; ... 8 = drive 16
PAD_DEFAULT_X   = P_CUTOFF      ; paddle X at start
PAD_DEFAULT_Y   = P_RESO        ; paddle Y at start

        .include "core/framework.asm"

; -----------------------------------------------------------------------------
; synth_init - hook called once at start, after core init_vars: empty the
; held-note stack, then set up the SID (falls through into sid_init).
; -----------------------------------------------------------------------------
synth_init
        jsr presets_init        ; first: the factory presets may lie where the test logs go
        lda #0
        ldx #STACK_SIZE-1
-       sta note_stack,x
        dex
        bpl -
.if TEST_LOG
        lda #<NOTE_LOG          ; the note log starts empty, cleared (an entry
        sta log_ptr             ; of zeros marks its end for tools/seq_check.py)
        lda #>NOTE_LOG
        sta log_ptr+1
        lda #<OUT_LOG           ; the out log too (both areas: $5000-$6FFF)
        sta out_log_ptr
        lda #>OUT_LOG
        sta out_log_ptr+1
        sta log_ptr+1
        lda #0
        sta LOG_LAG
        tay
-       sta (log_ptr),y
        iny
        bne -
        inc log_ptr+1
        ldx log_ptr+1
        cpx #>NOTE_LOG_END
        bne -
        lda #>NOTE_LOG
        sta log_ptr+1
        lda #0                  ; (LOG_LAG at $5FFF was cleared with the rest)
        sta LOG_LAG
.endif
        jsr seq_init            ; patterns, tempo (TEST_SEQ: starts playing)
        jsr steps_init          ; the step screen's key masks
        jsr undo_clear          ; nothing to undo yet
        jsr disk_init           ; the drive the program came from, the default name

; -----------------------------------------------------------------------------
; sid_init - clear the SID and set voice 1's fixed envelope rates.
; ADSR: attack 0, decay 0, release 0. With every rate at 0 the SID envelope
; counter can never be above the new rate's period, which is what causes the
; infamous ADSR delay bug, so rapid retriggers always start instantly.
; -----------------------------------------------------------------------------
sid_init
        lda #0
        ldx #$18
-       sta $d400,x
        dex
        bpl -
        lda #$00                ; attack 0 (2 ms), decay 0
        sta SID_V1_AD
        lda #$f0                ; sustain full, release 0 (6 ms)
        sta SID_V1_SR
        rts

        .include "core/midi.asm"
        .include "core/params.asm"
        .include "src/notes.asm"
        .include "src/engine.asm"
        .include "core/sequencer.asm"
synth_pattern = seq_pattern     ; core hooks: CC 85, song position, song select
synth_song_position = seq_song_position
synth_song_select = seq_song_select
        .include "core/math.asm"
        .include "core/paddles.asm"
        .include "core/keyboard.asm"
        .include "src/keymap.asm"
        .include "src/hooks.asm"
        .include "core/screen.asm"
        .include "src/steps.asm"
        .include "src/undo.asm"
        .include "src/disk.asm"
        .include "src/dumps.asm"
        .include "src/presets.asm"
        .include "src/params.asm"
        .include "core/test_feed.asm"

; =============================================================================
; Generated tables (tables.py): frequencies, cutoff curve, envelope factors,
; TICK_LATCH and the TEST_MIDI pattern
; =============================================================================
        .include "tables.inc"

        .include "core/test_keys.asm"
        .include "src/test_scripts.asm"

.if TEST_LOG
        .cerror * > OUT_LOG, "program runs into the test logs (src/notes.asm OUT_LOG)"
.endif
; the factory presets (tables.py), after the code: presets_init copies them
; to PRESET_RAM before anything else runs, so the test logs may overwrite
; them afterwards; likewise a test feed (sysex_init copies it away first)
        .include "presets.inc"
.if TEST_SYSEX & TSX_FEED
test_sysex_data .binary "test_sysex.bin" ; (tools/dump_check.py: copied to $F000 at start)
.endif
program_end
        .cerror program_end > rx_buffer, "program runs into the buffers at $C000"
