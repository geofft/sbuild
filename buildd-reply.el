;;; buildd-reply.el: Some utility functions to reply to buildd mails
;;;
;;;	Copyright (C) 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
;;;
;;;	This program is free software; you can redistribute it and/or
;;;	modify it under the terms of the GNU General Public License as
;;;	published by the Free Software Foundation; either version 2 of the
;;;	License, or (at your option) any later version.
;;;
;;;	This program is distributed in the hope that it will be useful, but
;;;	WITHOUT ANY WARRANTY; without even the implied warranty of
;;;	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;	General Public License for more details.
;;;
;;;	You should have received a copy of the GNU General Public License
;;;	along with this program; if not, write to the Free Software
;;;	Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
;;;
;;; This file is not part of GNU Emacs.
;;;
;;; $Id: buildd-reply.el,v 1.13 2000/03/07 09:35:50 rnhodek Exp $
;;;
;;; $Log: buildd-reply.el,v $
;;; Revision 1.13  2000/03/07 09:35:50  rnhodek
;;; buildd-bug: Also insert a pointer to complete build log.
;;;
;;; Revision 1.12  2000/03/01 14:18:35  rnhodek
;;; Two new functions:
;;;  - buildd-bug-change-category changes the failed category of a failed
;;;    package; you use it from a mail buffer with a reply to the bug
;;;    report (if the maintainer hasn't changed the subject...); you are
;;;    prompted for a new category, which can be TAB-expanded.
;;;  - buildd-bug-comment adds next text to the fail message of a package;
;;;    used the same way as buildd-bug-change-category above, but you can
;;;    insert arbitrary text; with [CAT] you can also set/change the category.
;;; New changed keybindings: C-c C-a (formerly buildd-bug-ack-append) is
;;; now a prefix for 3 bindings that append something to fail messages:
;;;  - C-c C-a C-n -> buildd-bug-ack-append (i.e., append a bug number)
;;;  - C-c C-a C-a -> buildd-bug-comment (append arbitrary text)
;;;  - C-c C-a C-c -> buildd-bug-change-category
;;;
;;; Revision 1.11  2000/01/19 13:08:44  rnhodek
;;; Prefix arg for buildd-bug-ack-append doesn't send mail immediately,
;;; but lets you edit the To: address (or anything else).
;;;
;;; Revision 1.10  1999/12/07 14:46:18  rnhodek
;;; New function buildd-reopen-bug.
;;;
;;; Revision 1.9  1999/10/21 11:04:18  rnhodek
;;; Don't hardcode email addr of buildd.
;;;
;;; Revision 1.8  1999/08/26 09:31:08  rnhodek
;;; Move buildd-add-sd-map to global key C-c C-v.
;;;
;;; Revision 1.7  1999/08/26 09:26:41  rnhodek
;;; New function buildd-add-sd-map for inserting a package alphabetically
;;; into a sd_map-* file.
;;; buildd-find-place-for-new-source-dep: package name can contain also [.+-].
;;; buildd-find-place-for-new-source-dep, buildd-edit-manual-source-deps:
;;; support for "ARCHS |" prefixes (ignore them when sorting).
;;;
;;; Revision 1.6  1999/05/04 09:02:46  rnhodek
;;; edit-manual-src-deps: '.' also allowed in package names.
;;;
;;; Revision 1.5  1999/04/26 12:37:52  rnhodek
;;; Remove overflowous paren...
;;;
;;; Revision 1.4  1999/04/26 12:36:12  rnhodek
;;; Rewrite buildd-edit-manual-source-deps for andrea:
;;;  - Default file name is madd_sd-DIST, where DIST is taken from the
;;;    (dist=XXX) part of the subject
;;;  - Use "=>" instead of ":" after the keyword
;;; More flexible displaying of madd_sd buffer by using pop-to-buffer.
;;;
;;; Revision 1.3  1999/04/20 13:41:59  rnhodek
;;; In buildd-bug, insert a Severity: important header;
;;; cannot-build-from-source type bugs should usually be important.
;;;
;;; Revision 1.2  1998/12/07 12:47:27  rnhodek
;;; New function buildd-edit-manual-source-deps, contributed by James
;;; Troup; slightly adapted by me for rmail.
;;; buildd-depretry can now also extract dependencies from the error
;;; messages from sbuild ("after installing, the following ... are unsatisfied").
;;;
;;; Revision 1.1  1998/11/25 13:21:42  rnhodek
;;; Initial version.
;;;
;;;

(defun buildd-prepare-mail (label send-now &rest ins)
  (if label
	  (rmail-set-label label t))
  (rmail-reply t)
  (goto-char (point-max))
  (while ins
	(insert (car ins))
	(setq ins (cdr ins)))
  (if send-now
      (mail-send-and-exit nil)))

;; Reply to buildd logs with a signed .changes file (which must be
;; extracted from the mail)
(defun buildd-reply-ok ()
  (interactive)
  (save-excursion
    (let (beg end str)
      (goto-char (point-max))
      (if (not (re-search-backward "^[^ 	]*\\.changes:$"))
		  (error "Can't find .changes: line"))
      (forward-line 1)
      (beginning-of-line)
      (setq beg (point))
      (if (not (re-search-forward "^Files: $"))
		  (error "Can't find Files: line"))
      (beginning-of-line)
      (forward-line 1)
      (while (looking-at "^ ")
		(forward-line 1))
      (setq end (point))
      (setq str (buffer-substring beg end))
	  (rmail-set-label "ok" t)
      
      (rmail-reply t)
      (goto-char (point-max))
      (setq beg (point))
      (insert str)
      (goto-char (point-max))
      (setq end (point))
      (mc-sign-region 0 beg end)
      (mail-send-and-exit nil))))

(defun buildd-reply-newversion ()
  (interactive)
  (save-excursion
    (let (str)
      (goto-char (point-min))
      (if (not (re-search-forward "only different version \\([^ 	]*\\) found"))
		  (error "Can't find version"))
      (setq str (buffer-substring (match-beginning 1) (match-end 1)))
	  (buildd-prepare-mail "newv" t "newvers " str "\n"))))

(defun buildd-reply-retry ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "retry" t "retry\n")))

