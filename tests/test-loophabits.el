;;; test-loophabits.el --- ERT tests for loophabits.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'loophabits)

(defmacro with-loophabits-sandbox (&rest body)
  "Run BODY with `loophabits-file' in a temp file and a cold cache."
  `(let ((loophabits-file (make-temp-file "loophabits-" nil ".org"))
         (lh--cache nil)
         (lh--cache-key nil))
     ,@body))

(defun lh-test--make (&rest props)
  "Create a habit named after the test, PROPS passed to `loophabits-new'."
  (apply #'loophabits-new "Test habit"
         ;; PROPS first so they override the fallbacks below.
         (append props '(:freq "1/1" :color "#7dcfff"))))

(defun lh-test--rewind-created (name days)
  "Rewind habit NAME's :CREATED: to DAYS before today."
  (with-current-buffer (find-file-noselect (loophabits--file))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (concat "^[*] +" (regexp-quote name)))
      (re-search-forward ":CREATED:")
      (delete-region (point) (line-end-position))
      (insert (format " [%s]"
                      (lh-format-date (lh-date-shift (lh-today) (- days)))))
      (save-buffer)))
  (loophabits-load 'force))

;;; --- storage: create, parse, round-trip -------------------------------------

(ert-deftest loophabits-new-and-parse ()
  "A created habit parses back with all its fields."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (should h)
     (should (equal "Test habit" (lh/habit-name h)))
     (should (eq 'yesno (lh/habit-type h)))
     (should (equal 1 (lh/habit-freq-num h)))
     (should (equal 1 (lh/habit-freq-den h)))
     (should (equal "#7dcfff" (lh/habit-color h)))
     (should-not (lh/habit-paused h))
     (should-not (lh/habit-archived h))
     (should (equal (lh-today) (lh/habit-created h))))))

(ert-deftest loophabits-new-measurable ()
  "Measurable habits keep target and unit."
  (with-loophabits-sandbox
   (lh-test--make :type 'measurable :target 30 :unit "pages")
   (let ((h (loophabits-find "Test habit")))
     (should (eq 'measurable (lh/habit-type h)))
     (should (equal 30 (lh/habit-target h)))
     (should (equal "pages" (lh/habit-unit h))))))

(ert-deftest loophabits-parse-entry-variants ()
  "Every entry grammar variant parses to its value."
  (with-loophabits-sandbox
   (let ((today (lh-today)))
     (lh-test--make)
     (let ((h (loophabits-find "Test habit")))
       (loophabits-set h (lh-date-shift today -4) 1)
       (loophabits-set h (lh-date-shift today -3) 0)
       (loophabits-set h (lh-date-shift today -2) 'skip "was traveling")
       (loophabits-set h (lh-date-shift today -1) 'q))
     (let ((h (loophabits-find "Test habit")))
       (should (equal 1 (lh-entry-value h (lh-date-shift today -4))))
       (should (equal 0 (lh-entry-value h (lh-date-shift today -3))))
       (should (eq 'skip (lh-entry-value h (lh-date-shift today -2))))
       (should (eq 'q (lh-entry-value h (lh-date-shift today -1))))
       (should (equal "was traveling"
                      (lh-entry-note h (lh-date-shift today -2))))
       (should (= 4 (length (lh/habit-entries h))))))))

(ert-deftest loophabits-set-replaces-not-duplicates ()
  "Re-setting a date replaces the entry."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (loophabits-set h (lh-today) 1)
     (loophabits-set h (lh-today) 0 "changed my mind")
     (setq h (loophabits-find "Test habit"))
     (should (= 1 (length (lh/habit-entries h))))
     (should (equal 0 (lh-entry-value h (lh-today))))
     (should (equal "changed my mind"
                    (lh-entry-note h (lh-today)))))))

;;; --- computed values, due days, auto bridging -------------------------------

(ert-deftest loophabits-computed-value-before-creation-is-auto ()
  "Days before :CREATED: are auto (not expected)."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (should (eq 'auto (lh-computed-value h (lh-date-shift (lh-today) -10)))))))

(ert-deftest loophabits-weekly-auto-bridging ()
  "A 1/7 habit: days after the weekly quota is met are auto."
  (with-loophabits-sandbox
   (lh-test--make :freq "1/7")
   (let* ((h (loophabits-find "Test habit"))
          (today (lh-today)))
     ;; No entries yet: the trailing week is empty, so today is due
     ;; and unmet -> no.
     (should (eq 'no (lh-computed-value h today)))
     ;; Check in today.
     (loophabits-set h today 1)
     (should (eq 'yes (lh-computed-value (loophabits-find "Test habit")
                                         today)))
     ;; Tomorrow the weekly quota is already met -> auto (bridged).
     (should (eq 'auto (lh-computed-value
                        (loophabits-find "Test habit")
                        (lh-date-shift today 1)))))))

(ert-deftest loophabits-due-p-daily-and-weekly ()
  "Daily habits are always due; weekly habits until quota."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (should (lh-due-p h (lh-today)))
     (should (lh-due-p h (lh-date-shift (lh-today) -30))))
   (loophabits-new "Weekly" :freq "1/7")
   (let ((h (loophabits-find "Weekly")))
     ;; No entries yet in the trailing week -> due.
     (should (lh-due-p h (lh-today)))
     (loophabits-set h (lh-today) 1)
     ;; Quota met for a 7-day window ending yesterday-today... the
     ;; window used by due-p on DATE is the DEN days ending the day
     ;; BEFORE DATE; with a yes today, tomorrow is not yet decided
     ;; here, but today itself was decided on yesterday's window.
     (should (lh-due-p h (lh-today))))))

(ert-deftest loophabits-completed-p-measurable ()
  "Measurable completion needs the target; at-most inverts it."
  (with-loophabits-sandbox
   (lh-test--make :type 'measurable :target 30 :unit "pages")
   (let ((h (loophabits-find "Test habit")))
     (loophabits-set h (lh-today) 25)
     (should-not (lh-completed-p (loophabits-find "Test habit") (lh-today)))
     (loophabits-set h (lh-today) 30)
     (should (lh-completed-p (loophabits-find "Test habit") (lh-today))))
   (loophabits-new "At most" :type 'measurable-at-most :target 2
                   :unit "cigarettes")
   (let ((h (loophabits-find "At most")))
     (loophabits-set h (lh-today) 1)
     (should (lh-completed-p (loophabits-find "At most") (lh-today)))
     (loophabits-set h (lh-today) 5)
     (should-not (lh-completed-p (loophabits-find "At most") (lh-today))))))

;;; --- score: the real Loop recurrence -----------------------------------------

(ert-deftest loophabits-score-recurrence-math ()
  "One yes on creation day gives exactly 1 - multiplier."
  (with-loophabits-sandbox
   (lh-test--make)
   (let* ((h (loophabits-find "Test habit"))
          (today (lh-today)))
     (loophabits-set h today 1)
     (setq h (loophabits-find "Test habit"))
     ;; multiplier = 0.5 ^ (sqrt(1) / 13); score = 0*m + 1*(1-m).
     (let* ((m (expt 0.5 (/ 1.0 13.0)))
            (expected (* 100.0 (- 1.0 m))))
       (should (< (abs (- (loophabits-score h today) expected)) 0.01)))
     ;; An explicit no on the only day: score 0.
     (loophabits-set h today 0)
     (should (equal 0.0 (loophabits-score (loophabits-find "Test habit")
                                          today))))))

(ert-deftest loophabits-score-all-yes-converges-high ()
  "A month of daily yeses scores near 100."
  (with-loophabits-sandbox
   (lh-test--make)
   (lh-test--rewind-created "Test habit" 29)
   (let* ((h (loophabits-find "Test habit"))
          (start (lh-date-shift (lh-today) -29)))
     (dotimes (i 30)
       (loophabits-set h (lh-date-shift start i) 1))
     ;; Closed form: n yeses give score 1 - m^n, m = 0.5^(1/13).
     (let* ((m (expt 0.5 (/ 1.0 13.0)))
            (expected (* 100.0 (- 1.0 (expt m 30)))))
       (should (< (abs (- (loophabits-score (loophabits-find "Test habit")
                                            (lh-today))
                          expected))
                  0.1))))))

(ert-deftest loophabits-score-skip-days-are-neutral ()
  "Skip days do not change the score at all."
  (with-loophabits-sandbox
   (lh-test--make)
   (let* ((h (loophabits-find "Test habit"))
          (today (lh-today)))
     (loophabits-set h (lh-date-shift today -2) 1)
     (loophabits-set h (lh-date-shift today -1) 1)
     (let ((before (loophabits-score (loophabits-find "Test habit") today)))
       (loophabits-set h today 'skip)
       (should (equal before
                      (loophabits-score (loophabits-find "Test habit")
                                        today)))))))

;;; --- streaks ------------------------------------------------------------------

(ert-deftest loophabits-streaks-and-best ()
  "Consecutive days chain; gaps break; best remembers."
  (with-loophabits-sandbox
   (lh-test--make)
   (lh-test--rewind-created "Test habit" 11)
   (let* ((h (loophabits-find "Test habit"))
          (today (lh-today)))
     ;; Two streaks: 3 days a week ago, 2 days ending today.
     (dolist (d '(-9 -8 -7))
       (loophabits-set h (lh-date-shift today d) 1))
     (dolist (d '(-1 0))
       (loophabits-set h (lh-date-shift today d) 1))
     (setq h (loophabits-find "Test habit"))
     (should (equal 2 (loophabits-current-streak h)))
     (should (equal 3 (loophabits-best-streak h)))
     (should (equal 2 (length (loophabits-streaks h)))))))

(ert-deftest loophabits-weekly-streak-bridges-auto-days ()
  "A 1/7 habit streak counts auto (non-due) days as part of the run."
  (with-loophabits-sandbox
   (lh-test--make :freq "1/7")
   (lh-test--rewind-created "Test habit" 10)
   (let* ((h (loophabits-find "Test habit"))
          (today (lh-today)))
     ;; One check 10 days ago: days -9..-3 are auto (their weekly
     ;; window still contains the check) and bridge the streak; from
     ;; -2 on the window has lost it, so the run ends at -3.
     (loophabits-set h (lh-date-shift today -10) 1)
     (should (equal 8 (loophabits-best-streak
                       (loophabits-find "Test habit"))))
     ;; Today is due again (no check in the trailing week) and has no
     ;; entry: the current streak is broken.
     (should (equal 0 (loophabits-current-streak
                       (loophabits-find "Test habit")))))))

;;; --- toggle (widget tap semantics) --------------------------------------------

(ert-deftest loophabits-toggle-cycle-yesno ()
  "Tapping cycles none -> yes -> skip -> no -> yes (Loop's order)."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (loophabits-toggle "Test habit")
     (should (equal 1 (lh-entry-value (loophabits-find "Test habit")
                                      (lh-today))))
     (loophabits-toggle "Test habit")
     (should (eq 'skip (lh-entry-value (loophabits-find "Test habit")
                                       (lh-today))))
     (loophabits-toggle "Test habit")
     (should (equal 0 (lh-entry-value (loophabits-find "Test habit")
                                      (lh-today))))
     (loophabits-toggle "Test habit")
     (should (equal 1 (lh-entry-value (loophabits-find "Test habit")
                                      (lh-today)))))))

(ert-deftest loophabits-toggle-measurable-jumps-to-target ()
  "Measurable taps jump between 0 and the target."
  (with-loophabits-sandbox
   (lh-test--make :type 'measurable :target 30 :unit "pages")
   (let ((h (loophabits-find "Test habit")))
     (loophabits-toggle "Test habit")
     (should (equal 30 (lh-entry-value (loophabits-find "Test habit")
                                       (lh-today))))
     (loophabits-toggle "Test habit")
     (should (equal 0 (lh-entry-value (loophabits-find "Test habit")
                                      (lh-today)))))))

;;; --- archive -------------------------------------------------------------------

(ert-deftest loophabits-archive-tags-and-hides ()
  "Archiving adds the ARCHIVE tag and drops the habit from the list."
  (with-loophabits-sandbox
   (lh-test--make)
   (loophabits-archive (loophabits-find "Test habit"))
   (let ((h (loophabits-find "Test habit")))
     (should h)                          ; still parsed...
     (should (lh/habit-archived h))      ; ...but tagged
     (should-not (member h (loophabits--active))))))

;;; --- export / import -------------------------------------------------------------

(ert-deftest loophabits-json-round-trip ()
  "Export then import reproduces habits and entries (incl. numbers)."
  (with-loophabits-sandbox
   (lh-test--make)
   (loophabits-new "Pages" :type 'measurable :target 30 :unit "pages")
   (let ((h1 (loophabits-find "Test habit"))
         (h2 (loophabits-find "Pages"))
         (backup (make-temp-file "loophabits-backup-" nil ".json")))
     (loophabits-set h1 (lh-date-shift (lh-today) -1) 1 "felt great")
     (loophabits-set h1 (lh-today) 'skip)
     (loophabits-set h2 (lh-today) 23)
     (loophabits-export-json backup)
     ;; Import into a FRESH file.
     (let ((loophabits-file (make-temp-file "loophabits-restore-" nil ".org"))
           (lh--cache nil) (lh--cache-key nil))
       (loophabits-import-json backup)
       (let ((r1 (loophabits-find "Test habit"))
             (r2 (loophabits-find "Pages")))
         (should r1)
         (should r2)
         (should (eq 'measurable (lh/habit-type r2)))
         (should (equal 30 (lh/habit-target r2)))
         (should (equal "pages" (lh/habit-unit r2)))
         (should (equal 1 (lh-entry-value r1 (lh-date-shift (lh-today) -1))))
         (should (equal "felt great"
                        (lh-entry-note r1 (lh-date-shift (lh-today) -1))))
         (should (eq 'skip (lh-entry-value r1 (lh-today))))
         (should (equal 23 (lh-entry-value r2 (lh-today)))))))))

(ert-deftest loophabits-csv-export ()
  "CSV export writes a header and one row per entry."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit"))
         (csv (make-temp-file "loophabits-" nil ".csv")))
     (loophabits-set h (lh-today) 1 "note, with comma")
     (loophabits-export-csv csv)
     (with-temp-buffer
       (insert-file-contents csv)
       (goto-char (point-min))
       (should (looking-at "date,name,value,note"))
       (forward-line 1)
       (should (looking-at
                (format "[0-9-]+,\"Test habit\",1,\"note, with comma\"")))))))

;;; --- elwidget integration ---------------------------------------------------------

(ert-deftest loophabits-elwidget-tree-shape ()
  "The widget tree offers one tappable check per active habit."
  (with-loophabits-sandbox
   (lh-test--make :color "#ff0000")
   (loophabits-set (loophabits-find "Test habit") (lh-today) 1)
   (let ((tree (loophabits-elwidget-tree)))
     (should (equal :text (car (nth 0 tree))))     ; header line
     (let* ((row (nth 1 tree)))
       (should (eq :row (car row)))
       (let ((check (cadr row)))
         (should (eq :check (car check)))
         (should (equal t (nth 1 check)))          ; done today
         (should (equal "toggle" (plist-get (cddr check) :action)))
         (should (equal "Test habit" (plist-get (cddr check) :arg)))
         (should (equal "#ff0000" (plist-get (cddr check) :color))))))))

(ert-deftest loophabits-elwidget-state ()
  "The shadow state reports 1 for done habits, 0 otherwise."
  (with-loophabits-sandbox
   (lh-test--make)
   (loophabits-new "Second" )
   (loophabits-set (loophabits-find "Test habit") (lh-today) 1)
   (let ((state (loophabits-elwidget-state)))
     (should (equal 1 (cdr (assoc "Test habit" state))))
     (should (equal 0 (cdr (assoc "Second" state)))))))

;;; --- dashboard mark ---------------------------------------------------------------

(ert-deftest loophabits-mark-glyphs ()
  "Today's mark matches the computed value."
  (with-loophabits-sandbox
   (lh-test--make)
   (let ((h (loophabits-find "Test habit")))
     (should (equal "[ ]" (loophabits--mark h)))
     (loophabits-set h (lh-today) 1)
     (should (equal "[X]" (loophabits--mark (loophabits-find "Test habit"))))
     (loophabits-set h (lh-today) 'skip)
     (should (equal "[-]" (loophabits--mark (loophabits-find "Test habit"))))
     (loophabits-set h (lh-today) 'q)
     (should (equal "[?]" (loophabits--mark (loophabits-find "Test habit")))))))

(provide 'test-loophabits)
;;; test-loophabits.el ends here

;;; --- elwidget widgets (v0.2) ---------------------------------------------------

(ert-deftest loophabits--on-event-toggles ()
  "A \"toggle\" tap flips the habit for today and asks for a refresh."
  (with-loophabits-sandbox
   (lh-test--make)
   (should (loophabits--on-event "toggle" "Test habit"))
   (should (lh-completed-p (loophabits-find "Test habit") (lh-today)))
   (should-not (loophabits--on-event "other" "Test habit"))))

(ert-deftest loophabits--today-tree-shape ()
  "Header row with done/total progress + one tappable check per habit."
  (with-loophabits-sandbox
   (lh-test--make :color "#ff0000")
   (loophabits-new "Second" :type 'measurable :target 10 :unit "pages")
   (loophabits-set (loophabits-find "Test habit") (lh-today) 1)
   (let ((tree (loophabits--today-tree)))
     ;; Header row: "Habits 1/2" text + a progress node.
     (let ((header (nth 0 tree)))
       (should (eq :row (car header)))
       (should (cl-some (lambda (n) (and (eq (car n) :text)
                                         (string-match "Habits 1/2" (nth 1 n))))
                        (cdr header)))
       (should (cl-some (lambda (n) (eq (car n) :progress)) (cdr header))))
     ;; Check row: one check per active habit, toggle action, name arg.
     ;; (--active sorts by :ORDER: then name, so assert by :arg, not position.)
     (let* ((row (nth 1 tree))
            (checks (cl-remove-if-not (lambda (n) (eq (car n) :check)) (cdr row)))
            (by-arg (lambda (name)
                      (cl-find-if (lambda (c) (equal (plist-get (cddr c) :arg)
                                                     name))
                                  checks))))
       (should (eq :row (car row)))
       (should (equal 2 (length checks)))
       (should (equal t (nth 1 (funcall by-arg "Test habit"))))     ; done
       (should (equal 'off (nth 1 (funcall by-arg "Second"))))      ; not done
       (dolist (c checks)
         (should (equal "toggle" (plist-get (cddr c) :action))))))))

(ert-deftest loophabits--today-tree-empty-and-overflow ()
  "No habits: friendly text.  More than six: a +N counter, six checks."
  (with-loophabits-sandbox
   (let ((tree (loophabits--today-tree)))
     (should (cl-some (lambda (n) (and (eq (car n) :text)
                                       (string-match "No habits" (nth 1 n))))
                      tree)))
   (dotimes (i 8)
     (loophabits-new (format "H%d" i)))
   (let* ((tree (loophabits--today-tree))
          (row (nth 1 tree))
          (checks (cl-remove-if-not (lambda (n) (eq (car n) :check)) (cdr row)))
          (texts (cl-remove-if-not (lambda (n) (eq (car n) :text)) (cdr row))))
     (should (equal 6 (length checks)))
     (should (cl-some (lambda (n) (equal "+2" (nth 1 n))) texts)))))

(ert-deftest loophabits--progress-tree-shape ()
  "Measurable habits render value/target bars; yesno ones stay out."
  (with-loophabits-sandbox
   (lh-test--make)                       ; yesno: not in this widget
   (loophabits-new "Read" :type 'measurable :target 30 :unit "pages"
                   :color "#ff0000")
   (loophabits-new "Water" :type 'measurable :target 8 :unit "glasses")
   (loophabits-set (loophabits-find "Read") (lh-today) 12)
   (let ((tree (loophabits--progress-tree)))
     (let ((bars (cl-remove-if-not (lambda (n) (eq (car n) :row)) (cdr tree))))
       (should (equal 2 (length bars)))
       (let ((read-bar (cl-find-if
                        (lambda (n) (cl-some (lambda (c)
                                                (and (eq (car c) :progress)
                                                     (equal 12 (plist-get (cdr c) :value))))
                                              (cdr n)))
                        bars)))
         (should read-bar)
         (let ((prog (cl-find-if (lambda (c) (eq (car c) :progress))
                                 (cdr read-bar))))
           (should (equal 30 (plist-get (cdr prog) :max)))
           (should (string-match "12/30 pages" (plist-get (cdr prog) :label)))
           (should (equal "#ff0000" (plist-get (cdr prog) :color))))))))
  ;; Zero progress renders 0/target honestly.
  (with-loophabits-sandbox
   (loophabits-new "Walk" :type 'measurable :target 5000 :unit "steps")
   (let ((tree (loophabits--progress-tree)))
     (should (cl-some (lambda (n) (and (eq (car n) :row)
                                       (cl-some (lambda (c)
                                                  (and (eq (car c) :progress)
                                                       (zerop (plist-get (cdr c) :value))))
                                                (cdr n))))
                      (cdr tree)))))
  ;; No measurable habits at all: the friendly text, no bars.
  (with-loophabits-sandbox
   (loophabits-new "Meditate")
   (let ((tree (loophabits--progress-tree)))
     (should (cl-some (lambda (n) (and (eq (car n) :text)
                                       (string-match "No measurable" (nth 1 n))))
                      tree))
     (should-not (cl-some (lambda (n) (eq (car n) :row)) (cdr tree))))))

;;; --- widget steppers: tick AND edit numbers from the home screen --------------

(ert-deftest loophabits-bump-measurable ()
  "Bumping a measurable habit adds to today's entry, floored at zero."
  (with-loophabits-sandbox
   (loophabits-new "Read" :type 'measurable :target 30 :unit "pages")
   (should (equal 3 (loophabits-bump "Read" 3)))
   (should (equal 3 (lh-entry-value (loophabits-find "Read") (lh-today))))
   (should (equal 7 (loophabits-bump "Read" 4)))
   ;; floors at zero, never negative
   (should (equal 0 (loophabits-bump "Read" -10)))
   (should (equal 0 (lh-entry-value (loophabits-find "Read") (lh-today))))))

(ert-deftest loophabits-bump-yesno ()
  "Bumping a yes/no habit marks it done (positive) or not (negative)."
  (with-loophabits-sandbox
   (lh-test--make)
   (should (equal 1 (loophabits-bump "Test habit" 1)))
   (should (lh-completed-p (loophabits-find "Test habit") (lh-today)))
   (should (equal 0 (loophabits-bump "Test habit" -1)))
   (should-not (lh-completed-p (loophabits-find "Test habit") (lh-today)))))

(ert-deftest loophabits--on-event-inc-dec ()
  "Widget stepper events adjust the habit behind the #value arg."
  (with-loophabits-sandbox
   (loophabits-new "Read" :type 'measurable :target 30 :unit "pages")
   (let ((arg (loophabits--value-arg "Read")))
     (should (loophabits--on-event "inc" arg))
     (should (loophabits--on-event "inc" arg))
     (should (equal 2 (lh-entry-value (loophabits-find "Read") (lh-today))))
     (should (loophabits--on-event "dec" arg))
     (should (equal 1 (lh-entry-value (loophabits-find "Read") (lh-today))))
     ;; plain names (no suffix) still resolve
     (should (loophabits--on-event "inc" "Read"))
     (should (equal 2 (lh-entry-value (loophabits-find "Read") (lh-today)))))))

(ert-deftest loophabits--progress-tree-steppers ()
  "Each measurable row carries - and + buttons and a tappable bar."
  (with-loophabits-sandbox
   (loophabits-new "Read" :type 'measurable :target 30 :unit "pages"
                   :color "#ff0000")
   (loophabits-set (loophabits-find "Read") (lh-today) 12)
   (let* ((tree (loophabits--progress-tree))
          (row (cl-find-if (lambda (n) (eq (car n) :row)) (cdr tree)))
          (kids (cdr row))
          (minus (cl-find-if (lambda (c) (eq (car c) :button)) kids))
          (plus (cl-find-if (lambda (c) (and (eq (car c) :button)
                                              (equal "+" (nth 1 c))))
                            kids))
          (bar (cl-find-if (lambda (c) (eq (car c) :progress)) kids)))
     (should (equal "-" (nth 1 minus)))
     (should (equal "dec" (plist-get (cddr minus) :action)))
     (should (equal (loophabits--value-arg "Read")
                    (plist-get (cddr minus) :arg)))
     (should plus)
     (should (equal "inc" (plist-get (cddr plus) :action)))
     (should (equal "inc" (plist-get (cdr bar) :action)))
     (should (equal (loophabits--value-arg "Read")
                    (plist-get (cdr bar) :arg)))
     ;; fmt template with the live value substituted as the label
     (should (equal "{v}/30 pages" (plist-get (cdr bar) :fmt)))
     (should (equal "12/30 pages" (plist-get (cdr bar) :label))))))

(ert-deftest loophabits-elwidget-state-value-keys ()
  "Measurable habits shadow both the check key and the #value key."
  (with-loophabits-sandbox
   (lh-test--make)
   (loophabits-new "Read" :type 'measurable :target 30 :unit "pages")
   (loophabits-set (loophabits-find "Read") (lh-today) 12)
   (let ((state (loophabits-elwidget-state)))
     ;; yesno: one key, 0/1
     (should (equal 0 (cdr (assoc "Test habit" state))))
     (should-not (assoc (loophabits--value-arg "Test habit") state))
     ;; measurable: done-today 0/1 AND the numeric value
     (should (equal 0 (cdr (assoc "Read" state))))
     (should (equal 12 (cdr (assoc (loophabits--value-arg "Read") state)))))))
