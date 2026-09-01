#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-compositor-resize-origin.XXXXXX.lisp")
source_excerpt=$(mktemp "${TMPDIR:-/tmp}/lambda64-compositor-resize-origin-source.XXXXXX.lisp")
trap 'rm -f "$test_file" "$source_excerpt"' EXIT

sed -n '/^(defun updated-window-origin-for-resize /,/^(defun resize-window /p' \
  "$repo_root/gui/compositor.lisp" | sed '$d' >"$source_excerpt"

cat >"$test_file" <<'LISP'
(defpackage :mezzano.gui
  (:use :cl)
  (:export #:make-colour
           #:make-surface
           #:make-surface-from-array
           #:surface-format
           #:surface-height
           #:surface-width))

(in-package :mezzano.gui)

(defstruct (host-surface (:constructor make-host-surface (width height format)))
  width
  height
  format)

(defun surface-width (surface)
  (host-surface-width surface))

(defun surface-height (surface)
  (host-surface-height surface))

(defun surface-format (surface)
  (host-surface-format surface))

(defpackage :mezzano.sync
  (:use :cl)
  (:export #:mailbox-receive #:mailbox-send #:make-mailbox #:wait-for-objects))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:current-framebuffer
           #:current-thread
           #:establish-thread-foothold
           #:framebuffer-blit
           #:framebuffer-boot-id
           #:framebuffer-height
           #:framebuffer-width
           #:make-thread
           #:with-timer))

(defpackage :mezzano.gui.basic-repl
  (:use :cl)
  (:export #:spawn))

(defpackage :mezzano.gui.fancy-repl
  (:use :cl)
  (:export #:spawn))

(defpackage :mezzano.gui.compositor
  (:use :cl)
  (:export #:close-window #:make-window))

(in-package :mezzano.gui.compositor)

(defclass window ()
  ((%x :initarg :x :accessor window-x)
   (%y :initarg :y :accessor window-y)
   (%buffer :initarg :buffer :reader window-buffer)
   (%grabp :initarg :grabp :accessor grabp)
   (%grab-x1 :initarg :grab-x1 :accessor grab-x1)
   (%grab-y1 :initarg :grab-y1 :accessor grab-y1)
   (%grab-x2 :initarg :grab-x2 :accessor grab-x2)
   (%grab-y2 :initarg :grab-y2 :accessor grab-y2))
  (:default-initargs :grabp nil))

(defclass event ()
  ((%window :initarg :window :reader window)))

(defclass resize-event (event)
  ((%origin :initarg :origin :reader resize-origin)
   (%new-fb :initarg :new-fb :reader resize-new-fb)))

(defgeneric width (thing))
(defgeneric height (thing))
(defgeneric process-event (event))

(defmethod width ((window window))
  (mezzano.gui:surface-width (window-buffer window)))

(defmethod height ((window window))
  (mezzano.gui:surface-height (window-buffer window)))

(defvar *drag-window* nil)
(defvar *drag-x-origin* nil)
(defvar *drag-y-origin* nil)

(defun clamp (value minimum maximum)
  (max minimum (min value maximum)))

(defun expand-clip-rectangle-by-window (window)
  (declare (ignore window)))

(defvar *send-event-hook* nil)

(defun send-event (window event)
  (when *send-event-hook*
    (funcall *send-event-hook* window event)))

(defun update-mouse-cursor ())

(defun compositor-form-p (form)
  (or (and (consp form)
           (eq (first form) 'defun)
           (member (second form)
                   '(updated-window-origin-for-resize
                     window-grab-offset-for-resize
                     updated-window-grab-for-resize)))
      (and (consp form)
           (eq (first form) 'defmethod)
           (eq (second form) 'process-event)
           (equal (second (first (third form))) 'resize-event))))

(let ((*package* (find-package :mezzano.gui.compositor)))
  (with-open-file (stream (or (sb-ext:posix-getenv "COMPOSITOR_SOURCE_EXCERPT")
                              (error "COMPOSITOR_SOURCE_EXCERPT is not set")))
    (loop for form = (read stream nil nil)
          while form
          when (compositor-form-p form)
            do (eval form))))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A failed: expected ~S, got ~S" description expected actual)))

(defun surface (width height)
  (mezzano.gui::make-host-surface width height :argb32))

(defun make-grabbed-window ()
  (make-instance 'window
                 :x 100 :y 200
                 :buffer (surface 100 80)
                 :grabp t
                 :grab-x1 10 :grab-y1 20
                 :grab-x2 90 :grab-y2 70))

(defun resize-and-snapshot (origin width height &optional (window (make-grabbed-window)))
  (process-event (make-instance 'resize-event
                                :window window
                                :origin origin
                                :new-fb (surface width height)))
  (list (window-x window) (window-y window)
        (and (slot-boundp window '%grab-x1) (grab-x1 window))
        (and (slot-boundp window '%grab-y1) (grab-y1 window))
        (and (slot-boundp window '%grab-x2) (grab-x2 window))
        (and (slot-boundp window '%grab-y2) (grab-y2 window))))

;; Growing from each corner keeps the grab rectangle fixed relative to the
;; stationary window edges. The changed axes therefore receive the inverse
;; window-origin displacement.
(assert-equal '(100 200 10 20 90 70)
              (resize-and-snapshot :top-left 120 100)
              "top-left anchored resize")
(assert-equal '(80 200 30 20 110 70)
              (resize-and-snapshot :top-right 120 100)
              "top-right anchored resize")
(assert-equal '(100 180 10 40 90 90)
              (resize-and-snapshot :bottom-left 120 100)
              "bottom-left anchored resize")
(assert-equal '(80 180 30 40 110 90)
              (resize-and-snapshot :bottom-right 120 100)
              "bottom-right anchored resize")

;; Midpoint resizing moves each window edge by half the size delta and must
;; translate both grab axes by the inverse midpoint displacement.
(assert-equal '(90 190 20 30 100 80)
              (resize-and-snapshot :midpoint 120 100)
              "midpoint anchored resize")

;; Shrinking to the minimum supported geometry clamps both translated corners
;; independently while preserving their ordering.
(let ((window (make-instance 'window
                             :x 100 :y 200
                             :buffer (surface 100 80)
                             :grabp t
                             :grab-x1 90 :grab-y1 70
                             :grab-x2 100 :grab-y2 80)))
  (assert-equal '(199 279 0 0 1 1)
                (resize-and-snapshot :bottom-right 1 1 window)
                "minimum-size clamp"))

;; An inactive grab may leave its coordinate slots unbound. Resizing must not
;; read or initialize them.
(let ((window (make-instance 'window
                             :x 100 :y 200
                             :buffer (surface 100 80)
                             :grabp nil)))
  (assert-equal '(80 180 nil nil nil nil)
                (resize-and-snapshot :bottom-right 120 100 window)
                "no-grab resize")
  (dolist (slot '(%grab-x1 %grab-y1 %grab-x2 %grab-y2))
    (when (slot-boundp window slot)
      (error "No-grab resize unexpectedly bound ~S" slot))))

;; SEND-EVENT is non-blocking in production, so a client may update its grab
;; region while the compositor is completing a resize. Preserve the old order:
;; translate the current post-delivery grab rather than restoring a stale,
;; pre-delivery snapshot.
(let ((*send-event-hook*
        (lambda (window event)
          (declare (ignore event))
          (setf (grabp window) t
                (grab-x1 window) 1
                (grab-y1 window) 2
                (grab-x2 window) 3
                (grab-y2 window) 4))))
  (assert-equal '(80 180 21 22 23 24)
                (resize-and-snapshot :bottom-right 120 100)
                "post-delivery grab update"))

(format t "Compositor resize-origin grab contract passed~%")
LISP

COMPOSITOR_SOURCE_EXCERPT="$source_excerpt" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
