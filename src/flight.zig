//! Flight model + chase camera on a spherical planet. See docs/FLIGHT_MODEL.md.
//!
//! Key idea: the *nose* is controlled directly (rate-commanded, ultra snappy),
//! while the *velocity vector* chases the nose with a "grip" factor.
//! On a spherical planet:
//! - Local up at position `p` is `normalize(p)`.
//! - As the plane translates around the sphere, its orientation and velocity
//!   transport along the great-circle curvature so level flight naturally
//!   follows the horizon around the globe.
//! - Includes gentle natural auto-leveling (8x slowed) and predictive GCAS
//!   against the spherical terrain/ocean surface.
const std = @import("std");
const math = @import("math.zig");
const planet = @import("planet.zig");
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

pub const Params = struct {
    // Max angular rates (deg/s) about local axes.
    pitch_rate: f32 = 105, // 1/2 up/down speed (was 210)
    yaw_rate: f32 = 85,
    roll_rate: f32 = 280, // 1/2 banking speed (was 560)
    /// Time constant of the rate response (smaller = snappier). ~1-2 frames @ 60 Hz.
    response_tau: f32 = 0.05,

    // Speeds (m/s) — 10x scale for extreme speed feel.
    cruise: f32 = 2600,
    boost: f32 = 4800,
    brake: f32 = 1100,
    min_speed: f32 = 700,
    thrust_accel: f32 = 950,
    brake_decel: f32 = 2200,

    // Energy model (scaled with 10x speed).
    turn_bleed: f32 = 1200, // m/s^2 lost at full turn rate
    aoa_drag: f32 = 0.8, // fraction of speed lost per second at 90° AoA
    gravity_k: f32 = 40.0, // exaggerated gravity along flight path

    // Grip: how fast velocity direction chases the nose (1/s).
    grip: f32 = 10,
    min_grip: f32 = 1.2,
    aoa_slide_start_deg: f32 = 20,
    aoa_slide_full_deg: f32 = 70,

    // Auto-leveling (natural stability when controls are neutral) — slowed 8x for gentle return.
    roll_level_gain: f32 = 0.35, // rad/s per unit roll error
    pitch_level_gain: f32 = 0.20, // rad/s per unit pitch error

    // Auto ground avoidance (GCAS).
    ground_avoid_lookahead: f32 = 1.35, // seconds of terrain lookahead
    ground_avoid_ceiling: f32 = 420.0, // altitude AGL (m) where low-alt floor protection begins
    ground_floor_alt: f32 = 55.0, // minimum safe floor altitude AGL (m)

    // Mild G-Force Fly-By-Wire (FBW) Envelope Protection & Energy Bleed:
    fbw_g_max: f32 = 9.0, // Maximum sustained positive G-load in normal flight (9G envelope)
    fbw_g_min: f32 = -3.5, // Negative G limit for pushover maneuvers (-3.5G)
    fbw_g_drift: f32 = 12.0, // High-G thrust-vectoring override limit (12G)
    fbw_g_scale: f32 = 420.0, // Scaling constant (m/s^2 per G) calibrated for high-speed flight
    fbw_induced_drag: f32 = 8.5, // Induced drag coefficient bleeding speed at high G (m/s per G^2 per sec)
};

pub const Input = struct {
    pitch: f32 = 0, // +1 = nose up
    roll: f32 = 0, // +1 = roll right
    yaw: f32 = 0, // +1 = nose right
    boost: bool = false,
    brake: bool = false,
    drift: bool = false, // High-G Cobra / Thrust-Vector drift
};

pub const CarrierMode = enum {
    free_flight,
    approach, // Auto-piloting onto carrier final approach glideslope
    landing_roll, // Touchdown + arresting wire deceleration on the flight deck
    healing, // Stopped on deck restoring health to 100%
    takeoff_roll, // Catapult launch along the flight deck + climb-out
};

pub const gear_speeds = [10]f32{
    -650.0, // Gear 0 ('0'): Reverse!
    120.0, // Gear 1 ('1'): Very slow sightseeing crawl
    320.0, // Gear 2 ('2'): Slow low-pass speed
    650.0, // Gear 3 ('3'): Light cruise
    1100.0, // Gear 4 ('4'): Medium patrol
    1800.0, // Gear 5 ('5'): Fast cruise
    2600.0, // Gear 6 ('6'): Standard jet speed (default)
    3800.0, // Gear 7 ('7'): Supersonic
    5400.0, // Gear 8 ('8'): Hypersonic
    8000.0, // Gear 9 ('9'): Extreme orbital-skimming speed
};

pub const BfmPhase = enum {
    scan, // Sector scanning & threat detection
    intercept_setup, // Lateral turning room & energy preservation
    lead_turn_merge, // The Merge: early lead turn into bandit's exit plane
    high_yo_yo, // Excess closure: vertical pitch-up to trade speed for altitude
    low_yo_yo, // Lag pursuit: dive below horizon to accelerate & cut turn circle
    one_circle, // Nose-to-nose tight radius fight
    two_circle, // Nose-to-tail sustained rate fight
    firing_solution, // Inside weapons envelope - weapons free!

    pub fn label(self: BfmPhase) []const u8 {
        return switch (self) {
            .scan => "SCAN [LOSE SIGHT, LOSE FIGHT]",
            .intercept_setup => "INTERCEPT [GAIN TURNING ROOM]",
            .lead_turn_merge => "THE MERGE [PULL LEAD TURN]",
            .high_yo_yo => "HIGH YO-YO [TRADE SPEED FOR ALT]",
            .low_yo_yo => "LOW YO-YO [CUT INSIDE CIRCLE]",
            .one_circle => "ONE-CIRCLE [RADIUS FIGHT]",
            .two_circle => "TWO-CIRCLE [RATE FIGHT]",
            .firing_solution => "FIRING SOLUTION [WEAPONS CLEAR]",
        };
    }
};

/// Atmospheric Weather Annunciator & Physical Dynamics State
pub const WeatherState = struct {
    in_cloud: bool = false,
    gust_active: bool = false,
    turb_active: bool = false,
    therm_active: bool = false,
    rain_active: bool = false,
    clear_active: bool = true,
};

