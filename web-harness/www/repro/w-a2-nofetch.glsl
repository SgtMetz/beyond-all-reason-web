#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform UniformParamsBuffer
{
    vec3 rndVec3;
    uint renderCaps;
    vec4 timeInfo;
    vec4 viewGeometry;
    vec4 mapSize;
    vec4 mapHeight;
    vec4 fogColor;
    vec4 fogParams;
    vec4 sunDir;
    vec4 sunAmbientModel;
    vec4 sunAmbientMap;
    vec4 sunDiffuseModel;
    vec4 sunDiffuseMap;
    vec4 sunSpecularModel;
    vec4 sunSpecularMap;
    vec4 shadowDensity;
    vec4 windInfo;
    vec2 mouseScreenPos;
    uint mouseStatus;
    uint mouseUnused;
    vec4 mouseWorldPos;
    vec4 teamColor[255];
} _944;

layout(std140) uniform UniformMatrixBuffer
{
    mat4 screenView;
    mat4 screenProj;
    mat4 screenViewProj;
    mat4 cameraView;
    mat4 cameraProj;
    mat4 cameraViewProj;
    mat4 cameraBillboardView;
    mat4 cameraViewInv;
    mat4 cameraProjInv;
    mat4 cameraViewProjInv;
    mat4 shadowView;
    mat4 shadowProj;
    mat4 shadowViewProj;
    mat4 reflectionView;
    mat4 reflectionProj;
    mat4 reflectionViewProj;
    mat4 orthoProj01;
    mat4 mmDrawView;
    mat4 mmDrawProj;
    mat4 mmDrawViewProj;
    mat4 mmDrawIMMView;
    mat4 mmDrawIMMProj;
    mat4 mmDrawIMMViewProj;
    mat4 mmDrawDimView;
    mat4 mmDrawDimProj;
    mat4 mmDrawDimViewProj;
} _965;

uniform highp usampler2D rcl_ssbo5;
uniform vec4 lookupParams;
uniform highp sampler2D coverageTex;
uniform highp sampler2D targetTex;
uniform highp sampler2D radarInfoTex;
uniform highp sampler2D alliedWinnerTex;
uniform highp sampler2D alliedRunnerUpTex;
uniform vec4 circleParams;
uniform vec4 animParams;
uniform highp sampler2D mapDepths;
uniform vec4 radarcenter_range;
uniform highp sampler2D modelDepths;
uniform uint rcl_ssbo5_bytes;

layout(location = 0) out vec4 fragColor;

vec2 previewCoverageAt(ivec2 radarCell)
{
    ivec2 texel = (radarCell - ivec2(lookupParams.xy)) + ivec2(int(lookupParams.z));
    bool _130 = any(lessThan(texel, ivec2(0)));
    bool oob = (!_130) ? any(greaterThanEqual(texel, textureSize(coverageTex, 0))) : _130;
    vec2 v = vec2(texelFetch(targetTex, texel, 0).x, texelFetch(coverageTex, texel, 0).x);
    return oob ? vec2(-1.0) : v;
}

float alliedAt(ivec2 radarCell)
{
    bool _220 = lookupParams.w < 0.5;
    bool _227 = (!_220) ? any(lessThan(radarCell, ivec2(0))) : _220;
    bool oob = (!_227) ? any(greaterThanEqual(radarCell, textureSize(radarInfoTex, 0))) : _227;
    return oob ? 0.0 : 1.0;
}

vec2 circleCoverageAt(ivec2 radarCell)
{
    ivec2 param = radarCell;
    vec2 coverage = previewCoverageAt(param);
    vec2 offset = vec2(radarCell - ivec2(lookupParams.xy));
    float dist = length(offset);
    bool _181 = coverage.x <= 0.0;
    if (_181 ? (dist > lookupParams.z) : _181)
    {
        ivec2 inner = ivec2(lookupParams.xy) + ivec2(floor((offset * ((lookupParams.z - 0.75) / dist)) + vec2(0.5)));
        ivec2 param_1 = inner;
        coverage = previewCoverageAt(param_1);
    }
    return max(coverage, vec2(0.0));
}

vec2 boundaryCoverageAt(ivec2 cell, bool allied)
{
    vec2 _616;
    if (allied)
    {
        ivec2 param = cell;
        _616 = vec2(alliedAt(param));
    }
    else
    if (circleParams.x > 0.5)
    {
        ivec2 param_1 = cell;
        _616 = circleCoverageAt(param_1);
    }
    else
    {
        ivec2 param_2 = cell;
        _616 = previewCoverageAt(param_2);
    }
    return max(_616, vec2(0.0));
}

