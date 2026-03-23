package compiler

import "core:fmt"

Src_Loc :: struct {
	file: string,
	line: int,
	col:  int,
}

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

Token :: struct {
	kind:    Token_Kind,
	text:    string,
	src_loc: Src_Loc,
}

Width :: enum {
	U8, U16, U32, U64,
	F32, F64,
}

Opcode :: string

// --- Expressions ---

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

Sizeof_Expr :: struct {
	type_name: string,
}

Alignof_Expr :: struct {
	type_name: string,
}

Sizeof_Soa_Expr :: struct {
	type_name: string,
	capacity:  Const_Expr,
}

Offset_Expr :: struct {
	type_name:  string,
	field_name: string,
}

Soa_Offset_Expr :: struct {
	type_name:  string,
	field_name: string,
	capacity:   Const_Expr,
}

Binop_Expr :: struct {
	op:  Token_Kind,
	lhs: Const_Expr,
	rhs: Const_Expr,
}

Unop_Expr :: struct {
	op:      Token_Kind,
	operand: Const_Expr,
}

// --- Operands ---

Operand :: union {
	string,             // Register name, Alias name, or Label/Qual reference
	Immediate,
	Mem_Ref,
}

Immediate :: struct {
	expr: Const_Expr,
}

Mem_Ref :: struct {
	base:   Maybe(string), // Register/Alias name
	index:  Maybe(string), // Register/Alias name
	scale:  int,           // 1, 2, 4, 8
	offset: Const_Expr,
}

// --- Statements ---

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

Instr :: struct {
	op:            Opcode,
	width:         Maybe(Width),
	prefix:        u8,             // 0 = none, 0xF0 = lock, 0x3E = likely, 0x2E = unlikely
	operands:      [dynamic]Operand,
	src_loc:       Src_Loc,
}

Fn_Decl :: struct {
	is_static: bool,
	name:      string,
	body:      []Stmt,
	src_loc:   Src_Loc,
}

Inline_Fn_Decl :: struct {
	name:    string,
	body:    []Stmt,
	src_loc: Src_Loc,
}

Struct_Decl :: struct {
	name:   string,
	layout: Layout_Kind,
	fields: []Struct_Field,
	src_loc: Src_Loc,
}

Layout_Kind :: enum { AoS, SoA }

Struct_Field :: struct {
	name: string,
	type: Width,
}

Data_Decl :: struct {
	is_static:   bool,
	name:        string,
	type:        Width,
	struct_name: string, // set when type represents a named struct (for data init ordering)
	is_array:    bool,
	value:       Data_Value,
	src_loc:     Src_Loc,
}

Data_Value :: union {
	i64,
	f64,
	string,
	[]Data_Value,
	map[string]Data_Value, // struct init
}

Const_Decl :: struct {
	name:    string,
	expr:    Const_Expr,
	src_loc: Src_Loc,
}

Import_Decl :: struct {
	path:    string,
	alias:   string,
	src_loc: Src_Loc,
}

Namespace_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

Extern_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

Let_Decl :: struct {
	name:        string,
	reg:         string,
	noalias:     bool,           // pointer guaranteed non-overlapping
	provenance:  string,         // provenance kind: "extern", "arena(name)", "stack", "static", "raw", or ""
	src_loc:     Src_Loc,
}

Label_Decl :: struct {
	name:    string,
	src_loc: Src_Loc,
}

Arena_Decl :: struct {
	name:    string,
	buf:     Operand,
	size:    Const_Expr,
	src_loc: Src_Loc,
}

Alloc_Stmt :: struct {
	arena_name: string,
	size:       Const_Expr,
	align:      Const_Expr,
	src_loc:    Src_Loc,
}

Reset_Stmt :: struct {
	arena_name: string,
	src_loc:    Src_Loc,
}

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

While_Loop :: struct {
	cond:    ^Instr,
	jump_cc: string,
	body:    []Stmt,
	src_loc: Src_Loc,
}

Assert_Stmt :: struct {
	is_static: bool,
	cond:      union { ^Instr, Const_Expr },
	jump_cc:   string, // for runtime assert
	message:   string,
	src_loc:   Src_Loc,
}

Expect_Stmt :: struct {
	message: string,
	src_loc: Src_Loc,
}

Breakpoint_Stmt :: struct {
	src_loc: Src_Loc,
}

Unreachable_Stmt :: struct {
	src_loc: Src_Loc,
}

Result_Decl :: struct {
	type:    Width,
	src_loc: Src_Loc,
}

Program :: struct {
	stmts: [dynamic]Stmt,
}
