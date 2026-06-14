if exists("b:current_syntax")
  finish
endif

syn keyword gengoKeyword
      \ assert break case const continue cycle
      \ default defer else enum false for func
      \ if import in interface null predicate pub
      \ range return struct subtype switch test
      \ trap true type var variant

syn keyword gengoType int float bool string any

syn match gengoOperator "+\|-\|\*\|/\|%\|\*\*\|++\|--"
syn match gengoOperator "==\|!=\|<\|<=\|>\|>="
syn match gengoOperator "&&\|||\|!"
syn match gengoOperator "&\||\|\^\|~\|<<\|>>"
syn match gengoOperator "=\|:=\|+=\|-=\|*=\|/=\|%="
syn match gengoOperator "&=\||=\|^=\|<<=\|>>="
syn match gengoOperator "\.\|\.\.\|\.\.\.\|?"

syn match gengoDelimiter "[(),{}\[\];:]"

syn region gengoString start='"' end='"' contains=gengoEscape
syn match gengoEscape '\\[ntr\\"'"'"']' contained

syn region gengoRawString start="'" end="'"

syn match gengoMultiline "^\\\\.*$"

syn region gengoRune matchgroup=gengoRuneDelim start='`' end='`'

syn match gengoNumber '\<-\=\d[0-9_]*\(\.[0-9][0-9_]*\)\=\([eE][+-]\=\d\+\)\>'

syn match   gengoComment  "//.*$"
syn region  gengoComment  start="/\*" end="\*/"

hi def link gengoKeyword      Keyword
hi def link gengoType         Type
hi def link gengoOperator     Operator
hi def link gengoDelimiter    Delimiter
hi def link gengoString       String
hi def link gengoEscape       SpecialChar
hi def link gengoRawString    String
hi def link gengoMultiline    String
hi def link gengoRune         Character
hi def link gengoRuneDelim    Delimiter
hi def link gengoNumber       Number
hi def link gengoComment      Comment

let b:current_syntax = "gengo"
