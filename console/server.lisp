(in-package #:cl-user)
(require :asdf)
(defparameter *file* *load-pathname*)
(defparameter *repo*
  (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname *file*)))
(handler-case
    (let ((h (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME"))))
      (when (and h (probe-file (merge-pathnames "quicklisp/setup.lisp"
                                                 (uiop:ensure-directory-pathname h))))
        (load (merge-pathnames "quicklisp/setup.lisp"
                               (uiop:ensure-directory-pathname h)))))
  (error (e) (format t "[bootstrap] ~a~%" e)))
(handler-case
    (let ((q (find-package "QL")))
      (when q (funcall (find-symbol "QUICKLOAD" q)
                       '(:hunchentoot :yason) :silent t)))
  (error (e) (format t "[deps] ~a~%" e)))
(handler-case
    (progn
      (asdf:initialize-source-registry
       `(:source-registry (:tree ,(uiop:subpathname *repo* ".tools/deps/"))
                          :ignore-inherited-configuration))
      (pushnew *repo* asdf:*central-registry* :test #'equal)
      (asdf:load-system :agent-cl :force nil))
  (error (e) (format t "[agent-cl] ~a~%" e)))

(unless (and (find-package "QL") (find-package "HUNCHENTOOT"))
  (format t "~&[console] FATAL: need quicklisp + hunchentoot loaded before defpackage. home=~a~%" (uiop:getenv "USERPROFILE"))
  (sb-ext:quit :unix-status 1))
(defpackage #:aconsole (:use #:cl :hunchentoot))
(in-package #:aconsole)

(defparameter *port* 8977)
(defparameter *static-ui*
  (merge-pathnames "console/static/index.html" cl-user::*repo*))
(defparameter *sessions-dir*
  (merge-pathnames ".agent-cl/sessions/"
                   (uiop:ensure-directory-pathname
                    (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))))

(defun json-quote (s)
  "S as a JSON string literal.

  EVERY character below 0x20 must be escaped (RFC 8259). Only quote, backslash,
  LF, TAB and CR were handled, so a form-feed, NUL or ESC — exactly what this repo
  captures from subprocesses, and what a user can paste into the chat box — was
  written raw and made the whole response body invalid (reproduced: the browser's
  JSON.parse rejected it, and /api/sessions would break for every client if one
  session directory name contained such a character)."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across (if (stringp s) s (princ-to-string s)) do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Tab (write-string "\\t" o))
        (#\Return (write-string "\\r" o))
        (otherwise
         (if (< (char-code c) 32)
             (format o "\\u~(~4,'0x~)" (char-code c))
             (write-char c o)))))
    (write-char #\" o)))

(defun session-ids ()
  (ensure-directories-exist *sessions-dir*)
  (loop for sub in (uiop:subdirectories *sessions-dir*)
        for nm  = (car (last (pathname-directory (pathname sub))))
        when (and nm (probe-file (merge-pathnames "events.jsonl" sub)))
          collect (string nm)))

(defun valid-session-id-p (id)
  "True when ID is a plain session directory name.

  The /api/session handler interpolated the raw query parameter into a path, so
  ?id=../../../Windows/win.ini climbed out of the sessions directory and served
  any events.jsonl the process could read. Only the id characters we actually
  generate are accepted, and the result must be one of the known ids."
  (and (stringp id)
       (plusp (length id))
       (<= (length id) 64)
       (every (lambda (c)
                (or (alphanumericp c) (member c '(#\- #\_ #\.))))
              id)
       (not (member id '("." "..") :test #'string=))
       ;; SEARCH, not FIND: FIND with a string needle and #'CHAR= is a type error
       ;; (it signalled a 500 on every real session id)
       (not (search ".." id))))

(defun read-session (id)
  "Re-encode the session's JSONL as a JSON array. Each line is PARSED and
  re-encoded: the handler used to copy raw lines, so one invalid line made the
  browser's JSON.parse fail and the whole session render as empty."
  (when (valid-session-id-p id)
    (let ((f (merge-pathnames (concatenate 'string id "/events.jsonl")
                              *sessions-dir*)))
      (when (probe-file f)
        (with-output-to-string (o)
          (write-char #\[ o)
          (let ((first t))
            ;; LENIENT decode + a guard around open/read: probe-file is not a
            ;; readability test (a directory, a sharing violation), and a single
            ;; stray byte used to raise a :UTF-8 decoding error out of the handler
            ;; and return HTTP 500 — after which the page silently rendered an
            ;; empty transcript. agent-cl.core:read-file-lenient is the same
            ;; helper the session store uses for exactly this reason.
            (handler-case
              (with-open-file (in f :external-format :utf-8)
                (loop for line = (read-line in nil nil) while line do
                  (let ((trimmed (string-trim '(#\Return #\Space) line)))
                    (unless (string= trimmed "")
                      (handler-case
                          (let ((json (agent-cl.core:json-encode
                                       (agent-cl.core:json-decode trimmed))))
                            (unless first (write-char #\, o))
                            (write-string json o)
                            (setf first nil))
                        (error (e)
                          (format t "~&[console] skip bad event line in ~a: ~a~%"
                                  id e)))))))
              (error (e)
                (format t "~&[console] cannot read session ~a: ~a~%" id e))))
          (write-char #\] o))))))

(define-easy-handler (home :uri "/") ()
  (setf (content-type*) "text/html; charset=utf-8")
  (handler-case
      (let ((p (probe-file *static-ui*)))
        (if p
            (uiop:read-file-string p :external-format :utf-8)
            (format nil "<h1>no index. look at ~a</h1>" (namestring *static-ui*))))
    (error (e)
      (format t "~&[console] index read error: ~a~%" e)
      "<h1>index read error</h1>")))

(define-easy-handler (sessions :uri "/api/sessions") ()
  (setf (content-type*) "application/json; charset=utf-8")
  (format nil "[~{~a~^,~}]" (mapcar #'json-quote (session-ids))))

(define-easy-handler (page-session :uri "/api/session") ()
  (setf (content-type*) "application/json; charset=utf-8")
  (let* ((raw (or (parameter "id") ""))
         (id  (subseq raw 0 (min 64 (length raw)))))
    (or (and (plusp (length id)) (read-session id)) "[]")))

(defun plist-string (obj key)
  "Look up a top-level STRING field KEY in a yason plist (string keys, eq won't match)."
  (loop for (k v) on obj by #'cddr
        when (and (stringp k) (string= k key) (stringp v)) return v))

(define-easy-handler (sendchat :uri "/api/chat" :default-request-type :post) ()
  (setf (content-type*) "application/json; charset=utf-8")
  (let ((body (handler-case (raw-post-data :force-text t) (error () ""))))
    (handler-case
        (let* ((json (yason:parse (make-string-input-stream (or body ""))
                                  :object-as :plist))
               (tex  (plist-string json "text")))
          (if (and tex (plusp (length tex)))
              (format nil "{\"role\":\"assistant\",\"content\":~a}"
                      (json-quote
                       (concatenate 'string "（mock · 未接真实模型）收到：“" tex "”")))
              "{\"error\":\"empty text\"}"))
      (error (e) (format nil "{\"error\":~a}" (json-quote (format nil "~a" e)))))))

(defparameter *server* nil)
(defun server-up () (and *server* (hunchentoot:started-p *server*)))
(let ((probe (ignore-errors
              (usocket:socket-listen "127.0.0.1" *port* :reuse-address nil
                                                       :element-type '(unsigned-byte 8)))))
  (if probe
      (ignore-errors (usocket:socket-close probe))
      (progn (format t "~&[console] 端口 ~a 已被占用：另一个实例可能正在运行（本进程退出）~%" *port*)
             (finish-output)
             (sb-ext:quit :unix-status 2 :recklessly-p t))))
(setf *server* (start (make-instance 'easy-acceptor :port *port* :address "127.0.0.1")))
(format t "~&[console] ready: http://127.0.0.1:~a/  sessions: ~a~%" *port* (length (session-ids)))
(finish-output)
(if (uiop:getenv "AGENT_CONSOLE_SELFCHECK")
    ;; probe mode issued by the tooling: boot + readiness prints already shown;
    ;; never leave a lingering process in the agent's own context.
    ;; NB: this used to call (SB-EXIT ...), an undefined function, so self-check
    ;; mode raised "The function SB-EXIT is undefined" instead of quitting.
    (progn (format t "SELFCHECK_OK_TO_QUIT~%")
           (finish-output)
           ;; :RECKLESSLY-P — without it SBCL waits up to SB-EXT:*EXIT-TIMEOUT*
           ;; (60 s) for the hunchentoot acceptor/worker threads, which never
           ;; join, so this mode kept port 8977 bound for a full minute after
           ;; announcing it was done.
           (ignore-errors (hunchentoot:stop *server*))
           (ignore-errors (sb-ext:quit :unix-status 0 :recklessly-p t)))
    (loop (sleep 60)))
