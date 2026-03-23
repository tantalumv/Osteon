#+feature dynamic-literals
package compiler

import "core:fmt"
import "core:strings"

Struct_Info :: struct {
	name:      string,
	size:      int,      // AoS: total size with padding. SoA: per-element size.
	align:     int,
	layout:    Layout_Kind,
	fields:    []Struct_Field_Info,
	soa_block: int,      // SoA only: total block size for default capacity
}

Struct_Field_Info :: struct {
	name:      string,
	type:      Width,
	offset:    int,      // AoS: byte offset from struct base. SoA: index for @soa_offset.
}

global_structs: map[string]^Struct_Info

init_layout_resolution :: proc() {
	global_structs = make(map[string]^Struct_Info)
}

width_to_size := map[Width]int {
	.U8  = 1,
	.U16 = 2,
	.U32 = 4,
	.U64 = 8,
	.F32 = 4,
	.F64 = 8,
}

resolve_struct_layout :: proc(decl: ^Struct_Decl, pkg: ^Package) {
	info := new(Struct_Info)
	info.name = decl.name
	info.layout = decl.layout

	fields := make([dynamic]Struct_Field_Info)

	if decl.layout == .SoA {
		// SoA layout: all values of field 0, then all values of field 1, etc.
		// offset stores cumulative byte offset for a capacity-1 block
		// i.e., @soa_offset(struct, field, 1) = sum of sizes of all preceding fields
		cumulative := 0
		max_align := 1

		for f in decl.fields {
			size := width_to_size[f.type]
			append(&fields, Struct_Field_Info{f.name, f.type, cumulative})
			cumulative += size
			if size > max_align {
				max_align = size
			}
		}

		info.fields = fields[:]
		info.size = cumulative   // per-element size (sum of field sizes, no padding)
		info.align = max_align
		info.soa_block = 0       // computed per-use via SIZEOF_SOA
	} else {
		// AoS layout: sequential fields with explicit padding enforcement
		curr_offset := 0
		max_align := 1

		for f in decl.fields {
			size := width_to_size[f.type]

			if curr_offset % size != 0 {
				if !strings.has_prefix(f.name, "_") {
					report_error(.Fatal_Layout, decl.src_loc, fmt.tprintf(
						"Field %s in struct %s is misaligned. Offset is %d, size is %d. Use explicit _pad field.",
						f.name, decl.name, curr_offset, size))
				}
			}

			append(&fields, Struct_Field_Info{f.name, f.type, curr_offset})
			curr_offset += size
			if size > max_align {
				max_align = size
			}
		}

		info.fields = fields[:]
		info.size = curr_offset
		info.align = max_align
		info.soa_block = 0
	}

	global_structs[info.name] = info
}
