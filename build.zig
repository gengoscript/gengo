const std = @import("std");

pub fn presetConfigPath(preset: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, preset, "256k")) return "src/runtime/config_256k.zig";
    if (std.mem.eql(u8, preset, "1m")) return "src/runtime/config_1m.zig";
    if (std.mem.eql(u8, preset, "16m")) return "src/runtime/config_16m.zig";
    if (std.mem.eql(u8, preset, "unlimited")) return "src/runtime/config_unlimited.zig";
    if (std.mem.eql(u8, preset, "dev")) return "src/runtime/config_dev.zig";
    if (std.mem.eql(u8, preset, "stress")) return "src/runtime/config_stress.zig";
    return null;
}

pub fn wasmArtifactPath(mode: []const u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "debug")) {
        if (std.mem.eql(u8, name, "gengo-cli.wasm")) return "debug/gengo-cli.wasm";
        if (std.mem.eql(u8, name, "gengo-engine.wasm")) return "debug/gengo-engine.wasm";
        if (std.mem.eql(u8, name, "gengo-perf.wasm")) return "debug/gengo-perf.wasm";
    }
    if (std.mem.eql(u8, mode, "test")) {
        if (std.mem.eql(u8, name, "gengo-cli.wasm")) return "test/gengo-cli.wasm";
    }
    if (std.mem.eql(u8, mode, "release")) {
        if (std.mem.eql(u8, name, "gengo-cli.wasm")) return "release/gengo-cli.wasm";
        if (std.mem.eql(u8, name, "gengo-engine.wasm")) return "release/gengo-engine.wasm";
        if (std.mem.eql(u8, name, "gengo-engine-net.wasm")) return "release/gengo-engine-net.wasm";
        if (std.mem.eql(u8, name, "gengo-engine-fs.wasm")) return "release/gengo-engine-fs.wasm";
        if (std.mem.eql(u8, name, "gengo-engine-minimal.wasm")) return "release/gengo-engine-minimal.wasm";
    }
    unreachable;
}

