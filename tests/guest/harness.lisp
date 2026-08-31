(in-package :lambda64.tests)

(defmacro define-test (name () &body body)
  `(push (cons ,name (lambda () ,@body)) *tests*))

(defmacro is (form)
  `(unless ,form
     (error "Test assertion failed: ~S" ',form)))

