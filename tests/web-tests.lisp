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
  (let ((old (uiop:getenv "TAVILY_API_KEY"))
        (keyfile (merge-pathnames "test-web-key-order.txt"
                                  (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (sb-posix:setenv "TAVILY_API_KEY" "ENVKEY" 1)
           (is-equal "EXPLICIT" (agent-cl.web:tavily-key "EXPLICIT"))
           (is-equal "ENVKEY" (agent-cl.web:tavily-key nil))
           (is-equal "ENVKEY" (agent-cl.web:tavily-key ""))
           ;; An empty explicit value must fall through, not win. This assertion
           ;; used to be a tautology — (is-equal "X" "X") — which passed forever
           ;; while proving nothing. *TAVILY-KEY-FILE* is bound so the fallback
           ;; chain is deterministic regardless of the developer's real key file.
           (with-open-file (s keyfile :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
             (write-string "FILEKEY" s))
           (sb-posix:setenv "TAVILY_API_KEY" "" 1)
           (let ((agent-cl.web:*tavily-key-file* keyfile))
             (is-equal "FILEKEY" (agent-cl.web:tavily-key ""))
             (is-equal "FILEKEY" (agent-cl.web:tavily-key nil))
             (is-equal "EXPLICIT" (agent-cl.web:tavily-key "EXPLICIT")))
           ;; no explicit, no env, no key file -> NIL (caller must report how to set one)
           (let ((agent-cl.web:*tavily-key-file* (merge-pathnames "absent-key.txt"
                                                                  (uiop:temporary-directory))))
             (is-equal nil (agent-cl.web:tavily-key ""))
             (is-equal nil (agent-cl.web:tavily-key nil))))
      (ignore-errors (delete-file keyfile))
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

;;; ---------------------------------------------------------------------------
;;; cost guards: cache + per-process budget
;;;
;;; Regression for a real incident: an agent fleet burned a whole Tavily quota
;;; because every web.search was a billable request, with no cache and no cap.
;;; These tests inject a counting stub so the logic is verified offline.
;;; ---------------------------------------------------------------------------

(defmacro with-search-stub ((counter-var) &body body)
  "Run BODY with web.search's network call replaced by a counting stub that
  returns one well-formed result, and a clean cache/budget. LET* is required:
  the stub closes over COUNTER-VAR, which parallel LET would not have bound yet."
  `(let* ((,counter-var 0)
          (agent-cl.web:*search-fetcher*
            (lambda (backend query max)
              (declare (ignore backend max))
              (incf ,counter-var)
              (list (list :TITLE (format nil "R~a" ,counter-var)
                          :URL (format nil "http://x/~a" ,counter-var)
                          :CONTENT "snip"))))
          (agent-cl.web:*web-search-budget* 20)
          (agent-cl.web:*search-cache-ttl* 3600))
     (agent-cl.web:reset-web-search-budget)
     (agent-cl.web:clear-search-cache)
     ,@body))

(deftest web-search-cache-avoids-repeat-requests
  (with-search-stub (calls)
    (multiple-value-bind (c1 s1) (agent-cl.web:web-search
                                  (list :QUERY "common lisp" :MAX-RESULTS 3) nil)
      (is-equal :ok s1)
      (ok (search "R1" c1) "first call hits the backend")
      (is-equal 1 calls))
    ;; identical query -> served from cache, no second billable request
    (multiple-value-bind (c2 s2) (agent-cl.web:web-search
                                  (list :QUERY "common lisp" :MAX-RESULTS 3) nil)
      (is-equal :ok s2)
      (ok (search "R1" c2))
      (is-equal 1 calls)
      (is-equal "R1" (subseq c2 0 (min 2 (length c2)))))
    ;; different max-results is a different cache key -> one more request
    (agent-cl.web:web-search (list :QUERY "common lisp" :MAX-RESULTS 5) nil)
    (is-equal 2 calls)))

(deftest web-search-budget-stops-spending
  (with-search-stub (calls)
    (let ((agent-cl.web:*web-search-budget* 2))
      (agent-cl.web:reset-web-search-budget)
      ;; two distinct queries consume the whole budget
      (is-equal :ok (nth-value 1 (agent-cl.web:web-search (list :QUERY "q1") nil)))
      (is-equal :ok (nth-value 1 (agent-cl.web:web-search (list :QUERY "q2") nil)))
      (is-equal 2 calls)
      (is-equal 0 (agent-cl.web:search-budget-left))
      ;; third distinct query must be refused WITHOUT issuing a request
      (multiple-value-bind (c3 s3) (agent-cl.web:web-search (list :QUERY "q3") nil)
        (is-equal :error s3)
        (ok (search "上限" c3) "explains the budget was hit")
        (is-equal 2 calls) "no further billable request")
      ;; a cached query still works for free even at zero budget
      (multiple-value-bind (c4 s4) (agent-cl.web:web-search (list :QUERY "q1") nil)
        (is-equal :ok s4)
        (ok (search "R1" c4))
        (is-equal 2 calls)))))

(deftest web-search-budget-nil-means-unlimited
  (with-search-stub (calls)
    (let ((agent-cl.web:*web-search-budget* nil))
      (agent-cl.web:reset-web-search-budget)
      (dotimes (i 5)
        (agent-cl.web:web-search (list :QUERY (format nil "unlimited-~a" i)) nil))
      (is-equal 5 calls)
      (ok (> (agent-cl.web:search-budget-left) 1000) "unlimited reports a huge remaining"))))

(deftest web-search-disabled-cache-always-refetches
  (with-search-stub (calls)
    (let ((agent-cl.web:*search-cache-ttl* 0))
      (agent-cl.web:clear-search-cache)
      (agent-cl.web:web-search (list :QUERY "nocache" :MAX-RESULTS 1) nil)
      (agent-cl.web:web-search (list :QUERY "nocache" :MAX-RESULTS 1) nil)
      (is-equal 2 calls "ttl 0 disables caching"))))

(deftest web-search-trips-breaker-on-quota-error
  "A provider quota rejection (Tavily 432 'usage limit') must stop the process
  from spending more: subsequent distinct queries are refused WITHOUT a request,
  instead of hammering a dead endpoint."
  (let* ((agent-cl.web:*web-search-budget* nil)   ; unlimited budget -> only the breaker can stop us
         (agent-cl.web:*search-cache-ttl* 3600)
         (requests 0)
         (agent-cl.web:*search-fetcher*
           (lambda (backend query max)
             (declare (ignore backend query max))
             (incf requests)
             (error "web http 432: {\"detail\":{\"error\":\"This request exceeds your plan's set usage limit.\"}}"))))
    (agent-cl.web:reset-web-search-budget)
    (agent-cl.web:clear-search-cache)
    ;; 1) the first call fails with a quota error -> breaker trips
    (multiple-value-bind (c1 s1) (agent-cl.web:web-search (list :QUERY "q1") nil)
      (is-equal :error s1)
      (ok (search "熔断" c1) "tells the caller it tripped")
      (is-equal 1 requests))
    (ok agent-cl.web:*web-search-tripped* "breaker flag is set")
    ;; 2) a NEW query must be refused with no further request
    (multiple-value-bind (c2 s2) (agent-cl.web:web-search (list :QUERY "q2") nil)
      (is-equal :error s2)
      (ok (search "熔断" c2))
      (is-equal 1 requests) "no second billable request")
    ;; 3) resetting clears the breaker
    (agent-cl.web:reset-web-search-budget)
    (ok (not agent-cl.web:*web-search-tripped*) "reset clears the breaker")))

;;; ---------------------------------------------------------------------------
;;; per-delegated-child allowance
;;;
;;; Children keep web.search, but each child session has its own small cap so a
;;; single runaway child cannot drain the plan; the parent is unaffected.
;;; ---------------------------------------------------------------------------

(defun stub-fetcher (counter)
  "A fetch stub that increments COUNTER (a cons whose car is the tally)."
  (lambda (backend query max)
    (declare (ignore backend max))
    (incf (car counter))
    (list (list :TITLE "R" :URL "http://x/1" :CONTENT "snip"))))

(deftest web-search-child-gets-its-own-smaller-cap
  (let* ((tally (list 0))
         (agent-cl.web:*search-fetcher* (stub-fetcher tally))
         (agent-cl.web:*web-search-budget* nil)      ; process budget out of the way
         (agent-cl.web:*search-cache-ttl* 3600)
         (parent (make-agent :transport (make-mock-transport) :tools nil))
         (child-agent (make-agent :transport (make-mock-transport) :tools nil
                                  :depth 1)))
    (agent-cl.web:reset-web-search-budget)
    (agent-cl.web:reset-child-search-budget 2)   ; 2 real searches per child
    (agent-cl.web:clear-search-cache)
    ;; child: two distinct queries are allowed
    (is-equal :ok (nth-value 1 (agent-cl.web:web-search
                                (list :QUERY "c1") child-agent)))
    (is-equal :ok (nth-value 1 (agent-cl.web:web-search
                                (list :QUERY "c2") child-agent)))
    (is-equal 2 (car tally))
    (is-equal 0 (agent-cl.web:child-budget-left child-agent))
    ;; child: third distinct query refused WITHOUT a request
    (multiple-value-bind (c3 s3) (agent-cl.web:web-search
                                  (list :QUERY "c3") child-agent)
      (is-equal :error s3)
      (ok (search "子 agent" c3) "explains the child allowance")
      (is-equal 2 (car tally)) "no third request from the child")
    ;; parent is NOT limited by the child cap
    (is-equal :ok (nth-value 1 (agent-cl.web:web-search
                                (list :QUERY "p1") parent)))
    (is-equal 3 (car tally) "parent still searches")))

(deftest web-search-top-level-context-is-not-a-child
  ;; a nil ctx (direct tool call) and a depth-0 agent both count as top-level
  (let* ((tally (list 0))
         (agent-cl.web:*search-fetcher* (stub-fetcher tally))
         (agent-cl.web:*web-search-budget* nil)
         (agent-cl.web:*search-cache-ttl* 3600)
         (parent (make-agent :transport (make-mock-transport) :tools nil)))
    (agent-cl.web:reset-web-search-budget)
    (agent-cl.web:reset-child-search-budget 1)
    (agent-cl.web:clear-search-cache)
    (ok (not (agent-cl.web:child-agent-p nil)) "nil ctx is top-level")
    (ok (not (agent-cl.web:child-agent-p parent)) "depth 0 is top-level")
    (ok (agent-cl.web:child-agent-p
         (make-agent :transport (make-mock-transport) :tools nil :depth 1))
        "depth 1 is a child")
    ;; a top-level ctx is not capped by the (1-search) child allowance
    (dotimes (i 3)
      (is-equal :ok (nth-value 1 (agent-cl.web:web-search
                                  (list :QUERY (format nil "top-~a" i)) parent))))
    (is-equal 3 (car tally))))
