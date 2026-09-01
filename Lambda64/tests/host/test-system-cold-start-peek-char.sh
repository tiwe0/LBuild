#!/usr/bin/env bash
# Regression coverage for the pre-CLOS PEEK-CHAR implementation used by cold-start.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file="$repo_root/system/cold-start.lisp"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-cold-peek.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/peek-char.lisp" "${COLD_START_PEEK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun peek-char')
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
    raise SystemExit('unterminated cold-start PEEK-CHAR form')

if sys.argv[3]:
    old = '((characterp peek-type)'
    if old not in form:
        raise SystemExit('character-peek mutation anchor missing')
    form = form.replace(old, '((and nil (characterp peek-type))', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<EOF_LISP
(defpackage :cold-start-peek-test
  (:use :cl)
  (:shadow #:peek-char #:read-char #:unread-char))
(in-package :cold-start-peek-test)

(defstruct input-buffer
  data
  (position 0)
  unread)

(defun cold-read-char (stream)
  (or (prog1 (input-buffer-unread stream)
        (setf (input-buffer-unread stream) nil))
      (let ((position (input-buffer-position stream))
            (data (input-buffer-data stream)))
        (when (< position (length data))
          (prog1 (char data position)
            (incf (input-buffer-position stream)))))))

(defun cold-unread-char (character stream)
  (when (input-buffer-unread stream)
    (error "multiple unread characters"))
  (setf (input-buffer-unread stream) character))

(defun whitespace[2]p (character)
  (find character '(#\Space #\Tab #\Newline #\Return #\Page)))

(load #p"$tmp_dir/peek-char.lisp")

(defun check (value description)
  (unless value
    (error "~A" description)))

(defun check-char (actual expected description)
  (check (and (characterp actual) (char= actual expected))
         (format nil "~A: got ~S, expected ~S" description actual expected)))

(let ((stream (make-input-buffer :data "ab")))
  (check-char (peek-char nil stream) #\a "nil peek result")
  (check-char (cold-read-char stream) #\a "nil peek preserves input")
  (check-char (cold-read-char stream) #\b "nil peek preserves following input"))

(let ((stream (make-input-buffer
               :data (concatenate 'string " " (string #\Tab) (string #\Newline) "alpha"))))
  (check-char (peek-char t stream) #\a "whitespace peek result")
  (check-char (cold-read-char stream) #\a "whitespace peek preserves delimiter")
  (check-char (cold-read-char stream) #\l "whitespace peek consumes only whitespace"))

(let ((stream (make-input-buffer :data "ab=c")))
  (check-char (peek-char #\= stream) #\= "character peek result")
  (check-char (cold-read-char stream) #\= "character peek preserves delimiter")
  (check-char (cold-read-char stream) #\c "character peek consumes preceding characters"))

(let ((stream (make-input-buffer :data "ab c")))
  (check-char (peek-char #\Space stream) #\Space "character whitespace delimiter")
  (check-char (cold-read-char stream) #\Space "character whitespace delimiter is unread"))

(format t "cold-start PEEK-CHAR semantics passed~%")
EOF_LISP

sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${COLD_START_PEEK_MUTATION_RUN:-}" ]]; then
  if COLD_START_PEEK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "cold-start PEEK-CHAR mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "cold-start PEEK-CHAR mutation rejected"
fi
