package main

import "codegen"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
import "core:strings"

gleam_type :: proc(s: ^State, expr: ^ast.Expr, file: ^ast.File) -> string {
	type := resolve_gleam_type(s, expr, file)
	// Track imports from resolved type references, before rendering any source.
	for prefix, name in ([codegen.Gleam_Import]string{.Types = "types.", .Dict = "dict.", .Option = "option."}) {
		if strings.contains(type, prefix) {
			s.gleam_imports[name] = true
		}
	}
	return type
}

resolve_gleam_type :: proc(s: ^State, expr: ^ast.Expr, file: ^ast.File) -> string {
	text := source(file, expr)
	if x, ok := expr.derived.(^ast.Ident); ok {
		switch x.name {
		case "i8", "i16", "i32", "i64", "i128", "int", "u8", "u16", "u32", "u64", "u128", "uint", "uintptr", "rune":
			return "Int"
		case "f32", "f64":
			return "Float"
		case "bool":
			return "Bool"
		case "string":
			return "String"
		case:
			decl, ok := s.declarations[x.name]
			if !ok {
				die(expr, fmt.tprintf("cannot resolve exported type %s", x.name))
			}
			return declare_type(s, x.name, decl)
		}
	} else if x, ok := expr.derived.(^ast.Array_Type); ok {
		return fmt.aprintf("List(%s)", gleam_type(s, x.elem, file))
	} else if x, ok := expr.derived.(^ast.Dynamic_Array_Type); ok {
		return fmt.aprintf("List(%s)", gleam_type(s, x.elem, file))
	} else if x, ok := expr.derived.(^ast.Map_Type); ok {
		return fmt.aprintf("dict.Dict(%s, %s)", gleam_type(s, x.key, file), gleam_type(s, x.value, file))
	} else if x, ok := expr.derived.(^ast.Selector_Expr); ok {
		name := x.field.name
		if rel, ok := s.imports[ident(x.expr)]; ok && (rel == "glodin:glodin" || strings.has_suffix(rel, "/glodin")) {
			switch name {
			case "Binary", "Owned_Binary", "New_Binary":
				return "BitArray"
			case "Big_Int":
				return "Int"
			case "Term":
				return "types.Term"
			case "Atom":
				return "types.Atom"
			case "Pid":
				return "types.Pid"
			case "Reference":
				return "types.Reference"
			case:
				die(expr, fmt.tprintf("unsupported native interface type %s", name))
			}
		}
		// Import aliases are resolved using the imported package's AST.
		alias := ident(x.expr)
		rel, exists := s.imports[alias]
		if !exists {
			die(expr, "exported imported type has no corresponding import")
		}
		import_dir := join({filepath.dir(file.fullpath), rel})
		if colon := strings.index_byte(rel, ':'); colon >= 0 {
			collection, found := s.collections[rel[:colon]]
			if !found {
				die(expr, "exported collection types require an entry in glodin.json collections")
			}
			import_dir = join({collection, rel[colon + 1:]})
		}
		pkg, ok := parser.parse_package_from_path(import_dir)
		if !ok {
			die(expr, "cannot parse imported type package")
		}
		for _, imported_file in pkg.files {
			if !file_matches_target(imported_file, s.target) {
				continue
			}
			for stmt in imported_file.decls {
				decl, ok := stmt.derived.(^ast.Value_Decl)
				if ok && len(decl.names) == 1 && ident(decl.names[0]) == name {
					return declare_type(s, text, Declaration{decl, imported_file})
				}
			}
		}
		die(expr, "imported type not found")
	} else if x, ok := expr.derived.(^ast.Call_Expr); ok {
		selector, ok := x.expr.derived.(^ast.Selector_Expr)
		if !ok {
			die(
				expr,
				"only Glodin Result, Option, Resource and Nif_Result generic types are supported in exported signatures",
			)
		}
		name := selector.field.name
		switch name {
		case "Json":
			if len(x.args) != 1 {
				die(expr, "Json requires one type argument")
			}
			if _, exists := s.types[text]; !exists {
				s.types[text] = codegen.Type_Declaration{}
				append(&s.codecs, codegen.Json_Codec{type = source(file, x.args[0])})
			}
			return "BitArray"
		case "Result":
			if len(x.args) != 2 {
				die(expr, "Result requires two type arguments")
			}
			return fmt.aprintf("Result(%s, %s)", gleam_type(s, x.args[0], file), gleam_type(s, x.args[1], file))
		case "Option":
			if len(x.args) != 1 {
				die(expr, "Option requires one type argument")
			}
			return fmt.aprintf("option.Option(%s)", gleam_type(s, x.args[0], file))
		case "Nif_Result":
			if len(x.args) != 1 {
				die(expr, "Nif_Result requires one type argument")
			}
			return gleam_type(s, x.args[0], file)
		case "Resource":
			if len(x.args) != 1 {
				die(expr, "Resource requires one type argument")
			}
			resource_type := source(file, x.args[0])
			s.resources[resource_type] = true
			native_name := resource_type
			if dot := strings.last_index_byte(native_name, '.'); dot >= 0 {
				native_name = native_name[dot + 1:]
			}
			if _, exists := s.types[text]; !exists {
				s.types[text] = codegen.Type_Declaration {
					kind = .External,
					name = fmt.aprintf("%sResource", gleam_type_name(native_name)),
				}
				append(&s.type_order, text)
				append(&s.codecs, codegen.Resource_Codec{type = resource_type})
			}
			return fmt.aprintf("%sResource", gleam_type_name(native_name))
		case:
			die(expr, "unsupported generic native type")
		}
	} else if x, ok := expr.derived.(^ast.Distinct_Type); ok {
		return gleam_type(s, x.type, file)
	} else {
		// Unknown compiler AST nodes are rejected at this external syntax boundary.
		die(expr, fmt.tprintf("unsupported native interface type: %s", text))
	}
	return ""
}

