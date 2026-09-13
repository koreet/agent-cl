;;;; tests/schema-tests.lisp — JSON-Schema validation and type coercion.
;;;;
;;;; The coercion path is reachable from *model output* (a model may send
;;;; "42" where the schema says :integer), so READ-NUMBER must never be able to
;;;; evaluate reader syntax: "#.(...)" is exactly the kind of text a tool
;;;; argument can contain.
(in-package #:agent-cl.tests)

(defparameter *eval-bomb* nil
  "Set to T if READ-NUMBER is ever tricked into evaluating its input.")

;; --- validation: types, required, nested paths ---------------------------------

(deftest schema-validates-object-types
  (let ((schema (make-schema :kind :object
                             :properties '(("name" :type :string)
                                           ("count" :type :integer)))))
    (is-equal nil (validate-json schema '(:name "x" :count 2)))
    (ok (validate-json schema '(:name 5)) "a number where a string belongs")
    (ok (validate-json schema '(:count "two")) "a string where an integer belongs")))

(deftest schema-integer-accepts-integral-floats
  "JSON has no integer/float distinction, so 2.0 must pass an :integer slot
  while 2.5 must not."
  (let ((schema (make-schema :kind :object
                             :properties '(("count" :type :integer)))))
    (is-equal nil (validate-json schema '(:count 2.0)))
    (ok (validate-json schema '(:count 2.5)))))

(deftest schema-reports-nested-paths
  "Problems inside a nested object must name their path, otherwise a failure is
  unattributable."
  (let ((schema (make-schema :kind :object
                             :properties
                             '(("outer" :type :object
                               :properties (("inner" :type :string)))))))
    (let ((problems (validate-json schema '(:outer (:inner 7)))))
      (ok problems "bad nested value must be reported")
      (ok (some (lambda (p) (search "inner" p)) problems)
          "the reported problem should mention the nested key"))))

;; --- coercion: strings that the schema wants as numbers -------------------------

(deftest coerce-string-to-number
  (let ((schema (make-schema :kind :object
                             :properties '(("n" :type :number)
                                           ("i" :type :integer)))))
    (let ((out (coerce-schema-types schema '(:n "3.5" :i "7"))))
      (ok (= 3.5 (getf out :n)) "3.5 coerced to a number")
      (is-equal 7 (getf out :i)))))

(deftest coerce-keeps-unparseable-string
  "A failed coercion must NOT silently become NIL: the validator should still
  see the offending text and report it."
  (let ((schema (make-schema :kind :object
                             :properties '(("n" :type :number)))))
    (is-equal "abc" (getf (coerce-schema-types schema '(:n "abc")) :n))))

;; --- READ-NUMBER safety ---------------------------------------------------------

(deftest read-number-parses-plain-literals
  (is-equal 42 (agent-cl.schema::read-number "42"))
  (ok (= -1.5 (agent-cl.schema::read-number "-1.5")))
  (ok (= 1000.0d0 (agent-cl.schema::read-number "1e3"))))

(deftest read-number-refuses-reader-syntax
  "Reader syntax must be inert: no #. evaluation, no #n= labels, no quotes,
  no ratios, no trailing junk."
  (dolist (evil '("#.(setf agent-cl.tests::*eval-bomb* t)"
                  "#.(+ 1 2)"
                  "#.(delete-file \"x\")"
                  "#1=(1 . #1#)"
                  "'42"
                  "1/2"
                  "(+ 1 2)"
                  "42abc"
                  " 42"
                  "42 "
                  ""))
    (is-equal nil (agent-cl.schema::read-number evil)
              (format nil "~s must not be read as a number" evil)))
  (ok (null *eval-bomb*)
      "reader-eval must never run — *EVAL-BOMB* was set by #."))

(deftest read-number-hardens-against-eval-eval-var
  "Even if a caller re-enables *READ-EVAL*, the character whitelist alone
  rejects reader macros."
  (let ((*read-eval* t))
    (is-equal nil (agent-cl.schema::read-number "#.(setf agent-cl.tests::*eval-bomb* t)")))
  (ok (null *eval-bomb*)))
