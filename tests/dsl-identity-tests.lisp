;;;; tests/dsl-identity-tests.lisp — persistent identity declaration + queries.
;;;;
;;;; Pure/offline, in a fresh *DECLARATIONS* binding for determinism.
(in-package #:agent-cl.tests)

(defmacro with-fresh-ids (&body body)
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

(deftest dsl-identity-registers-and-traits
  (with-fresh-ids
    (eval '(defidentity founder ()
             (:core-traits (:honesty 1.0) (:caution 0.7) (:curiosity 0.9))
             (:anchor "be honest")
             (:memory-policy (:keep-failures t))))
    (ok (find-declaration 'founder :identity))
    (is-equal 1.0 (identity-trait 'founder :honesty))
    (is-equal 0.7 (identity-trait 'founder :caution))
    (is-equal "be honest" (identity-anchor 'founder))
    (is-equal '(:keep-failures t) (identity-memory-policy 'founder))))

(deftest dsl-identity-trait-absent-is-nil
  (with-fresh-ids
    (eval '(defidentity id2 () (:core-traits (:honesty 1.0))))
    (ok (null (identity-trait 'id2 :nonexistent)))
    (ok (null (identity-trait 'no-such-identity :honesty)))))

(deftest dsl-identity-trait-threshold
  (with-fresh-ids
    (eval '(defidentity id3 () (:core-traits (:honesty 1.0) (:caution 0.4))))
    (ok (identity-trait>= 'id3 :honesty 0.9))
    (ok (not (identity-trait>= 'id3 :caution 0.9)))
    (ok (not (identity-trait>= 'id3 :absent 0.0)) "absent trait is never >=")))

(deftest dsl-identity-rejects-nonnumeric-traits
  (with-fresh-ids
    (signals-error error
      (eval '(defidentity bad () (:core-traits (:honesty "very")))))))

(deftest dsl-identity-describe
  (with-fresh-ids
    (eval '(defidentity id4 () (:core-traits (:honesty 1.0)) (:anchor "creed")))
    (let ((s (describe-identity 'id4)))
      (ok (search "ID4" s))
      (ok (search "HONESTY" s))
      (ok (search "creed" s)))))

(deftest dsl-identity-governed-by-enters-graph
  (with-fresh-ids
    (eval '(defprinciple data-integrity () (:priority 100)))
    (eval '(defidentity id5 () (:core-traits (:honesty 1.0))
             (:governed-by data-integrity)))
    (is-equal '(data-integrity) (decl-refs (find-declaration 'id5 :identity)))
    (ok (member 'id5 (decl-referenced-by 'data-integrity)))))
