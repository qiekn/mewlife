import "common";
import "bindless";

// 必须与 src/render/renderer.jai 里的 Point_Light / Scene_Params 一致（与 pbr_vs.slang 相同）。
struct Point_Light {
    float3 position;
    float radius;
    float3 color;
    float intensity;
};

struct Scene_Params {
    float4x4 view_projection;
    float3 camera_position;
    uint point_light_count;
    float3 sun_direction;
    float sun_intensity;
    float3 sun_color;
    float ambient_intensity;
    float3 ambient_color;
    float exposure;
    Point_Light point_lights[4];
    uint tone_mapping;   // 0 无，1 Reinhard，2 ACES
    uint debug_view;     // 0 正常，1 法线，2 基础色，3 金属度，4 粗糙度，5 AO，6 自发光，7 uv
    uint2 padding;
};

// 材质标志位。
static const uint MATERIAL_HAS_BASE_COLOR_MAP = 1 << 0;
static const uint MATERIAL_HAS_METALLIC_ROUGHNESS_MAP = 1 << 1;
static const uint MATERIAL_HAS_NORMAL_MAP = 1 << 2;
static const uint MATERIAL_HAS_OCCLUSION_MAP = 1 << 3;
static const uint MATERIAL_HAS_EMISSIVE_MAP = 1 << 4;
static const uint MATERIAL_UNLIT = 1 << 5;
static const uint MATERIAL_DOUBLE_SIDED = 1 << 6;

// 必须与 renderer.jai 的 Material_Params 一致。
struct Material_Params {
    float4 base_color;
    float3 emissive;
    float emissive_strength;
    float metallic;
    float roughness;
    float normal_scale;
    float occlusion_strength;
    TextureHandle2D<float4> base_color_map;
    TextureHandle2D<float4> metallic_roughness_map;
    TextureHandle2D<float4> normal_map;
    TextureHandle2D<float4> occlusion_map;
    TextureHandle2D<float4> emissive_map;
    SamplerHandle sampler;
    uint flags;
    uint padding;
};

// 必须与 renderer.jai 的 Pixel_Params 一致。
struct Pixel_Params {
    Scene_Params* scene;
    Material_Params material;
};

struct PS_Input {
    float3 world_position : TEXCOORD0;
    float3 world_normal   : TEXCOORD1;
    float2 uv             : TEXCOORD2;
    float4 world_tangent  : TEXCOORD3;
    float4 color          : COLOR0;
};

[vk::push_constant]
PixelParams<Pixel_Params> pp;

static const float PI = 3.14159265359;

// ----------------------------------------------------------------------------: Cook-Torrance BRDF
//
// 微表面模型：把表面看成无数朝向各异的微小镜面。三项相乘：
//   D：有多少微表面正好朝向半程向量 h（GGX 分布，粗糙度越大越分散）
//   G：微表面之间的相互遮挡（Smith-Schlick）
//   F：菲涅尔，掠射角反射增强（Schlick 近似）

float distribution_ggx(float n_dot_h, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float d = n_dot_h * n_dot_h * (a2 - 1) + 1;
    return a2 / (PI * d * d);
}

float geometry_schlick_ggx(float n_dot_x, float roughness) {
    float r = roughness + 1;
    float k = r * r / 8;   // 直接光的 k 取法
    return n_dot_x / (n_dot_x * (1 - k) + k);
}

float geometry_smith(float n_dot_v, float n_dot_l, float roughness) {
    return geometry_schlick_ggx(n_dot_v, roughness) * geometry_schlick_ggx(n_dot_l, roughness);
}

float3 fresnel_schlick(float cos_theta, float3 f0) {
    return f0 + (1 - f0) * pow(saturate(1 - cos_theta), 5);
}

// 单个光源的贡献。l 指向光源，radiance 是到达表面的入射辐射度。
float3 shade_light(float3 n, float3 v, float3 l, float3 radiance, float3 albedo, float metallic, float roughness, float3 f0) {
    float3 h = normalize(v + l);
    float n_dot_l = saturate(dot(n, l));
    float n_dot_v = max(dot(n, v), 0.0001);
    float n_dot_h = saturate(dot(n, h));
    float h_dot_v = saturate(dot(h, v));

    float d = distribution_ggx(n_dot_h, roughness);
    float g = geometry_smith(n_dot_v, n_dot_l, roughness);
    float3 f = fresnel_schlick(h_dot_v, f0);

    float3 specular = d * g * f / (4 * n_dot_v * n_dot_l + 0.0001);
    // 能量守恒：被镜面反射掉的部分不再进入漫反射；金属没有漫反射。
    float3 kd = (1 - f) * (1 - metallic);
    return (kd * albedo / PI + specular) * radiance * n_dot_l;
}

// ----------------------------------------------------------------------------: 色调映射与输出编码

float3 tonemap_reinhard(float3 x) { return x / (1 + x); }