float roundedBoundary(float covered, vec3 neighbours, vec2 edgeDist)
{
    float radius = 0.3300000131130218505859375;
    float res;
    if (covered > 0.5)
    {
        float _336 = (neighbours.x < 0.5) ? edgeDist.x : 1000000.0;
        float _348 = (neighbours.y < 0.5) ? edgeDist.y : 1000000.0;
        vec2 sideDist = vec2(_336, _348);
        bool _358 = neighbours.x < 0.5;
        bool _364 = _358 ? (neighbours.y > 0.5) : _358;
        bool _370 = _364 ? (neighbours.z > 0.5) : _364;
        sideDist.x = (_370 ? (edgeDist.y < radius) : _370) ? (length(vec2(edgeDist.x + radius, edgeDist.y - radius)) - radius) : sideDist.x;
        bool _395 = neighbours.y < 0.5;
        bool _401 = _395 ? (neighbours.x > 0.5) : _395;
        bool _407 = _401 ? (neighbours.z > 0.5) : _401;
        sideDist.y = (_407 ? (edgeDist.x < radius) : _407) ? (length(vec2(edgeDist.x - radius, edgeDist.y + radius)) - radius) : sideDist.y;
        float sdf = min(sideDist.x, sideDist.y);
        bool _438 = neighbours.x < 0.5;
        bool _444 = _438 ? (neighbours.y < 0.5) : _438;
        sdf = (_444 ? all(lessThan(edgeDist, vec2(radius))) : _444) ? (radius - length(edgeDist - vec2(radius))) : sdf;
        res = sdf;
    }
    else {
    float _468 = (neighbours.x > 0.5) ? edgeDist.x : 1000000.0;
    float _478 = (neighbours.y > 0.5) ? edgeDist.y : 1000000.0;
    vec2 sideDist_1 = vec2(_468, _478);
    bool _488 = neighbours.x > 0.5;
    bool _494 = _488 ? (neighbours.z < 0.5) : _488;
    sideDist_1.x = (_494 ? (edgeDist.y < radius) : _494) ? (length(vec2(edgeDist.x + radius, edgeDist.y - radius)) - radius) : sideDist_1.x;
    bool _519 = neighbours.y > 0.5;
    bool _525 = _519 ? (neighbours.z < 0.5) : _519;
    sideDist_1.y = (_525 ? (edgeDist.x < radius) : _525) ? (length(vec2(edgeDist.x - radius, edgeDist.y + radius)) - radius) : sideDist_1.y;
    float sdf_1 = -min(sideDist_1.x, sideDist_1.y);
    bool _557 = neighbours.x < 0.5;
    bool _563 = _557 ? (neighbours.y < 0.5) : _557;
    sdf_1 = (_563 ? (neighbours.z > 0.5) : _563) ? (radius - length(edgeDist + vec2(radius))) : sdf_1;
    bool _583 = all(greaterThan(neighbours, vec3(0.5)));
    sdf_1 = (_583 ? all(lessThan(edgeDist, vec2(radius))) : _583) ? (length(edgeDist - vec2(radius)) - radius) : sdf_1;
    res = sdf_1;
    }
    return res;
}

float roundedCells(vec2 coord, bool allied, out float sdf)
{
    ivec2 cell = ivec2(floor(coord));
    vec2 inCell = fract(coord);
    ivec2 direction = (ivec2(step(vec2(0.5), inCell)) * ivec2(2)) - ivec2(1);
    ivec2 param = cell;
    bool param_1 = allied;
    vec2 center = boundaryCoverageAt(param, param_1);
    ivec2 param_2 = cell + ivec2(direction.x, 0);
    bool param_3 = allied;
    vec2 nx = boundaryCoverageAt(param_2, param_3);
    ivec2 param_4 = cell + ivec2(0, direction.y);
    bool param_5 = allied;
    vec2 nz = boundaryCoverageAt(param_4, param_5);
    ivec2 param_6 = cell + direction;
    bool param_7 = allied;
    vec2 nd = boundaryCoverageAt(param_6, param_7);
    vec3 neighbours = step(vec3(0.5), vec3(nx.x, nz.x, nd.x));
    float param_8 = step(0.5, center.x);
    vec3 param_9 = neighbours;
    vec2 param_10 = vec2(0.5) - abs(inCell - vec2(0.5));
    sdf = roundedBoundary(param_8, param_9, param_10);
    return (center.x > 0.5) ? center.y : max(nx.y * neighbours.x, max(nz.y * neighbours.y, nd.y * neighbours.z));
}

uvec4 rcl_ssbo5_t(uint o)
{
    uint i = o >> 4u;
    return texelFetch(rcl_ssbo5, ivec2(int(i & 1023u), int(i >> 10u)), 0);
}

vec4 rcl_ssbo5_alliedCircles(uint i)
{
    uint param = 0u + (i * 16u);
    return uintBitsToFloat(rcl_ssbo5_t(param));
}

