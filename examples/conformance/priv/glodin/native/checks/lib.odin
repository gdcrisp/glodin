package checks

import "base:runtime"
import math_big "core:math/big"
import "core:mem"
import "core:sync"
import bigint "glodin:bigint"
import g "glodin:glodin"
import sys "glodin:sys"

Person :: struct {
	name: string,age:  i64,
}
Colour :: enum {
	Red,
	Green,
	Blue,
}
Circle :: struct {
	radius: f64,
}
Rectangle :: struct {
	width:  f64,height: f64,
}
Shape :: union {
	Circle,
	Rectangle,
}
@(glodin_codec = "tuple")
Pair :: struct {
	first:  i64,second: string,
}
@(glodin_codec = "map")
Settings :: struct {
	enabled: bool,size:    i64,
}

Counter :: struct {
	value: i64,
}
Auto_State :: struct {
	value: i64,
}
@(glodin_resource)
Observed :: struct {
	recipient: g.Pid,
}
@(glodin_resource)
Blob :: struct {
	bytes: []u8,
}
@(glodin_resource)
Selectable :: struct {
	lock:      sync.Mutex,
	read_event:  g.Event,
	write_event: g.Event,
	recipient: g.Pid,
}

@(glodin_gleam = "Int")
Positive :: distinct i64

@(glodin_codec = "record")
Native_Record :: struct {
	value: i64,
}
@(glodin_codec = "untagged")
Native_Value :: union {
	i64,
	string,
}
counter_type: g.Resource_Type(Counter)
worker_pool: ^g.Worker_Pool
pool_gate: sync.Sema

@(glodin_load)
on_load :: proc(env: ^g.Env, data: ^rawptr, info: g.Term) -> i32 {
	loaded, valid := g.decode(env, info, i64)
	if !valid {
		return -1
	}
	private := new(i64, g.beam_allocator())
	private^ = loaded
	data^ = private
	registered, ok := g.resource_open(env, "counter", Counter, g.Resource_Callbacks(Counter) {
		dyncall = proc(env: ^g.Env, counter: ^Counter, call_data: rawptr) {
			(^i64)(call_data)^ = counter.value
		},
	})
	if !ok {
		return -1
	}
	counter_type = registered
	_, observed_ok := g.resource_open(env, "observed", Observed, g.Resource_Callbacks(Observed) {
		destroy = proc(value: ^Observed) {
			env := g.env_new()
			defer g.env_destroy(&env)
			g.send(nil, value.recipient, env.env, g.Term(g.atom(env.env, "observed_destroyed")))
		},
		down = proc(env: ^g.Env, value: ^Observed, pid: g.Pid, monitor: rawptr) {
			g.send(nil, value.recipient, env, g.Term(g.atom(env, "observed_down")))
		},
	})
	_, blob_ok := g.resource_open(env, "blob", Blob, g.Resource_Callbacks(Blob) {
		destroy = proc(value: ^Blob) {
			delete(value.bytes, g.beam_allocator())
		},
	})
	_, selectable_ok := g.resource_open(env, "selectable", Selectable, g.Resource_Callbacks(Selectable) {
		destroy = close_selectable,
		stop = proc(env: ^g.Env, value: ^Selectable, event: g.Event, direct: bool) {
			close_selectable(value)
			message_env := g.env_new()
			defer g.env_destroy(&message_env)
			g.send(nil, value.recipient, message_env.env, g.Term(g.atom(message_env.env, "select_stopped")))
		},
	})
	if !observed_ok || !blob_ok || !selectable_ok {
		return -1
	}
	g.register_codec(Positive, g.Codec {
		decode = proc(env: ^g.Env, term: g.Term, out: any) -> bool {
			n, ok := g.decode(env, term, i64)
			if !ok || n <= 0 {
				return false
			}
			(^Positive)(out.data)^ = Positive(n)
			return true
		},
		encode = proc(env: ^g.Env, value: any) -> (g.Term, bool) {
			return g.encode(env, i64((^Positive)(value.data)^)), true
		},
	})
	pool, pool_ok := g.pool_new(2, 4)
	if !pool_ok {
		return -1
	}
	worker_pool = pool
	return 0
}

