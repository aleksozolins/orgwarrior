;;; fixture-init.el --- A small org setup for testing orgwarrior  -*- lexical-binding: t; -*-

;; Shaped like a real GTD config (keywords, logging, dashboards) but
;; pointed at copies of tests/fixtures/org.  Used by the ERT tests, the
;; pytest integration test and scripts/dev-daemon.  Loaded with
;; ORGWARRIOR_FIXTURE_DEST set, it sets itself up in that directory.
;; A sandbox: it writes org files only there (orgwarrior-fixture--guard).

(require 'org)
(require 'org-agenda)
(require 'org-habit)  ; a habit's graph, as most org setups have it

;; Org writes weekday names in the system's language; the tests expect English.
(setq system-time-locale "C")

(defconst orgwarrior-fixture-source
  (expand-file-name "fixtures/org" (file-name-directory (or load-file-name buffer-file-name))))

(defun orgwarrior-fixture--expand-dates (text)
  "Replace {{+N}} in TEXT with the org date N days from today."
  (replace-regexp-in-string
   "{{\\([+-][0-9]+\\)}}"
   (lambda (m)
     (format-time-string
      "%Y-%m-%d %a"
      (time-add (current-time)
                (days-to-time (string-to-number (match-string 1 m))))))
   text t t))

(defvar orgwarrior-fixture-dir nil
  "The fixture copy: the one place this Emacs writes org files.")

;; Whatever talks to this daemon (a dev script, a test, a Python shell with
;; the real config, whose [add] file is ~/org/inbox.org), an org file outside
;; the copy is an error, never a write: real files stay untouched.
(defun orgwarrior-fixture--guard (_start _end filename &rest _)
  (when (and orgwarrior-fixture-dir (stringp filename)
             (string-match-p "\\.org\\(?:_archive\\)?\\'" filename)
             (not (string-prefix-p (file-name-as-directory (file-truename orgwarrior-fixture-dir))
                                   (file-truename filename))))
    (error "Sandbox: won't write %s, outside %s (a dev daemon writes only its copy)"
           (abbreviate-file-name filename) (abbreviate-file-name orgwarrior-fixture-dir))))
(advice-add 'write-region :before #'orgwarrior-fixture--guard)

(defun orgwarrior-fixture-setup (dest)
  "Copy the fixture org files into DEST and point org at them."
  (make-directory dest t)
  (setq orgwarrior-fixture-dir dest)
  (dolist (src (directory-files orgwarrior-fixture-source t "\\.org\\'"))
    (with-temp-file (expand-file-name (file-name-nondirectory src) dest)
      (insert (orgwarrior-fixture--expand-dates
               (with-temp-buffer (insert-file-contents src) (buffer-string))))))
  (setq org-directory (file-name-as-directory dest)
        org-agenda-files (mapcar (lambda (f) (expand-file-name f dest))
                                 '("tasks.org" "projects.org" "calendar.org" "inbox.org"))
        org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "ACTIVE(a)" "WAIT(w@/!)"
                                      "|" "DONE(d@/!)" "SKIP(k@/!)"))
        org-log-done 'time
        org-log-into-drawer t
        org-log-reschedule 'time
        org-log-redeadline 'time
        org-agenda-start-on-weekday nil
        org-refile-targets `((nil :maxlevel . 1)
                             (,(expand-file-name "tasks.org" dest) :maxlevel . 1)
                             (,(expand-file-name "projects.org" dest) :maxlevel . 1))
        org-agenda-custom-commands
        '(("d" "Day Dashboard"
           ((agenda "" ((org-agenda-span 1)))
            (tags-todo "inbox")
            (todo "NEXT")))
          ("i" "Inbox" tags-todo "inbox")
          ("n" "Next" todo "NEXT")))
  dest)

;; A second setup, unlike the first: mixed-case keywords and no TODO, a file
;; with its own #+TODO, numeric priorities, logging in the body, not a drawer.
(defun orgwarrior-fixture-setup-alt (dest)
  "Copy the other fixture files into DEST and point org at them."
  (let ((orgwarrior-fixture-source (concat orgwarrior-fixture-source "-alt")))
    (orgwarrior-fixture-setup dest))
  (setq org-agenda-files (mapcar (lambda (f) (expand-file-name f dest))
                                 '("tasks.org" "bugs.org" "inbox.org"))
        org-todo-keywords '((sequence "TASK(t)" "Waiting(w@)" "|" "Done(d)" "Dropped(x@)"))
        org-log-into-drawer nil
        org-priority-highest 1
        org-priority-lowest 5
        org-priority-default 3
        org-agenda-custom-commands nil)
  dest)

;; Set but empty is unset: "" would set up in the current directory.
(when-let* ((dest (getenv "ORGWARRIOR_FIXTURE_DEST")) ((not (string-empty-p dest))))
  (orgwarrior-fixture-setup dest))

;;; fixture-init.el ends here
