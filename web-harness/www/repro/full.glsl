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
} _373;

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
} _529;

uniform vec4 previewParams;
uniform highp sampler2D coverageTex;
uniform highp sampler2D targetTex;
uniform vec2 alliedParams;
uniform highp sampler2D alliedTex;
uniform highp sampler2D alliedSdfTex;
uniform float alliedCircleCount;
uniform float alliedCircles[192];
uniform highp sampler2D mapDepths;
uniform float previewInactive;
uniform float circleMode;
uniform float fadeStrength;
uniform vec4 circleParams;
uniform vec2 emitterXZ;
uniform highp sampler2D modelDepths;
uniform float stippleOffset;

layout(location = 0) out vec4 fragColor;

vec2 thinOutline(vec2 width, vec2 pixel, float thin)
{
    return max(width * thin, min(width, pixel * 1.0));
}

float alliedCircleSdf(vec2 w)
{
    if (alliedParams.x < 0.5)
    {
        return -128.0;
    }
    float offMap = distance(w, clamp(w, vec2(0.0), _373.mapSize.xy));
    return (((texture(alliedSdfTex, w / _373.mapSize.xy).x - 0.5) * 2.0) * 128.0) - offMap;
}

float alliedExactSdf(vec2 w, out vec3 owner)
{
    owner = vec3(0.0, 0.0, -1.0);
    float best = -128.0;
    int count = int(alliedCircleCount);
    for (int i = 0; i < count; i++)
    {
        vec3 circle = vec3(alliedCircles[i * 3], alliedCircles[(i * 3) + 1], alliedCircles[(i * 3) + 2]);
        float inside = circle.z - distance(w, circle.xy);
        if (inside > best)
        {
            best = inside;
            owner = circle;
        }
    }
    return best;
}

ivec2 discTexel(ivec2 cell)
{
    int radius = int(previewParams.z);
    ivec2 texel = (cell - ivec2(previewParams.xy)) + ivec2(radius);
    bool _105 = radius < 0;
    bool _114;
    if (!_105)
    {
        _114 = any(lessThan(texel, ivec2(0)));
    }
    else
    {
        _114 = _105;
    }
    bool _127;
    if (!_114)
    {
        _127 = any(greaterThanEqual(texel, ivec2((2 * radius) + 1)));
    }
    else
    {
        _127 = _114;
    }
    if (_127)
    {
        return ivec2(-1);
    }
    return texel;
}

float previewCoverageAt(ivec2 cell)
{
    ivec2 param = cell;
    ivec2 texel = discTexel(param);
    float _144;
    if (texel.x < 0)
    {
        _144 = 0.0;
    }
    else
    {
        _144 = texelFetch(coverageTex, texel, 0).x;
    }
    return _144;
}

float previewTargetAt(ivec2 cell)
{
    ivec2 param = cell;
    ivec2 texel = discTexel(param);
    float _168;
    if (texel.x < 0)
    {
        _168 = 0.0;
    }
    else
    {
        _168 = step(0.5, texelFetch(targetTex, texel, 0).x);
    }
    return _168;
}

float alliedAt(ivec2 cell)
{
    bool _187 = alliedParams.x < 0.5;
    bool _194;
    if (!_187)
    {
        _194 = any(lessThan(cell, ivec2(0)));
    }
    else
    {
        _194 = _187;
    }
    bool _205;
    if (!_194)
    {
        _205 = any(greaterThanEqual(cell, textureSize(alliedTex, 0)));
    }
    else
    {
        _205 = _194;
    }
    if (_205)
    {
        return 0.0;
    }
    return step(0.5, texelFetch(alliedTex, cell, 0).x);
}

float edgeBand(float sdf, float width, float px)
{
    return smoothstep(-px, 0.0, sdf) * (1.0 - smoothstep(width - px, width, sdf));
}

float stipple(float coord, float rate)
{
    float periodsPerPixel = max(rate * 4.0, 9.9999997473787516355514526367188e-05);
    float dashes = smoothstep(0.5 - periodsPerPixel, 0.5 + periodsPerPixel, abs(fract(coord * 4.0) - 0.5) * 2.0);
    dashes = mix(dashes, 0.5, smoothstep(0.25, 0.5, periodsPerPixel));
    return mix(0.300000011920928955078125, 1.0, dashes);
}

