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
  "(values spec refs) for DEFPRINCIPLE. A non-integer :priority is rejected at
  load time: silently accepting it made CONSTITUTION-P compare a string with
  EQL and quietly report 'not constitutional'."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (unless (and (consp cl) (keywordp (first cl)))
        (error "defprinciple: malformed clause ~s (expected (:key value...))" cl))
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:priority
           (unless (integerp (first val))
             (error "defprinciple: :priority must be an integer; got ~s" (first val)))
           (setf spec (append spec (list :priority (first val)))))
          (:statement (setf spec (append spec (list :statement (first val)))))
          (:constrains (setf refs (append refs (copy-list val)))
                       (setf spec (append spec (list :constrains (copy-list val)))))
          (:governed-by (setf refs (append refs (copy-list val)))
                        (setf spec (append spec (list :governed-by (copy-list val)))))
          (:resolves-conflict (setf spec (append spec (list :resolves-conflict val)))) ; body forms
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defun note-principle-registered (name)
  "Freeze NAME's constitutional status, then return it.

  A principle is constitutional when, AT REGISTRATION TIME, its priority is at
  least the top priority already declared (ties included). The flag is stored in
  the declaration and never recomputed.

  Recomputing constitutionality from mutable priorities at query time allowed a
  two-step bypass: raise another principle above the constitution (allowed, it is
  a raise), which demoted the constitution to 'ordinary', and only then demote it
  — destroying the human-owned layer without ever being refused."
  (let* ((d (find-declaration name :principle))
         (p (and d (getf (decl-spec d) :priority)))
         (others (remove d (all-principles)))
         (top (and others
                   (reduce #'max others
                           :key (lambda (o) (or (getf (decl-spec o) :priority) 0))))))
    (when (and d (integerp p) (or (null top) (>= p top)))
      (setf (decl-spec d) (plist-put (decl-spec d) :constitutional t)))
    (and d (getf (decl-spec d) :constitutional))))

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
       ;; freeze constitutional status now, while this principle's priority is
       ;; still the one the author wrote
       (note-principle-registered ',name)
       ',name)))

;;; --------------------------------------------------------------------------
;;; reflection
;;; --------------------------------------------------------------------------

(defun principle-spec (name) (declaration-spec name :principle))
(defun principle-priority (name) (getf (principle-spec name) :priority))
(defun principle-statement (name) (getf (principle-spec name) :statement))
(defun principle-constrains (name) (getf (principle-spec name) :constrains))
(defun principle-resolves-conflict-form (name) (getf (principle-spec name) :resolves-conflict))
(defun principle-constitutional-p (name)
  "The frozen flag recorded at registration (see NOTE-PRINCIPLE-REGISTERED)."
  (getf (principle-spec name) :constitutional))

(defun all-principles ()
  (all-declarations :principle))

(defun max-principle-priority ()
  (let ((ps (all-principles)))
    (and ps (reduce #'max ps :key (lambda (d) (or (getf (decl-spec d) :priority) 0))))))

(defun constitution-p (name)
  "True iff NAME was declared as part of the constitution (top priority at
  registration time). NIL when NAME is not a principle — an unknown name is a
  query result, not an error."
  (and (principle-constitutional-p name) t))

;;; --------------------------------------------------------------------------
;;; guarded mutation: the constitution cannot be quietly demoted/removed
;;; --------------------------------------------------------------------------

(defun change-principle-priority (name new-priority)
  "Set NAME's priority to NEW-PRIORITY. REFUSES (returns :refused) when NAME is
  constitutional — the top-priority principle is human-owned and may not be
  demoted by agent code — or when NEW-PRIORITY is not an integer. Otherwise
  updates in place and returns :ok.

  Constitutionality is the FROZEN flag from registration, not a recomputation
  over current priorities, so first raising another principle cannot turn the
  constitution into an ordinary principle and unlock a second-step demotion."
  (let ((d (find-declaration name :principle)))
    (cond
      ((null d) :unknown)
      ((not (integerp new-priority)) :refused)
      ((constitution-p name)
       ;; allow a no-op or a RAISE (raising keeps it constitutional); refuse a demotion
       (if (>= new-priority (principle-priority name))
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
