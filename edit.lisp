(in-package :neomacs)

(sera:export-always
    '(insert-nodes delete-nodes move-nodes extract-nodes
      splice-node join-nodes raise-node split-node
      wrap-node delete-node replace-node
      *clipboard-ring* *clipboard-ring-index*
      revert-buffer-aux))

;;; DOM Edit

(defun assign-neomacs-id (node)
  (setf (gethash "neomacs-identifier" (attributes node))
        (make-eager-cell
         :no-news-p #'equal
         :value (princ-to-string
                 (incf (next-neomacs-id (current-buffer))))))
  node)

(defun text-markers-in (neomacs text-node offset length)
  (iter (for m in (markers neomacs))
    (labels ((process-text-pos (pos)
               (when (eq (text-pos-node pos) text-node)
                 (when (and (>= (text-pos-offset pos) offset)
                            (or (not length)
                                (> (+ offset length)
                                   (text-pos-offset pos))))
                   (collect m)))))
      (match (slot-value m 'pos)
        ((and (text-pos) pos)
         (process-text-pos pos))
        ((%after-pos before)
         (when (text-pos-p before)
           (process-text-pos before)))))))

(defun move-text-markers
    (neomacs src-node src-offset dst-node dst-offset length)
  "Move markers in NEOMACS pointing inside text node.

Move markers pointing inside [SRC-OFFSET,SRC-OFFSET+LENGTH) of
SRC-NODE to [DST-OFFSET,DST-OFFSET+LENGTH) of DST-NODE.
If LENGTH is NIL, move everything after SRC-OFFSET."
  (check-type src-node text-node)
  (let ((ms (text-markers-in neomacs src-node src-offset length)))
    (dolist (m ms)
      (labels ((process-text-pos (pos)
                 (setf (text-pos-node pos) dst-node
                       (text-pos-offset pos)
                       (+ dst-offset (- (text-pos-offset pos) src-offset)))))
        (match (slot-value m 'pos)
          ((and (text-pos) pos)
           (process-text-pos pos))
          ((%after-pos before)
           (process-text-pos before)))))))

(defun merge-text-nodes (prev node)
  (let ((host (host node))
        (parent (parent node))
        (offset (length (text prev))))
    (unless *inhibit-dom-update*
      (evaluate-javascript
       (ps:ps
         (let* ((node (js-node-1 node))
                (prev (ps:chain node previous-sibling))
                (parent (js-node-1 parent)))
           (ps:chain prev (append-data (ps:chain node data)))
           (ps:chain parent (remove-child node))
           nil))
       (host node)))

    (setf (text prev)
          (sera:concat (text prev) (text node)))
    (remove-node node)
    (node-cleanup node)
    (move-text-markers
     host node 0 prev offset nil)
    (record-undo
     (nclo undo-merge-text ()
       (split-text-node prev offset node))
     (nclo redo-merge-text ()
       (merge-text-nodes prev node))
     host)))

(defun maybe-merge-text-nodes (node)
  (when node
    (let ((prev (previous-sibling node)))
      (when (and (text-node-p prev) (text-node-p node))
        (merge-text-nodes prev node)))))

(defun split-text-node (node offset next)
  (let ((parent (parent node))
        (host (host node)))
    (unless *inhibit-dom-update*
      (evaluate-javascript
       (ps:ps (ps:chain (js-node-1 node)
                        (split-text (ps:lisp offset))))
       (host node)))
    (node-setup next host)
    (insert-before parent next (next-sibling node))
    (psetf (text node) (subseq (text node) 0 offset)
           (text next) (subseq (text node) offset))
    (move-text-markers host node offset next 0 nil)
    (record-undo
     (nclo undo-split-text ()
       (merge-text-nodes node next))
     (nclo redo-split-text ()
       (split-text-node node offset next))
     host)))

(defun maybe-split-text-node (pos)
  "Split `text-node' at POS if possible.

Returns the node after the position after this operation."
  (match pos
    ((text-pos node offset)
     (if (= offset 0)
         node
         (let ((next (make-instance 'text-node
                                    :text ""
                                    :host (host pos))))
           (split-text-node node offset next)
           next)))
    (_ (node-after pos))))

(defun insert-nodes-2 (parent nodes reference)
  (unless *inhibit-dom-update*
    (evaluate-javascript
     (ps:ps
       (let* ((parent (js-node-1 parent))
              (reference (js-node-1 reference))
              (template (ps:chain document (create-element "template"))))
         (setf (ps:chain template inner-h-t-m-l)
               (ps:lisp
                (with-output-to-string (stream)
                  (dolist (c nodes)
                    (serialize c stream)))))
         (ps:chain -array
                   (from (ps:chain template content child-nodes))
                   (for-each (lambda (c)
                               (ps:chain parent (insert-before c reference)))))))
     (host parent)))

  (dolist (c nodes)
    (insert-before parent c reference))

  (record-undo
   (nclo undo-insert-nodes ()
     (delete-nodes-2 parent (car nodes) reference))
   (nclo redo-insert-nodes ()
     (insert-nodes-2 parent nodes reference))
   (host parent)))

(defun insert-nodes-1 (pos nodes)
  "Internal function for inserting NODES."
  (bind ((parent (node-containing pos))
         (reference (maybe-split-text-node pos)))
    (insert-nodes-2 parent nodes reference)
    (maybe-merge-text-nodes (car nodes))
    (maybe-merge-text-nodes reference)
    nil))

(defun node-setup (node host)
  "Setup NODE as a good citizen of HOST.

This assigns a neomacs-id attribute and run `on-node-setup'.

This function should be called on all nodes entering HOST's DOM
tree (which is usually taken care of by `insert-nodes')."
  (setf (host node) host)
  (when (element-p node)
    (assign-neomacs-id node))
  (on-node-setup host node))

(defun insert-nodes (marker-or-pos &rest things)
  "Insert THINGS at MARKER-OR-POS.

THINGS can be DOM nodes or strings, which are converted to text nodes."
  (with-delayed-evaluation
    (let* ((pos (resolve-marker marker-or-pos))
           (host (host pos)))
      (unless host
        (error "~a does not point inside an active document." pos))
      (check-read-only host pos)
      (let ((nodes
              (iter (for n in things)
                (when (stringp n)
                  (if (> (length n) 0)
                      (setq n (make-instance 'text-node :text n))
                      (setq n nil)))
                (when n (collect n)))))
        ;; Normalize text nodes, merge adjacent ones and remove empty ones.
        (setq nodes
              (iter (with last = nil)
                (for n in nodes)
                (if (and (text-node-p n)
                         (text-node-p last))
                    (setf (text last)
                          (str:concat (text last) (text n)))
                    (collect n))
                (setq last n)))
        (when nodes
          (record-undo
           (nclo undo-node-setup ()
             (mapc (alex:curry #'do-dom #'node-cleanup) nodes))
           (nclo redo-node-setup ()
             (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host)) nodes))
           host)
          (insert-nodes-1 pos (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host))
                                    nodes)))))))

(defun count-nodes-between (beg end)
  (iter (for node first beg then (next-sibling node))
    (while node)
    (until (eql node end))
    (sum 1)))

(defun delete-nodes-2 (parent beg end)
  (let ((reference (previous-sibling beg))
        (length (count-nodes-between beg end)))
    (unless *inhibit-dom-update*
      (evaluate-javascript
       (if reference
           (ps:ps
             (let ((parent (js-node-1 parent))
                   (reference (js-node-1 reference)))
               (dotimes (_ (ps:lisp length))
                 (ps:chain parent (remove-child
                                   (ps:chain reference next-sibling))))
               nil))
           (ps:ps
             (let ((parent (js-node-1 parent)))
               (dotimes (_ (ps:lisp length))
                 (ps:chain parent (remove-child
                                   (ps:chain parent first-child))))
               nil)))
       (host parent)))
    (let ((nodes
            (iter (for node = (if reference (next-sibling reference)
                                  (first-child parent)))
              (while node)
              (until (eql node end))
              (remove-node node)
              (collect node))))
      (relocate-markers (host parent) nodes
                        (or (normalize-node-pos end nil)
                            (end-pos (parent beg))))
      (record-undo
       (nclo undo-delete-nodes ()
         (insert-nodes-2 parent nodes end))
       (nclo redo-delete-nodes ()
         (delete-nodes-2 parent beg end))
       (host parent))
      nodes)))

(defun relocate-markers (host deleted-nodes end)
  (labels ((node (marker-or-pos)
             (ematch marker-or-pos
               ((marker pos) (node pos))
               ((element) marker-or-pos)
               ((text-pos node) node)
               ((end-pos node) node)
               ((%start-pos node) node)
               ((%after-pos before) (node before)))))
    (dolist (n deleted-nodes)
      (do-dom (lambda (deleted-node)
                (dolist (m (markers host))
                  (when (eq (node m) deleted-node)
                    #+nil (let ((pos (pos m))
                                (mp (trivial-garbage:make-weak-pointer m)))
                            (record-undo
                             (nclo undo-move-marker ()
                               (when-let (m (trivial-garbage:weak-pointer-value mp))
                                 (setf (pos m) pos)))
                             (nclo redo-move-marker ()
                               (when-let (m (trivial-garbage:weak-pointer-value mp))
                                 (setf (pos m) end)))
                             host))
                    (setf (pos m) end))))
        n))))

(defun delete-nodes-1 (beg end)
  (let ((parent (node-containing beg)))
    (when end
      (unless (eql parent (node-containing end))
        (error "~a and ~a are not siblings." beg end)))
    (let* (;; Quirk: `maybe-split-text-node' may invalidate `text-pos'
           ;; after it. A correct way to handle this is to
           ;; use `marker' instead of `text-pos', which might be costly.
           ;; Currently we rely on BEG is before END.
           ;; (However, how do we make `move-nodes-2' correct?
           ;; TODO: sort positions before spliting.
           (end (maybe-split-text-node end))
           (beg (maybe-split-text-node beg))
           (nodes (delete-nodes-2 parent beg end)))

      (maybe-merge-text-nodes end)
      nodes)))

(defun node-cleanup (node)
  "Release resources associated with NODE under its active document.

This runs `on-node-cleanup' and removes any observers on NODE's cell
slots.

This function should be called on all nodes leaving HOST's DOM
tree (which is usually taken care of by `delete-nodes' and
`extract-nodes')."
  (on-node-cleanup (host node) node)
  (iter (for s in (if (element-p node)
                      '(parent next-sibling previous-sibling
                        first-child last-child)
                      '(parent next-sibling previous-sibling)))
    (for c = (slot-value node s))
    (iter
      (for o in (lwcells::cell-outs c))
      (when (observer-cell-p o)
        (cell-set-function o nil))))
  (setf (host node) nil))

(defun delete-nodes-0 (beg end)
  (with-delayed-evaluation
    (let* ((beg (resolve-marker beg))
           (host (host beg))
           (end (resolve-marker end)))
      (unless host
        (error "~a does not point inside an active document." beg))
      (check-read-only host beg)
      ;; Account for this edge case
      (unless (or (end-pos-p beg) (equalp beg end))
        (let ((nodes (delete-nodes-1 beg end)))
          (mapc (alex:curry #'do-dom #'node-cleanup)
                nodes)
          (record-undo
           (nclo undo-node-cleanup ()
             (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host)) nodes))
           (nclo redo-node-cleanup ()
             (mapc (alex:curry #'do-dom #'node-cleanup) nodes))
           host)
          nodes)))))

(defun delete-nodes (beg end)
  "Delete nodes between BEG and END and returns nil.

BEG and END must be sibling positions.  If END is nil, delete children
starting from BEG till the end of its parent."
  (delete-nodes-0 beg end)
  nil)

(defun extract-nodes (beg end)
  "Like `delete-nodes', but clone and return the deleted contents."
  (mapcar #'clone-node (delete-nodes-0 beg end)))

(defun move-nodes-2 (src-parent beg end dst-parent reference)
  (let ((src-reference (previous-sibling beg))
        (length (count-nodes-between beg end)))

    (when (eql beg reference)
      (return-from move-nodes-2))

    (unless *inhibit-dom-update*
      (evaluate-javascript
       (if src-reference
           (ps:ps
             (let ((src-reference (js-node-1 src-reference))
                   (dst-parent (js-node-1 dst-parent))
                   (dst-reference (js-node-1 reference)))
               (dotimes (_ (ps:lisp length))
                 (ps:chain dst-parent
                           (insert-before
                            (ps:chain src-reference next-sibling)
                            dst-reference)))
               nil))
           (ps:ps
             (let ((src-parent (js-node-1 src-parent))
                   (dst-parent (js-node-1 dst-parent))
                   (dst-reference (js-node-1 reference)))
               (dotimes (_ (ps:lisp length))
                 (ps:chain dst-parent
                           (insert-before
                            (ps:chain src-parent first-child)
                            dst-reference)))
               nil)))
       (host dst-parent)))

    (iter (for node = (if src-reference (next-sibling src-reference)
                          (first-child src-parent)))
      (for i below length)
      (remove-node node)
      (insert-before dst-parent node reference))
    (record-undo
     (nclo undo-move-nodes ()
       (move-nodes-2 dst-parent beg reference src-parent end))
     (nclo redo-move-nodes ()
       (move-nodes-2 src-parent beg end dst-parent reference))
     (host dst-parent))))

(defun move-nodes (beg end to)
  "Move nodes between BEG and END to TO and returns nil.

BEG and END must be sibling positions.  If END is nil, move children
starting from BEG till the end of its parent."
  (with-delayed-evaluation
    (let* ((beg (resolve-marker beg))
           (end (resolve-marker end))
           (to (resolve-marker to))
           (src-parent (node-containing beg))
           (dst-parent (node-containing to))
           (host (host to)))

      (unless (host beg)
        (error "~a does not point inside an active document." beg))
      (unless (eq (host beg) host)
        (error "~a and ~a not point inside the same document." beg to))
      (check-read-only host beg)
      ;; If END is nil, also move marker at (end-pos src-parent)
      (unless end
        (dolist (m (markers host))
          (let ((pos (slot-value m 'pos)))
            (when (and (end-pos-p pos)
                       (eq (end-pos-node pos) src-parent))
              (setf (pos m) to)))))
      ;; Account for this edge case
      (when (or (end-pos-p beg) (equalp beg end))
        (return-from move-nodes nil))
      (setq end (maybe-split-text-node end)
            beg (maybe-split-text-node beg)
            to (maybe-split-text-node to))
      (move-nodes-2 src-parent beg end dst-parent to)
      (maybe-merge-text-nodes end)
      (maybe-merge-text-nodes to)
      (maybe-merge-text-nodes beg)
      nil)))

;;; Additional operations

(defun splice-node (node)
  "Splice children of NODE in place of NODE itself."
  (move-nodes (pos-down node) nil (pos-right node))
  (delete-nodes node (pos-right node)))

(defun join-nodes (dst src)
  "Join DST and SRC nodes.

This moves all children of SRC into DST and deletes SRC."
  (move-nodes src (pos-right src) (pos-down-last dst))
  (splice-node src))

(defun raise-node (node)
  "Replace NODE's parent with NODE."
  (move-nodes node (pos-right node) (pos-up node))
  (delete-nodes (pos-right node) (pos-right (pos-right node))))

(defun split-node (&optional (pos (focus)))
  "Split node containing POS at POS.

Let parent be the node containing POS. This involves inserting a clone
of parent after parent, and moving children after POS into the
clone. Returns the cloned node (i.e. the node after the split point)."
  (let* ((node (node-containing pos))
         (new-node (clone-node node nil))
         (dst (pos-right (pos-up pos))))
    (insert-nodes dst new-node)
    (move-nodes pos nil (end-pos new-node))
    new-node))

(defun wrap-node (node new-node)
  "Insert NEW-NODE around NODE.

NODE becomes the last child of NEW-NODE."
  (insert-nodes node new-node)
  (move-nodes node (pos-right node) (end-pos new-node)))

(defun wrap-nodes (beg end new-node)
  "Insert NEW-NODE around nodes between BEG and END.

BEG and END must be sibling positions. Nodes between BEG and END
become the last child of NEW-NODE."
  (insert-nodes beg new-node)
  (move-nodes beg end (end-pos new-node)))

(defun delete-node (node)
  "Delete a single NODE."
  (delete-nodes node (pos-right node)))

(defun replace-node (node new-node)
  "Replace NODE with NEW-NODE."
  (insert-nodes (pos-right node) new-node)
  (delete-node node))

(defun swap-nodes (node-1 node-2)
  (let ((pos (pos-right node-1)))
    (move-nodes node-1 pos (pos-right node-2))
    (move-nodes node-2 (pos-right node-2) pos)))

(defun erase-buffer ()
  "Delete all content of current buffer."
  (let ((*inhibit-dom-update* t))
    (delete-nodes (pos-down (document-root (current-buffer))) nil))
  (unless *inhibit-dom-update*
    (evaluate-javascript-sync
     "document.body.replaceChildren()"
     (current-buffer))))

(defun serialize-document (document-root styles stream)
  (write-string "<!DOCTYPE html>
<html><head>" stream)
  (dolist (style (reverse styles))
    (format stream "<style id=\"neomacs-style-~a\">" style)
    (write-string (cell-ref (css-cell style)) stream)
    (write-string "</style>" stream))
  (write-string "</head>" stream)
  (serialize document-root stream)
  (write-string "</html>" stream))

(defgeneric revert-buffer-aux (buffer)
  (:documentation "Regenerate the content of BUFFER.")
  (:method ((buffer buffer))
    (not-supported buffer 'revert-buffer))
  (:method :around ((buffer buffer))
    ;; Static HTML optimization:

    ;; Rather than using `insert-nodes' primitive editing primitives, we
    ;; just updates Lisp side DOM, and serialize it as a static HTML
    ;; then serve to renderer. This is much better than renderer-side
    ;; DOM manipulation for larger files.
    (let ((*inhibit-dom-update* t))
      (call-next-method))
    (evaluate-javascript
     (format nil "Contents[~s]='~a'"
             (id buffer)
             (quote-js
              (with-output-to-string (s)
                (serialize-document
                 (document-root buffer)
                 (styles buffer)
                 s))))
     :global)
    (load-url buffer (format nil "neomacs://contents/~a" (id buffer)))))

(define-command revert-buffer ()
  "Regenerate the content of current buffer.

The behavior can be customized via `revert-buffer-aux'."
  (let ((*inhibit-read-only* t))
    (revert-buffer-aux (current-buffer))))

;;; Editing commands

(defun self-insert-char ()
  "Get the last typed character from `*this-command-keys*'.

Called by `self-insert-command' to get the character for insertion."
  (let ((desc (key-description (lastcar *this-command-keys*))))
    (cond ((= (length desc) 1) (aref desc 0))
          ((equal desc "space") #\Space))))

(define-command self-insert-command ()
  "Insert the last typed character into current buffer."
  (undo-auto-amalgamate)
  (insert-nodes (focus) (string (self-insert-char)))
  (setf (adjust-marker-direction (current-buffer)) 'backward))

(define-command new-line (&optional (marker (focus)))
  "Insert a new line node (br element) at MARKER."
  (insert-nodes marker (make-new-line-node)))

(defgeneric trivial-p-aux (buffer node)
  (:method ((buffer buffer) node) nil))

(defun backward-delete-until (marker predicate)
  (let ((beg (npos-prev-until marker predicate))
        (end (pos marker))
        (buffer (host marker))
        deleted)
    (iter (until (pos-right end))
      (for next = (pos-right (pos-up end)))
      (while next) (setq end next))
    (map-range (range beg end)
               (lambda (beg end)
                 (unless (or (equal beg end)
                             (and (end-pos-p beg) (not end)))
                   (unless
                       (every (alex:curry #'trivial-p-aux buffer)
                              (delete-nodes-0 beg end))
                     (setq deleted t)))))
    (unless deleted
      (when (end-pos-p beg)
        (let* ((prev (node-containing beg))
               (next (next-sibling prev)))
          (when (and (element-p next)
                     (equal (attribute prev "class")
                            (attribute next "class")))
            (join-nodes prev next)
            (return-from backward-delete-until))))
      (setf (pos marker) beg))))

(define-command backward-delete (&optional (marker (focus)))
  (undo-auto-amalgamate)
  (setf (adjust-marker-direction (host marker))
        'backward)
  (backward-delete-until marker #'selectable-p))

(defun forward-delete-until (marker predicate)
  (let ((end (npos-next-until marker predicate))
        (beg (pos marker))
        (buffer (host marker))
        deleted)
    (iter (until (pos-left beg))
      (for next = (pos-up beg))
      (while next) (setq beg next))
    (map-range (range beg end)
               (lambda (beg end)
                 (unless (or (equal beg end)
                             (and (end-pos-p beg) (not end)))
                   (unless
                       (every (alex:curry #'trivial-p-aux buffer)
                              (delete-nodes-0 beg end))
                     (setq deleted t)))))
    (unless deleted
      (when (not (pos-left end))
        (let* ((next (node-containing end))
               (prev (previous-sibling next)))
          (when (and (element-p prev)
                     (equal (attribute prev "class")
                            (attribute next "class")))
            (join-nodes prev next)
            (return-from forward-delete-until))))
      (setf (pos marker) end))))

(define-command forward-delete (&optional (marker (focus)))
  (undo-auto-amalgamate)
  (with-advance-p (marker nil)
    (forward-delete-until marker #'selectable-p)))

(define-command backward-delete-word (&optional (marker (focus)))
  (let ((end (pos marker)))
    (backward-word marker)
    (delete-range (range marker end))))

(define-command forward-delete-word (&optional (marker (focus)))
  (let ((beg (pos marker)))
    (forward-word marker)
    (delete-range (range beg marker))))

(define-command backward-delete-element (&optional (marker (focus)))
  (backward-element marker)
  (delete-nodes marker (pos-right marker)))

(defstruct clipboard-item
  (styles) (nodes))

(defvar *clipboard-ring* (containers:make-ring-buffer 1000 t))

(defvar *clipboard-ring-index* 0)

(defvar *system-clipboard-last-read* nil)

(defun clipboard-insert (items)
  (if items
      (progn
        (containers:insert-item
         *clipboard-ring*
         (make-clipboard-item
          :styles (styles (current-buffer))
          :nodes items))
        (let ((text
                (handler-case
                    (with-output-to-string (s)
                      (dolist (n items)
                        (write-dom-aux
                         (current-buffer)
                         n s)))
                  ;; Fallback to plain text
                  (not-supported ()
                    (with-output-to-string (s)
                      (dolist (n items)
                        (write-string (text-content n) s)))))))
          (evaluate-javascript
           (ps:ps
             (ps:chain clipboard (write-text (ps:lisp text))))
           :global)
          (setq *system-clipboard-last-read* text)))
      (user-error "Nothing to copy")))

(defun read-system-clipboard-maybe ()
  (let ((text (evaluate-javascript-sync
               "clipboard.readText()"
               :global)))
    (unless (equal text *system-clipboard-last-read*)
      (setq *system-clipboard-last-read* text)
      (containers:insert-item
       *clipboard-ring*
       (make-clipboard-item
        :nodes (list text))))))

(define-command cut-element ()
  "Cut element under focus and save into clipboard.

If selection is active, cut selected contents instead."
  (if (selection-active (current-buffer))
      (progn
        (clipboard-insert
         (extract-range
          (range (selection-marker (current-buffer)) (focus))))
        (setf (selection-active (current-buffer)) nil))
      (let ((pos (or (pos-up-ensure (focus) #'element-p)
                     (error 'top-of-subtree))))
        (clipboard-insert (extract-nodes pos (pos-right pos))))))

(define-command copy-element ()
  "Copy element under focus into clipboard.

If selection is active, copy selected contents instead."
  (if (selection-active (current-buffer))
      (progn
        (clipboard-insert
         (clone-range
          (range (selection-marker (current-buffer)) (focus))))
        (setf (selection-active (current-buffer)) nil))
      (let ((pos (or (pos-up-ensure (focus) #'element-p)
                     (error 'top-of-subtree))))
        (clipboard-insert (list (clone-node pos))))))

(define-command paste ()
  "Paste the first item in clipboard."
  (setq *clipboard-ring-index* 0)
  (read-system-clipboard-maybe)
  (let ((item (containers:item-at *clipboard-ring* *clipboard-ring-index*)))
    (setf (advance-p (selection-marker (current-buffer))) nil)
    (setf (pos (selection-marker (current-buffer))) (pos (focus)))
    (apply #'insert-nodes (focus)
           (mapcar #'clone-node (clipboard-item-nodes item)))))

(define-command paste-pop ()
  "Cycle pasted contents, or prompt for a clipboard item to paste."
  (undo-auto-amalgamate)
  (if (member *last-command* '(paste paste-pop))
      (progn
        (incf *clipboard-ring-index*)
        (delete-range
         (range (selection-marker (current-buffer)) (focus))))
      (progn
        (read-system-clipboard-maybe)
        (read-from-minibuffer
         "Paste from clipboard: "
         :mode 'clipboard-minibuffer-mode
         :completion-buffer
         (make-completion-buffer
          '(clipboard-list-mode completion-buffer-mode)))))
  (let ((item (containers:item-at *clipboard-ring* *clipboard-ring-index*)))
    (apply #'insert-nodes (focus)
           (mapcar #'clone-node (clipboard-item-nodes item)))))

(define-command forward-cut (&optional (pos (focus)))
  "Cut until end of line and save into clipboard."
  (iter (with end = (copy-pos pos))
    (setq end (npos-right end))
    (unless end
      (clipboard-insert (extract-nodes pos nil))
      (return))
    (when (line-end-p end)
      (clipboard-insert (extract-nodes pos end))
      (return))))

(define-command swap-next-element (&optional (pos (focus)))
  (let* ((element (or (pos-up-ensure pos #'element-p)
                      (error 'top-of-subtree)))
         (dst (or (pos-right-until element #'graphic-element-p)
                  (error 'end-of-subtree))))
    (swap-nodes element dst)))

(define-command swap-previous-element (&optional (pos (focus)))
  (let* ((element (or (pos-up-ensure pos #'element-p)
                      (error 'top-of-subtree)))
         (dst (or (pos-left-until element #'graphic-element-p)
                  (error 'end-of-subtree))))
    (swap-nodes element dst)))

;;; Presentations

(defun presentation-at
    (pos-or-marker &optional (type t) error-p)
  "Find enclosing element with a presentation attribute of TYPE.

If ERROR-P is t, signal a `user-error' if no such element is found"
  (let ((pos (resolve-marker pos-or-marker))
        presentation)
    (iter
      (when (element-p pos)
        (when-let (p (attribute pos 'presentation))
          (when (typep p type)
            (setq presentation p))))
      (until presentation)
      (setq pos (pos-up pos))
      (while pos))
    (when (and error-p (not presentation))
      (user-error "No ~a under focus" type))
    presentation))

(defun attach-presentation (element object)
  (setf (attribute element 'presentation) object)
  element)

;;; Default key bindings

(define-keys :global
  "backspace" 'backward-delete
  "space" 'self-insert-command
  "enter" 'new-line
  "M-backspace" 'backward-delete-word
  "C-M-backspace" 'backward-delete-element
  "C-d" 'forward-delete
  "M-d" 'forward-delete-word
  "C-w" 'cut-element
  "M-w" 'copy-element
  "C-y" 'paste
  "M-y" 'paste-pop
  "C-k" 'forward-cut)

(iter (for i from 32 below 127)
  (for char = (code-char i))
  (unless (member char '(#\ ))
    (set-key *global-keymap* (string char) 'self-insert-command)))

(iter (for i from 160 below 255)
  (for char = (code-char i))
  (set-key *global-keymap* (string char) 'self-insert-command))
