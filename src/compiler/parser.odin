package compiler

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Function: parse_integer
// Parses a numeric string literal into a signed 64-bit integer.
// Supports decimal, hexadecimal (0x/0X), binary (0b/0B), and octal (0o/0O) prefixes.
// Returns the parsed value, or 0 on failure.
parse_integer :: proc(text: string) -> i64 {
	if strings.has_prefix(text, "0x") || strings.has_prefix(text, "0X") {
		val, _ := strconv.parse_int(text[2:], 16)
		return i64(val)
	}
	if strings.has_prefix(text, "0b") || strings.has_prefix(text, "0B") {
		val, _ := strconv.parse_int(text[2:], 2)
		return i64(val)
	}
	if strings.has_prefix(text, "0o") || strings.has_prefix(text, "0O") {
		val, _ := strconv.parse_int(text[2:], 8)
		return i64(val)
	}
	val, _ := strconv.parse_i64(text)
	return val
}

// Type: Parser
// Incremental token-stream parser that consumes a Lexer and produces an AST.
// Tracks the current and previous tokens for lookahead and context during parsing.
Parser :: struct {
	lexer: Lexer,
	curr:  Token,
	prev:  Token,
}

// Function: init_parser
// Creates a new Parser from the given Lexer and advances to the first token.
// Returns the initialized Parser ready for parsing.
init_parser :: proc(lexer: Lexer) -> Parser {
	p := Parser{lexer = lexer}
	advance_token(&p)
	return p
}

// Function: advance_token
// Moves the parser forward by one token, storing the previous token for backtracking.
advance_token :: proc(p: ^Parser) {
	p.prev = p.curr
	p.curr = next_token(&p.lexer)
}

// Function: expect_token
// Asserts the current token matches the expected kind and advances on success.
// Reports a fatal syntax error and returns a zero-value token on mismatch.
expect_token :: proc(p: ^Parser, kind: Token_Kind) -> Token {
	if p.curr.kind == kind {
		tok := p.curr
		advance_token(p)
		return tok
	}
	report_error(.Fatal_Syntax, p.curr.src_loc, fmt.tprintf("Expected %v, got %v (%s)", kind, p.curr.kind, p.curr.text))
	return {}
}

// Function: match_token
// Conditionally consumes the current token if it matches the expected kind.
// Returns true if a match occurred and the token was advanced past.
match_token :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr.kind == kind {
		advance_token(p)
		return true
	}
	return false
}

// Function: parse_program
// Entry point for parsing an entire source file into a Program AST node.
// Repeatedly parses top-level statements until EOF is reached.
parse_program :: proc(p: ^Parser) -> ^Program {
	prog := new(Program)
	prog.stmts = make([dynamic]Stmt)

	for p.curr.kind != .EOF {
		stmt := parse_top_level(p)
		if stmt != nil {
			append(&prog.stmts, stmt)
		}
	}

	return prog
}

// Function: parse_top_level
// Dispatches parsing of a single top-level declaration based on the current token kind.
// Handles namespace, import, const, struct, data, extern, fn, static_assert, result, section, and global declarations.
parse_top_level :: proc(p: ^Parser) -> Stmt {
	#partial switch p.curr.kind {
	case .Namespace: return parse_namespace_decl(p)
	case .Import:    return parse_import_decl(p)
	case .Const:     return parse_const_decl(p)
	case .Struct, .Layout: return parse_struct_decl(p)
	case .Data, .Static:   return parse_data_decl(p)
	case .Extern:    return parse_extern_decl(p)
	case .Fn, .Inline: return parse_fn_decl(p)
	case .Static_Assert: return parse_static_assert(p)
	case .Result:    return parse_result_decl(p)
	case .Section:
		// section name — parsed but ignored (no functional effect yet)
		advance_token(p) // section
		expect_token(p, .String)
		return nil
	case .Global:
		// global fn or global data — treat like static
		return parse_global_decl(p)
	case:
		report_error(.Fatal_Syntax, p.curr.src_loc, fmt.tprintf("Unexpected top-level token: %v (%s)", p.curr.kind, p.curr.text))
		return nil
	}
}

// Function: parse_namespace_decl
// Parses a namespace declaration consisting of the 'namespace' keyword followed by an identifier name.
parse_namespace_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // namespace
	name := expect_token(p, .Identifier).text
	res := new(Namespace_Decl)
	res^ = Namespace_Decl{name, loc}
	return res
}

