//! cap:ffi — load shared libraries and call arbitrary C functions.
//!
//! Native CLI only (build_options.cap_ffi is true solely in the native CLI,
//! see build.zig's native_cli_opts). Requires --cap ffi at runtime. This is
//! the highest-trust capability: a script can call any exported symbol in any
//! library it can name, and a wrong declaration can crash the process. See
//! docs/capabilities.md.
//!
//! Calling convention is handled by hand-rolled SysV trampolines (x86_64 and
//! aarch64). libffi is deliberately not used so the CLI keeps zero external
//! build dependencies. v1 supports scalar, float, cstring, and pointer args
//! and returns — no struct-by-value, no variadics.

const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const vmtyp = @import("../vm_types.zig");
const vmod = @import("../value.zig");
const Value = vmod.Value;
const Object = vmod.Object;
const MapEntry = vmod.MapEntry;
const NativeFnId = @import("native_ids.zig").NativeFnId;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;

pub const LibQualifiedName = "@cap_type:ffi.Lib";
pub const CallableQualifiedName = "@cap_type:ffi.Callable";
pub const BufQualifiedName = "@cap_type:ffi.Buf";

// Type descriptor codes exposed as ffi.types.* in script. Keep in sync with
// the installFfiModule type namespace in native/main.zig.
pub const TypeVoid: u8 = 0;
pub const TypeI8: u8 = 1;
pub const TypeU8: u8 = 2;
pub const TypeI16: u8 = 3;
pub const TypeU16: u8 = 4;
pub const TypeI32: u8 = 5;
pub const TypeU32: u8 = 6;
pub const TypeI64: u8 = 7;
pub const TypeU64: u8 = 8;
pub const TypeF32: u8 = 9;
pub const TypeF64: u8 = 10;
pub const TypeStr: u8 = 11;
pub const TypePtr: u8 = 12;

// SysV register limits: x86_64 passes 6 integer and 8 vector args in
// registers; aarch64 passes 8 and 8. Declarations beyond the register file
// are rejected at declare() time (v1 does not spill to the stack).
const MaxIntArgs = 6;
const MaxFloatArgs = 8;

/// Marshalling frame shared with the trampolines. Layout is hard-coded in
/// the assembly below; keep the two in sync.
///
/// Float args are always stored as full 64-bit slots. For f32 args the value
/// lives in the low 32 bits (high 32 zero); both trampolines load the whole
/// slot into the vector register, which is correct for f32 and f64 alike.
///
/// Layout (offsets used directly in asm — must stay in sync):
///   0:   fn_ptr  (*anyopaque, 8 bytes)
///   8:   ints    ([6]u64,    48 bytes)
///   56:  floats  ([8]f64,    64 bytes)
///   120: result_u (u64,       8 bytes)
///   128: result_f (f64,       8 bytes)
const FfiCall = extern struct {
    fn_ptr: ?*const anyopaque,
    ints: [MaxIntArgs]u64,
    floats: [MaxFloatArgs]f64,
    result_u: u64,
    result_f: f64,
};

comptime {
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("cap:ffi requires x86_64 or aarch64"),
    }
    // Verify the offsets the trampolines hard-code.
    const S = FfiCall;
    std.debug.assert(@offsetOf(S, "fn_ptr") == 0);
    std.debug.assert(@offsetOf(S, "ints") == 8);
    std.debug.assert(@offsetOf(S, "floats") == 56);
    std.debug.assert(@offsetOf(S, "result_u") == 120);
    std.debug.assert(@offsetOf(S, "result_f") == 128);
}

const TrampolineFn = *const fn (*FfiCall) callconv(.c) void;

