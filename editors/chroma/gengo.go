// Package chroma contains a Gengo lexer for Chroma (used by Hugo and other Go-based syntax highlighters).
package chroma

import (
	"github.com/alecthomas/chroma/v2"
)

// Gengo is a Chroma lexer for the Gengo programming language.
var Gengo = chroma.MustNewLexer(
	&chroma.Config{
		Name:      "Gengo",
		Aliases:   []string{"gengo"},
		Filenames: []string{"*.gengo"},
	},
	func() chroma.Rules {
		return chroma.Rules{
			"root": {
				// Comments
				{`//.*`, chroma.CommentSingle, nil},

				// Keywords
				{`\b(assert|break|case|const|continue|cycle|default|defer|else|enum|false|for|func|if|import|in|interface|null|predicate|pub|range|return|struct|subtype|switch|test|trap|true|type|var|variant)\b`, chroma.Keyword, nil},

				// Built-in types
				{`\b(int|float|bool|string|any)\b`, chroma.KeywordType, nil},

				// Numbers: decimal int, float, scientific
				{`\b-?[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?\b`, chroma.Number, nil},

				// Double-quoted strings with escapes
				{`"(?:[^"\\]|\\.)*"`, chroma.StringDouble, nil},

				// Single-quoted raw strings
				{`'[^']*'`, chroma.StringSingle, nil},

				// Multiline raw string lines
				{`^\\\\`, chroma.StringOther, chroma.Push("multiline")},

				// Rune literals
				{`` `[^`]` `` `, chroma.StringChar, nil},

				// Whitespace
				{`\s+`, chroma.TextWhitespace, nil},
			},
			"multiline": {
				{`$`, chroma.StringOther, chroma.Pop(1)},
				{`.*$`, chroma.StringOther, nil},
			},
		}
	},
)
