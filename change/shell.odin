package change

// A shell script is the one language here that commonly has no extension:
// the scripts a repository keeps in bin/ are named for the command they
// are, and only the shebang says what reads them. The dialect is settled
// once, at gather, and every reader after that is told rather than left to
// guess from the name.

import "core:strings"

// Dialect pairs a spelling with the shell it means: an extension for most
// files, a whole name for the dotfiles that have none. zsh and fish are
// absent on purpose — nothing here reads them.
@(private = "file")
Dialect :: struct {
	spelling: string,
	shell:    string,
}

@(private = "file")
extensions := []Dialect {
	{".bash", "bash"},
	{".bats", "bats"},
	{".ksh", "ksh"},
	{".dash", "sh"},
	{".sh", "sh"},
}

@(private = "file")
dotfiles := []Dialect {
	{".bashrc", "bash"},
	{".bash_profile", "bash"},
	{".bash_aliases", "bash"},
	{".bash_logout", "bash"},
	{".profile", "sh"},
}

// shell_of is the dialect a file is read as — bash, sh, ksh or bats — or
// empty where it is not a shell script. An extension settles it; a file
// without one is settled by first_line, which is the only thing that says
// what reads a script named for the command it is.
shell_of :: proc(path, first_line: string) -> string {
	base := path
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		base = path[i + 1:]
	}
	for d in dotfiles {
		if base == d.spelling {
			return d.shell
		}
	}
	if has_extension(base) {
		for e in extensions {
			if strings.has_suffix(base, e.spelling) {
				return e.shell
			}
		}
		return ""
	}
	return interpreter(first_line)
}

// needs_shebang is whether a path's first line has to be read for
// shell_of to answer: a name that carries an extension answers itself.
needs_shebang :: proc(path: string) -> bool {
	base := path
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		base = path[i + 1:]
	}
	for d in dotfiles {
		if base == d.spelling {
			return false
		}
	}
	return !has_extension(base) && is_code_file(path)
}

// has_extension is whether a file name carries one. A leading dot is the
// name's own, not an extension, so .bashrc has none in this sense.
@(private = "file")
has_extension :: proc(base: string) -> bool {
	return strings.contains(strings.trim_prefix(base, "."), ".")
}

// interpreter is the dialect a shebang names. The interpreter is the
// first word that is neither env nor one of its flags, so that
// "#!/usr/bin/env -S bash -eu" reads as bash.
@(private = "file")
interpreter :: proc(first_line: string) -> string {
	line := strings.trim_space(first_line)
	if !strings.has_prefix(line, "#!") {
		return ""
	}
	for field in strings.fields(line[2:], context.temp_allocator) {
		name := field
		if i := strings.last_index_byte(name, '/'); i >= 0 {
			name = name[i + 1:]
		}
		if name == "env" || strings.has_prefix(name, "-") {
			continue
		}
		switch name {
		case "bash":
			return "bash"
		case "sh", "dash", "ash":
			return "sh"
		case "ksh", "ksh93", "mksh", "pdksh":
			return "ksh"
		case "bats":
			return "bats"
		}
		return ""
	}
	return ""
}
