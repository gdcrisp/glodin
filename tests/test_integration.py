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
GLEAM = shutil.which(os.environ.get("GLEAM_BIN", "gleam"))
assert GLEAM, "Gleam must be installed"
STDLIB = ROOT / "build/packages/gleam_stdlib"


def run(cwd, *args, success=True, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env={**os.environ, "GLEAM": GLEAM, **(env or {})}, timeout=180)
    if success and result.returncode:
        raise AssertionError(f"{' '.join(args)} failed:\n{result.stdout}")
    if not success and not result.returncode:
        raise AssertionError(f"Expected failure: {' '.join(args)}\n{result.stdout}")
    return result.stdout


def native_run(cwd, *args, **kwargs):
    return run(cwd, "escript", "glodin_build.escript", *args, **kwargs)


def archive_contents(path, destination=None):
    with tarfile.open(path) as outer:
        contents = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        names = inner.getnames()
        if destination is not None:
            inner.extractall(destination, filter="data")
    return names


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
        first = native_run(self.path, "test")
        self.assertIn("Compiling Odin NIF math", first)
        bindings = self.path / "src/sample/math.gleam"
        before = bindings.stat().st_mtime_ns
        second = native_run(self.path, "test")
        self.assertNotIn("Compiling Odin NIF", second)
        self.assertEqual(before, bindings.stat().st_mtime_ns)
        run(self.path, GLEAM, "check", env={"ODIN": "glodin_missing_odin"})
        self.assertIn("missing executable", native_run(self.path, "build", success=False,
                                                env={"ODIN": "glodin_missing_odin"}))
        native = self.path / "priv/glodin/native/math/lib.odin"
        original = native.read_text()
        native.write_text(original.replace("a + b", "a + b + 1"))
        changed = native_run(self.path, "test", success=False)
        self.assertIn("Compiling Odin NIF math", changed)
        self.assertIn("43", changed)
        self.assertEqual(before, bindings.stat().st_mtime_ns)
        native.write_text(original + '\n@(glodin_nif)\nbroken :: proc(p: ^i64) -> i64 { return p^ }\n')
        failed = native_run(self.path, "build", success=False)
        self.assertRegex(failed, r"lib\.odin:\d+:\d+: glodin: unsupported")
        native.write_text(original)
        native_run(self.path, "test")
        support = self.path / "priv/glodin/support"
        support.mkdir()
        dependency = support / "lib.odin"
        dependency.write_text("package support\nId :: i64\noffset :: proc() -> i64 { return 0 }\n")
        native.write_text(original.replace("@(glodin_nif)", 'import shared "../../support"\n\n@(glodin_nif)', 1)
                          .replace("a + b", "a + b + shared.offset()") +
                          '\n@(glodin_nif)\necho_id :: proc(n: shared.Id) -> shared.Id { return n }\n')
        native_run(self.path, "test")
        dependency.write_text(dependency.read_text().replace("return 0", "return 1"))
        self.assertIn("43", native_run(self.path, "test", success=False))
        dependency.write_text(dependency.read_text().replace("return 1", "return 0"))
        native_run(self.path, "test")

    def test_generated_exports_and_stale_module_cleanup(self):
        self.scaffold()
        native = self.path / "priv/glodin/native/math/lib.odin"
        native.write_text(native.read_text().replace("@(glodin_nif)", '@(glodin_nif, glodin_name="sum")'))
        test = self.path / "test/sample_test.gleam"
        test.write_text(test.read_text().replace("math.add", "math.sum"))
        native_run(self.path, "test")
        self.assertNotIn("fn add(", (self.path / "src/sample/math.gleam").read_text())
        config = self.path / "priv/glodin/native/math/glodin.json"
        values = json.loads(config.read_text())
        values["gleam_module"] = "sample/arithmetic"
        values["module"] = "sample_arithmetic_ffi"
        config.write_text(json.dumps(values))
        test.write_text(test.read_text().replace("sample/math", "sample/arithmetic").replace("math.sum", "arithmetic.sum"))
        native_run(self.path, "test")
        self.assertFalse((self.path / "src/sample/math.gleam").exists())
        self.assertFalse((self.path / "src/sample_math_ffi.erl").exists())

    def test_wrapper_arguments_exit_status_and_clean_bootstrap(self):
        self.scaffold()
        native_run(self.path, "build")
        (self.path / "src/arguments_ffi.erl").write_text(
            '-module(arguments_ffi).\n-export([main/0]).\n'
            'main() -> io:format("~p~n", [init:get_plain_arguments()]), halt(23).\n')
        (self.path / "src/arguments.gleam").write_text(
            '@external(erlang, "arguments_ffi", "main")\npub fn main() -> Nil\n')
        args = ["argument with spaces", "literal$(touch SHOULD_NOT_EXIST)"]
        result = subprocess.run(["escript", "glodin_build.escript", "run", "-m", "arguments", "--", *args],
                                cwd=self.path, text=True, capture_output=True,
                                env={**os.environ, "GLEAM": GLEAM})
        self.assertEqual(23, result.returncode, result.stdout + result.stderr)
        self.assertIn(args[0], result.stdout)
        self.assertIn(args[1], result.stdout)
        self.assertFalse((self.path / "SHOULD_NOT_EXIST").exists())
        shutil.rmtree(self.path / "build")
        shutil.rmtree(self.path / ".glodin")
        native_run(self.path, "test")
        output = native_run(self.path, "build", "--target=javascript", success=False)
        self.assertIn("only the Erlang target", output)

    def test_native_conformance(self):
        target = self.path / "conformance"
        shutil.copytree(ROOT / "examples/conformance", target,
                        ignore=lambda directory, names: [n for n in names if n in ("build", ".glodin", "glodin_generated.odin", "manifest.toml") or (n == "native" and Path(directory).name == "priv")])
        cfg = target / "gleam.toml"
        cfg.write_text(cfg.read_text().replace('path = "../.."', f'path = {json.dumps(str(ROOT))}'))
        if STDLIB.exists():
            cfg.write_text(cfg.read_text().replace('gleam_stdlib = ">= 0.44.0 and < 2.0.0"',
                                                   f'gleam_stdlib = {{ path = {json.dumps(str(STDLIB))} }}'))
        output = native_run(target, "test")
        self.assertIn("Glodin conformance checks passed", output)
        beam = target / "build/dev/erlang/glodin_conformance/ebin/glodin_conformance_checks_ffi.beam"
        old = target / "old.beam"
        shutil.copyfile(beam, old)
        native = target / "priv/glodin/native/checks/lib.odin"
        native.write_text(native.read_text().replace("return n * 2", "return n * 3"))
        module_config = target / "priv/glodin/native/checks/glodin.json"
        settings = json.loads(module_config.read_text())
        settings["load_data"] = 13
        module_config.write_text(json.dumps(settings))
        native_run(target, "build")
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
        native_run(target, "build")
        run(target, "erl", "+S", "2:2", "-noshell", "-pa", *paths, "-eval",
            "29 = glodin_conformance_checks_ffi:load_value(), halt(0).")
        native_run(target, "export", "erlang-shipment")
        shipment = target / "build/erlang-shipment"
        self.assertTrue(list(shipment.rglob("*.so")))
        shipment_paths = [str(p) for p in shipment.rglob("ebin")]
        self.assertTrue(shipment_paths)
        run(shipment, "erl", "+S", "2:2", "-noshell", "-pa", *shipment_paths, "-eval",
            "29 = glodin_conformance_checks_ffi:load_value(), halt(0).")

    def test_source_package_includes_native_inputs(self):
        self.scaffold()
        (self.path / "README.md").write_text("# Source fixture\nNative addition example.\n")
        native_run(self.path, "test")
        binary = next((self.path / "priv/native").glob("sample_math_ffi_*.so"))
        before = binary.read_bytes()
        config = self.path / "gleam.toml"
        original_config = config.read_text()
        config.write_text(original_config.split("[dependencies]")[0])
        (self.path / "manifest.toml").unlink()
        run(self.path, "escript", str(ROOT / "priv/glodin.escript"), "export", "hex-tarball")
        extracted = self.path / "package"
        names = archive_contents(self.path / "build/sample-0.1.0.tar", extracted)
        self.assertIn('-vsn("unbuilt")', (extracted / "src/sample_math_ffi.erl").read_text())
        self.assertIn("priv/glodin/native/math/lib.odin", names)
        self.assertIn("priv/glodin/native/math/glodin.json", names)
        self.assertIn("src/sample/math.gleam", names)
        self.assertFalse(any(n.startswith("priv/native/") or ".dSYM/" in n for n in names))
        self.assertFalse(any(n.startswith(".glodin/") for n in names))
        self.assertEqual(before, binary.read_bytes())
        config.write_text(original_config)
        native_run(self.path, "test")

    def test_source_release_rejects_external_native_sources(self):
        self.scaffold()
        support = self.path / "support"
        support.mkdir()
        (support / "lib.odin").write_text("package support\nvalue :: proc() -> i64 { return 0 }\n")
        native = self.path / "priv/glodin/native/math/lib.odin"
        native.write_text(native.read_text().replace("@(glodin_nif)", 'import s "../../../../support"\n@(glodin_nif)')
                          .replace("a + b", "a + b + s.value()"))
        output = native_run(self.path, "export", "hex-tarball", success=False)
        self.assertIn("must be packaged under priv/", output)

    def test_explicit_binary_needs_no_native_toolchain(self):
        self.scaffold()
        native_run(self.path, "test")
        binary = next((self.path / "priv/native").glob("sample_math_ffi_*.so"))
        prebuilt = self.path / "supplied.so"
        shutil.copyfile(binary, prebuilt)
        config = self.path / "priv/glodin/native/math/glodin.json"
        values = json.loads(config.read_text())
        values.update(skip_compilation=True, artifact="supplied.so")
        config.write_text(json.dumps(values))
        shutil.rmtree(self.path / ".glodin")
        native_run(self.path, "test", env={"ODIN": "glodin_missing_odin", "CC": "glodin_missing_cc"})

    def test_direct_transitive_and_extracted_native_dependencies(self):
        library = self.path / "library"
        package(library, "native_library")
        (library / "README.md").write_text("# Native library\nAn addition library.\n")
        run(library, "escript", str(ROOT / "priv/glodin.escript"), "new", "math")
        # Export a real self-contained Gleam numeric NIF package.
        run(library, "escript", str(ROOT / "priv/glodin.escript"), "export", "hex-tarball")
        extracted = self.path / "extracted"
        archive_contents(library / "build/native_library-0.1.0.tar", extracted)
        middle = self.path / "middle"
        package(middle, "middle")
        (middle / "gleam.toml").write_text((middle / "gleam.toml").read_text() +
            '\n[dependencies]\nnative_library = { path = "../library" }\n')
        (middle / "src/middle.gleam").write_text(
            'import native_library/math\npub fn answer() { math.add(19, 23) }\n')
        app = self.path / "app"
        package(app, "consumer", glodin=True)
        cfg = app / "gleam.toml"
        cfg.write_text(cfg.read_text() + '\nnative_library = { path = "../library" }\n')
        run(app, GLEAM, "run", "-m", "glodin", "--", "init")
        (app / "test").mkdir()
        test = app / "test/consumer_test.gleam"
        test.write_text('import native_library/math\npub fn main() { let assert 42 = math.add(19, 23) }\n')
        native_run(app, "test")
        # Change a dependency with a cached Gleam build and observe a native rebuild.
        source = library / "priv/glodin/native/math/lib.odin"
        original = source.read_text()
        source.write_text(original.replace("a + b", "a + b + 1"))
        self.assertIn("43", native_run(app, "test", success=False))
        source.write_text(original)
        # Root now reaches the native library only through another package.
        cfg.write_text(cfg.read_text().replace('native_library = { path = "../library" }',
                                               'middle = { path = "../middle" }'))
        test.write_text('import middle\npub fn main() { let assert 42 = middle.answer() }\n')
        native_run(app, "test")
        # Replace the source library with the exact contents exported for Hex.
        mcfg = middle / "gleam.toml"
        mcfg.write_text(mcfg.read_text().replace('../library', '../extracted'))
        shutil.rmtree(app / "build")
        native_run(app, "test")
        shipment_output = native_run(app, "export", "erlang-shipment")
        shipment = app / "build/erlang-shipment"
        self.assertTrue(list(shipment.rglob("native_library_math_ffi_*.so")), shipment_output)
        paths = [str(p) for p in shipment.rglob("ebin")]
        run(shipment, "erl", "+S", "2:2", "-noshell", "-pa", *paths, "-eval",
            '42 = middle:answer(), halt(0).')

    def test_glodin_archive_documentation_and_fresh_consumer(self):
        # Exercise the package bytes, not the source checkout, including docs sources.
        run(ROOT, "escript", "priv/glodin.escript", "export", "hex-tarball")
        extracted = self.path / "toolkit"
        names = archive_contents(ROOT / "build/glodin-0.1.0.tar", extracted)
        self.assertIn("LICENSE", names)
        self.assertIn("priv/docs/workflow.md", names)
        self.assertIn("priv/odin/generator/main.odin", names)
        self.assertFalse(any(n.endswith((".so", ".o", ".beam")) or ".dSYM/" in n for n in names))
        run(extracted, GLEAM, "docs", "build")
        app = self.path / "app"
        package(app, "archive_consumer")
        cfg = app / "gleam.toml"
        cfg.write_text(cfg.read_text() + f'\n[dependencies]\nglodin = {{ path = {json.dumps(str(extracted))} }}\n')
        run(app, GLEAM, "run", "-m", "glodin", "--", "new", "math")
        (app / "test").mkdir()
        (app / "test/archive_consumer_test.gleam").write_text(
            'import archive_consumer/math\npub fn main() { let assert 42 = math.add(19, 23) }\n')
        native_run(app, "test")

    def test_multiple_modules_preserve_existing_build_configuration(self):
        package(self.path, "merge_fixture", glodin=True)
        config = self.path / "gleam.toml"
        config.write_text(config.read_text() + '''
[erlang]
extra_applications = ["crypto"] # keep this comment

[tools.example]
build_hooks = ["unrelated configuration"]
''')
        original = config.read_text()
        run(self.path, GLEAM, "run", "-m", "glodin", "--", "new", "math")
        run(self.path, "escript", "glodin_build.escript", "new", "extra")
        self.assertEqual(original, config.read_text())
        (self.path / "test").mkdir()
        (self.path / "test/merge_fixture_test.gleam").write_text(
            'import merge_fixture/math\nimport merge_fixture/extra\npub fn main() {\n'
            '  let assert 42 = math.add(19,23)\n  let assert 5 = extra.add(2,3)\n}\n')
        native_run(self.path, "test")


if __name__ == "__main__":
    unittest.main(verbosity=2)
