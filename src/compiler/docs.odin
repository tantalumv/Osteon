package compiler

// Namespace: compiler
// The Osteon compiler package. Contains the lexer, parser, AST definitions,
// desugaring passes, x86-64 code generator, and PE32+/COFF emitters.
// All compiler phases are implemented in Odin.

// ======================================================================
// Documentation Index — Natural Docs Comment Templates
// ======================================================================
// This file serves as a reference index for all public APIs in the
// Osteon compiler. Each entry links to the actual implementation file.
//
// Natural Docs uses "// Keyword: Name" format for line comments.
// Blank continuation lines must also start with "//".
//
// See also: docs/Languages.txt for Odin language configuration.

// ======================================================================
// main.odin — Entry Point and Compilation Pipeline
// ======================================================================

// Function: main
// Main entry point for the Osteon compiler. Parses command-line arguments,
// initializes the error engine, loads packages, runs compilation pipeline
// passes (const eval, layout, static_assert, desugaring, inline expansion),
// and emits the final PE32+ executable or COFF object file.
//
// Returns: Exits via os.exit with code 0 on success, 1 on fatal error.

// Function: explain_error
// Prints a detailed explanation of a compiler error code to stdout.
//
// Parameters:
//   code - error code string (e.g., "fatal/width", "warn/dead")

// Function: run_tests
// Runs the test suite by scanning the specified directory for .ostn test
// files, compiling each with --emit exe, running the resulting executable,
// and comparing the exit code against the expected exit code.
//
// Parameters:
//   test_dir - path to directory containing test files (default: tests/valid)

// Function: parse_expected_exit_code
// Extracts the expected exit code from a test filename.
// Filename format: name.exitcode.ostn (e.g., test.0.ostn)
//
// Parameters:
//   filename - the test filename to parse
//
// Returns: expected exit code as integer, or 0 if not found

// Function: strip_release
// Removes debug-only instructions from a function body for release builds.
// Strips breakpoint instructions (int3/breakpoint).
//
// Parameters:
//   body - the list of statements representing the function body
//
// Returns: new dynamic array of statements with release-safe instructions only

// Function: expand_inline_fns
// Expands inline function bodies at all call sites across packages.
//
// Parameters:
//   packages - slice of packages containing functions to process

// Function: expand_inline_in_body
// Walks a function body and expands any call to an inline function.
// Supports both zero-operand inline calls and explicit call instructions.
// Also handles mangled namespace syntax (ns::fn).
//
// Parameters:
//   body       - the list of statements representing the function body
//   inline_fns - pointer to map of inline function names to their bodies

// Function: resolve_aliases
// Rewrites let alias declarations to their underlying register names.
//
// Parameters:
//   body - the list of statements representing the function body

// Function: print_desugared_body
// Prints the desugared AST representation of a function body.
//
// Parameters:
//   body - the list of statements to print

// Function: print_operand
// Prints a single operand in human-readable format.
//
// Parameters:
//   op - the operand to print (string, Immediate, or Mem_Ref)

// Function: is_terminating
// Determines whether an instruction terminates a basic block.
//
// Parameters:
//   op - the opcode string to check (e.g., "ret", "jmp", "ud2")
//
// Returns: true if the instruction is a terminator

// Function: check_analysis_passes
// Runs all analysis passes on functions in the given packages.
//
// Parameters:
//   packages - slice of packages to analyze
//   is_debug - whether this is a debug build

// Function: check_canary_missing
// Checks if a function allocates stack space but does not have a canary.
//
// Parameters:
//   fn - the function declaration to check

// Function: check_unreachable
// Reports warnings for instructions after a terminating instruction.
//
// Parameters:
//   pkg      - the package containing the function
//   fn_name  - the name of the function being checked
//   body     - the function body statements to analyze
//   fn_loc   - the source location of the function

// Function: check_breakpoint
// Reports hints for breakpoint instructions in non-debug builds.
//
// Parameters:
//   pkg     - the package containing the function
//   fn_name - the name of the function being checked
//   body    - the function body statements to analyze

