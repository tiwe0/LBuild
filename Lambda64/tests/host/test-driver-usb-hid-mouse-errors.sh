#!/usr/bin/env bash
# Regression coverage for HID mouse probe diagnostics.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${HID_MOUSE_SOURCE:-"$repo_root/drivers/usb/hid-mouse.lisp"}

python3 - "$source_file" "${HID_MOUSE_ERROR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun convert-collection")
end = source.index("\n\n(defun", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace(
        '(sup:debug-print-line\n             "HID mouse probe failed because report id came after first field; report id "\n             value)',
        ';; diagnostic removed',
        1,
    )
required = [
    '(sup:debug-print-line\n             "HID mouse probe failed because report id came after first field; report id "\n             value)',
    '(throw :probe-failed :failed)',
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("HID mouse probe diagnostic contract missing: " + ", ".join(missing))
if "TODO - print error message" in form:
    raise SystemExit("HID mouse probe diagnostic TODO remains")
print("HID mouse probe diagnostic contract passed")
PY

if [[ -z "${HID_MOUSE_ERROR_MUTATION_RUN:-}" ]]; then
  if HID_MOUSE_ERROR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "HID mouse diagnostic mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "HID mouse diagnostic mutation rejected"
fi
