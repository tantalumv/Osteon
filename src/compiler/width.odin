#+feature dynamic-literals
package compiler

import "core:fmt"
import "core:strings"

// Variable: register_widths
// Maps register name strings to their Width values. Covers all x86-64
// GPRs (64/32/16/8-bit) and XMM SIMD registers used for width checking.
register_widths: map[string]Width

// Function: init
// Initializes the register_widths map with all known x86-64 register
// names and their corresponding bit widths.
init :: proc() {
	register_widths = map[string]Width{
		// GPR 64-bit
		"rax" = .U64, "rbx" = .U64, "rcx" = .U64, "rdx" = .U64,
		"rsi" = .U64, "rdi" = .U64, "rsp" = .U64, "rbp" = .U64,
		"r8" = .U64, "r9" = .U64, "r10" = .U64, "r11" = .U64,
		"r12" = .U64, "r13" = .U64, "r14" = .U64, "r15" = .U64,
		// GPR 32-bit
		"eax" = .U32, "ebx" = .U32, "ecx" = .U32, "edx" = .U32,
		"esi" = .U32, "edi" = .U32, "esp" = .U32, "ebp" = .U32,
		"r8d" = .U32, "r9d" = .U32, "r10d" = .U32, "r11d" = .U32,
		"r12d" = .U32, "r13d" = .U32, "r14d" = .U32, "r15d" = .U32,
		// GPR 16-bit
		"ax" = .U16, "bx" = .U16, "cx" = .U16, "dx" = .U16,
		"si" = .U16, "di" = .U16, "sp" = .U16, "bp" = .U16,
		"r8w" = .U16, "r9w" = .U16, "r10w" = .U16, "r11w" = .U16,
		"r12w" = .U16, "r13w" = .U16, "r14w" = .U16, "r15w" = .U16,
		// GPR 8-bit low
		"al" = .U8, "bl" = .U8, "cl" = .U8, "dl" = .U8,
		"sil" = .U8, "dil" = .U8, "spl" = .U8, "bpl" = .U8,
		"r8b" = .U8, "r9b" = .U8, "r10b" = .U8, "r11b" = .U8,
		"r12b" = .U8, "r13b" = .U8, "r14b" = .U8, "r15b" = .U8,
		// SIMD
		"xmm0" = .F32, "xmm1" = .F32, "xmm2" = .F32, "xmm3" = .F32,
		"xmm4" = .F32, "xmm5" = .F32, "xmm6" = .F32, "xmm7" = .F32,
		"xmm8" = .F32, "xmm9" = .F32, "xmm10" = .F32, "xmm11" = .F32,
		"xmm12" = .F32, "xmm13" = .F32, "xmm14" = .F32, "xmm15" = .F32,
	}
}

// Function: width_to_string
// Returns the human-readable bit width string for a Width enum value
// (e.g. "8", "16", "32", "64"). Returns "?" for unrecognized widths.
width_to_string :: proc(w: Width) -> string {
	switch w {
	case .U8:  return "8"
	case .U16: return "16"
	case .U32: return "32"
	case .U64: return "64"
	case .F32: return "32"
	case .F64: return "64"
	}
	return "?"
}

// Function: format_operand
// Renders a single operand as a human-readable string for error correction
// messages. Handles register names, immediates, and memory references.
format_operand :: proc(op: Operand) -> string {
	#partial switch v in op {
	case string:
		return v
	case Immediate:
		return fmt.tprintf("imm(%v)", v.expr)
	case Mem_Ref:
		base_str := ""
		if v.base != nil {
			base_str = v.base.?
		}
		if v.index != nil {
			return fmt.tprintf("deref(%s, %s, %d, %v)", base_str, v.index.?, v.scale, v.offset)
		}
		return fmt.tprintf("deref(%s, %v)", base_str, v.offset)
	}
	return "??"
}

// Function: format_operands
// Renders a list of operands as a comma-separated string using format_operand.
format_operands :: proc(operands: []Operand) -> string {
	sb := strings.builder_make()
	for op, i in operands {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, format_operand(op))
	}
	return strings.to_string(sb)
}

