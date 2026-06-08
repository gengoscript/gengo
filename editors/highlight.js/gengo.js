/*
 * highlight.js grammar for Gengo.
 * Usage: hljs.registerLanguage('gengo', gengo);
 */
function gengo(hljs) {
  var KEYWORDS = {
    keyword:
      'assert break case const continue cycle default defer else enum ' +
      'false for func if import in interface null predicate pub range ' +
      'return struct subtype switch test trap true type var variant',
    type: 'int float bool string any',
  };

  var ESCAPE = {
    className: 'attr',
    begin: /\\(?:[ntr\\"'/]|x[0-9a-fA-F]{2})/,
  };

  var STRING_DQ = {
    className: 'string',
    begin: '"',
    end: '"',
    contains: [ESCAPE],
  };

  var STRING_SQ = {
    className: 'string',
    begin: "'",
    end: "'",
  };

  var MULTILINE = {
    className: 'string',
    begin: /^\\\\/m,
    end: /$/m,
  };

  var RUNE = {
    className: 'string',
    match: /`[^`]`/,
  };

  var NUMBER = {
    className: 'number',
    relevance: 0,
    variants: [
      { begin: /\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b/ },
    ],
  };

  var COMMENT = {
    className: 'comment',
    begin: /\/\//,
    end: /$/,
  };

  return {
    name: 'Gengo',
    aliases: ['gengo'],
    keywords: KEYWORDS,
    contains: [
      COMMENT,
      STRING_DQ,
      STRING_SQ,
      MULTILINE,
      RUNE,
      NUMBER,
    ],
  };
}

module.exports = gengo;