(defun buildd-reply-depretry ()
  (interactive)
  (save-excursion
    (let ((deps ""))
      (goto-char (point-min))
      (while (re-search-forward
			  "^E: Package \\([^ ]*\\) has no installation candidate$"
			  (point-max) t)
		(if (> (length deps) 0) (setq deps (concat deps ", ")))
		(setq deps (concat deps (buffer-substring (match-beginning 1)
												  (match-end 1)))))
      (goto-char (point-min))
      (while (re-search-forward
			  "^E: Couldn't find package \\([^ ]*\\)$" (point-max) t)
		(if (> (length deps) 0) (setq deps (concat deps ", ")))
		(setq deps (concat deps (buffer-substring (match-beginning 1)
												  (match-end 1)))))
      (goto-char (point-min))
      (if (re-search-forward
		   "^After installing, the following source dependencies"
		   (point-max) t)
		  (progn
			(forward-line 1)
			(while (re-search-forward
					"\\([^ (]*\\)(inst [^ ]* ! \\([<>=]*\\) wanted \\([^ ]*\\))"
					(point-max) t)
			  (if (> (length deps) 0) (setq deps (concat deps ", ")))
			  (setq deps (concat deps
								 (buffer-substring (match-beginning 1)
												   (match-end 1))
								 " ("
								 (buffer-substring (match-beginning 2)
												   (match-end 2))
								 " "
								 (buffer-substring (match-beginning 3)
												   (match-end 3))
								 ")")))))
	  (buildd-prepare-mail "dretry" nil "dep-retry " deps "\n")
	  (forward-line -1)
	  (end-of-line))))

(defun buildd-reply-giveback ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "giveback" t "giveback\n")))

(defun buildd-reply-notforus ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "not-for-us" t "not-for-us\n")))

(defun buildd-reply-manual ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "manual" t "manual\n")))

(defun buildd-reply-purge ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "purge" t "purge\n")))

(defun buildd-reply-fail ()
  (interactive)
  (save-excursion
	(buildd-prepare-mail "failed" nil "fail\n")
	(goto-char (point-max))))

(defvar buildd-log-base-addr "http://m68k.debian.org/buildd/logs/")

(defun buildd-bug ()
  (interactive)
  (save-excursion
	(let (pkgv pkg vers dist time)
	  (goto-char (point-min))
	  (if (not (re-search-forward "^Subject: Log for .* build of \\([^ 	][^ 	]*\\)_\\([^ 	][^ 	]*\\) (dist=\\([a-z]*\\))"))
		  (error "Can't find package+version in subject"))
	  (setq pkg (buffer-substring (match-beginning 1) (match-end 1))
			vers (buffer-substring (match-beginning 2) (match-end 2))
			dist (buffer-substring (match-beginning 3) (match-end 3)))
	  (setq pkgv (concat pkg "_" vers))
	  (if (not (re-search-forward "^Build started at \\([0-9-]*\\)"))
		  (error "Can't find package+version in subject"))
	  (setq time (buffer-substring (match-beginning 1) (match-end 1)))
	  (rmail-set-label "bug" t)
	  
	  (rmail-mail)
	  (goto-char (point-min))
	  (end-of-line)
	  (insert "submit@bugs.debian.org")
	  (forward-line 1)
	  (end-of-line)
	  (insert (concat pkgv "(" dist "): "))
	  (goto-char (point-max))
	  (insert
	   (concat "Package: " pkg "\nVersion: " vers
			   "\nSeverity: important\n\n\n"
			   "A complete build log can be found at\n"
			   buildd-log-base-addr pkgv "_" time "\n"))
	  (goto-char (point-min))
	  (forward-line 1)
	  (end-of-line))))