// Function: parse_import_decl
// Parses an import declaration with a string path and optional 'as' alias.
parse_import_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // import
	path := expect_token(p, .String).text
	alias := ""
	if match_token(p, .As) {
		alias = expect_token(p, .Identifier).text
	}
	res := new(Import_Decl)
	res^ = Import_Decl{path, alias, loc}
	return res
}

// Function: parse_const_decl
// Parses a compile-time constant declaration with a name, '=' sign, and constant expression.
parse_const_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // const
	name := expect_token(p, .Identifier).text
	expect_token(p, .Eq)
	expr := parse_const_expr(p)
	res := new(Const_Decl)
	res^ = Const_Decl{name, expr, loc}
	return res
}

// Function: parse_struct_decl
// Parses a struct declaration with an optional layout(soa) modifier.
// Structs contain typed fields separated by commas within braces.
parse_struct_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	layout := Layout_Kind.AoS
	if p.curr.kind == .Layout {
		advance_token(p) // layout
		expect_token(p, .Paren_Open)
		expect_token(p, .Layout) // soa is a keyword too, but let's handle as identifier if needed
		// Actually the EBNF says 'layout' '(' 'soa' ')'
		// Let's adjust Token_Kind if needed, but for now expect literal 'soa'
		if p.curr.text != "soa" {
			report_error(.Fatal_Syntax, p.curr.src_loc, "Expected 'soa'")
		}
		advance_token(p)
		expect_token(p, .Paren_Close)
		layout = .SoA
	}
	
	expect_token(p, .Struct)
	name := expect_token(p, .Identifier).text
	expect_token(p, .Brace_Open)
	
	fields := make([dynamic]Struct_Field)
	for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
		f_name := expect_token(p, .Identifier).text
		expect_token(p, .Colon)
		f_type := parse_type(p)
		expect_token(p, .Comma)
		append(&fields, Struct_Field{f_name, f_type})
	}
	expect_token(p, .Brace_Close)
	
	res := new(Struct_Decl)
	res^ = Struct_Decl{name, layout, fields[:], loc}
	return res
}

// Function: parse_data_decl
// Parses a data declaration with optional static storage, type annotation, and initializer.
// Supports primitive types, struct names, and array types.
parse_data_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	is_static := match_token(p, .Static)
	expect_token(p, .Data)
	name := expect_token(p, .Identifier).text
	expect_token(p, .Colon)

	// Check if the type is a struct name (identifier) vs a primitive type
	struct_name := ""
	type_width: Width

	if p.curr.kind == .Identifier && (p.curr.text == "u8" || p.curr.text == "u16" || p.curr.text == "u32" || p.curr.text == "u64" || p.curr.text == "f32" || p.curr.text == "f64") {
		type_width = parse_type(p)
	} else if p.curr.kind == .Identifier {
		// Struct name — store for later lookup
		struct_name = p.curr.text
		advance_token(p)
		type_width = .U64 // placeholder; actual size comes from struct layout
	} else {
		type_width = parse_type(p)
	}

	is_array := false
	if match_token(p, .Bracket_Open) {
		expect_token(p, .Bracket_Close)
		is_array = true
	}
	
	expect_token(p, .Eq)
	value := parse_data_value(p)
	
	res := new(Data_Decl)
	res^ = Data_Decl{is_static, name, type_width, struct_name, is_array, value, loc}
	return res
}

// Function: parse_extern_decl
// Parses an extern declaration that references an external symbol by name.
parse_extern_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // extern
	name := expect_token(p, .Identifier).text
	res := new(Extern_Decl)
	res^ = Extern_Decl{name, loc}
	return res
}

// Function: parse_fn_decl
// Parses a function declaration with optional inline or static modifiers.
// Functions contain a body of statements enclosed in braces.
// Returns an Inline_Fn_Decl or Fn_Decl depending on the modifier.
parse_fn_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	is_inline := match_token(p, .Inline)
	is_static := false
	if !is_inline {
		is_static = match_token(p, .Static)
	}
	
	expect_token(p, .Fn)
	name := expect_token(p, .Identifier).text
	expect_token(p, .Brace_Open)
	
	body := make([dynamic]Stmt)
	for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
		stmt := parse_fn_stmt(p)
		if stmt != nil {
			append(&body, stmt)
		}
	}
	expect_token(p, .Brace_Close)
	
	if is_inline {
		res := new(Inline_Fn_Decl)
		res^ = Inline_Fn_Decl{name, body[:], loc}
		return res
	} else {
		res := new(Fn_Decl)
		res^ = Fn_Decl{is_static, name, body[:], loc}
		return res
	}
}

