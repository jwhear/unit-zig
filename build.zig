const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    //TODO build c/unit


    const lib = b.addStaticLibrary("unit-zig", "src/unit.zig");
    lib.setTarget(target);
    lib.setBuildMode(mode);
    addUnit(lib);
    lib.install();

    // Combines libunit-zig.a with libunit.a to make a single fat lib
    //b.addSystemCommand(&[_][]const u8{
        //"ar", "-M", "libunit-zig.mri"
    //});

    const pkg = std.build.Pkg{
        .name = "unit",
        .path = .{ .path="src/unit.zig" },
    };

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    tests.linkLibC();
    addUnit(tests);
    //tests.linkLibrary(lib);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);

    const demo = b.addExecutable("demo1", "examples/demo1.zig");
    demo.setTarget(target);
    demo.setBuildMode(mode);
    demo.addPackage(pkg);
    addUnit(demo);
    demo.install();
}

pub fn addUnit(obj: *std.build.LibExeObjStep) void {
    obj.linkLibC();
    obj.addIncludeDir("c/unit/src/");
    obj.addIncludeDir("c/unit/build/");
    obj.addLibPath("c/unit/build/");
    obj.linkSystemLibrary("unit");
}
