const std = @import("std");
const build = @import("build.zig");

test "each supported preset resolves to its configuration source" {
    try std.testing.expectEqualStrings("src/runtime/config_256k.zig", build.presetConfigPath("256k").?);
    try std.testing.expectEqualStrings("src/runtime/config_1m.zig", build.presetConfigPath("1m").?);
    try std.testing.expectEqualStrings("src/runtime/config_16m.zig", build.presetConfigPath("16m").?);
    try std.testing.expectEqualStrings("src/runtime/config_unlimited.zig", build.presetConfigPath("unlimited").?);
    try std.testing.expectEqualStrings("src/runtime/config_dev.zig", build.presetConfigPath("dev").?);
    try std.testing.expectEqualStrings("src/runtime/config_stress.zig", build.presetConfigPath("stress").?);
}

test "artifact paths keep build modes separate" {
    try std.testing.expectEqualStrings("debug/gengo-cli.wasm", build.wasmArtifactPath("debug", "gengo-cli.wasm"));
    try std.testing.expectEqualStrings("test/gengo-cli.wasm", build.wasmArtifactPath("test", "gengo-cli.wasm"));
    try std.testing.expectEqualStrings("release/gengo-cli.wasm", build.wasmArtifactPath("release", "gengo-cli.wasm"));
    try std.testing.expectEqualStrings("release/gengo-engine-minimal.wasm", build.wasmArtifactPath("release", "gengo-engine-minimal.wasm"));
}
