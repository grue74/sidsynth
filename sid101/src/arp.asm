; arp.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The arpeggiator. With the Arpeggio parameter on, the notes played (MIDI
; and the C64 keyboard: the core's note_on / note_off) are held in a list
; sorted by pitch, and the arpeggiator plays them one at a time through the
; voice (voice_note_on / voice_note_off in notes.asm), each a fresh note
; with its gate open for half a step:
;   Up          the held notes upwards, then again an octave up per range
;               octave, then from the bottom again
;   Down        the same downwards
;   Up & down   up, then down, the top and the bottom notes played once
;   Random      a random one of the same notes each step
; The range is 1 to 3 octaves; a step is a 1/8, 1/16 or 1/32 note at the
; sequencer's tempo (internal clock: the first note sounds at once, when
; the first key goes down), or 12, 6 or 3 MIDI clocks (Clock on MIDI: the
; steps keep to the clocks counted since MIDI start, so the first note
; waits for the next step). The velocity is the newest key's.
;
; The sequencer's notes don't go through the arpeggiator: synth_tick sets
; in_seq while seq_tick runs, and a note off for a note the list doesn't
; hold goes to the voice (a note held before the arpeggiator went on, the
; sequencer's note when it stops). Notes to the voice are logged there
; (TEST_LOG: log_note in voice_note_on / voice_note_off), so with the
; arpeggiator on the log has what it plays (tools/arp_check.py).

; the arpeggiator's state, in the synth's RAM area after note_stack,
; audition_bits and arp_held (zero page is full; none of it is needed there)
        .virtual $c158
arp_count       .byte ?         ; keys held in arp_held
arp_on          .byte ?         ; the Arpeggio parameter was on (P_ARP changes)
arp_first       .byte ?         ; nonzero: the next step plays the pattern's first note
arp_pos         .byte ?         ; the step's place in the pattern, 0..arp_period-1
arp_period      .byte ?         ; arp_step: steps in the pattern
arp_span        .byte ?         ; arp_step: notes in the range, keys x octaves
arp_note        .byte ?         ; the note the arpeggiator has sounding, NO_NOTE = none
arp_vel         .byte ?         ; the newest key's velocity
arp_last        .byte ?         ; the newest key
arp_phase       .word ?         ; internal clock: a step is due when it passes 65536
arp_inc         .word ?         ; internal clock: its increment per tick (arp_set_inc)
arp_clocks      .byte ?         ; MIDI clock: clocks since the last step ($FF: since start)
arp_due         .byte ?         ; MIDI clock: nonzero = a step is due (arp_realtime sets it)
arp_gate_due    .byte ?         ; MIDI clock: nonzero = the gate closes
arp_rng         .byte ?         ; Random: its own sequence (not the LFO's: the order of
                                ; the notes must not depend on the LFO)
in_seq          .byte ?         ; nonzero while seq_tick runs: its notes go to the voice
arp_state_end
        .endv
        .cerror arp_state_end > $c200, "the arpeggiator's state runs into cc_map"

; the held keys, in the synth's RAM area after note_stack and audition_bits
arp_held        = $c150         ; ARP_MAX bytes: MIDI notes, sorted upwards
ARP_MAX         = 8             ; keys held at most (more are not played)
        .cerror arp_held + ARP_MAX > $c158, "arp_held runs into the arpeggiator's state"
ARP_RNG_SEED    = $5d           ; the random sequence's start (tools/arp_check.py's model)

; -----------------------------------------------------------------------------
; arp_init - no keys held, nothing sounding, the random sequence from its
; start. clobbers A
; -----------------------------------------------------------------------------
arp_init
        lda #0
        sta arp_count
        sta arp_first
        sta arp_pos
        sta arp_clocks
        sta arp_due
        sta arp_gate_due
        sta in_seq
        lda params+P_ARP
        sta arp_on
        lda #NO_NOTE
        sta arp_note
        lda #ARP_RNG_SEED
        sta arp_rng
        rts

; =============================================================================
; Notes in
; =============================================================================

; -----------------------------------------------------------------------------
; note_on - core hook: a note played (MIDI, the C64 keyboard) or the
; sequencer's step. To the arpeggiator when it is on (but not the
; sequencer's), else to the voice.
; A: MIDI note, X: velocity (1..127). clobbers A, X, Y
; -----------------------------------------------------------------------------
note_on
        ldy params+P_ARP
        beq +
        ldy in_seq
        bne +
        jmp arp_key_on
