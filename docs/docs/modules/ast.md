# Abstract Syntax Tree Types

*Source: src/compiler/ast.odin*

All AST node types, enums, unions, and structs.

---

## Types

### `Src_Loc` {#src_loc}

Type: Src_Loc Structure representing a source code location for error reporting and debugging.

| Parameter | Description |
|-----------|-------------|
| `file` | source file path |
| `line` | line number (1-indexed) |
| `col` | column number (1-indexed) |

---

### `Token_Kind` {#token_kind}

Type: Token_Kind Enumeration of all token types in the Osteon language. Includes keywords, symbols, and special tokens for parsing.

---

### `Token` {#token}

Type: Token Represents a single lexical token with kind, text, and source location.

| Parameter | Description |
|-----------|-------------|
| `kind` | Token_Kind enumeration value |
| `text` | raw text of the token |
| `src_loc` | source location for error reporting |

---

### `Width` {#width}

Type: Width Enumeration of data width specifiers for instructions and types. Used to determine operand size and encoding.

| Parameter | Description |
|-----------|-------------|
| `U8` | 8-bit unsigned integer |
| `U16` | 16-bit unsigned integer |
| `U32` | 32-bit unsigned integer |
| `U64` | 64-bit unsigned integer |
| `F32` | 32-bit floating point |
| `F64` | 64-bit floating point |

---

### `Opcode` {#opcode}

Type: Opcode Represents an instruction opcode as a string (e.g., "mov", "add", "jmp").

---

### `Const_Expr` {#const_expr}

Type: Const_Expr Union type for compile-time constant expressions. Can be a literal integer, float, string identifier, or a compound expression node.   i64            - integer literal   f64            - float literal   string         - identifier or qualified name reference   ^Sizeof_Expr   - SIZEOF(type) expression   ^Alignof_Expr  - ALIGNOF(type) expression   ^Sizeof_Soa_Expr - SIZEOF_SOA(type, cap) expression   ^Offset_Expr   - @offset(type, field) expression   ^Soa_Offset_Expr - @soa_offset(type, field, cap) expression   ^Binop_Expr    - binary operation expression   ^Unop_Expr     - unary operation expression

---

### `Sizeof_Expr` {#sizeof_expr}

Type: Sizeof_Expr Compile-time SIZEOF expression that returns the byte size of a type.

| Parameter | Description |
|-----------|-------------|
| `type_name` | name of the type to query |

---

### `Alignof_Expr` {#alignof_expr}

Type: Alignof_Expr Compile-time ALIGNOF expression that returns the alignment of a type.

| Parameter | Description |
|-----------|-------------|
| `type_name` | name of the type to query |

---

### `Sizeof_Soa_Expr` {#sizeof_soa_expr}

Type: Sizeof_Soa_Expr Compile-time SIZEOF_SOA expression for computing SoA block sizes.

| Parameter | Description |
|-----------|-------------|
| `type_name` | name of the struct type |
| `capacity` | capacity expression |

---

### `Offset_Expr` {#offset_expr}

Type: Offset_Expr Compile-time @offset expression for AoS field byte offsets.

| Parameter | Description |
|-----------|-------------|
| `type_name` | name of the struct type |
| `field_name` | name of the field |

---

### `Soa_Offset_Expr` {#soa_offset_expr}

Type: Soa_Offset_Expr Compile-time @soa_offset expression for SoA field array byte offsets.

| Parameter | Description |
|-----------|-------------|
| `type_name` | name of the struct type |
| `field_name` | name of the field |
| `capacity` | capacity expression |

---

### `Binop_Expr` {#binop_expr}

Type: Binop_Expr Binary operation expression node (e.g., lhs + rhs).

| Parameter | Description |
|-----------|-------------|
| `op` | operator token kind |
| `lhs` | left-hand side expression |
| `rhs` | right-hand side expression |

---

### `Unop_Expr` {#unop_expr}

Type: Unop_Expr Unary operation expression node (e.g., -x, ~x).

| Parameter | Description |
|-----------|-------------|
| `op` | operator token kind |
| `operand` | the operand expression |

---

### `Operand` {#operand}

Type: Operand Union type for instruction operands: registers, immediates, or memory references.   string     - register name, alias name, or label/qualified reference   Immediate  - immediate value with compile-time expression   Mem_Ref    - memory reference with base, index, scale, offset

