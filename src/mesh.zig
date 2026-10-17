//! Procedural low-poly meshes (flat shaded, vertex colored).
const std = @import("std");
const m = @import("math.zig");
const Vec3 = m.Vec3;
const font_data = @import("font_data.zig");

pub const Vertex = extern struct {
    pos: [3]f32,
    nrm: [3]f32,
    col: [3]f32,
};

/// sRGB hex-ish (0..255) to linear color (the swapchain is an sRGB format).
pub fn srgb(r: u8, g: u8, b: u8) Vec3 {
    const f = struct {
        fn c(v: u8) f32 {
            return std.math.pow(f32, @as(f32, @floatFromInt(v)) / 255.0, 2.2);
        }
    };
    return Vec3.init(f.c(r), f.c(g), f.c(b));
}

pub const Builder = struct {
    verts: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Builder) void {
        self.verts.deinit(self.alloc);
        self.indices.deinit(self.alloc);
    }

    /// Flat triangle. The normal is flipped to point away from `inside`.
    pub fn tri(self: *Builder, a: Vec3, b: Vec3, c: Vec3, col: Vec3, inside: Vec3) !void {
        var n = b.sub(a).cross(c.sub(a)).norm();
        if (n.dot(a.sub(inside)) < 0) n = n.scale(-1);
        const base: u32 = @intCast(self.verts.items.len);
        for ([_]Vec3{ a, b, c }) |p| {
            try self.verts.append(self.alloc, .{
                .pos = .{ p.x, p.y, p.z },
                .nrm = .{ n.x, n.y, n.z },
                .col = .{ col.x, col.y, col.z },
            });
        }
        try self.indices.appendSlice(self.alloc, &.{ base, base + 1, base + 2 });
    }

    pub fn quad(self: *Builder, a: Vec3, b: Vec3, c: Vec3, d: Vec3, col: Vec3, inside: Vec3) !void {
        try self.tri(a, b, c, col, inside);
        try self.tri(a, c, d, col, inside);
    }

    /// Extruded convex quad: `p` offset by ±`off`.
    pub fn slab(self: *Builder, p: [4]Vec3, off: Vec3, col: Vec3) !void {
        var center = Vec3.zero;
        for (p) |v| center = center.add(v.scale(0.25));
        var t: [4]Vec3 = undefined;
        var b: [4]Vec3 = undefined;
        for (p, 0..) |v, i| {
            t[i] = v.add(off);
            b[i] = v.sub(off);
        }
        try self.quad(t[0], t[1], t[2], t[3], col, center);
        try self.quad(b[0], b[1], b[2], b[3], col, center);
        for (0..4) |i| {
            const j = (i + 1) % 4;
            try self.quad(t[i], t[j], b[j], b[i], col, center);
        }
    }

    /// Hexagonal ring at station z (nose toward -Z).
    fn ring(z: f32, rw: f32, rh: f32, cy: f32) [6]Vec3 {
        var r: [6]Vec3 = undefined;
        for (0..6) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
            r[i] = Vec3.init(@cos(a) * rw, cy + @sin(a) * rh, z);
        }
        return r;
    }
};

pub const MeshData = struct {
    verts: []Vertex,
    indices: []u32,
};

/// Stylized small fighter. ~12 m long, ~13 m span. Nose toward -Z, up +Y.
pub fn buildPlane(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const body = srgb(232, 238, 244);
    const body2 = srgb(196, 206, 218);
    const dark = srgb(46, 52, 66);
    const glass = srgb(60, 140, 220);
    const glow = srgb(255, 190, 90);

    // Fuselage: stations from nose to tail.
    const st = [_][4]f32{
        // z, rw, rh, cy
        .{ -7.0, 0.05, 0.05, 0.0 },
        .{ -4.5, 0.55, 0.45, 0.0 },
        .{ -1.0, 0.95, 0.75, 0.05 },
        .{ 3.0, 0.9, 0.7, 0.05 },
        .{ 6.0, 0.55, 0.5, 0.0 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, st[i][3], (st[i][0] + st[i + 1][0]) * 0.5);
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            const col = if ((i + k) % 2 == 0) body else body2;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }
    // Tail cap + engine glow
    const tail = rings[st.len - 1];
    const tail_c = Vec3.init(0, 0, 6.0);
    for (0..6) |k| try b.tri(tail[k], tail[(k + 1) % 6], tail_c.add(Vec3.init(0, 0, 0.05)), dark, Vec3.init(0, 0, 0));
    const nozzle = Builder.ring(6.12, 0.34, 0.3, 0);
    for (0..6) |k| try b.tri(nozzle[k], nozzle[(k + 1) % 6], Vec3.init(0, 0, 6.2), glow, Vec3.init(0, 0, 0));

    // Canopy
    const cz0: f32 = -3.6;
    const cz1: f32 = -0.4;
    const canopy_pts = [_]Vec3{
        Vec3.init(-0.45, 0.55, cz0 + 0.8), Vec3.init(0.45, 0.55, cz0 + 0.8),
        Vec3.init(0.5, 0.6, cz1),           Vec3.init(-0.5, 0.6, cz1),
    };
    const tip = Vec3.init(0, 1.15, -1.8);
    const cc = Vec3.init(0, 0.4, -2);
    try b.tri(canopy_pts[0], canopy_pts[1], tip, glass, cc);
    try b.tri(canopy_pts[1], canopy_pts[2], tip, glass, cc);
    try b.tri(canopy_pts[2], canopy_pts[3], tip, dark, cc);
    try b.tri(canopy_pts[3], canopy_pts[0], tip, glass, cc);

    // Swept delta wings (accent) — mirrored.
    inline for (.{ @as(f32, 1), @as(f32, -1) }) |sx| {
        const wing = [4]Vec3{
            Vec3.init(sx * 0.8, -0.1, -1.6),
            Vec3.init(sx * 6.6, -0.1, 3.0),
            Vec3.init(sx * 6.6, -0.1, 3.9),
            Vec3.init(sx * 0.8, -0.1, 3.9),
        };
        try b.slab(wing, Vec3.init(0, 0.07, 0), accent);
        // tail planes
        const tp = [4]Vec3{
            Vec3.init(sx * 0.7, 0.0, 4.0),
            Vec3.init(sx * 3.0, 0.0, 5.6),
            Vec3.init(sx * 3.0, 0.0, 6.2),
            Vec3.init(sx * 0.7, 0.0, 6.0),
        };
        try b.slab(tp, Vec3.init(0, 0.05, 0), body);
        // canted fins
        const fin = [4]Vec3{
            Vec3.init(sx * 0.7, 0.6, 3.3),
            Vec3.init(sx * 1.35, 2.5, 5.0),
            Vec3.init(sx * 1.35, 2.5, 5.7),
            Vec3.init(sx * 0.7, 0.6, 6.0),
        };
        try b.slab(fin, Vec3.init(0.05, 0, 0), accent);
    }
    return b;
}

/// Aerodynamic fighter plane with ultra-luminous glowing neon livery for Assisted Flight mode.
/// Features electric neon cyan fuselage, hot neon magenta wings and canted fins,
/// radiant solar gold cockpit canopy, luminous electric lime wingtip rails and photon striping,
/// and incandescent white-hot exhaust nozzle.
pub fn buildNeonAssistedPlane(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    // High-luminance neon colors:
    const neon_cyan = Vec3.init(0.12, 1.25, 1.45); // vibrant electric cyan
    const deep_teal = Vec3.init(0.05, 0.85, 1.05); // complementary luminous teal
    const neon_magenta = Vec3.init(1.45, 0.15, 0.95); // hot neon magenta/pink
    const neon_purple = Vec3.init(0.95, 0.08, 1.25); // neon violet/purple
    const neon_gold = Vec3.init(1.50, 1.35, 0.30); // radiant solar gold canopy
    const neon_lime = Vec3.init(0.45, 1.40, 0.55); // glowing electric lime striping
    const hot_white = Vec3.init(1.80, 1.80, 1.80); // incandescent nozzle collar

    // 1. Fuselage ring segments with alternating electric cyan & luminous deep teal
    const st = [_][4]f32{
        // z, rw, rh, cy
        .{ -7.0, 0.05, 0.05, 0.0 },
        .{ -4.5, 0.55, 0.45, 0.0 },
        .{ -1.0, 0.95, 0.75, 0.05 },
        .{ 3.0, 0.9, 0.7, 0.05 },
        .{ 6.0, 0.55, 0.5, 0.0 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, st[i][3], (st[i][0] + st[i + 1][0]) * 0.5);
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            const col = if ((i + k) % 2 == 0) neon_cyan else deep_teal;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }

    // 2. Tail cap + incandescent white-hot engine nozzle
    const tail = rings[st.len - 1];
    const tail_c = Vec3.init(0, 0, 6.0);
    for (0..6) |k| try b.tri(tail[k], tail[(k + 1) % 6], tail_c.add(Vec3.init(0, 0, 0.05)), neon_purple, Vec3.init(0, 0, 0));
    const nozzle = Builder.ring(6.12, 0.36, 0.32, 0);
    for (0..6) |k| try b.tri(nozzle[k], nozzle[(k + 1) % 6], Vec3.init(0, 0, 6.22), hot_white, Vec3.init(0, 0, 0));

    // 3. Glowing solar gold cockpit canopy
    const cz0: f32 = -3.6;
    const cz1: f32 = -0.4;
    const canopy_pts = [_]Vec3{
        Vec3.init(-0.45, 0.55, cz0 + 0.8), Vec3.init(0.45, 0.55, cz0 + 0.8),
        Vec3.init(0.5, 0.6, cz1),           Vec3.init(-0.5, 0.6, cz1),
    };
    const tip = Vec3.init(0, 1.15, -1.8);
    const cc = Vec3.init(0, 0.4, -2);
    try b.tri(canopy_pts[0], canopy_pts[1], tip, neon_gold, cc);
    try b.tri(canopy_pts[1], canopy_pts[2], tip, neon_gold, cc);
    try b.tri(canopy_pts[2], canopy_pts[3], tip, neon_purple, cc);
    try b.tri(canopy_pts[3], canopy_pts[0], tip, neon_gold, cc);

    // 4. Swept delta wings, horizontal stabilizers, and canted vertical fins (mirrored)
    inline for (.{ @as(f32, 1), @as(f32, -1) }) |sx| {
        // Delta wings (hot neon magenta)
        const wing = [4]Vec3{
            Vec3.init(sx * 0.8, -0.1, -1.6),
            Vec3.init(sx * 6.6, -0.1, 3.0),
            Vec3.init(sx * 6.6, -0.1, 3.9),
            Vec3.init(sx * 0.8, -0.1, 3.9),
        };
        try b.slab(wing, Vec3.init(0, 0.08, 0), neon_magenta);

        // Glowing wingtip missile launcher rails (electric lime)
        const wingtip_rail = [4]Vec3{
            Vec3.init(sx * 6.6, -0.12, 1.8),
            Vec3.init(sx * 6.82, -0.12, 1.8),
            Vec3.init(sx * 6.82, -0.12, 4.2),
            Vec3.init(sx * 6.6, -0.12, 4.2),
        };
        try b.slab(wingtip_rail, Vec3.init(0, 0.10, 0), neon_lime);

        // Wing leading edge neon photon stripe
        const leading_stripe = [4]Vec3{
            Vec3.init(sx * 0.8, -0.06, -1.5),
            Vec3.init(sx * 6.5, -0.06, 2.9),
            Vec3.init(sx * 6.35, -0.06, 3.1),
            Vec3.init(sx * 0.8, -0.06, -1.2),
        };
        try b.slab(leading_stripe, Vec3.init(0, 0.05, 0), neon_cyan);

        // Tail horizontal stabilizers (cyan body)
        const tp = [4]Vec3{
            Vec3.init(sx * 0.7, 0.0, 4.0),
            Vec3.init(sx * 3.0, 0.0, 5.6),
            Vec3.init(sx * 3.0, 0.0, 6.2),
            Vec3.init(sx * 0.7, 0.0, 6.0),
        };
        try b.slab(tp, Vec3.init(0, 0.06, 0), neon_cyan);

        // Canted twin vertical stabilizers (hot neon magenta with electric lime tip)
        const fin = [4]Vec3{
            Vec3.init(sx * 0.7, 0.6, 3.3),
            Vec3.init(sx * 1.35, 2.5, 5.0),
            Vec3.init(sx * 1.35, 2.5, 5.7),
            Vec3.init(sx * 0.7, 0.6, 6.0),
        };
        try b.slab(fin, Vec3.init(0.06, 0, 0), neon_magenta);

        // Fin tip neon beacon cap
        const fin_cap = [4]Vec3{
            Vec3.init(sx * 1.32, 2.45, 5.0),
            Vec3.init(sx * 1.38, 2.65, 5.0),
            Vec3.init(sx * 1.38, 2.65, 5.7),
            Vec3.init(sx * 1.32, 2.45, 5.7),
        };
        try b.slab(fin_cap, Vec3.init(0.06, 0, 0), neon_lime);
    }
    return b;
}

/// Builds a glowing supersonic jet afterburner plume extending rearwards from the engine nozzle.
/// Features:
/// 1. Incandescent heated nozzle glow ring at z in [6.12, 6.35]
/// 2. White-hot solar inner flame cone tapering from z = 6.25 to z = 8.80
/// 3. Radiant electric cyan/blue outer supersonic plasma sheath extending to z = 9.60
/// 4. 4 standing Mach disk supersonic shock diamonds along the exhaust centerline
/// 5. 4 radial supersonic plasma stabilizer fins radiating outward for high-G afterburner bloom
pub fn buildAfterburnerPlume(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const white_hot = Vec3.init(2.8, 2.8, 2.4); // hyper-bright solar core flame
    const amber_core = Vec3.init(3.2, 2.2, 0.7); // inner combustion glow
    const electric_cyan = Vec3.init(0.5, 3.2, 5.0); // supersonic plasma sheath
    const deep_blue = Vec3.init(0.3, 1.4, 4.0); // plume perimeter
    const mach_diamond_col = Vec3.init(3.4, 3.4, 2.8); // Mach disk standing shock

    // 1. Heated nozzle collar glow ring
    const ring_pts = 8;
    const nozzle_z0: f32 = 6.12;
    const nozzle_z1: f32 = 6.35;
    const r_collar: f32 = 0.40;
    var n_ring0: [ring_pts]Vec3 = undefined;
    var n_ring1: [ring_pts]Vec3 = undefined;
    for (0..ring_pts) |k| {
        const theta = @as(f32, @floatFromInt(k)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(ring_pts)));
        n_ring0[k] = Vec3.init(@cos(theta) * r_collar, @sin(theta) * r_collar, nozzle_z0);
        n_ring1[k] = Vec3.init(@cos(theta) * (r_collar * 1.15), @sin(theta) * (r_collar * 1.15), nozzle_z1);
    }
    for (0..ring_pts) |k| {
        const k2 = (k + 1) % ring_pts;
        try b.quad(n_ring0[k], n_ring0[k2], n_ring1[k2], n_ring1[k], white_hot, Vec3.init(0, 0, (nozzle_z0 + nozzle_z1) * 0.5));
    }

    // 2. White-hot inner core flame cone (from z = 6.25 to z = 8.80)
    const core_steps = [_][3]f32{
        .{ 6.25, 0.32, 0.0 },
        .{ 6.90, 0.28, 0.0 },
        .{ 7.60, 0.20, 0.0 },
        .{ 8.30, 0.11, 0.0 },
        .{ 8.80, 0.02, 0.0 },
    };
    var core_rings: [core_steps.len][6]Vec3 = undefined;
    for (core_steps, 0..) |cs, i| {
        core_rings[i] = Builder.ring(cs[0], cs[1], cs[1], cs[2]);
    }
    for (0..core_steps.len - 1) |i| {
        const col = if (i % 2 == 0) white_hot else amber_core;
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            try b.quad(core_rings[i][k], core_rings[i][k2], core_rings[i + 1][k2], core_rings[i + 1][k], col, Vec3.init(0, 0, (core_steps[i][0] + core_steps[i + 1][0]) * 0.5));
        }
    }
    // Cap inner flame cone tip
    const core_tip = Vec3.init(0, 0, 9.0);
    const last_core = core_rings[core_steps.len - 1];
    for (0..6) |k| {
        try b.tri(last_core[k], last_core[(k + 1) % 6], core_tip, amber_core, Vec3.init(0, 0, 8.80));
    }

    // 3. Outer radiant electric cyan plasma sheath (from z = 6.15 to z = 9.60)
    const sheath_steps = [_][3]f32{
        .{ 6.15, 0.38, 0.0 },
        .{ 6.80, 0.44, 0.0 },
        .{ 7.70, 0.35, 0.0 },
        .{ 8.70, 0.22, 0.0 },
        .{ 9.60, 0.04, 0.0 },
    };
    var sheath_rings: [sheath_steps.len][6]Vec3 = undefined;
    for (sheath_steps, 0..) |ss, i| {
        sheath_rings[i] = Builder.ring(ss[0], ss[1], ss[1], ss[2]);
    }
    for (0..sheath_steps.len - 1) |i| {
        const col = if (i % 2 == 0) electric_cyan else deep_blue;
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            try b.quad(sheath_rings[i][k], sheath_rings[i][k2], sheath_rings[i + 1][k2], sheath_rings[i + 1][k], col, Vec3.init(0, 0, (sheath_steps[i][0] + sheath_steps[i + 1][0]) * 0.5));
        }
    }
    const sheath_tip = Vec3.init(0, 0, 9.8);
    const last_sheath = sheath_rings[sheath_steps.len - 1];
    for (0..6) |k| {
        try b.tri(last_sheath[k], last_sheath[(k + 1) % 6], sheath_tip, deep_blue, Vec3.init(0, 0, 9.60));
    }

    // 4. Supersonic Mach disk shock diamonds (4 standing biconical shock wave diamonds)
    const mach_centers = [_]f32{ 6.8, 7.5, 8.2, 8.9 };
    for (mach_centers, 0..) |mz, mi| {
        const m_len: f32 = 0.28 - @as(f32, @floatFromInt(mi)) * 0.035;
        const m_rad: f32 = 0.16 - @as(f32, @floatFromInt(mi)) * 0.020;
        const front_tip = Vec3.init(0, 0, mz - m_len);
        const rear_tip = Vec3.init(0, 0, mz + m_len);
        const mid_ring = Builder.ring(mz, m_rad, m_rad, 0.0);

        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            try b.tri(mid_ring[k], mid_ring[k2], front_tip, mach_diamond_col, Vec3.init(0, 0, mz));
            try b.tri(mid_ring[k2], mid_ring[k], rear_tip, mach_diamond_col, Vec3.init(0, 0, mz));
        }
    }

    // 5. 4 radial supersonic plasma petals / fins radiating outward for high-intensity glow
    inline for (.{ @as(f32, 1.0), @as(f32, -1.0) }) |s_dir| {
        // Horizontal flame fins (X axis)
        const fin_x = [4]Vec3{
            Vec3.init(s_dir * 0.30, 0.0, 6.20),
            Vec3.init(s_dir * 0.46, 0.0, 6.80),
            Vec3.init(s_dir * 0.36, 0.0, 7.80),
            Vec3.init(s_dir * 0.16, 0.0, 8.60),
        };
        try b.slab(fin_x, Vec3.init(0, 0.025, 0), electric_cyan);

        // Vertical flame fins (Y axis)
        const fin_y = [4]Vec3{
            Vec3.init(0.0, s_dir * 0.30, 6.20),
            Vec3.init(0.0, s_dir * 0.46, 6.80),
            Vec3.init(0.0, s_dir * 0.36, 7.80),
            Vec3.init(0.0, s_dir * 0.16, 8.60),
        };
        try b.slab(fin_y, Vec3.init(0.025, 0, 0), electric_cyan);
    }

    return b;
}

/// Unit box: x,z in [-0.5,0.5], y in [0,1].
pub fn buildBox(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const c = Vec3.init(1, 1, 1);
    const ctr = Vec3.init(0, 0.5, 0);
    const p = [8]Vec3{
        Vec3.init(-0.5, 0, -0.5), Vec3.init(0.5, 0, -0.5), Vec3.init(0.5, 0, 0.5), Vec3.init(-0.5, 0, 0.5),
        Vec3.init(-0.5, 1, -0.5), Vec3.init(0.5, 1, -0.5), Vec3.init(0.5, 1, 0.5), Vec3.init(-0.5, 1, 0.5),
    };
    try b.quad(p[4], p[5], p[6], p[7], c, ctr); // top
    try b.quad(p[0], p[1], p[5], p[4], c, ctr);
    try b.quad(p[1], p[2], p[6], p[5], c, ctr);
    try b.quad(p[2], p[3], p[7], p[6], c, ctr);
    try b.quad(p[3], p[0], p[4], p[7], c, ctr);
    return b;
}

/// Flat checkered ground patch centered on origin, y = 0.
pub fn buildGround(alloc: std.mem.Allocator, cells: u32, size: f32) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const ca = srgb(92, 140, 72);
    const cb = srgb(80, 124, 62);
    const half = @as(f32, @floatFromInt(cells)) * size * 0.5;
    var iz: u32 = 0;
    while (iz < cells) : (iz += 1) {
        var ix: u32 = 0;
        while (ix < cells) : (ix += 1) {
            const x0 = @as(f32, @floatFromInt(ix)) * size - half;
            const z0 = @as(f32, @floatFromInt(iz)) * size - half;
            const col = if ((ix + iz) % 2 == 0) ca else cb;
            const below = Vec3.init(x0, -1, z0);
            try b.quad(
                Vec3.init(x0, 0, z0),
                Vec3.init(x0 + size, 0, z0),
                Vec3.init(x0 + size, 0, z0 + size),
                Vec3.init(x0, 0, z0 + size),
                col,
                below,
            );
        }
    }
    return b;
}

