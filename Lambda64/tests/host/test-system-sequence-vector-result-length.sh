#!/usr/bin/env bash
# Regression coverage for CONCATENATE vector result-type length restrictions.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SEQUENCE_SOURCE:-"$repo_root/system/sequence.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-sequence-vector-length.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/sequence.lisp" "${SEQUENCE_VECTOR_LENGTH_MUTATION_RUN:-}" <<'PY'
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

text = "\n\n".join((
    extract('(defun vector-type-element-type'),
    extract('(define-compiler-macro concatenate'),
    extract('(defun %concatenate-vector'),
    extract('(defun concatenate'),
))

if sys.argv[3]:
    old = """(unless (or (eql expected-length '*)
                     (eql total-length expected-length))"""
    if old not in text:
        raise SystemExit('sequence vector-length mutation anchor missing')
    text = text.replace(old, """(unless (or (eql expected-length '*)
                     t)""", 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:nicknames :sys.int)
  (:use :cl)
  (:shadow #:concatenate))
(in-package :mezzano.internals)

(defun typeexpand (type &optional environment)
  (declare (ignore environment))
  (values type nil))

(defun specialized-array-definition-tag (array-info)
  (declare (ignore array-info))
  nil)

(defun specialized-array-definition-type (array-info)
  array-info)

(defun upgraded-array-info (element-type &optional environment)
  (declare (ignore environment))
  element-type)

(defun make-simple-array-1 (&rest arguments)
  (declare (ignore arguments))
  (error "fixture should use MAKE-ARRAY"))

(load (or (sb-ext:posix-getenv "SEQUENCE_FORMS")
          (error "SEQUENCE_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(multiple-value-bind (element-type expected-length)
    (vector-type-element-type '(vector base-char 2))
  (check (eql element-type 'base-char)
         "vector result type returned the wrong element type: ~S" element-type)
  (check (eql expected-length 2)
         "vector result type did not return its fixed length: ~S" expected-length))

(multiple-value-bind (element-type expected-length)
    (vector-type-element-type '(simple-array character (3)))
  (check (eql element-type 'character)
         "simple-array result type returned the wrong element type: ~S" element-type)
  (check (eql expected-length 3)
         "simple-array result type did not return its fixed length: ~S" expected-length))

(multiple-value-bind (element-type expected-length)
    (vector-type-element-type '(vector t *))
  (check (eql element-type 't)
         "unrestricted vector returned the wrong element type: ~S" element-type)
  (check (eql expected-length '*)
         "unrestricted vector returned the wrong length restriction: ~S" expected-length))

(let ((expansion (funcall (compiler-macro-function 'concatenate)
                          '(concatenate '(vector base-char 2) #(1) #(2))
                          nil)))
  (check (equalp expansion
                 '(%concatenate-vector 'base-char '2 #(1) #(2)))
         "CONCATENATE compiler macro lost its fixed result length: ~S" expansion))

(check (equalp (%concatenate-vector 't 2 #(1) #(2)) #(1 2))
       "fixed-length vector CONCATENATE lost its successful result")
(check (handler-case
           (progn
             (%concatenate-vector 't 2 #(1) #(2 3))
             nil)
         (simple-type-error () t))
       "fixed-length vector CONCATENATE accepted the wrong number of elements")

(check (equalp (concatenate '(vector t 2) #(1) #(2)) #(1 2))
       "runtime CONCATENATE lost its fixed-length successful result")
(check (handler-case
           (progn
             (concatenate '(vector t 2) #(1) #(2 3))
             nil)
         (simple-type-error () t))
       "runtime CONCATENATE accepted the wrong number of elements")

(format t "sequence vector result-length semantics passed~%")
EOF_LISP

SEQUENCE_FORMS="$tmp_dir/sequence.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${SEQUENCE_VECTOR_LENGTH_MUTATION_RUN:-}" ]]; then
  if SEQUENCE_VECTOR_LENGTH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "sequence vector result-length mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "sequence vector result-length mutation rejected"
fi
