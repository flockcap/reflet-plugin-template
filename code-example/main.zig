//! TODO highlighter: marks TODO / FIXME / HACK in the gutter, reports them as diagnostics, keeps
//! a count in the status bar, and adds "Go to Next TODO" (palette and editor context menu).
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const reflet = @import("reflet");
const todo = @import("todo.zig");

comptime {
    _ = reflet.exports;
}

const command_next = "plugin.todo.next";

export fn reflet_init() i32 {
    reflet.begin();
    // without the commands capability the plugin still marks TODOs
    reflet.registerCommand(command_next, "Go to Next TODO", reflet.abi.CommandWhere.palette | reflet.abi.CommandWhere.editor_context) catch |e|
        reflet.logf(.warn, "Go to Next TODO unavailable: {s}", .{@errorName(e)});
    return reflet.done(.ok);
}

/// Re-mark the document whenever it opens, changes or becomes active.
export fn reflet_event(kind: i32, ptr: [*]const u8, len: usize) i32 {
    reflet.begin();
    const path = ptr[0..len];
    const ev: reflet.abi.Event = @enumFromInt(kind);
    switch (ev) {
        .document_opened, .document_changed, .active_document => {
            if (path.len == 0) return reflet.done(.ok);
            mark(path) catch |e| return reflet.fail(e);
        },
        else => {},
    }
    return reflet.done(.ok);
}

fn tone(t: todo.Tag) []const u8 {
    return switch (t) {
        .todo => "info",
        .fixme => "err",
        .hack => "warn",
    };
}

fn severity(t: todo.Tag) []const u8 {
    return switch (t) {
        .todo => "info",
        .fixme => "warning",
        .hack => "hint",
    };
}

fn mark(path: []const u8) reflet.Error!void {
    const info = try reflet.doc.info();
    // events may name a document that is no longer the active one
    if (!std.mem.eql(u8, info.path, path)) return;
    const text = try reflet.doc.text();
    const marks = todo.find(reflet.allocator, text) catch return error.OutOfMemory;
    const decos = reflet.create(reflet.doc.Decoration, marks.len * 2) orelse return error.OutOfMemory;
    const diags = reflet.create(reflet.doc.Diagnostic, marks.len) orelse return error.OutOfMemory;
    for (marks, 0..) |m, i| {
        decos[2 * i] = .{ .line = m.line, .kind = "gutter", .tone = tone(m.tag), .text = m.tag.word()[0..1] };
        decos[2 * i + 1] = .{ .line = m.line, .kind = "highlight", .tone = tone(m.tag) };
        const msg = std.fmt.allocPrint(reflet.allocator, "{s}: {s}", .{ m.tag.word(), if (m.note.len > 0) m.note else "(no note)" }) catch return error.OutOfMemory;
        diags[i] = .{ .line = m.line, .col = m.col, .end_col = m.col + @as(u32, @intCast(m.tag.word().len)), .severity = severity(m.tag), .message = msg, .code = m.tag.word() };
    }
    try reflet.doc.decorate(path, decos);
    try reflet.doc.diagnostics(path, diags);
    var buf: [48]u8 = undefined;
    const label = if (marks.len == 0) "" else std.fmt.bufPrint(&buf, "{d} TODO{s}", .{ marks.len, if (marks.len == 1) "" else "s" }) catch "";
    reflet.statusSet("count", label, .info) catch {};
}

export fn reflet_command(id: [*]const u8, id_len: usize, arg: [*]const u8, arg_len: usize) i32 {
    reflet.begin();
    _ = arg[0..arg_len];
    if (!std.mem.eql(u8, id[0..id_len], command_next)) return reflet.done(.unsupported);
    goNext() catch |e| return reflet.fail(e);
    return reflet.done(.ok);
}

fn goNext() reflet.Error!void {
    const text = try reflet.doc.text();
    const sels = try reflet.doc.selections();
    const cursor: usize = if (sels.len > 0) sels[0].head else 0;
    const marks = todo.find(reflet.allocator, text) catch return error.OutOfMemory;
    const m = todo.next(marks, text, cursor) orelse return;
    try reflet.doc.moveTo(@intCast(m.offset));
}
