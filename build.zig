const std = @import("std");

// Run zig build normally, and zig build -Doptimize=ReleaseFast for the final version. Use zig build --Dgen-enums as well to automatically construct src/enums.ts and zig test "zig/root.zig" to run all tests across the codebase.
// To make a final ReleaseFast build with even more optimization, use wasm-opt like this:
// { TEMP_WASM=$(mktemp -t wasm_opt_XXXXXX); wasm-opt src/main.wasm -o "$TEMP_WASM" -O4 --strip-debug --strip-dwarf --strip-producers --enable-threads --enable-simd && mv "$TEMP_WASM" src/main.wasm; }
pub fn build(b: *std.Build) void {
    // TODO add in wasm-opt for ReleaseFast builds for even more optimization!
    b.install_path = ".";
    const gen_enums = b.option(bool, "gen-enums", "Regenerate TypeScript enum definitions") orelse false; // -Dgen-enums
    const memory64 = b.option(bool, "memory64", "Utilize Memory64 (and enable relaxed SIMD)") orelse false; // -Dmemory64
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = if (memory64) .wasm64 else .wasm32, // WASM 32-bit. Works with 64-bit too (if Memory64 is needed in the future).
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(if (memory64) &.{ // We add features that are almost certainly supported by a browser that already supports WebGPU.
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
                .relaxed_simd,
            } else &.{ // We add features that are almost certainly supported by a browser that already supports WebGPU.
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
            }),
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    // Main WASM game build
    const exe = b.addExecutable(.{
        .name = "engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (optimize == .Debug) {
        exe.root_module.strip = false; // try to reduce any WASM optimization
        exe.lto = .none;
        exe.export_table = true;
    }
    if (optimize == .ReleaseFast) {
        exe.lto = .full;
    }
    exe.rdynamic = true; // export functions with "export" keyword
    exe.entry = .disabled; // No main()
    exe.stack_size = 4 * 65536; // 4 pages, can increase as necessary
    if (optimize == .Debug) {
        // exe.use_llvm = false; // can't do this for WASM ):
        // exe.use_lld = false; // nope
    }

    // removed since Zig manages pointers automatically
    // exe.global_base = 8;

    const install_wasm = b.addInstallFileWithDir(
        exe.getEmittedBin(),
        .{ .custom = "src/" },
        "main.wasm",
    );
    b.getInstallStep().dependOn(&install_wasm.step); // install
    if (gen_enums) {
        generateEnums(b, &[_][]const u8{ "zig/root.zig", "zig/types.zig", "zig/memory.zig" });
    }
}

fn generateEnums(b: *std.Build, paths: []const []const u8) void {
    const cache_root = b.cache_root.path orelse ".";
    const cache_path = b.pathJoin(&.{ cache_root, "content_hashes.txt" });
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (paths) |path| {
        const content = std.fs.cwd().readFileAlloc(b.allocator, path, 1024 * 1024 * 50) catch |err| {
            std.debug.panic("Warning: skipping enum generation due to being unable to read {s}: {any}\n", .{ path, err });
            return;
        };
        defer b.allocator.free(content);
        hasher.update(content);
    }

    var current_hash_binary: [32]u8 = undefined;
    hasher.final(&current_hash_binary);

    const current_hash_hex: []const u8 = &std.fmt.bytesToHex(current_hash_binary, .lower);
    const old_hash_hex: []const u8 = std.fs.cwd().readFileAlloc(b.allocator, cache_path, 64) catch |err| blk: {
        if (err != error.FileNotFound) {
            std.debug.panic("Warning: Could not read cache: {any}\n", .{err});
        }
        break :blk b.allocator.alloc(u8, 0) catch "";
    };
    // @import("zig/logger.zig").quick_warn(.{ current_hash_hex, old_hash_hex, std.mem.eql(u8, current_hash_hex, old_hash_hex) });
    defer if (old_hash_hex.len > 0) b.allocator.free(old_hash_hex);

    // compare array to slice and update content hash if necessary in generate_types.zig
    if (std.mem.eql(u8, current_hash_hex, old_hash_hex)) {
        return;
    }

    // now actually update the types if necessary
    const gen_tool = b.addExecutable(.{
        .name = "generate_types",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/generate_types.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_enums = b.addRunArtifact(gen_tool);
    run_enums.has_side_effects = true;

    // Pass the strings as arguments to the executable
    run_enums.addArgs(&.{
        cache_root,
        cache_path,
        current_hash_hex,
    });

    const generated_enums = run_enums.captureStdOut();
    const install_ts = b.addInstallFileWithDir(
        generated_enums,
        .{ .custom = "src/" },
        "enums.ts",
    );

    // Add to the main install step
    b.getInstallStep().dependOn(&install_ts.step);
}
