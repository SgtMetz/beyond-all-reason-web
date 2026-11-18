#version 300 es

uniform vec4 passRect;

layout(location = 0) in vec4 pos;
float rcl_ClipDistance[8];

void main()
{
    gl_Position = vec4(mix(passRect.xy, passRect.zw, (pos.xy * 0.5) + vec2(0.5)), 0.0, 1.0);
    rcl_ClipDistance[0] = 1.0;
    rcl_ClipDistance[1] = 1.0;
    rcl_ClipDistance[2] = 1.0;
    rcl_ClipDistance[3] = 1.0;
}

