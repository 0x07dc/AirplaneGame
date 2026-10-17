#version 450
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec3 inColor;

layout(location = 0) out vec3 vColor;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out float vDist;
layout(location = 3) out vec3 vWorldPos;
layout(location = 4) out vec3 vSunDir;

layout(push_constant) uniform Push {
    mat4 viewProj;
    mat4 model; // bottom row of columns 0..2 carries an RGB tint; model[3][3] carries sun angle
} pc;

void main() {
    float sunAngle = pc.model[3][3];
    mat4 m = pc.model;
    m[3][3] = 1.0;
    vec3 wp = (m * vec4(inPos, 1.0)).xyz;
    gl_Position = pc.viewProj * vec4(wp, 1.0);
    vNormal = normalize(mat3(m) * inNormal);
    vColor = inColor * vec3(pc.model[0][3], pc.model[1][3], pc.model[2][3]);
    vDist = (inNormal.z < -0.9) ? -1.0 : gl_Position.w;
    vWorldPos = wp;
    vSunDir = normalize(vec3(cos(sunAngle), 0.22, sin(sunAngle)));
}
