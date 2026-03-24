package compiler

import "core:fmt"

// Type: Src_Loc
// Structure representing a source code location for error reporting
// and debugging.
//
// Fields:
//   file - source file path
//   line - line number (1-indexed)
//   col  - column number (1-indexed)
Src_Loc :: struct {
	file: string,
	line: int,
	col:  int,
}

// Type: Token_Kind
// Enumeration of all token types in the Osteon language.
// Includes keywords, symbols, and special tokens for parsing.
Token_Kind :: enum {
	Invalid,
	EOF,

	// Keywords
	Fn, Inline, Label, Extern, Import, As, Namespace,
	Section, Static, Global, Const, Struct, Layout, Data, Let,
	For, While, Arena, Alloc, Reset,
	Unreachable, Breakpoint,
	Assert, Static_Assert, Expect,
	Result,
	Lock, Pause, Likely, Unlikely,
	Canary, Check_Canary,

	// Symbols
	Identifier,
	Integer,
	Float,
	String,
	
	Colon, Double_Colon, Semicolon, Comma, Dot,
	Paren_Open, Paren_Close,
	Brace_Open, Brace_Close,
	Bracket_Open, Bracket_Close,
	Eq, Plus, Minus, Star, Slash, Percent,
	Shl, Shr, Amp, Pipe, Hat, Tilde,
	Eq_Eq, Not_Eq, Lt, Lt_Eq, Gt, Gt_Eq,

	// Registers
	Register,
}

// Type: Token
// Represents a single lexical token with kind, text, and source location.
//
// Fields:
//   kind    - Token_Kind enumeration value
//   text    - raw text of the token
//   src_loc - source location for error reporting
Token :: struct {
	kind:    Token_Kind,
	text:    string,
	src_loc: Src_Loc,
}

// Type: Width
// Enumeration of data width specifiers for instructions and types.
// Used to determine operand size and encoding.
//
// Fields:
//   U8  - 8-bit unsigned integer
//   U16 - 16-bit unsigned integer
//   U32 - 32-bit unsigned integer
//   U64 - 64-bit unsigned integer
//   F32 - 32-bit floating point
//   F64 - 64-bit floating point
Width :: enum {
	U8, U16, U32, U64,
	F32, F64,
}

// Type: Opcode
// Represents an instruction opcode as a string (e.g., "mov", "add", "jmp").
Opcode :: string

// --- Expressions ---

// Type: Const_Expr
// Union type for compile-time constant expressions. Can be a literal
// integer, float, string identifier, or a compound expression node.
//
// Variants:
//   i64            - integer literal
//   f64            - float literal
//   string         - identifier or qualified name reference
//   ^Sizeof_Expr   - SIZEOF(type) expression
//   ^Alignof_Expr  - ALIGNOF(type) expression
//   ^Sizeof_Soa_Expr - SIZEOF_SOA(type, cap) expression
//   ^Offset_Expr   - @offset(type, field) expression
//   ^Soa_Offset_Expr - @soa_offset(type, field, cap) expression
//   ^Binop_Expr    - binary operation expression
//   ^Unop_Expr     - unary operation expression
Const_Expr :: union {
	i64,
	f64,
	string,             // identifier or qualified name
	^Sizeof_Expr,
	^Alignof_Expr,
	^Sizeof_Soa_Expr,
	^Offset_Expr,
	^Soa_Offset_Expr,
	^Binop_Expr,
	^Unop_Expr,
}

// Type: Sizeof_Expr
// Compile-time SIZEOF expression that returns the byte size of a type.
//
// Fields:
//   type_name - name of the type to query
Sizeof_Expr :: struct {
	type_name: string,
}

// Type: Alignof_Expr
// Compile-time ALIGNOF expression that returns the alignment of a type.
//
// Fields:
//   type_name - name of the type to query
Alignof_Expr :: struct {
	type_name: string,
}

// Type: Sizeof_Soa_Expr
// Compile-time SIZEOF_SOA expression for computing SoA block sizes.
//
// Fields:
//   type_name - name of the struct type
//   capacity  - capacity expression
Sizeof_Soa_Expr :: struct {
	type_name: string,
	capacity:  Const_Expr,
}

