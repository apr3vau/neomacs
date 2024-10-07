
(asdf:defsystem neomacs
  :version "0.0.1"
  :author "Qiantan Hong <qhong@alum.mit.edu>"
  :maintainer "Qiantan Hong <qhong@alum.mit.edu>"
  :license "GPLv3+"
  :description "Structural Lisp Environment"
  :serial t
  :components ((:file "packages")
               (:file "default-value")
               (:file "dom")
               (:file "command")
               (:file "pos-marker")
               (:file "defstyle")
               (:file "buffer")
               (:file "keymap")
               (:file "motion")
               (:file "edit")
               (:file "range")
               (:file "frame")
               (:file "command-loop")
               (:file "minibuffer")
               (:file "list-commands")
               (:file "undo")
               (:file "ceramic")
               (:file "start")
               (:file "completion")
               #+nil (:file "manual")
               (:file "modes/file-mode")
               (:file "modes/lisp-mode")
               (:file "modes/lisp-file"))
  :depends-on (:lwcells
               :ceramic
               :str
               :dynamic-mixins
               :parenscript
               :plump
               :lass
               :spinneret
               :metabang-bind
               :cl-containers
               :quri
               :trivial-types
               :sb-concurrency))
