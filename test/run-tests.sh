#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/bin/omarchy-branch-watch-check" "$ROOT/bin/branch-watch-probe"
/usr/bin/python3 "$ROOT/test/matrix-tests.py"
/usr/bin/python3 "$ROOT/test/qml-smoke.py"
