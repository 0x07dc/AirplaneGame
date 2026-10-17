//! Procedural spherical planet: cube-sphere terrain, ocean, cities with streets,
//! buildings, cars, tiny pedestrians, and ocean fleets (regular boats & battleships).
const std = @import("std");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const Vec3 = math.Vec3;
const Quat = math.Quat;

pub const radius: f32 = 63900.0; // 63.9 km sea-level radius (~401.5 km circumference, 29% smaller than original 90 km, 0.71x original size)
pub const cloud_alt_base: f32 = 1650.0;

pub fn hash3(ix: i32, iy: i32, iz: i32) f32 {
    var h: u32 = @bitCast(ix *% 374761393 +% iy *% 668265263 +% iz *% 1442695041);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0x00ffffff)) / @as(f32, 0x00ffffff);
}

/// Smooth 3D value noise in [-1, 1].
pub fn noise3(p: Vec3) f32 {
    const fx = @floor(p.x);
    const fy = @floor(p.y);
    const fz = @floor(p.z);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const iz: i32 = @intFromFloat(fz);
    const tx = p.x - fx;
    const ty = p.y - fy;
    const tz = p.z - fz;
    const ux = tx * tx * (3.0 - 2.0 * tx);
    const uy = ty * ty * (3.0 - 2.0 * ty);
    const uz = tz * tz * (3.0 - 2.0 * tz);

    const c000 = hash3(ix, iy, iz);
    const c100 = hash3(ix + 1, iy, iz);
    const c010 = hash3(ix, iy + 1, iz);
    const c110 = hash3(ix + 1, iy + 1, iz);
    const c001 = hash3(ix, iy, iz + 1);
    const c101 = hash3(ix + 1, iy, iz + 1);
    const c011 = hash3(ix, iy + 1, iz + 1);
    const c111 = hash3(ix + 1, iy + 1, iz + 1);

    const x00 = math.lerpf(c000, c100, ux);
    const x10 = math.lerpf(c010, c110, ux);
    const x01 = math.lerpf(c001, c101, ux);
    const x11 = math.lerpf(c011, c111, ux);
    const y0 = math.lerpf(x00, x10, uy);
    const y1 = math.lerpf(x01, x11, uy);
    return math.lerpf(y0, y1, uz) * 2.0 - 1.0;
}

/// 5-octave fBm on 3D coordinates.
pub fn fbm(p: Vec3) f32 {
    var sum: f32 = 0;
    var amp: f32 = 0.52;
    var freq: f32 = 1.0;
    inline for (0..5) |_| {
        sum += amp * noise3(p.scale(freq));
        freq *= 2.07;
        amp *= 0.48;
    }
    return sum;
}

/// Deterministic candidate city centers on the sphere so `terrainElevation` can level city basins
/// before the planet mesh and city props are built.
const max_city_sites: usize = 22;
const CitySite = struct {
    dir: Vec3,
    elev: f32,
};

var cached_sites: [max_city_sites]CitySite = undefined;
var cached_sites_count: usize = 0;
var cached_sites_ready: bool = false;

fn rawTerrainElevation(dir: Vec3) f32 {
    const cont = fbm(dir.scale(2.8)) + 0.35 * fbm(dir.scale(8.5)) - 0.04;
    if (cont <= 0.0) {
        return cont * 600.0; // underwater depth
    }
    const ridge = 1.0 - @abs(noise3(dir.scale(14.0)));
    const mountains = ridge * ridge * fbm(dir.scale(22.0).add(Vec3.init(3.1, 1.7, -2.4)));
    const h = cont * 1650.0 + @max(0.0, mountains) * 1450.0 * math.clamp01(cont * 2.2);
    return h;
}

pub const max_base_sites: usize = 8;
pub const BaseSite = struct {
    dir: Vec3,
    elev: f32,
    team: Team,
};
pub var cached_base_sites: [max_base_sites]BaseSite = undefined;
pub var cached_base_sites_count: usize = 0;
pub var cached_base_sites_ready: bool = false;

pub fn ensureBaseSites() void {
    if (cached_base_sites_ready) return;
    ensureCitySites();
    cached_base_sites_count = 0;
    const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
    const candidates: usize = 700;
    const cand_f: f32 = @floatFromInt(candidates);
    var i: usize = 0;
    while (i < candidates and cached_base_sites_count < max_base_sites) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const y = 1.0 - (fi + 0.5) * (2.0 / cand_f);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const theta = golden_angle * fi * 1.55 + 1.25;
        const dir = Vec3.init(@cos(theta) * r, y, @sin(theta) * r).norm();

        const elev = rawTerrainElevation(dir);
        if (elev < 18.0 or elev > 260.0) continue;

        // Keep clear from all city sites (~4.5 km)
        var near_city = false;
        for (cached_sites[0..cached_sites_count]) |cs| {
            if (cs.dir.dot(dir) > 0.9985) {
                near_city = true;
                break;
            }
        }
        if (near_city) continue;

        // Keep clear from other bases
        var too_close = false;
        for (cached_base_sites[0..cached_base_sites_count]) |ob| {
            if (ob.dir.dot(dir) > 0.960) {
                too_close = true;
                break;
            }
        }
        if (too_close) continue;

        const team: Team = if (cached_base_sites_count % 2 == 0) .friendly else .enemy;
        cached_base_sites[cached_base_sites_count] = .{
            .dir = dir,
            .elev = std.math.clamp(elev, 28.0, 140.0),
            .team = team,
        };
        cached_base_sites_count += 1;
    }
    cached_base_sites_ready = true;
}

