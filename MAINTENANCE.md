# Spotter Bullet Tracker: Codebase Maintenance Guide

This document is the technical architecture and maintenance reference for the **Spotter Bullet Tracker** mod for Arma 3.

---

## 1. Architectural Overview

Spotter Bullet Tracker is designed around a strictly client-to-client 1-to-1 sniper and spotter model.

```
+-----------------------------------------------------------------------------------+
|                              DEDICATED SERVER                                     |
|                      Server CPU Footprint: 0.00 ms                                |
|         (XEH_postInit.sqf exits immediately via !hasInterface check)              |
+-----------------------------------------------------------------------------------+
                                   |
         Direct CBA Target Events  | (No publicVariable, no broadcast)
                                   v
+--------------------------+               +----------------------------------------+
|      SHOOTER CLIENT      |               |             SPOTTER CLIENT             |
|                          |               |                                        |
| - FiredMan EH            |   sbt_pair    | - ACE Interaction ("Become Spotter")   |
| - Projectile Sampling    | ------------> | - Optics Detection (ADS in binos/scope)|
| - 50 Hz Per-Frame Handler|   sbt_chunk   | - Draw3D Mission Event Handler         |
| - HitPart Impact Hook    | ------------> | - Catmull-Rom Spline Interpolation     |
|                          |  sbt_impact   | - Volumetric Billboard Ribbon Render   |
|                          | ------------> | - drawIcon3D Impact Distance Marker    |
+--------------------------+               +----------------------------------------+
```

### Key Principles
1. **Zero Server Load**: All tracking, networking, and rendering occurs purely on player machines. Dedicated servers execute no tracking loops.
2. **Strict 1-to-1 Pairing**: One spotter pairs to one shooter. If either unit changes role, dies, or disconnects, event handlers unhook cleanly.
3. **Optics Gating**: The shooter only samples and sends bullet data when the spotter is actively aiming down sights (ADS) in authorized optics. When the spotter lowers their optics, the shooter skips projectile sampling entirely.
4. **Draw3D Only When Active**: The expensive `Draw3D` mission event handler is attached only while looking through valid optics and removed the instant the spotter lowers the glass.

---

## 2. Life Cycle of a Bullet Trace

```
1. TRIGGER PULL (Shooter)
   └─> fnc_onFired checks: sbt_enabled, valid spotter, distance <= 15m, spotter ADS ready.
   └─> Verifies ammo is BulletCore and initial speed >= 350 m/s.

2. IMPACT HOOK (Shooter)
   └─> Attaches HitPart EH to the live bullet entity to capture exact ASL impact point.

3. SAMPLING LOOP (Shooter)
   └─> Enqueues bullet into sbt_trackedQueue.
   └─> 50 Hz Per-Frame Handler (0.02s interval) records getPosASL every 2m+ of flight.
   └─> Batches points and transmits sbt_traceChunk every 50ms via CBA target event.

4. RECEIVE & SPLINE BAKE (Spotter)
   └─> fnc_receiveTrace converts ASL coordinates to AGL and aligns timestamps.
   └─> Evaluates Catmull-Rom cubic splines across incoming control points using precomputed matrix weights.
   └─> Updates active trace buffer (enforces sbt_maxTraces).

5. TERMINAL IMPACT (Shooter -> Spotter)
   └─> Bullet impacts or despawns. Shooter sends final sbt_traceImpact packet.
   └─> Spotter records terminal AGL impact coordinates and impact mission time.

6. DRAW3D RENDERING (Spotter)
   └─> fnc_draw3D runs every rendered frame while ADS.
   └─> Frustum culls segments behind the camera plane.
   └─> Draws center core and expanding volumetric ribbons drifting with wind.
   └─> Draws 3D dot icon and target distance reading ("842m") at the impact point.

7. EXPIRATION & CLEANUP (Spotter)
   └─> Vapor wake dissipates over sbt_vaporLifetime (default 0.85s).
   └─> Impact icon fades over sbt_impactDuration (default 2.5s).
   └─> Trace tuple is deleted from sbt_activeTraces and sbt_traceIndexMap.
```

---

## 3. Codebase File Structure

