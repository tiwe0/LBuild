#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${IP_SOURCE:-"$repo_root/net/ip.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-net-ip-state-and-fragments.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

python3 - "$source_file" "$test_file" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")


def extract_form(marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"Missing IPv4 state/reassembly form: {marker}")
    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    block_comment_depth = 0
    index = start
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if block_comment_depth:
            if character == "#" and following == "|":
                block_comment_depth += 1
                index += 2
                continue
            if character == "|" and following == "#":
                block_comment_depth -= 1
                index += 2
                continue
            index += 1
            continue
        if in_comment:
            if character == "\n":
                in_comment = False
            index += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == "#" and following == "|":
            block_comment_depth = 1
            index += 2
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
        index += 1
    raise SystemExit(f"Unterminated IPv4 form: {marker}")


markers = [
    "(defconstant +ipv4-header-version-and-ihl+",
    "(defconstant +ipv4-header-version-size+",
    "(defconstant +ipv4-header-version-position+",
    "(defconstant +ipv4-header-ihl-size+",
    "(defconstant +ipv4-header-ihl-position+",
    "(defconstant +ipv4-header-total-length+",
    "(defconstant +ipv4-header-identification+",
    "(defconstant +ipv4-header-fragmentation-control+",
    "(defconstant +ipv4-header-fragment-offset-size+",
    "(defconstant +ipv4-header-fragment-offset-position+",
    "(defconstant +ipv4-header-flag-more-fragments+",
    "(defconstant +ipv4-header-flag-do-not-fragment+",
    "(defconstant +ipv4-header-flag-reserved+",
    "(defconstant +ipv4-header-ttl+",
    "(defconstant +ipv4-header-protocol+",
    "(defconstant +ipv4-header-checksum+",
    "(defconstant +ipv4-header-source-ip+",
    "(defconstant +ipv4-header-destination-ip+",
    "(defparameter *outstanding-send-timeout*",
    "(defvar *outstanding-sends*",
    "(defvar *outstanding-sends-lock*",
    "(defvar *arp-update-generation*",
    "(defun outstanding-send-expired-p",
    "(defun expire-outstanding-sends",
    "(defun schedule-outstanding-send-expiration",
    "(defun retry-outstanding-send",
    "(defun queue-outstanding-send",
    "(defun transmit-or-queue-ipv4-packet",
    "(defun arp-table-updated",
    "(defparameter *ipv4-reassembly-timeout*",
    "(defconstant +maximum-ipv4-reassembled-payload-size+",
    "(defconstant +maximum-ipv4-reassemblies+",
    "(defconstant +maximum-ipv4-fragments-per-datagram+",
    "(defstruct (ipv4-fragment",
    "(defstruct (ipv4-reassembly",
    "(defvar *ipv4-reassemblies*",
    "(defvar *ipv4-reassembly-expiration-scheduled-p*",
    "(defun expire-ipv4-reassemblies",
    "(defun ipv4-reassembly-expiration-handler",
    "(defun schedule-ipv4-reassembly-expiration",
    "(defun accept-ipv4-fragment",
    "(defparameter *print-discarded-packets*",
    "(defparameter *discarded-packet-count*",
    "(defmethod mezzano.network.ethernet:ethernet-receive",
]

forms = [extract_form(marker) for marker in markers]

required_source = [
    "(queue-outstanding-send destination-host interface packet generation)",
    "(accept-ipv4-fragment",
]
for text in required_source:
    if text not in source:
        raise SystemExit(f"IPv4 receive/transmit integration is missing: {text}")
if "Discarding fragmented IPv4 packet (not supported)" in source:
    raise SystemExit("IPv4 receive still silently discards every fragment")

