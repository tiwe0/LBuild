#!/usr/bin/env bash
# Regression coverage for arbitrary character-name modifier prefix order.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CHARACTER_SOURCE:-"$repo_root/system/character.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-character-prefix-order.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/name-char.lisp" "${CHARACTER_PREFIX_MUTATION_RUN:-}" <<'PY'
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
    old = '(loop while (> (- (length name) start) 2)'
    if old not in form:
        raise SystemExit('prefix-loop mutation anchor missing')
    form = form.replace(old, '(loop while nil', 1)

Path(sys.argv[2]).write_text(form)
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:make-character #:name-char))
(in-package :mezzano.internals)

(deftype string-designator () 'string)

(defparameter *char-name-alist* '((65 "A")))
(defparameter *unicode-name-trie* nil)

(defun make-character (code &key control meta super hyper)
  (list code control meta super hyper))

(defun valid-codepoint-p (string &optional (start 0) end)
  (declare (ignore string start end))
  nil)

(defun match-unicode-name (name trie &key start)
  (declare (ignore name trie start))
  nil)

(load (or (sb-ext:posix-getenv "NAME_CHAR_FORM")
          (error "NAME_CHAR_FORM is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun permutations (items)
  (if (endp items)
      (list '())
      (loop for item in items
            append (mapcar (lambda (rest) (cons item rest))
                           (permutations (remove item items :count 1 :test #'eq))))))

(defun expected-character ()
  '(65 t t t t))

(dolist (prefixes (permutations '("C" "M" "S" "H")))
  (let ((name (format nil "~{~A-~}A" prefixes)))
    (check (equal (name-char name) (expected-character))
           "modifier order ~S did not preserve all bits: ~S"
           name (name-char name))))

(check (equal (name-char "A") '(65 nil nil nil nil))
       "unprefixed character name changed")
(check (equal (name-char "C-M-S-H-A") (expected-character))
       "canonical modifier order changed")
(check (null (name-char "C-C-A"))
       "duplicate modifier was accepted")
(check (null (name-char "C-"))
       "prefix-only name was accepted")

(format t "character modifier prefix ordering passed~%")
EOF_LISP

NAME_CHAR_FORM="$tmp_dir/name-char.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${CHARACTER_PREFIX_MUTATION_RUN:-}" ]]; then
  if CHARACTER_PREFIX_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "character prefix-order mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "character prefix-order mutation rejected"
fi
