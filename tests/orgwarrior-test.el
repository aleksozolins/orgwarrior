;;; orgwarrior-test.el --- ERT tests for orgwarrior.el  -*- lexical-binding: t; -*-

;; Run: emacs -Q --batch -l tests/orgwarrior-test.el -f ert-run-tests-batch-and-exit
;; Real org, real files: each test gets a fresh copy of the fixtures.

(require 'ert)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "fixture-init.el" here) nil t)
  (load (expand-file-name "../src/orgwarrior/orgwarrior.el" here) nil t))

(defmacro orgwarrior-test-with-fixtures (&rest body)
  "Run BODY against a fresh fixture copy, with `dir' bound to it."
  (declare (indent 0))
  `(let ((dir (make-temp-file "orgwarrior-test" t)))
     (unwind-protect
         (progn
           (orgwarrior-fixture-setup dir)
           ,@body)
       ;; Else killing its buffer asks whether to clock out first.
       (when (org-clocking-p) (orgwarrior--forget-clock))
       (dolist (buf (buffer-list))
         (when (and (buffer-file-name buf)
                    (string-prefix-p (file-truename dir) (file-truename (buffer-file-name buf))))
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))

(defun orgwarrior-test-call (&rest request)
  "Call `orgwarrior-call' with REQUEST (a plist) and return the parsed reply."
  (json-parse-string (orgwarrior-call (json-serialize request))
                     :object-type 'plist :array-type 'list :null-object nil))

