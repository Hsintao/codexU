#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make build >/dev/null
build/CodexU.app/Contents/MacOS/CodexU --self-test-rate-limits
