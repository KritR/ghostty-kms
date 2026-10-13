//! The kms apprt App: owns the seat, the DRM output, the presenter, input
//! and the single fullscreen surface, and runs the main loop.
//!
//! Main loop: every event source we have is a file descriptor (seat, DRM
//! page-flip events, libinput, the key-repeat timer and an eventfd that
//! other threads write to in `wakeup`), so the loop is a plain poll(2)
//! followed by a core tick. Everything here runs on the main thread; the
//! renderer and termio run on their own threads inside the core.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("kms_c");
const gl = @import("opengl");
const egl = gl.egl;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
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
/// like the Jetson where rendering and scanout are different devices.
render_display: *egl.Display,
render_node: ?RenderNode = null,

/// The one and only surface. Null once it has closed.
surface: ?*Surface = null,

/// eventfd written by `wakeup` (any thread) and the signal handler.
wake_fd: c_int,

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
    fd: c_int,
    gbm: *c.struct_gbm_device,
    display: *egl.Display,
};

/// Set by the signal handler; read by the main loop.
var signal_wake_fd: c_int = -1;
var signal_quit: std.atomic.Value(bool) = .init(false);

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;
    const alloc = core_app.alloc;

    // The wakeup fd must exist before anything can call `wakeup`.
    const wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake_fd < 0) return error.EventFdFailed;
    errdefer _ = c.close(wake_fd);

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
        .wake_fd = wake_fd,
        .content_scale = 1,
        .force_cpu = if (util.env("GHOSTTY_KMS_PRESENT")) |v| std.mem.eql(u8, v, "cpu") else false,
    };

    installSignalHandlers(wake_fd);

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
    while (self.running) {
        var fds = [_]c.struct_pollfd{
            .{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.seat.fd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.drm.fd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.input.fd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.input.repeat_fd, .events = c.POLLIN, .revents = 0 },
        };

        if (c.poll(&fds, fds.len, -1) < 0) {
            if (util.errno() == c.EINTR) continue;
            log.err("poll failed errno={}", .{util.errno()});
            return error.PollFailed;
        }

        if (fds[0].revents != 0) {
            var buf: u64 = 0;
            _ = c.read(self.wake_fd, &buf, @sizeOf(u64));
        }
        if (signal_quit.load(.acquire)) {
            log.info("quit signal received", .{});
            self.running = false;
            break;
        }

        if (fds[1].revents != 0) self.seat.dispatch() catch |err| {
            log.err("seat dispatch failed err={}", .{err});
            return err;
        };
        if (fds[2].revents != 0) self.presenter.dispatchDrmEvents();
        if (fds[3].revents != 0) self.input.dispatch();
        if (fds[4].revents != 0) self.input.handleRepeat();

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
    signal_wake_fd = -1;
    _ = c.close(self.wake_fd);
}

/// Called by the core (from any thread) to wake up the main loop.
pub fn wakeup(self: *App) void {
    const one: u64 = 1;
    _ = c.write(self.wake_fd, &one, @sizeOf(u64));
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
    c.gbm_device_destroy(rn.gbm);
    _ = c.close(rn.fd);
}

//-------------------------------------------------------------------
// Signals

fn installSignalHandlers(wake_fd: c_int) void {
    signal_wake_fd = wake_fd;
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
    const fd = signal_wake_fd;
    if (fd >= 0) {
        const one: u64 = 1;
        _ = c.write(fd, &one, @sizeOf(u64));
    }
}
