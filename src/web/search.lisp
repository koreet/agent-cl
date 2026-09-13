;;;; src/web/search.lisp — web.search: 网页检索。
;;;;
;;;; Backend: Tavily (https://api.tavily.com/search) via a single HTTPS POST.
;;;; It returns clean JSON ({query, results:[{title,url,content,score}]}), which
;;;; avoids the HTML-scraping fragility of the old DuckDuckGo path — that path
;;;; is kept below as :ddg for environments without a key, and is *opt-in*.
;;;;
;;;; The API key is never hard-coded: it is read from the tool argument, then
;;;; TAVILY_API_KEY, then ~/.agent-cl/tavily-key.txt (outside the repo, like the
;;;; model key). Without a key the tool returns a clear error, not a crash.
(defpackage #:agent-cl.web
  (:use #:cl)
  (:export #:web-search #:ddg-fetch-results #:tavily-fetch-results
           #:*tavily-key-file* #:tavily-key
           ;; cost guards: result cache + per-process search budget
           #:*web-search-budget* #:*web-search-calls* #:*search-cache-ttl*
           #:*search-fetcher* #:*web-search-tripped*
           #:search-budget-left #:reset-web-search-budget #:clear-search-cache
           ;; per-delegated-child allowance
           #:*child-search-budget* #:child-budget-left
           #:reset-child-search-budget #:child-agent-p))

(in-package #:agent-cl.web)

(defun pct-encode (s)
  "Percent-encode a query string (UTF-8), leaving unreserved chars intact."
  (with-output-to-string (out)
    (loop for ch across s
          for code = (char-code ch)
          do (cond ((or (and (char<= #\a ch #\z))
                        (and (char<= #\A ch #\Z))
                        (and (char<= #\0 ch #\9))
                        (member ch '(#\- #\_ #\. #\~)))
                    (write-char ch out))
                   (t (let ((b (sb-ext:string-to-octets (string ch) :external-format :utf-8)))
                        (loop for x across b
                              do (format out "%~2,'0X" x))))))))

(defun ddg-url (query max)
  (declare (ignore max))
  (format nil "https://html.duckduckgo.com/html/?q=~a" (pct-encode query)))

(defun html-entity-decode (s)
  "Decode the HTML entities that show up in scraped text (lt, gt, amp,
  quot, apos, nbsp) plus decimal numeric entities, then trim."
  (let ((out (make-string-output-stream)))
    (loop with i = 0 and n = (length s)
          while (< i n)
          do (let ((ch (char s i)))
               (cond
                 ((and (char= ch #\&) (< (+ i 3) n))
                  (let ((rest (subseq s (1+ i) (min n (+ i 8)))))
                    (cond
                      ((string-prefix-p "lt;" rest)
                       (write-char #\< out) (incf i 4))
                      ((string-prefix-p "gt;" rest)
                       (write-char #\> out) (incf i 4))
                      ((string-prefix-p "amp;" rest)
                       (write-char #\& out) (incf i 5))
                      ((string-prefix-p "quot;" rest)
                       (write-char #\" out) (incf i 6))
                      ((string-prefix-p "apos;" rest)
                       (write-char #\' out) (incf i 6))
                      ((string-prefix-p "nbsp;" rest)
                       (write-char #\Space out) (incf i 6))
                      ((and (char= (char rest 0) #\#) (plusp (length rest)))
                       ;; &#NN; numeric (decimal)
                       (let ((semi (position #\; rest :start 1)))
                         (if (and semi
                                  (every (lambda (c)
                                           (digit-char-p c))
                                         (subseq rest 1 semi)))
                             (progn
                               (write-char
                                (code-char (parse-integer
                                            (subseq rest 1 semi)))
                                out)
                               (incf i (+ 1 semi 1)))
                             (progn (write-char ch out) (incf i)))))
                      (t (write-char ch out) (incf i)))))
                 (t (write-char ch out) (incf i))))
          finally (return (get-output-stream-string out)))))

(defun string-prefix-p (prefix s)
  "T when S starts with PREFIX."
  (and (>= (length s) (length prefix))
       (string= prefix s :end2 (length prefix))))

(defun strip-tags (s)
  (let ((out (make-string-output-stream))
        (i 0) (n (length s)) (in-tag nil))
    (loop while (< i n)
          do (let ((ch (char s i)))
               (cond (in-tag
                      (when (char= ch #\>) (setf in-tag nil))
                      (incf i))
                     ((char= ch #\<) (setf in-tag t) (incf i))
                     (t (write-char ch out) (incf i)))))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (html-entity-decode (get-output-stream-string out)))))

(defun anchor-info (s start)
  "从 START 找 <a href=URL>title</a>，返回 (values href title end) 或 NIL。"
  (let* ((h0 (search "href=\"" s :start2 start))
         (q1 (and h0 (+ h0 6)))
         (q2 (and q1 (position #\" s :start q1)))
         (title-start (and q2 (position #\> s :start q2)))
         (title-end (and title-start (search "</a>" s :start2 title-start))))
    (if (and q2 title-start title-end)
        (let ((title (strip-tags (subseq s (1+ title-start) title-end))))
          (if (zerop (length title))
              nil
              (values (subseq s q1 q2) title title-end)))
        nil)))

(defun parse-links (html max)
  (let ((out nil) (pos 0))
    (loop while (and (< (length out) max)
                     (setf pos (search "<a " html :start2 pos)))
          do (multiple-value-bind (href title end)
                 (anchor-info html pos)
               (if href
                   (progn (push (cons title href) out)
                          (setf pos (1+ end)))
                   (setf pos (+ pos 3)))))
    (nreverse out)))

(defun http-get (url)
  "用 dexador GET（动态解析，避免编译期依赖）。"
  (let ((pkg (find-package :dexador)))
    (unless pkg
      (error "web.search 需要 dexador（请先安装并加载，或在本仓库 repl/smoke 中运行）"))
    (let ((get (find-symbol "GET" pkg)))
      (unless get (error "dexador:GET 不可用"))
      (multiple-value-bind (body status)
          (funcall get url :headers '(("User-Agent" . "agent-cl/0.1"))
                   :force-string t :read-timeout 60 :connect-timeout 30)
        (unless (and status (<= 200 status 299))
          (error "web http ~a" status))
        body))))

(defun dexador-error-detail (condition)
  "When CONDITION is dexador's http-request-failed, return (values status body);
  otherwise NIL. Symbols are resolved at runtime so this file never has a
  compile-time dependency on dexador being loaded."
  (let* ((pkg (find-package "DEXADOR.ERROR"))
         (cls (and pkg (find-symbol "HTTP-REQUEST-FAILED" pkg))))
    (when (and cls (typep condition cls))
      (let ((rs (find-symbol "RESPONSE-STATUS" pkg))
            (rb (find-symbol "RESPONSE-BODY" pkg)))
        (values (and rs (ignore-errors (funcall rs condition)))
                (and rb (ignore-errors (funcall rb condition))))))))

(defun http-post-json (url json headers)
  "POST JSON to URL via dexador (resolved at runtime, same style as HTTP-GET).
  Returns the FULL response body; a non-2xx status is turned into an error
  carrying the provider's own message, so the agent can act on it."
  (let ((pkg (find-package :dexador)))
    (unless pkg
      (error "web.search 需要 dexador（请先安装并加载，或在本仓库 repl/smoke 中运行）"))
    (let ((post (find-symbol "POST" pkg)))
      (unless post (error "dexador:POST 不可用"))
      (let ((body nil) (status nil))
        (handler-bind
            ((error (lambda (condition)
                      (multiple-value-bind (st detail) (dexador-error-detail condition)
                        (when st
                          (error "web http ~a: ~a" st (body-text detail)))))))
          (setf (values body status)
                (funcall post url :content json :headers headers
                         :force-string t :read-timeout 60 :connect-timeout 30)))
        (unless (and status (<= 200 status 299))
          (error "web http ~a: ~a" status (body-text body)))
        ;; the whole body: the caller parses it as JSON, so truncating here would
        ;; hand yason half an object and it would die with END-OF-FILE
        (body-text body nil)))))

(defun body-text (body &optional limit)
  "Best-effort printable text from a dexador body, which may be a string, a
  byte vector, a decoding stream, or NIL. LIMIT NIL means the whole thing:
  use that whenever the result is going to be parsed rather than shown."
  (flet ((cut (s) (if limit (subseq s 0 (min limit (length s))) s)))
    (handler-case
        (cond
          ((null body) "")
          ((stringp body) (cut body))
          ((streamp body)
           (let ((out (make-string-output-stream)))
             (loop repeat (or limit most-positive-fixnum)
                   for ch = (read-char body nil nil)
                   while ch
                   do (write-char ch out))
             (get-output-stream-string out)))
          ((and (vectorp body) (not (stringp body)))
           (cut (map 'string (lambda (b) (code-char (logand b 255))) body)))
          (t (cut (princ-to-string body))))
      (error () "<unreadable http body>"))))

;;; ---------------------------------------------------------------------------
;;; Tavily (default backend)
;;; ---------------------------------------------------------------------------

(defparameter *tavily-key-file*
  (merge-pathnames ".agent-cl/tavily-key.txt"
                   (uiop:ensure-directory-pathname
                    (or (uiop:getenv "USERPROFILE") (uiop:getenv "HOME") "/")))
  "Fallback key location, deliberately outside the repo so it is never
  committed. Created by hand; see tavily-key.")

(defun read-key-file (path)
  "Trimmed first line of PATH, or NIL when the file is absent/empty."
  (when (and path (probe-file path))
    (let ((line (string-trim '(#\Space #\Tab #\Newline #\Return)
                             (with-open-file (s path :external-format :utf-8)
                               (or (read-line s nil "") "")))))
      (when (plusp (length line)) line))))

(defun tavily-key (&optional explicit)
  "Resolve the Tavily key: EXPLICIT argument, then TAVILY_API_KEY, then the key
  file. NIL when none is configured (the caller then reports how to set one)."
  (or (and explicit (plusp (length explicit)) explicit)
      (let ((env (uiop:getenv "TAVILY_API_KEY")))
        (and env (plusp (length env)) env))
      (read-key-file *tavily-key-file*)))

(defun tavily-request-json (key query max)
  "Tavily /search request body. Built as a hash-table so json-encode emits a
  proper JSON object (NIL would otherwise encode as null, not false)."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "api_key" ht) key
          (gethash "query" ht) query
          (gethash "max_results" ht) max
          (gethash "search_depth" ht) "basic"
          (gethash "include_answer" ht) yason:false)
    (agent-cl.core:json-encode ht)))

(defun safe-text (value)
  "Printable, control-character-free text for a provider-supplied field.

  Provider data is untrusted. A non-string value (a number, a cons) used to raise
  inside the caller's handler, so a SUCCESSFUL search was reported as
  \"检索失败: The value 42 is not of type SEQUENCE\" and the good results were
  dropped (and not cached, so a retry spent quota again). ESC/C0 characters are
  stripped as well: a title carrying them reached the terminal and the log
  (OSC-52 clipboard writes, title spoofing, cursor control)."
  (let ((s (typecase value
             (null "")
             (string value)
             (t (princ-to-string value)))))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (remove-if (lambda (c) (< (char-code c) 32)) s))))

(defun format-results (results)
  "Render decoded Tavily results (a list of plists) as the agent-facing text:
  one title-and-url line per result, with the snippet indented beneath when
  present."
  (format nil "~{~a~^~%~}"
          (loop for r in results
                for title = (let ((t1 (safe-text (getf r :TITLE))))
                              (if (plusp (length t1)) t1 "(无标题)"))
                for url = (or (getf r :URL) "")
                for content = (getf r :CONTENT)
                collect (with-output-to-string (o)
                          (format o "~a - ~a" title url)
                          (when (and content (plusp (length content)))
                            (format o "~%    ~a"
                                    (subseq content 0 (min 300 (length content)))))))))

;;; ---------------------------------------------------------------------------
;;; Cost control: result cache + per-process budget
;;;
;;; Every web.search call is a REAL, BILLABLE Tavily request. An agent (or a
;;; fleet of delegated child agents) can easily issue hundreds of them while
;;; iterating, which drains a monthly quota. Two guards here:
;;;   1. CACHE  — identical (backend, query, max-results) within TTL is served
;;;      from memory and costs nothing;
;;;   2. BUDGET — a hard cap on real network searches per process; once hit the
;;;      tool returns a clear error instead of spending more quota.
;;; Cache hits never count against the budget, and requests that fail before
;;; leaving the process (e.g. no API key) do not count either.
;;; ---------------------------------------------------------------------------

(defparameter *web-search-budget* 20
  "Max REAL network searches per process. NIL = unlimited. Cache hits and
  no-key/no-request failures do not count. Raise with reset-web-search-budget.")

(defparameter *web-search-calls* 0
  "Real network searches issued so far in this process.")

(defparameter *search-cache-ttl* 3600
  "Seconds a cached result set stays valid. 0 disables caching.")

(defvar *search-cache* (make-hash-table :test 'equal)
  "CACHE-KEY -> (universal-time . results).")

(defvar *search-fetcher* nil
  "Test seam: when bound to (lambda (backend query max) -> results), it replaces
  the real network call so cache/budget logic can be verified offline.")

(defparameter *search-cache-max-entries* 200
  "Upper bound on cached result sets. The cache existed to save quota, but an
  agent iterating over generated queries could grow it without limit (each entry
  holding a full result set) for the life of the process.")

(defun normalize-query (query)
  "Canonical cache/identity form of QUERY: trimmed, case-folded, and with runs of
  whitespace collapsed. Without this, \"  DeepSeek  API \" and \"deepseek api\"
  were separate cache entries AND separate billable requests."
  (let* ((s (string-trim '(#\Space #\Tab #\Newline #\Return) (or query "")))
         (out (make-string-output-stream))
         (pending-space nil)
         (wrote nil))
    ;; a local flag rather than FILE-POSITION: not every implementation supports
    ;; file-position on a string output stream
    (loop for ch across s
          do (if (member ch '(#\Space #\Tab #\Newline #\Return))
                 (setf pending-space t)
                 (progn (when (and pending-space wrote)
                          (write-char #\Space out))
                        (setf pending-space nil
                              wrote t)
                        (write-char (char-downcase ch) out))))
    (get-output-stream-string out)))

(defun cache-key (backend query max)
  ;; the BACKEND is normalized too: "tavily", "Tavily" and "TAVILY" used to be
  ;; three separate cache entries AND three separate billable requests.
  (list (string-downcase (string-trim '(#\Space #\Tab) (or backend "")))
        (normalize-query query)
        max))

(defun cache-lookup (key)
  "Cached results for KEY when still fresh, else NIL (expired entries drop)."
  (let ((entry (gethash key *search-cache*)))
    (when entry
      (destructuring-bind (ts . results) entry
        (if (and (plusp *search-cache-ttl*)
                 (< (- (get-universal-time) ts) *search-cache-ttl*))
            results
            (progn (remhash key *search-cache*) nil))))))

(defun cache-store (key results)
  (when (plusp *search-cache-ttl*)
    ;; Bounded cache: when full, drop the entries that have been in there longest
    ;; (their timestamps are the oldest), then add the new one.
    (when (and *search-cache-max-entries*
               (>= (hash-table-count *search-cache*) *search-cache-max-entries*)
               (null (gethash key *search-cache*)))
      (let ((stale (loop for k being the hash-keys of *search-cache*
                           using (hash-value v)
                         collect (cons k (car v)))))
        (dolist (pair (subseq (sort stale #'< :key #'cdr)
                              0 (max 1 (floor (length stale) 4))))
          (remhash (car pair) *search-cache*))))
    (setf (gethash key *search-cache*)
          (cons (get-universal-time) results)))
  results)

(defun clear-search-cache ()
  "Drop every cached result set (used by tests and by users who want fresh data)."
  (clrhash *search-cache*))

(defvar *web-search-tripped* nil
  "Set when the provider says the plan/quota is exhausted; further real
  searches are refused until the counter is reset.")

(defun search-budget-left ()
  "Real searches still allowed in this process (a large number when unlimited)."
  (if *web-search-budget*
      (max 0 (- *web-search-budget* *web-search-calls*))
      most-positive-fixnum))

(defun reset-web-search-budget (&optional budget)
  "Reset the call counter and clear a tripped breaker; set a new BUDGET when
  supplied."
  (setf *web-search-calls* 0)
  (setf *web-search-tripped* nil)
  (when budget (setf *web-search-budget* budget))
  *web-search-budget*)

;;; --- per-child-agent search budget -----------------------------------------
;;; Delegated child agents keep web.search (it is genuinely useful for focused
;;; research), but each child session gets its own hard cap so one runaway
;;; child cannot drain the plan on its own. The parent is governed by the
;;; process budget above; a child is governed by BOTH.

(defparameter *child-search-budget* 3
  "Max REAL searches a single delegated child agent may issue. NIL = no extra
  per-child cap (the process budget still applies).")

(defvar *child-search-usage* (make-hash-table :test 'eq :weakness :key)
  "Child agent object -> real searches it has issued. KEY-WEAK, so a child agent
  that has finished can be collected: with a plain EQ table the table itself kept
  every child that ever searched alive for the life of the process. Cleared by
  reset-child-search-budget.")

(defun agent-depth-safe (ctx)
  "Depth of the agent in CTX (0 = top-level). Resolved at runtime because this
  file is compiled before agent-cl.loop exists. A nil / non-agent CTX (direct
  tool call in tests) counts as top-level."
  (let* ((pkg (find-package "AGENT-CL.LOOP"))
         (fn (and pkg (find-symbol "AGENT-DEPTH" pkg))))
    (if fn
        (or (ignore-errors (funcall fn ctx)) 0)
        0)))

(defun child-agent-p (ctx)
  (and ctx (> (agent-depth-safe ctx) 0)))

(defun child-searches-used (ctx)
  (or (gethash ctx *child-search-usage*) 0))

(defun note-child-search (ctx)
  (when (child-agent-p ctx)
    (setf (gethash ctx *child-search-usage*)
          (1+ (child-searches-used ctx)))))

(defun child-budget-left (ctx)
  "Real searches this child may still issue (a large number when uncapped)."
  (if (and (child-agent-p ctx) *child-search-budget*)
      (max 0 (- *child-search-budget* (child-searches-used ctx)))
      most-positive-fixnum))

(defun reset-child-search-budget (&optional budget)
  "Forget per-child usage (and optionally set a new per-child cap)."
  (clrhash *child-search-usage*)
  (when budget (setf *child-search-budget* budget))
  *child-search-budget*)

(defun quota-status-p (message status)
  "True when STATUS is 429/432, or MESSAGE contains a quota phrase. An explicit
  status is authoritative; the text test is the fallback."
  (or (and (integerp status) (member status '(429 432)))
      (let ((m (string-downcase (or message ""))))
        ;; Phrase matching, not bare \"/432/\": a substring test fired on any
        ;; message that merely CONTAINED those digits (a byte count, a result id,
        ;; a URL), tripping the breaker and pinning the budget to zero.
        (some (lambda (needle) (search needle m))
              '("usage limit" "rate limit" "quota" "exceeds your plan"
                "too many requests" "http 429" "http 432"
                "error 429" "error 432" "status 429" "status 432")))))

(defun quota-error-p (message)
  "True when MESSAGE looks like a provider quota/rate-limit rejection, so we
  trip the breaker instead of letting the agent hammer a dead endpoint."
  (quota-status-p message nil))

(defun trip-search-breaker (message)
  "Stop spending: mark the quota as exhausted and pin the budget to what has
  already been used."
  (setf *web-search-tripped* t)
  (when *web-search-budget*
    (setf *web-search-budget* *web-search-calls*))
  message)

(defun render-search-results (backend results)
  "Backend-agnostic rendering of RESULTS into the agent-facing text."
  (if (string-equal backend "ddg")
      (format nil "~{~a - ~a~%~}"
              (loop for pair in results
                    for t1 = (safe-text (car pair))
                    for u = (safe-text (cdr pair))
                    append (list t1 u)))
      (format-results results)))

(defun search-backend-ready-p (backend)
  "True when BACKEND can actually issue a request (so we never count a call
  that fails before leaving the process). A bound *SEARCH-FETCHER* stub counts
  as ready: it stands in for the network in tests."
  (if (string-equal backend "ddg")
      t
      (or *search-fetcher*
          (and (tavily-key) t))))

(defun call-search-backend (backend query max)
  "Issue the real (billable) search through BACKEND, honoring the test seam."
  (if *search-fetcher*
      (funcall *search-fetcher* backend query max)
      (if (string-equal backend "ddg")
          (ddg-fetch-results query max)
          (tavily-fetch-results query max))))

(defun tavily-fetch-results (query max)
  "Query Tavily and return a list of plists (:TITLE :URL :CONTENT :SCORE).
  Signals a descriptive error when no key is configured or the call fails."
  (let ((key (tavily-key)))
    (unless key
      (error "web.search 需要 Tavily API key：设置环境变量 TAVILY_API_KEY，或把 key 写入 ~a"
             *tavily-key-file*))
    (let* ((json (http-post-json "https://api.tavily.com/search"
                                 (tavily-request-json key query max)
                                 '(("Content-Type" . "application/json"))))
           (decoded (agent-cl.core:json-decode json)))
      (or (getf (agent-cl.core:object-to-plist decoded) :RESULTS)
          '()))))

(defun ddg-fetch-results (query max)
  (parse-links (http-get (ddg-url query max)) max))

(defun web-search (args ctx)
  "按 query 检索网页，返回至多 max_results 条「标题 - URL」(+ 摘要行)。

  Backend is Tavily (JSON, needs a key). Pass :backend \"ddg\" to use the
  keyless DuckDuckGo HTML scraper instead.

  Cost guards: identical queries within *SEARCH-CACHE-TTL* are served from
  cache, and at most *WEB-SEARCH-BUDGET* real requests are issued per process
  (cache hits are free); exceeding the budget returns an error rather than
  spending more quota."
  (let* ((query (getf args :QUERY))
         (max (or (getf args :MAX-RESULTS) 5))
         (backend (or (getf args :BACKEND) "tavily")))
    (unless query
      (return-from web-search (values "missing :query" :error)))
    (let ((key (cache-key backend query max)))
      ;; 1) cache first: same query within TTL costs nothing
      (let ((cached (cache-lookup key)))
        (when cached
          (return-from web-search
            (values (render-search-results backend cached) :ok))))
      ;; 2a) quota already exhausted -> refuse immediately, no request at all
      (when *web-search-tripped*
        (return-from web-search
          (values "web.search 已熔断：上一次调用返回额度/限流错误（如 Tavily 432 usage limit）。请升级套餐或稍后 reset-web-search-budget，本进程不再发起检索。"
                  :error)))
      ;; 2b) per-child gate: a delegated child has its own small allowance
      (when (and (search-backend-ready-p backend)
                 (child-agent-p ctx)
                 (zerop (child-budget-left ctx)))
        (return-from web-search
          (values (format nil "web.search 子 agent 检索配额已用尽（每个子 agent 最多 ~a 次真实检索）。请基于已有信息作答，或由主 agent 补充检索。"
                          *child-search-budget*)
                  :error)))
      ;; 2c) budget gate: refuse before spending any quota
      (when (and (search-backend-ready-p backend)
                 (zerop (search-budget-left)))
        (return-from web-search
          (values (format nil "web.search 已达本次运行上限（~a 次真实检索；缓存命中不计）。提升 agent-cl.web:*web-search-budget* 或 reset-web-search-budget 后继续。"
                          *web-search-budget*)
                  :error)))
      ;; 3) real request (counted only when it actually goes out)
      (handler-case
          (let ((results (if (search-backend-ready-p backend)
                             (progn (incf *web-search-calls*)
                                    (note-child-search ctx)
                                    (call-search-backend backend query max))
                             (call-search-backend backend query max))))
            (if results
                (values (render-search-results
                         backend (cache-store key results))
                        :ok)
                (values "没有找到相关结果" :error)))
        (error (e)
          (let* ((status (and (typep e 'agent-cl.core:transport-error)
                              (agent-cl.core:transport-error-status e)))
                 (msg (format nil "~a" e)))
            ;; An explicit HTTP status is authoritative: string-matching the
            ;; message is a fallback, not the primary signal.
            (if (quota-status-p msg status)
                (values (format nil "检索失败（已熔断，后续检索不再发出）: ~a"
                                (trip-search-breaker msg))
                        :error)
                (values (format nil "检索失败: ~a" msg) :error))))))))