/// Stylized 3D pointer indicator arrow oriented along -Z (arrowhead tip at -Z, stem at +Z).
/// Stylized 3D pointer indicator arrow oriented along -Z (arrowhead tip at -Z).
/// Sleek triangular delta-chevron geometry reminiscent of classic vector arcade terminals,
/// sculpted with modern aerospace stealth facets, sharp leading edges, and swept trailing notch.
/// Tinted by instance color (pure red for enemy, pure green for friendly).
pub fn buildPointerArrow(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick: f32 = 0.080;

    // Apex nose pointing forward along -Z:
    const apex_t = Vec3.init(0, thick, -1.25);
    const apex_b = Vec3.init(0, -thick, -1.25);

    // Left and right swept wingtips (sharp outer points):
    const left_m = Vec3.init(-0.65, 0, 0.38);
    const right_m = Vec3.init(0.65, 0, 0.38);

    // Inner crotch swept trailing notch:
    const notch_t = Vec3.init(0, thick * 0.75, -0.05);
    const notch_b = Vec3.init(0, -thick * 0.75, -0.05);

    // Mid-spine ridge point for elevated central dorsal ridge:
    const spine_t = Vec3.init(0, thick * 1.45, -0.42);
    const spine_b = Vec3.init(0, -thick * 1.45, -0.42);

    const inside = Vec3.init(0, 0, -0.25);

    // Upper faceted aerodynamic shell:
    try b.tri(apex_t, left_m, spine_t, white, inside);
    try b.tri(apex_t, spine_t, right_m, white, inside);
    try b.tri(spine_t, left_m, notch_t, white, inside);
    try b.tri(spine_t, notch_t, right_m, white, inside);

    // Lower faceted aerodynamic shell:
    try b.tri(apex_b, spine_b, left_m, white, inside);
    try b.tri(apex_b, right_m, spine_b, white, inside);
    try b.tri(spine_b, notch_b, left_m, white, inside);
    try b.tri(spine_b, right_m, notch_b, white, inside);

    // Leading edge knife-edge closure:
    try b.tri(apex_t, apex_b, left_m, white, inside);
    try b.tri(apex_t, right_m, apex_b, white, inside);

    // Trailing edge notch closure:
    try b.tri(left_m, notch_b, notch_t, white, inside);
    try b.tri(right_m, notch_t, notch_b, white, inside);

    // Center spine bridge:
    try b.quad(apex_t, spine_t, spine_b, apex_b, white, inside);
    try b.quad(spine_t, notch_t, notch_b, spine_b, white, inside);

    // Inner glowing vector core / accent spine:
    const core_thick = Vec3.init(0, 0.030, 0);
    const core_stem = [4]Vec3{
        Vec3.init(-0.065, thick * 0.95, -1.05),
        Vec3.init(0.065, thick * 0.95, -1.05),
        Vec3.init(0.065, thick * 0.95, 0.05),
        Vec3.init(-0.065, thick * 0.95, 0.05),
    };
    try b.slab(core_stem, core_thick, white.scale(1.35));

    return b;
}

/// Pointer indicator arrow with an illuminated transverse horizon bar indicating target is beyond visual horizon.
pub fn buildPointerArrowHorizon(alloc: std.mem.Allocator) !Builder {
    var b = try buildPointerArrow(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    // Transverse planetary horizon crossbar:
    const bar_quad = [4]Vec3{
        Vec3.init(-1.10, 0.08, -0.25),
        Vec3.init(1.10, 0.08, -0.25),
        Vec3.init(1.10, 0.08, -0.05),
        Vec3.init(-1.10, 0.08, -0.05),
    };
    try b.slab(bar_quad, Vec3.init(0, 0.04, 0), white.scale(1.4));
    return b;
}

/// Antipodal pointer arrow featuring a wireframe planetary globe orb at center, indicating target is on the other side of the planet.
pub fn buildPointerArrowFarSide(alloc: std.mem.Allocator) !Builder {
    var b = try buildPointerArrow(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    // Antipodal central planetary orb (representing the planet intervening between aircraft and contact)
    const orb_r: f32 = 0.32;
    const orb_c = Vec3.init(0, 0.10, -0.35);
    const steps = 10;
    for (0..steps) |si| {
        const a1 = @as(f32, @floatFromInt(si)) * (std.math.pi * 2.0 / @as(f32, steps));
        const a2 = @as(f32, @floatFromInt(si + 1)) * (std.math.pi * 2.0 / @as(f32, steps));
        // Equatorial ring
        const p1 = orb_c.add(Vec3.init(@cos(a1) * orb_r, 0, @sin(a1) * orb_r));
        const p2 = orb_c.add(Vec3.init(@cos(a2) * orb_r, 0, @sin(a2) * orb_r));
        try addStroke(&b, p1, p2, 0.040, Vec3.init(0, 0.030, 0), white.scale(1.5));
        // Meridian ring
        const m1 = orb_c.add(Vec3.init(@cos(a1) * orb_r, @sin(a1) * orb_r, 0));
        const m2 = orb_c.add(Vec3.init(@cos(a2) * orb_r, @sin(a2) * orb_r, 0));
        try addStroke(&b, m1, m2, 0.040, Vec3.init(0, 0.030, 0), white.scale(1.5));
    }
    return b;
}

/// Concentric tactical HUD teal targeting ring with angle markers (0°, 30°, 60°, 90°, etc.),
/// top inverted pitch caret, horizontal bank index wings, and roll index ticks.
pub fn buildTealAngleCircle(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const teal = Vec3.init(0.18, 3.2, 3.6); // Glowing futuristic teal
    const thick = Vec3.init(0, 0, 0.008);
    const sw: f32 = 0.0042;
    const r: f32 = 0.35;

    // 1. Circular ring with 48 segments and subtle tactical gaps at 0°, 90°, 180°, 270°
    const num_segs: usize = 48;
    for (0..num_segs) |i| {
        if (i == 0 or i == 12 or i == 24 or i == 36) continue;
        const a0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(num_segs)));
        const a1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(num_segs)));
        const p0 = Vec3.init(r * @sin(a0), r * @cos(a0), 0);
        const p1 = Vec3.init(r * @sin(a1), r * @cos(a1), 0);
        try addStroke(&b, p0, p1, sw, thick, teal);
    }

    // 2. Angle markers (every 30° major ticks, every 15° minor ticks)
    for (0..24) |ti| {
        const angle = @as(f32, @floatFromInt(ti)) * (std.math.pi / 12.0); // 15° steps
        const is_major = (ti % 2 == 0); // 30° steps
        const tick_len: f32 = if (is_major) 0.038 else 0.018;
        const tick_sw: f32 = if (is_major) 0.0045 else 0.0032;

        const sa = @sin(angle);
        const ca = @cos(angle);
        const p_in = Vec3.init(r * sa, r * ca, 0);
        const p_out = Vec3.init((r + tick_len) * sa, (r + tick_len) * ca, 0);
        try addStroke(&b, p_in, p_out, tick_sw, thick, teal);
    }

    // 3. Top apex marker (0° / 12 o'clock): Tactical inverted triangle caret ▽
    const caret_tip = Vec3.init(0, r + 0.004, 0);
    const caret_l = Vec3.init(-0.022, r + 0.038, 0);
    const caret_r = Vec3.init(0.022, r + 0.038, 0);
    try addStroke(&b, caret_tip, caret_l, 0.0045, thick, teal);
    try addStroke(&b, caret_l, caret_r, 0.0045, thick, teal);
    try addStroke(&b, caret_r, caret_tip, 0.0045, thick, teal);

    // 4. Horizontal Horizon Reference Wings at 90° (+X) and 270° (-X)
    // Right wing (+X)
    const rw_start = Vec3.init(r + 0.008, 0, 0);
    const rw_end = Vec3.init(r + 0.075, 0, 0);
    const rw_down = Vec3.init(r + 0.075, -0.025, 0);
    try addStroke(&b, rw_start, rw_end, 0.0055, thick, teal);
    try addStroke(&b, rw_end, rw_down, 0.0055, thick, teal);

    // Left wing (-X)
    const lw_start = Vec3.init(-(r + 0.008), 0, 0);
    const lw_end = Vec3.init(-(r + 0.075), 0, 0);
    const lw_down = Vec3.init(-(r + 0.075), -0.025, 0);
    try addStroke(&b, lw_start, lw_end, 0.0055, thick, teal);
    try addStroke(&b, lw_end, lw_down, 0.0055, thick, teal);

    // 5. Roll angle index markers at ±10°, ±20°, ±45°, ±60°
    const roll_angles = [_]f32{ 10.0, 20.0, 45.0, 60.0, -10.0, -20.0, -45.0, -60.0 };
    for (roll_angles) |deg| {
        const rad = deg * (std.math.pi / 180.0);
        const sa = @sin(rad);
        const ca = @cos(rad);
        const pip_pos = Vec3.init((r - 0.016) * sa, (r - 0.016) * ca, 0);
        const pip_out = Vec3.init((r - 0.002) * sa, (r - 0.002) * ca, 0);
        try addStroke(&b, pip_pos, pip_out, 0.0040, thick, teal);
    }

    return b;
}

/// Modern fighter HUD crosshair: central aim dot + 4 cardinal reticle ticks.
pub fn buildCrosshair(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.02);

    // Center aim dot
    const dot = [4]Vec3{
        Vec3.init(-0.025, -0.025, 0),
        Vec3.init(0.025, -0.025, 0),
        Vec3.init(0.025, 0.025, 0),
        Vec3.init(-0.025, 0.025, 0),
    };
    try b.slab(dot, thick, white);

    // Cardinal reticle tick bars: top, bottom, left, right
    const top_tick = [4]Vec3{
        Vec3.init(-0.015, 0.09, 0),
        Vec3.init(0.015, 0.09, 0),
        Vec3.init(0.015, 0.22, 0),
        Vec3.init(-0.015, 0.22, 0),
    };
    try b.slab(top_tick, thick, white);

    const bot_tick = [4]Vec3{
        Vec3.init(-0.015, -0.22, 0),
        Vec3.init(0.015, -0.22, 0),
        Vec3.init(0.015, -0.09, 0),
        Vec3.init(-0.015, -0.09, 0),
    };
    try b.slab(bot_tick, thick, white);

    const left_tick = [4]Vec3{
        Vec3.init(-0.22, -0.015, 0),
        Vec3.init(-0.09, -0.015, 0),
        Vec3.init(-0.09, 0.015, 0),
        Vec3.init(-0.22, 0.015, 0),
    };
    try b.slab(left_tick, thick, white);

    const right_tick = [4]Vec3{
        Vec3.init(0.09, -0.015, 0),
        Vec3.init(0.22, -0.015, 0),
        Vec3.init(0.22, 0.015, 0),
        Vec3.init(0.09, 0.015, 0),
    };
    try b.slab(right_tick, thick, white);

    return b;
}

/// Dynamic target lock brackets: 4 corner L-brackets framing the locked target or lead pip.
pub fn buildTargetReticle(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.02);
    const s: f32 = 0.35;
    const l: f32 = 0.12;
    const w: f32 = 0.025;

    // 4 corner L-brackets: (Top-Left, Top-Right, Bottom-Left, Bottom-Right)
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            // Horizontal bar of corner
            const h_bar = [4]Vec3{
                Vec3.init(sx * s, sy * s - w * sy, 0),
                Vec3.init(sx * (s - l), sy * s - w * sy, 0),
                Vec3.init(sx * (s - l), sy * s, 0),
                Vec3.init(sx * s, sy * s, 0),
            };
            try b.slab(h_bar, thick, white);

            // Vertical bar of corner
            const v_bar = [4]Vec3{
                Vec3.init(sx * s - w * sx, sy * (s - l), 0),
                Vec3.init(sx * s, sy * (s - l), 0),
                Vec3.init(sx * s, sy * s, 0),
                Vec3.init(sx * s - w * sx, sy * s, 0),
            };
            try b.slab(v_bar, thick, white);
        }
    }

    return b;
}

/// Hollow diamond target beacon in XY plane (nose toward -Z) for long-range aircraft framing.
pub fn buildTargetDiamond(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.02);
    const r: f32 = 0.42;
    const w: f32 = 0.045;

    const pts = [4]Vec3{
        Vec3.init(0, r, 0),
        Vec3.init(r, 0, 0),
        Vec3.init(0, -r, 0),
        Vec3.init(-r, 0, 0),
    };
    inline for (0..4) |i| {
        const j = (i + 1) % 4;
        const p1 = pts[i];
        const p2 = pts[j];
        const edge = p2.sub(p1);
        const norm = Vec3.init(-edge.y, edge.x, 0).norm().scale(w);
        const quad_pts = [4]Vec3{
            p1,
            p2,
            p2.add(norm),
            p1.add(norm),
        };
        try b.slab(quad_pts, thick, white);
    }
    return b;
}

/// Screen-space tactical target framing box for high-visibility acquisition.
/// Features 4 sharp L-bracket corners and a central diamond pip.
pub fn buildTargetFramingBox(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.006);
    const s: f32 = 0.038; // 38 mm box half-width
    const l: f32 = 0.014; // corner arm length
    const w: f32 = 0.0035; // line stroke width

    // 4 corner L-brackets
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const p_corner = Vec3.init(sx * s, sy * s, 0);
            const p_h = Vec3.init(sx * (s - l), sy * s, 0);
            const p_v = Vec3.init(sx * s, sy * (s - l), 0);
            try addStroke(&b, p_corner, p_h, w, thick, white);
            try addStroke(&b, p_corner, p_v, w, thick, white);
        }
    }

    // Central small diamond pip
    const d: f32 = 0.007;
    const pts = [4]Vec3{
        Vec3.init(0, d, 0),
        Vec3.init(d, 0, 0),
        Vec3.init(0, -d, 0),
        Vec3.init(-d, 0, 0),
    };
    inline for (0..4) |i| {
        const j = (i + 1) % 4;
        try addStroke(&b, pts[i], pts[j], 0.0022, thick, white);
    }

    return b;
}

/// 360° Circular Plan-Position Indicator (PPI) Tactical Radar Scope Frame.
pub fn buildTacticalRadarFrame(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const cyan = Vec3.init(0.25, 3.2, 3.8); // Glowing HUD cyan
    const bg_color = Vec3.init(0.012, 0.018, 0.026); // Smoked circular glass
    const thick = Vec3.init(0, 0, 0.008);
    const r: f32 = 0.160; // 16 cm radius (32 cm diameter) on HUD

    // 1. Smoked glass circular backplate
    const num_disc = 36;
    for (0..num_disc) |i| {
        const a0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, num_disc));
        const a1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / @as(f32, num_disc));
        const p0 = Vec3.init(r * @sin(a0), r * @cos(a0), -0.004);
        const p1 = Vec3.init(r * @sin(a1), r * @cos(a1), -0.004);
        try b.tri(Vec3.init(0, 0, -0.004), p0, p1, bg_color, Vec3.zero);
    }

    // 2. Outer circular boundary ring
    for (0..num_disc) |i| {
        const a0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, num_disc));
        const a1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / @as(f32, num_disc));
        const p0 = Vec3.init(r * @sin(a0), r * @cos(a0), 0.002);
        const p1 = Vec3.init(r * @sin(a1), r * @cos(a1), 0.002);
        try addStroke(&b, p0, p1, 0.0042, thick, cyan);
    }

    // 3. Inner Range Ring (50% radius = 10 km range)
    const r_inner = r * 0.50;
    for (0..28) |i| {
        if (i % 2 == 1) continue;
        const a0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 28.0);
        const a1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / 28.0);
        const p0 = Vec3.init(r_inner * @sin(a0), r_inner * @cos(a0), 0.002);
        const p1 = Vec3.init(r_inner * @sin(a1), r_inner * @cos(a1), 0.002);
        try addStroke(&b, p0, p1, 0.0030, thick, Vec3.init(0.20, 2.2, 2.8));
    }

    // 4. Subtle Crosshairs (Forward, Aft, Port, Starboard)
    try addStroke(&b, Vec3.init(-r * 0.95, 0, 0.002), Vec3.init(-r * 0.15, 0, 0.002), 0.0025, thick, Vec3.init(0.18, 1.8, 2.2));
    try addStroke(&b, Vec3.init(r * 0.15, 0, 0.002), Vec3.init(r * 0.95, 0, 0.002), 0.0025, thick, Vec3.init(0.18, 1.8, 2.2));
    try addStroke(&b, Vec3.init(0, -r * 0.95, 0.002), Vec3.init(0, -r * 0.15, 0.002), 0.0025, thick, Vec3.init(0.18, 1.8, 2.2));
    try addStroke(&b, Vec3.init(0, r * 0.15, 0.002), Vec3.init(0, r * 0.95, 0.002), 0.0025, thick, Vec3.init(0.18, 1.8, 2.2));

    // 5. Center Ownship Icon (white delta aircraft silhouette pointing forward)
    const own_tip = Vec3.init(0, 0.016, 0.004);
    const own_l = Vec3.init(-0.011, -0.011, 0.004);
    const own_r = Vec3.init(0.011, -0.011, 0.004);
    const own_c = Vec3.init(0, -0.005, 0.004);
    const white = Vec3.init(1.0, 1.0, 1.0);
    try addStroke(&b, own_tip, own_l, 0.0032, thick, white);
    try addStroke(&b, own_l, own_c, 0.0025, thick, white);
    try addStroke(&b, own_c, own_r, 0.0025, thick, white);
    try addStroke(&b, own_r, own_tip, 0.0032, thick, white);

    // 6. Header Badge Text "RADAR // 20KM"
    const radar_hdr = "RADAR 20KM";
    const hdr_h: f32 = 0.024;
    const hdr_w = measureText(radar_hdr, hdr_h);
    try addText(&b, radar_hdr, Vec3.init(-hdr_w * 0.5, r + 0.012, 0.004), hdr_h * 0.75, hdr_h, 0.003, Vec3.init(0.8, 3.8, 4.2));

    return b;
}

/// Downward-pointing threat chevron on compass tape.
pub fn buildCompassThreatMarker(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.006);
    const w: f32 = 0.012;
    const h: f32 = 0.016;
    const p_tip = Vec3.init(0, -0.004, 0);
    const p_l = Vec3.init(-w, h, 0);
    const p_r = Vec3.init(w, h, 0);
    const p_c = Vec3.init(0, h * 0.40, 0);
    try addStroke(&b, p_tip, p_l, 0.0035, thick, white);
    try addStroke(&b, p_l, p_c, 0.0028, thick, white);
    try addStroke(&b, p_c, p_r, 0.0028, thick, white);
    try addStroke(&b, p_r, p_tip, 0.0035, thick, white);
    return b;
}

/// Bold threat director chevron arrow that appears near the center gunsight
/// pointing toward off-screen or nearest hostiles.
pub fn buildThreatDirectorArrow(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.008);
    // Double chevron pointing in +Y direction
    const tip1 = Vec3.init(0, 0.036, 0);
    const l1 = Vec3.init(-0.024, 0.010, 0);
    const r1 = Vec3.init(0.024, 0.010, 0);
    const c1 = Vec3.init(0, 0.018, 0);
    try addStroke(&b, tip1, l1, 0.0045, thick, white);
    try addStroke(&b, l1, c1, 0.0035, thick, white);
    try addStroke(&b, c1, r1, 0.0035, thick, white);
    try addStroke(&b, r1, tip1, 0.0045, thick, white);

    const tip2 = Vec3.init(0, 0.016, 0);
    const l2 = Vec3.init(-0.020, -0.008, 0);
    const r2 = Vec3.init(0.020, -0.008, 0);
    const c2 = Vec3.init(0, -0.001, 0);
    try addStroke(&b, tip2, l2, 0.0040, thick, white);
    try addStroke(&b, l2, c2, 0.0032, thick, white);
    try addStroke(&b, c2, r2, 0.0032, thick, white);
    try addStroke(&b, r2, tip2, 0.0040, thick, white);

    return b;
}

/// Stylized 3D "T" text icon glyph enclosed in a HUD bracket badge.
pub fn buildIconT(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const white = Vec3.init(1.0, 1.0, 1.0);
    const thick = Vec3.init(0, 0, 0.02);

    // 0. Dark smoked glass backing plate
    const bg_color = Vec3.init(0.035, 0.05, 0.08);
    const bg_quad = [4]Vec3{
        Vec3.init(-0.45, -0.45, -0.008),
        Vec3.init(0.45, -0.45, -0.008),
        Vec3.init(0.45, 0.45, -0.008),
        Vec3.init(-0.45, 0.45, -0.008),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 1. Horizontal crossbar of 'T'
    const top_bar = [4]Vec3{
        Vec3.init(-0.24, 0.14, 0),
        Vec3.init(0.24, 0.14, 0),
        Vec3.init(0.24, 0.26, 0),
        Vec3.init(-0.24, 0.26, 0),
    };
    try b.slab(top_bar, thick, white);

    // 2. Vertical stem of 'T'
    const stem = [4]Vec3{
        Vec3.init(-0.06, -0.26, 0),
        Vec3.init(0.06, -0.26, 0),
        Vec3.init(0.06, 0.14, 0),
        Vec3.init(-0.06, 0.14, 0),
    };
    try b.slab(stem, thick, white);

    // 3. Surrounding corner bracket frame
    const s: f32 = 0.38;
    const l: f32 = 0.12;
    const w: f32 = 0.03;

    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            // Horizontal bar of corner
            const h_bar = [4]Vec3{
                Vec3.init(sx * s, sy * s - w * sy, 0),
                Vec3.init(sx * (s - l), sy * s - w * sy, 0),
                Vec3.init(sx * (s - l), sy * s, 0),
                Vec3.init(sx * s, sy * s, 0),
            };
            try b.slab(h_bar, thick, white);

            // Vertical bar of corner
            const v_bar = [4]Vec3{
                Vec3.init(sx * s - w * sx, sy * (s - l), 0),
                Vec3.init(sx * s, sy * (s - l), 0),
                Vec3.init(sx * s, sy * s, 0),
                Vec3.init(sx * s - w * sx, sy * s, 0),
            };
            try b.slab(v_bar, thick, white);
        }
    }

    return b;
}

