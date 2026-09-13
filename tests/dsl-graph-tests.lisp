;;;; tests/dsl-graph-tests.lisp — dependency graph over declarations.
;;;;
;;;; Pure/offline. Each test runs in a FRESH *DECLARATIONS* binding so the graph
;;;; is deterministic. We register declarations directly (make-declaration +
;;;; register-declaration) with explicit :refs — this exercises the graph layer
;;;; without depending on how each macro happens to fill refs.
(in-package #:agent-cl.tests)

(defmacro with-graph (&body body)
  `(let ((agent-cl.dsl::*declarations* (make-hash-table :test 'equal)))
     ,@body))

(defun reg (name kind refs)
  (register-declaration (make-declaration name kind :refs refs :spec nil)))

(deftest dsl-graph-forward-refs
  (with-graph
    (reg 'auth-refactor :goal '(data-integrity least-privilege))
    (is-equal '(data-integrity least-privilege) (decl-references 'auth-refactor :goal))))

(deftest dsl-graph-reverse-refs
  (with-graph
    (reg 'data-integrity :principle nil)
    (reg 'auth-refactor :goal '(data-integrity))
    (reg 'no-outside-writes :audit '(data-integrity))
    (reg 'unrelated :goal '(something-else))
    (let ((rev (decl-referenced-by 'data-integrity)))
      (ok (member 'auth-refactor rev))
      (ok (member 'no-outside-writes rev))
      (ok (not (member 'unrelated rev))))))

(deftest dsl-graph-transitive-impact
  (with-graph
    (reg 'constitution :principle nil)
    (reg 'mid :goal '(constitution))
    (reg 'top :goal '(mid))
    (let ((imp (mapcar #'car (impact-of 'constitution))))
      ;; constitution affects itself, mid, and (transitively) top
      (ok (member 'constitution imp))
      (ok (member 'mid imp))
      (ok (member 'top imp)))))

(deftest dsl-graph-internal-vs-external-refs
  (with-graph
    (reg 'data-integrity :principle nil)          ; resolves
    (reg 'worker :goal '(data-integrity workspace-write)) ; workspace-write = policy/tool name
    (is-equal '(data-integrity) (decl-internal-refs 'worker :goal))
    (is-equal '(workspace-write) (decl-external-refs 'worker :goal))))

(deftest dsl-graph-dangling-detection
  (with-graph
    (reg 'uses-missing :goal '(does-not-exist))
    (let ((dg (dangling-refs)))
      (ok (find 'uses-missing dg :key #'car))
      (ok (find 'does-not-exist dg :key #'cdr)))))

(deftest dsl-graph-cross-kind-edges
  (with-graph
    (reg 'file-gate :audit '(file.write))         ; audit -> tool-ish name
    (reg 'file-writer :goal '(file-gate))         ; goal -> audit (internal!)
    ;; file-gate is internal (a registered decl); file.write is external
    (is-equal '(file-gate) (decl-internal-refs 'file-writer :goal))
    (let ((rev (decl-referenced-by 'file-gate)))
      (ok (member 'file-writer rev)))))

(deftest dsl-graph-describe-impact
  (with-graph
    (reg 'p :principle nil)
    (reg 'g :goal '(p))
    (let ((s (describe-impact 'p)))
      (ok (search "IMPACT" s))
      (ok (search "G" s)))))
