;;;; src/tools/registry.lisp — tool registry (name -> tool).
;;;;
;;;; A tool is a callable object the model may invoke (docs/architecture.md
;;;; §6.1): name, description (what the model sees), parameters (schema), the
;;;; Lisp function and a danger flag. FN receives (args-plist ctx) where
;;;; args-plist uses keyword keys derived from the JSON the model sent; it
;;;; returns (values payload status) — payload is a string or a plist/hash
;;;; (converted to JSON text for the tool-result message), status :ok | :error.
(in-package #:agent-cl.tools)

(defun sanitize-tool-name (name)
  "Providers restrict function names to [a-zA-Z0-9_-]. Keep the human-facing
  DSL names (e.g. calendar.book) and map them to a safe wire name
  (calendar_book) only on the boundary."
  (map 'string (lambda (c)
                 (if (or (alphanumericp c) (char= c #\_) (char= c #\-))
                     c
                     #\_))
       name))

(defclass tool ()
  ((name        :initarg :name        :accessor tool-name)
   (wire-name   :initarg :wire-name   :accessor tool-wire-name)
   (description :initarg :description :initform "" :accessor tool-description)
   (parameters  :initarg :parameters  :initform nil :accessor tool-parameters)
   (fn          :initarg :fn          :accessor tool-fn)
   (dangerous-p :initarg :dangerous-p :initform nil :accessor tool-dangerous-p)))

(defun make-tool (name fn &key description parameters dangerous-p)
  (make-instance 'tool
                 :name name :fn fn
                 :wire-name (sanitize-tool-name name)
                 :description (or description "")
                 :parameters parameters
                 :dangerous-p dangerous-p))

;;; ---------------------------------------------------------------------------
;;; registry
;;; ---------------------------------------------------------------------------

(defvar *tool-registry* (make-hash-table :test 'equal)
  "Global tool registry: name string -> tool.")

(defun register-tool (tool &optional (registry *tool-registry*))
  (setf (gethash (tool-name tool) registry) tool)
  tool)

(defun unregister-tool (name &optional (registry *tool-registry*))
  (remhash name registry))

(defun find-tool (name &optional (registry *tool-registry*))
  "Find TOOL-NAME. Exact registry lookup first, then a wire-name match so
  model-supplied names (time_now) resolve to DSL tools (time.now)."
  (or (gethash name registry)
      (let ((wire (sanitize-tool-name name)))
        (loop for t1 being the hash-values of registry
              when (string= (tool-wire-name t1) wire)
                return t1))))

(defun list-tools (&optional (registry *tool-registry*))
  (loop for name being the hash-keys of registry collect name))

(defmacro with-tools ((&rest tool-names) &body body)
  "Temporarily replace the global registry with only TOOL-NAMES registered."
  `(let ((agent-cl.tools:*tool-registry*
           (let ((h (make-hash-table :test 'equal)))
             (dolist (n ',tool-names)
               (let ((t (find-tool n)))
                 (when t (setf (gethash n h) t))))
             h)))
     ,@body))

(defun payload->string (payload)
  "Normalize a tool result payload (string | object-plist | list | hash-table |
  number) to a string suitable for a tool-result message."
  (typecase payload
    (string payload)
    (hash-table (agent-cl.core:json-encode payload))
    (number (princ-to-string payload))
    (list (if (and (evenp (length payload)) (keywordp (first payload)))
              (agent-cl.core:encode-plist-object payload)
              (agent-cl.core:json-encode payload)))
    (t (princ-to-string payload))))

(defun call-tool (tool-name args-plist &optional ctx)
  "Invoke TOOL-NAME with decoded ARGS-PLIST. Returns (values content status)
  where status is :ok or :error and content is ready-to-send text."
  (let ((tool (find-tool tool-name)))
    (unless tool
      (return-from call-tool
        (values (format nil "unknown tool ~a" tool-name) :error)))
    (let ((schema (tool-parameters tool)))
      (when schema
        (let ((problems (agent-cl.schema:validate-json schema args-plist)))
          (when problems
            (return-from call-tool
              (values (format nil "参数校验失败: ~{~a~^; ~}" problems) :validation-error))))))
    (handler-case
        (multiple-value-bind (payload status)
            (funcall (tool-fn tool) args-plist ctx)
          (if (eq status :error)
              (values (payload->string payload) :error)
              (values (payload->string (or payload "")) :ok)))
      (agent-cl.core:tool-error (e)
        (values (format nil "tool error [~a]: ~a"
                        (agent-cl.core:tool-error-code e)
                        (agent-cl.core:agent-error-message e))
                :error))
      (error (e)
        (values (format nil "unexpected tool error: ~a" e) :error)))))

(defun tool-schema (tool)
  "TOOL -> wire entry hash-table:
    {:type function, :function {name description parameters JSON-Schema}}"
  (let ((outer (make-hash-table :test 'equal))
        (inner (make-hash-table :test 'equal)))
    (setf (gethash "type" outer) "function")
    (setf (gethash "name" inner) (tool-wire-name tool)
          (gethash "description" inner) (tool-description tool))
    (let ((params (tool-parameters tool)))
      (when params
        (setf (gethash "parameters" inner)
              (if (typep params 'agent-cl.schema:schema)
                  (agent-cl.schema:schema->json params)
                  params))))
    (setf (gethash "function" outer) inner)
    outer))