/// 3x5 vector bitmask font table for alphanumeric text and tactical HUD badges.
pub fn getGlyph(ch: u8) [5]u3 {
    const c = std.ascii.toUpper(ch);
    return switch (c) {
        '0' => .{ 7, 5, 5, 5, 7 },
        '1' => .{ 2, 6, 2, 2, 7 },
        '2' => .{ 7, 1, 7, 4, 7 },
        '3' => .{ 7, 1, 7, 1, 7 },
        '4' => .{ 5, 5, 7, 1, 1 },
        '5' => .{ 7, 4, 7, 1, 7 },
        '6' => .{ 7, 4, 7, 5, 7 },
        '7' => .{ 7, 1, 2, 2, 2 },
        '8' => .{ 7, 5, 7, 5, 7 },
        '9' => .{ 7, 5, 7, 1, 7 },
        'A' => .{ 7, 5, 7, 5, 5 },
        'B' => .{ 7, 5, 7, 5, 7 },
        'C' => .{ 7, 4, 4, 4, 7 },
        'D' => .{ 6, 5, 5, 5, 6 },
        'E' => .{ 7, 4, 7, 4, 7 },
        'F' => .{ 7, 4, 7, 4, 4 },
        'G' => .{ 7, 4, 5, 5, 7 },
        'H' => .{ 5, 5, 7, 5, 5 },
        'I' => .{ 7, 2, 2, 2, 7 },
        'J' => .{ 1, 1, 1, 5, 7 },
        'K' => .{ 5, 5, 6, 5, 5 },
        'L' => .{ 4, 4, 4, 4, 7 },
        'M' => .{ 5, 7, 5, 5, 5 },
        'N' => .{ 5, 7, 7, 5, 5 },
        'O' => .{ 7, 5, 5, 5, 7 },
        'P' => .{ 7, 5, 7, 4, 4 },
        'Q' => .{ 7, 5, 5, 7, 1 },
        'R' => .{ 7, 5, 7, 6, 5 },
        'S' => .{ 7, 4, 7, 1, 7 },
        'T' => .{ 7, 2, 2, 2, 2 },
        'U' => .{ 5, 5, 5, 5, 7 },
        'V' => .{ 5, 5, 5, 5, 2 },
        'W' => .{ 5, 5, 5, 7, 5 },
        'X' => .{ 5, 5, 2, 5, 5 },
        'Y' => .{ 5, 5, 2, 2, 2 },
        'Z' => .{ 7, 1, 2, 4, 7 },
        '[' => .{ 6, 4, 4, 4, 6 },
        ']' => .{ 3, 1, 1, 1, 3 },
        ':' => .{ 0, 2, 0, 2, 0 },
        '-' => .{ 0, 0, 7, 0, 0 },
        '+' => .{ 0, 2, 7, 2, 0 },
        '/' => .{ 1, 1, 2, 4, 4 },
        else => .{ 0, 0, 0, 0, 0 },
    };
}

pub const Stroke = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

// 16-Segment Alphanumeric Digital Clock Segment Stroke Definitions
// Clean rectilinear & chamfered segments ensuring zero ambiguity and pristine legibility
const sA1 = Stroke{ .u0 = 0.10, .v0 = 0.96, .u1 = 0.50, .v1 = 0.96 };
const sA2 = Stroke{ .u0 = 0.50, .v0 = 0.96, .u1 = 0.90, .v1 = 0.96 };
const sA  = Stroke{ .u0 = 0.10, .v0 = 0.96, .u1 = 0.90, .v1 = 0.96 };
const sB  = Stroke{ .u0 = 0.90, .v0 = 0.54, .u1 = 0.90, .v1 = 0.92 };
const sC  = Stroke{ .u0 = 0.90, .v0 = 0.08, .u1 = 0.90, .v1 = 0.46 };
const sD1 = Stroke{ .u0 = 0.10, .v0 = 0.04, .u1 = 0.50, .v1 = 0.04 };
const sD2 = Stroke{ .u0 = 0.50, .v0 = 0.04, .u1 = 0.90, .v1 = 0.04 };
const sD  = Stroke{ .u0 = 0.10, .v0 = 0.04, .u1 = 0.90, .v1 = 0.04 };
const sE  = Stroke{ .u0 = 0.10, .v0 = 0.08, .u1 = 0.10, .v1 = 0.46 };
const sF  = Stroke{ .u0 = 0.10, .v0 = 0.54, .u1 = 0.10, .v1 = 0.92 };
const sG1 = Stroke{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.50, .v1 = 0.50 };
const sG2 = Stroke{ .u0 = 0.50, .v0 = 0.50, .u1 = 0.90, .v1 = 0.50 };
const sG  = Stroke{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.90, .v1 = 0.50 };
const sH  = Stroke{ .u0 = 0.50, .v0 = 0.54, .u1 = 0.50, .v1 = 0.92 };
const sI  = Stroke{ .u0 = 0.50, .v0 = 0.08, .u1 = 0.50, .v1 = 0.46 };

// Specialized diagonals for M, W, V, X, and chamfers
const sDiag1 = Stroke{ .u0 = 0.12, .v0 = 0.92, .u1 = 0.88, .v1 = 0.08 }; // \
const sDiag2 = Stroke{ .u0 = 0.12, .v0 = 0.08, .u1 = 0.88, .v1 = 0.92 }; // /
const sVeeL  = Stroke{ .u0 = 0.12, .v0 = 0.92, .u1 = 0.50, .v1 = 0.06 };
const sVeeR  = Stroke{ .u0 = 0.88, .v0 = 0.92, .u1 = 0.50, .v1 = 0.06 };
const sW1    = Stroke{ .u0 = 0.12, .v0 = 0.92, .u1 = 0.35, .v1 = 0.06 };
const sW2    = Stroke{ .u0 = 0.35, .v0 = 0.06, .u1 = 0.50, .v1 = 0.60 };
const sW3    = Stroke{ .u0 = 0.50, .v0 = 0.60, .u1 = 0.65, .v1 = 0.06 };
const sW4    = Stroke{ .u0 = 0.65, .v0 = 0.06, .u1 = 0.88, .v1 = 0.92 };
const sM1    = Stroke{ .u0 = 0.10, .v0 = 0.92, .u1 = 0.50, .v1 = 0.45 };
const sM2    = Stroke{ .u0 = 0.90, .v0 = 0.92, .u1 = 0.50, .v1 = 0.45 };

/// High-contrast clock-style segmented font glyph definition (7-seg digits & 14/16-seg alphanumeric).
pub fn getStrokeGlyph(ch: u8) []const Stroke {
    const c = std.ascii.toUpper(ch);
    return switch (c) {
        'A' => &[_]Stroke{ sE, sF, sA, sB, sC, sG },
        'B' => &[_]Stroke{
            sE, sF, sA1, sD1, sG1,
            .{ .u0 = 0.50, .v0 = 0.96, .u1 = 0.88, .v1 = 0.76 },
            .{ .u0 = 0.88, .v0 = 0.76, .u1 = 0.88, .v1 = 0.58 },
            .{ .u0 = 0.88, .v0 = 0.58, .u1 = 0.50, .v1 = 0.50 },
            .{ .u0 = 0.50, .v0 = 0.50, .u1 = 0.90, .v1 = 0.42 },
            .{ .u0 = 0.90, .v0 = 0.42, .u1 = 0.90, .v1 = 0.22 },
            .{ .u0 = 0.90, .v0 = 0.22, .u1 = 0.50, .v1 = 0.04 },
        },
        'C' => &[_]Stroke{ sA, sD, sE, sF },
        'D' => &[_]Stroke{
            sE, sF, sA1, sD1,
            .{ .u0 = 0.50, .v0 = 0.96, .u1 = 0.90, .v1 = 0.70 },
            .{ .u0 = 0.90, .v0 = 0.70, .u1 = 0.90, .v1 = 0.30 },
            .{ .u0 = 0.90, .v0 = 0.30, .u1 = 0.50, .v1 = 0.04 },
        },
        'E' => &[_]Stroke{ sA, sD, sE, sF, .{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.74, .v1 = 0.50 } },
        'F' => &[_]Stroke{ sA, sE, sF, .{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.70, .v1 = 0.50 } },
        'G' => &[_]Stroke{ sA, sD, sE, sF, sC, .{ .u0 = 0.50, .v0 = 0.50, .u1 = 0.90, .v1 = 0.50 } },
        'H' => &[_]Stroke{ sB, sC, sE, sF, sG },
        'I' => &[_]Stroke{
            .{ .u0 = 0.25, .v0 = 0.96, .u1 = 0.75, .v1 = 0.96 },
            .{ .u0 = 0.25, .v0 = 0.04, .u1 = 0.75, .v1 = 0.04 },
            sH, sI,
        },
        'J' => &[_]Stroke{ sB, sC, sD, sE },
        'K' => &[_]Stroke{
            sE, sF,
            .{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.86, .v1 = 0.92 },
            .{ .u0 = 0.10, .v0 = 0.50, .u1 = 0.86, .v1 = 0.08 },
        },
        'L' => &[_]Stroke{ sD, sE, sF },
        'M' => &[_]Stroke{ sE, sF, sB, sC, sM1, sM2 },
        'N' => &[_]Stroke{ sE, sF, sB, sC, .{ .u0 = 0.10, .v0 = 0.92, .u1 = 0.90, .v1 = 0.08 } },
        'O' => &[_]Stroke{ sA, sB, sC, sD, sE, sF },
        'P' => &[_]Stroke{
            sE, sF, sA1, sG1,
            .{ .u0 = 0.50, .v0 = 0.96, .u1 = 0.88, .v1 = 0.76 },
            .{ .u0 = 0.88, .v0 = 0.76, .u1 = 0.88, .v1 = 0.58 },
            .{ .u0 = 0.88, .v0 = 0.58, .u1 = 0.50, .v1 = 0.50 },
        },
        'Q' => &[_]Stroke{ sA, sB, sC, sD, sE, sF, .{ .u0 = 0.50, .v0 = 0.35, .u1 = 0.92, .v1 = -0.06 } },
        'R' => &[_]Stroke{
            sE, sF, sA1, sG1,
            .{ .u0 = 0.50, .v0 = 0.96, .u1 = 0.88, .v1 = 0.76 },
            .{ .u0 = 0.88, .v0 = 0.76, .u1 = 0.88, .v1 = 0.58 },
            .{ .u0 = 0.88, .v0 = 0.58, .u1 = 0.50, .v1 = 0.50 },
            .{ .u0 = 0.50, .v0 = 0.50, .u1 = 0.90, .v1 = 0.04 },
        },
        'S' => &[_]Stroke{ sA, sF, sG, sC, sD },
        'T' => &[_]Stroke{ sA, sH, sI },
        'U' => &[_]Stroke{ sB, sC, sD, sE, sF },
        'V' => &[_]Stroke{ sVeeL, sVeeR },
        'W' => &[_]Stroke{ sW1, sW2, sW3, sW4 },
        'X' => &[_]Stroke{ sDiag1, sDiag2 },
        'Y' => &[_]Stroke{
            .{ .u0 = 0.12, .v0 = 0.92, .u1 = 0.50, .v1 = 0.50 },
            .{ .u0 = 0.88, .v0 = 0.92, .u1 = 0.50, .v1 = 0.50 },
            sI,
        },
        'Z' => &[_]Stroke{ sA, sD, .{ .u0 = 0.88, .v0 = 0.92, .u1 = 0.12, .v1 = 0.08 } },

        // Textbook 7-segment digital clock digits
        '0' => &[_]Stroke{ sA, sB, sC, sD, sE, sF },
        '1' => &[_]Stroke{ sB, sC },
        '2' => &[_]Stroke{ sA, sB, sG, sE, sD },
        '3' => &[_]Stroke{ sA, sB, sG, sC, sD },
        '4' => &[_]Stroke{ sF, sG, sB, sC },
        '5' => &[_]Stroke{ sA, sF, sG, sC, sD },
        '6' => &[_]Stroke{ sA, sF, sE, sD, sC, sG },
        '7' => &[_]Stroke{ sA, sB, sC },
        '8' => &[_]Stroke{ sA, sB, sC, sD, sE, sF, sG },
        '9' => &[_]Stroke{ sA, sB, sC, sD, sF, sG },

        '+' => &[_]Stroke{
            .{ .u0 = 0.15, .v0 = 0.50, .u1 = 0.85, .v1 = 0.50 },
            .{ .u0 = 0.50, .v0 = 0.15, .u1 = 0.50, .v1 = 0.85 },
        },
        '-' => &[_]Stroke{
            .{ .u0 = 0.15, .v0 = 0.50, .u1 = 0.85, .v1 = 0.50 },
        },
        ':' => &[_]Stroke{
            .{ .u0 = 0.50, .v0 = 0.70, .u1 = 0.50, .v1 = 0.70 },
            .{ .u0 = 0.50, .v0 = 0.30, .u1 = 0.50, .v1 = 0.30 },
        },
        '/' => &[_]Stroke{ sDiag2 },
        '[' => &[_]Stroke{ sA1, sD1, sE, sF },
        ']' => &[_]Stroke{ sA2, sD2, sB, sC },
        '%' => &[_]Stroke{
            sDiag2,
            .{ .u0 = 0.28, .v0 = 0.75, .u1 = 0.28, .v1 = 0.75 },
            .{ .u0 = 0.72, .v0 = 0.25, .u1 = 0.72, .v1 = 0.25 },
        },
        '.' => &[_]Stroke{
            .{ .u0 = 0.50, .v0 = 0.08, .u1 = 0.50, .v1 = 0.08 },
        },
        ',' => &[_]Stroke{
            .{ .u0 = 0.50, .v0 = 0.12, .u1 = 0.38, .v1 = -0.08 },
        },
        else => &[_]Stroke{},
    };
}

/// Appends a crisp 2D line segment quad ribbon in the XY plane facing forward (+Z).
pub fn addStroke(b: *Builder, p0: Vec3, p1: Vec3, sw: f32, thick: Vec3, color: Vec3) !void {
    _ = thick;
    const dx = p1.x - p0.x;
    const dy = p1.y - p0.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-4) {
        // Digital clock square/rhombus dot segment
        const rad = sw * 0.55;
        const v0 = Vec3.init(p0.x - rad, p0.y - rad, p0.z);
        const v1 = Vec3.init(p0.x + rad, p0.y - rad, p0.z);
        const v2 = Vec3.init(p0.x + rad, p0.y + rad, p0.z);
        const v3 = Vec3.init(p0.x - rad, p0.y + rad, p0.z);
        try b.quad(v0, v1, v2, v3, color, Vec3.init(0, 0, -1.0));
        return;
    }
    const inv_len = 1.0 / len;
    const nx = -dy * inv_len * (sw * 0.5);
    const ny = dx * inv_len * (sw * 0.5);

    // Flat front-facing ribbon quad with uniform forward normal: razor sharp, zero edge-shading artifacts!
    const v0 = Vec3.init(p0.x + nx, p0.y + ny, p0.z);
    const v1 = Vec3.init(p1.x + nx, p1.y + ny, p1.z);
    const v2 = Vec3.init(p1.x - nx, p1.y - ny, p1.z);
    const v3 = Vec3.init(p0.x - nx, p0.y - ny, p0.z);
    try b.quad(v0, v1, v2, v3, color, Vec3.init(0, 0, -1.0));
}

/// Measures the total advance width of rendered TrueType font text at height `char_h`.
pub fn measureText(text: []const u8, char_h: f32) f32 {
    var total_w: f32 = 0.0;
    for (text) |ch| {
        if (ch == ' ') {
            total_w += 0.35 * char_h;
        } else {
            const g = font_data.getGlyph(ch);
            total_w += g.advance * char_h;
        }
    }
    return total_w;
}

/// Appends high-fidelity TrueType font vector quads into a mesh builder in the XY plane.
pub fn addText(b: *Builder, text: []const u8, origin: Vec3, char_w: f32, char_h: f32, char_spacing: f32, color: Vec3) !void {
    _ = char_w;
    _ = char_spacing;
    // Self-illuminated emissive boost so all text is 100% bright, crisp, and high-contrast
    const lum = @max(color.x, @max(color.y, color.z));
    const boosted_col = if (lum < 1.8) color.scale(2.5 / @max(0.1, lum)) else color;

    var cur_x = origin.x;
    for (text) |ch| {
        if (ch == ' ') {
            cur_x += 0.35 * char_h;
            continue;
        }
        const g = font_data.getGlyph(ch);
        for (g.spans) |s| {
            const p0 = Vec3.init(cur_x + s.x0 * char_h, origin.y + s.y0 * char_h, origin.z);
            const p1 = Vec3.init(cur_x + s.x1 * char_h, origin.y + s.y0 * char_h, origin.z);
            const p2 = Vec3.init(cur_x + s.x1 * char_h, origin.y + s.y1 * char_h, origin.z);
            const p3 = Vec3.init(cur_x + s.x0 * char_h, origin.y + s.y1 * char_h, origin.z);
            try b.quad(p0, p1, p2, p3, boosted_col, Vec3.init(0, 0, -1.0));
        }
        cur_x += g.advance * char_h;
    }
}

/// Builds a standalone centered 3D vector text mesh in the XY plane.
pub fn buildText(alloc: std.mem.Allocator, text: []const u8, char_w: f32, char_h: f32, char_spacing: f32, color: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const total_w = measureText(text, char_h);
    const origin = Vec3.init(-total_w * 0.5, -char_h * 0.5, 0.006);
    try addText(&b, text, origin, char_w, char_h, char_spacing, color);
    return b;
}

/// Builds a centered 3D vector text badge with dark smoked glass backing,
/// futuristic corner brackets, and crisp readable text.
pub fn buildBadgeWithBacking(
    alloc: std.mem.Allocator,
    text: []const u8,
    char_w: f32,
    char_h: f32,
    char_spacing: f32,
) !Builder {
    return buildBadgeWithBackingCustom(alloc, text, char_w, char_h, char_spacing, 0.045, 0.026);
}

pub fn buildBadgeWithBackingCustom(
    alloc: std.mem.Allocator,
    text: []const u8,
    char_w: f32,
    char_h: f32,
    char_spacing: f32,
    pad_x: f32,
    pad_y: f32,
) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const total_text_w = measureText(text, char_h);
    const hw = total_text_w * 0.5 + pad_x;
    const hh = char_h * 0.5 + pad_y;

    // 1. Dark smoked glass backing plate (100% contrast against sky/clouds/sun)
    const bg_color = Vec3.init(0.02, 0.025, 0.035);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Futuristic avionics corner brackets & frame lines
    const border_col = Vec3.init(0.85, 0.90, 1.0);
    const brk_l: f32 = 0.038;
    const brk_t: f32 = 0.009;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            // Horizontal bracket arm
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.005), border_col);

            // Vertical bracket arm
            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.005), border_col);
        }
    }

    // Top and bottom subtle accent lines
    const top_line = [4]Vec3{
        Vec3.init(-hw + brk_l + 0.008, hh - 0.0035, 0.002),
        Vec3.init(hw - brk_l - 0.008, hh - 0.0035, 0.002),
        Vec3.init(hw - brk_l - 0.008, hh, 0.002),
        Vec3.init(-hw + brk_l + 0.008, hh, 0.002),
    };
    try b.slab(top_line, Vec3.init(0, 0, 0.004), border_col.scale(0.55));
    const bot_line = [4]Vec3{
        Vec3.init(-hw + brk_l + 0.008, -hh, 0.002),
        Vec3.init(hw - brk_l - 0.008, -hh, 0.002),
        Vec3.init(hw - brk_l - 0.008, -hh + 0.0035, 0.002),
        Vec3.init(-hw + brk_l + 0.008, -hh + 0.0035, 0.002),
    };
    try b.slab(bot_line, Vec3.init(0, 0, 0.004), border_col.scale(0.55));

    // 3. Crisp text centered on top
    const text_origin = Vec3.init(-total_text_w * 0.5, -char_h * 0.5, 0.008);
    const text_col = Vec3.init(1.0, 1.0, 1.0);
    try addText(&b, text, text_origin, char_w, char_h, char_spacing, text_col);

    return b;
}

/// Builds an active doctrine ribbon banner with dark smoked glass backing,
/// left glowing indicator pill, top/bottom rails, and centered crisp text.
pub fn buildBannerWithBacking(
    alloc: std.mem.Allocator,
    text: []const u8,
    char_w: f32,
    char_h: f32,
    char_spacing: f32,
) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const total_text_w = measureText(text, char_h);
    const pad_x: f32 = 0.065;
    const pad_y: f32 = 0.022;
    const hw = total_text_w * 0.5 + pad_x;
    const hh = char_h * 0.5 + pad_y;

    // 1. Dark smoked glass backing plate
    const bg_color = Vec3.init(0.02, 0.025, 0.035);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Left glowing tactical status pill
    const rail_col = Vec3.init(0.9, 0.95, 1.0);
    const left_pill = [4]Vec3{
        Vec3.init(-hw + 0.012, -hh + 0.006, 0.002),
        Vec3.init(-hw + 0.028, -hh + 0.006, 0.002),
        Vec3.init(-hw + 0.028, hh - 0.006, 0.002),
        Vec3.init(-hw + 0.012, hh - 0.006, 0.002),
    };
    try b.slab(left_pill, Vec3.init(0, 0, 0.005), rail_col);

    // 3. Top and bottom glowing rails
    const top_rail = [4]Vec3{
        Vec3.init(-hw + 0.035, hh - 0.0035, 0.002),
        Vec3.init(hw - 0.012, hh - 0.0035, 0.002),
        Vec3.init(hw - 0.012, hh, 0.002),
        Vec3.init(-hw + 0.035, hh, 0.002),
    };
    try b.slab(top_rail, Vec3.init(0, 0, 0.004), rail_col.scale(0.65));

    const bot_rail = [4]Vec3{
        Vec3.init(-hw + 0.035, -hh, 0.002),
        Vec3.init(hw - 0.012, -hh, 0.002),
        Vec3.init(hw - 0.012, -hh + 0.0035, 0.002),
        Vec3.init(-hw + 0.035, -hh + 0.0035, 0.002),
    };
    try b.slab(bot_rail, Vec3.init(0, 0, 0.004), rail_col.scale(0.65));

    // 4. Centered text
    const text_origin = Vec3.init(-total_text_w * 0.5 + 0.015, -char_h * 0.5, 0.008);
    const text_col = Vec3.init(1.0, 1.0, 1.0);
    try addText(&b, text, text_origin, char_w, char_h, char_spacing, text_col);

    return b;
}