pub fn ensureCitySites() void {
    if (cached_sites_ready) return;
    cached_sites_count = 0;
    const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
    const candidates: usize = 600;
    const cand_f: f32 = @floatFromInt(candidates);
    var i: usize = 0;
    while (i < candidates and cached_sites_count < max_city_sites) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const y = 1.0 - (fi + 0.5) * (2.0 / cand_f);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const theta = golden_angle * fi;
        const dir = Vec3.init(@cos(theta) * r, y, @sin(theta) * r).norm();

        const elev = rawTerrainElevation(dir);
        if (elev < 24.0 or elev > 320.0) continue;

        var too_close = false;
        for (cached_sites[0..cached_sites_count]) |other| {
            if (other.dir.dot(dir) > 0.985) {
                too_close = true;
                break;
            }
        }
        if (too_close) continue;

        const ref = if (@abs(dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
        const east = ref.cross(dir).norm();
        const north = dir.cross(east).norm();
        const step_ang: f32 = 950.0 / radius;
        if (rawTerrainElevation(dir.add(east.scale(step_ang)).norm()) < 5.0) continue;
        if (rawTerrainElevation(dir.sub(east.scale(step_ang)).norm()) < 5.0) continue;
        if (rawTerrainElevation(dir.add(north.scale(step_ang)).norm()) < 5.0) continue;
        if (rawTerrainElevation(dir.sub(north.scale(step_ang)).norm()) < 5.0) continue;

        // Grade the city terrace slightly above the center elevation so the entire city sits on a flat plateau
        cached_sites[cached_sites_count] = .{
            .dir = dir,
            .elev = std.math.clamp(elev, 32.0, 180.0),
        };
        cached_sites_count += 1;
    }
    cached_sites_ready = true;
}

/// Signed terrain elevation relative to sea level (`> 0` is land, `<= 0` is ocean floor).
/// Automatically flattens terrain into level urban basins inside city footprints and military base compounds
/// so all buildings and military structures sit cleanly on flat graded ground.
pub fn terrainElevation(dir: Vec3) f32 {
    ensureCitySites();
    ensureBaseSites();
    const raw = rawTerrainElevation(dir);
    if (raw <= 0.0) return raw;

    // Check if within ~1,550 m of any city center
    for (cached_sites[0..cached_sites_count]) |site| {
        const d = site.dir.dot(dir);
        if (d > 0.9995) {
            const ang = std.math.acos(std.math.clamp(d, -1.0, 1.0));
            const dist_m = ang * radius;
            const inner_r: f32 = 920.0;
            const outer_r: f32 = 1550.0;
            if (dist_m <= inner_r) {
                return site.elev;
            } else if (dist_m < outer_r) {
                const t = (dist_m - inner_r) / (outer_r - inner_r);
                const s = t * t * (3.0 - 2.0 * t);
                return math.lerpf(site.elev, raw, s);
            }
        }
    }

    // Check if within ~2,200 m of any military base center (matches terrain quad resolution on 90km planet)
    for (cached_base_sites[0..cached_base_sites_count]) |base| {
        const d = base.dir.dot(dir);
        if (d > 0.9990) {
            const ang = std.math.acos(std.math.clamp(d, -1.0, 1.0));
            const dist_m = ang * radius;
            const inner_r: f32 = 850.0;
            const outer_r: f32 = 2200.0;
            if (dist_m <= inner_r) {
                return base.elev;
            } else if (dist_m < outer_r) {
                const t = (dist_m - inner_r) / (outer_r - inner_r);
                const s = t * t * (3.0 - 2.0 * t);
                return math.lerpf(base.elev, raw, s);
            }
        }
    }
    return raw;
}

/// Surface radius at unit direction `dir` (clamped to sea level `radius`).
pub fn surfaceRadius(dir: Vec3) f32 {
    return radius + @max(0.0, terrainElevation(dir));
}

pub const Atmosphere = struct {
    /// Evaluates deterministic global wind & thermal updraft vector at `pos` (m) and global `time` (s).
    /// Requires 0 bytes of network synchronization because it is a pure function of (pos, time).
    pub fn evalWind(pos: Vec3, time: f32) Vec3 {
        const d = pos.len();
        if (d < 100.0) return Vec3.zero;
        const norm_pos = pos.scale(1.0 / d);
        const alt = d - radius;
        if (alt < 0.0 or alt > 28000.0) return Vec3.zero;

        // 1. High-altitude Jet Stream:
        // Planetary jet stream circles latitudinally (eastward) between 3,500m and 14,000m altitude
        const lat = norm_pos.y;
        const lat_factor = @cos(lat * (std.math.pi * 0.5));
        var east = Vec3.init(-norm_pos.z, 0, norm_pos.x);
        const east_len = east.len();
        if (east_len > 1e-4) {
            east = east.scale(1.0 / east_len);
        } else {
            east = Vec3.init(1, 0, 0);
        }

        const jet_peak: f32 = 8000.0;
        const jet_band: f32 = 4500.0;
        const jet_diff = (alt - jet_peak) / jet_band;
        const jet_envelope = @exp(-jet_diff * jet_diff);
        const jet_speed = 75.0 * lat_factor * jet_envelope;
        var wind = east.scale(jet_speed);

        // 2. Thermal Updrafts over Land & Cities:
        // Land and city asphalt absorb heat, creating buoyant vertical air columns (+15 to +35 m/s)
        const elev = terrainElevation(norm_pos);
        if (elev > 10.0 and alt < 3500.0) {
            const thermal_t = math.clamp01(1.0 - (alt / 3500.0));
            const wave = 0.5 + 0.5 * @sin(norm_pos.x * 12.0 + norm_pos.z * 12.0 + time * 0.4);
            const updraft_speed = (18.0 + 14.0 * wave) * thermal_t;
            wind = wind.add(norm_pos.scale(updraft_speed));
        }

        // 3. Atmospheric turbulence / micro-buffeting:
        if (alt < 6000.0) {
            const turb_fade = math.clamp01(1.0 - (alt / 6000.0));
            const turb_x = noise3(norm_pos.scale(32.0).add(Vec3.init(time * 0.7, 0, 0)));
            const turb_y = noise3(norm_pos.scale(32.0).add(Vec3.init(0, time * 0.7, 0)));
            const turb_z = noise3(norm_pos.scale(32.0).add(Vec3.init(0, 0, time * 0.7)));
            wind = wind.add(Vec3.init(turb_x, turb_y, turb_z).scale(9.0 * turb_fade));
        }

        return wind;
    }
};

/// Biome color for a given unit direction and elevation above sea level.
pub fn biomeColor(dir: Vec3, elev: f32) Vec3 {
    const lat = @abs(dir.y);
    if (elev <= 0.5) {
        const shallow = math.clamp01(1.0 + elev / 220.0);
        const deep_col = mesh.srgb(16, 62, 138);
        const reef_col = mesh.srgb(36, 148, 196);
        return Vec3.lerp(deep_col, reef_col, shallow * shallow);
    }
    // Check if inside an urban city footprint -> paved urban plaza tone
    ensureCitySites();
    for (cached_sites[0..cached_sites_count]) |site| {
        const ang = std.math.acos(std.math.clamp(site.dir.dot(dir), -1.0, 1.0));
        if (ang * radius < 980.0) {
            return mesh.srgb(118, 124, 134);
        }
    }
    // Check if inside a military base compound -> reinforced military concrete / tarmac
    ensureBaseSites();
    for (cached_base_sites[0..cached_base_sites_count]) |base| {
        const ang = std.math.acos(std.math.clamp(base.dir.dot(dir), -1.0, 1.0));
        if (ang * radius < 320.0) {
            return if (base.team == .friendly) mesh.srgb(84, 98, 114) else mesh.srgb(114, 88, 84);
        }
    }
    if (elev < 42.0) {
        return mesh.srgb(228, 206, 148);
    }
    if (elev + lat * 650.0 > 1350.0) {
        return mesh.srgb(242, 246, 252);
    }
    if (elev > 820.0) {
        return mesh.srgb(122, 118, 114);
    }
    if (elev > 420.0) {
        return mesh.srgb(74, 108, 58);
    }
    const v = math.clamp01(0.5 + 0.5 * noise3(dir.scale(30.0)));
    return Vec3.lerp(mesh.srgb(84, 142, 66), mesh.srgb(112, 162, 74), v);
}

fn cubeDir(face: usize, u: f32, v: f32) Vec3 {
    return switch (face) {
        0 => Vec3.init(1, v, -u).norm(),
        1 => Vec3.init(-1, v, u).norm(),
        2 => Vec3.init(u, 1, -v).norm(),
        3 => Vec3.init(u, -1, v).norm(),
        4 => Vec3.init(u, v, 1).norm(),
        else => Vec3.init(-u, v, -1).norm(),
    };
}

/// Builds the full spherical planet mesh (6 cube-sphere faces, flat-shaded low-poly facets).
pub fn buildPlanet(alloc: std.mem.Allocator, grid: u32) !mesh.Builder {
    var b = mesh.Builder.init(alloc);
    errdefer b.deinit();

    const nf: f32 = @floatFromInt(grid);
    var face: usize = 0;
    while (face < 6) : (face += 1) {
        var iy: u32 = 0;
        while (iy < grid) : (iy += 1) {
            const va = (@as(f32, @floatFromInt(iy)) / nf) * 2.0 - 1.0;
            const vb = (@as(f32, @floatFromInt(iy + 1)) / nf) * 2.0 - 1.0;
            var ix: u32 = 0;
            while (ix < grid) : (ix += 1) {
                const ua = (@as(f32, @floatFromInt(ix)) / nf) * 2.0 - 1.0;
                const ub = (@as(f32, @floatFromInt(ix + 1)) / nf) * 2.0 - 1.0;

                const d00 = cubeDir(face, ua, va);
                const d10 = cubeDir(face, ub, va);
                const d11 = cubeDir(face, ub, vb);
                const d01 = cubeDir(face, ua, vb);

                const e00 = terrainElevation(d00);
                const e10 = terrainElevation(d10);
                const e11 = terrainElevation(d11);
                const e01 = terrainElevation(d01);

                const p00 = d00.scale(radius + @max(0.0, e00));
                const p10 = d10.scale(radius + @max(0.0, e10));
                const p11 = d11.scale(radius + @max(0.0, e11));
                const p01 = d01.scale(radius + @max(0.0, e01));

                const dm = d00.add(d10).add(d11).add(d01).norm();
                const em = (e00 + e10 + e11 + e01) * 0.25;
                const col = biomeColor(dm, em);
                const inside = dm.scale(radius * 0.5);

                try b.quad(p00, p10, p11, p01, col, inside);
            }
        }
    }
    return b;
}

/// Builds an inward-facing spherical sky dome mesh (`radius = 75,000 m`) so the fragment shader
/// can render a rich 3D directional + vertical sky gradient, sun disk, and compass bands.
pub fn buildSkyDome(alloc: std.mem.Allocator, grid: u32) !mesh.Builder {
    var b = mesh.Builder.init(alloc);
    errdefer b.deinit();

    const sky_r: f32 = 250000.0; // 250 km sky dome radius (well beyond 90 km planet)
    const nf: f32 = @floatFromInt(grid);
    // Sentinel vertex color > 20.0 tells mesh.frag this is the sky dome
    const sky_sentinel = Vec3.init(50.0, 50.0, 50.0);

    var face: usize = 0;
    while (face < 6) : (face += 1) {
        var iy: u32 = 0;
        while (iy < grid) : (iy += 1) {
            const va = (@as(f32, @floatFromInt(iy)) / nf) * 2.0 - 1.0;
            const vb = (@as(f32, @floatFromInt(iy + 1)) / nf) * 2.0 - 1.0;
            var ix: u32 = 0;
            while (ix < grid) : (ix += 1) {
                const ua = (@as(f32, @floatFromInt(ix)) / nf) * 2.0 - 1.0;
                const ub = (@as(f32, @floatFromInt(ix + 1)) / nf) * 2.0 - 1.0;

                const d00 = cubeDir(face, ua, va);
                const d10 = cubeDir(face, ub, va);
                const d11 = cubeDir(face, ub, vb);
                const d01 = cubeDir(face, ua, vb);

                const p00 = d00.scale(sky_r);
                const p10 = d10.scale(sky_r);
                const p11 = d11.scale(sky_r);
                const p01 = d01.scale(sky_r);

                const dm = d00.add(d10).add(d11).add(d01).norm();
                // Outside reference is beyond `sky_r` so quad normals point inward toward the camera
                const outside = dm.scale(sky_r * 1.5);

                try b.quad(p00, p10, p11, p01, sky_sentinel, outside);
            }
        }
    }
    return b;
}

/// Builds a stylized multi-puff low-poly cloud cluster in local tangent space (+Y up).
pub fn buildCloudCluster(alloc: std.mem.Allocator) !mesh.Builder {
    var b = mesh.Builder.init(alloc);
    errdefer b.deinit();
    const white = mesh.srgb(248, 250, 255);
    const puffs = [_][4]f32{
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ -0.75, -0.12, 0.15, 0.72 },
        .{ 0.78, -0.10, -0.12, 0.76 },
        .{ 0.15, -0.15, 0.68, 0.65 },
        .{ -0.20, 0.22, -0.45, 0.60 },
    };
    for (puffs) |pf| {
        const cx = pf[0];
        const cy = pf[1];
        const cz = pf[2];
        const s = pf[3];
        const rx = 0.65 * s;
        const ry = 0.34 * s;
        const rz = 0.55 * s;
        const p = [4]Vec3{
            Vec3.init(cx - rx, cy, cz - rz),
            Vec3.init(cx + rx, cy, cz - rz),
            Vec3.init(cx + rx, cy, cz + rz),
            Vec3.init(cx - rx, cy, cz + rz),
        };
        try b.slab(p, Vec3.init(0, ry, 0), white);
    }
    return b;
}

