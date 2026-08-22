//! Basic build information:
//! - Run zig build normally, and zig build -Doptimize=ReleaseSafe for near-production performance.
//! - Use zig build -Dwasm-opt to use ReleaseFast AND highly aggressive wasm-opt (from Binaryen).
//! - Use zig build -Dgen-enums as well to automatically construct src/enums.ts
//! - Use zig test zig/root.zig to run all tests across the codebase.
//! - Change -Daseprite=PATH as necessary (or enforce a default in this file).
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    b.install_path = ".";
    const aseprite_path = b.option([]const u8, "aseprite", "Path to the Aseprite executable (default: aseprite in PATH)") orelse
        b.findProgram(&.{"aseprite"}, &.{}) catch null;
    const gen_enums = b.option(bool, "gen-enums", "Regenerate TypeScript enum definitions (default: no)") orelse false; // -Dgen-enums
    const wasm_opt = b.option(bool, "wasm-opt", "Add a very aggressive pass of optimizations provided by wasm-opt from Binaryen, forcing optimization level to ReleaseFast") orelse false; // -Dwasm-opt
    const memory64 = b.option(bool, "memory64", "Utilize Memory64") orelse false; // -Dmemory64
    // We can bundle this back with Zig in the future once inconsistencies are fixed.
    const relaxed_simd = b.option(bool, "relaxed-simd", "Enable relaxed SIMD when building for WASM (DANGEROUS: reorders instructions in concerning ways)") orelse false; // -Drelaxed-simd
    const build_native = b.option(bool, "native", "Build the native desktop application using Mach Engine (default: false)") orelse false;

    // Feature list: anything almost certainly supported by a browser that already supports WebGPU.
    const wasm_features = [_]std.Target.wasm.Feature{
        .simd128,
        .tail_call,
        .bulk_memory,
        .mutable_globals,
        .sign_ext,
        .nontrapping_fptoint,
        .reference_types,
        .multivalue,
        .exception_handling,
        .extended_const,
    };

    const target = b.standardTargetOptions(if (build_native) .{} else .{
        .default_target = .{
            .cpu_arch = if (memory64) .wasm64 else .wasm32, // WASM 32-bit. Works with 64-bit too (if Memory64 is needed in the future).
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(if (relaxed_simd)
                &(wasm_features ++ [_]std.Target.wasm.Feature{.relaxed_simd})
            else
                &wasm_features),
        },
    });

    // Ask for -Doptimize unconditionally, so that the flag stays valid (and stays in zig build --help)
    // even when -Dwasm-opt answers the question instead. Zig rejects an option that no one reads.
    const requested_optimize = b.standardOptimizeOption(.{});
    if (wasm_opt and b.user_input_options.contains("optimize")) {
        @panic("-Doptimize conflicts with -Dwasm-opt, which always builds ReleaseFast.");
    }

    const optimize: std.builtin.OptimizeMode = if (wasm_opt) .ReleaseFast else requested_optimize;

    if (build_native) {
        // TODO: when SPIR-V is supported by Mach Engine update this logic to work.
        // const app_mod = b.createModule(.{
        //     .root_source_file = b.path("zig/native_app.zig"),
        //     .optimize = optimize,
        //     .target = target,
        // });

        // const mach_dep = b.dependency("mach", .{
        //     .target = target,
        //     .optimize = optimize,
        // });
        // app_mod.addImport("mach", mach_dep.module("mach"));

        // // Read the shader code at build time
        // const shader_content: [:0]u8 = b.build_root.handle.readFileAllocOptions(
        //     b.graph.io,
        //     "src/shader.wgsl",
        //     b.allocator,
        //     .unlimited,
        //     .@"1", // default alignment
        //     0, // null-terminator sentinel!
        // ) catch @panic("Failed to read shader.wgsl.");

        // const native_options = b.addOptions();
        // native_options.addOption([]const u8, "shader_source", shader_content);

        // app_mod.addImport("build_options", native_options.createModule());

        // const exe = @import("mach").addExecutable(mach_dep.builder, .{
        //     .name = "depthwell",
        //     .app = app_mod,
        //     .target = target,
        //     .optimize = optimize,
        // });
        // b.installArtifact(exe);

        // // Package macOS builds as a standalone .app bundle
        // if (target.result.os.tag == .macos) {
        //     const app_dir = "Depthwell.app/Contents";

        //     // Move binary into Depthwell.app/Contents/MacOS/
        //     const install_bin = b.addInstallFileWithDir(
        //         exe.getEmittedBin(),
        //         .{ .custom = b.pathJoin(&.{ app_dir, "MacOS" }) },
        //         "depthwell",
        //     );
        //     b.getInstallStep().dependOn(&install_bin.step);

        //     // Write dynamic Info.plist
        //     const plist_content =
        //         \\<?xml version="1.0" encoding="UTF-8"?>
        //         \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        //         \\<plist version="1.0">
        //         \\<dict>
        //         \\    <key>CFBundleExecutable</key>
        //         \\    <string>depthwell</string>
        //         \\    <key>CFBundleIdentifier</key>
        //         \\    <string>com.user.depthwell</string>
        //         \\    <key>CFBundleName</key>
        //         \\    <string>Depthwell</string>
        //         \\    <key>CFBundlePackageType</key>
        //         \\    <string>APPL</string>
        //         \\    <key>LSMinimumSystemVersion</key>
        //         \\    <string>10.13</string>
        //         \\</dict>
        //         \\</plist>
        //     ;
        //     const plist_file = b.addWriteFile("Info.plist", plist_content);
        //     const install_plist = b.addInstallFileWithDir(
        //         plist_file.getDirectory().path(b, "Info.plist"),
        //         .{ .custom = app_dir },
        //         "Info.plist",
        //     );
        //     install_plist.step.dependOn(&plist_file.step);
        //     b.getInstallStep().dependOn(&install_plist.step);
        // }

        // const run_cmd = b.addRunArtifact(exe);
        // run_cmd.step.dependOn(b.getInstallStep());
        // if (b.args) |args| {
        //     run_cmd.addArgs(args);
        // }
        // const run_step = b.step("run", "Run the native app");
        // run_step.dependOn(&run_cmd.step);
    } else {
        // Standard WASM build pipeline!
        const module = b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Main WASM game build.
        const exe = b.addExecutable(.{ .name = "engine", .root_module = module });

        if (optimize == .Debug) {
            exe.root_module.strip = false;
            exe.lto = .none;
            exe.export_table = true;
        } else {
            exe.root_module.single_threaded = true;
            // exe.root_module.stack_check = false;
            if (optimize != .ReleaseSafe) exe.lto = .full;
        }

        exe.rdynamic = true;
        exe.stack_size = 8 * 65536;

        const wasm_bin: std.Build.LazyPath = if (wasm_opt) blk: {
            const optimize_wasm = b.addSystemCommand(&.{"wasm-opt"});
            optimize_wasm.addFileArg(exe.getEmittedBin());
            optimize_wasm.addArg("-o");
            const optimized = optimize_wasm.addOutputFileArg("main.wasm");
            optimize_wasm.addArgs(&.{
                "-O4",
                // We can keep the fn names, which makes crash info easier to read in release.
                // "--strip-debug",
                "--debuginfo",

                // Required: Binaryen stops with a fatal error if it must read Zig's DWARF 5.
                "--strip-dwarf",
                "--strip-producers",
            });

            optimize_wasm.addArgs(&.{
                "--optimize-instructions",

                // No --flatten/--rereloop here: they run after the -O4 pipeline,
                // so nothing coalesces the locals they introduce. generateChunk() locals grew too big,
                // and V8 sizes wasm frames by local count. Those commands also bloat the file-size!

                "--converge",
                "--gufa-optimizing",
                "--traps-never-happen",
                "--ignore-implicit-traps",
                "--limit-segments",
                "--closed-world",
                "--inline-functions-with-loops",
                "--inline-max-combined-binary-size=100000",
                "--directize",
                "--memory-packing",
                "--optimize-added-constants-propagate",
                "--flexible-inline-max-function-size=100",
                "--one-caller-inline-max-function-size=1",
                "--roundtrip",
                "--low-memory-unused",
            });

            // Invariant: wasm-opt must accept every feature that code generation can emit,
            // or it rejects the module at validation. Both lists come from wasm_features above.
            for (wasm_features) |feature| optimize_wasm.addArg(binaryenFeatureFlag(feature));
            if (memory64) {
                optimize_wasm.addArg("--enable-memory64");
            }
            if (relaxed_simd) {
                optimize_wasm.addArg("--enable-relaxed-simd");
            }

            break :blk optimized;
        } else exe.getEmittedBin();

        const install_wasm = b.addInstallFileWithDir(
            wasm_bin,
            .{ .custom = "" },
            "main.wasm",
        );
        b.getInstallStep().dependOn(&install_wasm.step);

        if (gen_enums) {
            generateEnums(b, &[_][]const u8{ "zig/root.zig", "zig/types/types.zig", "zig/memory.zig" });
        }

        // Bake sprite-layout and light constants into src/shader.wgsl.
        // Every file the generator reads a value out of belongs in this list,
        // or the shader keeps a stale constant while Zig packs against the new one.
        // memory.zig, refine.zig and water.zig decide the Block bit layout the shader unpacks.
        generateShaderConstants(b, &[_][]const u8{
            "zig/types/sprite.zig",
            "zig/render/lighting.zig",
            "zig/memory.zig",
            "zig/state/refine.zig",
            "zig/state/water.zig",
        });

        // Bake per-tile sprite sheet colors into zig/render/particle_colors.zig;
        // hash-guarded like the shader constants.
        const particle_gen = generateParticleColors(b, &[_][]const u8{
            "public/assets/main.png",
        });
        if (particle_gen) |gen_step| exe.step.dependOn(gen_step);

        if (aseprite_path) |path| {
            const export_main = addAsepriteStep(b, path, "aseprite/main.aseprite", "main", "main.png");
            const export_masked = addAsepriteStep(b, path, "aseprite/main.aseprite", "masks", "mainMasked.png");
            const install_main = b.addInstallFile(export_main, "public/assets/main.png");
            const install_masked = b.addInstallFile(export_masked, "public/assets/mainMasked.png");
            exe.step.dependOn(&install_main.step);
            exe.step.dependOn(&install_masked.step);

            // Extract colors only after the fresh sprite sheet lands in public/assets.
            // The hash was taken from the pre-export file, so a sprite sheet change converges over two watcher builds.
            if (particle_gen) |gen_step| gen_step.dependOn(&install_main.step);
        } else {
            std.debug.print("Aseprite executable not found; skipping step. Either add to your system PATH or use -Daseprite.", .{});
        }
    }
}

