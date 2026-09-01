;;;; IPv4 stack

(in-package :mezzano.network.ip)

(defconstant +ip-protocol-icmp+ 1)
(defconstant +ip-protocol-igmp+ 2)
(defconstant +ip-protocol-tcp+ 6)
(defconstant +ip-protocol-udp+ 17)

(defconstant +icmp-echo-reply+ 0)
(defconstant +icmp-echo-request+ 8)
(defconstant +icmp-destination-unreachable+ 3)
(defconstant +icmp-time-exceeded+ 11)
(defconstant +icmp-parameter-problem+ 12)

;;; Destination unreachable codes.
(defconstant +icmp-code-net-unreachable+ 0)
(defconstant +icmp-code-host-unreachable+ 1)
(defconstant +icmp-code-protocol-unreachable+ 2)
(defconstant +icmp-code-port-unreachable+ 3)
(defconstant +icmp-code-fragmentation-needed+ 4)
(defconstant +icmp-code-source-route-failed+ 5)

;; Time exceeded codes.
(defconstant +icmp-code-ttl-exceeded+ 0)
(defconstant +icmp-code-fragment-timeout+ 1)

;;; Routing.

;; A short note on locking:
;; Routes and the list of routes is immutable, it is never modified in-place.
;; When routes are added/removed a new list is constructed and completely
;; replaces the previous value of *ROUTING-TABLE*. This allows IPV4-ROUTE
;; to read the value of *ROUTING-TABLE* once and then use that list safely
;; without it being modified. The list may become stale if routes are modified
;; while routing, but that's not an issue.
(defvar *routing-table-lock* (mezzano.supervisor:make-mutex "IPv4 routing table."))
;; Sorted from longest prefix to shortest.
;; Default route has a prefix of 0.
(defvar *routing-table* nil)

(defclass ipv4-route ()
  ;; No netmask, just the network address & length of the prefix.
  ;; 192.168.0.0/24  network/prefix-length
  ((%network :initarg :network :reader route-network)
   (%prefix-length :initarg :prefix-length :reader route-prefix-length)
   (%gateway :initarg :gateway :reader route-gateway)
   (%tag :initarg :tag :reader route-tag)))

