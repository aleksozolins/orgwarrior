;;; orgwarrior-alt-test.el --- ERT tests for orgwarrior.el, another setup  -*- lexical-binding: t; -*-

;; Run: emacs -Q --batch -l tests/orgwarrior-alt-test.el -f ert-run-tests-batch-and-exit
;; An org setup unlike the main fixtures' (see `orgwarrior-fixture-setup-alt'), in an
;; Emacs of its own: the setup is global, so it can't share one with
;; orgwarrior-test.el.

(require 'ert)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "orgwarrior-test.el" here) nil t))

;; The other suite's tests run against the first setup only.
(ert-delete-all-tests)

(defmacro orgwarrior-alt-with-fixtures (&rest body)
  "Run BODY against a fresh copy of the other fixtures, with `dir' bound to it."
  (declare (indent 0))
  `(orgwarrior-test-with-fixtures
     (orgwarrior-fixture-setup-alt dir)
     ,@body))

(defun orgwarrior-alt-line (dir file title)
  "The heading line in FILE of DIR whose title is TITLE."
  (let ((text (orgwarrior-test-file dir file)))
    (and (string-match (concat "^\\*+ .*" (regexp-quote title) ".*$") text)
         (match-string 0 text))))

;;;; Adding: the target file's own first keyword

(ert-deftest orgwarrior-alt-add-default-keyword ()
  (orgwarrior-alt-with-fixtures
    (orgwarrior-test-add dir "Buy stamps" :heading "Inbox")
    (should (equal (orgwarrior-alt-line dir "inbox.org" "Buy stamps") "** TASK Buy stamps"))
    (orgwarrior-test-ok :op "add" :fields '((title . "Water the lawn")) :heading "Inbox"
                        :file (expand-file-name "inbox.org" dir))
    (should (equal (orgwarrior-alt-line dir "inbox.org" "Water the lawn") "** TASK Water the lawn"))
    ;; A file with its own #+TODO: its first keyword.
    (orgwarrior-test-ok :op "add" :text "Crash on quit" :heading "Bugs"
                        :file (expand-file-name "bugs.org" dir))
    (should (equal (orgwarrior-alt-line dir "bugs.org" "Crash on quit") "** BUG Crash on quit"))))

(ert-deftest orgwarrior-alt-add-keyword-any-case ()
  (orgwarrior-alt-with-fixtures
    (orgwarrior-test-add dir "waiting Call the bank" :heading "Inbox")
    (should (equal (orgwarrior-alt-line dir "inbox.org" "Call the bank") "** Waiting Call the bank"))
    (orgwarrior-test-ok :op "add" :fields '((title . "Fix the gate") (keyword . "WAITING"))
                        :heading "Inbox" :file (expand-file-name "inbox.org" dir))
    (should (equal (orgwarrior-alt-line dir "inbox.org" "Fix the gate") "** Waiting Fix the gate"))
    (should (string-match-p "already Done"
                            (orgwarrior-test-error :op "add" :text "done Old thing" :heading "Inbox"
                                                   :file (expand-file-name "inbox.org" dir))))))

;;;; Changing state: any case, spelled as the file has it

(ert-deftest orgwarrior-alt-verbs-any-case ()
  (orgwarrior-alt-with-fixtures
    (let ((id (orgwarrior-test-id "Water the plants")))
      (should (eq t (orgwarrior-test-ok :op "wants-note" :ids (vector id) :verb "waiting")))
      (should (eq :false (orgwarrior-test-ok :op "wants-note" :ids (vector id) :verb "done")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "waiting" :args [] :note "Asked Sam")
      (should (equal (orgwarrior-alt-line dir "tasks.org" "Water the plants") "** Waiting Water the plants")))
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Water the plants")) :verb "DONE" :args [])
    (should (equal (orgwarrior-alt-line dir "tasks.org" "Water the plants") "** Done Water the plants"))))

(ert-deftest orgwarrior-alt-per-file-keywords ()
  (orgwarrior-alt-with-fixtures
    (let* ((id (orgwarrior-test-id "Crash on save"))
           (show (orgwarrior-test-ok :op "show" :id id)))
      (should (equal (plist-get show :keywords) '("BUG" "FIXING" "FIXED" "WONTFIX")))
      (should (equal (plist-get show :done_keywords) '("FIXED" "WONTFIX")))
      (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Water the plants"))
                                :keywords)
                     '("TASK" "Waiting" "Done" "Dropped")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "fixed" :args [])
      (should (equal (orgwarrior-alt-line dir "bugs.org" "Crash on save") "** FIXED Crash on save"))
      ;; Another file's keyword isn't this one's.
      (should (string-match-p "Unknown verb"
                              (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Slow startup"))
                                                     :verb "waiting" :args []))))
    (should (equal (plist-get (orgwarrior-test-ok :op "keywords" :file (expand-file-name "bugs.org" dir))
                              :keywords)
                   '("BUG" "FIXING" "FIXED" "WONTFIX")))
    (should (equal (plist-get (orgwarrior-test-ok :op "keywords") :keywords)
                   '("TASK" "Waiting" "Done" "Dropped")))))

(ert-deftest orgwarrior-alt-keyword-views ()
  (orgwarrior-alt-with-fixtures
    ;; A view by keyword: any case, a file's own #+TODO keywords too.
    (let ((titles (lambda (arg)
                    (mapconcat (lambda (l) (plist-get l :text))
                               (orgwarrior-test-ok :op "view" :kind "words" :arg arg) "\n"))))
      (should (string-match-p "Hear back from the landlord" (funcall titles "waiting")))
      (should-not (string-match-p "Water the plants" (funcall titles "waiting")))
      (should (string-match-p "Crash on save" (funcall titles "bug")))
      (should-not (string-match-p "Slow startup" (funcall titles "bug"))))))

;;;; Notes and priorities

(ert-deftest orgwarrior-alt-notes-without-drawer ()
  (orgwarrior-alt-with-fixtures
    (let ((id (orgwarrior-test-id "Water the plants")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "waiting" :args [] :note "Asked Sam")
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "note" :args ["Sam" "said" "Friday"])
      (should-not (string-match-p ":LOGBOOK:" (orgwarrior-test-file dir "tasks.org")))
      (let ((notes (plist-get (orgwarrior-test-ok :op "show" :id id) :notes)))
        (should (equal (mapcar (lambda (n) (plist-get n :text)) notes) '("Sam said Friday" "Asked Sam")))
        (should (equal (plist-get (cadr notes) :state) "Waiting"))))))

(ert-deftest orgwarrior-alt-numeric-priorities ()
  (orgwarrior-alt-with-fixtures
    (let ((id (orgwarrior-test-id "Water the plants")))
      (should (equal (plist-get (orgwarrior-test-ok :op "keywords") :priorities) '("1" "2" "3" "4" "5")))
      (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Renew passport"))
                                :priority)
                     "2"))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["1"])
      (should (equal (orgwarrior-alt-line dir "tasks.org" "Water the plants") "** TASK [#1] Water the plants"))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["none"])
      (should (equal (orgwarrior-alt-line dir "tasks.org" "Water the plants") "** TASK Water the plants")))))

;;; orgwarrior-alt-test.el ends here
