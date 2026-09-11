;;;; tests/dsl-principle-tests.lisp — principles + constitution (milestone ii).
;;;;
;;;; Pure/offline. Principles register into the global *DECLARATIONS* table, and
;;;; CONSTITUTION-P depends on the top priority across all principles, so each
;;;; test runs in a FRESH *DECLARATIONS* binding (isolated) to keep the
;;;; constitution deterministic and avoid cross-test contamination.
(in-package #:agent-cl.tests)

(defmacro with-fresh-decls (&body body)
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

(deftest dsl-principle-registers-with-meta
  (with-fresh-decls
    (eval '(defprinciple data-integrity ()
             (:priority 100)
             (:statement "user data integrity outranks speed")
             (:constrains workspace-write)))
    (ok (find-declaration 'data-integrity :principle))
    (is-equal 100 (principle-priority 'data-integrity))
    (is-equal "user data integrity outranks speed" (principle-statement 'data-integrity))
    (is-equal '(workspace-write) (principle-constrains 'data-integrity))))

(deftest dsl-principle-constitution-is-top-priority
  (with-fresh-decls
    (eval '(defprinciple p-high () (:priority 100)))
    (eval '(defprinciple p-low  () (:priority 40)))
    (ok (constitution-p 'p-high))
    (ok (not (constitution-p 'p-low)))
    (is-equal 100 (max-principle-priority))))

(deftest dsl-principle-constitutional-demotion-refused
  (with-fresh-decls
    (eval '(defprinciple const () (:priority 100)))
    (eval '(defprinciple other () (:priority 50)))
    ;; demotion of the constitution is refused; priority unchanged
    (is-equal :refused (change-principle-priority 'const 10))
    (is-equal 100 (principle-priority 'const))
    ;; raising it is allowed (stays constitutional)
    (is-equal :ok (change-principle-priority 'const 120))
    (is-equal 120 (principle-priority 'const))
    ;; the non-top principle may be freely changed
    (is-equal :ok (change-principle-priority 'other 70))
    (is-equal 70 (principle-priority 'other))))

(deftest dsl-principle-unknown-change
  (with-fresh-decls
    (is-equal :unknown (change-principle-priority 'nope 1))))

(deftest dsl-principle-stop-constrains-note
  ;; a principle that the agent might delete: no delete entry exists, so the
  ;; only mutation is priority; constitution stays protective (covered above).
  (with-fresh-decls
    (eval '(defprinciple sole () (:priority 100)))
    (ok (constitution-p 'sole))))

(deftest dsl-principle-resolve-by-priority
  (with-fresh-decls
    (eval '(defprinciple a () (:priority 30)))
    (eval '(defprinciple b () (:priority 90)))
    (eval '(defprinciple c () (:priority 60)))
    (let ((winners (resolve-principles '(a b c))))
      (is-equal '(b c a) (mapcar #'decl-name winners)))))

(deftest dsl-principle-describe-shows-priority-and-flag
  (with-fresh-decls
    (eval '(defprinciple top () (:priority 100) (:statement "constitution")))
    (let ((s (describe-principle 'top)))
      (ok (search "TOP" s))
      (ok (search "100" s))
      (ok (search "CONSTITUTION" s)))))
