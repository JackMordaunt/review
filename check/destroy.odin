package check

// The check assumes an Odin struct that owns memory is freed field by
// field in a procedure written beside it. The leak read for here is a
// field added to the struct and never added to that procedure. The Odin
// sidecar reads the structs and the procedures that look like releases;
// what is compared here is whether each owning field is handed to a call
// in its release.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../change"
import "../finding"
import "../frontend"

// Owning_Type is a struct as the check reads it: where it is declared, and the
// procedures that release it.
@(private = "file")
Owning_Type :: struct {
	file:     string,
	decl:     frontend.Struct,
	releases: [dynamic]Located_Release,
}

@(private = "file")
Located_Release :: struct {
	file:    string,
	release: frontend.Release,
}

// check_destroy_incomplete reports an owning field of an Odin struct that
// the struct's release procedure never hands to a call. A procedure
// releases a struct T when its first parameter is T or ^T and it is named
// destroy, free, deinit or delete, alone or joined to T's snake_case name
// on either side: index_destroy and destroy_index both release Index. A
// field owns memory when its type is a string, a slice, a map, a dynamic
// array or a pointer, or a struct of the package that has a release of
// its own. A release that calls free_all or destroys an arena frees
// everything at once, and its struct is not read field by field. Only a
// field or a release the change adds a line to is judged; a struct with
// no release is not.
check_destroy_incomplete :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	dirs := make(map[string]bool, context.temp_allocator)
	for file in s.c.files {
		if strings.has_suffix(file, ".odin") && len(s.c.added[file]) > 0 {
			dirs[filepath.dir(file)] = true
		}
	}
	for dir in sorted_keys(dirs) {
		names := make([dynamic]string, context.temp_allocator)
		for file in s.files {
			if strings.has_suffix(file, ".odin") &&
			   filepath.dir(file) == dir {
				append(&names, file)
			}
		}
		answers, err := change.scan(.Odin, s.t, names[:], context.temp_allocator)
		if err != .None {
			continue // No sidecar, no reading: the check says nothing.
		}
		read_package(s, answers, names[:], out)
	}
}

// read_package judges the structs of one package, the files in the order
// named.
@(private = "file")
read_package :: proc(
	s: Scope,
	answers: map[string]frontend.File,
	names: []string,
	out: ^[dynamic]finding.Finding,
) {
	owned := make(map[string]Owning_Type, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	for name in names {
		file := answers[name]
		for decl in file.structs {
			if decl.name not_in owned {
				owned[decl.name] = Owning_Type {
					file     = name,
					decl     = decl,
					releases = make([dynamic]Located_Release, context.temp_allocator),
				}
				append(&order, decl.name)
			}
		}
	}
	for name in names {
		file := answers[name]
		for r in file.releases {
			if o, found := &owned[r.target]; found && releases(r.name, r.target) {
				append(&o.releases, Located_Release{name, r})
			}
		}
	}
	for type_name in order {
		o := owned[type_name]
		if len(o.releases) == 0 || frees_all(o.releases[:]) {
			continue
		}
		release_touched := false
		procs := make([dynamic]string, context.temp_allocator)
		for r in o.releases {
			release_touched ||= added_between(s, r.file, r.release.line, r.release.end_line)
			append(&procs, fmt.tprintf("`%s`", r.release.name))
		}
		for field in o.decl.fields {
			if !owns(field, owned) || released(field.name, o.releases[:]) {
				continue
			}
			if !release_touched && !added_between(s, o.file, field.line, field.line) {
				continue
			}
			via := strings.join(procs[:], " or ", context.temp_allocator)
			append(
				out,
				static(
					"odin-destroy-incomplete",
					.Consider,
					fmt.aprintf(
						"field `%s` of `%s` (%s) is never released in %s; free it there or mark it borrowed",
						field.name,
						type_name,
						field.type,
						via,
					),
					fmt.aprintf(
						"release it in %s, or, where the struct only borrows it, dismiss the finding with //review:ignore <rule> <why>",
						via,
					),
					file = o.file,
					line = field.line,
					symbol = fmt.aprintf("%s.%s", type_name, field.name),
				),
			)
		}
	}
}

// releases reports whether a procedure's name is a release of the type:
// a verb alone, or joined to the type's snake_case name on either side.
@(private = "file")
releases :: proc(name, type_name: string) -> bool {
	snake := snake_case(type_name)
	for verb in ([]string{"destroy", "free", "deinit", "delete"}) {
		if name == verb ||
		   name == strings.concatenate({snake, "_", verb}, context.temp_allocator) ||
		   name == strings.concatenate({verb, "_", snake}, context.temp_allocator) {
			return true
		}
	}
	return false
}

// snake_case lowers a type name, putting an underscore where a lower-case
// letter or a digit meets an upper-case one: Index_Entry and IndexEntry
// are both index_entry.
snake_case :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	prev: byte
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'A' && c <= 'Z' {
			if (prev >= 'a' && prev <= 'z') || (prev >= '0' && prev <= '9') {
				strings.write_byte(&b, '_')
			}
			c += 'a' - 'A'
		}
		strings.write_byte(&b, c)
		prev = name[i]
	}
	return strings.to_string(b)
}

// owns reports whether a field holds memory its struct must free: by its
// type's form, or by being a struct of the package with a release.
@(private = "file")
owns :: proc(field: frontend.Field, owned: map[string]Owning_Type) -> bool {
	switch field.shape {
	case "string", "slice", "map", "dynamic", "pointer":
		return true
	case "named":
		if o, found := owned[field.type]; found {
			return len(o.releases) > 0
		}
	}
	return false
}

// released reports whether any release hands the field's name to a call.
@(private = "file")
released :: proc(field: string, rs: []Located_Release) -> bool {
	for r in rs {
		if slice.contains(r.release.names, field) {
			return true
		}
	}
	return false
}

@(private = "file")
frees_all :: proc(rs: []Located_Release) -> bool {
	for r in rs {
		if r.release.frees_all {
			return true
		}
	}
	return false
}

// added_between reports whether the change adds a line of a file within
// the range, inclusive.
@(private = "file")
added_between :: proc(s: Scope, file: string, first, last: int) -> bool {
	lines := s.c.added[file]
	for l in lines {
		if l.line >= first && l.line <= last {
			return true
		}
	}
	return false
}
