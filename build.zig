const std = @import("std");
const portaudio = @import("portaudio");

fn hostApisToStrings(arena: std.mem.Allocator, host_apis: []const portaudio.HostApi) ![]const []const u8 {
    const strings = try arena.alloc([]const u8, host_apis.len);
    for (host_apis, strings) |host_api, *string| {
        string.* = @tagName(host_api);
    }
    return strings;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const portaudio_host_apis = b.option([]const portaudio.HostApi, "portaudio-host-api", "Enable specific host audio APIs");

    // PortAudio
    const portaudio_dep = b.dependency("portaudio", .{
        .target = target,
        .optimize = optimize,
        .@"host-api" = try hostApisToStrings(b.allocator, if (portaudio_host_apis) |opts| opts else switch (target.result.os.tag) {
            .macos => portaudio.HostApi.defaults.macos,
            .linux => portaudio.HostApi.defaults.linux,
            .windows => portaudio.HostApi.defaults.windows,
            else => std.debug.panic("unsupported os {s}", .{@tagName(target.result.os.tag)}),
        }),
    });
    const portaudio_lib = portaudio_dep.artifact("portaudio");
    portaudio_lib.bundle_ubsan_rt = true;
    exe_mod.addIncludePath(portaudio_dep.path("include"));
    exe_mod.linkLibrary(portaudio_lib);

    const exe = b.addExecutable(.{
        .name = "zenpaper",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wasm_agent = b.addExecutable(.{
        .name = "zenpaper-wasm-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_agent.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    wasm_agent.entry = .disabled;
    wasm_agent.rdynamic = true;
    wasm_agent.import_memory = true;
    wasm_agent.export_memory = false;

    const build_wasm_agent_step = b.step("build-wasm-agent", "Build WASM agent; assumes repository setup");
    build_wasm_agent_step.dependOn(&b.addInstallFile(
        wasm_agent.getEmittedBin(),
        "../frontend/zenpaper-wasm-agent.wasm",
    ).step);
}
