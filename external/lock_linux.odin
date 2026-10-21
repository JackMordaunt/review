package external
import "core:os"
import "core:sys/linux"
@(private)
lock_native :: proc(f: ^os.File) -> bool {
	return linux.flock(linux.Fd(os.fd(f)), {.EX, .NB}) == .NONE
}

@(private)
unlock_native :: proc(f: ^os.File) {
	_ = linux.flock(linux.Fd(os.fd(f)), {.UN})
}
