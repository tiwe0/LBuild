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

(eval-when (:compile-toplevel :load-toplevel :execute)
(defun coerce-vector-element-type (type &optional environment)
  "Figure out the element type of the vector type TYPE."
  (cond
    ((or (subtypep type 'base-string environment)
         (subtypep type 'simple-base-string environment))
     'base-char)
    ((or (subtypep type 'string environment)
         (subtypep type 'simple-string environment))
     'character)
    ((or (subtypep type 'bit-vector environment)
         (subtypep type 'simple-bit-vector environment))
     'bit)
    (t (let* ((expanded-type (typeexpand type environment))
              (element-type (cond ((and (consp expanded-type)
                                        (member (first expanded-type) '(array simple-array)))
                                   (parse-array-type expanded-type))
                                  ((subtypep expanded-type 'vector environment)
                                   ;; Some generic vector type?
                                   't)
                                  (t
                                   nil))))
         (if (eql element-type '*)
             't
             element-type)))))
)

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
