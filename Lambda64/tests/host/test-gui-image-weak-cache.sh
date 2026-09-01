#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
image_source=${IMAGE_SOURCE:-"$repo_root/gui/image.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-gui-image-weak-cache.XXXXXX.lisp")
trap 'python3 - "$test_file" <<'"'"'PY'"'"'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY' EXIT

python3 - "$image_source" "$test_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output_path = Path(sys.argv[2])


def extract_form(marker, description):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing {description}: {marker}")

    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    for index in range(start, len(source)):
        character = source[index]
        if in_comment:
            if character == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == ";" and source[max(0, index - 2):index] != "#\\":
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"Unterminated {description}: {marker}")


cache = extract_form("(defvar *image-cache*", "image cache definition")
flush = extract_form("(defun flush-image-cache", "cache flush function")
load = extract_form("(defun load-image", "image load function")

output_path.write_text(
    r'''(defpackage :mezzano.gui.image
  (:use :cl))

(in-package :mezzano.gui.image)

(defvar *decode-count* 0)

(defun load-jpeg (path)
  (declare (ignore path))
  (incf *decode-count*)
  ;; Use a non-immediate object large enough that collection is observable.
  (make-array 4096 :element-type '(unsigned-byte 8)
                   :initial-element (logand *decode-count* #xff)))

(defun load-png (path)
  (declare (ignore path))
  nil)

'''
    + cache
    + "\n"
    + flush
    + "\n"
    + load
    + r'''

(defun assert-true (condition format-control &rest arguments)
  (unless condition
    (apply #'error format-control arguments)))

(assert-true (eql (sb-ext:hash-table-weakness *image-cache*) :value)
             "Image cache must use value weakness, got ~S"
             (sb-ext:hash-table-weakness *image-cache*))

(flush-image-cache)
(setf *decode-count* 0)

;; A live caller reference must keep the weak cache entry usable.
(let* ((path (truename #P"/tmp/"))
       (first (load-image path))
       (second (load-image path)))
  (assert-true (eq first second)
               "A live cached image was decoded twice")
  (assert-true (= *decode-count* 1)
               "Expected one decode for a live cache hit, got ~D"
               *decode-count*))

(declaim (notinline populate-cache-for-collection))
(defun populate-cache-for-collection (path)
  (load-image path)
  (values))

;; Once no caller retains the image, a full collection may reclaim it and the
;; :VALUE weak table must stop retaining both the image and its pathname key.
(flush-image-cache)
(setf *decode-count* 0)
(defvar *test-path* (truename #P"/tmp/"))
(populate-cache-for-collection *test-path*)
;; Collection occurs in a later top-level dynamic extent so the host evaluator
;; cannot retain LOAD-IMAGE's return value in the caller frame that invokes GC.
(loop repeat 5 do (sb-ext:gc :full t))
(assert-true (zerop (hash-table-count *image-cache*))
             "Image cache retained an otherwise unreachable decoded image")
;; Weak hash-table cleanup is GC-driven. Triggering a lookup also exercises the
;; real LOAD-IMAGE miss path after collection.
(let ((replacement (load-image *test-path*)))
  (assert-true replacement "Reload after weak eviction returned NIL")
  (assert-true (= *decode-count* 2)
               "Weakly collected image was not decoded again; count ~D"
               *decode-count*))

(flush-image-cache)
(assert-true (zerop (hash-table-count *image-cache*))
             "FLUSH-IMAGE-CACHE did not clear the cache")

(format t "GUI image weak-cache contract passed.~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