pub const Plane = struct {
    params: Params = .{},
    pos: Vec3 = Vec3.init(0, planet.radius + 500.0, 0),
    rot: Quat = Quat.identity,
    dir: Vec3 = Vec3.forward, // velocity direction
    speed: f32 = 2600,
    /// Transmission gear: 1..9 = forward speed gears (from very slow 120 m/s to very fast 8,000 m/s), 0 = Reverse (-650 m/s).
    gear: u8 = 6,
    /// Smoothed local angular rates (rad/s): x = pitch, y = yaw, z = roll.
    rates: Vec3 = Vec3.zero,
    prev_pos: Vec3 = Vec3.init(0, planet.radius + 500.0, 0),
    prev_rot: Quat = Quat.identity,
    /// Angle between nose and velocity (radians) — exposed for HUD/effects.
    aoa: f32 = 0,
    /// Ground avoidance engagement (0..1) — exposed for HUD/log.
    gcas: f32 = 0,
    /// Current altitude above ground/sea surface (m).
    alt_agl: f32 = 500.0,
    /// Player hull health (0..100). Restored to 100 when landing on a friendly aircraft carrier.
    health: f32 = 100.0,
    max_health: f32 = 100.0,
    team: planet.Team = .friendly,
    is_dead: bool = false,
    death_timer: f32 = 0.0,
    /// Aircraft carrier landing / healing / takeoff sequence state:
    carrier_mode: CarrierMode = .free_flight,
    target_carrier: usize = 0,
    carrier_timer: f32 = 0,
    deck_progress: f32 = 0,
    respawns: u32 = 0,
    flight_time: f32 = 0.0,
    /// Combat targeting & auto-guidance:
    targeting_mode: bool = true,
    locked_target: ?usize = null,
    target_passed: bool = false,
    firing_solution: bool = false,
    drift_mode: bool = false,
    bfm_phase: BfmPhase = .intercept_setup,
    guided_fwd: Vec3 = Vec3.zero,
    /// Live aerodynamic turbulence factor (0..1) driving the HUD waveform player.
    turb: f32 = 0.0,
    /// Live G-force load (1G..9G) for avionics telemetry.
    g_load: f32 = 1.0,
    /// Live Atmospheric Weather State & Annunciator Tags
    weather: WeatherState = .{},

    pub fn up(_: *const Plane, pos: Vec3) Vec3 {
        return pos.norm();
    }

    /// Evaluates deterministic planetary atmospheric conditions & updates live weather state
    pub fn updateWeather(self: *Plane, in_cloud: bool) void {
        const up_ref = self.up(self.pos);
        const r_now = self.pos.len();
        const alt = r_now - planet.radius;
        const wind = planet.Atmosphere.evalWind(self.pos, self.flight_time);
        const wind_len = wind.len();
        const updraft = wind.dot(up_ref);
        const elev = planet.terrainElevation(up_ref);

        const gust = (wind_len >= 36.0);
        const turb = (self.turb >= 0.40);
        const therm = (elev > 10.0 and alt < 3500.0 and updraft > 8.0);
        const rain = (alt < 800.0 and elev < 2.0); // low altitude marine boundary layer

        self.weather.in_cloud = in_cloud;
        self.weather.gust_active = gust;
        self.weather.turb_active = turb;
        self.weather.therm_active = therm;
        self.weather.rain_active = rain;
        self.weather.clear_active = !in_cloud and !gust and !turb and !rain;
    }

    /// Tactical BFM Cubic Bezier auto-guidance toward maneuvering targets:
    /// Incorporates real-world Basic Fighter Maneuvers:
    /// - Lateral displacement during intercept setup to preserve turning room
    /// - The Merge Lead Turn: pulling early into bandit's projected exit plane
    /// - High Yo-Yo: vertical conversion trading excess speed for altitude to arrest overshoot
    /// - Low Yo-Yo: diving corner cut to accelerate and slice inside the turn circle
    /// - Low-pass filtered guidance to eliminate any twitching or jerkiness.
    pub fn applyBezierAutoGuide(
        self: *Plane,
        dt: f32,
        lead_pos: Vec3,
        target_pos: Vec3,
        target_dir: Vec3,
        target_speed: f32,
        strength: f32,
    ) void {
        const p = self.params;
        const p0 = self.pos;
        const p3 = lead_pos;
        const to_tgt = target_pos.sub(p0);
        const dist = to_tgt.len();
        if (dist < 10.0 or dist > 8500.0) {
            self.firing_solution = false;
            self.bfm_phase = .scan;
            return;
        }

        const fwd = self.rot.rotate(Vec3.forward);
        const pup = self.rot.rotate(Vec3.up);
        const to_tgt_dir = to_tgt.scale(1.0 / dist);
        const dot_fwd = fwd.dot(to_tgt_dir);
        const aspect = target_dir.dot(fwd);
        const rel_vel = self.dir.scale(self.speed).sub(target_dir.scale(target_speed));
        const closing_speed = rel_vel.dot(to_tgt_dir);

        // Target passing check
        if (dot_fwd < -0.15) {
            self.target_passed = true;
            self.firing_solution = false;
        } else {
            self.target_passed = false;
        }

        // --- BFM Tactical Phase Selection & Dynamic Control Point Shaping ---
        const curve_reach = dist * 0.40;
        var p1: Vec3 = undefined;
        var p2: Vec3 = p3.sub(target_dir.scale(curve_reach * 0.70));

        if (dot_fwd > 0.94 and dist < 2400.0) {
            // Inside weapons envelope: line up pure lead
            self.bfm_phase = .firing_solution;
            self.firing_solution = true;
            p1 = p0.add(fwd.scale(curve_reach));
        } else if (dist < 1800.0 and aspect < -0.45 and dot_fwd > 0.25) {
            // The Merge: Bandit closing head-on!
            // Guideline: Pull hard into a lead turn early, angling lift vector into future bandit exit heading.
            self.bfm_phase = .lead_turn_merge;
            self.firing_solution = false;
            const merge_axis = target_dir.cross(pup);
            const merge_axis_len = merge_axis.len();
            const lead_offset = if (merge_axis_len > 1e-4)
                merge_axis.scale(curve_reach * 0.45 / merge_axis_len)
            else
                pup.scale(curve_reach * 0.35);
            p1 = p0.add(fwd.scale(curve_reach * 0.65)).add(lead_offset);
        } else if (dist < 1100.0 and closing_speed > 450.0 and dot_fwd > 0.50) {
            // High Yo-Yo: Closing with extreme speed, high risk of overshoot!
            // Guideline: Trade excess speed for altitude, pitch up into vertical along lift vector (pup).
            self.bfm_phase = .high_yo_yo;
            self.firing_solution = false;
            p1 = p0.add(fwd.scale(curve_reach * 0.65)).add(pup.scale(curve_reach * 0.60));
        } else if (dist > 1200.0 and dist < 4500.0 and aspect > 0.15 and dot_fwd < 0.88) {
            // Low Yo-Yo: Lagging behind the bandit in a turn!
            // Guideline: Unload Gs, pitch slightly below horizon to accelerate & slice inside turn circle.
            self.bfm_phase = .low_yo_yo;
            self.firing_solution = false;
            p1 = p0.add(fwd.scale(curve_reach * 0.75)).sub(pup.scale(curve_reach * 0.30));
        } else if (dist >= 2400.0) {
            // Intercept & Setup: Maintain high energy, gain lateral turning room
            self.bfm_phase = .intercept_setup;
            self.firing_solution = false;
            const lateral_dir = fwd.cross(self.up(p0));
            const lat_len = lateral_dir.len();
            const lateral_disp = if (lat_len > 1e-4) lateral_dir.scale(curve_reach * 0.20 / lat_len) else Vec3.zero;
            p1 = p0.add(fwd.scale(curve_reach)).add(lateral_disp);
        } else {
            // Close-in Maneuvering: One-Circle (radius) vs Two-Circle (rate)
            self.bfm_phase = if (aspect < 0.0) .one_circle else .two_circle;
            self.firing_solution = false;
            p1 = p0.add(fwd.scale(curve_reach));
        }

        // Evaluate Bezier derivative at t = 0.20 ahead
        const t: f32 = 0.20;
        const one_minus_t = 1.0 - t;
        const d01 = p1.sub(p0).scale(3.0 * one_minus_t * one_minus_t);
        const d12 = p2.sub(p1).scale(6.0 * one_minus_t * t);
        const d23 = p3.sub(p2).scale(3.0 * t * t);
        const tangent = d01.add(d12).add(d23);
        const tangent_len = tangent.len();
        if (tangent_len < 1e-4) return;
        const raw_desired_fwd = tangent.scale(1.0 / tangent_len);

        // Anti-Jerkiness: Low-pass filter desired forward direction
        if (self.guided_fwd.dot(self.guided_fwd) < 0.1) {
            self.guided_fwd = fwd;
        }
        self.guided_fwd = Vec3.lerp(self.guided_fwd, raw_desired_fwd, 1.0 - @exp(-dt / 0.14)).norm();
        const desired_fwd = self.guided_fwd;

        const align_dot = fwd.dot(desired_fwd);

        // Progressive, intuitive turn rate with Mild G-Force FBW governor
        var turn_rate = std.math.clamp(strength, 2.0, 3.6);
        if (align_dot > 0.95) {
            const lock_factor = math.smoothstep(0.95, 0.99, align_dot);
            turn_rate *= math.lerpf(1.0, 1.30, lock_factor);
        }

        // --- Mild G-Force Fly-By-Wire (FBW) Governor for Bezier Auto-Guidance ---
        // Dynamically limits turn rate at high speeds to keep G-loads within the 9G structural envelope
        const speed_mag = @abs(self.speed);
        const max_allowed_g: f32 = if (self.drift_mode) p.fbw_g_drift else p.fbw_g_max;
        const demanded_g = 1.0 + (speed_mag * turn_rate) / p.fbw_g_scale;
        if (demanded_g > max_allowed_g) {
            const fbw_scale = (max_allowed_g - 1.0) / @max(demanded_g - 1.0, 1e-3);
            turn_rate *= math.clamp01(fbw_scale);
        }

        // FBW Induced Drag Bleed along the Bezier curve:
        const actual_g = 1.0 + (speed_mag * turn_rate) / p.fbw_g_scale;
        if (actual_g > 1.25 and self.speed > 0) {
            const g_excess = actual_g - 1.0;
            const fbw_bleed = p.fbw_induced_drag * (g_excess * g_excess) * dt;
            self.speed = @max(self.speed - fbw_bleed, self.gearTargetSpeed() * 0.40);
        }
        self.g_load = math.lerpf(self.g_load, actual_g, 1.0 - @exp(-dt / 0.08));

        const blend = math.clamp01(turn_rate * dt);
        const new_fwd = Vec3.lerp(fwd, desired_fwd, blend).norm();
        self.dir = Vec3.lerp(self.dir, new_fwd, blend * 0.75).norm();

        // FBW Coordinated Bank-Into-Turn (Bank & Yank):
        // Automatically banks the aircraft so its lift vector (pup) rolls into the turn plane normal
        const turn_cross = fwd.cross(desired_fwd);
        const turn_mag = turn_cross.len();
        var desired_pup = pup;
        if (turn_mag > 0.01) {
            const turn_axis = turn_cross.scale(1.0 / turn_mag);
            // Normal acceleration vector pointing into the center of the turn circle
            const turn_inward = turn_axis.cross(new_fwd).norm();
            // Blend canopy toward turn normal based on turn sharpness
            const bank_weight = math.smoothstep(0.02, 0.25, turn_mag);
            desired_pup = Vec3.lerp(pup, turn_inward, bank_weight * 0.75).norm();
        }

        const z_axis = new_fwd.scale(-1);
        const x_axis = desired_pup.cross(z_axis).norm();
        const y_axis = z_axis.cross(x_axis).norm();
        const target_rot = planet.fromBasis(x_axis, y_axis, z_axis);
        self.rot = Quat.nlerp(self.rot, target_rot, blend);
    }

    /// Auto-guide fallback for simple directional snapping:
    pub fn applyAutoGuide(self: *Plane, dt: f32, target_dir: Vec3, snap_strength: f32) void {
        const fwd = self.rot.rotate(Vec3.forward);
        const dot = fwd.dot(target_dir);
        if (dot < 0.35) return;

        const snap_factor = if (dot > 0.985) snap_strength * 2.5 else snap_strength;
        const blend = math.clamp01(snap_factor * dt);

        self.dir = Vec3.lerp(self.dir, target_dir, blend * 1.2).norm();

        const up_now = self.up(self.pos);
        const z_axis = target_dir.scale(-1);
        const x_axis = up_now.cross(z_axis).norm();
        const y_axis = z_axis.cross(x_axis).norm();
        const target_rot = planet.fromBasis(x_axis, y_axis, z_axis);
        self.rot = Quat.nlerp(self.rot, target_rot, blend);
    }

    pub fn setGear(self: *Plane, new_gear: u8) void {
        if (new_gear <= 9) {
            self.gear = new_gear;
        }
    }

    pub fn gearTargetSpeed(self: *const Plane) f32 {
        return gear_speeds[@min(@as(usize, self.gear), 9)];
    }

    pub fn kill(self: *Plane) void {
        self.is_dead = true;
        self.death_timer = 0;
        self.health = 0;
        self.carrier_mode = .free_flight;
    }

    pub fn respawnNearestCarrier(self: *Plane, carriers: []const planet.AircraftCarrier) void {
        var best_idx: usize = 0;
        var best_dist: f32 = std.math.inf(f32);
        for (carriers, 0..) |car, i| {
            if (car.team != self.team) continue;
            const d = car.pos.sub(self.pos).len();
            if (d < best_dist) {
                best_dist = d;
                best_idx = i;
            }
        }
        if (best_idx < carriers.len) {
            const car = carriers[best_idx];
            const deck_height: f32 = 21.2;
            const cat_start = car.pos.add(car.dir.scale(deck_height)).sub(car.fwd.scale(42.0));
            self.pos = cat_start;
            self.prev_pos = cat_start;
            self.rot = car.rot;
            self.prev_rot = car.rot;
            self.dir = car.fwd;
            self.speed = 0.0;
            self.health = 100.0;
            self.is_dead = false;
            self.death_timer = 0.0;
            self.carrier_mode = .takeoff_roll;
            self.target_carrier = best_idx;
            self.carrier_timer = 0.0;
            self.rates = Vec3.zero;
            self.locked_target = null;
            self.target_passed = false;
            self.firing_solution = false;
            self.bfm_phase = .scan;
        } else {
            self.respawn();
            self.health = 100.0;
            self.is_dead = false;
            self.death_timer = 0.0;
        }
    }

    pub fn respawn(self: *Plane) void {
        self.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    }

    pub fn spawnAt(self: *Plane, up_dir: Vec3, fwd_tangent: Vec3) void {
        const p = self.params;
        const u = up_dir.norm();
        const f = fwd_tangent.sub(u.scale(fwd_tangent.dot(u))).norm();
        const z_axis = f.scale(-1);
        const x_axis = u.cross(z_axis).norm();
        const y_axis = z_axis.cross(x_axis).norm();
        const rot = planet.fromBasis(x_axis, y_axis, z_axis);
        const start_r = planet.surfaceRadius(u) + 380.0;
        const start_pos = u.scale(start_r);
        const old_team = self.team;
        const old_respawns = self.respawns;
        self.* = .{
            .params = p,
            .pos = start_pos,
            .prev_pos = start_pos,
            .rot = rot,
            .prev_rot = rot,
            .dir = f,
            .gear = 6,
            .team = old_team,
            .health = 100.0,
            .max_health = 100.0,
            .is_dead = false,
            .death_timer = 0,
            .respawns = old_respawns + 1,
            .speed = gear_speeds[6],
        };
    }

    /// Triggered by pressing `1`: finds the nearest friendly (`Team.friendly`) aircraft carrier
    /// on the planet and engages the automated carrier landing, health restoration, and takeoff sequence.
    pub fn beginCarrierLanding(self: *Plane, carriers: []const planet.AircraftCarrier) ?usize {
        if (self.carrier_mode != .free_flight) return self.target_carrier;
        const my_dir = self.pos.norm();
        var best_idx: ?usize = null;
        var best_dot: f32 = -2.0;
        for (carriers, 0..) |car, idx| {
            if (car.team != .friendly) continue;
            const d = my_dir.dot(car.dir);
            if (d > best_dot) {
                best_dot = d;
                best_idx = idx;
            }
        }
        if (best_idx) |idx| {
            self.target_carrier = idx;
            self.carrier_mode = .approach;
            self.carrier_timer = 0;
            self.deck_progress = 0;
            self.rates = Vec3.zero;
        }
        return best_idx;
    }

    fn stepCarrierSequence(self: *Plane, dt: f32, car: planet.AircraftCarrier) void {
        self.prev_pos = self.pos;
        self.prev_rot = self.rot;
        self.gcas = 0;
        self.aoa = 0;

        const deck_height: f32 = 21.2; // plane wheel height resting cleanly on top of 1.35x scaled carrier flight deck (`14.55 * 1.35 + 1.5`)
        const stern_point = car.pos.add(car.dir.scale(deck_height)).sub(car.fwd.scale(155.0));
        const mid_deck = car.pos.add(car.dir.scale(deck_height)).add(car.fwd.scale(15.0));
        const bow_point = car.pos.add(car.dir.scale(deck_height)).add(car.fwd.scale(175.0));

        switch (self.carrier_mode) {
            .free_flight => {},
            .approach => {
                // Fly toward a final-approach glideslope point behind the carrier's stern, then flare onto the deck
                const to_stern = stern_point.sub(self.pos);
                const dist = to_stern.len();
                // Entry gate 950 m behind the stern, 160 m above the deck
                const entry_gate = stern_point.sub(car.fwd.scale(950.0)).add(car.dir.scale(160.0));
                const waypoint = if (dist > 1100.0) entry_gate else stern_point;
                const to_wp = waypoint.sub(self.pos);
                const wp_dist = @max(to_wp.len(), 1.0);
                const desired_dir = to_wp.scale(1.0 / wp_dist);

                // Smoothly steer velocity & orientation toward waypoint (or carrier runway alignment when close)
                const align_t = math.clamp01(1.0 - dist / 900.0);
                const look_fwd = Vec3.lerp(desired_dir, car.fwd, align_t * 0.75).norm();
                const up_now = self.pos.norm();
                const z_axis = look_fwd.scale(-1);
                const x_axis = up_now.cross(z_axis).norm();
                const y_axis = z_axis.cross(x_axis).norm();
                const target_rot = planet.fromBasis(x_axis, y_axis, z_axis);

                self.rot = Quat.nlerp(self.rot, target_rot, 1.0 - @exp(-8.0 * dt));
                self.dir = Vec3.lerp(self.dir, desired_dir, 1.0 - @exp(-9.0 * dt)).norm();

                // Decelerate from cruise/boost down to approach speed as we near the stern
                const target_spd = math.lerpf(420.0, 2600.0, math.clamp01((dist - 120.0) / 3200.0));
                self.speed = math.lerpf(self.speed, target_spd, 1.0 - @exp(-4.0 * dt));

                const step_dist = self.speed * dt;
                if (dist <= step_dist + 28.0) {
                    // Touchdown at the stern! Engage arresting gear
                    self.pos = stern_point;
                    self.rot = car.rot;
                    self.dir = car.fwd;
                    self.speed = 380.0;
                    self.carrier_mode = .landing_roll;
                    self.carrier_timer = 0;
                    self.deck_progress = 0;
                } else {
                    self.pos = self.pos.add(desired_dir.scale(step_dist));
                    // Keep above ocean surface during long-range approach
                    const u = self.pos.norm();
                    const min_r = planet.surfaceRadius(u) + deck_height;
                    if (self.pos.len() < min_r) self.pos = u.scale(min_r);
                }
                self.alt_agl = self.pos.len() - planet.radius;
            },
            .landing_roll => {
                // Roll from stern (`stern_point`) to arrested stop (`mid_deck`) over 1.45 seconds
                self.carrier_timer += dt;
                const t = math.clamp01(self.carrier_timer / 1.45);
                // Ease-out deceleration (arresting cable pull)
                const ease = 1.0 - (1.0 - t) * (1.0 - t);
                self.pos = Vec3.lerp(stern_point, mid_deck, ease);

                // Landing suspension squat / nose dip under rapid deceleration
                const squat_pitch = -0.065 * (1.0 - t) * (1.0 - t);
                const pitch_rot = Quat.fromAxisAngle(car.right, squat_pitch);
                self.rot = car.rot.mul(pitch_rot);
                self.dir = car.fwd;
                self.speed = math.lerpf(380.0, 0.0, t);
                self.alt_agl = deck_height;
                if (t >= 1.0) {
                    self.carrier_mode = .healing;
                    self.carrier_timer = 0;
                    self.speed = 0;
                    self.rot = car.rot;
                }
            },
            .healing => {
                // Parked on the flight deck: active re-up & health restoration animation over 3.2 seconds
                self.carrier_timer += dt;
                self.pos = mid_deck;
                self.rot = car.rot;
                self.dir = car.fwd;
                self.speed = 0;
                self.alt_agl = deck_height;
                self.health = @min(self.max_health, self.health + 35.0 * dt);
                if (self.carrier_timer >= 3.2 and self.health >= self.max_health) {
                    self.health = self.max_health;
                    self.carrier_mode = .takeoff_roll;
                    self.carrier_timer = 0;
                }
            },
            .takeoff_roll => {
                // Steam/EMALS catapult launch from `cat_start` past `bow_point` + climb-out
                self.carrier_timer += dt;
                const deck_t = math.clamp01(self.carrier_timer / 1.30);
                const cat_start = mid_deck.sub(car.fwd.scale(20.0));
                if (self.carrier_timer < 1.30) {
                    // Accelerating down the flight deck toward the bow
                    const accel_ease = deck_t * deck_t;
                    self.pos = Vec3.lerp(cat_start, bow_point, accel_ease);
                    self.rot = car.rot;
                    self.dir = car.fwd;
                    self.speed = math.lerpf(0.0, self.params.cruise * 0.70, deck_t);
                    self.alt_agl = deck_height;
                } else {
                    // Airborne off the bow! Pitch up +16° and accelerate to full cruise speed
                    const climb_t = math.clamp01((self.carrier_timer - 1.30) / 1.35);
                    self.speed = math.lerpf(self.params.cruise * 0.70, self.params.cruise, climb_t);
                    const climb_dir = car.fwd.add(car.dir.scale(0.28)).norm();
                    self.dir = climb_dir;
                    self.pos = self.pos.add(climb_dir.scale(self.speed * dt));
                    const u = self.pos.norm();
                    const z_axis = climb_dir.scale(-1);
                    const x_axis = u.cross(z_axis).norm();
                    const y_axis = z_axis.cross(x_axis).norm();
                    self.rot = planet.fromBasis(x_axis, y_axis, z_axis);
                    self.alt_agl = self.pos.len() - planet.radius;
                    if (climb_t >= 1.0) {
                        self.carrier_mode = .free_flight;
                        self.rates = Vec3.zero;
                    }
                }
            },
        }
    }

    pub fn step(self: *Plane, dt: f32, in: Input, carriers: []const planet.AircraftCarrier) void {
        if (self.is_dead) {
            self.death_timer += dt;
            if (self.death_timer >= 1.2) {
                self.respawnNearestCarrier(carriers);
            }
            return;
        }
        if (self.carrier_mode != .free_flight and self.target_carrier < carriers.len) {
            self.stepCarrierSequence(dt, carriers[self.target_carrier]);
            return;
        }

        // Also check if player manually touches down on a friendly carrier flight deck
        if (self.carrier_mode == .free_flight and !self.is_dead) {
            for (carriers, 0..) |car, idx| {
                if (car.team != .friendly) continue;
                const to_car = self.pos.sub(car.pos);
                const alt_deck = to_car.dot(car.dir) - 21.2;
                const long_dist = to_car.dot(car.fwd);
                const lat_dist = to_car.dot(car.right);
                if (long_dist >= -165.0 and long_dist <= -25.0 and @abs(lat_dist) <= 26.0 and @abs(alt_deck) <= 14.0) {
                    const fwd_align = self.dir.dot(car.fwd);
                    if (fwd_align > 0.55) {
                        self.target_carrier = idx;
                        self.carrier_mode = .landing_roll;
                        self.carrier_timer = 0.0;
                        self.deck_progress = 0.0;
                        self.speed = @min(self.speed, 380.0);
                        self.stepCarrierSequence(dt, car);
                        return;
                    }
                }
            }
        }
        const p = self.params;
        self.prev_pos = self.pos;
        self.prev_rot = self.rot;

        const up_ref = self.up(self.pos);
        const r_now = self.pos.len();
        const surf_now = planet.surfaceRadius(up_ref);
        const alt = r_now - surf_now;
        self.alt_agl = alt;

        // Current orientation basis vectors in world space.
        const fwd0 = self.rot.rotate(Vec3.forward);
        const right0 = self.rot.rotate(Vec3.init(1, 0, 0));
        const pup0 = self.rot.rotate(Vec3.up);

        // --- 0. Spherical Auto Ground Avoidance (GCAS) ---
        // Sample forward predicted position along velocity vector
        const future_pos = self.pos.add(self.dir.scale(self.speed * p.ground_avoid_lookahead));
        const future_up = future_pos.norm();
        const future_alt = future_pos.len() - planet.surfaceRadius(future_up);
        const mid_pos = self.pos.add(self.dir.scale(self.speed * (p.ground_avoid_lookahead * 0.45)));
        const mid_alt = mid_pos.len() - planet.surfaceRadius(mid_pos.norm());
        const min_pred_alt = @min(future_alt, mid_alt);

        const descending = self.dir.dot(up_ref) < 0.05;
        const predictive_danger = if (descending and (min_pred_alt < alt or min_pred_alt < p.ground_avoid_ceiling))
            1.0 - math.smoothstep(p.ground_floor_alt, p.ground_avoid_ceiling, min_pred_alt)
        else
            0.0;
        const proximity_danger = if (descending)
            1.0 - math.smoothstep(p.ground_floor_alt, p.ground_floor_alt * 2.2, alt)
        else
            0.0;
        const danger = @max(predictive_danger, proximity_danger);
        self.gcas = danger;

        // Apply ground cushion directly to flight velocity vector when descending close to terrain
        if (danger > 0.01 and self.dir.dot(up_ref) < 0.0) {
            const down_speed = -self.dir.dot(up_ref);
            const cushion_strength = 1.0 - @exp(-24.0 * danger * dt);
            self.dir = self.dir.add(up_ref.scale(down_speed * cushion_strength * 1.5 + 0.08 * dt)).norm();
        }

        // --- Continuous Smooth Roll with 90° Knife-Edge Hold & Subtle Ground Gravitation ---
        // roll_angle in [-pi, pi]: 0 = upright, +pi/2 = right sideways (+90°), -pi/2 = left sideways (-90°), +-pi = inverted (180°)
        const roll_angle = std.math.atan2(-right0.dot(up_ref), pup0.dot(up_ref));

        // When the pilot touches the roll stick (|in.roll| > 0.05), pilot input has 100% full authority.
        // There is no artificial locking, latching, or key-release requirement: holding A or D rolls continuously
        // through 360° without stopping, pausing, or resisting smooth progressions.
        const roll_stick_free = 1.0 - math.clamp01(@abs(in.roll) * 3.5);

        var auto_roll_rate: f32 = 0.0;
        if (roll_stick_free > 0.001) {
            // 1. Knife-Edge Attractor: when released near +/- 90° (+/- pi/2 rad ~ 1.5708),
            // provide a gentle, stable holding pocket so the plane sits comfortably at 90° sideways.
            const target_90: f32 = if (roll_angle >= 0) (std.math.pi * 0.5) else (-std.math.pi * 0.5);
            const err_90 = roll_angle - target_90;

            // 2. Inverted Attractor: when released upside down (~180° / +/- pi),
            // hold inverted attitude cleanly without flipping upright.
            const target_inv: f32 = if (roll_angle >= 0) std.math.pi else -std.math.pi;
            const err_inv = roll_angle - target_inv;

            if (@abs(err_90) <= 0.32) {
                // Within ~18° of knife-edge: sit stably at 90°
                const hold_t = 1.0 - math.smoothstep(0.18, 0.32, @abs(err_90));
                auto_roll_rate = -err_90 * 2.40 * hold_t * roll_stick_free;
                // Gently damp angular rate so it settles into 90° knife-edge cleanly
                self.rates.z *= (1.0 - 0.50 * hold_t * roll_stick_free);
            } else if (@abs(err_inv) <= 0.35) {
                // Upside down (inverted): hold inverted attitude hands-off
                const inv_t = 1.0 - math.smoothstep(0.18, 0.35, @abs(err_inv));
                auto_roll_rate = -err_inv * 0.90 * inv_t * roll_stick_free;
                self.rates.z *= (1.0 - 0.30 * inv_t * roll_stick_free);
            } else if (@abs(roll_angle) <= 0.45) {
                // Near wings-level: subtle gravitation to flat ground (gentle dihedral relaxation, not a snap)
                const grav_t = 1.0 - math.smoothstep(0.30, 0.45, @abs(roll_angle));
                auto_roll_rate = -roll_angle * p.roll_level_gain * grav_t * roll_stick_free;
            }
            // For intermediate angles (e.g. 30°, 45°, 60°, 135°), auto_roll_rate is 0.0,
            // preserving smooth continuous progressions and letting the pilot carve turns without pushback.
        }

        // Natural pitch leveling toward the local horizon (`fwd0.dot(up_ref) == 0`) when pitch stick is neutral.
        const pitch_stick_free = 1.0 - math.clamp01(@abs(in.pitch) * 2.5);
        var auto_pitch_rate: f32 = 0;
        if (pitch_stick_free > 0.001) {
            // Only apply gentle horizon leveling when generally upright (canopy pointing somewhat up)
            // When inverted, allow full unrestricted freedom and variability without fighting the pilot.
            if (pup0.dot(up_ref) > 0.25) {
                const pitch_err = -fwd0.dot(up_ref);
                auto_pitch_rate = std.math.clamp(
                    pitch_err * p.pitch_level_gain * pitch_stick_free,
                    -math.radians(p.pitch_rate * 0.4),
                    math.radians(p.pitch_rate * 0.4),
                );
            }
        }

        // Low-altitude ground protection: smoothly inhibit dive inputs when near the terrain floor
        var user_pitch = in.pitch;
        if (user_pitch < 0.0 and (alt < 90.0 or danger > 0.15)) {
            const floor_proximity = math.clamp01((alt - 25.0) / 65.0);
            user_pitch *= floor_proximity;
        }

        // Automatic aerodynamic ground-effect nose leveling when approaching the terrain floor
        if (alt < 90.0 and fwd0.dot(up_ref) < 0.0) {
            const nose_lift = 1.0 - math.clamp01((alt - 22.0) / 68.0);
            auto_pitch_rate += nose_lift * math.radians(p.pitch_rate * 0.85);
        }

        // High-G Drift / Thrust Vectoring (Hold 'F' or 'C'):
        const is_drift = in.drift and !self.is_dead;
        self.drift_mode = is_drift;
        const drift_pitch_mult: f32 = if (is_drift) 2.25 else 1.0;
        const drift_yaw_mult: f32 = if (is_drift) 2.10 else 1.0;

        // Mild G-Force Fly-By-Wire (FBW) Pitch Rate Governor for Unassisted Flight:
        // Closed-form dynamic pitch rate limiter capping sustained normal load factor (9.0G normal, 12.0G drift)
        // at high cruise/boost velocities, while preserving 100% full snappy pitch authority at low speeds.
        const speed_mag = @abs(self.speed);
        const g_max_allow: f32 = if (is_drift) p.fbw_g_drift else p.fbw_g_max;
        const g_min_allow: f32 = if (is_drift) -6.0 else p.fbw_g_min;

        const max_pitch_fbw = ((g_max_allow - 1.0) * p.fbw_g_scale) / @max(speed_mag, 350.0);
        const min_pitch_fbw = -((@abs(g_min_allow) + 1.0) * p.fbw_g_scale) / @max(speed_mag, 350.0);

        const raw_pitch_rate = math.radians(p.pitch_rate * drift_pitch_mult);
        const pos_pitch_rate = @min(raw_pitch_rate, max_pitch_fbw);
        const neg_pitch_rate = @min(raw_pitch_rate, -min_pitch_fbw);

        const user_pitch_rate: f32 = if (user_pitch >= 0.0)
            user_pitch * pos_pitch_rate
        else
            user_pitch * neg_pitch_rate;

        // Command angular rates: pilot retains snappy, unrestricted authority within safe G envelope.
        const cmd_pitch = std.math.clamp(
            user_pitch_rate + auto_pitch_rate,
            -neg_pitch_rate,
            pos_pitch_rate,
        );
        const cmd_roll = std.math.clamp(
            in.roll * math.radians(p.roll_rate) + auto_roll_rate,
            -math.radians(p.roll_rate),
            math.radians(p.roll_rate),
        );

        // --- 1. Rate-commanded rotation (critically damped-ish response) ---
        const tgt = Vec3.init(
            cmd_pitch,
            -in.yaw * math.radians(p.yaw_rate * drift_yaw_mult),
            -cmd_roll,
        );
        const k = 1.0 - @exp(-dt / p.response_tau);
        self.rates = self.rates.add(tgt.sub(self.rates).scale(k));
        const w = self.rates.len();
        if (w > 1e-6) {
            const dq = Quat.fromAxisAngle(self.rates.scale(1.0 / w), w * dt);
            self.rot = self.rot.mul(dq).normalize();
        }

        // --- 2. Energy / speed (Transmission Gears 1..9 + 0 Reverse) ---
        const fwd = self.rot.rotate(Vec3.forward);
        const gear_base = self.gearTargetSpeed();
        const target: f32 = if (self.gear == 0)
            (if (in.boost) gear_base * 1.8 else if (in.brake) gear_base * 0.4 else gear_base)
        else if (in.boost)
            @max(gear_base * 1.45, p.boost)
        else if (in.brake)
            gear_base * 0.55
        else
            gear_base;

        const accel_rate: f32 = 3400.0;
        if (target > self.speed) {
            self.speed = @min(self.speed + accel_rate * dt, target);
        } else {
            self.speed = @max(self.speed - accel_rate * dt, target);
        }
        const turn = math.clamp01(@sqrt(
            (self.rates.x * self.rates.x) / sq(math.radians(p.pitch_rate)) +
                (self.rates.y * self.rates.y) / sq(math.radians(p.yaw_rate)),
        ));
        if (self.speed > 0) {
            self.speed -= p.turn_bleed * 0.25 * turn * turn * dt;
            self.speed -= self.dir.dot(up_ref) * 9.81 * p.gravity_k * 0.35 * dt;

            // FBW Induced Drag Bleed during high-G maneuvers (G > 1.25):
            // Energy bleeds quadratically with excess G-load, rewarding disciplined energy management.
            if (self.g_load > 1.25) {
                const g_excess = self.g_load - 1.0;
                const induced_bleed = p.fbw_induced_drag * (g_excess * g_excess) * dt;
                self.speed = @max(self.speed - induced_bleed, gear_base * 0.35);
            }
        }

        // --- 3. Velocity chases the nose, gated by grip ---
        const cos_aoa = std.math.clamp(self.dir.dot(fwd), -1, 1);
        self.aoa = std.math.acos(cos_aoa);
        const slide = math.smoothstep(math.radians(p.aoa_slide_start_deg), math.radians(p.aoa_slide_full_deg), self.aoa);
        var grip = math.lerpf(p.grip, p.min_grip, slide);
        grip *= math.lerpf(0.55, 1.0, math.clamp01(@abs(self.speed) / 800.0));
        grip = math.lerpf(grip, @max(grip, 16.0), danger);
        if (is_drift) {
            grip = 1.05; // low grip during thrust-vector drift
            if (self.speed > 750.0) {
                self.speed -= 3600.0 * dt;
            }
        }
        self.dir = Vec3.lerp(self.dir, fwd, 1.0 - @exp(-grip * dt)).norm();

        // Radial velocity deflection near the terrain/ocean cushion
        const alt_cushion_factor = 1.0 - math.clamp01((alt - 22.0) / 95.0);
        const effective_deflect = @max(danger, alt_cushion_factor);
        if (effective_deflect > 0.01 and self.dir.dot(up_ref) < 0.12) {
            const lift = up_ref.scale((0.15 - self.dir.dot(up_ref)) * (1.0 - @exp(-28.0 * effective_deflect * dt)));
            self.dir = self.dir.add(lift).norm();
        }

        if (self.gear == 0) {
            self.speed = std.math.clamp(self.speed, -1500.0, 200.0);
        } else {
            self.speed -= self.speed * @sin(self.aoa) * p.aoa_drag * 0.35 * dt;
            self.speed = @max(self.speed, gear_base * 0.45);
        }

        // --- 4. Integrate + transport along sphere curvature + hard ground cushion ---
        self.flight_time += dt;
        const wind = planet.Atmosphere.evalWind(self.pos, self.flight_time);

        // --- 4b. Sensible Physical Weather Effects on Aerodynamics ---
        if (self.weather.in_cloud) {
            // Dense cloud moisture causes parasitic drag (-8% speed bleed) and cushions control surface bites
            self.speed -= self.speed * 0.08 * dt;
            self.rates = self.rates.scale(1.0 - 0.20 * dt);
        }
        if (self.weather.gust_active) {
            // Lateral wind shear drift
            const crosswind = wind.sub(self.dir.scale(wind.dot(self.dir)));
            self.dir = Vec3.lerp(self.dir, self.dir.add(crosswind.scale(0.012)), dt * 2.5).norm();
            self.rates.z += @sin(self.flight_time * 22.0) * 0.06 * dt;
        }
        if (self.weather.turb_active) {
            // Micro-torque buffeting directly driving airframe shudder & HUD waveform
            const t_bump = (self.turb - 0.38);
            self.rates.x += @sin(self.flight_time * 28.0) * 0.12 * t_bump * dt;
            self.rates.y += @cos(self.flight_time * 21.0) * 0.09 * t_bump * dt;
            self.rates.z += @sin(self.flight_time * 33.0) * 0.15 * t_bump * dt;
        }
        if (self.weather.therm_active) {
            // Vertical buoyant lift from warm land/cities reduces climb energy bleed
            self.dir = self.dir.add(up_ref.scale(0.08 * dt)).norm();
            if (self.dir.dot(up_ref) > 0.0) {
                self.speed += 8.5 * dt;
            }
        }
        if (self.weather.rain_active) {
            // Low-altitude marine boundary moisture friction
            self.speed -= self.speed * 0.035 * dt;
        }

        self.pos = self.pos.add(self.dir.scale(self.speed * dt)).add(wind.scale(dt * 0.45));
        const new_up = self.pos.norm();

        // Parallel-transport orientation and velocity along the sphere's curvature
        // so level flight stays level with the local horizon as you orbit the planet.
        const curve_axis = up_ref.cross(new_up);
        const sin_curve = curve_axis.len();
        if (sin_curve > 1e-7) {
            const q_curve = Quat.fromAxisAngle(curve_axis.scale(1.0 / sin_curve), std.math.asin(std.math.clamp(sin_curve, -1.0, 1.0)));
            self.rot = q_curve.mul(self.rot).normalize();
            self.dir = q_curve.rotate(self.dir).norm();
        }

        const new_surf = planet.surfaceRadius(new_up);
        const safe_floor_height: f32 = 22.0;
        const min_r = new_surf + safe_floor_height;
        if (self.pos.len() < min_r) {
            // Strictly clamp aircraft above the ground/ocean floor — impossible to run into the ground!
            self.pos = new_up.scale(min_r);
            self.alt_agl = safe_floor_height;

            const radial_v = self.dir.dot(new_up);
            if (radial_v < 0.04) {
                // Eliminate all downward velocity and deflect into surface tangent with a gentle climb
                const tangent = self.dir.sub(new_up.scale(radial_v));
                const tan_len = tangent.len();
                if (tan_len > 1e-4) {
                    self.dir = tangent.scale(1.0 / tan_len).add(new_up.scale(0.04)).norm();
                } else {
                    const fwd_now = self.rot.rotate(Vec3.forward);
                    const fwd_tan = fwd_now.sub(new_up.scale(fwd_now.dot(new_up)));
                    if (fwd_tan.len() > 1e-4) {
                        self.dir = fwd_tan.norm().add(new_up.scale(0.04)).norm();
                    } else {
                        self.dir = new_up;
                    }
                }
            }

            // Ground level attitude protection: ensure aircraft nose is not buried in the ground
            const fwd_now = self.rot.rotate(Vec3.forward);
            const nose_pitch = fwd_now.dot(new_up);
            if (nose_pitch < 0.0) {
                const right_now = self.rot.rotate(Vec3.init(1, 0, 0));
                const q_unpitch = Quat.fromAxisAngle(right_now, -nose_pitch + 0.02);
                self.rot = q_unpitch.mul(self.rot).normalize();
            }
            if (self.rates.x < 0.0) self.rates.x = 0.0;
        }

        // --- 5. Aerodynamic Turbulence & G-Load Dynamics ---
        const turn_rate_mag = @sqrt(self.rates.x * self.rates.x + self.rates.y * self.rates.y);
        const boost_g: f32 = if (in.boost) 1.5 else 0.0;
        const drift_g: f32 = if (is_drift) 2.2 else 0.0;
        const dynamic_g = 1.0 + (turn_rate_mag * (@abs(self.speed) / p.fbw_g_scale)) + boost_g + drift_g;
        self.g_load = math.lerpf(self.g_load, dynamic_g, 1.0 - @exp(-dt / 0.08));

        const boost_turb: f32 = if (in.boost or self.gear >= 7) 0.35 else 0.0;
        const drift_turb: f32 = if (is_drift) 0.65 else 0.0;
        const cloud_turb: f32 = if (self.weather.in_cloud) 0.18 else 0.0;
        const gust_turb: f32 = if (self.weather.gust_active) 0.22 else 0.0;
        const turb_raw = @abs(self.rates.x) * 0.45 + @abs(self.rates.y) * 0.45 + @abs(self.rates.z) * 0.30 +
            self.aoa * 2.2 + boost_turb + drift_turb + cloud_turb + gust_turb + wind.len() * 0.02;
        self.turb = math.lerpf(self.turb, math.clamp01(turb_raw), 1.0 - @exp(-dt / 0.09));
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
    pos: Vec3 = Vec3.init(0, planet.radius + 504.0, 13),
    up: Vec3 = Vec3.up,
    fov: f32 = math.radians(65),
    eye_view: Mat4 = Mat4.identity,
    zoom_active: bool = false,

    /// Chase camera with spherical local-up reference, positional lag, and smooth 360 roll follow.
    pub fn update(self: *Camera, dt: f32, ppos: Vec3, prot: Quat, speed: f32, p: Params) void {
        const fwd = prot.rotate(Vec3.forward);
        const pup = prot.rotate(Vec3.up);
        const speed_t = math.clamp01((speed - p.min_speed) / (p.boost - p.min_speed));
        const base_dist: f32 = if (self.zoom_active) 7.5 else 12.5;
        const max_dist: f32 = if (self.zoom_active) 10.5 else 16.5;
        const follow_dist = math.lerpf(base_dist, max_dist, speed_t);
        const up_h: f32 = if (self.zoom_active) 2.2 else 3.5;
        const desired = ppos.sub(fwd.scale(follow_dist)).add(pup.scale(up_h));
        const kp = 1.0 - @exp(-dt / 0.025);
        self.pos = Vec3.lerp(self.pos, desired, kp);
        const offset = self.pos.sub(ppos);
        const dist = offset.len();
        if (dist > 22.0) {
            self.pos = ppos.add(offset.scale(22.0 / dist));
        } else if (dist < 6.0 and !self.zoom_active) {
            const safe_dist: f32 = 6.0;
            const off_n = if (dist > 1e-3) offset.scale(1.0 / dist) else pup;
            self.pos = ppos.add(off_n.scale(safe_dist));
        }

        // Terrain clearance clamp: chase camera must never penetrate below planet terrain or ocean
        const cam_u = self.pos.norm();
        const cam_surf = planet.surfaceRadius(cam_u);
        const cam_min_r = cam_surf + 3.0;
        if (self.pos.len() < cam_min_r) {
            self.pos = cam_u.scale(cam_min_r);
        }

        // Smoothly track the airplane's local up (pup) across all 360° of roll.
        // This ensures perfectly continuous camera rotation without sudden threshold flips,
        // gimbal lock, or jarring discontinuities at 90° or when inverted.
        const want_up = pup;
        const ku = 1.0 - @exp(-dt / 0.09);
        self.up = Vec3.lerp(self.up, want_up, ku).norm();

        const look_dist: f32 = if (self.zoom_active) 120.0 else 30.0;
        const look = ppos.add(fwd.scale(look_dist));
        self.eye_view = Mat4.lookAt(self.pos, look, self.up);

        // FOV kick with speed + combat optic telephoto zoom (22° FOV).
        const target_fov = if (self.zoom_active)
            math.radians(22.0)
        else blk: {
            const t = math.clamp01((speed - p.cruise * 0.6) / (p.boost - p.cruise * 0.6));
            break :blk math.radians(62.0 + 28.0 * t);
        };
        self.fov = math.lerpf(self.fov, target_fov, 1.0 - @exp(-dt / 0.12));
    }

    pub fn forward(self: *const Camera, ppos: Vec3) Vec3 {
        return ppos.sub(self.pos).norm();
    }

    pub fn viewProj(self: *const Camera, aspect: f32) Mat4 {
        return Mat4.perspective(self.fov, aspect, 0.5, 280000.0).mul(self.eye_view);
    }
};

test "continuous 360 roll without latching or stopping" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 120.0;

    // Holding roll input rolls continuously through full 360° rotations without halting
    var passed_90 = false;
    var passed_180 = false;
    var passed_270 = false;
    var i: usize = 0;
    while (i < 240) : (i += 1) {
        plane.step(dt, .{ .roll = 1.0 }, &carriers);
        const right = plane.rot.rotate(Vec3.init(1, 0, 0));
        const pup = plane.rot.rotate(Vec3.up);
        const up_ref = plane.pos.norm();
        const roll_ang = std.math.atan2(-right.dot(up_ref), pup.dot(up_ref));

        if (@abs(roll_ang - (std.math.pi * 0.5)) < 0.15) passed_90 = true;
        if (@abs(@abs(roll_ang) - std.math.pi) < 0.15) passed_180 = true;
        if (@abs(roll_ang - (-std.math.pi * 0.5)) < 0.15) passed_270 = true;
    }
    try std.testing.expect(passed_90);
    try std.testing.expect(passed_180);
    try std.testing.expect(passed_270);
}

