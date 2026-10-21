package external

import "core:os"
// acquire retains the lock file between operations.
@(private)
acquire :: proc(path: string, allocator := context.allocator) -> (^os.File, bool) {
	context.allocator = allocator
	f, err := os.open(path, {.Read, .Write, .Create}, {.Read_User, .Write_User})
	if err != nil {return nil, false}
	locked := lock_native(f)
	if !locked {os.close(f); return nil, false}
	return f, true
}

// release unlocks before closing the handle.
@(private)
release :: proc(f: ^os.File) {
	unlock_native(f)
	os.close(f)
}
