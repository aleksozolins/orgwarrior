;;; orgwarrior.el --- Backend for the orgwarrior command line  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Aleks Ozolins
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/aleksozolins/orgwarrior

;; The Python side calls `orgwarrior-call' through `emacsclient --eval' with a
;; JSON request and prints the JSON reply.  Everything that needs org lives
;; here: building agenda views, task IDs, showing, acting on and adding
;; tasks.  Org does the real work; this file only drives it without ever
;; prompting, since a prompt would hang emacsclient.

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-agenda)
(require 'org-clock)
(require 'org-duration)
(require 'ox-html)

;; org-read-date-analyze reports a time of day through these; org makes them
;; special only inside org.el, so without this a `let' here would be lexical.
(defvar org-time-was-given)
(defvar org-end-time-was-given)
;; diary-lib's, which may not be loaded yet: the same.
(defvar calendar-debug-sexp)
;; org-habit's, read only once it's loaded (`featurep').
(defvar org-habit-preceding-days)
(defvar org-habit-following-days)
(declare-function org-archive--compute-location "org-archive" (location))

(defconst orgwarrior-agenda-buffer "*orgwarrior agenda*"
  "Buffer orgwarrior builds views in, so the user's *Org Agenda* is left alone.")

(defconst orgwarrior--min-id-length 2)

;; The element accessors Org 9.7 added, through org-element-property, which
;; Org 9.6 (Emacs 29's) has too.
(defun orgwarrior--el-begin (e) (org-element-property :begin e))
(defun orgwarrior--el-end (e) (org-element-property :end e))
(defun orgwarrior--el-contents-begin (e) (org-element-property :contents-begin e))
(defun orgwarrior--el-contents-end (e) (org-element-property :contents-end e))
(defun orgwarrior--el-parent (e) (org-element-property :parent e))
(defun orgwarrior--el-type-p (e types) (memq (org-element-type e) (ensure-list types)))

(defvar orgwarrior-gc-cons-threshold (* 64 1024 1024)
  "`gc-cons-threshold' while a request runs, if the user's is lower.
A view conses a lot, and with large agenda buffers live each collection
costs ~0.1 s: at Emacs's default 800 KB a large view spent most of its
time collecting.  Only bound for the request, so Emacs's own is kept.")


;;;; Entry point

(defun orgwarrior-call (request)
  "Handle REQUEST, a JSON string, and return the reply as a JSON string.
The reply is {\"ok\": RESULT} or {\"error\": MESSAGE}."
  (let ((dirty (orgwarrior--dirty-buffers)))
    (orgwarrior--json
     (condition-case err
         ;; A listed agenda file that doesn't exist is skipped, not asked about
         ;; ("Remove from list?" can't be answered here); --check names it.
         (let ((inhibit-interaction t)
               (org-agenda-skip-unavailable-files t)
               (inhibit-message t)
               (text-quoting-style 'straight)
               (gc-cons-threshold (max gc-cons-threshold orgwarrior-gc-cons-threshold)))
           (list :ok (orgwarrior--dispatch
                      (json-parse-string request :object-type 'alist
                                         :array-type 'list
                                         :null-object nil :false-object nil))))
       (inhibited-interaction
        (orgwarrior--undo-failed dirty)
        (list :error (format "Emacs tried to ask a question (%s), and orgwarrior can't answer one. Do the same thing in Emacs to see what it wants, or run orgwarrior --check"
                             (error-message-string err))))
       (error (orgwarrior--undo-failed dirty)
              (list :error (error-message-string err)))))))

(defun orgwarrior--dirty-buffers ()
  "The file buffers with unsaved changes: the user's own, never reverted."
  (seq-filter (lambda (b) (and (buffer-file-name b) (buffer-modified-p b))) (buffer-list)))

(defun orgwarrior--undo-failed (dirty)
  "After a request failed, the disk version of each file buffer it left
changed but unsaved, DIRTY (the user's own unsaved ones) left alone: a
save that failed (a write-protected file, a prompt) left the change in
memory, shown in views but never synced, and every later request
refused the file until someone reverted it in Emacs."
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (buffer-modified-p b) (not (memq b dirty)))
      (with-current-buffer b
        (ignore-errors (revert-buffer t t t))))))

(defvar orgwarrior--archives nil
  "Non-nil: this request's views, IDs and reports take in the archive files
too, as org's agenda does with `v A' (`org-agenda-archives-mode' t).")

(defun orgwarrior--check-encrypted ()
  "Refuse a request while an agenda file is encrypted and not open in
Emacs: opening it asks for the passphrase, which here is an error, or a
pinentry window waiting out the timeout.  Open, it's decrypted already."
  (let ((re (if (boundp 'epa-file-name-regexp) epa-file-name-regexp "\\.gpg\\'")))
    (dolist (f (orgwarrior--agenda-files))
      (when (and (string-match-p re f) (not (find-buffer-visiting f)))
        (user-error "%s is encrypted and not open in Emacs, and orgwarrior can't type its passphrase. Open it in Emacs once (it stays decrypted while Emacs runs), or take it out of org-agenda-files"
                    (abbreviate-file-name f))))))

(defun orgwarrior--setup (file heading)
  "What `orgwarrior --check' looks at: this Emacs, its init file, and the
org settings orgwarrior relies on, FILE and HEADING being [add]'s.  It
runs before the encrypted-file check: an unopened .gpg agenda file is one
of the things it reports."
  (let* ((setting org-agenda-files)
         ;; org-agenda-files keeps a listed file that doesn't exist; the agenda skips it.
         (files (seq-filter #'file-exists-p (ignore-errors (org-agenda-files t))))
         (re (if (boundp 'epa-file-name-regexp) epa-file-name-regexp "\\.gpg\\'"))
         (abbrev (lambda (f) (abbreviate-file-name (expand-file-name f)))))
    (list :emacs emacs-version
          :org (org-version)
          :daemon (if (daemonp) t :false)
          :socket (if (and (boundp 'server-socket-dir) server-socket-dir)
                      (abbreviate-file-name (expand-file-name server-name server-socket-dir))
                    :null)
          ;; Set to the name it tried (~/.emacs) even when there was no such file.
          :init (if (and user-init-file (file-exists-p user-init-file))
                    (abbreviate-file-name user-init-file) :null)
          :emacs_dir (abbreviate-file-name (expand-file-name user-emacs-directory))
          ;; An init file in ~/.config/emacs is ignored once ~/.emacs.d exists,
          ;; and a native-compiling Emacs makes it on its first start (eln-cache).
          :xdg_init (let ((f (expand-file-name "emacs/init.el" (or (getenv "XDG_CONFIG_HOME") "~/.config"))))
                      (if (file-exists-p f) (abbreviate-file-name f) :null))
          :agenda_setting (cond ((null setting) "unset") ((stringp setting) "file") (t "list"))
          ;; Entries of the list that don't exist: a typo'd path is silently skipped by org.
          :missing (vconcat (and (listp setting)
                                 (seq-remove #'file-exists-p
                                             (mapcar (lambda (f) (abbreviate-file-name (expand-file-name f org-directory)))
                                                     setting))))
          :files (vconcat (mapcar abbrev files))
          :read_only (vconcat (mapcar abbrev (seq-remove #'file-writable-p files)))
          :encrypted (vconcat (mapcar abbrev (seq-filter (lambda (f) (and (string-match-p re f)
                                                                         (not (find-buffer-visiting f))))
                                                        files)))
          :unsaved (vconcat (delq nil (mapcar (lambda (f) (let ((b (find-buffer-visiting f)))
                                                           (and b (buffer-modified-p b) (funcall abbrev f))))
                                              files)))
          :add (condition-case err
                   (list :file (abbreviate-file-name
                                (buffer-file-name (plist-get (orgwarrior--add-place file heading) :buffer))))
                 (error (list :error (error-message-string err))))
          :refile (if org-refile-targets t :false)
          ;; closed's reports read the CLOSED stamp, which org writes only with this.
          :log_done (if org-log-done t :false)
          :commands (vconcat (seq-filter #'stringp (mapcar #'car org-agenda-custom-commands))))))

(defun orgwarrior--dispatch (req)
  (let-alist req
    (let ((orgwarrior--archives .archive))
      (unless (equal .op "setup") (orgwarrior--check-encrypted))
      (pcase .op
        ("setup" (orgwarrior--setup .file .heading))
        ("view" (orgwarrior--view .kind .arg .width .prefix .grid .tags))
        ("show" (orgwarrior--show .id .html))
        ("act" (orgwarrior--act .ids .verb .args .note .new))
        ("add" (orgwarrior--add .text .file .heading .captured .fields .event .to .under))
        ("add-places" (orgwarrior--add-place-labels .file .heading))
        ("edit" (orgwarrior--edit .id))
        ("wants-note" (orgwarrior--wants-note .ids .verb))
        ("check" (orgwarrior--check .id .n .text))
        ("set-entry" (orgwarrior--set-entry .id .text .old))
        ("keywords" (orgwarrior--keywords .file))
        ("files" (vconcat (mapcar #'orgwarrior--file-key (orgwarrior--agenda-files))))
        ("tags" (orgwarrior--all-tags))
        ("calendar" (orgwarrior--calendar .days))
        ("entries" (orgwarrior--entries-with .property .value))
        ("refile-targets" (orgwarrior--refile-target-labels .ids))
        ("refile-places" (orgwarrior--refile-place-labels .ids))
        ("outline" (orgwarrior--outline .file))
        ("reorder" (orgwarrior--reorder .parent .file .ids))
        ("clock" (orgwarrior--clock-status))
        ("clock-in" (orgwarrior--clock-in .id .time))
        ("clock-out" (orgwarrior--clock-out .id .time))
        ("clock-cancel" (orgwarrior--clock-cancel .id))
        ("clocks" (orgwarrior--clocks .id))
        ("clock-edit" (orgwarrior--clock-edit .id .n .start .end .old .remove))
        ("clock-add" (orgwarrior--clock-add .id .start .end .duration))
        ("note-edit" (orgwarrior--note-edit .id .n .text .old .remove))
        ("props" (orgwarrior--props .id .name))
        ("report" (orgwarrior--report .words))
        ("edit-done" (orgwarrior--edit-done .buffer))
        (_ (error "Unknown op: %s" .op))))))

(defun orgwarrior--json (obj)
  "Serialize OBJ as JSON with non-ASCII escaped, so the reply survives
emacsclient's printing whatever the coding settings."
  (replace-regexp-in-string
   "[^[:ascii:]]"
   (lambda (c)
     (let ((cp (string-to-char c)))
       (if (< cp #x10000)
           (format "\\u%04x" cp)
         (let ((v (- cp #x10000)))
           (format "\\u%04x\\u%04x"
                   (+ #xd800 (ash v -10)) (+ #xdc00 (logand v #x3ff)))))))
   (decode-coding-string (json-serialize obj) 'utf-8)
   t t))


;;;; Files and buffers

(defun orgwarrior--file-buffer (file)
  "Return a buffer visiting FILE, reverted first if it changed on disk.
Syncthing rewrites org files behind Emacs's back; an unmodified buffer
that is out of date gets the disk version.  A modified one is left alone.
So does one whose read-only state no longer matches the file's: a chmod
leaves the time alone, and the buffer read only after the file was."
  (let ((buf (or (find-buffer-visiting file) (find-file-noselect file))))
    (with-current-buffer buf
      (unless (or (buffer-modified-p)
                  (and (verify-visited-file-modtime buf)
                       (eq buffer-read-only (not (file-writable-p buffer-file-name)))))
        (revert-buffer t t t)))
    buf))

(defun orgwarrior--agenda-files ()
  (seq-filter #'file-exists-p
              (if orgwarrior--archives
                  (let ((org-agenda-archives-mode t)) (org-agenda-files t 'ifmode))
                (org-agenda-files t))))

(defun orgwarrior--file-key (file)
  "FILE relative to `org-directory', or abbreviated if it's outside it.
Relative, so the same task has the same ID on every machine."
  (let ((file (file-truename file))
        (dir (file-name-as-directory (file-truename org-directory))))
    (if (string-prefix-p dir file)
        (file-relative-name file dir)
      (abbreviate-file-name file))))

(defun orgwarrior--buffer-file ()
  (or buffer-file-name (buffer-file-name (buffer-base-buffer))))

(defun orgwarrior--read-only-p (&optional buf)
  "Non-nil if BUF's (default the current buffer's) file isn't writable: a
copy of something else, such as a calendar a script exports to org, that
the next export would overwrite.  Shown everywhere, changed nowhere."
  (let ((file (buffer-file-name (orgwarrior--base-buffer buf))))
    (and file (not (file-writable-p file)))))

(defun orgwarrior--base-buffer (buf)
  (let ((buf (or buf (current-buffer)))) (or (buffer-base-buffer buf) buf)))

(defun orgwarrior--check-writable (buf)
  "Refuse a change to BUF before anything changes: its file read only
\(`orgwarrior--read-only-p'), or the user's unsaved changes in Emacs."
  (when (orgwarrior--read-only-p buf)
    (user-error "%s is read only, because its file isn't writable"
                (orgwarrior--file-key (buffer-file-name (orgwarrior--base-buffer buf)))))
  (when (buffer-modified-p buf)
    (user-error "%s has unsaved changes in Emacs. Save or revert it first"
                (buffer-name buf))))


;;;; IDs

(cl-defstruct (orgwarrior-entry (:constructor orgwarrior-entry-create))
  hash buffer pos)

(cl-defstruct (orgwarrior-index (:constructor orgwarrior-index-create))
  entries prefixes)

(defconst orgwarrior--cookie-re "\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\]"
  "A statistics cookie: [1/3] or [33%].")

(defun orgwarrior--title ()
  "Title of the heading at point: no keyword, priority, tags, comment
or statistics cookie, so changing any of those keeps the ID."
  (orgwarrior--title-of (org-get-heading t t t t)))

(defun orgwarrior--title-of (heading)
  "HEADING's title as `orgwarrior--title' gives it: cookies dropped."
  ;; Each replace only when there's something to replace: the index runs this
  ;; on every heading, and the copies were most of its time (in GC).
  (when (string-match-p orgwarrior--cookie-re heading)
    (setq heading (replace-regexp-in-string orgwarrior--cookie-re "" heading)))
  (when (string-match-p "\t\\|[ \t][ \t]" heading)
    (setq heading (replace-regexp-in-string "[ \t]+" " " heading)))
  (string-trim heading))

(defun orgwarrior--hash (key title &optional n)
  "The hash of the Nth heading titled TITLE in the file KEY: from the
second on, N joins what's hashed, so twins (an archive's are many) each
have an ID of their own and a title that's once in its file keeps its."
  (secure-hash 'sha1 (encode-coding-string
                      (concat key "\0" title (if (and n (> n 1)) (format "\0%d" n) ""))
                      'utf-8)))

(defun orgwarrior--hash-at-point ()
  "The hash of the heading at point, from its file's index: a twin's
depends on the headings before it."
  (or (gethash (save-excursion (ignore-errors (org-back-to-heading t) (point)))
               (orgwarrior-file-index-by-pos (orgwarrior--file-index)))
      (orgwarrior--hash (orgwarrior--file-key (orgwarrior--buffer-file)) (orgwarrior--title))))

;; Each agenda buffer's headings, hashed once and kept until its text (or what
;; its hashes are made of) changes: re-hashing every heading in every file on
;; every request was most of a request's time on a large setup.
(cl-defstruct (orgwarrior-file-index (:constructor orgwarrior-file-index-create))
  stamp entries by-pos counts)

(defvar orgwarrior--files (make-hash-table :test 'eq :weakness 'key)
  "Buffer → its `orgwarrior-file-index'.")

(defvar orgwarrior--last-index nil
  "(FILE-INDEXES . INDEX): the last index, reused while every file's is.")

;; Loaded again (a new engine): what the old one indexed, by its rules, goes.
(clrhash orgwarrior--files)
(setq orgwarrior--last-index nil)

(defun orgwarrior--index-stamp ()
  "What the current buffer's hashes depend on, cheap to compare: its text
(the tick counts text changes, not fontification), its file and
`org-directory' (the file key) and its keywords (stripped from titles)."
  (list (buffer-chars-modified-tick) (orgwarrior--buffer-file) org-directory org-todo-regexp))

(defun orgwarrior--cached-file ()
  "The current buffer's file index, if it's still current."
  (let ((file (gethash (current-buffer) orgwarrior--files)))
    (and file (equal (orgwarrior-file-index-stamp file) (orgwarrior--index-stamp)) file)))

(defun orgwarrior--file-index ()
  "The current buffer's headings, hashed: from the cache, else scanned."
  (or (orgwarrior--cached-file)
      (let ((key (orgwarrior--file-key (orgwarrior--buffer-file)))
            (by-pos (make-hash-table :test 'eql))
            (counts (make-hash-table :test 'equal))
            entries)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward org-outline-regexp-bol nil t)
           (let* ((title (orgwarrior--title))
                  (hash (orgwarrior--hash key title (puthash title (1+ (gethash title counts 0)) counts)))
                  (pos (line-beginning-position)))
             (puthash pos hash by-pos)
             (push (orgwarrior-entry-create :hash hash :buffer (current-buffer) :pos pos)
                   entries))))
        (puthash (current-buffer)
                 (orgwarrior-file-index-create :stamp (orgwarrior--index-stamp)
                                               :entries (nreverse entries) :by-pos by-pos
                                               :counts counts)
                 orgwarrior--files))))

(defun orgwarrior--index ()
  "Every heading in the agenda files, hashed."
  (let ((files (mapcar (lambda (file) (with-current-buffer (orgwarrior--file-buffer file)
                                        (orgwarrior--file-index)))
                       (orgwarrior--agenda-files))))
    (if (and orgwarrior--last-index
             (= (length files) (length (car orgwarrior--last-index)))
             (cl-every #'eq files (car orgwarrior--last-index)))
        (cdr orgwarrior--last-index)
      (let ((entries (apply #'append (mapcar #'orgwarrior-file-index-entries files))))
        (cdr (setq orgwarrior--last-index
                   (cons files (orgwarrior-index-create
                                :entries entries
                                :prefixes (orgwarrior--prefixes
                                           (mapcar #'orgwarrior-entry-hash entries))))))))))

(defun orgwarrior--common-prefix-length (a b)
  (let ((m (compare-strings a nil nil b nil nil)))
    (if (eq m t) (length a) (1- (abs m)))))

(defun orgwarrior--prefixes (hashes)
  "Map each of HASHES to its shortest unique prefix, at least 2 chars, and
not an ID still reserved for a task that's gone (`orgwarrior--reserved')."
  (let* ((sorted (vconcat (sort (delete-dups (copy-sequence hashes)) #'string<)))
         (n (length sorted))
         (current (make-hash-table :test 'equal))
         (table (make-hash-table :test 'equal)))
    (seq-doseq (h sorted) (puthash h t current))
    (dotimes (i n)
      (let ((h (aref sorted i))
            (len orgwarrior--min-id-length))
        (dolist (j (list (1- i) (1+ i)))
          (when (and (>= j 0) (< j n))
            (setq len (max len (1+ (orgwarrior--common-prefix-length h (aref sorted j)))))))
        (while (and (< len (length h)) (orgwarrior--reserved (substring h 0 len) current))
          (setq len (1+ len)))
        (puthash h (substring h 0 (min len (length h))) table)))
    table))

(defvar orgwarrior--given (make-hash-table :test #'equal)
  "Each ID given out: (HASH . TIME), the task it named and when it was last
shown.  An ID is a prefix, so once its task is renamed or gone, a new
task's hash can start with it.")

(defconst orgwarrior--reserve-seconds (* 24 3600)
  "How long an ID stays its task's after the task is renamed or gone.")

(defun orgwarrior--reserved (id current)
  "The hash ID was given out for, if that task isn't in CURRENT (a table of
the hashes there are) and it was shown within `orgwarrior--reserve-seconds':
an ID kept in a script or a conversation, never to name a new task."
  (when-let* ((given (gethash id orgwarrior--given)))
    (and (not (gethash (car given) current))
         (< (- (float-time) (cdr given)) orgwarrior--reserve-seconds)
         (car given))))

(defun orgwarrior--id (index hash)
  (let ((id (gethash hash (orgwarrior-index-prefixes index))))
    (when id (puthash id (cons hash (float-time)) orgwarrior--given))
    id))

(defmacro orgwarrior--at (entry &rest body)
  "Run BODY with point on ENTRY's heading."
  (declare (indent 1))
  `(with-current-buffer (orgwarrior-entry-buffer ,entry)
     (org-with-wide-buffer
      (goto-char (orgwarrior-entry-pos ,entry))
      ,@body)))

(defun orgwarrior--heading-line ()
  "The heading at point without stars, whitespace squeezed, its links as
org shows them."
  (let ((bol (line-beginning-position)) (eol (line-end-position)))
    (font-lock-ensure bol eol)
    (replace-regexp-in-string
     "[ \t]+" " "
     (replace-regexp-in-string
      "\\`\\*+ +" ""
      (substring-no-properties (orgwarrior--shown (buffer-substring bol eol)))))))

(defun orgwarrior--shown (string)
  "STRING (fontified) less what org hides of its links, the brackets and
target: the text as Emacs shows it, properties kept.  Only links: other
invisible text, like a folded subtree, is still part of the text."
  (let ((pos 0) (len (length string)) parts)
    (while (< pos len)
      (let ((next (next-single-property-change pos 'invisible string len)))
        (unless (eq (get-text-property pos 'invisible string) 'org-link)
          (push (substring string pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun orgwarrior--describe (index entry)
  (orgwarrior--at entry
    (format "  %s  %s:%d  %s"
            (orgwarrior--id index (orgwarrior-entry-hash entry))
            (orgwarrior--file-key (orgwarrior--buffer-file))
            (line-number-at-pos)
            (orgwarrior--heading-line))))

(defun orgwarrior--resolve (index id)
  "The single entry whose hash starts with ID, or a `user-error'."
  (let* ((id (downcase id))
         (matches (seq-filter (lambda (e) (string-prefix-p id (orgwarrior-entry-hash e)))
                              (orgwarrior-index-entries index)))
         (describe (lambda (es) (mapconcat (lambda (e) (orgwarrior--describe index e)) es "\n"))))
    (cond
     ((< (length id) orgwarrior--min-id-length)
      (user-error "%s is too short for an ID. IDs are at least %d characters" id orgwarrior--min-id-length))
     ((null matches) (user-error "No task %s" id))
     ((cdr matches) (user-error "ID %s is ambiguous:\n%s" id (funcall describe matches)))
     ;; A task gone since kept it: the new one starting with it is given a longer ID.
     ((orgwarrior--reserved id (orgwarrior-index-prefixes index))
      (user-error "%s was the ID of a task that has since been renamed or removed. The one starting with it now is:\n%s"
                  id (funcall describe matches)))
     (t (car matches)))))

(defun orgwarrior--resolve-anywhere (id)
  "(INDEX . ENTRY) for ID: in the agenda files, else in their archives.
Only to show it: actions resolve in the agenda files alone, so an
archived task is never changed by an ID that once named a live one."
  (let ((index (orgwarrior--index)))
    (condition-case err
        (cons index (orgwarrior--resolve index id))
      (user-error
       (if (or orgwarrior--archives
               (not (string-prefix-p "No task" (error-message-string err))))
           (signal (car err) (cdr err))
         (let* ((orgwarrior--archives t)
                (index (orgwarrior--index)))
           (cons index (orgwarrior--resolve index id))))))))


;;;; Dates

(defconst orgwarrior--date-aliases
  '(("today" . ".") ("tomorrow" . "+1d") ("tom" . "+1d") ("yesterday" . "-1d"))
  "Words org's date reader doesn't know.")

(defconst orgwarrior--time-re
  (concat "\\`[0-9]\\{1,2\\}\\(?::[0-9]\\{2\\}\\)?\\(?:[ap]m\\)?"
          "\\(?:-[0-9]\\{1,2\\}\\(?::[0-9]\\{2\\}\\)?\\(?:[ap]m\\)?\\|\\+[0-9.:]+h?\\)?\\'")
  "A time of day or a range: 14:00, 2pm, 14:00-15:30, 2pm+1h, 9:00+0:15.")

(defun orgwarrior--date-alone-p (word sentinel)
  "Non-nil if org reads WORD on its own: a date (SENTINEL's day if not)
or a time."
  (let (org-time-was-given org-end-time-was-given)  ; leaves the caller's alone
    (or (assoc (downcase word) orgwarrior--date-aliases)
        (string-match-p orgwarrior--time-re word)
        (/= (time-to-days (org-encode-time (org-read-date-analyze word sentinel (decode-time sentinel))))
            (time-to-days sentinel)))))

(defun orgwarrior--parse-date (string)
  "Parse STRING with org's date reader.
Return (INPUT TIME WITH-TIME END): the string to hand org, the encoded
time, whether a time of day was given, and the end time of a range
(\"15:30\" from \"fri 14:00-15:30\" or \"fri 14:00+1:30\") or nil.
Return nil if STRING isn't a date; `org-read-date' would quietly read
it as today, and skips words it doesn't know (\"call 3 people\" is the
3rd), so every word has to be a date or time on its own, or the date's
weekday name (org writes them in the locale's language)."
  (let* ((input (string-trim string))
         (input (or (cdr (assoc (downcase input) orgwarrior--date-aliases)) input))
         ;; Inside 1970-2037: org clamps dates outside it.
         (sentinel (encode-time (list 0 0 0 1 1 2000 nil -1 nil)))
         (org-time-was-given nil)
         (org-end-time-was-given nil))
    (unless (or (string-empty-p input)
                (= (time-to-days (org-encode-time
                                  (org-read-date-analyze input sentinel (decode-time sentinel))))
                   (time-to-days sentinel)))
      (setq org-time-was-given nil org-end-time-was-given nil)
      (when-let* ((time (org-encode-time
                         (org-read-date-analyze input (current-time) (decode-time))))
                  ((cl-every (lambda (word)
                               (or (orgwarrior--date-alone-p word sentinel)
                                   (string= (downcase word) (downcase (format-time-string "%a" time)))))
                             (split-string input))))
        (list input time (and org-time-was-given t)
              (and org-time-was-given org-end-time-was-given
                   (string-match "\\`\\([0-9]+\\):\\([0-9]+\\)" org-end-time-was-given)
                   (format "%02d:%02d" (string-to-number (match-string 1 org-end-time-was-given))
                           (string-to-number (match-string 2 org-end-time-was-given)))))))))

(defun orgwarrior--read-date (string)
  (or (orgwarrior--parse-date string) (user-error "Can't read %s as a date. Try fri, +2d, 2026-10-15 or fri 14:00" string)))

(defconst orgwarrior--repeater-re
  "\\`\\(?:\\.\\+\\|\\+\\+\\|\\+\\)[0-9]+[hdwmy]\\(?:/[0-9]+[hdwmy]\\)?\\'"
  "A repeater: +1w, .+2d, ++1m, or a habit's .+2d/4d.")

(defconst orgwarrior--warning-re "\\`--?[0-9]+[hdwmy]\\'"
  "A deadline warning or scheduled delay: -3d.")

(defun orgwarrior--read-timestamp (string)
  "Parse STRING: a date `orgwarrior--parse-date' reads, then optionally a
repeater and a warning period (\"fri 14:00-15:30 .+1w -2d\").  Return
\(DATE . COOKIES), DATE as `orgwarrior--parse-date' gives it, COOKIES a
list of strings.  Only after a date is +1w a repeater: alone it's a
date, a week from today."
  (let ((words (split-string string)) repeater warning)
    (while (and (cdr words)
                (let ((last (car (last words))))
                  (cond ((and (not repeater) (string-match-p orgwarrior--repeater-re last))
                         (setq repeater last))
                        ((and (not warning) (string-match-p orgwarrior--warning-re last))
                         (setq warning last)))))
      (setq words (butlast words)))
    (cons (orgwarrior--read-date (string-join words " "))
          (delq nil (list repeater warning)))))

(defun orgwarrior--stamp (date &optional cookies)
  "The active timestamp for DATE (from `orgwarrior--parse-date') and COOKIES."
  (let ((fmt (org-time-stamp-format (nth 2 date))))
    (format-time-string (concat (substring fmt 0 -1)
                                (when (nth 3 date) (concat "-" (nth 3 date)))
                                (mapconcat (lambda (c) (concat " " c)) cookies "")
                                (substring fmt -1))
                        (nth 1 date))))

(defun orgwarrior--timestamp-input (string)
  "What to hand `org-schedule' or `org-deadline' for STRING, and whether
it's exact: (INPUT . EXACT).  A whole <...> timestamp is taken as
written, its repeater or the lack of one included: EXACT is the
timestamp, to put back after org, which keeps the old repeater when the
new date has none.  Plain words follow org's rule: with a repeater or
warning they become a whole timestamp, the only form org takes them in;
else STRING goes as is, so org reads it as in Emacs (++2d is from the
date already there)."
  (let ((string (string-trim string)))
    (if (string-match "\\`<\\(.*\\)>\\'" string)
        (pcase-let* ((`(,date . ,cookies) (orgwarrior--read-timestamp (match-string 1 string)))
                     (stamp (orgwarrior--stamp date cookies)))
          (cons stamp stamp))
      (pcase-let ((`(,date . ,cookies) (orgwarrior--read-timestamp string)))
        (list (if cookies (orgwarrior--stamp date cookies) (car date)))))))

(defun orgwarrior--goto-when ()
  "Go to where the entry at point's event date goes: the first line after
its planning line, drawers and blank lines."
  (org-back-to-heading t)
  (let ((heading-end (line-end-position)))
    (org-end-of-meta-data t)
    ;; Org 9.6 stops before the blank lines.
    (skip-chars-forward " \t\n")
    (beginning-of-line)
    ;; A heading on the file's last line, no newline after it.
    (when (< (point) heading-end) (goto-char heading-end))))

(defun orgwarrior--when-line ()
  "The date of the entry at point as an event has it: (BEG END STAMP) of
the line right after its planning line and drawers, when that line holds
only a plain active timestamp (or a range), END past its newline.  Where
add event writes it; a timestamp further down is the text's, else nil."
  (save-excursion
    (orgwarrior--goto-when)
    (when (and (not (org-at-heading-p))
               (looking-at (concat "[ \t]*\\(" org-tsr-regexp "\\)[ \t]*$")))
      (list (point) (min (point-max) (1+ (line-end-position))) (match-string-no-properties 1)))))

(defun orgwarrior--when-action (string)
  "The function setting the entry at point's event date (`orgwarrior--when-line')
to STRING, a date with optional cookies or a whole <...> timestamp, as
sched takes them; added after the planning line and drawers if it has
none.  Plain words keep the repeater already there, as sched does."
  (let* ((string (string-trim string))
         (exact (string-match "\\`<\\(.*\\)>\\'" string))
         (parsed (orgwarrior--read-timestamp (if exact (match-string 1 string) string))))
    (lambda ()
      (let* ((old (orgwarrior--when-line))
             (cookies (or (cdr parsed)
                          (and (not exact) old
                               (string-match "<[^>]* \\([.+]?\\+[0-9]+[hdwmy]\\(?:/[0-9]+[hdwmy]\\)?\\)[ >]"
                                             (nth 2 old))
                               (list (match-string 1 (nth 2 old))))))
             (stamp (orgwarrior--stamp (car parsed) cookies)))
        (save-excursion
          (if old
              (delete-region (goto-char (nth 0 old)) (nth 1 old))
            (orgwarrior--goto-when)
            ;; No text: above the blank lines before the next heading.
            (when (org-at-heading-p)
              (skip-chars-backward " \t\n")
              (forward-line 1)))
          (if (bolp) (insert stamp "\n") (insert "\n" stamp)))))))


;;;; Views

(defun orgwarrior--view (kind arg width prefix grid tags)
  "Build the agenda view KIND (with ARG) and return its lines with IDs.
PREFIX, if non-nil, replaces `org-agenda-prefix-format' for this view;
GRID non-nil keeps org's time grid.  TAGS \"inline\" puts tags right
after the title, else they're right-aligned to WIDTH.  Kind closed (ARG
a span, as `orgwarrior--span' reads it) always takes in the archives:
what was done is mostly archived."
  (let* ((orgwarrior--archives (or orgwarrior--archives (equal kind "closed")))
         (index (orgwarrior--index)))
    (save-window-excursion
      (let ((org-agenda-buffer-name orgwarrior-agenda-buffer)
            (org-agenda-sticky nil)
            (org-agenda-window-setup 'current-window)
            (org-agenda-tags-column (cond ((equal tags "inline") 0)
                                          (width (- width))
                                          (t org-agenda-tags-column)))
            (org-agenda-prefix-format (or prefix org-agenda-prefix-format))
            (org-agenda-use-time-grid grid)
            ;; `org-agenda-mode' sets the mode from the start-with, globally:
            ;; bound, so it can't outlast this view.  Org 9.7's: void in 9.6.
            (org-agenda-start-with-archives-mode
             (if orgwarrior--archives t (bound-and-true-p org-agenda-start-with-archives-mode)))
            (org-agenda-archives-mode (and orgwarrior--archives t)))
        (when-let* ((old (get-buffer orgwarrior-agenda-buffer)))
          (kill-buffer old))
        ;; A habit's consistency graph goes past the end of the line instead of
        ;; over the heading at its column; `orgwarrior--habit-graph' takes it
        ;; off.  Only if org-habit is loaded: binding its variable before it
        ;; loads would leave it void.
        (cl-progv (and (featurep 'org-habit) '(org-habit-graph-column)) '(1000)
          (pcase kind
            ("today" (org-agenda-list nil nil 1))
            ("week" (org-agenda-list nil (and arg (time-to-days (nth 1 (orgwarrior--read-date arg)))) 7))
            ("all" (org-todo-list))
            ("closed" (orgwarrior--closed-view arg))
            ("words"
             (pcase (orgwarrior--state-query arg)
               (`(,states . nil) (org-todo-list states))
               (`(,states . ,match) (org-tags-view nil (concat match "/" states)))
               (_ (if-let* ((date (orgwarrior--parse-date arg)))
                      (org-agenda-list nil (time-to-days (nth 1 date)) 1)
                    (org-search-view nil arg)))))
            ("search"
             (when (string-blank-p arg) (user-error "A search needs some words to search for"))
             (org-search-view nil arg))
            ("tags" (org-tags-view nil arg))
            ("custom"
             (unless (assoc arg org-agenda-custom-commands)
               (user-error "There's no agenda command %S in org-agenda-custom-commands" arg))
             (org-agenda nil arg))
            (_ (error "Unknown view kind: %s" kind))))
        (let ((buf (or (get-buffer orgwarrior-agenda-buffer) (current-buffer))))
          (prog1 (orgwarrior--agenda-lines index buf)
            (kill-buffer buf)))))))

(defun orgwarrior--closed-view (words)
  "What was closed in the span WORDS (default today): org's agenda in log
mode showing only log items (C-u C-u l), the closed ones, empty days left out."
  (pcase-let* ((`(,start ,end) (orgwarrior--span words))
               (day (time-to-days start)))
    (let ((org-agenda-start-with-log-mode 'only)
          (org-agenda-log-mode-items '(closed))
          (org-agenda-show-all-dates nil)
          (org-agenda-include-diary nil))
      (org-agenda-list nil day (- (time-to-days end) day)))))

(defun orgwarrior--state-query (arg)
  "For ARG \"wait next +@phone\": (\"WAIT|NEXT\" . \"+@phone\").
Nil unless ARG starts with TODO keywords (any case) and whatever follows
is a tag match."
  (let ((words (split-string arg))
        (keywords (orgwarrior--all-keywords))
        states)
    (while (and words (assoc-string (car words) keywords t))
      (push (assoc-string (pop words) keywords t) states))
    (when (and states (or (null words) (memq (aref (car words) 0) '(?+ ?-))))
      (cons (string-join (nreverse states) "|")
            (and words (string-join words " "))))))

(defun orgwarrior--agenda-lines (index buf)
  (with-current-buffer buf
    (let (lines)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((bol (line-beginning-position))
               (eol (line-end-position))
               (marker (orgwarrior--line-marker bol eol)))
          (unless (orgwarrior--hint-line-p bol eol)
            (push (append (let* ((line (orgwarrior--shown (buffer-substring bol eol)))
                                 (graph (orgwarrior--habit-graph line)))
                            (when graph
                              (setq line (string-trim-right (substring line 0 (- (length line) (length graph))))))
                            (append
                             (list :text (substring-no-properties line)
                                   :id (or (and marker (orgwarrior--marker-id index marker)) :null)
                                   :spans (orgwarrior--line-spans line))
                             (when graph (list :habit (orgwarrior--habit graph)))
                             (when (and marker (orgwarrior--read-only-p (marker-buffer marker)))
                               (list :read_only t))
                             (when (orgwarrior--all-day-p bol) (list :all_day t))))
                          (when-let* (((get-text-property bol 'org-date-line))
                                      (day (get-text-property bol 'day)))
                            (pcase-let ((`(,m ,d ,y) (calendar-gregorian-from-absolute day)))
                              (list :date (format "%04d-%02d-%02d" y m d)))))
                  lines)))
        (forward-line 1))
      (vconcat (nreverse lines)))))

(defun orgwarrior--all-day-p (pos)
  "Whether the agenda line at POS is an event on a day without a time: a
plain timestamp, a diary sexp or a day of a range, with no keyword."
  (and (member (get-text-property pos 'type) '("timestamp" "sexp" "block"))
       (not (get-text-property pos 'time-of-day))
       (not (get-text-property pos 'todo-state))))

(defun orgwarrior--habit-graph (line)
  "The consistency graph org-habit put at the end of LINE, or nil."
  (when (featurep 'org-habit)
    (let ((n (+ 1 org-habit-preceding-days org-habit-following-days)))
      (and (> (length line) n)
           (string-prefix-p "habit-" (or (orgwarrior--face-role
                                          (get-text-property (- (length line) n) 'face line))
                                         ""))
           (substring line (- (length line) n))))))

(defun orgwarrior--rgb (color)
  "COLOR (#rrggbb, #rgb or a name) as #rrggbb, or nil.  Not `color-values':
it answers for the selected frame, and a daemon that never had a graphical
frame has only a colorless one, which rounds every color to a few."
  (when-let* ((values (or (color-values-from-color-spec color)
                          (tty-color-standard-values (downcase color)))))
    (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (/ v 257)) values))))

(defun orgwarrior--habit (graph)
  "GRAPH as a line of its own, (:text :spans :colors): a day per character,
`*' done, `!' today, its role the day's state, and :colors each role's
background as the Emacs theme sets it (#rrggbb)."
  (let ((spans (orgwarrior--line-spans graph))
        colors)
    (seq-doseq (span spans)
      (let ((role (aref span 2)))
        (when-let* (((not (plist-member colors (intern (concat ":" role)))))
                    (color (face-background (get-text-property (aref span 0) 'face graph) nil t))
                    (rgb (orgwarrior--rgb color)))
          (setq colors (plist-put colors (intern (concat ":" role)) rgb)))))
    (list :text (substring-no-properties graph) :spans spans
          :colors (or colors (make-hash-table)))))

(defun orgwarrior--hint-line-p (bol eol)
  "Non-nil for org's \"Press `N r' to search again\" lines, which are
about keys in the agenda buffer and mean nothing to orgwarrior."
  (save-excursion
    (goto-char bol)
    (skip-chars-forward " \t" eol)
    (and (< (point) eol)
         (let ((face (get-text-property (point) 'face)))
           (memq 'org-agenda-structure-secondary (ensure-list face))))))

(defun orgwarrior--line-marker (bol eol)
  "The heading marker org put somewhere on the agenda line BOL..EOL.
Only `org-hd-marker': lines with just `org-marker' (diary sexps and
the like) aren't headings orgwarrior can act on."
  (let ((pos bol) marker)
    (while (and (< pos eol) (not marker))
      (setq marker (get-text-property pos 'org-hd-marker)
            pos (next-single-property-change pos 'org-hd-marker nil eol)))
    marker))

(defun orgwarrior--marker-id (index marker)
  (when (buffer-live-p (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (unless (org-before-first-heading-p)
         (org-back-to-heading t)
         (orgwarrior--id index (orgwarrior--hash-at-point)))))))


(defconst orgwarrior--face-roles
  `((org-agenda-structure . "header")
    (org-agenda-structure-filter . "header")
    (org-agenda-date-today . "today")
    (org-agenda-date-weekend-today . "today")
    (org-agenda-date . "date")
    (org-agenda-date-weekend . "date")
    (org-time-grid . "grid")
    (org-agenda-current-time . "now")
    (org-scheduled-previously . "overdue")
    (org-imminent-deadline . "deadline")
    (org-warning . "deadline")
    (org-upcoming-deadline . "upcoming")
    (org-agenda-done . "done-item")
    (org-priority . "priority")
    (org-tag . "tag")
    ;; In a task's own text (show):
    (org-special-keyword . "label")
    (org-drawer . "drawer")
    (org-date . "timestamp")
    (org-link . "link")
    (org-checkbox . "checkbox")
    ;; A habit's days (`orgwarrior--habit'):
    ,@(mapcan (lambda (state)
                (list (cons (intern (format "org-habit-%s-face" state)) (concat "habit-" state))
                      (cons (intern (format "org-habit-%s-future-face" state))
                            (format "habit-%s-future" state))))
              '("clear" "ready" "alert" "overdue"))
    ,@(mapcar (lambda (n) (cons (intern (format "org-level-%d" n)) "heading"))
              (number-sequence 1 8))
    ,@(mapcar (lambda (n) (cons (intern (format "outline-%d" n)) "heading"))
              (number-sequence 1 8)))
  "Org faces orgwarrior colors, by the role name the CLI's color config uses.
Faces inheriting from one of these get its role.")

(defun orgwarrior--face-role (face)
  "The role of FACE (a face, a list of faces, or an anonymous face), or nil.
In a list the first face with a role wins, as it does for display."
  (cond
   ((keywordp face) nil)
   ((keywordp (car-safe face)) (orgwarrior--face-role (plist-get face :inherit)))
   ((symbolp face)
    (or (cdr (assq face orgwarrior--face-roles))
        (and (facep face)
             (let ((parent (face-attribute face :inherit nil nil)))
               (unless (eq parent 'unspecified) (orgwarrior--face-role parent))))))
   ((consp face)
    (seq-some #'orgwarrior--face-role face))))

(defun orgwarrior--line-spans (line &optional keyword)
  "The colorable parts of LINE (from `orgwarrior--shown'), as [START END
ROLE KEYWORD] vectors.  The TODO keyword (KEYWORD, else the
agenda's `todo-state') gets role \"todo\" or \"done\" plus the keyword
itself, whatever face org gave it.  On agenda lines the time of day and
org's \"Scheduled:\"-style label come last, so they win."
  (let ((keyword (or keyword
                     (when-let* ((s (get-text-property 0 'todo-state line)))
                       (substring-no-properties s))))
        ;; An agenda buffer's own keyword lists are empty.
        (all (if (derived-mode-p 'org-agenda-mode)
                 org-todo-keywords-for-agenda
               org-todo-keywords-1))
        (done (if (derived-mode-p 'org-agenda-mode)
                  org-done-keywords-for-agenda
                org-done-keywords))
        (pos 0)
        (len (length line))
        spans)
    (while (< pos len)
      (let* ((next (min (next-single-property-change pos 'face line len)
                        (next-single-property-change pos 'font-lock-face line len)))
             (face (or (get-text-property pos 'face line) (get-text-property pos 'font-lock-face line)))
             (run (substring-no-properties line pos next))
             ;; org-search-view leaves out `todo-state': then the first face
             ;; run that is a keyword is the keyword.
             (kw-p (and face (if keyword
                                 (equal run keyword)
                               (and (member run all) (setq keyword run)))))
             (role (if kw-p
                       (if (member keyword done) "done" "todo")
                     (orgwarrior--face-role face))))
        (when role
          (push (vector pos next role (if kw-p keyword :null)) spans))
        (setq pos next)))
    (dolist (part '((time . "time") (extra . "extra")))
      (when-let* ((value (orgwarrior--line-prop line (car part)))
                  (value (string-trim value "[ \t]+" "[. \t]+"))
                  ((not (string-empty-p value)))
                  (i (string-search value line)))
        (push (vector i (+ i (length value)) (cdr part) :null) spans)))
    (vconcat (nreverse spans))))

(defun orgwarrior--line-prop (line prop)
  "The first non-nil value of text property PROP in LINE."
  (when-let* ((pos (text-property-not-all 0 (length line) prop nil line)))
    (get-text-property pos prop line)))

(defun orgwarrior--line-links (line)
  "The links in LINE (from `orgwarrior--shown') as (:start :end :url),
what each covers of LINE, as org's fontification marked them."
  (let ((pos 0) (len (length line)) links)
    (while (< pos len)
      (let ((next (next-single-property-change pos 'htmlize-link line len)))
        (when-let* ((url (plist-get (get-text-property pos 'htmlize-link line) :uri)))
          (push (list :start pos :end next :url url) links))
        (setq pos next)))
    (vconcat (nreverse links))))

(defun orgwarrior--keyword-props ()
  "The TODO keyword of the heading at point, for the CLI to color."
  (let ((kw (org-get-todo-state)))
    (list :keyword (or kw :null)
          :done (if (member kw org-done-keywords) t :false))))

(defun orgwarrior--result (id &rest extra)
  "The heading at point as an action's result: ID, its line as shown,
EXTRA (more of the plist), its keyword."
  (append (list :id id :heading (orgwarrior--heading-line)) extra (orgwarrior--keyword-props)))

(defun orgwarrior--inherited-tags ()
  "The tags of the heading at point from the file's #+filetags and its parents."
  (vconcat (seq-remove (lambda (tag) (member tag (org-get-tags nil t))) (org-get-tags))))

(defun orgwarrior--entries (index ids)
  "The entries IDS name, each once, or a `user-error' for the first that
doesn't resolve: all of them before anything changes.  Copies: the
actions move their positions onto markers, and the index's are cached."
  (delete-dups (mapcar (lambda (id) (copy-orgwarrior-entry (orgwarrior--resolve index id))) ids)))

(defun orgwarrior--save (buffers)
  "Save those of BUFFERS that changed."
  (dolist (buf buffers)
    (with-current-buffer buf
      (when (buffer-modified-p) (save-buffer)))))


;;;; Show

(defun orgwarrior--show (id &optional html)
  "`orgwarrior ID''s content; HTML non-nil adds :html, its text as org
exports it (`orgwarrior--html')."
  (pcase-let ((`(,index . ,entry) (orgwarrior--resolve-anywhere id)))
    (orgwarrior--at entry
      (pcase-let ((`(,body-start . ,body-end) (orgwarrior--entry-region))
                  (event-date (orgwarrior--when-line)))
        (append
         (list :id (orgwarrior--id index (orgwarrior-entry-hash entry))
              :file (orgwarrior--file-key (orgwarrior--buffer-file))
              ;; Its file isn't writable: every change is refused.
              :read_only (if (orgwarrior--read-only-p) t :false)
              ;; As the agenda labels it: the file's name, #+category:, a CATEGORY property.
              :category (or (org-get-category) :null)
              :path (vconcat (org-get-outline-path))
              :parents (orgwarrior--parents index)
              ;; The siblings around it, for a front end's Move buttons to name.
              :prev (or (save-excursion (and (org-get-previous-sibling) (orgwarrior--title))) :null)
              :next (or (save-excursion (and (org-get-next-sibling) (orgwarrior--title))) :null)
              :heading (buffer-substring-no-properties (point) (line-end-position))
              :title (orgwarrior--title)
              :tags (vconcat (org-get-tags nil t))
              :inherited (orgwarrior--inherited-tags)
              :scheduled (or (org-entry-get nil "SCHEDULED") :null)
              :deadline (or (org-entry-get nil "DEADLINE") :null)
              :closed (or (org-entry-get nil "CLOSED") :null)
              ;; An event's date, and its line in :lines, for a front end
              ;; to show as a field, not text.
              :when (or (nth 2 event-date) :null)
              :when_line (if event-date (- (line-number-at-pos (car event-date)) (line-number-at-pos)) :null)
              :body (string-trim-right (buffer-substring-no-properties body-start body-end))
              :lines (orgwarrior--fontified-lines (point) body-end (org-get-todo-state))
              :links (orgwarrior--links (point) body-end)
              :checkboxes (orgwarrior--checkboxes (point) body-end)
              :notes (orgwarrior--notes body-start body-end)
              ;; Every log item, notes or not, to show and edit apart from
              ;; the drawer; and the drawers that then needn't show.
              :history (orgwarrior--history body-start body-end)
              :log_drawers (orgwarrior--log-drawers body-start body-end)
              ;; Its own properties, as its drawer lists them; Effort apart
              ;; too, with its minutes, for estimate against clocked.
              :properties (orgwarrior--properties)
              :effort (or (org-entry-get nil org-effort-property) :null)
              :effort_minutes (orgwarrior--effort-minutes)
              :priority (orgwarrior--priority-at-point)
              ;; Who added it, when someone else did (orgwarrior-web's add tokens).
              :from (or (org-entry-get nil "FROM") :null)
              ;; The file's, for a front end's state buttons: #+TODO is per file.
              :keywords (vconcat org-todo-keywords-1)
              :keyword_keys (orgwarrior--keyword-keys)
              :done_keywords (vconcat org-done-keywords)
              :children (orgwarrior--children index)
              ;; Its own clocks, newest first, as `orgwarrior--clocks' numbers them.
              :clocks (plist-get (orgwarrior--clocks-here index) :clocks))
         (and html (list :html (orgwarrior--html body-start body-end event-date)))
         (orgwarrior--keyword-props))))))

(defun orgwarrior--html (start end &optional event-date)
  "The entry's text from START to END as org exports it to HTML, body
only: what a front end shows read (bold, lists, tables, links, source
blocks), so nothing drifts from org's own reading of it.  Drawers, the
planning line and EVENT-DATE's line (`orgwarrior--when-line') left out (a front
end shows those its own way).  Source
blocks colored by face name (`org-keyword', `org-string'...), not the
daemon's colors, for the front end's theme.  Babel off: exporting never
runs a block."
  (let* ((start (save-excursion (goto-char start)
                                ;; Exported alone, with no heading above it, a planning
                                ;; line would read as a paragraph: it's left out here.
                                (when (looking-at-p org-planning-line-re) (forward-line 1))
                                (point)))
         (text (if event-date
                   (concat (buffer-substring-no-properties start (nth 0 event-date))
                           (buffer-substring-no-properties (nth 1 event-date) end))
                 (buffer-substring-no-properties start end)))
         (org-export-use-babel nil)
         (org-html-htmlize-output-type 'css)
         (org-html-htmlize-font-prefix "org-"))
    (if (not (org-string-nw-p text)) ""
      (org-export-string-as text 'html t
                            '(:with-drawers nil :with-planning nil :with-properties nil
                              :with-toc nil :section-numbers nil :with-clocks nil)))))

(defun orgwarrior--priority-at-point ()
  "The heading's own priority cookie as a string, or :null.  Not
`org-entry-get''s PRIORITY, which gives the default when there's none."
  (save-excursion
    (org-back-to-heading t)
    (if (looking-at org-priority-regexp) (match-string-no-properties 2) :null)))

(defun orgwarrior--log-item-re (template)
  "A regexp for a log item's first line as org writes it from TEMPLATE
(an `org-log-note-headings' value): group 1 its indentation, 8 the time
stamp, 9 the new state, 10 the old one.  Spaces stretch: `%-12s' pads."
  (concat "\\([ \t]*\\)- +"
          (replace-regexp-in-string
           "%-?[0-9]*\\([tTdDsSuU]\\)"
           (lambda (m)
             (pcase (aref m (1- (length m)))
               ((or ?t ?T ?d ?D) "\\(?8:[[<][^]>\n]*[]>]\\)")
               (?s "\\(?:\"\\(?9:[^\"\n]*\\)\"\\)?")
               (?S "\\(?:\"\\(?10:[^\"\n]*\\)\"\\)?")
               (_ ".*?")))
           (replace-regexp-in-string " +" " +" (regexp-quote template) t t)
           t t)
          "\\(?: +\\\\\\\\\\)?[ \t]*$"))

(defun orgwarrior--log-items (start end)
  "The log items between START and END, newest first, whichever way
`org-log-states-order-reversed' writes them: plists (:beg :end :time
:state :from :kind :heading :text), BEG to END the item, its text lines
included; HEADING its first line without the dash and the note's `\\'.
Matched by `org-log-note-headings', so a changed template still reads."
  (let ((res (delq nil (mapcar (lambda (h) (when (org-string-nw-p (cdr h))
                                             (cons (car h) (orgwarrior--log-item-re (cdr h)))))
                               org-log-note-headings)))
        items)
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^[ \t]*- " end t)
        (goto-char (line-beginning-position))
        (let* ((beg (point))
               (first (buffer-substring-no-properties beg (line-end-position)))
               (found (seq-some (lambda (r)
                                  (when (looking-at (cdr r))
                                    (list (car r) (match-string-no-properties 8) (match-string-no-properties 9)
                                          (length (match-string 1)) (match-string-no-properties 10))))
                                res))
               lines stop)
          (forward-line 1)
          (setq stop (point))
          (when found
            ;; The text: what follows, indented under the item, blank lines included.
            (while (and (< (point) end)
                        (looking-at "\\([ \t]*\\)\\(.*\\)$")
                        (not (string-prefix-p ":END:" (match-string 2)))
                        (or (string-empty-p (match-string 2))
                            (> (length (match-string 1)) (nth 3 found))))
              (push (match-string-no-properties 0) lines)
              (forward-line 1)
              (when (org-string-nw-p (car lines)) (setq stop (point))))  ; a blank after is no part of it
            (push (list :beg beg :end stop :time (or (nth 1 found) :null) :state (or (nth 2 found) :null)
                        :from (or (nth 4 found) :null) :kind (symbol-name (car found))
                        :heading (string-trim (replace-regexp-in-string
                                               "\\`[ \t]*- +\\|[ \t]*\\\\\\\\[ \t]*\\'" "" first))
                        :text (orgwarrior--dedent (nreverse lines)))
                  items)))))
    (sort (nreverse items)
          (lambda (a b)
            (let ((ta (plist-get a :time)) (tb (plist-get b :time)))
              (and (stringp ta) (stringp tb)
                   (time-less-p (org-time-string-to-time tb) (org-time-string-to-time ta))))))))

(defun orgwarrior--notes (start end)
  "The log items between START and END that carry text, newest first:
plists (:time :state :kind :text).  A state change or reschedule logged
without a note is no note."
  (vconcat (mapcar (lambda (i) (list :time (plist-get i :time) :state (plist-get i :state)
                                     :kind (plist-get i :kind) :text (plist-get i :text)))
                   (seq-filter (lambda (i) (org-string-nw-p (plist-get i :text)))
                               (orgwarrior--log-items start end)))))

(defun orgwarrior--history (start end)
  "Every log item between START and END, newest first, numbered as
`orgwarrior--note-edit' takes them: plists (:n :time :state :from :kind
:heading :text :raw), RAW the item as written, to guard an edit."
  (let ((n 0))
    (vconcat (mapcar (lambda (i)
                       (list :n (cl-incf n) :time (plist-get i :time) :state (plist-get i :state)
                             :from (plist-get i :from) :kind (plist-get i :kind)
                             :heading (plist-get i :heading) :text (plist-get i :text)
                             :raw (string-trim (buffer-substring-no-properties
                                                (plist-get i :beg) (plist-get i :end)))))
                     (orgwarrior--log-items start end)))))

(defun orgwarrior--log-drawer-names ()
  "The drawers the entry at point logs and clocks into, as org decides
\(`org-log-into-drawer', `org-clock-into-drawer', their properties)."
  (delete-dups (delq nil (list (org-log-into-drawer)
                               (let ((d (org-clock-into-drawer)))
                                 (cond ((stringp d) d)
                                       ((integerp d) (or (org-log-into-drawer) "LOGBOOK"))))))))

(defun orgwarrior--log-drawers (start end)
  "Of the entry's log and clock drawers between START and END, those
holding nothing but log items and CLOCK lines: a front end showing those
on their own can leave the drawer out."
  (let* ((items (orgwarrior--log-items start end))
         (clock-re (orgwarrior--clock-line-re))
         (case-fold-search t)
         found)
    (save-excursion
      (dolist (name (orgwarrior--log-drawer-names))
        (goto-char start)
        (when (re-search-forward (format "^[ \t]*:%s:[ \t]*$" (regexp-quote name)) end t)
          (forward-line 1)
          (let ((all t))
            (while (and all (< (point) end) (not (looking-at "^[ \t]*:END:[ \t]*$")))
              (let ((pos (point)))
                (if-let* ((item (seq-find (lambda (i) (and (<= (plist-get i :beg) pos) (< pos (plist-get i :end))))
                                          items)))
                    (goto-char (plist-get item :end))
                  (unless (or (looking-at "^[ \t]*$") (looking-at clock-re)) (setq all nil))
                  (forward-line 1))))
            (when all (push name found))))))
    (vconcat (nreverse found))))

(defun orgwarrior--drop-empty-log-drawers ()
  "Remove the entry at point's log and clock drawers once they're empty."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (case-fold-search t))
      (dolist (name (orgwarrior--log-drawer-names))
        (save-excursion
          (when (re-search-forward (format "^[ \t]*:%s:[ \t]*$" (regexp-quote name)) end t)
            (org-remove-empty-drawer-at (point))))))))

(defun orgwarrior--note-edit (id n text old remove)
  "Change log item N of ID's task (as `orgwarrior--history' numbers them):
its text to TEXT (none: just its first line; a note needs some), or
REMOVE it.  OLD, the item as shown (its :raw), must still match.  Its
first line stays as org wrote it.  The task's history after."
  (let* ((index (orgwarrior--index))
         (entry (orgwarrior--resolve index id)))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      (pcase-let* ((`(,start . ,end) (orgwarrior--entry-region))
                   (items (orgwarrior--log-items start end))
                   (item (or (and (integerp n) (> n 0) (nth (1- n) items))
                             (user-error "There's no history entry %s on it. It has %d" n (length items))))
                   (beg (plist-get item :beg))
                   (stop (plist-get item :end))
                   (text (string-trim (or text ""))))
        (when (and old (not (equal old (string-trim (buffer-substring-no-properties beg stop)))))
          (user-error "That note changed since it was shown. Show the task again"))
        (cond
         (remove
          (delete-region beg stop)
          (orgwarrior--drop-empty-log-drawers))
         ((and (string-empty-p text) (equal (plist-get item :kind) "note"))
          (user-error "A note needs some text. To get rid of it, delete it instead"))
         (t
          (goto-char beg)
          (let ((ind (progn (looking-at "[ \t]*") (match-string 0)))
                (first (replace-regexp-in-string "[ \t]*\\\\\\\\[ \t]*\\'" ""
                                                 (buffer-substring-no-properties beg (line-end-position)))))
            (delete-region beg stop)
            (insert first (if (string-empty-p text) "" " \\\\") "\n")
            (unless (string-empty-p text)
              (dolist (line (split-string text "\n"))
                (insert (if (org-string-nw-p line) (concat ind "  " line) "") "\n"))))))
        (save-buffer)
        (goto-char (orgwarrior-entry-pos entry))
        (pcase-let ((`(,start . ,end) (orgwarrior--entry-region)))
          (orgwarrior--history start end))))))

(defun orgwarrior--dedent (lines)
  "LINES joined, without their common indentation or blank lines around."
  (let ((ind (apply #'min (or (mapcar (lambda (l) (- (length l) (length (string-trim-left l))))
                                      (seq-filter #'org-string-nw-p lines))
                              '(0)))))
    (string-trim (mapconcat (lambda (l) (if (org-string-nw-p l) (substring l ind) "")) lines "\n")
                 "\n+" "\n+")))

(defun orgwarrior--priorities ()
  "The priorities org allows, highest first, as strings: letters, or
numbers when `org-priority-highest' is one."
  (mapcar (lambda (p) (if (orgwarrior--numeric-priorities-p) (number-to-string p) (char-to-string p)))
          (number-sequence org-priority-highest org-priority-lowest)))

(defun orgwarrior--numeric-priorities-p ()
  (< org-priority-highest 65))

(defun orgwarrior--entry-region ()
  "(START . END) of the text below the heading at point, up to the next
heading (a child's too): show's :body, what `orgwarrior--set-entry' replaces."
  (let ((end (save-excursion (outline-next-heading) (point))))
    (cons (min end (1+ (line-end-position))) end)))

(defun orgwarrior--set-entry (id text old)
  "Replace task ID's text below its heading, children left alone, with
TEXT as `orgwarrior--entry-text' lays it out.  OLD is that text as `show'
gave it (:body) and must still match: an entry changed underneath
\(Syncthing) is refused, not overwritten.  Headings in TEXT become its
children, after the ones it has (`orgwarrior--add-outline')."
  (let* ((index (orgwarrior--index))
         (entry (orgwarrior--resolve index id)))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      (pcase-let* ((`(,body . ,outline) (orgwarrior--split-outline text))
                   (new (orgwarrior--entry-text body))
                   (`(,start . ,end) (orgwarrior--entry-region))
                   (added 0))
        (unless (equal (string-trim-right (buffer-substring-no-properties start end)) old)
          (user-error "The task's text changed since it was shown. Reload it and try again"))
        (save-excursion
          ;; Up to the end of its last non-blank line: the blank lines before
          ;; the next heading stay.
          (goto-char end)
          (skip-chars-backward " \t\n" start)
          (delete-region start (if (= (point) start) start (min end (1+ (line-end-position)))))
          (goto-char start)
          (when new (insert (if (bolp) "" "\n") new "\n")))
        ;; Then the outline at the subtree's end as it now is.
        (when outline
          (save-excursion
            (let ((level (org-get-valid-level (org-current-level) 1)))
              (org-end-of-subtree t t)
              (setq added (orgwarrior--add-outline outline level)))))
        ;; The heading's [1/3], as C-c # counts it: its checkboxes, else its
        ;; children (`org-update-checkbox-count' alone zeroed a parent's).
        (org-update-statistics-cookies nil)
        (save-buffer)
        (append (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash entry)))
                (list :new_children added))))))

(defconst orgwarrior--heading-line-re "\\`\\*+\\(?:[ \t]\\|\\'\\)"
  "A line org reads as a heading.")

(defun orgwarrior--split-outline (text)
  "TEXT, an entry's text as a front end sends it, split where its first
heading starts: (BODY . OUTLINE), OUTLINE nil without one.  A heading
line inside a #+begin_/#+end_ block is the block's, escaped with a comma
as org escapes it (`org-escape-code-in-string'), not a heading."
  (let ((block nil) (lines nil) (split nil))
    (dolist (line (split-string (string-replace "\r" "" (or text "")) "\n"))
      (cond
       ((string-match-p "\\`[ \t]*#\\+end_" line) (setq block nil))
       ((string-match-p "\\`[ \t]*#\\+begin_" line) (setq block t))
       ((and block (string-match-p orgwarrior--heading-line-re line))
        (setq line (concat "," line)))
       ((and (not split) (string-match-p orgwarrior--heading-line-re line))
        (setq split (length lines))))
      (push line lines))
    (setq lines (nreverse lines))
    (if (not split)
        (cons (string-join lines "\n") nil)
      (cons (string-join (seq-take lines split) "\n")
            (string-join (seq-drop lines split) "\n")))))

(defun orgwarrior--add-outline (outline level)
  "Insert OUTLINE (headings and their text, levels as typed) at point, the
end of a subtree, its shallowest headings at LEVEL and the rest as deep
below them as typed.  The headings' count."
  (let* ((lines (split-string (string-trim-right outline) "\n"))
         (heads (seq-filter (lambda (l) (string-match-p orgwarrior--heading-line-re l)) lines))
         (shallowest (apply #'min (mapcar (lambda (l) (string-match "[^*]" (concat l " "))) heads))))
    (dolist (h heads)
      (unless (string-match-p "\\`\\*+[ \t]+[^ \t]" h)
        (user-error "A heading needs a title: %s" h)))
    (orgwarrior--insert-entry
     (mapconcat (lambda (l)
                  (if (string-match "\\`\\(\\*+\\)\\(?:[ \t]\\|\\'\\)" l)
                      (concat (make-string (+ level (- (length (match-string 1 l)) shallowest)) ?*)
                              (substring l (match-end 1)))
                    l))
                lines "\n"))
    (length heads)))

(defun orgwarrior--entry-text (text)
  "TEXT, an entry's text below its heading as a front end sends it, laid
out to save: the planning line and drawers, one blank line, then the rest,
blank lines around it dropped.  Nil if empty.  A line org would read as
a heading is refused: it would cut the entry short."
  (let* ((text (string-trim (string-replace "\r" "" (or text ""))
                            "\\(?:[ \t]*\n\\)+" "[ \t\n]+"))
         (lines (unless (string-empty-p text) (split-string text "\n")))
         meta)
    (when-let* ((line (seq-find (lambda (l) (string-match-p orgwarrior--heading-line-re l)) lines)))
      (user-error "A line can't start with \"*\", because org would make it a heading: %s" line))
    (when (and lines (string-match-p org-planning-line-re (car lines)))
      (push (pop lines) meta))
    (while-let ((lines)
                ((string-match-p org-drawer-regexp (car lines)))
                ((not (string-match-p org-property-end-re (car lines))))
                (n (cl-position-if (lambda (l) (string-match-p org-property-end-re l)) lines)))
      (dotimes (_ (1+ n)) (push (pop lines) meta)))
    (while (and lines (string-blank-p (car lines)))
      (pop lines))
    (when (or meta lines)
      (string-join (append (nreverse meta) (and meta lines '("")) lines) "\n"))))

(defun orgwarrior--links (start end)
  "The links in START..END, heading included, as org's parser finds them:
[[url][text]], bare URLs, <angle> ones.  Each is (:type :url :text),
:text the description or null."
  (save-restriction
    (narrow-to-region start end)
    (vconcat
     (org-element-map (org-element-parse-buffer) 'link
       (lambda (link)
         (list :type (org-element-property :type link)
               :url (org-element-property :raw-link link)
               :text (if (orgwarrior--el-contents-begin link)
                         (buffer-substring-no-properties (orgwarrior--el-contents-begin link)
                                                         (orgwarrior--el-contents-end link))
                       :null)))))))

(defun orgwarrior--checkbox-items (start end)
  "The list items with a checkbox in START..END, as org's parser finds
them, in order: what `orgwarrior--check' counts."
  (save-restriction
    (narrow-to-region start end)
    (org-element-map (org-element-parse-buffer) 'item
      (lambda (item) (and (org-element-property :checkbox item) item)))))

(defun orgwarrior--checkboxes (start end)
  "The checkboxes in START..END as (:line :text :state): :line indexes
the entry's :lines (0 is the heading), :state is on, off or trans
\(some sub-items done), :text the item's first line."
  (vconcat
   (mapcar (lambda (item)
             (save-excursion
               (goto-char (orgwarrior--el-begin item))
               (list :line (- (line-number-at-pos) (line-number-at-pos start))
                     :state (symbol-name (org-element-property :checkbox item))
                     :text (orgwarrior--checkbox-text item))))
           (orgwarrior--checkbox-items start end))))

(defun orgwarrior--check (id n text)
  "Toggle checkbox N (from 1, as `show' lists them) of task ID, as C-c
C-c does: cookies and a parent's [-] follow.  Only for a front end that
shows the box in place, so TEXT, the item's text it showed, must still
match: a list changed underneath (Syncthing) is refused, not guessed at.
On the command line, `edit' gives the context a list of boxes lacks."
  (let* ((index (orgwarrior--index))
         (entry (orgwarrior--resolve index id)))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      (let* ((items (orgwarrior--checkbox-items (point) (save-excursion (outline-next-heading) (point))))
             (item (and (integerp n) (<= 1 n (length items)) (nth (1- n) items))))
        (unless (and item (equal text (orgwarrior--checkbox-text item)))
          (user-error "The checkboxes changed since they were shown. Reload and try again"))
        (save-excursion
          (goto-char (orgwarrior--el-begin item))
          (org-toggle-checkbox))
        (save-buffer)
        (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash entry)))))))

(defun orgwarrior--checkbox-text (item)
  (save-excursion
    (goto-char (orgwarrior--el-begin item))
    (string-trim (buffer-substring-no-properties
                  (if (re-search-forward "\\[[ X-]\\][ \t]*" (line-end-position) t)
                      (point)
                    (line-beginning-position))
                  (line-end-position)))))

(defun orgwarrior--fontified-lines (start end keyword)
  "Lines START..END (trailing blank ones dropped) as Emacs shows them,
with org's colors as spans and the links each line shows; KEYWORD is the
TODO keyword on the first line."
  (font-lock-ensure start end)
  (save-excursion
    (goto-char end)
    (skip-chars-backward " \t\n" start)
    (let ((end (point)) lines)
      (goto-char start)
      (while (and (<= (point) end) (not (eobp)))
        (let ((line (orgwarrior--shown (buffer-substring (point) (min end (line-end-position))))))
          (push (list :text (substring-no-properties line)
                      :spans (orgwarrior--line-spans line (and (null lines) keyword))
                      :links (orgwarrior--line-links line))
                lines))
        (forward-line 1))
      (vconcat (nreverse lines)))))

(defun orgwarrior--parents (index)
  "The headings above the one at point, outermost first, for a front end
to open: (:id :title), :id null where none resolves."
  (save-excursion
    (let (parents)
      (while (org-up-heading-safe)
        (push (list :id (or (orgwarrior--id index (orgwarrior--hash-at-point)) :null)
                    :title (orgwarrior--title))
              parents))
      (vconcat parents))))

(defun orgwarrior--children (index)
  "The direct child headings of the heading at point, for a front end to
list and open: see `orgwarrior--siblings'."
  (save-excursion
    (if (org-goto-first-child) (orgwarrior--siblings index) [])))

(defun orgwarrior--siblings (index &optional deep)
  "The heading at point and its siblings after it: (:id :heading :text
:tags :keyword :done, and :child_count, its own children's count, unless
DEEP).  :heading is the whole line as
`orgwarrior--heading-line' gives it; :text is the heading without
keyword and tags (priority and cookies kept).  DEEP: each with its own
:children, the same way, all the way down (a front end's foldable tree)."
  (save-excursion
    (let (children)
      (cl-loop
       do (let ((heading (orgwarrior--heading-line)))  ; fontifies the line for :text
            (push (append (list :id (or (orgwarrior--id index (orgwarrior--hash-at-point)) :null)
                                :heading heading
                                :text (orgwarrior--shown (org-get-heading t t nil nil))
                                :tags (vconcat (org-get-tags nil t)))
                          (when (orgwarrior--read-only-p) (list :read_only t))
                          (orgwarrior--keyword-props)
                          (if deep
                              (list :children (save-excursion
                                                (if (org-goto-first-child) (orgwarrior--siblings index t) [])))
                            ;; How many of its own: a front end says there's more below.
                            (list :child_count (save-excursion
                                                 (if (not (org-goto-first-child)) 0
                                                   (cl-loop count t while (org-get-next-sibling)))))))
                  children))
       while (org-get-next-sibling))
      (vconcat (nreverse children)))))

(defun orgwarrior--agenda-file (key)
  "The agenda file whose `orgwarrior--file-key' is KEY (\"projects.org\"),
else the one file named KEY in a folder (gtd/todo.org for todo.org: a
setup kept in a folder of `org-directory')."
  (let ((files (orgwarrior--agenda-files)))
    (or (seq-find (lambda (f) (equal (orgwarrior--file-key f) key)) files)
        (let ((named (and (not (string-search "/" key))
                          (seq-filter (lambda (f) (equal (file-name-nondirectory f) key)) files))))
          (cond ((and named (null (cdr named))) (car named))
                (named (user-error "%s matches several agenda files: %s" key
                                   (mapconcat #'orgwarrior--file-key named ", ")))))
        (user-error "There's no agenda file %s" key))))

(defun orgwarrior--top-level ()
  "Move to the file's first top-level heading; nil if it has none."
  (goto-char (point-min))
  (and (re-search-forward org-outline-regexp-bol nil t)
       (progn (beginning-of-line)
              (while (org-up-heading-safe))
              t)))

(defun orgwarrior--outline (file)
  "FILE's (a file key) top-level headings, in file order, as
`orgwarrior--siblings' gives them, each with its :children all the way
down: a front end's page for the file, a tree to fold."
  (let ((index (orgwarrior--index)))
    (with-current-buffer (orgwarrior--file-buffer (setq file (orgwarrior--agenda-file file)))
      (org-with-wide-buffer
       (list :file (orgwarrior--file-key file)
             :children (if (orgwarrior--top-level) (orgwarrior--siblings index t) []))))))

(defun orgwarrior--reorder (parent file ids)
  "Put the children of PARENT (a task ID), or FILE's top-level headings
\(a file key), in the order IDS gives.  IDS must be those children, every
one: anything else means they changed underneath, and nothing moves.
Each child moves with its subtree; the blank lines between them stay as
they were."
  (let* ((index (orgwarrior--index))
         (parent (and parent (orgwarrior--resolve index parent)))
         (buf (if parent (orgwarrior-entry-buffer parent)
                (orgwarrior--file-buffer (orgwarrior--agenda-file (or file (user-error "reorder needs a parent heading or a file"))))))
         (wanted (mapcar (lambda (id) (orgwarrior-entry-hash (orgwarrior--resolve index id))) ids)))
    (orgwarrior--check-writable buf)
    (with-current-buffer buf
      (org-with-wide-buffer
       (if parent (goto-char (orgwarrior-entry-pos parent)))
       (unless (if parent (org-goto-first-child) (orgwarrior--top-level))
         (user-error "There's nothing to reorder"))
       (let (starts hashes end)
         (cl-loop do (push (point) starts) (push (orgwarrior--hash-at-point) hashes)
                  while (org-get-next-sibling))
         (setq starts (nreverse starts) hashes (nreverse hashes))
         (unless (and (equal (sort (copy-sequence hashes) #'string<) (sort (copy-sequence wanted) #'string<))
                      (= (length (delete-dups (copy-sequence hashes))) (length hashes)))
           (user-error "The headings changed since they were shown; reload and try again"))
         (goto-char (car (last starts)))
         (org-end-of-subtree t t)
         (setq end (point))
         (let* ((bounds (cl-mapcar #'cons starts (append (cdr starts) (list end))))
                (pieces (mapcar (lambda (b) (buffer-substring-no-properties (car b) (cdr b))) bounds))
                (trimmed (mapcar (lambda (p) (string-trim-right p "[ \t\n]+")) pieces))
                ;; What follows each piece's text: kept in place, not moved with it.
                (gaps (cl-mapcar (lambda (p tr) (substring p (length tr))) pieces trimmed))
                (by-hash (cl-mapcar #'cons hashes trimmed))
                (text (apply #'concat (cl-mapcar (lambda (h gap) (concat (cdr (assoc h by-hash)) gap))
                                                 wanted gaps))))
           (unless (equal text (buffer-substring-no-properties (car starts) end))
             (goto-char (car starts))
             (delete-region (car starts) end)
             (insert text)
             (save-buffer))))))
    (if parent (orgwarrior--at parent (orgwarrior--children (orgwarrior--index)))
      (plist-get (orgwarrior--outline file) :children))))


;;;; Calendar

(defun orgwarrior--calendar (days)
  "Every entry in the agenda files with a date, as data for a calendar:
its scheduled date, deadline, active timestamps (title and body) and
diary sexps, the sexps evaluated for each of the next DAYS days, as
the agenda would.  Commented and archived trees are left out, as the
agenda leaves them out."
  (let ((index (orgwarrior--index))
        (calendar-debug-sexp t)
        entries)
    (dolist (entry (orgwarrior-index-entries index))
      (orgwarrior--at entry
        (unless (or (org-in-commented-heading-p) (org-in-archived-heading-p))
          (when-let* ((stamps (orgwarrior--entry-stamps (or days 365))))
            (font-lock-ensure (point) (line-end-position))
            (push (append
                   (list :id (orgwarrior-entry-hash entry)
                         ;; Less its timestamps, as the agenda shows it.
                         :title (string-trim
                                 (replace-regexp-in-string
                                  "[ \t]+" " "
                                  (replace-regexp-in-string
                                   org-tsr-regexp-both ""
                                   (substring-no-properties
                                    (orgwarrior--shown (org-get-heading t t t t))))))
                         :tags (vconcat (org-get-tags nil t))
                         :inherited (orgwarrior--inherited-tags)
                         :category (or (org-get-category) :null)
                         :habit (if (and (fboundp 'org-is-habit-p) (org-is-habit-p)) t :false)
                         ;; A copy of another calendar, likely: a feed may leave it out.
                         :read_only (if (orgwarrior--read-only-p) t :false)
                         :stamps (vconcat stamps))
                   (orgwarrior--keyword-props))
                  entries)))))
    (vconcat (nreverse entries))))

(defun orgwarrior--entries-with (property value)
  "The entries whose own PROPERTY is VALUE (any value, if VALUE is nil), as
data: for a front end showing someone what they added (orgwarrior-web's
add tokens, :FROM:).  ID, the property's value, title as Emacs shows it,
keyword, done, the planning dates, the first plain timestamp (an
event's), CLOSED and CAPTURED.  Commented and archived trees are left
out, as the agenda leaves them out."
  (let ((index (orgwarrior--index))
        (any (memq value '(nil :null)))
        entries)
    (dolist (entry (orgwarrior-index-entries index))
      (orgwarrior--at entry
        (when-let* ((own (org-entry-get nil property))
                    ((if any (not (string-empty-p own)) (equal own value)))
                    ((not (or (org-in-commented-heading-p) (org-in-archived-heading-p)))))
          (font-lock-ensure (point) (line-end-position))
          (push (append
                 (list :id (orgwarrior--id index (orgwarrior-entry-hash entry))
                       :value own
                       :title (string-trim (substring-no-properties
                                            (orgwarrior--shown (org-get-heading t t t t))))
                       :scheduled (or (org-entry-get nil "SCHEDULED") :null)
                       :deadline (or (org-entry-get nil "DEADLINE") :null)
                       :timestamp (or (org-entry-get nil "TIMESTAMP") :null)
                       :closed (or (org-entry-get nil "CLOSED") :null)
                       :captured (or (org-entry-get nil "CAPTURED") :null))
                 (orgwarrior--keyword-props))
                entries))))
    (vconcat (nreverse entries))))

(defun orgwarrior--entry-stamps (days)
  "The dates of the entry at point, up to its first child (see
`orgwarrior--calendar')."
  (let* ((headline (org-element-at-point))
         (end (save-excursion (outline-next-heading) (point)))
         stamps)
    (dolist (kind '(:scheduled :deadline))
      (when-let* ((ts (org-element-property kind headline)))
        (push (orgwarrior--stamp-data ts (substring (symbol-name kind) 1) days) stamps)))
    (save-excursion
      (while (re-search-forward "<[0-9]\\|<%%(\\|^&?%%(" end t)
        (let ((ctx (save-excursion (goto-char (match-beginning 0)) (org-element-context))))
          (pcase (org-element-type ctx)
            ('timestamp
             (when (and (memq (org-element-property :type ctx) '(active active-range diary))
                        (not (orgwarrior--el-type-p (orgwarrior--el-parent ctx) 'planning)))
               (push (orgwarrior--stamp-data ctx "timestamp" days) stamps)
               (goto-char (max (point) (orgwarrior--el-end ctx)))))
            ('diary-sexp
             ;; "%%(diary-anniversary 10 20 1980) Robin is %d": the text after
             ;; the sexp is the entry it formats, as in the agenda.
             (let* ((value (string-trim-left (org-element-property :value ctx) "&?%%"))
                    (sexp-end (cdr (read-from-string value)))
                    (text (string-trim (substring value sexp-end))))
               (push (list :kind "sexp" :sexp (substring value 0 sexp-end)
                           :dates (orgwarrior--sexp-dates (substring value 0 sexp-end) text days))
                     stamps)
               (goto-char (max (point) (orgwarrior--el-end ctx)))))))))
    (seq-remove (lambda (s) (equal (plist-get s :dates) [])) (nreverse stamps))))

(defun orgwarrior--stamp-data (ts kind days)
  "Timestamp TS (an org-element) as data: dates and times as written,
repeater and warning as org parsed them.  A diary-sexp timestamp is
evaluated for each of the next DAYS days instead."
  (if (eq (org-element-property :type ts) 'diary)
      (let ((raw (org-element-property :raw-value ts)))
        (string-match "<%%\\((.*)\\)>" raw)
        (list :kind kind :sexp (match-string 1 raw)
              :dates (orgwarrior--sexp-dates (match-string 1 raw) "" days)))
    (let ((date (lambda (y m d) (format "%04d-%02d-%02d" y m d)))
          (time (lambda (h m) (if h (format "%02d:%02d" h m) :null)))
          (get (lambda (p) (org-element-property p ts))))
      (list :kind kind
            :start (funcall date (funcall get :year-start) (funcall get :month-start)
                            (funcall get :day-start))
            :start_time (funcall time (funcall get :hour-start) (funcall get :minute-start))
            :end (funcall date (funcall get :year-end) (funcall get :month-end)
                          (funcall get :day-end))
            :end_time (funcall time (funcall get :hour-end) (funcall get :minute-end))
            :repeat (if-let* ((type (funcall get :repeater-type))
                              ((> (or (funcall get :repeater-value) 0) 0)))
                        (list :type (pcase type ('cumulate "+") ('catch-up "++") ('restart ".+"))
                              :value (funcall get :repeater-value)
                              :unit (substring (symbol-name (funcall get :repeater-unit)) 0 1))
                      :null)
            :warning (if-let* ((value (funcall get :warning-value)))
                         (list :value value
                               :unit (substring (symbol-name (funcall get :warning-unit)) 0 1))
                       :null)))))

(defun orgwarrior--sexp-dates (sexp entry days)
  "The days from today through DAYS ahead on which SEXP (a string, as
in `%%(SEXP)') holds, as [{:date :text}], text being what it returned
(a birthday's \"Robin is 40\"), links as org shows them, or null.
`calendar-debug-sexp' is bound by the caller: org would otherwise beep
and sleep 2 s per day on a broken sexp; here it stops at the first error."
  (let ((today (org-today)) dates)
    (condition-case nil
        (dotimes (i days)
          (let* ((day (calendar-gregorian-from-absolute (+ today i)))
                 (result (org-diary-sexp-entry sexp entry day)))
            (dolist (text (if (listp result) result (list result)))
              (push (list :date (pcase-let ((`(,m ,d ,y) day)) (format "%04d-%02d-%02d" y m d))
                          :text (if (and (stringp text) (not (string-blank-p text)))
                                    (string-trim (org-link-display-format text))
                                  :null))
                    dates))))
      (error nil))
    (vconcat (nreverse dates))))


;;;; Actions

(defun orgwarrior--act (ids verb args note &optional new)
  "Apply VERB with ARGS to the tasks IDS, logging NOTE if given.
All IDs are resolved and the verb checked before anything changes.
NEW, refile only: a heading to make first and refile into, see
`orgwarrior--refile'."
  (when (and new (not (equal verb "refile")))
    (user-error "Only refile can make a new heading"))
  (pcase verb
    ;; A note on its own: no change, the text logged as org's `note'.
    ("note" (let ((text (or note (string-join args " "))))
              (unless (org-string-nw-p text) (user-error "note needs the note's text"))
              (orgwarrior--act-in-place ids verb nil text)))
    ("refile" (orgwarrior--refile ids args note new))
    ("kill" (orgwarrior--kill ids args note))
    ("archive" (orgwarrior--archive ids args note))
    ("rename" (orgwarrior--rename ids args note))
    ((or "up" "down" "promote" "demote") (orgwarrior--move ids verb args note))
    (_ (orgwarrior--act-in-place ids verb args note))))

(defun orgwarrior--move (ids verb args note)
  "Move the one task in IDS, with its subtree: up or down (VERB) among
its siblings, as M-up and M-down do; demote, under the sibling above, as
M-S-right does; promote, out of its parent to right after it.  Org's
M-S-left would leave it in place, its later siblings becoming its
children, so promote moves it below them first.  The result's :parent
is the title of the heading it's now under, null at the top level."
  (when (or args note) (user-error "%s takes nothing after it" verb))
  (when (cdr ids) (user-error "%s works on one task at a time" verb))
  (let* ((index (orgwarrior--index))
         (entry (orgwarrior--resolve index (car ids))))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      (let ((old (orgwarrior--parent-marker)))
        (pcase verb
          ((or "up" "down")
           (condition-case nil
               (if (equal verb "up") (org-move-subtree-up) (org-move-subtree-down))
             (error (user-error "It's already the %s at its level" (if (equal verb "up") "first" "last")))))
          ("demote"
           (unless (save-excursion (org-get-previous-sibling))
             (user-error "There's no heading above it at its level to go under"))
           (org-demote-subtree))
          ("promote"
           (unless old (user-error "It's already at the top level"))
           (while (save-excursion (org-get-next-sibling))
             (org-move-subtree-down))
           (org-promote-subtree)))
        (org-back-to-heading t)
        (orgwarrior--update-cookies (list old (orgwarrior--parent-marker))))
      (save-buffer)
      (vector (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash entry))
                                  :parent (or (save-excursion (and (org-up-heading-safe) (orgwarrior--title)))
                                              :null))))))

(defun orgwarrior--act-in-place (ids verb args note)
  (let* ((index (orgwarrior--index))
         (entries (orgwarrior--entries index ids))
         (buffers (delete-dups (mapcar #'orgwarrior-entry-buffer entries))))
    (mapc #'orgwarrior--check-writable buffers)
    (let ((planned (mapcar (lambda (e)
                             (cons e (orgwarrior--at e (orgwarrior--action verb args))))
                           entries))
          (markers nil))
      ;; Positions shift as earlier entries in the same buffer change.
      (dolist (p planned)
        (with-current-buffer (orgwarrior-entry-buffer (car p))
          (let ((m (copy-marker (orgwarrior-entry-pos (car p)))))
            (push m markers)
            (setf (orgwarrior-entry-pos (car p)) m))))
      (unwind-protect
          (vconcat
           (mapcar (lambda (p)
                     (orgwarrior--at (car p)
                       (funcall (cdr p))
                       (orgwarrior--flush-log note)
                       (org-back-to-heading t)
                       (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash (car p))))))
                   planned))
        (orgwarrior--save buffers)
        (dolist (m markers) (set-marker m nil))))))

(defvar org-blocked-by-checkboxes)

(defun orgwarrior--check-unblocked (to)
  "Refuse the change of the heading at point to TO that org blocks
\(`org-enforce-todo-dependencies', ORDERED, checkboxes): called from
code, `org-todo' only leaves it as it was, which read as done.  Asked
as `org-todo' asks, task by task: marking a project's tasks done along
with it is fine once they're done first."
  (let ((from (org-get-todo-state)) (org-blocked-by-checkboxes nil))
    (unless (or (null org-blocker-hook) (equal from to)
                (save-excursion
                  (save-match-data
                    (org-with-wide-buffer
                     (run-hook-with-args-until-failure
                      'org-blocker-hook (list :type 'todo-state-change :from from :to to
                                              :position (point)))))))
      (user-error "Org won't change %s from %s to %s, because %s" (orgwarrior--title) (or from "none") to
                  (if org-blocked-by-checkboxes "its checkboxes aren't all ticked"
                    (format "\"%s\" isn't done"
                            (replace-regexp-in-string "\\`\\*+ +" "" org-block-entry-blocking)))))))

(defun orgwarrior--action (verb args)
  "Return a function that applies VERB with ARGS at point, or signal
a `user-error' if they don't make sense here."
  (let ((keyword (orgwarrior--keyword-named verb)))
    (cond
     (keyword
      (when args (user-error "%s takes nothing after it" verb))
      (lambda ()
        (orgwarrior--check-unblocked keyword)
        (org-todo keyword)))
     ((equal verb "nokeyword")  ; C-c C-t SPC: a plain heading again
      (when args (user-error "nokeyword takes nothing after it"))
      (lambda () (org-todo "")))
     ((member verb '("sched" "due"))
      (let ((fn (if (equal verb "sched") #'org-schedule #'org-deadline))
            (date (string-join args " ")))
        (cond
         ((string-empty-p date) (user-error "%s needs a date, or \"none\" to remove it" verb))
         ((member date '("none" "-")) (lambda () (funcall fn '(4))))
         (t (pcase-let ((`(,input . ,exact) (orgwarrior--timestamp-input date))
                        (re (if (equal verb "sched") org-scheduled-time-regexp
                              org-deadline-time-regexp)))
              (lambda ()
                (funcall fn nil input)
                (when exact
                  (save-excursion
                    (when (re-search-forward re (save-excursion (outline-next-heading) (point)) t)
                      (replace-match (substring exact 1 -1) t t nil 1))))))))))
     ((equal verb "when")
      (let ((date (string-join args " ")))
        (cond
         ((string-empty-p date) (user-error "when needs a date, or \"none\" to remove it"))
         ((member date '("none" "-"))
          (lambda () (when-let* ((old (orgwarrior--when-line))) (delete-region (nth 0 old) (nth 1 old)))))
         (t (orgwarrior--when-action date)))))
     ((equal verb "note") #'ignore)
     ((equal verb "prop")
      (let ((name (car args)) (value (string-join (cdr args) " ")))
        (orgwarrior--check-property-name name)
        (cond ((string-empty-p value) (user-error "prop %s needs a value, or none to remove it" name))
              ((string-match-p "[\n\r]" value) (user-error "A property's value has to be one line: %s" name))
              ((member value '("none" "-")) (lambda () (org-delete-property name)))
              (t (lambda () (org-entry-put nil name value))))))
     ((equal verb "effort")
      (let ((value (string-join args " ")))
        (cond ((string-empty-p value) (user-error "effort needs a duration, like 0:30 or 1h, or none to remove it"))
              ((member value '("none" "-")) (lambda () (org-delete-property org-effort-property)))
              (t (lambda ()
                   (orgwarrior--check-effort value)
                   (org-entry-put nil org-effort-property value))))))
     ((equal verb "pri")
      (let ((value (upcase (string-join args " "))))
        (cond
         ((member value '("NONE" "-")) (lambda () (org-priority 'remove)))
         ;; Stepped by org, as S-up and S-down step it: past either end, removed.
         ((member value '("UP" "DOWN")) (let ((dir (intern (downcase value)))) (lambda () (org-priority dir))))
         ((member value (orgwarrior--priorities))
          (let ((p (if (orgwarrior--numeric-priorities-p) (string-to-number value) (string-to-char value))))
            (lambda () (org-priority p))))
         (t (user-error "pri takes one of %s, or up, down or none" (string-join (orgwarrior--priorities) " "))))))
     ((equal verb "tag")
      (unless args (user-error "tag needs tags to add or remove, like +home -work"))
      (let ((changes (mapcar (lambda (a)
                               (if (string-match "\\`\\([+-]\\)\\([[:alnum:]_@#%]+\\)\\'" a)
                                   (cons (match-string 2 a)
                                         (if (equal (match-string 1 a) "+") 'on 'off))
                                 (user-error "%s isn't a tag to add or remove. Write +tag or -tag" a)))
                             args)))
        (let ((exclusive (seq-filter (lambda (g) (plist-get g :exclusive)) (orgwarrior--tag-groups))))
          ;; As org's fast tag selection does: a tag from a { } group replaces the others.
          (lambda ()
            (dolist (c changes)
              (when (eq (cdr c) 'on)
                (dolist (g exclusive)
                  (when (member (car c) (plist-get g :tags))
                    (dolist (other (plist-get g :tags))
                      (unless (equal other (car c)) (org-toggle-tag other 'off))))))
              (org-toggle-tag (car c) (cdr c)))))))
     (t (user-error "There's no command %s. The keywords here are: %s"
                    verb (downcase (string-join org-todo-keywords-1 " ")))))))

(defun orgwarrior--all-tags ()
  "For a tag picker: the groups the agenda files declare (#+TAGS, as
`orgwarrior--tag-groups'), then every other tag in use, sorted.  Filetags are
left out: they belong to a file, not to what a task can be given."
  (let* ((groups (orgwarrior--tag-groups))
         (declared (seq-mapcat (lambda (g) (plist-get g :tags)) groups))
         (filetags (seq-mapcat (lambda (f) (buffer-local-value 'org-file-tags (orgwarrior--file-buffer f)))
                               (org-agenda-files))))
    (let ((other (sort (seq-remove
                        (lambda (s) (or (member s declared)
                                        (member s filetags)
                                        (not (string-match-p "\\`[[:alnum:]_@#%]+\\'" s))))
                        (delete-dups (mapcar #'car (org-global-tags-completion-table
                                                    (org-agenda-files)))))
                       #'string<)))
      (list :groups (vconcat (mapcar (lambda (g) (list :exclusive (if (plist-get g :exclusive) t :false)
                                                       :tags (vconcat (plist-get g :tags))))
                                     groups))
            :other (vconcat other)
            ;; Fast keys, as C-c C-q offers them: #+TAGS: @home(h), the rest as org assigns.
            :keys (vconcat (mapcar (lambda (k) (vector (car k) (char-to-string (cdr k))))
                                   (org-assign-fast-keys
                                    (mapcar (lambda (tag) (cons tag (orgwarrior--tag-key tag)))
                                            (append declared other)))))))))

(defun orgwarrior--tag-alists ()
  "`org-tag-persistent-alist', then each agenda file's tags (its #+TAGS,
else `org-tag-alist')."
  (cons org-tag-persistent-alist
        (mapcar (lambda (f) (buffer-local-value 'org-current-tag-alist (orgwarrior--file-buffer f)))
                (org-agenda-files))))

(defun orgwarrior--tag-key (tag)
  "TAG's fast key as a #+TAGS line or `org-tag-alist' gives it, or nil."
  (seq-some (lambda (alist) (cdr-safe (assoc tag alist))) (orgwarrior--tag-alists)))

(defun orgwarrior--tag-groups ()
  "The tag groups declared across the agenda files (each file's #+TAGS,
else `org-tag-alist'; and `org-tag-persistent-alist'), without repeats:
plists (:exclusive BOOL :tags LIST).  A { } group is exclusive; each
#+TAGS line outside one is a plain group."
  (let (groups)
    (dolist (alist (orgwarrior--tag-alists))
      (dolist (g (orgwarrior--parse-tag-alist alist))
        (unless (member g groups) (push g groups))))
    (nreverse groups)))

(defun orgwarrior--parse-tag-alist (alist)
  (let (groups current exclusive)
    (cl-flet ((flush ()
                (when current
                  (push (list :exclusive exclusive :tags (nreverse current)) groups)
                  (setq current nil))))
      (dolist (e alist)
        (pcase (car-safe e)
          (:startgroup (flush) (setq exclusive t))
          (:endgroup (flush) (setq exclusive nil))
          (:newline (unless exclusive (flush)))
          ((pred stringp) (push (car e) current))))
      (flush))
    (nreverse groups)))

(defun orgwarrior--keywords (&optional file)
  "The TODO keywords of FILE (its #+TODO, else org's), or org's own
without one, and the priorities, highest first."
  (cl-flet ((here () (list :keywords (vconcat org-todo-keywords-1)
                           :done (vconcat org-done-keywords)
                           :keys (orgwarrior--keyword-keys)
                           :priorities (vconcat (orgwarrior--priorities))
                           ;; How far ahead a deadline shows without a -3d of its own.
                           :warning_days org-deadline-warning-days)))
    (if file
        (let ((file (expand-file-name file)))
          (unless (file-exists-p file) (user-error "There's no file %s" file))
          (with-current-buffer (orgwarrior--file-buffer file) (here)))
      (with-temp-buffer
        (delay-mode-hooks (org-mode))
        (here)))))

(defun orgwarrior--keyword-keys ()
  "The current buffer's TODO keywords' fast keys, as C-c C-t takes them:
`TODO(t)' in `org-todo-keywords', else org's own choice; a string each, in
the keywords' order, null for one without."
  (vconcat (mapcar (lambda (k) (if-let* ((c (cdr (assoc k org-todo-key-alist)))) (char-to-string c) :null))
                   org-todo-keywords-1)))

(defun orgwarrior--keyword-named (word &optional keywords)
  "The keyword in KEYWORDS (default the buffer's) that WORD names, as
it's spelled there: `waiting' names \"Waiting\".  Nil if none."
  (let ((keywords (or keywords org-todo-keywords-1)))
    (or (car (member word keywords)) (assoc-string word keywords t))))

(defun orgwarrior--all-keywords ()
  "Every TODO keyword: org's, then each agenda file's own #+TODO."
  (delete-dups
   (append (plist-get (orgwarrior--keywords) :keywords) nil
           (seq-mapcat (lambda (f) (buffer-local-value 'org-todo-keywords-1 (orgwarrior--file-buffer f)))
                       (org-agenda-files)))))

(defun orgwarrior--wants-note (ids verb)
  "Whether org would ask for a note when any of IDS changes to keyword
VERB, so the CLI can ask instead.  `org-todo''s own logic: the
keyword's `@' (or leaving one with `@' on exit), else `org-log-done',
with LOGGING properties applied."
  (let ((index (orgwarrior--index)))
    (if (seq-some
         (lambda (id)
           (orgwarrior--at (orgwarrior--resolve index id)
             (when-let* ((keyword (orgwarrior--keyword-named verb)))
               (let* ((org-log-done org-log-done)
                      (org-todo-log-states org-todo-log-states)
                      (from (org-get-todo-state))
                      (logging (org-entry-get nil "LOGGING" t t)))
                 (when logging (org-local-logging logging))
                 (let ((dolog (or (nth 1 (assoc keyword org-todo-log-states))
                                  (nth 2 (assoc from org-todo-log-states)))))
                   (or (eq dolog 'note)
                       (and (not dolog) (eq org-log-done 'note)
                            (member keyword org-done-keywords)
                            (not (member from org-done-keywords)))))))))
         ids)
        t
      :false)))

(defun orgwarrior--flush-log (note)
  "Write the log entry org has queued, with NOTE as its text.
Org queues state-change and reschedule logging on `post-command-hook',
which never runs for `emacsclient --eval' (or worse, runs on the user's
next keystroke).  Store it now, without the note prompt.  With NOTE and
nothing queued, log a plain note."
  (when (and note (not org-log-setup))
    (org-add-log-setup 'note nil nil 'note))
  (when org-log-setup
    (remove-hook 'post-command-hook #'org-add-log-note)
    (setq org-log-setup nil)
    ;; `org-store-log-note' restores these, as `org-add-log-note' set them.
    (setq org-log-note-window-configuration (current-window-configuration))
    (move-marker org-log-note-return-to (point))
    (with-current-buffer (get-buffer-create " *orgwarrior note*")
      (erase-buffer)
      (when note (insert note))
      ;; Stores the note at `org-log-note-marker' and kills this buffer.
      (org-store-log-note))))


;;;; Clocking

;; The files are the truth: a running clock is an open CLOCK line in an
;; agenda file, found there, not in the daemon's memory (it doesn't survive a
;; restart, and another machine's Emacs clocks through Syncthing).  Org writes
;; and closes the lines.

(defconst orgwarrior--clock-stale-minutes 240
  "A clock running longer is flagged, likely forgotten: org's idle
detection needs a frame, which a clock started from a phone never has.")

(defun orgwarrior--clock-line-re ()
  "A CLOCK line: its start (group 1) and, once closed, its end (group 2)."
  (concat "^[ \t]*" (regexp-quote org-clock-string)
          " *\\(\\[[^]\n]+\\]\\)\\(?:--\\(\\[[^]\n]+\\]\\)\\)?"))

(defun orgwarrior--open-clock-p ()
  "Non-nil if the line at point is an open CLOCK line."
  (save-excursion
    (forward-line 0)
    (and (looking-at (orgwarrior--clock-line-re)) (not (match-beginning 2)))))

(defun orgwarrior--clock-hm (time) (format-time-string "%H:%M" time))
(defun orgwarrior--clock-iso (time) (format-time-string "%Y-%m-%d %H:%M" time))

(defun orgwarrior--minutes (start &optional end)
  "Whole minutes from START to END (default now)."
  (floor (float-time (time-subtract end start)) 60))

(defconst orgwarrior--clock-ago-re
  "\\`\\([-+]\\)\\(?:\\([0-9]+\\)h\\)?\\(?:\\([0-9]+\\)m\\)?\\'"
  "A clock time from now: -15m, -1h30m ago, +10m to come.")

(defconst orgwarrior--clock-of-day-re
  "\\`\\([0-9]\\{1,2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?\\([ap]m\\)?\\'"
  "A time of day: 17:30, 5:30pm, 5pm.")

(defun orgwarrior--next-day (time)
  "TIME's time of day on the next day: not 24 hours on, since a day a clock
change falls in has 23 or 25 (23:00-03:30 across one ended at 04:30)."
  (let ((d (decode-time time)))
    (setf (decoded-time-day d) (1+ (decoded-time-day d))
          (decoded-time-dst d) -1
          (decoded-time-zone d) nil)
    (encode-time d)))

(defun orgwarrior--clock-time (string &optional day later)
  "The time STRING gives a clock's start or end, nil for now (org's,
rounded as `org-clock-rounding-minutes' says): `-15m', `-1h30m', that
long ago, `+10m' that long from now; a time of day (`17:30', `5:30pm')
on DAY's date (a time, default today); a date and a time (`yesterday
17:30').  Not later than now unless LATER (an end: a clock started later
than now would run before it began).  Not `orgwarrior--parse-date': org
reads a bare time as no date."
  (let* ((words (split-string (downcase (or string ""))))
         (last (car (last words)))
         (time
          (cond
           ((null words) nil)
           ((and (null (cdr words)) (string-match orgwarrior--clock-ago-re last)
                 (or (match-beginning 2) (match-beginning 3)))
            (time-add nil (* (if (equal (match-string 1 last) "-") -60 60)
                             (+ (* 60 (string-to-number (or (match-string 2 last) "0")))
                                (string-to-number (or (match-string 3 last) "0"))))))
           ((string-match orgwarrior--clock-of-day-re last)
            (let ((h (string-to-number (match-string 1 last)))
                  (m (if (match-beginning 2) (string-to-number (match-string 2 last)) 0))
                  (ampm (match-string 3 last)))
              (unless (or (match-beginning 2) ampm)
                (user-error "Can't read %s as a time. Try 17:30, 5pm or -15m" string))
              (when ampm
                (unless (<= 1 h 12) (user-error "Can't read %s as a time" string))
                (setq h (+ (mod h 12) (if (equal ampm "pm") 12 0))))
              (unless (and (< h 24) (< m 60)) (user-error "Can't read %s as a time" string))
              (let ((d (decode-time (if (cdr words)
                                        (nth 1 (orgwarrior--read-date (string-join (butlast words) " ")))
                                      day))))
                (encode-time (list 0 m h (decoded-time-day d) (decoded-time-month d)
                                   (decoded-time-year d) nil -1 nil)))))
           (t (user-error "Can't read %s as a time. Try 17:30, 5pm, -15m or yesterday 17:30" string)))))
    (when (and time (not later) (time-less-p nil time))
      (user-error "%s is later than now, and a clock can't start in the future" (string-trim string)))
    time))

(defun orgwarrior--forget-clock ()
  "Make the daemon forget its running clock, as `org-clock-cancel' does,
leaving the line alone."
  (move-marker org-clock-marker nil)
  (move-marker org-clock-hd-marker nil)
  (setq org-clock-current-task nil)
  (when org-clock-mode-line-timer
    (cancel-timer org-clock-mode-line-timer)
    (setq org-clock-mode-line-timer nil))
  (when org-clock-idle-timer
    (cancel-timer org-clock-idle-timer)
    (setq org-clock-idle-timer nil))
  (setq global-mode-string (delq 'org-mode-line-string global-mode-string))
  (org-clock-restore-frame-title-format)
  (force-mode-line-update t))

(defun orgwarrior--clock-sync-memory ()
  "Forget the daemon's running clock if its line is no open clock any more
(closed or removed elsewhere).  Else org, clocking in, would close the
line again, over the end already written."
  (when (and (org-clocking-p)
             (not (with-current-buffer (org-clocking-buffer)
                    (org-with-wide-buffer
                     (goto-char org-clock-marker)
                     (orgwarrior--open-clock-p)))))
    (orgwarrior--forget-clock)))

(defun orgwarrior--clock-index ()
  "`orgwarrior--index', then the daemon's clock checked against the files
it just reread."
  (prog1 (orgwarrior--index) (orgwarrior--clock-sync-memory)))

(defun orgwarrior--open-clocks ()
  "Every open clock in the agenda files, oldest first, as
`org-find-open-clocks' gives them: (MARKER . START)."
  (sort (seq-mapcat (lambda (f) (org-find-open-clocks
                                 (buffer-file-name (orgwarrior--file-buffer f))))
                    (orgwarrior--agenda-files))
        (lambda (a b) (time-less-p (cdr a) (cdr b)))))

(defun orgwarrior--free-clocks (clocks)
  (dolist (c clocks) (set-marker (car c) nil)))

(defun orgwarrior--clock-on-p (clock entry)
  "Non-nil if CLOCK is in ENTRY's own section."
  (org-with-clock-position clock
    (org-back-to-heading t)
    (and (eq (current-buffer) (orgwarrior-entry-buffer entry))
         (= (point) (orgwarrior-entry-pos entry)))))

(defun orgwarrior--clock-data (index clock)
  "CLOCK's task and times, while running: {id, heading, title, file, start,
end (null), minutes, stale, keyword, done}."
  (org-with-clock-position clock
    (org-back-to-heading t)
    (let ((minutes (orgwarrior--minutes (cdr clock))))
      (append
       (list :id (orgwarrior--id index (orgwarrior--hash-at-point))
             :heading (orgwarrior--heading-line)
             :title (orgwarrior--title)
             :file (orgwarrior--file-key (orgwarrior--buffer-file))
             :start (orgwarrior--clock-iso (cdr clock))
             :end :null
             :minutes minutes
             :stale (if (>= minutes orgwarrior--clock-stale-minutes) t :false)
             :effort_minutes (orgwarrior--effort-minutes))
       (orgwarrior--keyword-props)))))

(defun orgwarrior--clock-status ()
  "The clocks running, oldest first, as `orgwarrior--clock-data' gives them."
  (let ((index (orgwarrior--index))
        (clocks (orgwarrior--open-clocks)))
    (unwind-protect
        (vconcat (mapcar (lambda (c) (orgwarrior--clock-data index c)) clocks))
      (orgwarrior--free-clocks clocks))))

(defun orgwarrior--running-list (index clocks)
  (mapconcat (lambda (c)
               (let ((d (orgwarrior--clock-data index c)))
                 (format "  %s  %s  since %s" (plist-get d :id) (plist-get d :heading)
                         (substring (plist-get d :start) 11))))
             clocks "\n"))

(defun orgwarrior--running-clock (index id clocks)
  "Of CLOCKS (open ones), the one ID's task has, else the only one."
  (let* ((entry (and id (orgwarrior--resolve index id)))
         (mine (if entry (seq-filter (lambda (c) (orgwarrior--clock-on-p c entry)) clocks) clocks)))
    (cond ((null mine) (if entry (user-error "There's no clock running on %s" id) (user-error "There's no clock running")))
          ((cdr mine)
           (user-error "Clocks are running on %d tasks. Name one by its ID:\n%s"
                       (length mine) (orgwarrior--running-list index mine)))
          (t (car mine)))))

(defun orgwarrior--close-clock (index clock at)
  "Close CLOCK at AT (nil: now) with `org-clock-out', logging what org
queues; return its data, :removed when org removed a zero-time line."
  (let ((data (orgwarrior--clock-data index clock)))
    (org-clock-clock-out clock nil at)
    (org-with-clock-position clock
      (let* ((closed (and (looking-at (orgwarrior--clock-line-re)) (match-beginning 2)
                          (org-time-string-to-time (match-string 2))))
             (end (or closed at (current-time))))
        (org-back-to-heading t)
        (orgwarrior--flush-log nil)
        (setq data (plist-put data :end (orgwarrior--clock-iso end)))
        (setq data (plist-put data :minutes (orgwarrior--minutes (cdr clock) end)))
        (setq data (plist-put data :stale :false))
        (plist-put data :removed (if closed :false t))))))

(defun orgwarrior--clock-in (id time)
  "Clock in on ID's task, at TIME (`orgwarrior--clock-time'; nil: now), as
`org-clock-in' does, closing whatever clock is running, at the same time.
{clock: the new one, closed: those closed}."
  (let* ((index (orgwarrior--clock-index))
         (entry (orgwarrior--resolve index id))
         (start (orgwarrior--clock-time time))
         (open (orgwarrior--open-clocks))
         (buffers (delete-dups (cons (orgwarrior-entry-buffer entry)
                                     (mapcar (lambda (c) (marker-buffer (car c))) open)))))
    (unwind-protect
        (progn
          (mapc #'orgwarrior--check-writable buffers)
          (when-let* ((here (seq-find (lambda (c) (orgwarrior--clock-on-p c entry)) open)))
            (user-error "You're already clocked in on it, since %s" (orgwarrior--clock-hm (cdr here))))
          (when-let* ((later (and start (seq-find (lambda (c) (time-less-p start (cdr c))) open))))
            (user-error "%s is before the running clock started (%s), on:\n%s"
                        (string-trim time) (orgwarrior--clock-hm (cdr later))
                        (orgwarrior--running-list index (list later))))
          (let ((closed (mapcar (lambda (c) (orgwarrior--close-clock index c start)) open)))
            (orgwarrior--at entry
              ;; Org's dangling-clock resolution and "start from the last
              ;; clock out?" prompt; the clocks are already closed.
              (let ((org-clock-auto-clock-resolution nil)
                    (org-clock-leftover-time nil)
                    (org-clock-continuously (and (not start) org-clock-continuously)))
                (org-clock-in nil start))
              (orgwarrior--flush-log nil))
            (orgwarrior--save buffers)
            (list :clock (orgwarrior--clock-data index (cons org-clock-marker org-clock-start-time))
                  :closed (vconcat closed))))
      (orgwarrior--free-clocks open))))

(defun orgwarrior--clock-out (id time)
  "Clock out, at TIME (nil: now): of ID's task's clock, else the one
running.  The clock's data, with its end."
  (let* ((index (orgwarrior--clock-index))
         (open (orgwarrior--open-clocks)))
    (unwind-protect
        (let* ((clock (orgwarrior--running-clock index id open))
               (buf (marker-buffer (car clock)))
               (at (orgwarrior--clock-time time nil t)))
          (orgwarrior--check-writable buf)
          (when (and at (time-less-p at (cdr clock)))
            (user-error "%s is before the clock started (%s)" (string-trim time) (orgwarrior--clock-hm (cdr clock))))
          (prog1 (orgwarrior--close-clock index clock at)
            (orgwarrior--save (list buf))))
      (orgwarrior--free-clocks open))))

(defun orgwarrior--clock-cancel (id)
  "Remove the running clock's line (ID's task's, else the one running), as
`org-clock-cancel' does: for one started by mistake."
  (let* ((index (orgwarrior--clock-index))
         (open (orgwarrior--open-clocks)))
    (unwind-protect
        (let* ((clock (orgwarrior--running-clock index id open))
               (data (orgwarrior--clock-data index clock)))
          (orgwarrior--check-writable (marker-buffer (car clock)))
          (org-with-clock-position clock
            (when (and (org-clocking-p) (eq (org-clocking-buffer) (current-buffer))
                       (= (line-beginning-position)
                          (save-excursion (goto-char org-clock-marker) (line-beginning-position))))
              (orgwarrior--forget-clock))
            (delete-region (line-beginning-position) (line-beginning-position 2))
            (org-clock-remove-empty-clock-drawer)
            (save-buffer))
          data)
      (orgwarrior--free-clocks open))))

(defun orgwarrior--entry-clocks ()
  "The CLOCK lines of the entry at point (its own, not its children's),
newest first: (BEG START END), END nil while running."
  (save-excursion
    (org-back-to-heading t)
    (let ((limit (save-excursion (outline-next-heading) (point)))
          (re (orgwarrior--clock-line-re))
          clocks)
      (while (re-search-forward re limit t)
        (let ((start (match-string 1)) (end (match-string 2)))  ; parsing clobbers the match
          (when (orgwarrior--el-type-p (org-element-at-point) 'clock)
            (push (list (line-beginning-position) (org-time-string-to-time start)
                        (and end (org-time-string-to-time end)))
                  clocks))))
      (sort clocks (lambda (a b) (time-less-p (nth 1 b) (nth 1 a)))))))

(defun orgwarrior--clocks-here (index)
  "The entry at point's clocks: {id, heading, minutes (all of them),
clocks: [{n, start, end, minutes, text}]}, newest first, N from 1."
  (let ((n 0) (total 0))
    (append
     (list :id (orgwarrior--id index (orgwarrior--hash-at-point))
          :heading (orgwarrior--heading-line)
          :clocks (vconcat
                   (mapcar (pcase-lambda (`(,beg ,start ,end))
                             (let ((minutes (orgwarrior--minutes start end)))
                               (cl-incf total minutes)
                               (list :n (cl-incf n)
                                     :start (orgwarrior--clock-iso start)
                                     :end (if end (orgwarrior--clock-iso end) :null)
                                     :minutes minutes
                                     :text (save-excursion
                                             (goto-char beg)
                                             (string-trim (buffer-substring-no-properties
                                                           beg (line-end-position)))))))
                           (orgwarrior--entry-clocks)))
          :minutes total)
     (orgwarrior--keyword-props))))

(defun orgwarrior--clocks (id)
  (let ((index (orgwarrior--index)))
    (orgwarrior--at (orgwarrior--resolve index id)
      (orgwarrior--clocks-here index))))

(defun orgwarrior--clock-edit (id n start end old remove)
  "Change clock N (as `orgwarrior--clocks' numbers them) of ID's task: its
START and/or END (`orgwarrior--clock-time', a time of day on the clock's
own date; an end before the start is the next day's), or REMOVE it.
OLD, the line as shown, must still match.  Org recomputes the total, as
after S-up on a CLOCK line.  The task's clocks after."
  (let* ((index (orgwarrior--clock-index))
         (entry (orgwarrior--resolve index id)))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      (let* ((clocks (orgwarrior--entry-clocks))
             (clock (or (and (integerp n) (> n 0) (nth (1- n) clocks))
                        (user-error "There's no clock %s on it. It has %d" n (length clocks)))))
        (pcase-let ((`(,beg ,s ,e) clock))
          (goto-char beg)
          (when (and old (not (equal old (string-trim (buffer-substring-no-properties
                                                         beg (line-end-position))))))
            (user-error "That clock changed since it was shown. Show the task again"))
          (let ((active (and (org-clocking-p) (eq (org-clocking-buffer) (current-buffer))
                             (= beg (save-excursion (goto-char org-clock-marker)
                                                    (line-beginning-position)))))
                (start (org-string-nw-p start))
                (end (org-string-nw-p end)))
            (cond
             (remove
              (when active (orgwarrior--forget-clock))
              (delete-region beg (line-beginning-position 2))
              (org-clock-remove-empty-clock-drawer))
             ((not (or start end)) (user-error "Give a new start or end, or remove the clock"))
             ((and end (not e)) (user-error "That clock is still running. Clock out to end it"))
             (t
              (let* ((new-s (if start (orgwarrior--clock-time start s) s))
                     (new-e (and e (if end (orgwarrior--clock-time end new-s t) e))))
                ;; 23:30-0:15: past midnight.  Only overnight: else a typo.
                (when (and end new-e (time-less-p new-e new-s)
                           (string-match-p orgwarrior--clock-of-day-re (string-trim end)))
                  (let ((next (orgwarrior--next-day new-e)))
                    (when (< (orgwarrior--minutes new-s next) (* 12 60))
                      (setq new-e next))))
                (when (and new-e (time-less-p new-e new-s))
                  (user-error "It would end (%s) before it starts (%s)"
                              (orgwarrior--clock-iso new-e) (orgwarrior--clock-iso new-s)))
                (looking-at (orgwarrior--clock-line-re))
                (let ((from (match-beginning 1))
                      (fmt (org-time-stamp-format t t)))  ; clobbers the match
                  (delete-region from (line-end-position))
                  (goto-char from)
                  (insert (format-time-string fmt new-s)
                          (if new-e (concat "--" (format-time-string fmt new-e)) "")))
                (goto-char beg)
                ;; Writes the => total; for the running clock, the daemon's start.
                (org-clock-update-time-maybe))))))
        (save-buffer)
        (goto-char (orgwarrior-entry-pos entry))
        (orgwarrior--clocks-here index)))))


(defun orgwarrior--clock-duration (string)
  "The minutes STRING says: 1h30m, 45m, 2h, 1:30."
  (let ((s (downcase (string-trim string))))
    (cond
     ((string-match "\\`\\([0-9]+\\):\\([0-5][0-9]\\)\\'" s)
      (+ (* 60 (string-to-number (match-string 1 s))) (string-to-number (match-string 2 s))))
     ((and (string-match "\\`\\(?:\\([0-9]+\\)h\\)?\\(?:\\([0-9]+\\)m\\)?\\'" s)
           (or (match-beginning 1) (match-beginning 2)))
      (+ (* 60 (string-to-number (or (match-string 1 s) "0")))
         (string-to-number (or (match-string 2 s) "0"))))
     (t (user-error "Can't read %s as a duration. Try 1h30m, 45m or 1:30" string)))))

(defun orgwarrior--clock-add (id start end duration)
  "Log a finished clock on ID's task, time already spent: from START
(`orgwarrior--clock-time') to END (a time of day on START's date; before
it, overnight, the next day's) or for DURATION (`orgwarrior--clock-duration').
A running clock is left alone, unlike clocking in at START.  Written where
`org-clock-in' writes one, the total as org computes it.  The task's
clocks after."
  (let* ((index (orgwarrior--clock-index))
         (entry (orgwarrior--resolve index id))
         (end (org-string-nw-p end))
         (duration (org-string-nw-p duration)))
    (unless (org-string-nw-p start) (user-error "Give the time it started, like 14:00 or yesterday 14:00"))
    (unless (xor end duration) (user-error "Give either the time it ended or how long it took"))
    (let* ((s (orgwarrior--clock-time start))
           (e (if duration
                  (time-add s (* 60 (orgwarrior--clock-duration duration)))
                (orgwarrior--clock-time end s t))))
      (when (and end (time-less-p e s)
                 (string-match-p orgwarrior--clock-of-day-re (downcase (string-trim end))))
        (let ((next (orgwarrior--next-day e)))
          (when (< (orgwarrior--minutes s next) (* 12 60))
            (setq e next))))
      (unless (time-less-p s e)
        (user-error "It would end (%s) before it starts (%s)"
                    (orgwarrior--clock-iso e) (orgwarrior--clock-iso s)))
      (when (time-less-p nil e)
        (user-error "It would end (%s) later than now. For time that hasn't happened yet, clock in instead"
                    (orgwarrior--clock-iso e)))
      (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
      (orgwarrior--at entry
        (org-clock-find-position nil)
        ;; As org-clock-in inserts its line.
        (insert-before-markers-and-inherit "\n")
        (backward-char 1)
        (when (save-excursion (end-of-line 0) (org-in-item-p))
          (forward-line 0)
          (indent-line-to (max 0 (- (current-indentation) 2))))
        (let ((fmt (org-time-stamp-format t t)))
          (insert-and-inherit org-clock-string " " (format-time-string fmt s)
                              "--" (format-time-string fmt e)))
        (forward-line 0)
        (org-clock-update-time-maybe)
        (save-buffer)
        (goto-char (orgwarrior-entry-pos entry))
        (orgwarrior--clocks-here index)))))


;;;; Clock reports

(defun orgwarrior--report-span (word)
  "A report's span WORD as (BLOCK KIND [START END]): BLOCK what org's
clocktable takes as :block, KIND day, week, month, year or range; a
range's dates as START and END.  Nil if WORD is no span."
  (let ((w (downcase (or word ""))))
    (cond
     ((member w '("" "today")) '(today day))
     ((equal w "yesterday") '(yesterday day))
     ((member w '("week" "thisweek")) '(thisweek week))
     ((equal w "lastweek") '(lastweek week))
     ((member w '("month" "thismonth")) '(thismonth month))
     ((equal w "lastmonth") '(lastmonth month))
     ((member w '("year" "thisyear")) '(thisyear year))
     ((equal w "lastyear") '(lastyear year))
     ((string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" w) (list w 'day))
     ((string-match-p "\\`[0-9]\\{4\\}-w[0-9]\\{1,2\\}\\'" w) (list (upcase w) 'week))
     ((string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}\\'" w) (list w 'month))
     ((string-match-p "\\`[0-9]\\{4\\}\\'" w) (list w 'year))
     ((string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\.\\.\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\'" w)
      (list nil 'range (match-string 1 w) (match-string 2 w))))))

(defun orgwarrior--span (words)
  "The span WORDS names, as `orgwarrior--report-span' reads it (default
today): (START END LABEL SPAN), END the start of the day after its last.
Anything else is refused."
  (let ((span (orgwarrior--report-span words)))
    (unless span
      (user-error "Can't read %s as a span. Try today, week, lastweek, month, 2026-10-20, 2026-W43, 2026-10 or A..B"
                  words))
    (orgwarrior--span-range span)))

(defun orgwarrior--span-range (span)
  "(START END LABEL SPAN) for SPAN, from `orgwarrior--report-span'."
  (let ((range (if (car span)
                   (org-clock-special-range (car span) nil t)
                 (let ((after (format-time-string
                               "%F" (time-add (org-time-string-to-time (nth 3 span)) (* 36 3600)))))
                   (list (format "<%s>" (nth 2 span)) (format "<%s>" after)
                         (format "%s to %s" (nth 2 span) (nth 3 span)))))))
    (list (org-time-string-to-time (nth 0 range)) (org-time-string-to-time (nth 1 range))
          (nth 2 range) span)))

(defun orgwarrior--report-steps (kind start)
  "The spans before and after one of KIND starting at START, for stepping:
\(PREV . NEXT), :null for a range."
  (let ((noon (time-add start (* 12 3600)))  ; days counted from noon: DST moves midnight
        (day (* 24 3600)))
    (pcase kind
      ('day (cons (format-time-string "%F" (time-subtract noon day)) (format-time-string "%F" (time-add noon day))))
      ('week (cons (format-time-string "%G-W%V" (time-subtract noon (* 7 day)))
                   (format-time-string "%G-W%V" (time-add noon (* 7 day)))))
      ('month (cons (format-time-string "%Y-%m" (time-subtract noon day))
                    (format-time-string "%Y-%m" (time-add noon (* 32 day)))))
      ('year (cons (format-time-string "%Y" (time-subtract noon day))
                   (format-time-string "%Y" (time-add noon (* 366 day)))))
      (_ (cons :null :null)))))

(defun orgwarrior--report (words)
  "Time clocked, as org's clocktable counts it (`org-clock-get-table-data'),
over the agenda files: WORDS a span (today, week, lastweek, 2026-10, a
range 2026-10-01..2026-10-15; default today) and a tag match.  {label,
start, end (its last day), kind, prev, next, match, minutes, files: [{file,
minutes, rows: [{depth, id, title, minutes, effort_minutes}]}]}, every
level, in file order."
  (let* ((parts (split-string (or words "")))
         (span (orgwarrior--report-span (car parts)))
         (match (string-join (if span (cdr parts) parts) " "))
         (span (or span (orgwarrior--report-span "today")))
         (index (orgwarrior--index))
         (block (car span))
         (range (orgwarrior--span-range span))
         (start (nth 0 range))
         (end (time-subtract (nth 1 range) (* 12 3600)))
         (params (append (list :maxlevel 100 :properties (list org-effort-property)
                               :match (org-string-nw-p match))
                         (if block (list :block block)
                           (list :tstart (nth 2 span) :tend (format-time-string "%F" (nth 1 range))))))
         (steps (orgwarrior--report-steps (nth 1 span) start))
         files (total 0))
    (dolist (f (orgwarrior--agenda-files))
      (with-current-buffer (orgwarrior--file-buffer f)
        (org-with-wide-buffer
         (let ((key (orgwarrior--file-key (orgwarrior--buffer-file)))
               ;; The clocktable gives titles, not positions: a twin's row gets no ID.
               (counts (orgwarrior-file-index-counts (orgwarrior--file-index))))
           (pcase-let ((`(,_ ,minutes ,rows) (org-clock-get-table-data key params)))
             (when (and minutes (> minutes 0))
               (cl-incf total minutes)
               (push (list :file key :minutes minutes
                           :rows (vconcat
                                  (mapcar (pcase-lambda (`(,level ,headline ,_ ,_ ,time ,props))
                                            (let ((effort (cdr (assoc org-effort-property props)))
                                                  (title (orgwarrior--title-of headline)))
                                              (list :depth level
                                                    :id (or (and (< (gethash title counts 0) 2)
                                                                 (orgwarrior--id index (orgwarrior--hash key title)))
                                                            :null)
                                                    :title (org-link-display-format title)
                                                    :minutes time
                                                    :effort_minutes (if (and effort (org-duration-p effort))
                                                                        (round (org-duration-to-minutes effort))
                                                                      :null))))
                                          rows)))
                     files)))))))
    (list :label (nth 2 range) :kind (symbol-name (nth 1 span))
          :start (format-time-string "%F" start) :end (format-time-string "%F" end)
          :prev (car steps) :next (cdr steps) :match (or (org-string-nw-p match) :null)
          :minutes total :files (vconcat (nreverse files)))))


;;;; Properties

(defun orgwarrior--properties ()
  "The entry at point's own properties, as its drawer lists them:
plists (:name :value).  Not inherited ones, nor org's special ones."
  (let ((block (org-get-property-block)) props)
    (when block
      (save-excursion
        (goto-char (car block))
        (while (re-search-forward org-property-re (cdr block) t)
          (push (list :name (match-string-no-properties 2)
                      :value (string-trim (or (match-string-no-properties 3) "")))
                props))))
    (vconcat (nreverse props))))

(defun orgwarrior--effort-minutes ()
  "The entry at point's Effort in minutes, or :null (none, or not a duration)."
  (let ((effort (org-entry-get nil org-effort-property)))
    (or (and effort (org-duration-p effort) (round (org-duration-to-minutes effort))) :null)))

(defun orgwarrior--check-property-name (name)
  (unless (and name (string-match-p "\\`[^ \t:]+\\'" name))
    (user-error "%s can't be a property name" (or name "")))
  (when (member (upcase name) org-special-properties)
    (user-error "%s is one of org's own properties. It has its own command" name)))

(defun orgwarrior--check-effort (value)
  "VALUE is an effort org reads, one of Effort_ALL's where that's set."
  (let ((allowed (org-property-get-allowed-values nil org-effort-property)))
    (cond ((and allowed (not (member value allowed)))
           (user-error "Effort has to be one of %s here" (string-join allowed " ")))
          ((not (org-duration-p value))
           (user-error "Can't read %s as a duration. Try 0:30, 1:15 or 2h" value)))))

(defun orgwarrior--props (id name)
  "For a property editor: {names: the property names in use across the
agenda files, values: NAME's allowed values for ID's task (its _ALL), or
null}."
  (let* ((index (orgwarrior--index))
         (entry (and id (orgwarrior--resolve index id))))
    (list :names (vconcat (sort (delete-dups
                                 (seq-mapcat (lambda (f) (with-current-buffer (orgwarrior--file-buffer f)
                                                           (org-buffer-property-keys)))
                                             (orgwarrior--agenda-files)))
                                #'string<))
          :values (or (and entry name
                           (orgwarrior--at entry
                             (let ((allowed (org-property-get-allowed-values nil name)))
                               (and allowed (vconcat allowed)))))
                      :null))))


;;;; Refile

(defun orgwarrior--in (where fn)
  "Call FN on WHERE: an entry, at its heading, or a buffer, at its start."
  (if (bufferp where)
      (with-current-buffer where
        (org-with-wide-buffer (goto-char (point-min)) (funcall fn)))
    (orgwarrior--at where (funcall fn))))

(defun orgwarrior--refile-targets (entries)
  "The refile targets org offers for ENTRIES (`org-refile-targets'; an
entry may be a buffer, for adding to it), as
plists, each file's top level first: org offers it only with
`org-refile-use-outline-path' set to `file', and without it a heading
can't be moved up to the top level.  Read-only files are left out
\(`orgwarrior--read-only-p'): nothing can go there.  :key is (BUFFER . POS),
comparable with `orgwarrior--parent-key'."
  (let (raw seen)
    (dolist (e entries)
      (orgwarrior--in e
        (lambda ()
          ;; A nil file in `org-refile-targets' means the current buffer.
          (dolist (tgt (org-refile-get-targets))
            (let ((key (cons (file-truename (nth 1 tgt)) (nth 3 tgt))))
              (unless (member key seen)
                (push key seen)
                (push tgt raw)))))))
    (setq raw (nreverse raw))
    (let ((files (seq-filter #'file-writable-p (orgwarrior--refile-files entries))))
      (setq raw (seq-filter (lambda (tg) (file-writable-p (nth 1 tg))) raw))
      (mapcar #'orgwarrior--target
              (append (mapcar (lambda (f) (list nil f nil nil)) files)
                      ;; Org's own file targets, for files that list missed.
                      (seq-filter (lambda (tg) (and (null (nth 3 tg))
                                                    (not (member (file-truename (nth 1 tg)) files))))
                                  raw)
                      (seq-filter (lambda (tg) (nth 3 tg)) raw))))))

(defun orgwarrior--target (rfloc)
  "RFLOC, a refile location (NAME FILE REGEXP POS), as a target plist."
  (let* ((file (nth 1 rfloc)) (pos (nth 3 rfloc))
         (buf (orgwarrior--file-buffer file)))
    (with-current-buffer buf
      (org-with-wide-buffer
       (let ((label (orgwarrior--file-key file)))
         (append
          (list :rfloc rfloc :buffer buf :key (cons buf pos) :file (file-name-base file))
          (if (not pos)
              (list :name (file-name-base file) :label label)
            (goto-char pos)
            (list :name (orgwarrior--title)
                  :label (string-join (cons label (org-get-outline-path t)) " › ")))))))))

(defun orgwarrior--refile-files (entries)
  "The files `org-refile-targets' names for ENTRIES, as org reads it: a
nil file is the entry's own."
  (let (files)
    (dolist (e entries)
      (orgwarrior--in e
        (lambda ()
          (dolist (spec org-refile-targets)
            (let ((f (car spec)))
              (setq f (cond ((null f) (list (orgwarrior--buffer-file)))
                            ((eq f 'org-agenda-files) (org-agenda-files t))
                            ((and (symbolp f) (fboundp f)) (funcall f))
                            ((and (symbolp f) (boundp f)) (symbol-value f))
                            (t f)))
              (dolist (file (if (stringp f) (list f) f))
                (when (stringp file)
                  (cl-pushnew (file-truename (expand-file-name file org-directory)) files
                              :test #'equal))))))))
    (seq-filter #'file-exists-p (nreverse files))))

(defun orgwarrior--refile-place-labels (ids)
  "The places for a new heading for the tasks IDS (refile's --new): the
refile targets, each file's top level included, as labels it takes as is."
  (let* ((index (orgwarrior--index))
         (entries (mapcar (lambda (id) (orgwarrior--resolve index id)) ids)))
    (vconcat (mapcar (lambda (tg) (plist-get tg :label)) (orgwarrior--refile-targets entries)))))

(defun orgwarrior--new-heading (place new)
  "Make a plain heading as NEW says (an alist: title, captured) as the
last child of PLACE (a target plist; a file's: at its top level), and
return it as a target.  Refused if one by that title is there already."
  (let-alist new
    (let ((title (string-trim (or .title "")))
          (buf (plist-get place :buffer))
          (pos (cdr (plist-get place :key))))
      (when (string-empty-p title) (user-error "The new heading needs a title"))
      (when (string-match-p "\n" title) (user-error "A heading has to be one line"))
      (orgwarrior--check-writable buf)
      (with-current-buffer buf
        (orgwarrior--check-event-title (car (split-string title)))
        (when (string-match-p "\\(?:\\`\\|[ \t]\\):[[:alnum:]_@#%:]+:\\'" title)
          (user-error "A title can't end in :word:, since org would read it as tags"))
        (org-with-wide-buffer
         (let ((level (if pos (progn (goto-char pos) (org-get-valid-level (org-current-level) 1)) 1))
               (title-key (orgwarrior--title-of title)))
           (if pos
               (save-excursion
                 (when (org-goto-first-child)
                   (cl-loop do (when (equal (orgwarrior--title) title-key)
                                 (user-error "%s already has %S" (plist-get place :label) title))
                            while (org-get-next-sibling))))
             (goto-char (point-min))
             (while (re-search-forward (format "^\\*\\{%d\\} " level) nil t)
               (when (equal (orgwarrior--title) title-key)
                 (user-error "%s already has %S" (plist-get place :label) title))))
           (if pos (progn (goto-char pos) (org-end-of-subtree t t)) (goto-char (point-max)))
           (orgwarrior--insert-entry (orgwarrior--render-add (list :title title) level .captured))
           (save-buffer)
           (forward-line -1)
           (org-back-to-heading t)
           ;; An empty [/] would stay in the outline path, so in its label.
           (org-update-statistics-cookies nil)
           (save-buffer)
           (orgwarrior--target (list title (buffer-file-name) nil (point)))))))))

(defun orgwarrior--refile-target-labels (ids)
  "The refile targets for the tasks IDS, as file › path labels, each one
a target `refile' takes as is.  Where all of them already are is left out."
  (let* ((index (orgwarrior--index))
         (entries (mapcar (lambda (id) (orgwarrior--resolve index id)) ids))
         (parents (mapcar #'orgwarrior--parent-key entries)))
    (vconcat
     (delq nil (mapcar (lambda (tg)
                         (unless (seq-every-p (lambda (p) (equal p (plist-get tg :key))) parents)
                           (plist-get tg :label)))
                       (orgwarrior--refile-targets entries))))))

(defun orgwarrior--parent-key (entry)
  "(BUFFER . POS) of ENTRY's parent heading, POS nil at top level."
  (orgwarrior--at entry
    (cons (current-buffer) (save-excursion (and (org-up-heading-safe) (point))))))

(defun orgwarrior--match-target (targets query parents)
  "The one target in TARGETS that QUERY names: an exact file › path
label (as `orgwarrior--refile-target-labels' gives them), an exact heading
name, then part of a name, then part of the label.  Ties
go to a target in the file QUERY names, then to one that isn't where
all the tasks already are (PARENTS, their `orgwarrior--parent-key's)."
  (let* ((q (downcase (string-trim query)))
         (list-them (lambda (ts) (mapconcat (lambda (tg) (concat "  " (plist-get tg :label)))
                                            ts "\n")))
         (matches
          (seq-some (lambda (pred) (seq-filter pred targets))
                    (list (lambda (tg) (equal (downcase (plist-get tg :label)) q))
                          ;; todo.org: gtd/todo.org's top level, a setup in a folder.
                          (lambda (tg) (and (null (cdr (plist-get tg :key)))
                                            (equal (downcase (file-name-nondirectory (plist-get tg :label))) q)))
                          (lambda (tg) (equal (downcase (plist-get tg :name)) q))
                          (lambda (tg) (string-search q (downcase (plist-get tg :name))))
                          (lambda (tg) (string-search q (downcase (plist-get tg :label)))))))
         (narrow (lambda (pred)
                   (when (cdr matches)
                     (setq matches (or (seq-filter pred matches) matches))))))
    (funcall narrow (lambda (tg) (equal (downcase (plist-get tg :file)) q)))
    ;; `tasks': the Tasks heading, not tasks.org's top level, named "tasks.org".
    (funcall narrow (lambda (tg) (cdr (plist-get tg :key))))
    (funcall narrow (lambda (tg) (seq-some (lambda (p) (not (equal p (plist-get tg :key))))
                                           parents)))
    (cond
     ((null targets) (user-error "There are no refile targets. Set org-refile-targets in your init file"))
     ((string-empty-p q) (user-error "refile needs a target:\n%s" (funcall list-them targets)))
     ((null matches) (user-error "No refile target matches %S. The targets are:\n%s" query (funcall list-them targets)))
     ((cdr matches) (user-error "%S matches several refile targets:\n%s"
                                query (funcall list-them matches)))
     (t (car matches)))))

(defun orgwarrior--refile (ids args note &optional new)
  "Refile the tasks IDS under the target ARGS names, with org's own
`org-refile'.  Their IDs change (the file is part of the hash), so
each result carries the old ID too.  Tasks already under the target
stay put, reported with :already.  NEW, an alist (title, captured),
makes a plain heading titled so first, as the last child of the place
ARGS names (one of the refile targets), and refiles into it."
  (when note (user-error "refile doesn't take a note"))
  (let* ((index (orgwarrior--index))
         (entries (orgwarrior--entries index ids))
         (target (orgwarrior--match-target (orgwarrior--refile-targets entries)
                                           (string-join args " ")
                                           (mapcar #'orgwarrior--parent-key entries)))
         (target (if new (orgwarrior--new-heading target new) target))
         (already (seq-filter (lambda (e) (equal (orgwarrior--parent-key e) (plist-get target :key)))
                              entries))
         (entries (seq-remove (lambda (e) (memq e already)) entries))
         (buffers (delete-dups (cons (plist-get target :buffer)
                                     (mapcar #'orgwarrior-entry-buffer entries))))
         (rfloc (copy-sequence (plist-get target :rfloc)))
         (moved nil)
         (markers nil)
         (parents nil))
    (mapc #'orgwarrior--check-writable buffers)
    ;; Positions shift as entries leave or land in the same buffer.
    (when (nth 3 rfloc)
      (with-current-buffer (plist-get target :buffer)
        (push (setf (nth 3 rfloc) (copy-marker (nth 3 rfloc))) markers)))
    (dolist (e entries)
      (with-current-buffer (orgwarrior-entry-buffer e)
        (push (setf (orgwarrior-entry-pos e) (copy-marker (orgwarrior-entry-pos e))) markers)))
    (unwind-protect
        (progn
          (dolist (e entries)
            (orgwarrior--at e
              (let ((old (orgwarrior--id index (orgwarrior-entry-hash e)))
                    (title (orgwarrior--title))
                    at)
                (push (orgwarrior--parent-marker) parents)
                ;; Instead of the user's hook, which may save every org buffer, edits in
                ;; progress included: where it landed (point, there), since a twin
                ;; can't be found by its title.
                (let ((org-after-refile-insert-hook (list (lambda () (setq at (point-marker))))))
                  (org-refile nil nil rfloc))
                (push (list :old old :title title :at at) moved)
                (orgwarrior--flush-log nil))))
          ;; org-refile leaves a [/] cookie on the target as it was.
          (when-let* ((pos (nth 3 rfloc)))
            (with-current-buffer (plist-get target :buffer)
              (org-with-wide-buffer
               (goto-char pos)
               (org-update-statistics-cookies nil))))
          (orgwarrior--update-cookies parents))
      (orgwarrior--save buffers)
      (dolist (m markers) (set-marker m nil)))
    (let ((index (orgwarrior--index)))
      (vconcat
       (mapcar (lambda (e)
                 (orgwarrior--at e
                   (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash e))
                                       :already (plist-get target :label))))
               already)
       (mapcar
        (lambda (m)
          (let ((at (plist-get m :at)))
            (append
             (list :old (plist-get m :old) :target (plist-get target :label))
             (if at
                 (with-current-buffer (marker-buffer at)
                   (org-with-wide-buffer
                    (goto-char at)
                    (set-marker at nil)
                    (append (list :id (or (orgwarrior--id index (orgwarrior--hash-at-point)) :null)
                                  :heading (orgwarrior--heading-line))
                            (orgwarrior--keyword-props))))
               (list :id :null :heading (plist-get m :title))))))
        (nreverse moved))))))


;;;; Cookies

(defun orgwarrior--parent-marker ()
  "A marker on the parent of the heading at point, or nil at the top level."
  (save-excursion (and (org-up-heading-safe) (point-marker))))

(defun orgwarrior--update-cookies (markers)
  "Recount the [/] cookies of the headings at MARKERS (nils skipped), as
C-c # does, then free the markers.  Org leaves a parent's cookie stale
when a child leaves or arrives."
  (dolist (m (delq nil markers))
    (when (marker-buffer m)
      (with-current-buffer (marker-buffer m)
        (org-with-wide-buffer
         (goto-char m)
         (when (org-at-heading-p) (org-update-statistics-cookies nil)))))
    (set-marker m nil)))


;;;; Rename

(defconst orgwarrior--trailing-tags-re "\\(?:\\`\\|[ \t]\\):[[:alnum:]_@#%:]+:\\'"
  "A title's end that org reads as its tags.")

(defun orgwarrior--rename (ids args note)
  "Give the one task in IDS the title ARGS, as `org-edit-headline' does:
keyword, priority and tags stay, and so do statistics cookies.  The ID
changes with the title, so the result carries the old one too."
  (when note (user-error "rename doesn't take a note"))
  (when (cdr ids) (user-error "rename works on one task at a time"))
  (let* ((title (string-trim (replace-regexp-in-string "[ \t\n]+" " " (string-join args " "))))
         (index (orgwarrior--index))
         (entry (orgwarrior--resolve index (car ids)))
         (old (orgwarrior--id index (orgwarrior-entry-hash entry))))
    (when (string-empty-p title) (user-error "rename needs the new title"))
    (orgwarrior--check-writable (orgwarrior-entry-buffer entry))
    (orgwarrior--at entry
      ;; Org would read these as a keyword or tags, not as part of the title.
      (when (member (car (split-string title)) org-todo-keywords-1)
        (user-error "A title can't start with %s, since org would read it as the keyword. Set the keyword with its own command"
                    (car (split-string title))))
      (when (string-match-p orgwarrior--trailing-tags-re title)
        (user-error "A title can't end in :word:, since org would read it as tags. Add tags with +tag"))
      (let ((cookies (let ((heading (org-get-heading t t t t)) (start 0) found)
                       (while (string-match orgwarrior--cookie-re heading start)
                         (push (match-string 0 heading) found)
                         (setq start (match-end 0)))
                       (nreverse found))))
        (org-edit-headline
         (if (or (null cookies) (string-match-p orgwarrior--cookie-re title))
             title
           (concat title " " (string-join cookies " ")))))
      (save-buffer)
      (org-back-to-heading t)
      (vector (append (list :old old)
                      (orgwarrior--result (orgwarrior--id (orgwarrior--index) (orgwarrior--hash-at-point))))))))


;;;; Kill

(defun orgwarrior--kill (ids args note)
  "Delete the tasks IDS, each with its whole subtree.  No undo: the CLI
confirms first.  An ID inside another ID's subtree goes with it."
  (when (or args note) (user-error "kill takes nothing after it"))
  (let* ((index (orgwarrior--index))
         (entries (orgwarrior--entries index ids))
         (buffers (delete-dups (mapcar #'orgwarrior-entry-buffer entries)))
         (killed nil))
    (mapc #'orgwarrior--check-writable buffers)
    (let* ((ranges (mapcar (lambda (e)
                             (orgwarrior--at e
                               (list e (point)
                                     (save-excursion (org-end-of-subtree t t) (point))
                                     (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash e))))))
                           entries))
           (outer (orgwarrior--outermost ranges))
           ;; Deleting one region shifts the ones after it.
           (regions (mapcar (lambda (r)
                              (with-current-buffer (orgwarrior-entry-buffer (car r))
                                (list (current-buffer) (copy-marker (nth 1 r))
                                      (copy-marker (nth 2 r)))))
                            outer))
           (parents (mapcar (lambda (r) (orgwarrior--at (car r) (orgwarrior--parent-marker))) outer)))
      (setq killed (mapcar #'cadddr ranges))
      (unwind-protect
          (dolist (r regions)
            (with-current-buffer (nth 0 r)
              (org-with-wide-buffer
               (delete-region (nth 1 r) (nth 2 r))
               ;; The last entry: don't leave the blank line that preceded it.
               (when (= (point-max) (marker-position (nth 1 r)))
                 (goto-char (point-max))
                 (skip-chars-backward " \t\n")
                 (delete-region (point) (point-max))
                 (unless (bobp) (insert "\n")))))
            (orgwarrior--update-cookies parents))
        (orgwarrior--save buffers)
        (dolist (r regions)
          (set-marker (nth 1 r) nil)
          (set-marker (nth 2 r) nil))))
    (vconcat killed)))


;;;; Archive

(defun orgwarrior--archive (ids args note)
  "Archive the tasks IDS with `org-archive-subtree', to wherever
`org-archive-location' (or an ARCHIVE property) says.  An ID inside
another ID's subtree goes with it."
  (when (or args note) (user-error "archive takes nothing after it"))
  (require 'org-archive)
  (let* ((index (orgwarrior--index))
         (entries (orgwarrior--entries index ids))
         (ranges (mapcar (lambda (e)
                           (orgwarrior--at e
                             (list e (point)
                                   (save-excursion (org-end-of-subtree t t) (point))
                                   (orgwarrior--result (orgwarrior--id index (orgwarrior-entry-hash e)))
                                   (orgwarrior--archive-file))))
                         entries))
         (outer (orgwarrior--outermost ranges))
         (files (delete-dups (mapcar (lambda (r) (nth 4 r)) ranges)))
         (sources (delete-dups (mapcar #'orgwarrior-entry-buffer entries)))
         (markers nil)
         (parents nil))
    (mapc #'orgwarrior--check-writable
          (append sources (delq nil (mapcar #'get-file-buffer files))))
    ;; Positions shift as earlier entries in the same buffer leave.
    (dolist (r outer)
      (with-current-buffer (orgwarrior-entry-buffer (car r))
        (push (setf (orgwarrior-entry-pos (car r)) (copy-marker (nth 1 r))) markers)))
    (unwind-protect
        (progn
          (dolist (r outer)
            (orgwarrior--at (car r)
              (push (orgwarrior--parent-marker) parents)
              (org-archive-subtree)))
          (orgwarrior--update-cookies parents))
      ;; org opens an archive file that had no buffer, so look again.
      (orgwarrior--save (append sources (delq nil (mapcar #'get-file-buffer files))))
      (dolist (m markers) (set-marker m nil)))
    (vconcat (mapcar (lambda (r)
                       (append (nth 3 r)
                               (list :target (file-name-nondirectory (nth 4 r)))))
                     ranges))))

(defun orgwarrior--archive-file ()
  "The file `org-archive-subtree' would move the entry at point to."
  (let ((file (car (org-archive--compute-location
                    (or (org-entry-get nil "ARCHIVE" 'inherit) org-archive-location)))))
    (if (string-empty-p file) (buffer-file-name (buffer-base-buffer)) file)))

(defun orgwarrior--outermost (ranges)
  "RANGES, each (ENTRY START END ...), minus those inside another's subtree."
  (seq-remove
   (lambda (r)
     (seq-some (lambda (o) (and (not (eq o r))
                                (eq (orgwarrior-entry-buffer (car o))
                                    (orgwarrior-entry-buffer (car r)))
                                (< (nth 1 o) (nth 1 r) (nth 2 o))))
               ranges))
   ranges))


;;;; Edit

(defun orgwarrior--edit (id)
  "Make an indirect buffer narrowed to task ID's subtree and return its
name, for `orgwarrior-edit-frame' to show.  Indirect, so the narrowing stays
out of the file's own buffer, which other frames on the daemon may show;
the edits land in that buffer all the same."
  (let* ((entry (orgwarrior--resolve (orgwarrior--index) id))
         (base (orgwarrior-entry-buffer entry)))
    (orgwarrior--check-writable base)
    (orgwarrior--at entry
      (let ((pos (point))
            (buf (make-indirect-buffer
                  base (generate-new-buffer-name (format "%s [orgwarrior]" (orgwarrior--title))) t)))
        (with-current-buffer buf
          (goto-char pos)
          (org-narrow-to-subtree)
          (org-fold-show-subtree)
          (setq header-line-format " C-x C-s saves, C-x C-c closes"))
        (list :buffer (buffer-name buf))))))

(defun orgwarrior-edit-frame (buffer)
  "Show BUFFER from `orgwarrior--edit' in the selected frame, the one
`emacsclient -t' just made, and kill BUFFER when that frame closes."
  (switch-to-buffer buffer)
  (delete-other-windows)
  (set-frame-parameter nil 'orgwarrior-edit buffer)
  (add-hook 'delete-frame-functions #'orgwarrior--edit-frame-closed)
  nil)

(defvar orgwarrior--edit-discarded nil
  "Edit buffers whose frame closed with changes unsaved.
For `orgwarrior--edit-done'.")

(defun orgwarrior--edit-frame-closed (frame)
  "Kill FRAME's edit buffer.  Unsaved changes to its file are discarded,
as when quitting an editor without saving, rather than left to block
orgwarrior.  `orgwarrior--edit' refused a modified file, so they're all
from this edit."
  (when-let* ((name (frame-parameter frame 'orgwarrior-edit))
              (buf (get-buffer name)))
    (let ((base (buffer-base-buffer buf)))
      (kill-buffer buf)
      (when (and base (buffer-modified-p base))
        (with-current-buffer base (revert-buffer t t t))
        (push name orgwarrior--edit-discarded)))))

(defun orgwarrior--edit-done (buffer)
  (let ((discarded (member buffer orgwarrior--edit-discarded)))
    (setq orgwarrior--edit-discarded (delete buffer orgwarrior--edit-discarded))
    (list :discarded (if discarded t :false))))


;;;; Add

(defun orgwarrior--add-buffer (file)
  "The buffer to add to FILE (default `org-default-notes-file')."
  (let ((path (expand-file-name (or file org-default-notes-file))))
    (cond ((file-exists-p path) (orgwarrior--file-buffer path))
          (file (user-error "There's no file to add to: %s doesn't exist. Create it, or set another file in [add] in orgwarrior's config"
                            (abbreviate-file-name path)))
          ;; Org's own default, ~/.notes: nobody set it, so say how.  Set, it only needs making.
          ((equal (file-name-nondirectory path) ".notes")
           (user-error "There's no file to add to: %s (Emacs's org-default-notes-file) doesn't exist. \
Point it at your inbox in your init file, (setq org-default-notes-file \"~/org/inbox.org\"), \
or set [add] file in orgwarrior's config.toml, file = \"~/org/inbox.org\". Then create that file" (abbreviate-file-name path)))
          (t (user-error "There's no file to add to: %s (Emacs's org-default-notes-file) doesn't exist yet. Create it; it can be empty"
                         (abbreviate-file-name path))))))

(defun orgwarrior--add-place (file heading)
  "Where FILE and HEADING (as `orgwarrior--add' takes them) add to, as a
target plist."
  (let ((buf (orgwarrior--add-buffer file)))
    (with-current-buffer buf
      (orgwarrior--target
       (list nil (buffer-file-name) nil
             (and heading (or (org-with-wide-buffer (org-find-exact-headline-in-buffer heading nil t))
                              (user-error "There's no heading %S in %s" heading (buffer-file-name)))))))))

(defun orgwarrior--add-places (file heading)
  "Where an add can go instead (its TO): where FILE and HEADING say,
then the refile targets as seen from that file, each file's top level
included."
  (let ((default (orgwarrior--add-place file heading)))
    (cons default (seq-remove (lambda (tg) (equal (plist-get tg :key) (plist-get default :key)))
                              (orgwarrior--refile-targets (list (plist-get default :buffer)))))))

(defun orgwarrior--add-place-labels (file heading)
  "The places an add can go (`orgwarrior--add-places'), each a label and
its file's key, and the open keywords of those files and the agenda
files: a form offers the ones of the file it adds to."
  (let* ((places (orgwarrior--add-places file heading))
         (buffers (delete-dups (append (mapcar (lambda (tg) (plist-get tg :buffer)) places)
                                       (mapcar #'orgwarrior--file-buffer (orgwarrior--agenda-files))))))
    (list :places (vconcat (mapcar (lambda (tg)
                                     (list :label (plist-get tg :label)
                                           :file (orgwarrior--file-key
                                                  (buffer-file-name (plist-get tg :buffer)))))
                                   places))
          :keywords (vconcat (mapcar (lambda (buf)
                                       (with-current-buffer buf
                                         (list :file (orgwarrior--file-key (buffer-file-name))
                                               :open (vconcat org-not-done-keywords))))
                                     buffers)))))

(defun orgwarrior--add (text file heading captured &optional fields event to under)
  "Append a task parsed from TEXT to FILE (default `org-default-notes-file').
Under the heading titled HEADING as its last child, else at the end of
the file as a top-level entry.  TO instead names a place as refile
names a target (`orgwarrior--add-places'), UNDER a heading by its ID.
CAPTURED non-nil adds a :CAPTURED: property.  FIELDS, an alist from a
form, replaces TEXT: see `orgwarrior--add-fields'.  EVENT non-nil adds
an event instead: no keyword, a plain timestamp (@DATE in TEXT, `when'
in FIELDS)."
  (let* ((place (cond
                 (under (let ((e (orgwarrior--resolve (orgwarrior--index) under)))
                          (cons (orgwarrior-entry-buffer e) (orgwarrior-entry-pos e))))
                 ;; Any agenda file by name, refile target or not: a file's view adds to it.
                 (to (if-let* ((f (ignore-errors (orgwarrior--agenda-file to))))
                         (cons (orgwarrior--file-buffer f) nil)
                       (plist-get (orgwarrior--match-target (orgwarrior--add-places file heading) to nil)
                                  :key)))
                 (t (let ((tg (orgwarrior--add-place file heading)))
                      (plist-get tg :key)))))
         (buf (car place)))
    (orgwarrior--check-writable buf)
    (with-current-buffer buf
      (let ((entry (if fields (orgwarrior--add-fields fields event) (orgwarrior--parse-add text event)))
            (level 1))
        (org-with-wide-buffer
         (if (not (cdr place))
             (goto-char (point-max))
           (goto-char (cdr place))
           (setq level (org-get-valid-level (org-current-level) 1))
           (org-end-of-subtree t t))
         ;; Headings in the body: the new entry's children.
         (pcase-let ((`(,body . ,outline) (orgwarrior--split-outline (plist-get entry :body)))
                     (added 0))
           (setq entry (plist-put entry :body (and (plist-get entry :body) body)))
           ;; Rendered first: it refuses a bad body, and then nothing has changed.
           (orgwarrior--insert-entry (orgwarrior--render-add entry level captured))
           (let ((new (save-excursion (forward-line -1) (org-back-to-heading t) (point-marker))))
             (when outline
               (setq added (orgwarrior--add-outline outline (1+ level))))
             (goto-char new)
             (set-marker new nil))
           (orgwarrior--update-cookies (list (point-marker) (orgwarrior--parent-marker)))
           (save-buffer)
           ;; Null when FILE isn't an agenda file: no ID would resolve.
           (append (orgwarrior--result (or (orgwarrior--id (orgwarrior--index) (orgwarrior--hash-at-point)) :null))
                   (list :new_children added))))))))

(defun orgwarrior--insert-entry (text)
  "Insert TEXT, an entry as `orgwarrior--render-add' gives it, at point,
the end of what it's added to: one blank line after what's before it."
  (let ((end (point)))
    (skip-chars-backward " \t\n")
    (delete-region (point) end)
    (insert (if (bobp) "" "\n\n") text))
  (unless (eobp) (insert "\n")))

(defun orgwarrior--date-word-p (word)
  "Non-nil if WORD continues a date in the add syntax: a time (with a
colon or am/pm, so a bare number stays in the title), a repeater or a
warning period."
  (or (and (string-match-p orgwarrior--time-re word) (string-match-p "[:apm]" word))
      (string-match-p orgwarrior--repeater-re word)
      (string-match-p orgwarrior--warning-re word)))

(defun orgwarrior--parse-add (text &optional event)
  "Parse TEXT's first line: optional leading keyword, `:tag:' groups and
`s:'/`d:' date tokens anywhere.  Times, repeaters and warnings right
after a date token belong to it (s:fri 14:00-15:00 +1w).  Uses the
current buffer's keywords, any case; without one, its first open
keyword.  For an EVENT: no keyword, and one `@' date,
required \(@fri 14:00-15:00).  The lines after the first are the body,
as typed."
  (let* ((newline (string-search "\n" text))
         (body (when newline (substring text (1+ newline))))
         (text (if newline (substring text 0 newline) text))
         words tags dates date (keyword (unless event (car org-not-done-keywords))))
    (dolist (token (split-string text))
      (cond
       ((and date (orgwarrior--date-word-p token))
        (setcdr date (concat (cdr date) " " token)))
       ((string-match-p "\\`\\(?::[[:alnum:]_@#%]+\\)+:\\'" token)
        (setq date nil)
        (dolist (tag (split-string token ":" t))
          (unless (member tag tags) (setq tags (append tags (list tag))))))
       ((string-match (if event "\\`\\(@\\)\\(.+\\)\\'" "\\`\\([sd]\\):\\(.+\\)\\'") token)
        (push (setq date (cons (match-string 1 token) (match-string 2 token))) dates))
       (t (setq date nil)
          (push token words))))
    (setq words (nreverse words))
    (when (and words (not event))
      (let ((first (orgwarrior--keyword-named (car words))))
        (cond
         ((member first org-done-keywords)
          (user-error "Can't add a task that's already %s" first))
         ((member first org-not-done-keywords)
          (setq keyword first words (cdr words))))))
    (unless words (user-error "The title is empty"))
    (when event (orgwarrior--check-event-title (car words)))
    (when (and event (not (assoc "@" dates)))
      (user-error "An event needs a date, like @fri or @2026-10-15 14:00"))
    (list :keyword keyword :title (string-join words " ") :tags tags :body body
          :when (orgwarrior--add-stamp (cdr (assoc "@" dates)))
          :scheduled (orgwarrior--add-stamp (cdr (assoc "s" dates)))
          :deadline (orgwarrior--add-stamp (cdr (assoc "d" dates))))))

(defun orgwarrior--check-title (title tags)
  "Refuse a TITLE from a form that org would read as more than a title: a
second line (a heading or drawer of its own), or trailing :word: with no
TAGS after it to be the tags instead."
  (when (string-match-p "[\n\r]" title)
    (user-error "A title has to be one line"))
  (when (and (seq-empty-p tags) (string-match-p orgwarrior--trailing-tags-re title))
    (user-error "A title can't end in :word:, since org would read it as tags. Give them as tags instead")))

(defun orgwarrior--check-event-title (first)
  "Refuse a title without a keyword whose FIRST word org would read as one."
  (when (member first org-todo-keywords-1)
    (user-error "A title without a keyword can't start with %s, since org would read it as one" first)))

(defun orgwarrior--add-stamp (string)
  "The timestamp for STRING, a date with optional cookies, or nil."
  (when string
    (pcase-let ((`(,date . ,cookies) (orgwarrior--read-timestamp string)))
      (orgwarrior--stamp date cookies))))

(defun orgwarrior--add-fields (fields &optional event)
  "The entry FIELDS describe: keyword, priority, title, tags, scheduled,
deadline and effort (checked as the effort verb checks it), as a form
gives them; for an EVENT title, tags and when; body and properties (name
to value, for the drawer) for both.  Nothing in the title is read as
syntax.  A done keyword adds a finished task (an import): CLOSED when
closed says, a date not later than now, else now where `org-log-done'
would stamp one."
  (let-alist fields
    (let ((keyword (cond (event nil)
                         ;; None, as org's C-c C-t SPC leaves it: a plain heading.
                         ((equal .keyword "") nil)
                         (.keyword (or (orgwarrior--keyword-named .keyword) .keyword))
                         (t (car org-not-done-keywords))))
          (title (string-trim (or .title ""))))
      (cond
       (event
        (when (or .keyword .scheduled .deadline .closed)
          (user-error "An event only has a date (when), not a keyword, scheduled, deadline or closed"))
        (unless .when (user-error "An event needs a date")))
       ((and .closed (not (member keyword org-done-keywords)))
        (user-error "Closed needs a done keyword: %s" (string-join org-done-keywords " ")))
       ((member keyword org-done-keywords))
       ((null keyword) (orgwarrior--check-event-title (car (split-string title))))
       ((not (member keyword org-not-done-keywords))
        (user-error "%s isn't a TODO keyword" keyword))
       (.when (user-error "A task has scheduled and deadline dates, not when (that's for events)")))
      (when (string-empty-p title) (user-error "The title is empty"))
      (orgwarrior--check-title title .tags)
      (when event (orgwarrior--check-event-title (car (split-string title))))
      (when (and .priority (not (member (upcase .priority) (orgwarrior--priorities))))
        (user-error "Priority has to be one of %s" (string-join (orgwarrior--priorities) " ")))
      (dolist (tag .tags)
        (unless (string-match-p "\\`[[:alnum:]_@#%]+\\'" tag)
          (user-error "%s can't be a tag" tag)))
      (pcase-dolist (`(,name . ,value) .properties)
        (unless (string-match-p "\\`[[:alnum:]_-]+\\'" (symbol-name name))
          (user-error "%s can't be a property name" name))
        (unless (and (stringp value) (not (string-match-p "\n" value)))
          (user-error "A property's value has to be one line: %s" name)))
      (when (and .effort event) (user-error "An event can't have an effort"))
      (when .effort (orgwarrior--check-effort .effort))
      (list :keyword keyword :priority (and .priority (upcase .priority))
            :title title :tags (delete-dups (copy-sequence .tags))
            :body .body
            :properties (append (mapcar (lambda (p) (cons (upcase (symbol-name (car p))) (cdr p))) .properties)
                                (and .effort (list (cons org-effort-property .effort))))
            :when (orgwarrior--add-stamp .when)
            :scheduled (orgwarrior--add-stamp .scheduled)
            :deadline (orgwarrior--add-stamp .deadline)
            :closed (orgwarrior--closed-stamp keyword .closed)))))

(defun orgwarrior--closed-stamp (keyword closed)
  "The CLOSED timestamp for a task added in KEYWORD: CLOSED's date (with
its time if it has one), now if it's nil and `org-log-done' is set, as
`org-todo' stamps it; nil for an open keyword."
  (when (member keyword org-done-keywords)
    (if closed
        (let ((date (orgwarrior--read-date closed)))
          (when (time-less-p nil (nth 1 date))
            (user-error "The closed time %s is later than now" closed))
          (format-time-string (org-time-stamp-format (nth 2 date) t) (nth 1 date)))
      (and org-log-done (format-time-string (org-time-stamp-format t t))))))

(defun orgwarrior--render-add (entry level captured)
  (let ((planning nil))
    (when-let* ((stamp (plist-get entry :closed)))
      (push (concat "CLOSED: " stamp) planning))
    (when-let* ((stamp (plist-get entry :scheduled)))
      (push (concat "SCHEDULED: " stamp) planning))
    (when-let* ((stamp (plist-get entry :deadline)))
      (push (concat "DEADLINE: " stamp) planning))
    (concat (make-string level ?*) " "
            (when-let* ((kw (plist-get entry :keyword))) (concat kw " "))
            (when-let* ((p (plist-get entry :priority))) (format "[#%s] " p))
            (plist-get entry :title)
            (when-let* ((tags (plist-get entry :tags)))
              (concat " :" (string-join tags ":") ":"))
            "\n"
            (when-let* ((text (orgwarrior--entry-text
                               (concat
                                (when planning (concat (string-join (nreverse planning) " ") "\n"))
                                (when (or captured (plist-get entry :properties))
                                  (concat ":PROPERTIES:\n"
                                          (when captured
                                            (concat ":CAPTURED: " (format-time-string (org-time-stamp-format t t)) "\n"))
                                          (mapconcat (lambda (p) (format ":%s: %s\n" (car p) (cdr p)))
                                                     (plist-get entry :properties) "")
                                          ":END:\n"))
                                ;; After the drawer: org only finds one right below the heading.
                                (when-let* ((stamp (plist-get entry :when))) (concat stamp "\n"))
                                (plist-get entry :body)))))
              (concat text "\n")))))

(provide 'orgwarrior)
;;; orgwarrior.el ends here
