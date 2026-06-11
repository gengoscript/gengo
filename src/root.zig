//! Public Zig embedding surface for gengo.
//!
//! Out-of-tree consumers (and examples/embed-host) import this as the
//! `gengo` module. Everything else under src/ is internal; white-box
//! test harness roots that poke internals must live directly in src/
//! because a Zig module root cannot import files outside its own
//! directory tree.

pub const api = @import("runtime/api.zig");
pub const Value = @import("lang/value.zig").Value;
