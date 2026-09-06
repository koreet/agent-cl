;;;; src/core/util.lisp — small portable helpers (no third-party deps).
(in-package #:agent-cl.core)

(defun ensure-list (x)
  (if (listp x) x (list x)))

(defun plist-get (plist key &optional default)
  "Like GETF but returns DEFAULT (not NIL) semantics the caller can distinguish."
  (let ((cell (member key plist :test #'eq)))
    (if cell (cadr cell) default)))

(defun alist->plist (alist)
  "((:a . 1) (:b . 2)) -> (:a 1 :b 2). Keys may be anything."
  (loop for (k . v) in alist append (list k v)))

(defun string-empty-p (s)
  (or (null s) (string= s "")))

(defun uuid-string ()
  "Random v4-ish UUID string, RFC-4122 shaped. Cryptography not needed for ids."
  (let ((bytes (make-array 16 :element-type '(unsigned-byte 8))))
    (dotimes (i 16)
      (setf (aref bytes i) (random 256)))
    (setf (aref bytes 6) (logand (aref bytes 6) #x0f))
    (setf (aref bytes 6) (logior (aref bytes 6) #x40))
    (setf (aref bytes 8) (logand (aref bytes 8) #x3f))
    (setf (aref bytes 8) (logior (aref bytes 8) #x80))
    (format nil "~2,'0x~2,'0x~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x"
            (aref bytes 0) (aref bytes 1) (aref bytes 2) (aref bytes 3)
            (aref bytes 4) (aref bytes 5)
            (aref bytes 6) (aref bytes 7)
            (aref bytes 8) (aref bytes 9)
            (aref bytes 10) (aref bytes 11) (aref bytes 12) (aref bytes 13) (aref bytes 14) (aref bytes 15))))

(defun now-iso8601 ()
  "Current UTC time as ISO-8601-ish string (second precision)."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (declare (ignore sec))
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:00Z"
            year month day hour min)))

(defparameter *ascii-per-token* 4.0
  "Rough tokens-per-char heuristic for non-CJK text.")
(defparameter *cjk-per-token* 0.75
  "Tokens per char for CJK-ish characters.")

(defun approx-tokens (text)
  "Cheap deterministic token estimate. CJK-heavy text costs more tokens per char
  than ASCII; usage returned by the provider is used for real accounting."
  (if (null text)
      0
      (let ((cjk 0) (ascii 0))
        (loop for ch across text
              do (if (and (char>= ch #\u4e00) (char<= ch #\u9fff))
                     (incf cjk)
                     (incf ascii)))
        (round (+ (/ cjk *cjk-per-token*) (/ ascii *ascii-per-token*))))))

(defun read-file-string (path &key (external-format :utf-8))
  (uiop:read-file-string path :external-format external-format))

(defun write-file-string (path content &key (external-format :utf-8)
                                            (if-exists :supersede)
                                            (if-does-not-exist :create))
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists if-exists
                            :if-does-not-exist if-does-not-exist
                            :external-format external-format)
    (write-string content out)
    content))

(defun shell-command (command &key (timeout 60) (directory nil))
  "Run COMMAND via the host shell, returning (values output-string exit-code).
  Raises agent-cl.core::dsl-style errors only on process-spawn failure."
  (let ((dir (or directory (uiop:getcwd))))
    (multiple-value-bind (out err exit)
        (uiop:run-program command
                          :output :string :error-output :string
                          :directory (namestring dir)
                          ;; NB: on Windows there is no real per-process timeout
                          ;; in uiop; uiop kills after :timeout on most platforms.
                          :timeout timeout
                          :ignore-error-status t)
      (declare (ignore err))
      (values (or out "") exit))))
