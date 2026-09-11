#!/usr/bin/env bash
# Every VIRTQUEUE slot must be initialized, by the positional constructor or by
# an initform.
#
# VIRTQUEUE uses a BOA constructor (%MAKE-VIRTQUEUE) that takes only the six
# geometry slots, because a keyword lambda list would materialise an argument
# vector in the general area and virtqueues are built during the pre-pager
# bootstrap.  A slot that is neither a constructor parameter nor given an
# initform silently defaults to NIL.  LAST-SEEN-USED is compared with EQL
# against the device's used-ring index; NIL never matches, so the receive loop
# falls through to descriptor extraction and evaluates (REM NIL size).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${VIRTIO_SOURCE:-"$repo_root/supervisor/virtio.lisp"}

python3 - "$source_file" "${VIRTIO_QUEUE_INIT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Historical defect: drop LAST-SEEN-USED's initform.
    source = source.replace("(last-seen-used 0))", "last-seen-used)", 1)

start = source.index("(defstruct (virtqueue")
depth = 0; string = comment = esc = False; end = None
for i, c in enumerate(source[start:], start):
    if comment:
        if c == "\n": comment = False
        continue
    if string:
        if esc: esc = False
        elif c == "\\": esc = True
        elif c == '"': string = False
        continue
    if c == ";": comment = True
    elif c == '"': string = True
    elif c == "(": depth += 1
    elif c == ")":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit("unterminated VIRTQUEUE defstruct")
form = source[start:end]

ctor = re.search(r"\(:constructor\s+%make-virtqueue\s*\(([^)]*)\)", form)
if not ctor:
    raise SystemExit("positional VIRTQUEUE constructor missing")
positional = set(ctor.group(1).split())

# Slot specs are everything after the option list.
body = form[ctor.end():]
body = body[body.index(")") + 1:]
slots = []
for match in re.finditer(r"(?m)^\s*(?:\(\s*([a-z0-9-]+)\s|([a-z0-9-]+)\s*$|([a-z0-9-]+)\)\s*$)", body):
    name = match.group(1) or match.group(2) or match.group(3)
    if name: slots.append((name, match.group(1) is not None))

if not slots:
    raise SystemExit("no VIRTQUEUE slots parsed")

missing = [name for name, has_initform in slots
           if name not in positional and not has_initform]
if missing:
    raise SystemExit("VIRTQUEUE slots default to NIL: " + ", ".join(missing))
print(f"virtqueue slot initialization contract passed ({len(slots)} slots)")
PY

if [[ -z "${VIRTIO_QUEUE_INIT_MUTATION_RUN:-}" ]]; then
  if VIRTIO_QUEUE_INIT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "virtqueue slot initialization mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "virtqueue slot initialization mutation rejected"
fi
