;;; inf-ruby.el --- Run a Ruby process in a buffer -*- lexical-binding:t -*-

;; Copyright (C) 1999-2008 Yukihiro Matsumoto, Nobuyoshi Nakada

;; Author: Yukihiro Matsumoto
;;         Nobuyoshi Nakada
;;         Cornelius Mika <cornelius.mika@gmail.com>
;;         Dmitry Gutov <dgutov@yandex.ru>
;;         Kyle Hargraves <pd@krh.me>
;; Maintainer: Dmitry Gutov <dmitry@gutov.dev>
;; URL: http://github.com/nonsequitur/inf-ruby
;; Created: 8 April 1998
;; Keywords: languages ruby
;; Version: 2.9.0
;; Package-Requires: ((emacs "26.1"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; inf-ruby provides a REPL buffer connected to a Ruby subprocess.
;;
;; If you're installing manually, you'll need to:
;; * drop the file somewhere on your load path (perhaps ~/.emacs.d)
;; * Add the following lines to your .emacs file:
;;
;;    (autoload 'inf-ruby "inf-ruby" "Run an inferior Ruby process" t)
;;    (add-hook 'ruby-mode-hook 'inf-ruby-minor-mode)
;;
;; Or, for enh-ruby-mode:
;;
;;    (add-hook 'enh-ruby-mode-hook 'inf-ruby-minor-mode)
;;
;; Installation via ELPA interface does the above for you
;; automatically.
;;
;; Additionally, consider adding
;;
;;    (add-hook 'compilation-filter-hook 'inf-ruby-auto-enter)
;;
;; to your init file to automatically switch from common Ruby compilation
;; modes to interact with a debugger.
;;
;; To call `inf-ruby-console-auto' more easily, you can, for example,
;; replace the original `inf-ruby' binding:
;;
;;   (eval-after-load 'inf-ruby
;;     '(define-key inf-ruby-minor-mode-map
;;        (kbd "C-c C-s") 'inf-ruby-console-auto))

;;; Code:

(require 'comint)
(require 'compile)
(require 'ruby-mode)
(require 'thingatpt)

(eval-when-compile
  (defvar rspec-compilation-mode-map)
  (defvar ruby-compilation-mode-map)
  (defvar projectile-rails-server-mode-map))

(defgroup inf-ruby nil
  "Run Ruby process in a buffer"
  :group 'languages)

(defcustom inf-ruby-prompt-read-only t
  "If non-nil, the prompt will be read-only.

Also see the description of `ielm-prompt-read-only'."
  :type 'boolean
  :group 'inf-ruby)

(defcustom inf-ruby-implementations
  '(("ruby"     . inf-ruby--irb-command)
    ("jruby"    . "jruby -S irb --prompt default --noreadline -r irb/completion")
    ("rubinius" . "rbx -r irb/completion")
    ("yarv"     . "irb1.9 -r irb/completion")
    ("macruby"  . "macirb -r irb/completion")
    ("pry"      . "pry"))
  "An alist mapping Ruby implementations to Irb commands.
CDR of each entry must be either a string or a function that
returns a string."
  :type '(repeat (cons string string))
  :group 'inf-ruby)

(defcustom inf-ruby-default-implementation "ruby"
  "Which Ruby implementation to use if none is specified."
  :type `(choice ,@(mapcar (lambda (item) (list 'const (car item)))
                           inf-ruby-implementations))
  :group 'inf-ruby)

(defcustom inf-ruby-wrapper-command nil
  "Command template to format the auto-detected project console command.
Useful for running the shell in another host or a container (such as Docker).
So when used it must include %s.  Set to nil to disable."
  :type '(choice (const :tag "Not used" nil)
                 (string :tag "Command template"))
  :group 'inf-ruby)

(defun inf-ruby--irb-command ()
  (let ((command "irb --prompt default -r irb/completion --noreadline"))
    (when (inf-ruby--irb-needs-nomultiline-p)
      (setq command (concat command " --nomultiline")))
    command))

(defun inf-ruby--irb-needs-nomultiline-p (&optional with-bundler)
  "Check if IRB needs the --nomultiline argument.
WITH-BUNDLER, the command is wrapped with `bundle exec'."
  (let* ((command (format (or inf-ruby-wrapper-command "%s")
                          (concat (when with-bundler "bundle exec ") "irb -v")))
         (output
          (with-output-to-string
            (let ((status (call-process-shell-command command nil
                                                      standard-output)))
              (unless (eql status 0)
                (error "%s exited with status %s" command status)))))
         (fields (split-string output "[ (]")))
    (if (equal (car fields) "irb")
        (version<= "1.2.0" (nth 1 fields))
      (error "Irb version unknown: %s" output))))

(defcustom inf-ruby-console-environment 'ask
  "Envronment to use for the `inf-ruby-console-*' commands.
If the value is not a string, ask the user to choose from the
available ones.  Otherwise, just use the value.

Currently only affects Rails and Hanami consoles."
  :type '(choice
          (const :tag "Ask the user" ask)
          (string :tag "Environment name")))

(defcustom inf-ruby-reuse-older-buffers t
  "When non-nil, `run-ruby-new' will try to reuse the buffer left
over by a previous Ruby process, as long as it was launched in
the same directory and used the same base name."
  :type 'boolean)

(defcustom inf-ruby-interact-with-fromcomp t
  "When non-nil, commands will use \"from compilation\" buffers.
It's buffers that switched to `inf-ruby-mode' from a Compilation mode,
such as `rspec-compilation-mode', either automatically upon seeing a
\"breakpoint\" or manually. The commands in question will be such
commands as `ruby-send-last-stmt' or `ruby-switch-to-inf'."
  :type 'boolean)

(defconst inf-ruby-prompt-format
  (concat
   (mapconcat
    #'identity
    '("\\(^%s> *\\)"                      ; Simple
      "\\(^(rdb:1) *\\)"                  ; Debugger
      "\\(^(rdbg[^)]*) *\\)"              ; Ruby Debug Gem
      "\\(^(byebug) *\\)"                 ; byebug
      "\\(^[a-z0-9-_]+([a-z0-9-_]+)%s *\\)" ; Rails 7+: project name and environment
      "\\(^\\(irb([^)]+)"                 ; IRB default
      "\\([[0-9]+] \\)?[Pp]ry ?([^)]+)"   ; Pry
      "\\(jruby-\\|JRUBY-\\)?[1-9]\\.[0-9]\\(\\.[0-9]+\\)*\\(-?p?[0-9]+\\)?" ; RVM
      "^rbx-head\\)")                     ; RVM continued
    "\\|")
   ;; Statement and nesting counters, common to the last four.
   " ?[0-9:]* ?%s *\\)")
  "Format string for the prompt regexp pattern.
Two placeholders: first char in the Simple prompt, and the last
graphical char in all other prompts.")

(defvar inf-ruby-first-prompt-pattern (format inf-ruby-prompt-format ">" ">" ">")
  "First prompt regex pattern of Ruby interpreter.")

(defvar inf-ruby-prompt-pattern
  (let ((delims "[\]>*\"'/`]"))
    (format inf-ruby-prompt-format "[?>]" delims delims))
  "Prompt regex pattern of Ruby interpreter.")

(defvar inf-ruby-mode-hook nil
  "Hook for customizing `inf-ruby-mode'.")

(defvar inf-ruby-mode-map
  (let ((map (copy-keymap comint-mode-map)))
    (define-key map (kbd "C-c C-l") 'ruby-load-file)
    (define-key map (kbd "C-c C-k") 'ruby-load-current-file)
    (define-key map (kbd "C-x C-e") 'ruby-send-last-stmt)
    (define-key map (kbd "TAB") 'completion-at-point)
    (define-key map (kbd "C-x C-q") 'inf-ruby-maybe-switch-to-compilation)
    (define-key map (kbd "C-c C-z") 'ruby-switch-to-last-ruby-buffer)
    map)
  "Mode map for `inf-ruby-mode'.")

;;;###autoload
(defvar ruby-source-modes '(ruby-mode enh-ruby-mode)
  "Used to determine if a buffer contains Ruby source code.
If it's loaded into a buffer that is in one of these major modes, it's
considered a ruby source file by `ruby-load-file'.
Used by these commands to determine defaults.")

(defvar ruby-prev-l/c-dir/file nil
  "Caches the last (directory . file) pair.
Caches the last pair used in the last `ruby-load-file' command.
Used for determining the default in the
next one.")

(defvar inf-ruby-at-top-level-prompt-p t)
(make-variable-buffer-local 'inf-ruby-at-top-level-prompt-p)

(defvar inf-ruby-last-prompt nil)
(make-variable-buffer-local 'inf-ruby-last-prompt)

(defconst inf-ruby-error-regexp-alist
  '(("^SyntaxError: \\(?:compile error\n\\)?\\([^\(].*\\):\\([1-9][0-9]*\\):" 1 2)
    ("^\tfrom \\([^\(].*\\):\\([1-9][0-9]*\\)\\(:in `.*'\\)?$" 1 2)))

;;;###autoload
(defun inf-ruby-setup-keybindings ()
  "Hook up `inf-ruby-minor-mode' to each of `ruby-source-modes'."
  (warn "`inf-ruby-setup-keybindings' is deprecated, please don't use it anymore.")
  (warn "If you're using `inf-ruby' from Git, please look up the new usage instructions."))

(make-obsolete 'inf-ruby-setup-keybindings 'add-hook "2.3.1")

(defvar inf-ruby-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-x") 'ruby-send-definition)
    (define-key map (kbd "C-x C-e") 'ruby-send-last-stmt)
    (define-key map (kbd "C-c C-b") 'ruby-send-block)
    (define-key map (kbd "C-c M-b") 'ruby-send-block-and-go)
    (define-key map (kbd "C-c C-x") 'ruby-send-definition)
    (define-key map (kbd "C-c M-x") 'ruby-send-definition-and-go)
    (define-key map (kbd "C-c C-r") 'ruby-send-region)
    (define-key map (kbd "C-c M-r") 'ruby-send-region-and-go)
    (define-key map (kbd "C-c C-z") 'ruby-switch-to-inf)
    (define-key map (kbd "C-c C-l") 'ruby-load-file)
    (define-key map (kbd "C-c C-k") 'ruby-load-current-file)
    (define-key map (kbd "C-c C-s") 'inf-ruby)
    (define-key map (kbd "C-c C-q") 'ruby-quit)
    (easy-menu-define
      inf-ruby-minor-mode-menu
      map
      "Inferior Ruby Minor Mode Menu"
      '("Inf-Ruby"
        ;; TODO: Add appropriate :active (or ENABLE) conditions.
        ["Send definition" ruby-send-definition t]
        ["Send last statement" ruby-send-last-stmt t]
        ["Send block" ruby-send-block t]
        ["Send region" ruby-send-region t]
        "--"
        ["Load file..." ruby-load-file t]
        "--"
        ["Start REPL" inf-ruby t]
        ["Switch to REPL" ruby-switch-to-inf t]
        ))
    map))

;;;###autoload
(define-minor-mode inf-ruby-minor-mode
  "Minor mode for interacting with the inferior process buffer.

The following commands are available:

\\{inf-ruby-minor-mode-map}"
  :lighter "" :keymap inf-ruby-minor-mode-map)

(defvar inf-ruby-buffer nil "The oldest live Ruby process buffer.")

(defvar inf-ruby-buffers nil "List of Ruby process buffers.")

(defvar inf-ruby-buffer-command nil "The command used to run Ruby shell")
(make-variable-buffer-local 'inf-ruby-buffer-command)

(defvar inf-ruby-buffer-impl-name nil "The name of the Ruby shell")
(make-variable-buffer-local 'inf-ruby-buffer-impl-name)

(define-derived-mode inf-ruby-mode comint-mode "Inf-Ruby"
  "Major mode for interacting with an inferior Ruby REPL process.

A simple IRB process can be fired up with \\[inf-ruby].

To launch a REPL with project-specific console instead, type
\\[inf-ruby-console-auto].  It recognizes several
project types, including Rails, gems and anything with `racksh'
in their Gemfile.

Customization: When entered, this mode runs `comint-mode-hook' and
`inf-ruby-mode-hook' (in that order).

You can send text to the inferior Ruby process from other buffers containing
Ruby source.

    `ruby-switch-to-inf' switches the current buffer to the ruby process buffer.
    `ruby-send-definition' sends the current definition to the ruby process.
    `ruby-send-region' sends the current region to the ruby process.
    `ruby-send-definition-and-go' and `ruby-send-region-and-go'
        switch to the ruby process buffer after sending their text.

Commands:
`RET' after the end of the process' output sends the text from the
    end of process to point.
`RET' before the end of the process' output copies the sexp ending at point
    to the end of the process' output, and sends it.
`DEL' converts tabs to spaces as it moves back.
`TAB' completes the input at point. IRB, Pry and Bond completion is supported.
`C-M-q' does `TAB' on each line starting within following expression.
Paragraphs are separated only by blank lines.  # start comments.
If you accidentally suspend your process, use \\[comint-continue-subjob]
to continue it.

The following commands are available:

\\{inf-ruby-mode-map}"
  (setq comint-prompt-regexp inf-ruby-prompt-pattern)

  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-column ruby-comment-column)
  (setq-local comment-start-skip "#+ *")

  (setq-local parse-sexp-ignore-comments t)
  (setq-local parse-sexp-lookup-properties t)

  (when (bound-and-true-p ruby-use-smie)
    (smie-setup ruby-smie-grammar #'ruby-smie-rules
                :forward-token  #'inf-ruby-smie--forward-token
                :backward-token #'inf-ruby-smie--backward-token))

  (add-hook 'comint-output-filter-functions 'inf-ruby-output-filter nil t)
  (setq comint-get-old-input 'inf-ruby-get-old-input)
  (setq-local compilation-error-regexp-alist inf-ruby-error-regexp-alist)
  (setq-local comint-prompt-read-only inf-ruby-prompt-read-only)
  (when (eq system-type 'windows-nt)
    (setq comint-process-echoes t))
  (add-hook 'completion-at-point-functions 'inf-ruby-completion-at-point nil t)
  (compilation-shell-minor-mode t))

(defun inf-ruby-output-filter (output)
  "Check if the current prompt is a top-level prompt."
  (unless (zerop (length output))
    (setq inf-ruby-last-prompt (car (last (split-string output "\n")))
          inf-ruby-at-top-level-prompt-p
          (string-match inf-ruby-first-prompt-pattern
                        inf-ruby-last-prompt))))

;; adapted from replace-in-string in XEmacs (subr.el)
(defun inf-ruby-remove-in-string (str regexp)
  "Remove all matches in STR for REGEXP and returns the new string."
  (let ((rtn-str "") (start 0) match prev-start)
    (while (setq match (string-match regexp str start))
      (setq prev-start start
            start (match-end 0)
            rtn-str (concat rtn-str (substring str prev-start match))))
    (concat rtn-str (substring str start))))

(defun inf-ruby-get-old-input ()
  "Snarf the sexp ending at point."
  (save-excursion
    (let ((end (point)))
      (re-search-backward inf-ruby-first-prompt-pattern)
      (inf-ruby-remove-in-string (buffer-substring (point) end)
                                 inf-ruby-prompt-pattern))))

(defun inf-ruby-buffer ()
  "Return inf-ruby buffer for the current buffer or project."
  (let ((current-dir (locate-dominating-file default-directory
                                             #'inf-ruby-console-match)))
    (and current-dir
         (inf-ruby-buffer-in-directory current-dir))))

(defun inf-ruby-buffer-in-directory (dir &optional impl-name)
  (setq dir (expand-file-name dir))
  (catch 'buffer
    (dolist (buffer inf-ruby-buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and (string= (expand-file-name default-directory) dir)
                     (or (not impl-name)
                         (equal impl-name inf-ruby-buffer-impl-name)))
            (throw 'buffer buffer)))))))

;;;###autoload
(defun inf-ruby (&optional impl)
  "Run an inferior Ruby process in a buffer.
With prefix argument, prompts for which Ruby implementation
\(from the list `inf-ruby-implementations') to use.

If there is a Ruby process running in an existing buffer, switch
to that buffer. Otherwise create a new buffer."
  (interactive (list (if current-prefix-arg
                         (completing-read "Ruby Implementation: "
                                          (mapc #'car inf-ruby-implementations))
                       inf-ruby-default-implementation)))
  (setq impl (or impl "ruby"))

  (let ((command (cdr (assoc impl inf-ruby-implementations))))
    (run-ruby command impl)))

;;;###autoload
(defun run-ruby (&optional command name)
  "Run an inferior Ruby process, input and output in a buffer.

If there is a process already running in a corresponding buffer,
switch to that buffer. Otherwise create a new buffer.

The consecutive buffer names will be:
`*NAME*', `*NAME*<2>', `*NAME*<3>' and so on.

COMMAND defaults to the default entry in
`inf-ruby-implementations'. NAME defaults to \"ruby\".

Runs the hooks `comint-mode-hook' and `inf-ruby-mode-hook'.

Type \\[describe-mode] in the process buffer for the list of commands."
  ;; This function is interactive and named like this for consistency
  ;; with `run-python', `run-octave', `run-lisp' and so on.
  ;; We're keeping both it and `inf-ruby' for backward compatibility.
  (interactive)
  (run-ruby-or-pop-to-buffer
   (let ((command
          (or command
              (cdr (assoc inf-ruby-default-implementation
                          inf-ruby-implementations)))))
     (if (functionp command)
         (funcall command)
       command))
   (or name "ruby")
   (or (inf-ruby-buffer)
       inf-ruby-buffer)))

(defun run-ruby-new (command &optional name)
  "Create a new inferior Ruby process in a new or existing buffer.

COMMAND is the command to call. NAME will be used for the name of
the buffer, defaults to \"ruby\"."
  (setq name (or name "ruby"))

  (let ((commandlist (split-string-and-unquote command))
        (buffer (current-buffer))
        (process-environment (copy-sequence process-environment)))
    ;; http://debbugs.gnu.org/15775
    (setenv "PAGER" (executable-find "cat"))
    (setenv "RUBY_DEBUG_NO_RELINE" "true")
    (set-buffer (apply 'make-comint-in-buffer
                       name
                       (inf-ruby-choose-buffer-name name)
                       (car commandlist)
                       nil (cdr commandlist)))
    (inf-ruby-mode)
    (ruby-remember-ruby-buffer buffer)
    (unless (memq (current-buffer) inf-ruby-buffers)
      (push (current-buffer) inf-ruby-buffers))
    (setq inf-ruby-buffer-impl-name name
          inf-ruby-buffer-command command))

  (unless (and inf-ruby-buffer (comint-check-proc inf-ruby-buffer))
    (setq inf-ruby-buffer (current-buffer)))

  (pop-to-buffer (current-buffer)))

(defun inf-ruby-choose-buffer-name (name)
  "Return the name of a suitable buffer or generate a unique one."
  (let ((buffer (and inf-ruby-reuse-older-buffers
                     (inf-ruby-buffer-in-directory default-directory
                                                   name))))
    (if buffer
        (buffer-name buffer)
      (generate-new-buffer-name (format "*%s*" name)))))

(defun run-ruby-or-pop-to-buffer (command &optional name buffer)
  (if (not (and buffer
                (comint-check-proc buffer)))
      (run-ruby-new command name)
    (pop-to-buffer buffer)
    (unless (and (string= inf-ruby-buffer-impl-name name)
                 (string= inf-ruby-buffer-command command))
      (error (concat "Found inf-ruby buffer, but it was created using "
                     "a different NAME-COMMAND combination: %s, `%s'")
             inf-ruby-buffer-impl-name
             inf-ruby-buffer-command))))

(defun inf-ruby-proc ()
  "Return the inferior Ruby process for the current buffer or project.

See variable `inf-ruby-buffers'."
  (or (get-buffer-process (if (eq major-mode 'inf-ruby-mode)
                              (current-buffer)
                            (or
                             ;; Prioritize the first visible buffer,
                             ;; e.g. for the case when it's inf-ruby
                             ;; switched from compilation mode.
                             (and inf-ruby-interact-with-fromcomp
                                  (inf-ruby-fromcomp-buffer))
                             (inf-ruby-buffer)
                             inf-ruby-buffer)))
      (error "No current process. See variable inf-ruby-buffers")))

(defun inf-ruby-fromcomp-buffer ()
  "Return the first visible compilation buffer in `inf-ruby-mode'."
  (cl-find-if
   (lambda (buf)
     (and (buffer-local-value 'inf-ruby-orig-compilation-mode buf)
          (provided-mode-derived-p (buffer-local-value 'major-mode buf)
                                   'inf-ruby-mode)))
   (mapcar #'window-buffer (window-list))))

;; These commands are added to the inf-ruby-minor-mode keymap:

(defconst ruby-send-terminator "--inf-ruby-%x-%d-%d-%d--"
  "Template for irb here document terminator.
Must not contain ruby meta characters.")

(defconst inf-ruby-eval-binding
  (concat "(defined?(IRB.conf) && IRB.conf[:MAIN_CONTEXT] && IRB.conf[:MAIN_CONTEXT].workspace.binding) || "
          "(defined?(Pry) && Pry.toplevel_binding)"))

(defconst ruby-eval-separator "")

(defun ruby-send-region (start end &optional print prefix suffix line-adjust)
  "Send the current region to the inferior Ruby process."
  (interactive "r\nP")
  (let ((file (or buffer-file-name (buffer-name)))
        line)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char start)
        (setq line (+ start (forward-line (- start)) 1))
        (goto-char start)))
    ;; compilation-parse-errors parses from second line.
    (save-excursion
      (let ((m (process-mark (inf-ruby-proc))))
        (set-buffer (marker-buffer m))
        (goto-char m)
        (insert ruby-eval-separator "\n")
        (set-marker m (point))))
    (if line-adjust
	(setq line (+ line line-adjust)))
    (ruby-send-string (concat prefix
                              (buffer-substring-no-properties start end)
                              suffix)
                      file line)
    (ruby-print-result print)))

(defface inf-ruby-result-overlay-face
  '((((class color) (background light))
     :background "grey90" :box (:line-width -1 :color "yellow"))
    (((class color) (background dark))
     :background "grey10" :box (:line-width -1 :color "black")))
  "Face used to display evaluation results at the end of line.")

;; Overlay

(defun inf-ruby--make-overlay (l r type &rest props)
  "Place an overlay between L and R and return it.
TYPE is a symbol put on the overlay\\='s category property.  It is
used to easily remove all overlays from a region with:
    (remove-overlays start end \\='category TYPE)
PROPS is a plist of properties and values to add to the overlay."
  (let ((o (make-overlay l (or r l) (current-buffer))))
    (overlay-put o 'category type)
    (overlay-put o 'inf-ruby-temporary t)
    (while props (overlay-put o (pop props) (pop props)))
    (push #'inf-ruby--delete-overlay (overlay-get o 'modification-hooks))
    o))

(defun inf-ruby--delete-overlay (ov &rest _)
  "Safely delete overlay OV.
Never throws errors, and can be used in an overlay's
modification-hooks."
  (ignore-errors (delete-overlay ov)))

(defun inf-ruby--make-result-overlay (value where duration &rest props)
  "Place an overlay displaying VALUE at the end of line.
VALUE is used as the overlay's after-string property, meaning it
is displayed at the end of the overlay.  The overlay itself is
placed from beginning to end of current line.
Return nil if the overlay was not placed or if it might not be
visible, and return the overlay otherwise.
Return the overlay if it was placed successfully, and nil if it
failed.
All arguments beyond these (PROPS) are properties to be used on
the overlay."
  (let ((format " => %s ")
	(prepend-face 'inf-ruby-result-overlay-face)
	(type 'result))
    (while (keywordp (car props))
      (setq props (cddr props)))
    ;; If the marker points to a dead buffer, don't do anything.
    (let ((buffer (cond
                   ((markerp where) (marker-buffer where))
                   ((markerp (car-safe where)) (marker-buffer (car where)))
                   (t (current-buffer)))))
      (with-current-buffer buffer
	(save-excursion
          (when (number-or-marker-p where)
            (goto-char where))
          ;; Make sure the overlay is actually at the end of the sexp.
          (skip-chars-backward "\r\n[:blank:]")
          (let* ((beg (if (consp where)
                          (car where)
			(save-excursion
                          (condition-case nil
                              (backward-sexp 1)
                            (scan-error nil))
                          (point))))
		 (end (if (consp where)
                          (cdr where)
			(line-end-position)))
		 (display-string (format format value))
		 (o nil))
            (remove-overlays beg end 'category type)
            (funcall #'put-text-property
                     0 (length display-string)
                     'face prepend-face
                     display-string)
            ;; ;; If the display spans multiple lines or is very long, display it at
            ;; ;; the beginning of the next line.
            ;; (when (or (string-match "\n." display-string)
            ;;           (> (string-width display-string)
            ;;              (- (window-width) (current-column))))
            ;;   (setq display-string (concat " \n" display-string)))
            ;; Put the cursor property only once we're done manipulating the
            ;; string, since we want it to be at the first char.
            (put-text-property 0 1 'cursor 0 display-string)
            (when (> (string-width display-string) (* 3 (window-width)))
              (setq display-string
                    (concat (substring display-string 0 (* 3 (window-width)))
                            "...\nResult truncated.")))
            ;; Create the result overlay.
            (setq o (apply #'inf-ruby--make-overlay
                           beg end type
                           'after-string display-string
                           props))
            (pcase duration
              ((pred numberp) (run-at-time duration nil #'inf-ruby--delete-overlay o))
              (`command (if this-command
                            (add-hook 'pre-command-hook
                                      #'inf-ruby--remove-result-overlay
                                      nil 'local)
                          (inf-ruby--remove-result-overlay))))
            (let ((win (get-buffer-window buffer)))
              ;; Left edge is visible.
              (when (and win
			 (<= (window-start win) (point))
			 ;; In 24.3 `<=' is still a binary predicate.
			 (<= (point) (window-end win))
			 ;; Right edge is visible. This is a little conservative
			 ;; if the overlay contains line breaks.
			 (or (< (+ (current-column) (string-width value))
				(window-width win))
                             (not truncate-lines)))
		o))))))))

(defun inf-ruby--remove-result-overlay ()
  "Remove result overlay from current buffer.
This function also removes itself from `pre-command-hook'."
  (remove-hook 'pre-command-hook #'inf-ruby--remove-result-overlay 'local)
  (remove-overlays nil nil 'category 'result))

(defun inf-ruby--eval-overlay (value)
  "Make overlay for VALUE at POINT."
  (inf-ruby--make-result-overlay value (point) 'command)
  value)

(defun ruby-print-result (&optional insert)
  "Print the result of the last evaluation in the current buffer."
  (let ((result (ruby-print-result-value)))
    (if insert
        (insert result)
      (inf-ruby--eval-overlay result))))

(defun ruby-print-result-value ()
  (let ((proc (inf-ruby-proc)))
    (with-current-buffer (process-buffer proc)
      (while (not (and comint-last-prompt
                       (goto-char (car comint-last-prompt))
                       (looking-at inf-ruby-first-prompt-pattern)))
        (accept-process-output proc))
      (re-search-backward inf-ruby-prompt-pattern)
      (or (re-search-forward "[ \n]=> " (car comint-last-prompt) t)
          ;; Evaluation seems to have failed.
          ;; Try to extract the error string.
          (let* ((inhibit-field-text-motion t)
                 (s (buffer-substring-no-properties (point) (line-end-position))))
            (while (string-match inf-ruby-prompt-pattern s)
              (setq s (replace-match "" t t s)))
            (error "%s" s)))
      (if (looking-at " *$")
          (progn
            (goto-char (1+ (match-end 0)))
            (replace-regexp-in-string
             "\n +" " "
             (buffer-substring-no-properties
              (point)
              (progn
                (forward-sexp)
                (point)))))
        (buffer-substring-no-properties (point) (line-end-position))))))

(defun ruby-shell--encode-string (string)
  "Escape all backslashes, double quotes, newlines, and # in STRING."
  (cl-reduce (lambda (string subst)
               (replace-regexp-in-string (car subst) (cdr subst) string))
             '(("\\\\" . "\\\\\\\\")
               ("\"" . "\\\\\"")
               ("#" . "\\\\#")
               ("\n" . "\\\\n"))
             :initial-value string))

(defun ruby-send-string (string &optional file line)
  "Send STRING to the inferior Ruby process.
Optionally provide FILE and LINE metadata to Ruby."
  (interactive
   (list (read-string "Ruby command: ") nil t))
  (let* ((file-and-lineno (concat (when file
                                    (format ", %S" (file-local-name file)))
                                  (when (and file line)
                                    (format ", %d" line))))
         (proc (inf-ruby-proc))
         (inf-ruby-eval-binding (if (buffer-local-value
                                     'inf-ruby-orig-compilation-mode
                                     (process-buffer proc))
                                    "binding"
                                  inf-ruby-eval-binding))
         (code (format "eval(\"%s\", %s%s)\n"
                       (ruby-shell--encode-string string)
                       inf-ruby-eval-binding
                       file-and-lineno)))
    (if (or (null (process-tty-name proc))
            (<= (string-bytes code)
                (or (bound-and-true-p comint-max-line-length)
                    1024))) ;; For Emacs < 28
        (comint-send-string (inf-ruby-proc) code)
      (let* ((temporary-file-directory (temporary-file-directory))
             (tempfile (make-temp-file "rb"))
             (tempfile-local-name (file-local-name tempfile)))
        (with-temp-file tempfile
          (insert (format "File.delete(%S)\n" tempfile-local-name))
          (insert string))
        (comint-send-string (inf-ruby-proc)
                            (format "eval(File.read(%S), %s%s)\n"
                                    tempfile-local-name
                                    inf-ruby-eval-binding
                                    file-and-lineno))))))

(defun ruby-quit ()
  "Send `exit' to the inferior Ruby process"
  (interactive)
  (process-send-string (inf-ruby-proc) "exit\r")
  (let ((buffer (process-buffer (inf-ruby-proc))))
    (when (buffer-local-value 'inf-ruby-orig-compilation-mode
                              buffer)
      (run-with-idle-timer 0 nil
                           #'inf-ruby-switch-to-compilation
                           buffer))))

(defun ruby-send-definition ()
  "Send the current definition to the inferior Ruby process."
  (interactive)
  (save-excursion
    (let ((orig-start (point))
          (adjust-lineno 0)
          prefix suffix defun-start)
      (save-excursion
        (end-of-line)
        (ruby-beginning-of-defun)
        (setq defun-start (point))
        (unless (ruby-block-contains-point orig-start)
          (error "Point is not within a definition"))
        (while (and (ignore-errors (backward-up-list) t)
                    (looking-at "\\s-*\\(class\\|module\\)\\s-"))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position)
                       (1+ (line-end-position)))))
            (if prefix
                (setq prefix (concat line prefix)
                      suffix (concat suffix "end\n"))
              (setq prefix line
                    suffix "end\n"))
            (setq adjust-lineno (1- adjust-lineno)))))
      (end-of-defun)
      (ruby-send-region defun-start (point) nil prefix suffix adjust-lineno))))

(defun ruby-send-last-sexp (&optional print)
  "Send the previous sexp to the inferior Ruby process."
  (interactive "P")
  (ruby-send-region (save-excursion (ruby-backward-sexp) (point)) (point))
  (ruby-print-result print))

(defun ruby-send-last-stmt (&optional print)
  "Send the preceding statement to the inferior Ruby process."
  (interactive "P")
  (let (beg)
    (save-excursion
      (skip-chars-backward " \t\n")
      (cond
       ((and (derived-mode-p 'ruby-mode)
             (bound-and-true-p smie-rules-function))
        (or (member (nth 2 (smie-backward-sexp ";")) '(";" "#" nil))
            (error "Preceding statement not found"))
        (setq beg (point)))
       (t ; enh-ruby-mode?
        (back-to-indentation)
        (while (and (eq (char-after) ?.)
                    (zerop (forward-line -1)))
          (back-to-indentation))
        (setq beg (point)))))
    (ruby-send-region beg (point)))
  (ruby-print-result print))

(defun ruby-send-block (&optional print)
  "Send the current block to the inferior Ruby process."
  (interactive "P")
  (save-excursion
    (ruby-end-of-block)
    (end-of-line)
    (let ((end (point)))
      (ruby-beginning-of-block)
      (ruby-send-region (point) end)))
  (ruby-print-result print))

(defvar ruby-last-ruby-buffer nil
  "The last buffer we switched to `inf-ruby' from.")
(make-variable-buffer-local 'ruby-last-ruby-buffer)

(defun ruby-remember-ruby-buffer (buffer)
  (setq ruby-last-ruby-buffer buffer))

(defun ruby-switch-to-inf (eob-p)
  "Switch to the ruby process buffer.
With argument, positions cursor at end of buffer."
  (interactive "P")
  (let ((buffer (current-buffer))
        (inf-ruby-buffer* (or (and inf-ruby-interact-with-fromcomp
                                   (inf-ruby-fromcomp-buffer))
                              (inf-ruby-buffer)
                              inf-ruby-buffer)))
    (if inf-ruby-buffer*
        (progn
          (pop-to-buffer inf-ruby-buffer*)
          (ruby-remember-ruby-buffer buffer))
      (error "No current process buffer, see variable inf-ruby-buffers")))
  (cond (eob-p
         (push-mark)
         (goto-char (point-max)))))

(defun ruby-switch-to-last-ruby-buffer ()
  "Switch back to the last Ruby buffer."
  (interactive)
  (if (and ruby-last-ruby-buffer
           (buffer-live-p ruby-last-ruby-buffer))
      (pop-to-buffer ruby-last-ruby-buffer)
    (message "Don't know the original Ruby buffer")))

(defun ruby-send-region-and-go (start end)
  "Send the current region to the inferior Ruby process.
Then switch to the process buffer."
  (interactive "r")
  (ruby-send-region start end)
  (ruby-switch-to-inf t))

(defun ruby-send-definition-and-go ()
  "Send the current definition to the inferior Ruby.
Then switch to the process buffer."
  (interactive)
  (ruby-send-definition)
  (ruby-switch-to-inf t))

(defun ruby-send-block-and-go ()
  "Send the current block to the inferior Ruby.
Then switch to the process buffer."
  (interactive)
  (ruby-send-block)
  (ruby-switch-to-inf t))

(defun ruby-load-file (file-name)
  "Load a Ruby file into the inferior Ruby process."
  (interactive (comint-get-source "Load Ruby file: " ruby-prev-l/c-dir/file
                                  ruby-source-modes t)) ;; T because LOAD needs an exact name
  (comint-check-source file-name) ; Check to see if buffer needs saved.
  (setq ruby-prev-l/c-dir/file (cons (file-name-directory    file-name)
                                     (file-name-nondirectory file-name)))
  (comint-send-string (inf-ruby-proc) (concat "(load \""
                                              (file-local-name file-name)
                                              "\"\)\n")))

(defun ruby-load-current-file ()
  "Load the current ruby file into the inferior Ruby process."
  (interactive)
  (ruby-load-file (buffer-file-name)))

(defun ruby-send-buffer ()
  "Send the current buffer to the inferior Ruby process."
  (interactive)
  (save-restriction
    (widen)
    (ruby-send-region (point-min) (point-max))))

(defun ruby-send-buffer-and-go ()
  "Send the current buffer to the inferior Ruby process.
Then switch to the process buffer."
  (interactive)
  (ruby-send-buffer)
  (ruby-switch-to-inf t))

(defun ruby-send-line ()
  "Send the current line to the inferior Ruby process."
  (interactive)
  (save-restriction
    (widen)
    (ruby-send-region (line-beginning-position) (line-end-position))))

(defun ruby-send-line-and-go ()
  "Send the current line to the inferior Ruby process.
Then switch to the process buffer."
  (interactive)
  (ruby-send-line)
  (ruby-switch-to-inf t))

(defun inf-ruby-completions (prefix)
  "Return a list of completions for the Ruby expression starting with EXPR."
  (let* ((proc (inf-ruby-proc))
         (line
          (concat
           (buffer-substring (save-excursion (move-beginning-of-line 1)
                                             (point))
                             (car (inf-ruby-completion-bounds-of-prefix)))
           ;; prefix can be different, as requested by completion style.
           prefix))
         (target (inf-ruby-completion-target-at-point))
         (prefix-offset (length target))
         (comint-filt (process-filter proc))
         (kept "") completions
         ;; Guard against running completions in parallel:
         inf-ruby-at-top-level-prompt-p)
    (unless (equal "(rdb:1) " inf-ruby-last-prompt)
      (set-process-filter proc (lambda (_proc string) (setq kept (concat kept string))))
      (unwind-protect
          (let ((completion-snippet
                 (format
                  (concat
                   "proc { |expr, line|"
                   "  require 'ostruct';"
                   "  old_wp = defined?(Bond) && Bond.started? && Bond.agent.weapon;"
                   "  begin"
                   "    Bond.agent.instance_variable_set('@weapon',"
                   "      OpenStruct.new(:line_buffer => line)) if old_wp;"
                   "    if defined?(_pry_.complete) then"
                   "      puts _pry_.complete(expr)"
                   "    elsif defined?(pry_instance.complete) then"
                   "      puts pry_instance.complete(expr)"
                   "    else"
                   "      completer = if defined?(_pry_) then"
                   "        Pry.config.completer.build_completion_proc(binding, _pry_)"
                   "      elsif old_wp then"
                   "        Bond.agent"
                   "      elsif defined?(IRB::InputCompletor::CompletionProc) then"
                   "        IRB::InputCompletor::CompletionProc"
                   "      end and puts completer.call(expr).compact"
                   "    end"
                   "  ensure"
                   "    Bond.agent.instance_variable_set('@weapon', old_wp) if old_wp "
                   "  end "
                   "}.call(\"%s\", \"%s\")\n")
                  (ruby-shell--encode-string (concat target prefix))
                  (ruby-shell--encode-string line))))
            (process-send-string proc completion-snippet)
            (while (and (not (string-match inf-ruby-prompt-pattern kept))
                        (accept-process-output proc 2 nil 1)))
            (setq completions (butlast (split-string kept "\r?\n") 2))
            ;; Subprocess echoes output on Windows and OS X.
            (when (and completions (string= (concat (car completions) "\n") completion-snippet))
              (setq completions (cdr completions))))
        (set-process-filter proc comint-filt)))
    (mapcar
     (lambda (str)
       (substring str prefix-offset))
     completions)))

(defconst inf-ruby-ruby-expr-break-chars " \t\n\"\'`><,;|&{(")

(defun inf-ruby-completion-bounds-of-prefix ()
  "Return bounds of expression at point to complete."
  (let ((inf-ruby-ruby-expr-break-chars
         (concat inf-ruby-ruby-expr-break-chars ".")))
    (inf-ruby-completion-bounds-of-expr-at-point)))

(defun inf-ruby-completion-bounds-of-expr-at-point ()
  "Return bounds of expression at point to complete."
  (when (not (memq (char-syntax (following-char)) '(?w ?_)))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward (concat "^" inf-ruby-ruby-expr-break-chars))
        (cons (point) end)))))

(defun inf-ruby-completion-expr-at-point ()
  "Return expression at point to complete."
  (let ((bounds (inf-ruby-completion-bounds-of-expr-at-point)))
    (and bounds
         (buffer-substring (car bounds) (cdr bounds)))))

(defun inf-ruby-completion-target-at-point ()
  (let ((bounds (inf-ruby-completion-bounds-of-expr-at-point)))
    (and bounds
         (buffer-substring
          (car bounds)
          (car (inf-ruby-completion-bounds-of-prefix))))))

(defun inf-ruby-completion-at-point ()
  "Retrieve the list of completions and prompt the user.
Returns the selected completion or nil."
  (let ((bounds (inf-ruby-completion-bounds-of-prefix)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (when inf-ruby-at-top-level-prompt-p
              (if (fboundp 'completion-table-with-cache)
                  (completion-table-with-cache #'inf-ruby-completions)
                (completion-table-dynamic #'inf-ruby-completions)))))))

(defvar inf-ruby-orig-compilation-mode nil
  "Original compilation mode before switching to `inf-ruby-mode'.")

(defvar inf-ruby-orig-process-filter nil
  "Original process filter before switching to `inf-ruby-mode'.")

(defvar inf-ruby-orig-error-regexp-alist nil
  "Original `compilation-error-regexp-alist' before switching to `inf-ruby-mode.'")

(defun inf-ruby-switch-from-compilation ()
  "Make the buffer writable and switch to `inf-ruby-mode'.
Recommended for use when the program being executed enters
interactive mode, i.e. hits a debugger breakpoint."
  (interactive)
  (setq buffer-read-only nil)
  (buffer-enable-undo)
  (let ((mode major-mode)
        (arguments compilation-arguments)
        (orig-mode-line-process mode-line-process)
        (orig-error-alist compilation-error-regexp-alist)
        (cst (bound-and-true-p compilation--start-time)))
    (inf-ruby-mode)
    (setq-local inf-ruby-orig-compilation-mode mode)
    (setq-local compilation-arguments arguments)
    (setq-local inf-ruby-orig-error-regexp-alist orig-error-alist)
    (when cst
      (setq-local compilation--start-time cst))
    (when orig-mode-line-process
      (setq mode-line-process orig-mode-line-process)))
  (let ((proc (get-buffer-process (current-buffer))))
    (when proc
      (setq-local inf-ruby-orig-process-filter (process-filter proc))
      (set-process-filter proc 'comint-output-filter))
    (when (looking-back inf-ruby-prompt-pattern (line-beginning-position))
      (let ((line (match-string 0)))
        (delete-region (match-beginning 0) (point))
        (comint-output-filter proc line)))))

(defun inf-ruby-switch-to-compilation (&optional buffer)
  "Switch to compilation mode this buffer was in before
`inf-ruby-switch-from-compilation' was called.
When BUFFER is non-nil, do that in that buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let ((orig-mode-line-process mode-line-process)
          (proc (get-buffer-process (current-buffer)))
          (arguments compilation-arguments)
          (filter inf-ruby-orig-process-filter)
          (errors inf-ruby-orig-error-regexp-alist)
          (cst (bound-and-true-p compilation--start-time)))
      (funcall inf-ruby-orig-compilation-mode)
      (setq mode-line-process orig-mode-line-process)
      (setq-local compilation-arguments arguments)
      (setq-local compilation-error-regexp-alist errors)
      (when cst
        (setq-local compilation--start-time cst))
      (when proc
        (set-process-filter proc filter)))))

(defun inf-ruby-maybe-switch-to-compilation ()
  "Switch to compilation mode this buffer was in before
`inf-ruby-switch-from-compilation' was called, if it was.
Otherwise, just toggle read-only status."
  (interactive)
  (if inf-ruby-orig-compilation-mode
      (inf-ruby-switch-to-compilation)
    (read-only-mode)))

;;;###autoload
(defun inf-ruby-switch-setup ()
  "Modify `rspec-compilation-mode' and `ruby-compilation-mode'
keymaps to bind `inf-ruby-switch-from-compilation' to `С-x C-q'."
  (eval-after-load 'rspec-mode
    '(define-key rspec-compilation-mode-map (kbd "C-x C-q")
       'inf-ruby-switch-from-compilation))
  (eval-after-load 'ruby-compilation
    '(define-key ruby-compilation-mode-map (kbd "C-x C-q")
       'inf-ruby-switch-from-compilation))
  (eval-after-load 'projectile-rails
    '(define-key projectile-rails-server-mode-map (kbd "C-x C-q")
       'inf-ruby-switch-from-compilation)))

(defvar inf-ruby-console-patterns-alist
  '((".zeus.sock" . zeus)
    (inf-ruby-console-rails-p . rails)
    (inf-ruby-console-hanami-p . hanami)
    (inf-ruby-console-script-p . script)
    ("*.gemspec" . gem)
    (inf-ruby-console-racksh-p . racksh)
    ("Gemfile" . default))
  "Mapping from predicates (wildcard patterns or functions) to type symbols.
`inf-ruby-console-auto' walks up from the current directory until
one of the predicates matches, then calls `inf-ruby-console-TYPE',
passing it the found directory.")

(defvar inf-ruby-breakpoint-pattern "\\(\\[1\\] pry(\\)\\|\\((rdb:1)\\)\\|\\((byebug)\\)\\|\\((rdbg[^)]*)\\)"
  "Pattern found when a breakpoint is triggered in a compilation session.
This checks if the current line is a pry or ruby-debug prompt.")

(defun inf-ruby-console-match (dir)
  "Find matching console command for DIR, if any."
  (catch 'type
    (dolist (pair inf-ruby-console-patterns-alist)
      (let ((default-directory dir)
            (pred (car pair)))
        (when (if (stringp pred)
                  (file-expand-wildcards pred)
                (funcall pred))
          (throw 'type (cdr pair)))))))

;;;###autoload
(defun inf-ruby-console-auto ()
  "Run the Ruby console command appropriate for the project.
The command and the directory to run it from are detected
automatically from `inf-ruby-console-patterns-alist' which
contains the configuration for the known project types."
  (interactive)
  (let* ((dir (locate-dominating-file default-directory
                                      #'inf-ruby-console-match))
         (type (inf-ruby-console-match dir))
         (fun (intern (format "inf-ruby-console-%s" type))))
    (unless type (error "No known project type found. Try `M-x inf-ruby' instead."))
    (funcall fun dir)))

(defun inf-ruby-console-rails-p ()
  (or (file-exists-p "bin/rails")
      (file-exists-p "script/rails")))

(defun inf-ruby-console-read-directory (type)
  (or
   (let ((predicate (car (rassq type inf-ruby-console-patterns-alist))))
     (locate-dominating-file (read-directory-name "" nil nil t)
                             (lambda (dir)
                               (let ((default-directory dir))
                                 (if (stringp predicate)
                                     (file-expand-wildcards predicate)
                                   (funcall predicate))))))
   (error "No matching directory for %s console found"
          (capitalize (symbol-name type)))))

(defun inf-ruby-console-run (command name)
  "Ensure a buffer named NAME running the given COMMAND exists."
  (run-ruby-or-pop-to-buffer (format (or inf-ruby-wrapper-command "%s") command)
                             name
                             (inf-ruby-buffer-in-directory default-directory)))

;;;###autoload
(defun inf-ruby-console-zeus (dir)
  "Run Rails console in DIR using Zeus."
  (interactive (list (inf-ruby-console-read-directory 'zeus)))
  (let ((default-directory (file-name-as-directory dir))
        (exec-prefix (if (executable-find "zeus") "" "bundle exec ")))
    (inf-ruby-console-run (concat exec-prefix "zeus console") "zeus")))

;;;###autoload
(defun inf-ruby-console-rails (dir)
  "Run Rails console in DIR."
  (interactive (list (inf-ruby-console-read-directory 'rails)))
  (let* ((default-directory (file-name-as-directory dir))
         (env (inf-ruby-console-rails-env)))
    (inf-ruby-console-run
     (concat (or
              (cl-find-if #'file-exists-p
                          '("bin/rails" "script/rails"))
              (error "No Rails binstub found, use `rails app:update:bin'"))
             " console -e "
             env
             ;; Note: this only has effect in Rails < 5.0 or >= 5.1.4
             ;; https://github.com/rails/rails/pull/29010
             (when (inf-ruby--irb-needs-nomultiline-p)
               " -- --nomultiline --noreadline"))
     "rails")))

(defun inf-ruby-console-rails-env ()
  (if (stringp inf-ruby-console-environment)
      inf-ruby-console-environment
    (let ((envs (inf-ruby-console-rails-envs)))
      (completing-read "Rails environment: "
                       envs
                       nil t
                       nil nil (car (member "development" envs))))))

(defun inf-ruby-console-rails-envs ()
  (let ((files (file-expand-wildcards "config/environments/*.rb")))
    (if (null files)
        (error "No files in %s" (expand-file-name "config/environments/"))
      (mapcar #'file-name-base files))))

(defun inf-ruby-console-hanami-p ()
  (and (file-exists-p "config.ru")
       (inf-ruby-file-contents-match "config.ru" "\\_<run Hanami.app\\_>")))

(defun inf-ruby-console-hanami (dir)
  "Run Hanami console in DIR."
  (interactive (list (inf-ruby-console-read-directory 'hanami)))
  (let* ((default-directory (file-name-as-directory dir))
         (env (inf-ruby-console-hanami-env))
         (with-bundler (file-exists-p "Gemfile"))
         (process-environment (cons (format "HANAMI_ENV=%s" env)
                                    process-environment)))
    (inf-ruby-console-run
     (concat (when with-bundler "bundle exec ")
             "hanami console")
     "hanami")))

(defun inf-ruby-console-hanami-env ()
  (if (stringp inf-ruby-console-environment)
      inf-ruby-console-environment
    (let ((envs '("development" "test" "production")))
      (completing-read "Hanami environment: "
                       envs
                       nil t
                       nil nil (car (member "development" envs))))))

;;;###autoload
(defun inf-ruby-console-gem (dir)
  "Run IRB console for the gem in DIR.
The main module should be loaded automatically.  If DIR contains a
Gemfile, it should use the `gemspec' instruction."
  (interactive (list (inf-ruby-console-read-directory 'gem)))
  (let* ((default-directory (file-name-as-directory dir))
         (gemspec (car (file-expand-wildcards "*.gemspec")))
         (with-bundler (file-exists-p "Gemfile"))
         (base-command
          (if with-bundler
              (if (inf-ruby-file-contents-match gemspec "\\$LOAD_PATH")
                  "bundle exec irb"
                "bundle exec irb -I lib")
            "irb -I lib"))
         (name (inf-ruby-file-contents-match
                gemspec "\\.name[ \t]*=[ \t]*['\"]\\([^'\"]+\\)['\"]" 1))
         args files)
    (unless (file-exists-p "lib")
      (error "The directory must contain a 'lib' subdirectory"))
    (let ((feature (and name (replace-regexp-in-string "-" "/" name))))
      (if (and feature (file-exists-p (concat "lib/" feature ".rb")))
          ;; There exists the main file corresponding to the gem name,
          ;; let's require it.
          (setq args (concat " -r " feature))
        ;; Let's require all non-directory files under lib, instead.
        (dolist (item (directory-files "lib"))
          (when (and (not (file-directory-p (format "lib/%s" item)))
                     (string-match-p "\\.rb\\'" item))
            (push item files)))
        (setq args
              (mapconcat
               (lambda (file)
                 (concat " -r " (file-name-sans-extension file)))
               files
               ""))))
    (when (inf-ruby--irb-needs-nomultiline-p with-bundler)
      (setq base-command (concat base-command " --nomultiline")))
    (inf-ruby-console-run
     (concat base-command args
             " --prompt default --noreadline -r irb/completion")
     "gem")))

(defun inf-ruby-console-racksh-p ()
  (and (file-exists-p "Gemfile.lock")
       (inf-ruby-file-contents-match "Gemfile.lock" "^ +racksh ")))

(defun inf-ruby-console-racksh (dir)
  "Run racksh in DIR."
  (interactive (list (inf-ruby-console-read-directory 'racksh)))
  (let ((default-directory (file-name-as-directory dir)))
    (inf-ruby-console-run "bundle exec racksh" "racksh")))

(defun inf-ruby-in-ruby-compilation-modes (mode)
  "Check if MODE is a Ruby compilation mode."
  (member mode '(rspec-compilation-mode
                 ruby-compilation-mode
                 projectile-rails-server-mode
                 minitest-compilation-mode)))

;;;###autoload
(defun inf-ruby-auto-enter ()
  "Switch to `inf-ruby-mode' if the breakpoint pattern matches the current line.
Return the end position of the breakpoint prompt."
  (let (pt)
    (when (and (inf-ruby-in-ruby-compilation-modes major-mode)
               (save-excursion
                 (beginning-of-line)
                 (setq pt
                       (re-search-forward inf-ruby-breakpoint-pattern nil t))))
      ;; Exiting excursion before this call to get the prompt fontified.
      (inf-ruby-switch-from-compilation)
      (add-hook 'comint-input-filter-functions 'inf-ruby-auto-exit nil t))
    pt))

;;;###autoload
(defun inf-ruby-auto-enter-and-focus ()
  "Switch to `inf-ruby-mode' on a breakpoint, select that window and set point."
  (let ((window (get-buffer-window))
        (pt (inf-ruby-auto-enter)))
    (when (and pt window)
      (select-window window)
      (goto-char pt))))

;;;###autoload
(defun inf-ruby-auto-exit (input)
  "Return to the previous compilation mode if INPUT is a debugger exit command."
  (when (inf-ruby-in-ruby-compilation-modes inf-ruby-orig-compilation-mode)
    (if (member input '("quit\n" "exit\n" ""))
        ;; After the current command completes, otherwise we get a
        ;; marker error.
        (run-with-idle-timer 0 nil #'inf-ruby-maybe-switch-to-compilation))))

(defun inf-ruby-enable-auto-breakpoint ()
  (interactive)
  (add-hook 'compilation-filter-hook 'inf-ruby-auto-enter))

(defun inf-ruby-disable-auto-breakpoint ()
  (interactive)
  (remove-hook 'compilation-filter-hook 'inf-ruby-auto-enter))

(defun inf-ruby-console-script-p ()
  (and (file-exists-p "Gemfile.lock")
       (or
        (file-exists-p "bin/console")
        (file-exists-p "console")
        (file-exists-p "console.rb"))))

;;;###autoload
(defun inf-ruby-console-script (dir)
  "Run custom bin/console, console or console.rb in DIR."
  (interactive (list (inf-ruby-console-read-directory 'script)))
  (let ((default-directory (file-name-as-directory dir)))
    (cond
     ((file-exists-p "bin/console")
      (inf-ruby-console-run "bundle exec bin/console" "bin/console"))
     ((file-exists-p "console.rb")
      (inf-ruby-console-run "bundle exec ruby console.rb" "console.rb"))
     ((file-exists-p "console")
      (inf-ruby-console-run "bundle exec console" "console.rb")))))

;;;###autoload
(defun inf-ruby-console-default (dir)
  "Run Pry, or bundle console, in DIR."
  (interactive (list (inf-ruby-console-read-directory 'default)))
  (let ((default-directory (file-name-as-directory dir)))
    (unless (file-exists-p "Gemfile")
      (error "The directory must contain a Gemfile"))
    (cond
     ((inf-ruby-file-contents-match "Gemfile" "^[ \t]*gem[ \t]*[\"']pry[\"']")
      (inf-ruby-console-run "bundle exec pry" "pry"))
     (t
      (inf-ruby-console-run "bundle console" "bundle console")))))

;;;###autoload
(defun inf-ruby-file-contents-match (file regexp &optional match-group)
  (with-temp-buffer
    (insert-file-contents file)
    (when (re-search-forward regexp nil t)
      (if match-group
          (match-string match-group)
        t))))

(defun inf-ruby-smie--forward-token ()
  (let ((inhibit-field-text-motion t))
    (ruby-smie--forward-token)))

(defun inf-ruby-smie--backward-token ()
  (let ((inhibit-field-text-motion t))
    (ruby-smie--backward-token)))

;;;###autoload (dolist (mode ruby-source-modes) (add-hook (intern (format "%s-hook" mode)) 'inf-ruby-minor-mode))

(provide 'inf-ruby)
;;; inf-ruby.el ends here
