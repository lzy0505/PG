;; This file is part of Proof General.
;; 
;; © Copyright 2020  Hendrik Tews
;; 
;; Authors: Hendrik Tews
;; Maintainer: Hendrik Tews <hendrik@askra.de>
;; 
;; License:     GPL (GNU GENERAL PUBLIC LICENSE)


;;; Commentary:
;; 
;; Coq Compile Tests (cct) --
;; ert tests for parallel background compilation for Coq
;;
;; This file contains common definitions for the automated tests of
;; parallel background compilation.


(defmacro cct-implies (p q)
  "Short-circuit logical implication.
Evaluate Q only if P is non-nil."
  `(or (not ,p) ,q))

(defun cct-goto-line (line)
  "Put point on start of line LINE.
Very similar to `goto-line', but the documentation of `goto-line'
says, programs should use this piece of code."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun cct-library-vo-of-v-file (v-src-file)
  "Return .vo file name for V-SRC-FILE.
Changes the suffix from .v to .vo.  V-SRC-FILE must have a .v suffix."
  (concat v-src-file "o"))

(defun cct-record-change-time (file)
  "Return cons of FILE and its modification time.
The modification time is an emacs time value, it's nil if file
cannot be accessed."
  (cons file (nth 5 (file-attributes file))))

(defun cct-record-change-times (files)
  "Return an assoc list of FILES with their modification times.
The modification time is an emacs time value, it's nil if file
cannot be accessed."
  (mapcar 'cct-record-change-time files))

(defun cct-split-change-times (file-change-times files)
  "Split assoc list FILE-CHANGE-TIMES.
FILE-CHANGE-TIMES must be an assoc list and FILES must be a
subset (i.e., each key occoring at most once) of the keys of
FILE-CHANGE-TIMES as list. This function returns two associations
lists (as cons cell). The car contains those associations in
FILE-CHANGE-TIMES with keys not in FILES, the cdr contains those
with keys in FILES."
  (seq-reduce
   (lambda (acc file)
     (push (assoc file (car acc)) (cdr acc))
     (setcar acc (assoc-delete-all file (car acc)))
     acc)
   files
   (cons (copy-alist file-change-times) nil)))

(defun cct-process-to-line (line)
  "Assert/retract to line LINE and wait until processing completed."
  (cct-goto-line line)
  (proof-goto-point)

  (while (or proof-second-action-list-active (consp proof-action-list))
    ;; (message "wait for coq/compilation with %d items queued\n"
    ;;          (length proof-action-list))
    ;;
    ;; accept-process-output without timeout returns rather quickly,
    ;; apparently most times without process output or any other event
    ;; to process.
    (accept-process-output nil 0.1)))

(defun cct-get-vanilla-span (line)
  "Get THE vanilla span for line LINE, report an error if there is none.
PG uses a number of overlapping and non-overlapping spans (read
overlays) in the asserted and queue region of the proof buffer,
see the comments in generic/proof-script.el. Spans of type
vanilla (stored at 'type in the span property list) are created
for real commands (not for comments). They hold various
information that is used, among others, for backtracking.

This function returns the vanilla span that covers line LINE and
reports a test failure if there is none or more than one vanilla spans."
  (let (spans)
    (cct-goto-line line)
    (setq spans (spans-filter (overlays-at (point)) 'type 'vanilla))
    (should (eq (length spans) 1))
    (car spans)))

(defun cct-last-message-line ()
  "Extract the last line from the *Messages* buffer.
Useful if the message is not present in the echo area any more
and `current-message' does not return anything."
  (save-excursion
    (set-buffer "*Messages*")
    (goto-char (point-max))
    (forward-line -1)
    (buffer-substring (point) (- (point-max) 1))))

(defun cct-check-locked (line locked-state)
  "Check that line LINE has locked state LOCKED-STATE
LOCKED-STATE must be 'locked or 'unlocked. This function checks
whether line LINE is inside or outside the asserted (locked)
region of the buffer and signals a test failure if not."
  (let ((locked (eq locked-state 'locked)))
    ;; (message "tcl line %d check %s: %s %s\n"
    ;;          line (if locked "locked" "unlocked")
    ;;          proof-locked-span
    ;;          (if (overlayp proof-locked-span)
    ;;              (span-end proof-locked-span)
    ;;            "no-span"))
    (cl-assert (or locked (eq locked-state 'unlocked))
               nil "test-check-locked 2nd argument wrong")
    (cct-goto-line line)
    (should (cct-implies locked (span-end proof-locked-span)))

    (should
     (or
      (and (not locked)
           (or (not proof-locked-span) (not (span-end proof-locked-span))))
      (and (span-end proof-locked-span)
           (funcall (if locked '< '>)
                    (point) (span-end proof-locked-span)))))))

(defun cct-locked-ancestors (line ancestors)
  "Check that the vanilla span at line LINE has ANCESTORS recorded.
The comparison treats ANCESTORS as set but the file names must
be `equal' as strings.

Ancestors are recoreded in the 'coq-locked-ancestors property of
the vanilla spans of require commands, see the in-file
documentation of coq/coq-par-compile.el."
  (let ((locked-ancestors
         (span-property (cct-get-vanilla-span line) 'coq-locked-ancestors)))
    (should
     (seq-set-equal-p locked-ancestors ancestors))))

(defun cct-file-unchanged (file time)
  "Check that modification time of FILE equals TIME.
Used to check that FILE has not been changed since TIME was
recorded before."
  (let ((file-time (nth 5 (file-attributes file))))
    ;; (message "TFU on %s: rec: %s now: %s\n"
    ;;          file
    ;;          (format-time-string "%H:%M:%S.%3N" time)
    ;;          (format-time-string "%H:%M:%S.%3N" file-time))
    (should
     (and file-time (equal time file-time)))))

(defun cct-unmodified-change-times (file-time-assoc)
  "Check that files in FILE-TIME-ASSOC have not been changed.
FILE-TIME-ASSOC must be an association list of files and emacs
times as returned by `cct-record-change-times' or
`cct-split-change-times'. This function checks that the
modification time of files in FILE-TIME-ASSOC equals the time
recorded in FILE-TIME-ASSOC, i.e., that the file has not been
changed since FILE-TIME-ASSOC has been recorded."
  (mapc
   (lambda (file-time-cons)
     (cct-file-unchanged (car file-time-cons) (cdr file-time-cons)))
   file-time-assoc))

(defun cct-file-newer (file time)
  "Check that FILE exists and its modification time is more recent than TIME."
  (let ((file-time (nth 5 (file-attributes file))))
    (should (and file-time (time-less-p time file-time)))))

(defun cct-older-change-times (file-time-assoc)
  "Check that files exist and have been changed.
FILE-TIME-ASSOC must be an association list of files and emacs
times as returned by `cct-record-change-times' or
`cct-split-change-times'. This function checks that the files in
FILE-TIME-ASSOC do exist and that their modification time is more
recent than in the association list, i.e., they have been updated
or changed since recording the time in the association."
  (mapc
   (lambda (file-time-cons)
     (cct-file-newer (car file-time-cons) (cdr file-time-cons)))
   file-time-assoc))

(defun cct-configure-proof-general ()
  "Configure Proof General for test execution."
  (setq delete-old-versions t
        coq-compile-before-require t
        coq-compile-keep-going t
        proof-auto-action-when-deactivating-scripting 'retract
        proof-three-window-enable nil
        coq-compile-auto-save 'save-coq
        coq--debug-auto-compilation nil))