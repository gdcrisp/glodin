GLEAM ?= gleam

.PHONY: check test docs package
check:
	odin check priv/odin/generator -vet-unused -vet-semicolon -vet-tabs
	$(GLEAM) format --check src examples
	$(GLEAM) check

test:
	$(GLEAM) build --warnings-as-errors
	GLEAM_BIN="$(GLEAM)" python3 -m unittest discover -s tests -p 'test_*.py' -v

docs:
	$(GLEAM) docs build

package:
	GLEAM="$(GLEAM)" escript priv/glodin.escript export hex-tarball