test "stable 90 degree knife edge sitting" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 120.0;

    // Roll right until near 90° (+1.57 rad)
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        plane.step(dt, .{ .roll = 1.0 }, &carriers);
        const right = plane.rot.rotate(Vec3.init(1, 0, 0));
        const pup = plane.rot.rotate(Vec3.up);
        const up_ref = plane.pos.norm();
        const roll_ang = std.math.atan2(-right.dot(up_ref), pup.dot(up_ref));
        if (roll_ang >= 1.48) break;
    }

    // Release roll stick (hands off roll) -> plane sits stably at 90°
    i = 0;
    while (i < 80) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const right_sit = plane.rot.rotate(Vec3.init(1, 0, 0));
    const pup_sit = plane.rot.rotate(Vec3.up);
    const up_ref_sit = plane.pos.norm();
    const settled_roll = std.math.atan2(-right_sit.dot(up_ref_sit), pup_sit.dot(up_ref_sit));
    // Must be sitting within ~5° of exact 90° (1.5708 rad)
    try std.testing.expect(@abs(settled_roll - (std.math.pi * 0.5)) < 0.10);
}

test "subtle gravitation toward wings level without violent snap" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 120.0;

    // Small bank angle ~0.25 rad (~14°)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        plane.step(dt, .{ .roll = 1.0 }, &carriers);
    }
    // Let residual roll rate damp
    i = 0;
    while (i < 15) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const right0 = plane.rot.rotate(Vec3.init(1, 0, 0));
    const pup0 = plane.rot.rotate(Vec3.up);
    const initial_roll = std.math.atan2(-right0.dot(plane.pos.norm()), pup0.dot(plane.pos.norm()));
    try std.testing.expect(initial_roll > 0.10 and initial_roll < 0.40);

    // Release controls -> subtle gravitation brings it closer to wings-level
    i = 0;
    while (i < 120) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const right1 = plane.rot.rotate(Vec3.init(1, 0, 0));
    const pup1 = plane.rot.rotate(Vec3.up);
    const gravitated_roll = std.math.atan2(-right1.dot(plane.pos.norm()), pup1.dot(plane.pos.norm()));
    // Subtly drifted closer to 0
    try std.testing.expect(gravitated_roll < initial_roll);
}

