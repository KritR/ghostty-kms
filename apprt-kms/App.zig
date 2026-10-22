//! The kms apprt App: owns the seat, the DRM output, the presenter, input
//! and the single fullscreen surface, and runs the main loop.
//!
//! Main loop: libxev (the same loop Ghostty's renderer and termio threads
//! use) watches the seat fd, the DRM fd (page-flip events), the libinput
//! fd and the key-repeat timerfd, plus an `xev.Async` that `wakeup`
//! notifies from other threads. After each loop iteration we tick the
//! core. Everything here runs on the main thread; the renderer and termio
//! run on their own threads inside the core.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("kms_c");
const gl = @import("opengl");
const egl = gl.egl;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const xev = global.xev;
const Config = configpkg.Config;
const inputpkg = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const Seat = @import("Seat.zig");
const Drm = @import("Drm.zig");
const Presenter = @import("Presenter.zig");
const Input = @import("Input.zig");
const Cursor = @import("Cursor.zig");
const Surface = @import("Surface.zig");
const util = @import("util.zig");

const log = std.log.scoped(.kms);

alloc: Allocator,
core_app: *CoreApp,
config: Config,

seat: Seat,
drm: Drm,
presenter: Presenter,
input: Input,
cursor: Cursor,

/// The EGL display the renderer uses. Normally the presenter's (same
/// GPU). With GHOSTTY_KMS_RENDER_DEVICE it's a separate GPU, for boards
/// like the Jetson where rendering and scanout are different devices, or
/// (`software`) Mesa's llvmpipe, for GPUs without desktop GL 4.3 such as
/// the Raspberry Pi's V3D, which still does the presenter's blit.
render_display: *egl.Display,
render_node: ?RenderNode = null,

/// The one and only surface. Null once it has closed.
surface: ?*Surface = null,

loop: xev.Loop,

/// Notified by `wakeup` (any thread) and the signal handler.
wakeup_h: xev.Async,
wakeup_c: xev.Completion = .{},

/// Readiness watches for our file descriptors.
seat_c: xev.Completion = .{},
drm_c: xev.Completion = .{},
input_c: xev.Completion = .{},
repeat_c: xev.Completion = .{},

running: bool = true,

/// The surface asked to close (from inside a core callback); handled at
/// the end of the current loop iteration.
close_requested: bool = false,

/// The renderer produced a frame we haven't presented yet.
present_requested: bool = false,

/// Redraw the last frame even without a new one (after a VT switch).
force_redraw: bool = false,

/// Present via CPU copies only (GHOSTTY_KMS_PRESENT=cpu).
force_cpu: bool = false,

content_scale: f32,

const RenderNode = struct {
    /// Unset for the software device, which has no DRM node.
    fd: c_int = -1,
    gbm: ?*c.struct_gbm_device = null,
    display: *egl.Display,
};

