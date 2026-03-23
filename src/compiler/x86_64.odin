#+feature dynamic-literals
package compiler

import "core:fmt"
import "core:strings"

// ================================================================
// Buffer primitives
// ================================================================

Instruction_Buffer :: [dynamic]u8

emit_byte :: proc(buf: ^Instruction_Buffer, b: u8) {
	append(buf, b)
}

emit_bytes :: proc(buf: ^Instruction_Buffer, bytes: ..u8) {
	for b in bytes {
		append(buf, b)
	}
}

emit_u16le :: proc(buf: ^Instruction_Buffer, v: u16) {
	emit_byte(buf, u8(v & 0xFF))
	emit_byte(buf, u8((v >> 8) & 0xFF))
}

emit_imm32 :: proc(buf: ^Instruction_Buffer, imm: i32) {
	emit_byte(buf, u8(imm & 0xFF))
	emit_byte(buf, u8((imm >> 8) & 0xFF))
	emit_byte(buf, u8((imm >> 16) & 0xFF))
	emit_byte(buf, u8((imm >> 24) & 0xFF))
}

emit_imm64 :: proc(buf: ^Instruction_Buffer, imm: i64) {
	emit_byte(buf, u8(imm & 0xFF))
	emit_byte(buf, u8((imm >> 8) & 0xFF))
	emit_byte(buf, u8((imm >> 16) & 0xFF))
	emit_byte(buf, u8((imm >> 24) & 0xFF))
	emit_byte(buf, u8((imm >> 32) & 0xFF))
	emit_byte(buf, u8((imm >> 40) & 0xFF))
	emit_byte(buf, u8((imm >> 48) & 0xFF))
	emit_byte(buf, u8((imm >> 56) & 0xFF))
}

// ================================================================
// Encoder context — tracks labels and jump patch sites
// ================================================================

Patch_Entry :: struct {
	label_name:  string,
	buf_offset:  int, // offset of the 4-byte displacement in the buffer
}

Encoder_Context :: struct {
	buf:          Instruction_Buffer,
	label_pos:    map[string]int,
	patch_list:   [dynamic]Patch_Entry,
	current_fn:   string,
	data_buf:     ^[dynamic]u8, // optional, populated during encoding for PE32
}

init_encoder :: proc(ctx: ^Encoder_Context) {
	ctx.buf = make(Instruction_Buffer)
	ctx.label_pos = make(map[string]int)
	ctx.patch_list = make([dynamic]Patch_Entry)
}

// ================================================================
// Width helpers
// ================================================================

width_is_64 :: proc(w: Maybe(Width)) -> bool {
	return w != nil && w.? == .U64
}

// True if operand size needs the 0x66 prefix (16-bit)
width_needs_66 :: proc(w: Maybe(Width)) -> bool {
	return w != nil && w.? == .U16
}

// True if this is an 8-bit operation (different opcode column)
width_is_8 :: proc(w: Maybe(Width)) -> bool {
	return w != nil && w.? == .U8
}

// True if register is ah/ch/dh/bh (high-byte, no REX allowed)
is_high_byte_reg :: proc(name: string) -> bool {
	return name == "ah" || name == "ch" || name == "dh" || name == "bh"
}

// ================================================================
// Low-level encoding helpers
// ================================================================

// Emit REX prefix if needed. For 8-bit ops, forces REX unless high-byte reg.
emit_rex_for_regs :: proc(buf: ^Instruction_Buffer, w: bool, reg_name: string, rm_name: string) {
	reg_id := reg_to_id[reg_name]
	rm_id  := reg_to_id[rm_name]
	needs_rex := w || is_ext_reg(reg_id) || is_ext_reg(rm_id)

	// 8-bit with new regs (spl/bpl/sil/dil) needs REX
	if !needs_rex {
		reg_w, reg_exists := register_widths[reg_name]
		if reg_exists && reg_w == .U8 && !is_high_byte_reg(reg_name) {
			needs_rex = true
		}
		rm_w, rm_exists := register_widths[rm_name]
		if rm_exists && rm_w == .U8 && !is_high_byte_reg(rm_name) {
			needs_rex = true
		}
	}

	if needs_rex {
		emit_byte(buf, encode_rex(w, is_ext_reg(reg_id), false, is_ext_reg(rm_id)))
	}
}

// Emit REX for single register operand
emit_rex_for_reg :: proc(buf: ^Instruction_Buffer, w: bool, reg_name: string) {
	reg_id := reg_to_id[reg_name]
	needs_rex := w || is_ext_reg(reg_id)
	if !needs_rex {
		reg_w, reg_exists := register_widths[reg_name]
		if reg_exists && reg_w == .U8 && !is_high_byte_reg(reg_name) {
			needs_rex = true
		}
	}
	if needs_rex {
		emit_byte(buf, encode_rex(w, false, false, is_ext_reg(reg_id)))
	}
}

emit_modrm_reg :: proc(buf: ^Instruction_Buffer, reg: u8, rm: u8) {
	emit_byte(buf, encode_modrm(.DirectRegister, reg & 0b111, rm & 0b111))
}

// ================================================================
// Memory operand encoding — ModR/M + SIB + displacement
// ================================================================

// emit_mem_operand encodes a memory reference into ModR/M (+SIB) + disp bytes.
// mem.base is required (register name). mem.index and mem.offset are optional.
emit_mem_operand :: proc(buf: ^Instruction_Buffer, reg_field: u8, mem: ^Mem_Ref, w: bool) {
	base_str := ""
	if mem.base != nil {
		base_str = mem.base.?
	}
	base_id := reg_to_id[base_str]

	has_index := mem.index != nil
	has_sib := has_index || base_id == 4 // RSP as base always needs SIB

	// Evaluate displacement
	disp: i64 = 0
	has_disp := false
	#partial switch v in mem.offset {
	case i64:
		disp = v
		has_disp = v != 0
	}

	needs_disp8 := has_disp && disp >= -128 && disp <= 127
	needs_disp32 := has_disp && !needs_disp8

	// RIP-relative: no base register
	if base_str == "" {
		emit_byte(buf, encode_modrm(.Indirect, reg_field & 0b111, 0b101))
		if has_disp {
			emit_imm32(buf, i32(disp))
		} else {
			emit_imm32(buf, 0)
		}
		return
	}

	// RBP/R13 with no displacement needs mod=01 + disp8=0
	force_disp := base_id == 5 && !has_disp

	// Mod field
	mod: Mod
	if !has_disp && !force_disp {
		mod = .Indirect
	} else if needs_disp8 || force_disp {
		mod = .Disp8
	} else {
		mod = .Disp32
	}

	// Emit REX
	rex_b := is_ext_reg(base_id)
	rex_x := false
	rex_r := is_ext_reg(reg_field)
	if has_index {
		rex_x = is_ext_reg(reg_to_id[mem.index.?])
	}
	emit_byte(buf, encode_rex(w, rex_r, rex_x, rex_b))

	if has_sib {
		// ModR/M: rm = 101? No, rm = 100 (SIB follows)
		emit_byte(buf, encode_modrm(mod, reg_field & 0b111, 0b100))

		// SIB byte
		scale_bits: u8 = 0
		if mem.scale == 2 { scale_bits = 1 }
		else if mem.scale == 4 { scale_bits = 2 }
		else if mem.scale == 8 { scale_bits = 3 }

		index_id: u8 = 0b100 // "no index" = 100
		if has_index {
			index_id = reg_to_id[mem.index.?]
		}

		emit_byte(buf, encode_sib(1 << scale_bits, index_id & 0b111, base_id & 0b111))
	} else {
		emit_byte(buf, encode_modrm(mod, reg_field & 0b111, base_id & 0b111))
	}

	// Displacement
	if needs_disp8 || force_disp {
		emit_byte(buf, u8(i8(disp)))
	} else if needs_disp32 {
		emit_imm32(buf, i32(disp))
	}
}

// MOV reg, [mem] — opcode 0x8A (8-bit) or 0x8B (16/32/64-bit)
encode_mov_reg_mem :: proc(buf: ^Instruction_Buffer, dst: string, src: ^Mem_Ref, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0x8A } else { opcode = 0x8B }

	if width_needs_66(w) { emit_byte(buf, 0x66) }

	emit_rex_for_reg(buf, width_is_64(w), dst)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[dst], src, width_is_64(w))
}

// MOV [mem], reg — opcode 0x88 (8-bit) or 0x89 (16/32/64-bit)
encode_mov_mem_reg :: proc(buf: ^Instruction_Buffer, dst: ^Mem_Ref, src: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0x88 } else { opcode = 0x89 }

	if width_needs_66(w) { emit_byte(buf, 0x66) }

	emit_rex_for_reg(buf, width_is_64(w), src)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[src], dst, width_is_64(w))
}

