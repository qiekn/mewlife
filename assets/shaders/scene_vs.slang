import "common";

struct Model_Vertex {
    float3 position;
    float3 normal;
    float2 uv;
    float4 weights;
    uint4 joints;
};

struct Scene_Instance {
    float4x4 transform;
    float4x4 normal_transform;
    float4 color;
};

struct Vertex_Parameters {
    Model_Vertex* vertices;
    float4x4* skinning;
    Scene_Instance* instances;
    float4x4 view_projection;
    float4x4 transform;
    float4x4 normal_transform;
    uint skinned;
    float outline_width;
    float2 inverse_viewport;
    float outline_distance;
    uint instanced;
};

struct VS_Output {
    float4 position : SV_POSITION;
    float3 world_position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float4 color : COLOR0;
};

[vk::push_constant]
VertexParams<Vertex_Parameters> parameters;

[shader("vertex")]
VS_Output main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    Vertex_Parameters p = *parameters.get();
    float4 instance_color = 1;
    if (p.instanced != 0) {
        Scene_Instance instance = p.instances[instance_id];
        p.transform = instance.transform;
        p.normal_transform = instance.normal_transform;
        instance_color = instance.color;
    }
    Model_Vertex v = p.vertices[vertex_id];
    float4 position = float4(v.position, 1);
    float3 normal = v.normal;
    if (p.skinned != 0) {
        float4 skinned_position = 0;
        float3 skinned_normal = 0;
        float total = 0;
        for (uint i = 0; i < 4; ++i) {
            if (v.weights[i] > 0 && v.joints[i] != 0xffffffff) {
                float4x4 bone = p.skinning[v.joints[i]];
                skinned_position += mul(bone, position) * v.weights[i];
                skinned_normal += mul((float3x3)bone, normal) * v.weights[i];
                total += v.weights[i];
            }
        }
        if (total > 0) {
            position = skinned_position / total;
            normal = skinned_normal / total;
        }
    }
    float4 world = mul(p.transform, position);
    VS_Output output;
    output.position = mul(p.view_projection, world);
    output.world_position = world.xyz;
    output.normal = mul((float3x3)p.normal_transform, normal);
    output.uv = v.uv;
    output.color = instance_color;
    if (p.outline_width > 0 && output.position.w > 0.0001) {
        // Inverted hull: a DPI-aware pixel width, with a simple version of the reference's distance thinning.
        float4 projected_normal = mul(p.view_projection, float4(normalize(output.normal), 0));
        float2 direction = (projected_normal.xy * output.position.w - output.position.xy * projected_normal.w)
                         / p.inverse_viewport;
        direction /= max(length(direction), 0.0001);
        float width = p.outline_width * min(1, p.outline_distance / output.position.w);
        output.position.xy += direction * p.inverse_viewport * (2 * width * output.position.w);
    }
    return output;
}
