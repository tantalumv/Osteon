#+feature dynamic-literals
package compiler

import "core:os"
import "core:fmt"

COFF_Header :: struct {
	machine:              u16,
	number_of_sections:   u16,
	time_date_stamp:      u32,
	pointer_to_symbol_table: u32,
	number_of_symbols:    u32,
	size_of_optional_header: u16,
	characteristics:       u16,
}

COFF_Section_Header :: struct {
	name:                 [8]u8,
	virtual_size:         u32,
	virtual_address:      u32,
	size_of_raw_data:     u32,
	pointer_to_raw_data:  u32,
	pointer_to_relocations: u32,
	pointer_to_line_numbers: u32,
	number_of_relocations: u16,
	number_of_line_numbers: u16,
	characteristics:       u32,
}

COFF_Symbol :: struct {
	name:                 [8]u8,
	value:                u32,
	section_number:       i16,
	type:                 u16,
	storage_class:        u8,
	number_of_aux_symbols: u8,
}

IMAGE_FILE_MACHINE_AMD64 :: 0x8664
IMAGE_FILE_CHARACTERISTICS_EXECUTABLE_IMAGE :: 0x0002
IMAGE_SCN_CNT_CODE :: 0x00000020
IMAGE_SCN_CNT_INITIALIZED_DATA :: 0x00000040
IMAGE_SCN_MEM_EXECUTE :: 0x20000000
IMAGE_SCN_MEM_READ :: 0x40000000
IMAGE_SCN_MEM_WRITE :: 0x80000000

// Relocation types for AMD64
IMAGE_REL_AMD64_REL32 :: 0x0004

COFF_Relocation :: struct {
	virtual_address:    u32,
	symbol_table_index: u32,
	type_:              u16,
}

// ============================================
// String table for long symbol names (>8 bytes)
// ============================================

String_Table :: struct {
	bytes:      [dynamic]u8,
	next_offset: u32, // next available offset (1-based)
}

init_string_table :: proc(st: ^String_Table) {
	st.bytes = make([dynamic]u8)
	// Reserve 4 bytes for the total size field
	append(&st.bytes, 0)
	append(&st.bytes, 0)
	append(&st.bytes, 0)
	append(&st.bytes, 0)
	st.next_offset = 4 // first string starts at offset 4 (1-based = 4)
}

// Add a string to the string table. Returns the 1-based offset.
string_table_add :: proc(st: ^String_Table, s: string) -> u32 {
	offset := st.next_offset
	for _, b in s {
		append(&st.bytes, u8(b))
	}
	append(&st.bytes, 0) // null terminator
	st.next_offset += u32(len(s)) + 1
	return offset
}

// Finalize: write the total size into the first 4 bytes
string_table_finalize :: proc(st: ^String_Table) {
	size := u32(len(st.bytes))
	st.bytes[0] = u8(size & 0xFF)
	st.bytes[1] = u8((size >> 8) & 0xFF)
	st.bytes[2] = u8((size >> 16) & 0xFF)
	st.bytes[3] = u8((size >> 24) & 0xFF)
}

// Set symbol name: short (≤8 bytes) goes in the field, long goes in string table
set_symbol_name :: proc(sym: ^COFF_Symbol, name: string, st: ^String_Table) {
	if len(name) <= 8 {
		// Short name: copy directly into the 8-byte field
		copy(sym.name[:], name)
	} else {
		// Long name: first 4 bytes = 0 (string table indicator), next 4 = offset
		sym.name[0] = 0
		sym.name[1] = 0
		sym.name[2] = 0
		sym.name[3] = 0
		offset := string_table_add(st, name)
		sym.name[4] = u8(offset & 0xFF)
		sym.name[5] = u8((offset >> 8) & 0xFF)
		sym.name[6] = u8((offset >> 16) & 0xFF)
		sym.name[7] = u8((offset >> 24) & 0xFF)
	}
}

// ============================================
// Main COFF emitter
// ============================================

