const builtin = @import("builtin");
comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @compileError("heap_test is native-only");
    }
}
const _ = @import("runtime/heap_test.zig");
