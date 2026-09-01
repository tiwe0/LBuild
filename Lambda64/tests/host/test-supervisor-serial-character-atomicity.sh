#!/usr/bin/env bash
# Regression coverage for atomic serial character writes.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SERIAL_SOURCE:-"$repo_root/supervisor/serial.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-serial-character-atomicity.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/debug-serial-write-char.lisp" "${SERIAL_CHARACTER_ATOMICITY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun debug-serial-write-char')
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
    raise SystemExit('unterminated DEBUG-SERIAL-WRITE-CHAR form')

if sys.argv[3]:
    old = '(debug-serial-write-byte-1 #x0D)'
    if old not in form:
        raise SystemExit('serial character mutation anchor missing')
    form = form.replace(old, '(debug-serial-write-byte #x0D)', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.supervisor
  (:use :cl))
(in-package :mezzano.supervisor)

(defvar *debug-serial-lock* :serial-lock)
(defvar *serial-at-line-start* t)
(defvar *lock-held* nil)
(defvar *lock-acquisitions* 0)
(defvar *written-bytes* '())

(defmacro safe-without-interrupts ((&rest ignored) &body body)
  (declare (ignore ignored))
  `(progn ,@body))

(defmacro with-symbol-spinlock ((lock) &body body)
  `(progn
     ,lock
     (when *lock-held*
       (error "serial lock was recursively acquired"))
     (incf *lock-acquisitions*)
     (let ((*lock-held* t))
       ,@body)))

(defmacro with-utf-8-bytes ((character byte) &body body)
  `(let ((,byte (char-code ,character)))
     ,@body))

(defun debug-serial-write-byte-1 (byte)
  (unless *lock-held*
    (error "serial byte ~S was written outside the serial lock" byte))
  (push byte *written-bytes*))

(defun debug-serial-write-byte (byte)
  (with-symbol-spinlock (*debug-serial-lock*)
    (debug-serial-write-byte-1 byte)))

(load (or (sb-ext:posix-getenv "SERIAL_WRITE_CHAR_FORM")
          (error "SERIAL_WRITE_CHAR_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun reset-serial-fixture ()
  (setf *serial-at-line-start* t
        *lock-held* nil
        *lock-acquisitions* 0
        *written-bytes* '()))

(reset-serial-fixture)
(debug-serial-write-char #\Newline)
(check (= *lock-acquisitions* 1)
       "CRLF used ~D lock acquisitions instead of one" *lock-acquisitions*)
(check (equal (nreverse *written-bytes*) '(#x0D #x0A))
       "newline did not emit CRLF atomically: ~S" *written-bytes*)
(check *serial-at-line-start* "newline did not restore line-start state")

(reset-serial-fixture)
(debug-serial-write-char #\A)
(check (= *lock-acquisitions* 1)
       "ordinary character used ~D lock acquisitions" *lock-acquisitions*)
(check (equal (nreverse *written-bytes*) '(65))
       "ordinary character did not emit UTF-8 byte: ~S" *written-bytes*)
(check (not *serial-at-line-start*) "ordinary character did not clear line-start state")

(format t "serial character atomicity passed~%")
EOF_LISP

SERIAL_WRITE_CHAR_FORM="$tmp_dir/debug-serial-write-char.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${SERIAL_CHARACTER_ATOMICITY_MUTATION_RUN:-}" ]]; then
  if SERIAL_CHARACTER_ATOMICITY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "serial character atomicity mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "serial character atomicity mutation rejected"
fi
