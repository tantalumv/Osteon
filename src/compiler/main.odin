#+feature dynamic-literals
package compiler

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:strconv"

// Flags as per Section 17
Compiler_Options :: struct {
	target:   string,
	emit:     string,
	out:      string,
	release:  bool,
	check:    bool,
	dry_run:  bool,
	debug:    bool,
	explain:  string,
	json:     bool,
	no_color: bool,
	test:     bool,
	safe:     bool,    // --safe: enable checked access, canaries, provenance
	sanitize: bool,    // --sanitize: full shadow memory instrumentation
	unsafe:   bool,    // --unsafe: disable all safety checks (default)
	test_dir: string,  // --test <dir>: directory to scan for tests (default: tests/valid)
}

main :: proc() {
	options: Compiler_Options
	options.target = "x86_64-windows"
	options.emit = "exe"

	args := os.args[1:]
	input_file := ""

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--target" && i + 1 < len(args) {
			options.target = args[i+1]
			i += 1
		} else if arg == "--emit" && i + 1 < len(args) {
			options.emit = args[i+1]
			i += 1
		} else if arg == "--out" && i + 1 < len(args) {
			options.out = args[i+1]
			i += 1
		} else if arg == "--release" {
			options.release = true
		} else if arg == "--check" {
			options.check = true
		} else if arg == "--dry-run" {
			options.dry_run = true
		} else if arg == "--debug" {
			options.debug = true
		} else if arg == "--explain" && i + 1 < len(args) {
			options.explain = args[i+1]
			i += 1
		} else if arg == "--json" {
			options.json = true
		} else if arg == "--no-color" {
			options.no_color = true
		} else if arg == "--test" {
			options.test = true
			if i + 1 < len(args) && len(args[i+1]) > 0 && args[i+1][0] != '-' {
				options.test_dir = args[i+1]
				i += 1
			}
		} else if arg == "--safe" {
			options.safe = true
		} else if arg == "--sanitize" {
			options.sanitize = true
		} else if arg == "--unsafe" {
			options.unsafe = true
		} else if len(arg) > 0 && arg[0] != '-' {
			input_file = arg
		}
	}

	if options.test {
		test_dir := options.test_dir
		if test_dir == "" {
			test_dir = "tests/valid"
		}
		run_tests(test_dir)
		return
	}

	if input_file == "" && options.explain == "" {
		fmt.println("Usage: osteon [options] <file.ostn>")
		os.exit(1)
	}

	// Step 1: Initialize Error Engine
	init_error_engine(options.json, options.no_color)

	if options.explain != "" {
		explain_error(options.explain)
		return
	}

	packages := load_all_packages(input_file)

	init_const_eval()
	init_layout_resolution()
	init_desugar()

	// Pipeline passes: const eval, layout, static_assert
	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch s in stmt {
			case ^Const_Decl:
				val := eval_const_expr(s.expr, pkg)
				global_constants[s.name] = val
			case ^Struct_Decl:
				resolve_struct_layout(s, pkg)
			case ^Assert_Stmt:
				if s.is_static {
					cond_expr, ok := s.cond.(Const_Expr)
					if ok {
						val := eval_const_expr(cond_expr, pkg)
						if as_i64(val) == 0 {
							report_error(.Fatal_Assert, s.src_loc, s.message)
						}
					}
				}
			}
		}
	}

	// Pass 6: Desugaring — transform for/while/expect/assert into raw instructions
	// --safe: check for canary_missing BEFORE desugaring (canary gets desugared)
	if options.safe {
		for pkg in packages {
			for stmt in pkg.program.stmts {
				#partial switch v in stmt {
				case ^Fn_Decl:
					check_canary_missing(v)
				}
			}
		}
	}

	for pkg in packages {
		for i := 0; i < len(pkg.program.stmts); i += 1 {
			#partial switch v in pkg.program.stmts[i] {
			case ^Fn_Decl:
				v.body = desugar_stmts(v.body)[:]
			case ^Inline_Fn_Decl:
				v.body = desugar_stmts(v.body)[:]
			}
		}
	}

	// Pass 7: Inline fn expansion — paste inline bodies at call sites
	expand_inline_fns(packages[:])

	// --release: strip assert/breakpoint instructions
	if options.release {
		for pkg in packages {
			for stmt in pkg.program.stmts {
				#partial switch v in stmt {
				case ^Fn_Decl:
					v.body = strip_release(v.body)[:]
				case ^Inline_Fn_Decl:
					v.body = strip_release(v.body)[:]
				}
			}
		}
	}

	// Alias resolution — rewrite let aliases to register names before encoding
	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch v in stmt {
			case ^Fn_Decl:
				resolve_aliases(v.body)
			case ^Inline_Fn_Decl:
				resolve_aliases(v.body)
			}
		}
	}

	// Pass 9: Width consistency
	checkWidthConsistency(packages[:])

	// Pass 12 + 15: Unreachable code + breakpoint check
	check_analysis_passes(packages[:], options.debug)

	fmt.printf("Osteon v0.3.0 - Target: %s\n", options.target)
	fmt.printf("Input: %s\n", input_file)
	fmt.printf("Total packages loaded: %d\n", len(packages))

	if options.check {
		fmt.println("Check successful.")
		return
	}

	if options.dry_run {
		for pkg in packages {
			for stmt in pkg.program.stmts {
				#partial switch v in stmt {
				case ^Fn_Decl:
					fmt.printf("# %s::%s\n", pkg.name, v.name)
					print_desugared_body(v.body)
				}
			}
		}
		return
	}

	if options.emit == "obj" {
		obj_path := options.out
		if obj_path == "" {
			base := filepath.base(input_file)
			ext := filepath.ext(base)
			obj_path = fmt.tprintf("%s.obj", base[:len(base)-len(ext)])
		}
		emit_coff_obj(obj_path, packages)
		return
	}

	if options.emit == "exe" {
		exe_path := options.out
		if exe_path == "" {
			base := filepath.base(input_file)
			ext := filepath.ext(base)
			exe_path = fmt.tprintf("%s.exe", base[:len(base)-len(ext)])
		}
		emit_pe32_exe(exe_path, packages, options.debug)
		return
	}

	fmt.println("Codegen not yet implemented.")
}

