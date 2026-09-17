import "common";
import "bindless";

struct PS_Input {
    float2 uv : TEXCOORD0;
};

struct PS_Params {
    TextureHandle2D<float4> texture;
    SamplerHandle sampler;
};

[vk::push_constant]
PixelParams<PS_Params> p;


float3 linear_to_srgb(float3 x) {
    x = saturate(x);

    float3 lo = x * 12.92;

    float3 hi =
        1.055 *
        pow(
            x,
            float3(1.0 / 2.4)
        )
        - 0.055;

    return float3(
        x.r <= 0.0031308 ? lo.r : hi.r,
        x.g <= 0.0031308 ? lo.g : hi.g,
        x.b <= 0.0031308 ? lo.b : hi.b
    );
}


[shader("pixel")]
float4 main(PS_Input input) : SV_Target0 {
    PS_Params params = *p.get();

    float4 texel =
        params.texture.Sample(
            params.sampler,
            input.uv
        );

    return float4(
        linear_to_srgb(texel.rgb),
        texel.a
    );
}
