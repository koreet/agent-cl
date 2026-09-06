;;;; src/dsl/schema-gen.lisp — DSL declarations <-> JSON Schema bridge.
;;;;
;;;; One user declaration drives (docs/architecture.md §6.6):
;;;;   1. the schema object used by the tool registry (validation + wire),
;;;;   2. the LLM-facing JSON Schema,
;;;;   3. structured-output schemas (defschema).
(in-package #:agent-cl.dsl)

(defvar *schemas* (make-hash-table :test 'equal)
  "Named schemas registered by defschema.")

;;; ---------------------------------------------------------------------------
;;; parameter declaration -> schema
;;; ---------------------------------------------------------------------------

(defun spec-of (name type opts)
  "Build one property spec plist from a declaration's tail options.
  OPTS may carry :description :enum :required :items <decl> :properties <decls>."
  (let ((spec (list :type type)))
    (let ((d (getf opts :description)))
      (when d (setf spec (append spec (list :description d)))))
    (let ((e (getf opts :enum)))
      (when e (setf spec (append spec (list :enum (copy-list e))))))
    (let ((items (getf opts :items)))
      (when items
        (setf spec (append spec (list :items (decl->prop items))))))
    (let ((props (getf opts :properties)))
      (when props
        (setf spec (append spec (list :properties (mapcar #'decl->prop props))))))
    spec))

(defun decl-name->string (name)
  (if (stringp name) name (string-downcase (symbol-name name))))

(defun decl->prop (decl)
  "DECL: (name type &key description enum required items properties) -> (name . spec)."
  (destructuring-bind (name type &rest opts) decl
    (cons (decl-name->string name) (spec-of name type opts))))

(defun dsl-params->schema (params)
  "PARAMS: list of DECL forms. Returns a :object schema."
  (let ((props nil)
        (required nil))
    (dolist (decl params)
      (destructuring-bind (name type &rest opts) decl
        (declare (ignore type))
        (push (decl->prop decl) props)
        (when (getf opts :required)
          (push (decl-name->string name) required))))
    (agent-cl.schema:make-schema
     :kind :object
     :properties (nreverse props)
     :required (nreverse required))))

(defun dsl-tool-schema (params)
  "Alias used by defdsl-tool expansion."
  (dsl-params->schema params))

(defun schema->json-schema (schema)
  "SCHEMA object -> LLM-facing JSON Schema hash."
  (agent-cl.schema:schema->json schema))

;;; ---------------------------------------------------------------------------
;;; defschema declarations: (:object (...) ...) / (:array items-decl)
;;; ---------------------------------------------------------------------------

(defun parse-schema-decl (decl)
  "DECL: (:object (prop-decl ...) ...) | (:array item-decl) | (:string | :number ...).
  Returns a schema object."
  (let ((kind (first decl)))
    (case kind
      (:object
       (let* ((body (rest decl))
              (props (mapcar #'decl->prop body))
              (required (loop for p in body
                              when (getf (cddr p) :required)
                                collect (decl-name->string (first p)))))
         (agent-cl.schema:make-schema
          :kind :object
          :properties props
          :required required)))
      (:array
       (agent-cl.schema:make-schema
        :kind :array
        :items (decl->prop (second decl))))
      (:string (agent-cl.schema:make-schema :kind :string))
      (:number (agent-cl.schema:make-schema :kind :number))
      (:boolean (agent-cl.schema:make-schema :kind :boolean))
      (t (error "parse-schema-decl: unsupported declaration ~s" decl)))))

(defun register-schema (name schema)
  (setf (gethash (decl-name->string name) *schemas*) schema)
  schema)

(defun find-schema (name)
  (gethash (decl-name->string name) *schemas*))
