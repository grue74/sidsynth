; clock.asm - part of SID500, included by sid500.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The time display (docs/design.md section 5f; the user, 2026-11-26): the
; song screen's title shows the song's place as bar.beat and its time as
; m:ss ("SONG  SCENE 05  BPM 122 012.3  2:15 PLAY"), in place of the half
; shown ("TRK 1-8": the header's colours show it).
;
; Song time: what is heard (play_tick, the ticks due), counted in the main
; loop's 250 Hz tick from play_tick's differences: nothing added to the
; timer interrupt, the renderer or the snapshots.
; - The text is kept as the title shows it (ck_text, screen codes): the
;   bar's three digits and m:ss counted on in place (ck_up), the bar 999
;   on to 000 by itself; nothing converted from binary.
; - A tick is 60 / (BPM x 48) s = 5 / (4 x BPM) s: 5 added to a remainder
;   (ck_frac) a tick, a second at 4 x BPM (exact at whole tempos; a tempo
;   change counts on at the new one).
; - The beat: the ticks into it (ck_bt) and its number (ck_beat), a bar
;   when the beats come round; the next bar's signature the playing
;   scene's (a launch is at a bar line, so a new scene's bars are its own).
; - Behind what was seen (a stop: play_tick back to the ticks sent, then on
;   to the 16th it continues from): nothing counted until play_tick is past
;   it again, so a stop's small steps back and on count right.
; - Jumps marked by their makers (ck_jump): scene.asm player_reset (the
;   song's start: 001.1 0:00, the start scene's bar) and locate.asm
;   locate_done (a song position: the bars from locate_scene's walk, which
;   counts them as it goes, ck_bars, and its rounds, ck_q; the time from
;   the 16th).
; Its code is in main RAM (~640 bytes: the user, 2026-11-26, gave the pool's
; first pages for it; the RAM under I/O had 91 bytes left).

; -----------------------------------------------------------------------------
; Variables: after the disk's (or the locate's) in $CFxx (main loop only)
; -----------------------------------------------------------------------------
.if DISK_CODE
CLOCK_VARS      = disk_vars_end
.else
CLOCK_VARS      = locate_vars_end
.endif
        .virtual CLOCK_VARS