pub const CloudInstance = struct {
    dir: Vec3,
    rot: Quat,
    scale: Vec3,
    alt: f32,
    threshold: f32,
};

pub fn generateClouds(out: []CloudInstance) void {
    const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));
    const n_f: f32 = @floatFromInt(out.len);
    for (out, 0..) |*cl, i| {
        const fi: f32 = @floatFromInt(i);
        const y = 1.0 - (fi + 0.5) * (2.0 / n_f);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const theta = golden_angle * fi;
        const dir = Vec3.init(@cos(theta) * r, y, @sin(theta) * r).norm();

        const weather = 0.5 + 0.5 * fbm(dir.scale(3.2).add(Vec3.init(5.2, -3.1, 1.8)));
        const h = hash3(@intCast(i * 17), @intCast(i * 31), @intCast(i * 47));
        const threshold = math.clamp01(0.65 * (1.0 - weather) + 0.35 * h);

        const alt = cloud_alt_base + (h - 0.5) * 550.0;
        const horiz = 220.0 + h * 340.0;
        const vert = 90.0 + h * 110.0;
        cl.* = .{
            .dir = dir,
            .rot = tangentRotation(dir, theta * 3.7),
            .scale = Vec3.init(horiz, vert, horiz),
            .alt = alt,
            .threshold = threshold,
        };
    }
}

pub const City = struct {
    dir: Vec3,
    pos: Vec3 = Vec3.zero,
    east: Vec3,
    north: Vec3,
    street_start: u32 = 0,
    street_count: u32 = 0,
    building_start: u32 = 0,
    building_count: u32 = 0,
    car_start: u32 = 0,
    car_count: u32 = 0,
    ped_start: u32 = 0,
    ped_count: u32 = 0,
};