// Function: check_dead_code
// Reports warnings for registers written but never read before return.
//
// Parameters:
//   pkg     - the package containing the function
//   fn_name - the name of the function being checked
//   body    - the function body statements to analyze

// Function: check_noret
// Reports hints for functions that may not return on all code paths.
//
// Parameters:
//   pkg     - the package containing the function
//   fn_name - the name of the function being checked
//   body    - the function body statements to analyze

// Function: check_uninit
// Reports fatal errors for registers read before being written.
//
// Parameters:
//   pkg     - the package containing the function
//   fn_name - the name of the function being checked
//   body    - the function body statements to analyze
//   fn_loc  - the source location of the function

// Function: check_clobber
// Reports warnings for caller-saved registers clobbered by function calls.
//
// Parameters:
//   pkg     - the package containing the function
//   fn_name - the name of the function being checked
//   body    - the function body statements to analyze

// ======================================================================
// lexer.odin — Lexical Analysis
// ======================================================================

// Function: init_lexer
// Initializes a new Lexer with source file and contents.
// Sets up line/col counters and reads the first character.
//
// Parameters:
//   file   - source file name for tracking source locations
//   source - entire source code content to be lexed
//
// Returns: Initialized Lexer ready for tokenization

// Function: next_token
// Returns the next Token from the lexer input stream.
// Handles symbols, keywords, identifiers, registers, numbers, and strings.
//
// Parameters:
//   l - pointer to the Lexer instance
//
// Returns: Next Token with kind, text, and source location

// Function: skip_whitespace_and_comments
// Skips whitespace characters and # line comments before the next token.
//
// Parameters:
//   l - pointer to the Lexer instance

// Function: lex_identifier_or_keyword
// Lexes an identifier or keyword token.
//
// Parameters:
//   l - pointer to the Lexer instance
//
// Returns: Token with kind Identifier, Register, or keyword

// Function: lex_number
// Lexes a numeric literal (decimal, hex 0x, binary 0b, octal 0o, float).
//
// Parameters:
//   l - pointer to the Lexer instance
//
// Returns: Token with kind Integer or Float

// Function: lex_string
// Lexes a string literal enclosed in double quotes.
//
// Parameters:
//   l - pointer to the Lexer instance
//
// Returns: Token with kind String

// Function: is_register
// Checks if a string is a recognized x86-64 register name (GPR or SIMD).
//
// Parameters:
//   text - the string to check
//
// Returns: true if the text is a valid register name

// ======================================================================
// parser.odin — Syntax Analysis
// ======================================================================

// Function: parse_program
// Parses a complete Osteon program into an AST.
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Pointer to a newly allocated Program

// Function: parse_top_level
// Parses a single top-level declaration.
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Stmt representing the parsed declaration

// Function: parse_fn_decl
// Parses a function or inline function declaration.
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Stmt (^Fn_Decl or ^Inline_Fn_Decl)

// Function: parse_struct_decl
// Parses a struct type declaration with optional layout(soa) annotation.
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Pointer to newly allocated Struct_Decl

// Function: parse_instruction
// Parses a single instruction with opcode, width annotation, and operands.
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Pointer to newly allocated Instr

// Function: parse_operand
// Parses a single instruction operand (register, immediate, deref, imm).
//
// Parameters:
//   p - pointer to the Parser instance
//
// Returns: Parsed Operand value

// Function: is_known_opcode
// Checks if a string is a known x86-64 instruction opcode.
// Used to prevent operand loop from consuming the next opcode.
//
// Parameters:
//   text - the string to check
//
// Returns: true if the text is a known instruction mnemonic

// ======================================================================
// ast.odin — Abstract Syntax Tree Types
// ======================================================================
// See ast.odin for full type definitions:
//   Type: Src_Loc, Token, Token_Kind, Width, Opcode
//   Type: Const_Expr, Sizeof_Expr, Alignof_Expr, Binop_Expr, Unop_Expr
//   Type: Operand, Immediate, Mem_Ref
//   Type: Stmt, Instr, Fn_Decl, Inline_Fn_Decl
//   Type: Struct_Decl, Layout_Kind, Struct_Field
//   Type: Data_Decl, Data_Value, Const_Decl
//   Type: Import_Decl, Namespace_Decl, Extern_Decl
//   Type: Let_Decl, Label_Decl, Arena_Decl, Alloc_Stmt, Reset_Stmt
//   Type: For_Loop, While_Loop, Assert_Stmt, Expect_Stmt
//   Type: Breakpoint_Stmt, Unreachable_Stmt, Result_Decl, Program

