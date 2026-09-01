#!/usr/bin/env bash
# Regression coverage for DEFMACRO and DEFINE-COMPILER-MACRO documentation.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DEFMACRO_SOURCE:-"$repo_root/system/defmacro.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-defmacro-documentation.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/defmacro.lisp" "${DEFMACRO_DOCUMENTATION_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1]).resolve()
source = source_path.read_text(encoding="utf-8")
repo_root = source_path.parent.parent
for relative_path, expected in {
    "compiler/cross-boot.lisp":
        "(defun sys.int::%defmacro (name lambda &optional lambda-list documentation)",
    "compiler/cross-compile.lisp":
        "(defun sys.int::%define-compiler-macro (name function &optional documentation)",
}.items():
    text = (repo_root / relative_path).read_text(encoding="utf-8")
    if expected not in text:
        raise SystemExit(f"cross-compiler documentation compatibility missing: {relative_path}")

if sys.argv[3]:
    if source.count(',documentation)') < 2:
        raise SystemExit("documentation mutation anchors missing")
    source = source.replace(',documentation)', ',nil)', 2)

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

text = "\n\n".join((
    extract("(defun expand-destructuring-lambda-list"),
    extract("(defun fix-lambda-list-environment"),
    extract("(defmacro defmacro"),
    extract("(defmacro define-compiler-macro"),
))
Path(sys.argv[2]).write_text(text + "\n", encoding="utf-8")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:defmacro #:define-compiler-macro))
(in-package :mezzano.internals)

(declaim (declaration lambda-name))

(cl:defmacro defmacro (name lambda-list &body body)
  `(cl:defmacro ,name ,lambda-list ,@body))

(define-condition invalid-macro-lambda-list (simple-error)
  ((lambda-list :initarg :lambda-list :reader invalid-macro-lambda-list-lambda-list)))

(defun dotted-list-length (list)
  (list-length list))

(defun parse-declares (body &key permit-docstring)
  (declare (ignore permit-docstring))
  (if (stringp (first body))
      (values (rest body) nil (first body))
      (values body nil nil)))

(defvar *macro-docstrings* (make-hash-table :test #'eq))
(defvar *compiler-macro-docstrings* (make-hash-table :test #'eq))

(defun %defmacro (name function &optional lambda-list documentation)
  (declare (ignore lambda-list))
  (setf (cl:macro-function name) function
        (gethash name *macro-docstrings*) documentation)
  name)

(defun %define-compiler-macro (name function &optional documentation)
  (declare (ignore function))
  (setf (gethash name *compiler-macro-docstrings*) documentation)
  name)

(load (or (sb-ext:posix-getenv "DEFMACRO_DOCUMENTATION_FORMS")
          (error "DEFMACRO_DOCUMENTATION_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(eval '(defmacro documented-macro ()
         "macro documentation"
         '(:expanded)))
(check (equal (gethash 'documented-macro *macro-docstrings*)
              "macro documentation")
       "DEFMACRO docstring was not stored: ~S"
       (gethash 'documented-macro *macro-docstrings*))

(eval '(define-compiler-macro documented-function (&whole whole)
         "compiler macro documentation"
         whole))
(check (equal (gethash 'documented-function *compiler-macro-docstrings*)
              "compiler macro documentation")
       "DEFINE-COMPILER-MACRO docstring was not stored: ~S"
       (gethash 'documented-function *compiler-macro-docstrings*))

(format t "defmacro documentation propagation passed~%")
EOF_LISP

DEFMACRO_DOCUMENTATION_FORMS="$tmp_dir/defmacro.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${DEFMACRO_DOCUMENTATION_MUTATION_RUN:-}" ]]; then
  if DEFMACRO_DOCUMENTATION_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "defmacro documentation mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "defmacro documentation mutation rejected"
fi
