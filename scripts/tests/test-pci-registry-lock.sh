#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
source="$root/Lambda64/supervisor/pci.lisp"

python3 - "$source" <<'PY'
import pathlib, sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def body(name):
    start = text.index("(defun " + name)
    end = text.find("\n(defun ", start + 1)
    return text[start:] if end < 0 else text[start:end]

required = [
    "(sys.int::defglobal *pci-registry-lock* :unlocked)",
    "(defmacro with-pci-registry-lock",
    "(sup:with-symbol-spinlock (*pci-registry-lock*)",
    "(setf *pci-registry-lock* :unlocked)",
]
missing = [item for item in required if item not in text]
if missing:
    raise AssertionError("PCI registry lock contract missing: " + ", ".join(missing))

for name in ("map-pci-devices", "pci-late-probe", "probe-pci-driver", "register-pci-driver"):
    if "(with-pci-registry-lock" not in body(name):
        raise AssertionError(f"{name} is not serialized")

# Device-list mutation must also be serialized during the scan path.
scan = body("pci-scan-bus")
if "(with-pci-registry-lock\n              (sup::push-wired device *pci-devices*))" not in scan:
    raise AssertionError("PCI device registration is not serialized")

# Mutation guard: removing registry wrappers must be rejected by this test.
mutated = text.replace("(with-pci-registry-lock\n", "(progn\n", 4)
for name in ("map-pci-devices", "pci-late-probe", "probe-pci-driver", "register-pci-driver"):
    start = mutated.index("(defun " + name)
    end = mutated.find("\n(defun ", start + 1)
    if "(with-pci-registry-lock" in (mutated[start:] if end < 0 else mutated[start:end]):
        break
else:
    raise AssertionError("mutation removing registry lock was not detected")
PY

echo "PCI registry lock contract passed"