// ======================================================================
// error.odin — Error Reporting Engine
// ======================================================================

// Function: init_error_engine
// Initializes the global error state for reporting.
//
// Parameters:
//   json_mode - whether to output errors in JSON format
//   no_color  - whether to disable ANSI color codes

// Function: report_error
// Reports a compiler error with full source context.
// Exits with code 1 for fatal errors.
//
// Parameters:
//   code       - the Error_Code identifying the error type
//   loc        - source location of the error
//   message    - human-readable error message
//   correction - optional suggestion for fixing the error

// Function: print_annotated_error
// Prints an annotated error message with source context lines.
//
// Parameters:
//   err      - the JSON_Error structure with context
//   severity - the error severity level

// Function: flush_json_errors
// Flushes all collected errors as JSON to stderr.

// ======================================================================
// desugar.odin — Desugaring Pass
// ======================================================================

// Function: init_desugar
// Resets the desugaring label counter.

// Function: desugar_stmts
// Transforms structured control flow (for, while, expect, assert,
// arena/alloc/reset) into raw instructions.
//
// Parameters:
//   stmts - the input statement list to desugar
//
// Returns: new dynamic array of desugared statements

// Function: desugar_for_loop
// Desugars a for-loop into: mov, label, cmp, jcc, body, add, jmp.
//
// Parameters:
//   loop - the For_Loop to desugar
//   out  - output statement list

// Function: desugar_while_loop
// Desugars a while-loop into: label, cond, jcc, body, cond, jcc, label.
//
// Parameters:
//   loop - the While_Loop to desugar
//   out  - output statement list

// Function: desugar_expect
// Desugars expect("msg") into: test rdx,rdx; jz ok; ud2; label ok
//
// Parameters:
//   e   - the Expect_Stmt to desugar
//   out - output statement list

// Function: desugar_assert
// Desugars a runtime assert into: cmp; jcc ok; ud2; label ok
//
// Parameters:
//   a   - the Assert_Stmt to desugar
//   out - output statement list

// Function: inverse_condition
// Returns the opposite jump condition code (e.g., "jz" -> "jnz").
//
// Parameters:
//   cc - the jump condition mnemonic
//
// Returns: the inverted jump condition mnemonic

// Function: desugar_canary
// Desugars canary into: mov(u64) deref(rbp, -8), imm(CANARY_VALUE)
//
// Parameters:
//   c   - the canary Instr
//   out - output statement list

// Function: desugar_check_canary
// Desugars check_canary into: cmp; je ok; ud2; label ok
//
// Parameters:
//   c   - the check_canary Instr
//   out - output statement list

// Function: desugar_mova
// Desugars mova (bounds-checked access) into: cmp; jb ok; ud2; label ok; mov
//
// Parameters:
//   m   - the mova Instr
//   out - output statement list

// ======================================================================
// x86_64.odin — x86-64 Machine Code Encoder
// ======================================================================

// Function: encode_instr
// Main instruction encoder. Dispatches to specific encoders based on
// opcode and operand count. Handles ALU, MOV, branches, SIMD, and
// special instructions.
//
// Parameters:
//   ctx   - pointer to the Encoder_Context
//   instr - pointer to the Instr to encode

// Function: resolve_patches
// Resolves all forward-referenced labels by patching displacement fields.
//
// Parameters:
//   ctx            - pointer to the Encoder_Context
//   unresolved_out - optional output list for unresolved patches

// Function: define_label
// Records a label definition at the current buffer position.
//
// Parameters:
//   ctx  - pointer to the Encoder_Context
//   name - label name

// Function: encode_jmp_label
// Emits JMP rel32 to a label (opcode 0xE9).
//
// Parameters:
//   ctx   - pointer to the Encoder_Context
//   label - target label name