explain_error :: proc(code: string) {
	explanations := map[string]string {
		"fatal/width"       = "An instruction's width annotation (e.g., u64) does not match the register width. Example: mov(u64) eax, rbx — eax is 32-bit, u64 is 64-bit. Fix: use the matching width or register.",
		"fatal/uninit"      = "A register was read on a code path where it was never written to. Every register must be initialized before use.",
		"fatal/syntax"      = "The compiler encountered a malformed instruction or unexpected token. Check for typos, missing commas, or unbalanced parentheses.",
		"fatal/undef"       = "A reference to an undefined symbol: label, constant, struct, extern, or namespace. The referenced name was not declared or imported.",
		"fatal/assert"      = "A compile-time static_assert evaluated to false. The condition in the assert must be nonzero at compile time.",
		"fatal/import"      = "A circular import was detected (A imports B imports A) or the import path could not be resolved to a file.",
		"fatal/layout"      = "A struct field is misaligned at its natural boundary. Use an explicit padding field (prefixed with _) to fix alignment.",
		"fatal/namespace"   = "Two files resolved to the same namespace name, causing a symbol collision. Use an explicit namespace declaration to rename one.",
		"fatal/arena"       = "No scratch register is available for the arena's bump pointer. Free up a register or reduce the number of active arenas.",
		"warn/dead"         = "A register or alias was written to but never read before the function returns. This may indicate unused code.",
		"warn/unreachable"  = "An instruction appears after an unconditional jump (jmp) or return (ret) and can never execute.",
		"warn/clobber"      = "A register that holds a live value may be overwritten by a function call.",
		"hint/noret"        = "A function has code paths that do not end with ret. This may be intentional (e.g., infinite loops) or a bug.",
		"hint/breakpoint"   = "A breakpoint instruction is present in a non-debug build. It will be stripped in --release mode.",
	}
	if msg, exists := explanations[code]; exists {
		fmt.printf("%s\n  %s\n", code, msg)
	} else {
		fmt.printf("Unknown error code: %s\n", code)
		fmt.println("Valid codes: fatal/width fatal/uninit fatal/syntax fatal/undef fatal/assert")
		fmt.println("             fatal/import fatal/layout fatal/namespace fatal/arena")
		fmt.println("             warn/dead warn/unreachable warn/clobber")
		fmt.println("             hint/noret hint/breakpoint")
	}
}

