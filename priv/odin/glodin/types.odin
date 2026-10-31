package glodin

import "../sys"
import "core:mem"
import "core:strings"

Env :: sys.Env
Term :: sys.Term
Atom :: distinct Term
Reference :: distinct Term
Pid :: sys.Pid
Event :: sys.Event
Raw_Nif :: proc "c" (env: ^Env, argc: i32, argv: [^]Term) -> Term

// Binary is a read-only view valid for the current environment's lifetime.
Binary :: distinct []u8
Owned_Env :: struct {
	env: ^Env,
}
Saved_Term :: struct {
	owner: ^Env,
	term:  Term,
}
Owned_Binary :: struct {
	handle: rawptr,
}
New_Binary :: Owned_Binary

Scheduler :: enum i32 {
	Normal    = 0,
	Dirty_Cpu = 1,
	Dirty_Io  = 2,
}
Error_Kind :: enum {
	Bad_Argument,
	Exception,
}
Error :: struct {
	kind:   Error_Kind,
	reason: Term,
}
Return :: union {
	Term,
	Error,
}
Nif_Result :: union($T: typeid) {
	T,
	Error,
}
Ok :: struct($T: typeid) {
	value: T,
}
Err :: struct($E: typeid) {
	error: E,
}
Result :: union($T, $E: typeid) {
	Ok(T),
	Err(E),
}
Some :: struct($T: typeid) {
	value: T,
}
None :: struct {}
Option :: union($T: typeid) {
	Some(T),
	None,
}

badarg :: sys.badarg
raise :: sys.raise
private_data :: sys.private
consume_timeslice :: proc(env: ^Env, percent: int) -> bool {
	return sys.consume_timeslice(env, i32(clamp(percent, 1, 100))) != 0
}
is_alive :: proc(env: ^Env) -> bool {
	return sys.alive(env) != 0
}
compare :: sys.compare
identical :: proc(a, b: Term) -> bool {
	return sys.identical(a, b) != 0
}
Term_Type :: enum i32 {
	Unknown   = -1,
	Atom      = 1,
	Bitstring = 2,
	Float     = 3,
	Function  = 4,
	Integer   = 5,
	List      = 6,
	Map       = 7,
	Pid       = 8,
	Port      = 9,
	Reference = 10,
	Tuple     = 11,
}
term_type :: proc(env: ^Env, term: Term) -> Term_Type {
	kind := sys.term_type(env, term)
	if kind < 1 || kind > 11 {
		return .Unknown
	}
	return Term_Type(kind)
}
copy_term :: sys.copy

atom :: proc(env: ^Env, name: string) -> Atom {
	return Atom(sys.atom(env, raw_data(name), uint(len(name)), 0))
}
existing_atom :: proc(env: ^Env, name: string) -> (Atom, bool) {
	t := sys.atom(env, raw_data(name), uint(len(name)), 1)
	return Atom(t), t != 0
}
atom_name :: proc(env: ^Env, value: Atom) -> (string, bool) {
	buffer: [1025]u8
	n := sys.atom_name(env, Term(value), &buffer[0], u32(len(buffer)))
	if n <= 0 {
		return "", false
	}
	return strings.clone(string(buffer[:n - 1])), true
}
tuple :: proc(env: ^Env, terms: []Term) -> Term {
	return sys.tuple(env, raw_data(terms), u32(len(terms)))
}
tuple_elements :: proc(env: ^Env, term: Term) -> ([]Term, bool) {
	n: i32
	data: ^Term
	if sys.get_tuple(env, term, &n, &data) == 0 {
		return nil, false
	}
	return mem.slice_ptr(data, int(n)), true
}

env_new :: proc() -> Owned_Env {return Owned_Env{sys.alloc_env()}}
env_destroy :: proc(env: ^Owned_Env) {
	if env.env != nil {
		sys.free_env(env.env)
		env.env = nil
	}
}
env_clear :: proc(env: ^Owned_Env) {
	sys.clear_env(env.env)
}
save :: proc(env: ^Owned_Env, term: Term) -> Saved_Term {
	return Saved_Term{env.env, sys.copy(env.env, term)}
}
load :: proc(saved: Saved_Term, env: ^Env) -> Term {
	return sys.copy(env, saved.term)
}

binary_new :: proc(size: int) -> (Owned_Binary, bool) {
	if size < 0 {
		return {}, false
	}
	handle := sys.owned_binary(uint(size))
	return Owned_Binary{handle}, handle != nil
}
binary_data :: proc(binary: Owned_Binary) -> []u8 {
	if binary.handle == nil {
		return nil
	}
	return mem.slice_ptr(sys.owned_binary_data(binary.handle), int(sys.owned_binary_size(binary.handle)))
}
binary_resize :: proc(binary: ^Owned_Binary, size: int) -> bool {
	return size >= 0 && binary.handle != nil && sys.owned_binary_resize(binary.handle, uint(size)) != 0
}
binary_destroy :: proc(binary: ^Owned_Binary) {
	sys.owned_binary_free(binary.handle)
	binary.handle = nil
}
binary_release :: proc(env: ^Env, binary: ^Owned_Binary) -> Term {
	if binary.handle == nil {
		return badarg(env)
	}
	term := sys.owned_binary_release(env, binary.handle)
	binary.handle = nil
	return term
}
make_reference :: sys.reference
self :: proc(env: ^Env) -> (Pid, bool) {
	pid: Pid
	ok := sys.self(env, &pid) != 0
	return pid, ok
}
send :: proc(env: ^Env, pid: Pid, message_env: ^Env, message: Term) -> bool {
	pid := pid
	return sys.send(env, &pid, message_env, message) != 0
}
schedule :: proc(env: ^Env, name: cstring, scheduler: Scheduler, callback: Raw_Nif, argv: []Term) -> Term {
	return sys.schedule(env, transmute(^u8)name, i32(scheduler), rawptr(callback), i32(len(argv)), raw_data(argv))
}
