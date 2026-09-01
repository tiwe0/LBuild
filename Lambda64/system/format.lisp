;;;; Early FORMAT

(defpackage :mezzano.format
  (:use :cl)
  ;; FORMAT and FORMATTER are implemented by this package rather than
  ;; inherited from COMMON-LISP.  Declare the shadowing explicitly so host
  ;; implementations do not report package-variance warnings when this file
  ;; is loaded after the test harness package scaffold.
  (:shadow #:format #:formatter))

(in-package :mezzano.format)

(defstruct directive
  character
  at-sign
  colon
  parameters)

;; Only tracks parameters for the start directive.
(defstruct block-directive
  character
  start-at-sign
  start-colon
  end-at-sign
  end-colon
  parameters
  inner)

(defparameter *block-directives*
  '((#\( #\))
    (#\[ #\])
    (#\< #\>)
    (#\{ #\})))

(defun whitespace[1]p (c)
  (or (eql c #\Newline)
      (eql c #\Space)
      (eql c #\Rubout)
      (eql c #\Page)
      (eql c #\Tab)
      (eql c #\Backspace)))

(defun parse-format-directive (control-string offset)
  (let ((prefix-parameters nil)
        (at-sign-modifier nil)
        (colon-modifier nil)
        (current-prefix nil))
    ;; Read prefix parameters
    (do () (nil)
      (case (char-upcase (char control-string offset))
        ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9 #\+ #\-)
         (when current-prefix (error "Invalid format control string ~S." control-string))
         ;; Eat digits until non-digit
         (let ((negative nil))
           (setf current-prefix 0)
           (case (char control-string offset)
             (#\+ (incf offset))
             (#\- (incf offset)
                  (setf negative t)))
           (when (not (digit-char-p (char control-string offset)))
             ;; The sign is optional, the digits are not.
             (error "Invalid format control string ~S." control-string))
           (do () ((not (digit-char-p (char control-string offset))))
             (setf current-prefix (+ (* current-prefix 10)
                                     (digit-char-p (char control-string offset))))
             (incf offset))
           (when negative
             (setf current-prefix (- current-prefix)))))
        (#\#
         (when current-prefix (error "Invalid format control string ~S." control-string))
         (incf offset)
         (setf current-prefix :sharp-sign))
        (#\V
         (when current-prefix (error "Invalid format control string ~S." control-string))
         (incf offset)
         (setf current-prefix :v))
        (#\'
         (when current-prefix (error "Invalid format control string ~S." control-string))
         (incf offset)
         (setf current-prefix (char control-string offset))
         (incf offset))
        (#\,
         (incf offset)
         (push current-prefix prefix-parameters)
         (setf current-prefix nil))
        (t (return))))
    (when current-prefix
      (push current-prefix prefix-parameters))
    (setf prefix-parameters (nreverse prefix-parameters))
    ;; Munch all colons and at-signs
    (do () (nil)
      (case (char control-string offset)
        (#\@ (setf at-sign-modifier t)
             (incf offset))
        (#\: (setf colon-modifier t)
             (incf offset))
        (t (return))))
    (case (char control-string offset)
      (#\Newline
       ;; Newline must be handled specially, as it advances through the control string.
       (unless colon-modifier
         ;; Eat trailing whitespace[1].
         (do () ((not (whitespace[1]p (char control-string (1+ offset)))))
           (incf offset)))
       (values offset #\Newline at-sign-modifier colon-modifier prefix-parameters))
      (#\/
       ;; This also advances through the control string.
       (let ((package-name "COMMON-LISP-USER")
             (symbol-name (make-array 20 :element-type 'character :adjustable t :fill-pointer 0))
             (allow-internal nil))
         (do ((ch (char control-string (incf offset))
                  (char control-string (incf offset))))
             ((eql ch #\/))
           (cond ((and (eql ch #\:)
                       (zerop (length symbol-name)))
                  (setf allow-internal t))
                 ((eql ch #\:)
                  (setf package-name symbol-name
                        symbol-name (make-array 20 :element-type 'character :adjustable t :fill-pointer 0)))
                 (t (vector-push-extend (char-upcase ch) symbol-name))))
         (push (list symbol-name package-name allow-internal) prefix-parameters)
         (values offset #\/ at-sign-modifier colon-modifier prefix-parameters)))
      (t (values offset (char-upcase (char control-string offset)) at-sign-modifier colon-modifier prefix-parameters)))))

(defun parse-format-control-substring (control-string start end-char)
  (do ((offset start (1+ offset))
       (accumulated-string)
       (result '()))
      ((>= offset (length control-string))
       (when end-char
         (error "No terminating ~~~C directive." end-char))
       (when accumulated-string
         (push accumulated-string result)
         (setf accumulated-string nil))
       (values offset (reverse result)))
    (flet ((append-character (c)
             "Append C to the accumulated-string."
             (when (not accumulated-string)
               (setf accumulated-string (make-array 50 :element-type 'character :adjustable t :fill-pointer 0)))
             (vector-push-extend c accumulated-string)))
      (cond ((eql #\~ (char control-string offset))
             (multiple-value-bind (new-offset character at-sign colon parameters)
                 (parse-format-directive control-string (1+ offset))
               (setf offset new-offset)
               ;; Flush accumulated output.
               (when accumulated-string
                 (push accumulated-string result)
                 (setf accumulated-string nil))
               (cond ((find character *block-directives* :key #'first)
                      (multiple-value-bind (new-offset inner end-at-sign end-colon)
                          (parse-format-control-substring control-string (1+ offset)
                                                          (second (find character *block-directives* :key #'first)))
                        (push (make-block-directive :character character
                                                    :start-at-sign at-sign
                                                    :start-colon colon
                                                    :end-at-sign end-at-sign
                                                    :end-colon end-colon
                                                    :parameters parameters
                                                    :inner inner)
                              result)
                        (setf offset new-offset)))
                     ((eql character end-char)
                      (when parameters
                        (error "~~~C does not take parameters." character))
                      (when (eql character end-char)
                        (return (values offset (reverse result) at-sign colon))))
                     ((find character *block-directives* :key #'second)
                      (error "Unexpected directive ~S in format control-string ~S!"
                             character control-string))
                     (t (push (make-directive :character character
                                              :at-sign at-sign
                                              :colon colon
                                              :parameters parameters)
                              result)))))
               (t (append-character (char control-string offset)))))))


(defun parse-format-control (control-string)
  (nth-value 1 (parse-format-control-substring control-string 0 nil)))

(defparameter *format-interpreters* '())

(defvar *format-argument-base* nil)
(defvar *format-escape-tag* nil)
(defvar *format-colon-escape-tag* nil)
(defvar *format-colon-arguments* nil)

(defun format-interpreter (character)
  (check-type character character)
  (getf *format-interpreters* character))

(defun (setf format-interpreter) (value character)
  (check-type character character)
  (setf (getf *format-interpreters* character) value))

(defmacro define-format-interpreter (character (at-sign colon &rest parameter-lambda-list) &body body)
  (let ((arguments (gensym "Args"))
        (at-sign-sym (or at-sign (gensym "At-Sign")))
        (colon-sym (or colon (gensym "Colon"))))
    `(setf (format-interpreter ',character)
           (lambda (,arguments ,at-sign-sym ,colon-sym ,@parameter-lambda-list)
             (declare (mezzano.internals::lambda-name (format-interpreter ,character)))
             (block nil
               ,@(when (not at-sign)
                       (list `(when ,at-sign-sym
                                (error "~~~C does not take the at-sign modifier." ',character))))
               ,@(when (not colon)
                       (list `(when ,colon-sym
                                (error "~~~C does not take the colon modifier." ',character))))
               (flet ((consume-argument ()
                        (when (endp ,arguments)
                          (error "No more format arguments."))
                        (pop ,arguments))
                      (remaining-arguments ()
                        ,arguments))
                 ,@body
                 ,arguments))))))

(defun format-integer (stream n base params at-sign colon)
  (let ((mincol (first params))
        (padchar (or (second params) #\Space))
        (commachar (or (third params) #\,))
        (comma-interval (or (fourth params) 3)))
    (unless (integerp n)
      (return-from format-integer
        (let ((*print-base* base))
          (write n :stream stream :escape nil :readably nil))))
    (check-type padchar character)
    (check-type commachar character)
    (check-type comma-interval (integer 1))
    (when (cddddr params)
      (error "Expected 0 to 4 parameters."))
    (if (or mincol colon)
        ;; Fancy formatting.
        (let ((buffer (make-array 8
                                  :element-type 'character
                                  :adjustable t
                                  :fill-pointer 0))
              (negative nil))
          (when (minusp n)
            (setf negative t
                  n (- n)))
          (unless mincol (setf mincol 0))
          ;; Write the number backwards into the buffer, no commas or padding yet.
          (if (= n 0)
              (vector-push-extend #\0 buffer)
              (do () ((= n 0))
                (multiple-value-bind (quot rem)
                    (truncate n base)
                  (vector-push-extend (char "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" rem) buffer)
                  (setf n quot))))
          (let ((separator-count (if colon
                                     (truncate (1- (length buffer)) comma-interval)
                                     0)))
            (dotimes (i (- mincol (+ (length buffer)
                                     separator-count
                                     (if (or negative at-sign) 1 0))))
            (write-char padchar stream))
          (cond
            (negative
             (write-char #\- stream))
            (at-sign
             (write-char #\+ stream)))
          (if colon
              (dotimes (i (length buffer))
                (when (and (not (zerop i))
                           (zerop (rem (- (length buffer) i) comma-interval)))
                  (write-char commachar stream))
                (write-char (char buffer (- (length buffer) i 1)) stream))
              (dotimes (i (length buffer))
                (write-char (char buffer (- (length buffer) i 1)) stream)))))
        (progn
          (when (and at-sign (not (minusp n)))
            (write-char #\+ stream))
          (write n :stream stream :escape nil :radix nil :base base :readably nil)))))

(defvar *cardinal-names-1*
  '("zero" "one" "two" "three" "four" "five" "six" "seven" "eight" "nine"
    "ten" "eleven" "twelve" "thirteen" "fourteen" "fifteen" "sixteen" "seventeen" "eighteen" "nineteen"))
(defvar *cardinal-names-10*
  '("zero" "ten" "twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"))
(defvar *ordinal-names-1*
  '("zeroth" "first" "second" "third" "fourth" "fifth" "sixth" "seventh" "eighth" "ninth"
    "tenth" "eleventh" "twelfth" "thirteenth" "fourteenth" "fifteenth" "sixteenth" "seventeenth" "eighteenth" "nineteenth"))
(defvar *ordinal-names-10*
  '("zeroth" "tenth" "twentieth" "thirtieth" "fortieth" "fiftieth" "sixtieth" "seventieth" "eightieth" "ninetieth"))
(defvar *radix-powers*
  '((1000000 "million" "millionth") (1000 "thousand" "thousandth") (100 "hundred" "hundredth")))

(defun print-cardinal (integer stream)
  (when (minusp integer)
    (write-string "negative " stream)
    (setf integer (- integer)))
  (cond ((< integer 20)
         (write-string (elt *cardinal-names-1* integer) stream))
        ((< integer 100)
         (multiple-value-bind (quot rem)
             (truncate integer 10)
           (write-string (elt *cardinal-names-10* quot) stream)
           (unless (zerop rem)
             (write-char #\- stream)
             (print-cardinal rem stream))))
        (t (loop for (power cardinal ordinal) in *radix-powers*
              when (>= integer power) do
                (multiple-value-bind (quot rem)
                    (truncate integer power)
                  (print-cardinal quot stream)
                  (write-char #\Space stream)
                  (write-string cardinal stream)
                  (unless (zerop rem)
                    (write-char #\Space stream)
                    (print-cardinal rem stream)))
                (return)
              finally (error "Number ~:D too large to be printed as a cardinal number." integer)))))

(defun print-ordinal (integer stream)
  (when (minusp integer)
    (write-string "negative " stream)
    (setf integer (- integer)))
  (cond ((< integer 20)
         (write-string (elt *ordinal-names-1* integer) stream))
        ((< integer 100)
         (multiple-value-bind (quot rem)
             (truncate integer 10)
           (cond ((zerop rem)
                  (write-string (elt *ordinal-names-10* quot) stream))
                 (t (write-string (elt *cardinal-names-10* quot) stream)
                    (write-char #\- stream)
                    (print-ordinal rem stream)))))
        (t (loop for (power cardinal ordinal) in *radix-powers*
              when (>= integer power) do
                (multiple-value-bind (quot rem)
                    (truncate integer power)
                  (print-cardinal quot stream)
                  (write-char #\Space stream)
                  (cond ((zerop rem)
                         (write-string ordinal stream))
                        (t (write-string cardinal stream)
                           (write-char #\Space stream)
                           (print-ordinal rem stream))))
                (return)
              finally (error "Number ~:D too large to be printed as an ordinal number." integer)))))

;;;; 22.3.1 FORMAT Basic Output.

(defun format-character (stream c at-sign colon)
  (check-type c character)
  (cond ((and at-sign (not colon))
         (write c :stream stream :escape t))
        (colon
         (if (and (graphic-char-p c) (not (eql #\Space c)))
             (write-char c stream)
             (write-string (char-name c) stream))
         (when at-sign
           ;; The precise keyboard gesture is implementation-dependent.  Give
           ;; a useful description for characters produced by the conventional
           ;; shifted ASCII keys, and leave layout-specific characters alone.
           (let* ((shifted "~!@#$%^&*()_+{}|:\"<>?")
                  (unshifted "`1234567890-=[]\\;',./")
                  (position (position c shifted :test #'char=)))
             (cond ((upper-case-p c)
                    (write-string " (Shift-" stream)
                    (write-char (char-downcase c) stream)
                    (write-char #\) stream))
                   (position
                    (write-string " (Shift-" stream)
                    (write-char (char unshifted position) stream)
                    (write-char #\) stream))))))
        (t (write-char c stream))))

(define-format-interpreter #\C (at-sign colon)
  (format-character *standard-output* (consume-argument) at-sign colon))

(define-format-interpreter #\% (at-sign colon &optional n)
  (check-type n (or integer null))
  (dotimes (i (or n 1))
    (terpri)))

(define-format-interpreter #\& (at-sign colon &optional n)
  (check-type n (or integer null))
  (when (or (null n) (plusp n))
    (fresh-line)
    (dotimes (i (1- (or n 1)))
      (terpri))))

(define-format-interpreter #\| (at-sign colon &optional n)
  (check-type n (or integer null))
  (dotimes (i (or n 1))
    (write-char #\Page)))

(define-format-interpreter #\~ (at-sign colon &optional n)
  (check-type n (or integer null))
  (dotimes (i (or n 1))
    (write-char #\~)))

;;;; 22.3.2 FORMAT Radix Control.

(defun format-radix (stream arg params at-sign colon)
  (cond
    (params
     (let ((base (or (first params) 10)))
       (check-type base integer)
       (format-integer stream arg
                       base (rest params)
                       at-sign colon)))
    (at-sign
     (unless (and (integerp arg) (<= 1 arg 3999))
       (error "Number ~S is outside the Roman numeral range 1 through 3999." arg))
     (let ((table (if colon
                      '((1000 "M") (500 "D") (100 "C") (50 "L")
                        (10 "X") (5 "V") (1 "I"))
                      '((1000 "M") (900 "CM") (500 "D") (400 "CD")
                        (100 "C") (90 "XC") (50 "L") (40 "XL")
                        (10 "X") (9 "IX") (5 "V") (4 "IV") (1 "I")))))
       (dolist (entry table)
         (destructuring-bind (value digits) entry
           (loop while (>= arg value)
                 do (write-string digits stream)
                    (decf arg value))))))
    (colon
     (print-ordinal arg stream))
    (t
     (print-cardinal arg stream))))

(define-format-interpreter #\R (at-sign colon &rest params)
  (format-radix *standard-output*
                (consume-argument)
                params at-sign colon))

(define-format-interpreter #\D (at-sign colon &rest params)
  (format-integer *standard-output* (consume-argument)
                  10 params at-sign colon))

(define-format-interpreter #\B (at-sign colon &rest params)
  (format-integer *standard-output* (consume-argument)
                  2 params at-sign colon))

(define-format-interpreter #\O (at-sign colon &rest params)
  (format-integer *standard-output* (consume-argument)
                  8 params at-sign colon))

(define-format-interpreter #\X (at-sign colon &rest params)
  (format-integer *standard-output* (consume-argument)
                  16 params at-sign colon))

;;;; 22.3.3 FORMAT Floating-Point Printers.

(defun decimal-integer-string (integer &optional (minimum-digits 1))
  (let ((string (with-output-to-string (stream)
                  (write integer :stream stream :base 10 :radix nil))))
    (if (< (length string) minimum-digits)
        (concatenate 'string
                     (make-string (- minimum-digits (length string))
                                  :initial-element #\0)
                     string)
        string)))

(defun write-field (stream string width padchar overflowchar &optional right-pad-p)
  (cond ((and width overflowchar (> (length string) width))
         (dotimes (i width)
           (write-char overflowchar stream)))
        (t
         (let ((padding (max 0 (- (or width 0) (length string)))))
           (unless right-pad-p
             (dotimes (i padding) (write-char padchar stream)))
           (write-string string stream)
           (when right-pad-p
             (dotimes (i padding) (write-char padchar stream)))))))

(defun finite-real-rational (object)
  (etypecase object
    (rational object)
    (float (rational object))))

(defun negative-real-p (object)
  (or (minusp object)
      (and (floatp object)
           (zerop object)
           (minusp (float-sign object)))))

(defun basic-real-string (object)
  (let* ((print-object (if (and (rationalp object) (not (integerp object)))
                           (float object)
                           object))
         (string (with-output-to-string (stream)
                   (write print-object :stream stream :escape nil :readably nil)))
         (marker (position-if (lambda (char)
                                (find char "EeFfDdSsLl" :test #'char=))
                              string)))
    (when (and marker
               (zerop (parse-integer string :start (1+ marker))))
      (setf string (subseq string 0 marker)))
    (if (find #\. string)
        string
        (concatenate 'string string ".0"))))

(defun real-significant-decimal-digits (object)
  (let* ((string (basic-real-string object))
         (exponent-position
           (position-if (lambda (char)
                          (find char "EeFfDdSsLl" :test #'char=))
                        string))
         (mantissa (subseq string 0 exponent-position))
         (digits (remove #\. (string-left-trim '(#\+ #\-) mantissa)))
         (leading (position-if-not (lambda (char) (char= char #\0)) digits)))
    (if leading
        (max 1 (- (length digits) leading
                  (loop for i downfrom (1- (length digits)) to leading
                        while (char= (char digits i) #\0)
                        count 1)))
        1)))

(defun decimal-exponent (number)
  (cond ((zerop number) 0)
        ((>= number 1)
         (loop with scaled = number
               with exponent = 0
               while (>= scaled 10)
               do (setf scaled (/ scaled 10))
                  (incf exponent)
               finally (return exponent)))
        (t
         (loop with scaled = number
               with exponent = -1
               while (< scaled 1/10)
               do (setf scaled (* scaled 10))
                  (decf exponent)
               finally (return exponent)))))

(defun fixed-real-string (object digits scale at-sign
                          &optional minimum-integer-digits decimal-point-p)
  (let* ((negative (negative-real-p object))
         (magnitude (abs (finite-real-rational object)))
         (factor (expt 10 digits))
         (rounded (round (* magnitude (expt 10 scale) factor)))
         (integer-part (truncate rounded factor))
         (fraction-part (rem rounded factor)))
    (concatenate 'string
                 (cond (negative "-") (at-sign "+") (t ""))
                 (decimal-integer-string integer-part
                                         (or minimum-integer-digits 1))
                 (if (or (plusp digits) decimal-point-p) "." "")
                 (if (plusp digits)
                     (decimal-integer-string fraction-part digits)
                     ""))))

(defun non-real-format-field (object width padchar)
  (let ((string (with-output-to-string (stream)
                  (write object :stream stream :escape nil :readably nil))))
    (values string width padchar)))

(defun format-fixed-float (stream object params at-sign colon)
  (declare (ignore colon))
  (destructuring-bind (&optional w d k overflowchar padchar) params
    (setf k (or k 0)
          padchar (or padchar #\Space))
    (check-type w (or null (integer 0)))
    (check-type d (or null (integer 0)))
    (check-type k integer)
    (check-type overflowchar (or null character))
    (check-type padchar character)
    (if (not (realp object))
        (multiple-value-bind (string width pad)
            (non-real-format-field object w padchar)
          (write-field stream string width pad nil t))
        (let* ((digits (or d
                           (let ((exponent
                                   (decimal-exponent
                                    (abs (finite-real-rational object)))))
                             (max 1 (- (real-significant-decimal-digits object)
                                       exponent k 1)))))
               (string (fixed-real-string object digits k at-sign)))
          (write-field stream string w padchar overflowchar)))))

(defun exponent-real-string (object digits exponent-digits scale exponentchar at-sign)
  (let* ((magnitude (abs (finite-real-rational object)))
         (exponent (decimal-exponent magnitude))
         (mantissa-scale (- (or scale 1) 1 exponent))
         (mantissa (fixed-real-string object digits mantissa-scale at-sign))
         (display-exponent (- exponent (1- (or scale 1)))))
    (concatenate 'string mantissa
                 (string (or exponentchar
                             (if (or (not (floatp object))
                                     (typep object *read-default-float-format*))
                                 #\E
                                 (etypecase object
                                   (short-float #\S)
                                   (single-float #\F)
                                   (double-float #\D)
                                   (long-float #\L)))))
                 (if (minusp display-exponent) "-" "+")
                 (decimal-integer-string (abs display-exponent)
                                         (or exponent-digits 1)))))

(defun exponent-digits-overflow-p (object exponent-digits scale)
  (and exponent-digits
       (> (length
           (decimal-integer-string
            (abs (- (decimal-exponent
                     (abs (finite-real-rational object)))
                    (1- scale)))
            1))
          exponent-digits)))

(defun write-exponent-field (stream string object width exponent-digits scale
                             padchar overflowchar)
  (if (and width overflowchar
           (exponent-digits-overflow-p object exponent-digits scale))
      (dotimes (i width)
        (declare (ignore i))
        (write-char overflowchar stream))
      (write-field stream string width padchar overflowchar)))

(defun format-exponent-float (stream object params at-sign colon)
  (declare (ignore colon))
  (destructuring-bind (&optional w d e k overflowchar padchar exponentchar)
      params
    (setf k (or k 1)
          padchar (or padchar #\Space))
    (check-type w (or null (integer 0)))
    (check-type d (or null (integer 0)))
    (check-type e (or null (integer 0)))
    (check-type k integer)
    (check-type overflowchar (or null character))
    (check-type padchar character)
    (check-type exponentchar (or null character))
    (if (not (realp object))
        (multiple-value-bind (string width pad)
            (non-real-format-field object w padchar)
          (write-field stream string width pad nil t))
        (write-exponent-field
         stream
         (exponent-real-string
          object (or d (max 1 (1- (real-significant-decimal-digits object))))
          e k exponentchar at-sign)
         object w e k padchar overflowchar))))

(defun format-general-float (stream object params at-sign colon)
  (declare (ignore colon))
  (destructuring-bind (&optional w d e k overflowchar padchar exponentchar)
      params
    (setf k (or k 1)
          padchar (or padchar #\Space))
    (check-type w (or null (integer 0)))
    (check-type d (or null (integer 0)))
    (check-type e (or null (integer 0)))
    (check-type k integer)
    (check-type overflowchar (or null character))
    (check-type padchar character)
    (check-type exponentchar (or null character))
    (if (not (realp object))
        (multiple-value-bind (string width pad)
            (non-real-format-field object w padchar)
          (write-field stream string width pad nil t))
        (let* ((digits (or d (real-significant-decimal-digits object)))
               (exponent (decimal-exponent (abs (finite-real-rational object))))
               (exponent-width (+ (or e 2) 2)))
          (if (and (<= -1 exponent) (< exponent digits))
              (let ((string (concatenate
                             'string
                             (fixed-real-string object
                                                (max 0 (- digits exponent 1))
                                                0 at-sign nil t)
                             (make-string exponent-width :initial-element #\Space))))
                (write-field stream string w padchar overflowchar))
              (write-exponent-field
               stream
               (exponent-real-string object digits e k
                                     (or exponentchar
                                         (and (typep object 'single-float)
                                              #\e))
                                     at-sign)
               object w e k padchar overflowchar))))))

(defun format-monetary-float (stream object params at-sign colon)
  (destructuring-bind (&optional d n w padchar) params
    (setf d (or d 2)
          n (or n 1)
          w (or w 0)
          padchar (or padchar #\Space))
    (check-type d (integer 0))
    (check-type n (integer 0))
    (check-type w (integer 0))
    (check-type padchar character)
    (if (not (realp object))
        (multiple-value-bind (string width pad)
            (non-real-format-field object w padchar)
          (declare (ignore pad))
          (write-field stream string width #\Space nil))
        (let* ((negative (negative-real-p object))
               (unsigned (fixed-real-string (abs object) d 0 nil n))
               (sign (cond (negative "-") (at-sign "+") (t "")))
               (padding (max 0 (- w (length unsigned) (length sign)))))
          (if colon
              (progn (write-string sign stream)
                     (dotimes (i padding) (write-char padchar stream)))
              (progn (dotimes (i padding) (write-char padchar stream))
                     (write-string sign stream)))
          (write-string unsigned stream)))))

(define-format-interpreter #\F (at-sign colon &rest params)
  (format-fixed-float *standard-output* (consume-argument) params at-sign colon))

(define-format-interpreter #\E (at-sign colon &rest params)
  (format-exponent-float *standard-output* (consume-argument) params at-sign colon))

(define-format-interpreter #\G (at-sign colon &rest params)
  (format-general-float *standard-output* (consume-argument) params at-sign colon))

(define-format-interpreter #\$ (at-sign colon &rest params)
  (format-monetary-float *standard-output* (consume-argument) params at-sign colon))

;;;; 22.3.4 FORMAT Printer Operations.

(defun format-printer-operation (stream object mincol colinc minpad padchar
                                 at-sign colon escape readably-is-nil)
  "Write OBJECT for ~A or ~S, applying the directive's full field contract."
  ;; The parser preserves commas as explicit NIL parameters, so normalize
  ;; omitted fields here as well as in the compiled XP formatter.
  (setf mincol (or mincol 0)
        colinc (or colinc 1)
        minpad (or minpad 0)
        padchar (or padchar #\Space))
  (check-type mincol (integer 0))
  (check-type colinc (integer 1))
  (check-type minpad (integer 0))
  (check-type padchar character)
  (let ((string
          (with-output-to-string (output)
            (let ((*print-escape* escape)
                  ;; ~A must remain aesthetic even if the caller binds this.
                  (*print-readably* (if readably-is-nil nil *print-readably*)))
              (if (and colon (null object))
                  (write-string "()" output)
                  (write object :stream output))))))
    ;; MINPAD is mandatory even when the object already exceeds MINCOL. Add
    ;; COLINC-sized groups after it until the complete field is wide enough.
    (let ((padding minpad))
      (loop while (< (+ (length string) padding) mincol)
            do (incf padding colinc))
      (when at-sign
        (dotimes (i padding)
          (declare (ignore i))
          (write-char padchar stream)))
      (write-string string stream)
      (unless at-sign
        (dotimes (i padding)
          (declare (ignore i))
          (write-char padchar stream))))))

(define-format-interpreter #\A (at-sign colon &optional (mincol 0) (colinc 1)
                                 (minpad 0) (padchar #\Space))
  (format-printer-operation *standard-output* (consume-argument)
                            mincol colinc minpad padchar
                            at-sign colon nil t))

(define-format-interpreter #\S (at-sign colon &optional (mincol 0) (colinc 1)
                                 (minpad 0) (padchar #\Space))
  (format-printer-operation *standard-output* (consume-argument)
                            mincol colinc minpad padchar
                            at-sign colon t nil))

(define-format-interpreter #\W (at-sign colon)
  (cond
    ((and at-sign colon)
     (write (consume-argument) :pretty t :level nil :length nil))
    (at-sign
     (write (consume-argument) :level nil :length nil))
    (colon
     (write (consume-argument) :pretty t))
    (t (write (consume-argument)))))

;;;; 22.3.5 FORMAT Pretty Printer Operations.

(define-format-interpreter #\_ (at-sign colon)
  (cond
    ((and at-sign colon)
     (pprint-newline :mandatory))
    (at-sign
     (pprint-newline :miser))
    (colon
     (pprint-newline :fill))
    (t (pprint-newline :linear))))

(defun decode-justification-sections (inner)
  (let ((sections '())
        (current '())
        overflow-section
        (spare 0)
        line-width)
    (dolist (element inner)
      (if (and (directive-p element)
               (eql (directive-character element) #\;))
          (cond ((directive-colon element)
                 (when (or overflow-section sections
                           (directive-at-sign element)
                           (> (length (directive-parameters element)) 2))
                   (error "Malformed ~~:; overflow clause in justification."))
                 (setf overflow-section (nreverse current)
                       current '()
                       spare (or (first (directive-parameters element)) 0)
                       line-width (second (directive-parameters element))))
                (t
                 (when (or (directive-at-sign element)
                           (directive-parameters element))
                   (error "~~; in justification takes no modifiers or parameters."))
                 (push (nreverse current) sections)
                 (setf current '())))
          (push element current)))
    (check-type spare (integer 0))
    (check-type line-width (or null (integer 0)))
    (values (nreverse (cons (nreverse current) sections))
            overflow-section spare line-width)))

(defun render-format-section (section args)
  (let (remaining)
    (values (with-output-to-string (stream)
              (let ((*standard-output* stream))
                (setf remaining (interpret-format-control section args))))
            remaining)))

(defun literal-format-section-string (section context)
  (unless (every #'stringp section)
    (error "~A prefix and suffix sections must be literal strings." context))
  (apply #'concatenate 'string section))

(defun decode-logical-block-sections (inner colon)
  (let ((sections '())
        (separators '())
        (current '()))
    (dolist (element inner)
      (if (and (directive-p element)
               (eql (directive-character element) #\;))
          (progn
            (when (or (directive-colon element)
                      (directive-parameters element))
              (error "~~; in a logical block takes only an optional at-sign."))
            (push (nreverse current) sections)
            (push element separators)
            (setf current '()))
          (push element current)))
    (setf sections (nreverse (cons (nreverse current) sections))
          separators (nreverse separators))
    (unless (or (= (length sections) 1) (= (length sections) 3))
      (error "Logical ~~<...~~:> requires one or three sections."))
    (when (and (= (length sections) 3)
               (directive-at-sign (second separators)))
      (error "Only the first logical-block separator may use an at-sign."))
    (values (if (= (length sections) 3)
                (literal-format-section-string (first sections) "Logical block")
                (if colon "(" ""))
            (if (= (length sections) 3) (second sections) (first sections))
            (if (= (length sections) 3)
                (literal-format-section-string (third sections) "Logical block")
                (if colon ")" ""))
            (and separators
                 (directive-at-sign (first separators))))))

(defun interpret-logical-block-body (body args fill-p)
  (if (not fill-p)
      (interpret-format-control body args)
      (dolist (element body args)
        (etypecase element
          (string
           (loop for char across element
                 do (write-char char)
                    (when (or (char= char #\Space) (char= char #\Tab))
                      (pprint-newline :fill))))
          ((or directive block-directive)
           (setf args (interpret-format-control (list element) args)))))))

(defun format-justification (args inner at-sign colon end-at-sign params)
  (when end-at-sign
    (error "~~> does not take the at-sign modifier in justification blocks."))
  (when (cddddr params)
    (error "~~< expects zero to four parameters."))
  (multiple-value-bind (sections overflow-section spare line-width)
      (decode-justification-sections inner)
    (let* ((mincol (or (first params) 0))
           (colinc (or (second params) 1))
           (minpad (or (third params) 0))
           (padchar (or (fourth params) #\Space))
           (strings '())
           (remaining args)
           overflow-string)
      (check-type mincol (integer 0))
      (check-type colinc (integer 1))
      (check-type minpad (integer 0))
      (check-type padchar character)
      (when overflow-section
        (multiple-value-setq (overflow-string remaining)
          (render-format-section overflow-section remaining)))
      (dolist (section sections)
        (multiple-value-bind (string new-remaining)
            (render-format-section section remaining)
          (push string strings)
          (setf remaining new-remaining)))
      (setf strings (nreverse strings))
      (let* ((natural-length (reduce #'+ strings :key #'length :initial-value 0))
             (slots (+ (max 0 (1- (length strings)))
                       (if colon 1 0)
                       (if at-sign 1 0)))
             (slots (if (zerop slots) 1 slots))
             (minimum (+ natural-length (* minpad slots)))
             (target (max mincol minimum)))
        (when (> target mincol)
          (let ((remainder (rem (- target mincol) colinc)))
            (unless (zerop remainder)
              (incf target (- colinc remainder)))))
        (when overflow-section
          (let ((column (or (mezzano.gray:stream-line-column *standard-output*) 0))
                (width (or line-width
                           (mezzano.gray:stream-line-length *standard-output*)
                           72)))
            (when (> (+ column target spare) width)
              (write-string overflow-string))))
        (let ((padding (- target natural-length))
              (slot 0))
          (labels ((emit-slot ()
                     (let* ((base (truncate padding slots))
                            (remainder (rem padding slots))
                            (count (+ base
                                      (if (>= slot (- slots remainder)) 1 0))))
                       (incf slot)
                       (dotimes (i count)
                         (declare (ignore i))
                         (write-char padchar)))))
            (when (or colon (= (length strings) 1)) (emit-slot))
            (loop for string in strings
                  for tail on strings
                  do (write-string string)
                     (when (rest tail) (emit-slot)))
            (when at-sign (emit-slot)))))
      remaining)))

(define-format-interpreter #\I (nil colon &optional count)
  (check-type count (or integer null))
  (pprint-indent (if colon
                     :current
                     :block)
                 (or count 1)))

(define-format-interpreter #\/ (at-sign colon function &rest params)
  (destructuring-bind (symbol-name package-name allow-internal)
      function
    (apply (intern symbol-name package-name)
           *standard-output*
           (consume-argument)
           colon at-sign
           params)))

;;;; 22.3.6 FORMAT Layout Control.

(define-format-interpreter #\T (at-sign colon &optional colnum colinc)
  (setf colnum (or colnum 1)
        colinc (or colinc 1))
  (cond (colon
         (pprint-tab (if at-sign :section-relative :section)
                     colnum colinc))
        (at-sign
         (dotimes (i colnum)
           (write-char #\Space))
         (let ((current (mezzano.gray:stream-line-column *standard-output*)))
           (when current
             (dotimes (i (- colinc (rem current colinc)))
               (write-char #\Space)))))
        (t (let ((current (mezzano.gray:stream-line-column *standard-output*)))
             (cond ((not current)
                    (write-string "  "))
                   ((< current colnum)
                    (dotimes (i (- colnum current))
                      (write-char #\Space)))
                   ((not (zerop colinc))
                    (dotimes (i (- colinc (rem (- current colnum) colinc)))
                      (write-char #\Space))))))))

(defun format-logical-block (args inner at-sign colon end-at-sign params)
  (when params
    (error "~~< logical blocks do not take parameters."))
  (multiple-value-bind (prefix body suffix per-line-prefix-p)
      (decode-logical-block-sections inner colon)
    (let* ((outer-args args)
           (block-args (if at-sign
                           args
                           (progn
                             (when (endp args)
                               (error "No more format arguments."))
                             (pop outer-args))))
           (remaining block-args))
      (flet ((render-body ()
               (let ((*format-argument-base* block-args))
                 (setf remaining
                       (interpret-logical-block-body body block-args
                                                     end-at-sign)))))
        (if per-line-prefix-p
            (pprint-logical-block (*standard-output* block-args
                                   :per-line-prefix prefix :suffix suffix)
              (render-body))
            (pprint-logical-block (*standard-output* block-args
                                   :prefix prefix :suffix suffix)
              (render-body))))
      (if at-sign nil outer-args))))

;;;; 22.3.7 FORMAT Control-Flow Operations.

(defun format-argument-tail-position (tail base)
  (loop for rest on base
        for position from 0
        when (eq rest tail) return position
        finally (if (null tail)
                    (return (length base))
                    (error "FORMAT argument pointer is not within its argument list."))))

(define-format-interpreter #\* (at-sign colon &optional n)
  (when (and at-sign colon)
    (error "~~* does not accept both colon and at-sign modifiers."))
  (setf n (or n (if at-sign 0 1)))
  (check-type n (integer 0))
  (let* ((current (format-argument-tail-position (remaining-arguments)
                                                 *format-argument-base*))
         (target (cond (at-sign n)
                       (colon (- current n))
                       (t (+ current n)))))
    (unless (<= 0 target (length *format-argument-base*))
      (error "FORMAT argument reposition target ~D is out of bounds." target))
    (return (nthcdr target *format-argument-base*))))

(defun format-iteration (args inner at-sign colon end-at-sign end-colon params)
  (when (rest params)
    (error "~~{ expects at most one parameter."))
  (when end-at-sign
    (error "~~> does not take the at-sign modifier."))
  (let ((n (first params))
        (list (cond (at-sign
                     args)
                    (t (when (endp args)
                         (error "No more format arguments."))
                       (pop args)))))
    (check-type n (or null integer))
    (let ((tag (gensym "FORMAT-ITERATION-")))
      (let ((*format-escape-tag* tag))
        (multiple-value-bind (escaped-tail escaped-p)
            (catch tag
              (loop with iteration = 0
                    do (when (and n (>= iteration n)) (return))
                       (when (and (not end-colon) (endp list)) (return))
                       (setf end-colon nil)
                       (incf iteration)
                       (if colon
                           (let ((iteration-arguments (pop list)))
                             (let ((*format-argument-base* iteration-arguments)
                                   (*format-colon-escape-tag* tag)
                                   (*format-colon-arguments* list))
                               (interpret-format-control inner
                                                         iteration-arguments)))
                           (let ((*format-argument-base* list)
                                 (*format-colon-escape-tag* tag)
                                 (*format-colon-arguments* list))
                             (setf list
                                   (interpret-format-control inner list)))))
              (values nil nil))
          (when (and escaped-p (not colon))
            (setf list escaped-tail)))))
    (if at-sign
        list
        args)))

(defun decode-conditional-clauses (control-list)
  "Split CONTROL-LIST into a list of clauses at ~; directives."
  (let ((result '())
        (current '())
        saw-else)
    (dolist (element control-list)
      (cond ((and (directive-p element)
                  (eql (directive-character element) #\;))
             (when saw-else
               (error "Additional clauses after else clause."))
             (when (directive-colon element)
               (setf saw-else t))
             (when (directive-at-sign element)
               (error "~; in [] does not take the at-sign modifier."))
             (when (directive-parameters element)
               (error "~; in [] expects no parameters."))
             (push (reverse current) result)
             (setf current '()))
            (t (push element current))))
    (cond (saw-else
           (values (reverse result) (reverse current) saw-else))
          (t (push (reverse current) result)
             (values (reverse result) nil saw-else)))))

(defun format-conditional (args inner at-sign colon end-at-sign end-colon params)
  (when (or end-at-sign end-colon)
    (error "~~] does not take the at-sign or colon modifiers."))
  (multiple-value-bind (clauses default defaultp)
      (decode-conditional-clauses inner)
    (cond ((and at-sign colon)
           (error "At-sign and colon modifiers are mutually exclusive in ~~["))
          (at-sign ; Test argument. If true, rewind 1 and execute the one-clause consequent.
           (when params (error "~~@[ expects no parameters."))
           (when defaultp
             (error "Default clause with ~~:[."))
           (unless (eql (length clauses) 1)
             (error "~~@[ takes exactly one claus."))
           (when (endp args)
             (error "No more format arguments."))
           (cond ((first args)
                  (interpret-format-control (first clauses)
                                            args))
                 (t (pop args) args)))
          (colon ; Select first clause if argument is false, second if true.
           (when params (error "~~:[ expects no parameters."))
           (when defaultp
             (error "Default clause with ~~:[."))
           (unless (eql (length clauses) 2)
             (error "~~:[ takes exactly two clauses."))
           (when (endp args)
             (error "No more format arguments."))
           (interpret-format-control (if (pop args)
                                         (second clauses)
                                         (first clauses))
                                     args))
           (t (when (rest params)
                (error "~~[ expects at most one parameter."))
              (when (and (null (first params)) (endp args))
                (error "No more format arguments."))
              (let ((arg (or (first params) (pop args))))
                (check-type arg integer)
                (cond ((or (< arg 0)
                           (>= arg (length clauses)))
                       (if defaultp
                           (interpret-format-control default
                                                     args)
                           args))
                      (t (interpret-format-control (nth arg clauses)
                                                   args))))))))

(define-format-interpreter #\? (at-sign nil)
  (let ((control (parse-format-control (consume-argument))))
    (cond (at-sign
           (return (interpret-format-control control (remaining-arguments))))
          (t (let ((indirect-arguments (consume-argument)))
               (let ((*format-argument-base* indirect-arguments))
                 (interpret-format-control control indirect-arguments)))))))

;;;; 22.3.8 FORMAT Miscellaneous Operations.

(defun format-case-correcting (args inner at-sign colon end-at-sign end-colon params)
  (when params (error "~~( Expects no parameters."))
  (when (or end-at-sign end-colon)
    (error "~~) does not take the at-sign or colon modifiers."))
  (let ((*standard-output* (mezzano.internals::make-case-correcting-stream
                            *standard-output*
                            (cond ((and colon at-sign)
                                   :upcase)
                                  (colon
                                   :titlecase)
                                  (at-sign
                                   :sentencecase)
                                  (t :downcase)))))
    (interpret-format-control inner args)))

(define-format-interpreter #\P (at-sign colon)
  (let ((arg (if colon
                 (let ((position
                         (format-argument-tail-position
                          (remaining-arguments) *format-argument-base*)))
                   (when (zerop position)
                     (error "~~:P has no previous argument."))
                   (nth (1- position) *format-argument-base*))
                 (consume-argument))))
    (if (and (numberp arg)
             (= arg 1))
        (if at-sign
            (write-string "y"))
        (if at-sign
            (write-string "ies")
            (write-string "s")))))

;;;; 22.3.9 FORMAT Miscellaneous Pseudo-Operations.

(define-format-interpreter #\^ (at-sign colon &rest params)
  (when (> (length params) 3)
    (error "~~^ accepts at most three parameters."))
  (let ((escape-p
          (case (length params)
            (0 (endp (if colon
                         *format-colon-arguments*
                         (remaining-arguments))))
            (1 (zerop (first params)))
            (2 (= (first params) (second params)))
            (3 (<= (first params) (second params) (third params))))))
    (when escape-p
      (throw (if colon
                 (or *format-colon-escape-tag* *format-escape-tag*)
                 *format-escape-tag*)
             (values (remaining-arguments) t)))))

(define-format-interpreter #\Newline (at-sign colon)
  (when at-sign
    (write-char #\Newline)))

(defun format-justification-or-logical-block (args inner at-sign colon end-at-sign end-colon params)
  (if end-colon
      (format-logical-block args inner at-sign colon end-at-sign params)
      (format-justification args inner at-sign colon end-at-sign params)))

(defun interpret-format-control (control args)
  (flet ((compute-parameters (params)
           (mapcar (lambda (p)
                     (cond ((eql p :v)
                            (when (endp args)
                              (error "No more arguments for V parameter."))
                            (pop args))
                           ((eql p :sharp-sign)
                            (length args))
                           (t p)))
                   params)))
    (dolist (element control)
      (etypecase element
        (string (write-string element))
        (block-directive
         ;; V parameters consume their arguments before the block receives its
         ;; own argument list. Keep that sequencing explicit instead of relying
         ;; on the evaluation order of FUNCALL's arguments.
         (let ((params (compute-parameters (block-directive-parameters element))))
           (setf args (funcall (ecase (block-directive-character element)
                                 (#\( #'format-case-correcting)
                                 (#\[ #'format-conditional)
                                 (#\< #'format-justification-or-logical-block)
                                 (#\{ #'format-iteration))
                               args
                               (block-directive-inner element)
                               (block-directive-start-at-sign element)
                               (block-directive-start-colon element)
                               (block-directive-end-at-sign element)
                               (block-directive-end-colon element)
                               params))))
        (directive
         (let ((fn (format-interpreter (directive-character element))))
           (when (not fn)
             (error "Unknown format directive ~S!" (directive-character element)))
           ;; As above, evaluate V/# parameters before passing ARGS to the
           ;; directive; a V parameter is not itself the directive's object.
           (let ((params (compute-parameters (directive-parameters element))))
             (setf args (apply fn args
                               (directive-at-sign element)
                               (directive-colon element)
                               params))))))))
  args)

(defun format (destination control-string &rest arguments)
  (flet ((do-format (stream)
           (let ((tag (gensym "FORMAT-ESCAPE-")))
             (let ((*format-argument-base* arguments)
                   (*format-escape-tag* tag)
                   (*format-colon-escape-tag* tag)
                   (*format-colon-arguments* arguments))
               (catch tag
                 (etypecase control-string
                   (string
                    (let ((*standard-output* stream))
                      (interpret-format-control
                       (parse-format-control control-string)
                       arguments)))
                   (function
                    (apply control-string stream arguments))))))
           nil))
    (cond
      ((eql destination 'nil)
       (with-output-to-string (stream)
         (do-format stream)))
      ((and (stringp destination)
            (array-has-fill-pointer-p destination))
       (do-format (make-instance 'mezzano.internals::string-output-stream
                                 :element-type 'character
                                 :string destination)))
      ((eql destination 't)
       (do-format *standard-output*))
      ((streamp destination)
       (do-format destination))
      (t (error 'type-error
                :expected-type '(or
                                 (member nil t)
                                 stream
                                 (and string (not simple-string)))
                :datum destination)))))

(defun formatter-1 (stream control-string arguments)
  (let ((*standard-output* stream)
        (*format-argument-base* arguments))
    ;; Call I-F-C directly instead of FORMAT so the remaining arguments
    ;; are returned.
    (let ((tag (gensym "FORMATTER-ESCAPE-")))
      (let ((*format-escape-tag* tag)
            (*format-colon-escape-tag* tag)
            (*format-colon-arguments* arguments))
        (let ((remaining
                (nth-value
                 0
                 (catch tag
                   (interpret-format-control
                    (parse-format-control control-string) arguments)))))
          remaining)))))

(defmacro formatter (control-string)
  (let ((stream (gensym "STREAM"))
        (arguments (gensym "ARGUMENTS")))
    `(lambda (,stream &rest ,arguments)
       (formatter-1 ,stream ',control-string ,arguments))))
