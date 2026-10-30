@external(erlang, "glodin_conformance_assertions", "run")
fn run_checks() -> Nil

pub fn main() {
  let person = checks.Person("Ada", 36)
  let assert True = person == checks.echo_person(person)
  let assert checks.Green = checks.echo_colour(checks.Green)
  let assert checks.Rectangle(2.0, 3.0) =
    checks.echo_shape(checks.Rectangle(2.0, 3.0))
  let assert #(1, "one") = checks.echo_pair(#(1, "one"))
  let assert Ok(42) = checks.echo_result(Ok(42))
  let assert Error("reason") = checks.echo_result(Error("reason"))
  let assert option.Some(42) = checks.echo_option(option.Some(42))
  let assert option.None = checks.echo_option(option.None)
  let numbers = dict.from_list([#("one", 1), #("two", 2)])
  let assert True = numbers == checks.echo_map(numbers)
  run_checks()
}
import glodin_conformance/checks
import gleam/option
import gleam/dict