/// Set by the signal handler; read by the main loop.
var signal_wakeup: ?*xev.Async = null;
var signal_quit: std.atomic.Value(bool) = .init(false);

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;
    const alloc = core_app.alloc;

    // The wakeup handle must exist before anything can call `wakeup`.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    var config = Config.load(alloc) catch |err| err: {
        log.err("error loading config, using defaults err={}", .{err});
        break :err try Config.default(alloc);
    };
    errdefer config.deinit();
    logConfigDiagnostics(&config);

    self.* = .{
        .alloc = alloc,
        .core_app = core_app,
        .config = config,
        .seat = undefined,
        .drm = undefined,
        .presenter = undefined,
        .input = undefined,
        .cursor = undefined,
        .render_display = undefined,
        .loop = loop,
        .wakeup_h = wakeup_h,
        .content_scale = 1,
        .force_cpu = if (util.env("GHOSTTY_KMS_PRESENT")) |v| std.mem.eql(u8, v, "cpu") else false,
    };

    installSignalHandlers(&self.wakeup_h);
    errdefer signal_wakeup = null;

    try self.seat.init();
    errdefer self.seat.deinit();

    try self.drm.init(alloc, &self.seat, .{
        .device = util.env("GHOSTTY_KMS_DEVICE"),
        .connector = util.env("GHOSTTY_KMS_CONNECTOR"),
        .mode = util.env("GHOSTTY_KMS_MODE"),
    });
    errdefer self.drm.deinit(alloc, &self.seat);

    self.content_scale = util.envFloat("GHOSTTY_KMS_SCALE") orelse self.drm.contentScale();
    if (!(self.content_scale > 0)) self.content_scale = 1;
    log.info("content scale={d}", .{self.content_scale});

    try self.presenter.init(alloc, &self.drm);
    errdefer {
        self.presenter.deinit();
        self.presenter.eglDisplay().terminate();
    }

    self.render_display = self.presenter.eglDisplay();
    if (util.env("GHOSTTY_KMS_RENDER_DEVICE")) |path| {
        self.render_node = try openRenderNode(path);
        self.render_display = self.render_node.?.display;
    }
    errdefer if (self.render_node) |rn| closeRenderNode(rn);

    // Refuse to run on a software rasterizer unless asked to. llvmpipe at
    // high resolutions keeps every core busy, which is a lot of power and
    // heat for small boards, and it's never what you want by accident.
    try checkNotSoftware("presenter", self.presenter.eglDisplay());
    if (self.render_node != null) try checkNotSoftware("renderer", self.render_display);

    try self.input.init(alloc, self, &self.seat, self.drm.width(), self.drm.height());
    errdefer self.input.deinit();

    self.cursor.init(&self.drm, self.content_scale);
    errdefer self.cursor.deinit();

    // From here on we react to VT switches.
    self.seat.handler = .{
        .ctx = self,
        .enable = seatEnabled,
        .disable = seatDisabled,
    };

    // Create our single fullscreen surface.
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self);
    self.surface = surface;

    if (self.force_cpu) surface.core().reportPresentationHealth(.unhealthy);

    self.core_app.focusEvent(true);
    surface.focusCallback(true);
}

pub fn run(self: *App) !void {
    self.wakeup_h.wait(&self.loop, &self.wakeup_c, App, self, onWakeup);
    watch(&self.loop, &self.seat_c, self.seat.fd(), self, onSeatReadable);
    watch(&self.loop, &self.drm_c, self.drm.fd(), self, onDrmReadable);
    watch(&self.loop, &self.input_c, self.input.fd(), self, onInputReadable);
    watch(&self.loop, &self.repeat_c, self.input.repeat_fd, self, onRepeatReadable);

    while (self.running) {
        // Block until at least one source fires, handle all ready ones.
        try self.loop.run(.once);

        if (signal_quit.load(.acquire)) {
            log.info("quit signal received", .{});
            self.running = false;
            break;
        }

        // Process the core's mailbox. This is where surface messages such
        // as "a frame is ready" turn into performAction calls.
        try self.core_app.tick(self);

        if (self.surface) |s| s.completePendingClipboard();

        if (self.close_requested) {
            self.close_requested = false;
            self.closeSurface();
        }

        self.maybePresent();
    }
}

const FdCallback = *const fn (self: *App) void;

/// Watch `fd` for readability, calling `cb` each time it's readable.
fn watch(
    loop: *xev.Loop,
    completion: *xev.Completion,
    fd: c_int,
    self: *App,
    comptime cb: FdCallback,
) void {
    xev.File.initFd(fd).poll(loop, completion, .read, App, self, (struct {
        fn callback(
            ud: ?*App,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.File,
            r: xev.PollError!xev.PollEvent,
        ) xev.CallbackAction {
            _ = r catch |err| {
                log.err("error polling fd err={}", .{err});
                return .disarm;
            };
            cb(ud.?);
            return .rearm;
        }
    }).callback);
}

fn onWakeup(
    _: ?*App,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| log.err("error in wakeup err={}", .{err});
    // Nothing else to do: the core tick runs after every loop iteration.
    return .rearm;
}

