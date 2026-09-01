#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${FILE_LOCAL_SOURCE:-"$repo_root/file/local.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-local-semantics.XXXXXX.lisp")
forms_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-local-forms.XXXXXX.lisp")
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
    "(defun file-container-key",
    "(defun read-directory-entry",
    "(defun version-position",
    "(defun local-directory-pathname",
    "(defun match-version",
    "(defun match-in-directory",
    "(defmethod directory-using-host",
    "(defun walk-directory",
    "(defun resolve-path",
    "(defun canonicalize-directory-file-pathname",
    "(defun directory-key",
    "(defun remove-specific-file",
    "(defmethod delete-file-using-host",
]

optional_prefixes = [
    "(defun wildcard-string-match-p",
    "(defun pathname-component-match-p",
    "(defun file-deleted-p",
    "(defun mark-file-deleted",
    "(defun expunge-file-container",
    "(defmethod expunge-directory-using-host",
    "(defun merge-file-plists",
]

forms = [extract_form(prefix) for prefix in prefixes]
forms.extend(form for prefix in optional_prefixes
             if (form := extract_form(prefix, required=False)) is not None)
forms.append(extract_form("(defmethod close ((stream local-stream)"))
Path(sys.argv[2]).write_text("\n\n".join(forms) + "\n")
PY

cat >"$test_file" <<'LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:export #:bsearch))

(in-package :mezzano.internals)

