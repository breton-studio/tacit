#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test "$@"
