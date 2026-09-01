#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export FILE_COMPILER_REPO_ROOT="$repo_root"
source_file=${FILE_COMPILER_SOURCE:-"$repo_root/system/file-compiler.lisp"}
sbcl=${SBCL:-sbcl}
forms_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-file-compiler-forms.XXXXXX.lisp")
writer_forms_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-file-compiler-writer-forms.XXXXXX.lisp")
test_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-file-compiler-test.XXXXXX.lisp")
mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/mezzano-file-compiler-mutants.XXXXXX")
trap 'rm -f "$forms_file" "$writer_forms_file" "$test_file"; rm -rf "$mutant_dir"' EXIT

python3 - "$source_file" "$forms_file" "$writer_forms_file" <<'PY'
from pathlib import Path
import os
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
repo_root = Path(os.environ["FILE_COMPILER_REPO_ROOT"])
if re.search(r"(?im)^\s*;+\s*(?:TODO|FIXME)\b", source):
    raise SystemExit("file-compiler.lisp still contains TODO/FIXME markers")

required = {
    "macrolet lexical environment": r"eval-in-lexenv\s+\(expand-macrolet-function def\).*environment-macro-definitions-only\s+env",
    "source pathname LLF record": r"source-name.*\+llf-string\+.*save-character.*\+llf-drop\+",
    "direct LLF cons allocation": r"defmethod save-one-object \(\(object cons\).*\+llf-allocate-cons\+.*write-object-backlink object omap stream :keep t.*save-object \(car object\).*save-object \(cdr object\).*\+llf-initialize-cons\+",
    "guarded Unicode scalar predicate": r"defun llf-unicode-scalar-code-p.*<= 0 code #x10FFFF.*code-char code",
    "shared compact character predicate": r"defun llf-compact-character-p.*llf-unicode-scalar-code-p.*defmethod save-one-object \(\(object string\).*llf-compact-character-p.*defmethod save-one-object \(\(object character\).*llf-unicode-scalar-code-p",
    "arbitrary character constructor": r"defmethod save-one-object \(\(object character\).*%%make-character.*\+llf-funcall-n\+",
    "compiler macro expansion": r"compiler-macroexpand-1 expansion env",
    "lexical symbol macro assignment": r"macroexpand-1 symbol env",
    "explicit initial top-level environment": r"handle-top-level-form.*:not-compile-time\s+nil",
}
for description, pattern in required.items():
    if not re.search(pattern, source, re.S):
        raise SystemExit(f"missing production contract: {description}")

llf_data_types = (repo_root / "system/data-types.lisp").read_text(encoding="utf-8")
runtime_loader = (repo_root / "system/load.lisp").read_text(encoding="utf-8")
cold_loader = (repo_root / "tools/cold-generator2/load.lisp").read_text(encoding="utf-8")
if "(defparameter *llf-version* 37)" not in llf_data_types:
    raise SystemExit("cons allocation LLF extension did not bump the format version")
for description, text in {
    "runtime loader": runtime_loader,
    "cold-generator loader": cold_loader,
}.items():
    for command in ("+llf-allocate-cons+", "+llf-initialize-cons+"):
        if command not in text:
            raise SystemExit(f"{description} does not implement {command}")

def extract(prefix):
    start = source.index(prefix)
    depth = 0
    in_string = False
    escaped = False
    line_comment = False
    for index in range(start, len(source)):
        char = source[index]
        if line_comment:
            if char == "\n":
                line_comment = False
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
            line_comment = True
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated form: {prefix}")

forms = [
    extract("(defun make-macrolet-env"),
    extract("(defun write-llf-header"),
    extract("(defun save-integer"),
    extract("(defun save-character"),
    extract("(defun llf-unicode-scalar-code-p"),
    extract("(defun llf-compact-character-p"),
    extract("(defmethod save-one-object ((object cons)"),
    extract("(defmethod save-one-object ((object string)"),
    extract("(defmethod save-one-object ((object character)"),
    extract("(defun compile-top-level-form-for-value"),
]
Path(sys.argv[2]).write_text("\n\n".join(forms) + "\n", encoding="utf-8")
writer_forms = [
    extract("(defmethod save-one-object ((object symbol)"),
    extract("(defmethod save-one-object ((object vector)"),
    extract("(defun write-object-backlink"),
    extract("(defun save-object"),
]
Path(sys.argv[3]).write_text("\n\n".join(writer_forms) + "\n", encoding="utf-8")
PY

