# Glodin

Write Odin NIFs and call them as typed Gleam functions on Erlang. Glodin follows
a scaffold-and-generate workflow: annotate ordinary native functions and call
statically typed generated Gleam bindings.

Glodin 0.1.0 supports **stock Gleam 1.19.1+**, Erlang/OTP **27–29**,
macOS/Linux on **arm64/x64**, and Odin **dev-2026-07a** (`819fdc7a8`)
with its bundled core packages. Install OTP NIF development headers and a C11
compiler. Python 3 is required only for repository tests. Rust and a custom
Gleam compiler are not required.

This is an initial release of the documented interfaces, not a claim of complete
Rustler parity. See the [capability checklist](https://hexdocs.pm/glodin/parity.html).

## A native module

Add Glodin:

```sh
gleam add glodin@0.1.0
```

Then scaffold a module:

```sh
gleam run -m glodin -- new math
```

Edit `priv/glodin/native/math/lib.odin`:

```odin
package my_app_math

@(glodin_nif)
add :: proc(a, b: i64) -> i64 {
	return a + b
}
```

Glodin generates `src/<your_package>/math.gleam`, an Erlang loader, and the native
adapters. Call the generated function normally:

```gleam
import my_app/math

pub fn main() {
  let assert 42 = math.add(19, 23)
}
```

Build and run with the generated wrapper:

```sh
escript glodin_build.escript build
escript glodin_build.escript run
escript glodin_build.escript test
```

The wrapper builds native dependencies first, then your native modules, then
invokes stock Gleam. Editing only Odin code invalidates the native build.
Plain `gleam build/run/test` does not rebuild NIFs. Use ordinary `gleam check`
and your editor for analysis without native compilation; use
`escript glodin_build.escript generate` to refresh declarations explicitly.

For applications that only consume a native library, add Glodin directly and
run `gleam run -m glodin -- init` once to install the wrapper. Commit the wrapper
and generated declarations/loaders so clean-checkout analysis works.

Publish native sources using `escript glodin_build.escript publish`, which stages
a source-only package without deleting local binaries. Native sources, imports,
collections and watched support files must live under `priv/`. Deploy with
`escript glodin_build.escript export erlang-shipment`, which builds optimized
libraries and includes them in the owning application's `priv` directory.

See the [workflow guide](https://hexdocs.pm/glodin/workflow.html),
[minimal example](https://github.com/gdcrisp/glodin/tree/v0.1.0/examples/math),
[conformance example](https://github.com/gdcrisp/glodin/tree/v0.1.0/examples/conformance),
and [Rustler API mapping](https://hexdocs.pm/glodin/rustler-api.html).

## Native interfaces

```odin
@(glodin_nif, glodin_name="calculate", glodin_schedule="DirtyCpu")
calculate_impl :: proc(input: []i64) -> i64 {
	result: i64
	for n in input {
		result += n
	}
	return result
}
```

Schedulers are `Normal`, `DirtyCpu`, and `DirtyIo`. An optional `^glodin.Env`
parameter, using any import alias, is injected rather than exposed to Gleam.
Concrete exported signatures are required; ambiguous or unsupported interfaces
produce a diagnostic at their Odin source location.

| Odin | Gleam / BEAM |
| --- | --- |
| Signed and unsigned integers through 128 bits | `Int`, with checked native ranges |
| `glodin.Big_Int` | Arbitrary-precision `Int`; optional `glodin:bigint` arithmetic adapter |
| `f32`, `f64`, `bool`, `string` | `Float`, `Bool`, validated UTF-8 `String` |
| `glodin.Binary`, `glodin.Owned_Binary` | `BitArray`; borrowed input and transferred owned output |
| Slices, arrays, dynamic arrays | `List`, with proper-list and element checks |
| `map[K]V` | `gleam/dict.Dict` |
| Named structs, enums, tagged unions | Generated Gleam custom types |
| `glodin.Result(T, E)`, `glodin.Option(T)` | Gleam `Result` and `gleam/option.Option` |
| `glodin.Nif_Result(T)` | A value of `T` or an explicit BEAM exception |
| `glodin.Resource(T)` | Generated opaque resource type |
| `Term`, `Atom`, `Pid`, `Reference` | Opaque types from `glodin/types` |

Use `@(glodin_codec="tuple")` for an untagged tuple struct, `"map"` for an
atom-keyed map, `"record"` for a record tuple, and `"untagged"` for a union of
alternative wire values. `@(glodin_tag="some_tag")` overrides a record/struct
tag. Representations that Gleam cannot construct directly get opaque external
types; expose typed native constructors for them. Tagged union alternatives are
named structs. Enum and constructor names follow Odin's Ada_Case convention.

For a custom codec, annotate the type with `@(glodin_gleam="Int")` or another
Gleam type expression, and register `glodin.Codec{encode=..., decode=...}` during
load. These callbacks receive a type-erased value and must honor the declared
Gleam representation. See `Positive` in the conformance example.

`@(glodin_load)`, `@(glodin_upgrade)`, and `@(glodin_unload)` mark lifecycle
callbacks. Their signatures are demonstrated in the examples and
[the ownership guide](https://hexdocs.pm/glodin/ownership.html). Resources in exported signatures, or
marked `@(glodin_resource)`, are registered automatically. Load callbacks can
configure their destructors, monitor callbacks, and I/O stop callbacks.

## Module configuration

Each `priv/glodin/native/<name>/glodin.json` describes one module. The scaffold creates the
required fields. Optional fields are shown here:

```json
{
  "name": "math",
  "module": "my_app_math_ffi",
  "gleam_module": "my_app/math",
  "otp_app": "my_app",
  "mode": "release",
  "odin": "odin",
  "cc": "cc",
  "odin_flags": [],
  "c_flags": [],
  "collections": {"shared": "priv/glodin/shared"},
  "watch": ["priv/include"],
  "load_data": 0
}
```

`ODIN` and `CC` supply default compiler paths. Without `mode`, wrapper build/run/test commands use debug information; production shipments
and source-release validation use speed optimization. `target`
sets an Odin target; configure a matching C compiler/flags and OTP headers for
cross compilation. Compiler-reported Odin source dependencies, `#load` files,
OTP headers, toolkit sources, flags, versions, and explicit `watch` paths are
fingerprinted. External native headers and libraries belong in `watch`.

`load_data` accepts a JSON value. Alternatively, `load_data_fun: ["module",
"function"]` calls an Erlang zero-argument function at load time. To use an
explicitly supplied library, set `skip_compilation: true` and `artifact` to its
path. Commit/include its generated Gleam declarations and Erlang loader. If all
modules use supplied libraries, the build needs neither Odin nor a C compiler.
The library must match the platform, OTP ABI, module name, and generated interface.

Native libraries have content-addressed filenames so upgrades load a distinct
library instance. Existing versions are retained for code upgrades. `.glodin/`
contains disposable build metadata and the bootstrapped generator.

## Verification

```sh
make check test
```

The suite launches real BEAM VMs and tests native conversion failures, generated
interfaces, incremental rebuilds, native dependencies, failed-build recovery,
resources, monitoring, destructor calls, jobs, upgrades, source packages, supplied
libraries, and production shipments. The release CI matrix covers macOS/Linux on arm64/x64 with
OTP 27–29. Local validation alone does not certify that matrix.

Odin can corrupt memory or panic inside a NIF and terminate the VM. See the
[ownership contract](https://hexdocs.pm/glodin/ownership.html) before keeping terms or data beyond a
call. Glodin does not provide Rust's borrow checker or panic unwinding.

## License

MIT OR Apache-2.0, at your option. See [LICENSE](https://github.com/gdcrisp/glodin/blob/v0.1.0/LICENSE).