// ALU reg, [mem] — opcode 0x02/0x03 (dst=reg, src=mem)
encode_alu_reg_mem :: proc(buf: ^Instruction_Buffer, op: string, dst: string, src: ^Mem_Ref, w: Maybe(Width)) {
	// ALU r/m, reg: 0x02 (8-bit) or 0x03 (16/32/64-bit) — opcode for each ALU op
	base: u8
	switch op {
	case "add": base = 0x02
	case "or":  base = 0x0A
	case "and": base = 0x22
	case "sub": base = 0x2A
	case "xor": base = 0x32
	case "cmp": base = 0x3A
	case:       base = 0x02
	}
	opcode := base
	if !width_is_8(w) { opcode = base + 1 }

	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), dst)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[dst], src, width_is_64(w))
}

// ALU [mem], reg — opcode varies by operation
encode_alu_mem_reg :: proc(buf: ^Instruction_Buffer, op: string, dst: ^Mem_Ref, src: string, w: Maybe(Width)) {
	base: u8
	switch op {
	case "add": base = 0x00
	case "or":  base = 0x08
	case "and": base = 0x20
	case "sub": base = 0x28
	case "xor": base = 0x30
	case "cmp": base = 0x38
	case:       base = 0x00
	}
	opcode := base
	if !width_is_8(w) { opcode = base + 1 }

	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), src)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[src], dst, width_is_64(w))
}

// CMP reg, [mem] — opcode 0x3A (8-bit) or 0x3B (16/32/64-bit)
encode_cmp_reg_mem :: proc(buf: ^Instruction_Buffer, op1: string, op2: ^Mem_Ref, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0x3A } else { opcode = 0x3B }

	if width_needs_66(w) { emit_byte(buf, 0x66) }

	emit_rex_for_reg(buf, width_is_64(w), op1)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[op1], op2, width_is_64(w))
}

// ================================================================
// SSE scalar encoding — movss/addss/subss/mulss/divss, movsd/addsd/etc.
// Prefix: F3 (single) or F2 (double), then 0F, then opcode
// ================================================================

// SSE reg-reg: xmm dst, xmm src
// prefix 0F opcode, ModR/M with reg=dst, rm=src
sse_reg_reg :: proc(buf: ^Instruction_Buffer, prefix: u8, opcode: u8, dst: string, src: string) {
	dst_id := reg_to_id[dst]
	src_id := reg_to_id[src]
	if prefix == 0xF3 || prefix == 0xF2 {
		emit_byte(buf, prefix)
	}
	if is_ext_reg(dst_id) || is_ext_reg(src_id) {
		emit_byte(buf, encode_rex(false, is_ext_reg(dst_id), false, is_ext_reg(src_id)))
	}
	emit_byte(buf, 0x0F)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, dst_id & 0b111, src_id & 0b111)
}

// SSE reg-mem: xmm dst, [mem]
sse_reg_mem :: proc(buf: ^Instruction_Buffer, prefix: u8, opcode: u8, dst: string, src: ^Mem_Ref) {
	dst_id := reg_to_id[dst]
	if prefix == 0xF3 || prefix == 0xF2 {
		emit_byte(buf, prefix)
	}
	// REX: R=dst extension. Base/index REX.B/REX.X handled by emit_mem_operand.
	if is_ext_reg(dst_id) {
		emit_byte(buf, encode_rex(false, is_ext_reg(dst_id), false, false))
	}
	emit_byte(buf, 0x0F)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, dst_id & 0b111, src, false)
}

// SSE mem-reg: [mem] dst, xmm src
sse_mem_reg :: proc(buf: ^Instruction_Buffer, prefix: u8, opcode: u8, dst: ^Mem_Ref, src: string) {
	src_id := reg_to_id[src]
	if prefix == 0xF3 || prefix == 0xF2 {
		emit_byte(buf, prefix)
	}
	if is_ext_reg(src_id) {
		emit_byte(buf, encode_rex(false, is_ext_reg(src_id), false, false))
	}
	emit_byte(buf, 0x0F)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, src_id & 0b111, dst, false)
}

// Lookup SSE opcode: returns (prefix, opcode) for a given mnemonic
sse_opcode :: proc(op: string) -> (prefix: u8, opcode: u8, ok: bool) {
	switch op {
	// Single-precision (F3 prefix)
	case "movss": return 0xF3, 0x10, true
	case "addss": return 0xF3, 0x58, true
	case "subss": return 0xF3, 0x5C, true
	case "mulss": return 0xF3, 0x59, true
	case "divss": return 0xF3, 0x5E, true
	// Double-precision (F2 prefix)
	case "movsd": return 0xF2, 0x10, true
	case "addsd": return 0xF2, 0x58, true
	case "subsd": return 0xF2, 0x5C, true
	case "mulsd": return 0xF2, 0x59, true
	case "divsd": return 0xF2, 0x5E, true
	}
	return 0, 0, false
}

// ================================================================
// Jcc condition code mapping
// ================================================================

jcc_condition_codes := map[string]u8 {
	"jo"  = 0x0, "jno" = 0x1,
	"jb"  = 0x2, "jnb" = 0x3, "jc" = 0x2, "jnc" = 0x3,
	"jz"  = 0x4, "jnz" = 0x5, "je" = 0x4, "jne" = 0x5,
	"jbe" = 0x6, "ja"  = 0x7,
	"js"  = 0x8, "jns" = 0x9,
	"jp"  = 0xa, "jnp" = 0xb,
	"jl"  = 0xc, "jge" = 0xd,
	"jle" = 0xe, "jg"  = 0xf,
}

// ALU extension bits (reg field of ModR/M for /r-digit forms)
ALU_ADD_EXT :: u8(0)
ALU_SUB_EXT :: u8(5)

// Single-operand extension bits (ModR/M reg field)
EXT_MUL  :: u8(4)  // MUL  (0xF7 /4)
EXT_IMUL :: u8(5)  // IMUL (0xF7 /5)
EXT_DIV  :: u8(6)  // DIV  (0xF7 /6)
EXT_NOT  :: u8(2)  // NOT  (0xF7 /2)
EXT_NEG  :: u8(3)  // NEG  (0xF7 /3)

// Shift/rotate extension bits (ModR/M reg field for 0xC0/0xC1)
EXT_ROL  :: u8(0)  // ROL  (0xC0/0xC1 /0)
EXT_ROR  :: u8(1)  // ROR  (0xC0/0xC1 /1)
EXT_SHL  :: u8(4)  // SHL  (0xC0/0xC1 /4)
EXT_SHR  :: u8(5)  // SHR  (0xC0/0xC1 /5)
EXT_SAR  :: u8(7)  // SAR  (0xC0/0xC1 /7)

// INC/DEC extension bits (0xFE/0xFF)
EXT_INC  :: u8(0)  // INC  (0xFE/0xFF /0)
EXT_DEC  :: u8(1)  // DEC  (0xFE/0xFF /1)

// ================================================================
// ALU encoding — handles ADD, SUB, XOR, AND, OR
// ================================================================

// Get the ALU opcode extension for a given instruction
alu_ext_for :: proc(op: string) -> u8 {
	switch op {
	case "add": return ALU_ADD_EXT
	case "sub": return ALU_SUB_EXT
	case "xor": return 6
	case "and": return 4
	case "or":  return 1
	}
	return 0
}

// reg-reg ALU: opcode 0x00/0x01, ModR/M with dst=r/m, src=reg
encode_alu_reg :: proc(buf: ^Instruction_Buffer, op: string, dst: string, src: string, w: Maybe(Width)) {
	// ALU opcode base: ADD=0x00, OR=0x08, ADC=0x10, SBB=0x18, AND=0x20, SUB=0x28, XOR=0x30, CMP=0x38
	base: u8
	switch op {
	case "add": base = 0x00
	case "or":  base = 0x08
	case "and": base = 0x20
	case "sub": base = 0x28
	case "xor": base = 0x30
	case "cmp": base = 0x38
	case:       base = 0x00
	}

	opcode_base := base
	if !width_is_8(w) {
		opcode_base = base + 1
	}

	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_regs(buf, width_is_64(w), src, dst)
	emit_byte(buf, opcode_base)
	emit_modrm_reg(buf, reg_to_id[src], reg_to_id[dst])
}

// reg-imm ALU: opcode 0x80/0x81/0x83, ModR/M with extension in reg field
encode_alu_imm :: proc(buf: ^Instruction_Buffer, op: string, dst: string, imm: i64, w: Maybe(Width)) {
	alu_ext := alu_ext_for(op)

	if width_is_8(w) {
		// 0x80 /digit ib — 8-bit operand, 8-bit immediate
		emit_rex_for_reg(buf, false, dst)
		emit_byte(buf, 0x80)
		emit_modrm_reg(buf, alu_ext, reg_to_id[dst])
		emit_byte(buf, u8(i8(imm)))
	} else if imm >= -128 && imm <= 127 {
		// 0x83 /digit ib — 16/32/64-bit operand, sign-extended 8-bit immediate
		if width_needs_66(w) {
			emit_byte(buf, 0x66)
		}
		emit_rex_for_reg(buf, width_is_64(w), dst)
		emit_byte(buf, 0x83)
		emit_modrm_reg(buf, alu_ext, reg_to_id[dst])
		emit_byte(buf, u8(i8(imm)))
	} else if width_is_64(w) {
		// 64-bit operand, 32-bit immediate (sign-extended by CPU)
		emit_rex_for_reg(buf, true, dst)
		emit_byte(buf, 0x81)
		emit_modrm_reg(buf, alu_ext, reg_to_id[dst])
		emit_imm32(buf, i32(imm))
	} else {
		// 16/32-bit operand, full-width immediate
		if width_needs_66(w) {
			emit_byte(buf, 0x66)
			emit_rex_for_reg(buf, false, dst)
			emit_byte(buf, 0x81)
			emit_modrm_reg(buf, alu_ext, reg_to_id[dst])
			emit_u16le(buf, u16(imm))
		} else {
			emit_rex_for_reg(buf, false, dst)
			emit_byte(buf, 0x81)
			emit_modrm_reg(buf, alu_ext, reg_to_id[dst])
			emit_imm32(buf, i32(imm))
		}
	}
}

