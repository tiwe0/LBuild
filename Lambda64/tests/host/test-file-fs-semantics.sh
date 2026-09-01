#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${FILE_FS_SOURCE:-"$repo_root/file/fs.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-fs-semantics.XXXXXX.lisp")
forms_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-fs-forms.XXXXXX.lisp")
trap 'rm -f "$test_file" "$forms_file"' EXIT

python3 - "$source_file" "$forms_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()


def extract_form(prefix, required=True):
    start = source.find(prefix)
    if start < 0:
        if required:
            raise SystemExit(f"missing source form: {prefix}")
        return None

    depth = 0
    in_string = False
    escaped = False
    line_comment = False
    block_comment = 0
    i = start
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
        elif block_comment:
            if ch == "#" and nxt == "|":
                block_comment += 1
                i += 1
            elif ch == "|" and nxt == "#":
                block_comment -= 1
                i += 1
        elif in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == ";":
            line_comment = True
        elif ch == "#" and nxt == "|":
            block_comment = 1
            i += 1
        elif ch == '"':
            in_string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1
    raise SystemExit(f"unterminated source form: {prefix}")

prefixes = [
    "(defun pathname-match-directory",
    "(defun pathname-match-p",
    "(defun mixed-case-p",
    "(defun case-correct-path-component",
    "(defun translate-one",
    "(defun translate-directory",
    "(defun translate-pathname",
    "(defun register-block-device-host-type",
    "(defun mount-block-device",
]
optional_prefixes = [
    "(defun match-directory-components",
    "(defun copy-filesystem-name-alist",
    "(defun filesystem-name-alist",
    "(defun filesystem-host-name",
]

forms = []
for prefix in optional_prefixes:
    form = extract_form(prefix, required=False)
    if form is not None:
        forms.append(form)
forms.extend(extract_form(prefix) for prefix in prefixes)
Path(sys.argv[2]).write_text("\n\n".join(forms) + "\n")
PY

cat >"$test_file" <<'LISP'
(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:with-mutex))

(in-package :mezzano.supervisor)

