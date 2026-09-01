#!/usr/bin/env bash
# Regression coverage for virtio-block BLK_SIZE negotiation and I/O units.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${VIRTIO_BLOCK_SOURCE:-"$repo_root/supervisor/virtio-block.lisp"}

python3 - "$source_file" "${VIRTIO_BLOCK_BLK_SIZE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace(
        "(setf (virtio:virtio-driver-feature device +virtio-block-f-blk-size+) t)",
        "; mutation: feature negotiation removed", 1)
    source = source.replace("(* count block-size)", "(* count 512)", 1)

required = [
    "(defconstant +virtio-block-f-blk-size+ 6)",
    "(block-size 512)",
    "(virtio:virtio-device-feature device +virtio-block-f-blk-size+)",
    "(setf (virtio:virtio-driver-feature device +virtio-block-f-blk-size+) t)",
    "(* lba (truncate block-size 512))",
    "(* count block-size)",
    "(truncate (* capacity 512) block-size)",
    "(< block-size 512)",
    "(> block-size sup::+4k-page-size+)",
    "(not (zerop (mod block-size 512)))",
]
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("virtio-block BLK_SIZE contract missing: " + ", ".join(missing))
feature_write = source.index(
    "(setf (virtio:virtio-driver-feature device +virtio-block-f-blk-size+) t)")
queue_setup = source.index("(virtio:virtio-configure-virtqueues device 1)")
if feature_write > queue_setup:
    raise SystemExit("virtio-block BLK_SIZE feature is negotiated after queue setup")
if "TODO: Set the BLK-SIZE feature and use non-512 byte blocks." in source:
    raise SystemExit("virtio-block BLK_SIZE TODO remains")
print("virtio-block BLK_SIZE contract passed")
PY

if [[ -z "${VIRTIO_BLOCK_BLK_SIZE_MUTATION_RUN:-}" ]]; then
  if VIRTIO_BLOCK_BLK_SIZE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "virtio-block BLK_SIZE mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "virtio-block BLK_SIZE mutation rejected"
fi
