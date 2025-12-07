const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    _ = b.standardOptimizeOption(.{});

    const root_module = b.addModule("quic_server_root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    addInternalPackages(b, root_module);

    const exe = b.addExecutable(.{
        .name = "quic-server-zig",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_root_module = b.addModule("quic_server_test_root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    addInternalPackages(b, test_root_module);

    const exe_tests = b.addTest(.{
        .root_module = test_root_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

fn pkgPath(b: *std.Build, comptime pathRelativeToProjectRoot: []const u8) std.Build.LazyPath {
    // Use relative path from build.zig location
    return b.path(pathRelativeToProjectRoot);
}

fn addInternalPackages(b: *std.Build, module: *std.Build.Module) void {
    module.addImport("variable_length_vector", b.addModule("variable_length_vector", .{
        .root_source_file = pkgPath(b, "src/variable_length_vector.zig"),
    }));
    module.addImport("bytes", b.addModule("bytes", .{
        .root_source_file = pkgPath(b, "src/bytes.zig"),
    }));
    module.addImport("utils", b.addModule("utils", .{
        .root_source_file = pkgPath(b, "src/utils.zig"),
    }));
}
