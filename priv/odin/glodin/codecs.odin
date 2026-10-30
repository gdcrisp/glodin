package glodin

import "../sys"
import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"

Codec_Mode :: enum {
	Tagged,
	Tuple,
	Map,
	Record,
	Untagged,
}
Codec :: struct {
	mode:   Codec_Mode,
	tag:    string,
	encode: proc(env: ^Env, value: any) -> (Term, bool),
	decode: proc(env: ^Env, term: Term, out: any) -> bool,
}
// Registration happens during library initialization, before NIF calls begin.
@(private)
codecs: map[typeid]Codec
register_codec :: proc($T: typeid, codec: Codec) {
	owned := codec
	if codec.tag != "" {
		owned.tag = strings.clone(codec.tag, runtime.heap_allocator())
	}
	if previous, exists := codecs[typeid_of(T)]; exists && previous.tag != "" {
		delete(previous.tag, runtime.heap_allocator())
	}
	codecs[typeid_of(T)] = owned
}

// Little-endian unsigned magnitude. Zero is represented by an empty digit slice.
Big_Int :: struct {
	negative: bool,
	digits:   []u8,
}

snake_case :: proc(name: string) -> string {
	b: strings.Builder
	boundary := true
	for c in name {
		if c == '(' || c == '$' {
			break
		}
		if c == '_' || c == ' ' {
			boundary = true
			continue
		}
		if c >= 'A' && c <= 'Z' {
			boundary = true
		}
		if boundary && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '_')
		}
		boundary = false
		strings.write_rune(&b, c + ('a' - 'A') if c >= 'A' && c <= 'Z' else c)
	}
	return strings.to_string(b)
}

@(private)
wire_tag :: proc(info: ^reflect.Type_Info) -> string {
	if codec, ok := codecs[info.id]; ok && codec.tag != "" {
		return codec.tag
	}
	if named, ok := info.variant.(reflect.Type_Info_Named); ok {
		tag := snake_case(named.name)
		if tag == "err" {
			return "error"
		}
		return tag
	}
	return ""
}

decode :: proc(env: ^Env, term: Term, $T: typeid) -> (value: T, ok: bool) {
	ok = decode_into(env, term, any{&value, typeid_of(T)})
	return
}
encode :: proc(env: ^Env, value: $T) -> Term {
	value := value
	term, ok := encode_value(env, any{rawptr(&value), typeid_of(T)})
	if !ok {
		return badarg(env)
	}
	return term
}

try_encode :: proc(env: ^Env, value: $T) -> (Term, bool) {
	value := value
	return encode_value(env, any{&value, typeid_of(T)})
}

@(private)
ptr_at :: proc(p: rawptr, offset: uintptr) -> rawptr {
	return rawptr(uintptr(p) + offset)
}