output_path.write_text(
    r'''(defpackage :mezzano.network (:use :cl))
(in-package :mezzano.network)
(defvar *network-serial-queue* :host-network-queue)

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:make-mutex #:with-mutex))
(in-package :mezzano.supervisor)
(defvar *lock-depth* 0)
(defun make-mutex (&optional name)
  (declare (ignore name))
  :host-mutex)
(defmacro with-mutex ((mutex) &body body)
  (declare (ignore mutex))
  `(progn
     (incf *lock-depth*)
     (unwind-protect (progn ,@body)
       (decf *lock-depth*))))

(defpackage :mezzano.sync.dispatch
  (:use :cl)
  (:export #:dispatch-delayed))
(in-package :mezzano.sync.dispatch)
(defvar *scheduled-callbacks* nil)
(defun dispatch-delayed (function delay queue)
  (push (list function delay queue) *scheduled-callbacks*)
  (values))

(defpackage :mezzano.network.ethernet
  (:use :cl)
  (:export #:ethernet-receive #:+ethertype-ipv4+))
(in-package :mezzano.network.ethernet)
(defconstant +ethertype-ipv4+ #x0800)
(defgeneric ethernet-receive (ethertype interface packet start end))

(defpackage :mezzano.network.ip
  (:use :cl)
  (:local-nicknames (:net :mezzano.network)))
(in-package :mezzano.network.ip)
(defun ub16ref/be (vector offset)
  (logior (ash (aref vector offset) 8)
          (aref vector (+ offset 1))))
(defun (setf ub16ref/be) (value vector offset)
  (setf (aref vector offset) (ldb (byte 8 8) value)
        (aref vector (+ offset 1)) (ldb (byte 8 0) value))
  value)
(defun ub32ref/be (vector offset)
  (logior (ash (aref vector offset) 24)
          (ash (aref vector (+ offset 1)) 16)
          (ash (aref vector (+ offset 2)) 8)
          (aref vector (+ offset 3))))
(defun (setf ub32ref/be) (value vector offset)
  (setf (aref vector offset) (ldb (byte 8 24) value)
        (aref vector (+ offset 1)) (ldb (byte 8 16) value)
        (aref vector (+ offset 2)) (ldb (byte 8 8) value)
        (aref vector (+ offset 3)) (ldb (byte 8 0) value))
  value)
(defun compute-ip-checksum (&rest arguments)
  (declare (ignore arguments))
  0)
(defun make-ipv4-address (address) address)
(defun ipv4-address-address (address) address)
(defparameter +ipv4-broadcast-local-network+ #xFFFFFFFF)
(defun address-equal (left right) (eql left right))
(defun ipv4-address-interface (address &optional errorp)
  (declare (ignore address errorp))
  t)
(defun ipv4-interface-address (interface &optional errorp)
  (declare (ignore interface errorp))
  (values #xC6336401 24))
(defun address-network-broadcast (address prefix-length)
  (declare (ignore address prefix-length))
  #xC63364FF)
(defun multicast-address-p (address)
  (declare (ignore address))
  nil)
(defvar *received-ipv4-packets* nil)
(defvar *transmit-attempts* nil)
(defvar *transmit-results* nil)
(declaim (ftype (function () *) arp-table-updated))
(defun try-ethernet-transmit (destination interface packet)
  (unless (zerop mezzano.supervisor::*lock-depth*)
    (error "Ethernet transmit attempted while outstanding-send lock was held"))
  (push (list destination interface packet) *transmit-attempts*)
  (case (pop *transmit-results*)
    (:success t)
    (:miss nil)
    (:miss-with-update
     (arp-table-updated)
     nil)
    (t nil)))
(defgeneric ipv4-receive (protocol packet dest-ip source-ip start end))
(defmethod ipv4-receive (protocol packet dest-ip source-ip start end)
  (push (list protocol dest-ip source-ip (subseq packet start end))
        *received-ipv4-packets*))
'''
    + "\n\n".join(forms)
    + r'''

(defun octets (&rest values)
  (make-array (length values)
              :element-type '(unsigned-byte 8)
              :initial-contents values))

(defun assert-equalp (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(defun assert-true (value description)
  (unless value
    (error "~A was false" description)))

(assert-equalp +ipv4-header-fragment-offset-size+ 13
               "IPv4 fragment-offset field width")

;;; Outstanding ARP-dependent sends have an absolute monotonic deadline and an
;;; independently scheduled cleanup, rather than depending on another ARP event.
(setf *outstanding-sends* nil
      *outstanding-send-timeout* 10
      *arp-update-generation* 0
      mezzano.sync.dispatch::*scheduled-callbacks* nil)
(queue-outstanding-send :destination :interface :packet 0 100)
(let* ((entry (first *outstanding-sends*))
       (deadline (fifth entry)))
  (assert-equalp (subseq entry 0 4)
                 '(:destination :interface :packet 0)
                 "queued send fields")
  (assert-equalp deadline
                 (+ 100 (* 10 internal-time-units-per-second))
                 "queued send deadline")
  (expire-outstanding-sends (1- deadline))
  (assert-equalp (length *outstanding-sends*) 1 "send before deadline")
  (expire-outstanding-sends deadline)
  (assert-equalp *outstanding-sends* nil "send at deadline"))
(let ((scheduled (first mezzano.sync.dispatch::*scheduled-callbacks*)))
  (assert-true scheduled "outstanding-send cleanup scheduling")
  (assert-equalp (second scheduled) 10 "outstanding-send cleanup delay")
  (assert-equalp (third scheduled) :host-network-queue
                 "outstanding-send cleanup queue"))

(let* ((now (get-internal-real-time))
       (live-deadline (+ now (* 100 internal-time-units-per-second))))
  (setf *transmit-attempts* nil
        *transmit-results* '(:miss)
        *outstanding-sends*
        `((:expired :interface :old-packet 0 ,(1- now))
          (:live :interface :new-packet 2 ,live-deadline)))
  (arp-table-updated)
  (assert-equalp *transmit-attempts*
                 '((:live :interface :new-packet))
                 "ARP update skips expired sends")
  (assert-equalp *outstanding-sends*
                 `((:live :interface :new-packet 3 ,live-deadline))
                 "ARP retry preserves original deadline"))

;;; Deterministic lost-wakeup interleaving: the first lookup misses, an ARP
;;; update runs before the miss is queued, and the generation mismatch claims
;;; the new entry for one immediate retry. The successful retry is not queued
;;; and no update can send it a second time.
(setf *outstanding-sends* nil
      *arp-update-generation* 0
      *transmit-attempts* nil
      *transmit-results* '(:miss-with-update :success))
(transmit-or-queue-ipv4-packet :barrier-destination :interface :barrier-packet)
(assert-equalp (reverse *transmit-attempts*)
               '((:barrier-destination :interface :barrier-packet)
                 (:barrier-destination :interface :barrier-packet))
               "ARP reply between miss and enqueue")
(assert-equalp *outstanding-sends* nil
               "lost-wakeup retry completion")
(arp-table-updated)
(assert-equalp (length *transmit-attempts*) 2
               "completed lost-wakeup retry is not sent twice")

;;; The non-racing path queues exactly once and a later ARP update claims it
;;; under the mutex, then performs the external transmit after releasing it.
(setf *outstanding-sends* nil
      *arp-update-generation* 0
      *transmit-attempts* nil
      *transmit-results* '(:miss))
(transmit-or-queue-ipv4-packet :normal-destination :interface :normal-packet)
(assert-equalp (length *outstanding-sends*) 1 "ordinary ARP miss queue")
(setf *transmit-results* '(:success))
(arp-table-updated)
(assert-equalp *outstanding-sends* nil "ordinary ARP update completion")
(assert-equalp (length *transmit-attempts*) 2
               "ordinary ARP send count")
(assert-equalp mezzano.supervisor::*lock-depth* 0
               "outstanding-send lock balance")

;;; Reassembly accepts out-of-order fragments and copies their payload so the
;;; receive buffer may be reused as soon as the fragment is accepted.
(setf *ipv4-reassemblies* (make-hash-table :test 'equal)
      *ipv4-reassembly-timeout* 15
      *ipv4-reassembly-expiration-scheduled-p* nil
      mezzano.sync.dispatch::*scheduled-callbacks* nil)
(let* ((key '(#xC0000201 #xC6336401 17 99))
       (tail (octets 16 17 18 19 20 21 22 23))
       (head (octets 0 1 2 3 4 5 6 7))
       (middle (octets 8 9 10 11 12 13 14 15)))
  (multiple-value-bind (packet status)
      (accept-ipv4-fragment key tail 0 8 2 nil 100)
    (assert-equalp packet nil "out-of-order final fragment packet")
    (assert-equalp status :pending "out-of-order final fragment status"))
  (setf (aref tail 0) 255)
  (multiple-value-bind (packet status)
      (accept-ipv4-fragment key head 0 8 0 t 101)
    (assert-equalp packet nil "out-of-order first fragment packet")
    (assert-equalp status :pending "out-of-order first fragment status"))
  (multiple-value-bind (packet status)
      (accept-ipv4-fragment key middle 0 8 1 t 102)
    (assert-equalp status :complete "out-of-order completion status")
    (assert-equalp packet
                   (apply #'octets (loop :for value :from 0 :below 24
                                         :collect value))
                   "out-of-order reassembled payload"))
  (assert-equalp (hash-table-count *ipv4-reassemblies*) 0
                 "completed state removal"))

;;; Any byte overlap invalidates the entire datagram state.
(let ((key '(1 2 6 7)))
  (assert-equalp
   (nth-value 1 (accept-ipv4-fragment key (make-array 16
                                                       :element-type '(unsigned-byte 8)
                                                       :initial-element 1)
                                      0 16 0 t 200))
   :pending
   "overlap setup")
  (assert-equalp
   (nth-value 1 (accept-ipv4-fragment key (make-array 8
                                                       :element-type '(unsigned-byte 8)
                                                       :initial-element 2)
                                      0 8 1 nil 201))
   :overlap
   "overlap rejection")
  (assert-equalp (gethash key *ipv4-reassemblies*) nil
                 "overlap state removal"))

;;; Non-final fragments must be non-empty multiples of eight octets, and the
;;; reconstructed payload cannot exceed the IPv4 length limit.
(assert-equalp
 (nth-value 1 (accept-ipv4-fragment '(3 4 17 8) (octets 1 2 3)
                                    0 3 0 t 300))
 :invalid-length
 "non-aligned non-final fragment")
(assert-equalp
 (nth-value 1 (accept-ipv4-fragment '(3 4 17 9) (make-array 8
                                                           :element-type '(unsigned-byte 8))
                                    0 8 8191 nil 301))
 :too-large
 "oversized fragment range")
(assert-equalp
 (nth-value 1 (accept-ipv4-fragment '(3 4 17 10) #() 0 0 1 nil 302))
 :invalid-length
 "empty final fragment")
(assert-equalp
 (nth-value 1 (accept-ipv4-fragment '(3 4 17 11) (make-array 8
                                                           :element-type '(unsigned-byte 8))
                                    0 8 0 t 303 22))
 :invalid-header-length
 "invalid first-fragment header length")
(assert-equalp
 (nth-value 1
            (accept-ipv4-fragment
             '(3 4 17 12)
             (make-array 65476 :element-type '(unsigned-byte 8))
             0 65476 0 nil 304 60))
 :too-large
 "payload beyond first-header total-length limit")

;;; Global and per-datagram resource bounds reject input deterministically.
(setf *ipv4-reassemblies* (make-hash-table :test 'equal))
(dotimes (index +maximum-ipv4-reassemblies+)
  (setf (gethash (list :state index) *ipv4-reassemblies*)
        (make-ipv4-reassembly 350)))
(assert-equalp
 (nth-value 1 (accept-ipv4-fragment '(:new-state) (make-array 8
                                                                  :element-type '(unsigned-byte 8))
                                    0 8 0 t 350))
 :resource-limit
 "global reassembly resource limit")
(setf *ipv4-reassemblies* (make-hash-table :test 'equal))
(let* ((key '(:fragment-limit))
       (state (make-ipv4-reassembly 360)))
  (setf (ipv4-reassembly-fragments state)
        (loop :for index :below +maximum-ipv4-fragments-per-datagram+
              :collect (make-ipv4-fragment
                        (* index 8)
                        (make-array 8 :element-type '(unsigned-byte 8)))))
  (setf (gethash key *ipv4-reassemblies*) state)
  (assert-equalp
   (nth-value 1 (accept-ipv4-fragment key (make-array 8
                                                     :element-type '(unsigned-byte 8))
                                      0 8
                                      +maximum-ipv4-fragments-per-datagram+
                                      t 360))
   :resource-limit
   "per-datagram fragment resource limit")
  (assert-equalp (gethash key *ipv4-reassemblies*) nil
                 "fragment-limit state removal"))

;;; Incomplete state expires at the boundary and a late tail begins a new,
;;; still-incomplete state instead of completing with stale bytes.
(setf *ipv4-reassemblies* (make-hash-table :test 'equal))
(let* ((key '(5 6 17 10))
       (timeout-ticks (* *ipv4-reassembly-timeout*
                         internal-time-units-per-second)))
  (assert-equalp
   (nth-value 1 (accept-ipv4-fragment key (make-array 8
                                                       :element-type '(unsigned-byte 8))
                                      0 8 0 t 400))
   :pending
   "timeout setup")
  (assert-equalp (expire-ipv4-reassemblies (+ 399 timeout-ticks)) 0
                 "reassembly before timeout")
  (assert-equalp (expire-ipv4-reassemblies (+ 400 timeout-ticks)) 1
                 "reassembly at timeout")
  (assert-equalp
   (nth-value 1 (accept-ipv4-fragment key (make-array 8
                                                       :element-type '(unsigned-byte 8))
                                      0 8 1 nil (+ 401 timeout-ticks)))
   :pending
   "late final fragment after timeout"))

(assert-true mezzano.sync.dispatch::*scheduled-callbacks*
             "reassembly cleanup scheduling")

;;; Completion and rejection do not enqueue one delayed callback per datagram.
;;; At most the single global expiration handler remains pending.
(setf *ipv4-reassemblies* (make-hash-table :test 'equal)
      *ipv4-reassembly-expiration-scheduled-p* nil
      mezzano.sync.dispatch::*scheduled-callbacks* nil)
(dotimes (index 100)
  (let ((complete-key (list :complete index))
        (reject-key (list :reject index)))
    (assert-equalp
     (nth-value 1 (accept-ipv4-fragment complete-key
                                        (make-array 8
                                                    :element-type '(unsigned-byte 8))
                                        0 8 0 t (+ 1000 index)))
     :pending
     "bounded timer complete setup")
    (assert-equalp
     (nth-value 1 (accept-ipv4-fragment complete-key
                                        (make-array 8
                                                    :element-type '(unsigned-byte 8))
                                        0 8 1 nil (+ 1000 index)))
     :complete
     "bounded timer completion")
    (assert-equalp
     (nth-value 1 (accept-ipv4-fragment reject-key
                                        (make-array 8
                                                    :element-type '(unsigned-byte 8))
                                        0 8 0 t (+ 1000 index)))
     :pending
     "bounded timer reject setup")
    (assert-equalp
     (nth-value 1 (accept-ipv4-fragment reject-key
                                        (make-array 8
                                                    :element-type '(unsigned-byte 8))
                                        0 8 0 nil (+ 1000 index)))
     :overlap
     "bounded timer rejection")))
(assert-equalp (hash-table-count *ipv4-reassemblies*) 0
               "complete/reject state cleanup")
(assert-equalp (length mezzano.sync.dispatch::*scheduled-callbacks*) 1
               "bounded reassembly expiration callback count")
(let ((scheduled (pop mezzano.sync.dispatch::*scheduled-callbacks*)))
  (funcall (first scheduled)))
(assert-equalp *ipv4-reassembly-expiration-scheduled-p* nil
               "empty reassembly timer disarm")
(assert-equalp mezzano.sync.dispatch::*scheduled-callbacks* nil
               "empty reassembly timer does not reschedule")

;;; Exercise the real Ethernet IPv4 receive method to prove fragments are fed
;;; through the state machine and only one reconstructed payload reaches L4.
(defun make-host-ipv4-fragment (offset more-fragments-p payload)
  (let ((packet (make-array (+ 20 (length payload))
                            :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (setf (aref packet +ipv4-header-version-and-ihl+) #x45
          (ub16ref/be packet +ipv4-header-total-length+) (length packet)
          (ub16ref/be packet +ipv4-header-identification+) 77
          (ub16ref/be packet +ipv4-header-fragmentation-control+)
          (logior offset (if more-fragments-p
                             (ash 1 +ipv4-header-flag-more-fragments+)
                             0))
          (aref packet +ipv4-header-ttl+) 64
          (aref packet +ipv4-header-protocol+) 17
          (ub32ref/be packet +ipv4-header-source-ip+) #xC0000201
          (ub32ref/be packet +ipv4-header-destination-ip+) #xC6336401)
    (replace packet payload :start1 20)
    packet))

(setf *ipv4-reassemblies* (make-hash-table :test 'equal)
      *received-ipv4-packets* nil)
(let ((final (make-host-ipv4-fragment 1 nil (octets 8 9 10 11)))
      (first (make-host-ipv4-fragment 0 t (octets 0 1 2 3 4 5 6 7))))
  (mezzano.network.ethernet:ethernet-receive
   mezzano.network.ethernet:+ethertype-ipv4+ :host-interface
   final 0 (length final))
  (assert-equalp *received-ipv4-packets* nil
                 "incomplete fragment delivery")
  (mezzano.network.ethernet:ethernet-receive
   mezzano.network.ethernet:+ethertype-ipv4+ :host-interface
   first 0 (length first))
  (assert-equalp
   *received-ipv4-packets*
   `((17 #xC6336401 #xC0000201
      ,(apply #'octets (loop :for value :from 0 :below 12 :collect value))))
   "Ethernet receive reassembled delivery"))

(format t "IPv4 stale-state and fragment reassembly tests passed~%")
''',
    encoding="utf-8",
)
PY

"$sbcl" --noinform --non-interactive --load "$test_file"