(defun bsearch (item sequence &key key)
  (position item sequence :key key :test #'=))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:with-mutex))

(in-package :mezzano.supervisor)

(defmacro with-mutex ((mutex) &body body)
  `(progn
     ,mutex
     ,@body))

(defpackage :mezzano.file-system
  (:use :cl)
  (:export
   #:directory-using-host
   #:delete-file-using-host
   #:expunge-directory-using-host
   #:file-system-host
   #:simple-file-error))

(in-package :mezzano.file-system)

(defclass file-system-host () ())
(define-condition simple-file-error (simple-error)
  ((pathname :initarg :pathname :reader error-pathname)))
(defgeneric directory-using-host (host pathname &key))
(defgeneric delete-file-using-host (host pathname &key))
(defgeneric expunge-directory-using-host (host pathname &key))

(defpackage :mezzano.file-system.local
  (:use :cl :mezzano.file-system)
  (:shadow
   #:close
   #:file-stream
   #:make-pathname
   #:pathname
   #:pathname-device
   #:pathname-directory
   #:pathname-host
   #:pathname-name
   #:pathname-type
   #:pathname-version))

(in-package :mezzano.file-system.local)

(defclass pathname ()
  ((host :initarg :host :reader pathname-host)
   (device :initarg :device :reader pathname-device)
   (directory :initarg :directory :reader pathname-directory)
   (name :initarg :name :reader pathname-name)
   (type :initarg :type :reader pathname-type)
   (version :initarg :version :reader pathname-version))
  (:default-initargs :host nil :device nil :directory nil :name nil :type nil :version nil))

(defun make-pathname (&key
                        (host nil hostp)
                        (device nil devicep)
                        (directory nil directoryp)
                        (name nil namep)
                        (type nil typep)
                        (version nil versionp)
                        defaults)
  (labels ((default (reader suppliedp value)
             (if suppliedp value (and defaults (funcall reader defaults)))))
    (make-instance 'pathname
                   :host (default #'pathname-host hostp host)
                   :device (default #'pathname-device devicep device)
                   :directory (default #'pathname-directory directoryp directory)
                   :name (default #'pathname-name namep name)
                   :type (default #'pathname-type typep type)
                   :version (default #'pathname-version versionp version))))

(defclass local-file-host (file-system-host)
  ((root :initarg :root :accessor local-host-root)
   (lock :initform nil :reader local-host-lock)))

(defclass local-file ()
  ((truename :initarg :truename :accessor file-truename)
   (storage :initarg :storage :accessor file-storage)
   (plist :initarg :plist :accessor file-plist)
   (lock :initform nil :reader file-lock))
  (:default-initargs :plist '()))

(defclass file-stream () ())

(defclass local-stream (file-stream)
  ((file :initarg :file :reader local-stream-file)
   (superseded-file :initarg :superseded-file :reader superseded-file))
  (:default-initargs :superseded-file nil))

(defgeneric close (stream &key abort &allow-other-keys))

(defmethod close ((stream file-stream) &key abort &allow-other-keys)
  (declare (ignore abort))
  t)

(defmacro with-host-locked ((host) &body body)
  `(mezzano.supervisor:with-mutex ((local-host-lock ,host))
     ,@body))

(load (or (sb-ext:posix-getenv "FILE_LOCAL_FORMS")
          (error "FILE_LOCAL_FORMS is not set")))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(defun assert-equal (expected actual control &rest arguments)
  (unless (equal expected actual)
    (apply #'error
           (concatenate 'string control " (expected ~S, got ~S)")
           (append arguments (list expected actual)))))

(defun expect-error (thunk control &rest arguments)
  (unless (handler-case
              (progn (funcall thunk) nil)
            (error () t))
    (apply #'error control arguments)))

(defun make-test-path (host directory &key name type version)
  (make-pathname :host host
                 :directory directory
                 :name name
                 :type type
                 :version version))

(defun make-test-file (host directory name type version &key (plist '()) storage)
  (make-instance 'local-file
                 :truename (make-test-path host directory
                                           :name name :type type :version version)
                 :storage (or storage
                              (make-array 0 :adjustable t :fill-pointer 0))
                 :plist plist))

(defun make-test-directory (host directory name)
  (make-test-file host directory name "directory" 1
                  :storage (make-array 1
                                       :initial-element
                                       (make-hash-table :test 'equalp))))

(defun directory-table (directory)
  (aref (file-storage directory) 0))

(defun add-test-entry (directory file)
  (let* ((path (file-truename file))
         (key (cons (pathname-name path) (pathname-type path)))
         (old (gethash key (directory-table directory))))
    (setf (gethash key (directory-table directory))
          (if old
              (concatenate 'vector old (vector file))
              (vector file)))
    file))

(defun result-names (paths)
  (sort (mapcar #'pathname-name paths) #'string-lessp))

(defun result-directories (paths)
  (sort (mapcar #'pathname-directory paths)
        #'string-lessp
        :key #'prin1-to-string))

(defun assert-canonical-directory-results (expected paths control)
  (assert-equal expected (result-directories paths) control)
  (assert-true (every (lambda (path)
                        (and (null (pathname-name path))
                             (null (pathname-type path))
                             (eql (pathname-version path) :newest)
                             (notany (lambda (component)
                                       (member component '(:wild :wild-inferiors)))
                                     (pathname-directory path))))
                      paths)
               "~A returned a wildcard or non-canonical directory pathname"
               control))

(defparameter *test-case*
  (or (sb-ext:posix-getenv "FILE_LOCAL_CASE") "all"))

(defun test-case-enabled-p (name)
  (or (string= *test-case* "all")
      (string= *test-case* name)))

;; Directory traversal supports wildcard strings in every string pathname
;; component, and :WILD-INFERIORS consumes zero or more levels even when it is
;; followed by a suffix.
(when (or (test-case-enabled-p "0137")
          (test-case-enabled-p "0138"))
  (let* ((root (make-test-directory nil '(:absolute) "ROOT"))
         (host (make-instance 'local-file-host :root root))
         (src (make-test-directory host '(:absolute) "src"))
         (src-old (make-test-directory host '(:absolute) "src-old"))
         (vendor (make-test-directory host '(:absolute) "vendor"))
         (vendor-src (make-test-directory host '(:absolute "vendor") "src"))
         (src-core (make-test-directory host '(:absolute "src") "core"))
         (vendor-src-core (make-test-directory host '(:absolute "vendor" "src") "core")))
    (setf (slot-value root 'truename) (make-test-path host '(:absolute)))
    (dolist (directory (list src src-old vendor))
      (add-test-entry root directory))
    (add-test-entry vendor vendor-src)
    (add-test-entry src src-core)
    (add-test-entry vendor-src vendor-src-core)
    (add-test-entry src (make-test-file host '(:absolute "src") "alpha" "lisp" 1))
    (add-test-entry src-old (make-test-file host '(:absolute "src-old") "archive" "lisp" 1))
    (add-test-entry vendor-src (make-test-file host '(:absolute "vendor" "src") "beta" "lisp" 1))
    (add-test-entry src-core (make-test-file host '(:absolute "src" "core") "core-a" "lisp" 1))
    (add-test-entry vendor-src-core
                    (make-test-file host '(:absolute "vendor" "src" "core")
                                    "core-b" "lisp" 1))

    (when (test-case-enabled-p "0137")
      (assert-equal '("alpha" "archive")
                    (result-names
                     (directory-using-host
                      host (make-test-path host '(:absolute "src*")
                                           :name "a*" :type "li*" :version :newest)))
                    "Wildcard string directory/name/type matching failed")
      (assert-canonical-directory-results
       '((:absolute "src") (:absolute "src-old"))
       (directory-using-host
        host (make-test-path host '(:absolute "src*") :version :newest))
       "Directory-only wildcard-string matching")
      (assert-true (wildcard-string-match-p "*" "")
                   "A wildcard did not match an empty string")
      (assert-true (wildcard-string-match-p "a**A" "alpha")
                   "Adjacent wildcards did not match case-insensitively")
      (assert-true (not (wildcard-string-match-p "alpha*" "beta"))
                   "A wildcard string matched an unrelated value"))
    (when (test-case-enabled-p "0138")
      (assert-equal '("alpha" "beta")
                    (result-names
                     (directory-using-host
                      host (make-test-path host '(:absolute :wild-inferiors "src")
                                           :name :wild :type "lisp" :version :newest)))
                    ":WILD-INFERIORS followed by an exact suffix failed")
      (assert-equal '("core-a" "core-b")
                    (result-names
                     (directory-using-host
                      host (make-test-path host '(:absolute :wild-inferiors "src" :wild)
                                           :name :wild :type "lisp" :version :newest)))
                    ":WILD-INFERIORS followed by a wildcard suffix failed")
      (assert-equal '("alpha" "archive" "beta" "core-a" "core-b")
                    (result-names
                     (directory-using-host
                      host (make-test-path host :wild
                                           :name :wild :type "lisp" :version :newest)))
                    "A :WILD directory did not expand to recursive traversal")
      (assert-canonical-directory-results
       '((:absolute "src") (:absolute "vendor" "src"))
       (directory-using-host
        host (make-test-path host '(:absolute :wild-inferiors "src")
                             :version :newest))
       "Directory-only :WILD-INFERIORS suffix matching")
      (assert-canonical-directory-results
       '((:absolute "src" "core")
         (:absolute "vendor" "src" "core"))
       (directory-using-host
        host (make-test-path host
                             '(:absolute :wild-inferiors :wild "core")
                             :version :newest))
       "Directory-only intermediate :WILD matching"))))

;; DELETE marks selected versions and keeps them addressable until EXPUNGE.
;; EXPUNGE physically removes only marked versions from the selected directory.
(when (test-case-enabled-p "0139")
  (let* ((root (make-test-directory nil '(:absolute) "ROOT"))
       (host (make-instance 'local-file-host :root root))
       (files (loop for version from 1 to 3
                    collect (make-test-file host '(:absolute) "report" "txt" version)))
       (key (cons "report" "txt")))
  (setf (slot-value root 'truename) (make-test-path host '(:absolute)))
  (dolist (file files)
    (add-test-entry root file))
  (delete-file-using-host
   host (make-test-path host '(:absolute) :name "report" :type "txt" :version 2))
  (assert-true (= (length (gethash key (directory-table root))) 3)
               "DELETE physically removed a file before EXPUNGE")
  (assert-true (getf (file-plist (second files)) :deleted)
               "DELETE did not mark the selected version")
  (assert-true (not (getf (file-plist (first files)) :deleted))
               "DELETE marked an unselected version")
  (assert-true (eq (read-directory-entry root "report" "txt" 2) (second files))
               "A deleted file stopped being addressable before EXPUNGE")
  (expunge-directory-using-host host (make-test-path host '(:absolute)))
  (let ((remaining (gethash key (directory-table root))))
    (assert-true (= (length remaining) 2)
                 "EXPUNGE did not remove exactly one marked version")
    (assert-equal '(1 3)
                  (map 'list (lambda (file)
                               (pathname-version (file-truename file)))
                       remaining)
                  "EXPUNGE changed surviving version order"))
  (delete-file-using-host
   host (make-test-path host '(:absolute) :name "report" :type "txt" :version :wild))
  (assert-true (every (lambda (file) (getf (file-plist file) :deleted))
                      (coerce (gethash key (directory-table root)) 'list))
               "Wildcard DELETE did not mark every remaining version")
  (expunge-directory-using-host host (make-test-path host '(:absolute)))
  (assert-true (null (gethash key (directory-table root)))
               "EXPUNGE left an empty version container in the directory")
  (expect-error
   (lambda ()
     (delete-file-using-host
      host (make-test-path host '(:absolute) :name "missing" :type "txt" :version 1)))
    "Deleting a missing file did not signal an error")))

;; Expunging a child directory neither recurses into it nor touches marked
;; entries in its parent, and a file pathname is rejected as a directory.
(when (test-case-enabled-p "0139")
  (let* ((root (make-test-directory nil '(:absolute) "ROOT"))
       (host (make-instance 'local-file-host :root root))
       (archive (make-test-directory host '(:absolute) "archive"))
       (root-file (make-test-file host '(:absolute) "root-marked" "txt" 1))
       (stale (make-test-file host '(:absolute "archive") "stale" "txt" 1))
       (live (make-test-file host '(:absolute "archive") "live" "txt" 1)))
  (setf (slot-value root 'truename) (make-test-path host '(:absolute)))
  (add-test-entry root archive)
  (add-test-entry root root-file)
  (add-test-entry archive stale)
  (add-test-entry archive live)
  (delete-file-using-host
   host (make-test-path host '(:absolute)
                        :name "root-marked" :type "txt" :version 1))
  (delete-file-using-host
   host (make-test-path host '(:absolute "archive")
                        :name "stale" :type "txt" :version 1))
  (expunge-directory-using-host
   host (make-test-path host '(:absolute "archive")))
  (assert-true (eq (read-directory-entry root "root-marked" "txt" 1) root-file)
               "Child expunge removed a marked parent entry")
  (assert-true (null (read-directory-entry archive "stale" "txt" 1))
               "Child expunge retained its marked entry")
  (assert-true (eq (read-directory-entry archive "live" "txt" 1) live)
               "Child expunge removed an unmarked sibling")
  (assert-true
   (handler-case
       (progn
         (expunge-directory-using-host
          host (make-test-path host '(:absolute)
                               :name "root-marked" :type "txt" :version 1))
         nil)
     (simple-file-error () t)
     (error (condition)
       (error "Non-directory expunge signalled the wrong condition: ~S" condition)))
    "Expunging a file pathname did not signal SIMPLE-FILE-ERROR")))

;; A successful :SUPERSEDE close merges replacement metadata over retained
;; metadata, retains old-only keys, canonicalizes duplicate indicators, and
;; atomically swaps the storage. Abort must leave the target untouched.
(when (test-case-enabled-p "0140")
  (let* ((old-storage (make-array 1 :initial-contents '(1)))
       (new-storage (make-array 2 :initial-contents '(8 9)))
       (target (make-instance 'local-file
                              :truename nil
                              :storage old-storage
                              :plist '(:creation-date 100 :write-date 200
                                       :owner "old" :shared "old")))
       (replacement (make-instance 'local-file
                                   :truename nil
                                   :storage new-storage
                                   :plist '(:write-date 300 :shared "new"
                                            :encoding :utf-8 :shared "stale")))
       (stream (make-instance 'local-stream
                              :file replacement
                              :superseded-file target)))
  (close stream)
  (assert-true (eq (file-storage target) new-storage)
               "SUPERSEDE close did not install replacement storage")
  (assert-equal "old" (getf (file-plist target) :owner)
                "SUPERSEDE lost an old-only property")
  (assert-equal "new" (getf (file-plist target) :shared)
                "Replacement property did not override the old property")
  (assert-equal :utf-8 (getf (file-plist target) :encoding)
                "SUPERSEDE lost a replacement-only property")
  (assert-true (= (count :shared (file-plist target)) 1)
               "SUPERSEDE retained duplicate property indicators")
  (assert-true (and (integerp (getf (file-plist target) :creation-date))
                    (= (getf (file-plist target) :creation-date)
                       (getf (file-plist target) :write-date)))
               "SUPERSEDE did not apply its close timestamp")
  (let* ((abort-target (make-instance 'local-file
                                      :truename nil
                                      :storage old-storage
                                      :plist '(:owner "stable")))
         (abort-stream (make-instance 'local-stream
                                      :file replacement
                                      :superseded-file abort-target)))
    (close abort-stream :abort t)
    (assert-true (eq (file-storage abort-target) old-storage)
                 "Aborted SUPERSEDE changed target storage")
    (assert-equal '(:owner "stable") (file-plist abort-target)
                  "Aborted SUPERSEDE changed target properties"))))

(format t "local filesystem wildcard/delete/plist contract passed~%")
LISP

FILE_LOCAL_FORMS="$forms_file" "$sbcl" --noinform --disable-debugger --script "$test_file"
