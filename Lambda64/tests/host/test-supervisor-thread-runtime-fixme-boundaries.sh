#!/usr/bin/env bash
# Host contract for unresolved scheduler and function-reference boundaries.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mutation=${FIXME_BOUNDARY_MUTATION:-}

python3 - "$repo_root" "$mutation" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
mutate = bool(sys.argv[2])
thread_path = root / "supervisor/thread.lisp"
runtime_path = root / "system/runtime-support.lisp"
thread = thread_path.read_text(encoding="utf-8")
runtime = runtime_path.read_text(encoding="utf-8")
if mutate:
    # Mutation-aware guard: an accidental marker removal must fail this test.
    thread = thread.replace("FIXME, HACK! Virtio", "resolved: Virtio", 1)

required_thread = (
    "FIXME, HACK! Virtio drivers seem to be broken",
    "FIXME: FPU state doesn't need to be completely saved",
    "FIXME: This should be done with the global lock held",
)
for marker in required_thread:
    if marker not in thread:
        raise SystemExit(f"missing scheduler boundary marker: {marker}")

# Keep the ARM64 BSP restriction explicit until a real multi-PE Virtio test exists.
if "#+arm64 (eql (local-cpu-info) *bsp-cpu*)" not in thread:
    raise SystemExit("ARM64 supervisor queue is no longer visibly BSP-constrained")
# The join event is intentionally published before taking the global lock.
cleanup = thread[thread.index("(defun thread-final-cleanup"):]
if cleanup.index("(setf (event-state") > cleanup.index("(acquire-global-thread-lock"):
    raise SystemExit("thread cleanup lock-order boundary changed")

required_runtime = (
    "FREF should be locked for the duration",
    "Fences.",
    "Cross-CPU synchronization.",
)
for marker in required_runtime:
    if marker not in runtime:
        raise SystemExit(f"missing function-reference boundary marker: {marker}")

spec_dir = root.parent / "docs/modernization/todo-fixme/specs"
for spec, phrase in (
    ("TF-WI-0287.md", "multi-PE Virtio"),
    ("TF-WI-0288.md", "complete FPU state"),
    ("TF-WI-0289.md", "join event"),
    ("TF-WI-0414.md", "without an explicit lock"),
    ("TF-WI-0415.md", "without an explicit lock"),
    ("TF-WI-0416.md", "without an explicit lock"),
):
    text = (spec_dir / spec).read_text(encoding="utf-8")
    if phrase not in text:
        raise SystemExit(f"specification {spec} lacks boundary phrase: {phrase}")
print("supervisor/thread and runtime-support FIXME boundaries passed (mutation-aware)")
PY

if [[ -z "$mutation" ]]; then
  if FIXME_BOUNDARY_MUTATION_RUN=1 FIXME_BOUNDARY_MUTATION=1 bash "$0" >/dev/null 2>&1; then
    echo 'FIXME boundary mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'FIXME boundary mutation rejected'
fi
