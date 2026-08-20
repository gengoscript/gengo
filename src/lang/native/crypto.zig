const std = @import("std");
const builtin = @import("builtin");
const vms = @import("../vm_state.zig");
const VMContext = vms.VMContext;
const vmgc = @import("../vm_gc.zig");
const Value = @import("../value.zig").Value;
const NativeFuncObj = @import("../value.zig").NativeFuncObj;
const NativeFnId = @import("native_ids.zig").NativeFnId;

const AesGcm128 = std.crypto.aead.aes_gcm.Aes128Gcm;
const AesGcm256 = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const XChaCha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;

pub fn dispatch(ctx: VMContext, nf: NativeFuncObj, argc: u8) !void {
    switch (@as(NativeFnId, @enumFromInt(nf.id))) {
        // --- Hashes (input = any bytes, output = lowercase hex string) ---
        .crypto_sha256 => {
            if (argc != 1) return error.ArityMismatch;
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &digest));
        },
        .crypto_sha512 => {
            if (argc != 1) return error.ArityMismatch;
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha512.hash(data, &digest, .{});
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &digest));
        },
        .crypto_blake3 => {
            if (argc != 1) return error.ArityMismatch;
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            std.crypto.hash.Blake3.hash(data, &digest, .{});
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &digest));
        },
        .crypto_md5 => {
            if (argc != 1) return error.ArityMismatch;
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
            std.crypto.hash.Md5.hash(data, &digest, .{});
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &digest));
        },
        .crypto_sha1 => {
            if (argc != 1) return error.ArityMismatch;
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            std.crypto.hash.Sha1.hash(data, &digest, .{});
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &digest));
        },
        // --- MACs (output = lowercase hex string) ---
        .crypto_hmac_sha256 => {
            if (argc != 2) return error.ArityMismatch;
            const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var out: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &out));
        },
        .crypto_hmac_sha512 => {
            if (argc != 2) return error.ArityMismatch;
            const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const data = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            var out: [std.crypto.auth.hmac.sha2.HmacSha512.mac_length]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha512.create(&out, data, key);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(try hexDigest(ctx, &out));
        },
        // --- AEAD: seal returns raw bytes (ciphertext || 16-byte tag) ---
        .crypto_aes_gcm_seal => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try aesSeal(ctx, argc));
        },
        .crypto_aes_gcm_open => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try aesOpen(ctx, argc));
        },
        .crypto_chacha20poly1305_seal => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try chachaSeal(ctx, argc));
        },
        .crypto_chacha20poly1305_open => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try chachaOpen(ctx, argc));
        },
        // --- Utility ---
        .crypto_constant_time_equal => {
            if (argc != 2) return error.ArityMismatch;
            const a = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const b = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            const eq = timingSafeEql(a, b);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = eq });
        },
        // --- Random ---
        .crypto_rand_bytes => {
            if (argc != 1) return error.ArityMismatch;
            const n = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 1]);
            if (n < 0 or n > 65536) return error.ValueError;
            const usize_n: usize = @intCast(n);
            ctx.vs.vmPopArgs(argc);
            const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
            defer ctx.vs.popTempRoot();
            const buf = try vmgc.vmAllocManagedBytes(ctx, usize_n);
            try fillRandomBytes(buf[0..usize_n]);
            obj.* = .{ .dyn_string = buf[0..usize_n] };
            try ctx.vs.vmPush(.{ .object = obj });
        },
        // --- Key derivation ---
        .crypto_argon2id => {
            if (argc != 6) return error.ArityMismatch;
            try ctx.vs.vmPush(try argon2id(ctx, argc));
        },
        // --- Password hashing ---
        .crypto_bcrypt_hash => {
            if (argc != 2) return error.ArityMismatch;
            try ctx.vs.vmPush(try bcryptHash(ctx, argc));
        },
        .crypto_bcrypt_verify => {
            if (argc != 2) return error.ArityMismatch;
            const hash_str = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const password = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            const ok = bcryptVerify(hash_str, password);
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = ok });
        },
        // --- HKDF ---
        .crypto_hkdf_sha256 => {
            if (argc != 4) return error.ArityMismatch;
            try ctx.vs.vmPush(try hkdfSha256(ctx, argc));
        },
        // --- XChaCha20-Poly1305 (24-byte nonce) ---
        .crypto_xchacha20poly1305_seal => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try xChachaSeal(ctx, argc));
        },
        .crypto_xchacha20poly1305_open => {
            if (argc != 3) return error.ArityMismatch;
            try ctx.vs.vmPush(try xChacha_open(ctx, argc));
        },
        // --- Ed25519 signatures ---
        .crypto_ed25519_sign => {
            if (argc != 2) return error.ArityMismatch;
            try ctx.vs.vmPush(try ed25519Sign(ctx, argc));
        },
        .crypto_ed25519_verify => {
            if (argc != 3) return error.ArityMismatch;
            const pk_bytes = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
            const sig_bytes = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const msg = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            if (pk_bytes.len != Ed25519.PublicKey.encoded_length) return error.ValueError;
            if (sig_bytes.len != Ed25519.Signature.encoded_length) return error.ValueError;
            const pk = Ed25519.PublicKey.fromBytes(pk_bytes[0..Ed25519.PublicKey.encoded_length].*) catch return error.ValueError;
            const sig = Ed25519.Signature.fromBytes(sig_bytes[0..Ed25519.Signature.encoded_length].*);
            const ok = blk: {
                sig.verify(msg, pk) catch break :blk false;
                break :blk true;
            };
            ctx.vs.vmPopArgs(argc);
            try ctx.vs.vmPush(.{ .boolean = ok });
        },
        // --- X25519 Diffie-Hellman ---
        .crypto_x25519 => {
            if (argc != 2) return error.ArityMismatch;
            const my_secret = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
            const their_public = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
            if (my_secret.len != X25519.secret_length) return error.ValueError;
            if (their_public.len != X25519.public_length) return error.ValueError;
            var sec: [X25519.secret_length]u8 = undefined;
            var pub_k: [X25519.public_length]u8 = undefined;
            @memcpy(&sec, my_secret);
            @memcpy(&pub_k, their_public);
            ctx.vs.vmPopArgs(argc);
            const shared = X25519.scalarmult(sec, pub_k) catch return error.ValueError;
            const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
            defer ctx.vs.popTempRoot();
            const buf = try vmgc.vmAllocManagedBytes(ctx, X25519.shared_length);
            @memcpy(buf[0..X25519.shared_length], &shared);
            obj.* = .{ .dyn_string = buf[0..X25519.shared_length] };
            try ctx.vs.vmPush(.{ .object = obj });
        },
        else => {},
    }
}