@(glodin_unload)
on_unload :: proc(env: ^g.Env, data: rawptr) {
	mem.free(data, g.beam_allocator())
}

@(glodin_upgrade)
on_upgrade :: proc(env: ^g.Env, data, old_data: ^rawptr, info: g.Term) -> i32 {
	old_value: i64
	if old_data^ != nil {
		old_value = (^i64)(old_data^)^
	}
	status := on_load(env, data, info)
	if status == 0 {
		(^i64)(data^)^ += old_value
	}
	return status
}

@(glodin_nif)
load_value :: proc(env: ^g.Env) -> i64 {
	return (^i64)(g.private_data(env))^
}
@(glodin_nif)
private_increment :: proc(env: ^g.Env, delta: i64) -> i64 {
	value := (^i64)(g.private_data(env))
	value^ += delta
	return value^
}
@(glodin_nif)
auto_new :: proc(value: i64) -> g.Resource(Auto_State) {
	resource, ok := g.resource_new(Auto_State{value})
	assert(ok)
	return resource
}
@(glodin_nif)
auto_read :: proc(resource: g.Resource(Auto_State)) -> i64 {
	return resource.data.value
}
@(glodin_nif)
echo_record :: proc(record: Native_Record) -> Native_Record {
	return record
}
@(glodin_nif)
echo_untagged :: proc(value: Native_Value) -> Native_Value {
	return value
}

@(glodin_nif)
atom_roundtrip :: proc(env: ^g.Env, name: string) -> string {
	value := g.atom(env, name)
	existing, found := g.existing_atom(env, name)
	assert(found && existing == value)
	text, ok := g.atom_name(env, value)
	assert(ok)
	return text
}
@(glodin_nif)
iterate_values :: proc(env: ^g.Env, list, dict: g.Term) -> i64 {
	it := g.list_iterator(env, list)
	count: i64
	for {
		_, ok := g.list_next(&it)
		if !ok {
			break
		}
		count += 1
	}
	assert(!it.failed)
	map_it, is_map := g.map_iterator(env, dict)
	assert(is_map)
	defer g.map_iterator_destroy(&map_it)
	for {
		_, _, ok := g.map_next(&map_it)
		if !ok {
			break
		}
		count += 1
	}
	return count
}
continuation :: proc "c" (env: ^g.Env, argc: i32, argv: [^]g.Term) -> g.Term {
	context = runtime.default_context()
	if argc != 1 {
		return g.badarg(env)
	}
	n, ok := g.decode(env, argv[0], i64)
	if !ok {
		return g.badarg(env)
	}
	return g.encode(env, n + 1)
}
@(glodin_nif)
yielding :: proc(env: ^g.Env, n: i64) -> g.Term {
	g.consume_timeslice(env, 1)
	args := [1]g.Term{g.encode(env, n)}
	return g.schedule(env, "glodin_continuation", .Normal, continuation, args[:])
}

@(glodin_nif)
echo_i8 :: proc(n: i8) -> i8 {
	return n
}
@(glodin_nif)
echo_u64 :: proc(n: u64) -> u64 {
	return n
}
@(glodin_nif)
echo_i128 :: proc(n: i128) -> i128 {
	return n
}
@(glodin_nif)
echo_big :: proc(n: g.Big_Int) -> g.Big_Int {
	return n
}
@(glodin_nif)
double_big :: proc(n: g.Big_Int) -> g.Big_Int {
	value, ok := bigint.to_core(n)
	assert(ok)
	defer math_big.destroy(&value)
	assert(math_big.add(&value, &value, &value) == .None)
	result, converted := bigint.from_core(&value)
	assert(converted)
	return result
}
@(glodin_nif)
echo_float :: proc(n: f64) -> f64 {
	return n
}
@(glodin_nif)
echo_string :: proc(s: string) -> string {
	return s
}
@(glodin_nif)
echo_bytes :: proc(s: g.Binary) -> g.Binary {
	return s
}
@(glodin_nif)
echo_list :: proc(items: []i64) -> []i64 {
	return items
}
@(glodin_nif)
echo_map :: proc(items: map[string]i64) -> map[string]i64 {
	return items
}
@(glodin_nif)
echo_person :: proc(person: Person) -> Person {
	return person
}
@(glodin_nif)
echo_colour :: proc(colour: Colour) -> Colour {
	return colour
}
@(glodin_nif)
echo_shape :: proc(shape: Shape) -> Shape {
	return shape
}
@(glodin_nif)
echo_pair :: proc(pair: Pair) -> Pair {
	return pair
}
@(glodin_nif)
echo_settings :: proc(settings: Settings) -> Settings {
	return settings
}
@(glodin_nif)
echo_result :: proc(result: g.Result(i64, string)) -> g.Result(i64, string) {
	return result
}
@(glodin_nif)
echo_option :: proc(option: g.Option(i64)) -> g.Option(i64) {
	return option
}

