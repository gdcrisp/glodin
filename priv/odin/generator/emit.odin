package main

import "codegen"
import "core:fmt"
import "core:os"
import "core:path/filepath"

write_if_changed :: proc(path, text: string) {
	old, err := os.read_entire_file(path, context.allocator)
	defer delete(old)
	if err == nil && string(old) == text {
		return
	}
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
		die(nil, fmt.tprintf("cannot write %s", path))
	}
}

emit :: proc(s: ^State, interface: ^codegen.Interface) {
	// Render every target before writing any of the generated files.
	odin := codegen.emit_odin(interface)
	gleam := codegen.emit_gleam(interface)
	erlang := codegen.emit_erlang(interface)
	c := codegen.emit_c(interface)
	cache := join({s.root, ".glodin", filepath.base(s.native)})
	os.make_directory(join({s.root, ".glodin"}))
	os.make_directory(cache)
	write_if_changed(join({s.native, "glodin_generated.odin"}), odin)
	// The driver formats this intermediate file before publishing declarations,
	// so unchanged public source files retain their mtimes on repeated builds.
	write_if_changed(join({cache, "bindings.gleam"}), gleam)
	write_if_changed(join({cache, "loader.erl"}), erlang)
	write_if_changed(join({cache, "entry.c"}), c)
}
