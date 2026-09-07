;;;; scripts/repl.lisp — interactive REPL driver for an agent.
;;;;
;;;; Usage (repo root):
;;;;   SBCL_HOME=.tools/sbcl XDG_CACHE_HOME=.tools/cache ^
;;;;     .tools/sbcl/sbcl.exe --script scripts/repl.lisp
;;;;
;;;; Offline note: real model calls need an *http-fetch-hook* (see
;;;; src/llm/transport.lisp). Without one the REPL prints a clear message and
;;;; exits — all deterministic tests use the in-image mock transport instead.
(in-package #:cl-user)

(require :asdf)

;; Optional: if a Quicklisp install exists, load it so dependencies resolve on
;; standard networked machines (vendored .tools/deps is only used otherwise).
(handler-case
    (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
           (setup (and home (merge-pathnames "quicklisp/setup.lisp"
                                  (uiop:ensure-directory-pathname home)))))
      (when (and setup (uiop:file-exists-p setup))
        (load setup)
        (format t "~&[bootstrap] quicklisp loaded from ~a~%" setup)))
  (error (e)
    (format t "~&[bootstrap] quicklisp unavailable: ~a~%" e)))


(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(asdf:initialize-source-registry
 `(:source-registry
   (:tree ,(uiop:subpathname *root* ".tools/deps/"))
   (:tree ,(uiop:subpathname *root* ".tools/sbcl/contrib/"))
   :ignore-inherited-configuration))
(pushnew *root* asdf:*central-registry* :test #'equal)


;; Quicklisp dist systems only become visible to ASDF after a ql:quickload,
;; so prime the four project dependencies first (runtime-resolved symbols).
(handler-case
    (let ((q (find-package "QL")))
      (when q
        (let ((quickload (find-symbol "QUICKLOAD" q)))
          (when quickload
            (funcall quickload '(:alexandria :yason :split-sequence :bordeaux-threads)
                     :silent t)
            (format t "~&[bootstrap] deps quickloaded~%")))))
  (error (e)
    (format t "~&[bootstrap] deps quickload failed: ~a~%" e)))

(asdf:load-system :agent-cl)
(agent-cl.tools:register-builtin-tools)

;; Prefer an in-process dexador+cl+ssl hook (needs vendored deps + CA bundle);
;; if unavailable the REPL still starts and real calls will fail with a clear
;; transport error (use mock transports or scripts/smoke.lisp in that case).
(handler-case
    (progn
      (load (merge-pathnames "dev-http.lisp"
                             (uiop:pathname-directory-pathname *load-truename*)))
      (let ((enable (find-symbol "ENABLE-HOOK" "AGENT-CL.DEXADOR-DEV")))
        (when enable (funcall enable))))
  (error (e)
    (format t "~&[repl] dexador direct unavailable: ~a~%" e)))

;; Plan-then-Execute 助手（/plan）
(handler-case
    (load (merge-pathnames "plan.lisp"
                           (uiop:pathname-directory-pathname *load-truename*)))
  (error (e)
    (format t "~&[repl] plan.lisp 加载失败: ~a~%" e)))

(defparameter *model* (or (uiop:getenv "AGENT_CL_MODEL") "deepseek-chat"))
(defparameter *base-url* (or (uiop:getenv "AGENT_CL_BASE_URL") "https://api.deepseek.com/v1"))

(defclass repl-agent (agent-cl.loop:agent) ())

(defmethod agent-cl.loop:on-tool-result ((a repl-agent) tool-name result-plist)
  "REPL 里把工具执行可视化（流式进行中也会出现）。"
  (declare (ignore a))
  (format t "~&  [tool ~a -> ~a]~%" tool-name (getf result-plist :status))
  (finish-output))

(defun make-repl-agent ()
  (make-instance 'repl-agent
   :transport (agent-cl.llm:make-http-transport
               :base-url *base-url*
               :api-key (uiop:getenv "AGENT_CL_API_KEY"))
   :model *model*
   :tools :all
   :system (format nil "你是基于 Common Lisp 构建的 Agent（模型 ~a）。需要动手时使用工具。" *model*)))

(unless agent-cl.llm:*http-fetch-hook*
  (format t "~&[repl] 警告: 未设置 agent-cl.llm:*http-fetch-hook*（离线构建）。~%")
  (format t "[repl] 真实请求将失败；请设置 AGENT_CL_API_KEY 后重试，测试请使用 mock transport。~%"))
;;; ---------------------------------------------------------------------------
;;; Markdown → ANSI 行级渲染（控制台友好；NO_COLOR=1 关闭颜色）
;;; ---------------------------------------------------------------------------
(defvar *color* (null (uiop:getenv "NO_COLOR")))
(defun esc (n) (format nil "~c[~am" #\Escape n))
(defun ansi (n text) (if *color* (format nil "~a~a~a" (esc n) text (esc 0)) text))

(defun render-inline (text)
  "**粗体** 与 `行内代码` 的最小 ANSI 着色。"
  (if (null *color*)
      text
      (let ((out (make-string-output-stream))
            (i 0) (n (length text)) (bold nil))
        (loop while (< i n)
              do (cond
                   ((and (< (1+ i) n)
                         (char= (char text i) #\*)
                         (char= (char text (1+ i)) #\*))
                    (setf bold (not bold))
                    (write-string (if bold (esc 1) (esc 0)) out)
                    (incf i 2))
                   ((char= (char text i) #\`)
                    (write-string (esc 32) out)
                    (incf i)
                    (loop while (and (< i n) (not (char= (char text i) #\`)))
                          do (write-char (char text i) out) (incf i))
                    (write-string (esc 0) out)
                    (when (< i n) (incf i)))     ; 跳过闭合反引号
                   (t (write-char (char text i) out) (incf i))))
        (when bold (write-string (esc 0) out))   ; 未闭合 ** 也要复位，防终端残留加粗
        (get-output-stream-string out))))

(defvar *md-state* :normal)
(defun reset-md () (setf *md-state* :normal))

(defvar *md-code-words*
  '("def" "return" "import" "from" "print" "if" "elif" "else" "for" "while"
    "lambda" "class" "defun" "let" "loop" "when" "unless" "setf" "progn"
    "quote" "nil" "format" "and" "or" "not" "in" "range"))

(defun tint-code-line (line)
  "把代码行里的常见关键字染黄，其余保持青色。"
  (if (null *color*)
      line
      (let ((out (make-string-output-stream))
            (n (length line)) (i 0) (word (make-string-output-stream)))
        (labels ((flush-word ()
                   (let ((w (get-output-stream-string word)))
                     (unless (zerop (length w))
                       (write-string
                        (if (member (string-downcase w) *md-code-words* :test #'string=)
                            (ansi 33 w)
                            (ansi 36 w))
                        out)))))
          (loop while (< i n)
                do (let ((ch (char line i)))
                     (if (or (alphanumericp ch) (char= ch #\_) (char= ch #\-))
                         (write-char ch word)
                         (progn (flush-word)
                                (write-char (if (member ch '(#\( #\) #\, #\;))
                                                #\Space ch)
                                            out)))
                     (incf i)))
          (flush-word)
          (get-output-stream-string out)))))

(defun table-row-p (line)
  (and (plusp (length line))
       (>= (count #\| line) 2)))

(defun render-md-line (line)
  "渲染一行（不含换行）；维护代码围栏状态。"
  (let ((trim (string-trim '(#\Space #\Tab #\Return) line)))
    (cond
      ((eq *md-state* :code)
       (if (and (>= (length trim) 3) (string= (subseq trim 0 3) "```"))
           (progn (setf *md-state* :normal)
                  (format t "~a~%" (ansi 33 trim)))
           (format t "~a~%" (tint-code-line line))))
      ((and (>= (length trim) 3) (string= (subseq trim 0 3) "```"))
       (setf *md-state* :code)
       (format t "~a~%" (ansi 33 trim)))
      ((and (plusp (length trim)) (char= (char trim 0) #\#))
       (format t "~a~%" (render-inline (ansi 1 line))))
      ((table-row-p trim)
       (format t "~a~%" (ansi 35 (render-inline line))))
      ((and (plusp (length trim))
            (member (char trim 0) '(#\- #\* #\+))
            (or (= (length trim) 1)
                (and (> (length trim) 1)
                     (char= (char trim 1) #\Space))))
       (format t "~a~%" (render-inline line)))
      (t (format t "~a~%" (render-inline line))))))

(defun render-md-text (text)
  "整段渲染（非流式回退用）。"
  (reset-md)
  (let ((start 0))
    (loop for nl = (position #\Newline text :start start)
          while nl
          do (render-md-line (subseq text start nl))
             (setf start (1+ nl)))
    (when (< start (length text))
      (render-md-line (subseq text start))))
  (reset-md))

;; 流式缓冲：整行才上色，未完成的行留缓冲
(defvar *tok-buf* (make-string-output-stream))
(defun reset-tokens () (setf *tok-buf* (make-string-output-stream)) (reset-md))
(defun flush-tokens ()
  (let ((rest (get-output-stream-string *tok-buf*)))
    (when (plusp (length rest)) (render-md-line rest)))
  (reset-md)
  (terpri)
  (finish-output))

(defun repl-on-token (text)
  (write-string text *tok-buf*)
  (let ((s (get-output-stream-string *tok-buf*)))
    (loop for nl = (position #\Newline s)
          while nl
          do (render-md-line (subseq s 0 nl))
             (setf s (subseq s (1+ nl))))
    (write-string s *tok-buf*)
    (finish-output)))

;; ---------------------------------------------------------------------------
;; 斜杠命令面板 / 会话导出载入 / 工具可视化
;; ---------------------------------------------------------------------------
(defun export-transcript (agent path)
  (with-open-file (o path :direction :output :if-exists :supersede
                         :external-format :utf-8)
    (dolist (m (agent-cl.loop:agent-messages agent))
      (write-line (agent-cl.core:json-encode
                   (agent-cl.llm:encode-message-wire m))
                  o)))
  (format t "~&已导出 ~a 条消息 -> ~a~%"
          (length (agent-cl.loop:agent-messages agent)) path))

(defun wire->message (plist)
  (let ((role (ecase (intern (string-upcase (or (getf plist :ROLE) "user"))
                             :keyword)
                (:SYSTEM :system) (:USER :user)
                (:ASSISTANT :assistant) (:TOOL :tool))))
    (cond
      ((eq role :tool)
       (agent-cl.messages:tool-result-message (getf plist :TOOL-CALL-ID)
                                              (or (getf plist :CONTENT) "")))
      ((and (eq role :assistant) (getf plist :TOOL-CALLS))
       (agent-cl.messages:assistant-message
        (or (getf plist :CONTENT) "")
        :tool-calls
        (loop for tc in (getf plist :TOOL-CALLS)
              for fn = (getf tc :FUNCTION)
              collect (agent-cl.messages:make-tool-call
                       (getf tc :ID) (getf fn :NAME)
                       (or (getf fn :ARGUMENTS) "{}")))))
      (t (agent-cl.messages:make-message role
                                         :content (or (getf plist :CONTENT) ""))))))

(defun sanitize-loaded-messages (msgs)
  "载入的会话可能是被中断/截断导出的：去掉开头的孤立 :tool 消息与结尾的
  悬空 assistant tool_calls（其后无 tool 结果），避免续谈时向 provider
  发送非法消息序列（tool 无前置 assistant / assistant tool_calls 无结果）。
  中间序列信任导出端（引擎保证配对）。"
  ;; 1) drop leading orphan tool results
  (let ((ms (loop for m in msgs
                  while (eq (agent-cl.messages:msg-role m) :tool)
                  finally (return msgs))))
    ;; 2) drop a trailing assistant message that carries tool_calls but has no
    ;; tool result after it (interrupted mid-turn export).
    (let ((n (length ms)))
      (if (and (plusp n)
               (eq (agent-cl.messages:msg-role (nth (1- n) ms)) :assistant)
               (agent-cl.messages:msg-tool-calls (nth (1- n) ms)))
          (subseq ms 0 (1- n))
          ms))))

(defun import-transcript (agent path)
  (let (msgs)
    (with-open-file (i path :direction :input :external-format :utf-8)
      (loop for line = (read-line i nil nil)
            while line
            for trimmed = (string-trim '(#\Return #\Space) line)
            unless (string= trimmed "")
              do (push (wire->message (agent-cl.core:decode-to-plist trimmed)) msgs)))
    (setf msgs (sanitize-loaded-messages (nreverse msgs)))
    (setf (agent-cl.loop:agent-messages agent) msgs)
    (format t "~&已载入 ~a 条消息~%" (length msgs))))

(defun list-memory-keys ()
  (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
         (dir (merge-pathnames ".agent-cl/memory/"
                               (uiop:ensure-directory-pathname home))))
    (when (uiop:directory-exists-p dir)
      (loop for f in (uiop:directory-files dir "*.json")
            collect (pathname-name f)))))

(defun print-help ()
  (format t "~&可用命令：~%")
  (format t "  /help          显示本帮助~%")
  (format t "  /tools         列出当前可用工具~%")
  (format t "  /memory        列出跨会话记忆键~%")
  (format t "  /export <file> 把当前会话导出为 JSONL~%")
  (format t "  /load <file>   载入 JSONL 会话继续对话~%")
  (format t "  /new           清空当前会话~%")
  (format t "  /color on|off  开/关 ANSI 颜色~%")
  (format t "  /plan <task>    Plan-then-Execute：拆步骤→逐步执行→汇总~%")
  (format t "  /compact       手动压缩旧会话为摘要~%")
  (format t "  /budget <tokens> 设置自动压缩触发预算（默认 6000）~%")
  (format t "  /quit 或 /exit 退出~%"))

(defvar *context-budget-chars* 6000
  "自动压缩触发预算（按 approx tokens；/budget 可改）")

(defun ctx-tokens (agent)
  "Approx tokens of the whole transcript. Content + (for assistant messages)
  every tool call's name and JSON arguments, so big tool-call payloads are not
  underestimated when deciding whether to compact."
  (loop for m in (agent-cl.loop:agent-messages agent)
        sum (+ (agent-cl.core:approx-tokens
                (or (agent-cl.messages:msg-content m) ""))
               (loop for tc in (agent-cl.messages:msg-tool-calls m)
                     sum (+ (agent-cl.core:approx-tokens
                             (agent-cl.messages:tool-call-name tc))
                            (agent-cl.core:approx-tokens
                             (agent-cl.messages:tool-call-arguments tc)))))))

(defun msg-line (m)
  (format nil "[~a] ~a" (agent-cl.messages:msg-role m)
          (or (agent-cl.messages:msg-content m) "")))

(defun summarize-in-child (agent text)
  "用一次独立短会话把旧对话压缩成摘要；失败返回 NIL。"
  (handler-case
      (let* ((child (agent-cl.loop:make-agent
                     :transport (agent-cl.loop:agent-transport agent)
                     :model (agent-cl.loop:agent-model agent)
                     :tools nil
                     :system "你是会话压缩器。把用户提供的早前对话浓缩为中文要点（250 字内），保留关键事实、结论与工具结果数值。只输出摘要。"
                     :policy (agent-cl.loop:make-policy :max-steps 1)))
             (r (agent-cl.loop:ask child text))
             (f (agent-cl.loop:final-content r)))
        (if (and (agent-cl.loop:done-p r) f) f nil))
    (error () nil)))

(defun maybe-compact (agent)
  "上下文超预算时，把最旧消息交给模型凝成摘要后替换（保留较新部分）。"
  (when (> (ctx-tokens agent) *context-budget-chars*)
    (let* ((msgs (agent-cl.loop:agent-messages agent))
           (n (length msgs))
           (target (* *context-budget-chars* 0.5)))
      (when (> n 2)
        (let (kept-rev (acc 0))
          ;; 从最新往回收，直到近似 token 达到目标（至少保留 1 条）
          (dolist (m (reverse msgs))
            (push m kept-rev)
            (incf acc (agent-cl.core:approx-tokens
                       (or (agent-cl.messages:msg-content m) "")))
            (when (>= acc target) (return)))
          (let* ((kept (nreverse kept-rev))
                 (drop-n (- n (length kept))))
            ;; 切割边界净化：若 kept 以孤立的 tool 结果开头（其 assistant
            ;; tool-call 已被压进摘要），把这类 tool 也并入被压缩区，避免
            ;; 下次请求以 :tool 消息开头 -> provider 400。
            (loop while (and (plusp (length kept))
                             (eq (agent-cl.messages:msg-role (first kept)) :tool))
                  do (pop kept)
                     (incf drop-n))
            (when (and (plusp drop-n) kept)
              (let* ((drop (subseq msgs 0 drop-n))
                     (summary (summarize-in-child
                               agent (format nil "~{~a~%~}" (mapcar #'msg-line drop)))))
                (unless summary
                  (setf summary (format nil "（早前 ~a 条消息已压缩）" drop-n)))
                (setf (agent-cl.loop:agent-messages agent)
                      (cons (agent-cl.messages:user-message
                             (format nil "[早前会话摘要] ~a" summary))
                            kept))
                (format t "~&[compact] 已压缩 ~a 条旧消息 -> 摘要（预算 ~a）~%"
                        drop-n *context-budget-chars*)))))))))

(defun repl-command (line agent)
  (let* ((trim (string-trim '(#\Space #\Tab) line))
         (sp (position #\Space trim))
         (cmd (if sp (subseq trim 0 sp) trim))
         (rest (and sp (string-trim '(#\Space) (subseq trim (1+ sp))))))
    (cond
      ((string= cmd "/help") (print-help))
      ((string= cmd "/tools")
       (format t "~&工具: ~{~a~^, ~}~%" (agent-cl.tools:list-tools)))
      ((string= cmd "/memory")
       (let ((keys (list-memory-keys)))
         (format t "~&记忆键: ~{~a~^, ~}~%" (or keys '("(空)")))))
      ((string= cmd "/export")
       (if rest (export-transcript agent rest)
           (format t "~&用法: /export <file.jsonl>~%")))
      ((string= cmd "/load")
       (if (and rest (uiop:file-exists-p rest))
           (import-transcript agent rest)
           (format t "~&用法: /load <file.jsonl>（文件不存在）~%")))
      ((string= cmd "/new")
       (setf (agent-cl.loop:agent-messages agent) nil)
       (format t "~&已清空当前会话~%"))
      ((string= cmd "/compact")
       (maybe-compact agent)
       (format t "~&当前 ~a tokens~%" (ctx-tokens agent)))
      ((string= cmd "/plan")
       (let ((f (and rest (find-symbol "RUN-PLANNED" "AGENT-CL.PLAN"))))
         (if f
             (handler-case
                 (progn
                   (funcall f agent rest #'repl-on-token)
                   (flush-tokens))   ; 步骤流式残段此刻落屏，勿留到下一轮被 reset-tokens 丢弃
               (error (e)
                 (format t "~&[plan] 失败: ~a~%" e)))
             (format t "~&/plan 不可用：scripts/plan.lisp 未加载~%"))))
      ((string= cmd "/budget")
       (let ((v (and rest (ignore-errors (parse-integer rest)))))
         (if v (progn (setf *context-budget-chars* v)
                      (format t "~&预算设为 ~a tokens~%" v))
             (format t "~&用法: /budget <tokens>~%"))))
      ((string= cmd "/color")
       (setf *color* (not (and rest (string= rest "off"))))
       (format t "~&颜色: ~a~%" (if *color* "on" "off")))
      ((or (string= cmd "/quit") (string= cmd "/exit"))
       (uiop:quit 0))
      (t (format t "~&未知命令 ~a（/help 查看）~%" cmd)))))


(defun ask-turn (agent line)
  (maybe-compact agent)
  (reset-tokens)
  (handler-case
      (let ((summary (agent-cl.loop:ask agent line :stream t
                                        :on-token #'repl-on-token)))
        (flush-tokens)
        (when (not (agent-cl.loop:done-p summary))
          (format t "~&[agent 未完成: ~a]~%"
                  (agent-cl.loop:guard-reason summary))))
    (error (e)
      (format t "~&[stream fallback: ~a]~%" e)
      (reset-tokens)
      (handler-case
          (let ((summary (agent-cl.loop:ask agent line)))
            (if (agent-cl.loop:done-p summary)
                (render-md-text (or (agent-cl.loop:final-content summary) ""))
                (format t "~&[agent 未完成: ~a]~%"
                        (agent-cl.loop:guard-reason summary))))
        (error (e2)
          (format t "~&agent> [error] ~a~%" e2))))))

;; ---------------------------------------------------------------------------
;; 主循环
;; ---------------------------------------------------------------------------
(handler-case
    (let ((agent (make-repl-agent)))
      (format t "~&Agent-CL REPL — 输入任务；/help 查看命令；空行退出；Ctrl-C 中断。~%")
      (format t "流式输出 + Markdown 着色已启用（/color off 关闭）。~%")
      (loop
        (format t "~&you> ")
        (finish-output)
        (let ((line (read-line *standard-input* nil :eof)))
          (when (or (eq line :eof) (string= (string-trim '(#\Space #\Tab) line) ""))
            (return))
          (if (and (plusp (length line)) (char= (char line 0) #\/))
              (repl-command line agent)
              (ask-turn agent line)))))
  ;; Ctrl-C 优雅退出（--script 下无调试器）
  (sb-sys:interactive-interrupt ()
    (format t "~&[repl] 已退出（Ctrl-C）。~%")
    (finish-output)
    (uiop:quit 0)))
