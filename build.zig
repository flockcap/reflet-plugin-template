// SPDX-License-Identifier: MIT
//! `zig build`       compiles every example to zig-out/<example>/plugin.wasm and packs
//!                   zig-out/<id>-<version>.reflet-plugin (what you upload to a GitHub Release).
//! `zig build test`  runs the examples' native unit tests and the packer's.
//!
//! Add your own plugin: copy an example folder and list it in `plugins` below.
const std = @import("std");

const plugins = [_][]const u8{ "re-example", "code-example" };

/// Native unit tests (pure std code, run on the host).
const native_tests = [_][]const u8{ "re-example/decode.zig", "code-example/todo.zig", "tools/pack.zig", "tools/zipw.zig" };

pub fn build(b: *std.Build) void {
    const host_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The feature set Reflet's WebAssembly interpreter runs: MVP + bulk memory, multi-value,
    // sign extension and non-trapping float-to-int.
    const F = std.Target.wasm.Feature;
    var features = std.Target.Cpu.Feature.Set.empty;
    for ([_]F{ .bulk_memory, .multivalue, .sign_ext, .nontrapping_fptoint }) |f| features.addFeature(@backingInt(f));
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = features,
    });
    const abi = b.createModule(.{ .root_source_file = b.path("sdk/abi.zig") });
    const sdk = b.createModule(.{
        .root_source_file = b.path("sdk/reflet.zig"),
        .imports = &.{.{ .name = "reflet_abi", .module = abi }},
    });

    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/pack.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });

    for (plugins) |dir| {
        const exe = b.addExecutable(.{
            .name = "plugin",
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}/main.zig", .{dir})),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "reflet", .module = sdk }},
            }),
        });
        exe.entry = .disabled;
        exe.rdynamic = true;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, b.fmt("{s}/plugin.wasm", .{dir})).step);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(b.fmt("{s}/reflet-plugin.toml", .{dir})), .prefix, b.fmt("{s}/reflet-plugin.toml", .{dir})).step);

        // <id>-<version>.reflet-plugin (named from the manifest by the packer)
        const run = b.addRunArtifact(pack);
        run.addDirectoryArg(b.path(dir));
        // a directory argument is not content-hashed: re-pack every build (it takes milliseconds)
        // so a new file under assets/ is never missed
        run.has_side_effects = true;
        run.addFileArg(exe.getEmittedBin());
        const out = run.addOutputDirectoryArg("dist");
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "" }).step);
    }

    const test_step = b.step("test", "Run the native unit tests");
    for (native_tests) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(file), .target = host_target, .optimize = optimize }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
