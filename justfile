# Standard recipes: build (debug), release, clean, test, install.
# install also builds review-vet, the go vet sidecar that `go-vet/<analyzer>`
# findings use when it sits beside review on PATH, and review-go, the Go
# parser sidecar the Odin reading under odin/ drives.
# odin-test and odin-build cover the Odin reading; they need the jfm
# collection at ~/Source/Personal/odin and review-go on PATH.

bin := "review"
odin := env("ODIN", "odin")
odin_flags := "-vet -strict-style -collection:jfm=" + home_directory() / "Source" / "Personal" / "odin"

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Debug build: symbols kept, for delve and stack traces.
build:
    go build -o {{bin}} .
    go build -C sidecar/govet -o ../../{{bin}}-vet .
    go build -o {{bin}}-go ./sidecar/gofront

# Optimised build: stripped, reproducible paths.
release:
    go build -trimpath -ldflags='-s -w' -o {{bin}} .
    go build -C sidecar/govet -trimpath -ldflags='-s -w' -o ../../{{bin}}-vet .
    go build -trimpath -ldflags='-s -w' -o {{bin}}-go ./sidecar/gofront

# Vet and run the tests.
test:
    go vet ./...
    go test ./...

# Remove build output and the Go build cache for this module.
clean:
    rm -f {{bin}} {{bin}}-vet {{bin}}-go
    rm -rf build
    go clean

# Test the Odin reading, package by package.
odin-test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    for p in txt frontend git tree change finding report check analyser job provider cache reviewer hook bench; do
        {{odin}} test odin/$p {{odin_flags}} -out:build/${p}_test
    done

# Debug build of the Odin reading -> build/review-odin
odin-build:
    mkdir -p build
    {{odin}} build odin/review {{odin_flags}} -debug -out:build/review-odin

# Copy the release binary to a directory on PATH. An installed copy is replaced in
# place; otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin, /usr/local/bin, else the
# first writable PATH entry.
install: release
    #!/usr/bin/env bash
    set -euo pipefail
    dest=""
    if existing=$(command -v {{bin}} 2>/dev/null) && [[ -w ${existing%/*} ]]; then
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
    install -m 755 {{bin}} "$dest/{{bin}}"
    install -m 755 {{bin}}-vet "$dest/{{bin}}-vet"
    install -m 755 {{bin}}-go "$dest/{{bin}}-go"
    echo "installed $dest/{{bin}}, $dest/{{bin}}-vet and $dest/{{bin}}-go"
