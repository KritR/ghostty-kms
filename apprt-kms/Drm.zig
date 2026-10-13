//! The DRM device and the output (connector + CRTC + mode) we scan out to.
//!
//! We use the legacy (non-atomic) KMS API: one modeset with
//! drmModeSetCrtc, then drmModePageFlip per frame. That's all a single
//! fullscreen terminal needs, and it works on every driver we target.
const Drm = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("kms_c");
const Seat = @import("Seat.zig");
const util = @import("util.zig");

const log = std.log.scoped(.kms_drm);

/// The DRM device, opened through the seat.
device: Seat.Device,

/// Device node path, for logging.
path: [:0]const u8,

/// The GBM device on top of the DRM fd.
gbm: *c.struct_gbm_device,

connector_id: u32,
crtc_id: u32,
mode: c.drmModeModeInfo,

/// Physical size of the connected display, 0 if unknown.
mm_width: u32,
mm_height: u32,

/// Human-readable connector name, e.g. "HDMI-A-1".
connector_name: [32]u8 = @splat(0),

/// The CRTC configuration before we took over, restored on exit so the
/// console comes back the way we found it.
saved_crtc: ?*c.drmModeCrtc,

pub const Options = struct {
    /// Explicit device path, e.g. /dev/dri/card1 (GHOSTTY_KMS_DEVICE).
    device: ?[:0]const u8 = null,
    /// Connector name, e.g. HDMI-A-1 (GHOSTTY_KMS_CONNECTOR).
    connector: ?[]const u8 = null,
    /// Mode, e.g. 1920x1080 or 1920x1080@60 (GHOSTTY_KMS_MODE).
    mode: ?[]const u8 = null,
};

pub fn init(self: *Drm, alloc: Allocator, seat: *Seat, opts: Options) !void {
    if (opts.device) |path| {
        try self.initDevice(alloc, seat, path, opts);
        return;
    }

    // Probe card0..card15 and take the first with a usable output.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/dev/dri/card{d}", .{i}) catch unreachable;
        if (c.access(path.ptr, c.F_OK) != 0) continue;
        self.initDevice(alloc, seat, path, opts) catch |err| {
            log.info("skipping {s}: {}", .{ path, err });
            continue;
        };
        return;
    }

    log.err("no DRM device with a connected display found; set " ++
        "GHOSTTY_KMS_DEVICE to pick one explicitly", .{});
    return error.NoDrmDevice;
}

fn initDevice(
    self: *Drm,
    alloc: Allocator,
    seat: *Seat,
    path: [:0]const u8,
    opts: Options,
) !void {
    const dev = try seat.openDevice(path.ptr);
    errdefer seat.closeDevice(dev);

    // Must support modesetting (not a render-only node).
    const res = c.drmModeGetResources(dev.fd) orelse return error.NotKmsDevice;
    defer c.drmModeFreeResources(res);

    const output = try pickOutput(dev.fd, res, opts);

    const gbm = c.gbm_create_device(dev.fd) orelse return error.GbmCreateFailed;
    errdefer c.gbm_device_destroy(gbm);

    self.* = .{
        .device = dev,
        .path = try alloc.dupeZ(u8, path),
        .gbm = gbm,
        .connector_id = output.connector_id,
        .crtc_id = output.crtc_id,
        .mode = output.mode,
        .mm_width = output.mm_width,
        .mm_height = output.mm_height,
        .saved_crtc = c.drmModeGetCrtc(dev.fd, output.crtc_id),
    };
    _ = std.fmt.bufPrint(&self.connector_name, "{s}", .{output.name()}) catch {};

    var drv_name: []const u8 = "?";
    const ver = c.drmGetVersion(dev.fd);
    defer if (ver) |v| c.drmFreeVersion(v);
    if (ver) |v| drv_name = v.*.name[0..@intCast(v.*.name_len)];

    log.info(
        "using device={s} driver={s} connector={s} mode={}x{}@{} size={}x{}mm",
        .{
            path,
            drv_name,
            self.connectorName(),
            self.mode.hdisplay,
            self.mode.vdisplay,
            self.mode.vrefresh,
            self.mm_width,
            self.mm_height,
        },
    );
}

pub fn deinit(self: *Drm, alloc: Allocator, seat: *Seat) void {
    // Only the DRM master can modeset.
    if (seat.active) self.restoreCrtc();
    if (self.saved_crtc) |crtc| c.drmModeFreeCrtc(crtc);
    c.gbm_device_destroy(self.gbm);
    seat.closeDevice(self.device);
    alloc.free(self.path);
}

