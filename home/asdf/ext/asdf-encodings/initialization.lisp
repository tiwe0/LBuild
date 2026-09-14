#+xcvb (module (:depends-on ("encodings" "asdf-support" "autodetect")))

;;; Load-time Initialization.

(in-package :asdf-encodings)

(initialize-normalized-encodings)
(register-asdf-encodings)
