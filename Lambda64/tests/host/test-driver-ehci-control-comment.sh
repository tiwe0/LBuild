#!/usr/bin/env bash
# Regression coverage for the EHCI control-transfer contract documentation.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${EHCI_SOURCE:-"$repo_root/drivers/usb/ehci-intel.lisp"}

python3 - "$source_file" "${EHCI_CONTROL_COMMENT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index(";; control-receive-data")
end = source.index("\n\n(defun control-timed-wait", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("Control requests that do not receive data", "Control requests that receive data", 1)
required = [
    "Control requests that do not receive data, such as set address and set",
    "configuration, use a zero length and a one-byte scratch buffer.",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("EHCI control-transfer documentation contract missing: " + ", ".join(missing))
if "TODO is this comment still valid" in form:
    raise SystemExit("EHCI control-transfer TODO remains")
print("EHCI control-transfer documentation contract passed")
PY

if [[ -z "${EHCI_CONTROL_COMMENT_MUTATION_RUN:-}" ]]; then
  if EHCI_CONTROL_COMMENT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "EHCI control-transfer documentation mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "EHCI control-transfer documentation mutation rejected"
fi
