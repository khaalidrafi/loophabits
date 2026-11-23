;;; loophabits.el --- Loop Habit Tracker features on Org files -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: GLM 5.3 <glm-5.3@z.ai>
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: habits, org, tools

;;; Commentary:

;; ALL the features of Loop Habit Tracker (iSoron/uhabits), on plain
;; Org files -- built so Emacs Android doubles as your habit tracker
;; (Owner order 2026-11-15).  The scoring and streak math is the REAL
;; Loop algorithm, read from uhabits core (Score.kt / StreakList.kt /
;; Entry.kt, 2026-11-15):

;;   multiplier = 0.5 ^ (sqrt(frequency) / 13)
;;   score      = previous * multiplier + checkmark * (1 - multiplier)

;; Feature map (Loop -> here):
;;   yes/no habits ................ habits with :TYPE: yesno
;;   measurable habits ............ :TYPE: measurable + :TARGET: + :UNIT:
;;   at-most measurable habits .... :TYPE: measurable-at-most
;;   flexible schedules ........... :FREQ: N/D (daily, weekly, 3/7,
;;                                  1/14; weekday sets map to N/7)
;;   habit score .................. exact Loop recurrence above
;;   streaks ...................... consecutive completed days, computed
;;                                  entries bridge non-due days (auto)
;;   history ...................... 365-day grid + per-weekday stats in
;;                                  the details buffer
;;   reminders .................... :REMINDER: HH:MM + Android
;;                                  notifications (android-notifications-
;;                                  notify) or desktop notifications
;;   widgets ...................... three elwidget specs (full list,
;;                                  today's checks + progress, measurable
;;                                  bars with +/- steppers) via
;;                                  loophabits-register-widgets, plus
;;                                  the org-habits delegation
;;   notes on checkmarks .......... text after the value in the LOGBOOK
;;   skip (not applicable) ........ value `s' -- excluded from the
;;                                  scoring window, does not break streaks
;;   question marks ............... value `q' (unknown) -- rendered dim
;;   archive / reorder / pause .... :ARCHIVE: tag+move, :ORDER:, :PAUSED:
;;   export ....................... CSV (date,name,value,note) + JSON
;;                                  backup of everything
;;   import ....................... the same JSON back
;;   no limits, offline, free ..... plain Org text

;; Storage is ONE org file (default ~/org/habits.org); each habit is a
;; level-1 heading with a property drawer and a LOGBOOK of entries:

;;   * Read a book                                             :habit:
;;   :PROPERTIES:
;;   :TYPE: yesno
;;   :FREQ: 1/1
;;   :COLOR: #7dcfff
;;   :REMINDER: 21:30
;;   :END:
;;   :LOGBOOK:
;;   - [2026-11-15 Sat 21:32] 1
;;   - [2026-11-14 Fri] s   was traveling
;;   :END:

;; Entry lines: - [DATE [TIME]] VALUE [note]  where VALUE is 1, 0,
;; s(kip), q(uestion) or a number (measurable habits).

;;; Code:

