// SPDX-License-Identifier: MIT
//! A tiny, dependency-free zip writer (std only): stored (uncompressed) entries with CRC-32,
//! a fixed 1980-01-01 timestamp so archives are reproducible. Builds `.reflet-plugin` files in
//! tests, the screenshot tour and the plugin template's `zig build` (this file is copied there
//! verbatim, so it must keep importing nothing but std).
//!
const std = @import("std");

pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    central: std.ArrayList(u8) = .empty,
    count: u16 = 0,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
        w.central.deinit(w.gpa);
    }

    fn le16(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try list.appendSlice(gpa, &b);
    }

    fn le32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try list.appendSlice(gpa, &b);
    }

    /// Add a file (`name` uses '/' separators, no leading slash).
    pub fn add(w: *Writer, name: []const u8, data: []const u8) !void {
        if (data.len > std.math.maxInt(u32) or w.out.items.len > std.math.maxInt(u32) or name.len > std.math.maxInt(u16)) return error.TooLarge;
        if (w.count == std.math.maxInt(u16)) return error.TooManyEntries;
        const crc = std.hash.Crc32.hash(data);
        const offset: u32 = @intCast(w.out.items.len);
        const size: u32 = @intCast(data.len);
        const g = w.gpa;
        // local file header
        try le32(&w.out, g, 0x04034b50);
        try le16(&w.out, g, 20); // version needed
        try le16(&w.out, g, 0); // flags
        try le16(&w.out, g, 0); // method: store
        try le16(&w.out, g, 0); // time
        try le16(&w.out, g, 0x21); // date: 1980-01-01
        try le32(&w.out, g, crc);
        try le32(&w.out, g, size);
        try le32(&w.out, g, size);
        try le16(&w.out, g, @intCast(name.len));
        try le16(&w.out, g, 0);
        try w.out.appendSlice(g, name);
        try w.out.appendSlice(g, data);
        // central directory entry
        try le32(&w.central, g, 0x02014b50);
        try le16(&w.central, g, (3 << 8) | 20); // made by: unix, 2.0
        try le16(&w.central, g, 20);
        try le16(&w.central, g, 0);
        try le16(&w.central, g, 0);
        try le16(&w.central, g, 0);
        try le16(&w.central, g, 0x21);
        try le32(&w.central, g, crc);
        try le32(&w.central, g, size);
        try le32(&w.central, g, size);
        try le16(&w.central, g, @intCast(name.len));
        try le16(&w.central, g, 0); // extra
        try le16(&w.central, g, 0); // comment
        try le16(&w.central, g, 0); // disk
        try le16(&w.central, g, 0); // internal attrs
        try le32(&w.central, g, 0o100644 << 16); // regular file, rw-r--r--
        try le32(&w.central, g, offset);
        try w.central.appendSlice(g, name);
        w.count += 1;
    }

    /// The finished archive (caller frees with the writer's allocator); the writer is reset.
    pub fn finish(w: *Writer) ![]u8 {
        const g = w.gpa;
        const cd_offset: u32 = @intCast(w.out.items.len);
        const cd_size: u32 = @intCast(w.central.items.len);
        try w.out.appendSlice(g, w.central.items);
        try le32(&w.out, g, 0x06054b50);
        try le16(&w.out, g, 0);
        try le16(&w.out, g, 0);
        try le16(&w.out, g, w.count);
        try le16(&w.out, g, w.count);
        try le32(&w.out, g, cd_size);
        try le32(&w.out, g, cd_offset);
        try le16(&w.out, g, 0);
        w.central.clearRetainingCapacity();
        w.count = 0;
        return w.out.toOwnedSlice(g);
    }
};

test "writes a well-formed archive" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.add("a.txt", "hello");
    try w.add("dir/b.bin", &.{ 0, 1, 2 });
    const z = try w.finish();
    defer std.testing.allocator.free(z);
    try std.testing.expect(std.mem.startsWith(u8, z, "PK\x03\x04"));
    const eocd = z[z.len - 22 ..];
    try std.testing.expect(std.mem.startsWith(u8, eocd, "PK\x05\x06"));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, eocd[10..12], .little));
}
