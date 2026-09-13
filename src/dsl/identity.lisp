;;;; src/dsl/identity.lisp — persistent identity (plan: defidentity).
;;;;
;;;; DEFIDENTITY defines a stable persona: numeric :core-traits (queryable so
;;;; code/decisions can read them), an :anchor (the irreducible creed), and a
;;;; :memory-policy (consumed later by defmemory). It registers an :identity
;;;; declaration through the same reflection base as every other DSL form, so
;;;; describe-* and the dependency graph see it too.
;;;;
;;;; Scope by design: this is DECLARATION + pure queries. It does not (yet) wire
;;;; traits into engine decisions — that is a follow-up, and doing it now would
;;;; be over-design. Numeric traits are validated to be numbers so they can be
;;;; compared/thresholded safely.
(in-package #:agent-cl.dsl)

(defun parse-identity-clauses (clauses)
  "(values spec refs) for DEFIDENTITY."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:core-traits
           (let ((traits val))          ; ((:honesty 1.0) (:caution 0.7) ...)
             (dolist (tv traits)
               (unless (and (consp tv) (numberp (second tv)))
                 (error "defidentity: :core-traits entries must be (trait number); got ~s" tv)))
             (setf spec (append spec (list :core-traits (copy-list traits))))))
          (:anchor (setf spec (append spec (list :anchor (first val)))))
          (:memory-policy (setf spec (append spec (list :memory-policy (first val)))))
          (:governed-by (setf refs (append refs (copy-list val)))
                        (setf spec (append spec (list :governed-by (copy-list val)))))
          (otherwise
           (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defmacro defidentity (name &body clauses)
  "Define a persistent identity (persona).
    (defidentity founder ()
      (:core-traits (:honesty 1.0) (:caution 0.7) (:curiosity 0.9))
      (:anchor \"诚实优先；不确定就说不确定\")
      (:memory-policy (:keep-failures t)))"
  (multiple-value-bind (spec refs)
      (parse-identity-clauses (strip-optional-lambda-list clauses))
    `(progn
       (register-declaration
        (make-declaration ',name :identity
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*)))
       ',name)))

;;; --------------------------------------------------------------------------
;;; pure queries
;;; --------------------------------------------------------------------------

(defun identity-spec (name)
  "SPEC plist of identity NAME, or NIL when NAME is not a registered identity."
  (let ((d (find-declaration name :identity)))
    (and d (decl-spec d))))
(defun identity-traits (name)
  "The (:trait number) alist of NAME, or NIL."
  (getf (identity-spec name) :core-traits))
(defun identity-anchor (name)
  (getf (identity-spec name) :anchor))
(defun identity-memory-policy (name)
  (getf (identity-spec name) :memory-policy))

(defun identity-trait (name trait)
  "Value of TRAIT (a keyword) for identity NAME, or NIL if absent.
  Keys are matched case-insensitively against the symbol name."
  (let ((tn (string-downcase (string trait))))
    (second (find-if (lambda (tv) (and (consp tv)
                                       (string= tn (string-downcase (string (first tv))))))
                     (identity-traits name)))))

(defun identity-trait>= (name trait threshold)
  "Convenience predicate: is TRAIT >= THRESHOLD for NAME? NIL if trait absent."
  (let ((v (identity-trait name trait)))
    (and (numberp v) (>= v threshold))))

(defun describe-identity (name)
  (let ((d (find-declaration name :identity)))
    (if (null d)
        (format nil "(no identity ~a)" name)
        (with-output-to-string (o)
          (format o "~&IDENTITY ~a~%" (decl-name d))
          (let ((tr (identity-traits name)))
            (when tr
              (format o "  traits: ~{~a~^, ~}~%"
                      (mapcar (lambda (tv) (format nil "~a=~a" (first tv) (second tv))) tr))))
          (let ((a (identity-anchor name)))
            (when a (format o "  anchor: ~a~%" a)))
          (let ((mp (identity-memory-policy name)))
            (when mp (format o "  memory-policy: ~s~%" mp)))))))