decode_into :: proc(env: ^Env, term: Term, out: any, depth := 0) -> bool {
	if depth > 128 {
		return false
	}
	info := type_info_of(out.id)
	if codec, ok := codecs[out.id]; ok && codec.decode != nil {
		return codec.decode(env, term, out)
	}
	switch out.id {
	case Term:
		(^Term)(out.data)^ = term
		return true
	case Atom:
		if sys.is_atom(env, term) == 0 {
			return false
		}
		(^Atom)(out.data)^ = Atom(term)
		return true
	case Reference:
		if sys.is_reference(env, term) == 0 {
			return false
		}
		(^Reference)(out.data)^ = Reference(term)
		return true
	case Pid:
		return sys.get_pid(env, term, (^Pid)(out.data)) != 0
	case Binary:
		data: ^u8
		size: uint
		if sys.inspect_binary(env, term, &data, &size) == 0 || size > uint(max(int)) {
			return false
		}
		(^Binary)(out.data)^ = Binary(mem.slice_ptr(data, int(size)))
		return true
	case Big_Int:
		value, ok := bigint_decode(env, term)
		if ok {
			(^Big_Int)(out.data)^ = value
		}
		return ok
	}
	base := reflect.type_info_base(info)
	switch t in base.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune:
		bits := base.size * 8
		signed := true
		if integer, ok := base.variant.(reflect.Type_Info_Integer); ok {
			signed = integer.signed
		}
		if bits > 64 {
			value, ok := bigint_decode(env, term)
			if !ok || len(value.digits) > 16 || (!signed && value.negative) {
				return false
			}
			n: u128
			for digit, i in value.digits {
				n |= u128(digit) << uint(8 * i)
			}
			if signed && ((!value.negative && n > u128(max(i128))) || (value.negative && n > u128(max(i128)) + 1)) {
				return false
			}
			if value.negative {
				n = ~n + 1
			}
			mem.copy(out.data, &n, base.size)
			return true
		}
		if signed {
			n: i64
			if sys.get_i64(env, term, &n) == 0 ||
			   (bits < 64 && (n < -(i64(1) << uint(bits - 1)) || n > (i64(1) << uint(bits - 1)) - 1)) {
				return false
			}
			mem.copy(out.data, &n, base.size)
		} else {
			n: u64
			if sys.get_u64(env, term, &n) == 0 || (bits < 64 && n > (u64(1) << uint(bits)) - 1) {
				return false
			}
			mem.copy(out.data, &n, base.size)
		}
		return true
	case reflect.Type_Info_Float:
		n: f64
		if sys.get_float(env, term, &n) == 0 {
			return false
		}
		if base.size == 8 {
			(^f64)(out.data)^ = n
		} else if base.size == 4 {
			if n > f64(max(f32)) || n < -f64(max(f32)) {
				return false
			}
			(^f32)(out.data)^ = f32(n)
		} else {
			return false
		}
		return true
	case reflect.Type_Info_Boolean:
		if term == Term(atom(env, "true")) {
			(^bool)(out.data)^ = true
			return true
		}
		if term == Term(atom(env, "false")) {
			(^bool)(out.data)^ = false
			return true
		}
		return false
	case reflect.Type_Info_String:
		if t.is_cstring {
			return false
		}
		value, ok := decode(env, term, Binary)
		if !ok || !utf8.valid_string(string(value)) {
			return false
		}
		(^string)(out.data)^ = string(value)
		return true
	case reflect.Type_Info_Array, reflect.Type_Info_Slice, reflect.Type_Info_Dynamic_Array:
		elem: ^reflect.Type_Info
		count := -1
		switch a in base.variant {
		case reflect.Type_Info_Array:
			elem = a.elem
			count = a.count
		case reflect.Type_Info_Slice:
			elem = a.elem
		case reflect.Type_Info_Dynamic_Array:
			elem = a.elem
		case reflect.Type_Info_Named,
		     reflect.Type_Info_Integer,
		     reflect.Type_Info_Rune,
		     reflect.Type_Info_Float,
		     reflect.Type_Info_Complex,
		     reflect.Type_Info_Quaternion,
		     reflect.Type_Info_String,
		     reflect.Type_Info_Boolean,
		     reflect.Type_Info_Any,
		     reflect.Type_Info_Type_Id,
		     reflect.Type_Info_Pointer,
		     reflect.Type_Info_Multi_Pointer,
		     reflect.Type_Info_Procedure,
		     reflect.Type_Info_Enumerated_Array,
		     reflect.Type_Info_Parameters,
		     reflect.Type_Info_Struct,
		     reflect.Type_Info_Union,
		     reflect.Type_Info_Enum,
		     reflect.Type_Info_Map,
		     reflect.Type_Info_Bit_Set,
		     reflect.Type_Info_Simd_Vector,
		     reflect.Type_Info_Matrix,
		     reflect.Type_Info_Soa_Pointer,
		     reflect.Type_Info_Bit_Field,
		     reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
			return false
		}
		n: u32
		if sys.list_length(env, term, &n) == 0 ||
		   (count >= 0 && int(n) != count) ||
		   uint(n) > uint(max(int)) / uint(max(elem.size, 1)) {
			return false
		}
		data := out.data
		if count < 0 {
			data, _ = mem.alloc(int(n) * elem.size, elem.align)
			if _, ok := base.variant.(reflect.Type_Info_Dynamic_Array); ok {
				(^runtime.Raw_Dynamic_Array)(out.data)^ = runtime.Raw_Dynamic_Array {
					data,
					int(n),
					int(n),
					context.allocator,
				}
			} else {
				(^runtime.Raw_Slice)(out.data)^ = runtime.Raw_Slice{data, int(n)}
			}
		}
		tail := term
		for i in 0 ..< int(n) {
			head: Term
			if sys.list_cell(env, tail, &head, &tail) == 0 ||
			   !decode_into(env, head, any{ptr_at(data, uintptr(i * elem.size)), elem.id}, depth + 1) {
				return false
			}
		}
		return sys.is_empty_list(env, tail) != 0
	case reflect.Type_Info_Struct:
		codec := codecs[info.id]
		terms: []Term
		if codec.mode != .Map {
			tag := wire_tag(info)
			if t.field_count == 0 && codec.mode != .Tuple {
				return term == Term(atom(env, tag))
			}
			value, ok := tuple_elements(env, term)
			if !ok {
				return false
			}
			terms = value
			offset := 1 if codec.mode == .Tagged || codec.mode == .Record else 0
			if len(terms) != int(t.field_count) + offset || (offset == 1 && terms[0] != Term(atom(env, tag))) {
				return false
			}
			terms = terms[offset:]
		}
		for i in 0 ..< int(t.field_count) {
			field_term: Term
			if codec.mode == .Map {
				if sys.map_get(env, term, Term(atom(env, t.names[i])), &field_term) == 0 {
					return false
				}
			} else {
				field_term = terms[i]
			}
			if !decode_into(env, field_term, any{ptr_at(out.data, t.offsets[i]), t.types[i].id}, depth + 1) {
				return false
			}
		}
		return true
	case reflect.Type_Info_Union:
		for variant in t.variants {
			if variant == nil {
				continue
			}
			// Decode alternatives into fresh storage; failed alternatives cannot leave stale state.
			data, _ := mem.alloc(variant.size, variant.align)
			if decode_into(env, term, any{data, variant.id}, depth + 1) {
				mem.copy(out.data, data, variant.size)
				reflect.set_union_variant_typeid(out, variant.id)
				return true
			}
		}
		return false
	case reflect.Type_Info_Enum:
		for name, i in t.names {
			if term == Term(atom(env, snake_case(name))) {
				n := i64(t.values[i])
				mem.copy(out.data, &n, base.size)
				return true
			}
		}
		return false
	case reflect.Type_Info_Map:
		it := sys.map_iterator(env, term)
		if it == nil {
			return false
		}
		defer sys.map_iterator_free(env, it)
		key, _ := mem.alloc(t.key.size, t.key.align)
		value, _ := mem.alloc(t.value.size, t.value.align)
		kt, vt: Term
		for sys.map_pair(env, it, &kt, &vt) != 0 {
			if !decode_into(env, kt, any{key, t.key.id}, depth + 1) ||
			   !decode_into(env, vt, any{value, t.value.id}, depth + 1) {
				return false
			}
			_, err := runtime.__dynamic_map_set_without_hash((^runtime.Raw_Map)(out.data), t.map_info, key, value)
			if err != nil {
				return false
			}
		}
		return true
	case reflect.Type_Info_Named,
	     reflect.Type_Info_Complex,
	     reflect.Type_Info_Quaternion,
	     reflect.Type_Info_Any,
	     reflect.Type_Info_Type_Id,
	     reflect.Type_Info_Pointer,
	     reflect.Type_Info_Multi_Pointer,
	     reflect.Type_Info_Procedure,
	     reflect.Type_Info_Enumerated_Array,
	     reflect.Type_Info_Parameters,
	     reflect.Type_Info_Bit_Set,
	     reflect.Type_Info_Simd_Vector,
	     reflect.Type_Info_Matrix,
	     reflect.Type_Info_Soa_Pointer,
	     reflect.Type_Info_Bit_Field,
	     reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
		return false
	}
	return false
}

