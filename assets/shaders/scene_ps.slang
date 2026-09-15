import "common";

[[vk::binding(0, 0)]] Texture2D<float4> textures[];
[[vk::binding(2, 0)]] SamplerState samplers[];

struct Pixel_Parameters {
    float4 color;
    float3 eye;
    uint texture_index;
    uint sampler_index;
    uint surface;
    uint textured;
    uint padding;
    float3 rim_color;
    float emissive;
};

struct PS_Input {
    float3 world_position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float4 color : COLOR0;
};

[vk::push_constant]
PixelParams<Pixel_Parameters> parameters;

[shader("pixel")]
float4 main(PS_Input input, bool front_face : SV_IsFrontFace) : SV_Target0 {
    Pixel_Parameters p = *parameters.get();
    float3 albedo = p.color.rgb * input.color.rgb;
    if (p.surface == 2) return float4(pow(saturate(albedo), 1.0 / 2.2), 1);
    float3 texel = 1;
    if (p.textured != 0) {
        // Source UVs point up; PNG rows point down. Alpha contains material data, not opacity.
        texel = textures[p.texture_index].Sample(samplers[p.sampler_index], float2(input.uv.x, 1 - input.uv.y)).rgb;
        albedo *= texel;
    }
    float3 normal = normalize(input.normal);
    if (!front_face) normal = -normal;
    float key = max(dot(normal, normalize(float3(-0.5, 1, 0.8))), 0);
    float fill = max(dot(normal, normalize(float3(0.8, 0.3, -0.6))), 0);
    float3 light = 0.36 + key * float3(0.70, 0.65, 0.55) + fill * float3(0.13, 0.17, 0.24);
    float3 color = albedo * light;
    if (p.surface == 1) {
        // A small opaque crystal material: original diffuse facets, core tint, rim and emission.
        float3 view = normalize(p.eye - input.world_position);
        float rim = pow(1 - saturate(dot(normal, view)), 3);
        float3 halfway = normalize(view + normalize(float3(-0.5, 1, 0.8)));
        float specular = pow(saturate(dot(normal, halfway)), 48);
        color = lerp(color, p.rim_color * texel, rim * 0.65) + albedo * p.emissive + specular * 0.35;
    }
    // The root SGPU surface and offscreen checks use UNORM color attachments.
    return float4(pow(saturate(color), 1.0 / 2.2), 1);
}
