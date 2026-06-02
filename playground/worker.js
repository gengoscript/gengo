import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";

self.onmessage = async (evt) => {
  const script = evt.data?.script ?? "";
  const post = (kind, payload) => self.postMessage({ kind, ...payload });

  let finished = false;
  const finish = (kind, payload) => {
    if (finished) return;
    finished = true;
    post(kind, payload);
  };

  try {
    const encoder = new TextEncoder();
    const fds = [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((line) => post("stdout", { text: line + "\n" })),
      ConsoleStdout.lineBuffered((line) => post("stderr", { text: line + "\n" })),
      new PreopenDirectory(".", new Map([["script.gengo", new File(encoder.encode(script))]])),
    ];

    const wasi = new WASI(["gengo-test.wasm", "script.gengo"], [], fds);
    const res = await fetch("./gengo-test.wasm", { cache: "no-store" });
    if (!res.ok) throw new Error(`Failed to fetch wasm: \${res.status}`);

    const wasm = await WebAssembly.instantiateStreaming(res, {
      wasi_snapshot_preview1: wasi.wasiImport,
    });

    try {
      const exitCode = wasi.start(wasm.instance);
      if (exitCode === 0 || exitCode === undefined) {
        finish("done", {});
      } else {
        finish("error", { error: `Exit code \${exitCode}` });
      }
    } catch (err) {
      if (err && (err.name === "ProcExitError" || err.code !== undefined)) {
        if (err.code === 0) {
          finish("done", {});
        } else {
          finish("error", { error: `Exit code \${err.code}` });
        }
      } else {
        throw err;
      }
    }
  } catch (err) {
    finish("error", { error: String(err.stack || err) });
  }
};
