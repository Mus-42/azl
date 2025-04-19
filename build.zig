const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const azl = b.addModule("azl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const Example = struct {
        name: []const u8,
        root_file: []const u8,
    };

    const EXAMPLES = [_]Example{
        .{ .name = "extract", .root_file = "examples/extract.zig" },
        .{ .name = "compress", .root_file = "examples/compress.zig" },
    };

    for (EXAMPLES) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.root_file),
            .target = target,
            .optimize = optimize,
        });

        example_exe.root_module.addImport("azl", azl);

        const run_example = b.addRunArtifact(example_exe);

        if (b.args) |args| {
            run_example.addArgs(args);
        }

        const run_step = b.step(example.name, "run example");
        run_step.dependOn(&run_example.step);
    }


    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
