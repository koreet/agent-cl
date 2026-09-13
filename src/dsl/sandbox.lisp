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
;; Step counting alone does not bound a single form: (make-string 100000000) or
;; (append huge huge) is ONE step. CAP the arguments so a whitelisted function
;; cannot be used to allocate unbounded memory or spin for minutes.
(defvar *dsl-max-integer* 1000000000000
  "Largest integer magnitude accepted as an operator argument (1e12).")
(defvar *dsl-max-sequence* 100000
  "Largest total element count (list elements / string characters) of all
  arguments passed to one operator call.")

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
  "Resolve a whitelisted name to its function object.

  Resolution goes through the CL package ONLY. Preferring the caller-visible
  binding meant a host package that shadows a whitelisted name (say EVIL::LIST)
  reached its own function through the sandbox — reproduced: the shadowing
  function ran and wrote a file. Every whitelist entry is a CL function, so there
  is no legitimate reason to consult the caller's binding."
  (let ((cl-sym (find-symbol (symbol-name sym) :cl)))
    (and cl-sym (fboundp cl-sym) (symbol-function cl-sym))))

(defun dsl-value-size (value limit)
  "Approximate element count of VALUE (list elements, string/vector length).

  Returns LIMIT+1 as soon as VALUE is known to exceed LIMIT, so a caller can
  decide 'too big' with a single > comparison — the previous version SATURATED at
  LIMIT, which made the argument cap impossible to trigger (an argument of exactly
  the limit measured as the limit, never more).

  A CIRCULAR list is rejected outright: walking it never terminates, and
  (dsl-eval-safe '(length (quote #1=(a . #1#)))) hung the whole process (>120 s,
  not even SB-EXT:WITH-TIMEOUT could break it). Floyd's tortoise/hare detects a
  cycle in O(1) space."
  (cond
    ((or (stringp value) (vectorp value)) (min (length value) (1+ limit)))
    ((consp value)
     (let ((n 0) (tail value) (hare value))
       (loop while (and (consp tail) (<= n limit))
             do (incf n)
                (setf tail (cdr tail))
                (when (evenp n) (setf hare (cdr hare)))
                (when (eq tail hare)
                  (error 'agent-cl.core:dsl-error :kind :limit
                         :message "dsl 拒绝环形/循环结构参数（拒绝遍历）")))
       ;; >LIMIT and still conses left => report LIMIT+1 (definitely too big);
       ;; otherwise N is the real length (an improper tail is not counted)
       (if (and (> n limit) (consp tail)) (1+ limit) n)))
    (t 1)))

(defvar *dsl-size-argument-ops*
  '(("MAKE-STRING" . 0) ("MAKE-LIST" . 0) ("MAKE-ARRAY" . 0) ("MAKE-SEQUENCE" . 1))
  "Operators whose Nth argument is the SIZE of the object they allocate. Their
  argument is a small integer, so the ordinary argument-size check cannot see the
  result: (make-string 100000000) is one step, one tiny argument, and 100MB of
  memory. Checked against *DSL-MAX-SEQUENCE* before the call.")

(defun check-op-limits (op args)
  "Refuse OP when its arguments are big enough to turn one whitelisted step into
  an unbounded allocation. Signals dsl-error :limit."
  (let ((total 0)
        (op-name (and (symbolp op) (symbol-name op))))
    (dolist (a args)
      (when (and (integerp a) (> (abs a) *dsl-max-integer*))
        (error 'agent-cl.core:dsl-error :kind :limit
               :message (format nil "dsl 拒绝超大整数参数 ~a（上限 ~a）"
                                a *dsl-max-integer*)))
      (incf total (dsl-value-size a (max 0 (- *dsl-max-sequence* total))))
      (when (> total *dsl-max-sequence*)
        (error 'agent-cl.core:dsl-error :kind :limit
               :message (format nil "dsl 参数总量超过 ~a（~a）"
                                *dsl-max-sequence* op))))
    (let ((idx (cdr (assoc op-name *dsl-size-argument-ops* :test #'string-equal))))
      (when idx
        (let ((n (nth idx args)))
          (when (and (integerp n) (> n *dsl-max-sequence*))
            (error 'agent-cl.core:dsl-error :kind :limit
                   :message (format nil "dsl 拒绝 ~a 分配 ~a （上限 ~a）"
                                    op-name n *dsl-max-sequence*)))))))
  t)

(defun interp (form)
  (when (> (incf *dsl-steps*) *dsl-max-steps*)
    (error 'agent-cl.core:dsl-error :kind :step-limit
           :message (format nil "dsl step limit (~a) exceeded" *dsl-max-steps*)))
  (cond
    ((null form) nil)
    ((eq form t) t)
    ((or (numberp form) (stringp form) (characterp form)) form)
    ;; keywords are self-evaluating constants, so they are safe as arguments. They
    ;; used to be denied as 'bare symbols', which made every whitelisted function
    ;; with keyword parameters unusable: (make-string 3 :initial-element #\\x)
    ;; was rejected and make-string could only produce NUL-filled strings.
    ((keywordp form) form)
    ((symbolp form)
     ;; other bare symbols only make sense as constants — deny everything else
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
            (let* ((fn (resolve-fn op))
                   (args (mapcar #'interp (rest form))))
              (unless fn (dsl-denied form))
              (check-op-limits op args)
              (apply fn args)))
           (t (dsl-denied form)))))))

(defun dsl-eval-safe (form)
  "Evaluate FORM under the current sandbox policy. Returns a string rendering
  of the result (bounded). Signals dsl-error when disabled or denied."
  (unless (sandbox-mode-enabled-p)
    (dsl-disabled))
  ;; LET*, not LET: with parallel bindings RESULT was computed while *DSL-STEPS*
  ;; still held the caller's value, so the per-call step counter was never
  ;; actually reset (the limit leaked across calls) — the reset must bind first.
  (let* ((*dsl-steps* 0)
         (result (interp form))
         (text (etypecase result
                 (null "nil")
                 (string result)
                 (number (princ-to-string result))
                 (symbol (princ-to-string result))
                 (list (prin1-to-string result))
                 (t (princ-to-string result)))))
    (when (> (length text) *dsl-max-result-chars*)
      (setf text (subseq text 0 *dsl-max-result-chars*)))
    text))

(defmacro with-dsl-sandbox (options &body body)
  "Enable the interpreter for BODY under an explicit policy.
    (with-dsl-sandbox (:mode :interpreter :max-steps 100) ...)
  Whitelist defaults to the safe pure-function list; caps default to globals."
  (let ((mode (or (getf options :mode) :interpreter))
        (wl (getf options :whitelist))
        (ms (getf options :max-steps))
        (mrc (getf options :max-result-chars))
        (mint (getf options :max-integer))
        (mseq (getf options :max-sequence)))
    `(let ((agent-cl.dsl:*dsl-execution-mode* ,mode)
           (agent-cl.dsl:*dsl-command-whitelist*
            (or ,wl agent-cl.dsl:*dsl-command-whitelist*))
           (agent-cl.dsl:*dsl-max-steps*
            (or ,ms agent-cl.dsl:*dsl-max-steps*))
           (agent-cl.dsl:*dsl-max-result-chars*
            (or ,mrc agent-cl.dsl:*dsl-max-result-chars*))
           (agent-cl.dsl:*dsl-max-integer*
            (or ,mint agent-cl.dsl:*dsl-max-integer*))
           (agent-cl.dsl:*dsl-max-sequence*
            (or ,mseq agent-cl.dsl:*dsl-max-sequence*)))
       ,@body)))
