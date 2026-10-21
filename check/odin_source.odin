package check

import "core:odin/ast"
import "core:odin/parser"

// parse_odin_source returns parsed syntax in the chosen allocator, or nil
// when the compiler must diagnose malformed source.
@(private)
parse_odin_source :: proc(path, src: string, allocator := context.temp_allocator) -> ^ast.File {
	context.allocator = allocator
	file := new(ast.File)
	file.fullpath, file.src = path, src
	p := parser.default_parser()
	p.err, p.warn = nil, nil
	if !parser.parse_file(&p, file) {
		return nil
	}
	return file
}
