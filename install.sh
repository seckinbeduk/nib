#!/bin/bash
# Build nib and put it on your PATH.
#   ./install.sh                  installs to /opt/homebrew/bin, or ~/.local/bin
#   PREFIX=/usr/local ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "Building nib (release)…"
mkdir -p .build
if ! swift build -c release --product nib > .build/release.log 2>&1; then
  grep -E "error:" .build/release.log | sort -u | head -40
  echo "❌ Build failed (full log: .build/release.log)"
  exit 1
fi
BIN="$(swift build -c release --show-bin-path)/nib"

if [[ -n "${PREFIX:-}" ]]; then
  DEST="$PREFIX/bin"
elif [[ -w /opt/homebrew/bin ]]; then
  DEST=/opt/homebrew/bin
else
  DEST="$HOME/.local/bin"
fi
mkdir -p "$DEST"
install -m 755 "$BIN" "$DEST/nib"
echo "✅ Installed $DEST/nib"

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "   $DEST isn't on your PATH. Add this to your shell profile:"
     echo "   export PATH=\"$DEST:\$PATH\"" ;;
esac
"$DEST/nib" doctor || true
