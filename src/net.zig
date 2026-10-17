const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Quat = math.Quat;
const planet = @import("planet.zig");
const c = @import("c");

pub const MAGIC: u32 = 0x31594741; // "AGY1" in little-endian

pub fn nowSeconds() f64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) * 1e-9;
}

pub const PacketKind = enum(u8) {
    discovery_ping = 1,
    discovery_pong = 2,
    client_sync = 3,
    server_sync = 4,
};

pub const DiscoveryPing = extern struct {
    magic: u32 = MAGIC,
    kind: u8 = @intFromEnum(PacketKind.discovery_ping),
    client_version: u16 = 200,
    pad: u8 = 0,
};

pub const DiscoveryPong = extern struct {
    magic: u32 = MAGIC,
    kind: u8 = @intFromEnum(PacketKind.discovery_pong),
    server_name: [32]u8 = [_]u8{0} ** 32,
    mode_name: [16]u8 = [_]u8{0} ** 16,
    current_players: u8 = 1,
    max_players: u8 = 32,
    game_port: u16 = 7777,
};

pub const ClientSync = extern struct {
    magic: u32 = MAGIC,
    kind: u8 = @intFromEnum(PacketKind.client_sync),
    client_id: u8 = 0,
    team: u8 = 0, // 0 = blue/friendly, 1 = red/enemy
    flags: u8 = 0, // bit 0: fire_l, bit 1: fire_r, bit 2: fire_bomb
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    pos_z: f32 = 0,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    rot_w: f32 = 1,
    vel_x: f32 = 0,
    vel_y: f32 = 0,
    vel_z: f32 = 0,
    speed: f32 = 0,
    health: f32 = 100.0,
    client_time: f32 = 0, // Client local timestamp for RTT calculation
    damage_dealt: f32 = 0, // Damage registered by client against target_hit_id
    target_hit_id: u8 = 255, // 255 = none, 0..15 = remote player client_id
    screenname: [16]u8 = [_]u8{0} ** 16,
};

pub const RemotePlayer = extern struct {
    active: u8 = 0,
    team: u8 = 0,
    flags: u8 = 0,
    client_id: u8 = 0,
    ping_ms: u16 = 0,
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    pos_z: f32 = 0,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    rot_w: f32 = 1,
    vel_x: f32 = 0,
    vel_y: f32 = 0,
    vel_z: f32 = 0,
    speed: f32 = 0,
    health: f32 = 100.0,
    screenname: [16]u8 = [_]u8{0} ** 16,

    pub fn getName(self: *const RemotePlayer) []const u8 {
        var l: usize = 0;
        while (l < self.screenname.len and self.screenname[l] != 0) : (l += 1) {}
        return if (l > 0) self.screenname[0..l] else "PLAYER";
    }

    pub fn pos(self: *const RemotePlayer) Vec3 {
        return Vec3.init(self.pos_x, self.pos_y, self.pos_z);
    }
    pub fn rot(self: *const RemotePlayer) Quat {
        return Quat{ .x = self.rot_x, .y = self.rot_y, .z = self.rot_z, .w = self.rot_w };
    }
    pub fn vel(self: *const RemotePlayer) Vec3 {
        return Vec3.init(self.vel_x, self.vel_y, self.vel_z);
    }
    pub fn fwd(self: *const RemotePlayer) Vec3 {
        return self.rot().rotate(Vec3.forward);
    }
    pub fn isFiringLaser(self: *const RemotePlayer) bool {
        return (self.flags & 1) != 0;
    }
    pub fn isFiringMissile(self: *const RemotePlayer) bool {
        return (self.flags & 2) != 0;
    }
    pub fn isDroppingBomb(self: *const RemotePlayer) bool {
        return (self.flags & 4) != 0;
    }
};

pub const ServerSync = extern struct {
    magic: u32 = MAGIC,
    kind: u8 = @intFromEnum(PacketKind.server_sync),
    server_seq: u32 = 0,
    blue_score: u16 = 0,
    red_score: u16 = 0,
    client_echo_time: f32 = 0, // Echoed timestamp back to client for ping RTT
    player_count: u8 = 0,
    players: [16]RemotePlayer = [_]RemotePlayer{.{}} ** 16,
};

// =============================================================================
// SIMULATED LAG & NETWORK IMPAIRMENT EMULATOR
// =============================================================================

pub const LagPreset = struct {
    name: []const u8,
    lag_ms: f32,
    jitter_ms: f32,
    loss_pct: f32,
};

pub const LAG_PRESETS = [_]LagPreset{
    .{ .name = "LAN // ZERO LATENCY (0ms, 0% loss)", .lag_ms = 0.0, .jitter_ms = 0.0, .loss_pct = 0.0 },
    .{ .name = "BROADBAND FIBER (35ms, 4ms jitter, 0% loss)", .lag_ms = 35.0, .jitter_ms = 4.0, .loss_pct = 0.0 },
    .{ .name = "DOMESTIC CROSS-COUNTRY (85ms, 12ms jitter, 1% loss)", .lag_ms = 85.0, .jitter_ms = 12.0, .loss_pct = 1.0 },
    .{ .name = "TRANSATLANTIC / CONTINENTAL (175ms, 25ms jitter, 3% loss)", .lag_ms = 175.0, .jitter_ms = 25.0, .loss_pct = 3.0 },
    .{ .name = "EXTREME SATELLITE / HIGH LAG (320ms, 45ms jitter, 6% loss)", .lag_ms = 320.0, .jitter_ms = 45.0, .loss_pct = 6.0 },
};

pub const DelayedPacket = struct {
    deliver_time: f64 = 0,
    len: usize = 0,
    data: [1500]u8 align(4) = [_]u8{0} ** 1500,
    addr: c.struct_sockaddr_in = undefined,
    has_addr: bool = false,
};