pub fn fd(self: *const Drm) c_int {
    return self.device.fd;
}

pub fn width(self: *const Drm) u32 {
    return self.mode.hdisplay;
}

pub fn height(self: *const Drm) u32 {
    return self.mode.vdisplay;
}

pub fn connectorName(self: *const Drm) []const u8 {
    return std.mem.sliceTo(&self.connector_name, 0);
}

/// Put back the CRTC configuration that was active before we started.
/// Only possible while we're DRM master (i.e. the seat is active).
pub fn restoreCrtc(self: *Drm) void {
    const crtc = self.saved_crtc orelse return;
    if (crtc.buffer_id == 0) return;
    var conn = self.connector_id;
    _ = c.drmModeSetCrtc(
        self.fd(),
        crtc.crtc_id,
        crtc.buffer_id,
        crtc.x,
        crtc.y,
        &conn,
        1,
        &crtc.mode,
    );
}

/// Derive a content scale from the display's physical size: the ratio of
/// its DPI to 96 (the standard Linux DPI), rounded to a quarter step and
/// clamped to [1, 4]. Displays that report no physical size (projectors,
/// some VMs) get 1.0.
pub fn contentScale(self: *const Drm) f32 {
    if (self.mm_width == 0 or self.mm_height == 0) return 1.0;
    const w_in: f32 = @as(f32, @floatFromInt(self.mm_width)) / 25.4;
    const dpi: f32 = @as(f32, @floatFromInt(self.width())) / w_in;
    return scaleFromDpi(dpi);
}

pub fn scaleFromDpi(dpi: f32) f32 {
    if (!std.math.isFinite(dpi) or dpi <= 0) return 1.0;
    const raw = dpi / 96.0;
    const stepped = @round(raw * 4.0) / 4.0;
    return std.math.clamp(stepped, 1.0, 4.0);
}

test scaleFromDpi {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 1.0), scaleFromDpi(96));
    try testing.expectEqual(@as(f32, 1.0), scaleFromDpi(80));
    try testing.expectEqual(@as(f32, 2.0), scaleFromDpi(192));
    // A 27" 4K panel is ~163 DPI.
    try testing.expectEqual(@as(f32, 1.75), scaleFromDpi(163));
    try testing.expectEqual(@as(f32, 4.0), scaleFromDpi(1000));
    try testing.expectEqual(@as(f32, 1.0), scaleFromDpi(0));
}

const Output = struct {
    connector_id: u32,
    crtc_id: u32,
    mode: c.drmModeModeInfo,
    mm_width: u32,
    mm_height: u32,
    name_buf: [32]u8,

    fn name(self: *const Output) []const u8 {
        return std.mem.sliceTo(&self.name_buf, 0);
    }
};

fn connectorTypeName(t: u32) []const u8 {
    return switch (t) {
        c.DRM_MODE_CONNECTOR_VGA => "VGA",
        c.DRM_MODE_CONNECTOR_DVII => "DVI-I",
        c.DRM_MODE_CONNECTOR_DVID => "DVI-D",
        c.DRM_MODE_CONNECTOR_DVIA => "DVI-A",
        c.DRM_MODE_CONNECTOR_Composite => "Composite",
        c.DRM_MODE_CONNECTOR_SVIDEO => "SVIDEO",
        c.DRM_MODE_CONNECTOR_LVDS => "LVDS",
        c.DRM_MODE_CONNECTOR_Component => "Component",
        c.DRM_MODE_CONNECTOR_9PinDIN => "DIN",
        c.DRM_MODE_CONNECTOR_DisplayPort => "DP",
        c.DRM_MODE_CONNECTOR_HDMIA => "HDMI-A",
        c.DRM_MODE_CONNECTOR_HDMIB => "HDMI-B",
        c.DRM_MODE_CONNECTOR_TV => "TV",
        c.DRM_MODE_CONNECTOR_eDP => "eDP",
        c.DRM_MODE_CONNECTOR_VIRTUAL => "Virtual",
        c.DRM_MODE_CONNECTOR_DSI => "DSI",
        c.DRM_MODE_CONNECTOR_DPI => "DPI",
        c.DRM_MODE_CONNECTOR_WRITEBACK => "Writeback",
        c.DRM_MODE_CONNECTOR_SPI => "SPI",
        c.DRM_MODE_CONNECTOR_USB => "USB",
        else => "Unknown",
    };
}

