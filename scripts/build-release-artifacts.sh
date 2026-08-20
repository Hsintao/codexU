#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"

if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "Requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi

make memory-risk-check
plutil -lint Resources/Info.plist
git diff --check

make test-macos-compatibility
make build >/dev/null
CODEXU_SKIP_BUILD=1 ./scripts/test-history-index.sh
build/CodexU.app/Contents/MacOS/CodexU --self-test-statistics-time-zone
build/CodexU.app/Contents/MacOS/CodexU --self-test-token-counter
build/CodexU.app/Contents/MacOS/CodexU --self-test-app-server-pipe
build/CodexU.app/Contents/MacOS/CodexU --self-test-claude-skill-paths
build/CodexU.app/Contents/MacOS/CodexU --self-test-status-item
build/CodexU.app/Contents/MacOS/CodexU --self-test-rate-limits
build/CodexU.app/Contents/MacOS/CodexU --self-test-particle-animation
build/CodexU.app/Contents/MacOS/CodexU --self-test-updates
./scripts/test-parsers.sh

make release-all

verify_asset() {
  local arch="$1"
  local expected_arch="$2"
  local dmg="dist/codexU-${VERSION}-mac-${arch}.dmg"
  local checksum="${dmg}.sha256"
  local mount_dir

  [[ -f "$dmg" ]] || { echo "Missing release asset: $dmg" >&2; exit 1; }
  [[ -f "$checksum" ]] || { echo "Missing checksum: $checksum" >&2; exit 1; }
  shasum -a 256 -c "$checksum"
  hdiutil verify "$dmg" >/dev/null

  mount_dir="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  file "$mount_dir/CodexU.app/Contents/MacOS/CodexU" | grep -q "$expected_arch"
  codesign --verify --deep --strict "$mount_dir/CodexU.app"
  hdiutil detach "$mount_dir" >/dev/null
  rmdir "$mount_dir"
}

verify_asset arm64 arm64
verify_asset x86_64 x86_64

echo "Release artifacts verified for codexU $VERSION"
cat "dist/codexU-${VERSION}-mac-arm64.dmg.sha256"
cat "dist/codexU-${VERSION}-mac-x86_64.dmg.sha256"
