(in-package :neomacs)

(sera:export-always
    '(node parent next-sibling previous-sibling host
      text-node text
      element first-child last-child tag-name
      attributes invisible-p
      element-p text-node-p tag-name-p
      clone-node child-nodes children text-content
      get-elements-by-class-name
      do-dom do-elements next-node previous-node
      attribute set-attribute-function *record-attribute-undo*
      add-class remove-class class-p
      insert-before append-child append-children
      remove-node dom))

(eval-always
  (defmodel node ()
      ((parent :cell nil)
       (next-sibling :cell nil)
       (previous-sibling :cell nil)
       (host :initform nil :accessor host :initarg :host)))

  (defmodel text-node (node)
      ((text :cell (error "Must supply :text.")
             :initarg :text)))

  (defmodel element (node)
      ((first-child :cell nil)
       (last-child :cell nil)
       (tag-name :initform (error "Must supply :tag-name") :reader tag-name
                 :initarg :tag-name)
       (attributes :initform (make-hash-table :test 'equal) :reader attributes)
       (invisible-p :cell (or (when-let (parent (parent self))
                                (invisible-p parent))
                              (class-p self "invisible"))
                  :reader invisible-p))))

(defmethod parent ((_ null)))
(defmethod next-sibling ((_ null)))
(defmethod previous-sibling ((_ null)))
(defmethod text ((_ null)))
(defmethod first-child ((_ null)))
(defmethod last-child ((_ null)))
(defmethod tag-name ((_ null)))

(declaim (inline element-p text-node-p make-element
                 class-p tag-name-p))

(defun element-p (object)
  (typep object 'element))

(defun text-node-p (object)
  (typep object 'text-node))

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

(defun attribute-cell (element name)
  (or (gethash name (attributes element))
      (setf (gethash name (attributes element))
            (add-attribute-observer
             (make-eager-cell :no-news-p #'equal)
             element name))))

(defun (setf attribute-cell) (new-val element name)
  (setf (gethash name (attributes element))
        (add-attribute-observer new-val element name)))

(defvar *record-attribute-undo* nil
  "Record undo information when setting attributes.

Note that this only affects `(setf attribute)', not computed
attributes (`set-attribute-function').")

(defun attribute (element name)
  (cell-ref (attribute-cell element name)))

(defun (setf attribute) (new-val element name)
  (if *record-attribute-undo*
      (let ((old-val (cell-ref (attribute-cell element name))))
        (setf (cell-ref (attribute-cell element name)) new-val)
        (record-undo
         (nclo undo-set-attribute ()
           (setf (cell-ref (attribute-cell element name))
                 old-val))
         (nclo redo-set-attribute ()
           (setf (cell-ref (attribute-cell element name))
                 new-val))
         (host element))
        new-val)
      (setf (cell-ref (attribute-cell element name))
            new-val)))

(defun set-attribute-function (element attribute function)
  "Set a computed attribute.
Make ATTRIBUTE of ELEMENT computed by calling FUNCTION with
ELEMENT as a single argument."
  (cell-set-function (attribute-cell element attribute)
                     (lambda () (funcall function element))))

(defvar *inhibit-dom-update* nil
  "Inhibit pushing changes to renderer.")

(defun add-attribute-observer (cell node attribute)
  "Add an observer to CELL,
which ensures renderer side ATTRIBUTE of NODE matches value of CELL.
If ATTRIBUTE is not a string, this is a no-op."
  (labels ((update (cell)
             (unless *inhibit-dom-update*
               (when-let (host (host node))
                 (let ((value (cell-ref cell)))
                   (evaluate-javascript
                    (if value
                        (ps:ps
                          (ps:chain (js-node-1 node)
                                    (set-attribute (ps:lisp attribute)
                                                   (ps:lisp value))))
                        (ps:ps
                          (ps:chain (js-node-1 node)
                                    (remove-attribute (ps:lisp attribute)))))
                    host))))))
    (when (stringp attribute)
      (add-observer cell #'update))
    cell))

(defun make-element (tag-name &rest attributes &key &allow-other-keys)
  (lret ((element (make-instance 'element :tag-name tag-name)))
    (iter (for (k v) on attributes by #'cddr)
      (if (eql k :children)
          (dolist (c v)
            (when (stringp c)
              (setq c (make-instance 'text-node :text c)))
            (append-child element c))
          (setf (attribute element (string-downcase (symbol-name k))) v)))))

(defun class-p (node class &rest more-classes)
  "Test if NODE is an element of one of CSS CLASS or MORE-CLASSES."
  (and (element-p node)
       (intersection
        (str:split #\Space (attribute node "class"))
        (cons class more-classes)
        :test 'equal)))

(defun tag-name-p (node tag-name)
  "Test if NODE is an element with TAG-NAME."
  (and (element-p node)
       (equal tag-name (tag-name node))))

(defun add-class (element class)
  "Add CSS CLASS to ELEMENT."
  (unless (class-p element class)
    (setf (attribute element "class")
          (str:concat (attribute element "class") " " class))))

(defun remove-class (element class)
  "Remove CSS CLASS from ELEMENT."
  (let ((class-list (str:split #\Space (attribute element "class"))))
    (when (member class class-list :test 'equal)
      (setf (attribute element "class")
            (str:join #\space (remove class class-list :test 'equal))))))

(defun make-new-line-node ()
  (make-instance 'element :tag-name "br"))

(defun new-line-node-p (node)
  (and (element-p node)
       (or (equal (attribute node "class")
                  "newline")
           (equal (tag-name node) "br"))))

(defmethod print-object ((node element) stream)
  (print-unreadable-object (node stream :identity t :type t)
    (format stream "~a (~a)"
            (tag-name node) (attribute node "class"))))

(defmethod print-object ((node text-node) stream)
  (print-unreadable-object (node stream :identity t :type t)
    (format stream "~a" (text node))))

(defvar *serialize-exclude-attributes* nil)

(defun serialize (node stream)
  "Serialize NODE to HTML and write to STREAM.
STREAM can also be
  - T, denotes `*standard-output*',
  - nil, returns the result as a string."
  (plump:serialize
   (labels ((process (node)
              (etypecase node
                (element
                 (lret ((n (make-instance
                            'plump:element :parent nil
                            :tag-name (tag-name node))))
                   (iter (for (k v) in-hashtable (attributes node))
                     (when (stringp k)
                       (unless (member k *serialize-exclude-attributes* :test 'equal)
                         (when-let (value (cell-ref v))
                           (setf (gethash k (plump:attributes n)) value)))))
                   (setf (plump:children n)
                         (iter (for c first (first-child node)
                                    then (next-sibling c))
                           (while c)
                           (collect (process c) result-type 'vector)))))
                (text-node
                 (make-instance 'plump:text-node :parent nil
                                :text (text node))))))
     (process node))
   stream))

(defgeneric clone-node (node &optional deep)
  (:documentation
   "Clone NODE.

If DEEP is non-nil, recursively clone all descendant.
DEEP defaults to T.")
  (:method ((node text-node) &optional (deep t))
           (declare (ignore deep))
           (make-instance 'text-node :text (text node)))
  (:method ((node element) &optional (deep t))
           (lret ((n (make-instance 'element :tag-name (tag-name node))))
             (iter (for (k v) in-hashtable (attributes node))
               (setf (attribute n k) (cell-ref v)))
             (when deep
               (iter (for c first (first-child node)
                          then (next-sibling c))
                 (while c)
                 (insert-before n (clone-node c) nil)))))
  (:method ((node string) &optional deep)
    (declare (ignore deep))
    node))

(defun insert-before (parent new-node reference)
  "Insert NEW-NODE under PARENT before REFERENCE.

If REFERENCE is nil, insert NEW-NODE as last child of PARENT.
Returns NEW-NODE."
  (assert (or (not reference) (eql (parent reference) parent)))
  (let ((prev (if reference (previous-sibling reference)
                  (last-child parent))))
    (setf (next-sibling new-node) reference
          (previous-sibling new-node) prev
          (parent new-node) parent)
    (if prev (setf (next-sibling prev) new-node)
        (setf (first-child parent) new-node))
    (if reference (setf (previous-sibling reference) new-node)
        (setf (last-child parent) new-node)))
  new-node)

(defun append-child (parent new-node)
  "Insert NEW-NODE as last child of PARENT.

Returns NEW-NODE."
  (insert-before parent new-node nil))

(defun append-children (parent children)
  "Insert CHILDREN as last children of PARENT.

Returns CHILDREN."
  (dolist (c children)
    (insert-before parent c nil))
  children)

(defun remove-node (node)
  "Remove NODE from DOM tree."
  (let ((next (next-sibling node))
        (prev (previous-sibling node))
        (parent (parent node)))
    (if next (setf (previous-sibling next) prev)
        (setf (last-child parent) prev))
    (if prev (setf (next-sibling prev) next)
        (setf (first-child parent) next))
    node))

(defun child-nodes (node)
  "Return immediate child nodes of NODE as a list."
  (when (element-p node)
    (iter (for c first (first-child node)
               then (next-sibling c))
      (while c)
      (collect c))))

(defun children (node)
  "Return immediate child elements of NODE as a list."
  (when (element-p node)
    (iter (for c first (first-child node)
               then (next-sibling c))
      (while c)
      (when (element-p c)
        (collect c)))))

(defun map-dom (function node)
  (labels ((process (node)
             (funcall function node
                      (when (element-p node)
                        (iter (for c first (first-child node)
                                   then (next-sibling c))
                          (while c)
                          (collect (process c)))))))
    (process node)))

(defun do-dom (function node)
  "Call FUNCTION on every descendant of NODE in post-order.
This includes `element's and `text-node's. Returns NODE."
  (map-dom (lambda (node results)
             (declare (ignore results))
             (funcall function node))
           node)
  node)

(defun do-elements (function node)
  "Like `do-dom', but only call FUNCTION on `element's. Returns NODE."
  (map-dom (lambda (node results)
             (declare (ignore results))
             (when (element-p node)
               (funcall function node)))
           node)
  node)

(defun next-node (node)
  "Next DOM node in pre-order traversal."
  (or (and (element-p node) (first-child node))
      (iter
        (when-let (next (next-sibling node))
          (return next))
        (setq node (parent node))
        (while node))))

(defun previous-node (node)
  "Previous DOM node in pre-order traversal."
  (if-let (prev (previous-sibling node))
    (loop
      (if-let (child (and (element-p prev)
                          (last-child prev)))
        (setq prev child)
        (return prev)))
    (parent node)))

(defun text-content (node)
  (map-dom
   (lambda (node results)
     (etypecase node
       (text-node (text node))
       (element (apply #'sera:concat results))))
   node))

(defun get-elements-by-class-name (node class)
  "Find all descendant elements of NODE with CLASS."
  (let (nodes)
    (do-elements
     (lambda (child)
       (when (class-p child class)
         (push child nodes)))
     node)
    (nreverse nodes)))

(defun dom (sexp)
  (labels ((process (sexp)
             (etypecase sexp
               (cons
                (multiple-value-bind (attrs children)
                    (split-args (cdr sexp))
                  (lret ((el (make-instance
                              'element :tag-name
                              (string-downcase (symbol-name (car sexp))))))
                    (iter (for (k v) on attrs by #'cddr)
                      (setf (attribute el (string-downcase (symbol-name k))) v))
                    (append-children el (mapcar #'process children)))))
               ((or element text-node)
                sexp)
               (string
                (make-instance 'text-node :text sexp)))))
    (process sexp)))
