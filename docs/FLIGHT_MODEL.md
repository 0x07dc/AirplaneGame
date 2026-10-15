# Flight Model — The Heart of the Game

> "Extremely fast and extremely maneuverable." This is the section that makes
> the game. Everything else (planet, cities, netcode) exists to serve it.
> This file is a living design doc; iterate here first, then in code.

## Design pillars

1. **Speed is the spectacle.** Small planes, huge velocity. The world must
   *feel* fast: low-altitude ground rush, parallax, speed-lines, FOV kick,
   wind audio, camera shake. Speed readout is secondary to the visual.
2. **Instant response.** Zero perceptible input latency. Turn-rate is
   commanded, not integrated through slow control surfaces. Stick → angular
   velocity target in <1–2 frames.
3. **Maneuvers over simulation.** Tight, snappy turns, knife-edge, hard
   reversals, "cobra" flips, drift-turns. Physics supports stylish moves, it
   doesn't punish. Stalling exists but is a *tool* (pivot), not a failure.
4. **Everything is forgiving, nothing is floaty.** Weighty, crisp, readable.
5. **Skill ceiling via momentum.** Velocity vector and nose direction are
   decoupled, so mastering "slip" gives high-skill play (strafing runs,
   dodging missiles, tailing).

## Core model (proposal — to be tuned by feel)

State: `pos`, `vel` (world, planet-relative), `rot` (quaternion), `ang_vel`.

- **Rotation is direct-control**: pilot input maps to target angular rates
  (pitch/roll/yaw, deg/s), smoothed by a critically-damped spring with very
  high stiffness (time constant ~0.05–0.12 s). Rates e.g. pitch 220°/s,
  roll 540°/s, yaw 90°/s (all configurable per airframe).
- **Velocity follows nose, partially.** Each tick, `vel` is rotated toward
  the nose direction by a "grip" factor (0..1) — high grip = on rails
  (arcade), low grip = drifty. Grip drops with angle-of-attack above a
  threshold (powerslide), and with high-G turns (bleeds speed).
- **Speed model**: thrust → target speed band; afterburner/boost; turns bleed
  energy proportionally to turn rate (rewarding wide arcs vs. snap turns);
  dive gains speed, climb loses it (gravity along the vel vector, small).
- **Lift is implicit**: no true stalls; instead an "energy floor" speed below
  which grip collapses and the nose can pivot freely (a deliberate trick move).
- **Brake / airbrake / boost** as distinct inputs.
- **Gravity on a sphere**: "down" = −normalize(pos − planet_center). All
  attitude & camera "up" references are local-up; roll is relative to it.
- **Ground effect & terrain near-miss bonus**: low-altitude fast flight gives
  a visual/score/boost bonus (encourages canyon/street flying).
- **Battle component** Battle AI in campaign or skirmish or play online with other players.

## Camera

- Chase cam with lag on position, tight on rotation; roll partially
  followed. FOV widens with speed. Look-ahead on turns. Cockpit/first-person
  optional.

## Tuning workflow (to build early!)

- Hot-reloadable `flight.toml`/`zon` params file; in-game debug sliders.
- Test course: ring gauntlet, canyon, city streets, loop-the-loop.
- Record/replay inputs to compare tuning variants deterministically.
- Fixed 240 Hz (or 120 Hz) physics step, decoupled from render.

## Networking implications

- Flight state is tiny (pos, quat, vel, few input bits) — see NETCODE.md.
- Client-side prediction + server reconciliation is essential because
  responsiveness is sacred: local plane must never wait on the server.
- Deterministic integrator (fixed step, no platform-dependent floats in the
  critical path; use f64 for position, f32 for rotations).

## Open tuning questions
- Max speed vs. planet radius (what's the world scale? crossing time?)
- Should airframes differ drastically (interceptor, bomber, glider)?
- G-force / blackout mechanic: none, cosmetic, or gameplay?
