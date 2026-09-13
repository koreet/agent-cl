;;;; tests/dsl-memory-tests.lisp — narrative memory: decay + recall.
;;;;
;;;; Pure/offline, in a fresh *DECLARATIONS* binding.
(in-package #:agent-cl.tests)

(defmacro with-fresh-mem (&body body)
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

;; a local predicate used by :recall-when
(defparameter *context-flag* nil)
(defun context-active-p () *context-flag*)

(deftest dsl-memory-registers-with-meta
  (with-fresh-mem
    (eval '(defmemory m1 ()
             (:content "auth migration broke on a boundary case")
             (:salience 0.8)
             (:linked-to refactor-auth)))
    (ok (find-declaration 'm1 :memory))
    (is-equal 0.8 (memory-salience 'm1))
    (is-equal "auth migration broke on a boundary case" (memory-content 'm1))
    (is-equal '(refactor-auth) (memory-linked-to 'm1))))

(deftest dsl-memory-rejects-nonnumeric-salience
  (with-fresh-mem
    (signals-error error
      (eval '(defmemory bad () (:content "x") (:salience "high"))))))

(deftest dsl-memory-decay-is-monotone
  (let ((s0 1.0))
    (let ((s1 (decay-salience s0 10))
          (s2 (decay-salience s0 20)))
      (ok (< s1 s0) "decay reduces salience")
      (ok (< s2 s1) "more time -> less salience")
      (ok (<= 0.0 s2 1.0) "stays within [0,1]"))))

(deftest dsl-memory-decay-zero-time-is-identity
  (is-equal 0.8 (decay-salience 0.8 0)))

(deftest dsl-memory-recall-by-goal-link
  (with-fresh-mem
    (eval '(defmemory a () (:content "for auth") (:salience 0.5) (:linked-to auth)))
    (eval '(defmemory b () (:content "for billing") (:salience 0.9) (:linked-to billing)))
    (let ((hits (recall-memories :goal 'auth)))
      (is-equal '(a) hits "only the auth-linked memory is recalled"))))

(deftest dsl-memory-recall-by-condition
  (with-fresh-mem
    (setf *context-flag* nil)
    (eval '(defmemory cond-m () (:content "c") (:salience 0.6)
             (:recall-when (context-active-p))))
    (ok (null (recall-memories)) "condition false -> not recalled")
    (setf *context-flag* t)
    (is-equal '(cond-m) (recall-memories) "condition true -> recalled")
    (setf *context-flag* nil)))

(deftest dsl-memory-recall-ranked-by-salience
  (with-fresh-mem
    (eval '(defmemory low  () (:content "l") (:salience 0.2)))
    (eval '(defmemory high () (:content "h") (:salience 0.9)))
    (eval '(defmemory mid  () (:content "m") (:salience 0.5)))
    (is-equal '(high mid low) (recall-memories))))

(deftest dsl-memory-recall-respects-min-salience
  (with-fresh-mem
    (eval '(defmemory keep () (:content "k") (:salience 0.7)))
    (eval '(defmemory drop () (:content "d") (:salience 0.1)))
    (is-equal '(keep) (recall-memories :min-salience 0.5))))

(deftest dsl-memory-linked-to-enters-graph
  (with-fresh-mem
    (eval '(defgoal g1 () (:intent "x"))
    )
    (eval '(defmemory m2 () (:content "c") (:salience 0.5) (:linked-to g1)))
    (is-equal '(g1) (decl-refs (find-declaration 'm2 :memory)))
    (ok (member 'm2 (decl-referenced-by 'g1)))))
