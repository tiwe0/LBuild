#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-file-http-remote.XXXXXX")
trap 'python3 - "$test_dir" <<'PY'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY' EXIT

python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import os
import re
import sys

repo = Path(sys.argv[1])
out = Path(sys.argv[2])

def form_containing(path, needle):
    text = path.read_text()
    hit = text.index(needle)
    start = hit if text[hit] == "(" else text.rfind("\n(", 0, hit) + 1
    depth = 0
    in_string = False
    escaped = False
    comment = False
    for index in range(start, len(text)):
        char = text[index]
        if comment:
            if char == "\n":
                comment = False
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
            comment = True
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise RuntimeError(f"unterminated form containing {needle!r} in {path}")

http = Path(os.environ.get("HTTP_SOURCE", repo / "file/http.lisp"))
http_parser = Path(os.environ.get("HTTP_PARSER_SOURCE", http))
http_request = Path(os.environ.get("HTTP_REQUEST_SOURCE", http))
remote = Path(os.environ.get("REMOTE_SOURCE", repo / "file/remote.lisp"))
open_form = form_containing(http, "(defmethod open-using-host ((host http-host)")
if not re.search(r"\(url-encode \(pathname-name pathname\)\)\s+pathname\)", open_form):
    raise RuntimeError("initial HTTP request does not preserve pathname context")
if "(http-request host port path pathname)" not in open_form:
    raise RuntimeError("redirect HTTP request does not preserve pathname context")
(out / "http-forms.lisp").write_text(
    form_containing(http_parser, "(defmethod parse-namestring-using-host ((host http-host)")
    + "\n\n"
    + form_containing(http_request, "(defun http-request (host port path")
    + "\n\n"
    + form_containing(http, "(defun decode-location (location)")
    + "\n\n"
    + open_form
    + "\n"
)
(out / "remote-forms.lisp").write_text(
    form_containing(remote, "(defmethod parse-namestring-using-host ((host remote-file-host)")
    + "\n"
)
PY

