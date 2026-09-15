#!/usr/bin/env bash
# The supervisor's boot-mode dispatch must have a reachable resume branch.
#
# BOOTLOADER-ENTRY-POINT decides between a first boot and a snapshot resume.
# A WIP commit inserted a traced FIRST-RUN-P branch above the original one and
# changed the original's test to (NOT FIRST-RUN-P) while leaving its body --
# which creates the main thread -- in place.  The two tests are exhaustive, so
# the T branch that resumes a snapshot became unreachable and every resumed
# image started a second main thread on INITIALIZE-LISP.
#
# That is fatal rather than merely wasteful: INITIALIZE-LISP ends by
# MAKUNBOUNDing the obarrays the cold generator supplied, so the second run
# dies in RAISE-UNBOUND-ERROR on *INITIAL-CREF-OBARRAY* before executing any of
# its own code.  The symptom is a panic on the second boot of any image that
# has snapshotted, with a correct image and a clean build.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
entry_source=${SUPERVISOR_ENTRY_SOURCE:-"$repo_root/supervisor/entry.lisp"}

python3 - "$entry_source" "${BOOT_MODE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Reintroduce the defect: give the resume branch a test that FIRST-RUN-P
    # already excludes, which is what made it unreachable.
    source = source.replace("          (t\n           ;; Snapshot resume.",
                            "          ((not first-run-p)\n           ;; Snapshot resume.", 1)

# Locate the boot-mode COND and collect its top-level branch tests.
start = source.index("(cond (first-run-p")
depth, i = 0, start
while True:
    if source[i] == '(':
        depth += 1
    elif source[i] == ')':
        depth -= 1
        if depth == 0:
            break
    i += 1
cond = source[start:i + 1]

tests = []
depth, j = 0, 0
while j < len(cond):
    if cond[j] == '(':
        depth += 1
        if depth == 2:                      # start of a branch
            k, d2 = j + 1, 0
            while cond[k] in ' \n':
                k += 1
            if cond[k] == '(':              # compound test
                d2 = 0
                m = k
                while True:
                    if cond[m] == '(':
                        d2 += 1
                    elif cond[m] == ')':
                        d2 -= 1
                        if d2 == 0:
                            break
                    m += 1
                tests.append(cond[k:m + 1])
            else:
                tests.append(cond[k:k + len("first-run-p")].split()[0].strip())
    elif cond[j] == ')':
        depth -= 1
    j += 1

assert tests[0] == "first-run-p", tests
assert len(tests) == 2, f"boot dispatch must be first-run/resume, got {tests}"
assert tests[1] == "t", f"resume branch must be reachable, its test is {tests[1]}"

# Split the two branches and check what each may do.
resume = cond[cond.index("(t\n"):]
first_run = cond[:cond.index("(t\n")]

assert "initialize-lisp" in first_run, "first boot must start the main thread"
assert "initialize-lisp" not in resume, \
    "resume must not start a second main thread on INITIALIZE-LISP"
assert "(make-thread" not in resume, \
    "resume must not create threads; they come back from the snapshot"
assert "(wake-thread *post-boot-worker-thread*)" in resume, \
    "resume must wake the snapshotted post-boot worker"

# Flags set unconditionally at entry must be cleared on both paths.
assert "(setf *cold-boot-in-progress* t)" in source
assert "(setf *cold-boot-in-progress* nil)" in resume, \
    "resume must clear *COLD-BOOT-IN-PROGRESS*; INITIALIZE-LISP does not run here"

paging = source[source.index("(if first-run-p"):source.index("(cond (first-run-p")]
assert paging.count("(setf *cold-paging-direct-stack-ops* nil)") == 2, \
    "both paging paths must clear *COLD-PAGING-DIRECT-STACK-OPS*"

# First-run detection must not be derived from *BOOT-ID*.  The first boot sets
# *BOOT-ID* to the pre-allocated cold sentinel to avoid allocating before the
# pager is live, that value is snapshotted, and every later boot then saw the
# sentinel and called itself a first boot -- so the resume branch, even once
# reachable, was never selected.  *BOOT-ID* separately means "boot generation"
# to the DMA buffer code, which requires it to differ between boots.
detect = source[source.index("(let ((first-run-p nil))"):source.index("(cond (first-run-p")]
trigger = detect[detect.index("(setf first-run-p t)") - 400:detect.index("(setf first-run-p t)")]
assert "*cold-bootstrap-completed*" in trigger, \
    "first-run detection must test *COLD-BOOTSTRAP-COMPLETED*"
assert "eq *boot-id* *initial-boot-event*" not in trigger, \
    "first-run detection must not be derived from the *BOOT-ID* cold sentinel"
PY

# The flag has to be set where the bootstrap obarrays are consumed: that is the
# exact point after which re-running INITIALIZE-LISP is fatal rather than merely
# wasteful.  Setting it anywhere earlier would let a half-initialised image take
# the resume path.
python3 - "$repo_root/system/cold-start.lisp" "${BOOT_MODE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace("(setf mezzano.supervisor::*cold-bootstrap-completed* t)", "", 1)

assert "(setf mezzano.supervisor::*cold-bootstrap-completed* t)" in source, \
    "INITIALIZE-LISP must record that the bootstrap obarrays are consumed"
teardown = source.index("(makunbound '*initial-cref-obarray*)")
flag = source.index("(setf mezzano.supervisor::*cold-bootstrap-completed* t)")
assert flag > teardown, "the flag must be set after the obarrays are released"
assert flag - teardown < 400, \
    "the flag must sit with the obarray teardown it describes, not drift from it"
PY

if [[ -z "${BOOT_MODE_MUTATION_RUN:-}" ]]; then
  if BOOT_MODE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "boot mode dispatch mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "boot mode dispatch mutation rejected"
fi

printf 'supervisor boot-mode dispatch contract passed\n'