emit_coff_obj :: proc(file_path: string, packages: [dynamic]^Package) {
	str_tab: String_Table
	init_string_table(&str_tab)

	// ============================================
	// 1. Encode .text (functions)
	// ============================================
	ctx: Encoder_Context
	init_encoder(&ctx)

	symbols := make([dynamic]COFF_Symbol)

	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch s in stmt {
			case ^Fn_Decl:
				ctx.current_fn = fmt.tprintf("%s__%s", pkg.name, s.name)

				sym: COFF_Symbol
				set_symbol_name(&sym, ctx.current_fn, &str_tab)
				sym.value = u32(len(ctx.buf))
				sym.section_number = 1
				sym.storage_class = 2
				append(&symbols, sym)

				for body_stmt in s.body {
					#partial switch bs in body_stmt {
					case ^Instr:
						encode_instr(&ctx, bs)
					case ^Label_Decl:
						define_label(&ctx, bs.name)
					case:
						// Other stmt types (Let_Decl etc.) handled by alias resolution
					}
				}
			}
		}
	}

	text_buffer := ctx.buf

	// Resolve patches
	unresolved_patches := make([dynamic]Patch_Entry)
	resolve_patches(&ctx, &unresolved_patches)

	// Convert unresolved patches to relocations + external symbols
	relocations := make([dynamic]COFF_Relocation)
	ext_sym_indices := make(map[string]u32)

	for patch in unresolved_patches {
		sym_idx: u32
		if idx, exists := ext_sym_indices[patch.label_name]; exists {
			sym_idx = idx
		} else {
			sym_idx = u32(len(symbols))
			ext_sym_indices[patch.label_name] = sym_idx

			ext_sym: COFF_Symbol
			set_symbol_name(&ext_sym, patch.label_name, &str_tab)
			ext_sym.value = 0
			ext_sym.section_number = 0
			ext_sym.storage_class = 2
			append(&symbols, ext_sym)
		}

		rel: COFF_Relocation
		rel.virtual_address = u32(patch.buf_offset)
		rel.symbol_table_index = sym_idx
		rel.type_ = IMAGE_REL_AMD64_REL32
		append(&relocations, rel)
	}

	// ============================================
	// 2. Encode .data (data declarations)
	// ============================================
	data_buffer := make([dynamic]u8)

	for pkg in packages {
		for stmt in pkg.program.stmts {
			#partial switch s in stmt {
			case ^Data_Decl:
				mangled := fmt.tprintf("%s__%s", pkg.name, s.name)
				sym: COFF_Symbol
				set_symbol_name(&sym, mangled, &str_tab)
				sym.value = u32(len(data_buffer))
				sym.section_number = 2
				sym.storage_class = s.is_static ? 3 : 2
				append(&symbols, sym)

			if s.is_array {
				if vals, ok := s.value.([]Data_Value); ok {
					for v in vals {
						serialize_data_value(&data_buffer, v, s.type)
					}
				}
			} else if s.struct_name != "" {
				// Struct data — look up field order from global_structs
				if info, exists := global_structs[s.struct_name]; exists {
					if inits, ok := s.value.(map[string]Data_Value); ok {
						for fi in info.fields {
							if v, v_exists := inits[fi.name]; v_exists {
								serialize_data_value(&data_buffer, v, fi.type)
							} else {
								// Field not in init — emit zero
								write_integer(&data_buffer, 0, fi.type)
							}
						}
					}
				} else {
					fmt.printf("Warning: struct %s not found for data %s\n", s.struct_name, s.name)
					serialize_data_value(&data_buffer, s.value, s.type)
				}
			} else {
					serialize_data_value(&data_buffer, s.value, s.type)
				}
			}
		}
	}

	// Finalize string table
	string_table_finalize(&str_tab)

	// ============================================
	// 3. Compute file layout
	// ============================================
	header_size := size_of(COFF_Header)
	section_header_size := size_of(COFF_Section_Header)
	symbol_table_size := len(symbols) * size_of(COFF_Symbol)
	str_tab_size := len(str_tab.bytes)

	section_headers_offset := header_size
	text_raw_offset := section_headers_offset + section_header_size * 2
	data_raw_offset := text_raw_offset + len(text_buffer)
	symbol_table_offset := data_raw_offset + len(data_buffer)
	text_reloc_offset := symbol_table_offset + symbol_table_size + str_tab_size

	header := COFF_Header {
		machine = IMAGE_FILE_MACHINE_AMD64,
		number_of_sections = 2,
		pointer_to_symbol_table = u32(symbol_table_offset),
		number_of_symbols = u32(len(symbols)),
		characteristics = IMAGE_FILE_CHARACTERISTICS_EXECUTABLE_IMAGE,
	}

	text_section := COFF_Section_Header {
		name = { '.', 't', 'e', 'x', 't', 0, 0, 0 },
		size_of_raw_data = u32(len(text_buffer)),
		pointer_to_raw_data = u32(text_raw_offset),
		pointer_to_relocations = u32(text_reloc_offset),
		number_of_relocations = u16(len(relocations)),
		characteristics = IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ,
	}

	data_section := COFF_Section_Header {
		name = { '.', 'd', 'a', 't', 'a', 0, 0, 0 },
		size_of_raw_data = u32(len(data_buffer)),
		pointer_to_raw_data = u32(data_raw_offset),
		characteristics = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
	}

	// ============================================
	// 4. Write file
	// ============================================
	f, err := os.open(file_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != 0 {
		fmt.eprintf("Error: Could not open %s for writing\n", file_path)
		return
	}
	defer os.close(f)

	os.write_ptr(f, &header, size_of(header))
	os.write_ptr(f, &text_section, size_of(text_section))
	os.write_ptr(f, &data_section, size_of(data_section))

	if len(text_buffer) > 0 {
		os.write(f, text_buffer[:])
	}
	if len(data_buffer) > 0 {
		os.write(f, data_buffer[:])
	}

	// Symbol table
	for i := 0; i < len(symbols); i += 1 {
		sym := &symbols[i]
		os.write_ptr(f, sym, size_of(sym^))
	}

	// String table (immediately after symbol table)
	if str_tab_size > 4 {
		os.write(f, str_tab.bytes[:])
	}

	// Relocations
	for i := 0; i < len(relocations); i += 1 {
		rel := &relocations[i]
		os.write_ptr(f, rel, size_of(rel^))
	}

	fmt.printf("COFF: %s (%d .text, %d .data, %d symbols, %d relocs, %d strtab)\n",
		file_path, len(text_buffer), len(data_buffer), len(symbols), len(relocations), str_tab_size)
}

