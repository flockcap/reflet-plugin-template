// SPDX-License-Identifier: MIT
//! Packs a plugin into `<id>-<version>.reflet-plugin`: a zip of exactly `reflet-plugin.toml`,
//! `plugin.wasm` and `assets/**`, the only entries Reflet and the marketplace accept.
//!
//!   pack <plugin dir> <plugin.wasm> <output dir>
//!
//! reads `<plugin dir>/reflet-plugin.toml` and `<plugin dir>/assets/**` and writes
//! `<output dir>/<id>-<version>.reflet-plugin`.
//!
//! Also checks that the manifest names an id and a semantic version, so a broken manifest
//! fails the build instead of the install.
const std = @import("std");
const zipw = @import("zipw.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| try args.append(arena, a);
    if (args.items.len != 3) {
        std.debug.print("usage: pack <plugin dir> <plugin.wasm> <output dir>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const manifest_path = try std.fs.path.join(arena, &.{ args.items[0], "reflet-plugin.toml" });
    const manifest = try cwd.readFileAlloc(io, manifest_path, arena, .limited(64 << 10));
    const wasm = try cwd.readFileAlloc(io, args.items[1], arena, .limited(10 << 20));
    const id = field(manifest, "id") orelse fail("{s}: missing id", .{manifest_path});
    const version = field(manifest, "version") orelse fail("{s}: missing version", .{manifest_path});
    if (!semver(version)) fail("{s}: version \"{s}\" is not MAJOR.MINOR.PATCH", .{ manifest_path, version });
    if (std.mem.indexOfScalar(u8, id, '.') == null) fail("{s}: id \"{s}\" must be reverse-DNS", .{ manifest_path, id });
    if (!std.mem.startsWith(u8, wasm, "\x00asm")) fail("{s} is not a wasm module", .{args.items[1]});

    var w = zipw.Writer.init(gpa);
    defer w.deinit();
    try w.add("reflet-plugin.toml", manifest);
    try w.add("plugin.wasm", wasm);
    {
        const assets = try std.fs.path.join(arena, &.{ args.items[0], "assets" });
        if (cwd.openDir(io, assets, .{ .iterate = true })) |dir_| {
            var dir = dir_;
            defer dir.close(io);
            var names: std.ArrayList([]const u8) = .empty;
            var walker = try dir.walk(arena);
            defer walker.deinit();
            while (try walker.next(io)) |e| {
                if (e.kind != .file) continue;
                try names.append(arena, try arena.dupe(u8, e.path));
            }
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (names.items) |n| {
                const data = try dir.readFileAlloc(io, n, arena, .limited(10 << 20));
                const name = try std.fmt.allocPrint(arena, "assets/{s}", .{n});
                std.mem.replaceScalar(u8, name, '\\', '/');
                try w.add(name, data);
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    const zip = try w.finish();
    defer gpa.free(zip);
    const out = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.reflet-plugin", .{ args.items[2], id, version });
    if (zip.len > 10 << 20) fail("{s} is larger than 10 MB", .{out});
    try cwd.createDirPath(io, args.items[2]);
    try cwd.writeFile(io, .{ .sub_path = out, .data = zip });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("pack: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// The string value of a top-level `key = "value"` line (before the first table header).
pub fn field(toml: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') return null;
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const v = std.mem.trim(u8, rest[1..], " \t");
        if (v.len < 2 or v[0] != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, v, 1, '"') orelse return null;
        return v[1..end];
    }
    return null;
}

fn semver(v: []const u8) bool {
    const core = v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
    var parts = std.mem.splitScalar(u8, core, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

test "field and semver" {
    const t = "id = \"com.example.x\"\nversion = \"1.2.3\"\n[flock]\nid = \"nope\"\n";
    try std.testing.expectEqualStrings("com.example.x", field(t, "id").?);
    try std.testing.expectEqualStrings("1.2.3", field(t, "version").?);
    try std.testing.expect(field(t, "owner") == null);
    try std.testing.expect(semver("0.1.0") and semver("1.0.0-beta.1") and !semver("1.0"));
}
