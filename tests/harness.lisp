;;;; tests/harness.lisp — dependency-free test harness.
;;;;
;;;; Adaptation note: docs/architecture.md preferred rove; this sandbox cannot
;;;; fetch its dependency closure, so Agent-CL ships this ~90-line harness with
;;;; the same ergonomics (deftest / ok / is-equal / signals-error). Swapping in
;;;; rove on a networked machine touches only this file's macros.

(defpackage #:agent-cl.tests
  (:use #:cl
        #:agent-cl.core #:agent-cl.messages #:agent-cl.llm #:agent-cl.schema
        #:agent-cl.tools #:agent-cl.loop #:agent-cl.dsl #:agent-cl.session)
  (:export #:deftest #:ok #:is-equal #:signals-error #:run-all #:run-tests))

(in-package #:agent-cl.tests)

(defvar *tests* (make-hash-table :test 'equal))
(defvar *order* nil)
(defvar *pass-count* 0)
(defvar *fail-count* 0)
(defvar *current-name* nil)
(defvar *local-fail* nil)

(defmacro deftest (name &body body)
  "Register a named test. BODY may use OK, IS-EQUAL, SIGNALS-ERROR."
  (let ((n (string-downcase (string name))))
    `(progn
       (setf (gethash ,n *tests*) (lambda () (let ((*local-fail* nil))
                                               ,@body
                                               (unless *local-fail*
                                                 (incf *pass-count*)))))
       (pushnew ,n *order* :test #'string=)
       ',name)))

(defun note-failure (detail)
  (setf *local-fail* t)
  (incf *fail-count*)
  (format t "~&  [FAIL] ~a: ~a~%" *current-name* detail)
  (finish-output))

(defmacro ok (form &optional (message nil))
  "Assert FORM evaluates true."
  `(unless ,form
     (note-failure (or ,message ,(format nil "~s is false" form)))))

(defmacro is-equal (expected form &optional (message nil))
  "Assert (equal EXPECTED FORM)."
  `(let ((got ,form))
     (unless (equal ,expected got)
       (note-failure (format nil "expected ~s but got ~s~@[ — ~a~]"
                             ,expected got ,message)))))

(defmacro signals-error (condition-type &body body)
  "Assert BODY signals CONDITION-TYPE (or a subtype of it)."
  `(handler-case
       (progn ,@body
         (note-failure (format nil "expected ~s to signal, but it returned"
                               ',condition-type)))
     (,condition-type () t)))

(defun run-one (name)
  (let ((fn (gethash name *tests*)))
    (format t "~&[RUN ] ~a~%" name)
    (finish-output)
    (handler-case
        (funcall fn)
      (error (e)
        (setf *local-fail* t)
        (incf *fail-count*)
        (format t "~&  [FAIL] ~a: unhandled error ~a~%" name e)))))

(defun run-all (&key (names nil))
  "Run all registered tests (or only NAMES). Returns T when everything passed."
  (setf *pass-count* 0 *fail-count* 0 *local-fail* nil)
  (dolist (name (or names (reverse *order*)))
    (let ((*current-name* name))
      (run-one name)))
  (format t "~&~&==== ~a passed, ~a failed ====~%" *pass-count* *fail-count*)
  (finish-output)
  (zerop *fail-count*))

(defun run-tests () (run-all))
