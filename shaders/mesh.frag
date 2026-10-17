#version 450
layout(location = 0) in vec3 vColor;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in float vDist;
layout(location = 3) in vec3 vWorldPos;
layout(location = 4) in vec3 vSunDir;
layout(location = 0) out vec4 outColor;

const vec3 DAY_SKY = vec3(0.30, 0.56, 0.88);
const vec3 DAY_ZENITH = vec3(0.07, 0.20, 0.54);
const vec3 DUSK_SKY = vec3(0.92, 0.42, 0.20);
const vec3 NIGHT_SKY = vec3(0.015, 0.024, 0.055);
const vec3 NIGHT_ZENITH = vec3(0.005, 0.009, 0.026);

// Evaluates the directional + vertical sky gradient in direction `dir` given local `up` and `sun`
vec3 evalSkyGradient(vec3 dir, vec3 up, vec3 sun) {
    float sunElev = dot(up, sun);
    float dayFactor = smoothstep(-0.20, 0.28, sunElev);
    float twilight = exp(-pow(sunElev / 0.24, 2.0));

    // Vertical zenith-to-horizon gradient relative to local planet surface normal `up`
    float elev = dot(dir, up); // +1 at zenith, 0 at horizon, <0 below horizon
    float zenithT = clamp(elev, 0.0, 1.0);
    float horizonBand = exp(-pow(elev / 0.22, 2.0));

    vec3 zenithCol = mix(NIGHT_ZENITH, DAY_ZENITH, dayFactor);
    vec3 horizCol = mix(NIGHT_SKY, DAY_SKY, dayFactor);
    horizCol = mix(horizCol, DUSK_SKY, twilight * 0.65);

    vec3 sky = mix(horizCol, zenithCol, pow(zenithT, 0.65));

    // Directional azimuth gradient (compass orientation + solar scattering):
    // 1) Sunward warm golden/amber scatter vs anti-solar deep indigo/cobalt
    float sunAlign = dot(dir, sun); // +1 looking toward sun, -1 looking away
    vec3 warmScatter = mix(vec3(0.98, 0.45, 0.18), vec3(0.95, 0.82, 0.55), dayFactor);
    vec3 antiSunTint = mix(vec3(0.01, 0.02, 0.06), vec3(0.10, 0.32, 0.72), dayFactor);
    sky = mix(sky, antiSunTint, clamp(-sunAlign, 0.0, 1.0) * 0.35);
    sky += warmScatter * pow(clamp(sunAlign * 0.5 + 0.5, 0.0, 1.0), 3.0) * (0.28 + 0.35 * twilight);

    // 2) Global compass gradient (North +Y cyan/aurora-blue vs South -Y warm magenta-gold, East +X teal vs West -X amber)
    // so even at constant solar angle you can immediately read your heading around the globe
    vec3 compassTint = vec3(
        0.10 * dir.x - 0.08 * dir.y,
        0.09 * dir.y + 0.05 * dir.z,
        0.14 * dir.y - 0.09 * dir.x
    );
    sky += compassTint * (0.45 + 0.45 * horizonBand);

    // Bright horizon rim glow so the horizon line and bank angle are crisp
    vec3 rimCol = mix(vec3(0.18, 0.32, 0.58), vec3(0.82, 0.92, 1.0), dayFactor);
    rimCol = mix(rimCol, vec3(1.0, 0.58, 0.30), twilight * 0.75);
    sky = mix(sky, rimCol, horizonBand * 0.32);

    // Sun disk + glowing solar corona + opposite moon/anti-sun marker
    float sunGlow = pow(clamp(sunAlign, 0.0, 1.0), 16.0) * 0.45;
    float sunDisk = smoothstep(0.9965, 0.9988, sunAlign) * 1.6;
    sky += vec3(1.0, 0.90, 0.68) * (sunGlow + sunDisk);

    float moonAlign = -sunAlign;
    float moonGlow = pow(clamp(moonAlign, 0.0, 1.0), 28.0) * 0.22;
    float moonDisk = smoothstep(0.9975, 0.9990, moonAlign) * 0.75;
    sky += vec3(0.55, 0.72, 1.0) * (moonGlow + moonDisk);

    return clamp(sky, 0.0, 2.5);
}

void main() {
    // HUD / Avionics sentinel: pristine self-illuminated emissive, zero lighting darkening, zero haze fog
    if (vDist < 0.0) {
        outColor = vec4(vColor, 1.0);
        return;
    }

    vec3 sun = normalize(vSunDir);

    // Sky dome sentinel (`vColor.r > 20.0`)
    if (vColor.r > 20.0) {
        vec3 dir = normalize(vWorldPos);
        // Use vNormal (-dir) or dir for spherical sky gradient; blend with sun & global compass
        vec3 skyCol = evalSkyGradient(dir, dir, sun);
        // Add subtle procedural altitude/azimuth bands across the sky dome so turning/banking is immediately visible
        float azBand = 0.5 + 0.5 * sin(atan(dir.z, dir.x) * 4.0);
        float elBand = 0.5 + 0.5 * cos(asin(clamp(dir.y, -1.0, 1.0)) * 6.0);
        skyCol *= 0.92 + 0.08 * (0.65 * azBand + 0.35 * elBand);
        outColor = vec4(skyCol, 1.0);
        return;
    }

    vec3 n = normalize(vNormal);
    vec3 up = normalize(vWorldPos);

    // Spherical day / sunset / night factor based on where this point is on the planet
    float sunElev = dot(up, sun);
    float dayFactor = smoothstep(-0.18, 0.28, sunElev);

    // Direct sunlight (masked on the night side of the planet)
    float planetShadow = smoothstep(-0.12, 0.08, sunElev);
    float ndl = max(dot(n, sun), 0.0) * planetShadow;
    vec3 sunCol = mix(vec3(1.05, 0.48, 0.22), vec3(1.05, 0.97, 0.88), smoothstep(0.0, 0.35, max(sunElev, 0.0)));

    // Local hemisphere ambient (day sky vs starlit night)
    vec3 skyAmb = mix(vec3(0.035, 0.055, 0.11), DAY_SKY * 0.58, dayFactor);
    vec3 groundAmb = mix(vec3(0.015, 0.022, 0.045), vec3(0.11, 0.14, 0.10), dayFactor);
    float hemiT = clamp(dot(n, up) * 0.5 + 0.5, 0.0, 1.0);
    vec3 ambient = mix(groundAmb, skyAmb, hemiT);

    // Emissive boost for bright weapon bolts / engine glow (where vColor channels > 1.2)
    float emissive = max(max(vColor.r, max(vColor.g, vColor.b)) - 1.0, 0.0);
    vec3 lit = vColor * (ambient + ndl * sunCol * 0.95) + vColor * (emissive * 0.45);

    // Directional atmospheric scattering / horizon haze matching the sky gradient in that direction
    vec3 localHorizon = evalSkyGradient(up, up, sun);
    float f = 1.0 - exp(-pow(vDist * 0.0000095, 1.35));
    outColor = vec4(mix(lit, localHorizon, clamp(f * 0.82, 0.0, 0.82)), 1.0);
}