encode_value :: proc(env: ^Env, value: any, depth := 0) -> (Term, bool) {
	if depth > 128 {
		return 0, false
	}
	if codec, ok := codecs[value.id]; ok && codec.encode != nil {
		return codec.encode(env, value)
	}
	switch value.id {
	case Term, Atom, Reference:
		return (^Term)(value.data)^, true
	case Pid:
		return sys.make_pid(env, (^Pid)(value.data)), true
	case Binary:
		bytes := (^Binary)(value.data)^
		return sys.make_bytes(env, raw_data(bytes), uint(len(bytes))), true
	case Owned_Binary:
		if (^Owned_Binary)(value.data).handle == nil {
			return 0, false
		}
		return binary_release(env, (^Owned_Binary)(value.data)), true
	case Big_Int:
		return bigint_encode(env, (^Big_Int)(value.data)^)
	case Error:
		error := (^Error)(value.data)^
		switch error.kind {
		case .Bad_Argument:
			return badarg(env), true
		case .Exception:
			return raise(env, error.reason), true
		}
	}
	info := type_info_of(value.id)
	base := reflect.type_info_base(info)
	switch t in base.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Rune:
		signed := true
		if integer, ok := base.variant.(reflect.Type_Info_Integer); ok {
			signed = integer.signed
		}
		if base.size > 8 {
			n := (^u128)(value.data)^
			negative := signed && (n >> 127) != 0
			if negative {
				n = ~n + 1
			}
			bytes := mem.slice_ptr((^u8)(&n), 16)
			return bigint_encode(env, Big_Int{negative, bytes})
		}
		n: u64
		mem.copy(&n, value.data, base.size)
		if signed {
			shift := 64 - base.size * 8
			return sys.make_i64(env, (i64(n << uint(shift))) >> uint(shift)), true
		}
		return sys.make_u64(env, n), true
	case reflect.Type_Info_Float:
		if base.size == 8 {
			if (transmute(u64)((^f64)(value.data)^) & 0x7ff0_0000_0000_0000) == 0x7ff0_0000_0000_0000 {
				return 0, false
			}
			return sys.make_float(env, (^f64)(value.data)^), true
		} else if base.size == 4 {
			if (transmute(u32)((^f32)(value.data)^) & 0x7f80_0000) == 0x7f80_0000 {
				return 0, false
			}
			return sys.make_float(env, f64((^f32)(value.data)^)), true
		}
		return 0, false
	case reflect.Type_Info_Boolean:
		return Term(atom(env, "true" if (^bool)(value.data)^ else "false")), true
	case reflect.Type_Info_String:
		if t.is_cstring {
			return 0, false
		}
		text := (^string)(value.data)^
		if !utf8.valid_string(text) {
			return 0, false
		}
		return sys.make_bytes(env, raw_data(text), uint(len(text))), true
	case reflect.Type_Info_Array, reflect.Type_Info_Slice, reflect.Type_Info_Dynamic_Array:
		items := make([dynamic]Term)
		it: int
		for elem, _ in reflect.iterate_array(value, &it) {
			term, ok := encode_value(env, elem, depth + 1)
			if !ok {
				return 0, false
			}
			append(&items, term)
		}
		term := sys.empty_list(env)
		for i := len(items) - 1; i >= 0; i -= 1 {
			term = sys.cons(env, items[i], term)
		}
		return term, true
	case reflect.Type_Info_Struct:
		codec := codecs[info.id]
		tag := wire_tag(info)
		if t.field_count == 0 && codec.mode != .Tuple && codec.mode != .Map {
			return Term(atom(env, tag)), true
		}
		items := make([dynamic]Term)
		if codec.mode == .Tagged || codec.mode == .Record {
			append(&items, Term(atom(env, tag)))
		}
		result_map := sys.map_new(env)
		for i in 0 ..< int(t.field_count) {
			term, ok := encode_value(env, any{ptr_at(value.data, t.offsets[i]), t.types[i].id}, depth + 1)
			if !ok {
				return 0, false
			}
			if codec.mode == .Map {
				if sys.map_put(env, result_map, Term(atom(env, t.names[i])), term, &result_map) == 0 {
					return 0, false
				}
			} else {
				append(&items, term)
			}
		}
		if codec.mode == .Map {
			return result_map, true
		}
		return tuple(env, items[:]), true
	case reflect.Type_Info_Union:
		variant := reflect.get_union_variant(value)
		if variant.id == nil {
			return 0, false
		}
		return encode_value(env, variant, depth + 1)
	case reflect.Type_Info_Enum:
		name, ok := reflect.enum_name_from_value_any(value)
		if !ok {
			return 0, false
		}
		return Term(atom(env, snake_case(name))), true
	case reflect.Type_Info_Map:
		result_map := sys.map_new(env)
		it: int
		for key, val in reflect.iterate_map(value, &it) {
			kt, key_ok := encode_value(env, key, depth + 1)
			vt, val_ok := encode_value(env, val, depth + 1)
			if !key_ok || !val_ok || sys.map_put(env, result_map, kt, vt, &result_map) == 0 {
				return 0, false
			}
		}
		return result_map, true
	case reflect.Type_Info_Named,
	     reflect.Type_Info_Complex,
	     reflect.Type_Info_Quaternion,
	     reflect.Type_Info_Any,
	     reflect.Type_Info_Type_Id,
	     reflect.Type_Info_Pointer,
	     reflect.Type_Info_Multi_Pointer,
	     reflect.Type_Info_Procedure,
	     reflect.Type_Info_Enumerated_Array,
	     reflect.Type_Info_Parameters,
	     reflect.Type_Info_Bit_Set,
	     reflect.Type_Info_Simd_Vector,
	     reflect.Type_Info_Matrix,
	     reflect.Type_Info_Soa_Pointer,
	     reflect.Type_Info_Bit_Field,
	     reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
		return 0, false
	}
	return 0, false
}

