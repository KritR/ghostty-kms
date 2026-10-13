//! Input devices via libinput (opened through the seat), translated into
//! calls on the App/Surface. Owns the keyboard state and key repeat, which
//! libinput leaves to the client.
const Input = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("kms_c");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Seat = @import("Seat.zig");
const Keyboard = @import("Keyboard.zig");
const util = @import("util.zig");

const log = std.log.scoped(.kms_input);

alloc: Allocator,
app: *App,
seat: *Seat,

udev: *c.struct_udev,
li: *c.struct_libinput,

/// Devices opened through the seat on libinput's behalf, so we can close
/// them by fd.
devices: std.ArrayList(Seat.Device) = .empty,

/// Keyboards, for keeping their LEDs in sync with lock state.
keyboards: std.ArrayList(*c.struct_libinput_device) = .empty,

keyboard: Keyboard,

/// Key repeat via a timerfd. libinput doesn't generate repeats.
repeat_fd: c_int,
repeat_key: ?u32 = null,
repeat_delay_ms: u32,
repeat_rate_hz: u32,

/// Pointer position in surface pixels and the area it is clamped to.
pointer_x: f64 = 0,
pointer_y: f64 = 0,
bounds_w: f64,
bounds_h: f64,

const interface: c.struct_libinput_interface = .{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

pub fn init(self: *Input, alloc: Allocator, app: *App, seat: *Seat, width: u32, height: u32) !void {
    const udev = c.udev_new() orelse return error.UdevFailed;
    errdefer _ = c.udev_unref(udev);

    const repeat_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_NONBLOCK | c.TFD_CLOEXEC);
    if (repeat_fd < 0) return error.TimerFdFailed;
    errdefer _ = c.close(repeat_fd);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .seat = seat,
        .udev = udev,
        .li = undefined,
        .keyboard = undefined,
        .repeat_fd = repeat_fd,
        .repeat_delay_ms = util.envInt(u32, "GHOSTTY_KMS_REPEAT_DELAY") orelse 400,
        .repeat_rate_hz = util.envInt(u32, "GHOSTTY_KMS_REPEAT_RATE") orelse 25,
        .bounds_w = @floatFromInt(width),
        .bounds_h = @floatFromInt(height),
        .pointer_x = @as(f64, @floatFromInt(width)) / 2,
        .pointer_y = @as(f64, @floatFromInt(height)) / 2,
    };

    try self.keyboard.init();
    errdefer self.keyboard.deinit();

    self.li = c.libinput_udev_create_context(&interface, self, udev) orelse
        return error.LibinputFailed;
    errdefer _ = c.libinput_unref(self.li);

    if (c.libinput_udev_assign_seat(self.li, seat.name().ptr) != 0) {
        log.err("libinput failed to assign seat={s}", .{seat.name()});
        return error.LibinputSeatFailed;
    }

    // Handle the initial device-added events.
    self.dispatch();
}

pub fn deinit(self: *Input) void {
    for (self.keyboards.items) |dev| _ = c.libinput_device_unref(dev);
    self.keyboards.deinit(self.alloc);
    _ = c.libinput_unref(self.li);
    // libinput closed its devices through closeRestricted above.
    self.devices.deinit(self.alloc);
    _ = c.udev_unref(self.udev);
    self.keyboard.deinit();
    _ = c.close(self.repeat_fd);
}

pub fn fd(self: *const Input) c_int {
    return c.libinput_get_fd(self.li);
}

pub fn setBounds(self: *Input, width: u32, height: u32) void {
    self.bounds_w = @floatFromInt(width);
    self.bounds_h = @floatFromInt(height);
}

/// Stop delivering input while we don't own the seat.
pub fn suspend_(self: *Input) void {
    self.stopRepeat();
    c.libinput_suspend(self.li);
}

pub fn resume_(self: *Input) void {
    if (c.libinput_resume(self.li) != 0) log.warn("libinput_resume failed", .{});
    self.dispatch();
}

fn openRestricted(path: [*c]const u8, flags: c_int, userdata: ?*anyopaque) callconv(.c) c_int {
    _ = flags;
    const self: *Input = @ptrCast(@alignCast(userdata orelse return -c.EINVAL));
    const dev = self.seat.openDevice(path) catch return -c.EACCES;
    self.devices.append(self.alloc, dev) catch {
        self.seat.closeDevice(dev);
        return -c.ENOMEM;
    };
    return dev.fd;
}

