//! Stack & XOR string decoder: an analysis pass that looks at every function for strings built
//! one immediate at a time on the stack (optionally XORed with a constant byte), comments each
//! one at the instruction that starts building it, and lists them in a "Decoded strings" panel
//! (click a row to jump there). "Decode Stack Strings" re-runs it on demand.
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const reflet = @import("reflet");
const decode = @import("decode.zig");

comptime {
    _ = reflet.exports;
}

const command_rescan = "plugin.xorstrings.rescan";

/// Results survive between calls (the call arena does not), so they live in static storage.
const max_results = 256;
const Result = struct { addr: u64, func: u64, key: u8, len: u8, text: [96]u8 };
var results: [max_results]Result = undefined;
var n_results: usize = 0;

export fn reflet_init() i32 {
    reflet.begin();
    reflet.re.registerPass("Decode stack & XOR strings") catch |e| reflet.logf(.warn, "no analysis pass: {s}", .{@errorName(e)});
    reflet.registerCommand(command_rescan, "Decode Stack Strings", reflet.abi.CommandWhere.palette | reflet.abi.CommandWhere.re_context) catch {};
    return reflet.done(.ok);
}

/// Called by the host for every function after auto-analysis.
export fn reflet_analysis_pass(entry: u64) i32 {
    reflet.begin();
    _ = scanFunction(entry) catch |e| return reflet.fail(e);
    return reflet.done(.ok);
}

export fn reflet_event(kind: i32, ptr: [*]const u8, len: usize) i32 {
    reflet.begin();
    _ = ptr[0..len];
    // all passes ran: show what they found
    if (kind == @intFromEnum(reflet.abi.Event.analysis_done)) publish() catch |e| return reflet.fail(e);
    return reflet.done(.ok);
}

export fn reflet_command(id: [*]const u8, id_len: usize, arg: [*]const u8, arg_len: usize) i32 {
    reflet.begin();
    _ = arg[0..arg_len];
    if (!std.mem.eql(u8, id[0..id_len], command_rescan)) return reflet.done(.unsupported);
    n_results = 0;
    const fs = reflet.re.functions() catch |e| return reflet.fail(e);
    for (fs) |f| _ = scanFunction(f.entry) catch {};
    publish() catch |e| return reflet.fail(e);
    return reflet.done(.ok);
}

fn scanFunction(entry: u64) reflet.Error!usize {
    const blocks = try reflet.re.blocks(entry);
    var found: std.ArrayList(decode.Found) = .empty;
    const chunks = reflet.create(decode.Chunk, blocks.len) orelse return error.OutOfMemory;
    var n: usize = 0;
    for (blocks) |b| {
        const size = b.end - b.start;
        if (size == 0 or size > 1 << 20) continue;
        const buf = reflet.alloc(@intCast(size)) orelse return error.OutOfMemory;
        chunks[n] = .{ .code = try reflet.re.read(b.start, buf), .addr = b.start };
        n += 1;
    }
    decode.scanChunks(reflet.allocator, chunks[0..n], &found) catch return error.OutOfMemory;
    var cbuf: [200]u8 = undefined;
    for (found.items) |f| {
        // one comment per string; a user's own comment is left alone
        if (try reflet.re.get(.comment, f.addr)) |existing| {
            if (!std.mem.startsWith(u8, existing, "stack string") and !std.mem.startsWith(u8, existing, "decoded")) continue;
        }
        try reflet.re.comment(f.addr, decode.comment(&cbuf, f));
        remember(entry, f);
    }
    return found.items.len;
}

fn remember(func: u64, f: decode.Found) void {
    for (results[0..n_results]) |r| if (r.addr == f.addr) return;
    if (n_results == max_results) return;
    var r: Result = .{ .addr = f.addr, .func = func, .key = f.key, .len = @intCast(@min(f.text.len, 96)), .text = undefined };
    @memcpy(r.text[0..r.len], f.text[0..r.len]);
    results[n_results] = r;
    n_results += 1;
}

const Row = struct { cells: []const []const u8, addr: u64 };

fn publish() reflet.Error!void {
    const rows = reflet.create(Row, n_results) orelse return error.OutOfMemory;
    for (results[0..n_results], rows) |*r, *row| {
        const cells = reflet.create([]const u8, 4) orelse return error.OutOfMemory;
        cells[0] = std.fmt.allocPrint(reflet.allocator, "0x{x}", .{r.addr}) catch return error.OutOfMemory;
        const name = try reflet.re.get(.name, r.func);
        cells[1] = name orelse (std.fmt.allocPrint(reflet.allocator, "sub_{x}", .{r.func}) catch return error.OutOfMemory);
        cells[2] = if (r.key == 0) "stack" else (std.fmt.allocPrint(reflet.allocator, "xor 0x{x:0>2}", .{r.key}) catch return error.OutOfMemory);
        cells[3] = r.text[0..r.len];
        row.* = .{ .cells = cells, .addr = r.addr };
    }
    const panel = .{
        .title = "Decoded strings",
        .view = "re",
        .root = .{
            .type = "table",
            .columns = &[_][]const u8{ "Address", "Function", "Encoding", "Text" },
            .rows = rows,
            .empty = "No stack or XOR strings found.",
        },
    };
    try reflet.panelSet("decoded", try reflet.json(panel));
}
