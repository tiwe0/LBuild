#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
telnet_source=${TELNET_SOURCE:-"$repo_root/applications/telnet.lisp"}
external_format_source=${EXTERNAL_FORMAT_SOURCE:-"$repo_root/system/external-format.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-telnet-receive.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$telnet_source" "$external_format_source" "$test_file" <<'PY'
from pathlib import Path
import sys

telnet_path = Path(sys.argv[1])
external_format_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
telnet = telnet_path.read_text(encoding="utf-8")
external_format = external_format_path.read_text(encoding="utf-8")


def extract_form(source, marker, description):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f'Missing {description}: {marker}')

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
    raise SystemExit(f'Unterminated {description}: {marker}')


external_forms = [
    extract_form(external_format, "(defun utf-8-decode-leader", "external-format helper"),
    extract_form(external_format, "(defun utf-8-continuation-byte-p", "external-format helper"),
    extract_form(external_format, "(deftype unicode-code-point", "external-format type"),
    extract_form(external_format, "(defun unicode-scalar-value-p", "external-format helper"),
    extract_form(external_format, "(defclass external-format", "external-format state"),
    extract_form(external_format, "(defun external-format-read-internal-code-point", "external-format decoder"),
]

constant_names = [
    "+command-se+", "+command-nop+", "+command-data-mark+", "+command-break+",
    "+command-interrupt-process+", "+command-Abort-output+", "+command-Are-You-There+",
    "+command-Erase-character+", "+command-Erase-Line+", "+command-Go-ahead+",
    "+command-SB+", "+command-WILL+", "+command-WONT+", "+command-DO+",
    "+command-DONT+", "+command-IAC+", "+option-transmit-binary+", "+option-echo+",
    "+option-suppress-go-ahead+", "+option-status+", "+option-window-size+",
    "+option-terminal-speed+", "+option-terminal-type+", "+option-x-display-location+",
    "+option-new-environ+", "+subnegotiation-is+", "+subnegotiation-send+",
    "+subnegotiation-info+", "+telnet-subnegotiation-payload-limit+",
]
telnet_forms = [
    *(extract_form(telnet, f"(defconstant {name}", "Telnet constant") for name in constant_names),
    extract_form(telnet, "(defun vector-ub8", "Telnet helper"),
    extract_form(telnet, "(defun %make-telnet-input-external-format", "Telnet decoder constructor"),
    extract_form(telnet, "(defun telnet-command", "Telnet command handler"),
    extract_form(telnet, "(defun send-window-size", "Telnet window-size sender"),
    extract_form(telnet, "(defclass telnet-client", "Telnet client state"),
    extract_form(telnet, "(defun %telnet-reset-subnegotiation", "Telnet framing helper"),
    extract_form(telnet, "(defun %telnet-deliver-decoder-result", "Telnet decoder helper"),
    extract_form(telnet, "(defun %telnet-receive-data-byte", "Telnet data helper"),
    extract_form(telnet, "(defun %telnet-begin-subnegotiation", "Telnet framing helper"),
    extract_form(telnet, "(defun %telnet-append-subnegotiation-byte", "Telnet framing helper"),
    extract_form(telnet, "(defun %telnet-process-iac-command", "Telnet framing helper"),
    extract_form(telnet, "(defun telnet-receive-byte", "Telnet receive entry point"),
    extract_form(telnet, "(defun telnet-receive-eof", "Telnet EOF entry point"),
]