// --- HKDF ---

fn hkdfSha256(ctx: VMContext, argc: u8) !Value {
    // args: ikm, salt, info, len
    const ikm_s = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 4]);
    const salt_s = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const info_s = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
    const out_len = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 1]);
    if (out_len < 1 or out_len > HkdfSha256.prk_length * 255) return error.ValueError;
    if (ikm_s.len > 4096 or salt_s.len > 4096 or info_s.len > 256) return error.ValueError;

    var ikm_buf: [4096]u8 = undefined;
    var salt_buf: [4096]u8 = undefined;
    var info_buf: [256]u8 = undefined;
    @memcpy(ikm_buf[0..ikm_s.len], ikm_s);
    @memcpy(salt_buf[0..salt_s.len], salt_s);
    @memcpy(info_buf[0..info_s.len], info_s);
    const ikm = ikm_buf[0..ikm_s.len];
    const salt = salt_buf[0..salt_s.len];
    const info = info_buf[0..info_s.len];
    const usize_len: usize = @intCast(out_len);

    ctx.vs.vmPopArgs(argc);

    const prk = HkdfSha256.extract(salt, ikm);
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, usize_len);
    HkdfSha256.expand(buf[0..usize_len], info, prk);
    obj.* = .{ .dyn_string = buf[0..usize_len] };
    return .{ .object = obj };
}

// --- XChaCha20-Poly1305 helpers (24-byte nonce) ---

