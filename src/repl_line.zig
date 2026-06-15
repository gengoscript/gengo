// Raw-mode line editor for the REPL (Linux only).
//
// Puts stdin in raw mode on entry, restores it on return. Handles arrow
// keys, Ctrl shortcuts, and in-session history without external dependencies.

const std = @import("std");

// ── termios (Linux x86-64 layout) ──────────────────────────────────────────

const Termios = extern struct {
    iflag:  u32,
    oflag:  u32,
    cflag:  u32,
    lflag:  u32,
    line:   u8,
    cc:     [19]u8,
    ispeed: u32,
    ospeed: u32,
};

const TCGETS:  usize = 0x5401;
const TCSETSF: usize = 0x5404;

const ISIG:   u32 = 0x0001;
const ICANON: u32 = 0x0002;
const ECHO:   u32 = 0x0008;
const ECHOE:  u32 = 0x0010;
const ECHOK:  u32 = 0x0020;
const ECHONL: u32 = 0x0040;
const IEXTEN: u32 = 0x8000;
const BRKINT: u32 = 0x0002;
const ICRNL:  u32 = 0x0100;
const IXON:   u32 = 0x0400;

const VTIME: usize = 5;
const VMIN:  usize = 6;

fn tcGet(t: *Termios) bool {
    return std.os.linux.syscall3(.ioctl, 0, TCGETS, @intFromPtr(t)) == 0;
}

fn tcSet(t: *const Termios) void {
    _ = std.os.linux.syscall3(.ioctl, 0, TCSETSF, @intFromPtr(t));
}

// ── history ────────────────────────────────────────────────────────────────

const HistCap    = 50;
const HistMaxLen = 512;

var hist_buf:   [HistCap][HistMaxLen]u8 = undefined;
var hist_lens:  [HistCap]usize          = [_]usize{0} ** HistCap;
var hist_count: usize                   = 0;

fn histPush(line: []const u8) void {
    if (line.len == 0) return;
    if (hist_count > 0) {
        const last = (hist_count - 1) % HistCap;
        if (std.mem.eql(u8, hist_buf[last][0..hist_lens[last]], line)) return;
    }
    const slot = hist_count % HistCap;
    const n = @min(line.len, HistMaxLen);
    @memcpy(hist_buf[slot][0..n], line[0..n]);
    hist_lens[slot] = n;
    hist_count += 1;
}

// age=1 → most recent entry, age=2 → second most recent, etc.
fn histGet(age: usize) ?[]const u8 {
    if (age == 0 or age > @min(hist_count, HistCap)) return null;
    const slot = (hist_count - age) % HistCap;
    return hist_buf[slot][0..hist_lens[slot]];
}

// ── low-level I/O (direct syscalls; no buffering) ──────────────────────────

fn sysRead(buf: []u8) usize {
    return std.os.linux.syscall3(.read, 0, @intFromPtr(buf.ptr), buf.len);
}

fn sysWrite(buf: []const u8) void {
    _ = std.os.linux.syscall3(.write, 1, @intFromPtr(buf.ptr), buf.len);
}

fn writeByte(b: u8) void {
    sysWrite(&[1]u8{b});
}

fn moveRight(n: usize) void {
    if (n == 0) return;
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "\x1b[{}C", .{n}) catch return;
    sysWrite(s);
}

fn redraw(prompt: []const u8, line: []const u8, cursor: usize) void {
    sysWrite("\r");
    sysWrite(prompt);
    sysWrite(line);
    sysWrite("\x1b[K"); // erase to end of line
    sysWrite("\r");
    moveRight(prompt.len + cursor);
}

// ── readLine ───────────────────────────────────────────────────────────────

