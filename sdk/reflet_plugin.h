/*
 * reflet_plugin.h - the Reflet plugin ABI (version 1) for C, Rust (via bindgen) and any language
 * that compiles to wasm32. Mirrors sdk/abi.zig, the single source of truth.
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Flock Holdings
 *
 * Build: clang --target=wasm32 -nostdlib -O2 -mbulk-memory -mmultivalue -msign-ext
 *        -mnontrapping-fptoint -Wl,--no-entry -Wl,--export-dynamic -o plugin.wasm plugin.c
 *
 * Conventions
 *   - Pointers and lengths are 32-bit guest values; integers are little-endian.
 *   - The host copies inputs into guest memory with reflet_alloc() before calling an entry
 *     point; a bump allocator reset at the start of each call is enough.
 *   - Entry points returning int64_t pack (ptr << 32 | len) of guest memory; a negative value
 *     carries a reflet_status in the low 32 bits.
 *   - Host imports return int32_t: >= 0 is a byte count, < 0 a reflet_status.
 *   - Getters ("out", "cap") copy at most cap bytes and return the FULL length: call with
 *     cap 0 to size the buffer, then again.
 *   - Every import needs the capability named next to it in reflet-plugin.toml; otherwise it
 *     returns REFLET_DENIED. See README.md (Capabilities).
 */
#ifndef REFLET_PLUGIN_H
#define REFLET_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REFLET_ABI_VERSION 1

#define REFLET_IMPORT(name) __attribute__((import_module("reflet"), import_name(#name)))
#define REFLET_EXPORT(name) __attribute__((export_name(#name)))

typedef enum {
    REFLET_OK = 0,
    REFLET_DENIED = -1,      /* capability not declared or not granted */
    REFLET_PENDING = -2,     /* legacy per-path prompt queued; retried by the host */
    REFLET_NOT_FOUND = -3,
    REFLET_IO = -4,
    REFLET_TOO_LARGE = -5,
    REFLET_INVALID = -6,
    REFLET_UNSUPPORTED = -7,
    REFLET_TIMED_OUT = -8
} reflet_status;

typedef enum { REFLET_LOG_DEBUG = 0, REFLET_LOG_INFO = 1, REFLET_LOG_WARN = 2, REFLET_LOG_ERROR = 3 } reflet_log_level;

typedef enum {
    REFLET_EVENT_DOCUMENT_OPENED = 1,
    REFLET_EVENT_DOCUMENT_CHANGED = 2,
    REFLET_EVENT_DOCUMENT_SAVED = 3,
    REFLET_EVENT_ACTIVE_DOCUMENT = 4,
    REFLET_EVENT_ANALYSIS_DONE = 5,
    REFLET_EVENT_PANEL_ACTION = 6
} reflet_event;

#define REFLET_WHERE_PALETTE 1
#define REFLET_WHERE_EDITOR_CONTEXT 2
#define REFLET_WHERE_RE_CONTEXT 4

typedef enum { REFLET_TONE_ACCENT = 0, REFLET_TONE_GOOD, REFLET_TONE_WARN, REFLET_TONE_ERR, REFLET_TONE_INFO, REFLET_TONE_HINT, REFLET_TONE_MUTED } reflet_tone;
typedef enum { REFLET_IL_LLIL = 0, REFLET_IL_LLIL_SSA, REFLET_IL_MLIL, REFLET_IL_MLIL_SSA, REFLET_IL_HLIL, REFLET_IL_PSEUDO_C } reflet_il_level;
typedef enum { REFLET_NAME = 0, REFLET_COMMENT = 1, REFLET_TYPE = 2 } reflet_annotation;
typedef enum { REFLET_GET = 0, REFLET_POST = 1 } reflet_fetch_method;
typedef enum { REFLET_XREF_CALL = 0, REFLET_XREF_JUMP, REFLET_XREF_DATA_READ, REFLET_XREF_DATA_WRITE, REFLET_XREF_DATA_REF } reflet_xref_kind;

#define REFLET_SEG_READ 1u
#define REFLET_SEG_WRITE 2u
#define REFLET_SEG_EXEC 4u

typedef struct { uint64_t start, end; uint32_t flags, _pad; } reflet_segment;           /* 24 bytes */
typedef struct { uint64_t entry, end; uint32_t blocks, instructions; } reflet_function;  /* 24 bytes */
typedef struct { uint64_t start, end; } reflet_block;                                    /* 16 bytes */
typedef struct { uint64_t from, to; uint32_t kind, _pad; } reflet_xref;                  /* 24 bytes */
typedef struct { uint32_t anchor, head; } reflet_selection;                              /*  8 bytes */
typedef struct { uint32_t status, body_len; } reflet_fetch_header;                       /*  8 bytes */
typedef struct { int32_t status; uint32_t format; } reflet_tool_header;                  /*  8 bytes */

/* ---- host imports: original ABI ---------------------------------------------------------- */
REFLET_IMPORT(log) void reflet_log(int32_t level, const char *ptr, uint32_t len);
REFLET_IMPORT(now_ms) int64_t reflet_now_ms(void);

