package glodin

import "../sys"

List_Iterator :: struct {
	env:    ^Env,
	tail:   Term,
	failed: bool,
}
list_iterator :: proc(env: ^Env, term: Term) -> List_Iterator {
	return List_Iterator{env = env, tail = term}
}
list_next :: proc(it: ^List_Iterator) -> (Term, bool) {
	if sys.is_empty_list(it.env, it.tail) != 0 {
		return 0, false
	}
	head: Term
	if sys.list_cell(it.env, it.tail, &head, &it.tail) == 0 {
		it.failed = true
		return 0, false
	}
	return head, true
}

Map_Iterator :: struct {
	env:       ^Env,
	handle:    rawptr,
	backward:  rawptr,
	remaining: int,
}
map_iterator :: proc(env: ^Env, term: Term) -> (Map_Iterator, bool) {
	n, valid := map_size(env, term)
	if !valid {
		return {}, false
	}
	handle := sys.map_iterator(env, term)
	backward := sys.map_iterator_last(env, term)
	it := Map_Iterator {
		env       = env,
		handle    = handle,
		backward  = backward,
		remaining = n,
	}
	if handle == nil || backward == nil {
		map_iterator_destroy(&it)
		return {}, false
	}
	return it, true
}
map_next :: proc(it: ^Map_Iterator) -> (Term, Term, bool) {
	key, value: Term
	ok := it.remaining > 0 && it.handle != nil && sys.map_pair(it.env, it.handle, &key, &value) != 0
	if ok {
		it.remaining -= 1
	}
	return key, value, ok
}
map_previous :: proc(it: ^Map_Iterator) -> (Term, Term, bool) {
	key, value: Term
	ok := it.remaining > 0 && it.backward != nil && sys.map_pair_previous(it.env, it.backward, &key, &value) != 0
	if ok {
		it.remaining -= 1
	}
	return key, value, ok
}
map_iterator_destroy :: proc(it: ^Map_Iterator) {
	if it.handle != nil {
		sys.map_iterator_free(it.env, it.handle)
		it.handle = nil
	}
	if it.backward != nil {
		sys.map_iterator_free(it.env, it.backward)
		it.backward = nil
	}
	it.remaining = 0
}

Time_Unit :: enum i32 {
	Second      = 0,
	Millisecond = 1,
	Microsecond = 2,
	Nanosecond  = 3,
}
monotonic_time :: proc(unit: Time_Unit) -> i64 {
	return sys.monotonic_time(i32(unit))
}
time_offset :: proc(unit: Time_Unit) -> i64 {
	return sys.time_offset(i32(unit))
}
convert_time :: proc(value: i64, from, to: Time_Unit) -> i64 {
	return sys.convert_time(value, i32(from), i32(to))
}
