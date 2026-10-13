//! Keyboard state: xkbcommon keymap, modifier state and compose (dead
//! keys), turning evdev key codes into Ghostty key events.
//!
//! The produced events intentionally match what the GTK apprt produces
//! (see src/apprt/gtk/key.zig and the GTK surface's keyEvent), since the
//! core's key encoding is tuned against it. In particular the UTF-8 text is
//! the keysym's character without control transformation (Ctrl+A gives
//! "a", not "\x01"), and C0 control characters are never sent as text.
const Keyboard = @This();

const std = @import("std");
const c = @import("kms_c");
const input = @import("../../input.zig");
const util = @import("util.zig");

const log = std.log.scoped(.kms_keyboard);

ctx: *c.struct_xkb_context,
keymap: *c.struct_xkb_keymap,
state: *c.struct_xkb_state,
compose_table: ?*c.struct_xkb_compose_table,
compose_state: ?*c.struct_xkb_compose_state,

mod_shift: c.xkb_mod_index_t,
mod_ctrl: c.xkb_mod_index_t,
mod_alt: c.xkb_mod_index_t,
mod_super: c.xkb_mod_index_t,
mod_caps: c.xkb_mod_index_t,
mod_num: c.xkb_mod_index_t,

/// Backing storage for the UTF-8 text of the last event.
utf8_buf: [64]u8 = undefined,

pub fn init(self: *Keyboard) !void {
    const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
    errdefer c.xkb_context_unref(ctx);

    // With all-null names, xkbcommon uses the XKB_DEFAULT_RULES/MODEL/
    // LAYOUT/VARIANT/OPTIONS environment variables, falling back to "us".
    const keymap = c.xkb_keymap_new_from_names(ctx, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
        log.err("failed to compile keymap; check XKB_DEFAULT_LAYOUT and friends", .{});
        return error.XkbKeymapFailed;
    };
    errdefer c.xkb_keymap_unref(keymap);

    const state = c.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    errdefer c.xkb_state_unref(state);

    // Compose tables are locale dependent; a missing table just disables
    // dead keys.
    const locale = util.env("LC_ALL") orelse util.env("LC_CTYPE") orelse util.env("LANG") orelse "C";
    const table = c.xkb_compose_table_new_from_locale(ctx, locale.ptr, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
    const compose_state = if (table) |t| c.xkb_compose_state_new(t, c.XKB_COMPOSE_STATE_NO_FLAGS) else null;
    if (table == null) log.info("no compose table for locale={s}; dead keys disabled", .{locale});

    self.* = .{
        .ctx = ctx,
        .keymap = keymap,
        .state = state,
        .compose_table = table,
        .compose_state = compose_state,
        .mod_shift = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_SHIFT),
        .mod_ctrl = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CTRL),
        .mod_alt = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_ALT),
        .mod_super = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_LOGO),
        .mod_caps = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CAPS),
        .mod_num = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_NUM),
    };
}

pub fn deinit(self: *Keyboard) void {
    if (self.compose_state) |s| c.xkb_compose_state_unref(s);
    if (self.compose_table) |t| c.xkb_compose_table_unref(t);
    c.xkb_state_unref(self.state);
    c.xkb_keymap_unref(self.keymap);
    c.xkb_context_unref(self.ctx);
}

/// Whether holding this key should auto-repeat.
pub fn keyRepeats(self: *const Keyboard, evdev_code: u32) bool {
    return c.xkb_keymap_key_repeats(self.keymap, evdev_code + 8) != 0;
}

pub const Leds = struct { caps_lock: bool, num_lock: bool, scroll_lock: bool };

pub fn leds(self: *const Keyboard) Leds {
    return .{
        .caps_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_CAPS) > 0,
        .num_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_NUM) > 0,
        .scroll_lock = c.xkb_state_led_name_is_active(self.state, c.XKB_LED_NAME_SCROLL) > 0,
    };
}

pub const Result = union(enum) {
    /// A key event for the core. `utf8` points into the Keyboard and is
    /// valid until the next call.
    key: input.KeyEvent,

    /// Ctrl+Alt+Fn: switch to VT n. Not forwarded to the terminal.
    switch_vt: u8,

    /// Swallowed (e.g. a cancelled compose sequence).
    none,
};