fn xChachaSeal(ctx: VMContext, argc: u8) !Value {
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const pt_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != XChaCha.nonce_length) return error.ValueError;
    var npub: [XChaCha.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const out_len = pt_len + XChaCha.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, out_len);
    const key_slice = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const pt = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    if (key_slice.len != XChaCha.key_length) return error.ValueError;
    var k: [XChaCha.key_length]u8 = undefined;
    @memcpy(&k, key_slice);
    var tag: [XChaCha.tag_length]u8 = undefined;
    XChaCha.encrypt(buf[0..pt.len], &tag, pt, &[_]u8{}, npub, k);
    @memcpy(buf[pt.len..][0..XChaCha.tag_length], &tag);
    obj.* = .{ .dyn_string = buf[0..out_len] };
    return .{ .object = obj };
}

fn xChacha_open(ctx: VMContext, argc: u8) !Value {
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const ct_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != XChaCha.nonce_length) return error.ValueError;
    if (ct_len < XChaCha.tag_length) return error.ValueError;
    var npub: [XChaCha.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const pt_len = ct_len - XChaCha.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, pt_len);
    const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const ct = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    if (key.len != XChaCha.key_length) return error.ValueError;
    var k: [XChaCha.key_length]u8 = undefined;
    @memcpy(&k, key);
    var tag: [XChaCha.tag_length]u8 = undefined;
    @memcpy(&tag, ct[pt_len..][0..XChaCha.tag_length]);
    XChaCha.decrypt(buf[0..pt_len], ct[0..pt_len], tag, &[_]u8{}, npub, k) catch return error.AuthenticationFailure;
    obj.* = .{ .dyn_string = buf[0..pt_len] };
    return .{ .object = obj };
}

// --- Ed25519 ---

fn ed25519Sign(ctx: VMContext, argc: u8) !Value {
    // args: seed(32), message
    const seed_slice = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
    const msg_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;
    if (seed_slice.len != Ed25519.KeyPair.seed_length) return error.ValueError;
    if (msg_len > 1 << 20) return error.ValueError; // 1 MiB limit

    var seed_buf: [Ed25519.KeyPair.seed_length]u8 = undefined;
    @memcpy(&seed_buf, seed_slice);

    const sig_len = Ed25519.Signature.encoded_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, sig_len);
    const msg = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    const kp = Ed25519.KeyPair.generateDeterministic(seed_buf) catch return error.ValueError;
    const sig = kp.sign(msg, null) catch return error.ValueError;
    @memcpy(buf[0..sig_len], &sig.toBytes());
    obj.* = .{ .dyn_string = buf[0..sig_len] };
    return .{ .object = obj };
}

// --- AEAD helpers ---

fn aesSeal(ctx: VMContext, argc: u8) !Value {
    // stack: key=top-3, nonce=top-2, plaintext=top-1
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const pt_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != AesGcm128.nonce_length) return error.ValueError;
    var npub: [AesGcm128.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const out_len = pt_len + AesGcm128.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, out_len);
    // Re-derive all three inputs after GC allocation.
    const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const pt = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    var tag: [AesGcm128.tag_length]u8 = undefined;
    switch (key.len) {
        AesGcm128.key_length => {
            var k128: [AesGcm128.key_length]u8 = undefined;
            @memcpy(&k128, key);
            AesGcm128.encrypt(buf[0..pt.len], &tag, pt, &[_]u8{}, npub, k128);
        },
        AesGcm256.key_length => {
            var k256: [AesGcm256.key_length]u8 = undefined;
            @memcpy(&k256, key);
            AesGcm256.encrypt(buf[0..pt.len], &tag, pt, &[_]u8{}, npub, k256);
        },
        else => return error.ValueError,
    }
    @memcpy(buf[pt.len..][0..AesGcm128.tag_length], &tag);
    obj.* = .{ .dyn_string = buf[0..out_len] };
    return .{ .object = obj };
}

