#!/usr/bin/env bash
# Ensure DMA-backed USB descriptor fields are read only under with-hcd-access.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${USB_DRIVER_SOURCE:-"$repo_root/drivers/usb/usb-driver.lisp"}

python3 - "$source_file" "${USB_HCD_ACCESS_GUARD_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Mutation removes the newly required guard forms.  The contract below
    # must reject this variant rather than merely checking marker text.
    source = source.replace("(with-hcd-access (usbd)", "(without-hcd-access (usbd)")

required = [
    "(with-hcd-access (usbd)\n                     (setf (usb-device-desc-size device)",
    "(with-hcd-access (usbd)\n             (vector (sys.int::ub16ref/le device-desc",
    "(let ((config-bytes (with-hcd-access (usbd)",
]
for fragment in required:
    if fragment not in source:
        raise SystemExit(f"missing HCD access guard: {fragment}")
print("USB HCD DMA access guards passed")
PY

if [[ -z "${USB_HCD_ACCESS_GUARD_MUTATION_RUN:-}" ]]; then
  if USB_HCD_ACCESS_GUARD_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "USB HCD access guard mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "USB HCD access guard mutation rejected"
fi