/// Builds a futuristic HUD waveform player frame with dark smoked glass screen,
/// Builds a futuristic HUD waveform player frame with dark smoked glass screen,
/// clean corner brackets, top/bottom rails, and avionics labels.
pub fn buildWaveformPlayerFrame(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.68;
    const h: f32 = 0.26;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass screen plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Precision corner brackets (sleek corner caps that do not intersect header text)
    const frame_col = Vec3.init(0.35, 2.6, 3.6); // neon cyan
    const brk_l: f32 = 0.035;
    const brk_t: f32 = 0.006;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Header label: "TURB // AERO"
    const text_col = Vec3.init(0.8, 3.4, 4.4);
    try addText(&b, "TURB // AERO", Vec3.init(-hw + 0.040, hh - 0.052, 0.006), 0.024, 0.040, 0.005, text_col);

    // Left status pip on header
    const left_pip = [4]Vec3{
        Vec3.init(-hw + 0.016, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.020, 0.004),
        Vec3.init(-hw + 0.016, hh - 0.020, 0.004),
    };
    try b.slab(left_pip, Vec3.init(0, 0, 0.005), Vec3.init(0.3, 3.4, 4.0));

    // 4. Secondary sub-label: "VIBRATION" (Large, crisp, high legibility)
    const sub_col = Vec3.init(0.5, 2.2, 3.2);
    try addText(&b, "VIBRATION", Vec3.init(-hw + 0.040, -hh + 0.018, 0.006), 0.028, 0.042, 0.007, sub_col);

    // 5. Horizontal divider rail under header & vertical partition divider rail
    const sub_rail_y: f32 = hh - 0.065;
    const sub_rail = [4]Vec3{
        Vec3.init(-hw + 0.015, sub_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, sub_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, sub_rail_y + 0.002, 0.002),
        Vec3.init(-hw + 0.015, sub_rail_y + 0.002, 0.002),
    };
    try b.slab(sub_rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.35));

    const div_x: f32 = 0.170;
    const div_rail = [4]Vec3{
        Vec3.init(div_x, -hh + 0.018, 0.002),
        Vec3.init(div_x + 0.004, -hh + 0.018, 0.002),
        Vec3.init(div_x + 0.004, sub_rail_y, 0.002),
        Vec3.init(div_x, sub_rail_y, 0.002),
    };
    try b.slab(div_rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.40));

    // 6. G-load header label & 3 background LED tracks
    try addText(&b, "G-LOAD", Vec3.init(div_x + 0.016, hh - 0.052, 0.006), 0.020, 0.035, 0.004, text_col);

    const led_ys = [_]f32{ -0.048, 0.000, 0.048 };
    for (led_ys) |ly| {
        const led_track = [4]Vec3{
            Vec3.init(div_x + 0.020, ly - 0.010, 0.004),
            Vec3.init(hw - 0.020, ly - 0.010, 0.004),
            Vec3.init(hw - 0.020, ly + 0.010, 0.004),
            Vec3.init(div_x + 0.020, ly + 0.010, 0.004),
        };
        try b.slab(led_track, Vec3.init(0, 0, 0.003), Vec3.init(0.08, 0.12, 0.18));
    }

    return b;
}

/// Builds a high-tech translucent smoked glass menu panel with neon corner brackets,
/// golden top accent, and horizontal dividing rails.
pub fn buildMenuBacking(alloc: std.mem.Allocator, w: f32, h: f32) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.010, 0.015, 0.024);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.012),
        Vec3.init(hw, -hh, -0.012),
        Vec3.init(hw, hh, -0.012),
        Vec3.init(-hw, hh, -0.012),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. High-tech corner brackets
    const frame_col = Vec3.init(0.35, 2.4, 3.6); // neon cyan
    const brk_l: f32 = 0.090;
    const brk_t: f32 = 0.008;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.005), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.005), frame_col);
        }
    }

    // 3. Top accent golden rail
    const gold_col = Vec3.init(3.8, 3.2, 0.8);
    const rail_w: f32 = hw * 0.90;
    const top_rail = [4]Vec3{
        Vec3.init(-rail_w, hh - 0.005, 0.003),
        Vec3.init(rail_w, hh - 0.005, 0.003),
        Vec3.init(rail_w, hh, 0.003),
        Vec3.init(-rail_w, hh, 0.003),
    };
    try b.slab(top_rail, Vec3.init(0, 0, 0.004), gold_col);

    // 4. Header divider rail (under header, y = hh - 0.20)
    const div_y: f32 = hh - 0.20;
    const div_rail = [4]Vec3{
        Vec3.init(-rail_w, div_y - 0.003, 0.003),
        Vec3.init(rail_w, div_y - 0.003, 0.003),
        Vec3.init(rail_w, div_y, 0.003),
        Vec3.init(-rail_w, div_y, 0.003),
    };
    try b.slab(div_rail, Vec3.init(0, 0, 0.004), frame_col.scale(0.55));

    // 5. Footer divider rail (comfortably above footer hints, y = -hh + 0.20)
    const foot_y: f32 = -hh + 0.20;
    const foot_rail = [4]Vec3{
        Vec3.init(-rail_w, foot_y - 0.003, 0.003),
        Vec3.init(rail_w, foot_y - 0.003, 0.003),
        Vec3.init(rail_w, foot_y, 0.003),
        Vec3.init(-rail_w, foot_y, 0.003),
    };
    try b.slab(foot_rail, Vec3.init(0, 0, 0.004), frame_col.scale(0.55));

    return b;
}

/// Builds a compact, sleek 3D window frame specifically tailored for the ESC pause menu.
pub fn buildPauseMenuBacking(alloc: std.mem.Allocator, w: f32, h: f32) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.010, 0.015, 0.024);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.012),
        Vec3.init(hw, -hh, -0.012),
        Vec3.init(hw, hh, -0.012),
        Vec3.init(-hw, hh, -0.012),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. High-tech corner brackets
    const frame_col = Vec3.init(0.35, 2.4, 3.6); // neon cyan
    const brk_l: f32 = 0.075;
    const brk_t: f32 = 0.007;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.005), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.005), frame_col);
        }
    }

    // 3. Top accent golden rail
    const gold_col = Vec3.init(3.8, 3.2, 0.8);
    const rail_w: f32 = hw * 0.90;
    const top_rail = [4]Vec3{
        Vec3.init(-rail_w, hh - 0.005, 0.003),
        Vec3.init(rail_w, hh - 0.005, 0.003),
        Vec3.init(rail_w, hh, 0.003),
        Vec3.init(-rail_w, hh, 0.003),
    };
    try b.slab(top_rail, Vec3.init(0, 0, 0.004), gold_col);

    // 4. Header divider rail (under subtitle)
    const div_y: f32 = 0.14;
    const div_rail = [4]Vec3{
        Vec3.init(-rail_w, div_y - 0.003, 0.003),
        Vec3.init(rail_w, div_y - 0.003, 0.003),
        Vec3.init(rail_w, div_y, 0.003),
        Vec3.init(-rail_w, div_y, 0.003),
    };
    try b.slab(div_rail, Vec3.init(0, 0, 0.004), frame_col.scale(0.55));

    // 5. Footer divider rail (above footer hints)
    const foot_y: f32 = -0.22;
    const foot_rail = [4]Vec3{
        Vec3.init(-rail_w, foot_y - 0.003, 0.003),
        Vec3.init(rail_w, foot_y - 0.003, 0.003),
        Vec3.init(rail_w, foot_y, 0.003),
        Vec3.init(-rail_w, foot_y, 0.003),
    };
    try b.slab(foot_rail, Vec3.init(0, 0, 0.004), frame_col.scale(0.55));

    return b;
}

/// Builds a breathtaking 3D military supersonic fighter emblem logo with delta wings,
/// canted vertical stabilizers, canopy glint, twin afterburner nozzles, flanking aviator wings, and HUD reticle.
pub fn buildTitleLogo(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const gold_col = Vec3.init(4.2, 3.5, 0.9);
    const cyan_col = Vec3.init(0.4, 2.8, 4.0);
    const stealth_col = Vec3.init(0.85, 0.95, 1.15);
    const dark_body = Vec3.init(0.12, 0.16, 0.22);
    const orange_burner = Vec3.init(5.0, 2.2, 0.2);

    // 1. Central Stealth Interceptor Jet
    // Nose to cockpit
    const nose_pts = [4]Vec3{
        Vec3.init(0.00, 0.16, 0.015),
        Vec3.init(0.025, 0.08, 0.012),
        Vec3.init(0.00, 0.07, 0.018),
        Vec3.init(-0.025, 0.08, 0.012),
    };
    try b.slab(nose_pts, Vec3.init(0, 0, 0.006), stealth_col);

    // Main fuselage body
    const fuse_pts = [4]Vec3{
        Vec3.init(-0.025, 0.08, 0.012),
        Vec3.init(0.025, 0.08, 0.012),
        Vec3.init(0.045, -0.12, 0.010),
        Vec3.init(-0.045, -0.12, 0.010),
    };
    try b.slab(fuse_pts, Vec3.init(0, 0, 0.007), dark_body);

    // Glowing electric canopy
    const canopy_pts = [4]Vec3{
        Vec3.init(0.00, 0.08, 0.022),
        Vec3.init(0.018, 0.02, 0.020),
        Vec3.init(0.00, -0.04, 0.019),
        Vec3.init(-0.018, 0.02, 0.020),
    };
    try b.slab(canopy_pts, Vec3.init(0, 0, 0.005), cyan_col);

    // Swept Delta Wings (Left & Right)
    const l_wing = [4]Vec3{
        Vec3.init(-0.025, 0.05, 0.010),
        Vec3.init(-0.28, -0.06, 0.007),
        Vec3.init(-0.25, -0.10, 0.007),
        Vec3.init(-0.045, -0.08, 0.010),
    };
    try b.slab(l_wing, Vec3.init(0, 0, 0.004), stealth_col);
    const l_trim = [4]Vec3{
        Vec3.init(-0.025, 0.05, 0.012),
        Vec3.init(-0.28, -0.06, 0.009),
        Vec3.init(-0.27, -0.07, 0.009),
        Vec3.init(-0.028, 0.038, 0.012),
    };
    try b.slab(l_trim, Vec3.init(0, 0, 0.003), gold_col);

    const r_wing = [4]Vec3{
        Vec3.init(0.025, 0.05, 0.010),
        Vec3.init(0.045, -0.08, 0.010),
        Vec3.init(0.25, -0.10, 0.007),
        Vec3.init(0.28, -0.06, 0.007),
    };
    try b.slab(r_wing, Vec3.init(0, 0, 0.004), stealth_col);
    const r_trim = [4]Vec3{
        Vec3.init(0.025, 0.05, 0.012),
        Vec3.init(0.028, 0.038, 0.012),
        Vec3.init(0.27, -0.07, 0.009),
        Vec3.init(0.28, -0.06, 0.009),
    };
    try b.slab(r_trim, Vec3.init(0, 0, 0.003), gold_col);

    // Twin Canted Vertical Stabilizers (Fins)
    const l_fin = [4]Vec3{
        Vec3.init(-0.032, -0.05, 0.012),
        Vec3.init(-0.058, -0.12, 0.038),
        Vec3.init(-0.048, -0.14, 0.038),
        Vec3.init(-0.028, -0.12, 0.012),
    };
    try b.slab(l_fin, Vec3.init(0, 0, 0.003), cyan_col);

    const r_fin = [4]Vec3{
        Vec3.init(0.028, -0.12, 0.012),
        Vec3.init(0.048, -0.14, 0.038),
        Vec3.init(0.058, -0.12, 0.038),
        Vec3.init(0.032, -0.05, 0.012),
    };
    try b.slab(r_fin, Vec3.init(0, 0, 0.003), cyan_col);

    // Glowing Afterburner Exhausts
    const l_nozzle = [4]Vec3{
        Vec3.init(-0.036, -0.12, 0.010),
        Vec3.init(-0.012, -0.12, 0.010),
        Vec3.init(-0.012, -0.145, 0.010),
        Vec3.init(-0.036, -0.145, 0.010),
    };
    try b.slab(l_nozzle, Vec3.init(0, 0, 0.005), orange_burner);

    const r_nozzle = [4]Vec3{
        Vec3.init(0.012, -0.12, 0.010),
        Vec3.init(0.036, -0.12, 0.010),
        Vec3.init(0.036, -0.145, 0.010),
        Vec3.init(0.012, -0.145, 0.010),
    };
    try b.slab(r_nozzle, Vec3.init(0, 0, 0.005), orange_burner);

    // 2. Aviator Insignia Swept Wing Bars (Feathers flanking the central jet)
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |side| {
        const bar1 = [4]Vec3{
            Vec3.init(side * 0.16, 0.08, 0.006),
            Vec3.init(side * 0.44, 0.11, 0.006),
            Vec3.init(side * 0.42, 0.085, 0.006),
            Vec3.init(side * 0.16, 0.06, 0.006),
        };
        try b.slab(bar1, Vec3.init(0, 0, 0.003), gold_col);

        const bar2 = [4]Vec3{
            Vec3.init(side * 0.14, 0.04, 0.006),
            Vec3.init(side * 0.38, 0.05, 0.006),
            Vec3.init(side * 0.36, 0.025, 0.006),
            Vec3.init(side * 0.14, 0.02, 0.006),
        };
        try b.slab(bar2, Vec3.init(0, 0, 0.003), stealth_col);

        const bar3 = [4]Vec3{
            Vec3.init(side * 0.12, 0.00, 0.006),
            Vec3.init(side * 0.32, -0.01, 0.006),
            Vec3.init(side * 0.30, -0.035, 0.006),
            Vec3.init(side * 0.12, -0.02, 0.006),
        };
        try b.slab(bar3, Vec3.init(0, 0, 0.003), cyan_col);
    }

    // 3. Tactical Reticle Brackets & Apex Star
    const apex_pts = [4]Vec3{
        Vec3.init(0.00, 0.21, 0.012),
        Vec3.init(0.028, 0.175, 0.010),
        Vec3.init(0.00, 0.185, 0.014),
        Vec3.init(-0.028, 0.175, 0.010),
    };
    try b.slab(apex_pts, Vec3.init(0, 0, 0.004), gold_col);

    const ret_rad: f32 = 0.22;
    const num_ticks: usize = 12;
    for (0..num_ticks) |ti| {
        const ang = @as(f32, @floatFromInt(ti)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(num_ticks)));
        const ca = @cos(ang);
        const sa = @sin(ang);
        const r1 = ret_rad;
        const r2 = ret_rad + 0.018;
        const tick_pts = [4]Vec3{
            Vec3.init(ca * r1 - sa * 0.003, sa * r1 + ca * 0.003, 0.005),
            Vec3.init(ca * r2 - sa * 0.003, sa * r2 + ca * 0.003, 0.005),
            Vec3.init(ca * r2 + sa * 0.003, sa * r2 - ca * 0.003, 0.005),
            Vec3.init(ca * r1 + sa * 0.003, sa * r1 - ca * 0.003, 0.005),
        };
        const t_col = if (ti % 3 == 0) gold_col else cyan_col.scale(0.7);
        try b.slab(tick_pts, Vec3.init(0, 0, 0.002), t_col);
    }

    return b;
}

/// Builds a wide, cinematic tactical command display backing for the Title / Start Screen
/// complete with neon cyan corner brackets, gold command rails, side runway ladders, and hazard stripes.
pub fn buildTitleScreenBacking(alloc: std.mem.Allocator, w: f32, h: f32) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.008, 0.012, 0.020);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.015),
        Vec3.init(hw, -hh, -0.015),
        Vec3.init(hw, hh, -0.015),
        Vec3.init(-hw, hh, -0.015),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.008), bg_color);

    // 2. High-tech dual-line corner brackets
    const frame_col = Vec3.init(0.40, 2.8, 4.0); // neon electric cyan
    const gold_col = Vec3.init(4.2, 3.5, 0.9);   // cyber gold
    const brk_l: f32 = 0.120;
    const brk_t: f32 = 0.009;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.005), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.005), frame_col);

            const notch = [4]Vec3{
                Vec3.init(sx * (hw - 0.020), sy * (hh - 0.020), 0.003),
                Vec3.init(sx * (hw - 0.045), sy * (hh - 0.020), 0.003),
                Vec3.init(sx * (hw - 0.045), sy * (hh - 0.035), 0.003),
                Vec3.init(sx * (hw - 0.020), sy * (hh - 0.035), 0.003),
            };
            try b.slab(notch, Vec3.init(0, 0, 0.004), gold_col);
        }
    }

    // 3. Top gold command rail
    const rail_w: f32 = hw * 0.94;
    const top_rail = [4]Vec3{
        Vec3.init(-rail_w, hh - 0.006, 0.003),
        Vec3.init(rail_w, hh - 0.006, 0.003),
        Vec3.init(rail_w, hh, 0.003),
        Vec3.init(-rail_w, hh, 0.003),
    };
    try b.slab(top_rail, Vec3.init(0, 0, 0.005), gold_col);

    // 4. Runway guidance light dashes (along left and right borders)
    const num_dashes: usize = 7;
    for (0..num_dashes) |di| {
        const dy = hh * 0.65 - @as(f32, @floatFromInt(di)) * (hh * 1.30 / @as(f32, @floatFromInt(num_dashes - 1)));
        const d_col = if (di % 2 == 0) gold_col else frame_col;
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
            const dash = [4]Vec3{
                Vec3.init(sx * (hw - 0.045), dy - 0.012, 0.002),
                Vec3.init(sx * (hw - 0.025), dy - 0.012, 0.002),
                Vec3.init(sx * (hw - 0.025), dy + 0.012, 0.002),
                Vec3.init(sx * (hw - 0.045), dy + 0.012, 0.002),
            };
            try b.slab(dash, Vec3.init(0, 0, 0.003), d_col);
        }
    }

    // 5. Centerline runway landing guidance strips (near bottom)
    for (0..4) |ri| {
        const ry = -hh + 0.08 + @as(f32, @floatFromInt(ri)) * 0.045;
        const rw = 0.008 + @as(f32, @floatFromInt(ri)) * 0.006;
        const r_strip = [4]Vec3{
            Vec3.init(-rw, ry, 0.002),
            Vec3.init(rw, ry, 0.002),
            Vec3.init(rw * 0.8, ry + 0.025, 0.002),
            Vec3.init(-rw * 0.8, ry + 0.025, 0.002),
        };
        try b.slab(r_strip, Vec3.init(0, 0, 0.003), gold_col.scale(0.85));
    }

    // 6. Hazard stripes along lower bottom rail
    const num_stripes: usize = 14;
    const stripe_span: f32 = hw * 1.5;
    const stripe_w: f32 = stripe_span / @as(f32, @floatFromInt(num_stripes));
    for (0..num_stripes) |si| {
        if (si % 2 == 0) {
            const sx1 = -stripe_span * 0.5 + @as(f32, @floatFromInt(si)) * stripe_w;
            const sx2 = sx1 + stripe_w;
            const sy1 = -hh + 0.004;
            const sy2 = -hh + 0.022;
            const stripe_pts = [4]Vec3{
                Vec3.init(sx1, sy1, 0.002),
                Vec3.init(sx2, sy1, 0.002),
                Vec3.init(sx2 + 0.015, sy2, 0.002),
                Vec3.init(sx1 + 0.015, sy2, 0.002),
            };
            try b.slab(stripe_pts, Vec3.init(0, 0, 0.003), gold_col.scale(0.75));
        }
    }

    return b;
}

/// Builds a clean tactical PIP target tracking frame (upper-left HUD) with smoked glass,
/// neon corner brackets, header banner "TGT // TRACK", center crosshair, and telemetry readouts.
pub fn buildTargetPipFrame(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.64;
    const h: f32 = 0.44;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Corner brackets
    const frame_col = Vec3.init(0.4, 2.2, 3.2);
    const brk_l: f32 = 0.038;
    const brk_t: f32 = 0.006;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Header bar: "TGT // TRACK"
    const text_col = Vec3.init(0.8, 3.4, 4.4);
    try addText(&b, "TGT // TRACK", Vec3.init(-hw + 0.046, hh - 0.048, 0.006), 0.026, 0.040, 0.0055, text_col);

    // Left status pill on header
    const pill = [4]Vec3{
        Vec3.init(-hw + 0.016, hh - 0.046, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.046, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.018, 0.004),
        Vec3.init(-hw + 0.016, hh - 0.018, 0.004),
    };
    try b.slab(pill, Vec3.init(0, 0, 0.005), Vec3.init(0.4, 3.6, 2.0));

    // Top divider rail under header
    const rail = [4]Vec3{
        Vec3.init(-hw + 0.015, hh - 0.062, 0.002),
        Vec3.init(hw - 0.015, hh - 0.062, 0.002),
        Vec3.init(hw - 0.015, hh - 0.058, 0.002),
        Vec3.init(-hw + 0.015, hh - 0.058, 0.002),
    };
    try b.slab(rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.4));

    // 4. Center reticle cross in PIP (centered around y = 0.020)
    const ch_col = Vec3.init(0.25, 0.8, 1.2);
    const cy_ret: f32 = 0.020;
    try addStroke(&b, Vec3.init(-0.048, cy_ret, 0.002), Vec3.init(-0.015, cy_ret, 0.002), 0.0035, Vec3.init(0, 0, 0.002), ch_col);
    try addStroke(&b, Vec3.init(0.015, cy_ret, 0.002), Vec3.init(0.048, cy_ret, 0.002), 0.0035, Vec3.init(0, 0, 0.002), ch_col);
    try addStroke(&b, Vec3.init(0, cy_ret - 0.048, 0.002), Vec3.init(0, cy_ret - 0.015, 0.002), 0.0035, Vec3.init(0, 0, 0.002), ch_col);
    try addStroke(&b, Vec3.init(0, cy_ret + 0.015, 0.002), Vec3.init(0, cy_ret + 0.048, 0.002), 0.0035, Vec3.init(0, 0, 0.002), ch_col);

    // 5. Telemetry divider rail (above readouts)
    const tel_rail_y: f32 = -hh + 0.095;
    const tel_rail = [4]Vec3{
        Vec3.init(-hw + 0.015, tel_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, tel_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, tel_rail_y + 0.002, 0.002),
        Vec3.init(-hw + 0.015, tel_rail_y + 0.002, 0.002),
    };
    try b.slab(tel_rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.4));

    // Telemetry labels: "RNG:" and "SPD:"
    const lbl_col = Vec3.init(0.6, 2.4, 3.2);
    try addText(&b, "RNG", Vec3.init(-hw + 0.026, -hh + 0.054, 0.006), 0.018, 0.028, 0.0045, lbl_col);
    try addText(&b, "SPD", Vec3.init(0.010, -hh + 0.054, 0.006), 0.018, 0.028, 0.0045, lbl_col);

    // Bottom range track line
    const rng_track = [4]Vec3{
        Vec3.init(-hw + 0.026, -hh + 0.022, 0.002),
        Vec3.init(hw - 0.026, -hh + 0.022, 0.002),
        Vec3.init(hw - 0.026, -hh + 0.028, 0.002),
        Vec3.init(-hw + 0.026, -hh + 0.028, 0.002),
    };
    try b.slab(rng_track, Vec3.init(0, 0, 0.003), Vec3.init(0.10, 0.16, 0.24));

    return b;
}

