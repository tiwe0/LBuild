#!/usr/bin/env bash
# SUPERSEDE-INSTANCE must test its CAS results by comparing the returned value.
#
# SYS.INT::CAS returns the previous contents of the place, not a success flag
# (see the (EQL (CAS ...) expected) idiom throughout supervisor/sync.lisp).
# Using the result as a boolean inverts the test: a successful swap of a NIL
# place reports false and a failed swap reports true.  On the already-obsolete
# branch the place is non-NIL by definition, so a NIL-expected CAS can never
# succeed -- and the inverted test reported that as success.  A second
# CHANGE-CLASS on one object then did nothing at all, which is what ASDF's
# RESET-SYSTEM-CLASS performs, leaving every system stuck as a PROTO-SYSTEM.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${INSTANCE_SOURCE:-"$repo_root/runtime/instance.lisp"}

python3 - "$source_file" "${SUPERSEDE_CAS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Historical defect: use the CAS result directly as a boolean.
    source = source.replace("""(when (eql (sys.int::cas (sys.int::layout-new-instance layout)
                                     current replacement)
                       current)""",
                            """(when (sys.int::cas (sys.int::layout-new-instance layout)
                                     current replacement)""", 1)

start = source.index("(defun supersede-instance")
end = source.index("\n(in-package", start)
form = source[start:end]

cas_calls = len(re.findall(r"sys\.int::cas\b", form))
if cas_calls == 0:
    raise SystemExit("SUPERSEDE-INSTANCE no longer uses CAS")

# Every CAS in this function must be consumed by an EQL against the expected
# old value rather than used directly as a generalised boolean.
bare = re.findall(r"\(when\s+\(sys\.int::cas\b", form)
if bare:
    raise SystemExit(
        f"{len(bare)} CAS result(s) in SUPERSEDE-INSTANCE used as a boolean; "
        "compare against the expected old value instead")

eql_tested = len(re.findall(r"\(eql\s+\(sys\.int::cas\b", form))
if eql_tested != cas_calls:
    raise SystemExit(
        f"SUPERSEDE-INSTANCE has {cas_calls} CAS call(s) but only "
        f"{eql_tested} are EQL-tested")

# The already-obsolete branch must not expect NIL: the slot is non-NIL there.
if re.search(r"\(sys\.int::cas\s+\(sys\.int::layout-new-instance\s+layout\)\s*\n?\s*nil\b", form):
    raise SystemExit(
        "the already-obsolete branch CASes LAYOUT-NEW-INSTANCE from NIL, "
        "which can never succeed")

print(f"supersede-instance CAS contract passed ({cas_calls} CAS sites)")
PY

if [[ -z "${SUPERSEDE_CAS_MUTATION_RUN:-}" ]]; then
  if SUPERSEDE_CAS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "supersede-instance CAS mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "supersede-instance CAS mutation rejected"
fi
