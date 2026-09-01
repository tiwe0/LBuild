#!/usr/bin/env bash
# Mutation-aware contract test for AdvSIMD IR box type queries.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARM64_BACKEND_SOURCE:-"$repo_root/compiler/backend/arm64/arm64.lisp"}

python3 - "$source_file" "${ARM64_BOX_TYPE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
methods = [
    "(defmethod ir:box-type ((instruction box-advsimd-instruction))",
    "(defmethod ir:box-type ((instruction unbox-advsimd-instruction))",
]
missing = [m for m in methods if m not in source]
if missing:
    raise SystemExit("ARM64 AdvSIMD box-type methods missing: " + ", ".join(missing))

if sys.argv[2]:
    # Simulate regression to an unrelated type answer in either method.
    source = source.replace("'mezzano.simd:simd-pack", "'nil")

for method in methods:
    start = source.index(method)
    end = source.find("\n\n(def", start + 1)
    body = source[start:] if end < 0 else source[start:end]
    if "'mezzano.simd:simd-pack" not in body:
        raise SystemExit(f"{method}: expected mezzano.simd:simd-pack return")

print("ARM64 AdvSIMD box-type contract passed")
PY

if [[ -z "${ARM64_BOX_TYPE_MUTATION_RUN:-}" ]]; then
  if ARM64_BOX_TYPE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 AdvSIMD box-type mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 AdvSIMD box-type mutation rejected"
fi
