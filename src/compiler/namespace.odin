package compiler

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Package :: struct {
	name:      string, // namespace name
	file:      string,
	program:   ^Program,
	imports:   map[string]string, // alias -> namespace_name
}

global_packages: map[string]^Package // namespace_name -> Package

init_namespace_resolution :: proc() {
	global_packages = make(map[string]^Package)
}

resolve_package_namespace :: proc(pkg: ^Package) {
	// 1. Default from filename
	base := filepath.base(pkg.file)
	ext := filepath.ext(base)
	default_name := base[:len(base)-len(ext)]
	
	pkg.name = default_name
	
	// 2. Override from Namespace_Decl
	found_decl := false
	for stmt in pkg.program.stmts {
		if decl, ok := stmt.(^Namespace_Decl); ok {
			if found_decl {
				report_error(.Fatal_Namespace, decl.src_loc, "Multiple namespace declarations in one file")
			}
			pkg.name = decl.name
			found_decl = true
		}
	}
	
	// 3. Check for collisions
	if existing, exists := global_packages[pkg.name]; exists {
		if existing.file != pkg.file {
			loc: Src_Loc
			if len(pkg.program.stmts) > 0 {
				loc = get_stmt_loc(pkg.program.stmts[0])
			}
			report_error(.Fatal_Namespace, loc, fmt.tprintf("Namespace collision: %s is defined in both %s and %s", pkg.name, existing.file, pkg.file))
		}
	}
	
	global_packages[pkg.name] = pkg
}

// (Will need to implement get_loc for all AST nodes or just use a helper)
get_stmt_loc :: proc(stmt: Stmt) -> Src_Loc {
	#partial switch s in stmt {
	case ^Instr: return s.src_loc
	case ^Fn_Decl: return s.src_loc
	case ^Inline_Fn_Decl: return s.src_loc
	case ^Struct_Decl: return s.src_loc
	case ^Data_Decl: return s.src_loc
	case ^Const_Decl: return s.src_loc
	case ^Import_Decl: return s.src_loc
	case ^Namespace_Decl: return s.src_loc
	case ^Extern_Decl: return s.src_loc
	case ^Let_Decl: return s.src_loc
	case ^Label_Decl: return s.src_loc
	case ^Arena_Decl: return s.src_loc
	case ^Alloc_Stmt: return s.src_loc
	case ^Reset_Stmt: return s.src_loc
	case ^For_Loop: return s.src_loc
	case ^While_Loop: return s.src_loc
	case ^Assert_Stmt: return s.src_loc
	case ^Expect_Stmt: return s.src_loc
	case ^Breakpoint_Stmt: return s.src_loc
	case ^Unreachable_Stmt: return s.src_loc
	case: return {}
	}
}
