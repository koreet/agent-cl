;;;; tests/store-hardening-tests.lisp — regression tests for the data-layer audit.
;;;;
;;;; Scope: memory key encoding, code.exec interpreter selection, the session
;;;; event log (timestamps, unknown roles, lenient reads, previews), the web
;;;; search cache/breaker, and self-improvement rollback reporting.
(in-package #:agent-cl.tests)

;;; ---------------------------------------------------------------------------
;;; memory keys must be injective
;;; ---------------------------------------------------------------------------

(deftest memory-key-encoding-is-injective
  "\"a b\" hex-escaped to \"a20b\", which collided with the literal key \"a20b\":
  one memory silently overwrote the other. The escape introducer is escaped now."
  (let ((a (agent-cl.tools::memory-key-stem "a b"))
        (b (agent-cl.tools::memory-key-stem "a20b"))
        (c (agent-cl.tools::memory-key-stem "a-b"))
        (d (agent-cl.tools::memory-key-stem "a_b"))
        (e (agent-cl.tools::memory-key-stem "a/b")))
    (is-equal "a_20b" a)
    (is-equal "a20b" b)
    (is-equal "a-b" c)
    (is-equal "a_5fb" d)
    (is-equal "a_2fb" e)
    ;; all distinct
    (is-equal 5 (length (remove-duplicates (list a b c d e) :test #'string=)))))

(deftest memory-key-encoding-survives-case-and-devices
  "Windows filenames are case-insensitive, so 'ABC' and 'abc' shared one file;
  and a key like 'con' produced an unusable device name."
  (is-equal "abc" (agent-cl.tools::memory-key-stem "abc"))
  (is-equal "_41_42_43" (agent-cl.tools::memory-key-stem "ABC"))
  (ok (not (string-equal (agent-cl.tools::memory-key-stem "ABC")
                         (agent-cl.tools::memory-key-stem "abc"))))
  (is-equal "_con" (agent-cl.tools::memory-key-stem "con"))
  (is-equal "_5fcon" (agent-cl.tools::memory-key-stem "_con"))
  ;; empty key still maps to something usable
  (ok (plusp (length (agent-cl.tools::memory-key-stem "")))))

(deftest memory-store-recall-roundtrip-keeps-distinct-keys
  "End to end over the real filesystem: two keys that used to collide must now
  hold different values."
  (let ((k1 "collide test a b")
        (k2 "collide test a20b"))
    (unwind-protect
         (progn
           (multiple-value-bind (c s) (agent-cl.tools:call-tool
                                       "memory.set" (list :KEY k1 :VALUE "first"))
             (declare (ignore c))
             (is-equal :ok s))
           (multiple-value-bind (c s) (agent-cl.tools:call-tool
                                       "memory.set" (list :KEY k2 :VALUE "second"))
             (declare (ignore c))
             (is-equal :ok s))
           (multiple-value-bind (c1 s1) (agent-cl.tools:call-tool
                                         "memory.recall" (list :KEY k1))
             (multiple-value-bind (c2 s2) (agent-cl.tools:call-tool
                                           "memory.recall" (list :KEY k2))
               (is-equal :ok s1)
               (is-equal :ok s2)
               (is-equal "first" c1)
               (is-equal "second" c2)
               (ok (not (string= c1 c2)) "the two keys must not share a file"))))
      (dolist (f (list (agent-cl.tools::memory-key-file k1)
                       (agent-cl.tools::memory-key-file k2)))
        (ignore-errors (delete-file f))))))

;;; ---------------------------------------------------------------------------
;;; code.exec
;;; ---------------------------------------------------------------------------

(deftest code-exec-uses-the-interpreter-extension
  "Every temp file was written as .tmp, so a script carried no hint of its
  language and `sh` handed a .tmp file to cmd on Windows."
  (multiple-value-bind (argv ext) (agent-cl.tools::interpreter-command "python" "print(1)" "f")
    (declare (ignore argv))
    (is-equal ".py" ext))
  (multiple-value-bind (argv ext) (agent-cl.tools::interpreter-command "sbcl" "(print 1)" "f")
    (declare (ignore argv))
    (is-equal ".lisp" ext))
  ;; unsupported language -> no argv (reported, not guessed)
  (multiple-value-bind (argv ext) (agent-cl.tools::interpreter-command "ruby" "x" "f")
    (declare (ignore ext))
    (is-equal nil argv)))

(deftest code-exec-sh-does-not-fake-success
  "On Windows `sh` used to run `cmd /c <script>`, which cannot execute a shell
  script: the model was told its code had run. With no POSIX shell available the
  tool must say so."
  (if (agent-cl.tools::find-unix-shell)
      (is-equal :ok (nth-value 1 (agent-cl.tools:call-tool
                                  "code.exec"
                                  (list :CODE "echo hello-sh" :LANGUAGE "sh"))))
      (multiple-value-bind (content status)
          (agent-cl.tools:call-tool "code.exec" (list :CODE "echo hi" :LANGUAGE "sh"))
        (is-equal :error status)
        (ok (search "POSIX shell" content)))))

;;; ---------------------------------------------------------------------------
;;; session event log
;;; ---------------------------------------------------------------------------

(deftest session-message-events-carry-a-timestamp
  "SESSION-LAST-TS read :TS from events, but message events had no timestamp at
  all, so a session's age and ordering were invisible."
  (let* ((dir (merge-pathnames (format nil ".tools/tmp/sess-~a/"
                                       (agent-cl.core:uuid-string))
                               (uiop:getcwd)))
         (s (agent-cl.session:make-session :directory dir)))
    (unwind-protect
         (progn
           (agent-cl.session:persist-message s (user-message "hi"))
           (ok (agent-cl.session:session-last-ts s) "a message event needs a ts")
           (ok (getf (first (agent-cl.session::session-events s)) :TYPE)))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest session-unknown-role-does-not-break-replay
  "An unknown role hit ECASE and aborted the WHOLE replay: one odd line made the
  session unloadable."
  (let* ((dir (merge-pathnames (format nil ".tools/tmp/sess-~a/"
                                       (agent-cl.core:uuid-string))
                               (uiop:getcwd)))
         (s (agent-cl.session:make-session :directory dir)))
    (unwind-protect
         (progn
           (agent-cl.session:persist-message s (user-message "hello"))
           ;; a plausible-but-unknown event kind (future version, other tool)
           (agent-cl.session:session-append s '(:type "message" :role "judge"
                                                :content "hmm"))
           (agent-cl.session:persist-message s (assistant-message "world"))
           (let ((msgs (agent-cl.session:replayed-messages s)))
             (is-equal 2 (length msgs) "the two known messages survive")
             (is-equal "hello" (msg-content (first msgs)))
             (is-equal "world" (msg-content (second msgs)))))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest session-replay-survives-invalid-utf8
  "A strict UTF-8 read raised on one stray byte, which defeated the entire
  skip-the-corrupt-line design by failing the whole replay."
  (let* ((dir (merge-pathnames (format nil ".tools/tmp/sess-~a/"
                                       (agent-cl.core:uuid-string))
                               (uiop:getcwd)))
         (s (agent-cl.session:make-session :directory dir))
         (path (agent-cl.session:session-path s)))
    (unwind-protect
         (progn
           (agent-cl.session:persist-message s (user-message "ok"))
           ;; append a line with a raw byte that is not valid UTF-8 on its own
           (with-open-file (out path :direction :output
                                     :if-exists :append
                                     :element-type '(unsigned-byte 8))
             (write-sequence (map '(vector (unsigned-byte 8))
                                  #'char-code
                                  (format nil "{\"type\":\"message\",\"role\":\"user\",\"content\":\"~c~c\"}~%"
                                          (code-char 200) (code-char 250)))
                             out))
           (let ((msgs (agent-cl.session:replayed-messages
                        (agent-cl.session:open-session
                         (agent-cl.session:session-id s) :directory dir))))
             (ok (plusp (length msgs)) "the good line must still replay")))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest session-first-user-text-skips-non-user-events
  "The preview looked only at the FIRST message event, so a log starting with a
  checkpoint or an assistant message showed no preview at all."
  (let* ((dir (merge-pathnames (format nil ".tools/tmp/sess-~a/"
                                       (agent-cl.core:uuid-string))
                               (uiop:getcwd)))
         (s (agent-cl.session:make-session :directory dir)))
    (unwind-protect
         (progn
           (agent-cl.session:save-checkpoint s "start")
           (agent-cl.session:persist-message s (assistant-message "greeting"))
           (agent-cl.session:persist-message s (user-message "what is 2+2?"))
           (is-equal "what is 2+2?" (agent-cl.session:session-first-user-text s)))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest session-append-keeps-the-log-and-tail-consistent
  "Appending is O(1) via a tail pointer; the in-memory log must stay correct and
  in order."
  (let* ((dir (merge-pathnames (format nil ".tools/tmp/sess-~a/"
                                       (agent-cl.core:uuid-string))
                               (uiop:getcwd)))
         (s (agent-cl.session:make-session :directory dir)))
    (unwind-protect
         (progn
           (dotimes (i 5)
             (agent-cl.session:persist-message s (user-message (format nil "m~a" i))))
           (is-equal 5 (length (agent-cl.session::session-events s)))
           (is-equal '("m0" "m1" "m2" "m3" "m4")
                     (mapcar #'msg-content (agent-cl.session:replayed-messages s)))
           ;; reopening from disk sees the same log
           (let ((s2 (agent-cl.session:open-session (agent-cl.session:session-id s)
                                                    :directory dir)))
             (is-equal 5 (length (agent-cl.session::session-events s2)))))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

;;; ---------------------------------------------------------------------------
;;; web.search guards
;;; ---------------------------------------------------------------------------

(deftest web-cache-key-normalizes-the-query
  "\"  DeepSeek  API \" and \"deepseek api\" were separate cache entries AND
  separate billable requests."
  (is-equal (agent-cl.web::cache-key "tavily" "deepseek api" 5)
            (agent-cl.web::cache-key "tavily" "  DeepSeek   API  " 5))
  ;; NB: Lisp strings do not use C escapes — build the whitespace explicitly
  (is-equal "a b c" (agent-cl.web::normalize-query
                     (format nil "A~cB~c  C" #\Tab #\Newline)))
  (is-equal "abc" (agent-cl.web::normalize-query " abc ")))

(deftest web-cache-is-bounded
  "The cache was unbounded: an agent iterating over generated queries grew it
  (each entry a full result set) for the life of the process."
  (let ((agent-cl.web::*search-cache* (make-hash-table :test 'equal))
        (agent-cl.web::*search-cache-max-entries* 10))
    (dotimes (i 40)
      (agent-cl.web::cache-store (list "k" (format nil "q~a" i) 5)
                                 (list (list :title "t" :url "u"))))
    (ok (<= (hash-table-count agent-cl.web::*search-cache*) 10)
        "the cache must stay within its cap")))

(deftest web-breaker-does-not-trip-on-stray-digits
  "QUOTA-ERROR-P did (search \"432\" message), so any message merely containing
  those digits tripped the breaker and pinned the budget to zero."
  (ok (not (agent-cl.web::quota-error-p "fetched 1432 bytes from example.com")))
  (ok (not (agent-cl.web::quota-error-p "result id 4291 returned")))
  (ok (agent-cl.web::quota-error-p "http 432: usage limit exceeded"))
  (ok (agent-cl.web::quota-error-p "Rate limit reached"))
  (ok (agent-cl.web::quota-status-p "anything" 429)
      "an explicit HTTP status is authoritative"))