| File | Purpose |
| --- | --- |
| `addons/main/config.cpp` | CfgPatches definition, required addons (CBA, ACE), and XEH hooks. |
| `addons/main/script_component.hpp` | Component definition macros (`PREFIX sbt`, `COMPONENT main`). |
| `addons/main/script_macros.hpp` | Macro helpers (`PREP`, debug logs, version string builders). |
| `addons/main/script_version.hpp` | Semantic version numbers (Major, Minor, Patch, Build). |
| `addons/main/XEH_preStart.sqf` | Pre-compilation hook for functions during game start. |
| `addons/main/XEH_preInit.sqf` | Initializes global caches, math weights, and includes settings. |
| `addons/main/XEH_postInit.sqf` | Client-only setup, target event handlers, optics switch listeners. |
| `addons/main/XEH_PREP.hpp` | Function registration list compiled via CBA_fnc_compileFunction. |
| `addons/main/initSettings.inc.sqf` | CBA Addon Options menu registration for all user settings. |
| `addons/main/functions/fnc_becomeSpotter.sqf` | Pairs player to a target shooter unit via ACE interact. |
| `addons/main/functions/fnc_stopSpotting.sqf` | Unpairs player, clears variables, and removes Draw3D. |
| `addons/main/functions/fnc_handlePairRequest.sqf` | Executed on shooter; attaches FiredMan EH and saves spotter. |
| `addons/main/functions/fnc_handleUnpair.sqf` | Executed on shooter; detaches FiredMan EH and clears spotter. |
| `addons/main/functions/fnc_checkOptics.sqf` | Verifies ADS through binos/spotting scope; manages Draw3D EH. |
| `addons/main/functions/fnc_initInteractions.sqf` | Registers ACE actions ("Become Spotter" and "Stop Spotting"). |
| `addons/main/functions/fnc_onFired.sqf` | Shooter FiredMan handler; tracks bullets and streams chunks. |
| `addons/main/functions/fnc_receiveTrace.sqf` | Spotter packet receiver; calculates Catmull-Rom spline curves. |
| `addons/main/functions/fnc_draw3D.sqf` | Per-frame renderer for vapor ribbons and impact distance icons. |
| `addons/main/functions/fnc_parseClassList.sqf` | Parses comma-separated class strings into fast lookup HashMaps. |

---

## 4. Network Protocol and Events

All network communication uses `CBA_fnc_targetEvent`. Data is sent directly to the partner client without broadcasting to other clients or the server.

### `sbt_pair`
- **Target**: Shooter unit
- **Payload**: `[spotter (Object), isReady (Boolean)]`
- **Action**: Shooter stores spotter in `player setVariable ["sbt_spotter", spotter, true]` and attaches `FiredMan` EH.

### `sbt_unpair`
- **Target**: Shooter or Spotter unit
- **Payload**: `[sender (Object)]`
- **Action**: Removes `FiredMan` EH and clears tracking variables.

### `sbt_spotterReady`
- **Target**: Shooter unit
- **Payload**: `[spotter (Object), isReady (Boolean)]`
- **Action**: Updates `spotter setVariable ["sbt_ready", isReady]` on the shooter machine. When `isReady` is false, the shooter ignores all fired rounds.

### `sbt_traceChunk`
- **Target**: Spotter unit
- **Payload**: `[traceKey (String), points (Array), meta (Array)]`
- **Points Format**: `[[posASL, flightTimeSeconds], ...]`
- **Meta Format**: `[muzzleVelocityMps, velocityVector]` on initial chunk; `[]` on subsequent chunks.

### `sbt_traceImpact`
- **Target**: Spotter unit
- **Payload**: `[traceKey (String), points (Array), meta (Array)]`
- **Action**: Marks the trace as impacted, bakes final spline endpoint, and stores impact coordinates for `drawIcon3D`.

---

## 5. Active Trace Data Structure

Each active bullet trace on the spotter machine is stored as a 12-element array inside `sbt_activeTraces` and indexed by `sbt_traceIndexMap`:

```sqf
_trace = [
    _traceKey,          // 0: String   - Unique shot identifier (e.g. "1")
    _posArr,            // 1: Array    - Interpolated spline points in AGL [[x,y,z], ...]
    _impacted,          // 2: Boolean  - True once terminal impact packet is received
    _localStart,        // 3: Number   - Local CBA_missionTime when shot was fired
    _rawAGL,            // 4: Array    - Raw received control points [[posAGL, time], ...]
    _bakedCursor,       // 5: Number   - Next spline control point index to bake
    _renderCursor,      // 6: Number   - First non-expired segment index for Draw3D
    _timeArr,           // 7: Array    - Interpolated timestamps matching _posArr
    _velEst,            // 8: Array    - Instantaneous estimated velocity vector
    _dragFactor,        // 9: Number   - Estimated drag coefficient for dead reckoning
    _impactPosAGL,      // 10: Array   - Terminal impact position [x,y,z] in AGL
    _impactTime         // 11: Number  - Local CBA_missionTime when impact occurred
];
```

---

## 6. Mathematical Foundations

### Catmull-Rom Cubic Spline Interpolation
Raw projectile positions sampled at 50 Hz create segmented lines. To produce a smooth condensation trail, Catmull-Rom cubic splines interpolate 4 intermediate sub-points between each control point pair:

$$p(u) = 0.5 \cdot \left[(-u^3 + 2u^2 - u)p_0 + (3u^3 - 5u^2 + 2)p_1 + (-3u^3 + 4u^2 + u)p_2 + (u^3 - u^2)p_3\right]$$

Precomputed matrix weights in `sbt_splineWeights` evaluate this at fractional steps $u \in \{0.25, 0.50, 0.75, 1.00\}$ with pure vector math.

### Frustum Dot-Product Culling
Before iterating over trace segments, the camera view direction dot product tests whether points lie in front of the camera plane:

