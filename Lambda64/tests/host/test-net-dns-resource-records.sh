#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${DNS_SOURCE:-"$repo_root/net/dns.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-net-dns-resource-records.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(defpackage :mezzano.internals
  (:use :cl)
  (:nicknames :sys.int)
  (:export #:ub16ref/be #:ub32ref/be))
(in-package :mezzano.internals)

(defun ub16ref/be (vector offset)
  (logior (ash (aref vector offset) 8)
          (aref vector (+ offset 1))))

(defun (setf ub16ref/be) (value vector offset)
  (check-type value (unsigned-byte 16))
  (setf (aref vector offset) (ldb (byte 8 8) value)
        (aref vector (+ offset 1)) (ldb (byte 8 0) value))
  value)

(defun ub32ref/be (vector offset)
  (logior (ash (aref vector offset) 24)
          (ash (aref vector (+ offset 1)) 16)
          (ash (aref vector (+ offset 2)) 8)
          (aref vector (+ offset 3))))

(defun (setf ub32ref/be) (value vector offset)
  (check-type value (unsigned-byte 32))
  (setf (aref vector offset) (ldb (byte 8 24) value)
        (aref vector (+ offset 1)) (ldb (byte 8 16) value)
        (aref vector (+ offset 2)) (ldb (byte 8 8) value)
        (aref vector (+ offset 3)) (ldb (byte 8 0) value))
  value)

(defun explode (delimiter string start end)
  (let ((end (or end (length string)))
        (result '())
        (part-start start))
    (loop :for index :from start :below end
          :when (char= (char string index) delimiter)
            :do (push (subseq string part-start index) result)
                (setf part-start (1+ index)))
    (nreverse (cons (subseq string part-start end) result))))

(defpackage :mezzano.network (:use :cl) (:export #:send #:receive))
(defpackage :mezzano.network.ip
  (:use :cl)
  (:export #:make-ipv4-address #:address-equal))
(defpackage :mezzano.network.udp
  (:use :cl)
  (:export #:with-udp-connection))
(defmacro mezzano.network.udp:with-udp-connection ((connection server port) &body body)
  (declare (ignore server port))
  `(let ((,connection nil)) ,@body))
(defun mezzano.network.ip:make-ipv4-address (address) address)
(defun mezzano.network.ip:address-equal (left right) (equal left right))
(defun mezzano.network:send (&rest arguments) (declare (ignore arguments)))
(defun mezzano.network:receive (&rest arguments) (declare (ignore arguments)))

(defpackage :mezzano.network.dns
  (:use :cl)
  (:import-from :mezzano.internals #:ub16ref/be #:ub32ref/be)
  (:local-nicknames (:net :mezzano.network)
                    (:sys.int :mezzano.internals)))
LISP

cat "$source_file" >>"$test_file"

cat >>"$test_file" <<'LISP'
(in-package :mezzano.network.dns)

(defun assert-equalp (actual expected description)
  (unless (equalp actual expected)
    (error "~A produced ~S, expected ~S" description actual expected)))

(defun assert-signals (condition thunk description)
  (let ((caught nil))
    (handler-case (funcall thunk)
      (condition (value)
        (setf caught value)))
    (unless caught
      (error "~A did not signal ~S" description condition))
    (unless (typep caught condition)
      (error "~A signalled ~S, expected ~S" description caught condition))))

;; Lock the byte-level header, owner-name, fixed RR fields, RDLENGTH, and IPv4
;; order independently of the decoder used by the larger round-trip fixture.
(assert-equalp
 (build-dns-packet 1 0
                   :questions '(("A" :a :in))
                   :answers '(("A" :a :in 2 #xC0000201)))
 #(0 1 0 0 0 1 0 1 0 0 0 0
   1 97 0 0 1 0 1
   1 97 0 0 1 0 1 0 0 0 2 0 4 192 0 2 1)
 "simple A response wire format")

(let* ((unknown-type '(:unknown-type 65000))
       (unknown-class '(:unknown-class 65001))
       (raw #(1 2 3 4 5))
       (questions '(("Example.COM." :a :in)))
       (answers `(("example.com" :a :in 300 #xC0000201)
                  ("alias.example.com" :cname :in 301 "example.com")
                  ("example.com" :mx :in 302 10 "mail.example.com")
                  ("example.com" :soa :in 303 "ns.example.com" "hostmaster.example.com"
                   7 8 9 10 11)
                  ("opaque.example.com" ,unknown-type :in 304 ,raw)
                  ("class.example.com" :txt ,unknown-class 305 ,raw)))
       (authority '(("example.com" :ns :in 400 "ns.example.com")))
       (additional `(("ns.example.com" :aaaa :in 500
                      ,#(32 1 13 184 0 0 0 0 0 0 0 0 0 0 0 1))))
       (packet (build-dns-packet #x1234 #x8180
                                 :questions questions
                                 :answers answers
                                 :authority-rrs authority
                                 :additional-rrs additional)))
  (multiple-value-bind (id flags decoded-questions decoded-answers
                        decoded-authority decoded-additional)
      (decode-dns-packet packet)
    (assert-equalp id #x1234 "transaction ID")
    (assert-equalp flags #x8180 "flags")
    (assert-equalp decoded-questions '(("example.com" :a :in)) "questions")
    (assert-equalp decoded-answers answers "answer resource records")
    (assert-equalp decoded-authority authority "authority resource records")
    (assert-equalp decoded-additional additional "additional resource records")))

;; RDATA arity and width errors must fail before emitting a malformed packet.
(assert-signals 'error
                (lambda ()
                  (build-dns-packet 1 0 :answers '(("x" :a :in 1))))
                "missing A address")
(assert-signals 'type-error
                (lambda ()
                  (build-dns-packet 1 0 :answers '(("x" :a :in 1 #x100000000))))
                "oversized A address")
(assert-signals 'error
                (lambda ()
                  (build-dns-packet 1 0 :answers '(("x" :aaaa :in 1 #(0 1)))))
                "short AAAA address")

;; Classic DNS/UDP packets are capped at 512 octets. A record that cannot fit
;; must be rejected rather than returning a truncated or corrupt packet.
(let ((packet (build-dns-packet
               1 0
               :answers
               `(("x" :txt :in 1
                  ,(make-array 487
                               :element-type '(unsigned-byte 8)
                               :initial-element 65))))))
  (assert-equalp (length packet) 512 "maximum-size DNS packet"))
(assert-signals 'error
                (lambda ()
                  (build-dns-packet 1 0
                                    :answers
                                    `(("x" :txt :in 1
                                       ,(make-array 488
                                                    :element-type '(unsigned-byte 8)
                                                    :initial-element 65)))))
                "oversized DNS packet")

;; The encoded wire name, not merely the source string, is limited to 255
;; octets. Four 63-octet labels plus their leaders and root byte are invalid.
(assert-signals 'error
                (lambda ()
                  (build-dns-packet
                   1 0
                   :questions
                   `((,(format nil "~A.~A.~A.~A"
                               (make-string 63 :initial-element #\a)
                               (make-string 63 :initial-element #\b)
                               (make-string 63 :initial-element #\c)
                               (make-string 63 :initial-element #\d))
                      :a :in))))
                "overlong encoded DNS name")

(format t "DNS resource-record packet tests passed~%")
LISP

"$sbcl" --noinform --non-interactive --load "$test_file"
