#!/usr/bin/env bash
# Regression coverage for property-list validation in (SETF SYMBOL-PLIST).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RUNTIME_SYMBOL_SOURCE:-"$repo_root/runtime/symbol.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-runtime-symbol-plist.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/symbol-plist.lisp" "${RUNTIME_SYMBOL_PLIST_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()

def extract(start_marker):
    start = source.index(start_marker)
    depth = 0
    in_string = False
    in_comment = False
    escaped = False
    for index in range(start, len(source)):
        character = source[index]
        if in_comment:
            if character == '\n':
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == ';':
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f'unterminated form starting at {start_marker!r}')

forms = []
if '(defun %property-list-p' in source:
    forms.append(extract('(defun %property-list-p'))
forms.append(extract('(defun (setf symbol-plist)'))
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = '((null fast) t)'
    if old not in text:
        raise SystemExit('symbol-plist mutation anchor missing')
    text = text.replace(old, '((null fast) nil)', 1)

Path(sys.argv[2]).write_text(text)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.runtime
  (:use :cl)
  (:shadow #:symbol-plist))
(in-package :mezzano.runtime)

(defvar *symbol-plists* (make-hash-table :test #'eq))

(load (or (sb-ext:posix-getenv "RUNTIME_SYMBOL_PLIST_FORM")
          (error "RUNTIME_SYMBOL_PLIST_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun signals-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(let ((symbol (gensym "PLIST-")))
  (check (equal (setf (symbol-plist symbol) '(:alpha 1 :beta 2))
                '(:alpha 1 :beta 2))
         "valid property list was not returned")
  (check (equal (gethash symbol *symbol-plists*) '(:alpha 1 :beta 2))
         "valid property list was not retained")
  (check (signals-p (lambda () (setf (symbol-plist symbol) 42)))
         "atom was accepted as a property list")
  (check (signals-p (lambda () (setf (symbol-plist symbol) '(:alpha . 1))))
         "dotted list was accepted as a property list")
  (check (signals-p (lambda () (setf (symbol-plist symbol) '(:alpha 1 :beta))))
         "odd-length list was accepted as a property list")
  (let ((circular (list :alpha 1)))
    (setf (cddr circular) circular)
    (check (signals-p (lambda () (setf (symbol-plist symbol) circular)))
           "circular list was accepted as a property list"))
  (check (equal (gethash symbol *symbol-plists*) '(:alpha 1 :beta 2))
         "invalid property list changed the stored value"))

(format t "runtime symbol-plist validation passed~%")
EOF_LISP

RUNTIME_SYMBOL_PLIST_FORM="$tmp_dir/symbol-plist.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${RUNTIME_SYMBOL_PLIST_MUTATION_RUN:-}" ]]; then
  if RUNTIME_SYMBOL_PLIST_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "symbol-plist validation mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "symbol-plist validation mutation rejected"
fi