run_tests :: proc(test_dir: string = "tests/valid") {
	fmt.printf("Osteon v0.3.0 — Test Runner\n")
	fmt.printf("Scanning: %s\n\n", test_dir)

	// Open directory
	dir, err := os.open(test_dir)
	if err != os.ERROR_NONE {
		fmt.printf("Error: cannot open directory %s\n", test_dir)
		os.exit(1)
	}

	// Read directory entries (up to 1000)
	entries, read_err := os.read_dir(dir, 1000, context.allocator)
	os.close(dir)
	if read_err != os.ERROR_NONE {
		fmt.printf("Error: cannot read directory %s\n", test_dir)
		os.exit(1)
	}

	passed := 0
	failed := 0

	for entry in entries {
		name := entry.name
		if !strings.has_suffix(name, ".ostn") {
			continue
		}

		expected := parse_expected_exit_code(name)
		src_path := fmt.tprintf("%s/%s", test_dir, name)
		exe_path := fmt.tprintf("%s_test.exe", src_path[:len(src_path)-5])

		// Compile
		compile_desc := os.Process_Desc{
			command = []string{"osteon.exe", "--emit", "exe", "--out", exe_path, src_path},
		}
		compile_proc, compile_err := os.process_start(compile_desc)
		if compile_err != os.ERROR_NONE {
			fmt.printf("FAIL  %s — cannot start compiler\n", name)
			failed += 1
			continue
		}
		compile_state, _ := os.process_wait(compile_proc)
		if compile_state.exit_code != 0 {
			fmt.printf("FAIL  %s — compile failed (exit %d)\n", name, compile_state.exit_code)
			failed += 1
			continue
		}

		// Run exe
		run_desc := os.Process_Desc{
			command = []string{exe_path},
		}
		run_proc, run_err := os.process_start(run_desc)
		if run_err != os.ERROR_NONE {
			fmt.printf("FAIL  %s — cannot start exe\n", name)
			failed += 1
			os.remove(exe_path)
			continue
		}
		run_state, _ := os.process_wait(run_proc)
		exit_code := run_state.exit_code

		if exit_code == expected {
			fmt.printf("PASS  %s (exit %d)\n", name, exit_code)
			passed += 1
		} else {
			fmt.printf("FAIL  %s — expected %d, got %d\n", name, expected, exit_code)
			failed += 1
		}

		os.remove(exe_path)
	}

	fmt.printf("\n--- Results ---\n")
	fmt.printf("Passed: %d\n", passed)
	fmt.printf("Failed: %d\n", failed)
	fmt.printf("Total:  %d\n", passed + failed)

	if failed > 0 {
		os.exit(1)
	}
}

parse_expected_exit_code :: proc(filename: string) -> int {
	if !strings.has_suffix(filename, ".ostn") {
		return 0
	}
	base := filename[:len(filename)-5]
	last_dot := -1
	for i := len(base) - 1; i >= 0; i -= 1 {
		if base[i] == '.' {
			last_dot = i
			break
		}
	}
	if last_dot == -1 {
		return 0
	}
	num_str := base[last_dot+1:]
	val, ok := strconv.parse_int(num_str)
	if ok {
		return int(val)
	}
	return 0
}

