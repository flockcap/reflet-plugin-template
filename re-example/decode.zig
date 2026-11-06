//! Finds strings that a function builds on the stack one immediate at a time (`mov byte
//! [rbp-0x20], 0x48`, `mov dword [rsp+0x10], 0x6c6c6548`, ...) and, when the function also
//! XORs with a constant byte, the XOR-obfuscated ones. x86 / x86-64 encodings; pure std so it
//! is unit-tested natively.
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");

pub const Found = struct {
    /// Address of the first store that builds the string.
    addr: u64,
    /// Decoded text (no terminating NUL).
    text: []const u8,
    /// 0 for a plain stack string.
    key: u8,
};

const Store = struct {
    /// Stack offset (rbp/rsp relative; the two bases are kept apart).
    off: i64,
    base: u8,
    addr: u64,
    bytes: [8]u8,
    len: u8,
};

/// Decode one stack store of an immediate at `code[i..]`; returns it and the instruction length.
fn store(code: []const u8, i: usize, addr: u64) ?struct { s: Store, len: usize } {
    var p = i;
    var width: u8 = 4;
    if (p < code.len and code[p] == 0x66) {
        width = 2;
        p += 1;
    }
    if (p + 3 > code.len) return null;
    const op = code[p];
    if (op != 0xC6 and op != 0xC7) return null;
    if (op == 0xC6) {
        if (width == 2) return null;
        width = 1;
    }
    const modrm = code[p + 1];
    const mod = modrm >> 6;
    const reg = (modrm >> 3) & 7;
    const rm = modrm & 7;
    if (reg != 0 or mod == 0 or mod == 3) return null;
    var q = p + 2;
    var base: u8 = 0;
    if (rm == 4) {
        // SIB: only [rsp + disp]
        if (q >= code.len or code[q] != 0x24) return null;
        base = 1;
        q += 1;
    } else if (rm != 5) return null; // rbp
    var disp: i64 = 0;
    if (mod == 1) {
        if (q + 1 > code.len) return null;
        disp = @as(i8, @bitCast(code[q]));
        q += 1;
    } else {
        if (q + 4 > code.len) return null;
        disp = std.mem.readInt(i32, code[q..][0..4], .little);
        q += 4;
    }
    if (q + width > code.len) return null;
    var s: Store = .{ .off = disp, .base = base, .addr = addr, .bytes = undefined, .len = width };
    @memcpy(s.bytes[0..width], code[q..][0..width]);
    return .{ .s = s, .len = q + width - i };
}

/// XOR keys used with an 8-bit immediate in `code` (xor al/r8/r32, imm8 forms).
pub fn xorKeys(code: []const u8, out: *[8]u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 1) {
        var key: ?u8 = null;
        if (code[i] == 0x34) key = code[i + 1] // xor al, imm8
        else if (i + 2 < code.len and (code[i] == 0x80 or code[i] == 0x83) and (code[i + 1] & 0xF8) == 0xF0) key = code[i + 2]; // xor r, imm8
        const k = key orelse continue;
        if (k == 0 or n == out.len) continue;
        if (std.mem.indexOfScalar(u8, out[0..n], k) == null) {
            out[n] = k;
            n += 1;
        }
    }
    return out[0..n];
}

fn printable(s: []const u8) bool {
    if (s.len < 4) return false;
    var letters: usize = 0;
    for (s) |c| {
        if (c < 0x20 or c > 0x7e) return false;
        if (std.ascii.isAlphanumeric(c)) letters += 1;
    }
    return letters * 2 >= s.len;
}

