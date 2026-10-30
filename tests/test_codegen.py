"""Exercise the resolved codegen interface through actual Gleam and Odin builds."""
from pathlib import Path
import tempfile
import unittest

import test_integration as integration


class Codegen(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="glodin codegen ")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name).resolve()
        integration.package(self.path, "sample", glodin=True)
        integration.run(self.path, integration.GLEAM, "run", "-m", "glodin", "--", "new", "math")

    def test_resolved_parameters_types_and_imports(self):
        (self.path / "native/math/lib.odin").write_text('''package codegen_checks
import g "glodin:glodin"

Pair_Value :: struct { first, second: i64 }
Choice :: enum { First_Value, Second_Value }
Variant_Value :: struct { x, y: i64 }
Empty_Value :: struct {}
Payload :: union { Variant_Value, Empty_Value }
Container :: struct {
    values: g.Option([]Pair_Value),
    lookup: map[string]i64,
}

@(glodin_nif)
env_order :: proc(a, b: ^g.Env, before: i64, c: ^g.Env, after: i64, d, e: ^g.Env) -> i64 {
    assert(a == b && b == c && c == d && d == e)
    return before + after
}
@(glodin_nif)
ping :: proc() {}
@(glodin_nif)
answer :: proc() -> i64 { return 42 }
@(glodin_nif)
echo_pair :: proc(value: Pair_Value) -> Pair_Value { return value }
@(glodin_nif, glodin_schedule="DirtyCpu")
echo_choice :: proc(value: Choice) -> Choice { return value }
@(glodin_nif, glodin_schedule="DirtyIo")
echo_payload :: proc(value: Payload) -> Payload { return value }
@(glodin_nif)
echo_container :: proc(value: Container) -> Container { return value }
''')
        (self.path / "test").mkdir()
        (self.path / "test/sample_test.gleam").write_text('''import sample/math
import gleam/dict
import gleam/option

pub fn main() {
  let assert 42 = math.env_order(19, 23)
  let assert Nil = math.ping()
  let assert 42 = math.answer()
  let assert math.PairValue(19, 23) = math.echo_pair(math.PairValue(19, 23))
  let assert math.FirstValue = math.echo_choice(math.FirstValue)
  let assert math.SecondValue = math.echo_choice(math.SecondValue)
  let assert math.VariantValue(19, 23) = math.echo_payload(math.VariantValue(19, 23))
  let assert math.EmptyValue = math.echo_payload(math.EmptyValue)
  let value = math.Container(
    option.Some([math.PairValue(19, 23)]),
    dict.from_list([#("answer", 42)]),
  )
  let assert True = math.echo_container(value) == value
}
''')
        integration.run(self.path, integration.GLEAM, "test")

    def test_invalid_interface_preserves_all_outputs(self):
        native = self.path / "native/math/lib.odin"
        original = native.read_text()
        outputs = [
            self.path / "src/sample/math.gleam",
            native.parent / "glodin_generated.odin",
            self.path / ".glodin/math/entry.c",
            self.path / ".glodin/math/loader.erl",
        ]
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in outputs}
        cases = [
            ('@(glodin_nif)\nbad :: proc(value: i64 = 1) -> i64 { return value }',
             "NIF parameters cannot have defaults"),
            ('@(glodin_nif)\nbad :: proc() -> (i64, i64) { return 1, 2 }',
             "use an explicit tuple struct or Result"),
            ('@(glodin_nif, glodin_name="add")\nbad :: proc(a, b: i64) -> i64 { return a + b }',
             "duplicate exported name and arity"),
            ('@(glodin_codec="map")\nBad_Map :: struct { value: ^i64 }\n'
             '@(glodin_nif)\nbad :: proc(value: Bad_Map) -> Bad_Map { return value }',
             "unsupported native interface type"),
            ('@(glodin_codec="untagged")\nBad_Union :: union { i64, ^i64 }\n'
             '@(glodin_nif)\nbad :: proc(value: Bad_Union) -> Bad_Union { return value }',
             "unsupported native interface type"),
        ]
        for declaration, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic, declaration=declaration):
                native.write_text(original + "\n" + declaration + "\n")
                output = integration.run(
                    self.path, "escript", str(integration.ROOT / "priv/glodin.escript"),
                    "generate", success=False,
                )
                self.assertIn(diagnostic, output)
                self.assertRegex(output, r"lib\.odin:\d+:\d+: glodin:")
                for path in outputs:
                    self.assertEqual(before[path], (path.read_bytes(), path.stat().st_mtime_ns))


if __name__ == "__main__":
    unittest.main(verbosity=2)
