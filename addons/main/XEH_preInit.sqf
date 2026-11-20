#include "script_component.hpp"

ADDON = false;

#include "XEH_PREP.hpp"

sbt_scopeVehicleMap = createHashMap;
sbt_opticItemMap = createHashMap;

// Pre-squared thresholds avoid calling sqrt inside per-frame loops
sbt_maxSpotterDistSqr = 225;     // 15m max distance between spotter and shooter (15^2)
sbt_maxTrackDistSqr = 9000000;   // 3000m max tracking distance for projectiles (3000^2)
sbt_minVelocitySqr = 122500;     // 350 m/s minimum projectile speed to track (350^2)

sbt_showImpactIcon = true;
sbt_impactDuration = 2.5;
sbt_impactColor = [1.0, 0.75, 0.20];

// Precomputed Catmull-Rom weights at u = 0.25, 0.50, 0.75, 1.00 avoid polynomial math per point
sbt_splineWeights = [
    [-0.046875, 0.890625, 0.171875, -0.015625, 0.25],
    [-0.0625, 0.5625, 0.5625, -0.0625, 0.5],
    [-0.015625, 0.171875, 0.890625, -0.046875, 0.75],
    [0, 0, 1, 0, 1.0]
];

#include "initSettings.inc.sqf"

ADDON = true;
