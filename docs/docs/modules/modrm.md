# ModR/M and REX Encoding

*Source: src/compiler/modrm.odin*

Encodes ModR/M, SIB, and REX prefix bytes.

---

## Functions

### `encode_modrm` {#encode_modrm}

Function: encode_modrm Encodes a ModR/M byte from addressing mode, register, and r/m fields. Returns [mod:2][reg:3][rm:3] packed into a single byte.

---

### `encode_sib` {#encode_sib}

Function: encode_sib Encodes a SIB (Scale-Index-Base) byte. Converts the scale factor (1/2/4/8) to its 2-bit encoding and packs with index and base register fields.

---

### `encode_rex` {#encode_rex}

Function: encode_rex Encodes a REX prefix byte [0100WRXB]. W enables 64-bit operand size, R/X/B extend the ModR/M reg, SIB index, or ModR/M r/m field respectively.

---

### `is_ext_reg` {#is_ext_reg}

Function: is_ext_reg Returns true if the register ID requires a REX extension bit (id >= 8), meaning it refers to registers r8-r15 or their width variants.

---

## Types

### `Mod` {#mod}

Type: Mod ModR/M addressing mode field. Encodes the addressing mode for the ModR/M byte: indirect, with 8/32-bit displacement, or direct register.

---

## Constants

### `reg_to_id` {#reg_to_id}

Constant: reg_to_id Maps register name strings to their x86-64 hardware register ID (0-15). Covers GPRs at all widths, legacy high-byte registers, and XMM registers.

---
