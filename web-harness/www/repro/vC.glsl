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
    bool _144;
    if (!_130)
    {
        _144 = any(greaterThanEqual(texel, textureSize(coverageTex, 0)));
    }
    else
    {
        _144 = _130;
    }
    if (_144)
    {
        return vec2(-1.0);
    }
    return vec2(texelFetch(targetTex, texel, 0).x, texelFetch(coverageTex, texel, 0).x);
}

float alliedAt(ivec2 radarCell)
{
    bool _220 = lookupParams.w < 0.5;
    bool _227;
    if (!_220)
    {
        _227 = any(lessThan(radarCell, ivec2(0)));
    }
    else
    {
        _227 = _220;
    }
    bool _238;
    if (!_227)
    {
        _238 = any(greaterThanEqual(radarCell, textureSize(radarInfoTex, 0)));
    }
    else
    {
        _238 = _227;
    }
    if (_238)
    {
        return 0.0;
    }
    return step(0.5, texelFetch(radarInfoTex, radarCell, 0).x);
}

vec2 circleCoverageAt(ivec2 radarCell)
{
    ivec2 param = radarCell;
    vec2 coverage = previewCoverageAt(param);
    vec2 offset = vec2(radarCell - ivec2(lookupParams.xy));
    float dist = length(offset);
    bool _181 = coverage.x <= 0.0;
    bool _188;
    if (_181)
    {
        _188 = dist > lookupParams.z;
    }
    else
    {
        _188 = _181;
    }
    if (_188)
    {
        ivec2 inner = ivec2(lookupParams.xy) + ivec2(floor((offset * ((lookupParams.z - 0.75) / dist)) + vec2(0.5)));
        ivec2 param_1 = inner;
        coverage = previewCoverageAt(param_1);
    }
    return max(coverage, vec2(0.0));
}

vec2 boundaryCoverageAt(ivec2 cell, bool allied)
{
    if (allied)
    {
        ivec2 param = cell;
        return vec2(alliedAt(param));
    }
    vec2 _616;
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
    if (covered > 0.5)
    {
        float _336;
        if (neighbours.x < 0.5)
        {
            _336 = edgeDist.x;
        }
        else
        {
            _336 = 1000000.0;
        }
        float _348;
        if (neighbours.y < 0.5)
        {
            _348 = edgeDist.y;
        }
        else
        {
            _348 = 1000000.0;
        }
        vec2 sideDist = vec2(_336, _348);
        bool _358 = neighbours.x < 0.5;
        bool _364;
        if (_358)
        {
            _364 = neighbours.y > 0.5;
        }
        else
        {
            _364 = _358;
        }
        bool _370;
        if (_364)
        {
            _370 = neighbours.z > 0.5;
        }
        else
        {
            _370 = _364;
        }
        bool _377;
        if (_370)
        {
            _377 = edgeDist.y < radius;
        }
        else
        {
            _377 = _370;
        }
        if (_377)
        {
            sideDist.x = length(vec2(edgeDist.x + radius, edgeDist.y - radius)) - radius;
        }
        bool _395 = neighbours.y < 0.5;
        bool _401;
        if (_395)
        {
            _401 = neighbours.x > 0.5;
        }
        else
        {
            _401 = _395;
        }
        bool _407;
        if (_401)
        {
            _407 = neighbours.z > 0.5;
        }
        else
        {
            _407 = _401;
        }
        bool _414;
        if (_407)
        {
            _414 = edgeDist.x < radius;
        }
        else
        {
            _414 = _407;
        }
        if (_414)
        {
            sideDist.y = length(vec2(edgeDist.x - radius, edgeDist.y + radius)) - radius;
        }
        float sdf = min(sideDist.x, sideDist.y);
        bool _438 = neighbours.x < 0.5;
        bool _444;
        if (_438)
        {
            _444 = neighbours.y < 0.5;
        }
        else
        {
            _444 = _438;
        }
        bool _452;
        if (_444)
        {
            _452 = all(lessThan(edgeDist, vec2(radius)));
        }
        else
        {
            _452 = _444;
        }
        if (_452)
        {
            sdf = radius - length(edgeDist - vec2(radius));
        }
        return sdf;
    }
    float _468;
    if (neighbours.x > 0.5)
    {
        _468 = edgeDist.x;
    }
    else
    {
        _468 = 1000000.0;
    }
    float _478;
    if (neighbours.y > 0.5)
    {
        _478 = edgeDist.y;
    }
    else
    {
        _478 = 1000000.0;
    }
    vec2 sideDist_1 = vec2(_468, _478);
    bool _488 = neighbours.x > 0.5;
    bool _494;
    if (_488)
    {
        _494 = neighbours.z < 0.5;
    }
    else
    {
        _494 = _488;
    }
    bool _501;
    if (_494)
    {
        _501 = edgeDist.y < radius;
    }
    else
    {
        _501 = _494;
    }
    if (_501)
    {
        sideDist_1.x = length(vec2(edgeDist.x + radius, edgeDist.y - radius)) - radius;
    }
    bool _519 = neighbours.y > 0.5;
    bool _525;
    if (_519)
    {
        _525 = neighbours.z < 0.5;
    }
    else
    {
        _525 = _519;
    }
    bool _532;
    if (_525)
    {
        _532 = edgeDist.x < radius;
    }
    else
    {
        _532 = _525;
    }
    if (_532)
    {
        sideDist_1.y = length(vec2(edgeDist.x - radius, edgeDist.y + radius)) - radius;
    }
    float sdf_1 = -min(sideDist_1.x, sideDist_1.y);
    bool _557 = neighbours.x < 0.5;
    bool _563;
    if (_557)
    {
        _563 = neighbours.y < 0.5;
    }
    else
    {
        _563 = _557;
    }
    bool _569;
    if (_563)
    {
        _569 = neighbours.z > 0.5;
    }
    else
    {
        _569 = _563;
    }
    if (_569)
    {
        sdf_1 = radius - length(edgeDist + vec2(radius));
    }
    bool _583 = all(greaterThan(neighbours, vec3(0.5)));
    bool _591;
    if (_583)
    {
        _591 = all(lessThan(edgeDist, vec2(radius)));
    }
    else
    {
        _591 = _583;
    }
    if (_591)
    {
        sdf_1 = length(edgeDist - vec2(radius)) - radius;
    }
    return sdf_1;
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
    if (center.x > 0.5)
    {
        return center.y;
    }
    return max(nx.y * neighbours.x, max(nz.y * neighbours.y, nd.y * neighbours.z));
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
    uint param = uint(entry);
    vec4 circle = rcl_ssbo5_alliedCircles(param);
    return circle.z - distance(worldXZ, circle.xy);
}

