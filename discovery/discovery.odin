// Package discovery locates shipped tools beside review before consulting PATH.
package discovery

import "core:os"
import "core:path/filepath"
import "core:fmt"
import "core:strings"
import "jm:sh"

find :: proc(name: string, allocator := context.allocator) -> (path: string, found: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	if err == nil && (name == "review-go" || name == "review-vet" || name == "odin-review-extract") {
		suffix := ""
		when ODIN_OS == .Windows {suffix = ".exe"}
		file := fmt.tprintf("%s%s", name, suffix)
		candidate, _ := filepath.join({filepath.dir(self), file}, context.temp_allocator)
		if executable(candidate, context.temp_allocator) {return strings.clone(candidate, allocator), true}
	}
	separator := ":"
	when ODIN_OS == .Windows {separator = ";"}
	path_env := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path_env, separator) {
		if dir == "" {continue}
		for extension in sh.executable_extensions() {
			file := fmt.tprintf("%s%s", name, extension)
			candidate, _ := filepath.join({dir, file}, context.temp_allocator)
			if executable(candidate, context.temp_allocator) {
				absolute, absolute_err := filepath.abs(candidate, allocator)
				if absolute_err == nil {return absolute, true}
			}
		}
	}
	return "", false
}

executable :: proc(path: string, allocator := context.allocator) -> bool {
	if !os.is_file(path) {return false}
	when ODIN_OS != .Windows {
		info, err := os.stat(path, allocator)
		return err == nil && info.mode & os.Permissions_Execute_All != {}
	} else {return true}
}
