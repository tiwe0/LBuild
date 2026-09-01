#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
sbcl=${SBCL:-sbcl}
test_file=$(mktemp "${TMPDIR:-/tmp}/lambda64-compositor-async-window-query.XXXXXX.lisp")
source_excerpt=$(mktemp "${TMPDIR:-/tmp}/lambda64-compositor-async-window-query-source.XXXXXX.lisp")
med_excerpt=$(mktemp "${TMPDIR:-/tmp}/lambda64-med-async-window-query-source.XXXXXX.lisp")
trap 'rm -f "$test_file" "$source_excerpt" "$med_excerpt"' EXIT

awk '
  $0 == "(defun screensaver-running-p ()" {
    print
    getline
    print
  }
  $0 == ";;;; Window creation event." { copying_windows = 1 }
  $0 == ";;;; Window activation changed." { copying_windows = 0 }
  $0 == ";; FIXME: This really shouldn\047t be synchronous." ||
  $0 == ";;;; Asynchronous window queries." { copying_query = 1 }
  $0 == ";;;; Main body of the compositor." { copying_query = 0 }
  copying_windows || copying_query { print }
' "$repo_root/gui/compositor.lisp" >"$source_excerpt"

awk '
  $0 == "(defun med-ed-hook (&key initial-pathname initial-position)" { copying = 1 }
  copying && /^\(when \(not mezzano.extensions:/ { copying = 0 }
  copying { print }
' "$repo_root/../home/med/main.lisp" >"$med_excerpt"

if [[ ! -s "$source_excerpt" || ! -s "$med_excerpt" ]]; then
  echo "Could not extract the compositor or MED window-query implementation" >&2
  exit 1
fi

cat >"$test_file" <<'LISP'
(defpackage :mezzano.sync
  (:use :cl)
  (:export #:mailbox-receive #:mailbox-send #:make-mailbox))

(in-package :mezzano.sync)

(defstruct (host-mailbox (:constructor %make-host-mailbox (name)))
  name
  (items '()))

(defvar *mailbox-send-wait-values* '())

(defun make-mailbox (&key name capacity)
  (declare (ignore capacity))
  (%make-host-mailbox name))

(defun mailbox-send (value mailbox &key (wait-p t))
  (push wait-p *mailbox-send-wait-values*)
  (setf (host-mailbox-items mailbox)
        (nconc (host-mailbox-items mailbox) (list value)))
  t)

(defun mailbox-receive (mailbox &key (wait-p t))
  (loop
    (when (host-mailbox-items mailbox)
      (return (values (pop (host-mailbox-items mailbox)) t)))
    (unless wait-p
      (return (values nil nil)))
    (let ((processor (find-symbol "PROCESS-NEXT-EVENT"
                                  :mezzano.gui.compositor)))
      (unless (and processor (fboundp processor))
        (error "No host compositor is available to service the mailbox"))
      (funcall processor))))

(defpackage :mezzano.gui
  (:use :cl)
  (:export #:make-surface))

(in-package :mezzano.gui)

(defun make-surface (width height)
  (list width height))

(defpackage :mezzano.supervisor
  (:use :cl)
  (:export #:current-thread
           #:fifo-push
           #:framebuffer-height
           #:framebuffer-width))

(in-package :mezzano.supervisor)

(defvar *fifo-pushes* '())

(defun current-thread ()
  :host-thread)

(defun framebuffer-width (screen)
  (declare (ignore screen))
  1024)

(defun framebuffer-height (screen)
  (declare (ignore screen))
  768)

(defun fifo-push (value fifo &optional (wait-p t))
  (push (list value fifo wait-p) *fifo-pushes*)
  t)

(defpackage :mezzano.gui.compositor
  (:use :cl)
  (:export #:close-window #:get-window-by-kind #:make-window))

(in-package :mezzano.gui.compositor)

(defclass window ()
  ((%kind :initarg :kind :reader kind)
   (%id :initarg :id :reader window-id)
   (%x :initarg :x :accessor window-x)
   (%y :initarg :y :accessor window-y)
   (%width :initarg :width :reader width)
   (%height :initarg :height :reader height)
   (%layer :initarg :layer :reader layer)
   (%fifo :initarg :fifo :reader fifo))
  (:default-initargs :x 0 :y 0 :width 80 :height 60 :layer nil :fifo nil))

(defclass event ()
  ((%window :initarg :window :reader window))
  (:default-initargs :window nil))

(defgeneric process-event (event))

(defclass window-activation-event (event)
  ((%state :initarg :state :reader state)))

(defclass mouse-event (event)
  ((%button-state :initarg :button-state)
   (%button-change :initarg :button-change)
   (%x-position :initarg :x-position)
   (%y-position :initarg :y-position)
   (%x-motion :initarg :x-motion)
   (%y-motion :initarg :y-motion)))

(defvar *window-list* '())
(defvar *submitted-events* '())
(defvar *kind-read-count* 0)
(defvar *compositor-debug-enable* nil)
(defvar *main-screen* :host-screen)
(defvar *active-window* nil)
(defvar *drag-window* nil)
(defvar *m-tab-active* nil)
(defvar *m-tab-list* '())
(defvar *mouse-x* 0)
(defvar *mouse-y* 0)
(defvar *mouse-buttons* 0)

(defmethod kind :around ((window window))
  (incf *kind-read-count*)
  (call-next-method))

(defun submit-compositor-event (event)
  (setf *submitted-events* (nconc *submitted-events* (list event)))
  (values))

(defun send-event (window event)
  (declare (ignore window event)))

(defun expand-clip-rectangle-by-window (window)
  (declare (ignore window)))

(defun allow-m-tab (window)
  (declare (ignore window))
  nil)

(defun window-at-point (x y)
  (declare (ignore x y))
  nil)

(defun screen-to-window-coordinates (window x y)
  (values (- x (window-x window))
          (- y (window-y window))))

(defun process-next-event ()
  (unless *submitted-events*
    (error "No compositor event is pending"))
  (process-event (pop *submitted-events*)))

(defun assert-eq (expected actual description)
  (unless (eq expected actual)
    (error "~A failed: expected ~S, got ~S" description expected actual)))

(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A failed: expected ~S, got ~S" description expected actual)))

(let ((*package* (find-package :mezzano.gui.compositor)))
  (with-open-file (stream (or (sb-ext:posix-getenv "COMPOSITOR_QUERY_SOURCE")
                              (error "COMPOSITOR_QUERY_SOURCE is not set")))
    (loop for form = (read stream nil nil)
          while form
          do (eval form))))

(defun receive-result (mailbox)
  (multiple-value-bind (value validp)
      (mezzano.sync:mailbox-receive mailbox :wait-p nil)
    (unless validp
      (error "Expected an asynchronous query result"))
    value))

(let* ((first-target (make-instance 'window :kind :target :id :front))
       (other (make-instance 'window :kind :other :id :other))
       (second-target (make-instance 'window :kind :target :id :back)))
  (setf *window-list* (list first-target other second-target)
        *submitted-events* '()
        *kind-read-count* 0
        mezzano.sync::*mailbox-send-wait-values* '())
  (let ((result-mailbox (get-window-by-kind :target)))
    ;; The public call only submits work. It must neither traverse compositor
    ;; state nor synchronously expose a window.
    (assert-equal 0 *kind-read-count* "query submission state isolation")
    (assert-equal 1 (length *submitted-events*) "one queued query")
    (multiple-value-bind (value validp)
        (mezzano.sync:mailbox-receive result-mailbox :wait-p nil)
      (declare (ignore value))
      (assert-eq nil validp "result unavailable before event processing"))
    (process-next-event)
    (assert-eq first-target (receive-result result-mailbox)
               "frontmost matching window")
    (assert-equal '(nil) mezzano.sync::*mailbox-send-wait-values*
                  "nonblocking compositor reply")))

;; A missing kind still produces one valid NIL result, rather than leaving the
;; receiver unable to distinguish absence from an unprocessed query.
(setf *submitted-events* '()
      mezzano.sync::*mailbox-send-wait-values* '())
(let ((result-mailbox (get-window-by-kind :missing)))
  (process-next-event)
  (multiple-value-bind (value validp)
      (mezzano.sync:mailbox-receive result-mailbox :wait-p nil)
    (assert-eq t validp "missing result delivery")
    (assert-eq nil value "missing result value"))
  (multiple-value-bind (value validp)
      (mezzano.sync:mailbox-receive result-mailbox :wait-p nil)
    (declare (ignore value))
    (assert-eq nil validp "exactly one result")))

;; Each request owns a separate response mailbox.
(setf *submitted-events* '())
(let ((first (get-window-by-kind :target))
      (second (get-window-by-kind :target)))
  (when (eq first second)
    (error "Queries unexpectedly shared one result mailbox")))

;; Use the production create/close event classes and methods to prove ordering.
(defun reset-compositor-fixture ()
  (setf *window-list* '()
        *submitted-events* '()
        *active-window* nil
        *drag-window* nil
        *m-tab-list* '()
        *kind-read-count* 0))

(defun submit-create (window &optional (initial-z-order :top))
  (submit-compositor-event
   (make-instance 'window-create-event
                  :window window
                  :initial-z-order initial-z-order)))

(let ((first (make-instance 'window :kind :ordered :id :first))
      (frontmost (make-instance 'window :kind :ordered :id :frontmost)))
  (reset-compositor-fixture)
  (submit-create first)
  (submit-create frontmost)
  (let ((result-mailbox (get-window-by-kind :ordered)))
    (assert-equal 0 *kind-read-count* "create-query remains deferred")
    (process-next-event)
    (process-next-event)
    (process-next-event)
    (assert-eq frontmost (receive-result result-mailbox)
               "create then query returns frontmost window"))

  ;; A query queued before close snapshots the pre-close ordering.
  (let ((result-mailbox (get-window-by-kind :ordered)))
    (close-window frontmost)
    (process-next-event)
    (process-next-event)
    (assert-eq frontmost (receive-result result-mailbox)
               "query before close returns closing window"))

  ;; A close queued before the query is visible and leaves no matching window
  ;; after the remaining match is also closed.
  (close-window first)
  (let ((result-mailbox (get-window-by-kind :ordered)))
    (process-next-event)
    (process-next-event)
    (multiple-value-bind (value validp)
        (mezzano.sync:mailbox-receive result-mailbox :wait-p nil)
      (assert-eq t validp "close-query missing result delivery")
      (assert-eq nil value "close then query returns NIL"))))

;; The screensaver checks run inside the compositor loop. They use the private
;; direct helper instead of enqueuing a query that the same thread would have to
;; process later.
(let ((screensaver (make-instance 'window :kind :screensaver :id :screensaver)))
  (setf *window-list* (list screensaver)
        *submitted-events* '()
        *kind-read-count* 0)
  (assert-eq screensaver (screensaver-running-p)
             "internal screensaver lookup")
  (assert-equal '() *submitted-events*
                "internal lookup does not self-enqueue"))

;; Load the real MED hook and ensure it receives the asynchronous result before
;; deciding whether to send an open request or spawn a new editor.
(defpackage :med
  (:use :cl))

(in-package :med)

(defclass open-file-request ()
  ((%path :initarg :path :reader request-path)
   (%position :initarg :position :reader request-position)))

(defvar *spawn-calls* '())

(defun spawn (&key initial-file initial-position)
  (push (list initial-file initial-position) *spawn-calls*))

(let ((*package* (find-package :med)))
  (with-open-file (stream (or (sb-ext:posix-getenv "MED_HOOK_SOURCE")
                              (error "MED_HOOK_SOURCE is not set")))
    (eval (read stream))))

(let ((editor (make-instance 'mezzano.gui.compositor::window
                             :kind :editor :id :editor :fifo :editor-fifo)))
  (mezzano.gui.compositor::reset-compositor-fixture)
  (mezzano.gui.compositor::submit-create editor)
  (mezzano.gui.compositor::process-next-event)
  (setf mezzano.supervisor::*fifo-pushes* '()
        *spawn-calls* '())
  (med-ed-hook :initial-pathname #P"example.lisp" :initial-position 17)
  (mezzano.gui.compositor::assert-equal
   '() *spawn-calls* "existing editor does not spawn")
  (mezzano.gui.compositor::assert-equal
   1 (length mezzano.supervisor::*fifo-pushes*)
   "existing editor receives one open request")
  (let* ((push (first mezzano.supervisor::*fifo-pushes*))
         (request (first push)))
    (mezzano.gui.compositor::assert-eq
     :editor-fifo (second push) "existing editor FIFO")
    (mezzano.gui.compositor::assert-equal
     #P"example.lisp" (request-path request) "MED request path")
    (mezzano.gui.compositor::assert-equal
     17 (request-position request) "MED request position"))

  (mezzano.gui.compositor:close-window editor)
  (mezzano.gui.compositor::process-next-event)
  (setf *spawn-calls* '())
  (med-ed-hook :initial-pathname #P"new.lisp" :initial-position 9)
  (mezzano.gui.compositor::assert-equal
   (list (list #P"new.lisp" 9)) *spawn-calls*
   "missing editor spawns with request state"))

(format t "Compositor asynchronous window-query contract passed~%")
LISP

COMPOSITOR_QUERY_SOURCE="$source_excerpt" \
MED_HOOK_SOURCE="$med_excerpt" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"