bigint_decode :: proc(env: ^Env, term: Term) -> (Big_Int, bool) {
	// ETF is inspected only after the VM has encoded the term; non-integers are rejected.
	handle := sys.external_binary(env, term)
	if handle == nil {
		return {}, false
	}
	defer sys.owned_binary_free(handle)
	bytes := mem.slice_ptr(sys.owned_binary_data(handle), int(sys.owned_binary_size(handle)))
	if len(bytes) < 3 || bytes[0] != 131 {
		return {}, false
	}
	result: Big_Int
	switch bytes[1] {
	case 97:
		result.digits = make([]u8, 1)
		result.digits[0] = bytes[2]
	case 98:
		if len(bytes) != 6 {
			return {}, false
		}
		n := i32(u32(bytes[2]) << 24 | u32(bytes[3]) << 16 | u32(bytes[4]) << 8 | u32(bytes[5]))
		result.negative = n < 0
		magnitude := u32(-i64(n)) if n < 0 else u32(n)
		result.digits = make([]u8, 4)
		mem.copy(raw_data(result.digits), &magnitude, 4)
	case 110, 111:
		offset := 4
		n := int(bytes[2])
		if bytes[1] == 111 {
			if len(bytes) < 7 {
				return {}, false
			}
			n = int(u32(bytes[2]) << 24 | u32(bytes[3]) << 16 | u32(bytes[4]) << 8 | u32(bytes[5]))
			offset = 7
		}
		if n > len(bytes) - offset {
			return {}, false
		}
		result.negative = bytes[offset - 1] != 0
		result.digits = make([]u8, n)
		copy(result.digits, bytes[offset:offset + n])
	case:
		return {}, false
	}
	return result, true
}

bigint_encode :: proc(env: ^Env, value: Big_Int) -> (Term, bool) {
	count := len(value.digits)
	for count > 0 && value.digits[count - 1] == 0 {
		count -= 1
	}
	if count == 0 {
		return sys.make_i64(env, 0), true
	}
	if u64(count) > u64(max(u32)) {
		return 0, false
	}
	bytes := make([]u8, count + 7)
	bytes[0], bytes[1] = 131, 111
	n := u32(count)
	bytes[2], bytes[3], bytes[4], bytes[5] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
	bytes[6] = 1 if value.negative else 0
	copy(bytes[7:], value.digits[:count])
	term: Term
	ok := sys.from_external(env, raw_data(bytes), uint(len(bytes)), &term) != 0
	return term, ok
}
