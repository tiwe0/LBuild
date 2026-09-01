#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
format_source=${FORMAT_SOURCE:-"$repo_root/system/format.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-format.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(require :asdf)
(sb-ext:unlock-package :cl)
(setf sb-ext:*on-package-variance* '(:warn nil))

(defpackage :mezzano.gray
  (:use :cl)
  (:export #:stream-line-column #:stream-line-length))
(in-package :mezzano.gray)
(defun stream-line-column (stream)
  (declare (ignore stream))
  nil)
(defun stream-line-length (stream)
  (declare (ignore stream))
  72)

(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)
(declaim (declaration lambda-name))
(defclass string-output-stream () ())
(defun make-case-correcting-stream (stream mode)
  (declare (ignore mode))
  stream)

(defpackage :mezzano.format
  (:use :cl)
  (:shadow #:format #:formatter))
(load (sb-ext:posix-getenv "FORMAT_SOURCE"))

(in-package :cl-user)

(defun mezzano-format (control &rest arguments)
  (apply #'mezzano.format::format nil control arguments))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun assert-signals (thunk description)
  (handler-case
      (progn (funcall thunk)
             (error "~A: expected an error" description))
    (error () t)))

;; TF-WI-0382: separator characters contribute to MINCOL.
(assert-equal "     1,234" (mezzano-format "~10:D" 1234)
              "Grouped decimal MINCOL")
(assert-equal "    +1,234" (mezzano-format "~10:@D" 1234)
              "Grouped signed decimal MINCOL")
(assert-equal "1_23_45_67" (mezzano-format "~10,'_,'_,2:D" 1234567)
              "Custom grouping width")

;; TF-WI-0383: ~:@C describes conventional shifted ASCII gestures.
(assert-equal "A (Shift-a)" (mezzano-format "~:@C" #\A)
              "Shifted alphabetic character description")
(assert-equal "! (Shift-1)" (mezzano-format "~:@C" #\!)
              "Shifted punctuation description")
(assert-equal "Newline" (mezzano-format "~:C" #\Newline)
              "Named non-graphic character")

;; TF-WI-0384: modern and old-style Roman numerals and domain limits.
(assert-equal "CMXLIV" (mezzano-format "~@R" 944) "Modern Roman numeral")
(assert-equal "DCCCCXXXXIIII" (mezzano-format "~:@R" 944)
              "Old-style Roman numeral")
(assert-equal "MMMCMXCIX" (mezzano-format "~@R" 3999)
              "Roman upper boundary")
(assert-signals (lambda () (mezzano-format "~@R" 0)) "Roman zero")
(assert-signals (lambda () (mezzano-format "~@R" 4000)) "Roman overflow")

;; TF-WI-0385: floating-point directive families, padding, rounding, signs,
;; overflow fields, monetary placement, and non-real fallback.
(assert-equal "1.25" (mezzano-format "~F" 1.25) "Default fixed float")
(assert-equal "125.0" (mezzano-format "~,,2F" 1.25)
              "Scaled fixed float default precision")
(assert-equal "    1.25" (mezzano-format "~8,2F" 1.25) "Fixed width")
(assert-equal "*****" (mezzano-format "~5,2,0,'*F" 123.4)
              "Fixed overflow field")
(assert-equal "    1.250E+0" (mezzano-format "~12,3E" 1.25)
              "Exponent width and precision")
(assert-equal "**********" (mezzano-format "~10,2,1,,'*E" 1.0e20)
              "Exponent digit overflow field")
(assert-equal "  1.25    " (mezzano-format "~10,3G" 1.25)
              "General float fixed selection")
(assert-equal " 1000.    " (mezzano-format "~10,3G" 999.9)
              "General float fixed rounding boundary")
(assert-equal "  9.999e-4" (mezzano-format "~10,3G" 9.999e-4)
              "General float exponential selection")
(assert-equal "**********" (mezzano-format "~10,3,1,,'*G" 1.0e20)
              "General exponent digit overflow field")
(assert-equal "1.25" (mezzano-format "~$" 1.25) "Default monetary")
(assert-equal "-___001.25" (mezzano-format "~2,3,10,'_:$" -1.25)
              "Monetary sign before padding")
(assert-equal "___+001.25" (mezzano-format "~2,3,10,'_@$" 1.25)
              "Monetary explicit positive sign")
(assert-equal "       FOO" (mezzano-format "~2,1,10,'_$" 'foo)
              "Monetary non-real field width")
(assert-equal "FOO     " (mezzano-format "~8,2F" 'foo)
              "Non-real floating fallback")

;; TF-WI-0386: standard justification distributes padding between and at the
;; requested boundaries, respecting MINPAD and custom PADCHAR.
(assert-equal "x        y" (mezzano-format "~10<~A~;~A~>" "x" "y")
              "Interior justification")
(assert-equal "    x    y" (mezzano-format "~10:<~A~;~A~>" "x" "y")
              "Leading justification")
(assert-equal "x    y    " (mezzano-format "~10@<~A~;~A~>" "x" "y")
              "Trailing justification")
(assert-equal "x________y" (mezzano-format "~10,3,2,'_<~A~;~A~>" "x" "y")
              "Justification minimum padding")
(assert-equal "!         x" (mezzano-format "~10<!~0,5:;~A~>" "x")
              "Justification overflow prefix")

;; TF-WI-0428: ~A and ~S apply MINPAD before advancing by COLINC; @ moves
;; the complete padding field to the left, while : retains the NIL spelling.
(assert-equal "x         " (mezzano-format "~10A" "x")
              "Aesthetic minimum width")
(assert-equal "         x" (mezzano-format "~10@A" "x")
              "Aesthetic left padding")
(assert-equal "x___________" (mezzano-format "~10,3,2,'_A" "x")
              "Aesthetic minpad and colinc")
(assert-equal "x" (mezzano-format "~,3A" "x")
              "Aesthetic omitted MINCOL")
(assert-equal "x__" (mezzano-format "~,,2,'_A" "x")
              "Aesthetic omitted MINCOL and COLINC")
(assert-equal "___________x" (mezzano-format "~10,3,2,'_@A" "x")
              "Aesthetic custom left padding")
(assert-equal "\"x\"________" (mezzano-format "~10,3,2,'_S" "x")
              "Standard printer custom padding")
(assert-equal "()" (mezzano-format "~:A" nil)
              "Aesthetic colon NIL spelling")
(assert-equal "___________x" (mezzano-format "~v,v,v,v@A" 10 3 2 #\_ "x")
              "Aesthetic V parameter evaluation")
(assert-signals (lambda () (mezzano-format "~0,0A" "x"))
                "Aesthetic COLINC must be positive")
(assert-signals (lambda () (mezzano-format "~0,1,-1A" "x"))
                "Aesthetic MINPAD must be non-negative")

;; TF-WI-0387 and TF-WI-0391: logical blocks own their ~; separators; the
;; compatibility no-op directive is gone outside a delimited construct.
(assert-equal "(x)" (mezzano-format "~:<~A~:>" '("x"))
              "Default logical-block delimiters")
(assert-equal "prexpost" (mezzano-format "~:<pre~;~A~;post~:>" '("x"))
              "Explicit logical-block delimiters")
(assert-equal "prexpost" (mezzano-format "~:<pre~@;~A~;post~:>" '("x"))
              "Per-line logical-block prefix")
(assert-equal "(x y)" (mezzano-format "~@:<~A ~_~A~:>" "x" "y")
              "At-sign logical-block arguments")
(assert-equal "(x y)" (mezzano-format "~@:<~A ~A~:@>" "x" "y")
              "Fill-mode logical block")
(assert-signals (lambda () (mezzano-format "~;"))
                "Out-of-context clause separator")

;; TF-WI-0388: relative, backward, and absolute argument repositioning.
(assert-equal "1 3" (mezzano-format "~A ~*~A" 1 2 3)
              "Forward argument skip")
(assert-equal "1 1" (mezzano-format "~A ~:*~A" 1 2 3)
              "Backward argument skip")
(assert-equal "1 3" (mezzano-format "~A ~2@*~A" 1 2 3 4)
              "Absolute argument positioning")
(assert-signals (lambda () (mezzano-format "~A ~2:*~A" 1 2 3))
                "Argument reposition underflow")
(assert-signals (lambda () (mezzano-format "~A~:@*~A" 1 2))
                "Argument reposition conflicting modifiers")

;; TF-WI-0389: ~:P observes the previous argument without consuming the next.
(assert-equal "1 2" (mezzano-format "~A~:P ~A" 1 2)
              "Singular previous-argument pluralization")
(assert-equal "2s x" (mezzano-format "~A~:P ~A" 2 "x")
              "Plural previous-argument pluralization")
(assert-equal "1s 3" (mezzano-format "~A~P ~A" 1 2 3)
              "Ordinary plural consumes its argument")

;; TF-WI-0390: zero/one/two/three-parameter escape predicates, bounded
;; iteration, and colon escape from list-of-lists iteration.
(assert-equal "" (mezzano-format "~0^no" ) "One-parameter escape")
(assert-equal "yes" (mezzano-format "~1^yes") "False escape predicate")
(assert-equal "" (mezzano-format "~1,1^no") "Two-parameter escape")
(assert-equal "" (mezzano-format "~1,2,3^no") "Three-parameter escape")
(assert-equal "1, 2, 3" (mezzano-format "~{~A~^, ~}" '(1 2 3))
              "Iteration final separator escape")
(assert-equal "1, 2, 3" (mezzano-format "~:{~A~:^, ~}" '((1) (2) (3)))
              "Colon escape checks outer iteration arguments")
(assert-equal "12" (mezzano-format "~2{~A~}" '(1 2 3))
              "Bounded iteration")
(assert-equal "12" (mezzano-format "~v{~A~}" 2 '(1 2 3))
              "V parameter precedes iteration arguments")
(let ((stream (make-broadcast-stream)))
  (assert-equal '(1 2)
                (funcall (mezzano.format::formatter "~0^") stream 1 2)
                "FORMATTER true parameter escape tail")
  (assert-equal '((1 2))
                (multiple-value-list
                 (funcall (mezzano.format::formatter "~0^") stream 1 2))
                "FORMATTER escape returns exactly one value")
  (assert-equal '(1 2)
                (funcall (mezzano.format::formatter "~1^") stream 1 2)
                "FORMATTER false parameter escape tail")
  (assert-equal '(2)
                (funcall (mezzano.format::formatter "~A~^") stream 1 2)
                "FORMATTER exhausted-argument escape tail"))

(cl:format t "system FORMAT directive semantics passed~%")
LISP

FORMAT_SOURCE="$format_source" "$sbcl" --noinform --disable-debugger --script "$test_file"

if [[ ${FORMAT_MUTATION_RUN:-0} != 1 ]]; then
  mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/mezzano-format-mutants.XXXXXX")
  trap 'rm -f "$test_file"; rm -rf "$mutant_dir"' EXIT
  python3 - "$format_source" "$mutant_dir" <<'MUTANT_PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutants = {
    "field-padding": (
        "(loop while (< (+ (length string) padding) mincol)\n"
        "            do (incf padding colinc))",
        "(loop while nil\n"
        "            do (incf padding colinc))"),
    "field-colinc": (
        "(loop while (< (+ (length string) padding) mincol)\n"
        "            do (incf padding colinc))",
        "(loop while (< (+ (length string) padding) mincol)\n"
        "            do (incf padding 1))"),
    "field-left-padding": ("(when at-sign\n        (dotimes", "(when nil\n        (dotimes"),
    "field-colon-nil": ("(if (and colon (null object))", "(if nil"),
    "field-standard-escape": ("(*print-escape* escape)", "(*print-escape* nil)"),
    "field-omitted-default": ("(or mincol 0)", "mincol"),
    "directive-v-order": (
        "(let ((params (compute-parameters (directive-parameters element))))",
        "(let ((params nil))"),
    "block-v-order": (
        "(let ((params (compute-parameters (block-directive-parameters element))))",
        "(let ((params nil))"),
}
for name, (original, replacement) in mutants.items():
    mutant = source.replace(original, replacement, 1)
    if mutant == source:
        raise SystemExit(f"unable to create {name} mutant")
    Path(sys.argv[2], f"{name}.lisp").write_text(mutant, encoding="utf-8")
MUTANT_PY
  for mutant in "$mutant_dir"/*.lisp; do
    if FORMAT_MUTATION_RUN=1 FORMAT_SOURCE="$mutant" "$0" >/dev/null 2>&1; then
      echo "FORMAT printer-operation mutation survived: $mutant" >&2
      exit 1
    fi
  done
  echo "system FORMAT printer-operation mutation negatives passed"
fi
