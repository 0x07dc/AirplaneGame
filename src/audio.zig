const std = @import("std");
const c = @import("c");

pub const SoundKind = enum {
    shoot_left,
    shoot_right,
    hit,
    hit_armor,
    explosion,
    explosion_big,
    bomb_drop,
    carrier_trap,
    carrier_heal,
};

const max_voices = 24;

const Voice = struct {
    active: bool = false,
    kind: SoundKind = .shoot_left,
    time: f32 = 0.0,
    duration: f32 = 0.0,
    volume: f32 = 1.0,
    pan: f32 = 0.0,
    phase: f32 = 0.0,
    phase2: f32 = 0.0,
    noise_state: u32 = 12345,
};

const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const AudioEngine = struct {
    pcm_handle: ?*c.snd_pcm_t = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: SpinLock = .{},

    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,

    // Engine synth state (updated from main thread)
    engine_speed_ratio: f32 = 0.0,
    engine_boost: f32 = 0.0,
    engine_turb: f32 = 0.0,
    engine_active: bool = false,

    // Elevator / Flight Lounge Music State
    music_active: bool = false,
    music_volume: f32 = 0.35,
    music_cur_vol: f32 = 0.0,
    music_time: f32 = 0.0,
    music_chord_phases: [4]f32 = [_]f32{0.0} ** 4,
    music_bass_phase: f32 = 0.0,
    music_lead_phase: f32 = 0.0,
    music_vibrato_phase: f32 = 0.0,
    music_tremolo_phase: f32 = 0.0,
    music_kick_phase: f32 = 0.0,
    music_snap_phase: f32 = 0.0,

    // Audio thread synthesis phase accumulators
    engine_phase1: f32 = 0.0,
    engine_phase2: f32 = 0.0,
    boost_flutter_phase: f32 = 0.0,
    noise_state: u32 = 98765,
    shot_seed: u32 = 123456789,
    noise_lpf: f32 = 0.0,
    wind_lpf: f32 = 0.0,

    pub fn setMusicState(self: *AudioEngine, active: bool, vol: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.music_active = active;
        self.music_volume = vol;
        if (!active) {
            self.music_cur_vol = 0.0;
        }
    }

    pub fn setEngineActive(self: *AudioEngine, active: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.engine_active = active;
    }

    pub fn init(self: *AudioEngine) void {
        var pcm: ?*c.snd_pcm_t = null;
        const res = c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_PLAYBACK, 0);
        if (res < 0) {
            std.log.warn("audio: default PCM device unavailable (code {d}); running silent", .{res});
            self.pcm_handle = null;
            return;
        }

        // 44.1 kHz, 16-bit signed interleaved stereo, ~25ms latency
        const set_res = c.snd_pcm_set_params(
            pcm,
            c.SND_PCM_FORMAT_S16_LE,
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            2,
            44100,
            1,
            25000,
        );
        if (set_res < 0) {
            std.log.warn("audio: failed to configure PCM params (code {d})", .{set_res});
            _ = c.snd_pcm_close(pcm);
            self.pcm_handle = null;
            return;
        }

        self.pcm_handle = pcm;
        self.running.store(true, .release);

        self.thread = std.Thread.spawn(.{}, audioWorker, .{self}) catch |err| {
            std.log.warn("audio: failed to spawn audio thread: {s}", .{@errorName(err)});
            _ = c.snd_pcm_close(pcm);
            self.pcm_handle = null;
            self.running.store(false, .release);
            return;
        };

        std.log.info("audio: initialized real-time procedural sound synthesizer (44.1kHz stereo ALSA)", .{});
    }

    pub fn deinit(self: *AudioEngine) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.pcm_handle) |pcm| {
            _ = c.snd_pcm_drain(pcm);
            _ = c.snd_pcm_close(pcm);
            self.pcm_handle = null;
        }
    }

    pub fn triggerShoot(self: *AudioEngine, is_left: bool) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shot_seed = self.shot_seed *% 1664525 +% 1013904223;
        self.spawnVoice(.{
            .active = true,
            .kind = if (is_left) .shoot_left else .shoot_right,
            .time = 0.0,
            .duration = 0.088,
            .volume = 0.65,
            .pan = if (is_left) -0.32 else 0.32,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = self.shot_seed,
        });
    }

    pub fn triggerHit(self: *AudioEngine, is_armor: bool) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.spawnVoice(.{
            .active = true,
            .kind = if (is_armor) .hit_armor else .hit,
            .time = 0.0,
            .duration = if (is_armor) 0.16 else 0.12,
            .volume = 0.85,
            .pan = 0.0,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = 54321,
        });
    }

    pub fn triggerExplosion(self: *AudioEngine, is_big: bool) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.spawnVoice(.{
            .active = true,
            .kind = if (is_big) .explosion_big else .explosion,
            .time = 0.0,
            .duration = if (is_big) 1.8 else 1.25,
            .volume = if (is_big) 1.25 else 1.0,
            .pan = 0.0,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = 99123,
        });
    }

    pub fn triggerBombDrop(self: *AudioEngine) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.spawnVoice(.{
            .active = true,
            .kind = .bomb_drop,
            .time = 0.0,
            .duration = 0.35,
            .volume = 1.05,
            .pan = 0.0,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = 314159,
        });
    }

    pub fn triggerCarrierTrap(self: *AudioEngine) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.spawnVoice(.{
            .active = true,
            .kind = .carrier_trap,
            .time = 0.0,
            .duration = 0.45,
            .volume = 1.15,
            .pan = 0.0,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = 77123,
        });
    }

    pub fn triggerCarrierHeal(self: *AudioEngine) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.spawnVoice(.{
            .active = true,
            .kind = .carrier_heal,
            .time = 0.0,
            .duration = 0.42,
            .volume = 0.85,
            .pan = 0.0,
            .phase = 0.0,
            .phase2 = 0.0,
            .noise_state = 88442,
        });
    }

    pub fn triggerPlayerJoined(self: *AudioEngine) void {
        self.triggerCarrierHeal();
    }

    pub fn triggerTargetLockTone(self: *AudioEngine) void {
        self.triggerCarrierHeal();
    }

    pub fn updateEngine(self: *AudioEngine, speed_ratio: f32, is_boost: bool, turb: f32) void {
        if (self.pcm_handle == null) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.engine_active = true;
        self.engine_speed_ratio = std.math.clamp(speed_ratio, 0.0, 1.5);
        self.engine_boost = if (is_boost) 1.0 else 0.0;
        self.engine_turb = std.math.clamp(turb, 0.0, 1.5);
    }

    fn spawnVoice(self: *AudioEngine, new_v: Voice) void {
        // Find first free slot
        for (&self.voices) |*v| {
            if (!v.active) {
                v.* = new_v;
                return;
            }
        }
        // Voice stealing: replace voice with greatest elapsed fraction
        var best_idx: usize = 0;
        var max_progress: f32 = -1.0;
        for (self.voices, 0..) |v, i| {
            const prog = v.time / @max(v.duration, 0.001);
            if (prog > max_progress) {
                max_progress = prog;
                best_idx = i;
            }
        }
        self.voices[best_idx] = new_v;
    }

    fn audioWorker(self: *AudioEngine) void {
        const sample_rate: f32 = 44100.0;
        const dt: f32 = 1.0 / sample_rate;
        const buffer_frames: usize = 512;
        var pcm_buffer: [buffer_frames * 2]i16 = undefined;

        while (self.running.load(.acquire)) {
            // Local snapshot of engine & music state
            var speed_r: f32 = 0.0;
            var boost_val: f32 = 0.0;
            var turb_val: f32 = 0.0;
            var eng_active: bool = false;
            var mus_active: bool = false;
            var mus_target_vol: f32 = 0.35;
            {
                self.mutex.lock();
                speed_r = self.engine_speed_ratio;
                boost_val = self.engine_boost;
                turb_val = self.engine_turb;
                eng_active = self.engine_active;
                mus_active = self.music_active;
                mus_target_vol = self.music_volume;
                self.mutex.unlock();
            }

            for (0..buffer_frames) |frame_i| {
                var mix_l: f32 = 0.0;
                var mix_r: f32 = 0.0;

                // Smooth music volume crossfade (instant silence when entering game or paused)
                const target_v = if (mus_active) mus_target_vol else 0.0;
                if (!mus_active) {
                    self.music_cur_vol = 0.0;
                } else {
                    self.music_cur_vol += (target_v - self.music_cur_vol) * (dt * 12.0);
                }

                // 1. Inspiring Ready-To-Fly Elevator / Flight Lounge Music Synthesizer
                if (self.music_cur_vol > 0.001) {
                    const sec_per_beat: f32 = 60.0 / 114.0;
                    const loop_beats: f32 = 32.0;
                    const beat = @mod(self.music_time / sec_per_beat, loop_beats);
                    const measure: usize = @intFromFloat(beat / 4.0);
                    const beat_in_bar = beat - @as(f32, @floatFromInt(measure)) * 4.0;
                    const frac_in_beat = @mod(beat, 1.0);

                    // Chords: 0,4=Fmaj9, 1=Em7, 2=Dm9, 3=Cmaj9, 5=G7sus4, 6=Am9, 7=Turnaround
                    var chord_f = [4]f32{ 220.00, 261.63, 329.63, 392.00 }; // Fmaj9 (A3, C4, E4, G4)
                    var root_f: f32 = 87.31; // F2

                    switch (measure) {
                        0, 4 => { // Fmaj9
                            root_f = 87.31;
                            chord_f = .{ 220.00, 261.63, 329.63, 392.00 };
                        },
                        1 => { // Em7
                            root_f = 82.41;
                            chord_f = .{ 196.00, 246.94, 293.66, 392.00 };
                        },
                        2 => { // Dm9
                            root_f = 73.42;
                            chord_f = .{ 174.61, 220.00, 261.63, 329.63 };
                        },
                        3 => { // Cmaj9
                            root_f = 65.41;
                            chord_f = .{ 164.81, 196.00, 246.94, 293.66 };
                        },
                        5 => { // G7sus4
                            root_f = 98.00;
                            chord_f = .{ 174.61, 261.63, 293.66, 349.23 };
                        },
                        6 => { // Am9
                            root_f = 110.00;
                            chord_f = .{ 261.63, 329.63, 392.00, 493.88 };
                        },
                        7 => { // Turnaround (Gm7 -> C13sus)
                            if (beat_in_bar < 2.0) {
                                root_f = 98.00;
                                chord_f = .{ 174.61, 233.08, 293.66, 349.23 };
                            } else {
                                root_f = 65.41;
                                chord_f = .{ 164.81, 220.00, 233.08, 293.66 };
                            }
                        },
                        else => {},
                    }

                    // Walking Bass (Warm sine with soft harmonic richness)
                    var cur_bass_f = root_f;
                    const beat_int: usize = @intFromFloat(beat_in_bar);
                    switch (beat_int) {
                        0 => cur_bass_f = root_f,
                        1 => cur_bass_f = root_f * 1.5,
                        2 => cur_bass_f = root_f * 1.26,
                        3 => cur_bass_f = root_f * 1.12,
                        else => cur_bass_f = root_f,
                    }
                    self.music_bass_phase += cur_bass_f * dt * (2.0 * std.math.pi);
                    if (self.music_bass_phase > 2.0 * std.math.pi) self.music_bass_phase -= 2.0 * std.math.pi;
                    const bass_env = @exp(-frac_in_beat * 3.2);
                    const bass_sig = @sin(self.music_bass_phase) * 0.42 * bass_env;

                    // Electric Piano / Rhodes Chords (stereo tremolo)
                    self.music_tremolo_phase += 4.5 * dt * (2.0 * std.math.pi);
                    if (self.music_tremolo_phase > 2.0 * std.math.pi) self.music_tremolo_phase -= 2.0 * std.math.pi;
                    const tremolo_l = 0.5 + 0.35 * @sin(self.music_tremolo_phase);
                    const tremolo_r = 0.5 - 0.35 * @sin(self.music_tremolo_phase);

                    const strike0 = @exp(-beat_in_bar * 1.5);
                    const strike1 = if (beat_in_bar >= 1.5) @exp(-(beat_in_bar - 1.5) * 2.2) else 0.0;
                    const strike2 = if (beat_in_bar >= 2.5) @exp(-(beat_in_bar - 2.5) * 2.2) else 0.0;
                    const chord_env = @max(strike0 * 0.65, @max(strike1 * 0.45, strike2 * 0.55));

                    var chord_sum: f32 = 0.0;
                    for (0..4) |ci| {
                        self.music_chord_phases[ci] += chord_f[ci] * dt * (2.0 * std.math.pi);
                        if (self.music_chord_phases[ci] > 2.0 * std.math.pi) self.music_chord_phases[ci] -= 2.0 * std.math.pi;
                        const chime = @sin(self.music_chord_phases[ci]) + 0.22 * @sin(self.music_chord_phases[ci] * 2.0);
                        chord_sum += chime;
                    }
                    const chord_sig = chord_sum * 0.08 * chord_env;

                    // Lounge Percussion (Kick, Rimshot, Soft Shaker Hi-Hat)
                    const kick_t = @min(beat_in_bar, if (beat_in_bar >= 2.5) beat_in_bar - 2.5 else 999.0);
                    var kick_sig: f32 = 0.0;
                    if (kick_t < 0.25) {
                        const k_freq = 50.0 + 85.0 * @exp(-kick_t * 22.0);
                        self.music_kick_phase += k_freq * dt * (2.0 * std.math.pi);
                        if (self.music_kick_phase > 2.0 * std.math.pi) self.music_kick_phase -= 2.0 * std.math.pi;
                        kick_sig = @sin(self.music_kick_phase) * 0.45 * @exp(-kick_t * 14.0);
                    }

                    const snap_t = @min(
                        if (beat_in_bar >= 1.0) beat_in_bar - 1.0 else 999.0,
                        if (beat_in_bar >= 3.0) beat_in_bar - 3.0 else 999.0,
                    );
                    var snap_sig: f32 = 0.0;
                    if (snap_t < 0.12) {
                        self.music_snap_phase += 1400.0 * dt * (2.0 * std.math.pi);
                        if (self.music_snap_phase > 2.0 * std.math.pi) self.music_snap_phase -= 2.0 * std.math.pi;
                        self.noise_state = self.noise_state *% 1664525 +% 1013904223;
                        const n_snap = (@as(f32, @floatFromInt(self.noise_state >> 16)) / 32768.0) - 1.0;
                        snap_sig = (@sin(self.music_snap_phase) * 0.28 + n_snap * 0.18) * @exp(-snap_t * 35.0);
                    }

                    const eighth_frac = @mod(beat * 2.0, 1.0);
                    self.noise_state = self.noise_state *% 1664525 +% 1013904223;
                    const n_hat = (@as(f32, @floatFromInt(self.noise_state >> 16)) / 32768.0) - 1.0;
                    const hihat_sig = if (eighth_frac < 0.18) n_hat * 0.07 * @exp(-eighth_frac * 25.0) else 0.0;

                    // Inspiring Ready-To-Fly Melodic Lead (Flute / Vibraphone)
                    const melody_scale = [32]f32{
                        440.00, 523.25, 659.25, 783.99, // M0: A4 -> C5 -> E5 -> G5
                        659.25, 659.25, 587.33, 493.88, // M1: E5 -> E5 -> D5 -> B4
                        440.00, 523.25, 659.25, 659.25, // M2: A4 -> C5 -> E5 -> E5
                        587.33, 587.33, 523.25, 523.25, // M3: D5 -> D5 -> C5 -> C5
                        523.25, 659.25, 783.99, 880.00, // M4: C5 -> E5 -> G5 -> A5
                        987.77, 987.77, 783.99, 587.33, // M5: B5 -> B5 -> G5 -> D5
                        659.25, 659.25, 880.00, 880.00, // M6: E5 -> E5 -> A5 -> A5
                        783.99, 659.25, 587.33, 523.25, // M7: G5 -> E5 -> D5 -> C5
                    };
                    const beat_idx: usize = @intCast(@min(@as(usize, @intFromFloat(beat)), 31));
                    const lead_target_f = melody_scale[beat_idx];

                    self.music_vibrato_phase += 5.2 * dt * (2.0 * std.math.pi);
                    if (self.music_vibrato_phase > 2.0 * std.math.pi) self.music_vibrato_phase -= 2.0 * std.math.pi;
                    const vibrato_depth = if (frac_in_beat > 0.25) 5.5 * @sin(self.music_vibrato_phase) else 0.0;
                    const lead_f = lead_target_f + vibrato_depth;

                    self.music_lead_phase += lead_f * dt * (2.0 * std.math.pi);
                    if (self.music_lead_phase > 2.0 * std.math.pi) self.music_lead_phase -= 2.0 * std.math.pi;

                    const lead_env = if (frac_in_beat < 0.08)
                        frac_in_beat / 0.08
                    else
                        @exp(-(frac_in_beat - 0.08) * 1.8);

                    const lead_tone = @sin(self.music_lead_phase) * 0.75 + @sin(self.music_lead_phase * 3.0) * 0.15;
                    const lead_sig = lead_tone * 0.16 * lead_env;

                    // Mix music bus into master channels (scaled to preserve master headroom for SFX)
                    const mus_scale: f32 = 0.35;
                    const mus_l = (bass_sig + chord_sig * tremolo_l + kick_sig + snap_sig * 0.9 + hihat_sig * 0.8 + lead_sig * 0.95) * (self.music_cur_vol * mus_scale);
                    const mus_r = (bass_sig + chord_sig * tremolo_r + kick_sig + snap_sig * 1.1 + hihat_sig * 1.2 + lead_sig * 1.05) * (self.music_cur_vol * mus_scale);

                    mix_l += mus_l;
                    mix_r += mus_r;

                    self.music_time += dt;
                }

                // 2. Continuous Jet Thruster & Afterburner Engine Synthesizer (Active in-flight)
                if (eng_active) {
                    // Primary engine turbine frequency
                    const base_f = 68.0 + speed_r * 145.0 + boost_val * 35.0;
                    self.engine_phase1 += base_f * dt * (2.0 * std.math.pi);
                    if (self.engine_phase1 > 2.0 * std.math.pi) self.engine_phase1 -= 2.0 * std.math.pi;

                    // Harmonic compressor whine
                    const whine_f = base_f * 3.4;
                    self.engine_phase2 += whine_f * dt * (2.0 * std.math.pi);
                    if (self.engine_phase2 > 2.0 * std.math.pi) self.engine_phase2 -= 2.0 * std.math.pi;

                    const hum = @sin(self.engine_phase1) * 0.16 + @sin(self.engine_phase2) * 0.05;

                    // Pseudo-random noise generator
                    self.noise_state = self.noise_state *% 1664525 +% 1013904223;
                    const raw_noise = (@as(f32, @floatFromInt(self.noise_state >> 16)) / 32768.0) - 1.0;

                    // Low-pass filtered combustion rumble
                    const alpha_comb = 0.04 + boost_val * 0.08;
                    self.noise_lpf += (raw_noise - self.noise_lpf) * alpha_comb;

                    // Afterburner blowtorch flame flutter (34 Hz)
                    self.boost_flutter_phase += 34.0 * dt * (2.0 * std.math.pi);
                    if (self.boost_flutter_phase > 2.0 * std.math.pi) self.boost_flutter_phase -= 2.0 * std.math.pi;
                    const flutter = 0.85 + 0.15 * @sin(self.boost_flutter_phase);

                    // High-speed aerodynamic wind rush
                    const alpha_wind = 0.12;
                    self.wind_lpf += (raw_noise - self.wind_lpf) * alpha_wind;
                    const wind_rush = self.wind_lpf * (speed_r * 0.09 + turb_val * 0.08);

                    const engine_sig = (hum + self.noise_lpf * (0.28 + boost_val * 0.55 * flutter)) * (0.35 + speed_r * 0.40) + wind_rush;
                    mix_l += engine_sig;
                    mix_r += engine_sig;
                }

                // 2. Active One-Shot Sound Voices (Shooting, Hits, Explosions)
                {
                    self.mutex.lock();
                    for (&self.voices) |*v| {
                        if (!v.active) continue;

                        const t = v.time;
                        var s_sig: f32 = 0.0;

                        switch (v.kind) {
                            .shoot_left, .shoot_right => {
                                // Fast exponential pitch sweep from 950 Hz down to 180 Hz
                                const sweep_f = 180.0 + 770.0 * @exp(-t / 0.024);
                                v.phase += sweep_f * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;

                                // Pulse wave + snappy noise transient attack
                                v.noise_state = v.noise_state *% 1664525 +% 1013904223;
                                const n_val = (@as(f32, @floatFromInt(v.noise_state >> 16)) / 32768.0) - 1.0;
                                const transient = if (t < 0.015) n_val * 0.45 * (1.0 - t / 0.015) else 0.0;

                                const tone = if (@sin(v.phase) > 0.0) @as(f32, 0.42) else @as(f32, -0.42);
                                const env = @exp(-t / 0.032);
                                s_sig = (tone + transient) * env * v.volume;
                            },
                            .hit, .hit_armor => {
                                // Resonant metallic impact + low thud
                                const f1: f32 = if (v.kind == .hit_armor) 1450.0 else 1150.0;
                                const f2: f32 = if (v.kind == .hit_armor) 820.0 else 640.0;
                                v.phase += f1 * dt * (2.0 * std.math.pi);
                                v.phase2 += f2 * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;
                                if (v.phase2 > 2.0 * std.math.pi) v.phase2 -= 2.0 * std.math.pi;

                                const ring = (@sin(v.phase) * 0.6 + @sin(v.phase2) * 0.4) * @exp(-t / 0.028);
                                const thud = @sin(v.time * 95.0 * 2.0 * std.math.pi) * @exp(-t / 0.045) * 0.5;
                                s_sig = (ring + thud) * v.volume;
                            },
                            .explosion, .explosion_big => {
                                // Low sub-bass drop (88 Hz -> 28 Hz) + filtered rumble
                                const f_exp = 28.0 + 60.0 * @exp(-t / 0.35);
                                v.phase += f_exp * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;

                                v.noise_state = v.noise_state *% 1664525 +% 1013904223;
                                const n_val = (@as(f32, @floatFromInt(v.noise_state >> 16)) / 32768.0) - 1.0;

                                const boom = @sin(v.phase) * 0.55 * @exp(-t / 0.45);
                                const decay_rate: f32 = if (v.kind == .explosion_big) 0.55 else 0.38;
                                const rumble = n_val * 0.65 * @exp(-t / decay_rate);
                                s_sig = (boom + rumble) * v.volume;
                            },
                            .bomb_drop => {
                                // Pneumatic rack latch release click + heavy low wind whoosh
                                const click_freq = 650.0 * @exp(-t / 0.012);
                                v.phase += click_freq * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;
                                const click = if (t < 0.025) @sin(v.phase) * (1.0 - t / 0.025) else 0.0;

                                v.noise_state = v.noise_state *% 1664525 +% 1013904223;
                                const n_val = (@as(f32, @floatFromInt(v.noise_state >> 16)) / 32768.0) - 1.0;
                                const whoosh = n_val * 0.45 * @sin(std.math.clamp(t / 0.35, 0.0, 1.0) * std.math.pi);
                                s_sig = (click * 0.6 + whoosh * 0.5) * v.volume;
                            },
                            .carrier_trap => {
                                // Arresting cable high-tension brake deceleration screech + cable snap
                                const f_whine: f32 = 540.0 * (1.0 - t / 0.45) + 120.0;
                                v.phase += f_whine * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;
                                v.noise_state = v.noise_state *% 1664525 +% 1013904223;
                                const n_val = (@as(f32, @floatFromInt(v.noise_state >> 16)) / 32768.0) - 1.0;
                                const tire_screech = n_val * 0.40 * @exp(-t / 0.35);
                                const cable_tone = @sin(v.phase) * 0.45 * @exp(-t / 0.40);
                                s_sig = (tire_screech + cable_tone) * v.volume;
                            },
                            .carrier_heal => {
                                // Sci-fi high-tech harmonic resonance pulse / recharge chime
                                const f1 = 520.0 + 360.0 * @sin(std.math.clamp(t / 0.40, 0.0, 1.0) * (std.math.pi * 0.5));
                                const f2 = f1 * 1.5;
                                v.phase += f1 * dt * (2.0 * std.math.pi);
                                v.phase2 += f2 * dt * (2.0 * std.math.pi);
                                if (v.phase > 2.0 * std.math.pi) v.phase -= 2.0 * std.math.pi;
                                if (v.phase2 > 2.0 * std.math.pi) v.phase2 -= 2.0 * std.math.pi;
                                const bell = (@sin(v.phase) * 0.6 + @sin(v.phase2) * 0.35) * @exp(-t / 0.32);
                                s_sig = bell * v.volume;
                            },
                        }

                        // Apply stereo panning
                        const pan_l = std.math.clamp(0.5 - v.pan * 0.5, 0.0, 1.0);
                        const pan_r = std.math.clamp(0.5 + v.pan * 0.5, 0.0, 1.0);
                        mix_l += s_sig * pan_l;
                        mix_r += s_sig * pan_r;

                        v.time += dt;
                        if (v.time >= v.duration) {
                            v.active = false;
                        }
                    }
                    self.mutex.unlock();
                }

                // 3. Soft Limiter (Saturator) & Conversion to 16-Bit Signed Integer
                // Polynomial soft clip: x / (1.0 + |x|) prevents harsh digital distortion
                const sat_l = mix_l / (1.0 + @abs(mix_l));
                const sat_r = mix_r / (1.0 + @abs(mix_r));

                const sample_i16_l: i16 = @intFromFloat(std.math.clamp(sat_l * 31000.0, -32760.0, 32760.0));
                const sample_i16_r: i16 = @intFromFloat(std.math.clamp(sat_r * 31000.0, -32760.0, 32760.0));

                pcm_buffer[frame_i * 2 + 0] = sample_i16_l;
                pcm_buffer[frame_i * 2 + 1] = sample_i16_r;
            }

            // Write PCM buffer to audio hardware
            if (self.pcm_handle) |pcm| {
                const written = c.snd_pcm_writei(pcm, &pcm_buffer, buffer_frames);
                if (written < 0) {
                    // Buffer underrun / error recovery
                    _ = c.snd_pcm_prepare(pcm);
                }
            }
        }
    }
};

pub var global_audio: AudioEngine = .{};