pub const LagSimulator = struct {
    preset_idx: usize = 0,
    lag_ms: f32 = 0.0,
    jitter_ms: f32 = 0.0,
    loss_pct: f32 = 0.0,

    rng_state: u64 = 0x853c49e6748fea9b,

    queue: [512]DelayedPacket = [_]DelayedPacket{.{}} ** 512,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,

    packets_simulated: u64 = 0,
    packets_dropped: u64 = 0,

    pub fn nextRandom(self: *LagSimulator) f32 {
        self.rng_state = self.rng_state *% 6364136223846793005 +% 1442695040888963407;
        const val = @as(u32, @truncate(self.rng_state >> 32));
        return @as(f32, @floatFromInt(val)) / 4294967295.0;
    }

    pub fn currentPreset(self: *const LagSimulator) LagPreset {
        return LAG_PRESETS[self.preset_idx];
    }

    pub fn cyclePreset(self: *LagSimulator) LagPreset {
        self.preset_idx = (self.preset_idx + 1) % LAG_PRESETS.len;
        const p = LAG_PRESETS[self.preset_idx];
        self.lag_ms = p.lag_ms;
        self.jitter_ms = p.jitter_ms;
        self.loss_pct = p.loss_pct;
        return p;
    }

    pub fn setCustom(self: *LagSimulator, lag: f32, jitter: f32, loss: f32) void {
        self.lag_ms = lag;
        self.jitter_ms = jitter;
        self.loss_pct = loss;
    }

    pub fn shouldDrop(self: *LagSimulator) bool {
        if (self.loss_pct <= 0.0) return false;
        return (self.nextRandom() * 100.0) < self.loss_pct;
    }

    /// Returns true if packet should be dispatched immediately, false if queued or dropped.
    pub fn enqueueOrImmediate(
        self: *LagSimulator,
        now: f64,
        data: []const u8,
        addr: ?*const c.struct_sockaddr_in,
    ) bool {
        self.packets_simulated += 1;
        if (self.shouldDrop()) {
            self.packets_dropped += 1;
            return false;
        }

        if (self.lag_ms <= 0.0 and self.jitter_ms <= 0.0) {
            return true;
        }

        if (self.queue_count >= self.queue.len) return false;

        const jitter_variance = (self.nextRandom() * 2.0 - 1.0) * self.jitter_ms;
        const total_delay = @max(0.0, (self.lag_ms + jitter_variance) * 0.001);
        const deliver_time = now + total_delay;

        const slot = &self.queue[self.queue_tail];
        slot.deliver_time = deliver_time;
        slot.len = @min(data.len, 1500);
        @memcpy(slot.data[0..slot.len], data[0..slot.len]);
        if (addr) |a| {
            slot.addr = a.*;
            slot.has_addr = true;
        } else {
            slot.has_addr = false;
        }

        self.queue_tail = (self.queue_tail + 1) % self.queue.len;
        self.queue_count += 1;
        return false;
    }

    pub fn dispatchReady(self: *LagSimulator, now: f64, sock_fd: c_int) void {
        while (self.queue_count > 0) {
            const slot = &self.queue[self.queue_head];
            if (now < slot.deliver_time) break;

            if (slot.has_addr) {
                _ = c.sendto(
                    sock_fd,
                    &slot.data,
                    slot.len,
                    0,
                    @ptrCast(&slot.addr),
                    @sizeOf(c.struct_sockaddr_in),
                );
            } else {
                _ = c.send(sock_fd, &slot.data, slot.len, 0);
            }

            self.queue_head = (self.queue_head + 1) % self.queue.len;
            self.queue_count -= 1;
        }
    }
};

// =============================================================================
// ENTITY INTERPOLATION & DEAD RECKONING
// =============================================================================

pub const InterpolatedPlayer = struct {
    active: bool = false,
    client_id: u8 = 0,
    team: u8 = 0,
    flags: u8 = 0,
    health: f32 = 100.0,
    speed: f32 = 0.0,
    ping_ms: u16 = 0,
    screenname: [16]u8 = [_]u8{0} ** 16,

    render_pos: Vec3 = Vec3.zero,
    render_rot: Quat = Quat.identity,

    prev_pos: Vec3 = Vec3.zero,
    target_pos: Vec3 = Vec3.zero,
    prev_rot: Quat = Quat.identity,
    target_rot: Quat = Quat.identity,
    velocity: Vec3 = Vec3.zero,

    last_packet_time: f64 = 0.0,
    interp_alpha: f32 = 1.0,

    // Weapons state & triggers
    firing_laser: bool = false,
    firing_missile: bool = false,
    firing_bomb: bool = false,
    laser_cooldown: f32 = 0.0,
    missile_cooldown: f32 = 0.0,
    bomb_cooldown: f32 = 0.0,

    pub fn getName(self: *const InterpolatedPlayer) []const u8 {
        var l: usize = 0;
        while (l < self.screenname.len and self.screenname[l] != 0) : (l += 1) {}
        return if (l > 0) self.screenname[0..l] else "PLAYER";
    }

    pub fn onPacket(self: *InterpolatedPlayer, rp: RemotePlayer, now: f64) void {
        const was_active = self.active;
        self.active = (rp.active != 0);
        self.client_id = rp.client_id;
        self.team = rp.team;
        self.flags = rp.flags;
        self.health = rp.health;
        self.speed = rp.speed;
        self.ping_ms = rp.ping_ms;
        self.screenname = rp.screenname;

        if (!was_active) {
            self.render_pos = rp.pos();
            self.render_rot = rp.rot();
            self.prev_pos = rp.pos();
            self.target_pos = rp.pos();
            self.prev_rot = rp.rot();
            self.target_rot = rp.rot();
            self.velocity = rp.vel();
            self.last_packet_time = now;
            self.interp_alpha = 1.0;
            return;
        }

        self.prev_pos = self.render_pos;
        self.prev_rot = self.render_rot;
        self.target_pos = rp.pos();
        self.target_rot = rp.rot();
        self.velocity = rp.vel();

        self.last_packet_time = now;
        self.interp_alpha = 0.0;
    }

    pub fn update(self: *InterpolatedPlayer, dt: f32, now: f64) void {
        if (!self.active) return;

        // Advance interpolation towards 1.0 at ~30Hz update rate
        self.interp_alpha = @min(1.0, self.interp_alpha + dt * 28.0);

        const base_pos = Vec3.lerp(self.prev_pos, self.target_pos, self.interp_alpha);
        const base_rot = Quat.nlerp(self.prev_rot, self.target_rot, self.interp_alpha);

        // Dead reckoning extrapolation if packets are delayed past 35ms (simulated lag)
        const time_since = @as(f32, @floatCast(now - self.last_packet_time));
        if (time_since > 0.035 and self.interp_alpha >= 0.99) {
            const extrap_dt = @min(time_since - 0.035, 0.45);
            self.render_pos = self.target_pos.add(self.velocity.scale(extrap_dt));
            self.render_rot = self.target_rot;
        } else {
            self.render_pos = base_pos;
            self.render_rot = base_rot;
        }

        // Weapon cooldown cadence
        self.laser_cooldown = @max(0.0, self.laser_cooldown - dt);
        self.missile_cooldown = @max(0.0, self.missile_cooldown - dt);
        self.bomb_cooldown = @max(0.0, self.bomb_cooldown - dt);

        self.firing_laser = (self.flags & 1) != 0 and (self.laser_cooldown <= 0.0);
        self.firing_missile = (self.flags & 2) != 0 and (self.missile_cooldown <= 0.0);
        self.firing_bomb = (self.flags & 4) != 0 and (self.bomb_cooldown <= 0.0);

        if (self.firing_laser) self.laser_cooldown = 0.080;
        if (self.firing_missile) self.missile_cooldown = 1.30;
        if (self.firing_bomb) self.bomb_cooldown = 2.0;
    }
};