float cellCircleDist(ivec2 radarCell, vec2 worldXZ)
{
    bool _270 = any(lessThan(radarCell, ivec2(0)));
    bool _281;
    if (!_270)
    {
        _281 = any(greaterThanEqual(radarCell, textureSize(alliedWinnerTex, 0)));
    }
    else
    {
        _281 = _270;
    }
    if (_281)
    {
        return -1000000.0;
    }
    float winner = texelFetch(alliedWinnerTex, radarCell, 0).x;
    if (winner < 0.5)
    {
        return -1000000.0;
    }
    float param = winner;
    vec2 param_1 = worldXZ;
    float dist = packedCircleDist(param, param_1);
    float runnerUp = texelFetch(alliedRunnerUpTex, radarCell, 0).x;
    if (runnerUp > 0.5)
    {
        float param_2 = runnerUp;
        vec2 param_3 = worldXZ;
        dist = max(dist, packedCircleDist(param_2, param_3));
    }
    return dist / 32.0;
}

float alliedCircleCells(vec2 coord, vec2 worldXZ, float reach)
{
    ivec2 cell = ivec2(floor(coord));
    vec2 inCell = fract(coord);
    vec2 edgeDist = vec2(0.5) - abs(inCell - vec2(0.5));
    ivec2 param = cell;
    vec2 param_1 = worldXZ;
    float own = cellCircleDist(param, param_1);
    if (all(greaterThan(edgeDist, vec2(reach))))
    {
        float _764;
        if (own > (-100000.0))
        {
            _764 = min(own, min(edgeDist.x, edgeDist.y));
        }
        else
        {
            _764 = -1000000.0;
        }
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
    float _866;
    if (true)
    {
        _866 = pow(0.5 + (0.5 * cos((phase * 2.0) * 3.1415927410125732421875)), 4.5);
    }
    else
    {
        _866 = pow(1.0 - phase, 4.5);
    }
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
    bool _999;
    if (_993)
    {
        _999 = camPos.y > 0.0;
    }
    else
    {
        _999 = _993;
    }
    if (_999)
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
    if (circles)
    {
        ownBoundarySdf = min(ownBoundarySdf, circleSdf / 32.0);
    }
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
    float _1240;
    if (pixelCells < 4.0)
    {
        _1240 = max(ownLine, 1.0 - smoothstep(0.0, width, outerSdf));
    }
    else
    {
        _1240 = 0.0;
    }
    float outline = _1240;
    float glow = 0.0;
    bool _1253 = weight > 0.0;
    bool _1259;
    if (_1253)
    {
        _1259 = animParams.z > 0.5;
    }
    else
    {
        _1259 = _1253;
    }
    if (_1259)
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

