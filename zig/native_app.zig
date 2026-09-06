//! Starts up Mach Engine for native builds.
//! Does not work yet.
//! Mach Engine work is paused until Zig SPIR-V support is complete.
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const dw = @import("root.zig");
const build_options = @import("build_options");
const shader_source: []const u8 = build_options.shader_source;

const App = @This();

pub const Modules = mach.Modules(.{
    mach.Core,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .deinit,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

// Update pipeline references to separate targets
tile_pipeline: ?*gpu.RenderPipeline = null,
background_pipeline: ?*gpu.RenderPipeline = null,
entity_pipeline: ?*gpu.RenderPipeline = null,
app_thread: mach.Thread,
window: mach.ObjectID,

pub var io: std.Io = undefined;
pub var start_timestamp: std.Io.Timestamp = undefined;
var threaded_io = std.Io.Threaded.init_single_threaded;

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
) !void {
    core.on_exit = app_mod.id.deinit;

    // Initialize threaded IO backend & startup timestamp
    io = threaded_io.io();
    start_timestamp = std.Io.Clock.awake.now(io);

    // Initialize our underlying game states
    dw.main();
    dw.init();

    const window = try core.windows.new(.{
        .title = "Depthwell",
        .on_render = app_mod.id.render,
    });

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .window = window,
    };
}

fn setupPipeline(core: *mach.Core, app: *App) !void {
    var window = core.windows.getValue(app.window);
    defer core.windows.setValueRaw(app.window, window);

    // Split monolithic WGSL source into parts:
    @setEvalBranchQuota(1e6);
    const tile_idx = comptime std.mem.find(u8, shader_source, "// TILE SECTION") orelse @compileError("Missing tile tag");
    const background_idx = comptime std.mem.find(u8, shader_source, "// BACKGROUND SECTION") orelse @compileError("Missing background tag");
    const entity_idx = comptime std.mem.find(u8, shader_source, "// ENTITY SECTION") orelse @compileError("Missing entity tag");
    const footer_idx = comptime std.mem.find(u8, shader_source, "// OKLAB AND COLOR SPACE") orelse @compileError("Missing footer tag");

    const header = shader_source[0..tile_idx];
    const tile = shader_source[tile_idx..background_idx];
    const background = shader_source[background_idx..entity_idx];
    const entity = shader_source[entity_idx..footer_idx];
    const footer = shader_source[footer_idx..];

    // Concatenate sections into individual pipeline shaders
    const tile_raw = header ++ tile ++ footer;
    const tile_src: [*:0]const u8 = (tile_raw ++ "\x00")[0..tile_raw.len :0];

    const background_raw = header ++ background ++ footer;
    const background_src: [*:0]const u8 = (background_raw ++ "\x00")[0..background_raw.len :0];

    const entity_raw = header ++ entity ++ footer;
    const entity_src: [*:0]const u8 = (entity_raw ++ "\x00")[0..entity_raw.len :0];

    // Create unique ShaderModules
    const tile_module = window.device.createShaderModuleWGSL("tile.wgsl", tile_src);
    defer tile_module.release();

    const background_module = window.device.createShaderModuleWGSL("background.wgsl", background_src);
    defer background_module.release();

    const entity_module = window.device.createShaderModuleWGSL("entity.wgsl", entity_src);
    defer entity_module.release();

    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend,
    };

    // Background pipeline!
    const background_fragment = gpu.FragmentState.init(.{
        .module = background_module,
        .entry_point = "fs_background",
        .targets = &.{color_target},
    });
    const background_desc = gpu.RenderPipeline.Descriptor{
        .label = "background_pipeline",
        .fragment = &background_fragment,
        .vertex = gpu.VertexState{
            .module = background_module,
            .entry_point = "vs_background",
        },
    };
    app.background_pipeline = window.device.createRenderPipeline(&background_desc);

    // Tile pipeline!
    const tile_fragment = gpu.FragmentState.init(.{
        .module = tile_module,
        .entry_point = "fs_tile",
        .targets = &.{color_target},
    });
    const tile_desc = gpu.RenderPipeline.Descriptor{
        .label = "tile_pipeline",
        .fragment = &tile_fragment,
        .vertex = gpu.VertexState{
            .module = tile_module,
            .entry_point = "vs_tile",
        },
    };
    app.tile_pipeline = window.device.createRenderPipeline(&tile_desc);

    // Entity pipeline!
    const entity_fragment = gpu.FragmentState.init(.{
        .module = entity_module,
        .entry_point = "fs_entity",
        .targets = &.{color_target},
    });
    const entity_desc = gpu.RenderPipeline.Descriptor{
        .label = "entity_pipeline",
        .fragment = &entity_fragment,
        .vertex = gpu.VertexState{
            .module = entity_module,
            .entry_point = "vs_entity",
        },
    };
    app.entity_pipeline = window.device.createRenderPipeline(&entity_desc);
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(core: *mach.Core) void {
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .close => core.exit(),
            else => {},
        }
    }

    // TODO: frame drop logic
    dw.tick(1.0, 1);
}

pub fn render(app: *App, core: *mach.Core) !void {
    const pipeline = app.background_pipeline orelse {
        try setupPipeline(core, app);
        return;
    };
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(app.window);

    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    const deep_space_black = gpu.Color{ .r = 0.05, .g = 0.05, .b = 0.07, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = deep_space_black,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer render_pass.release();

    render_pass.setPipeline(pipeline);
    render_pass.draw(3, 1, 0, 0);
    render_pass.end();

    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
}

pub fn deinit(app: *App) void {
    app.app_thread.join();
    if (app.tile_pipeline) |p| p.release();
    if (app.background_pipeline) |p| p.release();
    if (app.entity_pipeline) |p| p.release();
}

// Linker section!
pub export fn jsMessage(ptr: u64, len: usize, message_type: dw.logger.LogCategory) void {
    const msg = ptr[0..len];
    const prefix = switch (message_type) {
        .info => "[INFO] ",
        .warn => "[WARN] ",
        .err => "[ERROR] ",
        else => "[LOG] ",
    };
    std.debug.print("{s}{s}\n", .{ prefix, msg });
}

pub export fn jsWriteText(id: u8, ptr: u64, len: usize) void {
    const text = ptr[0..len];
    std.debug.print("[UI Span {d}] {s}\n", .{ id, text });
}

pub export fn jsGetTime() f64 {
    const now = std.Io.Clock.awake.now(io);
    const elapsed = start_timestamp.durationTo(now);
    return @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1_000_000.0;
}

pub export fn jsHandleVisibleChunks(opacity: f64, wireframe_opacity: f64) void {
    _ = opacity;
    _ = wireframe_opacity;
}

pub export fn jsHandleVisibleEntities() void {}

pub export fn jsSetMouseType(mouse_type: dw.mouse.CursorType) void {
    _ = mouse_type;
}

pub export fn jsPlaySound(soundId: u32, volume: f64, pitch: f64) void {
    _ = soundId;
    _ = volume;
    _ = pitch;
}
