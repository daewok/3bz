(in-package 3bz)

;; libz says these are enough entries for zlib as specified
(defconstant +max-tree-entries/len+ 852)
(defconstant +max-tree-entries/dist+ 592)
(defconstant +max-tree-size+ (+ +max-tree-entries/len+
                                +max-tree-entries/dist+))

;; low-bit tags for nodes in tree
(defconstant +ht-literal+ #b00)
(defconstant +ht-link/end+ #b01)
(defconstant +ht-len/dist+ #b10)
(defconstant +ht-invalid+ #b11)

;; 'end' code in lit/len alphabet
(defconstant +end-code+ 256)
;; first length code in lit/len alphabet
(defconstant +lengths-start+ 257)
;; last valid length (there are some extra unused values to fill tree)
(defconstant +lengths-end+ 285)
;; offset of length codes in extra-bits tables
(defconstant +lengths-extra-bits-offset+ 32)

(deftype ht-bit-count-type ()'(unsigned-byte 4))
(deftype ht-offset-type ()'(unsigned-byte 11))
(deftype ht-node-type ()'(unsigned-byte 16))
(deftype ht-node-array-type () `(simple-array ht-node-type (,+max-tree-size+)))


;; accessors/predicates/constructors for node in tree
;; low bits 00 = literal
;; low bits 01 = link flag, #x0001 = end, #xffff = invalid
;; low bits 10 = len/dist
;; (low bits 11 = invalid)

(declaim (inline ht-linkp ht-invalidp ht-endp ht-node-type
                 ht-link-bits ht-link-offset
                 ht-literalp ht-value
                 ht-link-node ht-literal-node ht-len-node ht-dist-node
                 ht-invalid-node ht-end-node))
(defun ht-linkp (node)
  (oddp node))
(defun ht-invalidp (node)
  (= node #xffff))
;; (usually will just check for link bits or link-offset = 0 for endp)
(defun ht-endp (node)
  (= node #x0001))
(defun ht-node-type (node)
  (ldb (byte 2 0) node))

;; for valid link, store 4 bits of bit-count, 11 bits of table base
(defun ht-link-node (bits index)
  (logior +ht-link/end+
          (ash bits 2)
          (ash index 6)))
(defun ht-link-bits (node)
  (ldb (byte 4 2) node))
(defun ht-link-offset (node)
  (ldb (byte 10 6) node))


(defun ht-literalp (node)
  (zerop (ldb (byte 2 0) node)))
(defun ht-len/dist-p (node)
  (= 1 (ldb (byte 2 0) node)))
;; literals, length and distance just store a value. for literals, it
;; is the code value, for len/dist it is index into base and
;; extra-bits arrays
(defun ht-value (node)
  (ldb (byte 14 2) node))

(defun ht-literal-node (value)
  (logior +ht-literal+
          (ash value 2)))

(defun ht-len-node (value)
  (assert (>= value +lengths-start+))
  (logior +ht-len/dist+
          ;; value stored in tree is offset so we can use single table
          ;; for extra-bits and base-values for lengths and distances
          (ash (+ +lengths-extra-bits-offset+
                  (if (>= value +lengths-start+)
                      (- value +lengths-start+)
                      value))
               2)))

(defun ht-dist-node (value)
  (logior +ht-len/dist+
          (ash value 2)))

(defun ht-invalid-node () #xffff)
(defun ht-end-node () #x0001)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defstruct (huffman-tree (:conc-name ht-))
    (len-start-bits 0 :type ht-bit-count-type)
    (dist-start-bits 0 :type ht-bit-count-type)
    (dist-offset 0 :type ht-offset-type)
    (nodes (make-array +max-tree-size+ :element-type 'ht-node-type
                                       :initial-element (ht-invalid-node))
     :type ht-node-array-type)))

(deftype code-table-type () '(simple-array (unsigned-byte 4) 1))

(defparameter *fixed-lit/length-table*
  (concatenate 'code-table-type
               (make-array (1+ (- 143 0)) :initial-element 8)
               (make-array (1+ (- 255 144)) :initial-element 9)
               (make-array (1+ (- 279 256)) :initial-element 7)
               (make-array (1+ (- 287 280)) :initial-element 8)))

(defparameter *fixed-dist-table*
  (coerce (make-array 32 :initial-element 5) 'code-table-type))

;; extra-bits and len/dist-bases store
(declaim (type (simple-array (unsigned-byte 4)
                             (#. (+ 29 +lengths-extra-bits-offset+)))
               *extra-bits*)
         (type (simple-array (unsigned-byte 16)
                             (#. (+ 29 +lengths-extra-bits-offset+)))
               *len/dist-bases*))

(alexandria:define-constant +extra-bits+
    (concatenate
     '(simple-array (unsigned-byte 4) (61))
     (replace (make-array +lengths-extra-bits-offset+ :initial-element 0)
              #(0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12 13 13))
     #(0 0 0 0 0 0 0 0 1 1 1 1 2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 0))
  :test 'equalp)


;; base length value for each length/distance code, add to extra bits
;; to get length
(alexandria:define-constant +len/dist-bases+
    (concatenate '(simple-array (unsigned-byte 16) (61))
                 (replace (make-array +lengths-extra-bits-offset+ :initial-element 0)
                          #(1 2 3 4 5 7 9 13 17 25 33 49 65 97
                            129 193 257 385 513 769
                            1025 1537 2049 3073 4097 6145 8193
                            12289 16385 24577))
                 #(3 4 5 6 7 8 9 10 11 13 15 17 19 23 27 31 35 43 51 59 67 83 99
                   115 131 163 195 227 258))
  :test 'equalp)

(declaim (type (simple-array (unsigned-byte 15) (32768)) *bit-rev-table*))
(defparameter *bit-rev-table*
  (coerce (loop for i below (expt 2 15)
                collect (parse-integer
                         (reverse (format nil "~15,'0b" i)) :radix 2))
          '(simple-array (unsigned-byte 15) (*))))

(declaim (inline bit-rev))
(defun bit-rev (x bits)
  (declare (type (unsigned-byte 15) x))
  (ldb (byte bits (- 15 bits)) (aref *bit-rev-table* x)))

(defun build-tree-part (tree tree-offset table type start end)
  (declare (type fixnum tree-offset start end)
           (type code-table-type table))
  ;; # of entries of each bit size
  (declare (optimize speed))
  (let* ((counts (let ((a (make-array 16 :element-type '(unsigned-byte 11)
                                         :initial-element 0)))
                   (loop for x from start below end
                         for i = (aref table x)
                         when (plusp i) do (incf (aref a i)))
                   a))
         ;; first position of each used bit size
         (offsets (let ((c 0))
                    (declare (type (unsigned-byte 11) c))
                    (map '(simple-array (unsigned-byte 11) (16))
                         (lambda (a)
                           (prog1
                               (if (zerop a) 0 c)
                             (incf c a)))
                         counts)))
         ;; first code of each used bit size
         (code-offsets (let ((c 0))
                         (declare (type (unsigned-byte 17) c))
                         (map '(simple-array (unsigned-byte 16) (16))
                              (lambda (a)
                                (prog1
                                    (if (zerop a) 0 c)
                                  (setf c (ash (+ c a) 1))))
                              counts)))
         ;; range of bit sizes used
         (min (position-if-not 'zerop counts))
         ;; temp space for sorting table
         (terminals (make-huffman-tree)))
    (declare (type (or null (unsigned-byte 4)) min)
             (type (simple-array (unsigned-byte 11) (16)) counts))
    (unless min
      (return-from build-tree-part (values 0 0)))
    ;; sort table/allocate codes
    (loop with offset-tmp = (copy-seq offsets)
          for i fixnum from 0
          for to fixnum from start below end
          for l = (aref table to)
          for nodes of-type (simple-array (unsigned-byte 16) 1)
            = (ht-nodes terminals)
          for o = (aref offset-tmp l)
          for co = (aref code-offsets l)
          when (plusp l)
            do (incf (aref offset-tmp l))
               (cond
                 ((member type '(:dist :dht-len))
                  (setf (aref nodes o)
                        (if (<= i 29)
                            (ht-dist-node i)
                            ;; codes above 29 aren't used
                            (ht-invalid-node))))
                 ((> i +lengths-end+)
                  (setf (aref nodes o) (ht-invalid-node)))
                 ((>= i +lengths-start+)
                  (setf (aref nodes o) (ht-len-node i)))
                 ((= i +end-code+)
                  (setf (aref nodes o) (ht-end-node)))
                 (t
                  (setf (aref nodes o) (ht-literal-node i)))))

    ;; fill tree:
    (let ((next-subtable tree-offset))
      (declare (type (unsigned-byte 12) next-subtable))
      (labels ((next-len (l)
                 (position-if 'plusp counts :start l))
               (subtable (prefix prefix-bits)
                 (declare (ignorable prefix))
                 (or
                  (loop for entry-bits = (next-len prefix-bits)
                        while entry-bits
                        if (= prefix-bits entry-bits)
                          return (prog1 (aref (ht-nodes terminals)
                                              (aref offsets entry-bits))
                                   (incf (aref offsets entry-bits))
                                   (decf (aref counts entry-bits)))
                        else
                          return (let ((start next-subtable)
                                       (b  (- entry-bits prefix-bits)))
                                   (declare (type (unsigned-byte 16) b))
                                   (incf next-subtable (expt 2 b))
                                   (loop for i below (expt 2 b)
                                         do (setf (aref (ht-nodes tree)
                                                        (+ start (bit-rev i b)))
                                                  (subtable i entry-bits)))
                                   (values (ht-link-node b start))))
                  (ht-invalid-node))))
        (incf next-subtable (expt 2 min))
        (loop for i below (expt 2 min)
              do (setf (aref (ht-nodes tree)
                             (+ tree-offset (bit-rev i min)))
                       (subtable i min))))
      (values next-subtable min))))

(defun build-tree (tree lit/len dist)
  (declare (optimize speed)
           (type code-table-type lit/len dist))
  (multiple-value-bind (count bits)
      (build-tree-part tree 0 lit/len :lit/len 0 (length lit/len))
    (setf (ht-len-start-bits tree) bits)
    (setf (ht-dist-offset tree) count)
    (setf (ht-dist-start-bits tree)
          (nth-value 1 (build-tree-part tree count dist :dist
                                        0 (length dist))))))

(defun build-tree* (tree lit/len/dist mid end)
  (declare (optimize speed)
           (type (vector (unsigned-byte 4)) lit/len/dist)
           (type (and unsigned-byte fixnum) mid))
  (multiple-value-bind (count bits)
      (build-tree-part tree 0 lit/len/dist :lit/len 0 mid)
    (setf (ht-len-start-bits tree) bits)
    (setf (ht-dist-offset tree) count)
    (setf (ht-dist-start-bits tree)
          (nth-value 1 (build-tree-part tree count
                                        lit/len/dist :dist
                                        mid end)))
    #++(dump-tree tree)))

(defun dump-tree (tree &key bits base (depth 0))
  (cond
    ((and bits base)
     (loop for i below (expt 2 bits)
           for node = (aref (ht-nodes tree) (+ i base))
           do (format *debug-io* "~a~4,' d: ~a~%"
                      (make-string depth :initial-element #\~)
                      i
                      (ecase (ht-node-type node)
                        (#.+ht-literal+ (list :literal (ht-value node)))
                        (#.+ht-link/end+
                         (if (ht-endp node) :end
                             (list :link
                                   :bits (ht-link-bits node)
                                   :offset (ht-link-offset node))))
                        (#.+ht-len/dist+
                         (let ((v  (ht-value node)))
                           (list :len/dist v
                                 (when (> v +lengths-extra-bits-offset+)
                                   (+ v
                                      +lengths-start+
                                      (- +lengths-extra-bits-offset+)))
                                 :start (aref +len/dist-bases+ v)
                                 :end (+ (aref +len/dist-bases+ v)
                                         (1- (expt 2 (aref +extra-bits+ v)))))))
                        (#.+ht-invalid+ :invalid)))
              (when (and (ht-linkp node)
                         (not (or (ht-endp node)
                                  (ht-invalidp node))))
                (dump-tree tree :bits (ht-link-bits node)
                                :base (ht-link-offset node)
                                :depth (+ depth 2)))))
    (t
     (format *debug-io* "lit/len table:~%")
     (dump-tree tree :bits (ht-len-start-bits tree)
                     :base 0 :depth 1)
     (format *debug-io* "distance table:~%")
     (when (plusp (ht-dist-start-bits tree))
       (dump-tree tree :bits (ht-dist-start-bits tree)
                       :base (ht-dist-offset tree)
                       :depth 1)))))

(defconstant +static-huffman-tree+ (if (boundp '+static-huffman-tree+)
                                       +static-huffman-tree+
                                       (make-huffman-tree)))

(build-tree +static-huffman-tree+ *fixed-lit/length-table* *fixed-dist-table*)
(dump-tree +static-huffman-tree+)

(defstruct (deflate-state (:conc-name ds-))
  ;; storage for dynamic huffman tree, modified for each dynamic block
  (dynamic-huffman-tree (make-huffman-tree) :type huffman-tree)
  ;; reference to either dynamic-huffman-tree or *static-huffman-tree*
  ;; depending on curret block
  (current-huffman-tree +static-huffman-tree+ :type huffman-tree)
  ;; # of bits to read for current huffman tree level
  (tree-bits 0 :type ht-bit-count-type)
  ;; offset of current subtable in nodes array of current-huffman-tree
  (tree-offset 0 :type ht-offset-type)
  ;; # of extra bits being read in extra-bits state
  (extra-bits-needed 0 :type ht-bit-count-type)
  ;; last literal decoded from huffman tree
  ;; (last-decoded-literal 0 :type (unsigned-byte 8)) ;; unused?
  ;; last decoded length/distance value
  (last-decoded-len/dist 0 :type (unsigned-byte 16))
  ;; indicate consumer of extra bits
  (extra-bits-type 0 :type (unsigned-byte 2))
  ;; set when reading last block
  (last-block-flag nil :type (or nil t))
  ;; number of bytes left to copy (for uncompressed block, or from
  ;; history in compressed block)
  (bytes-to-copy 0 :type (unsigned-byte 16))
  ;; offset (from current output position) in history of source of
  ;; current copy in compressed block
  (history-copy-offset 0 :type (unsigned-byte 16))
  ;; current state machine state
  (current-state :start-of-block)
  ;; output ring-buffer (todo: generalize this)
  (output-buffer (make-array 65536 :element-type '(unsigned-byte 8)))
  (output-index 0 :type (unsigned-byte 16))
  ;; dynamic huffman tree parameters being read
  (dht-hlit 0 :type  (unsigned-byte 10))
  (dht-hlit+hdist 0 :type (unsigned-byte 10))
  (dht-hclen 0 :type octet)
  (dht-len-code-index 0 :type octet)
  (dht-len-codes (make-array 20 :element-type '(unsigned-byte 4)
                                :initial-element 0)
   :type code-table-type)
  (dht-len-tree (make-huffman-tree)) ;; fixme: reduce size
  (dht-lit/len/dist (make-array (+ 288 32) :element-type '(unsigned-byte 4)
                                           :initial-element 0)
   :type code-table-type)
  (dht-lit/len/dist-index 0 :type (mod 320))
  (dht-last-len 0 :type octet)
  ;; bitstream state: we read up to 64bits at a time to try to
  ;; minimize time spent interacting with input stream relative to
  ;; decoding time.
  (partial-bits 0 :type (unsigned-byte 64))
  ;; # of valid bits remaining in partial-bits (0 = none)
  ;; (bits-remaining 0 :type (unsigned-byte 6)) bit offset of
  ;; remaining valid bits in partial-bits. 64 = none remaining.  note
  ;; that when storing less than 64 bits (at end of input, etc), we
  ;; need to use upper bits
  (partial-bit-offset 64 :type (unsigned-byte 7)))
(defmacro with-bit-readers ((state) &body body)
  `(macrolet (;; use cached bits (only called when we can fill current
              ;; read from cache)
              (%use-partial-bits (n n2)
                `(prog1
                     (ldb (byte ,n (ds-partial-bit-offset ,',state))
                          (ds-partial-bits ,',state))
                   (setf (ds-partial-bit-offset ,',state) ,n2)))
              ;; try to get more bits from source (only called when
              ;; there aren't enough already read)
              (%try-read-bits (n interrupt-form)
                (with-gensyms (tmp o r n2 n3 input octets)
                  `(let ((,tmp 0)
                         (,o 0))
                     (declare (type (unsigned-byte 6) ,o)
                              (type (unsigned-byte 16) ,tmp)
                              (type (unsigned-byte 6) ,n))
                     (flet ((int ()
                              ;; if we ran out of input, store what we
                              ;; have so we can try again later
                              (assert (< ,o 16))
                              (let ((,r (- 64 ,o)))
                                (declare (type (unsigned-byte 6) ,r)
                                         (type (unsigned-byte 4) ,o))
                                (setf (ds-partial-bit-offset ,',state) ,r)
                                (setf (ds-partial-bits ,',state)
                                      (ldb (byte 64 0)
                                           (ash (ldb (byte ,o 0) ,tmp) ,r))))
                              ;; and let caller decide what to do next
                              ,interrupt-form))
                       ;; we had some leftover bits, try to use them
                       ;; before getting more input
                       (when (< (ds-partial-bit-offset ,',state) 64)
                         (let ((,r (- 64 (ds-partial-bit-offset ,',state))))
                          (assert (<= ,r 16))
                           (setf ,tmp
                                 (ldb (byte ,r (ds-partial-bit-offset ,',state))
                                      (ds-partial-bits ,',state)))
                           (setf ,o ,r)))
                       ;; try to read more bits from input
                       (multiple-value-bind (,input ,octets)
                           (word64)
                         (cond
                           ((= ,octets 8)
                            (setf (ds-partial-bit-offset ,',state) 0
                                  (ds-partial-bits ,',state) ,input))
                           ((zerop ,octets)
                            (setf (ds-partial-bit-offset ,',state) 64))
                           (t
                            (let ((,r (* 8 (- 8 ,octets))))
                              (declare (type (unsigned-byte 6) ,r))
                              (setf (ds-partial-bit-offset ,',state) ,r)
                              (setf (ds-partial-bits ,',state)
                                    (ldb (byte 64 0) (ash ,input ,r)))))))
                       ;; consume any additional available input
                       (let* ((,n2 (- ,n ,o))
                              (,n3 (+ (ds-partial-bit-offset ,',state) ,n2)))
                         (cond
                           ;; we have enough bits to finish read
                           ((< ,n3 64)
                            (setf ,tmp
                                  (ldb (byte 16 0)
                                       (logior ,tmp
                                               (ash (ldb (byte ,n2 (ds-partial-bit-offset ,',state))
                                                         (ds-partial-bits ,',state))
                                                    ,o))))
                            (setf (ds-partial-bit-offset ,',state) ,n3))
                           ;; we have some bits, but not enough. consume
                           ;; what is available and error
                           ((< (ds-partial-bit-offset ,',state) 64)
                            (let ((,r (- 64 (ds-partial-bit-offset ,',state))))
                              (setf ,tmp
                                    (ldb (byte 16 0)
                                         (logior ,tmp
                                                 (ash (ldb (byte ,r (ds-partial-bit-offset ,',state))
                                                           (ds-partial-bits ,',state))
                                                      ,o))))
                              (incf ,o ,r)
                              (int)))
                           ;; didn't get any new bits, error
                           (t
                            (int)))))
                     ;; if we got here, return results
                     ,tmp)))
              (bits (n interrupt-form)
                (with-gensyms (n2)
                  (once-only (n)
                   `(let ((,n2 (+ (ds-partial-bit-offset ,',state)
                                  (the (unsigned-byte 6) ,n))))
                      (if (<= ,n2 64)
                          (%use-partial-bits ,n ,n2)
                          (%try-read-bits ,n ,interrupt-form))))))
              (byte-align ()
                `(setf (ds-partial-bit-offset ,',state)
                       (* 8 (ceiling (ds-partial-bit-offset ,',state) 8)))))
     ,@body))




(defmacro state-machine ((state) &body tagbody)
  (with-gensyms (next-state)
    (let ((tags (loop for form in tagbody when (atom form) collect form)))
      `(macrolet ((next-state (,next-state)
                    `(progn
                       #++(setf (ds-current-state ,',state) ',,next-state)
                       (go ,,next-state))))
         (tagbody
            ;; possibly could do better than a linear search here, but
            ;; if state machine is being interrupted often enough to
            ;; matter, it probably won't matter anyway :/ at most,
            ;; maybe define more commonly interrupted states earlier
            (ecase (ds-current-state ,state)
              ,@(loop for i in tags
                      collect `(,i (go ,i))))
            ,@(loop for f in tagbody
                    collect f
                    when (atom f)
                      ;;collect `(format *debug-io* "=>~s~%" ',f) and
                      collect `(setf (ds-current-state ,state) ',f)))))))


(declaim (type (simple-array octet (19)) *len-code-order*))
(alexandria:define-constant +len-code-order+
    (coerce #(16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15)
            '(simple-array (unsigned-byte 8) (19)))
  :test 'equalp)

(defparameter *stats* (make-hash-table))
(defun decompress (read-context state &key into)
  (declare (type (or null octet-vector) into)
           (optimize speed))
  (with-reader-contexts (read-context)
    (with-bit-readers (state)
      (let ((output (ds-output-buffer state))
            (out nil)
            (count 0))
        (declare (type (simple-array (unsigned-byte 8) (65536)) output)
                 (fixnum count))
        (labels ((copy-output (from to)
                   (if into
                       (replace into output
                                :start1 count
                                :start2 from :end2 to)
                       (push (subseq output from to) out))
                   (incf count (- to from)))
                 (out-byte (x)
                   #++(format t " ~2,'0x" x)
                   #++(if (<= 32 x 127)
                          (format t " {~c}" (code-char x))
                          (format t " <~d>" x))
                   #++(format *debug-io* "##out ~2,'0x~%" x)
                   (setf (aref output (ds-output-index state)) x)
                   (setf (ds-output-index state)
                         (ldb (byte 16 0) (1+ (ds-output-index state))))
                   (when (zerop (ds-output-index state))
                     (copy-output 32768 65536))
                   (when (= 32768 (ds-output-index state))
                     (copy-output 0 32768)))
                 (copy-history-byte (offset)
                   (declare (type (unsigned-byte 16) offset))
                   #++(format *debug-io* "copy history ~s~%" offset)
                   (let ((x (aref output (ldb (byte 16 0)
                                              (- (ds-output-index state)
                                                 offset)))))
                     (out-byte x)))
                 (copy-history (n)
                   (declare (type fixnum n))
                   (let ((o (ds-history-copy-offset state)))
                     #++(loop repeat n do (copy-history-byte o))
                     (let* ((d (ds-output-index state))
                            (s (ldb (byte 16 0) (- d o)))
                            (n1 n)
                            (e (- 65536 n 8)))
                       (declare (type (unsigned-byte 16) d s))
                       ;; if either range overlaps end of ring buffer,
                       ;; copy by bytes until neither overlaps
                       (when (or (>= s e)
                                 (>= d e))
                         (loop until (zerop n)
                               until (and (< s e)
                                          (< d e))
                               do (setf (aref output d) (aref output s))
                                  (setf d (ldb (byte 16 0) (1+ d)))
                                  (setf s (ldb (byte 16 0) (1+ s)))
                                  (decf n)))
                       ;; we are copying in a 64k ring buffer and
                       ;; deflate is limited to copying 258 bytes from
                       ;; at most 32k away. If we copy a few bytes too
                       ;; much it won't overwrite anything important,
                       ;; so just copy by largest word size we can.
                       ;; (word size is limited by offset, since it
                       ;; has to copy results of previous copies if it
                       ;; overlaps, unlike REPLACE)
                       (cond
                         ((>= o 8)
                          (loop repeat (ceiling n 8)
                                do (setf (nibbles:ub64ref/le output d)
                                         (nibbles:ub64ref/le output s))
                                   (setf d (ldb (byte 16 0) (+ d 8)))
                                   (setf s (ldb (byte 16 0) (+ s 8)))))
                         ((>= o 4)
                          (loop repeat (ceiling n 4)
                                do (setf (nibbles:ub32ref/le output d)
                                         (nibbles:ub32ref/le output s))
                                   (setf d (ldb (byte 16 0) (+ d 4)))
                                   (setf s (ldb (byte 16 0) (+ s 4)))))
                         ((>= o 2)
                          (loop repeat (ceiling n 2)
                                do (setf (nibbles:ub16ref/le output d)
                                         (nibbles:ub16ref/le output s))
                                   (setf d (ldb (byte 16 0) (+ d 2)))
                                   (setf s (ldb (byte 16 0) (+ s 2)))))
                         (t
                          (loop repeat n
                                do (setf (aref output d)
                                         (aref output s))
                                   (setf d (ldb (byte 16 0) (1+ d)))
                                   (setf s (ldb (byte 16 0) (1+ s))))))
                       ;; D may be a bit past actual value, so reset
                       ;; to correct end point
                       (setf d (ldb (byte 16 0)
                                    (+ (ds-output-index state) n1)))
                       ;; copy to output buffer if needed
                       (if (< d (ds-output-index state))
                           (copy-output 32768 65536)
                           (when (and (< (ds-output-index state) 32768)
                                      (>= d 32768))
                             (copy-output 0 32768)))
                       (setf (ds-output-index state) d))))
                 (store-dht (v)
                   (cond
                     ((plusp (ds-dht-hlit+hdist state))
                      (setf (aref (ds-dht-lit/len/dist state)
                                  (ds-dht-lit/len/dist-index state))
                            v)
                      (incf (ds-dht-lit/len/dist-index state))
                      (decf (ds-dht-hlit+hdist state)))
                     (t
                      (error "???"))))
                 (repeat-dht (c)
                   (loop repeat c do (store-dht (ds-dht-last-len state)))))
          (declare (ignorable #'copy-history-byte)
                   (inline out-byte store-dht copy-history))

          (state-machine (state)
            :start-of-block
            (let ((final (the bit (bits 1 (error "foo!"))))
                  (type (the (unsigned-byte 2) (bits 2 (error "foo2")))))
              #++(format t "block ~s ~s~%" final type)
              (setf (ds-last-block-flag state) (plusp final))
              (ecase type
                (0 (next-state :uncompressed-block))
                (1 (next-state :static-huffman-block))
                (2 (next-state :dynamic-huffman-block))))

            :uncompressed-block
            (byte-align)
            (let ((s (bits 16 (error "foo3")))
                  (n (the (unsigned-byte 16) (bits 16 (error "foo4")))))
              (assert (= n (ldb (byte 16 0) (lognot s))))
              #++(format *debug-io* "uncompressed ~s (~s)~%" s n)
              (loop repeat s
                    do (out-byte (the octet (bits 8 (error "5"))))))
            (next-state :block-end)

            :static-huffman-block
            (setf (ds-current-huffman-tree state)
                  +static-huffman-tree+)
            (next-state :decompress-block)

            :dynamic-huffman-block
            (setf (ds-dht-hlit state) (+ 257 (bits 5 (error "dhb1"))))
            #++(format t "hlit = ~s~%" (ds-dht-hlit state))
            :dynamic-huffman-block2
            (let ((hdist (+ 1 (bits 5 (error "dhb2")))))
              (setf (ds-dht-hlit+hdist state)
                    (+ (ds-dht-hlit state)
                       hdist)))
            (setf (ds-dht-lit/len/dist-index state) 0)
            :dynamic-huffman-block3
            (setf (ds-dht-hclen state) (+ 4 (bits 4 (error "dhb3"))))
            (fill (ds-dht-len-codes state) 0)
            (setf (ds-dht-len-code-index state) 0)
            :dynamic-huffman-block-len-codes
            (loop while (plusp (ds-dht-hclen state))
                  for i = (aref +len-code-order+ (ds-dht-len-code-index state))
                  do (setf (aref (ds-dht-len-codes state) i)
                           (bits 3 (error "dhb-lc")))
                     (incf (ds-dht-len-code-index state))
                     (decf (ds-dht-hclen state)))
            (setf (ht-len-start-bits (ds-dht-len-tree state))
                  (nth-value 1
                             (build-tree-part (ds-dht-len-tree state) 0
                                              (ds-dht-len-codes state)
                                              :dht-len 0 20)))
            #++(format *debug-io*
                       "build dht len tree: ~s~%"  (ds-dht-len-codes state))
            #++(dump-tree (ds-dht-len-tree state))
            (setf (ds-current-huffman-tree state)
                  (ds-dht-len-tree state))
            (setf (ds-extra-bits-type state) 2)
            (next-state :decode-huffman-entry)

            :dynamic-huffman-block4
            (build-tree* (ds-dynamic-huffman-tree state)
                         (ds-dht-lit/len/dist state)
                         (ds-dht-hlit state)
                         (ds-dht-lit/len/dist-index state))
            (setf (ds-extra-bits-type state) 0)
            (setf (ds-current-huffman-tree state)
                  (ds-dynamic-huffman-tree state))
            (next-state :decompress-block)

            :block-end
            (if (ds-last-block-flag state)
                (next-state :done)
                (next-state :start-of-block))

            :decompress-block
            ;; reading a literal/length/end
            (next-state :decode-huffman-entry)


            :decode-huffman-entry
            (setf (ds-tree-bits state)
                  (ht-len-start-bits (ds-current-huffman-tree state)))
            (setf (ds-tree-offset state) 0)
            :decode-huffman-entry2
            ;; fixme: build table reversed instead of reversing bits
            (let* ((bits (bits (ds-tree-bits state) (error "6")))
                   (node (aref (ht-nodes (ds-current-huffman-tree state))
                               (+ bits (ds-tree-offset state)))))
              #++(format *debug-io* "got ~d bits ~16,'0b -> node ~16,'0b~%"
                         (ds-tree-bits state)
                         bits node)
              ;; test file shows ~ 1.5:1.3:0.5 for link:len/dist:literal
              (ecase (ht-node-type node)
                (#.+ht-link/end+
                 (when (ht-endp node)
                   (next-state :block-end))
                 (setf (ds-tree-bits state) (ht-link-bits node)
                       (ds-tree-offset state) (ht-link-offset node))
                 (next-state :decode-huffman-entry2))
                (#.+ht-len/dist+
                 (if (= (ds-extra-bits-type state) 2)
                     ;; reading dynamic table lengths
                     (let ((v (ht-value node)))
                       #++(incf (gethash v *stats* 0))
                       (cond
                         ((< v 16)
                          (setf (ds-dht-last-len state) v)
                          (store-dht v)
                          (next-state :more-dht?))
                         ((= v 16)
                          (setf (ds-extra-bits-needed state) 2
                                (ds-last-decoded-len/dist state) 3))
                         ((= v 17)
                          (setf (ds-extra-bits-needed state) 3
                                (ds-last-decoded-len/dist state) 3
                                (ds-dht-last-len state) 0))
                         (t
                          (setf (ds-extra-bits-needed state) 7
                                (ds-last-decoded-len/dist state) 11
                                (ds-dht-last-len state) 0)))
                       (next-state :extra-bits)))
                 ;; reading length or distance, with possible extra bits
                 (let ((v (ht-value node)))
                   (setf (ds-extra-bits-needed state)
                         (aref +extra-bits+ v))
                   (setf (ds-last-decoded-len/dist state)
                         (aref +len/dist-bases+ v))
                   #++(format *debug-io* " read l/d ~s: ~s ~s ~%"
                              v
                              (ds-extra-bits-needed state)
                              (ds-last-decoded-len/dist state))
                   (next-state :extra-bits)))
                (#.+ht-literal+
                 (out-byte (ht-value node))
                 (next-state :decode-huffman-entry))))
            :more-dht?
            #++(format *debug-io* "  ~s ~s~%"
                       (ds-dht-hlit state)
                       (ds-dht-hdist state))
            (if (plusp (ds-dht-hlit+hdist state))
                (next-state :decode-huffman-entry)
                (progn
                  (setf (ds-extra-bits-type state) 0)
                  (next-state :dynamic-huffman-block4)))
            :extra-bits
            (when (plusp (ds-extra-bits-needed state))
              (let ((bits (bits (ds-extra-bits-needed state) (error "7"))))
                (declare (type (unsigned-byte 16) bits))
                #++(format *debug-io* " ~s extra bits = ~s~%"
                           (ds-extra-bits-needed state) bits)
                (incf (ds-last-decoded-len/dist state)
                      bits)))
            (ecase (ds-extra-bits-type state)
              (0 ;; len
               (setf (ds-bytes-to-copy state)
                     (ds-last-decoded-len/dist state))
               (next-state :read-dist))
              (1 ;; dist
               (setf (ds-history-copy-offset state)
                     (ds-last-decoded-len/dist state))
               (setf (ds-extra-bits-type state) 0)
               #++(format t "match ~s ~s~%"
                          (ds-bytes-to-copy state)
                          (ds-history-copy-offset state))
               (next-state :copy-history))
              (2 ;; dht
               (repeat-dht (ds-last-decoded-len/dist state))
               (next-state :more-dht?)))

            :read-dist
            (setf (ds-tree-bits state)
                  (ht-dist-start-bits (ds-current-huffman-tree state)))
            (setf (ds-tree-offset state)
                  (ht-dist-offset (ds-current-huffman-tree state)))
            (setf (ds-extra-bits-type state) 1)
            (next-state :decode-huffman-entry2)

            :copy-history
            (copy-history (ds-bytes-to-copy state))
            (next-state :decompress-block)

            :done)
          (cond
            ((< 0 (ds-output-index state) 32768)
             (copy-output 0 (ds-output-index state)))
            ((< 32768 (ds-output-index state))
             (copy-output 32768 (ds-output-index state))))
          (if into
              into
              (reverse out)))))))
