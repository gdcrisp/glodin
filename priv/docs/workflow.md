# CLI and native dependencies

Glodin 0.1.0 uses stock Gleam 1.19.1 or newer, Erlang/OTP 27–29,
Odin dev-2026-07a (`819fdc7a8`), OTP NIF headers, and a C11 compiler.
Linux/macOS on arm64/x64 are supported. Windows, certified cross-compilation,
and downloading or publishing prebuilt native packages are outside this release.

## Bootstrap

```sh
gleam add glodin@0.1.0
gleam run -m glodin -- new math
```

Edit `priv/glodin/native/math/lib.odin`. Each module has a sibling `glodin.json`.
For a consumer with no native modules of its own, install the wrapper with
`gleam run -m glodin -- init` instead. Subsequent scaffolding can use
`escript glodin_build.escript new extra`, even if the application's generated
bindings are currently stale.

Commit `glodin_build.escript`, native sources/configuration, and generated
Gleam declarations and Erlang loaders. Ignore `.glodin/`, `build/`,
`priv/native/`, `glodin_generated.odin`, and native debug bundles.

## Commands

| Command after `escript glodin_build.escript` | Behavior |
| --- | --- |
| `build` | Build native dependencies and application NIFs, then `gleam build` |
| `run [options] -- [arguments]` | Build NIFs, then forward to `gleam run` |
| `test [options] -- [arguments]` | Build NIFs, then forward to `gleam test` |
| `generate` | Refresh declarations and adapters without compiling libraries |
| `doctor` | Print compiler versions, OTP version and NIF header location |
| `export erlang-shipment` | Build optimized NIFs and a production Erlang shipment |
| `export hex-tarball` | Validate and export a source-only Hex archive |
| `publish [--yes]` | Validate, stage and publish sources plus HexDocs |
| `init` | Install/update the local wrapper |
| `new MODULE` | Scaffold a new native module and refresh declarations |

Build/run/test options and arguments are passed as argument vectors without a
shell. Output is streamed and the child exit status is preserved. Programs that
require interactive stdin are not supported by the escript port wrapper; build
first, then use plain `gleam run` for an interactive program.

`GLEAM`, `ODIN`, and `CC` select executable paths. The native module configuration
can override Odin/C compiler settings. Application commands use debug NIF builds;
shipments and source-release validation use optimized builds unless a module
explicitly sets its mode. The target is Erlang only.

Plain `gleam check` and editor analysis never build native code. Plain
`gleam build`, `gleam run`, and `gleam test` do not update NIFs. Run the wrapper
after native edits. `generate` requires Odin, but does not require the C compiler.

## Source dependencies

Add the native library and Glodin as dependencies, run `init`, and use the wrapper.
It downloads dependencies and reads package configuration through Gleam's JSON
package-information export, then builds reachable native dependencies before
the application. Local path, Git, and Hex Gleam packages use the same workflow.
Only the root package's development dependencies participate in development
commands; production shipments use production dependencies.

A source package must contain its native modules under `priv/glodin/native/`.
Keep additional Odin imports, `#load` inputs, collections, and watched support
files under `priv/` as well. Odin's bundled core/vendor packages and Glodin's
toolkit are toolchain dependencies and do not need to be copied into your package.
Publish generated declarations/loaders so consumers can check code before a native
build. Every consuming machine needs the native toolchain.

Use the wrapper's `publish` or `export hex-tarball` command for a native package.
Stock Gleam includes **all** files under `priv/`, even ignored binaries. Glodin
stages a source-only copy, rejects symlinks and unpackaged native dependencies,
regenerates declarations/loaders, and excludes native artifacts and caches.
Your working application's binaries are retained. Do not publish a native
package directly with plain `gleam publish` after building NIFs.

Hex packages cannot depend on local paths or unpublished Git packages. Replace
such requirements with published Hex version requirements before release.

## Deployment and supplied local binaries

`export erlang-shipment` includes the built NIFs in their owning OTP applications.
Deploy the complete shipment on the same platform/architecture and a compatible
OTP runtime. Test it outside the source checkout before deployment.

For a local application, `skip_compilation: true` and `artifact` in a module's
configuration select a supplied library. Include its generated declarations and
loader. When all modules use supplied libraries, no Odin/C compiler is needed to
build or run the application. The binary must match the platform, ABI, module,
and interface. Publishing these supplied binaries is not supported in 0.1.0.

Native code runs inside the BEAM VM. Follow the [ownership contract](ownership.html).