(defmacro with-mutex ((mutex) &body body)
  `(progn ,mutex ,@body))

(defpackage :mezzano.disk
  (:use :cl)
  (:export #:all-block-devices))

(in-package :mezzano.disk)

(defvar *test-block-devices* '())

(defun all-block-devices ()
  *test-block-devices*)

(defpackage :mezzano.file-system
  (:use :cl)
  (:shadow
   #:logical-pathname
   #:make-pathname
   #:pathname
   #:pathname-device
   #:pathname-directory
   #:pathname-host
   #:pathname-match-p
   #:pathname-name
   #:pathname-type
   #:pathname-version
   #:translate-pathname))

(in-package :mezzano.file-system)

(defclass file-system-host () ())
(defclass test-host (file-system-host) ())
(defclass logical-host (file-system-host) ())

(defclass pathname ()
  ((host :initarg :host :reader pathname-host)
   (device :initarg :device :reader pathname-device)
   (directory :initarg :directory :reader pathname-directory)
   (name :initarg :name :reader pathname-name)
   (type :initarg :type :reader pathname-type)
   (version :initarg :version :reader pathname-version))
  (:default-initargs :device nil :directory nil :name nil :type nil :version nil))

(defclass logical-pathname (pathname) ())

(defclass file-host-mount-mixin ()
  ((mount-state :initarg :mount-state :accessor file-host-mount-state)
   (mount-device :initarg :mount-device :accessor file-host-mount-device))
  (:default-initargs :mount-state :unmounted :mount-device nil))

(defgeneric mount-host (host block-device))
(defgeneric create-host (class block-device name-alist))

(defvar *host-alist* '())
(defvar *block-device-host-types* '())
(defvar *block-device-host-type-lock* nil)
(defvar *filesystems-alist* '())

(defun pathname (object)
  (etypecase object
    (pathname object)))

(defun make-pathname (&key host device directory name type version defaults)
  (make-instance (if (typep host 'logical-host) 'logical-pathname 'pathname)
                 :host (or host (and defaults (pathname-host defaults)))
                 :device (or device (and defaults (pathname-device defaults)))
                 :directory (or directory (and defaults (pathname-directory defaults)))
                 :name (or name (and defaults (pathname-name defaults)))
                 :type (or type (and defaults (pathname-type defaults)))
                 :version (or version (and defaults (pathname-version defaults)))))

(load (or (sb-ext:posix-getenv "FILE_FS_FORMS")
          (error "FILE_FS_FORMS is not set")))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun assert-equal (expected actual control &rest arguments)
  (unless (equal expected actual)
    (apply #'error
           (concatenate 'string control " (expected ~S, got ~S)")
           (append arguments (list expected actual)))))

(defun expect-error (thunk control)
  (unless (handler-case
              (progn (funcall thunk) nil)
            (error () t))
    (error control)))

(defun make-test-path (host directory)
  (make-pathname :host host :directory directory
                 :name "file" :type "lisp" :version 1))

(defclass test-mount-host (file-host-mount-mixin) ())

(defvar *create-host-calls* '())
(defvar *created-host-name* nil)

(defun copy-test-name-alist (name-alist)
  (mapcar (lambda (entry)
            (mapcar (lambda (value)
                      (if (stringp value) (copy-seq value) value))
                    entry))
          name-alist))

(defun mutate-test-name-alist (name-alist)
  (when name-alist
    (let ((entry (first name-alist)))
      (when (and (stringp (first entry))
                 (plusp (length (first entry))))
        (setf (char (first entry) 0) #\X))
      (when (and (stringp (second entry))
                 (plusp (length (second entry))))
        (setf (char (second entry) 0) #\X)))))

(defmethod mount-host ((host test-mount-host) block-device)
  (setf (file-host-mount-state host) :mounted
        (file-host-mount-device host) block-device)
  t)

(defmethod create-host ((class (eql :test-filesystem)) block-device name-alist)
  (push (list class block-device (copy-test-name-alist name-alist))
        *create-host-calls*)
  (setf *created-host-name*
        (let ((name (filesystem-host-name "UUID-A" name-alist)))
          (if name
              (if (stringp name) (copy-seq name) name)
              'auto-generated)))
  ;; A host implementation must not be able to mutate the authoritative
  ;; namespace through the snapshot supplied by MOUNT-BLOCK-DEVICE.
  (mutate-test-name-alist name-alist)
  *created-host-name*)

(defmethod create-host ((class (eql :rejecting-filesystem))
                        block-device name-alist)
  (push (list class block-device (copy-test-name-alist name-alist))
        *create-host-calls*)
  (mutate-test-name-alist name-alist)
  nil)

(defparameter *test-case*
  (or (sb-ext:posix-getenv "FILE_FS_CASE") "all"))

(defun test-case-enabled-p (name)
  (or (string= *test-case* "all")
      (string= *test-case* name)))

(let ((host (make-instance 'test-host)))
  (when (test-case-enabled-p "0132")
    (let ((source (make-test-path host '(:absolute "root" "a" "b" "leaf")))
          (from (make-test-path host '(:absolute "root" :wild-inferiors "leaf")))
          (to (make-test-path host '(:absolute "out" :wild-inferiors))))
      (assert-true (pathname-match-p source from)
                   "A non-terminal :WILD-INFERIORS pattern did not match its suffix")
      (assert-true
       (not (pathname-match-p
             (make-test-path host '(:absolute "root" "a" "wrong"))
             from))
       "A non-terminal :WILD-INFERIORS pattern ignored a mismatched suffix")
      (assert-equal '(:absolute "out" "a" "b")
                    (pathname-directory (translate-pathname source from to))
                    "FROM :WILD-INFERIORS did not capture only matched inferiors")
      (assert-equal '(:absolute "out")
                    (pathname-directory
                     (translate-pathname
                      (make-test-path host '(:absolute "root" "leaf"))
                      from to))
                    "FROM :WILD-INFERIORS did not support a zero-level match")
      (expect-error
       (lambda ()
         (translate-pathname
          (make-test-path host '(:absolute "root" "a" "wrong"))
          from to))
       "TRANSLATE-PATHNAME accepted a source that did not match FROM-WILDCARD")
      (expect-error
       (lambda ()
         (translate-pathname
          source
          (make-test-path (make-instance 'test-host)
                          '(:absolute "root" :wild-inferiors "leaf"))
          to))
       "TRANSLATE-PATHNAME ignored a FROM-WILDCARD host mismatch")
      (assert-equal '(:absolute "literal")
                    (pathname-directory
                     (translate-pathname
                      (make-test-path host nil)
                      (make-test-path host nil)
                      (make-test-path host '(:absolute "literal"))))
                    "A NIL FROM directory ignored the literal TO directory")))

  (when (test-case-enabled-p "0133")
    (let ((source (make-test-path host '(:absolute "root" "a" "b")))
          (from (make-test-path host '(:absolute "root" :wild-inferiors)))
          (to (make-test-path host
                              '(:absolute "out" :wild-inferiors "done"))))
      (assert-equal '(:absolute "out" "a" "b" "done")
                    (pathname-directory (translate-pathname source from to))
                    "TO :WILD-INFERIORS did not preserve its suffix")
      (assert-equal '(:absolute "out" "done")
                    (pathname-directory
                     (translate-pathname
                      (make-test-path host '(:absolute "root")) from to))
                    "TO :WILD-INFERIORS did not support an empty capture")
      (expect-error
       (lambda ()
         (translate-pathname
          (make-test-path host '(:absolute "root" "one" "tail"))
          (make-test-path host '(:absolute "root" :wild "tail"))
          (make-test-path host '(:absolute "out" :wild-inferiors))))
       "A TO :WILD-INFERIORS consumed a FROM :WILD capture")
      (assert-equal '(:absolute "out" "one")
                    (pathname-directory
                     (translate-pathname
                      (make-test-path host '(:absolute "root" "one" "two"))
                      (make-test-path host '(:absolute "root" :wild :wild))
                      (make-test-path host '(:absolute "out" :wild))))
                    "TO did not discard unused trailing FROM captures")
      (assert-equal '(:absolute "literal")
                    (pathname-directory
                     (translate-pathname
                      (make-test-path host '(:absolute "root" "one" "two"))
                      (make-test-path host '(:absolute "root" :wild :wild))
                      (make-test-path host '(:absolute "literal"))))
                    "A literal TO did not discard all FROM captures")
      (expect-error
       (lambda ()
         (translate-pathname
          (make-test-path host '(:absolute "root" "one"))
          (make-test-path host '(:absolute "root" :wild))
          (make-test-path host '(:absolute "out" :wild :wild))))
       "TRANSLATE-PATHNAME accepted an extra TO wildcard"))))

(when (test-case-enabled-p "0134")
  (let ((*block-device-host-types*
          '(:rejecting-filesystem :test-filesystem))
        (*host-alist* '())
        (*filesystems-alist*
          (list (list (copy-seq "UUID-A") (copy-seq "CONFIGURED")))))
    (setf *create-host-calls* '()
          *created-host-name* nil)
    (assert-equal "CONFIGURED" (filesystem-host-name "uuid-a")
                  "UUID lookup was not case-insensitive")
    (let ((snapshot (filesystem-name-alist)))
      (assert-true (not (eq (first snapshot)
                            (first *filesystems-alist*)))
                   "The namespace snapshot reused an authoritative entry")
      (assert-true (not (eq (first (first snapshot))
                            (first (first *filesystems-alist*))))
                   "The namespace snapshot reused the authoritative UUID string")
      (assert-true (not (eq (second (first snapshot))
                            (second (first *filesystems-alist*))))
                   "The namespace snapshot reused the authoritative name string")
      (mutate-test-name-alist snapshot)
      (assert-equal '(("UUID-A" "CONFIGURED")) *filesystems-alist*
                    "Mutating a namespace snapshot changed the authority"))
    (mount-block-device :mapped-disk)
    (assert-equal "CONFIGURED" *created-host-name*
                  "Configured UUID mapping did not take priority")
    (assert-equal '(("UUID-A" "CONFIGURED")) *filesystems-alist*
                  "CREATE-HOST mutated authoritative namespace strings")
    (assert-equal '(("UUID-A" "CONFIGURED"))
                  (third (first *create-host-calls*))
                  "The succeeding CREATE-HOST attempt saw mutated strings")
    (assert-equal 2 (length *create-host-calls*)
                  "Mapped mounting did not stop after the first success"))
  (let ((*block-device-host-types* '(:test-filesystem))
        (*host-alist* '())
        (*filesystems-alist* '()))
    (setf *create-host-calls* '()
          *created-host-name* nil)
    (mount-block-device :fallback-disk)
    (assert-equal 'auto-generated *created-host-name*
                  "Missing UUID mapping did not preserve host fallback naming"))
  (let* ((existing (make-instance 'test-mount-host))
         (*host-alist* (list (list "EXISTING" existing)))
         (*block-device-host-types* '(:test-filesystem))
         (*filesystems-alist* '(("UUID-A" configured))))
    (setf *create-host-calls* '())
    (mount-block-device :existing-disk)
    (assert-equal :mounted (file-host-mount-state existing)
                  "An existing unmounted host was not mounted first")
    (assert-true (null *create-host-calls*)
                 "CREATE-HOST ran after an existing host mounted successfully"))
  (let ((*block-device-host-types* '())
        (*filesystems-alist*
          (list (list (copy-seq "UUID-A") (copy-seq "CONFIGURED"))))
        (mezzano.disk::*test-block-devices* '(:first-disk :second-disk)))
    (setf *create-host-calls* '()
          *created-host-name* nil)
    (register-block-device-host-type :test-filesystem)
    (assert-equal '("CONFIGURED" "CONFIGURED")
                  (mapcar (lambda (call)
                            (filesystem-host-name "UUID-A" (third call)))
                          (reverse *create-host-calls*))
                  "REGISTER-BLOCK-DEVICE-HOST-TYPE leaked a mutated snapshot between attempts")
    (assert-equal '(("UUID-A" "CONFIGURED")) *filesystems-alist*
                  "Registration mutated authoritative namespace strings")))

(format t "file/fs pathname and namespace contract passed~%")
LISP

FILE_FS_FORMS="$forms_file" "$sbcl" --noinform --disable-debugger --script "$test_file"
