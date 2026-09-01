#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-fancy-repl-completion.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :mezzano.gui.font (:use :cl))
(defpackage :mezzano.line-editor
  (:use :cl)
  (:export #:line-edit-mixin))
(defpackage :mezzano.gray
  (:use :cl)
  (:export #:fundamental-character-input-stream))
(defpackage :mezzano.gui.widgets
  (:use :cl)
  (:export #:text-widget))
(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:make-fifo))
(defpackage :mezzano.internals
  (:use :cl)
  (:export #:readtable-syntax-type))

(in-package :mezzano.internals)

(defun readtable-syntax-type (character &optional readtable)
  (declare (ignore readtable))
  (case character
    ((#\Space #\Tab #\Newline) :whitespace)
    (#\\ :single-escape)
    (#\| :multiple-escape)
    (otherwise nil)))

(in-package :cl-user)

(let ((source (or (sb-ext:posix-getenv "FANCY_REPL_SOURCE")
                  (error "FANCY_REPL_SOURCE is not set")))
      (wanted '("%COMPLETION-CHARACTER-KIND"
                "%COMPLETION-TOKEN-BOUNDS"
                "%COMPLETION-PACKAGE-MARKER"))
      (found '()))
  (with-open-file (stream source)
    (loop :for form = (read stream nil :eof)
          :until (eq form :eof)
          :do (cond ((and (consp form)
                          (member (first form) '(defpackage in-package)))
                     (eval form))
                    ((and (consp form)
                          (eq (first form) 'defun)
                          (member (symbol-name (second form)) wanted
                                  :test #'string=))
                     (eval form)
                     (pushnew (symbol-name (second form)) found
                              :test #'string=)))
          :until (and (consp form) (eq (first form) 'defclass))
          :until (= (length found) (length wanted))))
  (dolist (name wanted)
    (unless (member name found :test #'string=)
      (error "Missing completion lexer helper ~S" name))))

(in-package :mezzano.gui.fancy-repl)

(defun test-syntax-type (character)
  (mezzano.internals:readtable-syntax-type character))

(defun test-macro-character (character)
  (case character
    ((#\( #\) #\" #\;) (values #'identity nil))
    (#\# (values #'identity t))
    (otherwise (values nil nil))))

(defun bounds (buffer cursor)
  (%completion-token-bounds buffer cursor
                            #'test-syntax-type
                            #'test-macro-character))

(defun package-marker (buffer)
  (%completion-package-marker buffer 0 (length buffer) #'test-syntax-type))

(defun assert-bounds (buffer cursor expected-start expected-end)
  (multiple-value-bind (start end) (bounds buffer cursor)
    (unless (and (eql start expected-start) (eql end expected-end))
      (error "Bounds for ~S at ~D were ~S..~S, expected ~S..~S"
             buffer cursor start end expected-start expected-end))))

(defun assert-disabled (buffer cursor)
  (multiple-value-bind (start end) (bounds buffer cursor)
    (when (or start end)
      (error "Completion unexpectedly enabled for ~S at ~D: ~S..~S"
             buffer cursor start end))))

(defun assert-error (thunk description)
  (unless (handler-case
              (progn (funcall thunk) nil)
            (error () t))
    (error "Expected an error for ~A" description)))

;; A terminating macro is a token boundary; a non-terminating macro is not.
(assert-bounds "alpha" 0 0 5)
(assert-bounds "(alpha" 6 1 6)
(assert-bounds "(alpha" 1 1 6)
(assert-bounds "#alpha" 6 0 6)
(assert-bounds "alpha(beta" 3 0 5)
(assert-bounds "alpha(beta" 10 6 10)

;; Escaped whitespace and terminating macros remain inside the token. Multiple
;; escape sections may contain otherwise terminating characters.
(assert-bounds "alpha\\ beta" 11 0 11)
(assert-bounds "alpha\\(beta" 11 0 11)
(assert-bounds "alpha| ( |beta" 14 0 14)
(unless (= (package-marker "pkg:symbol") 3)
  (error "Unescaped package marker was not found"))
(when (package-marker "pkg\\:symbol")
  (error "Single-escaped colon was treated as a package marker"))
(when (package-marker "|pkg:symbol|")
  (error "Multiple-escaped colon was treated as a package marker"))
(unless (= (package-marker "|pkg|:symbol") 5)
  (error "Package marker after multiple escape was not found"))

;; Completion is deliberately disabled inside an open or closed string and in
;; a line comment, but resumes after the closing delimiter/newline.
(assert-disabled "\"alpha beta\"" 7)
(assert-disabled "\"alpha beta\" gamma" 4)
(assert-bounds "\"alpha beta\" gamma" 18 13 18)
(assert-disabled "; alpha beta" 8)
(assert-disabled "alpha ; beta" 10)
(assert-bounds (format nil "alpha ; beta~%gamma") 18 13 18)
(assert-error (lambda () (bounds "alpha" 6)) "cursor beyond buffer")

(format t "Fancy REPL completion lexer tests passed.~%")
LISP

FANCY_REPL_SOURCE="$repo_root/applications/fancy-repl.lisp" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"

grep -Fq '(%completion-token-bounds buffer cursor-position)' \
  "$repo_root/applications/fancy-repl.lisp"
grep -Fq '(%completion-package-marker buffer start end)' \
  "$repo_root/applications/fancy-repl.lisp"

if grep -Eq 'TODO: Deal with non-terminating macro characters' \
    "$repo_root/applications/fancy-repl.lisp"; then
  echo "Fancy REPL completion TODO remains after helper integration" >&2
  exit 1
fi
