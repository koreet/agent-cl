;;;; tests/dsl-audit-tests.lisp — executable audit rules (milestone i).
;;;;
;;;; IMPORTANT: DEFWAUDIT (like DEFGUARD) registers its predicate into the
;;;; GLOBAL *EXTRA-GUARDS* table at load/macroexpansion time. A top-level
;;;; defaudit in a test file would leak into every later engine test. So every
;;;; test here runs inside (let ((agent-cl.loop:*extra-guards* nil)) ...) and
;;;; triggers registration by EVAL of the defaudit form AT TEST TIME. That
;;;; keeps the audit rules fully isolated to the test that needs them.
(in-package #:agent-cl.tests)

(defun audit-agent ()
  (agent-cl.loop:make-agent
   :transport (agent-cl.llm:make-mock-transport :script nil)
   :tools nil))

(defun rule-fn (name)
  "Fetch the registered guard predicate NAME from the CURRENT binding."
  (cdr (assoc name agent-cl.loop:*extra-guards*
              :test (lambda (item key) (string-equal item key)))))

(deftest dsl-audit-registers-declaration
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit always-trips
             (:applies-to file.write)
             (:check (declare (ignore agent)) "always blocked")
             (:on-violation :block)
             (:evidence (:kind :path-prefix :source "workspace-root"))))
    (ok (find-declaration 'always-trips :audit))
    (is-equal '(file.write) (audit-applies-to 'always-trips))
    (is-equal :block (audit-on-violation 'always-trips))
    (is-equal '(:kind :path-prefix :source "workspace-root")
              (audit-evidence 'always-trips))))

(deftest dsl-audit-default-on-violation-is-block
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit no-violation-clause
             (:check (declare (ignore agent)) nil)))
    (is-equal :block (audit-on-violation 'no-violation-clause))))

(deftest dsl-audit-predicate-enters-guard-path
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit trip-rule
             (:applies-to file.write)
             (:check (declare (ignore agent)) "blocked!")))
    ;; the rule participates in the guard registry (=> blocks engine turns)
    (ok (rule-fn "trip-rule"))))

(deftest dsl-audit-trip-returns-reason-else-nil
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit trip2 (:check (declare (ignore agent)) "blocked!")))
    (eval '(defaudit pass2 (:check (declare (ignore agent)) nil)))
    (let ((agent (audit-agent)))
      (is-equal "blocked!" (funcall (rule-fn "trip2") agent))
      (ok (null (funcall (rule-fn "pass2") agent))))))

(deftest dsl-audit-clean-registry-does-not-accumulate
  ;; isolation proof: starting from a clean binding, only rules we add are present
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit only-rule (:check (declare (ignore agent)) nil)))
    (is-equal 1 (length agent-cl.loop:*extra-guards*))))

(deftest dsl-audit-describe-shows-scope
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit scope-rule (:applies-to file.write)
             (:check (declare (ignore agent)) nil)))
    (let ((s (describe-audit 'scope-rule)))
      (ok (search "SCOPE-RULE" s))
      (ok (search "FILE.WRITE" s)))))

(deftest dsl-audit-no-llm-involvement
  (let ((agent-cl.loop:*extra-guards* nil))
    (eval '(defaudit trip3 (:check (declare (ignore agent)) "b")))
    (let* ((mk (agent-cl.llm:make-mock-transport
                :script (list (agent-cl.llm:script-reply "{\"x\":1}"))))
           (agent (agent-cl.loop:make-agent :transport mk :tools nil))
           (before (length (agent-cl.llm:mock-script mk))))
      (funcall (rule-fn "trip3") agent)
      (is-equal before (length (agent-cl.llm:mock-script mk))))))
