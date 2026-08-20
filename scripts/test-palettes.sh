#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
make build
"build/CodexU.app/Contents/MacOS/CodexU" --self-test-palettes
