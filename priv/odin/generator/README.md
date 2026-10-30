# Glodin code generation

Glodin's generator is an Odin program bundled with the library. The build hook
compiles it when its sources change; `gleam run -m glodin -- generate` runs it
without compiling the NIF. It has no third-party codegen dependency.

The pipeline has three steps:

1. `parser.odin` collects native declarations and Glodin attributes using Odin's
   parser. `types.odin` resolves supported interface types and codec metadata.
2. `resolve.odin` creates a `codegen.Interface`. It flattens grouped parameters,
   distinguishes injected environments from BEAM arguments, computes wire arity,
   checks duplicate exports, and resolves result types. Odin `Ada_Case` names
   become Gleam `UpperCamelCase` names while wire tags retain their snake case.
3. The `codegen` package renders Gleam bindings, Odin wrappers, the Erlang loader,
   and C registration independently. `emit.odin` writes changed files after all
   outputs have been rendered. Validation failures leave existing output intact.

`codegen/model.odin` is the contract between resolution and rendering. It models
functions, parameters, type declarations, constructors, imports, resource types,
codec registrations, and lifecycle callbacks. Emitters do not access parser
nodes, resolve types, or read or write files. Type references remain resolved
language-specific strings; this is a Glodin interface model, not a general
purpose compiler or a replacement for Gleam's type checker.

When adding a supported type, update resolution and use the existing declaration
forms (`External`, `Alias`, `Tuple`, `Custom`) where possible. When adding a new
declaration form, extend the model and the exhaustive emitter switch. Scheduler
and codec choices are enums, parsed from attributes at the source boundary.

The generator owns one arena for its invocation. Parser data, interface slices,
and rendered strings remain alive until the outputs have been written. The
standalone codegen emitters allocate returned source with `context.allocator`;
callers must retain the interface's allocator while rendering it.

Run `make check` and `make test`. The codegen regressions compile generated source
and exercise grouped environment parameters, zero-argument and void functions,
type and constructor naming, nested imports, schedulers, and validation failures
that must preserve all four outputs.
