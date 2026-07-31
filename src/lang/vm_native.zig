const native_main = @import("native/main.zig");
const native_core = @import("native/core.zig");
const native_bytes = @import("native/bytes.zig");

pub const callNative = native_main.callNative;
pub const callHostModule = native_main.callHostModule;
pub const installStdGlobal = native_main.installStdGlobal;
pub const installHostModules = native_main.installHostModules;
pub const installCapabilityModules = native_main.installCapabilityModules;
pub const tryCallFfiCallable = native_main.tryCallFfiCallable;
pub const nativeConvToString = native_core.nativeConvToString;
pub const nativeTypeNameValue = native_core.nativeTypeNameValue;
pub const nativeLen = native_core.nativeLen;
pub const nativeAppend = native_core.nativeAppend;
pub const nativeByteLen = native_core.nativeByteLen;
pub const BytesDecodeKind = native_bytes.DecodeKind;
pub const bytesDecodeAt = native_bytes.decodeAt;