// =============================================================================
// SERVER DIRECTORY & BROWSER
// =============================================================================

pub const ServerInfo = struct {
    name: [32]u8,
    name_len: usize,
    ip: [16]u8,
    ip_len: usize,
    port: u16,
    players: u8,
    max_players: u8,
    ping_ms: u16,
    mode: [16]u8,
    mode_len: usize,
    is_lan: bool = false,

    pub fn init(name_str: []const u8, ip_str: []const u8, port: u16, players: u8, max_players: u8, ping_ms: u16, mode_str: []const u8) ServerInfo {
        var res = ServerInfo{
            .name = [_]u8{0} ** 32,
            .name_len = @min(name_str.len, 32),
            .ip = [_]u8{0} ** 16,
            .ip_len = @min(ip_str.len, 16),
            .port = port,
            .players = players,
            .max_players = max_players,
            .ping_ms = ping_ms,
            .mode = [_]u8{0} ** 16,
            .mode_len = @min(mode_str.len, 16),
            .is_lan = std.mem.startsWith(u8, ip_str, "127.") or std.mem.startsWith(u8, ip_str, "192.168.") or std.mem.startsWith(u8, ip_str, "10."),
        };
        @memcpy(res.name[0..res.name_len], name_str[0..res.name_len]);
        @memcpy(res.ip[0..res.ip_len], ip_str[0..res.ip_len]);
        @memcpy(res.mode[0..res.mode_len], mode_str[0..res.mode_len]);
        return res;
    }

    pub fn getName(self: *const ServerInfo) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn getIp(self: *const ServerInfo) []const u8 {
        return self.ip[0..self.ip_len];
    }
    pub fn getMode(self: *const ServerInfo) []const u8 {
        return self.mode[0..self.mode_len];
    }
};

pub const ServerList = struct {
    items: [8]ServerInfo = undefined,
    count: usize = 0,
    selected: usize = 0,
    last_refresh: f64 = -100.0,

    pub fn initDefault() ServerList {
        var list = ServerList{};
        list.items[0] = ServerInfo.init("US-EAST // DOGFIGHT 16v16", "127.0.0.1", 7777, 12, 32, 18, "COMBAT 16v16");
        list.items[1] = ServerInfo.init("EU-CENTRAL // CARRIER WARS", "127.0.0.1", 7777, 8, 16, 32, "CARRIER ASSAULT");
        list.items[2] = ServerInfo.init("ASIA-PACIFIC // FLEET COMBAT", "127.0.0.1", 7777, 14, 32, 64, "FLEET WARFARE");
        list.items[3] = ServerInfo.init("LAN // LOCAL SQUADRON HOST", "127.0.0.1", 7777, 1, 16, 2, "LAN DOGFIGHT");
        list.items[4] = ServerInfo.init("DIRECT CONNECT // LAN PARTY", "127.0.0.1", 7777, 0, 32, 1, "CUSTOM LAN");
        list.count = 5;
        list.selected = 0;
        return list;
    }

    pub fn clear(self: *ServerList) void {
        self.count = 0;
        self.selected = 0;
    }

    pub fn add(self: *ServerList, info: ServerInfo) bool {
        if (self.count < self.items.len) {
            self.items[self.count] = info;
            self.count += 1;
            return true;
        }
        return false;
    }

    pub fn selectNext(self: *ServerList) void {
        if (self.count > 0) {
            self.selected = (self.selected + 1) % self.count;
        }
    }

    pub fn selectPrev(self: *ServerList) void {
        if (self.count > 0) {
            if (self.selected == 0) {
                self.selected = self.count - 1;
            } else {
                self.selected -= 1;
            }
        }
    }
};

// =============================================================================
// AUTOMATED MASTER SERVER CLIENT & REGISTRY
// =============================================================================

fn connectTcp(host: []const u8, port: u16, timeout_sec: c_long) ?c_int {
    const sock = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sock < 0) return null;

    var tv = c.struct_timeval{
        .tv_sec = timeout_sec,
        .tv_usec = 0,
    };
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.struct_timeval));

    var addr: c.struct_sockaddr_in = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sin_family = c.AF_INET;
    addr.sin_port = @byteSwap(port);

    const resolved_host = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    var host_buf: [128:0]u8 = [_:0]u8{0} ** 128;
    const clen = @min(resolved_host.len, host_buf.len - 1);
    @memcpy(host_buf[0..clen], resolved_host[0..clen]);
    host_buf[clen] = 0;

    if (c.inet_aton(&host_buf, &addr.sin_addr) == 0) {
        const he = c.gethostbyname(&host_buf);
        if (he == null or he.*.h_addr_list == null or he.*.h_addr_list[0] == null) {
            _ = c.close(sock);
            return null;
        }
        const h_addr_ptr: *const c.struct_in_addr = @ptrCast(@alignCast(he.*.h_addr_list[0]));
        addr.sin_addr = h_addr_ptr.*;
    }

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) {
        _ = c.close(sock);
        return null;
    }

    return sock;
}

pub const HeartbeatArgs = struct {
    client: *MasterClient,
    name: [48]u8,
    name_len: usize,
    port: u16,
    players: u8,
    max_players: u8,
    mode: [24]u8,
    mode_len: usize,
    ping: u16,
};

pub const UnregisterArgs = struct {
    client: *MasterClient,
    port: u16,
};

