const native_main = @import("native/main.zig");
const native_core = @import("native/core.zig");

pub const callNative = native_main.callNative;
pub const installStdGlobal = native_main.installStdGlobal;
pub const nativeConvToString = native_core.nativeConvToString;