// Type: Offset_Expr
// Compile-time @offset expression for AoS field byte offsets.
//
// Fields:
//   type_name  - name of the struct type
//   field_name - name of the field
Offset_Expr :: struct {
	type_name:  string,
	field_name: string,
}

// Type: Soa_Offset_Expr
// Compile-time @soa_offset expression for SoA field array byte offsets.
//
// Fields:
//   type_name  - name of the struct type
//   field_name - name of the field
//   capacity   - capacity expression
Soa_Offset_Expr :: struct {
	type_name:  string,
	field_name: string,
	capacity:   Const_Expr,
}

// Type: Binop_Expr
// Binary operation expression node (e.g., lhs + rhs).
//
// Fields:
//   op  - operator token kind
//   lhs - left-hand side expression
//   rhs - right-hand side expression
Binop_Expr :: struct {
	op:  Token_Kind,
	lhs: Const_Expr,
	rhs: Const_Expr,
}

// Type: Unop_Expr
// Unary operation expression node (e.g., -x, ~x).
//
// Fields:
//   op      - operator token kind
//   operand - the operand expression
Unop_Expr :: struct {
	op:      Token_Kind,
	operand: Const_Expr,
}

// --- Operands ---

// Type: Operand
// Union type for instruction operands: registers, immediates, or memory references.
//
// Variants:
//   string     - register name, alias name, or label/qualified reference
//   Immediate  - immediate value with compile-time expression
//   Mem_Ref    - memory reference with base, index, scale, offset
Operand :: union {
	string,             // Register name, Alias name, or Label/Qual reference
	Immediate,
	Mem_Ref,
}

// Type: Immediate
// Represents an immediate (literal) operand in an instruction.
//
// Fields:
//   expr - constant expression value (i64, f64, string, or compound)
Immediate :: struct {
	expr: Const_Expr,
}

// Type: Mem_Ref
// Represents a memory reference operand in an instruction.
// Supports base + index * scale + offset addressing.
//
// Fields:
//   base   - optional base register name
//   index  - optional index register name
//   scale  - index scaling factor (1, 2, 4, or 8)
//   offset - constant offset expression
Mem_Ref :: struct {
	base:   Maybe(string), // Register/Alias name
	index:  Maybe(string), // Register/Alias name
	scale:  int,           // 1, 2, 4, 8
	offset: Const_Expr,
}

// --- Statements ---

// Type: Stmt
// Union type for all statement kinds in the Osteon AST.
// Covers instructions, declarations, control flow, and directives.
Stmt :: union {
	^Instr,
	^Fn_Decl,
	^Inline_Fn_Decl,
	^Struct_Decl,
	^Data_Decl,
	^Const_Decl,
	^Import_Decl,
	^Namespace_Decl,
	^Extern_Decl,
	^Let_Decl,
	^Label_Decl,
	^Arena_Decl,
	^Alloc_Stmt,
	^Reset_Stmt,
	^For_Loop,
	^While_Loop,
	^Assert_Stmt,
	^Expect_Stmt,
	^Breakpoint_Stmt,
	^Unreachable_Stmt,
	^Result_Decl,
}

// Type: Instr
// Represents a single machine instruction in the AST.
//
// Fields:
//   op       - opcode string (e.g., "mov", "add", "jmp")
//   width    - optional width annotation (e.g., u64)
//   prefix   - instruction prefix byte (0=none, 0xF0=lock, 0x3E=likely, 0x2E=unlikely)
//   operands - dynamic array of Operand values
//   src_loc  - source location for error reporting
Instr :: struct {
	op:            Opcode,
	width:         Maybe(Width),
	prefix:        u8,             // 0 = none, 0xF0 = lock, 0x3E = likely, 0x2E = unlikely
	operands:      [dynamic]Operand,
	src_loc:       Src_Loc,
}

