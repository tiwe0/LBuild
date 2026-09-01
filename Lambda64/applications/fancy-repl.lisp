;;;; A Lisp REPL with line-editing, history and completion.

(defpackage :mezzano.gui.fancy-repl
  (:use :cl :mezzano.gui.font)
  (:export #:spawn))

(in-package :mezzano.gui.fancy-repl)

(defun %completion-character-kind (character syntax-type-function macro-character-function)
  (let ((syntax (funcall syntax-type-function character)))
    (cond ((eql syntax :whitespace) :whitespace)
          ((eql syntax :single-escape) :single-escape)
          ((eql syntax :multiple-escape) :multiple-escape)
          (t
           (multiple-value-bind (function non-terminating-p)
               (funcall macro-character-function character)
             (if (and function (not non-terminating-p))
                 :terminating-macro
                 :constituent))))))

(defun %completion-token-bounds
    (buffer cursor-position
     &optional
       (syntax-type-function #'mezzano.internals::readtable-syntax-type)
       (macro-character-function #'get-macro-character))
  "Return the reader-token bounds at CURSOR-POSITION, or NIL in text/comment syntax."
  (check-type buffer string)
  (check-type cursor-position (integer 0))
  (when (> cursor-position (length buffer))
    (error "Cursor position ~D is beyond a buffer of length ~D."
           cursor-position (length buffer)))
  (labels ((kind (character)
             (%completion-character-kind character
                                         syntax-type-function
                                         macro-character-function))
           (scan-string (position)
             (let ((start position)
                   (closedp nil))
               (incf position)
               (loop :while (< position (length buffer))
                     :for character = (char buffer position)
                     :for character-kind = (kind character)
                     :do (cond ((eql character-kind :single-escape)
                                (incf position (min 2 (- (length buffer) position))))
                               ((and (char= character #\")
                                     (eql character-kind :terminating-macro))
                                (incf position)
                                (setf closedp t)
                                (return))
                               (t (incf position))))
               (values position
                       (and (> cursor-position start)
                            (if closedp
                                (< cursor-position position)
                                (<= cursor-position position))))))
           (scan-comment (position)
             (let ((start position))
               (incf position)
               (loop :while (< position (length buffer))
                     :until (char= (char buffer position) #\Newline)
                     :do (incf position))
               (values position
                       (and (> cursor-position start)
                            (<= cursor-position position)))))
           (scan-token (position)
             (let ((start position)
                   (multiple-escape-p nil))
               (loop :while (< position (length buffer))
                     :for character-kind = (kind (char buffer position))
                     :do (cond ((eql character-kind :single-escape)
                                (incf position (min 2 (- (length buffer) position))))
                               ((eql character-kind :multiple-escape)
                                (setf multiple-escape-p (not multiple-escape-p))
                                (incf position))
                               (multiple-escape-p
                                (incf position))
                               ((member character-kind '(:whitespace :terminating-macro))
                                (return))
                               (t (incf position))))
               (values start position))))
    (let ((position 0))
      (loop :while (< position (length buffer))
            :for character = (char buffer position)
            :for character-kind = (kind character)
            :do (cond ((eql character-kind :whitespace)
                       (incf position))
                      ((eql character-kind :terminating-macro)
                       (cond ((char= character #\")
                              (multiple-value-bind (next-position contains-cursor-p)
                                  (scan-string position)
                                (when contains-cursor-p
                                  (return-from %completion-token-bounds nil))
                                (setf position next-position)))
                             ((char= character #\;)
                              (multiple-value-bind (next-position contains-cursor-p)
                                  (scan-comment position)
                                (when contains-cursor-p
                                  (return-from %completion-token-bounds nil))
                                (setf position next-position)))
                             (t (incf position))))
                      (t
                       (multiple-value-bind (start end) (scan-token position)
                         (when (and (>= cursor-position start)
                                    (<= cursor-position end))
                           (return-from %completion-token-bounds
                             (values start end)))
                         (setf position end)))))
      (values cursor-position cursor-position))))

(defun %completion-package-marker
    (buffer start end
     &optional (syntax-type-function #'mezzano.internals::readtable-syntax-type))
  "Return the first unescaped package marker between START and END."
  (let ((position start)
        (multiple-escape-p nil))
    (loop :while (< position end)
          :for character = (char buffer position)
          :for syntax = (funcall syntax-type-function character)
          :do (cond ((eql syntax :single-escape)
                     (incf position (min 2 (- end position))))
                    ((eql syntax :multiple-escape)
                     (setf multiple-escape-p (not multiple-escape-p))
                     (incf position))
                    ((and (not multiple-escape-p) (char= character #\:))
                     (return position))
                    (t (incf position))))))

(defclass fancy-repl (mezzano.line-editor:line-edit-mixin
                      mezzano.gray:fundamental-character-input-stream
                      mezzano.gui.widgets:text-widget)
  ((%fifo :initarg :fifo :reader fifo)
   (%window :initarg :window :reader window)
   (%thread :initarg :thread :reader thread)
   (%input :initarg :input :reader input-buffer)
   (%closed :initarg :window-closed :accessor window-closed)
   (%frame :initarg :frame :reader frame))
  (:default-initargs :input (mezzano.supervisor:make-fifo 500 :element-type 'character)
                     :window-closed nil))

(defmethod mezzano.line-editor:compute-completions ((stream fancy-repl) buffer cursor-position)
  (multiple-value-bind (start end)
      (%completion-token-bounds buffer cursor-position)
    (unless start
      (return-from mezzano.line-editor:compute-completions nil))
    ;; Divide into package and symbol.
    (let* ((marker (%completion-package-marker buffer start end))
           (internalp (or (not marker)
                          (and (< (1+ marker) end)
                               (eql (char buffer (1+ marker)) #\:))))
           (package-name (if marker
                             (subseq buffer start marker)
                             (package-name *package*)))
           (package (find-package (if (string= package-name "")
                                      "KEYWORD"
                                      (string-upcase package-name))))
           (name (if marker
                     (subseq buffer (+ marker (if internalp 2 1)) end)
                     (subseq buffer start end))))
      (when package
        (let ((completions '()))
          (flet ((frob (sym)
                   (when (and (>= (length (symbol-name sym)) (length name))
                              (string-equal (symbol-name sym) name :end1 (length name)))
                     (pushnew (string-downcase (subseq (symbol-name sym) (length name)))
                              completions
                              :test #'string-equal))))
            (cond (internalp
                   (do-symbols (sym package)
                     (frob sym)))
                  (t
                   (do-external-symbols (sym package)
                     (frob sym)))))
          (when (not marker)
            (dolist (package (list-all-packages))
              (dolist (package-name (list* (package-name package) (package-nicknames package)))
                (when (and (>= (length package-name) (length name))
                           (string-equal package-name name :end1 (length name)))
                  (pushnew (string-downcase (format nil "~A:" (subseq package-name (length name))))
                           completions
                           :test #'string-equal)))))
          (values cursor-position cursor-position
                  (sort completions #'string<)))))))

(defgeneric dispatch-event (window event)
  ;; Eat unknown events.
  (:method (w e)))

(defmethod dispatch-event (window (event mezzano.gui.compositor:window-activation-event))
  (setf (mezzano.gui.widgets:activep (frame window)) (mezzano.gui.compositor:state event))
  (mezzano.gui.widgets:draw-frame (frame window)))

(defmethod dispatch-event (window (event mezzano.gui.compositor:key-event))
  ;; should filter out strange keys?
  (when (not (mezzano.gui.compositor:key-releasep event))
    (mezzano.supervisor:fifo-push (if (mezzano.gui.compositor:key-modifier-state event)
                                      ;; Force character to uppercase when a modifier key is active, gets
                                      ;; around weirdness in how character names are processed.
                                      ;; #\C-a and #\C-A both parse as the same character (C-LATIN_CAPITAL_LETTER_A).
                                      (mezzano.internals::make-character
                                       (char-code (char-upcase (mezzano.gui.compositor:key-key event)))
                                       :control (find :control (mezzano.gui.compositor:key-modifier-state event))
                                       :meta (find :meta (mezzano.gui.compositor:key-modifier-state event))
                                       :super (find :super (mezzano.gui.compositor:key-modifier-state event))
                                       :hyper (find :hyper (mezzano.gui.compositor:key-modifier-state event)))
                                      (mezzano.gui.compositor:key-key event))
                                  (input-buffer window) nil)))

(defmethod dispatch-event (window (event mezzano.gui.compositor:mouse-event))
  (mezzano.gui.widgets:frame-mouse-event (frame window) event))

(defmethod dispatch-event (window (event mezzano.gui.compositor:window-close-event))
  (throw 'mezzano.supervisor:terminate-thread nil))

(defmethod dispatch-event (window (event mezzano.gui.compositor:quit-event))
  (throw 'mezzano.supervisor:terminate-thread nil))

(defmethod dispatch-event (app (event mezzano.gui.compositor:resize-request-event))
  (let ((old-width (mezzano.gui.compositor:width (window app)))
        (old-height (mezzano.gui.compositor:height (window app)))
        (new-width (max 100 (mezzano.gui.compositor:width event)))
        (new-height (max 100 (mezzano.gui.compositor:height event))))
    (when (or (not (eql old-width new-width))
              (not (eql old-height new-height)))
      (let ((new-framebuffer (mezzano.gui:make-surface
                              new-width new-height))
            (frame (frame app)))
        (mezzano.gui.widgets:resize-frame frame new-framebuffer)
        (mezzano.gui.widgets:resize-widget
         app
         new-framebuffer
         (nth-value 0 (mezzano.gui.widgets:frame-size frame))
         (nth-value 2 (mezzano.gui.widgets:frame-size frame))
         (- new-width
            (nth-value 0 (mezzano.gui.widgets:frame-size frame))
            (nth-value 1 (mezzano.gui.widgets:frame-size frame)))
         (- new-height
            (nth-value 2 (mezzano.gui.widgets:frame-size frame))
            (nth-value 3 (mezzano.gui.widgets:frame-size frame))))
        (mezzano.gui.compositor:resize-window
         (window app) new-framebuffer
         :origin (mezzano.gui.compositor:resize-origin event))))))

(defmethod dispatch-event (app (event mezzano.gui.compositor:resize-event))
  )

(defun pump-event-loop (window)
  "Read & dispatch window events until there are no more waiting events."
  (loop
     (let ((evt (mezzano.supervisor:fifo-pop (fifo window) nil)))
       (when (not evt)
         (return))
       (dispatch-event window evt))))

(defmethod mezzano.gray:stream-read-char ((stream fancy-repl))
  (unwind-protect
       (progn
         (setf (mezzano.gui.widgets:cursor-visible stream) t)
         (loop
            ;; Catch up with window manager events.
            (pump-event-loop stream)
            (setf (mezzano.gui.widgets:cursor-visible stream) t)
            (when (window-closed stream)
              (return :eof))
            ;; Check for an available character.
            (let ((ch (mezzano.supervisor:fifo-pop (input-buffer stream) nil)))
              (when ch
                (return ch)))
            ;; Block until the next window event.
            (dispatch-event stream (mezzano.supervisor:fifo-pop (fifo stream)))))
    (setf (mezzano.gui.widgets:cursor-visible stream) nil)))

(defmethod mezzano.gray:stream-read-char-no-hang ((stream fancy-repl))
  ;; Catch up with window manager events.
  (pump-event-loop stream)
  (cond ((window-closed stream)
         :eof)
        (t (mezzano.supervisor:fifo-pop (input-buffer stream) nil))))

(defmethod mezzano.gray:stream-terpri :before ((stream fancy-repl))
  ;; Catch up with window manager events.
  (pump-event-loop stream))

(defmethod mezzano.gray:stream-write-char :before ((stream fancy-repl) character)
  ;; Catch up with window manager events.
  (pump-event-loop stream))

(defmethod mezzano.gray:stream-clear-input ((stream fancy-repl))
  ;; Catch up with window manager events.
  (pump-event-loop stream)
  ;; Munch all waiting characters.
  (loop
     (when (not (mezzano.supervisor:fifo-pop (input-buffer stream) nil))
       (return))))

(defmethod interactive-stream-p ((stream fancy-repl))
  't)

(defun repl-main (&optional initial-function title width height)
  (let ((font (mezzano.gui.font:open-font
               mezzano.gui.font:*default-monospace-font*
               mezzano.gui.font:*default-monospace-font-size*))
        (fifo (mezzano.supervisor:make-fifo 50)))
    (mezzano.gui.compositor:with-window (window fifo (or width 800) (or height 600))
      (let* ((framebuffer (mezzano.gui.compositor:window-buffer window))
             (frame (make-instance 'mezzano.gui.widgets:frame
                                   :framebuffer framebuffer
                                   :title (string (or title initial-function "REPL"))
                                   :close-button-p t
                                   :resizablep t
                                   :damage-function (mezzano.gui.widgets:default-damage-function window)
                                   :set-cursor-function (mezzano.gui.widgets:default-cursor-function window)))
             (term (make-instance 'fancy-repl
                                  :fifo fifo
                                  :window window
                                  :thread (mezzano.supervisor:current-thread)
                                  :font font
                                  :frame frame
                                  ;; text-widget stuff.
                                  :framebuffer framebuffer
                                  :x-position (nth-value 0 (mezzano.gui.widgets:frame-size frame))
                                  :y-position (nth-value 2 (mezzano.gui.widgets:frame-size frame))
                                  :width (- (mezzano.gui.compositor:width window)
                                            (nth-value 0 (mezzano.gui.widgets:frame-size frame))
                                            (nth-value 1 (mezzano.gui.widgets:frame-size frame)))
                                  :height (- (mezzano.gui.compositor:height window)
                                             (nth-value 2 (mezzano.gui.widgets:frame-size frame))
                                             (nth-value 3 (mezzano.gui.widgets:frame-size frame)))
                                  :damage-function (mezzano.gui.widgets:default-damage-function window)))
             (*terminal-io* term)
             (*standard-input* (make-synonym-stream '*terminal-io*))
             (*standard-output* *standard-input*)
             (*error-output* *standard-input*)
             (*query-io* *standard-input*)
             (*trace-output* *standard-input*)
             (*debug-io* *standard-input*))
        (setf (mezzano.gui.compositor:name window) term)
        (mezzano.gui.widgets:draw-frame frame)
        (mezzano.gui.compositor:damage-window window
                                              0 0
                                              (mezzano.gui.compositor:width window)
                                              (mezzano.gui.compositor:height window))
        (handler-case
            (funcall (or initial-function #'mezzano.internals::repl))
          ;; Exit when the close button is clicked.
          (mezzano.gui.widgets:close-button-clicked ()
            (return-from repl-main)))))))

(defun spawn (&key initial-function title width height)
  (mezzano.supervisor:make-thread (lambda () (repl-main initial-function title width height))
                                  :name (or title "Fancy Lisp Listener")))