fn onSeatReadable(self: *App) void {
    self.seat.dispatch() catch |err| {
        log.err("seat dispatch failed err={}; exiting", .{err});
        self.running = false;
    };
}

fn onDrmReadable(self: *App) void {
    self.presenter.dispatchDrmEvents();
}

fn onInputReadable(self: *App) void {
    self.input.dispatch();
}

fn onRepeatReadable(self: *App) void {
    self.input.handleRepeat();
}

pub fn terminate(self: *App) void {
    self.closeSurface();
    self.seat.handler = null;
    self.cursor.deinit();
    self.input.deinit();
    if (self.render_node) |rn| closeRenderNode(rn);
    self.presenter.deinit();
    self.presenter.eglDisplay().terminate();
    self.drm.deinit(self.alloc, &self.seat);
    self.seat.deinit();
    self.config.deinit();
    signal_wakeup = null;
    self.wakeup_h.deinit();
    self.loop.deinit();
}

/// Called by the core (from any thread) to wake up the main loop.
pub fn wakeup(self: *App) void {
    self.wakeup_h.notify() catch |err| log.warn("error waking up main loop err={}", .{err});
}

pub fn keyboardLayout(self: *const App) inputpkg.KeyboardLayout {
    _ = self;
    // Only used for macOS option-as-alt detection.
    return .unknown;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => self.running = false,

        // Single surface: closing the window/tab closes the terminal.
        .close_window, .close_tab, .close_all_windows => self.requestClose(),

        .render => self.present_requested = true,

        .set_title => switch (target) {
            .app => {},
            .surface => |core| core.rt_surface.setTitle(value.title),
        },

        .mouse_shape => self.cursor.setShape(switch (value) {
            .text, .vertical_text => .ibeam,
            else => .arrow,
        }),

        .mouse_visibility => self.cursor.setHidden(value == .hidden),

        .config_change => switch (target) {
            .surface => {},
            .app => {
                // Keep our copy current for anything that reads it later.
                const clone = try value.config.clone(self.alloc);
                self.config.deinit();
                self.config = clone;
            },
        },

        .reload_config => try self.reloadConfig(target, value),

        .renderer_health => log.info("renderer health={}", .{value}),

        .ring_bell => log.debug("bell", .{}),

        // Nothing to do: with one surface we exit when it closes.
        .quit_timer => {},

        else => return false,
    }

    return true;
}

/// Send the given IPC to a running Ghostty. There is no IPC channel for
/// the kms runtime (one terminal per VT), so this always fails.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return false;
}

fn reloadConfig(
    self: *App,
    target: apprt.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    // Soft reloads re-apply conditional state to the current config.
    if (opts.soft) {
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core| try core.updateConfig(&self.config),
        }
        return;
    }

    var config = try Config.load(self.alloc);
    defer config.deinit();
    logConfigDiagnostics(&config);
    switch (target) {
        // This triggers a config_change action, which updates self.config.
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core| try core.updateConfig(&config),
    }
}

fn logConfigDiagnostics(config: *const Config) void {
    for (config._diagnostics.items()) |diag| {
        log.warn("config: {f}", .{diag});
    }
}

//-------------------------------------------------------------------
// Surface lifecycle

pub fn requestClose(self: *App) void {
    self.close_requested = true;
    self.wakeup();
}

fn closeSurface(self: *App) void {
    const surface = self.surface orelse return;
    self.surface = null;
    surface.deinit();
    self.alloc.destroy(surface);
    // One surface: when it's gone, we're done.
    self.running = false;
}

//-------------------------------------------------------------------
// Presentation