// Function: parse_static_assert
// Parses a static assertion that evaluates a constant expression at compile time.
// Optionally accepts a string message displayed on failure.
parse_static_assert :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // static_assert
	expect_token(p, .Paren_Open)
	expr := parse_const_expr(p)
	message := ""
	if match_token(p, .Comma) {
		message = expect_token(p, .String).text
	}
	expect_token(p, .Paren_Close)
	res := new(Assert_Stmt)
	res^ = Assert_Stmt{is_static = true, cond = expr, message = message, src_loc = loc}
	return res
}

// Function: parse_result_decl
// Parses a result(type) contract annotation that specifies the return type of a function.
// Emits no executable code; serves as a type-level contract.
parse_result_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // result
	expect_token(p, .Paren_Open)
	rtype := parse_type(p)
	expect_token(p, .Paren_Close)
	res := new(Result_Decl)
	res^ = Result_Decl{type = rtype, src_loc = loc}
	return res
}

// Function: parse_global_decl
// Parses a global declaration, which is equivalent to a static function or static data declaration.
// Dispatches to fn or data parsing paths based on the token following 'global'.
parse_global_decl :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc
	advance_token(p) // global
	#partial switch p.curr.kind {
	case .Fn:
		// global fn → static fn
		// We need to handle this manually since parse_fn_decl checks for Static keyword
		is_inline := match_token(p, .Inline)
		expect_token(p, .Fn)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Brace_Open)
		
		body := make([dynamic]Stmt)
		for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
			stmt := parse_fn_stmt(p)
			if stmt != nil {
				append(&body, stmt)
			}
		}
		expect_token(p, .Brace_Close)
		
		if is_inline {
			// inline fn doesn't use is_static — just parse as normal
			res := new(Inline_Fn_Decl)
			res^ = Inline_Fn_Decl{name = name, body = body[:], src_loc = loc}
			return res
		} else {
			res := new(Fn_Decl)
			res^ = Fn_Decl{is_static = true, name = name, body = body[:], src_loc = loc}
			return res
		}
	case .Data:
		// global data → static data
		advance_token(p) // data
		name := expect_token(p, .Identifier).text
		expect_token(p, .Colon)

		struct_name := ""
		dtype: Width
		if p.curr.kind == .Identifier && (p.curr.text == "u8" || p.curr.text == "u16" || p.curr.text == "u32" || p.curr.text == "u64" || p.curr.text == "f32" || p.curr.text == "f64") {
			dtype = parse_type(p)
		} else if p.curr.kind == .Identifier {
			struct_name = p.curr.text
			advance_token(p)
			dtype = .U64
		} else {
			dtype = parse_type(p)
		}

		is_array := false
		if match_token(p, .Bracket_Open) {
			expect_token(p, .Bracket_Close)
			is_array = true
		}
		expect_token(p, .Eq)
		value := parse_data_value(p)
		res := new(Data_Decl)
		res^ = Data_Decl{is_static = true, name = name, type = dtype, struct_name = struct_name, is_array = is_array, value = value, src_loc = loc}
		return res
	case:
		report_error(.Fatal_Syntax, p.curr.src_loc, fmt.tprintf("Expected 'fn' or 'data' after 'global', got %v", p.curr.kind))
		return nil
	}
}

// Function: parse_type
// Parses a type token and returns the corresponding Width enum value.
// Supports u8, u16, u32, u64, f32, and f64 type keywords.
parse_type :: proc(p: ^Parser) -> Width {
	tok := p.curr
	advance_token(p)
	switch tok.text {
	case "u8":  return .U8
	case "u16": return .U16
	case "u32": return .U32
	case "u64": return .U64
	case "f32": return .F32
	case "f64": return .F64
	case:
		report_error(.Fatal_Syntax, tok.src_loc, fmt.tprintf("Unknown type: %s", tok.text))
		return .U64
	}
}

