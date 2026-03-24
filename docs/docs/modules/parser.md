# Syntax Analysis

*Source: src/compiler/parser.odin*

Parses token streams into an Abstract Syntax Tree.

---

## Functions

### `parse_integer` {#parse_integer}

Function: parse_integer Parses a numeric string literal into a signed 64-bit integer. Supports decimal, hexadecimal (0x/0X), binary (0b/0B), and octal (0o/0O) prefixes. Returns the parsed value, or 0 on failure.

---

### `init_parser` {#init_parser}

Function: init_parser Creates a new Parser from the given Lexer and advances to the first token. Returns the initialized Parser ready for parsing.

---

### `advance_token` {#advance_token}

Function: advance_token Moves the parser forward by one token, storing the previous token for backtracking.

---

### `expect_token` {#expect_token}

Function: expect_token Asserts the current token matches the expected kind and advances on success. Reports a fatal syntax error and returns a zero-value token on mismatch.

---

### `match_token` {#match_token}

Function: match_token Conditionally consumes the current token if it matches the expected kind. Returns true if a match occurred and the token was advanced past.

---

### `parse_program` {#parse_program}

Function: parse_program Entry point for parsing an entire source file into a Program AST node. Repeatedly parses top-level statements until EOF is reached.

---

### `parse_top_level` {#parse_top_level}

Function: parse_top_level Dispatches parsing of a single top-level declaration based on the current token kind. Handles namespace, import, const, struct, data, extern, fn, static_assert, result, section, and global declarations.

---

### `parse_namespace_decl` {#parse_namespace_decl}

Function: parse_namespace_decl Parses a namespace declaration consisting of the 'namespace' keyword followed by an identifier name.

---

### `parse_import_decl` {#parse_import_decl}

Function: parse_import_decl Parses an import declaration with a string path and optional 'as' alias.

---

### `parse_const_decl` {#parse_const_decl}

Function: parse_const_decl Parses a compile-time constant declaration with a name, '=' sign, and constant expression.

---

### `parse_struct_decl` {#parse_struct_decl}

Function: parse_struct_decl Parses a struct declaration with an optional layout(soa) modifier. Structs contain typed fields separated by commas within braces.

---

### `parse_data_decl` {#parse_data_decl}

Function: parse_data_decl Parses a data declaration with optional static storage, type annotation, and initializer. Supports primitive types, struct names, and array types.

---

### `parse_extern_decl` {#parse_extern_decl}

Function: parse_extern_decl Parses an extern declaration that references an external symbol by name.

---

### `parse_fn_decl` {#parse_fn_decl}

Function: parse_fn_decl Parses a function declaration with optional inline or static modifiers. Functions contain a body of statements enclosed in braces. Returns an Inline_Fn_Decl or Fn_Decl depending on the modifier.

---

### `parse_static_assert` {#parse_static_assert}

Function: parse_static_assert Parses a static assertion that evaluates a constant expression at compile time. Optionally accepts a string message displayed on failure.

---

### `parse_result_decl` {#parse_result_decl}

Function: parse_result_decl Parses a result(type) contract annotation that specifies the return type of a function. Emits no executable code; serves as a type-level contract.

---

### `parse_global_decl` {#parse_global_decl}

Function: parse_global_decl Parses a global declaration, which is equivalent to a static function or static data declaration. Dispatches to fn or data parsing paths based on the token following 'global'.

---

### `parse_type` {#parse_type}

Function: parse_type Parses a type token and returns the corresponding Width enum value. Supports u8, u16, u32, u64, f32, and f64 type keywords.

---

### `parse_const_expr` {#parse_const_expr}

Function: parse_const_expr Parses a compile-time constant expression, handling literals, identifiers, and binary operators. Uses left-to-right precedence with recursive descent for binary operator chaining.

---

### `parse_const_atom` {#parse_const_atom}

Function: parse_const_atom Parses a single atomic constant expression such as an integer, float, identifier, parenthesized sub-expression, or unary operator (minus/tilde). Handles built-in intrinsics like SIZEOF, ALIGNOF, SIZEOF_SOA, @offset, and @soa_offset.

---

### `is_binop` {#is_binop}

Function: is_binop Returns true if the given token kind is a binary operator. Covers arithmetic (+, -, *, /, %), shift (<<, >>), bitwise (&, |, ^), and comparison (==, !=, <, <=, >, >=) operators.

---

### `parse_data_value` {#parse_data_value}

Function: parse_data_value Parses a data initializer value, which may be an integer, float, string literal, array literal (bracket-enclosed list), or struct initializer (brace-enclosed key-value pairs).

---

### `parse_fn_stmt` {#parse_fn_stmt}

Function: parse_fn_stmt Parses a single statement within a function body. Handles instruction prefixes (lock, likely, unlikely), let bindings, labels, arena allocations, for/while loops, assertions, and plain instructions.

---

### `parse_instruction` {#parse_instruction}

Function: parse_instruction Parses a single machine instruction with its opcode, optional width annotation, and operands. Handles special opcodes like prefetch(hint) that modify the opcode string based on a parenthesized argument.

---

### `is_keyword_starting_stmt` {#is_keyword_starting_stmt}

Function: is_keyword_starting_stmt Returns true if the given token kind introduces a new statement (e.g., let, label, for, while, assert). Used to terminate operand parsing when a new statement keyword appears.

---

### `can_start_operand` {#can_start_operand}

Function: can_start_operand Returns true if the given token kind can begin an operand expression. Valid operand-starting tokens include identifiers, registers, literals, parentheses, and unary operators.

---

### `is_known_opcode` {#is_known_opcode}

Function: is_known_opcode Returns true if the given text matches a known instruction opcode mnemonic. Used to prevent the operand loop from greedily consuming the next instruction's opcode as an operand of the current instruction. Covers control flow, ALU, shift, data movement, SSE scalar, SIMD, atomics, and cache instructions.

---

### `parse_operand` {#parse_operand}

Function: parse_operand Parses a single instruction operand, which may be a memory reference (deref), an immediate value (imm), a qualified name (name::member), a register, or a plain identifier. Handles both 2-arg deref(base, offset) and 4-arg deref(base, index, scale, offset) forms.

---

## Types

### `Parser` {#parser}

Type: Parser Incremental token-stream parser that consumes a Lexer and produces an AST. Tracks the current and previous tokens for lookahead and context during parsing.

---
