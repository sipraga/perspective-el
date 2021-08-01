;;; test-perspective.el --- Tests for perspective  -*- lexical-binding: t; -*-

;; Licensed under the same terms as Emacs and under the MIT license.

;; URL: http://github.com/nex3/perspective-el
;; Created: 2019-09-18
;; By: Nathaniel Nicandro <nathanielnicandro@gmail.com>

;;; Commentary:

;;; Code:

(require 'perspective)
(require 'cl-lib)
(require 'ert)

;; Set frame size so that splitting windows doesn't result in pesky
;;
;;    "Window ... too small for splitting"
;;
;; errors.
(set-frame-height (selected-frame) 80)
(set-frame-width (selected-frame) 160)

(defun persp-test-interesting-buffer? (buf)
  "Return t if BUF is a non-temporary buffer (i.e., lacks
tell-tale leading '*' characters)."
  (and (buffer-live-p buf)
       (not (string-match-p "^[[:space:]]*?\\*" (buffer-name buf)))))

(defun persp-test-buffer-list-all ()
  "Return the list of buffers in Emacs (in all
perspectives), filtering out temporaries."
  (cl-remove-if-not #'persp-test-interesting-buffer? (buffer-list)))

(defun persp-test-buffer-list (persp)
  "Return the list of buffers in the current perspective,
filtering out temporaries."
  (cl-remove-if-not #'persp-test-interesting-buffer? (persp-buffers persp)))

(defun persp-test-match-scratch-buffers (&rest buffer-or-name)
  "Return a list of buffers that are considered *scratch* buffers.
If not nil, verify that BUFFER-OR-NAME are all the buffers that
are in the list of buffers or return nil otherwise.  Return nil
if there are no *scratch* buffers to be found.

Consider buffers being *scratch* buffers when their name begins
with \"*scratch*\".  Sort the list by names via `string-lessp'."
  (let ((scratch-buffers (mapcar #'get-buffer buffer-or-name))
        (matched-buffers (cl-remove-if-not
                          (lambda (buffer)
                            (string-match-p "^\\*scratch\\*.*$" (buffer-name buffer)))
                          (buffer-list))))
    (when (cl-every (lambda (buffer)
                      (memq buffer matched-buffers))
                    scratch-buffers)
      (sort matched-buffers
            (lambda (a b)
              (string-lessp (buffer-name a) (buffer-name b)))))))

(defun persp-test-kill-extra-buffers (&rest buffer-or-name)
  "Kill BUFFER-OR-NAME and extra scratch buffers found.
Return a list of names of the killed buffers, or nil if there's
no candidate to kill.

Extra scratch buffers have a name that begins with \"*scratch*\",
like \"*scratch* \" and \"*scratch* (NAME)\"."
  (let* (kill-list-names
         (scratch-buffer (get-buffer "*scratch*"))
         (extra-buffers (mapcar #'get-buffer buffer-or-name))
         (matched-buffers (remq scratch-buffer (persp-test-match-scratch-buffers))))
    (dolist (buffer (cl-remove-duplicates (append extra-buffers matched-buffers)))
      (when (buffer-live-p buffer)
        (push (buffer-name buffer) kill-list-names)
        (kill-buffer buffer)))
    (sort kill-list-names #'string-lessp)))

(defun persp-test-buffer-in-persps (buffer-or-name &rest persp-or-name)
  "Return the buffer BUFFER-OR-NAME when live and found in each of
PERSP-OR-NAME, and, at the same time, not in any other existing
perspective that is not PERSP-OR-NAME.  Otherwise return nil.

If PERSP-OR-NAME is nil or not given, BUFFER-OR-NAME should not
be found in any existing perspective.  Otherwise return nil.

PERSP-OR-NAME may be a perspective's name or a perspective data
object `perspective-p', if the latter it may even not exist."
  (let (whitelist
        (persps (hash-table-values (perspectives-hash)))
        (buffer (when buffer-or-name (get-buffer buffer-or-name))))
    (catch 'result
      (unless (and buffer (buffer-live-p buffer))
        (throw 'result nil))
      ;; whitelist
      (dolist (persp persp-or-name)
        (when (stringp persp)
          ;; resolve a perspective's name to its data
          (setq persp (cl-find-if (lambda (p)
                                    (equal persp (persp-name p)))
                                  persps)))
        (unless (and (perspective-p persp)
                     (memq buffer (persp-buffers persp)))
          (throw 'result nil))
        (push persp whitelist))
      ;; blacklist
      (dolist (persp (cl-set-difference persps whitelist))
        (when (memq buffer (persp-buffers persp))
          (throw 'result nil)))
      (throw 'result buffer))))

(defmacro persp-test-with-persp (&rest body)
  "Allow multiple tests to run with reasonable assumption of
isolation. This macro assumes persp-mode is turned off, then
turns on persp-mode, evaluates the body, and finally remove all
perspectives and open buffers."
  (declare (indent 0))
  `(progn
     (persp-mode 1)
     (unwind-protect
         (progn ,@body)
       (let ((other-persps (delete persp-initial-frame-name (persp-names))))
         ;; Kill other perspectives than the main perspective to get rid
         ;; of buffers that are not found in the main perspective.
         (mapc #'persp-kill other-persps)
         ;; Then get rid of perspective-specific *scratch* buffers which
         ;; have become part of the main perspective.
         (mapc (lambda (persp)
                 ;; `get-buffer' should suffice here, there's no need to
                 ;; also call `buffer-live-p' when a string is passed as
                 ;; argument to the former, but we do it anyway ;)
                 (let* ((scratch-name (format "*scratch* (%s)" persp))
                        (scratch-buffer (get-buffer scratch-name)))
                   (when (buffer-live-p scratch-buffer)
                     (kill-buffer scratch-buffer))))
               other-persps))
       (persp-mode -1)
       ;; Remove live buffers that are not temporaries.
       (mapc #'kill-buffer (persp-test-buffer-list-all)))))

(defmacro persp-test-with-temp-buffers (vars &rest body)
  "Bind temporary buffers to VARS, evaluate BODY, then kill
temporary buffers."
  (declare (indent 1))
  (let ((binds (cl-loop for var in vars collect
                        `(,var (generate-new-buffer "persp-test"))))
        (cleanup (cl-loop for var in vars collect
                          `(when (buffer-live-p ,var)
                             (kill-buffer ,var)))))
    `(let (,@binds)
       (unwind-protect
           (progn ,@body)
         ,@cleanup))))

(defmacro persp-test-with-files (temp-files? vars &rest body)
  "Bind temporary buffers with on-disk files to VARS,
evaluate BODY, then kill temporary buffers. If TEMP-FILES is t,
the files are purely temporary and will be deleted at cleanup. If
TEMP-FILES is nil, the file names are just the var symbols, will
be created and non-empty if they do not exist, and will not be
deleted at cleanup."
  (let ((binds (cl-loop for var in vars collect
                        `(,var (let ((new-buf (find-file
                                               (if ,temp-files?
                                                   (make-temp-file (symbol-name ',var))
                                                 (symbol-name ',var)))))
                                 (with-current-buffer new-buf
                                   (when (= 0 (buffer-size))
                                     (insert (buffer-file-name new-buf))
                                     (save-buffer))
                                   new-buf)))))
        (cleanup (cl-loop for var in vars collect
                          `(when (buffer-live-p ,var)
                             (when ,temp-files?
                               (delete-file (buffer-file-name ,var)))
                             (kill-buffer ,var)))))
    `(let (,@binds)
       (unwind-protect
           (progn ,@body)
         ,@cleanup))))

(defun persp-test-clean-files (&rest test-files)
  "Cleans the given TEST-FILES."
  (cl-loop for f in test-files do
           (when (file-exists-p f)
             (delete-file f))))

(ert-deftest helper-macros ()
  (should (= 0 (length (persp-test-buffer-list-all))))
  (let ((saved-path-B1 "")
        (saved-path-B2 ""))
    ;; temp files
    (persp-test-with-files t (B1 B2)
      (should (get-buffer B1))
      (setf saved-path-B1 (buffer-file-name B1))
      (should (file-exists-p saved-path-B1))
      (should (get-buffer B2))
      (setf saved-path-B2 (buffer-file-name B2))
      (should (file-exists-p saved-path-B2)))
    (should-not (file-exists-p saved-path-B1))
    (should-not (file-exists-p saved-path-B2))
    ;; non-temp files, will require cleanup
    (should-not (get-buffer "A1"))
    (should-not (get-buffer "A2"))
    (persp-test-with-files nil (A1 A2)
      (should (get-buffer A1))
      (should (get-buffer "A1"))
      (should (get-buffer A2))
      (should (get-buffer "A2")))
    ;; clean up non-temp files
    (delete-file "A1")
    (delete-file "A2"))
  ;; no buffers should be open after all this
  (should (= 0 (length (persp-test-buffer-list-all)))))

(ert-deftest basic-persp-test-with-persp ()
  "Test `persp-test-with-persp'.

When cleaning up, don't assume there's a \"*scratch* (NAME)\" for
every perspective NAME still existing before the cleanup.  That
may cause `kill-buffer' to fail passing a non-existent buffer.

Buffers like \"*dummy* (NAME)\" should not be killed just because
they follow the pattern \"*scratch* (NAME)\".

Buffers should always be killed when only found in perspectives
that are not the main perspective."
  (unwind-protect
      (persp-test-with-persp
        ;; Summary before exiting `persp-test-with-persp':
        ;;
        ;; main: *dummy*, *dummy* (A), *scratch*, *scratch* (A), *scratch* (C)
        ;;    A:          *dummy* (A)
        ;;    B:          *dummy* (B)
        ;;    C is killed before the cleanup
        ;;    D:                                  *scratch* (D)
        ;;
        ;; Expected buffers after `persp-test-with-persp' cleanup:
        ;;
        ;;       *dummy*, *dummy* (A), *scratch*, *scratch* (C)
        ;;
        ;; *scratch* (A) is killed during cleanup, because perspective
        ;; A exists before the cleanup, instead *scratch* (C) will not
        ;; be killed, because perspective C has been killed before the
        ;; cleanup.  There should be no attempt killing *scratch* (B),
        ;; since it's non-existent and *scratch* (D) is killed killing
        ;; perspective D.  *dummy* (A) persists, it is shared with the
        ;; main perspective, instead *dummy* (B) is killed killing the
        ;; perspective B, it's not shared with the main perspective.
        (let ((dummy-buffer (get-buffer-create "*dummy*"))
              (dummy-buffer-A (get-buffer-create "*dummy* (A)"))
              (dummy-buffer-B (get-buffer-create "*dummy* (B)")))
          (should persp-mode)
          (should (buffer-live-p dummy-buffer))
          (should (buffer-live-p dummy-buffer-A))
          (should (buffer-live-p dummy-buffer-B))
          (should (get-buffer-create "*scratch*"))
          (persp-set-buffer (get-buffer "*scratch*"))
          (persp-switch "A")
          (persp-set-buffer dummy-buffer-A)
          (should (get-buffer "*scratch* (A)"))
          (persp-switch "B")
          (persp-set-buffer dummy-buffer-B)
          (should (get-buffer "*scratch* (B)"))
          (persp-switch "C")
          (persp-set-buffer dummy-buffer)
          (should (get-buffer "*scratch* (C)"))
          (persp-switch "D")
          (should (get-buffer "*scratch* (D)"))
          (persp-switch "main")
          (persp-add-buffer dummy-buffer)
          (persp-add-buffer dummy-buffer-A)
          (should (kill-buffer "*scratch* (B)"))
          (should-not (get-buffer "*scratch* (B)"))
          (persp-set-buffer (get-buffer "*scratch* (A)"))
          (persp-set-buffer (get-buffer "*scratch* (C)"))
          (persp-kill "C")))
    (should-not persp-mode)
    ;; Buffers found only in the main perspective or shared with main.
    (should (get-buffer "*dummy*"))
    (should (get-buffer "*scratch*"))
    (should (get-buffer "*dummy* (A)"))
    ;; Buffers found in the main perspective while perspective NAME is
    ;; killed before the cleanup.
    (should (get-buffer "*scratch* (C)"))
    ;; Buffers found in the main perspective while perspective NAME is
    ;; alive before the cleanup.
    (should-not (get-buffer "*scratch* (A)"))
    ;; Buffers found only in other perspectives than main perspective.
    (should-not (get-buffer "*dummy* (B)"))
    (should-not (get-buffer "*scratch* (D)"))
    ;; Buffers manually killed but perspective NAME is kept alive till
    ;; the cleanup.
    (should-not (get-buffer "*scratch* (B)"))
    ;; Reset state.
    (should (kill-buffer "*dummy*"))
    (should-not (get-buffer "*dummy*"))
    (should (kill-buffer "*dummy* (A)"))
    (should-not (get-buffer "*dummy* (A)"))
    (should (kill-buffer "*scratch* (C)"))
    (should-not (get-buffer "*scratch* (C)"))))

(ert-deftest basic-persp-test-match-scratch-buffers ()
  "Test `persp-test-match-scratch-buffers'.

Expect a list of live buffers that may be considered *scratch*
buffers, aka the buffer's name begins with \"*scratch*\", or nil
if there's none.

When providing buffer or buffer's name arguments, them should
include exactly what the function would find.  Repetition and
order do not matter.  If just one argument isn't a candidate,
return nil."
  (let (matched-buffers dummy-buffer scratch-buffer scratch-buffer-A)
    ;; Cleanup *scratch* buffers.
    (mapc (lambda (buffer)
            (when (string-match-p "^\\*scratch\\*.*$" (buffer-name buffer))
              (kill-buffer buffer)))
          (buffer-list))
    ;; Match live *scratch* buffers.
    (persp-test-with-persp
      (should (setq dummy-buffer (get-buffer-create "*dummy*")))
      (should (setq scratch-buffer (get-buffer-create "*scratch*")))
      ;; get a list of all live *scratch* buffers
      (should (setq matched-buffers (list scratch-buffer)))
      (should (equal matched-buffers (persp-test-match-scratch-buffers)))
      ;; verify that all arguemnts meet the criteria
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers scratch-buffer)))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*" scratch-buffer)))
      (should (equal matched-buffers (persp-test-match-scratch-buffers scratch-buffer "*scratch*")))
      ;; verify that the matching criteria cannot be subverted
      (should-not (persp-test-match-scratch-buffers "*dummy*"))
      (should-not (persp-test-match-scratch-buffers dummy-buffer))
      (should-not (persp-test-match-scratch-buffers "*scratch* "))
      (should-not (persp-test-match-scratch-buffers "*scratch*" "*dummy*"))
      (should-not (persp-test-match-scratch-buffers "*dummy*" "*scratch*"))
      (should-not (persp-test-match-scratch-buffers "*scratch*" "*scratch* "))
      (should-not (persp-test-match-scratch-buffers "*scratch* " "*scratch*"))
      (should-not (persp-test-match-scratch-buffers scratch-buffer dummy-buffer))
      (should-not (persp-test-match-scratch-buffers dummy-buffer scratch-buffer))
      (should-not (persp-test-match-scratch-buffers "*scratch*" "*scratch* " "*scratch*"))
      (should (kill-buffer dummy-buffer))
      (should-not (get-buffer "*dummy*"))
      (should-not (buffer-live-p dummy-buffer))
      (should-not (persp-test-match-scratch-buffers dummy-buffer))
      (should-not (persp-test-match-scratch-buffers scratch-buffer dummy-buffer))
      (should-not (persp-test-match-scratch-buffers dummy-buffer scratch-buffer))
      (should (get-buffer-create "*scratch* "))
      (setq matched-buffers (list scratch-buffer (get-buffer "*scratch* ")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*" "*scratch* ")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch* " "*scratch*")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*" "*scratch* " "*scratch*"))))
    ;; Cleanup *scratch* buffers.
    (mapc (lambda (buffer)
            (when (string-match-p "^\\*scratch\\*.*$" (buffer-name buffer))
              (kill-buffer buffer)))
          (buffer-list))
    ;; Match live *scratch* buffers.
    (persp-test-with-persp
      (persp-new "A")
      (should (setq scratch-buffer (get-buffer-create "*scratch*")))
      (should (setq scratch-buffer-A (get-buffer "*scratch* (A)")))
      ;; get a list of all live *scratch* buffers
      (should (setq matched-buffers (list scratch-buffer scratch-buffer-A)))
      (should (equal matched-buffers (persp-test-match-scratch-buffers)))
      ;; verify that all arguemnts meet the criteria
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*" "*scratch* (A)")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch* (A)" "*scratch*")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers scratch-buffer scratch-buffer-A)))
      (should (equal matched-buffers (persp-test-match-scratch-buffers scratch-buffer-A "*scratch* (A)" scratch-buffer "*scratch*")))
      ;; verify that the matching criteria cannot be subverted
      (should-not (persp-test-match-scratch-buffers "*scratch*" "*scratch* " "*scratch* (A)"))
      (should (get-buffer-create "*scratch* "))
      (setq matched-buffers (list scratch-buffer (get-buffer "*scratch* ") scratch-buffer-A))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch*" "*scratch* " "*scratch* (A)")))
      (should (equal matched-buffers (persp-test-match-scratch-buffers "*scratch* (A)" "*scratch*" "*scratch* "))))
    ;; Cleanup *scratch* buffers.
    (mapc (lambda (buffer)
            (when (string-match-p "^\\*scratch\\*.*$" (buffer-name buffer))
              (kill-buffer buffer)))
          (buffer-list))
    (should (get-buffer-create "*scratch*"))))

(ert-deftest basic-persp-test-kill-extra-buffers ()
  "Test `persp-test-kill-extra-buffers'.

Expect to automatically cleanup *scratch* buffers that are not
the \"*scratch*\" buffer, and all the buffers and buffer's names
given as arguments, \"*scratch*\" buffer itself when included."
  ;; Cleanup from extra *scratch* buffers.
  (mapc #'kill-buffer (persp-test-match-scratch-buffers))
  (should (get-buffer-create "*scratch*"))
  ;; Try to kill some buffers and buffer's names.
  (let ((some-buffer (get-buffer-create "*some*"))
        (live-buffer (get-buffer-create "*live*"))
        (dead-buffer (get-buffer-create "*dead*")))
    (should (get-buffer "*some*"))
    (should (get-buffer "*live*"))
    (should (get-buffer "*dead*"))
    (should (kill-buffer dead-buffer))
    (should-not (get-buffer "*dead*"))
    (should (buffer-live-p some-buffer))
    (should (buffer-live-p live-buffer))
    (should-not (buffer-live-p dead-buffer))
    ;; As result, expect a list of names in alphabetical order of the
    ;; buffers the function tries to kill.  Expect nil if there is no
    ;; suitable candidate.  If the killing does not happen, it may be
    ;; due to reasons outside of the scope of the function.
    (should-not (persp-test-kill-extra-buffers))
    (should-not (persp-test-kill-extra-buffers "*dead*"))
    (should-not (persp-test-kill-extra-buffers dead-buffer))
    (should-not (persp-test-kill-extra-buffers "*dead*" dead-buffer))
    (should (equal (list "*live*" "*some*")
                   (persp-test-kill-extra-buffers "*some*" dead-buffer "*dead*" live-buffer)))
    (should (persp-test-match-scratch-buffers "*scratch*"))
    (should-not (buffer-live-p dead-buffer))
    (should-not (buffer-live-p live-buffer))
    (should-not (buffer-live-p some-buffer))
    (should-not (get-buffer "*dead*"))
    (should-not (get-buffer "*live*"))
    (should-not (get-buffer "*some*"))
    ;; Duplicate arguments, as buffer or buffer's name, should not be
    ;; a problem.
    (should (setq some-buffer (get-buffer-create "*some*")))
    (should (equal (list "*some*")
                   (persp-test-kill-extra-buffers "*some*" some-buffer "*some*" some-buffer)))
    (should (persp-test-match-scratch-buffers "*scratch*"))
    (should-not (buffer-live-p some-buffer))
    (should-not (get-buffer "*some*")))
  ;; Expect to kill extra scratch buffers that aren't the "*scratch*"
  ;; buffer, doing a cleanup after exiting `persp-mode'.
  (persp-test-with-persp
    (should (switch-to-buffer "*dummy*"))
    (should (switch-to-buffer "*scratch*"))
    (should (switch-to-buffer "*scratch* "))
    (should (switch-to-buffer "*scratch* (A)"))
    (should (switch-to-buffer "*scratch* (B)")))
  (should (equal (list "*scratch* " "*scratch* (A)" "*scratch* (B)")
                 (persp-test-kill-extra-buffers)))
  (should (persp-test-match-scratch-buffers "*scratch*"))
  (should (get-buffer "*dummy*"))
  ;; Do a cleanup while in `persp-mode', killing the "*scratch*" too.
  ;; Expect a list of names of buffers the function tries to kill, it
  ;; doesn't matter if the buffers survive the killing.  The function
  ;; tries to kill what matches its criteria.  Candidates to kill can
  ;; be given in any order, the result will be in alphabetical order.
  (persp-test-with-persp
    (persp-switch "A")
    (persp-switch "B")
    (should (get-buffer "*dummy*"))
    (should (get-buffer-create "*scratch* "))
    (should (equal (list "*scratch*" "*scratch* " "*scratch* (A)" "*scratch* (B)")
                   (persp-test-kill-extra-buffers "*scratch* (C)" "*scratch* (B)" "*scratch*"))))
  (should-not (persp-test-match-scratch-buffers))
  (should (get-buffer "*dummy*"))
  ;; Cleanup.
  (should (get-buffer-create "*scratch*"))
  (should (equal (list "*dummy*")
                 (persp-test-kill-extra-buffers "*dummy*")))
  (should (persp-test-match-scratch-buffers "*scratch*"))
  (should-not (get-buffer "*dummy*")))

(ert-deftest basic-persp-test-buffer-in-persps ()
  "Test that `persp-test-buffer-in-persps' is working properly.

Verify that a buffer can only be found in perspectives owning it
and, at the same time, not in other existing perspectives.  keep
in mind that a perspective owning the buffer may be bare data of
a formally non-existent `perspective-p' object."
  (should (get-buffer-create "*dummy*"))
  (should (get-buffer-create "*scratch*"))
  (persp-test-kill-extra-buffers "*rogue*")
  (persp-test-with-persp
    (persp-new "A")
    (persp-new "B")
    (let (persp
          persp-A
          persp-B
          buffers
          buffers-A
          buffers-B
          rogue-buffer
          (dummy-buffer (get-buffer "*dummy*"))
          (scratch-buffer (get-buffer "*scratch*"))
          (scratch-buffer-A (get-buffer "*scratch* (A)"))
          (scratch-buffer-B (get-buffer "*scratch* (B)")))
      ;; Get perspective's data from each existing perspective.
      (setq persp (persp-curr))
      (should (persp-is-current-buffer dummy-buffer))
      (should (persp-is-current-buffer scratch-buffer))
      (should-not (persp-is-current-buffer scratch-buffer-A))
      (should-not (persp-is-current-buffer scratch-buffer-B))
      (setq buffers (copy-sequence (persp-buffers (persp-curr))))
      (with-perspective "A"
        (setq persp-A (persp-curr))
        (should-not (persp-is-current-buffer dummy-buffer))
        (should-not (persp-is-current-buffer scratch-buffer))
        (should (persp-is-current-buffer scratch-buffer-A))
        (should-not (persp-is-current-buffer scratch-buffer-B))
        (setq buffers-A (copy-sequence (persp-buffers (persp-curr)))))
      (with-perspective "B"
        (setq persp-B (persp-curr))
        (should-not (persp-is-current-buffer dummy-buffer))
        (should-not (persp-is-current-buffer scratch-buffer))
        (should-not (persp-is-current-buffer scratch-buffer-A))
        (should (persp-is-current-buffer scratch-buffer-B))
        (setq buffers-B (copy-sequence (persp-buffers (persp-curr)))))
      ;; Read the list of buffers from each perspective's data.
      (should (equal buffers (persp-buffers persp)))
      (should (equal buffers-A (persp-buffers persp-A)))
      (should (equal buffers-B (persp-buffers persp-B)))
      ;; *dummy* is in main, not in A and B
      (should (memq dummy-buffer buffers))
      (should-not (memq dummy-buffer buffers-A))
      (should-not (memq dummy-buffer buffers-B))
      ;; *scratch* is in main, not in A and B
      (should (memq scratch-buffer buffers))
      (should-not (memq scratch-buffer buffers-A))
      (should-not (memq scratch-buffer buffers-B))
      ;; *scratch* (A) is in A, not in main and B
      (should (memq scratch-buffer-A buffers-A))
      (should-not (memq scratch-buffer-A buffers))
      (should-not (memq scratch-buffer-A buffers-B))
      ;; *scratch* (B) is in B, not is main and A
      (should (memq scratch-buffer-B buffers-B))
      (should-not (memq scratch-buffer-B buffers))
      (should-not (memq scratch-buffer-B buffers-A))
      ;; Find buffer by name in specific perspectives.
      (should (persp-test-buffer-in-persps "*dummy*" "main"))
      (should (persp-test-buffer-in-persps "*scratch*" "main"))
      (should (persp-test-buffer-in-persps "*scratch* (A)" "A"))
      (should (persp-test-buffer-in-persps "*scratch* (B)" "B"))
      ;; Find buffer by name in perspective's data.
      (should (persp-test-buffer-in-persps "*dummy*" persp))
      (should (persp-test-buffer-in-persps "*scratch*" persp))
      (should (persp-test-buffer-in-persps "*scratch* (A)" persp-A))
      (should (persp-test-buffer-in-persps "*scratch* (B)" persp-B))
      ;; Find buffer in specific perspectives.
      (should (persp-test-buffer-in-persps dummy-buffer "main"))
      (should (persp-test-buffer-in-persps scratch-buffer "main"))
      (should (persp-test-buffer-in-persps scratch-buffer-A "A"))
      (should (persp-test-buffer-in-persps scratch-buffer-B "B"))
      ;; Find buffer in perspective's data.
      (should (persp-test-buffer-in-persps dummy-buffer persp))
      (should (persp-test-buffer-in-persps scratch-buffer persp))
      (should (persp-test-buffer-in-persps scratch-buffer-A persp-A))
      (should (persp-test-buffer-in-persps scratch-buffer-B persp-B))
      ;; Try buffer in wrong perspective.
      (should-not (persp-test-buffer-in-persps dummy-buffer "main" "A"))
      ;; Try in non-existent perspective.
      (should-not (persp-test-buffer-in-persps dummy-buffer "main" "C"))
      ;; Try buffer in duplicate targets.
      (should (persp-test-buffer-in-persps dummy-buffer (persp-curr)))
      (should (persp-test-buffer-in-persps dummy-buffer persp (persp-curr)))
      (should (persp-test-buffer-in-persps dummy-buffer "main" (persp-curr)))
      (should (persp-test-buffer-in-persps dummy-buffer persp "main" (persp-curr)))
      ;; Try finding non-existent buffer.
      (should-not (get-buffer "*rogue*"))
      (should-not (persp-test-buffer-in-persps "*rogue*"))
      ;; Try finding a new rogue buffer.
      (should (setq rogue-buffer (get-buffer-create "*rogue*")))
      (should (persp-test-buffer-in-persps "*rogue*"))
      (should-not (persp-is-current-buffer rogue-buffer))
      (with-perspective "A"
        (should-not (persp-is-current-buffer rogue-buffer)))
      (with-perspective "B"
        (should-not (persp-is-current-buffer rogue-buffer)))
      ;; Try a rogue perspective's data.
      (persp-set-buffer rogue-buffer)
      (setq persp (copy-perspective (persp-curr)))
      (setf (persp-current-buffers) (remq rogue-buffer (persp-current-buffers)))
      (should (memq rogue-buffer (persp-buffers persp)))
      (should-not (persp-is-current-buffer rogue-buffer))
      (should (persp-test-buffer-in-persps "*rogue*" persp))
      (should-not (persp-test-buffer-in-persps "*rogue*" "main"))
      (should-not (persp-test-buffer-in-persps "*rogue*" (persp-curr)))
      (should-not (persp-test-buffer-in-persps "*rogue*" persp "main" (persp-curr)))
      ;; Try finding a killed buffer.
      (persp-remove-buffer dummy-buffer)
      (should-not (get-buffer "*dummy*"))
      (should-not (buffer-live-p dummy-buffer))
      (should (memq dummy-buffer (persp-buffers persp)))
      (should-not (persp-is-current-buffer dummy-buffer))
      (should-not (persp-test-buffer-in-persps "*dummy*"))
      (should-not (persp-test-buffer-in-persps dummy-buffer))
      (should-not (persp-test-buffer-in-persps "*dummy*" persp))
      (should-not (persp-test-buffer-in-persps dummy-buffer persp))
      ;; Try finding a shared buffer.
      (should (setq dummy-buffer (get-buffer-create "*dummy*")))
      ;; *dummy* is a rogue buffer
      (should (persp-test-buffer-in-persps "*dummy*"))
      ;; put *dummy* in A and B
      (setq persp (persp-curr))
      (should-not (persp-is-current-buffer dummy-buffer))
      (with-perspective "A"
        (setq persp-A (persp-curr))
        (persp-add-buffer dummy-buffer)
        (should (persp-is-current-buffer dummy-buffer)))
      (with-perspective "B"
        (setq persp-B (persp-curr))
        (persp-add-buffer dummy-buffer)
        (should (persp-is-current-buffer dummy-buffer)))
      ;; where is *dummy*?
      (should (persp-test-buffer-in-persps "*dummy*" "A" "B"))
      (should (persp-test-buffer-in-persps "*dummy*" persp-A "B"))
      (should (persp-test-buffer-in-persps dummy-buffer "A" persp-B))
      (should-not (persp-test-buffer-in-persps "*dummy*" "A" "B" persp))
      (should (persp-test-buffer-in-persps dummy-buffer persp-A persp-B))
      (should (persp-test-buffer-in-persps dummy-buffer "A" persp-A persp-B "B"))))
  ;; Cleanup.
  (persp-test-kill-extra-buffers "*dummy*" "*rogue*"))

(ert-deftest basic-persp-header-line-format-default-value ()
  "Disabling `persp-mode' should properly restore the default
value of `header-line-format'.

Updating `header-line-format' default value using a buffer
local value of it is a mistake."
  (let ((persp-show-modestring 'header)
	(default-header-line-format (default-value 'header-line-format)))
    ;; Since `persp-test-with-persp' may change in the future, do not
    ;; use it.  We need to avoid switching to another buffer than the
    ;; *dummy* buffer just before `persp-mode' is disabled.  For this
    ;; test to work, a buffer with a locally modified header needs to
    ;; be the current buffer when `persp-mode' is disabled.
    (persp-mode 1)
    (should (switch-to-buffer "*dummy*"))
    (should (equal (buffer-name) "*dummy*"))
    (setq header-line-format "custom header")
    ;; This is just being paranoid about the header's default value.
    (should-not (equal header-line-format default-header-line-format))
    (should-not (equal header-line-format (default-value 'header-line-format)))
    (persp-mode -1)
    (should (equal (buffer-name) "*dummy*"))
    (should (equal header-line-format "custom header"))
    (let ((updated-header-line-format (default-value 'header-line-format)))
      (should (equal updated-header-line-format default-header-line-format)))
    ;; Cleanup.
    (kill-buffer "*dummy*")))

(ert-deftest basic-persp-creation-deletion ()
  "Switching to a non-existing perspective should create the new
perspective.  Switching to an existing perspective should not
duplicate the perspective.  Creating a new perspective should
not automatically switch to the perspective."
  (persp-test-with-persp
    (should (equal (persp-current-name) "main"))
    (should (equal (list "main") (sort (persp-names) #'string-lessp)))
    ;; test if switching to a non-existing perspective also creates it
    (persp-switch "A")
    (should (equal (persp-current-name) "A"))
    (should (equal (list "A" "main") (sort (persp-names) #'string-lessp)))
    ;; test if creating a new perspective switches to it automatically
    (persp-new "B")
    (should (equal (persp-current-name) "A"))
    (should (equal (list "A" "B" "main") (sort (persp-names) #'string-lessp)))
    ;; test if switching to an existing perspective duplicates it
    (persp-switch "B")
    (should (equal (persp-current-name) "B"))
    (should (equal (list "A" "B" "main") (sort (persp-names) #'string-lessp)))
    (persp-switch "A")
    (should (equal (persp-current-name) "A"))
    (should (equal (list "A" "B" "main") (sort (persp-names) #'string-lessp)))
    ;; kill the current perspective to see where we land
    (persp-kill (persp-current-name))
    (should (equal (persp-current-name) "B"))
    (should (equal (list "B" "main") (sort (persp-names) #'string-lessp)))
    (persp-kill (persp-current-name))
    (should (equal (persp-current-name) "main"))
    (should (equal (list "main") (sort (persp-names) #'string-lessp)))
    ;; sanity checks before killing the main perspective
    (should (get-buffer "*Messages*"))
    (should (get-buffer-create "*scratch*"))
    (persp-set-buffer (get-buffer "*scratch*"))
    (let ((ert-buffer (get-buffer "*ert*"))
          (msg-buffer (get-buffer "*Messages*")))
      ;; interactively run ert requires the *ert* buffer
      (setf (persp-current-buffers) (remq ert-buffer (persp-current-buffers)))
      ;; the *Messages* buffer is also ert's requiremet
      (setf (persp-current-buffers) (remq msg-buffer (persp-current-buffers)))
      ;; *scratch* is in main, not *ert* and *Messages*
      (should (persp-test-buffer-in-persps "*scratch*" "main"))
      (should-not (persp-test-buffer-in-persps ert-buffer "main"))
      (should-not (persp-test-buffer-in-persps msg-buffer "main"))
      ;; kill the main perspective except above buffers
      (persp-kill (persp-current-name))
      ;; the *scratch* buffer should have been killed
      (should-not (get-buffer "*scratch*"))
      ;; *ert* is needed by interactively run tests
      (should (eq ert-buffer (get-buffer "*ert*")))
      ;; the *Messages* buffer is needed by ert
      (should (eq msg-buffer (get-buffer "*Messages*")))))
  ;; cleanup
  (should (get-buffer-create "*scratch*")))

(ert-deftest basic-persp-get-buffers ()
  "Test `persp-get-buffers'.
Expect the list of a perspective's buffers."
  (persp-test-with-persp
    ;; buffers whose name is special should be listed
    (let ((special-buffer (get-buffer-create " *foo*")))
      (should (buffer-live-p special-buffer))
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-buffers (persp-curr)))))
        (should (equal buffers (persp-get-buffers (persp-curr))))
        (should (equal buffers (persp-get-buffers "main")))
        (should (equal buffers (persp-current-buffers)))
        (should (equal buffers (persp-get-buffers)))
        (should (memq special-buffer buffers)))
      (persp-switch "A")
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-buffers (persp-curr)))))
        (should (equal buffers (persp-get-buffers (persp-curr))))
        (should (equal buffers (persp-get-buffers "A")))
        (should (equal buffers (persp-current-buffers)))
        (should (equal buffers (persp-get-buffers)))
        (should (memq special-buffer buffers)))
      (persp-switch "B")
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-buffers (persp-curr)))))
        (should (equal buffers (persp-get-buffers (persp-curr))))
        (should (equal buffers (persp-get-buffers "B")))
        (should (equal buffers (persp-current-buffers)))
        (should (equal buffers (persp-get-buffers)))
        (should (memq special-buffer buffers)))
      (persp-switch "main")
      (should (memq special-buffer (persp-get-buffers)))
      (should (memq special-buffer (persp-get-buffers "A")))
      (should (memq special-buffer (persp-get-buffers "B")))
      (should (equal (persp-get-buffers) (persp-get-buffers "main")))
      (should-not (equal (persp-get-buffers) (persp-get-buffers "A")))
      (should-not (equal (persp-get-buffers "A") (persp-get-buffers "B")))))
  ;; cleanup
  (persp-test-kill-extra-buffers " *foo*"))

(ert-deftest basic-persp-get-buffer-names ()
  "Test `persp-get-buffer-names'.
Expect the list of a perspective's live buffers."
  (persp-test-with-persp
    ;; buffers whose name is special should be filtered
    (let ((special-buffer (get-buffer-create " *foo*")))
      (should (buffer-live-p special-buffer))
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-current-buffer-names))))
        (should (equal buffers (persp-get-buffer-names (persp-curr))))
        (should (equal buffers (persp-get-buffer-names "main")))
        (should (equal buffers (persp-get-buffer-names)))
        (should-not (memq special-buffer buffers)))
      (persp-switch "A")
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-current-buffer-names))))
        (should (equal buffers (persp-get-buffer-names (persp-curr))))
        (should (equal buffers (persp-get-buffer-names "A")))
        (should (equal buffers (persp-get-buffer-names)))
        (should-not (memq special-buffer buffers)))
      (persp-switch "B")
      (persp-add-buffer special-buffer)
      (let ((buffers (copy-sequence (persp-current-buffer-names))))
        (should (equal buffers (persp-get-buffer-names (persp-curr))))
        (should (equal buffers (persp-get-buffer-names "B")))
        (should (equal buffers (persp-get-buffer-names)))
        (should-not (memq special-buffer buffers)))
      (persp-switch "main")
      (should-not (memq special-buffer (persp-get-buffer-names)))
      (should-not (memq special-buffer (persp-get-buffer-names "A")))
      (should-not (memq special-buffer (persp-get-buffer-names "B")))
      (should (equal (persp-get-buffer-names) (persp-get-buffer-names "main")))
      (should-not (equal (persp-get-buffer-names) (persp-get-buffer-names "A")))
      (should-not (equal (persp-get-buffer-names "A") (persp-get-buffer-names "B")))))
  ;; cleanup
  (persp-test-kill-extra-buffers " *foo*"))

