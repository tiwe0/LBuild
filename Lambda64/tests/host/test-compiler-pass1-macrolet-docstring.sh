#!/usr/bin/env bash
# Regression coverage for MACROLET local macro docstring handling.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${PASS1_SOURCE:-"$repo_root/compiler/pass1.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-pass1-macrolet-docstring.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/pass1.lisp" "${PASS1_MACROLET_DOCSTRING_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun hack-macrolet-definition")
depth = 0
in_string = False
escaped = False
line_comment = False
for index in range(start, len(source)):
    c = source[index]
    if line_comment:
        if c == "\n": line_comment = False
        continue
    if in_string:
        if escaped: escaped = False
        elif c == "\\": escaped = True
        elif c == '"': in_string = False
        continue
    if c == ';': line_comment = True
    elif c == '"': in_string = True
    elif c == '(':
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            text = source[start:index + 1]
            break
else:
    raise SystemExit("unterminated hack-macrolet-definition")

if sys.argv[3]:
    anchor = ":permit-docstring t"
    if anchor not in text:
        raise SystemExit("docstring permit mutation anchor missing")
    text = text.replace(anchor, ":permit-docstring nil", 1)
Path(sys.argv[2]).write_text(text + "\n", encoding="utf-8")
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals (:nicknames :sys.int) (:use :cl))
(in-package :mezzano.internals)
(declaim (declaration lambda-name))

(defun parse-declares (forms &key permit-docstring)
  (if (and permit-docstring
           (stringp (first forms))
           (rest forms))
      (values (rest forms) nil (first forms))
      (values forms nil nil)))
(defun fix-lambda-list-environment (lambda-list)
  (values lambda-list nil))
(defvar *last-eval-form* nil)
(defun eval-in-lexenv (form environment)
  (declare (ignore environment))
  (setf *last-eval-form* form)
  (eval form))
(defun environment-macro-definitions-only (lexenv)
  (declare (ignore lexenv))
  nil)

(load (or (sb-ext:posix-getenv "PASS1_MACROLET_DOCSTRING_FORMS")
          (error "PASS1_MACROLET_DOCSTRING_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments)))

(let* ((definition '(documented-macro ()
                      "local macro documentation"
                      (list :expanded)))
       (result (hack-macrolet-definition definition nil))
       (function (second result)))
  (check (eq (first result) 'documented-macro)
         "MACROLET definition name changed: ~S" result)
  (labels ((contains-docstring-p (tree)
             (or (equal tree "local macro documentation")
                 (and (consp tree) (some #'contains-docstring-p tree)))))
    (check (not (contains-docstring-p *last-eval-form*))
           "MACROLET docstring was emitted as an executable form: ~S"
           *last-eval-form*))
  (check (equal (funcall function '(documented-macro) nil) '(:expanded))
         "MACROLET expansion behavior changed"))

;; A final string is a body form, not a docstring, and must remain observable.
(let* ((result (hack-macrolet-definition '(string-result () "body value") nil))
       (function (second result)))
  (check (equal (funcall function '(string-result) nil) "body value")
         "final string body form was incorrectly discarded"))

(format t "pass1 MACROLET docstring handling passed~%")
EOF_LISP

PASS1_MACROLET_DOCSTRING_FORMS="$tmp_dir/pass1.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${PASS1_MACROLET_DOCSTRING_MUTATION_RUN:-}" ]]; then
  if PASS1_MACROLET_DOCSTRING_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "pass1 MACROLET docstring mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "pass1 MACROLET docstring mutation rejected"
fi
