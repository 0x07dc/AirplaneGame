//! Airplane Game — entry point: window, fixed-step sim, scene assembly.
const std = @import("std");
const c = @import("c");
const math = @import("math.zig");
const mesh = @import("mesh.zig");
const flight = @import("flight.zig");
const gfx = @import("gfx.zig");
const Window = @import("window.zig").Window;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const log = std.log.scoped(.game);

const sim_dt: f32 = 1.0 / 120.0;

fn nowSeconds() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) * 1e-9;
}

fn axis(pos: bool, neg: bool) f32 {
    return (if (pos) @as(f32, 1) else 0) - (if (neg) @as(f32, 1) else 0);
}

fn readInput(win: *const Window) flight.Input {
    return .{
        // W / Up = nose down, S / Down = nose up
        .pitch = std.math.clamp(axis(win.down(.s), win.down(.w)) + axis(win.down(.down), win.down(.up)), -1, 1),
        .roll = std.math.clamp(axis(win.down(.d), win.down(.a)) + axis(win.down(.right), win.down(.left)), -1, 1),
        .yaw = axis(win.down(.e), win.down(.q)),
        .boost = win.down(.shift),
        .brake = win.down(.space) or win.down(.ctrl),
    };
}

fn hash2(x: i32, z: i32) u32 {
    var h: u32 = @bitCast(x *% 374761393 +% z *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return h;
}

const tower_cell: f32 = 300.0;
const tower_radius_cells: i32 = 25;
const max_draws = 4096;

pub fn main() !void {
    var win = Window{};
    try win.init();
    var r = gfx.Renderer{};
    defer r.deinit();
    try r.init(&win);

    const alloc = std.heap.page_allocator;
    var pb = try mesh.buildPlane(alloc);
    defer pb.deinit();
    var bb = try mesh.buildBox(alloc);
    defer bb.deinit();
    var gb = try mesh.buildGround(alloc, 48, 250.0);
    defer gb.deinit();
    const plane_mesh = try r.createMesh(pb.verts.items, pb.indices.items);
    const box_mesh = try r.createMesh(bb.verts.items, bb.indices.items);
    const ground_mesh = try r.createMesh(gb.verts.items, gb.indices.items);

    // Tower palette (muted, a bit warm/cool variety).
    const palette = [_]Vec3{
        mesh.srgb(196, 200, 210), mesh.srgb(232, 190, 150), mesh.srgb(150, 170, 200),
        mesh.srgb(210, 150, 140), mesh.srgb(170, 190, 160),
    };

    const max_frames: u64 = if (std.c.getenv("AG_FRAMES")) |s|
        std.fmt.parseInt(u64, std.mem.span(s), 10) catch 0
    else
        0;

    var plane = flight.Plane{};
    var cam = flight.Camera{};
    var draws: [max_draws]gfx.DrawCmd = undefined;

    var frame: u64 = 0;
    var last = nowSeconds();
    var acc: f64 = 0;
    var next_report = last + 1.0;
    while (!win.should_close and !win.down(.esc)) {
        win.pump();
        if (win.resized) {
            win.resized = false;
            try r.recreate(win.width, win.height);
        }

        const now = nowSeconds();
        const frame_dt: f32 = @floatCast(@min(now - last, 0.1));
        acc = @min(acc + (now - last), 0.25);
        last = now;
        const input = readInput(&win);
        while (acc >= sim_dt) : (acc -= sim_dt) plane.step(sim_dt, input);

        const alpha: f32 = @floatCast(acc / sim_dt);
        const ppos = plane.renderPos(alpha);
        const prot = plane.renderRot(alpha);
        cam.update(frame_dt, ppos, prot, plane.speed, plane.params);
        const vp = cam.viewProj(r.aspect());

        // --- Build draw list ---
        var n: usize = 0;
        const snap: f32 = 500.0;
        const gpos = Vec3.init(@floor(cam.pos.x / snap) * snap, 0, @floor(cam.pos.z / snap) * snap);
        draws[n] = .{ .mesh = ground_mesh, .model = Mat4.model(gpos, Vec3.init(1, 1, 1), math.Quat.identity, Vec3.init(1, 1, 1)) };
        n += 1;
        draws[n] = .{ .mesh = plane_mesh, .model = Mat4.model(ppos, Vec3.init(1, 1, 1), prot, Vec3.init(1, 1, 1)) };
        n += 1;

        const cfwd = cam.forward(ppos);
        const cx: i32 = @intFromFloat(@floor(cam.pos.x / tower_cell));
        const cz: i32 = @intFromFloat(@floor(cam.pos.z / tower_cell));
        var iz = cz - tower_radius_cells;
        while (iz <= cz + tower_radius_cells) : (iz += 1) {
            var ix = cx - tower_radius_cells;
            while (ix <= cx + tower_radius_cells) : (ix += 1) {
                const h = hash2(ix, iz);
                if ((h & 3) != 0) continue;
                const jx = @as(f32, @floatFromInt((h >> 8) & 0xff)) / 255.0 * 200.0 + 50.0;
                const jz = @as(f32, @floatFromInt((h >> 16) & 0xff)) / 255.0 * 200.0 + 50.0;
                const bx = @as(f32, @floatFromInt(ix)) * tower_cell + jx;
                const bz = @as(f32, @floatFromInt(iz)) * tower_cell + jz;
                const to = Vec3.init(bx - cam.pos.x, 0, bz - cam.pos.z);
                if (to.dot(cfwd) < -300.0) continue;
                const t = @as(f32, @floatFromInt((h >> 4) & 0xff)) / 255.0;
                const height = 15.0 + t * t * 200.0;
                const width = 14.0 + @as(f32, @floatFromInt((h >> 24) & 0x1f));
                if (n >= max_draws) break;
                draws[n] = .{
                    .mesh = box_mesh,
                    .model = Mat4.model(Vec3.init(bx, 0, bz), Vec3.init(width, height, width), math.Quat.identity, palette[h % palette.len]),
                };
                n += 1;
            }
        }

        if (!try r.drawFrame(vp, draws[0..n])) try r.recreate(win.width, win.height);
        frame += 1;
        if (now >= next_report) {
            next_report = now + 1.0;
            log.info("speed {d:.0} m/s  alt {d:.0} m  aoa {d:.0}°  draws {d}", .{ plane.speed, plane.pos.y, plane.aoa * 180.0 / std.math.pi, n });
        }
        if (max_frames != 0 and frame >= max_frames) break;
    }
    log.info("exited cleanly after {d} frames", .{frame});
}
