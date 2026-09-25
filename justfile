# Standard recipes: build (debug), release, clean, test, install.
# review is the Odin binary; review-go and review-vet are the Go sidecars
# (the Go parser, and go vet's multichecker) and odin-review-extract the
# Odin one. install ships all four beside each other on PATH. The Odin
# packages need the jm collection at ~/Source/Personal/jm.

odin := env("ODIN", "odin")
flags := "-vet -strict-style -collection:jm=" + home_directory() / "Source" / "Personal" / "jm"
packages := "txt frontend git tree change finding report check analyser job provider cache reviewer hook bench"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Debug build: symbols kept, for delve and stack traces.
build:
    mkdir -p build
    {{odin}} build review {{flags}} -debug -sanitize:address -out:build/review
    {{odin}} build sidecar/odin {{flags}} -debug -out:build/odin-review-extract
    go build -o build/review-go ./sidecar/gofront
    go build -C sidecar/govet -o ../../build/review-vet .

# Optimised build: stripped, reproducible paths.
release:
    mkdir -p build
    {{odin}} build review {{flags}} -o:speed -out:build/review
    {{odin}} build sidecar/odin {{flags}} -o:speed -out:build/odin-review-extract
    go build -trimpath -ldflags='-s -w' -o build/review-go ./sidecar/gofront
    go build -C sidecar/govet -trimpath -ldflags='-s -w' -o ../../build/review-vet .

# Type-check, then run every package's tests and the Go sidecar's.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/test
    for p in {{packages}}; do
        {{odin}} test $p {{flags}} -sanitize:address -out:build/test/$p
    done
    go vet ./... && go test ./...

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
        install -m 755 build/$bin "$dest/$bin"
    done
    echo "installed ${binaries[*]} into $dest"
    for d in ${go_paths+"${go_paths[@]}"}; do
        [[ $d == "$dest" ]] && continue
        for bin in "${binaries[@]}"; do
            [[ -f $d/$bin ]] && rm -f "$d/$bin" && echo "removed the older $d/$bin"
        done
    done
    true
