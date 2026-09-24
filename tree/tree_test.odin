package tree

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
	tr, ok := at("/tmp", "")
	testing.expect(t, ok)
	testing.expect_value(t, tr.dir, "/tmp")
	testing.expect_value(t, path(tr, "a/b.go", context.temp_allocator), "/tmp/a/b.go")
	close(tr)
}