// ================================================================
// MOV encoding
// ================================================================

// MOV reg, imm — 0xB0+rd (8-bit) or 0xB8+rd (16/32/64-bit)
encode_mov_reg_imm :: proc(buf: ^Instruction_Buffer, reg: string, imm: i64, w: Maybe(Width)) {
	reg_id := reg_to_id[reg]

	if width_is_8(w) {
		emit_rex_for_reg(buf, false, reg)
		emit_byte(buf, 0xB0 + (reg_id & 0b111))
		emit_byte(buf, u8(imm))
	} else if width_needs_66(w) {
		emit_byte(buf, 0x66)
		emit_rex_for_reg(buf, false, reg)
		emit_byte(buf, 0xB8 + (reg_id & 0b111))
		emit_u16le(buf, u16(imm))
	} else if width_is_64(w) {
		emit_rex_for_reg(buf, true, reg)
		emit_byte(buf, 0xB8 + (reg_id & 0b111))
		emit_imm64(buf, imm)
	} else {
		emit_rex_for_reg(buf, false, reg)
		emit_byte(buf, 0xB8 + (reg_id & 0b111))
		emit_imm32(buf, i32(imm))
	}
}

// MOV reg, reg — 0x88 (8-bit) or 0x89 (16/32/64-bit)
encode_mov_reg_reg :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) {
		opcode = 0x88
	} else {
		opcode = 0x89
	}

	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_regs(buf, width_is_64(w), src, dst)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, reg_to_id[src], reg_to_id[dst])
}

// ================================================================
// CMP and TEST encoding
// ================================================================

// CMP reg, reg — 0x38 (8-bit) or 0x39 (16/32/64-bit)
encode_cmp_reg_reg :: proc(buf: ^Instruction_Buffer, op1: string, op2: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) {
		opcode = 0x38
	} else {
		opcode = 0x39
	}

	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_regs(buf, width_is_64(w), op2, op1)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, reg_to_id[op2], reg_to_id[op1])
}

// CMP reg, imm — 0x80 /7 (8-bit), 0x81 /7 or 0x83 /7 (16/32/64-bit)
encode_cmp_reg_imm :: proc(buf: ^Instruction_Buffer, dst: string, imm: i64, w: Maybe(Width)) {
	CMP_EXT :: u8(7)

	if width_is_8(w) {
		emit_rex_for_reg(buf, false, dst)
		emit_byte(buf, 0x80)
		emit_modrm_reg(buf, CMP_EXT, reg_to_id[dst])
		emit_byte(buf, u8(i8(imm)))
	} else if imm >= -128 && imm <= 127 {
		if width_needs_66(w) {
			emit_byte(buf, 0x66)
		}
		emit_rex_for_reg(buf, width_is_64(w), dst)
		emit_byte(buf, 0x83)
		emit_modrm_reg(buf, CMP_EXT, reg_to_id[dst])
		emit_byte(buf, u8(i8(imm)))
	} else if width_is_64(w) {
		emit_rex_for_reg(buf, true, dst)
		emit_byte(buf, 0x81)
		emit_modrm_reg(buf, CMP_EXT, reg_to_id[dst])
		emit_imm32(buf, i32(imm))
	} else {
		if width_needs_66(w) {
			emit_byte(buf, 0x66)
			emit_rex_for_reg(buf, false, dst)
			emit_byte(buf, 0x81)
			emit_modrm_reg(buf, CMP_EXT, reg_to_id[dst])
			emit_u16le(buf, u16(imm))
		} else {
			emit_rex_for_reg(buf, false, dst)
			emit_byte(buf, 0x81)
			emit_modrm_reg(buf, CMP_EXT, reg_to_id[dst])
			emit_imm32(buf, i32(imm))
		}
	}
}

// TEST reg, reg — 0x84 (8-bit) or 0x85 (16/32/64-bit)
encode_test_reg_reg :: proc(buf: ^Instruction_Buffer, op1: string, op2: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) {
		opcode = 0x84
	} else {
		opcode = 0x85
	}

	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_regs(buf, width_is_64(w), op2, op1)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, reg_to_id[op2], reg_to_id[op1])
}

// ================================================================
// Single-operand encoding — MUL, IMUL, DIV, NOT, NEG
// Opcode 0xF6/0xF7, extension in ModR/M reg field
// ================================================================

encode_single_operand :: proc(buf: ^Instruction_Buffer, ext: u8, reg_name: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) {
		opcode = 0xF6
	} else {
		opcode = 0xF7
	}

	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_reg(buf, width_is_64(w), reg_name)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, ext, reg_to_id[reg_name])
}

// ================================================================
// IMUL 2-operand: dst *= src
// Opcode 0x0F 0xAF /r
// ================================================================

encode_imul_reg_reg :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	if width_needs_66(w) {
		emit_byte(buf, 0x66)
	}

	emit_rex_for_regs(buf, width_is_64(w), dst, src)
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xAF)
	emit_modrm_reg(buf, reg_to_id[dst], reg_to_id[src])
}

// ================================================================
// PUSH / POP — 64-bit only
// ================================================================

encode_push_reg :: proc(buf: ^Instruction_Buffer, reg: string) {
	reg_id := reg_to_id[reg]
	if is_ext_reg(reg_id) {
		emit_byte(buf, encode_rex(false, false, false, true))
	}
	emit_byte(buf, 0x50 + (reg_id & 0b111))
}

encode_pop_reg :: proc(buf: ^Instruction_Buffer, reg: string) {
	reg_id := reg_to_id[reg]
	if is_ext_reg(reg_id) {
		emit_byte(buf, encode_rex(false, false, false, true))
	}
	emit_byte(buf, 0x58 + (reg_id & 0b111))
}

// ================================================================
// LEA reg, [rip+disp32] — for address loads
// Opcode 0x8D, ModR/M mod=00 rm=101 (RIP-relative)
// ================================================================

encode_lea_rip :: proc(buf: ^Instruction_Buffer, dst: string, disp: i32) {
	emit_rex_for_reg(buf, true, dst)
	emit_byte(buf, 0x8D)
	// mod=00, reg=dst, rm=101 (RIP-relative addressing)
	emit_byte(buf, encode_modrm(.Indirect, reg_to_id[dst] & 0b111, 0b101))
	emit_imm32(buf, disp)
}

// ================================================================
// SYSCALL — 0x0F 0x05
// ================================================================

encode_syscall :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0x05)
}

// ================================================================
// RET — 0xC3, NOP — 0x90
// ================================================================

encode_ret :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0xC3)
}

encode_nop :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x90)
}

// ================================================================
// JMP / Jcc / CALL — RIP-relative, 32-bit displacement
// ================================================================

// Record a label definition at the current buffer position
define_label :: proc(ctx: ^Encoder_Context, name: string) {
	mangled := fmt.tprintf("%s__%s", ctx.current_fn, name)
	ctx.label_pos[mangled] = len(ctx.buf)
}

// Emit JMP rel32 — opcode 0xE9
encode_jmp_label :: proc(ctx: ^Encoder_Context, label: string) {
	mangled := fmt.tprintf("%s__%s", ctx.current_fn, label)
	emit_byte(&ctx.buf, 0xE9)

	// Check if label is already defined (backward jump)
	if pos, exists := ctx.label_pos[mangled]; exists {
		// displacement = target - (current_pos + 4)
		disp := i32(pos - (len(ctx.buf) + 4))
		emit_imm32(&ctx.buf, disp)
	} else {
		// Forward reference — emit placeholder, record patch
		patch: Patch_Entry
		patch.label_name = mangled
		patch.buf_offset = len(ctx.buf)
		append(&ctx.patch_list, patch)
		emit_imm32(&ctx.buf, 0) // placeholder
	}
}

// Emit Jcc rel32 — opcode 0x0F 0x80+cc
encode_jcc_label :: proc(ctx: ^Encoder_Context, mnemonic: string, label: string) {
	mangled := fmt.tprintf("%s__%s", ctx.current_fn, label)
	cc, exists := jcc_condition_codes[mnemonic]
	if !exists {
		fmt.printf("Warning: unknown jump condition '%s'\n", mnemonic)
		return
	}

	emit_byte(&ctx.buf, 0x0F)
	emit_byte(&ctx.buf, 0x80 + cc)

	if pos, exists := ctx.label_pos[mangled]; exists {
		disp := i32(pos - (len(ctx.buf) + 4))
		emit_imm32(&ctx.buf, disp)
	} else {
		patch: Patch_Entry
		patch.label_name = mangled
		patch.buf_offset = len(ctx.buf)
		append(&ctx.patch_list, patch)
		emit_imm32(&ctx.buf, 0)
	}
}