pub fn build(b: *std.Build) void {
    const preset_opt = b.option([]const u8, "preset", "runtime preset: 256k|1m|16m|unlimited|dev|stress") orelse "1m";
    const preset_config_path = presetConfigPath(preset_opt) orelse @panic("invalid -Dpreset, expected 256k|1m|16m|unlimited|dev|stress");

    const perf_opt = b.option(bool, "perf", "Enable performance counters (outputs PERF: lines to stderr)") orelse false;
    const gc_stress_opt = b.option(bool, "gc_stress", "Force GC on every allocation to detect unrooted-value bugs") orelse false;
    const heap_paranoia_opt = b.option(bool, "heap_paranoia", "Assert no live pointers are overwritten in the heap bump allocator") orelse false;
    const cap_net_opt = b.option(bool, "cap_net", "Include cap:net capability") orelse true;
    const cap_http_opt = b.option(bool, "cap_http", "Include cap:http capability") orelse true;
    const cap_fs_opt = b.option(bool, "cap_fs", "Include cap:fs capability") orelse true;
    const cap_env_opt = b.option(bool, "cap_env", "Include cap:env capability") orelse true;
    const cap_ffi_opt = b.option(bool, "cap_ffi", "Include cap:ffi capability (native CLI only)") orelse false;
    const predicates_opt = b.option(bool, "predicates", "Enable runtime predicate checks") orelse true;
    const gengo_host_opt = b.option(bool, "gengo_host", "Include gengo_host import for host module callbacks") orelse true;
    const gengo_version = "0.6.0-pre2";
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "perf", perf_opt);
    build_opts.addOption(bool, "gc_stress", gc_stress_opt);
    build_opts.addOption(bool, "heap_paranoia", heap_paranoia_opt);
    build_opts.addOption(bool, "cap_net", cap_net_opt);
    build_opts.addOption(bool, "cap_http", cap_http_opt);
    build_opts.addOption(bool, "cap_fs", cap_fs_opt);
    build_opts.addOption(bool, "cap_env", cap_env_opt);
    build_opts.addOption(bool, "cap_ffi", cap_ffi_opt);
    build_opts.addOption(bool, "predicates", predicates_opt);
    build_opts.addOption(bool, "gengo_host", gengo_host_opt);
    build_opts.addOption([]const u8, "version", gengo_version);
    const build_opts_mod = build_opts.createModule();

    // Native CLI gets cap:ffi unconditionally (it is a CLI-only capability:
    // dlopen + hand-rolled SysV trampolines, gated at compile time to x86_64
    // and aarch64). Every other build — the WASM CLI, engines, runners, and
    // the native engine .so — uses build_opts_mod above with cap_ffi=false.
    const native_cli_opts = b.addOptions();
    native_cli_opts.addOption(bool, "perf", perf_opt);
    native_cli_opts.addOption(bool, "gc_stress", gc_stress_opt);
    native_cli_opts.addOption(bool, "heap_paranoia", heap_paranoia_opt);
    native_cli_opts.addOption(bool, "cap_net", cap_net_opt);
    native_cli_opts.addOption(bool, "cap_http", cap_http_opt);
    native_cli_opts.addOption(bool, "cap_fs", cap_fs_opt);
    native_cli_opts.addOption(bool, "cap_env", cap_env_opt);
    native_cli_opts.addOption(bool, "cap_ffi", true);
    native_cli_opts.addOption(bool, "predicates", predicates_opt);
    native_cli_opts.addOption(bool, "gengo_host", gengo_host_opt);
    native_cli_opts.addOption([]const u8, "version", gengo_version);
    const native_cli_opts_mod = native_cli_opts.createModule();
    const runtime_config_mod = b.createModule(.{ .root_source_file = b.path(preset_config_path) });

    const wasmtime_opt = b.option([]const u8, "wasmtime", "path to wasmtime binary") orelse "wasmtime";
    const test_filter_opt = b.option([]const u8, "test_filter", "Filter test cases by filename substring (chaos, native-cap)");
    const conformance_wasm_opt = b.option([]const u8, "conformance_wasm", "WASM artifact to test with the conformance runner");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // ── Main runtime ──────────────────────────────────────────────────────────

    const gengo_debug = addWasmExe(b, "gengo-cli", "src/main.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const gengo_release = addWasmExe(b, "gengo-cli", "src/main.zig", wasm_target, .ReleaseFast, build_opts_mod, runtime_config_mod);

    const install_debug = installWasm(b, gengo_debug, wasmArtifactPath("debug", "gengo-cli.wasm"));
    const install_release = installWasm(b, gengo_release, wasmArtifactPath("release", "gengo-cli.wasm"));
    const install_test = installOptimizedWasm(b, gengo_release, wasmArtifactPath("test", "gengo-cli.wasm"));

    // ── Engine (WASM exports for host embedding) ─────────────────────────────

    const engine_debug = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const engine_release = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, build_opts_mod, runtime_config_mod);

    const install_engine_debug = installWasm(b, engine_debug, wasmArtifactPath("debug", "gengo-engine.wasm"));
    const install_engine_release = installWasm(b, engine_release, wasmArtifactPath("release", "gengo-engine.wasm"));

    // ── Test runners (build + run immediately, no permanent artifact) ─────────

    const vm_safety_exe = addWasmExe(b, "vm-safety-runner", "src/vm_safety_runner.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const run_vm_safety = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_vm_safety.addArtifactArg(vm_safety_exe);

    const vm_value_exe = addWasmExe(b, "vm-value-runner", "src/vm_value_runner.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const run_vm_value = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_vm_value.addArtifactArg(vm_value_exe);

    const embedding_exe = addWasmExe(b, "embedding-runner", "src/embedding_runner.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const run_embedding = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_embedding.addArtifactArg(embedding_exe);

    const engine_runner_exe = addWasmExe(b, "engine-runner", "src/engine_runner.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const run_engine_runner = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/", "--dir", "." });
    run_engine_runner.addArtifactArg(engine_runner_exe);

    const fuzz_runner_exe = addWasmExe(b, "fuzz-runner", "src/fuzz_runner.zig", wasm_target, .Debug, build_opts_mod, runtime_config_mod);
    const run_fuzz_runner = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_fuzz_runner.addArtifactArg(fuzz_runner_exe);

    const fuzz_gc_stress_opts = b.addOptions();
    fuzz_gc_stress_opts.addOption(bool, "perf", false);
    fuzz_gc_stress_opts.addOption(bool, "gc_stress", true);
    fuzz_gc_stress_opts.addOption(bool, "heap_paranoia", false);
    fuzz_gc_stress_opts.addOption(bool, "cap_net", cap_net_opt);
    fuzz_gc_stress_opts.addOption(bool, "cap_http", cap_http_opt);
    fuzz_gc_stress_opts.addOption(bool, "cap_fs", cap_fs_opt);
    fuzz_gc_stress_opts.addOption(bool, "cap_env", cap_env_opt);
    fuzz_gc_stress_opts.addOption(bool, "cap_ffi", false);
    fuzz_gc_stress_opts.addOption(bool, "predicates", predicates_opt);
    fuzz_gc_stress_opts.addOption(bool, "gengo_host", gengo_host_opt);
    fuzz_gc_stress_opts.addOption([]const u8, "version", gengo_version);
    const fuzz_gc_stress_opts_mod = fuzz_gc_stress_opts.createModule();
    const fuzz_gc_stress_exe = addWasmExe(b, "fuzz-runner-gc-stress", "src/fuzz_runner.zig", wasm_target, .Debug, fuzz_gc_stress_opts_mod, runtime_config_mod);
    const run_fuzz_gc_stress = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_fuzz_gc_stress.addArtifactArg(fuzz_gc_stress_exe);

    // ── Native test runner (replaces bash scripts) ────────────────────────────

    const test_runner_mod = b.createModule(.{
        .root_source_file = b.path("tools/test_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    test_runner_mod.link_libc = true;
    const test_runner_exe = b.addExecutable(.{ .name = "test-runner", .root_module = test_runner_mod });

    // ── Conformance ───────────────────────────────────────────────────────────

    const run_conformance = b.addRunArtifact(test_runner_exe);
    run_conformance.step.dependOn(&install_test.step);
    run_conformance.addArg("conformance");
    run_conformance.addArg(wasmtime_opt);
    run_conformance.addArg("build/test/gengo-cli.wasm");

    const run_conformance_release = b.addRunArtifact(test_runner_exe);
    run_conformance_release.step.dependOn(&install_test.step);
    run_conformance_release.addArg("conformance");
    run_conformance_release.addArg(wasmtime_opt);
    run_conformance_release.addArg("build/test/gengo-cli.wasm");

    const run_conformance_artifact = b.addRunArtifact(test_runner_exe);
    run_conformance_artifact.addArg("conformance");
    run_conformance_artifact.addArg(wasmtime_opt);
    run_conformance_artifact.addArg(conformance_wasm_opt orelse "build/test/gengo-cli.wasm");

    // ── Named steps ───────────────────────────────────────────────────────────

    const wasi_step = b.step("wasi", "Build WASI runtime (Debug)");
    wasi_step.dependOn(&install_debug.step);

    const wasi_release_step = b.step("wasi-release", "Build WASI runtime (ReleaseFast)");
    wasi_release_step.dependOn(&install_release.step);

    const conformance_release_step = b.step("conformance-release", "Run conformance tests against the ReleaseFast WASI runtime");
    conformance_release_step.dependOn(&run_conformance_release.step);

    const conformance_artifact_step = b.step("conformance-artifact", "Run conformance tests against -Dconformance_wasm");
    conformance_artifact_step.dependOn(&run_conformance_artifact.step);

    const engine_build_step = b.step("engine-build", "Build engine WASM module (Debug)");
    engine_build_step.dependOn(&install_engine_debug.step);

    const engine_release_step = b.step("engine-release", "Build engine WASM module (ReleaseFast)");
    engine_release_step.dependOn(&install_engine_release.step);

    // ── Named WASM release artifacts (compile-time capability gating) ─────────

    const cap_combo = b.step("engine-release-full", "Build engine with net+http+fs (ReleaseFast)");
    cap_combo.dependOn(&install_engine_release.step);

    const net_http_opts = b.addOptions();
    net_http_opts.addOption(bool, "perf", perf_opt);
    net_http_opts.addOption(bool, "gc_stress", false);
    net_http_opts.addOption(bool, "heap_paranoia", false);
    net_http_opts.addOption(bool, "cap_net", true);
    net_http_opts.addOption(bool, "cap_http", true);
    net_http_opts.addOption(bool, "cap_fs", false);
    net_http_opts.addOption(bool, "cap_env", false);
    net_http_opts.addOption(bool, "predicates", predicates_opt);
    net_http_opts.addOption(bool, "gengo_host", true);
    net_http_opts.addOption([]const u8, "version", gengo_version);
    const net_http_opts_mod = net_http_opts.createModule();
    const engine_net_http = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, net_http_opts_mod, runtime_config_mod);
    const install_engine_net_http = installWasmAs(b, engine_net_http, wasmArtifactPath("release", "gengo-engine-net.wasm"));
    const net_http_step = b.step("engine-release-net", "Build engine with net+http (ReleaseFast)");
    net_http_step.dependOn(&install_engine_net_http.step);

    const fs_opts = b.addOptions();
    fs_opts.addOption(bool, "perf", perf_opt);
    fs_opts.addOption(bool, "gc_stress", false);
    fs_opts.addOption(bool, "heap_paranoia", false);
    fs_opts.addOption(bool, "cap_net", false);
    fs_opts.addOption(bool, "cap_http", false);
    fs_opts.addOption(bool, "cap_fs", true);
    fs_opts.addOption(bool, "cap_env", false);
    fs_opts.addOption(bool, "predicates", predicates_opt);
    fs_opts.addOption(bool, "gengo_host", true);
    fs_opts.addOption([]const u8, "version", gengo_version);
    const fs_opts_mod = fs_opts.createModule();
    const engine_fs = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, fs_opts_mod, runtime_config_mod);
    const install_engine_fs = installWasmAs(b, engine_fs, wasmArtifactPath("release", "gengo-engine-fs.wasm"));
    const fs_step = b.step("engine-release-fs", "Build engine with fs only (ReleaseFast)");
    fs_step.dependOn(&install_engine_fs.step);

    const minimal_opts = b.addOptions();
    minimal_opts.addOption(bool, "perf", perf_opt);
    minimal_opts.addOption(bool, "gc_stress", false);
    minimal_opts.addOption(bool, "heap_paranoia", false);
    minimal_opts.addOption(bool, "cap_net", false);
    minimal_opts.addOption(bool, "cap_http", false);
    minimal_opts.addOption(bool, "cap_fs", false);
    minimal_opts.addOption(bool, "cap_env", false);
    minimal_opts.addOption(bool, "cap_ffi", false);
    minimal_opts.addOption(bool, "predicates", predicates_opt);
    minimal_opts.addOption(bool, "gengo_host", false);
    minimal_opts.addOption([]const u8, "version", gengo_version);
    const minimal_opts_mod = minimal_opts.createModule();
    const engine_minimal = addWasmExe(b, "gengo-engine", "src/engine.zig", wasm_target, .ReleaseFast, minimal_opts_mod, runtime_config_mod);
    const install_engine_minimal = installWasmAs(b, engine_minimal, wasmArtifactPath("release", "gengo-engine-minimal.wasm"));
    const minimal_step = b.step("engine-release-minimal", "Build engine with no capabilities (ReleaseFast)");
    minimal_step.dependOn(&install_engine_minimal.step);

    // ── Engine (native shared library for host embedding) ──────────────────────

    const native_target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });

    const engine_native_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = native_target,
        .optimize = .Debug,
    });
    engine_native_mod.addImport("build_options", build_opts_mod);
    engine_native_mod.addImport("runtime_config", runtime_config_mod);
    const engine_native = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gengo-engine",
        .root_module = engine_native_mod,
    });
    const install_engine_native = b.addInstallArtifact(engine_native, .{});

    const engine_native_release_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    engine_native_release_mod.addImport("build_options", build_opts_mod);
    engine_native_release_mod.addImport("runtime_config", runtime_config_mod);
    const engine_native_release = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gengo-engine",
        .root_module = engine_native_release_mod,
    });
    const install_engine_native_release = b.addInstallArtifact(engine_native_release, .{});

    const engine_native_step = b.step("engine-native", "Build native shared library (Debug)");
    engine_native_step.dependOn(&install_engine_native.step);

    const engine_native_release_step = b.step("engine-native-release", "Build native shared library (ReleaseFast)");
    engine_native_release_step.dependOn(&install_engine_native_release.step);

    // ── Lexer unit tests (native Zig test runner) ─────────────────────────────

    const lexer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lang/lexer.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lexer_test = b.addTest(.{ .root_module = lexer_test_mod });
    const run_lexer_tests = b.addRunArtifact(lexer_test);

    const lexer_test_step = b.step("lexer-test", "Run lexer unit tests");
    lexer_test_step.dependOn(&run_lexer_tests.step);

    const build_test_mod = b.createModule(.{
        .root_source_file = b.path("build_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const build_test = b.addTest(.{ .root_module = build_test_mod });
    const run_build_tests = b.addRunArtifact(build_test);

    const build_test_step = b.step("build-test", "Run build graph contract tests");
    build_test_step.dependOn(&run_build_tests.step);

    const engine_api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    engine_api_test_mod.addImport("build_options", build_opts_mod);
    engine_api_test_mod.addImport("runtime_config", runtime_config_mod);
    const engine_api_test = b.addTest(.{ .root_module = engine_api_test_mod });
    const run_engine_api_tests = b.addRunArtifact(engine_api_test);

    const engine_api_test_step = b.step("engine-api-test", "Run native engine C API tests");
    engine_api_test_step.dependOn(&run_engine_api_tests.step);

    // ── Heap / GC unit tests (native Zig test runner) ─────────────────────────
    // Uses a wrapper root at src/ so that runtime/heap.zig can import ../lang/value.zig.

    const heap_test_mod = b.createModule(.{
        .root_source_file = b.path("src/heap_test_root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    heap_test_mod.addImport("build_options", build_opts_mod);
    heap_test_mod.addImport("runtime_config", runtime_config_mod);
    const heap_test = b.addTest(.{ .root_module = heap_test_mod });
    const run_heap_tests = b.addRunArtifact(heap_test);

    const heap_test_step = b.step("heap-test", "Run heap and GC invariant tests");
    heap_test_step.dependOn(&run_heap_tests.step);

    // ── Compiler unit tests (native Zig test runner) ──────────────────────────

    const compiler_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    compiler_test_mod.addImport("build_options", build_opts_mod);
    compiler_test_mod.addImport("runtime_config", runtime_config_mod);
    const compiler_test = b.addTest(.{ .root_module = compiler_test_mod });
    const run_compiler_tests = b.addRunArtifact(compiler_test);

    const compiler_test_step = b.step("compiler-test", "Run compiler bytecode output tests");
    compiler_test_step.dependOn(&run_compiler_tests.step);

    // ── Long-lived embedding fragmentation harness tests ────────────────────

    const embedding_frag_test_mod = b.createModule(.{
        .root_source_file = b.path("src/embedding_fragmentation_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    embedding_frag_test_mod.addImport("build_options", build_opts_mod);
    embedding_frag_test_mod.addImport("runtime_config", runtime_config_mod);
    const embedding_frag_test = b.addTest(.{ .root_module = embedding_frag_test_mod });
    const run_embedding_frag_tests = b.addRunArtifact(embedding_frag_test);

    const embedding_frag_test_step = b.step("embedding-frag-test", "Run long-lived embedding fragmentation harness tests");
    embedding_frag_test_step.dependOn(&run_embedding_frag_tests.step);

    // ── Chaos / spec-fail in-process tests (native Zig test runner) ───────────

    const chaos_spec_test_mod = b.createModule(.{
        .root_source_file = b.path("src/chaos_spec_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    chaos_spec_test_mod.addImport("build_options", build_opts_mod);
    chaos_spec_test_mod.addImport("runtime_config", runtime_config_mod);
    const chaos_spec_test = b.addTest(.{ .root_module = chaos_spec_test_mod });
    const run_chaos_spec_tests = b.addRunArtifact(chaos_spec_test);

    const chaos_spec_test_step = b.step("chaos-spec-test", "Run chaos and spec/fail cases in-process");
    chaos_spec_test_step.dependOn(&run_chaos_spec_tests.step);

    const unit_step = b.step("unit", "Run VM safety, value, embedding, and engine API checks");
    unit_step.dependOn(&run_vm_safety.step);
    unit_step.dependOn(&run_vm_value.step);
    unit_step.dependOn(&run_embedding.step);
    unit_step.dependOn(&run_engine_runner.step);

    const test_step = b.step("test", "Run heap, compiler, lexer, runtime safety, value, embedding, engine, fuzz, and conformance tests");
    test_step.dependOn(&run_heap_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_embedding_frag_tests.step);
    test_step.dependOn(&run_chaos_spec_tests.step);
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_build_tests.step);
    test_step.dependOn(&run_vm_safety.step);
    test_step.dependOn(&run_vm_value.step);
    test_step.dependOn(&run_embedding.step);
    test_step.dependOn(&run_engine_runner.step);
    test_step.dependOn(&run_fuzz_runner.step);
    test_step.dependOn(&install_engine_debug.step);
    test_step.dependOn(&run_conformance.step);

    const run_bench = b.addRunArtifact(test_runner_exe);
    run_bench.step.dependOn(&install_test.step);
    run_bench.addArg("bench");
    run_bench.addArg(wasmtime_opt);
    run_bench.addArg("build/test/gengo-cli.wasm");
    const bench_step = b.step("bench", "Run benchmark suite");
    bench_step.dependOn(&run_bench.step);

    const run_bench_release = b.addRunArtifact(test_runner_exe);
    run_bench_release.step.dependOn(&install_release.step);
    run_bench_release.addArg("bench");
    run_bench_release.addArg(wasmtime_opt);
    run_bench_release.addArg("build/release/gengo-cli.wasm");
    const bench_release_step = b.step("bench-release", "Run benchmark suite (ReleaseFast)");
    bench_release_step.dependOn(&run_bench_release.step);

    // bench-perf: perf-instrumented build; outputs PERF: lines to stderr.
    // ReleaseSafe, not Debug: an unoptimized runInner (256-way opcode switch)
    // now emits enough per-arm locals that wasmtime's translator rejects the
    // module ("too many locals"). ReleaseSafe keeps every safety check Debug
    // has (bounds/overflow checks, no UB-triggered miscounting) while running
    // mem2reg/register allocation, so PERF: counters stay deterministic.
    const perf_opts = b.addOptions();
    perf_opts.addOption(bool, "perf", true);
    perf_opts.addOption(bool, "gc_stress", gc_stress_opt);
    perf_opts.addOption(bool, "heap_paranoia", false);
    perf_opts.addOption(bool, "cap_net", cap_net_opt);
    perf_opts.addOption(bool, "cap_http", cap_http_opt);
    perf_opts.addOption(bool, "cap_fs", cap_fs_opt);
    perf_opts.addOption(bool, "cap_env", cap_env_opt);
    perf_opts.addOption(bool, "cap_ffi", false);
    perf_opts.addOption(bool, "predicates", predicates_opt);
    perf_opts.addOption(bool, "gengo_host", gengo_host_opt);
    perf_opts.addOption([]const u8, "version", gengo_version);
    const perf_opts_mod = perf_opts.createModule();
    const gengo_perf = addWasmExe(b, "gengo-perf", "src/main.zig", wasm_target, .ReleaseSafe, perf_opts_mod, runtime_config_mod);
    const install_perf = installWasmAs(b, gengo_perf, wasmArtifactPath("debug", "gengo-perf.wasm"));

    const bench_perf_runner_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_perf_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    bench_perf_runner_mod.link_libc = true;
    const bench_perf_runner_exe = b.addExecutable(.{ .name = "bench-perf-runner", .root_module = bench_perf_runner_mod });
    const run_bench_perf = b.addRunArtifact(bench_perf_runner_exe);
    run_bench_perf.step.dependOn(&install_perf.step);
    run_bench_perf.addArg(wasmtime_opt);
    run_bench_perf.addArg("build/debug/gengo-perf.wasm");
    const bench_perf_step = b.step("bench-perf", "Run benchmarks with perf counters (PERF: lines on stderr)");
    bench_perf_step.dependOn(&run_bench_perf.step);

    const fuzz_step = b.step("fuzz", "Run fuzz tests (compiler, VM, and boundary inputs)");
    fuzz_step.dependOn(&run_fuzz_runner.step);

    // Native fuzz lane: same corpus, native codegen — the unchecked stack
    // ops, proof flags, and fused handlers only exist as native machine code,
    // and wasmtime throttles iteration throughput besides.
    const fuzz_native_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    fuzz_native_mod.addImport("build_options", build_opts_mod);
    fuzz_native_mod.addImport("runtime_config", runtime_config_mod);
    fuzz_native_mod.link_libc = true;
    const fuzz_native_exe = b.addExecutable(.{ .name = "fuzz-runner-native", .root_module = fuzz_native_mod });
    const run_fuzz_native = b.addRunArtifact(fuzz_native_exe);
    const fuzz_native_step = b.step("fuzz-native", "Run fuzz tests natively (native codegen paths)");
    fuzz_native_step.dependOn(&run_fuzz_native.step);

    // Native builds of the hand-assembled-bytecode runners: their signal is
    // target-independent VM semantics, so they gate the native codegen too.
    const vm_value_native_mod = b.createModule(.{
        .root_source_file = b.path("src/vm_value_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    vm_value_native_mod.addImport("build_options", build_opts_mod);
    vm_value_native_mod.addImport("runtime_config", runtime_config_mod);
    vm_value_native_mod.link_libc = true;
    const vm_value_native_exe = b.addExecutable(.{ .name = "vm-value-runner-native", .root_module = vm_value_native_mod });
    const run_vm_value_native = b.addRunArtifact(vm_value_native_exe);

    const vm_safety_native_mod = b.createModule(.{
        .root_source_file = b.path("src/vm_safety_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    vm_safety_native_mod.addImport("build_options", build_opts_mod);
    vm_safety_native_mod.addImport("runtime_config", runtime_config_mod);
    vm_safety_native_mod.link_libc = true;
    const vm_safety_native_exe = b.addExecutable(.{ .name = "vm-safety-runner-native", .root_module = vm_safety_native_mod });
    const run_vm_safety_native = b.addRunArtifact(vm_safety_native_exe);

    const vm_native_step = b.step("vm-native", "Run VM value/safety runners natively");
    vm_native_step.dependOn(&run_vm_value_native.step);
    vm_native_step.dependOn(&run_vm_safety_native.step);
    // Part of the main test gate: their semantics are target-independent,
    // so they must hold on native codegen too.
    test_step.dependOn(&run_vm_value_native.step);
    test_step.dependOn(&run_vm_safety_native.step);

    const fuzz_gc_stress_step = b.step("fuzz-gc-stress", "Run fuzz tests under gc_stress (GC on every allocation)");
    fuzz_gc_stress_step.dependOn(&run_fuzz_gc_stress.step);

    // ── Native CLI ────────────────────────────────────────────────────────────

    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .Debug,
    });
    native_mod.addImport("build_options", native_cli_opts_mod);
    native_mod.addImport("runtime_config", runtime_config_mod);
    native_mod.link_libc = true;
    const native_exe = b.addExecutable(.{ .name = "gengo", .root_module = native_mod });
    const install_native = b.addInstallArtifact(native_exe, .{});

    b.getInstallStep().dependOn(&install_native.step);
    const cli_step = b.step("cli", "Build native CLI binary (zig-out/bin/gengo)");
    cli_step.dependOn(&install_native.step);

    // Shared library the tests/native-cap cap:ffi cases dlopen through
    // ffi.load. Written in C and built with the same Zig toolchain used for
    // the CLI: a plain, libc-free .so loads reliably into Gengo's
    // statically-linked native CLI, whereas Zig-built shared objects have
    // TLS/runtime-init interactions with the static musl binary that can
    // corrupt the library at load time.
    const build_ffi_test_lib = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-shared", "-fPIC", "-target", "x86_64-linux-musl", "-nostdlib", "-fno-sanitize=all", "-Wl,-soname,libgengo_ffi_test.so", "-o" });
    build_ffi_test_lib.addFileArg(b.path("zig-out/lib/libgengo_ffi_test.so"));
    build_ffi_test_lib.addFileArg(b.path("tools/ffi_test_lib.c"));
    const run_native_cap = b.addRunArtifact(test_runner_exe);
    run_native_cap.step.dependOn(&install_native.step);
    run_native_cap.step.dependOn(&build_ffi_test_lib.step);
    run_native_cap.addArg("native-cap");
    run_native_cap.addArg("zig-out/bin/gengo");
    if (test_filter_opt) |f| {
        run_native_cap.addArg("--filter");
        run_native_cap.addArg(f);
    }
    const native_cap_step = b.step("native-cap", "Run native capability tests against the CLI");
    native_cap_step.dependOn(&run_native_cap.step);

    const embedding_frag_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/embedding_fragmentation_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    embedding_frag_runner_mod.addImport("build_options", build_opts_mod);
    embedding_frag_runner_mod.addImport("runtime_config", runtime_config_mod);
    const embedding_frag_runner = b.addExecutable(.{
        .name = "embedding-frag-runner",
        .root_module = embedding_frag_runner_mod,
    });
    const run_embedding_frag = b.addRunArtifact(embedding_frag_runner);
    if (b.args) |args| run_embedding_frag.addArgs(args);
    const embedding_frag_step = b.step("embedding-frag", "Run the long-lived embedding fragmentation harness");
    embedding_frag_step.dependOn(&run_embedding_frag.step);

    const run_chaos = b.addRunArtifact(test_runner_exe);
    run_chaos.step.dependOn(&install_native.step);
    run_chaos.addArg("chaos");
    run_chaos.addArg("zig-out/bin/gengo");
    if (test_filter_opt) |f| {
        run_chaos.addArg("--filter");
        run_chaos.addArg(f);
    }
    const chaos_step = b.step("chaos", "Run limit/edge-case chaos tests against the CLI");
    chaos_step.dependOn(&run_chaos.step);

    const run_native = b.addRunArtifact(native_exe);
    if (b.args) |args| run_native.addArgs(args);
    const run_step = b.step("run", "Run a script with the native CLI (-- script.gengo)");
    run_step.dependOn(&run_native.step);

    const native_release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .ReleaseSafe,
    });
    native_release_mod.addImport("build_options", native_cli_opts_mod);
    native_release_mod.addImport("runtime_config", runtime_config_mod);
    native_release_mod.link_libc = true;
    const native_release_exe = b.addExecutable(.{ .name = "gengo", .root_module = native_release_mod });
    const install_native_release = b.addInstallArtifact(native_release_exe, .{});

    const cli_release_step = b.step("cli-release", "Build native CLI binary (ReleaseSafe)");
    cli_release_step.dependOn(&install_native_release.step);

    const native_fast_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    native_fast_mod.addImport("build_options", native_cli_opts_mod);
    native_fast_mod.addImport("runtime_config", runtime_config_mod);
    native_fast_mod.link_libc = true;
    const native_fast_exe = b.addExecutable(.{ .name = "gengo-fast", .root_module = native_fast_mod });
    const install_native_fast = b.addInstallArtifact(native_fast_exe, .{});
    const cli_fast_step = b.step("cli-fast", "Build native CLI binary (ReleaseFast, for timing benchmarks)");
    cli_fast_step.dependOn(&install_native_fast.step);

    const native_small_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    native_small_mod.addImport("build_options", native_cli_opts_mod);
    native_small_mod.addImport("runtime_config", runtime_config_mod);
    native_small_mod.link_libc = true;
    const native_small_exe = b.addExecutable(.{ .name = "gengo", .root_module = native_small_mod });
    const install_native_small = b.addInstallArtifact(native_small_exe, .{});
    const cli_small_step = b.step("cli-small", "Build native CLI binary (ReleaseSmall + strip, smallest binary)");
    cli_small_step.dependOn(&install_native_small.step);

    // ── Native embed example ──────────────────────────────────────────────────

    const gengo_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    gengo_mod.addImport("build_options", build_opts_mod);
    gengo_mod.addImport("runtime_config", runtime_config_mod);
    const host_embed_mod = b.createModule(.{
        .root_source_file = b.path("examples/embed-host/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_embed_mod.addImport("gengo", gengo_mod);
    const host_embed_exe = b.addExecutable(.{
        .name = "embed-host-example",
        .root_module = host_embed_mod,
    });
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
    opts_mod: *std.Build.Module,
    runtime_config_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("build_options", opts_mod);
    mod.addImport("runtime_config", runtime_config_mod);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.stack_size = 4 * 1024 * 1024;
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
    const step = b.addSystemCommand(&.{ "bash", "-c", "mkdir -p \"build/$(dirname \"$2\")\" && cp \"$1\" \"build/$2\"", "--" });
    step.addFileArg(exe.getEmittedBin());
    step.addArg(dest_name);
    return step;
}

fn installOptimizedWasm(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    dest_name: []const u8,
) *std.Build.Step.Run {
    const step = b.addSystemCommand(&.{ "bash", "-c", "mkdir -p \"build/$(dirname \"$2\")\" && cp \"$1\" \"build/$2\" && wasm-opt -O3 --strip-debug \"build/$2\" -o \"build/$2\"", "--" });
    step.addFileArg(exe.getEmittedBin());
    step.addArg(dest_name);
    return step;
}
