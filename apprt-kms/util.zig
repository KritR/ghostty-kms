//! Small helpers shared across the kms apprt.
const std = @import("std");
const c = @import("kms_c");

/// The calling thread's C errno.
pub fn errno() c_int {
    return c.__errno_location().*;
}

/// Read an environment variable. kms-specific settings use environment
/// variables (GHOSTTY_KMS_*) so that we don't have to patch Ghostty's
/// config parser.
pub fn env(name: [*:0]const u8) ?[:0]const u8 {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return s;
}

pub fn envInt(comptime T: type, name: [*:0]const u8) ?T {
    const s = env(name) orelse return null;
    return std.fmt.parseInt(T, s, 10) catch {
        std.log.scoped(.kms).warn("ignoring invalid integer {s}={s}", .{ name, s });
        return null;
    };
}

pub fn envFloat(name: [*:0]const u8) ?f32 {
    const s = env(name) orelse return null;
    return std.fmt.parseFloat(f32, s) catch {
        std.log.scoped(.kms).warn("ignoring invalid number {s}={s}", .{ name, s });
        return null;
    };
}

pub fn envBool(name: [*:0]const u8) bool {
    const s = env(name) orelse return false;
    return std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "yes");
}

/// Monotonic time in nanoseconds.
pub fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}
