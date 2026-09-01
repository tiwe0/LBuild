#!/usr/bin/env bash
# Regression coverage for standard stream argument normalization.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${STREAM_SOURCE:-"$repo_root/system/stream.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-stream-open.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/frob-stream.lisp" "${STREAM_FROB_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun frob-stream')
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
            form = source[start:index + 1]
            break
else:
    raise SystemExit('unterminated FROB-STREAM form')

if sys.argv[3]:
    old = '(open-stream-p stream)'
    if old not in form:
        raise SystemExit('open-stream mutation anchor missing')
    form = form.replace(old, 't', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:stream #:open-stream-p #:*terminal-io*))
(in-package :mezzano.internals)

(defclass stream () ())
(defclass open-test-stream (stream) ())
(defclass closed-test-stream (stream) ())
(defgeneric open-stream-p (stream))
(defmethod open-stream-p ((stream open-test-stream))
  (declare (ignore stream))
  t)
(defmethod open-stream-p ((stream closed-test-stream))
  (declare (ignore stream))
  nil)
(defparameter *terminal-io* (make-instance 'open-test-stream))

(load (or (sb-ext:posix-getenv "STREAM_FROB_FORM")
          (error "STREAM_FROB_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun signals-p (condition thunk)
  (handler-case (progn (funcall thunk) nil)
    (error (caught) (typep caught condition))))

(let ((default (make-instance 'open-test-stream))
      (open (make-instance 'open-test-stream))
      (closed (make-instance 'closed-test-stream)))
  (check (eq (frob-stream nil default) default)
         "NIL stream did not select the supplied default")
  (check (eq (frob-stream t default) *terminal-io*)
         "T stream did not select terminal I/O")
  (check (eq (frob-stream open default) open)
         "open stream was not returned")
  (check (signals-p 'stream-error (lambda () (frob-stream closed default)))
         "closed stream was accepted")
  (check (signals-p 'type-error (lambda () (frob-stream :not-a-stream default)))
         "non-stream was accepted"))

(format t "stream open-state normalization passed~%")
EOF_LISP

STREAM_FROB_FORM="$tmp_dir/frob-stream.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${STREAM_FROB_MUTATION_RUN:-}" ]]; then
  if STREAM_FROB_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "stream open-state mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "stream open-state mutation rejected"
fi