// Function: encode_jcc_label
// Emits Jcc rel32 to a label (opcode 0x0F 0x80+cc).
//
// Parameters:
//   ctx      - pointer to the Encoder_Context
//   mnemonic - condition mnemonic (e.g., "jnz")
//   label    - target label name

// Function: encode_call_label
// Emits CALL rel32 to a label (opcode 0xE8).
//
// Parameters:
//   ctx    - pointer to the Encoder_Context
//   target - target label name

// ======================================================================
// pe32.odin — PE32+ Executable Emitter
// ======================================================================

// Function: emit_pe32_exe
// Emits a PE32+ executable file with entry stub, user code, and headers.
//
// Parameters:
//   output_path - path for the output .exe file
//   packages    - array of loaded packages to encode
//   is_debug    - whether to include debug info

// ======================================================================
// coff.odin — COFF Object File Emitter
// ======================================================================

// Function: emit_coff_obj
// Emits a COFF object file with .text and .data sections, symbol table,
// string table, and relocations.
//
// Parameters:
//   file_path - path for the output .obj file
//   packages  - array of loaded packages to encode

// ======================================================================
// const_eval.odin — Compile-Time Constant Evaluation
// ======================================================================

// Function: eval_const_expr
// Evaluates a compile-time constant expression tree.
// Supports integer/float literals, identifiers, binops, unops,
// SIZEOF, ALIGNOF, SIZEOF_SOA, @offset, @soa_offset.
//
// Parameters:
//   expr - the constant expression to evaluate
//   pkg  - optional package context for symbol lookup
//
// Returns: Constant_Value (i64 or f64)

// ======================================================================
// layout.odin — Struct Layout Resolution
// ======================================================================

// Function: resolve_struct_layout
// Computes field offsets and total size for a struct declaration.
// Supports both AoS (sequential) and SoA (structure of arrays) layouts.
//
// Parameters:
//   decl - the Struct_Decl to resolve
//   pkg  - the package containing the declaration

// ======================================================================
// import.odin — Package Import Loading
// ======================================================================

// Function: load_all_packages
// Loads the main file and all transitively imported packages.
// Handles circular import detection and diamond import dedup.
//
// Parameters:
//   main_file - path to the main source file
//
// Returns: dynamic array of all loaded packages

// Function: load_package_recursive
// Recursively loads a package and its imports using DFS.
//
// Parameters:
//   file - path to the source file to load
//
// Returns: pointer to the loaded Package

// Function: resolve_import_path
// Resolves a relative import path against the importing file's directory.
//
// Parameters:
//   base_file   - the file containing the import
//   import_path - the relative import path string
//
// Returns: resolved absolute file path

// ======================================================================
// namespace.odin — Namespace Resolution
// ======================================================================

// Function: resolve_package_namespace
// Resolves a package's namespace from its filename or explicit declaration.
// Checks for namespace collisions with already-loaded packages.
//
// Parameters:
//   pkg - pointer to the Package to resolve

// ======================================================================
// width.odin — Width Consistency Checking
// ======================================================================

// Function: checkWidthConsistency
// Checks that instruction widths match register widths across all packages.
// Reports fatal/width errors for mismatches.
//
// Parameters:
//   packages - slice of packages to check

// ======================================================================
// modrm.odin — ModR/M and REX Encoding
// ======================================================================

// Function: encode_modrm
// Encodes a ModR/M byte from mod, reg, and rm fields.
//
// Parameters:
//   mod - the Mod addressing mode
//   reg - the register field (3 bits)
//   rm  - the r/m field (3 bits)
//
// Returns: encoded ModR/M byte

// Function: encode_sib
// Encodes a SIB (Scale-Index-Base) byte.
//
// Parameters:
//   scale - scale factor (1, 2, 4, or 8)
//   index - index register ID (3 bits)
//   base  - base register ID (3 bits)
//
// Returns: encoded SIB byte

// Function: encode_rex
// Encodes a REX prefix byte with W, R, X, B bits.
//
// Parameters:
//   w - 64-bit operand size
//   r - extension of ModR/M reg field
//   x - extension of SIB index field
//   b - extension of ModR/M r/m field
//
// Returns: encoded REX prefix byte
