#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
blit_source=${BLIT_SOURCE:-"$repo_root/gui/blit.lisp"}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-gui-bitblt-blend-alignment.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$repo_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

def require(path, pattern, description):
    text = (root / path).read_text(encoding="utf-8")
    if not re.search(pattern, text, re.DOTALL):
        raise SystemExit(f"missing alignment precondition: {description} ({path})")

# Runtime and cold-image allocation both round every header-plus-payload object
# to an even word count. GC transport performs the same rounding, preserving
# the 16-byte object-base invariant after movement.
require("runtime/allocate.lisp",
        r"\(let \(\(words \(1\+ size\)\)\).*?\(when \(oddp words\)\s*\(incf words\)\)",
        "runtime objects occupy an even number of words")
require("tools/cold-generator2/serialize.lisp",
        r"\(when \(oddp n-words\) \(incf n-words\)\)",
        "cold-image objects occupy an even number of words")
require("tools/cold-generator2/write.lisp",
        r"\(assert \(zerop \(rem start sys\.int::\+allocation-minimum-alignment\+\)\)\)",
        "cold-image area starts meet allocation alignment")
require("system/gc.lisp",
        r"allocate-for-transport object address\s*\(if \(oddp length\)\s*\(1\+ length\)",
        "transported objects occupy an even number of words")

# Array creation supplies the element storage as the object's payload. Backend
# object addressing places slot zero eight bytes after the object base, and
# UB32 SIMD indexing scales the element index by four bytes.
require("system/runtime-array.lisp",
        r"%allocate-object \(specialized-array-definition-tag info\) length\s*"
        r"\(truncate total-size 64\) area",
        "simple-array element storage is object payload")
require("compiler/backend/arm64/codegen.lisp",
        r"\(\+ \(- sys\.int::\+tag-object\+\) 8 \(\* slot \(or scale 8\)\)\)",
        "object slot zero is eight bytes after its base")
require("tools/cold-generator2/serialize.lisp",
        r"\(\+ \(- object sys\.int::\+tag-object\+\)\s*8\s*\(\* slot 8\)\)",
        "cold-image object slot zero is eight bytes after its base")
require("runtime/simd-x86-64.lisp",
        r"u32\.4-aref.*?%fast-fixnum-\* ,index '4",
        "UB32 SIMD indices use a four-byte scale")

# The x86-64 primitive deliberately uses MOVDQU, so alignment is an effective
# address optimization rather than an instruction correctness requirement.
require("compiler/backend/x86-64/simd.lisp",
        r"%%object-ref-sse-vector/128-unscaled.*?:opcode 'lap:movdqu",
        "x86-64 SIMD loads are explicitly unaligned-safe")
require("compiler/backend/x86-64/simd.lisp",
        r"\(setf simd::%%object-ref-sse-vector/128-unscaled\).*?:opcode 'lap:movdqu",
        "x86-64 SIMD stores are explicitly unaligned-safe")

print("GUI BITBLT alignment layout preconditions passed")
PY

cat >"$test_file" <<'LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:export #:%simple-1d-array-p #:%complex-array-storage))

(in-package :mezzano.internals)

