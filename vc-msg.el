;;; vc-msg.el --- Show commit information of current line

;; Copyright (C) 2017-2019 Chen Bin
;;
;; Version: 1.0.3
;; Keywords: git vc svn hg messenger
;; Author: Chen Bin <chenbin DOT sh AT gmail DOT com>
;; URL: http://github.com/redguardtoo/vc-msg
;; Package-Requires: ((emacs "24.4") (popup "0.5.0"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Commentary:
;;
;; This package is an extended and actively maintained version of the
;; package emacs-git-messenger.
;;
;; Run "M-x vc-msg-show" and follow the hint.

;; The Version Control Software (VCS) is detected automatically.
;;
;; Set up to force the VCS type (Perforce, for example),
;;   (setq vc-msg-force-vcs "p4")
;;
;; You can add hook to `vc-msg-hook',
;;   (defun vc-msg-hook-setup (vcs-type commit-info)
;;     ;; copy commit id to clipboard
;;     (message (format "%s\n%s\n%s\n%s"
;;                      (plist-get commit-info :id)
;;                      (plist-get commit-info :author)
;;                      (plist-get commit-info :author-time)
;;                      (plist-get commit-info :author-summary))))
;;   (add-hook 'vc-msg-hook 'vc-msg-hook-setup)
;;
;; Hook `vc-msg-show-code-hook' is hook after code of certain commit
;; is displayed.  Here is sample code:
;;   (defun vc-msg-show-code-setup ()
;;     ;; use `ffip-diff-mode' from package find-file-in-project instead of `diff-mode'
;;     (ffip-diff-mode))
;;   (add-hook 'vc-msg-show-code-hook 'vc-msg-show-code-setup)
;;
;; Git users could set `vc-msg-git-show-commit-function' to show the code of commit,
;;
;;   (setq vc-msg-git-show-commit-function 'magit-show-commit)
;;
;; If `vc-msg-git-show-commit-function' is executed, `vc-msg-show-code-hook' is ignored.
;;
;; Perforce is detected automatically.  You don't need any manual setup.
;; But if you use Windows version of perforce CLI in Cygwin Emacs, we
;; provide the variable `vc-msg-p4-file-to-url' to convert file path to
;; ULR so Emacs and Perforce CLI could communicate the file location
;; correctly:
;;   (setq vc-msg-p4-file-to-url '(".*/proj1" "//depot/development/proj1"))
;;
;; The program provides a plugin framework so you can easily write a
;; plugin to support any alien VCS.  Please use "vc-msg-git.el" as a sample.

;; Sample configuration to integrate with Magit (https://magit.vc/),
;;
;; (eval-after-load 'vc-msg-git
;;   '(progn
;;      ;; show code of commit
;;      (setq vc-msg-git-show-commit-function 'magit-show-commit)
;;      ;; open file of certain revision
;;      (push '("m"
;;              "[m]agit-find-file"
;;              (lambda ()
;;                (let* ((info vc-msg-previous-commit-info)
;;                       (git-dir (locate-dominating-file default-directory ".git")))
;;                  (magit-find-file (plist-get info :id )
;;                                   (concat git-dir (plist-get info :filename))))))
;;            vc-msg-git-extra)))
;;

;;; Code:

(require 'cl-lib)
(require 'vc-msg-sdk)

(defgroup vc-msg nil
  "vc-msg"
  :group 'vc)

(defcustom vc-msg-force-vcs nil
  "Extra VCS overrides result of `vc-msg-detect-vcs-type'.
A string like 'git' or 'svn' to lookup `vc-msg-plugins'."
  :type 'string)

(defcustom vc-msg-get-current-file-function 'vc-msg-sdk-get-current-file
  "Get current file path."
  :type 'function)

(defcustom vc-msg-get-line-num-function 'line-number-at-pos
  "Get current line number."
  :type 'function)

(defcustom vc-msg-get-version-function 'vc-msg-sdk-get-version
  "Get version of current file/buffer."
  :type 'function)

(defcustom vc-msg-known-vcs
  '(("p4" . (let* ((output (shell-command-to-string "p4 client -o"))
                   (git-root-dir (vc-msg-sdk-git-rootdir))
                   (root-dir (if (string-match "^Root:[ \t]+\\(.*\\)" output)
                                 (match-string 1 output)))
                   (current-file (funcall vc-msg-get-current-file-function)))
              (if git-root-dir (setq git-root-dir
                                     (file-truename (file-name-as-directory git-root-dir))))

              (if root-dir (setq root-dir
                                 (file-truename (file-name-as-directory root-dir))))
              ;; 'p4 client -o' has the parent directory of `buffer-file-name'
              (and root-dir
                   current-file
                   (string-match-p (format "^%s" root-dir) current-file)
                   (or (not git-root-dir)
                       ;; use `git-p4', git root same as p4 client root
                       (> (length git-root-dir) (length root-dir))))))
    ("svn" . ".svn")
    ("hg" . ".hg")
    ("git" . ".git"))
  "List of known VCS.
In VCS, the key like 'git' or 'svn' is used to locate plugin
in `vc-msg-plugins'.  The directory name like '.git' or '.svn'
is used to locate VCS root directory."
  :type '(repeat sexp))

(defcustom vc-msg-show-at-line-beginning-p t
  "Show the message at beginning of line."
  :type 'boolean)

(defcustom vc-msg-plugins
  '((:type "svn" :execute vc-msg-svn-execute :format vc-msg-svn-format :extra vc-msg-svn-extra)
    (:type "hg" :execute vc-msg-hg-execute :format vc-msg-hg-format :extra vc-msg-hg-extra)
    (:type "p4" :execute vc-msg-p4-execute :format vc-msg-p4-format :extra vc-msg-p4-extra)
    (:type "git" :execute vc-msg-git-execute :format vc-msg-git-format :extra vc-msg-git-extra))
  "List of VCS plugins.
A plugin is a `plist'.  Sample to add a new plugin:

  (defun my-execute (file line &optional extra))
  (defun my-format (info))
  (add-to-list 'vc-msg-plugins
               '(:type \"git\"
                 :execute my-execute
                 :format my-format)

`vc-msg-show' finds correct VCS plugin and show commit message:

  (popup-tip (my-format (my-execute buffer-file-name (line-number-at-pos)))).

The result of `my-execute' is blackbox outside of plugin.
But if result is string, `my-execute' fails and returns error message.
If result is nil, `my-execute' fails silently.
Please check `vc-msg-git-execute' and `vc-msg-git-format' for sample."
  :type '(repeat sexp))

(defcustom vc-msg-newbie-friendly-msg "Press q to quit"
  "Extra friendly hint for newbies."
  :type 'string)

(defcustom vc-msg-hook nil
  "Hook for `vc-msg-show'.
The first parameter of hook is VCS type (\"git\", fore example).
The second parameter is the `plist' of extrated information,
- `(plist-get param :id)`
- `(plist-get param :author)`
- `(plist-get param :author-time)`
- `(plist-get param :author-summary)`
Other extra fields of param may exists which is produced by plugin
and is a blackbox to 'vc-msg.el'."
  :type 'hook)

(defcustom vc-msg-show-code-hook nil
  "Hook after showing the code in a new buffer."
  :type 'hook)

(defcustom vc-msg-previous-commit-info nil
  "Store the data extracted by (plist-get :execute plugin)."
  :type 'sexp)

(defvar-local vc-msg-current-file nil)
(defvar-local vc-msg-executer nil)
(defvar-local vc-msg-formatter nil)
(defvar-local vc-msg-commit-info nil)
(defvar-local vc-msg-extra-commands nil)

(defun vc-msg-match-plugin (plugin)
  "Try match PLUGIN.  Return string keyword or nil."
  (let* ((type (car plugin))
         (algorithm (cdr plugin)))
    (cond
     ((stringp algorithm)
      ;; shell command
      (if (locate-dominating-file default-directory algorithm)
          type))
     ((functionp algorithm)
      ;; execute function
      (if (funcall plugin)
          type))
     ((consp plugin)
      ;; execute lisp expression
      (if (funcall `(lambda () ,algorithm))
          type)))))

(defun vc-msg-detect-vcs-type ()
  "Return VCS type or nil."
  (cond
   ;; use `vc-msg-force-vcs' if it's not nil
   (vc-msg-force-vcs
    vc-msg-force-vcs)
   (t
    ;; or some "smart" algorithm will figure out the correct VCS
    (if (listp vc-msg-known-vcs)
        (cl-some #'vc-msg-match-plugin vc-msg-known-vcs)))))

(defun vc-msg-find-plugin ()
  "Find plugin automatically using `vc-msg-plugins'."
  (let* ((plugin (cl-some (lambda (e)
                            (if (string= (plist-get e :type) (vc-msg-detect-vcs-type)) e))
                          vc-msg-plugins)))
    (if plugin
        ;; load the plugin in run time
        (let* ((plugin-file (intern (concat "vc-msg-" (plist-get plugin :type)))))
          (unless (featurep plugin-file)
            (require plugin-file))))
    plugin))

(defun vc-msg-get-friendly-id (plugin commit-info)
  "Show user the short id if PLUGIN and COMMIT-INFO is correct."
  (let* ((vcs-type (plist-get plugin :type))
         (id (plist-get commit-info :id)))
    (if (member vcs-type '("git" "hg"))
        (vc-msg-sdk-short-id id)
      id)))

(defun vc-msg-copy-all ()
  "Copy the content of popup into `kill-ring'."
  (interactive)
  (let* ((plugin (vc-msg-find-plugin))
         formatter)
    (when plugin
      (setq formatter (plist-get plugin :format))
      (kill-new (funcall formatter vc-msg-previous-commit-info))
      (message "Copy all from commit %s"
               (vc-msg-get-friendly-id plugin
                                 vc-msg-previous-commit-info)))))

(defun vc-msg-show-commit ()
  "Show the commit in `vc-msg-commit-info'."
  (interactive)
  (cl-ecase vc-msg-executer
    ('vc-msg-git-execute
     (let ((commit (plist-get vc-msg-commit-info :id))
           (filename (list (plist-get vc-msg-commit-info :filename))))
       (magit-show-commit commit nil filename)
       (message "Showing %s at %s" filename commit)))))

(defun vc-msg-log ()
  "Show the commit in `vc-msg-commit-info'."
  (interactive)
  (cl-ecase vc-msg-executer
    ('vc-msg-git-execute
     (let* ((commit (plist-get vc-msg-commit-info :id))
            (buffer (magit-log-setup-buffer '("HEAD") nil nil)))
       (with-current-buffer buffer
         (goto-char (point-min))
         (when (re-search-forward (concat "^" (substring commit 0 7)) nil t)
           (beginning-of-line)))))))

(defun vc-msg-blame ()
  (interactive)
  (cl-ecase vc-msg-executer
    ('vc-msg-git-execute
     (magit-blame))))

(defun vc-msg-copy-link ()
  (interactive)
  (cl-ecase vc-msg-executer
    ('vc-msg-git-execute
     (require 'git-link)
     (let ((git-link-use-commit t))
       (call-interactively #'git-link)))))

(pretty-hydra-define vc-msg-hydra
  (:title (concat "vc-msg\n\n"
                  (cl-etypecase vc-msg-commit-info
                    (list
                     (let* ((pad 2)
                            (padstr (make-string pad ?\ ))
                            (width (- (min (window-width) 100) (* pad 2)))
                            (src (funcall vc-msg-formatter vc-msg-commit-info)))
                       (thread-last (split-string src "\n")
                         (mapcar (lambda (s) (seq-partition s width)))
                         (apply #'append)
                         (mapcar (lambda (s) (concat padstr s padstr)))
                         (funcall (lambda (xs) (string-join xs "\n"))))))
                    (string
                     vc-msg-commit-info)))
          :pre (setq vc-msg-commit-info
                     (when vc-msg-current-file
                       (funcall vc-msg-executer
                                vc-msg-current-file
                                (funcall vc-msg-get-line-num-function)
                                (funcall vc-msg-get-version-function))))
          :quit-key ("C-g" "q"))
  ("Copy info"
   (("wa" vc-msg-copy-all "All" :exit t)
    ("wl" vc-msg-copy-link "Commit URL" :exit t))
   "Visit"
   (("c" vc-msg-show-commit "Commit" :exit t)
    ("l" vc-msg-log "Log" :exit t))
   "Blame"
   (("b" (if magit-blame-mode
             (magit-blame-cycle-style)
           (magit-blame-addition nil))
     "Show")
    ("B" magit-blame-quit "Quit"))))

;;;###autoload
(defun vc-msg-show ()
  "Show commit message of current line.
If Git is used and some text inside the line is selected,
the correct commit which submits the selected text is displayed."
  (interactive)
  (let ((plugin (vc-msg-find-plugin)))
    (setq vc-msg-current-file (funcall vc-msg-get-current-file-function))
    (setq vc-msg-executer (plist-get plugin :execute))
    (setq vc-msg-formatter (plist-get plugin :format))
    (vc-msg-hydra/body)))

(provide 'vc-msg)
;;; vc-msg.el ends here
