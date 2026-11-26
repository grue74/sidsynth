; =============================================================================
; SID808 - TR-808 style drum machine for the C64 with an 8580 SID
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
; This program is free software under the GNU General Public License,
; version 3 or (at your option) any later version; see LICENSE.
;
;   * drums played from MIDI (General MIDI drum notes, velocity = accent)
;     and from the C64 keyboard (Z = kick at the default octave)
;   * three SID voices shared by all sounds: dynamic allocation with choke
;     groups (closed hat chokes open hat), the quietest voice is stolen
;   * each sound is a step program (tables.py): waveform, pitch glide,
;     software level with exponential decay, filter
;
; Design: docs/design.md. Build: build.sh. PAL timing, 500 Hz engine tick.
; Memory: BASIC and KERNAL ROMs are banked out ($01 = $35); we own the
; hardware IRQ/NMI vectors at $FFFE/$FFFA.
; =============================================================================

        .cpu "6502"

TICK_HZ = 500                   ; engine tick rate; overrides the core's weak 250
MIDI_POLL_SCAN = 1              ; MIDI read between the main loop's scan pieces too: a note waits
                                ; less (SID500 docs/latency.md, tools/synth_latency.py)
SYNTH_SCREEN = 1                ; the step grid owns the screen and keys (core hooks)
MIDI_REALTIME = 1               ; MIDI clock, start, stop come to synth_realtime (sequencer.asm)
MIDI_OUT = 1                    ; MIDI output (core midi_send): the sequencer's clock and notes
PATTERN_CC = 85                 ; controller 85 picks the pattern (sequencer.asm seq_pattern)
MIDI_SYSTEM = 1                 ; song position and song select (seq_song_position, seq_song_select)
MIDI_SYSEX = DUMPS              ; the song file as a SysEx dump (src/dumps.asm)
SYSEX_SYNTH = 2                 ; SID808's ID in it (SidSynth: 1 SID303, 2 SID808, 3 SID101)
SYSEX_RAM = $c800               ; a received dump (13.5 KB) is staged at $C800-$FEFF, under
SYSEX_MAX = $3700               ; the I/O chips too (the KERNAL's RAM alone is 8 KB)
SYSEX_UNDER_IO = 1
KERNAL_ZP_COPY = $c500          ; start keeps the KERNAL's zero page here (disk.asm)
                                ; (tables.py's TICK_HZ must match; the core checks)

        .weak                   ; SID808 build options, overridable with 64tass -D NAME=value
DUMPS = 1                       ; 1 = SysEx dumps (MIDI_SYSEX); the demos that play by themselves
                                ; leave them out (build.sh): with them six don't fit on the disk
TEST_DUMP_VERSION = 0           ; tests: a dump sent says this file version (1, 2, 4) and holds
                                ; what that version holds (tools/dump_check.py)
TEST_TIMING = 0                 ; 1 = border colour marks synth_tick's CPU time
MUTE_SETTLE = 1                 ; 1 = hold the waveform until the envelope settles at
                                ; the hit's level (soft hits stay soft); 0 = 1 tick only
TEST_CPU = 0                    ; 1 = measure synth_tick while playing (engine.asm cpu_end):
                                ; longest in cycles, most ticks behind, ticks over a tick
                                ; period, ticks measured; read them in VICE's monitor
VIDEO_MARK = 0                  ; 1 = call video_frame once per video frame (engine.asm),
                                ; a breakpoint address for c64tools/vicerec.py
V_MAJOR = 0                     ; version (build.sh, from VERSION): shown in the title row
V_MINOR = 0                     ; with the build number
V_PATCH = 0
TEST_NMI = 0                    ; n > 0 = an NMI every n cycles (CIA2 timer A), each
                                ; taking about as long as a MIDI byte's: tests that the
                                ; oscillator park (voices.asm osc_park) survives them
        .endweak

        .include "core/options.inc"
        .include "core/c64.inc"

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
; TICK_LATCH, the sound programs and lookup tables come from tables.inc
; (included at the end)

NUM_VOICES      = 3
VOICE_IDLE      = $ff           ; v_sound: no sound playing

; SID control register bits
GATE            = %00000001
TEST_BIT        = %00001000

VIC_RASTER      = $d012         ; current raster line, bits 0-7 (osc_park)
RASTER_BIT8     = %10000000     ; VIC_CTRL1 ($D011) bit 7: raster line bit 8

; parameter indices (order = order on screen)
; (MIDI controllers and paddles can be learnt to the ones before LEARN_LIMIT)
P_VOLUME        = 0
P_LEVEL         = 1             ; the selected sound's knobs (knobs.asm): Level 0..15,
P_TUNE          = 2             ; Tune -12..+12 semitones,
P_DECAY         = 3             ; Decay 0..15,
P_TONE          = 4             ; Tone 0..15
P_SOUND         = 5             ; the sound the page shows (= the grid's cursor row)
P_CHANNEL       = 6
P_MIDIIF        = 7
P_PADDLES       = 8
P_CLOCK         = 9             ; sequencer clock: 0 internal, 1 MIDI
P_MIDIOUT       = 10            ; MIDI out: 0 off, 1 on (clock and notes)
P_DRIVE         = 11            ; disk drive: 0..8 = drive 8..16 (disk.asm)
NUM_PARAMS      = 12
PAD_DEFAULT_X   = P_VOLUME      ; paddles at start (paddles are Off by default)
PAD_DEFAULT_Y   = P_VOLUME

; one envelope per voice, the voice's level (level_decay; the core's env_decay is unused)
ENV_COUNT       = NUM_VOICES

        .include "core/framework.asm"

; -----------------------------------------------------------------------------
; synth_init - hook called once at start, after core init_vars: every voice
; idle, SID cleared.
; -----------------------------------------------------------------------------
synth_init
        lda #VOICE_IDLE
        ldx #NUM_VOICES-1
-       sta v_sound,x
        sta v_partner,x         ; ($FF = NO_PARTNER too)
        dex
        bpl -
        sta filter_owner
        lda #0                  ; level_decay's table pointers: rate pages,
        sta dlo_ptr             ; low bytes 0 (the high bytes are set per use)
        sta dhi_ptr
        sta score_ptr           ; voice_pick's score page pointer, likewise
        lda #RNG_SEED
        sta rng
        lda #0
        sta load_warn           ; no CPU warning (RAM: junk at power-on)
        sta load_slip
        jsr undo_clear          ; nothing to undo yet
        jsr disk_init           ; the default file name
        jsr knob_init           ; every sound's knobs at the defaults
        jsr seq_init            ; patterns, tempo (TEST_SEQ: starts playing)
        jsr grid_take           ; start on the step grid (drawn by the first draw step)

        ; clear the SID; every ADSR rate stays 0 (no ADSR delay bug, see
        ; docs/design.md 5), so only sustain levels are written from now on
        lda #0
        ldx #$18
-       sta SID_V1_FREQ_LO,x
        dex
        bpl -
.if TEST_NMI
        ; NMIs from CIA2 timer A, our handler on the vector (the interface's
        ; NMIs are never on: the test interface is the built-in feeder)
        lda #<test_nmi
        sta VEC_NMI
        lda #>test_nmi
        sta VEC_NMI+1
        lda #<(TEST_NMI-1)
        sta CIA2_TA_LO
        lda #>(TEST_NMI-1)
        sta CIA2_TA_HI
        lda #%00010001          ; force latch load, start, continuous mode
        sta CIA2_CRA
        lda #%10000001          ; enable the timer A interrupt (NMI)
        sta CIA2_ICR
.endif
        jmp mode_vol_write

.if TEST_NMI
CIA2_TA_LO      = $dd04
CIA2_TA_HI      = $dd05
CIA2_CRA        = $dd0e
; test_nmi - TEST_NMI: acknowledge CIA2 and take about as long as the core's
; nmi_handler with a MIDI byte (~45 cycles with the NMI's own 7)
test_nmi
        pha
        lda CIA2_ICR            ; acknowledge (the NMI line goes high again)
        .rept 10
        nop
        .endrept
        pla
        rti
.endif

        .include "core/midi.asm"
        .include "core/params.asm"
        .include "src/engine.asm"
        .include "src/voices.asm"
        .include "src/sequencer.asm"
synth_pattern = seq_pattern     ; core hooks: CC 85, song position, song select
synth_song_position = seq_song_position
synth_song_select = seq_song_select
        .include "core/math.asm"
        .include "core/paddles.asm"
        .include "core/keyboard.asm"
        .include "src/keymap.asm"
        .include "src/hooks.asm"
        .include "core/screen.asm"
        .include "src/grid.asm"
        .include "src/undo.asm"
        .include "src/disk.asm"
        .include "src/knobs.asm"
.if MIDI_SYSEX
        .include "src/dumps.asm"
.else
k_dump  jmp key_done            ; (D on the grid: no dumps in this build)
.endif
        .include "src/params.asm"
        .include "core/test_feed.asm"

; =============================================================================
; Generated tables (tables.py): sound programs, note map, decay factors,
; filter settings, mute times, TICK_LATCH and the TEST_MIDI pattern
; =============================================================================
        .include "tables.inc"

        .include "core/test_keys.asm"
        .include "src/test_scripts.asm"

.if MIDI_SYSEX && (TEST_SYSEX & TSX_FEED)
test_sysex_data .binary "test_sysex.bin" ; (tools/dump_check.py: copied to $F000 at start)
.endif
program_end
        .cerror program_end > rx_buffer, "program runs into the buffers at $C000"
        .cerror program_end > PATTERN_RAM, "program runs into the pattern memory at $8000"
        .cerror program_end > UNDO_RAM, "program runs into the undo pages (undo.asm: fewer UNDO_STEPS for this build)"
