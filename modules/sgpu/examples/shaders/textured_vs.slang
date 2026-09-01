import "common";

struct VS_Output {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
}

struct Vertex_Buffers {
    float2* positions;
    float2* uvs;
};

[vk::push_constant]
VertexParams<Vertex_Buffers> sp;

[shader("vertex")]
VS_Output main(uint vertex_id: SV_VertexID) {
    VS_Output output;
    output.position = float4(sp.get().positions[vertex_id], 0., 1.);
    output.uv = sp.get().uvs[vertex_id];
    return output;
}