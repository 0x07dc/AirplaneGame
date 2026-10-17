# AIRPLANE COMBAT SIMULATOR // ENGINEERING SPECIFICATION (SPEC.md)

**Document Version**: 1.0.0  
**Target Platform**: Linux (Wayland, Vulkan 1.3, ALSA)  
**Implementation Language**: Pure Zig (0.16.0-dev / 0.14.0+)  
**Application Identifier**: `io.github._0x07dc.AirplaneGame`  
**License**: MIT License  

---

## 1. Executive Summary & Design Tenets

**Airplane Combat Simulator** is a high-performance, military-grade 3D tactical flight simulator and dogfighting game built from the bare metal up without third-party game engines or middleware frameworks.

### Core Architectural Principles:
1. **Zero External Runtime Dependencies**: Outside standard Linux system ABIs (`libc`, `libwayland-client`, `libvulkan`, `libasound`), the engine contains no third-party libraries. All vector mathematics, font rasterization, 3D mesh building, networking, audio synthesis, and flight physics are implemented directly in Zig.
2. **Deterministic Data-Oriented Design (DOD)**: Memory layout favors flat struct arrays (`MultiArrayList` and contiguous slices) for cache locality. Cache line misses are minimized across 60 Hz simulation updates.
3. **Strict Memory Safety & Explicit Allocation**: Dynamic allocations use explicit `std.mem.Allocator` passing. Frame-transient data relies on fast `ArenaAllocator` regions reset between render cycles. There are zero garbage collection pauses.
4. **Asynchronous Non-Blocking Execution**: Audio synthesis runs on an isolated high-priority POSIX thread. Network packet dispatching operates via non-blocking UDP sockets (`SOCK_DGRAM | SOCK_NONBLOCK`). Master server queries execute via background worker threads.

---

## 2. Architecture & Module Decomposition

```
AirplaneGame/
├── build.zig                     # Zig build script (Vulkan, Wayland, ALSA, desktop integration)
├── src/
│   ├── main.zig                  # Entrypoint, main loop, screen state machine, HUD orchestration
│   ├── gfx.zig                   # Vulkan 1.3 rendering pipeline, swapchain, depth buffer, readback
│   ├── window.zig                # Native Wayland client (xdg-shell, zxdg-decoration-v1, evdev)
│   ├── flight.zig                # 6-DoF aerodynamic flight physics, gearing, carrier trap hook
│   ├── planet.zig                # Spherical planetary model, cities, traffic, clouds, fleet
│   ├── mesh.zig                  # Procedural 3D mesh generation (jets, carriers, buildings, HUD)
│   ├── font_data.zig             # Vector typography definition and 3D character extrusion
│   ├── audio.zig                 # Multi-threaded ALSA real-time procedural sound synthesizer
│   ├── net.zig                   # UDP multiplayer protocol, Hermite interpolation, lag simulator
│   ├── ai.zig                    # BFM combat AI, formation logic, carrier landing circuits
│   ├── math.zig                  # Vector3, Matrix4x4, Quaternion, and spherical trigonometric math
│   └── c/
│       ├── c.h                   # C headers import wrapper
│       ├── xdg-shell-protocol.c  # Wayland xdg-shell protocol implementation
│       └── xdg-decoration-protocol.c # Wayland server-side decoration protocol
├── shaders/
│   ├── mesh.vert                 # Vulkan 1.3 GLSL vertex shader (MVP transform, lighting)
│   └── mesh.frag                 # Vulkan 1.3 GLSL fragment shader (directional + ambient shading)
├── dist/
│   ├── common/                   # FreeDesktop metadata (.desktop, .metainfo.xml, hicolor icons)
│   ├── arch/                     # Arch Linux AUR package specs (PKGBUILD, PKGBUILD.git, .SRCINFO)
│   └── flatpak/                  # Flathub Flatpak packaging manifests (YAML and JSON)
└── tools/
    ├── master_server.py          # Standalone Python HTTP master server & REST registry
    └── test_master_integration.py# Master server validation test suite
```

---

## 3. Vulkan 1.3 Graphics Subsystem Specification (`src/gfx.zig`)

### 3.1 Device & Instance Management
- **Vulkan API Version**: `VK_API_VERSION_1_3`.
- **Instance Extensions**:
  - `VK_KHR_surface`
  - `VK_KHR_wayland_surface`
