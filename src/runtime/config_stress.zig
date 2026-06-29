// stress: deliberately tight limits to exercise boundary conditions in CI.
// Small heap forces frequent GC; small stack/frame limits hit overflow paths
// that the 1m preset never reaches in normal use.
pub const heap_size_bytes: usize = 256 * 1024;
pub const max_objects: usize = 512;
pub const max_stack: usize = 128;
pub const max_frames: usize = 16;
pub const max_input_bytes: usize = 32 * 1024;
pub const max_defers: usize = 32;
pub const gc_object_step: usize = 32;