// The trampolines are hand-written naked functions called through a .c-signature
// cast, so the frame pointer arrives in the ABI's first-arg register (rdi/x0).
// They bind the frame to a register, load the ABI register windows from the
// frame, call the target through its fn_ptr slot, and store rax/x0 and
// xmm0/d0 back into the frame.
//
// They are written in a deliberately small asm subset: Zig's self-hosted
// x86_64 backend, which compiles Debug builds, accepts only a limited
// instruction set and rejects every memory-operand SSE form. Float values are
// therefore moved between memory and the vector registers through GPRs, and
// 64-bit vector values are assembled/disassembled from two 32-bit halves with
// movd/punpckldq (load) and movd/pshufd (store) — all plain SSE2, so the code
// also works at -mcpu baseline, which the CLI targets. LLVM builds accept the
// same text. All literal registers use the %% escape.
//
// x86_64 stack alignment: the naked function is entered with RSP%16 == 8.
// pushq %rdi (the frame, for later recovery) brings RSP to 0 mod 16, so the
// callq is correctly aligned and the callee pops it before the epilogue, after
// which the parked frame is still at (%rsp).
//
// aarch64: SP stays 16-aligned through the stp/ldp pair. x19 is callee-saved
// and therefore preserved by the target function, so the frame pointer remains
// valid after blr; x30 (return address) is saved and restored by the pair.
fn callX86_64() callconv(.naked) void {
    _ = asm volatile (
        \\ pushq %%rdi
        \\ movq (%%rsp), %%r11
        \\ movq 8(%%r11), %%rdi
        \\ movq 16(%%r11), %%rsi
        \\ movq 24(%%r11), %%rdx
        \\ movq 32(%%r11), %%rcx
        \\ movq 40(%%r11), %%r8
        \\ movq 48(%%r11), %%r9
        \\ movl 56(%%r11), %%eax
        \\ movl 60(%%r11), %%r10d
        \\ movd %%eax, %%xmm0
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm0
        \\ movl 64(%%r11), %%eax
        \\ movl 68(%%r11), %%r10d
        \\ movd %%eax, %%xmm1
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm1
        \\ movl 72(%%r11), %%eax
        \\ movl 76(%%r11), %%r10d
        \\ movd %%eax, %%xmm2
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm2
        \\ movl 80(%%r11), %%eax
        \\ movl 84(%%r11), %%r10d
        \\ movd %%eax, %%xmm3
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm3
        \\ movl 88(%%r11), %%eax
        \\ movl 92(%%r11), %%r10d
        \\ movd %%eax, %%xmm4
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm4
        \\ movl 96(%%r11), %%eax
        \\ movl 100(%%r11), %%r10d
        \\ movd %%eax, %%xmm5
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm5
        \\ movl 104(%%r11), %%eax
        \\ movl 108(%%r11), %%r10d
        \\ movd %%eax, %%xmm6
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm6
        \\ movl 112(%%r11), %%eax
        \\ movl 116(%%r11), %%r10d
        \\ movd %%eax, %%xmm7
        \\ movd %%r10d, %%xmm8
        \\ punpckldq %%xmm8, %%xmm7
        \\ movq (%%r11), %%rax
        \\ callq *%%rax
        \\ movq (%%rsp), %%rdi
        \\ movq %%rax, 120(%%rdi)
        \\ movd %%xmm0, %%eax
        \\ movl %%eax, 128(%%rdi)
        \\ pshufd $1, %%xmm0, %%xmm8
        \\ movd %%xmm8, %%eax
        \\ movl %%eax, 132(%%rdi)
        \\ addq $8, %%rsp
        \\ retq
    );
}

