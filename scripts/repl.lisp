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

;; Defined further down with the rest of the streaming renderer; declared here so
;; the display hooks below can call it without a forward-reference warning.
(declaim (ftype (function () t) flush-token-prefix))

;;; --- sub-agent activity display -------------------------------------------
;;; task.delegate hands a subtask to a child agent that shares this class and
;;; runs one depth level deeper (see src/tools/builtin.lisp). Routing its steps
;;; and tool calls through the pure agent-cl.render layout makes delegated work
;;; visible and visually nested under the parent instead of silently swallowed.

(defun repl-subagent-mark (depth)
  "Display tag for activity from a delegated sub-agent at DEPTH (>= 1).
   NIL at the top level, so a top-level agent's own output is never altered."
  (when (plusp depth)
    (format nil "[sub agent ~d]" depth)))

(defun repl-activity (agent text &optional (base-indent 2))
  "Render one activity line for AGENT through the pure nesting layout.
   Depth 0 (the top-level agent) prepends only the usual gutter, so existing
   output is byte-for-byte unchanged; a sub-agent is additionally indented and
   tagged by repl-subagent-mark, so delegated work reads as nested."
  (let ((depth (agent-cl.loop:agent-depth agent)))
    (format nil "~a~a"
            (make-string base-indent :initial-element #\Space)
            (agent-cl.render:agent-activity-line
             depth (repl-subagent-mark depth) text))))

(defmethod agent-cl.loop:on-step-start ((a repl-agent) step-ctx)
  "Show a sub-agent's steps. The top-level agent's steps stay implicit in the
   streamed answer, so its output is unchanged."
  (let ((depth (agent-cl.loop:agent-depth a)))
    (when (plusp depth)
      (flush-token-prefix)
      (format t "~&~a~%"
              (repl-activity a (format nil "step ~a" (getf step-ctx :step))))
      (finish-output))))

(defmethod agent-cl.loop:on-tool-result ((a repl-agent) tool-name result-plist)
  "REPL printer: show every tool result. A sub-agent's call is indented and
   [sub agent N]-tagged so delegated activity is distinct from the parent's; a
   failure prints the concrete reason (truncated) so the user is not left
   staring at a bare ERROR."
  ;; flush first, so this row cannot appear above text the model already emitted
  (flush-token-prefix)
  (let ((status (getf result-plist :status))
        (content (getf result-plist :content)))
    (if (eq status :ok)
        (format t "~&~a~%" (repl-activity a (format nil "[tool ~a -> OK]" tool-name)))
        (progn
          (format t "~&~a~%"
                  (repl-activity a (format nil "[tool ~a -> ~a]" tool-name status)))
          (when content
            (format t "~a~%"
                    (repl-activity a
                                   (subseq content 0 (min 400 (length content)))
                                   4))))))
  (finish-output))

(defun repl-print-activity-block (agent text &optional (base-indent 2))
  "Print multi-line TEXT as AGENT activity, one gutter line per input line.
   The first line carries the sub-agent tag; continuations stay aligned.
   Long output is truncated so a runaway conclusion cannot flood the REPL."
  (let* ((cap 2000)
         (shown (if (> (length text) cap)
                    (concatenate 'string (subseq text 0 cap) " …")
                    text))
         (lines (uiop:split-string shown :separator (list #\Newline))))
    (format t "~&~a~%" (repl-activity agent (first lines) base-indent))
    (dolist (l (rest lines))
      (format t "~&~a~%" (repl-activity agent l base-indent)))
    (finish-output)))

(defmethod agent-cl.loop:on-turn-done ((a repl-agent) summary)
  "Show a sub-agent's conclusion the moment that (child) agent finishes.
   The top-level agent's conclusion is already the streamed answer, so depth 0
   stays silent and existing output is unchanged."
  (let ((depth (agent-cl.loop:agent-depth a)))
    (when (and (plusp depth) (agent-cl.loop:done-p summary))
      (let ((text (agent-cl.loop:final-content summary)))
        (when (and text (plusp (length text)))
          (repl-print-activity-block a (format nil "结论: ~a" text)))))))

(defparameter *repl-system-prompt*
  (concatenate 'string
    "你是 Agent-CL —— 一个构建在 Common Lisp（SBCL）之上的自主 Agent。"
    "你运行在真实主机上，可读写文件、执行命令、写代码并运行"
    "（code.exec 支持 python / sbcl / sh）。当前模型：" *model* "。"

    "【核心准则一：对自己的代码负责】"
    "你说要做什么、说已经做完什么，都必须有据可依。"
    "- 开工前先给出一句话计划：目标 → 方案 → 如何验证。"
    "- 把任务切成分阶段的里程碑；每个里程碑收尾时，用 code.exec 运行"
    "  与之对应的测试单元（或最小验证示例），跑通后再向用户交付该阶段"
    "  结论。未验证的阶段成果，明确标注“待验证”，不装作已完工。"
    "- 小步迭代过程中允许快速试跑（REPL 式），但“完成”的定义是：该"
    "  阶段通过了对应测试，而不是“看起来能跑”。"
    "- 这正符合 Common Lisp 的 REPL 式开发：小步写、小步跑，里程碑"
    "  有据可查。"

    "【核心准则二：实事求是，把用户当作协作者】"
    "- 不知道就说不知道，做不到就说做不到，不确定就说“我不确定”——"
    "  绝不编造数值、文件内容、工具结果或“我记得是……”。"
    "- 当需求有歧义、信息不足、或存在多种合理方向时，先简短地反问"
    "  澄清（可给出你倾向的选项），而不是闷头猜一个方向做完。"
    "- 适度主动汇报进展与卡点：每完成一个有意义的阶段，用一两句同步"
    "  结论/下一步；遇到阻碍不硬扛，说出来一起定方向。"
    "- 但不要为提问而提问：能合理推断的默认值自己定，只在实质性歧义"
    "  时才打断用户。"

    "【发挥 Common Lisp 的表达力（让代码更短更强）】"
    "- 批量操作优先高阶函数（mapcar / remove-if / reduce / find-if /"
    "  count-if / position / subseq），少手写循环；迭代用 loop 宏的"
    "  声明式写法。"
    "- 文本用 format 指令（~a ~d ~{~} ~%），轻量数据用 plist/alist。"
    "- 重复结构用 defmacro 抽象成领域语言，但克制、可读、带文档。"
    "- code.exec 默认选 sbcl；纯函数式核心 + 最小副作用，让逻辑天然"
    "  可测（输入到输出，不依赖外部状态）——这也是“代码可负责”的根基。"

    "【交互约定】"
    "- 中文回答，结论先行；工具结果过长先提炼要点。"
    "- 涉及真实世界状态必须调用工具，把工具结果转述，不凭空给。"))

(defun make-repl-agent ()
  (make-instance 'repl-agent
   :transport (agent-cl.llm:make-http-transport
               :base-url *base-url*
               :api-key (uiop:getenv "AGENT_CL_API_KEY"))
   :model *model*
   :tools :all
   :system *repl-system-prompt*))

(unless agent-cl.llm:*http-fetch-hook*
  (format t "~&[repl] 警告: 未设置 agent-cl.llm:*http-fetch-hook*（离线构建）。~%")
  (format t "[repl] 真实请求将失败；请设置 AGENT_CL_API_KEY 后重试，测试请使用 mock transport。~%"))
;;; ---------------------------------------------------------------------------
;;; Markdown → ANSI 行级渲染（控制台友好；NO_COLOR=1 关闭颜色）
;;; ---------------------------------------------------------------------------
(defun color-capable-p ()
  "True when ANSI colour is worth emitting on *STANDARD-OUTPUT*.

  Redirecting the REPL to a file, a pipe or a CI log used to fill it with escape
  sequences, so colour is now gated on having a real console. On Windows the
  console probe is the reliable test: SBCL reports INTERACTIVE-STREAM-P as true
  even for a redirected fd-stream (verified with piped input). NO_COLOR=1 still
  has the final say on every platform."
  (and (null (uiop:getenv "NO_COLOR"))
       (if (uiop:os-windows-p)
           (and (agent-cl.render:probe-console) t)
           (or (ignore-errors (interactive-stream-p *standard-output*)) t))))

(defvar *color* (color-capable-p))
(defun esc (n) (format nil "~c[~am" #\Escape n))
(defun ansi (n text) (if *color* (format nil "~a~a~a" (esc n) text (esc 0)) text))

(defun inline-theme ()
  "Build the ANSI theme plist fed to the pure renderer, honouring *color*.
  When colour is off the theme is NIL, which makes agent-cl.render:render-inline*
  strip the markdown markers and return plain text — the NO_COLOR fallback."
  (when *color*
    (list :bold "1" :code "36" :link "4")))

(defun render-inline (text)
  "Render **bold** / `code` / [link](url) via the pure, tested core.
  Thin adapter: choose the theme from *color*, delegate to agent-cl.render."
  (agent-cl.render:render-inline* text (inline-theme)))

;;;; repl.lisp RENDER-SECTION PATCH (surgical replacement, kept readable)
;;;; Replaces the old global-*md-state* line renderer with one driven by the
;;;; pure, tested agent-cl.render core. Colour helpers (*md-code-words*,
;;;; tint-code-line, table-row-p) are preserved verbatim; the state machine and
;;;; streaming/flush now thread fence state via *fence* (turn-scoped explicit
;;;; value) and ask the pure core for the classification of every line.
;;;;
;;;; *engine* :new (default) -> fence/code-aware via agent-cl.render.
;;;; *engine* :legacy        -> /engine legacy : passthrough ordinary lines
;;;;                            (no fence highlighting), as a visual fallback.

;;;; --- render-mode switch --------------------------------------------
(defparameter *engine* :new)          ; :new | :legacy
(defparameter *fence* :fence-out)     ; current agent-cl.render fence state

;;;; --- colour helpers (unchanged, ANSI decisions live here) ------------
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

;;;; --- ordinary (non-fenced) line decoration ---------------------------
(defun emit-heading (level text)
  "Render a heading (text already inline-rendered) at LEVEL. Styling decisions
  (SGR code, underline) come from the pure agent-cl.render core; this only
  prints. H1 gets a leading blank line and a heavy underline, H2 a light one."
  (let ((code (and *color* (agent-cl.render:heading-ansi level)))
        (col  (and *color* (agent-cl.render:heading-rule-color level)))
        (line (agent-cl.render:heading-rule level)))
    (when (= level 1) (format t "~%"))            ; breathing room above H1
    (format t "~a~%"
            (if code
                (format nil "~c[~am~a~c[0m" #\Escape code text #\Escape)
                text))
    (when (plusp (length line))
      (format t "~a~%"
              (if *color*
                  (format nil "~c[~am~a~c[0m" #\Escape col line #\Escape)
                  line)))))

(defun render-heading-line (level text)
  "Emit a heading, styled by LEVEL. Uses the pure classify-heading result;
  the marker (#) itself is not printed. Falls back to plain when *color* is off."
  (emit-heading level (render-inline text)))

(defun horizontal-rule-p (trim)
  "True for a markdown horizontal rule: 3+ of the same -, * or _ (allowing spaces)."
  (and (>= (length trim) 3)
       (let ((c (char trim 0)))
         (and (member c '(#\- #\* #\_))
              (every (lambda (ch) (or (char= ch c) (char= ch #\Space))) trim)
              (>= (count c trim) 3)))))

(defvar *table-buf* nil
  "Pending table rows (list of cell-lists) accumulated until the table ends.
  Tables must be buffered whole because column widths need every row up front.")

(defun flush-table ()
  "Emit any buffered table as an aligned block, then clear the buffer.
  Header (first row) is bolded when colour is on. No-op when empty."
  (when *table-buf*
    (let* ((rows (nreverse *table-buf*))
           (lines (agent-cl.render:format-table-block rows)))
      (loop for line in lines
            for first = t then nil
            do (format t "~a~%"
                       (if (and first *color*)
                           (ansi 1 line)       ; bold header
                           line))))
    (setf *table-buf* nil)))

(defun render-list-item (kind indent ltext)
  "Emit a list item. Bullets show a coloured '•'; ordered items keep their own
  number (ltext is 'N. body'). INDENT leading spaces are preserved so nesting
  reads as indentation."
  (let ((pad (make-string indent :initial-element #\Space)))
    (if (eq kind :bullet)
        (format t "~a~a ~a~%" pad
                (if *color* (ansi 36 "•") "•")
                (render-inline ltext))
        (format t "~a~a~%" pad (render-inline ltext)))))

(defun render-ordinary-line (line)
  "普通行的装饰：标题分级 / 水平线 / 列表 / 表格（缓冲对齐）/ 其它默认。"
  (let ((trim (string-trim '(#\Space #\Tab #\Return) line)))
    (multiple-value-bind (hlevel htext) (agent-cl.render:classify-heading line)
      (cond
        ((plusp hlevel) (flush-table) (render-heading-line hlevel htext))
        ((horizontal-rule-p trim)
         (flush-table)
         (format t "~a~%" (if *color*
                              (ansi 90 (make-string 40 :initial-element #\-))
                              (make-string 40 :initial-element #\-))))
        (t
         (multiple-value-bind (lkind lindent ltext)
             (agent-cl.render:classify-list-item line)
           (cond
             ((eq lkind :bullet)  (flush-table) (render-list-item :bullet lindent ltext))
             ((eq lkind :ordered) (flush-table) (render-list-item :ordered lindent ltext))
             ((table-row-p trim)
              ;; buffer this row; the whole table is emitted at once later
              (push (agent-cl.render:parse-table-row line) *table-buf*))
             (t (flush-table) (format t "~a~%" (render-inline line))))))))))

;;;; --- classify + emit one logical line -------------------------------
(defun render-one-md-line (kind line)
  "按 agent-cl.render 给的单行 KIND 上屏（不含换行）。"
  (ecase kind
    (:blank       (format t "~%"))
    (:fence-start (format t "~a~%" (ansi 33 (string-trim '(#\Space #\Tab) line))))
    (:fence-end   (format t "~a~%" (ansi 33 (string-trim '(#\Space #\Tab) line))))
    (:code        (format t "~a~%" (tint-code-line line)))
    (:normal      (render-ordinary-line line))))

(defun advance-fence-with-line (line)
  "将一整行(无尾换行)作为逻辑行交给 pure classify-one，更新并返回 *fence*，
  再按分类结果上屏。legacy 模式退化为纯普通行输出。"
  (if (eq *engine* :legacy)
      (render-ordinary-line line)
      (multiple-value-bind (st md)
          (agent-cl.render:classify-one *fence* line)
        (setf *fence* st)
        ;; a fence opens/closes: any pending table must be flushed first
        (when (member (agent-cl.render:md-line-kind md) '(:fence-start :fence-end))
          (flush-table))
        (render-one-md-line (agent-cl.render:md-line-kind md)
                            (agent-cl.render:md-line-text md))))
  *fence*)

;;;; --- whole-block renderer for the non-streaming fallback path ---------
(defun render-md-text (text)
  "整段渲染（非流式 fallback / /load 载入会话）。"
  (setf *fence* :fence-out)
  (setf *table-buf* nil)
  (let ((start 0))
    (loop for nl = (position #\Newline text :start start)
          while nl
          do (progn
               ;; NB: an EMPTY line (start = nl) must still be rendered: the old
               ;; guard (when (< start nl) ...) silently dropped every blank line,
               ;; so paragraph breaks disappeared on the non-streaming path.
               (advance-fence-with-line (subseq text start nl))
               (setf start (1+ nl)))
          finally (when (< start (length text))
                    (advance-fence-with-line (subseq text start))))
    ;; A table that ends the text must still reach the screen: it lives in
    ;; *TABLE-BUF* until something flushes it, and nothing did at EOF.
    (flush-table)
    (setf *fence* :fence-out)))

;;;; --- streaming buffer (complete lines are flushed as they arrive) -----
(defvar *tok-buf* (make-string-output-stream))
(defun reset-tokens ()
  "开始一轮：清空缓冲，并把围栏状态与表格缓冲归零（避免跨回合残留）。"
  (setf *tok-buf* (make-string-output-stream))
  (setf *fence* :fence-out)
  (setf *table-buf* nil))
(defun flush-tokens ()
  "回合结束：冲刷未成行的残片与待输出的表格，然后归零围栏状态。"
  (let ((rest (get-output-stream-string *tok-buf*)))
    (when (plusp (length rest))
      (advance-fence-with-line rest)))
  (flush-table)                      ; 表格在回合结束时收尾
  (setf *fence* :fence-out)          ; 回合结束强制合拢，屏障跨回合泄漏
  (terpri)
  (finish-output))

(defun repl-on-token (text)
  "流式到达：攒到整行就渲染，未完成的行留在缓冲。"
  (write-string text *tok-buf*)
  (let ((s (get-output-stream-string *tok-buf*)))
    (loop for nl = (position #\Newline s)
          while nl
          do (progn
               (advance-fence-with-line (subseq s 0 nl))
               (setf s (subseq s (1+ nl))))
          finally (write-string s *tok-buf*))
    (finish-output)))

(defun flush-token-prefix ()
  "Render whatever the streaming buffer still holds (a partial line), keeping the
  fence state.

  Called before any out-of-band row (a tool result, a sub-agent step): those used
  to print IMMEDIATELY while the model's pending partial line stayed buffered, so
  the screen showed the tool row BEFORE the assistant text that preceded it."
  (let ((rest (get-output-stream-string *tok-buf*)))
    (when (plusp (length rest))
      (advance-fence-with-line rest)
      (terpri)
      (finish-output))))

;; END REPL RENDER PATCH

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

(defvar *repl-session* nil
  "当前 REPL 会话对象（agent-cl.session:session）。")
(defvar *persisted-count* 0
  "已写入当前会话的消息条数（增量持久用）。")

(defun import-transcript (agent path)
  "Load a JSONL transcript into AGENT and make the session log agree with it.
  IMPORT-TRANSCRIPT used to leave *PERSISTED-COUNT* untouched, so the next
  REPL-PERSIST-TURN appended the WHOLE loaded history into the session again —
  duplicate events on every /load."
  (let (msgs)
    (with-open-file (i path :direction :input :external-format :utf-8)
      (loop for line = (read-line i nil nil)
            while line
            for trimmed = (string-trim '(#\Return #\Space) line)
            unless (string= trimmed "")
              do (push (wire->message (agent-cl.core:decode-to-plist trimmed)) msgs)))
    (setf msgs (sanitize-loaded-messages (nreverse msgs)))
    (setf (agent-cl.loop:agent-messages agent) msgs)
    ;; the imported history is now the agent's state, so record it as such:
    ;; persist it into the CURRENT session and mark it as already written
    (setf *persisted-count* 0)
    (repl-persist-turn agent)
    (format t "~&已载入 ~a 条消息（已写入当前会话 ~a）~%"
            (length msgs) (agent-cl.session:session-id *repl-session*))))

(defun clean-input-line (line)
  "Normalize one line of user input: strip surrounding whitespace including CR.

  \\r matters: `read-line` splits on #\\Newline only, so on Windows (CRLF input,
  piped or pasted text) every line arrived with a trailing #\\Return. `/help\\r`
  was an unknown command and a line containing only \\r counted as a real prompt
  instead of the blank-line no-op."
  (string-trim '(#\Space #\Tab #\Return #\Newline) (or line "")))

(defun session-root ()
  "REPL 会话根目录：~/.agent-cl/sessions/（仓库外，随用户持久）。"
  (let* ((home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
         (base (if (and home (plusp (length home)))
                   (uiop:ensure-directory-pathname home)
                   ;; no HOME at all (a service context, a stripped environment):
                   ;; falling back to the cwd keeps sessions working instead of
                   ;; erroring out inside ENSURE-DIRECTORY-PATHNAME.
                   (progn
                     (format t "~&[session] 警告：未找到 USERPROFILE/HOME，会话写入当前目录 ~a~%"
                             (uiop:getcwd))
                     (uiop:getcwd))))
         (d (merge-pathnames ".agent-cl/sessions/" base)))
    (ensure-directories-exist d)
    d))

(defparameter *prune-min-age-seconds* 3600
  "Only prune a session directory that has been empty for at least this long, so
  a session another REPL instance is still starting up is never deleted.")

(defun prune-empty-sessions ()
  "Delete session directories that contain no events.jsonl. These come from
  sessions that were created but never written to (e.g. a repl started and
  exited without a real turn); they hold no user data, only clutter the list.

  Only directories older than *prune-min-age-seconds* are touched, and the
  current session is never touched: a session mid-startup (another REPL instance,
  or this one before its first checkpoint) is EMPTY for a moment, and pruning it
  broke that instance's writes."
  (let ((root (session-root))
        (now (get-universal-time))
        (current (and *repl-session* (agent-cl.session:session-id *repl-session*))))
    (dolist (sub (uiop:subdirectories root))
      (let ((id (car (last (pathname-directory sub)))))
        (unless (and current (string= id current))
          (unless (uiop:file-exists-p (merge-pathnames "events.jsonl" sub))
            (let ((mtime (ignore-errors (file-write-date sub))))
              (when (and mtime (> (- now mtime) *prune-min-age-seconds*))
                (ignore-errors
                 (uiop:delete-directory-tree sub :validate t
                                                 :if-does-not-exist :ignore))))))))))

(defun repl-new-session (agent)
  "开始一个新会话：把当前 agent 消息清空并绑定新 session id。
  新建后立即写入一条 session-start checkpoint，使会话马上落盘、出现在
  /sessions 列表里（否则只建目录不写文件，用户看不到它）。"
  (when (and agent *repl-session*)
    ;; 先把旧会话落一个 checkpoint，便于审计结束点
    (handler-case
        (agent-cl.session:save-checkpoint *repl-session* "switched-away")
      (error () nil)))
  (setf *repl-session* (agent-cl.session:make-session
                        :directory (session-root)))
  (setf *persisted-count* 0)
  (when agent (setf (agent-cl.loop:agent-messages agent) nil))
  ;; materialise the session so it shows up immediately in /sessions
  (handler-case
      (agent-cl.session:save-checkpoint *repl-session* "session-start")
    (error () nil))
  (format t "~&[session] 新会话 ~a~%" (agent-cl.session:session-id *repl-session*))
  *repl-session*)

(defun repl-persist-turn (agent)
  "把 agent-messages 里尚未落盘的消息追加进当前会话（增量，事件日志式）。"
  (let ((s *repl-session*))
    (when (and s agent)
      (let ((msgs (agent-cl.loop:agent-messages agent))
            (failed 0)
            (first-error nil))
        (loop for m in (nthcdr (min *persisted-count* (length msgs)) msgs)
              do (handler-case
                     (agent-cl.session:persist-message s m)
                   (error (e)
                     ;; Count instead of swallowing: a full disk or a locked
                     ;; session file used to lose the whole turn in silence.
                     (incf failed)
                     (unless first-error (setf first-error e)))))
        (when (plusp failed)
          (format t "~&[session] 警告：~a 条消息未能写入会话（~a）：~a~%"
                  failed (agent-cl.session:session-path s) first-error))
        (setf *persisted-count* (length msgs))))))

(defun repl-session-line (s)
  "一行会话预览：id · 消息数 · 首句 · 最后事件时间。"
  (let* ((n (agent-cl.session:session-message-count s))
         (first-user (agent-cl.session:session-first-user-text s))
         (ts (agent-cl.session:session-last-ts s))
         (preview (if first-user
                      (subseq first-user 0 (min 40 (length first-user)))
                      "(空)")))
    (format nil "~a  [~a 条]  ~a  ~a"
            (agent-cl.session:session-id s) n preview
            (or ts ""))))

(defun sorted-session-ids ()
  "Session ids, most-recently-active first (falls back to id order)."
  (let ((ids (agent-cl.session:session-ids (session-root))))
    (sort ids #'string> :key (lambda (id)
                               (handler-case
                                   (or (agent-cl.session:session-last-ts
                                        (agent-cl.session:load-session
                                         id :directory (session-root)))
                                       "")
                                 (error () ""))))))

(defun repl-list-sessions ()
  "List sessions with an index so they can be picked by number. Returns the
  ordered id list (same order as printed)."
  (let ((ids (sorted-session-ids)))
    (if ids
        (progn
          (format t "~&已保存会话（共 ~a 个）：~%" (length ids))
          (loop for id in ids for i from 1
                do (handler-case
                       (let ((s (agent-cl.session:load-session
                                 id :directory (session-root))))
                         (format t "  ~2d) ~a~%" i (repl-session-line s)))
                     (error (e)
                       (format t "  ~2d) ~a  [读取失败: ~a]~%" i id e)))))
        (format t "~&还没有已保存的会话。~%"))
    ids))

(defun repl-use-interactive (agent)
  "Prompt for a session by number/id/prefix (like /use but interactive)."
  (let ((ids (repl-list-sessions)))
    (when ids
      (format t "选择会话编号（直接回车取消）: ")
      (finish-output)
      (let* ((line (read-line *standard-input* nil :eof))
             (line (if (eq line :eof) "" (string-trim '(#\Space #\Tab) line))))
        (multiple-value-bind (id status)
            (agent-cl.session:resolve-session-choice line ids)
          (case status
            (:ok          (repl-use-session agent id))
            (:none        (format t "~&[session] 已取消。~%"))
            (:ambiguous   (format t "~&[session] 前缀匹配到多个会话，请用编号或完整 id。~%"))
            (:out-of-range (format t "~&[session] 编号超出范围（1..~a）。~%" (length ids)))))))))

(defparameter *replay-count* 30
  "How many recent user/assistant turns to echo back after switching sessions.")

(defun replay-conversation (turns)
  "Echo remembered TURNS ((role . content) ...) so the user can see the prior
  conversation. Tool traffic is already filtered upstream; text goes through the
  same markdown path as live output."
  (when turns
    (format t "~&── 历史回放（最近 ~a 条）──~%" (length turns))
    (dolist (entry turns)
      (let ((role (car entry)) (text (cdr entry)))
        (format t "~&~a~%"
                (if *color*
                    (if (eq role :user) (ansi 34 "CL-USER>") (ansi 36 "AGENT>"))
                    (if (eq role :user) "CL-USER>" "AGENT>")))
        (render-md-text text)
        (terpri)))
    (format t "~&── 历史回放结束 ──~%")))

(defun repl-use-session (agent id)
  "切换到 ID 会话：先存当前会话，再载入目标历史续聊，并回显最近若干轮。"
  (repl-persist-turn agent)   ; 存当前 agent 未落盘消息
  (let ((s (agent-cl.session:load-session id :directory (session-root))))
    (setf *repl-session* s)
    (let ((history (agent-cl.session:replayed-messages s)))
      (setf (agent-cl.loop:agent-messages agent) history)
      (setf *persisted-count* (length history))
      (format t "~&[session] 已切换到 ~a（~a 条历史）~%"
              id (length history))
      ;; echo the recent conversation so the user sees what was said
      (let ((turns (agent-cl.session:last-conversation-turns
                    history *replay-count*)))
        (replay-conversation turns)
        (when (> (length (agent-cl.session:conversation-entries history))
                 *replay-count*)
          (format t "~&（更早的对话未显示；共 ~a 条）~%"
                  (length (agent-cl.session:conversation-entries history))))))))

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
  (format t "  /new           另起新会话（当前自动存档）~%")
  (format t "  /sessions      列出已保存会话~%")
  (format t "  /use [编号|id|前缀]  切换会话；不带参数则交互选择~%")
  (format t "  /color on|off  开/关 ANSI 颜色~%")
  (format t "  /usage         显示模型 / token 用量 / 工作路径~%")
  (format t "  /model [名称]  从 API 拉取模型列表并选择；带名称则直接切换~%")
  (format t "  /demo          markdown 渲染 + 状态栏自检~%")
  (format t "  /engine new|legacy  渲染引擎新/旧（旧=无代码围栏高亮）~%")
  (format t "  /footer on|off 开/关底部常驻状态栏与输入栏~%")
  (format t "  /plan <task>    Plan-then-Execute：拆步骤→逐步执行→汇总~%")
  (format t "  /quit 或 /exit 退出~%"))

(defun repl-command (line agent)
  (let* ((trim (clean-input-line line))
         (sp (position #\Space trim))
         (cmd (if sp (subseq trim 0 sp) trim))
         (rest (and sp (string-trim '(#\Space #\Tab) (subseq trim (1+ sp))))))
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
       (repl-new-session agent))
      ((string= cmd "/sessions")
       (repl-list-sessions))
      ((string= cmd "/use")
       (if (and rest (plusp (length rest)))
           ;; explicit pick: number / unique id prefix / full id
           (let ((ids (sorted-session-ids)))
             (multiple-value-bind (id status)
                 (agent-cl.session:resolve-session-choice rest ids)
               (case status
                 (:ok           (repl-use-session agent id))
                 (:none         (format t "~&[session] 未找到匹配：~a~%" rest))
                 (:ambiguous    (format t "~&[session] 前缀匹配到多个会话：~a~%" rest))
                 (:out-of-range (format t "~&[session] 编号超出范围（1..~a）。~%" (length ids))))))
           ;; no argument: interactive picker
           (repl-use-interactive agent)))
      ((string= cmd "/plan")
       (if (null rest)
           (format t "~&用法: /plan <task>（需要一个任务描述）~%")
           (let ((f (find-symbol "RUN-PLANNED" "AGENT-CL.PLAN")))
             (if f
                 (handler-case
                     (progn
                       (funcall f agent rest #'repl-on-token)
                       (flush-tokens))   ; 步骤流式残段此刻落屏，勿留到下一轮被 reset-tokens 丢弃
                   (error (e)
                     (format t "~&[plan] 失败: ~a~%" e)))
                 (format t "~&/plan 不可用：scripts/plan.lisp 未加载~%")))))
      ((string= cmd "/color")
       (setf *color* (not (and rest (string= rest "off"))))
       (format t "~&颜色: ~a~%" (if *color* "on" "off")))
      ((string= cmd "/usage")
       (format t "~&模型: ~a~%  提示(^): ~a tokens~%  生成(v): ~a tokens~%  合计: ~a tokens~%  工作路径: ~a~%"
               (agent-cl.loop:agent-model agent)
               (agent-cl.loop:agent-usage-prompt agent)
               (agent-cl.loop:agent-usage-completion agent)
               (agent-cl.loop:agent-usage-total agent)
               (current-workdir)))
      ((string= cmd "/model")
       (if (and rest (plusp (length rest)))
           (repl-set-model agent rest)
           (repl-choose-model agent)))
      ((string= cmd "/demo")
       (format t "~&── markdown 渲染自检（引擎: ~a）──~%" *engine*)
       (dolist (l '("# 一级标题"
                    "## 二级标题"
                    "### 三级标题"
                    "普通段落，含 **加粗** 与 `行内代码`，还有 [可点链接](https://example.com)。"
                    "- 无序项 A"
                    "- 无序项 B"
                    "  - 嵌套子项 B1"
                    "1. 有序第一"
                    "2. 有序第二"
                    "---"
                    "| 名称 | 类型 | 用量 | 状态 |"
                    "| --- | --- | --- | --- |"
                    "| read | tool | 12 | ok |"
                    "| parser.lisp | file | 340 | ok |"
                    "| web.search | tool | 1 | fail |"
                    "表格后的一行普通文本。"
                    "```lisp"
                    "(defun hello () (format t \"hi\"))"
                    "```"))
         (advance-fence-with-line l))
       (flush-tokens)
       (render-status-bar agent))
      ((string= cmd "/engine")
       (cond
         ((and rest (string= rest "new")) (setf *engine* :new))
         ((and rest (string= rest "legacy")) (setf *engine* :legacy))
         (t (format t "~&用法: /engine new|legacy；当前 ~a~%" *engine*)))
       (when (member rest '("new" "legacy") :test #'string=)
         (format t "~&渲染引擎: ~a~%" *engine*)))
      ((string= cmd "/footer")
       (cond
         ((and rest (string= rest "off"))
          (footer-disable)
          (format t "~&[repl] 底部状态栏已关闭（/footer on 恢复）。~%"))
         ((and rest (string= rest "on"))
          (if (footer-enable)
              (format t "~&[repl] 底部状态栏/输入栏已固定。~%")
              (format t "~&[repl] 此终端无法固定底部（输出被重定向或无 VT 支持）。~%")))
         (t (format t "~&底部状态栏: ~a（用法: /footer on|off）~%"
                    (if (footer-active-p) "on" "off")))))

      ((or (string= cmd "/quit") (string= cmd "/exit"))
       (uiop:quit 0))
      (t (format t "~&未知命令 ~a（/help 查看）~%" cmd)))))


(defun slashed-name (path)
  "PATH with native separators turned into '/', so a Windows cwd and a HOME
  spelled with the other separator still compare equal."
  (substitute #\/ #\\ (namestring path)))

(defun current-workdir ()
  "Working directory shown in the status bar. Shortens the user's home prefix
  to ~.

  The prefix test used to be a bare STRING-EQUAL over the first N characters, so
  HOME=C:/Users/bob also matched C:/Users/bobby/... and the bar printed a
  nonsense '~y/...'; it also compared native (backslash) strings against a HOME
  that may be spelled with either separator."
  (let* ((cwd (slashed-name (uiop:getcwd)))
         (home (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME")))
         (home (and home (plusp (length home))
                    (string-right-trim "/\\" (substitute #\/ #\\ home)))))
    (if (and home
             (>= (length cwd) (length home))
             (string-equal home cwd :end1 (length home) :end2 (length home))
             ;; the boundary must be a separator (or the whole path), never a
             ;; shared prefix of a longer directory name
             (or (= (length cwd) (length home))
                 (char= (char cwd (length home)) #\/)))
        (concatenate 'string "~" (subseq cwd (length home)))
        cwd)))

(defun fetch-model-ids ()
  "GET <base-url>/models and return the list of model ids, or NIL on any
  failure (no key, offline, package missing). Uses dexador if available."
  (handler-case
      (let ((get (find-symbol "GET" "DEXADOR"))
            (key (uiop:getenv "AGENT_CL_API_KEY")))
        (when get
          (let* ((url (concatenate 'string
                                   (string-right-trim "/" *base-url*) "/models"))
                 (body (funcall get url
                                :headers (list (cons "Authorization"
                                                     (concatenate 'string "Bearer " key)))
                                :read-timeout 30)))
            (agent-cl.llm:parse-models-response body))))
    (error (e) (format t "~&[model] 拉取失败: ~a~%" e) nil)))

(defun repl-choose-model (agent)
  "Interactive model picker: fetch ids, list them, set agent-model on choice.
  Keeps the conversation history; only the model name changes."
  (let ((ids (fetch-model-ids)))
    (cond
      ((null ids)
       (format t "~&[model] 无法获取模型列表（离线或未配置 key）。可用 /model <名称> 直接指定。~%"))
      (t
       (format t "~&可用模型（共 ~a 个，当前 ~a）：~%" (length ids)
               (agent-cl.loop:agent-model agent))
       (loop for id in ids for i from 1
             do (format t "  ~2d) ~a~a~%" i id
                        (if (string= id (agent-cl.loop:agent-model agent))
                            "  ← 当前" "")))
       (format t "选择模型编号（直接回车取消）: ")
       (finish-output)
       (let* ((line (read-line *standard-input* nil :eof))
              (line (if (eq line :eof) "" (string-trim '(#\Space #\Tab) line))))
         (multiple-value-bind (id status)
             (agent-cl.session:resolve-session-choice line ids)
           (case status
             (:ok (set-model agent id))
             (:none (format t "~&[model] 已取消。~%"))
             (:ambiguous (format t "~&[model] 名称有歧义。~%"))
             (:out-of-range (format t "~&[model] 编号超出范围（1..~a）。~%" (length ids))))))))))

(defun set-model (agent id)
  "Switch the agent's model, keeping the conversation. Prints confirmation."
  (setf (agent-cl.loop:agent-model agent) id)
  (format t "~&[model] 已切换到 ~a（对话历史保留）~%" id))

(defun repl-set-model (agent name)
  "Set the model by exact name (or unique prefix if the list is fetchable)."
  (let ((ids (fetch-model-ids)))
    (if ids
        (multiple-value-bind (id status)
            (agent-cl.session:resolve-session-choice name ids)
          (case status
            (:ok (set-model agent id))
            (:none (set-model agent name))   ; let the API reject unknown names
            (:ambiguous (format t "~&[model] ~a 匹配多个模型，请输入完整名。~%" name))
            (:out-of-range (set-model agent name))))
        (set-model agent name))))

(defun cache-hit-rate (agent)
  "Prompt-cache hit ratio in [0,1], or NIL when the provider never reported
  cache fields (so the caller can omit the display rather than fake it)."
  (when (agent-cl.loop:agent-cache-seen agent)
    (let ((h (agent-cl.loop:agent-cache-hit agent))
          (m (agent-cl.loop:agent-cache-miss agent)))
      (when (plusp (+ h m)) (/ h (float (+ h m)))))))

(defun status-bar-text (agent)
  "One-line status: model | token split (auto-scaled) | optional cache
  hit-rate | working dir. Returned as a string rather than printed, so the
  plain prompt path and the pinned bottom footer render identical content."
  (let* ((model (agent-cl.loop:agent-model agent))
         (pin   (agent-cl.loop:agent-usage-prompt agent))
         (pout  (agent-cl.loop:agent-usage-completion agent))
         (tot   (agent-cl.loop:agent-usage-total agent))
         (rate  (cache-hit-rate agent))
         (dir   (current-workdir))
         (tk #'agent-cl.core:format-token-count))
    (format nil "  ~a ~a | ~a ~a ~a~@[ ~a~] | ~a"
            (ansi 90 "──")                          ; dim rule
            (ansi 36 (format nil "~a" model))
            (ansi 32 (format nil "^~a" (funcall tk pin)))   ; prompt (in)
            (ansi 33 (format nil "v~a" (funcall tk pout)))  ; completion (out)
            (ansi 90 (format nil "=~a tok" (funcall tk tot)))
            (when rate
              (ansi 35 (format nil "cache ~d%" (round (* rate 100)))))
            (ansi 90 dir))))

(defun render-status-bar (agent)
  "Print the status bar above the prompt. Fallback path, used when no console
  footer can be pinned."
  (format t "~&~a~%" (status-bar-text agent)))

;;; ---------------------------------------------------------------------------
;;; pinned bottom footer：状态栏 + 输入行常驻终端底部
;;; ---------------------------------------------------------------------------
;;; When the REPL owns a real console we reserve the bottom two rows as a footer
;;; (status above, input below) and restrict scrolling to the rows above it, so
;;; transcript output scrolls underneath a bar that never moves. Without a
;;; console — output redirected, no VT support, or a screen too short — the
;;; footer stays off and the previous "status bar, then prompt" flow is intact.

(defparameter *repl-prompt* "CL-USER> ")

(defvar *footer* nil
  "Plist describing the pinned footer, or NIL when disabled:
  :cols :rows :handle :scroll-top :scroll-bottom :status-row :input-row.")

(defun footer-active-p () (and *footer* t))

(defun footer-enable ()
  "Pin the footer at the bottom. T on success; NIL (no side effects) when the
  terminal cannot support it."
  (let ((cap (agent-cl.render:probe-console)))
    (when cap
      (let* ((rows   (getf cap :rows))
             (cols   (getf cap :cols))
             (handle (getf cap :handle))
             (layout (agent-cl.render:footer-layout rows))
             (vt     (or (getf cap :vt)
                         (and handle (agent-cl.render:console-enable-vt handle)))))
        (when (and layout vt (integerp cols) (plusp cols))
          (setf *footer* (append (list :cols cols :rows rows :handle handle)
                                 layout))
          (format t "~a" (agent-cl.render:set-scroll-region
                          (getf *footer* :scroll-top)
                          (getf *footer* :scroll-bottom)))
          ;; park inside the scrolling region and emit a real newline, so the
          ;; stream's column bookkeeping (fresh-line / ~&) agrees with the screen
          (format t "~a" (agent-cl.render:cursor-to
                          (getf *footer* :scroll-bottom) 1))
          (terpri)
          (finish-output)
          t)))))

(defun footer-disable ()
  "Hand the terminal back: full-screen scrolling, cursor below the footer.
  Safe to call when the footer was never enabled."
  (when *footer*
    (let ((f *footer*))
      (setf *footer* nil)
      (format t "~a" (agent-cl.render:reset-scroll-region))
      (format t "~a" (agent-cl.render:cursor-to (getf f :rows) 1))
      (terpri)
      (finish-output))))

(defun footer-draw-status (agent)
  "Repaint the status row in place. The saved/restored cursor means this never
  disturbs the position transcript output flows from."
  (format t "~a~a~a~a~a"
          (agent-cl.render:save-cursor)
          (agent-cl.render:cursor-to (getf *footer* :status-row) 1)
          (agent-cl.render:erase-line)
          (agent-cl.render:pad-ansi-line (status-bar-text agent)
                                         (getf *footer* :cols))
          (agent-cl.render:restore-cursor)))

(defun footer-draw-prompt ()
  "Clear the input row and show the prompt on it."
  (format t "~a~a~a"
          (agent-cl.render:cursor-to (getf *footer* :input-row) 1)
          (agent-cl.render:erase-line)
          *repl-prompt*)
  (finish-output))

(defun footer-begin-output (&optional echo)
  "Park the cursor at the bottom of the scrolling region before a turn prints.
  ECHO re-prints an accepted input line there, because the transient input row
  is erased at the next prompt and would otherwise vanish from the transcript."
  (format t "~a" (agent-cl.render:cursor-to (getf *footer* :scroll-bottom) 1))
  (if echo
      (format t "~a~a~%" *repl-prompt* echo)
      (terpri))
  (finish-output))

(defun footer-refresh-geometry ()
  "Re-probe the console and, when the terminal was resized, re-pin the footer.
  The footer's row/column numbers were captured once at enable time, so after a
  resize the status bar padded to the OLD width and the cursor addressing pointed
  at rows that no longer existed. Returns T when the geometry changed."
  (when *footer*
    (let ((cap (agent-cl.render:probe-console)))
      (when (and cap (integerp (getf cap :cols)) (plusp (getf cap :cols)))
        (let ((cols (getf cap :cols)) (rows (getf cap :rows)))
          (when (or (/= cols (getf *footer* :cols))
                    (/= rows (getf *footer* :rows)))
            (let ((layout (agent-cl.render:footer-layout rows)))
              (if layout
                  (progn
                    (setf *footer* (append (list :cols cols :rows rows
                                                 :handle (getf cap :handle))
                                           layout))
                    (format t "~a" (agent-cl.render:set-scroll-region
                                    (getf *footer* :scroll-top)
                                    (getf *footer* :scroll-bottom)))
                    (finish-output)
                    t)
                  ;; the screen became too short to pin a footer
                  (footer-disable)
                  nil))))))))

(defun ask-turn (agent line)
  (unwind-protect
       (progn
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
    ;; 每轮结束：持久化本轮消息。状态栏由主循环在提示符处常驻打印，这里不再打。
    (repl-persist-turn agent)))

;; ---------------------------------------------------------------------------
;; 主循环
;; ---------------------------------------------------------------------------
(handler-case
    (unwind-protect
         (let ((agent (make-repl-agent)))
           (prune-empty-sessions)     ; 清掉“建了没写”的空会话目录
           (repl-new-session agent)
           (format t "~&Agent-CL REPL — 输入任务；/help 查看命令；/quit 退出；Ctrl-C 中断。~%")
           (format t "流式输出 + Markdown 着色已启用（/color off 关闭）。~%")
           ;; pin the status bar + input line to the bottom when the console can
           ;; take it; otherwise the inline status bar above the prompt remains
           (footer-enable)
           (when (footer-active-p)
             (format t "~&[repl] 状态栏与输入栏已固定在底部（/footer off 关闭）。~%"))
            (loop
              ;; a resized terminal invalidates the pinned footer's geometry
              (footer-refresh-geometry)
              (if (footer-active-p)
                  (progn (footer-draw-status agent) (footer-draw-prompt))
                  (progn (render-status-bar agent)
                         (format t "~&~a" *repl-prompt*)
                         (finish-output)))
              (let ((line (read-line *standard-input* nil :eof)))
                (cond
                  ;; EOF (stdin closed / piped input ended) -> exit
                  ((eq line :eof)
                   (when (footer-active-p) (footer-begin-output nil))
                   (return))
                  ;; blank line = no-op (SLIME-style): just re-prompt, never exit
                  ((string= (clean-input-line line) "")
                   (when (footer-active-p) (footer-begin-output nil)))
                  (t
                   ;; the transient input row is erased at the next prompt, so
                   ;; copy the accepted line into the scrolling transcript
                   (when (footer-active-p) (footer-begin-output line))
                   (if (char= (char line 0) #\/)
                       (repl-command line agent)
                       (handler-case
                           (ask-turn agent line)
                         (sb-sys:interactive-interrupt ()
                           ;; Ctrl-C DURING A TURN interrupts the turn — which is
                           ;; what the banner promises. It used to fall through to
                           ;; the outer handler and quit the whole REPL, throwing
                           ;; away a live session. Ctrl-C at the prompt (where
                           ;; READ-LINE is waiting) still exits.
                           (agent-cl.loop:stop agent)
                           (flush-tokens)
                           (format t "~&[repl] 已中断本轮（会话保留；在提示符处 Ctrl-C 退出）。~%")
                           (repl-persist-turn agent)))))))))
      ;; always hand the terminal back, including on Ctrl-C
      (footer-disable))
  ;; Ctrl-C 优雅退出（--script 下无调试器）
  (sb-sys:interactive-interrupt ()
    (footer-disable)
    (format t "~&[repl] 已退出（Ctrl-C）。~%")
    (finish-output)
    (uiop:quit 0)))
