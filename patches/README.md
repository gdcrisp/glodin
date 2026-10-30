# Gleam 1.19.1 integration

`gleam-1.19.1-glodin.patch` is an apply-ready contribution against the verified
v1.19.1 source archive. `scripts/patch_gleam.py` generates the same changes for the
compiler build script. No upstream submission has been made.

The extension adds three opt-in `erlang` configuration fields:

```toml
[erlang]
build_hooks = [["escript", "glodin_build.escript", "build", "--hook"]]
extra_files = ["native", "glodin_build.escript"]
exclude_files = ["priv/native"]
```

Each hook is an executable plus an argument vector, invoked without a shell.
Its working directory is the package's source directory. The hook runs before
module discovery on Erlang builds, runs, tests, and production exports. Cached
Gleam dependencies run their hooks too. Checking, documentation analysis, and
LSP analysis do not run hooks. Failures stop the command.

Hook environment:

| Variable | Meaning |
| --- | --- |
| `GLEAM_PROJECT_ROOT` | Absolute consuming project root |
| `GLEAM_PACKAGE_ROOT` | Absolute owning package source root |
| `GLEAM_PACKAGE_BUILD` | Owning package build directory |
| `GLEAM_PACKAGE_NAME` | Owning package name |
| `GLEAM_BUILD_MODE` | Consuming build mode |
| `GLEAM_BUILD_TARGET` | `erlang` |
| `GLEAM_BUILD_HOOK` | `1` |

The publisher includes `extra_files` and omits `exclude_files` before producing
the archive and metadata. Existing archive checks reject files outside the
project root. These options allow source packages to contain native inputs and
hooks while excluding host binaries. Deployable Erlang shipments continue to
include compiled `priv` artifacts.

The patch also replaces one upstream `Option::map_or_default` call with the
equivalent stable `map_or_else`, allowing the pinned source to compile with the
stable Rust toolchain used here.

`tests/test_integration.py` exercises the extension through a real compiler,
including cached dependencies, checking without execution, command arguments
with spaces/shell metacharacters, source archives, and hook failure propagation.
