import "common";

[[vk::binding(0, 0)]] Texture2D<float4> textures[];
[[vk::binding(2, 0)]] SamplerState samplers[];

struct Pixel_Parameters {
    uint texture_index;
    uint sampler_index;
};

struct PS_Input {
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

[vk::push_constant]
PixelParams<Pixel_Parameters> parameters;

[shader("pixel")]
float4 main(PS_Input input) : SV_Target0 {
    Pixel_Parameters p = *parameters.get();
    return input.color * textures[p.texture_index].Sample(samplers[p.sampler_index], input.uv);
}
