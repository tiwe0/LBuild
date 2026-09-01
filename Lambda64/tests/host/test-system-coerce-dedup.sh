#!/usr/bin/env bash
# Regression coverage for COERCE's shared runtime/compiler-macro behavior.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COERCE_SOURCE:-"$repo_root/system/coerce.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-coerce-dedup.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/coerce.lisp" "${COERCE_DEDUP_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

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
    raise SystemExit(f'unterminated form starting at {start_marker!r}')

forms = [extract('(defun coerce-vector-element-type')]
if '(defun %coerce-value' in source:
    forms.append(extract('(defun %coerce-value'))
forms.extend([
    extract('(defun coerce '),
    extract('(define-compiler-macro coerce'),
])
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = "(if (typep ,obj ',result-type)"
    if old not in text:
        raise SystemExit('COERCE mutation anchor missing')
    text = text.replace(old, '(if nil', 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:coerce))
(in-package :mezzano.internals)

(defun typeexpand (type &optional environment)
  (declare (ignore environment))
  type)

(defun parse-array-type (type)
  (declare (ignore type))
  nil)

(load (or (sb-ext:posix-getenv "COERCE_FORMS")
          (error "COERCE_FORMS is not set")))
(defparameter *runtime-coerce* (symbol-function 'coerce))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defparameter *list-source* (list :alpha :beta))
(defparameter *vector-source* (vector :alpha :beta))

(flet ((expand (form)
         (let ((compiler-macro (cl:compiler-macro-function 'coerce)))
           (check compiler-macro "COERCE compiler macro is unavailable")
           (funcall compiler-macro form nil))))
  (check (eq (funcall *runtime-coerce* *list-source* 'list) *list-source*)
         "runtime COERCE did not retain a matching list")
  (check (eq (eval (expand '(coerce *list-source* 'list))) *list-source*)
         "compiler macro COERCE copied a matching list")
  (check (eq (funcall *runtime-coerce* *vector-source* 'vector) *vector-source*)
         "runtime COERCE did not retain a matching vector")
  (check (eq (eval (expand '(coerce *vector-source* 'vector))) *vector-source*)
         "compiler macro COERCE copied a matching vector")
  (let ((runtime-vector (funcall *runtime-coerce* *list-source* 'vector))
        (compiler-macro-vector (eval (expand '(coerce *list-source* 'vector)))))
    (check (equalp compiler-macro-vector runtime-vector)
           "compiler macro COERCE diverged from runtime conversion: ~S vs ~S"
           compiler-macro-vector runtime-vector)))

(format t "COERCE runtime/compiler-macro sharing passed~%")
EOF_LISP

COERCE_FORMS="$tmp_dir/coerce.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${COERCE_DEDUP_MUTATION_RUN:-}" ]]; then
  if COERCE_DEDUP_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "COERCE dedup mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "COERCE dedup mutation rejected"
fi
