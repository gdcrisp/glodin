# Glodin

Write Odin NIFs and call them as typed Gleam functions on Erlang. Glodin follows
Rustler's workflow: scaffold a native module, annotate ordinary native functions,
and let the normal language build command compile and load the NIF.

**Development status:** the local workflow and conformance suite work. This is
not a released or certified full-parity replacement. The platform matrix and the
remaining verification gates in [the parity checklist](docs/parity.md) must pass
before a release.

## Toolchain

- Odin **dev-2026-07a** (`819fdc7a8`), including its bundled core packages.
- Erlang/OTP 27, 28, or 29, with NIF development headers, and a C11 compiler.
- The bundled patch of Gleam **1.19.1**. Stock Gleam does not execute these build
  hooks. Python 3 and Rust are required to build the patched compiler and run
  repository tests; they are not required by Glodin-powered applications.

Build the compiler once, then put it on your path:

```sh
make compiler
export PATH="$PWD/.tools/bin:$PATH"
```

The build script verifies the upstream source archive's SHA-256. The contribution
is kept in [scripts/patch_gleam.py](scripts/patch_gleam.py) and as an apply-ready
patch under [patches](patches/). It has not been submitted or accepted upstream.

## A native module

Until Glodin is published, add it to your project's `gleam.toml` as a local
dependency:

```toml
[dependencies]
glodin = { path = "/absolute/path/to/glodin" }
```

Then scaffold a module:

```sh
gleam run -m glodin -- new math
```

Edit `native/math/lib.odin`:

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

Use ordinary `gleam build`, `gleam run`, and `gleam test`. Editing only Odin code
invalidates the native build. `gleam check` and language-server analysis use the
existing generated declarations and never run native build hooks. Regenerate
declarations explicitly with `gleam run -m glodin -- generate` when needed.

The scaffold configures source-package inclusion for `native/` and the hook
script, and excludes host binaries from Hex source packages. Add any additional
native support directories to `erlang.extra_files`. `gleam export erlang-shipment`
includes the compiled library in the owning application's `priv` directory.

See [examples/math](examples/math) for the minimal application and
[examples/conformance](examples/conformance) for codecs, resources, jobs, and
custom conversion examples.

The [Rustler source API mapping](docs/rustler-api.md) records the corresponding
operations, Gleam adaptations, tests, and remaining certification work.

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
[the ownership guide](docs/ownership.md). Resources in exported signatures, or
marked `@(glodin_resource)`, are registered automatically. Load callbacks can
configure their destructors, monitor callbacks, and I/O stop callbacks.

## Module configuration

Each `native/<name>/glodin.json` describes one module. The scaffold creates the
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
  "collections": {"shared": "native/shared"},
  "watch": ["include"],
  "load_data": 0
}
```

`ODIN` and `CC` supply default compiler paths. Without `mode`, Gleam's development
build uses debug information and production uses speed optimization. `target`
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
interfaces, incremental rebuilds, dependency hooks, failed-build recovery,
resources, monitoring, destructor calls, jobs, upgrades, source packages, supplied
libraries, and production shipments. CI defines macOS/Linux on arm64/x64 with
OTP 27–29. Local validation alone does not certify that matrix.

Odin can corrupt memory or panic inside a NIF and terminate the VM. See the
[ownership contract](docs/ownership.md) before keeping terms or data beyond a
call. Glodin does not provide Rust's borrow checker or panic unwinding.