- **Device Selection Criteria**:
  - Discrete GPU preferred over integrated; fallback to integrated GPU (`VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`).
  - Graphics and presentation queue family sharing single index where available.
- **Device Extensions**:
  - `VK_KHR_swapchain`

### 3.2 Swapchain & Surface Presentation
- **Format**: `VK_FORMAT_B8G8R8A8_SRGB` (fallback: `VK_FORMAT_B8G8R8A8_UNORM`).
- **Color Space**: `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`.
- **Present Mode**: `VK_PRESENT_MODE_FIFO_KHR` (hard vsync lock) with fallback to `VK_PRESENT_MODE_MAILBOX_KHR` (triple buffering) or `VK_PRESENT_MODE_IMMEDIATE_KHR`.
- **Image Count**: 3 swapchain images (triple buffering).

### 3.3 Depth Buffering & Render Pass
- **Depth Format**: `VK_FORMAT_D32_SFLOAT` (fallback: `VK_FORMAT_D32_SFLOAT_S8_UINT` or `VK_FORMAT_D24_UNORM_S8_UINT`).
- **Depth Test**: `VK_COMPARE_OP_LESS_OR_EQUAL`.
- **Depth Write**: Enabled for opaque 3D world geometry; disabled for 2D/3D HUD overlays to prevent self-clipping.

### 3.4 Pipeline State & Dynamic States
- **Dynamic States**: `VK_DYNAMIC_STATE_VIEWPORT`, `VK_DYNAMIC_STATE_SCISSOR`.
- **Cull Mode**: `VK_CULL_MODE_BACK_BIT` for solid geometry, `VK_CULL_MODE_NONE` for double-sided HUD vector elements.
- **Front Face**: `VK_FRONT_FACE_COUNTER_CLOCKWISE`.

### 3.5 Shaders & Push Constants
- **Vertex Format**:
  - `location = 0`: `inPosition: vec3` (Float32x3, offset 0)
  - `location = 1`: `inColor: vec4` (Float32x4, offset 12)
  - `location = 2`: `inNormal: vec3` (Float32x3, offset 28)
  - **Stride**: 40 bytes per vertex.
- **Push Constant Layout** (Stage: `VK_SHADER_STAGE_VERTEX_BIT`):
  ```glsl
  layout(push_constant) uniform PushConstants {
      mat4 mvp;         // 64 bytes: Model-View-Projection matrix
      vec4 light_dir;   // 16 bytes: Directional sun vector (xyz) + ambient intensity (w)
      vec4 cam_pos;     // 16 bytes: Camera world position (xyz) + time/fog parameter (w)
  } pc;
  ```

### 3.6 Offscreen Framebuffer Readback (`--showcase`)
- **Format**: Host-visible staging buffer with linear tiling (`VK_IMAGE_TILING_LINEAR`).
- **Blit Operation**: `vkCmdCopyImageToBuffer` converts optimal tiled swapchain image to linear RGB staging memory.
- **Output**: Writes uncompressed PPM (`P6`) images at 1280x720 resolution to disk.

---

## 4. Wayland Native Windowing Specification (`src/window.zig`)

### 4.1 Protocols Implemented
- **Core Protocol**: `wl_compositor`, `wl_shm`, `wl_seat`, `wl_surface`.
- **Window Management**: `xdg_wm_base`, `xdg_surface`, `xdg_toplevel`.
- **Decorations**: `zxdg_decoration_manager_v1`, `zxdg_toplevel_decoration_v1`.
  - Sets mode to `ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE` to utilize native desktop titlebars and shadows.

### 4.2 Event Loop & Input Architecture
- **Dispatch**: Direct non-blocking calls to `wl_display_dispatch_pending()` combined with socket polling on `wl_display_get_fd()`.
- **Keyboard Handling**:
  - Linux evdev keycode mapping (e.g., `KEY_W`, `KEY_S`, `KEY_A`, `KEY_D`, `KEY_LEFTSHIFT`, `KEY_SPACE`, `KEY_ENTER`, `KEY_ESC`).
  - Bitfield state tracking for simultaneous multiple keypresses (supports chords like Pitch Up + Roll Right + Gun Fire + Afterburner).
- **Graceful Termination**: Intercepts `xdg_toplevel.close` and `wl_display_dispatch` failure to execute atomic resource deallocation.

---

