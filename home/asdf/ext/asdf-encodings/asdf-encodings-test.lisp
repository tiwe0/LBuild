#+xcvb (module (:depends-on ("asdf-encodings" (:asdf "hu.dwim.stefil"))))

(defpackage :asdf-encodings-test
  (:use :cl :fare-utils :asdf-encodings :hu.dwim.stefil))

(in-package :asdf-encodings-test)

(declaim (optimize (speed 1) (debug 3) (space 3)))

;;; Testing the asdf-encodings library.

(defsuite* (test-suite
            :in root-suite
            :documentation "Testing reader interception"))

;;; TODO: actually test stuff
