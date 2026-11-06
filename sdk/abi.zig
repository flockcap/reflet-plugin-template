// SPDX-License-Identifier: MIT
//! The Reflet plugin ABI, version 1: a WIT-free, pointer+length ABI between the host and a
//! wasm32 guest. This file is std-only on purpose: the guest SDK (`sdk/reflet.zig`)
//! imports it too (as module `reflet_abi`), so host and guest agree on one source of truth.
//!
//! Conventions
//! - All integers are little-endian; pointers and lengths are guest `i32` (treated as u32).
//! - Host -> guest data: the host calls `reflet_alloc(len)`, copies the bytes to the returned
//!   pointer, then passes (ptr, len). The guest owns that memory afterwards (a bump allocator
//!   that the guest resets at the start of every entry point is fine).
//! - Guest -> host data: an entry point returns an `i64` made by `pack(ptr, len)` pointing into
//!   guest memory; the host copies it out before the next call. `len == 0` means "nothing".
//!   A negative return (high bit set) is a `Status` in the low 32 bits.
//! - Host imports return `i32`: >= 0 is a count of bytes, < 0 is a `Status`.
//! - Every guest call is bounded by fuel; a trap disables nothing but that call.
//!
//! STABILITY: frozen for v1. New exports/imports may be added (optional ones only); never change
//! a signature or a record layout. Bump `version` for incompatible changes.
const std = @import("std");

pub const version: i32 = 1;

/// Module name of every host import.
pub const import_module = "reflet";

/// Guest exports. `memory`, `reflet_abi_version` and `reflet_alloc` are required; the rest
/// depend on the plugin kinds the manifest declares.
pub const exports = struct {
    pub const memory = "memory";
    /// () -> i32: must return `version`.
    pub const abi_version = "reflet_abi_version";
    /// (len: i32) -> i32 ptr; 0 = out of memory.
    pub const alloc = "reflet_alloc";
    /// () -> i32 Status. Optional; called once after instantiation.
    pub const init = "reflet_init";
    /// kind theme: () -> i64 packed UTF-8 TOML theme text (same format as a user theme file,
    /// see core.settings.theme_file).
    pub const theme = "reflet_theme";
    /// kind grammar: (src_ptr: i32, src_len: i32) -> i64 packed array of `SpanRecord`s, sorted,
    /// non-overlapping, offsets relative to the start of `src`.
    pub const highlight = "reflet_highlight";
    /// kind arch: (bytes_ptr: i32, bytes_len: i32, address: i64) -> i64 packed
    /// `InsnHeader` followed by `text_len` bytes of UTF-8 text ("mnemonic\toperands").
    /// `len == 0` in the header (or an empty result) = undecodable.
    pub const arch_decode = "reflet_arch_decode";
    /// kind tool: (cmd_ptr: i32, cmd_len: i32, in_ptr: i32, in_len: i32) -> i64 packed
    /// `ToolHeader` followed by UTF-8 output text. `cmd` is the command id from the manifest,
    /// `in` is the input the manifest asked for (`tool.input`).
    pub const tool_run = "reflet_tool_run";

    // ---- API v1 (docs/plugins/API.md); all optional ----

    /// (id_ptr, id_len, arg_ptr, arg_len) -> i32 Status. A command the plugin registered with
    /// `register_command` ran; `arg` is UTF-8 (a panel row's `arg`, or empty).
    pub const command = "reflet_command";
    /// (kind: i32 `Event`, ptr, len) -> i32 Status. `ptr/len` is the event's payload
    /// (a document path, or JSON for `panel_action`).
    pub const event = "reflet_event";
    /// (entry: i64) -> i32 Status. Runs once per function after auto-analysis for every pass
    /// the plugin registered (capability analysis.pass).
    pub const analysis_pass = "reflet_analysis_pass";
    /// (src_ptr, src_len) -> i64 packed formatted text (capability editor.format).
    pub const format = "reflet_format";
};

