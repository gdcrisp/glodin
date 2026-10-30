//// Glodin's CLI bootstrap for typed Odin NIFs on Erlang.
////
//// Run `gleam run -m glodin -- new math` to scaffold a module, or `init`
//// to install the wrapper when consuming native libraries. Then use
//// `escript glodin_build.escript build`, `run`, or `test` so native code
//// is built before Gleam compiles the application.

/// Execute Glodin with the command-line arguments after `--`.
///
/// Requires Erlang/OTP. Native generation requires Odin; native compilation
/// also requires a C compiler and OTP NIF headers. See the workflow guide
/// for commands, packaging and toolchain requirements.
@external(erlang, "glodin_cli", "main")
pub fn main() -> Nil