/// The `wasm-opt` flag that turns on the same wasm feature as `feature`.
/// `wasm-opt` may reject a module that uses a feature it did not get told about.
fn binaryenFeatureFlag(feature: std.Target.wasm.Feature) []const u8 {
    return switch (feature) {
        .simd128 => "--enable-simd",
        .relaxed_simd => "--enable-relaxed-simd",
        .tail_call => "--enable-tail-call",
        .bulk_memory => "--enable-bulk-memory",
        .mutable_globals => "--enable-mutable-globals",
        .sign_ext => "--enable-sign-ext",
        .nontrapping_fptoint => "--enable-nontrapping-float-to-int",
        .reference_types => "--enable-reference-types",
        .multivalue => "--enable-multivalue",
        .exception_handling => "--enable-exception-handling",
        .extended_const => "--enable-extended-const",
        else => std.debug.panic("No wasm-opt flag is known for the wasm feature {t}.", .{feature}),
    };
}

/// Handles `.aseprite` file exports automatically.
fn addAsepriteStep(
    b: *std.Build,
    aseprite_exe: []const u8,
    input_path: []const u8,
    layer_name: []const u8,
    out_filename: []const u8,
) std.Build.LazyPath {
    const run_cmd = b.addSystemCommand(&.{aseprite_exe});
    run_cmd.addArg("-b");
    if (layer_name.len > 0) {
        run_cmd.addArgs(&.{ "--layer", layer_name });
    } else {
        // run_cmd.addArg("--all-layers");
        @panic("Layer name must be non-empty!");
    }

    run_cmd.addFileArg(b.path(input_path));
    run_cmd.addArgs(&.{
        "--sheet-type",
        "rows",
        "--sheet-columns",
        "16",
    });
    run_cmd.addArg("--sheet");
    const output = run_cmd.addOutputFileArg(out_filename);

    // _ = run_cmd.captureStdOut(.{});
    // _ = run_cmd.captureStdErr(.{});
    return output;
}

