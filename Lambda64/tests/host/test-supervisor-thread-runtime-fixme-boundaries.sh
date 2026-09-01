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
sync = (root / "supervisor/sync.lisp").read_text(encoding="utf-8")
entry = (root / "supervisor/entry.lisp").read_text(encoding="utf-8")
virtio = (root / "supervisor/virtio.lisp").read_text(encoding="utf-8")
x86_thread = (root / "supervisor/x86-64/thread.lisp").read_text(encoding="utf-8")
arm64_thread = (root / "supervisor/arm64/thread.lisp").read_text(encoding="utf-8")
if mutate:
    # Mutation-aware guard: accidental removal of any tracked marker fails.
    if sys.argv[2] == "virtio":
        thread = thread.replace("FIXME, HACK! Virtio", "resolved: Virtio", 1)
    elif sys.argv[2] == "fpu":
        thread = thread.replace("FIXME: FPU state", "resolved: FPU state", 1)
    elif sys.argv[2] == "lock-order":
        # Exercise the dangerous ordering change so the structural check
        # cannot be bypassed by a comment-only mutation.
        cleanup_start = thread.index("(defun thread-final-cleanup")
        cleanup_end = thread.find("(defun thread-join", cleanup_start)
        cleanup = thread[cleanup_start:cleanup_end]
        event_form = "(setf (event-state (thread-join-event self)) (or return-values :no-values))"
        lock_form = "(acquire-global-thread-lock)"
        cleanup = cleanup.replace(event_form, "__LOCK_ORDER_EVENT__", 1).replace(lock_form, event_form, 1).replace("__LOCK_ORDER_EVENT__", lock_form, 1)
        thread = thread[:cleanup_start] + cleanup + thread[cleanup_end:]
    elif sys.argv[2] == "fref":
        runtime = runtime.replace("FIXME: FREF should be locked for the duration", "resolved fref publication", 1)

# Virtio and FPU notes remain as explicit constraints until their respective
# cross-architecture redesigns land.  The cleanup lock-order FIXME is resolved
# and is checked structurally below.
for marker in ("FIXME, HACK! Virtio drivers seem to be broken",
               "FIXME: FPU state doesn't need to be completely saved"):
    if marker not in thread:
        raise SystemExit(f"missing scheduler boundary marker: {marker}")

# Keep the ARM64 BSP restriction explicit until a real multi-PE Virtio test exists.
if thread.count("#+arm64 (eql (local-cpu-info) *bsp-cpu*)") < 2:
    raise SystemExit("ARM64 supervisor scheduling paths are no longer visibly BSP-constrained")
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
# Until the compiler proves that a yield cannot have live vector values, both
# architecture backends must retain the complete register file (FXSAVE on
# x86-64; Q0-Q31 stores on ARM64).
if "(fxsave " not in x86_thread:
    raise SystemExit("x86-64 voluntary switch lacks complete FPU save primitive")
arm64_save = arm64_thread[arm64_thread.index("define-lap-function save-fpu-state"):arm64_thread.index("define-lap-function restore-fpu-state")]
for reg in range(32):
    if f":q{reg}" not in arm64_save:
        raise SystemExit(f"ARM64 FPU save missing vector register q{reg}")
# Cleanup transitions to :dead while holding the global lock, then publishes
# the join event after releasing it, and reacquires before rescheduling.
cleanup = thread[thread.index("(defun thread-final-cleanup"):]
lock = cleanup.index("(acquire-global-thread-lock)")
dead = cleanup.index("(setf (thread-state self) :dead)")
unlock = cleanup.index("(release-global-thread-lock)", dead)
event = cleanup.index("(setf (event-state (thread-join-event self))", unlock)
relock = cleanup.index("(acquire-global-thread-lock)", event)
if not (lock < dead < unlock < event < relock):
    raise SystemExit("thread cleanup must publish join event after dead transition and lock release")
# `event-state` wakes threads while holding the big wait-object lock and a
# wait-queue lock; wake-thread then acquires the global thread lock.  Taking
# the global lock first in cleanup would therefore invert this established
# order and can deadlock on SMP.
event_setter = sync[sync.index("(defun (setf event-state)"):]
if event_setter.find("with-place-spinlock (*big-wait-for-objects-lock*)") < 0:
    raise SystemExit("event-state lock graph lost big wait-object lock")
if event_setter.find("with-wait-queue-lock") < 0 or event_setter.find("wake-thread") < 0:
    raise SystemExit("event-state must wake waiters under wait-queue lock")
# Secondary ARM64 PEs are booted before the post-boot worker executes deferred
# Virtio probing.  This confirms that the BSP restriction is exercised during
# the real multi-PE window rather than being a dead boot-time branch.
boot_smp = entry.find("(boot-secondary-cpus)")
post_worker = entry.find("(setf *post-boot-worker-thread*")
if boot_smp < 0 or post_worker < 0 or boot_smp > post_worker:
    raise SystemExit("secondary CPUs must boot before post-boot worker creation")
if "(sup::add-deferred-boot-action 'virtio-late-probe)" not in virtio:
    raise SystemExit("Virtio late probe must remain deferred until after SMP boot")

# The publication fence is now implemented in every setter branch.  Keep the
# unresolved lock/quiescence constraints as boundary markers while asserting
# the concrete barrier contract separately.
required_runtime = (
    "FREF should be locked for the duration",
    "Cross-CPU synchronization.",
)
for marker in required_runtime:
    if marker not in runtime:
        raise SystemExit(f"missing function-reference boundary marker: {marker}")
if runtime.count("sys.int::dma-write-barrier") < 3:
    raise SystemExit("function-reference publication must retain per-branch barriers")

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
