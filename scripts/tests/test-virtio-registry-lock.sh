#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
source="$root/Lambda64/supervisor/virtio.lisp"

python3 - "$source" <<'PY'
import pathlib, sys

source = pathlib.Path(sys.argv[1])
text = source.read_text()

def check(value):
    required = [
        "(defmacro with-virtio-registry-lock",
        "(sup:with-symbol-spinlock (*virtio-registry-lock*)",
    ]
    assert all(item in value for item in required), "registry lock contract missing"
    for name in ("virtio-device-register", "virtio-late-probe", "register-virtio-driver"):
        start = value.index("(defun " + name)
        end = value.find("\n(defun ", start + 1)
        body = value[start:] if end < 0 else value[start:end]
        assert "(with-virtio-registry-lock" in body, f"{name} is not serialized"

check(text)

# Mutation guard: removing the lock wrapper must make this contract fail.
mutated = text.replace("(with-virtio-registry-lock\n", "(progn\n", 3)
try:
    check(mutated)
except AssertionError:
    pass
else:
    raise AssertionError("mutation removing registry lock was not detected")
PY

echo "Virtio registry lock test passed"
