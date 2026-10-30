# Rustler 0.39.0 source API mapping

Reference: the `rustler-0.39.0` tag of
[rusterlium/rustler](https://github.com/rusterlium/rustler/tree/rustler-0.39.0).
The downloaded source archive used for this review has SHA-256
`5a3ca1491bfc83df72688fe07d164d585c8f1b3149b47a2d5c59015ea0ea179e`.

This maps public operation groups to the implementation and its behavioral
tests. It is a source review, not a claim of exhaustive operation/platform
certification. See [the release gates](parity.html).

| Rustler source / public operations | Glodin counterpart | Verification |
| --- | --- | --- |
| `rustler_codegen`: `nif`, `init`, `Nif` registration | `@(glodin_nif)`, generated C/Odin entry points and loader | scaffold; zero-argument/void functions; grouped environments; export rename/removal |
| `NifTuple`, `NifMap`, `NifRecord` | `glodin_codec` representations and `glodin_tag` | tuple, map and record conformance |
| `NifUnitEnum`, `NifTaggedEnum`, `NifUntaggedEnum` | enum/union derivation | all three wire representations; invalid tags and alternatives |
| `NifStruct`, `NifException` | generated Gleam custom types; `Result`, `Error` | Gleam constructors and explicit exception; Elixir struct metadata is replaced |
| `Encoder`, `Decoder` | `encode`, `try_encode`, `decode`, `register_codec`, `Codec` | native/Gleam round trips; `Positive` custom codec |
| `Env` construction and raw C access | explicit `^Env`, `glodin:sys` | injected environments and C shim |
| `Env.error_tuple`, `Error::Term` | `Result(T,E)`/`Err(E)`, or `tuple` with an `error` atom | both domain-result variants |
| `Env.send`, `whereis_pid` | `send`, `whereis_pid` | delivery, registered-name lookup and missing name |
| `Env.binary_to_term`, trusted decoding | `binary_to_term`, safe by default, explicit `trusted` flag | ETF round trips, malformed input, consumed prefix |
| `OwnedEnv.new/run/save/send_and_clear/clear`; `SavedTerm.load` | `env_new`, ordinary Odin calls with `env.env`, `save`, `send`, `env_clear`, `env_destroy`, `load` | saved nested term copied between environments; worker messages |
| `Term.new/as_c_arg/get_env/in_env/decode` | `Term`, explicit environment parameter, `copy_term`, `decode` | identity/copy and nested decoding |
| `Term.decode_as_binary`, `to_binary` | `binary_from_iolist`, `term_to_binary` | nested iolist and ETF tests |
| `Term.hash_internal/hash_phash2/get_erl_type/size` | `hash_internal`, `hash_phash2`, `term_type`, `term_size` | copied-term hash equality; BEAM `phash2` agreement; OTP 29 size availability |
| `Term` equality, ordering and dynamic predicates | `identical`, `compare`, `Term_Type`; further predicates through `sys.api` | equality/order; numeric raw API predicate |
| Atom construction, existing-atom lookup and string conversion | UTF-8 `atom`, `existing_atom`, `atom_name`; Latin-1 OTP constructors through `sys.api` | UTF-8 atom round trip and existing lookup; Latin-1 helper path is not separately tested |
| `Truthy` | explicit `truthy`; ordinary `bool` codec remains strict | false/nil rejection and integer truthiness |
| Primitive integers, floats, booleans, strings | checked Odin primitive codecs | signed/unsigned bounds; 128-bit values; malformed UTF-8 and wrong types |
| `BigInt` | `Big_Int`; optional `glodin:bigint` adapter | 1024-bit positive/negative arithmetic and round trips |
| Rust `Option`, `ErlOption` | Gleam `Option(T)` as `none`/`{some,T}`; alternate Erlang representations through codec registration | both Gleam variants; `nil`/`undefined` compatibility is an explicit codec choice |
| Rust `Result` | Gleam-compatible `Result(T,E)` | `ok` and `error` tuples from both languages |
| Tuple construction and extraction | `tuple`, `tuple_elements`; tuple codec | tuple shape/tag validation |
| List creation, cells, length, reverse, prepend, iterator | `list_new`, `list_cell`, `list_length`, `list_reverse`, `list_prepend`, `List_Iterator` | empty/proper/improper lists; reverse and iterator |
| Map construction from arrays/pairs, get/size/put/remove/update | `map_from_arrays`, `map_get`, `map_size`, `map_put`, `map_remove`, `map_update`; native maps and codecs | mutations, missing update key and mismatched arrays |
| Double-ended `MapIterator` | `Map_Iterator`, `map_next`, `map_previous`, `map_iterator_destroy` | mixed traversal consumes each entry once |
| `Binary`, iolist decoding, sub-binaries | call-scoped `Binary`, `binary_from_iolist`, checked `binary_sub` | arbitrary bytes, nested iolists, invalid values and slicing bounds |
| `OwnedBinary`, `NewBinary`, copy/reallocate/release | `Owned_Binary`, `New_Binary`, `binary_from_slice`, `binary_new/data/resize/release/destroy` | resize zeroing, transfer and returned bytes |
| `LocalPid`, self, liveness; `Reference` | `Pid`, `self`, `is_process_alive`, `Reference`, `make_reference`, `copy_term` | process lookup/liveness, self and reference identity |
| `Resource`, `Registration`, `resource_impl` | `@(glodin_resource)`, automatic registration, `resource_open`, `Resource_Callbacks(T)` | automatic load/upgrade registration and callback configuration |
| `ResourceArc.new/clone`, term conversion and destruction | `resource_new`, `resource_keep`, `resource_release`, generated codec, destructor callback | native retained reference; shared BEAM resource; destruction notification |
| Resource-backed binary | `resource_binary` | bytes remain backed by their resource |
| Resource process monitoring | `monitor`, `demonitor`, `Monitor`, `monitor_destroy`, down callback | exit notification and cancellation |
| Dynamic resource call and callback | `dynamic_resource_call`, `Resource_Callbacks(T).dyncall` | successful dispatch and missing type rejection |
| `EnifAllocator` | `beam_allocator` | alignment, initialization and paired cleanup |
| `SchedulerFlags`, `consume_timeslice`, low-level continuation | `Scheduler`, `consume_timeslice`, `schedule` | normal/dirty calls and yielding continuation |
| `spawn`, thread spawning, scheduler-thread query | `spawn`, `Job`, `job_send`, `is_scheduler_thread`; custom pools can use Odin threading and explicit ownership APIs | worker delivery and thread classification; arbitrary external pools are not certified |
| `Return`, `NifResult`, `Error` variants | `Return`, `Nif_Result(T)`, `Error`, raw `Term`, domain `Result`, `badarg`, `raise` | conversion failure, domain errors and raised BEAM term |
| `sys` NIF APIs and macro interfaces | OTP-generated `sys.api` lookup; ABI-sensitive structures/macros in `priv/c` | C shim, raw predicate, scheduler, resource and I/O tests; every raw function is not individually tested |
| Mix compiler, Rustler configuration and crate scaffolding | stock Gleam wrapper, bundled driver, native JSON and `new` | wrapper builds/tests, cached dependencies, source archives and shipments |
| Serde and Rust-specific traits/lifetimes | explicit codec callbacks and Odin ownership contract | custom codec and ownership suite; Rust enforcement/panic recovery excluded |

Gleam adaptations deliberately preserve Gleam's representations. In particular,
`Float` accepts BEAM floats rather than coercing integers, `Option` has tagged
Gleam variants, and named records use Gleam constructor tags. An Erlang-facing
compatibility format can be registered separately without changing those types.

Remaining certification includes untested raw API operations, optional alternate
wire formats, custom worker pools, target/collection combinations, and all
requested operating-system/architecture/OTP combinations. These are future certification work. Glodin 0.1.0 claims the tested documented
interfaces rather than exhaustive Rustler parity.
