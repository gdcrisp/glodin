GLEAM ?= $(CURDIR)/.tools/bin/gleam

.PHONY: compiler check test
compiler:
	bash scripts/build_gleam.sh

check:
	odin check priv/odin/generator -vet-unused -vet-semicolon -vet-tabs
	$(GLEAM) check

test:
	$(GLEAM) build
	GLEAM_BIN="$(GLEAM)" python3 -m unittest discover -s tests -p 'test_*.py' -v