---

### `Immediate` {#immediate}

Type: Immediate Represents an immediate (literal) operand in an instruction.

| Parameter | Description |
|-----------|-------------|
| `expr` | constant expression value (i64, f64, string, or compound) |

---

### `Mem_Ref` {#mem_ref}

Type: Mem_Ref Represents a memory reference operand in an instruction. Supports base + index * scale + offset addressing.

| Parameter | Description |
|-----------|-------------|
| `base` | optional base register name |
| `index` | optional index register name |
| `scale` | index scaling factor (1, 2, 4, or 8) |
| `offset` | constant offset expression |

---

### `Stmt` {#stmt}

Type: Stmt Union type for all statement kinds in the Osteon AST. Covers instructions, declarations, control flow, and directives.

---

### `Instr` {#instr}

Type: Instr Represents a single machine instruction in the AST.

| Parameter | Description |
|-----------|-------------|
| `op` | opcode string (e.g., "mov", "add", "jmp") |
| `width` | optional width annotation (e.g., u64) |
| `prefix` | instruction prefix byte (0=none, 0xF0=lock, 0x3E=likely, 0x2E=unlikely) |
| `operands` | dynamic array of Operand values |
| `src_loc` | source location for error reporting |

---

### `Fn_Decl` {#fn_decl}

Type: Fn_Decl Represents a function declaration in the AST.

| Parameter | Description |
|-----------|-------------|
| `is_static` | whether function has static linkage |
| `name` | function name |
| `body` | array of statements in function body |
| `src_loc` | source location |

---

### `Inline_Fn_Decl` {#inline_fn_decl}

Type: Inline_Fn_Decl Represents an inline function declaration that gets expanded at call sites.

| Parameter | Description |
|-----------|-------------|
| `name` | inline function name |
| `body` | array of statements in function body |
| `src_loc` | source location |

---

### `Struct_Decl` {#struct_decl}

Type: Struct_Decl Represents a struct type declaration with optional layout annotation.

| Parameter | Description |
|-----------|-------------|
| `name` | struct name |
| `layout` | Layout_Kind (AoS or SoA) |
| `fields` | array of Struct_Field definitions |
| `src_loc` | source location |

---

### `Layout_Kind` {#layout_kind}

Type: Layout_Kind Enumeration of struct memory layout strategies.

| Parameter | Description |
|-----------|-------------|
| `AoS` | Array of Structures (default, sequential layout) |
| `SoA` | Structure of Arrays (optimized for SIMD vectorization) |

---

### `Struct_Field` {#struct_field}

Type: Struct_Field Represents a single field definition in a struct declaration.

| Parameter | Description |
|-----------|-------------|
| `name` | field name |
| `type` | field data width |

---

### `Data_Decl` {#data_decl}

Type: Data_Decl Represents a data (global variable) declaration.

| Parameter | Description |
|-----------|-------------|
| `is_static` | whether data has static linkage |
| `name` | data name |
| `type` | data width type |
| `struct_name` | name of struct type if applicable |
| `is_array` | whether this is an array declaration |
| `value` | initial value expression |
| `src_loc` | source location |

---

### `Data_Value` {#data_value}

Type: Data_Value Union type for data initialization values. Can be an integer, float, string, array of values, or struct field map.

---

### `Const_Decl` {#const_decl}

Type: Const_Decl Represents a compile-time constant declaration.

| Parameter | Description |
|-----------|-------------|
| `name` | constant name |
| `expr` | constant expression value |
| `src_loc` | source location |

---

### `Import_Decl` {#import_decl}

Type: Import_Decl Represents a file import declaration with optional alias.

| Parameter | Description |
|-----------|-------------|
| `path` | import file path |
| `alias` | optional namespace alias |
| `src_loc` | source location |

---

### `Namespace_Decl` {#namespace_decl}

Type: Namespace_Decl Represents a namespace declaration that overrides the default package name (derived from filename).

| Parameter | Description |
|-----------|-------------|
| `name` | namespace name |
| `src_loc` | source location |

---

### `Extern_Decl` {#extern_decl}

Type: Extern_Decl Represents an external symbol declaration.

| Parameter | Description |
|-----------|-------------|
| `name` | external symbol name |
| `src_loc` | source location |

---

