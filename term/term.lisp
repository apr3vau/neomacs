(in-package #:3bst)

;; Patch 3bst to support scrollback

(defun tscrollup (orig n &key (term *term*))
  (let* ((bottom (bottom term)) (n (limit n 0 (1+ (- bottom orig))))
         (screen (screen term)))
    (neomacs/term::insert-scrollback (aref screen orig))
    (tclearregion 0 orig (1- (columns term)) (1- (+ orig n)) :term term)
    (tsetdirt (+ orig n) bottom :term term)
    (loop for i from orig to (- bottom n)
          do (rotatef (aref screen i)
                      (aref screen (+ i n))))))

(in-package #:neomacs/term)

(define-mode term-mode (read-only-mode doc-mode)
  ((for-term
    :initform (make-instance
               '3bst:term
               :rows 25
               :columns 80))
   (pid :initarg :pid)
   (pty :initarg :pty)
   (thread)
   (line-starts)
   (scrollback-lines :initform nil)))

(defmethod enable-aux ((mode-name (eql 'term-mode)))
  (let* ((buffer (current-buffer))
         (3bst:*term* (for-term buffer)))
    (3bst::tresize (3bst:columns 3bst:*term*) (3bst:rows 3bst:*term*))
    (3bst::treset)
    (setf (line-starts buffer)
          (let ((*inhibit-read-only* t))
            (iter (for i below (3bst:rows 3bst:*term*))
              (for node = (neomacs::make-new-line-node))
              (insert-nodes (end-pos (document-root buffer)) node)
              (collect node)))
          (thread buffer)
          (bt2:make-thread
           (lambda ()
             (let (*print-readably*)
               (handler-case
                   (iter (for c = (read-char-no-hang (pty buffer)
                                                     nil 'eof))
                     (until (eql c 'eof))
                     (with last-cursor)
                     (if c
                         (let ((3bst:*term* (for-term buffer))
                               (neomacs::*current-buffer* buffer))
                           (3bst:handle-input (string c)))
                         (progn
                           (when (typep buffer 'term-insert-mode)
                             (with-current-buffer buffer
                               (when (buffer-alive-p buffer)
                                 (cond ((find-if #'plusp
                                                 (3bst:dirty (for-term buffer)))
                                        (redisplay-term (for-term buffer) buffer)
                                        (redisplay-focus (for-term buffer) buffer)
                                        (setf last-cursor
                                              (3bst::copy-cursor
                                               (3bst::cursor 3bst:*term*))))
                                       ((not (equalp last-cursor
                                                     (3bst::cursor 3bst:*term*)))
                                        (redisplay-focus (for-term buffer) buffer)
                                        (setf last-cursor
                                              (3bst::copy-cursor
                                               (3bst::cursor 3bst:*term*))))))))
                           (sleep 0.02))))
                 (stream-error ()))
               (with-current-buffer buffer
                 (when (buffer-alive-p buffer)
                   (delete-buffer buffer)))))
           :name "Terminal listener"))))

(defmethod selectable-p-aux ((buffer term-mode) pos)
  (and (or (text-pos-p pos) (new-line-node-p pos))
       (call-next-method)))

(defmethod on-delete-buffer progn ((buffer term-mode))
  (sb-posix:close (pty buffer))
  (sb-posix:kill (pid buffer) sb-unix:sighup)
  (sb-posix:waitpid (pid buffer) 0))

(defvar +ansi-colors+
  '("ansi-black" "ansi-red" "ansi-green" "ansi-yellow"
    "ansi-blue" "ansi-magenta" "ansi-cyan" "ansi-white"
    "ansi-bright-black" "ansi-bright-red" "ansi-bright-green" "ansi-bright-yellow"
    "ansi-bright-blue" "ansi-bright-magenta" "ansi-bright-cyan" "ansi-bright-white"))

(defun apply-fg-color (node color)
  (labels ((c (r g b)
             (setf (attribute node "style")
                   (format nil "color:#~2,'0x~2,'0x~2,'0x;" r g b)))
           (c6 (x)
             (let ((b (mod x 6))
                   (g (mod (floor x 6) 6))
                   (r (mod (floor x 36) 6)))
               (c (* r 51) (* g 51) (* b 51))))
           (g (x)
             (c (* x 16) (* x 16) (* x 16))))
    (cond ((logbitp 24 color)
           (c (ldb (byte 8 16) color)
              (ldb (byte 8 8) color)
              (ldb (byte 8 0) color)))
          ((< color 16)
           (setf (attribute node "class") (nth color +ansi-colors+)))
          (t (let ((c (- color 16)))
               (if (< c 216)
                   (c6 c)
                   (g (- c 216))))))
    node))

(defun render-line (line)
  (let ((stream (make-string-output-stream))
        last-color)
    (flet ((emit ()
             (let ((output (get-output-stream-string stream)))
               (when (plusp (length output))
                 (list (apply-fg-color
                        (neomacs::make-element
                         "span" :children (list output))
                        last-color))))))
      (nconc
       (iter (for c in-vector line)
         (for color = (3bst:fg c))
         (unless (or (not last-color) (eql color last-color))
           (nconcing (emit)))
         (unless (eql (3bst:c c) #\Nul)
           (write-char (3bst:c c) stream))
         (setq last-color color))
       (emit)))))

(defun redisplay-term (term buffer)
  (let ((*inhibit-read-only* t))
    (iter (for line in (nreverse (scrollback-lines buffer)))
      (apply #'insert-nodes (car (line-starts buffer))
             (make-new-line-node) line))
    (setf (scrollback-lines buffer) nil)
    (iter (with dirty = (3bst:dirty term))
      (for row below (3bst:rows term))
      (for (beg end) on (line-starts buffer))
      (when (plusp (aref dirty row))
        (delete-nodes (pos-right beg) end)
        (apply #'insert-nodes
         (pos-right beg)
         (render-line (aref (3bst::screen term) row)))
        (setf (aref dirty row) 0)))))

(defun redisplay-focus (term buffer)
  (let* ((cursor (3bst::cursor term))
         (x (3bst::x cursor))
         (y (3bst::y cursor))
         (pos (pos-right (nth y (line-starts buffer)))))
    (iter (for i to x)
      (unless (eql (3bst:c (3bst:glyph-at (3bst::screen term) y i)) #\Nul)
        (setf pos (or (npos-next-until pos #'text-pos-p) pos))))
    (setf (pos (focus buffer)) pos)))

(defun insert-scrollback (line)
  (push (render-line line) (scrollback-lines neomacs::*current-buffer*)))

(cffi:defcfun ("run_shell" %run-shell) :void
  (rows :int) (cols :int) (program :string) (argv :pointer) (term-env :string)
  (pid :pointer) (fd :pointer))

(defun run-shell (rows cols cmd args term-env)
  (let* ((string-pointers (mapcar #'cffi:foreign-string-alloc args))
         (argv-pointer (cffi:foreign-alloc
                        :pointer :null-terminated-p t
                        :initial-contents string-pointers)))
    (unwind-protect
         (cffi:with-foreign-objects
             ((pid-pointer :int)
              (fd-pointer :int))
           (setf (cffi:mem-ref pid-pointer :int) 0
                 (cffi:mem-ref fd-pointer :int) 0)
           (%run-shell rows cols cmd argv-pointer term-env
                       pid-pointer fd-pointer)
           (values (cffi:mem-ref pid-pointer :int)
                   (cffi:mem-ref fd-pointer :int)))
      (mapc #'cffi:foreign-string-free string-pointers)
      (cffi:foreign-free argv-pointer))))

(define-mode term-insert-mode () ()
  (:lighter "Insert")
  (:toggler t)
  (:documentation "Forward most keys to terminal."))

(defvar *terminfo-installed-p* nil
  "Whether we know that st terminfo entry are already installed.")

(define-command term ()
  "Start terminal emulator."
  (unless *terminfo-installed-p*
    (handler-case
        (progn
          (uiop:run-program (list "infocmp" "st-256color")
                            :error-output t)
          (setq *terminfo-installed-p* t))
      (uiop:subprocess-error (c)
        (when (neomacs::read-yes-or-no
               (if (eql (uiop:subprocess-error-code c) 1)
                   "Terminfo for st seems not installed yet. Install now? "
                   (format nil "Probe terminfo entry failed (~a). Install terminfo for st now? "
                           (uiop:subprocess-error-code c))))
          (uiop:run-program
           (list "tic" "-sx"
                 (uiop:native-namestring
                  (neomacs::translate-relocated-source
                   #P"~/quicklisp/local-projects/neomacs/term/st.info"))
                 :output t :error-output t))))))
  (multiple-value-bind (pid fd)
      (run-shell 25 80 "/bin/bash" nil "st-256color")
    (switch-to-buffer
     (make-buffer
      "*term*" :mode '(term-insert-mode term-mode) :pid pid
      :pty (sb-sys:make-fd-stream fd :input t :output t
                                     :dual-channel-p t)))))

(defnclo term-send-seq-command (string) ()
  (term-send-seq string))

(define-keys term-mode
  "C-c C-k" 'term-insert-mode
  "C-c C-l" 'term-clear-scrollback)

(define-keys term-insert-mode
  'self-insert-command 'term-forward-key
  'backward-delete (make-term-send-seq-command "")
  'backward-delete-word (make-term-send-seq-command "")
  "enter" 'term-forward-key
  "tab" 'term-forward-key
  "escape" (make-term-send-seq-command "")
  "C-q" 'term-quote-send-key
  "C-c C-j" 'term-insert-mode)

(iter (for i from (char-code #\a) to (char-code #\z))
  (for char = (code-char i))
  (unless (member char '(#\x #\c #\q))
    (set-key (find-keymap 'term-insert-mode)
             (format nil "C-~a" char) 'term-forward-key)
    (set-key (find-keymap 'term-insert-mode)
             (format nil "M-~a" char) 'term-forward-key)))

(defun term-send-seq (string)
  (let* ((buffer (current-buffer))
         (3bst:*term* (for-term buffer))
         (3bst::*write-to-child-hook*
           (lambda (term string)
             (declare (ignore term))
             (write-string string (pty buffer))
             (finish-output (pty buffer)))))
    (3bst::tty-send string)))

(defun term-send-key (key)
  (let ((seq (key-sym key)))
    (when (equal seq "Space") (setf seq " "))
    (when (equal seq "Enter") (setf seq "
"))
    (when (equal seq "Tab") (setf seq "	"))
    (when (key-ctrl key)
      (setf seq (string (code-char (1+ (- (char-code (aref seq 0))
                                          (char-code #\a)))))))
    (when (key-meta key)
      (setf seq (str:concat "" seq)))
    (term-send-seq seq)))

(define-command term-clear-scrollback
  :mode term-mode ()
  "Delete scrollback content."
  (let ((*inhibit-read-only* t))
    (delete-nodes (pos-down (document-root (current-buffer)))
                  (car (line-starts (current-buffer))))))

(define-command term-forward-key
  :mode term-mode ()
  "Send this key to terminal."
  (term-send-key (car (last *this-command-keys*))))

(define-command term-quote-send-key
  :mode term-mode ()
  "Send the next key to terminal."
  (term-send-key (read-key "Send to terminal: ")))

(defstyle term '(:font-family "monospace"))

(defstyle ansi-black '(:color "#fff"))
(defstyle ansi-red '(:color "#c00"))
(defstyle ansi-green '(:color "#0c0"))
(defstyle ansi-yellow '(:color "#cc0"))
(defstyle ansi-blue '(:color "#00c"))
(defstyle ansi-magenta '(:color "#c0c"))
(defstyle ansi-cyan '(:color "#0cc"))
(defstyle ansi-white '(:color "#000"))
(defstyle ansi-bright-black '(:color "#ccc"))
(defstyle ansi-bright-red '(:color "#f00"))
(defstyle ansi-bright-green '(:color "#0f0"))
(defstyle ansi-bright-yellow '(:color "#ff0"))
(defstyle ansi-bright-blue '(:color "#00f"))
(defstyle ansi-bright-magenta '(:color "#f0f"))
(defstyle ansi-bright-cyan '(:color "#0ff"))
(defstyle ansi-bright-white '(:color "#777"))

(defsheet term-mode
    `(("body" :inherit term)
      ,@(iter (for color in +ansi-colors+)
         (collect `(,(str:concat "." color)
                    :inherit ,(find-symbol
                               (string-upcase color)
                               (find-package "NEOMACS/TERM")))))))
