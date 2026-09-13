;;;; src/dsl/graph.lisp — dependency graph over DSL declarations (plan: reuse refs).
;;;;
;;;; Declarations already CAPTURE symbol references (decl-refs), collected from
;;;; :governed-by / :audit-rules / :constrains / :applies-to. This module turns
;;;; that raw capture into queryable edges — forward refs, reverse refs, change
;;;; impact (transitive), and dangling-reference detection.
;;;;
;;;; A reference is "internal" when it resolves to a registered declaration of
;;;; ANY kind (a goal referencing a principle, an audit referencing a goal, ...).
;;;; References that do not resolve (a policy name, a tool name, a typo) are
;;;; kept as-is and surface through DANGLING-REFS / DECL-EXTERNAL-REFS.
;;;;
;;;; All pure functions over *DECLARATIONS* — no mutation, no engine coupling.
(in-package #:agent-cl.dsl)

(defun decl-any (name)
  "Any declaration with this NAME, regardless of kind (first by kind/name order)."
  (first (remove-if-not (lambda (d) (string= (name-string (decl-name d))
                                             (name-string name)))
                        (all-declarations))))

(defun declared-name-p (name)
  "True if NAME resolves to a registered declaration of any kind."
  (not (null (decl-any name))))

(defun decl-references (name &optional kind)
  "Forward edges: the symbol names DECLARATION (NAME,KIND) references."
  (let ((d (if kind (find-declaration name kind) (decl-any name))))
    (and d (decl-refs d))))

(defun decl-referenced-by (target-name)
  "Reverse edges: names of all declarations (any kind) that reference TARGET-NAME."
  (let ((tn (name-string target-name)) (out nil))
    (dolist (d (all-declarations))
      (when (member tn (decl-refs d) :test (lambda (a b) (string= a (name-string b))))
        (push (decl-name d) out)))
    (nreverse out)))

(defun decl-dependents (name)
  "Alias for DECL-REFERENCED-BY, spelled for 'who depends on me'."
  (decl-referenced-by name))

(defun impact-of (name &optional (kind nil))
  "Change impact: NAME plus every declaration that (transitively) references it
  — computed over INTERNAL edges only. Returns a list of (name . kind)."
  (declare (ignore kind))
  (let ((seen (make-hash-table :test 'equal))
        (acc nil)
        (queue (list (name-string name))))
    (loop while queue
          for cur = (pop queue)
          do (unless (gethash cur seen)
               (setf (gethash cur seen) t)
               (let ((d (decl-any cur)))
                 (when d (push (cons (decl-name d) (decl-kind d)) acc)))
               (dolist (rev (decl-referenced-by cur))
                 (push (name-string rev) queue))))
    (nreverse acc)))

(defun decl-internal-refs (name &optional kind)
  "References of (NAME,KIND) that DO resolve to a declaration."
  (remove-if-not #'declared-name-p (or (decl-references name kind) nil)))

(defun decl-external-refs (name &optional kind)
  "References of (NAME,KIND) that do NOT resolve (policy/tool names, typos)."
  (remove-if #'declared-name-p (or (decl-references name kind) nil)))

(defun dangling-refs ()
  "All unresolved references: list of (source-decl-name . missing-ref-name)."
  (let ((out nil))
    (dolist (d (all-declarations))
      (dolist (r (decl-refs d))
        (unless (declared-name-p r)
          (push (cons (decl-name d) r) out))))
    (nreverse out)))

(defun describe-impact (name)
  "Human-readable change-impact summary for NAME."
  (let* ((d (decl-any name))
         (imp (impact-of name))
         (ext (and d (decl-external-refs name (decl-kind d)))))
    (with-output-to-string (o)
      (format o "~&IMPACT of ~a:~%" name)
      (format o "  affects ~d declaration(s): ~{~a~^, ~}~%"
              (length imp) (mapcar (lambda (p) (car p)) imp))
      (when ext
        (format o "  external (graph-external) refs: ~{~a~^, ~}~%" ext)))))
