;;; haskell-test-utils.el --- Utilities for Haskell Mode tests.  -*- lexical-binding: t -*-

;; Copyright © 2016 Arthur Fayzrakhmanov. All rights reserved.

;; This file is part of haskell-mode package.
;; You can contact with authors using GitHub issue tracker:
;; https://github.com/haskell/haskell-mode/issues

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This package provides utilities for `haskell-mode' tests.

;;; Code:

(require 'cl-lib)

(defun insert-lines (&rest lines)
  "Insert all LINES in current buffer."
  (let ((ls lines)
        (line ""))
    (while ls
      (setq line (car ls))
      (setq ls (cdr ls))
      (when ls
        (insert line)
        (insert "\n")))
    (insert line)))

(defmacro with-temp-switch-to-buffer (&rest body)
  "Create a temporary buffer and evalute BODY there.
Uses `switch-to-buffer' and evaluates BODY in temp buffer like `progn'.

Seems that `execute-kbd-macro' is not able to correctly execute
keybindings without this."
  (declare (indent 0) (debug t))
  (let ((temp-buffer (make-symbol "temp-buffer")))
    `(let ((,temp-buffer (generate-new-buffer " *temp*")))
       ;; FIXME: kill-buffer can change current-buffer in some odd cases.
       (unwind-protect
           (progn
             (switch-to-buffer ,temp-buffer)
             ,@body)
         (and (buffer-name ,temp-buffer)
              (kill-buffer ,temp-buffer))))))

(defun check-syntax-and-face-match-range (beg end syntax face)
  "Check if all charaters between positions BEG and END have
syntax set to SYNTAX and face set to FACE.

If SYNTAX or FACE are set to t then any syntex respective face is
not checked."
  (let (all-syntaxes
        all-faces
        (syntax-classes "-.w_()'\"$\\/<>@!|")
        (text (buffer-substring-no-properties beg end)))
    (while (< beg end)
      (cl-pushnew (char-to-string (aref syntax-classes (syntax-class (syntax-after beg)))) all-syntaxes :test #'equal)
      (cl-pushnew (get-text-property beg 'face) all-faces :test #'equal)
      (setq beg (1+ beg)))
    (unless (eq syntax t)
      (should (equal (list text (mapconcat #'identity (sort (mapcar (lambda (syn) (char-to-string syn)) syntax) #'string<) ""))
                     (list text (mapconcat #'identity (sort all-syntaxes #'string<) "")))))
    (unless (eq face t)
      (should (equal (list text (list face))
                     (list text all-faces))))))

(defun check-face-match-range (face n)
  (let ((beg (match-beginning n))
        (end (match-end n)))
    (while (< beg end)
      (should (eq face (get-text-property beg 'face)))
      (setq beg (1+ beg)))))

(defmacro with-haskell-test-buffer (mode &rest body)
  "Run BODY in the context of a new buffer set to `haskell-mode'.

Buffer is named *haskell-mode-buffer*. It is not deleted
after a test as this aids interactive debugging."
  (declare (indent 1) (debug t))
  `(progn
     ;; we want to create buffer from scratch so that there are no
     ;; leftover state from the previous test
     (when (get-buffer "*haskell-test-buffer*")
       (kill-buffer "*haskell-test-buffer*"))
     (save-current-buffer
       (set-buffer (get-buffer-create "*haskell-test-buffer*"))
       (funcall ,mode)
       ,@body)))

(defun check-properties (lines-or-contents props &optional mode)
  "Check if syntax properties and font-lock properties as set properly.

LINES is a list of strings that will be inserted to a new
buffer. Then PROPS is a list of tripples of (string syntax
face). String is searched for in the buffer and then is checked
if all of its characters have syntax and face. See
`check-syntax-and-face-match-range`."
  (with-haskell-test-buffer (or mode #'haskell-mode)
    (if (consp lines-or-contents)
        (dolist (line lines-or-contents)
          (let ((pos (point)))
            (insert line "\n")
            (save-excursion
              ;; For some reason font-lock-fontify-region moves the
              ;; point. I do not think it is guaranteed it should not,
              ;; but then it might be our fault. Investigate later.
              (font-lock-fontify-region pos (point)))))
      (insert lines-or-contents)
      (font-lock-fontify-buffer))

    (goto-char (point-min))
    (dolist (prop props)
      (cl-destructuring-bind (string syntax face) prop
        (let ((case-fold-search nil))
          (search-forward string))
        (check-syntax-and-face-match-range (match-beginning 0) (match-end 0) syntax face)))))


(defun message-stderr (&rest args)
  "Output a message to stderr in batch mode.

ARGS are formatted according to `format'. A newline is automatically appended."
  (apply #'message args))

(defun message-stdout (&rest args)
  "Output a message to stdout in batch mode.

ARGS are formatted according to `format'. A newline is automatically appended."
  (princ (apply #'format args))
  (terpri))

(defun read-stdin ()
  "Read a line from stdin in batch mode.

A line is read and returned. End of input is signalled by
nil. Newlines are stripped. Last line is returned even if there
is no final newline."
  (condition-case nil
      (read-from-minibuffer "")
    (error nil)))

(defmacro with-script-path (cmdvar func &rest body)
  "Temporarily substitute a command line executable.

Creates a temporary executable script and sets CMDVAR to point to
the script. When the script is run it spawns another Emacs
instance and executes function FUNC. Substitution is in effect
throughout BODY.

In FUNC variable `argv' is a list of all arguments that the
script received when invoked. If the FUNC returns a number then
it will be used as exit code for `kill-emacs' function, otherwise
0 will be used."
  (declare (indent 2) (debug t))
  `(let ((,cmdvar (make-temp-file "haskell-mode-tests-script")))
     (with-current-buffer (find-file-noselect ,cmdvar)

       (insert "#!/bin/sh\n")
       (insert "\":\"; exec \"" invocation-directory invocation-name "\" -Q --batch -l \"$0\" -- \"$@\"\n")
       (insert "(setq debug-on-error t)\n")
       (insert "(pop argv)\n")
       (insert "(setq load-path '" (format "%S" load-path) ")\n")
       (insert "(load \"" (symbol-file ',func) "\" nil t)\n")
       (insert "(let ((return-value (" (symbol-name ',func) ")))\n")
       (insert " (if (numberp return-value)\n")
       (insert "    (kill-emacs return-value)\n")
       (insert "    (kill-emacs 0)))\n")
       (basic-save-buffer)
       (kill-buffer))
     (set-file-modes ,cmdvar (string-to-number "700" 8))
     (unwind-protect
         (progn ,@body)
       (delete-file ,cmdvar))))

(provide 'haskell-test-utils)

;;; haskell-test-utils.el ends here
