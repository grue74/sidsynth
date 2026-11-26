; render.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Rendering ahead (docs/design.md section 4; the user, 2026-11-20): the
; player (player.asm player_play) renders each tick's MIDI bytes into a
; staging page up to the lead's ticks before the tick is due, in the
; timer interrupt's spare time with interrupts on; at the tick, release
; only copies them into the transmit ring. So a busy tick's bytes leave on
; time, however long they took to compute: only the wire's own pace is
; left. Mute and other live changes act on ticks not yet rendered, up to
; the lead's ticks later.
;
; The rendering is done by the main loop (render_slice, from synth_tick),
; a step at a time (the offs, then a track), as long as it is ahead by
; fewer than the lead's ticks and no 250 Hz tick is waiting, so the
; keys and the screen keep their turn (the editor's one-frame rule) and
; the timing doesn't depend on it. The timer interrupt only releases, and
; renders itself only when a due tick isn't ready (more than the main loop
; managed: the renderer behind).
;
; Ticks are counted from the start in three words that wrap (their
; differences stay well below 32768 ticks, even in overload: at 300 BPM
; that is 2 minutes behind): play_tick the ticks due so far, ren_tick the
; next to render, rel_tick the next to release. When the renderer is
; behind (more than it can compute in time), a due tick is released as it
; is rendered, a track at a time (stage_commit).
;
; Two routines run in interrupts and may be called again from a nested
; interrupt while running: each has a busy flag, and a call that finds it
; busy sets an "again" flag that the running one looks at before it lets
; go, so no tick waits for the next interrupt.

; the lead (the user, 2026-11-20): about 42 ms ahead at any tempo, the
; ticks in it from tables.py's tempo_lead (render_ahead, set with the tempo:
; 1 tick at 40 BPM, 4 at 120, 10 at 295), so a busy tick has as long to be
; rendered at any tempo, and live changes act at most ~42 ms later. The
; timer interrupt keeps all of it for now (render_min = render_ahead: see
; render_slice).
LEAD_MAX        = 14            ; the most ticks of lead (tables.py checks it)
STAGE           = $fc00         ; the staging ring, a page (RAM under the KERNAL)
TICK_END        = $fd00         ; each rendered tick's end in STAGE (ren_tick & 15)
        .cerror TICK_END + 16 > $fffa, "the stage runs into the vectors"
        .cerror LEAD_MAX > 14, "TICK_END holds 16 ticks"

        .section zp
render_ahead    .byte ?         ; the lead, in ticks (tempo_lead: about 42 ms)
render_min      .byte ?         ; fewer ready: the timer interrupt renders (= render_ahead)
play_tick       .word ?         ; ticks due so far (wraps)
ren_tick        .word ?         ; the next tick to render
rel_tick        .word ?         ; the next tick to release
lead_low        .byte ?         ; ticks_lead's scratch
stage_head      .byte ?         ; where the renderer stages next
stage_tail      .byte ?         ; the first byte not yet released
stage_commit_at .byte ?         ; the end of the tick in progress's whole messages
render_busy     .byte ?         ; nonzero: a render step is running
render_again    .byte ?         ;   and render (the interrupt) wanted to meanwhile
render_running  .byte ?         ; nonzero: render's loop is running (an interrupt's)
render_sp       .byte ?         ;   its stack pointer before each step (render_abort)
render_broken   .byte ?         ; nonzero: a step was abandoned (render_abort): the tracks'
                                ; state may be half-way through it (transport.asm)
render_phase    .byte ?         ; PHASE_BEGIN, PHASE_OFFS, PHASE_TRACKS: the next step
render_first_end .byte ?        ; render_first: the tick it stops at (low byte)
release_busy    .byte ?         ; the same for release
release_again   .byte ?
release_low     .byte ?         ; release's scratch
rel_partial     .byte ?         ; 1 = part of rel_tick has gone out (the renderer behind):
                                ; a stop counts it as sent (transport.asm)
st_saved_x      .byte ?         ; st_byte keeps X here
        .send