fn callAarch64() callconv(.naked) void {
    _ = asm volatile (
        \\ stp x19, x30, [sp, #-16]!
        \\ mov x19, x0
        \\ ldr x17, [x19]
        \\ ldr x0, [x19, #8]
        \\ ldr x1, [x19, #16]
        \\ ldr x2, [x19, #24]
        \\ ldr x3, [x19, #32]
        \\ ldr x4, [x19, #40]
        \\ ldr x5, [x19, #48]
        \\ ldr d0, [x19, #56]
        \\ ldr d1, [x19, #64]
        \\ ldr d2, [x19, #72]
        \\ ldr d3, [x19, #80]
        \\ ldr d4, [x19, #88]
        \\ ldr d5, [x19, #96]
        \\ ldr d6, [x19, #104]
        \\ ldr d7, [x19, #112]
        \\ blr x17
        \\ str x0, [x19, #120]
        \\ str d0, [x19, #128]
        \\ ldp x19, x30, [sp], #16
        \\ ret
    );
}

fn callTrampoline(frame: *FfiCall) void {
    const t: TrampolineFn = switch (builtin.cpu.arch) {
        .x86_64 => @ptrCast(&callX86_64),
        .aarch64 => @ptrCast(&callAarch64),
        else => @compileError("cap:ffi requires x86_64 or aarch64"),
    };
    t(frame);
}

fn extractI64(v: Value) !i64 {
    return switch (v) {
        .int => |n| n,
        .float => |n| blk: {
            if (n < @as(f64, @floatFromInt(std.math.minInt(i64))) or n >= std.math.pow(f64, 2.0, 63.0)) return error.TypeError;
            break :blk @as(i64, @intFromFloat(n));
        },
        else => return error.TypeError,
    };
}

fn extractF64(v: Value) !f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |n| n,
        else => return error.TypeError,
    };
}

// Allocate a null-terminated copy of s using page_allocator. Caller must free.
fn toCString(s: []const u8) ![:0]u8 {
    const buf = try std.heap.page_allocator.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}

// Look up a symbol by name in a DynLib, handling versioned ELF symbols.
//
// std.DynLib.lookup calls ElfDynLib.lookupAddress("", name) which rejects any
// symbol whose version string is non-empty (e.g. SDL3's SDL_Init@@SDL3_0.0.0).
// The fix: when the unversioned lookup fails, walk the verdef table and retry
// with each non-base version name until one matches. This is only needed on
// musl-static builds where Zig uses ElfDynLib; on glibc builds DlDynLib calls
// dlsym which resolves versioned symbols itself.
fn lookupSym(dynlib: *std.DynLib, name: [:0]const u8) ?usize {
    if (dynlib.lookup(*align(1) const u8, name)) |s| return @intFromPtr(s);
    if (comptime !(builtin.abi == .musl and builtin.link_mode == .static)) return null;
    const lib = &dynlib.inner;
    var vd: ?*std.elf.Verdef = lib.verdef;
    while (vd) |v| {
        if ((v.flags & std.elf.VER_FLG_BASE) == 0) {
            const aux: *std.elf.Verdaux = @ptrFromInt(@intFromPtr(v) + v.aux);
            const vername = std.mem.sliceTo(lib.strings + aux.name, 0);
            if (lib.lookupAddress(vername, name)) |addr| return addr;
        }
        vd = if (v.next == 0) null else @ptrFromInt(@intFromPtr(v) + v.next);
    }
    return null;
}

fn lookupType(ctx: VMContext, qname: []const u8) !*Object {
    const val = ctx.gs.get(qname) orelse return error.CapabilityError;
    return switch (val) {
        .object => |o| o,
        else => return error.CapabilityError,
    };
}

fn fieldValue(si: vmod.StructInstanceObj, name: []const u8) !Value {
    const idx = vmtyp.findFieldIndex(si.typ.struct_type.fields, name) orelse return error.UnknownStructField;
    return si.fields[idx].value;
}

// Extract the *std.DynLib stored as i64 in _handle, or error if closed.
fn extractHandle(v: Value) !*std.DynLib {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.TypeError,
    };
    const raw: usize = switch (obj.*) {
        .struct_instance => |inst| switch (inst.fields[0].value) {
            .int => |n| @as(u64, @bitCast(n)),
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
    if (raw == 0) return error.CapabilityError; // library already closed
    return @ptrFromInt(raw);
}

fn validCode(n: i64) bool {
    return n >= 0 and n <= TypePtr;
}

const BufParts = struct { ptr: usize, len: usize };

// Extract the raw pointer and length from a Buf struct_instance.
fn extractBufParts(v: Value) !BufParts {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.TypeError,
    };
    const si = switch (obj.*) {
        .struct_instance => |i| i,
        else => return error.TypeError,
    };
    if (si.fields.len < 2) return error.TypeError;
    const ptr = @as(u64, @bitCast(switch (si.fields[0].value) {
        .int => |n| n,
        else => return error.TypeError,
    }));
    const len = @as(u64, @bitCast(switch (si.fields[1].value) {
        .int => |n| n,
        else => return error.TypeError,
    }));
    if (ptr == 0) return error.CapabilityError; // freed or invalid
    return .{ .ptr = @intCast(ptr), .len = @intCast(len) };
}

fn offsetArg(v: Value) !usize {
    return switch (v) {
        .int => |n| if (n < 0) error.RangeError else @intCast(n),
        else => error.TypeError,
    };
}

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        .cap_ffi_load => {
            if (argc != 1) return error.ArityMismatch;
            const arg0 = try ctx.vs.vmPeek(0);
            const name = vms.asStringValue(arg0) catch return error.TypeError;

            // std.DynLib.open accepts []const u8 directly (no sentinel needed).
            // On musl static builds Zig uses ElfDynLib (its own ELF loader)
            // rather than musl's stub dlopen, which always returns null.
            const dynlib = std.heap.page_allocator.create(std.DynLib) catch return error.OutOfMemory;
            dynlib.* = std.DynLib.open(name) catch {
                std.heap.page_allocator.destroy(dynlib);
                return error.FfiLoadFailed;
            };

            const lib_typ = try lookupType(ctx, LibQualifiedName);
            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 1);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = lib_typ, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            defer ctx.vs.popTempRoot();
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_handle") }, .value = .{ .int = @as(i64, @bitCast(@intFromPtr(dynlib))) } };

            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .object = inst_obj });
        },
        .cap_ffi_close => {
            if (argc != 1) return error.ArityMismatch;
            const lib_val = try ctx.vs.vmPeek(0);
            const obj = switch (lib_val) {
                .object => |o| o,
                else => return error.TypeError,
            };
            if (obj.* != .struct_instance) return error.TypeError;
            const raw: usize = switch (obj.struct_instance.fields[0].value) {
                .int => |n| @as(u64, @bitCast(n)),
                else => return error.TypeError,
            };
            if (raw != 0) {
                const dynlib: *std.DynLib = @ptrFromInt(raw);
                dynlib.close();
                std.heap.page_allocator.destroy(dynlib);
                obj.struct_instance.fields[0].value = .{ .int = 0 };
            }
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_declare => {
            if (argc != 4) return error.ArityMismatch;
            // Keep the arguments on the VM stack (rooted) while we allocate the
            // Callable struct; with GC stress enabled the array could be moved
            // or collected as soon as we drop a native-stack reference.
            const args_arr_val = try ctx.vs.vmPeek(0);
            const ret_val = try ctx.vs.vmPeek(1);
            const name_val = try ctx.vs.vmPeek(2);
            const lib_val = try ctx.vs.vmPeek(3);

            const dynlib = try extractHandle(lib_val);
            const sym_name = vms.asStringValue(name_val) catch return error.TypeError;
            const ret_code: u8 = switch (ret_val) {
                .int => |n| if (validCode(n)) @intCast(n) else return error.RangeError,
                else => return error.TypeError,
            };

            const args_obj: *Object = switch (args_arr_val) {
                .object => |o| o,
                else => return error.TypeError,
            };
            const arg_values = try vms.asArraySlice(args_obj);
            if (arg_values.len > MaxIntArgs + MaxFloatArgs) return error.ArityMismatch;

            var int_count: usize = 0;
            var float_count: usize = 0;
            for (arg_values) |av| {
                const code: u8 = switch (av) {
                    .int => |n| if (n >= 1 and n <= TypePtr) @intCast(n) else return error.RangeError,
                    else => return error.TypeError,
                };
                switch (code) {
                    TypeI8, TypeU8, TypeI16, TypeU16, TypeI32, TypeU32, TypeI64, TypeU64, TypeStr, TypePtr => {
                        int_count += 1;
                    },
                    TypeF32, TypeF64 => {
                        float_count += 1;
                    },
                    else => return error.TypeError,
                }
            }
            if (int_count > MaxIntArgs) return error.ArityMismatch;
            if (float_count > MaxFloatArgs) return error.ArityMismatch;

            // Stack-allocated sentinel buffer for the symbol name.
            var sym_buf: [512:0]u8 = undefined;
            if (sym_name.len >= sym_buf.len) return error.NameTooLong;
            @memcpy(sym_buf[0..sym_name.len], sym_name);
            sym_buf[sym_name.len] = 0;

            const sym_addr = lookupSym(dynlib, sym_buf[0..sym_name.len :0]) orelse return error.FfiSymbolNotFound;

            const callable_typ = try lookupType(ctx, CallableQualifiedName);
            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 3);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = callable_typ, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            defer ctx.vs.popTempRoot();
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_sym") }, .value = .{ .int = @as(i64, @bitCast(sym_addr)) } };
            inst_fields[1] = .{ .key = .{ .string = try ctx.cs.internStr("_ret") }, .value = .{ .int = ret_code } };
            inst_fields[2] = .{ .key = .{ .string = try ctx.cs.internStr("_args") }, .value = args_arr_val };

            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .object = inst_obj });
        },
        .cap_ffi_buf_alloc => {
            if (argc != 1) return error.ArityMismatch;
            const n: usize = switch (try ctx.vs.vmPeek(0)) {
                .int => |i| if (i <= 0 or i > 64 * 1024 * 1024) return error.RangeError else @intCast(i),
                else => return error.TypeError,
            };
            const raw = std.heap.page_allocator.alloc(u8, n) catch return error.OutOfMemory;
            @memset(raw, 0);
            const buf_typ = try lookupType(ctx, BufQualifiedName);
            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 2);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = buf_typ, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            defer ctx.vs.popTempRoot();
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_ptr") }, .value = .{ .int = @bitCast(@intFromPtr(raw.ptr)) } };
            inst_fields[1] = .{ .key = .{ .string = try ctx.cs.internStr("_len") }, .value = .{ .int = @bitCast(@as(u64, n)) } };
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .object = inst_obj });
        },
        .cap_ffi_buf_from_ptr => {
            if (argc != 2) return error.ArityMismatch;
            const ptr_int = switch (try ctx.vs.vmPeek(1)) {
                .int => |i| i,
                else => return error.TypeError,
            };
            const len_int = switch (try ctx.vs.vmPeek(0)) {
                .int => |i| if (i < 0 or i > 64 * 1024 * 1024) return error.RangeError else i,
                else => return error.TypeError,
            };
            if (ptr_int == 0) return error.CapabilityError;
            const buf_typ = try lookupType(ctx, BufQualifiedName);
            // 3-field instance: _ptr, _len, _own=0 (non-owning — caller must not call .free())
            const inst_fields = try vmgc.vmAllocManagedSlice(ctx, MapEntry, 3);
            const inst_obj = try vmgc.vmAllocObject(ctx);
            inst_obj.* = .{ .struct_instance = .{ .typ = buf_typ, .fields = inst_fields } };
            try ctx.vs.pushTempRoot(.{ .object = inst_obj });
            defer ctx.vs.popTempRoot();
            inst_fields[0] = .{ .key = .{ .string = try ctx.cs.internStr("_ptr") }, .value = .{ .int = ptr_int } };
            inst_fields[1] = .{ .key = .{ .string = try ctx.cs.internStr("_len") }, .value = .{ .int = len_int } };
            inst_fields[2] = .{ .key = .{ .string = try ctx.cs.internStr("_own") }, .value = .{ .int = 0 } };
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .object = inst_obj });
        },
        .cap_ffi_buf_free => {
            if (argc != 1) return error.ArityMismatch;
            const buf_val = try ctx.vs.vmPeek(0);
            const obj = switch (buf_val) {
                .object => |o| o,
                else => return error.TypeError,
            };
            const si = switch (obj.*) {
                .struct_instance => |i| i,
                else => return error.TypeError,
            };
            if (si.fields.len < 2) return error.TypeError;
            const ptr = @as(u64, @bitCast(switch (si.fields[0].value) {
                .int => |n| n,
                else => return error.TypeError,
            }));
            if (ptr != 0) {
                // Check _own field (field[2]): 0 = borrowed, skip page_allocator.free.
                const owned = si.fields.len < 3 or switch (si.fields[2].value) {
                    .int => |n| n != 0,
                    else => true,
                };
                if (owned) {
                    const blen = @as(u64, @bitCast(switch (si.fields[1].value) {
                        .int => |n| n,
                        else => return error.TypeError,
                    }));
                    std.heap.page_allocator.free(@as([*]u8, @ptrFromInt(ptr))[0..blen]);
                }
                obj.struct_instance.fields[0].value = .{ .int = 0 };
            }
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_len => {
            if (argc != 1) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(0));
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = @intCast(parts.len) });
        },
        .cap_ffi_buf_read_u8 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 1 > parts.len) return error.RangeError;
            const val = @as([*]const u8, @ptrFromInt(parts.ptr))[off];
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = val });
        },
        .cap_ffi_buf_read_i32 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 4 > parts.len) return error.RangeError;
            const val = std.mem.readInt(i32, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..4], .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = val });
        },
        .cap_ffi_buf_read_u32 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 4 > parts.len) return error.RangeError;
            const val = std.mem.readInt(u32, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..4], .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = @as(i64, @intCast(val)) });
        },
        .cap_ffi_buf_read_i64 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 8 > parts.len) return error.RangeError;
            const val = std.mem.readInt(i64, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..8], .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = val });
        },
        .cap_ffi_buf_read_u64 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 8 > parts.len) return error.RangeError;
            const val = std.mem.readInt(u64, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..8], .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .int = @bitCast(val) });
        },
        .cap_ffi_buf_read_f32 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 4 > parts.len) return error.RangeError;
            const bits = std.mem.readInt(u32, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..4], .little);
            const val: f32 = @bitCast(bits);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .float = val });
        },
        .cap_ffi_buf_read_f64 => {
            if (argc != 2) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(1));
            const off = try offsetArg(try ctx.vs.vmPeek(0));
            if (off + 8 > parts.len) return error.RangeError;
            const bits = std.mem.readInt(u64, @as([*]const u8, @ptrFromInt(parts.ptr))[off..][0..8], .little);
            const val: f64 = @bitCast(bits);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.{ .float = val });
        },
        .cap_ffi_buf_write_u8 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const v: u8 = switch (try ctx.vs.vmPeek(0)) {
                .int => |n| @truncate(@as(u64, @bitCast(n))),
                else => return error.TypeError,
            };
            if (off + 1 > parts.len) return error.RangeError;
            @as([*]u8, @ptrFromInt(parts.ptr))[off] = v;
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_i32 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const v: i32 = @truncate(try extractI64(try ctx.vs.vmPeek(0)));
            if (off + 4 > parts.len) return error.RangeError;
            std.mem.writeInt(i32, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..4], v, .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_u32 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const v: u32 = @truncate(@as(u64, @bitCast(try extractI64(try ctx.vs.vmPeek(0)))));
            if (off + 4 > parts.len) return error.RangeError;
            std.mem.writeInt(u32, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..4], v, .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_i64 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const v: i64 = try extractI64(try ctx.vs.vmPeek(0));
            if (off + 8 > parts.len) return error.RangeError;
            std.mem.writeInt(i64, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..8], v, .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_u64 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const v: u64 = @bitCast(try extractI64(try ctx.vs.vmPeek(0)));
            if (off + 8 > parts.len) return error.RangeError;
            std.mem.writeInt(u64, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..8], v, .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_f32 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const fv: f32 = @floatCast(try extractF64(try ctx.vs.vmPeek(0)));
            if (off + 4 > parts.len) return error.RangeError;
            std.mem.writeInt(u32, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..4], @bitCast(fv), .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        .cap_ffi_buf_write_f64 => {
            if (argc != 3) return error.ArityMismatch;
            const parts = try extractBufParts(try ctx.vs.vmPeek(2));
            const off = try offsetArg(try ctx.vs.vmPeek(1));
            const fv: f64 = try extractF64(try ctx.vs.vmPeek(0));
            if (off + 8 > parts.len) return error.RangeError;
            std.mem.writeInt(u64, @as([*]u8, @ptrFromInt(parts.ptr))[off..][0..8], @bitCast(fv), .little);
            for (0..argc + 1) |_| _ = try ctx.vs.vmPop();
            try ctx.vs.vmPush(.null);
        },
        else => return error.NativeFunctionNotFound,
    }
}