+       jmp voice_note_on

; -----------------------------------------------------------------------------
; note_off - core hook: a note let go. The arpeggiator's if it holds the
; note, else the voice's.
; A: MIDI note. clobbers A, X, Y
; -----------------------------------------------------------------------------
note_off
        ldy params+P_ARP
        beq +
        ldy in_seq
        bne +
        jmp arp_key_off
+       jmp voice_note_off

; -----------------------------------------------------------------------------
; arp_key_on - a key goes down with the arpeggiator on: into the sorted
; list (once only; with ARP_MAX held it is not added). The first key
; starts the pattern from its first note.
; A: MIDI note, X: velocity. clobbers A, X, Y, tmp
; -----------------------------------------------------------------------------
arp_key_on
        stx arp_vel
        sta arp_last
        jsr arp_remove          ; (a second note on for a held key: moved, not doubled)
        ldx arp_count
        cpx #ARP_MAX
        bcs _done               ; full

        ; insert sorted: the notes above it move up one place
        sta tmp
_shift  cpx #0
        beq _place
        lda tmp
        cmp arp_held-1,x
        bcs _place              ; the one below is not higher: here
        lda arp_held-1,x
        sta arp_held,x
        dex
        bne _shift
_place  lda tmp
        sta arp_held,x
        inc arp_count

        ; the first key: the pattern from its start; MIDI clock: nothing
        ; made due before it, so it waits for the next step; internal
        ; clock: the phase one increment short of a step, so the next
        ; tick steps
        lda arp_count
        cmp #1
        bne _done
        sta arp_first
        lda #0
        sta arp_due
        sta arp_gate_due
        jsr arp_set_inc
        sec
        lda #0
        sbc arp_inc
        sta arp_phase
        lda #0
        sbc arp_inc+1
        sta arp_phase+1
_done   rts

; -----------------------------------------------------------------------------
; arp_key_off - a key let go with the arpeggiator on: out of the list (a
; note the list doesn't hold goes to the voice). The last key up silences
; the arpeggiator's note at once.
; A: MIDI note. clobbers A, X, Y
; -----------------------------------------------------------------------------
arp_key_off
        jsr arp_remove
        bcs +
        jmp voice_note_off      ; not one of the arpeggiator's keys
+       lda arp_count
        bne +
        jmp arp_note_off
+       rts

; -----------------------------------------------------------------------------
; arp_remove - remove note A from arp_held if it is there. Carry set if it
; was. Preserves A; clobbers X, Y.
; -----------------------------------------------------------------------------
arp_remove
        ldx arp_count
        beq _absent
_find   dex
        cmp arp_held,x
        beq _found
        cpx #0
        bne _find
_absent clc
        rts

        ; found at X: the ones above move down a place
_found  pha
        dec arp_count
-       cpx arp_count
        bcs _closed
        lda arp_held+1,x
        sta arp_held,x
        inx
        bne -
_closed pla
        sec
        rts

; -----------------------------------------------------------------------------
; arp_note_off - the arpeggiator's note, if one sounds, off in the voice.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
arp_note_off
        lda arp_note
        cmp #NO_NOTE
        beq +
        ldx #NO_NOTE
        stx arp_note
        jmp voice_note_off
+       rts

; =============================================================================
; On and off
; =============================================================================

; -----------------------------------------------------------------------------
; arp_param_changed - the Arpeggio parameter changed (synth_param_changed).
; Turned on: the notes the voice holds become the arpeggiator's keys (not
; while the sequencer plays: the voice may hold its step). Turned off: the
; arpeggiator stops and the newest key it held sounds on in the voice (or,
; if that one was let go, the highest). From one pattern to another: the
; pattern goes on from where it is (arp_step keeps the place in range).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
arp_param_changed
        ldx #0
        lda params+P_ARP
        beq +
        inx
+       cpx arp_on
        beq _done               ; on stayed on, or off stayed off
        stx arp_on
        txa
        beq _off

        ; on: take over the voice's held notes, the voice let go
        lda seq_play
        bne _done
        lda #0                  ; from the oldest: the newest ends as arp_last
        sta tmp2