fn maybePresent(self: *App) void {
    if (!self.present_requested and !self.force_redraw) return;
    if (!self.seat.active or !self.presenter.canPresent()) return;
    const surface = self.surface orelse return;

    const frame = surface.core().renderer.takeFrame();
    if (frame == null and !self.force_redraw) {
        self.present_requested = false;
        return;
    }

    self.present_requested = false;
    const was_modeset = self.presenter.needs_modeset;
    self.presenter.present(frame) catch |err| switch (err) {
        error.DmabufImportFailed => {
            log.warn("DMABUF import failed, asking renderer for CPU frames", .{});
            surface.core().reportPresentationHealth(.unhealthy);
        },
        error.PresentFailed => {},
    };
    if (frame != null or self.presenter.source != .none) self.force_redraw = false;
    // A failed modeset (e.g. racing a VT switch) is retried at the next
    // wakeup rather than leaving a stale screen.
    if (self.presenter.needs_modeset and self.presenter.source != .none) self.force_redraw = true;

    // A modeset resets the cursor plane.
    if (was_modeset and !self.presenter.needs_modeset) self.cursor.apply();
}

//-------------------------------------------------------------------
// VT switching

fn seatEnabled(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.input.resume_();
    self.presenter.resume_();
    // Re-applied in maybePresent once the modeset is done.
    self.cursor.setActive(true);
    self.force_redraw = true;
    if (self.surface) |s| {
        s.occlusionCallback(true);
        s.refresh();
    }
}

fn seatDisabled(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.input.suspend_();
    self.presenter.suspend_();
    self.cursor.setActive(false);
    // Lets the renderer stop drawing while we're not on screen.
    if (self.surface) |s| s.occlusionCallback(false);
}

//-------------------------------------------------------------------
// Input, called by Input

pub fn keyEvent(self: *App, ev: inputpkg.KeyEvent) void {
    const surface = self.surface orelse return;
    surface.keyCallback(ev);
}

pub fn pointerMotion(self: *App, x: f64, y: f64, mods: inputpkg.Mods) void {
    self.cursor.move(x, y);
    const surface = self.surface orelse return;
    surface.cursorPosCallback(x, y, mods);
}

pub fn mouseButton(
    self: *App,
    action: inputpkg.MouseButtonState,
    button: inputpkg.MouseButton,
    mods: inputpkg.Mods,
) void {
    const surface = self.surface orelse return;
    surface.mouseButtonCallback(action, button, mods);
}

pub fn scroll(self: *App, dx: f64, dy: f64, mods: inputpkg.ScrollMods) void {
    const surface = self.surface orelse return;
    surface.scrollCallback(dx, dy, mods);
}

//-------------------------------------------------------------------
// Separate render GPU

fn openRenderNode(path: [:0]const u8) !RenderNode {
    if (std.mem.eql(u8, path, "software")) {
        // Asking for the software device is asking for software rendering.
        if (!util.envBool("GHOSTTY_KMS_ALLOW_SOFTWARE")) {
            log.err("GHOSTTY_KMS_RENDER_DEVICE=software needs GHOSTTY_KMS_ALLOW_SOFTWARE=1", .{});
            return error.SoftwareRenderingRefused;
        }
        return openSoftwareDevice();
    }

    // Render nodes don't need DRM master, so no seat involvement.
    const fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC);
    if (fd < 0) {
        log.err("failed to open render device {s} errno={}", .{ path, util.errno() });
        return error.RenderDeviceOpenFailed;
    }
    errdefer _ = c.close(fd);
    const gbm = c.gbm_create_device(fd) orelse return error.GbmCreateFailed;
    errdefer c.gbm_device_destroy(gbm);
    const display = try egl.Display.initPlatform(0x31D7, @ptrCast(gbm), null);
    log.info("rendering on {s}", .{path});
    return .{ .fd = fd, .gbm = gbm, .display = display };
}

fn closeRenderNode(rn: RenderNode) void {
    rn.display.terminate();
    if (rn.gbm) |gbm| c.gbm_device_destroy(gbm);
    if (rn.fd >= 0) _ = c.close(rn.fd);
}