/// Invoked from vm.zig performCall when the callee is a struct_instance whose
/// type is the ffi callable. Marshals the args on the VM stack, runs the
/// trampoline, and pushes the result. Follows the cap_net popping protocol:
/// pops argc args plus the callee, then pushes one result.
pub fn dispatchCallable(ctx: VMContext, obj: *Object, argc: u8) !void {
    const si = obj.struct_instance;
    try ctx.vs.pushTempRoot(.{ .object = obj });
    defer ctx.vs.popTempRoot();

    const sym_val = try fieldValue(si, "_sym");
    const ret_val = try fieldValue(si, "_ret");
    const args_val = try fieldValue(si, "_args");

    const sym: usize = switch (sym_val) {
        .int => |n| @as(u64, @bitCast(n)),
        else => return error.TypeError,
    };
    const ret_code: u8 = switch (ret_val) {
        .int => |n| if (validCode(n)) @intCast(n) else return error.RangeError,
        else => return error.TypeError,
    };
    const args_obj: *Object = switch (args_val) {
        .object => |o| o,
        else => return error.TypeError,
    };
    const arg_values = try vms.asArraySlice(args_obj);
    if (arg_values.len != argc) return error.ArityMismatch;

    // Copy the type codes into a native buffer before any later operation can
    // trigger a GC. The arg array is GC-managed and may move while we are using
    // its backing, and our local slice is not a GC root.
    var arg_codes: [MaxIntArgs + MaxFloatArgs]u8 = undefined;
    if (argc > arg_codes.len) return error.ArityMismatch;
    for (0..argc) |i| {
        arg_codes[i] = switch (arg_values[i]) {
            .int => |n| if (n >= 1 and n <= TypePtr) @intCast(n) else return error.RangeError,
            else => return error.TypeError,
        };
    }

    var frame: FfiCall = undefined;
    @memset(&frame.ints, 0);
    @memset(&frame.floats, 0);
    frame.fn_ptr = @ptrFromInt(sym);
    frame.result_u = 0;
    frame.result_f = 0;

    // Args still sit at stack[stack_top - argc .. stack_top] (rooted by the
    // VM stack). Marshalling below only uses page_allocator, which never
    // triggers a GC, so their string/array backing stays put until the
    // trampoline has run. The arg type codes were copied into a native buffer
    // above because the arg_values slice points into GC-managed array storage.
    const start = ctx.vs.stack_top - argc;
    var c_strings: [MaxIntArgs][:0]u8 = undefined;
    var c_string_count: usize = 0;
    defer for (c_strings[0..c_string_count]) |s| std.heap.page_allocator.free(s);

    var int_count: usize = 0;
    var float_count: usize = 0;
    var ai: usize = 0;
    while (ai < argc) : (ai += 1) {
        const v = ctx.vs.stack[start + ai];
        const code = arg_codes[ai];
        switch (code) {
            TypeI8, TypeU8, TypeI16, TypeU16, TypeI32, TypeU32, TypeI64, TypeU64 => {
                if (int_count >= MaxIntArgs) return error.ArityMismatch;
                frame.ints[int_count] = @as(u64, @bitCast(try extractI64(v)));
                int_count += 1;
            },
            TypeF32, TypeF64 => {
                if (float_count >= MaxFloatArgs) return error.ArityMismatch;
                if (code == TypeF32) {
                    const f32v: f32 = @floatCast(try extractF64(v));
                    // Store the f32 bits in the low 32 bits of the slot; the
                    // trampoline loads the full 64-bit slot into the vector
                    // register, so the f32 lands in its low 32 bits.
                    frame.floats[float_count] = @as(f64, @bitCast(@as(u64, @intCast(@as(u32, @bitCast(f32v))))));
                } else {
                    frame.floats[float_count] = try extractF64(v);
                }
                float_count += 1;
            },
            TypeStr => {
                if (int_count >= MaxIntArgs) return error.ArityMismatch;
                const s = vms.asStringValue(v) catch return error.TypeError;
                const z = try toCString(s);
                c_strings[c_string_count] = z;
                c_string_count += 1;
                frame.ints[int_count] = @intFromPtr(z.ptr);
                int_count += 1;
            },
            TypePtr => {
                if (int_count >= MaxIntArgs) return error.ArityMismatch;
                frame.ints[int_count] = switch (v) {
                    .int => |n| @as(u64, @bitCast(n)),
                    .null => 0,
                    .object => |o| switch (o.*) {
                        .struct_instance => |sinst| switch (sinst.fields[0].value) {
                            .int => |n| @as(u64, @bitCast(n)),
                            else => return error.TypeError,
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };
                int_count += 1;
            },
            else => return error.TypeError, // TypeVoid is not a valid arg type
        }
    }

    for (0..@as(usize, argc) + 1) |_| _ = try ctx.vs.vmPop();

    callTrampoline(&frame);

    const out: Value = switch (ret_code) {
        TypeVoid => .null,
        TypeI8 => .{ .int = @as(i64, @intCast(@as(i8, @bitCast(@as(u8, @truncate(frame.result_u)))))) },
        TypeU8 => .{ .int = @as(i64, @intCast(@as(u8, @truncate(frame.result_u)))) },
        TypeI16 => .{ .int = @as(i64, @intCast(@as(i16, @bitCast(@as(u16, @truncate(frame.result_u)))))) },
        TypeU16 => .{ .int = @as(i64, @intCast(@as(u16, @truncate(frame.result_u)))) },
        TypeI32 => .{ .int = @as(i64, @intCast(@as(i32, @bitCast(@as(u32, @truncate(frame.result_u)))))) },
        TypeU32 => .{ .int = @as(i64, @intCast(@as(u32, @truncate(frame.result_u)))) },
        TypeI64 => .{ .int = @as(i64, @bitCast(frame.result_u)) },
        TypeU64 => .{ .int = @as(i64, @bitCast(frame.result_u)) },
        TypeF32 => .{ .float = @as(f32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(frame.result_f)))))) },
        TypeF64 => .{ .float = frame.result_f },
        TypeStr => blk: {
            if (frame.result_u == 0) break :blk .null;
            const cstr: [*:0]const u8 = @ptrFromInt(frame.result_u);
            const bytes = std.mem.span(cstr);
            break :blk try vmgc.makeDynString(ctx, bytes);
        },
        TypePtr => .{ .int = @as(i64, @bitCast(frame.result_u)) },
        else => return error.RangeError,
    };
    try ctx.vs.vmPush(out);
}
