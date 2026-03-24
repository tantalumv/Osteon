package compiler

import "core:fmt"
import "core:os"
import "core:path/filepath"

// Track files currently being loaded (for circular import detection)
files_loading := map[string]bool{}
// Track files already loaded (for diamond import dedup)
loaded_files := map[string]^Package{}

// Function: load_all_packages
// Entry point for package loading. Initializes namespace resolution and
// recursively loads the main file and all its transitive imports.
// Returns all loaded packages collected from the global registry.
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

// Function: load_package_recursive
// Performs a DFS load of a source file and all its imports. Uses the call stack
// for circular import detection and a visited map for diamond import deduplication.
// Reads, lexes, parses the file, resolves its namespace, and recurses into imports.
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

// Function: resolve_import_path
// Resolves an import path relative to the directory of the importing file.
// Returns the absolute path to the imported source file.
resolve_import_path :: proc(base_file: string, import_path: string) -> string {
	dir := filepath.dir(base_file)
	res, _ := filepath.join([]string{dir, import_path}, context.allocator)
	return res
}
