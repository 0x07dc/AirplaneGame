//! AI Dogfight & Team Battle System on the Spherical Planet.
//! Handles friendly (Blue) and enemy (Red) AI fighter squadrons:
//! - Formation flight and combat patrols around home aircraft carriers
//! - Pursuit, evasion, lead-pursuit aiming, and dogfighting
//! - Laser and missile weapons firing
//! - Hit detection, damage, health bars, explosion debris, and carrier respawns.
const std = @import("std");
const math = @import("math.zig");
const planet = @import("planet.zig");
const flight = @import("flight.zig");
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Team = planet.Team;

pub const AiState = enum {
    patrol,
    chase,
    barrel_roll,
    immelmann,
    break_turn,
    boom_and_zoom,
    evade,
    respawning,
};

pub const AiFighter = struct {
    active: bool = true,
    team: Team,
    pos: Vec3,
    prev_pos: Vec3,
    rot: Quat,
    prev_rot: Quat,
    dir: Vec3,
    speed: f32 = 2200.0,
    health: f32 = 100.0,
    max_health: f32 = 100.0,
    laser_cd: f32 = 0,
    missile_cd: f32 = 0,
    target_idx: ?usize = null, // index into planes/AI (or special marker for player)
    target_is_player: bool = false,
    state: AiState = .patrol,
    state_timer: f32 = 0,
    maneuver_timer: f32 = 0,
    maneuver_roll: f32 = 0,
    respawn_timer: f32 = 0,
    home_carrier: usize = 0,
    patrol_angle: f32 = 0,
    patrol_radius: f32 = 1600.0,
    patrol_alt: f32 = 420.0,
    formation_slot: usize = 0,
    kills: u32 = 0,

    pub fn isAlive(self: *const AiFighter) bool {
        return self.active and self.health > 0.0 and self.state != .respawning;
    }
};

pub const Explosion = struct {
    active: bool = false,
    pos: Vec3 = Vec3.zero,
    age: f32 = 0,
    max_age: f32 = 0.95,
    team: Team = .enemy,
};

