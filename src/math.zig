//! Minimal math: Vec3, Quat, Mat4 (column-major, Vulkan clip conventions).
//! Coordinate convention: right-handed, +X right, +Y up, -Z forward.
const std = @import("std");

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const up: Vec3 = .{ .y = 1 };
    pub const forward: Vec3 = .{ .z = -1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn len(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }
    pub fn norm(a: Vec3) Vec3 {
        const l = a.len();
        return if (l > 1e-12) a.scale(1.0 / l) else a;
    }
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
};

pub const Quat = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};

    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const h = angle * 0.5;
        const s = @sin(h);
        const a = axis.norm();
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s, .w = @cos(h) };
    }
    /// Hamilton product: apply `b` first, then `a`.
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        };
    }
    pub fn normalize(q: Quat) Quat {
        const l = @sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (l < 1e-12) return identity;
        const i = 1.0 / l;
        return .{ .x = q.x * i, .y = q.y * i, .z = q.z * i, .w = q.w * i };
    }
    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const u = Vec3{ .x = q.x, .y = q.y, .z = q.z };
        // v' = v + w*t + u×t, where t = 2 (u×v)
        const t = u.cross(v).scale(2.0);
        return v.add(t.scale(q.w)).add(u.cross(t));
    }
    /// Shortest-path normalized lerp.
    pub fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        const d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
        const s: f32 = if (d < 0) -1 else 1;
        return (Quat{
            .x = a.x + (b.x * s - a.x) * t,
            .y = a.y + (b.y * s - a.y) * t,
            .z = a.z + (b.z * s - a.z) * t,
            .w = a.w + (b.w * s - a.w) * t,
        }).normalize();
    }
};

pub const Mat4 = struct {
    /// Column-major: m[col * 4 + row].
    m: [16]f32,

    pub const identity: Mat4 = .{ .m = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var s: f32 = 0;
                for (0..4) |k| s += a.m[k * 4 + row] * b.m[col * 4 + k];
                r.m[col * 4 + row] = s;
            }
        }
        return r;
    }

    /// Vulkan clip space (y down, z in 0..1), right-handed view looking down -Z.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_y * 0.5);
        var r = Mat4{ .m = [_]f32{0} ** 16 };
        r.m[0] = f / aspect;
        r.m[5] = -f;
        r.m[10] = far / (near - far);
        r.m[11] = -1;
        r.m[14] = near * far / (near - far);
        return r;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).norm();
        const s = f.cross(up).norm();
        const u = s.cross(f);
        return .{ .m = .{
            s.x,           u.x,           -f.x,         0,
            s.y,           u.y,           -f.y,         0,
            s.z,           u.z,           -f.z,         0,
            -s.dot(eye),   -u.dot(eye),   f.dot(eye),   1,
        } };
    }

    /// Model matrix (T * R * S). The otherwise-unused bottom row of the first
    /// three columns carries an RGB tint to the shader (see shaders/mesh.vert).
    pub fn model(pos: Vec3, scl: Vec3, rot: Quat, tint: Vec3) Mat4 {
        const cx = rot.rotate(Vec3.init(1, 0, 0)).scale(scl.x);
        const cy = rot.rotate(Vec3.init(0, 1, 0)).scale(scl.y);
        const cz = rot.rotate(Vec3.init(0, 0, 1)).scale(scl.z);
        return .{ .m = .{
            cx.x, cx.y, cx.z, tint.x,
            cy.x, cy.y, cy.z, tint.y,
            cz.x, cz.y, cz.z, tint.z,
            pos.x, pos.y, pos.z, 1,
        } };
    }
};

pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}
pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
}
pub fn lerpf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
pub fn radians(deg: f32) f32 {
    return deg * std.math.pi / 180.0;
}
