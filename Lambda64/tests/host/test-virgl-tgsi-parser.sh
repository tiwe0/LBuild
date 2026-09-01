#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_file="${TGSI_SOURCE:-$repo_root/Lambda64/gui/virgl/tgsi.lisp}"

if ! command -v sbcl >/dev/null 2>&1; then
  echo "error: sbcl is required for the TGSI parser host test" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lambda64-tgsi-parser.XXXXXX")"
tmp_lisp="$tmp_dir/test.lisp"
cleanup() {
  python3 - "$tmp_dir" <<'PY'
from pathlib import Path
import shutil
import sys

shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

cat >"$tmp_lisp" <<'LISP'
(defpackage :mezzano.gui.virgl.tgsi
  (:use :cl)
  (:export #:assemble #:dcl #:imm #:end #:mov))

(load (or (uiop:getenv "TGSI_SOURCE")
          (error "TGSI_SOURCE is not set")))

(in-package :cl-user)

(defun assemble (processor source)
  (mezzano.gui.virgl.tgsi:assemble processor source))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A~%Expected: ~S~%Actual:   ~S" description expected actual)))

(defun assert-signals (condition thunk description)
  (handler-case
      (progn
        (funcall thunk)
        (error "~A: expected ~S" description condition))
    (condition (caught)
      (unless (typep caught condition)
        (error "~A: expected ~S, got ~S (~A)"
               description condition (type-of caught) caught)))))

;;; Existing declaration syntax remains byte-for-byte compatible.
(multiple-value-bind (text tokens)
    (assemble :fragment
              '((mezzano.gui.virgl.tgsi:dcl (:in 0) :color :color)
                (mezzano.gui.virgl.tgsi:dcl (:out 0) :color)
                (mezzano.gui.virgl.tgsi:end)))
  (assert-equal "FRAG
DCL IN[0], COLOR, COLOR
DCL OUT[0], COLOR
END
" text "legacy declaration output")
  (assert-equal 10 tokens "legacy declaration token count"))

;;; Dimension, array, indexed semantic, interpolation location and invariant
;;; each have a defined representation and token contribution.
(multiple-value-bind (text tokens)
    (assemble :fragment
              '((mezzano.gui.virgl.tgsi:dcl
                 (:in 0 3)
                 (:dimension 2)
                 (:array 7)
                 (:generic 4)
                 :perspective
                 :centroid
                 :invariant)
                (mezzano.gui.virgl.tgsi:end)))
  (assert-equal "FRAG
DCL IN[2][0..3], ARRAY(7), GENERIC[4], PERSPECTIVE, CENTROID, INVARIANT
END
" text "structured declaration output")
  (assert-equal 9 tokens "structured declaration token count"))

;;; Vertex inputs cannot carry semantic/interpolation qualifiers in Mesa's
;;; TGSI text grammar, but an ARRAY qualifier remains valid.
(multiple-value-bind (text tokens)
    (assemble :vertex
              '((mezzano.gui.virgl.tgsi:dcl (:in 0 1) (:array 3))
                (mezzano.gui.virgl.tgsi:end)))
  (assert-equal "VERT
DCL IN[0..1], ARRAY(3)
END
" text "vertex input array declaration")
  (assert-equal 6 tokens "vertex input array token count"))

(assert-signals 'error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:dcl (:in 3 2)))))
                "reversed declaration range")
(assert-signals 'error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:dcl (:in 0) :bogus))))
                "unknown declaration qualifier")
(assert-signals 'error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:dcl
                               (:in 0) :color :position))))
                "duplicate semantic")
(assert-signals 'error
                (lambda ()
                  (assemble :vertex
                            '((mezzano.gui.virgl.tgsi:dcl
                               (:in 0) :color))))
                "vertex-input semantic")
(assert-signals 'type-error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:dcl
                               (:in 0) (:array 4294967296)))))
                "array identifier width")
(assert-signals 'type-error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:dcl
                               (:in 0) (:array -1)))))
                "negative array identifier")

;;; Unnumbered immediates keep their legacy syntax. Explicit numbers must equal
;;; the next implicit immediate index, exactly as Mesa's parser requires.
(multiple-value-bind (text tokens)
    (assemble :fragment
              '((mezzano.gui.virgl.tgsi:imm 0 :flt32
                 (0.0 0.0 0.0 0.0))
                (mezzano.gui.virgl.tgsi:end)))
  (assert-equal "FRAG
IMM[0] FLT32 {0.0, 0.0, 0.0, 0.0}
END
" text "explicit immediate zero")
  (assert-equal 8 tokens "explicit immediate zero token count"))

(multiple-value-bind (text tokens)
    (assemble :fragment
              '((mezzano.gui.virgl.tgsi:imm :flt32
                 (1.0 2.0 3.0 4.0))
                (mezzano.gui.virgl.tgsi:imm 1 :uint32
                 (0 1 2147483648 4294967295))
                (mezzano.gui.virgl.tgsi:imm 2 :int32
                 (-2147483648 -1 0 2147483647))
                (mezzano.gui.virgl.tgsi:imm 3 :flt64
                 (1.5d0 -2.25d10))
                (mezzano.gui.virgl.tgsi:end)))
  (assert-equal "FRAG
IMM FLT32 {1.0, 2.0, 3.0, 4.0}
IMM[1] UINT32 {0, 1, 2147483648, 4294967295}
IMM[2] INT32 {-2147483648, -1, 0, 2147483647}
IMM[3] FLT64 {1.5e0, -2.25e10}
END
" text "immediate output matrix")
  (assert-equal 23 tokens "immediate token count"))

(assert-signals 'error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:imm 1 :flt32
                               (0.0 0.0 0.0 0.0)))))
                "numbered immediate gap")
(assert-signals 'type-error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:imm :uint32
                               (0 1 2 -1)))))
                "negative uint32")
(assert-signals 'type-error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:imm :int32
                               (0 1 2 2147483648)))))
                "int32 overflow")
(assert-signals 'error
                (lambda ()
                  (assemble :fragment
                            '((mezzano.gui.virgl.tgsi:imm :flt64
                               (1.0d0 2.0d0 3.0d0 4.0d0)))))
                "flt64 arity")

(format t "TGSI declaration/immediate contract passed~%")
LISP

TGSI_SOURCE="$source_file" sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --load "$tmp_lisp"
