import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";

self.onmessage = async (evt) => {
  const script = evt.data?.script ?? "";
  const post = (kind, payload) => self.postMessage({ kind, ...payload });

  try {
    const encoder = new TextEncoder();
    const fds = [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((line) => post("stdout", { text: line + "\n" })),
      ConsoleStdout.lineBuffered((line) => post("stderr", { text: line + "\n" })),
      new PreopenDirectory(".", new Map([["script.gengo", new File(encoder.encode(script))]])),
    ];

    const wasi = new WASI(["gengo-test.wasm", "script.gengo"], [], fds);
    const res = await fetch("./gengo-test.wasm");
    if (!res.ok) throw new Error(`Failed to fetch wasm: ${res.status}`);

    const wasm = await WebAssembly.instantiateStreaming(res, {
      wasi_snapshot_preview1: wasi.wasiImport,
    });
    wasi.start(wasm.instance);
    post("done", {});
  } catch (err) {
    post("error", { error: String(err) });
  }
};
