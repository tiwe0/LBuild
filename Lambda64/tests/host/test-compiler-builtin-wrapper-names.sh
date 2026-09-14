#!/usr/bin/env bash
# Every builtin that claims a wrapper must have a callable function name.
#
# GENERATE-BUILTIN-FUNCTIONS emits (%DEFUN name lambda) for each builtin with
# :HAS-WRAPPER true.  VALID-FUNCTION-NAME-P admits only symbols, (SETF x) and
# (CAS x), and COLD-START's fref hookup ECASEs over exactly those, so a wrapper
# named with any other prefix aborts the cold boot with
# "DCAS fell through ECASE form".  ARM64's double-width CAS is the only
# list-named builtin outside that set; x86-64 exposes the same operation
# through symbol-named builtins.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

python3 - "$repo_root" "${BUILTIN_WRAPPER_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

root = Path(sys.argv[1])
mutate = bool(sys.argv[2])

# Prefixes COLD-START and VALID-FUNCTION-NAME-P accept for compound names.
allowed = {"setf", "cas"}

runtime = (root / "system/runtime-support.lisp").read_text(encoding="utf-8")
m = re.search(r"\(cons \(member ([a-z ]+)\)", runtime)
if m:
    declared = set(m.group(1).split())
    if declared != allowed:
        raise SystemExit(
            f"VALID-FUNCTION-NAME-P now admits {sorted(declared)}; update this test "
            "and COLD-START's ECASE together")

bad = []
for path in (root / "compiler/backend").rglob("*.lisp"):
    text = path.read_text(encoding="utf-8", errors="ignore")
    if mutate and path.name == "memory.lisp":
        text = text.replace("     :has-wrapper nil)", "     )", 1)
    for m in re.finditer(r"\(define-builtin\s+\(([\w.:%-]+)\s+[^)]*\)\s*\n?\s*\(([^\n]*)", text):
        head = m.group(1).split("::")[-1].lower()
        if head in allowed:
            continue
        # A non-setf/cas compound name is only legal with no wrapper.
        tail = text[m.start():m.start() + 500]
        if ":has-wrapper nil" not in tail:
            bad.append(f"{path.name}: ({m.group(1)} ...)")

if bad:
    raise SystemExit(
        "builtin(s) with an uncallable compound name claim a wrapper: "
        + ", ".join(sorted(set(bad))))
print("builtin wrapper name contract passed")
PY

if [[ -z "${BUILTIN_WRAPPER_MUTATION_RUN:-}" ]]; then
  if BUILTIN_WRAPPER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "builtin wrapper name mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "builtin wrapper name mutation rejected"
fi
