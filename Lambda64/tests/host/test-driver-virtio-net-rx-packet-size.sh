#!/usr/bin/env bash
# Regression coverage for virtio-net receive packet sizing.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${VIRTIO_NET_SOURCE:-"$repo_root/drivers/virtio-net.lisp"}

python3 - "$source_file" "${VIRTIO_NET_PACKET_SIZE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun virtio-net-receive-processing")
end = source.index("\n\n(defun virtio-net-do-transmit-processing", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(adjust-array packet packet-size)", "packet", 1)
required = [
    "(let ((packet-size (- len +virtio-net-hdr-size+)))",
    "(when (or (< packet-size 0) (> packet-size +virtio-net-mtu+))",
    "(setf packet (adjust-array packet packet-size))",
    "(incf (virtio-net-total-rx-bytes nic) packet-size)",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("virtio-net RX packet-size contract missing: " + ", ".join(missing))
if "TODO: Get the packet size correct." in form:
    raise SystemExit("virtio-net RX packet-size TODO remains")
print("virtio-net RX packet-size contract passed")
PY

if [[ -z "${VIRTIO_NET_PACKET_SIZE_MUTATION_RUN:-}" ]]; then
  if VIRTIO_NET_PACKET_SIZE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "virtio-net packet-size mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "virtio-net packet-size mutation rejected"
fi
