"""End-to-end checks against the actual Odin compiler and isolated BEAM VMs."""
from pathlib import Path
import json
import io
import os
import shutil
import subprocess
import tempfile
import tarfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
GLEAM = str(Path(os.environ.get("GLEAM_BIN", ROOT / ".tools/bin/gleam")).resolve())
STDLIB = ROOT / "build/packages/gleam_stdlib"


def run(cwd, *args, success=True, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env={**os.environ, **(env or {})}, timeout=180)
    if success and result.returncode:
        raise AssertionError(f"{' '.join(args)} failed:\n{result.stdout}")
    if not success and not result.returncode:
        raise AssertionError(f"Expected failure: {' '.join(args)}\n{result.stdout}")
    return result.stdout


def package(path, name, glodin=False):
    (path / "src").mkdir(parents=True)
    toml = f'name = "{name}"\nversion = "0.1.0"\ntarget = "erlang"\nlicences = ["MIT"]\ndescription = "Integration fixture"\n'
    if glodin:
        toml += f'\n[dependencies]\nglodin = {{ path = {json.dumps(str(ROOT))} }}\n'
        if STDLIB.exists():
            toml += f'gleam_stdlib = {{ path = {json.dumps(str(STDLIB))} }}\n'
    (path / "gleam.toml").write_text(toml)