fn closeRestricted(dev_fd: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Input = @ptrCast(@alignCast(userdata orelse return));
    for (self.devices.items, 0..) |dev, i| {
        if (dev.fd == dev_fd) {
            self.seat.closeDevice(dev);
            _ = self.devices.swapRemove(i);
            return;
        }
    }
    _ = c.close(dev_fd);
}

/// Read and handle all pending libinput events.
pub fn dispatch(self: *Input) void {
    if (c.libinput_dispatch(self.li) != 0) {
        log.warn("libinput_dispatch failed errno={}", .{util.errno()});
    }
    while (c.libinput_get_event(self.li)) |ev| {
        defer c.libinput_event_destroy(ev);
        self.handleEvent(ev);
    }
}

fn handleEvent(self: *Input, ev: *c.struct_libinput_event) void {
    switch (c.libinput_event_get_type(ev)) {
        c.LIBINPUT_EVENT_DEVICE_ADDED => self.deviceAdded(c.libinput_event_get_device(ev).?),
        c.LIBINPUT_EVENT_DEVICE_REMOVED => self.deviceRemoved(c.libinput_event_get_device(ev).?),

        c.LIBINPUT_EVENT_KEYBOARD_KEY => {
            const kev = c.libinput_event_get_keyboard_event(ev);
            const code = c.libinput_event_keyboard_get_key(kev);
            const pressed = c.libinput_event_keyboard_get_key_state(kev) == c.LIBINPUT_KEY_STATE_PRESSED;
            // With several keyboards, only the first press and the last
            // release of a key count.
            const count = c.libinput_event_keyboard_get_seat_key_count(kev);
            if ((pressed and count != 1) or (!pressed and count != 0)) return;
            self.handleKey(code, if (pressed) .press else .release);
        },

        c.LIBINPUT_EVENT_POINTER_MOTION => {
            const pev = c.libinput_event_get_pointer_event(ev);
            self.movePointer(
                self.pointer_x + c.libinput_event_pointer_get_dx(pev),
                self.pointer_y + c.libinput_event_pointer_get_dy(pev),
            );
        },

        c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => {
            const pev = c.libinput_event_get_pointer_event(ev);
            self.movePointer(
                c.libinput_event_pointer_get_absolute_x_transformed(pev, @intFromFloat(self.bounds_w)),
                c.libinput_event_pointer_get_absolute_y_transformed(pev, @intFromFloat(self.bounds_h)),
            );
        },

        c.LIBINPUT_EVENT_POINTER_BUTTON => {
            const pev = c.libinput_event_get_pointer_event(ev);
            const pressed = c.libinput_event_pointer_get_button_state(pev) == c.LIBINPUT_BUTTON_STATE_PRESSED;
            const button: input.MouseButton = switch (c.libinput_event_pointer_get_button(pev)) {
                c.BTN_LEFT => .left,
                c.BTN_RIGHT => .right,
                c.BTN_MIDDLE => .middle,
                c.BTN_SIDE => .four,
                c.BTN_EXTRA => .five,
                c.BTN_FORWARD => .six,
                c.BTN_BACK => .seven,
                c.BTN_TASK => .eight,
                else => .unknown,
            };
            self.app.mouseButton(if (pressed) .press else .release, button, self.mods());
        },

        c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL => {
            // Wheel clicks, in 1/120ths of a notch.
            const pev = c.libinput_event_get_pointer_event(ev);
            const dx = axisValue(pev, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, true) / 120.0;
            const dy = axisValue(pev, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, true) / 120.0;
            // Positive libinput values scroll down/right; Ghostty's
            // positive y scrolls up (same inversion as the GTK apprt).
            self.app.scroll(-dx, -dy, .{});
        },

        c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER,
        c.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS,
        => {
            // Touchpads etc.: smooth scrolling in pointer-motion units.
            const pev = c.libinput_event_get_pointer_event(ev);
            const dx = axisValue(pev, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, false);
            const dy = axisValue(pev, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, false);
            self.app.scroll(-dx, -dy, .{ .precision = true });
        },

        else => {},
    }
}

fn axisValue(pev: ?*c.struct_libinput_event_pointer, axis: c.enum_libinput_pointer_axis, v120: bool) f64 {
    if (c.libinput_event_pointer_has_axis(pev, axis) == 0) return 0;
    return if (v120)
        c.libinput_event_pointer_get_scroll_value_v120(pev, axis)
    else
        c.libinput_event_pointer_get_scroll_value(pev, axis);
}

