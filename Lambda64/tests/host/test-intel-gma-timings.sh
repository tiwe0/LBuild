#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
driver_source=${DRIVER_SOURCE:-"$repo_root/drivers/intel-gma.lisp"}
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/intel-gma.XXXXXX.lisp")
trap 'rm -f "$test_file"' EXIT

cat >"$test_file" <<'LISP'
(sb-ext:unlock-package :cl)
(defpackage :mezzano.supervisor.pci
  (:use :cl)
  (:export #:define-pci-driver #:pci-device-boot-id #:pci-io-region
           #:pci-io-region/32))
(in-package :mezzano.supervisor.pci)
(defmacro define-pci-driver (&rest arguments)
  (declare (ignore arguments))
  nil)
(defun pci-device-boot-id (device) device)
(defun pci-io-region (&rest arguments) (declare (ignore arguments)) nil)
(defun pci-io-region/32 (&rest arguments) (declare (ignore arguments)) 0)
(defun (setf pci-io-region/32) (value &rest arguments)
  (declare (ignore arguments)) value)

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:current-framebuffer #:make-mutex #:with-device-access #:with-mutex))
(in-package :mezzano.supervisor)
(defmacro with-device-access (binding &body body)
  (declare (ignore binding))
  `(progn ,@body))
(defmacro with-mutex (binding &body body)
  (declare (ignore binding))
  `(progn ,@body))
(defun make-mutex (name) name)
(defun current-framebuffer () nil)
(defun framebuffer-layout (framebuffer) (declare (ignore framebuffer)) nil)
(defun framebuffer-base-address (framebuffer) (declare (ignore framebuffer)) 0)
(defun video-set-framebuffer (&rest arguments) (declare (ignore arguments)) nil)

(defpackage :mezzano.sync (:use :cl))
(defpackage :mezzano.gui.compositor (:use :cl) (:export #:force-redisplay))
(in-package :mezzano.gui.compositor)
(defun force-redisplay (&optional force) (declare (ignore force)) nil)

(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)
(defun ub16ref/le (vector offset)
  (logior (aref vector offset) (ash (aref vector (1+ offset)) 8)))
(defun ub16ref/be (vector offset)
  (logior (ash (aref vector offset) 8) (aref vector (1+ offset))))
(defun ub32ref/le (vector offset)
  (loop for i below 4 sum (ash (aref vector (+ offset i)) (* i 8))))

(load (sb-ext:posix-getenv "DRIVER_SOURCE"))
(in-package :cl-user)

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))
(defun assert-true (value description)
  (unless value (error "~A" description)))
(defun assert-signals (thunk description)
  (handler-case (progn (funcall thunk) (error "~A: expected error" description))
    (error () t)))

(let ((sync (mezzano.driver.intel-gma::make-separate-sync-config t nil)))
  (assert-true (mezzano.driver.intel-gma::sync-config-positive-vsync-p sync)
               "positive vertical sync")
  (assert-true (not (mezzano.driver.intel-gma::sync-config-positive-hsync-p sync))
               "negative horizontal sync"))

(multiple-value-bind (n m1 m2 p1 p2 clock error)
    (mezzano.driver.intel-gma::compute-pll-parameters 25175000)
  (declare (ignore n m1 m2 p1 p2 clock))
  (assert-true (<= error mezzano.driver.intel-gma::+maximum-dot-clock-error+)
               "common PLL clock accepted"))
(assert-signals
 (lambda () (mezzano.driver.intel-gma::compute-pll-parameters 1))
 "unrepresentable PLL clock rejected")

(let* ((edid (make-array 128 :element-type '(unsigned-byte 8) :initial-element 0)))
  (loop for offset from 38 below 54 do (setf (aref edid offset) 1))
  (setf (aref edid 38) 129
        (aref edid 39) #xC0)
  (let ((modes (mezzano.driver.intel-gma::decode-edid-standard-timings edid)))
    (assert-equal 1 (length modes) "one standard timing")
    (assert-equal 1280 (mezzano.driver.intel-gma::timing-horz-active (first modes))
                  "standard timing width")
    (assert-equal 720 (mezzano.driver.intel-gma::timing-vert-active (first modes))
                  "standard timing aspect ratio")
    (assert-equal 3 (mezzano.driver.intel-gma::timing-vert-sync (first modes))
                  "GTF fixed vertical sync width")
    (assert-true (> (mezzano.driver.intel-gma::timing-pixel-clock (first modes)) 0)
                 "GTF pixel clock")))

(let ((edid (make-array 128 :element-type '(unsigned-byte 8) :initial-element 0)))
  (setf (aref edid 35) (ash 1 5)
        (aref edid 36) (ash 1 7))
  (let ((modes (mezzano.driver.intel-gma::decode-edid-established-timings edid)))
    (assert-equal 2 (length modes) "selected established timings")
    (assert-true (find 25175000 modes
                       :key #'mezzano.driver.intel-gma::timing-pixel-clock)
                 "640x480@60 exact DMT timing")
    (assert-true (find 50000000 modes
                       :key #'mezzano.driver.intel-gma::timing-pixel-clock)
                 "800x600@72 exact DMT timing")))
(let ((edid (make-array 128 :element-type '(unsigned-byte 8) :initial-element 0)))
  (setf (aref edid 35) #xFF
        (aref edid 36) #xFF
        (aref edid 37) #x80)
  (assert-equal 17
                (length
                 (mezzano.driver.intel-gma::decode-edid-established-timings
                  edid))
                "all established timing bits decoded"))

(multiple-value-bind (width height aspect)
    (mezzano.driver.intel-gma::decode-edid-screen-geometry 121 0)
  (assert-equal nil width "aspect-only width")
  (assert-equal nil height "aspect-only height")
  (assert-equal 11/5 aspect "landscape aspect ratio"))
(multiple-value-bind (width height aspect)
    (mezzano.driver.intel-gma::decode-edid-screen-geometry 0 101)
  (assert-equal nil width "portrait aspect-only width")
  (assert-equal nil height "portrait aspect-only height")
  (assert-equal 1/2 aspect "portrait aspect ratio"))

(dolist (entry '((#b010 . :field-sequential-right)
                 (#b011 . :field-sequential-left)
                 (#b100 . :2-way-interleaved-right)
                 (#b101 . :2-way-interleaved-left)
                 (#b110 . :4-way-interleaved)
                 (#b111 . :side-by-side-interleaved)))
  (let ((code (car entry)))
    (assert-equal (cdr entry)
                  (mezzano.driver.intel-gma::decode-edid-stereo
                   (logior (ash (ldb (byte 2 1) code) 5)
                           (ldb (byte 1 0) code)))
                  "EDID stereo code")))

(let ((samples '(0 1 2 0 1 0)) (calls 0))
  (mezzano.driver.intel-gma::wait-for-vblank-transitions
   (lambda () (prog1 (pop samples) (incf calls))) 2 6)
  (assert-equal 6 calls "two scanline wraps observed"))

(let* ((timing (mezzano.driver.intel-gma::make-timing
                :sync-config
                (mezzano.driver.intel-gma::make-separate-sync-config nil t)))
       (adpa (mezzano.driver.intel-gma::adpa-with-timing-sync 0 timing)))
  (assert-equal 0 (ldb mezzano.driver.intel-gma::+adpa-vsync-polarity+ adpa)
                "ADPA negative vertical polarity")
  (assert-equal 1 (ldb mezzano.driver.intel-gma::+adpa-hsync-polarity+ adpa)
                "ADPA positive horizontal polarity"))

(let* ((timing (mezzano.driver.intel-gma::make-timing :interlaced t))
       (pipeconf (mezzano.driver.intel-gma::pipeconf-with-timing-scan
                  0 timing)))
  (assert-equal mezzano.driver.intel-gma::+pipeconf-interlace-field-indication+
                (ldb mezzano.driver.intel-gma::+pipeconf-interlace+ pipeconf)
                "PIPECONF interlace programming"))

(assert-signals
 (lambda ()
   (mezzano.driver.intel-gma::validate-gma-timing
    (mezzano.driver.intel-gma::make-timing
     :sync-config (mezzano.driver.intel-gma::make-separate-sync-config t t)
     :stereo :side-by-side-interleaved)))
 "unsupported stereo rejected")

(cl:format t "intel GMA timing semantics passed~%")
LISP

DRIVER_SOURCE="$driver_source" "$sbcl" --noinform --disable-debugger --script "$test_file"
