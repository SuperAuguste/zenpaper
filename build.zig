const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // PortAudio
    const portaudio = b.dependency("portaudio", .{});
    const portaudio_lib = portaudio.artifact("portaudio");
    portaudio_lib.bundle_ubsan_rt = true;
    exe_mod.addIncludePath(portaudio.path("include"));
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
}
