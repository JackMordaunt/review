package tree

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
ends_reads_a_range :: proc(t: ^testing.T) {
	after, ranged := ends("abc")
	testing.expect_value(t, after, "abc")
	testing.expect_value(t, ranged, false)
	after, ranged = ends("a..b")
	testing.expect_value(t, after, "b")
	testing.expect_value(t, ranged, true)
	after, ranged = ends("a...b")
	testing.expect_value(t, after, "b")
	testing.expect_value(t, ranged, true)
}

@(test)
working_tree_reads_in_place :: proc(t: ^testing.T) {
	// A real absolute directory on every system: on Windows "/tmp" joined as
	// "tmp\\a\\b.go" (release run 36747721533).
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root := strings.trim_right(temp, "/\\")
	tr, ok := at(root, "")
	testing.expect(t, ok)
	testing.expect_value(t, tr.dir, root)
	sep := filepath.SEPARATOR_STRING
	want := strings.concatenate({root, sep, "a", sep, "b.go"}, context.temp_allocator)
	testing.expect_value(t, path(tr, "a/b.go", context.temp_allocator), want)
	close(tr)
}
