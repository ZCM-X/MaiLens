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
    float4 rotationTop0;
    float4 rotationTop1;
    float4 rotationTop2;
    float4 rotationBottom0;
    float4 rotationBottom1;
    float4 rotationBottom2;
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
    float machineZoom;
    float machineActive;
    float4 machineViewRight;
    float4 machineViewDown;
    float4 machineViewForward;
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

    // Render one rectilinear virtual-camera view, then rotate each ray toward
    // the tracked screen centre and through the gimbal pose before the inverse
    // fisheye map. This reframes the lens view without stretching the image.
    float2 viewOffsetPixels = (in.uv - 0.5) * u.destinationSize;
    viewOffsetPixels /= max(u.machineZoom, 0.01);
    viewOffsetPixels /= max(u.cropZoom, 0.01);

    // Preserve the true raw-lens view only when neither stabilization path is
    // active. Machine lock still needs ray projection when lens tuning is off.
    if (u.correctionEnabled < 0.5 && u.gimbalActive < 0.5 && u.machineActive < 0.5) {
        return cameraFrame.sample(linearSampler, in.uv);
    }

    // Build a ray in the output pinhole camera. Machine lock turns this camera
    // toward the detected display centre; the gimbal then maps it to the live
    // sensor direction, preserving perspective during yaw and pitch.
    float virtualFocal = u.destinationSize.x / (2.0 * tan(u.horizontalFOVRadians * 0.5));
    float2 rectilinear = viewOffsetPixels / max(virtualFocal, 1.0);
    float3 rayOutput = normalize(float3(rectilinear.x, rectilinear.y, 1.0));
    float3x3 lockedFromMachine = float3x3(u.machineViewRight.xyz,
                                          u.machineViewDown.xyz,
                                          u.machineViewForward.xyz);
    float3 rayLocked = normalize(lockedFromMachine * rayOutput);
    float3x3 cameraFromLockedTop = float3x3(u.rotationTop0.xyz,
                                            u.rotationTop1.xyz,
                                            u.rotationTop2.xyz);
    float3x3 cameraFromLockedBottom = float3x3(u.rotationBottom0.xyz,
                                               u.rotationBottom1.xyz,
                                               u.rotationBottom2.xyz);
    float3x3 cameraFromLocked = float3x3(
        mix(cameraFromLockedTop[0], cameraFromLockedBottom[0], in.uv.y),
        mix(cameraFromLockedTop[1], cameraFromLockedBottom[1], in.uv.y),
        mix(cameraFromLockedTop[2], cameraFromLockedBottom[2], in.uv.y)
    );
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