(defun orgwarrior-test-ok (&rest request)
  (let ((reply (apply #'orgwarrior-test-call request)))
    (should-not (plist-get reply :error))
    (plist-get reply :ok)))

(defun orgwarrior-test-error (&rest request)
  (let ((reply (apply #'orgwarrior-test-call request)))
    (should (plist-get reply :error))
    (plist-get reply :error)))

(defun orgwarrior-test-file (dir name)
  (with-temp-buffer
    (insert-file-contents (expand-file-name name dir))
    (buffer-string)))

(defun orgwarrior-test-fresh-minute ()
  "Wait for a new minute if this one is nearly over: a test clocking
relative to now (-30m, then out) expects whole minutes, and org's clock
lines count minutes, so a minute passing between two calls adds one."
  (let ((second (decoded-time-second (decode-time))))
    (when (>= second 50) (sleep-for (- 60.2 second)))))

(defun orgwarrior-test-id (title)
  "The displayed ID of the task titled TITLE, from the `all' view."
  (let ((line (seq-find (lambda (l) (string-match-p (regexp-quote title) (plist-get l :text)))
                        (orgwarrior-test-ok :op "view" :kind "all"))))
    (should line)
    (plist-get line :id)))


(defun orgwarrior-test-span-texts (line)
  "LINE's spans as (TEXT ROLE KEYWORD), TEXT what each covers."
  (let ((text (plist-get line :text)))
    (mapcar (lambda (s) (list (substring text (nth 0 s) (nth 1 s)) (nth 2 s) (nth 3 s)))
            (plist-get line :spans))))

(defun orgwarrior-test-orgw ()
  "The ID of projects.org's Orgwarrior heading: no keyword, so not in `all'."
  (plist-get (car (plist-get (orgwarrior-test-ok :op "outline" :file "projects.org") :children)) :id))


;;;; IDs

(ert-deftest orgwarrior-test-prefixes ()
  (let ((table (orgwarrior--prefixes '("abc123" "abd999" "ff0000" "ff0000"))))
    (should (equal (gethash "abc123" table) "abc"))
    (should (equal (gethash "abd999" table) "abd"))
    (should (equal (gethash "ff0000" table) "ff"))))

(ert-deftest orgwarrior-test-title-ignores-keyword-tags-cookies ()
  (with-temp-buffer
    (org-mode)
    (insert "* NEXT [#A] Pay rent [1/2] [50%]   :finances:\n")
    (goto-char (point-min))
    (should (equal (orgwarrior--title) "Pay rent"))))

(ert-deftest orgwarrior-test-title-squeezes-whitespace ()
  (should (equal (orgwarrior--title-of " Pay\t  rent [1/2] ") "Pay rent"))
  (should (equal (orgwarrior--title-of "Pay rent") "Pay rent")))

(ert-deftest orgwarrior-test-index-cache ()
  "The index is kept while the files are unchanged, and follows any change:
an edit in Emacs, a file rewritten on disk (Syncthing)."
  (orgwarrior-test-with-fixtures
    (let* ((index (orgwarrior--index))
           (file (expand-file-name "tasks.org" dir))
           (hash-of (lambda (title) (orgwarrior--hash "tasks.org" title)))
           (has (lambda (index title) (orgwarrior--id index (funcall hash-of title)))))
      (should (eq index (orgwarrior--index)))
      (should (funcall has index "Pay rent"))
      ;; An edit in Emacs: the new title in, the old one out.
      (with-current-buffer (orgwarrior--file-buffer file)
        (goto-char (point-min))
        (re-search-forward "Pay rent")
        (replace-match "Pay the rent")
        ;; From the body too, the heading's hash, as the index has it.
        (forward-line 1)
        (should (equal (orgwarrior--hash-at-point) (funcall hash-of "Pay the rent")))
        (save-buffer))
      (let ((index (orgwarrior--index)))
        (should (funcall has index "Pay the rent"))
        (should-not (funcall has index "Pay rent")))
      ;; Rewritten on disk: read again, its headings hashed again.
      (sleep-for 1.1)  ; a newer modification time than the buffer's
      (with-temp-file file
        (insert (replace-regexp-in-string "Pay the rent" "Pay rent on disk"
                                          (orgwarrior-test-file dir "tasks.org"))))
      (let ((index (orgwarrior--index)))
        (should (funcall has index "Pay rent on disk"))
        (should-not (funcall has index "Pay the rent"))
        (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior--id index (funcall hash-of "Pay rent on disk")))
                                  :id)
                       (orgwarrior--id index (funcall hash-of "Pay rent on disk"))))))))

(ert-deftest orgwarrior-test-index-20000-headings ()
  "A large setup: with 20,000 more headings, a request after the first
doesn't hash them again."
  (orgwarrior-test-with-fixtures
    (let ((big (expand-file-name "big.org" dir)))
      (with-temp-file big
        (dotimes (p 2000)
          (insert (format "* Project %d\n" p))
          (dotimes (c 9)
            (insert (format "** TODO Task %d-%d :@home:\nSome body text.\n" p c)))))
      (let ((org-agenda-files (append org-agenda-files (list big))))
        (should (= (length (orgwarrior-index-entries (orgwarrior--index)))
                   (+ 20000 (length (orgwarrior-index-entries
                                     (let ((org-agenda-files (butlast org-agenda-files)))
                                       (orgwarrior--index)))))))
        (orgwarrior--index)
        (should (< (car (benchmark-run 1 (orgwarrior--index))) 0.05))
        (let ((id (orgwarrior--id (orgwarrior--index) (orgwarrior--hash "tasks.org" "Pay rent"))))
          (should (< (car (benchmark-run 1 (orgwarrior-test-ok :op "show" :id id))) 0.5)))
        (should (< (car (benchmark-run 1 (orgwarrior-test-ok :op "view" :kind "today"))) 1.0))))))

(ert-deftest orgwarrior-test-id-stable-across-keyword-change ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Call dentist")))
      (should (>= (length id) 2))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "todo" :args [])
      (should (equal (orgwarrior-test-id "Call dentist") id))
      (should (string-match-p "^\\*\\* TODO Call dentist" (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-no-such-task ()
  (orgwarrior-test-with-fixtures
    (should (string-match-p "No task" (orgwarrior-test-error :op "show" :id "zz")))))

(ert-deftest orgwarrior-test-id-too-short ()
  (orgwarrior-test-with-fixtures
    (should (string-match-p "too short" (orgwarrior-test-error :op "show" :id "a")))))

(ert-deftest orgwarrior-test-ambiguous-prefix ()
  (let* ((a (orgwarrior-entry-create :hash "ab12" :buffer (current-buffer) :pos 1))
         (b (orgwarrior-entry-create :hash "ab34" :buffer (current-buffer) :pos 1))
         (index (orgwarrior-index-create :entries (list a b)
                                    :prefixes (orgwarrior--prefixes '("ab12" "ab34")))))
    (cl-letf (((symbol-function 'orgwarrior--describe) (lambda (_i e) (orgwarrior-entry-hash e))))
      (should (string-match-p "ambiguous"
                              (cadr (should-error (orgwarrior--resolve index "ab") :type 'user-error))))
      (should (eq (orgwarrior--resolve index "ab3") b)))))

(ert-deftest orgwarrior-test-twins ()
  "Same-titled headings in one file: the first keeps its title's hash, each
later one its own, numbered, so each has an ID and acts alone."
  (orgwarrior-test-with-fixtures
    (let* ((index (orgwarrior--index))
           (first (orgwarrior--id index (orgwarrior--hash "tasks.org" "Take out trash")))
           (second (orgwarrior--id index (orgwarrior--hash "tasks.org" "Take out trash" 2)))
           (in-3-days (format-time-string "%F" (time-add nil (* 3 86400)))))
      (should (and first second (not (equal first second))))
      (should (equal (sort (delq nil (mapcar (lambda (l) (and (string-match-p "Take out trash" (plist-get l :text))
                                                                (plist-get l :id)))
                                             (orgwarrior-test-ok :op "view" :kind "all")))
                           #'string<)
                     (sort (list first second) #'string<)))
      (should (string-match-p in-3-days (plist-get (orgwarrior-test-ok :op "show" :id second) :scheduled)))
      (orgwarrior-test-ok :op "act" :ids (vector second) :verb "pri" :args ["a"])
      (should (string-match-p (concat "\\* TODO Take out trash .*\nSCHEDULED: <[^\n]*\n"
                                      "\\*\\* TODO \\[#A\\] Take out trash .*\nSCHEDULED: <" in-3-days)
                              (orgwarrior-test-file dir "tasks.org")))
      ;; Accepted: with the first gone, the second is the first, its ID too.
      (orgwarrior-test-archive first)
      (should (string-match-p in-3-days (plist-get (orgwarrior-test-ok :op "show" :id first) :scheduled))))))

(ert-deftest orgwarrior-test-twins-archived ()
  "An archive collects twins: each archived one has an ID that shows it."
  (orgwarrior-test-with-fixtures
    (let ((first (orgwarrior-test-id "Take out trash")))
      (orgwarrior-test-archive first)
      (orgwarrior-test-archive (orgwarrior-test-id "Take out trash"))
      (let ((ids (delq nil (mapcar (lambda (l) (and (string-match-p "Take out trash" (plist-get l :text))
                                                     (plist-get l :id)))
                                   (orgwarrior-test-ok :op "view" :kind "search" :arg "trash" :archive t)))))
        (should (= 2 (length (delete-dups (copy-sequence ids)))))
        (should (equal (delete-dups (mapcar (lambda (id) (plist-get (orgwarrior-test-ok :op "show" :id id) :file))
                                            ids))
                       '("tasks.org_archive")))
        (should-not (equal (plist-get (orgwarrior-test-ok :op "show" :id (car ids)) :scheduled)
                           (plist-get (orgwarrior-test-ok :op "show" :id (cadr ids)) :scheduled)))))))

(ert-deftest orgwarrior-test-twins-refiled ()
  "Refiling a twin next to its twin reports the ID of the one that landed."
  (orgwarrior-test-with-fixtures
    (let ((in-3-days (format-time-string "%F" (time-add nil (* 3 86400)))))
      (orgwarrior-test-refile "Take out trash" "warr")
      (let* ((result (car (orgwarrior-test-refile "Take out trash" "warr")))
             (shown (orgwarrior-test-ok :op "show" :id (plist-get result :id))))
        (should (equal (plist-get shown :file) "projects.org"))
        (should (equal (plist-get result :heading) "TODO Take out trash :@home:recurring:"))
        ;; The second refiled was the later one: the one with its date.
        (should (string-match-p in-3-days (plist-get shown :scheduled)))))))

(ert-deftest orgwarrior-test-renamed-task-stops-matching ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle")))
      (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
        (goto-char (point-min))
        (re-search-forward "Learn to juggle")
        (replace-match "Learn to unicycle")
        (save-buffer))
      (should (string-match-p "No task" (orgwarrior-test-error :op "show" :id id))))))


;;;; Views

(ert-deftest orgwarrior-test-view-today ()
  (orgwarrior-test-with-fixtures
    (let* ((lines (orgwarrior-test-ok :op "view" :kind "today" :width 80))
           (dentist (seq-find (lambda (l) (string-match-p "Call dentist" (plist-get l :text))) lines)))
      (should (plist-get dentist :id))
      ;; The day header is a plain line.
      (should-not (plist-get (car lines) :id))
      (should (string-match-p "agenda" (plist-get (car lines) :text)))
      ;; Not scheduled today: absent.
      (should-not (seq-find (lambda (l) (string-match-p "juggle" (plist-get l :text))) lines))
      ;; The user's own agenda buffer is untouched.
      (should-not (get-buffer "*Org Agenda*"))
      (should-not (get-buffer orgwarrior-agenda-buffer)))))

(ert-deftest orgwarrior-test-view-date-lines ()
  ;; A date header carries its date, for front ends to step from.
  (orgwarrior-test-with-fixtures
    (cl-flet ((dates (kind) (delq nil (mapcar (lambda (l) (plist-get l :date))
                                              (orgwarrior-test-ok :op "view" :kind kind)))))
      (should (= 7 (length (dates "week"))))
      (should (equal (dates "today") (list (format-time-string "%F")))))
    ;; A week from a date: the fixtures start a week on its first day.
    (let ((dates (delq nil (mapcar (lambda (l) (plist-get l :date))
                                   (orgwarrior-test-ok :op "view" :kind "week" :arg "2030-01-15")))))
      (should (equal (list (car dates) (car (last dates)) (length dates)) '("2030-01-15" "2030-01-21" 7))))
    (should (string-match-p "Can't parse date"
                            (orgwarrior-test-error :op "view" :kind "week" :arg "fridge")))))

(ert-deftest orgwarrior-test-view-date ()
  (orgwarrior-test-with-fixtures
    (let ((lines (orgwarrior-test-ok :op "view" :kind "words" :arg "+1d")))
      (should (seq-find (lambda (l) (string-match-p "Scaffold the package" (plist-get l :text))) lines))
      (should-not (seq-find (lambda (l) (string-match-p "Call dentist" (plist-get l :text))) lines)))
    ;; Neither keywords nor a date: a text search.
    (should (string-match-p "Search words: fridge"
                            (plist-get (car (orgwarrior-test-ok :op "view" :kind "words" :arg "fridge"))
                                       :text)))
    ;; Words with a date in them are still a search: org reads "call 3
    ;; people" as the 3rd, skipping the words it doesn't know.
    (dolist (words '("call 3 people" "show 91" "dentist fri"))
      (should (string-match-p (concat "Search words: " words)
                              (plist-get (car (orgwarrior-test-ok :op "view" :kind "words" :arg words))
                                         :text))))
    ;; A date and a time, or org's own timestamp text with its weekday.
    (dolist (date '("fri 14:00-15:30" "nov 3" "2030-01-15 Tue 9:00"))
      (should (seq-find (lambda (l) (plist-get l :date))
                        (orgwarrior-test-ok :op "view" :kind "words" :arg date))))))

(ert-deftest orgwarrior-test-view-search ()
  (orgwarrior-test-with-fixtures
    (cl-flet ((ids-of (kind arg)
                (delq nil (mapcar (lambda (l) (plist-get l :text))
                                  (seq-filter (lambda (l) (plist-get l :id))
                                              (orgwarrior-test-ok :op "view" :kind kind :arg arg))))))
      ;; Any case, part of a word, tasks and events alike.
      (let ((found (ids-of "words" "DENT")))
        (should (= 2 (length found)))
        (should (seq-find (lambda (s) (string-match-p "Call dentist" s)) found))
        (should (seq-find (lambda (s) (string-match-p "Dentist appointment" s)) found)))
      ;; Quoted (kind "search"), a word that's also a date is searched for.
      ;; Not a weekday: fixture timestamps, relative to today, have those.
      (should-not (ids-of "search" "tomorrow"))
      (should (ids-of "search" "batt"))
      (should (string-match-p "Search for what"
                              (orgwarrior-test-error :op "view" :kind "search" :arg " "))))))

(ert-deftest orgwarrior-test-view-states ()
  (orgwarrior-test-with-fixtures
    (cl-flet ((texts (arg) (mapcar (lambda (l) (plist-get l :text))
                                   (orgwarrior-test-ok :op "view" :kind "words" :arg arg)))
              (has (re texts) (seq-find (lambda (s) (string-match-p re s)) texts)))
      (let ((done (texts "done")))
        (should (has "Write the spec" done))
        (should-not (has "dentist" done)))
      (let ((both (texts "Wait NEXT")))
        (should (has "Package from mom" both))
        (should (has "Call dentist" both))
        (should-not (has "Take out trash" both)))
      (let ((tagged (texts "next +@phone")))
        (should (has "Call dentist" tagged))
        (should-not (has "Scaffold the package" tagged)))
      ;; A keyword followed by something that isn't a tag match is no state query.
      (should (string-match-p "Search words: next fridge"
                              (car (texts "next fridge")))))))

(ert-deftest orgwarrior-test-view-tags ()
  (orgwarrior-test-with-fixtures
    (let ((texts (mapcar (lambda (l) (plist-get l :text))
                         (orgwarrior-test-ok :op "view" :kind "tags" :arg "+@home"))))
      (should (= 2 (seq-count (lambda (s) (string-match-p "Take out trash" s)) texts)))
      (should-not (seq-find (lambda (s) (string-match-p "dentist" s)) texts)))))

(ert-deftest orgwarrior-test-view-custom ()
  (orgwarrior-test-with-fixtures
    (let ((texts (mapcar (lambda (l) (plist-get l :text))
                         (orgwarrior-test-ok :op "view" :kind "custom" :arg "i"))))
      (should (seq-find (lambda (s) (string-match-p "Buy batteries" s)) texts)))
    (should (string-match-p "No agenda command"
                            (orgwarrior-test-error :op "view" :kind "custom" :arg "zz")))))

(ert-deftest orgwarrior-test-view-drops-key-hints ()
  (orgwarrior-test-with-fixtures
    (dolist (req '((:kind "all") (:kind "tags" :arg "+@home")))
      (let ((texts (mapcar (lambda (l) (plist-get l :text))
                           (apply #'orgwarrior-test-ok :op "view" req))))
        (should (seq-find (lambda (s) (string-match-p "Take out trash" s)) texts))
        (should-not (seq-find (lambda (s) (string-match-p "Press\\|(1)" s)) texts))))))

(ert-deftest orgwarrior-test-view-prefix-format ()
  (orgwarrior-test-with-fixtures
    (let ((line (lambda (lines)
                  (plist-get (seq-find (lambda (l) (string-match-p "Learn to juggle" (plist-get l :text)))
                                       lines)
                             :text))))
      (should (string-match-p "\\`  tasks: +TODO"
                              (funcall line (orgwarrior-test-ok :op "view" :kind "all"))))
      (should (string-match-p "\\`>tasks: TODO"
                              (funcall line (orgwarrior-test-ok :op "view" :kind "all" :prefix ">%c: "))))
      ;; Only for orgwarrior's call.
      (should-not (stringp org-agenda-prefix-format)))))

(ert-deftest orgwarrior-test-view-time-grid ()
  (orgwarrior-test-with-fixtures
    (let ((grid-p (lambda (lines)
                    (seq-find (lambda (l) (string-match-p "\\.\\.\\.\\.\\.\\. -----" (plist-get l :text)))
                              lines))))
      (should-not (funcall grid-p (orgwarrior-test-ok :op "view" :kind "today")))
      (should (funcall grid-p (orgwarrior-test-ok :op "view" :kind "today" :grid t))))))

(ert-deftest orgwarrior-test-view-all-day ()
  ;; An event without a time is all_day; a timed one, a task on a plain
  ;; date and a scheduled task aren't.
  (orgwarrior-test-with-fixtures
    (with-current-buffer (find-file-noselect (expand-file-name "calendar.org" dir))
      (goto-char (point-max))
      (insert (format-time-string "* Day off\n<%F %a>\n")
              (format-time-string "* Holiday week\n<%F %a>--" (time-add nil -86400))
              (format-time-string "<%F %a>\n" (time-add nil 86400)))
      (insert (format-time-string "* TODO Return the books\n<%F %a>\n"))
      (insert "* Every day\n<%%(diary-cyclic 1 1 1 2000)>\n")
      (save-buffer))
    (let* ((lines (orgwarrior-test-ok :op "view" :kind "today"))
           (all-day (lambda (title)
                      (plist-get (seq-find (lambda (l) (string-match-p title (plist-get l :text))) lines)
                                 :all_day))))
      (dolist (title '("Day off" "Holiday week" "Every day"))
        (should (eq (funcall all-day title) t)))
      (dolist (title '("Dentist appointment" "Return the books" "Call dentist"))
        (should-not (funcall all-day title))))))

(ert-deftest orgwarrior-test-view-spans ()
  (orgwarrior-test-with-fixtures
    (let* ((org-todo-keyword-faces '(("NEXT" . (:foreground "orange"))))
           (lines (orgwarrior-test-ok :op "view" :kind "today" :width 80))
           (spans (lambda (title)
                    (orgwarrior-test-span-texts
                     (seq-find (lambda (l) (string-match-p title (plist-get l :text))) lines)))))
      (should (equal (plist-get (car lines) :spans) '((0 17 "header" nil))))
      (should (member '("NEXT" "todo" "NEXT") (funcall spans "Call dentist")))
      (should (member '(":@phone:" "tag" nil) (funcall spans "Call dentist")))
      (should (assoc " Pay rent [0/1]" (funcall spans "Pay rent")))
      (should (equal (nth 1 (assoc " Pay rent [0/1]" (funcall spans "Pay rent"))) "upcoming")))))

(ert-deftest orgwarrior-test-view-done-keyword-span ()
  ;; The agenda buffer has no `org-done-keywords' of its own.
  (orgwarrior-test-with-fixtures
    (let* ((line (seq-find (lambda (l) (string-match-p "Write the spec" (plist-get l :text)))
                           (orgwarrior-test-ok :op "view" :kind "words" :arg "done"))))
      (should (member '("DONE" "done" "DONE") (orgwarrior-test-span-texts line))))))

(ert-deftest orgwarrior-test-view-search-keyword-span ()
  ;; org-search-view puts no `todo-state' on its lines; the keyword is still found.
  (orgwarrior-test-with-fixtures
    (let* ((line (seq-find (lambda (l) (plist-get l :id))
                           (orgwarrior-test-ok :op "view" :kind "search" :arg "batteries"))))
      (should (member '("TODO" "todo" "TODO") (orgwarrior-test-span-texts line))))))

(ert-deftest orgwarrior-test-face-role-inherits ()
  (should (equal (orgwarrior--face-role 'org-scheduled-previously) "overdue"))
  (should (equal (orgwarrior--face-role '((:foreground "red") org-tag org-warning)) "tag"))
  (should-not (orgwarrior--face-role '(:foreground "red")))
  (should (equal (orgwarrior--face-role '((:inherit org-link) org-agenda-calendar-sexp)) "link"))
  (should-not (orgwarrior--face-role 'default))
  (custom-declare-face 'orgwarrior-test-face '((t :inherit org-upcoming-deadline)) "")
  (should (equal (orgwarrior--face-role 'orgwarrior-test-face) "upcoming")))

(ert-deftest orgwarrior-test-view-tags-placement ()
  (orgwarrior-test-with-fixtures
    (let ((line (lambda (&rest req)
                  (plist-get (seq-find (lambda (l) (string-match-p "Call dentist" (plist-get l :text)))
                                       (apply #'orgwarrior-test-ok :op "view" :kind "today" :width 80 req))
                             :text))))
      (should (string-match-p "Call dentist :@phone:\\'" (funcall line :tags "inline")))
      (should (string-match-p "Call dentist  +:@phone:\\'" (funcall line)))
      (should (= 80 (length (funcall line)))))))

;; org-habit's graph: off the line (which keeps its tags), a line of its own.
(ert-deftest orgwarrior-test-view-habit ()
  (require 'org-habit)
  (orgwarrior-test-with-fixtures
    (with-temp-file (expand-file-name "tasks.org" dir)
      (insert (orgwarrior-test-file dir "tasks.org")
              (orgwarrior-fixture--expand-dates
               (concat "** TODO Water the plants :@home:\n"
                       "SCHEDULED: <{{+0}} .+2d>\n"
                       ":PROPERTIES:\n:STYLE: habit\n:END:\n"
                       ":LOGBOOK:\n- State \"DONE\" from \"TODO\" [{{-2}} 09:00]\n:END:\n"))))
    (let* ((line (seq-find (lambda (l) (string-match-p "Water the plants" (plist-get l :text)))
                           (orgwarrior-test-ok :op "view" :kind "today")))
           (habit (plist-get line :habit))
           (graph (plist-get habit :text)))
      (should (string-match-p "Water the plants +:@home:\\'" (plist-get line :text)))
      (should (= (length graph) (+ 1 org-habit-preceding-days org-habit-following-days)))
      (should (string-match-p "\\*" graph))
      (should (string-match-p "!" graph))
      (should (seq-every-p (lambda (s) (string-prefix-p "habit-" (nth 2 s))) (plist-get habit :spans)))
      (should (seq-every-p (lambda (c) (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" c))
                           (seq-filter #'stringp (plist-get habit :colors)))))
    ;; Other lines have no graph.
    (should-not (seq-some (lambda (l) (plist-get l :habit))
                          (seq-remove (lambda (l) (string-match-p "Water" (plist-get l :text)))
                                      (orgwarrior-test-ok :op "view" :kind "today"))))))

(ert-deftest orgwarrior-test-habit-colors-as-set ()
  "A habit day's color is its face's, exactly, with no color display (a
daemon that never had a graphical frame, or batch Emacs as here)."
  (require 'org-habit)
  (let* ((faces '(org-habit-clear-face org-habit-clear-future-face org-habit-ready-face
                  org-habit-ready-future-face org-habit-alert-face org-habit-alert-future-face
                  org-habit-overdue-face org-habit-overdue-future-face))
         (old (mapcar (lambda (f) (face-attribute f :background)) faces))
         (set (seq-map-indexed (lambda (_ i) (format "#%02x%02x%02x" (+ 17 i) (+ 101 i) (+ 203 i))) faces)))
    (unwind-protect
        (progn
          (cl-mapc (lambda (f c) (set-face-attribute f nil :background c)) faces set)
          (orgwarrior-test-with-fixtures
            (with-temp-file (expand-file-name "tasks.org" dir)
              (insert (orgwarrior-test-file dir "tasks.org")
                      (orgwarrior-fixture--expand-dates
                       (concat "** TODO Water the plants :@home:\n"
                               "SCHEDULED: <{{+0}} .+2d>\n:PROPERTIES:\n:STYLE: habit\n:END:\n"
                               ":LOGBOOK:\n- State \"DONE\" from \"TODO\" [{{-2}} 09:00]\n"
                               "- State \"DONE\" from \"TODO\" [{{-4}} 09:00]\n:END:\n"))))
            (let* ((line (seq-find (lambda (l) (string-match-p "Water the plants" (plist-get l :text)))
                                   (orgwarrior-test-ok :op "view" :kind "today")))
                   (colors (seq-filter #'stringp (plist-get (plist-get line :habit) :colors))))
              (should colors)
              (should (seq-every-p (lambda (c) (member c set)) colors)))))
      (cl-mapc (lambda (f c) (set-face-attribute f nil :background c)) faces old)))
  (should (equal (orgwarrior--rgb "forestgreen") "#228b22"))
  (should-not (orgwarrior--rgb "no-such-color")))

(ert-deftest orgwarrior-test-view-time-and-extra-spans ()
  (orgwarrior-test-with-fixtures
    (let* ((lines (orgwarrior-test-ok :op "view" :kind "today"))
           (roles (lambda (title)
                    (let ((l (seq-find (lambda (l) (string-match-p title (plist-get l :text))) lines)))
                      (mapcar (lambda (s) (cons (substring (plist-get l :text) (nth 0 s) (nth 1 s))
                                                (nth 2 s)))
                              (plist-get l :spans))))))
      (should (member '("14:00" . "time") (funcall roles "Dentist appointment")))
      (should (member '("Scheduled:" . "extra") (funcall roles "Call dentist")))
      (should (member '("In   2 d.:" . "extra") (funcall roles "Pay rent"))))))


;;;; Calendar

(ert-deftest orgwarrior-test-calendar ()
  (orgwarrior-test-with-fixtures
    (let* ((soon (calendar-gregorian-from-absolute (+ (org-today) 5)))
           (soon-iso (pcase-let ((`(,m ,d ,y) soon)) (format "%04d-%02d-%02d" y m d))))
      (with-current-buffer (find-file-noselect (expand-file-name "calendar.org" dir))
        (goto-char (point-max))
        (insert "* Trip\n<2026-11-02 Mon>--<2026-11-04 Wed>\n"
                "* Lunch <2026-11-05 Thu 12:00-13:00>\n"
                (format "* Birthdays\n%%%%(diary-anniversary %d %d 1980) [[https://x.org][Robin]] is %%d\n"
                        (nth 0 soon) (nth 1 soon))
                "* Broken\n%%(no-such-function)\n"
                "* TODO File taxes\nDEADLINE: <2026-11-20 Fri +1y -3d>\n"
                "* Old :ARCHIVE:\n<2026-11-06 Fri>\n"
                "* COMMENT Draft\n<2026-11-07 Sat>\n")
        (save-buffer))
      (let* ((entries (orgwarrior-test-ok :op "calendar" :days 30))
             (get (lambda (title) (seq-find (lambda (e) (equal (plist-get e :title) title)) entries)))
             (stamp (lambda (title) (car (plist-get (funcall get title) :stamps)))))
        (should (equal (plist-get (funcall get "Pay rent [0/1]") :keyword) "TODO"))
        (should (equal (plist-get (funcall stamp "Pay rent [0/1]") :kind) "deadline"))
        (should (equal (plist-get (funcall get "Pay rent [0/1]") :tags) '("finances")))
        (should (equal (plist-get (funcall get "Scaffold the package") :tags) '("@computer")))
        ;; The whole hash, which resolves like any ID.
        (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (plist-get (funcall get "Pay rent [0/1]") :id)) :id)
                       (orgwarrior-test-id "Pay rent")))
        (should (equal (plist-get (funcall stamp "Take out trash") :repeat) '(:type "+" :value 1 :unit "w")))
        (should (equal (plist-get (funcall stamp "Dentist appointment") :start_time) "14:00"))
        (let ((trip (funcall stamp "Trip")))
          (should (equal (list (plist-get trip :start) (plist-get trip :end) (plist-get trip :start_time))
                         '("2026-11-02" "2026-11-04" nil))))
        ;; A timestamp in the heading: a time range, and out of the title.
        (should (equal (plist-get (funcall stamp "Lunch") :end_time) "13:00"))
        (let ((taxes (funcall stamp "File taxes")))
          (should (equal (plist-get taxes :warning) '(:value 3 :unit "d")))
          (should (equal (plist-get taxes :repeat) '(:type "+" :value 1 :unit "y"))))
        ;; A sexp is evaluated per day, its line's text formatted, links as shown.
        (should (equal (plist-get (funcall stamp "Birthdays") :dates)
                       `((:date ,soon-iso :text ,(format "Robin is %d" (- (nth 2 soon) 1980))))))
        ;; A broken one is dropped, not an error; archived and commented trees aren't there.
        (should-not (funcall get "Broken"))
        (should-not (funcall get "Old"))
        (should-not (funcall get "Draft"))
        (should-not (funcall get "Learn to juggle"))))))


;;;; Show

(ert-deftest orgwarrior-test-show ()
  (orgwarrior-test-with-fixtures
    (let ((task (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Pay rent"))))
      (should (equal (plist-get task :file) "tasks.org"))
      (should (equal (plist-get task :path) '("Tasks")))
      (should (string-match-p "\\`\\*\\* TODO Pay rent" (plist-get task :heading)))
      (should (string-match-p "\\`DEADLINE: <" (plist-get task :body)))
      (should (equal (plist-get task :deadline) (orgwarrior-fixture--expand-dates "<{{+2}}>")))
      (should-not (plist-get task :scheduled))
      (should (string-match-p "Transfer from checking" (plist-get task :body)))
      (should-not (plist-get task :children))
      ;; Org's own fontification, as spans per line.
      (let ((roles (mapcar (lambda (l)
                             (mapcar (lambda (s) (cons (substring (plist-get l :text) (nth 0 s) (nth 1 s))
                                                       (nth 2 s)))
                                     (plist-get l :spans)))
                           (plist-get task :lines))))
        (should (member '("TODO" . "todo") (nth 0 roles)))
        (should (member '(":finances:" . "tag") (nth 0 roles)))
        (should (equal (nth 1 roles) `(("DEADLINE:" . "label") (,(orgwarrior-fixture--expand-dates "<{{+2}}>") . "timestamp"))))
        (should (member '("[ ]" . "checkbox") (car (last roles))))))
    (let ((task (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Publish to PyPI"))))
      ;; Direct children, each with the ID that opens it.
      (let ((kids (plist-get task :children)))
        (should (equal (mapcar (lambda (c) (plist-get c :heading)) kids)
                       '("TODO Pick a license" "TODO Write a README")))
        (should (equal (plist-get (car kids) :text) "Pick a license"))
        (should (equal (plist-get (car kids) :keyword) "TODO"))
        (should (equal (plist-get (car kids) :id) (orgwarrior-test-id "Pick a license"))))
      (should (equal (plist-get task :body) "")))
    ;; No keyword, so not in `all': found by a search.
    (let* ((orgwarrior (seq-find (lambda (l) (string-match-p "Orgwarrior \\[" (plist-get l :text)))
                            (orgwarrior-test-ok :op "view" :kind "search" :arg "Orgwarrior")))
           (kids (plist-get (orgwarrior-test-ok :op "show" :id (plist-get orgwarrior :id)) :children)))
      (should (equal (mapcar (lambda (c) (plist-get c :keyword)) kids) '("DONE" "NEXT" "TODO")))
      (should (eq (plist-get (car kids) :done) t))
      (should (equal (plist-get (nth 1 kids) :tags) '("@computer")))
      (should (equal (plist-get (nth 1 kids) :text) "Scaffold the package")))))

;; Org's parser finds them; each line reads as Emacs shows it, its links
;; covering what they show.
(ert-deftest orgwarrior-test-show-html ()
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Pay rent"))
           (html (plist-get (orgwarrior-test-ok :op "show" :id id :html t) :html)))
      (should (string-match-p "<p>\nTransfer from checking" html))
      (should (string-match-p "<li class=\"off\"><code>\\[&\\(#xa0\\|nbsp\\);\\]</code> remember the memo line" html))
      (should-not (string-match-p "CREATED\\|DEADLINE\\|PROPERTIES" html))  ; drawers and planning out
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :html))
      ;; A source block: colored by face name, never run.
      (orgwarrior-test-ok :op "set-entry" :id id :old (plist-get (orgwarrior-test-ok :op "show" :id id) :body)
                          :text "#+begin_src emacs-lisp :exports both\n(error \"ran\")\n#+end_src\n")
      (let ((html (plist-get (orgwarrior-test-ok :op "show" :id id :html t) :html)))
        (should (string-match-p "class=\"src src-emacs-lisp\"" html))
        (when (require 'htmlize nil t)  ; colors only where htmlize is
          (should (string-match-p "<span class=\"org-" html)))))))

(ert-deftest orgwarrior-test-show-links ()
  (orgwarrior-test-with-fixtures
    (with-temp-file (expand-file-name "tasks.org" dir)
      (insert (replace-regexp-in-string
               "Learn to juggle :someday:\n"
               (concat "Learn to juggle :someday:\n"
                       "See [[https://example.com/j][a guide]], https://example.org/balls"
                       " and [[file:notes.org]].\n")
               (orgwarrior-test-file dir "tasks.org"))))
    (let* ((task (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Learn to juggle")))
           (links (plist-get task :links)))
      (should (equal (mapcar (lambda (l) (list (plist-get l :type) (plist-get l :url) (plist-get l :text)))
                             links)
                     '(("https" "https://example.com/j" "a guide")
                       ("https" "https://example.org/balls" nil)
                       ("file" "file:notes.org" nil))))
      (let* ((line (nth 1 (plist-get task :lines)))
             (text (plist-get line :text))
             (shown (lambda (l) (substring text (plist-get l :start) (plist-get l :end)))))
        (should (equal text "See a guide, https://example.org/balls and file:notes.org."))
        (should (equal (mapcar (lambda (l) (list (funcall shown l) (plist-get l :url)))
                               (plist-get line :links))
                       '(("a guide" "https://example.com/j")
                         ("https://example.org/balls" "https://example.org/balls")
                         ("file:notes.org" "file:notes.org"))))
        (should (equal (mapcar (lambda (s) (substring text (nth 0 s) (nth 1 s)))
                               (seq-filter (lambda (s) (equal (nth 2 s) "link")) (plist-get line :spans)))
                       (mapcar shown (plist-get line :links))))))
    (should-not (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Call dentist")) :links))))

;; A link in a heading reads as its description wherever the heading shows.
(ert-deftest orgwarrior-test-heading-links ()
  (orgwarrior-test-with-fixtures
    (with-temp-file (expand-file-name "projects.org" dir)
      (insert (replace-regexp-in-string
               "Pick a license" "Pick a [[https://choosealicense.com][license]]"
               (orgwarrior-test-file dir "projects.org"))))
    (let* ((id (orgwarrior-test-id "Pick a license"))
           (line (seq-find (lambda (l) (equal (plist-get l :id) id))
                           (orgwarrior-test-ok :op "view" :kind "all")))
           (text (plist-get line :text)))
      (should (member "license" (mapcar (lambda (s) (substring text (nth 0 s) (nth 1 s)))
                                        (seq-filter (lambda (s) (equal (nth 2 s) "link"))
                                                    (plist-get line :spans)))))
      (let ((kid (car (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Publish to PyPI"))
                                 :children))))
        (should (equal (plist-get kid :heading) "TODO Pick a license"))
        (should (equal (plist-get kid :text) "Pick a license")))
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids (vector id) :verb "next" :args []))
                                :heading)
                     "NEXT Pick a license")))))

(ert-deftest orgwarrior-test-show-notes ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Call dentist")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "done" :args [] :note "Booked")
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "next" :args [])  ; no note: none shown
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "note" :args [] :note "Bring\n\nthe card")
      (let ((notes (plist-get (orgwarrior-test-ok :op "show" :id id) :notes)))
        (should (equal (mapcar (lambda (n) (list (plist-get n :kind) (plist-get n :state) (plist-get n :text)))
                               notes)
                       '(("note" nil "Bring\n\nthe card") ("state" "DONE" "Booked"))))
        (should (string-match-p "\\`\\[[0-9-]+ [A-Za-z]+ [0-9:]+\\]\\'" (plist-get (car notes) :time))))
      ;; A template of one's own still reads, and oldest-first files come out newest first.
      (let ((org-log-note-headings '((note . "Said on %t"))))
        (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
          (goto-char (point-min))
          (re-search-forward "Learn to juggle")
          (forward-line)
          (insert "- Said on [2026-01-01 Thu 09:00] \\\\\n  first\n"
                  "- Said on [2026-02-01 Sun 09:00] \\\\\n  second\n")
          (save-buffer))
        (should (equal (mapcar (lambda (n) (plist-get n :text))
                               (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Learn to juggle"))
                                          :notes))
                       '("second" "first")))))))

(ert-deftest orgwarrior-test-show-from ()
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :fields '(:title "Hers" :properties (:FROM "robin")))
      (should (equal "robin" (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Hers")) :from)))
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Pay rent")) :from)))))


;;;; The entry's text and checkboxes

;; The text below the heading, replaced as a whole: one blank line after the
;; planning line and drawers, whatever was typed; children untouched.
(ert-deftest orgwarrior-test-headings-in-text ()
  "Headings typed in an entry's text become its children, after the ones it
has, the shallowest one level below it whatever its stars; keywords and
tags read as org reads them; a star line inside a block stays its text."
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-orgw))
           (old (plist-get (orgwarrior-test-ok :op "show" :id id) :body))
           (r (orgwarrior-test-ok :op "set-entry" :id id :old old :text (string-join '(
                "The plan, in short."
                "#+begin_src sh"
                "* not a heading"
                "#+end_src"
                "** NEXT Book flights :@phone:"
                "Window seat."
                "*** Compare fares"
                "** Pack") "\n")))
           (file (orgwarrior-test-file dir "projects.org")))
      (should (= (plist-get r :new_children) 3))
      ;; Its [1/3] counts its children still, the new ones too.
      (should (string-match-p "^\\* Orgwarrior \\[1/4\\]" file))
      ;; Its text: the body before the first heading, the block's star escaped.
      (should (string-match-p "The plan, in short\\.\n#\\+begin_src sh\n,\\* not a heading\n#\\+end_src"
                              (plist-get (orgwarrior-test-ok :op "show" :id id) :body)))
      ;; After its own children, at their level and below.
      (should (string-match-p (concat "\\*\\* TODO Publish to PyPI\\(?:.\\|\n\\)*?\n\n"
                                      "\\*\\* NEXT Book flights +:@phone:\nWindow seat\\.\n"
                                      "\\*\\*\\* Compare fares\n\\*\\* Pack")
                              file))
      (should (orgwarrior-test-id "Book flights"))  ; a task now, with its keyword
      (should-not (string-match-p "^\\* not a heading" file))))
  ;; Adding: the body's headings under the new entry.
  (orgwarrior-test-with-fixtures
    (let* ((r (orgwarrior-test-ok :op "add" :text "Plan the trip\nSome notes.\n*** TODO Book flights\n**** Window seat"
                                  :file (expand-file-name "inbox.org" dir) :heading "Tasks"))
           (inbox (orgwarrior-test-file dir "inbox.org")))
      (should (= (plist-get r :new_children) 2))
      (should (string-match-p (concat "\\*\\* TODO Plan the trip\n\\(?:.*\n\\)*?Some notes\\.\n\n"
                                      "\\*\\*\\* TODO Book flights\n\\*\\*\\*\\* Window seat")
                              inbox))))
  ;; A heading without a title: refused, nothing written.
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Pay rent"))
           (old (plist-get (orgwarrior-test-ok :op "show" :id id) :body))
           (before (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "needs a title" (orgwarrior-test-error :op "set-entry" :id id :old old :text "a\n**")))
      (should (equal (orgwarrior-test-file dir "tasks.org") before)))))

(ert-deftest orgwarrior-test-set-entry ()
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Pay rent"))
           (body (lambda () (plist-get (orgwarrior-test-ok :op "show" :id id) :body)))
           (old (funcall body))
           (planning (car (split-string old "\n"))))
      (should (string-match-p "\\`DEADLINE: " planning))
      (should (equal (plist-get (orgwarrior-test-ok :op "set-entry" :id id :old old
                                                    :text (concat planning "\n:PROPERTIES:\n:STYLE: habit\n:END:\n- one\n\n\n"))
                                :heading)
                     "TODO Pay rent [0/0] :finances:"))
      (should (equal (funcall body) (concat planning "\n:PROPERTIES:\n:STYLE: habit\n:END:\n\n- one")))
      (should (string-match-p "- one\n\\*\\* WAIT" (orgwarrior-test-file dir "tasks.org")))
      ;; Changed underneath: refused, nothing written.
      (let ((before (orgwarrior-test-file dir "tasks.org")))
        (should (string-match-p "changed" (orgwarrior-test-error :op "set-entry" :id id :old old :text "x")))
        (should (equal (orgwarrior-test-file dir "tasks.org") before)))
      (should (equal (plist-get (orgwarrior-test-ok :op "set-entry" :id id :old (funcall body)
                                                    :text "- [X] a\n- [ ] b")
                                :heading)
                     "TODO Pay rent [1/2] :finances:"))
      (orgwarrior-test-ok :op "set-entry" :id id :old (funcall body) :text "")
      (should (equal (funcall body) "")))
    ;; A parent: its own text only, children kept.  Its parent's show counts them.
    (should (equal (mapcar (lambda (c) (plist-get c :child_count))
                           (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-orgw)) :children))
                   '(0 0 2)))
    (let ((id (orgwarrior-test-id "Publish to PyPI")))
      (orgwarrior-test-ok :op "set-entry" :id id :old "" :text "Before the children.")
      (let ((task (orgwarrior-test-ok :op "show" :id id)))
        (should (equal (plist-get task :body) "Before the children."))
        (should (= (length (plist-get task :children)) 2))))))

;; org-toggle-checkbox: cookies, nested ones and a parent's [-] follow.
(ert-deftest orgwarrior-test-check ()
  (orgwarrior-test-with-fixtures
    (with-temp-file (expand-file-name "tasks.org" dir)
      (insert (replace-regexp-in-string
               "- \\[ \\] remember the memo line\n"
               "- [ ] remember the memo line\n- [ ] bag [0/2]\n  - [ ] shirt\n  - [ ] pants\n"
               (orgwarrior-test-file dir "tasks.org"))))
    (let* ((id (orgwarrior-test-id "Pay rent"))
           (task (orgwarrior-test-ok :op "show" :id id))
           (boxes (plist-get task :checkboxes)))
      (should (equal (mapcar (lambda (b) (list (plist-get b :text) (plist-get b :state))) boxes)
                     '(("remember the memo line" "off") ("bag [0/2]" "off")
                       ("shirt" "off") ("pants" "off"))))
      ;; :line points at the line in :lines.
      (should (string-match-p "shirt" (plist-get (nth (plist-get (nth 2 boxes) :line)
                                                       (plist-get task :lines))
                                                  :text)))
      (let ((r (orgwarrior-test-ok :op "check" :id id :n 3 :text "shirt")))
        (should (equal (plist-get r :id) id))
        (should (string-match-p "Pay rent \\[0/2\\]" (plist-get r :heading))))
      (should (string-match-p "- \\[-\\] bag \\[1/2\\]\n  - \\[X\\] shirt"
                              (orgwarrior-test-file dir "tasks.org")))
      (orgwarrior-test-ok :op "check" :id id :n 1 :text "remember the memo line")
      (should (string-match-p "TODO Pay rent \\[1/2\\]" (orgwarrior-test-file dir "tasks.org")))
      ;; Toggles back.
      (orgwarrior-test-ok :op "check" :id id :n 1 :text "remember the memo line")
      (should (string-match-p "TODO Pay rent \\[0/2\\]" (orgwarrior-test-file dir "tasks.org")))
      ;; The text must match; there's no check without it, and no check verb.
      (dolist (bad '((:n 1 :text "something else") (:n 1) (:n 9 :text "x")))
        (should (string-match-p "changed" (apply #'orgwarrior-test-error :op "check" :id id bad))))
      (should (string-match-p "Unknown verb" (orgwarrior-test-error :op "act" :ids (vector id) :verb "check"
                                                               :args ["1"]))))))


;;;; States, notes and priorities

(ert-deftest orgwarrior-test-warning-days ()
  (let ((org-deadline-warning-days 5))
    (should (= (plist-get (orgwarrior-test-ok :op "keywords") :warning_days) 5))))

(ert-deftest orgwarrior-test-keywords ()
  (should (equal (orgwarrior-test-ok :op "keywords")
                 '(:keywords ("TODO" "NEXT" "ACTIVE" "WAIT" "DONE" "SKIP")
                   :done ("DONE" "SKIP") :keys ("t" "n" "a" "w" "d" "k") :priorities ("A" "B" "C")
                   :warning_days 14))))  ; org's default

;; Fast keys, as C-c C-t and C-c C-q take them: the config's, else org's own.
(ert-deftest orgwarrior-test-fast-keys ()
  (orgwarrior-test-with-fixtures
    (should (equal (plist-get (orgwarrior-test-ok :op "keywords") :keys) '("t" "n" "a" "w" "d" "k")))
    (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (orgwarrior-test-id "Pay rent")) :keyword_keys)
                   '("t" "n" "a" "w" "d" "k")))
    (let ((keys (plist-get (orgwarrior-test-ok :op "tags") :keys)))
      (should (member '("@home" "h") keys))     ; #+tags: @home(h)
      (should (member '("@phone" "p") keys))    ; org's: its first letter
      (should (member '("parents" "a") keys))   ; p taken: the next free one of its letters
      (should (= (length keys) (length (delete-dups (mapcar #'cadr keys))))))))

(ert-deftest orgwarrior-test-done-logs-without-prompting ()
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Call dentist"))
           (result (orgwarrior-test-ok :op "act" :ids (vector id) :verb "done" :args [])))
      (should (string-match-p "\\`DONE Call dentist" (plist-get (car result) :heading)))
      ;; show's closed: the CLOSED stamp.
      (should (string-match-p "\\`\\[[0-9-]+ [A-Za-z]+ [0-9:]+\\]\\'"
                              (plist-get (orgwarrior-test-ok :op "show" :id id) :closed))))
    (let ((text (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "\\*\\* DONE Call dentist +:@phone:\nCLOSED: \\[" text))
      (should (string-match-p ":LOGBOOK:\n- State \"DONE\" +from \"NEXT\" +\\[" text)))
    (should-not (memq #'org-add-log-note post-command-hook))
    (should-not org-log-setup)))

(ert-deftest orgwarrior-test-done-with-note ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Call dentist"))
                   :verb "done" :args [] :note "Booked for Tuesday")
    (should (string-match-p "from \"NEXT\" +\\[[^]]+\\] \\\\\\\\\n +Booked for Tuesday"
                            (orgwarrior-test-file dir "tasks.org")))))

(ert-deftest orgwarrior-test-note-without-logging-keyword ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Learn to juggle"))
                   :verb "next" :args [] :note "Bought the balls")
    (should (string-match-p "Note taken on .*\n +Bought the balls"
                            (orgwarrior-test-file dir "tasks.org")))))

(ert-deftest orgwarrior-test-wait-needs-no-prompt ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Learn to juggle")) :verb "wait" :args [])
    (should (string-match-p "WAIT Learn to juggle" (orgwarrior-test-file dir "tasks.org")))))

(ert-deftest orgwarrior-test-keyword-on-and-off ()
  (orgwarrior-test-with-fixtures
    (let ((orgw (orgwarrior-test-orgw)))
      ;; A plain heading takes a keyword, and gives it up again.
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids (vector orgw) :verb "todo" :args []))
                                :heading)
                     "TODO Orgwarrior [1/3]"))
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids (vector orgw) :verb "nokeyword" :args []))
                                :heading)
                     "Orgwarrior [1/3]"))
      (should (string-match-p "^\\* Orgwarrior \\[1/3\\]$" (orgwarrior-test-file dir "projects.org")))
      (should (string-match-p "takes no arguments"
                              (orgwarrior-test-error :op "act" :ids (vector orgw) :verb "nokeyword" :args ["x"]))))))

(ert-deftest orgwarrior-test-note-verb ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle")))
      ;; Text from -m (the note) or the arguments; no state change.
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "note" :args ["Bought" "balls"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "note" :args [] :note "Three of them\nred")
      (let ((text (orgwarrior-test-file dir "tasks.org")))
        (should (string-match-p "TODO Learn to juggle" text))
        (should (string-match-p "Note taken on .*\n +Bought balls" text))
        (should (string-match-p "Note taken on .*\n +Three of them\n +red" text)))
      (should (string-match-p "needs the note's text"
                              (orgwarrior-test-error :op "act" :ids (vector id) :verb "note" :args []))))))

(defun orgwarrior-test-wants-note (verb &rest titles)
  (orgwarrior-test-ok :op "wants-note" :verb verb :ids (vconcat (mapcar #'orgwarrior-test-id titles))))

(ert-deftest orgwarrior-test-wants-note ()
  (orgwarrior-test-with-fixtures
    ;; DONE(d@/!) and WAIT(w@/!) ask; NEXT doesn't; leaving WAIT asks only on entry.
    (should (eq t (orgwarrior-test-wants-note "done" "Pay rent")))
    (should (eq t (orgwarrior-test-wants-note "wait" "Pay rent")))
    (should (eq :false (orgwarrior-test-wants-note "next" "Pay rent")))
    (should (eq :false (orgwarrior-test-wants-note "todo" "Package from mom")))
    (should (eq :false (orgwarrior-test-wants-note "sched" "Pay rent")))
    (should (eq t (orgwarrior-test-wants-note "done" "Learn to juggle" "Pay rent")))
    ;; A LOGGING property overrides the keywords' own settings.
    (let ((id (orgwarrior-test-id "Pay rent")))
      (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
        (goto-char (point-min))
        (re-search-forward "Pay rent")
        (org-entry-put nil "LOGGING" "DONE(!)")
        (save-buffer))
      (should (eq :false (orgwarrior-test-ok :op "wants-note" :verb "done" :ids (vector id)))))))

(ert-deftest orgwarrior-test-note-runs-stored-note-hook ()
  ;; Like a hook that mails a reply: an advice reads the note buffer, the
  ;; hook reads the entry; both must see what they would in Emacs.
  (skip-unless (boundp 'org-after-note-stored-hook))  ; Org 9.7 on (not Emacs 29's 9.6)
  (orgwarrior-test-with-fixtures
    (let* ((seen nil) (text nil)
           (grab (lambda () (setq text (buffer-string))))
           (org-after-note-stored-hook
            (list (lambda () (push (list org-log-note-purpose org-log-note-state
                                         (substring-no-properties (org-get-heading t t t t)))
                                   seen)))))
      (advice-add 'org-store-log-note :before grab)
      (unwind-protect
          (orgwarrior-test-ok :op "act" :verb "done" :note "paid in full"
                         :ids (vector (orgwarrior-test-id "Pay rent")))
        (advice-remove 'org-store-log-note grab))
      (should (equal text "paid in full"))
      (should (equal seen '((state "DONE" "Pay rent [0/1]")))))))

(ert-deftest orgwarrior-test-priority ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle")))
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :priority))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["b"])
      (should (string-match-p "TODO \\[#B\\] Learn to juggle" (orgwarrior-test-file dir "tasks.org")))
      (should (equal "B" (plist-get (orgwarrior-test-ok :op "show" :id id) :priority)))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["up"])
      (should (equal "A" (plist-get (orgwarrior-test-ok :op "show" :id id) :priority)))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["down"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["down"])
      (should (equal "C" (plist-get (orgwarrior-test-ok :op "show" :id id) :priority)))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["none"])
      (should (string-match-p "TODO Learn to juggle" (orgwarrior-test-file dir "tasks.org")))
      ;; Past the end, removed (as org's S-up does).
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["a"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "pri" :args ["up"])
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :priority))
      (should (string-match-p "one of A B C"
                              (orgwarrior-test-error :op "act" :ids (vector id) :verb "pri" :args ["Z"]))))))

(ert-deftest orgwarrior-test-multiple-ids ()
  (orgwarrior-test-with-fixtures
    (let ((result (orgwarrior-test-ok :op "act"
                                 :ids (vector (orgwarrior-test-id "Learn to juggle")
                                              (orgwarrior-test-id "Pay rent")
                                              (orgwarrior-test-id "Write a README"))
                                 :verb "next" :args [])))
      (should (= 3 (length result))))
    (should (string-match-p "NEXT Learn to juggle" (orgwarrior-test-file dir "tasks.org")))
    (should (string-match-p "NEXT Pay rent" (orgwarrior-test-file dir "tasks.org")))
    (should (string-match-p "\\*\\*\\* NEXT Write a README" (orgwarrior-test-file dir "projects.org")))))

(ert-deftest orgwarrior-test-bad-id-changes-nothing ()
  (orgwarrior-test-with-fixtures
    (let ((before (orgwarrior-test-file dir "tasks.org")))
      (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Learn to juggle") "zz")
                        :verb "done" :args [])
      (should (equal before (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-unknown-verb ()
  (orgwarrior-test-with-fixtures
    (should (string-match-p "Unknown verb"
                            (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Pay rent"))
                                              :verb "frobnicate" :args [])))))

(ert-deftest orgwarrior-test-unsaved-buffer-guard ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle"))
          (before (orgwarrior-test-file dir "tasks.org")))
      (with-current-buffer (find-buffer-visiting (expand-file-name "tasks.org" dir))
        (goto-char (point-max))
        (insert "half-finished edit"))
      (should (string-match-p "unsaved changes"
                              (orgwarrior-test-error :op "act" :ids (vector id) :verb "done" :args [])))
      (should (equal before (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-stale-buffer-reverted ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-id "Learn to juggle")   ; visits tasks.org
    (sleep-for 0.01)
    ;; Syncthing writes the file behind Emacs's back.
    (with-temp-file (expand-file-name "tasks.org" dir)
      (insert (replace-regexp-in-string "Learn to juggle" "Learn to unicycle"
                                        (orgwarrior-test-file dir "tasks.org"))))
    (set-file-times (expand-file-name "tasks.org" dir) (time-add (current-time) 10))
    (should (orgwarrior-test-id "Learn to unicycle"))))

(ert-deftest orgwarrior-test-actions-keep-blank-lines ()
  "Entries separated by blank lines (as many files have them) stay that way."
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "tasks.org" dir)))
      (with-temp-file file
        (insert (replace-regexp-in-string
                 "\n\\*\\* " "\n\n** " (orgwarrior-test-file dir "tasks.org"))))
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Call dentist")) :verb "done" :note "n")
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Pay rent")) :verb "sched" :args ["+1d"])
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Package from mom")) :verb "next")
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "juggle")) :verb "tag" :args ["+x"])
      (orgwarrior-test-ok :op "add" :text "new thing" :file file :heading "Tasks")
      (let ((text (orgwarrior-test-file dir "tasks.org")))
        (should (= 7 (with-temp-buffer (insert text) (how-many "\n\n\\*\\* " (point-min)))))
        (should-not (string-match-p "[^\n]\n\\*\\* " text))))))


;;;; Dates

(ert-deftest orgwarrior-test-sched-and-due ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle"))
          (tomorrow (format-time-string "%Y-%m-%d" (time-add (current-time) (days-to-time 1)))))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "sched" :args ["tomorrow"])
      (should (string-match-p (concat "juggle :someday:\nSCHEDULED: <" tomorrow)
                              (orgwarrior-test-file dir "tasks.org")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "due" :args ["2026-12-25"])
      (should (string-match-p "DEADLINE: <2026-12-25 "
                              (orgwarrior-test-file dir "tasks.org")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "sched" :args ["none"])
      (should-not (string-match-p "juggle :someday:\nSCHEDULED"
                                  (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "Can't parse date"
                              (orgwarrior-test-error :op "act" :ids (vector id)
                                                :verb "sched" :args ["fridge"])))
      ;; Org would read only the fri, the rest skipped.
      (should (string-match-p "Can't parse date"
                              (orgwarrior-test-error :op "act" :ids (vector id)
                                                :verb "sched" :args ["dentist fri"]))))))

;; Ranges come from org; repeaters and warnings only after a date.
(ert-deftest orgwarrior-test-sched-ranges-and-repeaters ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle"))
          (sched (lambda (&rest args)
                   (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Learn to juggle"))
                                  :verb "sched" :args (vconcat args))
                   (with-temp-buffer
                     (insert (orgwarrior-test-file dir "tasks.org"))
                     (goto-char (point-min))
                     (re-search-forward "juggle :someday:\nSCHEDULED: \\(<[^>]*>\\)")
                     (match-string 1)))))
      (should (string-match-p "\\`<2026-12-25 Fri 14:00-15:30>\\'"
                              (funcall sched "2026-12-25" "14:00-15:30")))
      (should (string-match-p "\\`<2026-12-25 Fri 14:00-15:00>\\'"
                              (funcall sched "2026-12-25 2pm+1h")))
      (should (string-match-p "\\`<2026-12-25 Fri 09:00 \\.\\+1w -2d>\\'"
                              (funcall sched "2026-12-25 9:00 .+1w -2d")))
      ;; A new repeater replaces the old one; none given keeps it, as in Emacs.
      (should (string-match-p "\\`<2026-12-26 Sat \\+\\+1m>\\'"
                              (funcall sched "2026-12-26" "++1m")))
      (should (string-match-p "\\`<2026-12-27 Sun \\+\\+1m>\\'"
                              (funcall sched "2026-12-27")))
      ;; A whole timestamp is exact: no repeater means none.
      (should (string-match-p "\\`<2026-12-28 Mon 10:00-11:00>\\'"
                              (funcall sched "<2026-12-28 10:00-11:00>")))
      (funcall sched "2026-12-28 .+1w -2d")
      (should (string-match-p "\\`<2026-12-29 Tue -1d>\\'"
                              (funcall sched "<2026-12-29 -1d>")))
      ;; Alone, +1w is a date.
      (should (string-match-p (concat "\\`<" (format-time-string "%Y-%m-%d"
                                                               (time-add nil (days-to-time 7))))
                              (funcall sched "+1w")))
      (should (equal (orgwarrior-test-id "Learn to juggle") id)))))

;; An event's date: the plain timestamp on the line under its drawers, a
;; field of its own; one further down is the text's.
(ert-deftest orgwarrior-test-when ()
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "calendar.org" dir))
           (id (plist-get (orgwarrior-test-ok :op "add" :file file :event t :captured t
                                         :fields '(:title "Hang out" :when "2026-12-25 12:00-16:00"
                                                   :body "At Tony's\n<2026-12-31 Thu> too"))
                          :id))
           (when (lambda (&rest args)
                   (orgwarrior-test-ok :op "act" :ids (vector id) :verb "when" :args (vconcat args))
                   (orgwarrior-test-file dir "calendar.org")))
           (show (orgwarrior-test-ok :op "show" :id id :html t)))
      (should (equal (plist-get show :when) "<2026-12-25 Fri 12:00-16:00>"))
      (should (string-match-p "\\`<2026-12-25"
                              (plist-get (nth (plist-get show :when_line) (plist-get show :lines)) :text)))
      (should-not (string-match-p "2026-12-25" (plist-get show :html)))
      (should (string-match-p "At Tony" (plist-get show :html)))
      (should (string-match-p ":END:\n\n<2026-12-26 Sat 10:00>\nAt Tony's\n<2026-12-31 Thu> too"
                              (funcall when "2026-12-26" "10:00")))
      ;; Plain words keep the repeater, a whole timestamp is exact, as sched.
      (funcall when "2026-12-26 +1y")
      (should (string-match-p "\n<2026-12-27 Sun \\+1y>\nAt" (funcall when "2026-12-27")))
      (should (string-match-p "\n<2026-12-28 Mon>\nAt" (funcall when "<2026-12-28>")))
      (should (string-match-p ":END:\n\nAt Tony's\n<2026-12-31 Thu> too" (funcall when "none")))
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :when))
      ;; None there: added under the drawers, the text's own left alone.
      (should (string-match-p ":END:\n\n<2027-01-02 Sat>\nAt Tony's\n<2026-12-31 Thu> too"
                              (funcall when "2027-01-02")))
      (should (string-match-p "Can't parse date"
                              (orgwarrior-test-error :op "act" :ids (vector id) :verb "when" :args ["fridge"])))
      (should (orgwarrior-test-error :op "act" :ids (vector id) :verb "when" :args [])))
    ;; Under the planning line.
    (let ((id (orgwarrior-test-id "Learn to juggle")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "sched" :args ["2026-12-25"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "when" :args ["2026-12-26"])
      (should (string-match-p "juggle :someday:\nSCHEDULED: <2026-12-25 Fri>\n<2026-12-26 Sat>\n"
                              (orgwarrior-test-file dir "tasks.org"))))))

;; A file that isn't writable: a calendar a script exports to org.
(ert-deftest orgwarrior-test-read-only-file ()
  (orgwarrior-test-with-fixtures
    (let* ((before (orgwarrior-test-file dir "projects.org"))
           (scaffold (orgwarrior-test-id "Scaffold the package"))
           (batteries (orgwarrior-test-id "Buy batteries")))
      (set-file-modes (expand-file-name "projects.org" dir) #o444)
      (should (eq (plist-get (orgwarrior-test-ok :op "show" :id scaffold) :read_only) t))
      (should (eq (plist-get (orgwarrior-test-ok :op "show" :id batteries) :read_only) :false))
      (should (equal (plist-get (orgwarrior-test-ok :op "show" :id batteries) :category) "Inbox"))
      (let ((lines (orgwarrior-test-ok :op "view" :kind "all"))
            (read-only (lambda (title lines)
                         (plist-get (seq-find (lambda (l) (string-match-p title (plist-get l :text))) lines)
                                    :read_only))))
        (should (eq (funcall read-only "Scaffold" lines) t))
        (should-not (funcall read-only "Buy batteries" lines)))
      (should (eq (plist-get (car (plist-get (orgwarrior-test-ok :op "outline" :file "projects.org") :children))
                             :read_only)
                  t))
      (should (eq (plist-get (seq-find (lambda (e) (equal (plist-get e :title) "Scaffold the package"))
                                       (orgwarrior-test-ok :op "calendar" :days 30))
                             :read_only)
                  t))
      ;; Every change refused, before anything changes.
      (dolist (req `((:op "act" :ids ,(vector scaffold) :verb "done")
                     (:op "act" :ids ,(vector batteries scaffold) :verb "sched" :args ["fri"])
                     (:op "act" :ids ,(vector scaffold) :verb "refile" :args ["tasks.org"])
                     (:op "set-entry" :id ,scaffold :text "x" :old "")
                     (:op "clock-in" :id ,scaffold)
                     (:op "add" :text "New" :to "projects.org")))
        (should (string-match-p "projects.org is read only" (apply #'orgwarrior-test-error req))))
      (should (equal (orgwarrior-test-file dir "projects.org") before))
      (should-not (string-match-p "SCHEDULED" (orgwarrior-test-file dir "inbox.org")))
      ;; Nothing goes there either.
      (should (equal (orgwarrior-test-ok :op "refile-targets" :ids (vector batteries))
                     '("inbox.org" "tasks.org" "tasks.org › Tasks"))))))

(ert-deftest orgwarrior-test-reschedule-logs-without-prompting ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Call dentist")) :verb "sched" :args ["+3d"])
    (should (string-match-p "Rescheduled from \"\\[" (orgwarrior-test-file dir "tasks.org")))
    (should-not (memq #'org-add-log-note post-command-hook))))


;;;; Tags

(ert-deftest orgwarrior-test-tag ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Call dentist"))
                   :verb "tag" :args ["+urgent" "-@phone"])
    (let ((text (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "NEXT Call dentist +:urgent:\n" text)))))

(ert-deftest orgwarrior-test-tags ()
  (orgwarrior-test-with-fixtures
    (let ((tags (orgwarrior-test-ok :op "tags")))
      ;; tasks.org's #+tags: a { } group, then a plain line; the rest are in use only.
      (should (equal (plist-get tags :groups)
                     '((:exclusive t :tags ("@home" "@phone" "@computer"))
                       (:exclusive :false :tags ("finances" "parents")))))
      ;; inbox is inbox.org's #+filetags: not something to give a task.
      (should (equal (plist-get tags :other) '("recurring" "someday"))))))

(ert-deftest orgwarrior-test-tag-exclusive ()
  (orgwarrior-test-with-fixtures
    (let ((id (vector (orgwarrior-test-id "Call dentist"))))  ; :@phone:
      ;; A tag from the { } group replaces the one there; others are kept.
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids id :verb "tag"
                                                    :args ["+@home" "+finances"]))
                                :heading)
                     "NEXT Call dentist :@home:finances:"))
      ;; Two from the group at once: the last wins.
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids id :verb "tag"
                                                    :args ["+@phone" "+@computer"]))
                                :heading)
                     "NEXT Call dentist :finances:@computer:")))))


;;;; Rename

;; Keyword, tags and cookies stay; the ID follows the title.
(ert-deftest orgwarrior-test-rename ()
  (orgwarrior-test-with-fixtures
    (let* ((old (orgwarrior-test-id "Pay rent"))
           (r (car (orgwarrior-test-ok :op "act" :ids (vector old) :verb "rename"
                                  :args ["Pay" "the" "rent"]))))
      (should (equal (plist-get r :old) old))
      (should (equal (plist-get r :id) (orgwarrior-test-id "Pay the rent")))
      (should (string-match-p "^\\*\\* TODO Pay the rent \\[0/1\\] +:finances:$"
                              (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "Transfer from checking" (orgwarrior-test-file dir "tasks.org"))))
    (let ((id (orgwarrior-test-id "Call dentist")))
      (dolist (bad '(["DONE" "x"] ["x" ":y:"] [] ["  "]))
        (should (orgwarrior-test-error :op "act" :ids (vector id) :verb "rename" :args bad)))
      (should (string-match-p "one task" (orgwarrior-test-error :op "act" :ids (vector id (orgwarrior-test-id "Learn to juggle"))
                                                           :verb "rename" :args ["x"])))
      (should (string-match-p "NEXT Call dentist" (orgwarrior-test-file dir "tasks.org"))))))


;;;; Refile

(defun orgwarrior-test-refile (title target)
  (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id title)) :verb "refile"
                 :args (vector target)))

(ert-deftest orgwarrior-test-refile ()
  (orgwarrior-test-with-fixtures
    (let* ((old (orgwarrior-test-id "Buy batteries"))
           (result (car (orgwarrior-test-refile "Buy batteries" "tasks"))))
      (should (equal (plist-get result :old) old))
      (should (equal (plist-get result :target) "tasks.org › Tasks"))
      (should (equal (plist-get result :heading) "TODO Buy batteries"))
      (should-not (equal (plist-get result :id) old))
      (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (plist-get result :id)) :file)
                     "tasks.org"))
      (should-not (string-match-p "Buy batteries" (orgwarrior-test-file dir "inbox.org")))
      ;; The inbox filetag no longer applies.
      (should-not (seq-find (lambda (l) (string-match-p "Buy batteries" (plist-get l :text)))
                            (orgwarrior-test-ok :op "view" :kind "tags" :arg "inbox"))))))

(ert-deftest orgwarrior-test-refile-targets ()
  (orgwarrior-test-with-fixtures
    ;; From the inbox, Tasks (tasks.org) and Orgwarrior both contain "a".
    (should (string-match-p "\"a\" matches several refile targets:\n  tasks.org › Tasks\n  projects.org › Orgwarrior"
                            (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Buy batteries"))
                                              :verb "refile" :args ["a"])))
    ;; Part of a name; the file › path label shows where it went.
    (should (equal (plist-get (car (orgwarrior-test-refile "Buy batteries" "warr")) :target)
                   "projects.org › Orgwarrior"))
    (let ((id (vector (orgwarrior-test-id "Learn to juggle"))))
      (should (string-match-p "needs a target:\n  tasks.org\n  projects.org\n  tasks.org › Tasks\n  projects.org › Orgwarrior"
                              (orgwarrior-test-error :op "act" :ids id :verb "refile")))
      (should (string-match-p "No refile target matches \"zzz\""
                              (orgwarrior-test-error :op "act" :ids id :verb "refile" :args ["zzz"])))
      ;; Already there: reported, not moved.
      (let ((result (car (orgwarrior-test-ok :op "act" :ids id :verb "refile" :args ["tasks"]))))
        (should (equal (plist-get result :already) "tasks.org › Tasks"))
        (should (equal (plist-get result :id) (aref id 0)))
        (should-not (plist-get result :old)))
      (should (string-match-p "takes no note"
                              (orgwarrior-test-error :op "act" :ids id :verb "refile" :args ["warr"]
                                                :note "x"))))))

(ert-deftest orgwarrior-test-refile-several ()
  (orgwarrior-test-with-fixtures
    (let ((results (orgwarrior-test-ok :op "act" :verb "refile" :args ["orgwarrior"]
                                  :ids (vector (orgwarrior-test-id "Call dentist")
                                               (orgwarrior-test-id "Learn to juggle")))))
      (should (= 2 (length results)))
      (should (string-match-p "\\*\\* NEXT Call dentist.*\nSCHEDULED: .*\n\\*\\* TODO Learn to juggle.*\n\\'"
                              (orgwarrior-test-file dir "projects.org"))))))

(ert-deftest orgwarrior-test-refile-mixed ()
  (orgwarrior-test-with-fixtures
    ;; "tasks" names inbox.org's Tasks and tasks.org's; the file decides.  The
    ;; task already there doesn't block the one that moves.
    (let ((results (orgwarrior-test-ok :op "act" :verb "refile" :args ["tasks"]
                                  :ids (vector (orgwarrior-test-id "Buy batteries")
                                               (orgwarrior-test-id "Learn to juggle")))))
      (should (equal (mapcar (lambda (r) (or (plist-get r :already) (plist-get r :target)))
                             results)
                     '("tasks.org › Tasks" "tasks.org › Tasks")))
      (should (plist-get (seq-find (lambda (r) (plist-get r :old)) results) :old))
      (should-not (string-match-p "Buy batteries" (orgwarrior-test-file dir "inbox.org")))
      (should (string-match-p "Buy batteries" (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-refile-target-labels ()
  (orgwarrior-test-with-fixtures
    (let ((batteries (orgwarrior-test-id "Buy batteries"))
          (juggle (orgwarrior-test-id "Learn to juggle")))
      ;; Each file's top level first; where the task already is isn't offered.
      (should (equal (orgwarrior-test-ok :op "refile-targets" :ids (vector batteries))
                     '("inbox.org" "tasks.org" "projects.org" "tasks.org › Tasks" "projects.org › Orgwarrior")))
      (should (equal (orgwarrior-test-ok :op "refile-targets" :ids (vector batteries juggle))
                     '("inbox.org" "tasks.org" "projects.org"
                       "inbox.org › Tasks" "tasks.org › Tasks" "projects.org › Orgwarrior")))
      ;; A label is a target as is.
      (should (equal (plist-get (car (orgwarrior-test-refile "Learn to juggle" "projects.org › Orgwarrior")) :target)
                     "projects.org › Orgwarrior")))))

;; A file's top level, which org offers only with `org-refile-use-outline-path'
;; set to `file': the way to move a heading up to level 1.
(ert-deftest orgwarrior-test-refile-top-level ()
  (orgwarrior-test-with-fixtures
    (let ((r (car (orgwarrior-test-refile "Learn to juggle" "projects.org"))))
      (should (equal (plist-get r :target) "projects.org"))
      (should (string-match-p "\n\\* TODO Learn to juggle" (orgwarrior-test-file dir "projects.org")))
      ;; Already there.
      (should (equal (plist-get (car (orgwarrior-test-ok :op "act" :ids (vector (plist-get r :id))
                                                         :verb "refile" :args ["projects.org"]))
                                :already)
                     "projects.org")))
    ;; A name both a file and a heading have: the heading.
    (should (equal (plist-get (car (orgwarrior-test-refile "Buy batteries" "tasks")) :target)
                   "tasks.org › Tasks"))))

;; A new heading: made, then refiled into, in one act.
(ert-deftest orgwarrior-test-refile-new ()
  (orgwarrior-test-with-fixtures
    (let ((batteries (orgwarrior-test-id "Buy batteries")))
      ;; Every file in org-refile-targets, then the targets.
      (should (equal (orgwarrior-test-ok :op "refile-places" :ids (vector batteries))
                     '("inbox.org" "tasks.org" "projects.org"
                       "inbox.org › Tasks" "tasks.org › Tasks" "projects.org › Orgwarrior")))
      (let ((r (car (orgwarrior-test-ok :op "act" :ids (vector batteries) :verb "refile"
                                        :args ["projects.org"]
                                        :new '((title . "Kitchen reno [/]") (captured . t))))))
        (should (equal (plist-get r :old) batteries))
        (should (equal (plist-get r :target) "projects.org › Kitchen reno"))
        (should (string-match-p
                 (concat "\n\n\\* Kitchen reno \\[0/1\\]\n:PROPERTIES:\n:CAPTURED: \\[[^]]+\\]\n:END:\n"
                         "\\*\\* TODO Buy batteries\n")
                 (orgwarrior-test-file dir "projects.org")))
        ;; Its page: no keyword, the task as its child; the task's, its parent.
        (let* ((parents (plist-get (orgwarrior-test-ok :op "show" :id (plist-get r :id)) :parents))
               (reno (orgwarrior-test-ok :op "show" :id (plist-get (car parents) :id))))
          (should (equal (mapcar (lambda (p) (plist-get p :title)) parents) '("Kitchen reno")))
          (should-not (plist-get reno :keyword))
          (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get reno :children))
                         (list (plist-get r :id)))))
        ;; Now a target itself.
        (should (equal (plist-get (car (orgwarrior-test-refile "Learn to juggle" "reno")) :target)
                       "projects.org › Kitchen reno"))
        (should (string-match-p "Kitchen reno \\[0/2\\]" (orgwarrior-test-file dir "projects.org")))))
    ;; Under a target, as its last child.
    (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Call dentist")) :verb "refile"
                        :args ["tasks.org › Tasks"] :new '((title . "Health")))
    (should (string-match-p "\\*\\* Health\n\\*\\*\\* NEXT Call dentist"
                            (orgwarrior-test-file dir "tasks.org")))
    (let ((id (vector (orgwarrior-test-id "Pay rent"))))
      (should (string-match-p "already has \"Health\""
                              (orgwarrior-test-error :op "act" :ids id :verb "refile" :args ["tasks.org › Tasks"]
                                                     :new '((title . "Health")))))
      (should (string-match-p "needs a title"
                              (orgwarrior-test-error :op "act" :ids id :verb "refile" :args ["projects.org"]
                                                     :new '((title . " ")))))
      (should (string-match-p "would read it as one"
                              (orgwarrior-test-error :op "act" :ids id :verb "refile" :args ["projects.org"]
                                                     :new '((title . "TODO list")))))
      (should (string-match-p "Only refile"
                              (orgwarrior-test-error :op "act" :ids id :verb "done" :args []
                                                     :new '((title . "X")))))
      (should (string-match-p "needs a target:\n  tasks.org\n  projects.org\n"
                              (orgwarrior-test-error :op "act" :ids id :verb "refile"
                                                     :new '((title . "X"))))))))

(ert-deftest orgwarrior-test-refile-guards ()
  (orgwarrior-test-with-fixtures
    ;; Unsaved changes in the target file: refuse, move nothing.
    (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
      (goto-char (point-max))
      (insert "half-typed")
      (should (string-match-p "unsaved changes"
                              (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Buy batteries"))
                                                :verb "refile" :args ["tasks"])))
      (should (string-match-p "Buy batteries" (orgwarrior-test-file dir "inbox.org")))
      (set-buffer-modified-p nil)
      (revert-buffer t t t))
    ;; The user's save-everything hook doesn't run: other unsaved edits stay unsaved.
    (let* ((called nil)
           (org-after-refile-insert-hook (list (lambda () (setq called t)))))
      (orgwarrior-test-refile "Buy batteries" "tasks")
      (should-not called))))


;;;; Order

(defun orgwarrior-test-titles (children)
  (mapcar (lambda (c) (plist-get c :text)) children))

(ert-deftest orgwarrior-test-outline-and-reorder ()
  (orgwarrior-test-with-fixtures
    (let* ((outline (orgwarrior-test-ok :op "outline" :file "projects.org"))
           (orgw (plist-get (car (plist-get outline :children)) :id)))
      (should (equal (orgwarrior-test-titles (plist-get outline :children)) '("Orgwarrior [1/3]")))
      (should (string-match-p "No agenda file" (orgwarrior-test-error :op "outline" :file "nope.org")))
      ;; A heading's children, each with its subtree and body.
      (let* ((kids (plist-get (orgwarrior-test-ok :op "show" :id orgw) :children))
             (ids (mapcar (lambda (c) (plist-get c :id)) kids))
             (new (vector (nth 2 ids) (nth 0 ids) (nth 1 ids))))
        (should (equal (orgwarrior-test-titles
                        (orgwarrior-test-ok :op "reorder" :parent orgw :ids new))
                       '("Publish to PyPI" "Write the spec" "Scaffold the package")))
        (should (string-match-p
                 (concat "\\* Orgwarrior \\[1/3\\]\n\\*\\* TODO Publish to PyPI\n\\*\\*\\* TODO Pick a license\n"
                         "\\*\\*\\* TODO Write a README\n\\*\\* DONE Write the spec\n"
                         "\\*\\* NEXT Scaffold the package :@computer:\nSCHEDULED: <[^>]+>\n\\'")
                 (orgwarrior-test-file dir "projects.org")))
        ;; Not all of them, or not theirs: refused, nothing moved.
        (should (string-match-p "changed since"
                                (orgwarrior-test-error :op "reorder" :parent orgw :ids (vector (aref new 0)))))
        (should (string-match-p "changed since"
                                (orgwarrior-test-error :op "reorder" :parent orgw
                                                       :ids (vconcat new (list (orgwarrior-test-id "Pay rent"))))))
        ;; Up and down: one place, among its siblings.
        (should (string-match-p "Scaffold"
                                (plist-get (car (orgwarrior-test-ok :op "act" :ids (vector (nth 1 ids)) :verb "up" :args []))
                                           :heading)))
        (should (equal (orgwarrior-test-titles (plist-get (orgwarrior-test-ok :op "show" :id orgw) :children))
                       '("Publish to PyPI" "Scaffold the package" "Write the spec")))
        (should (string-match-p "Already the first"
                                (orgwarrior-test-error :op "act" :ids (vector (nth 2 ids)) :verb "up" :args [])))
        (orgwarrior-test-ok :op "act" :ids (vector (nth 2 ids)) :verb "down" :args [])
        (should (equal (orgwarrior-test-titles (plist-get (orgwarrior-test-ok :op "show" :id orgw) :children))
                       '("Scaffold the package" "Publish to PyPI" "Write the spec")))))
    ;; A file's top level, blank lines between staying where they were.
    (let ((tasks (plist-get (orgwarrior-test-ok :op "outline" :file "tasks.org") :children)))
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Pay rent")) :verb "refile"
                          :args ["tasks.org"] :new '((title . "Bills")))
      (let ((ids (mapcar (lambda (c) (plist-get c :id))
                         (plist-get (orgwarrior-test-ok :op "outline" :file "tasks.org") :children))))
        (should (= (length ids) (1+ (length tasks))))
        (should (equal (orgwarrior-test-titles
                        (orgwarrior-test-ok :op "reorder" :file "tasks.org" :ids (vconcat (reverse ids))))
                       '("Bills" "Tasks")))
        (should (string-match-p "\\`#\\+[^*]*\n\\* Bills\n\\(?:.*\n\\)*?\\*\\* TODO Pay rent.*\n\\(?:.*\n\\)*\n\\* Tasks\n"
                                (orgwarrior-test-file dir "tasks.org")))))))

;; A file's outline: the whole tree, each heading with its children.
(ert-deftest orgwarrior-test-outline-tree ()
  (orgwarrior-test-with-fixtures
    (let* ((top (car (plist-get (orgwarrior-test-ok :op "outline" :file "projects.org") :children)))
           (kids (plist-get top :children))
           (publish (seq-find (lambda (c) (string-match-p "Publish" (plist-get c :text))) kids)))
      (should (string-match-p "Orgwarrior" (plist-get top :text)))
      (should (equal (orgwarrior-test-titles kids) '("Write the spec" "Scaffold the package" "Publish to PyPI")))
      (should (equal (orgwarrior-test-titles (plist-get publish :children)) '("Pick a license" "Write a README")))
      (should-not (plist-get (car (plist-get publish :children)) :children)))))

;; Promote: out of its parent to right after it, its later siblings
;; staying; demote: under the sibling above.  Cookies on both sides.
(ert-deftest orgwarrior-test-promote-demote ()
  (orgwarrior-test-with-fixtures
    (let* ((orgw (orgwarrior-test-orgw))
           (scaffold (orgwarrior-test-id "Scaffold the package"))
           (move (lambda (id verb) (car (orgwarrior-test-ok :op "act" :ids (vector id) :verb verb :args []))))
           (kids (lambda (id) (orgwarrior-test-titles (plist-get (orgwarrior-test-ok :op "show" :id id) :children))))
           (show (orgwarrior-test-ok :op "show" :id scaffold)))
      (should (equal (list (plist-get show :prev) (plist-get show :next)) '("Write the spec" "Publish to PyPI")))
      (should-not (plist-get (funcall move scaffold "promote") :parent))
      (should (equal (funcall kids orgw) '("Write the spec" "Publish to PyPI")))
      (should (equal (orgwarrior-test-titles (plist-get (orgwarrior-test-ok :op "outline" :file "projects.org") :children))
                     '("Orgwarrior [1/2]" "Scaffold the package")))
      (should (string-match-p "Already at the top level"
                              (orgwarrior-test-error :op "act" :ids (vector scaffold) :verb "promote" :args [])))
      (should (equal (plist-get (funcall move scaffold "demote") :parent) "Orgwarrior"))
      (should (equal (funcall kids orgw) '("Write the spec" "Publish to PyPI" "Scaffold the package")))
      (should (string-match-p "^\\* Orgwarrior \\[1/3\\]$" (orgwarrior-test-file dir "projects.org")))
      (should (string-match-p "No heading above"
                              (orgwarrior-test-error :op "act" :ids (vector (orgwarrior-test-id "Pick a license"))
                                                     :verb "demote" :args [])))
      (should (equal (plist-get (funcall move (orgwarrior-test-id "Write a README") "demote") :parent)
                     "Pick a license")))))

;; Org leaves a parent's [/] as it was when a child arrives or leaves.
(ert-deftest orgwarrior-test-cookies-follow ()
  (orgwarrior-test-with-fixtures
    (let ((cookie (lambda () (let ((text (orgwarrior-test-file dir "projects.org")))
                               (and (string-match "^\\* Orgwarrior \\(\\[[0-9/]*\\]\\)" text)
                                    (match-string 1 text))))))
      (orgwarrior-test-add dir "Tag a release"
                           :under (plist-get (car (plist-get (orgwarrior-test-ok :op "outline" :file "projects.org")
                                                             :children))
                                             :id))
      (should (equal (funcall cookie) "[1/4]"))
      (orgwarrior-test-ok :op "act" :verb "refile" :args ["tasks.org"]
                          :ids (vector (plist-get (seq-find (lambda (l) (string-match-p "Write the spec" (plist-get l :text)))
                                                            (orgwarrior-test-ok :op "view" :kind "words" :arg "done"))
                                                  :id)))
      (should (equal (funcall cookie) "[0/3]"))
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Scaffold the package"))
                          :verb "archive" :args [])
      (should (equal (funcall cookie) "[0/2]"))
      (orgwarrior-test-ok :op "act" :ids (vector (orgwarrior-test-id "Tag a release"))
                          :verb "kill" :args [])
      (should (equal (funcall cookie) "[0/1]")))))


;;;; Kill

(defun orgwarrior-test-kill (&rest titles)
  (orgwarrior-test-ok :op "act" :verb "kill" :ids (vconcat (mapcar #'orgwarrior-test-id titles))))

(ert-deftest orgwarrior-test-kill-keeps-blank-lines ()
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "tasks.org" dir)))
      (with-temp-file file
        (insert (replace-regexp-in-string
                 "\n\\*\\* " "\n\n** " (orgwarrior-test-file dir "tasks.org"))))
      (let ((result (car (orgwarrior-test-kill "Package from mom"))))
        (should (equal (plist-get result :heading) "WAIT Package from mom :parents:")))
      (let ((text (orgwarrior-test-file dir "tasks.org")))
        (should-not (string-match-p "Package from mom" text))
        (should (string-match-p "SCHEDULED: <[^>]+>\n\n\\*\\* TODO Take out trash" text))
        (should-not (string-match-p "[^\n]\n\\*\\* " text))
        (should-not (string-match-p "\n\n\n" text))))))

(ert-deftest orgwarrior-test-kill-last-entry ()
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "tasks.org" dir)))
      (with-temp-file file
        (insert (replace-regexp-in-string
                 "\n\\*\\* " "\n\n** " (orgwarrior-test-file dir "tasks.org"))))
      (orgwarrior-test-kill "Learn to juggle")
      (should (string-match-p "\\+1w>\n\\'" (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-kill-subtree-and-nested ()
  (orgwarrior-test-with-fixtures
    ;; The parent's subtree takes its child; both are reported, nothing else goes;
    ;; the cookie counts what's left.
    (let ((results (orgwarrior-test-kill "Pick a license" "Publish to PyPI")))
      (should (= 2 (length results)))
      (should (equal (orgwarrior-test-file dir "projects.org")
                     (orgwarrior-fixture--expand-dates
                      "#+title: Projects\n\n* Orgwarrior [1/2]\n** DONE Write the spec\n** NEXT Scaffold the package :@computer:\nSCHEDULED: <{{+1}}>\n"))))))

(ert-deftest orgwarrior-test-kill-guards ()
  (orgwarrior-test-with-fixtures
    (let ((id (vector (orgwarrior-test-id "Learn to juggle"))))
      (should (string-match-p "takes no arguments"
                              (orgwarrior-test-error :op "act" :verb "kill" :ids id :args ["x"])))
      (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
        (goto-char (point-max))
        (insert "half-typed")
        (should (string-match-p "unsaved changes"
                                (orgwarrior-test-error :op "act" :verb "kill" :ids id))))
      (should (string-match-p "Learn to juggle" (orgwarrior-test-file dir "tasks.org"))))))


;;;; Archive

(defun orgwarrior-test-archive (&rest ids)
  (orgwarrior-test-ok :op "act" :verb "archive" :ids (vconcat ids)))

(ert-deftest orgwarrior-test-archive ()
  (orgwarrior-test-with-fixtures
    (let* ((done (seq-find (lambda (l) (string-match-p "Write the spec" (plist-get l :text)))
                           (orgwarrior-test-ok :op "view" :kind "words" :arg "done")))
           (id (plist-get done :id))
           (result (car (orgwarrior-test-archive id))))
      (should (equal (plist-get result :heading) "DONE Write the spec"))
      (should (equal (plist-get result :target) "projects.org_archive"))
      (should-not (string-match-p "Write the spec" (orgwarrior-test-file dir "projects.org")))
      (let ((archive (orgwarrior-test-file dir "projects.org_archive")))
        (should (string-match-p "\\* DONE Write the spec" archive))
        (should (string-match-p ":ARCHIVE_TIME:" archive)))
      ;; Gone from the agenda files, so the ID no longer resolves: the archive
      ;; file is part of its hash.
      (should (string-match-p "No task" (orgwarrior-test-error :op "show" :id id))))))

(ert-deftest orgwarrior-test-archives ()
  (orgwarrior-test-with-fixtures
    (let ((juggle (orgwarrior-test-id "Learn to juggle"))
          (line-of (lambda (lines) (seq-find (lambda (l) (and (plist-get l :id)
                                                              (string-match-p "juggle" (plist-get l :text))))
                                             lines))))
      (orgwarrior-test-ok :op "act" :ids (vector juggle) :verb "done" :args [] :note "Did it")
      (orgwarrior-test-archive juggle)
      ;; What was closed today, archived or not; empty days and the diary left out.
      (let* ((closed (orgwarrior-test-ok :op "view" :kind "closed" :arg "week"))
             (line (funcall line-of closed)))
        (should (string-match-p "Closed: +DONE Learn to juggle" (plist-get line :text)))
        (should-not (cl-some (lambda (l) (string-match-p "Diary\\|Batteries" (plist-get l :text))) closed))
        ;; Its archived ID shows it, but acts on nothing.
        (should (equal (plist-get (orgwarrior-test-ok :op "show" :id (plist-get line :id)) :file)
                       "tasks.org_archive"))
        (should (string-match-p "No task" (orgwarrior-test-error :op "act" :ids (vector (plist-get line :id))
                                                                 :verb "todo" :args []))))
      (should-not (funcall line-of (orgwarrior-test-ok :op "view" :kind "closed" :arg "lastyear")))
      (should (string-match-p "Not a span" (orgwarrior-test-error :op "view" :kind "closed" :arg "soon")))
      ;; A search takes in the archives only when asked.
      (should-not (funcall line-of (orgwarrior-test-ok :op "view" :kind "search" :arg "juggle")))
      (should (plist-get (funcall line-of (orgwarrior-test-ok :op "view" :kind "search" :arg "juggle"
                                                              :archive t))
                         :id))
      (should (funcall line-of (orgwarrior-test-ok :op "view" :kind "tags" :arg "+someday" :archive t))))))

(ert-deftest orgwarrior-test-archive-subtree-and-nested ()
  (orgwarrior-test-with-fixtures
    (let ((results (orgwarrior-test-archive (orgwarrior-test-id "Pick a license")
                                       (orgwarrior-test-id "Publish to PyPI")
                                       (orgwarrior-test-id "Learn to juggle"))))
      (should (equal (mapcar (lambda (r) (plist-get r :target)) results)
                     '("projects.org_archive" "projects.org_archive" "tasks.org_archive")))
      (should-not (string-match-p "PyPI\\|license" (orgwarrior-test-file dir "projects.org")))
      (should-not (string-match-p "juggle" (orgwarrior-test-file dir "tasks.org")))
      (let ((archive (orgwarrior-test-file dir "projects.org_archive")))
        ;; The child went with its parent, once.
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "Pick a license" l))
                                  (split-string archive "\n"))))
        (should (string-match-p "TODO Publish to PyPI" archive)))
      (should-not (cl-some (lambda (b) (and (buffer-file-name b) (buffer-modified-p b)))
                           (buffer-list))))))

(ert-deftest orgwarrior-test-archive-guards ()
  (orgwarrior-test-with-fixtures
    (let ((id (vector (orgwarrior-test-id "Learn to juggle"))))
      (should (string-match-p "takes no arguments"
                              (orgwarrior-test-error :op "act" :verb "archive" :ids id :args ["x"])))
      ;; An archive file with unsaved edits is refused like the source would be.
      (with-current-buffer (find-file-noselect (expand-file-name "tasks.org_archive" dir))
        (insert "half-typed")
        (should (string-match-p "unsaved changes"
                                (orgwarrior-test-error :op "act" :verb "archive" :ids id))))
      (should (string-match-p "Learn to juggle" (orgwarrior-test-file dir "tasks.org"))))))


;;;; Edit

(ert-deftest orgwarrior-test-edit-indirect-narrowed ()
  (orgwarrior-test-with-fixtures
    (let* ((name (plist-get (orgwarrior-test-ok :op "edit" :id (orgwarrior-test-id "Pay rent")) :buffer))
           (buf (get-buffer name))
           (base (buffer-base-buffer buf)))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should (string-match-p "\\`\\*\\* TODO Pay rent.*\n\\(.*\n\\)*- \\[ \\] remember the memo line\n*\\'"
                                      (buffer-string)))
              (search-forward "[ ]")
              (replace-match "[X]"))
            ;; The file's own buffer isn't narrowed but has the edit.
            (with-current-buffer base
              (should (= (point-min) 1))
              (should (= (point-max) (1+ (buffer-size))))
              (should (buffer-modified-p))
              (should (string-match-p "\\[X\\] remember" (buffer-string))))
            ;; Closing the frame unsaved takes the indirect buffer and the edit with it.
            (set-frame-parameter nil 'orgwarrior-edit name)
            (orgwarrior--edit-frame-closed (selected-frame))
            (should-not (buffer-live-p buf))
            (with-current-buffer base
              (should-not (buffer-modified-p))
              (should (string-match-p "\\[ \\] remember" (buffer-string))))
            (should (eq t (plist-get (orgwarrior-test-ok :op "edit-done" :buffer name) :discarded)))
            (should (eq :false (plist-get (orgwarrior-test-ok :op "edit-done" :buffer name) :discarded))))
        (set-frame-parameter nil 'orgwarrior-edit nil)
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest orgwarrior-test-edit-saved-is-kept ()
  (orgwarrior-test-with-fixtures
    (let* ((name (plist-get (orgwarrior-test-ok :op "edit" :id (orgwarrior-test-id "Pay rent")) :buffer)))
      (with-current-buffer name
        (search-forward "[ ]")
        (replace-match "[X]")
        (save-buffer))
      (set-frame-parameter nil 'orgwarrior-edit name)
      (unwind-protect (orgwarrior--edit-frame-closed (selected-frame))
        (set-frame-parameter nil 'orgwarrior-edit nil))
      (should (string-match-p "\\[X\\] remember" (orgwarrior-test-file dir "tasks.org")))
      (should (eq :false (plist-get (orgwarrior-test-ok :op "edit-done" :buffer name) :discarded))))))

(ert-deftest orgwarrior-test-edit-refuses-unsaved ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Pay rent")))
      (with-current-buffer (find-file-noselect (expand-file-name "tasks.org" dir))
        (goto-char (point-max))
        (insert "half-typed"))
      (should (string-match-p "unsaved changes" (orgwarrior-test-error :op "edit" :id id)))
      (should-not (seq-some (lambda (b) (string-suffix-p "[orgwarrior]" (buffer-name b)))
                            (buffer-list))))))


;;;; Add

(defun orgwarrior-test-add (dir text &rest options)
  (apply #'orgwarrior-test-ok :op "add" :text text
         :file (expand-file-name "inbox.org" dir) options))

(ert-deftest orgwarrior-test-add ()
  (orgwarrior-test-with-fixtures
    (let* ((result (orgwarrior-test-add dir "NEXT call the dentist :@phone: s:fri d:2026-12-01"
                                   :heading "Tasks" :captured t))
           (text (orgwarrior-test-file dir "inbox.org")))
      (should (string-match-p
               (concat ":END:\n\n\\*\\* NEXT call the dentist :@phone:\n"
                       "SCHEDULED: <[0-9-]+ Fri> DEADLINE: <2026-12-01 Tue>\n"
                       ":PROPERTIES:\n:CAPTURED: \\[[0-9-]+ [A-Z][a-z]+ [0-9:]+\\]\n:END:\n\\'")
               text))
      (should-not (string-match-p "inbox:" (substring text 40)))
      (should (equal (plist-get result :keyword) "NEXT"))
      ;; The returned ID finds the new task.
      (should (string-match-p "call the dentist"
                              (plist-get (orgwarrior-test-ok :op "show" :id (plist-get result :id))
                                         :heading))))))

;; Anywhere: a place as refile names one (TO), or under a heading by ID (UNDER).
(ert-deftest orgwarrior-test-add-to-and-under ()
  (orgwarrior-test-with-fixtures
    (let ((inbox (expand-file-name "inbox.org" dir)))
      ;; The default first, then the refile targets as seen from its file.
      (let ((places (orgwarrior-test-ok :op "add-places" :file inbox :heading "Tasks")))
        (should (equal (mapcar (lambda (p) (plist-get p :label)) (plist-get places :places))
                       '("inbox.org › Tasks" "inbox.org" "tasks.org" "projects.org"
                         "tasks.org › Tasks" "projects.org › Orgwarrior")))
        (should (equal (plist-get (nth 5 (plist-get places :places)) :file) "projects.org"))
        ;; Each file's open keywords, for the form's chips.
        (should (equal (plist-get (seq-find (lambda (k) (equal (plist-get k :file) "projects.org"))
                                            (plist-get places :keywords))
                                  :open)
                       '("TODO" "NEXT" "ACTIVE" "WAIT"))))
      (orgwarrior-test-add dir "Ship it" :heading "Tasks" :to "warr")
      (should (string-match-p "\n\\*\\* TODO Ship it\n\\'" (orgwarrior-test-file dir "projects.org")))
      (orgwarrior-test-add dir "Garden" :heading "Tasks" :to "projects.org")
      (should (string-match-p "\n\\* TODO Garden\n\\'" (orgwarrior-test-file dir "projects.org")))
      (orgwarrior-test-add dir "Upload the wheel" :heading "Tasks"
                           :under (orgwarrior-test-id "Publish to PyPI"))
      (should (string-match-p "\\*\\*\\* TODO Write a README\n\\(?:.*\n\\)*?\\*\\*\\* TODO Upload the wheel"
                              (orgwarrior-test-file dir "projects.org")))
      (should-not (string-match-p "Ship it\\|Garden\\|Upload" (orgwarrior-test-file dir "inbox.org")))
      ;; An agenda file that isn't a refile target, by its name.
      (orgwarrior-test-add dir "Buy milk" :heading "Tasks" :to "inbox.org")
      (should (string-match-p "\n\\* TODO Buy milk\n\\'" (orgwarrior-test-file dir "inbox.org")))
      (should (string-match-p "No refile target matches"
                              (orgwarrior-test-error :op "add" :text "X" :file inbox :to "zzz"))))))

;; A priority from a form.
(ert-deftest orgwarrior-test-add-priority ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "add" :fields '((title . "Pay the plumber") (keyword . "NEXT") (priority . "a"))
                        :file (expand-file-name "inbox.org" dir))
    (should (string-match-p "\n\\* NEXT \\[#A\\] Pay the plumber\n" (orgwarrior-test-file dir "inbox.org")))
    (should (string-match-p "Priority is one of"
                            (orgwarrior-test-error :op "add" :fields '((title . "X") (priority . "Z"))
                                                   :file (expand-file-name "inbox.org" dir))))))

;; A plain heading: keyword "", as C-c C-t SPC leaves one.
(ert-deftest orgwarrior-test-add-no-keyword ()
  (orgwarrior-test-with-fixtures
    (let ((r (orgwarrior-test-ok :op "add" :fields '((title . "Garage") (keyword . ""))
                                 :file (expand-file-name "projects.org" dir))))
      (should-not (plist-get r :keyword))
      (should (string-match-p "\n\\* Garage\n\\'" (orgwarrior-test-file dir "projects.org")))
      (should (string-match-p "would read it as one"
                              (orgwarrior-test-error :op "add" :fields '((title . "TODO later") (keyword . ""))
                                                     :file (expand-file-name "projects.org" dir)))))))

(ert-deftest orgwarrior-test-add-with-time ()
  ;; A time of day survives into the timestamp (org-time-was-given is special).
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :text "dentist s:2026-10-14T14:00 d:2026-10-16" :file file :heading "Tasks")
      (should (string-match-p "SCHEDULED: <2026-10-14 Wed 14:00> DEADLINE: <2026-10-16 Fri>"
                              (orgwarrior-test-file dir "inbox.org"))))))

(ert-deftest orgwarrior-test-add-ranges-and-repeaters ()
  ;; Times, repeaters and warnings right after s:/d: go with the date;
  ;; a bare number doesn't.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                     :text "dentist s:2026-10-16 14:00-15:00 +1y d:2026-11-01 -5d 3 times")
      (should (string-match-p (concat "\\* TODO dentist 3 times\n"
                                      "SCHEDULED: <2026-10-16 Fri 14:00-15:00 \\+1y> "
                                      "DEADLINE: <2026-11-01 Sun -5d>\n")
                              (orgwarrior-test-file dir "inbox.org")))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                     :fields '(:title "standup" :scheduled "2026-10-19 9am+0:15 .+1d"))
      (should (string-match-p "SCHEDULED: <2026-10-19 Mon 09:00-09:15 \\.\\+1d>"
                              (orgwarrior-test-file dir "inbox.org"))))))

;; No keyword, the timestamp on its own line (after any drawer).
(ert-deftest orgwarrior-test-add-event ()
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "calendar.org" dir))
           (r (orgwarrior-test-ok :op "add" :file file :event t :captured t
                             :text "Dentist cleaning @2026-10-16 14:00-15:00 :@out: s:x")))
      (should (string-match-p (concat "\n\n\\* Dentist cleaning s:x :@out:\n"
                                      ":PROPERTIES:\n:CAPTURED: [^\n]*\n:END:\n\n"
                                      "<2026-10-16 Fri 14:00-15:00>\n\\'")
                              (orgwarrior-test-file dir "calendar.org")))
      (should-not (plist-get r :keyword))
      (should (string-match-p "Dentist cleaning"
                              (mapconcat (lambda (l) (plist-get l :text))
                                         (orgwarrior-test-ok :op "view" :kind "words" :arg "2026-10-16")
                                         "\n"))))
    (let ((file (expand-file-name "calendar.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :event t
                     :fields '(:title "Mom birthday" :when "2026-11-03 +1y"))
      (should (orgwarrior-test-error :op "add" :file file :event t :fields '(:title "x")))
      (should (string-match-p "\\* Mom birthday\n<2026-11-03 Tue \\+1y>\n\\'"
                              (orgwarrior-test-file dir "calendar.org")))
      (dolist (text '("no date" "TODO party @fri"))
        (should (orgwarrior-test-error :op "add" :file file :event t :text text))))))

(ert-deftest orgwarrior-test-add-fields ()
  ;; From a form: the title is taken as is, however much it looks like syntax.
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "inbox.org" dir))
           (r (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                             :fields '(:keyword "next" :title "fix the d:3 bug :x:"
                                       :tags ["@phone"] :scheduled "2026-10-14 14:00"))))
      (should (equal (plist-get r :heading) "NEXT fix the d:3 bug :x: :@phone:"))
      (should (string-match-p "SCHEDULED: <2026-10-14 Wed 14:00>" (orgwarrior-test-file dir "inbox.org")))
      (dolist (bad '((:title "") (:title "x" :keyword "NOPE")
                     (:title "x" :tags ["a b"]) (:title "x" :deadline "fridge")))
        (should (orgwarrior-test-error :op "add" :file file :heading "Tasks" :fields bad))))))

(ert-deftest orgwarrior-test-add-one-line ()
  ;; A form's title is the title alone: no second line (a heading of its own),
  ;; no trailing :word: org would read as tags unless tags follow it.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (should (string-match-p "one line" (orgwarrior-test-error
                                          :op "add" :file file
                                          :fields '(:title "Harmless\n* DONE Injected :evil:"))))
      (should (string-match-p "one line" (orgwarrior-test-error
                                          :op "add" :file file :event t
                                          :fields '(:title "Dinner\r\n* X" :when "2026-10-20"))))
      (should (string-match-p "would set tags" (orgwarrior-test-error
                                                :op "add" :file file :fields '(:title "Tagged? :x:" :tags []))))
      (orgwarrior-test-ok :op "add" :file file :fields '(:title "Tagged? :x:" :tags ["y"]))
      (should-not (string-match-p "Injected\\|^\\* X" (orgwarrior-test-file dir "inbox.org")))
      (let ((id (orgwarrior-test-id "Tagged? :x:")))
        (should (string-match-p "one line" (orgwarrior-test-error :op "act" :verb "prop" :ids (vector id)
                                                                  :args ["FOO" "a\n* X"])))))))

(ert-deftest orgwarrior-test-stale-id ()
  ;; An ID is a prefix: once its task is gone, a new task's hash can start
  ;; with it.  The ID stays the gone task's for a day: the new one gets a
  ;; longer one, and the old one is refused, never acting on it.
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "inbox.org" dir))
           (old (orgwarrior-test-id "Buy batteries"))
           (title (cl-loop for i from 0
                           for title = (format "Probe %d" i)
                           when (string-prefix-p old (orgwarrior--hash "inbox.org" title))
                           return title)))
      (orgwarrior-test-ok :op "act" :verb "kill" :ids (vector old))
      (let ((new (plist-get (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                                                :fields `(:title ,title))
                            :id)))
        (should (string-prefix-p old new))
        (should (> (length new) (length old)))
        (let ((err (orgwarrior-test-error :op "act" :verb "done" :ids (vector old))))
          (should (string-match-p "renamed or gone" err))
          (should (string-match-p (regexp-quote title) err)))
        (should-not (string-match-p "DONE Probe" (orgwarrior-test-file dir "inbox.org")))
        (orgwarrior-test-ok :op "act" :verb "pri" :ids (vector new) :args ["A"])
        (should (string-match-p (concat "\\[#A\\] " title) (orgwarrior-test-file dir "inbox.org")))
        ;; A day on, the reservation is over.
        (let ((orgwarrior--reserve-seconds 0) (orgwarrior--last-index nil))
          (should (equal (orgwarrior-test-id title) old)))))))

(ert-deftest orgwarrior-test-failed-save-reverted ()
  ;; A save that fails leaves nothing behind: not the change in memory, and
  ;; not a file every later request refuses.
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "tasks.org" dir))
           (id (orgwarrior-test-id "Call dentist")))
      (orgwarrior-test-ok :op "view" :kind "all")
      (set-file-modes file #o444)
      (unwind-protect
          (should (orgwarrior-test-error :op "act" :verb "pri" :ids (vector id) :args ["C"]))
        (set-file-modes file #o644))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should-not (string-match-p "#C" (orgwarrior-test-file dir "tasks.org")))
      (orgwarrior-test-ok :op "act" :verb "pri" :ids (vector id) :args ["B"])
      (should (string-match-p "\\[#B\\] Call dentist" (orgwarrior-test-file dir "tasks.org"))))))

(ert-deftest orgwarrior-test-next-day-across-dst ()
  ;; Overnight clocks end on the next day at the time given, though the day
  ;; a clock change falls in has 23 or 25 hours.
  (let ((zone (getenv "TZ")))
    (unwind-protect
        (progn
          (set-time-zone-rule "EST5EDT,M3.2.0,M11.1.0")
          (dolist (case '(("2026-03-07 03:30" . "2026-03-08 03:30")
                          ("2026-10-31 02:30" . "2026-11-01 02:30")
                          ("2026-10-31 01:30" . "2026-11-01 01:30")))
            (should (equal (format-time-string "%F %R" (orgwarrior--next-day
                                                       (org-time-string-to-time (car case))))
                           (cdr case)))))
      (set-time-zone-rule zone))))

(ert-deftest orgwarrior-test-blocked ()
  ;; org-enforce-todo-dependencies: org-todo from code leaves a blocked task
  ;; as it was, which read as done.  Refused, naming what blocks it; fine once
  ;; the children are done, in one request too.
  (orgwarrior-test-with-fixtures
    (let ((org-enforce-todo-dependencies t)
          (org-blocker-hook '(org-block-todo-from-children-or-siblings-or-parent))
          (parent (orgwarrior-test-id "Publish to PyPI")))
      (should (string-match-p "Org blocks Publish to PyPI from TODO to DONE: \"TODO Pick a license\""
                              (orgwarrior-test-error :op "act" :verb "done" :ids (vector parent) :note "x")))
      (should (string-match-p "\\*\\* TODO Publish to PyPI" (orgwarrior-test-file dir "projects.org")))
      (orgwarrior-test-ok :op "act" :verb "done" :note "x"
                          :ids (vector (orgwarrior-test-id "Pick a license") (orgwarrior-test-id "Write a README")
                                       parent))
      (should (string-match-p "\\*\\* DONE Publish to PyPI" (orgwarrior-test-file dir "projects.org"))))))

(ert-deftest orgwarrior-test-file-in-a-folder ()
  ;; A setup kept in a folder of org-directory: its files named bare, as long
  ;; as one file has the name.
  (orgwarrior-test-with-fixtures
    (let* ((sub (expand-file-name "gtd" dir))
           (file (expand-file-name "lists.org" sub)))
      (make-directory sub)
      (with-temp-file file (insert "* Groceries\n** TODO Milk\n"))
      (let ((org-agenda-files (append org-agenda-files (list file)))
            (orgwarrior--last-index nil))
        (should (equal (plist-get (orgwarrior-test-ok :op "outline" :file "lists.org") :file) "gtd/lists.org"))
        (orgwarrior-test-ok :op "add" :file (expand-file-name "inbox.org" dir) :fields '(:title "Eggs") :to "lists.org")
        (should (string-match-p "^\\* TODO Eggs" (orgwarrior-test-file sub "lists.org")))
        (should (string-match-p "No agenda file" (orgwarrior-test-error :op "outline" :file "nope.org")))))))

(ert-deftest orgwarrior-test-encrypted-agenda-file ()
  ;; Opening an encrypted file asks for its passphrase: refused up front,
  ;; saying what to do, unless Emacs has it open (decrypted) already.
  (orgwarrior-test-with-fixtures
    (let* ((file (expand-file-name "secret.org.gpg" dir))
           (org-agenda-files (append org-agenda-files (list file))))
      (let ((file-name-handler-alist nil))  ; else writing it asks whom to encrypt for
        (with-temp-file file (insert "not really encrypted")))
      (should (string-match-p "secret.org.gpg is encrypted and not open in Emacs"
                              (orgwarrior-test-error :op "view" :kind "all")))
      (let ((buf (let ((auto-mode-alist nil) (file-name-handler-alist nil)) (find-file-noselect file))))
        (unwind-protect
            (orgwarrior-test-ok :op "keywords")
          (kill-buffer buf))))))

(ert-deftest orgwarrior-test-add-done ()
  ;; An import's finished task, from fields only: CLOSED as given, else now.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                          :fields '(:keyword "done" :title "Old one" :closed "2026-03-02 09:15"
                                    :scheduled "2026-03-01"))
      (should (string-match-p "\\*\\* DONE Old one\nCLOSED: \\[2026-03-02 Mon 09:15\\] SCHEDULED: <2026-03-01 Sun>\n"
                              (orgwarrior-test-file dir "inbox.org")))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :fields '(:keyword "DONE" :title "Day only" :closed "2026-03-02"))
      (should (string-match-p "DONE Day only\nCLOSED: \\[2026-03-02 Mon\\]\n" (orgwarrior-test-file dir "inbox.org")))
      (let ((org-log-done 'time))
        (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :fields '(:keyword "DONE" :title "Just now")))
      (should (string-match-p "DONE Just now\nCLOSED: \\[[^]]+ [0-9:]+\\]" (orgwarrior-test-file dir "inbox.org")))
      (should (string-match-p "later than now" (orgwarrior-test-error :op "add" :file file
                                                                    :fields '(:keyword "DONE" :title "x" :closed "+2d"))))
      (should (string-match-p "done keyword" (orgwarrior-test-error :op "add" :file file
                                                                   :fields '(:title "x" :closed "2026-03-02"))))
      (should (orgwarrior-test-error :op "add" :file file :event t
                                     :fields '(:title "x" :when "2026-03-02" :closed "2026-03-02"))))))

(ert-deftest orgwarrior-test-add-text-body ()
  ;; The quick syntax's first line is the heading; the rest is the body, as typed.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :captured t
                          :text "Pack :travel: s:2030-01-15\n- [ ] socks s:not-a-date\n- [ ] charger")
      (should (string-match-p (concat "\\*\\* TODO Pack :travel:\nSCHEDULED: <2030-01-15 Tue>\n"
                                      ":PROPERTIES:\n:CAPTURED: [^\n]*\n:END:\n\n"
                                      "- \\[ \\] socks s:not-a-date\n- \\[ \\] charger\n\\'")
                              (orgwarrior-test-file dir "inbox.org"))))))

(ert-deftest orgwarrior-test-add-properties ()
  ;; In the drawer after :CAPTURED:, names as org writes them; bad ones refused.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :captured t
                          :fields '(:title "Dry cleaning" :properties (:from "robin")))
      (should (string-match-p "\\* TODO Dry cleaning\n:PROPERTIES:\n:CAPTURED: [^\n]*\n:FROM: robin\n:END:\n\\'"
                              (orgwarrior-test-file dir "inbox.org")))
      (orgwarrior-test-ok :op "add" :file file :event t :fields '(:title "Dinner" :when "2026-10-20 19:00"
                                                                 :properties (:FROM "robin")))
      (should (string-match-p "\\* Dinner\n:PROPERTIES:\n:FROM: robin\n:END:\n\n<2026-10-20 Tue 19:00>\n\\'"
                              (orgwarrior-test-file dir "inbox.org")))
      (dolist (bad '((:a\ b "x") (:from "two\nlines")))
        (should (orgwarrior-test-error :op "add" :file file :fields `(:title "x" :properties ,bad)))))))

(ert-deftest orgwarrior-test-entries-with ()
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :captured t
                          :fields '(:title "Dry cleaning" :scheduled "2030-01-15" :properties (:FROM "robin")))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :event t
                          :fields '(:title "Dinner" :when "2030-01-16 19:00" :properties (:FROM "robin")))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :fields '(:title "Mine"))
      (orgwarrior-test-ok :op "act" :verb "done" :ids (vector (orgwarrior-test-id "Dry cleaning")))
      (let ((found (orgwarrior-test-ok :op "entries" :property "FROM" :value "robin")))
        (should (equal (mapcar (lambda (e) (plist-get e :title)) found) '("Dry cleaning" "Dinner")))
        (let ((dry (car found)) (dinner (cadr found)))
          (should (eq t (plist-get dry :done)))
          (should (equal (plist-get dry :scheduled) "<2030-01-15 Tue>"))
          (should (string-prefix-p "[" (plist-get dry :closed)))
          (should (string-prefix-p "[" (plist-get dry :captured)))
          (should-not (plist-get dinner :keyword))
          (should (equal (plist-get dinner :timestamp) "<2030-01-16 Wed 19:00>"))))
      (should-not (orgwarrior-test-ok :op "entries" :property "FROM" :value "nobody")))))

(ert-deftest orgwarrior-test-add-body ()
  ;; After the drawer and one blank line, as typed; no drawer, right below.
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file file :heading "Tasks" :captured t
                          :fields '(:title "Pack" :body "\n\n- [ ] socks\n  - wool\n\n"))
      (should (string-match-p ":CAPTURED: [^\n]*\n:END:\n\n- \\[ \\] socks\n  - wool\n\\'"
                              (orgwarrior-test-file dir "inbox.org")))
      (orgwarrior-test-ok :op "add" :file file :fields '(:title "Read" :body "chapter 3"))
      (should (string-match-p "\n\\* TODO Read\nchapter 3\n\\'" (orgwarrior-test-file dir "inbox.org")))
      ;; A heading in it: a child of the new entry (orgwarrior-test-headings-in-text).
      (should (= (plist-get (orgwarrior-test-ok :op "add" :file file :heading "Tasks"
                                                :fields '(:title "x" :body "a\n* b"))
                            :new_children)
                 1)))))

(ert-deftest orgwarrior-test-add-top-level-no-captured ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-add dir "water the plants")
    (should (string-match-p ":END:\n\n\\* TODO water the plants\n\\'"
                            (orgwarrior-test-file dir "inbox.org")))))

(ert-deftest orgwarrior-test-add-under-nested-heading ()
  (orgwarrior-test-with-fixtures
    ;; Before the next sibling, one level below the heading.
    (orgwarrior-test-ok :op "add" :text "Register the name" :heading "Publish to PyPI"
                   :file (expand-file-name "projects.org" dir))
    (should (string-match-p "\\*\\*\\* TODO Write a README\n\n\\*\\*\\* TODO Register the name\n\\'"
                            (orgwarrior-test-file dir "projects.org")))
    (orgwarrior-test-ok :op "add" :text "Fix docs" :heading "Orgwarrior"
                   :file (expand-file-name "projects.org" dir))
    (should (string-match-p "Register the name\n\n\\*\\* TODO Fix docs\n\\'"
                            (orgwarrior-test-file dir "projects.org")))))

(ert-deftest orgwarrior-test-add-outside-agenda-files ()
  (orgwarrior-test-with-fixtures
    (let ((file (expand-file-name "notes.org" dir)))
      (with-temp-file file (insert "#+title: Notes\n"))
      (let ((result (orgwarrior-test-ok :op "add" :text "x" :file file)))
        (should-not (plist-get result :id))
        (should (equal (orgwarrior-test-file dir "notes.org") "#+title: Notes\n\n* TODO x\n"))))))

(ert-deftest orgwarrior-test-sandbox ()
  "A fixture daemon writes no org file outside its copy: an add to another
file (a real config's inbox) is an error, the file as it was."
  (orgwarrior-test-with-fixtures
    (let* ((outside (make-temp-file "orgwarrior-real" t))
           (inbox (expand-file-name "inbox.org" outside)))
      (unwind-protect
          (progn
            (with-temp-buffer (insert "* Tasks\n") (let ((orgwarrior-fixture-dir nil)) (write-region nil nil inbox)))
            (should (string-match-p "Sandbox: won't write"
                                    (orgwarrior-test-error :op "add" :text "x" :file inbox :heading "Tasks")))
            (should (equal (orgwarrior-test-file outside "inbox.org") "* Tasks\n"))
            ;; Other files, and org files inside, are written as ever.
            (with-temp-file (expand-file-name "notes.txt" outside) (insert "x"))
            (orgwarrior-test-ok :op "add" :text "y" :file (expand-file-name "inbox.org" dir)))
        (when-let* ((b (get-file-buffer inbox))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
        (delete-directory outside t)))))

(ert-deftest orgwarrior-test-add-defaults-and-errors ()
  (orgwarrior-test-with-fixtures
    (should (string-match-p "already DONE" (orgwarrior-test-error :op "add" :text "DONE thing"
                                                            :file (expand-file-name "inbox.org" dir))))
    (should (string-match-p "Empty title" (orgwarrior-test-error :op "add" :text "NEXT :x:"
                                                           :file (expand-file-name "inbox.org" dir))))
    (should (string-match-p "No heading \"Nope\""
                            (orgwarrior-test-error :op "add" :text "x" :heading "Nope"
                                              :file (expand-file-name "inbox.org" dir))))
    (should (string-match-p "not found" (orgwarrior-test-error :op "add" :text "x"
                                                         :file (expand-file-name "nope.org" dir))))
    (let ((org-default-notes-file (expand-file-name "nope.org" dir)))
      (should (string-match-p "set \\[add\\] file" (orgwarrior-test-error :op "add" :text "x"))))
    ;; No file: org-default-notes-file.
    (let ((org-default-notes-file (expand-file-name "calendar.org" dir)))
      (orgwarrior-test-ok :op "add" :text "renew passport")
      (should (string-match-p "\\* TODO renew passport\n\\'" (orgwarrior-test-file dir "calendar.org"))))))

(ert-deftest orgwarrior-test-history-and-note-edit ()
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Call dentist")))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "done" :args [] :note "Booked")
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "next" :args [])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "note" :args [] :note "Bring\n\nthe card")
      (orgwarrior-test-ok :op "clock-in" :id id :time "-1h")
      (orgwarrior-test-ok :op "clock-out")
      (let* ((task (orgwarrior-test-ok :op "show" :id id))
             (history (plist-get task :history)))
        (should (equal (mapcar (lambda (h) (list (plist-get h :n) (plist-get h :kind) (plist-get h :state)
                                                 (plist-get h :from) (plist-get h :text)))
                               history)
                       '((1 "note" nil nil "Bring\n\nthe card") (2 "state" "NEXT" "DONE" "")
                         (3 "state" "DONE" "NEXT" "Booked"))))
        (should (string-prefix-p "State \"NEXT\"" (plist-get (nth 1 history) :heading)))
        ;; Every line of the LOGBOOK is a log item or a clock: a page can leave it out.
        (should (equal (plist-get task :log_drawers) '("LOGBOOK")))
        ;; A note's text changed, the old one guarding it.
        (should (string-match-p "changed since"
                                (orgwarrior-test-error :op "note-edit" :id id :n 1 :text "x" :old "- nope")))
        (orgwarrior-test-ok :op "note-edit" :id id :n 1 :text "Bring the card\nand the form"
                            :old (plist-get (car history) :raw))
        (should (string-match-p "Note taken on [^\n]+ \\\\\\\\\n  Bring the card\n  and the form\n"
                                (orgwarrior-test-file dir "tasks.org")))
        ;; A state change given a note, then its note taken off again.
        (orgwarrior-test-ok :op "note-edit" :id id :n 2 :text "Rebooked")
        (should (equal (plist-get (nth 1 (plist-get (orgwarrior-test-ok :op "show" :id id) :history)) :text)
                       "Rebooked"))
        (orgwarrior-test-ok :op "note-edit" :id id :n 2 :text "")
        (should (equal (plist-get (nth 1 (plist-get (orgwarrior-test-ok :op "show" :id id) :history)) :text) ""))
        (should (string-match-p "needs its text" (orgwarrior-test-error :op "note-edit" :id id :n 1 :text " ")))
        ;; Removed, all of them: the drawer keeps the clock.
        (dotimes (_ 3) (orgwarrior-test-ok :op "note-edit" :id id :n 1 :remove t))
        (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :history))
        (should (string-match-p ":LOGBOOK:\nCLOCK: [^\n]+\n:END:" (orgwarrior-test-file dir "tasks.org"))))
      ;; Something else in the drawer: it has to show.
      (with-current-buffer (find-buffer-visiting (expand-file-name "tasks.org" dir))
        (goto-char (point-min))
        (re-search-forward "^CLOCK:")
        (insert "a remark of my own\n")
        (save-buffer))
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :log_drawers)))))

(ert-deftest orgwarrior-test-add-with-effort ()
  (orgwarrior-test-with-fixtures
    (let ((inbox (expand-file-name "inbox.org" dir)))
      (orgwarrior-test-ok :op "add" :file inbox :heading "Tasks" :fields '(:title "Paint the hall" :effort "1:30"))
      (should (string-match-p "\\*\\* TODO Paint the hall\n:PROPERTIES:\n:Effort: +1:30\n:END:" (orgwarrior-test-file dir "inbox.org")))
      (should (string-match-p "Not a duration" (orgwarrior-test-error :op "add" :file inbox :fields '(:title "x" :effort "soon"))))
      (should (string-match-p "no effort" (orgwarrior-test-error :op "add" :file inbox :event t
                                                                 :fields '(:title "x" :when "fri" :effort "1:00")))))))

(ert-deftest orgwarrior-test-properties-and-effort ()
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Pay rent"))
           (props (lambda () (mapcar (lambda (p) (list (plist-get p :name) (plist-get p :value)))
                                     (plist-get (orgwarrior-test-ok :op "show" :id id) :properties)))))
      (should (equal (funcall props) '(("CREATED" "[2026-09-01 Tue 10:00]"))))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "prop" :args ["LOCATION" "the" "bank"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "effort" :args ["0:45"])
      (let ((task (orgwarrior-test-ok :op "show" :id id)))
        (should (equal (plist-get task :effort) "0:45"))
        (should (= (plist-get task :effort_minutes) 45)))
      (should (equal (funcall props) '(("CREATED" "[2026-09-01 Tue 10:00]") ("LOCATION" "the bank") ("Effort" "0:45"))))
      (should (member "LOCATION" (plist-get (orgwarrior-test-ok :op "props" :id id) :names)))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "prop" :args ["LOCATION" "none"])
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "effort" :args ["none"])
      (should (equal (funcall props) '(("CREATED" "[2026-09-01 Tue 10:00]"))))
      (should-not (plist-get (orgwarrior-test-ok :op "show" :id id) :effort))
      ;; Refused: org's own, a bad name, not a duration.
      (should (string-match-p "org's own" (orgwarrior-test-error :op "act" :ids (vector id) :verb "prop" :args ["TODO" "x"])))
      (should (string-match-p "Not a property name"
                              (orgwarrior-test-error :op "act" :ids (vector id) :verb "prop" :args ["a b" "x"])))
      (should (string-match-p "Not a duration" (orgwarrior-test-error :op "act" :ids (vector id) :verb "effort" :args ["soon"])))
      ;; Effort_ALL: its values only, and offered.
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "prop" :args ["Effort_ALL" "0:15" "0:30" "1:00"])
      (should (equal (plist-get (orgwarrior-test-ok :op "props" :id id :name "Effort") :values) '("0:15" "0:30" "1:00")))
      (should (string-match-p "one of 0:15" (orgwarrior-test-error :op "act" :ids (vector id) :verb "effort" :args ["0:45"])))
      (orgwarrior-test-ok :op "act" :ids (vector id) :verb "effort" :args ["0:30"])
      (should (= (plist-get (orgwarrior-test-ok :op "show" :id id) :effort_minutes) 30)))))

;;;; Clocking

(defun orgwarrior-test-logbook (dir file after lines)
  "Put a LOGBOOK of LINES right after AFTER in FILE (before anything visits it)."
  (let ((text (orgwarrior-test-file dir file)))
    (should (string-search after text))
    (with-temp-file (expand-file-name file dir)
      (insert (string-replace after (concat after ":LOGBOOK:\n"
                                            (mapconcat (lambda (l) (concat l "\n")) lines "")
                                            ":END:\n")
                              text)))))

(defun orgwarrior-test-stamp (seconds-ago)
  (format-time-string "[%Y-%m-%d %a %H:%M]" (time-subtract nil seconds-ago)))

(defun orgwarrior-test-clock-titles (clocks)
  (mapcar (lambda (c) (plist-get c :title)) clocks))

(ert-deftest orgwarrior-test-clock-time ()
  (let ((day (encode-time (list 0 0 12 5 10 2026 nil -1 nil))))
    (should (equal (orgwarrior--clock-iso (orgwarrior--clock-time "17:30" day)) "2026-10-05 17:30"))
    (should (equal (orgwarrior--clock-iso (orgwarrior--clock-time "5:30PM" day)) "2026-10-05 17:30"))
    (should (equal (orgwarrior--clock-iso (orgwarrior--clock-time "12am" day)) "2026-10-05 00:00"))
    (should (equal (orgwarrior--clock-iso (orgwarrior--clock-time "2026-10-06 9:05" day)) "2026-10-06 09:05")))
  (should-not (orgwarrior--clock-time nil))
  (should-not (orgwarrior--clock-time " "))
  (should (= (orgwarrior--minutes (orgwarrior--clock-time "-1h30m")) 90))
  (should (= (orgwarrior--minutes (orgwarrior--clock-time "-15m")) 15))
  (should (equal (format-time-string "%F %R" (orgwarrior--clock-time "yesterday 9:00"))
                 (format-time-string "%F 09:00" (time-subtract nil 86400))))
  (dolist (bad '("9" "25:00" "13pm" "9:75" "soon" "-" "+15m" "tomorrow 9:00"))
    (should-error (orgwarrior--clock-time bad) :type 'user-error))
  ;; An end may be later than now: fudged forward.
  (should (= (round (float-time (time-subtract (orgwarrior--clock-time "+15m" nil t) nil)) 60) 15)))

(ert-deftest orgwarrior-test-clock-in-and-out ()
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (let* ((id (orgwarrior-test-id "Learn to juggle"))
           (in (orgwarrior-test-ok :op "clock-in" :id id :time "-30m")))
      (should (equal (plist-get (plist-get in :clock) :title) "Learn to juggle"))
      (should (= (plist-get (plist-get in :clock) :minutes) 30))
      (should-not (plist-get in :closed))
      (should (string-match-p "Learn to juggle :someday:\n:LOGBOOK:\nCLOCK: \\[[^]]+\\]\n:END:"
                              (orgwarrior-test-file dir "tasks.org")))
      (let ((status (orgwarrior-test-ok :op "clock")))
        (should (equal (orgwarrior-test-clock-titles status) '("Learn to juggle")))
        (should (eq (plist-get (car status) :stale) :false)))
      (should (string-match-p "Already clocked in" (orgwarrior-test-error :op "clock-in" :id id)))
      (should (string-match-p "later than now" (orgwarrior-test-error :op "clock-in" :id (orgwarrior-test-id "Call dentist")
                                                                      :time "+5m")))
      (should (string-match-p "before it started" (orgwarrior-test-error :op "clock-out" :time "-45m")))
      (let ((out (orgwarrior-test-ok :op "clock-out" :time "+10m")))  ; fudged forward
        (should (= (plist-get out :minutes) 40))
        (should (eq (plist-get out :removed) :false)))
      (should (string-match-p "CLOCK: \\[[^]]+\\]--\\[[^]]+\\] =>  0:40" (orgwarrior-test-file dir "tasks.org")))
      (should (string-match-p "No clock running" (orgwarrior-test-error :op "clock-out")))
      (should-not (org-clocking-p)))))

(ert-deftest orgwarrior-test-clock-in-closes-running ()
  "Clocking in closes what's running, at the same time."
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (let ((juggle (orgwarrior-test-id "Learn to juggle"))
          (dentist (orgwarrior-test-id "Call dentist")))
      (orgwarrior-test-ok :op "clock-in" :id juggle :time "-1h")
      (should (string-match-p "before the running clock"
                              (orgwarrior-test-error :op "clock-in" :id dentist :time "-2h")))
      (let ((closed (plist-get (orgwarrior-test-ok :op "clock-in" :id dentist :time "-15m") :closed)))
        (should (equal (orgwarrior-test-clock-titles closed) '("Learn to juggle")))
        (should (= (plist-get (car closed) :minutes) 45)))
      (should (equal (orgwarrior-test-clock-titles (orgwarrior-test-ok :op "clock")) '("Call dentist"))))))

(ert-deftest orgwarrior-test-clock-from-the-files ()
  "Open CLOCK lines are what's running, whatever the daemon remembers."
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-logbook dir "tasks.org" "Learn to juggle :someday:\n"
                             (list (concat "CLOCK: " (orgwarrior-test-stamp (* 5 3600)))))
    (orgwarrior-test-logbook dir "inbox.org" ":CAPTURED: [2026-09-29 Tue 21:51]\n:END:\n"
                             (list (concat "CLOCK: " (orgwarrior-test-stamp 600))))
    (let ((status (orgwarrior-test-ok :op "clock")))
      (should (equal (orgwarrior-test-clock-titles status) '("Learn to juggle" "Buy batteries")))
      (should (eq (plist-get (car status) :stale) t))
      (should (eq (plist-get (cadr status) :stale) :false)))
    (should (string-match-p "running on 2 tasks.*\n.*Learn to juggle.*\n.*Buy batteries"
                            (orgwarrior-test-error :op "clock-out")))
    (let ((batteries (orgwarrior-test-id "Buy batteries")))
      (should (= (plist-get (orgwarrior-test-ok :op "clock-out" :id batteries) :minutes) 10))
      (should (string-match-p "No clock running on" (orgwarrior-test-error :op "clock-out" :id batteries))))
    (orgwarrior-test-ok :op "clock-cancel")
    (should-not (string-match-p "CLOCK\\|LOGBOOK" (orgwarrior-test-file dir "tasks.org")))
    (should-not (orgwarrior-test-ok :op "clock"))))

(ert-deftest orgwarrior-test-clock-memory-out-of-step ()
  "A clock closed elsewhere (Syncthing) isn't closed again on the next clock in."
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-ok :op "clock-in" :id (orgwarrior-test-id "Learn to juggle") :time "-1h")
    (should (org-clocking-p))
    (let* ((file (expand-file-name "tasks.org" dir))
           (text (orgwarrior-test-file dir "tasks.org")))
      (should (string-match "^CLOCK: \\(\\[[^]]+\\]\\)$" text))
      (let* ((start (match-string 1 text))
             (line (format "CLOCK: %s--%s =>  0:20" start
                           (format-time-string "[%Y-%m-%d %a %H:%M]"
                                               (time-add (org-time-string-to-time start) 1200)))))
        (with-temp-file file (insert (replace-match line t t text)))
        (set-file-times file (time-add (current-time) 10))
        (orgwarrior-test-ok :op "clock-in" :id (orgwarrior-test-id "Call dentist"))
        (should (string-search line (orgwarrior-test-file dir "tasks.org")))
        (should (equal (orgwarrior-test-clock-titles (orgwarrior-test-ok :op "clock")) '("Call dentist")))))))

(ert-deftest orgwarrior-test-clocks-edit ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-logbook dir "tasks.org" "Learn to juggle :someday:\n"
                             '("CLOCK: [2026-10-05 Mon 09:40]--[2026-10-05 Mon 12:23] =>  2:43"
                               "CLOCK: [2026-10-06 Tue 14:05]--[2026-10-06 Tue 14:47] =>  0:42"))
    (let* ((id (orgwarrior-test-id "Learn to juggle"))
           (clocks (orgwarrior-test-ok :op "clocks" :id id))
           (file (lambda () (orgwarrior-test-file dir "tasks.org"))))
      (should (= (plist-get clocks :minutes) 205))
      (should (equal (plist-get (orgwarrior-test-ok :op "show" :id id) :clocks) (plist-get clocks :clocks)))
      (should (equal (mapcar (lambda (c) (list (plist-get c :n) (plist-get c :start) (plist-get c :end)
                                               (plist-get c :minutes)))
                             (plist-get clocks :clocks))
                     '((1 "2026-10-06 14:05" "2026-10-06 14:47" 42)
                       (2 "2026-10-05 09:40" "2026-10-05 12:23" 163))))
      ;; A time of day is on the clock's own date.
      (should (= (plist-get (orgwarrior-test-ok :op "clock-edit" :id id :n 2 :start "9:30" :end "12:20")
                            :minutes)
                 (+ 42 170)))
      (should (string-search "CLOCK: [2026-10-05 Mon 09:30]--[2026-10-05 Mon 12:20] =>  2:50" (funcall file)))
      ;; Only the end, past midnight.
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :end "0:15")
      (should (string-search "CLOCK: [2026-10-06 Tue 14:05]--[2026-10-07 Wed 00:15] => 10:10" (funcall file)))
      (should (string-match-p "before it starts"
                              (orgwarrior-test-error :op "clock-edit" :id id :n 1 :start "2026-10-07 9:00")))
      ;; Not overnight: 20 hours is a typo.
      (should (string-match-p "before it starts"
                              (orgwarrior-test-error :op "clock-edit" :id id :n 2 :end "9:00")))
      (should (string-match-p "changed since"
                              (orgwarrior-test-error :op "clock-edit" :id id :n 1 :start "14:00" :old "CLOCK: nope")))
      (should (string-match-p "No clock 3" (orgwarrior-test-error :op "clock-edit" :id id :n 3 :start "9:00")))
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :start "14:00"
                          :old "CLOCK: [2026-10-06 Tue 14:05]--[2026-10-07 Wed 00:15] => 10:10")
      (should (string-search "[2026-10-06 Tue 14:00]--[2026-10-07 Wed 00:15] => 10:15" (funcall file)))
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :remove t)
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :remove t)
      (should-not (string-match-p "LOGBOOK" (funcall file))))))

(ert-deftest orgwarrior-test-report ()
  (orgwarrior-test-with-fixtures
    (orgwarrior-test-logbook dir "tasks.org" "Learn to juggle :someday:\n"
                             '("CLOCK: [2026-10-05 Mon 09:40]--[2026-10-05 Mon 12:23] =>  2:43"
                               "CLOCK: [2026-10-06 Tue 14:05]--[2026-10-06 Tue 14:47] =>  0:42"))
    (orgwarrior-test-logbook dir "inbox.org" ":CAPTURED: [2026-09-29 Tue 21:51]\n:END:\n"
                             '("CLOCK: [2026-10-06 Tue 10:00]--[2026-10-06 Tue 10:30] =>  0:30"))
    (let* ((juggle (orgwarrior-test-id "Learn to juggle"))
           (report (lambda (words) (orgwarrior-test-ok :op "report" :words words)))
           (rows (lambda (r) (seq-mapcat (lambda (f) (mapcar (lambda (row) (list (plist-get f :file) (plist-get row :depth)
                                                                                   (plist-get row :title) (plist-get row :minutes)))
                                                               (plist-get f :rows)))
                                         (plist-get r :files)))))
      (orgwarrior-test-ok :op "act" :ids (vector juggle) :verb "effort" :args ["2:00"])
      (let ((day (funcall report "2026-10-05")))
        (should (equal (funcall rows day) '(("tasks.org" 1 "Tasks" 163) ("tasks.org" 2 "Learn to juggle" 163))))
        (should (equal (plist-get (nth 1 (plist-get (car (plist-get day :files)) :rows)) :id) juggle))
        (should (= (plist-get (nth 1 (plist-get (car (plist-get day :files)) :rows)) :effort_minutes) 120))
        (should (equal (list (plist-get day :kind) (plist-get day :prev) (plist-get day :next))
                       '("day" "2026-10-04" "2026-10-06"))))
      (should (= (plist-get (funcall report "2026-10-05..2026-10-06") :minutes) 235))
      (let ((week (funcall report "2026-W41")))
        (should (equal (list (plist-get week :minutes) (plist-get week :label) (plist-get week :start) (plist-get week :end)
                             (plist-get week :prev) (plist-get week :next))
                       '(235 "week 2026-W41" "2026-10-05" "2026-10-11" "2026-W40" "2026-W42")))
        (should (equal (mapcar (lambda (f) (plist-get f :file)) (plist-get week :files)) '("tasks.org" "inbox.org"))))
      (let ((month (funcall report "2026-10")))
        (should (equal (list (plist-get month :kind) (plist-get month :prev) (plist-get month :next)) '("month" "2026-09" "2026-11"))))
      ;; A tag match after the span; the inbox's filetags count.
      (should (= (plist-get (funcall report "2026-10-06 +inbox") :minutes) 30))
      ;; Nothing clocked: nothing listed.
      (let ((today (funcall report "")))
        (should (equal (list (plist-get today :minutes) (plist-get today :files)) '(0 nil)))
        (should (equal (plist-get today :start) (format-time-string "%F")))))))

(ert-deftest orgwarrior-test-clock-edit-running ()
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle")))
      (orgwarrior-test-ok :op "clock-in" :id id)
      (should (string-match-p "still running" (orgwarrior-test-error :op "clock-edit" :id id :n 1 :end "-1m")))
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :start "-1h")
      (should (= (plist-get (car (orgwarrior-test-ok :op "clock")) :minutes) 60))
      (should (= (orgwarrior--minutes org-clock-start-time) 60))   ; the daemon's too
      (orgwarrior-test-ok :op "clock-edit" :id id :n 1 :remove t)
      (should-not (org-clocking-p))
      (should-not (orgwarrior-test-ok :op "clock")))))

(ert-deftest orgwarrior-test-clock-add ()
  "Time already spent, logged as a finished clock: a running one goes on."
  (orgwarrior-test-fresh-minute)
  (orgwarrior-test-with-fixtures
    (let ((id (orgwarrior-test-id "Learn to juggle"))
          (file (lambda () (orgwarrior-test-file dir "tasks.org"))))
      (orgwarrior-test-ok :op "clock-in" :id id)
      (let ((clocks (orgwarrior-test-ok :op "clock-add" :id id :start "2026-10-05 9:40" :end "12:23")))
        (should (equal (mapcar (lambda (c) (plist-get c :end)) (plist-get clocks :clocks))
                       '(nil "2026-10-05 12:23"))))
      ;; Where org-clock-in writes one, the running one left as it was.
      (should (string-match-p (concat ":LOGBOOK:\n *CLOCK: \\[2026-10-05 Mon 09:40\\]--\\[2026-10-05 Mon 12:23\\] =>  2:43\n"
                                      " *CLOCK: \\[[^]]+\\]\n")
                              (funcall file)))
      (should (org-clocking-p))
      (should (= 1 (length (orgwarrior-test-ok :op "clock"))))
      ;; A duration; overnight.
      (orgwarrior-test-ok :op "clock-add" :id id :start "2026-10-06 14:05" :duration "42m")
      (should (string-search "CLOCK: [2026-10-06 Tue 14:05]--[2026-10-06 Tue 14:47] =>  0:42" (funcall file)))
      (orgwarrior-test-ok :op "clock-add" :id id :start "2026-10-06 23:30" :end "0:15")
      (should (string-search "CLOCK: [2026-10-06 Tue 23:30]--[2026-10-07 Wed 00:15] =>  0:45" (funcall file)))
      (orgwarrior-test-ok :op "clock-add" :id id :start "2026-10-08 9:00" :duration "1:30")
      (should (string-search "[2026-10-08 Thu 10:30] =>  1:30" (funcall file)))
      (should (string-match-p "one of them" (orgwarrior-test-error :op "clock-add" :id id :start "9:00"
                                                                   :end "10:00" :duration "1h")))
      (should (string-match-p "one of them" (orgwarrior-test-error :op "clock-add" :id id :start "9:00")))
      (should (string-match-p "later than now" (orgwarrior-test-error :op "clock-add" :id id :start "-10m"
                                                                      :duration "1h")))
      (should (string-match-p "Not a duration" (orgwarrior-test-error :op "clock-add" :id id :start "-2h"
                                                                      :duration "soon")))
      (should (string-match-p "before it starts" (orgwarrior-test-error :op "clock-add" :id id
                                                                        :start "2026-10-06 14:00" :end "9:00"))))))

(ert-deftest orgwarrior-test-files ()
  (orgwarrior-test-with-fixtures
    (should (equal (sort (append (orgwarrior-test-ok :op "files") nil) #'string<)
                   '("calendar.org" "inbox.org" "projects.org" "tasks.org")))))

;;; orgwarrior-test.el ends here
