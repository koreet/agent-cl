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
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across (if (stringp s) s (princ-to-string s)) do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Tab (write-string "\\t" o))
        (#\Return (write-string "\\r" o))
        (otherwise (write-char c o))))
    (write-char #\" o)))

(defun session-ids ()
  (ensure-directories-exist *sessions-dir*)
  (loop for sub in (uiop:subdirectories *sessions-dir*)
        for nm  = (car (last (pathname-directory (pathname sub))))
        when (and nm (probe-file (merge-pathnames "events.jsonl" sub)))
          collect (string nm)))

(defun read-session (id)
  (let ((f (merge-pathnames (concatenate 'string id "/events.jsonl")
                            *sessions-dir*)))
    (when (probe-file f)
      (with-output-to-string (o)
        (write-char #\[ o)
        (let ((first t))
          (with-open-file (in f :external-format :utf-8)
            (loop for line = (read-line in nil nil) while line do
              (handler-case
                  (progn
                    (unless first (write-char #\, o))
                    (write-string line o)
                    (setf first nil))
                (error () nil)))))
        (write-char #\] o)))))

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
(setf *server* (start (make-instance 'easy-acceptor :port *port* :address "127.0.0.1")))
(format t "~&[console] ready: http://127.0.0.1:~a/  sessions: ~a~%" *port* (length (session-ids)))
(finish-output)
(if (uiop:getenv "AGENT_CONSOLE_SELFCHECK")
    ;; probe mode issued by the tooling: boot + readiness prints already shown;
    ;; never leave a lingering process in the agent's own context.
    (sb-exit (progn (format t "SELFCHECK_OK_TO_QUIT~%") (finish-output)
                    (ignore-errors (sb-ext:quit :unix-status 0))))
    (loop (sleep 60)))