// Function: parse_const_expr
// Parses a compile-time constant expression, handling literals, identifiers, and binary operators.
// Uses left-to-right precedence with recursive descent for binary operator chaining.
parse_const_expr :: proc(p: ^Parser) -> Const_Expr {
	// Simplified: handle literals, identifiers, and basic binops
	// Recursion for binops should follow precedence, but for now simple left-to-right or single atoms
	
	lhs := parse_const_atom(p)
	
	if is_binop(p.curr.kind) {
		op := p.curr.kind
		advance_token(p)
		rhs := parse_const_expr(p)
		res := new(Binop_Expr)
		res^ = Binop_Expr{op, lhs, rhs}
		return res
	}
	
	return lhs
}

// Function: parse_const_atom
// Parses a single atomic constant expression such as an integer, float, identifier,
// parenthesized sub-expression, or unary operator (minus/tilde).
// Handles built-in intrinsics like SIZEOF, ALIGNOF, SIZEOF_SOA, @offset, and @soa_offset.
parse_const_atom :: proc(p: ^Parser) -> Const_Expr {
	tok := p.curr
	advance_token(p)
	
	#partial switch tok.kind {
	case .Integer:
		val := parse_integer(tok.text)
		return val
	case .Float:
		val, _ := strconv.parse_f64(tok.text)
		return val
	case .Register:
		// Register name used in const expr context (e.g., deref index)
		return tok.text
	case .Identifier:
		// Check for imm(expr) — immediate value wrapper
		if tok.text == "imm" {
			expect_token(p, .Paren_Open)
			expr := parse_const_expr(p)
			expect_token(p, .Paren_Close)
			return expr
		}
		// Could be SIZEOF etc.
		switch tok.text {
		case "SIZEOF":
			expect_token(p, .Paren_Open)
			type_name := expect_token(p, .Identifier).text
			expect_token(p, .Paren_Close)
			res := new(Sizeof_Expr)
			res^ = Sizeof_Expr{type_name}
			return res
		case "ALIGNOF":
			expect_token(p, .Paren_Open)
			type_name := expect_token(p, .Identifier).text
			expect_token(p, .Paren_Close)
			res := new(Alignof_Expr)
			res^ = Alignof_Expr{type_name}
			return res
		case "SIZEOF_SOA":
			expect_token(p, .Paren_Open)
			type_name := expect_token(p, .Identifier).text
			expect_token(p, .Comma)
			cap := parse_const_expr(p)
			expect_token(p, .Paren_Close)
			res := new(Sizeof_Soa_Expr)
			res^ = Sizeof_Soa_Expr{type_name, cap}
			return res
		case "@offset":
			expect_token(p, .Paren_Open)
			type_name := expect_token(p, .Identifier).text
			expect_token(p, .Comma)
			field_name := expect_token(p, .Identifier).text
			expect_token(p, .Paren_Close)
			res := new(Offset_Expr)
			res^ = Offset_Expr{type_name, field_name}
			return res
		case "@soa_offset":
			expect_token(p, .Paren_Open)
			type_name := expect_token(p, .Identifier).text
			expect_token(p, .Comma)
			field_name := expect_token(p, .Identifier).text
			expect_token(p, .Comma)
			cap := parse_const_expr(p)
			expect_token(p, .Paren_Close)
			res := new(Soa_Offset_Expr)
			res^ = Soa_Offset_Expr{type_name, field_name, cap}
			return res
		case:
			// Check for qualified name
			if p.curr.kind == .Double_Colon {
				advance_token(p)
				sub_name := expect_token(p, .Identifier).text
				return fmt.tprintf("%s::%s", tok.text, sub_name)
			}
			return tok.text
		}
	case .Paren_Open:
		expr := parse_const_expr(p)
		expect_token(p, .Paren_Close)
		return expr
	case .Minus, .Tilde:
		op := tok.kind
		expr := parse_const_atom(p)
		res := new(Unop_Expr)
		res^ = Unop_Expr{op, expr}
		return res
	case:
		report_error(.Fatal_Syntax, tok.src_loc, fmt.tprintf("Unexpected token in const expr: %v", tok.kind))
		return i64(0)
	}
}

