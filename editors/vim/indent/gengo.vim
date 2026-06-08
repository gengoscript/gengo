if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal autoindent
setlocal shiftwidth=4
setlocal softtabstop=4
setlocal tabstop=4
setlocal expandtab

let b:undo_indent = "setl ai< sw< sts< ts< et<"
