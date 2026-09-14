import "common";

struct Imgui_Vertex {
    float2 position;
    float2 uv;
    uint color;
};

struct Vertex_Parameters {
    Imgui_Vertex* vertices;
    float2 scale;
    float2 translate;
};

struct VS_Output {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

[vk::push_constant]
VertexParams<Vertex_Parameters> parameters;

[shader("vertex")]
VS_Output main(uint vertex_id : SV_VertexID) {
    Vertex_Parameters p = *parameters.get();
    Imgui_Vertex vertex = p.vertices[vertex_id];

    VS_Output output;
    output.position = float4(vertex.position * p.scale + p.translate, 0.0, 1.0);
    output.uv = vertex.uv;
    output.color = float4(
        vertex.color & 255,
        (vertex.color >> 8) & 255,
        (vertex.color >> 16) & 255,
        (vertex.color >> 24) & 255
    ) / 255.0;
    return output;
}
