const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_amalgamation = b.dependency("sqlite_amalgamation", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = sqlite_amalgamation.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(sqlite_amalgamation.path("."));
    const c_module = translate_c.createModule();

    const sqlite = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .imports = &.{
            .{ .name = "c", .module = c_module },
        },
    });
    sqlite.addCSourceFile(.{ .file = sqlite_amalgamation.path("sqlite3.c") });

    const exe = b.addExecutable(.{
        .name = "tummy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run command");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
