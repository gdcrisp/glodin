// Glodin's resolved interface. Emitters never need the Odin parser or filesystem.
package codegen

Scheduler :: enum {
	Normal,
	Dirty_Cpu,
	Dirty_Io,
}

Parameter_Kind :: enum {
	Value,
	Environment,
}

Parameter :: struct {
	kind:       Parameter_Kind,
	name:       string,
	odin_type:  string,
	gleam_type: string,
	wire_index: int,
}

Function :: struct {
	name:          string,
	wire_name:     string,
	scheduler:     Scheduler,
	parameters:    []Parameter,
	arity:         int,
	returns_value: bool,
	gleam_result:  string,
}

Type_Kind :: enum {
	External,
	Alias,
	Tuple,
	Custom,
}

Field :: struct {
	name: string,
	type: string,
}

Constructor :: struct {
	name:      string,
	fields:    []Field,
	multiline: bool,
}

Type_Declaration :: struct {
	kind:         Type_Kind,
	name:         string,
	alias:        string,
	fields:       []Field,
	constructors: []Constructor,
}

Gleam_Import :: enum {
	Types,
	Dict,
	Option,
}

GLEAM_IMPORT_PATHS :: [Gleam_Import]string {
	.Types  = "glodin/types",
	.Dict   = "gleam/dict",
	.Option = "gleam/option",
}

Codec_Mode :: enum {
	Tagged,
	Tuple,
	Map,
	Record,
	Untagged,
}

Value_Codec :: struct {
	type: string,
	mode: Codec_Mode,
	tag:  string,
}

Resource_Codec :: struct {
	type: string,
}

Codec :: union {
	Value_Codec,
	Resource_Codec,
	Json_Codec,
}

Json_Codec :: struct {
	type: string,
}

Import :: struct {
	name: string,
	path: string,
}

Resource :: struct {
	type: string,
	tag:  string,
}

Lifecycle :: struct {
	load:    string,
	upgrade: string,
	unload:  string,
}

// Slices and strings borrow the resolver's allocator. Keep it alive until all
// outputs have been rendered and written.
Interface :: struct {
	package_name:  string,
	module:        string,
	app:           string,
	imports:       []Import,
	gleam_imports: [Gleam_Import]bool,
	functions:     []Function,
	types:         []Type_Declaration,
	resources:     []Resource,
	codecs:        []Codec,
	lifecycle:     Lifecycle,
}
