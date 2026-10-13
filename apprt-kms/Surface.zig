//! The kms apprt Surface: the single fullscreen terminal. Wraps the core
//! surface and implements the functions the core calls on its apprt
//! surface. Size and scale come from the DRM output.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");

const log = std.log.scoped(.kms_surface);

app: *App,
core_surface: CoreSurface,

/// The title set by the terminal. There's nowhere to show it, but the
/// core reads it back (e.g. for copy_title_to_clipboard).
title: ?[:0]const u8 = null,

cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },

/// In-process clipboards. There is no system clipboard on the console,
/// so copy/paste works within this terminal only. The selection and
/// primary clipboards share one slot, like X11's PRIMARY.
clipboard_standard: ?[:0]u8 = null,
clipboard_selection: ?[:0]u8 = null,

/// Clipboard reads are completed from the main loop rather than inside
/// `clipboardRequest`, matching the asynchronous flow other apprts have
/// and keeping us out of the core's call stack (and its locks).
pending_reads: std.ArrayList(PendingRead) = .empty,

const PendingRead = struct {
    clipboard: apprt.Clipboard,
    request: apprt.ClipboardRequest,
};

pub fn init(self: *Surface, app: *App) !void {
    self.* = .{
        .app = app,
        .core_surface = undefined,
    };

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
    defer config.deinit();

    try self.core_surface.init(
        app.alloc,
        &config,
        app.core_app,
        app,
        self,
    );
}

pub fn deinit(self: *Surface) void {
    const alloc = self.app.alloc;

    // Deny anything still queued so requesters (e.g. OSC 52 reads)
    // aren't left waiting.
    for (self.pending_reads.items) |p| self.core_surface.denyClipboardRequest(p.request);
    self.pending_reads.deinit(alloc);

    if (self.title) |v| alloc.free(v);
    if (self.clipboard_standard) |v| alloc.free(v);
    if (self.clipboard_selection) |v| alloc.free(v);

    self.app.core_app.deleteSurface(self);
    self.core_surface.deinit();
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    // No confirmation UI on the console; closing just closes.
    _ = process_active;
    self.app.requestClose();
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.alloc;
    const copy = alloc.dupeZ(u8, title) catch return;
    if (self.title) |v| alloc.free(v);
    self.title = copy;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.app.content_scale, .y = self.app.content_scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.app.drm.width(), .height = self.app.drm.height() };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options {
    return .{ .display = self.app.render_display };
}

//-------------------------------------------------------------------
// Clipboard

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard, .selection, .primary => true,
    };
}

fn slot(self: *Surface, clipboard_type: apprt.Clipboard) *?[:0]u8 {
    return switch (clipboard_type) {
        .standard => &self.clipboard_standard,
        .selection, .primary => &self.clipboard_selection,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    switch (state) {
        // Writes carry their own contents; reads need something to read.
        .kitty_write, .list => {},
        else => if (self.slot(clipboard_type).* == null) return .unavailable,
    }

    try self.pending_reads.append(self.app.alloc, .{
        .clipboard = clipboard_type,
        .request = state,
    });
    self.app.wakeup();
    return .started;
}

/// Complete queued clipboard requests. Called from the main loop.
pub fn completePendingClipboard(self: *Surface) void {
    while (self.pending_reads.items.len > 0) {
        const p = self.pending_reads.orderedRemove(0);
        self.completeRead(p);
    }
}

fn completeRead(self: *Surface, p: PendingRead) void {
    const text = self.slot(p.clipboard).*;
    const contents: []const terminal.clipboard.Content = if (text) |t|
        &.{.{ .mime = "text/plain", .data = t }}
    else
        &.{};
    const available: []const []const u8 = if (text != null) &.{"text/plain"} else &.{};

    var complete: CoreSurface.CompleteClipboard = .{
        .contents = contents,
        .available = available,
    };

    self.core_surface.completeClipboardRequest(p.request, complete) catch |err| switch (err) {
        // Paste protection wants a confirmation we have no UI for. The
        // clipboard is in-process, so its contents were copied from this
        // terminal; paste them. Disable `clipboard-paste-protection` to
        // skip this step entirely.
        error.UnsafePaste => {
            log.info("pasting multi-line text without confirmation (no prompt UI on the console)", .{});
            complete.confirmed = true;
            self.core_surface.completeClipboardRequest(p.request, complete) catch |err2| {
                log.warn("error completing clipboard request err={}", .{err2});
            };
        },

        // A program asked to access the clipboard and the config says to
        // ask the user. We can't, so deny.
        error.UnauthorizedPaste => {
            log.info("denying clipboard access that requires confirmation", .{});
            self.core_surface.denyClipboardRequest(p.request);
        },

        else => log.warn("error completing clipboard request err={}", .{err}),
    };
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (confirm) {
        log.info("ignoring clipboard write that requires confirmation", .{});
        return;
    }

    // We only keep text.
    const text: [:0]const u8 = for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) break content.data;
    } else return;

    const alloc = self.app.alloc;
    const copy = try alloc.dupeZ(u8, text);
    const s = self.slot(clipboard_type);
    if (s.*) |old| alloc.free(old);
    s.* = copy;
}

//-------------------------------------------------------------------
// Callbacks into the core, called by App on input and seat events.

pub fn keyCallback(self: *Surface, ev: input.KeyEvent) void {
    _ = self.core_surface.keyCallback(ev) catch |err| {
        log.err("error in key callback err={}", .{err});
    };
}

pub fn cursorPosCallback(self: *Surface, x: f64, y: f64, mods: input.Mods) void {
    self.cursor_pos = .{ .x = @floatCast(x), .y = @floatCast(y) };
    self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
        log.err("error in cursor pos callback err={}", .{err});
    };
}

pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) void {
    _ = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
        log.err("error in mouse button callback err={}", .{err});
    };
}

pub fn scrollCallback(self: *Surface, dx: f64, dy: f64, mods: input.ScrollMods) void {
    self.core_surface.scrollCallback(dx, dy, mods) catch |err| {
        log.err("error in scroll callback err={}", .{err});
    };
}

pub fn focusCallback(self: *Surface, focused: bool) void {
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("error in focus callback err={}", .{err});
    };
}

pub fn occlusionCallback(self: *Surface, visible: bool) void {
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.err("error in occlusion callback err={}", .{err});
    };
}

pub fn refresh(self: *Surface) void {
    self.core_surface.refreshCallback() catch |err| {
        log.err("error in refresh callback err={}", .{err});
    };
}
