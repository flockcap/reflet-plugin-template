// SPDX-License-Identifier: MIT
//! Guest-side SDK for Reflet plugins (wasm32-freestanding). Import as `reflet`:
//! `const reflet = @import("reflet");` and reference `reflet.exports` from the plugin root
//! (`comptime { _ = reflet.exports; }`). The ABI itself is `reflet.abi`
//! (sdk/abi.zig, shared with the Reflet host).
//!
//! Memory: a bump arena over linear memory that grows with `memory.grow`. The host copies
//! inputs in with `reflet_alloc` *before* calling an entry point and copies results out right
//! after it returns, so the arena is reset by the first `reflet_alloc` (or `begin`) after an
//! entry point has returned (`ret` / `retStatus` mark that), never in the middle of a call.
//!
//! Entry points look like:
//! ```zig
//! export fn reflet_theme() i64 {
//!     reflet.begin();
//!     return reflet.ret(theme_text);
//! }
//! ```
//!
const std = @import("std");
pub const abi = @import("reflet_abi");

// ---- host imports ---------------------------------------------------------------------------

/// Raw host imports (module "reflet"); prefer the typed helpers below.
pub const host = struct {
    pub extern "reflet" fn log(level: i32, ptr: [*]const u8, len: usize) void;
    pub extern "reflet" fn now_ms() i64;
    pub extern "reflet" fn fs_size(path: [*]const u8, path_len: usize) i64;
    pub extern "reflet" fn fs_read(path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn fs_write(path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) i32;
    pub extern "reflet" fn net_connect(host_name: [*]const u8, host_len: usize, port: i32) i32;
    pub extern "reflet" fn net_send(handle: i32, ptr: [*]const u8, len: usize) i32;
    pub extern "reflet" fn net_recv(handle: i32, ptr: [*]u8, cap: usize) i32;
    pub extern "reflet" fn net_close(handle: i32) void;
    pub extern "reflet" fn process_run(argv: [*]const u8, argv_len: usize, out: [*]u8, cap: usize) i32;

    // API v1 (docs/plugins/API.md). Getters return the full length and copy at most `cap`.
    pub extern "reflet" fn notify(level: i32, ptr: [*]const u8, len: usize) i32;
    pub extern "reflet" fn setting_get(key: [*]const u8, key_len: usize, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn setting_set(key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) i32;
    pub extern "reflet" fn storage_read(name: [*]const u8, name_len: usize, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn storage_write(name: [*]const u8, name_len: usize, data: [*]const u8, len: usize) i32;
    pub extern "reflet" fn net_fetch(method: i32, url: [*]const u8, url_len: usize, body: [*]const u8, body_len: usize, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn register_command(id: [*]const u8, id_len: usize, title: [*]const u8, title_len: usize, where: i32) i32;
    pub extern "reflet" fn panel_set(id: [*]const u8, id_len: usize, json: [*]const u8, json_len: usize) i32;
    pub extern "reflet" fn status_set(id: [*]const u8, id_len: usize, text: [*]const u8, text_len: usize, tone: i32) i32;
    pub extern "reflet" fn re_info(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_read(addr: u64, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_segments(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_functions(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_blocks(entry: u64, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_il(addr: u64, level: i32, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_xrefs(addr: u64, dir: i32, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_get(what: i32, addr: u64, out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn re_set(what: i32, addr: u64, ptr: [*]const u8, len: usize) i32;
    pub extern "reflet" fn re_goto(addr: u64) i32;
    pub extern "reflet" fn register_pass(name: [*]const u8, name_len: usize) i32;
    pub extern "reflet" fn doc_info(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn doc_text(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn doc_selections(out: [*]u8, cap: usize) i32;
    pub extern "reflet" fn doc_edit(json: [*]const u8, len: usize) i32;
    pub extern "reflet" fn doc_select(ptr: [*]const u8, len: usize) i32;
    pub extern "reflet" fn decorations_set(path: [*]const u8, path_len: usize, json: [*]const u8, json_len: usize) i32;
    pub extern "reflet" fn diagnostics_set(path: [*]const u8, path_len: usize, json: [*]const u8, json_len: usize) i32;
};

/// Host failures as Zig errors (`Status` without `ok`).
pub const Error = error{ Denied, Pending, NotFound, Io, TooLarge, Invalid, Unsupported, TimedOut, OutOfMemory };

pub fn errorOf(code: i64) Error {
    return switch (code) {
        abi.Status.denied.code() => error.Denied,
        abi.Status.pending.code() => error.Pending,
        abi.Status.not_found.code() => error.NotFound,
        abi.Status.too_large.code() => error.TooLarge,
        abi.Status.invalid.code() => error.Invalid,
        abi.Status.unsupported.code() => error.Unsupported,
        abi.Status.timed_out.code() => error.TimedOut,
        else => error.Io,
    };
}

pub fn statusOf(err: Error) abi.Status {
    return switch (err) {
        error.Denied => .denied,
        error.Pending => .pending,
        error.NotFound => .not_found,
        error.Io => .io,
        error.TooLarge, error.OutOfMemory => .too_large,
        error.Invalid => .invalid,
        error.Unsupported => .unsupported,
        error.TimedOut => .timed_out,
    };
}

pub fn log(level: abi.LogLevel, msg: []const u8) void {
    host.log(@backingInt(level), msg.ptr, msg.len);
}

/// `log` with formatting (message truncated to 512 bytes).
pub fn logf(level: abi.LogLevel, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    log(level, msg);
}

pub fn nowMs() i64 {
    return host.now_ms();
}

/// Size of a file (capability fs_read).
pub fn fileSize(path: []const u8) Error!u64 {
    const n = host.fs_size(path.ptr, path.len);
    if (n < 0) return errorOf(n);
    return @intCast(n);
}

/// Read a whole file into the arena (capability fs_read). Files larger than `max` are
/// `error.TooLarge`.
pub fn readFile(path: []const u8, max: usize) Error![]u8 {
    const size = try fileSize(path);
    if (size > max) return error.TooLarge;
    const buf = alloc(@intCast(size)) orelse return error.OutOfMemory;
    const n = host.fs_read(path.ptr, path.len, buf.ptr, buf.len);
    if (n < 0) return errorOf(n);
    return buf[0..@intCast(n)];
}

/// Create or truncate a file (capability fs_write).
pub fn writeFile(path: []const u8, data: []const u8) Error!void {
    const n = host.fs_write(path.ptr, path.len, data.ptr, data.len);
    if (n < 0) return errorOf(n);
}

/// A TCP connection (capability net, "host:port").
pub const Conn = struct {
    handle: i32,

    pub fn open(host_name: []const u8, port: u16) Error!Conn {
        const h = host.net_connect(host_name.ptr, host_name.len, port);
        if (h < 0) return errorOf(h);
        return .{ .handle = h };
    }

    pub fn send(c: Conn, data: []const u8) Error!usize {
        const n = host.net_send(c.handle, data.ptr, data.len);
        if (n < 0) return errorOf(n);
        return @intCast(n);
    }

    /// 0 = closed by the peer.
    pub fn recv(c: Conn, buf: []u8) Error!usize {
        const n = host.net_recv(c.handle, buf.ptr, buf.len);
        if (n < 0) return errorOf(n);
        return @intCast(n);
    }

    pub fn close(c: Conn) void {
        host.net_close(c.handle);
    }
};

pub const ProcessResult = struct {
    exit_code: i32,
    /// Captured stdout (truncated to the buffer passed in).
    stdout: []const u8,
    /// Full stdout length before truncation.
    stdout_len: usize,
};

/// Run a program to completion (capability process, argv[0]); stdout lands in `out`.
pub fn run(argv: []const []const u8, out: []u8) Error!ProcessResult {
    var len: usize = 0;
    for (argv) |a| len += a.len + 1;
    const packed_argv = alloc(len) orelse return error.OutOfMemory;
    var i: usize = 0;
    for (argv) |a| {
        @memcpy(packed_argv[i..][0..a.len], a);
        packed_argv[i + a.len] = 0;
        i += a.len + 1;
    }
    const n = host.process_run(packed_argv.ptr, packed_argv.len, out.ptr, out.len);
    if (n < 0) return errorOf(n);
    const used: usize = @intCast(n);
    const hs = @sizeOf(abi.ProcessHeader);
    return .{
        .exit_code = std.mem.readInt(i32, out[0..4], .little),
        .stdout_len = std.mem.readInt(u32, out[4..8], .little),
        .stdout = out[hs..used],
    };
}

// ---- memory -----------------------------------------------------------------------------------

const page = 64 * 1024;

/// Arena start (the end of the module's initial memory) and bump pointer.
var base: usize = 0;
var top: usize = 0;
/// Set when an entry point returns: the next allocation starts a fresh arena.
var finished: bool = true;

fn capacity() usize {
    return @wasmMemorySize(0) * page;
}

fn ensure(end: usize) bool {
    const cap = capacity();
    if (end <= cap) return true;
    const need = (end - cap + page - 1) / page;
    return @wasmMemoryGrow(0, need) >= 0;
}

/// Start a new call's arena if the previous call has finished (call at the top of every entry
/// point; `reflet_alloc` does it too).
pub fn begin() void {
    if (!finished) return;
    if (base == 0) base = capacity();
    top = base;
    finished = false;
}

/// Bump-allocate `len` bytes (16-aligned), growing memory as needed. Null when the host's
/// memory limit is reached.
pub fn alloc(len: usize) ?[]u8 {
    begin();
    const start = std.mem.alignForward(usize, top, 16);
    const end = std.math.add(usize, start, len) catch return null;
    if (!ensure(end)) return null;
    top = end;
    return @as([*]u8, @ptrFromInt(start))[0..len];
}

/// Like `alloc`, typed.
pub fn create(comptime T: type, n: usize) ?[]T {
    const bytes = alloc(std.math.mul(usize, n, @sizeOf(T)) catch return null) orelse return null;
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}

fn vAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const s = alloc(len) orelse return null;
    return s.ptr;
}

fn vResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // only the newest allocation can change size in place
    const start = @intFromPtr(memory.ptr);
    if (start + memory.len != top) return new_len <= memory.len;
    const end = std.math.add(usize, start, new_len) catch return false;
    if (!ensure(end)) return false;
    top = end;
    return true;
}

fn vRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (vResize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
}

fn vFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const start = @intFromPtr(memory.ptr);
    if (start + memory.len == top) top = start;
}

/// The arena as a `std.mem.Allocator` (frees only the newest allocation; everything is
/// dropped when the next call starts).
pub const allocator: std.mem.Allocator = .{
    .ptr = @ptrFromInt(16),
    .vtable = &.{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree },
};

/// Return `data` (guest memory) from an entry point.
pub fn ret(data: []const u8) i64 {
    finished = true;
    return abi.pack(@intCast(@intFromPtr(data.ptr)), @intCast(data.len));
}

/// Return a failure status from an entry point.
pub fn retStatus(s: abi.Status) i64 {
    finished = true;
    return abi.packStatus(s);
}

/// Copy a string into the arena (for building results).
pub fn dupe(s: []const u8) ?[]u8 {
    const out = alloc(s.len) orelse return null;
    @memcpy(out, s);
    return out;
}

// ---- result builders --------------------------------------------------------------------------

/// Output of `reflet_tool_run`: a `ToolHeader` followed by text.
pub fn toolResult(status: abi.Status, format: abi.ToolOutput, text: []const u8) i64 {
    const hs = @sizeOf(abi.ToolHeader);
    const out = alloc(hs + text.len) orelse return retStatus(.too_large);
    std.mem.writeInt(i32, out[0..4], status.code(), .little);
    std.mem.writeInt(u32, out[4..8], @backingInt(format), .little);
    @memcpy(out[hs..], text);
    return ret(out);
}

/// Output of `reflet_arch_decode`: an `InsnHeader` followed by "mnemonic\toperands".
pub fn insnResult(len: u32, flow: abi.InsnFlow, target: ?u64, text: []const u8) i64 {
    const hs = @sizeOf(abi.InsnHeader);
    const out = alloc(hs + text.len) orelse return retStatus(.too_large);
    std.mem.writeInt(u32, out[0..4], len, .little);
    std.mem.writeInt(u32, out[4..8], @backingInt(flow), .little);
    std.mem.writeInt(u64, out[8..16], target orelse 0, .little);
    std.mem.writeInt(u32, out[16..20], @intFromBool(target != null), .little);
    std.mem.writeInt(u32, out[20..24], @intCast(text.len), .little);
    @memcpy(out[hs..], text);
    return ret(out);
}

/// Collects `SpanRecord`s for `reflet_highlight`.
pub const Spans = struct {
    list: std.ArrayList(abi.SpanRecord) = .empty,

    pub fn add(s: *Spans, start: usize, end: usize, kind: abi.Token) void {
        if (end <= start) return;
        s.list.append(allocator, .{ .start = @intCast(start), .end = @intCast(end), .kind = @backingInt(kind) }) catch {};
    }

    pub fn result(s: *Spans) i64 {
        return ret(std.mem.sliceAsBytes(s.list.items));
    }
};

/// Text builder in the arena.
pub const Text = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn write(t: *Text, s: []const u8) void {
        t.list.appendSlice(allocator, s) catch {};
    }

    pub fn print(t: *Text, comptime fmt: []const u8, args: anytype) void {
        t.list.print(allocator, fmt, args) catch {};
    }

    pub fn bytes(t: *const Text) []const u8 {
        return t.list.items;
    }
};

/// The exports every plugin needs; `comptime { _ = reflet.exports; }` in the plugin root.
pub const exports = struct {
    export fn reflet_abi_version() i32 {
        return abi.version;
    }
    export fn reflet_alloc(len: i32) i32 {
        if (len < 0) return 0;
        const s = alloc(@intCast(len)) orelse return 0;
        return @intCast(@intFromPtr(s.ptr));
    }
};

// ---- API v1 helpers ---------------------------------------------------------------------------
//
// Every helper allocates in the call arena (dropped when the entry point returns). Host
// imports are only linked into the plugin when a helper that uses them is referenced, so a
// plugin imports exactly the host functions it calls.

fn check(n: i32) Error!usize {
    if (n < 0) return errorOf(n);
    return @intCast(n);
}

var empty_buf: [1]u8 = undefined;

/// Call a getter twice: once to size, once to fill.
fn getAll(comptime f: anytype, args: anytype) Error![]u8 {
    const n = try check(@call(.auto, f, args ++ .{ @as([*]u8, &empty_buf), @as(usize, 0) }));
    const buf = alloc(n) orelse return error.OutOfMemory;
    const m = try check(@call(.auto, f, args ++ .{ buf.ptr, buf.len }));
    return buf[0..@min(n, m)];
}

fn records(comptime T: type, bytes: []u8) []T {
    const aligned: []align(1) T = std.mem.bytesAsSlice(T, bytes[0 .. bytes.len - bytes.len % @sizeOf(T)]);
    const out = create(T, aligned.len) orelse return &.{};
    for (aligned, out) |x, *o| o.* = x;
    return out;
}

// common

/// A notification toast (capability notify).
pub fn notify(level: abi.LogLevel, msg: []const u8) Error!void {
    _ = try check(host.notify(@backingInt(level), msg.ptr, msg.len));
}

/// This plugin's setting `key`, or null when unset (capability settings).
pub fn settingGet(key: []const u8) Error!?[]u8 {
    return getAll(host.setting_get, .{ key.ptr, key.len }) catch |e| switch (e) {
        error.NotFound => null,
        else => e,
    };
}

pub fn settingSet(key: []const u8, value: []const u8) Error!void {
    _ = try check(host.setting_set(key.ptr, key.len, value.ptr, value.len));
}

/// A file in this plugin's private storage folder, or null (capability storage).
pub fn storageRead(name: []const u8) Error!?[]u8 {
    return getAll(host.storage_read, .{ name.ptr, name.len }) catch |e| switch (e) {
        error.NotFound => null,
        else => e,
    };
}

pub fn storageWrite(name: []const u8, data: []const u8) Error!void {
    _ = try check(host.storage_write(name.ptr, name.len, data.ptr, data.len));
}

pub const Response = struct { status: u32, body: []const u8, truncated: bool };

/// HTTPS request (capability `net.fetch:<host>` for the URL's host). Bodies up to `max`.
pub fn fetch(method: abi.FetchMethod, url: []const u8, body: []const u8, max: usize) Error!Response {
    const hs = @sizeOf(abi.FetchHeader);
    const out = alloc(hs + max) orelse return error.OutOfMemory;
    const n = try check(host.net_fetch(@backingInt(method), url.ptr, url.len, body.ptr, body.len, out.ptr, out.len));
    const full = std.mem.readInt(u32, out[4..8], .little);
    return .{ .status = std.mem.readInt(u32, out[0..4], .little), .body = out[hs..n], .truncated = full > n - hs };
}

/// Add a command to the palette (`where`: `abi.CommandWhere` bits). Ids start with "plugin.";
/// the host calls `reflet_command(id, arg)` when it runs. Capability commands.
pub fn registerCommand(id: []const u8, title: []const u8, where: i32) Error!void {
    _ = try check(host.register_command(id.ptr, id.len, title.ptr, title.len, where));
}

/// Create or replace a panel from its JSON description (API.md "Panels"). Capability ui.panel
/// (or re.view for `"view":"re"` panels).
pub fn panelSet(id: []const u8, description: []const u8) Error!void {
    _ = try check(host.panel_set(id.ptr, id.len, description.ptr, description.len));
}

/// Show (or with empty text, remove) a status bar item. Capability ui.statusbar.
pub fn statusSet(id: []const u8, text: []const u8, tone: abi.Tone) Error!void {
    _ = try check(host.status_set(id.ptr, id.len, text.ptr, text.len, @backingInt(tone)));
}

// reverse engineering (capability analysis.read unless noted)

pub const re = struct {
    pub const Info = struct { path: []const u8 = "", format: []const u8 = "", arch: []const u8 = "", bits: u8 = 0, entry: ?u64 = null };

    pub fn info() Error!Info {
        const raw = try getAll(host.re_info, .{});
        return std.json.parseFromSliceLeaky(Info, allocator, raw, .{ .ignore_unknown_fields = true }) catch error.Invalid;
    }

    /// Mapped bytes at `addr` (fewer than `buf.len` at the end of a segment).
    pub fn read(addr: u64, buf: []u8) Error![]u8 {
        return buf[0..try check(host.re_read(addr, buf.ptr, buf.len))];
    }

    pub fn segments() Error![]abi.SegmentRecord {
        return records(abi.SegmentRecord, try getAll(host.re_segments, .{}));
    }

    pub fn functions() Error![]abi.FunctionRecord {
        return records(abi.FunctionRecord, try getAll(host.re_functions, .{}));
    }

    pub fn blocks(entry: u64) Error![]abi.BlockRecord {
        return records(abi.BlockRecord, try getAll(host.re_blocks, .{entry}));
    }

    /// IL / pseudo-C text of the function containing `addr`.
    pub fn il(addr: u64, level: abi.IlLevel) Error![]u8 {
        return getAll(host.re_il, .{ addr, @as(i32, @backingInt(level)) });
    }

    pub fn xrefsTo(addr: u64) Error![]abi.XrefRecord {
        return records(abi.XrefRecord, try getAll(host.re_xrefs, .{ addr, @as(i32, 0) }));
    }

    pub fn xrefsFrom(addr: u64) Error![]abi.XrefRecord {
        return records(abi.XrefRecord, try getAll(host.re_xrefs, .{ addr, @as(i32, 1) }));
    }

    /// Name, comment or type at `addr`, null when unset.
    pub fn get(what: abi.Annotation, addr: u64) Error!?[]u8 {
        return getAll(host.re_get, .{ @as(i32, @backingInt(what)), addr }) catch |e| switch (e) {
            error.NotFound => null,
            else => e,
        };
    }

    /// Set (empty clears) as one undoable op tagged "plugin:<id>". Capability analysis.write.
    pub fn set(what: abi.Annotation, addr: u64, value: []const u8) Error!void {
        _ = try check(host.re_set(@backingInt(what), addr, value.ptr, value.len));
    }

    pub fn comment(addr: u64, text: []const u8) Error!void {
        return set(.comment, addr, text);
    }

    pub fn rename(addr: u64, name: []const u8) Error!void {
        return set(.name, addr, name);
    }

    /// Show `addr` in the RE workspace. Capability re.view.
    pub fn goto(addr: u64) Error!void {
        _ = try check(host.re_goto(addr));
    }

    /// Register an analysis pass; the host calls `reflet_analysis_pass(entry)` for every
    /// function after auto-analysis. Capability analysis.pass.
    pub fn registerPass(name: []const u8) Error!void {
        _ = try check(host.register_pass(name.ptr, name.len));
    }
};

// code (capability editor.read unless noted)

pub const doc = struct {
    pub const Info = struct { path: []const u8 = "", language: []const u8 = "", version: u64 = 0, lines: usize = 0 };

    pub fn info() Error!Info {
        const raw = try getAll(host.doc_info, .{});
        return std.json.parseFromSliceLeaky(Info, allocator, raw, .{ .ignore_unknown_fields = true }) catch error.Invalid;
    }

    pub fn text() Error![]u8 {
        return getAll(host.doc_text, .{});
    }

    /// Primary first.
    pub fn selections() Error![]abi.SelectionRecord {
        return records(abi.SelectionRecord, try getAll(host.doc_selections, .{}));
    }

    pub const Edit = struct { start: usize, end: usize, text: []const u8 };

    /// Apply non-overlapping edits as one undo step. Capability editor.write.
    pub fn edit(edits: []const Edit) Error!void {
        const text_json = std.json.Stringify.valueAlloc(allocator, edits, .{}) catch return error.OutOfMemory;
        _ = try check(host.doc_edit(text_json.ptr, text_json.len));
    }

    /// Replace the selections (first = primary) and reveal it. Capability editor.write.
    pub fn select(sels: []const abi.SelectionRecord) Error!void {
        const bytes = std.mem.sliceAsBytes(sels);
        _ = try check(host.doc_select(bytes.ptr, bytes.len));
    }

    /// Move the cursor to byte `offset`.
    pub fn moveTo(offset: u32) Error!void {
        return select(&.{.{ .anchor = offset, .head = offset }});
    }

    pub const Decoration = struct {
        line: u32,
        /// "gutter", "highlight", "inlay", "underline"
        kind: []const u8,
        tone: []const u8 = "accent",
        text: []const u8 = "",
        offset: ?u64 = null,
        end: ?u64 = null,
    };

    /// Replace this plugin's decorations of `path`. Capability editor.decorate.
    pub fn decorate(path: []const u8, items: []const Decoration) Error!void {
        const text_json = std.json.Stringify.valueAlloc(allocator, items, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        _ = try check(host.decorations_set(path.ptr, path.len, text_json.ptr, text_json.len));
    }

    pub const Diagnostic = struct {
        line: u32,
        col: u32 = 0,
        end_col: u32 = 0,
        /// "error", "warning", "info", "hint"
        severity: []const u8 = "warning",
        message: []const u8,
        code: []const u8 = "",
    };

    /// Replace this plugin's diagnostics of `path`. Capability editor.diagnostics.
    pub fn diagnostics(path: []const u8, items: []const Diagnostic) Error!void {
        const text_json = std.json.Stringify.valueAlloc(allocator, items, .{}) catch return error.OutOfMemory;
        _ = try check(host.diagnostics_set(path.ptr, path.len, text_json.ptr, text_json.len));
    }
};

/// Serialize `value` as JSON in the arena (panel descriptions).
pub fn json(value: anytype) Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false }) catch error.OutOfMemory;
}

/// End an entry point that returns a plain `i32` status (`reflet_init`, `reflet_command`,
/// `reflet_event`, `reflet_analysis_pass`): marks the call arena for reuse.
pub fn done(s: abi.Status) i32 {
    finished = true;
    return s.code();
}

/// `done` for an error from a helper.
pub fn fail(e: Error) i32 {
    return done(statusOf(e));
}
