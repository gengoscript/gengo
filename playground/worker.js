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
    const encoded = encoder.encode(script);

    // Minimal WASI stubs — engine only calls random/clock/env/io at runtime
    // when the script actually uses those features.
    const wasi = {
      fd_write: (fd, iovs, iovcnt, nwritten) => {
        // gengo_write handles stdout/stderr; fd_write may still be called
        // internally. Return success without writing to keep the engine
        // running.
        const view = new DataView(memory.buffer);
        view.setUint32(nwritten, 0, true);
        return 0;
      },
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_fdstat_get: (fd, buf) => {
        // Pretend fd is a character device.
        const view = new DataView(memory.buffer);
        view.setUint8(buf, 2); // filetype = character_device
        view.setUint16(buf + 2, 0, true); // flags
        view.setBigUint64(buf + 8, 0n, true); // rights_base
        view.setBigUint64(buf + 16, 0n, true); // rights_inheriting
        return 0;
      },
      fd_filestat_get: (fd, buf) => {
        new Uint8Array(memory.buffer, buf, 64).fill(0);
        return 0;
      },
      fd_prestat_get: (fd, buf) => { return 8; }, // not found
      fd_prestat_dir_name: (fd, buf, len) => { return 8; },
      environ_sizes_get: (count, buf_size) => {
        const view = new DataView(memory.buffer);
        view.setUint32(count, 0, true);
        view.setUint32(buf_size, 0, true);
        return 0;
      },
      environ_get: (environ, environ_buf) => { return 0; },
      random_get: (buf, len) => {
        crypto.getRandomValues(new Uint8Array(memory.buffer, buf, len));
        return 0;
      },
      clock_time_get: (id, precision, time_ptr) => {
        const view = new DataView(memory.buffer);
        view.setBigUint64(time_ptr, BigInt(Date.now()) * 1000000n, true);
        return 0;
      },
      clock_res_get: (id, resolution_ptr) => {
        const view = new DataView(memory.buffer);
        view.setBigUint64(resolution_ptr, 1000n, true);
        return 0;
      },
      proc_exit: (code) => finish("done", {}),
      poll_oneoff: (in_ptr, out_ptr, nsubscriptions, nevents) => {
        const view = new DataView(memory.buffer);
        view.setUint32(nevents, 0, true);
        return 0;
      },
      args_sizes_get: (argc, buf_size) => {
        const view = new DataView(memory.buffer);
        view.setUint32(argc, 0, true);
        view.setUint32(buf_size, 0, true);
        return 0;
      },
      args_get: (argv, argv_buf) => { return 0; },
    };

    let memory = null;
    let outputBuf = "";

    // env.gengo_write — capture stdout/stderr from the engine
    const env = {
      gengo_write(ptr, len, is_stderr) {
        const str = new TextDecoder().decode(
          new Uint8Array(memory.buffer, ptr, len)
        );
        outputBuf += str;
        if (is_stderr) {
          post("stderr", { text: str });
        } else {
          post("stdout", { text: str });
        }
      },
    };

    const res = await fetch("./gengo-engine.wasm", { cache: "no-store" });
    if (!res.ok) throw new Error(`Failed to fetch wasm: ${res.status}`);

    const wasm = await WebAssembly.instantiateStreaming(res, {
      wasi_snapshot_preview1: wasi,
      env,
    });

    memory = wasm.instance.exports.memory;

    const handle = wasm.instance.exports.engine_init();
    if (handle === 0) throw new Error("engine_init failed");

    // Write script into WASM linear memory past the data section.
    // The engine has a 4 MB data/stack region; 8 MB is safely past it.
    const scratchOffset = 8 * 1024 * 1024;
    const needed = scratchOffset + encoded.length;
    if (memory.buffer.byteLength < needed) {
      const pagesToAdd = Math.ceil((needed - memory.buffer.byteLength) / 65536);
      memory.grow(pagesToAdd);
    }
    new Uint8Array(memory.buffer, scratchOffset, encoded.length).set(encoded);

    const result = wasm.instance.exports.engine_run(handle, scratchOffset, encoded.length);
    if (result !== 0) {
      // Engine returned an error — read last_error.
      const errBuf = new Uint8Array(memory.buffer, scratchOffset, 512);
      const errLen = wasm.instance.exports.engine_last_error(handle, scratchOffset, 512);
      const errMsg = errLen > 0 ? new TextDecoder().decode(errBuf.slice(0, errLen)) : `error code ${result}`;
      finish("error", { error: errMsg });
      return;
    }

    finish("done", {});
  } catch (err) {
    finish("error", { error: String(err.stack || err) });
  }
};
