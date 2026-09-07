;;;; scripts/plan.lisp — Plan-then-Execute 助手（独立模块，供 repl /plan 动态加载）
(defpackage #:agent-cl.plan
  (:use #:cl)
  (:export #:run-planned))

(in-package #:agent-cl.plan)

(defun one-shot (agent system text)
  "无工具短会话，取模型文本输出。"
  (handler-case
      (let ((w (agent-cl.loop:make-agent
                :transport (agent-cl.loop:agent-transport agent)
                :model (agent-cl.loop:agent-model agent)
                :tools nil
                :system system
                :policy (agent-cl.loop:make-policy :max-steps 1))))
        (let ((r (agent-cl.loop:ask w text)))
          (agent-cl.loop:final-content r)))
    (error (e) (format nil "[error: ~a]" e))))

(defun step-body (s)
  "去掉行首编号与分隔符，返回步骤正文。"
  (let* ((n (length s))
         (i 0))
    (loop while (and (< i n) (digit-char-p (char s i))) do (incf i))
    (loop while (and (< i n) (member (char s i) '(#\. #\) #\- #\Space)))
          do (incf i))
    (string-trim '(#\Space #\Tab) (subseq s i))))

(defun parse-plan (text)
  (remove-if (lambda (x) (zerop (length x)))
             (loop for ln in (uiop:split-string (or text "") :separator '(#\Newline))
                   for t2 = (string-trim '(#\Space #\Tab #\Return) ln)
                   when (and (plusp (length t2)) (digit-char-p (char t2 0)))
                     collect (step-body t2))))

(defun run-step (agent s on-token)
  "单步执行：流式优先，出错退化为一次性调用；两次都失败也返回错误文本，不让异常穿透。"
  (handler-case
      (agent-cl.loop:ask agent s :stream t :on-token on-token)
    (error ()
      (handler-case
          (agent-cl.loop:ask agent s)
        (error (e)
          (agent-cl.loop:guard-failed agent
                                      (format nil "step error: ~a" e)))))))

(defun step-child (agent s task on-token)
  "用一次性子 agent 执行单步，返回 turn-summary。子 agent 继承 transport/
  model/工具集但不共享 transcript——步骤执行的过程消息不会污染主会话历史。"
  (let* ((names (agent-cl.loop:agent-tools agent))
         (tools (if (eq names :all) (agent-cl.tools:list-tools) names))
         (child (agent-cl.loop:make-agent
                 :transport (agent-cl.loop:agent-transport agent)
                 :model (agent-cl.loop:agent-model agent)
                 :tools tools
                 :system "你是被 /plan 调用的步骤执行器。执行当前这一步并给出简短结论。"
                 :policy (agent-cl.loop:make-policy :max-steps 8))))
    (run-step child (format nil "~a~%[原任务背景] ~a" s task) on-token)))

(defun run-planned (agent task &optional (on-token nil))
  (format t "~&[plan] 规划步骤...~%")
  (finish-output)
  (let* ((plan (one-shot agent
                         "你是任务规划器。把任务拆成不超过 4 个可执行步骤，每行一条：1. 步骤内容。只输出步骤列表。"
                         task))
         (steps (or (parse-plan plan) (list task))))
    (format t "~&[plan] 步骤: ~{~a~^ | ~}~%" steps)
    (let ((results nil))
      (loop for s in steps
            for idx from 1
            do (format t "~&[plan] 执行 ~a/~a ~a~%" idx (length steps) s)
               (finish-output)
               (let ((r (step-child agent s task on-token)))
                 (push (cond ((agent-cl.loop:done-p r)
                              (or (agent-cl.loop:final-content r) "(无输出)"))
                             (t (format nil "[步骤未完成: ~a]"
                                        (agent-cl.loop:guard-reason r))))
                       results)))
      (let* ((res (nreverse results))
             (summary (one-shot agent
                                "你是总结者：根据各步骤执行结果，用中文简洁回答用户原任务，不赘述过程。"
                                (format nil "原任务：~a~%步骤结果：~%~{~a~%~}" task res))))
        (when summary (format t "~&~a~%" summary))
        summary))))
