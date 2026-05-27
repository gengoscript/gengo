import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";

const srcEl = document.getElementById("src");
const outEl = document.getElementById("out");
const runBtn = document.getElementById("run");
const sampleBtn = document.getElementById("sample");
const statusEl = document.getElementById("status");

const sample = `std := import("std")
x := 2 + 3 * 4
std.io.println(x)`;

srcEl.value = sample;

sampleBtn.onclick = () => {
  srcEl.value = sample;
};

runBtn.onclick = async () => {
  runBtn.disabled = true;
  outEl.textContent = "";
  statusEl.textContent = "Running...";

  const write = (s) => {
    outEl.textContent += s;
  };

  try {
    const encoder = new TextEncoder();
    const script = srcEl.value;

    const fds = [
      new OpenFile(new File([])), // stdin
      ConsoleStdout.lineBuffered((line) => write(line + "\n")), // stdout
      ConsoleStdout.lineBuffered((line) => write(line + "\n")), // stderr
      new PreopenDirectory(".", {
        "script.gengo": new File(encoder.encode(script)),
      }),
    ];

    const wasi = new WASI(["gengo-test.wasm", "script.gengo"], [], fds);

    const res = await fetch("./gengo-test.wasm");
    if (!res.ok) throw new Error(`Failed to fetch wasm: ${res.status}`);

    const wasm = await WebAssembly.instantiateStreaming(res, {
      wasi_snapshot_preview1: wasi.wasiImport,
    });

    wasi.start(wasm.instance);
    statusEl.textContent = "Done";
  } catch (err) {
    write(String(err) + "\n");
    statusEl.textContent = "Error";
  } finally {
    runBtn.disabled = false;
  }
};