fn movePointer(self: *Input, x: f64, y: f64) void {
    self.pointer_x = std.math.clamp(x, 0, @max(0, self.bounds_w - 1));
    self.pointer_y = std.math.clamp(y, 0, @max(0, self.bounds_h - 1));
    self.app.pointerMotion(self.pointer_x, self.pointer_y, self.mods());
}

/// Current modifier state, for pointer events.
fn mods(self: *const Input) input.Mods {
    return self.keyboard.mods();
}

fn deviceAdded(self: *Input, dev: *c.struct_libinput_device) void {
    const name = std.mem.span(c.libinput_device_get_name(dev));
    const is_kbd = c.libinput_device_has_capability(dev, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0;
    const is_ptr = c.libinput_device_has_capability(dev, c.LIBINPUT_DEVICE_CAP_POINTER) != 0;
    log.info("input device added name=\"{s}\" keyboard={} pointer={}", .{ name, is_kbd, is_ptr });

    if (is_kbd) {
        self.keyboards.append(self.alloc, c.libinput_device_ref(dev).?) catch return;
        self.updateLeds();
    }
}

fn deviceRemoved(self: *Input, dev: *c.struct_libinput_device) void {
    for (self.keyboards.items, 0..) |kbd, i| {
        if (kbd == dev) {
            _ = c.libinput_device_unref(kbd);
            _ = self.keyboards.swapRemove(i);
            break;
        }
    }
}

fn updateLeds(self: *Input) void {
    const state = self.keyboard.leds();
    var leds: c_uint = 0;
    if (state.caps_lock) leds |= c.LIBINPUT_LED_CAPS_LOCK;
    if (state.num_lock) leds |= c.LIBINPUT_LED_NUM_LOCK;
    if (state.scroll_lock) leds |= c.LIBINPUT_LED_SCROLL_LOCK;
    for (self.keyboards.items) |dev| c.libinput_device_led_update(dev, leds);
}

fn handleKey(self: *Input, code: u32, action: input.Action) void {
    const before = self.keyboard.leds();
    const result = self.keyboard.process(code, action);
    if (!std.meta.eql(before, self.keyboard.leds())) self.updateLeds();

    switch (action) {
        .press => if (self.keyboard.keyRepeats(code)) self.startRepeat(code) else self.stopRepeat(),
        .release => if (self.repeat_key == code) self.stopRepeat(),
        .repeat => {},
    }

    switch (result) {
        .none => {},
        .switch_vt => |vt| {
            self.stopRepeat();
            self.seat.switchSession(vt);
        },
        .key => |ev| self.app.keyEvent(ev),
    }
}

fn startRepeat(self: *Input, code: u32) void {
    if (self.repeat_rate_hz == 0) return;
    self.repeat_key = code;
    const interval_ns: u64 = std.time.ns_per_s / self.repeat_rate_hz;
    const delay_ns: u64 = @as(u64, self.repeat_delay_ms) * std.time.ns_per_ms;
    const spec: c.struct_itimerspec = .{
        .it_value = .{
            .tv_sec = @intCast(delay_ns / std.time.ns_per_s),
            .tv_nsec = @intCast(delay_ns % std.time.ns_per_s),
        },
        .it_interval = .{
            .tv_sec = @intCast(interval_ns / std.time.ns_per_s),
            .tv_nsec = @intCast(interval_ns % std.time.ns_per_s),
        },
    };
    _ = c.timerfd_settime(self.repeat_fd, 0, &spec, null);
}

fn stopRepeat(self: *Input) void {
    self.repeat_key = null;
    const spec = std.mem.zeroes(c.struct_itimerspec);
    _ = c.timerfd_settime(self.repeat_fd, 0, &spec, null);
}

/// Called when the repeat timerfd is readable.
pub fn handleRepeat(self: *Input) void {
    var expirations: u64 = 0;
    if (c.read(self.repeat_fd, &expirations, @sizeOf(u64)) != @sizeOf(u64)) return;
    const code = self.repeat_key orelse return;
    // If we fell behind, don't flood the terminal.
    const n = @min(expirations, 4);
    var i: u64 = 0;
    while (i < n) : (i += 1) self.handleKey(code, .repeat);
}