// Emit CALL rel32 — opcode 0xE8
encode_call_label :: proc(ctx: ^Encoder_Context, target: string) {
	emit_byte(&ctx.buf, 0xE8)

	if pos, exists := ctx.label_pos[target]; exists {
		disp := i32(pos - (len(ctx.buf) + 4))
		emit_imm32(&ctx.buf, disp)
	} else {
		patch: Patch_Entry
		patch.label_name = target
		patch.buf_offset = len(ctx.buf)
		append(&ctx.patch_list, patch)
		emit_imm32(&ctx.buf, 0)
	}
}

// Resolve all forward-referenced labels after code emission.
// Unresolved patches are appended to unresolved_out for caller to handle.
resolve_patches :: proc(ctx: ^Encoder_Context, unresolved_out: ^[dynamic]Patch_Entry = nil) {
	for patch in ctx.patch_list {
		if target_pos, exists := ctx.label_pos[patch.label_name]; exists {
			disp := i32(target_pos - (patch.buf_offset + 4))
			// Patch the 4-byte displacement in little-endian
			ctx.buf[patch.buf_offset + 0] = u8(disp & 0xFF)
			ctx.buf[patch.buf_offset + 1] = u8((disp >> 8) & 0xFF)
			ctx.buf[patch.buf_offset + 2] = u8((disp >> 16) & 0xFF)
			ctx.buf[patch.buf_offset + 3] = u8((disp >> 24) & 0xFF)
		} else if unresolved_out != nil {
			append(unresolved_out, patch)
		}
	}
	clear(&ctx.patch_list)
}

// ================================================================
// Shift/Rotate encoding — SHL, SHR, SAR, ROL, ROR
// Opcode 0xC0 (8-bit) / 0xC1 (16/32/64-bit), extension in ModR/M reg field
// Or 0xD0/0xD1 for shift by 1 (immediate 1)
// Or 0xD2/0xD3 for shift by CL
// ================================================================

is_shift_op :: proc(op: string) -> bool {
	switch op {
	case "shl", "shr", "sar", "rol", "ror":
		return true
	}
	return false
}

shift_ext_for :: proc(op: string) -> u8 {
	switch op {
	case "shl": return EXT_SHL
	case "shr": return EXT_SHR
	case "sar": return EXT_SAR
	case "rol": return EXT_ROL
	case "ror": return EXT_ROR
	}
	return 0
}

// Encode shift reg, imm — handles imm=1 specially, imm>1 as 0xC0/0xC1
encode_shift_reg_imm :: proc(buf: ^Instruction_Buffer, op: string, dst: string, imm: i64, w: Maybe(Width)) {
	ext := shift_ext_for(op)

	if imm == 1 {
		// 0xD0 (8-bit) / 0xD1 (16/32/64-bit), shift by 1
		opcode: u8
		if width_is_8(w) { opcode = 0xD0 } else { opcode = 0xD1 }
		if width_needs_66(w) { emit_byte(buf, 0x66) }
		emit_rex_for_reg(buf, width_is_64(w), dst)
		emit_byte(buf, opcode)
		emit_modrm_reg(buf, ext, reg_to_id[dst])
	} else {
		// 0xC0 (8-bit, imm8) / 0xC1 (16/32/64-bit, imm8), shift count in imm8
		opcode: u8
		if width_is_8(w) { opcode = 0xC0 } else { opcode = 0xC1 }
		if width_needs_66(w) { emit_byte(buf, 0x66) }
		emit_rex_for_reg(buf, width_is_64(w), dst)
		emit_byte(buf, opcode)
		emit_modrm_reg(buf, ext, reg_to_id[dst])
		emit_byte(buf, u8(imm))
	}
}

// Encode shift reg, cl — 0xD2 (8-bit) / 0xD3 (16/32/64-bit)
encode_shift_reg_cl :: proc(buf: ^Instruction_Buffer, op: string, dst: string, w: Maybe(Width)) {
	ext := shift_ext_for(op)
	opcode: u8
	if width_is_8(w) { opcode = 0xD2 } else { opcode = 0xD3 }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), dst)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, ext, reg_to_id[dst])
}

// ================================================================
// INC/DEC encoding — single-operand register
// INC: 0xFE (8-bit) / 0xFF (16/32/64-bit), extension /0
// DEC: 0xFE (8-bit) / 0xFF (16/32/64-bit), extension /1
// ================================================================

encode_inc_reg :: proc(buf: ^Instruction_Buffer, reg: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xFE } else { opcode = 0xFF }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), reg)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, EXT_INC, reg_to_id[reg])
}

encode_dec_reg :: proc(buf: ^Instruction_Buffer, reg: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xFE } else { opcode = 0xFF }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), reg)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, EXT_DEC, reg_to_id[reg])
}

// INC/DEC [mem] — for lock-prefixed atomic inc/dec
encode_inc_mem :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xFE } else { opcode = 0xFF }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), "rax")
	emit_byte(buf, opcode)
	emit_mem_operand(buf, EXT_INC, mem, width_is_64(w))
}

encode_dec_mem :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xFE } else { opcode = 0xFF }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), "rax")
	emit_byte(buf, opcode)
	emit_mem_operand(buf, EXT_DEC, mem, width_is_64(w))
}

// ================================================================
// Bit manipulation — POPCNT, LZCNT, TZCNT, BSR, BSF, BSWAP
// ================================================================

// Two-operand reg-reg bit scan: 0x0F op /r
encode_bitscan_reg_reg :: proc(buf: ^Instruction_Buffer, opcode1: u8, opcode2: u8, prefix: u8, dst: string, src: string, w: Maybe(Width)) {
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	if prefix != 0 { emit_byte(buf, prefix) }
	emit_rex_for_regs(buf, width_is_64(w), dst, src)
	emit_byte(buf, opcode1)
	emit_byte(buf, opcode2)
	emit_modrm_reg(buf, reg_to_id[dst], reg_to_id[src])
}

// POPCNT reg, reg — F3 0F B8 /r
encode_popcnt :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	encode_bitscan_reg_reg(buf, 0x0F, 0xB8, 0xF3, dst, src, w)
}

// LZCNT reg, reg — F3 0F BD /r
encode_lzcnt :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	encode_bitscan_reg_reg(buf, 0x0F, 0xBD, 0xF3, dst, src, w)
}

// TZCNT reg, reg — F3 0F BC /r
encode_tzcnt :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	encode_bitscan_reg_reg(buf, 0x0F, 0xBC, 0xF3, dst, src, w)
}

// BSR reg, reg — 0F BD /r
encode_bsr :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	encode_bitscan_reg_reg(buf, 0x0F, 0xBD, 0, dst, src, w)
}

// BSF reg, reg — 0F BC /r
encode_bsf :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	encode_bitscan_reg_reg(buf, 0x0F, 0xBC, 0, dst, src, w)
}

// BSWAP reg — 0F C8+rd (32/64-bit only)
encode_bswap :: proc(buf: ^Instruction_Buffer, reg: string, w: Maybe(Width)) {
	reg_id := reg_to_id[reg]
	if is_ext_reg(reg_id) {
		emit_byte(buf, encode_rex(width_is_64(w), false, false, true))
	} else if width_is_64(w) {
		emit_byte(buf, encode_rex(true, false, false, false))
	}
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xC8 + (reg_id & 0b111))
}

// ================================================================
// XCHG — atomic exchange
// reg, reg: 0x90+rd (if dst=rax) or 0x87 /r
// mem, reg: 0x87 /r (same opcode as reg,reg with mem operand)
// ================================================================

encode_xchg_reg_reg :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0x86 } else { opcode = 0x87 }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_regs(buf, width_is_64(w), dst, src)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, reg_to_id[dst], reg_to_id[src])
}

encode_xchg_mem_reg :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, reg: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0x86 } else { opcode = 0x87 }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), reg)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[reg], mem, width_is_64(w))
}

// ================================================================
// CMPXCHG — compare and exchange
// 0x0F B0 (8-bit) / 0x0F B1 (16/32/64-bit)
// reg, reg or mem, reg
// ================================================================

encode_cmpxchg_reg_reg :: proc(buf: ^Instruction_Buffer, dst: string, src: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xB0 } else { opcode = 0xB1 }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_regs(buf, width_is_64(w), src, dst)
	emit_byte(buf, 0x0F)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, reg_to_id[src], reg_to_id[dst])
}

encode_cmpxchg_mem_reg :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, reg: string, w: Maybe(Width)) {
	opcode: u8
	if width_is_8(w) { opcode = 0xB0 } else { opcode = 0xB1 }
	if width_needs_66(w) { emit_byte(buf, 0x66) }
	emit_rex_for_reg(buf, width_is_64(w), reg)
	emit_byte(buf, 0x0F)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, reg_to_id[reg], mem, width_is_64(w))
}

