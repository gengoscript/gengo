const outEl = document.getElementById("out");
const runBtn = document.getElementById("run");
const stopBtn = document.getElementById("stop");
const shareBtn = document.getElementById("share");
const examplesEl = document.getElementById("examples");
const statusEl = document.getElementById("status");
const execInfoEl = document.getElementById("exec-info");

const encoder = new TextEncoder();

function encodeCode(str) {
  return btoa(encodeURIComponent(str).replace(/%([0-9A-F]{2})/g, (match, p1) => String.fromCharCode('0x' + p1)));
}

function decodeCode(str) {
  return decodeURIComponent(Array.prototype.map.call(atob(str), (c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2)).join(''));
}

function loadExample(key) {
  return fetch(`./examples/${key}.gengo`, { cache: "no-store" }).then(r => {
    if (!r.ok) throw new Error(`Failed to load example: ${key}`);
    return r.text();
  });
}

function clearShareUrl() {
  const url = new URL(window.location);
  if (url.searchParams.has('code')) {
    url.searchParams.delete('code');
    window.history.replaceState({}, '', url);
  }
}

const MaxOutputBytes = 128 * 1024;
const RunTimeoutMs = 5000;

let worker = null;
let runTimer = null;
let outputBytes = 0;
let editor = null;
let startTime = 0;

runBtn.disabled = true;
shareBtn.disabled = true;

