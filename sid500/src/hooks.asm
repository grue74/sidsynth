; hooks.asm - SID500's hooks called by the core
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The core calls: synth_init (sid500.asm), synth_timer, synth_rt_irq,
; synth_tx_byte (timing.asm), and these. Stage A: the notes from MIDI in
; and the keys aren't used yet (recording is stage D).

; -----------------------------------------------------------------------------
; synth_tick - 250 times a second from the main loop: the player's ticks
; rendered ahead, a step at a time (render.asm; the timer interrupt
; releases them); the live switch (live.asm); in test builds the bursts.
; -----------------------------------------------------------------------------
synth_tick
.if TEST_BURST
        jsr burst_tick
.endif
        jsr locate_poll         ; a slave's stop, start or continue to finish (locate.asm:
                                ; a song position located first)
        jsr thru_poll           ; what waits in thru's queue (record.asm)
        jsr clock_poll          ; the time display brought to the tick heard (clock.asm:
                                ; after thru, which mustn't wait for it)
        jsr song_urgent         ; the cursor's row drawn soon (the editor's rule 2)
.if TEST_LIVE
        jsr test_live_tick      ; (tests: the playing scene's cells changed)
.endif
        jsr live_slice          ; a changed cell of the playing scene heard at once
        jsr count_poll          ; the count-in (count.asm); a take's messages, its merges
                                ; begun (take.asm rec_poll)
        jsr grid_slice          ; the step grid's pattern decoded (a take's merged)
.if TEST_SWITCH
        jsr test_switch
.endif
        jmp render_slice

; -----------------------------------------------------------------------------
; note_on, note_off - a note from MIDI in (A = note, X = velocity) or a
; note key (on the song screen: the core's): on the step grid, step entry
; (grid.asm grid_midi_on, grid_midi_off); else nothing yet (stage D
; records them). all_notes_off - F8, RUN/STOP, CC 120/123: no key held
; for step entry (nothing sounds).
; -----------------------------------------------------------------------------
note_on         = list_midi_on  ; (list.asm: grid_midi_on on the step grid)
note_off        = list_midi_off ; (grid_midi_off)
all_notes_off
        lda #0
        sta grid_held
        rts

; synth_command - F7 (core CMD_SYNTH) on the parameter screen: the song screen.
synth_command   = song_take

; -----------------------------------------------------------------------------
; synth_param_changed - side effects of the parameters, from core
; param_changed. Y: the parameter that changed. Tempo: the player's period;
; Swing: the player's swing; Clock: the player starts again, as master or
; as slave.
; -----------------------------------------------------------------------------
synth_param_changed
        cpy #P_TEMPO
        bne +
        jmp player_set_tempo
+       cpy #P_SWING
        bne +
        jmp player_set_swing
+       cpy #P_CLOCK
        bne +
        jmp player_restart
+       cpy #P_THRU
        bne +
        lda params+P_THRU
        bne +
        jmp thru_all_off        ; (Off: nothing left sounding)
+       rts

; -----------------------------------------------------------------------------
; synth_draw_status - the status row (ptr set to it by core draw_status).
; -----------------------------------------------------------------------------
synth_draw_status
        ldy #39
-       lda status_text,y
        sta (ptr),y
        dey
        bpl -
        rts