float packedCircleDist(float entry, vec2 worldXZ)
{
    uint param = uint(int(entry) % 4096);
    vec4 circle = rcl_ssbo5_alliedCircles(param);
    return circle.z - distance(worldXZ, circle.xy);
}

float cellCircleDist(ivec2 radarCell, vec2 worldXZ)
{
    bool _270 = any(lessThan(radarCell, ivec2(0)));
    bool oob = (!_270) ? any(greaterThanEqual(radarCell, textureSize(alliedWinnerTex, 0))) : _270;
    float winner = texelFetch(alliedWinnerTex, radarCell, 0).x;
    float runnerUp = texelFetch(alliedRunnerUpTex, radarCell, 0).x;
    float dist = packedCircleDist(winner, worldXZ);
    dist = (runnerUp > 0.5) ? max(dist, packedCircleDist(runnerUp, worldXZ)) : dist;
    return (oob || winner < 0.5) ? -1000000.0 : dist / 32.0;
}

float alliedCircleCells(vec2 coord, vec2 worldXZ, float reach)
{
    ivec2 cell = ivec2(floor(coord));
    vec2 inCell = fract(coord);
    vec2 edgeDist = vec2(0.5) - abs(inCell - vec2(0.5));
    ivec2 param = cell;
    vec2 param_1 = worldXZ;
    float own = cellCircleDist(param, param_1);
    bool early = all(greaterThan(edgeDist, vec2(reach)));
    {
        float _764 = (own > (-100000.0)) ? min(own, min(edgeDist.x, edgeDist.y)) : (-1000000.0);
        return _764;
    }
    ivec2 direction = (ivec2(step(vec2(0.5), inCell)) * ivec2(2)) - ivec2(1);
    ivec2 param_2 = cell + ivec2(direction.x, 0);
    vec2 param_3 = worldXZ;
    ivec2 param_4 = cell + ivec2(0, direction.y);
    vec2 param_5 = worldXZ;
    ivec2 param_6 = cell + direction;
    vec2 param_7 = worldXZ;
    vec3 neighbourDist = vec3(cellCircleDist(param_2, param_3), cellCircleDist(param_4, param_5), cellCircleDist(param_6, param_7));
    vec3 neighbours = vec3(greaterThan(neighbourDist, vec3(0.0)));
    float param_8 = 0.0;
    vec3 param_9 = neighbours;
    vec2 param_10 = edgeDist;
    float sdf = min(roundedBoundary(param_8, param_9, param_10), max(neighbourDist.x, max(neighbourDist.y, neighbourDist.z)));
    if (own > (-100000.0))
    {
        float param_11 = 1.0;
        vec3 param_12 = neighbours;
        vec2 param_13 = edgeDist;
        sdf = max(sdf, min(roundedBoundary(param_11, param_12, param_13), own));
    }
    return sdf;
}

float sheetGlow(vec2 fromCenter, float time)
{
    float dist = length(fromCenter);
    float phase = fract((dist - (time * 85.0)) / 180.0);
    float _866 = true ? pow(0.5 + (0.5 * cos((phase * 2.0) * 3.1415927410125732421875)), 4.5) : pow(1.0 - phase, 4.5);
    float ring = _866;
    float glow = ring * 0.800000011920928955078125;
    if (animParams.w > 0.5)
    {
        float angle = (atan(fromCenter.y, fromCenter.x) / 6.283185482025146484375) + 0.5;
        float behind = (1.0 - fract(angle - (time * 0.10999999940395355224609375))) * 360.0;
        float trail = clamp(1.0 - (behind / 30.0), 0.0, 1.0);
        glow += (((trail * trail) + (1.0 - smoothstep(0.0, 9.0, behind))) * 0.550000011920928955078125);
    }
    return clamp(glow, 0.0, 1.0);
}