require.config({ paths: { vs: 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs' } });
require(['vs/editor/editor.main'], function () {
  monaco.languages.register({ id: 'gengo' });
  monaco.languages.setMonarchTokensProvider('gengo', {
    keywords: [
      'true', 'false', 'null', 'if', 'else', 'for', 'in', 'switch', 'case',
      'default', 'return', 'func', 'struct', 'interface', 'type', 'subtype', 'variant',
      'range', 'enum', 'import', 'const', 'break', 'continue', 'defer', 'assert', 'trap'
    ],
    typeKeywords: ['int', 'float', 'bool', 'string', 'rune', 'any', 'error'],
    operators: [
      '=', '>', '<', '!', '~', '?', ':', '==', '<=', '>=', '!=',
      '&&', '||', '++', '--', '+', '-', '*', '/', '&', '|', '^', '%',
      '<<', '>>', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', ':=', '..', '...'
    ],
    symbols: /[=><!~?:&|+\-*\/\^%]+/,
    escapes: /\\(?:[abfnrtv\\"']|x[0-9A-Fa-f]{1,4}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})/,
    tokenizer: {
      root: [
        [/[a-z_$][\w$]*/, {
          cases: {
            '@keywords': 'keyword',
            '@typeKeywords': 'type',
            '@default': 'identifier'
          }
        }],
        [/\.[a-z_$][\w$]*/, 'type.identifier'],
        [/[A-Z][\w$]*/, 'type.identifier'],
        { include: '@whitespace' },
        [/[{}()\[\]]/, '@brackets'],
        [/@symbols/, {
          cases: {
            '@operators': 'operator',
            '@default': ''
          }
        }],
        [/\d*\.\d+([eE][\-+]?\d+)?/, 'number.float'],
        [/\d+/, 'number'],
        [/[;,.]/, 'delimiter'],
        [/\\\\.*$/, 'string'],
        [/"([^"\\]|\\.)*$/, 'string.invalid'],
        [/"/, { token: 'string.quote', bracket: '@open', next: '@string' }],
        [/'[^']*'/, 'string'],
        [/'/, 'string.invalid']
      ],
      string: [
        [/[^\\"]+/, 'string'],
        [/@escapes/, 'string.escape'],
        [/\\./, 'string.escape.invalid'],
        [/"/, { token: 'string.quote', bracket: '@close', next: '@pop' }]
      ],
      whitespace: [
        [/[ \t\r\n]+/, 'white'],
        [/\/\*/, 'comment', '@comment'],
        [/\/\/.*$/, 'comment'],
      ],
      comment: [
        [/[^\/*]+/, 'comment'],
        [/\/\*/, 'comment', '@push'],
        ["\\*/", 'comment', '@pop'],
        [/[\/*]/, 'comment']
      ],
    },
  });

  monaco.editor.defineTheme('gengo-dark', {
    base: 'vs-dark',
    inherit: true,
    rules: [
      { token: 'keyword', foreground: 'ff7b72' },
      { token: 'type', foreground: 'ffa657' },
      { token: 'string', foreground: 'a5d6ff' },
      { token: 'comment', foreground: '8b949e', fontStyle: 'italic' },
      { token: 'number', foreground: '79c0ff' },
      { token: 'operator', foreground: 'ff7b72' },
    ],
    colors: {
      'editor.background': '#0d1117',
      'editor.foreground': '#c9d1d9',
      'editorLineNumber.foreground': '#484f58',
      'editorLineNumber.activeForeground': '#8b949e',
      'editor.lineHighlightBackground': '#161b22',
      'editor.selectionBackground': '#1f6feb44',
    }
  });

  const urlParams = new URLSearchParams(window.location.search);
  const codeParam = urlParams.get('code');

  const initialPromise = codeParam
    ? Promise.resolve(decodeCode(codeParam))
    : loadExample('hello');

  initialPromise.then(function (initialCode) {
    editor = monaco.editor.create(document.getElementById('editor'), {
      value: initialCode,
      language: 'gengo',
      theme: 'gengo-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', monospace",
      lineNumbersMinChars: 3,
      padding: { top: 16 },
      fixedOverflowWidgets: true
    });

    if (!codeParam) examplesEl.value = 'hello';

    runBtn.disabled = false;
    shareBtn.disabled = false;

    window.addEventListener('keydown', function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') runBtn.click();
    });
  });
});

function appendOutput(text, isError) {
  const n = encoder.encode(text).length;
  if (outputBytes >= MaxOutputBytes) return;

  const span = document.createElement("span");
  if (isError) span.style.color = "var(--err)";

  if (outputBytes + n > MaxOutputBytes) {
    const remaining = MaxOutputBytes - outputBytes;
    if (remaining > 0) span.textContent = text.slice(0, remaining);
    const truncated = document.createElement("div");
    truncated.textContent = "\n[output truncated]";
    truncated.style.color = "var(--ink-muted)";
    outEl.appendChild(span);
    outEl.appendChild(truncated);
    outputBytes = MaxOutputBytes;
    return;
  }

  span.textContent = text;
  outEl.appendChild(span);
  outputBytes += n;
  outEl.scrollTop = outEl.scrollHeight;
}

function setIdle(status, isError) {
  runBtn.disabled = false;
  stopBtn.disabled = true;
  if (runTimer) { clearTimeout(runTimer); runTimer = null; }
  if (worker) { worker.terminate(); worker = null; }
  statusEl.innerHTML = `<span class="badge ${isError ? 'error' : 'success'}">${status}</span>`;
  const duration = ((performance.now() - startTime) / 1000).toFixed(2);
  if (startTime > 0) execInfoEl.textContent = `Finished in ${duration}s`;
}

function stopRun(reason) {
  setIdle(reason || "Stopped", true);
}

function startWorker(script) {
  startTime = performance.now();
  execInfoEl.textContent = "";
  worker = new Worker("./worker.js?v=825db98b", { type: "module" });
  let hasStderr = false;

  worker.onmessage = function (evt) {
    const msg = evt.data;
    if (msg.kind === "stdout") { appendOutput(msg.text); return; }
    if (msg.kind === "stderr") { hasStderr = true; appendOutput(msg.text, true); return; }
    if (msg.kind === "done") { setIdle(hasStderr ? "Error" : "Success", hasStderr); return; }
    if (msg.kind === "error") { appendOutput((msg.error || "unknown error") + "\n", true); setIdle("Error", true); return; }
  };

  worker.onerror = function (err) {
    appendOutput(String(err.message || err) + "\n", true);
    setIdle("Worker error", true);
  };

  runTimer = setTimeout(function () {
    appendOutput("\n[terminated: timeout]\n", true);
    stopRun("Timeout");
  }, RunTimeoutMs);

  worker.postMessage({ script });
}

runBtn.onclick = function () {
  if (worker || !editor) return;
  runBtn.disabled = true;
  stopBtn.disabled = false;
  outEl.innerHTML = "";
  outputBytes = 0;
  statusEl.innerHTML = `<span class="badge" style="color: var(--ink-muted); background: rgba(255,255,255,0.05)">Running...</span>`;
  startWorker(editor.getValue());
};

stopBtn.onclick = function () {
  appendOutput("\n[terminated: stopped]\n", true);
  stopRun("Stopped");
};

function updateUrl(code) {
  const url = new URL(window.location);
  url.searchParams.set('code', encodeCode(code));
  window.history.pushState({}, '', url);
}

shareBtn.onclick = function () {
  if (!editor) return;
  const code = editor.getValue();
  updateUrl(code);
  const originalContent = shareBtn.innerHTML;
  shareBtn.innerHTML = `
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
    Copied!
  `;
  navigator.clipboard.writeText(window.location.href);
  setTimeout(function () { shareBtn.innerHTML = originalContent; }, 2000);
};

examplesEl.onchange = function () {
  if (!editor) return;
  const val = examplesEl.value;
  if (!val) return;
  loadExample(val).then(function (code) {
    editor.setValue(code);
    clearShareUrl();
  });
};