pub const PropInstance = struct {
    pos: Vec3,
    rot: Quat,
    scale: Vec3,
    color: Vec3,
    dir: Vec3,
    kind: u8 = 0,
};

pub const CityAgent = struct {
    city_idx: u16,
    along_north: bool, // true = travels along north axis, false = along east axis
    lane_offset: f32, // perpendicular offset (street coordinate + lane/sidewalk offset)
    half_len: f32, // travel extent [-half_len, +half_len]
    speed: f32, // m/s (signed)
    phase: f32, // initial distance offset
    color: Vec3,
};

pub const ShipKind = enum { regular_boat, battleship };

pub const ShipAgent = struct {
    kind: ShipKind,
    center_dir: Vec3,
    east: Vec3,
    north: Vec3,
    orbit_radius: f32, // meters on sea surface
    angular_speed: f32, // rad/s
    phase: f32,
    color: Vec3,
    health: f32 = 100.0,
    max_health: f32 = 100.0,
    alive: bool = true,
    death_timer: f32 = 0.0,
};

pub const Team = enum(u8) {
    friendly = 0, // Blue team (player's team)
    enemy = 1, // Red team
};

pub const AircraftCarrier = struct {
    team: Team,
    dir: Vec3, // unit sphere direction on ocean surface
    pos: Vec3, // world position at sea level (`dir.scale(radius)`)
    fwd: Vec3, // bow direction (unit tangent vector along takeoff direction)
    right: Vec3, // starboard direction (`fwd.cross(dir)`)
    rot: Quat, // world orientation (local -Z = `fwd`, +Y = `dir`, +X = `right`)
    color: Vec3, // team accent color (Blue vs Red)
};

pub const BaseKind = enum(u8) {
    command_bunker = 0,
    radar_station = 1,
    aircraft_hangar = 2,
    sam_battery = 3,
    fuel_depot = 4,
};

pub const BaseStructure = struct {
    kind: BaseKind,
    pos: Vec3,
    rot: Quat,
    team: Team,
    health: f32 = 140.0,
    max_health: f32 = 140.0,
    alive: bool = true,
    death_timer: f32 = 0.0,
    points: i32 = 5,
};

pub const MilitaryBase = struct {
    team: Team,
    dir: Vec3,
    pos: Vec3,
    rot: Quat,
    east: Vec3,
    north: Vec3,
    name: [24]u8 = [_]u8{0} ** 24,
    name_len: usize = 0,
    structures: [8]BaseStructure = undefined,
    structure_count: usize = 0,
};

pub const WorldObjects = struct {
    cities: [22]City = undefined,
    city_count: usize = 0,
    streets: [5200]PropInstance = undefined,
    street_count: usize = 0,
    buildings: [2200]PropInstance = undefined,
    building_count: usize = 0,
    cars: [600]CityAgent = undefined,
    car_count: usize = 0,
    peds: [900]CityAgent = undefined,
    ped_count: usize = 0,
    ships: [220]ShipAgent = undefined,
    ship_count: usize = 0,
    carriers: [16]AircraftCarrier = undefined,
    carrier_count: usize = 0,
    blimps: [32]BlimpAgent = undefined,
    blimp_count: usize = 0,
    bases: [8]MilitaryBase = undefined,
    base_count: usize = 0,
};

pub const BlimpAgent = struct {
    center_dir: Vec3,
    east: Vec3,
    north: Vec3,
    orbit_radius: f32, // meters along tangent
    angular_speed: f32, // rad/s
    altitude: f32, // meters above terrain/ocean (e.g. 360 - 520 m)
    phase: f32,
    health: f32 = 80.0,
    max_health: f32 = 80.0,
    alive: bool = true,
    death_timer: f32 = 0.0,
};