// Function: format_instruction
// Renders a full instruction including opcode, width annotation, and operands
// as a human-readable string for error correction messages.
format_instruction :: proc(instr: ^Instr) -> string {
	operands_str := format_operands(instr.operands[:])
	if instr.width != nil {
		return fmt.tprintf("%s(%v) %s", instr.op, instr.width.?, operands_str)
	}
	return fmt.tprintf("%s %s", instr.op, operands_str)
}

// Function: checkWidthConsistency
// Entry point for width consistency checking. Iterates over all packages
// and verifies that instruction width annotations match register operand widths.
checkWidthConsistency :: proc(packages: []^Package) {
	for pkg in packages {
		for stmt in pkg.program.stmts {
			if fn_decl, ok := stmt.(^Fn_Decl); ok {
				alias_to_reg := make(map[string]string)
				check_stmt_list_width(pkg, &alias_to_reg, fn_decl.body)
			}
			if inline_fn_decl, ok := stmt.(^Inline_Fn_Decl); ok {
				alias_to_reg := make(map[string]string)
				check_stmt_list_width(pkg, &alias_to_reg, inline_fn_decl.body)
			}
		}
	}
}

// Function: check_stmt_list_width
// Recursively checks all instructions in a statement list, including those
// nested inside for/while loops. Tracks let-declaration aliases to registers.
check_stmt_list_width :: proc(pkg: ^Package, alias_to_reg: ^map[string]string, stmts: []Stmt) {
	for s in stmts {
		#partial switch v in s {
		case ^Let_Decl:
			alias_to_reg^[v.name] = v.reg
		case ^Instr:
			check_instruction_width(pkg, alias_to_reg, v)
		case ^For_Loop:
			check_stmt_list_width(pkg, alias_to_reg, v.body)
		case ^While_Loop:
			check_stmt_list_width(pkg, alias_to_reg, v.body)
		case ^Alloc_Stmt, ^Reset_Stmt, ^Label_Decl, ^Arena_Decl:
			// No register operands to check
		}
	}
}

// Function: check_instruction_width
// Validates a single instruction's width annotation against its register
// operands. Reports Fatal_Width on mismatch or missing width annotation.
check_instruction_width :: proc(pkg: ^Package, alias_to_reg: ^map[string]string, instr: ^Instr) {
	width := instr.width
	has_width := width != nil

	for i := 0; i < len(instr.operands); i += 1 {
		operand := instr.operands[i]
		reg_name := ""
		#partial switch op in operand {
		case string:
			if reg, exists := alias_to_reg^[op]; exists {
				reg_name = reg
			} else if is_register(op) {
				reg_name = op
			}
		case Mem_Ref:
			if op.base != nil {
				base := op.base.?
				if reg, exists := alias_to_reg^[base]; exists {
					reg_name = reg
				} else if is_register(base) {
					reg_name = base
				}
			}
		case:
			_ = 0 // skip non-register operands
		}

		if reg_name != "" {
			reg_width, exists := register_widths[reg_name]
			if !exists {
				continue
			}

			if has_width {
				if width.? != reg_width {
					msg := fmt.tprintf("%s is %s-bit; instruction width is %v", reg_name, width_to_string(reg_width), width.?)
					correction := fmt.tprintf("%s(%v) %s", instr.op, reg_width, format_operands(instr.operands[:]))
					report_error(.Fatal_Width, instr.src_loc, msg, correction)
				}
			} else {
				msg := fmt.tprintf("missing width annotation for register %s", reg_name)
				correction := fmt.tprintf("%s(%v) %s", instr.op, reg_width, format_operands(instr.operands[:]))
				report_error(.Fatal_Width, instr.src_loc, msg, correction)
			}
		}
	}
}

// Function: is_gpr_reg
// Checks if a string is a known register name by looking it up in the
// register_widths map. Returns true for valid GPR and XMM registers.
is_gpr_reg :: proc(reg: string) -> bool {
	_, exists := register_widths[reg]
	return exists
}
