#version 450
layout(location = 0) out vec3 vColor;
layout(push_constant) uniform Push {
    vec2 offset;
    float angle;
    float aspect;
} pc;

void main() {
    vec2 pos[3] = vec2[](vec2(0.0, -0.25), vec2(0.18, 0.2), vec2(-0.18, 0.2));
    vec3 col[3] = vec3[](vec3(1.0, 0.45, 0.2), vec3(0.2, 0.8, 1.0), vec3(0.7, 0.3, 1.0));
    float c = cos(pc.angle), s = sin(pc.angle);
    vec2 p = vec2(c * pos[gl_VertexIndex].x - s * pos[gl_VertexIndex].y,
                  s * pos[gl_VertexIndex].x + c * pos[gl_VertexIndex].y) + pc.offset;
    gl_Position = vec4(p.x / pc.aspect, p.y, 0.0, 1.0);
    vColor = col[gl_VertexIndex];
}