.if TEST_PLAY
        .section live_vars      ; (live.asm's RAM at $C280: the zero page is full)
steps_main      .word ?         ; tests: render steps by the main loop
steps_irq       .word ?         ;   and by the timer interrupt
st_full_count   .byte ?         ;   the stage full
        .send
.endif

; -----------------------------------------------------------------------------
; render_reset - nothing rendered, due or released (from player_reset, the
; player not running).
; clobbers A
; -----------------------------------------------------------------------------
render_reset
        lda #0
        sta play_tick
        sta play_tick+1
        sta ren_tick
        sta ren_tick+1
        sta rel_tick
        sta rel_tick+1
        sta stage_head
        sta stage_tail
        sta stage_commit_at
        sta render_busy
        sta render_again
        sta render_running
        sta render_broken
        sta render_phase
        sta release_busy
        sta release_again
        sta rel_partial
        rts

; -----------------------------------------------------------------------------
; set_lead - the render lead A ticks (render_ahead), all the timer
; interrupt's (render_min the same). (Stage B tried giving it to the main
; loop, render_min 1, so the keys and the screen would get their turn
; between steps: it couldn't keep ahead, and at half the wire the music
; went out up to 35 ms late. The interrupt keeps it.)
; keeps X, Y
; -----------------------------------------------------------------------------
set_lead
        sta render_ahead
        sta render_min
        rts

; -----------------------------------------------------------------------------
; render_slice - (main loop, synth_tick) render steps while at least
; render_min and fewer than the lead's ticks are ready, and the 4 ms of
; this 250 Hz tick have more than SLICE_SPARE cycles left (CIA1 timer B
; counts them down) and no tick is waiting: so the main loop stays within
; a tick of its ticks. Below render_min the timer interrupt renders (the
; main loop holding the lock then would keep it from doing so). With
; render_min = render_ahead (for now) the main loop renders nothing.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
SLICE_SPARE_HI  = 4             ; timer B's high byte: stop below 4 * 256 cycles left
render_slice
        lda play_state
        beq _done               ; (stopped)
_more   jsr _lead
        cmp render_ahead
        bcs _done               ; far enough ahead
        cmp render_min
        bcc _done               ; the interrupt's to do
        lda tick_count
        cmp tick_done
        bne _done               ; the next 250 Hz tick first
        lda CIA1_TB_HI
        cmp #SLICE_SPARE_HI
        bcc _done               ; this tick's time used up
        lda stage_tail          ; the stage's room less than a step's most: later
        clc                     ; (a full stage would wait here for a tick to go)
        sbc stage_head
        cmp #STAGE_RESERVE
        bcc _done
        jsr _step
        jmp _more
_done   rts

; _lead - A = the ticks rendered ahead of the ticks due (ticks_lead)
_lead   jmp ticks_lead


