;;;; Basic system configuration used during cold-load.

(in-package :mezzano.internals)

;; This is the local IP address of the system running the file-server.
(defparameter *file-server-host-ip* "192.168.0.123")

;; The full path to the Lambda64 source tree.
;; This must be a string, it must end with '/', and it must include a host portion.
(defparameter *mezzano-source-path* "REMOTE:/Full/path/to/Lambda64/")

;; The full path to the Lambda64 home directory, containing the libraries.
;; This must be a string, it must end with '/', and it must include a host portion.
(defparameter *home-directory-path* "REMOTE:/Full/path/to/home/directory/")
