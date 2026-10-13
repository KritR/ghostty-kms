//! Mouse cursor on the DRM cursor plane (legacy cursor API). The image is
//! a small dumb buffer we draw ourselves: an arrow, or an I-beam over text.
//! If the driver has no cursor plane, the cursor is simply not shown.
const Cursor = @This();

const std = @import("std");
const c = @import("kms_c");
const Drm = @import("Drm.zig");
const util = @import("util.zig");

const log = std.log.scoped(.kms_cursor);

pub const Shape = enum { arrow, ibeam };

drm: *Drm,

/// Dumb buffer holding the cursor image (ARGB8888, premultiplied).
handle: u32 = 0,
pitch: u32 = 0,
map: ?[]align(std.heap.page_size_min) u8 = null,
/// Cursor plane size reported by the driver (usually 64x64).
size: u32 = 64,
/// Integer scale applied to the drawn shapes for HiDPI.
scale: u32 = 1,

shape: Shape = .arrow,
hot_x: i32 = 0,
hot_y: i32 = 0,

x: i32 = 0,
y: i32 = 0,

/// Hidden until the pointer first moves, so keyboard-only setups never
/// see a cursor, and while the core asks for it to be hidden.
moved: bool = false,
hidden_by_core: bool = false,

/// False if the hardware cursor isn't usable.
available: bool = false,

/// False while we don't own the seat (and so can't touch the hardware).
/// State changes made meanwhile are pushed by the next `apply`.
active: bool = true,

pub fn init(self: *Cursor, drm: *Drm, content_scale: f32) void {
    self.* = .{ .drm = drm };
    self.scale = @max(1, @as(u32, @intFromFloat(@round(content_scale))));

    var cap: u64 = 0;
    if (c.drmGetCap(drm.fd(), c.DRM_CAP_CURSOR_WIDTH, &cap) == 0 and cap > 0) self.size = @intCast(cap);
    // Our shapes need at least 32x32 per scale step.
    while (self.scale > 1 and self.size < 32 * self.scale) self.scale -= 1;

    var size: u64 = 0;
    if (c.drmModeCreateDumbBuffer(drm.fd(), self.size, self.size, 32, 0, &self.handle, &self.pitch, &size) != 0) {
        log.info("no dumb buffer for cursor errno={}, cursor disabled", .{util.errno()});
        return;
    }
    var offset: u64 = 0;
    if (c.drmModeMapDumbBuffer(drm.fd(), self.handle, &offset) != 0) {
        log.info("failed to map cursor buffer errno={}", .{util.errno()});
        _ = c.drmModeDestroyDumbBuffer(drm.fd(), self.handle);
        return;
    }
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, drm.fd(), @intCast(offset));
    if (ptr == c.MAP_FAILED) {
        log.info("failed to mmap cursor buffer errno={}", .{util.errno()});
        _ = c.drmModeDestroyDumbBuffer(drm.fd(), self.handle);
        return;
    }
    self.map = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..@intCast(size)];
    self.available = true;
    self.draw();
}

pub fn deinit(self: *Cursor) void {
    if (!self.available) return;
    _ = c.drmModeSetCursor(self.drm.fd(), self.drm.crtc_id, 0, 0, 0);
    if (self.map) |m| _ = c.munmap(m.ptr, m.len);
    _ = c.drmModeDestroyDumbBuffer(self.drm.fd(), self.handle);
}

/// Called on seat enable/disable. Re-applies state when re-enabled; the
/// caller does that after the modeset, which resets the cursor plane.
pub fn setActive(self: *Cursor, active: bool) void {
    self.active = active;
}

pub fn setShape(self: *Cursor, shape: Shape) void {
    if (self.shape == shape) return;
    self.shape = shape;
    if (!self.available) return;
    self.draw();
    self.apply();
}

pub fn setHidden(self: *Cursor, hidden: bool) void {
    if (self.hidden_by_core == hidden) return;
    self.hidden_by_core = hidden;
    self.apply();
}

pub fn move(self: *Cursor, x: f64, y: f64) void {
    self.x = @intFromFloat(x);
    self.y = @intFromFloat(y);
    if (!self.moved) {
        self.moved = true;
        self.apply();
        return;
    }
    if (!self.available or !self.active or !self.visible()) return;
    _ = c.drmModeMoveCursor(self.drm.fd(), self.drm.crtc_id, self.x - self.hot_x, self.y - self.hot_y);
}

fn visible(self: *const Cursor) bool {
    return self.moved and !self.hidden_by_core;
}

/// Push the current state to the hardware. Also used after a modeset
/// (e.g. returning from another VT), which resets the cursor plane.
pub fn apply(self: *Cursor) void {
    if (!self.available or !self.active) return;
    const fd = self.drm.fd();
    if (!self.visible()) {
        _ = c.drmModeSetCursor(fd, self.drm.crtc_id, 0, 0, 0);
        return;
    }
    if (c.drmModeSetCursor2(fd, self.drm.crtc_id, self.handle, self.size, self.size, self.hot_x, self.hot_y) != 0 and
        c.drmModeSetCursor(fd, self.drm.crtc_id, self.handle, self.size, self.size) != 0)
    {
        const err = util.errno();
        // Losing DRM master races with the seat disable notification;
        // that's not the driver rejecting the cursor.
        if (err == c.EACCES or err == c.EPERM) return;
        log.info("driver rejected hardware cursor errno={}, cursor disabled", .{err});
        self.available = false;
        return;
    }
    _ = c.drmModeMoveCursor(fd, self.drm.crtc_id, self.x - self.hot_x, self.y - self.hot_y);
}

// Shapes: 'B' is the black outline, 'W' the white fill.
const arrow = [_][]const u8{
    "B",
    "BB",
    "BWB",
    "BWWB",
    "BWWWB",
    "BWWWWB",
    "BWWWWWB",
    "BWWWWWWB",
    "BWWWWWWWB",
    "BWWWWWWWWB",
    "BWWWWWWWWWB",
    "BWWWWWWBBBBB",
    "BWWWBWWB",
    "BWWBBWWB",
    "BWB  BWWB",
    "BB   BWWB",
    "B     BWWB",
    "      BWWB",
    "       BB",
};

const ibeam = [_][]const u8{
    "BBBBBBB",
    "BWWBWWB",
    "BBBWBBB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "  BWB",
    "BBBWBBB",
    "BWWBWWB",
    "BBBBBBB",
};

fn draw(self: *Cursor) void {
    const map = self.map orelse return;
    @memset(map, 0);
    const rows: []const []const u8 = switch (self.shape) {
        .arrow => &arrow,
        .ibeam => &ibeam,
    };
    switch (self.shape) {
        .arrow => {
            self.hot_x = 0;
            self.hot_y = 0;
        },
        .ibeam => {
            self.hot_x = @intCast(3 * self.scale);
            self.hot_y = @intCast(8 * self.scale);
        },
    }

    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            const px: u32 = switch (ch) {
                'B' => 0xff000000,
                'W' => 0xffffffff,
                else => continue,
            };
            for (0..self.scale) |sy| for (0..self.scale) |sx| {
                const x = rx * self.scale + sx;
                const y = ry * self.scale + sy;
                if (x >= self.size or y >= self.size) continue;
                const off = y * self.pitch + x * 4;
                std.mem.writeInt(u32, map[off..][0..4], px, .little);
            };
        }
    }
}
