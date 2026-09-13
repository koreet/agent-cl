;;;; src/dsl/introspect.lisp — metacognition (plan: defintrospect).
;;;;
;;;; DEFINTROSPECT declares how an agent estimates its OWN confidence from
;;;; OBSERVABLE signals (not from the model judging itself): :based-on lists
;;;; local predicate forms; confidence = fraction that hold. Below :threshold the
;;;; agent should take :on-low (a degradation path). :failure-patterns give
;;;; STRUCTURED failure attribution: the first matching pattern's :kind.
;;;;
;;;; Everything here is local and pure — "knowing what you don't know" is a
;;;; computation over signals, never a prompt. This is the point of the macro.
(in-package #:agent-cl.dsl)

(defun parse-introspect-clauses (clauses)
  "(values spec refs) for DEFINTROSPECT."
  (let ((spec nil) (refs nil))
    (dolist (cl clauses)
      (let ((key (first cl)) (val (rest cl)))
        (case key
          (:based-on
           ;; accept (:based-on (sig1 sig2 ...)) or (:based-on sig1 sig2 ...)
           (let ((sigs (if (and (= (length val) 1) (listp (first val)))
                           (first val) val)))
             (setf spec (append spec (list :based-on (copy-list sigs))))))
          (:threshold
           (unless (numberp (first val))
             (error "defintrospect: :threshold must be a number; got ~s" (first val)))
           (setf spec (append spec (list :threshold (first val)))))
          (:on-low (setf spec (append spec (list :on-low (first val)))))
          (:failure-patterns
           ;; ((:kind foo :when form) (:kind bar :when form) ...)
           (setf spec (append spec (list :failure-patterns (copy-list (first val))))))
          (:governed-by (setf refs (append refs (copy-list val)))
                        (setf spec (append spec (list :governed-by (copy-list val)))))
          (otherwise (setf spec (append spec (list key (if (= (length val) 1) (first val) val))))))))
    (values spec refs)))

(defmacro defintrospect (name lambda-list &body clauses)
  "Define a metacognition rule.
    (defintrospect auth-rework ()
      (:based-on ((has-relevant-file-p) (last-test-passed-p)))
      (:threshold 0.6)
      (:on-low :ask-clarifying-question)
      (:failure-patterns ((:kind :missing-context :when (no-relevant-file-p)))))"
  (declare (ignore lambda-list))
  (multiple-value-bind (spec refs) (parse-introspect-clauses clauses)
    `(progn
       (register-declaration
        (make-declaration ',name :introspect
                          :spec ',spec
                          :refs ',refs
                          :source ,(or *load-pathname* *compile-file-pathname*)))
       ',name)))

;;; --------------------------------------------------------------------------
;;; pure queries
;;; --------------------------------------------------------------------------

(defun introspect-spec (name)
  (let ((d (find-declaration name :introspect)))
    (and d (decl-spec d))))
(defun introspect-signals (name) (getf (introspect-spec name) :based-on))
(defun introspect-threshold (name) (or (getf (introspect-spec name) :threshold) 0.5))
(defun introspect-on-low (name) (getf (introspect-spec name) :on-low))
(defun introspect-failure-patterns (name) (getf (introspect-spec name) :failure-patterns))

(defun introspect-confidence (name)
  "Confidence in [0,1] = fraction of :based-on signal forms that hold locally.
  NIL if NAME is not an introspect declaration. No LLM involvement."
  (let ((sigs (introspect-signals name)))
    (when sigs
      (let ((n (length sigs))
            (hit (count-if #'eval-local-predicate sigs)))
        (if (zerop n) 1.0 (coerce (/ hit n) 'single-float))))))

(defun introspect-confident-p (name)
  "True when confidence >= :threshold (default 0.5)."
  (let ((c (introspect-confidence name)))
    (and c (>= c (introspect-threshold name)))))

(defun introspect-failure-kind (name)
  "First :failure-patterns entry whose :when form holds -> its :kind; else NIL.
  Structured attribution over observable conditions, no inference."
  (loop for spec in (introspect-failure-patterns name)
        for kind = (getf spec :kind)
        for when = (getf spec :when)
        when (and kind when (eval-local-predicate when)) return kind))

(defun describe-introspect (name)
  (let ((d (find-declaration name :introspect)))
    (if (null d)
        (format nil "(no introspect ~a)" name)
        (with-output-to-string (o)
          (format o "~&INTROSPECT ~a [threshold ~a]~%"
                  (decl-name d) (introspect-threshold name))
          (format o "  based-on: ~d signal(s)~%" (length (introspect-signals name)))
          (let ((ol (introspect-on-low name)))
            (when ol (format o "  on-low: ~a~%" ol)))
          (let ((fp (introspect-failure-patterns name)))
            (when fp (format o "  failure-patterns: ~d~%" (length fp))))))))
