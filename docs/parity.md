# Rustler parity and release gates

Reference: [Rustler 0.39.0](https://github.com/rusterlium/rustler/tree/rustler-0.39.0).
This checklist tracks capabilities, not identical Rust symbols or syntax.
An implementation check means the capability is present. Verification is a
separate column; a local test does not certify every operation or platform.

| Capability | Glodin implementation | Example / verification |
| --- | --- | --- |
| Typed NIF exports and automatic conversion | `@(glodin_nif)`, parser and generated adapters | `examples/math`; incremental/scaffold integration test |
| Export renaming and registration | `glodin_name`, generated C `ERL_NIF_INIT` | renamed export and stale-module tests |
| Normal / dirty CPU / dirty I/O schedulers | `glodin_schedule`, `Scheduler` | conformance `renamed`, `dirty_io` |
| Project scaffolding and compiler integration | `glodin.main`, bundled escripts, pinned Gleam patch | ordinary `gleam run/build/test`; dependency hook tests |
| Root/dependency prebuild hooks | `erlang.build_hooks` argv arrays | root/dependency cache, environment, literal-argument, failure tests |
| Load, upgrade, unload, private data | generated lifecycle adapters; `private_data` | explicit upgrade migrates private state and automatically registers resources; old code is purged |
| Load data and dynamic load data | `load_data`, `load_data_fun` | static load data and Erlang load-data function tested |
| Terms, atoms, PIDs, references, equality and comparison | `Term`, `Atom`, `Pid`, `Reference`, `term_type`, `compare`, `identical`, `whereis_pid`, `is_process_alive` | UTF-8 atoms, process lookup, references, identity and ordering tested |
| ETF conversion, hashing and term size | `term_to_binary`, `binary_to_term`, `hash_internal`, `hash_phash2`, `term_size` | safe/trusted ETF round trips, malformed ETF, trailing input and Erlang `phash2` agreement; size reports availability on OTP 29+ |
| Integer codecs and arbitrary precision | checked integer codecs, `Big_Int`, optional `glodin:bigint` | signed/unsigned boundaries, negative 128-bit and 1024-bit round trips |
| Float, boolean and UTF-8 string codecs | checked primitive codecs | float/type errors, booleans and malformed UTF-8 tested |
| Borrowed / new / owned binaries | `Binary`, `Owned_Binary`, transfer/resize/release helpers, `binary_sub`, `binary_from_iolist` | opaque bytes, resized/zeroed owned buffers, resource binaries, nested iolists and checked sub-binary bounds |
| Lists, tuples, maps and iterators | recursive codecs, `List_Iterator`, `Map_Iterator`, list/map operations | malformed lists, nested round trips, map mutations, forward/backward iteration without duplicates |
| Struct/map/record/tuple derivation | `glodin_codec`, `glodin_tag` | tagged struct/map/tuple and record round trips |
| Unit, tagged and untagged enums | enum and union codecs, generated Gleam declarations | unit/tagged round trips and untagged alternatives/rejection |
| Gleam Results and Options | `Result(T,E)`, `Option(T)` | both variants tested from Gleam and Erlang |
| Custom encoder/decoder extension points | `register_codec`, `Codec`, `glodin_gleam` | `Positive` custom codec and rejection test |
| Bad arguments and explicit exceptions | `Error`, `Nif_Result(T)`, `badarg`, `raise` | malformed values and explicit exception tested |
| Call-scoped allocation | generated per-call dynamic arenas | exercised by all generated wrappers |
| BEAM allocator | `beam_allocator` | alignment, zero initialization and paired free tested |
| Independent environments and saved terms | `Owned_Env`, `Saved_Term`, `save`, `load`, clear/destroy | nested term copied through an owned environment |
| Typed reference-counted resources and destructors | `Resource(T)`, resource open/new/keep/release helpers | shared counter, wrong-resource rejection, destructor notification |
| Resource synchronization | resource lock/unlock | 8 processes increment one resource concurrently |
| Resource binaries | `resource_binary` | binary lifetime backed by a resource |
| Process monitors and down callbacks | `monitor`, `demonitor`, `Monitor` | process exit, explicit cancellation, retained ownership and destructor notifications |
| I/O stop callbacks and selection | resource stop callback; OTP API through `glodin:sys` | real pipe readiness and stop/close callback tested |
| Dynamic resource calls | `Resource_Callbacks(T).dyncall`, `dynamic_resource_call` | successful callback and missing resource-type rejection |
| Resource takeover and code upgrade | stable resource header, current-library callbacks, hashed libraries | retained counter survives upgrade and old-code purge |
| Background threads and messaging | `spawn`, `Job`, `job_send`, `send`; joins on unload | background result, direct send, upgrade/purge tested |
| Timeslices and rescheduling | `consume_timeslice`, `schedule`, `is_scheduler_thread` | yielding continuation, scheduler calls and non-scheduler worker thread checked |
| Low-level NIF API access | OTP-header-generated lookup with exact caller-supplied C signatures | `sys.api("enif_is_number", ...)` tested; no claim that every OTP API is individually tested |
| Multiple native modules, compiler flags/paths, targets and collections | module JSON, `ODIN`/`CC`, compiler arrays, `target`, `collections`, `watch`, `otp_include` | multiple modules, existing TOML preservation, normal paths and imported aliases tested; cross-compilation and collection combinations need broader coverage |
| Explicitly supplied libraries | `skip_compilation`, `artifact` | fresh cache with missing Odin/CC still runs successfully |
| Native source packaging and compiled shipments | patched `extra_files`/`exclude_files`; standard shipment export | source archive inclusion/exclusion and `.so` shipment checks |

## Release gates

- [x] Scaffold a native addition function and call it from Gleam.
- [x] Edit only Odin and observe updated behavior through ordinary `gleam test`.
- [x] Confirm unchanged builds reuse artifacts and preserve generated file mtimes.
- [x] Recover from an invalid native interface; reject unsupported types at their source location.
- [x] Track compiler-reported imported Odin dependencies.
- [x] Exercise malformed inputs and ownership-sensitive behavior in isolated BEAM VMs.
- [x] Retain a resource across two native library versions and purge the old code.
- [x] Migrate private state through an explicit upgrade callback.
- [x] Exercise monitor cancellation, actual I/O readiness/stop, dynamic resource calls and yielding.
- [x] Include native sources/hooks in a Hex archive and native libraries in a production shipment.
- [ ] Complete the remaining behavioral coverage identified above.
- [ ] Run and pass the complete macOS/Linux × arm64/x64 × OTP 27/28/29 CI matrix.
- [ ] Finish operation-by-operation certification beyond the [source API mapping](rustler-api.md) before claiming full parity.
- [ ] Obtain an accepted upstream build integration, or explicitly release with the pinned compiler requirement.

## Deliberate substitutions and exclusions

Rust proc macros become Odin annotations and a generator. Rust trait extension
points become explicit codec callbacks. Gleam custom types replace Elixir
structs/exceptions. The optional core big-integer adapter replaces Rust's
num-bigint dependency. Literal Serde integration, Rust ownership enforcement,
and Rust panic unwinding are outside the contract. Automatic binary downloads
are deferred; explicitly supplied libraries are supported.
