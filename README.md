# AIRPLANE COMBAT SIMULATOR

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.3-red.svg)](https://www.vulkan.org/)
[![Wayland](https://img.shields.io/badge/Wayland-Native-brightgreen.svg)](https://wayland.freedesktop.org/)
[![ALSA](https://img.shields.io/badge/Audio-ALSA%20Real--Time%20Synth-purple.svg)](https://www.alsa-project.org/)
[![Multiplayer](https://img.shields.io/badge/Multiplayer-UDP%2060Hz-yellow.svg)](src/net.zig)

> **A blistering, fast-paced multiplayer fighter jet combat simulator and dogfighting engine engineered from the metal up in pure Zig 0.16.0.**
>
> Push the envelope in Mach 10+ supersonic interceptors over a fully-simulated spherical planet with 22 procedural metropolitan cities, conduct white-knuckle carrier trap landings, duel in massive 8-, 16-, or 32-player squadron dogfights with dynamic AI backfill, and vibe to real-time procedural elevator lounge jazz on the title screen. Zero engine bloat. Zero heavyweight frameworks. Pure systems programming.

---

## Table of Contents

1. [What is Airplane Combat Simulator?](#what-is-airplane-combat-simulator)
2. [Exciting Features](#exciting-features)
3. [Installing & Obtaining for Your Linux Distro](#installing--obtaining-for-your-linux-distro)
   - [Arch Linux, Manjaro & EndeavourOS (AUR)](#arch-linux-manjaro--endeavouros-aur)
   - [Fedora, RHEL & CentOS Stream (Flatpak / Flathub)](#fedora-rhel--centos-stream-flatpak--flathub)
   - [Ubuntu, Debian, Linux Mint & Pop!_OS (Flatpak / Flathub)](#ubuntu-debian-linux-mint--pop_os-flatpak--flathub)
   - [openSUSE Tumbleweed & Leap (Flatpak / Flathub)](#opensuse-tumbleweed--leap-flatpak--flathub)
   - [Building Locally from Source (Any Distro)](#building-locally-from-source-any-distro)
4. [Title Screen & Elevator Lounge Music](#title-screen--elevator-lounge-music)
5. [Combat Fleet Sizes, Match Limits & 15-Minute Timer](#combat-fleet-sizes-match-limits--15-minute-timer)
6. [Flight Controls & Weapons Doctrine](#flight-controls--weapons-doctrine)
7. [Spherical Planetary Radar & BFM Tactical Guidance](#spherical-planetary-radar--bfm-tactical-guidance)
8. [Naval Carrier Operations & Arrestor Deck Traps](#naval-carrier-operations--arrestor-deck-traps)
9. [Multiplayer & LAN Direct Connect](#multiplayer--lan-direct-connect)
10. [Automated Master Server](#automated-master-server)
11. [Multiplayer Lag Simulator](#multiplayer-lag-simulator)
12. [Performance Benchmarks & Stutter Analysis](#performance-benchmarks--stutter-analysis)
13. [CLI Reference & Automated Test Suites](#cli-reference--automated-test-suites)
14. [License](#license)

---

## What is Airplane Combat Simulator?

**Airplane Combat Simulator** is a high-octane, fast-paced 3D multiplayer air-combat game designed for Linux. Built without third-party game engines (no Unity, no Unreal, no Godot), it communicates directly with the Linux kernel, the Wayland compositor, your GPU via Vulkan 1.3, and your sound card via ALSA PCM.

Whether performing 90-degree knife-edge mountain flybys at 3,800 m/s, locking onto enemy fighters through cloud banks with AIM-9 Sidewinder missiles, evading heavy flak around a massive high-altitude evil Zeppelin, or catching the #3 arresting cable on a pitching aircraft carrier deck, Airplane Combat Simulator delivers immediate, responsive combat dogfighting at a blistering 300+ FPS.

---

## Exciting Features

### ⚡ Hypersonic Aerodynamics & 6-DoF Physics
- **Extreme Speed Envelope**: Fly anywhere from a gentle 20 m/s landing crawl up to a blistering **3,800 m/s (Mach 10+)** across a 9-speed manual gearbox with instant **Emergency Afterburner Boost**.
- **Knife-Edge & Inverted Flight**: Full 90-degree knife-edge flight authority without control deadzones, stable inverted flight, and high-G combat turns.
- **Fly-By-Wire Ground Avoidance (GPWS)**: Automatic collision avoidance system that gently recovers pitch when scraping treetops or wave crests during high-speed nap-of-the-earth (NOE) strafing runs.

### 🌍 Spherical Living Planet
- **Full Planetary Curvature**: Fly around an entire planetary body with real spherical trigonometry and curvature-of-the-earth line-of-sight mechanics.
- **22 Living Metropolitan Cities**: Explore 22 procedural cities featuring over 5,000 street corridors, soaring skyscrapers, illuminated downtown avenues, moving civilian car traffic, and pedestrians.
- **Dynamic Naval Fleets**: Team-aligned supercarriers with illuminated runways, support destroyers, cargo vessels, and deep-ocean patrol zones.

### ⚔️ High-Intensity Dogfighting & Balanced Theaters
- **8, 16, or 32 Combatant Dogfights**: Jump into tight 4v4 squadron skirmishes, 8v8 fleet defense battles, or epic 16v16 air-superiority theater wars in both Single Player and Multiplayer.
- **Dynamic AI Backfill**: Empty player slots are automatically backfilled with lethal AI combatants running Basic Fighter Maneuvers (BFMs). When human pilots join, AI fighters yield their slots seamlessly.
- **15-Minute Regulation Sortie Timer**: Live countdown clock ticking toward match completion with flashing red final-minute urgency alerts.
- **Scaled Match Win Limits**: Race to **50 points** (8 players), **100 points** (16 players), or **200 points** (32 players).
- **Holographic Debriefing Scoreboard**: Full 3D end-of-match debriefing screen celebrating Allied Blue or OPFOR Red victories with comprehensive match statistics.

### 🎯 Military Avionics & Weapons Arsenal
- **20mm Rotary Vulcan Autocannon**: 6,000 RPM high-velocity cannon featuring dynamic lead-computing optical gunsight (LCOS) prediction pippers.
- **AIM-9 Sidewinder Missiles**: Dual wing-pylon infrared/radar homing missiles with proportional navigation tracking and volumetric rocket smoke trails.
- **Mk 82 500 lb Demolition Bombs**: Continuously Computed Impact Point (CCIP) bombing reticle projected directly onto spherical terrain geometry.
- **Clutter-Free HUD**: Smart edge-of-screen radar arrows guide you to off-screen or horizon-masked enemies, and automatically vanish when the hostile enters your forward windshield gunsight to keep your crosshairs clear.
- **Evil Zeppelin Boss**: Heavily armed high-altitude dreadnought airship bristling with anti-air flak batteries.

### 🎵 100% Procedural Real-Time Audio
- **Zero Sound Files**: Every single decibel is synthesized in real time on a dedicated ALSA stereo audio thread using pure mathematical oscillators, resonant filters, and noise shaping.
- **Tactical Flight SFX**: Spooling jet turbine whine, afterburner roaring resonance, 20mm rotary cannon chatter, missile launches, and carrier cable traps.
- **Procedural Elevator Lounge Jazz**: Smooth, inspirational ready-to-fly lounge music playing across menus—featuring rich Rhodes electric piano chords with stereo tremolo, upright walking bass, bossa percussion, and a lyrical vibraphone/flute melody.

---

## Installing & Obtaining for Your Linux Distro

Airplane Combat Simulator is prepared for distribution via **Flatpak (Flathub)** and the **Arch User Repository (AUR)**.

### Arch Linux, Manjaro & EndeavourOS

#### Option 1: Direct Native Package (Zero AUR Account Required)
Install the pre-built native package directly with `pacman`:
```bash
sudo pacman -U https://github.com/0x07dc/AirplaneGame/releases/download/v0.1.0/airplane-game-0.1.0-1-x86_64.pkg.tar.zst
```

#### Option 2: Build Locally via PKGBUILD
```bash
git clone https://github.com/0x07dc/AirplaneGame.git
cd AirplaneGame/dist/arch
makepkg -si
```

#### Option 3: Arch User Repository (AUR)
```bash
# Using yay (Stable Release)
yay -S airplane-game

# Or the cutting-edge Git development release:
yay -S airplane-game-git
```

---

### Fedora, RHEL & CentOS Stream (Flatpak / Flathub)

1. **Enable Flathub** (if not already enabled):
   ```bash
   flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
   ```
2. **Install the Game**:
   ```bash
   flatpak install flathub io.github._0x07dc.AirplaneGame
   ```
3. **Launch the Game**:
   ```bash
   flatpak run io.github._0x07dc.AirplaneGame
   ```
   *(Or launch "Airplane Combat Simulator" directly from your application launcher/GNOME Shell/KDE Plasma menu)*.

---

### Ubuntu, Debian, Linux Mint & Pop!_OS (Flatpak / Flathub)

1. **Install Flatpak support**:
   ```bash
   sudo apt update
   sudo apt install -y flatpak
   ```
2. **Add the Flathub repository**:
   ```bash
   flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
   ```
3. **Install and Run**:
   ```bash
   flatpak install flathub io.github._0x07dc.AirplaneGame
   flatpak run io.github._0x07dc.AirplaneGame
   ```

---

### openSUSE Tumbleweed & Leap (Flatpak / Flathub)

1. **Install Flatpak**:
   ```bash
   sudo zypper install flatpak
   ```
2. **Add Flathub**:
   ```bash
   flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
   ```
3. **Install and Run**:
   ```bash
   flatpak install flathub io.github._0x07dc.AirplaneGame
   flatpak run io.github._0x07dc.AirplaneGame
   ```

---

### Building Locally from Source (Any Distro)

#### Prerequisites
Install Zig (0.14.0 or newer; 0.16.0 recommended) and development headers:

```bash
# Arch / Manjaro
sudo pacman -S zig wayland vulkan-headers vulkan-icd-loader alsa-lib

# Fedora
sudo dnf install -y zig wayland-devel vulkan-loader-devel alsa-lib-devel

# Ubuntu / Debian
sudo apt install -y libwayland-dev libvulkan-dev libasound2-dev
# (Install Zig from https://ziglang.org/download/ or via snap: sudo snap install zig --classic --beta)
```

#### Compilation & Running
```bash
git clone https://github.com/0x07dc/AirplaneGame.git
cd AirplaneGame

# Build optimized binary
zig build -Doptimize=ReleaseFast

# Run the game!
./zig-out/bin/airplane_game

# Or install system-wide into /usr (FHS layout with icons and desktop entry):
sudo zig build -Doptimize=ReleaseFast -Duse-precompiled-shaders=true --prefix /usr
```

#### Local Flatpak Build
Test the Flatpak package locally using `flatpak-builder`:
```bash
flatpak-builder --user --install --force-clean build-dir dist/flatpak/io.github._0x07dc.AirplaneGame.local.yaml
flatpak run io.github._0x07dc.AirplaneGame
```

---

## Title Screen & Elevator Lounge Music

When launching the game, pilots are greeted by a custom-styled military title screen:

- **Custom 3D Fighter Emblem**: A 3D extruded stealth delta interceptor featuring gold leading edges, canopy glass diamond, canted vertical fins, glowing twin afterburners, and 3-tiered aviator wing feathers.
- **Runway Guidance Architecture**: Smoked-glass command plate framed with neon cyan corner brackets, 7-step vertical runway light ladders, centerline perspective stripes, and hazard markings.
- **Procedural Elevator Lounge Jazz**: An 8-measure real-time synthesizer progression (`Fmaj9 → Em7 → Dm9 → Cmaj9 → Fmaj9 → G7sus4 → Am9 → Gm7/C13sus`) that transitions seamlessly from menu relaxation to high-intensity combat.
- **Controls**: Use `W`/`S` or `↑`/`↓` to toggle `START GAME` and `QUIT GAME`; press `Enter` or `Space` to confirm.

---

## Combat Fleet Sizes, Match Limits & 15-Minute Timer

Every combat sortie is standardized around three balanced theater sizes:

| Fleet Size | Team Breakdown | Score Win Limit | Regulation Sortie Time |
| :---: | :---: | :---: | :---: |
| **8 COMBATANTS** | 4 Blue vs 4 Red | **50 Points** | **15:00 Minutes** |
| **16 COMBATANTS** | 8 Blue vs 8 Red | **100 Points** | **15:00 Minutes** |
| **32 COMBATANTS** | 16 Blue vs 16 Red | **200 Points** | **15:00 Minutes** |

- **Instant Action**: All slots start full with AI combatants.
- **Seamless Drop-In**: When a human player joins, an AI fighter on that team yields its slot immediately. An amber tactical HUD banner (`PLAYER JOINED: <CALLSIGN>`) and audio alert notify all pilots.
- **Game Over Scoreboard**: When a team hits the target score or the 15-minute timer expires, the match immediately enters the debriefing screen. Review your kills and team score, then press `Enter` to immediately relaunch into a fresh sortie.

---

## Flight Controls & Weapons Doctrine

### Primary Flight Controls

| Function | Primary Key | Secondary / Alternative | Tactical Purpose |
| :--- | :--- | :--- | :--- |
| **Pitch Down / Up** | `W` / `S` | `Up Arrow` / `Down Arrow` | Elevator control for attitude and climb/dive rate |
| **Roll Left / Right** | `A` / `D` | `Left Arrow` / `Right Arrow` | Aileron banking for high-G coordinated turns |
| **Rudder Yaw Left / Right**| `Q` / `E` | — | Crosswind landing alignment and gun fine-aiming |
| **Afterburner Boost** | **`LEFT SHIFT`** | — | Emergency military thrust; breaks supersonic barrier |
| **Air Brakes** | `SPACEBAR` | `LEFT CTRL` | Dorsal speed brakes for rapid deceleration |
| **20mm Vulcan Cannon** | **`ENTER`** | — | High-velocity rotary cannon with lead pursuit pipper |
| **Homing Missiles** | **`RIGHT SHIFT`** | — | AIM-9 Sidewinder infrared/radar guided missiles |
| **Heavy Demolition Bombs** | **`RIGHT CTRL`** | `C` | 500 lb aerial bomb with CCIP ground impact reticle |
| **Cockpit Optical Zoom** | `Z` | — | 3x magnification; declutters secondary HUD windows |
| **Transmission Gear** | `1` through `9` | — | Stepped velocity presets from 20 m/s up to 3,800 m/s |
| **Reverse Gear** | `0` | — | Ground carrier deck taxiing and emergency stopping |
| **Target Lock Cycle** | `T` / `TAB` | — | Cycles combat radar lock across airborne hostiles |
| **Carrier Autopilot** | **``` ` ```** (Backtick) | `H` | Toggles automated carrier landing, 5s repair & takeoff |
| **Emergency Recovery** | **`Y`** | — | Places plane on carrier craft for 15s to recover from glitches |
| **Cycle Network Lag** | **`L`** | — | Cycles simulated latency (0ms, 35ms, 85ms, 175ms, 320ms) |
| **Tactical Pause Menu** | **`ESC`** / `P` | — | Freezes flight in place; inspect airframe or access menus |

---

## Spherical Planetary Radar & BFM Tactical Guidance

Fighting around a spherical planet introduces true line-of-sight (LOS) mechanics:

1. **Direct Line-of-Sight (LOS)**: Local hostiles display cyan diamond tracking reticles with real-time range and closure rates.
2. **Horizon-Masked & Far-Side Threats**: When an enemy is behind the curvature of the earth, the HUD warns:
   - `TARGET ON FAR SIDE OF PLANET // NO DIRECT LOS`
   - `TARGET OVER HORIZON // TERRAIN MASKED`
3. **Curved Bezier Auto-Guidance (Key: `T`)**: Engaging Tactical Autopilot (`T`) calculates a 3D cubic Bezier curve tangentially around the globe's circumference, bringing you into an optimal stern-conversion dogfight intercept.
4. **Boresight Decluttering**: Peripheral radar ring arrows point towards off-screen and horizon-occluded hostiles, but automatically suppress when the target is right in front of your windshield to maintain a clean firing sightline.

---

## Naval Carrier Operations & Arrestor Deck Traps

Patrolling supercarriers act as mobile forward operating bases:

1. **Automated Carrier Autopilot Recovery (Key: ``` ` ``` or `H`)**:
   - Press **``` ` ```** (backtick) or **`H`** at any time to engage automated carrier recovery to the nearest friendly (Blue Team) supercarrier.
   - The autopilot navigates around the curvature of the planet at cruise altitude, decelerates along the glideslope centerline, touches down on the flight deck, rolls to an arrested stop, recharges hull health to **100% over 5 seconds**, and launches back off the bow via the EMALS catapult.
   - **Toggle Disengage**: Press **``` ` ```** or **`H`** again at any point to immediately disengage autopilot and restore manual stick flight control.
2. **Manual Stern Approach & Arrestor Trap**:
   - Line up on the carrier's wake along its forward heading vector.
   - Decelerate below **70 m/s** (`Gear 1` or speed brakes `SPACEBAR`).
   - Touch down on the flight deck. The arresting cable captures your tailhook, producing tire smoke and an audible cable trap snap.
3. **Automated Triage & Rearm**:
   - Velocity is safely arrested.
   - Hull integrity is restored to **100% HP** with visual nanite repair particles.
   - Vulcan cannon ammo, homing missiles, and bombs are reloaded to full capacity.
4. **Catapult Launch**: Engage **`LEFT SHIFT`** (Afterburner Boost) to launch off the carrier bow.
5. **Emergency Carrier Recovery (Key: `Y` // 15-Second Cooldown)**:
   - If caught in a glitch, stuck in terrain, or trapped in an anomaly, press **`Y`** to immediately place your aircraft onto the flight deck of the nearest friendly carrier craft for 15 seconds of emergency recovery and full hull recharge, followed by an automated catapult launch.
   - A live tactical countdown banner displays **`EMERGENCY RECOVERY: XX S`** on your HUD while docked on the craft, with a 15-second cooldown timer between uses.

---

## Multiplayer & LAN Direct Connect

Enjoy lag-free multiplayer over LAN or the internet with zero configuration.

### Option A: In-Game Direct Connect (LAN Party)
1. Launch `./zig-out/bin/airplane_game`.
2. From the Main Menu, select **`3. DIRECT CONNECT // LAN PARTY`**.
3. Pick your local subnet preset (`192.168.1.X`, `192.168.0.X`, `10.0.0.X`, or `127.0.0.1`).
4. Set the host IP octet with `Left` / `Right` and press **Enter** to connect!

### Option B: Command Line (CLI)
Host a game:
```bash
./zig-out/bin/airplane_game --host 7777 --ai 16
```
Connect to the host:
```bash
./zig-out/bin/airplane_game --connect 192.168.1.100:7777
```

---

## Automated Master Server

For internet play and automated lobby discovery, the engine integrates with an Automated Master Server service (`tools/master_server.py`).

Start the lightweight Python master service:
```bash
python3 tools/master_server.py --port 8080
```

- When hosting with `--host`, the game registers with the master server and sends periodic heartbeats.
- When opening the in-game **Multiplayer Lobby**, the engine dynamically queries the master server in the background, listing available hosts with real-time ping and player counts.

---

## Multiplayer Lag Simulator

Press **`L`** during flight to test netcode resilience under simulated adverse network conditions in real time:

- `NET: LAN [0ms Lag]`
- `NET: BROADBAND [35ms Lag]`
- `NET: DOMESTIC [85ms Lag]`
- `NET: CONTINENTAL [175ms Lag]`
- `NET: SATELLITE [320ms Lag / 6% Loss]`

The client-side Hermite interpolation buffer and dead-reckoning engine ensure smooth dogfighting even under high ping and packet loss.

---

## Performance Benchmarks & Stutter Analysis

The engine features a built-in automated 6-tier benchmarking and frame-timing telemetry harness (`--benchmark`, `--benchmark --uncapped`). Tested on an **Intel(R) UHD Graphics 620 (KBL GT2)** running native **Wayland** with Mesa Vulkan 1.3 on Linux, the engine demonstrates exceptional frame pacing and zero engine stutter.

### Mode A: Uncapped High-Throughput Triple-Buffering (`VK_PRESENT_MODE_MAILBOX_KHR`)

| Tier / Gameplay Scenario | Avg FPS | 1% Low | 0.1% Low | Avg Frame Time | Jitter ($\sigma$) | Stutter % (>16.7ms) | Draw Calls |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Tier 1: High-Altitude Ocean Cruise** | **158.6 FPS** | 95.8 FPS | 93.8 FPS | 6.31 ms | 1.21 ms | **0.0%** | 1,211 |
| **Tier 2: Naval Carrier Approach** | **145.6 FPS** | 94.9 FPS | 83.0 FPS | 6.87 ms | 0.99 ms | **0.0%** | 1,189 |
| **Tier 3: Downtown Metropolis Skyline** | **153.7 FPS** | 100.8 FPS | 85.0 FPS | 6.51 ms | 1.36 ms | **0.0%** | 1,413 |
| **Tier 4: 8-Player Squadron Dogfight** | **198.1 FPS** | 135.5 FPS | 88.6 FPS | 5.05 ms | 0.85 ms | **0.0%** | 1,436 |
| **Tier 5: 16-Player Fleet Strike Defense** | **189.3 FPS** | 135.3 FPS | 102.5 FPS | 5.28 ms | 0.81 ms | **0.0%** | 1,727 |
| **Tier 6: 32-Player Theater & Zeppelin** | **168.4 FPS** | 121.3 FPS | 116.4 FPS | 5.94 ms | 1.07 ms | **0.0%** | 1,980 |

### Mode B: Regulation 60 Hz VSync (`VK_PRESENT_MODE_FIFO_KHR`, 60 Hz Display)

| Tier / Gameplay Scenario | Avg FPS | 1% Low | 0.1% Low | Avg Frame Time | Jitter ($\sigma$) | Pure Work (CPU+GPU) | Compute Headroom |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Tier 1: High-Altitude Ocean Cruise** | **60.0 FPS** | 49.6 FPS | 49.1 FPS | 16.67 ms | 1.00 ms | 9.33 ms | **107 FPS** |
| **Tier 2: Naval Carrier Approach** | **60.0 FPS** | 51.2 FPS | 48.3 FPS | 16.66 ms | 1.00 ms | 9.50 ms | **105 FPS** |
| **Tier 3: Downtown Metropolis Skyline** | **60.0 FPS** | 50.0 FPS | 44.7 FPS | 16.65 ms | 1.05 ms | 9.72 ms | **103 FPS** |
| **Tier 4: 8-Player Squadron Dogfight** | **60.1 FPS** | 51.4 FPS | 45.2 FPS | 16.64 ms | 1.13 ms | 8.64 ms | **116 FPS** |
| **Tier 5: 16-Player Fleet Strike Defense** | **60.1 FPS** | 50.7 FPS | 47.9 FPS | 16.65 ms | 0.87 ms | 8.21 ms | **122 FPS** |
| **Tier 6: 32-Player Theater & Zeppelin** | **60.0 FPS** | 52.1 FPS | 48.1 FPS | 16.66 ms | 0.93 ms | 9.30 ms | **107 FPS** |

### Per-Frame Timing & Subsystem Breakdown

```
[ Tier 6: 32-Player Theater + Evil Zeppelin Boss // 1,980 Draw Calls ]
├─ CPU Flight & 32-Agent BFM AI Simulation:   2.31 ms  (39.5%)
├─ Vulkan Command Buffer Recording:          0.77 ms  (13.2%)
├─ Vulkan Queue Submit Overhead:             0.09 ms  ( 1.5%)
└─ GPU Hardware Execution & Fence Wait:      2.68 ms  (45.8%)
─────────────────────────────────────────────────────────────
Total Processing Latency per Frame:           5.85 ms  (100.0%)
Theoretical Unconstrained Framerate:          171.0 FPS
```

### Stuttering & Frame Pacing Assessment
- **Micro-Stutters ($>1.5\times$ rolling average)**: Under 0.5% in uncapped mode; **0.0%** in VSync mode.
- **Major Stutters ($>2.0\times$ rolling average)**: **0 across all 1,800 frames** in both VSync and uncapped modes.
- **Dropped Frames ($>16.67\text{ ms}$)**: **0.0%** in uncapped high-throughput mode.
- **Zero Garbage Collection Hitches**: Manual memory allocation and pre-allocated static ring buffers eliminate GC pauses, memory compaction spikes, and thread lock contention.

For the comprehensive technical methodology and complete telemetry report, see [BENCHMARKS.md](BENCHMARKS.md).

---

## CLI Reference & Automated Test Suites

### CLI Flag Reference
```text
USAGE:
  airplane_game [OPTIONS]

OPTIONS:
  -h, --help               Display this help text and exit
  -v, --version            Display version information and exit
  --no-audio               Run without sound (silent mode)
  --singleplayer, --sp     Launch directly into singleplayer combat sortie
  --ai, --players <8|16|32> Specify combat fleet size (8=4v4, 16=8v8, 32=16v16)
  --callsign, --name <NAME> Specify pilot callsign/screenname
  --spawn <carrier|city>   Specify spawn location (carrier deck or metropolis)
  --host [port]            Host multiplayer listen server (default: 7777)
  --connect <ip:port>      Connect directly to multiplayer server
  --master <ip:port>       Automated master server address (default: 127.0.0.1:8080)
  --test-net               Run automated multiplayer latency & impairment test suite
  --lag <ms>               Simulate network latency in milliseconds
  --jitter <ms>            Simulate network latency variance/jitter in milliseconds
  --loss <pct>             Simulate network packet loss percentage (0..100)
  --showcase               Run automated visual showcase benchmark & verification
  --benchmark              Run automated 6-tier gameplay performance & stutter benchmark
  --uncapped               Enable uncapped mailbox/immediate presentation mode
```

### Automated Testing & Benchmarks
```bash
# Automated 6-tier gameplay performance & stutter benchmark:
./zig-out/bin/airplane_game --benchmark

# Uncapped high-throughput benchmark:
./zig-out/bin/airplane_game --benchmark --uncapped

# Network protocol, dead reckoning, and lag simulator verification:
zig test src/net.zig

# Flight envelope, aerodynamics, and ground avoidance verification:
zig test src/flight.zig

# Headless loopback stress test across 4 network impairment profiles:
./zig-out/bin/airplane_game --test-net

# Master server integration test suite:
python3 tools/test_master_integration.py
```

---

## License

This project is open-source software licensed under the [MIT License](LICENSE).
Copyright © 2026 0x07dc. All rights reserved.