test "intermediate bank angle preserves progression without snapping" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 120.0;

    // Roll to ~40° (~0.70 rad)
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        plane.step(dt, .{ .roll = 1.0 }, &carriers);
    }
    // Let angular rate settle
    i = 0;
    while (i < 20) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const right_hold = plane.rot.rotate(Vec3.init(1, 0, 0));
    const pup_hold = plane.rot.rotate(Vec3.up);
    const hold_roll = std.math.atan2(-right_hold.dot(plane.pos.norm()), pup_hold.dot(plane.pos.norm()));
    // Release roll input -> angle is preserved at intermediate angle (no auto-snap to 0 or 90)
    try std.testing.expect(hold_roll > 0.45 and hold_roll < 0.85);

    // After 60 more frames, verify it still stays at intermediate angle and does not pull back to 0
    i = 0;
    while (i < 60) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const right_hold2 = plane.rot.rotate(Vec3.init(1, 0, 0));
    const pup_hold2 = plane.rot.rotate(Vec3.up);
    const hold_roll2 = std.math.atan2(-right_hold2.dot(plane.pos.norm()), pup_hold2.dot(plane.pos.norm()));
    try std.testing.expect(hold_roll2 > 0.45 and hold_roll2 < 0.85);
}

test "inverted flight stability and full control variability" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 120.0;

    // Roll to inverted (upside down)
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        plane.step(dt, .{ .roll = 1.0 }, &carriers);
        const pup = plane.rot.rotate(Vec3.up);
        if (pup.dot(plane.pos.norm()) < -0.98) break;
    }

    // Hands off roll: stays inverted
    i = 0;
    while (i < 30) : (i += 1) {
        plane.step(dt, .{ .roll = 0.0 }, &carriers);
    }
    const pup_inv = plane.rot.rotate(Vec3.up);
    try std.testing.expect(pup_inv.dot(plane.pos.norm()) < -0.90);

    // Full control variability: pitch down input commands full pitch rate without GCAS suppression
    var p_step: usize = 0;
    while (p_step < 15) : (p_step += 1) {
        plane.step(dt, .{ .pitch = -1.0 }, &carriers);
    }
    try std.testing.expect(plane.rates.x < -0.5);

    // Pitch up input commands full pitch rate
    p_step = 0;
    while (p_step < 30) : (p_step += 1) {
        plane.step(dt, .{ .pitch = 1.0 }, &carriers);
    }
    try std.testing.expect(plane.rates.x > 0.5);
}

