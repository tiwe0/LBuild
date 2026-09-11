(in-package :mezzano.internals)

(define-condition unknown-coercion (type-error)
  ((object :initarg :object
           :reader unknown-coercion-object)
   (type :initarg :type
         :reader unknown-coercion-type))
  (:report (lambda (condition stream)
             (format stream "Don't know how to coerce ~S to type ~S."
                     (unknown-coercion-object condition)
                     (unknown-coercion-type condition)))))

;; COERCE-VECTOR-ELEMENT-TYPE lives in system/type.lisp.  This file is warm
;; loaded, but the cold system/sequence.lisp calls the helper from
;; MAKE-SEQUENCE, so it must exist before warm loading begins -- CLOS reaches
;; (MAKE-SEQUENCE 'VECTOR ...) while closette itself is still loading.

(declaim (inline %coerce-value))
(defun %coerce-value (object result-type)
  (cond ((subtypep result-type 'list)
         (map 'list 'identity object))
        ((subtypep result-type 'vector)
         (check-type object sequence)
         (let ((element-type (coerce-vector-element-type result-type nil)))
           (if element-type
               (make-array (length object)
                           :element-type element-type
                           :initial-contents object)
               (error 'unknown-coercion :object object :type result-type))))
        ((subtypep result-type 'short-float)
         (float object 1.0s0))
        ((subtypep result-type 'single-float)
         (float object 1.0f0))
        ((subtypep result-type 'double-float)
         (float object 1.0d0))
        ((subtypep result-type 'long-float)
         (float object 1.0l0))
        ((subtypep result-type 'float)
         (float object 1.0f0))
        ((subtypep result-type '(complex short-float))
         (complex (float (realpart object) 1.0s0) (float (imagpart object) 1.0s0)))
        ((subtypep result-type '(complex single-float))
         (complex (float (realpart object) 1.0f0) (float (imagpart object) 1.0f0)))
        ((subtypep result-type '(complex double-float))
         (complex (float (realpart object) 1.0d0) (float (imagpart object) 1.0d0)))
        ((subtypep result-type 'complex)
         (complex (realpart object) (imagpart object)))
        ((and (subtypep result-type 'function)
              (consp object)
              (eql (first object) 'lambda))
         (compile nil object))
        ((and (subtypep result-type 'function)
              (functionp object))
         object)
        ((and (subtypep result-type 'function)
              (typep object 'function-name))
         (fdefinition object))
        ((subtypep result-type 'character)
         (character object))
        (t (error 'unknown-coercion :object object :type result-type))))

(defun coerce (object result-type)
  (if (or (eql result-type 't)
          (typep object result-type))
      object
      (%coerce-value object result-type)))

(define-compiler-macro coerce (&whole whole object result-type &environment env)
  ;; Result type must be known.
  (cond ((or (eql result-type 't)
             (typep result-type '(cons (eql quote) (cons (eql t) null))))
         ;; Result-type is T.
         (return-from coerce object))
        ((typep result-type '(cons (eql quote) (cons t null)))
         (setf result-type (second result-type)))
        (t
         (return-from coerce whole)))
  (let ((obj (gensym "OBJECT")))
    `(let ((,obj ,object))
       (if (typep ,obj ',result-type)
           ,obj
           (%coerce-value ,obj ',result-type)))))
