#!/usr/bin/env bash
# Regression coverage for ARM64 load/store pair opcode classification.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-arm64.lisp"}
python3 - "$source_file" "${ARM64_PAIR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun load/store-pair")
end = source.index("\n\n;; Load register (literal)", start)
decoder = source[start:end]
if sys.argv[2]:
    # Mutate the non-temporal load branch; the contract must reject it.
    decoder = decoder.replace(":ldnp", ":stnp", 1)
required = [
    "(if non-temporal",
    ":ldnp",
    ":stnp",
    "(eql (ldb (byte 2 30) word) 1)",
    ":ldpws",
    "'a64:ldp",
    "'a64:stp",
]
missing = [token for token in required if token not in decoder]
if missing:
    raise SystemExit("ARM64 load/store pair contract missing: " + ", ".join(missing))
if "lap todo" in decoder.lower() or "TODO" in decoder or "FIXME" in decoder:
    raise SystemExit("ARM64 load/store pair stale marker remains")
if sys.argv[2] and ":ldnp" not in decoder:
    raise SystemExit("ARM64 pair mutation unexpectedly survived")
print("ARM64 load/store pair opcode contract passed")
PY
if [[ -z "${ARM64_PAIR_MUTATION_RUN:-}" ]]; then
  if ARM64_PAIR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 pair decoder mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 pair decoder mutation rejected"
fi