-       ldx tmp2
        cpx note_count
        bcs +
        lda note_stack,x
        ldx last_vel
        jsr arp_key_on
        inc tmp2
        bne -                   ; always
+       lda #0
        sta note_count
        jmp note_release

        ; off: the arpeggiator's note off; a held key to the voice
_off    jsr arp_note_off
        lda arp_count
        beq _done
        lda arp_last
        jsr arp_remove
        bcs +
        ldx arp_count           ; let go already: the highest held
        lda arp_held-1,x
+       ldx #0
        stx arp_count
        ldx arp_vel
        jmp voice_note_on
_done   rts

; -----------------------------------------------------------------------------
; arp_forget - all notes off: no keys, nothing sounding (the voice's gates
; are closed by all_notes_off). clobbers A
; -----------------------------------------------------------------------------
arp_forget
        lda #0
        sta arp_count
        lda #NO_NOTE
        sta arp_note
        rts

; =============================================================================
; Timing
; =============================================================================

; -----------------------------------------------------------------------------
; arp_tick - from synth_tick, before the sound engine: the steps and the
; gates. Internal clock: the phase grows by arp_inc, a step when it passes
; 65536, the gate closes when it passes 32768. MIDI clock: what
; arp_realtime made due. Nothing without keys held (the arpeggiator off
; holds none). It runs every tick, so it is kept short: what changes
; only with the tempo or the rate is worked out once a step (arp_set_inc).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
arp_tick
        lda arp_count
        beq _done               ; off, or no keys
        lda params+P_CLOCK
        bne _midi
        clc
        lda arp_phase
        adc arp_inc
        sta arp_phase
        lda arp_phase+1
        adc arp_inc+1
        sta arp_phase+1
        bcs arp_step            ; passed 65536: the next step
        bpl _done               ; the first half of the step
        jmp arp_note_off        ; the second half: the gate closed

        ; MIDI clock: the gate, then the step
_midi   lda arp_gate_due
        beq +
        lda #0
        sta arp_gate_due
        jsr arp_note_off
+       lda arp_due
        beq _done
        lda #0
        sta arp_due
        jmp arp_step
_done   rts

; -----------------------------------------------------------------------------
; arp_step - a step: the last note off, the next one on. The pattern runs
; over arp_span = keys x octaves notes (index i: key i mod keys, octave
; i / keys). Up: i = the place; Down: span-1 - place; Up & down: up to the
; top, then down (period 2 x span - 2, at least 1); Random: i = a random
; byte x span / 256. The place advances by one and wraps at the period
; (also when the keys or the range changed under it: from the start).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
arp_step
        jsr arp_note_off
        lda arp_count
        bne +
        rts                     ; no keys
+       jsr arp_set_inc         ; the next step's length: tempo and rate as now
        ; span = keys x octaves (at most 8 x 3)
        lda #0
        ldx params+P_ARPRANGE   ; 0..2: 1..3 octaves
-       clc
        adc arp_count
        dex
        bpl -
        sta arp_span

        ; period: up and down plays both ends once
        ldx params+P_ARP
        cpx #ARP_UPDOWN
        bne _period
        asl
        sec
        sbc #2
        bne _period
        lda #1                  ; one note: period 1
_period sta arp_period

        ; the place: the first note, or the next one (wrapping at the period)
        ldx #0
        lda arp_first
        bne _first
        ldx arp_pos
        inx
        cpx arp_period
        bcc _first
        ldx #0
_first  stx arp_pos
        lda #0
        sta arp_first

        ; the index in the span from the place and the mode
        lda params+P_ARP
        cmp #ARP_DOWN
        beq _down
        cmp #ARP_UPDOWN
        beq _updown
        cmp #ARP_RANDOM
        beq _random
        lda arp_pos             ; up
        jmp _index
_down   lda arp_span
        clc
        sbc arp_pos             ; span - 1 - place
        jmp _index
_updown lda arp_pos
        cmp arp_span
        bcc _index              ; going up
        lda arp_period          ; going down: 2 x span - 2 - place
        sec
        sbc arp_pos
        jmp _index
_random jsr arp_random
        ldx arp_span
        jsr mul8                ; A = random x span / 256

        ; the note: key (index mod keys) + 12 x (index / keys)
