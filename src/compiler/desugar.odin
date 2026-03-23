package compiler

import "core:fmt"

// Global label counter for unique generated labels
desugar_label_counter: int

// Arena info: tracks the original buffer register, scratch register, and buffer size
Arena_Info :: struct {
	buf_reg:     string,
	scratch_reg: string,
	buf_size:    i64,
}

init_desugar :: proc() {
	desugar_label_counter = 0
}

next_desugar_label :: proc(prefix: string) -> string {
	desugar_label_counter += 1
	return fmt.tprintf("__%s_%d", prefix, desugar_label_counter)
}

// desugar_stmts transforms structured control flow into raw instructions.
// Processes function bodies: for, while, expect, assert, arena/alloc/reset.
desugar_stmts :: proc(stmts: []Stmt) -> [dynamic]Stmt {
	result := make([dynamic]Stmt)

	// First pass: collect arena declarations and assign scratch registers
	arena_info := make(map[string]Arena_Info)
	scratch_regs := []string{"r11", "r10", "r9", "r8"}
	scratch_idx := 0

	for s in stmts {
		if arena, ok := s.(^Arena_Decl); ok {
			buf_reg := ""
			if reg, ok := arena.buf.(string); ok {
				buf_reg = reg
			}
			buf_size := as_i64(eval_const_expr(arena.size, nil))
			if scratch_idx < len(scratch_regs) {
				arena_info[arena.name] = Arena_Info{buf_reg, scratch_regs[scratch_idx], buf_size}
				scratch_idx += 1
			} else {
				report_error(.Fatal_Arena, arena.src_loc, "No scratch register available for arena")
			}
		}
	}

	// Second pass: desugar all statements
	for s in stmts {
		#partial switch v in s {
		case ^For_Loop:
			if v.unroll_factor > 1 {
				desugar_for_unroll(v, &result)
			} else {
				desugar_for_loop(v, &result)
			}
		case ^While_Loop:
			desugar_while_loop(v, &result)
		case ^Expect_Stmt:
			desugar_expect(v, &result)
		case ^Assert_Stmt:
			if !v.is_static {
				desugar_assert(v, &result)
			} else {
				append(&result, s)
			}
		case ^Arena_Decl:
			desugar_arena_decl(v, &arena_info, &result)
		case ^Alloc_Stmt:
			desugar_alloc(v, &arena_info, &result)
		case ^Reset_Stmt:
			desugar_reset(v, &arena_info, &result)
		case ^Instr:
			if v.op == "canary" {
				desugar_canary(v, &result)
			} else if v.op == "check_canary" {
				desugar_check_canary(v, &result)
			} else if v.op == "mova" {
				desugar_mova(v, &result)
			} else {
				append(&result, s)
			}
		case:
			append(&result, s)
		}
	}

	return result
}

// For loop:
//   for reg = start, end, step { body }
// Desugars to:
//   mov reg, start
//   label loop:
//   cmp reg, end
//   jge done
//   <body>
//   add reg, step
//   jmp loop
//   label done:
desugar_for_loop :: proc(loop: ^For_Loop, out: ^[dynamic]Stmt) {
	loop_label := next_desugar_label("for")
	// Use user-specified label for done target if provided (for explicit break via jmp)
	done_label := loop.label != "" ? loop.label : next_desugar_label("for_done")

	// Counter name: extract from operand
	counter_name := ""
	if reg, ok := loop.counter.(string); ok {
		counter_name = reg
	}

	// mov reg, start
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&mov_instr.operands, loop.counter)
	append(&mov_instr.operands, loop.start)
	append(out, Stmt(mov_instr))

	// label loop:
	loop_lbl := new(Label_Decl)
	loop_lbl^ = Label_Decl{name = loop_label, src_loc = loop.src_loc}
	append(out, Stmt(loop_lbl))

	// cmp reg, end
	cmp_instr := new(Instr)
	cmp_instr^ = Instr{op = "cmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&cmp_instr.operands, loop.counter)
	append(&cmp_instr.operands, loop.end)
	append(out, Stmt(cmp_instr))

	// jge done
	jmp_instr := new(Instr)
	jmp_instr^ = Instr{op = "jge", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jmp_instr.operands, Operand(done_label))
	append(out, Stmt(jmp_instr))

	// body (desugar recursively)
	body := desugar_stmts(loop.body)
	for stmt in body {
		append(out, stmt)
	}

	// add reg, step
	add_instr := new(Instr)
	add_instr^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&add_instr.operands, loop.counter)
	append(&add_instr.operands, loop.step)
	append(out, Stmt(add_instr))

	// jmp loop
	jmp_back := new(Instr)
	jmp_back^ = Instr{op = "jmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jmp_back.operands, Operand(loop_label))
	append(out, Stmt(jmp_back))

	// label done:
	done_lbl := new(Label_Decl)
	done_lbl^ = Label_Decl{name = done_label, src_loc = loop.src_loc}
	append(out, Stmt(done_lbl))
}

