#+feature dynamic-literals
package compiler

// ModR/M Byte: [ mod: 2 bits ][ reg: 3 bits ][ rm: 3 bits ]
// SIB Byte:    [ scale: 2 bits ][ index: 3 bits ][ base: 3 bits ]

Mod :: enum u8 {
	Indirect       = 0b00, // [reg]
	Disp8          = 0b01, // [reg + d8]
	Disp32         = 0b10, // [reg + d32]
	DirectRegister = 0b11, // reg
}

encode_modrm :: proc(mod: Mod, reg: u8, rm: u8) -> u8 {
	return (u8(mod) << 6) | ((reg & 0b111) << 3) | (rm & 0b111)
}

encode_sib :: proc(scale: u8, index: u8, base: u8) -> u8 {
	// scale: 0=1, 1=2, 2=4, 3=8
	s_bits: u8
	switch scale {
	case 1: s_bits = 0
	case 2: s_bits = 1
	case 4: s_bits = 2
	case 8: s_bits = 3
	}
	return (s_bits << 6) | ((index & 0b111) << 3) | (base & 0b111)
}

// REX Prefix: [ 0100 ][ W ][ R ][ X ][ B ]
// W: 1 = 64-bit operand size
// R: Extension of ModR/M 'reg' field (bit 3)
// X: Extension of SIB 'index' field (bit 3)
// B: Extension of ModR/M 'r/m', SIB 'base', or opcode 'reg' field (bit 3)

encode_rex :: proc(w, r, x, b: bool) -> u8 {
	rex: u8 = 0b01000000
	if w do rex |= (1 << 3)
	if r do rex |= (1 << 2)
	if x do rex |= (1 << 1)
	if b do rex |= (1 << 0)
	return rex
}

// Register mapping for x86-64
// Note: r8-r15 set the REX.B/R/X bits.
reg_to_id := map[string]u8 {
	// 64-bit
	"rax" = 0, "rcx" = 1, "rdx" = 2, "rbx" = 3,
	"rsp" = 4, "rbp" = 5, "rsi" = 6, "rdi" = 7,
	"r8"  = 8, "r9"  = 9, "r10" = 10, "r11" = 11,
	"r12" = 12, "r13" = 13, "r14" = 14, "r15" = 15,
	// 32-bit
	"eax" = 0, "ecx" = 1, "edx" = 2, "ebx" = 3,
	"esp" = 4, "ebp" = 5, "esi" = 6, "edi" = 7,
	"r8d" = 8, "r9d" = 9, "r10d" = 10, "r11d" = 11,
	"r12d" = 12, "r13d" = 13, "r14d" = 14, "r15d" = 15,
	// 16-bit
	"ax" = 0, "cx" = 1, "dx" = 2, "bx" = 3,
	"sp" = 4, "bp" = 5, "si" = 6, "di" = 7,
	"r8w" = 8, "r9w" = 9, "r10w" = 10, "r11w" = 11,
	"r12w" = 12, "r13w" = 13, "r14w" = 14, "r15w" = 15,
	// 8-bit low (REX)
	"al" = 0, "cl" = 1, "dl" = 2, "bl" = 3,
	"spl" = 4, "bpl" = 5, "sil" = 6, "dil" = 7,
	"r8b" = 8, "r9b" = 9, "r10b" = 10, "r11b" = 11,
	"r12b" = 12, "r13b" = 13, "r14b" = 14, "r15b" = 15,
	// 8-bit high (no REX — legacy only)
	"ah" = 4, "ch" = 5, "dh" = 6, "bh" = 7,
	// XMM registers (0-15)
	"xmm0" = 0, "xmm1" = 1, "xmm2" = 2, "xmm3" = 3,
	"xmm4" = 4, "xmm5" = 5, "xmm6" = 6, "xmm7" = 7,
	"xmm8" = 8, "xmm9" = 9, "xmm10" = 10, "xmm11" = 11,
	"xmm12" = 12, "xmm13" = 13, "xmm14" = 14, "xmm15" = 15,
}

is_ext_reg :: proc(id: u8) -> bool {
	return id >= 8
}