/// Builds a dedicated HUD Hull / Armor health gauge frame (lower-right HUD)
/// with dark smoked glass, corner brackets, "HULL // STATUS" header, "ARMOR LVL" sublabel,
/// and 10 segmented health pips.
pub fn buildHealthGaugeFrame(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.68;
    const h: f32 = 0.26;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Corner brackets
    const frame_col = Vec3.init(0.4, 2.4, 3.4);
    const brk_l: f32 = 0.035;
    const brk_t: f32 = 0.006;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Header label: "HULL // STATUS" (Cleanly spanning the top zone above sub-rail)
    const text_col = Vec3.init(0.8, 3.4, 4.4);
    try addText(&b, "HULL // STATUS", Vec3.init(-hw + 0.046, hh - 0.052, 0.006), 0.028, 0.044, 0.008, text_col);

    // Left status pill on header
    const pill = [4]Vec3{
        Vec3.init(-hw + 0.016, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.020, 0.004),
        Vec3.init(-hw + 0.016, hh - 0.020, 0.004),
    };
    try b.slab(pill, Vec3.init(0, 0, 0.005), Vec3.init(0.25, 3.4, 1.2));

    // 4. Sub-label: "HULL INTEGRITY" (Large, crisp, high legibility)
    const sub_col = Vec3.init(0.6, 2.2, 3.2);
    try addText(&b, "HULL INTEGRITY", Vec3.init(-hw + 0.040, -hh + 0.018, 0.006), 0.028, 0.042, 0.007, sub_col);

    // 5. Horizontal divider rail under header & vertical partition divider rail
    const sub_rail_y: f32 = hh - 0.065;
    const sub_rail = [4]Vec3{
        Vec3.init(-hw + 0.015, sub_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, sub_rail_y - 0.002, 0.002),
        Vec3.init(hw - 0.015, sub_rail_y + 0.002, 0.002),
        Vec3.init(-hw + 0.015, sub_rail_y + 0.002, 0.002),
    };
    try b.slab(sub_rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.35));

    const div_x: f32 = 0.090;
    const div_rail = [4]Vec3{
        Vec3.init(div_x, -hh + 0.018, 0.002),
        Vec3.init(div_x + 0.004, -hh + 0.018, 0.002),
        Vec3.init(div_x + 0.004, sub_rail_y, 0.002),
        Vec3.init(div_x, sub_rail_y, 0.002),
    };
    try b.slab(div_rail, Vec3.init(0, 0, 0.003), frame_col.scale(0.40));

    // 6. 10 background segment tracks for health pips (left partition)
    const pip_w: f32 = 0.027;
    const pip_h: f32 = 0.076;
    const pip_gap: f32 = 0.007;
    const start_x: f32 = -hw + 0.035;
    const track_col = Vec3.init(0.08, 0.12, 0.18);

    for (0..10) |i| {
        const px = start_x + @as(f32, @floatFromInt(i)) * (pip_w + pip_gap);
        const slot = [4]Vec3{
            Vec3.init(px, -0.038, 0.002),
            Vec3.init(px + pip_w, -0.038, 0.002),
            Vec3.init(px + pip_w, -0.038 + pip_h, 0.002),
            Vec3.init(px, -0.038 + pip_h, 0.002),
        };
        try b.slab(slot, Vec3.init(0, 0, 0.003), track_col);
    }

    return b;
}

/// Builds a 3-tier tactical avionics scoreboard plate displaying:
/// - Personal Score (PILOT)
/// - Friendly Team Score (BLUE)
/// - Enemy Team Score (RED)
pub fn buildScoreBoardPlate(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.64;
    const h: f32 = 0.40;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Corner brackets
    const frame_col = Vec3.init(0.4, 2.4, 3.4);
    const brk_l: f32 = 0.035;
    const brk_t: f32 = 0.006;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Header line: "TAC // SCORE"
    const text_col = Vec3.init(0.8, 3.4, 4.4);
    try addText(&b, "TAC // SCORE", Vec3.init(-hw + 0.046, hh - 0.056, 0.006), 0.028, 0.044, 0.006, text_col);

    // Top status pill
    const top_pill = [4]Vec3{
        Vec3.init(-hw + 0.016, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.050, 0.004),
        Vec3.init(-hw + 0.026, hh - 0.020, 0.004),
        Vec3.init(-hw + 0.016, hh - 0.020, 0.004),
    };
    try b.slab(top_pill, Vec3.init(0, 0, 0.005), Vec3.init(4.2, 3.6, 0.5));

    // Horizontal rails separating the 3 score tiers
    const rail_y1: f32 = 0.038;
    const rail1 = [4]Vec3{
        Vec3.init(-hw + 0.016, rail_y1 - 0.003, 0.002),
        Vec3.init(hw - 0.016, rail_y1 - 0.003, 0.002),
        Vec3.init(hw - 0.016, rail_y1 + 0.003, 0.002),
        Vec3.init(-hw + 0.016, rail_y1 + 0.003, 0.002),
    };
    try b.slab(rail1, Vec3.init(0, 0, 0.003), frame_col.scale(0.35));

    const rail_y2: f32 = -0.062;
    const rail2 = [4]Vec3{
        Vec3.init(-hw + 0.016, rail_y2 - 0.003, 0.002),
        Vec3.init(hw - 0.016, rail_y2 - 0.003, 0.002),
        Vec3.init(hw - 0.016, rail_y2 + 0.003, 0.002),
        Vec3.init(-hw + 0.016, rail_y2 + 0.003, 0.002),
    };
    try b.slab(rail2, Vec3.init(0, 0, 0.003), frame_col.scale(0.35));

    // 4. Row 1: Personal Score "YOU:"
    const row1_y: f32 = 0.068;
    const p1_pip = [4]Vec3{
        Vec3.init(-hw + 0.018, row1_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row1_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row1_y + 0.024, 0.004),
        Vec3.init(-hw + 0.018, row1_y + 0.024, 0.004),
    };
    try b.slab(p1_pip, Vec3.init(0, 0, 0.005), Vec3.init(4.2, 3.6, 0.5));
    try addText(&b, "YOU:", Vec3.init(-hw + 0.042, row1_y - 0.016, 0.006), 0.040, 0.060, 0.007, Vec3.init(4.2, 3.6, 0.5));

    // 5. Row 2: Friendly Team "BLUE:"
    const row2_y: f32 = -0.032;
    const p2_pip = [4]Vec3{
        Vec3.init(-hw + 0.018, row2_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row2_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row2_y + 0.024, 0.004),
        Vec3.init(-hw + 0.018, row2_y + 0.024, 0.004),
    };
    try b.slab(p2_pip, Vec3.init(0, 0, 0.005), Vec3.init(0.4, 2.8, 4.4));
    try addText(&b, "BLUE:", Vec3.init(-hw + 0.042, row2_y - 0.016, 0.006), 0.040, 0.060, 0.007, Vec3.init(0.4, 2.8, 4.4));

    // 6. Row 3: Enemy Team "RED:"
    const row3_y: f32 = -0.132;
    const p3_pip = [4]Vec3{
        Vec3.init(-hw + 0.018, row3_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row3_y - 0.016, 0.004),
        Vec3.init(-hw + 0.030, row3_y + 0.024, 0.004),
        Vec3.init(-hw + 0.018, row3_y + 0.024, 0.004),
    };
    try b.slab(p3_pip, Vec3.init(0, 0, 0.005), Vec3.init(4.4, 0.5, 0.3));
    try addText(&b, "RED:", Vec3.init(-hw + 0.042, row3_y - 0.016, 0.006), 0.040, 0.060, 0.007, Vec3.init(4.4, 0.6, 0.3));

    return b;
}

/// Builds an individual HUD Weather Status Tag badge (e.g. CLEAR, CLOUD, GUST, TURB, THERM, RAIN)
/// with dark smoked glass, left status indicator block, corner brackets, and crisp text.
pub fn buildWeatherTag(alloc: std.mem.Allocator, text: []const u8) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.42;
    const h: f32 = 0.075;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Corner brackets
    const frame_col = Vec3.init(1.0, 1.0, 1.0);
    const brk_l: f32 = 0.042;
    const brk_t: f32 = 0.0065;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Left glowing status pip
    const status_pip = [4]Vec3{
        Vec3.init(-hw + 0.016, -hh + 0.012, 0.004),
        Vec3.init(-hw + 0.038, -hh + 0.012, 0.004),
        Vec3.init(-hw + 0.038, hh - 0.012, 0.004),
        Vec3.init(-hw + 0.016, hh - 0.012, 0.004),
    };
    try b.slab(status_pip, Vec3.init(0, 0, 0.005), Vec3.init(1.0, 1.0, 1.0));

    // 4. Tag text centered nicely in remaining badge area
    const char_w: f32 = 0.034;
    const char_h: f32 = 0.052;
    const char_spacing: f32 = 0.008;
    const text_origin = Vec3.init(-hw + 0.056, -char_h * 0.5, 0.006);
    try addText(&b, text, text_origin, char_w, char_h, char_spacing, Vec3.init(1.0, 1.0, 1.0));

    return b;
}

/// Builds the header label badge for the HUD Weather annunciator column.
pub fn buildWeatherHeader(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 0.42;
    const h: f32 = 0.068;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // Dark smoked plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // Glowing cyan frame lines
    const frame_col = Vec3.init(0.35, 2.6, 3.6);
    const top_rail = [4]Vec3{
        Vec3.init(-hw + 0.015, hh - 0.004, 0.002),
        Vec3.init(hw - 0.015, hh - 0.004, 0.002),
        Vec3.init(hw - 0.015, hh, 0.002),
        Vec3.init(-hw + 0.015, hh, 0.002),
    };
    try b.slab(top_rail, Vec3.init(0, 0, 0.003), frame_col);

    const bot_rail = [4]Vec3{
        Vec3.init(-hw + 0.015, -hh, 0.002),
        Vec3.init(hw - 0.015, -hh, 0.002),
        Vec3.init(hw - 0.015, -hh + 0.004, 0.002),
        Vec3.init(-hw + 0.015, -hh + 0.004, 0.002),
    };
    try b.slab(bot_rail, Vec3.init(0, 0, 0.003), frame_col);

    // Text: "WX // STATUS"
    const text_col = Vec3.init(0.8, 3.4, 4.4);
    try addText(&b, "WX // STATUS", Vec3.init(-hw + 0.032, -0.020, 0.006), 0.026, 0.040, 0.006, text_col);

    return b;
}