// ================================================================
// Cache control — prefetch, fences, clflush
// ================================================================

// prefetch hint, [mem] — 0x0F 18 /digit
// t0=/1, t1=/2, t2=/3, nta=/0
encode_prefetch :: proc(buf: ^Instruction_Buffer, hint: string, mem: ^Mem_Ref) {
	ext: u8
	switch hint {
	case "t0":  ext = 1
	case "t1":  ext = 2
	case "t2":  ext = 3
	case "nta": ext = 0
	case:       ext = 1 // default to t0
	}
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0x18)
	emit_mem_operand(buf, ext, mem, false)
}

// mfence — 0x0F 0xAE 0xF0
encode_mfence :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xAE)
	emit_byte(buf, 0xF0)
}

// lfence — 0x0F 0xAE 0xE8
encode_lfence :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xAE)
	emit_byte(buf, 0xE8)
}

// sfence — 0x0F 0xAE 0xF8
encode_sfence :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xAE)
	emit_byte(buf, 0xF8)
}

// clflush [mem] — 0x0F 0xAE /7
encode_clflush :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xAE)
	emit_mem_operand(buf, 7, mem, false)
}

// ================================================================
// CPUID — 0x0F 0xA2
// ================================================================

encode_cpuid :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0x0F)
	emit_byte(buf, 0xA2)
}

// ================================================================
// PAUSE — 0xF3 0x90
// ================================================================

encode_pause :: proc(buf: ^Instruction_Buffer) {
	emit_byte(buf, 0xF3)
	emit_byte(buf, 0x90)
}

// ================================================================
// VEX encoding infrastructure for AVX/SIMD instructions
// ================================================================

is_simd_reg :: proc(reg: string) -> bool {
	return strings.has_prefix(reg, "xmm") || strings.has_prefix(reg, "ymm") || strings.has_prefix(reg, "zmm")
}

// Get the 4-bit register ID for SIMD registers (0-15)
sim_reg_id :: proc(reg: string) -> u8 {
	return reg_to_id[reg]
}

// Check if register is 256-bit (ymm)
is_ymm :: proc(reg: string) -> bool {
	return strings.has_prefix(reg, "ymm")
}

// Build 3-byte VEX prefix (0xC4)
// R: inverted extend of ModR/M reg field (dest)
// X: inverted extend of SIB index
// B: inverted extend of ModR/M rm / SIB base / opcode reg
// m-mmmm: opcode map (1=0F, 2=0F38, 3=0F3A)
// W: opcode specific (0 for most)
// vvvv: second source register (inverted 4-bit ID, 1111 = none)
// L: vector length (0=128/xmm, 1=256/ymm)
// pp: legacy prefix (0=none, 1=66, 2=F3, 3=F2)
emit_vex3 :: proc(buf: ^Instruction_Buffer, r: bool, x: bool, b: bool, map_sel: u8, w: bool, vvvv: u8, L: bool, pp: u8) {
	byte1 := u8(0xC4)
	if !r { byte1 |= 0x80 }
	if !x { byte1 |= 0x40 }
	if !b { byte1 |= 0x20 }
	byte1 |= (map_sel & 0x1F)

	byte2 := u8(0)
	if w { byte2 |= 0x80 }
	byte2 |= ((~vvvv & 0x0F) << 3)
	if L { byte2 |= 0x04 }
	byte2 |= (pp & 0x03)

	emit_byte(buf, byte1)
	emit_byte(buf, byte2)
}

// Build 2-byte VEX prefix (0xC5) — used when R=X=B=1 and m-mmmm=01
emit_vex2 :: proc(buf: ^Instruction_Buffer, r: bool, vvvv: u8, L: bool, pp: u8) {
	byte := u8(0xC5)
	if !r { byte |= 0x80 }
	byte |= ((~vvvv & 0x0F) << 3)
	if L { byte |= 0x04 }
	byte |= (pp & 0x03)
	emit_byte(buf, byte)
}

// Helper: emit VEX prefix based on register and prefix info
emit_vex :: proc(buf: ^Instruction_Buffer, dst_ext: bool, vvvv_id: u8, is_256: bool, pp: u8, map_sel: u8) {
	// Always use 3-byte form for simplicity and correctness
	emit_vex3(buf, dst_ext, true, true, map_sel, false, vvvv_id, is_256, pp)
}

// ================================================================
// Vector register width validation
// ================================================================

// Check if register width matches expected vector width
validate_vec_reg :: proc(reg: string, is_256: bool) -> bool {
	if is_256 {
		return strings.has_prefix(reg, "ymm")
	} else {
		return strings.has_prefix(reg, "xmm") || strings.has_prefix(reg, "ymm")
	}
}

// ================================================================
// VEX-encoded vector instruction helpers
// ================================================================

// emit_vex_rrr: 3-operand VEX instruction, reg-reg-reg
// dst = src1 op src2
emit_vex_rrr :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string, pp: u8, map_sel: u8, opcode: u8) {
	dst_ext := sim_reg_id(dst) >= 8
	src1_id := sim_reg_id(src1)
	src2_id := sim_reg_id(src2)
	src2_ext := src2_id >= 8
	is_256 := validate_vec_reg(dst, true)

	emit_vex3(buf, dst_ext, true, !src2_ext, map_sel, false, src2_id & 0x07, is_256, pp)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src1_id & 0x07)
}

// emit_vex_rr: 2-operand VEX instruction, reg-reg (no src2)
emit_vex_rr :: proc(buf: ^Instruction_Buffer, dst: string, src: string, pp: u8, map_sel: u8, opcode: u8) {
	dst_ext := sim_reg_id(dst) >= 8
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8
	is_256 := validate_vec_reg(dst, true)

	emit_vex3(buf, dst_ext, true, !src_ext, map_sel, false, 0x0F, is_256, pp)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
}

// emit_vex_rm: VEX instruction with reg, memory operands
emit_vex_rm :: proc(buf: ^Instruction_Buffer, dst: string, mem: ^Mem_Ref, pp: u8, map_sel: u8, opcode: u8) {
	dst_ext := sim_reg_id(dst) >= 8
	is_256 := validate_vec_reg(dst, true)

	emit_vex3(buf, dst_ext, true, true, map_sel, false, 0x0F, is_256, pp)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, sim_reg_id(dst) & 0x07, mem, false)
}

// emit_vex_mr: VEX instruction with memory, reg operands
emit_vex_mr :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, src: string, pp: u8, map_sel: u8, opcode: u8) {
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8
	is_256 := validate_vec_reg(src, true)

	emit_vex3(buf, true, true, !src_ext, map_sel, false, 0x0F, is_256, pp)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, src_id & 0x07, mem, false)
}

// emit_vex_rri: VEX instruction with reg, reg, imm8
emit_vex_rri :: proc(buf: ^Instruction_Buffer, dst: string, src: string, pp: u8, map_sel: u8, opcode: u8, imm: u8) {
	dst_ext := sim_reg_id(dst) >= 8
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8
	is_256 := validate_vec_reg(dst, true)

	emit_vex3(buf, dst_ext, true, !src_ext, map_sel, false, 0x0F, is_256, pp)
	emit_byte(buf, opcode)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
	emit_byte(buf, imm)
}

// emit_vex_rmi: VEX instruction with reg, memory, imm8
emit_vex_rmi :: proc(buf: ^Instruction_Buffer, dst: string, mem: ^Mem_Ref, pp: u8, map_sel: u8, opcode: u8, imm: u8) {
	dst_ext := sim_reg_id(dst) >= 8
	is_256 := validate_vec_reg(dst, true)

	emit_vex3(buf, dst_ext, true, true, map_sel, false, 0x0F, is_256, pp)
	emit_byte(buf, opcode)
	emit_mem_operand(buf, sim_reg_id(dst) & 0x07, mem, false)
	emit_byte(buf, imm)
}

// ================================================================
// Vector instruction encoders
// ================================================================

// VMOVUPS / VMOVUPD — unaligned load: vmovups ymm, [mem]
encode_vmovups :: proc(buf: ^Instruction_Buffer, dst: string, mem: ^Mem_Ref, is_256: bool) {
	emit_vex_rm(buf, dst, mem, 0, 1, 0x10)
}

// Unaligned store: vmovups [mem], ymm
encode_vmovups_store :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, src: string, is_256: bool) {
	emit_vex_mr(buf, mem, src, 0, 1, 0x11)
}

// VMOVAPS — aligned load: vmovaps ymm, [mem]
encode_vmovaps :: proc(buf: ^Instruction_Buffer, dst: string, mem: ^Mem_Ref, is_256: bool) {
	emit_vex_rm(buf, dst, mem, 0, 1, 0x28)
}

// Aligned store: vmovaps [mem], ymm
encode_vmovaps_store :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, src: string, is_256: bool) {
	emit_vex_mr(buf, mem, src, 0, 1, 0x29)
}

// VADDPS
encode_vaddps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x58)
}

// VSUBPS
encode_vsubps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x5C)
}

// VMULPS
encode_vmulps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x59)
}

