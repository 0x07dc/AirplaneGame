//! Procedural low-poly meshes (flat shaded, vertex colored).
const std = @import("std");
const m = @import("math.zig");
const Vec3 = m.Vec3;

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
pub fn buildPlane(alloc: std.mem.Allocator) !Builder {
    var b = Builder.init(alloc);
    errdefer b.deinit();
    const body = srgb(232, 238, 244);
    const body2 = srgb(196, 206, 218);
    const accent = srgb(255, 90, 54);
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
