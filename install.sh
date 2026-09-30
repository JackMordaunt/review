#!/bin/sh
# review installer for Linux, macOS and Git Bash. It downloads the four
# binaries for this machine — review and the sidecars it reads Go and Odin
# through — checks every sha256 before installing any, and puts them side
# by side on PATH.
#
#   curl -fsSL https://mordaunt.dev/code/review/install.sh | sh
#
# REVIEW_VERSION pins a release tag; REVIEW_BINDIR picks the directory
# (default ~/.local/bin); REVIEW_RELEASE_BASE overrides the download URL.

set -eu

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

base=${REVIEW_RELEASE_BASE:-}
if [ -z "$base" ]; then
  if [ -n "${REVIEW_VERSION:-}" ]; then
    base="https://github.com/jackmordaunt/review/releases/download/$REVIEW_VERSION"
  else
    base="https://github.com/jackmordaunt/review/releases/latest/download"
  fi
fi

case "$(uname -s)" in
  Linux*)                os=linux ;;
  Darwin*)               os=darwin ;;
  MINGW*|MSYS*|CYGWIN*)  os=windows ;;
  *)                     fail "unsupported system: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)   arch=amd64 ;;
  aarch64|arm64)  arch=arm64 ;;
  *)              fail "unsupported architecture: $(uname -m)" ;;
esac
ext=""
if [ "$os" = windows ]; then ext=.exe; fi
bindir=${REVIEW_BINDIR:-$HOME/.local/bin}
binaries="review review-go review-vet odin-review-extract"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else fail "neither curl nor wget is installed"; fi
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else fail "neither sha256sum nor shasum is installed"; fi
}

printf 'fetching review for %s-%s from %s\n' "$os" "$arch" "$base"
fetch "$base/sha256sums.txt" "$work/sha256sums.txt" || fail "no checksum file"
for b in $binaries; do
  asset="$b-$os-$arch$ext"
  fetch "$base/$asset" "$work/$asset" || fail "download of $asset failed"
  # Accept an optional * before the name, which sha256sum prints in binary mode.
  want=$(grep "[[:space:]]\*\{0,1\}$asset\$" "$work/sha256sums.txt" | cut -d' ' -f1)
  [ -n "$want" ] || fail "$asset is not in sha256sums.txt"
  [ "$(sha256 "$work/$asset")" = "$want" ] || fail "checksum mismatch for $asset"
done

mkdir -p "$bindir"
for b in $binaries; do
  mv -f "$work/$b-$os-$arch$ext" "$bindir/$b$ext"
  chmod +x "$bindir/$b$ext"
done
printf 'installed %s into %s\n' "$binaries" "$bindir"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf 'add %s to your PATH\n' "$bindir" ;;
esac
"$bindir/review$ext" version
