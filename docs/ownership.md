# Ownership and lifecycle

Every generated C entry point establishes a fresh Odin context and a dynamic
arena. `context.allocator` and `context.temp_allocator` both refer to that arena
during the native function. It is destroyed after the return value is encoded.

- Decoded strings and `Binary` values borrow immutable BEAM memory. Never mutate
  or retain their bytes after the call.
- Decoded slices, arrays, maps, Big_Int digits, and intermediate codec storage
  use the call allocator. Copy them into an explicitly owned allocator before
  storing them in a resource or job. A resource containing an Odin slice owns
  only the slice header until you provide persistent backing storage.
- `Term` and `Reference` belong to their environment. Use `Owned_Env`, `save`,
  and `load` to copy terms between calls/threads. Clearing or destroying an
  environment invalidates its saved terms. Environments require external
  synchronization when shared between threads.
- `Owned_Binary` is zero-initialized and mutable while owned. `binary_release`
  transfers it to BEAM and clears its handle. Generated encoding performs this
  transfer for returned owned binaries. Destroy abandoned binaries explicitly.
- `beam_allocator()` provides aligned native allocations backed by `enif_alloc`.
  Pair allocation and deallocation with the same allocator.

## Resources

`Resource(T)` decoded as an argument is borrowed for the call. `resource_new`
creates an owned native reference. Returning it transfers that reference to
BEAM; releasing an abandoned resource requires `resource_release`.
`resource_keep` acquires an additional owned reference. Do not copy an owned
resource and release both copies. Ownership is explicit, not compiler-enforced.

Use `resource_lock`/`resource_unlock` around mutable payload access. Pure readers
still need synchronization when other calls can mutate the same payload.
`resource_binary` retains its resource for the binary's lifetime; the referenced
bytes must be immutable and valid until its destructor runs.

`monitor` returns owned monitor storage. Destroy that storage with
`monitor_destroy`; this does not remove the BEAM monitor. Use `demonitor` first
when cancellation is intended. Destructor, down, stop, and dynamic-call callbacks may execute
on BEAM threads and must synchronize shared application state.

`dynamic_resource_call` invokes another registered resource type using a raw
call-data pointer. Caller and provider must agree on its layout; it stays valid
through the synchronous callback. This interface does not validate that layout.

Map iterators own C iterator storage. Pair creation with `map_iterator_destroy`;
iteration may alternate `map_next` and `map_previous` without repeating entries.
The referenced term still belongs to its environment.

Resource takeover keeps the native payload and lock. Resource names, header
layout, and payload layout are compatibility contracts across versions. Change
the resource type/name when a payload layout changes; provide an application
migration instead of reinterpreting old bytes as a different Odin structure.
The generic header carries no callbacks into the old library, and destructor
dispatch resolves callbacks in the new library after takeover.

## Background work

`spawn` creates a job on an OS thread with a heap-backed context and an independent
environment. Copy/retain its data before submitting it; call-scoped memory is
not valid input. The job owns cleanup of its submitted payload. `job_send`
encodes into the job environment and sends to its recipient. Check its return
value if the recipient may have exited.

Completed threads are reaped on later submissions. Generated unload callbacks
join outstanding threads before the library unloads. Long-lived workers must
implement termination in the application so a code purge can finish.
Once shutdown starts, new job submissions fail instead of joining work while
holding the submission lock. A failed submission leaves payload cleanup to its caller.

## Lifecycle callbacks

Callbacks use Odin's normal calling convention; generated C adapters establish
the context:

```odin
@(glodin_load)
on_load :: proc(env: ^glodin.Env, data: ^rawptr, info: glodin.Term) -> i32 {
	return 0
}

@(glodin_upgrade)
on_upgrade :: proc(env: ^glodin.Env, data, old_data: ^rawptr, info: glodin.Term) -> i32 {
	return 0
}

@(glodin_unload)
on_unload :: proc(env: ^glodin.Env, data: rawptr) {
	// Release application-owned private state here.
}
```

Load/upgrade return zero for success. A missing upgrade callback reuses the load
callback to initialize a separate library instance. Explicit upgrade callbacks
configure their resource callbacks and handle old private state. Generated
resource registration runs before both load and upgrade callbacks. The unload adapter
joins jobs, invokes the application's callback, and frees Glodin's registries.

Raw NIF API access is available through `glodin:sys` using
`sys.api("enif_function", proc "c" (...))`. Supply the exact C signature from the
selected OTP headers. Allocate opaque C structures through C; a guessed Odin
layout is not an ABI contract. This interface is intentionally low level.
