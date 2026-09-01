#!/usr/bin/env bash
# Regression coverage for RTL8168 DMA buffer allocation checks.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RTL8168_SOURCE:-"$repo_root/drivers/rtl8168.lisp"}

python3 - "$source_file" "${RTL8168_BUFFER_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun rtl8168-reset")
end = source.index("\n\n(defun rtl8168", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(unless (and", "(when (and", 1)
required = [
    "(unless (and",
    "(rtl8168-tx-ring-phys nic)",
    "(rtl8168-rx-ring-phys nic)",
    "(rtl8168-tx-bounce-phys nic)",
    "(rtl8168-rx-bounce-phys nic)",
    "RTL8168 DMA buffers are not fully allocated",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("RTL8168 buffer-allocation contract missing: " + ", ".join(missing))
if "FIXME: Verify that all buffers were allocated." in form:
    raise SystemExit("RTL8168 buffer-allocation FIXME remains")
print("RTL8168 buffer-allocation contract passed")
PY

if [[ -z "${RTL8168_BUFFER_MUTATION_RUN:-}" ]]; then
  if RTL8168_BUFFER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "RTL8168 buffer-allocation mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "RTL8168 buffer-allocation mutation rejected"
fi
