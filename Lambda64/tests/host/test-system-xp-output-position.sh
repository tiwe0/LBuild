#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_file=${XP_SOURCE:-"$repo_root/system/xp.lisp"}
mutation=$(mktemp "${TMPDIR:-/tmp}/xp-output-position.XXXXXX.lisp")
trap 'rm -f "$mutation"' EXIT

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defmethod initialize-instance :after ((xp xp-structure) &key)")
end = source.index("\n;The char-mode stuff", start)
form = source[start:end]
if "FIXME: If the output position can't be determined" in form:
    raise SystemExit("output-position FIXME remains")
if "(integerp position)" not in form:
    raise SystemExit("XP initialization must validate an unknown output position")
if "(if (integerp position) position 1)" not in form:
    raise SystemExit("XP initialization must conservatively use column 1 when position is unknown")
print("XP output-position fallback contract passed")
PY

cp "$source_file" "$mutation"
python3 - "$mutation" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace("(if (integerp position) position 1)", "position", 1)
path.write_text(source, encoding="utf-8")
PY
if XP_SOURCE="$mutation" bash "$0" >/dev/null 2>&1; then
  echo "mutation unexpectedly passed" >&2
  exit 1
fi
echo "XP output-position mutation rejection passed"
