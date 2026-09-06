;;;; src/core/error.lisp — condition hierarchy (see docs/architecture.md §8).
(in-package #:agent-cl.core)

(define-condition agent-error (error)
  ((message :initarg :message :initform nil :reader agent-error-message))
  (:report (lambda (c s)
             (format s "agent-cl error~@[: ~a~]" (agent-error-message c)))))

(define-condition transport-error (agent-error)
  ((status :initarg :status :initform nil :reader transport-error-status)
   (retryable :initarg :retryable :initform nil :reader transport-error-retryable-p))
  (:report (lambda (c s)
             (format s "transport error~@[ (http ~a)~]~@[: ~a~]"
                     (transport-error-status c) (agent-error-message c)))))

(define-condition tool-error (agent-error)
  ((tool :initarg :tool :initform nil :reader tool-error-tool)
   (code :initarg :code :initform :error :reader tool-error-code))
  (:report (lambda (c s)
             (format s "tool ~a failed [~a]~@[: ~a~]"
                     (tool-error-tool c) (tool-error-code c) (agent-error-message c)))))

(define-condition dsl-error (agent-error)
  ((kind :initarg :kind :initform :parse :reader dsl-error-kind))
  (:report (lambda (c s)
             (format s "dsl error (~a)~@[: ~a~]"
                     (dsl-error-kind c) (agent-error-message c)))))

(define-condition schema-error (agent-error)
  ((path :initarg :path :initform nil :reader schema-error-path)
   (expected :initarg :expected :initform nil :reader schema-error-expected)
   (actual :initarg :actual :initform nil :reader schema-error-actual))
  (:report (lambda (c s)
             (format s "schema error at ~a: expected ~a, got ~a~@[: ~a~]"
                     (schema-error-path c) (schema-error-expected c)
                     (schema-error-actual c) (agent-error-message c)))))

(define-condition guard-triggered (agent-error)
  ((rule :initarg :rule :initform nil :reader guard-triggered-rule)
   (limit :initarg :limit :initform nil :reader guard-triggered-limit))
  (:report (lambda (c s)
             (format s "guard '~a' triggered (limit ~a)~@[: ~a~]"
                     (guard-triggered-rule c) (guard-triggered-limit c)
                     (agent-error-message c)))))

(define-condition agent-pause (agent-error)
  ((reason :initarg :reason :initform :interrupt :reader agent-pause-reason))
  (:report (lambda (c s)
             (format s "agent paused (~a)~@[: ~a~]"
                     (agent-pause-reason c) (agent-error-message c)))))