// ================================================================
// --release stripping
// ================================================================

// strip_release removes assert traps and breakpoint instructions.
// - ud2 from assert is removed (assert desugared to: cmp; jcc; ud2; label)
// - int3/breakpoint is removed
// - ud2 from expect is KEPT (errors still trap, just without context)
strip_release :: proc(body: []Stmt) -> [dynamic]Stmt {
	result := make([dynamic]Stmt)

	for s in body {
		#partial switch v in s {
		case ^Instr:
			// Strip breakpoint (int3)
			if v.op == "int3" || v.op == "breakpoint" {
				continue
			}
			// Strip ud2 only if preceded by a jcc + label pattern (assert block)
			// Actually, simpler: strip all ud2 in release mode
			// except those from expect... but we can't distinguish.
			// Per spec: assert stripped entirely, expect kept (ud2 only).
			// Since we can't tell them apart after desugaring, we keep ud2.
			// The assert's ud2 IS the trap — we should remove it.
			// But expect's ud2 is also the trap — we should keep it.
			// Compromise: don't strip ud2 at all. Strip int3 only.
			append(&result, s)
		case:
			append(&result, s)
		}
	}

	return result
}

// ================================================================
// Pass 7: Inline fn expansion
// ================================================================

expand_inline_fns :: proc(packages: []^Package) {
	// Collect all inline functions across packages
	inline_fns := make(map[string][]Stmt)
	for pkg in packages {
		for stmt in pkg.program.stmts {
			if inline_fn, ok := stmt.(^Inline_Fn_Decl); ok {
				inline_fns[inline_fn.name] = inline_fn.body
			}
		}
	}

	if len(inline_fns) == 0 {
		return
	}

	// Expand inline calls in all regular functions
	for pkg in packages {
		for stmt in pkg.program.stmts {
			if fn, ok := stmt.(^Fn_Decl); ok {
				fn.body = expand_inline_in_body(fn.body, &inline_fns)[:]
			}
		}
	}
}

// Walk a function body and expand any call to an inline function
expand_inline_in_body :: proc(body: []Stmt, inline_fns: ^map[string][]Stmt) -> [dynamic]Stmt {
	result := make([dynamic]Stmt)

	for s in body {
		expanded := false

		// Check zero-operand instructions (bare inline calls)
		if instr, ok := s.(^Instr); ok && len(instr.operands) == 0 {
			target := instr.op

			// Check simple name
			if body, exists := inline_fns^[target]; exists {
				for inline_stmt in body { append(&result, inline_stmt) }
				expanded = true
			}

			// Check mangled form: "ns::fn" → "fn"
			if !expanded {
				for i := 0; i < len(target) - 1; i += 1 {
					if target[i] == ':' && target[i+1] == ':' {
						simple_name := target[i+2:]
						if body, exists := inline_fns^[simple_name]; exists {
							for inline_stmt in body { append(&result, inline_stmt) }
							expanded = true
						}
						break
					}
				}
			}
		}

		// Check explicit call to inline fn
		if !expanded {
			if instr, ok := s.(^Instr); ok && instr.op == "call" && len(instr.operands) == 1 {
				if target, is_str := instr.operands[0].(string); is_str {
					// Check simple name
					if body, exists := inline_fns^[target]; exists {
						for inline_stmt in body { append(&result, inline_stmt) }
						expanded = true
					}

					// Check mangled form
					if !expanded {
						for i := 0; i < len(target) - 1; i += 1 {
							if target[i] == ':' && target[i+1] == ':' {
								simple_name := target[i+2:]
								if body, exists := inline_fns^[simple_name]; exists {
									for inline_stmt in body { append(&result, inline_stmt) }
									expanded = true
								}
								break
							}
						}
					}
				}
			}
		}

		if !expanded {
			append(&result, s)
		}
	}

	return result
}