$$\text{visible} = (P \cdot \vec{d}_{\text{cam}}) > (P_{\text{cam}} \cdot \vec{d}_{\text{cam}})$$

If both the start and end of a trace fail this test, the entire trace is skipped.

### Volumetric Billboard Ribbons
To give the vapor trail 3D depth, ribbon flank vectors are calculated perpendicular to both the bullet's flight path chord $\vec{c}$ and the camera view vector $\vec{d}_{\text{cam}}$:

$$\vec{n}_{\text{billboard}} = \frac{\vec{c} \times \vec{d}_{\text{cam}}}{\|\vec{c} \times \vec{d}_{\text{cam}}\|}$$

Flank ribbons expand outward from the core over time and drift according to the local wind vector.

### Impact Distance Calculation
When the terminal impact occurs, the distance reading displayed next to the dot icon is computed from the shooter's rifle muzzle to the impact position:

$$\text{distance} = \text{round}(\|\vec{pos}_{\text{impact}} - \vec{pos}_{\text{shooter}}\|)$$

If the shooter object is unavailable, it gracefully falls back to the spotter's position.

---

## 7. CBA Settings Reference

All settings can be configured in-game via `Options -> Addon Options -> Spotter Bullet Tracker`:

| Setting Key | Type | Default | Description |
| --- | --- | --- | --- |
| `sbt_enabled` | Checkbox | `true` | Master toggle for the entire mod. |
| `sbt_maxTraces` | Slider | `4` | Cap on simultaneous traces drawn in Draw3D. |
| `sbt_maxSpotterDist` | Slider | `15m` | Maximum allowed distance between spotter and shooter. |
| `sbt_autoIncludeOptics` | Checkbox | `true` | Auto-enables all binoculars, rangefinders, and designators. |
| `sbt_scopeVehicles` | Editbox | `"ACE_SpottingScopeObject"` | Extra static spotting scope vehicle/turret classes. |
| `sbt_opticsList` | Editbox | Comma list | Extra handheld optic item classnames. |
| `sbt_vaporColor` | Color | `[0.90, 0.93, 0.96]` | RGB color of the vapor condensation wake. |
| `sbt_vaporAlpha` | Slider | `0.42` | Peak opacity of the vapor trail. |
| `sbt_vaporLifetime` | Slider | `0.85s` | How long each vapor segment remains visible. |
| `sbt_volumetricVapor` | Checkbox | `true` | Enables expanding 3D ribbons that drift with wind. |
| `sbt_showImpactIcon` | Checkbox | `true` | Draws a 3D dot icon and distance reading on impact. |
| `sbt_impactDuration` | Slider | `2.5s` | Visibility duration of the impact distance marker. |
| `sbt_impactColor` | Color | `[1.0, 0.75, 0.20]` | RGB color of the impact icon and distance text. |
| `sbt_enableMinLight` | Checkbox | `true` | Suppresses traces in pitch darkness without NVG/TI. |
| `sbt_minLight` | Slider | `0.25` | Ambient light threshold required for daylight traces. |
| `sbt_allowNVG` | Checkbox | `true` | Allows seeing traces through night vision goggles. |
| `sbt_allowTI` | Checkbox | `false` | Allows seeing traces in thermal imaging mode. |

---

## 8. Build and Maintenance Workflow

The project uses [HEMTT](https://github.com/BrettMayson/HEMTT) for building, linting, and releasing.

### Common Commands
```powershell
# Run the SQF and config linter
hemtt check

# Build test PBO into .hemttout/build
hemtt build

# Build production release ZIPs into releases/
hemtt release

# Build dev version and update symlink in Arma 3 directory
hemtt dev
```

### Dev Symlink Setup
When running `hemtt dev`, HEMTT automatically establishes a directory symlink:
- **Target**: `D:\SteamLibrary\steamapps\common\Arma 3\z\sbt` -> `<repo>\.hemttout\dev`
- Enable `-filePatching` in your Arma 3 launcher or startup parameters to load updated scripts without repacking PBOs.

---

## 9. Troubleshooting and Edge Cases

1. **Spotter sees no traces when shooter fires**:
   - Verify spotter is within 15m of shooter (`sbt_maxSpotterDist`).
   - Verify spotter is actively aiming down sights in binoculars, rangefinder, or spotting scope.
   - Check ambient lighting: in nighttime missions, traces are suppressed unless NVG/TI is active or `sbt_enableMinLight` is false.
   - Verify ammunition is a bullet (`BulletCore`) with muzzle velocity >= 350 m/s.

2. **Impact icon position accuracy**:
   - The impact position is captured by the engine's `HitPart` event handler directly on the bullet object.
   - If a bullet travels beyond 3000m or flies for more than 8 seconds, the round is treated as despawned and impacts at its last recorded position.

3. **Performance during high rate of fire**:
   - If a shooter fires rapidly (e.g. DMR double-tap), `sbt_maxTraces` caps the maximum active traces in memory.
   - The oldest completed trace is immediately dropped when a new shot arrives exceeding the cap.