/// The Mesa driver behind an EGL display (EGL_MESA_query_driver), e.g.
/// "v3d", "zink", "iris", or "swrast"/"kms_swrast" for software.
fn eglDriverName(display: *egl.Display) ?[:0]const u8 {
    const GetDriverName = *const fn (egl.c.EGLDisplay) callconv(.c) ?[*:0]const u8;
    const f: GetDriverName = @ptrCast(egl.c.eglGetProcAddress("eglGetDisplayDriverName") orelse return null);
    return std.mem.span(f(display) orelse return null);
}

fn checkNotSoftware(what: []const u8, display: *egl.Display) !void {
    const name = eglDriverName(display) orelse {
        log.info("{s} EGL driver unknown (no EGL_MESA_query_driver)", .{what});
        return;
    };
    log.info("{s} EGL driver={s}", .{ what, name });
    const software = std.mem.eql(u8, name, "swrast") or std.mem.eql(u8, name, "kms_swrast");
    if (!software) return;
    if (util.envBool("GHOSTTY_KMS_ALLOW_SOFTWARE")) {
        log.warn("{s} is using software rendering ({s}); allowed by GHOSTTY_KMS_ALLOW_SOFTWARE", .{ what, name });
        return;
    }
    log.err("{s} would use software rendering ({s}); refusing. Set " ++
        "GHOSTTY_KMS_ALLOW_SOFTWARE=1 to allow it.", .{ what, name });
    return error.SoftwareRenderingRefused;
}

/// Mesa's software EGL device (llvmpipe), found through
/// EGL_EXT_device_enumeration. Chosen explicitly rather than through
/// LIBGL_ALWAYS_SOFTWARE, which would also affect the presenter's display
/// (and which Mesa's GBM platform doesn't honour anyway).
fn openSoftwareDevice() !RenderNode {
    const EGL_EXTENSIONS = 0x3055;
    const EGL_PLATFORM_DEVICE_EXT = 0x313F;
    const QueryDevices = *const fn (egl.c.EGLint, [*]?*anyopaque, *egl.c.EGLint) callconv(.c) egl.c.EGLBoolean;
    const QueryDeviceString = *const fn (?*anyopaque, egl.c.EGLint) callconv(.c) ?[*:0]const u8;

    const query_devices: QueryDevices = @ptrCast(egl.c.eglGetProcAddress("eglQueryDevicesEXT") orelse {
        log.err("EGL_EXT_device_enumeration not available; can't find a software renderer", .{});
        return error.NoSoftwareDevice;
    });
    const query_string: QueryDeviceString = @ptrCast(egl.c.eglGetProcAddress("eglQueryDeviceStringEXT") orelse
        return error.NoSoftwareDevice);

    var devices: [16]?*anyopaque = @splat(null);
    var n: egl.c.EGLint = 0;
    if (query_devices(devices.len, &devices, &n) != egl.c.EGL_TRUE) return error.NoSoftwareDevice;
    for (devices[0..@intCast(n)]) |dev| {
        const exts = std.mem.span(query_string(dev, EGL_EXTENSIONS) orelse continue);
        if (!egl.hasExtension(exts, "EGL_MESA_device_software")) continue;
        const display = try egl.Display.initPlatform(EGL_PLATFORM_DEVICE_EXT, @ptrCast(dev), null);
        log.info("rendering on the software EGL device (llvmpipe)", .{});
        return .{ .display = display };
    }
    log.err("no software EGL device found (is Mesa's llvmpipe installed?)", .{});
    return error.NoSoftwareDevice;
}

//-------------------------------------------------------------------
// Signals

fn installSignalHandlers(wakeup_h: *xev.Async) void {
    signal_wakeup = wakeup_h;
    // A handler rather than a blocked mask + signalfd: Ghostty resets
    // handlers but not the mask before exec'ing the shell, so a blocked
    // mask would leak into every child.
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.HUP, &sa, null);
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    signal_quit.store(true, .release);
    // Async.notify is a single write(2) to an eventfd: signal safe.
    if (signal_wakeup) |h| h.notify() catch {};
}