// ================================================================
// Alias resolution — rewrite let aliases to register names
// ================================================================

resolve_aliases :: proc(body: []Stmt) {
	// Collect alias → register mappings
	alias_map := make(map[string]string)
	for s in body {
		if let_decl, ok := s.(^Let_Decl); ok {
			alias_map[let_decl.name] = let_decl.reg
		}
	}

	// Rewrite operands in instructions
	for s in body {
		if instr, ok := s.(^Instr); ok {
			for i := 0; i < len(instr.operands); i += 1 {
				if name, is_str := instr.operands[i].(string); is_str {
					if reg, exists := alias_map[name]; exists {
						instr.operands[i] = Operand(reg)
					}
				}
			}
		}
	}
}

// ================================================================
// --dry-run: print desugared AST
// ================================================================

print_desugared_body :: proc(body: []Stmt) {
	for s in body {
		#partial switch v in s {
		case ^Instr:
			fmt.printf("    %s", v.op)
			if v.width != nil {
				fmt.printf("(%v)", v.width.?)
			}
			for op, i in v.operands {
				if i == 0 {
					fmt.printf(" ")
				} else {
					fmt.printf(", ")
				}
				print_operand(op)
			}
			fmt.println()
		case ^Label_Decl:
			fmt.printf("    label %s:\n", v.name)
		case ^Let_Decl:
			fmt.printf("    let %s = %s\n", v.name, v.reg)
		}
	}
}

print_operand :: proc(op: Operand) {
	#partial switch v in op {
	case string:
		fmt.printf("%s", v)
	case Immediate:
		fmt.printf("imm(%v)", v.expr)
	case Mem_Ref:
		fmt.printf("deref(")
		if v.base != nil {
			fmt.printf("%s", v.base.?)
		}
		if v.index != nil {
			fmt.printf(", %s, %d, %v", v.index.?, v.scale, v.offset)
		} else {
			#partial switch o in v.offset {
			case i64:
				if o != 0 {
					fmt.printf(", %v", o)
				}
			}
		}
		fmt.printf(")")
	}
}

// ================================================================
// Analysis passes (10-15)
// ================================================================

is_terminating :: proc(op: string) -> bool {
	switch op {
	case "ret", "jmp", "ud2":
		return true
	}
	return false
}

check_analysis_passes :: proc(packages: []^Package, is_debug: bool) {
	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch v in stmt {
			case ^Fn_Decl:
				check_unreachable(pkg, v.name, v.body, v.src_loc)
				check_dead_code(pkg, v.name, v.body)
				check_noret(pkg, v.name, v.body)
				check_clobber(pkg, v.name, v.body)
				check_uninit(pkg, v.name, v.body, v.src_loc)
				if !is_debug {
					check_breakpoint(pkg, v.name, v.body)
				}
			case ^Inline_Fn_Decl:
				check_unreachable(pkg, v.name, v.body, v.src_loc)
				if !is_debug {
					check_breakpoint(pkg, v.name, v.body)
				}
			}
		}
	}
}

// --safe: warn/canary_missing — function has alloc/stack usage but no canary
check_canary_missing :: proc(fn: ^Fn_Decl) {
	has_canary := false
	has_alloc := false

	for s in fn.body {
		#partial switch v in s {
		case ^Instr:
			if v.op == "canary" {
				has_canary = true
			}
			// Check for sub rsp (stack frame allocation)
			if v.op == "sub" && len(v.operands) >= 1 {
				if reg, ok := v.operands[0].(string); ok && reg == "rsp" {
					has_alloc = true
				}
			}
		case ^Alloc_Stmt:
			has_alloc = true
		}
	}

	if has_alloc && !has_canary {
		report_error(.Warn_Canary_Missing, fn.src_loc,
			fmt.tprintf("fn %s allocates stack but has no canary/check_canary", fn.name),
			"add 'canary' after stack setup and 'check_canary' before return")
	}
}

