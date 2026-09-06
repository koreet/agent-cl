;;; scripts/env.lisp — shared offline bootstrap for Agent-CL.
;;;
;;; In this sandboxed environment there is no working in-Lisp TLS and no
;;; admin/winget, so Quicklisp's dist download is unavailable. Dependencies
;;; are vendored under <repo>/.tools/deps/<lib>/ (each dir holds its .asd).
;;; This file registers every such dir in the ASDF central registry and loads
;;; the ASDF system.
;;;
;;; Usage:
;;;   SBCL_HOME=<repo>/.tools/sbcl XDG_CACHE_HOME=<repo>/.tools/cache \
;;;     sbcl --script scripts/env.lisp          ; loads :agent-cl, no tests
;;;     sbcl --script scripts/run-tests.lisp    ; runs test suite
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


(defparameter *agent-cl-root*
  ;; repo root = parent of the directory holding this file (scripts/)
  (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname *load-truename*)))

;; Register every vendored library under .tools/deps recursively (no Quicklisp
;; dist available in this sandbox), plus this repo for :agent-cl itself.
(asdf:initialize-source-registry
 `(:source-registry
   (:tree ,(uiop:subpathname *agent-cl-root* ".tools/deps/"))
   :ignore-inherited-configuration))
(pushnew *agent-cl-root* asdf:*central-registry* :test #'equal)


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
(format t "~&[env] agent-cl loaded (deps from ~a)~%"
        (uiop:subpathname *agent-cl-root* ".tools/deps/"))