float arcStipple(vec2 w, vec3 circle, float offset, float rate)
{
    float periods = max(1.0, floor((((6.283185482025146484375 * circle.z) * 4.0) / 32.0) + 0.5));
    float turns = atan(w.y - circle.y, w.x - circle.x) / 6.283185482025146484375;
    float param = ((turns * periods) / 4.0) - offset;
    float param_1 = rate;
    return stipple(param, param_1);
}

float cellOffMap(ivec2 cell)
{
    bool _334 = any(lessThan(cell, ivec2(0)));
    bool _344;
    if (!_334)
    {
        _344 = any(greaterThanEqual(cell, ivec2(192, 320)));
    }
    else
    {
        _344 = _334;
    }
    return float(_344);
}

void stipplesAt(vec2 cellCoord, vec2 nearSide, vec2 pixelCells, float offset, out vec2 sides, out float corner)
{
    float param = cellCoord.y - (((nearSide.x * 2.0) - 1.0) * offset);
    float param_1 = pixelCells.y;
    float param_2 = cellCoord.x + (((nearSide.y * 2.0) - 1.0) * offset);
    float param_3 = pixelCells.x;
    sides = vec2(stipple(param, param_1), stipple(param_2, param_3));
    float param_4 = offset;
    float param_5 = max(pixelCells.x, pixelCells.y);
    corner = stipple(param_4, param_5);
}

float borderLine(vec2 sides, float diagonalOut, vec2 edge, vec2 stipples, float cornerStipple)
{
    float line = max((sides.x * edge.x) * stipples.x, (sides.y * edge.y) * stipples.y);
    float corner = min(edge.x, edge.y) * max(sides.x * sides.y, ((1.0 - sides.x) * (1.0 - sides.y)) * diagonalOut);
    return mix(line, cornerStipple, corner);
}