// Function: is_binop
// Returns true if the given token kind is a binary operator.
// Covers arithmetic (+, -, *, /, %), shift (<<, >>), bitwise (&, |, ^),
// and comparison (==, !=, <, <=, >, >=) operators.
is_binop :: proc(kind: Token_Kind) -> bool {
	// +, -, *, /, %, <<, >>, &, |, ^, ==, !=, <, <=, >, >=
	#partial switch kind {
	case .Plus, .Minus, .Star, .Slash, .Percent, .Shl, .Shr, .Amp, .Pipe, .Hat: return true
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq: return true
	case: return false
	}
}

// Function: parse_data_value
// Parses a data initializer value, which may be an integer, float, string literal,
// array literal (bracket-enclosed list), or struct initializer (brace-enclosed key-value pairs).
parse_data_value :: proc(p: ^Parser) -> Data_Value {
	tok := p.curr
	advance_token(p)
	
	#partial switch tok.kind {
	case .Integer:
		val := parse_integer(tok.text)
		return val
	case .Float:
		val, _ := strconv.parse_f64(tok.text)
		return val
	case .String:
		return tok.text
	case .Bracket_Open:
		vals := make([dynamic]Data_Value)
		for p.curr.kind != .Bracket_Close && p.curr.kind != .EOF {
			append(&vals, parse_data_value(p))
			if p.curr.kind == .Comma {
				advance_token(p)
			}
		}
		expect_token(p, .Bracket_Close)
		return vals[:]
	case .Brace_Open:
		// Struct init
		inits := make(map[string]Data_Value)
		for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
			name := expect_token(p, .Identifier).text
			expect_token(p, .Colon)
			val := parse_data_value(p)
			inits[name] = val
			if p.curr.kind == .Comma {
				advance_token(p)
			}
		}
		expect_token(p, .Brace_Close)
		return inits
	case:
		report_error(.Fatal_Syntax, tok.src_loc, fmt.tprintf("Unexpected token in data value: %v", tok.kind))
		return i64(0)
	}
}

