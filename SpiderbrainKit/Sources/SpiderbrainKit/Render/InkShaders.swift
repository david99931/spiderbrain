import Foundation

/// Shader source, compiled at runtime.
///
/// A `.metal` file in the package would be precompiled and marginally faster to
/// start, but it adds a build-system dependency that is easy to get wrong. For a
/// spike whose job is to answer "does the ink feel right", runtime compilation
/// costs a few milliseconds once and removes a whole class of setup failure.
/// Move this to a `.metal` file before shipping.
enum InkShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // MUST stay byte-compatible with Swift's InkVertex (five contiguous Floats,
    // stride 20). Plain float2/float3 would NOT match: Metal aligns float3 to 16
    // bytes, making this struct 32 bytes, and every vertex after the first would
    // read garbage. The packed_ types are 4-byte aligned, so 8 + 12 = 20.
    struct InkVertex {
        packed_float2 position;
        packed_float3 color;
    };

    struct Uniforms {
        float2 viewportSize;  // in points
    };

    struct RasterData {
        float4 position [[position]];
        float3 color;
    };

    // Ink pass: view points -> normalised device coordinates.
    // UIKit is y-down and NDC is y-up, so y is flipped here.
    vertex RasterData ink_vertex(uint id [[vertex_id]],
                                 constant InkVertex *vertices [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        InkVertex in = vertices[id];
        RasterData out;
        float x = (in.position.x / uniforms.viewportSize.x) * 2.0 - 1.0;
        float y = 1.0 - (in.position.y / uniforms.viewportSize.y) * 2.0;
        out.position = float4(x, y, 0.0, 1.0);
        out.color = in.color;
        return out;
    }

    // Written fully opaque. Overlap within a stroke therefore writes the same value
    // twice instead of compounding alpha, which is the whole point of the two-pass
    // approach.
    fragment float4 ink_fragment(RasterData in [[stage_in]]) {
        return float4(in.color, 1.0);
    }

    struct CompositeData {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle. No vertex buffer needed.
    vertex CompositeData composite_vertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        CompositeData out;
        out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(uv.x, 1.0 - uv.y);
        return out;
    }

    // The ink layer is composited exactly once, at the stroke's real alpha.
    //
    // The resolve texture is ALREADY premultiplied: covered MSAA samples wrote
    // (color, 1) and uncovered ones kept the transparent clear, so resolving a
    // half-covered texel averages to (color * 0.5, 0.5). Multiplying by ink.a
    // again here would darken every antialiased edge.
    fragment float4 composite_fragment(CompositeData in [[stage_in]],
                                       texture2d<float> inkLayer [[texture(0)]],
                                       constant float &alpha [[buffer(0)]]) {
        constexpr sampler linearSampler(mag_filter::linear, min_filter::linear);
        float4 ink = inkLayer.sample(linearSampler, in.uv);
        return ink * alpha;
    }
    """
}
