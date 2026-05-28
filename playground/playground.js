const srcEl = document.getElementById("src");
const outEl = document.getElementById("out");
const runBtn = document.getElementById("run");
const stopBtn = document.getElementById("stop");
const sampleBtn = document.getElementById("sample");
const statusEl = document.getElementById("status");

const sample = `std := import("std")
x := 2 + 3 * 4
std.io.println(x)`;

const MaxOutputBytes = 128 * 1024;
const RunTimeoutMs = 5000;

let worker = null;
let runTimer = null;
let outputBytes = 0;

srcEl.value = sample;

sampleBtn.onclick = () => {
  srcEl.value = sample;
};

function appendOutput(text) {
  const n = new TextEncoder().encode(text).length;
  if (outputBytes >= MaxOutputBytes) return;
  if (outputBytes + n > MaxOutputBytes) {
    const remaining = MaxOutputBytes - outputBytes;
    if (remaining > 0) {
      outEl.textContent += text.slice(0, remaining);
    }
    outEl.textContent += "\n[output truncated]\n";
    outputBytes = MaxOutputBytes;
    return;
  }
  outEl.textContent += text;
  outputBytes += n;
}

function setIdle() {
  runBtn.disabled = false;
  stopBtn.disabled = true;
  if (runTimer) {
    clearTimeout(runTimer);
    runTimer = null;
  }
  worker = null;
}

function stopRun(reason) {
  if (worker) worker.terminate();
  if (reason) statusEl.textContent = reason;
  setIdle();
}

function startWorker(script) {
  worker = new Worker("./worker.js", { type: "module" });

  worker.onmessage = (evt) => {
    const msg = evt.data;
    if (msg.kind === "stdout" || msg.kind === "stderr") {
      appendOutput(msg.text);
      return;
    }
    if (msg.kind === "done") {
      statusEl.textContent = "Done";
      setIdle();
      return;
    }
    if (msg.kind === "error") {
      appendOutput(String(msg.error) + "\n");
      statusEl.textContent = "Error";
      setIdle();
    }
  };

  worker.onerror = (err) => {
    appendOutput(String(err.message || err) + "\n");
    statusEl.textContent = "Worker error";
    setIdle();
  };

  runTimer = setTimeout(() => {
    appendOutput("\n[terminated: timeout]\n");
    stopRun("Timed out");
  }, RunTimeoutMs);

  worker.postMessage({ script });
}

runBtn.onclick = () => {
  if (worker) return;
  runBtn.disabled = true;
  stopBtn.disabled = false;
  outEl.textContent = "";
  outputBytes = 0;
  statusEl.textContent = "Running...";
  startWorker(srcEl.value);
};

stopBtn.onclick = () => {
  appendOutput("\n[terminated: stopped]\n");
  stopRun("Stopped");
};
