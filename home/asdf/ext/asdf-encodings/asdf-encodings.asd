;;; -*- Mode: Lisp ; Base: 10 ; Syntax: ANSI-Common-Lisp -*-

(defsystem "asdf-encodings"
  :defsystem-depends-on ((:version "asdf" "3.0"))
  :description "Portable interface to character encodings and your implementation's external-format"
  :author "Francois-Rene Rideau"
  :components
  ((:file "pkgdcl")
   (:file "encodings" :depends-on ("pkgdcl"))
   (:file "autodetect" :depends-on ("pkgdcl"))
   (:file "asdf-support" :depends-on ("pkgdcl"))
   (:file "initialization" :depends-on ("encodings" "autodetect" "asdf-support")))
  :in-order-to ((test-op (test-op "asdf-encodings/test"))))


(defsystem "asdf-encodings/test"
  :depends-on (:asdf-encodings :fare-utils :hu.dwim.stefil)
  :description "Tests for asdf-encodings"
  :author "Francois-Rene Rideau"
  :components ((:file "asdf-encodings-test"))
  :perform (test-op (o c) (call-function "asdf-encodings-test::test-suite")))
