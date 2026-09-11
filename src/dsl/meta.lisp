;;;; src/dsl/meta.lisp — declaration metadata + reflection layer (plan §B1).
;;;;
;;;; Every DSL declaration (goal / principle / audit / ...) registers a
;;;; DSL-DECLARATION metadata object here. This is the common base new macros
;;;; build on, and the thing DESCRIBE-* read (reflection is *for the agent*;
;;;; the macro surface is for humans). It mirrors the existing *SCHEMAS*
;;;; registry in schema-gen.lisp, just generalized over a class instead of a
;;;; raw schema, and adds symbol-reference capture for a future dependency
;;;; graph (we COLLECT refs now, we do not build the graph yet — plan §C).
(in-package #:agent-cl.dsl)

(defclass dsl-declaration ()
  ((name    :initarg :name    :accessor decl-name)          ; symbol
   (kind    :initarg :kind    :accessor decl-kind)          ; :goal | :principle | :audit ...
   (spec    :initarg :spec    :initform nil :accessor decl-spec)   ; plist
   (refs    :initarg :refs    :initform nil :accessor decl-refs)   ; list of symbols
   (source  :initarg :source  :initform nil :accessor decl-source) ; file / nil
   (version :initarg :version :initform 1   :accessor decl-version)))

(defvar *declarations* (make-hash-table :test 'equal)
  "name-string -> dsl-declaration. Equal-hash like *SCHEMAS* so string names work.")

(defun decl-key (name kind)
  "Declarations are keyed by KIND + NAME so a :goal and an :audit may share a
  name without clobbering each other."
  (format nil "~(~a~)/~(~a~)" kind name))

(defun name-string (name)
  (if (stringp name) name (string-downcase (symbol-name name))))

(defun make-declaration (name kind &key spec refs source (version 1))
  (make-instance 'dsl-declaration
                 :name (if (symbolp name) name (intern (string-upcase (string name))))
                 :kind kind :spec spec :refs refs :source source :version version))

(defun register-declaration (decl)
  "Register DECL (a DSL-DECLARATION). Returns it. Re-registration replaces."
  (setf (gethash (decl-key (decl-name decl) (decl-kind decl)) *declarations*) decl)
  decl)

(defun find-declaration (name kind)
  "Return the declaration named NAME of KIND, or NIL."
  (gethash (decl-key name kind) *declarations*))

(defun unregister-declaration (name kind)
  (remhash (decl-key name kind) *declarations*))

(defun all-declarations (&optional kind)
  "All declarations (optionally of one KIND), ordered by name."
  (let ((out (loop for d being the hash-values of *declarations*
                   when (or (null kind) (eq (decl-kind d) kind))
                     collect d)))
    (sort out #'string< :key (lambda (d) (name-string (decl-name d))))))

(defun describe-declaration (name &optional kind)
  "Human-readable one-paragraph summary (the 'structure' readable projection).
  When KIND is NIL and several kinds share NAME, describe the first by kind order."
  (let ((ds (if kind
                (list (find-declaration name kind))
                (loop for d being the hash-values of *declarations*
                      when (string= (name-string (decl-name d)) (name-string name))
                        collect d))))
    (setf ds (remove nil ds))
    (if (null ds)
        (format nil "(no declaration ~a~@[ kind ~a~])" name kind)
        (with-output-to-string (o)
          (dolist (d ds)
            (format o "~&~a ~a~%  refs: ~{~a~^, ~}~@[~%  spec: ~s~]~%"
                    (string-upcase (symbol-name (decl-kind d)))
                    (decl-name d)
                    (decl-refs d)
                    (decl-spec d)))))))
