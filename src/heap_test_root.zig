const builtin = @import("builtin");
comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @compileError("heap_test is native-only");
    }
}
test {
    _ = @import("runtime/heap_test.zig");
}
