#!/usr/bin/env bash
# The obsolete-instance forwarding path must copy a funcallable instance's
# entry point with the RAW accessor.
#
# +FUNCTION-ENTRY-POINT+ holds a code address, not a Lisp value.  Copying it
# with %OBJECT-REF-T inside TRANSPORT-OBJECT hands the collector that address
# as a root: it is scavenged like any other reference and the forwarded result
# written back, so the instance ends up pointing at a tagged object.  Calling
# it faults with ESR EC 0x22 (PC alignment).  The neighbouring
# +FUNCALLABLE-INSTANCE-FUNCTION+ slot is boxed and must keep the tagged one.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${GC_SOURCE:-"$repo_root/system/gc.lisp"}

python3 - "$source_file" "${GC_FORWARD_ENTRY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace(
        "(setf (%object-ref-unsigned-byte-64 new-instance +function-entry-point+)\n"
        "                  (%object-ref-unsigned-byte-64 object +function-entry-point+))",
        "(setf (%object-ref-t new-instance +function-entry-point+)\n"
        "                  (%object-ref-t object +function-entry-point+))", 1)

start = source.index("(when (funcallable-instance-p object)")
block = source[start:start + 1400]

if re.search(r"\(%object-ref-t\s+\w+\s+\+function-entry-point\+\)", block):
    raise SystemExit(
        "funcallable-instance entry point forwarded with the tagged accessor; "
        "use %OBJECT-REF-UNSIGNED-BYTE-64 so the collector does not treat the "
        "code address as a reference")
if not re.search(r"\(%object-ref-unsigned-byte-64\s+new-instance\s+\+function-entry-point\+\)", block):
    raise SystemExit("entry point is not forwarded at all")
if not re.search(r"\(%object-ref-t\s+new-instance\s+\+funcallable-instance-function\+\)", block):
    raise SystemExit(
        "the boxed +FUNCALLABLE-INSTANCE-FUNCTION+ slot must keep the tagged accessor")
print("funcallable-instance forwarding accessor contract passed")
PY

if [[ -z "${GC_FORWARD_ENTRY_MUTATION_RUN:-}" ]]; then
  if GC_FORWARD_ENTRY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "funcallable-instance forwarding mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "funcallable-instance forwarding mutation rejected"
fi