cat >"$test_dir/test.lisp" <<'LISP'
(defpackage :mezzano.file-system
  (:use :cl)
  (:shadow #:file-error #:simple-file-error #:file-error-pathname)
  (:export #:file-system-host
           #:file-error
           #:simple-file-error
           #:file-error-pathname
           #:parse-namestring-using-host
           #:open-using-host))

(in-package :mezzano.file-system)

(defclass file-system-host () ())
(define-condition file-error (error)
  ((pathname :initarg :pathname :reader file-error-pathname)))
(define-condition simple-file-error (file-error simple-error) ())
(defgeneric parse-namestring-using-host (host namestring junk-allowed))
(defgeneric open-using-host (host pathname
                             &key direction element-type if-exists
                               if-does-not-exist external-format))

(defpackage :mezzano.internals
  (:use :cl)
  (:export #:explode))

(in-package :mezzano.internals)

(defun explode (delimiter string start end)
  (loop :with result = '()
        :for component-start = start :then (1+ delimiter-position)
        :for delimiter-position = (position delimiter string
                                           :start component-start :end end)
        :do (push (subseq string component-start (or delimiter-position end)) result)
        :until (null delimiter-position)
        :finally (return (nreverse result))))

(defun type-equal (left right)
  (equal left right))

(defpackage :mezzano.network
  (:use :cl)
  (:export #:resolve-address #:buffered-format #:with-open-network-stream))

(in-package :mezzano.network)

(defvar *resolve-errorp* :not-called)
(defvar *resolved-address* nil)
(defvar *opened-address* :not-opened)
(defvar *opened-port* :not-opened)
(defvar *request-text* nil)
(defun resolve-address (host &optional (errorp t))
  (declare (ignore host))
  (setf *resolve-errorp* errorp)
  *resolved-address*)
(defun buffered-format (stream control-string &rest arguments)
  (declare (ignore stream))
  (setf *request-text* (apply #'format nil control-string arguments)))
(defmacro with-open-network-stream ((stream host port) &body body)
  `(let ((,stream :mock-network-stream))
     (setf *opened-address* ,host
           *opened-port* ,port)
     ,@body))

(defpackage :mezzano.file-system.http
  (:use :cl)
  (:import-from :mezzano.file-system
                #:file-system-host
                #:parse-namestring-using-host
                #:open-using-host)
  (:shadowing-import-from :mezzano.file-system #:simple-file-error)
  (:shadow #:make-pathname #:pathname-device #:pathname-name))

(in-package :mezzano.file-system.http)

(defclass http-host (file-system-host) ())
(defun make-pathname (&key host device directory name type version)
  (list :host host :device device :directory directory :name name
        :type type :version version))
(defun pathname-field (pathname field)
  (getf pathname field))
(defun pathname-device (pathname)
  (pathname-field pathname :device))
(defun pathname-name (pathname)
  (pathname-field pathname :name))
(defvar *permit-redirects* t)
(defun url-encode (string)
  string)
(defun header-name (header)
  (car header))
(defun header-value (header)
  (cdr header))
(defun make-http-stream (pathname body element-type external-format)
  (list :pathname pathname :body body :element-type element-type
        :external-format external-format))
(defun read-http-response (stream)
  (declare (ignore stream))
  (values "HTTP/1.1" 200 "OK" '() #()))

(load (merge-pathnames "http-forms.lisp" *load-truename*))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let* ((host (make-instance 'http-host))
       (text "//example.com:8080/a b?x=1"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host host text t)
    (assert-true (= position (length text)) "HTTP full parse stopped at ~S" position)
    (assert-true (string= (car (pathname-field pathname :device)) "example.com")
                 "HTTP domain parsed incorrectly")
    (assert-true (= (cdr (pathname-field pathname :device)) 8080)
                 "HTTP port parsed incorrectly")
    (assert-true (string= (pathname-field pathname :name) "/a b?x=1")
                 "HTTP path parsed incorrectly")))

(multiple-value-bind (pathname position)
    (parse-namestring-using-host (make-instance 'http-host)
                                 "example.com trailing" t)
  (assert-true (= position (length "example.com"))
               "HTTP junk position is ~S" position)
  (assert-true (string= (pathname-field pathname :name) "/")
               "HTTP junk prefix did not produce the root path"))

(multiple-value-bind (pathname position)
    (parse-namestring-using-host (make-instance 'http-host)
                                 "example.com:bad" t)
  (assert-true (= position (length "example.com"))
               "Invalid HTTP port did not leave the colon as junk: ~S" position)
  (assert-true (= (cdr (pathname-field pathname :device)) 80)
               "Invalid HTTP port changed the default port"))

(multiple-value-bind (pathname position)
    (parse-namestring-using-host (make-instance 'http-host)
                                 "example.com:8080 trailing" t)
  (assert-true (= position (length "example.com:8080"))
               "HTTP explicit-port junk position is ~S" position)
  (assert-true (= (cdr (pathname-field pathname :device)) 8080)
               "HTTP explicit port was not retained before junk")
  (assert-true (string= (pathname-field pathname :name) "/")
               "HTTP explicit-port junk prefix did not produce the root path"))

(assert-true
 (handler-case
     (progn
       (parse-namestring-using-host (make-instance 'http-host)
                                    "example.com trailing" nil)
       nil)
   (error () t))
 "HTTP syntax junk was accepted without :JUNK-ALLOWED")

(assert-true
 (handler-case
     (progn
       (parse-namestring-using-host (make-instance 'http-host)
                                    "example.com:8080 trailing" nil)
       nil)
   (error () t))
 "HTTP explicit-port syntax junk was accepted without :JUNK-ALLOWED")

(assert-true
 (handler-case
     (progn
       (parse-namestring-using-host (make-instance 'http-host) ":80" t)
       nil)
   (error () t))
 "HTTP parser accepted a missing domain")

(handler-case
    (progn
      (http-request "does-not-exist.invalid" 80 "/")
      (error "Unknown HTTP host did not signal"))
  (simple-file-error (condition)
    (assert-true (null (mezzano.file-system:file-error-pathname condition))
                 "Direct HTTP request acquired an unexpected pathname")))

(let ((pathname '(:original-http-pathname)))
  (handler-case
      (progn
        (http-request "does-not-exist.invalid" 80 "/" pathname)
        (error "Unknown HTTP host did not signal"))
    (simple-file-error (condition)
      (assert-true (eq (mezzano.file-system:file-error-pathname condition) pathname)
                   "Unknown-host file error lost its pathname")
      (assert-true (search "does-not-exist.invalid" (princ-to-string condition)
                           :test #'char-equal)
                   "Unknown-host error did not identify the domain: ~A" condition)))
  (assert-true (null mezzano.network::*resolve-errorp*)
               "HTTP resolution did not use the non-signalling resolver contract")
  (assert-true (eq mezzano.network::*opened-address* :not-opened)
               "HTTP request opened a connection after failed resolution"))

(setf mezzano.network::*resolved-address* '(192 0 2 1)
      mezzano.network::*request-text* nil)
(multiple-value-bind (version status reason headers body)
    (http-request "example.test" 8080 "/resource")
  (declare (ignore headers body))
  (assert-true (and (string= version "HTTP/1.1")
                    (= status 200)
                    (string= reason "OK"))
               "Resolved HTTP request lost its response values")
  (assert-true (equal mezzano.network::*opened-address* '(192 0 2 1))
               "HTTP request did not connect to the resolved address")
  (assert-true (= mezzano.network::*opened-port* 8080)
               "HTTP request did not preserve the requested port")
  (assert-true (search "Host: example.test" mezzano.network::*request-text*
                       :test #'char-equal)
               "HTTP request did not preserve the domain in the Host header: ~S"
               mezzano.network::*request-text*))

(let* ((host (make-instance 'http-host))
       (pathname (make-pathname :host host
                                :device (cons "origin.test" 80)
                                :directory '(:absolute)
                                :name "/start"))
       (calls '()))
  (setf (symbol-function 'http-request)
        (lambda (domain port path &optional request-pathname)
          (push (list domain port path request-pathname) calls)
          (if (string= domain "origin.test")
              (values "HTTP/1.1" 302 "Found"
                      '(("Location" . "http://redirect.test/final")) nil)
              (values "HTTP/1.1" 200 "OK" '() #(1 2 3)))))
  (let ((stream (open-using-host host pathname
                                 :direction :input
                                 :element-type '(unsigned-byte 8)
                                 :if-exists nil
                                 :if-does-not-exist :error
                                 :external-format :default)))
    (setf calls (nreverse calls))
    (assert-true (= (length calls) 2)
                 "HTTP redirect issued ~D requests instead of two" (length calls))
    (assert-true (every (lambda (call) (eq (fourth call) pathname)) calls)
                 "HTTP redirect did not preserve pathname context: ~S" calls)
    (assert-true (equal (subseq (second calls) 0 3)
                        '("redirect.test" 80 "/final"))
                 "HTTP redirect target was decoded incorrectly: ~S" (second calls))
    (assert-true (eq (getf stream :pathname) pathname)
                 "HTTP redirect result lost the original pathname")))

(defpackage :mezzano.file-system.remote
  (:use :cl)
  (:import-from :mezzano.file-system
                #:file-system-host
                #:parse-namestring-using-host)
  (:shadow #:make-pathname))

(in-package :mezzano.file-system.remote)

(defclass remote-file-host (file-system-host) ())
(defun make-pathname (&key host device directory name type version)
  (list :host host :device device :directory directory :name name
        :type type :version version))
(defun pathname-field (pathname field)
  (getf pathname field))

(load (merge-pathnames "remote-forms.lisp" *load-truename*))

(defun assert-true (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let* ((host (make-instance 'remote-file-host))
       (text "/src/foo.lisp~"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host host text t)
    (assert-true (= position (length text)) "Remote parse stopped at ~S" position)
    (assert-true (equal (pathname-field pathname :directory) '(:absolute "src"))
                 "Remote directory parsed incorrectly: ~S"
                 (pathname-field pathname :directory))
    (assert-true (string= (pathname-field pathname :name) "foo")
                 "Remote name parsed incorrectly")
    (assert-true (string= (pathname-field pathname :type) "lisp")
                 "Remote type parsed incorrectly")
    (assert-true (eq (pathname-field pathname :version) :previous)
                 "Remote backup version parsed incorrectly")))

(let ((text "relative name.txt"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host (make-instance 'remote-file-host) text t)
    (assert-true (= position (length text)) "Remote pathname did not consume legal spaces")
    (assert-true (string= (pathname-field pathname :name) "relative name")
                 "Remote pathname treated a legal space as junk")))

(multiple-value-bind (pathname position)
    (parse-namestring-using-host (make-instance 'remote-file-host) "" t)
  (assert-true pathname "Empty remote namestring returned no pathname")
  (assert-true (zerop position) "Empty remote namestring returned position ~S" position))

(let ((text "/src/"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host (make-instance 'remote-file-host) text t)
    (assert-true (= position (length text)) "Trailing-directory parse stopped at ~S" position)
    (assert-true (equal (pathname-field pathname :directory) '(:absolute "src"))
                 "Trailing-directory components are wrong: ~S"
                 (pathname-field pathname :directory))
    (assert-true (null (pathname-field pathname :name))
                 "Trailing directory acquired a name")
    (assert-true (null (pathname-field pathname :type))
                 "Trailing directory acquired a type")
    (assert-true (null (pathname-field pathname :version))
                 "Trailing directory acquired a version")))

(let ((text "/**/*.lisp"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host (make-instance 'remote-file-host) text t)
    (assert-true (= position (length text)) "Wild-inferiors parse stopped at ~S" position)
    (assert-true (equal (pathname-field pathname :directory)
                        '(:absolute :wild-inferiors))
                 "Wild-inferiors directory is wrong: ~S"
                 (pathname-field pathname :directory))
    (assert-true (eq (pathname-field pathname :name) :wild)
                 "Wild-inferiors pathname name is not wild")
    (assert-true (string= (pathname-field pathname :type) "lisp")
                 "Wild-inferiors pathname type is wrong")))

(let ((text "/src/*.*"))
  (multiple-value-bind (pathname position)
      (parse-namestring-using-host (make-instance 'remote-file-host) text t)
    (assert-true (= position (length text)) "Name/type wildcard parse stopped at ~S" position)
    (assert-true (equal (pathname-field pathname :directory) '(:absolute "src"))
                 "Name/type wildcard directory is wrong")
    (assert-true (eq (pathname-field pathname :name) :wild)
                 "Remote pathname name is not wild")
    (assert-true (eq (pathname-field pathname :type) :wild)
                 "Remote pathname type is not wild")))

(format t "file HTTP/remote pathname and resolution contracts passed~%")
LISP

FILE_HTTP_REMOTE_TEST_DIR="$test_dir" "$sbcl" --noinform --disable-debugger \
  --script "$test_dir/test.lisp"
