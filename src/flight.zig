//! Flight model + chase camera. See docs/FLIGHT_MODEL.md for the design intent.
//!
//! Key idea: the *nose* is controlled directly (rate-commanded, ultra snappy),
//! while the *velocity vector* chases the nose with a "grip" factor. High grip =
//! on rails; losing grip (high angle of attack / low energy) lets the plane slide
//! and pivot, which skilled pilots exploit.
const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

pub const Params = struct {
    // Max angular rates (deg/s) about local axes.
    pitch_rate: f32 = 210,
    yaw_rate: f32 = 85,
    roll_rate: f32 = 560,
    /// Time constant of the rate response (smaller = snappier). ~1-2 frames @ 60 Hz.
    response_tau: f32 = 0.05,

    // Speeds (m/s).
    cruise: f32 = 260,
    boost: f32 = 480,
    brake: f32 = 110,
    min_speed: f32 = 70,
    thrust_accel: f32 = 95,
    brake_decel: f32 = 220,

    // Energy model.
    turn_bleed: f32 = 120, // m/s^2 lost at full turn rate
    aoa_drag: f32 = 0.8, // fraction of speed lost per second at 90° AoA
    gravity_k: f32 = 4.0, // exaggerated gravity along flight path

    // Grip: how fast velocity direction chases the nose (1/s).
    grip: f32 = 10,
    min_grip: f32 = 1.2,
    aoa_slide_start_deg: f32 = 20,
    aoa_slide_full_deg: f32 = 70,
};

pub const Input = struct {
    pitch: f32 = 0, // +1 = nose up
    roll: f32 = 0, // +1 = roll right
    yaw: f32 = 0, // +1 = nose right
    boost: bool = false,
    brake: bool = false,
};

pub const Plane = struct {
    params: Params = .{},
    pos: Vec3 = Vec3.init(0, 400, 0),
    rot: Quat = Quat.identity,
    dir: Vec3 = Vec3.forward, // velocity direction
    speed: f32 = 260,
    /// Smoothed local angular rates (rad/s): x = pitch, y = yaw, z = roll.
    rates: Vec3 = Vec3.zero,
    prev_pos: Vec3 = Vec3.init(0, 400, 0),
    prev_rot: Quat = Quat.identity,
    /// Angle between nose and velocity (radians) — exposed for HUD/effects.
    aoa: f32 = 0,
    respawns: u32 = 0,

    pub fn up(_: *const Plane, _: Vec3) Vec3 {
        // World up. On the planet this becomes normalize(pos - planet_center).
        return Vec3.up;
    }

    pub fn respawn(self: *Plane) void {
        const p = self.params;
        self.* = .{ .params = p, .respawns = self.respawns + 1, .speed = p.cruise };
    }

    pub fn step(self: *Plane, dt: f32, in: Input) void {
        const p = self.params;
        self.prev_pos = self.pos;
        self.prev_rot = self.rot;

        // --- 1. Rate-commanded rotation (critically damped-ish response) ---
        const tgt = Vec3.init(
            in.pitch * math.radians(p.pitch_rate),
            -in.yaw * math.radians(p.yaw_rate), // +yaw about +Y turns nose left
            -in.roll * math.radians(p.roll_rate), // +roll about +Z rolls left
        );
        const k = 1.0 - @exp(-dt / p.response_tau);
        self.rates = self.rates.add(tgt.sub(self.rates).scale(k));
        const w = self.rates.len();
        if (w > 1e-6) {
            const dq = Quat.fromAxisAngle(self.rates.scale(1.0 / w), w * dt);
            self.rot = self.rot.mul(dq).normalize(); // local-axis rotation
        }

        // --- 2. Energy / speed ---
        const fwd = self.rot.rotate(Vec3.forward);
        const up_ref = self.up(self.pos);
        const target: f32 = if (in.boost) p.boost else if (in.brake) p.brake else p.cruise;
        if (target > self.speed) {
            self.speed = @min(self.speed + p.thrust_accel * dt, target);
        } else {
            self.speed = @max(self.speed - p.brake_decel * dt, target);
        }
        const turn = math.clamp01(@sqrt(
            (self.rates.x * self.rates.x) / sq(math.radians(p.pitch_rate)) +
                (self.rates.y * self.rates.y) / sq(math.radians(p.yaw_rate)),
        ));
        self.speed -= p.turn_bleed * turn * turn * dt;
        self.speed -= self.dir.dot(up_ref) * 9.81 * p.gravity_k * dt;

        // --- 3. Velocity chases the nose, gated by grip ---
        const cos_aoa = std.math.clamp(self.dir.dot(fwd), -1, 1);
        self.aoa = std.math.acos(cos_aoa);
        const slide = math.smoothstep(math.radians(p.aoa_slide_start_deg), math.radians(p.aoa_slide_full_deg), self.aoa);
        var grip = math.lerpf(p.grip, p.min_grip, slide);
        grip *= math.lerpf(0.25, 1.0, math.clamp01((self.speed - p.min_speed) / 80.0));
        self.dir = Vec3.lerp(self.dir, fwd, 1.0 - @exp(-grip * dt)).norm();
        self.speed -= self.speed * @sin(self.aoa) * p.aoa_drag * dt;
        self.speed = @max(self.speed, p.min_speed);

        // --- 4. Integrate ---
        self.pos = self.pos.add(self.dir.scale(self.speed * dt));

        if (self.pos.y < 3.0) self.respawn();
    }

    pub fn renderPos(self: *const Plane, alpha: f32) Vec3 {
        return Vec3.lerp(self.prev_pos, self.pos, alpha);
    }
    pub fn renderRot(self: *const Plane, alpha: f32) Quat {
        return Quat.nlerp(self.prev_rot, self.rot, alpha);
    }
};

fn sq(x: f32) f32 {
    return x * x;
}

pub const Camera = struct {
    pos: Vec3 = Vec3.init(0, 404, 13),
    up: Vec3 = Vec3.up,
    fov: f32 = math.radians(65),
    eye_view: Mat4 = Mat4.identity,

    /// Chase camera with positional lag (sells speed) and partial roll follow.
    pub fn update(self: *Camera, dt: f32, ppos: Vec3, prot: Quat, speed: f32, p: Params) void {
        const fwd = prot.rotate(Vec3.forward);
        const pup = prot.rotate(Vec3.up);
        const desired = ppos.sub(fwd.scale(13.0)).add(pup.scale(3.5));
        const kp = 1.0 - @exp(-dt / 0.035);
        self.pos = Vec3.lerp(self.pos, desired, kp);

        const want_up = Vec3.up.scale(0.4).add(pup.scale(0.6)).norm();
        const ku = 1.0 - @exp(-dt / 0.12);
        self.up = Vec3.lerp(self.up, want_up, ku).norm();

        const look = ppos.add(fwd.scale(30.0));
        self.eye_view = Mat4.lookAt(self.pos, look, self.up);

        // FOV kick with speed.
        const t = math.clamp01((speed - p.cruise * 0.6) / (p.boost - p.cruise * 0.6));
        const target_fov = math.radians(62 + 28 * t);
        self.fov = math.lerpf(self.fov, target_fov, 1.0 - @exp(-dt / 0.15));
    }

    pub fn forward(self: *const Camera, ppos: Vec3) Vec3 {
        return ppos.sub(self.pos).norm();
    }

    pub fn viewProj(self: *const Camera, aspect: f32) Mat4 {
        return Mat4.perspective(self.fov, aspect, 0.5, 30000.0).mul(self.eye_view);
    }
};
