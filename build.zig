const std = @import("std");

// zig build                 -> zig-out/bin/silt.wasm (the simulation kernel)
// zig build test            -> native unit tests for the kernel
// zig build -Dwasm-optimize=ReleaseFast   (default: ReleaseSmall)
pub fn build(b: *std.Build) void {
    const native = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimisation mode for silt.wasm") orelse .ReleaseSmall;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        // 128-bit SIMD for the @Vector(4, f32) kernels; bulk memory for memset/memcpy.
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .simd128, .bulk_memory }),
    });
    const wasm = b.addExecutable(.{
        .name = "silt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = native,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the kernel's unit tests");
    test_step.dependOn(&run_tests.step);
}