fn aesOpen(ctx: VMContext, argc: u8) !Value {
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const ct_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != AesGcm128.nonce_length) return error.ValueError;
    if (ct_len < AesGcm128.tag_length) return error.ValueError;
    var npub: [AesGcm128.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const pt_len = ct_len - AesGcm128.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, pt_len);
    const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const ct = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    var tag: [AesGcm128.tag_length]u8 = undefined;
    @memcpy(&tag, ct[pt_len..][0..AesGcm128.tag_length]);
    switch (key.len) {
        AesGcm128.key_length => {
            var k128: [AesGcm128.key_length]u8 = undefined;
            @memcpy(&k128, key);
            AesGcm128.decrypt(buf[0..pt_len], ct[0..pt_len], tag, &[_]u8{}, npub, k128) catch return error.AuthenticationFailure;
        },
        AesGcm256.key_length => {
            var k256: [AesGcm256.key_length]u8 = undefined;
            @memcpy(&k256, key);
            AesGcm256.decrypt(buf[0..pt_len], ct[0..pt_len], tag, &[_]u8{}, npub, k256) catch return error.AuthenticationFailure;
        },
        else => return error.ValueError,
    }
    obj.* = .{ .dyn_string = buf[0..pt_len] };
    return .{ .object = obj };
}

fn chachaSeal(ctx: VMContext, argc: u8) !Value {
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const pt_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != ChaCha.nonce_length) return error.ValueError;
    var npub: [ChaCha.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const out_len = pt_len + ChaCha.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, out_len);
    const key_slice = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const pt = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    if (key_slice.len != ChaCha.key_length) return error.ValueError;
    var k: [ChaCha.key_length]u8 = undefined;
    @memcpy(&k, key_slice);
    var tag: [ChaCha.tag_length]u8 = undefined;
    ChaCha.encrypt(buf[0..pt.len], &tag, pt, &[_]u8{}, npub, k);
    @memcpy(buf[pt.len..][0..ChaCha.tag_length], &tag);
    obj.* = .{ .dyn_string = buf[0..out_len] };
    return .{ .object = obj };
}

fn chachaOpen(ctx: VMContext, argc: u8) !Value {
    const nonce_val = ctx.vs.stack[ctx.vs.stack_top - 2];
    const nonce_slice = try vms.asStringValue(nonce_val);
    const ct_len = (try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1])).len;

    if (nonce_slice.len != ChaCha.nonce_length) return error.ValueError;
    if (ct_len < ChaCha.tag_length) return error.ValueError;
    var npub: [ChaCha.nonce_length]u8 = undefined;
    @memcpy(&npub, nonce_slice);

    const pt_len = ct_len - ChaCha.tag_length;
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, pt_len);
    const key = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const ct = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 1]);
    ctx.vs.vmPopArgs(argc);

    if (key.len != ChaCha.key_length) return error.ValueError;
    var k: [ChaCha.key_length]u8 = undefined;
    @memcpy(&k, key);
    var tag: [ChaCha.tag_length]u8 = undefined;
    @memcpy(&tag, ct[pt_len..][0..ChaCha.tag_length]);
    ChaCha.decrypt(buf[0..pt_len], ct[0..pt_len], tag, &[_]u8{}, npub, k) catch return error.AuthenticationFailure;
    obj.* = .{ .dyn_string = buf[0..pt_len] };
    return .{ .object = obj };
}

// --- Key derivation ---