output_path.write_text(
    r'''(defpackage :mezzano.internals (:use :cl))
(defpackage :mezzano.gui.xterm
  (:use :cl)
  (:export #:receive-char #:terminal-width #:terminal-height))
(defpackage :mezzano.telnet (:use :cl))

(in-package :mezzano.gui.xterm)
(defun receive-char (sink character) (funcall sink character))
(defun terminal-width (sink) (declare (ignore sink)) 80)
(defun terminal-height (sink) (declare (ignore sink)) 24)

(in-package :mezzano.internals)
'''
    + "\n\n".join(external_forms)
    + r'''

(in-package :mezzano.telnet)
'''
    + "\n\n".join(telnet_forms)
    + r'''

(defclass capture-output-stream (sb-gray:fundamental-binary-output-stream)
  ((octets :initform (make-array 16 :element-type '(unsigned-byte 8)
                                 :adjustable t :fill-pointer 0)
           :reader captured-octets)))

(defmethod sb-gray:stream-write-byte ((stream capture-output-stream) byte)
  (vector-push-extend byte (captured-octets stream))
  byte)

(defmethod sb-gray:stream-write-sequence ((stream capture-output-stream) sequence
                                          &optional (start 0) end)
  (setf end (or end (length sequence)))
  (loop :for index :from start :below end
        :do (vector-push-extend (elt sequence index) (captured-octets stream)))
  sequence)

(defun make-test-client ()
  (let ((characters (make-array 16 :element-type 'character
                                :adjustable t :fill-pointer 0))
        (connection (make-instance 'capture-output-stream)))
    (values (make-instance 'telnet-client
                           :xterm (lambda (character)
                                    (vector-push-extend character characters))
                           :terminal-type "xterm-color"
                           :connection connection
                           :do-window-size-updates nil)
            characters
            connection)))

(defun reset-characters (characters)
  (setf (fill-pointer characters) 0))

(defun reset-octets (connection)
  (setf (fill-pointer (captured-octets connection)) 0))

(defun assert-equalp (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(defun feed (client &rest octets)
  (dolist (octet octets)
    (telnet-receive-byte client octet)))

(defun receive-state-snapshot (client)
  (let ((external-format (telnet-input-external-format client)))
    (list (telnet-framing-state client)
          (telnet-pending-command client)
          (telnet-subnegotiation-option client)
          (copy-seq (telnet-subnegotiation-data client))
          (last-was-cr client)
          external-format
          (slot-value external-format 'mezzano.internals::%accumulated-code-point)
          (slot-value external-format 'mezzano.internals::%code-point-bytes-remaining)
          (telnet-receive-eof-p client))))

(defun assert-no-data-preserves-state (client characters connection description)
  (let ((state (receive-state-snapshot client))
        (output (copy-seq characters))
        (replies (copy-seq (captured-octets connection))))
    (telnet-receive-byte client nil)
    (assert-equalp (receive-state-snapshot client) state description)
    (assert-equalp characters output description)
    (assert-equalp (captured-octets connection) replies description)))

(defun assert-eof-resets-receiver (client characters connection description)
  (let ((old-external-format (telnet-input-external-format client)))
    (telnet-receive-eof client)
    (unless (and (eql (telnet-framing-state client) :data)
                 (not (telnet-pending-command client))
                 (not (telnet-subnegotiation-option client))
                 (zerop (length (telnet-subnegotiation-data client)))
                 (not (last-was-cr client))
                 (telnet-receive-eof-p client)
                 (not (eq old-external-format
                          (telnet-input-external-format client))))
      (error "~A did not reset all receive state" description))
    (let ((state (receive-state-snapshot client))
          (output (copy-seq characters))
          (replies (copy-seq (captured-octets connection))))
      (telnet-receive-eof client)
      (assert-equalp (receive-state-snapshot client) state description)
      (assert-equalp characters output description)
      (assert-equalp (captured-octets connection) replies description))))

(defun assert-valid-utf-8-splits (octets expected)
  (loop :for split :from 1 :below (length octets)
        :do (multiple-value-bind (client characters) (make-test-client)
              (loop :for index :below split
                    :do (telnet-receive-byte client (aref octets index)))
              (assert-equalp characters "" "incomplete UTF-8 prefix")
              ;; NIL is the no-data result of READ-BYTE-NO-HANG. It must not
              ;; advance either framing or decoder state.
              (telnet-receive-byte client nil)
              (loop :for index :from split :below (length octets)
                    :do (telnet-receive-byte client (aref octets index)))
              (assert-equalp characters expected "split UTF-8 sequence"))))

;; All valid UTF-8 widths survive every packet boundary.
(multiple-value-bind (client characters) (make-test-client)
  (feed client #x41)
  (assert-equalp characters "A" "ASCII payload"))
(assert-valid-utf-8-splits #(#xC3 #xA9) (string (code-char #xE9)))
(assert-valid-utf-8-splits #(#xE4 #xB8 #xAD) (string (code-char #x4E2D)))
(assert-valid-utf-8-splits #(#xF0 #x9F #x99 #x82) (string (code-char #x1F642)))

;; Decoder errors match the existing external-format state machine, including
;; resynchronising a valid leader that appeared where a continuation was due.
(multiple-value-bind (client characters) (make-test-client)
  (feed client #x80 #xE2 #x41 #xED #xA0 #x80 #xEF #xB7 #x90)
  (assert-equalp characters
                 (coerce (list #\Replacement_Character
                               #\Replacement_Character
                               #\A
                               #\Replacement_Character
                               #\Replacement_Character)
                         'string)
                 "invalid UTF-8 replacement and resynchronisation"))
(multiple-value-bind (client characters) (make-test-client)
  ;; The current external format accepts this overlong representation of NUL;
  ;; Telnet deliberately inherits that behavior rather than defining a second
  ;; UTF-8 policy.
  (feed client #xC0 #x80)
  (assert-equalp characters (string (code-char 0)) "external-format compatibility"))

;; Quoted IAC is restored as data and is consequently an invalid UTF-8 leader.
(multiple-value-bind (client characters) (make-test-client)
  (feed client +command-iac+ +command-iac+)
  (assert-equalp characters (string #\Replacement_Character) "quoted IAC data"))

;; Negotiation is dispatched only when the option octet arrives. The output
;; stream deliberately has no input methods, so any synchronous read fails.
(multiple-value-bind (client characters connection) (make-test-client)
  (declare (ignore characters))
  (feed client +command-iac+ +command-do+)
  (assert-equalp (captured-octets connection) #() "partial negotiation")
  (telnet-receive-byte client nil)
  (assert-equalp (captured-octets connection) #() "no-data negotiation state")
  (feed client +option-terminal-type+)
  (assert-equalp (captured-octets connection)
                 (vector +command-iac+ +command-will+ +option-terminal-type+)
                 "completed negotiation"))
(multiple-value-bind (client characters connection) (make-test-client)
  (declare (ignore characters))
  (feed client +command-iac+ +command-will+ +option-echo+
        +command-iac+ +command-wont+ +option-echo+)
  (assert-equalp (captured-octets connection) #() "WILL/WONT negotiation"))

;; Subnegotiation retains escaped IAC and dispatches only at IAC SE.
(multiple-value-bind (client characters connection) (make-test-client)
  (declare (ignore characters))
  (feed client +command-iac+ +command-sb+ +option-terminal-type+
        +subnegotiation-send+ +command-iac+)
  (assert-equalp (captured-octets connection) #() "partial subnegotiation")
  (feed client +command-se+)
  (assert-equalp (captured-octets connection)
                 (concatenate 'vector
                              (vector +command-iac+ +command-sb+
                                      +option-terminal-type+ +subnegotiation-is+)
                 (map 'vector #'char-code "xterm-color")
                              (vector +command-iac+ +command-se+))
                 "completed terminal-type subnegotiation"))
(multiple-value-bind (client characters) (make-test-client)
  (declare (ignore characters))
  (let ((original-command (symbol-function 'telnet-command))
        (captured-command nil)
        (captured-option nil)
        (captured-data nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'telnet-command)
                 (lambda (telnet command &optional option data)
                   (declare (ignore telnet))
                   (setf captured-command command
                         captured-option option
                         captured-data (copy-seq data))))
           (feed client +command-iac+ +command-sb+ +option-status+
                 1 +command-iac+ +command-iac+)
           (unless (eql (telnet-framing-state client) :sb-data)
             (error "Escaped subnegotiation IAC did not return to SB data"))
           (feed client 2
                 +command-iac+ +command-se+)
           (unless (and (eql captured-command +command-sb+)
                        (eql captured-option +option-status+))
             (error "Subnegotiation command or option was not dispatched"))
           (assert-equalp captured-data #(1 255 2)
                          "escaped IAC in subnegotiation payload"))
      (setf (symbol-function 'telnet-command) original-command))))

;; A malformed SB IAC command is reprocessed as a top-level command and can
;; resume normally on the next option byte.
(multiple-value-bind (client characters connection) (make-test-client)
  (declare (ignore characters))
  (feed client +command-iac+ +command-sb+ +option-status+ 1
        +command-iac+ +command-do+ +option-terminal-type+)
  (assert-equalp (captured-octets connection)
                 (vector +command-iac+ +command-will+ +option-terminal-type+)
                 "malformed subnegotiation recovery"))
(multiple-value-bind (client characters connection) (make-test-client)
  (declare (ignore connection))
  (feed client +command-iac+ +command-sb+ +option-status+ 1
        +command-iac+ +command-nop+ #x41)
  (unless (eql (telnet-framing-state client) :data)
    (error "Malformed SB followed by a simple command did not resynchronise"))
  (assert-equalp characters "A" "simple-command subnegotiation recovery"))
(multiple-value-bind (client characters) (make-test-client)
  (declare (ignore characters))
  (let ((original-command (symbol-function 'telnet-command))
        (captured-option nil)
        (captured-data nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'telnet-command)
                 (lambda (telnet command &optional option data)
                   (declare (ignore telnet))
                   (when (eql command +command-sb+)
                     (setf captured-option option
                           captured-data (copy-seq data)))))
           (feed client +command-iac+ +command-sb+ +option-status+ 1
                 +command-iac+ +command-sb+ +option-terminal-type+
                 +subnegotiation-send+ +command-iac+ +command-se+)
           (unless (eql captured-option +option-terminal-type+)
             (error "Nested SB did not replace the malformed subnegotiation"))
           (assert-equalp captured-data (vector +subnegotiation-send+)
                          "nested subnegotiation recovery"))
      (setf (symbol-function 'telnet-command) original-command))))

;; CR is delivered immediately, a following data NUL is suppressed, and
;; Telnet control frames do not clear the pending CR state.
(multiple-value-bind (client characters) (make-test-client)
  (feed client #x0D +command-iac+ +command-nop+ #x00 #x0D #x0A)
  (assert-equalp characters (coerce (list #\Return #\Return #\Newline) 'string)
                 "NVT CR/NUL handling"))

;; Subnegotiation storage is fixed at a conservative bound. Overflow discards
;; input through IAC SE, then resets non-fatally for subsequent data.
(multiple-value-bind (client characters) (make-test-client)
  (declare (ignore characters))
  (let ((original-command (symbol-function 'telnet-command))
        (captured-data nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'telnet-command)
                 (lambda (telnet command &optional option data)
                   (declare (ignore telnet option))
                   (when (eql command +command-sb+)
                     (setf captured-data (copy-seq data)))))
           (feed client +command-iac+ +command-sb+ +option-status+)
           (dotimes (index +telnet-subnegotiation-payload-limit+)
             (declare (ignore index))
             (telnet-receive-byte client #x41))
           (unless (and (eql (telnet-framing-state client) :sb-data)
                        (= (length (telnet-subnegotiation-data client))
                           +telnet-subnegotiation-payload-limit+))
             (error "Exact-limit SB was rejected before its terminator"))
           (feed client +command-iac+ +command-se+)
           (unless (and captured-data
                        (= (length captured-data)
                           +telnet-subnegotiation-payload-limit+)
                        (every (lambda (octet) (= octet #x41)) captured-data))
             (error "Exact-limit SB was not dispatched intact")))
      (setf (symbol-function 'telnet-command) original-command))))
(multiple-value-bind (client characters) (make-test-client)
  (feed client +command-iac+ +command-sb+ +option-status+)
  (dotimes (index (1+ +telnet-subnegotiation-payload-limit+))
    (declare (ignore index))
    (telnet-receive-byte client #x41))
  (unless (eql (telnet-framing-state client) :sb-discard)
    (error "Over-limit SB did not enter bounded discard state"))
  (unless (zerop (length (telnet-subnegotiation-data client)))
    (error "Over-limit SB retained payload storage"))
  (feed client #x42 +command-iac+ +command-iac+ #x43
        +command-iac+ +command-se+ #x44)
  (assert-equalp characters "D" "over-limit subnegotiation recovery"))

;; Every partial framing state preserves all parser, decoder, and output state
;; when READ-BYTE-NO-HANG reports NIL, and EOF resets it idempotently.
(dolist (scenario
          (list
           (list :iac
                 (lambda (client)
                   (feed client +command-iac+)))
           (list :sb-option
                 (lambda (client)
                   (feed client +command-iac+ +command-sb+)))
           (list :sb-data
                 (lambda (client)
                   (feed client +command-iac+ +command-sb+ +option-status+ #x41)))
           (list :sb-iac
                 (lambda (client)
                   (feed client +command-iac+ +command-sb+ +option-status+
                         #x41 +command-iac+)))
           (list :sb-discard
                 (lambda (client)
                   (feed client +command-iac+ +command-sb+ +option-status+)
                   (dotimes (index (1+ +telnet-subnegotiation-payload-limit+))
                     (declare (ignore index))
                     (telnet-receive-byte client #x41))))
           (list :sb-discard-iac
                 (lambda (client)
                   (feed client +command-iac+ +command-sb+ +option-status+)
                   (dotimes (index (1+ +telnet-subnegotiation-payload-limit+))
                     (declare (ignore index))
                     (telnet-receive-byte client #x41))
                   (feed client +command-iac+)))))
  (destructuring-bind (expected-state setup) scenario
    (multiple-value-bind (client characters connection) (make-test-client)
      (funcall setup client)
      (unless (eql (telnet-framing-state client) expected-state)
        (error "Scenario entered ~S instead of ~S"
               (telnet-framing-state client) expected-state))
      (assert-no-data-preserves-state
       client characters connection
       (format nil "NIL preservation in ~S" expected-state))
      (assert-eof-resets-receiver
       client characters connection
       (format nil "EOF reset from ~S" expected-state)))))

;; EOF finalises a partial UTF-8 scalar once, discards incomplete control
;; framing, and repeated EOF is idempotent.
(multiple-value-bind (client characters connection) (make-test-client)
  (feed client #xE2)
  (telnet-receive-eof client)
  (telnet-receive-eof client)
  (assert-equalp characters (string #\Replacement_Character) "UTF-8 EOF finalisation")
  (reset-characters characters)
  (reset-octets connection)
  (feed client +command-iac+ +command-do+)
  (telnet-receive-eof client)
  (telnet-receive-eof client)
  (assert-equalp characters "" "control-frame EOF finalisation")
  (assert-equalp (captured-octets connection) #() "EOF must not reply"))

;; EOF on a clean decoder boundary emits nothing, and feeding a new octet after
;; EOF starts a fresh receive session successfully.
(multiple-value-bind (client characters connection) (make-test-client)
  (feed client #x41)
  (telnet-receive-eof client)
  (assert-equalp characters "A" "clean-boundary EOF")
  (assert-equalp (captured-octets connection) #() "clean-boundary EOF reply")
  (feed client #x42)
  (unless (not (telnet-receive-eof-p client))
    (error "A new octet after EOF did not reopen receive state"))
  (assert-equalp characters "AB" "feed after EOF")
  (telnet-receive-eof client)
  (assert-equalp characters "AB" "clean EOF after reopened receive state"))

(format t "Telnet non-blocking receive tests passed.~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --disable-debugger --script "$test_file"

debt_marker=FIX
debt_marker+=ME
if grep -Eq "$debt_marker: (Translate from UTF-8 here|This does sync reads)" "$telnet_source"; then
  echo "Telnet receive debt marker remains after state-machine integration" >&2
  exit 1
fi
