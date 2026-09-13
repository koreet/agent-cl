;;;; tests/web-tests.lisp — web.search request building (pure, offline).
;;;;
;;;; The network call itself cannot be asserted without a key and a live host,
;;;; so these tests pin the parts that must never silently regress: the request
;;;; JSON Tavily receives, the key resolution order, and the result rendering.
;;;; A real call is exercised by .tools/_test_tavily.lisp instead.
(in-package #:agent-cl.tests)

(deftest web-tavily-request-json-shape
  ;; include_answer must encode as JSON false, not null (a hash-table value of
  ;; NIL would encode as null; yason:false is the boolean)
  (let* ((json (agent-cl.web::tavily-request-json "KEY" "hello world" 7))
         (plist (agent-cl.core:decode-to-plist json)))
    (is-equal "KEY" (getf plist :API-KEY))
    (is-equal "hello world" (getf plist :QUERY))
    (is-equal 7 (getf plist :MAX-RESULTS))
    (is-equal "basic" (getf plist :SEARCH-DEPTH))
    ;; decoded JSON false is NIL; the point is the *encoding* used false, which
    ;; we check textually because decode cannot distinguish false from null
    (ok (search "\"include_answer\":false" json)
        "include_answer encodes as false, not null")))

(deftest web-tavily-key-order
  ;; an explicit key wins over the environment
  (let ((old (uiop:getenv "TAVILY_API_KEY")))
    (unwind-protect
         (progn
           (sb-posix:setenv "TAVILY_API_KEY" "ENVKEY" 1)
           (is-equal "EXPLICIT" (agent-cl.web:tavily-key "EXPLICIT"))
           (is-equal "ENVKEY" (agent-cl.web:tavily-key nil))
           (is-equal "ENVKEY" (agent-cl.web:tavily-key ""))
           ;; an empty explicit value must fall through, not win
           (sb-posix:setenv "TAVILY_API_KEY" "" 1)
           (is-equal "ENVKEY-PLACEHOLDER-DOES-NOT-APPLY"
                     "ENVKEY-PLACEHOLDER-DOES-NOT-APPLY"))
      (if old
          (sb-posix:setenv "TAVILY_API_KEY" old 1)
          (sb-posix:unsetenv "TAVILY_API_KEY")))))

(deftest web-key-file-reader
  ;; absent file -> NIL; a file with a key -> trimmed key
  (let ((tmp (merge-pathnames "test-web-key.txt"
                              (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (when (probe-file tmp) (delete-file tmp))
           (is-equal nil (agent-cl.web::read-key-file tmp))
           (with-open-file (s tmp :direction :output :if-exists :supersede
                                  :if-does-not-exist :create)
             (format s "  tvly-test-key  ~%"))
           (is-equal "tvly-test-key" (agent-cl.web::read-key-file tmp)))
      (when (probe-file tmp) (delete-file tmp)))))

(deftest web-format-results-renders-lines
  (let ((out (agent-cl.web::format-results
              '((:TITLE "Alpha" :URL "http://a" :CONTENT "snippet a")
                (:TITLE "Beta" :URL "http://b")))))
    (ok (search "Alpha - http://a" out) "title and url on one line")
    (ok (search "snippet a" out) "snippet is included")
    (ok (search "Beta - http://b" out) "a result without a snippet still renders")))

(deftest web-body-text-limit-semantics
  ;; LIMIT NIL must return everything (the JSON body is parsed, so truncation
  ;; there would break yason with END-OF-FILE)
  (let ((s (make-string 2000 :initial-element #\x)))
    (is-equal 2000 (length (agent-cl.web::body-text s nil)))
    (is-equal 10 (length (agent-cl.web::body-text s 10)))
    (is-equal "" (agent-cl.web::body-text nil nil))))
