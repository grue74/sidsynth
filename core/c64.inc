; core/c64.inc - C64 hardware registers and values
; Part of the SID synth core shared by SID303 and SID808.
; Copyright (C) 2026 Jarkko Lehti
; SPDX-License-Identifier: GPL-3.0-or-later

; Hardware registers
; -----------------------------------------------------------------------------
SID_V1_FREQ_LO  = $d400
SID_V1_FREQ_HI  = $d401
SID_V1_PW_LO    = $d402
SID_V1_PW_HI    = $d403         ; bits 0-3 = pulse width bits 8-11
SID_V1_CTRL     = $d404         ; waveform bits 4-7, gate bit 0
SID_V1_AD       = $d405
SID_V1_SR       = $d406         ; sustain level bits 4-7, release bits 0-3
SID_V2_FREQ_LO  = $d407         ; voice 2: 303 square pulse
SID_V2_FREQ_HI  = $d408
SID_V2_PW_LO    = $d409
SID_V2_PW_HI    = $d40a
SID_V2_CTRL     = $d40b
SID_V2_SR       = $d40d
SID_V3_FREQ_LO  = $d40e         ; voice 3: body triangle
SID_V3_FREQ_HI  = $d40f
SID_V3_CTRL     = $d412
SID_V3_SR       = $d414
SID_CUTOFF_LO   = $d415         ; cutoff bits 0-2
SID_CUTOFF_HI   = $d416         ; cutoff bits 3-10
SID_RES_FILT    = $d417         ; resonance bits 4-7, voice routing bits 0-2
SID_MODE_VOL    = $d418         ; filter mode bits 4-6, master volume bits 0-3
SID_POTX        = $d419         ; paddle X of the port selected by CIA1 PA6/PA7
SID_POTY        = $d41a

VIC_CTRL1       = $d011
VIC_MEMSETUP    = $d018
VIC_IRQ_FLAG    = $d019
VIC_IRQ_MASK    = $d01a
VIC_BORDER      = $d020
VIC_BACKGROUND  = $d021

CIA1_PRA        = $dc00         ; out: keyboard column select (bits 0-7), paddle mux (bits 6-7)
CIA1_PRB        = $dc01         ; in : keyboard rows (0 = pressed)
CIA1_DDRA       = $dc02
CIA1_DDRB       = $dc03
CIA1_TA_LO      = $dc04
CIA1_TA_HI      = $dc05
CIA1_TB_LO      = $dc06
CIA1_TB_HI      = $dc07
CIA1_ICR        = $dc0d         ; read = acknowledge, bit 0 = timer A underflow
CIA1_CRA        = $dc0e
CIA1_CRB        = $dc0f
CIA2_ICR        = $dd0d

CPU_PORT        = $01
RAM_IO          = $35           ; $01 value: RAM under BASIC/KERNAL, I/O at $D000

VEC_NMI         = $fffa         ; hardware vectors, RAM since the KERNAL is off
VEC_IRQ         = $fffe

SCREEN          = $0400
COLOR_RAM       = $d800
CHARSET_MIXED   = $17           ; $D018: screen $0400, upper/lower case charset

; 6850 ACIA (MIDI cartridges) control register values
ACIA_RESET      = %00000011     ; master reset (also stops its interrupts)
ACIA_8N1_RXIRQ  = %10010100     ; bit 7 RX IRQ on, bits 4-2 = 101 (8 data, 1 stop), bits 1-0 divider
ACIA_DIV16      = %01           ; 500 kHz clock / 16 = 31250 baud
ACIA_DIV64      = %10           ; 2 MHz clock / 64 = 31250 baud
ACIA_RDRF       = %00000001     ; status bit 0: received byte waiting
ACIA_TDRE       = %00000010     ; status bit 1: transmit data register empty
ACIA_TXIRQ      = %00100000     ; control bits 6-5 = 01: RTS low, transmit interrupt on
; status bit 7 = ACIA is asserting its interrupt line