## 5. Flight Dynamics & Aerodynamics Model Specification (`src/flight.zig`)

### 5.1 Coordinate Frame
- Right-handed Cartesian coordinates in planetary tangent space.
- Forward: $+Z$ (Boresight)
- Right: $+X$ (Starboard Wing)
- Up: $+Y$ (Dorsal Canopy)

### 5.2 Equations of Motion (6-DoF)
The simulation integrates rigid-body Newtonian mechanics at 60 Hz ($\Delta t = 1/60$s):
$$\vec{v}_{t+\Delta t} = \vec{v}_t + \frac{\vec{F}_{\text{total}}}{m} \Delta t$$
$$\vec{p}_{t+\Delta t} = \vec{p}_t + \vec{v}_{t+\Delta t} \Delta t$$

Total force breakdown:
$$\vec{F}_{\text{total}} = \vec{F}_{\text{thrust}} + \vec{F}_{\text{lift}} + \vec{F}_{\text{drag}} + \vec{F}_{\text{gravity}}$$

### 5.3 Aerodynamic Parameters
1. **Lift**:
   $$L = \frac{1}{2} \rho v^2 S C_L(\alpha)$$
   Where $C_L(\alpha) = 2 \pi \alpha$ before stall angle $\alpha_{\text{stall}} = 18^\circ$. Post-stall lift decays exponentially with flow separation.
2. **Parasitic & Induced Drag**:
   $$D = \frac{1}{2} \rho v^2 S \left( C_{D0} + \frac{C_L^2}{\pi e AR} \right)$$
   Where $C_{D0} = 0.021$ (clean configuration), $AR = 2.45$ (low aspect delta wing).
3. **Transmission Gearbox & Thrust**:
   - 9 forward stepped speed governor settings:
     - Gear 1: $50\text{ m/s}$ ($180\text{ km/h}$ - carrier landing approach)
     - Gear 2: $150\text{ m/s}$ ($540\text{ km/h}$ - dogfighting maneuvering speed)
     - Gear 3: $340\text{ m/s}$ ($1,224\text{ km/h}$ - Mach 1.0 sound barrier)
     - Gear 4: $680\text{ m/s}$ (Mach 2.0)
     - Gear 5: $1,200\text{ m/s}$ (Mach 3.5)
     - Gear 6: $1,800\text{ m/s}$ (Mach 5.3 - hypersonic threshold)
     - Gear 7: $2,400\text{ m/s}$ (Mach 7.0)
     - Gear 8: $3,100\text{ m/s}$ (Mach 9.1)
     - Gear 9: $3,800\text{ m/s}$ (Mach 11.2 - suborbital sprint)
   - **Emergency Afterburner Boost (`LEFT SHIFT`)**: Immediately multiplies engine thrust output by $2.5\times$, applying forward supersonic acceleration.
   - **Air Brakes (`SPACEBAR` / `LEFT CTRL`)**: Deploys dorsal speed brake tiles, multiplying drag $C_{D0}$ by $4.0\times$ for rapid deceleration.

### 5.4 High-G Handling, Knife-Edge & Inverted Stability
- **90-Degree Knife-Edge Flight**: Zero deadzones in roll coordinate transforms. Rudder aerodynamic authority retains sideforce generation allowing continuous horizontal flight at $\phi = 90^\circ$.
- **180-Degree Inverted Flight**: Full pitch elevator authority preserved while flying upside down.
- **Subtle Planetary Gravity Bias**: Applies a gentle corrective leveling moment toward the local planetary gravity vector with an exponential damping factor ($\tau = 4.5$s), preserving aerobatic agility while preventing spatial disorientation during long transit flights.

### 5.5 Ground Proximity Warning System (GPWS) & Fly-By-Wire Collision Avoidance
- Continuously projects aircraft velocity vector down to local spherical terrain mesh.
- If predicted time-to-impact $t_{\text{impact}} < 1.8$s, the fly-by-wire flight control computer overrides pilot stick inputs:
  - Automatically wings-level the aircraft ($\phi \to 0$).
  - Smoothly commands maximum positive pitch $+G$ climb until terrain clearance $> 150\text{ m}$ AGL.

