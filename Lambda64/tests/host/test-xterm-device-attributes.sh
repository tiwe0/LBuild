#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
xterm_source=${XTERM_SOURCE:-"$repo_root/gui/xterm.lisp"}
telnet_source=${TELNET_SOURCE:-"$repo_root/applications/telnet.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-xterm-device-attributes.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$xterm_source" "$telnet_source" "$test_file" <<'PY'
from pathlib import Path
import sys

xterm_path = Path(sys.argv[1])
telnet_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
xterm = xterm_path.read_text(encoding="utf-8")
telnet = telnet_path.read_text(encoding="utf-8")


def extract_form(source, marker, description):
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


def extract_optional_form(source, marker, description, fallback):
    if marker not in source:
        return fallback
    return extract_form(source, marker, description)


xterm_forms = [
    extract_form(xterm, "(defclass xterm-terminal", "XTerm terminal class"),
    extract_form(xterm, "(defmethod initialize-instance :after",
                 "XTerm initializer"),
    extract_form(xterm, "(defun default-action", "XTerm parser helper"),
    extract_form(xterm, "(defun xterm-ground", "XTerm ground state"),
    extract_form(xterm, "(defun xterm-escape ", "XTerm escape state"),
    extract_form(xterm, "(defun xterm-csi-entry", "XTerm CSI entry state"),
    extract_form(xterm, "(defun xterm-csi-param", "XTerm CSI parameter state"),
    extract_form(xterm, "(defun xterm-clear", "XTerm clear action"),
    extract_form(xterm, "(defun xterm-collect", "XTerm collect action"),
    extract_form(xterm, "(defun xterm-param", "XTerm parameter action"),
    extract_form(xterm, "(defun xterm-csi-dispatch", "XTerm CSI dispatcher"),
    extract_form(xterm, "(defun receive-char", "XTerm receive entry point"),
]

telnet_forms = [
    extract_form(telnet, "(defconstant +command-IAC+", "Telnet IAC constant"),
    extract_form(telnet, "(defconstant +telnet-subnegotiation-payload-limit+",
                 "Telnet subnegotiation limit"),
    extract_form(telnet, "(defun %telnet-iac-escape-octets", "Telnet IAC helper"),
    extract_form(telnet, "(defun %telnet-encode-output", "Telnet output encoder"),
    extract_form(telnet, "(defclass telnet-client", "Telnet client class"),
    extract_optional_form(
        telnet,
        "(defun %make-telnet-response-bridge",
        "Telnet response bridge",
        '''(defun %make-telnet-response-bridge ()
  (error "Telnet response bridge is not implemented."))''',
    ),
]

output_path.write_text(
    r'''(defpackage :mezzano.internals (:use :cl))
(defpackage :mezzano.gui (:use :cl) (:export #:bitset))
(defpackage :mezzano.gui.xterm (:use :cl))
(defpackage :mezzano.telnet (:use :cl))

(in-package :mezzano.gui)
(defun bitset (&rest arguments) (declare (ignore arguments)))

(in-package :mezzano.internals)
(defun encode-utf-8-string (sequence &key eol-style &allow-other-keys)
  (unless (and (eql eol-style :lf) (= (length sequence) 1))
    (error "Unexpected terminal response encoder input"))
  (let ((code (char-code (char sequence 0))))
    (if (<= code #x7F)
        (vector code)
        (error "The DA response must be ASCII"))))

(in-package :mezzano.gui.xterm)
(declaim (ftype function
                xterm-clear xterm-execute xterm-osc-start xterm-print
                xterm-collect xterm-esc-dispatch xterm-csi-dispatch
                xterm-param adjust-ansi-mode adjust-dec-private-mode clear
                erase report-unknown-escape scroll-terminal
                set-character-attributes cell-pixel-width cell-pixel-height
                soft-reset true-background-colour))
'''
    + "\n\n".join(xterm_forms)
    + r'''

;; The focused parser path does not render, but these functions are referenced
;; by other branches in the extracted state machine and dispatcher.
(defun xterm-execute (&rest arguments) (declare (ignore arguments)))
(defun xterm-print (&rest arguments) (declare (ignore arguments)))
(defun xterm-esc-dispatch (&rest arguments) (declare (ignore arguments)))
(defun xterm-osc-start (&rest arguments) (declare (ignore arguments)))
(defun xterm-hook (&rest arguments) (declare (ignore arguments)))
(defun set-character-attributes (&rest arguments) (declare (ignore arguments)))
(defun adjust-ansi-mode (&rest arguments) (declare (ignore arguments)))
(defun adjust-dec-private-mode (&rest arguments) (declare (ignore arguments)))
(defun scroll-terminal (&rest arguments) (declare (ignore arguments)))
(defun cell-pixel-width (terminal) (declare (ignore terminal)) 1)
(defun cell-pixel-height (terminal) (declare (ignore terminal)) 1)
(defun soft-reset (terminal) (declare (ignore terminal)))
(defun true-background-colour (terminal) (declare (ignore terminal)) 0)

(defvar *unknown-escape-count* 0)
(defun report-unknown-escape (terminal)
  (declare (ignore terminal))
  (incf *unknown-escape-count*))

(defun make-parser-terminal (response-function)
  (let ((terminal (allocate-instance (find-class 'xterm-terminal))))
    (setf (slot-value terminal 'state) 'xterm-ground
          (slot-value terminal 'intermediate-characters) '()
          (slot-value terminal 'parameters) (make-array 16 :initial-element nil)
          (slot-value terminal 'n-parameters) 0
          (slot-value terminal 'parameter-separator-count) 0
          (slot-value terminal 'escape-sequence) '()
          (slot-value terminal 'response-function) response-function)
    terminal))

(defun feed-string (terminal string)
  (map nil (lambda (character) (receive-char terminal character)) string))

(defun csi (parameters)
  (concatenate 'string (string #\Escape) "[" parameters "c"))

(defun assert-equalp (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(let ((unconfigured (allocate-instance (find-class 'xterm-terminal))))
  (unless (handler-case (progn (response-function unconfigured) nil)
            (unbound-slot () t))
    (error "XTerm response callback has an implicit default")))

(defun make-initialized-terminal (&optional (response-function nil supplied-p))
  (apply #'make-instance
         'xterm-terminal
         :framebuffer :framebuffer
         :font :font
         :x 0
         :y 0
         :width 1
         :height 1
         :damage-function (lambda (&rest arguments)
                            (declare (ignore arguments)))
         (when supplied-p
           (list :response-function response-function))))

(dolist (constructor
         (list (lambda () (make-initialized-terminal))
               (lambda () (make-initialized-terminal nil))
               (lambda () (make-initialized-terminal 42))))
  (unless (handler-case (progn (funcall constructor) nil)
            (error () t))
    (error "XTerm initializer accepted a missing or non-function callback")))

(let ((callback (lambda (character) (declare (ignore character)))))
  (unless (eq (response-function (make-initialized-terminal callback))
              callback)
    (error "XTerm initializer rejected or replaced a function callback")))

(let ((response (make-array 16 :element-type 'character
                            :adjustable t :fill-pointer 0)))
  (let ((terminal (make-parser-terminal
                   (lambda (character)
                     (vector-push-extend character response)))))
    (feed-string terminal (csi ""))
    (assert-equalp response
                   (concatenate 'string (string #\Escape) "[?1;2c")
                   "parameterless primary DA response")
    (setf (fill-pointer response) 0)
    (feed-string terminal (csi "0"))
    (assert-equalp response
                   (concatenate 'string (string #\Escape) "[?1;2c")
                   "explicit-zero primary DA response")
    (setf (fill-pointer response) 0
          *unknown-escape-count* 0)
    (feed-string terminal (csi "1"))
    (feed-string terminal (csi "0;0"))
    (feed-string terminal (csi "0;"))
    (assert-equalp response "" "unsupported DA parameters")
    (assert-equalp *unknown-escape-count* 3
                   "unsupported DA unknown-path count")))

(in-package :mezzano.telnet)

(defun %make-telnet-input-external-format () nil)
'''
    + "\n\n".join(telnet_forms)
    + r'''

(defclass capture-output-stream (sb-gray:fundamental-binary-output-stream)
  ((octets :initform (make-array 16 :element-type '(unsigned-byte 8)
                                 :adjustable t :fill-pointer 0)
           :reader captured-octets)))

(defmethod sb-gray:stream-write-sequence ((stream capture-output-stream) sequence
                                          &optional (start 0) end)
  (setf end (or end (length sequence)))
  (loop :for index :from start :below end
        :do (vector-push-extend (elt sequence index) (captured-octets stream)))
  sequence)

(defun assert-equalp (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(multiple-value-bind (response-function set-client)
    (%make-telnet-response-bridge)
  ;; Construction cannot silently discard a response before the client exists.
  (unless (handler-case (progn (funcall response-function #\Escape) nil)
            (error () t))
    (error "Unbound Telnet response bridge silently accepted output"))
  (let ((client (make-instance 'telnet-client
                               :connection nil
                               :do-window-size-updates nil)))
    (funcall set-client client)
    (unless (handler-case (progn (funcall response-function #\Escape) nil)
              (error () t))
      (error "Disconnected Telnet response bridge silently accepted output"))
    (let ((connection (make-instance 'capture-output-stream)))
      (setf (connection client) connection)
      (let ((terminal
              (mezzano.gui.xterm::make-parser-terminal response-function)))
        (mezzano.gui.xterm::feed-string
         terminal
         (mezzano.gui.xterm::csi "")))
      (assert-equalp (captured-octets connection)
                     #(27 91 63 49 59 50 99)
                     "XTerm DA response over the Telnet connection"))))

(format t "xterm device attributes tests passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --non-interactive --load "$test_file"
