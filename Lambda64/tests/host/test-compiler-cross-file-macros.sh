#!/usr/bin/env bash
# Regression coverage for compiler-macro expansion in the cross-file compiler.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CROSS_FILE_COMPILER_SOURCE:-"$repo_root/compiler/cross-file-compiler.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-cross-file-macros.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/cross-file-compiler.lisp" "${CROSS_FILE_COMPILER_MACRO_MUTATION_RUN:-}" <<'PY'
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

text = extract('(defun x-compile-for-value')

if sys.argv[3]:
    old = '''(if expandedp
                     (setf expansion next)
                     (return expansion))))'''
    if old not in text:
        raise SystemExit('cross-file compiler-macro mutation anchor missing')
    text = text.replace(old, '''(if expandedp
                     (return expansion)
                     (return expansion))))''', 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:nicknames :sys.int)
  (:use :cl))
(defpackage :mezzano.compiler
  (:use :cl)
  (:shadow #:macroexpand))
(in-package :mezzano.internals)

(defconstant +llf-funcall-n+ :funcall-n)
(defconstant +llf-drop+ :drop)
(defconstant +llf-if+ :if)
(defconstant +llf-else+ :else)
(defconstant +llf-fi+ :fi)
(defvar *events* nil)
(defvar *top-level-form-number* nil)

(defun add-to-llf (&rest arguments)
  (push arguments *events*))

(defun valid-funcall-function-p (form)
  (declare (ignore form))
  nil)

(defun funcall-function-name (form)
  (declare (ignore form))
  (error "fixture should not unpeel FUNCALL"))

(in-package :mezzano.compiler)

(defvar *failed-fastload-by-symbol* (make-hash-table))
(defvar *target-architecture* nil)

(defun compile-lambda (&rest arguments)
  (declare (ignore arguments))
  (error "fixture should not compile a lambda"))

(defun macroexpand (form environment)
  (declare (ignore environment))
  (if (equal form '(ordinary 1))
      (values '(original 1) t)
      (if (equal form '(after-compiler-macro 1))
          (values '(final-stage 1) t)
          (values form nil))))

(defun compiler-macroexpand-1 (form environment)
  (declare (ignore environment))
  (if (equal form '(original 1))
      (values '(after-compiler-macro 1) t)
      (values form nil)))

(load (or (sb-ext:posix-getenv "CROSS_FILE_COMPILER_FORMS")
          (error "CROSS_FILE_COMPILER_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(setf sys.int::*events* nil)
(x-compile-for-value '(ordinary 1) :lexical-environment)
(let ((events (reverse sys.int::*events*)))
  (check (equal events '((nil 1) (:funcall-n final-stage 1)))
         "compiler-macro expansion chain did not complete: ~S" events))

(format t "cross-file compiler-macro expansion passed~%")
EOF_LISP

CROSS_FILE_COMPILER_FORMS="$tmp_dir/cross-file-compiler.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${CROSS_FILE_COMPILER_MACRO_MUTATION_RUN:-}" ]]; then
  if CROSS_FILE_COMPILER_MACRO_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "cross-file compiler-macro mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "cross-file compiler-macro mutation rejected"
fi