// While loop:
//   while cmp(u64) rcx, imm(0) / jnz { body }
// Desugars to:
//   label loop:
//   <cond instr>
//   <inverse jcc> done
//   <body>
//   <cond instr again>
//   <jcc> loop
//   label done:
desugar_while_loop :: proc(loop: ^While_Loop, out: ^[dynamic]Stmt) {
	loop_label := next_desugar_label("while")
	done_label := next_desugar_label("while_done")

	inverse_jcc := inverse_condition(loop.jump_cc)

	// label loop:
	loop_lbl := new(Label_Decl)
	loop_lbl^ = Label_Decl{name = loop_label, src_loc = loop.src_loc}
	append(out, Stmt(loop_lbl))

	// <cond instr>
	append(out, Stmt(loop.cond))

	// <inverse jcc> done (exit if condition fails)
	exit_jmp := new(Instr)
	exit_jmp^ = Instr{op = inverse_jcc, operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&exit_jmp.operands, Operand(done_label))
	append(out, Stmt(exit_jmp))

	// body (desugar recursively)
	body := desugar_stmts(loop.body)
	for stmt in body {
		append(out, stmt)
	}

	// <cond instr again>
	append(out, Stmt(loop.cond))

	// <jcc> loop (continue if condition holds)
	continue_jmp := new(Instr)
	continue_jmp^ = Instr{op = loop.jump_cc, operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&continue_jmp.operands, Operand(loop_label))
	append(out, Stmt(continue_jmp))

	// label done:
	done_lbl := new(Label_Decl)
	done_lbl^ = Label_Decl{name = done_label, src_loc = loop.src_loc}
	append(out, Stmt(done_lbl))
}

// expect("msg") → test rdx, rdx; jz __expect_ok; ud2; label __expect_ok:
desugar_expect :: proc(e: ^Expect_Stmt, out: ^[dynamic]Stmt) {
	ok_label := next_desugar_label("expect_ok")

	// test(u64) rdx, rdx
	test_instr := new(Instr)
	test_instr^ = Instr{op = "test", operands = make([dynamic]Operand), src_loc = e.src_loc}
	append(&test_instr.operands, Operand("rdx"))
	append(&test_instr.operands, Operand("rdx"))
	append(out, Stmt(test_instr))

	// jz ok (zero = success, skip trap)
	jz_instr := new(Instr)
	jz_instr^ = Instr{op = "jz", operands = make([dynamic]Operand), src_loc = e.src_loc}
	append(&jz_instr.operands, Operand(ok_label))
	append(out, Stmt(jz_instr))

	// ud2
	ud2_instr := new(Instr)
	ud2_instr^ = Instr{op = "ud2", operands = make([dynamic]Operand), src_loc = e.src_loc}
	append(out, Stmt(ud2_instr))

	// label ok:
	ok_lbl := new(Label_Decl)
	ok_lbl^ = Label_Decl{name = ok_label, src_loc = e.src_loc}
	append(out, Stmt(ok_lbl))
}

