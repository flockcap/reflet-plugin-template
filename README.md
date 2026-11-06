# Reflet plugin template

Start here to build a plugin for Reflet, the GPU editor and reverse
engineering workbench. Plugins are small WebAssembly modules that run sandboxed inside Reflet:
they can only do what their capabilities allow, and the user approves those capabilities when
installing.

This repo contains two working plugins you can copy:

- `re-example/`: **Stack & XOR string decoder** (an RE plugin). An analysis pass finds strings
  that functions build on the stack one immediate at a time, decodes the ones XORed with a
  constant byte, comments each one where it is built, and lists them in a "Decoded strings"
  panel (click a row to jump there).
- `code-example/`: **TODO highlighter** (a code plugin). Marks TODO, FIXME and HACK in the
  gutter, reports them as diagnostics, shows a count in the status bar and adds
  "Go to Next TODO".

## What plugins can do

RE plugins (`kinds = ["re"]`):

- read the open binary: bytes, segments, functions, basic blocks, IL at LLIL / MLIL / HLIL and
  pseudo-C, cross-references, names, comments and types
- rename, comment and retype; each write is a normal undoable database op, marked as made by
  your plugin
- register an analysis pass that runs on every function after auto-analysis
- add commands (palette, context menus) and panels (lists, tables, text, trees) with rows that
  jump to addresses

Code plugins (`kinds = ["code"]`):

- read and edit the active document (each edit is one undo step), read and move cursors
- add gutter marks, line highlights, inline hints and underlines
- report diagnostics, format documents, provide a grammar for syntax highlighting
- add commands, panels and a status bar item

Both: namespaced settings, notifications, a private storage folder, logging, and HTTPS requests
to hosts you declare. The full reference is [docs/API.md](docs/API.md).

## Quick start

