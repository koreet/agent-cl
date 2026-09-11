;;;; src/dsl/principles.lisp — principles + constitution (plan §B, milestone ii).
;;;;
;;;; A PRINCIPLE is "what to protect, and in what priority order". The
;;;; highest-priority principle(s) form the CONSTITUTION: agentcode may NOT
;;;; silently lower or delete them (mirrors plan §2.3 "宪法层: Agent 不可随意改").
;;;;
;;;; Minimal, testable scope (no inference engine):
;;;;   * defprinciple: register a :principle declaration (priority, statement,
;;;;     :constrains refs, optional :resolves-conflict body).
;;;;   * principle-priority / principle-statement / principle-constrains.
;;;;   * constitution-p: a principle is constitutional iff its priority equals
;;;;     the current maximum priority among all principles.
;;;;   * change-principle-priority: refuses to demote/remove a constitutional
;;;;     principle; allows ordinary (non-top) changes. Returns (:ok ...)/errors.
;;;;   * resolve-principles: returns the winning principles for a conflict by
;;;;     priority order (highest first); :resolves-conflict is captured but not
;;;;     executed here — executing arbitrary conflict logic is a later step.
(in-package #:agent-cl.dsl)

(defun parse-principle-clauses (clauses)
  "(values spec refs) for DEFPRINCIPLE."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:priority (setf spec (append spec (list :priority (first val)))))
          (:statement (setf spec (append spec (list :statement (first val)))))
          (:constrains (setf refs (append refs (copy-list val)))
                       (setf spec (append spec (list :constrains (copy-list val)))))
          (:governed-by (setf refs (append refs (copy-list val)))
                        (setf spec (append spec (list :governed-by (copy-list val)))))
          (:resolves-conflict (setf spec (append spec (list :resolves-conflict val)))) ; body forms
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defmacro defprinciple (name lambda-list &body clauses)
  "Define a principle. LAMBDA-LIST is conventionally () (kept for symmetry).
    (defprinciple data-integrity ()
      (:priority 100)
      (:statement \"用户数据的完整性优先于任务完成速度\")
      (:constrains workspace-write))"
  (declare (ignore lambda-list))
  (multiple-value-bind (spec refs) (parse-principle-clauses clauses)
    `(progn
       (register-declaration
        (make-declaration ',name :principle
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*)))
       ',name)))

;;; --------------------------------------------------------------------------
;;; reflection
;;; --------------------------------------------------------------------------

(defun principle-spec (name) (decl-spec (find-declaration name :principle)))
(defun principle-priority (name) (getf (principle-spec name) :priority))
(defun principle-statement (name) (getf (principle-spec name) :statement))
(defun principle-constrains (name) (getf (principle-spec name) :constrains))
(defun principle-resolves-conflict-form (name) (getf (principle-spec name) :resolves-conflict))

(defun all-principles ()
  (all-declarations :principle))

(defun max-principle-priority ()
  (let ((ps (all-principles)))
    (and ps (reduce #'max ps :key (lambda (d) (or (getf (decl-spec d) :priority) 0))))))

(defun constitution-p (name)
  "True iff NAME's priority equals the current top priority (a constitutional
  principle). NIL when NAME is not a principle."
  (let ((p (principle-priority name)))
    (and p (eql p (max-principle-priority)))))

;;; --------------------------------------------------------------------------
;;; guarded mutation: the constitution cannot be quietly demoted/removed
;;; --------------------------------------------------------------------------

(defun change-principle-priority (name new-priority)
  "Set NAME's priority to NEW-PRIORITY. REFUSES (returns :refused) when NAME is
  constitutional — the top-priority principle is human-owned and may not be
  demoted by agent code. Otherwise updates in place and returns :ok."
  (let ((d (find-declaration name :principle)))
    (cond
      ((null d) :unknown)
      ((constitution-p name)
       ;; allow a no-op or a RAISE (raising keeps it constitutional); refuse a demotion
       (if (and (integerp new-priority)
                (>= new-priority (principle-priority name)))
           (progn (setf (decl-spec d) (plist-put (decl-spec d) :priority new-priority)) :ok)
           :refused))
      (t
       (setf (decl-spec d) (plist-put (decl-spec d) :priority new-priority))
       :ok))))

(defun plist-put (pl key val)
  "Return PL with KEY set to VAL (insert if absent)."
  (if (loop for (k) on pl by #'cddr thereis (eq k key))
      (loop for (k v) on pl by #'cddr
            append (if (eq k key) (list key val) (list k v)))
      (append pl (list key val))))

;;; --------------------------------------------------------------------------
;;; conflict resolution (priority order only; bodies captured, not executed)
;;; --------------------------------------------------------------------------

(defun resolve-principles (&optional names)
  "Given NAMES (principles in conflict; NIL = all), return them sorted by
  priority, highest first. The winner is the first. Actual :resolves-conflict
  bodies are captured in metadata but NOT executed at this milestone."
  (let ((ds (if names
                (remove nil (mapcar (lambda (n) (find-declaration n :principle)) names))
                (all-principles))))
    (sort ds #'> :key (lambda (d) (or (getf (decl-spec d) :priority) 0)))))

(defun describe-principle (name)
  (let ((d (find-declaration name :principle)))
    (if (null d)
        (format nil "(no principle ~a)" name)
        (with-output-to-string (o)
          (format o "~&PRINCIPLE ~a [priority ~a~a]~%  ~a"
                  (decl-name d)
                  (principle-priority name)
                  (if (constitution-p name) " · CONSTITUTION" "")
                  (principle-statement name))
          (let ((cs (principle-constrains name)))
            (when cs
              (format o "~%  constrains: ~{~a~^, ~}" cs)))
          (terpri o)))))