fn pickOutput(drm_fd: c_int, res: *c.drmModeRes, opts: Options) !Output {
    const connectors = res.connectors[0..@intCast(res.count_connectors)];
    for (connectors) |conn_id| {
        const conn = c.drmModeGetConnector(drm_fd, conn_id) orelse continue;
        defer c.drmModeFreeConnector(conn);

        var name_buf: [32]u8 = @splat(0);
        _ = std.fmt.bufPrint(&name_buf, "{s}-{d}", .{
            connectorTypeName(conn.*.connector_type),
            conn.*.connector_type_id,
        }) catch {};
        const name = std.mem.sliceTo(&name_buf, 0);

        if (opts.connector) |want| {
            if (!std.mem.eql(u8, want, name)) continue;
        }

        if (conn.*.connection != c.DRM_MODE_CONNECTED or conn.*.count_modes == 0) {
            log.debug("connector {s} not connected", .{name});
            continue;
        }

        const mode = pickMode(conn, opts.mode) orelse {
            log.warn("connector {s} has no mode matching {s}", .{ name, opts.mode.? });
            continue;
        };

        const crtc_id = pickCrtc(drm_fd, res, conn) orelse {
            log.warn("connector {s} has no usable CRTC", .{name});
            continue;
        };

        return .{
            .connector_id = conn_id,
            .crtc_id = crtc_id,
            .mode = mode,
            .mm_width = conn.*.mmWidth,
            .mm_height = conn.*.mmHeight,
            .name_buf = name_buf,
        };
    }

    return error.NoConnectedOutput;
}

fn pickMode(conn: *c.drmModeConnector, want: ?[]const u8) ?c.drmModeModeInfo {
    const modes = conn.modes[0..@intCast(conn.count_modes)];

    if (want) |spec| {
        const parsed = parseModeSpec(spec) orelse {
            log.warn("invalid GHOSTTY_KMS_MODE={s}, expected WxH or WxH@R", .{spec});
            return null;
        };
        var best: ?c.drmModeModeInfo = null;
        for (modes) |m| {
            if (m.hdisplay != parsed.w or m.vdisplay != parsed.h) continue;
            if (parsed.r) |r| if (m.vrefresh != r) continue;
            // Prefer the preferred mode, then the highest refresh.
            if (best == null or
                (m.type & c.DRM_MODE_TYPE_PREFERRED) != 0 or
                m.vrefresh > best.?.vrefresh) best = m;
        }
        return best;
    }

    for (modes) |m| {
        if ((m.type & c.DRM_MODE_TYPE_PREFERRED) != 0) return m;
    }
    return modes[0];
}

const ModeSpec = struct { w: u32, h: u32, r: ?u32 };

fn parseModeSpec(spec: []const u8) ?ModeSpec {
    const x = std.mem.indexOfScalar(u8, spec, 'x') orelse return null;
    const at = std.mem.indexOfScalar(u8, spec, '@');
    const w = std.fmt.parseInt(u32, spec[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, spec[x + 1 .. at orelse spec.len], 10) catch return null;
    const r: ?u32 = if (at) |i| std.fmt.parseInt(u32, spec[i + 1 ..], 10) catch return null else null;
    return .{ .w = w, .h = h, .r = r };
}

test parseModeSpec {
    const testing = std.testing;
    try testing.expectEqual(ModeSpec{ .w = 1920, .h = 1080, .r = null }, parseModeSpec("1920x1080").?);
    try testing.expectEqual(ModeSpec{ .w = 800, .h = 600, .r = 60 }, parseModeSpec("800x600@60").?);
    try testing.expect(parseModeSpec("garbage") == null);
}

fn pickCrtc(drm_fd: c_int, res: *c.drmModeRes, conn: *c.drmModeConnector) ?u32 {
    // Prefer the CRTC already driving this connector (fbcon's), which
    // avoids a needless reconfiguration.
    if (conn.encoder_id != 0) {
        if (c.drmModeGetEncoder(drm_fd, conn.encoder_id)) |enc| {
            defer c.drmModeFreeEncoder(enc);
            if (enc.*.crtc_id != 0) return enc.*.crtc_id;
        }
    }

    const crtcs = res.crtcs[0..@intCast(res.count_crtcs)];
    const encoders = conn.encoders[0..@intCast(conn.count_encoders)];
    for (encoders) |enc_id| {
        const enc = c.drmModeGetEncoder(drm_fd, enc_id) orelse continue;
        defer c.drmModeFreeEncoder(enc);
        for (crtcs, 0..) |crtc_id, i| {
            if ((enc.*.possible_crtcs & (@as(u32, 1) << @intCast(i))) != 0) return crtc_id;
        }
    }
    return null;
}
