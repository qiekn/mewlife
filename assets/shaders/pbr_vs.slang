import "common";

// 必须与 src/render/renderer.jai 里的 Vertex 逐字节一致（scalar 布局，无填充）。
// 静态网格和蒙皮网格共用一种顶点：权重全零、joints 全 0xffffffff 表示不蒙皮。
struct Vertex {
    float3 position;
    float3 normal;
    float2 uv;
    float4 tangent;   // xyz 切线，w 副切线符号
    float4 weights;
    uint4  joints;
};

// 实例化绘制时每个实例自己的矩阵和颜色。
struct Instance {
    float4x4 model;
    float4 color;
};

// 必须与 renderer.jai 的 Scene_Params 一致。
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
    float3 sun_direction;     // 指向光源，已归一化
    float sun_intensity;
    float3 sun_color;
    float ambient_intensity;
    float3 ambient_color;
    float exposure;
    Point_Light point_lights[4];
    uint tone_mapping;
    uint debug_view;
    uint2 padding;
};

// 必须与 renderer.jai 的 Vertex_Params 一致。
struct Vertex_Params {
    Scene_Params* scene;
    Vertex* vertices;
    float4x4* skinning;       // skinned != 0 时有效
    Instance* instances;      // instanced != 0 时有效
    float4x4 model;
    float4x4 normal_matrix;   // model 的逆转置；实例化时改用实例矩阵的 3x3（假定均匀缩放）
    uint skinned;
    uint instanced;
    uint2 padding;
};

struct VS_Output {
    float4 position       : SV_POSITION;
    float3 world_position : TEXCOORD0;
    float3 world_normal   : TEXCOORD1;
    float2 uv             : TEXCOORD2;
    float4 world_tangent  : TEXCOORD3;
    float4 color          : COLOR0;
};

[vk::push_constant]
VertexParams<Vertex_Params> vp;

[shader("vertex")]
VS_Output main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    Vertex_Params p = *vp.get();
    Vertex v = p.vertices[vertex_id];

    float4 position = float4(v.position, 1);
    float3 normal = v.normal;
    float3 tangent = v.tangent.xyz;

    if (p.skinned != 0) {
        // 线性混合蒙皮：每个顶点最多受 4 个关节影响。
        float4 skinned_position = 0;
        float3 skinned_normal = 0;
        float3 skinned_tangent = 0;
        float total = 0;
        for (uint i = 0; i < 4; ++i) {
            if (v.weights[i] > 0 && v.joints[i] != 0xffffffff) {
                float4x4 bone = p.skinning[v.joints[i]];
                skinned_position += mul(bone, position) * v.weights[i];
                skinned_normal   += mul((float3x3)bone, normal) * v.weights[i];
                skinned_tangent  += mul((float3x3)bone, tangent) * v.weights[i];
                total += v.weights[i];
            }
        }
        if (total > 0) {
            position = skinned_position / total;
            normal = skinned_normal / total;
            tangent = skinned_tangent / total;
        }
    }

    float4x4 model = p.model;
    float3x3 normal_matrix = (float3x3)p.normal_matrix;
    float4 color = 1;
    if (p.instanced != 0) {
        Instance instance = p.instances[instance_id];
        model = instance.model;
        normal_matrix = (float3x3)instance.model;
        color = instance.color;
    }

    float4 world = mul(model, position);
    Scene_Params scene = *p.scene;

    VS_Output output;
    output.position = mul(scene.view_projection, world);
    output.world_position = world.xyz;
    output.world_normal = mul(normal_matrix, normal);
    output.world_tangent = float4(mul((float3x3)model, tangent), v.tangent.w);
    output.uv = v.uv;
    output.color = color;
    return output;
}