(defvar buildd-mail-addr "buildd")

(defun buildd-bug-ack-append (edit-addr)
  (interactive "P")
  (save-excursion
	(let (bugno pkgv pkg vers dist beg end)
	  (goto-char (point-min))
	  (if (not (re-search-forward "^Subject: Bug#\\([0-9]*\\): Acknowledgement (\\([^ 	][^ 	]*\\)_\\([^ 	][^ 	]*\\)(\\([a-z]*\\)): "))
		  (error "Can't find bug#, package+version, and/or dist in subject"))
	  (setq bugno (buffer-substring (match-beginning 1) (match-end 1))
			pkg (buffer-substring (match-beginning 2) (match-end 2))
			vers (buffer-substring (match-beginning 3) (match-end 3))
			dist (buffer-substring (match-beginning 4) (match-end 4)))
	  (setq pkgv (concat pkg "_" vers))
	  (rmail-mail)
	  (goto-char (point-min))
	  (end-of-line)
	  (insert buildd-mail-addr)
	  (forward-line 1)
	  (end-of-line)
	  (insert (concat "Re: Log for failed build of " pkgv " (dist=" dist ")"))
	  (goto-char (point-max))
	  (insert (concat "fail\n(see #" bugno ")\n"))
	  (if (null edit-addr)
		  (mail-send-and-exit nil)
		(progn (goto-char (point-min)) (forward-word 2) (forward-word -1))))))

(defun buildd-bug-comment ()
  (interactive)
  (save-excursion
	(let (pkgv pkg vers dist)
	  (goto-char (point-min))
	  (if (not (re-search-forward "^Subject: \\(Re:[ 	]*\\)?Bug#\\([0-9]*\\): \\([^ 	][^ 	]*\\)_\\([^ 	][^ 	]*\\)(\\([a-z]*\\)"))
		  (error "Can't find bug#, package+version, and/or dist in subject"))
	  (setq pkg (buffer-substring (match-beginning 3) (match-end 3))
			vers (buffer-substring (match-beginning 4) (match-end 4))
			dist (buffer-substring (match-beginning 5) (match-end 5)))
	  (setq pkgv (concat pkg "_" vers))
	  (rmail-mail)
	  (goto-char (point-min))
	  (end-of-line)
	  (insert buildd-mail-addr)
	  (forward-line 1)
	  (end-of-line)
	  (insert (concat "Re: Log for failed build of " pkgv " (dist=" dist ")"))
	  (goto-char (point-max))
	  (insert "fail\n")
	  (call-process "date" nil t nil "+%m/%d/%y")
	  (forward-char -1)
	  (insert ": "))))

(defun buildd-bug-change-category (edit-addr)
  (interactive "P")
  (save-excursion
	(let (cat pkgv pkg vers dist)
	  (goto-char (point-min))
	  (if (not (re-search-forward "^Subject: \\(Re:[ 	]*\\)?Bug#\\([0-9]*\\): \\([^ 	][^ 	]*\\)_\\([^ 	][^ 	]*\\)(\\([a-z]*\\)"))
		  (error "Can't find bug#, package+version, and/or dist in subject"))
	  (setq pkg (buffer-substring (match-beginning 3) (match-end 3))
			vers (buffer-substring (match-beginning 4) (match-end 4))
			dist (buffer-substring (match-beginning 5) (match-end 5)))
	  (setq pkgv (concat pkg "_" vers))
	  (setq cat
			(completing-read "New bug category: "
							 (mapcar (function (lambda (x) (cons x t)))
									 '("fix-expected" "reminder-sent"
									   "nmu-offered" "easy" "medium" "hard"
									   "compiler-error" "uploaded-fixed-pkg"))
							 nil t nil))
	  (rmail-mail)
	  (goto-char (point-min))
	  (end-of-line)
	  (insert buildd-mail-addr)
	  (forward-line 1)
	  (end-of-line)
	  (insert (concat "Re: Log for failed build of " pkgv " (dist=" dist ")"))
	  (goto-char (point-max))
	  (insert (concat "fail\n[" cat "]\n"))
	  (if (null edit-addr)
		  (mail-send-and-exit nil)
		(progn (goto-char (point-min)) (forward-word 2) (forward-word -1))))))

