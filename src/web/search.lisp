;;;; src/web/search.lisp — web.search: 免 key 的网页检索（DuckDuckGo Lite）。
;;;;
;;;; 需要运行环境能发起 HTTPS GET（正常机器: ql 装 dexador；本仓库在 repl/smoke
;;;; 里由 dev-http 提供）。无 dexador 时工具返回明确错误而非崩溃。
(defpackage #:agent-cl.web
  (:use #:cl)
  (:export #:web-search #:ddg-fetch-results))

(in-package #:agent-cl.web)

(defun ddg-url (query max)
  (declare (ignore max))
  (format nil "https://html.duckduckgo.com/html/?q=~a"
          (substitute #\+ #\Space query)))

(defun html-entity-decode (s)
  (let ((out (make-string-output-stream)))
    (loop with i = 0 and n = (length s)
          while (< i n)
          do (let ((ch (char s i)))
               (cond
                 ((and (char= ch #\&) (< (+ i 3) n))
                  (cond ((and (char= (char s (1+ i)) #\l) (char= (char s (+ i 2)) #\t))
                         (write-char #\< out) (incf i 4))
                        ((and (char= (char s (1+ i)) #\g) (char= (char s (+ i 2)) #\t))
                         (write-char #\> out) (incf i 4))
                        ((and (char= (char s (1+ i)) #\a) (char= (char s (+ i 2)) #\m)
                              (char= (char s (+ i 3)) #\p))
                         (write-char #\& out) (incf i 5))
                        (t (write-char ch out) (incf i))))
                 (t (write-char ch out) (incf i))))
          finally (return (get-output-stream-string out)))))

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

(defun ddg-fetch-results (query max)
  (parse-links (http-get (ddg-url query max)) max))

(defun web-search (args ctx)
  "按 query 检索网页，返回至多 max_results 条「标题 - URL」。"
  (declare (ignore ctx))
  (let* ((query (getf args :QUERY))
         (max (or (getf args :MAX-RESULTS) 5)))
    (unless query
      (return-from web-search (values "missing :query" :error)))
    (handler-case
        (let ((links (ddg-fetch-results query max)))
          (if links
              (values (format nil "~{~a~%~}" links) :ok)
              (values "没有找到相关结果" :error)))
      (error (e) (values (format nil "检索失败: ~a" e) :error)))))