// assert(cmp(u64) rax, imm(0), jnz, "msg")
// → cmp(u64) rax, imm(0); jnz ok; ud2; label ok:
desugar_assert :: proc(a: ^Assert_Stmt, out: ^[dynamic]Stmt) {
	ok_label := next_desugar_label("assert_ok")

	cond_instr, ok := a.cond.(^Instr)
	if !ok {
		return
	}

	// <cmp instr>
	append(out, Stmt(cond_instr))

	// <jcc> ok (jump past trap on success)
	jcc_instr := new(Instr)
	jcc_instr^ = Instr{op = a.jump_cc, operands = make([dynamic]Operand), src_loc = a.src_loc}
	append(&jcc_instr.operands, Operand(ok_label))
	append(out, Stmt(jcc_instr))

	// ud2
	ud2_instr := new(Instr)
	ud2_instr^ = Instr{op = "ud2", operands = make([dynamic]Operand), src_loc = a.src_loc}
	append(out, Stmt(ud2_instr))

	// label ok:
	ok_lbl := new(Label_Decl)
	ok_lbl^ = Label_Decl{name = ok_label, src_loc = a.src_loc}
	append(out, Stmt(ok_lbl))
}

// inverse_condition returns the opposite jump condition
inverse_condition :: proc(cc: string) -> string {
	switch cc {
	case "jz":  return "jnz"
	case "jnz": return "jz"
	case "je":  return "jne"
	case "jne": return "je"
	case "jg":  return "jle"
	case "jge": return "jl"
	case "jl":  return "jge"
	case "jle": return "jg"
	case "ja":  return "jbe"
	case "jae": return "jb"
	case "jb":  return "jae"
	case "jbe": return "ja"
	case "js":  return "jns"
	case "jns": return "js"
	case "jc":  return "jnc"
	case "jnc": return "jc"
	case "jo":  return "jno"
	case "jno": return "jo"
	case "jp":  return "jnp"
	case "jnp": return "jp"
	}
	return "jnz" // fallback
}

// ================================================================
// Arena desugaring
// ================================================================

// Arena declaration: emits no instructions. buf register becomes the bump pointer base.
desugar_arena_decl :: proc(arena: ^Arena_Decl, arena_info: ^map[string]Arena_Info, out: ^[dynamic]Stmt) {
	info, exists := arena_info^[arena.name]
	if !exists || info.buf_reg == "" {
		return
	}

	// Initialize scratch register with the buffer base pointer
	// mov(u64) scratch, buf
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = arena.src_loc}
	append(&mov_instr.operands, Operand(info.scratch_reg))
	append(&mov_instr.operands, Operand(info.buf_reg))
	append(out, Stmt(mov_instr))
}

