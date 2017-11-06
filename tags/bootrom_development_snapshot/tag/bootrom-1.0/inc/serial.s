;
;-------------------------------------------------------------------------------
;
; Translate some register names & offsets
;
DMAC		EQU	DMAC_BASE
DMAC_STATUS	EQU	TLM_DMAC_STAT
SYSC		EQU	SYSCTLR_BASE_B
SYSC_TUBE	EQU	SYSCTLR_TUBE
SYSC_IO_PORT	EQU	SYSCTLR_IO_PORT
SYSC_IO_DIR	EQU	SYSCTLR_IO_DIRECTION
SYSC_IO_SET	EQU	SYSCTLR_SET_IO
SYSC_IO_CLR	EQU	SYSCTLR_CLEAR_IO
SYSC_MISC_C	EQU	SYSCTLR_MISC_CONTROL
;
;
SYSC_IO_IN	EQU	SYSC_IO_SET
;
SERIAL_NCS	EQU	0x20	; Out
SERIAL_CLK	EQU	0x10	; Out
SERIAL_SI	EQU	0x08	; Out
SERIAL_SO	EQU	0x04	; In
;
SERIAL_OE	EQU	SERIAL_NCS + SERIAL_CLK + SERIAL_SI
;
;-------------------------------------------------------------------------------
;
boot_reset	MOV	r7, #DMAC		; r7 -> DMAC
		LDR	r1, [r7, #DMAC_STATUS] 	; read status reg
		MOV	r1, r1, LSR #24		; Get CPUID to 7:0
;
		MOV	r7, #SYSC		; r7 -> SYSC
		MVN	r0, #0
		STR	r0, [r7, #SYSC_IO_DIR]	; All GPIO pins -> inputs
		NOP	    	 		; Allow to settle?
;
		LDR	r0, [r7, #SYSC_IO_IN]	; Read inputs
;
		MOV	r0, r0, LSR #3		; CPU number is bit 3
		AND	r0, r0, #1  		; Only a single bit for CPU0/1
;
		CMP	r0, r1			; See if we are boot CPU
		BEQ	boot_serial		; Skip if so
;
;
; All CPUs except the one chosen to look for serial ROM loop here
; until MISC_CTRL bit 1 is set
;
;
boot_wait	LDR	r0, [r7, #SYSC_MISC_C]	; Else loop on MISC_CTRL bit 1
		TST	r0, #2
		BEQ	boot_wait
;
		B	boot_introm
;
;
boot_serial	MOV	r0, #SERIAL_NCS		; Config GPIO
		STR	r0, [r7, #SYSC_IO_PORT]	; Ncs high, others low
;
		MVN	r0, #SERIAL_OE		; Bits 5-3 output
		STR	r0, [r7, #SYSC_IO_DIR]
;
		BL	serial_boot		; May return, may not...
;
		MOV	r1, #SERIAL_NCS		; Tidy up GPIO
		STR	r1, [r7, #SYSC_IO_SET]	; Ncs -> high
;
		LDR	r0, [r7, #SYSC_MISC_C]
		ORR	r0, r0, #2
		STR	r0, [r7, #SYSC_MISC_C]
;
		B	boot_introm
;
;
;-------------------------------------------------------------------------------
;
; serial_boot
;
; Spinnaker interface to a 4 wire SPI serial ROM. Connections are
; to GPIO[5:2]. Bits 5:3 are outputs - NCS (chip select), SCK (clock),
; SI (shift in). Bit 2 is an input - SO (shift out).
;
; The code loads blocks of 32-bit data from serial ROM to arbitrary locations
; in the address space. Branch to an arbitrary address is also provided.
;
; Format of the data in the ROM is as follows.
;
;	ROM		= block*, end-mark
;	block  		= padding, block-mark, length, address, data
;	padding 	= 0x55*
;	block-mark 	= 0x3a
;	length 		= byte1, byte0 (16 bit big endian)
;	address 	= word
;	data 		= word*
;	word 		= byte3, byte2, byte1, byte0 (32 bit big endian)
;	end-mark	= ! (padding || block-mark)
;
; If length != 0, that many words follow "address". These words are
; loaded starting from "address". If length == 0, control branches to
; "address" (called as a subroutine - return reenters "serial_boot" at
; "scan_rom" - must preserve r5-r7).
;
; The routine returns the number of blocks loaded (0 most likely means there is
; no ROM present). It may never return if the ROM contains an 'execution' block.
;
; On entry r7 -> SYSC
;
;
serial_boot	MOV	r6, lr			; Save return address
		MOV	r5, #0			; Set block count
;
		MOV	r0, #SERIAL_NCS		; Ncs -> low
		STR	r0, [r7, #SYSC_IO_CLR]
;
		BL	serial_addr32		; Send read cmd & address
;
scan_rom	BL	serial_read8		; Read byte from ROM
;
;!!		STR	r0, [r7, #SYSC_TUBE]	; ** DEBUG **
;
		CMP	r0, #0x55		; Padding?
		BEQ	scan_rom
;
		CMP	r0, #0x3a		; Block marker?
		MOV	r0, r5			; Get return value
		MOVNE	pc, r6			; Return if not marker
;
		ADD	r5, r5, #1		; Bump block count
;
read_block	BL	serial_read16		; Get word count to r4
		MOV	r4, r0
;
		BL	serial_read32		; Get load/exec addr to r3
		MOV	r3, r0
;
		CMP	r4, #0			; Length zero - jump to exec addr
		ADREQ	lr, scan_rom		; Return (if ever) to scan_rom
		MOVEQ	pc, r3			; Go to exec addr
;
ser_loop	BL	serial_read32
		STR	r0, [r3], #4
;
;!!		MOV	r0, #"."
;!!		STR	r0, [r7, #SYSC_TUBE]	; ** DEBUG **
;
		SUBS	r4, r4, #1
		BNE	ser_loop
;
		B	scan_rom		; Look for another block
;
;
;-------------------------------------------------------------------------------
;
; res = serial_read8/16/32
;
;
serial_read8	MOV	r1, #8			; Read 8 bits (to r0)
		B	serial_read
;
serial_read16	MOV	r1, #16			; Read 16 bits (to r0)
		B	serial_read
;
serial_read32	MOV	r1, #32			; Read 32 bits (to r0)
;
serial_read	MOV	r0, #0			; Initialise result
;
rdl		LDR	r2, [r7, #SYSC_IO_IN]	; Read SO pin
		TST	r2, #SERIAL_SO 		; Test for high
		ADDNE	r0, r0, #1		; Bump r0 if so
		MOV	r2, #SERIAL_CLK		; CLK bit
		STR	r2, [r7, #SYSC_IO_SET]	; Clock high
		STR	r2, [r7, #SYSC_IO_CLR]	; then low
		SUBS	r1, r1, #1		; Drop count
		MOVNE	r0, r0, LSL #1		; Shift r0 left unless last
		BNE	rdl 			; and loop
		MOV	pc, lr
;
;-------------------------------------------------------------------------------
;
; serial_addr32
;
;
serial_addr32	MOV	r0, #0x03000000		; Read from address 0
		MOV	r1, #32			; Send 32 bits
;
wrl		TST	r0, #0x80000000		; Test top bit
		MOV	r0, r0, LSL #1		; then shift up
		MOV	r2, #SERIAL_SI 		; Data bit to r1
		STREQ	r2, [r7, #SYSC_IO_CLR]	; and set or clr
		STRNE	r2, [r7, #SYSC_IO_SET]	; appropriately
		MOV	r2, #SERIAL_CLK		; Pulse clock
		STR	r2, [r7, #SYSC_IO_SET]
		STR	r2, [r7, #SYSC_IO_CLR]
		SUBS	r1, r1, #1		; Drop count and loop
		BNE	wrl
		MOV	pc, lr
;
		END
