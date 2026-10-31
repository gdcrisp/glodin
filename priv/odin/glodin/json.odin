package glodin

import json "core:encoding/json"
import "core:strconv"
import "core:unicode/utf8"

// JSON values travel as UTF-8 BEAM binaries, independently of Gleam constructors.
// Decoded storage belongs to context.allocator (the generated call arena).
Json :: struct($T: typeid) {
	value: T,
}

json_decode :: proc(bytes: Binary, $T: typeid) -> (value: T, ok: bool) {
	if !json_document_valid(transmute([]u8)bytes) {
		return value, false
	}
	err := json.unmarshal(transmute([]u8)bytes, &value, .JSON)
	if err != nil {
		return value, false
	}
	// Core's typed decoder permits narrowing casts and absent fields. Require a
	// lossless round trip so neither can silently change a caller's JSON value.
	original, parse_err := json.parse_bytes(transmute([]u8)bytes, .JSON, true)
	if parse_err != nil {
		return value, false
	}
	defer json.destroy_value(original)
	encoded, marshal_err := json.marshal(value, {spec = .JSON})
	if marshal_err != nil {
		return value, false
	}
	defer delete(encoded)
	roundtrip, roundtrip_err := json.parse_bytes(encoded, .JSON, true)
	if roundtrip_err != nil {
		return value, false
	}
	defer json.destroy_value(roundtrip)
	return value, json_values_equal(original, roundtrip)
}

json_encode :: proc(value: $T) -> (Owned_Binary, bool) {
	bytes, err := json.marshal(value, {spec = .JSON})
	if err != nil {
		return {}, false
	}
	defer delete(bytes)
	if !json_document_valid(bytes) {
		return {}, false
	}
	return binary_from_slice(bytes)
}

// Bound nesting before invoking the recursive core decoder, and require EOF.
@(private)
json_document_valid :: proc(bytes: []u8) -> bool {
	if !utf8.valid_string(string(bytes)) {
		return false
	}
	tokenizer := json.make_tokenizer(string(bytes), .JSON, true)
	depth := 0
	started, complete: bool
	for {
		token, err := json.get_token(&tokenizer)
		if token.kind == .EOF {
			return started && complete && json.is_valid(bytes, .JSON, true)
		}
		if err != nil {
			return false
		}
		if token.kind == .Integer {
			_, valid := strconv.parse_i64(token.text)
			if !valid {
				return false
			}
		}
		if complete {
			return false
		}
		started = true
		switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
			if depth > 128 {
				return false
			}
		case .Close_Brace, .Close_Bracket:
			depth -= 1
			if depth < 0 {
				return false
			}
			complete = depth == 0
		case .Null, .False, .True, .Integer, .Float, .String:
			complete = depth == 0
		case .Invalid, .EOF, .Infinity, .NaN, .Ident, .Colon, .Comma:
			if depth == 0 {
				return false
			}
		}
	}
}

@(private)
json_values_equal :: proc(a, b: json.Value) -> bool {
	switch x in a {
	case json.Null:
		_, ok := b.(json.Null)
		return ok
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.Integer:
		y, ok := b.(json.Integer)
		return ok && x == y
	case json.Float:
		y, ok := b.(json.Float)
		return ok && x == y
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) {
			return false
		}
		for item, i in x {
			if !json_values_equal(item, y[i]) {
				return false
			}
		}
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || len(x) != len(y) {
			return false
		}
		for key, item in x {
			other, found := y[key]
			if !found || !json_values_equal(item, other) {
				return false
			}
		}
		return true
	}
	return false
}

register_json_codec :: proc($T: typeid) {
	register_codec(Json(T), Codec {
		decode = proc(env: ^Env, term: Term, out: any) -> bool {
			bytes, binary_ok := decode(env, term, Binary)
			if !binary_ok {
				return false
			}
			value, ok := json_decode(bytes, T)
			if ok {
				(^Json(T))(out.data)^ = {value = value}
			}
			return ok
		},
		encode = proc(env: ^Env, value: any) -> (Term, bool) {
			binary, ok := json_encode((^Json(T))(value.data).value)
			if !ok {
				return 0, false
			}
			return binary_release(env, &binary), true
		},
	})
}