/// Host imports (module `import_module`). Signatures in wasm types.
pub const imports = struct {
    /// (level: i32 `LogLevel`, ptr: i32, len: i32) -> ()
    pub const log = "log";
    /// () -> i64 milliseconds since the Unix epoch.
    pub const now_ms = "now_ms";
    /// (path_ptr, path_len) -> i64 file size, or a negative Status. Capability fs_read.
    pub const fs_size = "fs_size";
    /// (path_ptr, path_len, out_ptr, out_cap) -> i32 bytes read (at most out_cap, from the
    /// start of the file), or a negative Status. Capability fs_read.
    pub const fs_read = "fs_read";
    /// (path_ptr, path_len, data_ptr, data_len) -> i32 bytes written, or a negative Status.
    /// Creates or truncates. Capability fs_write.
    pub const fs_write = "fs_write";
    /// (host_ptr, host_len, port: i32) -> i32 connection handle (>= 0), or a negative Status.
    /// Capability net ("host:port").
    pub const net_connect = "net_connect";
    /// (handle, ptr, len) -> i32 bytes sent, or a negative Status.
    pub const net_send = "net_send";
    /// (handle, ptr, cap) -> i32 bytes received (0 = closed by peer), or a negative Status.
    pub const net_recv = "net_recv";
    /// (handle) -> ()
    pub const net_close = "net_close";
    /// (argv_ptr, argv_len, out_ptr, out_cap) -> i32 bytes written to out, or a negative
    /// Status. argv is NUL-separated (`"git\x00status\x00"`); runs to completion with no stdin.
    /// `out` receives a `ProcessHeader` then captured stdout (truncated to fit).
    /// Capability process (argv[0]).
    pub const process_run = "process_run";

    // ---- API v1. Getters copy at most `out_cap` bytes and return the FULL length, so a guest
    // can call with out_cap 0 to size its buffer. Each import names its capability; without it
    // the call returns `Status.denied`. RE calls without an open binary, and code calls
    // without an active document, return `Status.not_found`.

    // common
    /// (level: i32 `LogLevel`, ptr, len) -> i32. Capability notify.
    pub const notify = "notify";
    /// (key_ptr, key_len, out_ptr, out_cap) -> i32 length, not_found. Capability settings.
    pub const setting_get = "setting_get";
    /// (key_ptr, key_len, val_ptr, val_len) -> i32. Capability settings.
    pub const setting_set = "setting_set";
    /// (name_ptr, name_len, out_ptr, out_cap) -> i32 length. Capability storage.
    pub const storage_read = "storage_read";
    /// (name_ptr, name_len, data_ptr, data_len) -> i32 bytes written. Capability storage.
    pub const storage_write = "storage_write";
    /// (method: i32 `FetchMethod`, url_ptr, url_len, body_ptr, body_len, out_ptr, out_cap) ->
    /// i32 bytes written to out: a `FetchHeader` then the response body (truncated to fit).
    /// Capability net.fetch:<host> for the URL's host; https only (http for localhost).
    pub const net_fetch = "net_fetch";
    /// (id_ptr, id_len, title_ptr, title_len, where: i32 `CommandWhere` bits) -> i32.
    /// `id` must start with "plugin.". Capability commands.
    pub const register_command = "register_command";
    /// (id_ptr, id_len, json_ptr, json_len) -> i32. Create or replace panel `id` with a
    /// declarative tree (see API.md "Panels"). Capability ui.panel (or re.view for "re" panels).
    pub const panel_set = "panel_set";
    /// (id_ptr, id_len, text_ptr, text_len, tone: i32 `Tone`) -> i32. Empty text removes the
    /// item. Capability ui.statusbar.
    pub const status_set = "status_set";

    // reverse engineering
    /// (out_ptr, out_cap) -> i32 length of JSON {"path","format","arch","bits","entry"}.
    /// Capability analysis.read.
    pub const re_info = "re_info";
    /// (addr: i64, out_ptr, out_cap) -> i32 bytes read (mapped bytes only). analysis.read.
    pub const re_read = "re_read";
    /// (out_ptr, out_cap) -> i32 length of `SegmentRecord`s. analysis.read.
    pub const re_segments = "re_segments";
    /// (out_ptr, out_cap) -> i32 length of `FunctionRecord`s, sorted by entry. analysis.read.
    pub const re_functions = "re_functions";
    /// (entry: i64, out_ptr, out_cap) -> i32 length of `BlockRecord`s. analysis.read.
    pub const re_blocks = "re_blocks";
    /// (addr: i64, level: i32 `IlLevel`, out_ptr, out_cap) -> i32 length of UTF-8 text of the
    /// function containing addr. analysis.read.
    pub const re_il = "re_il";
    /// (addr: i64, dir: i32 0 = to addr / 1 = from addr, out_ptr, out_cap) -> i32 length of
    /// `XrefRecord`s. analysis.read.
    pub const re_xrefs = "re_xrefs";
    /// (what: i32 `Annotation`, addr: i64, out_ptr, out_cap) -> i32 length, not_found when
    /// unset. analysis.read.
    pub const re_get = "re_get";
    /// (what: i32 `Annotation`, addr: i64, ptr, len) -> i32 (len 0 clears). One undoable database
    /// op, attributed to "plugin:<id>". Capability analysis.write.
    pub const re_set = "re_set";
    /// (addr: i64) -> i32. Show `addr` in the RE workspace. Capability re.view.
    pub const re_goto = "re_goto";
    /// (name_ptr, name_len) -> i32. Register an analysis pass (`reflet_analysis_pass`).
    /// Capability analysis.pass.
    pub const register_pass = "register_pass";

    // code
    /// (out_ptr, out_cap) -> i32 length of JSON {"path","language","version","lines"} of the
    /// active document. Capability editor.read.
    pub const doc_info = "doc_info";
    /// (out_ptr, out_cap) -> i32 length of the active document's UTF-8 text. editor.read.
    pub const doc_text = "doc_text";
    /// (out_ptr, out_cap) -> i32 length of `SelectionRecord`s (primary first). editor.read.
    pub const doc_selections = "doc_selections";
    /// (json_ptr, json_len) -> i32. Apply `[{"start","end","text"}]` (byte offsets, not
    /// overlapping) as ONE undo step. Capability editor.write.
    pub const doc_edit = "doc_edit";
    /// (ptr, len) -> i32. Replace the selections with `SelectionRecord`s (first = primary) and
    /// reveal the primary one. Capability editor.write.
    pub const doc_select = "doc_select";
    /// (path_ptr, path_len, json_ptr, json_len) -> i32. Replace this plugin's decorations of
    /// `path` (see API.md "Decorations"). Capability editor.decorate.
    pub const decorations_set = "decorations_set";
    /// (path_ptr, path_len, json_ptr, json_len) -> i32. Replace this plugin's diagnostics of
    /// `path`. Capability editor.diagnostics.
    pub const diagnostics_set = "diagnostics_set";
};

