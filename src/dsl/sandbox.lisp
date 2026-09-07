;;;; src/dsl/sandbox.lisp — safe evaluation of user/model-provided DSL scripts.
;;;;
;;;; Decision D2: dynamic execution is OFF by default. The interpreter is
;;;; delivered but *dsl-execution-mode* is :off, so dsl-eval-safe refuses unless
;;;; the caller opts in with WITH-DSL-SANDBOX (explicit :mode and whitelist).
;;;;
;;;; Security model (docs/architecture.md §6.5): we never EVAL user forms. A
;;;; tiny AST walker interprets only forms whose head symbol is on an explicit
;;;; whitelist; everything else (including any function that can reach host
;;;; I/O, eval, read, shell, files, processes) is denied. Steps and result size
;;;; are capped. Whitelisted operators are pure, side-effect-free functions.
(in-package #:agent-cl.dsl)

(defvar *dsl-execution-mode* :off) ; :off | :interpreter
(defvar *dsl-command-whitelist*
  '(+ - * / mod rem 1+ 1- abs min max floor ceiling round
    = /= < > <= >=
    list cons car cdr cadr caddr cddr append reverse length nth elt
    first second third rest butlast last
    string string-downcase string-upcase string-capitalize
    concatenate subseq symbol-name make-string))
(defvar *dsl-max-steps* 500)
(defvar *dsl-max-result-chars* 2000)

(defparameter *dsl-blacklist-names*
  '("EVAL" "APPLY" "FUNCALL" "SYMBOL-FUNCTION" "FDEFINITION" "MACROEXPAND"
    "READ" "READ-FROM-STRING" "LOAD" "COMPILE" "SHELL"
    "OPEN" "WITH-OPEN-FILE" "DELETE-FILE" "RENAME-FILE" "PROBE-FILE"
    "RUN-PROGRAM"))

(defvar *dsl-steps* 0)

(defun sandbox-mode-enabled-p ()
  (member *dsl-execution-mode* '(:interpreter :strict)))

(defun dsl-denied (form)
  (error 'agent-cl.core:dsl-error :kind :denied
         :message (format nil "sandbox denied form ~s (not on whitelist)" form)))

(defun dsl-disabled ()
  (error 'agent-cl.core:dsl-error :kind :disabled
         :message "dynamic DSL execution is disabled (decision D2); enable with with-dsl-sandbox"))

(defun name-in (sym names)
  (member (symbol-name sym) names :test #'string-equal))

(defun allowed-symbol-p (sym)
  "Callable only when its name is on the explicit whitelist (any package; the
  name is then resolved package-agnostically, see RESOLVE-FN). Everything else
  is denied: the whitelist is the single gate, so no CL function outside it —
  sleep/read-line/print/symbol-value/directory/… — is ever reachable, which is
  what the file header promises."
  (and (not (name-in sym *dsl-blacklist-names*))
       (not (macro-function sym))
       (not (special-operator-p sym))
       (name-in sym (mapcar #'symbol-name *dsl-command-whitelist*))))

(defun resolve-fn (sym)
  "Resolve SYM to a function object, falling back to the CL symbol of the
  same name (whitelist names are package-agnostic)."
  (or (and (fboundp sym) (symbol-function sym))
      (let ((cl-sym (find-symbol (symbol-name sym) :cl)))
        (and cl-sym (fboundp cl-sym) (symbol-function cl-sym)))))

(defun interp (form)
  (when (> (incf *dsl-steps*) *dsl-max-steps*)
    (error 'agent-cl.core:dsl-error :kind :step-limit
           :message (format nil "dsl step limit (~a) exceeded" *dsl-max-steps*)))
  (cond
    ((null form) nil)
    ((eq form t) t)
    ((or (numberp form) (stringp form) (characterp form)) form)
    ((symbolp form)
     ;; bare symbols only make sense as constants — deny everything else
     (dsl-denied form))
    ((atom form) form)
    ((eq (car form) 'quote) (second form))
    ((not (symbolp (car form))) (dsl-denied form))
    (t (let ((op (car form)))
         (cond
           ((eq op 'if)
            (if (interp (second form))
                (interp (third form))
                (interp (fourth form))))
           ((member op '(progn)) ; harmless sequencing
            (let ((result nil))
              (dolist (sub (rest form))
                (setf result (interp sub)))
              result))
           ((allowed-symbol-p op)
            (let ((fn (resolve-fn op)))
              (unless fn (dsl-denied form))
              (apply fn (mapcar #'interp (rest form)))))
           (t (dsl-denied form)))))))

(defun dsl-eval-safe (form)
  "Evaluate FORM under the current sandbox policy. Returns a string rendering
  of the result (bounded). Signals dsl-error when disabled or denied."
  (unless (sandbox-mode-enabled-p)
    (dsl-disabled))
  (let ((*dsl-steps* 0)
        (result (interp form)))
    (let ((text (etypecase result
                  (string result)
                  (number (princ-to-string result))
                  (symbol (princ-to-string result))
                  (list (prin1-to-string result))
                  (null "nil")
                  (t (princ-to-string result)))))
      (when (> (length text) *dsl-max-result-chars*)
        (setf text (subseq text 0 *dsl-max-result-chars*)))
      text)))

(defmacro with-dsl-sandbox (options &body body)
  "Enable the interpreter for BODY under an explicit policy.
    (with-dsl-sandbox (:mode :interpreter :max-steps 100) ...)
  Whitelist defaults to the safe pure-function list; caps default to globals."
  (let ((mode (or (getf options :mode) :interpreter))
        (wl (getf options :whitelist))
        (ms (getf options :max-steps))
        (mrc (getf options :max-result-chars)))
    `(let ((agent-cl.dsl:*dsl-execution-mode* ,mode)
           (agent-cl.dsl:*dsl-command-whitelist*
            (or ,wl agent-cl.dsl:*dsl-command-whitelist*))
           (agent-cl.dsl:*dsl-max-steps*
            (or ,ms agent-cl.dsl:*dsl-max-steps*))
           (agent-cl.dsl:*dsl-max-result-chars*
            (or ,mrc agent-cl.dsl:*dsl-max-result-chars*)))
       ,@body)))