// Function: parse_fn_stmt
// Parses a single statement within a function body.
// Handles instruction prefixes (lock, likely, unlikely), let bindings, labels, arena allocations,
// for/while loops, assertions, and plain instructions.
parse_fn_stmt :: proc(p: ^Parser) -> Stmt {
	loc := p.curr.src_loc

	// Handle instruction prefixes: lock, likely, unlikely
	prefix_byte: u8 = 0
	if p.curr.kind == .Lock {
		prefix_byte = 0xF0
		advance_token(p)
	} else if p.curr.kind == .Likely {
		prefix_byte = 0x3E
		advance_token(p)
	} else if p.curr.kind == .Unlikely {
		prefix_byte = 0x2E
		advance_token(p)
	}

	#partial switch p.curr.kind {
	case .Let:
		advance_token(p)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Eq)
		reg := expect_token(p, .Register).text

		// Parse optional annotations: noalias, provenance(kind)
		noalias_flag := false
		prov := ""
		if p.curr.kind == .Identifier && p.curr.text == "noalias" {
			noalias_flag = true
			advance_token(p)
		}
		if p.curr.kind == .Identifier && p.curr.text == "provenance" {
			advance_token(p)
			expect_token(p, .Paren_Open)
			kind_name := p.curr.text
			advance_token(p)
			if p.curr.kind == .Paren_Open {
				// provenance(arena(name)) — kind with parenthesized arg
				advance_token(p) // (
				arg := p.curr.text
				advance_token(p)
				expect_token(p, .Paren_Close) // )
				prov = fmt.tprintf("%s(%s)", kind_name, arg)
			} else {
				prov = kind_name
			}
			expect_token(p, .Paren_Close)
		}

		res := new(Let_Decl)
		res^ = Let_Decl{name = name, reg = reg, noalias = noalias_flag, provenance = prov, src_loc = loc}
		return res
	case .Label:
		advance_token(p)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Colon)
		res := new(Label_Decl)
		res^ = Label_Decl{name, loc}
		return res
	case .Arena:
		advance_token(p)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Eq)
		expect_token(p, .Identifier) // init
		expect_token(p, .Paren_Open)
		buf := parse_operand(p)
		expect_token(p, .Comma)
		size := parse_const_expr(p)
		expect_token(p, .Paren_Close)
		res := new(Arena_Decl)
		res^ = Arena_Decl{name, buf, size, loc}
		return res
	case .Alloc:
		advance_token(p)
		expect_token(p, .Paren_Open)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Comma)
		size := parse_const_expr(p)
		expect_token(p, .Comma)
		align := parse_const_expr(p)
		expect_token(p, .Paren_Close)
		res := new(Alloc_Stmt)
		res^ = Alloc_Stmt{name, size, align, loc}
		return res
	case .Reset:
		advance_token(p)
		expect_token(p, .Paren_Open)
		name := expect_token(p, .Identifier).text
		expect_token(p, .Paren_Close)
		res := new(Reset_Stmt)
		res^ = Reset_Stmt{name, loc}
		return res
	case .For:
		advance_token(p)
		label := ""
		unroll_factor := 0
		if match_token(p, .Bracket_Open) {
			if p.curr.kind == .Identifier && p.curr.text == "unroll" {
				// for[unroll(N)]
				advance_token(p) // unroll
				expect_token(p, .Paren_Open)
				unroll_expr := parse_const_expr(p)
				unroll_factor = int(as_i64(eval_const_expr(unroll_expr, nil)))
				expect_token(p, .Paren_Close)
			} else {
				// for[label]
				label = expect_token(p, .Identifier).text
			}
			expect_token(p, .Bracket_Close)
		}
		counter := parse_operand(p)
		expect_token(p, .Eq)
		start := parse_operand(p)
		expect_token(p, .Comma)
		end := parse_operand(p)
		expect_token(p, .Comma)
		step := parse_operand(p)
		expect_token(p, .Brace_Open)
		body := make([dynamic]Stmt)
		for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
			append(&body, parse_fn_stmt(p))
		}
		expect_token(p, .Brace_Close)
		res := new(For_Loop)
		res^ = For_Loop{label = label, unroll_factor = unroll_factor, counter = counter, start = start, end = end, step = step, body = body[:], src_loc = loc}
		return res
	case .While:
		advance_token(p)
		cond := parse_instruction(p)
		expect_token(p, .Slash)
		jump_cc := expect_token(p, .Identifier).text // e.g. jnz
		expect_token(p, .Brace_Open)
		body := make([dynamic]Stmt)
		for p.curr.kind != .Brace_Close && p.curr.kind != .EOF {
			append(&body, parse_fn_stmt(p))
		}
		expect_token(p, .Brace_Close)
		res := new(While_Loop)
		res^ = While_Loop{cond, jump_cc, body[:], loc}
		return res
	case .Assert:
		advance_token(p)
		expect_token(p, .Paren_Open)
		cond := parse_instruction(p)
		expect_token(p, .Comma)
		jump_cc := expect_token(p, .Identifier).text
		expect_token(p, .Comma)
		msg := expect_token(p, .String).text
		expect_token(p, .Paren_Close)
		res := new(Assert_Stmt)
		res^ = Assert_Stmt{is_static = false, cond = cond, jump_cc = jump_cc, message = msg, src_loc = loc}
		return res
	case .Expect:
		advance_token(p)
		expect_token(p, .Paren_Open)
		msg := expect_token(p, .String).text
		expect_token(p, .Paren_Close)
		res := new(Expect_Stmt)
		res^ = Expect_Stmt{msg, loc}
		return res
	case .Breakpoint:
		advance_token(p)
		res := new(Breakpoint_Stmt)
		res^ = Breakpoint_Stmt{loc}
		return res
	case .Unreachable:
		advance_token(p)
		res := new(Unreachable_Stmt)
		res^ = Unreachable_Stmt{loc}
		return res
	case .Canary:
		advance_token(p)
		// canary desugars to: mov deref(rbp, -8), imm(CANARY_VALUE)
		res := new(Instr)
		res^ = Instr{op = "canary", operands = make([dynamic]Operand), src_loc = loc}
		return res
	case .Check_Canary:
		advance_token(p)
		// check_canary desugars to: cmp deref(rbp, -8), imm(CANARY_VALUE); jne __canary_fail; ud2
		res := new(Instr)
		res^ = Instr{op = "check_canary", operands = make([dynamic]Operand), src_loc = loc}
		return res
	case .Identifier, .Register:
		res := parse_instruction(p)
		if prefix_byte != 0 {
			res.prefix = prefix_byte
		}
		return res
	case:
		// Check if a prefix was used but no instruction followed
		if prefix_byte != 0 {
			report_error(.Fatal_Syntax, loc, fmt.tprintf("Prefix keyword must precede an instruction, got %v", p.curr.kind))
			return nil
		}
		report_error(.Fatal_Syntax, loc, fmt.tprintf("Unexpected token in function body: %v (%s)", p.curr.kind, p.curr.text))
		return nil
	}
}