/// Populates scattered cities (street grids, buildings, cars, pedestrians) on land,
/// naval fleets / civilian boats, and team Aircraft Carriers across the oceans.
pub fn generateWorldObjects(w: *WorldObjects, bld_palette: []const Vec3) void {
    w.city_count = 0;
    w.street_count = 0;
    w.building_count = 0;
    w.car_count = 0;
    w.ped_count = 0;
    w.ship_count = 0;
    w.carrier_count = 0;

    const golden_angle: f32 = std.math.pi * (3.0 - @sqrt(5.0));

    // 1. Place City Centers from the pre-graded flat city basins around the globe
    ensureCitySites();
    for (cached_sites[0..cached_sites_count]) |site| {
        if (w.city_count >= w.cities.len) break;
        const dir = site.dir;
        const ref = if (@abs(dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
        const east = ref.cross(dir).norm();
        const north = dir.cross(east).norm();

        const city_idx: u16 = @intCast(w.city_count);
        const st_start = w.street_count;
        const bld_start = w.building_count;
        const car_start = w.car_count;
        const ped_start = w.ped_count;

        const c_pos = dir.scale(surfaceRadius(dir));
        w.cities[w.city_count] = .{
            .dir = dir,
            .pos = c_pos,
            .east = east,
            .north = north,
            .street_start = @intCast(st_start),
            .building_start = @intCast(bld_start),
            .car_start = @intCast(car_start),
            .ped_start = @intCast(ped_start),
        };
        const cur_city = w.city_count;
        w.city_count += 1;

        buildCityContent(w, city_idx, bld_palette);

        w.cities[cur_city].street_count = @intCast(w.street_count - st_start);
        w.cities[cur_city].building_count = @intCast(w.building_count - bld_start);
        w.cities[cur_city].car_count = @intCast(w.car_count - car_start);
        w.cities[cur_city].ped_count = @intCast(w.ped_count - ped_start);
    }

    // 2. Populate Ocean Fleets (Battleships + Regular Boats) in deep water
    const ship_cands: usize = 900;
    const ship_cand_f: f32 = @floatFromInt(ship_cands);
    var si: usize = 0;
    const boat_colors = [_]Vec3{
        mesh.srgb(225, 72, 52),
        mesh.srgb(52, 138, 215),
        mesh.srgb(240, 185, 55),
        mesh.srgb(65, 175, 115),
        mesh.srgb(235, 238, 245),
    };
    while (si < ship_cands and w.ship_count < w.ships.len) : (si += 1) {
        const fi: f32 = @floatFromInt(si);
        const y = 1.0 - (fi + 0.5) * (2.0 / ship_cand_f);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const theta = golden_angle * fi * 1.3;
        const dir = Vec3.init(@cos(theta) * r, y, @sin(theta) * r).norm();

        // Must be open ocean (including patrol radius)
        if (terrainElevation(dir) > -25.0) continue;
        const ref = if (@abs(dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
        const east = ref.cross(dir).norm();
        const north = dir.cross(east).norm();
        const check_ang: f32 = 600.0 / radius;
        if (terrainElevation(dir.add(east.scale(check_ang)).norm()) > -8.0) continue;
        if (terrainElevation(dir.sub(east.scale(check_ang)).norm()) > -8.0) continue;
        if (terrainElevation(dir.add(north.scale(check_ang)).norm()) > -8.0) continue;
        if (terrainElevation(dir.sub(north.scale(check_ang)).norm()) > -8.0) continue;

        const h = hash3(@intCast(si * 19), @intCast(si * 37), @intCast(si * 61));
        const is_battleship = (si % 4 == 0);
        const orbit_r: f32 = if (is_battleship) 380.0 + h * 320.0 else 220.0 + h * 280.0;
        const lin_speed: f32 = if (is_battleship) 24.0 + h * 14.0 else 36.0 + h * 24.0;
        const sign: f32 = if ((si & 1) == 0) 1.0 else -1.0;

        w.ships[w.ship_count] = .{
            .kind = if (is_battleship) .battleship else .regular_boat,
            .center_dir = dir,
            .east = east,
            .north = north,
            .orbit_radius = orbit_r,
            .angular_speed = sign * (lin_speed / orbit_r),
            .phase = h * std.math.pi * 2.0,
            .color = if (is_battleship) Vec3.init(1, 1, 1) else boat_colors[si % boat_colors.len],
        };
        w.ship_count += 1;
    }

    // 3. Populate Team Aircraft Carriers (8 Friendly Blue Team + 8 Enemy Red Team) scattered across the oceans
    const friendly_col = Vec3.init(0.20, 0.65, 1.35); // bright azure blue team markings
    const enemy_col = Vec3.init(1.40, 0.25, 0.20); // bright crimson red team markings
    const carrier_cands: usize = 600;
    const carrier_cand_f: f32 = @floatFromInt(carrier_cands);
    var kc: usize = 0;
    while (kc < carrier_cands and w.carrier_count < w.carriers.len) : (kc += 1) {
        const fi: f32 = @floatFromInt(kc);
        const y = 1.0 - (fi + 0.5) * (2.0 / carrier_cand_f);
        const r = @sqrt(@max(0.0, 1.0 - y * y));
        const theta = golden_angle * fi * 1.7 + 0.8;
        const dir = Vec3.init(@cos(theta) * r, y, @sin(theta) * r).norm();

        // Must be in open water with clear sea approach & takeoff corridor (~1.5 km around)
        if (terrainElevation(dir) > -20.0) continue;
        const ref = if (@abs(dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
        const east = ref.cross(dir).norm();
        const north = dir.cross(east).norm();
        const clear_ang: f32 = 1400.0 / radius;
        if (terrainElevation(dir.add(east.scale(clear_ang)).norm()) > -5.0) continue;
        if (terrainElevation(dir.sub(east.scale(clear_ang)).norm()) > -5.0) continue;
        if (terrainElevation(dir.add(north.scale(clear_ang)).norm()) > -5.0) continue;
        if (terrainElevation(dir.sub(north.scale(clear_ang)).norm()) > -5.0) continue;

        // Well-spaced across the planet
        var too_close = false;
        for (w.carriers[0..w.carrier_count]) |other| {
            if (other.dir.dot(dir) > 0.93) { // ~21° apart (~11 km)
                too_close = true;
                break;
            }
        }
        if (too_close) continue;

        const yaw = hash3(@intCast(kc * 29), @intCast(kc * 53), 811) * std.math.pi * 2.0;
        const cy = @cos(yaw);
        const sy = @sin(yaw);
        const fwd = east.scale(cy).add(north.scale(sy)).norm();
        const z_axis = fwd.scale(-1);
        const right = dir.cross(z_axis).norm();
        const y_axis = z_axis.cross(right).norm();

        const team: Team = if (w.carrier_count % 2 == 0) .friendly else .enemy;
        w.carriers[w.carrier_count] = .{
            .team = team,
            .dir = dir,
            .pos = dir.scale(radius),
            .fwd = fwd,
            .right = right,
            .rot = fromBasis(right, y_axis, z_axis),
            .color = if (team == .friendly) friendly_col else enemy_col,
        };
        w.carrier_count += 1;
    }

    // 4. Populate Evil Atmospheric Blimps patrolling above cities and oceans
    w.blimp_count = 0;
    for (w.cities[0..w.city_count]) |city| {
        if (w.blimp_count >= w.blimps.len) break;
        const b_idx = w.blimp_count;
        const alt: f32 = 360.0 + hash3(@intCast(b_idx * 17), 42, 91) * 160.0; // 360 - 520m AGL
        const orb_r: f32 = 850.0 + hash3(@intCast(b_idx * 31), 88, 14) * 600.0; // 850 - 1450m radius
        const ang_spd: f32 = 0.020 + hash3(@intCast(b_idx * 7), 19, 73) * 0.012; // slow majestic cruise
        const phase: f32 = hash3(@intCast(b_idx * 43), 61, 33) * std.math.pi * 2.0;

        w.blimps[w.blimp_count] = .{
            .center_dir = city.dir,
            .east = city.east,
            .north = city.north,
            .orbit_radius = orb_r,
            .angular_speed = if (b_idx % 2 == 0) ang_spd else -ang_spd,
            .altitude = alt,
            .phase = phase,
            .health = 80.0,
            .max_health = 80.0,
            .alive = true,
            .death_timer = 0.0,
        };
        w.blimp_count += 1;
    }

    // 5. Populate Small Military Bases for Each Team (4 Friendly Blue + 4 Enemy Red)
    w.base_count = 0;
    ensureBaseSites();
    const blue_names = [_][]const u8{
        "FORT VALIANT",
        "AERO BASE COBALT",
        "OUTPOST TITAN",
        "CAMP SENTINEL",
    };
    const red_names = [_][]const u8{
        "FORT DREADNOUGHT",
        "AIRBASE CRIMSON",
        "OUTPOST INFERNO",
        "CAMP VIPER",
    };
    var blue_idx: usize = 0;
    var red_idx: usize = 0;

    for (cached_base_sites[0..cached_base_sites_count]) |bsite| {
        if (w.base_count >= w.bases.len) break;
        const dir = bsite.dir;
        const ref = if (@abs(dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
        const east = ref.cross(dir).norm();
        const north = dir.cross(east).norm();
        const base_r = surfaceRadius(dir);
        const base_pos = dir.scale(base_r + 2.5);

        const team = bsite.team;
        const b_name = if (team == .friendly) blk: {
            const name = blue_names[blue_idx % blue_names.len];
            blue_idx += 1;
            break :blk name;
        } else blk: {
            const name = red_names[red_idx % red_names.len];
            red_idx += 1;
            break :blk name;
        };

        const base_rot = fromBasis(east, dir, north.scale(-1));

        var mbase = MilitaryBase{
            .team = team,
            .dir = dir,
            .pos = base_pos,
            .rot = base_rot,
            .east = east,
            .north = north,
            .name = [_]u8{0} ** 24,
            .name_len = @min(b_name.len, 24),
            .structures = undefined,
            .structure_count = 0,
        };
        @memcpy(mbase.name[0..mbase.name_len], b_name[0..mbase.name_len]);

        // Layout military structures on flat graded compound
        const struct_defs = [_]struct {
            kind: BaseKind,
            ex: f32,
            ny: f32,
            yaw: f32,
            health: f32,
            pts: i32,
        }{
            .{ .kind = .command_bunker, .ex = 0.0, .ny = 20.0, .yaw = 0.0, .health = 250.0, .pts = 10 },
            .{ .kind = .radar_station, .ex = -75.0, .ny = 55.0, .yaw = 0.4, .health = 140.0, .pts = 5 },
            .{ .kind = .aircraft_hangar, .ex = 70.0, .ny = 45.0, .yaw = 1.57, .health = 180.0, .pts = 5 },
            .{ .kind = .aircraft_hangar, .ex = 70.0, .ny = -45.0, .yaw = 1.57, .health = 180.0, .pts = 5 },
            .{ .kind = .sam_battery, .ex = -85.0, .ny = -45.0, .yaw = 0.8, .health = 120.0, .pts = 5 },
            .{ .kind = .sam_battery, .ex = 0.0, .ny = 85.0, .yaw = -0.5, .health = 120.0, .pts = 5 },
            .{ .kind = .fuel_depot, .ex = -45.0, .ny = -70.0, .yaw = 0.0, .health = 100.0, .pts = 5 },
            .{ .kind = .fuel_depot, .ex = -10.0, .ny = -70.0, .yaw = 0.0, .health = 100.0, .pts = 5 },
        };

        for (struct_defs) |sd| {
            if (mbase.structure_count >= mbase.structures.len) break;
            const s_pos = base_pos.add(east.scale(sd.ex)).add(north.scale(sd.ny));
            const yaw_rot = Quat.fromAxisAngle(dir, sd.yaw);
            const s_rot = yaw_rot.mul(base_rot);

            mbase.structures[mbase.structure_count] = .{
                .kind = sd.kind,
                .pos = s_pos,
                .rot = s_rot,
                .team = team,
                .health = sd.health,
                .max_health = sd.health,
                .alive = true,
                .death_timer = 0.0,
                .points = sd.pts,
            };
            mbase.structure_count += 1;
        }

        w.bases[w.base_count] = mbase;
        w.base_count += 1;
    }
}

fn buildCityContent(w: *WorldObjects, city_idx: u16, bld_palette: []const Vec3) void {
    const city = w.cities[city_idx];
    const grid_half: i32 = 3; // 6x6 blocks, 7x7 avenues/streets
    const block_pitch: f32 = 240.0; // meters between street centerlines
    const road_width: f32 = 36.0;
    const city_half_ext: f32 = @as(f32, @floatFromInt(grid_half)) * block_pitch;
    const plaza_concrete = mesh.srgb(156, 162, 170);

    // 1. Segmented Streets (7 East-West + 7 North-South avenues, broken into 6 segments each so they hug sphere curvature!)
    var k: i32 = -grid_half;
    while (k <= grid_half) : (k += 1) {
        const offset: f32 = @as(f32, @floatFromInt(k)) * block_pitch;
        var seg: i32 = -grid_half;
        while (seg < grid_half) : (seg += 1) {
            const s_mid = (@as(f32, @floatFromInt(seg)) + 0.5) * block_pitch;
            const seg_len = block_pitch + road_width * 0.6;

            // North-South avenue segment at `(offset, s_mid)`
            if (w.street_count < w.streets.len) {
                const p_dir = cityPointDir(city, offset, s_mid);
                const elev = terrainElevation(p_dir);
                if (elev > 1.5) {
                    const loc_east = city.north.cross(p_dir).norm();
                    const loc_north = p_dir.cross(loc_east).norm();
                    const r_surf = radius + elev - 26.0; // bottom at -26 m, top at +2.0 m
                    w.streets[w.street_count] = .{
                        .pos = p_dir.scale(r_surf),
                        .rot = fromBasis(loc_east, p_dir, loc_north),
                        .scale = Vec3.init(road_width, 28.0, seg_len),
                        .color = Vec3.init(1, 1, 1),
                        .dir = p_dir,
                        .kind = 0, // 0 = road segment (rendered with street_mesh)
                    };
                    w.street_count += 1;
                }
            }

            // East-West street segment at `(s_mid, offset)`
            if (w.street_count < w.streets.len) {
                const p_dir = cityPointDir(city, s_mid, offset);
                const elev = terrainElevation(p_dir);
                if (elev > 1.5) {
                    const loc_east = city.north.cross(p_dir).norm();
                    const loc_north = p_dir.cross(loc_east).norm();
                    const r_surf = radius + elev - 25.9; // bottom at -25.9 m, top at +2.1 m
                    // Rotate 90° so length is along local Z (same as North-South avenues):
                    w.streets[w.street_count] = .{
                        .pos = p_dir.scale(r_surf),
                        .rot = fromBasis(loc_north.scale(-1), p_dir, loc_east),
                        .scale = Vec3.init(road_width, 28.0, seg_len),
                        .color = Vec3.init(1, 1, 1),
                        .dir = p_dir,
                        .kind = 0, // 0 = road segment (rendered with street_mesh)
                    };
                    w.street_count += 1;
                }
            }
        }
    }

    // 2. City Blocks -> Concrete sidewalk/plaza pad per block + 2x2 building lots per block
    var bx: i32 = -grid_half;
    while (bx < grid_half) : (bx += 1) {
        var bz: i32 = -grid_half;
        while (bz < grid_half) : (bz += 1) {
            const block_cx = (@as(f32, @floatFromInt(bx)) + 0.5) * block_pitch;
            const block_cz = (@as(f32, @floatFromInt(bz)) + 0.5) * block_pitch;
            const dist_norm = @sqrt(block_cx * block_cx + block_cz * block_cz) / (city_half_ext * 1.414);

            // Raised concrete sidewalk pads (2x2 lot pads per block so spherical curvature drop-off at the street curb is < 0.08 m!)
            const half_pad = (block_pitch - road_width) * 0.5;
            inline for (.{ @as(f32, -0.5), @as(f32, 0.5) }) |px| {
                inline for (.{ @as(f32, -0.5), @as(f32, 0.5) }) |pz| {
                    const pad_x = block_cx + px * half_pad;
                    const pad_z = block_cz + pz * half_pad;
                    const blk_dir = cityPointDir(city, pad_x, pad_z);
                    const blk_elev = terrainElevation(blk_dir);
                    if (blk_elev > 2.5 and w.street_count < w.streets.len) {
                        const blk_east = city.north.cross(blk_dir).norm();
                        const blk_north = blk_dir.cross(blk_east).norm();
                        w.streets[w.street_count] = .{
                            .pos = blk_dir.scale(radius + blk_elev - 19.45),
                            .rot = fromBasis(blk_east, blk_dir, blk_north),
                            .scale = Vec3.init(half_pad, 22.0, half_pad),
                            .color = plaza_concrete,
                            .dir = blk_dir,
                            .kind = 1, // 1 = plaza concrete pad (rendered with box_mesh)
                        };
                        w.street_count += 1;
                    }
                }
            }

            inline for (.{ @as(f32, -58.0), @as(f32, 58.0) }) |lx| {
                inline for (.{ @as(f32, -58.0), @as(f32, 58.0) }) |lz| {
                    if (w.building_count >= w.buildings.len) break;
                    const x = block_cx + lx;
                    const z = block_cz + lz;
                    const p_dir = cityPointDir(city, x, z);
                    const elev = terrainElevation(p_dir);
                    if (elev > 3.0) {
                        const loc_east = city.north.cross(p_dir).norm();
                        const loc_north = p_dir.cross(loc_east).norm();
                        const h = hash3(@as(i32, city_idx) * 31 + bx * 7 + @as(i32, @intFromFloat(lx)), bz * 13 + @as(i32, @intFromFloat(lz)), 97);
                        const core_boost = @max(0.18, 1.0 - dist_norm * 0.82);
                        const height = 42.0 + (60.0 + h * h * 290.0) * core_boost;
                        const width = 34.0 + h * 20.0;
                        const depth = 34.0 + (1.0 - h) * 20.0;
                        // Anchor building into the concrete sidewalk pad (`radius + elev + 2.2`) so its dark lobby base sits flush on the sidewalk
                        const surf_r = radius + elev + 2.2;
                        const col_idx = (@as(usize, city_idx) * 7 + @as(usize, @intCast(bx + grid_half)) * 3 + @as(usize, @intCast(bz + grid_half))) % bld_palette.len;
                        const bld_kind: u8 = @intCast((@as(usize, @intCast(bx + grid_half)) * 3 + @as(usize, @intCast(bz + grid_half)) + w.building_count) % 2);
                        w.buildings[w.building_count] = .{
                            .pos = p_dir.scale(surf_r),
                            .rot = fromBasis(loc_east, p_dir, loc_north),
                            .scale = Vec3.init(width, height, depth),
                            .color = bld_palette[col_idx],
                            .dir = p_dir,
                            .kind = bld_kind,
                        };
                        w.building_count += 1;
                    }
                }
            }
        }
    }

    // 3. Cars driving along the city's streets (always include traffic on the central boulevards `street_idx = 0`)
    const car_palette = [_]Vec3{
        mesh.srgb(235, 55, 45),
        mesh.srgb(45, 135, 235),
        mesh.srgb(245, 195, 40),
        mesh.srgb(240, 244, 248),
        mesh.srgb(55, 200, 110),
        mesh.srgb(180, 75, 220),
    };
    var ci: usize = 0;
    while (ci < 26 and w.car_count < w.cars.len) : (ci += 1) {
        const h = hash3(@intCast(city_idx), @intCast(ci * 17), 301);
        const street_idx: i32 = if (ci < 6) 0 else @as(i32, @intFromFloat(@floor(h * 7.0))) - grid_half;
        const along_north = if (ci < 6) true else (ci % 2 == 0);
        const dir_sign: f32 = if ((ci & 1) == 0) 1.0 else -1.0;
        const lane_shift: f32 = dir_sign * 8.0;
        w.cars[w.car_count] = .{
            .city_idx = city_idx,
            .along_north = along_north,
            .lane_offset = @as(f32, @floatFromInt(street_idx)) * block_pitch + lane_shift,
            .half_len = city_half_ext,
            .speed = dir_sign * (28.0 + h * 26.0),
            .phase = if (ci < 6) (535.0 + @as(f32, @floatFromInt(ci)) * 45.0) else h * city_half_ext * 2.0,
            .color = car_palette[ci % car_palette.len],
        };
        w.car_count += 1;
    }

    // 4. Tiny pedestrians walking along the sidewalks of every street
    const ped_palette = [_]Vec3{
        mesh.srgb(250, 90, 70),
        mesh.srgb(70, 180, 250),
        mesh.srgb(250, 220, 75),
        mesh.srgb(120, 235, 135),
        mesh.srgb(245, 130, 220),
        mesh.srgb(250, 250, 250),
    };
    var pi: usize = 0;
    while (pi < 40 and w.ped_count < w.peds.len) : (pi += 1) {
        const h = hash3(@intCast(city_idx), @intCast(pi * 23), 709);
        const street_idx: i32 = if (pi < 10) 0 else @as(i32, @intFromFloat(@floor(h * 7.0))) - grid_half;
        const along_north = if (pi < 10) true else (pi % 2 == 0);
        const side_sign: f32 = if ((pi & 1) == 0) 1.0 else -1.0;
        const sidewalk_shift: f32 = side_sign * (20.5 + (h - 0.5) * 2.5);
        w.peds[w.ped_count] = .{
            .city_idx = city_idx,
            .along_north = along_north,
            .lane_offset = @as(f32, @floatFromInt(street_idx)) * block_pitch + sidewalk_shift,
            .half_len = city_half_ext,
            .speed = side_sign * (3.5 + h * 3.5),
            .phase = if (pi < 10) (525.0 + @as(f32, @floatFromInt(pi)) * 24.0) else h * city_half_ext * 2.0,
            .color = ped_palette[pi % ped_palette.len],
        };
        w.ped_count += 1;
    }
}

/// Maps local tangent offsets `(east_m, north_m)` in meters around `city` onto the unit sphere.
pub fn cityPointDir(city: City, east_m: f32, north_m: f32) Vec3 {
    return city.dir
        .add(city.east.scale(east_m / radius))
        .add(city.north.scale(north_m / radius))
        .norm();
}

/// Evaluates a `CityAgent` (car or pedestrian) at time `t`, returning world position and orientation.
pub fn evalCityAgent(w: *const WorldObjects, ag: CityAgent, t: f32, y_offset: f32) struct { pos: Vec3, rot: Quat, dir: Vec3 } {
    const city = w.cities[ag.city_idx];
    const span = ag.half_len * 2.0;
    const raw = @mod(ag.phase + ag.speed * t, span);
    const s = (if (raw < 0) raw + span else raw) - ag.half_len;

    const east_m = if (ag.along_north) ag.lane_offset else s;
    const north_m = if (ag.along_north) s else ag.lane_offset;
    const dir = cityPointDir(city, east_m, north_m);
    const r_surf = surfaceRadius(dir) + y_offset;

    const fwd = if (ag.along_north)
        (if (ag.speed >= 0) city.north else city.north.scale(-1))
    else
        (if (ag.speed >= 0) city.east else city.east.scale(-1));
    // Mesh nose is -Z, so local +Z is `-fwd`
    const z_axis = fwd.scale(-1).norm();
    const x_axis = dir.cross(z_axis).norm();
    const y_axis = z_axis.cross(x_axis).norm();
    return .{
        .pos = dir.scale(r_surf),
        .rot = fromBasis(x_axis, y_axis, z_axis),
        .dir = dir,
    };
}

/// Evaluates a `ShipAgent` (boat or battleship) at time `t` on the ocean surface.
pub fn evalShipAgent(sh: ShipAgent, t: f32) struct { pos: Vec3, rot: Quat, dir: Vec3 } {
    const a = sh.phase + sh.angular_speed * t;
    const ca = @cos(a);
    const sa = @sin(a);
    const east_m = ca * sh.orbit_radius;
    const north_m = sa * sh.orbit_radius;
    const dir = sh.center_dir
        .add(sh.east.scale(east_m / radius))
        .add(sh.north.scale(north_m / radius))
        .norm();

    const sign: f32 = if (sh.angular_speed >= 0) 1.0 else -1.0;
    const tangent = sh.east.scale(-sa * sign).add(sh.north.scale(ca * sign)).norm();
    // Mesh bow is -Z, so local +Z is `-tangent`
    const z_axis = tangent.scale(-1);
    const x_axis = dir.cross(z_axis).norm();
    const y_axis = z_axis.cross(x_axis).norm();
    return .{
        .pos = dir.scale(radius + 0.5),
        .rot = fromBasis(x_axis, y_axis, z_axis),
        .dir = dir,
    };
}

/// Evaluates a `BlimpAgent` at time `t` patrolling the atmosphere.
pub fn evalBlimpAgent(bl: BlimpAgent, t: f32) struct { pos: Vec3, rot: Quat, dir: Vec3, fwd: Vec3 } {
    const a = bl.phase + bl.angular_speed * t;
    const ca = @cos(a);
    const sa = @sin(a);
    const east_m = ca * bl.orbit_radius;
    const north_m = sa * bl.orbit_radius;
    const dir = bl.center_dir
        .add(bl.east.scale(east_m / radius))
        .add(bl.north.scale(north_m / radius))
        .norm();

    const sign: f32 = if (bl.angular_speed >= 0) 1.0 else -1.0;
    const tangent = bl.east.scale(-sa * sign).add(bl.north.scale(ca * sign)).norm();
    // Airship nose is -Z, so local +Z is `-tangent`
    const z_axis = tangent.scale(-1);
    const x_axis = dir.cross(z_axis).norm();
    const y_axis = z_axis.cross(x_axis).norm();
    const surf_r = surfaceRadius(dir);
    return .{
        .pos = dir.scale(surf_r + bl.altitude),
        .rot = fromBasis(x_axis, y_axis, z_axis),
        .dir = dir,
        .fwd = tangent,
    };
}

/// Builds a quaternion whose local +Y is `up_dir`, rotated around `up_dir` by `yaw`.
pub fn tangentRotation(up_dir: Vec3, yaw: f32) Quat {
    const ref = if (@abs(up_dir.y) < 0.9) Vec3.up else Vec3.init(1, 0, 0);
    const east = ref.cross(up_dir).norm();
    const north = up_dir.cross(east).norm();
    const c = @cos(yaw);
    const s = @sin(yaw);
    const x_axis = east.scale(c).add(north.scale(s));
    const z_axis = east.scale(-s).add(north.scale(c));
    return fromBasis(x_axis, up_dir, z_axis);
}

pub fn fromBasis(x: Vec3, y: Vec3, z: Vec3) Quat {
    const trace = x.x + y.y + z.z;
    if (trace > 0.0) {
        const s = @sqrt(trace + 1.0) * 2.0;
        return (Quat{
            .w = 0.25 * s,
            .x = (y.z - z.y) / s,
            .y = (z.x - x.z) / s,
            .z = (x.y - y.x) / s,
        }).normalize();
    } else if (x.x > y.y and x.x > z.z) {
        const s = @sqrt(1.0 + x.x - y.y - z.z) * 2.0;
        return (Quat{
            .w = (y.z - z.y) / s,
            .x = 0.25 * s,
            .y = (y.x + x.y) / s,
            .z = (z.x + x.z) / s,
        }).normalize();
    } else if (y.y > z.z) {
        const s = @sqrt(1.0 + y.y - x.x - z.z) * 2.0;
        return (Quat{
            .w = (z.x - x.z) / s,
            .x = (y.x + x.y) / s,
            .y = 0.25 * s,
            .z = (z.y + y.z) / s,
        }).normalize();
    } else {
        const s = @sqrt(1.0 + z.z - x.x - y.y) * 2.0;
        return (Quat{
            .w = (x.y - y.x) / s,
            .x = (z.x + x.x) / s,
            .y = (z.y + y.z) / s,
            .z = 0.25 * s,
        }).normalize();
    }
}

pub const PlanetaryTargetRel = struct {
    dist_3d: f32, // Straight-line Euclidean distance through 3D space
    surface_dist: f32, // Great-circle arc distance along planet surface in meters
    hemi_dot: f32, // Radial dot product: >0.0 same hemisphere, <=0.0 opposite hemisphere
    is_occluded: bool, // True if chord ray passes through the planet sphere or opposite hemisphere
    is_far_side: bool, // True if target is on the opposite side of the planet (hemi_dot <= 0.0)
    tangent_dir: Vec3, // Unit vector along planet surface tangent toward target
};

pub fn evalTargetRel(p1: Vec3, p2: Vec3) PlanetaryTargetRel {
    const to_p2 = p2.sub(p1);
    const d3 = to_p2.len();
    const up1 = p1.norm();
    const up2 = p2.norm();
    const h_dot = math.clamp(up1.dot(up2), -1.0, 1.0);
    const ang = std.math.acos(h_dot);
    const s_dist = radius * ang;

    // Ray-sphere segment intersection with planet
    var occluded = false;
    const seg_len_sq = to_p2.lenSq();
    if (seg_len_sq > 1.0) {
        const t = -p1.dot(to_p2) / seg_len_sq;
        if (t > 0.0 and t < 1.0) {
            const closest = p1.add(to_p2.scale(t));
            const min_r = closest.len();
            const surf_r = surfaceRadius(closest.norm());
            if (min_r < (surf_r - 20.0)) {
                occluded = true;
            }
        }
    }
    if (h_dot <= 0.0) {
        occluded = true;
    }

    // Tangent heading along spherical surface
    const proj = up2.sub(up1.scale(h_dot));
    const proj_len = proj.len();
    const t_dir = if (proj_len > 1e-4) proj.scale(1.0 / proj_len) else blk: {
        const perp = if (@abs(up1.y) < 0.9) up1.cross(Vec3.init(0, 1, 0)) else up1.cross(Vec3.init(1, 0, 0));
        break :blk perp.norm();
    };

    return .{
        .dist_3d = d3,
        .surface_dist = s_dist,
        .hemi_dot = h_dot,
        .is_occluded = occluded,
        .is_far_side = (h_dot <= 0.0),
        .tangent_dir = t_dir,
    };
}

pub fn isOccludedByPlanet(p1: Vec3, p2: Vec3) bool {
    const to_p2 = p2.sub(p1);
    const seg_len_sq = to_p2.lenSq();
    if (seg_len_sq <= 1.0) return false;
    const up1 = p1.norm();
    const up2 = p2.norm();
    if (up1.dot(up2) <= 0.0) return true; // Opposite hemisphere is always occluded
    const t = -p1.dot(to_p2) / seg_len_sq;
    if (t > 0.0 and t < 1.0) {
        const closest = p1.add(to_p2.scale(t));
        const min_r = closest.len();
        const surf_r = surfaceRadius(closest.norm());
        return min_r < (surf_r - 20.0);
    }
    return false;
}

