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
    # Mutation-aware guard: accidental removal of any tracked marker fails.
    if sys.argv[2] == "virtio":
        thread = thread.replace("FIXME, HACK! Virtio", "resolved: Virtio", 1)
    elif sys.argv[2] == "fpu":
        thread = thread.replace("FIXME: FPU state", "resolved: FPU state", 1)
    elif sys.argv[2] == "lock-order":
        thread = thread.replace("FIXME: This should be done", "resolved: This should be done", 1)
    elif sys.argv[2] == "fref":
        runtime = runtime.replace("FIXME: FREF should be locked for the duration", "resolved fref publication", 1)

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
# Voluntary switches still save the architectural FPU state before publishing
# the partial-save flag.  This ordering is part of the current ABI contract;
# reducing the save to control registers requires a separate cross-architecture
# lazy-state design and must not happen as an incidental cleanup.
voluntary = thread[thread.index("(defun %%switch-to-thread-via-wired-stack"):]
voluntary = voluntary[:voluntary.index("(defun %%switch-to-thread-via-interrupt")]
save_pos = voluntary.find("(save-fpu-state current-thread)")
partial_pos = voluntary.find("(setf (thread-full-save-p current-thread) nil)")
if save_pos < 0 or partial_pos < 0 or save_pos > partial_pos:
    raise SystemExit("voluntary switch must save FPU state before marking partial save")
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
  for marker in virtio fpu lock-order fref; do
    if FIXME_BOUNDARY_MUTATION_RUN=1 FIXME_BOUNDARY_MUTATION="$marker" bash "$0" >/dev/null 2>&1; then
      echo "FIXME boundary mutation unexpectedly survived: $marker" >&2
      exit 1
    fi
  done
  echo 'FIXME boundary mutations rejected'
fi