/// Updates `enums.ts` automatically.
/// `build()` only calls this when the `-Dgen-enums` flag is passed.
fn generateEnums(b: *std.Build, paths: []const []const u8) void {
    const cache_root = b.cache_root.path orelse ".";
    const cache_path = b.pathJoin(&.{ cache_root, "content_hashes.txt" });
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (paths) |path| {
        const content = b.build_root.handle.readFileAlloc(
            b.graph.io,
            path,
            b.allocator,
            .unlimited,
        ) catch |err| {
            std.debug.panic("Warning: skipping enum generation due to being unable to read {s}: {any}\n", .{ path, err });
            return;
        };
        defer b.allocator.free(content);
        hasher.update(content);
    }

    var current_hash_binary: [32]u8 = undefined;
    hasher.final(&current_hash_binary);

    const current_hash_hex: []const u8 = &std.fmt.bytesToHex(current_hash_binary, .lower);
    const old_hash_hex = b.build_root.handle.readFileAlloc(
        b.graph.io,
        cache_path,
        b.allocator,
        .limited(1024), // extra buffer to be safe; exactly the right number of bytes fails
    ) catch |err| blk: {
        if (err != error.FileNotFound) {
            std.debug.panic("Warning: Could not read cache: {any}\n", .{err});
        }
        break :blk b.allocator.alloc(u8, 0) catch "";
    };

    // @import("zig/logger.zig").quickWarn(.{ current_hash_hex, old_hash_hex, std.mem.eql(u8, current_hash_hex, old_hash_hex) });
    defer if (old_hash_hex.len > 0) b.allocator.free(old_hash_hex);

    // Compare the array to the slice, and update the content hash in generate_types.zig if needed.
    if (std.mem.eql(u8, current_hash_hex, old_hash_hex)) {
        return;
    }

    // Now actually update the types, since the files involved were modified.
    const gen_tool = b.addExecutable(.{
        .name = "generate_types",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/generate_types.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // Create exactly ONE module for the game code.
    // const depthwell_mod = b.createModule(.{
    //     .root_source_file = b.path("zig/root.zig"),
    // });

    // // The tool only needs to see the game root
    // gen_tool.root_module.addImport("depthwell", depthwell_mod);

    const run_enums = b.addRunArtifact(gen_tool);
    run_enums.has_side_effects = true;

    // Pass the strings as arguments to the executable.
    run_enums.addArgs(&.{
        cache_root,
        cache_path,
        current_hash_hex,
    });

    const generated_enums = run_enums.captureStdOut(.{});
    const install_ts = b.addInstallFileWithDir(
        generated_enums,
        .{ .custom = "src/" },
        "enums.ts",
    );

    // Add to the main install step.
    b.getInstallStep().dependOn(&install_ts.step);
}

/// Regenerates the `#CONSTANT REGION START, DO NOT MODIFY CONTENTS MANUALLY#` block in `src/shader.wgsl` from the `Sprite` enum.
/// Similar to `generateEnums()`: hashes `paths`, skips entirely when unchanged,
/// otherwise builds and runs `zig/update_shader.zig` (which rewrites the shader in place and updates the cache).
fn generateShaderConstants(b: *std.Build, paths: []const []const u8) void {
    const cache_root = b.cache_root.path orelse ".";
    const cache_path = b.pathJoin(&.{ cache_root, "shader_const_hashes.txt" });
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (paths) |path| {
        const content = b.build_root.handle.readFileAlloc(
            b.graph.io,
            path,
            b.allocator,
            .unlimited,
        ) catch |err| {
            std.debug.panic("Skipping shader-constant generation; could not read {s}: {any}\n", .{ path, err });
        };
        defer b.allocator.free(content);
        hasher.update(content);
    }

    var current_hash_binary: [32]u8 = undefined;
    hasher.final(&current_hash_binary);
    const current_hash_hex: []const u8 = &std.fmt.bytesToHex(current_hash_binary, .lower);

    const old_hash_hex = b.build_root.handle.readFileAlloc(
        b.graph.io,
        cache_path,
        b.allocator,
        .limited(1024),
    ) catch |err| blk: {
        if (err != error.FileNotFound) std.debug.panic("Could not read shader cache: {any}\n", .{err});
        break :blk b.allocator.alloc(u8, 0) catch "";
    };
    defer if (old_hash_hex.len > 0) b.allocator.free(old_hash_hex);

    if (std.mem.eql(u8, current_hash_hex, old_hash_hex)) return;

    const gen_tool = b.addExecutable(.{
        .name = "update_shader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/update_shader.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_gen = b.addRunArtifact(gen_tool);
    run_gen.has_side_effects = true;
    run_gen.addArgs(&.{ cache_root, cache_path, current_hash_hex });
    b.getInstallStep().dependOn(&run_gen.step);
}

/// Regenerates `zig/render/particle_colors.zig` from the exported sprite atlas PNGs.
/// Similar to `generateEnums()`: hashes `paths`, skips entirely when unchanged,
/// otherwise builds and runs `zig/generate_pixel_data.zig` (which rewrites the file in-place and updates cache).
/// Returns the run step (for sequencing against the atlas export), or null when skipped.
fn generateParticleColors(b: *std.Build, paths: []const []const u8) ?*std.Build.Step {
    const cache_root = b.cache_root.path orelse ".";
    const cache_path = b.pathJoin(&.{ cache_root, "particle_color_hashes.txt" });
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (paths) |path| {
        const content = b.build_root.handle.readFileAlloc(
            b.graph.io,
            path,
            b.allocator,
            .unlimited,
        ) catch |err| {
            std.debug.panic("Skipping particle-color generation; could not read {s}: {any}\n", .{ path, err });
        };
        defer b.allocator.free(content);
        hasher.update(content);
    }

    var current_hash_binary: [32]u8 = undefined;
    hasher.final(&current_hash_binary);
    const current_hash_hex: []const u8 = &std.fmt.bytesToHex(current_hash_binary, .lower);

    const old_hash_hex = b.build_root.handle.readFileAlloc(
        b.graph.io,
        cache_path,
        b.allocator,
        .limited(1024),
    ) catch |err| blk: {
        if (err != error.FileNotFound) std.debug.panic("Could not read particle-color cache: {any}\n", .{err});
        break :blk b.allocator.alloc(u8, 0) catch "";
    };
    defer if (old_hash_hex.len > 0) b.allocator.free(old_hash_hex);

    if (std.mem.eql(u8, current_hash_hex, old_hash_hex)) return null;

    const gen_tool = b.addExecutable(.{
        .name = "generate_pixel_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/generate_pixel_data.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_gen = b.addRunArtifact(gen_tool);
    run_gen.has_side_effects = true;
    run_gen.addArgs(&.{ cache_root, cache_path, current_hash_hex });
    b.getInstallStep().dependOn(&run_gen.step);
    return &run_gen.step;
}
