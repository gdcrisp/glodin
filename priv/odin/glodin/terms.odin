package glodin

import "../sys"
import "core:mem"

// Erlang/Elixir truthiness is an explicit alternative to the strict Bool codec.
truthy :: proc(env: ^Env, term: Term) -> bool {
	return !identical(term, Term(atom(env, "false"))) && !identical(term, Term(atom(env, "nil")))
}

// Returned terms and binary views belong to env. Copy before retaining them.
list_new :: sys.empty_list
list_prepend :: sys.cons
list_length :: proc(env: ^Env, term: Term) -> (int, bool) {
	n: u32
	ok := sys.list_length(env, term, &n) != 0
	return int(n), ok
}
list_cell :: proc(env: ^Env, term: Term) -> (Term, Term, bool) {
	head, tail: Term
	ok := sys.list_cell(env, term, &head, &tail) != 0
	return head, tail, ok
}
list_reverse :: proc(env: ^Env, term: Term) -> (Term, bool) {
	call, found := sys.api("enif_make_reverse_list", proc "c" (_: ^Env, _: Term, _: ^Term) -> i32)
	out: Term
	ok := found && call(env, term, &out) != 0
	return out, ok
}
map_new :: sys.map_new
map_get :: proc(env: ^Env, term, key: Term) -> (Term, bool) {
	out: Term
	ok := sys.map_get(env, term, key, &out) != 0
	return out, ok
}
map_size :: proc(env: ^Env, term: Term) -> (int, bool) {
	call, found := sys.api("enif_get_map_size", proc "c" (_: ^Env, _: Term, _: ^uint) -> i32)
	n: uint
	ok := found && call(env, term, &n) != 0
	return int(n), ok
}
map_put :: proc(env: ^Env, term, key, value: Term) -> (Term, bool) {
	out: Term
	ok := sys.map_put(env, term, key, value, &out) != 0
	return out, ok
}
map_remove :: proc(env: ^Env, term, key: Term) -> (Term, bool) {
	call, found := sys.api("enif_make_map_remove", proc "c" (_: ^Env, _: Term, _: Term, _: ^Term) -> i32)
	out: Term
	ok := found && call(env, term, key, &out) != 0
	return out, ok
}
map_update :: proc(env: ^Env, term, key, value: Term) -> (Term, bool) {
	call, found := sys.api("enif_make_map_update", proc "c" (_: ^Env, _: Term, _: Term, _: Term, _: ^Term) -> i32)
	out: Term
	ok := found && call(env, term, key, value, &out) != 0
	return out, ok
}
map_from_arrays :: proc(env: ^Env, keys, values: []Term) -> (Term, bool) {
	if len(keys) != len(values) {
		return 0, false
	}
	call, found := sys.api(
		"enif_make_map_from_arrays",
		proc "c" (_: ^Env, _: ^Term, _: ^Term, _: uint, _: ^Term) -> i32,
	)
	out: Term
	ok := found && call(env, raw_data(keys), raw_data(values), uint(len(keys)), &out) != 0
	return out, ok
}
binary_from_iolist :: proc(env: ^Env, term: Term) -> (Binary, bool) {
	data: ^u8
	size: uint
	if sys.inspect_iolist(env, term, &data, &size) == 0 {
		return nil, false
	}
	return Binary(mem.slice_ptr(data, int(size))), true
}
binary_from_slice :: proc(bytes: []u8) -> (Owned_Binary, bool) {
	binary, ok := binary_new(len(bytes))
	if ok {
		copy(binary_data(binary), bytes)
	}
	return binary, ok
}
binary_sub :: proc(env: ^Env, term: Term, offset, length: int) -> (Term, bool) {
	data: ^u8
	size: uint
	if offset < 0 ||
	   length < 0 ||
	   sys.inspect_binary(env, term, &data, &size) == 0 ||
	   uint(offset) > size ||
	   uint(length) > size - uint(offset) {
		return 0, false
	}
	return sys.sub_binary(env, term, uint(offset), uint(length)), true
}
term_to_binary :: proc(env: ^Env, term: Term) -> (Owned_Binary, bool) {
	handle := sys.external_binary(env, term)
	return Owned_Binary{handle}, handle != nil
}
// Safe decoding refuses creation of atoms and external function references.
// trusted=true is only for trusted ETF input; consumed identifies trailing bytes.
binary_to_term :: proc(env: ^Env, bytes: []u8, trusted := false) -> (Term, int, bool) {
	out: Term
	n := sys.binary_to_term(env, raw_data(bytes), uint(len(bytes)), &out, i32(trusted))
	return out, int(n), n != 0
}
hash_internal :: proc(term: Term, salt: u64) -> u64 {
	call, found := sys.api("enif_hash", proc "c" (_: i32, _: Term, _: u64) -> u64)
	assert(found)
	return call(1, term, salt)
}
hash_phash2 :: proc(term: Term) -> u32 {
	call, found := sys.api("enif_hash", proc "c" (_: i32, _: Term, _: u64) -> u64)
	assert(found)
	return u32(call(2, term, 0))
}
// Available on OTP 29 and later; callers must inspect the availability result.
term_size :: proc(term: Term) -> (uint, bool) {
	call, found := sys.api("enif_term_size", proc "c" (_: Term) -> uint)
	if !found {
		return 0, false
	}
	return call(term), true
}
whereis_pid :: proc(env: ^Env, name_or_pid: Term) -> (Pid, bool) {
	pid: Pid
	if sys.get_pid(env, name_or_pid, &pid) != 0 {
		return pid, true
	}
	call, found := sys.api("enif_whereis_pid", proc "c" (_: ^Env, _: Term, _: ^Pid) -> i32)
	ok := found && call(env, name_or_pid, &pid) != 0
	return pid, ok
}
is_process_alive :: proc(env: ^Env, pid: Pid) -> bool {
	pid := pid
	call, found := sys.api("enif_is_process_alive", proc "c" (_: ^Env, _: ^Pid) -> i32)
	return found && call(env, &pid) != 0
}
is_scheduler_thread :: proc() -> bool {
	call, found := sys.api("enif_thread_type", proc "c" () -> i32)
	return found && call() != 0
}
