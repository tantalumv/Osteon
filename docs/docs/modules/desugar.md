# Desugaring Pass

*Source: src/compiler/desugar.odin*

Transforms structured control flow into raw instructions.

---

## Functions

### `init_desugar` {#init_desugar}

Function: init_desugar Resets the global desugar label counter to zero. Must be called before desugaring a new compilation unit.

---

### `next_desugar_label` {#next_desugar_label}

Function: next_desugar_label Generates and returns a unique label string prefixed with prefix and an incrementing counter (e.g., "__for_1").

---

### `desugar_stmts` {#desugar_stmts}

Function: desugar_stmts Transforms structured control flow (for, while, expect, assert, arena/alloc/reset, canary, mova) into raw machine-level instructions. Returns a new dynamic array of desugared statements.

---

### `desugar_for_loop` {#desugar_for_loop}

Function: desugar_for_loop Desugars a counted for loop into a compare-and-jump sequence: init counter, label loop, cmp against end, jge done, body, add step, jmp loop, label done.

---

### `desugar_while_loop` {#desugar_while_loop}

Function: desugar_while_loop Desugars a while loop: emits a loop label, the condition instruction, an inverse jump to exit on failure, the body, the condition again, a jump back to loop on success, and a done label.

---

### `desugar_expect` {#desugar_expect}

Function: desugar_expect Desugars an expect statement into: test rdx, rdx; jz ok_label; ud2; label ok. Triggers ud2 if rdx is non-zero (error path).

---

### `desugar_assert` {#desugar_assert}

Function: desugar_assert Desugars a runtime assert into: cmp instruction, conditional jump to ok_label on success, ud2 trap on failure, and ok label.

---

### `inverse_condition` {#inverse_condition}

Function: inverse_condition Returns the logical inverse of a jump condition code (e.g., "jz" returns "jnz", "jge" returns "jl"). Falls back to "jnz" for unknown codes.

---

### `desugar_arena_decl` {#desugar_arena_decl}

Function: desugar_arena_decl Desugars an arena declaration by emitting a mov that initializes the scratch register from the buffer base register.

---

### `desugar_alloc` {#desugar_alloc}

Function: desugar_alloc Desugars an arena allocation: aligns the scratch bump pointer, copies it to rax as the result, advances by size, and optionally checks for buffer overflow (triggering ud2 on out-of-bounds).

---

### `desugar_reset` {#desugar_reset}

Function: desugar_reset Desugars an arena reset by re-initializing the scratch register from the original buffer base register, effectively rewinding the bump pointer.

---

### `desugar_for_unroll` {#desugar_for_unroll}

Function: desugar_for_unroll Desugars a for loop with loop unrolling: emits N copies of the body per iteration (with interleaved step increments), followed by a scalar tail that handles any remaining iterations one at a time.

---

### `desugar_canary` {#desugar_canary}

Function: desugar_canary Desugars a canary instruction into a u64 mov that writes CANARY_VALUE to the stack slot at rbp - 8.

---

### `desugar_check_canary` {#desugar_check_canary}

Function: desugar_check_canary Desugars a check_canary instruction: compares the stack slot at rbp - 8 against CANARY_VALUE, jumps to ok_label on match, otherwise traps with ud2.

---

### `desugar_mova` {#desugar_mova}

Function: desugar_mova Desugars a bounds-checked memory access: compares the index register against count, traps with ud2 if out of bounds, then performs the underlying mov.

---

## Types

### `Arena_Info` {#arena_info}

Type: Arena_Info Tracks the original buffer register, scratch register used as the bump pointer, and compile-time buffer size for an arena allocation region.

---

## Constants

### `CANARY_VALUE` {#canary_value}

Constant: CANARY_VALUE Magic value (0x3F2C1D4B5E60789) written to the stack canary slot below rbp.

---
