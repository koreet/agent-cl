;;;; tests/core-tests.lisp
(in-package #:agent-cl.tests)

(deftest json-roundtrip-basic
  (let* ((json (json-encode (let ((h (make-hash-table :test 'equal)))
                              (setf (gethash "a" h) 1)
                              h)))
         (back (json-decode json)))
    (ok (hash-table-p back))
    (is-equal 1 (gethash "a" back))))

(deftest json-encode-plist-object
  (let ((json (encode-plist-object '(:model "m" :max-tokens 5 :stream t :tags ("x" "y")))))
    (ok (search "\"model\":\"m\"" json))
    (ok (search "\"max_tokens\":5" json))
    (ok (search "\"stream\":true" json))
    (ok (search "\"tags\":[\"x\",\"y\"]" json))))

(deftest json-object-to-plist-snake-case
  (let* ((json "{\"tool_call_id\":\"abc\",\"finish_reason\":\"tool_calls\",\"user_name\":\"b\"}")
         (pl (decode-to-plist json)))
    (is-equal "abc" (getf pl :TOOL-CALL-ID))
    (is-equal "tool_calls" (getf pl :FINISH-REASON))
    (is-equal "b" (getf pl :USER-NAME))))

(deftest json-unicode-cjk
  (let* ((json (json-encode (let ((h (make-hash-table :test 'equal)))
                              (setf (gethash "greeting" h) "你好世界")
                              h)))
         (back (json-decode json)))
    (is-equal "你好世界" (gethash "greeting" back))))

(deftest approx-tokens-sanity
  (ok (plusp (approx-tokens "hello world")))
  (ok (> (approx-tokens (make-string 100 :initial-element #\汉))
         (approx-tokens (make-string 100 :initial-element #\a)))))

(deftest uuid-unique
  (ok (string-not-equal (uuid-string) (uuid-string)))
  (is-equal 36 (length (uuid-string))))

(deftest condition-signaling
  (signals-error agent-cl.core:tool-error
    (error 'agent-cl.core:tool-error :tool "x" :code :boom :message "m")))

(deftest string-file-roundtrip
  (let ((path (format nil "~a/.tools/tmp-write-test.txt"
                      (namestring (uiop:getcwd)))))
    (write-file-string path "héllo")
    (is-equal "héllo" (read-file-string path))
    (ignore-errors (delete-file path))))