// alloc(arena, size, align):
desugar_alloc :: proc(alloc: ^Alloc_Stmt, arena_info: ^map[string]Arena_Info, out: ^[dynamic]Stmt) {
	info, exists := arena_info^[alloc.arena_name]
	if !exists {
		report_error(.Fatal_Undef, alloc.src_loc, fmt.tprintf("Unknown arena: %s", alloc.arena_name))
		return
	}

	size := as_i64(eval_const_expr(alloc.size, nil))
	align := as_i64(eval_const_expr(alloc.align, nil))

	// add(u64) scratch, imm(align - 1)
	add_align := new(Instr)
	add_align^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
	append(&add_align.operands, Operand(info.scratch_reg))
	append(&add_align.operands, Operand(Immediate{i64(align - 1)}))
	append(out, Stmt(add_align))

	// and(u64) scratch, imm(~(align - 1))
	and_mask := new(Instr)
	and_mask^ = Instr{op = "and", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
	append(&and_mask.operands, Operand(info.scratch_reg))
	append(&and_mask.operands, Operand(Immediate{~(align - 1)}))
	append(out, Stmt(and_mask))

	// mov(u64) rax, scratch (result pointer)
	mov_result := new(Instr)
	mov_result^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
	append(&mov_result.operands, Operand("rax"))
	append(&mov_result.operands, Operand(info.scratch_reg))
	append(out, Stmt(mov_result))

	// add(u64) scratch, imm(size) (advance bump pointer)
	add_size := new(Instr)
	add_size^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
	append(&add_size.operands, Operand(info.scratch_reg))
	append(&add_size.operands, Operand(Immediate{size}))
	append(out, Stmt(add_size))

	// Overflow check: scratch > buf_base + buf_size → ud2
	if info.buf_size > 0 {
		ok_label := next_desugar_label("alloc_ok")

		// Use rcx as temp for buf_end = buf_base + buf_size
		// mov(u64) rcx, buf_reg
		mov_temp := new(Instr)
		mov_temp^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
		append(&mov_temp.operands, Operand("rcx"))
		append(&mov_temp.operands, Operand(info.buf_reg))
		append(out, Stmt(mov_temp))

		// add(u64) rcx, imm(buf_size)
		add_end := new(Instr)
		add_end^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
		append(&add_end.operands, Operand("rcx"))
		append(&add_end.operands, Operand(Immediate{info.buf_size}))
		append(out, Stmt(add_end))

		// cmp(u64) scratch, rcx
		cmp_instr := new(Instr)
		cmp_instr^ = Instr{op = "cmp", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
		append(&cmp_instr.operands, Operand(info.scratch_reg))
		append(&cmp_instr.operands, Operand("rcx"))
		append(out, Stmt(cmp_instr))

		// jbe ok (scratch <= buf_end → ok)
		jbe_instr := new(Instr)
		jbe_instr^ = Instr{op = "jbe", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
		append(&jbe_instr.operands, Operand(ok_label))
		append(out, Stmt(jbe_instr))

		// ud2
		ud2_instr := new(Instr)
		ud2_instr^ = Instr{op = "ud2", operands = make([dynamic]Operand), src_loc = alloc.src_loc}
		append(out, Stmt(ud2_instr))

		// label ok:
		ok_lbl := new(Label_Decl)
		ok_lbl^ = Label_Decl{name = ok_label, src_loc = alloc.src_loc}
		append(out, Stmt(ok_lbl))
	}
}

// reset(arena): re-initialize scratch from original buffer register
desugar_reset :: proc(rst: ^Reset_Stmt, arena_info: ^map[string]Arena_Info, out: ^[dynamic]Stmt) {
	info, exists := arena_info^[rst.arena_name]
	if !exists || info.buf_reg == "" {
		return
	}

	// mov(u64) scratch, buf (restore bump pointer to base)
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = rst.src_loc}
	append(&mov_instr.operands, Operand(info.scratch_reg))
	append(&mov_instr.operands, Operand(info.buf_reg))
	append(out, Stmt(mov_instr))
}

// ================================================================
// for[unroll(N)] — N copies of body per iteration + scalar tail
// ================================================================
//
// Desugars to:
//   mov reg, start
//   label main:
//   cmp reg, end - (N-1)*step   (if end is compile-time known)
//   jge tail
//   <body copy 0>
//   add reg, step
//   <body copy 1>
//   add reg, step
//   ...
//   <body copy N-1>
//   add reg, step
//   jmp main
//   label tail:
//   cmp reg, end
//   jge done
//   <body>
//   add reg, step
//   jmp tail
//   label done:

desugar_for_unroll :: proc(loop: ^For_Loop, out: ^[dynamic]Stmt) {
	N := loop.unroll_factor
	main_label := next_desugar_label("for_unroll_main")
	tail_label := next_desugar_label("for_unroll_tail")
	done_label := loop.label != "" ? loop.label : next_desugar_label("for_unroll_done")

	// mov reg, start
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&mov_instr.operands, loop.counter)
	append(&mov_instr.operands, loop.start)
	append(out, Stmt(mov_instr))

	// label main:
	main_lbl := new(Label_Decl)
	main_lbl^ = Label_Decl{name = main_label, src_loc = loop.src_loc}
	append(out, Stmt(main_lbl))

	// cmp reg, end
	cmp_instr := new(Instr)
	cmp_instr^ = Instr{op = "cmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&cmp_instr.operands, loop.counter)
	append(&cmp_instr.operands, loop.end)
	append(out, Stmt(cmp_instr))

	// jge tail
	jge_tail := new(Instr)
	jge_tail^ = Instr{op = "jge", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jge_tail.operands, Operand(tail_label))
	append(out, Stmt(jge_tail))

	// N copies of body + step
	body_desugared := desugar_stmts(loop.body)
	for copy := 0; copy < N; copy += 1 {
		for stmt in body_desugared {
			append(out, stmt)
		}
		// add reg, step (except after last copy — handled by tail)
		if copy < N - 1 {
			add_instr := new(Instr)
			add_instr^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = loop.src_loc}
			append(&add_instr.operands, loop.counter)
			append(&add_instr.operands, loop.step)
			append(out, Stmt(add_instr))
		}
	}

	// Final step after last body copy
	add_final := new(Instr)
	add_final^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&add_final.operands, loop.counter)
	append(&add_final.operands, loop.step)
	append(out, Stmt(add_final))

	// jmp main
	jmp_main := new(Instr)
	jmp_main^ = Instr{op = "jmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jmp_main.operands, Operand(main_label))
	append(out, Stmt(jmp_main))

	// label tail:
	tail_lbl := new(Label_Decl)
	tail_lbl^ = Label_Decl{name = tail_label, src_loc = loop.src_loc}
	append(out, Stmt(tail_lbl))

	// Scalar cleanup: one iteration at a time
	// cmp reg, end
	cmp_tail := new(Instr)
	cmp_tail^ = Instr{op = "cmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&cmp_tail.operands, loop.counter)
	append(&cmp_tail.operands, loop.end)
	append(out, Stmt(cmp_tail))

	// jge done
	jge_done := new(Instr)
	jge_done^ = Instr{op = "jge", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jge_done.operands, Operand(done_label))
	append(out, Stmt(jge_done))

	// body
	for stmt in body_desugared {
		append(out, stmt)
	}

	// add reg, step
	add_step := new(Instr)
	add_step^ = Instr{op = "add", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&add_step.operands, loop.counter)
	append(&add_step.operands, loop.step)
	append(out, Stmt(add_step))

	// jmp tail
	jmp_tail := new(Instr)
	jmp_tail^ = Instr{op = "jmp", operands = make([dynamic]Operand), src_loc = loop.src_loc}
	append(&jmp_tail.operands, Operand(tail_label))
	append(out, Stmt(jmp_tail))

	// label done:
	done_lbl := new(Label_Decl)
	done_lbl^ = Label_Decl{name = done_label, src_loc = loop.src_loc}
	append(out, Stmt(done_lbl))
}

// ================================================================
// canary — stack canary write
// Desugars to: mov deref(rbp, -8), imm(CANARY_VALUE)
// ================================================================

CANARY_VALUE :: i64(0x3F2C1D4B5E60789)

desugar_canary :: proc(c: ^Instr, out: ^[dynamic]Stmt) {
	// mov(u64) deref(rbp, -8), imm(CANARY_VALUE)
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", width = .U64, operands = make([dynamic]Operand), src_loc = c.src_loc}
	append(&mov_instr.operands, Operand(Mem_Ref{base = "rbp", offset = i64(-8)}))
	append(&mov_instr.operands, Operand(Immediate{CANARY_VALUE}))
	append(out, Stmt(mov_instr))
}

// ================================================================
// check_canary — stack canary verify
// Desugars to:
//   cmp(u64) deref(rbp, -8), imm(CANARY_VALUE)
//   je ok
//   ud2
//   label ok:
// ================================================================

desugar_check_canary :: proc(c: ^Instr, out: ^[dynamic]Stmt) {
	ok_label := next_desugar_label("canary_ok")

	// cmp(u64) deref(rbp, -8), imm(CANARY_VALUE)
	cmp_instr := new(Instr)
	cmp_instr^ = Instr{op = "cmp", width = .U64, operands = make([dynamic]Operand), src_loc = c.src_loc}
	append(&cmp_instr.operands, Operand(Mem_Ref{base = "rbp", offset = i64(-8)}))
	append(&cmp_instr.operands, Operand(Immediate{CANARY_VALUE}))
	append(out, Stmt(cmp_instr))

	// je ok
	je_instr := new(Instr)
	je_instr^ = Instr{op = "je", operands = make([dynamic]Operand), src_loc = c.src_loc}
	append(&je_instr.operands, Operand(ok_label))
	append(out, Stmt(je_instr))

	// ud2
	ud2_instr := new(Instr)
	ud2_instr^ = Instr{op = "ud2", operands = make([dynamic]Operand), src_loc = c.src_loc}
	append(out, Stmt(ud2_instr))

	// label ok:
	ok_lbl := new(Label_Decl)
	ok_lbl^ = Label_Decl{name = ok_label, src_loc = c.src_loc}
	append(out, Stmt(ok_lbl))
}

// ================================================================
// mova — bounds-checked memory access
// mova(type) dst, deref(base, idx, scale, offset), count
// Desugars to:
//   cmp(u64) idx, count
//   jb ok
//   ud2
//   label ok:
//   mov(type) dst, deref(base, idx, scale, offset)
// ================================================================

desugar_mova :: proc(m: ^Instr, out: ^[dynamic]Stmt) {
	ok_label := next_desugar_label("mova_ok")

	if len(m.operands) < 3 {
		return
	}

	dst := m.operands[0]
	mem := m.operands[1]
	count := m.operands[2]

	// Extract index from Mem_Ref
	mem_ref, is_mem := mem.(Mem_Ref)
	if !is_mem {
		append(out, Stmt(m))
		return
	}

	// cmp(u64) idx, count
	cmp_instr := new(Instr)
	cmp_instr^ = Instr{op = "cmp", width = .U64, operands = make([dynamic]Operand), src_loc = m.src_loc}
	if mem_ref.index != nil {
		append(&cmp_instr.operands, Operand(mem_ref.index.?))
	} else {
		// No index — bounds check against offset
		append(&cmp_instr.operands, Operand("rax"))
	}
	append(&cmp_instr.operands, count)
	append(out, Stmt(cmp_instr))

	// jb ok
	jb_instr := new(Instr)
	jb_instr^ = Instr{op = "jb", operands = make([dynamic]Operand), src_loc = m.src_loc}
	append(&jb_instr.operands, Operand(ok_label))
	append(out, Stmt(jb_instr))

	// ud2
	ud2_instr := new(Instr)
	ud2_instr^ = Instr{op = "ud2", operands = make([dynamic]Operand), src_loc = m.src_loc}
	append(out, Stmt(ud2_instr))

	// label ok:
	ok_lbl := new(Label_Decl)
	ok_lbl^ = Label_Decl{name = ok_label, src_loc = m.src_loc}
	append(out, Stmt(ok_lbl))

	// mov(type) dst, mem
	mov_instr := new(Instr)
	mov_instr^ = Instr{op = "mov", width = m.width, operands = make([dynamic]Operand), src_loc = m.src_loc}
	append(&mov_instr.operands, dst)
	append(&mov_instr.operands, mem)
	append(out, Stmt(mov_instr))
}