pub const Status = enum(i32) {
    ok = 0,
    /// The capability is not in the manifest, or the user denied it.
    denied = -1,
    /// The capability is declared but the user has not answered yet; a prompt is queued and
    /// the host re-runs the triggering action once it is allowed.
    pending = -2,
    not_found = -3,
    io = -4,
    too_large = -5,
    invalid = -6,
    unsupported = -7,
    /// A file, network or process call ran past its time limit (the UI never waits forever).
    timed_out = -8,
    _,

    pub fn code(s: Status) i32 {
        return @backingInt(s);
    }
};

pub const LogLevel = enum(i32) { debug = 0, info = 1, warn = 2, err = 3, _ };

/// Pack a guest (ptr, len) into an entry-point result. `ptr` must be below 2^31 (guest memory is
/// capped far below that), so a packed value is never negative.
pub fn pack(ptr: u32, len: u32) i64 {
    return @bitCast((@as(u64, ptr) << 32) | len);
}

pub const Unpacked = union(enum) {
    data: struct { ptr: u32, len: u32 },
    status: Status,
};

/// Inverse of `pack`; negative values carry a `Status` (`packStatus`).
pub fn unpack(v: i64) Unpacked {
    if (v < 0) return .{ .status = @fromBackingInt(@intCast(@as(i32, @truncate(v)))) };
    const u: u64 = @bitCast(v);
    return .{ .data = .{ .ptr = @truncate(u >> 32), .len = @truncate(u) } };
}

/// An entry-point result that reports a failure instead of data.
pub fn packStatus(s: Status) i64 {
    return @as(i64, s.code()) | @as(i64, std.math.minInt(i64));
}

/// Token kinds a grammar plugin may emit. Names match `core.syntax.TokenKind` tag names (the
/// host maps by name), numbers are the ABI.
pub const Token = enum(u32) {
    plain = 0,
    keyword = 1,
    function = 2,
    type = 3,
    string = 4,
    escape = 5,
    number = 6,
    constant = 7,
    constant_builtin = 8,
    comment = 9,
    operator = 10,
    punctuation = 11,
    punctuation_bracket = 12,
    variable = 13,
    property = 14,
    label = 15,
    namespace = 16,
    attribute = 17,
    tag = 18,
    heading = 19,
    literal = 20,
    _,
};

