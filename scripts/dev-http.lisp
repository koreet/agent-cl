;;;; scripts/dev-http.lisp — enable in-process HTTPS via dexador + cl+ssl.
;;;;
;;;; The offline sandbox cannot use schannel-based TLS and dexador's default
;;;; Windows backend is WinHTTP (schannel), so we force the usocket backend with
;;;; cl+ssl over OpenSSL. Load this AFTER agent-cl plus an ASDF source-registry
;;;; that includes <repo>/.tools/deps and <repo>/.tools/sbcl/contrib (see
;;;; smoke.lisp / repl.lisp for the registry setup), then:
;;;;   (agent-cl.dexador-dev:enable-hook :ca-file ".../ca-bundle.trust.crt")
;;;; It installs agent-cl.llm:*http-fetch-hook* so the http transport performs
;;;; real HTTPS requests directly in the SBCL process (no subprocess).
;;;;
;;;; Note: every foreign-package reference is resolved at runtime via
;;;; find-symbol so this file loads before those packages exist.
(in-package #:cl-user)

(defpackage #:agent-cl.dexador-dev
  (:use #:cl)
  (:export #:enable-hook #:*ca-file*))

(in-package #:agent-cl.dexador-dev)

(defparameter *ca-file*
  (or (let ((v (uiop:getenv "SSL_CERT_FILE")))
        (and v (probe-file v)))
      (probe-file "C:/Program Files/Git/mingw64/etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt")
      (probe-file "/etc/ssl/certs/ca-certificates.crt")))

(defun load-optional (system)
  "Load SYSTEM. Prefer ql:quickload when Quicklisp is present (its dist systems
  are otherwise invisible to plain asdf:load-system in a fresh process)."
  (handler-case
      (let ((q (find-package "QL")))
        (if q
            (progn (funcall (find-symbol "QUICKLOAD" q) (list system) :silent t) t)
            (progn (asdf:load-system system) t)))
    (error (e)
      (format t "~&[dev-http] cannot load ~a: ~a~%" system e)
      nil)))

(defun set-env (name value)
  "Best-effort process env set via sb-posix (runtime-resolved)."
  (handler-case
      (progn
        (require "SB-POSIX")
        (let ((fn (find-symbol "SETENV" (find-package "SB-POSIX"))))
          (when fn (funcall fn name value 1))))
    (error (e)
      (format t "~&[dev-http] cannot set ~a: ~a~%" name e))))

(defun http-body-text (body &optional (limit 500))
  "Return up to LIMIT printable chars of a dexador response BODY, which may be
  a string, a byte vector, a (decoding) stream, or NIL."
  (flet ((cut (s) (subseq s 0 (min limit (length s)))))
    (handler-case
        (cond
          ((stringp body) (cut body))
          ((streamp body)
           (let ((out (make-string-output-stream)))
             (loop repeat limit
                   for ch = (read-char body nil nil)
                   while ch
                   do (write-char ch out))
             (get-output-stream-string out)))
          ((and (vectorp body) (not (stringp body)))
           ;; dexador error bodies may come back as (unsigned-byte 8) arrays
           (cut (map 'string (lambda (b) (code-char (logand b 255))) body)))
          (t (cut (princ-to-string body))))
      (error () "<unreadable http body>"))))

(defun dexador-failed-info (c)
  "If C is a dexador http-request-failed (resolved at runtime so this file
  loads before dexador does), return (values status body-text); else NIL."
  (let* ((epkg (find-package "DEXADOR.ERROR"))
         (cls (and epkg (find-symbol "HTTP-REQUEST-FAILED" epkg))))
    (when (and cls (typep c cls))
      (let ((rs (and epkg (find-symbol "RESPONSE-STATUS" epkg)))
            (rb (and epkg (find-symbol "RESPONSE-BODY" epkg))))
        (values (and rs (ignore-errors (funcall rs c)))
                (http-body-text (and rb (ignore-errors (funcall rb c)))))))))

(defun dexador-post (post url request-json headers stream)
  "POST to URL, converting dexador's continuable http-request-failed (raised
  for any status >= 400, with the body as a decoding stream) into a clean
  agent-cl transport-error. Returns BODY on 2xx."
  (let ((args (append (list :content request-json
                            :headers headers
                            :read-timeout (if stream 240 120)
                            :connect-timeout 30)
                      (when stream (list :want-stream t :force-string t)))))
    (handler-bind
        ((error
          (lambda (c)
            (multiple-value-bind (st bt) (dexador-failed-info c)
              (when st
                (error 'agent-cl.core:transport-error
                       :message (format nil "http ~a: ~a" st bt)
                       :status st
                       ;; 5xx and 429 (rate limit) are transient; 4xx are not
                       :retryable (or (>= st 500) (= st 429))))))))
      (multiple-value-bind (body status)
          (apply post url args)
        (unless (<= 200 status 299)
          (error 'agent-cl.core:transport-error
                 :message (format nil "http ~a: ~a" status
                                  (http-body-text body))
                 :status status
                 :retryable (or (>= status 500) (= status 429))))
        body))))

(defun install-hook (pkg)
  "Resolve dexador's POST/backend symbols in PKG and install the hook."
  (let ((backend-var (and pkg (intern "*DEXADOR-BACKEND*" pkg)))
        (post (and pkg (find-symbol "POST" pkg))))
    (when (and backend-var post)
      (setf (symbol-value backend-var) :usocket)
      (setf agent-cl.llm:*http-fetch-hook*
            (lambda (request-json &key base-url api-key timeout stream)
              (declare (ignore timeout))
              (let ((url (concatenate 'string base-url "/chat/completions"))
                    (headers `(("Content-Type" . "application/json")
                               ("Authorization" . ,(format nil "Bearer ~a" api-key)))))
                (dexador-post post url request-json headers stream)))))
    t))

(defun enable-hook (&key (ca-file *ca-file*))
  "Load cffi/cl+ssl/dexador, force the usocket backend and install a dexador
  based *http-fetch-hook*. Returns T on success."
  (when ca-file
    (set-env "SSL_CERT_FILE" (namestring ca-file)))
  (let ((ok (and (load-optional :cffi)
                 (load-optional :cl+ssl)
                 (load-optional :dexador)
                 ;; official dexador on Windows only compiles the winhttp backend;
                 ;; load dexador-usocket so the usocket+cl+ssl backend exists
                 (load-optional :dexador-usocket)
                 (install-hook (find-package :dexador)))))
    (when ok
      (format t "~&[dev-http] dexador direct hook installed (in-process TLS)~%"))
    ok))