ck_seen         .word ?         ; play_tick counted to
ck_jump         .byte ?         ; CK_*: a jump to take (set by its maker)
ck_bt           .byte ?         ; the ticks into the beat
ck_beat         .byte ?         ;   the beat in the bar, 0 = the first
ck_frac         .word ?         ; the time's units past the second: 5 a tick
ck_zero_end                     ; (ck_seen ... ck_frac: 0 at the song's start)
ck_beats        .byte ?         ; the bar's beats (1-16)
ck_blen         .byte ?         ;   a beat's ticks (48, 24)
ck_q4           .word ?         ; 4 x BPM: a second's units
ck_bars         .word ?         ; locate_scene: the bars of the scenes passed; then a round's
ck_q            .word ?         ; locate_round: the rounds left out
ck_text         .fill CK_TEXT_LEN ; the title's "001.1  0:00", as shown
clock_vars_end
        .endv
        .cerror clock_vars_end > $d000, "the clock's variables run past $CFFF"
        .section edit_vars      ; (under the KERNAL: $CFxx is full)
ck_ver          .byte ?         ; counted on at each change of the text
ck_drawn        .byte ?         ;   and as the title was last prepared with
        .send
CK_RESET        = 1             ; ck_jump: the song from its start (player_reset)
CK_LOCATED      = 2             ;   a song position located (locate_done)
CK_TICK_UNITS   = 5             ; a tick: 5 / (4 x BPM) s
CK_TEXT_LEN     = 11            ; "001.1  0:00"
CK_BAR_LAST     = 2             ; ck_text's places: the bar's last digit,
CK_BEAT         = 4             ;   the beat (1 or 2 digits),
CK_SECOND       = 10            ;   the seconds' last digit (the minutes at 6-7)
CK_BLANK        = $20           ; a space (screen code)
SONG_TITLE_CLOCK = 24           ; ck_text's place in the title

        .section late_code
; clock_check - (count.asm count_state_check: the song screen's, each draw
; step) the text changed since the title last had it (ck_drawn): its 11
; characters put straight on the screen (~200 cycles; the colours the
; title's already), if the title row shows the song screen's title (not
; marked to draw: else it is drawn whole from the text anyway; no disk
; message or prompt there) and the beam is clear of it (else the next
; step). As a row drawn whole the clock cost the keys' response at half
; the wire (screen_check: up to 101.5 ms of 100), and as a dirty row it
; waited behind a scroll's copying (flash_check: a beat old for 15-23
; frames). A title prepared aside is forgotten (it has the old text).
; The step grid's title is its own. clobbers A, X, Y
clock_check
        lda song_mode
        bne _rts                ; (MODE_SONG: 0)
        lda ck_ver
        cmp ck_drawn
        beq _rts
        lda song_dirty_rows     ; (the title marked: drawn whole, with the text)
        and #1 << SONG_TITLE_ROW
        bne _rts
.if DISK_CODE
        lda disk_ui             ; (the disk's message or prompt there)
        bne _rts
.endif
        ldx #SONG_TITLE_ROW
        jsr song_row_safe
        bcc _rts                ; (the beam near: the next step)
        lda ck_ver
        sta ck_drawn
        lda song_ready_row      ; (the title prepared: forgotten)
        bne +
        lda #$ff
        sta song_ready_row
+       jsr set_row_ptr         ; (X: the title's row)
        ldx #CK_TEXT_LEN-1
        ldy #SONG_TITLE_CLOCK+CK_TEXT_LEN-1
-       lda ck_text,x
        sta (ptr),y
        dey
        dex
        bpl -
_rts    rts
        .cerror MODE_SONG != 0, "clock_check: MODE_SONG is 0"
        .cerror SONG_TITLE_ROW != 0, "clock_check: the title's row is row 0"

; ck_add_bars - (locate.asm's walks, clock_located) ck_bars + scene X's bars
; x its repeats (1-255 x 1-9). clobbers A, Y; keeps X
ck_add_bars
        ldy SCENE_REPEATS,x
-       clc
        lda ck_bars
        adc SCENE_BARS,x
        sta ck_bars
        bcc +
        inc ck_bars+1
+       dey
        bne -
        rts
        .send

        .section init_code      ; (start-up only: run once from INIT_CODE)
; clock_init - (synth_init) the title's text at the song's start before
; anything draws it (the RAM is junk at power-on). clobbers A, X, Y
clock_init
        jmp ck_reset
        .send

        .section late_code
; -----------------------------------------------------------------------------
; clock_poll - (hooks.asm synth_tick: the main loop's 250 Hz tick, every
; screen) a jump marked (ck_jump) taken; then the ticks heard since the
; last look counted on (forward only: behind, it waits). At the song's
; start, stopped, the start scene's signature taken again (it may be
; edited there). clobbers A, X, Y, div_lo, div_hi
; -----------------------------------------------------------------------------
clock_poll
        lda params+P_TEMPO      ; 4 x BPM
        clc
        adc #BPM_LOWEST
        sta ck_q4
        lda #0
        asl ck_q4
        rol a
        asl ck_q4
        rol a
        sta ck_q4+1
        lda ck_jump
        beq clock_count
        cmp #CK_LOCATED
        beq clock_located
        jsr ck_reset            ; (the song's start: from tick 0)
clock_count
        php                     ; div = the tick now - the tick seen
        sei
        ldy play_tick
        ldx play_tick+1
        plp
        tya
        sec
        sbc ck_seen
        sta div_lo
        txa
        sbc ck_seen+1
        sta div_hi
        bmi _rts                ; (behind: a stop's place; it comes on to it)
        ora div_lo
        beq _same
        jmp clock_ahead
_same   tya                     ; at the song's start: its signature again
        ora ck_seen+1
        bne _rts
        ldx start_scene
        jmp ck_sig
_rts    rts

; -----------------------------------------------------------------------------
; clock_located - (CK_LOCATED) once the song is at the 16th located
; (locate.asm and the stop's pieces done: play_tick its tick): the bars
; before it (the walk's, its rounds x a round's: the rows from scene 1, and
; those in its scene), its place in the bar, its time (the 16th x 60
; units, / 4 x BPM); the text from 001.1 0:00 counted on to them.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
clock_located
        lda stop_phase
        ora loc_phase
        beq +
        rts
+
        jsr ck_reset            ; (the text from the start, the counts 0)
        lda locate_tick
        sta ck_seen
        lda locate_tick+1
        sta ck_seen+1
        lda ck_bars             ; the bars: the walk's (sc_x)
        sta sc_x
        lda ck_bars+1
        sta sc_x+1
        lda ck_q                ; with rounds: a round's (ck_bars), that many times
        ora ck_q+1
        beq _scene
        lda #0
        sta ck_bars
        sta ck_bars+1
        tax
-       jsr ck_add_bars
        inx
        cpx #NUM_SCENES
        bcs _round
        jsr scene_empty
        bne -
_round  clc
        lda sc_x
        adc ck_bars
        sta sc_x
        lda sc_x+1
        adc ck_bars+1
        sta sc_x+1
        lda ck_q
        bne +
        dec ck_q+1
+       dec ck_q
        lda ck_q
        ora ck_q+1
        bne _round
_scene  ldx loc_k               ; in its scene: (loc_t - loc_org) / its bar
        jsr ck_sig
        ldx loc_k
        jsr bar_passes          ; (sc_len)
        ldx #0
        sec
-       lda loc_t,x
        sbc loc_org,x
        sta sc_num,x
        inx
        txa
        eor #3
        bne -
        jsr sc_mod              ; sc_num: the bars before, sc_rem: the place
        clc
        lda sc_x
        adc sc_num
        sta sc_x
        lda sc_x+1
        adc sc_num+1
        sta sc_x+1
        lda sc_rem              ; the place: the beat, the ticks into it
        ldx sc_rem+1
        ldy #$ff
-       iny
        sec
        sbc ck_blen
        bcs -
        dex
        bpl -
        adc ck_blen             ; (carry clear: the last beat back)
        sta ck_bt
        sty ck_beat
        ldy #CK_BAR_LAST        ; the bar's digits, from 001 on
        jsr ck_up_n
        lda loc_16th            ; the time: the 16th's units / 4 x BPM
        sta sc_num
        lda loc_16th+1
        sta sc_num+1
        lda #0
        sta sc_num+2
        lda #CK_TICK_UNITS * TICKS_PER_STEP
        jsr sc_mul24
        lda ck_q4
        sta sc_len
        lda ck_q4+1
        sta sc_len+1
        jsr sc_mod              ; sc_num: the seconds, sc_rem: the rest
        lda sc_rem
        sta ck_frac
        lda sc_rem+1
        sta ck_frac+1
        lda sc_num
        sta sc_x
        lda sc_num+1
        sta sc_x+1
        ldy #CK_SECOND          ; the seconds' digits, from 0:00 on
        jsr ck_up_n
        jsr ck_beat_text
        jmp clock_count         ; (then on to the tick, if it plays already)

; -----------------------------------------------------------------------------
; clock_ahead - div ticks forward (1 or more): each one's time added (a
; second: ck_up), its beat on, a bar at the beats' end (the next bar's
; signature the playing scene's), ck_seen on. The title marked to draw at
; a change.
; clobbers A, X, Y, div_lo, div_hi
; -----------------------------------------------------------------------------
clock_ahead
_tick   clc                     ; the time: 5 units, a second at 4 x BPM
        lda ck_frac
        adc #CK_TICK_UNITS
        sta ck_frac
        bcc +
        inc ck_frac+1
+       cmp ck_q4
        lda ck_frac+1
        sbc ck_q4+1
        bcc _place
        sta ck_frac+1
        lda ck_frac
        sbc ck_q4               ; (carry set)
        sta ck_frac
        ldx #CK_SECOND
        jsr ck_up
        inc ck_ver              ; (the title to draw)
_place  inc ck_bt               ; the beat
        lda ck_bt
        cmp ck_blen
        bcc _next
        lda #0
        sta ck_bt
        inc ck_beat
        lda ck_beat
        cmp ck_beats
        bcc _beat
        lda #0                  ; a bar
        sta ck_beat
        ldx #CK_BAR_LAST
        jsr ck_up
        ldx play_scene
        jsr ck_sig
_beat   jsr ck_beat_text
_next   inc ck_seen             ; (counted to: a tick at a time, with the text)
        bne +
        inc ck_seen+1
+       lda div_lo              ; div - 1
        bne +
        dec div_hi
+       dec div_lo
        lda div_lo
        ora div_hi
        bne _tick
        rts

; -----------------------------------------------------------------------------
; ck_reset - (a jump; clock_init) the song's start: the text "001.1  0:00"
; (ck_start), every count 0 (the jump taken), the start scene's
; signature; the title marked to draw. clobbers A, X, Y
; -----------------------------------------------------------------------------
ck_reset
        ldx #CK_TEXT_LEN-1
-       lda ck_start,x
        sta ck_text,x
        dex
        bpl -
        lda #0
        ldx #ck_zero_end-ck_seen-1
-       sta ck_seen,x
        dex
        bpl -
        inc ck_ver              ; (the title to draw)
        ldx start_scene
        ; (on into ck_sig)

; ck_sig - ck_beats, ck_blen: scene X's beats and a beat's ticks. clobbers A, X
ck_sig
        jsr sig_beats           ; A: beats (1-16), X: a beat's ticks
        sta ck_beats
        stx ck_blen
        rts

; ck_beat_text - the beat's 1 or 2 digits (ck_beat + 1) into the text; the
; title marked. clobbers A, X, Y
ck_beat_text
        ldx ck_beat
        inx
        txa
        cmp #10
        bcc +
        sbc #10                 ; (carry set) 10-16: a 1 and the ones
        ora #CHAR_DIGIT0
        sta ck_text+CK_BEAT+1
        lda #CHAR_DIGIT0+1
        bne ++
+       ora #CHAR_DIGIT0        ; 1-9: the digit and a space
        ldx #CK_BLANK
        stx ck_text+CK_BEAT+1
+       sta ck_text+CK_BEAT
        inc ck_ver              ; (the title to draw)
        rts

; ck_up - the number ending at ck_text's place X one up: each digit past
; its top back to 0 and the one before it up (the colon passed over; a
; blank, the minutes' tens, as 0), up to the first place that isn't a
; digit (the bar's: 999 on to 000). clobbers A, X
ck_up   lda ck_top,x
        beq _rts                ; (not a digit: the number's start)
        bmi _on                 ; (the colon)
        lda ck_text,x
        ora #CHAR_DIGIT0        ; (a blank: 0)
        cmp ck_top,x
        bcc _inc
        lda #CHAR_DIGIT0
        sta ck_text,x
_on     dex
        bpl ck_up
_rts    rts
_inc    adc #1                  ; (carry clear)
        sta ck_text,x
        rts
ck_top  .byte CHAR_DIGIT0+9, CHAR_DIGIT0+9, CHAR_DIGIT0+9, 0 ; the bar, the dot
        .byte 0, 0              ; the beat (ck_beat_text's)
        .byte CHAR_DIGIT0+9, CHAR_DIGIT0+9, $ff ; the minutes (0-99), the colon
        .byte CHAR_DIGIT0+5, CHAR_DIGIT0+9 ; the seconds
        .cerror * - ck_top != CK_TEXT_LEN, "ck_top: a byte a place"
        .enc "screen"
ck_start .text "001.1  0:00"    ; (the title's is under I/O)
        .enc "none"
        .cerror * - ck_start != CK_TEXT_LEN, "ck_start: the text's length"

; ck_up_n - the number ending at ck_text's place Y up sc_x (a word) times.
; clobbers A, X, sc_x
ck_up_n
-       lda sc_x
        ora sc_x+1
        beq _rts
        tya
        tax
        jsr ck_up
        lda sc_x
        bne +
        dec sc_x+1
+       dec sc_x
        jmp -
_rts    rts
        .send
