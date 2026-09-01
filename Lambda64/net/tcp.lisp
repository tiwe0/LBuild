;;; TCP
;;;
;;; Transmission Control Protocol - Protocol Specification
;;; https://tools.ietf.org/html/rfc793
;;;
;;; EFSM/SDL modeling of the original TCP standard (RFC793) and the
;;; Congestion Control Mechanism of TCP Reno
;;; http://www.medianet.kent.edu/techreports/TR2005-07-22-tcp-EFSM.pdf
;;;
;;; Computing TCP's Retransmission Timer
;;; https://tools.ietf.org/html/rfc6298

(in-package :mezzano.network.tcp)

(defconstant +tcp4-header-source-port+ 0)
(defconstant +tcp4-header-destination-port+ 2)
(defconstant +tcp4-header-sequence-number+ 4)
(defconstant +tcp4-header-acknowledgment-number+ 8)
(defconstant +tcp4-header-flags-and-data-offset+ 12)
(defconstant +tcp4-header-window-size+ 14)
(defconstant +tcp4-header-checksum+ 16)
(defconstant +tcp4-header-urgent-pointer+ 18)

(defconstant +tcp4-flag-fin+ #b00000001)
(defconstant +tcp4-flag-syn+ #b00000010)
(defconstant +tcp4-flag-rst+ #b00000100)
(defconstant +tcp4-flag-psh+ #b00001000)
(defconstant +tcp4-flag-ack+ #b00010000)
(defconstant +tcp4-flag-urg+ #b00100000)
(defconstant +tcp4-flag-ece+ #b01000000)
(defconstant +tcp4-flag-cwr+ #b10000000)

;; DEFPARAMETER, not DEFCONSTANT, due to cross-compiler constraints.
(defparameter +ip-wildcard+ (mezzano.network.ip:make-ipv4-address "0.0.0.0"))
(defconstant +port-wildcard+ 0)

(defparameter *tcp-connect-timeout* 10)
(defparameter *tcp-syn-received-timeout* 10)
(defparameter *tcp-initial-retransmit-time* 1)
(defparameter *minimum-rto* 1) ;; in seconds
(defparameter *maximum-rto* 60) ;; in seconds

(defparameter *initial-window-size* 8192)

(defparameter *netmangler-force-local-retransmit* nil
  "If true, then all data segments will be initially dropped
and forced to be sent from the retransmit queue.")
(defparameter *netmangler-iss* nil
  "Force the ISS to this value.
Set to a value near 2^32 to test SND sequence number wrapping.")

(defvar *tcp-connections* nil)
(defvar *tcp-connection-lock* (mezzano.supervisor:make-mutex "TCP connection list"))
(defvar *tcp-listeners* nil)
(defvar *tcp-listener-lock* (mezzano.supervisor:make-mutex "TCP listener list"))

(deftype tcp-connection-state ()
  "Possible states that a TCP connection can have."
  '(member
    :closed
    :syn-sent
    :syn-received
    :established
    :close-wait
    :last-ack
    :fin-wait-1
    :fin-wait-2
    :closing))

(deftype tcp-port-number ()
  '(unsigned-byte 16))

(deftype tcp-sequence-number ()
  '(unsigned-byte 32))

(defun +u32 (x y)
  (ldb (byte 32 0) (+ x y)))

(defun -u32 (x y)
  (ldb (byte 32 0) (- x y)))

(defun tcp-sequence< (x y)
  "Compare two TCP sequence numbers in serial-number space."
  (let ((distance (-u32 y x)))
    (and (not (zerop distance))
         (< distance #x80000000))))

(defun tcp-sequence<= (x y)
  (or (eql x y) (tcp-sequence< x y)))

(defclass tcp-listener ()
  ((local-port :reader tcp-listener-local-port
               :initarg :local-port
               :type tcp-port-number)
   (local-ip :reader tcp-listener-local-ip
             :initarg :local-ip
             :type mezzano.network.ip::ipv4-address)
   (pending-connections :reader tcp-listener-pending-connections
                        :initarg :pending-connections
                        :type hash-table)
   (connections :reader tcp-listener-connections
                :initarg :connections
                :type mezzano.sync:mailbox)
   (n-pending-connections :accessor tcp-listener-n-pending-connections
                          :initarg :n-pending-connections
                          :type integer)
   (backlog :reader tcp-listener-backlog
            :initarg :backlog)
   (%lock :reader tcp-listener-lock)
   (%closed-p :accessor tcp-listener-closed-p :initform nil))
  (:default-initargs :n-pending-connections 0))

(defmethod initialize-instance :after ((instance tcp-listener) &key)
  (setf (slot-value instance '%lock)
        (mezzano.supervisor:make-mutex instance)))

(defmacro with-tcp-listener-locked (listener &body body)
  `(mezzano.supervisor:with-mutex ((tcp-listener-lock ,listener)
                                   :resignal-errors t)
     ,@body))

(defmethod mezzano.sync:get-object-event ((object tcp-listener))
  (mezzano.sync:get-object-event (tcp-listener-connections object)))

(defmethod mezzano.network:local-endpoint ((object tcp-listener))
  (values (tcp-listener-local-ip object)
          (tcp-listener-local-port object)))

(defmethod print-object ((instance tcp-listener) stream)
  (print-unreadable-object (instance stream :type t :identity t)
    (format stream "~A:~A"
            (tcp-listener-local-ip instance)
            (tcp-listener-local-port instance))))

(defun get-tcp-listener-without-lock (local-ip local-port)
  (dolist (listener *tcp-listeners*)
    (when (and (or (mezzano.network.ip:address-equal
                    (tcp-listener-local-ip listener) local-ip)
                   (mezzano.network.ip:address-equal
                    (tcp-listener-local-ip listener) +ip-wildcard+))
               (eql (tcp-listener-local-port listener) local-port))
      (return listener))))

(defun get-tcp-listener (local-ip local-port)
  (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
    (get-tcp-listener-without-lock local-ip local-port)))

(defun tcp-listen (local-host local-port &key backlog)
  (let* ((local-ip (mezzano.network:resolve-address local-host))
         (source-address (if (mezzano.network.ip:address-equal local-ip +ip-wildcard+)
                             +ip-wildcard+
                             (mezzano.network.ip:ipv4-interface-address
                              (nth-value 1 (mezzano.network.ip:ipv4-route local-ip))))))
    (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
      (let* ((local-port (cond ((eql local-port +port-wildcard+)
                                ;; find a suitable port number
                                (loop :for local-port := (+ (random 32768) 32768)
                                      :unless (get-tcp-listener-without-lock source-address local-port)
                                      :do (return local-port)))
                               ((get-tcp-listener-without-lock source-address local-port)
                                (error "Server already listening on port ~D" local-port))
                               (t
                                local-port)))
             (listener (make-instance 'tcp-listener
                                      :pending-connections (make-hash-table :test 'equalp :synchronized t)
                                      :connections (mezzano.sync:make-mailbox
                                                    :name "TCP Listener")
                                      :backlog backlog
                                      :local-port local-port
                                      :local-ip source-address)))
        (push listener *tcp-listeners*)
        listener))))

(defun tcp-accept (listener &key (wait-p t) element-type external-format)
  (let ((connection (mezzano.sync:mailbox-receive
                     (tcp-listener-connections listener)
                     :wait-p wait-p)))
    (when connection
      (if (tcp-listener-complete-accept listener connection)
          (return-from tcp-accept
            (tcp4-accept-connection connection
                                    :element-type element-type
                                    :external-format external-format))
          ;; CLOSE won the listener lock after the mailbox receive. Do not
          ;; leak a live, no-longer-owned connection to the caller.
          (abort-connection connection)))
    nil))

(defun tcp-listener-complete-accept (listener connection)
  "Linearize a mailbox receive against listener close."
  (declare (ignore connection))
  (with-tcp-listener-locked listener
    (when (not (tcp-listener-closed-p listener))
      (when (and (tcp-listener-backlog listener)
                 (plusp (tcp-listener-n-pending-connections listener)))
        (decf (tcp-listener-n-pending-connections listener)))
      t)))

(defun close-tcp-listener (listener)
  (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
    (setf *tcp-listeners* (remove listener *tcp-listeners*)))
  (let ((pending-connections nil)
        (accepted-connections nil))
    (with-tcp-listener-locked listener
      (setf (tcp-listener-closed-p listener) t
            pending-connections
            (loop for connection being the hash-values
                    of (tcp-listener-pending-connections listener)
                  collect connection)
            accepted-connections
            (mezzano.sync:mailbox-flush
             (tcp-listener-connections listener))
            (tcp-listener-n-pending-connections listener) 0)
      (clrhash (tcp-listener-pending-connections listener)))
    (dolist (connection (append pending-connections accepted-connections))
      (with-tcp-connection-locked connection
        (abort-connection connection)))))

(defun tcp-listener-remove-pending (listener connection &key accepted-p)
  "Remove CONNECTION from LISTENER's half-open set exactly once."
  (when listener
    (with-tcp-listener-locked listener
      (when (remhash connection
                     (tcp-listener-pending-connections listener))
        (when (and (not accepted-p)
                   (tcp-listener-backlog listener)
                   (plusp (tcp-listener-n-pending-connections listener)))
          (decf (tcp-listener-n-pending-connections listener)))
        (when (and accepted-p
                   (not (tcp-listener-closed-p listener)))
          (mezzano.sync:mailbox-send
           connection
           (tcp-listener-connections listener)))
        t))))

(defun tcp-listener-accepts-passive-open-p (listener)
  "Return true when a locked listener may reserve another passive open."
  (and (not (tcp-listener-closed-p listener))
       (or (not (tcp-listener-backlog listener))
           (< (tcp-listener-n-pending-connections listener)
              (tcp-listener-backlog listener)))))

(defclass tcp-connection ()
  ((%state :accessor tcp-connection-state
           :initarg :state
           :type tcp-connection-state)
   (%local-port :reader tcp-connection-local-port
                :initarg :local-port
                :type tcp-port-number)
   (%local-ip :reader tcp-connection-local-ip
              :initarg :local-ip
              :type mezzano.network.ip::ipv4-address)
   (%remote-port :reader tcp-connection-remote-port
                 :initarg :remote-port
                 :type tcp-port-number)
   (%remote-ip :reader tcp-connection-remote-ip
               :initarg :remote-ip
               :type mezzano.network.ip::ipv4-address)
   (%snd.nxt :accessor tcp-connection-snd.nxt
             :initarg :snd.nxt
             :type tcp-sequence-number)
   (%snd.una :accessor tcp-connection-snd.una
             :initarg :snd.una)
   (%snd.wnd :accessor tcp-connection-snd.wnd
             :initarg :snd.wnd)
   (%snd.wl1 :accessor tcp-connection-snd.wl1
             :initarg :snd.wl1)
   (%snd.wl2 :accessor tcp-connection-snd.wl2
             :initarg :snd.wl2)
   (%rcv.nxt :accessor tcp-connection-rcv.nxt
             :initarg :rcv.nxt
             :type tcp-sequence-number)
   (%rcv.wnd :accessor tcp-connection-rcv.wnd :initarg :rcv.wnd)
   (%max-seg-size :accessor tcp-connection-max-seg-size :initarg :max-seg-size)
   (%rx-data :accessor tcp-connection-rx-data :initform '())
   ;; Doesn't need to be synchronized, only accessed from the network serial queue.
   (%rx-data-unordered :reader tcp-connection-rx-data-unordered
                       :initform (make-hash-table))
   (%last-ack-time :accessor tcp-connection-last-ack-time :initarg :last-ack-time)
   (%srtt :accessor tcp-connection-srtt :initarg :srtt)
   (%rttvar :accessor tcp-connection-rttvar :initarg :rttvar)
   (%rto :accessor tcp-connection-rto :initarg :rto)
   (%retransmit-queue :accessor tcp-connection-retransmit-queue :initform '())
   (%tx-data :accessor tcp-connection-tx-data :initform '())
   (%congestion-window :accessor tcp-connection-congestion-window
                       :initarg :congestion-window)
   (%slow-start-threshold :accessor tcp-connection-slow-start-threshold
                          :initarg :slow-start-threshold)
   (%duplicate-acks :accessor tcp-connection-duplicate-acks
                    :initform 0)
   (%listener :reader tcp-connection-listener :initarg :listener)
   (%lock :reader tcp-connection-lock)
   (%cvar :reader tcp-connection-cvar)
   (%receive-event :reader tcp-connection-receive-event)
   (%pending-error :accessor tcp-connection-pending-error :initform nil)
   (%abort-pending-p :accessor tcp-connection-abort-pending-p :initform nil)
   (%retransmit-timer :reader tcp-connection-retransmit-timer)
   (%retransmit-source :reader tcp-connection-retransmit-source)
   (%timeout-timer :reader tcp-connection-timeout-timer)
   (%timeout-source :reader tcp-connection-timeout-source)
   (%timeout :initarg :timeout :reader tcp-connection-timeout)
   (%boot-id :reader tcp-connection-boot-id
             :initarg :boot-id))
  (:default-initargs
   :max-seg-size 1000
   :snd.wnd 0
   :snd.wl1 0
   :snd.wl2 0
   :congestion-window nil
   :slow-start-threshold #xFFFF
   :listener nil
   :last-ack-time nil
   :srtt nil
   :rttvar nil
   :rto *tcp-initial-retransmit-time*
   :boot-id nil
   :timeout nil))

(defun (setf tcp-connection-timeout) (timeout connection)
  (with-tcp-connection-locked connection
    (setf (slot-value connection '%timeout) timeout)
    (update-timeout-timer connection)))

(defun arm-retransmit-timer (connection)
  (mezzano.supervisor:timer-arm (tcp-connection-rto connection)
                                (tcp-connection-retransmit-timer connection))
  (values))

(defun disarm-retransmit-timer (connection)
  (mezzano.supervisor:timer-disarm (tcp-connection-retransmit-timer connection))
  (values))

(defun retransmit-timer-handler (connection)
  (when (not (mezzano.supervisor:timer-expired-p
              (tcp-connection-retransmit-timer connection)))
    ;; Timer is either still pending or isn't actually running.
    ;; This can happen if the timer expires but some other task reconfigures
    ;; a new retransmit time.
    (return-from retransmit-timer-handler))
  (mezzano.supervisor:with-mutex ((tcp-connection-lock connection))
    ;; Disarm it so it stops triggering the source
    (mezzano.supervisor:timer-disarm (tcp-connection-retransmit-timer connection))
    (when (tcp-connection-abort-pending-p connection)
      (return-from retransmit-timer-handler))
    ;; What're we retransmitting?
    (ecase (tcp-connection-state connection)
      (:syn-sent
       (let ((seq (-u32 (tcp-connection-snd.nxt connection) 1)))
         (tcp4-send-packet connection seq 0 nil :ack-p nil :syn-p t)
         (arm-retransmit-timer connection)))
      (:syn-received
       (tcp4-send-packet connection
                         (-u32 (tcp-connection-snd.nxt connection) 1)
                         (tcp-connection-rcv.nxt connection)
                         nil
                         :ack-p t
                         :syn-p t)
       (setf (tcp-connection-rto connection)
             (min *maximum-rto* (* 2 (tcp-connection-rto connection))))
       (arm-retransmit-timer connection))
      ((:established
        :close-wait
        :last-ack
        :fin-wait-1
        :fin-wait-2
       :closing)
       (let ((packet (first (tcp-connection-retransmit-queue connection))))
         (let* ((mss (tcp-connection-max-seg-size connection))
                (flight (-u32 (tcp-connection-snd.nxt connection)
                              (tcp-connection-snd.una connection))))
           (setf (tcp-connection-slow-start-threshold connection)
                 (max (floor flight 2) (* 2 mss))
                 (tcp-connection-congestion-window connection) mss
                 (tcp-connection-duplicate-acks connection) 0))
         (apply #'tcp4-send-packet connection packet)
         (setf (tcp-connection-rto connection)
               (min *maximum-rto* (* 2 (tcp-connection-rto connection))))
         (arm-retransmit-timer connection))))))

(defun arm-timeout-timer (seconds connection)
  (mezzano.supervisor:timer-arm seconds
                                (tcp-connection-timeout-timer connection))
  (values))

(defun disarm-timeout-timer (connection)
  (mezzano.supervisor:timer-disarm (tcp-connection-timeout-timer connection))
  (values))

(defun timeout-timer-handler (connection)
  (when (not (mezzano.supervisor:timer-expired-p
              (tcp-connection-timeout-timer connection)))
    ;; Timer is either still pending or isn't actually running.
    ;; This can happen if the timer expires but some other task reconfigures
    ;; a new timeout time.
    (return-from timeout-timer-handler))
  (mezzano.supervisor:with-mutex ((tcp-connection-lock connection))
    ;; Disarm it so it stops triggering the source
    (mezzano.supervisor:timer-disarm (tcp-connection-timeout-timer connection))
    (setf (tcp-connection-pending-error connection)
          (make-condition 'connection-timed-out
                          :host (tcp-connection-remote-ip connection)
                          :port (tcp-connection-remote-port connection)))
    (mezzano.supervisor:condition-notify (tcp-connection-cvar connection) t)
    (case (tcp-connection-state connection)
      ((:syn-sent :syn-received)
       (tcp-listener-remove-pending (tcp-connection-listener connection)
                                    connection)
       (detach-tcp-connection connection))
      (:closed)
      (t
       (close-connection connection)))))

(defmethod initialize-instance :after ((instance tcp-connection) &key)
  (setf (slot-value instance '%lock) (mezzano.supervisor:make-mutex instance)
        (slot-value instance '%cvar) (mezzano.supervisor:make-condition-variable instance)
        (slot-value instance '%receive-event) (mezzano.supervisor:make-event :name `(:data-available ,instance))
        (slot-value instance '%retransmit-timer) (mezzano.supervisor:make-timer :name `(:tcp-retransmit ,instance))
        (slot-value instance '%timeout-timer) (mezzano.supervisor:make-timer :name `(:tcp-timeout ,instance)))
  (when (not (tcp-connection-congestion-window instance))
    (let ((mss (tcp-connection-max-seg-size instance)))
      (setf (tcp-connection-congestion-window instance)
            (min (* 4 mss) (max (* 2 mss) 4380)))))
  (setf (slot-value instance '%retransmit-source)
        (mezzano.sync.dispatch:make-source (tcp-connection-retransmit-timer instance)
                                           (lambda ()
                                             (retransmit-timer-handler instance))
                                           :target net::*network-serial-queue*))
  (setf (slot-value instance '%timeout-source)
        (mezzano.sync.dispatch:make-source (tcp-connection-timeout-timer instance)
                                           (lambda ()
                                             (timeout-timer-handler instance))
                                           :target net::*network-serial-queue*)))

(defmethod print-object ((instance tcp-connection) stream)
  (print-unreadable-object (instance stream :type t :identity t)
    (format stream "~A :local ~A:~A :remote ~A:~A"
            (tcp-connection-state instance)
            (tcp-connection-local-ip instance)
            (tcp-connection-local-port instance)
            (tcp-connection-remote-ip instance)
            (tcp-connection-remote-port instance))))

(defmacro with-tcp-connection-locked (connection &body body)
  `(mezzano.supervisor:with-mutex ((tcp-connection-lock ,connection) :resignal-errors t)
     ,@body))

(defun get-tcp-connection (remote-ip remote-port local-ip local-port)
  (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
    (dolist (connection *tcp-connections*)
      (when (and (mezzano.network.ip:address-equal
                  (tcp-connection-remote-ip connection)
                  remote-ip)
                 (eql (tcp-connection-remote-port connection) remote-port)
                 (mezzano.network.ip:address-equal
                  (tcp-connection-local-ip connection)
                  local-ip)
                 (eql (tcp-connection-local-port connection) local-port))
        (return connection)))))

(defun tcp4-open-passive (listener packet start end
                          local-ip local-port remote-ip remote-port)
  "Create one half-open inbound connection while holding LISTENER's lock."
  (declare (ignore end))
  (with-tcp-listener-locked listener
    (when (tcp-listener-accepts-passive-open-p listener)
      (let* ((irs (ub32ref/be packet
                             (+ start +tcp4-header-sequence-number+)))
             (iss (or *netmangler-iss* (random #x100000000)))
             (connection
               (make-instance 'tcp-connection
                              :state :syn-received
                              :local-port local-port
                              :local-ip local-ip
                              :remote-port remote-port
                              :remote-ip remote-ip
                              :snd.nxt (+u32 iss 1)
                              :snd.una iss
                              :snd.wnd (ub16ref/be
                                        packet
                                        (+ start +tcp4-header-window-size+))
                              :snd.wl1 irs
                              :snd.wl2 iss
                              :rcv.nxt (+u32 irs 1)
                              :rcv.wnd *initial-window-size*
                              :listener listener
                              :boot-id
                              (mezzano.supervisor:current-boot-id))))
        (when (tcp-listener-backlog listener)
          (incf (tcp-listener-n-pending-connections listener)))
        (setf (gethash connection
                       (tcp-listener-pending-connections listener))
              connection)
        (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
          (push connection *tcp-connections*))
        (setf (tcp-connection-last-ack-time connection)
              (get-internal-run-time))
        (when (not *netmangler-force-local-retransmit*)
          (tcp4-send-packet connection iss (+u32 irs 1) nil
                            :ack-p t :syn-p t))
        (arm-retransmit-timer connection)
        (arm-timeout-timer *tcp-syn-received-timeout* connection)
        connection))))

(defmethod mezzano.network.ip:ipv4-receive ((protocol (eql mezzano.network.ip:+ip-protocol-tcp+)) packet local-ip remote-ip start end)
  (let* ((remote-port (ub16ref/be packet (+ start +tcp4-header-source-port+)))
         (local-port (ub16ref/be packet (+ start +tcp4-header-destination-port+)))
         (flags (ldb (byte 12 0)
                     (ub16ref/be packet (+ start +tcp4-header-flags-and-data-offset+))))
         (connection (get-tcp-connection remote-ip remote-port local-ip local-port))
         (listener (get-tcp-listener local-ip local-port)))
    (cond (connection
           (tcp4-connection-receive connection packet start end listener))
          ;; A listener serializes backlog accounting against ACCEPT and CLOSE.
          ((and listener (eql flags +tcp4-flag-syn+))
           (tcp4-open-passive listener packet start end
                              local-ip local-port remote-ip remote-port))
          ((logtest flags +tcp4-flag-rst+)) ; Do nothing for resets addressed to nobody.
          (t
           (let* ((seq (if (logtest flags +tcp4-flag-ack+)
                           (tcp-packet-acknowledgment-number packet start end)
                           0))
                  (ack (+u32 (tcp-packet-sequence-number packet start end)
                             (tcp-packet-data-length packet start end)))
                  (packet (assemble-tcp4-packet local-ip local-port
                                                remote-ip remote-port
                                                seq ack
                                                0
                                                nil
                                                :ack-p (logtest flags +tcp4-flag-ack+)
                                                :rst-p t)))
             (mezzano.network.ip:transmit-ipv4-packet
              local-ip remote-ip
              mezzano.network.ip:+ip-protocol-tcp+ packet))))))

(defun tcp4-accept-connection (connection &key element-type external-format)
  (cond ((or (not element-type)
             (sys.int::type-equal element-type 'character))
         (make-instance 'tcp-stream
                        :connection connection
                        :external-format (sys.int::make-external-format
                                          (or element-type 'character)
                                          (or external-format :default)
                                          :eol-style :crlf)))
        ((sys.int::type-equal element-type '(unsigned-byte 8))
         (assert (or (not external-format)
                     (eql external-format :default)))
         (make-instance 'tcp-octet-stream
                        :connection connection))
        (t
         (error "Unsupported element type ~S" element-type))))

;; Note - must be called on the network queue.
(defun detach-tcp-connection (connection)
  ;; Disarming here is doubly important.
  ;; 1) It stops the timer from hanging around if it was active.
  ;; 2) If the source handler is pending, then it'll return immediately.
  (setf (tcp-connection-state connection) :closed)
  (mezzano.supervisor:timer-disarm (tcp-connection-retransmit-timer connection))
  (mezzano.supervisor:timer-disarm (tcp-connection-timeout-timer connection))
  (mezzano.sync.dispatch:cancel (tcp-connection-retransmit-source connection))
  (mezzano.sync.dispatch:cancel (tcp-connection-timeout-source connection))
  (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
    (setf *tcp-connections* (remove connection *tcp-connections*))))

(defun append-data-packet (connection entry)
  (if (tcp-connection-rx-data connection)
      (setf (cdr (last (tcp-connection-rx-data connection)))
            (list entry))
      (setf (tcp-connection-rx-data connection)
            (list entry))))

(defun update-unordered-data (connection)
  "Try to find any out-of-order data in CONNECTION that is now in-order."
  ;; Check if the next packet is in tcp-connection-rx-data-unordered
  (loop
     :for (packet start end data-length)
     := (gethash (tcp-connection-rcv.nxt connection)
                 (tcp-connection-rx-data-unordered connection))
     :always packet
     :do (remhash (tcp-connection-rcv.nxt connection)
                  (tcp-connection-rx-data-unordered connection))
     :do (append-data-packet connection (list packet start end))
     :do (setf (tcp-connection-rcv.nxt connection)
               (+u32 (tcp-connection-rcv.nxt connection) data-length))))

(defun tcp4-receive-data (connection data-length end header-length packet seq start)
  (cond ((= seq (tcp-connection-rcv.nxt connection))
         ;; Send data to the user layer
         (append-data-packet connection (list packet (+ start header-length) end))
         (setf (tcp-connection-rcv.nxt connection)
               (+u32 (tcp-connection-rcv.nxt connection) data-length))
         (update-unordered-data connection)
         (setf (mezzano.supervisor:event-state
                (tcp-connection-receive-event connection))
               t))
        ;; Add future packet to tcp-connection-rx-data-unordered
        ((> seq (tcp-connection-rcv.nxt connection))
         (unless (gethash seq (tcp-connection-rx-data-unordered connection))
           (setf (gethash seq (tcp-connection-rx-data-unordered connection))
                 (list packet (+ start header-length) end data-length)))))
  (when (<= seq (tcp-connection-rcv.nxt connection))
    ;; Don't check *netmangler-force-local-retransmit* here,
    ;; or no acks will ever get through.
    (tcp4-send-packet connection
                      (tcp-connection-snd.nxt connection)
                      (tcp-connection-rcv.nxt connection)
                      nil
                      :ack-p t)))

(defun tcp-packet-sequence-number (packet start end)
  (declare (ignore end))
  (ub32ref/be packet (+ start +tcp4-header-sequence-number+)))

(defun tcp-packet-acknowledgment-number (packet start end)
  (declare (ignore end))
  (ub32ref/be packet (+ start +tcp4-header-acknowledgment-number+)))

(defun tcp-packet-flags (packet start end)
  (declare (ignore end))
  (ldb (byte 12 0) (ub16ref/be packet (+ start +tcp4-header-flags-and-data-offset+))))

(defun tcp-packet-header-length (packet start end)
  (declare (ignore end))
  (* (ldb (byte 4 12) (ub16ref/be packet (+ start +tcp4-header-flags-and-data-offset+))) 4))

(defun tcp-packet-data-length (packet start end)
  (- end (+ start (tcp-packet-header-length packet start end))))

(defun tcp-packet-window (packet start end)
  (declare (ignore end))
  (ub16ref/be packet (+ start +tcp4-header-window-size+)))

(defun acceptable-segment-p (connection packet start end)
  (let ((rcv.wnd (tcp-connection-rcv.wnd connection))
        (rcv.nxt (tcp-connection-rcv.nxt connection))
        (seg.seq (tcp-packet-sequence-number packet start end))
        (seg.len (tcp-packet-data-length packet start end)))
    (if (eql rcv.wnd 0)
        (and (eql seg.len 0)
             (eql seg.seq rcv.nxt))
        (flet ((in-window-p (sequence)
                 (and (tcp-sequence<= rcv.nxt sequence)
                      (tcp-sequence< sequence (+u32 rcv.nxt rcv.wnd)))))
          (or (in-window-p seg.seq)
              (and (plusp seg.len)
                   (in-window-p (-u32 (+u32 seg.seq seg.len) 1))))))))

(defun tcp-reset-acceptable-p (connection packet start end)
  "Return true when PACKET's RST is valid for CONNECTION's current state."
  (case (tcp-connection-state connection)
    (:syn-sent
     (and (logtest (tcp-packet-flags packet start end) +tcp4-flag-ack+)
          (eql (tcp-packet-acknowledgment-number packet start end)
               (tcp-connection-snd.nxt connection))))
    (t
     (acceptable-segment-p connection packet start end))))

(defun tcp-update-send-window (connection seg.seq seg.ack seg.window)
  "Apply RFC 793 SND.WL1/SND.WL2 ordering to an advertised window update."
  (when (or (tcp-sequence< (tcp-connection-snd.wl1 connection) seg.seq)
            (and (eql (tcp-connection-snd.wl1 connection) seg.seq)
                 (tcp-sequence<= (tcp-connection-snd.wl2 connection)
                                 seg.ack)))
    (setf (tcp-connection-snd.wnd connection) seg.window
          (tcp-connection-snd.wl1 connection) seg.seq
          (tcp-connection-snd.wl2 connection) seg.ack)
    t))

(defun tcp-flight-size (connection)
  (-u32 (tcp-connection-snd.nxt connection)
        (tcp-connection-snd.una connection)))

(defun tcp-note-new-ack (connection previous-una ack)
  "Advance Reno congestion control after ACK moves SND.UNA forward."
  (let* ((mss (tcp-connection-max-seg-size connection))
         (acked (-u32 ack previous-una))
         (cwnd (tcp-connection-congestion-window connection)))
    (cond ((>= (tcp-connection-duplicate-acks connection) 3)
           (setf (tcp-connection-congestion-window connection)
                 (tcp-connection-slow-start-threshold connection)))
          ((< cwnd (tcp-connection-slow-start-threshold connection))
           (incf (tcp-connection-congestion-window connection)
                 (min acked mss)))
          (t
           (incf (tcp-connection-congestion-window connection)
                 (max 1 (floor (* mss mss) cwnd)))))
    (setf (tcp-connection-duplicate-acks connection) 0)))

(defun tcp-note-duplicate-ack (connection)
  "Perform Reno duplicate-ACK accounting and fast retransmit."
  (when (tcp-connection-retransmit-queue connection)
    ;; This implementation does not implement per-duplicate transmission while
    ;; in fast recovery. Cap the counter at the transition threshold instead of
    ;; inflating CWND without sending the additional permitted segment.
    (when (< (tcp-connection-duplicate-acks connection) 3)
      (incf (tcp-connection-duplicate-acks connection))
      (when (eql (tcp-connection-duplicate-acks connection) 3)
        (let ((mss (tcp-connection-max-seg-size connection)))
          (setf (tcp-connection-slow-start-threshold connection)
                (max (floor (tcp-flight-size connection) 2) (* 2 mss))
                (tcp-connection-congestion-window connection)
                (+ (tcp-connection-slow-start-threshold connection)
                   (* 3 mss)))
          (apply #'tcp4-send-packet
                 connection
                 (first (tcp-connection-retransmit-queue connection))))))))

(defun update-timeout-timer (connection)
  (case (tcp-connection-state connection)
    (:syn-sent)
    (:syn-received
     (disarm-timeout-timer connection)
     (arm-timeout-timer *tcp-syn-received-timeout* connection))
    (t
     (disarm-timeout-timer connection)
     (let ((timeout (tcp-connection-timeout connection)))
       (when (and timeout
                  (not (member (tcp-connection-state connection)
                               '(:fin-wait-1 :fin-wait-2 :last-ack :closed))))
         (arm-timeout-timer timeout connection))))))

(defun initial-rtt-measurement (connection)
  (let ((delta-time (float (/ (- (get-internal-run-time) (tcp-connection-last-ack-time connection))
                              internal-time-units-per-second))))
    (setf (tcp-connection-srtt connection) delta-time
          (tcp-connection-rttvar connection) (/ delta-time 2))
    (setf (tcp-connection-rto connection)
          (min *maximum-rto*
               (max *minimum-rto*
                    (+ (tcp-connection-srtt connection)
                       (max 0.01 (* 4 (tcp-connection-rttvar connection))))))
          (tcp-connection-last-ack-time connection) nil)))

(defun subsequent-rtt-measurement (connection)
  (let ((delta-time (float (/ (- (get-internal-run-time) (tcp-connection-last-ack-time connection))
                              internal-time-units-per-second))))
    (setf (tcp-connection-rttvar connection)
          (+ (* 0.75 (tcp-connection-rttvar connection))
             (* 0.25 (- (tcp-connection-srtt connection) delta-time))))
    (setf (tcp-connection-srtt connection)
          (+ (* 0.875 (tcp-connection-srtt connection))
             (* 0.125 delta-time)))
    (setf (tcp-connection-rto connection)
          (min *maximum-rto*
               (max *minimum-rto*
                    (+ (tcp-connection-srtt connection)
                       (max 0.01 (* 4 (tcp-connection-rttvar connection))))))
          (tcp-connection-last-ack-time connection) nil)))

(defun tcp4-connection-receive (connection packet start end listener)
  ;; Don't use WITH-TCP-CONNECTION-LOCKED here. No errors should occur
  ;; in here, so this avoids truncating the backtrace with :resignal-errors.
  (mezzano.supervisor:with-mutex ((tcp-connection-lock connection))
    (when (tcp-connection-abort-pending-p connection)
      (return-from tcp4-connection-receive))
    (let* ((seq (tcp-packet-sequence-number packet start end))
           (ack (tcp-packet-acknowledgment-number packet start end))
           (flags (tcp-packet-flags packet start end))
           (window (tcp-packet-window packet start end))
           (header-length (tcp-packet-header-length packet start end))
           (data-length (tcp-packet-data-length packet start end)))
      (when (logtest flags +tcp4-flag-rst+)
        (cond ((tcp-reset-acceptable-p connection packet start end)
               (setf (tcp-connection-pending-error connection)
                     (make-condition 'connection-reset
                                     :host (tcp-connection-remote-ip connection)
                                     :port (tcp-connection-remote-port connection)))
               (tcp-listener-remove-pending
                (tcp-connection-listener connection)
                connection)
               (detach-tcp-connection connection)
               (mezzano.supervisor:condition-notify
                (tcp-connection-cvar connection) t))
              ((not (eql (tcp-connection-state connection) :syn-sent))
               ;; Challenge an out-of-window reset without changing state.
               (tcp4-send-packet connection
                                 (tcp-connection-snd.nxt connection)
                                 (tcp-connection-rcv.nxt connection)
                                 nil
                                 :ack-p t)))
        (return-from tcp4-connection-receive))
      ;; :CLOSED should never be seen here
      (ecase (tcp-connection-state connection)
        (:syn-sent
         ;; Active open
         (cond ((and (logtest flags +tcp4-flag-ack+)
                     (logtest flags +tcp4-flag-syn+)
                     (eql ack (tcp-connection-snd.nxt connection)))
                ;; Remote has sent SYN+ACK and waiting for ACK
                (initial-rtt-measurement connection)
                (setf (tcp-connection-state connection) :established)
                (setf (tcp-connection-rcv.nxt connection) (+u32 seq 1))
                (setf (tcp-connection-snd.una connection) ack
                      (tcp-connection-snd.wnd connection) window
                      (tcp-connection-snd.wl1 connection) seq
                      (tcp-connection-snd.wl2 connection) ack)
                (when (not *netmangler-force-local-retransmit*)
                  (tcp4-send-packet connection ack (tcp-connection-rcv.nxt connection) nil))
                ;; Cancel retransmit
                (disarm-retransmit-timer connection)
                (disarm-timeout-timer connection))
               ((logtest flags +tcp4-flag-syn+)
                ;; Simultaneous open
                (setf (tcp-connection-state connection) :syn-received
                      (tcp-connection-rcv.nxt connection) (+u32 seq 1)
                      (tcp-connection-snd.wnd connection) window
                      (tcp-connection-snd.wl1 connection) seq
                      (tcp-connection-snd.wl2 connection) ack)
                (when (not *netmangler-force-local-retransmit*)
                  (tcp4-send-packet connection ack (tcp-connection-rcv.nxt connection) nil
                                    :ack-p t :syn-p t))
                ;; Await the final ACK with bounded retransmission.
                (arm-retransmit-timer connection)
                (arm-timeout-timer *tcp-syn-received-timeout* connection))
               (t
                ;; Aborting connection
                (tcp4-send-packet connection ack seq nil :rst-p t)
                (setf (tcp-connection-pending-error connection)
                      (make-condition 'connection-aborted
                                      :host (tcp-connection-remote-ip connection)
                                      :port (tcp-connection-remote-port connection)))
                (detach-tcp-connection connection))))
        (:syn-received
         ;; Pasive open
         (cond ((and (eql flags +tcp4-flag-ack+)
                     (eql seq (tcp-connection-rcv.nxt connection))
                     (eql ack (tcp-connection-snd.nxt connection)))
                ;; Remote has sent ACK, connection established
                (initial-rtt-measurement connection)
                (setf (tcp-connection-state connection) :established
                      (tcp-connection-snd.wnd connection) window
                      (tcp-connection-snd.wl1 connection) seq
                      (tcp-connection-snd.wl2 connection) ack)
                (disarm-retransmit-timer connection)
                (disarm-timeout-timer connection)
                (when listener
                  (tcp-listener-remove-pending listener connection
                                               :accepted-p t)))
               ;; Ignore duplicated SYN packets
               ((and (logtest flags +tcp4-flag-syn+)
                     (eql seq (-u32 (tcp-connection-rcv.nxt connection) 1))))
               (t
                ;; Aborting connection
                (tcp4-send-packet connection ack seq nil :rst-p t)
                (setf (tcp-connection-pending-error connection)
                      (make-condition 'connection-aborted
                                      :host (tcp-connection-remote-ip connection)
                                      :port (tcp-connection-remote-port connection)))
                (detach-tcp-connection connection)
                (when listener
                  (tcp-listener-remove-pending listener connection)))))
        (:established
         (cond ((not (acceptable-segment-p connection packet start end))
                (when (not (logtest flags +tcp4-flag-rst+))
                  (tcp4-send-packet connection
                                    (tcp-connection-snd.nxt connection)
                                    (tcp-connection-rcv.nxt connection)
                                    nil
                                    :ack-p t)))
               ((logtest flags +tcp4-flag-syn+)
                (setf (tcp-connection-pending-error connection)
                      (make-condition 'connection-reset
                                      :host (tcp-connection-remote-ip connection)
                                      :port (tcp-connection-remote-port connection)))
                (detach-tcp-connection connection)
                (tcp4-send-packet connection
                                  (tcp-connection-snd.nxt connection)
                                  0 ; ???
                                  nil
                                  :ack-p nil
                                  :rst-p t))
               ((not (logtest flags +tcp4-flag-ack+))) ; Ignore packets without ACK set.
               ((and (tcp-sequence< (tcp-connection-snd.una connection) ack)
                     (tcp-sequence<= ack
                                    (tcp-connection-snd.nxt connection)))
                (let ((previous-una (tcp-connection-snd.una connection)))
                (when (tcp-connection-last-ack-time connection)
                  (subsequent-rtt-measurement connection))
                (tcp-update-send-window connection seq ack window)
                ;; Remove from the retransmit queue any segments that
                ;; were fully acknowledged by this ACK.
                (flet ((seq-cmp (x)
                         "Test SND.UNA =< X =< SEG.ACK"
                         (and (tcp-sequence<= previous-una x)
                              (tcp-sequence<= x ack))))
                  (loop
                     (when (endp (tcp-connection-retransmit-queue connection))
                       (return))
                     (let* ((rtx-start-seq (first (first (tcp-connection-retransmit-queue connection))))
                            (rtx-end-seq (+u32 rtx-start-seq (length (third (first (tcp-connection-retransmit-queue connection)))))))
                       (when (not (and (seq-cmp rtx-start-seq)
                                       (seq-cmp rtx-end-seq)))
                         ;; This segment not fully acked.
                         (return)))
                     (pop (tcp-connection-retransmit-queue connection))))
                (if (endp (tcp-connection-retransmit-queue connection))
                    (disarm-retransmit-timer connection)
                    (arm-retransmit-timer connection))
                (setf (tcp-connection-snd.una connection) ack)
                (tcp-note-new-ack connection previous-una ack)
                (tcp-flush-send-buffer connection)
                (if (zerop data-length)
                    (when (and (eql seq (tcp-connection-rcv.nxt connection))
                               (logtest flags +tcp4-flag-fin+))
                      ;; Remote has sent FIN and waiting for ACK
                      (setf (tcp-connection-state connection) :close-wait
                            (tcp-connection-rcv.nxt connection)
                            (+u32 seq 1))
                      (setf (mezzano.supervisor:event-state
                             (tcp-connection-receive-event connection))
                            t)
                      (tcp4-send-packet connection ack (+u32 seq 1) nil :ack-p t))
                    (tcp4-receive-data connection data-length end header-length packet seq start))))
               ((eql (tcp-connection-snd.una connection) ack)
                (let ((previous-window (tcp-connection-snd.wnd connection)))
                  (tcp-update-send-window connection seq ack window)
                  (if (and (zerop data-length)
                           (not (logtest flags +tcp4-flag-fin+))
                           (eql previous-window window))
                      (tcp-note-duplicate-ack connection)
                      (setf (tcp-connection-duplicate-acks connection) 0))
                  (tcp-flush-send-buffer connection))
                (when (not (eql data-length 0))
                  (tcp4-receive-data connection data-length end header-length packet seq start)))))
        (:close-wait
         ;; Remote has closed, local can still send data.
         ;; Not much to do here, just waiting for the application to close.
         )
        (:last-ack
         ;; Local closed, waiting for remote to ACK.
         (when (logtest flags +tcp4-flag-ack+)
           ;; Remote has sent ACK, connection closed
           (detach-tcp-connection connection)))
        (:fin-wait-1
         ;; Local closed, waiting for remote to close.
         (if (zerop data-length)
             (when (= seq (tcp-connection-rcv.nxt connection))
               (cond ((logtest flags +tcp4-flag-fin+)
                      (setf (tcp-connection-rcv.nxt connection)
                            (+u32 (tcp-connection-rcv.nxt connection) 1))
                      (tcp4-send-packet connection
                                        (tcp-connection-snd.nxt connection)
                                        (tcp-connection-rcv.nxt connection)
                                        nil)
                      (if (logtest flags +tcp4-flag-ack+)
                          ;; Remote saw our FIN and closed as well.
                          (detach-tcp-connection connection)
                          ;; Simultaneous close
                          (setf (tcp-connection-state connection) :closing)))
                     ((logtest flags +tcp4-flag-ack+)
                      ;; Remote saw our FIN
                      (setf (tcp-connection-state connection) :fin-wait-2))))
             (tcp4-receive-data connection data-length end header-length packet seq start)))
        (:fin-wait-2
         ;; Local closed, still waiting for remote to close.
         (if (zerop data-length)
             (when (and (= seq (tcp-connection-rcv.nxt connection))
                        (logtest flags +tcp4-flag-fin+))
               ;; Remote has sent FIN and waiting for ACK
               (setf (tcp-connection-rcv.nxt connection)
                     (+u32 (tcp-connection-rcv.nxt connection) 1))
               (tcp4-send-packet connection
                                 (tcp-connection-snd.nxt connection)
                                 (tcp-connection-rcv.nxt connection)
                                 nil)
               (detach-tcp-connection connection))
             (tcp4-receive-data connection data-length end header-length packet seq start)))
        (:closing
         ;; Waiting for ACK
         (when (and (eql seq (tcp-connection-rcv.nxt connection))
                    (logtest flags +tcp4-flag-ack+))
           ;; Remote has sent ACK, connection closed
           (detach-tcp-connection connection)))))
    (update-timeout-timer connection)
    ;; Notify any waiters that something may have changed.
    (mezzano.supervisor:condition-notify (tcp-connection-cvar connection) t)))

(defun tcp4-send-packet (connection seq ack data &key cwr-p ece-p urg-p (ack-p t) psh-p rst-p syn-p fin-p errors-escape)
  (when (tcp-connection-abort-pending-p connection)
    (return-from tcp4-send-packet))
  (let* ((source (tcp-connection-local-ip connection))
         (source-port (tcp-connection-local-port connection))
         (packet (assemble-tcp4-packet source source-port
                                       (tcp-connection-remote-ip connection)
                                       (tcp-connection-remote-port connection)
                                       seq ack
                                       (tcp-connection-rcv.wnd connection)
                                       data
                                       :cwr-p cwr-p
                                       :ece-p ece-p
                                       :urg-p urg-p
                                       :ack-p ack-p
                                       :psh-p psh-p
                                       :rst-p rst-p
                                       :syn-p syn-p
                                       :fin-p fin-p)))
    (handler-case
        (mezzano.network.ip:transmit-ipv4-packet
         source (tcp-connection-remote-ip connection)
         mezzano.network.ip:+ip-protocol-tcp+ packet)
      (mezzano.network.ip:no-route-to-host (c)
        (detach-tcp-connection connection)
        (setf (tcp-connection-pending-error connection) c)
        (mezzano.supervisor:condition-notify (tcp-connection-cvar connection) t)
        (when errors-escape
          (error c))))))

(defun compute-ip-pseudo-header-partial-checksum (src-ip dst-ip protocol length)
  (+ (logand src-ip #xFFFF)
     (logand (ash src-ip -16) #xFFFF)
     (logand dst-ip #xFFFF)
     (logand (ash dst-ip -16) #xFFFF)
     protocol
     length))

(defun assemble-tcp4-packet (src-ip src-port dst-ip dst-port seq-num ack-num window payload
                             &key cwr-p ece-p urg-p (ack-p t) psh-p rst-p syn-p fin-p)
  "Build a full TCP & IP header."
  (let* ((checksum 0)
         (payload-size (length payload))
         (header (make-array 20 :element-type '(unsigned-byte 8)))
         (packet (list header payload)))
    ;; Assemble the TCP header.
    (setf (ub16ref/be header +tcp4-header-source-port+) src-port
          (ub16ref/be header +tcp4-header-destination-port+) dst-port
          (ub32ref/be header +tcp4-header-sequence-number+) seq-num
          (ub32ref/be header +tcp4-header-acknowledgment-number+) ack-num
          ;; Data offset/header length (5 32-bit words) and flags.
          (ub16ref/be header +tcp4-header-flags-and-data-offset+) (logior #x5000
                                                                          (if fin-p +tcp4-flag-fin+ 0)
                                                                          (if syn-p +tcp4-flag-syn+ 0)
                                                                          (if rst-p +tcp4-flag-rst+ 0)
                                                                          (if psh-p +tcp4-flag-psh+ 0)
                                                                          (if ack-p +tcp4-flag-ack+ 0)
                                                                          (if urg-p +tcp4-flag-urg+ 0)
                                                                          (if ece-p +tcp4-flag-ece+ 0)
                                                                          (if cwr-p +tcp4-flag-cwr+ 0))
          ;; Window.
          (ub16ref/be header +tcp4-header-window-size+) window
          ;; Checksum.
          (ub16ref/be header +tcp4-header-checksum+) 0
          ;; Urgent pointer.
          (ub16ref/be header +tcp4-header-urgent-pointer+) 0)
    ;; Compute the final checksum.
    (setf checksum (compute-ip-pseudo-header-partial-checksum
                    (mezzano.network.ip::ipv4-address-address src-ip)
                    (mezzano.network.ip::ipv4-address-address dst-ip)
                    mezzano.network.ip:+ip-protocol-tcp+
                    (+ (length header) payload-size)))
    (setf checksum (mezzano.network.ip:compute-ip-partial-checksum header 0 nil checksum))
    (when payload
      (setf checksum (mezzano.network.ip:compute-ip-partial-checksum payload 0 nil checksum)))
    (setf checksum (mezzano.network.ip:finalize-ip-checksum checksum))
    (setf (ub16ref/be header +tcp4-header-checksum+) checksum)
    packet))

(defun allocate-local-tcp-port (local-ip ip port)
  (loop :for local-port := (+ (random 32768) 32768)
        :do (unless (get-tcp-connection ip port local-ip local-port)
              (return local-port))))

(defun abort-connection (connection)
  (mezzano.sync.dispatch:dispatch-async
   (lambda ()
     (tcp4-send-packet connection
                       (tcp-connection-snd.nxt connection)
                       (tcp-connection-rcv.nxt connection)
                       nil
                       :rst-p t)
     (detach-tcp-connection connection))
   net::*network-serial-queue*))

(define-condition connection-error (net:network-error)
  ((host :initarg :host :reader connection-error-host)
   (port :initarg :port :reader connection-error-port)))

(define-condition connection-closed (connection-error)
  ())

(define-condition connection-aborted (connection-error)
  ())

(define-condition connection-reset (connection-error)
  ())

(define-condition connection-timed-out (connection-error)
  ())

(define-condition connection-stale (connection-error)
  ())

(defun flush-stale-connections ()
  ;; Called with snapshot inhibited to prevent more connections becoming stale.
  ;; Lock ordering note:
  ;; Can't take the per-connection lock while *tcp-connection-lock* is
  ;; held. Must be the other way around. Per-connection lock first,
  ;; then *tcp-connection-lock*.
  (let ((stale-connections
         (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
           (loop
              for connection in *tcp-connections*
              when (and (tcp-connection-boot-id connection)
                        (not (eql (tcp-connection-boot-id connection)
                                  (mezzano.supervisor:current-boot-id))))
              collect connection))))
    (dolist (connection stale-connections)
      (mezzano.supervisor:with-mutex ((tcp-connection-lock connection))
        (setf (tcp-connection-pending-error connection)
              (make-condition 'connection-stale
                              :host (tcp-connection-remote-ip connection)
                              :port (tcp-connection-remote-port connection)))
        (mezzano.supervisor:condition-notify (tcp-connection-cvar connection) t)
        (detach-tcp-connection connection)))))

(defun check-connection-error (connection)
  (let ((condition (tcp-connection-pending-error connection)))
    (when condition
      (error condition))))

(defun tcp-connect (ip port &key persist timeout)
  (let* ((interface (nth-value 1 (mezzano.network.ip:ipv4-route ip)))
         (source-address (mezzano.network.ip:ipv4-interface-address interface))
         (source-port (allocate-local-tcp-port source-address ip port))
         (iss (or *netmangler-iss*
                  (random #x100000000)))
         (connection (make-instance 'tcp-connection
                                    :state :syn-sent
                                    :local-port source-port
                                    :local-ip source-address
                                    :remote-port port
                                    :remote-ip ip
                                    :snd.nxt (+u32 iss 1)
                                    :snd.una iss
                                    :rcv.nxt 0
                                    :rcv.wnd *initial-window-size*
                                    :boot-id (if persist nil (mezzano.supervisor:current-boot-id))
                                    :timeout timeout)))
    (mezzano.sync.dispatch:dispatch-async
     (lambda ()
       (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
         (push connection *tcp-connections*))
       (setf (tcp-connection-last-ack-time connection)
             (get-internal-run-time))
       (when (not *netmangler-force-local-retransmit*)
         (tcp4-send-packet connection iss 0 nil :ack-p nil :syn-p t))
       (arm-retransmit-timer connection)
       (arm-timeout-timer *tcp-connect-timeout* connection))
     net::*network-serial-queue*)
    (with-tcp-connection-locked connection
      (mezzano.supervisor:condition-wait-for ((tcp-connection-cvar connection)
                                              (tcp-connection-lock connection))
        (not (eql (tcp-connection-state connection) :syn-sent)))
      (check-connection-error connection))
    connection))

(defun subseq-ub8 (sequence start &optional end)
  "Like SUBSEQ, but returns a simple UB8 vector."
  (let ((result (make-array (- (or end (length sequence)) start) :element-type '(unsigned-byte 8))))
    (replace result sequence :start2 start :end2 end)
    result))

(defun tcp-queue-send-data (connection data start end)
  "Copy DATA into MSS-sized connection-owned pending segments."
  (let ((segments '())
        (mss (tcp-connection-max-seg-size connection)))
    (loop for offset from start below end by mss
          for segment-end = (min end (+ offset mss))
          do (push (list (subseq-ub8 data offset segment-end)
                         (eql segment-end end))
                   segments))
    (setf (tcp-connection-tx-data connection)
          (nconc (tcp-connection-tx-data connection)
                 (nreverse segments)))))

(defun tcp-flush-send-buffer (connection)
  "Transmit queued bytes up to the peer and congestion-window limits."
  (when (tcp-connection-abort-pending-p connection)
    (return-from tcp-flush-send-buffer (values)))
  (loop
    for flight = (tcp-flight-size connection)
    for limit = (min (tcp-connection-snd.wnd connection)
                     (tcp-connection-congestion-window connection))
    for available = (max 0 (- limit flight))
    while (and (plusp available) (tcp-connection-tx-data connection))
    do
       (let* ((entry (first (tcp-connection-tx-data connection)))
              (data (first entry))
              (psh-p (second entry))
              (count (min available
                          (tcp-connection-max-seg-size connection)
                          (length data))))
         (tcp-send-1 connection data 0 count
                     :psh-p (and psh-p (eql count (length data))))
         (if (eql count (length data))
             (pop (tcp-connection-tx-data connection))
             (setf (first (tcp-connection-tx-data connection))
                   (list (subseq-ub8 data count) psh-p)))))
  (values))

(defun tcp-send-1 (connection data start end &key psh-p)
  (when (tcp-connection-abort-pending-p connection)
    (return-from tcp-send-1))
  (let ((snd.nxt (tcp-connection-snd.nxt connection))
        (rcv.nxt (tcp-connection-rcv.nxt connection))
        (len (- end start))
        ;; A copy of the data must be taken as it is owned by the user
        ;; and may be modified after TCP-SEND returns. Due to retransmit
        ;; it needs to be kept around until the remote has acked the data.
        (data (subseq-ub8 data start end)))
    (setf (tcp-connection-snd.nxt connection)
          (+u32 snd.nxt len))
    (setf (tcp-connection-retransmit-queue connection)
          (append (tcp-connection-retransmit-queue connection)
                  (list (list snd.nxt rcv.nxt data :psh-p psh-p))))
    (arm-retransmit-timer connection)
    (when (not *netmangler-force-local-retransmit*)
      (tcp4-send-packet connection
                        snd.nxt rcv.nxt
                        data
                        :psh-p psh-p
                        :errors-escape t))))

(defun tcp-send (connection data &optional (start 0) end)
  (setf end (or end (length data)))
  (with-tcp-connection-locked connection
    (check-connection-error connection)
    (when (tcp-connection-abort-pending-p connection)
      (error 'connection-aborted
             :host (tcp-connection-remote-ip connection)
             :port (tcp-connection-remote-port connection)))
    (update-timeout-timer connection)
    ;; No sending when the connection is closing.
    ;; Half-closed connections seem too weird to be worth dealing with.
    (when (not (eql (tcp-connection-state connection) :established))
      (error 'connection-closed
             :host (tcp-connection-remote-ip connection)
             :port (tcp-connection-remote-port connection)))
    (unless (tcp-connection-last-ack-time connection)
      (setf (tcp-connection-last-ack-time connection)
            (get-internal-run-time)))
    (when (< start end)
      (tcp-queue-send-data connection data start end)
      (tcp-flush-send-buffer connection))))

(defclass tcp-octet-stream (gray:fundamental-binary-input-stream
                            gray:fundamental-binary-output-stream)
  ((connection :initarg :connection :reader tcp-stream-connection)
   (current-packet :initform nil :accessor tcp-stream-packet)))

(defclass tcp-stream (sys.int::external-format-mixin
                      gray:fundamental-character-input-stream
                      gray:fundamental-character-output-stream
                      tcp-octet-stream
                      gray:unread-char-mixin)
  ())

(defmethod mezzano.network:local-endpoint ((object tcp-octet-stream))
  (let ((conn (tcp-stream-connection object)))
    (values (tcp-connection-local-ip conn)
            (tcp-connection-local-port conn))))

(defmethod mezzano.network:remote-endpoint ((object tcp-octet-stream))
  (let ((conn (tcp-stream-connection object)))
    (values (tcp-connection-remote-ip conn)
            (tcp-connection-remote-port conn))))

(defmethod mezzano.sync:get-object-event ((object tcp-octet-stream))
  (tcp-connection-receive-event (tcp-stream-connection object)))

(defmethod print-object ((instance tcp-octet-stream) stream)
  (print-unreadable-object (instance stream :type t :identity t)
    (multiple-value-bind (local-address local-port)
        (mezzano.network:local-endpoint instance)
      (multiple-value-bind (remote-address remote-port)
          (mezzano.network:remote-endpoint instance)
        (format stream "~A :Local ~A:~A :Remote ~A:~A"
                (tcp-connection-state (tcp-stream-connection instance))
                local-address local-port
                remote-address remote-port)))))

(defun connection-may-have-additional-data-p (connection)
  "Returns true if CONNECTION is in a state where it may potentially receive further data."
  (member (tcp-connection-state connection)
          ;; Data can only be received in these states.
          '(:established
            :fin-wait-1
            :fin-wait-2)))

(defun refill-tcp-packet-buffer (stream)
  (let ((connection (tcp-stream-connection stream)))
    ;; Wait for data or for the connection to close.
    (mezzano.supervisor:condition-wait-for ((tcp-connection-cvar connection)
                                            (tcp-connection-lock connection))
      (when (tcp-stream-packet stream)
        ;; There was already data waiting or another thread refilled
        ;; while we were waiting.
        (return-from refill-tcp-packet-buffer t))
      (or (tcp-connection-rx-data connection)
          (not (connection-may-have-additional-data-p connection))))
    (when (and (null (tcp-connection-rx-data connection))
               (not (connection-may-have-additional-data-p connection)))
      (return-from refill-tcp-packet-buffer nil))
    (setf (tcp-stream-packet stream) (pop (tcp-connection-rx-data connection))))
  t)

(defun refill-tcp-packet-buffer-no-hang (stream)
  (let ((connection (tcp-stream-connection stream)))
    (when (and (null (tcp-stream-packet stream))
               (tcp-connection-rx-data connection))
      (setf (tcp-stream-packet stream) (pop (tcp-connection-rx-data connection))))))

(defun maybe-clear-receive-ready-event (stream)
  (let ((connection (tcp-stream-connection stream)))
    (when (and (null (tcp-stream-packet stream))
               (endp (tcp-connection-rx-data connection))
               (connection-may-have-additional-data-p connection))
      (setf (mezzano.supervisor:event-state
             (tcp-connection-receive-event connection))
            nil))))

(defmethod gray:stream-listen-byte ((stream tcp-octet-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (check-connection-error (tcp-stream-connection stream))
    (refill-tcp-packet-buffer-no-hang stream)
    (not (null (tcp-stream-packet stream)))))

;; Provide this method so that LISTEN works on octet streams too.
;; EXTERNAL-FORMAT-MIXIN implements LISTEN on a character level,
;; LISTEN-BYTE exists to poke directly at the raw byte stream.
(defmethod gray:stream-listen ((stream tcp-octet-stream))
  (let ((result (gray:stream-listen-byte stream)))
    (and result (not (eql result :eof)))))

(defmethod gray:stream-read-byte ((stream tcp-octet-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (check-connection-error (tcp-stream-connection stream))
    (when (not (refill-tcp-packet-buffer stream))
      (return-from gray:stream-read-byte :eof))
    (let* ((packet (tcp-stream-packet stream))
           (byte (aref (first packet) (second packet))))
      (when (>= (incf (second packet)) (third packet))
        (setf (tcp-stream-packet stream) nil))
      (maybe-clear-receive-ready-event stream)
      byte)))

(defmethod gray:stream-read-byte-no-hang ((stream tcp-octet-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (check-connection-error (tcp-stream-connection stream))
    (refill-tcp-packet-buffer-no-hang stream)
    (when (not (tcp-stream-packet stream))
      (return-from gray:stream-read-byte-no-hang
        (if (connection-may-have-additional-data-p (tcp-stream-connection stream))
            nil
            :eof)))
    (let* ((packet (tcp-stream-packet stream))
           (byte (aref (first packet) (second packet))))
      (when (>= (incf (second packet)) (third packet))
        (setf (tcp-stream-packet stream) nil))
      (maybe-clear-receive-ready-event stream)
      byte)))

(defmethod gray:stream-read-sequence ((stream tcp-octet-stream) sequence &optional (start 0) end)
  (when (not end)
    (setf end (length sequence)))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (check-connection-error (tcp-stream-connection stream))
    (let ((position start))
      (loop (when (or (>= position end)
                      (not (refill-tcp-packet-buffer stream)))
              (return))
         (let* ((packet (tcp-stream-packet stream))
                (pkt-data (first packet))
                (pkt-offset (second packet))
                (pkt-length (third packet))
                (bytes-to-copy (min (- end position) (- pkt-length pkt-offset))))
           (replace sequence pkt-data
                    :start1 position
                    :start2 pkt-offset
                    :end2 (+ pkt-offset bytes-to-copy))
           (when (>= (incf (second packet) bytes-to-copy) (third packet))
             (setf (tcp-stream-packet stream) nil))
           (incf position bytes-to-copy)))
      (maybe-clear-receive-ready-event stream)
      position)))

(defmethod gray:stream-write-byte ((stream tcp-octet-stream) byte)
  (let ((ary (make-array 1 :element-type '(unsigned-byte 8)
                         :initial-element byte)))
    (tcp-send (tcp-stream-connection stream) ary)))

(defmethod gray:stream-write-sequence ((stream tcp-octet-stream) sequence &optional (start 0) end)
  (tcp-send (tcp-stream-connection stream) sequence start end))

(defun close-connection (connection)
  (when (tcp-connection-abort-pending-p connection)
    (return-from close-connection))
  (ecase (tcp-connection-state connection)
    (:established
     (setf (tcp-connection-state connection) :fin-wait-1)
     (setf (tcp-connection-retransmit-queue connection)
           (append (tcp-connection-retransmit-queue connection)
                   (list (list (tcp-connection-snd.nxt connection)
                               (tcp-connection-rcv.nxt connection)
                               nil
                               :fin-p t))))
     (arm-retransmit-timer connection)
     (when (not *netmangler-force-local-retransmit*)
       (tcp4-send-packet connection
                         (tcp-connection-snd.nxt connection)
                         (tcp-connection-rcv.nxt connection)
                         nil
                         :fin-p t
                         :errors-escape t)))
    (:close-wait
     (setf (tcp-connection-state connection) :last-ack)
     (setf (tcp-connection-retransmit-queue connection)
           (append (tcp-connection-retransmit-queue connection)
                   (list (list (tcp-connection-snd.nxt connection)
                               (tcp-connection-rcv.nxt connection)
                               nil
                               :fin-p t
                               :errors-escape t))))
     (arm-retransmit-timer connection)
     (when (not *netmangler-force-local-retransmit*)
       (tcp4-send-packet connection
                         (tcp-connection-snd.nxt connection)
                         (tcp-connection-rcv.nxt connection)
                         nil
                         :fin-p t
                         :errors-escape t)))
    ((:last-ack :fin-wait-1 :fin-wait-2 :closed))))

(defun abort-stream-connection (connection)
  "Detach a stream without transmitting additional segments."
  ;; CLOSE holds the connection lock while calling this function. Publish the
  ;; abort intent synchronously so already-queued network work cannot reopen a
  ;; window and flush data before the asynchronous detach runs.
  (setf (tcp-connection-abort-pending-p connection) t
        (tcp-connection-tx-data connection) '()
        (tcp-connection-retransmit-queue connection) '())
  (disarm-retransmit-timer connection)
  (disarm-timeout-timer connection)
  (mezzano.sync.dispatch:dispatch-async
   (lambda () (detach-tcp-connection connection))
   net::*network-serial-queue*))

(defun tcp-close-stream-connection (connection abort)
  (if abort
      (abort-stream-connection connection)
      (close-connection connection)))

(defmethod close ((stream tcp-octet-stream) &key abort)
  (let ((connection (tcp-stream-connection stream)))
    (with-tcp-connection-locked connection
      (tcp-close-stream-connection connection abort))))

(defmethod open-stream-p ((stream tcp-octet-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (let ((connection (tcp-stream-connection stream)))
      (refill-tcp-packet-buffer-no-hang stream)
      (or (tcp-stream-packet stream)
          (connection-may-have-additional-data-p connection)))))

(defmethod stream-element-type ((stream tcp-octet-stream))
  '(unsigned-byte 8))

(defun tcp-stream-connect (address port &key element-type external-format persist timeout)
  (cond ((or (not element-type)
             (sys.int::type-equal element-type 'character))
         (make-instance 'tcp-stream
                        :connection (tcp-connect (net::resolve-address address) port
                                                 :persist persist
                                                 :timeout timeout)
                        :external-format (sys.int::make-external-format
                                          (or element-type 'character)
                                          (or external-format :default)
                                          :eol-style :crlf)))
        ((sys.int::type-equal element-type '(unsigned-byte 8))
         (assert (or (not external-format)
                     (eql external-format :default)))
         (make-instance 'tcp-octet-stream
                        :connection (tcp-connect (net::resolve-address address) port
                                                 :persist persist
                                                 :timeout timeout)))
        (t
         (error "Unsupported element type ~S" element-type))))
