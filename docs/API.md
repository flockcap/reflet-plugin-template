# Reflet Plugin API v1

Plugins are WebAssembly modules (wasm32, MVP + bulk memory, multi-value, sign-ext, non-trapping
float-to-int) that run in Reflet's own sandboxed interpreter. A plugin touches nothing outside its
linear memory except through the host functions below, each gated by a capability
(the capabilities table in [README.md](../README.md#capabilities)). Every call into a plugin is bounded by fuel, so a hung or
crashing plugin fails that call only.

There are two families, and a plugin may be both:

- **RE plugins** (`kinds = ["re"]`): read the open binary (bytes, segments, functions, blocks,
  IL at LLIL/MLIL/HLIL, xrefs, names, comments, types), annotate it as undoable database ops,
  run analysis passes, add commands and panels.
- **Code plugins** (`kinds = ["code"]`): read and edit the active document, move cursors,
  decorate the editor, report diagnostics, format, contribute a grammar, show a status item.

The legacy kinds (`theme`, `grammar`, `arch`, `tool`) of the in-tree samples keep working.

Source of truth for the ABI: `sdk/abi.zig` (imports, exports, records), shared with the Reflet
host. SDKs: `sdk/reflet.zig` (Zig) and `sdk/reflet_plugin.h` (C, Rust via bindgen). Examples:
`re-example/` (stack and XOR string decoder) and `code-example/` (TODO highlighter).

## Package

```
reflet-plugin.toml      manifest (required)
plugin.wasm             the module (required)
assets/**               anything else the plugin ships (optional)
```

Published as `<id>-<version>.reflet-plugin`: a zip of exactly those entries (no other names, no
`..`, no absolute paths, at most 10 MB). Reflet validates the zip, the manifest and the wasm module
before installing, also for sideloaded files.

### `reflet-plugin.toml`

```toml
id = "com.example.xor-strings"      # reverse-DNS, 1-64 of [a-z0-9._-], starts with a letter
name = "XOR string decoder"
version = "1.2.0"                   # semver
kinds = ["re"]                      # re, code (and the legacy kinds)
capabilities = ["analysis.read", "analysis.write", "analysis.pass", "net.fetch:api.example.com"]
min_reflet = "0.1.0"                # oldest Reflet that can run it
description = "One sentence for the marketplace card."
license = "MIT"
homepage = "https://github.com/me/xor-strings"
wasm = "plugin.wasm"                # default

[flock]
owner = "me"                        # your Flock ID username: proves the repo is yours
```

Unknown keys are ignored (forward compatible). Errors carry a line number.

## ABI conventions

- Pointers and lengths are guest `i32`; integers are little-endian.
- Host -> guest data: the host calls `reflet_alloc(len)`, copies the bytes there, then passes
  `(ptr, len)`. A bump arena reset at the start of each entry point is enough (the Zig SDK does it).
- Guest -> host results from `i64` entry points: `pack(ptr, len) = ptr << 32 | len`; a negative
  value carries a status in the low 32 bits.
- Host imports return `i32`: `>= 0` a byte count, `< 0` a status:
  `ok 0, denied -1, pending -2, not_found -3, io -4, too_large -5, invalid -6, unsupported -7,
  timed_out -8`.
- **Getters** take `(out_ptr, out_cap)`, copy at most `out_cap` bytes and return the full
  length: call with `out_cap = 0` to size the buffer.
- A bad pointer or argument is `invalid`, never a trap. RE calls with no binary open, and code
  calls with no active document, return `not_found`.

## Exports

| Export | Signature | When |
| --- | --- | --- |
| `memory`, `reflet_abi_version() -> i32` (= 1), `reflet_alloc(len) -> ptr` | | required |
| `reflet_init() -> i32` | | once after loading: register commands, passes, panels |
| `reflet_command(id, id_len, arg, arg_len) -> i32` | | a registered command ran (`arg` = a panel row's `arg`, or empty) |
| `reflet_event(kind, ptr, len) -> i32` | | `1` document opened, `2` changed, `3` saved, `4` active document (payload: path); `5` analysis done (payload: binary path); `6` panel action (JSON `{"panel","row","arg"}`) |
| `reflet_analysis_pass(entry: i64) -> i32` | | once per function after auto-analysis, for plugins that called `register_pass` |
| `reflet_format(src, len) -> i64` | | "Format Document with <plugin>" (`editor.format`) |
| `reflet_highlight`, `reflet_theme`, `reflet_arch_decode`, `reflet_tool_run` | | legacy kinds |

Document events need `editor.read`, analysis events `analysis.read`.

## Host functions (module `"reflet"`)

### Common

| Import | Signature | Capability |
| --- | --- | --- |
| `log` | `(level, ptr, len)` | none (plugin log in Settings > Plugins) |
| `now_ms` | `() -> i64` | none |
| `notify` | `(level, ptr, len) -> i32` | `notify` |
| `setting_get` | `(key, key_len, out, cap) -> i32` | `settings` |
| `setting_set` | `(key, key_len, val, val_len) -> i32` | `settings` |
| `storage_read` | `(name, name_len, out, cap) -> i32` | `storage` |
| `storage_write` | `(name, name_len, data, len) -> i32` | `storage` |
| `net_fetch` | `(method, url, url_len, body, body_len, out, cap) -> i32` | `net.fetch:<host>` |
| `register_command` | `(id, id_len, title, title_len, where) -> i32` | `commands` |
| `panel_set` | `(id, id_len, json, json_len) -> i32` | `ui.panel` (`re.view` for RE panels) |
| `status_set` | `(id, id_len, text, text_len, tone) -> i32` | `ui.statusbar` |

- Settings are strings keyed by `[A-Za-z0-9._-]{1,64}`, kept per plugin in
  `<config>/plugin-data/<id>/.settings.json`.
- Storage files live in `<config>/plugin-data/<id>/` (same name rules, 16 MB each).
- `net_fetch`: `method` 0 GET, 1 POST (JSON body). `out` receives `{status: u32, body_len: u32}`
  then the body, truncated to fit. HTTPS only (plain HTTP for `localhost` / `127.0.0.1`), the
  host must be declared exactly, no credentials in the URL, 10 s limit.
- Commands: ids start with `plugin.` and use `[a-z0-9._-]`; `where` is a bit set:
  `1` palette, `2` editor context menu, `4` RE context menu.
- Tones: `0 accent, 1 good, 2 warn, 3 err, 4 info, 5 hint, 6 muted`.

### Reverse engineering

| Import | Signature | Capability |
| --- | --- | --- |
| `re_info` | `(out, cap)` JSON `{"path","format","arch","bits","entry"}` | `analysis.read` |
| `re_read` | `(addr: i64, out, cap) -> bytes read` | `analysis.read` |
| `re_segments` | `(out, cap)` -> `SegmentRecord[]` | `analysis.read` |
| `re_functions` | `(out, cap)` -> `FunctionRecord[]` sorted by entry | `analysis.read` |
| `re_blocks` | `(entry: i64, out, cap)` -> `BlockRecord[]` | `analysis.read` |
| `re_il` | `(addr: i64, level, out, cap)` -> text of the containing function | `analysis.read` |
| `re_xrefs` | `(addr: i64, dir, out, cap)` -> `XrefRecord[]` (`dir` 0 = to, 1 = from) | `analysis.read` |
| `re_get` | `(what, addr: i64, out, cap)` (`not_found` when unset) | `analysis.read` |
| `re_set` | `(what, addr: i64, ptr, len)` (empty clears) | `analysis.write` |
| `re_goto` | `(addr: i64)` | `re.view` |
| `register_pass` | `(name, name_len)` | `analysis.pass` |

Records (little-endian, packed as declared):

```
SegmentRecord  { u64 start; u64 end; u32 flags /* 1 r, 2 w, 4 x */; u32 _pad; }   24 bytes
FunctionRecord { u64 entry; u64 end; u32 blocks; u32 instructions; }               24 bytes
BlockRecord    { u64 start; u64 end; }                                             16 bytes
XrefRecord     { u64 from; u64 to; u32 kind /* 0 call 1 jump 2 read 3 write 4 ref */; u32 _pad; }
```

IL levels: `0 llil, 1 llil_ssa, 2 mlil, 3 mlil_ssa, 4 hlil, 5 pseudo_c`. Annotations (`what`):
`0 name, 1 comment, 2 type` (a C declaration).

Every `re_set` is one normal database op: it shows in history, Undo reverts it, and collab peers
receive it. The Reflet host records the write as made by `plugin:<id>`.

### Code

| Import | Signature | Capability |
| --- | --- | --- |
| `doc_info` | `(out, cap)` JSON `{"path","language","version","lines"}` | `editor.read` |
| `doc_text` | `(out, cap)` UTF-8 text | `editor.read` |
| `doc_selections` | `(out, cap)` -> `SelectionRecord[]` (`{u32 anchor; u32 head;}`, primary first) | `editor.read` |
| `doc_edit` | `(json, len)` `[{"start","end","text"}]`, byte offsets, no overlaps, **one undo step** | `editor.write` |
| `doc_select` | `(records, len)` replace selections, reveal the primary | `editor.write` |
| `decorations_set` | `(path, path_len, json, json_len)` replaces this plugin's decorations of `path` | `editor.decorate` |
| `diagnostics_set` | `(path, path_len, json, json_len)` replaces this plugin's diagnostics of `path` | `editor.diagnostics` |

Decorations:

```json
[{"line": 4, "kind": "gutter", "tone": "warn", "text": "T"},
 {"line": 4, "kind": "highlight", "tone": "warn"},
 {"line": 4, "kind": "inlay", "text": "3 refs", "offset": 120},
 {"line": 4, "kind": "inlay", "text": "slow"},
 {"line": 4, "kind": "underline", "offset": 118, "end": 124, "tone": "err"}]
```

`gutter` draws `text` (1-2 characters) in the marker lane, `highlight` tints the line, `inlay`
draws virtual text before `offset` (or after the end of the line without one), `underline` a
squiggle over `[offset, end)`. Lines are 0-based.

Diagnostics:

```json
[{"line": 4, "col": 3, "end_col": 7, "severity": "warning", "message": "TODO: rename", "code": "TODO"}]
```

`severity` is `error`, `warning`, `info` or `hint`. They draw as underlines and gutter glyphs and
are listed in the Plugin Problems panel.

## Panels

`panel_set(id, json)` creates or replaces a dock panel. The host renders a flat, declarative
tree; plugins never draw.

```json
{"title": "Decoded strings", "view": "re", "place": "bottom",
 "root": {"type": "table", "columns": ["Address", "Text"], "empty": "Nothing found.",
          "rows": [{"cells": ["0x401000", "Hello"], "addr": 4198400, "arg": "row-1"}]}}
```

- `view`: `"re"` (RE workspace, needs `re.view`), `"code"` or `"any"` (needs `ui.panel`).
- `place`: `bottom` (default) or `right`.
- `root.type`: `list` (`items` with `label`, `detail`), `table` (`columns`, `rows` with
  `cells`), `text` (`text`), `tree` (`items` with `children`).
- Any row may carry `addr` (activating it jumps there in the RE workspace), `line` (+ optional
  `path`: moves the editor there), `arg` (sent back as a `panel_action` event), `tone`.

## Limits

Fuel per call 200 M instructions; 16 MB per result; 10 s per network / file call; 256
commands, settings and storage files, 8 panels and 4 status items per plugin; 10 000
decorations or diagnostics per document.

## Building

Zig: `sdk/reflet.zig` gives typed helpers (`reflet.re.functions()`,
`reflet.doc.decorate(...)`, `reflet.panelSet(...)`) and the arena. See `build.zig`, which also packs `<id>-<version>.reflet-plugin`.

C: include `reflet_plugin.h` and build with
`clang --target=wasm32 -nostdlib -O2 -mbulk-memory -mmultivalue -msign-ext -mnontrapping-fptoint -Wl,--no-entry -Wl,--export-dynamic`.

## Installing and publishing

- **Sideload** (development): Settings > Plugins > Installed > "Install from File…" takes a
  `.reflet-plugin` or a folder. Sideloaded plugins carry an "Unverified" badge.
- **Marketplace**: publish a GitHub Release with the `.reflet-plugin` asset, then submit the
  repo at https://id.flock.holdings/plugins/submit. The `[flock] owner` line proves ownership.
  Admins review the first version; later versions publish automatically unless they add
  capabilities. Reflet verifies the signed catalog (Ed25519) before trusting anything in it and
  downloads artifacts only from `dl.flock.holdings`, checking sha256 and size.
- **Deep links**: `reflet://plugins/install?id=<id>` opens the install prompt for the latest
  non-yanked version.
