# Compile-Time Evaluation

*Source: src/compiler/const_eval.odin*

Evaluates constant expressions at compile time.

---

## Functions

### `init_const_eval` {#init_const_eval}

Function: init_const_eval Initializes the global_constants map for compile-time constant evaluation.

---

### `eval_const_expr` {#eval_const_expr}

Function: eval_const_expr Recursively evaluates a compile-time constant expression. Handles literals, identifier lookups, binary/unary operations, sizeof, alignof, and offset intrinsics.

---

### `eval_sizeof` {#eval_sizeof}

Function: eval_sizeof Evaluates SIZEOF(Type) — returns the byte size of a struct (AoS: with padding, SoA: per-element) or primitive type. Reports Fatal_Undef for unknown types.

---

### `eval_alignof` {#eval_alignof}

Function: eval_alignof Evaluates ALIGNOF(Type) — returns the alignment requirement in bytes for a struct or primitive type. Primitive types are self-aligned to their size.

---

### `eval_sizeof_soa` {#eval_sizeof_soa}

Function: eval_sizeof_soa Evaluates SIZEOF_SOA(Type, capacity) — total SoA block size computed as sum(field_sizes) * capacity, aligned to the struct's alignment boundary.

---

### `eval_aos_offset` {#eval_aos_offset}

Function: eval_aos_offset Evaluates @offset(Type, field) — returns the byte offset of a named field within an AoS struct layout. Reports Fatal_Undef if struct or field not found.

---

### `eval_soa_offset` {#eval_soa_offset}

Function: eval_soa_offset Evaluates @soa_offset(Type, field, capacity) — byte offset of a field's array in a SoA block, computed as sum_of_sizes_of_preceding_fields * capacity.

---

### `eval_binop` {#eval_binop}

Function: eval_binop Evaluates a binary operation on two Constant_Value operands. Supports arithmetic (+, -, *, /, %), bitwise (<<, >>, &, |, ~), and comparison operators.

---

### `eval_unop` {#eval_unop}

Function: eval_unop Evaluates a unary operation on a Constant_Value. Supports negation (-) and bitwise complement (~). Returns 0 for unrecognized operators.

---

### `as_i64` {#as_i64}

Function: as_i64 Extracts an i64 value from a Constant_Value union. Converts f64 to i64 via truncation. Returns 0 for unrecognized variants.

---

## Types

### `Constant_Value` {#constant_value}

Type: Constant_Value Union type holding a compile-time constant value. Supports both integer (i64) and floating-point (f64) constant representations.

---

## Variables

### `global_constants` {#global_constants}

Variable: global_constants Global registry mapping constant names to their evaluated Constant_Value. Populated during declaration evaluation and queried during expression eval.

---
