#+xcvb (module (:depends-on ("pkgdcl")))

(in-package :asdf-encodings)

(defvar *on-unsupported-encoding* :error
  "One of :error, :warn or nil, specifies what to do when passed an unsupported encoding.")

(defun encoding-external-format (encoding &key (on-error *on-unsupported-encoding*))
  (or (and (eq encoding :default) :default)
      (find-implementation-encoding (or (normalize-encoding encoding) encoding))
      (ecase on-error
        ((:error) (cerror "continue using :default" "unsupported encoding ~S" encoding) nil)
        ((:warn) (warn "unsupported encoding ~S, falling back to using :default " encoding) nil)
        ((nil) nil))
      :default))

(defun register-asdf-encodings ()
  (setf *encoding-external-format-hook* 'encoding-external-format
        *encoding-detection-hook* 'detect-file-encoding)
  (values))
