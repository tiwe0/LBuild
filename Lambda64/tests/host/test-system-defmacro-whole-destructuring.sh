#!/usr/bin/env bash
# Regression coverage for &WHOLE destructuring in macro lambda lists.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DEFMACRO_SOURCE:-"$repo_root/system/defmacro.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-defmacro-whole.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/defmacro.lisp" "${DEFMACRO_WHOLE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[3]:
    old = "(handle-sublist (cadr ll) whole)"
    if old not in source:
        raise SystemExit("&WHOLE mutation anchor missing")
    source = source.replace(old, "(push (list (cadr ll) whole) bindings)", 1)

def extract(start_marker):
    start = source.index(start_marker)
    depth = 0
    in_string = False
    in_comment = False
    escaped = False
    for index in range(start, len(source)):
        character = source[index]
        if in_comment:
            if character == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
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
    raise SystemExit(f"unterminated form starting at {start_marker!r}")

text = extract("(defun expand-destructuring-lambda-list")
Path(sys.argv[2]).write_text(text + "\n", encoding="utf-8")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)

(define-condition invalid-macro-lambda-list (simple-error)
  ((lambda-list :initarg :lambda-list :reader invalid-macro-lambda-list-lambda-list)))

(defun dotted-list-length (list)
  (list-length list))

(defun parse-declares (body &key permit-docstring)
  (declare (ignore permit-docstring))
  (values body nil nil))

(load (or (sb-ext:posix-getenv "DEFMACRO_WHOLE_FORMS")
          (error "DEFMACRO_WHOLE_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let ((expansion
        (expand-destructuring-lambda-list
         '((&whole (operator argument) &rest rest))
         'whole-destructuring-probe
         '((list operator argument rest))
         'whole
         '(cdr whole)
         '())))
  (check (equal (eval `(let ((whole '(probe (left right)))) ,expansion))
                '(left right (left right)))
         "&WHOLE destructuring did not bind the complete inner form: ~S"
         expansion)
  (check (handler-case
             (progn
               (eval `(let ((whole '(probe (left right extra)))) ,expansion))
               nil)
           (error () t))
         "&WHOLE destructuring accepted a mismatched complete inner form"))

(format t "defmacro &WHOLE destructuring passed~%")
EOF_LISP

DEFMACRO_WHOLE_FORMS="$tmp_dir/defmacro.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${DEFMACRO_WHOLE_MUTATION_RUN:-}" ]]; then
  if DEFMACRO_WHOLE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "defmacro &WHOLE mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "defmacro &WHOLE mutation rejected"
fi
