#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${FAT32_SOURCE:-"$repo_root/file/fat32.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-fat32-verbose.XXXXXX.lisp")
trap 'python3 - "$test_file" <<'"'"'PY'"'"'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])


def extract_form(marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"missing FAT32 source form: {marker}")
    depth = 0
    in_string = False
    escaped = False
    comment = False
    for index in range(start, len(source)):
        character = source[index]
        if comment:
            if character == "\n":
                comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == ";":
            comment = True
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated FAT32 source form: {marker}")


method = extract_form("(defmethod ensure-directories-exist-using-host ((host fat-host)")

output.write_text(
    r'''(defpackage :mezzano.file-system.fat32
  (:use :cl))

(in-package :mezzano.file-system.fat32)

(defconstant +attribute-directory+ 4)

(define-condition simple-file-error (file-error simple-condition) ())

(defstruct test-entry name child directory-p)

(defclass fat-host ()
  ((root :initarg :root :reader test-host-root)))

(defgeneric ensure-directories-exist-using-host (host pathname &key verbose))

(defun fat-structure (host)
  (declare (ignore host))
  :ffs)

(defun fat (host)
  (declare (ignore host))
  :fat)

(defun file-host-mount-device (host)
  (test-host-root host))

(defun read-root-directory (disk ffs fat)
  (declare (ignore ffs fat))
  disk)

(defmacro with-fat-host-locked ((host) &body body)
  `(progn ,host ,@body))

(defmacro do-files ((offset) directory finally &body body)
  `(loop :for ,offset :from 0 :below (length ,directory)
         :do (progn ,@body)
         :finally (return ,finally)))

(defun read-file-name (directory offset)
  (test-entry-name (aref directory offset)))

(defun read-first-cluster (directory offset)
  (test-entry-child (aref directory offset)))

(defun directory-p (directory offset)
  (test-entry-directory-p (aref directory offset)))

(defun read-file (ffs disk cluster fat)
  (declare (ignore ffs disk fat))
  cluster)

(defun create-file (host directory directory-cluster name type previous-p attributes)
  (declare (ignore host directory-cluster type previous-p attributes))
  (let ((child (make-array 0 :adjustable t :fill-pointer 0)))
    (vector-push-extend (make-test-entry :name name
                                         :child child
                                         :directory-p t)
                        directory)
    child))

'''
    + method
    + r'''

(defun assert-true (condition control &rest arguments)
  (unless condition
    (apply #'error control arguments)))

(defun occurrence-count (needle haystack)
  (loop :with count := 0
        :with start := 0
        :for position := (search needle haystack :start2 start)
        :while position
        :do (incf count)
            (setf start (+ position (length needle)))
        :finally (return count)))

(let* ((existing-child (make-array 0 :adjustable t :fill-pointer 0))
       (root (make-array 1 :adjustable t :fill-pointer 1
                          :initial-contents
                          (list (make-test-entry :name "Existing"
                                                 :child existing-child
                                                 :directory-p t))))
       (host (make-instance 'fat-host :root root))
       (pathname (make-pathname :directory
                                '(:absolute "eXiStInG" "NewOne" "NewTwo")
                                :name "payload" :type "bin"))
       (created nil)
       (output
         (with-output-to-string (stream)
           (let ((*standard-output* stream))
             (setf created
                   (ensure-directories-exist-using-host host pathname
                                                        :verbose t))))))
  (assert-true created "Creating directories returned NIL")
  (assert-true (= (occurrence-count "Created directory" output) 2)
               "Verbose output did not report exactly the two created directories: ~S"
               output)
  (assert-true (and (search "NewOne" output :test #'char-equal)
                    (search "NewTwo" output :test #'char-equal))
               "Verbose output did not identify only newly created paths: ~S"
               output)
  (let* ((second-created t)
        (second-output
          (with-output-to-string (stream)
            (let ((*standard-output* stream))
              (setf second-created
                    (ensure-directories-exist-using-host host pathname
                                                         :verbose t))))))
    (assert-true (not second-created)
                 "Second ensure-directories call reported creation")
    (assert-true (string= second-output "")
                 "Existing directories produced verbose output: ~S" second-output)))

(let* ((file-data (make-array 0 :adjustable t :fill-pointer 0))
       (root (make-array 1 :adjustable t :fill-pointer 1
                          :initial-contents
                          (list (make-test-entry :name "Collision"
                                                 :child file-data
                                                 :directory-p nil))))
       (host (make-instance 'fat-host :root root))
       (pathname (make-pathname :directory
                                '(:absolute "cOlLiSiOn" "Child")))
       (signalled nil)
       (output
         (with-output-to-string (stream)
           (let ((*standard-output* stream))
             (handler-case
                 (ensure-directories-exist-using-host host pathname
                                                       :verbose t)
               (simple-file-error ()
                 (setf signalled t)))))))
  (assert-true signalled
               "A same-name ordinary file was traversed as a directory")
  (assert-true (= (length root) 1)
               "A directory was created despite the ordinary-file collision")
  (assert-true (string= output "")
               "An ordinary-file collision produced verbose output: ~S" output))

(let* ((other-child (make-array 0 :adjustable t :fill-pointer 0))
       (root (make-array 1 :adjustable t :fill-pointer 1
                          :initial-contents
                          (list (make-test-entry :name "Other"
                                                 :child other-child
                                                 :directory-p t))))
       (host (make-instance 'fat-host :root root))
       (pathname (make-pathname :directory '(:absolute "*")))
       (output
         (with-output-to-string (stream)
           (let ((*standard-output* stream))
             (assert-true
              (ensure-directories-exist-using-host host pathname :verbose t)
              "Literal asterisk directory was not created")))))
  (assert-true (= (length root) 2)
               "Literal asterisk matched an unrelated existing directory")
  (assert-true (string= (test-entry-name (aref root 1)) "*")
               "Ensure-directories did not create the literal asterisk name")
  (assert-true (= (occurrence-count "Created directory" output) 1)
               "Literal asterisk creation report was incorrect: ~S" output))

(let* ((root (make-array 0 :adjustable t :fill-pointer 0))
       (host (make-instance 'fat-host :root root))
       (pathname (make-pathname :directory '(:absolute "Silent")))
       (output
         (with-output-to-string (stream)
           (let ((*standard-output* stream))
             (ensure-directories-exist-using-host host pathname
                                                   :verbose nil)))))
  (assert-true (string= output "")
               "VERBOSE NIL produced output: ~S" output))

(format t "FAT32 ensure-directories verbose contract passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
