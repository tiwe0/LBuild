#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src=${HTTP_DEMO_SOURCE:-"$root/net/http-demo.lisp"}

python3 - "$src" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
if __import__("os").environ.get("HTTP_DEMO_PENDING_MUTATION_RUN"):
    source = source.replace("(%untrack-connection server connection)", "nil", 1)
if re.search(r"(?im)^\s*;.*\b(?:TODO|FIXME)\b", source):
    raise SystemExit("HTTP demo TODO/FIXME marker remains")
required = [
    "http-server-connections",
    "%track-connection",
    "%untrack-connection",
    "%abort-pending-connections",
    ":abort t",
    "unwind-protect",
]
for token in required:
    if token not in source:
        raise SystemExit(f"missing pending-connection cancellation contract: {token}")

# The listener must register before dispatch and unregister in an unwind-protect;
# this mutation removes that cleanup and must be rejected by the contract.
if "%untrack-connection server connection" not in source:
    raise SystemExit("connection cleanup call missing")
print("HTTP pending-connection cancellation contract passed")
PY

if [[ -z "${HTTP_DEMO_PENDING_MUTATION_RUN:-}" ]]; then
  if HTTP_DEMO_PENDING_MUTATION_RUN=1 HTTP_DEMO_SOURCE="$src" bash "$0" >/dev/null 2>&1; then
    echo "HTTP pending cancellation mutation unexpectedly survived" >&2
    exit 1
  fi
fi