pub const SpanRecord = extern struct {
    start: u32,
    end: u32,
    /// `Token`.
    kind: u32,
};

pub const InsnFlow = enum(u32) { normal = 0, jump = 1, branch = 2, call = 3, ret = 4, _ };

pub const InsnHeader = extern struct {
    /// Instruction length in bytes; 0 = undecodable.
    len: u32,
    /// `InsnFlow`.
    flow: u32,
    /// Branch/call target (valid when `has_target != 0`).
    target: u64,
    has_target: u32,
    text_len: u32,
};

pub const ToolHeader = extern struct {
    /// `Status` of the run (`pending` = a capability prompt was queued; re-run after it).
    status: i32,
    /// `ToolOutput`.
    format: u32,
};

pub const ToolOutput = enum(u32) { text = 0, markdown = 1, _ };

// ---- API v1 records and enums -----------------------------------------------------------------

/// `reflet_event` kinds.
pub const Event = enum(i32) {
    document_opened = 1,
    document_changed = 2,
    document_saved = 3,
    /// The active editor changed (payload: its path, empty for none).
    active_document = 4,
    /// Auto-analysis of the open binary finished (payload: its path).
    analysis_done = 5,
    /// A panel row was activated (payload: JSON {"panel","row","arg"}).
    panel_action = 6,
    _,
};

pub const CommandWhere = struct {
    pub const palette: i32 = 1;
    pub const editor_context: i32 = 2;
    pub const re_context: i32 = 4;
};

/// Status bar / decoration tones (names match the host's tones).
pub const Tone = enum(i32) { accent = 0, good = 1, warn = 2, err = 3, info = 4, hint = 5, muted = 6, _ };

pub const IlLevel = enum(i32) { llil = 0, llil_ssa = 1, mlil = 2, mlil_ssa = 3, hlil = 4, pseudo_c = 5, _ };

pub const Annotation = enum(i32) { name = 0, comment = 1, type = 2, _ };

pub const FetchMethod = enum(i32) { get = 0, post = 1, _ };

pub const FetchHeader = extern struct {
    /// HTTP status.
    status: u32,
    /// Full body length before truncation.
    body_len: u32,
};

pub const SegmentFlags = struct {
    pub const read: u32 = 1;
    pub const write: u32 = 2;
    pub const exec: u32 = 4;
};

pub const SegmentRecord = extern struct { start: u64, end: u64, flags: u32, _pad: u32 = 0 };
pub const FunctionRecord = extern struct { entry: u64, end: u64, blocks: u32, instructions: u32 };
pub const BlockRecord = extern struct { start: u64, end: u64 };
pub const XrefKind = enum(u32) { call = 0, jump = 1, data_read = 2, data_write = 3, data_ref = 4, _ };
pub const XrefRecord = extern struct { from: u64, to: u64, kind: u32, _pad: u32 = 0 };
pub const SelectionRecord = extern struct { anchor: u32, head: u32 };

pub const ProcessHeader = extern struct {
    exit_code: i32,
    /// Full stdout length before truncation.
    stdout_len: u32,
};

comptime {
    std.debug.assert(@sizeOf(SpanRecord) == 12);
    std.debug.assert(@sizeOf(InsnHeader) == 24);
    std.debug.assert(@sizeOf(ToolHeader) == 8);
    std.debug.assert(@sizeOf(ProcessHeader) == 8);
    std.debug.assert(@sizeOf(FetchHeader) == 8);
    std.debug.assert(@sizeOf(SegmentRecord) == 24);
    std.debug.assert(@sizeOf(FunctionRecord) == 24);
    std.debug.assert(@sizeOf(BlockRecord) == 16);
    std.debug.assert(@sizeOf(XrefRecord) == 24);
    std.debug.assert(@sizeOf(SelectionRecord) == 8);
}

test "pack round trip and status" {
    const p = unpack(pack(0x1234, 99));
    try std.testing.expectEqual(@as(u32, 0x1234), p.data.ptr);
    try std.testing.expectEqual(@as(u32, 99), p.data.len);
    try std.testing.expectEqual(Status.pending, unpack(packStatus(.pending)).status);
    try std.testing.expectEqual(Status.denied, unpack(packStatus(.denied)).status);
    const hi = unpack(pack(0x7fff_ffff, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0x7fff_ffff), hi.data.ptr);
}