cat >"$test_file" <<'LISP'
(defpackage :mezzano.compiler (:use :cl))
(defpackage :mezzano.internals
  (:nicknames :sys.int)
  (:use :cl)
  (:shadow #:char-code #:code-char #:compile-file #:compile-file-pathname))
(in-package :mezzano.internals)

(defconstant +llf-string+ #x07)
(defconstant +llf-cons+ #x03)
(defconstant +llf-symbol+ #x04)
(defconstant +llf-uninterned-symbol+ #x05)
(defconstant +llf-allocate-cons+ #x2F)
(defconstant +llf-initialize-cons+ #x30)
(defconstant +llf-backlink+ #x01)
(defconstant +llf-add-backlink+ #x14)
(defconstant +llf-simple-vector+ #x0C)
(defconstant +llf-typed-array+ #x1E)
(defconstant +llf-typed-integer-array+ #x2E)
(defconstant +llf-initialize-array+ #x2A)
(defconstant +llf-character+ #x0D)
(defconstant +llf-character-with-bits+ #x1A)
(defconstant +llf-funcall-n+ #x1F)
(defconstant +llf-drop+ #x20)
(defconstant +llf-if+ #x26)
(defconstant +llf-else+ #x27)
(defconstant +llf-fi+ #x28)
(defconstant +llf-arch-x86-64+ 1)
(defconstant +llf-arch-arm64+ 2)
(defparameter *llf-version* 37)
(defparameter *llf-architecture* :x86-64)
(defparameter *llf-dry-run* nil)
(defparameter *compiling-make-load-form* nil)
(defparameter *llf-forms* nil)
(defparameter *events* nil)
(defparameter *saved-objects* nil)
(defparameter *stack-depth* 0)
(defparameter *top-level-form-number* 0)
(defparameter *character-code-overrides* nil)
(defparameter *character-bit-overrides* nil)

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun char-code (character)
  (or (cdr (assoc character *character-code-overrides*))
      (cl:char-code character)))

(defun code-char (code)
  (and (<= 0 code #x10FFFF)
       (not (<= #xD800 code #xDFFF))
       (not (<= #xFDD0 code #xFDEF))
       (not (= (logand code #xFFFE) #xFFFE))
       (cl:code-char code)))

(defun char-bits (character)
  (or (cdr (assoc character *character-bit-overrides*)) 0))

(defun %%make-character (code bits)
  (list :character code bits))

(defun expand-macrolet-function (definition)
  (declare (ignore definition))
  '(lambda (&rest arguments) (declare (ignore arguments)) :expanded))

(defparameter *seen-eval-environment* nil)
(defun eval-in-lexenv (form environment)
  (setf *seen-eval-environment* environment)
  (eval form))

(defun mezzano.compiler::environment-macro-definitions-only (environment)
  (list :macros-from environment))

(defun mezzano.compiler::extend-environment (environment &key functions variables declarations)
  (declare (ignore variables declarations))
  (list :parent environment :functions functions))

(defgeneric save-one-object (object omap stream))
(defun compile-top-level-form-for-value (form environment)
  (declare (ignore environment))
  (incf *stack-depth*)
  (push (list :allocate form) *events*))
(defun compile-top-level-form (form environment)
  (declare (ignore environment))
  (push (list :initialize form) *events*))
(defun write-object-backlink (object omap stream &key keep)
  (declare (ignore omap stream))
  (unless keep
    (decf *stack-depth*))
  (push (list :backlink object keep) *events*))
(defun save-object (object omap stream)
  (declare (ignore omap stream))
  (push object *saved-objects*))
(defun compile-file-load-time-value (&rest arguments)
  (declare (ignore arguments)))
(defun mezzano.compiler::compiler-macroexpand-1 (form environment)
  (declare (ignore environment))
  (values form nil))
(defun add-to-llf (&rest arguments)
  (declare (ignore arguments)))
(defun add-deferred-lambda (&rest arguments)
  (declare (ignore arguments)))
(defun valid-funcall-function-p (form)
  (declare (ignore form))
  nil)
(defun funcall-function-name (form)
  (second form))

(load (sb-ext:posix-getenv "FILE_COMPILER_FORMS"))
(defparameter *production-compile-top-level-form-for-value*
  (symbol-function 'compile-top-level-form-for-value))

;; TF-WI-0375: outer lexical macro definitions are used while creating a
;; nested MACROLET expansion function.
(let ((result (make-macrolet-env '((inner () :ok)) :outer-environment)))
  (assert-equal '(:macros-from :outer-environment)
                *seen-eval-environment*
                "macrolet definition evaluation environment")
  (unless (getf result :functions)
    (error "macrolet bindings were not installed")))

;; TF-WI-0376, TF-WI-0377, and TF-WI-0378: the compatible LLF prefix is
;; followed by a discarded source pathname, and UTF-8 boundary encodings are
;; emitted by the production functions.
(let ((path (format nil "~A/mezzano-file-compiler.llf" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))))
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
    (write-llf-header stream #p"source/test.lisp"))
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (loop for byte = (read-byte stream nil nil)
                       while byte collect byte)))
      (assert-equal '(76 76 70 1 37 1 7 16)
                    (subseq bytes 0 8)
                    "LLF fixed header and source string prefix")
      (assert-equal "source/test.lisp"
                    (map 'string #'cl:code-char (subseq bytes 8 24))
                    "LLF source pathname")
      (assert-equal +llf-drop+ (nth 24 bytes) "LLF source pathname drop")))
  (delete-file path))
(let ((path (format nil "~A/mezzano-character.bin" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))))
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
    (save-character (cl:code-char #x7FF) stream)
    (save-character (cl:code-char #x800) stream)
    (save-character (cl:code-char #x10000) stream))
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (assert-equal '(#xDF #xBF #xE0 #xA0 #x80 #xF0 #x90 #x80 #x80)
                  (loop for byte = (read-byte stream nil nil)
                        while byte collect byte)
                  "UTF-8 boundary encodings"))
  (delete-file path))

;; The scalar guard must run before CODE-CHAR. Mezzano rejects #xFFFF as a
;; noncharacter, accepts #x10000, and represents the remaining 21-bit codes
;; only through %%MAKE-CHARACTER.
(assert-equal nil (llf-unicode-scalar-code-p #xFFFF) "rejected Unicode noncharacter")
(assert-equal t (not (null (llf-unicode-scalar-code-p #x10000))) "accepted Unicode scalar")
(assert-equal nil (llf-unicode-scalar-code-p #x110000) "first non-Unicode code")
(assert-equal nil (llf-unicode-scalar-code-p #x1FFFFF) "largest implementation code")

(flet ((assert-fallback (sentinel code description)
         (let ((path (format nil "~A/mezzano-character-method.bin"
                             (or (sb-ext:posix-getenv "TMPDIR") "/tmp")))
               (*character-code-overrides* (list (cons sentinel code)))
               (*saved-objects* nil))
           (with-open-file (stream path :direction :output :if-exists :supersede
                                        :element-type '(unsigned-byte 8))
             (save-one-object sentinel (make-hash-table) stream))
           (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
             (assert-equal (list code 0 '%%make-character 2)
                           (reverse *saved-objects*)
                           description)
             (assert-equal +llf-funcall-n+ (read-byte stream)
                           "arbitrary character fallback command"))
           (delete-file path))))
  (assert-fallback #\X #xFFFF "CODE-CHAR-rejected fallback objects")
  (assert-fallback #\Y #x110000 "first implementation-only fallback objects")
  (assert-fallback #\Z #x1FFFFF "largest implementation-only fallback objects"))
(let ((path (format nil "~A/mezzano-compact-character-method.bin"
                    (or (sb-ext:posix-getenv "TMPDIR") "/tmp")))
      (*character-code-overrides* (list (cons #\W #x10000))))
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
    (save-one-object #\W (make-hash-table) stream))
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (assert-equal '(#x0D #xF0 #x90 #x80 #x80)
                  (loop for byte = (read-byte stream nil nil)
                        while byte collect byte)
                  "#x10000 compact character method"))
  (delete-file path))
(let ((path (format nil "~A/mezzano-attributed-character-method.bin"
                    (or (sb-ext:posix-getenv "TMPDIR") "/tmp")))
      (*character-bit-overrides* (list (cons #\A 1))))
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
    (save-one-object #\A (make-hash-table) stream))
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (assert-equal '(#x1A #x41 1)
                  (loop for byte = (read-byte stream nil nil)
                        while byte collect byte)
                  "attributed character method"))
  (delete-file path))

;; TF-WI-0379: native LLF allocation and backlinking precede edge
;; initialization. This works for cycles through arbitrary serializable
;; containers without recursively compiling a top-level form.
(setf (symbol-function 'compile-top-level-form-for-value)
      (lambda (form environment)
        (declare (ignore environment))
        (incf *stack-depth*)
        (push (list :allocate form) *events*)))
(setf (symbol-function 'compile-top-level-form)
      (lambda (form environment)
        (declare (ignore environment))
        (push (list :initialize form) *events*)))
(let ((*character-bit-overrides* (list (cons #\A 1)))
      (*events* nil)
      (*stack-depth* 0))
  (save-one-object "A" (make-hash-table) (make-broadcast-stream))
  (let* ((events (reverse *events*))
         (initialization (second (third events))))
    (assert-equal '(:allocate :backlink :initialize)
                  (mapcar #'first events)
                  "attributed string uses allocation path")
    (assert-equal t (third (second events)) "attributed string backlink keep")
    (unless (search "SETF" (prin1-to-string initialization))
      (error "attributed string initialization was not emitted"))))
(let ((*character-code-overrides* (list (cons #\B #x110000)))
      (*events* nil)
      (*stack-depth* 0))
  (save-one-object "B" (make-hash-table) (make-broadcast-stream))
  (assert-equal '(:allocate :backlink :initialize)
                (mapcar #'first (reverse *events*))
                "noncompact string uses allocation path"))
(flet ((read-bytes (path)
         (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
           (loop for byte = (read-byte stream nil nil)
                 while byte collect byte))))
  (let ((path (format nil "~A/mezzano-cons.bin"
                      (or (sb-ext:posix-getenv "TMPDIR") "/tmp")))
        (*events* nil)
        (*saved-objects* nil))
    (with-open-file (stream path :direction :output :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (save-one-object '(1 . 2) (make-hash-table) stream))
    (assert-equal '((:backlink (1 . 2) t)) (reverse *events*)
                  "cons backlink follows native allocation")
    (assert-equal '(1 2) (reverse *saved-objects*) "cons CAR/CDR order")
    (assert-equal (list +llf-allocate-cons+ +llf-initialize-cons+)
                  (read-bytes path)
                  "native cons LLF commands")
    (delete-file path)))

;; Reload the production object-map writer after the lightweight directive
;; tests above. Its two passes must serialize a mixed cons/vector cycle without
;; entering the former :SAVE-IN-PROGRESS failure path.
(defun never-deferred-function-p (object)
  (declare (ignore object))
  nil)
(deftype deferred-function ()
  '(and cons (satisfies never-deferred-function-p)))
(defun deferred-function-function (&rest arguments)
  (declare (ignore arguments))
  (error "unexpected deferred function"))
(defun deferred-function-additional-commands (&rest arguments)
  (declare (ignore arguments))
  (error "unexpected deferred function"))
(load (sb-ext:posix-getenv "FILE_COMPILER_WRITER_FORMS"))
(let* ((cell (cons nil nil))
       (vector (vector cell))
       (omap (make-hash-table))
       (path (format nil "~A/mezzano-mixed-cycle.bin"
                     (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))))
  (setf (car cell) vector)
  (let ((*llf-dry-run* t))
    (save-object cell omap (make-broadcast-stream)))
  (with-open-file (stream path :direction :output :if-exists :supersede
                           :element-type '(unsigned-byte 8))
    (let ((*llf-dry-run* nil))
      (save-object cell omap stream)))
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (loop for byte = (read-byte stream nil nil)
                       while byte collect byte)))
      (assert-equal +llf-allocate-cons+ (first bytes)
                    "mixed cycle allocates cons before edges")
      (unless (member +llf-initialize-cons+ bytes)
        (error "mixed cycle omitted native cons initialization: ~S" bytes))
      (unless (member +llf-backlink+ bytes)
        (error "mixed cycle omitted cons backlink: ~S" bytes))))
  (delete-file path))

;; Replace the recording compiler with the production implementation for the
;; compiler-macro regression.
(setf (symbol-function 'compile-top-level-form-for-value)
      *production-compile-top-level-form-for-value*)
(defun mezzano.compiler::compiler-macroexpand-1 (form environment)
  (declare (ignore environment))
  (if (and (consp form) (eq (first form) 'compiler-macro-probe))
      (values '(quote 42) t)
      (values form nil)))
(defun add-to-llf (action &rest objects)
  (push (cons action objects) *llf-forms*))
(let ((*llf-forms* nil))
  (compile-top-level-form-for-value '(compiler-macro-probe) nil)
  (assert-equal '((nil 42)) *llf-forms* "compiler macro expansion"))

;; TF-WI-0381: exercise a real host lexical symbol-macro environment. The
;; lowered LLF must reference the expansion place, never assign the symbol's
;; global value.
(require :sb-cltl2)
(let* ((environment
         (sb-cltl2:augment-environment nil
                                      :symbol-macro '((lexical-target (car cell)))))
       (*llf-forms* nil))
  (compile-top-level-form-for-value '(setq lexical-target 7) environment)
  (let ((printed (prin1-to-string *llf-forms*)))
    (when (search "LEXICAL-TARGET" printed)
      (error "lexical symbol macro was lowered as a global assignment: ~A" printed))
    (unless (search "CELL" printed)
      (error "lexical symbol-macro expansion was not lowered: ~A" printed))))

(format t "system file compiler semantics passed~%")
LISP

FILE_COMPILER_REPO_ROOT="$repo_root" \
FILE_COMPILER_FORMS="$forms_file" \
FILE_COMPILER_WRITER_FORMS="$writer_forms_file" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"

if [[ ${FILE_COMPILER_MUTATION_RUN:-0} != 1 ]]; then
  python3 - "$source_file" "$mutant_dir" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutants = {
    "all-compact-string": source.replace(
        "#'llf-compact-character-p", "(constantly t)", 1),
    "character-le-unicode-limit": source.replace(
        "(llf-unicode-scalar-code-p (char-code object))",
        "(<= (char-code object) #x10FFFF)", 1),
    "setq-lookup-nil": source.replace(
        "(macroexpand-1 symbol env)", "(macroexpand-1 symbol nil)", 1),
    "cons-without-keep": source.replace(
        "(write-object-backlink object omap stream :keep t)",
        "(write-object-backlink object omap stream)", 1),
    "cons-missing-native-allocation": source.replace(
        "(write-byte +llf-allocate-cons+ stream)", "(values)", 1),
}
for name, mutant in mutants.items():
    if mutant == source:
        raise SystemExit(f"mutation did not apply: {name}")
    Path(sys.argv[2], name + ".lisp").write_text(mutant, encoding="utf-8")
PY
  for mutant in "$mutant_dir"/*.lisp; do
    if FILE_COMPILER_MUTATION_RUN=1 FILE_COMPILER_SOURCE="$mutant" \
         "$0" >/dev/null 2>&1; then
      echo "mutation unexpectedly survived: $(basename "$mutant")" >&2
      exit 1
    fi
  done
  echo "system file compiler mutation negatives passed"
fi