void main()
{
    vec2 screenUV = (gl_FragCoord.xy - _373.viewGeometry.zw) / _373.viewGeometry.xy;
    float mapDepth = texture(mapDepths, screenUV).x;
    vec4 world = _529.cameraViewProjInv * vec4((screenUV * 2.0) - vec2(1.0), mapDepth, 1.0);
    vec3 worldPos = world.xyz / vec3(world.w);
    vec3 camPos = _529.cameraViewInv[3].xyz;
    bool _558 = worldPos.y < 0.0;
    bool _564;
    if (_558)
    {
        _564 = camPos.y > 0.0;
    }
    else
    {
        _564 = _558;
    }
    if (_564)
    {
        worldPos = mix(camPos, worldPos, vec3(camPos.y / (camPos.y - worldPos.y)));
    }
    vec2 cellCoord = worldPos.xz / vec2(32.0);
    vec2 cellPixels = fwidth(cellCoord);
    vec2 xGrad = vec2(dFdx(cellCoord.x), dFdy(cellCoord.x));
    vec2 zGrad = vec2(dFdx(cellCoord.y), dFdy(cellCoord.y));
    vec2 pixelCells = max(vec2(length(xGrad), length(zGrad)), vec2(9.9999997473787516355514526367188e-06));
    if (mapDepth >= 0.999998986721038818359375)
    {
        discard;
    }
    ivec2 cell = ivec2(floor(cellCoord));
    float inactive = previewInactive;
    bool circles = circleMode > 0.5;
    vec2 w = worldPos.xz;
    float px = max(pixelCells.x, pixelCells.y) * 32.0;
    float camDist = distance(camPos, worldPos);
    float distanceFade = 1.0 - (fadeStrength * smoothstep(4000.0, 8000.0, camDist));
    if (distanceFade <= 0.0)
    {
        discard;
    }
    float thin = mix(1.0, 0.60000002384185791015625, smoothstep(3000.0, 8000.0, camDist));
    float offMapDist = distance(w, clamp(w, vec2(0.0), _373.mapSize.xy));
    float mapFill = clamp(1.0 - (offMapDist / px), 0.0, 1.0);
    float mapLine = 1.0 - clamp(offMapDist / 50.0, 0.0, 1.0);
    float ownSdf = -128.0;
    float alliedSdf = -128.0;
    vec3 alliedOwner = vec3(0.0, 0.0, -1.0);
    float bandWidth = (((px * 1.2000000476837158203125) * _373.viewGeometry.y) / 1080.0) + 0.88999998569488525390625;
    vec2 param = vec2(bandWidth);
    vec2 param_1 = vec2(px);
    float param_2 = thin;
    bandWidth = thinOutline(param, param_1, param_2).x;
    float weight;
    float ownIn;
    float allied;
    if (circles)
    {
        float ownDist = distance(w, circleParams.xy);
        bool _720 = previewParams.z >= 0.0;
        bool _726;
        if (_720)
        {
            _726 = circleParams.z > 0.0;
        }
        else
        {
            _726 = _720;
        }
        if (_726)
        {
            ownSdf = circleParams.z - ownDist;
        }
        vec2 param_3 = w;
        alliedSdf = alliedCircleSdf(param_3);
        float nearEdge = (((bandWidth + (2.0 * px)) + 4.0) + 24.0) + 8.0;
        bool _751 = (alliedParams.x > 0.5) && (alliedCircleCount > 0.5);
        bool _761;
        if (_751)
        {
            _761 = (abs(alliedSdf) < nearEdge) || (offMapDist > 0.0);
        }
        else
        {
            _761 = _751;
        }
        if (_761)
        {
            vec2 param_4 = w;
            vec3 param_5;
            float _767 = alliedExactSdf(param_4, param_5);
            alliedOwner = param_5;
            alliedSdf = _767;
        }
        float distN = ownDist / max(circleParams.z, 1.0);
        float spawn = smoothstep(distN - 0.100000001490116119384765625, distN + 0.0199999995529651641845703125, previewParams.w * 18.0);
        float inside = clamp((ownSdf / px) + 0.5, 0.0, 1.0);
        weight = (inside * spawn) * circleParams.w;
        ownIn = inside * step(0.5, spawn);
        allied = clamp((alliedSdf / px) + 0.5, 0.0, 1.0);
    }
    else
    {
        float distN_1 = length(((vec2(cell) + vec2(0.5)) * 32.0) - emitterXZ) / (max(previewParams.z, 1.0) * 32.0);
        float spawn_1 = smoothstep(distN_1 - 0.100000001490116119384765625, distN_1 + 0.0199999995529651641845703125, previewParams.w * 18.0);
        ivec2 param_6 = cell;
        weight = smoothstep(0.0, 0.5, previewCoverageAt(param_6)) * spawn_1;
        ivec2 param_7 = cell;
        ownIn = step(0.5, min(previewTargetAt(param_7), spawn_1));
        ivec2 param_8 = cell;
        allied = alliedAt(param_8);
    }
    float alliedFade = (allied * alliedParams.y) * 0.85000002384185791015625;
    float fillFade = mix(mix(alliedFade, 1.0, weight), max(alliedFade, weight * 0.5), inactive) * mapFill;
    float jammedFade = max(alliedFade, (ownIn * weight) * (1.0 - inactive)) * mapLine;
    float ownLineFade = ((ownIn * weight) * mix(1.0, 0.4000000059604644775390625, inactive)) * mapLine;
    if (max(fillFade, max(jammedFade, ownLineFade)) < 0.039999999105930328369140625)
    {
        discard;
    }
    if (texture(modelDepths, screenUV).x < mapDepth)
    {
        discard;
    }
    float ownLine = 0.0;
    float coveredLine = 0.0;
    float outlineOn;
    if (circles)
    {
        outlineOn = (max(cellPixels.x, cellPixels.y) < 4.0) ? 0.800000011920928955078125 : 0.0;
        float rate = px / 32.0;
        float param_9 = ownSdf;
        float param_10 = bandWidth;
        float param_11 = px;
        ownLine = edgeBand(param_9, param_10, param_11);
        if ((ownLine > 0.0) && (outlineOn > 0.0))
        {
            vec2 param_12 = w;
            vec3 param_13 = circleParams.xyz;
            float param_14 = stippleOffset * (1.0 - inactive);
            float param_15 = rate;
            ownLine *= arcStipple(param_12, param_13, param_14, param_15);
        }
        float ownJamSdf = (inactive < 0.5) ? ownSdf : (-128.0);
        float param_16 = max(ownJamSdf, alliedSdf);
        float param_17 = bandWidth;
        float param_18 = px;
        coveredLine = edgeBand(param_16, param_17, param_18);
        if ((coveredLine > 0.0) && (outlineOn > 0.0))
        {
            vec3 _983;
            if (ownJamSdf >= alliedSdf)
            {
                _983 = circleParams.xyz;
            }
            else
            {
                _983 = alliedOwner;
            }
            vec3 owner = _983;
            float _994;
            if (owner.z > 0.0)
            {
                vec2 param_19 = w;
                vec3 param_20 = owner;
                float param_21 = stippleOffset;
                float param_22 = rate;
                _994 = arcStipple(param_19, param_20, param_21, param_22);
            }
            else
            {
                _994 = 1.0;
            }
            coveredLine *= _994;
        }
    }
    else
    {
        outlineOn = (max(cellPixels.x, cellPixels.y) < 1.0) ? 0.800000011920928955078125 : 0.0;
        vec2 inCell = fract(cellCoord);
        vec2 edgeDist = vec2(0.5) - abs(inCell - vec2(0.5));
        vec2 width = (((pixelCells * 1.2000000476837158203125) * _373.viewGeometry.y) / vec2(1080.0)) + vec2(0.0278124995529651641845703125);
        vec2 param_23 = width;
        vec2 param_24 = pixelCells;
        float param_25 = thin;
        width = thinOutline(param_23, param_24, param_25);
        bool _1047 = outlineOn > 0.0;
        bool _1054;
        if (_1047)
        {
            _1054 = any(lessThan(edgeDist, width));
        }
        else
        {
            _1054 = _1047;
        }
        if (_1054)
        {
            vec2 nearSide = step(vec2(0.5), inCell);
            ivec2 nx = cell + ivec2((int(nearSide.x) * 2) - 1, 0);
            ivec2 nz = cell + ivec2(0, (int(nearSide.y) * 2) - 1);
            ivec2 nd = ivec2(nx.x, nz.y);
            ivec2 param_26 = nx;
            ivec2 param_27 = nz;
            ivec2 param_28 = nd;
            vec3 offMapNeighbours = vec3(cellOffMap(param_26), cellOffMap(param_27), cellOffMap(param_28));
            ivec2 param_29 = nx;
            ivec2 param_30 = nz;
            ivec2 param_31 = nd;
            vec3 ownNeighbours = max(vec3(previewTargetAt(param_29), previewTargetAt(param_30), previewTargetAt(param_31)), offMapNeighbours);
            ivec2 param_32 = nx;
            ivec2 param_33 = nz;
            ivec2 param_34 = nd;
            vec3 alliedNeighbours = max(vec3(alliedAt(param_32), alliedAt(param_33), alliedAt(param_34)), offMapNeighbours);
            vec3 ownOut = (vec3(1.0) - ownNeighbours) * ownIn;
            vec3 coveredOut = vec3(1.0) - max(ownNeighbours * (1.0 - inactive), alliedNeighbours);
            vec2 edge = vec2(1.0) - smoothstep(width - pixelCells, width, edgeDist);
            vec2 param_35 = cellCoord;
            vec2 param_36 = nearSide;
            vec2 param_37 = pixelCells;
            float param_38 = stippleOffset;
            vec2 param_39;
            float param_40;
            stipplesAt(param_35, param_36, param_37, param_38, param_39, param_40);
            vec2 stipples = param_39;
            float cornerStipple = param_40;
            vec2 param_41 = cellCoord;
            vec2 param_42 = nearSide;
            vec2 param_43 = pixelCells;
            float param_44 = stippleOffset * (1.0 - inactive);
            vec2 param_45;
            float param_46;
            stipplesAt(param_41, param_42, param_43, param_44, param_45, param_46);
            vec2 ownStipples = param_45;
            float ownCornerStipple = param_46;
            vec2 param_47 = ownOut.xy;
            float param_48 = ownOut.z;
            vec2 param_49 = edge;
            vec2 param_50 = ownStipples;
            float param_51 = ownCornerStipple;
            ownLine = borderLine(param_47, param_48, param_49, param_50, param_51);
            vec2 param_52 = coveredOut.xy;
            float param_53 = coveredOut.z;
            vec2 param_54 = edge;
            vec2 param_55 = stipples;
            float param_56 = cornerStipple;
            coveredLine = borderLine(param_52, param_53, param_54, param_55, param_56);
        }
    }
    float lineAlpha = max(ownLine * ownLineFade, coveredLine * jammedFade) * outlineOn;
    vec3 fillColor = mix(vec3(0.62000000476837158203125, 0.3499999940395355224609375, 0.3300000131130218505859375), vec3(0.89999997615814208984375, 0.2199999988079071044921875, 0.20000000298023223876953125), vec3(weight * (1.0 - (inactive * allied))));
    float fillAlpha = (0.17000000178813934326171875 * fillFade) * (1.0 - lineAlpha);
    float alpha = lineAlpha + fillAlpha;
    fragColor = vec4(((vec3(1.0, 0.319999992847442626953125, 0.2199999988079071044921875) * lineAlpha) + (fillColor * fillAlpha)) / vec3(max(alpha, 9.9999997473787516355514526367188e-05)), alpha * distanceFade);
}