; _step - one render step (none when the interrupt's is running)
_step
.if TEST_PLAY
        inc steps_main          ; (tests: the steps rendered here)
        bne +
        inc steps_main+1
+
.endif
        jmp render_locked

; -----------------------------------------------------------------------------
; ticks_lead - the ticks rendered ahead of the ticks due, ren_tick -
; play_tick: A = the lead (0 when level or behind, $FF when 255 or more);
; carry clear = behind (ticks due not rendered).
; preserves X, Y
; -----------------------------------------------------------------------------
ticks_lead
        sec
        lda ren_tick
        sbc play_tick
        sta lead_low
        lda ren_tick+1
        sbc play_tick+1
        bmi _behind
        bne _far
        lda lead_low
        sec
        rts
_far    lda #$ff
        sec
        rts
_behind lda #0
        clc
        rts

; -----------------------------------------------------------------------------
; render - (the timer interrupt, interrupts on) when fewer than render_min
; ticks are ready ahead (the main loop didn't manage), rendered here until
; there are. A step running already (the main loop's): that one goes on;
; a release running (this interrupt came in the middle of one): nothing,
; as a full stage would wait for that release, which can't go on. And this
; loop itself running already (an interrupt it let in): nothing, that one
; goes on (it looks at the lead again after each step). Without that, each
; tick's interrupt between two steps started a loop of its own while the
; lead was being caught up: they nested a level a tick, until the stack
; ran out (found after a jump from 100 to 290 BPM as slave). Not while
; the player is stopped or held (a stop being done): a step running then
; is finished, or abandoned if the stage is full (render_abort).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
render
        lda release_busy        ; a release interrupted below: not now (rendering
        bne _done               ; could wait on the stage for that release: deadlock)
        php
        sei
        lda render_running
        bne _running
        inc render_running
        plp
-
.if !TEST_ABORT
        lda play_state          ; stopped or held: no more
        beq render_quit
        cmp #PLAY_HELD
        beq render_quit
.endif
        jsr ticks_lead
        bcc +                   ; behind: on
        cmp render_min
        bcs render_quit
+
.if TEST_PLAY
        inc steps_irq           ; (tests: the steps rendered here)
        bne +
        inc steps_irq+1
+
.endif
        tsx                     ; (where render_abort comes back to)
        stx render_sp
        jsr render_locked
        bcc -
        jmp render_quit
_running
        plp
_done   rts

; render_quit - render's loop ends (render_abort comes here too)
render_quit
        lda #0
        sta render_running
        rts

; -----------------------------------------------------------------------------
; render_abort - (st_full, st_byte: the stage full while the player is
; stopped or held, in the interrupt's render loop) the step abandoned: no
; tick will come due to make room, so waiting would never end (the
; interrupt never returning, the main loop never doing the stop). Back
; to render's loop as it was before the step (render_sp), which ends;
; render_broken set. Nothing a stop needs is lost: each message is staged
; before the note map changes for it (an off before its entry is freed,
; a note before it gets one), so the map and the staged bytes still say
; which notes sounded (stop_walk_stage); the tracks' state may be half-way
; through the step, so stop_locate goes back to a snapshot.
; -----------------------------------------------------------------------------
render_abort
        ldx render_sp
        txs
        lda #0
        sta render_busy
        lda #1
        sta render_broken
        jmp render_quit

; render_locked - one render step, unless one is running already (then
; carry set: the caller stops). clobbers A, X, Y
render_locked
        php
        sei
        lda render_busy
        beq +
        sta render_again
        plp
        sec
        rts
+       inc render_busy
        plp
.if TEST_RENDER_TIMED
        jsr render_timed        ; (tests: the longest step, timing.asm)
.else
        jsr render_step
.endif
        lda #0
        sta render_busy
        clc
        rts

+       inc render_busy
        plp
-       jsr render_step
        lda render_phase
        bne -                   ; (PHASE_BEGIN again: the tick done)
        lda #0
        sta render_busy
        clc
        rts

; -----------------------------------------------------------------------------
; render_step - the tick's next step (render_phase): its beginning, then a
; channel's note offs at a time, then the tracks until one that had
; something to do; a phase with nothing left goes on into the next in the
; same step (a quiet tick is one step). A tick done is marked, and
; released if due.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
PHASE_BEGIN     = 0
PHASE_OFFS      = 1
PHASE_TRACKS    = 2
render_step
.if TEST_LOG && TEST_LOG_RELEASE
        lda #LOG_STEP           ; (tests: a step begins)
        jsr log_release_kind
.endif
        lda render_phase
        cmp #PHASE_OFFS
        beq _offs
        bcs _tracks
        ; the tick's beginning: its offs gathered, or none
        jsr play_begin
        bcs +
        lda #PHASE_OFFS
        sta render_phase
        bne _offs               ; (always)
+       lda #PHASE_TRACKS
        sta render_phase
        bne _tracks             ; (always)
        ; a channel's offs, or on to the tracks
_offs   jsr offs_send_next
        bcs +
        jmp stage_commit
+       lda #PHASE_TRACKS
        sta render_phase
        ; the tracks until one that had something to do
_tracks jsr play_track
        bcs _tick_done
        jmp stage_commit
_tick_done
        lda ren_tick
        and #15
        tax
        lda stage_head
        sta TICK_END,x
        sta stage_commit_at
        php                     ; the phase and the tick's number change together:
        sei                     ; take.asm rec_now reads pl_music, already the next
        lda #PHASE_BEGIN        ; tick's pass, as ren_tick's when the phase is
        sta render_phase        ; PHASE_BEGIN (a stamp a tick late in between)
        inc ren_tick
        bne +
        inc ren_tick+1
+       plp
.if TEST_LOG && TEST_LOG_RELEASE
        lda #LOG_RENDERED       ; (tests: a tick rendered, ren_tick now)
        jsr log_release_kind
.endif
        jmp release             ; (out if due)

; -----------------------------------------------------------------------------
; render_first - before MIDI start (nothing due, interrupts as they are):
; the lead's first ticks rendered, a step at a time, so the first ones are
; on time too, however busy. It stops early, maybe in the middle of a
; tick, while the stage still has STAGE_RESERVE bytes free: with nothing
; due, a full stage would wait for a release that never comes (st_full).
; The rest is rendered once playing, as any tick behind.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
STAGE_RESERVE   = 128           ; the most a render step stages, kept free (a track's
                                ; events on one tick: 42 notes; more could still wait for
                                ; ever here)
render_first
        lda ren_tick
        clc
        adc render_ahead
        sta render_first_end
-       lda ren_tick
        cmp render_first_end
        beq _done               ; the lead rendered
        lda stage_tail          ; free = tail - head - 1 (carry clear: the 1)
        clc
        sbc stage_head
        cmp #STAGE_RESERVE
        bcc _done               ; nearly full: the rest when playing
        jsr render_step
        jmp -
_done   rts

; -----------------------------------------------------------------------------
; release - (interrupts on) the ticks due and rendered: their bytes from
; the stage into the transmit ring, published. A due tick still being
; rendered (the renderer behind) goes as far as its whole messages are
; staged, its running status then started afresh. Called again while
; running: the running one goes on.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
release
        php
        sei
        lda release_busy
        beq +
        sta release_again
        plp
        rts
+       inc release_busy
        plp
_next   lda #0
        sta release_again
        ; is rel_tick due? (play_tick - rel_tick > 0)
        sec
        lda play_tick
        sbc rel_tick
        sta release_low         ; (its own: ticks_lead's lead_low may be in use
        lda play_tick+1         ; in the code this interrupted)
        sbc rel_tick+1
        bmi _done
        ora release_low
        beq _done
        jsr release_thru        ; (a tick's first bytes: thru's first, record.asm)
        ; rendered (whole) or in progress?
        lda ren_tick
        cmp rel_tick
        bne _whole
        lda ren_tick+1
        cmp rel_tick+1
        beq _partial
_whole
.if TEST_LOG && TEST_LOG_RELEASE
        jsr log_release         ; (tests: when each tick goes)
.endif
        lda rel_tick
        and #15
        tax
        ldy TICK_END,x
        jsr release_to
        lda #0
        sta rel_partial
        inc rel_tick
        bne +
        inc rel_tick+1
+       jmp _next
_partial
.if TEST_LOG && TEST_LOG_RELEASE
        lda #LOG_PART           ; (tests: a part of a tick in progress)
        jsr log_release_kind
.endif
        ldy stage_commit_at
        cpy stage_tail
        beq _done
        jsr release_to          ; (running status goes on across the parts: when thru
                                ; comes, stage D, it must not come between them)
        lda #1
        sta rel_partial
        ; let go, unless called again meanwhile (the interrupt flag put
        ; back as it was: render_first runs with interrupts off)
_done   php
        sei
        lda release_again
        bne +
        sta release_busy        ; (0)
        plp
        rts
+       plp
        jmp _next

; release_to - the stage's bytes up to (not including) Y into the transmit
; ring, RELEASE_CHUNK at a time, each published at once (the wire starts
; on the first while the rest are copied); waits for room in the ring
; (interrupts on: the transmit interrupt makes it). clobbers A, X, Y
RELEASE_CHUNK   = 16
release_to
        sty release_end
_chunk  lda release_end
        sec
        sbc stage_tail
        beq _none               ; all copied
        cmp #RELEASE_CHUNK
        bcc +
        lda #RELEASE_CHUNK
+       sta release_count
        ; room in the ring: tail - next - 1 bytes
-       lda tx_tail
        clc
        sbc out_next
        beq _wait
        cmp release_count
        bcs _copy
        sta release_count       ; (as many as fit)
        ; copy, then publish
_copy   ldx stage_tail
        ldy out_next
-       lda STAGE,x
        sta tx_buffer,y
        inx
        iny
        dec release_count
        bne -
        stx stage_tail
        sty out_next
        jsr out_go
        jmp _chunk
_wait   jsr out_go              ; (full: what is there goes; room comes)
        jmp _chunk
_none   rts

        .section zp
release_end     .byte ?         ; release_to: where it stops
release_count   .byte ?         ;   and the bytes of this chunk
        .send

; -----------------------------------------------------------------------------
; st_put - (macro) st_byte inline: byte A staged; when the stage is full,
; st_full waits for room. clobbers Y
; -----------------------------------------------------------------------------
st_put  .macro
        ldy stage_head
        sta STAGE,y             ; (written; kept only if there is room)
        iny
        cpy stage_tail
        bne +
        jsr st_full
+       sty stage_head
        .endm

; st_full - the stage is full (A staged at stage_head already): what is due
; goes out first and it waits for room (interrupts on: the ticks come due
; and go); Y = stage_head + 1 then. Stopped or held, in the interrupt's
; render loop: no tick will come due, so the step is abandoned
; (render_abort). keeps A, X
st_full
.if TEST_PLAY
        inc st_full_count       ; (tests: how often the stage was full)
.endif
        pha
        txa
        pha
-       jsr release
        ldy stage_head
        iny
        cpy stage_tail
        bne +
        jsr st_stuck            ; (full still: abandoned if nothing will come due)
        jmp -
+       pla
        tax
        pla
        rts

; st_stuck - the stage full still: stopped or held, in the interrupt's
; render loop, the step abandoned (render_abort, not returning); else on
; waiting. clobbers A
st_stuck
        lda play_state
        cmp #PLAY_STARTING
        beq +
        cmp #PLAY_RUNNING
        beq +
        lda render_running
        beq +                   ; (the main loop's renders keep room: never here)
        jmp render_abort
+       rts

; -----------------------------------------------------------------------------
; st_byte - (the renderer) byte A staged. When the stage is full, what is
; due goes out first (release), and it waits for room (interrupts on: the
; ticks come due and go).
; preserves A, X, Y
; -----------------------------------------------------------------------------
st_byte
        stx st_saved_x
-       ldx stage_head
        sta STAGE,x             ; (written; kept only if there is room)
        inx
        cpx stage_tail
        beq _full
        stx stage_head
        ldx st_saved_x
        rts
_full   pha
        tya
        pha
        jsr release
        jsr st_stuck            ; (stopped or held: abandoned)
        pla
        tay
        pla
        jmp -

; -----------------------------------------------------------------------------
; stage_commit - (the renderer) the tick in progress's whole messages so far
; are ready: if the tick is due already (the renderer behind), they go out
; at once, and what waits in thru's queue after them (record.asm
; commit_release).
; preserves X, Y
; -----------------------------------------------------------------------------
stage_commit
        lda stage_head
        sta stage_commit_at
        lda ren_tick            ; due when behind: ren_tick < play_tick (carry clear)
        cmp play_tick
        lda ren_tick+1
        sbc play_tick+1
        bcs +
        txa
        pha
        tya
        pha
        jsr commit_release
        pla
        tay
        pla
        tax
+       rts
