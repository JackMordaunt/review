# Standard recipes: build (debug), release, clean, test, install.
# review is the Odin binary; review-go and review-vet are the Go sidecars
# (the Go parser, and go vet's multichecker) and odin-review-extract the
# Odin one. install ships all four beside each other on PATH.
#
#   just deps            fetch the jm submodule and build its SQLite archive
#   just build           debug binaries with ASan               -> build/
#   just release         optimised binaries                     -> build/
#   just test            every package's tests and the Go sidecar's
#   just check           type-check for linux, darwin and windows, debug and release
#   just test-installer  install.sh and install.ps1 against a fake release
#   just install         put the four binaries on PATH
#   just clean           remove build output

odin := env("ODIN", "odin")
root := replace(justfile_directory(), "\\", "/")
# The jm collection: https://mordaunt.dev/code/jm, pinned as the jm
# submodule. JM=<path> builds against another checkout instead.
jm := env("JM", root / "jm")
# The commit a binary is built from, with -dirty when the tree has
# uncommitted changes, so `review version` can say which code it is. The
# value is quoted for odin, since a hash like 21e17ac would otherwise be
# read as a number.
commit := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
dirty := `git status --porcelain 2>/dev/null | head -c 1`
stamp := commit + (if dirty != "" { "-dirty" } else { "" })
flags := "-vet -strict-style -collection:jm=" + jm
review_flags := flags + " -define:COMMIT='\"" + stamp + "\"'"
# `just test SAN=` drops the sanitizer where it gets in the way: on Windows
# its HeapSize hook aborts on memory Windows allocated itself.
san := env("SAN", "-sanitize:address")
# Windows refuses to run an output without its extension, and Odin will not
# write one.
exe := if os() == "windows" { ".exe" } else { "" }
packages := "txt frontend git tree change finding report check analyser job provider cache reviewer hook bench"
targets := "linux_amd64 darwin_arm64 windows_amd64"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# The jm submodule, when JM does not name another checkout, and its SQLite
# archive, which jm:sqlite3 links.
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    if ! ls "{{jm}}"/sqlite3/lib/sqlite3.* >/dev/null 2>&1; then (cd "{{jm}}" && just sqlite); fi

# Debug build: symbols kept, for delve and stack traces.
build: deps
    mkdir -p build
    {{odin}} build review {{review_flags}} -debug {{san}} -out:build/review{{exe}}
    {{odin}} build sidecar/odin {{flags}} -debug -out:build/odin-review-extract{{exe}}
    go build -o build/review-go{{exe}} ./sidecar/gofront
    go build -C sidecar/govet -o ../../build/review-vet{{exe}} .

# Optimised build: stripped, reproducible paths.
release: deps
    mkdir -p build
    {{odin}} build review {{review_flags}} -o:speed -out:build/review{{exe}}
    {{odin}} build sidecar/odin {{flags}} -o:speed -out:build/odin-review-extract{{exe}}
    go build -trimpath -ldflags='-s -w' -o build/review-go{{exe}} ./sidecar/gofront
    go build -C sidecar/govet -trimpath -ldflags='-s -w' -o ../../build/review-vet{{exe}} .

# Type-check, then run every package's tests and the Go sidecar's.
test: deps
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/test/bin
    # The tests that read Odin through the sidecar read this tree's, not
    # whichever one is installed.
    {{odin}} build sidecar/odin {{flags}} -out:build/test/bin/odin-review-extract{{exe}}
    export PATH="$PWD/build/test/bin:$PATH"
    for p in {{packages}}; do
        {{odin}} test $p {{flags}} {{san}} -out:build/test/$p{{exe}}
    done
    go vet ./... && go test ./...

# Type-check both Odin binaries for every target, with and without -debug.
check: deps
    for t in {{targets}}; do \
      for d in "" -debug; do \
        {{odin}} check review {{review_flags}} $d -target:$t || exit 1; \
        {{odin}} check sidecar/odin {{flags}} $d -target:$t || exit 1; \
      done; \
    done

