package main

import "core:mem"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

join :: proc(parts: []string) -> string {
	value, err := filepath.join(parts)
	if err != nil {
		die(nil, "invalid path")
	}
	return value
}

main :: proc() {
	if len(os.args) < 6 {
		die(nil, "generator expects NATIVE ROOT ERLANG_MODULE GLEAM_MODULE OTP_APP")
	}
	// Parser nodes, the resolved interface and emitted source share one lifetime.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator

	s := State {
		target       = {os = ODIN_OS, arch = ODIN_ARCH},
		native       = os.args[1],
		root         = os.args[2],
		module       = os.args[3],
		gleam_module = os.args[4],
		app          = os.args[5],
	}
	for argument in os.args[6:] {
		if strings.has_prefix(argument, "--target=") {
			parts := strings.split(argument[len("--target="):], "_")
			if len(parts) != 2 {
				die(nil, "generator target requires OS_ARCH")
			}
			s.target.os, _ = parser.get_build_os_from_string(parts[0])
			s.target.arch = parser.get_build_arch_from_string(parts[1])
			if s.target.os == .Unknown || s.target.arch == .Unknown {
				die(nil, "unsupported generator target")
			}
		} else if index := strings.index_byte(argument, '='); index >= 0 {
			s.collections[argument[:index]] = argument[index + 1:]
		} else {
			die(nil, "collections must use NAME=PATH")
		}
	}
	parse_native(&s)
	interface := resolve_interface(&s)
	emit(&s, &interface)
}
