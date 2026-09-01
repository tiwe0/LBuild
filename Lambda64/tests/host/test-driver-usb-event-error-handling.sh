#!/usr/bin/env bash
# Regression coverage for USB port event error handling.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${USB_DRIVER_SOURCE:-"$repo_root/drivers/usb/usb-driver.lisp"}

python3 - "$source_file" "${USB_EVENT_ERROR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
connect_start = source.index("(defmethod handle-interrupt-event ((type (eql :port-connect))")
disconnect_start = source.index("(defmethod handle-interrupt-event ((type (eql :port-disconnect))")
connect = source[connect_start:disconnect_start]
disconnect_end = source.index("\n\n;;======================================================================", disconnect_start)
disconnect = source[disconnect_start:disconnect_end]
if sys.argv[2]:
    connect = connect.replace("(error (condition)", "(error (condition-disabled)", 1)
    disconnect = disconnect.replace("(error (condition)", "(error (condition-disabled)", 1)
required = [
    (connect, "port-connect"),
    (disconnect, "port-disconnect"),
]
for form, name in required:
    if "(handler-case" not in form or "(error (condition)" not in form:
        raise SystemExit(f"USB {name} error-handler contract missing")
    if "USB " + name + " failed" not in form:
        raise SystemExit(f"USB {name} diagnostic contract missing")
if "TODO - add error handling" in connect or "TODO - add error handling" in disconnect:
    raise SystemExit("USB port event error-handling TODO remains")
print("USB port event error-handling contract passed")
PY

if [[ -z "${USB_EVENT_ERROR_MUTATION_RUN:-}" ]]; then
  if USB_EVENT_ERROR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "USB event error-handling mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "USB event error-handling mutation rejected"
fi