@(glodin_nif)
echo_json :: proc(value: g.Json(Person)) -> g.Json(Person) {
	return value
}

@(glodin_nif)
pool_enqueue :: proc(recipient: g.Pid, n: i64) -> bool {
	data := new(i64, runtime.heap_allocator())
	data^ = n
	ok := g.pool_submit(worker_pool, recipient, data, proc(job: ^g.Job) {
		defer free(job.data, runtime.heap_allocator())
		g.job_send(job, g.Atom(g.atom(job.env.env, "pool_started")))
		sync.sema_wait(&pool_gate)
		g.job_send(job, (^i64)(job.data)^ * 2)
	})
	if !ok {
		free(data, runtime.heap_allocator())
	}
	return ok
}

@(glodin_nif)
pool_release :: proc() {
	sync.sema_post(&pool_gate, 6)
}

@(glodin_nif, glodin_schedule = "DirtyIo")
pool_close :: proc() {
	g.pool_close(worker_pool)
}
@(glodin_nif, glodin_name = "renamed", glodin_schedule = "DirtyCpu")
dirty_operation :: proc(n: i64) -> i64 {
	return n * 2
}
@(glodin_nif, glodin_schedule = "DirtyIo")
dirty_io :: proc(n: i64) -> i64 {
	return n
}
@(glodin_nif)
counter_new :: proc(n: i64) -> g.Resource(Counter) {
	resource, ok := g.resource_new(counter_type, Counter{n})
	assert(ok)
	return resource
}
@(glodin_nif)
counter_increment :: proc(counter: g.Resource(Counter)) -> i64 {
	g.resource_lock(counter)
	defer g.resource_unlock(counter)
	counter.data.value += 1
	return counter.data.value
}
@(glodin_nif)
counter_read :: proc(counter: g.Resource(Counter)) -> i64 {
	g.resource_lock(counter)
	defer g.resource_unlock(counter)
	return counter.data.value
}

@(glodin_nif)
counter_dynamic :: proc(env: ^g.Env, counter: g.Resource(Counter)) -> i64 {
	g.resource_lock(counter)
	defer g.resource_unlock(counter)
	value: i64
	term := g.encode(env, counter)
	assert(
		!g.dynamic_resource_call(
			env,
			g.atom(env, "glodin_conformance_checks_ffi"),
			g.atom(env, "missing_resource"),
			term,
			&value,
		),
	)
	assert(
		g.dynamic_resource_call(
			env,
			g.atom(env, "glodin_conformance_checks_ffi"),
			g.atom(env, "counter"),
			term,
			&value,
		),
	)
	return value
}

@(glodin_nif)
iolist_bytes :: proc(env: ^g.Env, value: g.Term) -> g.Nif_Result(g.Binary) {
	bytes, ok := g.binary_from_iolist(env, value)
	if !ok {
		return g.Error{kind = .Bad_Argument}
	}
	return bytes
}

@(glodin_nif)
sub_bytes :: proc(env: ^g.Env, value: g.Term, offset, length: i64) -> g.Nif_Result(g.Term) {
	term, ok := g.binary_sub(env, value, int(offset), int(length))
	if !ok {
		return g.Error{kind = .Bad_Argument}
	}
	return term
}

