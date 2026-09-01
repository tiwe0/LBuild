#!/usr/bin/env bash
# Regression coverage for list-shape descriptions.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DESCRIBE_SOURCE:-"$repo_root/system/describe.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-describe-list-kind.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/describe-cons.lisp" "${DESCRIBE_LIST_KIND_MUTATION_RUN:-}" <<'PY'
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
helper_marker = '(defun %describe-cons-kind'
if helper_marker in source:
    forms.append(extract(helper_marker))
forms.append(extract('(defmethod describe-object ((object cons)'))
text = '\n\n'.join(forms)

if sys.argv[3]:
    old = '(dotted-list-length object)'
    if old not in text:
        raise SystemExit('list-kind mutation anchor missing')
    text = text.replace(old, 'nil', 1)

Path(sys.argv[2]).write_text(text)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:describe-object))
(in-package :mezzano.internals)

(defgeneric describe-object (object stream))
(defun lisp-object-address (object)
  (declare (ignore object))
  42)

(defun dotted-list-length (list)
  (do ((count 0 (+ count 2))
       (fast list (cddr fast))
       (slow list (cdr slow)))
      (nil)
    (when (atom fast) (return count))
    (when (atom (cdr fast)) (return (1+ count)))
    (when (and (eq fast slow) (> count 0)) (return nil))))

(load (or (sb-ext:posix-getenv "DESCRIBE_CONS_FORM")
          (error "DESCRIBE_CONS_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun description (object)
  (let ((*print-circle* t))
    (with-output-to-string (stream)
      (describe-object object stream))))

(let ((proper '(a b))
      (dotted (cons 'a 'b))
      (circular (list 'a)))
  (setf (cdr circular) circular)
  (check (search "proper list" (description proper))
         "proper list was not identified: ~S" (description proper))
  (check (search "dotted list" (description dotted))
         "dotted list was not identified: ~S" (description dotted))
  (check (search "circular list" (description circular))
         "circular list was not identified: ~S" (description circular)))

(format t "describe list-shape classification passed~%")
EOF_LISP

DESCRIBE_CONS_FORM="$tmp_dir/describe-cons.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${DESCRIBE_LIST_KIND_MUTATION_RUN:-}" ]]; then
  if DESCRIBE_LIST_KIND_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "describe list-kind mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "describe list-kind mutation rejected"
fi