// Krzysztof Narkowicz 的 ACES 拟合。
float3 tonemap_aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// 交换链是 UNORM，需要手动编码到 sRGB。
float3 linear_to_srgb(float3 x) {
    x = saturate(x);
    float3 lo = x * 12.92;
    float3 hi = 1.055 * pow(x, float3(1.0 / 2.4)) - 0.055;
    return float3(x.r <= 0.0031308 ? lo.r : hi.r,
                  x.g <= 0.0031308 ? lo.g : hi.g,
                  x.b <= 0.0031308 ? lo.b : hi.b);
}

[shader("pixel")]
float4 main(PS_Input input, bool front_face : SV_IsFrontFace) : SV_Target0 {
    Pixel_Params p = *pp.get();
    Material_Params m = p.material;
    Scene_Params scene = *p.scene;

    // 材质采样。贴图缺失时用因子本身。
    float4 base_color = m.base_color * input.color;
    if ((m.flags & MATERIAL_HAS_BASE_COLOR_MAP) != 0) base_color *= m.base_color_map.Sample(m.sampler, input.uv);

    float metallic = m.metallic;
    float roughness = m.roughness;
    if ((m.flags & MATERIAL_HAS_METALLIC_ROUGHNESS_MAP) != 0) {
        // glTF 约定：G 通道粗糙度，B 通道金属度。
        float4 mr = m.metallic_roughness_map.Sample(m.sampler, input.uv);
        roughness *= mr.g;
        metallic *= mr.b;
    }
    roughness = clamp(roughness, 0.04, 1);   // 0 粗糙度会让 GGX 退化成无穷窄的尖峰

    float ao = 1;
    if ((m.flags & MATERIAL_HAS_OCCLUSION_MAP) != 0) {
        ao = lerp(1, m.occlusion_map.Sample(m.sampler, input.uv).r, m.occlusion_strength);
    }

    float3 emissive = m.emissive * m.emissive_strength;
    if ((m.flags & MATERIAL_HAS_EMISSIVE_MAP) != 0) emissive *= m.emissive_map.Sample(m.sampler, input.uv).rgb;

    // 法线：几何法线，或用切线空间法线贴图扰动。
    float3 n = normalize(input.world_normal);
    if ((m.flags & MATERIAL_DOUBLE_SIDED) != 0 && !front_face) n = -n;
    if ((m.flags & MATERIAL_HAS_NORMAL_MAP) != 0) {
        float3 sampled = m.normal_map.Sample(m.sampler, input.uv).xyz * 2 - 1;
        sampled.xy *= m.normal_scale;
        float3 t = normalize(input.world_tangent.xyz);
        t = normalize(t - n * dot(n, t));   // 插值后重新正交化
        float3 b = cross(n, t) * input.world_tangent.w;
        n = normalize(t * sampled.x + b * sampled.y + n * sampled.z);
    }

    if ((m.flags & MATERIAL_UNLIT) != 0) return float4(linear_to_srgb(base_color.rgb), base_color.a);

    // 调试视图：直接输出中间量，便于逐项检查。
    if (scene.debug_view != 0) {
        float3 dbg = 0;
        if (scene.debug_view == 1) dbg = n * 0.5 + 0.5;
        else if (scene.debug_view == 2) dbg = base_color.rgb;
        else if (scene.debug_view == 3) dbg = float3(metallic);
        else if (scene.debug_view == 4) dbg = float3(roughness);
        else if (scene.debug_view == 5) dbg = float3(ao);
        else if (scene.debug_view == 6) dbg = emissive;
        else if (scene.debug_view == 7) dbg = float3(frac(input.uv), 0);
        return float4(linear_to_srgb(dbg), 1);
    }

    float3 v = normalize(scene.camera_position - input.world_position);
    float3 albedo = base_color.rgb;
    // 非金属的基础反射率约 4%；金属的 F0 就是它的颜色。
    float3 f0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);

    float3 lo = 0;
    // 平行光（太阳）。
    lo += shade_light(n, v, normalize(scene.sun_direction), scene.sun_color * scene.sun_intensity,
                      albedo, metallic, roughness, f0);
    // 点光源：平方反比衰减，并在 radius 处平滑截断，避免无限远的影响。
    for (uint i = 0; i < scene.point_light_count; ++i) {
        Point_Light light = scene.point_lights[i];
        float3 to_light = light.position - input.world_position;
        float distance2 = max(dot(to_light, to_light), 0.0001);
        float distance = sqrt(distance2);
        float window = saturate(1 - pow(distance / max(light.radius, 0.001), 4));
        float attenuation = window * window / distance2;
        lo += shade_light(n, v, to_light / distance, light.color * light.intensity * attenuation,
                          albedo, metallic, roughness, f0);
    }

    // 环境光：没有 IBL 之前用一个常数近似，仍然让菲涅尔影响漫反射/镜面的比例。
    float3 f_ambient = fresnel_schlick(max(dot(n, v), 0), f0);
    float3 kd = (1 - f_ambient) * (1 - metallic);
    float3 ambient = scene.ambient_color * scene.ambient_intensity * (kd * albedo + f_ambient * 0.5) * ao;

    float3 color = (ambient + lo) * scene.exposure + emissive;
    if (scene.tone_mapping == 1) color = tonemap_reinhard(color);
    else if (scene.tone_mapping == 2) color = tonemap_aces(color);

    return float4(linear_to_srgb(color), base_color.a);
}
