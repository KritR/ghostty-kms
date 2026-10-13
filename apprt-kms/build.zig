//! Build wiring for the kms apprt. Called from `src/build/SharedDeps.zig`
//! (see patches/) when building with `-Dapp-runtime=kms`.
//!
//! We only link C system libraries through pkg-config; no Zig package
//! dependencies are added (upstream's Nix build pre-fetches those).
const std = @import("std");
const translate_c = @import("translate_c");

/// pkg-config names of the system libraries the kms apprt needs.
pub const system_libs = [_][]const u8{
    "libdrm",
    "gbm",
    "libinput",
    "libudev",
    "xkbcommon",
    "libseat",
    "glesv2",
};

pub fn add(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    link_opts: std.Build.Module.LinkSystemLibraryOptions,
) !void {
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    for (system_libs) |lib| step.root_module.linkSystemLibrary(lib, link_opts);

    // All C headers used by the kms apprt are translated as one module,
    // imported as `@import("kms_c")`.
    try translate_c.addImportToModule(b, "kms_c", step.root_module, .{
        .source = .{ .file = b.path("src/apprt/kms/c.c") },
        .target = target,
        .optimize = optimize,
        .link_system_libs = &system_libs,
    });
}