/// Process a key. `evdev_code` is the Linux input event code (what
/// libinput reports); `action` is press/release/repeat. Updates the
/// modifier state for presses and releases.
pub fn process(self: *Keyboard, evdev_code: u32, action: input.Action) Result {
    const kc: c.xkb_keycode_t = evdev_code + 8;
    const sym = c.xkb_state_key_get_one_sym(self.state, kc);

    // Modifier state as it was when the key went down, matching what GTK
    // reports, then the state is updated after we've built the event.
    defer if (action != .repeat) {
        _ = c.xkb_state_update_key(
            self.state,
            kc,
            if (action == .release) c.XKB_KEY_UP else c.XKB_KEY_DOWN,
        );
    };

    if (action == .press and sym >= c.XKB_KEY_XF86Switch_VT_1 and sym <= c.XKB_KEY_XF86Switch_VT_12) {
        return .{ .switch_vt = @intCast(sym - c.XKB_KEY_XF86Switch_VT_1 + 1) };
    }

    const physical = physicalKey(kc);
    const key = remapKey(physical, sym, isModifierKeysym(sym));

    var ev_mods = self.mods();
    applySidedMods(&ev_mods, physical, action);

    const consumed: input.Mods = .{
        .shift = self.isConsumed(kc, self.mod_shift),
        .ctrl = self.isConsumed(kc, self.mod_ctrl),
        .alt = self.isConsumed(kc, self.mod_alt),
        .super = self.isConsumed(kc, self.mod_super),
    };

    // Compose (dead keys) on press/repeat.
    var composing = false;
    var text: []const u8 = "";
    compose: {
        if (action == .release) break :compose;
        const cs = self.compose_state orelse break :compose;
        if (c.xkb_compose_state_feed(cs, sym) != c.XKB_COMPOSE_FEED_ACCEPTED) break :compose;
        switch (c.xkb_compose_state_get_status(cs)) {
            c.XKB_COMPOSE_COMPOSING => {
                composing = true;
            },
            c.XKB_COMPOSE_COMPOSED => {
                const n = c.xkb_compose_state_get_utf8(cs, &self.utf8_buf, self.utf8_buf.len);
                c.xkb_compose_state_reset(cs);
                if (n > 0 and n < self.utf8_buf.len) text = self.utf8_buf[0..@intCast(n)];
                // The composed text is what this key produced.
                return .{ .key = .{
                    .action = action,
                    .key = key,
                    .mods = ev_mods,
                    .consumed_mods = consumed,
                    .utf8 = text,
                    .unshifted_codepoint = self.unshiftedCodepoint(kc),
                } };
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(cs);
                return .none;
            },
            else => {},
        }
    }

    if (!composing) text = self.keysymText(sym);

    return .{ .key = .{
        .action = action,
        .key = key,
        .mods = ev_mods,
        .consumed_mods = consumed,
        .composing = composing,
        .utf8 = text,
        .unshifted_codepoint = self.unshiftedCodepoint(kc),
    } };
}

/// Current effective modifier state (used for pointer events).
pub fn mods(self: *const Keyboard) input.Mods {
    return .{
        .shift = self.modActive(self.mod_shift),
        .ctrl = self.modActive(self.mod_ctrl),
        .alt = self.modActive(self.mod_alt),
        .super = self.modActive(self.mod_super),
        .caps_lock = self.modActive(self.mod_caps),
        .num_lock = self.modActive(self.mod_num),
    };
}

fn modActive(self: *const Keyboard, idx: c.xkb_mod_index_t) bool {
    if (idx == c.XKB_MOD_INVALID) return false;
    return c.xkb_state_mod_index_is_active(self.state, idx, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn isConsumed(self: *const Keyboard, kc: c.xkb_keycode_t, idx: c.xkb_mod_index_t) bool {
    if (idx == c.XKB_MOD_INVALID) return false;
    return c.xkb_state_mod_index_is_consumed2(self.state, kc, idx, c.XKB_CONSUMED_MODE_GTK) > 0;
}

/// The text a keysym produces, without control transformation. C0
/// controls (Return, Tab, Escape, ...) produce no text; the encoder
/// handles those from the key itself. Same rule as the GTK apprt.
fn keysymText(self: *Keyboard, sym: c.xkb_keysym_t) []const u8 {
    const cp = c.xkb_keysym_to_utf32(sym);
    if (cp < 0x20) return "";
    const n = c.xkb_keysym_to_utf8(sym, &self.utf8_buf, self.utf8_buf.len);
    // n includes the terminating NUL.
    if (n <= 1) return "";
    return self.utf8_buf[0..@intCast(n - 1)];
}

/// The codepoint of the key at shift level 0 in the active layout, used
/// by the Kitty keyboard protocol.
fn unshiftedCodepoint(self: *const Keyboard, kc: c.xkb_keycode_t) u21 {
    const layout = c.xkb_state_key_get_layout(self.state, kc);
    if (layout == c.XKB_LAYOUT_INVALID) return 0;
    var syms: [*c]const c.xkb_keysym_t = undefined;
    const n = c.xkb_keymap_key_get_syms_by_level(self.keymap, kc, layout, 0, &syms);
    if (n < 1) return 0;
    return std.math.cast(u21, c.xkb_keysym_to_utf32(syms[0])) orelse 0;
}

/// The layout-independent key from Ghostty's keycode table (native codes
/// on Linux are XKB keycodes, i.e. evdev + 8).
pub fn physicalKey(kc: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == kc) return entry.key;
    }
    return .unidentified;
}

