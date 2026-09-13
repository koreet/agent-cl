;;;; tests/dsl-introspect-tests.lisp — metacognition: confidence from signals.
;;;;
;;;; Pure/offline, in a fresh *DECLARATIONS* binding. "Confidence" is a local
;;;; computation over observable signal predicates — no model judgement.
(in-package #:agent-cl.tests)

(defmacro with-fresh-intro (&body body)
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

;; switchable local signals
(defparameter *sig-a* nil)
(defparameter *sig-b* nil)
(defun sig-a () *sig-a*)
(defun sig-b () *sig-b*)

(deftest dsl-introspect-registers-with-meta
  (with-fresh-intro
    (eval '(defintrospect probe ()
             (:based-on ((sig-a) (sig-b)))
             (:threshold 0.6)
             (:on-low :ask)
             (:failure-patterns ((:kind :missing-context :when (sig-a))))))
    (ok (find-declaration 'probe :introspect))
    (is-equal 0.6 (introspect-threshold 'probe))
    (is-equal :ask (introspect-on-low 'probe))
    (is-equal 2 (length (introspect-signals 'probe)))))

(deftest dsl-introspect-confidence-is-signal-fraction
  (with-fresh-intro
    (eval '(defintrospect probe2 () (:based-on ((sig-a) (sig-b))) (:threshold 0.5)))
    (setf *sig-a* nil *sig-b* nil) (is-equal 0.0e0 (introspect-confidence 'probe2))
    (setf *sig-a* t   *sig-b* nil) (is-equal 0.5e0 (introspect-confidence 'probe2))
    (setf *sig-a* t   *sig-b* t)   (is-equal 1.0e0 (introspect-confidence 'probe2))
    (setf *sig-a* nil *sig-b* nil)))

(deftest dsl-introspect-confident-p-threshold
  (with-fresh-intro
    (eval '(defintrospect probe3 () (:based-on ((sig-a) (sig-b))) (:threshold 0.6)))
    (setf *sig-a* t *sig-b* nil)   ; 0.5 < 0.6
    (ok (not (introspect-confident-p 'probe3)))
    (setf *sig-a* t *sig-b* t)     ; 1.0 >= 0.6
    (ok (introspect-confident-p 'probe3))
    (setf *sig-a* nil *sig-b* nil)))

(deftest dsl-introspect-failure-attribution
  (with-fresh-intro
    (eval '(defintrospect probe4 ()
             (:based-on ((sig-a)))
             (:failure-patterns ((:kind :k1 :when (sig-a))
                                 (:kind :k2 :when (sig-b))))))
    (setf *sig-a* nil *sig-b* nil)
    (ok (null (introspect-failure-kind 'probe4)) "no pattern matches")
    (setf *sig-b* t)
    (is-equal :k2 (introspect-failure-kind 'probe4))
    (setf *sig-a* t)                        ; first matching pattern wins
    (is-equal :k1 (introspect-failure-kind 'probe4))
    (setf *sig-a* nil *sig-b* nil)))

(deftest dsl-introspect-rejects-nonnumeric-threshold
  (with-fresh-intro
    (signals-error error
      (eval '(defintrospect bad () (:based-on ((sig-a))) (:threshold "hi"))))))

(deftest dsl-introspect-unknown-is-nil
  (with-fresh-intro
    (ok (null (introspect-confidence 'nope)))
    (ok (null (introspect-confident-p 'nope)))))

(deftest dsl-introspect-describe
  (with-fresh-intro
    (eval '(defintrospect probe5 () (:based-on ((sig-a))) (:threshold 0.7) (:on-low :halt)))
    (let ((s (describe-introspect 'probe5)))
      (ok (search "PROBE5" s))
      (ok (search "0.7" s))
      (ok (search "HALT" s)))))