/// Builds a futuristic HUD heading compass tape backing plate with dark smoked glass,
/// neon corner brackets, top/bottom rails, center index caret [▼], and left wind gauge frame.
pub fn buildCompassBacking(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const w: f32 = 1.08;
    const h: f32 = 0.176;
    const hw = w * 0.5;
    const hh = h * 0.5;

    // 1. Dark smoked glass plate
    const bg_color = Vec3.init(0.015, 0.022, 0.032);
    const bg_quad = [4]Vec3{
        Vec3.init(-hw, -hh, -0.006),
        Vec3.init(hw, -hh, -0.006),
        Vec3.init(hw, hh, -0.006),
        Vec3.init(-hw, hh, -0.006),
    };
    try b.slab(bg_quad, Vec3.init(0, 0, 0.006), bg_color);

    // 2. Corner brackets
    const frame_col = Vec3.init(0.4, 2.4, 3.2);
    const brk_l: f32 = 0.055;
    const brk_t: f32 = 0.008;
    inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sx| {
        inline for (.{ @as(f32, -1.0), @as(f32, 1.0) }) |sy| {
            const h_arm = [4]Vec3{
                Vec3.init(sx * hw, sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh - brk_t * sy, 0.002),
                Vec3.init(sx * (hw - brk_l), sy * hh, 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
            };
            try b.slab(h_arm, Vec3.init(0, 0, 0.004), frame_col);

            const v_arm = [4]Vec3{
                Vec3.init(sx * hw - brk_t * sx, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * (hh - brk_l), 0.002),
                Vec3.init(sx * hw, sy * hh, 0.002),
                Vec3.init(sx * hw - brk_t * sx, sy * hh, 0.002),
            };
            try b.slab(v_arm, Vec3.init(0, 0, 0.004), frame_col);
        }
    }

    // 3. Top and bottom rails
    const rail_col = Vec3.init(0.25, 0.85, 1.1);
    const top_r = [4]Vec3{
        Vec3.init(-hw + brk_l, hh - 0.004, 0.002),
        Vec3.init(hw - brk_l, hh - 0.004, 0.002),
        Vec3.init(hw - brk_l, hh, 0.002),
        Vec3.init(-hw + brk_l, hh, 0.002),
    };
    try b.slab(top_r, Vec3.init(0, 0, 0.003), rail_col);
    const bot_r = [4]Vec3{
        Vec3.init(-hw + brk_l, -hh, 0.002),
        Vec3.init(hw - brk_l, -hh, 0.002),
        Vec3.init(hw - brk_l, -hh + 0.004, 0.002),
        Vec3.init(-hw + brk_l, -hh + 0.004, 0.002),
    };
    try b.slab(bot_r, Vec3.init(0, 0, 0.003), rail_col);

    // 4. Partition line 1: between Airspeed and Digital Heading box at x = -0.190
    const p1_line = [4]Vec3{
        Vec3.init(-0.193, -hh + 0.015, 0.002),
        Vec3.init(-0.187, -hh + 0.015, 0.002),
        Vec3.init(-0.187, hh - 0.015, 0.002),
        Vec3.init(-0.193, hh - 0.015, 0.002),
    };
    try b.slab(p1_line, Vec3.init(0, 0, 0.003), rail_col);

    // Partition line 2: between Digital Heading box and Scrolling Tape at x = +0.050
    const p2_line = [4]Vec3{
        Vec3.init(0.047, -hh + 0.015, 0.002),
        Vec3.init(0.053, -hh + 0.015, 0.002),
        Vec3.init(0.053, hh - 0.015, 0.002),
        Vec3.init(0.047, hh - 0.015, 0.002),
    };
    try b.slab(p2_line, Vec3.init(0, 0, 0.003), rail_col);

    // 5. Zone Labels:
    // "AIR (M/S)" centered cleanly in left gauge zone (zone spans -hw=-0.540 to -0.190, center is -0.355)
    const lbl_col = Vec3.init(0.8, 3.4, 4.2);
    const air_lbl = "AIR (M/S)";
    const air_w = measureText(air_lbl, 0.034);
    try addText(&b, air_lbl, Vec3.init(-0.355 - air_w * 0.5, hh - 0.052, 0.006), 0.028, 0.034, 0.007, lbl_col);

    // "HDG" header in center zone (zone spans -0.190 to +0.050, center is -0.070)
    const hdg_w = measureText("HDG", 0.038);
    try addText(&b, "HDG", Vec3.init(-0.070 - hdg_w * 0.5, hh - 0.050, 0.006), 0.028, 0.038, 0.007, lbl_col);

    // 6. Gold index marker caret [▼] positioned directly above scrolling tape index at x = +0.270
    const tape_idx_x: f32 = 0.270;
    const caret_col = Vec3.init(4.4, 3.8, 0.5); // gold caret
    const caret = [4]Vec3{
        Vec3.init(tape_idx_x - 0.018, hh + 0.018, 0.004),
        Vec3.init(tape_idx_x + 0.018, hh + 0.018, 0.004),
        Vec3.init(tape_idx_x + 0.004, hh - 0.008, 0.004),
        Vec3.init(tape_idx_x - 0.004, hh - 0.008, 0.004),
    };
    try b.slab(caret, Vec3.init(0, 0, 0.003), caret_col);

    return b;
}

/// Builds a bold, high-visibility 3D directional arrow pointer for relative air/wind direction.
pub fn buildAirVectorArrow(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const arrow_col = Vec3.init(0.4, 4.2, 2.4); // glowing electric emerald/cyan
    // 1. Arrow shaft: sturdy stem from y = -0.022 to y = +0.004
    const sw: f32 = 0.0045; // total width = 0.009
    const shaft = [4]Vec3{
        Vec3.init(-sw, -0.022, 0.004),
        Vec3.init(sw, -0.022, 0.004),
        Vec3.init(sw, 0.004, 0.004),
        Vec3.init(-sw, 0.004, 0.004),
    };
    try b.slab(shaft, Vec3.init(0, 0, 0.004), arrow_col);

    // 2. Bold Delta Arrowhead: wide chevron pointing towards +Y
    const hw: f32 = 0.015; // total width = 0.030
    const head = [4]Vec3{
        Vec3.init(-hw, 0.002, 0.005),
        Vec3.init(hw, 0.002, 0.005),
        Vec3.init(0.002, 0.024, 0.005),
        Vec3.init(-0.002, 0.024, 0.005),
    };
    try b.slab(head, Vec3.init(0, 0, 0.005), arrow_col);

    // 3. Gold arrowhead tip beacon for sharp visual focus
    const tip_col = Vec3.init(4.4, 3.8, 0.5);
    const tip = [4]Vec3{
        Vec3.init(-0.006, 0.010, 0.006),
        Vec3.init(0.006, 0.010, 0.006),
        Vec3.init(0.001, 0.024, 0.006),
        Vec3.init(-0.001, 0.024, 0.006),
    };
    try b.slab(tip, Vec3.init(0, 0, 0.006), tip_col);

    return b;
}

/// Builds a classic military avionics Flight Path Vector (FPV) / Airflow Velocity reticle [-o-].
pub fn buildFPVReticle(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const fpv_col = Vec3.init(0.4, 3.6, 4.2); // neon cyan
    const r: f32 = 0.018;

    // Center circular ring (octagonal)
    const sides: usize = 8;
    for (0..sides) |i| {
        const a1 = @as(f32, @floatFromInt(i)) * (std.math.pi * 2.0 / 8.0);
        const a2 = @as(f32, @floatFromInt(i + 1)) * (std.math.pi * 2.0 / 8.0);
        const x1 = @cos(a1) * r;
        const y1 = @sin(a1) * r;
        const x2 = @cos(a2) * r;
        const y2 = @sin(a2) * r;
        const seg = [4]Vec3{
            Vec3.init(x1, y1, 0.004),
            Vec3.init(x2, y2, 0.004),
            Vec3.init(x2 * 0.85, y2 * 0.85, 0.004),
            Vec3.init(x1 * 0.85, y1 * 0.85, 0.004),
        };
        try b.slab(seg, Vec3.init(0, 0, 0.003), fpv_col);
    }

    // Left wing
    const left_wing = [4]Vec3{
        Vec3.init(-r - 0.024, -0.003, 0.004),
        Vec3.init(-r, -0.003, 0.004),
        Vec3.init(-r, 0.003, 0.004),
        Vec3.init(-r - 0.024, 0.003, 0.004),
    };
    try b.slab(left_wing, Vec3.init(0, 0, 0.003), fpv_col);

    // Right wing
    const right_wing = [4]Vec3{
        Vec3.init(r, -0.003, 0.004),
        Vec3.init(r + 0.024, -0.003, 0.004),
        Vec3.init(r + 0.024, 0.003, 0.004),
        Vec3.init(r, 0.003, 0.004),
    };
    try b.slab(right_wing, Vec3.init(0, 0, 0.003), fpv_col);

    // Top vertical stabilizer fin
    const top_fin = [4]Vec3{
        Vec3.init(-0.003, r, 0.004),
        Vec3.init(0.003, r, 0.004),
        Vec3.init(0.003, r + 0.016, 0.004),
        Vec3.init(-0.003, r + 0.016, 0.004),
    };
    try b.slab(top_fin, Vec3.init(0, 0, 0.003), fpv_col);

    return b;
}

/// Glowing laser bolt mesh oriented along -Z.
pub fn buildLaser(alloc: std.mem.Allocator, col: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const p = [4]Vec3{
        Vec3.init(-0.18, 0, -9.0),
        Vec3.init(0.18, 0, -9.0),
        Vec3.init(0.18, 0, 9.0),
        Vec3.init(-0.18, 0, 9.0),
    };
    try b.slab(p, Vec3.init(0, 0.18, 0), col);
    return b;
}

/// Low-poly missile mesh oriented along -Z (nose at -Z, fins + plume at +Z).
pub fn buildMissile(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const body = srgb(235, 240, 245);
    const warhead = srgb(255, 70, 50);
    const fin_col = srgb(60, 68, 82);
    const plume = Vec3.init(3.5, 1.8, 0.4);

    const st = [_][4]f32{
        .{ -3.2, 0.03, 0.03, 0.0 },
        .{ -2.0, 0.28, 0.28, 0.0 },
        .{ 2.2, 0.28, 0.28, 0.0 },
        .{ 3.0, 0.45, 0.45, 0.0 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, 0, (st[i][0] + st[i + 1][0]) * 0.5);
        const col = if (i == 0) warhead else if (i == 1) body else plume;
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }
    // Tail fins
    inline for (.{ @as(f32, 1), @as(f32, -1) }) |s| {
        const hfin = [4]Vec3{
            Vec3.init(s * 0.24, 0, 1.0),
            Vec3.init(s * 0.95, 0, 1.8),
            Vec3.init(s * 0.95, 0, 2.2),
            Vec3.init(s * 0.24, 0, 2.2),
        };
        try b.slab(hfin, Vec3.init(0, 0.04, 0), fin_col);
        const vfin = [4]Vec3{
            Vec3.init(0, s * 0.24, 1.0),
            Vec3.init(0, s * 0.95, 1.8),
            Vec3.init(0, s * 0.95, 2.2),
            Vec3.init(0, s * 0.24, 2.2),
        };
        try b.slab(vfin, Vec3.init(0.04, 0, 0), fin_col);
    }
    return b;
}

/// Low-poly car mesh (~4.4 m long, ~2.0 m wide, ~1.5 m tall), nose toward -Z.
/// Body uses white base so per-instance tint colors each car differently.
pub fn buildCar(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const chassis = Vec3.init(1.0, 1.0, 1.0); // tinted by instance color
    const cabin = srgb(45, 58, 78);
    const lights_f = Vec3.init(2.4, 2.2, 1.5);
    const lights_r = Vec3.init(2.2, 0.25, 0.2);

    // Lower body
    const low = [4]Vec3{
        Vec3.init(-1.05, 0.45, -2.2),
        Vec3.init(1.05, 0.45, -2.2),
        Vec3.init(1.05, 0.45, 2.2),
        Vec3.init(-1.05, 0.45, 2.2),
    };
    try b.slab(low, Vec3.init(0, 0.38, 0), chassis);

    // Upper cabin
    const top = [4]Vec3{
        Vec3.init(-0.90, 1.08, -0.85),
        Vec3.init(0.90, 1.08, -0.85),
        Vec3.init(0.90, 1.08, 1.05),
        Vec3.init(-0.90, 1.08, 1.05),
    };
    try b.slab(top, Vec3.init(0, 0.32, 0), cabin);

    // Headlights & taillights
    const hl = [4]Vec3{
        Vec3.init(-0.85, 0.52, -2.26),
        Vec3.init(0.85, 0.52, -2.26),
        Vec3.init(0.85, 0.52, -2.18),
        Vec3.init(-0.85, 0.52, -2.18),
    };
    try b.slab(hl, Vec3.init(0, 0.10, 0), lights_f);
    const tl = [4]Vec3{
        Vec3.init(-0.85, 0.55, 2.18),
        Vec3.init(0.85, 0.55, 2.18),
        Vec3.init(0.85, 0.55, 2.26),
        Vec3.init(-0.85, 0.55, 2.26),
    };
    try b.slab(tl, Vec3.init(0, 0.10, 0), lights_r);
    return b;
}

/// Tiny stylized pedestrian (~2.2 m tall with head & torso) so you spot them when buzzing streets.
pub fn buildPerson(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const shirt = Vec3.init(1.0, 1.0, 1.0); // tinted per instance
    const head_col = srgb(245, 208, 172);
    const legs_col = srgb(48, 56, 74);

    // Legs
    const legs = [4]Vec3{
        Vec3.init(-0.32, 0.45, -0.22),
        Vec3.init(0.32, 0.45, -0.22),
        Vec3.init(0.32, 0.45, 0.22),
        Vec3.init(-0.32, 0.45, 0.22),
    };
    try b.slab(legs, Vec3.init(0, 0.45, 0), legs_col);

    // Torso
    const torso = [4]Vec3{
        Vec3.init(-0.42, 1.25, -0.26),
        Vec3.init(0.42, 1.25, -0.26),
        Vec3.init(0.42, 1.25, 0.26),
        Vec3.init(-0.42, 1.25, 0.26),
    };
    try b.slab(torso, Vec3.init(0, 0.42, 0), shirt);

    // Head
    const head = [4]Vec3{
        Vec3.init(-0.28, 1.95, -0.28),
        Vec3.init(0.28, 1.95, -0.28),
        Vec3.init(0.28, 1.95, 0.28),
        Vec3.init(-0.28, 1.95, 0.28),
    };
    try b.slab(head, Vec3.init(0, 0.28, 0), head_col);
    return b;
}

/// Regular civilian / cargo / yacht boat (~26 m long, bow toward -Z).
pub fn buildBoat(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const hull = Vec3.init(1.0, 1.0, 1.0); // tinted per boat
    const deck = srgb(238, 240, 244);
    const bridge = srgb(248, 250, 252);
    const glass = srgb(45, 130, 210);

    // Tapered hull stations from bow (-Z) to stern (+Z)
    const st = [_][4]f32{
        .{ -13.5, 0.2, 1.2, 1.2 },
        .{ -8.0, 3.2, 2.2, 1.0 },
        .{ 2.0, 3.6, 2.2, 1.0 },
        .{ 12.5, 3.0, 2.0, 1.0 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, st[i][3], (st[i][0] + st[i + 1][0]) * 0.5);
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            const col = if (k <= 2) deck else hull;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }
    // Cabin / wheelhouse
    const cab = [4]Vec3{
        Vec3.init(-2.0, 3.6, -4.5),
        Vec3.init(2.0, 3.6, -4.5),
        Vec3.init(2.0, 3.6, 3.5),
        Vec3.init(-2.0, 3.6, 3.5),
    };
    try b.slab(cab, Vec3.init(0, 1.4, 0), bridge);
    const win_band = [4]Vec3{
        Vec3.init(-2.1, 4.3, -4.65),
        Vec3.init(2.1, 4.3, -4.65),
        Vec3.init(2.1, 4.3, -1.5),
        Vec3.init(-2.1, 4.3, -1.5),
    };
    try b.slab(win_band, Vec3.init(0, 0.45, 0), glass);
    return b;
}

/// Naval Battleship (~110 m long, armored gray hull, superstructure, mast, and main gun turrets).
pub fn buildBattleship(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const hull_gray = srgb(112, 122, 134);
    const deck_dark = srgb(76, 84, 96);
    const super_col = srgb(142, 152, 164);
    const turret_col = srgb(92, 100, 112);
    const barrel_col = srgb(52, 58, 66);
    const waterline_red = srgb(155, 48, 42);

    // Armored hull stations from sharp bow (-56 m) to stern (+54 m)
    const st = [_][4]f32{
        .{ -56.0, 0.3, 3.2, 2.5 },
        .{ -36.0, 7.2, 4.2, 2.2 },
        .{ -8.0, 9.5, 4.5, 2.2 },
        .{ 26.0, 9.2, 4.4, 2.2 },
        .{ 54.0, 6.8, 3.8, 2.2 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, st[i][3], (st[i][0] + st[i + 1][0]) * 0.5);
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            const col = if (k == 1) deck_dark else if (k >= 4) waterline_red else hull_gray;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }

    // Central citadel superstructure + bridge tower + radar mast
    const citadel = [4]Vec3{
        Vec3.init(-5.2, 8.5, -14.0),
        Vec3.init(5.2, 8.5, -14.0),
        Vec3.init(5.2, 8.5, 18.0),
        Vec3.init(-5.2, 8.5, 18.0),
    };
    try b.slab(citadel, Vec3.init(0, 3.2, 0), super_col);

    const bridge = [4]Vec3{
        Vec3.init(-3.6, 14.2, -10.0),
        Vec3.init(3.6, 14.2, -10.0),
        Vec3.init(3.6, 14.2, 4.0),
        Vec3.init(-3.6, 14.2, 4.0),
    };
    try b.slab(bridge, Vec3.init(0, 3.0, 0), hull_gray);

    const mast = [4]Vec3{
        Vec3.init(-1.2, 20.5, -4.0),
        Vec3.init(1.2, 20.5, -4.0),
        Vec3.init(1.2, 20.5, 0.5),
        Vec3.init(-1.2, 20.5, 0.5),
    };
    try b.slab(mast, Vec3.init(0, 4.0, 0), turret_col);

    // Two forward main battery turrets + one aft main turret, each with twin barrels
    const turret_z = [_]f32{ -34.0, -22.0, 30.0 };
    const barrel_dir = [_]f32{ -1.0, -1.0, 1.0 };
    for (turret_z, 0..) |tz, ti| {
        const ty: f32 = if (ti == 1) 9.6 else 7.8;
        const tur = [4]Vec3{
            Vec3.init(-3.4, ty, tz - 3.8),
            Vec3.init(3.4, ty, tz - 3.8),
            Vec3.init(3.4, ty, tz + 3.8),
            Vec3.init(-3.4, ty, tz + 3.8),
        };
        try b.slab(tur, Vec3.init(0, 1.6, 0), turret_col);

        const bz0 = tz + barrel_dir[ti] * 3.5;
        const bz1 = tz + barrel_dir[ti] * 11.5;
        const z_min = @min(bz0, bz1);
        const z_max = @max(bz0, bz1);
        inline for (.{ @as(f32, -1.2), @as(f32, 1.2) }) |bx| {
            const brl = [4]Vec3{
                Vec3.init(bx - 0.35, ty + 0.4, z_min),
                Vec3.init(bx + 0.35, ty + 0.4, z_min),
                Vec3.init(bx + 0.35, ty + 0.4, z_max),
                Vec3.init(bx - 0.35, ty + 0.4, z_max),
            };
            try b.slab(brl, Vec3.init(0, 0.35, 0), barrel_col);
        }
    }
    return b;
}

/// City Street / Avenue segment with dark asphalt pavement, raised concrete sidewalk curbs,
/// white edge lines, dashed white lane divider markings, double dashed highway yellow centerline,
/// and zebra crosswalks. Width along X: [-0.5, 0.5], Height along Y: [0, 1.0], Length along Z: [-0.5, 0.5].
pub fn buildStreet(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const asphalt = srgb(36, 40, 48);
    const sidewalk = srgb(155, 162, 172);
    const yellow_line = Vec3.init(1.7, 1.4, 0.25); // emissive highway yellow
    const white_line = Vec3.init(1.5, 1.5, 1.55); // bright painted white
    const crosswalk_col = Vec3.init(1.4, 1.4, 1.45);

    // 1. Road asphalt bed (y in [0.0, 0.96], x in [-0.42, 0.42], z in [-0.50, 0.50])
    const p_road = [4]Vec3{
        Vec3.init(-0.42, 0.48, -0.50),
        Vec3.init(0.42, 0.48, -0.50),
        Vec3.init(0.42, 0.48, 0.50),
        Vec3.init(-0.42, 0.48, 0.50),
    };
    try b.slab(p_road, Vec3.init(0, 0.48, 0), asphalt);

    // 2. Raised concrete sidewalk curbs (x in [-0.50, -0.42] and [0.42, 0.50], top at y = 1.00)
    const p_sw_l = [4]Vec3{
        Vec3.init(-0.50, 0.50, -0.50),
        Vec3.init(-0.42, 0.50, -0.50),
        Vec3.init(-0.42, 0.50, 0.50),
        Vec3.init(-0.50, 0.50, 0.50),
    };
    try b.slab(p_sw_l, Vec3.init(0, 0.50, 0), sidewalk);

    const p_sw_r = [4]Vec3{
        Vec3.init(0.42, 0.50, -0.50),
        Vec3.init(0.50, 0.50, -0.50),
        Vec3.init(0.50, 0.50, 0.50),
        Vec3.init(0.42, 0.50, 0.50),
    };
    try b.slab(p_sw_r, Vec3.init(0, 0.50, 0), sidewalk);

    // 3. White outer shoulder/fog lines at x = -0.38 and x = +0.38 (z in [-0.49, 0.49])
    inline for (.{ @as(f32, -0.38), @as(f32, 0.38) }) |lx| {
        const p_edge = [4]Vec3{
            Vec3.init(lx - 0.010, 0.965, -0.49),
            Vec3.init(lx + 0.010, 0.965, -0.49),
            Vec3.init(lx + 0.010, 0.965, 0.49),
            Vec3.init(lx - 0.010, 0.965, 0.49),
        };
        try b.slab(p_edge, Vec3.init(0, 0.006, 0), white_line);
    }

    // 4. Dashed white lane divider lines (at x = -0.19 and x = +0.19 for 4-lane avenue)
    const dash_w_zs = [_]f32{ -0.32, -0.16, 0.0, 0.16, 0.32 };
    inline for (.{ @as(f32, -0.19), @as(f32, 0.19) }) |lx| {
        for (dash_w_zs) |dz| {
            const p_dash = [4]Vec3{
                Vec3.init(lx - 0.006, 0.966, dz - 0.040),
                Vec3.init(lx + 0.006, 0.966, dz - 0.040),
                Vec3.init(lx + 0.006, 0.966, dz + 0.040),
                Vec3.init(lx - 0.006, 0.966, dz + 0.040),
            };
            try b.slab(p_dash, Vec3.init(0, 0.006, 0), white_line);
        }
    }

    // 5. Double dashed highway yellow centerline along Z (at x = -0.014 and x = +0.014)
    const dash_y_zs = [_]f32{ -0.36, -0.22, -0.07, 0.07, 0.22, 0.36 };
    inline for (.{ @as(f32, -0.014), @as(f32, 0.014) }) |cx| {
        for (dash_y_zs) |dz| {
            const p_dash = [4]Vec3{
                Vec3.init(cx - 0.006, 0.968, dz - 0.046),
                Vec3.init(cx + 0.006, 0.968, dz - 0.046),
                Vec3.init(cx + 0.006, 0.968, dz + 0.046),
                Vec3.init(cx - 0.006, 0.968, dz + 0.046),
            };
            try b.slab(p_dash, Vec3.init(0, 0.007, 0), yellow_line);
        }
    }

    // 6. Zebra crosswalk bars at both ends of the street segment (intersections)
    inline for (.{ @as(f32, -0.44), @as(f32, 0.44) }) |cz| {
        var wx: f32 = -0.32;
        while (wx <= 0.32) : (wx += 0.08) {
            const p_stripe = [4]Vec3{
                Vec3.init(wx - 0.024, 0.966, cz - 0.025),
                Vec3.init(wx + 0.024, 0.966, cz - 0.025),
                Vec3.init(wx + 0.024, 0.966, cz + 0.025),
                Vec3.init(wx - 0.024, 0.966, cz + 0.025),
            };
            try b.slab(p_stripe, Vec3.init(0, 0.006, 0), crosswalk_col);
        }
    }

    return b;
}

/// Modern Glass-Curtain Skyscraper:
/// - Lobby podium with glass entrance portal and marquee canopy
/// - Multi-story tower with individual window panes and vertical mullions across all 4 facades
/// - Upper penthouse setback tier with panoramic glass ribbons
/// - Rooftop mechanical penthouse, HVAC cooling units, and red-beacon communications antenna spire
pub fn buildBuilding(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const facade = Vec3.init(1.0, 1.0, 1.0); // tinted by building palette
    const lobby_col = srgb(54, 60, 72);
    const roof_col = srgb(68, 75, 88);
    const win_lit = Vec3.init(1.65, 1.50, 1.08); // warm glowing office windows
    const win_sky = Vec3.init(0.70, 1.05, 1.50); // cool reflective blue windows
    const win_dark = srgb(38, 48, 62); // dark office windows
    const win_amber = Vec3.init(1.75, 1.35, 0.70); // amber executive suite
    const canopy_col = srgb(38, 42, 50);
    const spire_steel = srgb(180, 190, 205);
    const beacon_red = Vec3.init(3.6, 0.35, 0.25);

    // 1. Ground-floor lobby base (`y in [0.0, 0.10]`, `x,z in [-0.52, 0.52]`)
    const p_base = [4]Vec3{
        Vec3.init(-0.52, 0.05, -0.52),
        Vec3.init(0.52, 0.05, -0.52),
        Vec3.init(0.52, 0.05, 0.52),
        Vec3.init(-0.52, 0.05, 0.52),
    };
    try b.slab(p_base, Vec3.init(0, 0.05, 0), lobby_col);

    // Entrance marquee / canopy on front facade (-Z)
    const p_canopy = [4]Vec3{
        Vec3.init(-0.16, 0.095, -0.56),
        Vec3.init(0.16, 0.095, -0.56),
        Vec3.init(0.16, 0.095, -0.48),
        Vec3.init(-0.16, 0.095, -0.48),
    };
    try b.slab(p_canopy, Vec3.init(0, 0.012, 0), canopy_col);

    // Glass entrance portal doors
    const p_doors = [4]Vec3{
        Vec3.init(-0.12, 0.045, -0.526),
        Vec3.init(0.12, 0.045, -0.526),
        Vec3.init(0.12, 0.045, -0.518),
        Vec3.init(-0.12, 0.045, -0.518),
    };
    try b.slab(p_doors, Vec3.init(0, 0.042, 0), win_sky);

    // 2. Main tower core (`y in [0.10, 0.84]`, `x,z in [-0.48, 0.48]`)
    const p_main = [4]Vec3{
        Vec3.init(-0.48, 0.47, -0.48),
        Vec3.init(0.48, 0.47, -0.48),
        Vec3.init(0.48, 0.47, 0.48),
        Vec3.init(-0.48, 0.47, 0.48),
    };
    try b.slab(p_main, Vec3.init(0, 0.37, 0), facade);

    // 3. Grid of individual window panes with structural mullions across all 4 facades
    const floor_ys = [_]f32{ 0.16, 0.24, 0.32, 0.40, 0.48, 0.56, 0.64, 0.72 };
    const win_cols = [_]Vec3{ win_lit, win_sky, win_dark, win_amber };
    const win_offs = [_]f32{ -0.32, -0.11, 0.11, 0.32 };
    const win_w: f32 = 0.070; // half-width (width = 0.14)
    const win_h: f32 = 0.024; // half-height (height = 0.048)

    for (floor_ys, 0..) |fy, f_idx| {
        for (win_offs, 0..) |wx, c_idx| {
            const col = win_cols[(f_idx * 7 + c_idx * 11) % win_cols.len];

            // North facade (z = -0.486)
            const p_north = [4]Vec3{
                Vec3.init(wx - win_w, fy, -0.488),
                Vec3.init(wx + win_w, fy, -0.488),
                Vec3.init(wx + win_w, fy, -0.478),
                Vec3.init(wx - win_w, fy, -0.478),
            };
            try b.slab(p_north, Vec3.init(0, win_h, 0), col);

            // South facade (z = +0.486)
            const p_south = [4]Vec3{
                Vec3.init(wx - win_w, fy, 0.478),
                Vec3.init(wx + win_w, fy, 0.478),
                Vec3.init(wx + win_w, fy, 0.488),
                Vec3.init(wx - win_w, fy, 0.488),
            };
            try b.slab(p_south, Vec3.init(0, win_h, 0), col);

            // West facade (x = -0.486)
            const p_west = [4]Vec3{
                Vec3.init(-0.488, fy, wx - win_w),
                Vec3.init(-0.478, fy, wx - win_w),
                Vec3.init(-0.478, fy, wx + win_w),
                Vec3.init(-0.488, fy, wx + win_w),
            };
            try b.slab(p_west, Vec3.init(0, win_h, 0), col);

            // East facade (x = +0.486)
            const p_east = [4]Vec3{
                Vec3.init(0.478, fy, wx - win_w),
                Vec3.init(0.488, fy, wx - win_w),
                Vec3.init(0.488, fy, wx + win_w),
                Vec3.init(0.478, fy, wx + win_w),
            };
            try b.slab(p_east, Vec3.init(0, win_h, 0), col);
        }
    }

    // Mid-tower architectural ledge / spandrel band at y = 0.44
    const p_ledge = [4]Vec3{
        Vec3.init(-0.495, 0.44, -0.495),
        Vec3.init(0.495, 0.44, -0.495),
        Vec3.init(0.495, 0.44, 0.495),
        Vec3.init(-0.495, 0.44, 0.495),
    };
    try b.slab(p_ledge, Vec3.init(0, 0.014, 0), canopy_col);

    // 4. Upper setback tier (`y in [0.84, 0.96]`, `x,z in [-0.36, 0.36]`)
    const p_top = [4]Vec3{
        Vec3.init(-0.36, 0.90, -0.36),
        Vec3.init(0.36, 0.90, -0.36),
        Vec3.init(0.36, 0.90, 0.36),
        Vec3.init(-0.36, 0.90, 0.36),
    };
    try b.slab(p_top, Vec3.init(0, 0.06, 0), facade);

    // Penthouse ribbon windows
    const p_pent = [4]Vec3{
        Vec3.init(-0.375, 0.90, -0.375),
        Vec3.init(0.375, 0.90, -0.375),
        Vec3.init(0.375, 0.90, 0.375),
        Vec3.init(-0.375, 0.90, 0.375),
    };
    try b.slab(p_pent, Vec3.init(0, 0.028, 0), win_lit);

    // 5. Rooftop mechanical penthouse + HVAC units
    const p_roof = [4]Vec3{
        Vec3.init(-0.18, 0.985, -0.18),
        Vec3.init(0.18, 0.985, -0.18),
        Vec3.init(0.18, 0.985, 0.18),
        Vec3.init(-0.18, 0.985, 0.18),
    };
    try b.slab(p_roof, Vec3.init(0, 0.025, 0), roof_col);

    // HVAC cooling unit
    const p_hvac = [4]Vec3{
        Vec3.init(-0.30, 0.975, 0.12),
        Vec3.init(-0.16, 0.975, 0.12),
        Vec3.init(-0.16, 0.975, 0.28),
        Vec3.init(-0.30, 0.975, 0.28),
    };
    try b.slab(p_hvac, Vec3.init(0, 0.015, 0), srgb(45, 52, 60));

    // 6. Tall telecommunications antenna spire (`y in [1.01, 1.18]`)
    const p_spire = [4]Vec3{
        Vec3.init(-0.02, 1.095, -0.02),
        Vec3.init(0.02, 1.095, -0.02),
        Vec3.init(0.02, 1.095, 0.02),
        Vec3.init(-0.02, 1.095, 0.02),
    };
    try b.slab(p_spire, Vec3.init(0, 0.085, 0), spire_steel);

    // Aviation red warning strobe beacon at top of spire
    const p_beacon = [4]Vec3{
        Vec3.init(-0.038, 1.185, -0.038),
        Vec3.init(0.038, 1.185, -0.038),
        Vec3.init(0.038, 1.185, 0.038),
        Vec3.init(-0.038, 1.185, 0.038),
    };
    try b.slab(p_beacon, Vec3.init(0, 0.016, 0), beacon_red);

    return b;
}

/// Art-Deco / Stepped Skyscraper:
/// - Stepped tiered silhouette with vertical fluted stone piers
/// - Distinct window columns with warm glowing windows
/// - Gilded pyramid crown with pinnacle beacon
pub fn buildBuildingDeco(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const facade = Vec3.init(1.0, 1.0, 1.0); // tinted by building palette
    const base_col = srgb(58, 62, 70);
    const win_gold = Vec3.init(1.70, 1.45, 0.85); // glowing golden art-deco windows
    const win_cyan = Vec3.init(0.70, 1.10, 1.45);
    const gold_trim = Vec3.init(1.80, 1.40, 0.40); // gilded crown & pinnacle
    const beacon_red = Vec3.init(3.6, 0.35, 0.25);

    // 1. Plinth / Ground Entrance (`y in [0.0, 0.12]`, `x,z in [-0.50, 0.50]`)
    const p_base = [4]Vec3{
        Vec3.init(-0.50, 0.06, -0.50),
        Vec3.init(0.50, 0.06, -0.50),
        Vec3.init(0.50, 0.06, 0.50),
        Vec3.init(-0.50, 0.06, 0.50),
    };
    try b.slab(p_base, Vec3.init(0, 0.06, 0), base_col);

    // Gilded grand entrance archway
    const p_arch = [4]Vec3{
        Vec3.init(-0.14, 0.06, -0.515),
        Vec3.init(0.14, 0.06, -0.515),
        Vec3.init(0.14, 0.06, -0.495),
        Vec3.init(-0.14, 0.06, -0.495),
    };
    try b.slab(p_arch, Vec3.init(0, 0.055, 0), gold_trim);

    // 2. Tier 1 Core (`y in [0.12, 0.55]`, `x,z in [-0.46, 0.46]`)
    const p_t1 = [4]Vec3{
        Vec3.init(-0.46, 0.335, -0.46),
        Vec3.init(0.46, 0.335, -0.46),
        Vec3.init(0.46, 0.335, 0.46),
        Vec3.init(-0.46, 0.335, 0.46),
    };
    try b.slab(p_t1, Vec3.init(0, 0.215, 0), facade);

    // Tier 1 windows (5 floors of 3 vertical bays)
    const t1_ys = [_]f32{ 0.18, 0.26, 0.34, 0.42, 0.50 };
    const t1_xs = [_]f32{ -0.28, 0.0, 0.28 };
    for (t1_ys, 0..) |fy, f_idx| {
        for (t1_xs, 0..) |wx, c_idx| {
            const col = if ((f_idx + c_idx) % 2 == 0) win_gold else win_cyan;
            // North & South
            inline for (.{ @as(f32, -0.468), @as(f32, 0.468) }) |fz| {
                const p_w = [4]Vec3{
                    Vec3.init(wx - 0.08, fy, fz - 0.005),
                    Vec3.init(wx + 0.08, fy, fz - 0.005),
                    Vec3.init(wx + 0.08, fy, fz + 0.005),
                    Vec3.init(wx - 0.08, fy, fz + 0.005),
                };
                try b.slab(p_w, Vec3.init(0, 0.026, 0), col);
            }
            // East & West
            inline for (.{ @as(f32, -0.468), @as(f32, 0.468) }) |fx| {
                const p_w = [4]Vec3{
                    Vec3.init(fx - 0.005, fy, wx - 0.08),
                    Vec3.init(fx + 0.005, fy, wx - 0.08),
                    Vec3.init(fx + 0.005, fy, wx + 0.08),
                    Vec3.init(fx - 0.005, fy, wx + 0.08),
                };
                try b.slab(p_w, Vec3.init(0, 0.026, 0), col);
            }
        }
    }

    // 3. Tier 2 Setback (`y in [0.55, 0.80]`, `x,z in [-0.34, 0.34]`)
    const p_t2 = [4]Vec3{
        Vec3.init(-0.34, 0.675, -0.34),
        Vec3.init(0.34, 0.675, -0.34),
        Vec3.init(0.34, 0.675, 0.34),
        Vec3.init(-0.34, 0.675, 0.34),
    };
    try b.slab(p_t2, Vec3.init(0, 0.125, 0), facade);

    const t2_ys = [_]f32{ 0.60, 0.68, 0.76 };
    const t2_xs = [_]f32{ -0.18, 0.18 };
    for (t2_ys) |fy| {
        for (t2_xs) |wx| {
            inline for (.{ @as(f32, -0.348), @as(f32, 0.348) }) |fz| {
                const p_w = [4]Vec3{
                    Vec3.init(wx - 0.07, fy, fz - 0.005),
                    Vec3.init(wx + 0.07, fy, fz - 0.005),
                    Vec3.init(wx + 0.07, fy, fz + 0.005),
                    Vec3.init(wx - 0.07, fy, fz + 0.005),
                };
                try b.slab(p_w, Vec3.init(0, 0.025, 0), win_gold);
            }
            inline for (.{ @as(f32, -0.348), @as(f32, 0.348) }) |fx| {
                const p_w = [4]Vec3{
                    Vec3.init(fx - 0.005, fy, wx - 0.07),
                    Vec3.init(fx + 0.005, fy, wx - 0.07),
                    Vec3.init(fx + 0.005, fy, wx + 0.07),
                    Vec3.init(fx - 0.005, fy, wx + 0.07),
                };
                try b.slab(p_w, Vec3.init(0, 0.025, 0), win_gold);
            }
        }
    }

    // 4. Tier 3 Setback (`y in [0.80, 0.94]`, `x,z in [-0.22, 0.22]`)
    const p_t3 = [4]Vec3{
        Vec3.init(-0.22, 0.87, -0.22),
        Vec3.init(0.22, 0.87, -0.22),
        Vec3.init(0.22, 0.87, 0.22),
        Vec3.init(-0.22, 0.87, 0.22),
    };
    try b.slab(p_t3, Vec3.init(0, 0.07, 0), facade);

    // Gilded pyramid crown (`y in [0.94, 1.05]`)
    const p_pyr = [4]Vec3{
        Vec3.init(-0.14, 0.995, -0.14),
        Vec3.init(0.14, 0.995, -0.14),
        Vec3.init(0.14, 0.995, 0.14),
        Vec3.init(-0.14, 0.995, 0.14),
    };
    try b.slab(p_pyr, Vec3.init(0, 0.055, 0), gold_trim);

    // Spire pinnacle with aviation beacon
    const p_spire = [4]Vec3{
        Vec3.init(-0.02, 1.09, -0.02),
        Vec3.init(0.02, 1.09, -0.02),
        Vec3.init(0.02, 1.09, 0.02),
        Vec3.init(-0.02, 1.09, 0.02),
    };
    try b.slab(p_spire, Vec3.init(0, 0.04, 0), gold_trim);

    const p_beacon = [4]Vec3{
        Vec3.init(-0.035, 1.14, -0.035),
        Vec3.init(0.035, 1.14, -0.035),
        Vec3.init(0.035, 1.14, 0.035),
        Vec3.init(-0.035, 1.14, 0.035),
    };
    try b.slab(p_beacon, Vec3.init(0, 0.015, 0), beacon_red);

    return b;
}

/// Supercarrier (~260 m long, ~56 m wide flight deck at y = 14.5 m, starboard island tower,
/// runway centerline markings, stern threshold bars, 4 arresting wires, catapult track,
/// and 2 parked wingman jets on the starboard apron). Bow points toward -Z.
pub fn buildAircraftCarrier(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const hull_gray = srgb(98, 108, 122);
    const deck_asphalt = srgb(44, 50, 60);
    const island_col = srgb(138, 148, 162);
    const runway_white = srgb(245, 248, 252);
    const catapult_gold = Vec3.init(1.8, 1.35, 0.25);
    const wire_steel = srgb(185, 195, 210);
    const jet_body = srgb(215, 222, 232);
    // Pure white `team_accent` gets multiplied by the instance's team color (Blue vs Red)
    const team_accent = Vec3.init(1.0, 1.0, 1.0);

    // 1. Lower flared carrier hull from bow (-122 m) to stern (+122 m), kept strictly below y = 12.2 m
    // so it NEVER pokes through the flight deck!
    const st = [_][4]f32{
        .{ -122.0, 2.5, 4.8, 5.5 },
        .{ -90.0, 14.5, 5.5, 6.0 },
        .{ 0.0, 18.8, 5.8, 6.0 },
        .{ 92.0, 17.5, 5.5, 6.0 },
        .{ 122.0, 13.5, 5.0, 5.8 },
    };
    var rings: [st.len][6]Vec3 = undefined;
    for (st, 0..) |s, i| rings[i] = Builder.ring(s[0], s[1], s[2], s[3]);
    for (0..st.len - 1) |i| {
        const axis_c = Vec3.init(0, st[i][3], (st[i][0] + st[i + 1][0]) * 0.5);
        for (0..6) |k| {
            const k2 = (k + 1) % 6;
            const col = if (k >= 4) team_accent else hull_gray;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }

    // 2. Wide flat flight deck + angled port-side landing sponson (top surface at y = 14.5 m)
    const main_deck = [4]Vec3{
        Vec3.init(-24.0, 13.2, -130.0),
        Vec3.init(24.0, 13.2, -130.0),
        Vec3.init(24.0, 13.2, 130.0),
        Vec3.init(-24.0, 13.2, 130.0),
    };
    try b.slab(main_deck, Vec3.init(0, 1.3, 0), deck_asphalt);

    const angled_sponson = [4]Vec3{
        Vec3.init(-35.0, 13.15, -35.0),
        Vec3.init(-20.0, 13.15, -85.0),
        Vec3.init(-20.0, 13.15, 85.0),
        Vec3.init(-35.0, 13.15, 45.0),
    };
    try b.slab(angled_sponson, Vec3.init(0, 1.25, 0), deck_asphalt);

    // 3. Team-colored edge stripes along port & starboard flight deck edges
    inline for (.{ @as(f32, -22.5), @as(f32, 22.5) }) |ex| {
        const edge_stripe = [4]Vec3{
            Vec3.init(ex - 1.2, 14.58, -126.0),
            Vec3.init(ex + 1.2, 14.58, -126.0),
            Vec3.init(ex + 1.2, 14.58, 126.0),
            Vec3.init(ex - 1.2, 14.58, 126.0),
        };
        try b.slab(edge_stripe, Vec3.init(0, 0.14, 0), team_accent);
    }

    // 4. Stern runway threshold piano-key bars (`z in [114, 126]`) + 4 arresting gear cables (`z = 55..95`)
    var tx: f32 = -15.0;
    while (tx <= 15.0) : (tx += 5.0) {
        const bar = [4]Vec3{
            Vec3.init(tx - 1.4, 14.60, 114.0),
            Vec3.init(tx + 1.4, 14.60, 114.0),
            Vec3.init(tx + 1.4, 14.60, 126.0),
            Vec3.init(tx - 1.4, 14.60, 126.0),
        };
        try b.slab(bar, Vec3.init(0, 0.12, 0), team_accent);
    }
    const wire_zs = [_]f32{ 52.0, 66.0, 80.0, 94.0 };
    for (wire_zs) |wz| {
        const wire = [4]Vec3{
            Vec3.init(-16.0, 14.62, wz - 0.35),
            Vec3.init(12.0, 14.62, wz - 0.35),
            Vec3.init(12.0, 14.62, wz + 0.35),
            Vec3.init(-16.0, 14.62, wz + 0.35),
        };
        try b.slab(wire, Vec3.init(0, 0.10, 0), wire_steel);
    }

    // 5. Centerline dashed runway markings + glowing bow catapult launch track (`z in [-124, -15]`)
    var dz: f32 = -112.0;
    while (dz <= 102.0) : (dz += 26.0) {
        const dash = [4]Vec3{
            Vec3.init(-0.85, 14.60, dz),
            Vec3.init(0.85, 14.60, dz),
            Vec3.init(0.85, 14.60, dz + 13.0),
            Vec3.init(-0.85, 14.60, dz + 13.0),
        };
        try b.slab(dash, Vec3.init(0, 0.12, 0), runway_white);
    }
    inline for (.{ @as(f32, -3.2), @as(f32, 3.2) }) |cx| {
        const cat_line = [4]Vec3{
            Vec3.init(cx - 0.35, 14.60, -124.0),
            Vec3.init(cx + 0.35, 14.60, -124.0),
            Vec3.init(cx + 0.35, 14.60, -10.0),
            Vec3.init(cx - 0.35, 14.60, -10.0),
        };
        try b.slab(cat_line, Vec3.init(0, 0.11, 0), catapult_gold);
    }

    // 6. Two parked wingman fighter jets on the port/starboard apron (`x = -25.0`, `z = -10.0` and `z = 22.0`)
    const parked_zs = [_]f32{ -12.0, 22.0 };
    for (parked_zs) |pz| {
        const j_fuse = [4]Vec3{
            Vec3.init(-27.2, 15.6, pz - 5.5),
            Vec3.init(-25.2, 15.6, pz - 5.5),
            Vec3.init(-25.2, 15.6, pz + 5.5),
            Vec3.init(-27.2, 15.6, pz + 5.5),
        };
        try b.slab(j_fuse, Vec3.init(0, 0.85, 0), jet_body);
        const j_wing = [4]Vec3{
            Vec3.init(-31.5, 15.5, pz - 1.0),
            Vec3.init(-21.0, 15.5, pz - 1.0),
            Vec3.init(-21.0, 15.5, pz + 3.2),
            Vec3.init(-31.5, 15.5, pz + 3.2),
        };
        try b.slab(j_wing, Vec3.init(0, 0.25, 0), team_accent);
    }

    // 7. Starboard-side command island superstructure + bridge windows + radar tower
    const island_base = [4]Vec3{
        Vec3.init(15.0, 21.0, -18.0),
        Vec3.init(23.5, 21.0, -18.0),
        Vec3.init(23.5, 21.0, 32.0),
        Vec3.init(15.0, 21.0, 32.0),
    };
    try b.slab(island_base, Vec3.init(0, 6.5, 0), island_col);

    const island_bridge = [4]Vec3{
        Vec3.init(15.8, 30.0, -12.0),
        Vec3.init(22.8, 30.0, -12.0),
        Vec3.init(22.8, 30.0, 16.0),
        Vec3.init(15.8, 30.0, 16.0),
    };
    try b.slab(island_bridge, Vec3.init(0, 3.2, 0), team_accent);

    const radar_mast = [4]Vec3{
        Vec3.init(18.0, 37.5, -4.0),
        Vec3.init(21.0, 37.5, -4.0),
        Vec3.init(21.0, 37.5, 4.0),
        Vec3.init(18.0, 37.5, 4.0),
    };
    try b.slab(radar_mast, Vec3.init(0, 5.0, 0), runway_white);

    return b;
}

/// Evil atmospheric combat airship / blimp (~68 m long, ~19 m diameter gas envelope,
/// 4 cruciform empennage fins, underslung control gondola, and prominent glowing red
/// "EVIL" lettering emblazoned along both port and starboard flanks).
pub fn buildEvilBlimp(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const hull_dark = srgb(42, 46, 56); // sinister charcoal
    const hull_accent = srgb(75, 25, 30); // deep crimson underbelly
    const evil_red = Vec3.init(4.5, 0.35, 0.25); // glowing evil red lettering
    const fin_col = srgb(55, 60, 72);
    const win_gold = Vec3.init(2.8, 2.2, 0.4);

    // 1. Gas envelope hull: 7 aerodynamic stations along Z from nose (-34 m) to tail (+32 m)
    const st = [_][4]f32{
        .{ -34.0, 2.2, 2.2, 0.0 }, // nose cone cap
        .{ -24.0, 7.5, 7.5, 0.0 }, // front taper
        .{ -10.0, 9.6, 9.6, 0.0 }, // forward mid-body
        .{ 0.0, 9.8, 9.8, 0.0 }, // center body
        .{ 12.0, 9.2, 9.2, 0.0 }, // aft mid-body
        .{ 24.0, 6.2, 6.2, 0.0 }, // tail taper
        .{ 32.0, 1.8, 1.8, 0.0 }, // stern cap
    };

    var rings: [st.len][8]Vec3 = undefined;
    for (st, 0..) |s, i| {
        for (0..8) |k| {
            const a = @as(f32, @floatFromInt(k)) * std.math.pi / 4.0;
            rings[i][k] = Vec3.init(@cos(a) * s[1], s[3] + @sin(a) * s[2], s[0]);
        }
    }

    for (0..st.len - 1) |i| {
        const mid_z = (st[i][0] + st[i + 1][0]) * 0.5;
        const axis_c = Vec3.init(0, 0, mid_z);
        for (0..8) |k| {
            const k2 = (k + 1) % 8;
            // Crimson underbelly at bottom (k == 5, 6)
            const col = if (k == 5 or k == 6) hull_accent else hull_dark;
            try b.quad(rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k], col, axis_c);
        }
    }

    // 2. Empennage stabilizer fins at tail (z in [16.0, 31.0])
    inline for (.{ @as(f32, 1.0), @as(f32, -1.0) }) |sign| {
        // Vertical dorsal & ventral fins
        const fin_v = [4]Vec3{
            Vec3.init(-0.25, sign * 5.0, 16.0),
            Vec3.init(0.25, sign * 5.0, 16.0),
            Vec3.init(0.25, sign * 14.5, 30.5),
            Vec3.init(-0.25, sign * 14.5, 30.5),
        };
        try b.slab(fin_v, Vec3.init(0, sign * 0.2, 0), fin_col);

        // Horizontal port & starboard fins
        const fin_h = [4]Vec3{
            Vec3.init(sign * 5.0, -0.25, 16.0),
            Vec3.init(sign * 14.5, -0.25, 30.5),
            Vec3.init(sign * 14.5, 0.25, 30.5),
            Vec3.init(sign * 5.0, 0.25, 16.0),
        };
        try b.slab(fin_h, Vec3.init(sign * 0.2, 0, 0), fin_col);
    }

    // 3. Underslung command gondola cabin (y in [-12.2, -9.8], z in [-11.0, 7.0])
    const gondola = [4]Vec3{
        Vec3.init(-2.2, -12.2, -11.0),
        Vec3.init(2.2, -12.2, -11.0),
        Vec3.init(2.2, -12.2, 7.0),
        Vec3.init(-2.2, -12.2, 7.0),
    };
    try b.slab(gondola, Vec3.init(0, 2.4, 0), srgb(65, 70, 82));

    // Illuminated observation windows on gondola
    inline for (.{ @as(f32, -2.25), @as(f32, 2.25) }) |gx| {
        var wz: f32 = -9.0;
        while (wz <= 5.0) : (wz += 3.2) {
            const p_win = [4]Vec3{
                Vec3.init(gx, -11.4, wz - 1.1),
                Vec3.init(gx, -11.4, wz + 1.1),
                Vec3.init(gx, -10.4, wz + 1.1),
                Vec3.init(gx, -10.4, wz - 1.1),
            };
            try b.slab(p_win, Vec3.init(0.08, 0, 0), win_gold);
        }
    }

    // 4. Bold glowing red "EVIL" lettering emblazoned along both port and starboard flanks!
    // Letters: E - V - I - L (char_w = 4.2m, char_h = 6.2m, spacing = 1.6m, total span = ~22m)
    const text = "EVIL";
    const char_w: f32 = 4.2;
    const char_h: f32 = 6.2;
    const char_sp: f32 = 1.6;
    const pw = char_w / 3.0;
    const ph = char_h / 5.0;
    const x_offset: f32 = 9.85;

    // Starboard flank (+X): observer faces -X; Left is +Z, Right is -Z.
    // Letters advance from left (+Z) to right (-Z).
    const z_start_stbd: f32 = 11.0;
    for (text, 0..) |ch, ci| {
        const glyph = getGlyph(ch);
        const cz = z_start_stbd - @as(f32, @floatFromInt(ci)) * (char_w + char_sp);
        for (glyph, 0..) |bits, row_idx| {
            if (bits == 0) continue;
            const y0 = -2.8 + (4.0 - @as(f32, @floatFromInt(row_idx))) * ph;
            const y1 = y0 + ph;
            inline for (0..3) |col_idx| {
                const mask: u3 = @as(u3, 1) << @as(u2, @intCast(2 - col_idx));
                if ((bits & mask) != 0) {
                    const z1 = cz - @as(f32, @floatFromInt(col_idx)) * pw;
                    const z0 = z1 - pw;
                    const p_quad = [4]Vec3{
                        Vec3.init(x_offset, y0, z0),
                        Vec3.init(x_offset, y0, z1),
                        Vec3.init(x_offset, y1, z1),
                        Vec3.init(x_offset, y1, z0),
                    };
                    try b.slab(p_quad, Vec3.init(0.20, 0, 0), evil_red);
                }
            }
        }
    }

    // Port flank (-X): observer faces +X; Left is -Z, Right is +Z.
    // Letters advance from left (-Z) to right (+Z).
    const z_start_port: f32 = -11.0;
    for (text, 0..) |ch, ci| {
        const glyph = getGlyph(ch);
        const cz = z_start_port + @as(f32, @floatFromInt(ci)) * (char_w + char_sp);
        for (glyph, 0..) |bits, row_idx| {
            if (bits == 0) continue;
            const y0 = -2.8 + (4.0 - @as(f32, @floatFromInt(row_idx))) * ph;
            const y1 = y0 + ph;
            inline for (0..3) |col_idx| {
                const mask: u3 = @as(u3, 1) << @as(u2, @intCast(2 - col_idx));
                if ((bits & mask) != 0) {
                    const z0 = cz + @as(f32, @floatFromInt(col_idx)) * pw;
                    const z1 = z0 + pw;
                    const p_quad = [4]Vec3{
                        Vec3.init(-x_offset, y0, z1),
                        Vec3.init(-x_offset, y0, z0),
                        Vec3.init(-x_offset, y1, z0),
                        Vec3.init(-x_offset, y1, z1),
                    };
                    try b.slab(p_quad, Vec3.init(-0.20, 0, 0), evil_red);
                }
            }
        }
    }

    return b;
}

/// Builds a military base compound foundation slab with concrete perimeter, tarmac apron,
/// and team-colored tactical runway markings.
pub fn buildMilitaryCompound(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const tarmac_col = srgb(58, 64, 72);
    const edge_col = srgb(78, 86, 96);
    const hw: f32 = 120.0;
    const hl: f32 = 90.0;

    // 1. Main reinforced concrete compound slab with subterranean foundation skirt
    const p_slab = [4]Vec3{
        Vec3.init(-hw, -2.5, -hl),
        Vec3.init(hw, -2.5, -hl),
        Vec3.init(hw, -2.5, hl),
        Vec3.init(-hw, -2.5, hl),
    };
    try b.slab(p_slab, Vec3.init(0, 3.0, 0), tarmac_col);

    // 2. Concrete perimeter border curb
    const p_edge = [4]Vec3{
        Vec3.init(-hw - 3.0, 0.8, -hl - 3.0),
        Vec3.init(hw + 3.0, 0.8, -hl - 3.0),
        Vec3.init(hw + 3.0, 0.8, hl + 3.0),
        Vec3.init(-hw - 3.0, 0.8, hl + 3.0),
    };
    try b.slab(p_edge, Vec3.init(0, 0.6, 0), edge_col);

    // 3. Team-colored central runway stripe & landing threshold
    const p_stripe = [4]Vec3{
        Vec3.init(-4.0, 0.85, -hl + 8.0),
        Vec3.init(4.0, 0.85, -hl + 8.0),
        Vec3.init(4.0, 0.85, hl - 8.0),
        Vec3.init(-4.0, 0.85, hl - 8.0),
    };
    try b.slab(p_stripe, Vec3.init(0, 0.05, 0), accent);

    // 4. Helipad circle / H-marking pad
    const p_heli = [4]Vec3{
        Vec3.init(65.0, 0.85, -15.0),
        Vec3.init(95.0, 0.85, -15.0),
        Vec3.init(95.0, 0.85, 15.0),
        Vec3.init(65.0, 0.85, 15.0),
    };
    try b.slab(p_heli, Vec3.init(0, 0.05, 0), srgb(180, 185, 195));

    return b;
}

/// Builds a heavy armored command bunker with sloped concrete blast walls,
/// observation visor slit, comms antenna, and team colored insignia.
pub fn buildBunker(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const concrete = srgb(95, 102, 110);
    const armor_plate = srgb(48, 54, 62);
    const visor_glow = Vec3.init(accent.x * 2.2, accent.y * 2.2, accent.z * 2.2);

    // 1. Heavy sloped concrete lower pyramid base (22m x 18m, 4.5m high)
    const base_w: f32 = 11.0;
    const base_l: f32 = 9.0;
    const top_w: f32 = 8.5;
    const top_l: f32 = 7.0;
    const h1: f32 = 4.5;

    // Bottom face
    const b0 = Vec3.init(-base_w, 0, -base_l);
    const b1 = Vec3.init(base_w, 0, -base_l);
    const b2 = Vec3.init(base_w, 0, base_l);
    const b3 = Vec3.init(-base_w, 0, base_l);

    // Intermediate deck
    const t0 = Vec3.init(-top_w, h1, -top_l);
    const t1 = Vec3.init(top_w, h1, -top_l);
    const t2 = Vec3.init(top_w, h1, top_l);
    const t3 = Vec3.init(-top_w, h1, top_l);

    const center = Vec3.init(0, h1 * 0.5, 0);
    try b.quad(t0, t1, b1, b0, concrete, center);
    try b.quad(t1, t2, b2, b1, concrete, center);
    try b.quad(t2, t3, b3, b2, concrete, center);
    try b.quad(t3, t0, b0, b3, concrete, center);
    try b.quad(t0, t1, t2, t3, concrete, center);

    // 2. Armored upper command cupola (12m x 10m, from y=4.5 to y=7.5)
    const p_cupola = [4]Vec3{
        Vec3.init(-6.0, 6.0, -5.0),
        Vec3.init(6.0, 6.0, -5.0),
        Vec3.init(6.0, 6.0, 5.0),
        Vec3.init(-6.0, 6.0, 5.0),
    };
    try b.slab(p_cupola, Vec3.init(0, 1.5, 0), armor_plate);

    // 3. Narrow armored visor slits (emissive visor slit facing front & flanks)
    const p_visor = [4]Vec3{
        Vec3.init(-4.5, 5.8, -5.15),
        Vec3.init(4.5, 5.8, -5.15),
        Vec3.init(4.5, 5.8, -4.95),
        Vec3.init(-4.5, 5.8, -4.95),
    };
    try b.slab(p_visor, Vec3.init(0, 0.35, 0), visor_glow);

    // 4. Team-colored roof accent roundel plate
    const p_roof = [4]Vec3{
        Vec3.init(-4.0, 7.6, -3.5),
        Vec3.init(4.0, 7.6, -3.5),
        Vec3.init(4.0, 7.6, 3.5),
        Vec3.init(-4.0, 7.6, 3.5),
    };
    try b.slab(p_roof, Vec3.init(0, 0.12, 0), accent);

    // 5. Communications mast / sensor array (reaching to y=14.0)
    const p_mast = [4]Vec3{
        Vec3.init(-0.4, 10.5, -0.4),
        Vec3.init(0.4, 10.5, -0.4),
        Vec3.init(0.4, 10.5, 0.4),
        Vec3.init(-0.4, 10.5, 0.4),
    };
    try b.slab(p_mast, Vec3.init(0, 3.0, 0), srgb(180, 190, 205));

    // Blinking beacon on mast tip
    const p_beacon = [4]Vec3{
        Vec3.init(-0.6, 13.8, -0.6),
        Vec3.init(0.6, 13.8, -0.6),
        Vec3.init(0.6, 13.8, 0.6),
        Vec3.init(-0.6, 13.8, 0.6),
    };
    try b.slab(p_beacon, Vec3.init(0, 0.4, 0), Vec3.init(4.5, 3.8, 0.6));

    return b;
}

/// Builds an early-warning radar station with triangular steel lattice gantry,
/// revolving parabolic radar dish, and equipment shelter.
pub fn buildRadarStation(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const steel = srgb(140, 150, 165);
    const shelter_col = srgb(65, 72, 82);
    const dish_col = srgb(220, 226, 235);

    // 1. Concrete equipment shelter base (10m x 8m, 3.5m high)
    const p_base = [4]Vec3{
        Vec3.init(-5.0, 1.75, -4.0),
        Vec3.init(5.0, 1.75, -4.0),
        Vec3.init(5.0, 1.75, 4.0),
        Vec3.init(-5.0, 1.75, 4.0),
    };
    try b.slab(p_base, Vec3.init(0, 1.75, 0), shelter_col);

    // Team accent band on shelter
    const p_band = [4]Vec3{
        Vec3.init(-5.15, 2.6, -4.15),
        Vec3.init(5.15, 2.6, -4.15),
        Vec3.init(5.15, 2.6, 4.15),
        Vec3.init(-5.15, 2.6, 4.15),
    };
    try b.slab(p_band, Vec3.init(0, 0.4, 0), accent);

    // 2. Triangular steel lattice gantry tower (from y=3.5 to y=18.0)
    const p_tower = [4]Vec3{
        Vec3.init(-1.4, 10.75, -1.4),
        Vec3.init(1.4, 10.75, -1.4),
        Vec3.init(1.4, 10.75, 1.4),
        Vec3.init(-1.4, 10.75, 1.4),
    };
    try b.slab(p_tower, Vec3.init(0, 7.25, 0), steel);

    // 3. Parabolic radar reflector dish (angled 35° upward)
    const dish_center = Vec3.init(0, 19.5, 0);
    const dw: f32 = 6.0;
    const dh: f32 = 4.5;
    const p_dish = [4]Vec3{
        dish_center.add(Vec3.init(-dw, -dh * 0.7, -1.5)),
        dish_center.add(Vec3.init(dw, -dh * 0.7, -1.5)),
        dish_center.add(Vec3.init(dw * 0.85, dh, 1.8)),
        dish_center.add(Vec3.init(-dw * 0.85, dh, 1.8)),
    };
    try b.slab(p_dish, Vec3.init(0, 0.25, 0.35), dish_col);

    // Feed horn protruding forward
    const p_horn = [4]Vec3{
        dish_center.add(Vec3.init(-0.4, 0.2, -3.8)),
        dish_center.add(Vec3.init(0.4, 0.2, -3.8)),
        dish_center.add(Vec3.init(0.4, 0.8, -3.8)),
        dish_center.add(Vec3.init(-0.4, 0.8, -3.8)),
    };
    try b.slab(p_horn, Vec3.init(0, 0, 1.8), accent);

    return b;
}

/// Builds an aircraft hangar shelter with curved corrugated Quonset roof,
/// open entrance bay, and team identification banners.
pub fn buildHangar(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const metal_wall = srgb(108, 116, 126);
    const roof_panel = srgb(135, 145, 158);
    const interior_floor = srgb(45, 50, 56);
    const hazard_yellow = Vec3.init(3.8, 3.2, 0.4);

    const hw: f32 = 13.0; // half-width (26m total)
    const hl: f32 = 16.0; // half-length (32m total)
    const wall_h: f32 = 5.0;
    const apex_h: f32 = 10.5;

    // 1. Interior floor
    const p_floor = [4]Vec3{
        Vec3.init(-hw, 0.2, -hl),
        Vec3.init(hw, 0.2, -hl),
        Vec3.init(hw, 0.2, hl),
        Vec3.init(-hw, 0.2, hl),
    };
    try b.slab(p_floor, Vec3.init(0, 0.2, 0), interior_floor);

    // 2. Side vertical walls
    const p_left_wall = [4]Vec3{
        Vec3.init(-hw, wall_h * 0.5, -hl),
        Vec3.init(-hw + 0.8, wall_h * 0.5, -hl),
        Vec3.init(-hw + 0.8, wall_h * 0.5, hl),
        Vec3.init(-hw, wall_h * 0.5, hl),
    };
    try b.slab(p_left_wall, Vec3.init(0, wall_h * 0.5, 0), metal_wall);

    const p_right_wall = [4]Vec3{
        Vec3.init(hw - 0.8, wall_h * 0.5, -hl),
        Vec3.init(hw, wall_h * 0.5, -hl),
        Vec3.init(hw, wall_h * 0.5, hl),
        Vec3.init(hw - 0.8, wall_h * 0.5, hl),
    };
    try b.slab(p_right_wall, Vec3.init(0, wall_h * 0.5, 0), metal_wall);

    // 3. Arched pitched roof
    const r_left = [4]Vec3{
        Vec3.init(-hw - 0.5, wall_h, -hl - 0.5),
        Vec3.init(0, apex_h, -hl - 0.5),
        Vec3.init(0, apex_h, hl + 0.5),
        Vec3.init(-hw - 0.5, wall_h, hl + 0.5),
    };
    try b.slab(r_left, Vec3.init(-0.25, 0.35, 0), roof_panel);

    const r_right = [4]Vec3{
        Vec3.init(0, apex_h, -hl - 0.5),
        Vec3.init(hw + 0.5, wall_h, -hl - 0.5),
        Vec3.init(hw + 0.5, wall_h, hl + 0.5),
        Vec3.init(0, apex_h, hl + 0.5),
    };
    try b.slab(r_right, Vec3.init(0.25, 0.35, 0), roof_panel);

    // 4. Rear gable wall (closed at +hl)
    const p_rear = [4]Vec3{
        Vec3.init(-hw, wall_h * 0.5, hl),
        Vec3.init(hw, wall_h * 0.5, hl),
        Vec3.init(0, apex_h, hl),
        Vec3.init(0, apex_h, hl),
    };
    try b.slab(p_rear, Vec3.init(0, 0, 0.5), metal_wall);

    // 5. Team identification banner across roof ridge
    const p_banner = [4]Vec3{
        Vec3.init(-5.0, apex_h + 0.25, -6.0),
        Vec3.init(5.0, apex_h + 0.25, -6.0),
        Vec3.init(5.0, apex_h + 0.25, 6.0),
        Vec3.init(-5.0, apex_h + 0.25, 6.0),
    };
    try b.slab(p_banner, Vec3.init(0, 0.15, 0), accent);

    // 6. Front entrance hazard line
    const p_haz = [4]Vec3{
        Vec3.init(-hw, 0.35, -hl - 0.5),
        Vec3.init(hw, 0.35, -hl - 0.5),
        Vec3.init(hw, 0.35, -hl + 0.5),
        Vec3.init(-hw, 0.35, -hl + 0.5),
    };
    try b.slab(p_haz, Vec3.init(0, 0.08, 0), hazard_yellow);

    return b;
}

/// Builds a surface-to-air missile (SAM) launcher battery with octagonal revetment,
/// revolving launcher turret, and twin elevated surface-to-air missiles.
pub fn buildSamBattery(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const revetment_col = srgb(85, 92, 100);
    const turret_col = srgb(48, 54, 62);
    const missile_white = srgb(235, 238, 245);

    // 1. Octagonal concrete / sandbag blast revetment berm (14m diameter, 2m high)
    const p_rev = [4]Vec3{
        Vec3.init(-7.0, 1.0, -7.0),
        Vec3.init(7.0, 1.0, -7.0),
        Vec3.init(7.0, 1.0, 7.0),
        Vec3.init(-7.0, 1.0, 7.0),
    };
    try b.slab(p_rev, Vec3.init(0, 1.0, 0), revetment_col);

    // 2. Revolving launcher pedestal (turret base)
    const p_ped = [4]Vec3{
        Vec3.init(-3.0, 2.5, -3.0),
        Vec3.init(3.0, 2.5, -3.0),
        Vec3.init(3.0, 2.5, 3.0),
        Vec3.init(-3.0, 2.5, 3.0),
    };
    try b.slab(p_ped, Vec3.init(0, 0.6, 0), turret_col);

    // Team accent ring around turret
    const p_ring = [4]Vec3{
        Vec3.init(-3.2, 2.8, -3.2),
        Vec3.init(3.2, 2.8, -3.2),
        Vec3.init(3.2, 2.8, 3.2),
        Vec3.init(-3.2, 2.8, 3.2),
    };
    try b.slab(p_ring, Vec3.init(0, 0.15, 0), accent);

    // 3. Elevating twin missile launcher rack (angled 40° upward)
    inline for (.{ @as(f32, -1.8), @as(f32, 1.8) }) |msx| {
        // Missile rail
        const r_start = Vec3.init(msx, 3.2, 2.5);
        const r_end = Vec3.init(msx, 6.8, -3.5);
        const p_rail = [4]Vec3{
            r_start.add(Vec3.init(-0.3, 0, 0)),
            r_start.add(Vec3.init(0.3, 0, 0)),
            r_end.add(Vec3.init(0.3, 0, 0)),
            r_end.add(Vec3.init(-0.3, 0, 0)),
        };
        try b.slab(p_rail, Vec3.init(0, 0.25, 0), turret_col);

        // Missile body
        const m_pos = Vec3.lerp(r_start, r_end, 0.5).add(Vec3.init(0, 0.45, 0));
        const p_missile = [4]Vec3{
            m_pos.add(Vec3.init(-0.4, -0.4, 2.8)),
            m_pos.add(Vec3.init(0.4, -0.4, 2.8)),
            m_pos.add(Vec3.init(0.4, 0.4, -3.8)),
            m_pos.add(Vec3.init(-0.4, 0.4, -3.8)),
        };
        try b.slab(p_missile, Vec3.init(0, 0.35, 0), missile_white);

        // Team colored warhead & delta fins
        const p_fins = [4]Vec3{
            m_pos.add(Vec3.init(-1.2, 0, 2.4)),
            m_pos.add(Vec3.init(1.2, 0, 2.4)),
            m_pos.add(Vec3.init(1.2, 0, 1.4)),
            m_pos.add(Vec3.init(-1.2, 0, 1.4)),
        };
        try b.slab(p_fins, Vec3.init(0, 0.8, 0), accent);
    }

    return b;
}

/// Builds a military fuel depot with reinforced concrete retention dyke basin,
/// dual pressurized fuel storage tanks, catwalk, and hazard diamond placards.
pub fn buildFuelDepot(alloc: std.mem.Allocator, accent: Vec3) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const dyke_col = srgb(85, 92, 100);
    const tank_col = srgb(195, 202, 212);
    const hazard_red = Vec3.init(4.2, 0.4, 0.3);

    // 1. Concrete containment dyke basin (18m x 14m, 1.5m wall)
    const p_dyke = [4]Vec3{
        Vec3.init(-9.0, 0.75, -7.0),
        Vec3.init(9.0, 0.75, -7.0),
        Vec3.init(9.0, 0.75, 7.0),
        Vec3.init(-9.0, 0.75, 7.0),
    };
    try b.slab(p_dyke, Vec3.init(0, 0.75, 0), dyke_col);

    // 2. Dual cylindrical fuel storage tanks (each 5m diameter, 12m length)
    inline for (.{ @as(f32, -4.2), @as(f32, 4.2) }) |tx| {
        const p_tank = [4]Vec3{
            Vec3.init(tx - 2.5, 3.8, -5.5),
            Vec3.init(tx + 2.5, 3.8, -5.5),
            Vec3.init(tx + 2.5, 3.8, 5.5),
            Vec3.init(tx - 2.5, 3.8, 5.5),
        };
        try b.slab(p_tank, Vec3.init(0, 2.5, 0), tank_col);

        // Team identification stripe around tank
        const p_stripe = [4]Vec3{
            Vec3.init(tx - 2.6, 3.8, -1.0),
            Vec3.init(tx + 2.6, 3.8, -1.0),
            Vec3.init(tx + 2.6, 3.8, 1.0),
            Vec3.init(tx - 2.6, 3.8, 1.0),
        };
        try b.slab(p_stripe, Vec3.init(0, 2.6, 0), accent);

        // Flammable hazard diamond on tank end (-Z)
        const p_haz = [4]Vec3{
            Vec3.init(tx - 0.9, 3.8, -5.65),
            Vec3.init(tx + 0.9, 3.8, -5.65),
            Vec3.init(tx + 0.9, 3.8, -5.55),
            Vec3.init(tx - 0.9, 3.8, -5.55),
        };
        try b.slab(p_haz, Vec3.init(0, 0.9, 0), hazard_red);
    }

    return b;
}

