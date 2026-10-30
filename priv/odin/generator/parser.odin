package main

import "codegen"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

die :: proc(node: ^ast.Node, message: string) -> ! {
	if node != nil {
		fmt.eprintf("%s:%d:%d: glodin: %s\n", node.pos.file, node.pos.line, node.pos.column, message)
	} else {
		fmt.eprintf("glodin: %s\n", message)
	}
	os.exit(1)
}

source :: proc(file: ^ast.File, node: ^ast.Node) -> string {
	return file.src[node.pos.offset:node.end.offset]
}
ident :: proc(expr: ^ast.Expr) -> string {
	if x, ok := expr.derived.(^ast.Ident); ok {
		return x.name
	}
	return ""
}
attribute :: proc(decl: ^ast.Value_Decl, name: string) -> (string, bool) {
	for attr in decl.attributes {
		for elem in attr.elems {
			if ident(elem) == name {
				return "", true
			}
			if x, ok := elem.derived.(^ast.Field_Value); ok && ident(x.field) == name {
				literal, ok := x.value.derived.(^ast.Basic_Lit)
				if !ok {
					die(x, "attribute values must be string literals")
				}
				return strings.trim(literal.tok.text, "\""), true
			}
		}
	}
	return "", false
}

snake :: proc(name: string) -> string {
	b: strings.Builder
	boundary := true
	for c in name {
		if c == '_' || c == ' ' {
			boundary = true
			continue
		}
		if c >= 'A' && c <= 'Z' {
			boundary = true
		}
		if boundary && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '_')
		}
		boundary = false
		strings.write_rune(&b, c + ('a' - 'A') if c >= 'A' && c <= 'Z' else c)
	}
	return strings.to_string(b)
}

gleam_type_name :: proc(name: string) -> string {
	b: strings.Builder
	boundary := true
	for c in name {
		if c == '_' {
			boundary = true
			continue
		}
		strings.write_rune(&b, c - ('a' - 'A') if boundary && c >= 'a' && c <= 'z' else c)
		boundary = false
	}
	return strings.to_string(b)
}
valid_name :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] < 'a' || name[0] > 'z' {
		return false
	}
	for c in name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

is_env :: proc(s: ^State, expr: ^ast.Expr) -> bool {
	pointer, ok := expr.derived.(^ast.Pointer_Type)
	if !ok {
		return false
	}
	selector, selected := pointer.elem.derived.(^ast.Selector_Expr)
	if !selected || selector.field.name != "Env" {
		return false
	}
	path := s.imports[ident(selector.expr)]
	return path == "glodin:glodin" || strings.has_suffix(path, "/glodin")
}

parse_native :: proc(s: ^State) {
	pkg, collected := parser.collect_package(s.native)
	if !collected {
		die(nil, "cannot read Odin package")
	}
	for path in pkg.files {
		if filepath.base(path) == "glodin_generated.odin" {
			delete_key(&pkg.files, path)
		}
	}
	p := parser.default_parser()
	if !parser.parse_package(pkg, &p) || p.error_count > 0 {
		die(nil, "cannot parse Odin package")
	}
	s.package_name = pkg.name
	paths := make([dynamic]string)
	for path in pkg.files {
		append(&paths, path)
	}
	slice.sort(paths[:])
	for path in paths {
		file := pkg.files[path]
		if filepath.base(path) == "glodin_generated.odin" {
			continue
		}
		for imp in file.imports {
			alias := imp.name.text
			relpath := strings.trim(imp.relpath.text, "\"")
			if alias == "" {
				alias = filepath.base(relpath)
				if colon := strings.last_index_byte(alias, ':'); colon >= 0 {
					alias = alias[colon + 1:]
				}
			}
			if old, exists := s.imports[alias]; exists && old != relpath {
				die(imp, "conflicting file-local import names in native interface; give the imports distinct aliases")
			}
			s.imports[alias] = relpath
		}
		for stmt in file.decls {
			decl, ok := stmt.derived.(^ast.Value_Decl)
			if !ok || len(decl.names) != 1 || len(decl.values) != 1 {
				continue
			}
			name := ident(decl.names[0])
			s.declarations[name] = Declaration{decl, file}
			if _, resource := attribute(decl, "glodin_resource"); resource {
				s.resources[name] = true
			}
			if _, tagged := attribute(decl, "glodin_load"); tagged {
				s.load_proc = name
			}
			if _, tagged := attribute(decl, "glodin_upgrade"); tagged {
				s.upgrade_proc = name
			}
			if _, tagged := attribute(decl, "glodin_unload"); tagged {
				s.unload_proc = name
			}
			if _, tagged := attribute(decl, "glodin_nif"); !tagged {
				continue
			}
			literal, literal_ok := decl.values[0].derived.(^ast.Proc_Lit)
			if !literal_ok || literal.type.generic {
				die(decl, "NIF exports must be concrete procedures")
			}
			wire_name, renamed := attribute(decl, "glodin_name")
			if !renamed {
				wire_name = name
			}
			if !valid_name(wire_name) {
				die(decl, "export names must be lowercase identifiers")
			}
			schedule, _ := attribute(decl, "glodin_schedule")
			scheduler: codegen.Scheduler
			switch schedule {
			case "", "Normal":
				scheduler = .Normal
			case "DirtyCpu":
				scheduler = .Dirty_Cpu
			case "DirtyIo":
				scheduler = .Dirty_Io
			case:
				die(decl, "schedule must be Normal, DirtyCpu, or DirtyIo")
			}
			append(&s.functions, Native_Function{name, wire_name, scheduler, literal, file, decl})
		}
	}
	if len(s.functions) == 0 {
		die(nil, "native module contains no @(glodin_nif) procedures")
	}
}
