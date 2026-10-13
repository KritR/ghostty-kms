//! The `kms` application runtime: Ghostty directly on the Linux console
//! via DRM/KMS, with libseat for device access and VT switching, libinput
//! and xkbcommon for input. One fullscreen surface, no windowing system.
const internal_os = @import("../../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("App.zig");
pub const Surface = @import("Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Drm.zig");
    _ = @import("Keyboard.zig");
}