class Integration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glodin integration ")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name).resolve()

    def scaffold(self):
        package(self.path, "sample", glodin=True)
        run(self.path, GLEAM, "run", "-m", "glodin", "--", "new", "math")
        (self.path / "test").mkdir()
        (self.path / "test/sample_test.gleam").write_text(
            'import sample/math\npub fn main() { let assert 42 = math.add(19, 23) }\n')

    def test_scaffold_incremental_and_failed_build_recovery(self):
        self.scaffold()
        first = run(self.path, GLEAM, "test")
        self.assertIn("Compiling Odin NIF math", first)
        bindings = self.path / "src/sample/math.gleam"
        before = bindings.stat().st_mtime_ns
        second = run(self.path, GLEAM, "test")
        self.assertNotIn("Compiling Odin NIF", second)
        self.assertEqual(before, bindings.stat().st_mtime_ns)
        run(self.path, GLEAM, "check", env={"ODIN": "glodin_missing_odin"})
        self.assertIn("missing executable", run(self.path, GLEAM, "build", success=False,
                                                env={"ODIN": "glodin_missing_odin"}))
        native = self.path / "native/math/lib.odin"
        original = native.read_text()
        native.write_text(original.replace("a + b", "a + b + 1"))
        changed = run(self.path, GLEAM, "test", success=False)
        self.assertIn("Compiling Odin NIF math", changed)
        self.assertIn("43", changed)
        self.assertEqual(before, bindings.stat().st_mtime_ns)
        native.write_text(original + '\n@(glodin_nif)\nbroken :: proc(p: ^i64) -> i64 { return p^ }\n')
        failed = run(self.path, GLEAM, "build", success=False)
        self.assertRegex(failed, r"lib\.odin:\d+:\d+: glodin: unsupported")
        native.write_text(original)
        run(self.path, GLEAM, "test")
        support = self.path / "support"
        support.mkdir()
        dependency = support / "lib.odin"
        dependency.write_text("package support\nId :: i64\noffset :: proc() -> i64 { return 0 }\n")
        native.write_text(original.replace("@(glodin_nif)", 'import shared "../../support"\n\n@(glodin_nif)', 1)
                          .replace("a + b", "a + b + shared.offset()") +
                          '\n@(glodin_nif)\necho_id :: proc(n: shared.Id) -> shared.Id { return n }\n')
        run(self.path, GLEAM, "test")
        dependency.write_text(dependency.read_text().replace("return 0", "return 1"))
        self.assertIn("43", run(self.path, GLEAM, "test", success=False))
        dependency.write_text(dependency.read_text().replace("return 1", "return 0"))
        run(self.path, GLEAM, "test")

    def test_generated_exports_and_stale_module_cleanup(self):
        self.scaffold()
        native = self.path / "native/math/lib.odin"
        native.write_text(native.read_text().replace("@(glodin_nif)", '@(glodin_nif, glodin_name="sum")'))
        test = self.path / "test/sample_test.gleam"
        test.write_text(test.read_text().replace("math.add", "math.sum"))
        run(self.path, GLEAM, "test")
        self.assertNotIn("fn add(", (self.path / "src/sample/math.gleam").read_text())
        config = self.path / "native/math/glodin.json"
        values = json.loads(config.read_text())
        values["gleam_module"] = "sample/arithmetic"
        values["module"] = "sample_arithmetic_ffi"
        config.write_text(json.dumps(values))
        test.write_text(test.read_text().replace("sample/math", "sample/arithmetic").replace("math.sum", "arithmetic.sum"))
        run(self.path, GLEAM, "test")
        self.assertFalse((self.path / "src/sample/math.gleam").exists())
        self.assertFalse((self.path / "src/sample_math_ffi.erl").exists())

    def test_hook_order_cache_environment_arguments_and_check(self):
        dep = self.path / "dependency"
        package(dep, "hook_dependency")
        (dep / "src/hook_dependency.gleam").write_text("pub fn value() { 42 }\n")
        package(self.path, "hook_root")
        (self.path / "src/hook_root.gleam").write_text("import hook_dependency\npub fn main() { hook_dependency.value() }\n")
        config = self.path / "gleam.toml"
        config.write_text(config.read_text() + '\n[dependencies]\nhook_dependency = { path = "dependency" }\n')
        hook = '''import json, os, pathlib, sys
p = pathlib.Path("hook_calls.json")
calls = json.loads(p.read_text()) if p.exists() else []
calls.append({"cwd":os.getcwd(),"argv":sys.argv[1:],"env":{k:v for k,v in os.environ.items() if k.startswith("GLEAM_")}})
p.write_text(json.dumps(calls))
'''
        arguments = ["python3", "hook.py", "argument with spaces", "literal$(touch SHOULD_NOT_EXIST)"]
        for p in (self.path, dep):
            (p / "hook.py").write_text(hook)
            cfg = p / "gleam.toml"
            cfg.write_text(cfg.read_text() + "\n[erlang]\nbuild_hooks = [" + json.dumps(arguments) + "]\n")
        run(self.path, GLEAM, "build")
        run(self.path, GLEAM, "build")
        for p in (self.path, dep):
            calls = json.loads((p / "hook_calls.json").read_text())
            self.assertEqual(2, len(calls))
            self.assertEqual(str(p), calls[0]["cwd"])
            self.assertEqual(arguments[2:], calls[0]["argv"])
            self.assertEqual(str(self.path), calls[0]["env"]["GLEAM_PROJECT_ROOT"])
            self.assertFalse((p / "SHOULD_NOT_EXIST").exists())
        run(self.path, GLEAM, "check")
        for p in (self.path, dep):
            self.assertEqual(2, len(json.loads((p / "hook_calls.json").read_text())))
        (self.path / "hook.py").write_text("raise SystemExit(23)\n")
        self.assertIn("Shell command failure", run(self.path, GLEAM, "build", success=False))

    def test_native_conformance(self):
        target = self.path / "conformance"
        shutil.copytree(ROOT / "examples/conformance", target,
                        ignore=shutil.ignore_patterns("build", ".glodin", "priv", "glodin_generated.odin", "manifest.toml"))
        cfg = target / "gleam.toml"
        cfg.write_text(cfg.read_text().replace('path = "../.."', f'path = {json.dumps(str(ROOT))}'))
        if STDLIB.exists():
            cfg.write_text(cfg.read_text().replace('gleam_stdlib = ">= 0.44.0 and < 2.0.0"',
                                                   f'gleam_stdlib = {{ path = {json.dumps(str(STDLIB))} }}'))
        output = run(target, GLEAM, "test")
        self.assertIn("Glodin conformance checks passed", output)
        beam = target / "build/dev/erlang/glodin_conformance/ebin/glodin_conformance_checks_ffi.beam"
        old = target / "old.beam"
        shutil.copyfile(beam, old)
        native = target / "native/checks/lib.odin"
        native.write_text(native.read_text().replace("return n * 2", "return n * 3"))
        module_config = target / "native/checks/glodin.json"
        settings = json.loads(module_config.read_text())
        settings["load_data"] = 13
        module_config.write_text(json.dumps(settings))
        run(target, GLEAM, "build")
        expression = f'''
          N = glodin_conformance_checks_ffi,
          {{ok, Old}} = file:read_file({json.dumps(str(old))}),
          {{ok, New}} = file:read_file({json.dumps(str(beam))}),
          {{module,N}} = code:load_binary(N,"version1",Old),
          14 = N:renamed(7),
          11 = N:private_increment(11),
          Auto = N:auto_new(17),
          R = N:counter_new(8),
          9 = N:counter_increment(R),
          true = N:background(self(),21),
          receive 42 -> ok after 5000 -> error(old_job_timeout) end,
          {{module,N}} = code:load_binary(N,"version2",New),
          21 = N:renamed(7),
          24 = N:load_value(),
          17 = N:auto_read(Auto),
          19 = N:auto_read(N:auto_new(19)),
          9 = N:counter_read(R),
          true = code:soft_purge(N),
          10 = N:counter_increment(R),
          halt(0).
        '''
        paths = [str(p) for p in (target / "build/dev/erlang").glob("*/ebin")]
        run(target, "erl", "+S", "2:2", "-noshell", "-pa", *paths, "-eval", expression)
        settings.pop("load_data")
        settings["load_data_fun"] = ["glodin_conformance_assertions", "load_data"]
        module_config.write_text(json.dumps(settings))
        run(target, GLEAM, "build")
        run(target, "erl", "+S", "2:2", "-noshell", "-pa", *paths, "-eval",
            "29 = glodin_conformance_checks_ffi:load_value(), halt(0).")
        run(target, GLEAM, "export", "erlang-shipment")
        shipment = target / "build/erlang-shipment"
        self.assertTrue(list(shipment.rglob("*.so")))
        shipment_paths = [str(p) for p in shipment.rglob("ebin")]
        self.assertTrue(shipment_paths)
        run(shipment, "erl", "+S", "2:2", "-noshell", "-pa", *shipment_paths, "-eval",
            "29 = glodin_conformance_checks_ffi:load_value(), halt(0).")

    def test_source_package_includes_native_inputs(self):
        package(self.path, "source_fixture")
        (self.path / "src/source_fixture.gleam").write_text("pub fn main() { Nil }\n")
        (self.path / "native/checks").mkdir(parents=True)
        (self.path / "native/checks/lib.odin").write_text("package checks\n")
        (self.path / "glodin_build.escript").write_text("source hook sentinel\n")
        (self.path / "priv/native").mkdir(parents=True)
        (self.path / "priv/native/host.so").write_text("must not ship in the source package\n")
        config = self.path / "gleam.toml"
        config.write_text(config.read_text() + '\n[erlang]\nextra_files = ["native", "glodin_build.escript"]\nexclude_files = ["priv/native"]\n')
        run(self.path, GLEAM, "export", "hex-tarball")
        tarball = next((self.path / "build").rglob("source_fixture-0.1.0.tar"))
        with tarfile.open(tarball) as outer:
            contents = outer.extractfile("contents.tar.gz").read()
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
            names = inner.getnames()
        self.assertIn("native/checks/lib.odin", names)
        self.assertIn("glodin_build.escript", names)
        self.assertNotIn("priv/native/host.so", names)

    def test_explicit_binary_needs_no_native_toolchain(self):
        self.scaffold()
        run(self.path, GLEAM, "test")
        binary = next((self.path / "priv/native").glob("sample_math_ffi_*.so"))
        prebuilt = self.path / "supplied.so"
        shutil.copyfile(binary, prebuilt)
        config = self.path / "native/math/glodin.json"
        values = json.loads(config.read_text())
        values.update(skip_compilation=True, artifact="supplied.so")
        config.write_text(json.dumps(values))
        shutil.rmtree(self.path / ".glodin")
        run(self.path, GLEAM, "test", env={"ODIN": "glodin_missing_odin", "CC": "glodin_missing_cc"})

    def test_multiple_modules_preserve_existing_build_configuration(self):
        package(self.path, "merge_fixture", glodin=True)
        config = self.path / "gleam.toml"
        config.write_text(config.read_text() + '''
[erlang]
extra_applications = ["crypto"]
build_hooks = [
  ["python3", "existing_hook.py", "literal ] #"], # keep this comment
]
extra_files = ["support", # existing source files
]
exclude_files = ["other"]

[tools.example]
build_hooks = ["unrelated configuration"]
''')
        (self.path / "existing_hook.py").write_text('from pathlib import Path\nPath("existing_hook_ran").write_text("ok")\n')
        run(self.path, GLEAM, "run", "-m", "glodin", "--", "new", "math")
        once = config.read_text()
        self.assertIn("# keep this comment", once)
        self.assertIn('build_hooks = ["unrelated configuration"]', once)
        run(self.path, GLEAM, "run", "-m", "glodin", "--", "new", "extra")
        self.assertEqual(once, config.read_text())
        (self.path / "test").mkdir()
        (self.path / "test/merge_fixture_test.gleam").write_text(
            'import merge_fixture/math\nimport merge_fixture/extra\npub fn main() {\n'
            '  let assert 42 = math.add(19,23)\n  let assert 5 = extra.add(2,3)\n}\n')
        run(self.path, GLEAM, "test")
        self.assertTrue((self.path / "existing_hook_ran").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
