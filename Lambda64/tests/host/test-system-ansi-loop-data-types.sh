#!/usr/bin/env bash
# LOOP's generated accumulator/list bindings intentionally remain untyped.
# This contract protects the compiler-compatibility decision at ansi-loop.lisp:150/154.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ANSI_LOOP_SOURCE:-"$repo_root/system/ansi-loop.lisp"}

python3 - "$source_file" "${ANSI_LOOP_DATA_TYPES_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "(defvar *loop-real-data-type* 't)",
    "(defvar *loop-list-data-type* 't)",
    "the compiler treats declarations as assumptions",
    "A user supplied :BY function is opaque to LOOP",
]
missing = [token for token in required if token not in source]
if "FIXME: This used to be 'real" in source or "FIXME: Likewise, but 'list" in source:
    missing.append("stale FIXME marker")

# Mutation-aware: either narrowing must be rejected by this contract test.
if sys.argv[2]:
    mutated = source.replace("(defvar *loop-real-data-type* 't)",
                             "(defvar *loop-real-data-type* 'real)", 1)
    mutated = mutated.replace("(defvar *loop-list-data-type* 't)",
                              "(defvar *loop-list-data-type* 'list)", 1)
    missing = [token for token in required if token not in mutated]

if missing:
    raise SystemExit("LOOP data-type compatibility contract missing: " + ", ".join(missing))
print("LOOP data-type compatibility contract passed")
PY

if [[ -z "${ANSI_LOOP_DATA_TYPES_MUTATION_RUN:-}" ]]; then
  if ANSI_LOOP_DATA_TYPES_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "LOOP data-type narrowing mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "LOOP data-type narrowing mutation rejected"
fi
