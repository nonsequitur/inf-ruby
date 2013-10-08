`inf-ruby.el` provides a REPL buffer connected to an IRB subprocess.

## Installation

### Via package.el

`package.el` is the built-in package manager in Emacs 24+. On Emacs 23
you will need to get [package.el](http://bit.ly/pkg-el23) yourself if you wish to use it.

`inf-ruby` is available on both major `package.el` community
maintained repos -
[Marmalade](http://marmalade-repo.org/packages/inf-ruby) and
[MELPA](http://melpa.milkbox.net).

If you're not already using Marmalade, add this to your
`~/.emacs.d/init.el` (or equivalent) and load it with <kbd>M-x eval-buffer</kbd>.

```lisp
(require 'package)
(add-to-list 'package-archives
             '("marmalade" . "http://marmalade-repo.org/packages/"))
(package-initialize)
```

For MELPA the code you need to add is:

```lisp
(require 'package)
(add-to-list 'package-archives
             '("melpa" . "http://melpa.milkbox.net/packages/") t)
(package-initialize)
```

And then you can install `inf-ruby` with the following command:

<kbd>M-x package-install [RET] inf-ruby [RET]</kbd>

or by adding this bit of Emacs Lisp code to your Emacs initialization file(`.emacs` or `init.el`):

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
(autoload 'inf-ruby "inf-ruby" "Run an inferior Ruby process" t)
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

A Ruby process can be fired up with <kbd>M-x inf-ruby</kbd>.

Customization: When entered, this mode runs `comint-mode-hook` and
`inf-ruby-mode-hook` (in that order).

You can send text to the inferior ruby process from other buffers containing
Ruby source.

* `ruby-switch-to-inf` switches the current buffer to the ruby process buffer.
* `ruby-send-definition` sends the current definition to the ruby process.
* `ruby-send-region` sends the current region to the ruby process.
* `ruby-send-definition-and-go' and `ruby-send-region-and-go` switch to the ruby process buffer after sending their text.

Commands:

* Return after the end of the process' output sends the text from the
end of process to point.
* Return before the end of the process' output copies the sexp ending at point
to the end of the process' output, and sends it.
* Delete converts tabs to spaces as it moves back.
* Tab indents for ruby; with argument, shifts rest
of expression rigidly with the current line.
* <kbd>C-M-q</kbd> does <kbd>Tab</kbd> on each line starting within following expression.
* Paragraphs are separated only by blank lines.  `#`start comments.
* If you accidentally suspend your process, use
`comint-continue-subjob` to continue it.

### Keymap

Here's a list of the keybindings defined by `inf-ruby-minor-mode`.

Keyboard shortcut                    | Command
-------------------------------------|-------------------------------
<kbd>C-M-x</kbd>                     | ruby-send-definition
<kbd>C-x C-e</kbd>                   | ruby-send-last-sexp
<kbd>C-c C-b</kbd>                   | ruby-send-block
<kbd>C-c M-b</kbd>                   | ruby-send-block-and-go
<kbd>C-c C-x</kbd>                   | ruby-send-definition
<kbd>C-c M-x</kbd>                   | ruby-send-definition-and-go
<kbd>C-c C-r</kbd>                   | ruby-send-region
<kbd>C-c M-r</kbd>                   | ruby-send-region-and-go
<kbd>C-c C-z</kdb>                   | ruby-switch-to-inf
<kbd>C-c C-l</kbd>                   | ruby-load-file
<kbd>C-c C-s</kbd>                   | inf-ruby