(defun %simple-1d-array-p (array)
  (typep array '(simple-array * (*))))

(defun %complex-array-storage (array)
  (declare (ignore array))
  (error "The host fixture only uses simple vector storage"))

(defpackage :mezzano.gui
  (:use :cl)
  (:export #:colour))

(in-package :mezzano.gui)

(deftype colour () '(unsigned-byte 32))
(deftype matrix4 () '(simple-array single-float (4 4)))
(deftype colour-matrix () 't)

(handler-bind ((warning (lambda (condition)
                          (declare (ignore condition))
                          (muffle-warning))))
  (load (or (sb-ext:posix-getenv "BLIT_SOURCE")
            (error "BLIT_SOURCE is not set"))))

(defvar *scalar-calls*)
(defvar *quad-calls*)
(defvar *interleaved-calls*)

(defun fixture-blend-pixel (source destination)
  (ldb (byte 32 0) (+ source destination #x01020304)))

(defun %%alpha-blend-one-argb8888-argb8888 (source to to-offset)
  (push to-offset *scalar-calls*)
  (setf (aref to to-offset)
        (fixture-blend-pixel source (aref to to-offset))))

(defun fixture-blend-run (width source source-offset to to-offset)
  (dotimes (index width)
    (setf (aref to (+ to-offset index))
          (fixture-blend-pixel (aref source (+ source-offset index))
                               (aref to (+ to-offset index))))))

(defun alpha-blend-quad (source source-offset to to-offset)
  (unless (= (mod to-offset 4) 2)
    (error "Quad path selected at unaligned destination offset ~D" to-offset))
  (push (list source-offset to-offset) *quad-calls*)
  (fixture-blend-run 4 source source-offset to to-offset))

(defun alpha-blend-interleaved (source source-offset to to-offset)
  (unless (= (mod to-offset 4) 2)
    (error "16-pixel path selected at unaligned destination offset ~D" to-offset))
  (push (list source-offset to-offset) *interleaved-calls*)
  (fixture-blend-run 16 source source-offset to to-offset))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A failed: expected ~S, got ~S" description expected actual)))

(defun assert-array= (expected actual description)
  (unless (equalp expected actual)
    (error "~A failed:~%  expected ~S~%  actual   ~S"
           description expected actual)))

(defun check-case (description from-offset to-offset ncols
                   &key
                     (expected-scalars nil expected-scalars-p)
                     (expected-quads nil expected-quads-p)
                     (expected-interleaved nil expected-interleaved-p))
  (let ((source (make-array 64 :element-type '(unsigned-byte 32)))
        (actual (make-array 64 :element-type '(unsigned-byte 32)))
        (expected (make-array 64 :element-type '(unsigned-byte 32))))
    (dotimes (index 64)
      (setf (aref source index) (+ #x10203040 (* index #x00010101))
            (aref actual index) (+ #x40506070 (* index #x00000103))
            (aref expected index) (aref actual index)))
    (dotimes (index ncols)
      (setf (aref expected (+ to-offset index))
            (fixture-blend-pixel (aref source (+ from-offset index))
                                 (aref expected (+ to-offset index)))))
    (let ((*scalar-calls* '())
          (*quad-calls* '())
          (*interleaved-calls* '()))
      (%bitblt-blend-line actual to-offset ncols source from-offset)
      (assert-array= expected actual description)
      (when expected-scalars-p
        (assert-equal expected-scalars (nreverse *scalar-calls*)
                      (format nil "~A scalar calls" description)))
      (when expected-quads-p
        (assert-equal expected-quads (nreverse *quad-calls*)
                      (format nil "~A quad calls" description)))
      (when expected-interleaved-p
        (assert-equal expected-interleaved (nreverse *interleaved-calls*)
                      (format nil "~A interleaved calls" description))))))

;; The UB32 payload begins one word after a 16-byte-aligned object header, so
;; element offsets congruent to 2 modulo 4 are the aligned SIMD boundary.
(check-case "already aligned bulk" 6 2 36
            :expected-scalars '()
            :expected-quads '((38 34))
            :expected-interleaved '((6 2) (22 18)))
(check-case "unaligned prefix reaches bulk" 5 0 22
            :expected-scalars '(0 1)
            :expected-quads '((23 18))
            :expected-interleaved '((7 2)))
(check-case "source and destination alignment differ" 1 0 22
            :expected-scalars '(0 1)
            :expected-quads '((19 18))
            :expected-interleaved '((3 2)))
(check-case "short line cannot reach alignment" 3 0 1
            :expected-scalars '(0)
            :expected-quads '()
            :expected-interleaved '())
(check-case "prefix and exact quad" 9 1 5
            :expected-scalars '(1)
            :expected-quads '((10 2))
            :expected-interleaved '())
(check-case "zero length" 0 3 0
            :expected-scalars '()
            :expected-quads '()
            :expected-interleaved '())

;; Exercise every starting alignment and lengths around the scalar, quad, and
;; 16-pixel boundaries. Every case is compared with a scalar reference above.
(dolist (to-offset '(0 1 2 3 4 5))
  (dolist (from-offset '(0 1 2 3 4 5))
    (dolist (ncols '(0 1 2 3 4 5 15 16 17 19 20 21 31 32 33 39 40))
      (check-case (format nil "offsets ~D/~D length ~D"
                          from-offset to-offset ncols)
                  from-offset to-offset ncols))))

(format t "GUI BITBLT blend alignment contract passed~%")
LISP

BLIT_SOURCE="$blit_source" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