/// Trim at the first NUL.
fn untilNul(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// A piece of a function's code (one basic block) at `addr`.
pub const Chunk = struct { code: []const u8, addr: u64 };

/// Scan the code of one function (`code` starts at `base_addr`). Strings are appended to
/// `out` (texts allocated with `gpa`).
pub fn scan(gpa: std.mem.Allocator, code: []const u8, base_addr: u64, out: *std.ArrayList(Found)) !void {
    return scanChunks(gpa, &.{.{ .code = code, .addr = base_addr }}, out);
}

/// Scan a whole function given as its blocks: the stores may sit in one block and the XOR
/// that decodes them in the loop block after it.
pub fn scanChunks(gpa: std.mem.Allocator, chunks: []const Chunk, out: *std.ArrayList(Found)) !void {
    var stores: std.ArrayList(Store) = .empty;
    defer stores.deinit(gpa);
    var keys_buf: [8]u8 = undefined;
    var n_keys: usize = 0;
    for (chunks) |ch| {
        const code = ch.code;
        var i: usize = 0;
        while (i < code.len) {
            if (store(code, i, ch.addr + i)) |r| {
                // `mov dword [rbp-x], 0` is a counter or a pointer being cleared, not text
                const zero = r.s.len >= 2 and std.mem.allEqual(u8, r.s.bytes[0..r.s.len], 0);
                if (!zero) try stores.append(gpa, r.s);
                i += r.len;
            } else i += 1;
        }
        var kb: [8]u8 = undefined;
        for (xorKeys(code, &kb)) |k| {
            if (n_keys < keys_buf.len and std.mem.indexOfScalar(u8, keys_buf[0..n_keys], k) == null) {
                keys_buf[n_keys] = k;
                n_keys += 1;
            }
        }
    }
    if (stores.items.len == 0) return;
    std.mem.sort(Store, stores.items, {}, struct {
        fn lt(_: void, a: Store, b: Store) bool {
            return if (a.base != b.base) a.base < b.base else a.off < b.off;
        }
    }.lt);
    const keys = keys_buf[0..n_keys];

    // runs of adjacent stores on the same base
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(gpa);
    var start: usize = 0;
    while (start < stores.items.len) {
        run.clearRetainingCapacity();
        var first_addr = stores.items[start].addr;
        var end = start;
        var next_off = stores.items[start].off;
        while (end < stores.items.len and stores.items[end].base == stores.items[start].base and stores.items[end].off == next_off) : (end += 1) {
            const s = stores.items[end];
            try run.appendSlice(gpa, s.bytes[0..s.len]);
            next_off += s.len;
            first_addr = @min(first_addr, s.addr);
        }
        if (end == start) end = start + 1;
        start = end;
        if (run.items.len < 4) continue;
        // the plain bytes and every XOR key the function uses compete; the most text-like wins
        var best: ?[]u8 = null;
        var best_key: u8 = 0;
        var best_score: usize = 0;
        if (score(untilNul(run.items))) |sc| {
            best = try gpa.dupe(u8, untilNul(run.items));
            best_score = sc;
        }
        for (keys) |k| {
            const dec = try gpa.alloc(u8, run.items.len);
            defer gpa.free(dec);
            for (run.items, dec) |b, *d| d.* = b ^ k;
            const t = untilNul(dec);
            const sc = score(t) orelse continue;
            if (sc > best_score) {
                if (best) |b| gpa.free(b);
                best = try gpa.dupe(u8, t);
                best_key = k;
                best_score = sc;
            }
        }
        if (best) |text| try out.append(gpa, .{ .addr = first_addr, .text = text, .key = best_key });
    }
}

/// How text-like `s` is (letters, digits and spaces count; other printables do not), or null
/// when it is too short or not printable.
fn score(s: []const u8) ?usize {
    if (!printable(s)) return null;
    var n: usize = 0;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == ' ') n += 2;
        if (std.ascii.isLower(c)) n += 1;
    }
    return n;
}

/// The comment the plugin writes at the first store.
pub fn comment(buf: []u8, f: Found) []const u8 {
    if (f.key == 0) return std.fmt.bufPrint(buf, "stack string: \"{s}\"", .{f.text}) catch "stack string";
    return std.fmt.bufPrint(buf, "decoded (xor 0x{x:0>2}): \"{s}\"", .{ f.key, f.text }) catch "decoded string";
}