### 5.6 Aircraft Carrier Arrestor Trap Dynamics & Automated Recovery
- **Manual Trap Envelope**:
  - Horizontal capture window: $X \in [-18\text{ m}, +18\text{ m}]$ across flight deck centerline.
  - Vertical touchdown zone: $Y \in [0\text{ m}, 3.5\text{ m}]$ above deck surface.
  - Speed limit: $v \le 70\text{ m/s}$ ($252\text{ km/h}$).
  - Approach angle: Within $\pm 25^\circ$ of carrier longitudinal heading vector.
- **Arresting Deceleration**:
  - When hook engages cable, an elastic spring-damper deceleration profile is applied:
    $$a_{\text{cable}} = -k_{\text{cable}} (p - p_0) - c_{\text{cable}} v$$
  - Velocity arrests to zero within $1.45$ seconds ($45\text{ m}$ rollout).
  - Triggers tire smoke particles, ALSA cable snap acoustic event, and initiates instant hull triage (100% HP) and weapons reload.
- **Carrier Autopilot Recovery Sequence (Keys: ``` ` ``` / `H`)**:
  - **Spherical Approach Guidance**: Calculates great-circle tangent trajectory around planet curvature towards the glideslope entry corridor (1200m astern at 180m elevation), automatically decelerating from supersonic transit down to approach velocity.
  - **Touchdown & Arrest**: Smoothly aligns with the longitudinal flight deck centerline and engages arresting cables upon deck capture (with a 12-second failsafe approach timer).
  - **Health Recharge**: Restores hull integrity to **100% HP over a 5.0-second recharge duration** with visible repair nanite particles.
  - **Catapult Launch**: Discharges steam/EMALS catapult off the carrier bow, accelerating to full cruise speed with a +16° climb-out before restoring free flight.
  - **Autopilot Toggle**: Pressing **``` ` ```** or **`H`** while autopilot is active immediately cancels autopilot and returns full stick control to the pilot.
- **Emergency Respawn (Key: `R` // 15-Second Cooldown)**:
  - Instantaneous deployment at the nearest friendly aircraft carrier with restored health and manual flight controls.
  - Governed by a **15-second cooldown timer** (`respawn_cooldown`), providing a reliable glitch/anomaly escape mechanism while preventing combat exploitation.

---

## 6. Planetary Simulation & World Generation Specification (`src/planet.zig`)

### 6.1 Spherical Topology
- **Planetary Radius**: $R_{\text{planet}} = 6,371,000\text{ m}$ (represented in normalized engine simulation units).
- **Surface Elevation**: Multi-octave simplex/Perlin noise generator producing continental landmasses, mountain chains, and ocean basins.
- **Coordinate Conversion**:
  $$\vec{P}(r, \theta, \phi) = \begin{bmatrix} r \cos \theta \sin \phi \\ r \sin \theta \\ r \cos \theta \cos \phi \end{bmatrix}$$
  Where $\theta$ is latitude, $\phi$ is longitude, and $r = R_{\text{planet}} + h_{\text{elevation}}$.

### 6.2 Horizon Masking & Line-of-Sight (LOS)
Line-of-sight between two aircraft $\vec{P}_1$ and $\vec{P}_2$ is calculated by determining whether the line segment intersects the planetary sphere:
1. Direction vector: $\vec{D} = \frac{\vec{P}_2 - \vec{P}_1}{\|\vec{P}_2 - \vec{P}_1\|}$.
2. Closest distance from planet center to ray:
   $$d_{\text{min}} = \|\vec{P}_1 - (\vec{P}_1 \cdot \vec{D}) \vec{D}\|$$
3. If $d_{\text{min}} < R_{\text{planet}}$ and the projection point lies between $\vec{P}_1$ and $\vec{P}_2$, direct line-of-sight is blocked by the planet.
   - HUD classifies target as `HORIZON MASKED` or `FAR SIDE OF PLANET`.

### 6.3 Procedural Metropolitan Cities
- **Total Cities**: 22 geographically distinct urban centers.
- **Urban Grid Topology**:
  - Over 5,000 generated street corridors.
  - Skyscraper clusters with procedural floor counts (30m to 350m height).
  - Night-time window emissive lighting shaders.
- **Civilian Vehicle Simulation**:
  - 572 autonomous ground vehicles traversing street spline networks.
  - Car turn signals, braking behavior, and lane tracking.
- **Pedestrian Simulation**:
  - 880 pedestrian agents wandering sidewalk perimeters.

### 6.4 Naval Fleet & Floating Assets
- **16 Team Aircraft Carriers**: Positioned along ocean sectors, featuring active runway lighting, tower island superstructure, and arrestor gear.
- **Destroyers & Cruisers**: Flanking carrier strike groups with automated anti-air missile defense zones.
- **Evil Zeppelin Boss**: High-altitude dreadnought airship (altitude 2,500m MSL) with 4 rotatable anti-air flak turrets and a massive health bar.

---

## 7. Combat Avionics, Weapons & Fire Control Specification (`src/mesh.zig`, `src/font_data.zig`)

### 7.1 Lead-Computing Optical Sight (LCOS)
The HUD calculates the ballistic lead intercept point for the 20mm Vulcan rotary cannon:
1. Relative position: $\vec{R} = \vec{P}_{\text{target}} - \vec{P}_{\text{shooter}}$.
2. Target relative velocity: $\vec{V}_{\text{rel}} = \vec{V}_{\text{target}} - \vec{V}_{\text{shooter}}$.
3. Muzzle velocity: $V_{\text{bullet}} = 1,050\text{ m/s}$.
4. Time of flight approximation:
   $$t_{\text{tof}} \approx \frac{\|\vec{R}\|}{V_{\text{bullet}}}$$
5. Predicted lead pipper position:
   $$\vec{P}_{\text{pip}} = \vec{P}_{\text{target}} + \vec{V}_{\text{rel}} t_{\text{tof}} + \frac{1}{2} \vec{g} t_{\text{tof}}^2$$
6. Projected onto pilot HUD screen space; represented by an illuminated circular reticle with crosshairs and dynamic range tick.

### 7.2 Weapons Systems
1. **20mm M61 Vulcan Autocannon**:
   - Cyclic rate: 6,000 rounds/minute (100 rounds/sec).
   - Projectile damage: 12 HP per impact.
   - Ballistic gravity drop and aerodynamic drag decay.
2. **AIM-9 Sidewinder Air-to-Air Missile**:
   - Guidance Law: True Proportional Navigation (PN):
     $$\vec{a}_{\text{cmd}} = N \cdot V_c \cdot \dot{\vec{\lambda}}$$
     Where $N = 4.0$ (navigation gain), $V_c$ is closure velocity, and $\dot{\vec{\lambda}}$ is line-of-sight angular rate.
   - Seeker FOV: $\pm 35^\circ$ off boresight.
   - Motor burn time: 4.5 seconds; coast phase: 6.0 seconds.
   - Proximity fuse: Detonates within 12 meters of target, dealing up to 75 HP area-of-effect damage.
3. **Mk 82 500 lb Aerial Demolition Bomb**:
   - Ballistic parabolic release.
   - Continuously Computed Impact Point (CCIP): Continuously integrates gravity and forward momentum against the terrain elevation surface, drawing an impact cross on the ground.
   - Blast radius: 65 meters; destroys ground vehicles, anti-air flak batteries, and damages the high-altitude Zeppelin.

### 7.3 HUD Target Indicator Decluttering
- **Peripheral Radar Ring Arrow**:
  - Clamped to screen boundary circle ($r = 0.88$).
  - Color-coded: Cyan (direct LOS), Amber (horizon-masked), Magenta (far-side antipodal).
- **Forward Boresight Declutter Filter**:
  - When target enters the central windshield forward field-of-view ($\theta < 15^\circ$), the peripheral edge arrow is automatically suppressed.
  - Only the 3D in-world tracking diamond, range bracket, and lead pipper are drawn, providing an unobstructed sight picture.

---

## 8. Squadron AI & Basic Fighter Maneuvers (BFM) Specification (`src/ai.zig`)

### 8.1 Combatant Fleet Standardization
Every game mode standardizes strictly on three balanced fleet capacities:
- **8 Combatants**: 4 Blue vs 4 Red (Squadron Skirmish)
- **16 Combatants**: 8 Blue vs 8 Red (Fleet Strike Defense)
- **32 Combatants**: 16 Blue vs 16 Red (Theater Air Superiority)

### 8.2 Dynamic AI Backfill & Slot Replacement
- **Initialization**: At match start, all 8, 16, or 32 slots are populated by autonomous AI fighters.
- **Human Connection**: When a human player joins (local host or network peer):
  1. The engine scans the matching team array.
  2. Selects an active AI combatant.
  3. Decommissions the AI entity and transfers the combat slot to the human pilot.
  4. Triggers an amber tactical HUD banner (`PLAYER JOINED: <CALLSIGN>`) and audio chime.
- **Human Disconnection**: If a human leaves, the engine seamlessly spawns an AI replacement to maintain 50/50 team balance.

### 8.3 Tactical AI State Machine
Each AI pilot executes a 60 Hz BFM state machine:
```
[PATROL / CRUISE]
       │
       ▼ (Hostile Detected in Radar Envelope)
[BVR STERN INTERCEPT]
       │
       ▼ (Range < 1,500m)
[GUN ATTACK RUN] ──(Target Overshoots)──► [HIGH YO-YO]
       │                                       │
       ▼ (Defensive / Missiles Incoming)       ▼
[BREAK TURN / SCISSORS] ◄──────────────────────┘
       │
       ▼ (Low Fuel / Damaged)
[CARRIER RETURN & TRAP]
```

---

## 9. Real-Time Procedural Audio Synthesizer Specification (`src/audio.zig`)

### 9.1 ALSA Audio Thread Architecture
- **API**: Linux Advanced Linux Sound Architecture (ALSA) PCM interface (`snd_pcm_open`, `snd_pcm_writei`).
- **Device**: `default` (fallback to `plughw:0,0`).
- **Sample Rate**: 44,100 Hz.
- **Channels**: 2 (Stereo Interleaved).
- **Format**: `SND_PCM_FORMAT_S16_LE` (16-bit Signed Little-Endian).
- **Buffer Parameters**:
  - Period size: 256 frames (5.8 ms audio latency).
  - Buffer size: 1,024 frames (4 periods).
- **Thread Concurrency**: Spawns a dedicated POSIX thread (`std.Thread.spawn`) with an atomic ring buffer.

### 9.2 Sound Generation Algorithms
1. **Jet Engine Whine**: Additive phase accumulator synthesizing high-frequency turbine blades ($f_0 \approx 800\text{ Hz} \dots 4,200\text{ Hz}$ modulated by throttle gear).
2. **Supersonic Afterburner**: Multi-stage pink noise generator passed through a 2-pole resonant low-pass filter with random amplitude jitter.
3. **20mm Rotary Cannon**: 100 Hz pulse train triggering damped 450 Hz metallic sine bursts mixed with high-passed explosive noise bursts.
4. **Missile Rocket Thruster**: Dual band-pass white noise with pitch-swept solid-fuel resonance.
5. **Carrier Arrestor Cable Snap**: High-tension metallic impact transient (1,800 Hz) with exponential decay and high-frequency friction screech.

### 9.3 Procedural Elevator Lounge Music Synthesizer
Synthesized entirely in mathematical real-time:
- **Tempo**: 114 BPM (0.526s per beat).
- **Structure**: 8 measures (32 beats per full harmonic cycle).
- **Harmonic Progression**:
  - Measures 1-2: `Fmaj9` ($F - A - C - E - G$)
  - Measure 3: `Em7` ($E - G - B - D$)
  - Measure 4: `Dm9` ($D - F - A - C - E$)
  - Measure 5: `Cmaj9` ($C - E - G - B - D$)
  - Measure 6: `Fmaj9` ($F - A - C - E - G$)
  - Measure 7: `G7sus4` ($G - C - D - F$)
  - Measure 8: `Am9` ($A - C - E - G - B$) transitioning through `Gm7 / C13sus` turnaround.
- **Instruments**:
  - **Rhodes Electric Piano**: Dual sine operators ($f_0 + 2.0 f_0$ crystal harmonic) with smooth exponential decay and 4.5 Hz stereo tremolo modulation.
  - **Walking Upright Bass**: Low-end sine oscillator with 2nd harmonic saturation, walking root-fifth-passing note walking basslines.
  - **Bossa Percussion**: Synthesized deep 55 Hz low kick on beats 1 & 2.5, crisp rimshot snaps on beats 2 & 4, and filtered 8th-note shaker hi-hats.
  - **Lyrical Flight Lead**: Soaring vibraphone/flute melody with 5.2 Hz vibrato.
- **Crossfader**: Smooth exponential crossfader fades music to silent during flight combat and mutes the jet engine on menu screens.

---

## 10. Non-Blocking UDP Networking & Replication Specification (`src/net.zig`)

### 10.1 Transport Layer
- **Socket Type**: Non-blocking UDP (`SOCK_DGRAM | SOCK_NONBLOCK`).
- **Default Port**: `7777`.
- **Packet Rate**: 60 Hz bidirectional tick rate.

### 10.2 Packet Wire Protocol
All datagrams begin with an 8-byte unified protocol header:
```rust
#[repr(C, packed)]
struct PacketHeader {
    magic: u32,        // 0x41435331 ("ACS1")
    seq: u16,          // Monotonically increasing sequence number
    packet_type: u8,   // Packet opcode
    flags: u8,         // Bitfield flags (e.g. ACK, IMPAIRMENT, CHECKSUM)
}
```

#### Packet Opcodes:
| Opcode | Identifier | Direction | Description |
| :---: | :--- | :---: | :--- |
| `0x01` | `CONNECT_REQ` | Client $\to$ Host | Handshake request with client callsign and protocol version |
| `0x02` | `CONNECT_ACK` | Host $\to$ Client | Acceptance containing assigned client slot ID and match configuration |
| `0x03` | `STATE_UPDATE` | Bidirectional | 60 Hz transform state (position, orientation, velocity, inputs) |
| `0x04` | `WEAPON_FIRE` | Bidirectional | Weapon discharge event (cannon, missile, bomb) |
| `0x05` | `DAMAGE_EVENT`| Bidirectional | Damage allocation, hit confirmation, health update |
| `0x06` | `MATCH_STATE` | Host $\to$ Client | 15-minute timer synchronization, team scores, game over status |
| `0x07` | `HEARTBEAT`   | Bidirectional | Keepalive ping/pong measuring round-trip time (RTT) |
| `0x08` | `DISCONNECT`  | Bidirectional | Clean session termination |

### 10.3 Entity Interpolation & Dead Reckoning
To mask latency and packet jitter, clients maintain a 100 ms historical state snapshot buffer:
- **Hermite Cubic Spline Interpolation**: Smoothly blends between known state snapshots $S_{t-1}$ and $S_t$.
- **Dead Reckoning Extrapolation**: If packets are delayed or dropped:
  $$\vec{P}_{\text{extrap}} = \vec{P}_{\text{last}} + \vec{V}_{\text{last}} \Delta t + \frac{1}{2} \vec{a} \Delta t^2$$
  Supported up to 500 ms before entering safety hover/despawn.

### 10.4 Network Impairment Simulator
In-engine real-time lag simulation engine (cycled via `L` key):
- **Jitter Ring Buffer**: Delays packets dynamically with Gaussian variance.
- **Packet Drop Filter**: Drops outgoing/incoming packets based on pseudo-random probability threshold.
- **Profiles**:
  1. `LAN`: $0\text{ ms}$ lag, $0\text{ ms}$ jitter, $0.0\%$ loss.
  2. `BROADBAND`: $35\text{ ms}$ lag, $3\text{ ms}$ jitter, $0.0\%$ loss.
  3. `DOMESTIC`: $85\text{ ms}$ lag, $8\text{ ms}$ jitter, $0.0\%$ loss.
  4. `CONTINENTAL`: $175\text{ ms}$ lag, $15\text{ ms}$ jitter, $0.0\%$ loss.
  5. `SATELLITE`: $320\text{ ms}$ lag, $35\text{ ms}$ jitter, $6.0\%$ loss.

### 10.5 Regulation Match Synchronization
- **Sortie Duration**: 15 minutes ($900.0$ seconds).
- **Score Limits**:
  - 8 Players: Race to **50 points**
  - 16 Players: Race to **100 points**
  - 32 Players: Race to **200 points**
- **Match Termination**: Match halts immediately when either team hits the target score or when the 15-minute clock reaches zero. Transitions all participants into the holographic Game Over debriefing state.

---

## 11. UI State Machine & Vector Font Engine Specification

### 11.1 Screen State Machine
The top-level application loop transitions through strict states:
```
                ┌──────────────────────────────────────┐
                │             TITLE_SCREEN             │
                └──────────────────┬───────────────────┘
                                   │ (START GAME)
                                   ▼
                ┌──────────────────────────────────────┐
                │           CHOOSE_CALLSIGN            │
                └──────────────────┬───────────────────┘
                                   │ (CONFIRM CALLSIGN)
                                   ▼
                ┌──────────────────────────────────────┐
                │              MAIN_MENU               │
                └───┬──────────────┬────────────────┬──┘
                    │              │                │
            (1. SP) │      (2. MP) │        (3. LAN)│
                    ▼              ▼                ▼
             ┌───────────┐  ┌──────────────┐  ┌──────────────┐
             │ SP_SETUP  │  │   MP_LOBBY   │  │DIRECT_CONNECT│
             └─────┬─────┘  └──────┬───────┘  └──────┬───────┘
                   │               │                 │
                   └───────────────┼─────────────────┘
                                   │ (LAUNCH SORTIE)
                                   ▼
                ┌──────────────────────────────────────┐
                │               IN_GAME                │
                └──────┬────────────────────────┬──────┘
                       │ (PAUSE / ESC)          │ (SCORE / TIME REACHED)
                       ▼                        ▼
                ┌─────────────┐          ┌─────────────┐
                │   PAUSED    │          │  GAME_OVER  │
                └─────────────┘          └─────────────┘
```

### 11.2 3D Vector Typography Engine (`src/font_data.zig`, `src/mesh.zig`)
- **Glyph Definition**: Resolution-independent vector stroke definitions for ASCII characters `32` through `126`.
- **Extrusion Pipeline**: Converts 2D font lines into 3D triangular prisms with configurable depth, beveling, and face/edge coloring.
- **Rendering Performance**: Pre-batched into static or transient vertex buffers, rendering entire paragraphs and HUD telemetry strings in a single Vulkan draw call.

---

## 12. Linux Packaging & Distribution Standards

### 12.1 Flathub Flatpak Specification
- **Application ID**: `io.github._0x07dc.AirplaneGame`
  - *Note on D-Bus specification compliance*: D-Bus forbids bus name components that begin with a digit (`0-9`). Because GitHub username `0x07dc` begins with a digit, FreeDesktop and Flatpak standards mandate prefixing with an underscore (`_0x07dc`).
- **Runtime**: `org.freedesktop.Platform 24.08`
- **SDK**: `org.freedesktop.Sdk 24.08`
- **SDK Extension**: `org.freedesktop.Sdk.Extension.zig` (pinned to Zig 0.14/0.16)
- **Sandbox Holes / Permissions**:
  - `--socket=wayland`: Native Wayland display access.
  - `--socket=pulseaudio`: ALSA/PulseAudio sound server pipe.
  - `--device=dri`: Direct Rendering Infrastructure (Vulkan hardware acceleration).
  - `--share=network`: UDP multiplayer socket communication.

### 12.2 Arch Linux (AUR) Specification
- **Package Names**: `airplane-game` (stable release), `airplane-game-git` (VCS master branch).
- **Build Tool**: Native `zig build -Doptimize=ReleaseFast -Duse-precompiled-shaders=true --prefix "$pkgdir/usr"`.
- **FHS Integration**:
  - Binary: `/usr/bin/airplane_game`
  - Desktop Entry: `/usr/share/applications/io.github._0x07dc.AirplaneGame.desktop`
  - AppStream Metainfo: `/usr/share/metainfo/io.github._0x07dc.AirplaneGame.metainfo.xml`
  - Icons: `/usr/share/icons/hicolor/{64x64,128x128,256x256,512x512,scalable}/apps/`

### 12.3 Automated Test & Verification Matrix
Every build must pass the following headless verification test suite before distribution:
```bash
# 1. Aerodynamic physics and flight envelope verification:
zig test src/flight.zig

# 2. Network protocol, packet serialization, and dead reckoning verification:
zig test src/net.zig

# 3. Headless 4-profile network lag impairment loopback stress test:
./zig-out/bin/airplane_game --test-net

# 4. Master server REST endpoint and keepalive validation:
python3 tools/test_master_integration.py

# 5. Automated 6-tier gameplay performance & stutter benchmark:
./zig-out/bin/airplane_game --benchmark

# 6. Uncapped high-throughput benchmark:
./zig-out/bin/airplane_game --benchmark --uncapped

# 7. AppStream metadata compliance:
appstreamcli validate --no-net dist/common/io.github._0x07dc.AirplaneGame.metainfo.xml

# 8. Desktop file validation:
desktop-file-validate dist/common/io.github._0x07dc.AirplaneGame.desktop
```

---

*Airplane Combat Simulator Engineering Specification — Maintained by 0x07dc.*
