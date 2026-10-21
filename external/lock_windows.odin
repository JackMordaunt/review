package external
import "core:os"
import win32 "core:sys/windows"
@(private)
lock_native :: proc(f: ^os.File) -> bool {
	overlapped: win32.OVERLAPPED
	return bool(
		win32.LockFileEx(
			win32.HANDLE(os.fd(f)),
			win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY,
			0,
			1,
			0,
			&overlapped,
		),
	)
}

@(private)
unlock_native :: proc(f: ^os.File) {
	overlapped: win32.OVERLAPPED
	_ = win32.UnlockFileEx(win32.HANDLE(os.fd(f)), 0, 1, 0, &overlapped)
}
