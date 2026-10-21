package external
import "core:os"
import "core:sys/darwin"
@(private)
lock_native :: proc(f: ^os.File) -> bool {
	return darwin.syscall_flock(i32(os.fd(f)), darwin.LOCK_EX | darwin.LOCK_NB) == 0
}

@(private)
unlock_native :: proc(f: ^os.File) {
	_ = darwin.syscall_flock(i32(os.fd(f)), darwin.LOCK_UN)
}
