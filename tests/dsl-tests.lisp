;;;; tests/dsl-tests.lisp — DSL layer tests (defdsl-tool / defagent / sandbox).
(in-package #:agent-cl.tests)

;;; ---------------------------------------------------------------------------
;;; L2: domain DSL tools
;;; ---------------------------------------------------------------------------

(defdsl-tool "dsl.add" "两数相加"
    ((a :number :description "加数" :required t)
     (b :number :description "被加数" :required t))
  (values (format nil "~a" (+ (getf args :A) (getf args :B))) :ok))

(defcommand "dsl.upper" "大写字符串"
    ((s :string :description "输入" :required t))
  (values (string-upcase (getf args :S)) :ok))

(deftest dsl-tools-registered
  (ok (find-tool "dsl.add"))
  (ok (find-tool "dsl.upper"))
  (let ((tool (find-tool "dsl.add")))
    (is-equal "dsl.add" (agent-cl.tools:tool-name tool))
    (multiple-value-bind (content status)
        (agent-cl.tools:call-tool "dsl.add" (list :A 20 :B 22))
      (is-equal :ok status)
      (is-equal "42" content))
    (multiple-value-bind (content status)
        (agent-cl.tools:call-tool "dsl.upper" (list :S "agent"))
      (is-equal :ok status)
      (is-equal "AGENT" content))))

(deftest dsl-tool-parameter-validation
  ;; missing required a -> validation error fed back, engine lets the model retry
  (multiple-value-bind (content status)
      (agent-cl.tools:call-tool "dsl.add" (list :B 1))
    (is-equal :validation-error status)
    (ok (search "参数校验失败" content))))

(deftest dsl-tool-end-to-end-via-engine
  (let* ((tr (make-mock-transport
              :script (list (script-reply
                             (reply-json "" (list (tc-json "c1" "dsl.add" "{\"a\":6,\"b\":7}"))))
                            (script-reply (reply-json "13" nil)))))
         (agent (make-agent :transport tr :tools '("dsl.add")
                            :policy (make-policy :max-steps 4)))
         (summary (run agent "6+7?")))
    (ok (done-p summary))
    (is-equal "13" (final-content summary))
    (is-equal 1 (turn-summary-tool-count summary))))

;;; ---------------------------------------------------------------------------
;;; defschema / defpolicy / defguard
;;; ---------------------------------------------------------------------------

(defschema dsl-invoice
  (:object (amount :number :description "金额" :required t)
           (memo  :string :description "备注")))

(deftest defschema-registers
  (let ((schema (agent-cl.dsl:find-schema "dsl-invoice")))
    (ok schema)
    ;; wire JSON Schema has properties amount/memo, required [amount]
    (let ((wire (json-decode (schema->json-string schema))))
      (ok (gethash "properties" wire))
      (is-equal '("amount") (gethash "required" wire)))
    ;; validator: valid and invalid payloads
    (let ((schema2 (agent-cl.dsl:find-schema "dsl-invoice")))
      (ok (json-valid-p schema2 (decode-to-plist "{\"amount\": 10.5}")))
      (ok (not (json-valid-p schema2 (decode-to-plist "{}")))))))

(defpolicy dsl-chatty (:max-steps 8 :temperature 0.5))

(deftest defpolicy-creates-policy
  (is-equal 8 (policy-max-steps dsl-chatty))
  (is-equal 0.5 (policy-temperature dsl-chatty)))

(defguard dsl-token-heavy (a)
  (when (> (agent-cl.loop:agent-usage-total a) 100)
    "token-heavy"))

(deftest defguard-registers-and-fires
  ;; rule registered: name present in extra guards
  (ok (assoc "dsl-token-heavy" agent-cl.loop:*extra-guards* :test #'string=))
  (let ((agent (make-agent :transport (make-mock-transport) :tools nil)))
    (ok (not (agent-cl.loop:check-extra-guards agent)))
    (setf (agent-cl.loop:agent-usage-total agent) 500)
    (is-equal "token-heavy" (agent-cl.loop:check-extra-guards agent))))

;;; ---------------------------------------------------------------------------
;;; defagent
;;; ---------------------------------------------------------------------------

(defagent dsl-bot
  (:system "DSL 测试机器人"
   :tools (dsl.add)
   :policy dsl-chatty))

(deftest defagent-builds-agent
  (ok (typep dsl-bot 'agent-cl.loop:agent))
  (is-equal "DSL 测试机器人" (agent-cl.loop:agent-system dsl-bot))
  (is-equal '("dsl.add") (agent-cl.loop:agent-tools dsl-bot))
  (is-equal 8 (policy-max-steps (agent-cl.loop:agent-policy dsl-bot))))

(deftest defagent-runs-with-mock-transport
  ;; swap the transport of dsl-bot for a deterministic mock and drive it
  (let* ((tr (make-mock-transport
              :script (list (script-reply
                             (reply-json "" (list (tc-json "c1" "dsl.add" "{\"a\":1,\"b\":2}"))))
                            (script-reply (reply-json "3" nil)))))
         (agent (make-agent :transport tr :tools '("dsl.add")
                            :policy (make-policy :max-steps 4)
                            :system (agent-cl.loop:agent-system dsl-bot)))
         (summary (run agent "1+2?")))
    (ok (done-p summary))
    (is-equal "3" (final-content summary))))

;;; ---------------------------------------------------------------------------
;;; sandbox (decision D2: off by default)
;;; ---------------------------------------------------------------------------

(deftest dsl-sandbox-disabled-by-default
  (signals-error agent-cl.core:dsl-error
    (dsl-eval-safe '(+ 1 2))))

(deftest dsl-sandbox-arithmetic-when-enabled
  (is-equal "3" (with-dsl-sandbox ()
                  (dsl-eval-safe '(+ 1 2))))
  (is-equal "6" (with-dsl-sandbox ()
                  (dsl-eval-safe '(* 2 3))))
  (is-equal "hello world"
            (with-dsl-sandbox ()
              (dsl-eval-safe '(concatenate 'string "hello" " world")))))

(deftest dsl-sandbox-rejects-dangerous-forms
  (signals-error agent-cl.core:dsl-error
    (with-dsl-sandbox ()
      (dsl-eval-safe '(shell "rm -rf /"))))
  (signals-error agent-cl.core:dsl-error
    (with-dsl-sandbox ()
      (dsl-eval-safe '(eval '(+ 1 2)))))
  (signals-error agent-cl.core:dsl-error
    (with-dsl-sandbox ()
      (dsl-eval-safe '(open "/etc/passwd")))))

(deftest dsl-sandbox-step-limit
  (signals-error agent-cl.core:dsl-error
    (with-dsl-sandbox (:max-steps 10)
      ;; nested list building loops many steps
      (dsl-eval-safe '(list (list (list (list 1 2) (list 3 4))
                                  (list (list 5 6) (list 7 8)))
                            (list (list (list 9 10) (list 11 12))
                                  (list (list 13 14) (list 15 16))))))))
