/// Metal shader source, compiled at runtime with `MTLDevice.makeLibrary(source:)`. This avoids a
/// build-time dependency on the separately downloaded Metal toolchain of Xcode 26 on CI.
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexParams {
        float2 imageSize;
        float2 viewSize;
    };

    struct FragmentParams {
        float black;
        float white;
        float invGamma;
        float red;
        float color;
        float pad0;
        float pad1;
        float pad2;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Triangle strip over the image rectangle. The 3x3 display transform (image pixels ->
    // screen points, D-10) is applied here; the fragment stage only samples and stretches.
    vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                 constant float3x3 &transform [[buffer(0)]],
                                 constant VertexParams &vp [[buffer(1)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1));
        // Pixel i has its centre at coordinate i, so the image rectangle starts at -0.5.
        float2 p = corner * vp.imageSize - 0.5;
        float3 q = transform * float3(p, 1.0);
        VertexOut out;
        out.position = float4(q.x / vp.viewSize.x * 2.0 - 1.0, 1.0 - q.y / vp.viewSize.y * 2.0, 0.0, 1.0);
        out.uv = corner;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  texture2d<float> lumaTexture [[texture(0)]],
                                  texture2d<float> chromaTexture [[texture(1)]],
                                  constant FragmentParams &fp [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = lumaTexture.sample(s, in.uv).r;
        float3 rgb = float3(y);
        if (fp.color > 0.5) {
            float2 cbcr = chromaTexture.sample(s, in.uv).rg - 0.5;
            rgb = float3(y + 1.402 * cbcr.y,
                         y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
                         y + 1.772 * cbcr.x);
        }
        float range = max(fp.white - fp.black, 0.0001);
        rgb = clamp((rgb - fp.black) / range, 0.0, 1.0);
        rgb = pow(rgb, float3(fp.invGamma));
        if (fp.red > 0.5) {
            float l = dot(rgb, float3(0.299, 0.587, 0.114));
            rgb = float3(l, 0.0, 0.0);
        }
        return float4(rgb, 1.0);
    }
    """
}
