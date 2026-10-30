package main

import "codegen"
import "core:fmt"
import "core:path/filepath"
import "core:slice"

// Resolve and validate the source before any emitter runs. The result and all
// nested slices borrow context.allocator for the duration of this invocation.
resolve_interface :: proc(s: ^State) -> codegen.Interface {
	interface := codegen.Interface {
		package_name = s.package_name,
		module = s.module,
		app = s.app,
		lifecycle = {load = s.load_proc, upgrade = s.upgrade_proc, unload = s.unload_proc},
	}
	functions := make([dynamic]codegen.Function)
	seen := make(map[string]bool)
	defer delete(seen)
	for native in s.functions {
		function := codegen.Function {
			name         = native.name,
			wire_name    = native.wire_name,
			scheduler    = native.scheduler,
			gleam_result = "Nil",
		}
		parameters := make([dynamic]codegen.Parameter)
		for field in native.literal.type.params.list {
			if is_env(s, field.type) {
				// Every Odin parameter gets an argument, including grouped envs.
				for _ in field.names {
					append(&parameters, codegen.Parameter{kind = .Environment})
				}
				continue
			}
			if field.default_value != nil {
				die(field, "NIF parameters cannot have defaults")
			}
			gleam := gleam_type(s, field.type, native.file)
			for name in field.names {
				append(
					&parameters,
					codegen.Parameter {
						kind = .Value,
						name = ident(name),
						odin_type = source(native.file, field.type),
						gleam_type = gleam,
						wire_index = function.arity,
					},
				)
				function.arity += 1
			}
		}
		function.parameters = parameters[:]
		key := fmt.aprintf("%s/%d", function.wire_name, function.arity)
		if seen[key] {
			die(native.decl, "duplicate exported name and arity")
		}
		seen[key] = true
		results := native.literal.type.results
		if results != nil && len(results.list) > 0 {
			if len(results.list) != 1 || len(results.list[0].names) > 1 {
				die(native.decl, "use an explicit tuple struct or Result for multiple return values")
			}
			function.returns_value = true
			function.gleam_result = gleam_type(s, results.list[0].type, native.file)
		}
		append(&functions, function)
	}
	interface.functions = functions[:]
	interface.gleam_imports = s.gleam_imports
	interface.codecs = s.codecs[:]
	types := make([dynamic]codegen.Type_Declaration)
	for name in s.type_order {
		append(&types, s.types[name])
	}
	interface.types = types[:]
	import_names := make([dynamic]string)
	defer delete(import_names)
	for name in s.imports {
		append(&import_names, name)
	}
	slice.sort(import_names[:])
	imports := make([dynamic]codegen.Import)
	for name in import_names {
		append(&imports, codegen.Import{name = name, path = s.imports[name]})
	}
	interface.imports = imports[:]
	resource_names := make([dynamic]string)
	defer delete(resource_names)
	for name in s.resources {
		append(&resource_names, name)
	}
	slice.sort(resource_names[:])
	resources := make([dynamic]codegen.Resource)
	for name in resource_names {
		append(&resources, codegen.Resource{type = name, tag = snake(filepath.base(name))})
	}
	interface.resources = resources[:]
	return interface
}
