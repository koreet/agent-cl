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

(defun fresh-random-state ()
  "A randomly seeded random-state. SBCL's default *random-state* is seeded
  deterministically at startup, so two processes (and repeated calls with the
  default) produce the SAME sequence — which made every session id collide. Use
  SB-EXT:SEED-RANDOM-STATE T for a real per-call seed; fall back to
  *random-state* on other implementations."
  #+sbcl (sb-ext:seed-random-state t)
  #-sbcl *random-state*)

(defun uuid-string ()
  "Random v4-ish UUID string, RFC-4122 shaped. Cryptography not needed for ids."
  (let ((bytes (make-array 16 :element-type '(unsigned-byte 8)))
        (rs (fresh-random-state)))
    (dotimes (i 16)
      (setf (aref bytes i) (random 256 rs)))
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
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour min sec)))

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

(defun utf8-byte-length (text)
  "Number of bytes TEXT occupies when written as UTF-8 (chars may be 1-4 bytes)."
  (if (null text)
      0
      (loop for ch across text
            for code = (char-code ch)
            sum (cond ((< code #x80) 1)
                      ((< code #x800) 2)
                      ((< code #x10000) 3)
                      (t 4)))))

(defun read-file-string (path &key (external-format :utf-8))
  "Read PATH as text, or NIL when it does not exist. An absent file is an
  ordinary outcome here rather than a condition — callers such as
  SELFIMPROVE:IMPROVE-FILE distinguish it explicitly, and letting OPEN signal
  used to mask the real reason behind an OS error message."
  (when (uiop:file-exists-p path)
    (uiop:read-file-string path :external-format external-format)))

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
                          :timeout timeout
                          :ignore-error-status t)
      (declare (ignore err))
      (values (or out "") exit))))

;; ---------------------------------------------------------------------------
;; run-program-with-timeout — hard wall-clock watchdog
;;
;; uiop:run-program :timeout is unreliable on Windows (verified: a 3s timeout
;; on `ping -n 30` returned after 34s). Tools like shell.run / code.exec pass a
;; model-supplied TIMEOUT and would otherwise hang the engine forever. This
;; helper runs the child asynchronously, polls it, and kills the whole process
;; tree (taskkill /F /T on Windows, SIGKILL elsewhere) once the deadline hits.
;; Returns (values out err exit) where EXIT is :timeout on kill.
;; ---------------------------------------------------------------------------

(defun read-file-bytes (path)
  "Read a whole file as an (unsigned-byte 8) vector."
  (with-open-file (in path :element-type '(unsigned-byte 8)
                         :direction :input)
    (let ((buf (make-array (file-length in)
                           :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun read-file-lenient (path)
  "Read a file as text without ever throwing on byte encoding. Subprocess
  output on Windows may be written in the ANSI codepage (GBK) rather than
  UTF-8, and a strict UTF-8 read then raises a stream decoding error that
  surfaces as a baffling tool failure. Strategy: try UTF-8, then GBK/cp936,
  finally a lossy byte->char fallback so callers always get a string."
  (when (uiop:file-exists-p path)
    (let ((bytes (read-file-bytes path)))
      (flet ((octets (ext)
               (ignore-errors
                (sb-ext:octets-to-string bytes :external-format ext))))
        (or (octets :utf-8)
            (octets :cp936)
            (octets :gbk)
            ;; last resort: never fail, keep ASCII readable
            (map 'string (lambda (b)
                           (if (< b 128) (code-char b) #\?))
                 bytes))))))

(defun run-program-with-timeout (argv &key (timeout 60) (directory nil))
  "Run ARGV with a hard wall-clock TIMEOUT. uiop:run-program :timeout is
  unreliable on Windows (verified: a 3s timeout on `ping -n 30` returned after
  34s), so this launches the child asynchronously, polls it, and kills the
  whole process tree (taskkill /F /T on Windows, SIGKILL elsewhere) once the
  deadline hits. Returns (values out err exit); EXIT is :timeout on kill."
  (let ((dir (or directory (uiop:getcwd))))
    (if (null timeout)
        ;; no deadline: plain synchronous run
        (uiop:run-program argv :output :string :error-output :string
                          :directory (namestring dir)
                          :ignore-error-status t)
        (let* ((stamp (agent-cl.core:uuid-string))
               (tmp-dir (uiop:ensure-directory-pathname
                         (merge-pathnames ".tools/tmp/" (uiop:getcwd))))
               (out-file (merge-pathnames
                          (format nil "watchdog-~a-out.txt" stamp) tmp-dir))
               (err-file (merge-pathnames
                          (format nil "watchdog-~a-err.txt" stamp) tmp-dir))
               (deadline (+ (get-internal-real-time)
                            (round (* timeout internal-time-units-per-second)))))
          ;; The redirection files are opened by UIOP *at launch time*, so the
          ;; directory must exist BEFORE launch-program: otherwise a fresh clone
          ;; (where .tools/ is gitignored and thus absent) fails its very first
          ;; shell.run with "Error opening .../watchdog-*.txt".
          (ensure-directories-exist tmp-dir)
          (let ((proc (uiop:launch-program
                       argv
                       :output (namestring out-file)
                       :error-output (namestring err-file)
                       :directory (namestring dir))))
            (unwind-protect
               (progn
                 (loop while (and (<= (get-internal-real-time) deadline)
                                  (ignore-errors (uiop:process-alive-p proc)))
                       do (sleep 0.05))
                 (if (ignore-errors (uiop:process-alive-p proc))
                     ;; still alive after the deadline -> kill the process tree
                     (progn
                       (let ((pid (ignore-errors (uiop:process-info-pid proc))))
                         (when pid
                           (ignore-errors
                            (uiop:run-program
                             (if (uiop:os-windows-p)
                                 (list "taskkill" "/pid" (princ-to-string pid)
                                       "/T" "/F")
                                 (list "kill" "-9" (princ-to-string pid)))
                             :output nil :error-output nil
                             :ignore-error-status t))))
                       (values (read-file-lenient out-file)
                               (read-file-lenient err-file)
                               :timeout))
                     ;; finished before the deadline: wait for its exit code
                     (let ((exit
                             (handler-case
                                 (uiop:wait-process proc)
                               (error () nil))))
                       (values (read-file-lenient out-file)
                               (read-file-lenient err-file)
                               (if (integerp exit) exit :unknown)))))
            ;; cleanup: make sure the child never survives us, remove temp files
            (when (ignore-errors (uiop:process-alive-p proc))
              (ignore-errors (uiop:terminate-process proc)))
            (ignore-errors (delete-file out-file))
            (ignore-errors (delete-file err-file))))))))

;; ---------------------------------------------------------------------------
;; lexical path handling — one implementation, shared by the file tools
;; (workspace confinement) and self-improvement (repo confinement)
;; ---------------------------------------------------------------------------

(defun path-segments (absolute-string)
  "Split an ABSOLUTE-STRING path into (values PREFIX SEGMENTS). '.' is dropped
  and '..' pops the previous segment, so the result is already folded. Purely
  lexical: the filesystem is never touched, which is what makes it usable for
  files that do not exist yet. PREFIX is the Windows drive (\"C:\") or \"\"."
  (let* ((s (substitute #\/ #\\ (princ-to-string absolute-string)))
         (prefix "")
         (rest s))
    (when (and (>= (length s) 2)
               (alpha-char-p (char s 0))
               (char= (char s 1) #\:))
      (setf prefix (subseq s 0 2)
            rest (subseq s 2)))
    (let ((out nil))
      (dolist (seg (uiop:split-string rest :separator '(#\/)))
        (cond ((or (string= seg "") (string= seg ".")) nil)
              ;; '..' pops the previous segment; above the root it is ignored
              ((string= seg "..") (when out (pop out)))
              (t (push seg out))))
      (values prefix (nreverse out)))))

(defun canonical-path-string (path &optional base)
  "Lexically canonical absolute path string for PATH, with '..' folded away.
  Relative paths resolve against BASE, falling back to the current working
  directory. Because folding happens before the string is used, callers can
  validate this exact string and then OPEN it: what was checked is what is used."
  (let* ((raw (if (pathnamep path) (namestring path) (princ-to-string path)))
         (abs (if (uiop:absolute-pathname-p (pathname raw))
                  raw
                  (namestring (merge-pathnames
                               raw
                               (uiop:ensure-directory-pathname
                                (or base (uiop:getcwd))))))))
    (multiple-value-bind (prefix segs) (path-segments abs)
      (if segs
          (format nil "~a/~{~a~^/~}" prefix segs)
          (format nil "~a/" prefix)))))

(defun path-inside-p (candidate root)
  "True when canonical CANDIDATE equals or sits under canonical ROOT. Case is
  folded only on Windows, where the filesystem is case-insensitive."
  (let ((c (if (uiop:os-windows-p) (string-downcase candidate) candidate))
        (r (if (uiop:os-windows-p) (string-downcase root) root)))
    (or (string= c r)
        (and (> (length c) (length r))
             (string= c r :end1 (length r) :end2 (length r))
             (char= (char c (length r)) #\/)))))

(defun format-token-count (n)
  "Compact token count for display: <1000 as-is, then 1.2k, then 1.2M.
  Rounds to one decimal; drops a trailing '.0'. Non-numbers -> \"?\". Pure."
  (cond
    ((not (numberp n)) "?")
    ((< n 1000) (format nil "~d" n))
    ((< n 1000000) (let ((v (/ (round (* n 10) 1000) 10.0)))
                     (if (= v (floor v)) (format nil "~dk" (floor v))
                         (format nil "~,1fk" v))))
    (t (let ((v (/ (round (* n 10) 1000000) 10.0)))
         (if (= v (floor v)) (format nil "~dM" (floor v))
             (format nil "~,1fM" v))))))