(defun add-route (network prefix-length gateway &optional tag)
  (setf network (make-ipv4-address network))
  (if prefix-length
      (assert (eql (ipv4-address-address (address-host network prefix-length)) 0))
      (setf prefix-length 32))
  (let ((route (make-instance 'ipv4-route
                              :network (make-ipv4-address network)
                              :prefix-length prefix-length
                              :gateway gateway
                              :tag tag)))
    (mezzano.supervisor:with-mutex (*routing-table-lock*)
      (setf *routing-table*
            (merge 'list
                   (remove-if (lambda (x)
                                (and (address-equal network (route-network x))
                                     (eql prefix-length (route-prefix-length x))))
                              *routing-table*)
                   (list route)
                   #'>
                   :key #'route-prefix-length))
      route)))

(defun remove-route (network prefix-length &optional tag)
  (setf network (make-ipv4-address network))
  (if prefix-length
      (assert (eql (ipv4-address-address (address-host network prefix-length)) 0))
      (setf prefix-length 32))
  (mezzano.supervisor:with-mutex (*routing-table-lock*)
    (setf *routing-table*
          (remove-if (lambda (x)
                       (and (address-equal network (route-network x))
                            (eql prefix-length (route-prefix-length x))
                            (or (eql tag t)
                                (eql tag (route-tag x)))))
                     *routing-table*))))

(define-condition no-route-to-host (net:network-error)
  ((host :initarg :host :reader no-route-to-host-host))
  (:report (lambda (condition stream)
             (format stream "No route to host ~A"
                     (no-route-to-host-host condition)))))

(defun ipv4-route (destination &optional gateway-lookup)
  "Return the host IP and interface for the destination IP address."
  (dolist (route *routing-table*
           (error 'no-route-to-host :host destination))
    (when (address-equal (address-network destination
                                          (route-prefix-length route))
                         (route-network route))
      (return
        (cond ((ipv4-address-p (route-gateway route))
               (when gateway-lookup
                 (error "Gateway lookup failed."))
               ;; Route to this host is via a gateway.
               ;; Find a route to the gateway.
               (values (route-gateway route)
                       (nth-value 1 (ipv4-route (route-gateway route) t))))
              (t ;; Local host on this network
               (values destination
                       (route-gateway route))))))))

;;; Interfaces.

(defvar *ipv4-interfaces* '())

(defun ifup (nic address prefix-length)
  "Set NIC's IPv4 address to ADDRESS.
ADDRESS must be an ipv4-address designator."
  (setf address (make-ipv4-address address))
  (let ((existing (find nic *ipv4-interfaces* :key #'first)))
    (cond (existing
           (setf (second existing) address
                 (third existing) prefix-length))
          (t
           (push (list nic address prefix-length) *ipv4-interfaces*)))))

(defun ifdown (nic)
  (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
    (setf *outstanding-sends*
          (remove nic *outstanding-sends*
                  :key #'second)))
  (setf *ipv4-interfaces* (remove nic *ipv4-interfaces* :key #'first)))

(defun ipv4-interface-address (nic &optional (errorp t))
  "Return the IP address and prefix-length of the given interface."
  (let ((entry (find nic *ipv4-interfaces* :key #'first)))
    (cond (entry
           (values (second entry) (third entry)))
          (errorp
           (error "No IPv4 address for interface ~S." nic))
          (t
           (values nil nil)))))

(defun ipv4-address-interface (address &optional (errorp t))
  "Return the interface with the given IP address."
  (or (car (find address *ipv4-interfaces* :key #'second :test #'address-equal))
      (and errorp
           (error "No interface for IPv4 address ~A." address))))

;;; Checksums.

#|
;; Original un-optimized implementation
(defun compute-ip-partial-checksum (buffer &optional (start 0) end (initial 0))
  ;; From RFC 1071.
  (let ((total initial))
    (setf end (or end (length buffer)))
    (when (oddp (- end start))
      (decf end)
      (incf total (ash (aref buffer end) 8)))
    (do ((i start (+ i 2)))
        ((>= i end))
      (incf total (ub16ref/be buffer i)))
    total))
|#

(defun compute-ip-partial-checksum (buffer &optional (start 0) end (initial 0))
  ;; From RFC 1071.
  (check-type buffer (simple-array (unsigned-byte 8) (*)))
  (check-type initial (unsigned-byte 32))
  (check-type start fixnum)
  (check-type end (or null fixnum))
  (let ((total initial))
    (declare (type (unsigned-byte 32) total)
             (type (simple-array (unsigned-byte 8) (*)) buffer)
             (optimize speed (safety 0) (debug 0)))
    (let ((true-end (or end (length buffer))))
      (declare (type fixnum start true-end))
      (when (oddp (the fixnum (- true-end start)))
        (decf true-end)
        (incf total (the (unsigned-byte 16)
                         (ash (the (unsigned-byte 8)
                                   (aref buffer true-end))
                              8))))
      (do ((i start (+ i 2)))
          ((>= i true-end))
        (declare (type fixnum i))
        (incf total (mezzano.extensions:ub16ref/be buffer i))))
    total))

(defun finalize-ip-checksum (checksum)
  (check-type checksum (unsigned-byte 32))
  (let ((total checksum))
    (declare (type (unsigned-byte 32) total)
             (optimize speed (safety 0) (debug 0)))
    (do ()
        ((not (logtest total #xFFFF0000)))
      (setf total (+ (the (unsigned-byte 16) (logand total #xFFFF))
                     (the (unsigned-byte 16) (ash total -16)))))
    (logand (the (signed-byte 32) (lognot total)) #xFFFF)))

(defun compute-ip-checksum (buffer &optional (start 0) end (initial 0))
  (finalize-ip-checksum (compute-ip-partial-checksum buffer start end initial)))

;;; Other.

(defconstant +ipv4-header-version-and-ihl+ 0)
(defconstant +ipv4-header-version-size+ 4)
(defconstant +ipv4-header-version-position+ 4)
(defconstant +ipv4-header-ihl-size+ 4)
(defconstant +ipv4-header-ihl-position+ 0)
(defconstant +ipv4-header-dsf+ 1)
(defconstant +ipv4-header-total-length+ 2)
(defconstant +ipv4-header-identification+ 4)
(defconstant +ipv4-header-fragmentation-control+ 6)
(defconstant +ipv4-header-fragment-offset-size+ 13)
(defconstant +ipv4-header-fragment-offset-position+ 0)
(defconstant +ipv4-header-flag-more-fragments+ 13)
(defconstant +ipv4-header-flag-do-not-fragment+ 14)
(defconstant +ipv4-header-flag-reserved+ 15)
(defconstant +ipv4-header-ttl+ 8)
(defconstant +ipv4-header-protocol+ 9)
(defconstant +ipv4-header-checksum+ 10)
(defconstant +ipv4-header-source-ip+ 12)
(defconstant +ipv4-header-destination-ip+ 16)

(defgeneric transmit-ipv4-packet-on-interface (destination-host interface packet))

(defparameter *outstanding-send-timeout* 30
  "Seconds to retain an IPv4 packet while waiting for ARP resolution.")

(defvar *outstanding-sends* '()
  "Packets waiting for ARP resolution.
Each entry is (destination-host interface packet attempt expiration-time).")

(defvar *outstanding-sends-lock*
  (mezzano.supervisor:make-mutex "IPv4 outstanding sends"))

(defvar *arp-update-generation* 0
  "Incremented whenever an ARP update may make a pending send runnable.")

(defun outstanding-send-expired-p (entry now)
  (let ((expiration-time (fifth entry)))
    ;; Entries restored from an older image do not have a deadline and must not
    ;; become immortal after the representation change.
    (or (null expiration-time)
        (>= now expiration-time))))

(defun expire-outstanding-sends (&optional (now (get-internal-real-time)))
  (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
    (let ((old-count (length *outstanding-sends*)))
      (setf *outstanding-sends*
            (remove-if (lambda (entry)
                         (outstanding-send-expired-p entry now))
                       *outstanding-sends*))
      (- old-count (length *outstanding-sends*)))))

(defun schedule-outstanding-send-expiration ()
  (mezzano.sync.dispatch:dispatch-delayed
   #'expire-outstanding-sends
   *outstanding-send-timeout*
   net::*network-serial-queue*))

(defun retry-outstanding-send (entry observed-generation)
  "Try a claimed outstanding send without holding *OUTSTANDING-SENDS-LOCK*.
If ARP changed while the entry was claimed, retry immediately; otherwise put
the entry back on the pending list with its original deadline."
  (loop
     (when (outstanding-send-expired-p entry (get-internal-real-time))
       (return nil))
     (format t "Attempting retransmit to ~S on ~S.~%"
             (first entry) (second entry))
     (when (try-ethernet-transmit (first entry) (second entry) (third entry))
       (return t))
     (when (> (fourth entry) 5)
       (return nil))
     (incf (fourth entry))
     (let ((retry-now nil))
       (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
         (cond ((outstanding-send-expired-p entry (get-internal-real-time))
                (return-from retry-outstanding-send nil))
               ((not (= observed-generation *arp-update-generation*))
                (setf observed-generation *arp-update-generation*
                      retry-now t))
               (t
                (push entry *outstanding-sends*)
                (return-from retry-outstanding-send nil))))
       (unless retry-now
         (return nil)))))

(defun queue-outstanding-send (destination-host interface packet
                               observed-generation
                               &optional (now (get-internal-real-time)))
  (let ((entry (list destination-host interface packet 0
                     (+ now (* *outstanding-send-timeout*
                               internal-time-units-per-second))))
        (retry-now nil)
        (current-generation nil))
    (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
      (setf current-generation *arp-update-generation*)
      (if (= observed-generation current-generation)
          (push entry *outstanding-sends*)
          (setf retry-now t)))
    (schedule-outstanding-send-expiration)
    (when retry-now
      (retry-outstanding-send entry current-generation)))
  (values))

(defun transmit-or-queue-ipv4-packet (destination-host interface packet)
  (let ((generation
          (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
            *arp-update-generation*)))
    (unless (try-ethernet-transmit destination-host interface packet)
      (queue-outstanding-send destination-host interface packet generation)))
  (values))

(defun try-ethernet-transmit (destination-host interface packet)
  (let ((arp-result (mezzano.network.arp:arp-lookup interface
                                                    mezzano.network.ethernet:+ethertype-ipv4+
                                                    (ipv4-address-address destination-host))))
    (cond (arp-result
           (mezzano.network.ethernet:transmit-ethernet-packet
            interface
            arp-result
            mezzano.network.ethernet:+ethertype-ipv4+
            packet)
           t)
          (t
           nil))))

(defun arp-table-updated ()
  (let ((entries nil)
        (generation nil)
        (now (get-internal-real-time)))
    (mezzano.supervisor:with-mutex (*outstanding-sends-lock*)
      (incf *arp-update-generation*)
      (setf generation *arp-update-generation*
            entries (remove-if (lambda (entry)
                                 (outstanding-send-expired-p entry now))
                               *outstanding-sends*)
            *outstanding-sends* nil))
    (dolist (entry entries)
      (retry-outstanding-send entry generation))))

(defmethod transmit-ipv4-packet-on-interface (destination-host (interface mezzano.driver.network-card:network-card) packet)
  (transmit-or-queue-ipv4-packet destination-host interface packet))

(defmethod transmit-ipv4-packet-on-interface (destination-host (interface net::loopback-interface) packet)
  ;; Bounce loopback packets out over the nic for testing as well.
  (mezzano.network.ethernet:transmit-ethernet-packet
   (first (mezzano.sync:watchable-set-items mezzano.driver.network-card::*nics*))
   #(0 0 0 1 2 3)
   mezzano.network.ethernet:+ethertype-ipv4+
   packet)
  ;; Use dispatch-async to avoid recursively calling back into the receive path.
  (let ((loopback-packet (make-array (+ 14 (net::packet-length packet))
                                     :element-type '(unsigned-byte 8))))
    (net::copy-packet loopback-packet
                          (cons #(0 0 0 0 0 0
                                  0 0 0 0 0 0
                                  8 0)
                                packet))
    (mezzano.sync.dispatch:dispatch-async
     (lambda ()
       (sys.int::log-and-ignore-errors
         (mezzano.network.ethernet::receive-ethernet-packet
          interface loopback-packet)))
     net::*network-serial-queue*)
    loopback-packet))

(defun assemble-ipv4-packet (source destination protocol payload)
  (let* ((ip-header (make-array 20 :element-type '(unsigned-byte 8)))
         (packet (cons ip-header payload)))
    (setf
     ;; Version (4) and header length (5 32-bit words).
     (aref ip-header +ipv4-header-version-and-ihl+) #x45
     ;; Differentiated Services Field, normal packet.
     (aref ip-header +ipv4-header-dsf+) #x00
     ;; Total length.
     (ub16ref/be ip-header +ipv4-header-total-length+) (net:packet-length packet)
     ;; This packet is emitted whole, so it does not need a distinct ID.
     (ub16ref/be ip-header +ipv4-header-identification+) 0
     ;; Flags & fragment offset.
     (ub16ref/be ip-header +ipv4-header-fragmentation-control+) 0
     ;; Time-to-Live. Specified in RFC1122.
     (aref ip-header +ipv4-header-ttl+) 64
     ;; Protocol.
     (aref ip-header +ipv4-header-protocol+) protocol
     ;; Source address.
     (ub32ref/be ip-header +ipv4-header-source-ip+) (mezzano.network.ip::ipv4-address-address source)
     ;; Destination address.
     (ub32ref/be ip-header +ipv4-header-destination-ip+) (mezzano.network.ip::ipv4-address-address destination)
     ;; Header checksum.
     (ub16ref/be ip-header +ipv4-header-checksum+) 0
     (ub16ref/be ip-header +ipv4-header-checksum+) (compute-ip-checksum ip-header))
    packet))

(defun transmit-ipv4-packet (source destination protocol payload)
  (multiple-value-bind (host interface)
      (ipv4-route destination)
    (when (and host interface)
      (transmit-ipv4-packet-on-interface
       host interface
       (assemble-ipv4-packet (or source (ipv4-interface-address interface) #x00000000)
                             destination
                             protocol
                             payload)))))

(defun multicast-address-p (address)
  (address-equal +ipv4-multicast-network+ (address-network address 4)))

(defgeneric ipv4-receive (protocol packet dest-ip source-ip start end))

(defmethod ipv4-receive (protocol packet dest-ip source-ip start end)
  nil)

(defparameter *print-discarded-packets* nil)
(defparameter *discarded-packet-count* 0)

(defparameter *ipv4-reassembly-timeout* 60
  "Seconds to retain an incomplete IPv4 datagram.")

(defconstant +maximum-ipv4-reassembled-payload-size+ (- #xFFFF 20))
(defconstant +maximum-ipv4-reassemblies+ 64)
(defconstant +maximum-ipv4-fragments-per-datagram+ 128)

(defstruct (ipv4-fragment
             (:constructor make-ipv4-fragment (start data)))
  (start 0 :type (unsigned-byte 16))
  (data #() :type vector))

(defstruct (ipv4-reassembly
             (:constructor make-ipv4-reassembly (updated-at)))
  (updated-at 0 :type integer)
  (fragments '() :type list)
  (total-length nil :type (or null (unsigned-byte 16)))
  (first-header-length nil :type (or null (integer 20 60))))

(defvar *ipv4-reassemblies* (make-hash-table :test 'equal)
  "Incomplete IPv4 datagrams keyed by source, destination, protocol, and ID.")

(defvar *ipv4-reassembly-expiration-scheduled-p* nil
  "True while the single reassembly expiration callback is pending.")

(defun expire-ipv4-reassemblies (&optional (now (get-internal-real-time)))
  (let ((expired-keys '())
        (timeout (* *ipv4-reassembly-timeout*
                    internal-time-units-per-second)))
    (maphash (lambda (key reassembly)
               (when (>= now (+ (ipv4-reassembly-updated-at reassembly)
                                timeout))
                 (push key expired-keys)))
             *ipv4-reassemblies*)
    (dolist (key expired-keys)
      (remhash key *ipv4-reassemblies*))
    (length expired-keys)))

(defun ipv4-reassembly-expiration-handler ()
  (setf *ipv4-reassembly-expiration-scheduled-p* nil)
  (let ((now (get-internal-real-time)))
    (expire-ipv4-reassemblies now)
    (when (plusp (hash-table-count *ipv4-reassemblies*))
      (let ((next-expiration nil)
            (timeout (* *ipv4-reassembly-timeout*
                        internal-time-units-per-second)))
        (maphash (lambda (key reassembly)
                   (declare (ignore key))
                   (let ((expiration (+ (ipv4-reassembly-updated-at reassembly)
                                        timeout)))
                     (when (or (null next-expiration)
                               (< expiration next-expiration))
                       (setf next-expiration expiration))))
                 *ipv4-reassemblies*)
        (setf *ipv4-reassembly-expiration-scheduled-p* t)
        (mezzano.sync.dispatch:dispatch-delayed
         #'ipv4-reassembly-expiration-handler
         (/ (max 0 (- next-expiration now))
            internal-time-units-per-second)
         net::*network-serial-queue*)))))

(defun schedule-ipv4-reassembly-expiration ()
  (unless *ipv4-reassembly-expiration-scheduled-p*
    (setf *ipv4-reassembly-expiration-scheduled-p* t)
    (mezzano.sync.dispatch:dispatch-delayed
     #'ipv4-reassembly-expiration-handler
     *ipv4-reassembly-timeout*
     net::*network-serial-queue*)))

(defun accept-ipv4-fragment (key packet start end fragment-offset
                             more-fragments-p
                             &optional (now (get-internal-real-time))
                               (header-length 20))
  "Accept one IPv4 fragment.
Return the reconstructed payload and :COMPLETE, or NIL and a status keyword."
  (let* ((payload-length (- end start))
         (payload-start (* fragment-offset 8))
         (payload-end (+ payload-start payload-length)))
    (labels ((reject (status)
               (remhash key *ipv4-reassemblies*)
               (return-from accept-ipv4-fragment (values nil status))))
      (when (or (<= payload-length 0)
                (and more-fragments-p
                     (not (zerop (mod payload-length 8)))))
        (reject :invalid-length))
      (when (> payload-end +maximum-ipv4-reassembled-payload-size+)
        (reject :too-large))
      (let ((reassembly (gethash key *ipv4-reassemblies*)))
        (unless reassembly
          (expire-ipv4-reassemblies now)
          (when (>= (hash-table-count *ipv4-reassemblies*)
                    +maximum-ipv4-reassemblies+)
            (return-from accept-ipv4-fragment (values nil :resource-limit)))
          (setf reassembly (make-ipv4-reassembly now)
                (gethash key *ipv4-reassemblies*) reassembly))
        (when (>= (length (ipv4-reassembly-fragments reassembly))
                  +maximum-ipv4-fragments-per-datagram+)
          (reject :resource-limit))
        (when (zerop fragment-offset)
          (when (or (< header-length 20)
                    (> header-length 60)
                    (not (zerop (mod header-length 4))))
            (reject :invalid-header-length))
          (let ((maximum-payload (- #xFFFF header-length)))
            (when (or (> payload-end maximum-payload)
                      (let ((known-total
                              (ipv4-reassembly-total-length reassembly)))
                        (and known-total (> known-total maximum-payload)))
                      (some (lambda (fragment)
                              (> (+ (ipv4-fragment-start fragment)
                                    (length (ipv4-fragment-data fragment)))
                                 maximum-payload))
                            (ipv4-reassembly-fragments reassembly)))
              (reject :too-large)))
          (setf (ipv4-reassembly-first-header-length reassembly)
                header-length))
        (let ((known-total (ipv4-reassembly-total-length reassembly)))
          (when (and known-total
                     (or (> payload-end known-total)
                         (and more-fragments-p
                              (>= payload-end known-total))))
            (reject :inconsistent-total))
          (unless more-fragments-p
            (when (and known-total (not (= known-total payload-end)))
              (reject :inconsistent-total))
            (dolist (fragment (ipv4-reassembly-fragments reassembly))
              (when (> (+ (ipv4-fragment-start fragment)
                          (length (ipv4-fragment-data fragment)))
                       payload-end)
                (reject :inconsistent-total))))
          (dolist (fragment (ipv4-reassembly-fragments reassembly))
            (let ((fragment-start (ipv4-fragment-start fragment))
                  (fragment-end (+ (ipv4-fragment-start fragment)
                                   (length (ipv4-fragment-data fragment)))))
              (when (and (< payload-start fragment-end)
                         (< fragment-start payload-end))
                (reject :overlap))))
          (unless more-fragments-p
            (setf (ipv4-reassembly-total-length reassembly) payload-end)))
        (let ((data (make-array payload-length
                                :element-type '(unsigned-byte 8))))
          (replace data packet :start2 start :end2 end)
          (push (make-ipv4-fragment payload-start data)
                (ipv4-reassembly-fragments reassembly)))
        (setf (ipv4-reassembly-updated-at reassembly) now
              (ipv4-reassembly-fragments reassembly)
              (sort (ipv4-reassembly-fragments reassembly)
                    #'< :key #'ipv4-fragment-start))
        (let ((total-length (ipv4-reassembly-total-length reassembly))
              (next-offset 0))
          (when total-length
            (dolist (fragment (ipv4-reassembly-fragments reassembly))
              (unless (= (ipv4-fragment-start fragment) next-offset)
                (return))
              (incf next-offset (length (ipv4-fragment-data fragment))))
            (when (= next-offset total-length)
              (let ((payload (make-array total-length
                                         :element-type '(unsigned-byte 8))))
                (dolist (fragment (ipv4-reassembly-fragments reassembly))
                  (replace payload (ipv4-fragment-data fragment)
                           :start1 (ipv4-fragment-start fragment)))
                (remhash key *ipv4-reassemblies*)
                (return-from accept-ipv4-fragment
                  (values payload :complete))))))
        (schedule-ipv4-reassembly-expiration)
        (values nil :pending)))))

(defmethod mezzano.network.ethernet:ethernet-receive
    ((ethertype (eql mezzano.network.ethernet:+ethertype-ipv4+))
     interface packet start end)
  (let ((actual-length (- end start)))
    (when (< actual-length 20)
      ;; Runt packet with an incomplete header.
      (when *print-discarded-packets*
        (format t "Discarding runt IPv4 packet (~D bytes).~%" actual-length))
      (incf *discarded-packet-count*)
      (return-from mezzano.network.ethernet:ethernet-receive))
    (let* ((version-and-ihl (aref packet (+ start +ipv4-header-version-and-ihl+)))
           (version (ldb (byte +ipv4-header-version-size+ +ipv4-header-version-position+)
                         version-and-ihl))
           (header-length (* (ldb (byte +ipv4-header-ihl-size+ +ipv4-header-ihl-position+)
                                  version-and-ihl)
                             4))
           (total-length (ub16ref/be packet (+ start +ipv4-header-total-length+)))
           (identification (ub16ref/be packet (+ start +ipv4-header-identification+)))
           (frag-control (ub16ref/be packet (+ start +ipv4-header-fragmentation-control+)))
           (frag-offset (ldb (byte +ipv4-header-fragment-offset-size+ +ipv4-header-fragment-offset-position+)
                             frag-control))
           (ttl (aref packet (+ start +ipv4-header-ttl+)))
           (protocol (aref packet (+ start +ipv4-header-protocol+)))
           (source-ip (make-ipv4-address (ub32ref/be packet (+ start +ipv4-header-source-ip+))))
           (dest-ip (make-ipv4-address (ub32ref/be packet (+ start +ipv4-header-destination-ip+)))))
      (declare (ignore ttl))
      (when (not (eql version 4))
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with bad version ~D.~%" version))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (< header-length 20)
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with too-short header-length ~D.~%" header-length))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (> header-length actual-length)
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with too-long header-length ~D (max ~D).~%" header-length actual-length))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (> header-length total-length)
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with too-short total-length ~D (smaller than header-length ~D).~%" total-length header-length))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (> total-length actual-length)
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with too-long total-length ~D (max ~D).~%" total-length actual-length))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (logbitp +ipv4-header-flag-reserved+ frag-control)
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with reserved flag set.~%"))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (when (not (eql (compute-ip-checksum packet start (+ start header-length)) 0))
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet with bad header checksum.~%"))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      ;; Is it address to one of our interfaces?
      ;; If not, forward or reject it.
      (when (and (not (address-equal dest-ip +ipv4-broadcast-local-network+)) ; not broadcast
		 (not (ipv4-address-interface dest-ip nil))
                 ;; Interface broadcast address.
                 (multiple-value-bind (interface-address prefix-length)
                     (ipv4-interface-address interface nil)
                   (not (and interface-address
                             (address-equal
                              dest-ip
                              (address-network-broadcast interface-address prefix-length)))))
                 (not (multicast-address-p dest-ip)))
        (when *print-discarded-packets*
          (format t "Discarding IPv4 packet addressed to someone else. ~A~%" dest-ip))
        (incf *discarded-packet-count*)
        (return-from mezzano.network.ethernet:ethernet-receive))
      (let ((more-fragments-p
              (logbitp +ipv4-header-flag-more-fragments+ frag-control)))
        (cond ((or (not (zerop frag-offset)) more-fragments-p)
               (when (logbitp +ipv4-header-flag-do-not-fragment+ frag-control)
                 (when *print-discarded-packets*
                   (format t "Discarding fragmented IPv4 packet with DF set.~%"))
                 (incf *discarded-packet-count*)
                 (return-from mezzano.network.ethernet:ethernet-receive))
               (multiple-value-bind (payload status)
                   (accept-ipv4-fragment
                    (list (ipv4-address-address source-ip)
                          (ipv4-address-address dest-ip)
                          protocol identification)
                    packet (+ start header-length) (+ start total-length)
                    frag-offset more-fragments-p
                    (get-internal-real-time) header-length)
                 (case status
                   (:complete
                    (ipv4-receive protocol payload dest-ip source-ip
                                  0 (length payload)))
                   (:pending)
                   (t
                    (when *print-discarded-packets*
                      (format t "Discarding invalid IPv4 fragment (~A).~%" status))
                    (incf *discarded-packet-count*)))))
              (t
               (ipv4-receive protocol packet
                             dest-ip source-ip
                             (+ start header-length) (+ start total-length))))))))

;;; IP addresses.

(defstruct (ipv4-address
             (:constructor %make-ipv4-address (address)))
  (address 0 :read-only t :type (unsigned-byte 32)))

(defun make-ipv4-address (address)
  "Turn ADDRESS into an IPv4 address object.
ADDRESS can be a string containing an IP address in dotted-decimal notation,
A sequence of 4 octets, with element 0 being the MSB and element 3 the LSB,
an (UNSIGNED-BYTE 32) or an IPV4-ADDRESS."
  (etypecase address
    (ipv4-address
     address)
    ((unsigned-byte 32)
     (%make-ipv4-address address))
    (string
     (make-ipv4-address (parse-ipv4-address address)))
    (sequence
     (assert (eql (length address) 4))
     (assert (every (lambda (x) (typep x 'octet)) address))
     (make-ipv4-address (logior (ash (elt address 0) 24)
                                (ash (elt address 1) 16)
                                (ash (elt address 2) 8)
                                (elt address 3))))))

(defun format-ipv4-address (stream argument &optional colon-p at-sign-p)
  "Print the (UNSIGNED-BYTE 32) argument in dotted-decimal notation."
  (check-type argument (unsigned-byte 32))
  (assert (and (not colon-p)
               (not at-sign-p)))
  (format stream "~D.~D.~D.~D"
          (ldb (byte 8 24) argument)
          (ldb (byte 8 16) argument)
          (ldb (byte 8 8) argument)
          (ldb (byte 8 0) argument)))

(defun ipv4-address-to-string (ipv4-address)
  (format-ipv4-address nil (ipv4-address-address ipv4-address)))

(defmethod print-object ((object ipv4-address) stream)
  (if (or *print-readably*
          *print-escape*)
      (call-next-method)
      (format-ipv4-address stream (ipv4-address-address object))))

(define-condition invalid-ipv4-address (simple-error)
  ((address :initarg :address
            :reader invalid-ipv4-address-address)))

(defun parse-ipv4-address (address &key (start 0) end)
  "Interpret the string ADDRESS as an IPv4 address in dotted-decimal notation,
 returning the parsed address as an (UNSIGNED-BYTE 32).
If ADDRESS is not a valid IPv4 address, an error of type INVALID-IPV4-ADDRESS is signalled."
  (setf address (string address))
  (unless end (setf end (length address)))
  (let ((value 0)
        (octet 0)
        (seen-dots 0))
    (dotimes (i (- end start))
      (let* ((c (char address (+ start i)))
             (weight (digit-char-p c)))
        (cond ((char= c #\.)
               (incf seen-dots)
               (when (>= seen-dots 4)
                 (error 'invalid-ipv4-address
                        :address address
                        :format-control "Too many dots in address ~S."
                        :format-arguments (list address)))
               (when (>= octet 256)
                 (error 'invalid-ipv4-address
                        :address address
                        :format-control "Part ~D too large in address ~S."
                        :format-arguments (list (1- seen-dots) address)))
               (setf value (+ (ash value 8)
                              octet)
                     octet 0))
              (weight
               (setf octet (+ (* octet 10)
                              weight)))
              (t (error 'invalid-ipv4-address
                        :address address
                        :format-control "Invalid character ~:C in address ~S."
                        :format-arguments (list c address))))))
    (when (>= octet (ash 1 (* (- 4 seen-dots) 8)))
      (error 'invalid-ipv4-address
             :address address
             :format-control "Final part too large in address ~S."
             :format-arguments (list address)))
    (setf value (+ (ash value (* (- 4 seen-dots) 8))
                   octet))
    (check-type value (unsigned-byte 32))
    value))

;; DEFPARAMETER, not DEFCONSTANT, due to cross-compiler constraints.
(defparameter +ipv4-broadcast-source+ (make-ipv4-address #x00000000))
(defparameter +ipv4-broadcast-local-network+ (make-ipv4-address #xFFFFFFFF))
(defparameter +ipv4-multicast-network+ (make-ipv4-address "224.0.0.0"))

(defgeneric address-equal (x y))

(defgeneric address-network (local-ip prefix-length)
  (:documentation "Return the address of LOCAL-IP's network, based on PREFIX-LENGTH."))

(defgeneric address-network-broadcast (local-ip prefix-length)
  (:documentation "Return the network broadcast address of LOCAL-IP, based on PREFIX-LENGTH."))

(defgeneric address-host (local-ip prefix-length)
  (:documentation "Return the address of LOCAL-IP's host, based on PREFIX-LENGTH."))

(defmethod address-equal ((x ipv4-address) (y ipv4-address))
  (eql (ipv4-address-address x) (ipv4-address-address y)))

(defmethod address-network ((local-ip ipv4-address) prefix-length)
  (check-type prefix-length (integer 0 32))
  (let ((mask (ash (1- (ash 1 prefix-length)) (- 32 prefix-length))))
    (make-ipv4-address (logand (ipv4-address-address local-ip)
                               mask))))

(defmethod address-network-broadcast ((local-ip ipv4-address) prefix-length)
  (check-type prefix-length (integer 0 32))
  (let ((mask (ash (1- (ash 1 prefix-length)) (- 32 prefix-length))))
    (make-ipv4-address (logior (logand (ipv4-address-address local-ip)
                                       mask)
                               (logxor #xFFFFFFFF mask)))))

(defmethod address-host ((local-ip ipv4-address) prefix-length)
  (check-type prefix-length (integer 0 32))
  (let ((mask (ash (1- (ash 1 prefix-length)) (- 32 prefix-length))))
    (make-ipv4-address (logand (ipv4-address-address local-ip)
                               (lognot mask)))))

;;; ICMP.

(defconstant +icmp4-header-size+ 8)
(defconstant +icmp4-type+ 0)
(defconstant +icmp4-code+ 1)
(defconstant +icmp4-checksum+ 2)
(defconstant +icmp4-identifier+ 4)
(defconstant +icmp4-sequence-number+ 6)

(defvar *icmp-listeners* '())
(defvar *icmp-listener-lock* (mezzano.supervisor:make-mutex "ICMP listener list"))

(defmethod ipv4-receive ((protocol (eql +ip-protocol-icmp+)) packet dest-ip source-ip start end)
  (declare (ignore dest-ip))
  (let ((length (- end start)))
    (when (< length +icmp4-header-size+)
      (format t "Discarding runt ICMPv4 packet from ~A.~%" source-ip)
      (return-from ipv4-receive))
    (let ((type (aref packet (+ start +icmp4-type+)))
          (code (aref packet (+ start +icmp4-code+)))
          (identifier (ub16ref/be packet (+ start +icmp4-identifier+)))
          (sequence-number (ub16ref/be packet (+ start +icmp4-sequence-number+))))
      (when (not (eql (compute-ip-checksum packet start end) 0))
        (format t "Discarding ICMPv4 packet with bad header checksum.~%")
        (return-from ipv4-receive))
      (dolist (l *icmp-listeners*)
        (funcall (first l) packet source-ip start end))
      (case type
        (#.+icmp-echo-request+
         (format t "Responding to ping from ~A.~%" source-ip)
         (transmit-icmp-packet source-ip
                               +icmp-echo-reply+ 0
                               identifier sequence-number
                               (subseq packet (+ start +icmp4-header-size+) end)))
        (#.+icmp-echo-reply+)
        (t (format t "Ignoring ICMP packet with unknown type/code ~D/~D.~%"
                   type code))))))

(defun transmit-icmp-packet (destination type code &optional (identifier 0) (sequence-number 0) payload)
  (let ((packet (make-array (+ +icmp4-header-size+ (if payload (length payload) 0))
                            :element-type '(unsigned-byte 8))))
    (setf (aref packet +icmp4-type+) type
          (aref packet +icmp4-code+) code
          (ub16ref/be packet +icmp4-checksum+) 0
          (ub16ref/be packet +icmp4-identifier+) identifier
          (ub16ref/be packet +icmp4-sequence-number+) sequence-number)
    (when payload
      (replace packet payload :start1 +icmp4-header-size+))
    (setf (ub16ref/be packet +icmp4-checksum+) (mezzano.network.ip:compute-ip-checksum packet))
    (transmit-ipv4-packet nil destination +ip-protocol-icmp+ (list packet))))

(defun send-ping (destination &optional (identifier 0) (sequence-number 0) payload)
  (when (not payload)
    (setf payload (make-array 56 :element-type '(unsigned-byte 8)))
    (dotimes (i 56)
      (setf (aref payload i) i)))
  (transmit-icmp-packet destination +icmp-echo-request+ 0 identifier sequence-number payload))

(defmacro with-icmp-listener (listener &body body)
  `(call-with-icmp-listener ,listener (lambda () ,@body)))

(defun call-with-icmp-listener (listener fn)
  (setf listener (cons listener nil))
  (unwind-protect
       (progn
         (mezzano.supervisor:with-mutex (*icmp-listener-lock*)
           (push listener *icmp-listeners*))
         (funcall fn))
    (mezzano.supervisor:with-mutex (*icmp-listener-lock*)
      (setf *icmp-listeners* (remove listener *icmp-listeners*)))))

(defun ping-host (host &key (count 4) quiet)
  (let ((in-flight-pings nil)
        (received-packets '())
        (identifier 1234)
        (host-ip (net::resolve-address host))
        (rx-lock (mezzano.supervisor:make-mutex "ping lock")))
    (with-icmp-listener
        (lambda (packet source-ip start end)
          (mezzano.supervisor:with-mutex (rx-lock)
            (push (list packet source-ip start end) received-packets)))
      (dotimes (i count)
        (push i in-flight-pings)
        (send-ping host-ip identifier i))
      (let ((timeout-absolute (+ (get-universal-time) 10)))
        (loop
           (let ((packets (mezzano.supervisor:with-mutex (rx-lock)
                            (prog1 received-packets
                              (setf received-packets '())))))
             (loop
                for (packet source-ip start end) in packets
                do (when (and (address-equal source-ip host-ip)
                              (eql (aref packet (+ start +icmp4-type+)) +icmp-echo-reply+)
                              (eql (ub16ref/be packet (+ start +icmp4-identifier+)) identifier))
                     (let ((seq (ub16ref/be packet (+ start +icmp4-sequence-number+))))
                       (when (find seq in-flight-pings)
                         (setf in-flight-pings (remove seq in-flight-pings))
                         (when (not quiet)
                           (format t "Pong ~S.~%" seq)))))))
           (when (or (> (get-universal-time) timeout-absolute)
                     (null in-flight-pings))
             (return))
           (sleep 0.01)))
      (when (and in-flight-pings
                 (not quiet))
        (format t "~S pings still in-flight.~%" (length in-flight-pings)))
      (values (not (eql count (length in-flight-pings)))
              (length in-flight-pings)))))