pub const BattleManager = struct {
    const max_ai = 32;
    fighters: [max_ai]AiFighter = undefined,
    fighter_count: usize = 0,
    explosions: [48]Explosion = [_]Explosion{.{}} ** 48,
    next_expl: usize = 0,
    blue_score: u32 = 0,
    red_score: u32 = 0,

    pub fn init(self: *BattleManager, carriers: []const planet.AircraftCarrier, requested_count: usize) void {
        self.fighter_count = 0;
        self.blue_score = 0;
        self.red_score = 0;

        const effective_total = if (requested_count == 0) max_ai else @min(requested_count, max_ai);
        const per_team = @max(1, effective_total / 2);

        // Collect all friendly and enemy carrier indices to distribute squadrons
        var friendly_carriers: [16]usize = undefined;
        var friendly_c_count: usize = 0;
        var enemy_carriers: [16]usize = undefined;
        var enemy_c_count: usize = 0;

        for (carriers, 0..) |car, i| {
            if (car.team == .friendly and friendly_c_count < friendly_carriers.len) {
                friendly_carriers[friendly_c_count] = i;
                friendly_c_count += 1;
            } else if (car.team == .enemy and enemy_c_count < enemy_carriers.len) {
                enemy_carriers[enemy_c_count] = i;
                enemy_c_count += 1;
            }
        }

        // Friendly Blue fighters
        var i: usize = 0;
        while (i < per_team and self.fighter_count < max_ai) : (i += 1) {
            const c_idx = if (friendly_c_count > 0) friendly_carriers[i % friendly_c_count] else 0;
            const car = carriers[c_idx];
            const p_ang = @as(f32, @floatFromInt(i)) * (std.math.pi * 2.0 / 8.0);
            const alt = 360.0 + @as(f32, @floatFromInt(i % 3)) * 80.0;
            const r_orbit: f32 = 1400.0 + @as(f32, @floatFromInt(i % 4)) * 180.0;

            const c_dir = car.dir;
            const ref = if (@abs(c_dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
            const east = ref.cross(c_dir).norm();
            const north = c_dir.cross(east).norm();

            const e_m = @cos(p_ang) * r_orbit;
            const n_m = @sin(p_ang) * r_orbit;
            const pos_dir = c_dir.add(east.scale(e_m / planet.radius)).add(north.scale(n_m / planet.radius)).norm();
            const pos = pos_dir.scale(planet.radius + alt);

            const fwd = east.scale(-@sin(p_ang)).add(north.scale(@cos(p_ang))).norm();
            const z_axis = fwd.scale(-1);
            const right = pos_dir.cross(z_axis).norm();
            const y_axis = z_axis.cross(right).norm();
            const rot = planet.fromBasis(right, y_axis, z_axis);

            self.fighters[self.fighter_count] = .{
                .active = true,
                .team = .friendly,
                .pos = pos,
                .prev_pos = pos,
                .rot = rot,
                .prev_rot = rot,
                .dir = fwd,
                .speed = 2100.0 + @as(f32, @floatFromInt(i * 45)),
                .health = 100.0,
                .max_health = 100.0,
                .laser_cd = 0.2 + @as(f32, @floatFromInt(i)) * 0.1,
                .missile_cd = 1.0 + @as(f32, @floatFromInt(i)) * 0.3,
                .home_carrier = c_idx,
                .patrol_angle = p_ang,
                .patrol_radius = r_orbit,
                .patrol_alt = alt,
                .formation_slot = i,
            };
            self.fighter_count += 1;
        }

        // Enemy Red fighters
        var j: usize = 0;
        while (j < per_team and self.fighter_count < max_ai) : (j += 1) {
            const c_idx = if (enemy_c_count > 0) enemy_carriers[j % enemy_c_count] else 0;
            const car = carriers[c_idx];
            const p_ang = @as(f32, @floatFromInt(j)) * (std.math.pi * 2.0 / 8.0);
            const alt = 380.0 + @as(f32, @floatFromInt(j % 3)) * 80.0;
            const r_orbit: f32 = 1500.0 + @as(f32, @floatFromInt(j % 4)) * 180.0;

            const c_dir = car.dir;
            const ref = if (@abs(c_dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
            const east = ref.cross(c_dir).norm();
            const north = c_dir.cross(east).norm();

            const e_m = @cos(p_ang) * r_orbit;
            const n_m = @sin(p_ang) * r_orbit;
            const pos_dir = c_dir.add(east.scale(e_m / planet.radius)).add(north.scale(n_m / planet.radius)).norm();
            const pos = pos_dir.scale(planet.radius + alt);

            const fwd = east.scale(-@sin(p_ang)).add(north.scale(@cos(p_ang))).norm();
            const z_axis = fwd.scale(-1);
            const right = pos_dir.cross(z_axis).norm();
            const y_axis = z_axis.cross(right).norm();
            const rot = planet.fromBasis(right, y_axis, z_axis);

            self.fighters[self.fighter_count] = .{
                .active = true,
                .team = .enemy,
                .pos = pos,
                .prev_pos = pos,
                .rot = rot,
                .prev_rot = rot,
                .dir = fwd,
                .speed = 2150.0 + @as(f32, @floatFromInt(j * 40)),
                .health = 100.0,
                .max_health = 100.0,
                .laser_cd = 0.2 + @as(f32, @floatFromInt(j)) * 0.1,
                .missile_cd = 1.0 + @as(f32, @floatFromInt(j)) * 0.3,
                .home_carrier = c_idx,
                .patrol_angle = p_ang,
                .patrol_radius = r_orbit,
                .patrol_alt = alt,
                .formation_slot = j,
            };
            self.fighter_count += 1;
        }
    }

    /// Replaces an active AI fighter on the given team with a joined human player,
    /// so the total number of combatants in the airspace remains constant.
    pub fn replaceAiWithPlayer(self: *BattleManager, team: Team) ?usize {
        for (self.fighters[0..self.fighter_count], 0..) |*f, idx| {
            if (f.active and f.team == team) {
                f.active = false;
                return idx;
            }
        }
        for (self.fighters[0..self.fighter_count], 0..) |*f, idx| {
            if (f.active) {
                f.active = false;
                return idx;
            }
        }
        return null;
    }

    pub fn spawnExplosion(self: *BattleManager, pos: Vec3, team: Team) void {
        self.explosions[self.next_expl] = .{
            .active = true,
            .pos = pos,
            .age = 0,
            .max_age = 0.95,
            .team = team,
        };
        self.next_expl = (self.next_expl + 1) % self.explosions.len;
    }

    /// Evaluates AI flight controls, targeting, shooting, health, and respawns.
    pub fn step(
        self: *BattleManager,
        dt: f32,
        player: *flight.Plane,
        carriers: []const planet.AircraftCarrier,
        weapons_spawn_laser: *const fn (origin: Vec3, vel: Vec3, rot: Quat, team: Team) void,
        weapons_spawn_missile: *const fn (origin: Vec3, vel: Vec3, rot: Quat, team: Team) void,
    ) void {
        // Step explosions
        for (&self.explosions) |*ex| {
            if (!ex.active) continue;
            ex.age += dt;
            if (ex.age >= ex.max_age) ex.active = false;
        }

        // Step fighters
        for (self.fighters[0..self.fighter_count], 0..) |*ai, ai_idx| {
            if (!ai.active) continue;

            ai.prev_pos = ai.pos;
            ai.prev_rot = ai.rot;

            if (ai.state == .respawning) {
                ai.respawn_timer -= dt;
                if (ai.respawn_timer <= 0.0) {
                    // Respawn above home carrier
                    if (ai.home_carrier < carriers.len) {
                        const car = carriers[ai.home_carrier];
                        const alt = ai.patrol_alt;
                        ai.pos = car.pos.add(car.dir.scale(alt)).add(car.fwd.scale(80.0));
                        ai.prev_pos = ai.pos;
                        ai.rot = car.rot;
                        ai.prev_rot = car.rot;
                        ai.dir = car.fwd;
                        ai.speed = 2200.0;
                        ai.health = ai.max_health;
                        ai.state = .patrol;
                    }
                }
                continue;
            }

            ai.laser_cd = @max(0.0, ai.laser_cd - dt);
            ai.missile_cd = @max(0.0, ai.missile_cd - dt);
            ai.state_timer += dt;

            // Target selection: search for nearest opposing fighter (or player)
            var target_pos: ?Vec3 = null;
            var target_vel: Vec3 = Vec3.zero;
            var min_dist_sq: f32 = 8000.0 * 8000.0;

            // Check player
            if (ai.team != player.team and player.health > 0.0) {
                const to_p = player.pos.sub(ai.pos);
                const d2 = to_p.x * to_p.x + to_p.y * to_p.y + to_p.z * to_p.z;
                if (d2 < min_dist_sq) {
                    min_dist_sq = d2;
                    target_pos = player.pos;
                    target_vel = player.dir.scale(player.speed);
                    ai.target_is_player = true;
                }
            }

            // Check AI enemies
            for (self.fighters[0..self.fighter_count], 0..) |*other, oi| {
                if (oi == ai_idx or !other.isAlive() or other.team == ai.team) continue;
                const to_o = other.pos.sub(ai.pos);
                const d2 = to_o.x * to_o.x + to_o.y * to_o.y + to_o.z * to_o.z;
                if (d2 < min_dist_sq) {
                    min_dist_sq = d2;
                    target_pos = other.pos;
                    target_vel = other.dir.scale(other.speed);
                    ai.target_idx = oi;
                    ai.target_is_player = false;
                }
            }

            const up_ref = ai.pos.norm();
            var desired_fwd = ai.dir;

            if (target_pos) |tpos| {
                const dist = @sqrt(min_dist_sq);
                ai.maneuver_timer -= dt;

                // Cycle between tactical maneuvers
                if (ai.maneuver_timer <= 0.0) {
                    ai.state = switch (ai.state) {
                        .chase => if (ai.health < 60.0) .barrel_roll else .break_turn,
                        .break_turn => .immelmann,
                        .immelmann => .boom_and_zoom,
                        .boom_and_zoom => .chase,
                        .barrel_roll => .chase,
                        else => .chase,
                    };
                    ai.maneuver_timer = switch (ai.state) {
                        .chase => 4.2,
                        .break_turn => 2.0,
                        .barrel_roll => 2.2,
                        .immelmann => 2.5,
                        .boom_and_zoom => 3.0,
                        else => 3.5,
                    };
                    ai.maneuver_roll = 0.0;
                }

                // Lead-pursuit intercept: estimate time to target
                const closing_speed = @max(1200.0, ai.speed);
                const lead_time = std.math.clamp(dist / closing_speed, 0.0, 1.8);
                const lead_tpos = tpos.add(target_vel.scale(lead_time));
                const to_lead = lead_tpos.sub(ai.pos).norm();

                switch (ai.state) {
                    .chase => {
                        desired_fwd = to_lead;
                        ai.speed = math.lerpf(ai.speed, 2250.0, dt * 2.0);
                    },
                    .break_turn => {
                        // Hard bank and break turn to create overshoot windows
                        const right_axis = up_ref.cross(ai.dir).norm();
                        const turn_side: f32 = if ((ai.formation_slot & 1) == 0) 1.0 else -1.0;
                        desired_fwd = ai.dir.scale(0.55).add(right_axis.scale(turn_side * 0.85)).norm();
                        ai.speed = math.lerpf(ai.speed, 1750.0, dt * 3.0); // tactical speed bleed
                    },
                    .barrel_roll => {
                        // Helical corkscrew evasion
                        ai.maneuver_roll += dt * 6.0;
                        const right_axis = up_ref.cross(ai.dir).norm();
                        const spiral_offset = right_axis.scale(@cos(ai.maneuver_roll) * 0.45).add(up_ref.scale(@sin(ai.maneuver_roll) * 0.45));
                        desired_fwd = to_lead.add(spiral_offset).norm();
                        ai.speed = math.lerpf(ai.speed, 2100.0, dt * 2.0);
                    },
                    .immelmann => {
                        // High pitch climb toward vertical then half-roll reverse
                        desired_fwd = ai.dir.scale(0.35).add(up_ref.scale(1.2)).norm();
                        ai.speed = math.lerpf(ai.speed, 2400.0, dt * 2.5);
                    },
                    .boom_and_zoom => {
                        // High-speed diving strafe pass
                        desired_fwd = tpos.sub(ai.pos).norm();
                        ai.speed = math.lerpf(ai.speed, 2800.0, dt * 3.0);
                    },
                    else => {
                        desired_fwd = to_lead;
                    },
                }

                // Fire weapons when aligned and in range!
                const aim_dot = ai.dir.dot(to_lead);
                if (dist < 4200.0 and aim_dot > 0.93) {
                    // Fire lasers
                    if (ai.laser_cd <= 0.0) {
                        ai.laser_cd = 0.16;
                        const right = ai.rot.rotate(Vec3.init(1, 0, 0));
                        const m_fwd = ai.rot.rotate(Vec3.forward);
                        const muzzle_spd = ai.speed + 5400.0;
                        const lvel = m_fwd.scale(muzzle_spd);
                        weapons_spawn_laser(ai.pos.add(right.scale(2.6)), lvel, ai.rot, ai.team);
                        weapons_spawn_laser(ai.pos.add(right.scale(-2.6)), lvel, ai.rot, ai.team);
                    }
                }
                if (dist < 3200.0 and dist > 400.0 and aim_dot > 0.90) {
                    // Fire missile
                    if (ai.missile_cd <= 0.0) {
                        ai.missile_cd = 3.2;
                        const m_fwd = ai.rot.rotate(Vec3.forward);
                        const mvel = ai.dir.scale(ai.speed).add(m_fwd.scale(700.0));
                        weapons_spawn_missile(ai.pos.add(ai.rot.rotate(Vec3.up).scale(-0.8)), mvel, ai.rot, ai.team);
                    }
                }
            } else {
                // Combat patrol around carrier or world zone
                ai.state = .patrol;
                ai.patrol_angle = @mod(ai.patrol_angle + 0.12 * dt, std.math.pi * 2.0);
                if (ai.home_carrier < carriers.len) {
                    const car = carriers[ai.home_carrier];
                    const c_dir = car.dir;
                    const ref = if (@abs(c_dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
                    const east = ref.cross(c_dir).norm();
                    const north = c_dir.cross(east).norm();

                    const e_m = @cos(ai.patrol_angle) * ai.patrol_radius;
                    const n_m = @sin(ai.patrol_angle) * ai.patrol_radius;
                    const dest_dir = c_dir.add(east.scale(e_m / planet.radius)).add(north.scale(n_m / planet.radius)).norm();
                    const dest_pos = dest_dir.scale(planet.radius + ai.patrol_alt);

                    desired_fwd = dest_pos.sub(ai.pos).norm();
                }
            }

            // Terrain avoidance (GCAS for AI)
            const surf_r = planet.surfaceRadius(up_ref);
            const alt = ai.pos.len() - surf_r;
            if (alt < 240.0) {
                // Blend desired direction upward away from the ground
                desired_fwd = desired_fwd.add(up_ref.scale(0.85)).norm();
            }

            // Steer velocity & rotation smoothly toward desired_fwd
            const turn_rate: f32 = 4.2;
            ai.dir = Vec3.lerp(ai.dir, desired_fwd, std.math.clamp(turn_rate * dt, 0.0, 1.0)).norm();

            const z_axis = ai.dir.scale(-1);
            const right = up_ref.cross(z_axis).norm();
            const y_axis = z_axis.cross(right).norm();
            const target_rot = planet.fromBasis(right, y_axis, z_axis);

            ai.rot = Quat.nlerp(ai.rot, target_rot, std.math.clamp(6.0 * dt, 0.0, 1.0));

            // Integrate position & parallel transport over spherical planet
            ai.pos = ai.pos.add(ai.dir.scale(ai.speed * dt));
            const new_up = ai.pos.norm();
            const curve_axis = up_ref.cross(new_up);
            const sin_curve = curve_axis.len();
            if (sin_curve > 1e-7) {
                const q_curve = Quat.fromAxisAngle(curve_axis.scale(1.0 / sin_curve), std.math.asin(std.math.clamp(sin_curve, -1.0, 1.0)));
                ai.rot = q_curve.mul(ai.rot).normalize();
                ai.dir = q_curve.rotate(ai.dir).norm();
            }

            // Hard ground floor clamp
            const min_r = planet.surfaceRadius(new_up) + 45.0;
            if (ai.pos.len() < min_r) {
                ai.pos = new_up.scale(min_r);
                if (ai.dir.dot(new_up) < 0.1) ai.dir = ai.dir.add(new_up.scale(0.2)).norm();
            }
        }
    }

    /// Checks projectile hits against fighters and player.
    pub fn handleHit(self: *BattleManager, target_ai_idx: ?usize, hit_player: bool, damage: f32, player: *flight.Plane) bool {
        if (hit_player) {
            if (player.is_dead) return false;
            player.health = @max(0.0, player.health - damage);
            if (player.health <= 0.0) {
                player.kill();
                self.spawnExplosion(player.pos, player.team);
                self.red_score += 1;
            }
            return true;
        }

        if (target_ai_idx) |idx| {
            if (idx < self.fighter_count) {
                var ai = &self.fighters[idx];
                if (!ai.isAlive()) return false;
                ai.health = @max(0.0, ai.health - damage);
                if (ai.health <= 0.0) {
                    self.spawnExplosion(ai.pos, ai.team);
                    ai.state = .respawning;
                    ai.respawn_timer = 4.5;
                    if (ai.team == .enemy) {
                        self.blue_score += 1;
                    } else {
                        self.red_score += 1;
                    }
                }
                return true;
            }
        }
        return false;
    }
};

test "AI vs AI dogfight simulation balance" {
    var battle = BattleManager{};
    const carriers = [_]planet.AircraftCarrier{
        .{
            .pos = Vec3.init(0, planet.radius, 0),
            .rot = Quat.identity,
            .fwd = Vec3.forward,
            .right = Vec3.init(1, 0, 0),
            .dir = Vec3.up,
            .team = .friendly,
            .color = Vec3.init(0.2, 0.4, 0.8),
        },
        .{
            .pos = Vec3.init(0, -planet.radius, 0),
            .rot = Quat.identity,
            .fwd = Vec3.forward,
            .right = Vec3.init(1, 0, 0),
            .dir = Vec3.init(0, -1, 0),
            .team = .enemy,
            .color = Vec3.init(0.8, 0.2, 0.2),
        },
    };
    battle.init(&carriers, 16);
    try std.testing.expectEqual(@as(usize, 16), battle.fighter_count);

    var dummy_player = flight.Plane{};
    dummy_player.pos = Vec3.init(planet.radius * 2.0, 0, 0); // far away
    dummy_player.health = 100.0;

    const dummyLaser = struct {
        fn spawn(_: Vec3, _: Vec3, _: Quat, _: planet.Team) void {}
    }.spawn;
    const dummyMissile = struct {
        fn spawn(_: Vec3, _: Vec3, _: Quat, _: planet.Team) void {}
    }.spawn;

    // Simulate 30 seconds of AI dogfight (1800 steps)
    var step_i: usize = 0;
    while (step_i < 1800) : (step_i += 1) {
        battle.step(1.0 / 60.0, &dummy_player, &carriers, dummyLaser, dummyMissile);
    }

    var active_count: usize = 0;
    for (battle.fighters[0..battle.fighter_count]) |*f| {
        if (f.active) active_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), active_count);
}
