#!/usr/bin/env bash
# Regression coverage for NaN-safe x86 single/double float equality lowering.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_file=${FLOAT_EQUALITY_SOURCE:-"$repo_root/compiler/backend/x86-64/number.lisp"}

python3 - "$source_file" "${FLOAT_EQUALITY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import math
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Deliberately remove the parity guard from one builtin; the contract must reject it.
    source = source.replace("lap:cmov64p", "lap:cmov64ne", 1)

for kind, compare, compare_op in (("single", "ucomiss", "%%single-float-="),
                                  ("double", "ucomisd", "%%double-float-=")):
    match = re.search(r"\(define-builtin sys\.int::%s.*?(?=\n\(define-builtin|\Z)" % re.escape(compare_op), source, re.S)
    if not match:
        raise SystemExit(f"{kind}-float equality builtin missing")
    body = match.group(0)
    if "TODO: This needs to check two conditions" in body:
        raise SystemExit(f"stale {kind}-float equality TODO remains")
    # Constant and general-operand paths each perform one compare and two guards.
    if body.count(f"lap:{compare}") != 2:
        raise SystemExit(f"{kind}-float equality must compare once per lowering path with {compare}")
    if body.count("lap:cmov64p") != 2 or body.count("lap:cmov64ne") != 2:
        raise SystemExit(f"{kind}-float equality must gate each path with PF and NE")
    if any(part.index("lap:cmov64p") > part.index("lap:cmov64ne")
           for part in body.split("(define-builtin ")[1:]):
        raise SystemExit(f"{kind}-float equality condition order is not PF then NE")

# Executable IEEE contract: equality is false whenever either operand is unordered.
def equal(lhs, rhs):
    return not (math.isnan(lhs) or math.isnan(rhs)) and lhs == rhs
for lhs, rhs, expected in ((1.0, 1.0, True), (1.0, 2.0, False),
                           (math.nan, math.nan, False), (math.nan, 1.0, False),
                           (1.0, math.nan, False)):
    if equal(lhs, rhs) is not expected:
        raise SystemExit("NaN-safe float equality model failed")
print("x86 single/double float equality contract passed")
PY

if [[ -z "${FLOAT_EQUALITY_MUTATION_RUN:-}" ]]; then
  if FLOAT_EQUALITY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "x86 float equality mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "x86 float equality mutation rejected"
fi
