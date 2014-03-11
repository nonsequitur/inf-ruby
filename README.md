`inf-ruby` provides a REPL buffer connected to a Ruby subprocess.

## Installation

### Via package.el

`package.el` is the built-in package manager in Emacs 24+. On Emacs 23
you will need to get [package.el](http://bit.ly/pkg-el23) yourself if you wish to use it.

`inf-ruby` is available on both major `package.el` community
maintained repos:
[Marmalade](http://marmalade-repo.org/packages/inf-ruby) and
[MELPA](http://melpa.milkbox.net/#/inf-ruby).

If you're not already using one of them, follow their installation instructions:
[Marmalade](http://marmalade-repo.org/),
[MELPA](http://melpa.milkbox.net/#/getting-started).

And then you can install `inf-ruby` with the following command:

<kbd>M-x package-install [RET] inf-ruby [RET]</kbd>

or by adding this bit of Emacs Lisp code to your Emacs initialization file (`.emacs` or `init.el`):

```lisp
(unless (package-installed-p 'inf-ruby)
  (package-install 'inf-ruby))
```

If the installation doesn't work try refreshing the package list:

<kbd>M-x package-refresh-contents [RET]</kbd>

### Via el-get

[el-get](https://github.com/dimitri/el-get) is another popular package manager for Emacs.
If you're an el-get user just do <kbd>M-x el-get-install</kbd>.

### Manual

If you're installing manually, you'll need to:

* drop the `inf-ruby.el` file somewhere on your load path (perhaps `~/.emacs.d/vendor`)
* Add the following lines to your `.emacs` (or `init.el`) file:

```lisp
(autoload 'inf-ruby-minor-mode "inf-ruby" "Run an inferior Ruby process" t)
(add-hook 'ruby-mode-hook 'inf-ruby-minor-mode)
```

Or, for [enh-ruby-mode](https://github.com/zenspider/enhanced-ruby-mode):

```lisp
(add-hook 'enh-ruby-mode-hook 'inf-ruby-minor-mode)
```

Installation via `package.el` interface does the above for you
automatically.

Additionally, consider adding

```lisp
(add-hook 'after-init-hook 'inf-ruby-switch-setup)
```

to your init file to easily switch from common Ruby compilation
modes to interact with a debugger.

### Emacs Prelude

`inf-ruby` comes bundled in
[Emacs Prelude](https://github.com/bbatsov/prelude). If you're a
Prelude user you can start using it right away.

## Usage

A simple IRB process can be fired up with <kbd>M-x inf-ruby</kbd>.

To launch a REPL with project-specific console instead, type <kbd>M-x inf-ruby-console-auto</kbd>.
It recognizes several project types, including Rails, gems and anything with `racksh` in their Gemfile.

Customization: When entered, this mode runs `comint-mode-hook` and
`inf-ruby-mode-hook` (in that order).

You can send text to the inferior Ruby process from other buffers containing
Ruby source.

* `ruby-switch-to-inf` switches the current buffer to the ruby process buffer.
* `ruby-send-definition` sends the current definition to the ruby process.
* `ruby-send-region` sends the current region to the ruby process.
* `ruby-send-definition-and-go` and `ruby-send-region-and-go` switch to the ruby process buffer after sending their text.

Commands:

* <kbd>RET</kbd> after the end of the process' output sends the text from the
end of process to point.
* <kbd>RET</kbd> before the end of the process' output copies the sexp ending at point
to the end of the process' output, and sends it.
* <kbd>DEL</kbd> converts tabs to spaces as it moves back.
* <kbd>TAB</kbd> completes the input at point. IRB, Pry and Bond completion is supported.
* <kbd>C-M-q</kbd> does <kbd>TAB</kbd> on each line starting within following expression.
* Paragraphs are separated only by blank lines.  `#` start comments.
* If you accidentally suspend your process, use
`comint-continue-subjob` to continue it.

### Keymap

To see the list of the keybindings defined by `inf-ruby-minor-mode`,
type <kbd>M-x describe-function [RET] inf-ruby-minor-mode [RET]</kbd>.