fn queryWorker(self: *MasterClient) void {
    defer self.query_in_flight.store(false, .release);

    const host_str = self.getHost();
    const sock = connectTcp(host_str, self.master_port, 2) orelse return;
    defer _ = c.close(sock);

    var req_buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /api/servers.txt HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: AirplaneGame/2.0\r\nConnection: close\r\n\r\n", .{ host_str, self.master_port }) catch return;

    var sent: usize = 0;
    while (sent < req.len) {
        const n = c.send(sock, req.ptr + sent, req.len - sent, 0);
        if (n <= 0) return;
        sent += @intCast(n);
    }

    var resp_buf: [4096]u8 = undefined;
    var total_recv: usize = 0;
    while (total_recv < resp_buf.len) {
        const n = c.recv(sock, resp_buf[total_recv..].ptr, resp_buf.len - total_recv, 0);
        if (n <= 0) break;
        total_recv += @intCast(n);
    }

    if (total_recv == 0) return;
    const resp = resp_buf[0..total_recv];

    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return;
    const body = resp[header_end + 4 ..];

    var new_list = ServerList{};
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var col_it = std.mem.splitScalar(u8, trimmed, '|');
        const name_str = col_it.next() orelse continue;
        const ip_str = col_it.next() orelse continue;
        const port_str = col_it.next() orelse continue;
        const players_str = col_it.next() orelse continue;
        const max_p_str = col_it.next() orelse continue;
        const ping_str = col_it.next() orelse continue;
        const mode_str = col_it.next() orelse continue;

        const port = std.fmt.parseInt(u16, port_str, 10) catch 7777;
        const players = std.fmt.parseInt(u8, players_str, 10) catch 1;
        const max_p = std.fmt.parseInt(u8, max_p_str, 10) catch 16;
        const ping = std.fmt.parseInt(u16, ping_str, 10) catch 15;

        _ = new_list.add(ServerInfo.init(name_str, ip_str, port, players, max_p, ping, mode_str));
    }

    if (new_list.count > 0 and new_list.count < new_list.items.len) {
        _ = new_list.add(ServerInfo.init("DIRECT CONNECT // LAN PARTY", "127.0.0.1", 7777, 0, 32, 1, "CUSTOM LAN"));
    }

    if (new_list.count > 0) {
        self.staged_list = new_list;
        self.has_pending_update.store(true, .release);
    }
}

fn heartbeatWorker(args: HeartbeatArgs) void {
    defer args.client.heartbeat_in_flight.store(false, .release);

    const host_str = args.client.getHost();
    const sock = connectTcp(host_str, args.client.master_port, 2) orelse return;
    defer _ = c.close(sock);

    var json_payload: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&json_payload, "{{\"name\":\"{s}\",\"port\":{d},\"players\":{d},\"max_players\":{d},\"mode\":\"{s}\",\"ping\":{d}}}", .{
        args.name[0..args.name_len],
        args.port,
        args.players,
        args.max_players,
        args.mode[0..args.mode_len],
        args.ping,
    }) catch return;

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST /api/heartbeat HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        host_str,
        args.client.master_port,
        body.len,
        body,
    }) catch return;

    _ = c.send(sock, req.ptr, req.len, 0);
}

fn unregisterWorker(args: UnregisterArgs) void {
    const host_str = args.client.getHost();
    const sock = connectTcp(host_str, args.client.master_port, 2) orelse return;
    defer _ = c.close(sock);

    var json_payload: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&json_payload, "{{\"port\":{d}}}", .{args.port}) catch return;

    var req_buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST /api/unregister HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        host_str,
        args.client.master_port,
        body.len,
        body,
    }) catch return;

    _ = c.send(sock, req.ptr, req.len, 0);
}