// ============================================
// Data serialization helpers
// ============================================

serialize_data_value :: proc(buf: ^[dynamic]u8, val: Data_Value, width: Width) {
	#partial switch v in val {
	case i64:
		write_integer(buf, v, width)
	case f64:
		write_float(buf, v, width)
	case string:
		for _, b in v {
			append(buf, u8(b))
		}
	case []Data_Value:
		// Array of values — serialize each element with the given width
		for elem in v {
			serialize_data_value(buf, elem, width)
		}
	case map[string]Data_Value:
		// Struct init — we'd need struct field order to serialize correctly.
		// For now, emit field values in an arbitrary order (map iteration).
		// A proper implementation requires the struct_name to look up field order.
		// Emit zero-sized placeholder if we can't determine layout.
		for k, v_elem in v {
			_ = k
			serialize_data_value(buf, v_elem, width)
		}
	case:
		// Unknown data value type — emit nothing
	}
}

write_integer :: proc(buf: ^[dynamic]u8, val: i64, width: Width) {
	switch width {
	case .U8:
		append(buf, u8(val))
	case .U16:
		append(buf, u8(val & 0xFF))
		append(buf, u8((val >> 8) & 0xFF))
	case .U32:
		append(buf, u8(val & 0xFF))
		append(buf, u8((val >> 8) & 0xFF))
		append(buf, u8((val >> 16) & 0xFF))
		append(buf, u8((val >> 24) & 0xFF))
	case .U64:
		append(buf, u8(val & 0xFF))
		append(buf, u8((val >> 8) & 0xFF))
		append(buf, u8((val >> 16) & 0xFF))
		append(buf, u8((val >> 24) & 0xFF))
		append(buf, u8((val >> 32) & 0xFF))
		append(buf, u8((val >> 40) & 0xFF))
		append(buf, u8((val >> 48) & 0xFF))
		append(buf, u8((val >> 56) & 0xFF))
	case .F32:
		bits := f32_to_bits(f32(val))
		append(buf, u8(bits & 0xFF))
		append(buf, u8((bits >> 8) & 0xFF))
		append(buf, u8((bits >> 16) & 0xFF))
		append(buf, u8((bits >> 24) & 0xFF))
	case .F64:
		bits := f64_to_bits(f64(val))
		append(buf, u8(bits & 0xFF))
		append(buf, u8((bits >> 8) & 0xFF))
		append(buf, u8((bits >> 16) & 0xFF))
		append(buf, u8((bits >> 24) & 0xFF))
		append(buf, u8((bits >> 32) & 0xFF))
		append(buf, u8((bits >> 40) & 0xFF))
		append(buf, u8((bits >> 48) & 0xFF))
		append(buf, u8((bits >> 56) & 0xFF))
	}
}

write_float :: proc(buf: ^[dynamic]u8, val: f64, width: Width) {
	if width == .F32 {
		bits := f32_to_bits(f32(val))
		append(buf, u8(bits & 0xFF))
		append(buf, u8((bits >> 8) & 0xFF))
		append(buf, u8((bits >> 16) & 0xFF))
		append(buf, u8((bits >> 24) & 0xFF))
	} else {
		bits := f64_to_bits(val)
		append(buf, u8(bits & 0xFF))
		append(buf, u8((bits >> 8) & 0xFF))
		append(buf, u8((bits >> 16) & 0xFF))
		append(buf, u8((bits >> 24) & 0xFF))
		append(buf, u8((bits >> 32) & 0xFF))
		append(buf, u8((bits >> 40) & 0xFF))
		append(buf, u8((bits >> 48) & 0xFF))
		append(buf, u8((bits >> 56) & 0xFF))
	}
}

f32_to_bits :: proc(f: f32) -> u32 {
	return transmute(u32)f
}

f64_to_bits :: proc(f: f64) -> u64 {
	return transmute(u64)f
}
