(in-package #:neomacs)

(define-mode html-doc-mode (lisp-mode file-mode) ())

(define-keys html-doc-mode
  "enter" 'open-paragraph
  "M-*" 'open-heading
  "M-`" 'open-code
  "M-/" 'open-italic
  "M--" 'insert-description-list
  "C-u M--" 'insert-description
  "M-," 'open-comma
  "C-c C-l"'insert-link)

(defmethod enable-aux ((mode (eql 'html-doc-mode)))
  (pushnew 'lisp-mode (styles (current-buffer))))

(defmethod selectable-p-aux ((buffer html-doc-mode) pos)
  (and (not (and (member (node-after pos) '(#\Space #\Newline #\Tab))
                 (member (node-before pos) '(nil #\Space #\Newline #\Tab))))
       (call-next-method)))

(defmethod revert-buffer-aux ((buffer html-doc-mode))
  (erase-buffer)
  (load-url buffer (str:concat "file://" (uiop:native-namestring (file-path buffer))))
  ;; Enter recursive edit to wait for `on-buffer-loaded', so that
  ;; buffer state is updated when `revert-buffer' returns.
  (recursive-edit))

(defmethod on-buffer-loaded progn ((buffer html-doc-mode) url err)
  (when (equal url (str:concat "file://" (uiop:native-namestring (file-path buffer))))
    (unless err
      (update-document-model buffer)
      (setf (pos (focus buffer))
            (pos-down (document-root buffer))))
    (signal 'exit-recursive-edit)))

(defmethod self-insert-aux
    ((buffer html-doc-mode) marker string)
  (let ((node (node-containing marker)))
    (cond ((member (tag-name node) '("body") :test 'equal)
           (let ((node (make-element "p" :children (list string))))
             (insert-nodes marker node)
             (setf (pos marker) (end-pos node))))
          (t (call-next-method)))))

(defmethod on-focus-move :around ((buffer html-doc-mode) old new)
  (declare (ignore old))
  (if (tag-name-p (node-containing new) "body")
      (disable 'sexp-editing-mode)
      (call-next-method)))

(define-command open-paragraph
  :mode html-doc-mode (&optional (marker (focus)))
  (let* ((pos (resolve-marker marker))
         (new-node (make-element "p"))
         (dst (pos-right (pos-up pos))))
    (insert-nodes dst new-node)
    (move-nodes pos nil (end-pos new-node))
    (setf (pos marker) (pos-down new-node))))

(define-command open-heading
  :mode html-doc-mode (&optional (marker (focus)))
  (labels ((cycle-level (n)
             (lret ((n (mod (1+ n) 7)))
               (message "Heading Level -> ~a" n)))
           (tag-level (tag)
             (cond ((equal tag "p") 0)
                   ((ppcre:all-matches "^h[123456]$" tag)
                    (parse-integer (subseq tag 1)))))
           (level-tag (level)
             (if (= level 0) "p"
                 (format nil "h~a" level))))
    (let* ((node (node-containing marker))
           (new-node (make-element
                      (level-tag
                       (cycle-level
                        (tag-level (tag-name node)))))))
      (insert-nodes (pos-right node) new-node)
      (move-nodes (pos-down node) nil (end-pos new-node))
      (delete-node node))))

(define-command open-code
  :mode html-doc-mode (&optional (marker (focus)))
  (let ((node (make-element "code")))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command open-italic
  :mode html-doc-mode (&optional (marker (focus)))
  (let ((node (make-element "i")))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(defun insert-list (marker list-tag item-tag)
  (unless (tag-name-p (node-containing marker) list-tag)
    (when (tag-name-p (node-containing marker) "p")
      (setf (pos marker) (split-node (pos marker))))
    (let ((node (make-element list-tag)))
      (insert-nodes marker node)
      (setf (pos marker) (end-pos node))))
  (let ((node (make-element item-tag)))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command insert-unordered-list
  :mode html-doc-mode (&optional (marker (focus)))
  (insert-list marker "ul" "li"))

(define-command insert-description-list
  :mode html-doc-mode (&optional (marker (focus)))
  (insert-list marker "dl" "dt"))

(define-command insert-description
  :mode html-doc-mode (&optional (marker (focus)))
  (insert-list marker "dl" "dd"))

(define-command open-comma
  :mode html-doc-mode (&optional (marker (focus)))
  "Insert a Sexp list and change the surrounding node to a comma expr."
  (let* ((list (make-list-node nil)))
    (add-class (node-containing marker) "comma-expr")
    (insert-nodes marker list)
    (setf (pos marker) (end-pos list))))

(define-command insert-link
  :mode html-doc-mode (&optional (marker (focus)))
  (let* ((href (read-from-minibuffer "Href: "))
         (a (make-element "a" :href href)))
    (insert-nodes marker a)
    (setf (pos marker) (end-pos a))))

(defmethod on-focus-move progn ((buffer html-doc-mode) old new)
  (declare (ignore old))
  (let ((node (node-containing new)))
    (if (class-p node "list" "symbol")
        (enable 'sexp-editing-mode)
        (disable 'sexp-editing-mode))))

;;; Get DOM from renderer
;; Initially adapted from Nyxt

(defparameter +get-body-json-code+
  (ps:ps
    (defparameter neomacs-identifier-counter 0)
    (defun process-element (element)
      (let ((object (ps:create :name (ps:@ element node-name)))
            (attributes (ps:chain element attributes)))
        (when (= 1 (ps:@ element node-type))
          (ps:chain element (set-attribute
                             "neomacs-identifier"
                             (ps:stringify neomacs-identifier-counter)))
          (incf neomacs-identifier-counter))
        (unless (ps:undefined attributes)
          (setf (ps:@ object :attributes) (ps:create))
          (loop for i from 0 below (ps:@ attributes length)
                do (setf (ps:@ object :attributes (ps:chain attributes (item i) name))
                         (ps:chain attributes (item i) value))))
        (unless (or (ps:undefined (ps:chain element child-nodes))
                    (= 0 (ps:chain element child-nodes length)))
          (setf (ps:chain object :children)
                (loop for child in (ps:chain element child-nodes)
                      collect (process-element child))))
        (when (and (ps:@ element shadow-root)
                   (ps:@ element shadow-root first-child))
          (setf (ps:chain object :children)
                (loop for child in (ps:chain *array
                                             (from (ps:@ element shadow-root children))
                                             (concat (ps:chain *array (from (ps:@ element children)))))
                      collect (process-element child))))
        (when (or (equal (ps:@ element node-name) "#text")
                  (equal (ps:@ element node-name) "#comment")
                  (equal (ps:@ element node-name) "#cdata-section"))
          (setf (ps:@ object :text) (ps:@ element text-content)))
        object))
    (list (process-element (ps:@ document body))
          neomacs-identifier-counter)))

(defun named-json-parse (json)
  "Return a DOM-tree produced from JSON.

JSON should have the format like what `+get-body-json-code+' produces:
- A nested hierarchy of objects (with only one root object), where
  - Every object has a 'name' (usually a tag name or '#text'/'#comment').
  - Some objects can have 'attributes' (a string->string dictionary).
  - Some objects have a subarray ('children') of objects working by these three
    rules."
  (labels ((json-to-dom (json)
             (let ((node
                     (cond
                       ((equal (assoc-value json :name) "#text")
                        (make-instance 'text-node :text (assoc-value json :text)))
                       (t
                        (make-instance 'element :tag-name (str:downcase (assoc-value json :name)))))))
               (dolist (c (assoc-value json :children))
                 (append-child node (json-to-dom c)))
               (iter (for (k . v) in (assoc-value json :attributes))
                 (setf (attribute node (str:downcase (symbol-name k))) v))
               node)))
    (json-to-dom json)))

(defun update-document-model (buffer)
  (bind (((json id) (evaluate-javascript-sync +get-body-json-code+ buffer))
         (dom (named-json-parse json)))
    (do-dom (lambda (n) (setf (host n) buffer)) dom)
    (setf (document-root buffer) dom
          (restriction buffer) dom
          (pos (focus buffer)) (pos-down dom)
          (next-neomacs-id buffer) id)))

(defmethod write-dom-aux ((buffer html-doc-mode) node stream)
  (let ((*serialize-exclude-attributes* '("neomacs-identifier")))
    (serialize node stream)))

(defun print-arglist (arglist package)
  (let ((*package* package))
    (format nil "(~{~a~^ ~})" arglist)))

(defun render-doc-string-paragraph (p)
  (let ((last-end 0))
    (append
     (iter
       (for (start end) on
            (ppcre:all-matches "`[^']*'" p)
            by #'cddr)
       (when (> start last-end)
         (collect (subseq p last-end start)))
       (when (> (1- end) (1+ start))
         (collect (make-element "code" :children
                                (list (subseq p (1+ start) (1- end))))))
       (setq last-end end))
     (when (> (length p) last-end)
       (list (subseq p last-end))))))

(defun render-doc-string (string)
  (when string
    (let ((paragraphs (str:split "

"
                                 string)))
      (iter (for p in paragraphs)
        (append-child
         *dom-output*
         (make-element
          "dd" :children
          (render-doc-string-paragraph p)))))))

(defun fundoc (function)
  (let ((*print-case* :downcase))
    (let ((*dom-output*
            (append-child *dom-output* (make-element "dt"))))
      (append-text
       *dom-output*
       (format nil "~a~:[~;, setf-able~]: "
               (cond ((macro-function function)
                      "Macro")
                     ((typep (symbol-function function)
                             'generic-function)
                      (let ((*print-case* :capitalize))
                        (format nil "~a generic function"
                                (slot-value (sb-mop:generic-function-method-combination (symbol-function function))
                                            'sb-pcl::type-name))))
                     (t "Function"))
               (fboundp (list 'setf function))))
      (append-child *dom-output*
                    (make-element "code" :children (list (prin1-to-string function))))
      (append-text *dom-output* " ")
      (append-child *dom-output*
                    (make-element "code" :children
                                  (list (print-arglist (swank-backend:arglist function)
                                                       (symbol-package function))))))
    (render-doc-string (documentation function 'function))))

(defun vardoc (var)
  (let ((*print-case* :downcase))
    (let ((*dom-output* (append-child *dom-output* (make-element "dt"))))
      (append-text *dom-output* "Variable: ")
      (append-child *dom-output*
                    (make-element "code" :children (list (prin1-to-string var)))))
    (render-doc-string (documentation var 'variable))))

(defun classdoc (class)
  (let ((*print-case* :downcase)
        (object (find-class class)))
    (let ((*dom-output* (append-child *dom-output* (make-element "dt"))))
      (append-text *dom-output* "Class: ")
      (append-child *dom-output*
                    (make-element "code" :children (list (prin1-to-string class))))
      (append-text *dom-output* " inherits ")
      (append-child
       *dom-output*
       (make-element
        "code"
        :children
        (list (print-arglist
               (mapcar #'class-name
                       (sb-mop:class-direct-superclasses object))
               (symbol-package class))))))
    (render-doc-string (documentation class 'type))
    (when-let (slots (sb-mop:class-direct-slots object))
      (let ((*dom-output*
              (append-child
               (append-child *dom-output*
                             (make-element "dd"))
               (make-element "dl"))))
        (iter (for slot in slots)
          (let ((*dom-output* (append-child *dom-output* (make-element "dt"))))
            (append-text *dom-output* "Slot: ")
            (append-child
             *dom-output*
             (make-element
              "code" :children
              (list (prin1-to-string
                     (sb-mop:slot-definition-name slot)))))
            (render-doc-string (documentation slot t))))))))

(defun expand-comma-expr (node)
  (labels ((process (node)
             (if (element-p node)
                 (if (class-p node "comma-expr")
                     (progn
                       (eval (node-to-sexp (first-child node)))
                       nil)
                     (lret ((*dom-output* (clone-node node nil)))
                       (iter (for c first (first-child node)
                                  then (next-sibling c))
                         (while c)
                         (when-let (d (process c))
                           (append-child *dom-output* d)))))
                 (clone-node node nil))))
    (process node)))

(defun heading-text-to-id (text)
  (str:replace-all " " "-" (string-downcase text)))

(defun add-heading-ids (node)
  (do-elements
      (lambda (node)
        (when (ppcre:all-matches
               "^h[123456]$"
               (tag-name node))
          (setf (attribute node "id")
                (heading-text-to-id (text-content node)))))
    node))

(define-command render-html-doc
  :mode html-doc-mode ()
  "Render current buffer by expanding at expressions."
  (let* ((path (file-path (current-buffer)))
         (output-path (make-pathname
                       :directory
                       (append (pathname-directory path)
                               (list "build"))
                       :defaults path)))
    (ensure-directories-exist output-path)
    (with-open-file (s output-path
                       :direction :output
                       :if-exists :supersede)
      (message "Rendering ~a" output-path)
      (let ((*serialize-exclude-attributes* '("neomacs-identifier"))
            (*package* (find-package "NEOMACS")))
        (serialize
         (add-heading-ids
          (expand-comma-expr (document-root (current-buffer))))
         s))
      (message "Rendered to ~a" output-path))))

(defun build-manual-section (file)
  (with-current-buffer (find-file-no-select file)
    (render-html-doc)
    (let (title subtitles)
      (do-elements
          (lambda (node)
            (when (tag-name-p node "h1")
              (setq title (text-content node)))
            (when (tag-name-p node "h2")
              (push (text-content node) subtitles)))
        (document-root (current-buffer)))
      (values title (nreverse subtitles)))))

(defun build-manual ()
  (let ((sections '("dom" "positions" "markers" "motion"
                    "edit" "undo" "ranges" "mode" "command-loop"
                    "window-management")))
    (with-current-buffer
        (find-file-no-select
         (asdf:system-relative-pathname
          "neomacs" "doc/build/toc.html"))
      (erase-buffer)
      (let ((*dom-output*
              (make-element "ol")))
        (iter (for section in sections)
          (for file = (asdf:system-relative-pathname
                       "neomacs"
                       (str:concat "doc/" section ".html")))
          (for href = (str:concat section ".html"))
          (let ((*dom-output* (append-child
                               *dom-output*
                               (make-element "li"))))
            (multiple-value-bind
                  (title subtitles)
                (build-manual-section file)
              (append-child
               *dom-output*
               (make-element "a" :href href :children (list title)))
              (let ((*dom-output* (append-child *dom-output*
                                                (make-element "ul"))))
                (iter
                  (for subtitle in subtitles)
                  (append-child
                   *dom-output*
                   (make-element
                    "li" :children
                    (list (make-element
                           "a" :href
                           (str:concat href "#"
                                       (heading-text-to-id subtitle))
                           :children (list subtitle))))))))))
        (insert-nodes
         (end-pos (document-root (current-buffer)))
         *dom-output*)
        (save-buffer)))))

(defstyle html-doc-mode
    `(("p:empty::after" :content "_")
      ("li p" :margin 0)
      ("body" :white-space "normal")
      (".comma-expr::before" :content ",")
      (".comma-expr" :border "solid 1px currentColor")))
