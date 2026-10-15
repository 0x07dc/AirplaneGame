#version 450
layout(location = 0) in vec3 vColor;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in float vDist;
layout(location = 0) out vec4 outColor;

const vec3 SUN_DIR = normalize(vec3(0.45, 0.8, 0.3));
const vec3 SKY = vec3(0.34, 0.57, 0.82);
const vec3 GROUND_BOUNCE = vec3(0.12, 0.16, 0.10);

void main() {
    vec3 n = normalize(vNormal);
    float diff = max(dot(n, SUN_DIR), 0.0);
    vec3 hemi = mix(GROUND_BOUNCE, SKY * 0.55, n.y * 0.5 + 0.5);
    vec3 lit = vColor * (hemi + diff * vec3(1.0, 0.95, 0.85) * 0.95);
    float f = 1.0 - exp(-pow(vDist * 0.00016, 1.4));
    outColor = vec4(mix(lit, SKY, clamp(f, 0.0, 1.0)), 1.0);
}
