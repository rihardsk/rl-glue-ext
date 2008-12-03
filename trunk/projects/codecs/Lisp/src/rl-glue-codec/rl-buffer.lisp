
;;; Copyright 2008 Gabor Balazs
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.
;;;
;;; $Revision$
;;; $Date$

(in-package #:org.rl-community.rl-glue-codec)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Architecture specific parameters.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +bits-per-byte+ 8
    "Number of bits in a byte.")
  (deftype byte-t () `(unsigned-byte ,+bits-per-byte+))
  (deftype byte-array-t () `(simple-array byte-t))

  (defconstant +bytes-per-char+ 1
    "Number of bytes in the character type.")
  (defconstant +bits-per-char+ (* +bits-per-byte+ +bytes-per-char+)
    "Number of bits in the character type.")
  (deftype char-code-t () `(unsigned-byte ,+bits-per-char+))

  (defconstant +bytes-per-integer+ 4
    "Number of bytes in the integer type.")
  (defconstant +bits-per-integer+ (* +bits-per-byte+ +bytes-per-integer+)
    "Number of bits in the integer type.")
  (defconstant +max-int-pos+ (1- +bits-per-integer+)
    "Maximum integer bit position.")
  (defconstant +uint-limit+ (expt 2 (1+ +max-int-pos+))
    "Maximum unsigned integer value.")
  (deftype int-code-t () `(unsigned-byte ,+bits-per-integer+))
  (deftype integer-t () `(signed-byte ,+bits-per-integer+))
  (deftype int-code-t () `(unsigned-byte ,+bits-per-integer+))

  (defconstant +expo-bits+ 11
    "Number of bits in the exponent part of the floating point type.")
  (defconstant +sigd-bits+ 52
    "Number of bits in the significand part of the floating point type.")

  ;; Because of the floating point encoding and decoding optimizations,
  ;; only the 32 bit architecture is supported when the code of a double-float 
  ;; is represented by two integer codes. If one wants to add support for the
  ;; 64 bit architectures, one should reimplement the float-encoder, 
  ;; float-decoder, buffer-read-float and buffer-write-float functions.
  (defconstant +bits-per-float+ (+ 1 +expo-bits+ +sigd-bits+)
    "Number of bits in the floating point type.")
  (defconstant +bytes-per-float+ (/ +bits-per-float+ +bits-per-byte+)
    "Number of bytes in the floating point type.")
  (defconstant +max-sigd+ (expt 2 +sigd-bits+)
    "Maximum significand value of the floating point type.")
  (defconstant +expo-offset+ (1- (expt 2 (1- +expo-bits+)))
    "Exponent offset for floating point encoding/decoding.")
  (deftype float-code-t () `(unsigned-byte ,+bits-per-float+)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Byte buffer for network communication.

(defparameter *init-buffer-size* 2048 "Initial buffer size in bytes.")
(declaim (type fixnum *init-buffer-size*))

(defstruct buffer
  "An unsigned byte based data buffer."
  (offset 0 :type fixnum) ; Position from/to where reading/writing happens.
  (size 0 :type fixnum) ; Number of bytes in the buffer.
  (bytes (make-array *init-buffer-size* :element-type 'byte-t)
         :type byte-array-t)) ; Data stored in the buffer.

(setf (documentation 'buffer-p 'function)
      "Returns T if type if OBJECT is buffer.")
(setf (documentation 'make-buffer 'function)
      "Makes an unsigned byte based data buffer.")
(setf (documentation 'buffer-offset 'function)
      "Returns the pointer of the buffer from/to read/write happens.")
(setf (documentation 'buffer-size 'function)
      "Returns the number of (used) bytes in the buffer.")
(setf (documentation 'buffer-bytes 'function)
      "Returns the storage (byte array) of the buffer.")

(defun buffer-clear (buffer)
  "Clears the content of BUFFER."
  (declare #.*optimize-settings*)
  (setf (buffer-size buffer) 0)
  (setf (buffer-offset buffer) 0)
  buffer)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Conditions.

(define-condition empty-buffer-error (error)
  ((otype
    :reader otype
    :initarg :otype
    :type symbol
    :documentation "Object type which is tried to read."))
  (:documentation "Raised if there is not enough data
 to read an object of OTYPE.")
  (:report (lambda (condition stream)
             (format stream "Not enough buffer data to read type ~A."
                     (otype condition)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data encoding and decoding.

(declaim (inline char-encoder))
(defun char-encoder (ch)
  "Returns the code of CH."
  (declare #.*optimize-settings*)
  (declare (type character ch))
  (char-code ch))

(declaim (inline char-decoder))
(defun char-decoder (code)
  "Returns the decoded character of CODE."
  (declare #.*optimize-settings*)
  (declare (type char-code-t code))
  (code-char code))

(declaim (inline integer-encoder))
(defun integer-encoder (int)
  "Returns the code of INT."
  (declare #.*optimize-settings*)
  (declare (type integer-t int))
  (if (logbitp +max-int-pos+ int) (+ int +uint-limit+) int))

(declaim (inline integer-decoder))
(defun integer-decoder (code)
  "Returns the decoded sigend integer of CODE."
  (declare #.*optimize-settings*)
  (declare (type int-code-t code))
  (if (logbitp +max-int-pos+ code) (- code +uint-limit+) code))

(declaim (inline float-encoder))
(defun float-encoder (float)
  "Returns the codes of FLOAT."
  (declare #.*optimize-settings*)
  (declare (type double-float float))
  (flet ((create-float-code (sign expo sigd)
           (declare #.*optimize-settings*)
           (declare (type fixnum sign expo))
           (declare (type float-code-t sigd))
           (let ((l-code 0))
             (declare (type int-code-t l-code))
             (setf (ldb (byte 1 (1- +bits-per-integer+)) l-code) sign)
             (setf (ldb (byte +expo-bits+ (- +bits-per-integer+
                                             1 +expo-bits+)) l-code) expo)
             (setf (ldb (byte (- +sigd-bits+ +bits-per-integer+) 0) l-code)
                   (ldb (byte (- +sigd-bits+ +bits-per-integer+)
                              +bits-per-integer+) sigd))
             (values l-code (ldb (byte +bits-per-integer+ 0) sigd)))))
    (if (zerop float)
        (create-float-code 0 0 0)
        (multiple-value-bind (sigd expo sign) (decode-float float)
          (declare (type double-float sigd sign))
          (declare (type fixnum expo))
          (let ((expo (+ expo (1- +expo-offset+)))
                (sign (if (plusp sign) 0 1)))
            (declare (type fixnum expo sign))
            (if (minusp expo)
                (create-float-code sign
                                   0
                                   (ash (round (* +max-sigd+ sigd)) expo))
                (create-float-code sign
                                   expo
                                   (round (* +max-sigd+ (1- (* sigd 2)))))))))))

(declaim (inline float-decoder))
(defun float-decoder (l-code r-code)
  "Returns the float generated from the L-CODE and R-CODE codes."
  (declare #.*optimize-settings*)
  (declare (type int-code-t l-code r-code))
  (let ((sign (ldb (byte 1 (1- +bits-per-integer+)) l-code))
        (expo (ldb (byte +expo-bits+ (- +bits-per-integer+ 1 +expo-bits+))
                   l-code))
        (l-sigd (ldb (byte (- +sigd-bits+ +bits-per-integer+) 0) l-code)))
    (declare (type (bit) sign))
    (declare (type (unsigned-byte #.+expo-bits+) expo))
    (declare (type (signed-byte #.(1+ +sigd-bits+)) l-sigd))
    (if (zerop expo)
        (setf expo 1)
        (setf (ldb (byte 1 (- +sigd-bits+ +bits-per-integer+)) l-sigd) 1))
    (let ((sigd (logior (ash l-sigd +bits-per-integer+) r-code)))
      (declare (type float-code-t sigd))
      (scale-float (coerce (if (zerop sign) sigd (- sigd)) 'double-float)
                   (- expo (+ +expo-offset+ +sigd-bits+))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Helper macros and functions.

(defmacro with-empty-buffer-check ((chk-p buffer type type-size) &body body)
  "Checks whether there is enough bytes in BUFFER to read an object of TYPE."
  (let ((buffer buffer))
    `(if (and ,chk-p (< (- (buffer-size ,buffer)
                           (buffer-offset ,buffer)) ,type-size))
         (restart-case (error 'empty-buffer-error :otype ,type)
           (use-value (value) value))
         (progn ,@body))))