void main()
{
    vec2 screenUV = (gl_FragCoord.xy - _944.viewGeometry.zw) / _944.viewGeometry.xy;
    float mapDepth = texture(mapDepths, screenUV).x;
    vec4 world = _965.cameraViewProjInv * vec4((screenUV * 2.0) - vec2(1.0), mapDepth, 1.0);
    vec3 worldPos = world.xyz / vec3(world.w);
    vec3 camPos = _965.cameraViewInv[3].xyz;
    bool _993 = worldPos.y < 0.0;
    if (_993 ? (camPos.y > 0.0) : _993)
    {
        worldPos = mix(camPos, worldPos, vec3(camPos.y / (camPos.y - worldPos.y)));
    }
    vec2 cellCoord = worldPos.xz / vec2(32.0);
    vec2 cellPixels = fwidth(cellCoord);
    if (mapDepth >= 0.999998986721038818359375)
    {
        discard;
    }
    ivec2 cell = ivec2(floor(cellCoord));
    bool circles = circleParams.x > 0.5;
    float pixelCells = max(max(cellPixels.x, cellPixels.y), 9.9999997473787516355514526367188e-06);
    float circleSdf = circleParams.y - distance(worldPos.xz, radarcenter_range.xz);
    bool _1056 = lookupParams.w < 0.5;
    bool _1075;
    if (_1056)
    {
        bool _1060;
        if (circles)
        {
            _1060 = circleSdf < ((-pixelCells) * 32.0);
        }
        else
        {
            ivec2 param = cell;
            _1060 = previewCoverageAt(param).x < 0.0;
        }
        _1075 = _1060;
    }
    else
    {
        _1075 = _1056;
    }
    if (_1075)
    {
        discard;
    }
    vec2 param_1 = cellCoord;
    bool param_2 = false;
    float param_3;
    float _1086 = roundedCells(param_1, param_2, param_3);
    float ownBoundarySdf = param_3;
    float ownCoverage = _1086;
    ownBoundarySdf = circles ? min(ownBoundarySdf, circleSdf / 32.0) : ownBoundarySdf;
    ownCoverage *= clamp((ownBoundarySdf / pixelCells) + 0.5, 0.0, 1.0);
    float ownWeight = smoothstep(0.0, 0.5, ownCoverage);
    float coverage = ownCoverage;
    float width = ((pixelCells * 2.0) * _944.viewGeometry.y) / 1080.0;
    float weight = 1.0;
    float alliedBoundarySdf = -1000000.0;
    float alliedCoverage = 0.0;
    if (lookupParams.w > 0.5)
    {
        weight = ownWeight;
        if (circles)
        {
            vec2 param_4 = cellCoord;
            vec2 param_5 = worldPos.xz;
            float param_6 = max(0.3300000131130218505859375, width + pixelCells);
            alliedBoundarySdf = alliedCircleCells(param_4, param_5, param_6);
            alliedCoverage = 1.0;
        }
        else
        {
            vec2 param_7 = cellCoord;
            bool param_8 = true;
            float param_9;
            float _1144 = roundedCells(param_7, param_8, param_9);
            alliedBoundarySdf = param_9;
            alliedCoverage = _1144;
        }
        alliedCoverage *= clamp((alliedBoundarySdf / pixelCells) + 0.5, 0.0, 1.0);
        coverage = max(coverage, alliedCoverage);
    }
    vec2 cellXZ = (vec2(cell) + vec2(0.5)) * 32.0;
    float distN = length(cellXZ - radarcenter_range.xz) / radarcenter_range.w;
    float front = animParams.y * 10.0;
    float spawn = mix(min(animParams.y * 4.0, 1.0), smoothstep(distN - 0.100000001490116119384765625, distN + 0.0199999995529651641845703125, front), weight);
    if ((coverage < 0.039999999105930328369140625) || (spawn < 0.00999999977648258209228515625))
    {
        discard;
    }
    if (texture(modelDepths, screenUV).x < mapDepth)
    {
        discard;
    }
    float fade = (spawn * smoothstep(0.0, 0.5, coverage)) * mix(0.550000011920928955078125, 1.0, weight);
    float outerSdf = max((ownCoverage >= 0.039999999105930328369140625) ? ownBoundarySdf : (-1000000.0), (alliedCoverage >= 0.039999999105930328369140625) ? alliedBoundarySdf : (-1000000.0));
    float ownLine = (1.0 - smoothstep(0.0, width, ownBoundarySdf)) * ownWeight;
    float _1240 = (pixelCells < 4.0) ? max(ownLine, 1.0 - smoothstep(0.0, width, outerSdf)) : 0.0;
    float outline = _1240;
    float glow = 0.0;
    bool _1253 = weight > 0.0;
    if (_1253 ? (animParams.z > 0.5) : _1253)
    {
        vec2 param_10 = worldPos.xz - radarcenter_range.xz;
        float param_11 = animParams.x;
        glow = sheetGlow(param_10, param_11) * weight;
    }
    vec3 tint = mix(vec3(0.3499999940395355224609375, 0.62000000476837158203125, 0.5), vec3(0.2199999988079071044921875, 0.85000002384185791015625, 0.5), vec3(weight));
    vec3 fillColor = mix(tint, vec3(0.550000011920928955078125, 1.0, 0.699999988079071044921875), vec3(glow));
    float fillAlpha = min(0.20000000298023223876953125 * (1.0 + glow), 1.0);
    fragColor = vec4(mix(fillColor, vec3(0.449999988079071044921875, 1.0, 0.569999992847442626953125), vec3(outline)), mix(fillAlpha, 0.4000000059604644775390625, outline) * fade);
}