/// Same as the GTK apprt: sided modifiers come from the physical key, and
/// the main modifier bit reflects the key itself on press/release, since
/// XKB state doesn't include the key being pressed yet.
fn applySidedMods(m: *input.Mods, physical: input.Key, action: input.Action) void {
    const down = action != .release;
    switch (physical) {
        .shift_left => {
            m.shift = down;
            m.sides.shift = .left;
        },
        .shift_right => {
            m.shift = down;
            m.sides.shift = .right;
        },
        .control_left => {
            m.ctrl = down;
            m.sides.ctrl = .left;
        },
        .control_right => {
            m.ctrl = down;
            m.sides.ctrl = .right;
        },
        .alt_left => {
            m.alt = down;
            m.sides.alt = .left;
        },
        .alt_right => {
            m.alt = down;
            m.sides.alt = .right;
        },
        .meta_left => {
            m.super = down;
            m.sides.super = .left;
        },
        .meta_right => {
            m.super = down;
            m.sides.super = .right;
        },
        else => {},
    }
}

/// Returns the logical key after applying XKB remapping, with the same
/// rules as the GTK apprt's `remapKey`.
pub fn remapKey(physical: input.Key, sym: u32, is_modifier: bool) input.Key {
    if (keyFromKeysym(sym)) |remapped| {
        if (physical.shouldBeRemappable() or remapped.shouldBeRemappable())
            return remapped;
    }

    if (is_modifier or isModifierKeysym(sym)) return .unidentified;
    return physical;
}

fn isModifierKeysym(sym: u32) bool {
    return switch (sym) {
        c.XKB_KEY_Shift_L,
        c.XKB_KEY_Shift_R,
        c.XKB_KEY_Shift_Lock,
        c.XKB_KEY_Control_L,
        c.XKB_KEY_Control_R,
        c.XKB_KEY_Caps_Lock,
        c.XKB_KEY_Meta_L,
        c.XKB_KEY_Meta_R,
        c.XKB_KEY_Alt_L,
        c.XKB_KEY_Alt_R,
        c.XKB_KEY_Super_L,
        c.XKB_KEY_Super_R,
        c.XKB_KEY_Hyper_L,
        c.XKB_KEY_Hyper_R,
        c.XKB_KEY_Num_Lock,
        c.XKB_KEY_Mode_switch,
        c.XKB_KEY_ISO_Lock,
        c.XKB_KEY_ISO_Level2_Latch,
        c.XKB_KEY_ISO_Level3_Shift,
        c.XKB_KEY_ISO_Level3_Latch,
        c.XKB_KEY_ISO_Level3_Lock,
        c.XKB_KEY_ISO_Level5_Shift,
        c.XKB_KEY_ISO_Level5_Latch,
        c.XKB_KEY_ISO_Level5_Lock,
        c.XKB_KEY_ISO_Group_Latch,
        c.XKB_KEY_ISO_Group_Lock,
        => true,
        else => false,
    };
}

pub fn keyFromKeysym(sym: u32) ?input.Key {
    for (keysym_table) |entry| {
        if (entry[0] == sym) return entry[1];
    }
    return null;
}

