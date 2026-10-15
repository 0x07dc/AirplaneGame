#version 450
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec3 inColor;

layout(location = 0) out vec3 vColor;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out float vDist;

layout(push_constant) uniform Push {
    mat4 viewProj;
    mat4 model; // bottom row of columns 0..2 carries an RGB tint (unused by transform)
} pc;

void main() {
    vec3 wp = (pc.model * vec4(inPos, 1.0)).xyz;
    gl_Position = pc.viewProj * vec4(wp, 1.0);
    vNormal = normalize(mat3(pc.model) * inNormal);
    vColor = inColor * vec3(pc.model[0][3], pc.model[1][3], pc.model[2][3]);
    vDist = gl_Position.w;
}