1. Install [Zig 0.17.1](https://ziglang.org/download/).
2. Build:

   ```sh
   zig build          # plugins + packages
   zig build test     # the examples' unit tests
   ```

3. Outputs land in `zig-out/`:

   ```
   zig-out/re-example/plugin.wasm
   zig-out/code-example/plugin.wasm
   zig-out/com.example.xor-strings-0.1.0.reflet-plugin
   zig-out/com.example.todo-0.1.0.reflet-plugin
   ```

To make your own plugin, copy one example folder, give it a new id in `reflet-plugin.toml`, and
add the folder to the `plugins` list at the top of `build.zig`. If you only need one plugin per
repo, delete the other example.

Not using Zig? `sdk/reflet_plugin.h` declares the same ABI for C, and for Rust through bindgen.
The build flags are in the header.

## The manifest

```toml
id = "com.example.xor-strings"      # reverse-DNS, yours once you publish it
name = "Stack & XOR string decoder"
version = "0.1.0"                   # semver; the release tag must match
kinds = ["re"]                      # "re", "code", or both
capabilities = ["analysis.read", "analysis.write", "analysis.pass", "re.view", "commands"]
min_reflet = "0.0.1"
description = "One sentence for the marketplace card."
license = "MIT"
homepage = "https://github.com/<you>/<repo>"

[flock]
owner = "your-flock-username"       # proves the repo is yours when you submit it
```

A package (`<id>-<version>.reflet-plugin`) is a zip of exactly `reflet-plugin.toml`,
`plugin.wasm` and an optional `assets/` folder, at most 10 MB. `zig build` makes it for you.

## Capabilities

Ask only for what you use. Each line below is what users see in the install prompt.

| Capability | Risk | Install prompt line | Unlocks |
| --- | --- | --- | --- |
| `analysis.read` | low | Read the open binary: bytes, segments, functions, blocks, IL, xrefs, names, comments and types | `re_info`, `re_read`, `re_segments`, `re_functions`, `re_blocks`, `re_il`, `re_xrefs`, `re_get`; `analysis_done` events |
| `analysis.write` | medium | Rename, comment and retype in the analysis database (undoable, marked as made by this plugin) | `re_set` (rename, comment, retype; one undoable db op each, attributed to `plugin:<id>`) |
| `analysis.pass` | low | Run an analysis pass over every function after auto-analysis | `register_pass` + the `reflet_analysis_pass` export |
| `re.view` | low | Show views in the reverse-engineering workspace and jump to addresses | `re_goto`; panels with `"view":"re"`; legacy `arch` plugins |
| `editor.read` | low | Read the text, path, language and selections of the active document | `doc_info`, `doc_text`, `doc_selections`; document events |
| `editor.write` | medium | Edit the active document and move its cursors (each edit is undoable) | `doc_edit`, `doc_select` |
| `editor.decorate` | low | Add highlights, gutter marks and inline hints to the editor | `decorations_set` (gutter marks, line highlights, inline hints, underlines) |
| `editor.diagnostics` | low | Report problems (errors, warnings, hints) for documents | `diagnostics_set` |
| `editor.format` | medium | Format documents on request | the `reflet_format` export ("Format Document with …") |
| `language.grammar` | low | Provide syntax highlighting for file types | the `reflet_highlight` export (legacy `grammar` kind) |
| `commands` | low | Add commands to the palette and context menus | `register_command` (palette, editor and RE context menus); legacy `tool` kind |
| `ui.panel` | low | Show a panel (lists, tables, text, trees) in a dock | `panel_set` (dock panels: list / table / text / tree) |
| `ui.statusbar` | low | Show an item in the status bar | `status_set` |
| `ui.theme` | low | Provide a colour theme | the `reflet_theme` export (legacy `theme` kind) |
| `settings` | low | Keep its own settings (namespaced under the plugin id) | `setting_get`, `setting_set` (namespaced under the plugin id) |
| `notify` | low | Show notifications | `notify` |
| `storage` | low | Store files in its own private data folder | `storage_read`, `storage_write` in `<config>/plugin-data/<id>/` |
| `fs.workspace.read` | medium | Read files in the open workspace folder | `fs_size`, `fs_read` inside the open workspace folder |
| `fs.workspace.write` | high | Create and overwrite files in the open workspace folder | `fs_write` inside the open workspace folder (never the plugins folder) |
| `net.fetch:<host>` | high | Make HTTPS requests to `<host>` | `net_fetch` to exactly that host (https; http only for localhost) |

`net.fetch:<host>` is host-scoped: one entry per host, exact DNS name, no wildcard, no port, no
scheme (`net.fetch:api.example.com`).

### Rules

- A kind implies the capability it needs (`theme` -> `ui.theme`, `grammar` -> `language.grammar`,
  `tool` -> `commands`, `arch` -> `re.view`), so the prompt lists it.
- Capabilities are granted for the whole plugin when it is installed (or first enabled). An
  update that asks for more shows **only the new ones**; until the user accepts, the update is
  not installed. Built-in plugins have what they declare.
- Without a capability a host function returns `REFLET_DENIED` (-1) and the plugin's log says
  which capability was missing; the plugin keeps running.
- `fs.workspace.*` keep the per-path checks of the original model: symlinks that leave the
  workspace are refused, and the plugins folder (with `grants.toml`) is never writable.

## Test locally

1. `zig build`
2. In Reflet open **Settings > Plugins > Installed** and choose **Install from File…**. Pick
   `zig-out/<id>-<version>.reflet-plugin`, or a folder holding `reflet-plugin.toml` and
   `plugin.wasm` (for example `zig-out/re-example/`).
3. Accept the capability prompt. Sideloaded plugins show an **Unverified** badge: Reflet
   checked the package, the manifest and the module, but nobody reviewed the code.
4. Use it: open a binary for an RE plugin (the pass runs when analysis finishes; "Decode Stack
   Strings" re-runs it), or a source file for a code plugin.
5. Debug: each plugin's log (your `reflet.log` calls, denied capabilities, traps) is on its card
   in **Settings > Plugins > Installed**. A plugin that traps fails that one call and keeps
   running.

To try a new build, install the file again: the same id replaces the old version.

## Publish

1. Bump `version` in `reflet-plugin.toml`.
2. Tag and push:

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```

   `.github/workflows/release.yml` builds on GitHub-hosted Ubuntu, checks that the tag matches
   every manifest's version, and attaches `<id>-<version>.reflet-plugin` to the GitHub Release.
3. First release only: submit the repository at https://id.flock.holdings/plugins/submit. The
   `[flock] owner` line in `reflet-plugin.toml` must be your Flock ID username: that is the
   proof the repo is yours (no GitHub OAuth needed).
4. Later releases: click **Sync** on your plugin dashboard, or wait for the daily poll.

## Review rules

- An admin reviews the first version of every plugin. Later versions publish automatically,
  unless they add capabilities: then they go back to review, and users are asked only for the
  new capabilities when they update.
- Ids are reverse-DNS and belong to the first publisher.
- Versions are immutable. To fix a release, publish a new version. A broken version can be
  yanked (no new installs, current users are warned). A malicious plugin is revoked: Reflet
  disables and uninstalls it everywhere and tells users why.
- No obfuscated or packed WebAssembly; the module must match the source in the repo.
- Declare only the capabilities you use. Every `net.fetch:<host>` must be explained in your
  README: what you send there and why.
- Reflet downloads packages only from `dl.flock.holdings`, and checks their sha256 and size
  against the signed catalog, so users get exactly the file that was reviewed.

## License

MIT, see [LICENSE](LICENSE). The SDK files in `sdk/` are MIT too, so your plugin can use any
license you like.