/* ---- common ------------------------------------------------------------------------------ */
REFLET_IMPORT(notify) int32_t reflet_notify(int32_t level, const char *ptr, uint32_t len);                       /* notify */
REFLET_IMPORT(setting_get) int32_t reflet_setting_get(const char *key, uint32_t key_len, char *out, uint32_t cap); /* settings */
REFLET_IMPORT(setting_set) int32_t reflet_setting_set(const char *key, uint32_t key_len, const char *val, uint32_t val_len);
REFLET_IMPORT(storage_read) int32_t reflet_storage_read(const char *name, uint32_t name_len, void *out, uint32_t cap); /* storage */
REFLET_IMPORT(storage_write) int32_t reflet_storage_write(const char *name, uint32_t name_len, const void *data, uint32_t len);
/* net.fetch:<host>; out receives reflet_fetch_header then the body (truncated to fit) */
REFLET_IMPORT(net_fetch) int32_t reflet_net_fetch(int32_t method, const char *url, uint32_t url_len, const void *body, uint32_t body_len, void *out, uint32_t cap);
REFLET_IMPORT(register_command) int32_t reflet_register_command(const char *id, uint32_t id_len, const char *title, uint32_t title_len, int32_t where); /* commands */
REFLET_IMPORT(panel_set) int32_t reflet_panel_set(const char *id, uint32_t id_len, const char *json, uint32_t json_len); /* ui.panel / re.view */
REFLET_IMPORT(status_set) int32_t reflet_status_set(const char *id, uint32_t id_len, const char *text, uint32_t text_len, int32_t tone); /* ui.statusbar */

/* ---- reverse engineering (analysis.read unless noted) ------------------------------------- */
REFLET_IMPORT(re_info) int32_t reflet_re_info(char *out, uint32_t cap);                 /* JSON {path,format,arch,bits,entry} */
REFLET_IMPORT(re_read) int32_t reflet_re_read(uint64_t addr, void *out, uint32_t cap);
REFLET_IMPORT(re_segments) int32_t reflet_re_segments(reflet_segment *out, uint32_t cap_bytes);
REFLET_IMPORT(re_functions) int32_t reflet_re_functions(reflet_function *out, uint32_t cap_bytes);
REFLET_IMPORT(re_blocks) int32_t reflet_re_blocks(uint64_t entry, reflet_block *out, uint32_t cap_bytes);
REFLET_IMPORT(re_il) int32_t reflet_re_il(uint64_t addr, int32_t level, char *out, uint32_t cap);
REFLET_IMPORT(re_xrefs) int32_t reflet_re_xrefs(uint64_t addr, int32_t from, reflet_xref *out, uint32_t cap_bytes);
REFLET_IMPORT(re_get) int32_t reflet_re_get(int32_t what, uint64_t addr, char *out, uint32_t cap);
REFLET_IMPORT(re_set) int32_t reflet_re_set(int32_t what, uint64_t addr, const char *ptr, uint32_t len);   /* analysis.write */
REFLET_IMPORT(re_goto) int32_t reflet_re_goto(uint64_t addr);                                            /* re.view */
REFLET_IMPORT(register_pass) int32_t reflet_register_pass(const char *name, uint32_t name_len);          /* analysis.pass */

/* ---- code (editor.read unless noted) ----------------------------------------------------- */
REFLET_IMPORT(doc_info) int32_t reflet_doc_info(char *out, uint32_t cap);               /* JSON {path,language,version,lines} */
REFLET_IMPORT(doc_text) int32_t reflet_doc_text(char *out, uint32_t cap);
REFLET_IMPORT(doc_selections) int32_t reflet_doc_selections(reflet_selection *out, uint32_t cap_bytes);
REFLET_IMPORT(doc_edit) int32_t reflet_doc_edit(const char *json, uint32_t len);         /* editor.write: [{"start","end","text"}] */
REFLET_IMPORT(doc_select) int32_t reflet_doc_select(const reflet_selection *sels, uint32_t len_bytes); /* editor.write */
REFLET_IMPORT(decorations_set) int32_t reflet_decorations_set(const char *path, uint32_t path_len, const char *json, uint32_t json_len); /* editor.decorate */
REFLET_IMPORT(diagnostics_set) int32_t reflet_diagnostics_set(const char *path, uint32_t path_len, const char *json, uint32_t json_len); /* editor.diagnostics */

/* ---- guest exports ------------------------------------------------------------------------
 * Required: memory, reflet_abi_version, reflet_alloc. Everything else is optional.
 *
 *   REFLET_EXPORT(reflet_abi_version) int32_t reflet_abi_version(void) { return REFLET_ABI_VERSION; }
 *   REFLET_EXPORT(reflet_alloc)       int32_t reflet_alloc(int32_t len);            // 0 = out of memory
 *   REFLET_EXPORT(reflet_init)        int32_t reflet_init(void);                    // register commands, passes
 *   REFLET_EXPORT(reflet_command)     int32_t reflet_command(const char *id, uint32_t id_len, const char *arg, uint32_t arg_len);
 *   REFLET_EXPORT(reflet_event)       int32_t reflet_event(int32_t kind, const char *payload, uint32_t len);
 *   REFLET_EXPORT(reflet_analysis_pass) int32_t reflet_analysis_pass(uint64_t entry);
 *   REFLET_EXPORT(reflet_format)      int64_t reflet_format(const char *src, uint32_t len);  // packed result
 *   REFLET_EXPORT(reflet_highlight)   int64_t reflet_highlight(const char *src, uint32_t len); // language.grammar
 */

static inline int64_t reflet_pack(uint32_t ptr, uint32_t len) { return (int64_t)(((uint64_t)ptr << 32) | len); }
static inline int64_t reflet_pack_status(reflet_status s) { return (int64_t)(int32_t)s | INT64_MIN; }

#ifdef __cplusplus
}
#endif

#endif /* REFLET_PLUGIN_H */
