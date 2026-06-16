const native_main = @import("native/main.zig");
const native_core = @import("native/core.zig");

pub const callNative = native_main.callNative;
pub const callHostModule = native_main.callHostModule;
pub const installStdGlobal = native_main.installStdGlobal;
pub const installHostModules = native_main.installHostModules;
pub const installCapabilityModules = native_main.installCapabilityModules;
pub const nativeConvToString = native_core.nativeConvToString;
pub const nativeTypeNameValue = native_core.nativeTypeNameValue;
