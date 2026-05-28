const std = @import("std");

fn makePresetStep(b: *std.Build, preset: []const u8) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{
        "bash",
        "-lc",
        b.fmt("cp runtime/config_{s}.zig runtime/config.zig && echo \"Applied gengo config preset: {s}\"", .{ preset, preset }),
    });
    return cmd;
}

fn makeWasiBuildStep(
    b: *std.Build,
    name: []const u8,
    optimize: []const u8,
    out_name: []const u8,
    root: []const u8,
    depends_on: ?*std.Build.Step.Run,
) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{
        "bash",
        "-lc",
        b.fmt(
            \\set -eu
            \\ZIG="${{ZIG:-zig}}"
            \\ZIG_GLOBAL_CACHE_DIR="${{ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache}}"
            \\ZIG_LOCAL_CACHE_DIR="${{ZIG_LOCAL_CACHE_DIR:-/tmp/zig-local-cache}}"
            \\"$ZIG" build-exe \
            \\  -target wasm32-wasi \
            \\  -fno-entry -rdynamic \
            \\  -O {s} \
            \\  -Mroot="{s}" \
            \\  -femit-bin="{s}"
            \\echo "Built {s}"
            ,
            .{ optimize, root, out_name, out_name },
        ),
    });
    if (depends_on) |d| cmd.step.dependOn(&d.step);
    _ = name;
    return cmd;
}

fn makeWasiRunnerStep(
    b: *std.Build,
    root: []const u8,
    out_name: []const u8,
    depends_on: ?*std.Build.Step.Run,
) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{
        "bash",
        "-lc",
        b.fmt(
            \\set -eu
            \\ZIG="${{ZIG:-zig}}"
            \\WASMTIME_BIN="${{WASMTIME_BIN:-wasmtime}}"
            \\ZIG_GLOBAL_CACHE_DIR="${{ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache}}"
            \\ZIG_LOCAL_CACHE_DIR="${{ZIG_LOCAL_CACHE_DIR:-/tmp/zig-local-cache}}"
            \\"$ZIG" build-exe \
            \\  -target wasm32-wasi \
            \\  -fno-entry -rdynamic \
            \\  -O Debug \
            \\  -Mroot="{s}" \
            \\  -femit-bin="{s}"
            \\"$WASMTIME_BIN" --dir / ./"{s}"
            ,
            .{ root, out_name, out_name },
        ),
    });
    if (depends_on) |d| cmd.step.dependOn(&d.step);
    return cmd;
}

pub fn build(b: *std.Build) void {
    const preset_opt = b.option([]const u8, "preset", "runtime preset: dev|tiny|stress") orelse "dev";
    const valid = std.mem.eql(u8, preset_opt, "dev") or std.mem.eql(u8, preset_opt, "tiny") or std.mem.eql(u8, preset_opt, "stress");
    if (!valid) @panic("invalid --preset, expected dev|tiny|stress");

    const preset = makePresetStep(b, preset_opt);
    const wasi = makeWasiBuildStep(b, "wasi", "Debug", "gengo-test.wasm", "main.zig", preset);
    const wasi_release = makeWasiBuildStep(b, "wasi-release", "ReleaseFast", "gengo-test.wasm", "main.zig", preset);
    const vm_safety = makeWasiRunnerStep(b, "vm_safety_runner.zig", "vm-safety.wasm", preset);
    const embedding = makeWasiRunnerStep(b, "embedding_runner.zig", "embedding.wasm", preset);

    const conformance = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "./tests/run_conformance.sh",
    });
    conformance.step.dependOn(&wasi.step);

    const test_step = b.step("test", "Run runtime safety, embedding API, and conformance tests");
    test_step.dependOn(&vm_safety.step);
    test_step.dependOn(&embedding.step);
    test_step.dependOn(&conformance.step);

    const bench = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "./tests/run_bench.sh",
    });
    bench.step.dependOn(&wasi.step);
    const bench_step = b.step("bench", "Run benchmark suite");
    bench_step.dependOn(&bench.step);

    const bench_release = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "./tests/run_bench.sh",
    });
    bench_release.step.dependOn(&wasi_release.step);
    const bench_release_step = b.step("bench-release", "Run benchmark suite with ReleaseFast runtime");
    bench_release_step.dependOn(&bench_release.step);

    const parity = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "./tests/run_host_parity.sh",
    });
    parity.step.dependOn(&wasi.step);
    const parity_step = b.step("parity", "Run host/embedded parity tests");
    parity_step.dependOn(&parity.step);

    const wasi_step = b.step("wasi", "Build WASI runtime (Debug)");
    wasi_step.dependOn(&wasi.step);

    const wasi_release_step = b.step("wasi-release", "Build WASI runtime (ReleaseFast)");
    wasi_release_step.dependOn(&wasi_release.step);

    const unit_step = b.step("unit", "Run VM safety and embedding API checks");
    unit_step.dependOn(&vm_safety.step);
    unit_step.dependOn(&embedding.step);

    const host_embed = b.addSystemCommand(&.{
        "bash",
        "-lc",
        \\set -eu
        \\ZIG="${ZIG:-zig}"
        \\ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache}"
        \\ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-/tmp/zig-local-cache}"
        \\"$ZIG" build-exe -O Debug -Mroot="embed_host_example.zig" -femit-bin="embed-host-example"
        \\./embed-host-example
        ,
    });
    host_embed.step.dependOn(&preset.step);
    const embed_example_step = b.step("embed-example", "Build and run native host embedding example");
    embed_example_step.dependOn(&host_embed.step);
}
