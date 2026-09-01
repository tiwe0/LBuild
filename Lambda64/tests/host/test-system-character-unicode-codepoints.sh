#!/usr/bin/env bash
# Regression coverage for invalid Unicode character-name code points.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CHARACTER_SOURCE:-"$repo_root/system/character.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-character-unicode-codepoints.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/name-char.lisp" "${CHARACTER_UNICODE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('(defun name-char')
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
    raise SystemExit('unterminated NAME-CHAR form')

if sys.argv[3]:
    old = '(and (< value char-code-limit)'
    if old not in form:
        raise SystemExit('Unicode range mutation anchor missing')
    form = form.replace(old, '(and t', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:char-code-limit #:make-character #:name-char))
(in-package :mezzano.internals)

(defconstant char-code-limit #x110000)
(deftype string-designator () 'string)
(defparameter *char-name-alist* '((65 "A")))
(defparameter *unicode-name-trie* nil)

(defun make-character (code &key control meta super hyper)
  (unless (and (integerp code) (<= 0 code #x10FFFF))
    (error 'type-error :datum code :expected-type '(integer 0 #x10FFFF)))
  (unless (or (<= #xD800 code #xDFFF)
              (<= #xFDD0 code #xFDEF)
              (eql (logand code #xFFFE) #xFFFE))
    (list code control meta super hyper)))

(defun valid-codepoint-p (string &optional (start 0) end)
  (unless end (setf end (length string)))
  (loop for index from start below end
        always (digit-char-p (char string index) 16)))

(defun match-unicode-name (name trie &key start)
  (declare (ignore name trie start))
  nil)

(load (or (sb-ext:posix-getenv "NAME_CHAR_FORM")
          (error "NAME_CHAR_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(check (equal (name-char "U0041") '(65 nil nil nil nil))
       "valid BMP Unicode name did not parse")
(check (equal (name-char "M-U00000041") '(65 nil t nil nil))
       "valid Unicode name lost its modifier")
(dolist (name '("U0000D800" "U0000FDD0" "U0000FFFE" "U00110000" "UFFFFFFFF"))
  (check (null (name-char name))
         "invalid Unicode name ~S did not return NIL" name))

(format t "character Unicode codepoint validation passed~%")
EOF_LISP

NAME_CHAR_FORM="$tmp_dir/name-char.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${CHARACTER_UNICODE_MUTATION_RUN:-}" ]]; then
  if CHARACTER_UNICODE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "character Unicode range mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "character Unicode range mutation rejected"
fi
