import "common";

// Must match Mesh_Vertex in src/engine/obj.jai (scalar layout: no padding).
struct Vertex {
    float3 position;
    float3 normal;
    float2 uv;
};

// Must match Mesh_Vertex_Params in src/render/scene.jai.
struct Vertex_Params {
    float4x4 view_projection;
    float4x4 model;
    Vertex* vertices;
};

struct VS_Output {
    float4 position     : SV_POSITION;
    float3 world_normal : NORMAL;
    float2 uv           : TEXCOORD0;
};

[vk::push_constant]
VertexParams<Vertex_Params> vp;

[shader("vertex")]
VS_Output main(uint vertex_id : SV_VertexID) {
    Vertex_Params p = *vp.get();
    Vertex v = p.vertices[vertex_id];

    float4 world = mul(p.model, float4(v.position, 1.0));

    VS_Output output;
    output.position = mul(p.view_projection, world);
    // Good enough while model only rotates / uniformly scales. Non-uniform scale
    // needs the inverse transpose; that arrives with the transform work in phase 3.
    output.world_normal = mul((float3x3)p.model, v.normal);
    output.uv = v.uv;
    return output;
}
