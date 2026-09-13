#!/usr/bin/env bash
# MOST-POSITIVE-FIXNUM / MOST-NEGATIVE-FIXNUM must exist in the target image and
# agree with the cross-compiler's copies.
#
# CROSS-BOOT.LISP defines them for the host cross-compile only.  Without a
# target-side definition every reader-evaluated #.MOST-POSITIVE-FIXNUM fails
# with an unbound variable -- ASDF does exactly this, so stage-four dependency
# loading died partway through compiling ASDF.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

python3 - "$repo_root" "${FIXNUM_LIMITS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

root = Path(sys.argv[1])
target = (root / "system/data-types.lisp").read_text(encoding="utf-8")
cross = (root / "compiler/cross-boot.lisp").read_text(encoding="utf-8")
if sys.argv[2]:
    target = re.sub(r"\(defconstant most-positive-fixnum[^\n]*\n", "", target, count=1)

m = re.search(r"\(defconstant \+n-fixnum-bits\+ (\d+)\)", target)
if not m:
    raise SystemExit("+N-FIXNUM-BITS+ not found in data-types.lisp")
tag_bits = int(m.group(1))
expected_pos = (1 << (64 - tag_bits - 1)) - 1
expected_neg = -(1 << (64 - tag_bits - 1))

for name in ("most-positive-fixnum", "most-negative-fixnum"):
    if not re.search(rf"\(defconstant {name}\s", target):
        raise SystemExit(f"{name.upper()} is not defined for the target image")

# The cross-compiler's values are literal; they must match the derived ones.
cm = re.search(r"\(defconstant sys\.int::most-positive-fixnum \(- \(expt 2 (\d+)\) 1\)\)", cross)
if not cm:
    raise SystemExit("cross-boot MOST-POSITIVE-FIXNUM not in the expected form")
cross_pos = (2 ** int(cm.group(1))) - 1
if cross_pos != expected_pos:
    raise SystemExit(
        f"cross-compiler fixnum range {cross_pos} disagrees with the target's "
        f"{expected_pos} derived from +N-FIXNUM-BITS+ = {tag_bits}")

print(f"fixnum limit contract passed (tag bits {tag_bits}, "
      f"most-positive-fixnum {expected_pos})")
PY

if [[ -z "${FIXNUM_LIMITS_MUTATION_RUN:-}" ]]; then
  if FIXNUM_LIMITS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "fixnum limit mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "fixnum limit mutation rejected"
fi