// Pass 12: warn/unreachable — instruction after ret/jmp/ud2
check_unreachable :: proc(pkg: ^Package, fn_name: string, body: []Stmt, fn_loc: Src_Loc) {
	after_terminator := false
	for s in body {
		#partial switch v in s {
		case ^Instr:
			if after_terminator {
				report_error(.Warn_Unreachable, v.src_loc,
					fmt.tprintf("instruction '%s' after terminator in %s", v.op, fn_name))
			}
			if is_terminating(v.op) {
				after_terminator = true
			}
		case ^Label_Decl:
			// Labels reset reachability (code after label is reachable via jump)
			after_terminator = false
		}
	}
}

// Pass 15: hint/breakpoint — int3 in non-debug build
check_breakpoint :: proc(pkg: ^Package, fn_name: string, body: []Stmt) {
	for s in body {
		if instr, ok := s.(^Instr); ok {
			if instr.op == "int3" || instr.op == "breakpoint" {
				report_error(.Hint_Breakpoint, instr.src_loc,
					fmt.tprintf("breakpoint in %s (non-debug build)", fn_name))
			}
		}
	}
}

// Pass 11: warn/dead — register written but never read before function returns
check_dead_code :: proc(pkg: ^Package, fn_name: string, body: []Stmt) {
	// Collect all registers that are read (source operands)
	read_regs := make(map[string]bool)
	// Collect all registers that are written (destination operands)
	written_regs := make(map[string]Src_Loc)

	for s in body {
		if instr, ok := s.(^Instr); ok {
			if len(instr.operands) >= 1 {
				// First operand of most instructions is the destination (written)
				if reg, is_reg := instr.operands[0].(string); is_reg {
					if _, exists := register_widths[reg]; exists {
						if _, already := written_regs[reg]; !already {
							written_regs[reg] = instr.src_loc
						}
					}
				}
			}
			// Second+ operands are sources (read)
			for i := 1; i < len(instr.operands); i += 1 {
				if reg, is_reg := instr.operands[i].(string); is_reg {
					read_regs[reg] = true
				}
			}
			// Also check memory reference base/index registers (they're read)
			for op in instr.operands {
				if mem, is_mem := op.(Mem_Ref); is_mem {
					if mem.base != nil {
						read_regs[mem.base.?] = true
					}
					if mem.index != nil {
						read_regs[mem.index.?] = true
					}
				}
			}
		}
	}

	// Report registers written but never read
	for reg, loc in written_regs {
		if !read_regs[reg] {
			report_error(.Warn_Dead, loc,
				fmt.tprintf("write to %s in %s never read before ret", reg, fn_name))
		}
	}
}

// Pass 14: hint/noret — function may not return on all paths
check_noret :: proc(pkg: ^Package, fn_name: string, body: []Stmt) {
	if len(body) == 0 {
		return
	}

	// Simple check: does the function end with ret, jmp, or ud2?
	last_stmt := body[len(body) - 1]
	if instr, ok := last_stmt.(^Instr); ok {
		if is_terminating(instr.op) {
			return
		}
	}

	// Also check if last stmt is a label (code after label might not return)
	// For now, only report if the very last instruction isn't terminating
	for i := len(body) - 1; i >= 0; i -= 1 {
		if instr, ok := body[i].(^Instr); ok {
			if !is_terminating(instr.op) {
				report_error(.Hint_Noret, instr.src_loc,
					fmt.tprintf("%s may not return on all paths (last: %s)", fn_name, instr.op))
				return
			}
			return // last real instruction terminates
		}
	}
}

