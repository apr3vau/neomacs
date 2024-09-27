(in-package :neomacs)

;;; DOM Edit

(defun assign-neomacs-id (node)
  (setf (attribute node "neomacs-identifier")
        (princ-to-string (incf (next-nyxt-id (find-submode 'neomacs-mode)))))
  node)

(defvar *inhibit-dom-update* nil)

(defun send-dom-update (parenscript)
  (unless *inhibit-dom-update*
    (if *inside-dom-update-p*
        (let ((ps:*parenscript-stream* *dom-update-stream*))
          (ps:ps* `(ignore-errors ,parenscript)))
        (progn
          (ffi-buffer-evaluate-javascript
           (current-buffer)
           (let (ps:*parenscript-stream*)
             (ps:ps* `(progn ,parenscript nil))))
          nil))))

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
           (process-text-pos before)))
        (when (eq m (focus-marker (host m)))
          (nhooks:run-hook (focus-move-hook (host m)) (pos m) (pos m)))))))

(defun merge-text-nodes (prev node)
  (let ((host (host node))
        (parent (parent node))
        (offset (length (text prev))))
    (send-dom-update
     `(let* ((node (js-node ,node))
             (prev (ps:chain node previous-sibling))
             (parent (js-node ,parent)))
        (ps:chain console (log node))
        (ps:chain prev (append-data (ps:chain node data)))
        (ps:chain parent (remove-child node))
        nil))

    (setf (text prev)
          (sera:concat (text prev) (text node)))
    (remove-node node)
    (move-text-markers
     host node 0 prev offset nil)
    (record-undo
     (nclo undo-merge-text ()
       (split-text-node prev offset node))
     (nclo redo-merge-text ()
       (merge-text-nodes prev node)))))

(defun maybe-merge-text-nodes (node)
  (when node
    (let ((prev (previous-sibling node)))
      (when (and (text-node-p prev) (text-node-p node))
        (merge-text-nodes prev node)))))

(defun split-text-node (node offset next)
  (let ((parent (parent node))
        (host (host node)))
    (send-dom-update
     `(ps:chain (js-node ,node) (split-text ,offset)))
    (insert-before parent next (next-sibling node))
    (psetf (text node) (subseq (text node) 0 offset)
           (text next) (subseq (text node) offset))
    (move-text-markers host node offset next 0 nil)
    (record-undo
     (nclo undo-split-text ()
       (merge-text-nodes node next))
     (nclo redo-split-text ()
       (split-text-node node offset next)))))

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
  (send-dom-update
   `(let* ((parent (js-node ,parent))
           (reference (js-node ,reference))
           (template (ps:chain document (create-element "template"))))
      (setf (ps:chain template inner-h-t-m-l)
            ,(with-output-to-string (stream)
               (dolist (c nodes)
                 (serialize c stream))))
      (ps:chain -array
                (from (ps:chain template content child-nodes))
                (for-each (lambda (c)
                            (ps:chain parent (insert-before c reference)))))
      nil))

  (dolist (c nodes)
    (insert-before parent c reference))

  (record-undo
   (nclo undo-insert-nodes ()
     (delete-nodes-2 parent (car nodes) reference))
   (nclo redo-insert-nodes ()
     (insert-nodes-2 parent nodes reference))))

(defun insert-nodes-1 (pos nodes)
  "Internal function for inserting NODES."
  (bind ((parent (node-containing pos))
         (reference (maybe-split-text-node pos)))
    (insert-nodes-2 parent nodes reference)
    (maybe-merge-text-nodes (car nodes))
    (maybe-merge-text-nodes reference)
    nil))

(defun node-setup (node host)
  (setf (host node) host)
  (when (element-p node)
    (assign-neomacs-id node)
    (hooks:run-hook (node-setup-hook host) node)))

(defun insert-nodes (marker-or-pos &rest things)
  (let* ((pos (resolve-marker marker-or-pos))
         (host (host pos)))
    (unless host
      (error "~a does not point inside an active document." pos))
    (check-read-only host)
    (let ((nodes (mapcar (lambda (n)
                           (if (stringp n)
                               (make-instance 'text-node :text n)
                               n))
                         things)))
      (record-undo
       (nclo undo-node-setup ()
         (mapc (alex:curry #'do-dom #'node-cleanup) nodes))
       (nclo redo-node-setup ()
         (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host)) nodes)))
      (insert-nodes-1 pos (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host))
                                nodes)))))

(defun count-nodes-between (beg end)
  (iter (for node first beg then (next-sibling node))
    (while node)
    (until (eql node end))
    (sum 1)))

(defun delete-nodes-2 (parent beg end)
  (let ((reference (previous-sibling beg))
        (length (count-nodes-between beg end)))
    (send-dom-update
     (if reference
         `(let ((parent (js-node ,parent))
                (reference (js-node ,reference)))
            (dotimes (_ ,length)
              (ps:chain parent (remove-child
                                (ps:chain reference next-sibling))))
            nil)
         `(let ((parent (js-node ,parent)))
            (dotimes (_ ,length)
              (ps:chain parent (remove-child
                                (ps:chain parent first-child))))
            nil)))
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
         (delete-nodes-2 parent beg end)))
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
                                 (setf (pos m) end)))))
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
  (when (element-p node)
    (iter (for s in '(parent next-sibling previous-sibling
                      first-child last-child))
      (for c = (slot-value node s))
      (iter
        (for o in (lwcells::cell-outs c))
        (when (observer-cell-p o)
          (cell-set-function o nil)))))
  (setf (host node) nil))

(defun delete-nodes-0 (beg end)
  (let* ((beg (resolve-marker beg))
         (host (host beg))
         (end (resolve-marker end)))
    (unless host
      (error "~a does not point inside an active document." beg))
    (check-read-only host)
    (let ((nodes (delete-nodes-1 beg end)))
      (mapc (alex:curry #'do-dom #'node-cleanup)
            nodes)
      (record-undo
       (nclo undo-node-cleanup ()
         (mapc (alex:curry #'do-dom (alex:rcurry #'node-setup host)) nodes))
       (nclo redo-node-cleanup ()
         (mapc (alex:curry #'do-dom #'node-cleanup) nodes)))
      nodes)))

(defun delete-nodes (beg end)
  (delete-nodes-0 beg end)
  nil)

(defun extract-nodes (beg end)
  (mapcar #'clone-node (delete-nodes-0 beg end)))

(defun move-nodes-2 (src-parent beg end dst-parent reference)
  (let ((src-reference (previous-sibling beg))
        (length (count-nodes-between beg end)))

    (send-dom-update
     (if src-reference
         `(let ((src-reference (js-node ,src-reference))
                (dst-parent (js-node ,dst-parent))
                (dst-reference (js-node ,reference)))
            (dotimes (_ ,length)
              (ps:chain dst-parent
                        (insert-before
                         (ps:chain src-reference next-sibling)
                         dst-reference)))
            nil)
         `(let ((src-parent (js-node ,src-parent))
                (dst-parent (js-node ,dst-parent))
                (dst-reference (js-node ,reference)))
            (dotimes (_ ,length)
              (ps:chain dst-parent
                        (insert-before
                         (ps:chain src-parent first-child)
                         dst-reference)))
            nil)))

    (iter (for node = (if src-reference (next-sibling src-reference)
                          (first-child src-parent)))
      (while node)
      (until (eql node end))
      (remove-node node)
      (insert-before dst-parent node reference)))
  (record-undo
   (nclo undo-move-nodes ()
     (move-nodes-2 dst-parent beg reference src-parent end))
   (nclo redo-move-nodes ()
     (move-nodes-2 src-parent beg end dst-parent reference))))

(defun move-nodes (beg end to)
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
    (check-read-only host)
    (setq end (maybe-split-text-node end)
          beg (maybe-split-text-node beg)
          to (maybe-split-text-node to))
    (move-nodes-2 src-parent beg end dst-parent to)
    (maybe-merge-text-nodes end)
    (maybe-merge-text-nodes to)
    (maybe-merge-text-nodes beg)
    nil))

(defun splice-node (node)
  (move-nodes (pos-down node) nil (pos-right node))
  (delete-nodes node (pos-right node)))

(defun join-nodes (dst src)
  (move-nodes src (pos-right src) (pos-down-last dst))
  (splice-node src))

(defun raise-node (node)
  (move-nodes node (pos-right node) (pos-up node))
  (delete-nodes (pos-right node) (pos-right (pos-right node))))

(defun split-node (pos)
  (let* ((node (node-containing pos))
         (new-node (clone-node node nil))
         (dst (pos-right (pos-up pos))))
    (insert-nodes dst new-node)
    (move-nodes pos nil (end-pos new-node))
    new-node))

;;; Editing commands

(define-command new-line (&optional (marker (focus)))
  (insert-nodes marker (make-new-line-node)))

(define-command backward-delete (&optional (marker (focus)))
  (undo-auto-amalgamate)
  (backward-node marker)
  (when-let (node (node-after marker))
    (unless (and (element-p node) (first-child node))
      (delete-nodes marker (pos-right marker)))))

(define-command forward-delete (&optional (marker (focus)))
  (undo-auto-amalgamate)
  (forward-node marker)
  (when-let (node (node-before marker))
    (unless (and (element-p node) (first-child node))
      (delete-nodes (pos-left marker) marker))))

(define-command backward-cut-word (&optional (marker (focus)))
  (with-dom-update (host marker)
    (let ((end (pos marker)))
      (backward-word marker)
      (let ((start (pos marker)))
        (if (and (text-pos-p end)
                 (eql (text-pos-node end)
                      (text-pos-node start)))
            (delete-nodes start end)
            (delete-nodes start nil))))))

(define-command cut-element (&optional (pos (focus)))
  (with-dom-update (host pos)
    (setq pos (or (pos-up-ensure pos #'element-p)
                  (error 'top-of-subtree)))
    (containers:insert-item (clipboard-ring *browser*)
                            (extract-nodes pos 1))))

(define-command copy-element (&optional (pos (focus)))
  (with-dom-update (host pos)
    (setq pos (or (pos-up-ensure pos #'element-p)
                  (error 'top-of-subtree)))
    (containers:insert-item (clipboard-ring *browser*)
                            (list (clone-node pos)))))

(define-command paste (&optional (neomacs (find-submode 'neomacs-mode)))
  (with-dom-update neomacs
    (let ((item (containers:current-item (clipboard-ring *browser*)))
          (marker (focus neomacs)))
      (if (stringp item)
          (hooks:run-hook (self-insert-hook (find-submode 'neomacs-mode))
                          marker item)
          (progn
            (setf (advance-p (selection-marker neomacs)) nil)
            (setf (pos (selection-marker neomacs)) (pos marker))
            (apply #'insert-nodes marker (mapcar #'clone-node item)))))))

(defun rotate-ring (ring)
  (with-slots (containers::buffer-start
               containers::buffer-end
               containers::total-size
               containers::contents)
      ring
    (decf containers::buffer-start)
    (decf containers::buffer-end)
    (let ((start (mod containers::buffer-start containers::total-size))
          (end (mod containers::buffer-end containers::total-size)))
      (setf (svref containers::contents start)
            (svref containers::contents end)
            (svref containers::contents end)
            0))))

(define-command paste-pop (&optional (neomacs (find-submode 'neomacs-mode)))
  (with-dom-update neomacs
    (rotate-ring (clipboard-ring *browser*))
    (let ((marker (focus neomacs))
          (item (containers:current-item (clipboard-ring *browser*))))
      (if (stringp item)
          (hooks:run-hook (self-insert-hook (find-submode 'neomacs-mode))
                          marker item)
          (progn
            (delete-nodes (selection-marker neomacs)
                          (pos-right (selection-marker neomacs)))
            (apply #'insert-nodes marker (mapcar #'clone-node item)))))))

(define-command forward-cut (&optional (pos (focus)))
  (iter (with end = (copy-pos pos))
    (setq end (npos-right end))
    (unless end
      (containers:insert-item (clipboard-ring *browser*)
                              (extract-nodes pos nil))
      (return))
    (when (new-line-node-p end)
      (containers:insert-item (clipboard-ring *browser*)
                              (extract-nodes pos end))
      (return))))