/// Keysym to key table. GDK keyvals are X keysyms, so this is the GTK
/// apprt's table with XKB names.
const keysym_table: []const struct { u32, input.Key } = &.{
    .{ c.XKB_KEY_a, .key_a },
    .{ c.XKB_KEY_b, .key_b },
    .{ c.XKB_KEY_c, .key_c },
    .{ c.XKB_KEY_d, .key_d },
    .{ c.XKB_KEY_e, .key_e },
    .{ c.XKB_KEY_f, .key_f },
    .{ c.XKB_KEY_g, .key_g },
    .{ c.XKB_KEY_h, .key_h },
    .{ c.XKB_KEY_i, .key_i },
    .{ c.XKB_KEY_j, .key_j },
    .{ c.XKB_KEY_k, .key_k },
    .{ c.XKB_KEY_l, .key_l },
    .{ c.XKB_KEY_m, .key_m },
    .{ c.XKB_KEY_n, .key_n },
    .{ c.XKB_KEY_o, .key_o },
    .{ c.XKB_KEY_p, .key_p },
    .{ c.XKB_KEY_q, .key_q },
    .{ c.XKB_KEY_r, .key_r },
    .{ c.XKB_KEY_s, .key_s },
    .{ c.XKB_KEY_t, .key_t },
    .{ c.XKB_KEY_u, .key_u },
    .{ c.XKB_KEY_v, .key_v },
    .{ c.XKB_KEY_w, .key_w },
    .{ c.XKB_KEY_x, .key_x },
    .{ c.XKB_KEY_y, .key_y },
    .{ c.XKB_KEY_z, .key_z },

    .{ c.XKB_KEY_0, .digit_0 },
    .{ c.XKB_KEY_1, .digit_1 },
    .{ c.XKB_KEY_2, .digit_2 },
    .{ c.XKB_KEY_3, .digit_3 },
    .{ c.XKB_KEY_4, .digit_4 },
    .{ c.XKB_KEY_5, .digit_5 },
    .{ c.XKB_KEY_6, .digit_6 },
    .{ c.XKB_KEY_7, .digit_7 },
    .{ c.XKB_KEY_8, .digit_8 },
    .{ c.XKB_KEY_9, .digit_9 },

    .{ c.XKB_KEY_semicolon, .semicolon },
    .{ c.XKB_KEY_space, .space },
    .{ c.XKB_KEY_apostrophe, .quote },
    .{ c.XKB_KEY_comma, .comma },
    .{ c.XKB_KEY_grave, .backquote },
    .{ c.XKB_KEY_period, .period },
    .{ c.XKB_KEY_slash, .slash },
    .{ c.XKB_KEY_minus, .minus },
    .{ c.XKB_KEY_equal, .equal },
    .{ c.XKB_KEY_bracketleft, .bracket_left },
    .{ c.XKB_KEY_bracketright, .bracket_right },
    .{ c.XKB_KEY_backslash, .backslash },

    .{ c.XKB_KEY_Up, .arrow_up },
    .{ c.XKB_KEY_Down, .arrow_down },
    .{ c.XKB_KEY_Right, .arrow_right },
    .{ c.XKB_KEY_Left, .arrow_left },
    .{ c.XKB_KEY_Home, .home },
    .{ c.XKB_KEY_End, .end },
    .{ c.XKB_KEY_Insert, .insert },
    .{ c.XKB_KEY_Delete, .delete },
    .{ c.XKB_KEY_Caps_Lock, .caps_lock },
    .{ c.XKB_KEY_Scroll_Lock, .scroll_lock },
    .{ c.XKB_KEY_Num_Lock, .num_lock },
    .{ c.XKB_KEY_Page_Up, .page_up },
    .{ c.XKB_KEY_Page_Down, .page_down },
    .{ c.XKB_KEY_Escape, .escape },
    .{ c.XKB_KEY_Return, .enter },
    .{ c.XKB_KEY_Tab, .tab },
    .{ c.XKB_KEY_BackSpace, .backspace },
    .{ c.XKB_KEY_Print, .print_screen },
    .{ c.XKB_KEY_Pause, .pause },

    .{ c.XKB_KEY_F1, .f1 },
    .{ c.XKB_KEY_F2, .f2 },
    .{ c.XKB_KEY_F3, .f3 },
    .{ c.XKB_KEY_F4, .f4 },
    .{ c.XKB_KEY_F5, .f5 },
    .{ c.XKB_KEY_F6, .f6 },
    .{ c.XKB_KEY_F7, .f7 },
    .{ c.XKB_KEY_F8, .f8 },
    .{ c.XKB_KEY_F9, .f9 },
    .{ c.XKB_KEY_F10, .f10 },
    .{ c.XKB_KEY_F11, .f11 },
    .{ c.XKB_KEY_F12, .f12 },
    .{ c.XKB_KEY_F13, .f13 },
    .{ c.XKB_KEY_F14, .f14 },
    .{ c.XKB_KEY_F15, .f15 },
    .{ c.XKB_KEY_F16, .f16 },
    .{ c.XKB_KEY_F17, .f17 },
    .{ c.XKB_KEY_F18, .f18 },
    .{ c.XKB_KEY_F19, .f19 },
    .{ c.XKB_KEY_F20, .f20 },
    .{ c.XKB_KEY_F21, .f21 },
    .{ c.XKB_KEY_F22, .f22 },
    .{ c.XKB_KEY_F23, .f23 },
    .{ c.XKB_KEY_F24, .f24 },
    .{ c.XKB_KEY_F25, .f25 },

    .{ c.XKB_KEY_KP_0, .numpad_0 },
    .{ c.XKB_KEY_KP_1, .numpad_1 },
    .{ c.XKB_KEY_KP_2, .numpad_2 },
    .{ c.XKB_KEY_KP_3, .numpad_3 },
    .{ c.XKB_KEY_KP_4, .numpad_4 },
    .{ c.XKB_KEY_KP_5, .numpad_5 },
    .{ c.XKB_KEY_KP_6, .numpad_6 },
    .{ c.XKB_KEY_KP_7, .numpad_7 },
    .{ c.XKB_KEY_KP_8, .numpad_8 },
    .{ c.XKB_KEY_KP_9, .numpad_9 },
    .{ c.XKB_KEY_KP_Decimal, .numpad_decimal },
    .{ c.XKB_KEY_KP_Divide, .numpad_divide },
    .{ c.XKB_KEY_KP_Multiply, .numpad_multiply },
    .{ c.XKB_KEY_KP_Subtract, .numpad_subtract },
    .{ c.XKB_KEY_KP_Add, .numpad_add },
    .{ c.XKB_KEY_KP_Enter, .numpad_enter },
    .{ c.XKB_KEY_KP_Equal, .numpad_equal },

    .{ c.XKB_KEY_KP_Separator, .numpad_separator },
    .{ c.XKB_KEY_KP_Left, .numpad_left },
    .{ c.XKB_KEY_KP_Right, .numpad_right },
    .{ c.XKB_KEY_KP_Up, .numpad_up },
    .{ c.XKB_KEY_KP_Down, .numpad_down },
    .{ c.XKB_KEY_KP_Page_Up, .numpad_page_up },
    .{ c.XKB_KEY_KP_Page_Down, .numpad_page_down },
    .{ c.XKB_KEY_KP_Home, .numpad_home },
    .{ c.XKB_KEY_KP_End, .numpad_end },
    .{ c.XKB_KEY_KP_Insert, .numpad_insert },
    .{ c.XKB_KEY_KP_Delete, .numpad_delete },
    .{ c.XKB_KEY_KP_Begin, .numpad_begin },

    .{ c.XKB_KEY_XF86Copy, .copy },
    .{ c.XKB_KEY_XF86Cut, .cut },
    .{ c.XKB_KEY_XF86Paste, .paste },

    .{ c.XKB_KEY_Shift_L, .shift_left },
    .{ c.XKB_KEY_Control_L, .control_left },
    .{ c.XKB_KEY_Alt_L, .alt_left },
    .{ c.XKB_KEY_Super_L, .meta_left },
    .{ c.XKB_KEY_Shift_R, .shift_right },
    .{ c.XKB_KEY_Control_R, .control_right },
    .{ c.XKB_KEY_Alt_R, .alt_right },
    .{ c.XKB_KEY_Super_R, .meta_right },
};

test "remap key" {
    const testing = std.testing;
    try testing.expectEqual(input.Key.escape, remapKey(.caps_lock, c.XKB_KEY_Escape, false));
    try testing.expectEqual(input.Key.key_a, remapKey(.key_a, c.XKB_KEY_b, false));
    try testing.expectEqual(input.Key.unidentified, remapKey(.delete, c.XKB_KEY_Mode_switch, false));
    try testing.expectEqual(input.Key.unidentified, remapKey(.delete, c.XKB_KEY_VoidSymbol, true));
}

test "physical key" {
    const testing = std.testing;
    // evdev KEY_A is 30, XKB keycode 38.
    try testing.expectEqual(input.Key.key_a, physicalKey(c.KEY_A + 8));
    try testing.expectEqual(input.Key.escape, physicalKey(c.KEY_ESC + 8));
}
