import "common";
import "bindless";

// Must match Mesh_Pixel_Params in src/render/scene.jai.
struct Pixel_Params {
    TextureHandle2D<float4> diffuse;
    SamplerHandle sampler;
    float3 light_direction;   // Towards the light, world space, normalized.
    float ambient;
};

struct PS_Input {
    float3 world_normal : NORMAL;
    float2 uv           : TEXCOORD0;
};

[vk::push_constant]
PixelParams<Pixel_Params> pp;

// The swapchain is a UNORM target, so we must encode to sRGB ourselves.
float3 linear_to_srgb(float3 x) {
    x = saturate(x);
    float3 lo = x * 12.92;
    float3 hi = 1.055 * pow(x, float3(1.0 / 2.4)) - 0.055;
    return float3(
        x.r <= 0.0031308 ? lo.r : hi.r,
        x.g <= 0.0031308 ? lo.g : hi.g,
        x.b <= 0.0031308 ? lo.b : hi.b
    );
}

[shader("pixel")]
float4 main(PS_Input input, bool front_face : SV_IsFrontFace) : SV_Target0 {
    Pixel_Params p = *pp.get();

    // The texture is R8G8B8A8_SRGB, so Sample() already returns linear values.
    float3 albedo = p.diffuse.Sample(p.sampler, input.uv).rgb;

    float3 n = normalize(input.world_normal);
    if (!front_face) n = -n;   // Only matters while culling is off.

    // Placeholder lighting until phase 4: Lambert diffuse plus a flat ambient term.
    float n_dot_l = max(dot(n, p.light_direction), 0.0);
    float3 color = albedo * (p.ambient + n_dot_l);

    return float4(linear_to_srgb(color), 1.0);
}
