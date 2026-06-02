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
type Point struct { x int, y int }
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
process()`,

  closures: `std := import("std")

func makeCounter(start int) func() int {
    n := start
    return func() {
        n += 1
        return n
    }
}

a := makeCounter(0)
b := makeCounter(10)

for i := 0; i < 4; i++ {
    std.io.printf("a=%d  b=%d\\n", a(), b())
}`,

  enums: `std := import("std")

type Direction enum { north, south, east, west }

func label(d Direction) string {
    switch d {
        case Direction.north { return "North" }
        case Direction.south { return "South" }
        case Direction.east  { return "East"  }
        default              { return "West"  }
    }
}

func opposite(d Direction) Direction {
    switch d {
        case Direction.north { return Direction.south }
        case Direction.south { return Direction.north }
        case Direction.east  { return Direction.west  }
        default              { return Direction.east  }
    }
}

dirs := [Direction.north, Direction.east, Direction.south, Direction.west]
for d in dirs {
    opp := opposite(d)
    std.io.printf("%s -> %s\\n", label(d), label(opp))
}`,

  named_types: `std := import("std")

type Celsius    float range -273.15..1000.0
type Fahrenheit float range -459.67..1832.0

func toFahrenheit(c Celsius) Fahrenheit {
    return Fahrenheit(float(c) * 9.0 / 5.0 + 32.0)
}

temps := [Celsius(-40.0), Celsius(0.0), Celsius(20.0), Celsius(100.0)]
for t in temps {
    f := toFahrenheit(t)
    std.io.printf("%f C = %f F\\n", float(t), float(f))
}`,

  interfaces: `std := import("std")

type Shape interface {
    area() float
    perimeter() float
}

type Rect   struct { w float, h float }
type Square struct { side float }

func (r Rect)   area() float      { return r.w * r.h }
func (r Rect)   perimeter() float { return 2.0 * (r.w + r.h) }
func (s Square) area() float      { return s.side * s.side }
func (s Square) perimeter() float { return 4.0 * s.side }

func describe(s Shape) {
    std.io.printf("area=%f  perimeter=%f\\n", s.area(), s.perimeter())
}

describe(Rect{w: 4.0, h: 3.0})
describe(Square{side: 5.0})`,

  errors: `std := import("std")

func safeDivide(a float, b float) (float, ?error) {
    if b == 0.0 {
        return 0.0, std.core.error("division by zero")
    }
    return a / b, null
}

pairs := [[10.0, 4.0], [7.0, 0.0], [9.0, 3.0]]
for pair in pairs {
    result, err := safeDivide(pair[0], pair[1])
    if std.core.is_error(err) {
        std.io.printf("%f / %f = error\\n", pair[0], pair[1])
    } else {
        std.io.printf("%f / %f = %f\\n", pair[0], pair[1], result)
    }
}`,

  maps: `std := import("std")
core := std.core

scores := {alice: 95, bob: 82, carol: 78, dave: 91}

std.io.println(core.has(scores, "alice"))
std.io.println(core.has(scores, "eve"))

removed := core.delete(scores, "dave")
std.io.printf("removed dave: %d\\n", removed)
std.io.printf("remaining: %d\\n", core.len(scores))

ks := core.keys(scores)
for k in ks {
    std.io.printf("%s: %d\\n", k, scores[k])
}`,

  arrays: `std := import("std")
core := std.core

nums := [3, 1, 4, 1, 5, 9, 2, 6]

std.io.println(core.contains(nums, 5))
std.io.println(core.contains(nums, 7))

without_first := core.remove(nums, 0)
std.io.printf("after remove: len=%d first=%d\\n",
    core.len(without_first),
    without_first[0],
)

evens := []
for n in nums {
    if n % 2 == 0 {
        evens = core.append(evens, n)
    }
}
std.io.println(evens)`,

  trap_binding: `std := import("std")

func safeDivide(a float, b float) (float, ?error) {
    if b == 0.0 {
        return 0.0, std.core.error("division by zero")
    }
    return a / b, null
}

func runAll(pairs any) {
    defer func() {
        err := std.core.recover()
        if err != null {
            std.io.println("caught:", err)
        }
    }()

    for pair in pairs {
        result, trap := safeDivide(pair[0], pair[1])
        std.io.printf("%.1f / %.1f = %.2f\\n", pair[0], pair[1], result)
    }
}

runAll([[10.0, 2.0], [9.0, 3.0], [5.0, 0.0], [8.0, 4.0]])
std.io.println("done")`,

  multiline: `std := import("std")

// Use \\\\ to start a multiline string line.
// Content is raw — escape sequences are not processed.

msg :=
    \\\\Hello, Gengo!
    \\\\Escape sequences \\n and \\t are NOT processed.
    \\\\Quotes like "this" need no backslash.

std.io.print(msg)`,

  string_ops: `std := import("std")
s := std.string

csv := "alice,bob,carol,dave"
names := s.split(csv, ",")
std.io.printf("names: %d\\n", std.core.len(names))
std.io.println(s.join(names, " | "))

std.io.println(s.trim("  hello world  "))
std.io.println(s.upper("gengo"))
std.io.println(s.lower("GENGO"))

std.io.println(s.starts_with("gengo", "gen"))
std.io.println(s.ends_with("gengo", "go"))

std.io.printf("index of 'world': %d\\n", s.index_of("hello world", "world"))
std.io.printf("index of 'xyz':   %d\\n", s.index_of("hello world", "xyz"))`,

  strings: `std := import("std")

s := "Hello, 世界"
std.io.printf("rune count : %d\\n", std.core.len(s))
std.io.printf("byte count : %d\\n", std.core.bytelen(s))
std.io.printf("first five : %s\\n", s[0:5])
std.io.printf("last two   : %s\\n", s[7:9])

std.io.println("characters:")
for i, ch in s {
    std.io.printf("  [%d] %s\\n", i, ch)
}`
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
      'range', 'enum', 'import', 'const', 'break', 'continue', 'defer', 'assert', 'trap'
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
