; presets.asm - part of SID101, included by sid101.asm
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Presets: 32 slots, each the 34 sound parameters (Cutoff to Volume) and a
; 12-character name, in PRESET_RAM. At start they are the factory set
; (presets.inc from tables.py, at the program's very end: copied here
; first, so the test logs may later overwrite it). On the parameter screen
; (core PARAM_SYNTH_KEYS: synth_param_key sees the keys first):
;   C= + F3 / F4     the next / previous preset (recall)
;   C= + RETURN      store: the status row asks for the slot (F3/F4) and the
;                    name (typed; SHIFT for capitals), RETURN stores, RUN/STOP
;                    cancels
;   C= + W / L       save / load the whole bank as a file of its own (its
;                    own name, at first "bank"), through disk.asm
; MIDI program change 0..31 recalls a preset (core MIDI_PROGRAM:
; synth_program); higher programs are ignored.
;
; A recall sets every sound parameter but Mod wheel (where the wheel is),
; Tune and Volume (setup): they are stored but never recalled. The title
; row shows the preset's number, '*' once the sound is changed after the
; recall or store (a knob, a key, a song or bank load), and its name.

PRESET_RAM      = $c900         ; NUM_PRESETS x PRESET_BYTES values, then the names
PRESET_NAMES    = PRESET_RAM + NUM_PRESETS * PRESET_BYTES
PRESET_END      = PRESET_NAMES + NUM_PRESETS * PRESET_NAME_LEN
BANK_V1_END     = PRESET_RAM + NUM_PRESETS * (SOUND_PARAMS_V1 + PRESET_NAME_LEN)
                                ; a version 1 bank's end (disk.asm, bank_upgrade)
        .cerror PRESET_END > $d000, "the presets run into I/O"
        .cerror factory_end - factory_presets != PRESET_END - PRESET_RAM, "presets.inc: the wrong size"
        .cerror PRESET_BYTES != P_VOLUME + 1, "a preset is Cutoff to Volume"

; the prompt's RAM, after steps_msg ($C800-$C827, undo.asm)
preset_name_buf = $c840         ; PRESET_NAME_LEN screen codes: the store prompt's name
prompt_bits     = $c850         ; 8 bytes, a bit per key code: pressed while a prompt was up
bank_name       = $c860         ; NAME_MAX bytes (PETSCII): the bank file's name
bank_name_len   = bank_name + NAME_MAX
song_name_copy  = $c880         ; NAME_MAX + 1: the song file's name, kept over a bank operation
        .cerror song_name_copy + NAME_MAX + 1 > PRESET_RAM, "preset prompt RAM runs into the presets"

PMODE_NONE      = 0             ; preset_mode: no prompt
PMODE_STORE     = 1             ; the store prompt
PMODE_BANK_SAVE = 2             ; the bank file's name, to save
PMODE_BANK_LOAD = 3             ; ... to load
RECALL_GATES    = 1             ; preset_recall: gates_write due
RECALL_VOICE    = 2             ; ... voice 2's frequency again
RECALL_ARP      = 4             ; ... arp_param_changed
PRESET_COL      = 12            ; title row: the preset's number, '*', its name
CHAR_STAR       = $2a           ; screen code '*'
LETTER_PETSCII  = $41           ; name_chars: letters from here (PETSCII 'A'..'Z' = screen
                                ; codes of the capitals; minus $40 = the small letters)

        .weak
TEST_PRESET_LOG = 0             ; 1 = every recall logs (slot | $80 if the sound was edited
        .endweak                ; before, then the 34 values after) at PRESET_LOG
PRESET_LOG      = UNDO_RAM      ; (tools/preset_check.py: its runs never undo)
PRESET_LOG_END  = PATTERN_RAM

; the presets' variables (zero page is full), after the prompt's RAM
        .virtual $c8a0
