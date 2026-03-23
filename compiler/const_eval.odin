package compiler

import "core:fmt"

Constant_Value :: union {
	i64,
	f64,
}

global_constants: map[string]Constant_Value

init_const_eval :: proc() {
	global_constants = make(map[string]Constant_Value)
}

eval_const_expr :: proc(expr: Const_Expr, pkg: ^Package) -> Constant_Value {
	#partial switch e in expr {
	case i64: { return e }
	case f64: { return e }
	case string:
		// identifier or qualified name
		if val, exists := global_constants[e]; exists {
			return val
		}
		report_error(.Fatal_Undef, {}, fmt.tprintf("Undefined constant: %s", e))
		return i64(0)
	case ^Binop_Expr:
		lhs := eval_const_expr(e.lhs, pkg)
		rhs := eval_const_expr(e.rhs, pkg)
		return eval_binop(e.op, lhs, rhs)
	case ^Unop_Expr:
		val := eval_const_expr(e.operand, pkg)
		return eval_unop(e.op, val)
	case ^Sizeof_Expr:
		return eval_sizeof(e.type_name)
	case ^Alignof_Expr:
		return eval_alignof(e.type_name)
	case ^Sizeof_Soa_Expr:
		cap_val := eval_const_expr(e.capacity, pkg)
		capacity := cap_val.(i64)
		return eval_sizeof_soa(e.type_name, capacity)
	case ^Offset_Expr:
		return eval_aos_offset(e.type_name, e.field_name)
	case ^Soa_Offset_Expr:
		cap_val := eval_const_expr(e.capacity, pkg)
		capacity := cap_val.(i64)
		return eval_soa_offset(e.type_name, e.field_name, capacity)
	case:
		return i64(0)
	}
}

// SIZEOF(Type) — byte size of a struct (AoS: with padding, SoA: per-element)
eval_sizeof :: proc(type_name: string) -> Constant_Value {
	if info, exists := global_structs[type_name]; exists {
		return i64(info.size)
	}
	// Primitive type lookup
	switch type_name {
	case "u8":  return i64(1)
	case "u16": return i64(2)
	case "u32": return i64(4)
	case "u64": return i64(8)
	case "f32": return i64(4)
	case "f64": return i64(8)
	}
	report_error(.Fatal_Undef, {}, fmt.tprintf("SIZEOF: unknown type '%s'", type_name))
	return i64(0)
}

// ALIGNOF(Type) — alignment in bytes
eval_alignof :: proc(type_name: string) -> Constant_Value {
	if info, exists := global_structs[type_name]; exists {
		return i64(info.align)
	}
	// Primitive types are self-aligned to their size
	switch type_name {
	case "u8":  return i64(1)
	case "u16": return i64(2)
	case "u32": return i64(4)
	case "u64": return i64(8)
	case "f32": return i64(4)
	case "f64": return i64(8)
	}
	report_error(.Fatal_Undef, {}, fmt.tprintf("ALIGNOF: unknown type '%s'", type_name))
	return i64(0)
}

// SIZEOF_SOA(Type, capacity) — total SoA block size
// = sum(field_sizes) * capacity, aligned to struct alignment
eval_sizeof_soa :: proc(type_name: string, capacity: i64) -> Constant_Value {
	if info, exists := global_structs[type_name]; exists {
		// info.size for SoA structs = per-element size (sum of field sizes)
		block_size := info.size * int(capacity)
		// Align to struct alignment boundary
		align := info.align
		if block_size % align != 0 {
			block_size += align - (block_size % align)
		}
		return i64(block_size)
	}
	report_error(.Fatal_Undef, {}, fmt.tprintf("SIZEOF_SOA: unknown struct '%s'", type_name))
	return i64(0)
}

// @offset(Type, field) — byte offset of field in AoS struct
eval_aos_offset :: proc(type_name: string, field_name: string) -> Constant_Value {
	if info, exists := global_structs[type_name]; exists {
		for f in info.fields {
			if f.name == field_name {
				return i64(f.offset)
			}
		}
		report_error(.Fatal_Undef, {}, fmt.tprintf("@offset: struct '%s' has no field '%s'", type_name, field_name))
		return i64(0)
	}
	report_error(.Fatal_Undef, {}, fmt.tprintf("@offset: unknown struct '%s'", type_name))
	return i64(0)
}

// @soa_offset(Type, field, capacity) — byte offset of field array in SoA block
// = sum_of_sizes_of_preceding_fields * capacity
eval_soa_offset :: proc(type_name: string, field_name: string, capacity: i64) -> Constant_Value {
	if info, exists := global_structs[type_name]; exists {
		for f in info.fields {
			if f.name == field_name {
				// f.offset for SoA = cumulative field size (sum of preceding fields' sizes)
				return i64(f.offset * int(capacity))
			}
		}
		report_error(.Fatal_Undef, {}, fmt.tprintf("@soa_offset: struct '%s' has no field '%s'", type_name, field_name))
		return i64(0)
	}
	report_error(.Fatal_Undef, {}, fmt.tprintf("@soa_offset: unknown struct '%s'", type_name))
	return i64(0)
}

eval_binop :: proc(op: Token_Kind, lhs: Constant_Value, rhs: Constant_Value) -> Constant_Value {
	l := lhs.(i64)
	r := rhs.(i64)

	#partial switch op {
	case .Plus:    return l + r
	case .Minus:   return l - r
	case .Star:    return l * r
	case .Slash:   return l / r
	case .Percent: return l % r
	case .Shl:     return l << uint(r)
	case .Shr:     return l >> uint(r)
	case .Amp:     return l & r
	case .Pipe:    return l | r
	case .Hat:     return l ~ r
	case .Eq_Eq:   return l == r ? 1 : 0
	case .Not_Eq:  return l != r ? 1 : 0
	case .Lt:      return l <  r ? 1 : 0
	case .Lt_Eq:   return l <= r ? 1 : 0
	case .Gt:      return l >  r ? 1 : 0
	case .Gt_Eq:   return l >= r ? 1 : 0
	case:          return i64(0)
	}
}

eval_unop :: proc(op: Token_Kind, val: Constant_Value) -> Constant_Value {
	v := val.(i64)
	#partial switch op {
	case .Minus:  return -v
	case .Tilde:  return ~v
	case:         return i64(0)
	}
}

// Extract i64 from Constant_Value
as_i64 :: proc(cv: Constant_Value) -> i64 {
	#partial switch v in cv {
	case i64: { return v }
	case f64: { return i64(v) }
	case: return 0
	}
}