(defun auto-adjust (buffer size)
  "Checks whether the buffer has enough free space to store SIZE bytes. 
If not, it automatically adjust the buffer."
  (declare #.*optimize-settings*)
  (declare (fixnum size))
  (let* ((bytes (buffer-bytes buffer))
         (buff-size (buffer-size buffer))
         (buff-capab (length bytes))
         (free-size (- buff-capab buff-size)))
    (when (< free-size size)
      (let ((arr (make-array (+ buff-capab (- size free-size) 1)
                             :element-type 'byte-t)))
        (dotimes (i buff-size)
          (setf (aref arr i) (aref bytes i)))
        (setf (buffer-bytes buffer) arr))))
  buffer)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Read/write operations on buffers.

(defmacro buffer-read (size buffer)
  "Reads an encoded value (CODE) from BUFFER, where SIZE is the length 
of the encoded value in bytes."
  (let ((code-size (* size +bits-per-byte+)) (buffer buffer))
    `(let ((code 0))
       (declare (type (unsigned-byte ,code-size) code))
       (let ((bytes (buffer-bytes ,buffer))
             (offset (buffer-offset ,buffer)))
         (dotimes (i ,size)
           (setf code (logior (the (unsigned-byte ,code-size)
                                (ash code +bits-per-byte+))
                              (aref bytes offset)))
           (incf offset))
         (setf (buffer-offset ,buffer) offset))
       code)))

(defmacro buffer-write (size code buffer)
  "Writes an encoded value (CODE) to BUFFER, where SIZE is the length 
of the encoded value in bytes."
  (let ((code-size (* size +bits-per-byte+)) (buffer buffer))
    `(let ((code-value ,code))
       (declare (type (unsigned-byte ,code-size) code-value))
       (let ((bytes (buffer-bytes ,buffer))
             (offset (buffer-offset ,buffer)))
         (do ((i ,size (1- i))
              (pos ,(* +bits-per-byte+ (1- size)) (- pos +bits-per-byte+)))
             ((= i 0) nil)
           (declare (type fixnum i pos))
           (setf (aref bytes offset)
                 (ldb (byte +bits-per-byte+ pos) code-value))
           (incf offset))
         (setf (buffer-offset ,buffer) offset)
         (incf (buffer-size ,buffer) ,size))
       code-value)))

(defun buffer-read-char (buffer &optional (buffchk-p t))
  "Reads a character from BUFFER."
  (declare #.*optimize-settings*)
  (with-empty-buffer-check (buffchk-p buffer 'character +bytes-per-char+)
    (char-decoder (buffer-read #.+bytes-per-char+ buffer))))

(defun buffer-write-char (ch buffer &optional (adjust-p t))
  "Writes the CH character to BUFFER."
  (declare #.*optimize-settings*)
  (when adjust-p (auto-adjust buffer +bytes-per-char+))
  (buffer-write #.+bytes-per-char+
                (char-encoder ch)
                buffer)
  ch)

(defun buffer-read-int (buffer &optional (buffchk-p t))
  "Reads an integer from BUFFER."
  (declare #.*optimize-settings*)
  (with-empty-buffer-check (buffchk-p buffer 'integer +bytes-per-integer+)
    (integer-decoder (buffer-read #.+bytes-per-integer+ buffer))))

(defun buffer-write-int (integer buffer &optional (adjust-p t))
  "Writes the INTEGER integer to BUFFER."
  (declare #.*optimize-settings*)
  (declare (type integer-t integer))
  (when adjust-p (auto-adjust buffer +bytes-per-integer+))
  (buffer-write #.+bytes-per-integer+
                (integer-encoder integer)
                buffer)
  integer)

(defun buffer-read-float (buffer &optional (buffchk-p t))
  "Reads a float from BUFFER."
  (declare #.*optimize-settings*)
  (with-empty-buffer-check (buffchk-p buffer 'float +bytes-per-float+)
    (float-decoder (buffer-read #.+bytes-per-integer+ buffer)
                   (buffer-read #.+bytes-per-integer+ buffer))))

(defun buffer-write-float (float buffer &optional (adjust-p t))
  "Writes the FLOAT float to BUFFER."
  (declare #.*optimize-settings*)
  (declare (type double-float float))
  (when adjust-p (auto-adjust buffer +bytes-per-float+))
  (multiple-value-bind (l-code r-code) (float-encoder float)
    (buffer-write #.+bytes-per-integer+ l-code buffer)
    (buffer-write #.+bytes-per-integer+ r-code buffer))
  float)

(defmacro buffer-read-seq (elem-type elem-size reader-fn buffer size buffchk-p)
  "Read a sequence of elements with type ELEM-TYPE and size ELEM-SIZE from 
BUFFER by the READER-FN function. If given, the SIZE parameter specifies the 
number of elements to be read. Otherwise it is read from the BUFFER. If 
BUFFCHK-P is T, the content of BUFFER is checked whether it contains enough 
data for the read operation."
  `(let ((arr-size (or ,size (buffer-read-int buffer))))
     (declare (type fixnum arr-size))
     (if (zerop arr-size)
         (make-array 0 :element-type ',elem-type)
         (with-empty-buffer-check (,buffchk-p
                                   ,buffer
                                   'simple-array
                                   (the fixnum (* ,elem-size arr-size)))
           (let ((arr (make-array arr-size :element-type ',elem-type)))
             (dotimes (i arr-size)
               (setf (aref arr i) (,reader-fn ,buffer nil)))
             arr)))))

(defmacro buffer-write-seq (seq elem-size writer-fn buffer size write-size-p)
  "Write the SEQ sequence of elements with type ELEM-TYPE and size ELEM-SIZE to 
BUFFER by the WRITER-FN function. If given, the SIZE parameter specifies the 
number of elements to be written. Otherwise it is calculated from SEQ. If 
WRITE-SIZE-P is T, it is written to the BUFFER before writing the sequence."
  `(let* ((elem-num (or ,size (length (the simple-array ,seq))))
          (byte-num (* ,elem-size elem-num)))
     (declare (type fixnum elem-num byte-num))
     (if ,write-size-p
         (progn
           (auto-adjust ,buffer (the fixnum (+ +bytes-per-integer+ byte-num)))
           (buffer-write-int elem-num ,buffer nil))
         (auto-adjust ,buffer byte-num))
     (when (plusp elem-num)
       (dotimes (i (length ,seq))
         (,writer-fn (aref ,seq i) ,buffer nil)))
     ,seq))

(defun buffer-read-int-seq (buffer &optional size (buffchk-p t))
  "Reads an integer sequence from BUFFER."
  (declare #.*optimize-settings*)
  (buffer-read-seq integer-t +bytes-per-integer+
                   buffer-read-int buffer size buffchk-p))

(defun buffer-write-int-seq (int-seq buffer &optional size (write-size-p t))
  "Writes the INT-SEQ integer sequence to BUFFER."
  (declare #.*optimize-settings*)
  (declare (type (simple-array integer-t) int-seq))
  (buffer-write-seq int-seq +bytes-per-integer+
                    buffer-write-int buffer size write-size-p))

(defun buffer-read-float-seq (buffer &optional size (buffchk-p t))
  "Reads a float sequence from BUFFER."
  (declare #.*optimize-settings*)
  (buffer-read-seq double-float +bytes-per-float+
                   buffer-read-float buffer size buffchk-p))

(defun buffer-write-float-seq (float-seq buffer &optional size (write-size-p t))
  "Writes the FLOAT-SEQ float sequence to BUFFER."
  (declare #.*optimize-settings*)
  (declare (type (simple-array double-float) float-seq))
  (buffer-write-seq float-seq +bytes-per-float+
                    buffer-write-float buffer size write-size-p))

(defun buffer-read-string (buffer &optional size (buffchk-p t))
  "Reads a string (character sequence) from BUFFER."
  (declare #.*optimize-settings*)
  (buffer-read-seq character +bytes-per-char+
                   buffer-read-char buffer size buffchk-p))

(defun buffer-write-string (string buffer &optional (write-size-p t))
  "Writes the STRING character sequence to BUFFER."
  (declare #.*optimize-settings*)
  (declare (type string string))
  (buffer-write-seq string +bytes-per-char+
                    buffer-write-char buffer nil write-size-p))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Sending/receiving buffer to/from a stream.

(defun read-int (stream)
  "Returns a read integer from STREAM."
  (declare #.*optimize-settings*)
  (let ((code 0))
    (declare (type int-code-t code))
    (dotimes (i +bytes-per-integer+)
      (setf code (logior (the int-code-t (ash code +bits-per-byte+))
                         (the byte-t (read-byte stream)))))
    (integer-decoder code)))

(defun write-int (int stream)
  "Writes an integer to STREAM."
  (declare #.*optimize-settings*)
  (let ((code (integer-encoder int)))
    (declare (type int-code-t code))
    (do ((i +bytes-per-integer+ (the fixnum (1- i)))
         (pos (* +bits-per-byte+ (1- +bytes-per-integer+))
              (- pos +bits-per-byte+)))
        ((= i 0) nil)
      (write-byte (ldb (byte +bits-per-byte+ pos) code) stream)))
  stream)

(defun buffer-send (buffer stream state)
  "Sending the TARGET, the size and the bytes from BUFFER to STREAM."
  (declare #.*optimize-settings*)
  (let ((size (buffer-size buffer)))
    (declare (type fixnum size))
    ;; sending header
    (write-int state stream)
    (write-int size stream)
    ;; sending buffer content
    (let ((bytes (buffer-bytes buffer)))
      (dotimes (i size)
        (write-byte (aref bytes i) stream))))
  (force-output stream)
  buffer)

(defun buffer-recv (buffer stream)
  "Receiving the size and the bytes to BUFFER from STREAM."
  ;; receiving header
  (declare #.*optimize-settings*)
  (let ((state (read-int stream))
        (size (read-int stream)))
    (declare (type fixnum state size))
    ;; receiving buffer content
    (buffer-clear buffer)
    (auto-adjust buffer size)
    (let ((bytes (buffer-bytes buffer)))
      (dotimes (i size)
        (setf (aref bytes i) (read-byte stream))))
    (setf (buffer-size buffer) size)
    state))

