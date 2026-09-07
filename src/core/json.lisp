;;;; src/core/json.lisp — JSON adapter over yason.
;;;;
;;;; Semantics chosen for the agent wire layer:
;;;;   * encode: hash-table/plist objects, strings, numbers, T -> true,
;;;;     NIL -> false is NOT used implicitly — callers pass yason:true /
;;;;     yason:false explicitly for booleans; NIL encodes as JSON null.
;;;;   * decode: objects become hash-tables; object-to-plist converts any
;;;;     decoded structure into keyword-keyed plists recursively.
(in-package #:agent-cl.core)

(defun json-encode (object)
  "Encode OBJECT to a JSON string using yason's stream encoder."
  (with-output-to-string (s)
    (yason:encode object s)))

(defun encode-plist-object (plist)
  "Encode a plist as a JSON object. Keys may be keywords/symbols/strings;
  values: string | number | hash-table | list-of-values (array) | yason:true /
  yason:false (booleans). Nested object plists are not supported here — the
  wire codec builds hash-tables directly for nested objects."
  (labels ((key->string (k)
             ;; Lisp kebab-case keyword -> JSON snake_case string
             (cond ((stringp k) k)
                   (t (substitute #\_ #\- (string-downcase (symbol-name k))))))
           (encode-value (v)
             (typecase v
               (hash-table v)
               (string v)
               (number v)
               (list (mapcar #'encode-value v))
               (t v))))          ; yason:true / yason:false symbols pass through
    (when (oddp (length plist))
      (error "encode-plist-object: plist has odd length: ~a" plist))
    (let ((ht (make-hash-table :test 'equal)))
      (loop for (k v) on plist by #'cddr
            do (setf (gethash (key->string k) ht) (encode-value v)))
      (json-encode ht))))

(defun json-decode (string)
  "Decode a JSON string. Objects become hash-tables (equal test), arrays
  become lists, booleans T/NIL, numbers numbers. Verified with yason: JSON
  null decodes to NIL (indistinguishable from absent/false for consumers that
  do not use :null sentinels — acceptable for optional fields)."
  (yason:parse string))

(defun object-to-plist (decoded &key (string-keys nil))
  "Recursively convert a yason-decoded structure into plists.
  JSON object keys become keywords when STRING-KEYS is NIL (uppercased via
  STRING-UPCASE), else stay strings. This is the shape tools receive."
  (labels ((key->keyword (k)
             ;; JSON snake_case -> Lisp kebab-case keyword
             (intern (substitute #\- #\_ (string-upcase k)) :keyword))
           (conv (x)
             (cond ((hash-table-p x)
                    (let (pairs)
                      (maphash (lambda (k v)
                                 (push (cons (if string-keys k
                                                 (key->keyword k))
                                             (conv v))
                                       pairs))
                               x)
                      (loop for (k . v) in (nreverse pairs)
                            append (list k v))))
                   ((stringp x) x)                    ; NB: strings ARE vectors
                   ((vectorp x) (map 'list #'conv x)) ; JSON arrays
                   ((listp x) (mapcar #'conv x))
                   (t x))))
    (conv decoded)))

(defun decode-to-plist (string &key (string-keys nil))
  "Shortcut: parse STRING and convert to a plist structure."
  (object-to-plist (json-decode string) :string-keys string-keys))
