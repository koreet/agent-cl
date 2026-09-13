;;;; src/dsl/memory.lisp — narrative memory (plan: defmemory).
;;;;
;;;; DEFMEMORY defines a lifecycle memory entry — not a key/value pair, but a
;;;; record with emotional weight (:salience), an association to a goal
;;;; (:linked-to), and a retrieval condition (:recall-when, a local predicate).
;;;; Salience decays over time (pure function) and entries are recalled when
;;;; their condition holds, ranked by salience.
;;;;
;;;; Scope by design: DECLARATION + pure decay/recall queries. Injecting recalled
;;;; memories into the engine's context (choose-messages) is a follow-up; doing
;;;; it now would couple this to the engine before the semantics settle.
(in-package #:agent-cl.dsl)

(defun parse-memory-clauses (clauses)
  "(values spec refs) for DEFMEMORY. :linked-to entries become graph refs."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:content (setf spec (append spec (list :content (first val)))))
          (:salience
           (unless (numberp (first val))
             (error "defmemory: :salience must be a number; got ~s" (first val)))
           (setf spec (append spec (list :salience (first val)))))
          (:linked-to (setf refs (append refs (copy-list val)))
                      (setf spec (append spec (list :linked-to (copy-list val)))))
          (:recall-when (setf spec (append spec (list :recall-when (first val)))))
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defmacro defmemory (name &body clauses)
  "Define a lifecycle memory entry.
    (defmemory failed-migration-42 ()
      (:content \"last auth migration broke on a boundary case\")
      (:salience 0.8)
      (:linked-to refactor-auth)
      (:recall-when (goal-active-p 'refactor-auth)))"
  (multiple-value-bind (spec refs)
      (parse-memory-clauses (strip-optional-lambda-list clauses))
    `(progn
       (register-declaration
        (make-declaration ',name :memory
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*)))
       ',name)))

;;; --------------------------------------------------------------------------
;;; pure queries
;;; --------------------------------------------------------------------------

(defun memory-spec (name)
  (let ((d (find-declaration name :memory)))
    (and d (decl-spec d))))
(defun memory-content (name) (getf (memory-spec name) :content))
(defun memory-salience (name) (getf (memory-spec name) :salience))
(defun memory-linked-to (name) (getf (memory-spec name) :linked-to))
(defun memory-recall-when-form (name) (getf (memory-spec name) :recall-when))

;;; --------------------------------------------------------------------------
;;; salience decay (pure)
;;; --------------------------------------------------------------------------

(defparameter *default-decay-rate* 0.05
  "Exponential decay rate per time unit (salience *= exp(-rate*dt)).")

(defun decay-salience (salience elapsed &optional (rate *default-decay-rate*))
  "Salience after ELAPSED time units of exponential decay. Clamps to [0,1]."
  (let ((v (* salience (exp (- (* rate elapsed))))))
    (max 0.0 (min 1.0 v))))

;;; --------------------------------------------------------------------------
;;; recall (pure, local predicate)
;;; --------------------------------------------------------------------------

(defun memory-applicable-p (name &key goal)
  "True when memory NAME should be recalled: its :linked-to (if any) matches
  GOAL, and its :recall-when predicate (if any) holds locally. No LLM."
  (let ((linked (memory-linked-to name))
        (form (memory-recall-when-form name)))
    (and (or (null goal)
             (null linked)
             (member goal linked :test (lambda (a b) (string-equal a b))))
         (or (null form) (eval-local-predicate form)))))

(defun recall-memories (&key goal (min-salience 0.0))
  "Return memory declarations that apply (GOAL link + :recall-when), with
  salience >= MIN-SALIENCE, ranked by salience desc. Names only."
  (let ((hits (loop for d in (all-declarations :memory)
                    for nm = (decl-name d)
                    when (and (or (null min-salience)
                                  (>= (or (memory-salience nm) 0) min-salience))
                              (memory-applicable-p nm :goal goal))
                      collect nm)))
    (sort hits #'> :key (lambda (nm) (or (memory-salience nm) 0)))))

(defun describe-memory (name)
  (let ((d (find-declaration name :memory)))
    (if (null d)
        (format nil "(no memory ~a)" name)
        (with-output-to-string (o)
          (format o "~&MEMORY ~a [salience ~a]~%" (decl-name d) (memory-salience name))
          (format o "  content: ~a~%" (memory-content name))
          (let ((l (memory-linked-to name)))
            (when l (format o "  linked-to: ~{~a~^, ~}~%" l)))
          (let ((f (memory-recall-when-form name)))
            (when f (format o "  recall-when: ~s~%" f)))))))
