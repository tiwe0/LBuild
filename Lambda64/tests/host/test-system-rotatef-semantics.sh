#!/usr/bin/env bash
# Regression coverage for the native ROTATEF expansion.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SETF_SOURCE:-"$repo_root/system/setf.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-rotatef-semantics.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/setf.lisp" "${ROTATEF_MUTATION_RUN:-}" <<'PY'
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

text = extract('(defmacro rotatef')

if sys.argv[3]:
    old = '(append (rest entries) (list (first entries)))'
    if old not in text:
        raise SystemExit('ROTATEF mutation anchor missing')
    text = text.replace(old, '(append (rest entries) (list (second entries)))', 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:get-setf-expansion #:rotatef))
(in-package :mezzano.internals)

(defun get-setf-expansion (place &optional environment)
  (declare (ignore environment))
  (let ((store (gensym "STORE")))
    (cond ((symbolp place)
           (values nil nil (list store)
                   `(setq ,place ,store)
                   place))
          ((and (consp place) (eql (first place) 'car))
           (let ((cell (gensym "CELL")))
             (values (list cell) (list (second place)) (list store)
                     `(setf (car ,cell) ,store)
                     `(car ,cell))))
          ((and (consp place) (eql (first place) 'pair))
           (let ((left (gensym "LEFT"))
                 (right (gensym "RIGHT"))
                 (left-store (gensym "LEFT-STORE"))
                 (right-store (gensym "RIGHT-STORE")))
             (values (list left right)
                     (list (second place) (third place))
                     (list left-store right-store)
                     `(progn
                        (setf (car ,left) ,left-store
                              (car ,right) ,right-store)
                        (values ,left-store ,right-store))
                     `(values (car ,left) (car ,right)))))
          (t (error "Unsupported fixture place ~S" place)))))

(load (or (sb-ext:posix-getenv "ROTATEF_FORMS")
          (error "ROTATEF_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let ((first :first)
      (second :second)
      (third :third))
  (check (null (rotatef first second third))
         "ROTATEF did not return NIL")
  (check (and (eql first :second)
              (eql second :third)
              (eql third :first))
         "three-place ROTATEF produced ~S, ~S, ~S" first second third))

(defparameter *place-evaluations* 0)
(defun counted-cell (cell)
  (incf *place-evaluations*)
  cell)

(let ((left (list :left))
      (right (list :right)))
  (setf *place-evaluations* 0)
  (rotatef (car (counted-cell left))
           (car (counted-cell right)))
  (check (= *place-evaluations* 2)
         "ROTATEF evaluated place subforms ~D times" *place-evaluations*)
  (check (and (eql (car left) :right)
              (eql (car right) :left))
         "ROTATEF did not preserve parallel place values: ~S ~S" left right))

(let ((a (list :a))
      (b (list :b))
      (c (list :c))
      (d (list :d)))
  (rotatef (pair a b) (pair c d))
  (check (and (eql (car a) :c)
              (eql (car b) :d)
              (eql (car c) :a)
              (eql (car d) :b))
         "ROTATEF did not preserve multiple store values: ~S ~S ~S ~S" a b c d))

(check (null (rotatef)) "zero-place ROTATEF did not return NIL")
(format t "ROTATEF semantics passed~%")
EOF_LISP

ROTATEF_FORMS="$tmp_dir/setf.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${ROTATEF_MUTATION_RUN:-}" ]]; then
  if ROTATEF_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ROTATEF mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ROTATEF mutation rejected"
fi
