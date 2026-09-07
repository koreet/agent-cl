;;;; src/schema/json-schema.lisp — JSON Schema builder + validator.
;;;;
;;;; Our schema mini-DSL (docs/architecture.md §5.6): a SCHEMA describes a JSON
;;;; object; each property is a plist
;;;;   (:type :string|:number|:integer|:boolean|:object|:array
;;;;    :description "..." :enum (...)
;;;;    :properties (sub-prop specs...) :items <spec-plist> :required (...))
;;;; One declaration drives three outputs:
;;;;   1. schema->json / schema->json-string — the LLM-facing JSON Schema;
;;;;   2. validate-json — local validation of model/tool payloads;
;;;;   3. property lookups for docs/coercion.
(in-package #:agent-cl.schema)

(defclass schema ()
  ((name        :initarg :name        :initform nil :accessor schema-name)
   (kind        :initarg :kind        :initform :object :accessor schema-kind)
   (description :initarg :description :initform nil :accessor schema-description)
   ;; properties: alist (name . spec-plist)
   (properties  :initarg :properties  :initform nil :accessor schema-properties)
   ;; required: list of property names (strings)
   (required    :initarg :required    :initform nil :accessor schema-required)
   ;; for kind :array: spec of the element
   (items       :initarg :items       :initform nil :accessor schema-items)))

(defun normalize-properties (props)
  "Accept any of:
     (:name spec :name2 spec2 ...)           plist of (name spec) pairs,
     ((\"x\" . spec) (\"y\" . spec))           dotted alist,
     ((\"x\" spec) (\"y\" spec))               two-element lists,
  and normalize to a dotted alist with string keys."
  (cond ((null props) nil)
        ((keywordp (first props))
         (loop for (k v) on props by #'cddr
               collect (cons (if (stringp k) k (string-downcase (symbol-name k))) v)))
        ((consp (first props))
         (mapcar (lambda (e)
                   (let ((k (car e)))
                     (cons (if (stringp k) k (string-downcase (symbol-name k)))
                           ;; two-element-list form ("x" spec) -> dotted
                           (if (and (cdr e) (not (cddr e)) (listp (cadr e)))
                               (cadr e)
                               (cdr e)))))
                 props))
        (t (error "normalize-properties: unsupported properties shape ~s" props))))

(defun make-schema (&key name kind description properties required items)
  (make-instance 'schema
                 :name name
                 :kind (or kind :object)
                 :description description
                 :properties (normalize-properties properties)
                 :required (mapcar (lambda (r) (if (stringp r) r
                                                   (string-downcase (symbol-name r))))
                                   required)
                 :items items))

;;; ---------------------------------------------------------------------------
;;; Lisp schema -> LLM-facing JSON Schema (hash-tables ready for yason)
;;; ---------------------------------------------------------------------------

(defun type->json (type)
  (ecase type
    (:string "string") (:number "number") (:integer "integer")
    (:boolean "boolean") (:object "object") (:array "array")))

(defun spec->json (spec)
  "Property spec plist -> JSON Schema hash (for a property node)."
  (let ((h (make-hash-table :test 'equal)))
    (let ((desc (getf spec :description)))
      (when desc (setf (gethash "description" h) desc)))
    (setf (gethash "type" h) (type->json (or (getf spec :type) :string)))
    (let ((enum (getf spec :enum)))
      (when enum (setf (gethash "enum" h) (copy-list enum))))
    (let ((items (getf spec :items)))
      (when items (setf (gethash "items" h) (spec->json items))))
    (let ((props (getf spec :properties)))
      (when props
        (let ((ph (make-hash-table :test 'equal)))
          (loop for (pname . pspec) in (normalize-properties props)
                do (setf (gethash pname ph) (spec->json pspec)))
          (setf (gethash "properties" h) ph))))
    (let ((req (getf spec :required)))
      (when req
        (setf (gethash "required" h)
              (mapcar (lambda (r) (if (stringp r) r
                                      (string-downcase (symbol-name r))))
                      req))))
    h))

(defun schema->json (schema)
  "SCHEMA -> JSON Schema hash for the wire (an object schema)."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "type" h) (type->json (schema-kind schema)))
    (let ((desc (schema-description schema)))
      (when desc (setf (gethash "description" h) desc)))
    (case (schema-kind schema)
      (:object
       (let ((ph (make-hash-table :test 'equal)))
         (dolist (prop (schema-properties schema))
           (setf (gethash (car prop) ph) (spec->json (cdr prop))))
         (setf (gethash "properties" h) ph))
       (let ((req (schema-required schema)))
         (when req (setf (gethash "required" h) (copy-list req)))))
      (:array
       (let ((items (schema-items schema)))
         (when items
           (setf (gethash "items" h)
                 (if (typep items 'schema)
                     (schema->json items)
                     (spec->json items)))))))
    h))

(defun schema->json-string (schema)
  (agent-cl.core:json-encode (schema->json schema)))

;;; ---------------------------------------------------------------------------
;;; validation of decoded JSON (plist structures) against a schema
;;; ---------------------------------------------------------------------------

(defun norm-property-key (name)
  "Normalize a schema property name (string or symbol) to the canonical
  dotted-keyword form used by decoded JSON plists. JSON snake_case keys are
  decoded to kebab-case keywords by core/json (e.g. \"max_steps\" -> :MAX-STEPS),
  so schema property names must follow the same rule or validation silently
  misses underscores names (required always reported missing, type checks
  skipped)."
  (let* ((s (if (symbolp name) (symbol-name name) name))
         (kebab (substitute #\- #\_ s)))
    (intern (string-upcase kebab) :keyword)))

(defun prop-key (name)
  "Schema property name (usually a string) -> expected decoded plist keyword."
  (norm-property-key name))

(defun find-prop (schema name)
  (assoc (if (symbolp name) (symbol-name name) name)
         (schema-properties schema)
         :test (lambda (a b) (string-equal (norm-property-key a)
                                           (norm-property-key b)))))

(defun spec->schema (spec)
  "Promote a property spec plist to a schema for validation (arrays/objects)."
  (make-schema :kind (or (getf spec :type) :string)
               :properties (getf spec :properties)
               :required (getf spec :required)
               :items (getf spec :items)))

(defun read-number (string)
  (let ((*read-default-float-format* 'double-float))
    (read-from-string string nil nil)))

(defmethod validate-value (spec value path problems)
  "Validate VALUE (already decoded to plists/keywords) against property spec."
  (let ((type (or (getf spec :type) :string)))
    (cond
      ((eq type :string)
       (unless (or (null value) (stringp value))
         (push (format nil "~a: expected string, got ~s" path value) problems)))
      ((eq type :number)
       (unless (or (null value) (numberp value))
         (push (format nil "~a: expected number, got ~s" path value) problems)))
      ((eq type :integer)
       (unless (or (null value) (and (numberp value) (integerp value)))
         (push (format nil "~a: expected integer, got ~s" path value) problems)))
      ((eq type :boolean)
       (unless (member value '(t nil))
         (push (format nil "~a: expected boolean, got ~s" path value) problems)))
      ((eq type :array)
       (unless (listp value)
         (push (format nil "~a: expected array, got ~s" path value) problems)))
      ((eq type :object)
       (unless (or (null value) (listp value))
         (push (format nil "~a: expected object, got ~s" path value) problems))))
    (let ((enum (getf spec :enum)))
      (when (and enum value)
        (unless (member value enum :test #'equal)
          (push (format nil "~a: ~s not in enum ~s" path value enum) problems))))
    (let ((props (getf spec :properties)))
      (when (and props (listp value))
        (let ((sub (make-schema :kind :object :properties props
                                :required (getf spec :required))))
          (setf problems (validate-object sub value path problems)))))
    problems))

(defmethod validate-object ((schema schema) value path problems)
  "Validate decoded object (plist with keyword keys) against SCHEMA."
  (unless (listp value)
    (push (format nil "~a: expected object, got ~s" path value) problems)
    (return-from validate-object problems))
  ;; required presence
  (dolist (r (schema-required schema))
    (unless (member (prop-key r) value :test #'eq)
      (push (format nil "~a: missing required property ~a" path r) problems)))
  ;; per-property checks
  (loop for (k v) on value by #'cddr
        for prop = (find-prop schema
                              (if (keywordp k) (string-downcase (symbol-name k)) k))
        when prop
          do (setf problems
                   (validate-value (cdr prop) v
                                   (format nil "~a.~a" path (car prop))
                                   problems)))
  problems)

(defun validate-json (schema decoded)
  "Validate DECODED (plist structure from tool-call-arguments-plist or
  decode-to-plist) against SCHEMA. Returns a list of problem strings (NIL ok)."
  (ecase (schema-kind schema)
    (:object (nreverse (validate-object schema decoded "" nil)))
    (:array
     (if (listp decoded)
         (loop for item in decoded
               for i from 0
               append (validate-value (schema-items schema) item
                                      (format nil "[~a]" i) nil))
         (list (format nil "expected array, got ~s" decoded))))))

(defun json-valid-p (schema decoded)
  (null (validate-json schema decoded)))

(defun schema-property (schema name)
  (cdr (find-prop schema name)))

(defun coerce-schema-types (schema decoded)
  "Best-effort type coercion of DECODED against SCHEMA (strings->numbers etc).
  Implemented for scalars; nested coercion applies for objects."
  (labels ((coerce-value (spec v)
             (let ((type (or (getf spec :type) :string)))
               (cond ((and (eq type :number) (stringp v))
                      (handler-case (read-number v) (error () v)))
                     ((and (eq type :integer) (stringp v))
                      (handler-case (parse-integer v) (error () v)))
                     (t v)))))
    (if (and (eq (schema-kind schema) :object) (listp decoded))
        (loop for (k v) on decoded by #'cddr
              for prop = (find-prop schema
                                    (if (keywordp k)
                                        (string-downcase (symbol-name k)) k))
              append (list k (if prop (coerce-value (cdr prop) v) v)))
        decoded)))
