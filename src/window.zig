const std = @import("std");
const c = @import("c");
// ───────────────────────── Wayland ─────────────────────────

pub const Window = struct {
    display: *c.struct_wl_display_1 = undefined,
    registry: *c.struct_wl_registry = undefined,
    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    decoration_manager: ?*c.struct_zxdg_decoration_manager_v1 = null,
    decoration: ?*c.struct_zxdg_toplevel_decoration_v1 = null,
    surface: *c.struct_wl_surface_2 = undefined,
    xdg_surface: *c.struct_xdg_surface = undefined,
    toplevel: *c.struct_xdg_toplevel = undefined,
    width: u32 = 1280,
    height: u32 = 720,
    configured: bool = false,
    should_close: bool = false,
    resized: bool = false,
    seat: ?*c.struct_wl_seat = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    pointer: ?*c.struct_wl_pointer = null,
    /// Physical key state indexed by evdev keycode (layout independent).
    keys: [256]bool = [_]bool{false} ** 256,
    mouse_left: bool = false,
    mouse_right: bool = false,
    mouse_left_clicked: bool = false,
    mouse_right_clicked: bool = false,
    grave_pressed: bool = false,
    respawn_pressed: bool = false,
    target_pressed: bool = false,
    tab_pressed: bool = false,
    enter_pressed: bool = false,
    space_pressed: bool = false,
    left_shift_pressed: bool = false,
    right_shift_pressed: bool = false,
    bomb_pressed: bool = false,
    esc_pressed: bool = false,
    p_pressed: bool = false,
    l_pressed: bool = false,
    m_pressed: bool = false,
    q_pressed: bool = false,
    up_pressed: bool = false,
    down_pressed: bool = false,
    left_pressed: bool = false,
    right_pressed: bool = false,
    h_pressed: bool = false,
    gear_pressed: ?u8 = null, // 0 = Reverse, 1..9 = forward speed gears
    typed_char: ?u8 = null,
    backspace_pressed: bool = false,

    const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = onSeatCaps, .name = onSeatName };
    const kb_listener: c.struct_wl_keyboard_listener = .{
        .keymap = onKbKeymap,
        .enter = onKbEnter,
        .leave = onKbLeave,
        .key = onKbKey,
        .modifiers = onKbMods,
        .repeat_info = onKbRepeat,
    };
    const pointer_listener: c.struct_wl_pointer_listener = .{
        .enter = onPtrEnter,
        .leave = onPtrLeave,
        .motion = onPtrMotion,
        .button = onPtrButton,
        .axis = onPtrAxis,
        .frame = onPtrFrame,
        .axis_source = onPtrAxisSource,
        .axis_stop = onPtrAxisStop,
        .axis_discrete = onPtrAxisDiscrete,
        .axis_value120 = onPtrAxisValue120,
        .axis_relative_direction = onPtrAxisRelDir,
        .warp = onPtrWarp,
    };

    const registry_listener: c.struct_wl_registry_listener = .{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };
    const wm_listener: c.struct_xdg_wm_base_listener = .{ .ping = onPing };
    const xdg_surface_listener: c.struct_xdg_surface_listener = .{ .configure = onSurfaceConfigure };
    const toplevel_listener: c.struct_xdg_toplevel_listener = .{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onConfigureBounds,
        .wm_capabilities = onWmCapabilities,
    };
    const decoration_listener: c.struct_zxdg_toplevel_decoration_v1_listener = .{
        .configure = onDecorationConfigure,
    };

    pub fn init(self: *Window) !void {
        self.display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        self.registry = c.wl_display_get_registry(self.display) orelse return error.NoRegistry;
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(self.display);
        _ = c.wl_display_roundtrip(self.display);
        const comp = self.compositor orelse return error.NoCompositor;
        const wm = self.wm_base orelse return error.NoXdgShell;
        _ = c.xdg_wm_base_add_listener(wm, &wm_listener, self);

        self.surface = c.wl_compositor_create_surface(comp) orelse return error.NoSurface;
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(wm, self.surface) orelse return error.NoSurface;
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.NoSurface;
        _ = c.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        c.xdg_toplevel_set_title(self.toplevel, "Airplane Game");
        c.xdg_toplevel_set_app_id(self.toplevel, "airplane_game");
        if (self.decoration_manager) |dm| {
            if (c.zxdg_decoration_manager_v1_get_toplevel_decoration(dm, self.toplevel)) |dec| {
                self.decoration = dec;
                _ = c.zxdg_toplevel_decoration_v1_add_listener(dec, &decoration_listener, self);
                c.zxdg_toplevel_decoration_v1_set_mode(dec, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            }
        }
        c.wl_surface_commit(self.surface);
        while (!self.configured) {
            if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDispatch;
        }
        _ = c.wl_display_roundtrip(self.display);
    }

    pub fn deinit(self: *Window) void {
        if (self.decoration) |dec| c.zxdg_toplevel_decoration_v1_destroy(dec);
        if (self.decoration_manager) |dm| c.zxdg_decoration_manager_v1_destroy(dm);
        if (self.keyboard) |kb| c.wl_keyboard_release(kb);
        if (self.pointer) |p| c.wl_pointer_release(p);
        if (self.seat) |seat| c.wl_seat_release(seat);
        c.xdg_toplevel_destroy(self.toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        c.wl_surface_destroy(self.surface);
        if (self.wm_base) |wb| c.xdg_wm_base_destroy(wb);
        if (self.compositor) |comp| c.wl_compositor_destroy(comp);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    /// Non-blocking event pump.
    pub fn pump(self: *Window) void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }
        _ = c.wl_display_flush(self.display);
        var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(self.display), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 0) > 0) {
            _ = c.wl_display_read_events(self.display);
        } else {
            c.wl_display_cancel_read(self.display);
        }
        _ = c.wl_display_dispatch_pending(self.display);
    }

    fn onGlobal(data: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        const i = std.mem.span(iface);
        if (std.mem.eql(u8, i, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, i, "xdg_wm_base")) {
            self.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
        } else if (std.mem.eql(u8, i, "zxdg_decoration_manager_v1")) {
            self.decoration_manager = @ptrCast(c.wl_registry_bind(reg, name, &c.zxdg_decoration_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, i, "wl_seat") and self.seat == null) {
            const seat: *c.struct_wl_seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(version, 5)));
            self.seat = seat;
            _ = c.wl_seat_add_listener(seat, &seat_listener, self);
        }
    }
    fn onSeatCaps(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        const has_kb = (caps & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0;
        if (has_kb and self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            _ = c.wl_keyboard_add_listener(self.keyboard, &kb_listener, self);
        } else if (!has_kb and self.keyboard != null) {
            c.wl_keyboard_release(self.keyboard);
            self.keyboard = null;
        }
        const has_ptr = (caps & c.WL_SEAT_CAPABILITY_POINTER) != 0;
        if (has_ptr and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            _ = c.wl_pointer_add_listener(self.pointer, &pointer_listener, self);
        } else if (!has_ptr and self.pointer != null) {
            c.wl_pointer_release(self.pointer);
            self.pointer = null;
        }
    }
    fn onSeatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}
    fn onKbKeymap(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
        _ = c.close(fd); // we use raw evdev scancodes, no xkb keymap needed
    }
    fn onKbEnter(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface_2, _: [*c]c.struct_wl_array) callconv(.c) void {}
    fn onKbLeave(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface_2) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.keys = [_]bool{false} ** 256; // avoid stuck keys on focus loss
    }
    fn onKbKey(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
        if (key < self.keys.len) self.keys[key] = pressed;
        if (pressed) {
            if (key == 14) {
                self.backspace_pressed = true;
            } else if (key >= 2 and key <= 10) {
                self.typed_char = @as(u8, @intCast(key - 2)) + '1';
            } else if (key == 11) {
                self.typed_char = '0';
            } else if (key == 12) {
                self.typed_char = '-';
            } else if (key == 57) {
                self.typed_char = ' ';
            } else {
                const char_opt: ?u8 = switch (key) {
                    16 => 'Q', 17 => 'W', 18 => 'E', 19 => 'R', 20 => 'T', 21 => 'Y', 22 => 'U', 23 => 'I', 24 => 'O', 25 => 'P',
                    30 => 'A', 31 => 'S', 32 => 'D', 33 => 'F', 34 => 'G', 35 => 'H', 36 => 'J', 37 => 'K', 38 => 'L',
                    44 => 'Z', 45 => 'X', 46 => 'C', 47 => 'V', 48 => 'B', 49 => 'N', 50 => 'M',
                    else => null,
                };
                if (char_opt) |ch| {
                    self.typed_char = ch;
                }
            }

            if (key == @intFromEnum(Key.grave)) {
                self.grave_pressed = true;
            } else if (key == @intFromEnum(Key.r)) {
                self.respawn_pressed = true;
            } else if (key == @intFromEnum(Key.t)) {
                self.target_pressed = true;
            } else if (key == @intFromEnum(Key.tab)) {
                self.tab_pressed = true;
            } else if (key == @intFromEnum(Key.enter)) {
                self.enter_pressed = true;
            } else if (key == @intFromEnum(Key.space)) {
                self.space_pressed = true;
            } else if (key == @intFromEnum(Key.esc)) {
                self.esc_pressed = true;
            } else if (key == @intFromEnum(Key.q)) {
                self.q_pressed = true;
            } else if (key == @intFromEnum(Key.m)) {
                self.m_pressed = true;
            } else if (key == @intFromEnum(Key.w) or key == @intFromEnum(Key.up)) {
                self.up_pressed = true;
            } else if (key == @intFromEnum(Key.s) or key == @intFromEnum(Key.down)) {
                self.down_pressed = true;
            } else if (key == @intFromEnum(Key.a) or key == @intFromEnum(Key.left)) {
                self.left_pressed = true;
            } else if (key == @intFromEnum(Key.d) or key == @intFromEnum(Key.right)) {
                self.right_pressed = true;
            } else if (key == @intFromEnum(Key.h)) {
                self.h_pressed = true;
            } else if (key == @intFromEnum(Key.p)) {
                self.p_pressed = true;
            } else if (key == @intFromEnum(Key.l)) {
                self.l_pressed = true;
            } else if (key == @intFromEnum(Key.left_shift)) {
                self.left_shift_pressed = true;
            } else if (key == @intFromEnum(Key.right_shift)) {
                self.right_shift_pressed = true;
            } else if (key == @intFromEnum(Key.c_key) or key == @intFromEnum(Key.right_ctrl)) {
                self.bomb_pressed = true;
            } else if (key >= @intFromEnum(Key.key_1) and key <= @intFromEnum(Key.key_9)) {
                self.gear_pressed = @intCast(key - @intFromEnum(Key.key_1) + 1);
            } else if (key == @intFromEnum(Key.key_0)) {
                self.gear_pressed = 0;
            }
        }
    }
    fn onKbMods(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onKbRepeat(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}

    fn onPtrEnter(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface_2, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
    fn onPtrLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface_2) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.mouse_left = false;
        self.mouse_right = false;
    }
    fn onPtrMotion(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
    fn onPtrButton(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {
        // Mouse controls turned off
    }
    fn onPtrAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn onPtrFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn onPtrAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn onPtrAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPtrAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPtrAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPtrAxisRelDir(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPtrWarp(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}

    pub fn down(self: *const Window, key: Key) bool {
        return self.keys[@intFromEnum(key)];
    }
    fn onGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    fn onPing(_: ?*anyopaque, wm: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(wm, serial);
    }
    fn onSurfaceConfigure(data: ?*anyopaque, s: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        c.xdg_surface_ack_configure(s, serial);
        self.configured = true;
    }
    fn onToplevelConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, w: i32, h: i32, _: [*c]c.struct_wl_array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        if (w > 0 and h > 0 and (self.width != w or self.height != h)) {
            self.width = @intCast(w);
            self.height = @intCast(h);
            self.resized = true;
        }
    }
    fn onToplevelClose(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.should_close = true;
    }
    fn onConfigureBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn onWmCapabilities(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}
    fn onDecorationConfigure(_: ?*anyopaque, _: ?*c.struct_zxdg_toplevel_decoration_v1, _: u32) callconv(.c) void {}
};

/// Linux evdev keycodes (linux/input-event-codes.h).
pub const Key = enum(u8) {
    esc = 1,
    key_1 = 2,
    key_2 = 3,
    key_3 = 4,
    key_4 = 5,
    key_5 = 6,
    key_6 = 7,
    key_7 = 8,
    key_8 = 9,
    key_9 = 10,
    key_0 = 11,
    minus = 12,
    equal = 13,
    tab = 15,
    q = 16,
    w = 17,
    e = 18,
    r = 19,
    t = 20,
    p = 25,
    lbracket = 26,
    rbracket = 27,
    enter = 28,
    ctrl = 29,
    a = 30,
    s = 31,
    d = 32,
    f = 33,
    h = 35,
    l = 38,
    grave = 41,
    left_shift = 42,
    z_key = 44,
    c_key = 46,
    m = 50,
    right_shift = 54,
    space = 57,
    right_ctrl = 97,
    up = 103,
    left = 105,
    right = 106,
    down = 108,
};