// Type: Fn_Decl
// Represents a function declaration in the AST.
//
// Fields:
//   is_static - whether function has static linkage
//   name      - function name
//   body      - array of statements in function body
//   src_loc   - source location
Fn_Decl :: struct {
	is_static: bool,
	name:      string,
	body:      []Stmt,
	src_loc:   Src_Loc,
}

// Type: Inline_Fn_Decl
// Represents an inline function declaration that gets expanded at call sites.
//
// Fields:
//   name    - inline function name
//   body    - array of statements in function body
//   src_loc - source location
Inline_Fn_Decl :: struct {
	name:    string,
	body:    []Stmt,
	src_loc: Src_Loc,
}

// Type: Struct_Decl
// Represents a struct type declaration with optional layout annotation.
//
// Fields:
//   name   - struct name
//   layout - Layout_Kind (AoS or SoA)
//   fields - array of Struct_Field definitions
//   src_loc - source location
Struct_Decl :: struct {
	name:   string,
	layout: Layout_Kind,
	fields: []Struct_Field,
	src_loc: Src_Loc,
}

// Type: Layout_Kind
// Enumeration of struct memory layout strategies.
//
// Fields:
//   AoS - Array of Structures (default, sequential layout)
//   SoA - Structure of Arrays (optimized for SIMD vectorization)
Layout_Kind :: enum { AoS, SoA }

// Type: Struct_Field
// Represents a single field definition in a struct declaration.
//
// Fields:
//   name - field name
//   type - field data width
Struct_Field :: struct {
	name: string,
	type: Width,
}

// Type: Data_Decl
// Represents a data (global variable) declaration.
//
// Fields:
//   is_static   - whether data has static linkage
//   name        - data name
//   type        - data width type
//   struct_name - name of struct type if applicable
//   is_array    - whether this is an array declaration
//   value       - initial value expression
//   src_loc     - source location
Data_Decl :: struct {
	is_static:   bool,
	name:        string,
	type:        Width,
	struct_name: string, // set when type represents a named struct (for data init ordering)
	is_array:    bool,
	value:       Data_Value,
	src_loc:     Src_Loc,
}

// Type: Data_Value
// Union type for data initialization values.
// Can be an integer, float, string, array of values, or struct field map.
Data_Value :: union {
	i64,
	f64,
	string,
	[]Data_Value,
	map[string]Data_Value, // struct init
}

// Type: Const_Decl
// Represents a compile-time constant declaration.
//
// Fields:
//   name    - constant name
//   expr    - constant expression value
//   src_loc - source location
Const_Decl :: struct {
	name:    string,
	expr:    Const_Expr,
	src_loc: Src_Loc,
}

// Type: Import_Decl
// Represents a file import declaration with optional alias.
//
// Fields:
//   path    - import file path
//   alias   - optional namespace alias
//   src_loc - source location
Import_Decl :: struct {
	path:    string,
	alias:   string,
	src_loc: Src_Loc,
}

// Type: Namespace_Decl
// Represents a namespace declaration that overrides the default
// package name (derived from filename).
//
// Fields:
//   name    - namespace name
//   src_loc - source location
Namespace_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

// Type: Extern_Decl
// Represents an external symbol declaration.
//
// Fields:
//   name    - external symbol name
//   src_loc - source location
Extern_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

// Type: Let_Decl
// Represents a local register alias declaration within a function.
// Maps a name to a register with optional aliasing and provenance info.
//
// Fields:
//   name       - alias name
//   reg        - underlying register name
//   noalias    - pointer aliasing guarantee (non-overlapping)
//   provenance - provenance kind: "extern", "arena(name)", "stack", "static", "raw", or ""
//   src_loc    - source location
Let_Decl :: struct {
	name:        string,
	reg:         string,
	noalias:     bool,           // pointer guaranteed non-overlapping
	provenance:  string,         // provenance kind: "extern", "arena(name)", "stack", "static", "raw", or ""
	src_loc:     Src_Loc,
}

// Type: Label_Decl
// Represents a label declaration for jump targets.
//
// Fields:
//   name    - label name
//   src_loc - source location
Label_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