(require 'org)
(require 'org-element)
(require 'json)
(require 'cl-lib)

(defgroup loophabits nil
  "Loop Habit Tracker features on Org files."
  :group 'org)

(defcustom loophabits-file "~/org/habits.org"
  "The org file holding habits (created on first use)."
  :type 'file)

(defcustom loophabits-archive-heading "Archive"
  "Archived habits move under this heading."
  :type 'string)

(defcustom loophabits-notify-function #'loophabits--notify
  "How reminders are delivered."
  :type 'function)

(defcustom loophabits-widget-step 1
  "How much one stepper tap on a widget changes a measurable habit.
Buttons and the bar itself on the loophabits-progress widget adjust
today's value by this much per tap (the dashboard `v' command still
sets exact values)."
  :type 'number)

;;; --- Data model ------------------------------------------------------------

(cl-defstruct (lh/habit
               (:constructor lh/habit-create))
  name type target unit color freq-num freq-den reminder paused
  archived order created entries)

;; Entry: (DATE . (VALUE . NOTE)) with DATE = (Y M D), VALUE =
;; number | 1 (yes) | 0 (no) | skip | q.

(defun lh-today ()
  "Today as (Y M D)."
  (let ((d (decode-time)))
    (list (nth 5 d) (nth 4 d) (nth 3 d))))

(defun lh-date->time (date)
  (encode-time 0 0 0 (nth 2 date) (nth 1 date) (nth 0 date)))

(defun lh-time->date (time)
  (let ((d (decode-time time)))
    (list (nth 5 d) (nth 4 d) (nth 3 d))))

(defun lh-date< (a b)
  (time-less-p (lh-date->time a) (lh-date->time b)))

(defun lh-date-diff (a b)
  "Days from B to A."
  (floor (/ (- (float-time (lh-date->time a))
               (float-time (lh-date->time b))) 86400.0)))

(defun lh-date-shift (date n)
  "DATE shifted by N days."
  (lh-time->date (time-add (lh-date->time date) (* n 86400))))

(defun lh-format-date (date)
  (format-time-string "%Y-%m-%d" (lh-date->time date)))

(defun lh-parse-date (string)
  "Parse YYYY-MM-DD from STRING -> (Y M D), or nil.
Wrapped in `save-match-data': callers routinely use `match-string'
on their own match right after this, and a bare `string-match' here
would clobber the shared match data under them."
  (save-match-data
    (when (and (stringp string)
               (string-match
                "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                string))
      (list (string-to-number (match-string 1 string))
            (string-to-number (match-string 2 string))
            (string-to-number (match-string 3 string))))))

(defun lh-clamp (lo hi x)
  (max lo (min hi x)))

;;; --- Parsing ---------------------------------------------------------------

(defvar lh--cache nil
  "Cached habit list.")
(defvar lh--cache-key nil
  "Cache key: (mtime . file).")

(defun loophabits--file ()
  (expand-file-name loophabits-file))

(defun loophabits-load (&optional force)
  "Parse `loophabits-file' into habit structs.  Cached by mtime."
  (let* ((file (loophabits--file))
         (key (list (file-attribute-modification-time
                     (file-attributes file))
                    file)))
    (if (and (not force) (equal key lh--cache-key) lh--cache)
        lh--cache
      (setq lh--cache-key key
            lh--cache (lh--parse-file file)))))

(defun lh--parse-file (file)
  "Parse FILE into habits (creates the file if absent)."
  (unless (file-exists-p file)
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "#+TITLE: Habits\n\n")))
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let ((habits nil))
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (h)
          (when (= (org-element-property :level h) 1)
            (let ((habit (lh--parse-habit h file)))
              (when habit (push habit habits))))))
      (nreverse habits))))

(defun lh--parse-habit (headline file)
  "Parse one habit from HEADLINE (org-element) in FILE."
  (let* ((title (org-element-property :raw-value headline))
         (tags (org-element-property :tags headline))
         (entries nil)
         type target unit color reminder paused order created
         (freq-num 1) (freq-den 1))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (goto-char (org-element-property :begin headline))
      (let ((bound (save-excursion (org-end-of-subtree t))))
        (setq type (pcase (org-entry-get (point) "TYPE")
                     ("measurable" 'measurable)
                     ("measurable-at-most" 'measurable-at-most)
                     (_ 'yesno))
              target (ignore-errors
                       (string-to-number
                        (or (org-entry-get (point) "TARGET") "")))
              unit (org-entry-get (point) "UNIT")
              color (org-entry-get (point) "COLOR")
              reminder (org-entry-get (point) "REMINDER")
              paused (equal "yes" (org-entry-get (point) "PAUSED"))
              order (ignore-errors
                      (string-to-number
                       (or (org-entry-get (point) "ORDER") "")))
              created (or (lh-parse-date
                           (or (org-entry-get (point) "CREATED") ""))
                          (lh-today)))
        (let ((fm (concat ":FREQ:[ \t]+\\([0-9]+\\)/\\([0-9]+\\)")))
          (save-excursion
            (when (re-search-forward fm bound t)
              (setq freq-num (string-to-number (match-string 1))
                    freq-den (string-to-number (match-string 2))))))
        ;; LOGBOOK entries.
        (let ((case-fold-search t))
          (save-excursion
            (when (re-search-forward
                   ":LOGBOOK:[ \t]*\n\\(\\(?:.*\n\\)*?\\):END:" bound t)
              (dolist (line (split-string (match-string 1) "\n" t))
                (when (string-match
                       (concat "^- \\[\\([0-9-]+\\)\\(?: [A-Za-z]+"
                               "\\(?: [0-9:]+\\)?\\)?\\][ \t]+"
                               "\\(s\\|q\\|[-0-9.]+\\)\\(?:[ \t]+\\(.*\\)\\)?$")
                       line)
                  (let ((date (lh-parse-date (match-string 1 line)))
                        (v (match-string 2 line))
                        (note (or (match-string 3 line) "")))
                    (when date
                      ;; Proper 3-list (DATE VALUE NOTE): a dotted
                      ;; (VALUE . NOTE) pair would break nth-based
                      ;; accessors on string notes.
                      (push (list date
                                  (cond
                                   ((string= v "s") 'skip)
                                   ((string= v "q") 'q)
                                   (t (string-to-number v)))
                                  note)
                            entries))))))))))
    ;; Build the struct outside the file-reading `with-temp-buffer'.
    (lh/habit-create
     :name title :type type :target (or target 0) :unit unit
     :color (or color "#7dcfff")
     :freq-num freq-num :freq-den freq-den
     :reminder reminder :paused paused
     :archived (and (member "ARCHIVE" tags) t)
     :order (or order 0)
     :created created
     :entries (sort (nreverse entries)
                    (lambda (a b) (lh-date< (car a) (car b)))))))

(defun lh-entry-value (habit date)
  "Raw stored entry value for DATE, or nil.
Entries are (DATE VALUE . NOTE) lists; this returns VALUE."
  (nth 1 (assoc date (lh/habit-entries habit) #'equal)))

(defun lh-entry-note (habit date)
  "Note stored with DATE's entry, or nil."
  (nth 2 (assoc date (lh/habit-entries habit) #'equal)))

(defun lh-yes-count (habit upto-date window)
  "Manual yes entries in the WINDOW days ending at UPTO-DATE."
  (let ((n 0)
        (lo (lh-date-shift upto-date (- (1- window)))))
    (dolist (e (lh/habit-entries habit))
      (let ((d (car e)) (v (cadr e)))
        (when (and (equal v 1)
                   (not (lh-date< d lo))
                   (not (lh-date< upto-date d)))
          (cl-incf n))))
    n))

(defun lh-due-p (habit date)
  "Was the habit still due on DATE (quota unmet in the window)?"
  (let* ((num (lh/habit-freq-num habit))
         (den (lh/habit-freq-den habit)))
    (if (and (= num 1) (= den 1))
        t
      (< (lh-yes-count habit (lh-date-shift date -1) den) num))))

(defun lh-completed-p (habit date)
  "Does DATE count as completed (streaks, grids, scores)?"
  (let ((v (lh-computed-value habit date)))
    (pcase (lh/habit-type habit)
      ('measurable
       (and (numberp v) (> (lh/habit-target habit) 0)
            (>= v (lh/habit-target habit))))
      ('measurable-at-most
       (and (numberp v) (> (lh/habit-target habit) 0)
            (<= v (lh/habit-target habit))))
      (_ (memq v '(yes auto))))))

(defun lh-computed-value (habit date)
  "Computed value for DATE following Loop semantics.
Returns skip, q, a number, or the symbols yes/no/auto:
- yes  = explicitly done; no = expected but missed;
- auto = not expected (before creation, or quota already met).
Numbers stay numbers for measurable habits only; a yes/no habit's
raw 1/0 entries surface as yes/no so every consumer (completion,
streaks, scores, grids) can compare against the symbols."
  (let ((raw (lh-entry-value habit date)))
    (cond
     ((eq raw 'skip) 'skip)
     ((eq raw 'q) 'q)
     ((numberp raw)
      (if (memq (lh/habit-type habit)
                '(measurable measurable-at-most))
          raw
        (if (zerop raw) 'no 'yes)))
     (t
      (cond
       ((lh-date< date (lh/habit-created habit)) 'auto)
       ((and (not (lh-due-p habit date))
             (eq (lh/habit-type habit) 'yesno))
        'auto)
       (t 'no))))))

;;; --- Score (exact Loop recurrence) -----------------------------------------

(defun lh--score-day (habit v window rolling prev num den multiplier target)
  "One step of Loop's score recurrence.  Returns (WINDOW ROLLING PREV).
SKIP/q days never reach this function (excluded by the caller, as in
uhabits ScoreList.recompute).  WINDOW slides to DEN entries; ROLLING
tracks the window's yes-count (boolean) or value-sum (measurable)."
  (push v window)
  ;; Slide: drop the oldest value and take its contribution back.
  (when (> (length window) den)
    (let ((oldest (car (last window))))
      (setq window (butlast window))
      (cond
       ((memq (lh/habit-type habit) '(measurable measurable-at-most))
        (setq rolling (- rolling (max 0 (or oldest 0)))))
       ((eq oldest 'yes)
        (setq rolling (- rolling 1.0))))))
  (cond
   ((memq (lh/habit-type habit) '(measurable measurable-at-most))
    (setq rolling (+ rolling (max 0 (if (numberp v) v 0))))
    (let ((pct (if (eq (lh/habit-type habit) 'measurable)
                   ;; at-least: fraction of the daily target met
                   (if (> target 0)
                       (min 1.0 (/ rolling target))
                     1.0)
                 ;; at-most: being under target is the success state
                 (if (> target 0)
                     (lh-clamp 0.0 1.0
                               (- 1.0 (/ (- rolling target) target)))
                   (if (> rolling 0) 0.0 1.0)))))
      (setq prev (+ (* prev multiplier)
                    (* pct (- 1 multiplier))))))
   (t
    (when (eq v 'yes)
      (setq rolling (+ rolling 1.0)))
    (let ((pct (min 1.0 (if (> num 0) (/ rolling num) 1.0))))
      (setq prev (+ (* prev multiplier)
                    (* pct (- 1 multiplier)))))))
  (list window rolling prev))

(defun loophabits-score (habit &optional date)
  "Loop habit score for DATE (default today), 0..100.

The recurrence is uhabits' exactly (Score.kt):
  multiplier = 0.5 ^ (sqrt(frequency) / 13)
  score      = previous * multiplier + checkmark * (1 - multiplier)
Boolean non-daily habits double numerator/denominator to smooth
irregular schedules (ScoreList.recompute)."
  (let* ((date (or date (lh-today)))
         (freq (/ (float (lh/habit-freq-num habit))
                  (lh/habit-freq-den habit)))
         (numerical (memq (lh/habit-type habit)
                          '(measurable measurable-at-most)))
         (num (if (and (not numerical) (< freq 1.0))
                  (* 2 (lh/habit-freq-num habit))
                (lh/habit-freq-num habit)))
         (den (if (and (not numerical) (< freq 1.0))
                  (* 2 (lh/habit-freq-den habit))
                (lh/habit-freq-den habit)))
         (multiplier (expt 0.5 (/ (sqrt freq) 13.0)))
         (window nil)
         (rolling 0.0)
         (prev (if (eq (lh/habit-type habit) 'measurable-at-most)
                   1.0 0.0))
         (start (lh/habit-created habit))
         (days (1+ (max 0 (lh-date-diff date start))))
         (target (lh/habit-target habit)))
    (dotimes (i days)
      (let* ((d (lh-date-shift start i))
             (v (lh-computed-value habit d)))
        (unless (memq v '(skip q))
          (let ((res (lh--score-day habit v window rolling prev
                                    num den multiplier target)))
            (setq window (nth 0 res)
                  rolling (nth 1 res)
                  prev (nth 2 res))))))
    (* 100.0 (lh-clamp 0.0 1.0 prev))))

(defun loophabits-streaks (habit)
  "All streaks (START END LEN) oldest-first, Loop-style."
  (let ((streaks nil)
        (date (lh-today))
        (start (lh/habit-created habit))
        (run nil))
    (while (not (lh-date< date start))
      (if (lh-completed-p habit date)
          (push date run)
        (when run
          (push (list (car (last run)) (car run) (length run)) streaks)
          (setq run nil)))
      (setq date (lh-date-shift date -1)))
    (when run
      (push (list (car (last run)) (car run) (length run)) streaks))
    streaks))

(defun loophabits-current-streak (habit)
  "Streak length ending today (or yesterday; auto days bridge).
`loophabits-streaks' returns runs oldest-first, so the LIVE streak is
the LAST one -- and it only counts while its end is today or yesterday
(a streak ending earlier is history, however long it was)."
  (let* ((streaks (loophabits-streaks habit))
         (newest (car (last streaks))))
    (if (and newest
             (not (lh-date< (nth 1 newest)
                            (lh-date-shift (lh-today) -1))))
        (nth 2 newest)
      0)))

(defun loophabits-best-streak (habit)
  (apply #'max (or (mapcar (lambda (s) (nth 2 s))
                            (loophabits-streaks habit))
                   '(0))))

;;; --- Writing entries --------------------------------------------------------

(defun lh--entry-line (date value note)
  "Format one LOGBOOK entry line."
  (format "- [%s %s] %s%s\n"
          (lh-format-date date)
          (format-time-string "%a" (lh-date->time date))
          (cond ((eq value 'skip) "s")
                ((eq value 'q) "q")
                ((numberp value) (number-to-string value))
                (t "1"))
          (if (or (null note) (string-empty-p note))
              ""
            (concat " " note))))

(defun loophabits-set (habit date value &optional note)
  "Store VALUE (and NOTE) for DATE on HABIT."
  (let ((file (loophabits--file)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (if (not (re-search-forward
                  (concat "^[*] +" (regexp-quote (lh/habit-name habit))
                          "\\(?:[ \t]*:.*\\)?$")
                  nil t))
            (error "loophabits: heading not found: %s"
                   (lh/habit-name habit))
          (let ((end (save-excursion (org-end-of-subtree t))))
            (unless (re-search-forward ":LOGBOOK:" end t)
              ;; Create the LOGBOOK AFTER the PROPERTIES drawer (Org
              ;; only reads a property drawer that directly follows
              ;; the heading, so a LOGBOOK wedged in between would
              ;; hide TYPE/TARGET/FREQ/... from org-entry-get).
              (goto-char (line-end-position))
              (forward-line 1)
              (when (looking-at "[ \t]*:PROPERTIES:")
                (re-search-forward "^[ \t]*:END:" end t)
                (forward-line 1))
              (insert ":LOGBOOK:\n:END:\n")
              (forward-line -1)
              (re-search-backward ":LOGBOOK:"))
            (forward-line 1)
            ;; Replace any existing entry for DATE, keep order.
            (let ((re (concat "^[ \t]*- \\[" (lh-format-date date))))
              (while (and (not (looking-at ":END:"))
                          (not (eobp))
                          (< (point) end))
                (if (looking-at re)
                    (delete-region (point)
                                   (progn (forward-line 1) (point)))
                  (forward-line 1))))
            (insert (lh--entry-line date value note))
            (save-buffer)
            (loophabits-load 'force)))))))

(defun loophabits-find (name)
  "Habit named NAME (or nil)."
  (cl-find name (loophabits-load)
           :test #'equal :key #'lh/habit-name))

(defun loophabits-toggle (id)
  "Toggle habit named ID for today (widget tap semantics).
Cycle for yes/no habits: none -> yes -> skip -> no -> yes (Loop's
nextToggleValue).  Measurable habits jump between 0 and the target."
  (let ((habit (loophabits-find id)))
    (when habit
      (let ((v (lh-entry-value habit (lh-today))))
        (loophabits-set habit (lh-today)
                        (cond
                         ((memq (lh/habit-type habit)
                                '(measurable measurable-at-most))
                          (if (lh-completed-p habit (lh-today))
                              0 (lh/habit-target habit)))
                         ((equal v 1) 'skip)
                         ((eq v 'skip) 0)
                         ((equal v 0) 1)
                         (t 1)))))))

(defun loophabits-bump (name delta)
  "Change habit NAME's value for today by DELTA (widget steppers).
Measurable habits add DELTA to today's entry, never below zero;
yes/no habits treat any positive DELTA as done and any negative one
as not done.  Return the new value.  One stepper tap is
`loophabits-widget-step'; the dashboard `v' command sets exact
values."
  (interactive
   (let* ((names (mapcar #'lh/habit-name (loophabits-load)))
          (name (completing-read "Habit: " names nil t)))
     (list name (read-number "Delta: " loophabits-widget-step))))
  (let ((habit (loophabits-find name)))
    (unless habit
      (error "loophabits: no habit named %s" name))
    (let ((value
           (if (memq (lh/habit-type habit)
                     '(measurable measurable-at-most))
               (let* ((raw (lh-computed-value habit (lh-today)))
                      (v (if (numberp raw) raw 0)))
                 (max 0 (+ v delta)))
             (if (> delta 0) 1 0))))
      (loophabits-set habit (lh-today) value)
      value)))

(defun loophabits-skip (habit)
  "Mark today skipped on HABIT (not applicable: no score change)."
  (loophabits-set habit (lh-today) 'skip))

(defun loophabits-note (habit note)
  "Attach NOTE to today's entry on HABIT."
  (let ((v (or (lh-entry-value habit (lh-today))
               (if (lh-completed-p habit (lh-today)) 1 0))))
    (loophabits-set habit (lh-today) v note)))

(defun loophabits-new (name &rest props)
  "Create habit NAME with PROPERTIES.
:TYPE yesno|measurable|measurable-at-most, :TARGET n, :UNIT s,
:FREQ \"N/D\", :COLOR \"#hex\", :REMINDER \"HH:MM\"."
  (let ((file (loophabits--file))
        (type (or (plist-get props :type) 'yesno))
        (target (or (plist-get props :target) 0))
        (unit (or (plist-get props :unit) ""))
        (freq (or (plist-get props :freq) "1/1"))
        (color (or (plist-get props :color) "#7dcfff"))
        (reminder (plist-get props :reminder)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      ;; insert takes strings only, so every optional property
      ;; contributes "" -- never nil -- when it is absent.
      (insert (concat
               (format "\n* %s :habit:\n" name)
               ":PROPERTIES:\n"
               (format ":TYPE: %s\n"
                       (pcase type
                         ('measurable "measurable")
                         ('measurable-at-most "measurable-at-most")
                         (_ "yesno")))
               (if (> target 0)
                   (format ":TARGET: %s\n:UNIT: %s\n" target unit)
                 "")
               (format ":FREQ: %s\n:COLOR: %s\n" freq color)
               (if (and reminder (not (string-empty-p reminder)))
                   (format ":REMINDER: %s\n" reminder)
                 "")
               ":PAUSED: no\n"
               (format ":CREATED: [%s]\n:END:\n"
                       (lh-format-date (lh-today)))))
      (save-buffer)
      (loophabits-load 'force))))

(defun loophabits-archive (habit)
  "Move HABIT under the Archive heading."
  (with-current-buffer (find-file-noselect (loophabits--file))
    (save-excursion
      (goto-char (point-min))
      (if (not (re-search-forward
                (concat "^[*] +" (regexp-quote (lh/habit-name habit))
                        "\\(?:[ \t]*:.*\\)?$")
                nil t))
          (error "loophabits: heading not found")
        ;; The ARCHIVE tag is what the parser keys `lh/habit-archived'
        ;; on; moving the heading alone would leave the habit listed
        ;; as active.
        (org-toggle-tag "ARCHIVE" 'on)
        (org-mark-subtree)
        (let ((text (buffer-substring (region-beginning) (region-end))))
          (delete-region (region-beginning) (region-end))
          (goto-char (point-max))
          (unless (re-search-backward
                   (concat "^[*] +" loophabits-archive-heading) nil t)
            (goto-char (point-max))
            (insert (format "\n* %s\n" loophabits-archive-heading)))
          (org-end-of-subtree t)
          (insert "\n" text)
          (save-buffer)
          (loophabits-load 'force))))))

;;; --- Dashboard --------------------------------------------------------------

(defvar loophabits-list-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "SPC") #'loophabits-toggle-at-point)
    (define-key m (kbd "s") #'loophabits-skip-at-point)
    (define-key m (kbd "v") #'loophabits-set-value-at-point)
    (define-key m (kbd "N") #'loophabits-note-at-point)
    (define-key m (kbd "n") #'loophabits-new-interactively)
    (define-key m (kbd "RET") #'loophabits-show-details)
    (define-key m (kbd "a") #'loophabits-archive-at-point)
    (define-key m (kbd "p") #'loophabits-pause-at-point)
    (define-key m (kbd "o") #'loophabits-open-file)
    (define-key m (kbd "g") #'loophabits-refresh)
    m))

(defun loophabits--active ()
  "Active (non-archived) habits in :ORDER:."
  (sort (cl-remove-if #'lh/habit-archived (loophabits-load))
        (lambda (a b)
          (or (< (lh/habit-order a) (lh/habit-order b))
              (and (= (lh/habit-order a) (lh/habit-order b))
                   (string< (lh/habit-name a)
                            (lh/habit-name b)))))))

(defun loophabits--mark (habit)
  "Today's mark for HABIT as a string."
  (let ((v (lh-computed-value habit (lh-today))))
    (cond ((memq v '(yes 1)) "[X]")
          ((eq v 'skip) "[-]")
          ((eq v 'q) "[?]")
          ((eq v 'auto) "   ")
          ((numberp v)
           (if (lh-completed-p habit (lh-today)) "[X]" "[ ]"))
          (t "[ ]"))))

;;;###autoload
(defun loophabits ()
  "The habit dashboard (Loop's main screen)."
  (interactive)
  (let ((buf (get-buffer-create "*Habits*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%-4s %-30s %-6s %-8s %-6s %s\n"
                        "" "Habit" "Freq" "Streak" "Score" "Today"))
        (dolist (h (loophabits--active))
          (let ((paused (lh/habit-paused h)))
            (insert
             (propertize
              (format "%-4s %-30s %-6s %-8s %-5.0f%% %s%s\n"
                      (loophabits--mark h)
                      (truncate-string-to-width
                       (lh/habit-name h) 30 nil nil "...")
                      (format "%s/%s"
                              (lh/habit-freq-num h)
                              (lh/habit-freq-den h))
                      (format "%dd" (loophabits-current-streak h))
                      (loophabits-score h)
                      (if (memq (lh/habit-type h)
                                '(measurable measurable-at-most))
                          (format "%s/%s %s"
                                  (or (lh-entry-value h (lh-today)) 0)
                                  (lh/habit-target h)
                                  (or (lh/habit-unit h) ""))
                        "")
                      (if paused " (paused)" ""))
              'lh-habit (lh/habit-name h))))))
      (loophabits-list-mode)
      (goto-char (point-min))
      (forward-line 1)
      (pop-to-buffer buf))))

(defun loophabits-refresh ()
  (interactive)
  (loophabits-load 'force)
  (loophabits))

(define-derived-mode loophabits-list-mode special-mode "Habits"
  "Loop-style habit dashboard."
  (setq buffer-read-only t))

(defun loophabits-habit-at-point ()
  (get-text-property (point) 'lh-habit))

(defun loophabits-toggle-at-point ()
  "Toggle the habit on this line."
  (interactive)
  (let ((name (loophabits-habit-at-point)))
    (when name (loophabits-toggle name) (loophabits-refresh))))

(defun loophabits-skip-at-point ()
  "Skip today for the habit on this line."
  (interactive)
  (let ((name (loophabits-habit-at-point)))
    (when name
      (loophabits-set (loophabits-find name) (lh-today) 'skip)
      (loophabits-refresh))))

(defun loophabits-set-value-at-point ()
  "Set a numeric value for a measurable habit."
  (interactive)
  (let* ((name (loophabits-habit-at-point))
         (habit (when name (loophabits-find name))))
    (when (and habit (memq (lh/habit-type habit)
                           '(measurable measurable-at-most)))
      (let ((v (read-number
                (format "Value (%s): " (or (lh/habit-unit habit) "units"))
                (or (lh-entry-value habit (lh-today))
                    (lh/habit-target habit)))))
        (loophabits-set habit (lh-today) v)
        (loophabits-refresh)))))

(defun loophabits-note-at-point ()
  "Add a note to today's check-in."
  (interactive)
  (let* ((name (loophabits-habit-at-point))
         (habit (when name (loophabits-find name))))
    (when habit
      (loophabits-note habit (read-string "Note: "))
      (loophabits-refresh))))

(defun loophabits-new-interactively ()
  "Create a habit (Loop's habit editor, minibuffer edition)."
  (interactive)
  (let* ((name (read-string "Habit name: "))
         (type (intern (completing-read
                        "Type: " '("yesno" "measurable"
                                   "measurable-at-most") nil t)))
         (target (if (eq type 'yesno)
                     0
                   (read-number "Daily target: " 1)))
         (unit (if (eq type 'yesno)
                   ""
                 (read-string "Unit (e.g. pages): ")))
         (freq (completing-read
                "Frequency (N/D): "
                '("1/1" "1/7" "2/7" "3/7" "1/14" "1/30") nil nil "1/1"))
         (color (read-string "Color (#hex): " "#7dcfff"))
         (reminder (read-string "Reminder HH:MM (empty = none): ")))
    (apply #'loophabits-new name
           :type type :target target :unit unit :freq freq :color color
           (unless (string-empty-p reminder)
             (list :reminder reminder)))
    (loophabits-refresh)))

(defun loophabits-pause-at-point ()
  "Toggle pause on the habit at point."
  (interactive)
  (let* ((name (loophabits-habit-at-point))
         (habit (when name (loophabits-find name))))
    (when habit
      (with-current-buffer (find-file-noselect (loophabits--file))
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward
                 (concat "^[*] +" (regexp-quote name)) nil t)
            (org-set-property "PAUSED"
                              (if (lh/habit-paused habit) "no" "yes"))
            (save-buffer))))
      (loophabits-load 'force)
      (loophabits-refresh))))

(defun loophabits-open-file ()
  (interactive)
  (find-file (loophabits--file)))

(defun loophabits-archive-at-point ()
  "Archive the habit at point."
  (interactive)
  (let ((name (loophabits-habit-at-point)))
    (when name
      (loophabits-archive (loophabits-find name))
      (loophabits-refresh))))

;;; --- Details (history grid + stats) -----------------------------------------

;;;###autoload
(defun loophabits-show-details ()
  "Stats + 365-day history grid for the habit at point."
  (interactive)
  (let* ((name (loophabits-habit-at-point))
         (habit (when name (loophabits-find name))))
    (unless habit (user-error "No habit here"))
    (let ((buf (get-buffer-create (format "*Habit: %s*" name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "%s -- %s\n\n" name
                          (format-time-string "%Y-%m-%d %a")))
          (insert (format "Score:        %.0f%%\n"
                          (loophabits-score habit)))
          (insert (format "Streak:       %dd current, %dd best\n"
                          (loophabits-current-streak habit)
                          (loophabits-best-streak habit)))
          (insert (format "Total checks: %d\n"
                          (cl-count-if
                           (lambda (e) (equal (cadr e) 1))
                           (lh/habit-entries habit))))
          ;; Per-weekday completion rates (last 12 weeks, due days only).
          (let ((rates (make-vector 7 0))
                (counts (make-vector 7 0)))
            (dotimes (i 84)
              (let* ((d (lh-date-shift (lh-today) (- i)))
                     (dow (nth 6 (decode-time (lh-date->time d)))))
                (when (lh-due-p habit d)
                  (cl-incf (aref counts dow))
                  (when (lh-completed-p habit d)
                    (cl-incf (aref rates dow))))))
            (insert "\nCompletion by weekday (12 weeks):\n")
            (dotimes (dow 7)
              (insert (format "  %s %3d%%\n"
                              (nth dow '("Sun" "Mon" "Tue" "Wed"
                                         "Thu" "Fri" "Sat"))
                              (if (> (aref counts dow) 0)
                                  (* 100 (/ (aref rates dow)
                                            (float (aref counts dow))))
                                0)))))
          ;; 365-day grid: rows = weeks, columns = weekdays.
          (insert "\nHistory (X done, o skip, ? unknown, . miss,\n")
          (insert "blank = not due / before habit):\n\n")
          (let* ((today (lh-today))
                 (start-dow (nth 6 (decode-time (lh-date->time today))))
                 (start (lh-date-shift today (- 364 start-dow))))
            (dotimes (week 53)
              (dotimes (dow 7)
                (let* ((d (lh-date-shift start (+ (* week 7) dow)))
                       (v (and (not (lh-date< d today))
                               (not (lh-date< d (lh/habit-created habit)))
                               (lh-computed-value habit d))))
                  (insert
                   (cond
                    ((null v) " ")
                    ((eq v 'skip) (propertize "o" 'face 'shadow))
                    ((eq v 'q) (propertize "?" 'face 'shadow))
                    ((eq v 'auto) " ")
                    ((lh-completed-p habit d)
                     (propertize "X" 'face
                                 `(:foreground ,(lh/habit-color habit))))
                    (t (propertize "." 'face '(:foreground "#f38ba8"))))))
              (insert "\n")))))
        (special-mode)
        (pop-to-buffer buf)))))

;;; --- Reminders ---------------------------------------------------------------

(defvar loophabits--reminder-timer nil)

;;;###autoload
(defun loophabits-start-reminders ()
  "Check habit reminders every minute and notify for due ones."
  (interactive)
  (setq loophabits--reminder-timer
        (run-at-time t 60 #'loophabits--remind))
  (message "loophabits: reminders started"))

;;;###autoload
(defun loophabits-stop-reminders ()
  (interactive)
  (when loophabits--reminder-timer
    (cancel-timer loophabits--reminder-timer)
    (setq loophabits--reminder-timer nil)))

(defun loophabits--remind ()
  "Remind for habits whose :REMINDER: time has arrived today."
  (let* ((now (decode-time))
         (hhmm (format "%02d:%02d" (nth 2 now) (nth 1 now)))
         (today (lh-today)))
    (dolist (h (loophabits--active))
      (let ((r (lh/habit-reminder h)))
        (when (and r (>= (length r) 5)
                   (equal (substring r 0 5) hhmm)
                   (not (lh/habit-paused h))
                   (lh-due-p h today)
                   (not (lh-completed-p h today))
                   (not (equal (get (lh/habit-name h) :reminded-today)
                               today)))
          (put (lh/habit-name h) :reminded-today today)
          (funcall loophabits-notify-function
                   (lh/habit-name h)
                   (format "Time for: %s (%d%%)"
                           (lh/habit-name h)
                           (round (loophabits-score h)))))))))

(defun loophabits--notify (title body)
  "Deliver a reminder: Android notification or message fallback."
  (cond
   ((fboundp 'android-notifications-notify)
    (android-notifications-notify :title title :body body))
   ((fboundp 'notifications-notify)
    (notifications-notify :title title :body body))
   (t (message "loophabits: %s -- %s" title body))))

;;; --- elwidget integration ----------------------------------------------------

;; Soft dependency: elwidget ships in emacshell and installs anywhere
;; else as an ordinary package; nothing here loads without it.
(declare-function elwidget-define "elwidget" (name &rest props))

(defun loophabits--value-arg (name)
  "Shadow-state key for habit NAME's numeric today value.
Distinct from NAME itself (the 0/1 check key), so the steppers'
  numbers never disturb the checks' instant flips."
  (concat name "#value"))

(defun loophabits--on-event (action arg)
  "Handle a widget tap.
\"toggle\" flips habit ARG (its name, 0/1 checks); \"inc\"/\"dec\"
adjust the measurable habit behind ARG -- which arrives with the
#value suffix the stepper nodes use -- by `loophabits-widget-step'."
  (cond
   ((equal action "toggle")
    (loophabits-toggle arg)
    t)
   ((member action '("inc" "dec"))
    (loophabits-bump
     (if (string-suffix-p "#value" arg)
         (substring arg 0 (- (length arg) (length "#value")))
       arg)
     (* loophabits-widget-step
        (if (equal action "inc") 1 -1)))
    t)))

(defun loophabits-elwidget-tree ()
  "The org-habits widget tree (for elwidget-org)."
  (let ((nodes (list '(:text "Habits" :size 16 :bold t :color "#89b4fa"))))
    (dolist (h (loophabits--active))
      (nconc nodes
             (list
              `(:row
                (:check ,(if (lh-completed-p h (lh-today)) t 'off)
                        :action "toggle" :arg ,(lh/habit-name h)
                        :color ,(lh/habit-color h))
                (:text ,(truncate-string-to-width
                         (concat (lh/habit-name h)
                                 (when (lh/habit-paused h) " (paused)"))
                         26 nil nil "...")
                       :size 13)
                (:text ,(format "%dd %2.0f%%"
                                (loophabits-current-streak h)
                                (loophabits-score h))
                       :size 12 :align right :color "#a6adc8")))))
    (unless (cdr nodes)
      (nconc nodes (list '(:text "No habits yet -- M-x loophabits"
                                 :size 12))))
    nodes))

(defun loophabits-elwidget-state ()
  "Shadow state for the widgets (instant taps, frozen Emacs).
Each habit contributes its NAME -> done-today 0/1 (the checks,
flipped 0<->1 by the app on \"toggle\" taps); measurable habits
additionally contribute NAME#value -> today's numeric value (the
stepper bars, bumped by the app on \"inc\"/\"dec\" taps and
re-rendered through the bar's :fmt template)."
  (mapcan
   (lambda (h)
     (let ((numeric (memq (lh/habit-type h)
                          '(measurable measurable-at-most)))
           (done (if (lh-completed-p h (lh-today)) 1 0)))
       (if numeric
           (let* ((raw (lh-computed-value h (lh-today)))
                  (v (if (numberp raw) raw 0)))
             (list (cons (lh/habit-name h) done)
                   (cons (loophabits--value-arg (lh/habit-name h)) v)))
         (list (cons (lh/habit-name h) done)))))
   (loophabits-load)))

(defun loophabits--today-tree ()
  "Compact one-line tree: a tappable check per active habit.
Header row carries the done/total progress bar (Loop's \"today\"
ring, as a bar).  At most six checks fit a 4x1 widget; the rest
count behind a \"+N\" text."
  (let* ((active (loophabits--active))
         (today (lh-today))
         (done (cl-count-if (lambda (h) (lh-completed-p h today)) active))
         (total (length active))
         (shown (seq-take active 6))
         (more (- total (length shown))))
    (append
     (list `(:row (:text ,(format "Habits %d/%d" done total)
                          :size 13 :bold t :color "#89b4fa")
                 (:progress :value ,done :max ,(max 1 total)
                            :label ,(if (zerop total)
                                        "—"
                                      (format "%d%%"
                                              (round (* 100 (/ (float done) total)))))
                            :color "#a6e3a1")))
     (if (null active)
         (list '(:text "No habits yet -- M-x loophabits" :size 12))
       (list (append
              '(:row)
              (mapcar (lambda (h)
                        `(:check ,(if (lh-completed-p h today) t 'off)
                                 :action "toggle" :arg ,(lh/habit-name h)
                                 :color ,(lh/habit-color h)))
                      shown)
              (when (> more 0)
                (list `(:text ,(format "+%d" more) :size 11
                              :color "#a6adc8")))))))))

(defun loophabits--progress-tree ()
  "Measurable habits: today's value as a bar with +/- steppers.
The bar itself is tappable (one step up); its label carries a :fmt
template the Android side re-renders from the shadow state, so taps
move the number even while Emacs is frozen in the background -- the
next Emacs sync is authoritative."
  (let ((nodes (list '(:text "Today" :size 14 :bold t :color "#89b4fa")))
        (any nil))
    (dolist (h (loophabits--active))
      (when (memq (lh/habit-type h) '(measurable measurable-at-most))
        (setq any t)
        (let* ((raw (lh-computed-value h (lh-today)))
               ;; computed-value yields the symbols yes/no/auto for
               ;; habit-day states, numbers only for actual entries;
               ;; the bar wants today's entered value, 0 otherwise.
               (v (if (numberp raw) raw 0))
               (target (lh/habit-target h))
               (bar-max (max 1 target))
               (varg (loophabits--value-arg (lh/habit-name h)))
               (fmt (format "{v}/%s %s" target (or (lh/habit-unit h) ""))))
          (nconc nodes
                 (list
                  `(:row
                    (:button "-" :action "dec" :arg ,varg
                             :color ,(lh/habit-color h))
                    (:text ,(truncate-string-to-width
                             (lh/habit-name h) 12 nil nil "...")
                           :size 12)
                    (:progress :value ,v :max ,bar-max
                               :label ,(replace-regexp-in-string
                                        "{v}" (format "%s" v) fmt t t)
                               :fmt ,fmt
                               :action "inc" :arg ,varg
                               :color ,(lh/habit-color h))
                    (:button "+" :action "inc" :arg ,varg
                             :color ,(lh/habit-color h))))))))
    (unless any
      (nconc nodes (list '(:text "No measurable habits" :size 12))))
    nodes))

;;;###autoload
(defun loophabits-register-widgets ()
  "Define the loophabits home-screen widgets (requires elwidget).

Three specs, all updatable straight from the home screen (ticks
flip instantly through the shadow state; steppers bump the number
the moment you tap, and the next Emacs sync is authoritative):

  loophabits          4x3  the full habit list (checks, streaks,
                           scores) -- the same tree elwidget-org's
                           org-habits widget delegates to
  loophabits-today    4x1  one row of checks + done/total progress
  loophabits-progress 4x2  measurable habits: value/target bars with
                           - and + steppers; the bar itself taps as
                           +1 (`loophabits-widget-step' sets the step)

Call it once from your init (emacshell: after loading loophabits),
then `M-x elwidget-refresh' and pick the specs in the Android
widget picker."
  (interactive)
  (unless (require 'elwidget nil t)
    (user-error "The elwidget package is required for the widgets"))
  (elwidget-define "loophabits"
    :title "Loophabits (tap to check)" :size [4 3]
    :render #'loophabits-elwidget-tree
    :on-event #'loophabits--on-event
    :state #'loophabits-elwidget-state)
  (elwidget-define "loophabits-today"
    :title "Habits today" :size [4 1]
    :render #'loophabits--today-tree
    :on-event #'loophabits--on-event
    :state #'loophabits-elwidget-state)
  (elwidget-define "loophabits-progress"
    :title "Measurable habits today" :size [4 2]
    :render #'loophabits--progress-tree
    :on-event #'loophabits--on-event
    :state #'loophabits-elwidget-state))

;;; --- Export / import ----------------------------------------------------------

;;;###autoload
(defun loophabits-export-csv (file)
  "Export every entry to FILE as date,name,value,note."
  (interactive "FExport habits CSV to: ")
  (with-temp-file file
    (insert "date,name,value,note\n")
    (dolist (h (loophabits-load))
      (dolist (e (lh/habit-entries h))
        (insert (format "%s,\"%s\",%s,\"%s\"\n"
                        (lh-format-date (car e))
                        (lh/habit-name h)
                        (cond ((eq (cadr e) 'skip) "s")
                              ((eq (cadr e) 'q) "q")
                              (t (format "%s" (cadr e))))
                        (or (nth 2 e) "")))))))

;;;###autoload
(defun loophabits-export-json (file)
  "Full backup: habit definitions + entries, to FILE."
  (interactive "FExport habits JSON to: ")
  (let ((data (mapcar
               (lambda (h)
                 `((name . ,(lh/habit-name h))
                   (type . ,(pcase (lh/habit-type h)
                              ('measurable "measurable")
                              ('measurable-at-most "measurable-at-most")
                              (_ "yesno")))
                   (target . ,(lh/habit-target h))
                   (unit . ,(or (lh/habit-unit h) ""))
                   (freq . ,(format "%s/%s" (lh/habit-freq-num h)
                                    (lh/habit-freq-den h)))
                   (color . ,(lh/habit-color h))
                   (reminder . ,(or (lh/habit-reminder h) ""))
                   (entries . ,(mapcar
                                (lambda (e)
                                  `((date . ,(lh-format-date (car e)))
                                    (value . ,(cond
                                               ((eq (cadr e) 'skip) "s")
                                               ((eq (cadr e) 'q) "q")
                                               (t (cadr e))))
                                    (note . ,(or (nth 2 e) ""))))
                                (lh/habit-entries h)))))
               (loophabits-load)))
        (json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode data)))))

;;;###autoload
(defun loophabits-import-json (file)
  "Import a JSON backup produced by `loophabits-export-json'."
  (interactive "fImport habits JSON from: ")
  ;; let* (NOT let): parallel-binding `let' would run json-read-file
  ;; in the OUTER scope, where json-array-type is still the default
  ;; `vector' and the parsed backup would come back as a vector.
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (data (json-read-file file)))
    (dolist (h data)
      (let ((name (cdr (assq 'name h))))
        (unless (loophabits-find name)
          (apply #'loophabits-new name
                 :type (intern (or (cdr (assq 'type h)) "yesno"))
                 :target (or (cdr (assq 'target h)) 0)
                 :unit (or (cdr (assq 'unit h)) "")
                 :freq (or (cdr (assq 'freq h)) "1/1")
                 :color (or (cdr (assq 'color h)) "#7dcfff")
                 (when (cdr (assq 'reminder h))
                   (list :reminder (cdr (assq 'reminder h))))))
        (dolist (e (cdr (assq 'entries h)))
          (loophabits-set (loophabits-find name)
                          (lh-parse-date (cdr (assq 'date e)))
                          (let ((v (cdr (assq 'value e))))
                            ;; Measurable values round-trip as JSON
                            ;; numbers; string= would signal on them.
                            (cond ((equal v "s") 'skip)
                                  ((equal v "q") 'q)
                                  ((numberp v) v)
                                  (t (string-to-number (or v "0")))))
                          (cdr (assq 'note e))))))
    (loophabits-load 'force)))

(provide 'loophabits)
;;; loophabits.el ends here