// VDIVPS
encode_vdivps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x5E)
}

// VSQRTPS
encode_vsqrtps :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	emit_vex_rr(buf, dst, src, 0, 1, 0x51)
}

// VMINPS
encode_vminps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x5D)
}

// VMAXPS
encode_vmaxps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x5F)
}

// VANDPS — bitwise AND
encode_vandps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x54)
}

// VORPS — bitwise OR
encode_vorps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0, 1, 0x56)
}

// VFMADD132PS: dst = dst * src2 + src1 (0F38 opcode map)
encode_vfmadd132ps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0x61, 2, 0x98)
}

// VFMADD213PS: dst = src1 * dst + src2
encode_vfmadd213ps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0x61, 2, 0xA8)
}

// VFMADD231PS: dst = src2 * src1 + dst
encode_vfmadd231ps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	emit_vex_rrr(buf, dst, src1, src2, 0x61, 2, 0xB8)
}

// VBROADCASTSS: fill all lanes with scalar from xmm register
encode_vbroadcastss :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	emit_vex_rr(buf, dst, src, 0x61, 2, 0x18)
}

// VSHUFPS: shuffle with imm8 control
encode_vshufps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string, imm: u8) {
	emit_vex_rri(buf, dst, src1, 0, 1, 0xC6, imm)
	emit_byte(buf, sim_reg_id(src2) & 0x07) // src2 goes in ModR/M reg
}

// VBLENDVPS: conditional blend by mask register
encode_vblendvps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string, mask: string) {
	// VBLENDVPS: 66 0F3A 4A /r imm8 — but uses xmm0 as implicit mask when VEX.vvvv=mask
	emit_vex_rrr(buf, dst, src1, src2, 0x61, 3, 0x4A)
	emit_byte(buf, sim_reg_id(mask) << 4) // mask in imm8 high nibble
}

// VCMPPS: compare with predicate
encode_vcmpps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string, pred: u8) {
	emit_vex_rri(buf, dst, src1, 0, 1, 0xC2, pred)
	emit_byte(buf, sim_reg_id(src2) & 0x07)
}

// VPERMPS: permute with index register, 3-operand
// VEX.NDS.256.66.0F38.W0 16 /r
encode_vpermps :: proc(buf: ^Instruction_Buffer, dst: string, idx: string, src: string) {
	dst_ext := sim_reg_id(dst) >= 8
	idx_id := sim_reg_id(idx)
	idx_ext := idx_id >= 8
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8
	is_256 := is_ymm(dst)

	emit_vex3(buf, dst_ext, !idx_ext, !src_ext, 2, false, idx_id & 0x07, is_256, 1)
	emit_byte(buf, 0x16)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
}

// VMOVNTPS: non-temporal store — same as vmovups store but with 0x2B opcode
encode_vmovntps :: proc(buf: ^Instruction_Buffer, mem: ^Mem_Ref, src: string, is_256: bool) {
	emit_vex_mr(buf, mem, src, 0, 1, 0x2B)
}

// VCVTSS2SD: scalar float → double conversion (128-bit)
encode_vcvtss2sd :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	dst_ext := sim_reg_id(dst) >= 8
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8

	emit_vex3(buf, dst_ext, true, !src_ext, 1, false, 0x0F, false, 2) // pp=F3
	emit_byte(buf, 0x5A)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
}

// VCVTSD2SS: scalar double → float conversion (128-bit)
encode_vcvtsd2ss :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	dst_ext := sim_reg_id(dst) >= 8
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8

	emit_vex3(buf, dst_ext, true, !src_ext, 1, false, 0x0F, false, 3) // pp=F2
	emit_byte(buf, 0x5A)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
}

// VCVTTPS2DQ: packed float → int32 (truncation) — 256-bit
encode_vcvttps2dq :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	emit_vex_rr(buf, dst, src, 1, 1, 0x5B) // pp=66
}

// VCVTDQ2PS: packed int32 → float — 256-bit
encode_vcvtdq2ps :: proc(buf: ^Instruction_Buffer, dst: string, src: string) {
	emit_vex_rr(buf, dst, src, 0, 1, 0x5B) // pp=none
}

// VEXTRACTF128: extract high 128-bit lane from ymm
// VEX.LIG.256.66.0F3A.W0 19 /r imm8
encode_vextractf128 :: proc(buf: ^Instruction_Buffer, dst: string, src: string, imm: u8) {
	src_id := sim_reg_id(src)
	src_ext := src_id >= 8

	emit_vex3(buf, true, true, !src_ext, 2, false, 0x0F, true, 1) // L=1, pp=66
	emit_byte(buf, 0x19)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src_id & 0x07)
	emit_byte(buf, imm)
}

// VHADDPS: horizontal add of adjacent pairs (128-bit lanes)
// VEX.NDS.128/256.F2.0F.WIG 7C /r
encode_vhaddps :: proc(buf: ^Instruction_Buffer, dst: string, src1: string, src2: string) {
	dst_ext := sim_reg_id(dst) >= 8
	src1_id := sim_reg_id(src1)
	src2_id := sim_reg_id(src2)
	src2_ext := src2_id >= 8
	is_256 := is_ymm(dst)

	emit_vex3(buf, dst_ext, true, !src2_ext, 1, false, src2_id & 0x07, is_256, 3) // pp=F2
	emit_byte(buf, 0x7C)
	emit_modrm_reg(buf, sim_reg_id(dst) & 0x07, src1_id & 0x07)
}

// ================================================================
// Main instruction encoder
// ================================================================

is_alu_op :: proc(op: string) -> bool {
	switch op {
	case "add", "sub", "xor", "and", "or":
		return true
	}
	return false
}

