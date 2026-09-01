#!/usr/bin/env bash
# Regression coverage for #:NAME not interning NAME in the KEYWORD package.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_UNINTERNED_SYMBOL_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
token_start = source.index("(defun read-token")
token_end = source.index("\n\n(defun read-ratio", token_start)
token_form = source[token_start:token_end]
colon_start = source.index("(defun read-#-colon")
colon_end = source.index("\n\n(defun read-#-dot", colon_start)
colon_form = source[colon_start:colon_end]
if sys.argv[2]:
    colon_form = colon_form.replace(r"(read-token stream #\: nil)",
                                    r"(read-token stream #\:)", 1)

required = [
    "(defun read-token (stream first &optional (intern-keyword t))",
    "(and (string= \"KEYWORD\" package-name)",
    "(not intern-keyword))",
    r"(read-token stream #\: nil)",
    "(make-symbol (if (stringp token) token (symbol-name token)))",
]
missing = [token for token in required if token not in token_form + "\n" + colon_form]
if "FIXME: This causes a symbol with the same name to be added" in colon_form:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("reader uninterned-symbol contract missing: " + ", ".join(missing))
print("reader uninterned-symbol contract passed")
PY

if [[ -z "${READER_UNINTERNED_SYMBOL_MUTATION_RUN:-}" ]]; then
  if READER_UNINTERNED_SYMBOL_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader uninterned-symbol mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader uninterned-symbol mutation rejected"
fi
