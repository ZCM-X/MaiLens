#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FisheyeUniforms {
    float4 rotation0;
    float4 rotation1;
    float4 rotation2;
    float2 sourceSize;
    float2 destinationSize;
    float2 centerNormalized;
    float cropZoom;
    float focalX;
    float focalY;
    float horizontalFOVRadians;
    float k1;
    float k2;
    float correctionEnabled;
    float gimbalActive;
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

    // The virtual gimbal reserves a fixed border around the locked view.
    // Its full 3D pose is applied below, so there is no separate 2D horizon
    // rotation or machine-detection crop in this render path.
    float2 rectifiedUV = 0.5 + (in.uv - 0.5) / max(u.cropZoom, 0.01);

    // Preserve the old raw-lens preview when no virtual gimbal is active. If
    // the gimbal is active, continue through the ray path below so yaw/pitch/
    // roll are still compensated even while correction is being previewed off.
    if (u.correctionEnabled < 0.5 && u.gimbalActive < 0.5) {
        if (any(rectifiedUV < 0.0) || any(rectifiedUV > 1.0)) {
            return float4(0.025, 0.035, 0.04, 1.0);
        }
        return cameraFrame.sample(linearSampler, rectifiedUV);
    }

    // Build a ray in the locked pinhole camera, then rotate that ray into the
    // current sensor camera. This is the crucial difference from a 2D crop:
    // the same world direction remains in the centre through roll, pitch, and
    // yaw, including diagonal movements.
    float virtualFocal = u.destinationSize.x / (2.0 * tan(u.horizontalFOVRadians * 0.5));
    float2 lockedPixels = (rectifiedUV - 0.5) * u.destinationSize;
    float2 rectilinear = lockedPixels / max(virtualFocal, 1.0);
    float3 rayLocked = normalize(float3(rectilinear.x, rectilinear.y, 1.0));
    float3x3 cameraFromLocked = float3x3(u.rotation0.xyz,
                                         u.rotation1.xyz,
                                         u.rotation2.xyz);
    float3 raySource = normalize(cameraFromLocked * rayLocked);

    float radial = length(raySource.xy);
    float theta = acos(clamp(raySource.z, -1.0, 1.0));
    float theta2 = theta * theta;
    float thetaDistorted = theta * (1.0 + u.k1 * theta2 + u.k2 * theta2 * theta2);
    float2 direction = radial > 0.000001 ? raySource.xy / radial : float2(0.0);
    float2 centerPixel = u.centerNormalized * u.sourceSize;
    float2 sourcePosition = centerPixel + float2(
        u.focalX * direction.x * thetaDistorted,
        u.focalY * direction.y * thetaDistorted
    );
    float2 sourceUV = sourcePosition / u.sourceSize;

    if (any(sourceUV < 0.0) || any(sourceUV > 1.0)) {
        return float4(0.025, 0.035, 0.04, 1.0);
    }
    return cameraFrame.sample(linearSampler, sourceUV);
}
