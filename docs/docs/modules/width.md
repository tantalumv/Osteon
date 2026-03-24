# Width Consistency Checking

*Source: src/compiler/width.odin*

Validates instruction width consistency.

---

## Functions

### `init` {#init}

Function: init Initializes the register_widths map with all known x86-64 register names and their corresponding bit widths.

---

### `width_to_string` {#width_to_string}

Function: width_to_string Returns the human-readable bit width string for a Width enum value (e.g. "8", "16", "32", "64"). Returns "?" for unrecognized widths.

---

### `format_operand` {#format_operand}

Function: format_operand Renders a single operand as a human-readable string for error correction messages. Handles register names, immediates, and memory references.

---

### `format_operands` {#format_operands}

Function: format_operands Renders a list of operands as a comma-separated string using format_operand.

---

### `format_instruction` {#format_instruction}

Function: format_instruction Renders a full instruction including opcode, width annotation, and operands as a human-readable string for error correction messages.

---

### `checkWidthConsistency` {#checkwidthconsistency}

Function: checkWidthConsistency Entry point for width consistency checking. Iterates over all packages and verifies that instruction width annotations match register operand widths.

---

### `check_stmt_list_width` {#check_stmt_list_width}

Function: check_stmt_list_width Recursively checks all instructions in a statement list, including those nested inside for/while loops. Tracks let-declaration aliases to registers.

---

### `check_instruction_width` {#check_instruction_width}

Function: check_instruction_width Validates a single instruction's width annotation against its register operands. Reports Fatal_Width on mismatch or missing width annotation.

---

### `is_gpr_reg` {#is_gpr_reg}

Function: is_gpr_reg Checks if a string is a known register name by looking it up in the register_widths map. Returns true for valid GPR and XMM registers.

---

## Variables

### `register_widths` {#register_widths}

Variable: register_widths Maps register name strings to their Width values. Covers all x86-64 GPRs (64/32/16/8-bit) and XMM SIMD registers used for width checking.

---
