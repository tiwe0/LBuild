#!/usr/bin/env bash
# Regression coverage for top-level macro-lambda-list &ENVIRONMENT placement.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DEFMACRO_SOURCE:-"$repo_root/system/defmacro.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-defmacro-environment.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/defmacro.lisp" "${DEFMACRO_ENVIRONMENT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[3]:
    old = "(symbolp (cadr i))"
    if old not in source:
        raise SystemExit("&ENVIRONMENT mutation anchor missing")
    source = source.replace(old, "t", 1)

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

Path(sys.argv[2]).write_text(
    extract("(defun fix-lambda-list-environment") + "\n",
    encoding="utf-8",
)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)

(define-condition invalid-macro-lambda-list (simple-error)
  ((lambda-list :initarg :lambda-list :reader invalid-macro-lambda-list-lambda-list)))

(load (or (sb-ext:posix-getenv "DEFMACRO_ENVIRONMENT_FORMS")
          (error "DEFMACRO_ENVIRONMENT_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun check-placement (lambda-list expected environment)
  (multiple-value-bind (without-environment found-environment)
      (fix-lambda-list-environment lambda-list)
    (check (equal without-environment expected)
           "&ENVIRONMENT removal changed the lambda list: ~S -> ~S"
           lambda-list without-environment)
    (check (eq found-environment environment)
           "&ENVIRONMENT binding was not retained: ~S -> ~S"
           lambda-list found-environment)))

(check-placement '(&whole whole &environment environment required &optional optional)
                 '(&whole whole required &optional optional)
                 'environment)
(check-placement '(required &environment environment &optional optional)
                 '(required &optional optional)
                 'environment)
(check-placement '(required &optional optional &environment environment &rest rest)
                 '(required &optional optional &rest rest)
                 'environment)
(check-placement '(required &rest rest &environment environment &key key)
                 '(required &rest rest &key key)
                 'environment)
(check-placement '(&key key &environment environment &aux auxiliary)
                 '(&key key &aux auxiliary)
                 'environment)
(check-placement '(required &aux auxiliary &environment environment)
                 '(required &aux auxiliary)
                 'environment)
(check-placement '(required &environment environment . rest)
                 '(required . rest)
                 'environment)

(check (handler-case
           (progn
             (fix-lambda-list-environment '(&environment (environment) required))
             nil)
         (invalid-macro-lambda-list () t))
       "non-symbol &ENVIRONMENT binding was accepted")
(check (handler-case
           (progn
             (fix-lambda-list-environment '(&environment first required &environment second))
             nil)
         (invalid-macro-lambda-list () t))
       "duplicate &ENVIRONMENT binding was accepted")
(check (handler-case
           (progn
             (fix-lambda-list-environment '(&environment environment &whole whole))
             nil)
         (invalid-macro-lambda-list () t))
       "&ENVIRONMENT before &WHOLE was accepted")

(format t "defmacro &ENVIRONMENT placement passed~%")
EOF_LISP

DEFMACRO_ENVIRONMENT_FORMS="$tmp_dir/defmacro.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${DEFMACRO_ENVIRONMENT_MUTATION_RUN:-}" ]]; then
  if DEFMACRO_ENVIRONMENT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "defmacro &ENVIRONMENT mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "defmacro &ENVIRONMENT mutation rejected"
fi
