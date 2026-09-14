#+xcvb (module (:depends-on ("pkgdcl")))

(in-package :asdf-encodings)

#|
;; Before we declare this file done, I propose we reimplement
;; an algorithm compatible with the one used by Emacs.
;; find-auto-coding is a compiled Lisp function in `mule.el'.
;; (find-auto-coding FILENAME SIZE)
;; Find a coding system for a file FILENAME of which SIZE bytes follow point.
;; These bytes should include at least the first 1k of the file ...
;; see also set-auto-coding
;; see also
;; http://www.gnu.org/software/emacs/manual/html_node/emacs/Specifying-File-Variables.html
;; http://www.emacswiki.org/cgi-bin/wiki?FileLocalVariables
;; hack-local-variables is a compiled Lisp function in `files.el`
;; (hack-local-variables &optional MODE-ONLY)
;; Parse and put into effect this buffer's local variables spec.
|#


;;;;; What's below is based on code by Douglas Crosher

;;; Examine the octect 'stream and returns three values:
;;;   1. True if valid UTF-8.
;;;   2. True if non-ASCII octets were found.
;;;      (If valid UTF-8, then only UTF-8 specific sequences were found.)
;;;   3. True if valid UTF-8 and the UTF-8 BOM was found at the start.
(defun detect-utf-8 (file)
  (with-open-file (stream file :direction :input
                          :element-type '(unsigned-byte 8))
    (flet ((extrap (c)
             (= (logand c #xc0) #x80))
           (b2-leading-p (c)
             (= (logand c #xe0) #xc0))
           (b3-leading-p (c)
             (= (logand c #xf0) #xe0))
           (b4-leading-p (c)
             (= (logand c #xf8) #xf0))
           (b5-leading-p (c)
             (= (logand c #xfc) #xf8)))
      (let ((bom-found-p nil)
            (nonasciip nil))
        (loop
          (let ((b (read-byte stream nil nil)))
            (cond ((not b)
                   (return))
                  ((< b #x80))
                  (t
                   (let ((b1 (read-byte stream nil nil)))
                     (cond ((or (not b1) (not (extrap b1)))
                            (return-from detect-utf-8
                              (values nil t nil)))
                           ((b2-leading-p b)
                            (setf nonasciip t))
                           (t
                            (let ((b2 (read-byte stream nil nil)))
                              (cond ((or (not b2) (not (extrap b2)))
                                     (return-from detect-utf-8
                                       (values nil t nil)))
                                    ((b3-leading-p b)
                                     (setf nonasciip t)
                                     (when (and nonasciip
                                                (= b #xef)
                                                (= b1 #xbb)
                                                (= b2 #xbf))
                                       (setf bom-found-p t)))
                                    (t
                                     (let ((b3 (read-byte stream nil nil)))
                                       (cond ((or (not b3) (not (extrap b3)))
                                              (return-from detect-utf-8
                                                (values nil t nil)))
                                             ((b4-leading-p b)
                                              (setf nonasciip t))
                                             (t
                                              (let ((b4 (read-byte stream nil nil)))
                                                (cond ((or (not b4) (not (extrap b4)))
                                                       (return-from detect-utf-8
                                                         (values nil t nil)))
                                                      ((b5-leading-p b)
                                                       (setf nonasciip t))
                                                      (t
                                                       (return-from detect-utf-8
                                                         (values nil t nil))))))))))))))))))
        (values t nonasciip bom-found-p)))))


(defun decode-ascii-encoded-declaration (buffer available start size offset)
  (declare (type fixnum start)
           (type (integer 1 4) size)
           (type (integer 0 3) offset))
  ;; Convert the buffered chunk to ASCII.
  (let ((ascii (make-string 1024 :initial-element #\?))
        (ascii-end 0))
    (do ()
        ((< available (+ start size)))
      (let* ((code (ecase size
                     (1
                      (aref buffer start))
                     (2
                      (let ((b0 (aref buffer start))
                            (b1 (aref buffer (1+ start))))
                        (ecase offset
                          (0
                           (logior (ash b1 8) b0))
                          (1
                           (logior (ash b0 8) b1)))))
                     (4
                      (let ((b0 (aref buffer start))
                            (b1 (aref buffer (+ start 1)))
                            (b2 (aref buffer (+ start 2)))
                            (b3 (aref buffer (+ start 3))))
                        (ecase offset
                          (0
                           (logior (ash b3 24) (ash b2 16) (ash b1 8) b0))
                          (1
                           (logior (ash b1 24) (ash b0 16) (ash b3 8) b2))
                          (2
                           (logior (ash b2 24) (ash b3 16) (ash b0 8) b1))
                          (3
                           (logior (ash b0 24) (ash b1 16) (ash b2 8) b3))))))))
        (incf start size)
        (let ((ch (if (< 0 code #x80) (code-char code) #\?)))
          (setf (aref ascii ascii-end) ch)
          (incf ascii-end))))
    ;; Parse the file options.
    (let ((found (search "-*-" ascii))
          (options nil))
      (when found
        (block do-file-options
          (let* ((start (+ found 3))
                 (end (search "-*-" ascii :start2 start)))
            (unless end
              ;; No closing "-*-".  Aborting file options.
              (return-from do-file-options))
            (unless (find #\: ascii :start start :end end)
              ;; Old style mode comment, or empty?
              (return-from do-file-options))
            (do ((opt-start start (1+ semi)) colon semi)
                (nil)
              (setf colon (position #\: ascii :start opt-start :end end))
              (unless colon
                ;; Missing ":".  Aborting file options.
                (return-from do-file-options))
              (setf semi (or (position #\; ascii :start colon :end end) end))
              (let ((option (string-trim '(#\space #\tab)
                                         (subseq ascii opt-start colon)))
                    (value (string-trim '(#\space #\tab)
                                        (subseq ascii (1+ colon) semi))))
                (push (cons option value) options)
                (when (= semi end) (return nil)))))))
      (flet ((try (x)
               (let ((o (cdr (assoc x options :test 'equalp))))
                 (when o
                   ;; strip Emacs-style EOL spec.
                   ;; TODO: find a way to integrate it in the external-format,
                   ;; on implementations that support it.
                   (when (equal "unix" (second (asdf::split-string o :max 2 :separator "-")))
                     (setf o (subseq o 0 (- (length o) 5))))
                   (intern (string-upcase o) :keyword)))))
        (or (try "external-format") (try "encoding") (try "coding"))))))

;;; Examine the file to determine the encoding.
;;; In some cases the encoding can be determined
;;; from the coding of the file itself,
;;; otherwise it may be specified in a file options line
;;; with the 'external-format', 'encoding', or 'coding' options.
;;; If the encoding is not detected or declared
;;; but is valid UTF-8 using then UTF-8 specific characters
;;; then :utf-8 is returned, otherwise :latin1 is returned.

(defun detect-buffer-encoding-header (buffer available)
  (flet ((x (initial-encoding &optional start size offset)
           (return-from detect-buffer-encoding-header (values initial-encoding start size offset))))
    (cond ((>= available 4)
           (let ((b1 (aref buffer 0))
                 (b2 (aref buffer 1))
                 (b3 (aref buffer 2))
                 (b4 (aref buffer 3)))
             (cond ((and (= b1 #x00) (= b2 #x00) (= b3 #xFE) (= b4 #xFF))
                    ;; UCS-4, big-endian (1234 order).
                    (x :ucs-4be 4 4 3))
                   ((and (= b1 #xff) (= b2 #xfe))
                    (cond ((and (= b3 #x00) (= b4 #x00))
                           ;; UCS-4, little-endian (4321 order).
                           (x :ucs-4le 4 4 0))
                          (t
                           ;; UTF-16, little-endian
                           (x :utf-16le 2 2 0))))
                   ((and (= b1 #x00) (= b2 #x00) (= b3 #xFF) (= b4 #xFE))
                    ;; UCS-4, order (2143).
                    (x nil 4 4 2))
                   ((and (= b1 #xfe) (= b2 #xff))
                    (cond ((and (= b3 #x00) (= b4 #x00))
                           ;; UCS-4, order (3412).
                           (x nil 4 4 1))
                          (t
                           ;; UTF-16, big-endian.
                           (x :utf-16be 2 2 1))))
                   ((and (= b1 #xEF) (= b2 #xBB) (= b3 #xBF))
                    ;; UTF-8 BOM.
                    (x :utf-8 3 1 0))
                   ;; Without a byte order mark, check for ASCII ';'.
                   ((and (= b1 #x3B) (= b2 #x00) (= b3 #x00) (= b4 #x00))
                    (x :ucs-4le 0 4 0))
                   ((and (= b1 #x00) (= b2 #x3B) (= b3 #x00) (= b4 #x00))
                    (x nil 0 4 1))
                   ((and (= b1 #x00) (= b2 #x00) (= b3 #x3B) (= b4 #x00))
                    (x nil 0 4 2))
                   ((and (= b1 #x00) (= b2 #x00) (= b3 #x00) (= b4 #x3B))
                    (x :ucs-4be 0 4 3))
                   ;; Check for ASCII ';;'.
                   ((and (= b1 #x3B) (= b2 #x00) (= b3 #x3B) (= b4 #x00))
                    (x :utf-16le 0 2 0))
                   ((and (= b1 #x00) (= b2 #x3B) (= b3 #x00) (= b4 #x3B))
                    (x :utf-16be 0 2 1))
                   ((and (= b1 #x3B) (= b2 #x3B))
                    (x :utf-8-auto 0 1 0))
                   ;;
                   ;; Check for UTF-7 ';'.
                   ((and (= b1 #x2B) (= b2 #x41) (= b3 #x44))
                    (x :utf-7))
                   ;;
                   ;; Check for ISO-2022-KR.
                   ((and (= b1 #x1B) (= b2 #x24) (= b3 #x29) (= b4 #x43))
                    (x :iso-2022-kr 4 1 0))
                   ;;
                   ;; Check for EBCDIC ';;'.
                   ((and (= b1 #x5e) (= b2 #x5e))
                    ;; EBCDIC - TODO read the declaration to determine the code page.
                    (x :ebcdic-us))
                   (t
                    ;; Not detected and no declaration, detect UTF-8.
                    (x :utf-8-auto)))))
          ((= available 3)
           (let ((b1 (aref buffer 0))
                 (b2 (aref buffer 1))
                 (b3 (aref buffer 2)))
             (cond ((and (= b1 #xEF) (= b2 #xBB) (= b3 #xBF))
                    ;; UTF-8 BOM.
                    (x :utf-8))
                   (t
                    (x :utf-8-auto)))))
          ((= available 2)
           (let ((b1 (aref buffer 0))
                 (b2 (aref buffer 1)))
             (cond ((and (= b1 #xff) (= b2 #xfe))
                    ;; UTF-16, little-endian
                    (x :utf-16le))
                   ((and (= b1 #xfe) (= b2 #xff))
                    ;; UTF-16, big-endian.
                    (x :utf-16be))
                   (t
                    (x :utf-8-auto)))))
          ((= available 1)
           (x (if (< (aref buffer 0) #x80) :ascii :latin1)))
          (t
           ;; Empty file - just use the default.
           (x :default)))))

(defun detect-file-encoding (file)
  (with-open-file (s file :element-type '(unsigned-byte 8)
                          :direction :input)
    ;; Buffer a chunk from the start of the file.
    (let* ((buffer (make-array 1024 :element-type '(unsigned-byte 8)))
           (available (read-sequence buffer s)))
      (multiple-value-bind (initial-encoding start size offset)
          (detect-buffer-encoding-header buffer available)
        (let ((declared-encoding
                (when start
                  (decode-ascii-encoded-declaration
                   buffer available start size offset))))
          (cond ((and (not initial-encoding) (not declared-encoding))
                 :latin1)
                ((or (and (not declared-encoding)
                          (eq initial-encoding :utf-8-auto))
                     (equalp declared-encoding :utf-8-auto))
                 (multiple-value-bind (valid-utf-8 nonasciip utf-8-bom)
                     (detect-utf-8 file)
                   (cond ((and valid-utf-8 (or nonasciip utf-8-bom))
                          :utf-8)
                         (nonasciip
                          :latin1)
                         (t
                          :ascii))))
                ((or (not declared-encoding)
                     (member initial-encoding '(:utf-16le :utf-16be
                                                :ucs-4le :ucs-4be)))
                 ;; Use the detected encoding.
                 initial-encoding)
                (t
                 declared-encoding)))))))