const testing = std.testing;

fn freeAll(list: *std.ArrayList(Found)) void {
    for (list.items) |f| testing.allocator.free(f.text);
    list.deinit(testing.allocator);
}

test "plain stack string from byte stores on rbp" {
    // mov byte [rbp-8], 'c' ... 'd', 0
    const code = [_]u8{ 0xC6, 0x45, 0xF8, 'c', 0xC6, 0x45, 0xF9, 'm', 0xC6, 0x45, 0xFA, 'd', 0xC6, 0x45, 0xFB, '.', 0xC6, 0x45, 0xFC, 'x', 0xC6, 0x45, 0xFD, 0 };
    var out: std.ArrayList(Found) = .empty;
    defer freeAll(&out);
    try scan(testing.allocator, &code, 0x1000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("cmd.x", out.items[0].text);
    try testing.expectEqual(@as(u64, 0x1000), out.items[0].addr);
}

test "xor-obfuscated dword stores on rsp with an xor eax, imm8" {
    const key: u8 = 0x5a;
    const plain = "Hello!!!";
    var enc: [8]u8 = undefined;
    for (plain, &enc) |c, *e| e.* = c ^ key;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(testing.allocator);
    // mov dword [rsp+0x10], enc[0..4]; mov dword [rsp+0x14], enc[4..8]; xor eax, 0x5a
    try code.appendSlice(testing.allocator, &.{ 0xC7, 0x44, 0x24, 0x10 });
    try code.appendSlice(testing.allocator, enc[0..4]);
    try code.appendSlice(testing.allocator, &.{ 0xC7, 0x44, 0x24, 0x14 });
    try code.appendSlice(testing.allocator, enc[4..8]);
    try code.appendSlice(testing.allocator, &.{ 0x83, 0xF0, key });
    var out: std.ArrayList(Found) = .empty;
    defer freeAll(&out);
    try scan(testing.allocator, code.items, 0x2000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("Hello!!!", out.items[0].text);
    try testing.expectEqual(key, out.items[0].key);
    var b: [128]u8 = undefined;
    try testing.expectEqualStrings("decoded (xor 0x5a): \"Hello!!!\"", comment(&b, out.items[0]));
}

test "the key may live in another block" {
    const key: u8 = 0x21;
    var code1: [16]u8 = undefined;
    for ("abcd", 0..) |c, i| {
        code1[i * 4 ..][0..4].* = .{ 0xC6, 0x45, @intCast(0xF0 + i), c ^ key };
    }
    const code2 = [_]u8{ 0x34, key, 0xC3 };
    var out: std.ArrayList(Found) = .empty;
    defer freeAll(&out);
    try scanChunks(testing.allocator, &.{ .{ .code = &code1, .addr = 0x10 }, .{ .code = &code2, .addr = 0x40 } }, &out);
    try testing.expectEqualStrings("abcd", out.items[0].text);
}

test "a zeroed counter next to the string does not hide it" {
    // mov dword [rbp-12], 0 ; mov byte [rbp-8..-4], "cmd.x"
    const code = [_]u8{ 0xC7, 0x45, 0xF4, 0, 0, 0, 0, 0xC6, 0x45, 0xF8, 'c', 0xC6, 0x45, 0xF9, 'm', 0xC6, 0x45, 0xFA, 'd', 0xC6, 0x45, 0xFB, '.', 0xC6, 0x45, 0xFC, 'x' };
    var out: std.ArrayList(Found) = .empty;
    defer freeAll(&out);
    try scan(testing.allocator, &code, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("cmd.x", out.items[0].text);
}

test "noise is ignored" {
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xE5, 0xC6, 0x45, 0xF8, 0x01, 0xC6, 0x45, 0xF9, 0x02, 0x5D, 0xC3 };
    var out: std.ArrayList(Found) = .empty;
    defer freeAll(&out);
    try scan(testing.allocator, &code, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
