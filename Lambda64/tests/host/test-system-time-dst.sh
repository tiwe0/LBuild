#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${TIME_SOURCE:-"$repo_root/system/time.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-time-dst.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

# Run the production definitions on the host with the kernel global primitive
# represented by a parameter.  This exercises the resolver contract without
# requiring a cold image or RTC hardware.
# Keep the decode implementation and its dependencies; the remainder depends
# on supervisor-only packages that are intentionally absent from this host
# harness.
sed '/^(defun get-decoded-time/,$d; s/(defglobal /(defparameter /g' "$source_file" >"$tmp_dir/time.lisp"
cat >"$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:shadow #:decode-universal-time #:get-decoded-time #:get-universal-time
           #:time #:format-time #:*time-zone* #:*daylight-saving-time-function*
           #:%time))
(in-package :mezzano.internals)
(defparameter *time-zone* 0)
(load (or (sb-ext:posix-getenv "TIME_SOURCE") (error "TIME_SOURCE is not set")))
(defun check (condition control &rest args)
  (unless condition (apply #'error control args)))

(setf *time-zone* 5 *daylight-saving-time-function* nil)
(multiple-value-bind (second minute hour date month year day daylight zone)
    (decode-universal-time 0)
  (declare (ignore second minute hour date month year day))
  (check (not daylight) "fixed-offset fallback unexpectedly reported DST")
  (check (= zone 5) "fixed-offset fallback changed configured zone"))

(setf *time-zone* 5
      *daylight-saving-time-function*
      (lambda (universal-time zone)
        (check (= universal-time 0) "resolver saw wrong universal time")
        (check (= zone 5) "resolver saw wrong configured zone")
        (values t (* 4 60 60))))
(multiple-value-bind (second minute hour date month year day daylight zone)
    (decode-universal-time 0)
  (declare (ignore second minute date month year day))
  (check daylight "resolver daylight result was not propagated")
  (check (= hour 20) "resolver UTC offset was not used to decode local time")
  (check (= zone 5) "daylight timezone was not reported as hours west"))

;; An explicit TIME-ZONE is deliberately fixed-offset and must not invoke DST.
(let ((called nil))
  (setf *daylight-saving-time-function* (lambda (&rest args) (declare (ignore args)) (setf called t) (values t 0)))
  (multiple-value-bind (second minute hour date month year day daylight zone)
      (decode-universal-time 0 2)
    (declare (ignore second minute hour date month year day))
    (check (not called) "explicit time-zone unexpectedly invoked resolver")
    (check (not daylight) "explicit time-zone unexpectedly reported DST")
    (check (= zone 2) "explicit time-zone offset changed")))
(format t "time DST resolver contract passed~%")
EOF_LISP
TIME_SOURCE="$tmp_dir/time.lisp" sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"
