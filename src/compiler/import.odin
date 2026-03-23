package compiler

import "core:fmt"
import "core:os"
import "core:path/filepath"

// Track files currently being loaded (for circular import detection)
files_loading := map[string]bool{}
// Track files already loaded (for diamond import dedup)
loaded_files := map[string]^Package{}

load_all_packages :: proc(main_file: string) -> [dynamic]^Package {
	init_namespace_resolution()
	files_loading = make(map[string]bool)
	loaded_files = make(map[string]^Package)

	load_package_recursive(main_file)

	// Collect all packages from global_packages (populated by DFS)
	packages := make([dynamic]^Package)
	for _, pkg in global_packages {
		append(&packages, pkg)
	}
	return packages
}

// DFS load: recursively loads imports. The call stack IS the cycle detector.
load_package_recursive :: proc(file: string) -> ^Package {
	// Diamond import dedup — already loaded, skip
	if pkg, exists := loaded_files[file]; exists {
		return pkg
	}

	// Circular import check — if this file is already on the call stack
	if files_loading[file] {
		fmt.eprintf("Error: Circular import detected: %s\n", file)
		os.exit(1)
	}

	files_loading[file] = true
	defer {
		files_loading[file] = false
	}

	// Read, lex, parse
	data, err := os.read_entire_file_from_path(file, context.allocator)
	if err != 0 {
		fmt.eprintf("Error: Could not read file %s\n", file)
		os.exit(1)
	}

	lexer := init_lexer(file, string(data))
	parser := init_parser(lexer)
	prog := parse_program(&parser)

	pkg := new(Package)
	pkg.file = file
	pkg.program = prog
	pkg.imports = make(map[string]string)

	resolve_package_namespace(pkg)

	// Cache before processing imports (so recursive calls find it)
	loaded_files[file] = pkg

	// Recursively process imports
	for stmt in pkg.program.stmts {
		if imp, ok := stmt.(^Import_Decl); ok {
			abs_path := resolve_import_path(file, imp.path)

			sub_pkg := load_package_recursive(abs_path)

			alias := imp.alias
			if alias == "" {
				alias = sub_pkg.name
			}
			pkg.imports[alias] = sub_pkg.name
		}
	}

	return pkg
}

resolve_import_path :: proc(base_file: string, import_path: string) -> string {
	dir := filepath.dir(base_file)
	res, _ := filepath.join([]string{dir, import_path}, context.allocator)
	return res
}
