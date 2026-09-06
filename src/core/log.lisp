;;;; src/core/log.lisp — dependency-free leveled logger.
;;;;
;;;; Adaptation note: docs/architecture.md preferred log4cl with "self-made" as
;;;; the fallback; this sandbox cannot fetch the log4cl dependency closure, so
;;;; we ship the fallback. The public surface (log-debug/log-info/...) is small
;;;; enough to swap for log4cl later without touching call sites.
(in-package #:agent-cl.core)

(defparameter *log-level* :info)
(defparameter *log-output* *error-output*)

(defparameter *log-levels* '(:trace 0 :debug 1 :info 2 :warn 3 :error 4))

(defun log-enabled-p (level)
  (>= (or (cdr (assoc level *log-levels*)) 1)
      (or (cdr (assoc *log-level* *log-levels*)) 1)))

(defun log-message (level fmt &rest args)
  (when (log-enabled-p level)
    (format *log-output* "~&[~a] ~a ~a~%"
            (string-downcase (symbol-name level))
            (now-iso8601)
            (apply #'format nil fmt args))
    (finish-output *log-output*)))

(defmacro define-log-fn (name level)
  `(defun ,name (fmt &rest args)
     (apply #'log-message ,level fmt args)))

(define-log-fn log-trace :trace)
(define-log-fn log-debug :debug)
(define-log-fn log-info  :info)
(define-log-fn log-warn  :warn)
(define-log-fn log-error :error)