.if TEST_PRESET_LOG
plog_ptr        .word ?         ; TEST_PRESET_LOG: the next entry (copied to ptr to write)
plog_edited     .byte ?         ; ... preset_edited before the recall
.endif
preset_cur      .byte ?         ; the preset recalled or stored last, 0..31
preset_edited   .byte ?         ; nonzero: the sound changed since
preset_mode     .byte ?         ; PMODE_*: the prompt up on the status row
preset_dest     .byte ?         ; the store prompt: the slot, 0..31
preset_name_len .byte ?         ; the store prompt: characters in preset_name_buf
preset_msg_on   .byte ?         ; nonzero: the status row shows steps_msg (until a key)
preset_key      .byte ?         ; synth_param_key: the key code
preset_count    .byte ?         ; preset_recall, bank_check: a counter
presets_vars_end
        .endv
        .cerror presets_vars_end > PRESET_RAM, "the presets' variables run into the presets"

; =============================================================================
; Recall and store
; =============================================================================

; -----------------------------------------------------------------------------
; presets_init - the factory presets into PRESET_RAM (first in synth_init:
; before the test logs clear $5000-$6FFF, which may hold them), preset 1
; (the start sound) current, no prompt, the bank's name "bank".
; clobbers A, X, Y
; -----------------------------------------------------------------------------
presets_init
        lda #<factory_presets
        sta ptr
        lda #>factory_presets
        sta ptr+1
        lda #<PRESET_RAM
        sta cptr
        lda #>PRESET_RAM
        sta cptr+1
        ldy #0
-       lda (ptr),y
        sta (cptr),y
        inc ptr
        bne +
        inc ptr+1
+       inc cptr
        bne +
        inc cptr+1
+       lda cptr
        cmp #<PRESET_END
        bne -
        lda cptr+1
        cmp #>PRESET_END
        bne -
        lda #0
        sta preset_cur
        sta preset_edited
        sta preset_mode
        sta preset_msg_on
        ldx #7                  ; no key pressed in a prompt
-       sta prompt_bits,x
        dex
        bpl -
.if TEST_PRESET_LOG
        sta plog_ptr            ; the log empty: PRESET_LOG..PRESET_LOG_END cleared
        sta ptr
        tay
        lda #>PRESET_LOG
        sta plog_ptr+1
        sta ptr+1
        lda #0
-       sta (ptr),y
        iny
        bne -
        inc ptr+1
        ldx ptr+1
        cpx #>PRESET_LOG_END
        bcc -
.endif
        ldx #DEFAULT_BANK_LEN
        stx bank_name_len
        dex
-       lda default_bank,x
        sta bank_name,x
        dex
        bpl -
        rts

; -----------------------------------------------------------------------------
; preset_ptr - ptr = slot A's values (PRESET_RAM + A x 34 = A x 32 + A x 2).
; clobbers A
; -----------------------------------------------------------------------------
preset_ptr
        asl                     ; x 2 (slot < 32: fits a byte)
        sta tmp
        lda #0
        sta ptr+1
        lda tmp
        asl                     ; x 4
        asl                     ; x 8
        asl                     ; x 16 (10 bits from here)
        rol ptr+1
        asl                     ; x 32
        rol ptr+1
        clc                     ; + x 2
        adc tmp
        bcc +
        inc ptr+1
+       clc
        adc #<PRESET_RAM
        sta ptr
        lda ptr+1
        adc #>PRESET_RAM
        sta ptr+1
        rts
        .cerror PRESET_BYTES != 34, "preset_ptr multiplies by 34"

; -----------------------------------------------------------------------------
; name_ptr - ptr = slot A's name (PRESET_NAMES + A x 12 = A x 8 + A x 4).
; clobbers A
; -----------------------------------------------------------------------------
name_ptr
        asl                     ; x 4 (slot < 32: fits a byte)
        asl
        sta tmp
        asl                     ; x 8 (up to 248)
        clc
        adc tmp                 ; x 12: up to 372, carry = bit 8
        sta ptr
        lda #0
        adc #0
        sta ptr+1
        lda ptr
        clc
        adc #<PRESET_NAMES
        sta ptr
        lda ptr+1
        adc #>PRESET_NAMES
        sta ptr+1
        rts

