(in-package #:neomacs)

;;; Neomacs buffer

(defvar *adjust-marker-direction* 'forward)

(defvar *buffer-table* (make-hash-table) "Map ID to buffer instances.")

(defun generate-buffer-id ()
  (iter (for i from 0)
    (unless (gethash i *buffer-table*)
      (return i))))

(defvar *buffer-name-table* (make-hash-table :test 'equal)
  "Map buffer name to buffer instances.")

(defun generate-buffer-name (name)
  (if (gethash name *buffer-name-table*)
      (iter (for i from 2)
        (for new-name = (format nil "~A<~A>" name i))
        (while (gethash new-name *buffer-name-table*))
        (finally (return new-name)))
      name))

(defvar *buffer-table-lock* (bt:make-recursive-lock))

(define-class buffer (default-mixin)
  ((id :initform (generate-buffer-id) :type integer)
   (name :type string)
   (url :initarg :url :type quri:uri)
   (word-boundary-list :default (list #\ ))
   (focus-marker)
   (selection-marker)
   (markers :type list)
   (document-root)
   (restriction)
   (next-neomacs-id :initform 0 :accessor next-neomacs-id :type integer)
   (read-only-p :type boolean)
   (scroll-margin
    :default 0.2
    :type (real 0 0.5)
    :documentation "With value s, try to keep cursor within [s,1-s] portion of the viewport.")
   (scroll-lines :default 10 :type (integer 1))
   (styles :default (list 'buffer 'completion) :initarg :styles)
   (modes :initform nil)
   (lock :initform (bt:make-recursive-lock) :reader lock)
   (window-decoration)
   (previous-buffer))
  (:default-initargs :url (quri:uri "about:blank")))

(defmethod id ((buffer buffer))
  (format nil "~A" (slot-value buffer 'id)))

(defun enable (mode-name)
  (dynamic-mixins:ensure-mix (current-buffer) mode-name))

(defun disable (mode-name)
  (dynamic-mixins:delete-from-mix (current-buffer) mode-name))

(defgeneric enable-aux (mode-name)
  (:method ((mode-name symbol))))

(defgeneric disable-aux (mode-name)
  (:method ((mode-name symbol))))

(defmethod update-instance-for-different-class
    :after ((previous buffer) (current buffer) &key)
  (let ((previous (sb-mop:class-precedence-list (class-of previous)))
        (current (sb-mop:class-precedence-list (class-of current))))
    (dolist (old (remove-if (alex:rcurry #'member current) previous))
      (disable-aux (class-name old)))
    (dolist (new (reverse (remove-if (alex:rcurry #'member previous) current)))
      (enable-aux (class-name new)))))

(defun focus (&optional (buffer (current-buffer)))
  (focus-marker buffer))

(defun buffer-alive-p (buffer)
  (eql (gethash (slot-value buffer 'id) *buffer-table*) buffer))

(defun call-with-current-buffer (buffer thunk)
  (let ((*current-buffer* buffer)
        (*adjust-marker-direction* *adjust-marker-direction*))
    (bt:with-recursive-lock-held ((lock buffer))
      (on-pre-command buffer)
      ;; Force evaluation at the end
      (let (lwcells::*delay-evaluation-p*)
        (unwind-protect
             (with-delayed-evaluation
               (funcall thunk))
          (when (buffer-alive-p buffer)
            (case *adjust-marker-direction*
              ((forward) (ensure-selectable (focus)))
              ((backward) (ensure-selectable (focus) t)))
            (render-focus (focus buffer))
            (on-post-command buffer)))))))

(defun send-dom-update (parenscript anchor-node)
  (unless *inhibit-dom-update*
    (evaluate-javascript
     (let (ps:*parenscript-stream*)
       (ps:ps* parenscript))
     (if (typep anchor-node 'buffer)
         anchor-node
         (host anchor-node)))
    #+nil (if *inside-dom-update-p*
        (let ((ps:*parenscript-stream* *dom-update-stream*))
          (ps:ps* `(ignore-errors ,parenscript)))
        (progn
          (evaluate-javascript
           (let (ps:*parenscript-stream*)
             (ps:ps* `(progn ,parenscript nil)))
           (current-buffer))
          nil))))

(defmethod initialize-instance :after ((buffer buffer) &key name)
  (unless name (alex:required-argument :name))
  (bt:with-recursive-lock-held (*buffer-table-lock*)
    (setf (name buffer) (generate-buffer-name name)
          (gethash (name buffer) *buffer-name-table*) buffer)
    (setf (gethash (slot-value buffer 'id) *buffer-table*) buffer))
  (dolist (new (reverse (sb-mop:class-precedence-list (class-of buffer))))
    (enable-aux (class-name new)))
  (cera.d:js cera.d:*driver*
             (format nil "Ceramic.createBuffer(~S, ~S, {})"
                     (id buffer) (quri:render-uri (url buffer))))
  (setf (document-root buffer)
        (make-instance 'element :tag-name "body" :host buffer)
        (restriction buffer) (document-root buffer)
        (focus-marker buffer) (make-instance 'marker :pos (end-pos (document-root buffer)))
        (window-decoration buffer)
        (make-element
         "div"
         :class "buffer" :selectable ""
         :children (list (make-element "div" :class "content" :buffer (id buffer)))))
  (dolist (style (styles buffer))
    (add-observer (css-cell style)
                  (nclo update-style (cell)
                    (declare (ignore cell))
                    (update-style buffer style)))))

(defgeneric on-post-command (buffer)
  (:method-combination progn)
  (:method progn ((buffer buffer))))

(defgeneric on-pre-command (buffer)
  (:method-combination progn)
  (:method progn ((buffer buffer))))

(ps:defpsmacro js-buffer (buffer)
  `(ps:getprop (ps:chain -ceramic buffers) (ps:lisp (id ,buffer))))

(defgeneric on-buffer-loaded (buffer)
  (:method-combination progn)
  (:method progn ((buffer buffer))
    (when (eql buffer (focused-buffer))
      (evaluate-javascript
       (ps:ps (ps:chain (js-buffer buffer) web-contents (focus)))
       nil))))

(defgeneric on-buffer-delete (buffer)
  (:method-combination progn)
  (:method progn ((buffer buffer))))

(defgeneric on-node-setup (buffer node)
  (:method-combination progn)
  (:method progn ((buffer buffer) (node t))))

(defgeneric on-node-cleanup (buffer node)
  (:method-combination progn)
  (:method progn ((buffer buffer) (node t))))

(defgeneric on-focus-move (buffer saved new)
  (:method-combination progn)
  (:method progn ((buffer buffer) (saved t) (new t))))

(defgeneric keymaps (buffer)
  (:method-combination append)
  (:method append ((buffer buffer))
    (list *global-keymap*)))

#+nil (defgeneric compute-completion (buffer pos))

(define-command delete-buffer (&optional (buffer (buffer-at-focus)))
  (when (frame-root buffer)
    (bury-buffer buffer))
  (with-current-buffer buffer
    (on-buffer-delete buffer)
    (dolist (style (styles buffer))
      (remove-observer (css-cell style) buffer
                       :key (lambda (f) (and (typep f 'update-style)
                                             (slot-value f 'buffer)))))
    (cera.d:js cera.d:*driver*
               (format nil "Ceramic.closeBuffer(~S)" (id buffer)))
    (bt:with-recursive-lock-held (*buffer-table-lock*)
      (remhash (slot-value buffer 'id) *buffer-table*)
      (remhash (name buffer) *buffer-name-table*))))

(defun get-buffer-create (name)
  (bt:with-recursive-lock-held (*buffer-table-lock*)
    (or (gethash name *buffer-name-table*)
        (make-instance 'buffer :name name))))

;;; Parenscript utils

(defun assign-neomacs-id (node)
  (setf (attribute node "neomacs-identifier")
        (princ-to-string (incf (next-neomacs-id (find-submode 'neomacs-mode)))))
  node)

(ps:defpsmacro js-node (node)
  (cond ((text-node-p node)
          (if-let (next (next-sibling node))
            `(ps:chain (js-node ,next) previous-sibling)
            `(ps:chain (js-node ,(parent node)) last-child)))
         ((element-p node)
          (if (equal (tag-name node) "body")
              `(ps:chain document body)
              (let ((id (attribute node "neomacs-identifier")))
                `(ps:chain document
                           (query-selector
                            ,(format nil "[neomacs-identifier='~a']" id))))))
         ((null node) nil)
         (t (error "Unknown node type ~a." node))))

(ps:defpsmacro js-node-1 (node)
  `(ps:lisp `(js-node ,,node)))

(defun get-bounding-client-rect (node)
  (evaluate-javascript
   (let (ps:*parenscript-stream*)
     (ps:ps*
      `(let ((r (ps:chain (js-node ,node) (get-bounding-client-rect))))
         (list (ps:chain r x) (ps:chain r y)
               (ps:chain r width) (ps:chain r height)))))
   (host node)))

(ps:defpsmacro pos-bounding-rect (marker-or-pos)
  (let ((pos (resolve-marker marker-or-pos)))
    (ematch pos
      ((text-pos node offset)
       `(let ((range (ps:new -range))
              (node (js-node ,node)))
          (ps:chain range (set-start node ,offset))
          (ps:chain range (set-end node ,offset))
          (ps:chain range (get-bounding-client-rect))))
      ((end-pos node)
       `(ps:chain (js-node ,node) (get-bounding-client-rect))))))

;;; Render focus

(defun render-focus (pos)
  (setq pos (resolve-marker pos))
  (send-dom-update
   (bind ((node (node-after pos))
          (parent (node-containing pos))
          (scroll-margin (scroll-margin (host pos))))
     `(let (anchor-x anchor-y)
        (dolist (e (ps:chain document (get-elements-by-class-name "focus")))
          (ps:chain e class-list (remove "focus")))
        (dolist (e (ps:chain document (get-elements-by-class-name "focus-tail")))
          (ps:chain e class-list (remove "focus-tail")))
        (let ((overlay (ps:chain document (get-element-by-id "neomacs-cursor"))))
          (when overlay (setf (ps:chain overlay style display) "none")))
        (let ((highlight (ps:chain -c-s-s highlights (get "neomacs"))))
          (when highlight (ps:chain highlight (clear))))

        ,(if (or (characterp node)
                 (and node (equal (tag-name node) "br")))
             `(let ((range (ps:new (-range))))
                ,(if (characterp node)
                     `(let* ((text-node (js-node ,(text-pos-node pos)))
                             (parent (ps:chain text-node parent-node)))
                        (ps:chain range (set-start text-node
                                                   ,(text-pos-offset pos)))
                        (ps:chain range (set-end text-node
                                                 ,(1+ (text-pos-offset pos)))))
                     `(let ((element (js-node ,node)))
                        (ps:chain range (select-node element))))
                (let ((rect (ps:chain range (get-bounding-client-rect))))
                  (setq anchor-x (ps:chain rect x))
                  (setq anchor-y (ps:chain rect y))
                  (if (> (ps:chain rect width) 5)
                      (let ((highlight (ps:chain -c-s-s highlights (get "neomacs"))))
                        (unless highlight
                          (setq highlight (ps:new (-highlight)))
                          (ps:chain -c-s-s highlights (set "neomacs" highlight)))
                        (ps:chain highlight (add range)))
                      (let ((overlay (ps:chain document (get-element-by-id "neomacs-cursor"))))
                        (unless overlay
                          (setq overlay (ps:chain document (create-element "div")))
                          (setf (ps:chain overlay id) "neomacs-cursor")
                          (ps:chain document body (append-child overlay)))
                        (setf (ps:chain overlay style display) "inline")
                        (setf (ps:chain overlay style left)
                              (+ (ps:chain rect x) (ps:chain window scroll-x) "px")
                              (ps:chain overlay style top)
                              (+ (ps:chain rect y) (ps:chain window scroll-y) "px")
                              (ps:chain overlay style width)
                              (+ (ps:chain rect width) "px")
                              (ps:chain overlay style height)
                              (+ (ps:chain rect height) "px")))))
                nil)
             `(let ((element (js-node ,(or node parent))))
                (ps:chain element class-list
                          (add ,(if node "focus" "focus-tail")))
                (let ((rect (ps:chain element (get-bounding-client-rect))))
                  (setq anchor-x (ps:chain rect ,(if node 'left 'right)))
                  (setq anchor-y (ps:chain rect ,(if node 'top 'bottom))))))
        (ps:chain window
                  (scroll-to
                   (+ (ps:chain window scroll-x)
                      (min (- anchor-x (* ,scroll-margin (ps:chain window inner-width))) 0)
                      (max (- anchor-x (* ,(- 1 scroll-margin) (ps:chain window inner-width))) 0))
                   (+ (ps:chain window scroll-y)
                      (min (- anchor-y (* ,scroll-margin (ps:chain window inner-height))) 0)
                      (max (- anchor-y (* ,(- 1 scroll-margin) (ps:chain window inner-height))) 0))))))
   pos))

;;; Read-only state

(define-condition read-only-error (error)
  ((buffer :initarg :buffer))
  (:report "~a is read only." buffer))

(defvar *inhibit-read-only* nil)

(defun check-read-only (buffer)
  (unless *inhibit-read-only*
    (restart-case
        (when (read-only-p buffer)
          (error 'read-only-error :buffer buffer))
      (continue ()
        :report "Go on write to this buffer.")
      (continue* ()
        :report "Make buffer writable and go on."
        (setf (read-only-p buffer) nil)))))

;;; Styles

(defun update-style (buffer style)
  (let ((id (format nil "neomacs-style-~a" style)))
    (with-current-buffer buffer
      (send-dom-update
       `(let ((element (ps:chain document (get-element-by-id ,id))))
          (unless element
            (setq element (ps:chain document (create-element "style")))
            (setf (ps:chain element id) ,id)
            (ps:chain document head (append-child element)))
          (setf (ps:chain element inner-h-t-m-l)
                ,(cell-ref (css-cell style))))
       buffer))))

(defun remove-style (buffer style)
  (let ((id (format nil "neomacs-style-~a" style)))
    (with-current-buffer buffer
      (send-dom-update
       `(let ((element (ps:chain document (get-element-by-id ,id))))
          (when element
            (ps:chain element (remove))))
       buffer))))

(defmethod (setf styles) (new-val (buffer buffer))
  (dolist (style (set-difference new-val (slot-value buffer 'styles)))
    (update-style buffer style)
    (add-observer (css-cell style)
                  (nclo update-style (cell)
                    (declare (ignore cell))
                    (update-style buffer style))))
  (dolist (style (set-difference (slot-value buffer 'styles) new-val))
    (remove-style buffer style)
    (remove-observer (css-cell style) buffer
                     :key (lambda (f) (and (typep f 'update-style)
                                           (slot-value f 'buffer)))))
  (setf (slot-value buffer 'styles) new-val))

(defstyle default `(:font-family "Verdana"))
(defstyle focus `(:background-color "#f0f7ff"))
(defstyle selection `(:background-color "#bde1ff"))
(defstyle keyword `(:color "#fd79a8"))
(defstyle macro `(:color "#fd79a8"))
(defstyle special-operator `(:color "#fd79a8"))
(defstyle string `(:color "#a29bfe"))
(defstyle comment `(:color "#777"))
(defstyle focus-tail
    `(((:append "::after") :content " " :inherit selection)
      :inherit focus))
(defstyle cursor
    `(:position "absolute"
      :min-height "1em"
      :min-width "0.3em"
      :z-index "-1"
      :inherit selection))

(defstyle buffer
    `(("body" :inherit default)
      (".focus" :inherit focus)
      (".focus-tail" :inherit focus-tail)
      ("::highlight(neomacs)" :inherit cursor)
      ("#neomacs-cursor" :inherit cursor)))
