//! Finds TODO / FIXME / HACK markers in text, line by line. Pure std, unit-tested natively.
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");

pub const Tag = enum {
    todo,
    fixme,
    hack,

    pub fn word(t: Tag) []const u8 {
        return switch (t) {
            .todo => "TODO",
            .fixme => "FIXME",
            .hack => "HACK",
        };
    }
};

pub const Mark = struct {
    tag: Tag,
    /// 0-based line.
    line: u32,
    /// Byte offset of the tag in the text.
    offset: usize,
    /// Column of the tag in its line.
    col: u32,
    /// The rest of the line after the tag (":" and spaces trimmed).
    note: []const u8,
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Every marker in `text` (a tag is a whole uppercase word: `TODO`, `TODO:`, `TODO(me)`).
pub fn find(gpa: std.mem.Allocator, text: []const u8) ![]Mark {
    var out: std.ArrayList(Mark) = .empty;
    errdefer out.deinit(gpa);
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i < text.len and text[i] != '\n') continue;
        const l = text[line_start..i];
        for ([_]Tag{ .todo, .fixme, .hack }) |t| {
            const w = t.word();
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, l, from, w)) |at| : (from = at + w.len) {
                if (at > 0 and isWordByte(l[at - 1])) continue;
                if (at + w.len < l.len and isWordByte(l[at + w.len])) continue;
                const note = std.mem.trim(u8, l[at + w.len ..], " \t:-");
                try out.append(gpa, .{ .tag = t, .line = line, .offset = line_start + at, .col = @intCast(at), .note = note });
                break; // one mark per tag per line
            }
        }
        line += 1;
        line_start = i + 1;
    }
    std.mem.sort(Mark, out.items, {}, struct {
        fn lt(_: void, a: Mark, b: Mark) bool {
            return a.offset < b.offset;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// The first mark on a line after the one holding `cursor`, wrapping to the first mark.
pub fn next(marks: []const Mark, text: []const u8, cursor: usize) ?Mark {
    if (marks.len == 0) return null;
    const eol = std.mem.indexOfScalarPos(u8, text, @min(cursor, text.len), '\n') orelse text.len;
    for (marks) |m| if (m.offset > eol) return m;
    return marks[0];
}

const testing = std.testing;

test "find tags as whole words, one per tag per line" {
    const text = "a = 1 // TODO: fix this\nTODOS are not tags\n# FIXME(me) later\nHACK\nxHACK no";
    const ms = try find(testing.allocator, text);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 3), ms.len);
    try testing.expectEqual(Tag.todo, ms[0].tag);
    try testing.expectEqual(@as(u32, 0), ms[0].line);
    try testing.expectEqualStrings("fix this", ms[0].note);
    try testing.expectEqual(Tag.fixme, ms[1].tag);
    try testing.expectEqual(@as(u32, 2), ms[1].line);
    try testing.expectEqual(@as(u32, 2), ms[1].col);
    try testing.expectEqual(@as(u32, 3), ms[2].line);
}

test "next wraps around" {
    const text = "TODO a\nx\nFIXME b\n";
    const ms = try find(testing.allocator, text);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 9), next(ms, text, 0).?.offset);
    try testing.expectEqual(@as(usize, 0), next(ms, text, 10).?.offset);
}
