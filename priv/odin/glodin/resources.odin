package glodin

import "../sys"
import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"

Resource :: struct($T: typeid) {
	data:   ^T,
	handle: rawptr,
	owned:  bool,
}
Resource_Type :: struct($T: typeid) {
	handle: rawptr,
	name:   string,
}
resource_type :: proc($T: typeid) -> (Resource_Type(T), bool) {
	desc, exists := resource_descriptors[typeid_of(T)]
	return Resource_Type(T){desc.handle, desc.name}, exists
}
Monitor :: struct {
	data: []u8,
}
Resource_Callbacks :: struct($T: typeid) {
	destroy: proc(data: ^T),
	down:    proc(env: ^Env, data: ^T, pid: Pid, monitor: rawptr),
	stop:    proc(env: ^Env, data: ^T, event: Event, direct: bool),
	dyncall: proc(env: ^Env, data: ^T, call_data: rawptr),
}

// The header carries no Odin pointers or procedure addresses, so resource type
// takeover can use callbacks from the new library. Payload layout must remain compatible.
@(private)
Resource_Header :: struct {
	name:           [128]u8,
	payload_offset: uintptr,
	mutex:          rawptr,
}
@(private)
Resource_Descriptor :: struct {
	handle:  rawptr,
	name:    string,
	destroy: proc(_: rawptr),
	down:    proc(_: ^Env, _: rawptr, _: Pid, _: rawptr),
	stop:    proc(_: ^Env, _: rawptr, _: Event, _: bool),
	dyncall: proc(_: ^Env, _: rawptr, _: rawptr),
}
@(private)
resource_descriptors: map[typeid]Resource_Descriptor
@(private)
resource_names: map[string]Resource_Descriptor
@(private)
resource_mutex: sync.Mutex

@(private)
resource_payload :: proc(handle: rawptr) -> rawptr {
	return rawptr(uintptr(handle) + (^Resource_Header)(handle).payload_offset)
}
@(private)
resource_descriptor :: proc(header: ^Resource_Header) -> Resource_Descriptor {
	sync.mutex_lock(&resource_mutex)
	defer sync.mutex_unlock(&resource_mutex)
	name := strings.trim_right(string(header.name[:]), "\x00")
	return resource_names[name]
}
@(private)
resource_destroy_callback :: proc "c" (env: ^Env, handle: rawptr) {
	context = runtime.default_context()
	header := (^Resource_Header)(handle)
	desc := resource_descriptor(header)
	if desc.destroy != nil {
		desc.destroy(resource_payload(handle))
	}
	if header.mutex != nil {
		sys.mutex_free(header.mutex)
	}
}
@(private)
resource_down_callback :: proc "c" (env: ^Env, handle: rawptr, pid: ^Pid, monitor: rawptr) {
	context = runtime.default_context()
	desc := resource_descriptor((^Resource_Header)(handle))
	if desc.down != nil {
		desc.down(env, resource_payload(handle), pid^, monitor)
	}
}
@(private)
resource_stop_callback :: proc "c" (env: ^Env, handle: rawptr, event: Event, direct: i32) {
	context = runtime.default_context()
	desc := resource_descriptor((^Resource_Header)(handle))
	if desc.stop != nil {
		desc.stop(env, resource_payload(handle), event, direct != 0)
	}
}

@(private)
resource_dyncall_callback :: proc "c" (env: ^Env, handle, call_data: rawptr) {
	context = runtime.default_context()
	desc := resource_descriptor((^Resource_Header)(handle))
	if desc.dyncall != nil {
		desc.dyncall(env, resource_payload(handle), call_data)
	}
}

// The caller and resource provider must agree on call_data's layout and lifetime.
dynamic_resource_call :: proc(env: ^Env, module, name: Atom, resource: Term, call_data: rawptr) -> bool {
	call, found := sys.api(
		"enif_dynamic_resource_call",
		proc "c" (_: ^Env, _: Term, _: Term, _: Term, _: rawptr) -> i32,
	)
	return found && call(env, Term(module), Term(name), resource, call_data) == 0
}

// Call during load/upgrade. Persisted payload size/layout is the author's contract.
resource_open :: proc {
	resource_open_default,
	resource_open_with_callbacks,
}
resource_open_default :: proc(env: ^Env, name: string, $T: typeid) -> (Resource_Type(T), bool) {
	return resource_open_with_callbacks(env, name, T, Resource_Callbacks(T){})
}
resource_open_with_callbacks :: proc(
	env: ^Env,
	name: string,
	$T: typeid,
	callbacks: Resource_Callbacks(T),
) -> (
	Resource_Type(T),
	bool,
) {
	if len(name) == 0 || len(name) >= 128 {
		return {}, false
	}
	sync.mutex_lock(&resource_mutex)
	defer sync.mutex_unlock(&resource_mutex)
	name_c := strings.clone_to_cstring(name)
	defer delete(name_c)
	previous, registered := resource_descriptors[typeid_of(T)]
	handle := previous.handle
	if registered && previous.name != name {
		return {}, false
	}
	if !registered {
		for id, other in resource_descriptors {
			if id != typeid_of(T) && other.name == name {
				return {}, false
			}
		}
		handle = sys.open_resource(
			env,
			transmute(^u8)name_c,
			rawptr(resource_destroy_callback),
			rawptr(resource_down_callback),
			rawptr(resource_stop_callback),
			rawptr(resource_dyncall_callback),
		)
	}
	if handle == nil {
		return {}, false
	}
	name := strings.clone(name)
	if registered {
		delete_key(&resource_names, previous.name)
		delete(previous.name)
	}
	desc := Resource_Descriptor {
		handle = handle,
		name   = name,
	}
	// Store typed callbacks separately. The adapters resolve the current version
	// by type at callback time rather than embedding old code pointers in objects.
	set_resource_callbacks(T, callbacks)
	desc.destroy = proc(ptr: rawptr) {
		c := get_resource_callbacks(T)
		if c.destroy != nil {
			c.destroy((^T)(ptr))
		}
	}
	desc.down = proc(e: ^Env, ptr: rawptr, pid: Pid, monitor: rawptr) {
		c := get_resource_callbacks(T)
		if c.down != nil {
			c.down(e, (^T)(ptr), pid, monitor)
		}
	}
	desc.stop = proc(e: ^Env, ptr: rawptr, event: Event, direct: bool) {
		c := get_resource_callbacks(T)
		if c.stop != nil {
			c.stop(e, (^T)(ptr), event, direct)
		}
	}
	desc.dyncall = proc(e: ^Env, ptr, call_data: rawptr) {
		c := get_resource_callbacks(T)
		if c.dyncall != nil {
			c.dyncall(e, (^T)(ptr), call_data)
		}
	}
	resource_descriptors[typeid_of(T)] = desc
	resource_names[name] = desc
	register_resource_codec(T)
	return Resource_Type(T){handle, name}, true
}

