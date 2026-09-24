# Standard recipes: build (debug), release, clean, test, install.
# review is the Odin binary; review-go and review-vet are the Go sidecars
# (the Go parser, and go vet's multichecker) and odin-review-extract the
# Odin one. install ships all four beside each other on PATH. The Odin
# packages need the jfm collection at ~/Source/Personal/odin.

odin := env("ODIN", "odin")
flags := "-vet -strict-style -collection:jfm=" + home_directory() / "Source" / "Personal" / "odin"
packages := "txt frontend git tree change finding report check analyser job provider cache reviewer hook bench"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Debug build: symbols kept, for delve and stack traces.
build:
    mkdir -p build
    {{odin}} build review {{flags}} -debug -out:build/review
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
        {{odin}} test $p {{flags}} -out:build/test/$p
    done
    go vet ./... && go test ./...

# Remove build output and the Go build cache for this module.
clean:
    rm -rf build
    go clean

# Copy the release binaries to a directory on PATH. An installed review is
# replaced in place; otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin,
# /usr/local/bin, else the first writable PATH entry.
install: release
    #!/usr/bin/env bash
    set -euo pipefail
    dest=""
    if existing=$(command -v review 2>/dev/null) && [[ -w ${existing%/*} ]]; then
        dest=${existing%/*}
    fi
    gopath=$(go env GOPATH 2>/dev/null || true); gobin=$(go env GOBIN 2>/dev/null || true)
    for d in "$HOME/.local/bin" "$HOME/bin" "$gobin" "${gopath:+$gopath/bin}" /usr/local/bin; do
        [[ -z $dest && -n $d && -d $d && -w $d && ":$PATH:" == *":$d:"* ]] && dest=$d
    done
    if [[ -z $dest ]]; then
        IFS=: read -ra dirs <<<"$PATH"
        for d in "${dirs[@]}"; do [[ -d $d && -w $d ]] && { dest=$d; break; }; done
    fi
    [[ -n $dest ]] || { echo "install: no writable directory on PATH" >&2; exit 1; }
    for bin in review review-go review-vet odin-review-extract; do
        install -m 755 build/$bin "$dest/$bin"
    done
    echo "installed review, review-go, review-vet and odin-review-extract into $dest"
