;;;; src/dsl/macros.lisp — the DSL layer (docs/architecture.md §6).
;;;;
;;;; L1 agent-instruction DSL:   defagent / defpolicy / defguard / defschema
;;;; L2 domain-tool DSL:         defdsl-tool / defcommand / defdsl-package
;;;;
;;;; These macros are the *user surface*: they expand into ordinary calls of
;;;; the tools/registry and loop/engine APIs, so every capability is usable
;;;; without the DSL too. Declarations are the single source for the schema,
;;;; the wire description and the validator (§6.6).
(in-package #:agent-cl.dsl)

(defun tool-name-string (name)
  (if (stringp name) name (string-downcase (symbol-name name))))

;;; ---------------------------------------------------------------------------
;;; L2: domain tool DSL
;;; ---------------------------------------------------------------------------

(defmacro defdsl-tool (name doc params &body body)
  "Define a tool the model may call.
    (defdsl-tool \"calc.add\" \"Add two numbers\"
        ((a :number :description \"first\" :required t)
         (b :number :description \"second\" :required t))
      (format nil \"~a\" (+ (getf args :A) (getf args :B))))
  BODY runs with ARGS (keyword-keyed plist of the JSON arguments the model
  sent) and CTX bound. Return (values payload :ok) or (values \"msg\" :error)."
  (let ((tool-name (tool-name-string name)))
    (let ((args-sym (intern "ARGS" *package*))
          (ctx-sym (intern "CTX" *package*)))
      `(agent-cl.tools:register-tool
        (agent-cl.tools:make-tool
         ,tool-name
         (lambda (,args-sym ,ctx-sym) ,@body)
         :description ,doc
         :parameters (dsl-params->schema ',params))))))

(defmacro defcommand (name doc params &body body)
  "Alias of DEFDSL-TOOL for command-style DSLs."
  `(defdsl-tool ,name ,doc ,params ,@body))

(defmacro defdsl-package (name &body body)
  "Documentation/grouping form: runs BODY (usually many DEFDSL-TOOL forms).
  In a real namespaced deployment this could generate a package; for now the
  '.' prefix in tool names plays that role."
  (declare (ignore name))
  `(progn ,@body))

;;; ---------------------------------------------------------------------------
;;; structured output schema DSL
;;; ---------------------------------------------------------------------------

(defmacro defschema (name decl)
  "Register a named schema declaration.
    (defschema invoice (:object (amount :number :required t)
                               (memo  :string)))"
  `(register-schema ',name (parse-schema-decl ',decl)))

;;; ---------------------------------------------------------------------------
;;; L1: agent instruction DSL
;;; ---------------------------------------------------------------------------

(defmacro defpolicy (name options)
  "Define a named policy for reuse across agents.
    (defpolicy chatty (:max-steps 30 :temperature 0.7 :parallel-tools t))"
  `(defparameter ,name (agent-cl.loop:make-policy ,@options)))

(defmacro defguard (name (agent-var) &body body)
  "Define and register an extra guard rule. BODY receives the agent and
  returns a reason string (guard trips) or NIL (passes).
    (defguard few-steps (a) (when (> (agent-steps-count a) 5) \"too many\"))"
  `(progn
     (defun ,name (,agent-var) ,@body)
     (agent-cl.loop:register-guard ,(tool-name-string name) #',name)
     ',name))

(defun build-agent-from-options (options)
  "Runtime half of defagent. OPTIONS is the keyword plist the user wrote."
  (let* ((transport (getf options :transport))
         (base-url (getf options :base-url))
         (api-key (getf options :api-key))
         (tools (getf options :tools))
         (policy (getf options :policy))
         (model (getf options :model))
         (system (getf options :system))
         (messages (getf options :messages))
         (memory (getf options :memory))
         (guard (getf options :guard))
         (max-steps (getf options :max-steps)))
    (let ((tr (or transport
                  (and (or base-url api-key)
                       (agent-cl.llm:make-http-transport
                        :base-url base-url :api-key api-key))
                  (agent-cl.llm:make-http-transport))))
      (let ((normalized-tools
              (when tools
                (mapcar (lambda (t1)
                          (cond ((stringp t1) t1)
                                ((symbolp t1) (tool-name-string t1))
                                (t t1)))
                        tools))))
        (agent-cl.loop:make-agent
         :transport tr
         :model model
         :tools (if normalized-tools normalized-tools :all)
         :policy (cond ((null policy) nil)
                       ((typep policy 'agent-cl.loop:policy) policy)
                       (t (apply #'agent-cl.loop:make-policy policy)))
         :messages messages
         :memory memory
         :system system
         :guard guard
         :max-steps max-steps)))))

(defun literal-tool-list-p (form)
  "True when FORM is a literal list of tool names (symbols/strings) — data,
  not an expression to evaluate."
  (and (listp form)
       (every (lambda (x) (or (symbolp x) (stringp x))) form)))

(defun expand-agent-options (options)
  "Walk the option plist so :tools literal name lists become quoted data."
  (let (out)
    (loop for (k v) on options by #'cddr
          do (setf out (list* k
                              (if (and (eq k :tools) (literal-tool-list-p v))
                                  (list 'quote v)
                                  v)
                              out)))
    (nreverse out)))

(defmacro defagent (name options)
  "Define a named agent from a keyword option list.
    (defagent my-bot
      (:model my-model :base-url my-base-url
       :system my-system-text
       :tools (shell.run file.read time.now)
       :policy chatty))
  Tool-name lists are taken literally; :policy refers to a defpolicy symbol;
  any other value is an expression evaluated when the definition loads."
  (let ((pairs nil))
    (loop for (k v) on options by #'cddr
          do (setf pairs (append pairs
                                  (list k
                                        (if (and (eq k :tools)
                                                 (literal-tool-list-p v))
                                            (list 'quote v)
                                            v)))))
    `(defparameter ,name (build-agent-from-options (list ,@pairs)))))