test "impossible to run into the ground in steep dive" {
    var plane = Plane{};
    // Spawn at 400m altitude
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 60.0;

    // Force steep dive straight down toward the ground at high speed
    plane.speed = 3200.0;
    plane.setGear(7);
    const down_dir = plane.pos.norm().scale(-1.0);
    plane.dir = down_dir;

    // Command full pitch-down input directly into the ground for 300 frames
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        plane.step(dt, .{ .pitch = -1.0 }, &carriers);
        const surf_r = planet.surfaceRadius(plane.pos.norm());
        // Verify craft NEVER dies from ground impact
        try std.testing.expect(!plane.is_dead);
        // Verify craft position never penetrates beneath safe floor height
        try std.testing.expect(plane.pos.len() >= surf_r + 21.9);
        // Verify AGL altitude never goes below safe floor
        try std.testing.expect(plane.alt_agl >= 21.9);
    }
}

test "skimming along terrain floor preserves flight and never crashes" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 60.0;

    // Place craft right at the ground floor at high speed
    const u = plane.pos.norm();
    const surf_r = planet.surfaceRadius(u);
    plane.pos = u.scale(surf_r + 22.0);
    plane.speed = 2600.0;

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        // Alternating extreme dive stick and neutral controls
        const p_in: f32 = if (i % 20 < 10) -1.0 else 0.0;
        plane.step(dt, .{ .pitch = p_in }, &carriers);
        const cur_surf = planet.surfaceRadius(plane.pos.norm());
        try std.testing.expect(!plane.is_dead);
        try std.testing.expect(plane.pos.len() >= cur_surf + 21.9);
        const cur_radial_v = plane.dir.dot(plane.pos.norm());
        // Right at the floor (within 3m of 22m safe floor), downward velocity must be deflected
        if (plane.pos.len() - cur_surf < 25.0) {
            try std.testing.expect(cur_radial_v >= -0.05);
        }
    }
}