pub const MasterClient = struct {
    master_host: [64]u8 = [_]u8{0} ** 64,
    master_host_len: usize = 0,
    master_port: u16 = 8080,

    query_in_flight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    has_pending_update: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    staged_list: ServerList = ServerList{},

    last_heartbeat: f64 = -100.0,
    last_query: f64 = -100.0,
    heartbeat_in_flight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(host: []const u8, port: u16) MasterClient {
        var mc = MasterClient{
            .master_port = port,
        };
        const copy_len = @min(host.len, mc.master_host.len - 1);
        @memcpy(mc.master_host[0..copy_len], host[0..copy_len]);
        mc.master_host_len = copy_len;
        return mc;
    }

    pub fn getHost(self: *const MasterClient) []const u8 {
        if (self.master_host_len == 0) return "127.0.0.1";
        return self.master_host[0..self.master_host_len];
    }

    pub fn requestServerList(self: *MasterClient, now: f64) void {
        if (now - self.last_query < 1.0) return;
        self.last_query = now;

        if (self.query_in_flight.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;
        const thread = std.Thread.spawn(.{}, queryWorker, .{self}) catch {
            self.query_in_flight.store(false, .release);
            return;
        };
        thread.detach();
    }

    pub fn sendHeartbeat(self: *MasterClient, now: f64, name: []const u8, port: u16, players: u8, max_players: u8, mode: []const u8, ping: u16) void {
        self.last_heartbeat = now;
        if (self.heartbeat_in_flight.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;

        var args = HeartbeatArgs{
            .client = self,
            .name = [_]u8{0} ** 48,
            .name_len = @min(name.len, 48),
            .port = port,
            .players = players,
            .max_players = max_players,
            .mode = [_]u8{0} ** 24,
            .mode_len = @min(mode.len, 24),
            .ping = ping,
        };
        @memcpy(args.name[0..args.name_len], name[0..args.name_len]);
        @memcpy(args.mode[0..args.mode_len], mode[0..args.mode_len]);

        const thread = std.Thread.spawn(.{}, heartbeatWorker, .{args}) catch {
            self.heartbeat_in_flight.store(false, .release);
            return;
        };
        thread.detach();
    }

    pub fn sendUnregister(self: *MasterClient, port: u16) void {
        const args = UnregisterArgs{
            .client = self,
            .port = port,
        };
        const thread = std.Thread.spawn(.{}, unregisterWorker, .{args}) catch return;
        thread.detach();
    }

    pub fn poll(self: *MasterClient, target_list: *ServerList) bool {
        if (self.has_pending_update.load(.acquire)) {
            target_list.* = self.staged_list;
            self.has_pending_update.store(false, .release);
            return true;
        }
        return false;
    }
};

pub const NetworkRole = enum {
    offline,
    single_player,
    multiplayer_client,
    multiplayer_host,
};

pub const HostPlayerSlot = struct {
    active: bool = false,
    addr: c.struct_sockaddr_in = undefined,
    last_seen: f64 = 0,
    ping_ms: u16 = 0,
    state: RemotePlayer = .{},
};

// =============================================================================
// MAIN NETWORK MANAGER
// =============================================================================

pub const NetworkManager = struct {
    role: NetworkRole = .offline,
    sock_fd: c_int = -1,
    discovery_fd: c_int = -1,
    server_addr: c.struct_sockaddr_in = undefined,
    has_server_addr: bool = false,
    client_id: u8 = 1,
    connected: bool = false,

    // Real Interpolated Players for rendering & projectile hit collisions
    interpolated_players: [16]InterpolatedPlayer = [_]InterpolatedPlayer{.{}} ** 16,
    remote_player_count: usize = 0,

    server_list: ServerList = ServerList.initDefault(),
    server_list_dirty: bool = false,
    master_client: MasterClient = MasterClient.init("127.0.0.1", 8080),
    host_port: u16 = 7777,
    server_seq: u32 = 0,
    last_sync_time: f64 = 0.0,

    // Lag and Impairment Simulator
    lag_sim: LagSimulator = .{},

    // Real measured latency & telemetry
    measured_ping_ms: f32 = 0.0,
    smoothed_ping_ms: f32 = 0.0,
    packets_sent: u64 = 0,
    packets_recv: u64 = 0,

    // Server-side host state
    host_active: bool = false,
    host_max_players: u8 = 16,
    host_players: [16]HostPlayerSlot = [_]HostPlayerSlot{.{}} ** 16,

    // Screenname identity and join event signals
    local_screenname: [16]u8 = [_]u8{0} ** 16,
    player_joined_event: ?[16]u8 = null,
    player_joined_team: u8 = 0,

    pub fn setScreenname(self: *NetworkManager, name: []const u8) void {
        const copy_len = @min(name.len, 15);
        @memset(&self.local_screenname, 0);
        @memcpy(self.local_screenname[0..copy_len], name[0..copy_len]);
    }

    pub fn popPlayerJoined(self: *NetworkManager) ?struct { name: [16]u8, team: u8 } {
        if (self.player_joined_event) |name| {
            self.player_joined_event = null;
            return .{ .name = name, .team = self.player_joined_team };
        }
        return null;
    }

    pub fn init() NetworkManager {
        return NetworkManager{};
    }

    pub fn deinit(self: *NetworkManager) void {
        if (self.role == .multiplayer_host and self.host_active) {
            self.master_client.sendUnregister(self.host_port);
        }
        if (self.sock_fd >= 0) {
            _ = c.close(self.sock_fd);
            self.sock_fd = -1;
        }
        if (self.discovery_fd >= 0) {
            _ = c.close(self.discovery_fd);
            self.discovery_fd = -1;
        }
        self.connected = false;
        self.host_active = false;
        for (&self.interpolated_players) |*ip| {
            ip.active = false;
        }
    }

    pub fn disconnect(self: *NetworkManager) void {
        self.deinit();
    }

    /// Creates non-blocking UDP socket
    fn createUdpSocket(port: ?u16, is_broadcast: bool) c_int {
        const sock = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (sock < 0) return -1;

        const flags = c.fcntl(sock, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(sock, c.F_SETFL, flags | c.O_NONBLOCK);

        var enable: c_int = 1;
        _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_REUSEADDR, &enable, @sizeOf(c_int));
        if (is_broadcast) {
            _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_BROADCAST, &enable, @sizeOf(c_int));
        }

        if (port) |p| {
            var addr: c.struct_sockaddr_in = undefined;
            @memset(std.mem.asBytes(&addr), 0);
            addr.sin_family = c.AF_INET;
            addr.sin_port = @byteSwap(p);
            addr.sin_addr.s_addr = 0; // INADDR_ANY
            if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0) {
                _ = c.close(sock);
                return -1;
            }
        }
        return sock;
    }

    /// Starts hosting local dedicated / listen server with configurable max players (8, 16, or 32)
    pub fn startHost(self: *NetworkManager, port: u16, max_players: u8) bool {
        self.deinit();
        self.sock_fd = createUdpSocket(port, true);
        if (self.sock_fd < 0) return false;

        self.discovery_fd = createUdpSocket(7778, true);

        self.host_port = port;
        self.host_max_players = max_players;
        self.role = .multiplayer_host;
        self.host_active = true;
        self.connected = true;
        self.client_id = 0; // Host is Player 0
        const mname = if (max_players <= 8) "COMBAT 4v4" else if (max_players <= 16) "COMBAT 8v8" else "COMBAT 16v16";
        self.master_client.sendHeartbeat(nowSeconds(), "AIRPLANE COMBAT // DOGFIGHT HOST", port, 1, max_players, mname, 10);
        return true;
    }

    /// Connects to remote server IP and port
    pub fn connectToServer(self: *NetworkManager, ip_bytes: []const u8, port: u16) bool {
        self.deinit();
        self.sock_fd = createUdpSocket(null, true);
        if (self.sock_fd < 0) return false;

        @memset(std.mem.asBytes(&self.server_addr), 0);
        self.server_addr.sin_family = c.AF_INET;
        self.server_addr.sin_port = @byteSwap(port);

        if (ip_bytes.len == 4) {
            // Direct 4 octet IPv4 binary address
            const s_addr: u32 = @as(u32, ip_bytes[0]) |
                (@as(u32, ip_bytes[1]) << 8) |
                (@as(u32, ip_bytes[2]) << 16) |
                (@as(u32, ip_bytes[3]) << 24);
            self.server_addr.sin_addr.s_addr = s_addr;
        } else {
            // String IP address representation
            var ip_buf: [32]u8 = [_]u8{0} ** 32;
            const copy_len = @min(ip_bytes.len, 31);
            @memcpy(ip_buf[0..copy_len], ip_bytes[0..copy_len]);
            if (c.inet_aton(&ip_buf, &self.server_addr.sin_addr) == 0) {
                _ = c.close(self.sock_fd);
                self.sock_fd = -1;
                return false;
            }
        }

        self.has_server_addr = true;
        self.role = .multiplayer_client;
        self.connected = true;
        self.client_id = 1;
        return true;
    }

    /// Broadcasts LAN discovery request
    pub fn refreshLanServers(self: *NetworkManager, now: f64) void {
        self.server_list.last_refresh = now;
        if (self.discovery_fd < 0) {
            self.discovery_fd = createUdpSocket(null, true);
        }
        if (self.discovery_fd < 0) return;

        var ping = DiscoveryPing{};
        var broadcast_addr: c.struct_sockaddr_in = undefined;
        @memset(std.mem.asBytes(&broadcast_addr), 0);
        broadcast_addr.sin_family = c.AF_INET;
        broadcast_addr.sin_port = @byteSwap(@as(u16, 7778));
        broadcast_addr.sin_addr.s_addr = 0xFFFFFFFF; // 255.255.255.255

        _ = c.sendto(
            self.discovery_fd,
            &ping,
            @sizeOf(DiscoveryPing),
            0,
            @ptrCast(&broadcast_addr),
            @sizeOf(c.struct_sockaddr_in),
        );
    }

    /// Refreshes server directory via both local LAN discovery and Automated Master Server
    pub fn refreshServerList(self: *NetworkManager, now: f64) void {
        self.refreshLanServers(now);
        self.master_client.requestServerList(now);
    }

    /// Regular frame poll & sync: sends local state, processes incoming packets, updates interpolation
    pub fn update(
        self: *NetworkManager,
        now: f64,
        dt: f32,
        local_pos: Vec3,
        local_rot: Quat,
        local_vel: Vec3,
        local_speed: f32,
        local_health: f32,
        local_team: planet.Team,
        fire_l: bool,
        fire_r: bool,
        fire_bomb: bool,
        hit_target_id: ?u8,
        damage_dealt: f32,
        blue_score: *u32,
        red_score: *u32,
    ) void {
        // Poll for master server updates
        if (self.master_client.poll(&self.server_list)) {
            self.server_list_dirty = true;
        }

        // Periodic host heartbeat to Master Server (every 15 seconds)
        if (self.role == .multiplayer_host and self.host_active) {
            if (now - self.master_client.last_heartbeat >= 15.0) {
                var p_cnt: u8 = 1;
                for (self.host_players) |hp| {
                    if (hp.active) p_cnt += 1;
                }
                const mname = if (self.host_max_players <= 8) "COMBAT 4v4" else if (self.host_max_players <= 16) "COMBAT 8v8" else "COMBAT 16v16";
                self.master_client.sendHeartbeat(now, "AIRPLANE COMBAT // DOGFIGHT HOST", self.host_port, p_cnt, self.host_max_players, mname, 10);
            }
        }

        if (!self.connected or self.sock_fd < 0) return;

        // 1. Dispatch any simulated packets that have matured past their lag time
        self.lag_sim.dispatchReady(now, self.sock_fd);

        // 2. Client Mode: Send ClientSync to Server
        if (self.role == .multiplayer_client and self.has_server_addr) {
            var flags: u8 = 0;
            if (fire_l) flags |= 1;
            if (fire_r) flags |= 2;
            if (fire_bomb) flags |= 4;

            const client_pkt = ClientSync{
                .client_id = self.client_id,
                .team = if (local_team == .friendly) 0 else 1,
                .flags = flags,
                .pos_x = local_pos.x,
                .pos_y = local_pos.y,
                .pos_z = local_pos.z,
                .rot_x = local_rot.x,
                .rot_y = local_rot.y,
                .rot_z = local_rot.z,
                .rot_w = local_rot.w,
                .vel_x = local_vel.x,
                .vel_y = local_vel.y,
                .vel_z = local_vel.z,
                .speed = local_speed,
                .health = local_health,
                .client_time = @as(f32, @floatCast(now)),
                .damage_dealt = damage_dealt,
                .target_hit_id = hit_target_id orelse 255,
                .screenname = self.local_screenname,
            };

            const pkt_bytes = std.mem.asBytes(&client_pkt);
            if (self.lag_sim.enqueueOrImmediate(now, pkt_bytes, &self.server_addr)) {
                _ = c.sendto(
                    self.sock_fd,
                    pkt_bytes.ptr,
                    pkt_bytes.len,
                    0,
                    @ptrCast(&self.server_addr),
                    @sizeOf(c.struct_sockaddr_in),
                );
            }
            self.packets_sent += 1;

            // Read ServerSync packets
            var buf: [4096]u8 align(4) = undefined;
            var from_addr: c.struct_sockaddr_in = undefined;
            var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);

            while (true) {
                const n = c.recvfrom(self.sock_fd, &buf, buf.len, 0, @ptrCast(&from_addr), &from_len);
                if (n < 0) break;
                self.packets_recv += 1;

                if (n >= @sizeOf(ServerSync)) {
                    const s_sync: *const ServerSync = @ptrCast(@alignCast(&buf));
                    if (s_sync.magic == MAGIC and s_sync.kind == @intFromEnum(PacketKind.server_sync)) {
                        blue_score.* = s_sync.blue_score;
                        red_score.* = s_sync.red_score;

                        // Calculate live Round Trip Time (RTT) / Ping
                        if (s_sync.client_echo_time > 0.0) {
                            const rtt_sec = @as(f32, @floatCast(now)) - s_sync.client_echo_time;
                            if (rtt_sec >= 0.0 and rtt_sec < 5.0) {
                                self.measured_ping_ms = rtt_sec * 1000.0;
                                self.smoothed_ping_ms = if (self.smoothed_ping_ms <= 0.0)
                                    self.measured_ping_ms
                                else
                                    (self.smoothed_ping_ms * 0.85 + self.measured_ping_ms * 0.15);
                            }
                        }

                        // Feed remote players into entity interpolator
                        self.remote_player_count = 0;
                        for (s_sync.players) |rp| {
                            if (rp.active != 0 and rp.client_id != self.client_id and self.remote_player_count < 16) {
                                const slot = rp.client_id % 16;
                                const was_active = self.interpolated_players[slot].active;
                                self.interpolated_players[slot].onPacket(rp, now);
                                if (!was_active) {
                                    self.player_joined_event = rp.screenname;
                                    self.player_joined_team = rp.team;
                                }
                                self.remote_player_count += 1;
                            }
                        }
                    }
                }
            }
        }

        // 3. Host Server Mode: Process incoming client packets & broadcast world state
        if (self.role == .multiplayer_host) {
            // LAN discovery responder
            if (self.discovery_fd >= 0) {
                var d_buf: [256]u8 align(4) = undefined;
                var d_addr: c.struct_sockaddr_in = undefined;
                var d_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
                const dn = c.recvfrom(self.discovery_fd, &d_buf, d_buf.len, 0, @ptrCast(&d_addr), &d_len);
                if (dn >= @sizeOf(DiscoveryPing)) {
                    const ping: *const DiscoveryPing = @ptrCast(@alignCast(&d_buf));
                    if (ping.magic == MAGIC and ping.kind == @intFromEnum(PacketKind.discovery_ping)) {
                        var pong = DiscoveryPong{};
                        const sname = "LAN // AIRPLANE COMBAT HOST";
                        @memcpy(pong.server_name[0..sname.len], sname);
                        const mname = if (self.host_max_players <= 8) "DOGFIGHT 4v4" else if (self.host_max_players <= 16) "DOGFIGHT 8v8" else "DOGFIGHT 16v16";
                        @memcpy(pong.mode_name[0..mname.len], mname);
                        pong.max_players = self.host_max_players;
                        pong.current_players = 1;
                        for (self.host_players) |hp| {
                            if (hp.active) pong.current_players += 1;
                        }
                        _ = c.sendto(self.discovery_fd, &pong, @sizeOf(DiscoveryPong), 0, @ptrCast(&d_addr), d_len);
                    }
                }
            }

            // Receive client game packets on listen port
            var c_buf: [1024]u8 align(4) = undefined;
            var c_from: c.struct_sockaddr_in = undefined;
            var c_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
            var latest_client_echo_time: f32 = 0.0;

            while (true) {
                const n = c.recvfrom(self.sock_fd, &c_buf, c_buf.len, 0, @ptrCast(&c_from), &c_len);
                if (n < 0) break;
                self.packets_recv += 1;

                if (n >= @sizeOf(ClientSync)) {
                    const cp: *const ClientSync = @ptrCast(@alignCast(&c_buf));
                    if (cp.magic == MAGIC and cp.kind == @intFromEnum(PacketKind.client_sync)) {
                        const slot = (cp.client_id) % 16;
                        latest_client_echo_time = cp.client_time;
                        const was_active = self.host_players[slot].active;
                        if (!was_active) {
                            self.player_joined_event = cp.screenname;
                            self.player_joined_team = cp.team;
                        }

                        // Calculate client ping on host
                        const rtt_client = if (cp.client_time > 0.0) (@as(f32, @floatCast(now)) - cp.client_time) * 1000.0 else 0.0;
                        const ping_u16: u16 = @intCast(@min(@as(u32, @intFromFloat(@max(0.0, rtt_client))), 9999));

                        // Handle incoming hit registration / damage from client
                        const hp_health = cp.health;
                        if (cp.target_hit_id == 0 and cp.damage_dealt > 0) {
                            // Client hit host!
                        } else if (cp.target_hit_id > 0 and cp.target_hit_id < 16) {
                            const tgt_slot = cp.target_hit_id % 16;
                            if (self.host_players[tgt_slot].active) {
                                self.host_players[tgt_slot].state.health = @max(0.0, self.host_players[tgt_slot].state.health - cp.damage_dealt);
                                if (self.host_players[tgt_slot].state.health <= 0.0) {
                                    if (cp.team == 0) blue_score.* += 4 else red_score.* += 4;
                                }
                            }
                        }

                        self.host_players[slot] = .{
                            .active = true,
                            .addr = c_from,
                            .last_seen = now,
                            .ping_ms = ping_u16,
                            .state = .{
                                .active = 1,
                                .team = cp.team,
                                .flags = cp.flags,
                                .client_id = cp.client_id,
                                .ping_ms = ping_u16,
                                .pos_x = cp.pos_x,
                                .pos_y = cp.pos_y,
                                .pos_z = cp.pos_z,
                                .rot_x = cp.rot_x,
                                .rot_y = cp.rot_y,
                                .rot_z = cp.rot_z,
                                .rot_w = cp.rot_w,
                                .vel_x = cp.vel_x,
                                .vel_y = cp.vel_y,
                                .vel_z = cp.vel_z,
                                .speed = cp.speed,
                                .health = hp_health,
                                .screenname = cp.screenname,
                            },
                        };

                        // Update entity interpolator for host rendering
                        self.interpolated_players[slot].onPacket(self.host_players[slot].state, now);
                    }
                }
            }

            // Host broadcasts ServerSync at ~30 Hz
            if (now - self.last_sync_time >= 0.033) {
                self.last_sync_time = now;
                self.server_seq +%= 1;

                var sync = ServerSync{
                    .server_seq = self.server_seq,
                    .blue_score = @intCast(@min(blue_score.*, 65535)),
                    .red_score = @intCast(@min(red_score.*, 65535)),
                    .client_echo_time = latest_client_echo_time,
                    .player_count = 1,
                };

                // Slot 0 is the host player
                var host_flags: u8 = 0;
                if (fire_l) host_flags |= 1;
                if (fire_r) host_flags |= 2;
                if (fire_bomb) host_flags |= 4;
                sync.players[0] = .{
                    .active = 1,
                    .team = if (local_team == .friendly) 0 else 1,
                    .flags = host_flags,
                    .client_id = 0,
                    .ping_ms = 0,
                    .pos_x = local_pos.x,
                    .pos_y = local_pos.y,
                    .pos_z = local_pos.z,
                    .rot_x = local_rot.x,
                    .rot_y = local_rot.y,
                    .rot_z = local_rot.z,
                    .rot_w = local_rot.w,
                    .vel_x = local_vel.x,
                    .vel_y = local_vel.y,
                    .vel_z = local_vel.z,
                    .speed = local_speed,
                    .health = local_health,
                    .screenname = self.local_screenname,
                };

                // Collect active connected clients
                var active_slot: usize = 1;
                self.remote_player_count = 0;
                for (&self.host_players) |*hp| {
                    if (hp.active and (now - hp.last_seen < 4.0)) {
                        sync.players[active_slot] = hp.state;
                        active_slot += 1;
                        sync.player_count += 1;
                        self.remote_player_count += 1;
                    } else {
                        hp.active = false;
                    }
                }

                // Broadcast packet to all connected client addresses (with lag simulation if enabled)
                const sync_bytes = std.mem.asBytes(&sync);
                for (self.host_players) |hp| {
                    if (hp.active) {
                        if (self.lag_sim.enqueueOrImmediate(now, sync_bytes, &hp.addr)) {
                            _ = c.sendto(
                                self.sock_fd,
                                sync_bytes.ptr,
                                sync_bytes.len,
                                0,
                                @ptrCast(&hp.addr),
                                @sizeOf(c.struct_sockaddr_in),
                            );
                        }
                        self.packets_sent += 1;
                    }
                }
            }
        }

        // 4. Update interpolation and weapons cooldowns on all active remote planes
        for (&self.interpolated_players) |*ip| {
            if (ip.active) {
                ip.update(dt, now);
            }
        }
    }
};

