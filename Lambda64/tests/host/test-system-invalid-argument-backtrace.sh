#!/usr/bin/env bash
# Regression contract for preserving invalid-argument caller frames.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-invalid-argument.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

check_contract() {
  python3 - "$1" "$2" "$repo_root/system/debug.lisp" "$repo_root/system/error.lisp" <<'PY'
from pathlib import Path
import sys
codegen, runtime, debug, error = [Path(p).read_text(encoding='utf-8') for p in sys.argv[1:]]
if 'FIXME:' in error:
    raise SystemExit('invalid-argument raiser still has an unresolved FIXME')
if 'HACK, replace RAISE-INVALID-ARGUMENT-ERROR' in debug:
    raise SystemExit('backtrace still relies on raiser substitution hack')
if 'jmp (:named-call sys.int::raise-invalid-argument-error)' in codegen:
    raise SystemExit('compiler argument check still tail-jumps to raiser')
if 'jmp (:named-call sys.int::raise-invalid-argument-error)' in runtime:
    raise SystemExit('runtime argument check still tail-jumps to raiser')
if codegen.count('(lap:call (:named-call sys.int::raise-invalid-argument-error))') != 1:
    raise SystemExit('compiler argument check must call raiser exactly once')
if runtime.count('(sys.lap-x86:call (:named-call sys.int::raise-invalid-argument-error))') != 3:
    raise SystemExit('runtime argument checks must call raiser in all x86 paths')
print('invalid-argument backtrace contract passed')
PY
}

codegen="$repo_root/compiler/backend/x86-64/codegen.lisp"
runtime="$repo_root/runtime/runtime-x86-64.lisp"
check_contract "$codegen" "$runtime"

cp "$codegen" "$tmp_dir/codegen.lisp"
python3 - "$tmp_dir/codegen.lisp" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
old = '(lap:call (:named-call sys.int::raise-invalid-argument-error))'
new = '(lap:jmp (:named-call sys.int::raise-invalid-argument-error))'
if text.count(old) != 1:
    raise SystemExit('mutation anchor count mismatch')
path.write_text(text.replace(old, new), encoding='utf-8')
PY
if check_contract "$tmp_dir/codegen.lisp" "$runtime" >/dev/null 2>&1; then
  echo 'invalid-argument backtrace mutation unexpectedly survived' >&2
  exit 1
fi
echo 'invalid-argument backtrace mutation rejected'
