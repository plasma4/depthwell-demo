const std = @import("std");

// Run zig build normally, and zig build -Doptimize=ReleaseFast for the final version. Use zig build enum to automatically construct src/enums.ts and zig test "zig/root.zig" to run all tests across the codebase.
pub fn build(b: *std.Build) void {
    b.install_path = ".";
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32, // WASM 32-bit. Should work with 64-bit too (if Memory64 is needed for some reason).
            .os_tag = .freestanding,
        },
    });

    // Add ReleaseFast flag for release.
    // Currently, all files are using setFloatMode by default until real32/real64 releases (which will also be better at tracking UB).
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
    exe.rdynamic = true; // export functions with "export" keyword
    exe.entry = .disabled; // No main()
    exe.stack_size = 4 * 65536; // can increase as necessary
    exe.initial_memory = 16 * 65536; // 4 MiB
    // exe.global_base = 0; // removed in favor of letting Zig manage pointers
    // if (optimize == .Debug) {
    //     exe.use_llvm = false;
    //     exe.use_lld = false;
    // }

    const install_wasm = b.addInstallFileWithDir(
        exe.getEmittedBin(),
        .{ .custom = "src/" },
        "main.wasm",
    );
    b.getInstallStep().dependOn(&install_wasm.step); // install

    const gen_tool = b.addExecutable(.{
        .name = "generate_types",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/generate_types.zig"),
            .target = b.graph.host, // Compiles for your computer, not WASM
            .optimize = .Debug,
        }),
    });
    // if (optimize == .Debug) {
    //     gen_tool.use_llvm = false;
    //     gen_tool.use_lld = false;
    // }

    const run_enums = b.addRunArtifact(gen_tool);
    const generated_enums = run_enums.captureStdOut();
    const install_ts = b.addInstallFileWithDir(
        generated_enums,
        .{ .custom = "src/" }, // This prevents exporting from happening in zig-out.
        "enums.ts",
    );

    const gen_step = b.step("enum", "Regenerate TypeScript enum definitions");
    gen_step.dependOn(&install_ts.step);
}
