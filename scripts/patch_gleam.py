#!/usr/bin/env python3
"""Apply the pinned Glodin build-hook contribution to pristine Gleam 1.19.1."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
config = root / "compiler-core/src/config.rs"
source = config.read_text()
needle = "pub struct ErlangConfig {\n"
assert needle in source and "pub build_hooks:" not in source
source = source.replace(".map_or_default(|suggestion|", ".map_or_else(String::new, |suggestion|")
source = source.replace(needle, needle + '''    /// Commands executed before Erlang package module discovery.
    /// Arguments are passed directly, without shell evaluation.
    #[serde(default)]
    pub build_hooks: Vec<Vec<String>>,
    /// Additional project-relative files or directories included in Hex packages.
    #[serde(default)]
    pub extra_files: Vec<Utf8PathBuf>,
    /// Project-relative paths excluded from Hex packages, including directory contents.
    #[serde(default)]
    pub exclude_files: Vec<Utf8PathBuf>,
''', 1)
config.write_text(source)

compiler = root / "compiler-core/src/build/project_compiler.rs"
source = compiler.read_text()
needle = "        let mut compiler = PackageCompiler::new(\n"
assert source.count(needle) == 1
source = source.replace(needle, '''        if let Err(error) = self.run_build_hooks(config, is_root, &root_path, &out_path) {
            return Outcome::TotalFailure(error);
        }

''' + needle)
needle = "    fn compile_gleam_package(\n"
source = source.replace(needle, '''    fn run_build_hooks(
        &self,
        config: &PackageConfig,
        is_root: bool,
        source: &Utf8Path,
        output: &Utf8Path,
    ) -> Result<()> {
        // Checking and LSP analysis must not execute package build programs.
        if self.target() != Target::Erlang
            || self.options.codegen != Codegen::All
            || self.options.compile == Compile::DepsOnly && is_root
        {
            return Ok(());
        }
        for command in &config.erlang.build_hooks {
            let Some((program, args)) = command.split_first() else {
                return Err(Error::ShellCommand {
                    program: "empty Erlang build hook".into(),
                    reason: ShellCommandFailureReason::Unknown,
                });
            };
            let env = vec![
                ("GLEAM_PROJECT_ROOT".into(), self.io.canonicalise(self.paths.root())?.to_string()),
                ("GLEAM_PACKAGE_ROOT".into(), self.io.canonicalise(source)?.to_string()),
                ("GLEAM_PACKAGE_BUILD".into(), output.to_string()),
                ("GLEAM_PACKAGE_NAME".into(), config.name.to_string()),
                ("GLEAM_BUILD_MODE".into(), self.mode().to_string()),
                ("GLEAM_BUILD_TARGET".into(), "erlang".into()),
                ("GLEAM_BUILD_HOOK".into(), "1".into()),
            ];
            let status = self.io.exec(Command {
                program: program.clone(),
                args: args.to_vec(),
                env,
                cwd: Some(source.to_path_buf()),
                stdio: self.subprocess_stdio,
            })?;
            if status != 0 {
                return Err(Error::ShellCommand {
                    program: program.clone(),
                    reason: ShellCommandFailureReason::Unknown,
                });
            }
        }
        Ok(())
    }

''' + needle)
compiler.write_text(source)

tests = root / "compiler-cli/src/dependencies/tests.rs"
source = tests.read_text().replace("erlang: ErlangConfig {\n", "erlang: ErlangConfig {\n            build_hooks: vec![],\n            extra_files: vec![],\n            exclude_files: vec![],\n")
tests.write_text(source)

publish = root / "compiler-cli/src/publish.rs"
source = publish.read_text()
source = source.replace('    let src_files = project_files(Utf8Path::new(""))?;', '''    let mut src_files = project_files(Utf8Path::new(""))?;
    for path in &config.erlang.extra_files {
        if path.is_dir() {
            src_files.extend(fs::priv_directory_files(path));
        } else {
            src_files.push(path.clone());
        }
    }
    src_files.retain(|path| !config.erlang.exclude_files.iter().any(|excluded| path.starts_with(excluded)));
    src_files.sort();
    src_files.dedup();''', 1)
publish.write_text(source)