declare_type :: proc(s: ^State, name: string, declaration: Declaration) -> string {
	decl, file := declaration.decl, declaration.file
	expr := decl.values[0]
	native_name := ident(decl.names[0])
	gleam_name := gleam_type_name(native_name)
	if mapping, custom := attribute(decl, "glodin_gleam"); custom {
		if mapping == "" || strings.contains(mapping, "\n") || strings.contains(mapping, "\"") {
			die(decl, "invalid Gleam type mapping")
		}
		return mapping
	}
	if _, exists := s.types[name]; exists {
		return gleam_name
	}
	// Mark before traversing fields to allow recursive named types.
	s.types[name] = codegen.Type_Declaration {
		name = gleam_name,
	}
	append(&s.type_order, name)
	mode, annotated := attribute(decl, "glodin_codec")
	tag, _ := attribute(decl, "glodin_tag")
	codec_mode: codegen.Codec_Mode = .Tagged
	switch mode {
	case "", "tagged":
	case "tuple":
		codec_mode = .Tuple
	case "map":
		codec_mode = .Map
	case "record":
		codec_mode = .Record
	case "untagged":
		codec_mode = .Untagged
	case:
		die(decl, "codec must be tagged, tuple, map, record, or untagged")
	}
	if annotated || tag != "" {
		if tag != "" && !valid_name(tag) {
			die(decl, "wire tags must be lowercase identifiers")
		}
		append(&s.codecs, codegen.Value_Codec{type = name, mode = codec_mode, tag = tag})
	}
	type := codegen.Type_Declaration {
		name = gleam_name,
	}
	if x, ok := expr.derived.(^ast.Struct_Type); ok {
		if mode == "map" || tag != "" && tag != snake(native_name) {
			type.kind = .External
			// Opaque Gleam declarations still require supported native fields.
			resolve_fields(s, x.fields, file, false)
		} else if mode == "tuple" {
			type.kind = .Tuple
			type.fields = resolve_fields(s, x.fields, file, false)
		} else {
			type.kind = .Custom
			constructors := make([]codegen.Constructor, 1)
			constructors[0] = codegen.Constructor {
				name      = gleam_name,
				fields    = resolve_fields(s, x.fields, file, true),
				multiline = true,
			}
			type.constructors = constructors
		}
	} else if x, ok := expr.derived.(^ast.Enum_Type); ok {
		type.kind = .Custom
		constructors := make([dynamic]codegen.Constructor)
		for field in x.fields {
			field_name := ident(field)
			if fv, ok := field.derived.(^ast.Field_Value); ok {
				field_name = ident(fv.field)
			}
			append(&constructors, codegen.Constructor{name = gleam_type_name(field_name)})
		}
		type.constructors = constructors[:]
	} else if x, ok := expr.derived.(^ast.Union_Type); ok {
		if mode == "untagged" {
			type.kind = .External
			for variant in x.variants {
				gleam_type(s, variant, file)
			}
		} else {
			type.kind = .Custom
			constructors := make([dynamic]codegen.Constructor)
			for variant in x.variants {
				variant_name := ident(variant)
				variant_decl, ok := s.declarations[variant_name]
				if !ok {
					die(variant, "tagged unions require named struct variants in the native package")
				}
				variant_struct, struct_ok := variant_decl.decl.values[0].derived.(^ast.Struct_Type)
				if !struct_ok {
					die(variant, "tagged unions require struct variants")
				}
				append(
					&constructors,
					codegen.Constructor {
						name = gleam_type_name(variant_name),
						fields = resolve_fields(s, variant_struct.fields, variant_decl.file, false),
					},
				)
			}
			type.constructors = constructors[:]
		}
	} else {
		type.kind = .Alias
		type.alias = gleam_type(s, expr, file)
	}
	s.types[name] = type
	return gleam_name
}

resolve_fields :: proc(s: ^State, list: ^ast.Field_List, file: ^ast.File, labelled: bool) -> []codegen.Field {
	fields := make([dynamic]codegen.Field)
	if list != nil {
		for field in list.list {
			type := gleam_type(s, field.type, file)
			for name in field.names {
				label := ""
				if labelled {
					label = ident(name)
				}
				append(&fields, codegen.Field{name = label, type = type})
			}
		}
	}
	return fields[:]
}