(ert-deftest basic-persp-switching ()
  (persp-test-with-persp
    (persp-test-with-temp-buffers (A1 A2 B1 B2 B3)
      ;; currently in "main" perspective
      (cl-loop for buf in (list A1 A2 B1 B2 B3) do
               (should-not (memq buf (persp-buffers (persp-curr)))))
      (persp-switch "A")
      (switch-to-buffer A1)
      (switch-to-buffer A2)
      (cl-loop for buf in (list A1 A2) do
               (should (memq buf (persp-buffers (persp-curr)))))
      (cl-loop for buf in (list B1 B2 B3) do
               (should-not (memq buf (persp-buffers (persp-curr)))))
      (persp-switch "B")
      (switch-to-buffer B1)
      (switch-to-buffer B2)
      (switch-to-buffer B3)
      (cl-loop for buf in (list A1 A2) do
               (should-not (memq buf (persp-buffers (persp-curr)))))
      (cl-loop for buf in (list B1 B2 B3) do
               (should (memq buf (persp-buffers (persp-curr)))))
      (persp-switch "main")
      (cl-loop for buf in (list A1 A2 B1 B2 B3) do
               (should-not (memq buf (persp-buffers (persp-curr))))))))

(defmacro persp-test-make-sample-environment ()
  "Make a test environment with the following window layout:

        A                  B
+----+-----+----+  +---------------+
|    |     |    |  |    B1 / B3    |
|    |     |    |  |               |
| A1 |  A2 | A3 |  +---------------+
|    |     |    |  |    B2 / B4    |
|    |     |    |  |               |
+----+-----+----+  +---------------+

This produces two perspectives, each with individual window
layouts and files. The 'main' perspective remains empty.

Notice the shameless symbol capture! This macro expects to be
called where A1, A2, A3, B1, B2, B3, and B4 are already bound
using persp-test-with-files."
  `(progn
     (persp-switch "A")
     (switch-to-buffer A1)
     (select-window (split-window-right))
     (switch-to-buffer A2)
     (select-window (split-window-right))
     (switch-to-buffer A3)
     (balance-windows)
     (persp-switch "B")
     (switch-to-buffer B3)
     (switch-to-buffer B1)
     (select-window (split-window-below))
     (switch-to-buffer B4)
     (switch-to-buffer B2)))

(defmacro persp-test-check-sample-environment ()
  "Runs a series of checks on the environment created by
persp-test-make-sample-environment."
  `(progn
     (should (equal (list "A" "B" "main") (sort (persp-names) #'string-lessp)))
     (persp-switch "A")
     ;; check buffers in perspective A
     (should (equal (list "A1" "A2" "A3")
                    (sort (mapcar #'buffer-name (persp-test-buffer-list (persp-curr)))
                          #'string-lessp)))
     ;; check windows in perspective A
     (should (equal (list "A1" "A2" "A3")
                    (sort (mapcar #'buffer-name (mapcar #'window-buffer (window-list)))
                          #'string-lessp)))
     (persp-switch "B")
     ;; check buffers in perspective B
     (should (equal (list "B1" "B2" "B3" "B4")
                    (sort (mapcar #'buffer-name (persp-test-buffer-list (persp-curr)))
                          #'string-lessp)))
     ;; check windows in perspective B
     (should (equal (list "B1" "B2")
                    (sort (mapcar #'buffer-name (mapcar #'window-buffer (window-list)))
                          #'string-lessp)))))

(ert-deftest basic-persp-window-retention ()
  (unwind-protect
      (persp-test-with-persp
        (persp-test-with-files nil (A1 A2 A3 B1 B2 B3 B4)
          (persp-test-make-sample-environment)
          (persp-test-check-sample-environment)))
    (persp-test-clean-files "A1" "A2" "A3" "B1" "B2" "B3" "B4")))

(ert-deftest issue-85-pulling-buffers-into-other-persps ()
  (persp-test-with-persp
    (persp-test-with-temp-buffers (A1 A2 B1)
      (persp-switch "A")
      (select-window (split-window-right))
      (balance-windows)
      (switch-to-buffer A1)
      (switch-to-buffer A2)
      (persp-switch "B")
      (select-window (split-window-right))
      (switch-to-buffer B1)
      (persp-switch "A")
      (persp-switch "B")
      (kill-buffer)
      (walk-windows
       (lambda (w) (should-not
                    (memq (window-buffer w) (list A1 A2))))))))

(ert-deftest issue-81-renaming-scratch-buffers ()
  (persp-test-with-persp
    (persp-switch "A")
    (should (get-buffer "*scratch* (A)"))
    (persp-rename "B")
    (should (not (get-buffer "*scratch* (A)")))
    (should (get-buffer "*scratch* (B)"))))

(defmacro with-named-persp (name &rest body)
  "Create a perspective, run the body, and then kill the perspectiev"
  (declare (indent 1))
  `(progn
     (persp-switch ,name)
     ,@body
     (persp-kill ,name)))

;; REFACTOR: push this up?
(defun persp-last-name ()
  (and (persp-last) (persp-name (persp-last))))

;; REFACTOR: push this up?
(defun persp-curr-name ()
  (and (persp-curr) (persp-name (persp-curr))))

(defmacro should-persp-equal (a b c d)
  `(progn
     (should (equal ,a (persp-names)))
     (should (equal ,b (persp-curr-name)))
     (should (equal ,c (persp-last-name)))
     (should (equal ,d (persp-find-some)))))

(ert-deftest issue-90-persp-last--vs--persp-find-some ()
  (persp-test-with-persp
   (let ((persp-sort 'created))         ; this should be respected when killing
     (should-persp-equal       '("main")             "main" nil    "main")
     (with-named-persp "A"
       (should-persp-equal     '("A" "main")         "A"    "main" "main")
       (with-named-persp "B"
         (should-persp-equal   '("B" "A" "main")     "B"    "A"    "A")
         (with-named-persp "C"
           (should-persp-equal '("C" "B" "A" "main") "C"    "B"    "B")) ; pop C
         (should-persp-equal   '("B" "A" "main")     "B"    nil    "B")) ; pop B
       (should-persp-equal     '("A" "main")         "A"    nil    "A")) ; pop A
     (should-persp-equal       '("main")             "main" nil    "main"))))

(ert-deftest state-save-and-load ()
  (unwind-protect
      (persp-test-with-persp
        (persp-test-with-files nil (A1 A2 A3 B1 B2 B3 B4)
          (persp-test-make-sample-environment)
          (should (= 7 (length (persp-test-buffer-list-all)))) ; sanity check
          (persp-state-save "state-1.el"))
        ;; reset perspectives
        (persp-mode -1)
        (delete-other-windows)
        (should (= 0 (length (persp-test-buffer-list-all)))) ; no open files
        (persp-mode 1)
        (should (equal (list "main") (sort (persp-names) #'string-lessp)))
        ;; load it back up
        (persp-state-load "state-1.el")
        (should (= 7 (length (persp-test-buffer-list-all)))) ; sanity check again
        (persp-test-check-sample-environment))
    (persp-test-clean-files "A1" "A2" "A3" "B1" "B2" "B3" "B4" "state-1.el")))

;;; test-perspective.el ends here
