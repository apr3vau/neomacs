(in-package :neomacs)

(defun print-arglist (arglist package)
  (if arglist
      (prini-to-string arglist :package package)
      "()"))

(spinneret:deftag :nxdoc (body attrs &rest keys &key slot mode class-name function macro command (command-key-p t) variable package (target "_self") &allow-other-keys)
  "Create an inline description for BODY symbol.

Relies on the type keywords (SLOT, MODE, CLASS-NAME, FUNCTION, MACRO, COMMAND,
VARIABLE, PACKAGE, TARGET), always provide those.

CLASS-NAME, if present, should be the symbol designating a class. It's not
called CLASS because Spinneret has special behavior for CLASS pre-defined and
non-overridable."
  (let* ((keys keys)
         (first (first body))
         (symbol (or package variable function macro command slot class-name mode
                     (when (symbolp first) first)))
         (printable (or (when (and (symbolp first) (eq first symbol))
                          (second body))
                        first package variable function macro command slot class-name mode))
         (type (cond
                 (package :package)
                 (variable :variable)
                 (macro :macro)
                 (command :command)
                 (function :function)
                 ((and slot class-name) :slot)
                 (mode :mode)
                 (class-name :class))))
    (declare (ignorable keys))
    (ecase type
      ((:function)
       `(:li "Function: " (:nxref ,@keys) " "
             (:code (print-arglist (swank-backend:arglist ,function)
                                   (symbol-package ,function)))
             (:p (:raw (resolve-backtick-quote-links
                        (documentation ,function 'function)
                        (symbol-package ,function))))))
      ((:command)
       `(:li "Command: " (:nxref ,@keys) " "
             (:code (print-arglist (swank-backend:arglist ,command)
                                   (symbol-package ,command)))
             (:p (:raw (resolve-backtick-quote-links
                        (documentation ,command 'function)
                        (symbol-package ,command))))))
      ((:variable)
       `(:li "Variable: " (:nxref ,@keys)
             (:p (:raw (resolve-backtick-quote-links
                        (documentation ,variable 'variable)
                        (symbol-package ,variable)))))))))

(defun neomacs-manual-content ()
  (spinneret:with-html-string
    (:ntoc
      (:nsection :title "Reactive DOM"
        (:p "Neomacs maintains reactive DOMs based on " (:nxref :package :lwcells) ". This enables observers and computed attributes to update in real-time depending on DOM content.")
        (:nsection :title "Nodes"
          (:p "This section documents the low-level node classes making up Neomacs's reactive DOM. Note that the interface here is low-level in the sense that " (:nxref :class-name 'text-node) "s are being exposed. The majority of Neomacs API hides " (:nxref :class-name 'text-node) " as an implementation detail and the " (:i "conceptual DOM" ) " consists of "(:nxref :class-name 'element) " and " (:nxref :class-name 'character)  ".")
          (:ul
           (:li (:nxref :class-name 'node))
           (:li (:nxref :class-name 'text-node))
           (:li (:nxref :class-name 'element))
           (:nxdoc :function 'child-nodes)
           (:nxdoc :function 'element-p)
           (:nxdoc :function 'text-node-p)
           (:nxdoc :function 'clone-node)))
        (:nsection :title "Traversing DOM"
          (:ul
           (:nxdoc :function 'do-dom)
           (:nxdoc :function 'do-elements)))
        (:nsection :title "Attributes"
          (:ul
           (:nxdoc :function 'attribute)
           (:nxdoc :function 'set-attribute-function)))
        (:nsection :title "Low-level DOM edits"
          (:p "This section documents low-level primitives for modifying Lisp-side DOM. They are used to implement programmer-facing editing operations, see " (:a :href "#editing-primitives" "Editing primitives") ".")
          (:ul
           (:nxdoc :function 'insert-before)
           (:nxdoc :function 'append-child)
           (:nxdoc :function 'append-children)
           (:nxdoc :function 'remove-node))))
      (:nsection :title "Positions"
        (:p "A " (:i "position") " denotes somewhere in the DOM tree, which can be before or after some node, or between two adjacent nodes.")
        (:p "Positions may become invalid after editing operations. To maintain a valid position across arbitrary editing operations, see " (:a :href "#markers" "Markers") ".")
        (:nsection :title "Types of positions"
          (:ul
           (:li "An " (:nxref :class-name 'element) " denotes the position before the " (:code "element") ".")
           (:li (:code "(end-pos node)") " denotes the position at the end of " (:code "node") " (after any children). " (:code "node") " must be an " (:nxref :class-name 'element) ".")
           (:li (:code "(text-pos node offset)") " denotes the position before the " (:code "offset") "-th character of " (:code "node") ". " (:code "node") " must be a " (:nxref :class-name 'text-node))
           (:li (:code "nil") " denotes nowhere. Many position-related functions may return nil if requested position does not exist, and propagates nil if they receives nil position as an argument.")))
        (:nsection :title "Node around positions"
          (:p "The following queries node around a given position. A node can be a " (:nxref :class-name 'character) " or " (:nxref :class-name 'element) ". If no node is found, nil is returned.")
          (:ul
           (:nxdoc :function 'node-after)
           (:nxdoc :function 'node-before)
           (:nxdoc :function 'node-containing)))
        (:nsection :title "Computing positions"
          (:p "Basic position functions:")
          (:ul
           (:nxdoc :function 'pos-left)
           (:nxdoc :function 'pos-right)
           (:nxdoc :function 'pos-next)
           (:nxdoc :function 'pos-prev)
           (:nxdoc :function 'pos-up)
           (:nxdoc :function 'pos-down)
           (:nxdoc :function 'pos-down-last))
          (:p "Iterate until or ensure a position predicate is satisfied:"
               (:nxref :function 'pos-left-until) ", "
               (:nxref :function 'pos-right-until) ", "
               (:nxref :function 'pos-prev-until) ", "
               (:nxref :function 'pos-next-until) ", "
               (:nxref :function 'pos-up-until) ", "
               (:nxref :function 'pos-left-ensure) ", "
               (:nxref :function 'pos-right-ensure) ", "
               (:nxref :function 'pos-prev-ensure) ", "
               (:nxref :function 'pos-next-ensure) ", "
               (:nxref :function 'pos-up-ensure) ".")
          (:p "Destructive variants: "
               (:nxref :function 'npos-left) ", "
               (:nxref :function 'npos-right) ", "
               (:nxref :function 'npos-next) ", "
               (:nxref :function 'npos-prev) ", "
               (:nxref :function 'npos-left-until) ", "
               (:nxref :function 'npos-right-until) ", "
               (:nxref :function 'npos-next-until) ", "
               (:nxref :function 'npos-prev-until) ", "
               (:nxref :function 'npos-left-ensure) ", "
               (:nxref :function 'npos-right-ensure) ", "
               (:nxref :function 'npos-next-ensure) ", "
               (:nxref :function 'npos-prev-ensure) ".")
          (:p "All of the above functions may take and return nil positions without signaling error."))
        (:nsection :title "Comparing positions"
          (:p "Two positions point to the same location iff they are " (:nxref :function 'equalp) ".")
          (:p "Additional functions for comparing positions:")
          (:ul
           (:nxdoc :function 'before-p))))
      (:nsection :title "Markers"
        (:p "A " (:nxref :class-name 'marker) " maintains a position in the buffer, which stays valid across arbitrary editing operations.")
        (:nsection :title "Marker advance types"
          (:ul
           (:p "When an insertion happens at a marker, the marker may get pushed after the inserted contents (it " (:i "advances") "), or stay before the inserted contents (it does not advance). This property can be queried and set using the following function:")
           (:nxdoc :function 'advance-p))))
      (:nsection :title "Motion"
        (:nsection :title "Selectable positions")
        (:nsection :title "Motion commands"
          (:p "The following moves according to structure of the document.")
          (:ul
           (:nxdoc :command 'forward-node :mode 'neomacs-mode)
           (:nxdoc :command 'backward-node :mode 'neomacs-mode)
           (:nxdoc :command 'forward-element :mode 'neomacs-mode)
           (:nxdoc :command 'backward-element :mode 'neomacs-mode)
           (:nxdoc :command 'backward-up-node :mode 'neomacs-mode)
           (:nxdoc :command 'beginning-of-buffer :mode 'neomacs-mode)
           (:nxdoc :command 'end-of-buffer :mode 'neomacs-mode)
           (:nxdoc :command 'forward-word :mode 'neomacs-mode)
           (:nxdoc :command 'backward-word :mode 'neomacs-mode)
           (:nxdoc :command 'beginning-of-line :mode 'neomacs-mode)
           (:nxdoc :command 'end-of-line :mode 'neomacs-mode)
           (:nxdoc :command 'beginning-of-defun :mode 'neomacs-mode)
           (:nxdoc :command 'end-of-defun :mode 'neomacs-mode))
          (:p "The following line motion commands try to keep horizontal approximately the same. Currently, we do this by counting number of selectable positions between current focus position and beginning-of-line position, and try to keep that number the same.")
          (:ul
           (:nxdoc :command 'previous-line :mode 'neomacs-mode)
           (:nxdoc :command 'next-line :mode 'neomacs-mode)
           (:nxdoc :command 'scroll-up-command :mode 'neomacs-mode)
           (:nxdoc :command 'scroll-down-command :mode 'neomacs-mode))))
      (:nsection :title "Editing"
        (:nsection :title "Editing primitives"
          (:p "Lisp programs are expected to use the following primitives to edit the Neomacs DOM. These primitives provides " (:a :href "#positions" "Positions")  "-based interface and handles " (:nxref :class-name 'text-node) " splitting/merging automatically. These primitives also maintain " (:a :href "#undo" "Undo") " history, updates browser renderer-side DOM, setup and destruction of observers and computed attributes, and allocation of neomacs-identifier.")
          (:ul
           (:nxdoc :function 'delete-nodes)
           (:nxdoc :function 'extract-nodes)
           (:nxdoc :function 'insert-nodes)
           (:nxdoc :function 'move-nodes)))
        (:nsection :title "Compound editing operations"
          (:ul
           (:nxdoc :function 'splice-node)
           (:nxdoc :function 'join-nodes)
           (:nxdoc :function 'raise-node)
           (:nxdoc :function 'split-node)))
        (:nsection :title "Editing commands"
          (:ul
           (:nxdoc :command 'new-line :mode 'neomacs-mode)
           (:nxdoc :command 'backward-delete :mode 'neomacs-mode)
           (:nxdoc :command 'forward-delete :mode 'neomacs-mode)
           (:nxdoc :command 'backward-cut-word :mode 'neomacs-mode)
           (:nxdoc :command 'cut-element :mode 'neomacs-mode)
           (:nxdoc :command 'copy-element :mode 'neomacs-mode)
           (:nxdoc :command 'paste :mode 'neomacs-mode)
           (:nxdoc :command 'paste-pop :mode 'neomacs-mode)
           (:nxdoc :command 'forward-cut :mode 'neomacs-mode))))
      (:nsection :title "Ranges"
        (:nsection :title "Range operations"
          (:ul
           (:nxdoc :function 'range)
           (:nxdoc :function 'range-collapsed-p)
           (:nxdoc :function 'inside-range-p)
           (:nxdoc :function 'extract-range)
           (:nxdoc :function 'delete-range)))
        (:nsection :title "Range selection"))
      (:nsection :title "Undo"
        (:p "The following functions maintains the undo history.")
        (:ul
         (:nxdoc :function 'record-undo)
         (:nxdoc :variable '*inhibit-record-undo*)
         (:nxdoc :function 'undo-auto-amalgamate)
         (:nxdoc :function 'undo-boundary))
        (:p "The following functions and commands perform undo and redo operations.")
        (:ul
         (:nxdoc :function 'undo)
         (:nxdoc :function 'redo)
         (:nxdoc :function 'undo-command)
         (:nxdoc :function 'redo-command)))
      (:nsection :title "Completion"))))

(define-internal-page-command-global neomacs-manual ()
    (buffer "*Neomacs Manual*" 'nyxt/mode/help:help-mode)
  "Display Neomacs manual."
  (spinneret:with-html-string
    (:nstyle '(body :max-width "80ch"))
    (:style "li p{margin-top: 0}")
    (:raw (neomacs-manual-content))))