_index  ldy #0
-       cmp arp_count
        bcc +
        sbc arp_count           ; (carry set)
        tax
        tya
        adc #12-1               ; (carry still set: + 12)
        tay
        txa
        jmp -
+       tax
        tya
        clc
        adc arp_held,x
        sta arp_note
        ldx arp_vel
        jmp voice_note_on

; -----------------------------------------------------------------------------
; arp_set_inc - arp_inc = the sequencer's step increment (a 1/16 at its
; tempo) x 1/2 for 1/8 notes, x 1, or x 2 for 1/32.
; clobbers A, X
; -----------------------------------------------------------------------------
arp_set_inc
        lda seq_inc
        sta arp_inc
        lda seq_inc+1
        ldx params+P_ARPRATE
        cpx #ARP_RATE_16
        beq _store
        bcs _double
        lsr                     ; 1/8: half
        ror arp_inc
        jmp _store
_double asl arp_inc             ; 1/32: twice
        rol
_store  sta arp_inc+1
        rts

; -----------------------------------------------------------------------------
; arp_random - the next random byte: r = 5 r + 1 (mod 256), a full period
; of 256: the Random order repeats after 256 steps (30 s at 1/16, 125
; BPM). Its low bits repeat quickly, but arp_step uses only the high ones
; (r x span / 256). The cheapest generator for the tick that also plays
; the note. Out: A. clobbers nothing else
; -----------------------------------------------------------------------------
arp_random
        lda arp_rng
        asl
        asl
        sec                     ; + 1
        adc arp_rng             ; 4 r + r + 1
        sta arp_rng
        rts

; -----------------------------------------------------------------------------
; synth_realtime - core hook (MIDI_REALTIME, SEQ_REALTIME_OWN): a MIDI
; realtime byte, from the main loop: the arpeggiator's count, then the
; sequencer's handler.
; A: the byte. clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_realtime
        pha
        jsr arp_realtime
        pla
        jmp seq_realtime

; -----------------------------------------------------------------------------
; arp_realtime - with the Clock on MIDI: start makes the next clock a step
; (the pattern from its first note); each clock counts, the step's half
; (arp_gate_half) closes the gate, its length (arp_clocks_per) makes the
; next step due. Only sets state: arp_tick plays (with keys held; the
; first key clears what was made due before it).
; A: the byte. clobbers A, X
; -----------------------------------------------------------------------------
arp_realtime
        ldx params+P_CLOCK
        beq _done               ; internal clock: not ours
        cmp #MIDI_START
        bne +
        lda #$ff                ; the next clock: a step
        sta arp_clocks
        lda #1
        sta arp_first
        rts
+       cmp #MIDI_CLOCK
        bne _done
        inc arp_clocks
        beq _step               ; the first clock after start
        ldx params+P_ARPRATE
        lda arp_clocks
        cmp arp_gate_half,x
        bne +
        lda #1
        sta arp_gate_due
        lda arp_clocks
+       cmp arp_clocks_per,x
        bcc _done
_step   lda #0
        sta arp_clocks
        lda #1
        sta arp_due
_done   rts

; -----------------------------------------------------------------------------
; synth_song_position - core hook (MIDI_SYSTEM): MIDI song position, A =
; LSB, X = MSB. The sequencer moves there (core seq_song_position); if it
; did (seq_located), the arpeggiator's clock count follows, as start sets
; it: at 1/8 an odd position is half a step in (the first clock is the
; step's 7th: its gate's half), else the first clock is a step.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
synth_song_position
        pha                     ; (bit 0: an odd 16th)
        jsr seq_song_position
        pla
        ldy seq_located
        beq _done               ; not moved (internal clock, or playing)
        and #1
        beq _step
        ldx params+P_ARPRATE
        bne _step               ; 1/16, 1/32: every 16th begins a step
        lda #CLOCKS_PER_STEP-1  ; 1/8, odd: the first clock makes 6, the gate's half
        .byte $2c               ; bit abs: skips the next 2-byte instruction
_step   lda #$ff                ; the first clock: a step
        sta arp_clocks
        lda #1
        sta arp_first
_done   rts

; MIDI clocks per step at each rate (1/8, 1/16, 1/32), and when the gate closes
arp_clocks_per  .byte 12, 6, 3
arp_gate_half   .byte 6, 3, 2