### `Let_Decl` {#let_decl}

Type: Let_Decl Represents a local register alias declaration within a function. Maps a name to a register with optional aliasing and provenance info.

| Parameter | Description |
|-----------|-------------|
| `name` | alias name |
| `reg` | underlying register name |
| `noalias` | pointer aliasing guarantee (non-overlapping) |
| `provenance` | provenance kind: "extern", "arena(name)", "stack", "static", "raw", or "" |
| `src_loc` | source location |

---

### `Label_Decl` {#label_decl}

Type: Label_Decl Represents a label declaration for jump targets.

| Parameter | Description |
|-----------|-------------|
| `name` | label name |
| `src_loc` | source location |

---

### `Arena_Decl` {#arena_decl}

Type: Arena_Decl Represents an arena (bump allocator) declaration. The buffer register becomes the bump pointer base.

| Parameter | Description |
|-----------|-------------|
| `name` | arena name |
| `buf` | buffer operand (register or memory reference) |
| `size` | arena size expression |
| `src_loc` | source location |

---

### `Alloc_Stmt` {#alloc_stmt}

Type: Alloc_Stmt Represents an allocation from an arena with alignment.

| Parameter | Description |
|-----------|-------------|
| `arena_name` | name of the arena to allocate from |
| `size` | allocation size expression |
| `align` | alignment expression |
| `src_loc` | source location |

---

### `Reset_Stmt` {#reset_stmt}

Type: Reset_Stmt Represents an arena reset operation that restores the bump pointer.

| Parameter | Description |
|-----------|-------------|
| `arena_name` | name of the arena to reset |
| `src_loc` | source location |

---

### `For_Loop` {#for_loop}

Type: For_Loop Represents a for-loop construct with counter, start, end, step, and body. Supports optional loop labels and loop unrolling.

| Parameter | Description |
|-----------|-------------|
| `label` | optional loop label for break/continue targets |
| `unroll_factor` | loop unrolling factor (0 or 1 = no unrolling, N > 1 = unroll N times) |
| `counter` | counter register operand |
| `start` | start value operand |
| `end` | end value operand |
| `step` | step value operand |
| `body` | loop body statements |
| `src_loc` | source location |

---

### `While_Loop` {#while_loop}

Type: While_Loop Represents a while-loop with a condition instruction and body.

| Parameter | Description |
|-----------|-------------|
| `cond` | condition instruction (e.g., cmp) |
| `jump_cc` | jump condition code for loop exit |
| `body` | loop body statements |
| `src_loc` | source location |

---

### `Assert_Stmt` {#assert_stmt}

Type: Assert_Stmt Represents an assertion statement, either compile-time (static_assert) or runtime assert.

| Parameter | Description |
|-----------|-------------|
| `is_static` | whether this is a compile-time assertion |
| `cond` | condition (Instr for runtime, Const_Expr for static) |
| `jump_cc` | jump condition code for runtime assertion success |
| `message` | assertion failure message |
| `src_loc` | source location |

---

### `Expect_Stmt` {#expect_stmt}

Type: Expect_Stmt Represents an expect statement that traps on error via rdx register check. Desugars to: test rdx, rdx; jz ok; ud2; label ok

| Parameter | Description |
|-----------|-------------|
| `message` | error message for the expect |
| `src_loc` | source location |

---

### `Breakpoint_Stmt` {#breakpoint_stmt}

Type: Breakpoint_Stmt Represents a breakpoint instruction (int3) inserted by the programmer. Stripped in release builds.

| Parameter | Description |
|-----------|-------------|
| `src_loc` | source location |

---

### `Unreachable_Stmt` {#unreachable_stmt}

Type: Unreachable_Stmt Represents an unreachable code marker that causes a trap if executed.

| Parameter | Description |
|-----------|-------------|
| `src_loc` | source location |

---

### `Result_Decl` {#result_decl}

Type: Result_Decl Represents a result type contract annotation. Emits no code; used to declare the expected return type of a function.

| Parameter | Description |
|-----------|-------------|
| `type` | the result width type |
| `src_loc` | source location |

---

### `Program` {#program}

Type: Program Represents a complete Osteon program with top-level statements.

| Parameter | Description |
|-----------|-------------|
| `stmts` | dynamic array of top-level statements (functions, structs, data, etc.) |

---
