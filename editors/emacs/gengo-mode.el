;;; gengo-mode.el --- Major mode for the Gengoscript programming language  -*- lexical-binding: t; -*-

;; Keywords: languages gengo

;;; Commentary:
;; Provides font-lock and basic indentation for .gengo files.

;;; Code:

(defgroup gengo nil
  "Major mode for Gengoscript."
  :group 'languages)

(defconst gengo-keywords
  '("assert" "break" "case" "const" "continue" "cycle"
    "default" "defer" "else" "enum" "false" "for" "func"
    "if" "import" "in" "interface" "null" "predicate" "pub"
    "range" "return" "struct" "subtype" "switch" "test"
    "trap" "true" "type" "var" "variant")
  "Gengoscript keywords.")

(defconst gengo-types
  '("int" "float" "bool" "string" "any")
  "Gengoscript built-in type names (contextual keywords).")

(defconst gengo-operators
  '("+" "-" "*" "/" "%" "**" "++" "--"
    "==" "!=" "<" "<=" ">" ">="
    "&&" "||" "!"
    "&" "|" "^" "~" "<<" ">>"
    "=" ":=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
    "." ".." "..." "?" ":")
  "Gengoscript operators and punctuation.")

(defvar gengo-font-lock-keywords
  (list
   ;; Keywords
   (cons (regexp-opt gengo-keywords 'words) 'font-lock-keyword-face)
   ;; Built-in types
   (cons (regexp-opt gengo-types 'words) 'font-lock-type-face)
   ;; Numbers: decimal integer, float, scientific
   (cons "\\<-\?[0-9][0-9_]*\\(\\.[0-9][0-9_]*\\)?\\([eE][+-]?[0-9]+\\)?\\>"
         'font-lock-constant-face)
   ;; Rune literals: backtick-delimited single character
   (cons "`.\\|`[^[:ascii:]]" 'font-lock-string-face)
   ;; Multiline raw string lines
   '("^\\\\" . font-lock-string-face)
   ;; Line comments
   '("//.*" . font-lock-comment-face)
   ;; Block comments
   (list "/\\*\\(?:[^*]\\|\\*[^/]\\)*\\*/" 0 'font-lock-comment-face t))
  "Font-lock rules for Gengoscript.")

;;;###autoload
(define-derived-mode gengo-mode prog-mode "Gengoscript"
  "Major mode for editing Gengoscript source files."
  (setq-local font-lock-defaults '(gengo-font-lock-keywords))
  ;; String highlighting
  (setq-local syntax-propertize-function
              (syntax-propertize-rules
               ;; Double-quoted strings with escapes
               (("\"\\(\\\\[\"\\ntr'']\\)*?\"" . "\\"))
               ;; Single-quoted raw strings (no escapes)
               (("'[^']*'" . "."))
               ;; Rune literals
               (("`[^`]`" . "."))))
  ;; Indentation: 4 spaces
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 4)
  (setq-local standard-indent 4))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gengo\\'" . gengo-mode))

(provide 'gengo-mode)

;;; gengo-mode.el ends here
