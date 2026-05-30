const std = @import("std");

pub fn build(b: *std.Build) void {
    const preset_opt = b.option([]const u8, "preset", "runtime preset: dev|tiny|stress") orelse "dev";
    const valid = std.mem.eql(u8, preset_opt, "dev") or
        std.mem.eql(u8, preset_opt, "tiny") or
        std.mem.eql(u8, preset_opt, "stress");
    if (!valid) @panic("invalid -Dpreset, expected dev|tiny|stress");

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

    const gengo_debug = addWasmExe(b, "gengo-test", "src/main.zig", wasm_target, .Debug, &preset.step);
    const gengo_release = addWasmExe(b, "gengo-test", "src/main.zig", wasm_target, .ReleaseFast, &preset.step);

    const install_debug = installWasm(b, gengo_debug, "gengo-test.wasm");
    const install_release = installWasm(b, gengo_release, "gengo-test.wasm");

    // ── Test runners (build + run immediately, no permanent artifact) ─────────

    const vm_safety_exe = addWasmExe(b, "vm-safety-runner", "src/vm_safety_runner.zig", wasm_target, .Debug, &preset.step);
    const run_vm_safety = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_vm_safety.addArtifactArg(vm_safety_exe);

    const embedding_exe = addWasmExe(b, "embedding-runner", "src/embedding_runner.zig", wasm_target, .Debug, &preset.step);
    const run_embedding = b.addSystemCommand(&.{ wasmtime_opt, "--dir", "/" });
    run_embedding.addArtifactArg(embedding_exe);

    // ── Conformance ───────────────────────────────────────────────────────────

    const conformance = b.addSystemCommand(&.{ "bash", "./tests/run_conformance.sh" });
    conformance.step.dependOn(&install_debug.step);
    conformance.setEnvironmentVariable("WASMTIME_BIN", wasmtime_opt);

    // ── Named steps ───────────────────────────────────────────────────────────

    const wasi_step = b.step("wasi", "Build WASI runtime (Debug)");
    wasi_step.dependOn(&install_debug.step);

    const wasi_release_step = b.step("wasi-release", "Build WASI runtime (ReleaseFast)");
    wasi_release_step.dependOn(&install_release.step);

    const unit_step = b.step("unit", "Run VM safety and embedding API checks");
    unit_step.dependOn(&run_vm_safety.step);
    unit_step.dependOn(&run_embedding.step);

    const test_step = b.step("test", "Run runtime safety, embedding API, and conformance tests");
    test_step.dependOn(&run_vm_safety.step);
    test_step.dependOn(&run_embedding.step);
    test_step.dependOn(&conformance.step);

    const bench = scriptStep(b, "bash", "./tests/run_bench.sh", &install_debug.step, wasmtime_opt);
    const bench_step = b.step("bench", "Run benchmark suite");
    bench_step.dependOn(&bench.step);

    const bench_release = scriptStep(b, "bash", "./tests/run_bench.sh", &install_release.step, wasmtime_opt);
    const bench_release_step = b.step("bench-release", "Run benchmark suite (ReleaseFast)");
    bench_release_step.dependOn(&bench_release.step);

    const parity = scriptStep(b, "bash", "./tests/run_host_parity.sh", &install_debug.step, wasmtime_opt);
    const parity_step = b.step("parity", "Run host/embedded parity tests");
    parity_step.dependOn(&parity.step);

    // ── Native CLI ────────────────────────────────────────────────────────────

    const optimize = b.standardOptimizeOption(.{});
    const native_exe = b.addExecutable(.{
        .name = "gengo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    native_exe.step.dependOn(&preset.step);
    const install_native = b.addInstallArtifact(native_exe, .{});

    const cli_step = b.step("cli", "Build native CLI binary (zig-out/bin/gengo)");
    cli_step.dependOn(&install_native.step);

    const run_native = b.addRunArtifact(native_exe);
    if (b.args) |args| run_native.addArgs(args);
    const run_step = b.step("run", "Run a script with the native CLI (-- script.gengo)");
    run_step.dependOn(&run_native.step);

    // ── Native embed example ──────────────────────────────────────────────────

    const host_embed_mod = b.createModule(.{
        .root_source_file = b.path("src/embed_host_example.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
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
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.step.dependOn(depends_on);
    return exe;
}

fn installWasm(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    dest_name: []const u8,
) *std.Build.Step.Run {
    const step = b.addSystemCommand(&.{ "bash", "-c", "mkdir -p build && cp \"$1\" \"build/$2\"", "--" });
    step.addFileArg(exe.getEmittedBin());
    step.addArg(dest_name);
    return step;
}

fn scriptStep(
    b: *std.Build,
    shell: []const u8,
    script: []const u8,
    depends_on: *std.Build.Step,
    wasmtime: []const u8,
) *std.Build.Step.Run {
    const step = b.addSystemCommand(&.{ shell, script });
    step.step.dependOn(depends_on);
    step.setEnvironmentVariable("WASMTIME_BIN", wasmtime);
    return step;
}