encode_instr :: proc(ctx: ^Encoder_Context, instr: ^Instr) {
	op := instr.op
	n := len(instr.operands)

	// Emit instruction prefix (lock, likely, unlikely)
	if instr.prefix != 0 {
		emit_byte(&ctx.buf, instr.prefix)
	}

	// -- No-operand instructions --
	if n == 0 {
		switch op {
		case "ret":       encode_ret(&ctx.buf)
		case "nop":       encode_nop(&ctx.buf)
		case "syscall":   encode_syscall(&ctx.buf)
		case "int3":      emit_byte(&ctx.buf, 0xCC)
		case "ud2":       emit_byte(&ctx.buf, 0x0F); emit_byte(&ctx.buf, 0x0B)
		case "cpuid":     encode_cpuid(&ctx.buf)
		case "pause":     encode_pause(&ctx.buf)
		case "mfence":    encode_mfence(&ctx.buf)
		case "lfence":    encode_lfence(&ctx.buf)
		case "sfence":    encode_sfence(&ctx.buf)
		case:
			fmt.printf("Warning: zero-operand instruction '%s' not implemented\n", op)
		}
		return
	}

	// -- SIMD vector instruction dispatch (runs before operand-count dispatch) --
	if strings.has_prefix(op, "v") && n >= 1 {
		dst, dst_is_reg := instr.operands[0].(string)

		// Vector store (2-operand, first operand is Mem_Ref): vstore [mem], reg
		if n == 2 && (op == "vstore" || op == "vstorea" || op == "vntstorea") {
			if mem, ok := instr.operands[0].(Mem_Ref); ok {
				if src_reg, ok2 := instr.operands[1].(string); ok2 && is_simd_reg(src_reg) {
					is_256 := is_ymm(src_reg)
					if op == "vstore" { encode_vmovups_store(&ctx.buf, &mem, src_reg, is_256); return }
					if op == "vstorea" { encode_vmovaps_store(&ctx.buf, &mem, src_reg, is_256); return }
					if op == "vntstorea" { encode_vmovntps(&ctx.buf, &mem, src_reg, is_256); return }
				}
			}
		}

		if dst_is_reg && is_simd_reg(dst) {
			is_256 := validate_vec_reg(dst, true)

			// 2-operand: load, store, broadcast, sqrt
			if n == 2 {
				src := instr.operands[1]

				if op == "vload" {
					if mem, ok := src.(Mem_Ref); ok { encode_vmovups(&ctx.buf, dst, &mem, is_256); return }
				}
				if op == "vloada" {
					if mem, ok := src.(Mem_Ref); ok { encode_vmovaps(&ctx.buf, dst, &mem, is_256); return }
				}
				// vstore/vstorea handled above (before SIMD register check)
			if op == "vbroadcast" || op == "vbroadcastss" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) {
						encode_vbroadcastss(&ctx.buf, dst, src_reg); return
					}
				}
			if op == "vsqrt" || op == "vsqrtps" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) {
						encode_vsqrtps(&ctx.buf, dst, src_reg); return
					}
				}
				// vcvt — type conversion
				if op == "vcvtss2sd" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) { encode_vcvtss2sd(&ctx.buf, dst, src_reg); return }
				}
				if op == "vcvtsd2ss" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) { encode_vcvtsd2ss(&ctx.buf, dst, src_reg); return }
				}
				if op == "vcvttps2dq" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) { encode_vcvttps2dq(&ctx.buf, dst, src_reg); return }
				}
				if op == "vcvtdq2ps" {
					if src_reg, ok := src.(string); ok && is_simd_reg(src_reg) { encode_vcvtdq2ps(&ctx.buf, dst, src_reg); return }
				}
				if op == "vabs" {
					// vabs is not a hardware instruction — emit fatal/synthetic
					report_error(.Fatal_Synthetic, instr.src_loc,
						"vabs has no direct hardware encoding.\nvabs requires a sign mask constant. Osteon does not synthesize this silently.\nCorrection:\n  data sign_mask_f32: u32[] = [0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF,\n                                0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF]\n  vloada ymm_mask, deref(sign_mask_f32, 0)\n  vandps dst, src, ymm_mask")
					return
				}
				if op == "vmaskedload" || op == "vmaskedstore" {
					report_error(.Fatal_Unsupported, instr.src_loc,
						fmt.tprintf("%s requires AVX-512\ntarget x86_64-windows does not have AVX-512 support declared\nAVX2 alternative:\n  vcmp ymm_mask, ymm_src, ymm_zero, imm(0)\n  vmaskmovps ymm_dst, ymm_mask, deref(rdi, 0)", op))
					return
				}
			}

			// vntstorea handled above (before SIMD register check)

			// Horizontal reductions: vhsum, vhmax, vhmin
			if n == 2 && (op == "vhsum" || op == "vhsumps") {
				if src_reg, ok := instr.operands[1].(string); ok && is_simd_reg(src_reg) {
					// Synthesize: extractf128 xmm1, src, 1; vaddps xmm1, xmm1, src; vhaddps xmm1, xmm1, xmm1; vhaddps dst, xmm1, xmm1
					encode_vextractf128(&ctx.buf, "xmm1", src_reg, 1)
					encode_vaddps(&ctx.buf, "xmm1", "xmm1", src_reg[:3] == "xmm" ? src_reg : fmt.tprintf("xmm%s", src_reg[3:]))
					encode_vhaddps(&ctx.buf, "xmm1", "xmm1", "xmm1")
					encode_vhaddps(&ctx.buf, dst, "xmm1", "xmm1")
					return
				}
			}
			if n == 2 && (op == "vhmax" || op == "vhmaxps") {
				fmt.printf("Warning: vhmax requires manual horizontal max sequence (not yet synthesized)\n"); return
			}
			if n == 2 && (op == "vhmin" || op == "vhminps") {
				fmt.printf("Warning: vhmin requires manual horizontal min sequence (not yet synthesized)\n"); return
			}

			// 3-operand: arithmetic, fma, cmp (with imm as 3rd)
			if n == 3 || n == 4 {
				src1, src1_is_reg := instr.operands[1].(string)
				src2 := instr.operands[2]

				if src1_is_reg && is_simd_reg(src1) {
					if src2_reg, ok := src2.(string); ok && is_simd_reg(src2_reg) {
						switch op {
						case "vadd", "vaddps":   encode_vaddps(&ctx.buf, dst, src1, src2_reg); return
						case "vsub", "vsubps":   encode_vsubps(&ctx.buf, dst, src1, src2_reg); return
						case "vmul", "vmulps":   encode_vmulps(&ctx.buf, dst, src1, src2_reg); return
						case "vdiv", "vdivps":   encode_vdivps(&ctx.buf, dst, src1, src2_reg); return
						case "vmin", "vminps":   encode_vminps(&ctx.buf, dst, src1, src2_reg); return
						case "vmax", "vmaxps":   encode_vmaxps(&ctx.buf, dst, src1, src2_reg); return
						case "vandps":           encode_vandps(&ctx.buf, dst, src1, src2_reg); return
						case "vorps":            encode_vorps(&ctx.buf, dst, src1, src2_reg); return
						case "vfma", "vfmadd231ps": encode_vfmadd231ps(&ctx.buf, dst, src1, src2_reg); return
						case "vfmadd132ps":      encode_vfmadd132ps(&ctx.buf, dst, src1, src2_reg); return
						case "vfmadd213ps":      encode_vfmadd213ps(&ctx.buf, dst, src1, src2_reg); return
						case "vpermps":          encode_vpermps(&ctx.buf, dst, src1, src2_reg); return
						}

						// vshufps with 4-operand (3 regs + imm)
						if (op == "vshuffle" || op == "vshufps") && n == 4 {
							if imm, ok3 := instr.operands[3].(Immediate); ok3 {
								#partial switch v in imm.expr {
								case i64:
									encode_vshufps(&ctx.buf, dst, src1, src2_reg, u8(v))
									return
								}
							}
						}

						// vcmp/vcmpps with 4 operands: dst, src1, src2, imm(pred)
						if (op == "vcmp" || op == "vcmpps") && n == 4 {
							if imm, ok3 := instr.operands[3].(Immediate); ok3 {
								#partial switch v in imm.expr {
								case i64:
									emit_vex_rri(&ctx.buf, dst, src1, 0, 1, 0xC2, u8(v))
									emit_byte(&ctx.buf, sim_reg_id(src2_reg) & 0x07)
									return
								}
							}
						}
					}
					// vcmp with imm as 3rd operand (n=3)
					if n == 3 && (op == "vcmp" || op == "vcmpps") {
						if imm, ok := src2.(Immediate); ok {
							#partial switch v in imm.expr {
							case i64:
								emit_vex_rri(&ctx.buf, dst, src1, 0, 1, 0xC2, u8(v))
								emit_byte(&ctx.buf, sim_reg_id(src1) & 0x07)
								return
							}
						}
					}
				}
			}

			// 4-operand: vfma(a,b,c,d), vblendv
			if n == 4 {
				src1, src1_is_reg := instr.operands[1].(string)
				src2 := instr.operands[2]

				if src1_is_reg && is_simd_reg(src1) {
					if src2_reg, ok := src2.(string); ok && is_simd_reg(src2_reg) {
						if op == "vfma" || op == "vfmadd231ps" {
							if src3, ok3 := instr.operands[3].(string); ok3 {
								encode_vfmadd132ps(&ctx.buf, dst, src1, src2_reg); return
							}
						}
						if op == "vblendv" {
							if mask, ok3 := instr.operands[3].(string); ok3 {
								encode_vblendvps(&ctx.buf, dst, src1, src2_reg, mask); return
							}
						}
					}
				}
			}

		} // close if dst_is_reg
	} // close if strings.has_prefix(op, "v")

	// -- JMP and Jcc (label target) --
	if op == "jmp" {
		if label, ok := instr.operands[0].(string); ok {
			if _, is_reg := reg_to_id[label]; !is_reg {
				encode_jmp_label(ctx, label)
				return
			}
		}
		fmt.printf("Warning: jmp only supports label targets\n")
		return
	}

	cond_code, is_jcc := jcc_condition_codes[op]
	if is_jcc && n == 1 {
		_ = cond_code // used inside encode_jcc_label via lookup
		if label, ok := instr.operands[0].(string); ok {
			encode_jcc_label(ctx, op, label)
			return
		}
	}

	// -- CALL (label target) --
	if op == "call" && n == 1 {
		if target, ok := instr.operands[0].(string); ok {
			// Mangle cross-namespace calls: "ns::fn" -> "ns__fn"
			mangled := target
			for i := 0; i < len(target) - 1; i += 1 {
				if target[i] == ':' && target[i+1] == ':' {
					mangled = fmt.tprintf("%s__%s", target[:i], target[i+2:])
					break
				}
			}
			encode_call_label(ctx, mangled)
			return
		}
	}

	// -- PUSH / POP (single register operand) --
	if op == "push" && n == 1 {
		if reg, ok := instr.operands[0].(string); ok {
			if _, is_reg := reg_to_id[reg]; is_reg {
				encode_push_reg(&ctx.buf, reg)
				return
			}
		}
		fmt.printf("Warning: push requires a register operand\n")
		return
	}

	if op == "pop" && n == 1 {
		if reg, ok := instr.operands[0].(string); ok {
			if _, is_reg := reg_to_id[reg]; is_reg {
				encode_pop_reg(&ctx.buf, reg)
				return
			}
		}
		fmt.printf("Warning: pop requires a register operand\n")
		return
	}

	// -- Single-operand: MUL, IMUL, DIV, NOT, NEG, INC, DEC, BSWAP --
	if n == 1 {
		if reg, ok := instr.operands[0].(string); ok {
			if _, is_reg := reg_to_id[reg]; is_reg {
				switch op {
				case "mul":  encode_single_operand(&ctx.buf, EXT_MUL,  reg, instr.width)
				case "imul": encode_single_operand(&ctx.buf, EXT_IMUL, reg, instr.width)
				case "div":  encode_single_operand(&ctx.buf, EXT_DIV,  reg, instr.width)
				case "not":  encode_single_operand(&ctx.buf, EXT_NOT,  reg, instr.width)
				case "neg":  encode_single_operand(&ctx.buf, EXT_NEG,  reg, instr.width)
				case "inc":  encode_inc_reg(&ctx.buf, reg, instr.width)
				case "dec":  encode_dec_reg(&ctx.buf, reg, instr.width)
				case "bswap": encode_bswap(&ctx.buf, reg, instr.width)
				case:
					fmt.printf("Warning: single-operand instruction '%s' not implemented\n", op)
				}
				return
			}
		}
		// Single memory operand: clflush, prefetch, inc, dec
		if mem, ok := instr.operands[0].(Mem_Ref); ok {
			if op == "clflush" {
				encode_clflush(&ctx.buf, &mem)
				return
			}
			if op == "prefetch_t0" || op == "prefetch_t1" || op == "prefetch_t2" || op == "prefetch_nta" {
				hint := op[9:]
				encode_prefetch(&ctx.buf, hint, &mem)
				return
			}
			if op == "inc" {
				encode_inc_mem(&ctx.buf, &mem, instr.width)
				return
			}
			if op == "dec" {
				encode_dec_mem(&ctx.buf, &mem, instr.width)
				return
			}
		}
		fmt.printf("Warning: %s requires a register operand\n", op)
		return
	}

	// -- Two-operand instructions --
	if n == 2 {
		dst, dst_is_reg := instr.operands[0].(string)
		src := instr.operands[1]

		// MOV reg, (reg | imm | mem)
		if op == "mov" {
			if dst_is_reg {
				if imm, src_is_imm := src.(Immediate); src_is_imm {
					#partial switch v in imm.expr {
					case i64:
						encode_mov_reg_imm(&ctx.buf, dst, v, instr.width)
						return
					}
				}
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_mov_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
				if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
					encode_mov_reg_mem(&ctx.buf, dst, &mem, instr.width)
					return
				}
			}
			// MOV [mem], (reg | imm)
			if mem, dst_is_mem := instr.operands[0].(Mem_Ref); dst_is_mem {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_mov_mem_reg(&ctx.buf, &mem, src_reg, instr.width)
						return
					}
				}
				if imm, src_is_imm := src.(Immediate); src_is_imm {
					#partial switch v in imm.expr {
					case i64:
						// MOV [mem], imm — opcode 0xC6/0xC7
						opcode: u8
						if width_is_8(instr.width) { opcode = 0xC6 } else { opcode = 0xC7 }
						if width_needs_66(instr.width) { emit_byte(&ctx.buf, 0x66) }
						emit_rex_for_reg(&ctx.buf, width_is_64(instr.width), "rax")
						emit_byte(&ctx.buf, opcode)
						emit_mem_operand(&ctx.buf, 0, &mem, width_is_64(instr.width))
						if width_is_8(instr.width) {
							emit_byte(&ctx.buf, u8(v))
						} else if width_is_64(instr.width) {
							emit_imm64(&ctx.buf, v)
						} else {
							emit_imm32(&ctx.buf, i32(v))
						}
						return
					}
				}
			}
			fmt.printf("Warning: unsupported mov operand types\n")
			return
		}

		// ALU: ADD, SUB, XOR, AND, OR
		if is_alu_op(op) {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_alu_reg(&ctx.buf, op, dst, src_reg, instr.width)
						return
					}
				}
				if imm, src_is_imm := src.(Immediate); src_is_imm {
					#partial switch v in imm.expr {
					case i64:
						encode_alu_imm(&ctx.buf, op, dst, v, instr.width)
						return
					}
				}
				if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
					encode_alu_reg_mem(&ctx.buf, op, dst, &mem, instr.width)
					return
				}
			}
			// ALU [mem], reg
			if mem, dst_is_mem := instr.operands[0].(Mem_Ref); dst_is_mem {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_alu_mem_reg(&ctx.buf, op, &mem, src_reg, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported %s operand types\n", op)
			return
		}

		// CMP
		if op == "cmp" {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_cmp_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
				if imm, src_is_imm := src.(Immediate); src_is_imm {
					#partial switch v in imm.expr {
					case i64:
						encode_cmp_reg_imm(&ctx.buf, dst, v, instr.width)
						return
					}
				}
				if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
					encode_cmp_reg_mem(&ctx.buf, dst, &mem, instr.width)
					return
				}
			}
			fmt.printf("Warning: unsupported cmp operand types\n")
			return
		}

		// TEST
		if op == "test" {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_test_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported test operand types\n")
			return
		}

		// IMUL reg, reg (2-operand form: dst *= src)
		if op == "imul" {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_imul_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported imul operand types\n")
			return
		}

		// Shift/Rotate: SHL, SHR, SAR, ROL, ROR
		if is_shift_op(op) {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						if src_reg == "cl" {
							encode_shift_reg_cl(&ctx.buf, op, dst, instr.width)
							return
						}
					}
				}
				if imm, src_is_imm := src.(Immediate); src_is_imm {
					#partial switch v in imm.expr {
					case i64:
						encode_shift_reg_imm(&ctx.buf, op, dst, v, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported %s operand types\n", op)
			return
		}

		// LEA reg, [mem]
		if op == "lea" {
			if dst_is_reg {
				if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
					if width_needs_66(instr.width) { emit_byte(&ctx.buf, 0x66) }
					emit_rex_for_reg(&ctx.buf, width_is_64(instr.width), dst)
					emit_byte(&ctx.buf, 0x8D)
					emit_mem_operand(&ctx.buf, reg_to_id[dst], &mem, width_is_64(instr.width))
					return
				}
			}
			fmt.printf("Warning: lea requires reg, [mem] operands\n")
			return
		}

		// Bit manipulation: popcnt, lzcnt, tzcnt, bsr, bsf
		switch op {
		case "popcnt":
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_popcnt(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
		case "lzcnt":
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_lzcnt(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
		case "tzcnt":
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_tzcnt(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
		case "bsr":
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_bsr(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
		case "bsf":
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_bsf(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
		}

		// XCHG: reg,reg or mem,reg
		if op == "xchg" {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_xchg_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
			if mem, dst_is_mem := instr.operands[0].(Mem_Ref); dst_is_mem {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_xchg_mem_reg(&ctx.buf, &mem, src_reg, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported xchg operand types\n")
			return
		}

		// CMPXCHG: reg,reg or mem,reg
		if op == "cmpxchg" {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_cmpxchg_reg_reg(&ctx.buf, dst, src_reg, instr.width)
						return
					}
				}
			}
			if mem, dst_is_mem := instr.operands[0].(Mem_Ref); dst_is_mem {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						encode_cmpxchg_mem_reg(&ctx.buf, &mem, src_reg, instr.width)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported cmpxchg operand types\n")
			return
		}

		// Prefetch: prefetch_t0 [mem], prefetch_t1 [mem], etc.
		if op == "prefetch_t0" || op == "prefetch_t1" || op == "prefetch_t2" || op == "prefetch_nta" {
			if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
				hint := op[9:] // extract "t0", "t1", "t2", "nta"
				encode_prefetch(&ctx.buf, hint, &mem)
				return
			}
			fmt.printf("Warning: prefetch requires memory operand\n")
			return
		}

		// SSE scalar: movss, addss, subss, mulss, divss, movsd, addsd, subsd, mulsd, divsd
		sse_prefix, sse_opc, is_sse := sse_opcode(op)
		if is_sse {
			if dst_is_reg {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						sse_reg_reg(&ctx.buf, sse_prefix, sse_opc, dst, src_reg)
						return
					}
				}
				if mem, src_is_mem := src.(Mem_Ref); src_is_mem {
					sse_reg_mem(&ctx.buf, sse_prefix, sse_opc, dst, &mem)
					return
				}
			}
			// SSE [mem], xmm
			if mem, dst_is_mem := instr.operands[0].(Mem_Ref); dst_is_mem {
				if src_reg, src_is_reg := src.(string); src_is_reg {
					if _, ok := reg_to_id[src_reg]; ok {
						sse_mem_reg(&ctx.buf, sse_prefix, sse_opc, &mem, src_reg)
						return
					}
				}
			}
			fmt.printf("Warning: unsupported %s operand types\n", op)
			return
		}

		fmt.printf("Warning: instruction '%s' not implemented in encoder\n", op)
		return
	}

	// -- Four+ operand instructions (vfma, vblendv, vshuffle) --
	if n >= 4 {
		dst_str, dst_is_simd := instr.operands[0].(string)
		if dst_is_simd && is_simd_reg(dst_str) {
			src_reg, src_is_reg := instr.operands[1].(string)

			if src_is_reg && is_simd_reg(src_reg) {
				src2 := instr.operands[2]

				// vfma dst, a, b, c (4-operand form)
				if (op == "vfma" || op == "vfmadd231ps") {
					if s2, ok := src2.(string); ok {
						if s3, ok3 := instr.operands[3].(string); ok3 {
							encode_vfmadd132ps(&ctx.buf, dst_str, src_reg, s2)
							return
						}
					}
				}

				// vblendv dst, a, b, mask
				if op == "vblendv" {
					if s2, ok := src2.(string); ok {
						if mask, ok3 := instr.operands[3].(string); ok3 {
							encode_vblendvps(&ctx.buf, dst_str, src_reg, s2, mask)
							return
						}
					}
				}
			}
		}
	}

	fmt.printf("Warning: instruction '%s' with %d operands not implemented\n", op, n)
}
