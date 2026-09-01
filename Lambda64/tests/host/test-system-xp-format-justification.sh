#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
xp_source=${XP_FORMAT_SOURCE:-"$repo_root/system/xp-format.lisp"}
xp_package_source=${XP_PACKAGE_SOURCE:-"$repo_root/system/xp-package.lisp"}
format_source=${FORMAT_SOURCE:-"$repo_root/system/format.lisp"}
sbcl=${SBCL:-sbcl}
forms_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-xp-justification.XXXXXX.lisp")
test_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-xp-justification-test.XXXXXX.lisp")
trap 'rm -f "$forms_file" "$test_file"' EXIT

python3 - "$xp_source" "$forms_file" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

def extract(prefix):
    start = source.index(prefix)
    depth = 0
    in_string = False
    escaped = False
    in_line_comment = False
    for i in range(start, len(source)):
        char = source[i]
        if in_line_comment:
            if char == "\n":
                in_line_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == ";":
            in_line_comment = True
            continue
        if char == '"':
            in_string = True
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise SystemExit(f"unbalanced form for {prefix}")

helper = extract("(defun format-standard-justification")
handler = extract("(defun handle-standard-<")
printer_handler = extract("(defun impl-A/S")
for description, pattern in {
    "XP output stream": r"\*standard-output\* xp",
    "early FORMAT argument base": r"mezzano\.format::\*format-argument-base\* initial",
    "early FORMAT escape tag": r"mezzano\.format::\*format-escape-tag\* escape-tag",
    "early FORMAT colon escape tag": r"mezzano\.format::\*format-colon-escape-tag\* colon-escape-tag",
    "early FORMAT colon arguments": r"mezzano\.format::\*format-colon-arguments\* colon-arguments",
    "shared justification engine": r"mezzano\.format::format-justification",
}.items():
    if not re.search(pattern, helper, re.S):
        raise SystemExit(f"XP justification helper is missing {description}")
for description, pattern in {
    "parameters and modifiers": r"parse-params start '\(0 1 0 #\\Space\).*"
                                r"format-standard-justification\s+XP ,\(args\) ,\(initial\) ,control"
                                r" ',atsign ',colon\s+',\(atsignp \(1- end\)\) the-params",
    "normal escape propagation": r"catch escape-tag.*return-from ,\*inner-end\* nil",
    "colon escape propagation": r"catch colon-escape-tag.*return-from ,\*outer-end\* nil",
    "colon escape argument contexts": r"if \(null \*outer-end\*\).*`\(cdr ,\(outer-args\)\).*\(initial\)",
}.items():
    if not re.search(pattern, handler, re.S):
        raise SystemExit(f"XP standard justification handler is missing {description}")
for description, pattern in {
    "shared printer-field helper": r"mezzano\.format::format-printer-operation",
    "ordered field parameters": r"\(first the-params\).*\(second the-params\).*"
                                r"\(third the-params\).*\(fourth the-params\)",
    "A/S modifiers": r"',atsign ',colon ,escape-value ',readably-is-nil",
}.items():
    if not re.search(pattern, printer_handler, re.S):
        raise SystemExit(f"XP printer operation handler is missing {description}")
Path(sys.argv[2]).write_text(helper + "\n\n", encoding="utf-8")
PY

