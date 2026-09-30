package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "jm:selfupdate"

// VERSION is the release tag, baked in by the release workflow with
// -define:VERSION. A local build has none, which selfupdate treats as a
// development build and leaves alone.
VERSION :: #config(VERSION, "")

// COMMIT is the commit the binary was built from, short, with "-dirty"
// when the working tree had uncommitted changes. The justfile and the
// release workflow pass it quoted, so that a hash such as 21e17ac is not
// read as a number. Git Bash on Windows has delivered them escaped (brainfold
// release run 36720442466 reported a commit as \7642491\), so commit_stamp
// strips backslashes as well.
COMMIT :: #config(COMMIT, "")

commit_stamp :: proc() -> string {
	return strings.trim(COMMIT, "\"\\")
}

// Where releases are served: the asset for each binary and platform,
// sha256sums.txt, its signature and version.txt, under one path.
// REVIEW_RELEASE_BASE overrides it. install.sh and install.ps1 repeat it,
// since they run before any binary exists; just test-installer checks that
// all three agree.
RELEASE_BASE :: "https://github.com/jackmordaunt/review/releases/latest/download"

// PLATFORM is this build's suffix in a release's asset names.
when ODIN_OS == .Windows {
	PLATFORM :: "windows-amd64.exe"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	PLATFORM :: "darwin-arm64"
} else when ODIN_OS == .Darwin {
	PLATFORM :: "darwin-amd64"
} else when ODIN_ARCH == .arm64 {
	PLATFORM :: "linux-arm64"
} else {
	PLATFORM :: "linux-amd64"
}

EXE :: ".exe" when ODIN_OS == .Windows else ""

// SIDECARS ship in every release beside review and are updated with it.
SIDECARS :: [?]string{"review-go", "review-vet", "odin-review-extract"}

// The Ed25519 key that signs sha256sums.txt in the release workflow; its
// private half is the repository secret REVIEW_SIGNING_KEY. Nothing from a
// release is trusted until it verifies under this key.
PUBLIC_KEY :: "0124f6a5e0935ef75b1a2b68495cbff7307837b61e1c61317ce0640bff828f12"

// UPDATE_FILE holds the version the last daily check found newer than this
// build, so the hint repeats on every run until `review update` while the
// network is asked at most once a day.
UPDATE_FILE :: "update-available"

// NOTIFY_TIMEOUT bounds each download of the daily check; a person is waiting.
NOTIFY_TIMEOUT :: 3 * time.Second

version_name :: proc() -> string {
	return VERSION == "" ? "dev" : VERSION
}

print_version :: proc() -> int {
	stamp := commit_stamp()
	fmt.printfln(
		"review %s (%s) built from %s",
		version_name(),
		PLATFORM,
		stamp == "" ? "an unknown commit" : stamp,
	)
	return 0
}

// The decoded public key; selfupdate keeps a slice of it.
public_key: [32]byte

// update_config is the check or update of one binary of the release:
// name is its asset's prefix, exe its path on disk, "" for this process.
update_config :: proc(name, exe: string, mode: selfupdate.Mode) -> selfupdate.Config {
	selfupdate.key_from_hex(PUBLIC_KEY, public_key[:])
	base := os.get_env("REVIEW_RELEASE_BASE", context.temp_allocator)
	return selfupdate.Config {
		base_url = base == "" ? RELEASE_BASE : base,
		version = VERSION,
		asset = fmt.tprintf("%s-%s", name, PLATFORM),
		public_key = public_key[:],
		mode = mode,
		state_dir = state_dir(),
		exe = exe,
	}
}

// state_dir holds the daily check's stamp and hint, beside the answer cache.
state_dir :: proc() -> string {
	dir, err := os.user_cache_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return filepath.join({dir, "review"}, context.temp_allocator) or_else ""
}

// review update: fetch the latest release, verify it, replace the sidecars
// beside this binary, then this binary, and run it again. The new binary
// re-runs `update` and reports everything up to date.
run_update :: proc() -> int {
	if VERSION == "" {
		fmt.eprintln("review: a development build does not update itself; rebuild it from source")
		return 1
	}
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("review: cannot find this executable: %v", err)
		return 1
	}
	dir := filepath.dir(self)
	failed := false
	for name in SIDECARS {
		exe := filepath.join({dir, strings.concatenate({name, EXE}, context.temp_allocator)}, context.temp_allocator) or_else ""
		if !os.exists(exe) {
			fmt.printfln("%s is not beside review; skipped", name)
			continue
		}
		cfg := update_config(name, exe, .Apply)
		cfg.no_reexec = true
		r := selfupdate.run(cfg)
		switch r.outcome {
		case .Applied:
			fmt.printfln("updated %s", name)
		case .Refused, .Failed:
			fmt.eprintfln("review: %s: %s", name, selfupdate.message(&r))
			failed = true
		case .Up_To_Date, .Update_Available, .Skipped:
		}
	}
	// The sidecars first: replacing review re-runs it, and nothing after
	// that line runs in this process.
	r := selfupdate.run(update_config("review", "", .Apply))
	remember_check(&r)
	switch r.outcome {
	case .Up_To_Date:
		fmt.printfln("review %s is up to date", VERSION)
	case .Applied:
		fmt.printfln("updated to %s", selfupdate.version(&r))
	case .Update_Available, .Skipped:
		fmt.println(selfupdate.message(&r))
	case .Refused, .Failed:
		fmt.eprintfln("review: %s", selfupdate.message(&r))
		return 1
	}
	return failed ? 1 : 0
}

// notify_update tells a person at a terminal that a newer release is out,
// after the command's own output. It is silent for hooks, agents and pipes,
// where stderr is not a terminal, and whenever REVIEW_NO_UPDATE is set.
notify_update :: proc() {
	if VERSION == "" ||
	   os.get_env("REVIEW_NO_UPDATE", context.temp_allocator) != "" ||
	   !os.is_tty(os.stderr) {
		return
	}
	cfg := update_config("review", "", .Notify)
	cfg.timeout = NOTIFY_TIMEOUT
	r := selfupdate.run(cfg)
	remember_check(&r)
	if hint := update_hint(); hint != "" {
		fmt.eprintln(hint)
	}
}

// remember_check keeps what a check learned. A failed check still counts as
// the day's check, so an offline machine waits a day rather than stalling
// every run on the timeout.
remember_check :: proc(r: ^selfupdate.Result) {
	dir := state_dir()
	if dir == "" {
		return
	}
	avail := filepath.join({dir, UPDATE_FILE}, context.temp_allocator) or_else ""
	switch r.outcome {
	case .Update_Available:
		os.make_directory_all(dir)
		v := selfupdate.version(r)
		_ = os.write_entire_file(avail, transmute([]byte)(v == "" ? "a newer release" : v))
	case .Up_To_Date, .Applied:
		os.remove(avail)
	case .Failed:
		os.make_directory_all(dir)
		stamp := filepath.join({dir, selfupdate.STAMP_FILE}, context.temp_allocator) or_else ""
		_ = os.write_entire_file(stamp, []byte{})
	case .Skipped, .Refused:
	}
}

// update_hint is the line a person sees while a newer release is waiting,
// or "" when none is.
update_hint :: proc() -> string {
	dir := state_dir()
	if dir == "" {
		return ""
	}
	avail := filepath.join({dir, UPDATE_FILE}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(avail, context.temp_allocator)
	v := strings.trim_space(string(data))
	if err != nil || v == "" || v == VERSION {
		return ""
	}
	return fmt.tprintf("review %s is available; run `review update`", v)
}
