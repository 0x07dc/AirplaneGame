# Planet & Network Encoding

## Procedural spherical planet

- **Parameterization**: cube-sphere (6 quadtree faces) → chunked LOD terrain.
  Each chunk = N×N grid, vertices displaced along the normal by
  `height(dir, seed)` (fBm simplex noise evaluated on the unit direction, so
  it's seamless).
- **Origin precision**: positions are `f64` (planet-cen0ad 0.28.0-3tered) on CPU;
  rendering is camera-relative `f32`. Planet radius ~ 50–200 km to start
  (tunable; crossing-time vs. plane speed is a key design number).
- **Everything deterministic from `seed`**: terrain, coastline, city sites,
  road graphs, building lots, initial boats/people. Clients regenerate;
  only *deltas* go over the wire.
- **Cities**: placed by suitability (flat, near coast); road graph generated
  in a local tangent plane per city; buildings from lot hashes.
- **Ocean**: sea level = sphere of radius R; wave displacement in a local
  tangent frame around the camera.
- **Destruction** = sparse **delta layer** keyed by (chunk id, cell). Crater
  stamps are stored as events `(pos, radius, depth, seed)`, not heightmaps.
- **Avoid perfect symmetry** = avoid perfect symmetry regarding the globe and objects, although parallel lines are good for cleanliness

## Network encoding (optimize for small packets)

Principles: server-authoritative, UDP (custom reliable layer or ENet-like),
fixed tick (e.g. 60 Hz sim, 20–30 Hz snapshots), delta + interest-managed.

- **Entity ID**: u16/u32 index+generation. Types are small enums (u8).
- **Quantized state** (per plane, ~20 bytes):
  - position: relative to a *cell origin* (e.g. 1 km grid cell id u32 +
    3×u16 offset at ~2 cm resolution within cell, or 3×i32 fixed-point)
  - orientation: **smallest-three quaternion** in 32 bits
  - velocity: 3×i16 (scaled), or derived from position delta
  - flags/health/throttle: bit-packed
- **Snapshots**: delta-compressed against last client-acked snapshot;
  only changed fields, bit-packed with a bit-writer (Zig `packed struct` +
  custom `BitWriter`).
- **Interest management**: spatial hash on the sphere (cube-face cells);
  clients receive only nearby entities, with LOD rates (far = 5 Hz).
- **Static world is never sent**: seed + destruction event log. New joiners
  get seed + compacted destruction events.
- **Projectiles**: send *spawn events* (origin, dir, speed, tick) and let both
  sides simulate deterministically; hit results authoritative from server.
- **NPCs / people / boats**: simulated deterministically from seed + tick
  where possible (crowds are cosmetic, client-side only; boats are
  server-owned with sparse waypoints).
- **Prediction**: client predicts own plane with same fixed-step flight code;
  reconcile with smooth error correction. Remote entities: interpolated
  (~100 ms buffer) with dead-reckoning extrapolation.
- **LAN**: UDP broadcast discovery; Online: dedicated or listen server with
  a simple relay/NAT-punch later.
- **Security basics**: server validates inputs (rate-limited), clients send
  inputs not state.