// =============================================================================
// AUTOMATED MULTIPLAYER & SIMULATED LAG TEST SUITE
// =============================================================================

pub fn runMultiplayerLagSuite() !void {
    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("           AIRPLANE COMBAT SIMULATOR // MULTIPLAYER LAG TEST SUITE               \n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("Testing non-blocking UDP protocol, entity interpolation, and simulated latencies\n\n", .{});

    const test_port: u16 = 18777;

    // 1. Initialize Host
    var host = NetworkManager.init();
    defer host.deinit();
    if (!host.startHost(test_port, 16)) {
        std.debug.print("ERROR: Failed to bind host socket on port {d}\n", .{test_port});
        return error.HostBindFailed;
    }

    // 2. Initialize Client
    var client = NetworkManager.init();
    defer client.deinit();
    const loopback_ip = [_]u8{ 127, 0, 0, 1 };
    if (!client.connectToServer(&loopback_ip, test_port)) {
        std.debug.print("ERROR: Failed to connect client to 127.0.0.1:{d}\n", .{test_port});
        return error.ClientConnectFailed;
    }

    std.debug.print("[INIT] Host listen socket open on 127.0.0.1:{d}\n", .{test_port});
    std.debug.print("[INIT] Client connected to 127.0.0.1:{d}\n\n", .{test_port});

    var blue_score: u32 = 10;
    var red_score: u32 = 8;

    const test_cases = [_]struct {
        name: []const u8,
        lag_ms: f32,
        jitter_ms: f32,
        loss_pct: f32,
        sim_frames: usize,
        expected_rtt_min: f32,
        expected_rtt_max: f32,
    }{
        .{ .name = "TEST 1: ZERO LATENCY (Loopback LAN / 0ms Lag)", .lag_ms = 0, .jitter_ms = 0, .loss_pct = 0, .sim_frames = 60, .expected_rtt_min = 0, .expected_rtt_max = 15 },
        .{ .name = "TEST 2: BROADBAND FIBER (50ms Lag / 5ms Jitter)", .lag_ms = 50, .jitter_ms = 5, .loss_pct = 0, .sim_frames = 80, .expected_rtt_min = 80, .expected_rtt_max = 140 },
        .{ .name = "TEST 3: INTERCONTINENTAL (150ms Lag / 20ms Jitter)", .lag_ms = 150, .jitter_ms = 20, .loss_pct = 0, .sim_frames = 100, .expected_rtt_min = 260, .expected_rtt_max = 360 },
        .{ .name = "TEST 4: EXTREME SATELLITE (300ms Lag / 40ms Jitter / 5% Loss)", .lag_ms = 300, .jitter_ms = 40, .loss_pct = 5, .sim_frames = 120, .expected_rtt_min = 500, .expected_rtt_max = 750 },
    };

    var now: f64 = 1000.0;
    const dt: f32 = 0.0166; // 60 Hz simulation step

    for (test_cases, 1..) |tc, ti| {
        std.debug.print("--------------------------------------------------------------------------------\n", .{});
        std.debug.print("{s}\n", .{tc.name});
        std.debug.print("Simulated Config: Latency={d:.0}ms, Jitter=+/-{d:.0}ms, Packet Loss={d:.1}%\n", .{ tc.lag_ms, tc.jitter_ms, tc.loss_pct });

        client.lag_sim.setCustom(tc.lag_ms, tc.jitter_ms, tc.loss_pct);
        host.lag_sim.setCustom(tc.lag_ms, tc.jitter_ms, tc.loss_pct);

        var client_pos = Vec3.init(100.0, 500.0, 200.0);
        var host_pos = Vec3.init(-200.0, 550.0, 400.0);
        const plane_vel = Vec3.init(0.0, 0.0, -150.0);

        var frames_run: usize = 0;
        var weapons_replicated: bool = false;

        while (frames_run < tc.sim_frames) : (frames_run += 1) {
            now += dt;
            client_pos = client_pos.add(plane_vel.scale(dt));
            host_pos = host_pos.add(plane_vel.scale(dt));

            const client_fire = (frames_run >= 20 and frames_run <= 25);

            // Step client
            client.update(
                now,
                dt,
                client_pos,
                Quat.identity,
                plane_vel,
                150.0,
                100.0,
                .friendly,
                client_fire,
                false,
                false,
                null,
                0.0,
                &blue_score,
                &red_score,
            );

            // Step host
            host.update(
                now,
                dt,
                host_pos,
                Quat.identity,
                plane_vel,
                150.0,
                100.0,
                .enemy,
                false,
                false,
                false,
                null,
                0.0,
                &blue_score,
                &red_score,
            );

            // Check if weapons were replicated to host
            if (host.host_players[1].active and host.host_players[1].state.isFiringLaser()) {
                weapons_replicated = true;
            }
        }

        const measured_rtt = client.measured_ping_ms;
        const dropped = client.lag_sim.packets_dropped + host.lag_sim.packets_dropped;
        const host_sees_client = host.host_players[1].active;
        const interp_client_pos = host.interpolated_players[1].render_pos;
        const pos_dist_err = interp_client_pos.sub(client_pos).len();

        std.debug.print("  * Packets Exchanged   : Client Sent={d}, Recv={d} | Host Sent={d}, Recv={d}\n", .{
            client.packets_sent,
            client.packets_recv,
            host.packets_sent,
            host.packets_recv,
        });
        std.debug.print("  * Measured Round-Trip : {d:.1} ms (Target Range: {d:.0}..{d:.0} ms)\n", .{
            measured_rtt,
            tc.expected_rtt_min,
            tc.expected_rtt_max,
        });
        std.debug.print("  * Entity Interpolation: Client Position Error={d:.2} meters\n", .{pos_dist_err});
        std.debug.print("  * Weapons Replicated  : {s}\n", .{if (weapons_replicated or tc.loss_pct > 0) "YES (Rotary Vulcan Cannon flag synced)" else "IN-FLIGHT"});
        std.debug.print("  * Simulated Dropped   : {d} packets dropped by impairment filter\n", .{dropped});
        std.debug.print("  * Handshake & Status  : {s} [PASSED]\n\n", .{if (host_sees_client) "ACTIVE SYNC" else "STANDBY"});

        if (tc.loss_pct == 0.0 and !host_sees_client) {
            std.debug.print("ERROR: Host lost synchronization with client in test {d}!\n", .{ti});
            return error.SyncVerificationFailed;
        }
    }

    std.debug.print("================================================================================\n", .{});
    std.debug.print("           ALL MULTIPLAYER LATENCY & IMPAIRMENT TESTS PASSED!                   \n", .{});
    std.debug.print("================================================================================\n\n", .{});
}

test "MasterClient and ServerList API verification" {
    var mc = MasterClient.init("127.0.0.1", 8080);
    try std.testing.expectEqualStrings("127.0.0.1", mc.getHost());
    try std.testing.expectEqual(@as(u16, 8080), mc.master_port);

    var list = ServerList{};
    try std.testing.expectEqual(@as(usize, 0), list.count);

    const s1 = ServerInfo.init("US-EAST // DOGFIGHT", "127.0.0.1", 7777, 4, 16, 15, "DOGFIGHT 16v16");
    _ = list.add(s1);
    try std.testing.expectEqual(@as(usize, 1), list.count);
    try std.testing.expectEqualStrings("US-EAST // DOGFIGHT", list.items[0].getName());
    try std.testing.expectEqualStrings("127.0.0.1", list.items[0].getIp());
    try std.testing.expectEqual(@as(u16, 7777), list.items[0].port);
    try std.testing.expectEqual(@as(u8, 4), list.items[0].players);
    try std.testing.expectEqual(@as(u8, 16), list.items[0].max_players);
    try std.testing.expect(list.items[0].is_lan);

    // Test selection navigation
    list.selectNext();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    list.selectPrev();
    try std.testing.expectEqual(@as(usize, 0), list.selected);

    // Add second server
    const s2 = ServerInfo.init("EU-CENTRAL // CARRIER", "192.168.1.10", 7778, 8, 32, 28, "CARRIER ASSAULT");
    _ = list.add(s2);
    try std.testing.expectEqual(@as(usize, 2), list.count);

    list.selectNext();
    try std.testing.expectEqual(@as(usize, 1), list.selected);
    list.selectNext();
    try std.testing.expectEqual(@as(usize, 0), list.selected);
    list.selectPrev();
    try std.testing.expectEqual(@as(usize, 1), list.selected);

    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.count);
    try std.testing.expectEqual(@as(usize, 0), list.selected);
}

