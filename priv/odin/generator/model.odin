package main

import "codegen"
import "core:odin/ast"

Declaration :: struct {
	decl: ^ast.Value_Decl,
	file: ^ast.File,
}
Native_Function :: struct {
	name, wire_name: string,
	scheduler:       codegen.Scheduler,
	literal:         ^ast.Proc_Lit,
	file:            ^ast.File,
	decl:            ^ast.Value_Decl,
}
State :: struct {
	root, native, module, gleam_module, app, package_name: string,
	declarations:                                          map[string]Declaration,
	imports:                                               map[string]string,
	collections:                                           map[string]string,
	types:                                                 map[string]codegen.Type_Declaration,
	type_order:                                            [dynamic]string,
	functions:                                             [dynamic]Native_Function,
	resources:                                             map[string]bool,
	codecs:                                                [dynamic]codegen.Codec,
	gleam_imports:                                         [codegen.Gleam_Import]bool,
	load_proc, upgrade_proc, unload_proc:                  string,
}