; -----------------------------------------------------------------------------
; recalled - is parameter Y one a recall sets? Out: Z clear = yes (A
; nonzero), Z set = no (Mod wheel, Tune, Volume, the setup). keeps X, Y
; -----------------------------------------------------------------------------
recalled
        cpy #PRESET_BYTES
        bcs _no
        cpy #P_MODWHEEL
        beq _no
        cpy #P_TUNE
        beq _no
        cpy #P_VOLUME
        beq _no
        lda #1
        rts
_no     lda #0
        rts

; -----------------------------------------------------------------------------
; preset_recall - slot A becomes the sound: its values into params (all
; but Mod wheel, Tune, Volume), and the title row shows it, not edited.
; Of the sound parameters only these have side effects (hooks.asm
; synth_param_changed), run once each and only if a value changed, so a
; recall stays short under load (tools/preset_check.py): Voice mode (voice
; 2's frequency again), Saw / Pulse / Sub / Voice mode (gates_write), and
; Arpeggio (arp_param_changed). The rest take effect from the next tick.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
preset_recall
.if TEST_PRESET_LOG
        ldx preset_edited
        stx plog_edited
.endif
        sta preset_cur
        jsr preset_ptr
        lda #0
        sta preset_count        ; (here: the side effects due, RECALL_* bits)
        ldy #PRESET_BYTES-1
_copy   jsr recalled
        beq _next
        lda (ptr),y
        cmp params,y
        beq _next               ; the same value: nothing to do
        sta params,y
        ldx #RECALL_GATES       ; which side effect the change asks for
        cpy #P_VOICEMODE
        bne +
        ldx #RECALL_GATES | RECALL_VOICE
+       cpy #P_ARP
        bne +
        ldx #RECALL_ARP
+       cpy #P_SAW
        bcc +
        cpy #P_SUB+1
        bcc ++
+       cpx #RECALL_GATES       ; neither Voice mode nor Saw..Sub: no gates
        bne +
        ldx #0
+       txa
        ora preset_count
        sta preset_count
_next   dey
        bpl _copy

        lda preset_count        ; the side effects, once each
        and #RECALL_VOICE
        beq +
        lda #$ff                ; voice 2's frequency again (pitch_to_sid),
        sta pitch_last+1
        jsr echo_clear          ; C64 mode's echo silent
+       lda preset_count
        and #RECALL_GATES
        beq +
        jsr gates_write         ; the voices' waveforms and gates
+       lda preset_count
        and #RECALL_ARP
        beq +
        jsr arp_param_changed
+       jsr chord_build         ; C64 mode: the chord for the keys held (Chord, Voice mode)
        lda #0
        sta preset_edited
.if TEST_PRESET_LOG
        lda plog_ptr+1          ; the log full?
        cmp #>PRESET_LOG_END
        bcs _logged
        lda plog_ptr
        sta ptr
        lda plog_ptr+1
        sta ptr+1
        lda preset_cur
        ldx plog_edited
        beq +
        ora #$80
+       ldy #0
        sta (ptr),y
-       lda params,y
        iny
        sta (ptr),y
        cpy #PRESET_BYTES
        bne -
        lda plog_ptr
        clc
        adc #PRESET_BYTES+1
        sta plog_ptr
        bcc _logged
        inc plog_ptr+1
_logged
.endif
        rts

; -----------------------------------------------------------------------------
; preset_store - the sound (all 34 values) and preset_name_buf into slot
; preset_dest, which becomes the current preset, not edited.
; clobbers A, Y
; -----------------------------------------------------------------------------
preset_store
        lda preset_dest
        sta preset_cur
        jsr preset_ptr
        ldy #PRESET_BYTES-1
-       lda params,y
        sta (ptr),y
        dey
        bpl -
        lda preset_dest
        jsr name_ptr
        ldy #PRESET_NAME_LEN-1
-       lda #CHAR_SPACE         ; the name, padded with spaces
        cpy preset_name_len
        bcs +
        lda preset_name_buf,y
+       sta (ptr),y
        dey
        bpl -
        lda #0
        sta preset_edited
        rts

; -----------------------------------------------------------------------------
; preset_touched - from synth_param_changed: parameter Y changed. A sound
; parameter a recall sets marks the preset edited. keeps X, Y
; -----------------------------------------------------------------------------
preset_touched
        jsr recalled
        beq +
        sta preset_edited       ; (A = 1)
+       rts

; -----------------------------------------------------------------------------
; synth_program - MIDI program change (core MIDI_PROGRAM): A = 0..127.
; Programs 0..31 recall that preset; the others are ignored.
; -----------------------------------------------------------------------------
synth_program
        cmp #NUM_PRESETS
        bcs +
        jmp preset_recall
+       rts

; =============================================================================
; Keys (core PARAM_SYNTH_KEYS: the parameter screen's keys come here first)
; =============================================================================

; -----------------------------------------------------------------------------
; synth_param_key - A: key code, want_press. Out: carry set = used.
; A release whose press went to a prompt is eaten (even after the prompt
; closed); other releases go on to the core (a held note ends). With a
; prompt up every press is the prompt's. Without one, a press clears a
; message, and C= + F3/F4, RETURN, W, L are the presets'.
; -----------------------------------------------------------------------------
synth_param_key
        sta preset_key
        lsr
        lsr
        lsr
        tax                     ; X = the key's byte in prompt_bits,
        lda preset_key
        and #7
        tay                     ; Y = its bit
        lda want_press
        bne _press
        lda bit_masks,y         ; a release: eaten if its press was a prompt's
        and prompt_bits,x
        beq _pass
        eor prompt_bits,x
        sta prompt_bits,x
        sec
        rts

_press  lda preset_mode
        beq _keys
        lda bit_masks,y         ; a prompt: the press is its own
        ora prompt_bits,x
        sta prompt_bits,x
        jsr prompt_press
        sec
        rts

_keys   lda #0
        sta preset_msg_on       ; a key: the message goes
        lda key_now+KC_CBM/8    ; C= held?
        and #1 << (KC_CBM % 8)
        beq _pass
        lda preset_key
        cmp #KC_F3
        beq _step
        cmp #KC_RETURN
        beq _store
        cmp #KC_W
        beq _bank_save
        cmp #KC_L
        beq _bank_load
        cmp #KC_M
        beq _bank_dump
_pass   clc
        rts

        ; C= + M: the bank as a SysEx dump (src/dumps.asm)
_bank_dump
        lda #DUMP_BANK
        jsr synth_sysex_request
        sec
        rts

        ; C= + F3: the next preset; SHIFT (F4): the previous
_step   ldx preset_cur
        inx
        lda shift_held
        beq +
        dex
        dex
+       txa
        and #NUM_PRESETS-1      ; (32: wraps both ways)
        jsr preset_recall
        sec
        rts

        ; C= + RETURN: the store prompt, on the current slot with its name
_store  lda preset_cur
        sta preset_dest
        jsr name_ptr
        ldy #0
        ldx #0                  ; the name's length without the trailing spaces
-       lda (ptr),y
        sta preset_name_buf,y
        iny
        cmp #CHAR_SPACE
        beq +
        tya
        tax
+       cpy #PRESET_NAME_LEN
        bne -
        stx preset_name_len
        lda #PMODE_STORE
        sta preset_mode
        sec
        rts

        ; C= + W / L: the bank file's name prompt
_bank_save
        lda #PMODE_BANK_SAVE
        .byte $2c               ; bit abs: skips the next lda
_bank_load
        lda #PMODE_BANK_LOAD
        sta preset_mode
        sec
        rts

; -----------------------------------------------------------------------------
; prompt_press - a key pressed while a prompt is up (preset_key).
; RUN/STOP: cancel. RETURN: store / save / load. DEL: delete a character.
; F3/F4 (store): the slot. A name character: typed.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
prompt_press
        lda preset_key
        cmp #KC_STOP
        beq _cancel
        cmp #KC_RETURN
        beq _go
        cmp #KC_DEL
        beq _delete
        ldx preset_mode
        cpx #PMODE_STORE
        bne _bank_char
        cmp #KC_F3
        beq _slot

        ; a character of the preset's name: screen codes, SHIFT for capitals
        tax
        lda name_chars,x
        beq _done
        cmp #LETTER_PETSCII
        bcc +                   ; digits, space, + - .: the same code
        ldx shift_held
        bne +                   ; capital: the PETSCII value is its screen code
        sec
        sbc #LETTER_PETSCII - 1 ; small letter: $01..$1A
+       ldx preset_name_len
        cpx #PRESET_NAME_LEN
        bcs _done
        sta preset_name_buf,x
        inc preset_name_len
_done   rts

        ; a character of the bank file's name (PETSCII, as disk.asm's)
_bank_char
        tax
        lda name_chars,x
        beq _done
        ldx bank_name_len
        cpx #NAME_MAX
        bcs _done
        sta bank_name,x
        inc bank_name_len
        rts

_slot   ldx preset_dest         ; F3: the next slot, F4 the previous
        inx
        lda shift_held
        beq +
        dex
        dex
+       txa
        and #NUM_PRESETS-1
        sta preset_dest
        rts

_delete ldx preset_mode
        cpx #PMODE_STORE
        bne +
        lda preset_name_len
        beq _done
        dec preset_name_len
        rts
+       lda bank_name_len
        beq _done
        dec bank_name_len
        rts

_cancel lda #PMODE_NONE
        sta preset_mode
        rts

_go     lda preset_mode
        cmp #PMODE_STORE
        bne _bank
        lda #PMODE_NONE
        sta preset_mode
        jmp preset_store
_bank   lda bank_name_len
        beq _done               ; no name
        jmp bank_run

; =============================================================================
; The bank file
; =============================================================================

; -----------------------------------------------------------------------------
; bank_run - save or load the bank (preset_mode) under bank_name, through
; disk_run: the song file's name is kept aside meanwhile. The status row
; shows "SAVING..." / "LOADING..." while it runs, then the drive's message
; (steps_msg, until a key). A load makes the bank safe (bank_check) and
; the sound counts as edited (it no longer is a slot's).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
bank_run
        ldx #NAME_MAX           ; the song's name and its length aside,
-       lda disk_name,x         ; the bank's in
        sta song_name_copy,x
        lda bank_name,x
        sta disk_name,x
        dex
        bpl -
        ldx #DISK_BANK_SAVE
        lda preset_mode
        cmp #PMODE_BANK_SAVE
        beq +
        ldx #DISK_BANK_LOAD
+       stx disk_kind
        lda #PMODE_NONE
        sta preset_mode

        ; "SAVING..." / "LOADING..." on the status row, now
        ldx #39
        lda #CHAR_SPACE
-       sta SCREEN+STATUS_ROW*40,x
        dex
        bpl -
        ldx #0
        lda disk_kind
        cmp #DISK_BANK_SAVE
        beq +
        ldx #busy_load - busy_texts
+       ldy #0
-       lda busy_texts,x
        sta SCREEN+STATUS_ROW*40,y
        inx
        iny
        cpy #BUSY_LEN
        bne -

        jsr disk_run
        ldx #NAME_MAX           ; the names back
-       lda song_name_copy,x
        sta disk_name,x
        dex
        bpl -
        lda #0
        sta msg_on              ; the message is the status row's, not the song row's
        lda #1
        sta preset_msg_on
        lda disk_kind
        cmp #DISK_BANK_LOAD
        bne +
        lda disk_error
        bne +                   ; not a bank: nothing came in
        lda #1
        sta preset_edited
        jmp bank_loaded
+       rts

; -----------------------------------------------------------------------------
; bank_loaded - after a bank came in (disk or SysEx), version disk_version:
; a version 1 bank made version 2 (bank_upgrade), then made safe
; (bank_check). clobbers A, X, Y
; -----------------------------------------------------------------------------
bank_loaded
        lda disk_version
        cmp #2
        bcs bank_check
        jsr bank_upgrade
        jmp bank_check

; -----------------------------------------------------------------------------
; bank_upgrade - a version 1 bank, as loaded at PRESET_RAM..BANK_V1_END
; (SOUND_PARAMS_V1 values a preset, then the names), into this version's
; layout in place: from the end down (everything moves up), the names, then
; each preset's values with the defaults of P_V2_FIRST..P_V2_LAST put in.
; clobbers A, X, Y
; -----------------------------------------------------------------------------
bank_upgrade
        lda #<BANK_V1_END       ; ptr: the old byte, cptr: its new place
        sta ptr
        lda #>BANK_V1_END
        sta ptr+1
        lda #<PRESET_END
        sta cptr
        lda #>PRESET_END
        sta cptr+1
        ldy #0
        ; the names
_name   jsr _src_down
        lda (ptr),y
        jsr _dst_down
        lda cptr
        cmp #<PRESET_NAMES
        bne _name
        lda cptr+1
        cmp #>PRESET_NAMES
        bne _name
        ; the presets' values, the last first
_preset lda #PRESET_BYTES-1
        sta preset_count
_value  ldx preset_count
        lda param_default,x     ; a new one: its default
        cpx #P_V2_FIRST
        bcc _old
        cpx #P_V2_LAST+1
        bcc _new
_old    jsr _src_down           ; an old one: from the file
        lda (ptr),y
_new    jsr _dst_down
        dec preset_count
        bpl _value
        lda cptr
        cmp #<PRESET_RAM
        bne _preset
        lda cptr+1
        cmp #>PRESET_RAM
        bne _preset
        rts

        ; ptr one down. clobbers A
_src_down
        lda ptr
        bne +
        dec ptr+1
+       dec ptr
        rts

        ; cptr one down, then A there. Y = 0
_dst_down
        pha
        lda cptr
        bne +
        dec cptr+1
+       dec cptr
        pla
        sta (cptr),y
        rts

; -----------------------------------------------------------------------------
; bank_check - after a bank load: every value within its parameter's range
; (a damaged or foreign file can't put the synth in a state it can't be in).
; clobbers A, X, Y
; -----------------------------------------------------------------------------
bank_check
        lda #NUM_PRESETS-1
        sta preset_count
-       lda preset_count
        jsr preset_ptr
        ldy #PRESET_BYTES-1
_value  lda (ptr),y
        cmp param_max,y
        bcc +
        beq +
        lda param_max,y
        sta (ptr),y
+       dey
        bpl _value
        dec preset_count
        bpl -
        rts

; =============================================================================
; The title row and the status row
; =============================================================================

; -----------------------------------------------------------------------------
; draw_preset_title - on the parameter screen, the title row's preset
; field: the number (01..32), '*' if edited, the name. clobbers A, X, Y
; -----------------------------------------------------------------------------
draw_preset_title
        lda ptr                 ; (ptr: the status row's, kept)
        pha
        lda ptr+1
        pha
        lda preset_cur
        clc
        adc #1
        ldx #CHAR_ZERO-1        ; tens
        sec
-       inx
        sbc #10
        bcs -
        adc #10+CHAR_ZERO       ; carry clear: units
        stx SCREEN+TITLE_ROW*40+PRESET_COL
        sta SCREEN+TITLE_ROW*40+PRESET_COL+1
        lda #CHAR_SPACE
        ldx preset_edited
        beq +
        lda #CHAR_STAR
+       sta SCREEN+TITLE_ROW*40+PRESET_COL+2
        lda preset_cur
        jsr name_ptr
        ldy #PRESET_NAME_LEN-1
-       lda (ptr),y
        sta SCREEN+TITLE_ROW*40+PRESET_COL+3,y
        dey
        bpl -
        pla
        sta ptr+1
        pla
        sta ptr
        rts

; -----------------------------------------------------------------------------
; draw_preset_prompt - the status row ((ptr), its colour set) while a prompt
; is up, reversed: "STORE TO 05: name_   F3/F4 slot" or "SAVE BANK 8:
; name_" / "LOAD BANK 8: name_". Out: carry set = drawn (a prompt or the
; message is up), clear = not (the normal status). clobbers A, X, Y
; -----------------------------------------------------------------------------
draw_preset_prompt
        lda preset_mode
        bne _prompt
        lda preset_msg_on
        bne _message
        clc
        rts

_message
        ldy #39
-       lda steps_msg,y
        sta (ptr),y
        dey
        bpl -
        sec
        rts

_prompt ldy #39                 ; reversed blanks
        lda #CHAR_SPACE | REVERSE
-       sta (ptr),y
        dey
        bpl -
        lda preset_mode
        cmp #PMODE_STORE
        bne _bank

        ; STORE TO nn: name_   F3/F4 slot
        ldy #0
-       lda store_text,y
        ora #REVERSE
        sta (ptr),y
        iny
        cpy #STORE_TEXT_LEN
        bne -
        lda preset_dest
        clc
        adc #1
        ldx #CHAR_ZERO-1
        sec
-       inx
        sbc #10
        bcs -
        adc #10+CHAR_ZERO
        ora #REVERSE
        pha
        txa
        ora #REVERSE
        sta (ptr),y
        iny
        pla
        sta (ptr),y
        iny
        lda #CHAR_COLON | REVERSE
        sta (ptr),y
        iny
        iny
        ldx #0
-       cpx preset_name_len
        beq +
        lda preset_name_buf,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        bne -                   ; always
+       lda #CHAR_SPACE         ; the cursor (not reversed)
        sta (ptr),y
        ldy #40-STORE_HINT_LEN
        ldx #0
-       lda store_hint,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        cpy #40
        bne -
        sec
        rts

        ; SAVE BANK 8: name_ / LOAD BANK 8: name_
_bank   ldx #0
        cmp #PMODE_BANK_SAVE
        beq +
        ldx #prompt_load - prompt_texts
+       ldy #0
-       lda prompt_texts,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        cpy #PROMPT_LEN
        bne -
        ldx #0
-       lda bank_text,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        cpx #BANK_TEXT_LEN
        bne -
        jsr drive_digits
        ldx #0
-       lda drive_text,x
        ora #REVERSE
        sta (ptr),y
        iny
        inx
        cpx drive_text_len
        bne -
        lda #CHAR_COLON | REVERSE
        sta (ptr),y
        iny
        iny
        ldx #0                  ; the name (screen code = PETSCII here)
-       cpx bank_name_len
        beq +
        lda bank_name,x
        ora #REVERSE
        sta (ptr),y
        inx
        iny
        bne -                   ; always
+       lda #CHAR_SPACE         ; the cursor (not reversed)
        sta (ptr),y
        sec
        rts

; =============================================================================
; Tables and texts
; =============================================================================

bit_masks       .byte 1, 2, 4, 8, 16, 32, 64, 128
default_bank    .text "bank"    ; (64tass -a: lowercase source = plain PETSCII)
DEFAULT_BANK_LEN = * - default_bank
        .enc "screen"
store_text      .text "STORE TO "
STORE_TEXT_LEN  = * - store_text
store_hint      .text "F3/F4 slot "
STORE_HINT_LEN  = * - store_hint
bank_text       .text "BANK "
BANK_TEXT_LEN   = * - bank_text
        .enc "none"
