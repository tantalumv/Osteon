# Struct Layout Resolution

*Source: src/compiler/layout.odin*

Computes struct field offsets and AoS/SoA layouts.

---

## Functions

### `init_layout_resolution` {#init_layout_resolution}

Function: init_layout_resolution Initializes the global_structs map for struct layout resolution.

---

### `resolve_struct_layout` {#resolve_struct_layout}

Function: resolve_struct_layout Resolves the byte layout of a struct declaration. For AoS layout, computes sequential field offsets with explicit padding enforcement. For SoA layout, computes cumulative per-element sizes for interleaved array storage. Registers the result in global_structs.

---

## Types

### `Struct_Info` {#struct_info}

Type: Struct_Info Stores resolved layout information for a struct declaration. Tracks name, byte size (AoS: with padding, SoA: per-element), alignment, layout kind, field metadata, and SoA block size.

---

### `Struct_Field_Info` {#struct_field_info}

Type: Struct_Field_Info Stores resolved layout information for a single struct field. Tracks the field name, its Width type, and byte offset (AoS) or cumulative size index (SoA).

---

## Constants

### `width_to_size` {#width_to_size}

Constant: width_to_size Maps Width enum values to their byte sizes for use during struct layout resolution and field offset computation.

---

## Variables

### `global_structs` {#global_structs}

Variable: global_structs Global registry mapping struct names to their resolved Struct_Info. Populated by resolve_struct_layout and queried during constant evaluation.

---