test "unassisted flight mild g-force fbw limits high-speed pitch rate and caps g-load" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 60.0;

    // Set high-speed boost/cruise (3800 m/s)
    plane.speed = 3800.0;
    plane.setGear(8);

    // Apply full backstick (+1.0 pitch) for 60 frames (1.0 second)
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        plane.step(dt, .{ .pitch = 1.0 }, &carriers);
    }

    // Dynamic G-load must be capped within ~9.0G structural limit (never blowing out into 15G+)
    try std.testing.expect(plane.g_load <= 9.25);
    try std.testing.expect(plane.g_load >= 5.0);

    // Pitch rate must be governed by FBW to ~0.88 rad/s, not the raw mechanical 1.48 rad/s
    const max_allowed_pitch_rate = ((plane.params.fbw_g_max - 1.0) * plane.params.fbw_g_scale) / plane.speed;
    try std.testing.expect(plane.rates.x <= max_allowed_pitch_rate + 0.15);
}

test "unassisted flight preserves full pitch rate at low speeds" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const carriers = [_]planet.AircraftCarrier{};
    const dt: f32 = 1.0 / 60.0;

    // Low speed (500 m/s)
    plane.speed = 500.0;
    plane.setGear(2);

    // Apply full backstick (+1.0 pitch) for 60 frames
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        plane.step(dt, .{ .pitch = 1.0 }, &carriers);
    }

    // Low speed maneuverability must remain 100% snappy (reaching full ~1.48 rad/s rate)
    try std.testing.expect(plane.rates.x >= 1.40);
}

test "assisted bezier auto-guide fbw limits g-load and bleeds induced drag" {
    var plane = Plane{};
    plane.spawnAt(Vec3.init(0, 1, 0), Vec3.forward);
    const dt: f32 = 1.0 / 60.0;

    plane.speed = 3400.0;
    const initial_speed = plane.speed;

    // Target placed at high angle requiring a hard turn
    const fwd = plane.rot.rotate(Vec3.forward);
    const right = plane.rot.rotate(Vec3.init(1, 0, 0));
    const target_pos = plane.pos.add(fwd.scale(1500.0)).add(right.scale(1500.0));
    const target_dir = right;
    const target_speed: f32 = 1800.0;
    const lead_pos = target_pos.add(target_dir.scale(target_speed * 0.5));

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        plane.applyBezierAutoGuide(dt, lead_pos, target_pos, target_dir, target_speed, 3.5);
    }

    // G-load capped within structural envelope
    try std.testing.expect(plane.g_load <= 9.25);
    // FBW induced drag bleed should have bled some kinetic energy
    try std.testing.expect(plane.speed < initial_speed);
}