@(glodin_nif)
check_term_operations :: proc(env: ^g.Env, value: g.Term, portable: u32) -> bool {
	assert(g.hash_phash2(value) == portable)
	assert(g.hash_internal(value, 42) == g.hash_internal(g.copy_term(env, value), 42))
	size, available := g.term_size(value)
	assert(!available || size > 0)
	assert(g.identical(value, g.copy_term(env, value)))
	assert(g.compare(g.encode(env, 1), g.encode(env, 2)) < 0)
	assert(g.is_scheduler_thread())
	pid, found := g.whereis_pid(env, g.Term(g.atom(env, "glodin_conformance_runner")))
	assert(found && g.is_process_alive(env, pid))
	self, exists := g.self(env)
	assert(exists && pid == self)
	_, missing := g.whereis_pid(env, g.Term(g.atom(env, "glodin_missing_process")))
	assert(!missing)
	owned, serialized := g.term_to_binary(env, value)
	assert(serialized)
	defer g.binary_destroy(&owned)
	bytes := g.binary_data(owned)
	decoded, consumed, valid := g.binary_to_term(env, bytes)
	assert(valid && consumed == len(bytes) && g.identical(value, decoded))
	decoded_trusted, _, trusted := g.binary_to_term(env, bytes, true)
	assert(trusted && g.identical(value, decoded_trusted))
	_, _, invalid := g.binary_to_term(env, []u8{131, 255})
	assert(!invalid)
	with_tail := make([]u8, len(bytes) + 1)
	copy(with_tail, bytes)
	_, prefix, prefix_ok := g.binary_to_term(env, with_tail)
	assert(prefix_ok && prefix == len(bytes))
	empty := g.list_new(env)
	list := g.list_prepend(env, g.encode(env, 2), g.list_prepend(env, g.encode(env, 1), empty))
	reversed, reversed_ok := g.list_reverse(env, list)
	n, proper := g.list_length(env, reversed)
	assert(reversed_ok && proper && n == 2)
	head, tail, cell := g.list_cell(env, reversed)
	assert(cell && g.identical(head, g.encode(env, 1)))
	n, proper = g.list_length(env, tail)
	assert(proper && n == 1)
	_, improper := g.list_reverse(env, g.list_prepend(env, head, head))
	assert(!improper)
	key := g.Term(g.atom(env, "answer"))
	dict, inserted := g.map_put(env, g.map_new(env), key, g.encode(env, 41))
	assert(inserted)
	updated: bool
	dict, updated = g.map_update(env, dict, key, g.encode(env, 42))
	assert(updated)
	_, missing_key := g.map_update(env, dict, g.Term(g.atom(env, "absent")), head)
	assert(!missing_key)
	answer, present := g.map_get(env, dict, key)
	assert(present && g.identical(answer, g.encode(env, 42)))
	removed: bool
	dict, removed = g.map_remove(env, dict, key)
	assert(removed)
	count, sized := g.map_size(env, dict)
	assert(sized && count == 0)
	assembled: bool
	dict, assembled = g.map_from_arrays(env, []g.Term{key}, []g.Term{answer})
	assert(assembled)
	count, sized = g.map_size(env, dict)
	assert(sized && count == 1)
	_, mismatch := g.map_from_arrays(env, []g.Term{key}, nil)
	assert(!mismatch)
	assert(!g.truthy(env, g.Term(g.atom(env, "nil"))))
	assert(!g.truthy(env, g.encode(env, false)))
	assert(g.truthy(env, g.encode(env, 0)))
	keys := []g.Term{g.encode(env, 1), g.encode(env, 2), g.encode(env, 3)}
	dict, assembled = g.map_from_arrays(env, keys, keys)
	assert(assembled)
	it, iterable := g.map_iterator(env, dict)
	assert(iterable)
	defer g.map_iterator_destroy(&it)
	first, _, first_ok := g.map_next(&it)
	last, _, last_ok := g.map_previous(&it)
	middle, _, middle_ok := g.map_next(&it)
	assert(first_ok && last_ok && middle_ok)
	assert(!g.identical(first, last) && !g.identical(first, middle) && !g.identical(last, middle))
	_, _, exhausted := g.map_previous(&it)
	assert(!exhausted)
	copy_binary, copied := g.binary_from_slice([]u8{1, 2})
	assert(copied)
	defer g.binary_destroy(&copy_binary)
	assert(g.binary_resize(&copy_binary, 4))
	assert(g.binary_data(copy_binary)[2] == 0 && g.binary_data(copy_binary)[3] == 0)
	return true
}
@(glodin_nif)
new_reference :: proc(env: ^g.Env) -> g.Reference {
	return g.Reference(g.make_reference(env))
}
@(glodin_nif)
get_self :: proc(env: ^g.Env) -> g.Pid {
	pid, ok := g.self(env)
	assert(ok)
	return pid
}
@(glodin_nif)
send_message :: proc(env: ^g.Env, pid: g.Pid, message: g.Term) -> bool {
	return g.send(env, pid, nil, message)
}
@(glodin_nif)
background :: proc(pid: g.Pid, n: i64) -> bool {
	data := new(i64, runtime.heap_allocator())
	data^ = n
	return g.spawn(pid, data, proc(job: ^g.Job) {
		assert(!g.is_scheduler_thread())
		n := (^i64)(job.data)
		defer free(n, runtime.heap_allocator())
		g.job_send(job, n^ * 2)
	})
}
@(glodin_nif)
raise_error :: proc(env: ^g.Env) -> g.Nif_Result(i64) {
	return g.Error{kind = .Exception, reason = g.Term(g.atom(env, "deliberate"))}
}

