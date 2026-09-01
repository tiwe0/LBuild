#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
font_source=${FONT_SOURCE:-"$repo_root/gui/font.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-font-modifier-bits.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$font_source" "$test_file" <<'PY'
from pathlib import Path
import re
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


method = extract_form(
    "(defmethod character-to-glyph ((font font) character)",
    "font character-to-glyph method",
)

# The executable fixture below proves the externally visible cache and fallback
# behavior. This representation-level assertion additionally requires the font
# boundary to make its modifier stripping explicit instead of depending on the
# incidental fact that CHAR-CODE currently discards Mezzano's modifier bits.
normalization = re.compile(
    r"\(character\s+\(if\s+\(zerop\s+"
    r"\(sys\.int::char-bits\s+character\)\)\s+"
    r"character\s+\(code-char\s+code\)\)\)",
    re.DOTALL,
)
normalizes_explicitly = bool(normalization.search(method))

output_path.write_text(
    r'''(defpackage :mezzano.supervisor (:use :cl)
  (:export #:with-mutex))
(defpackage :mezzano.gui (:use :cl)
  (:export #:make-surface-from-array))
(defpackage :sys.int (:use :cl)
  (:export #:char-bits #:map-unifont-2d))
(defpackage :zpb-ttf (:use :cl)
  (:export #:glyph-exists-p #:find-glyph #:code-point #:bounding-box
           #:advance-width #:ymax #:xmin))
(defpackage :mezzano.gui.font (:use :cl)
  (:shadow #:char-code #:code-char)
  (:export #:character-to-glyph))

(in-package :mezzano.supervisor)

(defmacro with-mutex ((lock) &body body)
  `(progn ,lock ,@body))

(in-package :mezzano.gui)

(defun make-surface-from-array (array &key format)
  (list :surface array format))

(in-package :mezzano.gui.font)

(defstruct test-character code bits)
(defstruct test-ttf-glyph code)
(defstruct glyph character mask yoff xoff advance)

(defclass typeface () ())
(defclass font ()
  ((cache :initform (make-array 17 :initial-element nil) :reader glyph-cache)
   (typeface :initform (make-instance 'typeface) :reader typeface)))

(defvar *ttf-present-codes* '())
(defvar *ttf-lookups* '())
(defvar *unifont-calls* '())
(defvar *unifont-missing-codes* '())
(defvar *fallback-mask* (make-array '(16 8) :initial-element 1))

(defun char-code (character)
  (etypecase character
    (test-character (test-character-code character))
    (character (cl:char-code character))))

(defun code-char (code)
  (or (cl:code-char code)
      (error "Test code point ~X is not representable by the host" code)))

(defun glyph-cache-lock (font)
  (declare (ignore font))
  nil)

(defun typeface-lock (typeface)
  (declare (ignore typeface))
  nil)

(defun font-loader (font)
  (declare (ignore font))
  :loader)

(defun font-scale (font)
  (declare (ignore font))
  1.0)

(defun scale-bb (bb scale)
  (declare (ignore scale))
  bb)

(defun rasterize-glyph (glyph scale)
  (declare (ignore scale))
  (list :rasterized (test-ttf-glyph-code glyph)))

(in-package :sys.int)

(defun char-bits (character)
  (if (mezzano.gui.font::test-character-p character)
      (mezzano.gui.font::test-character-bits character)
      0))

(defun map-unifont-2d (character)
  (push character mezzano.gui.font::*unifont-calls*)
  (let ((code (mezzano.gui.font::char-code character)))
    (unless (member code mezzano.gui.font::*unifont-missing-codes*)
      mezzano.gui.font::*fallback-mask*)))

(in-package :zpb-ttf)

(defun glyph-exists-p (code loader)
  (declare (ignore loader))
  (member code mezzano.gui.font::*ttf-present-codes*))

(defun find-glyph (code loader)
  (declare (ignore loader))
  (push code mezzano.gui.font::*ttf-lookups*)
  (mezzano.gui.font::make-test-ttf-glyph :code code))

(defun code-point (glyph)
  (mezzano.gui.font::test-ttf-glyph-code glyph))

(defun bounding-box (glyph)
  (declare (ignore glyph))
  #(0 0 8 12))

(defun advance-width (glyph)
  (declare (ignore glyph))
  8)

(defun ymax (bb) (aref bb 3))
(defun xmin (bb) (aref bb 0))

(in-package :mezzano.gui.font)

'''
    + method
    + r'''

(defun assert-true (condition format-control &rest arguments)
  (unless condition
    (apply #'error format-control arguments)))

(defun modifier-character (character bits)
  (make-test-character :code (cl:char-code character) :bits bits))

;; A modifier-bearing TTF character uses the same base glyph/cache cell as the
;; ordinary character. Calling it first must not leave modifier state in the
;; cached glyph, and the later ordinary lookup must not rasterize again.
(let* ((*ttf-present-codes* (list (cl:char-code #\A)))
       (*ttf-lookups* '())
       (font (make-instance 'font))
       (modified (modifier-character #\A #b1111))
       (modified-glyph (character-to-glyph font modified))
       (ordinary-glyph (character-to-glyph font #\A)))
  (assert-true (eq modified-glyph ordinary-glyph)
               "Modifier lookup polluted the ordinary glyph cache")
  (assert-true (eql (glyph-character modified-glyph) #\A)
               "Cached glyph retained modifier-bearing character state: ~S"
               (glyph-character modified-glyph))
  ;; FIND-GLYPH is called once by the implementation's code-point check and
  ;; once for rasterization. The cache hit must add no more calls.
  (assert-true (= (length *ttf-lookups*) 2)
               "Expected one rasterization path, got lookups ~S" *ttf-lookups*))

;; The Unifont boundary rejects modifier-bearing characters. A modified input
;; must be normalized before fallback, while an ordinary input retains the same
;; fallback and cache semantics.
(let* ((*unifont-calls* '())
       (font (make-instance 'font))
       (modified (modifier-character #\Snowman #b0011))
       (modified-glyph (character-to-glyph font modified))
       (ordinary-glyph (character-to-glyph font #\Snowman)))
  (assert-true (eq modified-glyph ordinary-glyph)
               "Fallback glyph was not shared with the ordinary cache entry")
  (assert-true (= (length *unifont-calls*) 1)
               "Expected one fallback lookup, got ~S" *unifont-calls*)
  (assert-true (and (characterp (first *unifont-calls*))
                    (zerop (sys.int:char-bits (first *unifont-calls*)))
                    (eql (first *unifont-calls*) #\Snowman))
               "Modifier state reached Unifont: ~S" *unifont-calls*))

;; Preserve missing-glyph behavior: if both the requested base character and
;; Unifont entry are absent, use WHITE_VERTICAL_RECTANGLE exactly once.
(let* ((*unifont-calls* '())
       (*unifont-missing-codes* (list (cl:char-code #\λ)))
       (font (make-instance 'font))
       (glyph (character-to-glyph
               font (modifier-character #\λ #b0100))))
  (assert-true (eql (glyph-character glyph) #\λ)
               "Missing-glyph fallback changed the glyph character")
  (assert-true (= (length *unifont-calls*) 2)
               "Expected requested and replacement fallback lookups: ~S"
               *unifont-calls*)
  (assert-true (and (eql (second *unifont-calls*) #\λ)
                    (eql (first *unifont-calls*) (code-char #x25AF)))
               "Fallback order changed: ~S" *unifont-calls*))

(format t "font modifier-bit behavioral tests passed~%")
''',
    encoding="utf-8",
)

if not normalizes_explicitly:
    # Run the semantic fixture first so a pre-change failure records both the
    # existing compatible behavior and the missing explicit font-boundary rule.
    output_path.write_text(
        output_path.read_text(encoding="utf-8")
        + '(error "character-to-glyph does not explicitly normalize modifier bits")\n',
        encoding="utf-8",
    )
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"
