#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${FAT32_SOURCE:-"$repo_root/file/fat32.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-file-fat32-wildcards.XXXXXX.lisp")
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


forms = [
    extract_form("(defun force-directory-only"),
    extract_form("(defun wildcard-string-match-p"),
    extract_form("(defun pathname-component-match-p"),
    extract_form("(defun match-in-directory"),
]

output.write_text(
    r'''(defpackage :mezzano.file-system.fat32
  (:use :cl))

(in-package :mezzano.file-system.fat32)

(defstruct test-entry
  name
  type
  directory-p
  child)

(defmacro do-files ((offset) directory finally &body body)
  `(loop :for ,offset :from 0 :below (length ,directory)
         :do (progn ,@body)
         :finally (return ,finally)))

(defun read-name-and-type (directory offset)
  (let ((entry (aref directory offset)))
    (values (test-entry-name entry) (test-entry-type entry))))

(defun read-file-name (directory offset)
  (test-entry-name (aref directory offset)))

(defun directory-p (directory offset)
  (test-entry-directory-p (aref directory offset)))

(defun read-first-cluster (directory offset)
  (test-entry-child (aref directory offset)))

(defun read-file (ffs disk cluster fat)
  (declare (ignore ffs disk fat))
  cluster)

'''
    + "\n\n".join(forms)
    + r'''

(defun entry (name &optional type child)
  (make-test-entry :name name
                   :type type
                   :directory-p (not (null child))
                   :child child))

(defun test-directory (&rest entries)
  (coerce entries 'vector))

(defun assert-true (condition control &rest arguments)
  (unless condition
    (apply #'error control arguments)))

(defun result-key (pathname)
  (list (car (last (pathname-directory pathname)))
        (pathname-name pathname)
        (pathname-type pathname)))

(defun sorted-result-keys (result)
  (sort (mapcar #'result-key result) #'string-lessp
        :key (lambda (key) (format nil "~{~A/~}" key))))

;; Embedded stars match zero or more characters, matching FAT's
;; case-insensitive component semantics.
(dolist (case '(("*" "" t)
                ("a**b" "AB" t)
                ("a*b*c" "AxByC" t)
                ("*mid*" "PREmiddLE" t)
                ("a*b" "ac" nil)
                ("read*" "README" t)))
  (destructuring-bind (pattern value expected) case
    (assert-true (eql expected (wildcard-string-match-p pattern value))
                 "Wildcard match ~S against ~S was wrong" pattern value)))

(let* ((source-one
         (test-directory (entry "ReadMe" "TXT")
                         (entry "README" "md")
                         (entry "notes" "txt")))
       (source-two
         (test-directory (entry "ReadLater" "TxT")
                         (entry "report" "txt")))
       (root
         (test-directory (entry "SourceOne" nil source-one)
                         (entry "sourceTwo" nil source-two)
                         (entry "binary" nil (test-directory))))
       (pathname
         (make-pathname :directory '(:absolute "sOurCe*")
                        :name "read*"
                        :type "t*"))
       (result (match-in-directory :disk :ffs :fat root
                                   (cdr (pathname-directory pathname))
                                   pathname)))
  (assert-true
   (equal (sorted-result-keys result)
          '(("SourceOne" "ReadMe" "TXT")
            ("sourceTwo" "ReadLater" "TxT")))
   "Directory/name/type wildcard result was wrong: ~S"
   (sorted-result-keys result))

  ;; A string wildcard in the directory position returns every actual matched
  ;; directory name, not the wildcard-bearing input pathname.
  (let* ((directory-pathname
           (make-pathname :directory '(:absolute "source*")
                          :name nil :type nil))
         (directories
           (match-in-directory :disk :ffs :fat root
                               (cdr (pathname-directory directory-pathname))
                               directory-pathname)))
    (assert-true
     (equal (sort (mapcar (lambda (path)
                            (car (last (pathname-directory path))))
                          directories)
                  #'string-lessp)
            '("SourceOne" "sourceTwo"))
     "Wildcard directory pathnames did not contain actual names: ~S"
     directories))

  ;; Exact strings retain case-insensitive FAT matching and actual on-disk case.
  (let* ((exact-pathname
           (make-pathname :directory '(:absolute "SOURCEONE")
                          :name "readme" :type "txt"))
         (exact-result
           (match-in-directory :disk :ffs :fat root
                               (cdr (pathname-directory exact-pathname))
                               exact-pathname)))
    (assert-true
     (equal (mapcar #'result-key exact-result)
            '(("SourceOne" "ReadMe" "TXT")))
     "Exact FAT component matching lost case-insensitive behavior: ~S"
     exact-result)))

(format t "FAT32 wildcard directory/name/type contract passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
