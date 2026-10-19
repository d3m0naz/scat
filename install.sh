#!/usr/bin/env bash
# Installs scat from a GitHub release. Downloads the source archive, checks
# its SHA-256 against the value pinned below, then installs into
# $SCAT_PREFIX (default ~/.local) and links bin/scat to it.
#
#   curl -fsSL https://raw.githubusercontent.com/d3m0naz/scat/main/install.sh | bash
#
# Set SCAT_PREFIX to change the install location.

set -euo pipefail

VERSION=0.2.3
SHA256=76d3dd849a734daeafa070998edca04fc36c69c5d64e9579a910a77a5dff15bb
URL=https://github.com/d3m0naz/scat/releases/download/v$VERSION/scat-$VERSION.tar.gz

PREFIX=${SCAT_PREFIX:-$HOME/.local}
SHARE=$PREFIX/share/scat-$VERSION
BIN=$PREFIX/bin/scat

if (( BASH_VERSINFO[0] < 5 )); then
    echo "scat needs Bash 5 or newer. Install it with: brew install bash" >&2
    echo "then put /opt/homebrew/bin first in PATH." >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha_cmd=(sha256sum)
else
    sha_cmd=(shasum -a 256)
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading scat $VERSION ..."
curl -fsSL "$URL" -o "$tmp/scat.tar.gz"

actual=$("${sha_cmd[@]}" "$tmp/scat.tar.gz" | awk '{print $1}')
if [[ $actual != "$SHA256" ]]; then
    echo "Checksum mismatch, nothing installed." >&2
    echo "  expected $SHA256" >&2
    echo "  got      $actual" >&2
    exit 1
fi

tar -xzf "$tmp/scat.tar.gz" -C "$tmp"

rm -rf "$SHARE"
mkdir -p "$(dirname -- "$SHARE")" "$(dirname -- "$BIN")"
mv "$tmp/scat-$VERSION" "$SHARE"
ln -sfn "$SHARE/scat" "$BIN"

echo "Installed: $BIN"
case ":$PATH:" in
    *":$(dirname -- "$BIN"):"*) ;;
    *) echo "Add $(dirname -- "$BIN") to your PATH to run scat." ;;
esac
echo "Run: scat --help"
