//! libseat wrapper. Gives us access to DRM and input devices without
//! running as root (via seatd or logind) and notifies us when our session
//! is enabled or disabled, which is how VT switching works.
const Seat = @This();

const std = @import("std");
const c = @import("kms_c");
const util = @import("util.zig");

const log = std.log.scoped(.kms_seat);

/// Callbacks invoked from `dispatch` when the seat state changes.
pub const Handler = struct {
    ctx: *anyopaque,
    enable: *const fn (ctx: *anyopaque) void,
    disable: *const fn (ctx: *anyopaque) void,
};

seat: *c.struct_libseat,

/// libseat keeps a pointer to the listener, so it lives here and the
/// Seat must not move after `init`.
listener: c.struct_libseat_seat_listener,

/// True while our session is the active one on the seat.
active: bool = false,

/// Set once the owner is ready to receive callbacks. Before that, state
/// changes only update `active`.
handler: ?Handler = null,

pub fn init(self: *Seat) !void {
    self.* = .{
        .seat = undefined,
        .listener = .{
            .enable_seat = enableSeat,
            .disable_seat = disableSeat,
        },
    };

    // Route libseat's own logging through ours.
    c.libseat_set_log_level(c.LIBSEAT_LOG_LEVEL_INFO);

    self.seat = c.libseat_open_seat(&self.listener, self) orelse {
        log.err("failed to open seat; is seatd or logind running and are " ++
            "we on a VT of our own? errno={}", .{util.errno()});
        return error.SeatOpenFailed;
    };
    errdefer _ = c.libseat_close_seat(self.seat);

    // The seat is not usable until it has been enabled at least once. If
    // our session never becomes active (e.g. we were started outside a
    // VT session) give up rather than hang.
    const timeout_ms: u64 = util.envInt(u64, "GHOSTTY_KMS_SEAT_TIMEOUT") orelse 10_000;
    const deadline = util.nowNs() + timeout_ms * std.time.ns_per_ms;
    while (!self.active) {
        const now = util.nowNs();
        if (now >= deadline) {
            log.err("timed out waiting for the seat to become active; run " ++
                "ghostty from a VT login (not over SSH or inside another " ++
                "graphical session)", .{});
            return error.SeatTimeout;
        }
        const remaining_ms: c_int = @intCast(@min((deadline - now) / std.time.ns_per_ms + 1, 1000));
        if (c.libseat_dispatch(self.seat, remaining_ms) < 0) {
            log.err("libseat_dispatch failed while waiting for seat errno={}", .{util.errno()});
            return error.SeatDispatchFailed;
        }
    }

    log.info("opened seat name={s}", .{self.name()});
}

pub fn deinit(self: *Seat) void {
    _ = c.libseat_close_seat(self.seat);
}

pub fn name(self: *const Seat) [:0]const u8 {
    return std.mem.span(c.libseat_seat_name(self.seat));
}

/// The fd to poll for seat events. Call `dispatch` when readable.
pub fn fd(self: *const Seat) c_int {
    return c.libseat_get_fd(self.seat);
}

pub fn dispatch(self: *Seat) !void {
    if (c.libseat_dispatch(self.seat, 0) < 0) return error.SeatDispatchFailed;
}

pub const Device = struct {
    fd: c_int,
    id: c_int,
};

/// Open a device node (DRM or evdev) through the seat.
pub fn openDevice(self: *Seat, path: [*:0]const u8) !Device {
    var dev_fd: c_int = -1;
    const id = c.libseat_open_device(self.seat, path, &dev_fd);
    if (id < 0) {
        log.warn("failed to open device path={s} errno={}", .{ path, util.errno() });
        return error.DeviceOpenFailed;
    }
    return .{ .fd = dev_fd, .id = id };
}

pub fn closeDevice(self: *Seat, dev: Device) void {
    _ = c.libseat_close_device(self.seat, dev.id);
    _ = c.close(dev.fd);
}

/// Switch to another VT/session. Used for Ctrl+Alt+Fn.
pub fn switchSession(self: *Seat, session: c_int) void {
    log.info("switching to session={}", .{session});
    if (c.libseat_switch_session(self.seat, session) < 0) {
        log.warn("failed to switch session errno={}", .{util.errno()});
    }
}

fn enableSeat(_: ?*c.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(userdata orelse return));
    log.info("seat enabled", .{});
    self.active = true;
    if (self.handler) |h| h.enable(h.ctx);
}

fn disableSeat(seat: ?*c.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Seat = @ptrCast(@alignCast(userdata orelse return));
    log.info("seat disabled", .{});
    self.active = false;
    if (self.handler) |h| h.disable(h.ctx);

    // We must acknowledge the disable once we've stopped using devices.
    _ = c.libseat_disable_seat(seat);
}