// Type: Arena_Decl
// Represents an arena (bump allocator) declaration.
// The buffer register becomes the bump pointer base.
//
// Fields:
//   name    - arena name
//   buf     - buffer operand (register or memory reference)
//   size    - arena size expression
//   src_loc - source location
Arena_Decl :: struct {
	name:    string,
	buf:     Operand,
	size:    Const_Expr,
	src_loc: Src_Loc,
}

// Type: Alloc_Stmt
// Represents an allocation from an arena with alignment.
//
// Fields:
//   arena_name - name of the arena to allocate from
//   size       - allocation size expression
//   align      - alignment expression
//   src_loc    - source location
Alloc_Stmt :: struct {
	arena_name: string,
	size:       Const_Expr,
	align:      Const_Expr,
	src_loc:    Src_Loc,
}

// Type: Reset_Stmt
// Represents an arena reset operation that restores the bump pointer.
//
// Fields:
//   arena_name - name of the arena to reset
//   src_loc    - source location
Reset_Stmt :: struct {
	arena_name: string,
	src_loc:    Src_Loc,
}

// Type: For_Loop
// Represents a for-loop construct with counter, start, end, step, and body.
// Supports optional loop labels and loop unrolling.
//
// Fields:
//   label          - optional loop label for break/continue targets
//   unroll_factor  - loop unrolling factor (0 or 1 = no unrolling, N > 1 = unroll N times)
//   counter        - counter register operand
//   start          - start value operand
//   end            - end value operand
//   step           - step value operand
//   body           - loop body statements
//   src_loc        - source location
For_Loop :: struct {
	label:        string,
	unroll_factor: int,       // 0 or 1 = no unrolling, N > 1 = unroll N times
	counter:      Operand,
	start:        Operand,
	end:          Operand,
	step:         Operand,
	body:         []Stmt,
	src_loc:      Src_Loc,
}

// Type: While_Loop
// Represents a while-loop with a condition instruction and body.
//
// Fields:
//   cond    - condition instruction (e.g., cmp)
//   jump_cc - jump condition code for loop exit
//   body    - loop body statements
//   src_loc - source location
While_Loop :: struct {
	cond:    ^Instr,
	jump_cc: string,
	body:    []Stmt,
	src_loc: Src_Loc,
}

// Type: Assert_Stmt
// Represents an assertion statement, either compile-time (static_assert)
// or runtime assert.
//
// Fields:
//   is_static - whether this is a compile-time assertion
//   cond      - condition (Instr for runtime, Const_Expr for static)
//   jump_cc   - jump condition code for runtime assertion success
//   message   - assertion failure message
//   src_loc   - source location
Assert_Stmt :: struct {
	is_static: bool,
	cond:      union { ^Instr, Const_Expr },
	jump_cc:   string, // for runtime assert
	message:   string,
	src_loc:   Src_Loc,
}

// Type: Expect_Stmt
// Represents an expect statement that traps on error via rdx register check.
// Desugars to: test rdx, rdx; jz ok; ud2; label ok
//
// Fields:
//   message - error message for the expect
//   src_loc - source location
Expect_Stmt :: struct {
	message: string,
	src_loc: Src_Loc,
}

// Type: Breakpoint_Stmt
// Represents a breakpoint instruction (int3) inserted by the programmer.
// Stripped in release builds.
//
// Fields:
//   src_loc - source location
Breakpoint_Stmt :: struct {
	src_loc: Src_Loc,
}

// Type: Unreachable_Stmt
// Represents an unreachable code marker that causes a trap if executed.
//
// Fields:
//   src_loc - source location
Unreachable_Stmt :: struct {
	src_loc: Src_Loc,
}

// Type: Result_Decl
// Represents a result type contract annotation. Emits no code;
// used to declare the expected return type of a function.
//
// Fields:
//   type    - the result width type
//   src_loc - source location
Result_Decl :: struct {
	type:    Width,
	src_loc: Src_Loc,
}

// Type: Program
// Represents a complete Osteon program with top-level statements.
//
// Fields:
//   stmts - dynamic array of top-level statements (functions, structs, data, etc.)
Program :: struct {
	stmts: [dynamic]Stmt,
}