fn argon2id(ctx: VMContext, argc: u8) !Value {
    // args: password, salt, time_cost, mem_kb, parallelism, key_len
    const password = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 6]);
    const salt = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 5]);
    const t = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 4]);
    const m = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 3]);
    const p = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 2]);
    const key_len = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 1]);

    // Upper bounds (not just bcryptHash's lower-bound style) matter here:
    // t/m/p are cast into std.crypto.pwhash.argon2.Params' u32/u32/u24
    // fields below with @intCast, and an out-of-range i64 (e.g. m between
    // u32::max and i64::max) panics that cast immediately -- a crash
    // trivially reachable from Gengo source, no wire format or policy
    // misconfiguration needed. The bounds also cap real resource use: m is
    // in KiB, so 4 GiB and 100 iterations are already generous for any
    // legitimate password-hashing use, while still comfortably fitting
    // u32/u32/u24 (max ~4.29e9 / ~4.29e9 / ~1.68e7 respectively).
    if (t < 1 or t > 100 or m < 8 or m > 4 * 1024 * 1024 or p < 1 or p > 255 or key_len < 1 or key_len > 64) return error.ValueError;
    if (salt.len < 8) return error.ValueError;

    // Copy inputs to stack buffers so GC allocation below is safe.
    if (password.len > 4096 or salt.len > 4096) return error.ValueError;
    var pw_buf: [4096]u8 = undefined;
    var salt_buf: [4096]u8 = undefined;
    @memcpy(pw_buf[0..password.len], password);
    @memcpy(salt_buf[0..salt.len], salt);
    const pw = pw_buf[0..password.len];
    const sl = salt_buf[0..salt.len];
    const usize_kl: usize = @intCast(key_len);

    ctx.vs.vmPopArgs(argc);

    var dk: [64]u8 = undefined;
    const params: std.crypto.pwhash.argon2.Params = .{
        .t = @intCast(t),
        .m = @intCast(m),
        .p = @intCast(p),
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    std.crypto.pwhash.argon2.kdf(std.heap.page_allocator, dk[0..usize_kl], pw, sl, params, .argon2id, io) catch return error.SystemResources;

    return try hexDigest(ctx, dk[0..usize_kl]);
}

// --- Password hashing ---

fn bcryptHash(ctx: VMContext, argc: u8) !Value {
    const password = try vms.asStringValue(ctx.vs.stack[ctx.vs.stack_top - 2]);
    const cost_val = try vms.valueAsInt(ctx.vs.stack[ctx.vs.stack_top - 1]);
    if (cost_val < 4 or cost_val > 31) return error.ValueError;
    const rounds_log: u6 = @intCast(cost_val);

    // Copy password to stack before GC allocation.
    if (password.len > 72) return error.ValueError;
    var pw_buf: [72]u8 = undefined;
    @memcpy(pw_buf[0..password.len], password);
    const pw = pw_buf[0..password.len];

    ctx.vs.vmPopArgs(argc);

    var hash_buf: [std.crypto.pwhash.bcrypt.hash_length]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const hash_str = std.crypto.pwhash.bcrypt.strHash(pw, .{
        .params = .{ .rounds_log = rounds_log, .silently_truncate_password = false },
        .encoding = .crypt,
    }, &hash_buf, io) catch return error.SystemResources;

    return try internedStringCopy(ctx, hash_str);
}

fn bcryptVerify(hash_str: []const u8, password: []const u8) bool {
    std.crypto.pwhash.bcrypt.strVerify(hash_str, password, .{
        .silently_truncate_password = false,
    }) catch return false;
    return true;
}

// --- Random bytes ---

fn fillRandomBytes(buf: []u8) !void {
    if (buf.len == 0) return;
    if (comptime builtin.os.tag == .wasi) {
        if (std.os.wasi.random_get(buf.ptr, buf.len) != .SUCCESS) return error.SystemResources;
    } else if (comptime builtin.os.tag == .linux) {
        var written: usize = 0;
        while (written < buf.len) {
            const got = std.os.linux.getrandom(buf.ptr + written, buf.len - written, 0);
            if (got == 0) return error.SystemResources;
            written += got;
        }
    } else {
        const seed: u64 = @intFromPtr(buf.ptr) ^ 0xdeadbeef_cafebabe;
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(buf);
    }
}

// --- Shared helpers ---

fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn hexDigest(ctx: VMContext, digest: []const u8) !Value {
    const obj = try vmgc.allocTempRooted(ctx, .{ .dyn_string = &[_]u8{} });
    defer ctx.vs.popTempRoot();
    const buf = try vmgc.vmAllocManagedBytes(ctx, digest.len * 2);
    for (digest, 0..) |b, i| {
        const hi: u8 = (b >> 4) & 0xf;
        const lo: u8 = b & 0xf;
        buf[i * 2] = if (hi < 10) '0' + hi else 'a' + hi - 10;
        buf[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + lo - 10;
    }
    obj.* = .{ .dyn_string = buf[0 .. digest.len * 2] };
    return .{ .object = obj };
}

fn internedStringCopy(ctx: VMContext, s: []const u8) !Value {
    return .{ .string = try ctx.cs.internStrCopy(s) };
}
