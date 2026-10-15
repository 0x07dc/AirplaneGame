const std = @import("std");
const c = @import("c");
// ───────────────────────── Wayland ─────────────────────────

pub const Window = struct {
    display: *c.struct_wl_display_1 = undefined,
    registry: *c.struct_wl_registry = undefined,
    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
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
    /// Physical key state indexed by evdev keycode (layout independent).
    keys: [256]bool = [_]bool{false} ** 256,

    const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = onSeatCaps, .name = onSeatName };
    const kb_listener: c.struct_wl_keyboard_listener = .{
        .keymap = onKbKeymap,
        .enter = onKbEnter,
        .leave = onKbLeave,
        .key = onKbKey,
        .modifiers = onKbMods,
        .repeat_info = onKbRepeat,
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

    pub fn init(self: *Window) !void {
        self.display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        self.registry = c.wl_display_get_registry(self.display) orelse return error.NoRegistry;
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
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
        c.wl_surface_commit(self.surface);
        while (!self.configured) {
            if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDispatch;
        }
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
        if (key < self.keys.len) self.keys[key] = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    }
    fn onKbMods(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onKbRepeat(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}

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
};

/// Linux evdev keycodes (linux/input-event-codes.h).
pub const Key = enum(u8) {
    esc = 1,
    ctrl = 29,
    q = 16,
    w = 17,
    e = 18,
    a = 30,
    s = 31,
    d = 32,
    shift = 42,
    space = 57,
    up = 103,
    left = 105,
    right = 106,
    down = 108,
};

