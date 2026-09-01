#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
xterm_source=${XTERM_SOURCE:-"$repo_root/gui/xterm.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-xterm-meta-input.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$xterm_source" "$test_file" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output_path = Path(sys.argv[2])


def extract_form(marker, description):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing {description}: {marker}")

    depth = 0
    in_string = False
    escaped = False
    in_comment = False
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
        if character == ";" and source[max(0, index - 2):index] != "#\\":
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"Unterminated {description}: {marker}")


input_translate = extract_form("(defun input-translate", "XTerm input translator")
up_translation = r'(#\Up-Arrow    (#\Esc #\[ #\A))'
if up_translation not in source:
    raise SystemExit("Missing existing Up-Arrow translation used by M-Up")

# Mezzano characters are immutable values: SET-CHAR-BIT returns a replacement
# character rather than changing its argument. Keep this assertion separate
# from the portable execution facade below, which cannot represent modifier
# bits on SBCL characters. Without the SETF, a real Meta-modified special key
# would retain Meta and no longer match the ordinary translation table.
if not re.search(
        r"\(setf\s+character\s+"
        r"\(mezzano\.internals::set-char-bit\s+character\s+:meta\s+nil\)\)",
        input_translate):
    raise SystemExit("Meta clearing must retain the replacement character returned by SET-CHAR-BIT")

output_path.write_text(
    r'''(defpackage :mezzano.internals (:use :cl))
(defpackage :mezzano.gui.xterm (:use :cl))

(in-package :mezzano.internals)

(defvar *test-character-bits* '())

(defun char-bit (character bit)
  (declare (ignore character))
  (not (null (member bit *test-character-bits*))))

(defun set-char-bit (character bit set-it)
  (setf *test-character-bits*
        (if set-it
            (adjoin bit *test-character-bits*)
            (remove bit *test-character-bits*)))
  ;; #\V is a pre-clear Meta Up-Arrow proxy. Returning #\U here makes the
  ;; caller's use of SET-CHAR-BIT's immutable replacement observable even on
  ;; SBCL, whose characters cannot carry Mezzano modifier bits.
  (if (and (eql character #\V)
           (eql bit :meta)
           (not set-it))
      #\U
      character))

(in-package :mezzano.gui.xterm)

;; SBCL has no Mezzano modifier-bearing character representation. The test
;; facade keeps modifier bits separately while the extracted implementation
;; still operates on real character values. #\U stands for Mezzano's Up-Arrow
;; key in this focused translation table.
(defvar *xterm-translations*
  '((#\U (#\Esc #\[ #\A))))
'''
    + input_translate
    + r'''

(defun translated-input (character bits)
  (let ((mezzano.internals::*test-character-bits* (copy-list bits))
        (output (make-array 8 :element-type 'character
                            :adjustable t :fill-pointer 0)))
    (input-translate nil character
                     (lambda (translated)
                       (vector-push-extend translated output)))
    (coerce output 'string)))

(defun assert-input (character bits expected description)
  (let ((actual (translated-input character bits)))
    (unless (string= actual expected)
      (error "~A produced ~S, expected ~S" description actual expected))))

(assert-input #\a '(:meta :control)
              (coerce (list #\Escape (code-char 1)) 'string)
              "M-C-a")
(assert-input #\U '(:meta)
              (concatenate 'string (string #\Escape)
                           (string #\Escape) "[A")
              "M-Up")
(assert-input #\V '(:meta)
              (concatenate 'string (string #\Escape)
                           (string #\Escape) "[A")
              "M-Up must use the cleared-Meta replacement")
(assert-input #\Escape '(:meta)
              (make-string 2 :initial-element #\Escape)
              "M-Escape")
(assert-input #\λ '(:meta)
              (concatenate 'string (string #\Escape) (string #\λ))
              "M-non-ASCII")

;; Meta must not weaken the existing rejection of window-system modifiers.
(assert-input #\a '(:super) "" "Super-a")
(assert-input #\a '(:hyper) "" "Hyper-a")
(assert-input #\a '(:meta :super) "" "M-Super-a")
(assert-input #\a '(:meta :hyper) "" "M-Hyper-a")

;; Existing non-Meta behavior remains the reusable translation core.
(assert-input #\a '(:control) (string (code-char 1)) "C-a")
(assert-input #\U '() (concatenate 'string (string #\Escape) "[A") "Up")
(assert-input #\λ '() (string #\λ) "non-ASCII")

(format t "xterm meta input tests passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