@(private)
resource_callbacks: map[typeid]rawptr
@(private)
set_resource_callbacks :: proc($T: typeid, callbacks: Resource_Callbacks(T)) {
	if previous, registered := resource_callbacks[typeid_of(T)]; registered {
		mem.free(previous)
	}
	p := new(Resource_Callbacks(T))
	p^ = callbacks
	resource_callbacks[typeid_of(T)] = p
}
@(private)
get_resource_callbacks :: proc($T: typeid) -> Resource_Callbacks(T) {
	sync.mutex_lock(&resource_mutex)
	defer sync.mutex_unlock(&resource_mutex)
	return (^Resource_Callbacks(T))(resource_callbacks[typeid_of(T)])^
}

register_resource_codec :: proc($T: typeid) {
	register_codec(Resource(T), Codec {
		decode = proc(env: ^Env, term: Term, out: any) -> bool {
			desc, registered := resource_descriptors[typeid_of(T)]
			if !registered {
				return false
			}
			handle: rawptr
			if sys.resource_get(env, term, desc.handle, &handle) == 0 {
				return false
			}
			(^Resource(T))(out.data)^ = Resource(T){(^T)(resource_payload(handle)), handle, false}
			return true
		},
		encode = proc(env: ^Env, value: any) -> (Term, bool) {
			resource := (^Resource(T))(value.data)
			if resource.handle == nil {
				return 0, false
			}
			term := sys.resource_term(env, resource.handle)
			if resource.owned {
				sys.resource_release(resource.handle)
				resource.owned = false
			}
			return term, true
		},
	})
}

resource_new :: proc {
	resource_new_with_type,
	resource_new_registered,
}
resource_new_registered :: proc(value: $T) -> (Resource(T), bool) {
	desc, exists := resource_descriptors[typeid_of(T)]
	if !exists {
		return {}, false
	}
	return resource_new_with_type(Resource_Type(T){desc.handle, desc.name}, value)
}
resource_new_with_type :: proc(resource_type: Resource_Type($T), value: T) -> (Resource(T), bool) {
	if resource_type.handle == nil {
		return {}, false
	}
	mutex := sys.mutex_new()
	if mutex == nil {
		return {}, false
	}
	handle := sys.resource_alloc(resource_type.handle, uint(size_of(Resource_Header) + size_of(T) + align_of(T)))
	if handle == nil {
		sys.mutex_free(mutex)
		return {}, false
	}
	header := (^Resource_Header)(handle)
	offset :=
		uintptr(mem.align_forward(rawptr(uintptr(handle) + uintptr(size_of(Resource_Header))), uintptr(align_of(T)))) -
		uintptr(handle)
	header^ = Resource_Header {
		payload_offset = offset,
		mutex          = mutex,
	}
	copy(header.name[:], transmute([]u8)resource_type.name)
	data := (^T)(resource_payload(handle))
	data^ = value
	return Resource(T){data, handle, true}, true
}

resource_keep :: proc(resource: Resource($T)) -> Resource(T) {
	sys.resource_keep(resource.handle)
	return Resource(T){resource.data, resource.handle, true}
}
resource_release :: proc(resource: ^Resource($T)) {
	if resource.owned && resource.handle != nil {
		sys.resource_release(resource.handle)
	}
	resource^ = {}
}
resource_lock :: proc(resource: Resource($T)) {
	sys.mutex_lock((^Resource_Header)(resource.handle).mutex)
}
resource_unlock :: proc(resource: Resource($T)) {
	sys.mutex_unlock((^Resource_Header)(resource.handle).mutex)
}
resource_binary :: proc(env: ^Env, resource: Resource($T), bytes: []u8) -> Term {
	return sys.resource_binary(env, resource.handle, raw_data(bytes), uint(len(bytes)))
}
monitor :: proc(env: ^Env, resource: Resource($T), pid: Pid) -> (Monitor, bool) {
	pid := pid
	m := Monitor{make([]u8, int(sys.monitor_size()), beam_allocator())}
	status := sys.monitor(env, resource.handle, &pid, cast(^sys.Monitor)raw_data(m.data))
	if status != 0 {
		monitor_destroy(&m)
		return {}, false
	}
	return m, status == 0
}
monitor_destroy :: proc(monitor: ^Monitor) {
	delete(monitor.data, beam_allocator())
	monitor.data = nil
}
demonitor :: proc(env: ^Env, resource: Resource($T), monitor: Monitor) -> bool {
	if len(monitor.data) != int(sys.monitor_size()) {
		return false
	}
	return sys.demonitor(env, resource.handle, cast(^sys.Monitor)raw_data(monitor.data)) == 0
}