// Read one line from stdin with raw-mode editing.
// Prints prompt, handles escape sequences and history, returns the line
// (without newline) or null on Ctrl+D with an empty buffer.
// Returns an empty slice if the user cancels with Ctrl+C.
pub fn readLine(prompt: []const u8, buf: []u8) ?[]const u8 {
    var orig: Termios = undefined;
    if (!tcGet(&orig)) {
        // tcgetattr failed — just print the prompt and return
        sysWrite(prompt);
        return null;
    }

    var raw = orig;
    raw.lflag &= ~(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL | IEXTEN);
    raw.iflag &= ~(BRKINT | ICRNL | IXON);
    raw.cc[VMIN]  = 1;
    raw.cc[VTIME] = 0;
    tcSet(&raw);
    defer tcSet(&orig);

    sysWrite(prompt);

    var len:      usize = 0;
    var cursor:   usize = 0;
    var hist_pos: usize = 0; // 0 = live input, 1 = most recent history entry
    var saved:    [HistMaxLen]u8 = undefined;
    var saved_len: usize = 0;

    while (true) {
        var byte: [1]u8 = undefined;
        if (sysRead(&byte) != 1) {
            sysWrite("\r\n");
            return if (len > 0) buf[0..len] else null;
        }
        const c = byte[0];

        switch (c) {
            '\r', '\n' => {
                sysWrite("\r\n");
                const result = buf[0..len];
                histPush(result);
                return result;
            },
            0x04 => { // Ctrl+D — EOF on empty line, otherwise ignore
                if (len == 0) {
                    sysWrite("\r\n");
                    return null;
                }
            },
            0x03 => { // Ctrl+C — cancel line, show new prompt from caller
                sysWrite("^C\r\n");
                len    = 0;
                cursor = 0;
                hist_pos = 0;
                return buf[0..0];
            },
            0x01 => { // Ctrl+A — beginning of line
                cursor = 0;
                redraw(prompt, buf[0..len], cursor);
            },
            0x05 => { // Ctrl+E — end of line
                cursor = len;
                redraw(prompt, buf[0..len], cursor);
            },
            0x0b => { // Ctrl+K — kill to end of line
                len = cursor;
                redraw(prompt, buf[0..len], cursor);
            },
            0x15 => { // Ctrl+U — kill whole line
                len    = 0;
                cursor = 0;
                redraw(prompt, buf[0..len], cursor);
            },
            0x7f, 0x08 => { // Backspace
                if (cursor > 0) {
                    std.mem.copyForwards(u8, buf[cursor - 1 .. len - 1], buf[cursor..len]);
                    cursor -= 1;
                    len    -= 1;
                    redraw(prompt, buf[0..len], cursor);
                }
            },
            0x1b => { // ESC — start of escape sequence
                var seq: [3]u8 = undefined;
                if (sysRead(seq[0..1]) != 1 or seq[0] != '[') continue;
                if (sysRead(seq[1..2]) != 1) continue;

                if (seq[1] >= '0' and seq[1] <= '9') {
                    // Extended: ESC [ N ~
                    if (sysRead(seq[2..3]) != 1 or seq[2] != '~') continue;
                    switch (seq[1]) {
                        '1' => { cursor = 0;   redraw(prompt, buf[0..len], cursor); }, // Home
                        '4' => { cursor = len; redraw(prompt, buf[0..len], cursor); }, // End
                        '3' => { // Delete
                            if (cursor < len) {
                                std.mem.copyForwards(u8, buf[cursor..len - 1], buf[cursor + 1..len]);
                                len -= 1;
                                redraw(prompt, buf[0..len], cursor);
                            }
                        },
                        else => {},
                    }
                    continue;
                }

                switch (seq[1]) {
                    'A' => { // Up — history back
                        if (hist_pos == 0) {
                            const n = @min(len, HistMaxLen);
                            @memcpy(saved[0..n], buf[0..n]);
                            saved_len = len;
                        }
                        if (histGet(hist_pos + 1)) |entry| {
                            hist_pos += 1;
                            const n = @min(entry.len, buf.len);
                            @memcpy(buf[0..n], entry[0..n]);
                            len    = n;
                            cursor = len;
                            redraw(prompt, buf[0..len], cursor);
                        }
                    },
                    'B' => { // Down — history forward
                        if (hist_pos == 0) continue;
                        hist_pos -= 1;
                        if (hist_pos == 0) {
                            const n = @min(saved_len, buf.len);
                            @memcpy(buf[0..n], saved[0..n]);
                            len = n;
                        } else if (histGet(hist_pos)) |entry| {
                            const n = @min(entry.len, buf.len);
                            @memcpy(buf[0..n], entry[0..n]);
                            len = n;
                        }
                        cursor = len;
                        redraw(prompt, buf[0..len], cursor);
                    },
                    'C' => { // Right
                        if (cursor < len) {
                            cursor += 1;
                            redraw(prompt, buf[0..len], cursor);
                        }
                    },
                    'D' => { // Left
                        if (cursor > 0) {
                            cursor -= 1;
                            redraw(prompt, buf[0..len], cursor);
                        }
                    },
                    'H' => { cursor = 0;   redraw(prompt, buf[0..len], cursor); }, // Home
                    'F' => { cursor = len; redraw(prompt, buf[0..len], cursor); }, // End
                    else => {},
                }
            },
            else => {
                if (c >= 0x20 and c != 0x7f and len < buf.len) {
                    if (cursor < len) {
                        std.mem.copyBackwards(u8, buf[cursor + 1..len + 1], buf[cursor..len]);
                    }
                    buf[cursor] = c;
                    cursor += 1;
                    len    += 1;
                    redraw(prompt, buf[0..len], cursor);
                }
            },
        }
    }
}