// Function: parse_instruction
// Parses a single machine instruction with its opcode, optional width annotation, and operands.
// Handles special opcodes like prefetch(hint) that modify the opcode string based on a parenthesized argument.
parse_instruction :: proc(p: ^Parser) -> ^Instr {
	loc := p.curr.src_loc
	op := expect_token(p, .Identifier).text // opcode

	// Handle prefetch(hint) — the parenthesized hint is part of the opcode, not a type
	if op == "prefetch" && p.curr.kind == .Paren_Open {
		advance_token(p) // (
		hint := expect_token(p, .Identifier).text // t0, t1, t2, nta
		expect_token(p, .Paren_Close)
		op = fmt.tprintf("prefetch_%s", hint)
	}

	is_type_keyword :: proc(text: string) -> bool {
		switch text {
		case "u8", "u16", "u32", "u64", "f32", "f64":
			return true
		}
		return false
	}

	// Peek at the next token without consuming it (lookahead)
	peek_token :: proc(p: ^Parser) -> Token {
		saved := p^
		tok := next_token(&p.lexer)
		p^ = saved
		return tok
	}

	width: Maybe(Width)
	// Only parse type annotation if the token after ( is a type keyword
	if p.curr.kind == .Paren_Open {
		lookahead := peek_token(p)
		if is_type_keyword(lookahead.text) {
			advance_token(p) // consume (
			width = parse_type(p)
			expect_token(p, .Paren_Close)
		}
	}
	
	operands := make([dynamic]Operand)
	for {
		// Check if there's an operand
		if p.curr.kind == .Brace_Close || p.curr.kind == .EOF || is_keyword_starting_stmt(p.curr.kind) {
			break
		}

		// Don't consume an identifier as an operand if it's a known instruction opcode
		if p.curr.kind == .Identifier && is_known_opcode(p.curr.text) && len(operands) == 0 {
			break
		}

		if !can_start_operand(p.curr.kind) {
			break
		}

		append(&operands, parse_operand(p))

		if !match_token(p, .Comma) {
			break
		}
	}
	
	res := new(Instr)
	res^ = Instr{op = op, width = width, operands = operands, src_loc = loc}
	return res
}

// Function: is_keyword_starting_stmt
// Returns true if the given token kind introduces a new statement (e.g., let, label, for, while, assert).
// Used to terminate operand parsing when a new statement keyword appears.
is_keyword_starting_stmt :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Let, .Label, .Arena, .Alloc, .Reset, .For, .While, .Assert, .Expect, .Breakpoint, .Unreachable, .Canary, .Check_Canary: return true
	case: return false
	}
}

// Function: can_start_operand
// Returns true if the given token kind can begin an operand expression.
// Valid operand-starting tokens include identifiers, registers, literals, parentheses, and unary operators.
can_start_operand :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Identifier, .Register, .Integer, .Float, .String, .Paren_Open, .Minus, .Tilde: return true
	case:
		// deref, imm
		return false // will handle in parse_operand
	}
}