/// Builds a heavy aerial demolition bomb with aerodynamic casing,
/// mechanical impact fuze, cruciform stabilizer tail fins with ring,
/// and yellow explosive filler hazard bands.
pub fn buildBomb(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();

    const body_col = srgb(64, 76, 56); // military olive-drab
    const fin_col = srgb(42, 50, 38); // dark military steel
    const hazard_yellow = Vec3.init(4.2, 3.6, 0.5); // glowing explosive filler stripe
    const fuze_steel = srgb(210, 215, 225); // mechanical impact fuze

    // Station geometry along Z (nose at -Z, tail at +Z)
    // Total length ~3.2m, diameter ~0.60m
    const stations = [_]struct { z: f32, r: f32, col: Vec3 }{
        .{ .z = -1.65, .r = 0.04, .col = fuze_steel }, // fuze vane tip
        .{ .z = -1.45, .r = 0.18, .col = fuze_steel }, // fuze collar
        .{ .z = -1.15, .r = 0.32, .col = hazard_yellow }, // yellow nose hazard stripe
        .{ .z = -0.90, .r = 0.34, .col = body_col }, // main cylindrical body
        .{ .z = 0.00, .r = 0.34, .col = body_col }, // center of gravity
        .{ .z = 0.65, .r = 0.32, .col = hazard_yellow }, // mid hazard stripe
        .{ .z = 1.15, .r = 0.22, .col = body_col }, // boat-tail taper
        .{ .z = 1.45, .r = 0.14, .col = fin_col }, // tail fin root
    };

    const num_sides: usize = 8;
    for (0..stations.len - 1) |i| {
        const s0 = stations[i];
        const s1 = stations[i + 1];

        for (0..num_sides) |si| {
            const a0 = @as(f32, @floatFromInt(si)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(num_sides)));
            const a1 = @as(f32, @floatFromInt(si + 1)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(num_sides)));

            const c0 = @cos(a0);
            const sn0 = @sin(a0);
            const c1 = @cos(a1);
            const sn1 = @sin(a1);

            const v00 = Vec3.init(c0 * s0.r, sn0 * s0.r, s0.z);
            const v10 = Vec3.init(c1 * s0.r, sn1 * s0.r, s0.z);
            const v11 = Vec3.init(c1 * s1.r, sn1 * s1.r, s1.z);
            const v01 = Vec3.init(c0 * s1.r, sn0 * s1.r, s1.z);

            const mid_col = Vec3.lerp(s0.col, s1.col, 0.5);
            try b.quad(v00, v10, v11, v01, mid_col, Vec3.init(0, 0, (s0.z + s1.z) * 0.5));
        }
    }

    // 4 Cruciform tail stabilizer fins (+X, -X, +Y, -Y) from z=0.8 to z=1.55
    const fin_span: f32 = 0.65;
    // Horizontal fin pair
    const p_fin_h = [4]Vec3{
        Vec3.init(-fin_span, 0, 0.85),
        Vec3.init(fin_span, 0, 0.85),
        Vec3.init(fin_span, 0, 1.55),
        Vec3.init(-fin_span, 0, 1.55),
    };
    try b.slab(p_fin_h, Vec3.init(0, 0.02, 0), fin_col);

    // Vertical fin pair
    const p_fin_v = [4]Vec3{
        Vec3.init(0, -fin_span, 0.85),
        Vec3.init(0, fin_span, 0.85),
        Vec3.init(0, fin_span, 1.55),
        Vec3.init(0, -fin_span, 1.55),
    };
    try b.slab(p_fin_v, Vec3.init(0.02, 0, 0), fin_col);

    // Circular/octagonal tail fin shroud ring at z=1.45
    const ring_r: f32 = 0.52;
    for (0..num_sides) |si| {
        const a0 = @as(f32, @floatFromInt(si)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(num_sides)));
        const a1 = @as(f32, @floatFromInt(si + 1)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(num_sides)));

        const c0 = @cos(a0);
        const sn0 = @sin(a0);
        const c1 = @cos(a1);
        const sn1 = @sin(a1);

        const r0 = Vec3.init(c0 * ring_r, sn0 * ring_r, 1.35);
        const r1 = Vec3.init(c1 * ring_r, sn1 * ring_r, 1.35);
        const r2 = Vec3.init(c1 * ring_r, sn1 * ring_r, 1.55);
        const r3 = Vec3.init(c0 * ring_r, sn0 * ring_r, 1.55);

        try b.quad(r0, r1, r2, r3, fin_col, Vec3.init(0, 0, 1.45));
    }

    return b;
}

test "tactical radar scope and sweep geometry" {
    const alloc = std.testing.allocator;
    var scope = try buildTacticalRadarFrame(alloc);
    defer scope.deinit();

    try std.testing.expect(scope.verts.items.len > 0);
    try std.testing.expect(scope.indices.items.len > 0);

    var box = try buildBox(alloc);
    defer box.deinit();

    var min_y: f32 = 999.0;
    var max_y: f32 = -999.0;
    for (box.verts.items) |v| {
        if (v.pos[1] < min_y) min_y = v.pos[1];
        if (v.pos[1] > max_y) max_y = v.pos[1];
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), min_y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), max_y, 1e-4);
}

