const std = @import("std");

pub fn build(b: *std.Build) void {
    const preset_opt = b.option([]const u8, "preset", "runtime preset: dev|tiny|stress") orelse "dev";
    const valid = std.mem.eql(u8, preset_opt, "dev") or
        std.mem.eql(u8, preset_opt, "tiny") or
        std.mem.eql(u8, preset_opt, "stress");
    if (!valid) @panic("invalid -Dpreset, expected dev|tiny|stress");

    const perf_opt = b.option(bool, "perf", "Enable performance counters (outputs PERF: lines to stderr)") orelse false;
    const cap_net_opt = b.option(bool, "cap_net", "Include cap:net capability") orelse true;
    const cap_http_opt = b.option(bool, "cap_http", "Include cap:http capability") orelse true;
    const cap_fs_opt = b.option(bool, "cap_fs", "Include cap:fs capability") orelse true;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "perf", perf_opt);
    build_opts.addOption(bool, "cap_net", cap_net_opt);
    build_opts.addOption(bool, "cap_http", cap_http_opt);
    build_opts.addOption(bool, "cap_fs", cap_fs_opt);
    const build_opts_mod = build_opts.createModule();

    const wasmtime_opt = b.option([]const u8, "wasmtime", "path to wasmtime binary") orelse "wasmtime";

    // Copy preset config file into place.
    const preset = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt("cp src/runtime/config_{s}.zig src/runtime/config.zig && echo 'Applied preset: {s}'", .{ preset_opt, preset_opt }),
    });

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // ── Main runtime ──────────────────────────────────────────────────────────

    const gengo_debug = addWasmExe(b, "gengo-runtime", "src/main.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const gengo_release = addWasmExe(b, "gengo-runtime", "src/main.zig", wasm_target, .ReleaseFast, &preset.step, build_opts_mod);

    const install_debug = installWasm(b, gengo_debug, "gengo-runtime.wasm");
    const install_release = installWasm(b, gengo_release, "gengo-runtime.wasm");

    // ── Engine (WASM exports for host embedding) ─────────────────────────────

    const engine_debug = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const engine_release = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, &preset.step, build_opts_mod);

    const install_engine_debug = installWasm(b, engine_debug, "gengo-engine.wasm");
    const install_engine_release = installWasm(b, engine_release, "gengo-engine.wasm");

    // ── Test runners (build + run immediately, no permanent artifact) ─────────

    const vm_safety_exe = addWasmExe(b, "vm-safety-runner", "src/vm_safety_runner.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const run_vm_safety = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_vm_safety.addArtifactArg(vm_safety_exe);

    const embedding_exe = addWasmExe(b, "embedding-runner", "src/embedding_runner.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const run_embedding = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_embedding.addArtifactArg(embedding_exe);

    const engine_runner_exe = addWasmExe(b, "engine-runner", "src/engine_runner.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const run_engine_runner = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/", "--dir", "." });
    run_engine_runner.addArtifactArg(engine_runner_exe);

    const fuzz_runner_exe = addWasmExe(b, "fuzz-runner", "src/fuzz_runner.zig", wasm_target, .Debug, &preset.step, build_opts_mod);
    const run_fuzz_runner = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_fuzz_runner.addArtifactArg(fuzz_runner_exe);

    // ── Native test runner (replaces bash scripts) ────────────────────────────

    const test_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    test_runner_mod.link_libc = true;
    const test_runner_exe = b.addExecutable(.{ .name = "test-runner", .root_module = test_runner_mod });

    // ── Conformance ───────────────────────────────────────────────────────────

    const run_conformance = b.addRunArtifact(test_runner_exe);
    run_conformance.step.dependOn(&install_debug.step);
    run_conformance.addArg("conformance");
    run_conformance.addArg(wasmtime_opt);
    run_conformance.addArg("build/gengo-runtime.wasm");

    // ── Named steps ───────────────────────────────────────────────────────────

    const wasi_step = b.step("wasi", "Build WASI runtime (Debug)");
    wasi_step.dependOn(&install_debug.step);

    const wasi_release_step = b.step("wasi-release", "Build WASI runtime (ReleaseFast)");
    wasi_release_step.dependOn(&install_release.step);

    const engine_build_step = b.step("engine-build", "Build engine WASM module (Debug)");
    engine_build_step.dependOn(&install_engine_debug.step);

    const engine_release_step = b.step("engine-release", "Build engine WASM module (ReleaseFast)");
    engine_release_step.dependOn(&install_engine_release.step);

    // ── Named WASM release artifacts (compile-time capability gating) ─────────

    const cap_combo = b.step("engine-release-full", "Build engine with net+http+fs (ReleaseFast)");
    cap_combo.dependOn(&install_engine_release.step);

    const net_http_opts = b.addOptions();
    net_http_opts.addOption(bool, "perf", perf_opt);
    net_http_opts.addOption(bool, "cap_net", true);
    net_http_opts.addOption(bool, "cap_http", true);
    net_http_opts.addOption(bool, "cap_fs", false);
    const net_http_opts_mod = net_http_opts.createModule();
    const engine_net_http = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, &preset.step, net_http_opts_mod);
    const install_engine_net_http = installWasmAs(b, engine_net_http, "gengo-engine-net.wasm");
    const net_http_step = b.step("engine-release-net", "Build engine with net+http (ReleaseFast)");
    net_http_step.dependOn(&install_engine_net_http.step);

    const fs_opts = b.addOptions();
    fs_opts.addOption(bool, "perf", perf_opt);
    fs_opts.addOption(bool, "cap_net", false);
    fs_opts.addOption(bool, "cap_http", false);
    fs_opts.addOption(bool, "cap_fs", true);
    const fs_opts_mod = fs_opts.createModule();
    const engine_fs = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, &preset.step, fs_opts_mod);
    const install_engine_fs = installWasmAs(b, engine_fs, "gengo-engine-fs.wasm");
    const fs_step = b.step("engine-release-fs", "Build engine with fs only (ReleaseFast)");
    fs_step.dependOn(&install_engine_fs.step);

    const minimal_opts = b.addOptions();
    minimal_opts.addOption(bool, "perf", perf_opt);
    minimal_opts.addOption(bool, "cap_net", false);
    minimal_opts.addOption(bool, "cap_http", false);
    minimal_opts.addOption(bool, "cap_fs", false);
    const minimal_opts_mod = minimal_opts.createModule();
    const engine_minimal = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, &preset.step, minimal_opts_mod);
    const install_engine_minimal = installWasmAs(b, engine_minimal, "gengo-engine-minimal.wasm");
    const minimal_step = b.step("engine-release-minimal", "Build engine with no capabilities (ReleaseFast)");
    minimal_step.dependOn(&install_engine_minimal.step);

    // ── Engine (native shared library for host embedding) ──────────────────────

    const engine_native_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    engine_native_mod.addImport("build_options", build_opts_mod);
    const engine_native = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gengo-engine",
        .root_module = engine_native_mod,
    });
    engine_native.step.dependOn(&preset.step);
    const install_engine_native = b.addInstallArtifact(engine_native, .{});

    const engine_native_release_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    engine_native_release_mod.addImport("build_options", build_opts_mod);
    const engine_native_release = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gengo-engine",
        .root_module = engine_native_release_mod,
    });
    engine_native_release.step.dependOn(&preset.step);
    const install_engine_native_release = b.addInstallArtifact(engine_native_release, .{});

    const engine_native_step = b.step("engine-native", "Build native shared library (Debug)");
    engine_native_step.dependOn(&install_engine_native.step);

    const engine_native_release_step = b.step("engine-native-release", "Build native shared library (ReleaseFast)");
    engine_native_release_step.dependOn(&install_engine_native_release.step);

    const unit_step = b.step("unit", "Run VM safety, embedding, and engine API checks");
    unit_step.dependOn(&run_vm_safety.step);
    unit_step.dependOn(&run_embedding.step);
    unit_step.dependOn(&run_engine_runner.step);

    const test_step = b.step("test", "Run runtime safety, embedding, engine, fuzz, and conformance tests");
    test_step.dependOn(&run_vm_safety.step);
    test_step.dependOn(&run_embedding.step);
    test_step.dependOn(&run_engine_runner.step);
    test_step.dependOn(&run_fuzz_runner.step);
    test_step.dependOn(&install_engine_debug.step);
    test_step.dependOn(&run_conformance.step);

    const run_bench = b.addRunArtifact(test_runner_exe);
    run_bench.step.dependOn(&install_debug.step);
    run_bench.addArg("bench");
    run_bench.addArg(wasmtime_opt);
    run_bench.addArg("build/gengo-runtime.wasm");
    const bench_step = b.step("bench", "Run benchmark suite");
    bench_step.dependOn(&run_bench.step);

    const run_bench_release = b.addRunArtifact(test_runner_exe);
    run_bench_release.step.dependOn(&install_release.step);
    run_bench_release.addArg("bench");
    run_bench_release.addArg(wasmtime_opt);
    run_bench_release.addArg("build/gengo-runtime.wasm");
    const bench_release_step = b.step("bench-release", "Run benchmark suite (ReleaseFast)");
    bench_release_step.dependOn(&run_bench_release.step);

    // bench-perf: perf-instrumented debug build; outputs PERF: lines to stderr
    const perf_opts = b.addOptions();
    perf_opts.addOption(bool, "perf", true);
    const perf_opts_mod = perf_opts.createModule();
    const gengo_perf = addWasmExe(b, "gengo-perf", "src/main.zig", wasm_target, .Debug, &preset.step, perf_opts_mod);
    const install_perf = installWasmAs(b, gengo_perf, "gengo-perf.wasm");

    const bench_perf_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_perf_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    bench_perf_runner_mod.link_libc = true;
    const bench_perf_runner_exe = b.addExecutable(.{ .name = "bench-perf-runner", .root_module = bench_perf_runner_mod });
    const run_bench_perf = b.addRunArtifact(bench_perf_runner_exe);
    run_bench_perf.step.dependOn(&install_perf.step);
    run_bench_perf.addArg(wasmtime_opt);
    const bench_perf_step = b.step("bench-perf", "Run benchmarks with perf counters (PERF: lines on stderr)");
    bench_perf_step.dependOn(&run_bench_perf.step);

    const fuzz_step = b.step("fuzz", "Run fuzz tests (compiler, VM, and boundary inputs)");
    fuzz_step.dependOn(&run_fuzz_runner.step);

    const run_parity = b.addRunArtifact(test_runner_exe);
    run_parity.step.dependOn(&install_debug.step);
    run_parity.addArg("parity");
    run_parity.addArg(wasmtime_opt);
    run_parity.addArg("build/gengo-runtime.wasm");
    const parity_step = b.step("parity", "Run host/embedded parity tests");
    parity_step.dependOn(&run_parity.step);

    // ── Native CLI ────────────────────────────────────────────────────────────

    const native_target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });

    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .Debug,
    });
    native_mod.addImport("build_options", build_opts_mod);
    const native_exe = b.addExecutable(.{ .name = "gengo", .root_module = native_mod });
    native_exe.step.dependOn(&preset.step);
    const install_native = b.addInstallArtifact(native_exe, .{});

    const cli_step = b.step("cli", "Build native CLI binary (zig-out/bin/gengo)");
    cli_step.dependOn(&install_native.step);

    const run_native = b.addRunArtifact(native_exe);
    if (b.args) |args| run_native.addArgs(args);
    const run_step = b.step("run", "Run a script with the native CLI (-- script.gengo)");
    run_step.dependOn(&run_native.step);

    const native_release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .ReleaseSafe,
    });
    native_release_mod.addImport("build_options", build_opts_mod);
    const native_release_exe = b.addExecutable(.{ .name = "gengo", .root_module = native_release_mod });
    native_release_exe.step.dependOn(&preset.step);
    const install_native_release = b.addInstallArtifact(native_release_exe, .{});

    const cli_release_step = b.step("cli-release", "Build native CLI binary (ReleaseSafe)");
    cli_release_step.dependOn(&install_native_release.step);

    // ── Native embed example ──────────────────────────────────────────────────

    const host_embed_mod = b.createModule(.{
        .root_source_file = b.path("src/embed_host_example.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_embed_mod.addImport("build_options", build_opts_mod);
    const host_embed_exe = b.addExecutable(.{
        .name = "embed-host-example",
        .root_module = host_embed_mod,
    });
    host_embed_exe.step.dependOn(&preset.step);
    const run_host_embed = b.addRunArtifact(host_embed_exe);
    const embed_example_step = b.step("embed-example", "Build and run native host embedding example");
    embed_example_step.dependOn(&run_host_embed.step);
}

fn addWasmExe(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    depends_on: *std.Build.Step,
    opts_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("build_options", opts_mod);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.stack_size = 4 * 1024 * 1024;
    exe.step.dependOn(depends_on);
    return exe;
}

fn installWasm(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    dest_name: []const u8,
) *std.Build.Step.Run {
    return installWasmAs(b, exe, dest_name);
}

fn installWasmAs(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    dest_name: []const u8,
) *std.Build.Step.Run {
    const step = b.addSystemCommand(&.{ "bash", "-c", "mkdir -p build && cp \"$1\" \"build/$2\" && if command -v wasm-opt >/dev/null 2>&1; then wasm-opt -O3 --strip-debug \"build/$2\" -o \"build/$2\"; fi", "--" });
    step.addFileArg(exe.getEmittedBin());
    step.addArg(dest_name);
    return step;
}