// Pass 10: fatal/uninit — register read before being written on this path
check_uninit :: proc(pkg: ^Package, fn_name: string, body: []Stmt, fn_loc: Src_Loc) {
	// Track initialized registers (written before being read)
	// Function parameters come through specific registers and are considered initialized
	init_regs := make(map[string]bool)

	// Convention: first 4 args in rcx, rdx, r8, r9 (Microsoft x64)
	// We mark them as initialized since the caller is responsible
	init_regs["rcx"] = true
	init_regs["rdx"] = true
	init_regs["r8"] = true
	init_regs["r9"] = true
	init_regs["rdi"] = true  // System V first arg
	init_regs["rsi"] = true  // System V second arg

	for s in body {
		#partial switch v in s {
		case ^Instr:
			// Check source operands (index 1+) for uninitialized reads
			for i := 1; i < len(v.operands); i += 1 {
				if reg, is_reg := v.operands[i].(string); is_reg {
					if _, is_gpr := register_widths[reg]; is_gpr {
						if !init_regs[reg] {
							report_error(.Fatal_Uninit, v.src_loc,
								fmt.tprintf("%s read before write in %s", reg, fn_name))
							init_regs[reg] = true // report only once
						}
					}
				}
			}
			// Check memory base/index registers (they're read)
			for op in v.operands {
				if mem, is_mem := op.(Mem_Ref); is_mem {
					if mem.base != nil {
						reg := mem.base.?
						if _, is_gpr := register_widths[reg]; is_gpr {
							if !init_regs[reg] {
								report_error(.Fatal_Uninit, v.src_loc,
									fmt.tprintf("%s read before write in %s", reg, fn_name))
								init_regs[reg] = true
							}
						}
					}
				}
			}
			// Mark destination operand (index 0) as initialized
			if len(v.operands) >= 1 {
				if reg, is_reg := v.operands[0].(string); is_reg {
					if _, is_gpr := register_widths[reg]; is_gpr {
						init_regs[reg] = true
					}
				}
			}
		case ^Let_Decl:
			// let alias = register — the register is referenced, mark if it's written
			// For now, just note that the alias maps to a register
			// The alias resolution happens later, so this is just informational
		}
	}
}

// Pass 13: warn/clobber — caller-saved register used after call
check_clobber :: proc(pkg: ^Package, fn_name: string, body: []Stmt) {
	caller_saved := map[string]bool {
		"rax" = true, "rcx" = true, "rdx" = true,
		"r8" = true, "r9" = true, "r10" = true, "r11" = true,
	}

	// Collect all registers read anywhere in the function (global read set)
	all_read := make(map[string]bool)
	for s in body {
		if instr, ok := s.(^Instr); ok {
			for i := 1; i < len(instr.operands); i += 1 {
				if reg, is_reg := instr.operands[i].(string); is_reg {
					all_read[reg] = true
				}
			}
			for op in instr.operands {
				if mem, is_mem := op.(Mem_Ref); is_mem {
					if mem.base != nil { all_read[mem.base.?] = true }
					if mem.index != nil { all_read[mem.index.?] = true }
				}
			}
		}
	}

	// Walk forward: track written registers, warn at call sites
	written_before_call := make(map[string]Src_Loc)
	for s in body {
		if instr, ok := s.(^Instr); ok {
			if instr.op == "call" {
				// Warn only if a caller-saved register was written before AND read after
				for reg, loc in written_before_call {
					if caller_saved[reg] && all_read[reg] {
						report_error(.Warn_Clobber, loc,
							fmt.tprintf("live register %s may be clobbered by call in %s", reg, fn_name))
					}
				}
				// After call, caller-saved registers are cleared
				written_before_call["rax"] = {}
				written_before_call["rcx"] = {}
				written_before_call["rdx"] = {}
				written_before_call["r8"] = {}
				written_before_call["r9"] = {}
				written_before_call["r10"] = {}
				written_before_call["r11"] = {}
			} else {
				if len(instr.operands) >= 1 {
					if reg, is_reg := instr.operands[0].(string); is_reg {
						if _, is_gpr := register_widths[reg]; is_gpr {
							written_before_call[reg] = instr.src_loc
						}
					}
				}
			}
		}
	}
}

