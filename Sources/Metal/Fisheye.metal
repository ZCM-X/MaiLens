#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FisheyeUniforms {
    float2 sourceSize;
    float2 destinationSize;
    float2 centerNormalized;
    float2 cropCenterNormalized;
    float cropZoom;
    float focalX;
    float focalY;
    float horizontalFOVRadians;
    float k1;
    float k2;
    float correctionEnabled;
};

vertex VertexOut fisheyeVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
    };
    VertexOut out;
    float2 position = positions[vertexID];
    out.position = float4(position, 0.0, 1.0);
    out.uv = float2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
    return out;
}

fragment float4 fisheyeFragment(
    VertexOut in [[stage_in]],
    texture2d<float> cameraFrame [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant FisheyeUniforms& u [[buffer(0)]]) {

    float2 rectifiedUV = u.cropCenterNormalized + (in.uv - 0.5) / max(u.cropZoom, 0.01);

    if (u.correctionEnabled < 0.5) {
        if (any(rectifiedUV < 0.0) || any(rectifiedUV > 1.0)) {
            return float4(0.025, 0.035, 0.04, 1.0);
        }
        return cameraFrame.sample(linearSampler, rectifiedUV);
    }

    float2 destinationPixel = rectifiedUV * u.destinationSize;
    float2 destinationCenter = u.destinationSize * 0.5;
    float virtualFocal = u.destinationSize.x / (2.0 * tan(u.horizontalFOVRadians * 0.5));

    float2 rectilinear = (destinationPixel - destinationCenter) / max(virtualFocal, 1.0);
    float radius = length(rectilinear);
    float theta = atan(radius);
    float theta2 = theta * theta;
    float thetaDistorted = theta * (1.0 + u.k1 * theta2 + u.k2 * theta2 * theta2);
    float radialScale = radius > 0.000001 ? thetaDistorted / radius : 1.0;

    float2 centerPixel = u.centerNormalized * u.sourceSize;
    float2 sourcePosition = centerPixel + float2(
        u.focalX * rectilinear.x * radialScale,
        u.focalY * rectilinear.y * radialScale
    );
    float2 sourceUV = sourcePosition / u.sourceSize;

    if (any(sourceUV < 0.0) || any(sourceUV > 1.0)) {
        return float4(0.025, 0.035, 0.04, 1.0);
    }
    return cameraFrame.sample(linearSampler, sourceUV);
}