@(glodin_nif)
echo_positive :: proc(n: Positive) -> Positive {
	return n
}
@(glodin_nif)
watch_process :: proc(env: ^g.Env, recipient, target: g.Pid) -> g.Resource(Observed) {
	resource, ok := g.resource_new(Observed{recipient})
	assert(ok)
	retained := g.resource_keep(resource)
	g.resource_release(&resource)
	monitor, monitored := g.monitor(env, retained, target)
	assert(monitored)
	g.monitor_destroy(&monitor)
	return retained
}

@(glodin_nif)
watch_then_cancel :: proc(env: ^g.Env, recipient, target: g.Pid) -> g.Resource(Observed) {
	resource, ok := g.resource_new(Observed{recipient})
	assert(ok)
	monitor, monitored := g.monitor(env, resource, target)
	assert(monitored)
	assert(g.demonitor(env, resource, monitor))
	g.monitor_destroy(&monitor)
	return resource
}

@(glodin_nif)
select_stop :: proc(env: ^g.Env, resource: g.Resource(Selectable)) -> bool {
	flags := sys.select(env, resource.data.read_event, 4, resource.handle, nil, g.make_reference(env))
	return (flags & 3) != 0
}
@(glodin_nif)
owned_bytes :: proc(bytes: g.Binary) -> g.Owned_Binary {
	owned, ok := g.binary_new(len(bytes))
	assert(ok)
	copy(g.binary_data(owned), ([]u8)(bytes))
	return owned
}
@(glodin_nif)
environment_copy :: proc(env: ^g.Env, value: g.Term) -> g.Term {
	owned := g.env_new()
	defer g.env_destroy(&owned)
	saved := g.save(&owned, value)
	return g.load(saved, env)
}
@(glodin_nif)
resource_bytes :: proc(env: ^g.Env, bytes: g.Binary) -> g.Term {
	data := make([]u8, len(bytes), g.beam_allocator())
	copy(data, ([]u8)(bytes))
	resource, ok := g.resource_new(Blob{data})
	assert(ok)
	defer g.resource_release(&resource)
	return g.resource_binary(env, resource, data)
}
@(glodin_nif)
check_low_level :: proc(env: ^g.Env, value: g.Term) -> bool {
	is_number, found := sys.api("enif_is_number", proc "c" (_: ^g.Env, _: g.Term) -> i32)
	return found && is_number(env, value) != 0
}
@(glodin_nif)
check_allocator :: proc() -> bool {
	pointer, error := mem.alloc(1000, 64, g.beam_allocator())
	if error != nil {
		return false
	}
	defer mem.free(pointer, g.beam_allocator())
	bytes := mem.slice_ptr((^u8)(pointer), 1000)
	for byte in bytes {
		if byte != 0 {
			return false
		}
	}
	return uintptr(pointer) % 64 == 0 && g.convert_time(1, .Second, .Millisecond) == 1000
}