cat >"$test_file" <<'LISP'
(require :asdf)
(sb-ext:unlock-package :cl)
(setf sb-ext:*on-package-variance* '(:warn nil))

;; XP intentionally defines its FORMAT and FORMATTER entry points on the
;; imported CL symbols in the target image. Preserve the host definitions so
;; this narrow SBCL harness can continue to compile and report assertions
;; after loading XP.
(defvar *host-format-function* (fdefinition 'cl:format))
(defvar *host-formatter-macro* (macro-function 'cl:formatter))

(defpackage :mezzano.gray
  (:use :cl)
  (:export #:stream-line-column #:stream-line-length))
(in-package :mezzano.gray)
(defun stream-line-column (stream)
  (declare (ignore stream))
  0)
(defun stream-line-length (stream)
  (declare (ignore stream))
  72)

(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)
(declaim (declaration lambda-name))

(defpackage :mezzano.compiler (:use :cl))
(defvar mezzano.compiler::*trace-asm* nil)
(defpackage :mezzano.compiler.backend (:use :cl))
(defvar mezzano.compiler.backend::*shut-up* nil)
(defpackage :mezzano.full-eval
  (:use :cl)
  (:export #:eval-in-lexenv))
(defun mezzano.full-eval:eval-in-lexenv (form lexical-environment)
  (declare (ignore lexical-environment))
  (eval form))

(defpackage :mezzano.format
  (:use :cl)
  (:shadow #:format #:formatter))
(load (sb-ext:posix-getenv "FORMAT_SOURCE"))
(load (sb-ext:posix-getenv "XP_PACKAGE_SOURCE"))
;; The target package exports inherited FORMAT/FORMATTER symbols. In the host
;; harness, replace those exports with XP-local symbols before loading its
;; definitions rather than replacing SBCL implementation-wide functions.
(unintern 'cl:format :mezzano.xp)
(unintern 'cl:formatter :mezzano.xp)
(shadow '(format formatter) :mezzano.xp)

(in-package :mezzano.xp)
;; These are late XP facilities normally supplied by xp.lisp. The generated
;; controls below only require their names to be resolvable while xp-format is
;; compiled, plus the primitive character-output implementations.
(defvar *circularity-hash-table* nil)
(defvar *abbreviation-happened* nil)
(defvar *current-level* 0)
(defun tail-pos (&rest arguments)
  (declare (ignore arguments))
  0)
(defun circularity-process (&rest arguments)
  (declare (ignore arguments))
  nil)
(defun maybe-initiate-xp-printing (fn stream &rest args)
  (apply fn stream args))
(defun write+ (object stream)
  (write object :stream stream :escape nil :readably nil))
(defun write-char++ (char stream)
  (write-char char stream))
(defun write-string++ (string stream start end)
  (write-string string stream :start start :end end))

(in-package :cl-user)
(load (sb-ext:posix-getenv "XP_FORMAT_SOURCE"))
(setf (fdefinition 'cl:format) *host-format-function*
      (macro-function 'cl:formatter) *host-formatter-macro*)

(in-package :mezzano.xp)
;; The generated controls under test only need the late-XP entry point and
;; primitive character output. Keep this scaffold deliberately small while
;; executing formatter-fn and its actual handler expansion.
(defun compile-host-xp (control)
  (eval `(lambda (s &rest args)
           ,(formatter-fn control "CL-USER" t))))

(defun run-host-xp (control args)
  (handler-case
      (let (remaining)
        (values
         (with-output-to-string (stream)
           (setf remaining
                 (apply (compile-host-xp control) stream args)))
         remaining nil))
    (error (condition)
      (values nil nil condition))))

(in-package :cl-user)
(defun fail (description)
  ;; Do not call ERROR or FORMAT to report an assertion: both are among the
  ;; dynamically compiled XP surfaces exercised here. A host-only diagnostic
  ;; keeps a formatter regression from turning into a nested debugger error.
  (write-line description *error-output*)
  (finish-output *error-output*)
  (sb-ext:exit :code 1))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (fail description)))

(defun assert-xp-output (expected-output expected-remaining control args description)
  (multiple-value-bind (output remaining error)
      (mezzano.xp::run-host-xp control args)
    (when error
      (fail description))
    (assert-equal expected-output output description)
    (assert-equal expected-remaining remaining
                  (concatenate 'string description " remaining arguments"))))

(defun assert-xp-error (control args description)
  (multiple-value-bind (output remaining error)
      (mezzano.xp::run-host-xp control args)
    (declare (ignore output remaining))
    (unless error
      (fail description))))

(assert-xp-output "x        y" nil "~10<~A~;~A~>" '("x" "y")
                  "XP interior justification")
(assert-xp-output "    x    y" nil "~10:<~A~;~A~>" '("x" "y")
                  "XP leading justification")
(assert-xp-output "x    y    " nil "~10@<~A~;~A~>" '("x" "y")
                  "XP trailing justification")
(assert-xp-output "x________y" nil "~10,3,2,'_<~A~;~A~>" '("x" "y")
                  "XP minpad and pad character")
(assert-xp-output "!         x" nil "~10<!~0,5:;~A~>" '("x")
                  "XP overflow clause")
(assert-xp-output "abcdefgh  123456789" '("TAIL")
                  "~v,#<~A~;~A~>" '(10 "abcdefgh" "123456789" "TAIL")
                  "XP V/# parameter evaluation and tail update")
(assert-xp-output "xx" '("TAIL") "~<~A~:*~A~>" '("x" "TAIL")
                  "XP argument-base binding for ~:*")
(assert-xp-output "" nil "~<~A~^~;~A~>" '("x")
                  "XP escape binding for ~^")
(assert-xp-output "" nil "~<~A~^~;~A~>AFTER" '("x")
                  "XP escape leaves the enclosing formatter")
(assert-xp-output "aXAFTER" nil "~:{~<~A~:^~;X~>AFTER~}"
                  '((("a") ("b")))
                  "XP colon escape checks outer iteration arguments")
(assert-xp-output "aXAFTER" nil "~A~<~:^~;X~>AFTER" '("a")
                  "XP colon escape uses the initial argument base outside iteration")
(assert-xp-error "~<~A~@>" '("x") "XP justification closing at-sign")
(assert-xp-error "~;" '() "XP out-of-context clause separator")

;; TF-WI-0428: compiled XP controls must use the same full ~A/~S field
;; contract as early FORMAT rather than dropping the parsed parameters.
(assert-xp-output "x         " nil "~10A" '("x")
                  "XP aesthetic minimum width")
(assert-xp-output "         x" nil "~10@A" '("x")
                  "XP aesthetic left padding")
(assert-xp-output "x___________" nil "~10,3,2,'_A" '("x")
                  "XP aesthetic minpad and colinc")
(assert-xp-output "x" nil "~,3A" '("x")
                  "XP aesthetic omitted MINCOL")
(assert-xp-output "x__" nil "~,,2,'_A" '("x")
                  "XP aesthetic omitted MINCOL and COLINC")
(assert-xp-output "___________x" nil "~10,3,2,'_@A" '("x")
                  "XP aesthetic custom left padding")
(assert-xp-output "\"x\"________" nil "~10,3,2,'_S" '("x")
                  "XP standard printer custom padding")
(assert-xp-output "()" nil "~:A" '(nil)
                  "XP aesthetic colon NIL spelling")
(assert-xp-output "___________x" nil "~v,v,v,v@A" '(10 3 2 #\_ "x")
                  "XP aesthetic V parameter evaluation")
(assert-xp-error "~0,0A" '("x") "XP aesthetic COLINC validation")
(assert-xp-error "~0,1,-1A" '("x") "XP aesthetic MINPAD validation")

(format t "XP FORMAT justification semantics passed~%")
LISP

FORMAT_SOURCE="$format_source" \
XP_PACKAGE_SOURCE="$xp_package_source" \
XP_FORMAT_SOURCE="$xp_source" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"

if [[ ${XP_JUSTIFICATION_MUTATION_RUN:-0} != 1 ]]; then
  mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/mezzano-xp-justification-mutants.XXXXXX")
  trap 'rm -f "$forms_file" "$test_file"; rm -rf "$mutant_dir"' EXIT
  python3 - "$xp_source" "$mutant_dir" <<'MUTANT_PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutants = {
    "shared-engine": ("mezzano.format::format-justification",
                      "mezzano.format::format-logical-block"),
    "xp-output": ("(*standard-output* xp)",
                  "(*standard-output* *standard-output*)"),
    "escape-context": ("(mezzano.format::*format-escape-tag* escape-tag)",
                       "(mezzano.format::*format-escape-tag* nil)"),
    "colon-argument-context": ("(mezzano.format::*format-colon-arguments* colon-arguments)",
                               "(mezzano.format::*format-colon-arguments* args)"),
    "defaults": ("parse-params start '(0 1 0 #\\Space)",
                 "parse-params start '(99 88 77 #\\_)"),
    "modifier-order": ("format-standard-justification\n                       XP ,(args) ,(initial) ,control ',atsign ',colon\n                       ',(atsignp (1- end)) the-params escape-tag\n                       colon-escape-tag\n                       ,(if (null *outer-end*)\n                            `(cdr ,(outer-args))\n                            (initial))",
                       "format-standard-justification\n                       XP ,(args) ,(initial) ,control ',colon ',atsign\n                       ',(atsignp (1- end)) the-params escape-tag\n                       colon-escape-tag\n                       ,(if (null *outer-end*)\n                            `(cdr ,(outer-args))\n                            (initial))"),
    "colon-fallback": ("                            (initial)))",
                       "                            (args)))"),
    "escape-propagation": ("(return-from ,*inner-end* nil)",
                           "nil"),
    "closing-atsign": ("',(atsignp (1- end))",
                       "nil"),
    "out-of-context-separator": ("(err 15 \"~~; appears out of context\" (1- end))",
                                 "(values)"),
    "printer-operation-delegation": ("mezzano.format::format-printer-operation",
                                     "mezzano.format::format-integer"),
    "printer-operation-parameter-order": (
        "XP ,(get-arg) (first the-params) (second the-params)\n"
        "        (third the-params) (fourth the-params)\n"
        "        ',atsign ',colon ,escape-value ',readably-is-nil",
        "XP ,(get-arg) (second the-params) (first the-params)\n"
        "        (third the-params) (fourth the-params)\n"
        "        ',atsign ',colon ,escape-value ',readably-is-nil"),
    "printer-operation-modifier-order": (
        "        ',atsign ',colon ,escape-value ',readably-is-nil",
        "        ',colon ',atsign ,escape-value ',readably-is-nil"),
    "printer-operation-colon": (
        "        ',atsign ',colon ,escape-value ',readably-is-nil",
        "        ',atsign nil ,escape-value ',readably-is-nil"),
    "printer-operation-escape": (
        "        ',atsign ',colon ,escape-value ',readably-is-nil",
        "        ',atsign ',colon nil ',readably-is-nil"),
}
for name, (original, replacement) in mutants.items():
    mutant = source.replace(original, replacement, 1)
    if mutant == source:
        raise SystemExit(f"unable to create {name} mutant")
    Path(sys.argv[2], f"{name}.lisp").write_text(mutant, encoding="utf-8")
MUTANT_PY
  for mutant in "$mutant_dir"/*.lisp; do
    if XP_JUSTIFICATION_MUTATION_RUN=1 XP_FORMAT_SOURCE="$mutant" "$0" >/dev/null 2>&1; then
      echo "XP justification mutation survived: $mutant" >&2
      exit 1
    fi
  done
  echo "XP FORMAT justification mutation negatives passed"
fi
