const outEl = document.getElementById("out");
const runBtn = document.getElementById("run");
const stopBtn = document.getElementById("stop");
const shareBtn = document.getElementById("share");
const examplesEl = document.getElementById("examples");
const statusEl = document.getElementById("status");
const execInfoEl = document.getElementById("exec-info");

function encodeCode(str) {
  return btoa(encodeURIComponent(str).replace(/%([0-9A-F]{2})/g, (match, p1) => String.fromCharCode('0x' + p1)));
}

function decodeCode(str) {
  return decodeURIComponent(Array.prototype.map.call(atob(str), (c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2)).join(''));
}

const samples = {
  hello: `std := import("std")
std.io.println("Hello, Gengo!")`,
  math: `std := import("std")
x := 10
y := 20
z := (x + y) * 2 / 5
std.io.printf("x: %d, y: %d, z: %d\\n", x, y, z)
std.io.println("z is even:", z % 2 == 0)`,
  structs: `std := import("std")
type Point struct {
    x int
    y int
}
func (p Point) squaredLen() int {
    return p.x*p.x + p.y*p.y
}
p := Point{x: 3, y: 4}
std.io.printf("Point: (%d, %d)\\n", p.x, p.y)
std.io.printf("Squared length: %d\\n", p.squaredLen())`,
  loops: `std := import("std")
sum := 0
for i := 1; i <= 10; i++ {
    sum += i
}
std.io.printf("Sum of 1..10: %d\\n", sum)

names := ["Alice", "Bob", "Charlie"]
for name in names {
    std.io.printf("Hello, %s!\\n", name)
}`,
  defer: `std := import("std")
func process() {
    defer std.io.println("cleanup done")
    std.io.println("doing work")
    std.io.println("more work")
}
process()`
};

const MaxOutputBytes = 128 * 1024;
const RunTimeoutMs = 5000;

let worker = null;
let runTimer = null;
let outputBytes = 0;
let editor = null;
let startTime = 0;

// Initialize Monaco
require.config({ paths: { vs: 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs' } });
require(['vs/editor/editor.main'], function () {
  // Register Gengo language
  monaco.languages.register({ id: 'gengo' });
  monaco.languages.setMonarchTokensProvider('gengo', {
    keywords: [
      'true', 'false', 'null', 'if', 'else', 'for', 'in', 'switch', 'case',
      'default', 'return', 'func', 'struct', 'interface', 'type',
      'range', 'enum', 'import', 'var', 'const', 'break', 'continue', 'defer'
    ],
    typeKeywords: ['int', 'float', 'bool', 'string', 'rune'],
    operators: [
      '=', '>', '<', '!', '~', '?', ':', '==', '<=', '>=', '!=',
      '&&', '||', '++', '--', '+', '-', '*', '/', '&', '|', '^', '%',
      '<<', '>>', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', ':=', '..', '...'
    ],
    symbols: /[=><!~?:&|+\-*\/\^%]+/,
    tokenizer: {
      root: [
        [/[a-z_$][\w$]*/, {
          cases: {
            '@keywords': 'keyword',
            '@typeKeywords': 'type',
            '@default': 'identifier'
          }
        }],
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
        [/"([^"\\]|\\.)*$/, 'string.invalid'],
        [/"/, { token: 'string.quote', bracket: '@open', next: '@string' }],
        [/'[^\\']'/, 'string'],
        [/(')(@escapes)(')/, ['string', 'string.escape', 'string']],
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
    escapes: /\\(?:[abfnrtv\\"']|x[0-9A-Fa-f]{1,4}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})/
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

  editor = monaco.editor.create(document.getElementById('editor'), {
    value: samples.hello,
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

  // Handle sharing URL
  const urlParams = new URLSearchParams(window.location.search);
  const codeParam = urlParams.get('code');
  if (codeParam) {
    try {
      editor.setValue(decodeCode(codeParam));
    } catch (e) {
      console.error("Failed to decode code param", e);
    }
  }

  // Keyboard shortcut
  window.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      runBtn.click();
    }
  });
});

function appendOutput(text, isError = false) {
  const n = new TextEncoder().encode(text).length;
  if (outputBytes >= MaxOutputBytes) return;
  
  const span = document.createElement("span");
  if (isError) span.style.color = "var(--err)";
  
  if (outputBytes + n > MaxOutputBytes) {
    const remaining = MaxOutputBytes - outputBytes;
    if (remaining > 0) {
      span.textContent = text.slice(0, remaining);
    }
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

function setIdle(status = "Idle", isError = false) {
  runBtn.disabled = false;
  stopBtn.disabled = true;
  if (runTimer) {
    clearTimeout(runTimer);
    runTimer = null;
  }
  worker = null;
  
  statusEl.innerHTML = `<span class="badge ${isError ? 'error' : 'success'}">${status}</span>`;
  const duration = ((performance.now() - startTime) / 1000).toFixed(2);
  if (startTime > 0) execInfoEl.textContent = `Finished in ${duration}s`;
}

function stopRun(reason) {
  if (worker) worker.terminate();
  setIdle(reason || "Stopped", true);
}

function startWorker(script) {
  startTime = performance.now();
  execInfoEl.textContent = "";
  worker = new Worker("./worker.js", { type: "module" });

  worker.onmessage = (evt) => {
    const msg = evt.data;
    if (msg.kind === "stdout") {
      appendOutput(msg.text);
      return;
    }
    if (msg.kind === "stderr") {
      appendOutput(msg.text, true);
      return;
    }
    if (msg.kind === "done") {
      setIdle("Success");
      return;
    }
    if (msg.kind === "error") {
      appendOutput(String(msg.error) + "\n", true);
      setIdle("Error", true);
    }
  };

  worker.onerror = (err) => {
    appendOutput(String(err.message || err) + "\n", true);
    setIdle("Worker error", true);
  };

  runTimer = setTimeout(() => {
    appendOutput("\n[terminated: timeout]\n", true);
    stopRun("Timeout");
  }, RunTimeoutMs);

  worker.postMessage({ script });
}

runBtn.onclick = () => {
  if (worker) return;
  runBtn.disabled = true;
  stopBtn.disabled = false;
  outEl.innerHTML = "";
  outputBytes = 0;
  statusEl.innerHTML = `<span class="badge" style="color: var(--ink-muted)">Running...</span>`;
  startWorker(editor.getValue());
};

stopBtn.onclick = () => {
  appendOutput("\n[terminated: stopped]\n", true);
  stopRun("Stopped");
};

shareBtn.onclick = () => {
  const code = encodeCode(editor.getValue());
  const url = new URL(window.location);
  url.searchParams.set('code', code);
  window.history.pushState({}, '', url);
  
  // Quick visual feedback
  const originalText = shareBtn.innerHTML;
  shareBtn.innerHTML = "Copied!";
  navigator.clipboard.writeText(url.toString());
  setTimeout(() => shareBtn.innerHTML = originalText, 2000);
};

examplesEl.onchange = () => {
  const val = examplesEl.value;
  if (samples[val]) {
    editor.setValue(samples[val]);
  }
};