(defun buildd-reopen-bug (bugno)
  (interactive "nBug Number: ")
  (save-excursion
	(rmail-set-label "bug" t)
	(rmail-mail)
	(goto-char (point-min))
	(end-of-line)
	(insert (concat "control@bugs.debian.org, " bugno "@bugs.debian.org"))
	(forward-line 1)
	(end-of-line)
	(insert (concat "Re: Bug#" bugno ": "))
	(goto-char (point-max))
	(insert (concat "reopen " bugno "\nstop\n\n"))))

(defvar manual-source-deps-file-pattern
  "wanna-build/andrea/madd_sd-")

;; Used by buildd-edit-manual-source-deps.

(defun buildd-find-place-for-new-source-dep (package)
  (let ((this-package "")
		(found-place nil))
    (beginning-of-buffer)
    ; Skip the comments and jump to the source deps
    (re-search-forward "^[a-zA-Z0-9]* => ")
    (beginning-of-line)
    (forward-line -1)
    ; Find the first higher (alphabetically later) package name
    (while (and (< (point) (point-max)) (not found-place))
      (progn
		(re-search-forward "^\\([^=|]*[ \t]*|[ \t]*\\)?\\([a-zA-Z0-9.+-]*\\) => ")
		(setq this-package (buffer-substring (match-beginning 2)
											 (match-end 2)))
		(if (string-lessp package this-package)
			(setq found-place t))))
    ; Should never happen (assuming no source package is > `zephyr')
    (if (not found-place)
		(error "Couldn't find place for package %s" package))
    ; Insert the package name, ready for the user to add the first source dep
    (beginning-of-line)
    (insert (format "%s => \n" package))
    (forward-char -1)))

;; Brings up a buffer with source-dependencies.manual file in it and
;; jumps to the right place.

(defun buildd-edit-manual-source-deps ()
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (if (not (re-search-forward "Subject: Log for \\(failed\\|successful\\) build of \\([a-zA-Z0-9.+-]*\\)_[^ ]* (dist=\\([a-z]*\\)"))
		(error "Can't find valid subject"))
    (setq package (buffer-substring (match-beginning 2) (match-end 2)))
    (setq dist (buffer-substring (match-beginning 3) (match-end 3))))
  (setq buf (find-file-noselect (concat manual-source-deps-file-pattern dist)))
  (pop-to-buffer buf)
  (goto-char (point-min))
  (if (re-search-forward (format "^\\([^=|]*[ \t]*|[ \t]*\\)?%s => " package) nil t)
	  (progn
		(end-of-line)
		(insert ", "))
	(buildd-find-place-for-new-source-dep package)))


(defvar manual-sd-map-file
  "wanna-build/andrea/sd_map-unstable")

(defun buildd-add-sd-map (package)
  (interactive "sMap: ")
  (if (not (string= (substring (buffer-name) 0 7) "sd_map-"))
	  (progn (setq buf (find-file-noselect manual-sd-map-file))
			 (pop-to-buffer buf)))
    (goto-char (point-min))
  (goto-char (point-min))
  (if (re-search-forward (format "^\\([^=|]*[ \t]*|[ \t]*\\)?%s => " package) nil t)
	  (progn
		(end-of-line)
		(insert ", "))
	(buildd-find-place-for-new-source-dep package)))

(require 'rmail)
(add-hook 'rmail-mode-hook
		  (lambda ()
			(define-key rmail-mode-map "\C-c\C-o" 'buildd-reply-ok)
			(define-key rmail-mode-map "\C-c\C-n" 'buildd-reply-newversion)
			(define-key rmail-mode-map "\C-c\C-r" 'buildd-reply-retry)
			(define-key rmail-mode-map "\C-c\C-d" 'buildd-reply-depretry)
			(define-key rmail-mode-map "\C-c\C-m" 'buildd-reply-manual)
			(define-key rmail-mode-map "\C-c\C-p" 'buildd-reply-purge)
			(define-key rmail-mode-map "\C-c\C-f" 'buildd-reply-fail)
			(define-key rmail-mode-map "\C-c\M-g" 'buildd-reply-giveback)
			(define-key rmail-mode-map "\C-c\M-n" 'buildd-reply-notforus)
			(define-key rmail-mode-map "\C-c\C-s" 'buildd-edit-manual-source-deps)
			(define-key rmail-mode-map "\C-c\C-b" 'buildd-bug)
			(define-key rmail-mode-map "\C-c\M-b" 'buildd-reopen-bug)
			(define-key rmail-mode-map "\C-c\C-a\C-n" 'buildd-bug-ack-append)
			(define-key rmail-mode-map "\C-c\C-a\C-a" 'buildd-bug-comment)
			(define-key rmail-mode-map "\C-c\C-a\C-c" 'buildd-bug-change-category)))
(global-set-key "\C-c\C-v" 'buildd-add-sd-map)