// Function: is_known_opcode
// Returns true if the given text matches a known instruction opcode mnemonic.
// Used to prevent the operand loop from greedily consuming the next instruction's
// opcode as an operand of the current instruction.
// Covers control flow, ALU, shift, data movement, SSE scalar, SIMD, atomics, and cache instructions.
is_known_opcode :: proc(text: string) -> bool {
	switch text {
	// Control flow
	case "ret", "nop", "syscall", "int3", "ud2", "cpuid", "pause":
		return true
	case "jmp", "jo", "jno", "jb", "jnb", "jc", "jnc", "jz", "jnz", "je", "jne":
		return true
	case "jbe", "ja", "js", "jns", "jp", "jnp", "jl", "jge", "jle", "jg":
		return true
	case "call", "push", "pop":
		return true
	// ALU
	case "add", "sub", "xor", "and", "or", "cmp", "test":
		return true
	// Multiply/divide
	case "mul", "imul", "div", "not", "neg":
		return true
	// Shift/rotate
	case "shl", "shr", "sar", "rol", "ror":
		return true
	// Inc/dec
	case "inc", "dec":
		return true
	// Data movement
	case "mov", "lea":
		return true
	// SSE scalar
	case "movss", "addss", "subss", "mulss", "divss":
		return true
	case "movsd", "addsd", "subsd", "mulsd", "divsd":
		return true
	// Bit manipulation
	case "popcnt", "lzcnt", "tzcnt", "bsr", "bsf", "bswap":
		return true
	// Atomics
	case "xchg", "cmpxchg":
		return true
	// Cache
	case "mfence", "lfence", "sfence", "clflush":
		return true
	case "prefetch_t0", "prefetch_t1", "prefetch_t2", "prefetch_nta":
		return true
	// Safety
	case "canary", "check_canary", "mova":
		return true
	// SIMD
	case "vload", "vloada", "vstore", "vstorea":
		return true
	case "vadd", "vsub", "vmul", "vdiv", "vfma", "vsqrt", "vabs", "vmin", "vmax":
		return true
	case "vaddps", "vsubps", "vmulps", "vdivps", "vminps", "vmaxps", "vsqrtps":
		return true
	case "vandps", "vorps", "vxorps", "vandnps":
		return true
	case "vfmadd132ps", "vfmadd213ps", "vfmadd231ps":
		return true
	case "vbroadcast", "vbroadcastss":
		return true
	case "vshuffle", "vpermute", "vcmp", "vcmpps":
		return true
	case "vmaskedload", "vmaskedstore", "vblend", "vblendv":
		return true
	case "vhsum", "vhmax", "vhmin", "vcvt":
		return true
	case "vshufps", "vpermps", "vextractf128", "vhaddps":
		return true
	case "vcvtss2sd", "vcvtsd2ss", "vcvttps2dq", "vcvtdq2ps":
		return true
	case "vntstorea":
		return true
	}
	return false
}

// Function: parse_operand
// Parses a single instruction operand, which may be a memory reference (deref),
// an immediate value (imm), a qualified name (name::member), a register, or a plain identifier.
// Handles both 2-arg deref(base, offset) and 4-arg deref(base, index, scale, offset) forms.
parse_operand :: proc(p: ^Parser) -> Operand {
	tok := p.curr
	
	if tok.kind == .Identifier {
		if tok.text == "deref" {
			advance_token(p)
			expect_token(p, .Paren_Open)

			// Parse base operand
			base := parse_operand(p)
			expect_token(p, .Comma)

			// Parse second argument — could be offset (2-arg) or index (4-arg)
			second_arg := parse_operand(p)

			// Check if there's a comma after second arg
			if match_token(p, .Comma) {
				// 4-arg form: deref(base, index, scale, offset)
				// second_arg is the index
				index_str: Maybe(string)
				if s, ok := second_arg.(string); ok {
					index_str = s
				}
				scale_ce := parse_const_expr(p)
				scale_cv := eval_const_expr(scale_ce, nil)
				scale := int(as_i64(scale_cv))
				expect_token(p, .Comma)
				offset := parse_const_expr(p)
				expect_token(p, .Paren_Close)

				base_str: Maybe(string)
				if b, ok := base.(string); ok {
					base_str = b
				}

				return Mem_Ref{base = base_str, index = index_str, scale = scale, offset = offset}
			} else {
				// 2-arg form: deref(base, offset)
				// second_arg is an immediate offset (from parse_operand → imm(N))
				expect_token(p, .Paren_Close)

				offset_expr: Const_Expr
				if imm, ok := second_arg.(Immediate); ok {
					offset_expr = imm.expr
				} else if s, ok := second_arg.(string); ok {
					offset_expr = s
				} else {
					offset_expr = i64(0)
				}

				base_str: Maybe(string)
				if b, ok := base.(string); ok {
					base_str = b
				}

				return Mem_Ref{base = base_str, offset = offset_expr}
			}
		} else if tok.text == "imm" {
			advance_token(p)
			expect_token(p, .Paren_Open)
			expr := parse_const_expr(p)
			expect_token(p, .Paren_Close)
			return Immediate{expr}
		}
	}
	
	// Default: identifier (alias, label, qual) or register
	advance_token(p)
	// Check for qualified name
	if p.curr.kind == .Double_Colon {
		advance_token(p)
		sub_name := expect_token(p, .Identifier).text
		return fmt.tprintf("%s::%s", tok.text, sub_name)
	}
	
	return tok.text
}
