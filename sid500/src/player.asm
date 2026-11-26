; player.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The player (docs/design.md section 4): each sequencer tick, from the
; timer interrupt with interrupts on (timing.asm synth_timer), it sends
; the note offs due, then each track's events due, the tracks in their
; priority order, each track's events in their recorded order. Each track
; plays its pattern of the scene, looping at the pattern's own length.
;
; Each track keeps where its reader is (events.asm's state, swapped in and
; out of ev_*), the tick its next event is due and the tick it is at in its
; pattern, and counts down to the next, so a track with nothing due costs
; a decrement. Notes sounding wait for their offs in a timing wheel: 256
; slots, a tick each (the off time's low byte), each a list of entries
; holding the time's high byte, so a tick looks only at its own slot.
;
; MIDI out goes through the merger (out_*): running status, the bytes
; published a track at a time (at the tick's end, the first byte would
; wait for every track; a byte at a time, the ring runs dry and each byte
; costs two interrupts). Nothing is dropped: when the ring is full
; the player waits (interrupts on: the transmit interrupt makes room, and
; the timer still sends each tick's clock and counts the tick).
;
; ev_* belong to the player while it plays: the main loop must not read
; patterns with them meanwhile (the editor will need its own reader).

; track settings and scenes (song data, docs/design.md sections 3 and 5)
NUM_TRACKS      = 16
NUM_SCENES      = 64
TRACK_CHANNEL   = $ca00         ; each track's MIDI channel, 0..15
TRACK_ORDER     = $ca10         ; the tracks in their priority order (a track number each)
TRACK_MUTE      = $ca20         ; 1 = muted (the user's M)
TRACK_SOLO      = $ca30         ; 1 = soloed (the user's S)
TRACK_QUIET     = $ca40         ; nonzero = its events read, not sent (tracks_quiet: mute, solo)
PLAY_PATTERN    = $ca50         ; the pattern each track plays now (the player's copy of its
                                ; scene's row: an edit never changes what a track reads), NO_PATTERN = none
PLAY_STALE      = $ca60         ; nonzero = the track reads a chain its pattern's edit replaced
                                ; (live.asm live_publish): the live switch moves it to the new one
SCENE_BARS      = $ca80         ; each scene's length in bars, 1..255 (stage E)
SCENE_SIG       = $cac0         ; its time signature: the beats - 1 (0..15), + SIG_EIGHTHS for n/8
SCENES          = $cb00         ; each scene's row: a pattern for each track (NO_PATTERN = none)
SCENE_PATTERN   = SCENES        ; scene 1's row (the one playing until stage E)
SONG_DATA_END   = SCENES + NUM_SCENES * NUM_TRACKS
        .cerror SONG_DATA_END > $d000, "the scenes run past the song data"
NO_PATTERN      = $ff
SIG_EIGHTHS     = $80
SCENE_BARS_DEFAULT = 4
SCENE_SIG_DEFAULT = TEST_SIG    ; 4/4 (4 - 1), unless a test sets another
TICKS_PER_STEP  = 12

; each track's player state (16 bytes an array)
TRK_PTR_LO      = $c400         ; the reader (events.asm: ev_ptr, ev_vel, ev_len, ev_cc)
TRK_PTR_HI      = $c410
TRK_VEL         = $c420
TRK_LEN_LO      = $c430
TRK_LEN_HI      = $c440
TRK_CC          = $c450
TRK_DUE_LO      = $c460         ; the tick in the pattern its next event is due ($FFFF: none)
TRK_DUE_HI      = $c470
TRK_POS_LO      = $c480         ; the tick in the pattern it plays next
TRK_POS_HI      = $c490
TRK_PLEN_LO     = $c4a0         ; its pattern's length in ticks (steps * 12)
TRK_PLEN_HI     = $c4b0
TRK_LEFT        = $c4c0         ; the reader's bytes left in its block (ev_left)
TRK_SKIP_LO     = $c4d0         ; ticks to pass before its next event or its pattern's end
TRK_SKIP_HI     = $c4e0
ACTIVE          = $c4f0         ; the tracks with a pattern, in priority order (active_count)

; the notes sounding: the timing wheel, in the RAM under the KERNAL (the
; player runs with the ROMs out; disk access only while stopped)
OFF_ENTRIES     = 128           ; notes that can wait for their offs at once
NO_ENTRY        = $ff
NOTE_ENTRY      = $f000         ; each channel's 128 notes: the entry of the note sounding,
                                ; NO_ENTRY = not sounding (2 KB: channel * 128 + note)
        .cerror NOTE_ENTRY % $800 != 0, "NOTE_ENTRY: its high byte is ORed with channel / 2"
WHEEL           = $f800         ; each slot's first entry (the tick's low byte), NO_ENTRY = none
OFF_HI          = $f900         ; an entry: its off time's high byte
OFF_CHANNEL     = $f980         ;   its channel
OFF_NOTE        = $fa00         ;   its note
OFF_NEXT        = $fa80         ;   the next entry in its slot (or the free list, or a chain)
CHANNEL_FIRST   = $fb00         ; offs_due: each channel's first entry due, NO_ENTRY = none
OFF_SLOT        = $fb80         ;   its slot (the off time's low byte)
        .cerror CHANNEL_FIRST + 16 > $fffa, "the wheel runs into the vectors"

; the tracks' state as each 16th began, the last two (by the 16th's
; parity): a stop that the renderer has gone past goes back to the 16th
; after it with one (transport.asm stop_locate). A slot: the 16 arrays of
; 16 TRK_PTR_LO..ACTIVE (TRK_PLEN among them, unchanged by playing),
; PLAY_PATTERN and PLAY_STALE, so a snapshot is a whole state: the
; patterns playing then (a live switch since, design 5, is made again:
; live.asm; a track in a replaced chain is stale in the snapshot too),
; with active_count, song_tick and pl_music beside them
SNAP_ARRAYS     = 16            ; TRK_PTR_LO..ACTIVE: one page, copied in four strips
SNAP_STRIP      = SNAP_ARRAYS * NUM_TRACKS / 4 ; (a loop of four copies: smaller than 16)
SNAP_PLAY       = SNAP_ARRAYS * NUM_TRACKS  ; then PLAY_PATTERN's copy
SNAP_STALE      = SNAP_PLAY + NUM_TRACKS    ;   and PLAY_STALE's
SNAP_SIZE       = SNAP_STALE + NUM_TRACKS
SNAPSHOT        = $fd10         ; two of SNAP_SIZE (288) bytes, after TICK_END (render.asm)
SNAP_TICK_LO    = SNAPSHOT + 2 * SNAP_SIZE  ; each one's song tick (2 bytes each)
SNAP_TICK_HI    = SNAP_TICK_LO + 2
SNAP_COUNT      = SNAP_TICK_HI + 2          ; its active_count
SNAP_MUSIC_0    = SNAP_COUNT + 2            ; its pl_music (3 bytes, 2 each)
SNAP_MUSIC_1    = SNAP_MUSIC_0 + 2
SNAP_MUSIC_2    = SNAP_MUSIC_1 + 2
        .cerror SNAPSHOT < TICK_END + 16, "the snapshots run into TICK_END"
        .cerror SNAP_MUSIC_2 + 2 > $fffa, "the snapshots run into the vectors"
        .cerror ACTIVE != TRK_PTR_LO + (SNAP_ARRAYS - 1) * NUM_TRACKS, "the snapshot's arrays"

MSG_NOTE_ON     = $90           ; channel messages (low nibble: the channel)
MSG_CC          = $b0
MSG_PROGRAM     = $c0
MSG_BEND        = $e0
CC_ALL_NOTES_OFF = 123          ; the controller that ends every note on its channel

        .section live_vars      ; (live.asm's RAM at $C280: the zero page is full)
pl_music        .fill 3         ; the passes over the tracks since the start: the music's
                                ; ticks (swing: 0-2 passes a tick), 24 bits (~48 hours
                                ; at 120 BPM): a live switch's time (live.asm)
        .send

        .section zp
song_tick       .word ?         ; the ticks played since the start (wraps)
off_free        .byte ?         ; the first free entry, NO_ENTRY = none
last_status     .byte ?         ; the running status: the last status byte queued, 0 = none
pl_track        .byte ?         ; the track being played
pl_channel      .byte ?         ; its MIDI channel
pl_time         .word ?         ; scratch: a tick
pl_map          .word ?         ; the track's channel's row of NOTE_ENTRY
pl_unmap        .word ?         ; off_unmap's row of NOTE_ENTRY
pl_prev         .byte ?         ; offs_due: the entry before, in the slot (NO_ENTRY: none)
pl_step_tick    .byte ?         ; the tick being rendered's place in its 16th, 0..11
pl_step_odd     .byte ?         ;   and the 16th's parity (its snapshot's slot)
pl_swing_row    .word ?         ; swing_counts' row for the Swing parameter (24 bytes)
pl_passes       .byte ?         ; the tracks' passes still to do this tick (swing: 0-2)
pl_walk         .byte ?         ; offs_due: the entry after
active_count    .byte ?         ; tracks in ACTIVE
tq_any_solo     .byte ?         ; tracks_quiet's scratch: nonzero = a track soloed
        .send

; -----------------------------------------------------------------------------
; tracks_init - the track settings at start: track n on channel n+1, the
; tracks in their own order, none muted or soloed; every scene empty, 4
; bars of 4/4.
; clobbers A, X
; -----------------------------------------------------------------------------
tracks_init
        ldx #NUM_TRACKS-1
-       txa
        sta TRACK_CHANNEL,x
        sta TRACK_ORDER,x
        lda #0
        sta TRACK_MUTE,x
        sta TRACK_SOLO,x
        sta TRACK_QUIET,x
        sta PLAY_STALE,x
        sta SNAPSHOT + SNAP_STALE,x     ; (the snapshots too: live.asm reads them)
        sta SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        lda #NO_PATTERN
        sta PLAY_PATTERN,x
        sta SNAPSHOT + SNAP_PLAY,x
        sta SNAPSHOT + SNAP_SIZE + SNAP_PLAY,x
        dex
        bpl -
        ; the scenes: no patterns (4 pages), their length and signature
        lda #NO_PATTERN
        ldx #0
-       .for _page := 0, _page < NUM_SCENES * NUM_TRACKS / 256, _page += 1
        sta SCENES + _page * $100,x
        .endfor
        inx
        bne -
        ldx #NUM_SCENES-1
-       lda #SCENE_BARS_DEFAULT
        sta SCENE_BARS,x
        lda #SCENE_SIG_DEFAULT
        sta SCENE_SIG,x
        dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; tracks_quiet - TRACK_QUIET (what the player reads) from mute and solo: a
; track is quiet when muted, or when another is soloed and it isn't. Each
; byte written once, so the player sees it old or new.
; clobbers A, X
; -----------------------------------------------------------------------------
tracks_quiet
        ; any track soloed?
        ldx #NUM_TRACKS-1
        lda #0
-       ora TRACK_SOLO,x
        dex
        bpl -
        sta tq_any_solo
        ; each track: muted, or not soloed while another is
        ldx #NUM_TRACKS-1
_track  lda TRACK_MUTE,x
        bne _set                ; (muted: quiet)
        lda tq_any_solo
        beq _set                ; (no solo anywhere: 0)
        lda TRACK_SOLO,x
        eor #1                  ; (soloed: 0, else 1)
_set    sta TRACK_QUIET,x
        dex
        bpl _track
        rts

; -----------------------------------------------------------------------------
; active_build - ACTIVE: the tracks with a pattern to play (PLAY_PATTERN),
; in their priority order (TRACK_ORDER); active_count. (player_reset, and
; live.asm live_apply between two passes: no walk of ACTIVE under way.)
; clobbers A, X, Y
; -----------------------------------------------------------------------------
active_build
        lda #0
        sta pl_order
        ldy #0
-       ldx pl_order
        lda TRACK_ORDER,x
        tax
        lda PLAY_PATTERN,x
        cmp #NO_PATTERN
        beq +
        txa
        sta ACTIVE,y
        iny
+       inc pl_order
        lda pl_order
        cmp #NUM_TRACKS
        bne -
        sty active_count
        rts

; -----------------------------------------------------------------------------
; player_reset - from the start (main loop or init, the player not playing):
; every track at its scene pattern's start at the next tick (the playing
; scene's row copied: PLAY_PATTERN; a number with no pattern yet plays
; nothing), no notes sounding, the running status forgotten.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
player_reset_tracks             ; (scene.asm player_reset first: the start scene)
        inc pl_jumps            ; a jump: a live switch not yet made dropped (live.asm)
        lda #0
        sta sw_pending
        ldx #NUM_TRACKS-1
_track  jsr scene_cell          ; (the playing scene's cell: scene.asm)
        sta PLAY_PATTERN,x
        cmp #NO_PATTERN
        beq _none
        tay
        lda PAT_STEPS,y         ; the length in ticks: steps * 12 = steps * 8 + steps * 4
        beq _none               ; (an empty pattern number: as none)
        jsr steps_to_ticks
        sta TRK_PLEN_LO,x
        sta TRK_POS_LO,x        ; (at its end: the first tick starts the pattern)
        tya
        sta TRK_PLEN_HI,x
        sta TRK_POS_HI,x
        jmp _next
_none   lda #NO_PATTERN         ; (the player's copy only: the cell keeps its number)
        sta PLAY_PATTERN,x
_next   lda #0
        sta TRK_SKIP_LO,x
        sta TRK_SKIP_HI,x
        sta PLAY_STALE,x        ; (each from its pattern's chain now)
        dex
        bpl _track
        jsr active_build        ; the tracks that play
        ; nothing sounding: the wheel and the notes' entries empty, every
        ; entry free (chained in order); nothing rendered, due or released
        lda #0
        sta song_tick
        sta song_tick+1
        sta pl_music
        sta pl_music+1
        sta pl_music+2
        sta last_status
        sta pl_step_tick
        sta pl_step_odd
        jsr snapshot_save       ; (the first 16th's state: its start)
        jsr render_reset
        ; (on into wheel_clear)

; -----------------------------------------------------------------------------
; wheel_clear - no note sounding: the wheel and the notes' entries empty,
; every entry free (chained in order).
; clobbers A, X
; -----------------------------------------------------------------------------
wheel_clear
        ; all nine pages in one pass (~12,800 cycles; a page at a time,
        ; wheel_clear_page, takes ~10,000 more: a slave's start away from
        ; the song's start waits for this one)
        lda #NO_ENTRY
        ldx #0
-       sta WHEEL,x
        .for _page := 0, _page < 8, _page += 1
        sta NOTE_ENTRY + _page * $100,x
        .endfor
        inx
        bne -
        jmp wheel_free_all

; wheel_clear_page - wheel_clear's page X (0..WHEEL_PAGES-1, any order): a
; page of NOTE_ENTRY, or the wheel and the free list (a stop does them
; one a call: transport.asm). clobbers A, X, Y
WHEEL_PAGES     = 9
wheel_clear_page
        cpx #8
        bcs _wheel
        txa                     ; NOTE_ENTRY's page X
        clc
        adc #>NOTE_ENTRY
        sta _note+2
        lda #NO_ENTRY
        ldy #0
_note   sta NOTE_ENTRY,y        ; (the page self-modified)
        iny
        bne _note
        rts
_wheel  lda #NO_ENTRY
        ldx #0
-       sta WHEEL,x
        inx
        bne -
        jmp wheel_free_all      ; (click.asm: out of the hot code's way)

; steps_to_ticks - A steps (1..128) * 12 ticks: low byte in A, high in Y.
; preserves X
steps_to_ticks
        ldy #0
        sty pl_time+1
        asl                     ; * 4 (at most 512: the carry into the high byte)
        rol pl_time+1
        asl
        rol pl_time+1
        sta pl_time
        asl                     ; * 8
        tay
        lda pl_time+1
        rol
        sta pl_walk
        tya
        clc
        adc pl_time             ; * 8 + * 4
        pha
        lda pl_walk
        adc pl_time+1
        tay
        pla
        rts

; -----------------------------------------------------------------------------
; The player renders a sequencer tick into the stage (render.asm) in steps,
; so the main loop can do it a little at a time (render_step): first
; play_begin (the offs due), then play_track until it says the tick is
; done. A track counts down the ticks to its next event or its pattern's
; end (TRK_SKIP), so a track with nothing to do costs a decrement; each
; track's bytes are committed as soon as they are staged (released at once
; when the tick is due already). Never re-entered (render.asm's lock).
; -----------------------------------------------------------------------------

; play_begin - a tick's beginning: running status afresh (a thru message
; may come between two ticks), the tracks from the first; the note offs due
; gathered (its slot of the wheel; offs_send_next sends them). Carry set =
; no offs. clobbers A, X, Y
play_begin_tick                 ; (scene.asm play_begin first: a launch)
.if TEST_TRAP_TICK && TEST_TRAP_TRACK == 255
        jsr trap_tick           ; (tests: a breakpoint as tick n's rendering begins)
.endif
        ; the tracks' passes this tick (swing): the tick's place in its
        ; pair of 16ths in swing_counts' row
        lda pl_step_odd
        beq +
        lda #TICKS_PER_STEP
+       clc
        adc pl_step_tick
        tay
        lda (pl_swing_row),y
        sta pl_passes
        lda ren_tick            ; the music's pass as the tick begins, for recording's
        and #15                 ; stamps (take.asm rec_now)
        tax
        lda pl_music
        sta TICK_MUSIC_LO,x
        lda pl_music+1
        sta TICK_MUSIC_HI,x
        lda #0
        sta last_status
        sta pl_order
        ldx song_tick
        lda WHEEL,x
        bmi +                   ; (NO_ENTRY: nothing in the slot)
        jsr offs_due
        clc
        rts
+       sec
        rts

; play_track - the tick's next step: the tracks counted down until one has
; something to do, which is played. Carry set = the tick is done (the
; song's tick counted on). With swing a tick makes 0, 1 or 2 passes over
; the tracks (pl_passes: each pass a tick of the music, play_begin), so
; the music runs slower than the ticks in an odd 16th's first half and
; faster in its second. clobbers A, X, Y
play_track
        ldy pl_order
        lda pl_passes
        beq _end                ; (swing: no pass this tick)
_track  cpy active_count
        bcs _pass_end
        ldx ACTIVE,y
        iny
        lda TRK_SKIP_LO,x
        bne _count
        lda TRK_SKIP_HI,x
        beq _handle
        dec TRK_SKIP_HI,x
_count  dec TRK_SKIP_LO,x
        jmp _track
_handle sty pl_order
        stx pl_track
        jsr track_handle
        clc
        rts
_pass_end
        inc pl_music            ; a pass done: the music a tick on
        bne +
        inc pl_music+1
        bne +
        inc pl_music+2
+       lda sw_pending
        beq +
        jsr live_due            ; (a live switch at this pass: live.asm)
+       ldy #0                  ; (the next pass from the first track)
        dec pl_passes
        bne _track              ; (swing: a second pass this tick)
_end    sty pl_order
.if TEST_TRAP_TICK && TEST_TRAP_TRACK == 255
        jsr trap_tick_end       ; (tests: ... and as it ends)
.endif
        inc song_tick
        bne +
        inc song_tick+1
+       inc pl_step_tick        ; the place in the 16th
        lda pl_step_tick
        cmp #TICKS_PER_STEP
        bne +
        lda #0
        sta pl_step_tick
        lda pl_step_odd
        eor #1
        sta pl_step_odd
        jsr snapshot_save       ; the next tick starts a 16th: the tracks' state kept now
+       sec                     ; (not as it begins: that is often the busiest tick)
        rts

; -----------------------------------------------------------------------------
; snapshot_save - (a 16th's first tick about to begin: play_track as the
; tick before it ends, player_reset, stop_locate) the tracks' state, the
; patterns playing, song_tick and pl_music into the 16th's slot (its
; parity). ~2,800 cycles.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
snapshot_save
        ldy pl_step_odd
        lda song_tick
        sta SNAP_TICK_LO,y
        lda song_tick+1
        sta SNAP_TICK_HI,y
        lda active_count
        sta SNAP_COUNT,y
        lda pl_music
        sta SNAP_MUSIC_0,y
        lda pl_music+1
        sta SNAP_MUSIC_1,y
        lda pl_music+2
        sta SNAP_MUSIC_2,y
        tya
        bne _slot1
        ldx #SNAP_STRIP-1
-       lda TRK_PTR_LO + 0 * SNAP_STRIP,x
        sta SNAPSHOT + 0 * SNAP_STRIP,x
        lda TRK_PTR_LO + 1 * SNAP_STRIP,x
        sta SNAPSHOT + 1 * SNAP_STRIP,x
        lda TRK_PTR_LO + 2 * SNAP_STRIP,x
        sta SNAPSHOT + 2 * SNAP_STRIP,x
        lda TRK_PTR_LO + 3 * SNAP_STRIP,x
        sta SNAPSHOT + 3 * SNAP_STRIP,x
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda PLAY_PATTERN,x
        sta SNAPSHOT + SNAP_PLAY,x
        lda PLAY_STALE,x
        sta SNAPSHOT + SNAP_STALE,x
        dex
        bpl -
        rts
_slot1
        ldx #SNAP_STRIP-1
-       lda TRK_PTR_LO + 0 * SNAP_STRIP,x
        sta SNAPSHOT + SNAP_SIZE + 0 * SNAP_STRIP,x
        lda TRK_PTR_LO + 1 * SNAP_STRIP,x
        sta SNAPSHOT + SNAP_SIZE + 1 * SNAP_STRIP,x
        lda TRK_PTR_LO + 2 * SNAP_STRIP,x
        sta SNAPSHOT + SNAP_SIZE + 2 * SNAP_STRIP,x
        lda TRK_PTR_LO + 3 * SNAP_STRIP,x
        sta SNAPSHOT + SNAP_SIZE + 3 * SNAP_STRIP,x
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda PLAY_PATTERN,x
        sta SNAPSHOT + SNAP_SIZE + SNAP_PLAY,x
        lda PLAY_STALE,x
        sta SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; snapshot_restore - the tracks' state as the 16th at song tick pl_time
; began, from its slot (the patterns playing then among it); song_tick =
; pl_time, pl_music as then, pl_step_* at its start. Carry set = no slot
; holds that tick (nothing changed).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
snapshot_restore
        ldy #0
-       lda SNAP_TICK_LO,y
        cmp pl_time
        bne +
        lda SNAP_TICK_HI,y
        cmp pl_time+1
        beq _found
+       iny
        cpy #2
        bne -
        sec
        rts
_found  sty pl_step_odd
        inc pl_jumps            ; a jump: a live switch not yet made dropped (live.asm)
        lda #0
        sta sw_pending
        sta pl_step_tick
        lda pl_time
        sta song_tick
        lda pl_time+1
        sta song_tick+1
        lda SNAP_COUNT,y
        sta active_count
        lda SNAP_MUSIC_0,y
        sta pl_music
        lda SNAP_MUSIC_1,y
        sta pl_music+1
        lda SNAP_MUSIC_2,y
        sta pl_music+2
        tya
        bne _slot1
        ldx #SNAP_STRIP-1
-       lda SNAPSHOT + 0 * SNAP_STRIP,x
        sta TRK_PTR_LO + 0 * SNAP_STRIP,x
        lda SNAPSHOT + 1 * SNAP_STRIP,x
        sta TRK_PTR_LO + 1 * SNAP_STRIP,x
        lda SNAPSHOT + 2 * SNAP_STRIP,x
        sta TRK_PTR_LO + 2 * SNAP_STRIP,x
        lda SNAPSHOT + 3 * SNAP_STRIP,x
        sta TRK_PTR_LO + 3 * SNAP_STRIP,x
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda SNAPSHOT + SNAP_PLAY,x
        sta PLAY_PATTERN,x
        lda SNAPSHOT + SNAP_STALE,x
        sta PLAY_STALE,x
        dex
        bpl -
        clc
        rts
_slot1
        ldx #SNAP_STRIP-1
-       lda SNAPSHOT + SNAP_SIZE + 0 * SNAP_STRIP,x
        sta TRK_PTR_LO + 0 * SNAP_STRIP,x
        lda SNAPSHOT + SNAP_SIZE + 1 * SNAP_STRIP,x
        sta TRK_PTR_LO + 1 * SNAP_STRIP,x
        lda SNAPSHOT + SNAP_SIZE + 2 * SNAP_STRIP,x
        sta TRK_PTR_LO + 2 * SNAP_STRIP,x
        lda SNAPSHOT + SNAP_SIZE + 3 * SNAP_STRIP,x
        sta TRK_PTR_LO + 3 * SNAP_STRIP,x
        dex
        bpl -
        ldx #NUM_TRACKS-1
-       lda SNAPSHOT + SNAP_SIZE + SNAP_PLAY,x
        sta PLAY_PATTERN,x
        lda SNAPSHOT + SNAP_SIZE + SNAP_STALE,x
        sta PLAY_STALE,x
        dex
        bpl -
        clc
        rts

        .section zp
pl_order        .byte ?         ; the place in ACTIVE being played
        .send

; -----------------------------------------------------------------------------
; track_handle - track pl_track's tick, where it has something to do (at
; its position, TRK_POS): at its pattern's end it starts again; the events
; due now are played and sent; then the ticks to its next event or its
; pattern's end, whichever is first, are counted down from the next tick
; on, its position moved there.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
track_handle
.if TEST_TRAP_TICK
        lda song_tick           ; (tests: breakpoints around one track's tick)
        cmp #<TEST_TRAP_TICK
        bne _handle
        lda song_tick+1
        cmp #>TEST_TRAP_TICK
        bne _handle
        lda pl_track
        cmp #TEST_TRAP_TRACK
        bne _handle
        jsr trap_start
        jsr _handle
        jmp trap_end
_handle
.endif
        ldx pl_track
        ; at the pattern's end: from its start
        lda TRK_POS_LO,x
        cmp TRK_PLEN_LO,x
        bne _due
        lda TRK_POS_HI,x
        cmp TRK_PLEN_HI,x
        bne _due
        jsr track_restart
        ldx pl_track
        ; the events due now
_due    lda TRK_POS_LO,x
        cmp TRK_DUE_LO,x
        bne _wait
        lda TRK_POS_HI,x
        cmp TRK_DUE_HI,x
        bne _wait
        jsr track_events
        jsr stage_commit
        ldx pl_track
        ; the next tick with something to do: the next event or the end
_wait   lda TRK_DUE_LO,x
        cmp TRK_PLEN_LO,x
        lda TRK_DUE_HI,x
        sbc TRK_PLEN_HI,x
        bcc _to_event           ; due < length
        lda TRK_PLEN_LO,x
        sta pl_time
        lda TRK_PLEN_HI,x
        sta pl_time+1
        jmp _skip
_to_event
        lda TRK_DUE_LO,x
        sta pl_time
        lda TRK_DUE_HI,x
        sta pl_time+1
        ; the ticks to pass first: that tick - the position - 1
_skip   clc
        lda pl_time
        sbc TRK_POS_LO,x
        sta TRK_SKIP_LO,x
        lda pl_time+1
        sbc TRK_POS_HI,x
        sta TRK_SKIP_HI,x
        lda pl_time
        sta TRK_POS_LO,x
        lda pl_time+1
        sta TRK_POS_HI,x
        rts

.if TEST_TRAP_TICK
; trap_start, trap_end - (tests) breakpoint addresses around a track's tick
trap_start
        rts
trap_end
        rts
.if TEST_TRAP_TRACK == 255
; trap_tick, trap_tick_end - (tests) trap_start / trap_end when song_tick
; is TEST_TRAP_TICK. keep X, Y
trap_tick
        lda song_tick
        cmp #<TEST_TRAP_TICK
        bne +
        lda song_tick+1
        cmp #>TEST_TRAP_TICK
        beq trap_start
+       rts
trap_tick_end
        lda song_tick
        cmp #<TEST_TRAP_TICK
        bne +
        lda song_tick+1
        cmp #>TEST_TRAP_TICK
        beq trap_end
+       rts
.endif
.endif

; -----------------------------------------------------------------------------
; track_restart - track pl_track from its pattern's start: position 0, the
; reader at the start, its first event's time; the reader saved.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
track_restart
        ldx pl_track
        lda #0
        sta TRK_POS_LO,x
        sta TRK_POS_HI,x
        sta TRK_DUE_LO,x
        sta TRK_DUE_HI,x
        lda PLAY_PATTERN,x
        jsr ev_start
        jsr track_next_time
        jmp track_save

; -----------------------------------------------------------------------------
; track_events - track pl_track's events due now: its reader swapped in,
; each event played, until the next one's time is later (or the pattern
; ends); the reader saved.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
track_events
        ldx pl_track
        lda TRACK_CHANNEL,x
        sta pl_channel
        lsr                     ; its row: channel * 128 (carry: the odd half page)
        ora #>NOTE_ENTRY
        sta pl_map+1
        lda #0
        ror
        sta pl_map
        lda TRK_PTR_LO,x
        sta ev_ptr
        lda TRK_PTR_HI,x
        sta ev_ptr+1
        lda TRK_LEFT,x
        sta ev_left
        lda TRK_VEL,x
        sta ev_vel
        lda TRK_LEN_LO,x
        sta ev_len
        lda TRK_LEN_HI,x
        sta ev_len+1
        lda TRK_CC,x
        sta ev_cc
_event  jsr ev_read_event
        ldx pl_track
        lda TRACK_QUIET,x       ; (muted, or another soloed)
        bne +
        jsr play_event
+       jsr track_next_time
        bcs track_save          ; the pattern ended
        lda ev_delta
        ora ev_delta+1
        beq _event              ; another at the same tick
        ; (falls through: the reader saved)

; track_save - the reader (ev_*) saved as track pl_track's
; clobbers A, X
track_save
        ldx pl_track
        lda ev_ptr
        sta TRK_PTR_LO,x
        lda ev_ptr+1
        sta TRK_PTR_HI,x
        lda ev_left
        sta TRK_LEFT,x
        lda ev_vel
        sta TRK_VEL,x
        lda ev_len
        sta TRK_LEN_LO,x
        lda ev_len+1
        sta TRK_LEN_HI,x
        lda ev_cc
        sta TRK_CC,x
        rts

; -----------------------------------------------------------------------------
; track_next_time - the reader's next time: track pl_track's next event due
; that much later ($FFFF when the pattern ends: carry set).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
track_next_time
        jsr ev_read_time
        ldx pl_track
        bcs _end
        lda TRK_DUE_LO,x
        adc ev_delta            ; (carry clear)
        sta TRK_DUE_LO,x
        lda TRK_DUE_HI,x
        adc ev_delta+1
        sta TRK_DUE_HI,x
        clc
        rts
_end    lda #$ff
        sta TRK_DUE_LO,x
        sta TRK_DUE_HI,x
        rts                     ; (carry set)

; -----------------------------------------------------------------------------
; play_event - the event read (ev_type, ev_d1, ev_d2, ev_vel, ev_len) out
; on pl_channel: a note also goes into the off list.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
play_event
        ldx ev_type
        beq _note
        dex
        beq _cc
        dex
        beq _bend
        dex
        beq _program
        rts                     ; TYPE_BAD: nothing
_cc     lda #MSG_CC
        ora pl_channel
        jsr st_status
        lda ev_d1
        jsr st_byte
        lda ev_d2
        jmp st_byte
_bend   lda #MSG_BEND
        ora pl_channel
        jsr st_status
        lda ev_d1
        jsr st_byte
        lda ev_d2
        jmp st_byte
_program
        lda #MSG_PROGRAM
        ora pl_channel
        jsr st_status
        lda ev_d1
        jmp st_byte

        ; a note: if it is sounding already, its off first (else that off
        ; would end the new note early); then the note, and its off listed
_note   ldy ev_d1
        lda (pl_map),y
        bmi +                   ; (NO_ENTRY: not sounding)
        tax
        jsr off_now
+       lda #MSG_NOTE_ON
        ora pl_channel
        cmp last_status
        beq +
        sta last_status
        #st_put
+       lda ev_d1
        #st_put
        lda ev_vel
        #st_put
        jmp off_add

; =============================================================================
; The note offs: the timing wheel
; =============================================================================

; -----------------------------------------------------------------------------
; off_add - note ev_d1 on pl_channel sounds until song_tick + ev_len: an
; entry (a free one, or when none is, the next off in the wheel is sent
; now to make room) into the slot of its off time, and into NOTE_ENTRY.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
off_add
        ldx off_free
        bmi _steal
        lda OFF_NEXT,x
        sta off_free
        jmp _fill
_steal  jsr off_steal
        ; the entry: the off time's high byte, the channel, the note
_fill   clc
        lda song_tick
        adc ev_len
        tay                     ; (the slot)
        lda song_tick+1
        adc ev_len+1
        sta OFF_HI,x
        tya
        sta OFF_SLOT,x
        lda pl_channel
        sta OFF_CHANNEL,x
        lda ev_d1
        sta OFF_NOTE,x
        ; first in its slot
        lda WHEEL,y
        sta OFF_NEXT,x
        txa
        sta WHEEL,y
        ; the note's entry
        ldy ev_d1
        sta (pl_map),y
        rts

; -----------------------------------------------------------------------------
; off_steal - no entry free: the wheel's next slot with an entry, from the
; next tick on, gives up its first entry (its note's off sent now). X =
; the entry.
; clobbers A, Y
; -----------------------------------------------------------------------------
off_steal
        ldy song_tick
-       iny                     ; (some slot has one: every entry is in a slot)
        ldx WHEEL,y
        bmi -
        lda OFF_NEXT,x          ; out of its slot
        sta WHEEL,y
        lda OFF_CHANNEL,x
        ora #MSG_NOTE_ON
        jsr st_status
        lda OFF_NOTE,x
        jsr st_byte
        lda #0
        jsr st_byte
        jsr off_unmap
_done   rts

; -----------------------------------------------------------------------------
; off_now - note ev_d1 on pl_channel, entry X, is sounding and starts
; again: its off now, and the entry out of its slot and free at once (left
; in the wheel until its slot came round, such entries filled it: a note a
; loop longer than its loop, as a pad's, leaves one every loop). The
; note's NOTE_ENTRY becomes the new entry's (off_add).
; clobbers A, Y
; -----------------------------------------------------------------------------
off_now
        lda #MSG_NOTE_ON
        ora pl_channel
        jsr st_status
        lda ev_d1
        jsr st_byte
        lda #0
        jsr st_byte
        ; find it in its slot (a short list): the head, or after another
        stx pl_walk             ; (the entry)
        ldy OFF_SLOT,x
        lda WHEEL,y
        cmp pl_walk
        bne _find
        lda OFF_NEXT,x          ; the head: the slot starts after it
        sta WHEEL,y
        jmp off_free_entry
_find   tay                     ; Y = an entry before it
-       lda OFF_NEXT,y
        cmp pl_walk
        beq +
        tay
        jmp -
+       lda OFF_NEXT,x          ; the one before it skips it
        sta OFF_NEXT,y
        jmp off_free_entry

; -----------------------------------------------------------------------------
; offs_due - this tick's slot of the wheel: its entries due now (the off
; time's high byte this tick's) sent a channel at a time, channel 1 first
; and each channel's oldest note first (running status then needs one
; status byte a channel: 64 offs take 144 bytes, not up to 192), and freed;
; the others (due 256 ticks or more later) stay.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
offs_due
        ; step 1: the channels' chains empty
        ldx #15
        lda #NO_ENTRY
-       sta CHANNEL_FIRST,x
        dex
        bpl -
        ; step 2: the slot walked: due entries into their channel's chain
        ; (in front: the slot lists the newest first, a chain the oldest)
        sta pl_prev
        ldy song_tick
        ldx WHEEL,y
_walk   bmi _send
        lda OFF_NEXT,x
        sta pl_walk
        lda OFF_HI,x
        cmp song_tick+1
        bne _stays
        jsr off_unlink
        ldy OFF_CHANNEL,x
        lda CHANNEL_FIRST,y
        sta OFF_NEXT,x
        txa
        sta CHANNEL_FIRST,y
        jmp _on
_stays  stx pl_prev
_on     ldx pl_walk
        jmp _walk
        ; then offs_send_next sends them, a channel a step
_send   lda #0
        sta pl_off_channel
        rts

; -----------------------------------------------------------------------------
; offs_send_next - the next channel (from pl_off_channel) with offs
; gathered by offs_due: its offs out, their notes unmapped, their entries
; freed. Carry set = no channel left.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
offs_send_next
        ldy pl_off_channel
_find   cpy #16
        bcs _none
        ldx CHANNEL_FIRST,y
        bpl _channel
        iny
        jmp _find
_none   rts                     ; (carry set)
_channel
        iny                     ; (the next call: the channel after)
        sty pl_off_channel
        dey
        tya                     ; the channel's row of NOTE_ENTRY (for the unmapping)
        lsr
        ora #>NOTE_ENTRY
        sta pl_unmap+1
        lda #0
        ror
        sta pl_unmap
        tya
        ora #MSG_NOTE_ON
        jsr st_status
        ; each off: its note and velocity 0 staged, the note unmapped, the
        ; entry freed
_off    lda OFF_NOTE,x
        #st_put
        lda #0
        #st_put
        ldy OFF_NOTE,x
        lda #NO_ENTRY
        sta (pl_unmap),y
        lda OFF_NEXT,x          ; (the chain's next)
        tay
        lda off_free
        sta OFF_NEXT,x
        stx off_free
        tya
        tax
        bpl _off                ; (NO_ENTRY: the channel's last)
        clc
        rts

; off_unlink - (offs_due) entry X out of the slot being walked (pl_prev before it,
; pl_walk after it)
off_unlink
        ldy pl_prev
        bmi +
        lda pl_walk
        sta OFF_NEXT,y
        rts
+       ldy song_tick
        lda pl_walk
        sta WHEEL,y
        rts

        .section zp
pl_off_channel  .byte ?         ; offs_due: the channel being sent
        .send

; off_free_entry - entry X onto the free list. clobbers A
off_free_entry
        lda off_free
        sta OFF_NEXT,x
        stx off_free
        rts

; off_unmap - entry X's note isn't sounding any more: its NOTE_ENTRY
; cleared. clobbers A, Y
off_unmap
        lda OFF_CHANNEL,x
        lsr                     ; its row: channel * 128
        ora #>NOTE_ENTRY
        sta pl_unmap+1
        lda #0
        ror
        sta pl_unmap
        ldy OFF_NOTE,x
        lda #NO_ENTRY
        sta (pl_unmap),y
        rts

; =============================================================================
; The merger: MIDI out from the player (interrupt) and the main loop
; =============================================================================

; -----------------------------------------------------------------------------
; st_status - status byte A staged, unless it is the running status
; already.
; preserves X, Y
; -----------------------------------------------------------------------------
st_status
        cmp last_status
        beq +
        sta last_status
        jmp st_byte
+       rts

; -----------------------------------------------------------------------------
; out_message_main - (main loop) a whole message of up to 3 bytes from
; out_msg (out_msg_len bytes, its status first) queued into the transmit
; ring and sent, inside sei so the release can't come between its bytes.
; Its status always sent (running status belongs to the rendered ticks,
; each of which starts with its own). Waits for room first with interrupts
; on (inside sei a full ring could never empty).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
out_message_main
-       sei
        lda tx_tail
        clc
        sbc out_next            ; free bytes = tail - next - 1
        cmp out_msg_len
        bcs out_message_room
        cli
        jsr out_go              ; (what is queued goes: room comes)
        jmp -
out_message_room                ; (record.asm thru_out: inside sei, room for the message)
        ldy #0
-       lda out_msg,y
        jsr out_byte
        iny
        cpy out_msg_len
        bne -
        jsr out_go
        cli
        rts

        .section zp
out_msg         .fill 3         ; out_message_main's message
out_msg_len     .byte ?         ;   and its length
        .send
