#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${TELNET_SOURCE:-"$repo_root/applications/telnet.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-telnet-utf8-send.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")


def extract_form(name):
    marker = f"(defun {name}"
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f'Missing Telnet output helper "{name}"')

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
        if character == ";":
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f'Unterminated Telnet output helper "{name}"')


forms = [
    extract_form("%telnet-iac-escape-octets"),
    extract_form("%telnet-encode-output"),
]

output_path.write_text(
    r'''(defpackage :mezzano.internals
  (:use :cl)
  (:export #:encode-utf-8-string))
(in-package :mezzano.internals)

(defun encode-utf-8-string (sequence &key (eol-style :crlf) &allow-other-keys)
  "Host stub matching the scalar replacement and LF behavior of Lambda64."
  (unless (= (length sequence) 1)
    (error "Telnet must encode one short character string per callback"))
  (unless (eql eol-style :lf)
    (error "Telnet must preserve LF instead of applying CRLF conversion"))
  (let* ((character (char sequence 0))
         (code (char-code character)))
    (when (or (> code #x10FFFF) (<= #xD800 code #xDFFF))
      (setf code #xFFFD))
    (cond ((<= code #x7F)
           (vector code))
          ((<= code #x7FF)
           (vector (logior #xC0 (ash code -6))
                   (logior #x80 (logand code #x3F))))
          ((<= code #xFFFF)
           (vector (logior #xE0 (ash code -12))
                   (logior #x80 (logand (ash code -6) #x3F))
                   (logior #x80 (logand code #x3F))))
          (t
           (vector (logior #xF0 (ash code -18))
                   (logior #x80 (logand (ash code -12) #x3F))
                   (logior #x80 (logand (ash code -6) #x3F))
                   (logior #x80 (logand code #x3F)))))))

(defpackage :mezzano.telnet (:use :cl))
'''
    "(in-package :mezzano.telnet)\n"
    "(defconstant +command-iac+ 255)\n"
    + "\n\n".join(forms)
    + r'''

(defun assert-octets (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

;; ASCII/control payloads preserve their original byte meanings, including the
;; individual characters used to construct terminal escape sequences.
(loop :for character :in (list (code-char 0) #\Escape #\[ #\A #\Return #\Newline)
      :for expected :in '(0 27 91 65 13 10)
      :do (assert-octets (%telnet-encode-output character)
                          (vector expected)
                          "ASCII control payload"))

;; Representative two-, three-, and four-byte scalar values use canonical UTF-8.
(assert-octets (%telnet-encode-output (code-char #xE9))
                #(#xC3 #xA9)
                "two-byte UTF-8 payload")
(assert-octets (%telnet-encode-output (code-char #x4E2D))
                #(#xE4 #xB8 #xAD)
                "three-byte UTF-8 payload")
(assert-octets (%telnet-encode-output (code-char #x1F642))
                #(#xF0 #x9F #x99 #x82)
                "four-byte UTF-8 payload")

(let ((surrogate (code-char #xD800)))
  (when surrogate
    (assert-octets (%telnet-encode-output surrogate)
                    #(#xEF #xBF #xBD)
                    "UTF-16 surrogate replacement")))

;; U+00FF is UTF-8 text, not a raw Telnet IAC command byte.
(assert-octets (%telnet-encode-output (code-char #xFF))
                #(#xC3 #xBF)
                "U+00FF payload")

;; Any IAC byte in a Telnet data payload is doubled, including adjacent bytes.
(assert-octets (%telnet-iac-escape-octets #(1 255 2 255 255 3))
                #(1 255 255 2 255 255 255 255 3)
                "Telnet IAC escaping")

(format t "telnet UTF-8 send tests passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --non-interactive --load "$test_file"
