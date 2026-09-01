const static float2 positions[3] = {
    float2(0.0, -0.5),
    float2(0.5, 0.5),
    float2(-0.5, 0.5),
};

struct Vertex {
    float4 pos: SV_Position;
}

struct Primitive {
    [[vk::location(0)]]
    nointerpolation float3 color;
    bool cull: SV_CullPrimitive;
}

const static uint MAX_VERTICES = 3;
const static uint MAX_PRIMITIVES = 1;

[outputtopology("triangle")]
[numthreads(3, 1, 1)]
[shader("mesh")]
void main(
    uint thread_id: SV_GroupIndex,
    OutputIndices<uint3, MAX_PRIMITIVES> out_triangles,
    OutputVertices<Vertex, MAX_VERTICES> out_vertices,
    OutputPrimitives<Primitive, MAX_PRIMITIVES> out_primitives
) {
    SetMeshOutputCounts(MAX_VERTICES, MAX_PRIMITIVES);

    if (thread_id < MAX_VERTICES) {
        out_vertices[thread_id].pos = float4(positions[thread_id], 0, 1);
    }

    if (thread_id < MAX_PRIMITIVES) {
        out_triangles[thread_id] = uint3(0, 1, 2);
        out_primitives[thread_id].color = float3(1, 0.5, 0.5);
        out_primitives[thread_id].cull = false;
    }
}