# The installers against a fake release on disk: the release binaries under
# the names CI would publish, a sha256sums.txt beside them, served over
# file://, into a throwaway directory. install.sh runs everywhere;
# install.ps1 installs on Windows and, wherever a PowerShell is on PATH,
# must refuse an asset whose checksum no longer matches. Off Windows its
# .exe cannot run, and PowerShell would hand it to xdg-open.
test-installer: release
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)" in Linux*) os=linux;; Darwin*) os=darwin;; *) os=windows;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; *) arch=arm64;; esac
    # The installers run before any binary exists, so they repeat the
    # release base the binary owns; all three must agree.
    base=$(sed -n 's/^RELEASE_BASE :: "\(.*\)"$/\1/p' review/version.odin)
    [ -n "$base" ] || { echo "FAIL no RELEASE_BASE in review/version.odin"; exit 1; }
    for f in install.sh install.ps1; do grep -qF "$base" "$f" || { echo "FAIL $f does not name $base"; exit 1; }; done
    echo "ok the installers name the release base"
    binaries=(review review-go review-vet odin-review-extract)
    rel="$(mktemp -d)"; bin="$(mktemp -d)"
    trap 'rm -rf "$rel" "$bin"' EXIT
    for b in "${binaries[@]}"; do
      cp "build/$b{{exe}}" "$rel/$b-$os-$arch{{exe}}"
      cp "build/$b{{exe}}" "$rel/$b-windows-amd64.exe"
    done
    (cd "$rel" && { command -v sha256sum >/dev/null && sha256sum ./*-* || shasum -a 256 ./*-*; } | sed 's|\./||' > sha256sums.txt)
    p=$(cygpath -m "$rel" 2>/dev/null || printf '%s' "$rel")
    export REVIEW_RELEASE_BASE="file:///${p#/}"
    w() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
    ps=$(command -v pwsh || command -v powershell || true)
    ps1() { REVIEW_BINDIR="$(w "$1")" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(w "$PWD/install.ps1")"; }

    REVIEW_BINDIR="$bin/sh" sh install.sh >/dev/null
    for b in "${binaries[@]}"; do cmp "$bin/sh/$b{{exe}}" "build/$b{{exe}}"; done
    "$bin/sh/review{{exe}}" version >/dev/null && echo "ok install.sh"
    if [ -n "$ps" ] && [ "$os" = windows ]; then
      ps1 "$bin/ps" >/dev/null
      for b in "${binaries[@]}"; do cmp "$bin/ps/$b.exe" "build/$b.exe"; done
      echo "ok install.ps1"
    fi

    for f in "$rel"/review-go-*; do printf x >> "$f"; done
    if REVIEW_BINDIR="$bin/t" sh install.sh >/dev/null 2>&1; then echo "FAIL install.sh accepted a bad checksum"; exit 1; fi
    [ ! -e "$bin/t/review{{exe}}" ] || { echo "FAIL install.sh installed part of a bad release"; exit 1; }
    echo "ok install.sh refuses a bad checksum"
    if [ -n "$ps" ]; then
      if ps1 "$bin/t2" >/dev/null 2>&1; then echo "FAIL install.ps1 accepted a bad checksum"; exit 1; fi
      echo "ok install.ps1 refuses a bad checksum"
    fi

# Remove build output and the Go build cache for this module.
clean:
    rm -rf build
    go clean

# Copy the release binaries to a directory on PATH: ~/.local/bin, ~/bin,
# /usr/local/bin, else where review already is, else the first writable
# PATH entry. A Go path is never chosen and a copy left in one is removed:
# `go install` put this tool there when it was written in Go, and two
# copies on one PATH is how a stale one gets run.
install: release
    #!/usr/bin/env bash
    set -euo pipefail
    gopath=$(go env GOPATH 2>/dev/null || true); gobin=$(go env GOBIN 2>/dev/null || true)
    go_paths=()
    [[ -n $gobin ]] && go_paths+=("$gobin")
    [[ -n $gopath ]] && go_paths+=("$gopath/bin")
    is_go_path() {
        local d
        for d in ${go_paths+"${go_paths[@]}"}; do [[ $1 == "$d" ]] && return 0; done
        return 1
    }
    dest=""
    for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
        [[ -z $dest && -d $d && -w $d && ":$PATH:" == *":$d:"* ]] && dest=$d
    done
    if [[ -z $dest ]] && existing=$(command -v review 2>/dev/null); then
        [[ -w ${existing%/*} ]] && ! is_go_path "${existing%/*}" && dest=${existing%/*}
    fi
    if [[ -z $dest ]]; then
        IFS=: read -ra dirs <<<"$PATH"
        for d in "${dirs[@]}"; do
            [[ -d $d && -w $d ]] && ! is_go_path "$d" && { dest=$d; break; }
        done
    fi
    [[ -n $dest ]] || { echo "install: no writable directory on PATH" >&2; exit 1; }
    binaries=(review review-go review-vet odin-review-extract)
    for bin in "${binaries[@]}"; do
        install -m 755 build/$bin{{exe}} "$dest/$bin{{exe}}"
    done
    echo "installed ${binaries[*]} into $dest"
    for d in ${go_paths+"${go_paths[@]}"}; do
        [[ $d == "$dest" ]] && continue
        for bin in "${binaries[@]}"; do
            [[ -f $d/$bin{{exe}} ]] && rm -f "$d/$bin{{exe}}" && echo "removed the older $d/$bin{{exe}}"
        done
    done
    true
