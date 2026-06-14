// Gengoscript language definition for Prism.js
Prism.languages.gengo = {
  'comment': [
    {
      pattern: /\/\*[\s\S]*?\*\//,
      greedy: true,
    },
    {
      pattern: /\/\/.*/,
      greedy: true,
    },
  ],

  'string': [
    // Double-quoted escaped strings
    {
      pattern: /"(?:[^"\\]|\\.)*"/,
      greedy: true,
      inside: {
        'escape': {
          pattern: /\\(?:[ntr\\"'/]|x[0-9a-fA-F]{2})/,
        },
      },
    },
    // Single-quoted raw strings
    {
      pattern: /'[^']*'/,
      greedy: true,
    },
    // Multiline raw string lines
    {
      pattern: /^\\\\.*/m,
      greedy: true,
    },
  ],

  'char': {
    pattern: /`[^`]`/,
    greedy: true,
  },

  'number': /\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b/,

  'keyword': /\b(?:assert|break|case|const|continue|cycle|default|defer|else|enum|false|for|func|if|import|in|interface|null|predicate|pub|range|return|struct|subtype|switch|test|trap|true|type|var|variant)\b/,

  'builtin': /\b(?:int|float|bool|string|any)\b/,

  'operator': [
    {
      pattern: /(\*\*|\.\.\.|\.\.|<<=|>>=|<<|>>|&&|\|\||[+\-*/%&|^~!<>=:]=?)/,
    },
  ],

  'punctuation': /[(){}\[\];,.:?]/,
};
